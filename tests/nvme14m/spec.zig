//! NVMe 1.4 mandatory-baseline definitions — the spec side.
//!
//! Pure: constants, field offsets, command builders. No device, no libvfn
//! calls, host-testable over synthetic buffers (`zig build test`). The
//! device-facing cases live in the `batches/*.zig` programs and use this module
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

/// Format NVM (80h): optional (OACS bit 1). Used as the "unsupported opcode"
/// probe when the controller does not advertise it (Figure 28).
pub const admin_format_nvm: u8 = 0x80;

// --- NVM command set opcodes (Figure 30) ----------------------------------

pub const nvm_flush: u8 = 0x00;
pub const nvm_write: u8 = 0x01;
pub const nvm_read: u8 = 0x02;
pub const nvm_write_uncorrectable: u8 = 0x04;
pub const nvm_compare: u8 = 0x05;
pub const nvm_write_zeroes: u8 = 0x08;
pub const nvm_dataset_mgmt: u8 = 0x09;
pub const nvm_verify: u8 = 0x0c;

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

/// Get Features Select (SEL) field, Figure 196 (CDW10 bits 10:08):
/// 000b current, 001b default, 010b saved, 011b supported capabilities.
/// NB: the backlog and `nvme-14m-analysis.md` write "default(2)/saved(3)";
/// that is off by one — Figure 196 is authoritative.
pub const sel_current: u8 = 0;
pub const sel_default: u8 = 1;
pub const sel_saved: u8 = 2;
pub const sel_supported_caps: u8 = 3;

/// Supported-capabilities word returned by Get Features SEL = 3
/// (Figure 199).
pub const feat_cap_svbl: u32 = 1 << 0; // Saveable
pub const feat_cap_nsspec: u32 = 1 << 1; // NS Specific
pub const feat_cap_chang: u32 = 1 << 2; // Changeable

// --- Log page identifiers (Figure 31) -------------------------------------

pub const log_error_info: u8 = 0x01;
pub const log_smart: u8 = 0x02;
pub const log_fw_slot: u8 = 0x03;

// --- Completion status: SCT (Figure 100) ----------------------------------

/// Status Code Type, in the CQE status field: 0 = generic (Figure 102),
/// 1 = command specific (Figure 103).
pub const sct_generic: u8 = 0;
pub const sct_cmd_specific: u8 = 1;
/// Backlog spelling of the command-specific SCT value.
pub const sc_cmd_specific: u8 = sct_cmd_specific;

// --- Generic command status codes (Figure 102) ----------------------------

pub const sc_success: u8 = 0x00;
pub const sc_invalid_opcode: u8 = 0x01;
pub const sc_invalid_field: u8 = 0x02;
pub const sc_abort_req: u8 = 0x07;
/// 0Bh: "Invalid Namespace or Format".
pub const sc_invalid_namespace: u8 = 0x0b;
/// 0Bh; kept so callers written against the first pass keep compiling.
pub const sc_invalid_nsid: u8 = sc_invalid_namespace;
/// 0Ch: "Command Sequence Error" (Figure 102). Returned for Set Features
/// Number of Queues (07h) once I/O queues exist (BASE@2.3 §5.2.26.2.1).
pub const sc_cmd_sequence_error: u8 = 0x0c;
pub const sc_prp_offset_invalid: u8 = 0x13;
pub const sc_lba_out_of_range: u8 = 0x80;

// --- Command-specific status codes (Figure 103) ---------------------------
// Reported with `sct == sct_cmd_specific`.

pub const csc_invalid_queue_id: u8 = 0x01;
pub const csc_invalid_queue_size: u8 = 0x02;
pub const csc_abort_limit: u8 = 0x03;
pub const csc_aer_limit: u8 = 0x05;
pub const csc_invalid_interrupt_vector: u8 = 0x08;
pub const csc_invalid_log_page: u8 = 0x09;
pub const csc_invalid_queue_deletion: u8 = 0x0c;
pub const csc_feature_not_saveable: u8 = 0x0d;
pub const csc_feature_not_changeable: u8 = 0x0e;
pub const csc_feature_not_ns_specific: u8 = 0x0f;

