//! NVMe 1.4 mandatory baseline — feature batch.
//!
//! Get/Set Features mutates controller state, so it lives in its own program:
//! a Set Features here can never perturb the read-only inspection batch, and
//! it gets a fresh controller session (`common.ctrl()` → libvfn `nvme_init`).
//!
//! Tests run in declaration order. The Number-of-Queues test must stay before
//! any I/O queue creation — that check is deliberately in the `io` program
//! (Set Features 07h becomes a Command Sequence Error once I/O queues exist).

const std = @import("std");
const nvme = @import("nvme");
const vfntest = @import("vfntest");
const common = @import("common");
const spec = @import("common").spec;

/// Read Features attribute `sel` (Figure 196) and return Dword 0.
fn getFeature(fid: u8, sel: u8, nsid: u32) !u32 {
    var cmd = spec.getFeaturesCmd(fid, sel, nsid);
    const cqe = try common.adminOk(&cmd, null, 0);
    return nvme.cqeDw0(cqe);
}

/// Set Features CDW11. The completion status is returned, not required: a
/// mandatory feature may legitimately be read-only, in which case the command
/// fails with a defined command-specific status (Figure 103).
fn setFeature(fid: u8, nsid: u32, cdw11: u32) !nvme.Status {
    var cmd = spec.setFeaturesCmd(fid, nsid, cdw11);
    const r = try common.admin(&cmd, null, 0);
    return nvme.status(r.cqe);
}

const Outcome = enum { accepted, not_changeable, not_ns_specific };

/// Set a new value, require the controller to either take it (then Get must
/// echo it, and the original value is restored) or refuse it with one of the
/// two defined command-specific statuses (leaving the value unchanged).
fn setAndCheck(fid: u8, nsid: u32, new_val: u32, mask: u32) !Outcome {
    const before = try getFeature(fid, spec.sel_current, nsid);

    const st = try setFeature(fid, nsid, new_val);
    if (st.sc == spec.sc_success and st.sct == 0) {
        const after = try getFeature(fid, spec.sel_current, nsid);
        try std.testing.expectEqual(new_val & mask, after & mask);
        _ = try setFeature(fid, nsid, before);
        try std.testing.expectEqual(before, try getFeature(fid, spec.sel_current, nsid));
        return .accepted;
    }

    // Defined command-specific refusal (Feature Not Changeable 0Eh or
    // Feature Not Namespace Specific 0Fh, Figure 103); the value is unchanged.
    try std.testing.expectEqual(@as(u3, 1), st.sct);
    try std.testing.expectEqual(before, try getFeature(fid, spec.sel_current, nsid));
    return switch (st.sc) {
        spec.csc_feature_not_changeable => .not_changeable,
        spec.csc_feature_not_ns_specific => .not_ns_specific,
        else => error.UnexpectedFeatureStatus,
    };
}

/// A mandatory feature must be gettable for the default (SEL=1) and, as
/// applicable, saved (SEL=2) value (Figure 196). When the feature is not
/// saveable (SVBL clear in the supported-capabilities word, Figure 199) the
/// saved read falls back to the default. (The backlog says "SEL=2 default and
/// SEL=3 saved"; Figure 196 / `spec.sel_*` define default = 1 and saved = 2.)
fn checkDefaultSaved(fid: u8, nsid: u32) !void {
    const def = try getFeature(fid, spec.sel_default, nsid);
    const sav = try getFeature(fid, spec.sel_saved, nsid);
    const caps = try getFeature(fid, spec.sel_supported_caps, nsid);
    if ((caps & spec.feat_cap_svbl) == 0) try std.testing.expectEqual(def, sav);
}

