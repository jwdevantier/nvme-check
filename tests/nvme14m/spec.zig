//! NVMe 1.4 mandatory-baseline definitions — the spec side.
//!
//! Pure: constants, field offsets, command builders. No device, no libvfn
//! calls, host-testable over synthetic buffers (`zig build test`). The
//! device-facing cases live in `batches/mandatory.zig` and use this module
//! through `common.spec`.
//!
//! Scope is exactly the mandatory baseline from the POC overview: the admin
//! command set, the mandatory Get/Set Features IDs, the mandatory log pages,
//! the mandatory Identify CNS values, and the NVM Read/Write/Flush commands.
//! Optional material (Format NVM, SGL, CMB/PMR, telemetry, ...) is absent.

const std = @import("std");
const c = @import("vfn_c");

// --- Admin command opcodes (Figure 28) ------------------------------------

pub const admin_delete_sq: u8 = 0x00;
pub const admin_create_sq: u8 = 0x01;
pub const admin_get_log: u8 = 0x02;
pub const admin_delete_cq: u8 = 0x04;
pub const admin_create_cq: u8 = 0x05;
pub const admin_identify: u8 = 0x06;
pub const admin_abort: u8 = 0x08;
pub const admin_set_features: u8 = 0x09;
pub const admin_get_features: u8 = 0x0a;
pub const admin_async_event: u8 = 0x0c;

// --- NVM command set opcodes (Figure 30) ----------------------------------

pub const nvm_flush: u8 = 0x00;
pub const nvm_write: u8 = 0x01;
pub const nvm_read: u8 = 0x02;

// --- Identify CNS values (Figure 244) -------------------------------------

pub const cns_ns: u8 = 0x00;
pub const cns_ctrl: u8 = 0x01;
pub const cns_active_ns_list: u8 = 0x02;
pub const cns_ns_descr_list: u8 = 0x03;

// --- Feature identifiers (Figure 32) --------------------------------------

pub const fid_arbitration: u8 = 0x01;
pub const fid_power_mgmt: u8 = 0x02;
pub const fid_temp_thresh: u8 = 0x04;
pub const fid_err_recovery: u8 = 0x05;
pub const fid_num_queues: u8 = 0x07;
pub const fid_write_atomicity: u8 = 0x0a;
pub const fid_async_event_conf: u8 = 0x0b;

// --- Log page identifiers (Figure 31) -------------------------------------

pub const log_error_info: u8 = 0x01;
pub const log_smart: u8 = 0x02;
pub const log_fw_slot: u8 = 0x03;

// --- Completion status codes (Figure 91) ----------------------------------

pub const sc_success: u8 = 0x00;
pub const sc_invalid_field: u8 = 0x02;
pub const sc_invalid_nsid: u8 = 0x0b;
pub const sc_abort_req: u8 = 0x07;

/// AER commands carry bit 15 set in the command identifier.
pub const cid_aer: u16 = 1 << 15;

// --- BAR0 register offsets (Figure 39) ------------------------------------

pub const reg_cap: usize = 0x00;
pub const reg_vs: usize = 0x08;
pub const reg_intms: usize = 0x0c;
pub const reg_intmc: usize = 0x10;
pub const reg_cc: usize = 0x14;
pub const reg_csts: usize = 0x1c;
pub const reg_aqa: usize = 0x24;
pub const reg_asq: usize = 0x28;
pub const reg_acq: usize = 0x30;

// --- Identify Controller field offsets (Figure 247, 4096-byte structure) ---

pub const idc_vid: usize = 0;
pub const idc_ssvid: usize = 2;
pub const idc_sn: usize = 4;
pub const idc_mn: usize = 24;
pub const idc_fr: usize = 64;
pub const idc_rab: usize = 72;
pub const idc_ieee: usize = 73;
pub const idc_mdts: usize = 77;
pub const idc_cntlid: usize = 78;
pub const idc_ver: usize = 80;
pub const idc_oacs: usize = 256;
pub const idc_acl: usize = 258;
pub const idc_aerl: usize = 259;
pub const idc_frmw: usize = 260;
pub const idc_lpa: usize = 261;
pub const idc_elpe: usize = 262;
pub const idc_npss: usize = 263;
pub const idc_sqes: usize = 512;
pub const idc_cqes: usize = 513;
pub const idc_nn: usize = 516;
pub const idc_oncs: usize = 520;
pub const idc_fna: usize = 524;
pub const idc_vwc: usize = 525;
pub const idc_awun: usize = 526;
pub const idc_awupf: usize = 528;
pub const idc_acwu: usize = 532;
pub const idc_sgls: usize = 536;
pub const idc_subnqn: usize = 768;

// --- Identify Namespace field offsets (Figure 248) ------------------------

pub const idns_nsze: usize = 0;
pub const idns_ncap: usize = 8;
pub const idns_nuse: usize = 16;
pub const idns_nsfeat: usize = 24;
pub const idns_nlbaf: usize = 25;
pub const idns_flbas: usize = 26;
pub const idns_mc: usize = 27;
pub const idns_dpc: usize = 28;
pub const idns_dps: usize = 29;
pub const idns_nmic: usize = 30;
pub const idns_dlfeat: usize = 33;
pub const idns_lbaf0: usize = 128; // u16 MS, then u8 LBADS at +2

// --- little-endian field readers ------------------------------------------

pub fn get8(buf: []const u8, off: usize) u8 {
    return buf[off];
}
pub fn get16(buf: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, buf[off..][0..2], .little);
}
pub fn get32(buf: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, buf[off..][0..4], .little);
}
pub fn get64(buf: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, buf[off..][0..8], .little);
}

