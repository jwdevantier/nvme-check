-- tests/tp4176/workflow.lua
--
-- TP4176 (Rate Limiting) black-box suite. Every controller is created with
-- QEMU's `rate-limit=on` (the TP4176 emulation), bound to vfio-pci, and the
-- test's Zig binary is run against it. See README.md.
--
-- A workflow is a DECLARATION: it returns { uses, tests = {...} } where a
-- test is a step-spec (`uses` = the driver action, `with` = its payload) plus
-- the harness-known selection keys (name/tags/archs). The runner loads every
-- suite, selects (arch, test) pairs in one pass, and executes each pair as a
-- makac step.  ./nvme-check.lua  is the entry point (--where, --list).
--
-- `uses` names the driver: set it on the suite (applies to every test) and/or
-- per test (overrides the suite's). There is no harness-level default. The
-- harness
-- resolves `drive` to a per-run raw disk at device-add time, so a fresh table
-- per test.

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

return {
	uses = "nvmecheck:libvfn-simple",
	tests = {
		{ name = "identify", tags = { "tp4176", "fast" },
			with = { program = "batches/identify.zig", nvme = nvme() } },
		{ name = "log_page", tags = { "tp4176" },
			with = { program = "batches/log_page.zig", nvme = nvme() } },
		{ name = "feature", tags = { "tp4176" },
			with = { program = "batches/feature.zig", nvme = nvme() } },
		{ name = "aer", tags = { "tp4176", "slow" },
			with = { program = "batches/aer.zig", nvme = nvme() } },
	},
}
