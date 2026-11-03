//! NVMe 1.4 mandatory baseline — read-only inspection test program.
//!
//! Everything here is non-destructive: the transport registers and the
//! controller enable state, the register BAR plus MSI-X capability,
//! interrupt masking, the four mandatory Identify CNS structures, the
//! controller capability fields, namespace NSID semantics and descriptor-list
//! rules, and the mandatory Get Log Page IDs and their
//! contents. The capability test briefly creates a throwaway I/O queue to probe
//! optional NVM opcodes, and the log-page test submits an invalid Format NVM
//! (NSID 0, which the device rejects) to exercise Error Information logging;
//! neither reads or writes user data and every queue created is deleted. The
//! MSI-X test attempts to enable MSI-X, binds a queue to a valid vector and
//! completes a command on it (polled); a second test programs the vector's
//! MSI-X table entry, registers a VFIO eventfd and waits for the device to
//! signal it, so real interrupt delivery is observed in the libvfn lane too.
//! Because no test leaves state behind, they share one controller session,
//! opened once by `common.ctrl()` (libvfn `nvme_init`: reset → admin queue →
//! enable → Identify).
//!
//! Tests run in declaration order. Nothing here depends on that order — each
//! test re-reads what it needs from the controller.

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

    // CC.CSS must name an I/O Command Set the controller advertises in
    // CAP.CSS (Figure 41 bits 6:4 with Figure 36 bits 44:37): 000b selects the
    // NVM Command Set and requires CAP.CSS.NCSS, 110b selects every supported
    // I/O Command Set and requires CAP.CSS.IOCSS, and 111b selects admin-only
    // and requires CAP.CSS.NOIOCSS. The remaining encodings are reserved. The
    // POC advertises IOCSS, so libvfn's bring-up selects 110b; a minimal
    // NVM-only controller selects 000b. Either is conformant.
    const css = (cc >> 4) & 0x7;
    const cap_css = (cap >> 37) & 0xff;
    try std.testing.expectEqual(@as(u64, 1), cap_css & 0x1); // NCSS
    switch (css) {
        0b000 => {},
        0b110 => try std.testing.expectEqual(@as(u64, 1), (cap_css >> 6) & 0x1), // IOCSS
        0b111 => try std.testing.expectEqual(@as(u64, 1), (cap_css >> 7) & 0x1), // NOIOCSS
        else => return error.ReservedCommandSetSelected,
    }

    // CC.MPS must name a page size the controller supports (Figure 41 bits
    // 10:7): CAP.MPSMIN <= MPS <= CAP.MPSMAX.
    const mps: u64 = (cc >> 7) & 0xf;
    try std.testing.expect(mps >= mpsmin and mps <= mpsmax);

    // AQA.ASQS/ACQS are 0-based queue sizes: a value of 0 means one entry and
    // is illegal (Figure 44 requires at least two entries while enabled), and
    // no admin queue may exceed CAP.MQES.
    const asqs = aqa & 0xfff;
    const acqs = (aqa >> 16) & 0xfff;
    try std.testing.expect(asqs >= 1 and asqs <= mqes);
    try std.testing.expect(acqs >= 1 and acqs <= mqes);

    // The admin queue base addresses are programmed and non-zero.
    try std.testing.expect(asq != 0);
    try std.testing.expect(acq != 0);
}

// NVMe over PCIe Transport Spec R1.4 Figure 10 assigns the BARs: BAR0/1 is
// the controller register memory (MLBAR/MUBAR), BAR2 is the optional
// Index/Data Pair or vendor specific, and BAR3/4/5 are vendor specific. A
// non-zero BAR2..BAR5 is therefore not a defect; the MSI-X Table/PBA may live
// in BAR4/5 (Figures 45/46).
test "transport BAR0 and BAR1" {
    const ctrl_ = try common.ctrl();

    const command = common.cfgRead16(ctrl_, 0x04);
    try std.testing.expect(command & 0x2 != 0); // memory space enable
    try std.testing.expect(command & 0x4 != 0); // bus master enable

    // Figure 20: BAR0 is a non-prefetchable memory BAR. Bits 13:04 are RO 0,
    // so the register block is at least 16 KiB and 16 KiB aligned.
    const bar0 = common.cfgRead32(ctrl_, 0x10);
    try std.testing.expect((bar0 & 0x1) == 0); // memory space
    try std.testing.expect((bar0 & 0x8) == 0); // non-prefetchable
    const bar0_reserved = (bar0 >> 4) & 0x3ff; // bits 13:04
    try std.testing.expectEqual(@as(u32, 0), bar0_reserved);

    // Figure 20 bits 02:01: 00b = 32-bit, 10b = 64-bit. 64-bit is recommended
    // (not required); 01b/11b are reserved by PCI.
    const bar_type = (bar0 >> 1) & 0x3;
    try std.testing.expect(bar_type == 0 or bar_type == 2);

    // Figure 21: BAR1 is MUBAR, the upper 32 bits of a 64-bit BAR0. A 32-bit
    // BAR0 has no upper half. A 64-bit BAR0 may legitimately have BAR1 == 0
    // when the assigned address fits in 32 bits (the §3.8.1.11 note).
    const bar1 = common.cfgRead32(ctrl_, 0x14);
    if (bar_type == 0) {
        try std.testing.expectEqual(@as(u32, 0), bar1);
    }

    // The VFIO region size is the BAR size. Figure 20 reserves bits 13:04, so
    // BAR0 is at least 16 KiB and covers the doorbells at offset 1000h
    // (Figure 4).
    const bar0_size = ctrl_.pci.bar_region_info[0].size;
    try std.testing.expect(bar0_size >= 0x4000);
    try std.testing.expect((bar0_size & (bar0_size - 1)) == 0); // PCI power of two

    std.debug.print("    BAR0=0x{x} ({s}-bit) BAR1=0x{x} size=0x{x}\n", .{
        bar0, if (bar_type == 2) "64" else "32", bar1, bar0_size,
    });
}