// --- command builders -----------------------------------------------------

/// Identify (06h): CNS/CSI select the structure; `nsid` is only interpreted by
/// CNS 00h/02h/03h.
pub fn identifyCmd(cns: u8, csi: u8, nsid: u32) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.identify.opcode = admin_identify;
    cmd.identify.nsid = c.cpu_to_le32(nsid);
    cmd.identify.cns = cns;
    cmd.identify.csi = csi;
    return cmd;
}

/// Get Features (0Ah) with `sel` (0 = current, 2 = default, 3 = saved/cap).
pub fn getFeaturesCmd(fid: u8, sel: u8, nsid: u32) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.features.opcode = admin_get_features;
    cmd.features.nsid = c.cpu_to_le32(nsid);
    cmd.features.fid = fid;
    cmd.features.sel = sel;
    return cmd;
}

/// Set Features (09h) with the feature-specific dword in CDW11.
pub fn setFeaturesCmd(fid: u8, nsid: u32, cdw11: u32) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.features.opcode = admin_set_features;
    cmd.features.nsid = c.cpu_to_le32(nsid);
    cmd.features.fid = fid;
    cmd.features.cdw11 = c.cpu_to_le32(cdw11);
    return cmd;
}

/// Get Log Page (02h). `len` is the number of bytes the *device* transfers
/// (the NUMD field); libvfn still needs a page-multiple DMA buffer, which is
/// the caller's business.
pub fn getLogCmd(lid: u8, nsid: u32, len: usize) c.nvme_cmd {
    const numd: u32 = @intCast(len / 4); // dwords, 1-based count -> NUMD = numd-1
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.log.opcode = admin_get_log;
    cmd.log.nsid = c.cpu_to_le32(nsid);
    cmd.log.lid = lid;
    cmd.log.numdl = c.cpu_to_le16(@truncate((numd - 1) & 0xffff));
    cmd.log.numdu = c.cpu_to_le16(@truncate((numd - 1) >> 16));
    return cmd;
}

/// Abort (08h): abort the command with identifier `cid` on submission queue
/// `sqid`.
///
/// `cid` is the *raw* identifier as libvfn stores it in the SQE (libvfn's
/// `cid` field is native, not byte-swapped). Abort's CDW10 carries a copy the
/// device compares against the identifier it decoded from the SQE, so
/// normalize it to the little-endian view the device uses.
pub fn abortCmd(sqid: u16, cid: u16) c.nvme_cmd {
    const seen: u32 = @as(u32, c.cpu_to_le16(cid));
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.unnamed_0.opcode = admin_abort;
    cmd.unnamed_0.cdw10 = c.cpu_to_le32((seen << 16) | @as(u32, sqid));
    return cmd;
}

/// Write/Read (01h/02h) over PRP for `nlb + 1` blocks at `slba`.
pub fn rwCmd(opcode: u8, nsid: u32, slba: u64, nlb: u16) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.rw.opcode = opcode;
    cmd.rw.nsid = c.cpu_to_le32(nsid);
    cmd.rw.slba = c.cpu_to_le64(slba);
    cmd.rw.nlb = c.cpu_to_le16(nlb);
    return cmd;
}

// --- host tests over the pure definitions ---------------------------------

test "field offsets match the 1.4 figures" {
    try std.testing.expectEqual(@as(usize, 0x14), reg_cc);
    try std.testing.expectEqual(@as(usize, 78), idc_cntlid);
    try std.testing.expectEqual(@as(usize, 512), idc_sqes);
    try std.testing.expectEqual(@as(usize, 768), idc_subnqn);
    try std.testing.expectEqual(@as(usize, 130), idns_lbaf0 + 2);
}

test "identify command encodes CNS/NSID" {
    const cmd = identifyCmd(cns_ns, 0, 1);
    try std.testing.expectEqual(admin_identify, cmd.identify.opcode);
    try std.testing.expectEqual(cns_ns, cmd.identify.cns);
    try std.testing.expectEqual(@as(u32, 1), c.le32_to_cpu(cmd.identify.nsid));
}

test "features command encodes FID/sel/CDW11" {
    const get = getFeaturesCmd(fid_num_queues, 0, 0);
    try std.testing.expectEqual(admin_get_features, get.features.opcode);
    try std.testing.expectEqual(fid_num_queues, get.features.fid);

    const set = setFeaturesCmd(fid_num_queues, 0, 0x00030003);
    try std.testing.expectEqual(admin_set_features, set.features.opcode);
    try std.testing.expectEqual(@as(u32, 0x00030003), c.le32_to_cpu(set.features.cdw11));
}

test "get log page encodes NUMD" {
    const cmd = getLogCmd(log_smart, 0xffffffff, 512);
    try std.testing.expectEqual(admin_get_log, cmd.log.opcode);
    try std.testing.expectEqual(log_smart, cmd.log.lid);
    try std.testing.expectEqual(@as(u16, 127), c.le16_to_cpu(cmd.log.numdl)); // 512/4 - 1
}

test "abort command encodes SQID/CID" {
    const cmd = abortCmd(0, 0x8001);
    const seen: u32 = @as(u32, c.cpu_to_le16(0x8001));
    try std.testing.expectEqual(admin_abort, cmd.unnamed_0.opcode);
    try std.testing.expectEqual(seen << 16, @as(u32, c.le32_to_cpu(cmd.unnamed_0.cdw10)));
}
