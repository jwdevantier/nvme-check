//! NVMe 1.4 mandatory baseline — controller shutdown batch.
//!
//! This program is where `CC.SHN` / `CSTS.SHST` shutdown processing is
//! exercised. Shutdown is terminal: once `SHST` reports complete the controller
//! is ready to be powered off, so this concern must not share a session with
//! anything else. The file is registered in `workflow.lua` from the start.
//!
//! Both variants are driven through BAR0: a normal shutdown (`SHN = 01b`) and
//! an abrupt shutdown (`SHN = 10b`), each polled to `SHST = 10b` (Figures 78/79,
//! §7.6.2). Between and after them the controller is resumed with a Controller
//! Reset followed by a re-enable — §7.6.2 requires that Reset to execute
//! commands again after a shutdown; submitting commands without it is
//! "undefined", so the suite asserts no post-shutdown quiescence.

const std = @import("std");
const vfn = @import("vfn");
const common = @import("common");
const spec = @import("common").spec;

/// Monotonic milliseconds (std.time in this Zig version is constants only).
fn monoMs() i64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn readCsts(ctrl_: *vfn.Ctrl) u32 {
    return common.regRead32(ctrl_, spec.reg_csts);
}

/// Figure 79 bits 3:2.
fn shst(csts_val: u32) u2 {
    return @truncate((csts_val >> 2) & 0x3);
}

/// Figure 79 bit 6: the Shutdown Type (ST) bit. 1.4(c) reserves bits 31:06, so
/// this is a 2.x field; it is kept only to surface (not assert) the value under
/// version policy (B): 1 = NVM Subsystem Shutdown, 0 = controller shutdown.
fn shutdownType(csts_val: u32) u1 {
    return @truncate((csts_val >> 6) & 0x1);
}

/// Spin until CSTS.SHST equals `want`, up to `to_ms`. `CAP.TO` bounds the wait
/// (Figure 69).
fn waitShst(ctrl_: *vfn.Ctrl, want: u2, to_ms: i64) !void {
    const deadline = monoMs() + to_ms;
    while (monoMs() < deadline) {
        if (shst(readCsts(ctrl_)) == want) return;
        std.atomic.spinLoopHint();
    }
    return error.Timeout;
}

/// Spin until CSTS.RDY equals `want_ready`, up to `to_ms` (Figure 79).
fn waitRdy(ctrl_: *vfn.Ctrl, want_ready: bool, to_ms: i64) !void {
    const deadline = monoMs() + to_ms;
    while (monoMs() < deadline) {
        const ready = (readCsts(ctrl_) & spec.csts_rdy) != 0;
        if (ready == want_ready) return;
        std.atomic.spinLoopHint();
    }
    return error.Timeout;
}

/// Request a controller shutdown by setting CC.SHN (Figure 78 bits 15:14)
/// while preserving the other CC fields.
fn requestShutdown(ctrl_: *vfn.Ctrl, cc: u32, shn: u2) void {
    common.regWrite32(ctrl_, spec.reg_cc, (cc & ~spec.cc_shn_mask) | (@as(u32, shn) << spec.cc_shn_shift));
}

/// Controller Reset followed by a re-enable. After a shutdown requested with
/// `CC.EN` set, §7.6.2 requires a Controller Reset before the controller
/// processes commands again; the reset clears `CSTS.SHST` to 00b (Figure 79).
/// The reset preserves AQA/ASQ/ACQ, so no admin queue needs re-programming
/// (Figure 78, §3.1.5).
fn resumeController(ctrl_: *vfn.Ctrl, to_ms: i64) !void {
    const cc = common.regRead32(ctrl_, spec.reg_cc);
    common.regWrite32(ctrl_, spec.reg_cc, cc & ~spec.cc_en);
    try waitRdy(ctrl_, false, to_ms);
    // The reset cleared CC, so restore its transport fields as well as EN and
    // clear SHN with the same write.
    common.regWrite32(ctrl_, spec.reg_cc, (cc | spec.cc_en) & ~spec.cc_shn_mask);
    try waitRdy(ctrl_, true, to_ms);
}

test "controller normal shutdown: CC.SHN / CSTS.SHST" {
    const ctrl_ = try common.ctrl();

    // Figure 69: CAP.TO is in 500 ms units (0 means 500 ms).
    const cap = common.regRead64(ctrl_, spec.reg_cap);
    const to_ms: i64 = 500 * @as(i64, @intCast(((cap >> 24) & 0xff) + 1));

    const cc = common.regRead32(ctrl_, spec.reg_cc);
    try std.testing.expectEqual(spec.csts_rdy, readCsts(ctrl_) & spec.csts_rdy);
    try std.testing.expectEqual(@as(u2, 0b00), shst(readCsts(ctrl_)));

    // 01b = normal shutdown notification (§7.6.2, Figure 78).
    requestShutdown(ctrl_, cc, 0b01);
    try waitShst(ctrl_, 0b10, to_ms);

    const done = readCsts(ctrl_);
    try std.testing.expectEqual(@as(u2, 0b10), shst(done)); // processing complete
    try std.testing.expectEqual(@as(u32, 0), done & spec.csts_cfs);

    // CSTS.ST (bit 6) is a 2.x field; 1.4(c) Figure 79 reserves bits 31:06.
    // Version policy (B) surfaces a set bit rather than failing on it (this run
    // only requests controller shutdowns, so a 2.x controller also reports 0).
    if (shutdownType(done) != 0) {
        std.debug.print("    WARNING: CSTS.ST (bit 6) set; reserved in 1.4(c), 2.x NVM Subsystem Shutdown\n", .{});
    }

    // Restore normal operation for the abrupt variant (§7.6.2).
    try resumeController(ctrl_, to_ms);
    try std.testing.expectEqual(@as(u2, 0b00), shst(readCsts(ctrl_)));
}

test "controller abrupt shutdown: CC.SHN / CSTS.SHST" {
    const ctrl_ = try common.ctrl();

    const cap = common.regRead64(ctrl_, spec.reg_cap);
    const to_ms: i64 = 500 * @as(i64, @intCast(((cap >> 24) & 0xff) + 1));

    const cc = common.regRead32(ctrl_, spec.reg_cc);
    try std.testing.expectEqual(spec.csts_rdy, readCsts(ctrl_) & spec.csts_rdy);

    // 10b = abrupt shutdown notification (§7.6.2, Figure 78).
    requestShutdown(ctrl_, cc, 0b10);
    try waitShst(ctrl_, 0b10, to_ms);

    const done = readCsts(ctrl_);
    try std.testing.expectEqual(@as(u2, 0b10), shst(done));
    try std.testing.expectEqual(@as(u32, 0), done & spec.csts_cfs);
    if (shutdownType(done) != 0) {
        std.debug.print("    WARNING: CSTS.ST (bit 6) set; reserved in 1.4(c), 2.x NVM Subsystem Shutdown\n", .{});
    }

    // Leave the controller running normally.
    try resumeController(ctrl_, to_ms);
    try std.testing.expectEqual(@as(u2, 0b00), shst(readCsts(ctrl_)));
}