// MSI-X is optional (TP R1.4 Figure 42): skip the MSI-X-specific tests when
// the capability is absent. This test inspects the capability itself, so it
// runs whenever MSI-X is present; it does not require MXE to be set.
test "transport MSI-X capability" {
    const ctrl_ = try common.ctrl();
    const msix = (try common.msixMaybe()) orelse
        return common.skip("MSI-X capability absent", .{});

    std.debug.print("    MSI-X: vectors={d} enabled={} masked={} table=BIR{d}+0x{x} pba=BIR{d}+0x{x}\n", .{
        msix.vectors,          msix.enabled(),
        msix.functionMasked(), msix.tableBir(),
        msix.tableOffset(),    msix.pbaBir(),
        msix.pbaOffset(),
    });

    // Figure 44: MXC.TS is an 11-bit field encoded as n-1, so the table size
    // (`vectors` = TS + 1) is in [1, 2048]. Bits 13:11 are reserved 000b.
    const mxc_reserved = (msix.mc >> 11) & 0x7; // bits 13:11
    try std.testing.expectEqual(@as(u16, 0), mxc_reserved);

    // Figures 45/46: in an NVMe implementation the Table and PBA BIRs may
    // select only BAR0 (0h), BAR4 (4h), or BAR5 (5h); 1h/2h are n/a and
    // 3h/6h/7h are reserved.
    try std.testing.expect(common.isValidMsixBir(msix.tableBir()));
    try std.testing.expect(common.isValidMsixBir(msix.pbaBir()));

    // The table/PBA must fit inside the BAR selected by its BIR. The VFIO
    // region size is the BAR size. (For BIR 0 this is BAR0; for BIR 4/5 it is
    // the vendor-specific BAR that vnvme uses for its MSI-X table.)
    const table_size = @as(u64, msix.vectors) * 16;
    const pba_size = (@as(u64, msix.vectors) + 63) / 64 * 8;
    try std.testing.expect(@as(u64, msix.tableOffset()) + table_size <= ctrl_.pci.bar_region_info[msix.tableBir()].size);
    try std.testing.expect(@as(u64, msix.pbaOffset()) + pba_size <= ctrl_.pci.bar_region_info[msix.pbaBir()].size);

    // If the table and PBA share a BAR, they must not overlap. The transport
    // spec's "memory page(s) ... shall not include other registers/structures"
    // rules out sharing.
    if (msix.tableBir() == msix.pbaBir()) {
        const t0 = @as(u64, msix.tableOffset());
        const t1 = t0 + table_size;
        const p0 = @as(u64, msix.pbaOffset());
        const p1 = p0 + pba_size;
        try std.testing.expect(t1 <= p0 or p1 <= t0);
    }
}

// INTMS sets and INTMC clears interrupt mask bits; reading INTMS reflects the
// current mask. These properties exist only for pin-based interrupts, single
// message MSI, and multiple message MSI: BASE §3.1.4.3/§3.1.4.4 forbid a host
// from touching them while the controller is configured for MSI-X (the MSI-X
// mask table is the masking mechanism then). Gate on the MSI-X Enable bit and
// validate the mask-table geometry instead when MSI-X is active.
test "transport interrupt masking INTMS INTMC" {
    const ctrl_ = try common.ctrl();

    // No MSI-X capability at all means pin/MSI is the interrupt transport, so
    // the INTMS/INTMC path below is the right one.
    if (try common.msixMaybe()) |msix| {
        if (msix.enabled()) {
            // MSI-X is the configured interrupt transport: INTMS/INTMC would
            // be undefined accesses. Validate the mask-table geometry the host
            // would program instead (a legal BIR).
            try std.testing.expect(common.isValidMsixBir(msix.tableBir()));
            try std.testing.expect(common.isValidMsixBir(msix.pbaBir()));
            std.debug.print("    MSI-X configured: INTMS/INTMC not accessed\n", .{});
            return;
        }
    }

    // Pin-based / MSI configuration: INTMS/INTMC are the masking mechanism.
    const initial = common.regRead32(ctrl_, spec.reg_intms);
    common.regWrite32(ctrl_, spec.reg_intms, 1);
    try std.testing.expect(common.regRead32(ctrl_, spec.reg_intms) & 1 == 1);
    common.regWrite32(ctrl_, spec.reg_intmc, 1);
    try std.testing.expect(common.regRead32(ctrl_, spec.reg_intms) & 1 == 0);

    // restore the mask we found
    common.regWrite32(ctrl_, spec.reg_intmc, 0xffffffff);
    common.regWrite32(ctrl_, spec.reg_intms, initial);
}

