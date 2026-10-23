//! Port of nvmetest_oob_cmb_test (QEMU tests/qtest/nvme-test.c).
//!
//! NVMe controller created with cmb_size_mb=2: BAR2 is the 2 MiB controller
//! memory buffer. Verify plain read-back and that partially out-of-bounds
//! accesses at the end of the window behave as the device model defines
//! (regression cover for a former NULL-deref).

const std = @import("std");
const common = @import("common");

// kill the spawned QEMU when this test panics (defers do not run)
pub const panic = std.debug.FullPanic(common.qtest.panicHook);


const CMB_SIZE: u64 = 2 * 1024 * 1024; // == device opt cmb_size_mb=2

test "oob-cmb-access: CMB read-back widths and boundary behavior" {
    const s = try common.spawn(",cmb_size_mb=2", &.{});
    defer s.deinit();

    try common.pci.enable(s, common.devfn);           // upstream: qpci_device_enable
    try common.pci.assignBar64(s, common.devfn, 2, common.BAR2); // then qpci_iomap(2)

    const cmb = common.BAR2;
    try s.write(u32, cmb + 0, 0xccbbaa99);
    try std.testing.expectEqual(@as(u8, 0x99), try s.read(u8, cmb + 0));
    try std.testing.expectEqual(@as(u16, 0xaa99), try s.read(u16, cmb + 0));

    // partially out-of-bounds: write straddling the window's last byte
    const last = cmb + CMB_SIZE - 1;
    try s.write(u32, last, 0x44332211);
    try std.testing.expectEqual(@as(u8, 0x11), try s.read(u8, last));
    try std.testing.expect((try s.read(u16, last)) != 0x2211);
    try std.testing.expect((try s.read(u32, last)) != 0x44332211);
}
