//! NVMe 1.4 mandatory baseline — controller reset batch.
//!
//! This program is where the `CC.EN` reset/enable state machine is exercised.
//! It is deliberately isolated from every other batch: clearing `CC.EN`
//! destroys libvfn's cached admin/I/O queues, so any test sharing this session
//! would be reading a stale controller.
//!
//! The test drives the CC.EN reset/enable sequence (Figure 78, §3.1.5) through
//! BAR0 only: it clears `CC.EN`, waits for `CSTS.RDY` to clear, checks
//! `CSTS.CFS`, re-programs `AQA`/`ASQ`/`ACQ` (legal only while disabled), and
//! re-enables the controller with a brand-new Admin queue. Because libvfn's
//! queue bookkeeping (tail, head, phase, and doorbell-buffer config) was
//! invalidated by the reset, the post-reset verification talks to the new queue
//! directly rather than through `common.admin()`.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("common").spec;

/// Monotonic milliseconds (std.time in this Zig version is constants only).
fn monoMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Spin until CSTS.RDY equals `want_ready`, up to `to_ms`. Figure 79 and
/// §7.6.1: the host waits for RDY after every `CC.EN` transition, bounded by
/// `CAP.TO`.
fn waitRdy(ctrl_: *vfn.Ctrl, want_ready: bool, to_ms: i64) !void {
    const deadline = monoMs() + to_ms;
    while (monoMs() < deadline) {
        const ready = (common.regRead32(ctrl_, spec.reg_csts) & spec.csts_rdy) != 0;
        if (ready == want_ready) return;
        std.atomic.spinLoopHint();
    }
    return error.Timeout;
}

/// Submit one Admin command on the freshly programmed Admin queue and return
/// its full 16-byte completion. Goes raw because the Controller Reset
/// invalidated libvfn's cached admin queue state (tail/head/phase and the
/// doorbell-buffer config); this also proves the re-programmed AQA/ASQ/ACQ are
/// the queue the controller is really using.
///
/// `slot` is the 0-based ring index of the command. A queue the controller has
/// just initialised starts with every Phase Tag set to '1' (Figure 126,
/// §3.1.5); while fewer than the queue depth of commands are issued, each
/// completion therefore lands in the matching slot with phase 1 and no slot is
/// reused.
fn rawAdmin(ctrl_: *vfn.Ctrl, asq: *const common.Dma, acq: []u8, cmd: *const c.nvme_cmd, slot: u32) !vfn.Cqe {
    const sqe_off = slot * 64;
    @memcpy(asq.buf.bytes()[sqe_off .. sqe_off + 64], std.mem.asBytes(cmd));
    common.dbWrite32(ctrl_, spec.dbl_sq0tdbl, slot + 1); // tail -> next slot

    const cqe_off = slot * 16;
    const raw: *const [16]u8 = @ptrCast(acq.ptr + cqe_off);
    const deadline = monoMs() + 5000;
    while (monoMs() < deadline) {
        const sfp = std.mem.readInt(u16, raw[14..16], .little);
        if (sfp & 1 != 0) { // controller-set phase tag marks the entry valid
            common.dbWrite32(ctrl_, spec.dbl_cq0hdbl, slot + 1); // reap slot
            var cqe: vfn.Cqe = undefined;
            @memcpy(std.mem.asBytes(&cqe), raw);
            return cqe;
        }
        std.atomic.spinLoopHint();
    }
    return error.Timeout;
}

/// Thin wrapper: issue Get Features (SEL=current) as the first command on the
/// fresh queue (slot 0) and return the CQE command-specific dword. A success is
/// required of the probe itself.
fn rawGetFeature(ctrl_: *vfn.Ctrl, asq: *const common.Dma, acq: []u8, fid: u8) !u32 {
    var cmd = spec.getFeaturesCmd(fid, spec.sel_current, 0);
    const cqe = try rawAdmin(ctrl_, asq, acq, &cmd, 0);
    const st = nvme.status(cqe);
    try std.testing.expectEqual(spec.sct_generic, st.sct);
    try std.testing.expectEqual(spec.sc_success, st.sc);
    return nvme.cqeDw0(cqe);
}

