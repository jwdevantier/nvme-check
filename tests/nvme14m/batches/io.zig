//! NVMe 1.4 mandatory baseline — I/O queue lifecycle and NVM datapath batch.
//!
//! All I/O-queue activity lives in one program because creating an I/O queue is
//! what makes a later Set Features Number of Queues (07h) illegal — the spec
//! calls that a Command Sequence Error. Keeping queue creation and the
//! datapath here means the `features` program always sees a queue-less
//! controller. The session is opened once by `common.ctrl()` (libvfn
//! `nvme_init`).
//!
//! Tests run in declaration order: queue creation/teardown precedes the
//! round-trip, which needs a live queue.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("common").spec;

/// Submit a raw admin command and return its decoded completion status. The
/// queue-management error probes below need the device status even when
/// libvfn's synchronous helper reports failure, so go through `common.admin`
/// (which still fills the CQE) rather than the libvfn create/delete wrappers.
fn adminStatus(cmd: *vfn.Cmd) !nvme.Status {
    const r = try common.admin(cmd, null, 0);
    return nvme.status(r.cqe);
}

/// Submit a raw command on I/O SQ 1 and return its decoded completion status.
/// A failing command still posts a CQE, which `nvme_rq_spin` consumes here, so
/// successive probes (and a later successful I/O) never see a stale completion.
fn ioStatus(ctrl_: *vfn.Ctrl, cmd: *vfn.Cmd, iova: c.iova_t, len: usize) !nvme.Status {
    const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(rq);

    if (len != 0 and c.nvme_rq_map_prp(ctrl_, rq, cmd, iova, len) != 0)
        return error.MapPrpFailed;

    vfn.rqExec(rq, cmd);
    var cqe = std.mem.zeroes(vfn.Cqe);
    _ = c.nvme_rq_spin(rq, &cqe);
    return nvme.status(cqe);
}

/// Write then read back `buf` at `slba`, letting `nvme_rq_map_prp` build the
/// PRP(s) for `iova`/`buf.len`; the pattern is verified after the read.
fn prpWriteRead(ctrl_: *vfn.Ctrl, iova: c.iova_t, slba: u64, buf: []u8, seed: u8) !void {
    std.debug.assert(buf.len % 512 == 0);
    const nlb: u16 = @intCast(buf.len / 512 - 1);
    for (buf, 0..) |*x, i| x.* = @truncate(i +% seed);

    for ([_]u8{ spec.nvm_write, spec.nvm_read }) |op| {
        if (op == spec.nvm_read) @memset(buf, 0);
        const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
        defer vfn.rqRelease(rq);
        var cmd = spec.rwCmd(op, 1, slba, nlb);
        try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_map_prp(ctrl_, rq, &cmd, iova, buf.len));
        vfn.rqExec(rq, &cmd);
        var cqe = std.mem.zeroes(vfn.Cqe);
        try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_spin(rq, &cqe));
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
    }

    for (buf, 0..) |x, i| try std.testing.expectEqual(@as(u8, @truncate(i +% seed)), x);
}

/// Write then read back `buf` at `slba` with explicit PRP1/PRP2 (used when the
/// list must chain across pages, which `nvme_rq_map_prp` cannot express).
fn prpRoundTripRaw(ctrl_: *vfn.Ctrl, slba: u64, buf: []u8, prp1: u64, prp2: u64, seed: u8) !void {
    const nlb: u16 = @intCast(buf.len / 512 - 1);
    for (buf, 0..) |*x, i| x.* = @truncate(i +% seed);

    var w = spec.rwCmdPrp(spec.nvm_write, 1, slba, nlb, prp1, prp2);
    try std.testing.expectEqual(spec.sc_success, (try ioStatus(ctrl_, &w, 0, 0)).sc);
    @memset(buf, 0);
    var r = spec.rwCmdPrp(spec.nvm_read, 1, slba, nlb, prp1, prp2);
    try std.testing.expectEqual(spec.sc_success, (try ioStatus(ctrl_, &r, 0, 0)).sc);

    for (buf, 0..) |x, i| try std.testing.expectEqual(@as(u8, @truncate(i +% seed)), x);
}

