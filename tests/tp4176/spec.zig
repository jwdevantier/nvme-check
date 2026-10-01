//! TP4176 (Rate Limiting) spec definitions — the spec side (DESIGN.md §4).
//!
//! Pure: layouts, field offsets, command builders, decoders. Host-testable
//! over synthetic buffers (`zig build test`); no device, no libvfn calls.
//! Device-facing cases live in `batches/` and use this module.

const std = @import("std");
const c = @import("vfn_c");

// --- admin opcodes / feature & log ids ------------------------------------

pub const admin_get_log_page: u8 = 0x02;
pub const admin_identify: u8 = 0x06;
pub const admin_abort: u8 = 0x08;
pub const admin_set_features: u8 = 0x09;
pub const admin_get_features: u8 = 0x0a;
pub const admin_async_event: u8 = 0x0c;

pub const log_rate_limit: u8 = 0x28; // TP4176 Rate Limiting log page
pub const feat_rate_limit: u8 = 0x28; // TP4176 Rate Limiting feature
pub const feat_async_event_conf: u8 = 0x0b;

/// Rate Limiting Configuration Change Notices (Async Event Configuration
/// bit 22, Figure 98).
pub const rlccn: u32 = 1 << 22;

/// Async Event Request cid bit (NVMe base spec): an AER's submission cid has
/// bit 15 set and the completion echoes it.
pub const cid_aer: u16 = 1 << 15;

// Async Event dw0 fields for the Rate Limiting Configuration Change event.
pub const aer_type_notice: u32 = 0x02;
pub const aer_info_rate_limit_chg: u32 = 0x0a;
pub const aer_lid_rate_limit: u32 = 0x28;

// CQE status codes.
pub const sc_invalid_field: u8 = 0x02; // Invalid Field in Command
pub const sc_invalid_ctrl_id: u8 = 0x1f; // Invalid Controller Identifier (SCT=1)

// Rate Limits Control (RLC) field.
pub const rlc_rle: u16 = 1 << 15; // Rate Limiting Enable
pub const rlm_hard: u16 = 0;
pub const rlm_soft: u16 = 1;

pub const rl_data_len: usize = 1024; // Figure RLDB data buffer
pub const log_len: usize = 4096; // comfortably larger than log page 28h
pub const rl_map_len: usize = 4096; // iommufd maps whole pages (1024 -> 4096)

/// Figure RLDB — Rate Limiting feature data buffer (1024 bytes).
pub const RlData = extern struct {
    rlc: c.leint16_t, // bytes 1:0  - bit 15 RLE, bits 3:0 RLM
    rsvd0: [5]u8, // bytes 6:2  - reserved
    bwsf: u8, // byte  7    - Bandwidth Scale Factor
    tbwv: c.leint64_t, // bytes 15:8 - Total Bandwidth Value
    wbwv: c.leint64_t, // bytes 23:16 - Write Bandwidth Value
    tiops: c.leint32_t, // bytes 27:24 - Total IOPS
    wiops: c.leint32_t, // bytes 31:28 - Write IOPS
    riopsr: u8, // byte  32   - Read IOPS Ratio
    wiopsr: u8, // byte  33   - Write IOPS Ratio
    rbwr: u8, // byte  34   - Read Bandwidth Ratio
    wbwr: u8, // byte  35   - Write Bandwidth Ratio
    rsvd1: [476]u8, // bytes 511:36 - reserved
    vs: [512]u8, // bytes 1023:512 - vendor specific
};

// Figure NewFig — log page header field offsets.
pub const lp_np: usize = 2; // u16le - Number of Ports (0's based)
pub const lp_lpl: usize = 4; // u32le - Log Page Length (dwords)
pub const lp_gc: usize = 8; // u32le - Generation Count
pub const lp_nst: usize = 12; // u16le - Number of Supported Targets
pub const lp_port_list: usize = 16; // u32le[NP+1] - dword offsets to QPD

// Figure QPD / QCD descriptor offsets (relative to a descriptor).
pub const pd_portid: usize = 0;
pub const pd_size: usize = 1024;
pub const cd_cntlid: usize = 0;
pub const cd_nnsmad: usize = 2;
pub const cd_size: usize = 320;

pub fn get16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}
pub fn get32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}
pub fn get64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

pub fn identifyCmd(cns: u8, csi: u8) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.identify.opcode = admin_identify;
    cmd.identify.cns = cns;
    cmd.identify.csi = csi;
    return cmd;
}

/// Build a Get/Set Features 28h command targeting a controller.
pub fn rlFeaturesCmd(opcode: u8, tid: u16, tgt: u8, sel: u8) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.features.opcode = opcode;
    cmd.features.fid = feat_rate_limit;
    cmd.features.sel = sel;
    cmd.features.cdw11 = c.cpu_to_le32((@as(u32, tgt) << 16) | @as(u32, tid));
    return cmd;
}

/// Build a Get Log Page 28h command covering `len` bytes.
pub fn getRateLimitLogCmd(len: usize) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    const numd: u32 = @intCast(len / 4);
    cmd.log.opcode = admin_get_log_page;
    cmd.log.lid = log_rate_limit;
    cmd.log.numdl = c.cpu_to_le16(@truncate((numd - 1) & 0xffff));
    cmd.log.numdu = c.cpu_to_le16(@truncate((numd - 1) >> 16));
    return cmd;
}

pub fn aerType(dw0: u32) u32 {
    return dw0 & 0x7;
}
pub fn aerInfo(dw0: u32) u32 {
    return (dw0 >> 8) & 0xff;
}
pub fn aerLid(dw0: u32) u32 {
    return (dw0 >> 16) & 0xff;
}

// --- host tests over synthetic buffers ------------------------------------

test "Figure RLDB layout" {
    try std.testing.expectEqual(@as(usize, 1024), @sizeOf(RlData));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(RlData, "rlc"));
    try std.testing.expectEqual(@as(usize, 7), @offsetOf(RlData, "bwsf"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(RlData, "tbwv"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(RlData, "wbwv"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RlData, "tiops"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(RlData, "wiops"));
    try std.testing.expectEqual(@as(usize, 34), @offsetOf(RlData, "rbwr"));
    try std.testing.expectEqual(@as(usize, 35), @offsetOf(RlData, "wbwr"));
}

test "rate-limit features command encodes FID/TGT/TID" {
    const cmd = rlFeaturesCmd(admin_get_features, 0x0042, 0, 0);
    try std.testing.expectEqual(admin_get_features, cmd.features.opcode);
    try std.testing.expectEqual(feat_rate_limit, cmd.features.fid);
    try std.testing.expectEqual(@as(u32, 0x0042), c.le32_to_cpu(cmd.features.cdw11));
}

test "log page header decodes (synthetic)" {
    var buf = [_]u8{0} ** 32;
    std.mem.writeInt(u16, buf[lp_np..][0..2], 0, .little);
    std.mem.writeInt(u32, buf[lp_lpl..][0..4], 376, .little);
    std.mem.writeInt(u32, buf[lp_gc..][0..4], 7, .little);
    std.mem.writeInt(u16, buf[lp_nst..][0..2], 0, .little);

    try std.testing.expectEqual(@as(u16, 0), get16(&buf, lp_np));
    try std.testing.expectEqual(@as(u32, 376), get32(&buf, lp_lpl));
    try std.testing.expectEqual(@as(u32, 7), get32(&buf, lp_gc));
    try std.testing.expectEqual(@as(u16, 0), get16(&buf, lp_nst));
}
