//! TP4176 batch: Set/Get Features 28h — round-trips, rejections, and the
//! async-event configuration bit.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("spec");

// Set Features 28h followed by Get Features 28h must round-trip every field
// at its Figure RLDB offset (notably WBWR, byte 35).
test "feature_set_get_roundtrip" {
    _ = try common.ctrl();

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    var resb = try vfntest.pageBuffer(spec.rl_map_len);
    defer resb.deinit();
    const out = common.rlData(outb);
    const res = common.rlData(resb);

    out.* = std.mem.zeroes(spec.RlData);
    out.rlc = c.cpu_to_le16(spec.rlc_rle | spec.rlm_hard);
    out.bwsf = 3;
    out.tbwv = c.cpu_to_le64(100);
    out.wbwv = c.cpu_to_le64(50);
    out.tiops = c.cpu_to_le32(1000);
    out.wiops = c.cpu_to_le32(500);
    out.riopsr = 1;
    out.wiopsr = 1;
    out.rbwr = 1;
    out.wbwr = 2;

    var cmd = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 0, 0);
    _ = try common.adminOk(&cmd, common.ptr(outb), spec.rl_map_len);
    cmd = spec.rlFeaturesCmd(spec.admin_get_features, common.cntlid(), 0, 0);
    _ = try common.adminOk(&cmd, common.ptr(resb), spec.rl_map_len);

    std.debug.print("    get: rlc=0x{x} bwsf={d} tbwv={d} wbwv={d} tiops={d} wiops={d} ratios={d}/{d} {d}/{d}\n", .{
        c.le16_to_cpu(res.rlc),      res.bwsf,
        c.le64_to_cpu(res.tbwv),     c.le64_to_cpu(res.wbwv),
        c.le32_to_cpu(res.tiops),    c.le32_to_cpu(res.wiops),
        res.riopsr,                  res.wiopsr,
        res.rbwr,                    res.wbwr,
    });

    try std.testing.expect(c.le16_to_cpu(res.rlc) & spec.rlc_rle != 0);
    try std.testing.expectEqual(spec.rlm_hard, c.le16_to_cpu(res.rlc) & 0xf);
    try std.testing.expectEqual(@as(u8, 3), res.bwsf);
    try std.testing.expectEqual(@as(u64, 100), c.le64_to_cpu(res.tbwv));
    try std.testing.expectEqual(@as(u64, 50), c.le64_to_cpu(res.wbwv));
    try std.testing.expectEqual(@as(u32, 1000), c.le32_to_cpu(res.tiops));
    try std.testing.expectEqual(@as(u32, 500), c.le32_to_cpu(res.wiops));
    try std.testing.expectEqual(@as(u8, 1), res.riopsr);
    try std.testing.expectEqual(@as(u8, 1), res.wiopsr);
    try std.testing.expectEqual(@as(u8, 1), res.rbwr);
    try std.testing.expectEqual(@as(u8, 2), res.wbwr); // byte 35 round-trip
}

// Clearing RLE disables the feature; a subsequent Get Features must report
// RLE cleared.
test "disable_clears_rle" {
    _ = try common.ctrl();

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    var resb = try vfntest.pageBuffer(spec.rl_map_len);
    defer resb.deinit();
    const out = common.rlData(outb);
    const res = common.rlData(resb);
    out.* = std.mem.zeroes(spec.RlData); // RLE=0

    var cmd = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 0, 0);
    _ = try common.adminOk(&cmd, common.ptr(outb), spec.rl_map_len);
    cmd = spec.rlFeaturesCmd(spec.admin_get_features, common.cntlid(), 0, 0);
    _ = try common.adminOk(&cmd, common.ptr(resb), spec.rl_map_len);

    try std.testing.expect(c.le16_to_cpu(res.rlc) & spec.rlc_rle == 0);
}

// TGT != 0 is invalid; expect Invalid Field in Command + DNR. NOTE: libvfn's
// nvme_admin() returns non-zero for a command error and still fills the CQE,
// so this is `!r.ok` with a valid completion, not a transport failure.
test "invalid_tgt_rejected" {
    _ = try common.ctrl();

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    var cmd = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 1, 0);
    const r = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);

    try std.testing.expect(!r.ok);
    const st = nvme.status(r.cqe);
    try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
    try std.testing.expect(st.dnr);
}

