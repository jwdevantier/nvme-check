//! qtest protocol client (NVMe-only scope).
//!
//! Talks the line-based qtest protocol to a QEMU spawned with
//! `-accel qtest -qtest unix:<sock>` (see qtest-vs-vfio-research report §3):
//! QEMU connects to sockets WE listen on; requests get one terminal response
//! line starting with OK/FAIL/ERR; async `IRQ` lines may interleave and are
//! level-cached. A second socket carries a QMP monitor (JSON lines; greeting
//! + qmp_capabilities handshake; events counted and skipped).
//!
//! recv timeouts are fail-closed (a hang is a FAIL, not a stuck runner).
//!
//! `launch()` is the normal entry point: it reads the driver's environment
//! contract (required NVME_QTEST_QEMU / NVME_QTEST_MACHINE), builds the base
//! machine argv from the resolved row, and delegates to `Session.spawn()`.

const std = @import("std");
const linux = std.os.linux;
const errno = std.posix.errno;

pub const pci = @import("pci.zig");
pub const GuestMem = @import("guestmem.zig").GuestMem;
pub const machines = @import("machines.zig");

// The live session, for the panic hook below. Single-threaded test binaries;
// set by spawn, cleared by deinit.
var g_active: ?*Session = null;

/// Panic hook for qtest-lane programs. A failed expect() aborts the test
/// process without running defers — which would leak the spawned QEMU. Opt in
/// from each program root:
///
///     pub const panic = std.debug.FullPanic(qtest.panicHook);
///
pub fn panicHook(msg: []const u8, first_trace_addr: ?usize) noreturn {
    if (g_active) |s| s.child.kill(s.io_threaded.io());
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub const Error = error{
    Syscall,
    Timeout,
    Protocol, // FAIL/ERR response (or malformed OK)
    NotLittleEndian,
    OutOfMemory,
    SpawnFailed,
    ProcessError,
    QemuBinUnset, // NVME_QTEST_QEMU missing (the driver sets it)
    MachineUnset, // NVME_QTEST_MACHINE missing (the driver sets it)
    UnknownMachine, // NVME_QTEST_MACHINE names no machines.Row
};

fn deleteSockFile(path: []const u8) void {
    var buf: [120]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = linux.unlinkat(linux.AT.FDCWD, buf[0..path.len :0].ptr, 0);
}

fn setRecvTimeout(fd: i32) Error!void {
    const tv: linux.timeval = .{ .sec = 15, .usec = 0 };
    const rc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(linux.timeval));
    if (errno(rc) != .SUCCESS) return error.Syscall;
}

/// Bind+listen a unix socket (with fail-closed recv timeout). QEMU connects
/// out to it — see the socket-chardev direction footgun, report §3.1.
fn unixListener(path: []const u8) Error!i32 {
    deleteSockFile(path);
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    if (errno(rc) != .SUCCESS) return error.Syscall;
    const fd: i32 = @intCast(rc);
    var addr: linux.sockaddr.un = .{ .path = undefined };
    if (path.len >= addr.path.len) return error.Syscall;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    if (errno(linux.bind(fd, @ptrCast(&addr), @intCast(@sizeOf(linux.sockaddr.un)))) != .SUCCESS)
        return error.Syscall;
    if (errno(linux.listen(fd, 1)) != .SUCCESS) return error.Syscall;
    try setRecvTimeout(fd);
    return fd;
}

fn acceptOne(lfd: i32) Error!i32 {
    const cfd = linux.accept4(lfd, null, null, 0);
    if (errno(cfd) != .SUCCESS) return error.Timeout; // usually: QEMU never connected
    _ = linux.close(lfd);
    const fd: i32 = @intCast(cfd);
    try setRecvTimeout(fd);
    return fd;
}

fn writeAllFd(fd: i32, bytes: []const u8) Error!void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (errno(rc) != .SUCCESS) return error.Syscall;
        off += rc;
    }
}

/// One line from fd, without the trailing newline. Slice points into `buf`;
/// valid until the next readLineFd on the same buffer.
fn readLineFd(fd: i32, buf: []u8, len: *usize) Error![]const u8 {
    while (true) {
        if (std.mem.indexOfScalar(u8, buf[0..len.*], '\n')) |i| {
            const line = buf[0..i];
            const rest = len.* - (i + 1);
            std.mem.copyForwards(u8, buf[0..rest], buf[i + 1 .. len.*]);
            len.* = rest;
            return line;
        }
        if (len.* == buf.len) return error.Protocol; // line overlong
        const rc = linux.read(fd, buf[len.*..].ptr, buf.len - len.*);
        const e = errno(rc);
        if (e == .AGAIN) return error.Timeout;
        if (e != .SUCCESS) return error.Syscall;
        if (rc == 0) return error.Protocol; // QEMU hung up
        len.* += rc;
    }
}

