// tests/tp4176/batches/smoke.zig
//
// First batch program: a device-free check that a batch test binary builds and
// runs. Real TP4176 cases land here as the suite is ported.

const std = @import("std");
const c = @import("vfn_c");

test "le16 round-trip" {
    const v: u16 = 0x1234;
    try std.testing.expectEqual(v, c.le16_to_cpu(c.cpu_to_le16(v)));
}
