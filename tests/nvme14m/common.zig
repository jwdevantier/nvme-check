//! Shared device state and low-level accessors for the NVMe 1.4 mandatory
//! suite's test programs. One lazily-opened controller per test binary; the
//! Zig test runner is single-threaded, so no lock is needed.
//!
//! Opening goes through libvfn's `nvme_init()` (via `vfntest.openFromEnv`):
//! reset → admin queue → enable → Identify. From there the program inspects
//! the
//! controller at the register/config-space/command level.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");

/// The suite's pure spec definitions; test programs reach them as
/// `@import("common").spec`.
pub const spec = @import("spec.zig");

/// Skip the current test with a reason printed next to the Zig test runner's
/// SKIP line. `error.SkipZigTest` itself carries no message.
pub fn skip(comptime fmt: []const u8, args: anytype) error{SkipZigTest} {
    std.debug.print("    skip: " ++ fmt ++ "\n", args);
    return error.SkipZigTest;
}

/// Like std.testing.expectEqual, but prints a context message when the
/// assertion fails. Zig's testing API has no message parameter.
pub fn expectEqualMsg(
    expected: anytype,
    actual: @TypeOf(expected),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    std.testing.expectEqual(expected, actual) catch |err| {
        std.debug.print("    " ++ fmt ++ "\n", args);
        return err;
    };
}

/// Human-readable name for a completion status code. `sct` selects the
/// generic (0) or command-specific (1) table; the numeric values are printed
/// by `expectStatus` alongside these names.
pub fn statusName(sct: u8, sc: u8) []const u8 {
    return switch (sct) {
        spec.sct_generic => switch (sc) {
            0x00 => "Success",
            0x01 => "Invalid Command Opcode",
            0x02 => "Invalid Field in Command",
            0x03 => "Command ID Conflict",
            0x04 => "Data Transfer Error",
            0x05 => "Command Aborted due to Power Loss",
            0x06 => "Internal Error",
            0x07 => "Command Abort Requested",
            0x08 => "Command Aborted due to SQ Deletion",
            0x09 => "Command Aborted due to Failed Fused Command",
            0x0a => "Command Aborted due to Missing Fused Command",
            0x0b => "Invalid Namespace or Format",
            0x0c => "Command Sequence Error",
            0x0d => "Invalid SGL Last Segment",
            0x0e => "Invalid Number of SGL Descriptors",
            0x0f => "Data SGL Length Invalid",
            0x10 => "Metadata SGL Length Invalid",
            0x11 => "SGL Descriptor Type Invalid",
            0x12 => "Invalid Use of Controller Memory Buffer",
            0x13 => "PRP Offset Invalid",
            0x14 => "Atomic Write Unit Normal",
            0x15 => "Operation Denied",
            0x16 => "SGL Data Block Granularity Invalid",
            0x17 => "Command Not Supported for Queue in CMB",
            0x18 => "Namespace is Write Protected",
            0x19 => "Command Interrupted",
            0x1a => "Transient Transport Error",
            0x80 => "LBA Out of Range",
            0x81 => "Capacity Exceeded",
            0x82 => "Namespace Not Ready",
            0x83 => "Namespace Reservation Conflict",
            0x84 => "Format in Progress",
            else => "Unknown Generic Status",
        },
        spec.sct_cmd_specific => switch (sc) {
            0x00 => "Completion Queue Invalid",
            0x01 => "Invalid Queue Identifier",
            0x02 => "Invalid Queue Size",
            0x03 => "Abort Command Limit Exceeded",
            0x05 => "Asynchronous Event Request Limit Exceeded",
            0x06 => "Invalid Firmware Slot",
            0x07 => "Invalid Firmware Image",
            0x08 => "Invalid Interrupt Vector",
            0x09 => "Invalid Log Page",
            0x0a => "Invalid Format",
            0x0b => "Firmware Activation Requires Conventional Reset",
            0x0c => "Invalid Queue Deletion",
            0x0d => "Feature Identifier Not Saveable",
            0x0e => "Feature Not Changeable",
            0x0f => "Feature Not Namespace Specific",
            0x10 => "Firmware Activation Requires NVM Subsystem Reset",
            0x11 => "Firmware Activation Requires Controller Level Reset",
            0x12 => "Firmware Activation Requires Maximum Time Violation",
            0x13 => "Firmware Activation Prohibited",
            0x14 => "Overlapping Range",
            0x15 => "Namespace Insufficient Capacity",
            0x16 => "Namespace Identifier Unavailable",
            0x18 => "Namespace Already Attached",
            0x19 => "Namespace Is Private",
            0x1a => "Namespace Not Attached",
            else => "Unknown Command-Specific Status",
        },
        else => "Unknown Status Type",
    };
}

