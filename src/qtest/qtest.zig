//! qtest protocol client (NVMe-only scope).
//!
//! Talks the line-based qtest protocol to a QEMU spawned with
//! `-accel qtest -qtest unix:<sock>` (see qtest-vs-vfio-research report §3):
//! QEMU connects to a socket WE listen on; requests get one terminal
//! response line starting with OK/FAIL/ERR; async `IRQ` lines may interleave
//! and are skipped (level tracking is a TODO until a test needs it).
//!
//! Only what the nvme-test.c port needs: endianness, in/out{l},
//! read/write{b,w,l,q}, clock_step. recv timeouts are fail-closed (a hang is
//! a FAIL, not a stuck runner).

const std = @import("std");
const linux = std.os.linux;
const errno = std.posix.errno;

pub const pci = @import("pci.zig");

pub const Error = error{
    Syscall,
    Timeout,
    Protocol, // FAIL/ERR response (or malformed OK)
    NotLittleEndian,
    OutOfMemory,
    SpawnFailed,
    ProcessError,
};

fn deleteSockFile(path: []const u8) void {
    var buf: [120]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = linux.unlinkat(linux.AT.FDCWD, buf[0..path.len :0].ptr, 0);
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    child: std.process.Child,
    fd: i32,
    listen_fd: i32,
    sock_path: []u8,
    rbuf: [64 * 1024]u8 = undefined,
    rlen: usize = 0,

    /// Spawn `qemu_bin` with `-qtest unix:<fresh socket>` plus the given
    /// extra args, bind/listen the socket first (QEMU is the connecting
    /// side), then accept. Caller owns; call deinit().
    pub fn spawn(allocator: std.mem.Allocator, qemu_bin: []const u8, extra_args: []const []const u8) Error!*Session {
        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        s.allocator = allocator;

        const pid = linux.getpid();
        s.sock_path = try std.fmt.allocPrint(allocator, "/tmp/nvme-qtest-{d}.sock", .{pid});
        deleteSockFile(s.sock_path);

        const lfd: i32 = blk: {
            const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
            if (errno(rc) != .SUCCESS) return error.Syscall;
            break :blk @intCast(rc);
        };
        var addr: linux.sockaddr.un = .{ .path = undefined };
        if (s.sock_path.len >= addr.path.len) return error.Syscall;
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..s.sock_path.len], s.sock_path);
        if (errno(linux.bind(lfd, @ptrCast(&addr), @intCast(@sizeOf(linux.sockaddr.un)))) != .SUCCESS)
            return error.Syscall;
        if (errno(linux.listen(lfd, 1)) != .SUCCESS) return error.Syscall;
        // fail-closed: an unreachable QEMU must not wedge the runner
        try setRecvTimeout(lfd);
        s.listen_fd = lfd;

        const qtest_arg = std.fmt.allocPrint(allocator, "unix:{s}", .{s.sock_path}) catch return error.OutOfMemory;
        defer allocator.free(qtest_arg);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, qemu_bin);
        try argv.appendSlice(allocator, &.{ "-qtest", qtest_arg });
        try argv.appendSlice(allocator, extra_args);

        s.io_threaded = .init(std.heap.smp_allocator, .{});
        s.child = std.process.spawn(s.io_threaded.io(), .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit, // QEMU's own diagnostics ride the driver's capture
        }) catch return error.SpawnFailed;

        const cfd = linux.accept4(lfd, null, null, 0);
        if (errno(cfd) != .SUCCESS) {
            _ = linux.close(lfd);
            s.child.kill(s.io_threaded.io());
            return error.Timeout;
        }
        _ = linux.close(lfd);
        s.listen_fd = -1;
        s.fd = @intCast(cfd);
        try setRecvTimeout(s.fd);
        s.rlen = 0;

        // handshake: this client is x86-only today (PCI config via ioports);
        // refuse to run a test against a big-endian target by accident.
        const endian = try s.cmd("endianness");
        if (!std.mem.eql(u8, endian, "little")) return error.NotLittleEndian;
        return s;
    }

    pub fn deinit(s: *Session) void {
        // 0.16 Child.kill kills AND reaps (sets id = null); a wait() after
        // it asserts. So: kill, done.
        s.child.kill(s.io_threaded.io());
        if (s.fd >= 0) _ = linux.close(s.fd);
        s.io_threaded.deinit();
        deleteSockFile(s.sock_path);
        s.allocator.free(s.sock_path);
        s.allocator.destroy(s);
    }

    pub fn socket_path(s: *const Session) []const u8 {
        return s.sock_path;
    }

    fn setRecvTimeout(fd: i32) Error!void {
        const tv: linux.timeval = .{ .sec = 15, .usec = 0 };
        const rc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
        if (errno(rc) != .SUCCESS) return error.Syscall;
    }

    fn writeAll(s: *Session, bytes: []const u8) Error!void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(s.fd, bytes.ptr + off, bytes.len - off);
            if (errno(rc) != .SUCCESS) return error.Syscall;
            off += rc;
        }
    }

    /// One line from the socket, without the trailing newline. Slice points
    /// into the session's buffer; valid until the next readLine().
    fn readLine(s: *Session) Error![]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, s.rbuf[0..s.rlen], '\n')) |i| {
                const line = s.rbuf[0..i];
                const rest = s.rlen - (i + 1);
                std.mem.copyForwards(u8, s.rbuf[0..rest], s.rbuf[i + 1 .. s.rlen]);
                s.rlen = rest;
                return line;
            }
            if (s.rlen == s.rbuf.len) return error.Protocol; // line overlong
            const rc = linux.read(s.fd, s.rbuf[s.rlen..].ptr, s.rbuf.len - s.rlen);
            const e = errno(rc);
            if (e == .AGAIN) return error.Timeout;
            if (e != .SUCCESS) return error.Syscall;
            if (rc == 0) return error.Protocol; // QEMU hung up
            s.rlen += rc;
        }
    }

    var cmd_buf: [4096]u8 = undefined; // single-threaded test runner

    fn fmt(comptime s: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.bufPrint(&cmd_buf, s, args) catch error.Protocol;
    }

    /// Send a command; return everything after "OK ", skipping async IRQ
    /// lines. FAIL/ERR responses raise error.Protocol.
    pub fn cmd(s: *Session, line: []const u8) Error![]const u8 {
        try s.writeAll(line);
        try s.writeAll("\n");
        while (true) {
            const rsp = try s.readLine();
            if (std.mem.startsWith(u8, rsp, "IRQ")) continue; // async; untracked for now
            if (std.mem.startsWith(u8, rsp, "OK")) {
                return std.mem.trim(u8, rsp[2..], " ");
            }
            if (std.mem.startsWith(u8, rsp, "FAIL") or std.mem.startsWith(u8, rsp, "ERR")) {
                std.debug.print("qtest: FAIL/ERR for '{s}': {s}\n", .{ line, rsp });
                return error.Protocol;
            }
        }
    }

    fn numRsp(rsp: []const u8) Error!u64 {
        return std.fmt.parseInt(u64, rsp, 0) catch error.Protocol;
    }

    // --- bus ops -----------------------------------------------------------

    pub fn inl(s: *Session, port: u16) Error!u32 {
        const c = try fmt("inl 0x{x}", .{port});
        return @intCast(try numRsp(try s.cmd(c)));
    }

    pub fn outl(s: *Session, port: u16, val: u32) Error!void {
        const c = try fmt("outl 0x{x} 0x{x}", .{ port, val });
        _ = try s.cmd(c);
    }

    pub fn readb(s: *Session, a: u64) Error!u8 {
        return @intCast(try s.readN("readb", a));
    }
    pub fn readw(s: *Session, a: u64) Error!u16 {
        return @intCast(try s.readN("readw", a));
    }
    pub fn readl(s: *Session, a: u64) Error!u32 {
        return @intCast(try s.readN("readl", a));
    }
    pub fn readq(s: *Session, a: u64) Error!u64 {
        return s.readN("readq", a);
    }

    fn readN(s: *Session, comptime op: []const u8, a: u64) Error!u64 {
        const c = try fmt(op ++ " 0x{x}", .{a});
        return numRsp(try s.cmd(c));
    }

    pub fn writeb(s: *Session, a: u64, v: u8) Error!void {
        return s.writeN("writeb", a, v);
    }
    pub fn writew(s: *Session, a: u64, v: u16) Error!void {
        return s.writeN("writew", a, v);
    }
    pub fn writel(s: *Session, a: u64, v: u32) Error!void {
        return s.writeN("writel", a, v);
    }
    pub fn writeq(s: *Session, a: u64, v: u64) Error!void {
        return s.writeN("writeq", a, v);
    }

    fn writeN(s: *Session, comptime op: []const u8, a: u64, v: u64) Error!void {
        const c = try fmt(op ++ " 0x{x} 0x{x}", .{ a, v });
        _ = try s.cmd(c);
    }

    /// Advance the virtual clock (ns). Requires -accel qtest.
    pub fn clockStep(s: *Session, ns: u64) Error!void {
        const c = try fmt("clock_step 0x{x}", .{ns});
        _ = try s.cmd(c);
    }

    /// memset <addr> <size> <pattern>
    pub fn memset(s: *Session, addr: u64, size: u64, pattern: u8) Error!void {
        const c = try fmt("memset 0x{x} 0x{x} 0x{x:0>2}", .{ addr, size, pattern });
        _ = try s.cmd(c);
    }

    /// write <addr> <size> 0x<hex> — bulk guest-memory write (hex on the
    /// wire, 2x size; fine for command/queue buffers).
    pub fn memWrite(s: *Session, addr: u64, bytes: []const u8) Error!void {
        const hex = s.allocator.alloc(u8, bytes.len * 2) catch return error.OutOfMemory;
        defer s.allocator.free(hex);
        const digits = "0123456789abcdef";
        for (bytes, 0..) |byte, i| {
            hex[i * 2] = digits[byte >> 4];
            hex[i * 2 + 1] = digits[byte & 0xf];
        }
        const c = s.allocator.alloc(u8, 64 + hex.len) catch return error.OutOfMemory;
        defer s.allocator.free(c);
        const line = std.fmt.bufPrint(c, "write 0x{x} 0x{x} 0x{s}", .{ addr, bytes.len, hex }) catch return error.Protocol;
        _ = try s.cmd(line);
    }

    /// read <addr> <size> -> 0x<hex>. Fills `out` (out.len bytes).
    pub fn memRead(s: *Session, addr: u64, out: []u8) Error!void {
        const c = try fmt("read 0x{x} 0x{x}", .{ addr, out.len });
        const rsp = try s.cmd(c);
        if (rsp.len < 2 + out.len * 2 or !std.mem.startsWith(u8, rsp, "0x")) return error.Protocol;
        var i: usize = 0;
        while (i < out.len) : (i += 1) {
            out[i] = std.fmt.parseInt(u8, rsp[2 + i * 2 ..][0..2], 16) catch return error.Protocol;
        }
    }
};
