//! NVMe 1.4 mandatory baseline — admin error / asynchronous-event batch.
//!
//! These tests drive the admin queue directly (`vfn.rqAcquire` → `rqExec` →
//! `cqGetCqe`/`nvme_rq_spin`) instead of `common.admin()`, because the AER test
//! must reap its own completions: `common.admin()`'s wait path would consume
//! the AER's CQE as a spurious completion for a later command. That direct
//! queue manipulation is why this concern gets its own program/session.
//!
//! Tests run in declaration order; each acquires and releases its own request
//! tracker, so order within the program does not matter.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const common = @import("common");
const spec = @import("common").spec;

/// Submit an admin command on the raw admin queue and return its completion
/// queue entry. `common.admin()`'s wait path could reap an outstanding AER
/// CQE as a spurious completion, so this batch drives the queue itself.
fn submitCqe(cmd: *vfn.Cmd) !vfn.Cqe {
    const ctrl_ = try common.ctrl();
    const rq = vfn.rqAcquire(ctrl_.adminq.sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(rq);
    vfn.rqExec(rq, cmd);
    var cqe = std.mem.zeroes(vfn.Cqe);
    _ = c.nvme_rq_spin(rq, &cqe);
    return cqe;
}

/// As `submitCqe`, returning the decoded completion status.
fn submit(cmd: *vfn.Cmd) !nvme.Status {
    return nvme.status(try submitCqe(cmd));
}

/// As `submitCqe`, with the command's data pointer mapped to the page-aligned
/// DMA buffer at `iova` for `len` bytes (Get Log Page, Identify, ...).
fn submitMapped(cmd: *vfn.Cmd, iova: c.iova_t, len: usize) !nvme.Status {
    const ctrl_ = try common.ctrl();
    const rq = vfn.rqAcquire(ctrl_.adminq.sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(rq);
    if (c.nvme_rq_map_prp(ctrl_, rq, cmd, iova, len) != 0) return error.MapPrpFailed;
    vfn.rqExec(rq, cmd);
    var cqe = std.mem.zeroes(vfn.Cqe);
    _ = c.nvme_rq_spin(rq, &cqe);
    return nvme.status(cqe);
}

/// Poll the admin completion queue until a completion for `cid` arrives,
/// consuming any earlier completions; write the head doorbell once.
fn waitCid(cq: *vfn.Cq, cid: u16) !vfn.Cqe {
    var spins: usize = 0;
    while (spins < 1_000_000) : (spins += 1) {
        const cqe = vfn.cqGetCqe(cq) orelse continue;
        if (cqe.cid == cid) {
            const copy = cqe.*;
            vfn.cqUpdateHead(cq);
            return copy;
        }
    }
    return error.Timeout;
}

/// Poll the admin completion queue until completions for both `cid_a` and
/// `cid_b` have arrived, in whatever order. Consumes and discards any other
/// completions; writes the head doorbell once.
const Pair = struct { a: vfn.Cqe, b: vfn.Cqe };
fn waitPair(cq: *vfn.Cq, cid_a: u16, cid_b: u16) !Pair {
    var got_a = false;
    var got_b = false;
    var a = std.mem.zeroes(vfn.Cqe);
    var b = std.mem.zeroes(vfn.Cqe);
    var spins: usize = 0;
    while (spins < 1_000_000 and !(got_a and got_b)) : (spins += 1) {
        const cqe = vfn.cqGetCqe(cq) orelse continue;
        if (cqe.cid == cid_a) {
            got_a = true;
            a = cqe.*;
        } else if (cqe.cid == cid_b) {
            got_b = true;
            b = cqe.*;
        }
    }
    vfn.cqUpdateHead(cq);
    if (!(got_a and got_b)) return error.Timeout;
    return .{ .a = a, .b = b };
}

/// Figure 142 lists the assigned Admin command opcodes and notes that
/// "Opcodes not listed are reserved": 03h is the gap between Get Log Page
/// (02h) and Delete I/O Completion Queue (04h), so a conformant controller
/// must reject it as an invalid opcode.
const admin_opcode_reserved: u8 = 0x03;

/// Figure 206 leaves 26h-6Fh reserved: no log page may be retrieved with such
/// an LID, so an abort status is required whatever the device supports.
const lid_reserved: u8 = 0x30;

// The admin error-completion matrix. A reserved opcode, a reserved Identify
// CNS and an illegal Get Log Page field are all generic errors (SCT=0, Figure
// 102). A Get Log Page with an unsupported LID is different in kind: BASE
// §5.2.12 requires the *command-specific* Invalid Log Page (SCT=1, SC=09h,
// Figure 103), not generic Invalid Field. Format NVM (80h) is the backlog's
// example for the opcode case, but it is optional (OACS.Format, Figure 328)
// and this controller advertises it, so a reserved opcode is the reliable
// "unsupported opcode" probe; the OACS↔80h relationship is asserted by the
// capability self-consistency test in `inspect.zig`.
test "admin error completions" {
    // 1. Unsupported opcode -> Invalid Command Opcode (Figure 102, 01h).
    {
        var cmd = std.mem.zeroes(vfn.Cmd);
        cmd.unnamed_0.opcode = admin_opcode_reserved;
        const st = try submit(&cmd);
        std.debug.print("    error opcode 0x{x} -> sct={d} sc=0x{x}\n", .{ admin_opcode_reserved, st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_generic, st.sct);
        try std.testing.expectEqual(spec.sc_invalid_opcode, st.sc);
    }

    // 2. Identify with a reserved CNS -> Invalid Field (Figure 102, 02h).
    //    §5.2.13 defines only a handful of CNS values; 0xFE names no structure.
    {
        var cmd = spec.identifyCmd(0xfe, 0, 0);
        const st = try submit(&cmd);
        std.debug.print("    error Identify CNS 0xfe -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_generic, st.sct);
        try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
    }

    // 3. Get Log Page with an unsupported or reserved LID -> Invalid Log Page.
    //    1.4(c) §5.14.2 / Figure 243 defines SC=09h (SCT=1) and returns it "if a
    //    reserved log page is requested"; only controllers compliant with
    //    "versions 1.3 and earlier" may return generic Invalid Field. QEMU is
    //    non-conformant here (it returns generic Invalid Field, SCT=0/SC=02h),
    //    so this failure is recorded in tests/nvme14m/known-qemu-failures.txt.
    {
        var cmd = spec.getLogCmd(lid_reserved, 0, 64);
        const st = try submit(&cmd);
        std.debug.print("    error Get Log LID 0x{x} -> sct={d} sc=0x{x}\n", .{ lid_reserved, st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_log_page, st.sc);
    }

    // 4. Get Log Page with an offset past the end of the log page -> Invalid
    //    Field. Error Information is 64 bytes per entry (Figure 209); LPOL =
    //    1000h is past its end, which Figure 203 requires the controller to
    //    abort with Invalid Field in Command.
    {
        var cmd = spec.getLogCmd(spec.log_error_info, 0, 64);
        cmd.log.lpol = c.cpu_to_le32(0x1000);
        const st = try submit(&cmd);
        std.debug.print("    error Get Log offset 0x1000 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_generic, st.sct);
        try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
    }
}

// AER is mandatory, and so is Abort. Post an AER, abort it, and require both
// completions: Abort success, and the AER completing with Abort Requested.
// This manipulates the admin queue directly, so it uses the request tracker
// API rather than common.admin() (whose wait path would reap the AER's CQE as
// a spurious completion).
test "admin Async Event Request and Abort" {
    const ctrl_ = try common.ctrl();
    const sq = ctrl_.adminq.sq;
    const cq = ctrl_.adminq.cq;

    const aer_rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(aer_rq);
    const aer_cid: u16 = aer_rq.cid | spec.cid_aer;

    var aer = std.mem.zeroes(vfn.Cmd);
    aer.unnamed_0.opcode = spec.admin_async_event;
    aer.unnamed_0.cid = aer_cid;
    vfn.sqExec(sq, &aer);

    const ab_rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(ab_rq);
    var ab = spec.abortCmd(0, aer_cid);
    vfn.rqExec(ab_rq, &ab);

    var got_ab = false;
    var got_aer = false;
    var ab_sc: u8 = 0xff;
    var aer_sc: u8 = 0xff;
    var spins: usize = 0;
    while (spins < 100_000 and !(got_ab and got_aer)) : (spins += 1) {
        const cqe = vfn.cqGetCqe(cq) orelse continue;
        const st = nvme.status(cqe.*);
        if (cqe.cid == ab_rq.cid) {
            got_ab = true;
            ab_sc = st.sc;
        } else if (cqe.cid == aer_cid) {
            got_aer = true;
            aer_sc = st.sc;
        }
    }
    vfn.cqUpdateHead(cq);

    std.debug.print("    AER cid=0x{x} abort cid=0x{x}: ab_sc=0x{x} aer_sc=0x{x}\n", .{ aer_cid, ab_rq.cid, ab_sc, aer_sc });
    try std.testing.expect(got_ab);
    try std.testing.expect(got_aer);
    try std.testing.expectEqual(spec.sc_success, ab_sc);
    try std.testing.expectEqual(spec.sc_abort_req, aer_sc);
}

// The AERL field (Figure 328 byte 259) is a 0's based maximum, so a conformant
// controller holds AERL + 1 AERs outstanding and completes the next one with
// the command-specific "Asynchronous Event Request Limit Exceeded" (Figure
// 149, 05h). Posting AERL + 1 requests also exercises the mandatory
// hold-outstanding rule; the limit is only reachable because those requests
// have not completed. (QEMU: AERL defaults to 3, admin queue 32 entries.)
test "admin Asynchronous Event Request limit" {
    const ctrl_ = try common.ctrl();
    const sq = ctrl_.adminq.sq;
    const cq = ctrl_.adminq.cq;

    var dma = try common.dmaMap(4096);
    defer dma.deinit();
    {
        var id = spec.identifyCmd(spec.cns_ctrl, 0, 0);
        const st = try submitMapped(&id, dma.iova, 4096);
        try std.testing.expectEqual(spec.sc_success, st.sc);
    }
    const b = dma.buf.bytes();
    const aerl = spec.get8(b, spec.idc_aerl);
    const limit = @as(usize, aerl) + 1;
    std.debug.print("    AERL={d} (max {d} outstanding AERs)\n", .{ aerl, limit });

    const max_held = 32;
    if (limit + 1 > @as(usize, @intCast(sq[0].qsize)) or limit > max_held) {
        // AERL exceeds what this admin queue can exercise; the overflow probe
        // would wrap the queue. Not expected: AERL is 3 on the POC and the
        // admin queue is 32 entries.
        std.debug.print("    skipping AERL overflow probe (limit {d} > queue)\n", .{limit});
        return;
    }

    // AERL + 1 requests are within the limit: they must remain outstanding.
    var held: [max_held]*vfn.Rq = undefined;
    var n: usize = 0;
    while (n < limit) : (n += 1) {
        const rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
        held[n] = rq;
        var cmd = std.mem.zeroes(vfn.Cmd);
        cmd.unnamed_0.opcode = spec.admin_async_event;
        cmd.unnamed_0.cid = rq.cid | spec.cid_aer;
        vfn.sqExec(sq, &cmd);
    }

    // The request past the limit must not be held: it completes at once with
    // SCT=1 (command specific), SC=05h (Figure 149).
    {
        const rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
        defer vfn.rqRelease(rq);
        var cmd = std.mem.zeroes(vfn.Cmd);
        cmd.unnamed_0.opcode = spec.admin_async_event;
        cmd.unnamed_0.cid = rq.cid | spec.cid_aer;
        vfn.sqExec(sq, &cmd);
        const cqe = try waitCid(cq, rq.cid | spec.cid_aer);
        const st = nvme.status(cqe);
        std.debug.print("    AER overflow -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_aer_limit, st.sc);
    }

    // Abort every outstanding AER so the queue and request pool are empty for
    // the next test (Abort succeeds; the AER completes with Abort Requested).
    for (held[0..n]) |aer_rq| {
        const ab_rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
        defer vfn.rqRelease(ab_rq);
        const aer_cid = aer_rq.cid | spec.cid_aer;
        var ab = spec.abortCmd(0, aer_cid);
        vfn.rqExec(ab_rq, &ab);
        const pair = try waitPair(cq, ab_rq.cid, aer_cid);
        try std.testing.expectEqual(spec.sc_success, nvme.status(pair.a).sc);
        try std.testing.expectEqual(spec.sc_abort_req, nvme.status(pair.b).sc);
        vfn.rqRelease(aer_rq);
    }
}

// AER "hold outstanding until an event" delivery (§5.2.2). OAES names the
// optional Notice events only; the mandatory SMART/Health events are enabled
// through the SHCW field of the Asynchronous Event Configuration feature
// (Figure 409 bits 7:0), whose bit 1 mirrors the composite-temperature
// Critical Warning (Figure 210). The controller must keep the AER pending
// until the event occurs, then complete it with AET=001b (SMART/Health), the
// feature's AEI (Figure 153) and LID=02h (Figure 150).
test "admin asynchronous event delivery" {
    const ctrl_ = try common.ctrl();
    const sq = ctrl_.adminq.sq;
    const cq = ctrl_.adminq.cq;

    var dma = try common.dmaMap(4096);
    defer dma.deinit();

    // Remember the current composite over-temperature threshold (Feature 04h
    // whose CDW11 selects THSEL=over, TMPSEL=composite, Figure 407) so it can
    // be restored. Its CQE Dword 0 is the threshold value.
    var get = spec.getFeaturesCmd(spec.fid_temp_thresh, spec.sel_current, 0);
    const before = try submitCqe(&get);
    try std.testing.expectEqual(spec.sc_success, nvme.status(before).sc);
    const default_thresh: u16 = @truncate(nvme.cqeDw0(before) & 0xffff);

    // Enable the SMART/Health temperature-threshold event.
    var en = spec.setFeaturesCmd(spec.fid_async_event_conf, 0, spec.smart_temp_thresh);
    try std.testing.expectEqual(spec.sc_success, (try submit(&en)).sc);

    // Post an AER. It must stay outstanding: no completion may appear before
    // an event occurs.
    const aer_rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(aer_rq);
    const aer_cid = aer_rq.cid | spec.cid_aer;
    var aer = std.mem.zeroes(vfn.Cmd);
    aer.unnamed_0.opcode = spec.admin_async_event;
    aer.unnamed_0.cid = aer_cid;
    vfn.sqExec(sq, &aer);
    try std.testing.expect(vfn.cqGetCqe(cq) == null);

    // Induce the event: set the over-temperature threshold below the current
    // composite temperature (Figure 407 TMPTH in Kelvins). Its completion and
    // the AER completion race, so reap both by cid.
    const sf_rq = vfn.rqAcquire(sq) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(sf_rq);
    var set = spec.setFeaturesCmd(spec.fid_temp_thresh, 0, 1);
    vfn.rqExec(sf_rq, &set);
    const pair = try waitPair(cq, aer_cid, sf_rq.cid);
    try std.testing.expectEqual(spec.sc_success, nvme.status(pair.a).sc);
    try std.testing.expectEqual(spec.sc_success, nvme.status(pair.b).sc);

    const dw0 = nvme.cqeDw0(pair.a);
    const aet: u3 = @truncate(dw0 & 0x7);
    const aei: u8 = @truncate((dw0 >> 8) & 0xff);
    const lid: u8 = @truncate((dw0 >> 16) & 0xff);
    std.debug.print("    AER event AET={d} AEI=0x{x} LID=0x{x}\n", .{ aet, aei, lid });
    try std.testing.expectEqual(spec.aet_smart, aet);
    try std.testing.expectEqual(spec.aei_smart_temp_thresh, aei);
    try std.testing.expectEqual(spec.log_smart, lid);

    // Clear the event by reading the SMART/Health log with RAE=0 (Figure 201
    // bit 15) and the controller-wide broadcast NSID; then restore the
    // threshold so the critical warning clears.
    var gl = spec.getLogCmd(spec.log_smart, 0xffffffff, 512);
    const gst = try submitMapped(&gl, dma.iova, 512);
    std.debug.print("    SMART clear: sct={d} sc=0x{x} (threshold {d})\n", .{ gst.sct, gst.sc, default_thresh });
    try std.testing.expectEqual(spec.sc_success, gst.sc);

    var restore = spec.setFeaturesCmd(spec.fid_temp_thresh, 0, default_thresh);
    try std.testing.expectEqual(spec.sc_success, (try submit(&restore)).sc);
}
