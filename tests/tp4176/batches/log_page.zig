//! TP4176 batch: Rate Limiting log page 28h (structure + generation count).

const std = @import("std");
const c = @import("vfn_c");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("spec");

// Get Log Page 28h: header sanity and descriptor cross-references. Port list
// entries are *dword* offsets into the log page (Figure NewFig); the
// controller descriptor's CNTLID must match the id learned by Identify.
test "log_page_structure" {
    _ = try common.ctrl();

    var buf = try vfntest.pageBuffer(spec.log_len);
    defer buf.deinit();

    var cmd = spec.getRateLimitLogCmd(spec.log_len);
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(@as(u8, 0), nvme.status(cqe).sc);

    const bytes = buf.bytes();
    const np = spec.get16(bytes, spec.lp_np);
    const lpl = spec.get32(bytes, spec.lp_lpl);
    const gc = spec.get32(bytes, spec.lp_gc);
    const nst = spec.get16(bytes, spec.lp_nst);
    std.debug.print("    log 28h header: np={d} lpl={d} ({d} bytes) gc={d} nst={d}\n", .{ np, lpl, lpl * 4, gc, nst });

    try std.testing.expectEqual(@as(u16, 0), np);
    try std.testing.expectEqual(@as(u16, 0), nst);
    try std.testing.expect(lpl >= 16);

    const port_dw = spec.get32(bytes, spec.lp_port_list);

    // spec interpretation: descriptor at byte offset port_dw*4
    var spec_ok = false;
    if (@as(usize, port_dw) * 4 + spec.pd_size <= @as(usize, lpl) * 4) {
        spec_ok = spec.get16(bytes, @as(usize, port_dw) * 4 + spec.pd_portid) == 0;
    }
    // defensive: also try a byte-offset interpretation and report it
    var byte_ok = false;
    if (@as(usize, port_dw) + spec.pd_size <= @as(usize, lpl) * 4) {
        byte_ok = spec.get16(bytes, @as(usize, port_dw) + spec.pd_portid) == 0;
    }
    std.debug.print("    port_list[0]={d}: dword-offset valid={} byte-offset valid={}\n", .{ port_dw, spec_ok, byte_ok });
    try std.testing.expect(spec_ok);

    if (byte_ok) {
        const ctrl_off = @as(usize, port_dw) + spec.pd_size;
        const cd_off = @as(usize, spec.get32(bytes, ctrl_off));
        const cntlid = spec.get16(bytes, cd_off + spec.cd_cntlid);
        const nnsmad = spec.get16(bytes, cd_off + spec.cd_nnsmad);
        std.debug.print("    ctrl descriptor: cntlid={d} nnsmad={d} (mine={d})\n", .{ cntlid, nnsmad, common.cntlid() });
        try std.testing.expectEqual(common.cntlid(), cntlid);
    }
}

// The Generation Count in the log page header increments when the rate
// limiting configuration changes.
test "gen_count_increments" {
    _ = try common.ctrl();

    var buf = try vfntest.pageBuffer(spec.log_len);
    defer buf.deinit();
    var logcmd = spec.getRateLimitLogCmd(spec.log_len);
    _ = try common.adminOk(&logcmd, common.ptr(buf), buf.bytes().len);
    const gc1 = spec.get32(buf.bytes(), spec.lp_gc);

    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    const out = common.rlData(outb);
    out.* = std.mem.zeroes(spec.RlData);
    out.rlc = c.cpu_to_le16(spec.rlc_rle | spec.rlm_hard);
    out.tbwv = c.cpu_to_le64(200);
    out.riopsr = 1;
    out.wiopsr = 1;
    out.rbwr = 1;
    out.wbwr = 1;

    var sf = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 0, 0);
    _ = try common.adminOk(&sf, common.ptr(outb), spec.rl_map_len);

    _ = try common.adminOk(&logcmd, common.ptr(buf), buf.bytes().len);
    const gc2 = spec.get32(buf.bytes(), spec.lp_gc);
    std.debug.print("    gc before={d} after={d}\n", .{ gc1, gc2 });
    try std.testing.expectEqual(gc1 + 1, gc2);
}