// Needs the MSI-X capability (Create I/O CQ CDW11.IV and the MSI-X table
// geometry). The completion is polled, so MXE need not be set here; the
// delivery test below is the one that needs MSI-X enabled. It binds an I/O CQ
// to vector 0 and completes a command, proving the queue-binding half; the
// delivery test registers a VFIO eventfd and observes the message itself.
test "MSI-X vector setup and command completion" {
    const ctrl_ = try common.ctrl();
    const msix = (try common.msixMaybe()) orelse
        return common.skip("MSI-X capability absent", .{});
    // MXC.TS is encoded as n-1, so vectors = TS + 1 >= 1; Interrupt Vector 0
    // is always valid. (The Create I/O CQ field must be < vectors, or FFFFh to
    // disable interrupts.)
    const vector: u16 = 0;

    // Enable MSI-X so the device would accept the vector (MSI-X Message
    // Control bit 15); restore the original control word when done. The kernel
    // owns the MSI-X Enable bit while the device is bound to vfio-pci, so the
    // write may not take. The completion path still works either way because
    // the queue is polled, and vector 0 is legal in both modes.
    common.cfgWrite16(ctrl_, @as(u64, msix.cap) + 2, msix.mc | 0x8000);
    defer common.cfgWrite16(ctrl_, @as(u64, msix.cap) + 2, msix.mc);
    const after = try common.msix();
    std.debug.print("    MSI-X: enable write -> enabled={}\n", .{after.enabled()});

    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 8, @as(c_int, vector)));
    defer _ = c.nvme_delete_iocq(ctrl_, 1);
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 8, &ctrl_.cq[1], 0));
    defer _ = c.nvme_delete_iosq(ctrl_, 1);

    // Flush on namespace 1 completes on the vector-bound completion queue. The
    // completion is polled; the MSI-X message it drives is not observable here.
    const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(rq);
    var cmd = std.mem.zeroes(vfn.Cmd);
    cmd.rw.opcode = spec.nvm_flush;
    cmd.rw.nsid = c.cpu_to_le32(1);
    vfn.rqExec(rq, &cmd);
    var cqe = std.mem.zeroes(vfn.Cqe);
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_spin(rq, &cqe));
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
    std.debug.print("    MSI-X: command completed on vector {d} (polled; delivery checked separately)\n", .{vector});
}

