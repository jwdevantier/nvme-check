#include <stdbool.h>

#include "vfn/trace/events.h"
#include "trace.h"

bool TRACE_NVME_CQ_GET_CQE_ACTIVE;
bool TRACE_NVME_CQ_GOT_CQE_ACTIVE;
bool TRACE_NVME_CQ_SPIN_ACTIVE;
bool TRACE_NVME_CQ_UPDATE_HEAD_ACTIVE;
bool TRACE_NVME_SQ_POST_ACTIVE;
bool TRACE_NVME_SQ_UPDATE_TAIL_ACTIVE;
bool TRACE_NVME_SKIP_MMIO_ACTIVE;
bool TRACE_IOMMUFD_IOAS_MAP_DMA_ACTIVE;
bool TRACE_IOMMUFD_IOAS_UNMAP_DMA_ACTIVE;
bool TRACE_VFIO_IOMMU_TYPE1_MAP_DMA_ACTIVE;
bool TRACE_VFIO_IOMMU_TYPE1_UNMAP_DMA_ACTIVE;
bool TRACE_VFIO_IOMMU_TYPE1_RECYCLE_EPHEMERAL_IOVAS_ACTIVE;

struct trace_event trace_events[] = {
	{"nvme_cq_get_cqe", &TRACE_NVME_CQ_GET_CQE_ACTIVE},
	{"nvme_cq_got_cqe", &TRACE_NVME_CQ_GOT_CQE_ACTIVE},
	{"nvme_cq_spin", &TRACE_NVME_CQ_SPIN_ACTIVE},
	{"nvme_cq_update_head", &TRACE_NVME_CQ_UPDATE_HEAD_ACTIVE},
	{"nvme_sq_post", &TRACE_NVME_SQ_POST_ACTIVE},
	{"nvme_sq_update_tail", &TRACE_NVME_SQ_UPDATE_TAIL_ACTIVE},
	{"nvme_skip_mmio", &TRACE_NVME_SKIP_MMIO_ACTIVE},
	{"iommufd_ioas_map_dma", &TRACE_IOMMUFD_IOAS_MAP_DMA_ACTIVE},
	{"iommufd_ioas_unmap_dma", &TRACE_IOMMUFD_IOAS_UNMAP_DMA_ACTIVE},
	{"vfio_iommu_type1_map_dma", &TRACE_VFIO_IOMMU_TYPE1_MAP_DMA_ACTIVE},
	{"vfio_iommu_type1_unmap_dma", &TRACE_VFIO_IOMMU_TYPE1_UNMAP_DMA_ACTIVE},
	{"vfio_iommu_type1_recycle_ephemeral_iovas", &TRACE_VFIO_IOMMU_TYPE1_RECYCLE_EPHEMERAL_IOVAS_ACTIVE},
};

int TRACE_NUM_EVENTS = 12;
