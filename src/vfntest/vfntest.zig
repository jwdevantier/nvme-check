//! Test-support conveniences (DESIGN.md §3). Thin and opportunistic, extracted
//! as patterns repeat; this layer must not become a second NVMe API.

const std = @import("std");
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