/// Assert both SCT and SC, printing the human-readable names and numeric
/// values on mismatch instead of Zig's bare `expected 2, found 4`.
pub fn expectStatus(
    expected_sct: u8,
    expected_sc: u8,
    st: nvme.Status,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const actual_sct: u8 = @intCast(st.sct);
    if (actual_sct == expected_sct and st.sc == expected_sc) return;

    std.debug.print("    " ++ fmt ++ "\n", args);
    std.debug.print(
        "    expected {s} (SCT={d} SC=0x{x}), got {s} (SCT={d} SC=0x{x})\n",
        .{
            statusName(expected_sct, expected_sc),
            expected_sct,
            expected_sc,
            statusName(actual_sct, st.sc),
            actual_sct,
            st.sc,
        },
    );
    return error.StatusMismatch;
}

// libvfn's nvme_init() expects a zeroed controller (it does not clear it
// itself); an `undefined` global would poison it.
var g_ctrl: vfn.Ctrl = std.mem.zeroes(vfn.Ctrl);
var g_init = false;

/// Open the controller named by $NVME_BDF once.
pub fn ctrl() !*vfn.Ctrl {
    if (g_init) return &g_ctrl;

    // NVME_DEBUG=1 turns on libvfn's logging (to stderr) for diagnosis.
    if (std.c.getenv("NVME_DEBUG") != null) vfn.enableDebugLog();

    try vfntest.openFromEnv(&g_ctrl);

    var buf = try vfntest.pageBuffer(4096);
    defer buf.deinit();

    var cmd = spec.identifyCmd(spec.cns_ctrl, 0, 0);
    const r = vfntest.admin(&g_ctrl, &cmd, ptr(buf), buf.bytes().len);
    const st = nvme.status(r.cqe);
    if (!r.ok or st.sc != 0 or st.sct != 0) return error.IdentifyFailed;

    g_init = true;
    return &g_ctrl;
}

/// Submit an admin command. `ok == false` may mean a device error status (the
/// completion is still valid) — inspect `nvme.status(r.cqe)`.
pub fn admin(cmd: *vfn.Cmd, data: ?*anyopaque, len: usize) !vfntest.AdminResult {
    return vfntest.admin(try ctrl(), cmd, data, len);
}

/// Submit an admin command, requiring success (transport *and* device status).
pub fn adminOk(cmd: *vfn.Cmd, data: ?*anyopaque, len: usize) !vfn.Cqe {
    const r = try admin(cmd, data, len);
    if (!r.ok) return error.NvmeCommandFailed;
    return r.cqe;
}

/// Probe an optional NVM command opcode on a throwaway I/O queue and return
/// its completion status. `nsid` is 0, which is invalid for every I/O
/// command, so a recognised opcode is rejected with a normal error status
/// (never `Invalid Command Opcode`) without reading or writing user data.
/// Used to check the `ONCS` support bits against the opcodes they name.
pub fn probeNvmOpcode(opcode: u8) !nvme.Status {
    const ctrl_ = try ctrl();

    if (c.nvme_create_iocq(ctrl_, 1, 8, -1) != 0) return error.CreateIocqFailed;
    defer _ = c.nvme_delete_iocq(ctrl_, 1);
    if (c.nvme_create_iosq(ctrl_, 1, 8, &ctrl_.cq[1], 0) != 0) return error.CreateIosqFailed;
    defer _ = c.nvme_delete_iosq(ctrl_, 1);

    const rq = vfn.rqAcquire(&ctrl_.sq[1]) orelse return error.NoRequestTracker;
    defer vfn.rqRelease(rq);

    var cmd = std.mem.zeroes(vfn.Cmd);
    cmd.rw.opcode = opcode;
    cmd.rw.nsid = c.cpu_to_le32(0);
    vfn.rqExec(rq, &cmd);

    var cqe = std.mem.zeroes(vfn.Cqe);
    // A valid probe completes with an error status (NSID 0 is invalid), which
    // nvme_rq_spin reports as non-zero after filling `cqe`; decode it either
    // way.
    _ = c.nvme_rq_spin(rq, &cqe);
    return nvme.status(cqe);
}

