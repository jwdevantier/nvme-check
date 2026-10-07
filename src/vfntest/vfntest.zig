//! Test-support conveniences (DESIGN.md §3). Thin and opportunistic, extracted
//! as patterns repeat; this layer must not become a second NVMe API.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");

pub const page_size = std.heap.page_size_min;

/// Default controller BDF when $NVME_BDF is unset.
pub const default_bdf: [:0]const u8 = "0000:02:00.0";

/// An anonymous, page-aligned mapping suitable for DMA. libvfn's iommufd
/// backend rejects unaligned user_va/length with EINVAL, so DMA buffers must
/// be page-aligned (and, for mapping, a whole number of pages).
pub const PageBuf = struct {
    mem: []align(page_size) u8,

    pub fn bytes(self: PageBuf) []align(page_size) u8 {
        return self.mem;
    }

    pub fn deinit(self: PageBuf) void {
        std.posix.munmap(self.mem);
    }
};

pub fn pageBuffer(len: usize) !PageBuf {
    const mem = try std.posix.mmap(
        null,
        len,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    );
    return .{ .mem = mem };
}

/// Open the controller named by $NVME_BDF (or `default_bdf`).
pub fn openFromEnv(ctrl: *vfn.Ctrl) !void {
    const from_env = std.c.getenv("NVME_BDF");
    const bdf: [*:0]const u8 = if (from_env) |p| p else default_bdf.ptr;
    if (vfn.init(ctrl, bdf) != 0) return error.NvmeInitFailed;
}

/// Result of an admin command submission.
pub const AdminResult = struct {
    /// The completion; valid whenever the device produced one (including an
    /// error status).
    cqe: vfn.Cqe,
    /// False when libvfn reported failure: either the command completed with a
    /// non-zero status (SC/SCT in `cqe`) or the library call failed.
    ok: bool,
};

/// Submit an admin command. libvfn's `nvme_admin` returns non-zero for a
/// *command* error too (and still fills the completion), so `ok == false` is
/// data to inspect, not necessarily a transport failure. Check
/// `nvme.status(result.cqe)`.
pub fn admin(ctrl: *vfn.Ctrl, cmd: *vfn.Cmd, data: ?*anyopaque, len: usize) AdminResult {
    var cqe: vfn.Cqe = std.mem.zeroes(vfn.Cqe);
    const ret = vfn.admin(ctrl, cmd, data, len, &cqe);
    return .{ .cqe = cqe, .ok = ret == 0 };
}

// --- real interrupt delivery (VFIO eventfds) -------------------------------

/// std.posix has no close() binding in this Zig; the direct syscall is fine on
/// this Linux-only (VFIO) path.
fn closeFd(fd: std.posix.fd_t) void {
    _ = std.os.linux.close(fd);
}

/// Bind a fresh eventfd to one MSI-X `vector` via VFIO and return it. The test
/// then waits on the fd to observe the device actually signalling the vector,
/// rather than merely polling the completion queue. Pair with `irqDisable`.
///
/// The message a vector sends is programmed separately in the MSI-X table; the
/// eventfd is the host-side observation point VFIO gives us.
pub fn irqEnable(ctrl: *vfn.Ctrl, vector: u16) !std.posix.fd_t {
    // eventfd(): libc's wrapper sets errno; std.posix has no binding for it on
    // Linux, so call the syscall and decode the raw return.
    const rc = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.EventfdFailed;
    const fd: std.posix.fd_t = @intCast(rc);

    errdefer closeFd(fd);
    if (c.vfn_shim_set_irq(ctrl, vector, fd) != 0) return error.SetIrqFailed;
    return fd;
}

/// Wait up to `timeout_ms` for an interrupt event on `fd` (created by
/// `irqEnable`). Returns true when one arrived (the eventfd counter is read and
/// drained), false on timeout.
pub fn irqWait(fd: std.posix.fd_t, timeout_ms: u64) !bool {
    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = try std.posix.poll(&fds, @intCast(timeout_ms));
    if (n == 0) return false;
    var count: [8]u8 = undefined;
    _ = try std.posix.read(fd, &count);
    return true;
}

/// Stop waiting on (and close) an eventfd returned by `irqEnable`.
pub fn irqDisable(fd: std.posix.fd_t) void {
    closeFd(fd);
}