// Real MSI-X interrupt delivery. The setup test above only shows a queue can be
// bound to a vector and polled; this test shows the controller actually raises
// the vector's MSI-X message. Program vector 0's table entry (message address =
// a DMA IOVA mapped in the controller's IOMMU, message data = a magic
// constant, vector control = unmasked), bind an I/O CQ to that vector, register
// a VFIO eventfd for it, and wait on the fd after submitting a Flush.
//
// 1.4(c) Figure 153 (Create I/O CQ CDW11): a queue created with Interrupts
// Enabled and a valid Interrupt Vector signals that MSI-X vector (§2.4) when a
// completion is posted; the eventfd is where VFIO surfaces it.
//
// This test needs MSI-X to be both present (capability) and enabled (MXE=1):
// with pin/MSI interrupts there is no MSI-X vector to observe. If MXE is clear,
// request it; if the kernel/vfio-pci owns the bit and it stays clear, skip.
test "MSI-X interrupt delivery" {
    const ctrl_ = try common.ctrl();
    const msix = (try common.msixMaybe()) orelse
        return common.skip("MSI-X capability absent", .{});
    std.debug.print("    MSI-X delivery: table=BIR{d}+0x{x} vectors={d}\n", .{
        msix.tableBir(), msix.tableOffset(), msix.vectors,
    });

    // Enable MSI-X if it is not already enabled. The kernel owns the bit while
    // the device is bound to vfio-pci; registering the eventfd below is what
    // lets the kernel actually enable it, so re-check after irqEnable().
    const saved_mc = msix.mc;
    if (!msix.enabled()) {
        common.cfgWrite16(ctrl_, @as(u64, msix.cap) + 2, saved_mc | 0x8000);
    }
    defer common.cfgWrite16(ctrl_, @as(u64, msix.cap) + 2, saved_mc);

    // The message address must be an IOVA the controller's IOMMU will accept
    // (the vfio-pci table trap rejects a bare physical address), so map one page
    // and aim the vector at it. The data is an arbitrary marker; the eventfd,
    // not the DMA, is the observation point.
    var dma = try common.dmaMap(vfntest.page_size);
    defer dma.deinit();

    // Locate the table. BIR 0 uses libvfn's BAR0 mappings; BIR 4/5 maps that
    // vendor-specific BAR. Invalid BIRs and tables that do not fit are skipped:
    // the structural test above already reports them.
    const table_size = @as(usize, msix.vectors) * 16;
    var table = common.mapMsixBar(ctrl_, msix.tableBir(), msix.tableOffset(), table_size) catch |err| switch (err) {
        error.InvalidMsixBir, error.MsixOutOfBar, error.MsixStraddlesBar0Mappings => {
            return common.skip("MSI-X table not reachable: {s}", .{@errorName(err)});
        },
        else => return err,
    };
    defer table.deinit(ctrl_);

    // Safety: a table in BAR0 must not overlap the NVMe register page
    // [0, 0x1000) or the doorbells this test uses (qid 0 at 0x1000/0x1004,
    // qid 1 at 0x1008/0x100c). Never program a table entry over those.
    if (msix.tableBir() == 0 and msix.tableOffset() < 0x1010) {
        return common.skip("MSI-X table overlaps NVMe registers/doorbells", .{});
    }

    const vector: u16 = 0;
    const entry = table.ptr + 16 * @as(usize, vector);
    const saved: [4]u32 = .{
        common.mmioRead32(entry),
        common.mmioRead32(entry + 4),
        common.mmioRead32(entry + 8),
        common.mmioRead32(entry + 12),
    };

    // Restore the table entry before table.deinit() unmaps a BAR4/5 mapping.
    defer {
        common.mmioWrite32(entry, saved[0]);
        common.mmioWrite32(entry + 4, saved[1]);
        common.mmioWrite32(entry + 8, saved[2]);
        common.mmioWrite32(entry + 12, saved[3]);
    }

    // Message address lo/hi = the IOVA; message data = a magic constant;
    // vector control = 0 (unmasked, unmodified delivery).
    const magic: u32 = 0x4e56_4d65; // "NVMe"
    common.mmioWrite32(entry, @truncate(dma.iova));
    common.mmioWrite32(entry + 4, @truncate(dma.iova >> 32));
    common.mmioWrite32(entry + 8, magic);
    common.mmioWrite32(entry + 12, 0);

    // Clear the function mask as well as setting MXE (Message Control bits 15
    // and 14). The kernel may still own these; delivery goes through the
    // registered eventfd when the vector fires.
    common.cfgWrite16(ctrl_, @as(u64, msix.cap) + 2, (saved_mc | 0x8000) & ~@as(u16, 0x4000));

    const fd = try vfntest.irqEnable(ctrl_, vector);
    defer {
        _ = c.vfn_shim_disable_irq(ctrl_, vector);
        vfntest.irqDisable(fd);
    }

    // Registering the eventfd lets vfio-pci enable MSI-X if it owns the enable
    // bit. If the device is still not configured for MSI-X, there is no vector
    // to observe: skip rather than fail.
    const active = try common.msix();
    if (!active.enabled()) {
        return common.skip("MSI-X present but not enabled", .{});
    }

    // Bind I/O CQ 1 to vector 0 (interrupts enabled), create SQ 1 on it, then
    // submit a Flush through the request tracker.
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iocq(ctrl_, 1, 8, @as(c_int, vector)));
    defer _ = c.nvme_delete_iocq(ctrl_, 1);
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_create_iosq(ctrl_, 1, 8, &ctrl_.cq[1], 0));
    defer _ = c.nvme_delete_iosq(ctrl_, 1);

    const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(rq);
    var cmd = std.mem.zeroes(vfn.Cmd);
    cmd.rw.opcode = spec.nvm_flush;
    cmd.rw.nsid = c.cpu_to_le32(1);
    vfn.rqExec(rq, &cmd);

    // The controller must signal the vector when the Flush completes. Wait on
    // the eventfd *before* draining the CQ, so this observes delivery rather
    // than falling back to polling.
    if (!try vfntest.irqWait(fd, 2000)) {
        // Drain the completion (if any) so the queues delete cleanly, then fail:
        // the device never raised the vector.
        var missing = std.mem.zeroes(vfn.Cqe);
        _ = c.nvme_rq_spin(rq, &missing);
        std.debug.print("    MSI-X delivery: vector {d} never signalled (completion sc=0x{x})\n", .{
            vector, nvme.status(missing).sc,
        });
        return error.InterruptNotDelivered;
    }

    var cqe = std.mem.zeroes(vfn.Cqe);
    try std.testing.expectEqual(@as(c_int, 0), c.nvme_rq_spin(rq, &cqe));
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
    std.debug.print("    MSI-X delivery: vector {d} signalled, Flush completed\n", .{vector});
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
    const fuses = spec.get16(b, spec.idc_fuses);
    const fna = spec.get8(b, spec.idc_fna);
    const vwc = spec.get8(b, spec.idc_vwc);
    const awun = spec.get16(b, spec.idc_awun);
    const awupf = spec.get16(b, spec.idc_awupf);
    const acwu = spec.get16(b, spec.idc_acwu);
    const sgls = spec.get32(b, spec.idc_sgls);
    const subnqn = b[spec.idc_subnqn .. spec.idc_subnqn + 256];

    std.debug.print("\n    id-ctrl: vid=0x{x} ssvid=0x{x} ver=0x{x} cntlid={d} mdts={d}\n", .{ vid, ssvid, ver, cntlid, mdts });
    std.debug.print("    id-ctrl: oacs=0x{x} acl={d} aerl={d} frmw=0x{x} lpa=0x{x} elpe={d} npss={d}\n", .{ oacs, acl, aerl, frmw, lpa, elpe, npss });
    std.debug.print("    id-ctrl: sqes=0x{x} cqes=0x{x} nn={d} oncs=0x{x} fuses=0x{x} fna=0x{x} vwc=0x{x}\n", .{ sqes, cqes, nn, oncs, fuses, fna, vwc });
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

    // CNTLID is the NVM subsystem unique controller identifier. Values
    // FFF0h..FFFFh are reserved, so a reported id must be in 0h..FFEFh
    // (Figure 328 bytes 79:78; Discovery log, Figure 310). There is no other
    // source for the value, so the previous `== common.cntlid()` check only
    // compared the field with itself.
    try std.testing.expect(cntlid <= 0xffef);

    // OACS names the optional admin commands. BASE@2.3 reserves bits 15:12
    // (Figure 328 bytes 257:256) and they must be zero. OACS.Format is a
    // direct support claim: a controller that sets it must recognise Format
    // NVM (80h), and one that clears it must reject the opcode. The probe uses
    // NSID 0, which is invalid, so it formats no namespace.
    try std.testing.expectEqual(@as(u16, 0), oacs & spec.oacs_reserved);
    {
        var fmt = spec.formatNvmCmd(0);
        const r = try common.admin(&fmt, null, 0);
        const st = nvme.status(r.cqe);
        if (oacs & spec.oacs_format != 0) {
            try std.testing.expect(st.sc != spec.sc_invalid_opcode);
        } else {
            try std.testing.expectEqual(spec.sc_invalid_opcode, st.sc);
        }
    }

    // ONCS names the optional NVM commands. BASE@2.3 reserves bits 15:13
    // (Figure 328 bytes 521:520). The low bits are "variants" bits: a set bit
    // is a firm support claim, so the named opcode must be recognised; a clear
    // bit may still mean support reported through a size limit, so no rejection
    // is asserted. The probes run with NSID 0 and touch no user data.
    try std.testing.expectEqual(@as(u16, 0), oncs & spec.oncs_reserved);
    if (oncs & spec.oncs_compare != 0) {
        try std.testing.expect((try common.probeNvmOpcode(spec.nvm_compare)).sc != spec.sc_invalid_opcode);
    }
    if (oncs & spec.oncs_write_zeroes != 0) {
        try std.testing.expect((try common.probeNvmOpcode(spec.nvm_write_zeroes)).sc != spec.sc_invalid_opcode);
    }
    if (oncs & spec.oncs_verify != 0) {
        try std.testing.expect((try common.probeNvmOpcode(spec.nvm_verify)).sc != spec.sc_invalid_opcode);
    }

    // FRMW (Figure 328 byte 260): bits 7:6 are reserved and NOFS (bits 3:1)
    // reports one to seven firmware slots, so at least one must be present.
    const frmw_reserved = (frmw >> 6) & 0x3; // bits 7:6
    try std.testing.expectEqual(@as(u8, 0), frmw_reserved);
    try std.testing.expect(((frmw >> 1) & 0x7) >= 1);

    // LPA (Figure 328 byte 261): bit 7 is reserved.
    try std.testing.expectEqual(@as(u8, 0), lpa & 0x80);

    // NPSS (Figure 328 byte 263) is a 0-based power-state count, capped at 31
    // (up to 32 states including power state 0). ELPE (byte 262) is a 0-based
    // error-log capacity for the mandatory Error Information log; both fields
    // are read above.
    try std.testing.expect(npss <= 31);

    // SGLS (Figure 328 bytes 539:536): bits 1:0 select the SGL support mode
    // (11b is reserved) and, when SGLs are not supported, the whole field must
    // be zero. The POC advertises SGLs, but the suite only ever uses PRP, the
    // mandatory data pointer.
    const sgl_mode = sgls & 0x3;
    try std.testing.expect(sgl_mode != 0x3);
    if (sgl_mode == 0) try std.testing.expectEqual(@as(u32, 0), sgls);
    try std.testing.expectEqual(@as(u32, 0), sgls & 0xffc000f8); // reserved bits

    // FUSES (Figure 251 bytes 523:522, an M field): the field is 16-bit and
    // bits 15:1 are reserved; bit 0 is Fused Compare-and-Write Supported.
    try std.testing.expectEqual(@as(u16, 0), fuses & spec.fuses_reserved);
    std.debug.print("    id-ctrl: fused compare-and-write supported={d}\n", .{fuses & 1});

    // VWC (Figure 251 byte 525, an M field): bits 7:3 are reserved. Bits 2:1
    // select the Flush NSID=FFFFFFFFh behaviour and shall not be 00b for a
    // controller compliant with 1.4 or later (only controllers compliant with
    // "versions 1.3 and earlier" may return 00b). Bit 0 reports a volatile
    // write cache, which is optional, so it is printed but not asserted
    // (QEMU reports 0b111).
    try std.testing.expect((vwc >> 1) & 0x3 != 0);
    std.debug.print("    id-ctrl: volatile write cache present={d}\n", .{vwc & 1});

    try std.testing.expect(std.mem.eql(u8, subnqn[0..4], "nqn."));
}

