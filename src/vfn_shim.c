/* SPDX-License-Identifier: LGPL-2.1-or-later OR MIT */
/*
 * libvfn exports its queue/request helpers as `static inline` functions in
 * the public headers. Zig's translate-c cannot translate the ones that use
 * inline asm (the memory barriers in support/barrier.h) or the GCC atomic
 * macros (support/atomic.h); it demotes them to `extern` declarations with no
 * body, and the translated bodies of e.g. nvme_sq_exec()/nvme_cq_update_head()
 * therefore reference undefined symbols.
 *
 * This shim emits those helpers as real, global symbols under their original
 * names so the translated Zig bindings link. We rename the header's `static
 * inline` definitions (via the preprocessor) so the C identifiers don't
 * collide with the global definitions we introduce afterwards.
 */
#define nvme_sq_update_tail    vfn_impl_nvme_sq_update_tail
#define nvme_try_dbbuf         vfn_impl_nvme_try_dbbuf
#define nvme_cq_get_cqe        vfn_impl_nvme_cq_get_cqe
#define nvme_rq_acquire_atomic vfn_impl_nvme_rq_acquire_atomic
#define nvme_rq_release_atomic vfn_impl_nvme_rq_release_atomic
#define bcr_serialize          vfn_impl_bcr_serialize

#include <errno.h>
#include <stdint.h>
#include <unistd.h>

#include <vfn/nvme.h>

#undef nvme_sq_update_tail
#undef nvme_try_dbbuf
#undef nvme_cq_get_cqe
#undef nvme_rq_acquire_atomic
#undef nvme_rq_release_atomic
#undef bcr_serialize

void nvme_sq_update_tail(struct nvme_sq *sq)
{
	vfn_impl_nvme_sq_update_tail(sq);
}

int nvme_try_dbbuf(uint16_t v, struct nvme_dbbuf *dbbuf)
{
	return vfn_impl_nvme_try_dbbuf(v, dbbuf);
}

struct nvme_cqe *nvme_cq_get_cqe(struct nvme_cq *cq)
{
	return vfn_impl_nvme_cq_get_cqe(cq);
}

struct nvme_rq *nvme_rq_acquire_atomic(struct nvme_sq *sq)
{
	return vfn_impl_nvme_rq_acquire_atomic(sq);
}

void nvme_rq_release_atomic(struct nvme_rq *rq)
{
	vfn_impl_nvme_rq_release_atomic(rq);
}

#ifdef __s390x__
/*
 * barrier.h's bcr_serialize() is inline asm; translate-c demotes it to an
 * extern declaration, so the translated request/CQ inline helpers need a real
 * global to link against.
 */
void bcr_serialize(void)
{
	asm volatile("bcr 15,0" ::: "memory");
}
#endif

/* libvfn's log_debug() is compiled in but runtime-gated by logv(); turn it on
 * so a failed nvme_init() explains itself on stderr. */
void vfn_shim_log_set_debug(void)
{
	logv_set(LOG_DEBUG);
}

int vfn_shim_errno(void)
{
	return errno;
}

/*
 * Register (fd >= 0) or clear (fd < 0, normally the caller just disables) one
 * eventfd for one MSI-X vector. Wraps vfio_set_irq()/vfio_disable_irq() so the
 * Zig test layer need not name the controller's nested struct vfio_device.
 *
 * Return: 0 on success, -1 and sets errno on error.
 */
int vfn_shim_set_irq(struct nvme_ctrl *ctrl, int vector, int fd)
{
	return vfio_set_irq(&ctrl->pci.dev, &fd, vector, 1);
}

int vfn_shim_disable_irq(struct nvme_ctrl *ctrl, int vector)
{
	return vfio_disable_irq(&ctrl->pci.dev, vector, 1);
}

/* Validation for the s390x pread/pwrite BAR backend: read the raw NVMe CAP
 * register out of BAR0 through the VFIO fd, bypassing mmap. */
long vfn_shim_pread(struct nvme_ctrl *ctrl, void *buf, size_t len, unsigned long off)
{
	return pread(ctrl->pci.dev.fd, buf, len,
		     ctrl->pci.bar_region_info[0].offset + off);
}

/* The same register read through libvfn's mapped BAR (NULL/0 when the region
 * was not mappable, i.e. on s390x). */
uint64_t vfn_shim_mmio_cap(struct nvme_ctrl *ctrl)
{
	if (!ctrl->regs)
		return 0;
	return le64_to_cpu(mmio_read64(ctrl->regs));
}

