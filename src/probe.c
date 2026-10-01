/* SPDX-License-Identifier: LGPL-2.1-or-later OR MIT */
/*
 * probe.c — a line-for-line C port of probe.zig.
 *
 * Exists as a side-by-side comparison (what the binding surface feels like
 * from C vs from Zig); the Zig program remains the built artifact.
 * Compile check (zig cc works fine as a C compiler), against the same
 * libvfn tree the build itself uses (the pinned dependency, or
 * -Dlibvfn-src's override — materialized locally first):
 *
 *   zig build libvfn-src   # -> zig-out/libvfn-src
 *   zig cc -c src/probe.c -o /tmp/probe.o \
 *     -Izig-out/libvfn-src/include -Izig-out/libvfn-src/src \
 *     -Izig-out/libvfn-src/ccan -Ivendor
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/uio.h> /* struct iovec, referenced by vfn/nvme.h prototypes */
#include <time.h>

#include <vfn/nvme.h>

/* from src/vfn_shim.c */
void vfn_shim_log_set_debug(void);
int vfn_shim_errno(void);
long vfn_shim_pread(struct nvme_ctrl *ctrl, void *buf, size_t len, unsigned long off);
uint64_t vfn_shim_mmio_cap(struct nvme_ctrl *ctrl);
int vfn_shim_dbbuf_selftest(void);
int vfn_shim_dbbuf_active(struct nvme_ctrl *ctrl);
uint32_t vfn_shim_dbbuf_sq_doorbell(struct nvme_ctrl *ctrl);
uint32_t vfn_shim_dbbuf_sq_eventidx(struct nvme_ctrl *ctrl);
uint32_t vfn_shim_dbbuf_cq_doorbell(struct nvme_ctrl *ctrl);
uint32_t vfn_shim_dbbuf_cq_eventidx(struct nvme_ctrl *ctrl);
uint16_t vfn_shim_adminq_sq_tail(struct nvme_ctrl *ctrl);
uint16_t vfn_shim_adminq_cq_head(struct nvme_ctrl *ctrl);

#define NVME_ADMIN_IDENTIFY 0x06
#define IDENTIFY_DATA_SIZE 4096

/* Byte-order-explicit decoders: NVMe is little-endian on the wire, and this
 * code must also be correct on a big-endian (s390x) host. */