/// AER commands carry bit 15 set in the command identifier.
pub const cid_aer: u16 = 1 << 15;

// --- Asynchronous events (Figures 150/153/210) ----------------------------

/// Asynchronous Event Type (AET), AER completion Dword 0 bits 2:0 (Figure 150).
pub const aet_error: u3 = 0;
pub const aet_smart: u3 = 1;
pub const aet_notice: u3 = 2;
pub const aet_immediate: u3 = 3;
pub const aet_one_shot: u3 = 4;
pub const aet_io_cmd_specific: u3 = 6;
pub const aet_vendor: u3 = 7;

/// Asynchronous Event Information (AEI) for SMART/Health status events
/// (Figure 153).
pub const aei_smart_reliability: u8 = 0;
pub const aei_smart_temp_thresh: u8 = 1;
pub const aei_smart_spare: u8 = 2;

/// SMART/Health Critical Warning temperature bit (Figure 210). The
/// Asynchronous Event Configuration feature's SHCW field (Figure 409 bits
/// 7:0) mirrors these bits to enable the matching events.
pub const smart_temp_thresh: u32 = 1 << 1;

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

// Doorbell offsets within the doorbell region (BAR0 offset 1000h, mapped
// separately by libvfn as `ctrl.doorbells`). QID 0 is the Admin queue; the SQ
// tail and CQ head doorbells are 4 bytes apart (Figure 40).
pub const dbl_sq0tdbl: usize = 0x00;
pub const dbl_cq0hdbl: usize = 0x04;

// Controller Configuration (Figure 41) and Controller Status (Figure 42) bits.
pub const cc_en: u32 = 1 << 0;
pub const cc_shn_shift: u5 = 14;
pub const cc_shn_mask: u32 = 0x3 << cc_shn_shift;
pub const csts_rdy: u32 = 1 << 0;
pub const csts_cfs: u32 = 1 << 1;

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
// 1.4 additions / previously-unread fields (Figure 328).
pub const idc_rtd3r: usize = 84;
pub const idc_rtd3e: usize = 88;
pub const idc_oaes: usize = 92;
pub const idc_ctratt: usize = 96;
pub const idc_cntrltype: usize = 111;
// Controller Attributes (CTRATT, Figure 328 bytes 99:96) capability bits.
pub const ctratt_mds: u32 = 1 << 10; // Multi-Domain Subsystem
pub const ctratt_fcm: u32 = 1 << 11; // Fixed Capacity Management
pub const ctratt_fdps: u32 = 1 << 19; // Flexible Data Placement Support

// Optional Admin Command Support (OACS, Figure 328 bytes 257:256). Each set
// bit is a direct claim that the command is supported; BASE@2.3 reserves
// bits 15:12.
pub const oacs_security: u16 = 1 << 0; // Security Send/Receive
pub const oacs_format: u16 = 1 << 1; // Format NVM
pub const oacs_firmware: u16 = 1 << 2; // Firmware Commit/Download
pub const oacs_ns_mgmt: u16 = 1 << 3; // Namespace Management
pub const oacs_self_test: u16 = 1 << 4; // Device Self-test
pub const oacs_directives: u16 = 1 << 5; // Directives
pub const oacs_nvme_mi: u16 = 1 << 6; // NVMe-MI Send/Receive
pub const oacs_virt_mgmt: u16 = 1 << 7; // Virtualization Management
pub const oacs_doorbell: u16 = 1 << 8; // Doorbell Buffer Config
pub const oacs_get_lba_status: u16 = 1 << 9; // Get LBA Status
pub const oacs_lockdown: u16 = 1 << 10; // Command and Feature Lockdown
pub const oacs_live_migration: u16 = 1 << 11; // Host Managed Live Migration
pub const oacs_reserved: u16 = 0xf000; // bits 15:12