/* Endianness probes for libvfn's mmio helpers: decode a known NVMe register
 * image through the same code path a real BAR access would use. */
uint32_t vfn_shim_read32(void *addr)
{
	return le32_to_cpu(mmio_read32(addr));
}

uint64_t vfn_shim_read64_raw(void *addr)
{
	return (uint64_t __force)mmio_read64(addr);
}

uint64_t vfn_shim_read64(void *addr)
{
	return le64_to_cpu(mmio_read64(addr));
}

void vfn_shim_write64_lh(void *addr, uint64_t native)
{
	mmio_lh_write64(addr, cpu_to_le64(native));
}

void vfn_shim_write64_hl(void *addr, uint64_t native)
{
	mmio_hl_write64(addr, cpu_to_le64(native));
}

/* ------------------------------------------------------------------ dbbuf
 *
 * Diagnostics for the e2e shadow-doorbell (DBBUF) test. The Shadow Doorbell
 * and EventIdx entries are device-visible host memory and, like everything
 * else the controller reads, little endian (NVMe base spec 1.4.3); so
 * nvme_try_dbbuf() must encode on the store and decode on the load.
 */

static void vfn_shim_put_le32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v);
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static uint32_t vfn_shim_read_shadow(void *ptr)
{
	if (!ptr)
		return 0;

	return le32_to_cpu(__LOAD_PTR(leint32_t *, ptr));
}

/*
 * vfn_shim_dbbuf_selftest - check nvme_try_dbbuf()'s byte order, no device
 *
 * Drives nvme_try_dbbuf() against a local shadow buffer so the encoding is
 * checked on whichever host this runs on. Both checks failed on big-endian
 * hosts before the endianness fix.
 *
 * Return: 0 on success, negative at the first failed check.
 */
int vfn_shim_dbbuf_selftest(void)
{
	uint8_t db[4] = { 0 }, ei[4] = { 0 };
	struct nvme_dbbuf buf = { .doorbell = db, .eventidx = ei };

	/* (a) the stored doorbell value must land little-endian in memory.
	 *
	 * The doorbell value is a 16-bit queue index, so use one that fits:
	 * 0x1234 must appear as bytes 34 12 00 00 in the shadow buffer. */
	nvme_try_dbbuf(0x1234, &buf);
	if (db[0] != 0x34 || db[1] != 0x12 || db[2] != 0x00 || db[3] != 0x00)
		return -1;

	/*
	 * (b) the event index must be decoded little-endian when deciding
	 * whether to ring the real doorbell. With old=5 and eventidx=3, the new
	 * value 7 leaves the event index behind: X=(7-3)=4 > Y=(7-5)=2, so the
	 * shadow update alone suffices and no mmio is needed (return 0). A
	 * byte-swapped decode reads both as 0 and wrongly forces mmio (-1).
	 */
	vfn_shim_put_le32(db, 5);
	vfn_shim_put_le32(ei, 3);
	if (nvme_try_dbbuf(7, &buf) != 0)
		return -2;

	return 0;
}

/* was the shadow-doorbell (DBBUF) feature negotiated during nvme_init()? */
int vfn_shim_dbbuf_active(struct nvme_ctrl *ctrl)
{
	return ctrl->dbbuf.doorbells.vaddr != NULL;
}

/* admin SQ/CQ shadow-buffer values and libvfn's view of the queue counters */
uint32_t vfn_shim_dbbuf_sq_doorbell(struct nvme_ctrl *ctrl)
{
	return vfn_shim_read_shadow(ctrl->adminq.sq->dbbuf.doorbell);
}

uint32_t vfn_shim_dbbuf_sq_eventidx(struct nvme_ctrl *ctrl)
{
	return vfn_shim_read_shadow(ctrl->adminq.sq->dbbuf.eventidx);
}

uint32_t vfn_shim_dbbuf_cq_doorbell(struct nvme_ctrl *ctrl)
{
	return vfn_shim_read_shadow(ctrl->adminq.cq->dbbuf.doorbell);
}

uint32_t vfn_shim_dbbuf_cq_eventidx(struct nvme_ctrl *ctrl)
{
	return vfn_shim_read_shadow(ctrl->adminq.cq->dbbuf.eventidx);
}

uint16_t vfn_shim_adminq_sq_tail(struct nvme_ctrl *ctrl)
{
	return ctrl->adminq.sq->tail;
}

uint16_t vfn_shim_adminq_cq_head(struct nvme_ctrl *ctrl)
{
	return ctrl->adminq.cq->head;
}
