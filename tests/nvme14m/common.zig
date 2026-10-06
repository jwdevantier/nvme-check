//! Shared device state and low-level accessors for the NVMe 1.4 mandatory
//! batch. One lazily-opened controller per test binary; the Zig test runner is
//! single-threaded, so no lock is needed.
//!
//! Opening goes through libvfn's `nvme_init()` (via `vfntest.openFromEnv`):
//! reset → admin queue → enable → Identify. From there the batch inspects the
//! controller at the register/config-space/command level.

const std = @import("std");
const c = @import("vfn_c");
const vfn = @import("vfn");
const nvme = @import("nvme");
const vfntest = @import("vfntest");

/// The suite's pure spec definitions; batches reach them as
/// `@import("common").spec`.
pub const spec = @import("spec.zig");

// libvfn's nvme_init() expects a zeroed controller (it does not clear it
// itself); an `undefined` global would poison it.
var g_ctrl: vfn.Ctrl = std.mem.zeroes(vfn.Ctrl);
var g_init = false;
var g_cntlid: u16 = 0;

/// Open the controller named by $NVME_BDF once, learning its controller id.
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

    g_cntlid = spec.get16(buf.bytes(), spec.idc_cntlid);
    g_init = true;
    return &g_ctrl;
}

pub fn cntlid() u16 {
    return g_cntlid;
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

// --- DMA buffers ----------------------------------------------------------

/// A page-aligned buffer mapped into the controller's IOMMU, with the IOVA to
/// program into PRPs. libvfn's iommufd backend rejects unaligned or non-page-
/// multiple mappings, hence the page-buffer requirement.
pub const Dma = struct {
    buf: vfntest.PageBuf,
    iova: c.iova_t,
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
