//! Port of nvmetest_pmr_reg_test (QEMU tests/qtest/nvme-test.c).
//!
//! NVMe with a persistent memory region: -object memory-backend-ram
//! (id=pmr0) behind pmrdev=pmr0, window at BAR4. PMRCAP/PMRCTL/PMRSTS live
//! in BAR0 at 0xe00..0xe08. Assert the PMRCAP bitfield layout, enable the
//! PMR and observe read-back through BAR4, then disable and observe PMRSTS
//! NRDY again.

const std = @import("std");
const common = @import("common");

// kill the spawned QEMU when this test panics (defers do not run)
pub const panic = std.debug.FullPanic(common.qtest.panicHook);


const PMRCAP: u64 = 0xe00;
const PMRCTL: u64 = 0xe04;
const PMRSTS: u64 = 0xe08;

test "pmr-test-access: PMRCAP fields, PMR enable/disable, NRDY transitions" {
    const s = try common.spawn(",pmrdev=pmr0", &.{
        "-object", "memory-backend-ram,id=pmr0,share=on,size=16",
    });
    defer s.deinit();

    // exact upstream ordering: enable, map BAR4 (PMR), disabled-check,
    // then map BAR0 and interrogate PMRCAP
    const pmr = common.BAR4;
    const nv = common.BAR0;
    try common.pci.enable(s, common.devfn);                 // qpci_device_enable
    try common.pci.assignBar64(s, common.devfn, 4, pmr);    // qpci_iomap(4)

    // PMR disabled: BAR4 writes do not stick
    try s.writel(pmr + 0, 0xccbbaa99);
    try std.testing.expect((try s.readb(pmr + 0)) != 0x99);
    try std.testing.expect((try s.readw(pmr + 0)) != 0xaa99);

    // upstream maps the NVMe BAR only here (qpci_iomap(0)), after the
    // disabled-PMR probe
    try common.pci.assignBar64(s, common.devfn, 0, nv);

    // PMRCAP: RDS (bit 3), WDS (bit 4), BIR (bits 7:5) == 4 (this BAR),
    // PMRWBM (bits 13:10) == 2, CMSS (bit 24) == 1
    const pmrcap = try s.readl(nv + PMRCAP);
    try std.testing.expectEqual(@as(u32, 1), (pmrcap >> 3) & 0x1);
    try std.testing.expectEqual(@as(u32, 1), (pmrcap >> 4) & 0x1);
    try std.testing.expectEqual(@as(u32, 4), (pmrcap >> 5) & 0x7);
    try std.testing.expectEqual(@as(u32, 2), (pmrcap >> 10) & 0xf);
    try std.testing.expectEqual(@as(u32, 1), (pmrcap >> 24) & 0x1);

    // Enable PMR (PMRCTL.EN): BAR4 now reads back
    try s.writel(nv + PMRCTL, 0x1);
    try s.writel(pmr + 0, 0x44332211);
    try std.testing.expectEqual(@as(u8, 0x11), try s.readb(pmr + 0));
    try std.testing.expectEqual(@as(u16, 0x2211), try s.readw(pmr + 0));
    try std.testing.expectEqual(@as(u32, 0x44332211), try s.readl(pmr + 0));

    var pmrsts = try s.readl(nv + PMRSTS);
    try std.testing.expectEqual(@as(u32, 0), (pmrsts >> 8) & 0x1); // NRDY == 0: ready

    // Disable again: writes stop sticking, NRDY asserts
    try s.writel(nv + PMRCTL, 0x0);
    try s.writel(pmr + 0, 0x88776655);
    try std.testing.expect((try s.readb(pmr + 0)) != 0x55);
    try std.testing.expect((try s.readw(pmr + 0)) != 0x6655);
    try std.testing.expect((try s.readl(pmr + 0)) != 0x88776655);

    pmrsts = try s.readl(nv + PMRSTS);
    try std.testing.expectEqual(@as(u32, 1), (pmrsts >> 8) & 0x1); // NRDY == 1: not ready
}