// CNTRLTYPE, OAES and CTRATT are mandatory for an I/O controller in 1.4
// (Figure 251: bytes 111, 95:92 and 99:96). Nothing else reads them, so a
// device that omits them still otherwise "looks" 1.4 — hence this test.
test "admin Identify Controller 1.4 fields" {
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    var cmd = spec.identifyCmd(spec.cns_ctrl, 0, 0);
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);

    const b = buf.bytes();
    const oaes = spec.get32(b, spec.idc_oaes);
    const ctratt = spec.get32(b, spec.idc_ctratt);
    const cntrltype = spec.get8(b, spec.idc_cntrltype);
    std.debug.print("    id-ctrl(1.4): cntrltype={d} oaes=0x{x} ctratt=0x{x}\n", .{ cntrltype, oaes, ctratt });

    // "Implementations compliant with NVM Express Base Specification,
    // Revision 1.4 or later shall report a controller type": 0h is reserved,
    // 1h is an I/O controller. This POC is an I/O controller.
    try std.testing.expectEqual(@as(u8, 1), cntrltype);

    // OAES is present; the Identify command above did not abort. In 1.4(c)
    // (Figure 251 bytes 95:92) bits 31:15, bit 10 and bits 7:0 are reserved;
    // those bits are defined in later revisions, so under version policy (B)
    // they are surfaced (printed above) but not asserted. No defined bit is
    // asserted either: a controller need not enable any optional event.

    // CTRATT is present. In 1.4(c) (Figure 251 bytes 99:96) bits 31:10 are
    // reserved; the bits the suite knows (Multi-Domain Subsystem bit 10, Fixed
    // Capacity Management bit 11, Flexible Data Placement Support bit 19) are
    // 2.x capabilities. Policy (B): accept a 2.x controller, so a set bit is
    // surfaced as a warning rather than failing the run.
    if (ctratt & spec.ctratt_mds != 0) {
        std.debug.print("    WARNING: CTRATT.MDS (bit 10) set; reserved in 1.4(c), 2.x Multi-Domain Subsystem\n", .{});
    }
    if (ctratt & spec.ctratt_fcm != 0) {
        std.debug.print("    WARNING: CTRATT.FCM (bit 11) set; reserved in 1.4(c), 2.x Fixed Capacity Management\n", .{});
    }
    if (ctratt & spec.ctratt_fdps != 0) {
        std.debug.print("    WARNING: CTRATT.FDPS (bit 19) set; reserved in 1.4(c), 2.x Flexible Data Placement Support\n", .{});
    }
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
    // LBADS (Figure 249 bytes 23:16) is a power of two; values < 9 (512 B) are
    // not supported and a reported 0h means the format is unused. 1.4(c) sets
    // no upper bound.
    try std.testing.expect(lbaf0_ds == 0 or lbaf0_ds >= 9);
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