test "admin Get Features mandatory IDs" {
    const Feat = struct { fid: u8, nsid: u32, name: []const u8 };
    const feats = [_]Feat{
        .{ .fid = spec.fid_arbitration, .nsid = 0, .name = "Arbitration" },
        .{ .fid = spec.fid_power_mgmt, .nsid = 0, .name = "PowerManagement" },
        .{ .fid = spec.fid_temp_thresh, .nsid = 0, .name = "TemperatureThreshold" },
        .{ .fid = spec.fid_err_recovery, .nsid = 1, .name = "ErrorRecovery" },
        .{ .fid = spec.fid_num_queues, .nsid = 0, .name = "NumberOfQueues" },
        .{ .fid = spec.fid_write_atomicity, .nsid = 0, .name = "WriteAtomicityNormal" },
        .{ .fid = spec.fid_async_event_conf, .nsid = 0, .name = "AsyncEventConfig" },
    };

    for (feats) |f| {
        var cmd = spec.getFeaturesCmd(f.fid, 0, f.nsid);
        const cqe = try common.adminOk(&cmd, null, 0);
        const st = nvme.status(cqe);
        std.debug.print("    Get Features {s} (fid 0x{x}) -> dw0=0x{x}\n", .{ f.name, f.fid, nvme.cqeDw0(cqe) });
        try std.testing.expectEqual(spec.sc_success, st.sc);
        try std.testing.expectEqual(@as(u3, 0), st.sct);
    }
}

test "admin Set/Get Features reserved FID rejected" {
    const bad: u8 = 0x7f;

    var gf = spec.getFeaturesCmd(bad, 0, 0);
    var r = try common.admin(&gf, null, 0);
    try std.testing.expect(!r.ok);
    var st = nvme.status(r.cqe);
    try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
    try std.testing.expectEqual(@as(u3, 0), st.sct);
    // Figure 126 gives no general "unsupported field => DNR=1" rule: its only
    // firm rule is that DNR should be cleared to '0' when SCT and SC are both 0.
    // Here SCT=0 and SC=Invalid Field (non-zero), so DNR is unconstrained.

    var sf = spec.setFeaturesCmd(bad, 0, 0);
    r = try common.admin(&sf, null, 0);
    try std.testing.expect(!r.ok);
    st = nvme.status(r.cqe);
    try std.testing.expectEqual(spec.sc_invalid_field, st.sc);
}

