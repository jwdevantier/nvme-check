//! NVMe 1.4 mandatory-baseline batch — one VM session, one test binary, a
//! series of `test {}` blocks.
//!
//! Scope (see ~/nvme-1.4.poc.overview.md): *only* mandatory behavior of an
//! NVMe over PCIe I/O controller — transport registers, the mandatory admin
//! commands, the mandatory Get/Set Features IDs, the mandatory log pages, the
//! four Identify CNS structures, and NVM Read/Write/Flush over PRP. Optional
//! material (Format NVM, SGL, CMB/PMR, telemetry, reservations, ...) is not
//! exercised.
//!
//! The controller is opened once (libvfn `nvme_init`: reset → admin queue →
//! enable → Identify) and every test builds on it. Tests run in declaration
//! order, which matters in one place: Set Features Number of Queues is only
//! legal while no I/O queue has been created, so the queue and I/O tests come
//! last.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("common").spec;

// --- §0 transport / controller scaffolding --------------------------------

// BAR0 registers are readable and the controller is enabled: CC.EN=1 with the
// mandatory entry sizes, CSTS.RDY=1, admin queue programmed, and a VS at or
// above 1.4.
test "transport registers and controller enable state" {
    const ctrl_ = try common.ctrl();

    const cap = common.regRead64(ctrl_, spec.reg_cap);
    const vs = common.regRead32(ctrl_, spec.reg_vs);
    const cc = common.regRead32(ctrl_, spec.reg_cc);
    const csts = common.regRead32(ctrl_, spec.reg_csts);
    const aqa = common.regRead32(ctrl_, spec.reg_aqa);
    const asq = common.regRead64(ctrl_, spec.reg_asq);
    const acq = common.regRead64(ctrl_, spec.reg_acq);
    std.debug.print("    CAP=0x{x} VS=0x{x} CC=0x{x} CSTS=0x{x}\n", .{ cap, vs, cc, csts });

    const mqes = cap & 0xffff;
    const mpsmin = (cap >> 48) & 0xf;
    const mpsmax = (cap >> 52) & 0xf;
    try std.testing.expect(mqes >= 1);
    try std.testing.expect(mpsmin <= mpsmax);

    const major = vs >> 16;
    const minor = (vs >> 8) & 0xff;
    try std.testing.expect(major > 1 or (major == 1 and minor >= 4));

    try std.testing.expect(cc & 0x1 == 1); // CC.EN
    try std.testing.expect(csts & 0x1 == 1); // CSTS.RDY
    try std.testing.expectEqual(@as(u32, 6), (cc >> 16) & 0xf); // CC.IOSQES
    try std.testing.expectEqual(@as(u32, 4), (cc >> 20) & 0xf); // CC.IOCQES

    // Admin queue attributes/base addresses are programmed (ASQS/ACQS are
    // 0-based, so a value of 0 is legal; the base pointers must not be).
    _ = aqa;
    try std.testing.expect(asq != 0);
    try std.testing.expect(acq != 0);
}