test "controller reset / enable state machine" {
    const ctrl_ = try common.ctrl();
    const page = vfntest.page_size;

    // Figure 69: CAP.TO is in 500 ms units (a value of 0 means 500 ms).
    const cap = common.regRead64(ctrl_, spec.reg_cap);
    const to_ms: i64 = 500 * @as(i64, @intCast(((cap >> 24) & 0xff) + 1));

    // The libvfn session (reset -> admin queue -> enable -> Identify) must have
    // left the controller enabled and ready.
    try std.testing.expectEqual(spec.csts_rdy, common.regRead32(ctrl_, spec.reg_csts) & spec.csts_rdy);

    // Capture the AEC Feature's default value while libvfn's admin queue is
    // still valid. Figure 78 (CC.EN) requires a Controller Reset to reset
    // non-persistent Feature values "to their default values", and §5.21.1 /
    // Figure 275 (FID 0Bh) confirms AEC does not persist across a reset. The
    // default itself is vendor specific (§7.8), so read it back with
    // SEL=default rather than assuming it is 0h.
    var get_aec_default = spec.getFeaturesDefault(spec.fid_async_event_conf, 0);
    const aec_default = nvme.cqeDw0(try common.adminOk(&get_aec_default, null, 0));

    // Create I/O CQ and SQ qid 1 so the reset's mandate to delete every I/O
    // queue (Figure 78) has something to delete; both creations must succeed.
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 8, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 8, &ctrl_.cq[1], 0));

    // Put a known, non-default value into AEC so the reset's restoration to
    // the default is observable.
    var set_aec = spec.setFeaturesCmd(spec.fid_async_event_conf, 0, 0x7f);
    _ = try common.adminOk(&set_aec, null, 0);

    const cc_before = common.regRead32(ctrl_, spec.reg_cc);
    const aqa_before = common.regRead32(ctrl_, spec.reg_aqa);
    const asq_before = common.regRead64(ctrl_, spec.reg_asq);
    const acq_before = common.regRead64(ctrl_, spec.reg_acq);

    // 1. CC.EN 1 -> 0 is a Controller Reset (Figure 78 EN, §3.1.5): the
    // controller is brought to idle and CSTS.RDY is cleared to 0.
    common.regWrite32(ctrl_, spec.reg_cc, cc_before & ~spec.cc_en);
    try waitRdy(ctrl_, false, to_ms);

    // Figure 78: that reset "reset[s] ... [all other] controller registers
    // defined in this section ... to their default values". CC's reset value is
    // 0h, so after the reset the whole register — including the transport fields
    // (MPS/CSS/IOSQES/IOCQES) the host had written — reads back 0h, not just EN.
    try std.testing.expectEqual(@as(u32, 0), common.regRead32(ctrl_, spec.reg_cc));

    // 2. A clean reset must not latch a fatal controller error.
    const csts = common.regRead32(ctrl_, spec.reg_csts);
    try std.testing.expectEqual(@as(u32, 0), csts & spec.csts_rdy);
    try std.testing.expectEqual(@as(u32, 0), csts & spec.csts_cfs);

    // AQA/ASQ/ACQ are the documented exception: a Controller Reset must leave
    // them untouched (Figure 78, §3.1.5).
    try std.testing.expectEqual(aqa_before, common.regRead32(ctrl_, spec.reg_aqa));
    try std.testing.expectEqual(asq_before, common.regRead64(ctrl_, spec.reg_asq));
    try std.testing.expectEqual(acq_before, common.regRead64(ctrl_, spec.reg_acq));

    // 3. Re-program AQA/ASQ/ACQ (legal only while CC.EN is 0) onto fresh pages,
    // then re-enable. The reset also cleared CC, so re-write its transport
    // fields (CSS/MPS/IOSQES/IOCQES) as well as EN.
    const admin_entries: u32 = 8; // ASQS/ACQS are 0-based; must be >= 2
    var asq = try common.dmaMap(page);
    defer asq.deinit();
    var acq = try common.dmaMap(page);
    defer acq.deinit();
    common.regWrite32(ctrl_, spec.reg_aqa, (admin_entries - 1) | ((admin_entries - 1) << 16));
    common.regWrite64(ctrl_, spec.reg_asq, asq.iova);
    common.regWrite64(ctrl_, spec.reg_acq, acq.iova);
    common.regWrite32(ctrl_, spec.reg_cc, cc_before | spec.cc_en);
    try waitRdy(ctrl_, true, to_ms);

    // 4. The re-programmed queue is live: a Get Features completes on it. This
    // proves the controller really is running on the new AQA/ASQ/ACQ.
    const aec_after = try rawGetFeature(ctrl_, &asq, acq.buf.bytes(), spec.fid_async_event_conf);
    std.debug.print("    reset: new admin queue live (AEC 0Bh current=0x{x}, default=0x{x})\n", .{ aec_after, aec_default });

    // Figure 78 / §5.21.1 / §7.8: the Controller Reset must have set the
    // non-persistent AEC Feature back to its default (0x7f was written before
    // the reset). QEMU does not rewrite n->features on a Controller Reset, so
    // the 0x7f reads back unchanged — a known non-conformance recorded in
    // known-qemu-failures.txt.
    try std.testing.expectEqual(aec_default, aec_after);

    // 5. Figure 78 also requires the Controller Reset to delete all I/O
    // Submission and Completion Queues. qid 1 was created above, so a Delete
    // must now find no such queue: §5.6.1/Figure 163 (Delete I/O SQ) and
    // §5.5.1/Figure 161 (Delete I/O CQ) both return Invalid Queue Identifier
    // (SC=01h) with a Command Specific status type (SCT=1, Figure 130) — it is
    // *not* the generic status code 01h, which is Invalid Command Opcode
    // (Figure 128).
    var del_sq = spec.deleteSqCmd(1);
    const sq_cqe = try rawAdmin(ctrl_, &asq, acq.buf.bytes(), &del_sq, 1);
    const sq_st = nvme.status(sq_cqe);
    std.debug.print("    reset: delete I/O SQ qid 1 -> SCT={d} SC=0x{x}\n", .{ sq_st.sct, sq_st.sc });
    try std.testing.expectEqual(@as(u3, 1), sq_st.sct);
    try std.testing.expectEqual(spec.csc_invalid_queue_id, sq_st.sc);

    var del_cq = spec.deleteCqCmd(1);
    const cq_cqe = try rawAdmin(ctrl_, &asq, acq.buf.bytes(), &del_cq, 2);
    const cq_st = nvme.status(cq_cqe);
    std.debug.print("    reset: delete I/O CQ qid 1 -> SCT={d} SC=0x{x}\n", .{ cq_st.sct, cq_st.sc });
    try std.testing.expectEqual(@as(u3, 1), cq_st.sct);
    try std.testing.expectEqual(spec.csc_invalid_queue_id, cq_st.sc);
}