// Create I/O Completion Queue (05h) + I/O Submission Queue (01h), then delete
// the SQ (00h) and CQ (04h). Queue sizes are small; interrupts are disabled
// (vector -1) because the datapath polls.
test "admin Create and Delete IO CQ and SQ" {
    const ctrl_ = try common.ctrl();

    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 8, -1));
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 8, &ctrl_.cq[1], 0));
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_delete_iosq(ctrl_, 1));
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_delete_iocq(ctrl_, 1));
}

// Figure 103 queue-management statuses. The happy path above covers success;
// §5.3.1-§5.3.4 require the command-specific failures below. The invalid-CQ
// probes run before any I/O queue exists; the duplicate/deletion probes need a
// live queue, which the deferred teardown (SQ before CQ, LIFO) removes again so
// the round-trip test below still finds a queue-clean controller.
test "admin Create and Delete IO queue error statuses" {
    const ctrl_ = try common.ctrl();
    const cap = common.regRead64(ctrl_, spec.reg_cap);
    const mqes: u16 = @truncate(cap & 0xffff);

    // A page-aligned, already-mapped PRP1 for the negative probes that pass the
    // QID/QSIZE checks but must fail before a queue is created. Reuse the admin
    // SQ's DMA buffer rather than mapping a throwaway page: a real mapped
    // address keeps the probe honest and needs no extra allocation.
    const prp1 = ctrl_.adminq.sq[0].mem.iova;

    // Create CQ with QID 0 (the Admin CQ) -> Invalid Queue Identifier.
    {
        var cmd = spec.createCqCmd(0, 7, 0, 0, false);
        const st = try adminStatus(&cmd);
        std.debug.print("    create CQ qid 0 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_id, st.sc);
    }

    // Create CQ with an out-of-range QID -> Invalid Queue Identifier.
    {
        var cmd = spec.createCqCmd(0xffff, 7, 0, 0, false);
        const st = try adminStatus(&cmd);
        std.debug.print("    create CQ qid 0xffff -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_id, st.sc);
    }

    // Create CQ with QSIZE 0: fewer than the mandatory two entries (§3.3.3.1),
    // so Invalid Queue Size (Figure 503).
    {
        var cmd = spec.createCqCmd(1, 0, 0, 0, false);
        const st = try adminStatus(&cmd);
        std.debug.print("    create CQ qsize 0 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_size, st.sc);
    }

    // Create CQ with QSIZE above CAP.MQES -> Invalid Queue Size.
    if (mqes != 0xffff) {
        var cmd = spec.createCqCmd(1, mqes + 1, 0, 0, false);
        const st = try adminStatus(&cmd);
        std.debug.print("    create CQ qsize {d} (MQES {d}) -> sct={d} sc=0x{x}\n", .{ mqes + 1, mqes, st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_size, st.sc);
    }

    // Create CQ with an impossible interrupt vector -> Invalid Interrupt
    // Vector (Figure 504/505). PRP1 is page aligned so the QID/QSIZE/PRP
    // checks pass before the vector is inspected.
    {
        var cmd = spec.createCqCmd(1, 7, prp1, 0xffff, true);
        const st = try adminStatus(&cmd);
        std.debug.print("    create CQ iv 0xffff -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_interrupt_vector, st.sc);
    }

    // Queue 1 now has to exist for the duplicate and deletion probes. The CQ
    // defer is registered first so it runs last, after the SQ delete below.
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 8, -1));
    defer _ = c.nvme_delete_iocq(ctrl_, 1);

    // Recreating the live CQ QID -> Invalid Queue Identifier.
    {
        var cmd = spec.createCqCmd(1, 7, prp1, 0, false);
        const st = try adminStatus(&cmd);
        std.debug.print("    duplicate create CQ 1 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_id, st.sc);
    }

    // Create SQ with QID 0 -> Invalid Queue Identifier (CQID 1 is valid so the
    // §5.3.2 CQID precondition is satisfied).
    {
        var cmd = spec.createSqCmd(0, 7, 0, 1);
        const st = try adminStatus(&cmd);
        std.debug.print("    create SQ qid 0 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_id, st.sc);
    }

    // Create SQ with an out-of-range QID -> Invalid Queue Identifier.
    {
        var cmd = spec.createSqCmd(0xffff, 7, 0, 1);
        const st = try adminStatus(&cmd);
        std.debug.print("    create SQ qid 0xffff -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_id, st.sc);
    }

    // Create SQ with QSIZE 0 -> Invalid Queue Size (Figure 507/510).
    {
        var cmd = spec.createSqCmd(1, 0, 0, 1);
        const st = try adminStatus(&cmd);
        std.debug.print("    create SQ qsize 0 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_size, st.sc);
    }

    // Create SQ 1 referencing CQ 1, then attempt to delete the CQ first:
    // §5.3.3 requires Invalid Queue Deletion while an SQ still references it.
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 8, &ctrl_.cq[1], 0));
    defer _ = c.nvme_delete_iosq(ctrl_, 1);

    // Recreating the live SQ QID -> Invalid Queue Identifier.
    {
        var cmd = spec.createSqCmd(1, 7, 0, 1);
        const st = try adminStatus(&cmd);
        std.debug.print("    duplicate create SQ 1 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_id, st.sc);
    }

    {
        var cmd = spec.deleteCqCmd(1);
        const st = try adminStatus(&cmd);
        std.debug.print("    delete CQ 1 with live SQ 1 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expectEqual(spec.sct_cmd_specific, st.sct);
        try std.testing.expectEqual(spec.csc_invalid_queue_deletion, st.sc);
    }
}

// Write → Read → Flush over PRP. The 3-page buffer forces PRP1 + PRP2 and a
// PRP list, so all three data-pointer forms the mandatory baseline uses are
// exercised. The pattern is regenerated after the read and compared. The same
// live queue then exercises the mandatory NVM I/O error completions.
test "io Write Read Flush PRP round-trip" {
    const ctrl_ = try common.ctrl();

    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 16, -1));
    defer _ = c.nvme_delete_iocq(ctrl_, 1);
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 16, &ctrl_.cq[1], 0));
    defer _ = c.nvme_delete_iosq(ctrl_, 1);

    const page = vfntest.page_size;
    const len = 3 * page;
    var dma = try common.dmaMap(len);
    defer dma.deinit();

    for (dma.buf.bytes(), 0..) |*x, i| x.* = @truncate(i / 7 + 0x41);
    const nlb: u16 = @intCast(len / 512 - 1); // 0-based: 24 blocks

    {
        const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
        defer vfn.rqRelease(rq);
        var cmd = spec.rwCmd(spec.nvm_write, 1, 0, nlb);
        try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_map_prp(ctrl_, rq, &cmd, dma.iova, len));
        vfn.rqExec(rq, &cmd);
        var cqe = std.mem.zeroes(vfn.Cqe);
        try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_spin(rq, &cqe));
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
    }

    {
        const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
        defer vfn.rqRelease(rq);
        var cmd = std.mem.zeroes(vfn.Cmd);
        cmd.rw.opcode = spec.nvm_flush;
        cmd.rw.nsid = c.cpu_to_le32(1);
        vfn.rqExec(rq, &cmd);
        var cqe = std.mem.zeroes(vfn.Cqe);
        try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_spin(rq, &cqe));
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
    }

    // scrub, then read the same block range back
    @memset(dma.buf.bytes(), 0xcc);
    {
        const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
        defer vfn.rqRelease(rq);
        var cmd = spec.rwCmd(spec.nvm_read, 1, 0, nlb);
        try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_map_prp(ctrl_, rq, &cmd, dma.iova, len));
        vfn.rqExec(rq, &cmd);
        var cqe = std.mem.zeroes(vfn.Cqe);
        try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_spin(rq, &cqe));
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
    }

    for (dma.buf.bytes(), 0..) |x, i| {
        try std.testing.expectEqual(@as(u8, @truncate(i / 7 + 0x41)), x);
    }
    std.debug.print("    write/read/flush verified {d} bytes over PRP\n", .{len});

    // Figure 109/110 data-pointer shapes, each a write/read round-trip on the
    // same live queue: PRP1 only, PRP1 + a page-aligned PRP2, PRP1 with a
    // non-zero first-entry offset, and a PRP list chained across pages. The
    // 3-page round-trip above already covers the single-page PRP-list form.
    {
        var one = try common.dmaMap(page);
        defer one.deinit();
        var two = try common.dmaMap(2 * page);
        defer two.deinit();
        var off = try common.dmaMap(page);
        defer off.deinit();
        var bad = try common.dmaMap(page);
        defer bad.deinit();
        var data = try common.dmaMap(100 * page);
        defer data.deinit();
        var lists = try common.dmaMap(2 * page);
        defer lists.deinit();

        try prpWriteRead(ctrl_, one.iova, 32, one.buf.bytes(), 0x51);
        try prpWriteRead(ctrl_, two.iova, 64, two.buf.bytes(), 0x52);
        try prpWriteRead(ctrl_, off.iova + 512, 128, off.buf.bytes()[512 .. 512 + 2048], 0x53);

        // Figure 110: a non-zero offset in PRP2 (a second, non-list entry) is
        // PRP Offset Invalid (Figure 102, 13h). A page plus 512 bytes keeps PRP2
        // a direct data pointer rather than a PRP list.
        const bad_nlb: u16 = @intCast((page + 512) / 512 - 1);
        var bad_cmd = spec.rwCmdPrp(spec.nvm_read, 1, 0, bad_nlb, bad.iova, bad.iova + 4);
        const bad_st = try ioStatus(ctrl_, &bad_cmd, 0, 0);
        std.debug.print("    PRP2 offset +4 -> sct={d} sc=0x{x}\n", .{ bad_st.sct, bad_st.sc });
        try std.testing.expectEqual(@as(u3, spec.sct_generic), bad_st.sct);
        try std.testing.expectEqual(spec.sc_prp_offset_invalid, bad_st.sc);

        // A PRP list that crosses a page boundary. PRP2 may carry an offset as
        // the first list pointer, so a 100-page transfer whose first list page
        // holds 63 data entries needs a second list page chained from its last
        // entry (Figure 111/112, §4.3.1). Still under MDTS (100 x 4 KiB).
        const npages = 100;
        const ents1 = 64; // slots in the first list page, incl. the chain pointer
        const off1 = page - ents1 * 8;
        for (0..ents1 - 1) |i| {
            std.mem.writeInt(u64, lists.buf.bytes()[off1 + i * 8 ..][0..8], data.iova + (i + 1) * page, .little);
        }
        std.mem.writeInt(u64, lists.buf.bytes()[off1 + (ents1 - 1) * 8 ..][0..8], lists.iova + page, .little);
        const ents2 = npages - 1 - (ents1 - 1);
        for (0..ents2) |i| {
            std.mem.writeInt(u64, lists.buf.bytes()[page + i * 8 ..][0..8], data.iova + (ents1 + i) * page, .little);
        }
        try prpRoundTripRaw(ctrl_, 256, data.buf.bytes(), data.iova, lists.iova + off1, 0x54);

        std.debug.print("    PRP shapes (PRP1-only, PRP1+PRP2, offset, chained list, bad PRP2) ok\n", .{});
    }

    // I/O error completions (Figure 102), run on the same live queue: LBA Out
    // of Range (80h), Invalid Namespace or Format (0Bh), and a transfer past
    // the controller's Maximum Data Transfer Size (02h). MDTS is a power of two
    // in units of the minimum memory page size, so the limit is
    // 2^MDTS × 2^(12 + CAP.MPSMIN) bytes (BASE@2.3 §5.2.13.2.1). A final valid
    // write proves the failing completions left the completion queue usable.
    {
        var id_ctrl = try vfntest.pageBuffer(4096);
        defer id_ctrl.deinit();
        var id_ns = try vfntest.pageBuffer(4096);
        defer id_ns.deinit();
        var icmd = spec.identifyCmd(spec.cns_ctrl, 0, 0);
        const icqe = try common.adminOk(&icmd, common.ptr(id_ctrl), id_ctrl.bytes().len);
        try std.testing.expectEqual(spec.sc_success, nvme.status(icqe).sc);
        var ncmd = spec.identifyCmd(spec.cns_ns, 0, 1);
        const ncqe = try common.adminOk(&ncmd, common.ptr(id_ns), id_ns.bytes().len);
        try std.testing.expectEqual(spec.sc_success, nvme.status(ncqe).sc);

        const mdts = spec.get8(id_ctrl.bytes(), spec.idc_mdts);
        const nsze = spec.get64(id_ns.bytes(), spec.idns_nsze);
        const cap = common.regRead64(ctrl_, spec.reg_cap);
        const mpsmin: u6 = @truncate((cap >> 48) & 0xf);
        try std.testing.expect(nsze >= 1);

        // SLBA == NSZE is one block past the last valid LBA.
        for ([_]u8{ spec.nvm_read, spec.nvm_write }) |op| {
            var cmd = spec.rwCmd(op, 1, nsze, 0);
            const st = try ioStatus(ctrl_, &cmd, dma.iova, page);
            std.debug.print("    op 0x{x} slba=NSZE -> sct={d} sc=0x{x}\n", .{ op, st.sct, st.sc });
            try std.testing.expectEqual(@as(u3, spec.sct_generic), st.sct);
            try std.testing.expectEqual(spec.sc_lba_out_of_range, st.sc);
        }

        // NSID FFFFFFFFh is not a namespace.
        for ([_]u8{ spec.nvm_read, spec.nvm_write }) |op| {
            var cmd = spec.rwCmd(op, 0xffffffff, 0, 0);
            const st = try ioStatus(ctrl_, &cmd, dma.iova, page);
            std.debug.print("    op 0x{x} nsid=FFFFFFFFh -> sct={d} sc=0x{x}\n", .{ op, st.sct, st.sc });
            try std.testing.expectEqual(@as(u3, spec.sct_generic), st.sct);
            try std.testing.expectEqual(spec.sc_invalid_namespace, st.sc);
        }

        // A transfer larger than MDTS. The NLB alone sets the size and the
        // controller rejects the command before touching the data pointer.
        const shift = @as(u32, mdts) + @as(u32, mpsmin) + 12;
        if (mdts == 0 or shift >= 64) {
            std.debug.print("    mdts={d}: no transfer-size limit; skipping probe\n", .{mdts});
        } else {
            const limit: u64 = @as(u64, 1) << @as(u6, @intCast(shift));
            const blocks: u64 = (limit + page) / 512;
            if (blocks > 0x10000) {
                std.debug.print("    MDTS limit {d} B out of range of one transfer; skipping probe\n", .{limit});
            } else {
                const big_nlb: u16 = @intCast(blocks - 1);
                for ([_]u8{ spec.nvm_read, spec.nvm_write }) |op| {
                    var cmd = spec.rwCmd(op, 1, 0, big_nlb);
                    const st = try ioStatus(ctrl_, &cmd, dma.iova, page);
                    std.debug.print("    op 0x{x} {d} B > MDTS {d} B -> sct={d} sc=0x{x}\n", .{ op, blocks * 512, limit, st.sct, st.sc });
                    try std.testing.expectEqual(@as(u3, spec.sct_generic), st.sct);
                    try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
                }
            }
        }

        // The failing completions did not corrupt the CQ: a valid write still
        // completes and its CQE is drained normally.
        var wcmd = spec.rwCmd(spec.nvm_write, 1, 0, 0);
        const st = try ioStatus(ctrl_, &wcmd, dma.iova, page);
        try std.testing.expectEqual(spec.sc_success, st.sc);
        std.debug.print("    error probes + follow-up write ok\n", .{});
    }
}

// Once any I/O queue has been created the number of queues is fixed for the
// lifetime of the controller: Set Features Number of Queues (07h) must be
// rejected with generic Command Sequence Error (Figure 102, 0Ch), not applied.
// A CQ/SQ pair is created here so the "queues exist" precondition holds
// regardless of what the earlier tests left behind (BASE@2.3 §5.2.26.2.1).
test "admin Set Features Number of Queues after queue creation" {
    const ctrl_ = try common.ctrl();

    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 8, -1));
    defer _ = c.nvme_delete_iocq(ctrl_, 1);
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 8, &ctrl_.cq[1], 0));
    defer _ = c.nvme_delete_iosq(ctrl_, 1);

    var sf = spec.setFeaturesCmd(spec.fid_num_queues, 0, 0);
    const r = try common.admin(&sf, null, 0);
    const st = nvme.status(r.cqe);
    std.debug.print("    numq after I/O queue creation -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
    try std.testing.expect(!r.ok);
    try std.testing.expectEqual(@as(u3, 0), st.sct);
    try std.testing.expectEqual(spec.sc_cmd_sequence_error, st.sc);
}
