-- tests/tp4176/workflow.lua
--
-- TP4176 (Rate Limiting) black-box suite. Every controller is created with
-- QEMU's `rate-limit=on` (the TP4176 emulation), bound to vfio-pci, and the
-- batch's Zig test binary is run against it. See README.md.
--
--   makac run tests/tp4176/workflow.lua   (runs the whole TP)
--   ./nvme-check.lua                           (the runner: --where, --list)

local batch = require("pkgs/nvmecheck/batch")

-- One controller, TP4176 emulation on. A fresh table per batch (the harness
-- resolves `drive` to a per-run raw disk at device-add time).
local function nvme()
	return {
		drive = "64M",
		ctrl = {
			["rate-limit"] = true,
			logical_block_size = 4096,
			physical_block_size = 4096,
		},
	}
end

local batches = {
	{ name = "identify", program = "batches/identify.zig", nvme = nvme(), tags = { "tp4176", "fast" } },
	{ name = "log_page", program = "batches/log_page.zig", nvme = nvme(), tags = { "tp4176" } },
	{ name = "feature", program = "batches/feature.zig", nvme = nvme(), tags = { "tp4176" } },
	{ name = "aer", program = "batches/aer.zig", nvme = nvme(), tags = { "tp4176", "slow" } },
}

batch.run_all("tp4176", batches)