/// True when every byte in `bytes` is zero (an absent/cleared identifier).
fn allZero(bytes: []const u8) bool {
    for (bytes) |ch| {
        if (ch != 0) return false;
    }
    return true;
}

test "admin Identify Namespace Identification Descriptor list" {
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    // Cross-check the descriptors against the Identify Namespace identifier
    // fields: a 1h descriptor is a copy of EUI64 and a 2h one a copy of NGUID,
    // and neither shall be reported when its field is cleared to 0 (Fig. 253).
    var nsbuf = try vfntest.pageBuffer(4096);
    defer nsbuf.deinit();
    var nscmd = spec.identifyCmd(spec.cns_ns, 0, 1);
    _ = try common.adminOk(&nscmd, common.ptr(nsbuf), nsbuf.bytes().len);
    const nsb = nsbuf.bytes();
    const eui64_set = !allZero(nsb[spec.idns_eui64..][0..8]);
    const nguid_set = !allZero(nsb[spec.idns_nguid..][0..16]);

    var cmd = spec.identifyCmd(spec.cns_ns_descr_list, 0, 1);
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);

    // Descriptors are NIDT (1B) + NIDL (1B) + 2 reserved bytes + NID (NIDL B);
    // the total length of one descriptor is NIDL + 4 (Figure 253). The list is
    // terminated by a zero NIDT/NIDL descriptor.
    const b = buf.bytes();
    var off: usize = 0;
    var n: usize = 0;
    var have_eui64 = false;
    var have_nguid = false;
    var have_uuid = false;
    var terminated = false;
    while (off + 4 <= b.len) {
        const nidt = b[off];
        const nidl = b[off + 1];
        if (nidl == 0) {
            terminated = true;
            break;
        }

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
        switch (nidt) {
            1 => have_eui64 = true,
            2 => have_nguid = true,
            3 => have_uuid = true,
            else => {},
        }
        off += 4 + nidl;
        n += 1;
    }
    std.debug.print("    ns descriptors: n={d} eui64={} nguid={} uuid={}\n", .{ n, have_eui64, have_nguid, have_uuid });
    try std.testing.expect(terminated);
    try std.testing.expectEqual(@as(u8, 0), b[off]);
    try std.testing.expectEqual(@as(u8, 0), b[off + 1]);
    try std.testing.expect(n >= 1);

    // The identifier descriptors mirror the Identify Namespace fields.
    try std.testing.expectEqual(eui64_set, have_eui64);
    try std.testing.expectEqual(nguid_set, have_nguid);

    // Figure 253: if the namespace supports neither an IEEE EUI64 (i.e., the
    // EUI64 field is cleared to 0h) nor an NGUID (the NGUID field is cleared to
    // 0h), then it shall report a type-3h Namespace UUID descriptor. QEMU's
    // implicit namespace clears EUI64 and NGUID *and* omits the UUID (the
    // nvme-ns `uuid` property is cold-path only), so this is a known QEMU
    // non-conformance (see known-qemu-failures.txt).
    if (!eui64_set and !nguid_set) try std.testing.expect(have_uuid);
}

