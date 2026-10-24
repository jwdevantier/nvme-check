-- tests/nvme14m/workflow.lua
--
-- NVMe 1.4 mandatory-baseline suite. One controller, one 64M namespace, split
-- into per-concern test programs so that destructive work (feature writes,
-- I/O-queue lifecycle, reset, shutdown) cannot contaminate read-only
-- inspection. Each entry below gets its own fresh `nvme_init()` session
-- (reset → admin queue → enable → Identify) — that session is the isolation
-- mechanism. See README.md and ~/nvme-1.4.poc.overview.md.
--
-- The entry `name` is the program's `:` filter key
-- (e.g. `./nvme-check.lua nvme14m:inspect -w 'arch=amd64'`).

-- The same device on both QEMU NVMe implementations: its test device
-- (`nvme`, every extension) and its hardened production controller (`vnvme`,
-- mandatory subset only). 512-byte LBAs on both, so the PRP round-trip maps
-- whole blocks without an LBA-size dance; vnvme takes its block sizes from the
-- same block properties, and owns a single implicit namespace fed by `drive`.
local function device()
	return {
		drive = "64M",
		ctrl = {
			logical_block_size = 512,
			physical_block_size = 512,
		},
	}
end

-- amd64 runs every test against both devices (`dev` is an ordinary
-- parameter, so `-w 'dev=vnvme'` selects the production-controller cases).
-- s390x keeps the test device alone until vnvme is tried on zPCI.
local function params()
	return {
		{ arch = "amd64", dev = "nvme" },
		{ arch = "amd64", dev = "vnvme" },
		{ arch = "s390x" },
	}
end

return {
	uses = "nvmecheck:qemu-vfio",
	tests = {
		-- Read-only: transport registers, BAR/MSI-X, interrupts, Identify,
		-- log pages. Shares one session; mutates nothing.
		{ name = "inspect", tags = { "nvme14", "fast" },
			params = params(),
			with = {
				program = "programs/inspect.zig",
				nvme = device(),
				vnvme = device(),
			} },

		-- Get/Set Features: mutates feature values, so it gets its own
		-- session and stays queue-less.
		{ name = "features", tags = { "nvme14", "fast" },
			params = params(),
			with = {
				program = "programs/features.zig",
				nvme = device(),
				vnvme = device(),
			} },

		-- Admin error completions, AER, Abort: drives the admin queue
		-- directly, so it must not share with common.admin() users.
		{ name = "admin_errors", tags = { "nvme14" },
			params = params(),
			with = {
				program = "programs/admin_errors.zig",
				nvme = device(),
				vnvme = device(),
			} },

		-- I/O queue lifecycle and NVM datapath: all queue creation lives
		-- here so the features program always sees a queue-less controller.
		{ name = "io", tags = { "nvme14", "io" },
			params = params(),
			with = {
				program = "programs/io.zig",
				nvme = device(),
				vnvme = device(),
			} },

		-- CC.EN reset/enable state machine: destroys libvfn's cached
		-- queues, so it is terminal to its own session.
		{ name = "reset", tags = { "nvme14", "destructive" },
			params = params(),
			with = {
				program = "programs/reset.zig",
				nvme = device(),
				vnvme = device(),
			} },

		-- CC.SHN / CSTS.SHST shutdown: terminal, own session.
		{ name = "shutdown", tags = { "nvme14", "destructive" },
			params = params(),
			with = {
				program = "programs/shutdown.zig",
				nvme = device(),
				vnvme = device(),
			} },
	},
}
