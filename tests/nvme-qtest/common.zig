//! Shared qtest-lane plumbing for the nvme-qtest suite: spawn a headless
//! QEMU (-accel qtest, machine pc) with an NVMe controller at PCI 04.0, and
//! hand the test a connected protocol session.
//!
//! The QEMU binary comes from the NVME_QTEST_QEMU env var, which the
//! nvmecheck:qtest driver sets from the configured qemu.<arch>.bin.
//!
//! No guest-memory constants are needed (these tests touch only MMIO); the
//! BAR bases below are addresses WE choose inside the low PCI hole — no
//! BIOS runs to assign them.

const std = @import("std");

pub const qtest = @import("qtest");
pub const pci = qtest.pci;

/// The device the argv below places at addr=04.0 (bus 0, dev 4, fn 0).
pub const devfn: pci.ConfigAddr = .{ .bus = 0, .dev = 4, .func = 0 };

/// BAR bases we assign (aligned to the BAR sizes the tests declare):
/// BAR0 16 KiB, BAR2 (CMB) up to 2 MiB, BAR4 (PMR) page-aligned scratch.
pub const BAR0: u64 = 0xF010_0000;
pub const BAR2: u64 = 0xF020_0000;
pub const BAR4: u64 = 0xF080_0000;

/// Spawn with the default in-memory drive (null-co, reads as zeroes).
pub fn spawn(device_opts: []const u8, qemu_args: []const []const u8) !*qtest.Session {
    return spawnDrive(device_opts, qemu_args, null);
}

/// Spawn QEMU with an NVMe device at 04.0 and return the connected session.
/// `device_opts` are appended to the -device string (e.g. ",cmb_size_mb=2");
/// `qemu_args` are extra argv words inserted before -device (e.g. a
/// memory-backend object for PMR). `drive` overrides the built-in drive spec
/// when a test needs a real backing file (datapath verification).
pub fn spawnDrive(device_opts: []const u8, qemu_args: []const []const u8, drive: ?[]const u8) !*qtest.Session {
    const alloc = std.heap.smp_allocator;
    const qemu = std.c.getenv("NVME_QTEST_QEMU") orelse
        return error.QemuBinUnset; // set by the nvmecheck:qtest driver

    const device = try std.fmt.allocPrint(alloc, "nvme,addr=04.0,drive=drv0,serial=foo{s}", .{device_opts});
    defer alloc.free(device);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    try args.appendSlice(alloc, &.{
        "-machine", "pc",
        "-accel",     "qtest",
        "-qtest-log", "/dev/null", // silence the protocol transcript on stderr
        "-m",       "256M",
        "-display", "none",
        "-nodefaults",
        "-drive",   drive orelse "id=drv0,if=none,file=null-co://,file.read-zeroes=on,format=raw",
    });
    try args.appendSlice(alloc, qemu_args);
    try args.appendSlice(alloc, &.{ "-device", device });

    return qtest.Session.spawn(alloc, std.mem.span(qemu), args.items);
}