pub const MAX_IRQ = 1024;

/// Parse "IRQ raise <n>" / "IRQ lower <n>"; null for anything else.
pub fn parseIrqLine(line: []const u8) ?struct { irq: u32, level: bool } {
    var it = std.mem.tokenizeScalar(u8, line, ' ');
    const tag = it.next() orelse return null;
    if (!std.mem.eql(u8, tag, "IRQ")) return null;
    const dir = it.next() orelse return null;
    const num = it.next() orelse return null;
    const irq = std.fmt.parseInt(u32, num, 10) catch return null;
    if (irq >= MAX_IRQ) return null;
    const level = if (std.mem.eql(u8, dir, "raise")) true else if (std.mem.eql(u8, dir, "lower")) false else return null;
    return .{ .irq = irq, .level = level };
}

test "parseIrqLine" {
    const r = parseIrqLine("IRQ raise 5").?;
    try std.testing.expectEqual(@as(u32, 5), r.irq);
    try std.testing.expect(r.level);
    const l = parseIrqLine("IRQ lower 0").?;
    try std.testing.expect(!l.level);
    try std.testing.expect(parseIrqLine("OK") == null);
    try std.testing.expect(parseIrqLine("IRQ sideways 1") == null);
    try std.testing.expect(parseIrqLine("IRQ raise 99999") == null);
}

// --- driver environment + base argv ----------------------------------------

/// What the `nvmecheck:qtest` driver promises on the environment: the QEMU
/// binary for the selected arch, and the machine row selected for it.
pub const Env = struct {
    qemu_bin: []const u8,
    row: machines.Row,
};

/// Read the driver's environment contract. Both variables are required —
/// the driver always sets them (testlib/lib/qtest.lua); guessing a machine
/// here would only paper over a misconfigured run.
pub fn resolveEnv() Error!Env {
    const qemu = std.c.getenv("NVME_QTEST_QEMU") orelse return error.QemuBinUnset;
    const mach = std.c.getenv("NVME_QTEST_MACHINE") orelse return error.MachineUnset;
    const row = machines.byName(std.mem.span(mach)) orelse return error.UnknownMachine;
    return .{ .qemu_bin = std.mem.span(qemu), .row = row };
}

/// The machine-level QEMU argv a row implies under the qtest lane: which
/// machine, qtest acceleration, silencing the protocol transcript, its RAM
/// size, and a headless host (no display, no default devices). Device and
/// drive args are the suite's business and are appended by the caller.
///
/// Returns an owned, growable list the caller extends and then deinits —
/// deliberately not a fixed-size array, so a different machine type can
/// append (or omit) flags without changing this signature.
pub fn baseArgs(allocator: std.mem.Allocator, row: machines.Row) Error!std.ArrayList([]const u8) {
    var args: std.ArrayList([]const u8) = .empty;
    errdefer args.deinit(allocator);
    try args.appendSlice(allocator, &.{
        "-machine",   row.machine,
        "-accel",     "qtest",
        "-qtest-log", "/dev/null",
        "-m",         row.memory,
        "-display",   "none",
        "-nodefaults",
    });
    // future machine types append their differences here (or a row carries
    // its own extras), without touching the return type.
    return args;
}

/// Spawn a qtest QEMU the way the driver intends: resolve the environment,
/// start from the row's base argv, and hand the result to `Session.spawn`.
/// `extra_args` are the remaining argv words (`-drive`, `-object`,
/// `-device`, ...). This is the normal entry point; `Session.spawn` is the
/// lower-level primitive for callers that build their own argv.
pub fn launch(allocator: std.mem.Allocator, extra_args: []const []const u8) Error!*Session {
    const env = try resolveEnv();
    var argv = try baseArgs(allocator, env.row);
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, extra_args);
    return Session.spawn(allocator, env.qemu_bin, env.row, argv.items);
}

test "baseArgs: pc row" {
    const alloc = std.testing.allocator;
    var b = try baseArgs(alloc, machines.pc);
    defer b.deinit(alloc);
    try std.testing.expectEqualStrings("-machine", b.items[0]);
    try std.testing.expectEqualStrings(machines.pc.machine, b.items[1]);
    try std.testing.expectEqualStrings("-m", b.items[6]);
    try std.testing.expectEqualStrings(machines.pc.memory, b.items[7]);
    try std.testing.expectEqualStrings("-nodefaults", b.items[10]);
}

