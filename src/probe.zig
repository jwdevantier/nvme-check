const std = @import("std");
const c = @import("vfn_c");

extern fn vfn_shim_log_set_debug() void;
extern fn vfn_shim_errno() c_int;
extern fn vfn_shim_pread(ctrl: *c.nvme_ctrl, buf: [*]u8, len: usize, off: c_ulong) c_long;
extern fn vfn_shim_mmio_cap(ctrl: *c.nvme_ctrl) u64;
extern fn vfn_shim_dbbuf_selftest() c_int;
extern fn vfn_shim_dbbuf_active(ctrl: *c.nvme_ctrl) c_int;
extern fn vfn_shim_dbbuf_sq_doorbell(ctrl: *c.nvme_ctrl) u32;
extern fn vfn_shim_dbbuf_sq_eventidx(ctrl: *c.nvme_ctrl) u32;
extern fn vfn_shim_dbbuf_cq_doorbell(ctrl: *c.nvme_ctrl) u32;
extern fn vfn_shim_dbbuf_cq_eventidx(ctrl: *c.nvme_ctrl) u32;
extern fn vfn_shim_adminq_sq_tail(ctrl: *c.nvme_ctrl) u16;
extern fn vfn_shim_adminq_cq_head(ctrl: *c.nvme_ctrl) u16;

const NVME_ADMIN_IDENTIFY: u8 = 0x06;
const IDENTIFY_DATA_SIZE = 4096;

// Page-aligned, page-sized: libvfn's iommufd backend rejects unaligned
// user_va/length with EINVAL before the command is issued.
var idbuf: [IDENTIFY_DATA_SIZE]u8 align(4096) = undefined;

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next(); // argv[0]
    const bdf = args.next() orelse {
        std.debug.print("usage: nvme-probe <bdf>\n", .{});
        std.process.exit(2);
    };

    var bdf_buf: [256]u8 = @splat(0);
    const n = @min(bdf.len, bdf_buf.len - 1);
    @memcpy(bdf_buf[0..n], bdf[0..n]);

    var ctrl: c.nvme_ctrl = std.mem.zeroes(c.nvme_ctrl);

    // Device-independent byte-order check of the shadow-doorbell encoding.
    // This is the actual code the endianness fix touched; on a big-endian
    // host it fails unless nvme_try_dbbuf() encodes/decodes little-endian.
    const db_selftest = vfn_shim_dbbuf_selftest();
    if (db_selftest != 0) {
        std.debug.print("DBBUF: selftest FAILED (code {d})\n", .{db_selftest});
        std.process.exit(1);
    }
    std.debug.print("DBBUF: selftest=ok\n", .{});

    vfn_shim_log_set_debug();
    const init_rc = c.nvme_init(&ctrl, @ptrCast(&bdf_buf), null);

    // CAP is at BAR0 offset 0. Compare the VFIO-pread bytes against libvfn's
    // (mmap-based) read; on s390x the mmap read is unavailable (regs == NULL)
    // and only pread remains.
    var cap_raw: [8]u8 = @splat(0);
    const prc = vfn_shim_pread(&ctrl, &cap_raw, cap_raw.len, 0);
    const cap_le = std.mem.readInt(u64, &cap_raw, .little);
    const cap_be = std.mem.readInt(u64, &cap_raw, .big);
    std.debug.print(
        "CAP: pread rc={d} le=0x{x} be=0x{x} mmio=0x{x} (mqes_le={d})\n",
        .{ prc, cap_le, cap_be, vfn_shim_mmio_cap(&ctrl), cap_le & 0xffff },
    );

    if (init_rc != 0) {
        const ri = ctrl.pci.bar_region_info[0];
        std.debug.print(
            "nvme_init({s}) failed: errno={d}; bar0 index={d} flags=0x{x} size=0x{x} offset=0x{x}\n",
            .{ bdf, vfn_shim_errno(), ri.index, ri.flags, ri.size, ri.offset },
        );
        std.process.exit(1);
    }
    defer c.nvme_close(&ctrl);

    var cmd: c.nvme_cmd = std.mem.zeroes(c.nvme_cmd);
    cmd.identify.opcode = NVME_ADMIN_IDENTIFY;
    cmd.identify.cns = 0x01; // Identify Controller
    cmd.identify.nsid = c.cpu_to_le32(0);

    if (c.nvme_admin(&ctrl, &cmd, &idbuf, IDENTIFY_DATA_SIZE, null) != 0) {
        std.debug.print("nvme_admin(identify) failed\n", .{});
        std.process.exit(1);
    }

    const vid = std.mem.readInt(u16, idbuf[0..2], .little);
    const ssvid = std.mem.readInt(u16, idbuf[2..4], .little);
    const sn = std.mem.sliceTo(idbuf[4..24], 0);
    const mn = std.mem.sliceTo(idbuf[24..64], 0);

    std.debug.print("nvme_init + Identify OK on {s}\n", .{bdf});
    std.debug.print("  vid=0x{x} ssvid=0x{x}\n", .{ vid, ssvid });
    std.debug.print("  sn={s}\n", .{sn});
    std.debug.print("  mn={s}\n", .{mn});

    // Shadow-doorbell (DBBUF) device check. libvfn negotiates the shadow
    // buffers in nvme_init() when OACS.DBCONFIG is set (QEMU: dbcs=on by
    // default); the device must then record the submitted queue tail in the
    // shadow EventIdx. If QEMU's dbbuf handling regresses, it stays stale and
    // this probe exits non-zero.
    if (vfn_shim_dbbuf_active(&ctrl) != 0) {
        const sq_tail = vfn_shim_adminq_sq_tail(&ctrl);
        const cq_head = vfn_shim_adminq_cq_head(&ctrl);

        // The device writes the shadow EventIdx asynchronously (via the CQ
        // doorbell trap that reaches it), so poll briefly for it to catch up
        // instead of sampling one instant and racing the update.
        var spins: u32 = 0;
        var ts: std.os.linux.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        while (spins < 400) : (spins += 1) {
            if (vfn_shim_dbbuf_sq_eventidx(&ctrl) == @as(u32, sq_tail) and
                vfn_shim_dbbuf_cq_eventidx(&ctrl) == @as(u32, cq_head))
                break;
            _ = std.os.linux.nanosleep(&ts, null);
        }

        const sq_db = vfn_shim_dbbuf_sq_doorbell(&ctrl);
        const sq_ei = vfn_shim_dbbuf_sq_eventidx(&ctrl);
        const cq_db = vfn_shim_dbbuf_cq_doorbell(&ctrl);
        const cq_ei = vfn_shim_dbbuf_cq_eventidx(&ctrl);
        std.debug.print(
            "DBBUF: active=1 sq(db={d} ei={d} tail={d}) cq(db={d} ei={d} head={d})\n",
            .{ sq_db, sq_ei, sq_tail, cq_db, cq_ei, cq_head },
        );
        if (sq_db != @as(u32, sq_tail) or sq_ei != @as(u32, sq_tail)) {
            std.debug.print("DBBUF: FAILED sq shadow (device/shadow mismatch)\n", .{});
            std.process.exit(1);
        }
        if (cq_db != @as(u32, cq_head) or cq_ei != @as(u32, cq_head)) {
            std.debug.print("DBBUF: FAILED cq shadow (device/shadow mismatch)\n", .{});
            std.process.exit(1);
        }
    } else {
        std.debug.print("DBBUF: active=0 (dbcs off or unsupported)\n", .{});
    }
}