// Set Features is itself mandatory, and features 01h/02h/04h/0Bh are mandatory
// for an I/O controller (BASE Figure 32). Each is Get-able and Set-able with
// the SEL semantics of Figure 196 / §4.4, and 05h/0Ah are the namespace-scoped
// features of the NVM Command Set (NVM Figure 16). A controller may report a
// mandatory feature as read-only: then Set fails with the command-specific
// Feature Not Changeable (0Eh) and the value stays put.
test "admin Set Features mandatory IDs" {
    // ONCS.SSFS (Figure 328 byte 520 bit 4) reports whether the Save/Select
    // mechanism is supported at all; log it for context. The per-feature
    // supported-capabilities word (SEL=3) is the finer-grained authority used
    // by checkDefaultSaved.
    var ibuf = try vfntest.pageBuffer(4096);
    defer ibuf.deinit();
    var icmd = spec.identifyCmd(spec.cns_ctrl, 0, 0);
    _ = try common.adminOk(&icmd, common.ptr(ibuf), ibuf.bytes().len);
    const ssfs = (spec.get16(ibuf.bytes(), spec.idc_oncs) & spec.oncs_save_select) != 0;
    std.debug.print("    Set Features: ONCS=0x{x} SSFS={}\n", .{ spec.get16(ibuf.bytes(), spec.idc_oncs), ssfs });

    // --- 01h Arbitration, controller scope (Figure 404) -------------------
    // HPW:MPW:LPW weights 3:2:1 and Arbitration Burst 3 (8 commands). Bits 7:3
    // are reserved and must stay zero.
    {
        const o = try setAndCheck(spec.fid_arbitration, 0, 0x03020103, 0xffffff07);
        std.debug.print("    Set Arbitration -> {s}\n", .{@tagName(o)});
        try std.testing.expect(o == .accepted or o == .not_changeable);
        try checkDefaultSaved(spec.fid_arbitration, 0);
    }

    // --- 02h Power Management, controller scope (Figure 405) --------------
    // Workload Hint 1, Power State 0 (power state 0 is always supported).
    {
        const o = try setAndCheck(spec.fid_power_mgmt, 0, 0x20, 0xff);
        std.debug.print("    Set PowerManagement -> {s}\n", .{@tagName(o)});
        try std.testing.expect(o == .accepted or o == .not_changeable);
        try checkDefaultSaved(spec.fid_power_mgmt, 0);
    }

    // --- 04h Temperature Threshold, controller scope (Figure 407) ---------
    // THSEL 0 (over threshold), TMPSEL 0 (composite); Get returns the 16-bit
    // threshold only. Pick a value clearly above the current temperature so no
    // SMART event fires.
    {
        const before = try getFeature(spec.fid_temp_thresh, spec.sel_current, 0);
        const new = if (before != 0xffff) @as(u32, 0xffff) else @as(u32, 0xfffe);
        const o = try setAndCheck(spec.fid_temp_thresh, 0, new, 0xffff);
        std.debug.print("    Set TemperatureThreshold 0x{x} -> {s}\n", .{ new, @tagName(o) });
        try std.testing.expect(o == .accepted or o == .not_changeable);
        try checkDefaultSaved(spec.fid_temp_thresh, 0);
    }

    // --- 0Bh Asynchronous Event Configuration, controller scope (Fig. 409) -
    // Toggle the Attached Namespace Attribute Notice (bit 8, defined for an I/O
    // controller) so the round-trip is a real change.
    {
        const before = try getFeature(spec.fid_async_event_conf, spec.sel_current, 0);
        const new = before ^ 0x00000100;
        const o = try setAndCheck(spec.fid_async_event_conf, 0, new, 0xffffffff);
        std.debug.print("    Set AsyncEventConfig 0x{x} -> {s}\n", .{ new, @tagName(o) });
        try std.testing.expect(o == .accepted or o == .not_changeable);
        try checkDefaultSaved(spec.fid_async_event_conf, 0);
    }

    // --- 05h Error Recovery, namespace scope (NVM Figure 97) ---------------
    // DULBE clear, TLER = 100 (10 s).
    {
        const before = try getFeature(spec.fid_err_recovery, spec.sel_current, 1);
        const new = if (before != 0x00000064) @as(u32, 0x00000064) else @as(u32, 0x00000065);
        const o = try setAndCheck(spec.fid_err_recovery, 1, new, 0xffffffff);
        std.debug.print("    Set ErrorRecovery 0x{x} -> {s}\n", .{ new, @tagName(o) });
        try std.testing.expect(o == .accepted or o == .not_changeable or o == .not_ns_specific);
        if (o == .not_ns_specific) {
            // Controller-scoped on this controller: set it through NSID 0.
            try std.testing.expectEqual(Outcome.accepted, try setAndCheck(spec.fid_err_recovery, 0, new, 0xffffffff));
        }
        try checkDefaultSaved(spec.fid_err_recovery, 1);
    }

    // --- 0Ah Write Atomicity Normal, namespace scope (NVM Figure 98) ------
    // DN = 1. Controllers that expose it as controller-scoped answer
    // Feature Not Namespace Specific to the NSID 1 set, so fall back to NSID 0.
    {
        const before = try getFeature(spec.fid_write_atomicity, spec.sel_current, 0);
        const new = before ^ 0x1;
        const o = try setAndCheck(spec.fid_write_atomicity, 1, new, 0x1);
        std.debug.print("    Set WriteAtomicityNormal 0x{x} (NSID 1) -> {s}\n", .{ new, @tagName(o) });
        try std.testing.expect(o == .accepted or o == .not_changeable or o == .not_ns_specific);
        if (o == .not_ns_specific) {
            try std.testing.expectEqual(Outcome.accepted, try setAndCheck(spec.fid_write_atomicity, 0, new, 0x1));
        }
        try checkDefaultSaved(spec.fid_write_atomicity, 0);
    }
}

