-- tests/nvme14m/workflow.lua
--
-- NVMe 1.4 mandatory-baseline suite. One controller, one 64M namespace, split
-- into per-concern batch programs so that destructive work (feature writes,
-- I/O-queue lifecycle, reset, shutdown) cannot contaminate read-only
-- inspection. Each entry below gets its own fresh `nvme_init()` session
-- (reset → admin queue → enable → Identify) — that session is the isolation
-- mechanism. See README.md and ~/nvme-1.4.poc.overview.md.
--
-- The entry `name` is the program's `:` filter key
-- (e.g. `./nvme-check.lua nvme14m:inspect -a amd64`).

return {
	uses = "nvmecheck:libvfn-simple",
	tests = {
		-- Read-only: transport registers, BAR/MSI-X, interrupts, Identify,
		-- log pages. Shares one session; mutates nothing.
		{ name = "inspect", tags = { "nvme14", "fast" },
			with = {
				program = "batches/inspect.zig",
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

		-- Get/Set Features: mutates feature values, so it gets its own
		-- session and stays queue-less.
		{ name = "features", tags = { "nvme14", "fast" },
			with = {
				program = "batches/features.zig",
				nvme = {
					drive = "64M",
					ctrl = {
						logical_block_size = 512,
						physical_block_size = 512,
					},
				},
			} },

		-- Admin error completions, AER, Abort: drives the admin queue
		-- directly, so it must not share with common.admin() users.
		{ name = "admin_errors", tags = { "nvme14" },
			with = {
				program = "batches/admin_errors.zig",
				nvme = {
					drive = "64M",
					ctrl = {
						logical_block_size = 512,
						physical_block_size = 512,
					},
				},
			} },

		-- I/O queue lifecycle and NVM datapath: all queue creation lives
		-- here so the features program always sees a queue-less controller.
		{ name = "io", tags = { "nvme14", "io" },
			with = {
				program = "batches/io.zig",
				nvme = {
					drive = "64M",
					ctrl = {
						logical_block_size = 512,
						physical_block_size = 512,
					},
				},
			} },

		-- CC.EN reset/enable state machine: destroys libvfn's cached
		-- queues, so it is terminal to its own session.
		{ name = "reset", tags = { "nvme14", "destructive" },
			with = {
				program = "batches/reset.zig",
				nvme = {
					drive = "64M",
					ctrl = {
						logical_block_size = 512,
						physical_block_size = 512,
					},
				},
			} },

		-- CC.SHN / CSTS.SHST shutdown: terminal, own session.
		{ name = "shutdown", tags = { "nvme14", "destructive" },
			with = {
				program = "batches/shutdown.zig",
				nvme = {
					drive = "64M",
					ctrl = {
						logical_block_size = 512,
						physical_block_size = 512,
					},
				},
			} },
	},
}
