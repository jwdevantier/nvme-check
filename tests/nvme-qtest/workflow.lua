-- tests/nvme-qtest/workflow.lua
--
-- Port of QEMU's tests/qtest/nvme-test.c to the nvme-check harness: each
-- upstream qgraph test function is one Zig test here, driven host-side via
-- the qtest protocol (driver: nvmecheck:qtest). See README.md.
--
-- params = { { arch = "amd64" } }: the qtest lane runs on the host, and
-- `arch` names the emulated target (amd64 -> qemu-system-x86_64 -machine pc).
-- No s390x case: zPCI config access needs executing-guest instructions, out of
-- qtest scope.

return {
	uses = "nvmecheck:qtest",
	tests = {
		{ name = "reg-read", tags = { "qtest", "fast" },
			params = { { arch = "amd64" } },
			with = { program = "batches/reg_read.zig" } },
		{ name = "oob-cmb-access", tags = { "qtest", "fast" },
			params = { { arch = "amd64" } },
			with = { program = "batches/oob_cmb_access.zig" } },
		{ name = "pmr-test-access", tags = { "qtest", "fast" },
			params = { { arch = "amd64" } },
			with = { program = "batches/pmr_reg.zig" } },
		{ name = "bringup-datapath", tags = { "qtest" },
			params = { { arch = "amd64" } },
			with = { program = "batches/bringup_datapath.zig" } },
	},
}