// MSI-X is the controller's interrupt transport and the register block is a
// single memory BAR: BAR0. BAR2 (CMB) / BAR4 (PMR or MSI-X-exclusive) are
// unclaimed, which is what "one BAR" means for a 1.4 controller.
test "transport one memory BAR and MSI-X capability" {
    const ctrl_ = try common.ctrl();

    const command = common.cfgRead16(ctrl_, 0x04);
    try std.testing.expect(command & 0x2 != 0); // memory space enable
    try std.testing.expect(command & 0x4 != 0); // bus master enable

    const bar0 = common.cfgRead32(ctrl_, 0x10);
    try std.testing.expect(bar0 & 0x1 == 0); // memory BAR, not I/O

    // BAR2..BAR5: no CMB (BAR2), no PMR / MSI-X-exclusive BAR (BAR4).
    inline for (.{ 0x18, 0x1c, 0x20, 0x24 }) |off| {
        try std.testing.expectEqual(@as(u32, 0), common.cfgRead32(ctrl_, off) & 0xfffffff0);
    }

    // Walk the PCI capability list for MSI-X (capability ID 0x11).
    try std.testing.expect(common.cfgRead16(ctrl_, 0x06) & 0x10 != 0);
    var cap: u8 = common.cfgRead8(ctrl_, 0x34) & 0xfc;
    var found = false;
    var guard: usize = 0;
    while (cap != 0 and guard < 48) : (guard += 1) {
        if (common.cfgRead8(ctrl_, cap) == 0x11) {
            const mc = common.cfgRead16(ctrl_, @as(u64, cap) + 2);
            const vectors = (mc & 0x7ff) + 1;
            std.debug.print("    MSI-X: vectors={d} enabled={}\n", .{ vectors, mc & 0x8000 != 0 });
            try std.testing.expect(vectors >= 1);
            found = true;
            break;
        }
        cap = common.cfgRead8(ctrl_, @as(u64, cap) + 1) & 0xfc;
    }
    try std.testing.expect(found);
}

// INTMS sets and INTMC clears interrupt mask bits; reading INTMS reflects the
// current mask.
test "transport interrupt masking INTMS INTMC" {
    const ctrl_ = try common.ctrl();

    const initial = common.regRead32(ctrl_, spec.reg_intms);
    common.regWrite32(ctrl_, spec.reg_intms, 1);
    try std.testing.expect(common.regRead32(ctrl_, spec.reg_intms) & 1 == 1);
    common.regWrite32(ctrl_, spec.reg_intmc, 1);
    try std.testing.expect(common.regRead32(ctrl_, spec.reg_intms) & 1 == 0);

    // restore the mask we found
    common.regWrite32(ctrl_, spec.reg_intmc, 0xffffffff);
    common.regWrite32(ctrl_, spec.reg_intms, initial);
}

// --- §1.1 mandatory admin commands / §5 mandatory Identify structures -----

