//! Thin Zig mapping of libvfn's C API (DESIGN.md §3). This layer is kept
//! close to upstream — a direct, predictable mapping, not an opinionated
//! wrapper. Idiomatic test conveniences live in `vfntest`.

const c = @import("vfn_c");

pub const Ctrl = c.nvme_ctrl;
pub const Cmd = c.nvme_cmd;
pub const Cqe = c.nvme_cqe;
pub const Sq = c.nvme_sq;
pub const Cq = c.nvme_cq;
pub const Rq = c.nvme_rq;

// Helpers from src/vfn_shim.c that translate-c cannot express (inline asm,
// GCC atomics, demoted header-only helpers).
pub extern fn vfn_shim_log_set_debug() void;
pub extern fn vfn_shim_errno() c_int;
pub extern fn vfn_shim_dbbuf_selftest() c_int;

/// nvme_init() — open the controller at `bdf` (e.g. "0000:02:00.0").
/// Returns 0 on success (errno via `lastErrno`).
pub fn init(ctrl: *Ctrl, bdf: [*:0]const u8) c_int {
    return c.nvme_init(ctrl, bdf, null);
}

/// nvme_close().
pub fn close(ctrl: *Ctrl) void {
    c.nvme_close(ctrl);
}

/// nvme_admin() — submit one admin command. `cqe` (if given) receives the
/// completion. Returns 0 when the library call succeeded.
pub fn admin(ctrl: *Ctrl, cmd: *Cmd, data: ?*anyopaque, len: usize, cqe: ?*Cqe) c_int {
    return c.nvme_admin(ctrl, cmd, data, len, cqe);
}

/// Turn on libvfn's debug logging (stderr).
pub fn enableDebugLog() void {
    vfn_shim_log_set_debug();
}

/// errno captured by the last failing libvfn call.
pub fn lastErrno() c_int {
    return vfn_shim_errno();
}

// --- request trackers and completion queues (translated static inlines) ---

pub fn rqAcquire(sq: *Sq) ?*Rq {
    return c.nvme_rq_acquire(sq);
}

pub fn rqRelease(rq: *Rq) void {
    c.nvme_rq_release(rq);
}

pub fn rqExec(rq: *Rq, cmd: *Cmd) void {
    c.nvme_rq_exec(rq, cmd);
}

/// Execute a command on the submission queue directly (does NOT overwrite the
/// command's cid) — e.g. an async event, which must carry `cid | NVME_CID_AER`.
pub fn sqExec(sq: *Sq, cmd: *const Cmd) void {
    c.nvme_sq_exec(sq, cmd);
}

pub fn cqGetCqe(cq: *Cq) ?*Cqe {
    return c.nvme_cq_get_cqe(cq);
}

pub fn cqUpdateHead(cq: *Cq) void {
    c.nvme_cq_update_head(cq);
}