/// A page-aligned DMA buffer as a raw pointer for libvfn.
pub fn ptr(buf: vfntest.PageBuf) ?*anyopaque {
    return @ptrCast(buf.bytes().ptr);
}

// --- BAR0 register access (libvfn mapped the register page) ---------------

fn regAt(ctrl_: *vfn.Ctrl, off: usize) ?*anyopaque {
    const base: [*c]u8 = @ptrCast(ctrl_.regs);
    return @ptrCast(base + off);
}

pub fn regRead32(ctrl_: *vfn.Ctrl, off: usize) u32 {
    return c.le32_to_cpu(c.mmio_read32(regAt(ctrl_, off)));
}

pub fn regWrite32(ctrl_: *vfn.Ctrl, off: usize, v: u32) void {
    c.mmio_write32(regAt(ctrl_, off), c.cpu_to_le32(v));
}

pub fn regRead64(ctrl_: *vfn.Ctrl, off: usize) u64 {
    return c.le64_to_cpu(c.mmio_read64(regAt(ctrl_, off)));
}

pub fn regWrite64(ctrl_: *vfn.Ctrl, off: usize, v: u64) void {
    // The register is little-endian; write both halves through the 32-bit
    // accessor (libvfn exposes no mmio_write64 wrapper).
    regWrite32(ctrl_, off, @truncate(v));
    regWrite32(ctrl_, off + 4, @truncate(v >> 32));
}

/// Write a 32-bit doorbell. `off` is relative to the doorbell region (BAR0
/// offset 1000h): libvfn maps `regs` as only that first page, so the doorbells
/// live behind `ctrl.doorbells` and `regAt` cannot reach them.
pub fn dbWrite32(ctrl_: *vfn.Ctrl, off: usize, v: u32) void {
    const base: [*c]u8 = @ptrCast(ctrl_.doorbells);
    c.mmio_write32(@ptrCast(base + off), c.cpu_to_le32(v));
}

/// Read a 32-bit word from the doorbell region (the inverse of `dbWrite32`).
/// Used to save/restore the MSI-X table, which lives above the doorbell window
/// inside the same BAR0 mapping.
pub fn dbRead32(ctrl_: *vfn.Ctrl, off: usize) u32 {
    const base: [*c]u8 = @ptrCast(ctrl_.doorbells);
    return c.le32_to_cpu(c.mmio_read32(@ptrCast(base + off)));
}

// --- PCI config space (little-endian on every host) -----------------------

pub fn cfgRead8(ctrl_: *vfn.Ctrl, off: u64) u8 {
    var b: [1]u8 = undefined;
    _ = c.vfio_pci_read_config(&ctrl_.pci, &b, b.len, @intCast(off));
    return b[0];
}

pub fn cfgRead16(ctrl_: *vfn.Ctrl, off: u64) u16 {
    var b: [2]u8 = undefined;
    _ = c.vfio_pci_read_config(&ctrl_.pci, &b, b.len, @intCast(off));
    return std.mem.readInt(u16, &b, .little);
}

pub fn cfgRead32(ctrl_: *vfn.Ctrl, off: u64) u32 {
    var b: [4]u8 = undefined;
    _ = c.vfio_pci_read_config(&ctrl_.pci, &b, b.len, @intCast(off));
    return std.mem.readInt(u32, &b, .little);
}

pub fn cfgWrite8(ctrl_: *vfn.Ctrl, off: u64, v: u8) void {
    var b: [1]u8 = .{v};
    _ = c.vfio_pci_write_config(&ctrl_.pci, &b, b.len, @intCast(off));
}

pub fn cfgWrite16(ctrl_: *vfn.Ctrl, off: u64, v: u16) void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    _ = c.vfio_pci_write_config(&ctrl_.pci, &b, b.len, @intCast(off));
}

// --- PCI capabilities -----------------------------------------------------

