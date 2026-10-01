//! TP4176 batch: the full AER flow (RLCCN). This one manipulates the admin
//! queue directly, so it runs as its own batch / VM session.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("common").spec;

const aer_wait_ms: i64 = 10_000; // s390x/TCG can be slow to deliver the event

fn nowMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// Enable RLCCN, post an AER, change the rate limiting configuration, and wait
// for the Notice event (type 2h, info 0Ah, LID 28h) to complete the AER.
test "aer_rate_limit_change" {
    const ctrl = try common.ctrl();

    // enable RLCCN (Async Event Configuration, FID 0Bh, bit 22)
    var cmd = std.mem.zeroes(vfn.Cmd);
    cmd.features.opcode = spec.admin_set_features;
    cmd.features.fid = spec.feat_async_event_conf;
    cmd.features.cdw11 = c.cpu_to_le32(spec.rlccn);
    _ = try common.adminOk(&cmd, null, 0);

    const sq = ctrl.adminq.sq;
    const cq = ctrl.adminq.cq;

    // Post the AER via a request tracker for a collision-free cid, but submit
    // with sq_exec (rq_exec overwrites the cid) so it carries the AER bit —
    // exactly what libvfn's own nvme_aer() does.
    const rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(rq);
    const aer_cid: u16 = rq.cid | spec.cid_aer;
    var aer = std.mem.zeroes(vfn.Cmd);
    aer.unnamed_0.opcode = spec.admin_async_event;
    aer.unnamed_0.cid = aer_cid;
    vfn.sqExec(sq, &aer);

    // trigger a config change via a request tracker -- NOT common.admin(),
    // whose wait path would drain and advance past the AER's completion.
    var outb = try vfntest.pageBuffer(spec.rl_map_len);
    defer outb.deinit();
    const out = common.rlData(outb);
    out.* = std.mem.zeroes(spec.RlData);
    out.rlc = c.cpu_to_le16(spec.rlc_rle | spec.rlm_hard);
    out.bwsf = 3;
    out.tbwv = c.cpu_to_le64(1234);
    out.riopsr = 1;
    out.wiopsr = 1;
    out.rbwr = 1;
    out.wbwr = 1;
    // Trigger the config change via a request tracker -- NOT common.admin(),
    // whose wait path would drain and advance past the AER's completion. The
    // feature buffer is DMA data, and nvme_rq_exec() does not set up the PRP,
    // so map the buffer and build the PRP ourselves, exactly as nvme_sync()
    // does for nvme_admin().
    const iommu_ctx = c.__iommu_ctx(ctrl);
    const outv: ?*anyopaque = common.ptr(outb);
    var iova: c.iova_t = 0;
    const need_unmap = !c.iommu_translate_vaddr(iommu_ctx, outv, &iova);
    if (need_unmap and
        c.iommu_map_vaddr(iommu_ctx, outv, spec.rl_map_len, &iova, c.IOMMU_MAP_EPHEMERAL) != 0)
        return error.IommuMapFailed;
    defer {
        if (need_unmap) _ = c.iommu_unmap_vaddr(iommu_ctx, outv, null);
    }

    var sf = spec.rlFeaturesCmd(spec.admin_set_features, common.cntlid(), 0, 0);
    const sf_rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(sf_rq);
    if (c.nvme_rq_map_prp(ctrl, sf_rq, &sf, iova, spec.rl_map_len) != 0)
        return error.PrpMapFailed;
    vfn.rqExec(sf_rq, &sf);

    std.debug.print("    cids: aer=0x{x} sf=0x{x}\n", .{ aer_cid, sf_rq.cid });
    std.debug.print("    cq: id={d} qsize={d} head={d} phase={d}\n", .{ cq[0].id, cq[0].qsize, cq[0].head, cq[0].phase });

    // one loop captures both completions
    var got: ?*vfn.Cqe = null;
    var sf_got: ?*vfn.Cqe = null;
    var aer_dw0: u32 = 0;
    var iters: usize = 0;
    const deadline = nowMs() + aer_wait_ms;
    while (nowMs() < deadline and (got == null or sf_got == null)) {
        iters += 1;
        const cqe = vfn.cqGetCqe(cq) orelse continue;
        const st = nvme.status(cqe.*);
        std.debug.print("    cqe cid=0x{x} sc=0x{x} sct={d}\n", .{ cqe.cid, st.sc, st.sct });
        if (cqe.cid == sf_rq.cid and sf_got == null) {
            sf_got = cqe;
        } else if (cqe.cid == aer_cid and got == null) {
            got = cqe;
            aer_dw0 = nvme.cqeDw0(cqe.*);
        }
    }
    std.debug.print("    loop end: iters={d} head={d} phase={d} got={} sf_got={}\n", .{
        iters, cq[0].head, cq[0].phase, got != null, sf_got != null,
    });
    vfn.cqUpdateHead(cq);

    try std.testing.expect(sf_got != null);

    if (got) |g| {
        std.debug.print("    AER: cid=0x{x} dw0=0x{x} type={d} info=0x{x} lid=0x{x}\n", .{
            g.cid, aer_dw0, spec.aerType(aer_dw0), spec.aerInfo(aer_dw0), spec.aerLid(aer_dw0),
        });
        try std.testing.expectEqual(aer_cid, g.cid);
        try std.testing.expectEqual(spec.aer_type_notice, spec.aerType(aer_dw0));
        try std.testing.expectEqual(spec.aer_info_rate_limit_chg, spec.aerInfo(aer_dw0));
        try std.testing.expectEqual(spec.aer_lid_rate_limit, spec.aerLid(aer_dw0));
    } else {
        std.debug.print("    AER did not complete within {d}ms\n", .{aer_wait_ms});
    }

    // best-effort abort (already completed; ianp=1 is the expected case)
    var abort = std.mem.zeroes(vfn.Cmd);
    abort.unnamed_0.opcode = spec.admin_abort;
    abort.unnamed_0.cdw10 = c.cpu_to_le32(@as(u32, aer_cid) << 16);
    const head_before = cq[0].head;
    const ar = try common.admin(&abort, null, 0);
    std.debug.print("    abort of AER cid 0x{x}: ianp={d} head {d}->{d}\n", .{
        aer_cid, nvme.cqeDw0(ar.cqe) & 1, head_before, cq[0].head,
    });

    try std.testing.expect(got != null);
}
