//! Port of nvmetest_reg_read_test (QEMU tests/qtest/nvme-test.c).
//!
//! Enable the device, map BAR0, read CAP via 32-bit halves and via one
//! 64-bit read; assert MQES (bits 15:0) and MPSMAX (bits 55:52) against the
//! QEMU device model's fixed capabilities.

const std = @import("std");
const common = @import("common");

// kill the spawned QEMU when this test panics (defers do not run)
pub const panic = std.debug.FullPanic(common.qtest.panicHook);


test "reg-read: CAP via 32-bit halves and 64-bit read" {
    const s = try common.spawn("", &.{});
    defer s.deinit();

    try common.pci.enable(s, common.devfn);           // upstream: qpci_device_enable
    try common.pci.assignBar64(s, common.devfn, 0, common.BAR0); // then qpci_iomap(0)

    const cap_lo = try s.readl(common.BAR0 + 0x0);
    try std.testing.expectEqual(@as(u32, 0x7ff), cap_lo & 0xffff); // MQES

    const cap_hi = try s.readl(common.BAR0 + 0x4);
    const cap: u64 = @as(u64, cap_hi) << 32;
    try std.testing.expectEqual(@as(u64, 0x4), (cap >> 52) & 0xf); // MPSMAX

    const cap64 = try s.readq(common.BAR0 + 0x0);
    try std.testing.expectEqual(@as(u64, 0x7ff), cap64 & 0xffff); // MQES
    try std.testing.expectEqual(@as(u64, 0x4), (cap64 >> 52) & 0xf); // MPSMAX
}