// NSID semantics. Spec refs use Base 1.4(c) numbers (the suite's arbiter);
// the registered Base 2.3 equivalents are in parentheses.
//
// What makes an NSID invalid - Base 1.4(c) - §6.1.2 (2.3: §3.2.1.2)
//   Valid NSIDs are 1..NN; 0h and values greater than NN are invalid.
//   FFFFFFFFh is the broadcast value, not an ordinary valid NSID.
// What makes an NSID inactive - Base 1.4(c) - §6.1.4 (2.3: §3.2.1.4)
//   Active = attached to this controller. Unallocated NSIDs are inactive for
//   all controllers.
// Inactive vs invalid status - Base 1.4(c) - §6.1.5 (2.3: §3.2.1.5)
//   Inactive -> Invalid Field in Command; invalid -> Invalid Namespace or
//   Format, unless a command-specific rule says otherwise.
// Identify CNS 00h exception - NVM 1.4(c) - §4.1.5.1
//   A valid but inactive NSID returns a zero-filled Identify Namespace data
//   structure, not an error.
// NN is the maximum valid NSID - Base 1.4(c) - Figure 251, bytes 519:516
//   (2.3: Figure 328, bytes 519:516).
// CNS 00h broadcast NSID - Base 1.4(c) - §5.15.2.1
//   FFFFFFFFh returns common namespace capabilities only when Namespace
//   Management is supported; otherwise Invalid Namespace or Format.
test "admin Identify Namespace NSID semantics and NN" {
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    var ccmd = spec.identifyCmd(spec.cns_ctrl, 0, 0);
    _ = try common.adminOk(&ccmd, common.ptr(buf), buf.bytes().len);
    const nn = spec.get32(buf.bytes(), spec.idc_nn);
    try std.testing.expect(nn >= 1);

    var acmd = spec.identifyCmd(spec.cns_active_ns_list, 0, 0);
    _ = try common.adminOk(&acmd, common.ptr(buf), buf.bytes().len);
    var active: [1024]u32 = undefined;
    var count: usize = 0;
    var max_nsid: u32 = 0;
    while (count < active.len) : (count += 1) {
        const nsid = spec.get32(buf.bytes(), count * 4);
        if (nsid == 0) break;
        active[count] = nsid;
        max_nsid = nsid;
    }
    std.debug.print("    id-ns semantics: nn={d} active={d} max={d}\n", .{ nn, count, max_nsid });
    try std.testing.expect(count >= 1);
    try std.testing.expect(count <= nn);
    try std.testing.expect(max_nsid <= nn);

    // NSID 0h is invalid - Base 1.4(c) - §6.1.2 / §6.1.5
    // (2.3: §3.2.1.2 / §3.2.1.5).
    {
        var cmd = spec.identifyCmd(spec.cns_ns, 0, 0);
        const r = try common.admin(&cmd, common.ptr(buf), buf.bytes().len);
        const st = nvme.status(r.cqe);
        std.debug.print("    id-ns(0): sc=0x{x} sct=0x{x}\n", .{ st.sc, st.sct });
        try common.expectEqualMsg(spec.sc_invalid_namespace, st.sc, "Identify CNS 00h NSID 0: expected Invalid Namespace (0x{x}), got 0x{x}", .{ spec.sc_invalid_namespace, st.sc });
        try common.expectEqualMsg(spec.sct_generic, st.sct, "Identify CNS 00h NSID 0: expected Generic status type (0x{x}), got 0x{x}", .{ spec.sct_generic, st.sct });
    }
    // NSID > NN is invalid - Base 1.4(c) - §6.1.2 / §6.1.5
    // (2.3: §3.2.1.2 / §3.2.1.5).
    if (nn < std.math.maxInt(u32)) {
        var cmd = spec.identifyCmd(spec.cns_ns, 0, nn +% 1);
        const r = try common.admin(&cmd, common.ptr(buf), buf.bytes().len);
        const st = nvme.status(r.cqe);
        std.debug.print("    id-ns({d}): sc=0x{x} sct=0x{x}\n", .{ nn +% 1, st.sc, st.sct });
        try common.expectEqualMsg(spec.sc_invalid_namespace, st.sc, "Identify CNS 00h NSID {d} (> NN {d}): expected Invalid Namespace (0x{x}), got 0x{x}", .{ nn +% 1, nn, spec.sc_invalid_namespace, st.sc });
        try common.expectEqualMsg(spec.sct_generic, st.sct, "Identify CNS 00h NSID {d} (> NN {d}): expected Generic status type (0x{x}), got 0x{x}", .{ nn +% 1, nn, spec.sct_generic, st.sct });
    }

    // The first valid NSID not in the Active list is inactive; it must return
    // a zero-filled data structure (and does not transfer the previous
    // buffer) - NVM 1.4(c) - §4.1.5.1.
    var candidate: u32 = 1;
    while (candidate <= nn) : (candidate += 1) {
        var is_active = false;
        for (active[0..count]) |a| {
            if (a == candidate) {
                is_active = true;
                break;
            }
        }
        if (is_active) continue;

        @memset(buf.bytes(), 0xff);
        var cmd = spec.identifyCmd(spec.cns_ns, 0, candidate);
        const r = try common.admin(&cmd, common.ptr(buf), buf.bytes().len);
        const st = nvme.status(r.cqe);
        std.debug.print("    id-ns(inactive {d}): ok={} sc=0x{x} zero={}\n", .{ candidate, r.ok, st.sc, allZero(buf.bytes()) });
        try std.testing.expectEqual(spec.sc_success, st.sc);
        try std.testing.expectEqual(spec.sct_generic, st.sct);
        try std.testing.expect(allZero(buf.bytes()));
        break;
    }
}

// --- §3 mandatory log pages -----------------------------------------------

/// Read a mandatory 512-byte log page (Figure 424) into `buf` and return
/// the completion. The device transfers 512 B; libvfn's mapping length must be
/// a whole number of pages.
fn readLogPage(buf: vfntest.PageBuf, lid: u8) !vfn.Cqe {
    var cmd = spec.getLogCmd(lid, 0xffffffff, 512);
    return common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
}