pub const Session = struct {
    allocator: std.mem.Allocator,
    io_threaded: std.Io.Threaded,
    child: std.process.Child,
    fd: i32, // qtest protocol socket
    qmp_fd: i32, // QMP monitor socket
    sock_path: []u8,
    qmp_path: []u8,
    rbuf: [64 * 1024]u8 = undefined,
    rlen: usize = 0,
    qbuf: [64 * 1024]u8 = undefined,
    qlen: usize = 0,
    irq_seen: [MAX_IRQ]bool = @splat(false),
    irq_level: [MAX_IRQ]bool = @splat(false),
    event_count: u64 = 0, // QMP events skipped as responses so far
    row: machines.Row, // the machine this session targets (from launch())
    gmem: GuestMem, // guest-physical bump allocator, initialized from `row`

    /// Low-level: spawn `qemu_bin` with `-qtest unix:<sock>` plus a QMP
    /// monitor (`-chardev socket -mon ...,mode=control`) plus the given
    /// extra args, with QEMU connecting out to two sockets we pre-bind.
    /// `row` is stored on the session and initializes its guest-memory
    /// window. Caller owns; call deinit(). Most tests want `launch()`
    /// instead, which resolves the driver environment and prepends the
    /// row's base args.
    pub fn spawn(allocator: std.mem.Allocator, qemu_bin: []const u8, row: machines.Row, extra_args: []const []const u8) Error!*Session {
        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        s.allocator = allocator;
        s.row = row;
        s.gmem = GuestMem.initFor(row);

        const pid = linux.getpid();
        s.sock_path = try std.fmt.allocPrint(allocator, "/tmp/nvme-qtest-{d}.sock", .{pid});
        s.qmp_path = try std.fmt.allocPrint(allocator, "/tmp/nvme-qtest-{d}.qmp", .{pid});
        errdefer allocator.free(s.qmp_path);

        const lfd = try unixListener(s.sock_path);
        const qfd = try unixListener(s.qmp_path);

        const qtest_arg = std.fmt.allocPrint(allocator, "unix:{s}", .{s.sock_path}) catch return error.OutOfMemory;
        defer allocator.free(qtest_arg);
        const qmp_arg = std.fmt.allocPrint(allocator, "socket,path={s},id=qmp0", .{s.qmp_path}) catch return error.OutOfMemory;
        defer allocator.free(qmp_arg);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, qemu_bin);
        try argv.appendSlice(allocator, &.{
            "-qtest",   qtest_arg,
            "-chardev", qmp_arg,
            "-mon",     "chardev=qmp0,mode=control",
        });
        try argv.appendSlice(allocator, extra_args);

        s.io_threaded = .init(std.heap.smp_allocator, .{});
        s.child = std.process.spawn(s.io_threaded.io(), .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit, // QEMU's own diagnostics ride the driver's capture
        }) catch return error.SpawnFailed;

        s.fd = acceptOne(lfd) catch |e| {
            s.child.kill(s.io_threaded.io());
            return e;
        };
        s.qmp_fd = acceptOne(qfd) catch |e| {
            s.child.kill(s.io_threaded.io());
            return e;
        };
        s.rlen = 0;
        s.qlen = 0;

        // handshake 1: refuse a big-endian target. Two reasons, both
        // separate from byte order as such: today's only implemented PCI
        // config mechanism (x86 ioports, pci.zig) does not exist on the BE
        // targets (ppc64/s390x), and the tests compare read()/write()
        // values against little-endian-defined device registers, while qtest
        // returns them in target order. Revisit when a non-x86 row lands.
        const endian = try s.cmd("endianness");
        if (!std.mem.eql(u8, endian, "little")) return error.NotLittleEndian;

        // handshake 2: QMP greeting + capabilities negotiation
        const greeting = try s.qmpReadLine();
        if (std.mem.indexOf(u8, greeting, "\"QMP\"") == null) return error.Protocol;
        _ = try s.qmpExecute("qmp_capabilities", null);

        g_active = s;
        return s;
    }

    pub fn deinit(s: *Session) void {
        if (g_active == s) g_active = null;
        // graceful when the VM is healthy; kill covers everything else
        if (s.qmp_fd >= 0) _ = s.qmpExecute("quit", null) catch {};
        // 0.16 Child.kill kills AND reaps (sets id = null); a wait() after
        // it asserts. So: kill, done.
        s.child.kill(s.io_threaded.io());
        if (s.fd >= 0) _ = linux.close(s.fd);
        if (s.qmp_fd >= 0) _ = linux.close(s.qmp_fd);
        s.io_threaded.deinit();
        deleteSockFile(s.sock_path);
        deleteSockFile(s.qmp_path);
        s.allocator.free(s.sock_path);
        s.allocator.free(s.qmp_path);
        s.allocator.destroy(s);
    }

    /// The session's guest-memory allocator, initialized from its machine
    /// row. Prefer this over building a `GuestMem` yourself: the window must
    /// match the machine the session actually spawned.
    pub fn guestMem(s: *Session) *GuestMem {
        return &s.gmem;
    }

    // --- qtest protocol ----------------------------------------------------

    fn readLine(s: *Session) Error![]const u8 {
        return readLineFd(s.fd, &s.rbuf, &s.rlen);
    }

    var cmd_buf: [4096]u8 = undefined; // single-threaded test runner

    fn fmt(comptime f: []const u8, args: anytype) Error![]const u8 {
        return std.fmt.bufPrint(&cmd_buf, f, args) catch error.Protocol;
    }

    /// Send a command; return everything after "OK ", skipping async IRQ
    /// lines (level-cached via noteIrq). FAIL/ERR raise error.Protocol.
    pub fn cmd(s: *Session, line: []const u8) Error![]const u8 {
        try writeAllFd(s.fd, line);
        try writeAllFd(s.fd, "\n");
        while (true) {
            const rsp = try s.readLine();
            if (std.mem.startsWith(u8, rsp, "IRQ")) {
                s.noteIrq(rsp);
                continue;
            }
            if (std.mem.startsWith(u8, rsp, "OK")) {
                return std.mem.trim(u8, rsp[2..], " ");
            }
            if (std.mem.startsWith(u8, rsp, "FAIL") or std.mem.startsWith(u8, rsp, "ERR")) {
                std.debug.print("qtest: FAIL/ERR for '{s}': {s}\n", .{ line, rsp });
                return error.Protocol;
            }
        }
    }

    /// Record an async IRQ line (called from cmd(); public for tests).
    pub fn noteIrq(s: *Session, line: []const u8) void {
        if (parseIrqLine(line)) |e| {
            s.irq_seen[e.irq] = true;
            s.irq_level[e.irq] = e.level;
        }
    }

    /// Last observed level of irq N (null if never raised/lowered).
    pub fn irqLevel(s: *const Session, irq: u32) ?bool {
        if (irq >= MAX_IRQ or !s.irq_seen[irq]) return null;
        return s.irq_level[irq];
    }

    fn numRsp(rsp: []const u8) Error!u64 {
        return std.fmt.parseInt(u64, rsp, 0) catch error.Protocol;
    }

    // --- bus ops -----------------------------------------------------------

    /// x86 I/O-port read (32-bit); qtest wire command `inl`.
    pub fn in32(s: *Session, port: u16) Error!u32 {
        return @intCast(try numRsp(try s.cmd(try fmt("inl 0x{x}", .{port}))));
    }

    /// x86 I/O-port write (32-bit); qtest wire command `outl`.
    pub fn out32(s: *Session, port: u16, val: u32) Error!void {
        _ = try s.cmd(try fmt("outl 0x{x} 0x{x}", .{ port, val }));
    }

    /// Read one value of type `T` (u8/u16/u32/u64) at guest-physical address
    /// `a`. The type *is* the width; the wire command is readb/readw/readl/readq.
    pub fn read(s: *Session, comptime T: type, a: u64) Error!T {
        const op = switch (T) {
            u8 => "readb",
            u16 => "readw",
            u32 => "readl",
            u64 => "readq",
            else => @compileError("qtest read: T must be u8, u16, u32 or u64"),
        };
        return @intCast(try numRsp(try s.cmd(try fmt(op ++ " 0x{x}", .{a}))));
    }

    /// Write `v` of type `T` (u8/u16/u32/u64) at guest-physical address `a`.
    pub fn write(s: *Session, comptime T: type, a: u64, v: T) Error!void {
        const op = switch (T) {
            u8 => "writeb",
            u16 => "writew",
            u32 => "writel",
            u64 => "writeq",
            else => @compileError("qtest write: T must be u8, u16, u32 or u64"),
        };
        _ = try s.cmd(try fmt(op ++ " 0x{x} 0x{x}", .{ a, v }));
    }

    /// Advance the virtual clock (ns). Requires -accel qtest.
    pub fn clockStep(s: *Session, ns: u64) Error!void {
        _ = try s.cmd(try fmt("clock_step 0x{x}", .{ns}));
    }

    /// memset <addr> <size> <pattern>
    pub fn memset(s: *Session, addr: u64, size: u64, pattern: u8) Error!void {
        _ = try s.cmd(try fmt("memset 0x{x} 0x{x} 0x{x:0>2}", .{ addr, size, pattern }));
    }

    /// write <addr> <size> 0x<hex> — bulk guest-memory write (hex on the
    /// wire, 2x size; fine for command/queue buffers).
    pub fn memWrite(s: *Session, addr: u64, source: []const u8) Error!void {
        const hex = s.allocator.alloc(u8, source.len * 2) catch return error.OutOfMemory;
        defer s.allocator.free(hex);
        const digits = "0123456789abcdef";
        for (source, 0..) |byte, i| {
            hex[i * 2] = digits[byte >> 4];
            hex[i * 2 + 1] = digits[byte & 0xf];
        }
        const c = s.allocator.alloc(u8, 64 + hex.len) catch return error.OutOfMemory;
        defer s.allocator.free(c);
        const line = std.fmt.bufPrint(c, "write 0x{x} 0x{x} 0x{s}", .{ addr, source.len, hex }) catch return error.Protocol;
        _ = try s.cmd(line);
    }

    /// read <addr> <size> -> 0x<hex>. Fills `dest` (dest.len bytes).
    pub fn memRead(s: *Session, addr: u64, dest: []u8) Error!void {
        const rsp = try s.cmd(try fmt("read 0x{x} 0x{x}", .{ addr, dest.len }));
        if (rsp.len < 2 + dest.len * 2 or !std.mem.startsWith(u8, rsp, "0x")) return error.Protocol;
        var i: usize = 0;
        while (i < dest.len) : (i += 1) {
            dest[i] = std.fmt.parseInt(u8, rsp[2 + i * 2 ..][0..2], 16) catch return error.Protocol;
        }
    }

    /// b64write <addr> <size> <base64> — like memWrite but ~4/3 wire size
    /// instead of 2x; matters once patterns get large.
    pub fn memWriteB64(s: *Session, addr: u64, source: []const u8) Error!void {
        const enc = std.base64.standard.Encoder;
        const b64 = s.allocator.alloc(u8, enc.calcSize(source.len)) catch return error.OutOfMemory;
        defer s.allocator.free(b64);
        _ = enc.encode(b64, source);
        const c = s.allocator.alloc(u8, 64 + b64.len) catch return error.OutOfMemory;
        defer s.allocator.free(c);
        const line = std.fmt.bufPrint(c, "b64write 0x{x} 0x{x} {s}", .{ addr, source.len, b64 }) catch return error.Protocol;
        _ = try s.cmd(line);
    }

    /// b64read <addr> <size> -> OK <base64>. Fills `dest`.
    pub fn memReadB64(s: *Session, addr: u64, dest: []u8) Error!void {
        const rsp = try s.cmd(try fmt("b64read 0x{x} 0x{x}", .{ addr, dest.len }));
        const dec = std.base64.standard.Decoder;
        const want = dec.calcSizeForSlice(rsp) catch return error.Protocol;
        if (want != dest.len) return error.Protocol;
        dec.decode(dest, rsp) catch return error.Protocol;
    }

    // --- QMP monitor -------------------------------------------------------

    fn qmpReadLine(s: *Session) Error![]const u8 {
        return readLineFd(s.qmp_fd, &s.qbuf, &s.qlen);
    }

    /// {"execute": name, "arguments": args?} — one JSON reply, QMP events
    /// skipped and counted (s.event_count). The reply's JSON text is
    /// returned raw (qmp replies fit one line); an {"error": ...} reply
    /// raises error.Protocol. Structured parsing stays the caller's business
    /// until a test needs it.
    pub fn qmpExecute(s: *Session, name: []const u8, args_json: ?[]const u8) Error![]const u8 {
        const line = if (args_json) |a|
            std.fmt.bufPrint(&cmd_buf, "{{\"execute\": \"{s}\", \"arguments\": {s}}}", .{ name, a }) catch return error.Protocol
        else
            std.fmt.bufPrint(&cmd_buf, "{{\"execute\": \"{s}\"}}", .{name}) catch return error.Protocol;
        try writeAllFd(s.qmp_fd, line);
        try writeAllFd(s.qmp_fd, "\n");
        while (true) {
            const rsp = try s.qmpReadLine();
            if (std.mem.startsWith(u8, rsp, "{\"event\"")) {
                s.event_count += 1;
                continue;
            }
            if (std.mem.startsWith(u8, rsp, "{\"error\"")) return error.Protocol;
            return rsp;
        }
    }
};