static uint16_t get_le16(const uint8_t *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint64_t get_le64(const uint8_t *p)
{
	uint64_t v = 0;
	for (int i = 7; i >= 0; i--)
		v = (v << 8) | p[i];
	return v;
}

static uint64_t get_be64(const uint8_t *p)
{
	uint64_t v = 0;
	for (int i = 0; i < 8; i++)
		v = (v << 8) | p[i];
	return v;
}

/* Page-aligned, page-sized: libvfn's iommufd backend rejects unaligned
 * user_va/length with EINVAL before the command is issued. */
static uint8_t idbuf[IDENTIFY_DATA_SIZE] __attribute__((aligned(4096)));

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: nvme-probe <bdf>\n");
		return 2;
	}
	const char *bdf = argv[1];

	struct nvme_ctrl ctrl = {0};

	/* Device-independent byte-order check of the shadow-doorbell encoding.
	 * This is the actual code the endianness fix touched; on a big-endian
	 * host it fails unless nvme_try_dbbuf() encodes/decodes little-endian. */
	int db_selftest = vfn_shim_dbbuf_selftest();
	if (db_selftest != 0) {
		fprintf(stderr, "DBBUF: selftest FAILED (code %d)\n", db_selftest);
		return 1;
	}
	fprintf(stderr, "DBBUF: selftest=ok\n");

	vfn_shim_log_set_debug();
	int init_rc = nvme_init(&ctrl, bdf, NULL);

	/* CAP is at BAR0 offset 0. Compare the VFIO-pread bytes against libvfn's
	 * (mmap-based) read; on s390x the mmap read is unavailable (regs == NULL)
	 * and only pread remains. */
	uint8_t cap_raw[8] = {0};
	long prc = vfn_shim_pread(&ctrl, cap_raw, sizeof cap_raw, 0);
	uint64_t cap_le = get_le64(cap_raw);
	uint64_t cap_be = get_be64(cap_raw);
	fprintf(stderr, "CAP: pread rc=%ld le=0x%llx be=0x%llx mmio=0x%llx (mqes_le=%llu)\n",
		prc,
		(unsigned long long)cap_le,
		(unsigned long long)cap_be,
		(unsigned long long)vfn_shim_mmio_cap(&ctrl),
		(unsigned long long)(cap_le & 0xffff));

	if (init_rc != 0) {
		struct vfio_region_info *ri = &ctrl.pci.bar_region_info[0];
		fprintf(stderr, "nvme_init(%s) failed: errno=%d; bar0 index=%u flags=0x%x size=0x%llx offset=0x%llx\n",
			bdf, vfn_shim_errno(), ri->index, ri->flags,
			(unsigned long long)ri->size,
			(unsigned long long)ri->offset);
		return 1;
	}

	union nvme_cmd cmd = {0};
	cmd.identify.opcode = NVME_ADMIN_IDENTIFY;
	cmd.identify.cns = 0x01; /* Identify Controller */
	cmd.identify.nsid = 0;   /* == cpu_to_le32(0) */

	if (nvme_admin(&ctrl, &cmd, idbuf, IDENTIFY_DATA_SIZE, NULL) != 0) {
		fprintf(stderr, "nvme_admin(identify) failed\n");
		nvme_close(&ctrl);
		return 1;
	}

	uint16_t vid = get_le16(&idbuf[0]);
	uint16_t ssvid = get_le16(&idbuf[2]);
	/* sn/mn are fixed-width, NUL-padded strings: print up to the first NUL */
	fprintf(stderr, "nvme_init + Identify OK on %s\n", bdf);
	fprintf(stderr, "  vid=0x%x ssvid=0x%x\n", vid, ssvid);
	fprintf(stderr, "  sn=%.*s\n", 20, (char *)&idbuf[4]);
	fprintf(stderr, "  mn=%.*s\n", 40, (char *)&idbuf[24]);

	/* Shadow-doorbell (DBBUF) device check. libvfn negotiates the shadow
	 * buffers in nvme_init() when OACS.DBCONFIG is set (QEMU: dbcs=on by
	 * default); the device must then record the submitted queue tail in the
	 * shadow EventIdx. If QEMU's dbbuf handling regresses, it stays stale and
	 * this probe exits non-zero. */
	if (vfn_shim_dbbuf_active(&ctrl) != 0) {
		uint16_t sq_tail = vfn_shim_adminq_sq_tail(&ctrl);
		uint16_t cq_head = vfn_shim_adminq_cq_head(&ctrl);

		/* The device writes the shadow EventIdx asynchronously (via the CQ
		 * doorbell trap that reaches it), so poll briefly for it to catch up
		 * instead of sampling one instant and racing the update. */
		const struct timespec ts = { .tv_sec = 0, .tv_nsec = 5 * 1000 * 1000 };
		for (int spins = 0; spins < 400; spins++) {
			if (vfn_shim_dbbuf_sq_eventidx(&ctrl) == (uint32_t)sq_tail &&
			    vfn_shim_dbbuf_cq_eventidx(&ctrl) == (uint32_t)cq_head)
				break;
			nanosleep(&ts, NULL);
		}

		uint32_t sq_db = vfn_shim_dbbuf_sq_doorbell(&ctrl);
		uint32_t sq_ei = vfn_shim_dbbuf_sq_eventidx(&ctrl);
		uint32_t cq_db = vfn_shim_dbbuf_cq_doorbell(&ctrl);
		uint32_t cq_ei = vfn_shim_dbbuf_cq_eventidx(&ctrl);
		fprintf(stderr, "DBBUF: active=1 sq(db=%u ei=%u tail=%u) cq(db=%u ei=%u head=%u)\n",
			sq_db, sq_ei, sq_tail, cq_db, cq_ei, cq_head);
		if (sq_db != (uint32_t)sq_tail || sq_ei != (uint32_t)sq_tail) {
			fprintf(stderr, "DBBUF: FAILED sq shadow (device/shadow mismatch)\n");
			nvme_close(&ctrl);
			return 1;
		}
		if (cq_db != (uint32_t)cq_head || cq_ei != (uint32_t)cq_head) {
			fprintf(stderr, "DBBUF: FAILED cq shadow (device/shadow mismatch)\n");
			nvme_close(&ctrl);
			return 1;
		}
	} else {
		fprintf(stderr, "DBBUF: active=0 (dbcs off or unsupported)\n");
	}

	nvme_close(&ctrl);
	return 0;
}