test "admin Identify Controller mandatory fields" {
    const ctrl_ = try common.ctrl();
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    var cmd = spec.identifyCmd(spec.cns_ctrl, 0, 0);
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);

    const b = buf.bytes();
    const vid = spec.get16(b, spec.idc_vid);
    const ssvid = spec.get16(b, spec.idc_ssvid);
    const sn = b[spec.idc_sn .. spec.idc_sn + 20];
    const mn = b[spec.idc_mn .. spec.idc_mn + 40];
    const ver = spec.get32(b, spec.idc_ver);
    const mdts = spec.get8(b, spec.idc_mdts);
    const cntlid = spec.get16(b, spec.idc_cntlid);
    const oacs = spec.get16(b, spec.idc_oacs);
    const acl = spec.get8(b, spec.idc_acl);
    const aerl = spec.get8(b, spec.idc_aerl);
    const frmw = spec.get8(b, spec.idc_frmw);
    const lpa = spec.get8(b, spec.idc_lpa);
    const elpe = spec.get8(b, spec.idc_elpe);
    const npss = spec.get8(b, spec.idc_npss);
    const sqes = spec.get8(b, spec.idc_sqes);
    const cqes = spec.get8(b, spec.idc_cqes);
    const nn = spec.get32(b, spec.idc_nn);
    const oncs = spec.get16(b, spec.idc_oncs);
    const fna = spec.get8(b, spec.idc_fna);
    const vwc = spec.get8(b, spec.idc_vwc);
    const awun = spec.get16(b, spec.idc_awun);
    const awupf = spec.get16(b, spec.idc_awupf);
    const acwu = spec.get16(b, spec.idc_acwu);
    const sgls = spec.get32(b, spec.idc_sgls);
    const subnqn = b[spec.idc_subnqn .. spec.idc_subnqn + 256];

    std.debug.print("    id-ctrl: vid=0x{x} ssvid=0x{x} ver=0x{x} cntlid={d} mdts={d}\n", .{ vid, ssvid, ver, cntlid, mdts });
    std.debug.print("    id-ctrl: oacs=0x{x} acl={d} aerl={d} frmw=0x{x} lpa=0x{x} elpe={d} npss={d}\n", .{ oacs, acl, aerl, frmw, lpa, elpe, npss });
    std.debug.print("    id-ctrl: sqes=0x{x} cqes=0x{x} nn={d} oncs=0x{x} fna=0x{x} vwc=0x{x}\n", .{ sqes, cqes, nn, oncs, fna, vwc });
    std.debug.print("    id-ctrl: awun={d} awupf={d} acwu={d} sgls=0x{x}\n", .{ awun, awupf, acwu, sgls });

    // VER is the supported base specification version and must match VS.
    const vs = common.regRead32(ctrl_, spec.reg_vs);
    try std.testing.expectEqual(vs, ver);
    try std.testing.expect(ver >= 0x00010400);

    // Serial number / model number are populated printable ASCII.
    for (sn) |ch| try std.testing.expect(ch == ' ' or (ch >= 0x20 and ch < 0x7f));
    for (mn) |ch| try std.testing.expect(ch == ' ' or (ch >= 0x20 and ch < 0x7f));
    try std.testing.expect(!std.mem.eql(u8, sn, "                    "));
    try std.testing.expect(!std.mem.eql(u8, mn, "                                        "));

    // SQES/CQES: minimum and maximum entry sizes are the fixed NVMe values.
    try std.testing.expectEqual(@as(u8, 6), sqes & 0xf);
    try std.testing.expectEqual(@as(u8, 6), sqes >> 4);
    try std.testing.expectEqual(@as(u8, 4), cqes & 0xf);
    try std.testing.expectEqual(@as(u8, 4), cqes >> 4);

    try std.testing.expect(nn >= 1);
    // CNTLID is "unique within the NVM subsystem", not necessarily non-zero:
    // the static controller model allows 0h..FFEFh (Discovery log, Figure 310).
    try std.testing.expectEqual(common.cntlid(), cntlid);
    try std.testing.expect(vwc & 0x1 == 1); // Volatile Write Cache present
    try std.testing.expect(std.mem.eql(u8, subnqn[0..4], "nqn."));
}

test "admin Identify Namespace mandatory fields" {
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    var cmd = spec.identifyCmd(spec.cns_ns, 0, 1);
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);

    const b = buf.bytes();
    const nsze = spec.get64(b, spec.idns_nsze);
    const ncap = spec.get64(b, spec.idns_ncap);
    const nuse = spec.get64(b, spec.idns_nuse);
    const nsfeat = spec.get8(b, spec.idns_nsfeat);
    const nlbaf = spec.get8(b, spec.idns_nlbaf);
    const flbas = spec.get8(b, spec.idns_flbas);
    const nmic = spec.get8(b, spec.idns_nmic);
    const dlfeat = spec.get8(b, spec.idns_dlfeat);
    const lbaf0_ms = spec.get16(b, spec.idns_lbaf0);
    const lbaf0_ds = spec.get8(b, spec.idns_lbaf0 + 2);

    std.debug.print("    id-ns(1): nsze={d} ncap={d} nuse={d} nsfeat=0x{x} nlbaf={d} flbas=0x{x}\n", .{ nsze, ncap, nuse, nsfeat, nlbaf, flbas });
    std.debug.print("    id-ns(1): nmic=0x{x} dlfeat=0x{x} lbaf0(ms={d} ds={d})\n", .{ nmic, dlfeat, lbaf0_ms, lbaf0_ds });

    try std.testing.expect(nsze >= 1);
    try std.testing.expect(ncap >= nsze);
    try std.testing.expect(nuse <= ncap);
    try std.testing.expect(nlbaf <= 63);
    try std.testing.expect((flbas & 0xf) <= nlbaf);
    try std.testing.expect(lbaf0_ms == 0); // PRP-only POC: no metadata
    try std.testing.expect(lbaf0_ds >= 9 and lbaf0_ds <= 12); // 512B .. 4KiB
}