// Optional NVM Command Support (ONCS, Figure 328 bytes 521:520). BASE@2.3
// reserves bits 15:13; the low bits are named “variants” because a clear bit
// can still mean support (reported through a non-zero size limit in the I/O
// Command Set specific Identify Controller), so only a set bit is a firm
// support claim.
pub const oncs_compare: u16 = 1 << 0; // NVMCMPS
pub const oncs_write_uncorrectable: u16 = 1 << 1; // NVMWUSV
pub const oncs_dataset_mgmt: u16 = 1 << 2; // NVMDSMSV
pub const oncs_write_zeroes: u16 = 1 << 3; // NVMWZSV
pub const oncs_save_select: u16 = 1 << 4; // SSFS
pub const oncs_reservations: u16 = 1 << 5; // RESERVS
pub const oncs_timestamp: u16 = 1 << 6; // TSS
pub const oncs_verify: u16 = 1 << 7; // NVMVFYS
pub const oncs_copy: u16 = 1 << 8; // NVMCPYS
pub const oncs_copy_single_atomicity: u16 = 1 << 9; // NVMCSA
pub const oncs_all_fast_copy: u16 = 1 << 10; // NVMAFC
pub const oncs_reserved: u16 = 0xe000; // bits 15:13
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
pub const idc_fuses: usize = 522;
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
pub const idns_nguid: usize = 104; // 16 bytes, big-endian (NVM Fig. 123)
pub const idns_eui64: usize = 120; // 8 bytes, big-endian (NVM Fig. 123)
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

/// Queue-management command flags (Figures 504/508).
pub const q_pc: u16 = 1 << 0; // Physically Contiguous
pub const cq_ien: u16 = 1 << 1; // Interrupts Enabled

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

/// Format NVM (80h): optional (OACS.Format). `nsid` 0 selects no namespace
/// and is rejected, which makes this a non-destructive probe of whether the
/// opcode is recognised.
pub fn formatNvmCmd(nsid: u32) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.rw.opcode = admin_format_nvm;
    cmd.rw.nsid = c.cpu_to_le32(nsid);
    return cmd;
}

/// Get Features (0Ah) with `sel` (see the `sel_*` constants, Figure 196).
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

/// Get Features (0Ah) current value (SEL = 0, Figure 196).
pub fn getFeaturesCurrent(fid: u8, nsid: u32) c.nvme_cmd {
    return getFeaturesCmd(fid, sel_current, nsid);
}

/// Get Features (0Ah) default value (SEL = 1, Figure 196).
pub fn getFeaturesDefault(fid: u8, nsid: u32) c.nvme_cmd {
    return getFeaturesCmd(fid, sel_default, nsid);
}

/// Get Features (0Ah) saved value (SEL = 2, Figure 196). A controller that
/// cannot save the feature operates as if SEL were default.
pub fn getFeaturesSaved(fid: u8, nsid: u32) c.nvme_cmd {
    return getFeaturesCmd(fid, sel_saved, nsid);
}

/// Set Features (09h) with the Save bit (SV, CDW10 bit 31, Figure 401) set,
/// so the attribute persists through power states and resets.
pub fn setFeaturesSaved(fid: u8, nsid: u32, cdw11: u32) c.nvme_cmd {
    var cmd = setFeaturesCmd(fid, nsid, cdw11);
    cmd.unnamed_0.cdw10 = c.cpu_to_le32(@as(u32, fid) | (1 << 31));
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

/// Create I/O Completion Queue (05h), §5.3.1/Figures 503-504. `qsize` is the
/// 0's based CDW10 field (entries - 1); `prp1` is the page-aligned queue base
/// address; `iv`/`ien` are CDW11's interrupt vector and Interrupts Enabled bit.
pub fn createCqCmd(qid: u16, qsize: u16, prp1: u64, iv: u16, ien: bool) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.create_cq.opcode = admin_create_cq;
    cmd.create_cq.prp1 = c.cpu_to_le64(prp1);
    cmd.create_cq.qid = c.cpu_to_le16(qid);
    cmd.create_cq.qsize = c.cpu_to_le16(qsize);
    cmd.create_cq.qflags = c.cpu_to_le16(q_pc | (if (ien) cq_ien else @as(u16, 0)));
    cmd.create_cq.iv = c.cpu_to_le16(iv);
    return cmd;
}

