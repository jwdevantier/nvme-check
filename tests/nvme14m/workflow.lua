-- tests/nvme14/workflow.lua
--
-- NVMe 1.4 mandatory-baseline suite. One controller, one 64M namespace, one
-- batch program whose `test {}` blocks walk the mandatory transport, admin,
-- feature, log and I/O behavior. See README.md and
-- ~/nvme-1.4.poc.overview.md.

return {
	uses = "nvmecheck:libvfn-simple",
	tests = {
		{ name = "mandatory", tags = { "nvme14", "fast" },
			with = {
				program = "batches/mandatory.zig",
				nvme = {
					drive = "64M",
					ctrl = {
						-- Keep one LBA = 512 B so the PRP round-trip
						-- maps whole blocks without an LBA-size dance.
						logical_block_size = 512,
						physical_block_size = 512,
					},
				},
			} },
	},
}