test "admin Identify Active Namespace ID list" {
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    var cmd = spec.identifyCmd(spec.cns_active_ns_list, 0, 0); // NSID 0 -> from NSID 1
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);

    // CNS 02h returns a Namespace List (Figure 139): an ordered, zero-filled
    // array of 1,024 four-byte NSIDs, with no count header.
    const b = buf.bytes();
    var entries: usize = 0;
    var prev: u32 = 0;
    var found = false;
    var i: usize = 0;
    while (i < 1024) : (i += 1) {
        const nsid = spec.get32(b, i * 4);
        if (nsid == 0) break;
        try std.testing.expect(nsid > prev); // increasing order
        prev = nsid;
        entries += 1;
        if (nsid == 1) found = true;
    }
    std.debug.print("    active ns list: entries={d} first={d}\n", .{ entries, spec.get32(b, 0) });
    try std.testing.expect(entries >= 1);
    try std.testing.expectEqual(@as(u32, 1), spec.get32(b, 0));
    try std.testing.expect(found);
}

test "admin Identify Namespace Identification Descriptor list" {
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    var cmd = spec.identifyCmd(spec.cns_ns_descr_list, 0, 1);
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);

    // Descriptors are NIDT (1B) + NIDL (1B) + 2 reserved bytes + NID (NIDL B);
    // the total length of one descriptor is NIDL + 4 (Figure 331).
    const b = buf.bytes();
    var off: usize = 0;
    var n: usize = 0;
    while (off + 4 <= b.len and b[off] != 0 and n < 16) {
        const nidt = b[off];
        const nidl = b[off + 1];
        const want: usize = switch (nidt) {
            1 => 8, // EUI64
            2 => 16, // NGUID
            3 => 16, // UUID
            4 => 1, // CSI
            else => 0,
        };
        std.debug.print("    ns descriptor: nidt={d} nidl={d}\n", .{ nidt, nidl });
        try std.testing.expect(want != 0);
        try std.testing.expectEqual(want, nidl);
        try std.testing.expectEqual(@as(u8, 0), b[off + 2]);
        try std.testing.expectEqual(@as(u8, 0), b[off + 3]);
        off += 4 + nidl;
        n += 1;
    }
    try std.testing.expect(n >= 1);
}

// --- §2 mandatory features ------------------------------------------------

test "admin Get Features mandatory IDs" {
    const Feat = struct { fid: u8, nsid: u32, name: []const u8 };
    const feats = [_]Feat{
        .{ .fid = spec.fid_arbitration, .nsid = 0, .name = "Arbitration" },
        .{ .fid = spec.fid_power_mgmt, .nsid = 0, .name = "PowerManagement" },
        .{ .fid = spec.fid_temp_thresh, .nsid = 0, .name = "TemperatureThreshold" },
        .{ .fid = spec.fid_err_recovery, .nsid = 1, .name = "ErrorRecovery" },
        .{ .fid = spec.fid_num_queues, .nsid = 0, .name = "NumberOfQueues" },
        .{ .fid = spec.fid_write_atomicity, .nsid = 0, .name = "WriteAtomicityNormal" },
        .{ .fid = spec.fid_async_event_conf, .nsid = 0, .name = "AsyncEventConfig" },
    };

    for (feats) |f| {
        var cmd = spec.getFeaturesCmd(f.fid, 0, f.nsid);
        const cqe = try common.adminOk(&cmd, null, 0);
        const st = nvme.status(cqe);
        std.debug.print("    Get Features {s} (fid 0x{x}) -> dw0=0x{x}\n", .{ f.name, f.fid, nvme.cqeDw0(cqe) });
        try std.testing.expectEqual(spec.sc_success, st.sc);
        try std.testing.expectEqual(@as(u3, 0), st.sct);
    }
}

