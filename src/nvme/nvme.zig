//! Shared NVMe spec structures. Generic structures that libvfn already
//! declares are re-exported, not duplicated; TP-specific
//! layouts live with the TP (e.g. tests/<tp>/spec.zig).

const std = @import("std");
const c = @import("vfn_c");

pub const Cqe = c.nvme_cqe;

/// Decoded CQE status field (NVMe base spec 1.4.3, Figure "Completion Queue
/// Entry"): the 16-bit Status Field `sfp` packs the phase bit plus the
/// status code, status code type, CRD, M and DNR bits.
pub const Status = struct {
    /// Status Code (SC)
    sc: u8,
    /// Status Code Type (SCT)
    sct: u3,
    /// Command Retry Delay (CRD)
    crd: u2,
    /// More (M)
    m: bool,
    /// Do Not Retry (DNR)
    dnr: bool,
};

pub fn status(cqe: Cqe) Status {
    const sfp: u16 = c.le16_to_cpu(cqe.sfp);
    return .{
        .sc = @truncate((sfp >> 1) & 0xff),
        .sct = @truncate((sfp >> 9) & 0x7),
        .crd = @truncate((sfp >> 12) & 0x3),
        .m = (sfp >> 14) & 1 != 0,
        .dnr = (sfp >> 15) & 1 != 0,
    };
}

/// The first dword of a CQE (command-specific; e.g. the async-event dw0).
/// Read as raw little-endian bytes to sidestep translate-c's anonymous union.
pub fn cqeDw0(cqe: Cqe) u32 {
    const p: [*]const u8 = @ptrCast(&cqe);
    return std.mem.readInt(u32, p[0..4], .little);
}

test "CQE status decodes SC/SCT/DNR" {
    var cqe = std.mem.zeroes(Cqe);
    // phase=1, SC=0x1f, SCT=1, DNR=1
    cqe.sfp = c.cpu_to_le16(@as(u16, 1 | (0x1f << 1) | (1 << 9) | (1 << 15)));

    const st = status(cqe);
    try std.testing.expectEqual(@as(u8, 0x1f), st.sc);
    try std.testing.expectEqual(@as(u3, 1), st.sct);
    try std.testing.expect(st.dnr);
    try std.testing.expect(!st.m);
}
