// Host unit tests for the translate-c binding itself (no device, no QEMU).
// Pure spec roots are separate `zig build test` roots (see build.zig).

const std = @import("std");
const c = @import("vfn_c");

test "libvfn endianness helpers round-trip (host)" {
    const v: u16 = 0x1234;
    try std.testing.expectEqual(v, c.le16_to_cpu(c.cpu_to_le16(v)));
}