// Get Log Page succeeds for the three mandatory log page IDs and the mandatory
// fields inside each page are well-formed:
//   01h Error Information  (Figure 197)
//   02h SMART / Health     (Figure 198)
//   03h Firmware Slot Info (Figure 200)
test "admin Get Log Page mandatory IDs and contents" {
    const ctrl_ = try common.ctrl();
    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    // --- 01h Error Information, Figure 197 (1.4(c)) -----------------------
    //
    // ECNT is the 64-bit unique id of the most recent entry: it starts at 1,
    // is incremented per unique error and rolls over to 1 at FFFF...FFFFh. 0
    // is the invalid-entry marker used when there are fewer entries than the
    // log holds. Snapshot ECNT, induce a known failed admin command (Format
    // NVM, 80h, NSID 0 — rejected, so it never formats anything), then read the
    // log again. An entry is only required when the failed command completed
    // with the More (M) bit set (Figure 126 / §5.14.1.1); it must then carry the
    // failed command's SQID, CID and completion status.
    var ecnt: u64 = 0;
    {
        _ = try readLogPage(buf, spec.log_error_info);
        const before = spec.get64(buf.bytes(), 0);

        const rq = vfn.rqAcquire(ctrl_.adminq.sq) orelse return error.NoRequestTracker;
        var fmt = spec.formatNvmCmd(0);
        vfn.rqExec(rq, &fmt);
        const want_cid = rq.cid;
        var fail_cqe = std.mem.zeroes(vfn.Cqe);
        _ = c.nvme_rq_spin(rq, &fail_cqe);
        vfn.rqRelease(rq);
        const fail = nvme.status(fail_cqe);
        try std.testing.expect(fail.sc != spec.sc_success);

        const cqe = try readLogPage(buf, spec.log_error_info);
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
        const b = buf.bytes();
        const after = spec.get64(b, 0);
        const sqid = spec.get16(b, 8);
        const cid = spec.get16(b, 10);
        const sts = spec.get16(b, 12);
        std.debug.print("    log ErrorInformation (0x1): ecnt={d} (was {d}) sqid={d} cid={d} sts=0x{x}\n", .{ after, before, sqid, cid, sts });
        ecnt = after;

        // Figure 126 defines the More (M) bit: M=1 means "there is more status
        // information for this command as part of the Error Information log",
        // M=0 means there is no additional status information. §5.14.1.1 ties
        // the log entry to that bit ("extended error information is provided
        // when the More (M) bit is set to '1'"). An entry is therefore required
        // iff M=1; with M=0 the controller has no obligation to log the failure
        // (QEMU clears M and does not), so nothing is asserted in that case.
        if (fail.m) {
            // M=1: the induced failure must have produced an entry. It must not
            // be the 0h invalid marker (Figure 197), and ECNT — a unique id that
            // starts at 1, increments per unique entry and rolls to 1 at
            // FFFFFFFF_FFFFFFFFh — must have advanced by exactly one.
            try std.testing.expect(after != 0);
            const expected = if (before == std.math.maxInt(u64)) 1 else before + 1;
            try std.testing.expectEqual(expected, after);
            try std.testing.expectEqual(@as(u16, 0), sqid); // admin SQ is 0
            try std.testing.expectEqual(want_cid, cid);
            // STS bits 15:1 are the failed command's CQE status field (Figure 126).
            try std.testing.expectEqual(@as(u8, fail.sc), @as(u8, @truncate((sts >> 1) & 0xff)));
            try std.testing.expectEqual(@as(u3, fail.sct), @as(u3, @truncate((sts >> 9) & 0x7)));
            // Bytes 31:30 and 63:42 are Reserved in 1.4(c) Figure 197; the OPC
            // and LPVER fields of BASE 2.3 Figure 209 do not exist here and are
            // deliberately not asserted.
        }
    }

    // --- 02h SMART / Health Information, Figure 198 -----------------------
    {
        const cqe = try readLogPage(buf, spec.log_smart);
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
        const b = buf.bytes();
        const cw = spec.get8(b, 0);
        const temp_k = spec.get16(b, 1);
        const avsp = spec.get8(b, 3);
        const avspt = spec.get8(b, 4);
        const pused = spec.get8(b, 5);
        const dur = spec.get64(b, 32);
        const duw = spec.get64(b, 40);
        const pwrc = spec.get64(b, 72);
        const upl = spec.get64(b, 88);
        const mdie = spec.get64(b, 96);
        const neile = spec.get64(b, 104);
        std.debug.print("    log SMART/Health (0x2): cw=0x{x} temp={d}K avsp={d} avspt={d} pused={d} dur={d} duw={d} pwrc={d} upl={d} mdie={d} neile={d}\n", .{ cw, temp_k, avsp, avspt, pused, dur, duw, pwrc, upl, mdie, neile });

        // Critical Warning bit 7 is reserved; bits 6:0 are the defined warnings.
        try std.testing.expectEqual(@as(u8, 0), cw & 0x80);
        // Composite Temperature is in Kelvins; 0K is not an operating value.
        try std.testing.expect(temp_k > 0);
        // Available Spare and its threshold are normalized percentages; values
        // 101..255 are reserved (Figure 198).
        try std.testing.expect(avsp <= 100);
        try std.testing.expect(avspt <= 100);
        // Percentage Used is 0..255 (255 = 255% or more); the life-of-controller
        // counters are not required to be non-zero (a fresh controller may
        // report 0) but must decode as 64-bit counts.
        // NEILE is the number of Error Information log entries over the life of
        // the controller, which is ECNT (Figure 197/198).
        try std.testing.expectEqual(ecnt, neile);
    }

    // --- 03h Firmware Slot Information, Figure 200 ------------------------
    {
        const cqe = try readLogPage(buf, spec.log_fw_slot);
        try std.testing.expectEqual(spec.sc_success, nvme.status(cqe).sc);
        const b = buf.bytes();
        const afi = b[0];
        const cafs = afi & 0x7; // Current Active Firmware Slot, bits 2:0
        const nafs = (afi >> 4) & 0x7; // Next Active Firmware Slot, bits 6:4
        std.debug.print("    log FirmwareSlotInformation (0x3): afi=0x{x} cafs={d} nafs={d}\n", .{ afi, cafs, nafs });

        // Bits 3 and 7 of AFI are reserved, and the active slot is 1..7.
        try std.testing.expectEqual(@as(u8, 0), afi & 0x88);
        try std.testing.expect(cafs >= 1 and cafs <= 7);

        // FRS1..FRS7 are 8-byte ASCII revisions. A slot with no valid revision
        // (unsupported or empty) is cleared to 0; a populated revision must be
        // printable ASCII and the active slot must be populated.
        var active_populated = false;
        inline for (1..8) |slot| {
            const fr = b[8 * slot .. 8 * slot + 8];
            var populated = false;
            for (fr, 0..) |ch, i| {
                if (ch == 0) {
                    // NUL is only valid as trailing padding.
                    for (fr[i..]) |tail| try std.testing.expectEqual(@as(u8, 0), tail);
                    break;
                }
                try std.testing.expect(ch >= 0x20 and ch < 0x7f);
                populated = true;
            }
            if (slot == cafs and populated) active_populated = true;
        }
        try std.testing.expect(active_populated);
    }
}
