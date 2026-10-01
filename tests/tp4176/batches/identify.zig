//! TP4176 batch: Identify NVM (RLA). One VM session, one test binary.

const std = @import("std");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("spec");

// Identify I/O Command Set Specific (CNS 06h, CSI 00h): the controller must
// advertise NVM Command Set spec 1.3 (VER, byte 21) and rate limiting
// attributes (RLA, byte 22: HLS/SLS), with SLMC (bytes 24:23) readable.
test "identify_nvm_rla" {
    _ = try common.ctrl();

    var buf = try vfntest.pageBuffer(spec.log_len);
    defer buf.deinit();

    var cmd = spec.identifyCmd(0x06, 0x00); // CNS 06h (NVM), CSI 00h
    const cqe = try common.adminOk(&cmd, common.ptr(buf), buf.bytes().len);
    try std.testing.expectEqual(@as(u8, 0), nvme.status(cqe).sc);

    const bytes = buf.bytes();
    const ver = bytes[21]; // NVM Command Set Specification Version
    const rla = bytes[22]; // Rate Limiting Attributes
    const slmc = spec.get16(bytes, 24);
    std.debug.print("    identify nvm: ver=0x{x} rla=0x{x} slmc=0x{x}\n", .{ ver, rla, slmc });

    try std.testing.expectEqual(@as(u8, 0x3), ver); // NVM CS 1.3
    try std.testing.expect(rla & 0x1 != 0); // RLA.HLS
    try std.testing.expect(rla & 0x2 != 0); // RLA.SLS
}
