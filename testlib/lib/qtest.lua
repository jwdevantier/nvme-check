-- testlib/lib/qtest.lua
-- The `nvmecheck:qtest` action: host-side qtest-protocol driver.
--
-- No VM machinery is involved (no image, no snapshot, no ssh): the test
-- program is a HOST-native Zig binary that spawns a headless QEMU
-- (-accel qtest) itself and talks the qtest protocol to it over a unix
-- socket; its exit code is the verdict. The driver supplies the QEMU binary
-- for the case via the NVME_QTEST_QEMU env var — for this lane
-- `with.params.arch` names the *emulated target* (suites declare
-- params = { { arch = "amd64" } } and get qemu.amd64.bin).
--
-- The client side of this contract is `qtest.launch` (src/qtest/qtest.zig):
-- it requires both env vars, resolves NVME_QTEST_MACHINE to a machines.Row,
-- and builds the base machine argv. An unset variable is an error.
--
-- with = {
--   program = "programs/x.zig",   -- relative to tests/<suite>/
--   params/suite/name/case = <injected by the runner>,
-- }
--
-- `params` is the concrete case's parameter table (params.arch, ...): the
-- runner does not interpret it, so the driver is where `arch` is read and a
-- case that does not declare it is an error.

local zigtest = require("./zigtest")
local config = require("./config")

local M = {}

---@param with table
---@return table
function M.run(with)
	assert(type(with) == "table", "nvmecheck:qtest: 'with' table is required")
	local program = assert(with.program, "nvmecheck:qtest: 'with.program' is required")
	local params = assert(with.params, "nvmecheck:qtest: 'with.params' (runner-injected) is required")
	local arch = assert(params.arch, "nvmecheck:qtest: 'params.arch' is required")

	local qemu = config.qemu_bin(arch)
	if qemu == nil then
		return { err = ("qemu.%s.bin is not set; set it in config.user.lua"):format(arch) }
	end

	local built = zigtest.build({
		arch = arch, -- selection row only; binary target is the host
		host = true,
		program = ("tests/%s/%s"):format(with.suite, program),
		name = with.name,
	})
	if built.err then return { err = built.err } end

	-- the qtest lane's machine per arch row (guest lane's q35/kvm choice is
	-- separate); NVME_QTEST_MACHINE is read by the test's common.zig
	local QT_MACHINE = { amd64 = "pc" }
	local machine = QT_MACHINE[arch]
		or "pc"
	local res = makac.exec({ "env", "NVME_QTEST_QEMU=" .. qemu, "NVME_QTEST_MACHINE=" .. machine, built.out.path })
	if res.stdout and #res.stdout > 0 then io.write(res.stdout) end
	if res.code ~= 0 then
		return { err = ("qtest program failed (exit %d)\nstderr:\n%s"):format(res.code, res.stderr or "") }
	end
	return { changed = true, out = { code = res.code } }
end

return M