/// Assert a Set Features completion carries the exact command-specific
/// status from Figure 103.
fn expectCmdSpecific(st: nvme.Status, sc: u8) !void {
    try std.testing.expectEqual(@as(u3, 1), st.sct);
    try std.testing.expectEqual(sc, st.sc);
}

/// Set Features with the Save (SV) bit in CDW10 bit 31 (Figure 401).
fn setFeatureSaved(fid: u8, nsid: u32, cdw11: u32) !nvme.Status {
    var cmd = spec.setFeaturesSaved(fid, nsid, cdw11);
    const r = try common.admin(&cmd, null, 0);
    return nvme.status(r.cqe);
}

// A mandatory feature need not be saveable or changeable. The controller
// advertises this through the supported-capabilities word (Get Features
// SEL=3, Figure 199), and a Set that contradicts it must fail with the
// matching command-specific status from Figure 103.
//
// NB: the backlog writes "SEL=2 default / SEL=3 saved"; Figure 196 defines
// default = 1, saved = 2 and supported capabilities = 3 (see `spec.sel_*`).
test "admin Set Features SEL and feature status codes" {
    // --- SEL current(0) / default(1) / saved(2) on Temperature Threshold ---
    // 04h is mandatory and (on the POC) changeable but not saveable. A feature
    // that is not saveable reports the default for a saved read (Figure 196).
    {
        const cur = try getFeature(spec.fid_temp_thresh, spec.sel_current, 0);
        const def = try getFeature(spec.fid_temp_thresh, spec.sel_default, 0);
        const sav = try getFeature(spec.fid_temp_thresh, spec.sel_saved, 0);
        const caps = try getFeature(spec.fid_temp_thresh, spec.sel_supported_caps, 0);
        std.debug.print("    04h SEL cur=0x{x} def=0x{x} sav=0x{x} caps=0x{x}\n", .{ cur, def, sav, caps });
        // Temperature Threshold returns only the 16-bit TMPTH (Figure 407).
        try std.testing.expectEqual(@as(u32, 0), cur >> 16);
        try std.testing.expectEqual(@as(u32, 0), def >> 16);
        try std.testing.expectEqual(@as(u32, 0), sav >> 16);
        // Repeated reads are stable, and only the three Figure 199 capability
        // bits are defined.
        try std.testing.expectEqual(def, try getFeature(spec.fid_temp_thresh, spec.sel_default, 0));
        const cap_mask = spec.feat_cap_svbl | spec.feat_cap_nsspec | spec.feat_cap_chang;
        try std.testing.expectEqual(@as(u32, 0), caps & ~cap_mask);
        if ((caps & spec.feat_cap_svbl) == 0) try std.testing.expectEqual(def, sav);
    }

    // --- 0Dh Feature Identifier Not Saveable ------------------------------
    // 04h is mandatory but not saveable on the POC: Set with SV = 1 must be
    // refused with 0Dh, leaving the current value unchanged (Figure 103).
    {
        const caps = try getFeature(spec.fid_temp_thresh, spec.sel_supported_caps, 0);
        if ((caps & spec.feat_cap_svbl) == 0) {
            const cur = try getFeature(spec.fid_temp_thresh, spec.sel_current, 0);
            const st = try setFeatureSaved(spec.fid_temp_thresh, 0, cur);
            std.debug.print("    04h Set SV -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
            try expectCmdSpecific(st, spec.csc_feature_not_saveable);
            try std.testing.expectEqual(cur, try getFeature(spec.fid_temp_thresh, spec.sel_current, 0));
        }
    }

    // --- 0Eh Feature Not Changeable ---------------------------------------
    // Arbitration 01h is mandatory but reports CHANG = 0 on the POC: a plain
    // Set must be refused with 0Eh, leaving the value unchanged (Figure 103).
    {
        const caps = try getFeature(spec.fid_arbitration, spec.sel_supported_caps, 0);
        if ((caps & spec.feat_cap_chang) == 0) {
            const cur = try getFeature(spec.fid_arbitration, spec.sel_current, 0);
            const st = try setFeature(spec.fid_arbitration, 0, 0x03020103);
            std.debug.print("    01h Set -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
            try expectCmdSpecific(st, spec.csc_feature_not_changeable);
            try std.testing.expectEqual(cur, try getFeature(spec.fid_arbitration, spec.sel_current, 0));
        }
    }

    // --- 0Fh Feature Not Namespace Specific --------------------------------
    // Async Event Configuration 0Bh is controller-scoped (NSSPEC = 0): Set
    // with a valid namespace identifier must be refused with 0Fh and leave the
    // value unchanged (Figure 103; §4.4 controller-scope case b).
    {
        const caps = try getFeature(spec.fid_async_event_conf, spec.sel_supported_caps, 0);
        try std.testing.expectEqual(@as(u32, 0), caps & spec.feat_cap_nsspec);
        const cur = try getFeature(spec.fid_async_event_conf, spec.sel_current, 0);
        const st = try setFeature(spec.fid_async_event_conf, 1, cur);
        std.debug.print("    0Bh Set NSID 1 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try expectCmdSpecific(st, spec.csc_feature_not_ns_specific);
        try std.testing.expectEqual(cur, try getFeature(spec.fid_async_event_conf, spec.sel_current, 0));
    }

    // --- the namespace-scoped direction -----------------------------------
    // The reverse of 0Fh (a namespace-scoped feature Set with a controller
    // NSID) is *not* 0Fh: §4.4 namespace-scope case c defers to the Figure 92
    // invalid-NSID rule, i.e. generic Invalid Namespace or Format. Error
    // Recovery 05h is namespace-scoped (NSSPEC = 1).
    {
        const caps = try getFeature(spec.fid_err_recovery, spec.sel_supported_caps, 1);
        try std.testing.expect((caps & spec.feat_cap_nsspec) != 0);
        var cmd = spec.setFeaturesCmd(spec.fid_err_recovery, 0, 0);
        const r = try common.admin(&cmd, null, 0);
        const st = nvme.status(r.cqe);
        std.debug.print("    05h Set NSID 0 -> sct={d} sc=0x{x}\n", .{ st.sct, st.sc });
        try std.testing.expect(!r.ok);
        try std.testing.expectEqual(@as(u3, 0), st.sct);
        try std.testing.expectEqual(spec.sc_invalid_namespace, st.sc);
    }
}

// Number of Queues is set once at init; setting it again while no I/O queue
// exists is legal. This test must run before any Create I/O *Q, because after
// that the command is a sequence error.
test "admin Set/Get Features Number of Queues" {
    var sf = spec.setFeaturesCmd(spec.fid_num_queues, 0, 0); // request minimum
    const set_cqe = try common.adminOk(&sf, null, 0);
    const granted = nvme.cqeDw0(set_cqe);

    var gf = spec.getFeaturesCmd(spec.fid_num_queues, 0, 0);
    const get_cqe = try common.adminOk(&gf, null, 0);
    const current = nvme.cqeDw0(get_cqe);

    std.debug.print("    numq: set granted nsqr={d} ncqr={d}; get nsqr={d} ncqr={d}\n", .{
        granted & 0xffff, granted >> 16, current & 0xffff, current >> 16,
    });
    try std.testing.expectEqual(granted, current);
    // 1.4(c) Figure 287: NCQA and NSQA are 0's based and "a minimum of one queue
    // shall be allocated", so 0 already means one queue. The mandatory minimum
    // is therefore encoded by every representable value, and there is nothing
    // further to assert: `>= 1` would demand *two* queues and false-fail a
    // controller that offers only the mandated one.
}
