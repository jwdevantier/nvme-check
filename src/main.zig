const std = @import("std");
const c = @import("vfn_c");

extern fn vfn_shim_read32(addr: *const anyopaque) u32;
extern fn vfn_shim_read64_raw(addr: *const anyopaque) u64;
extern fn vfn_shim_read64(addr: *const anyopaque) u64;
extern fn vfn_shim_write64_lh(addr: *anyopaque, native: u64) void;
extern fn vfn_shim_write64_hl(addr: *anyopaque, native: u64) void;
extern fn vfn_shim_dbbuf_selftest() c_int;

pub fn main() void {
    // Exported library function.
    const msg = "hello libvfn";
    std.debug.print("nvme_crc64(\"{s}\") = 0x{x}\n", .{ msg, c.nvme_crc64(0, msg.ptr, msg.len) });

    // Header-only helper (endianness): must round-trip on any host.
    const v: u16 = 0x1234;
    std.debug.print("le16 round-trip = 0x{x}\n", .{c.le16_to_cpu(c.cpu_to_le16(v))});

    // Header-only helper that translate-c demoted, resolved via the C shim.
    // Zeroed queue: tail == ptail, so this returns without touching a doorbell.
    var sq: c.nvme_sq = std.mem.zeroes(c.nvme_sq);
    c.nvme_sq_update_tail(&sq);
    std.debug.print("shim: nvme_sq_update_tail resolved and ran\n", .{});

    // mmio endianness: the raw little-endian bytes of NVMe CAP (0x4008200f0107ff)
    // as they sit in a BAR. read64 must decode to the same value on LE and BE.
    var reg: [8]u8 align(8) = .{ 0xff, 0x07, 0x01, 0x0f, 0x20, 0x08, 0x40, 0x00 };
    std.debug.print(
        "mmio read32=0x{x} read64_raw=0x{x} read64=0x{x} (want 0x4008200f0107ff)\n",
        .{ vfn_shim_read32(&reg), vfn_shim_read64_raw(&reg), vfn_shim_read64(&reg) },
    );

    // 64-bit write helpers must land little-endian bytes on both arches.
    const want = [_]u8{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 };
    var wl: [8]u8 = @splat(0);
    var wh: [8]u8 = @splat(0);
    vfn_shim_write64_lh(&wl, 0x1122334455667788);
    vfn_shim_write64_hl(&wh, 0x1122334455667788);
    std.debug.print("mmio write lh={x} hl={x} want={x}\n", .{
        std.mem.readInt(u64, &wl, .big), std.mem.readInt(u64, &wh, .big),
        std.mem.readInt(u64, &want, .big),
    });

    // Shadow-doorbell (DBBUF) byte order: nvme_try_dbbuf() must encode the
    // shadow doorbell and decode the event index little-endian on any host
    // (NVMe base spec 1.4.3 / B.5). Must print 0; nonzero means a regression.
    std.debug.print("dbbuf selftest = {d} (want 0)\n", .{vfn_shim_dbbuf_selftest()});
}
