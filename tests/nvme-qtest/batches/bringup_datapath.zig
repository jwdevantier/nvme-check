//! Port of the qtest POC (qtest-vs-vfio-research/nvme-qtest-poc.py) — full
//! NVMe datapath, host-side only.
//!
//! Covers what the in-tree nvme-test.c never reaches: controller enable
//! (CC.EN), admin queue bring-up, Identify, IO queue creation, an NVMe
//! Write -> Read round-trip verified in guest RAM AND on the backing image
//! (after Flush), Get Features, SMART log page, and a spec-mandated error
//! path (Set Features Number of Queues after IO queues exist ->
//! NVME_CMD_SEQ_ERROR).
//!
//! Layout mirrors include/block/nvme.h and the POC, which QEMU exercised
//! end-to-end. One stateful test block: the steps build on each other
//! (queues must exist before I/O), so this is one scenario, not three.
//! nvme.nvme's `Status` decoder shows what a shared CQE view would look like
//! if this lane grew; for now the three fields used here are decoded inline.

const std = @import("std");
const common = @import("common");

// kill the spawned QEMU when this test panics (defers do not run)
pub const panic = std.debug.FullPanic(common.qtest.panicHook);

const linux = std.os.linux;

// NvmeBar register offsets (include/block/nvme.h)
const REG_VS: u64 = 0x08;
const REG_CC: u64 = 0x14;
const REG_CSTS: u64 = 0x1C;
const REG_AQA: u64 = 0x24;
const REG_ASQ: u64 = 0x28;
const REG_ACQ: u64 = 0x30;
// doorbells (CAP.DSTRD == 0 -> 4-byte stride)
const DB0_SQ_TAIL: u64 = 0x1000;
const DB0_CQ_HEAD: u64 = 0x1004;
const DB1_SQ_TAIL: u64 = 0x1008;
const DB1_CQ_HEAD: u64 = 0x100C;

// guest-physical addresses, bump-allocated per run (src/qtest/guestmem.zig);
// assigned in the test body below
var ASQ: u64 = undefined; // admin SQ, 8 slots x 64 B
var ACQ: u64 = undefined; // admin CQ, 8 slots x 16 B
var IOSQ: u64 = undefined;
var IOCQ: u64 = undefined;
var DBUF: u64 = undefined; // admin data buffer (4 KiB)
var WRBUF: u64 = undefined; // write source (one LBA)
var RDBUF: u64 = undefined; // read destination

var g_cid: u16 = 0;
var g_sq_tail: [2]u32 = .{ 0, 0 }; // [qid] -> tail (qid 0 = admin, 1 = io)
var g_cq_head: [2]u32 = .{ 0, 0 };

/// Build a 64-byte NvmeCmd (PSDT=PRP); layout = include/block/nvme.h:592.
/// All multi-byte fields little-endian (the wire format; the test asserts
/// an LE machine up front via common.spawn's endianness handshake).
fn buildCmd(opc: u8, nv: anytype) struct { cmd: [64]u8, cid: u16 } {
    var c: [64]u8 = @splat(0);
    c[0] = opc;
    // c[1] = 0: flags, PSDT=PRP
    g_cid += 1;
    std.mem.writeInt(u16, c[2..4], g_cid, .little);
    std.mem.writeInt(u32, c[4..8], nv.nsid, .little);
    std.mem.writeInt(u64, c[16..24], nv.mptr, .little);
    std.mem.writeInt(u64, c[24..32], nv.prp1, .little);
    std.mem.writeInt(u64, c[32..40], nv.prp2, .little);
    std.mem.writeInt(u32, c[40..44], nv.cdw10, .little);
    std.mem.writeInt(u32, c[44..48], nv.cdw11, .little);
    return .{ .cmd = c, .cid = g_cid };
}

fn sqTailDb(qid: usize) u64 {
    return if (qid == 0) DB0_SQ_TAIL else DB1_SQ_TAIL;
}
fn cqHeadDb(qid: usize) u64 {
    return if (qid == 0) DB0_CQ_HEAD else DB1_CQ_HEAD;
}

fn submit(s: *common.qtest.Session, qid: usize, cmd: [64]u8) !void {
    const base: u64 = if (qid == 0) ASQ else IOSQ;
    try s.memWrite(base + @as(u64, g_sq_tail[qid]) * 64, cmd[0..]);
    g_sq_tail[qid] += 1;
    try s.writel(common.BAR0 + sqTailDb(qid), g_sq_tail[qid]);
}

const Cqe = struct { cid: u16, sc: u8, sct: u3, dw0: u32 };