/// Create I/O Submission Queue (01h), §5.3.2/Figures 507-508. `qsize` is the
/// 0's based CDW10 field; `cqid` is CDW11's Completion Queue Identifier.
pub fn createSqCmd(qid: u16, qsize: u16, prp1: u64, cqid: u16) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.create_sq.opcode = admin_create_sq;
    cmd.create_sq.prp1 = c.cpu_to_le64(prp1);
    cmd.create_sq.qid = c.cpu_to_le16(qid);
    cmd.create_sq.qsize = c.cpu_to_le16(qsize);
    cmd.create_sq.qflags = c.cpu_to_le16(q_pc);
    cmd.create_sq.cqid = c.cpu_to_le16(cqid);
    return cmd;
}

/// Delete I/O Completion Queue (04h), §5.3.3/Figure 511.
pub fn deleteCqCmd(qid: u16) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.delete_q.opcode = admin_delete_cq;
    cmd.delete_q.qid = c.cpu_to_le16(qid);
    return cmd;
}

/// Delete I/O Submission Queue (00h), §5.3.4/Figure 513.
pub fn deleteSqCmd(qid: u16) c.nvme_cmd {
    var cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.delete_q.opcode = admin_delete_sq;
    cmd.delete_q.qid = c.cpu_to_le16(qid);
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

/// Byte offsets of PRP1 and PRP2 in the 64-byte command. The 16-byte data
/// pointer starts after the 24-byte common command header (Figure 109).
pub const cmd_prp1: usize = 24;
pub const cmd_prp2: usize = 32;

/// Write/Read (01h/02h) with explicit PRP1/PRP2 and no PRP list, for the offset
/// rules of Figure 110 (PRP2 must be page aligned).
pub fn rwCmdPrp(opcode: u8, nsid: u32, slba: u64, nlb: u16, prp1: u64, prp2: u64) c.nvme_cmd {
    var cmd = rwCmd(opcode, nsid, slba, nlb);
    const b = std.mem.asBytes(&cmd);
    std.mem.writeInt(u64, b[cmd_prp1 .. cmd_prp1 + 8], prp1, .little);
    std.mem.writeInt(u64, b[cmd_prp2 .. cmd_prp2 + 8], prp2, .little);
    return cmd;
}

// --- host tests over the pure definitions ---------------------------------

test "field offsets match the 1.4 figures" {
    try std.testing.expectEqual(@as(usize, 0x14), reg_cc);
    try std.testing.expectEqual(@as(usize, 78), idc_cntlid);
    try std.testing.expectEqual(@as(usize, 512), idc_sqes);
    try std.testing.expectEqual(@as(usize, 768), idc_subnqn);
    try std.testing.expectEqual(@as(usize, 130), idns_lbaf0 + 2);
    // NVM@1.3 Figure 123: NGUID bytes 119:104, EUI64 bytes 127:120.
    try std.testing.expectEqual(@as(usize, 104), idns_nguid);
    try std.testing.expectEqual(@as(usize, 128), idns_eui64 + 8);
}

test "rw command encodes explicit PRP1/PRP2" {
    const cmd = rwCmdPrp(nvm_read, 1, 0x100, 7, 0xdead0000, 0xbeef1004);
    try std.testing.expectEqual(nvm_read, cmd.rw.opcode);
    try std.testing.expectEqual(@as(u16, 7), c.le16_to_cpu(cmd.rw.nlb));
    const b = std.mem.asBytes(&cmd);
    try std.testing.expectEqual(@as(usize, 24), cmd_prp1);
    try std.testing.expectEqual(@as(usize, 32), cmd_prp2);
    try std.testing.expectEqual(@as(u64, 0xdead0000), std.mem.readInt(u64, b[cmd_prp1 .. cmd_prp1 + 8], .little));
    try std.testing.expectEqual(@as(u64, 0xbeef1004), std.mem.readInt(u64, b[cmd_prp2 .. cmd_prp2 + 8], .little));
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

test "create/delete queue commands encode QID/QSIZE/CQID" {
    const cq = createCqCmd(3, 7, 0x1000, 2, true);
    try std.testing.expectEqual(admin_create_cq, cq.create_cq.opcode);
    try std.testing.expectEqual(@as(u16, 3), c.le16_to_cpu(cq.create_cq.qid));
    try std.testing.expectEqual(@as(u16, 7), c.le16_to_cpu(cq.create_cq.qsize));
    try std.testing.expectEqual(q_pc | cq_ien, c.le16_to_cpu(cq.create_cq.qflags));
    try std.testing.expectEqual(@as(u16, 2), c.le16_to_cpu(cq.create_cq.iv));

    const sq = createSqCmd(4, 15, 0x2000, 3);
    try std.testing.expectEqual(admin_create_sq, sq.create_sq.opcode);
    try std.testing.expectEqual(@as(u16, 4), c.le16_to_cpu(sq.create_sq.qid));
    try std.testing.expectEqual(@as(u16, 15), c.le16_to_cpu(sq.create_sq.qsize));
    try std.testing.expectEqual(@as(u16, 1), c.le16_to_cpu(sq.create_sq.qflags)); // PC only
    try std.testing.expectEqual(@as(u16, 3), c.le16_to_cpu(sq.create_sq.cqid));

    const dcq = deleteCqCmd(5);
    try std.testing.expectEqual(admin_delete_cq, dcq.delete_q.opcode);
    try std.testing.expectEqual(@as(u16, 5), c.le16_to_cpu(dcq.delete_q.qid));

    const dsq = deleteSqCmd(6);
    try std.testing.expectEqual(admin_delete_sq, dsq.delete_q.opcode);
    try std.testing.expectEqual(@as(u16, 6), c.le16_to_cpu(dsq.delete_q.qid));
}

test "offsets and status codes match the figures" {
    // Identify Controller field offsets, BASE Figure 328.
    try std.testing.expectEqual(@as(usize, 84), idc_rtd3r);
    try std.testing.expectEqual(@as(usize, 88), idc_rtd3e);
    try std.testing.expectEqual(@as(usize, 92), idc_oaes);
    try std.testing.expectEqual(@as(usize, 96), idc_ctratt);
    try std.testing.expectEqual(@as(usize, 111), idc_cntrltype);
    try std.testing.expectEqual(@as(usize, 522), idc_fuses);

    // Generic command status codes, BASE Figure 102.
    try std.testing.expectEqual(@as(u8, 0x01), sc_invalid_opcode);
    try std.testing.expectEqual(@as(u8, 0x02), sc_invalid_field);
    try std.testing.expectEqual(@as(u8, 0x0b), sc_invalid_namespace);
    try std.testing.expectEqual(@as(u8, 0x0c), sc_cmd_sequence_error);
    try std.testing.expectEqual(@as(u8, 0x13), sc_prp_offset_invalid);
    try std.testing.expectEqual(@as(u8, 0x80), sc_lba_out_of_range);

    // Status Code Type and command-specific codes, Figures 102/103.
    try std.testing.expectEqual(@as(u8, 0), sct_generic);
    try std.testing.expectEqual(@as(u8, 1), sct_cmd_specific);
    try std.testing.expectEqual(@as(u8, 0x01), csc_invalid_queue_id);
    try std.testing.expectEqual(@as(u8, 0x02), csc_invalid_queue_size);
    try std.testing.expectEqual(@as(u8, 0x03), csc_abort_limit);
    try std.testing.expectEqual(@as(u8, 0x05), csc_aer_limit);
    try std.testing.expectEqual(@as(u8, 0x08), csc_invalid_interrupt_vector);
    try std.testing.expectEqual(@as(u8, 0x09), csc_invalid_log_page);
    try std.testing.expectEqual(@as(u8, 0x0c), csc_invalid_queue_deletion);
    try std.testing.expectEqual(@as(u8, 0x0d), csc_feature_not_saveable);
    try std.testing.expectEqual(@as(u8, 0x0e), csc_feature_not_changeable);
    try std.testing.expectEqual(@as(u8, 0x0f), csc_feature_not_ns_specific);

    // Format NVM opcode, Figure 28.
    try std.testing.expectEqual(@as(u8, 0x80), admin_format_nvm);

    // Get Features SEL encodings, Figure 196.
    try std.testing.expectEqual(@as(u8, 0), sel_current);
    try std.testing.expectEqual(@as(u8, 1), sel_default);
    try std.testing.expectEqual(@as(u8, 2), sel_saved);
    try std.testing.expectEqual(@as(u8, 3), sel_supported_caps);

    // Feature capability bits, Figure 199.
    try std.testing.expectEqual(@as(u32, 1 << 0), feat_cap_svbl);
    try std.testing.expectEqual(@as(u32, 1 << 1), feat_cap_nsspec);
    try std.testing.expectEqual(@as(u32, 1 << 2), feat_cap_chang);

    // Asynchronous event types / SMART-Health information, Figures 150/153/210.
    try std.testing.expectEqual(@as(u3, 1), aet_smart);
    try std.testing.expectEqual(@as(u8, 1), aei_smart_temp_thresh);
    try std.testing.expectEqual(@as(u32, 1 << 1), smart_temp_thresh);
}

test "feature helpers encode SEL and the Save bit" {
    const def = getFeaturesDefault(fid_num_queues, 0);
    try std.testing.expectEqual(sel_default, def.features.sel);

    const saved = getFeaturesSaved(fid_num_queues, 0);
    try std.testing.expectEqual(sel_saved, saved.features.sel);

    const sv = setFeaturesSaved(fid_num_queues, 0, 0x00010001);
    try std.testing.expectEqual(fid_num_queues, sv.features.fid);
    try std.testing.expectEqual(@as(u32, 0x00010001), c.le32_to_cpu(sv.features.cdw11));
    try std.testing.expect((c.le32_to_cpu(sv.unnamed_0.cdw10) & (1 << 31)) != 0);
}

test "capability bit masks match Figure 328" {
    // OACS bits and the reserved window (bytes 257:256).
    try std.testing.expectEqual(@as(u16, 1 << 1), oacs_format);
    try std.testing.expectEqual(@as(u16, 1 << 11), oacs_live_migration);
    try std.testing.expectEqual(@as(u16, 0xf000), oacs_reserved);
    // Every defined OACS bit lies outside the reserved window.
    try std.testing.expect(oacs_format & oacs_reserved == 0);

    // ONCS bits and the reserved window (bytes 521:520).
    try std.testing.expectEqual(@as(u16, 1 << 0), oncs_compare);
    try std.testing.expectEqual(@as(u16, 1 << 7), oncs_verify);
    try std.testing.expectEqual(@as(u16, 1 << 10), oncs_all_fast_copy);
    try std.testing.expectEqual(@as(u16, 0xe000), oncs_reserved);

    // Optional NVM opcodes, Figure 30.
    try std.testing.expectEqual(@as(u8, 0x05), nvm_compare);
    try std.testing.expectEqual(@as(u8, 0x08), nvm_write_zeroes);
    try std.testing.expectEqual(@as(u8, 0x0c), nvm_verify);

    // Format NVM builder carries the opcode and NSID; NSID 0 makes it a safe
    // non-destructive probe.
    const fmt = formatNvmCmd(0);
    try std.testing.expectEqual(admin_format_nvm, fmt.rw.opcode);
    try std.testing.expectEqual(@as(u32, 0), c.le32_to_cpu(fmt.rw.nsid));
}