test "admin Set/Get Features reserved FID rejected" {
    const bad: u8 = 0x7f;

    var gf = spec.getFeaturesCmd(bad, 0, 0);
    var r = try common.admin(&gf, null, 0);
    try std.testing.expect(!r.ok);
    var st = nvme.status(r.cqe);
    try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
    try std.testing.expectEqual(@as(u3, 0), st.sct);
    try std.testing.expect(st.dnr);

    var sf = spec.setFeaturesCmd(bad, 0, 0);
    r = try common.admin(&sf, null, 0);
    try std.testing.expect(!r.ok);
    st = nvme.status(r.cqe);
    try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
    try std.testing.expect(st.dnr);
}

// Number of Queues is set once at init; setting it again while no I/O queue
// exists is legal and must report at least one I/O SQ and CQ. This test must
// run before any Create I/O *Q, because after that the command is a sequence
// error.
test "admin Set/Get Features Number of Queues" {
    var sf = spec.setFeaturesCmd(spec.fid_num_queues, 0, 0); // request minimum
    const set_cqe = try common.adminOk(&sf, null, 0);
    const granted = nvme.cqeDw0(set_cqe);

    var gf = spec.getFeaturesCmd(spec.fid_num_queues, 0, 0);
    const get_cqe = try common.adminOk(&gf, null, 0);
    const current = nvme.cqeDw0(get_cqe);

    std.debug.print("    numq: set granted nsqr={d} ncqr={d}; get nsqr={d} ncqr={d}\n", .{
        granted & 0xffff, granted >> 16, current & 0xffff, current >> 16,
    });
    try std.testing.expectEqual(granted, current);
}

// --- §3 mandatory log pages -----------------------------------------------

test "admin Get Log Page mandatory IDs" {
    const Log = struct { lid: u8, nsid: u32, name: []const u8 };
    const logs = [_]Log{
        .{ .lid = spec.log_error_info, .nsid = 0xffffffff, .name = "ErrorInformation" },
        .{ .lid = spec.log_smart, .nsid = 0xffffffff, .name = "SMART/Health" },
        .{ .lid = spec.log_fw_slot, .nsid = 0xffffffff, .name = "FirmwareSlotInformation" },
    };

    for (logs) |l| {
        var buf = try vfntest.pageBuffer(4096);
        defer buf.deinit();

        // Device transfers 512 B; libvfn's mapping length must be page-multiple.
        var cmd = spec.getLogCmd(l.lid, l.nsid, 512);
        const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);

        const b = buf.bytes();
        switch (l.lid) {
            spec.log_error_info => {
                const errors = spec.get64(b, 0);
                std.debug.print("    log {s} (0x{x}): error_count={d}\n", .{ l.name, l.lid, errors });
            },
            spec.log_smart => {
                const critical_warning = b[0];
                const temp_k = spec.get16(b, 1);
                std.debug.print("    log {s} (0x{x}): cw=0x{x} temp={d}K\n", .{ l.name, l.lid, critical_warning, temp_k });
                try std.testing.expect(temp_k > 0);
            },
            spec.log_fw_slot => {
                const afi = b[0] & 0x7;
                std.debug.print("    log {s} (0x{x}): active_slot={d}\n", .{ l.name, l.lid, afi });
                try std.testing.expect(afi >= 1);
            },
            else => {},
        }
    }
}

// --- §1.1 Asynchronous Event Request + Abort ------------------------------

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

// --- §0/§1.1 Create/Delete I/O queues -------------------------------------

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

// --- §4 mandatory NVM I/O command set -------------------------------------

// Write → Read → Flush over PRP. The 3-page buffer forces PRP1 + PRP2 and a
// PRP list, so all three data-pointer forms the mandatory baseline uses are
// exercised. The pattern is regenerated after the read and compared.
test "io Write Read Flush PRP round-trip" {
    const ctrl_ = try common.ctrl();

    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 16, -1));
    defer _ = c.nvme_delete_iocq(ctrl_, 1);
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 16, &ctrl_.cq[1], 0));
    defer _ = c.nvme_delete_iosq(ctrl_, 1);

    const page = vfntest.page_size;
    const len = 3 * page;
    var dma = try common.dmaMap(len);
    defer dma.buf.deinit();

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
}
