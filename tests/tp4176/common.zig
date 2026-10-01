//! Shared device state for a TP4176 batch: one lazily-opened controller per
//! test binary. The Zig test runner is single-threaded, so no lock is needed
//! (the Odin suite needed one because its runner was multi-threaded).

const std = @import("std");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const spec = @import("spec");

// libvfn's nvme_init() expects a zeroed controller (it does not clear it
// itself); an `undefined` global would poison it.
var g_ctrl: vfn.Ctrl = std.mem.zeroes(vfn.Ctrl);
var g_init = false;
var g_cntlid: u16 = 0;

/// Open the controller named by $NVME_BDF once, learning its controller id
/// (used as the TID for feature targeting).
pub fn ctrl() !*vfn.Ctrl {
    if (g_init) return &g_ctrl;

    // NVME_DEBUG=1 turns on libvfn's logging (to stderr) for diagnosis.
    if (std.c.getenv("NVME_DEBUG") != null) vfn.enableDebugLog();

    try vfntest.openFromEnv(&g_ctrl);

    var buf = try vfntest.pageBuffer(spec.log_len);
    defer buf.deinit();

    var cmd = spec.identifyCmd(0x01, 0x00); // CNS 01h: Identify Controller
    const r = vfntest.admin(&g_ctrl, &cmd, ptr(buf), buf.bytes().len);
    const st = nvme.status(r.cqe);
    if (!r.ok or st.sc != 0 or st.sct != 0) return error.IdentifyFailed;

    g_cntlid = spec.get16(buf.bytes(), 78); // CNTLID, bytes 78:79
    g_init = true;
    return &g_ctrl;
}

pub fn cntlid() u16 {
    return g_cntlid;
}

/// Submit an admin command. `ok == false` may mean a device error status (the
/// completion is still valid) -- inspect `nvme.status(r.cqe)`.
pub fn admin(cmd: *vfn.Cmd, data: ?*anyopaque, len: usize) !vfntest.AdminResult {
    return vfntest.admin(try ctrl(), cmd, data, len);
}

/// Submit an admin command, requiring success (transport *and* device status);
/// returns the completion.
pub fn adminOk(cmd: *vfn.Cmd, data: ?*anyopaque, len: usize) !vfn.Cqe {
    const r = try admin(cmd, data, len);
    if (!r.ok) return error.NvmeCommandFailed;
    return r.cqe;
}

/// A page-aligned DMA buffer as a raw pointer for libvfn.
pub fn ptr(buf: vfntest.PageBuf) ?*anyopaque {
    return @ptrCast(buf.bytes().ptr);
}

/// The same buffer viewed as the Figure RLDB data structure.
pub fn rlData(buf: vfntest.PageBuf) *spec.RlData {
    return @ptrCast(buf.bytes().ptr);
}
