/* SPDX-License-Identifier: LGPL-2.1-or-later OR MIT */
/*
 * Translation unit fed to Zig's translate-c to produce the libvfn bindings.
 */
#include <vfn/nvme.h>
#include <vfn/vfio.h>
#include <vfn/iommu.h>

/*
 * Thin wrappers around libvfn's VFIO IRQ registration (src/vfio/device.c).
 * They let the Zig test layer bind an eventfd to one MSI-X vector by number,
 * without having to name the controller's nested `struct vfio_device`. See
 * src/vfn_shim.c for the definitions.
 */
int vfn_shim_set_irq(struct nvme_ctrl *ctrl, int vector, int fd);
int vfn_shim_disable_irq(struct nvme_ctrl *ctrl, int vector);
