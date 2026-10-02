//! Bump allocator over the emulated machine's RAM — the guest-physical
//! address counterpart of libqos's QGuestAllocator.
//!
//! NOT a std.mem.Allocator (deliberately): that interface hands back host
//! pointers you can dereference; this hands back guest-physical *addresses*
//! (u64) to place NVMe queues / PRP buffers at. Under -accel qtest nothing
//! else uses guest RAM, so bump + align + bounds suffice; free() arrives if
//! a test ever needs to reuse space mid-run.

const std = @import("std");

pub const GuestMem = struct {
    base: u64, // first usable address (low RAM skipped by convention)
    top: u64, // one past the last RAM address (== -m size on pc)
    next: u64,

    /// 256 MiB pc-style default; bump top when the machine's -m differs.
    pub fn init() GuestMem {
        return .{ .base = 0x0010_0000, .top = 0x1000_0000, .next = 0x0010_0000 };
    }

    pub fn alloc(self: *GuestMem, size: u64, alignment: u64) error{OutOfGuestMemory}!u64 {
        const a = std.mem.alignForward(u64, self.next, alignment);
        if (a + size > self.top) return error.OutOfGuestMemory;
        self.next = a + size;
        return a;
    }

    /// Space for `n` items of T, page-aligned — the common DMA-buffer shape.
    pub fn allocFor(self: *GuestMem, comptime T: type, n: usize) error{OutOfGuestMemory}!u64 {
        return self.alloc(@sizeOf(T) * n, 4096);
    }
};

test "bump allocator: alignment, packing, exhaustion" {
    var g = GuestMem.init();

    const a = try g.alloc(10, 4096);
    try std.testing.expectEqual(@as(u64, 0x0010_0000), a); // already aligned

    const b = try g.alloc(1, 4096); // bumps and re-aligns to next page
    try std.testing.expectEqual(@as(u64, 0x0010_1000), b);

    const c = try g.allocFor([4096]u8, 1); // one full page
    try std.testing.expectEqual(@as(u64, 0x0010_2000), c);

    g.top = 0x0010_3000;
    try std.testing.expectError(error.OutOfGuestMemory, g.alloc(1, 4096));
}