// A TID naming another controller (or the reserved values) must be aborted
// with Invalid Controller Identifier (SCT=1, SC=1fh).
test "invalid_tid_rejected" {
    _ = try common.ctrl();

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();

    const tids = [_]u16{ 0xffff, 0xfffe, 0xfffd, common.cntlid() +% 100 };
    for (tids) |tid| {
        var cmd = spec.rlFeaturesCmd(spec.admin_set_features, tid, 0, 0);
        const r = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);
        const st = nvme.status(r.cqe);
        std.debug.print("    tid=0x{x}: ok={} sc=0x{x} sct={d} dnr={}\n", .{ tid, r.ok, st.sc, st.sct, st.dnr });
        try std.testing.expect(!r.ok);
        try std.testing.expectEqual(spec.sc_invalid_ctrl_id, st.sc);
        try std.testing.expectEqual(@as(u3, 1), st.sct);
    }
}

// RLM is a 4-bit field: 2h-Fh are reserved. Both RLM=2 and RLM=4 (which a
// naive 2-bit mask would accept) must be rejected.
test "invalid_rlm_rejected" {
    _ = try common.ctrl();

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    const out = common.rlData(outb);

    out.* = std.mem.zeroes(spec.RlData);
    out.rlc = c.cpu_to_le16(spec.rlc_rle | 2);
    out.riopsr = 1;
    out.wiopsr = 1;
    out.rbwr = 1;
    out.wbwr = 1;
    var cmd = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 0, 0);
    var r = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);
    try std.testing.expect(!r.ok);
    try std.testing.expectEqual(spec.sc_invalid_field, nvme.status(r.cqe).sc);

    out.rlc = c.cpu_to_le16(spec.rlc_rle | 4);
    r = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);
    std.debug.print("    RLM=4 (reserved): ok={}\n", .{r.ok});
    try std.testing.expect(!r.ok);

    out.* = std.mem.zeroes(spec.RlData);
    _ = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);
}

// Soft limit mode (RLM=1) must be accepted (SLS is advertised).
test "soft_limit_accepted" {
    _ = try common.ctrl();

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    const out = common.rlData(outb);
    out.* = std.mem.zeroes(spec.RlData);
    out.rlc = c.cpu_to_le16(spec.rlc_rle | spec.rlm_soft);
    out.bwsf = 3;
    out.tbwv = c.cpu_to_le64(10);
    out.riopsr = 1;
    out.wiopsr = 1;
    out.rbwr = 1;
    out.wbwr = 1;

    var cmd = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 0, 0);
    const cqe = try common.adminOk(&cmd, common.ptr(outb), spec.rl_map_len);
    try std.testing.expectEqual(@as(u8, 0), nvme.status(cqe).sc);
}

// With RLE set, every ratio byte must be non-zero (Figure RLDB).
test "zero_ratios_rejected" {
    _ = try common.ctrl();

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    const out = common.rlData(outb);
    var cmd = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 0, 0);

    out.* = std.mem.zeroes(spec.RlData);
    out.rlc = c.cpu_to_le16(spec.rlc_rle | spec.rlm_hard);
    var r = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);
    try std.testing.expect(!r.ok);
    try std.testing.expectEqual(spec.sc_invalid_field, nvme.status(r.cqe).sc);

    out.riopsr = 0;
    out.wiopsr = 1;
    out.rbwr = 1;
    out.wbwr = 1;
    r = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);
    std.debug.print("    riopsr=0/wiopsr=1: ok={}\n", .{r.ok});
    try std.testing.expect(!r.ok);

    out.* = std.mem.zeroes(spec.RlData);
    _ = try common.admin(&cmd, common.ptr(outb), spec.rl_map_len);
}

// Async Event Configuration (FID 0Bh): the RLCCN bit round-trips.
test "async_config_rlccn" {
    _ = try common.ctrl();

    var cmd = std.mem.zeroes(vfn.Cmd);
    cmd.features.opcode = spec.admin_set_features;
    cmd.features.fid = spec.feat_async_event_conf;
    cmd.features.cdw11 = c.cpu_to_le32(spec.rlccn);
    _ = try common.adminOk(&cmd, null, 0);

    cmd.features.opcode = spec.admin_get_features;
    const cqe = try common.adminOk(&cmd, null, 0);

    const dw0 = nvme.cqeDw0(cqe);
    std.debug.print("    async event config dw0=0x{x}\n", .{dw0});
    try std.testing.expect(dw0 & spec.rlccn != 0);
}