/// Poll qid's CQ for a fresh phase bit; advance clock 1 ms per spin.
/// SF field (dw3 upper half): bit0 phase, bits 8:1 SC, bits 11:9 SCT.
fn pollCqe(s: *common.qtest.Session, qid: usize) !Cqe {
    const cq: u64 = if (qid == 0) ACQ else IOCQ;
    var cqe: [16]u8 = undefined;
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) {
        try s.memRead(cq + g_cq_head[qid] * 16, cqe[0..]);
        const dw0 = std.mem.readInt(u32, cqe[0..4], .little);
        const cid = std.mem.readInt(u16, cqe[12..14], .little);
        const sf = std.mem.readInt(u16, cqe[14..16], .little);
        if (sf & 1 == 1) {
            g_cq_head[qid] += 1;
            try s.writel(common.BAR0 + cqHeadDb(qid), g_cq_head[qid]);
            return .{
                .cid = cid,
                .dw0 = dw0,
                .sc = @truncate(sf >> 1),
                .sct = @truncate(sf >> 9),
            };
        }
        try s.clockStep(1_000_000);
    }
    return error.Timeout;
}

/// Create/truncate an 8 MiB raw backing file and return (path, drive spec).
fn backingImage(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var buf: [128]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = linux.openat(linux.AT.FDCWD, buf[0..path.len :0].ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    if (std.posix.errno(rc) != .SUCCESS) return error.BackingFile;
    const fd: i32 = @intCast(rc);
    if (std.posix.errno(linux.ftruncate(fd, 8 * 1024 * 1024)) != .SUCCESS) return error.BackingFile;
    _ = linux.close(fd);
    return std.fmt.allocPrint(alloc, "id=drv0,if=none,file={s},format=raw", .{path});
}

test "bring-up + datapath: enable, identify, io queues, write/read, flush" {
    const alloc = std.heap.smp_allocator;
    const img_path = try std.fmt.allocPrint(alloc, "/tmp/nvme-qtest-{d}.img", .{linux.getpid()});
    defer {
        var buf: [128]u8 = undefined;
        @memcpy(buf[0..img_path.len], img_path);
        buf[img_path.len] = 0;
        _ = linux.unlinkat(linux.AT.FDCWD, buf[0..img_path.len :0].ptr, 0);
        alloc.free(img_path);
    }
    const drive = try backingImage(alloc, img_path);
    defer alloc.free(drive);

    var gmem = common.qtest.GuestMem.init(); // -m 256M pc layout
    ASQ = try gmem.alloc(4096, 4096);
    ACQ = try gmem.alloc(4096, 4096);
    IOSQ = try gmem.alloc(4096, 4096);
    IOCQ = try gmem.alloc(4096, 4096);
    DBUF = try gmem.alloc(4096, 4096);
    WRBUF = try gmem.alloc(4096, 4096);
    RDBUF = try gmem.alloc(4096, 4096);

    const s = try common.spawnDrive("", &.{}, drive);
    defer s.deinit();
    const bar = common.BAR0;

    try common.pci.assignBar64(s, common.devfn, 0, bar);
    try common.pci.enable(s, common.devfn);

    // -- bring-up: CC.EN must be 0; program admin queues; enable; poll RDY --
    try std.testing.expectEqual(@as(u32, 0), try s.readl(bar + REG_CC));
    try s.memset(ASQ, 4096, 0);
    try s.memset(ACQ, 4096, 0);
    try s.writel(bar + REG_AQA, (7 << 16) | 7); // acqs=8, asqs=8 (0-based)
    try s.writeq(bar + REG_ASQ, ASQ);
    try s.writeq(bar + REG_ACQ, ACQ);
    try s.writel(bar + REG_CC, 0x460001); // EN | IOSQES=6 | IOCQES=4, MPS=0

    var ready = false;
    var tries: usize = 0;
    while (tries < 100 and !ready) : (tries += 1) {
        ready = (try s.readl(bar + REG_CSTS)) & 1 == 1;
        if (!ready) try s.clockStep(1_000_000);
    }
    try std.testing.expect(ready);
    const vs = try s.readl(bar + REG_VS);
    std.debug.print("controller READY, VS {d}.{d}.{d}\n", .{ vs >> 16, (vs >> 8) & 0xff, vs & 0xff });

    // -- Identify controller (CNS=1): command in guest RAM, ring doorbell --
    {
        const c = buildCmd(0x06, .{ .nsid = 0, .mptr = 0, .prp1 = DBUF, .prp2 = 0, .cdw10 = 1, .cdw11 = 0 });
        try submit(s, 0, c.cmd);
        const cqe = try pollCqe(s, 0);
        try std.testing.expectEqual(c.cid, cqe.cid);
        try std.testing.expectEqual(@as(u8, 0), cqe.sc);

        var ident: [128]u8 = undefined;
        try s.memRead(DBUF, ident[0..]);
        std.debug.print("Identify: SN='{s}' MN='{s}' FW='{s}'\n", .{
            std.mem.trim(u8, ident[4..24], " "),
            std.mem.trim(u8, ident[24..64], " "),
            std.mem.trim(u8, ident[64..72], " "),
        });
    }

    // -- Create IO CQ#1 then SQ#1 (both physically contiguous, 8 entries) --
    {
        const ccq = buildCmd(0x05, .{ .nsid = 0, .mptr = 0, .prp1 = IOCQ, .prp2 = 0, .cdw10 = (7 << 16) | 1, .cdw11 = 1 });
        try submit(s, 0, ccq.cmd);
        try std.testing.expect((try pollCqe(s, 0)).sc == 0);
        const csq = buildCmd(0x01, .{ .nsid = 0, .mptr = 0, .prp1 = IOSQ, .prp2 = 0, .cdw10 = (7 << 16) | 1, .cdw11 = (1 << 16) | 1 });
        try submit(s, 0, csq.cmd);
        try std.testing.expect((try pollCqe(s, 0)).sc == 0);
    }

    // -- NVMe Write (1 LBA at slba 0), then Read into a scrubbed buffer --
    var payload: [512]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i / 7 + 0x41);
    {
        try s.memWrite(WRBUF, payload[0..]);
        const w = buildCmd(0x01, .{ .nsid = 1, .mptr = 0, .prp1 = WRBUF, .prp2 = 0, .cdw10 = 0, .cdw11 = 0 }); // nlb=0 -> 1 block
        try submit(s, 1, w.cmd);
        try std.testing.expect((try pollCqe(s, 1)).sc == 0);

        try s.memset(RDBUF, 512, 0xCC); // prove the read rewrote it
        const r = buildCmd(0x02, .{ .nsid = 1, .mptr = 0, .prp1 = RDBUF, .prp2 = 0, .cdw10 = 0, .cdw11 = 0 });
        try submit(s, 1, r.cmd);
        try std.testing.expect((try pollCqe(s, 1)).sc == 0);
        var back: [512]u8 = undefined;
        try s.memRead(RDBUF, back[0..]);
        try std.testing.expectEqualSlices(u8, payload[0..], back[0..]);
    }

    // -- Flush, then prove the data hit the backing image --
    {
        const f = buildCmd(0x00, .{ .nsid = 1, .mptr = 0, .prp1 = 0, .prp2 = 0, .cdw10 = 0, .cdw11 = 0 });
        try submit(s, 1, f.cmd);
        try std.testing.expect((try pollCqe(s, 1)).sc == 0);

        var on_disk: [512]u8 = undefined;
        var buf: [128]u8 = undefined;
        @memcpy(buf[0..img_path.len], img_path);
        buf[img_path.len] = 0;
        const rc = linux.openat(linux.AT.FDCWD, buf[0..img_path.len :0].ptr, .{ .ACCMODE = .RDONLY }, 0);
        try std.testing.expect(std.posix.errno(rc) == .SUCCESS);
        const fd: i32 = @intCast(rc);
        var got: usize = 0;
        while (got < on_disk.len) {
            const n = linux.pread(fd, on_disk[got..].ptr, on_disk.len - got, @intCast(got));
            try std.testing.expect(std.posix.errno(n) == .SUCCESS and n > 0);
            got += n;
        }
        _ = linux.close(fd);
        try std.testing.expectEqualSlices(u8, payload[0..], on_disk[0..]);
        std.debug.print("write round-trip verified in guest RAM and on backing image\n", .{});
    }

    // -- Get Features (FID 0x07 Number of Queues); result lands in CQE dw0 --
    {
        const gf = buildCmd(0x0a, .{ .nsid = 0, .mptr = 0, .prp1 = 0, .prp2 = 0, .cdw10 = 0x07, .cdw11 = 0 });
        try submit(s, 0, gf.cmd);
        const cqe = try pollCqe(s, 0);
        try std.testing.expect(cqe.sc == 0);
        std.debug.print("Get Features(NumQueues): NSQR={d} NCQR={d}\n", .{ cqe.dw0 & 0xffff, cqe.dw0 >> 16 });
    }

    // -- Get Log Page: SMART / Health (lid 0x02, 512 B) --
    {
        try s.memset(DBUF, 512, 0xEE);
        const gl = buildCmd(0x02, .{ .nsid = 0xffffffff, .mptr = 0, .prp1 = DBUF, .prp2 = 0, .cdw10 = (127 << 16) | 0x02, .cdw11 = 0 });
        try submit(s, 0, gl.cmd);
        try std.testing.expect((try pollCqe(s, 0)).sc == 0);
        var smart: [4]u8 = undefined;
        try s.memRead(DBUF, smart[0..]);
        std.debug.print("SMART: critical_warning=0x{x:0>2} temp={d}K\n", .{
            smart[0], std.mem.readInt(u16, smart[1..3], .little),
        });
    }

    // -- Spec-mandated error path: Set Features(NumQueues) once IO queues
    // -- exist must fail with NVME_CMD_SEQ_ERROR (0x0C), per spec and
    // -- hw/nvme/ctrl.c.
    {
        const sf = buildCmd(0x09, .{ .nsid = 0, .mptr = 0, .prp1 = 0, .prp2 = 0, .cdw10 = 0x07, .cdw11 = 3 | (3 << 16) });
        try submit(s, 0, sf.cmd);
        const cqe = try pollCqe(s, 0);
        try std.testing.expectEqual(@as(u8, 0x0C), cqe.sc);
        std.debug.print("Set Features(NumQueues) post-IO-queues -> CMD_SEQ_ERROR (spec-correct)\n", .{});
    }
}