/// Walk the PCI capability list (status bit 4, Figure PCI-1) for `id` and
/// return the capability's config-space offset, or null if it is absent.
pub fn pciFindCap(ctrl_: *vfn.Ctrl, id: u8) ?u8 {
    if (cfgRead16(ctrl_, 0x06) & 0x10 == 0) return null;
    var cap: u8 = cfgRead8(ctrl_, 0x34) & 0xfc;
    var guard: usize = 0;
    while (cap != 0 and guard < 48) : (guard += 1) {
        if (cfgRead8(ctrl_, cap) == id) return cap;
        cap = cfgRead8(ctrl_, @as(u64, cap) + 1) & 0xfc;
    }
    return null;
}

/// MSI-X capability (PCI capability ID 11h). `vectors` is MXC.TS + 1, the
/// number of interrupt vectors the controller can signal. `table`/`pba` are
/// the raw Table/PBA Offset+BIR registers: bits 31:3 are the 8-byte-aligned
/// offset and bits 2:0 select the BAR.
pub const Msix = struct {
    cap: u8,
    mc: u16,
    vectors: u16,
    table: u32,
    pba: u32,

    /// MSI-X Enable (Message Control bit 15). While set, INTMS/INTMC are off
    /// limits (BASE §3.1.4.3, §3.1.4.4).
    pub fn enabled(self: Msix) bool {
        return self.mc & 0x8000 != 0;
    }

    /// MSI-X Function Mask (Message Control bit 14).
    pub fn functionMasked(self: Msix) bool {
        return self.mc & 0x4000 != 0;
    }

    pub fn tableBir(self: Msix) u3 {
        return @truncate(self.table & 0x7);
    }

    pub fn tableOffset(self: Msix) u32 {
        return self.table & 0xfffffff8;
    }

    pub fn pbaBir(self: Msix) u3 {
        return @truncate(self.pba & 0x7);
    }

    pub fn pbaOffset(self: Msix) u32 {
        return self.pba & 0xfffffff8;
    }
};

/// Decode the MSI-X capability, or fail if the controller does not expose one.
pub fn msix() !Msix {
    const ctrl_ = try ctrl();
    const cap = pciFindCap(ctrl_, 0x11) orelse return error.NoMsixCapability;
    const mc = cfgRead16(ctrl_, @as(u64, cap) + 2);
    return .{
        .cap = cap,
        .mc = mc,
        .vectors = (mc & 0x7ff) + 1,
        .table = cfgRead32(ctrl_, @as(u64, cap) + 4),
        .pba = cfgRead32(ctrl_, @as(u64, cap) + 8),
    };
}

// --- DMA buffers ----------------------------------------------------------

/// A page-aligned buffer mapped into the controller's IOMMU, with the IOVA to
/// program into PRPs. libvfn's iommufd backend rejects unaligned or non-page-
/// multiple mappings, hence the page-buffer requirement.
pub const Dma = struct {
    buf: vfntest.PageBuf,
    iova: c.iova_t,

    /// Unmap the IOMMU mapping and release the host buffer. Callers that use
    /// this instead of `buf.deinit()` do not leak the IOVA, so a later
    /// `pageBuffer` on a reused host VA cannot pick up a stale mapping.
    pub fn deinit(self: *Dma) void {
        const ctrl_ = ctrl() catch {
            self.buf.deinit();
            return;
        };
        const ctx = c.__iommu_ctx(ctrl_);
        var len: usize = self.buf.bytes().len;
        _ = c.iommu_unmap_vaddr(ctx, @ptrCast(self.buf.bytes().ptr), &len);
        self.buf.deinit();
    }
};

pub fn dmaMap(len: usize) !Dma {
    const ctrl_ = try ctrl();
    const buf = try vfntest.pageBuffer(len);
    const ctx = c.__iommu_ctx(ctrl_);
    const v: ?*anyopaque = @ptrCast(buf.bytes().ptr);

    var iova: c.iova_t = 0;
    if (!c.iommu_translate_vaddr(ctx, v, &iova)) {
        if (c.iommu_map_vaddr(ctx, v, buf.bytes().len, &iova, 0) != 0) {
            buf.deinit();
            return error.IommuMapFailed;
        }
    }
    return .{ .buf = buf, .iova = iova };
}
