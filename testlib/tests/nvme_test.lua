#!/usr/bin/env makac
-- testlib/tests/nvme_test.lua
--
-- Unit tests for device wiring (testlib/lib/nvme.lua): spec -> plan ->
-- QMP commands / cold argv.
-- Pure table-builders only — no VM, no QEMU, no config.
--
--   makac run testlib/tests/nvme_test.lua

local nvme = require("pkgs/nvmecheck/nvme")

local total, failed = 0, 0

local function report(ok, label, detail)
	total = total + 1
	if not ok then
		failed = failed + 1
		print(("FAIL %s%s"):format(label, detail and ("\n     " .. detail) or ""))
	end
end

-- --- helpers ------------------------------------------------------------------

---@param plan NvmePlanEntry[]
---@param kind string
---@return NvmePlanEntry?
local function entry(plan, kind)
	for _, d in ipairs(plan) do
		if d.kind == kind then return d end
	end
	return nil
end

---@param plan NvmePlanEntry[]
---@return string
local function kinds(plan)
	local out = {}
	for _, d in ipairs(plan) do out[#out + 1] = d.kind end
	return table.concat(out, ",")
end

---@param kind string
---@param id string
---@param driver string?
---@param extra? table<string, any>
---@return string
local function want_entry(kind, id, driver, extra)
	local parts = { kind, id, driver or "-" }
	for k, v in pairs(extra or {}) do parts[#parts + 1] = k .. "=" .. tostring(v) end
	return table.concat(parts, " ")
end

-- --- plan: QEMU's test device (default) ---------------------------------------

do
	local plan = nvme.plan({ drive = "/tmp/nvme.img" })
	report(kinds(plan) == "blockdev,ctrl",
		"default device is blockdev + ctrl (implicit ns)", kinds(plan))

	local bd = entry(plan, "blockdev")
	report(bd ~= nil and bd.id == "nvme0-bdev", "blockdev node defaults to <id>-bdev")
	report(bd ~= nil and bd.driver == nil, "blockdev entry carries no driver")
	report(bd ~= nil and bd.args.driver == "raw", "drive_format defaults to raw",
		bd and tostring(bd.args.driver))
	report(bd ~= nil and bd.args.file.filename == "/tmp/nvme.img", "drive path lands in file.filename")
	report(bd ~= nil and bd.args.cache ~= nil and bd.args.cache.direct == true,
		"drive_cache defaults to direct")

	local ctrl = entry(plan, "ctrl")
	report(ctrl ~= nil and ctrl.driver == "nvme", "ctrl driver is nvme",
		ctrl and tostring(ctrl.driver))
	report(ctrl ~= nil and ctrl.id == "nvme0", "ctrl id defaults to nvme0",
		ctrl and tostring(ctrl.id))
	report(ctrl ~= nil and ctrl.args.serial == "nvme0", "serial defaults to the id",
		ctrl and tostring(ctrl.args.serial))
	report(ctrl ~= nil and ctrl.args.drive == "nvme0-bdev",
		"implicit namespace rides the ctrl", ctrl and tostring(ctrl.args.drive))
	report(ctrl ~= nil and ctrl.args.subsys == nil, "no subsys unless asked for")
end

-- --- plan: vnvme --------------------------------------------------------------

do
	local plan = nvme.plan({ device = "vnvme", drive = "/tmp/nvme.img" })
	report(kinds(plan) == "blockdev,ctrl", "vnvme is blockdev + ctrl", kinds(plan))

	local ctrl = entry(plan, "ctrl")
	report(ctrl ~= nil and ctrl.driver == "vnvme", "ctrl driver is the spec's device",
		ctrl and tostring(ctrl.driver))
	report(ctrl ~= nil and ctrl.id == "vnvme0", "id defaults to <device>0",
		ctrl and tostring(ctrl.id))
	report(ctrl ~= nil and ctrl.args.drive == "vnvme0-bdev",
		"vnvme's implicit namespace rides the ctrl", ctrl and tostring(ctrl.args.drive))

	report(entry(plan, "blockdev").id == "vnvme0-bdev", "blockdev node follows the vnvme id")

	-- any other device name passes through: custom QEMU builds
	local custom = nvme.plan({ device = "my-nvme", drive = "/tmp/x" })
	report(entry(custom, "ctrl").driver == "my-nvme", "unknown device names pass through")
end

-- --- plan: device properties are opaque --------------------------------------

do
	local ctrl = entry(nvme.plan({
		device = "vnvme",
		drive = "/tmp/nvme.img",
		serial = "SN123",
		ctrl = { logical_block_size = 4096, physical_block_size = 4096, num_queues = 8 },
	}), "ctrl")
	report(ctrl.args.serial == "SN123", "serial overrides the id", tostring(ctrl.args.serial))
	report(ctrl.args.logical_block_size == 4096 and ctrl.args.physical_block_size == 4096,
		"ctrl block sizes pass through")
	report(ctrl.args.num_queues == 8, "device-specific ctrl keys pass through")

	local named = entry(nvme.plan({ device = "vnvme", id = "disk", serial = "S" }), "ctrl")
	report(named.id == "disk" and named.args.serial == "S", "explicit id and serial win",
		named.id .. "/" .. tostring(named.args.serial))
end

-- --- plan: nvme subsystem / namespace ----------------------------------------

do
	local plan = nvme.plan({ drive = "/tmp/nvme.img", subsys = true, ns = { nsid = 2 } })
	report(kinds(plan) == "blockdev,subsys,ctrl,ns", "explicit ns adds subsys and ns", kinds(plan))

	local subsys = entry(plan, "subsys")
	report(subsys.driver == "nvme-subsys" and subsys.id == "nvme0-subsys",
		"subsys entry is nvme-subsys/nvme0-subsys")

	local ctrl = entry(plan, "ctrl")
	report(ctrl.args.subsys == "nvme0-subsys", "ctrl joins the subsystem")
	report(ctrl.args.drive == nil, "explicit ns takes the drive off the ctrl")

	local ns = entry(plan, "ns")
	report(ns.driver == "nvme-ns" and ns.id == "nvme0-ns", "ns entry is nvme-ns/nvme0-ns")
	report(ns.args.bus == "nvme0-subsys", "ns sits on the subsystem bus")
	report(ns.args.nsid == 2, "ns nsid override wins", tostring(ns.args.nsid))
	report(ns.args.drive == "nvme0-bdev", "ns takes the drive")
end

-- --- plan: only "nvme" has subsystem/namespace objects -----------------------

do
	local cases = {
		{ "subsys", { device = "vnvme", subsys = true } },
		{ "subsys_id", { device = "vnvme", subsys_id = "s" } },
		{ "ns", { device = "vnvme", ns = {} } },
		{ "ns_id", { device = "vnvme", ns_id = "n" } },
		{ "nsid", { device = "vnvme", nsid = 1 } },
	}
	for _, c in ipairs(cases) do
		local ok, err = pcall(nvme.plan, c[2])
		report(not ok and tostring(err):find("single implicit namespace", 1, true) ~= nil,
			"vnvme rejects '" .. c[1] .. "'", tostring(err))
	end
end

-- --- commands: QMP ------------------------------------------------------------

do
	local cmds = nvme.commands({ drive = "/tmp/nvme.img" }, { bus = "rp0", addr = "0.0" })
	report(#cmds == 2, "one blockdev-add and one device_add", tostring(#cmds))
	report(cmds[1].execute == "blockdev-add", "drive goes first", cmds[1].execute)
	report(cmds[2].execute == "device_add" and cmds[2].arguments.driver == "nvme",
		"the ctrl is device_add nvme")

	local a = cmds[2].arguments
	report(a.bus == "rp0" and a.addr == "0.0", "attach lands on the ctrl",
		tostring(a.bus) .. "/" .. tostring(a.addr))
	report(a.drive == "nvme0-bdev", "implicit namespace survives rendering")

	local v = nvme.commands({ device = "vnvme", drive = "/tmp/nvme.img" }, { bus = "rp1", addr = "0.0" })
	report(v[2].arguments.driver == "vnvme", "vnvme is device_add vnvme",
		v[2].arguments.driver)
	report(v[2].arguments.bus == "rp1", "attach works for vnvme too")
end

do
	local cmds = nvme.commands({ drive = "/tmp/nvme.img", subsys = true, ns = {} },
		{ bus = "rp0", addr = "0.0" })
	report(#cmds == 4, "subsys/ns render three device_adds plus the blockdev", tostring(#cmds))
	report(cmds[3].arguments.bus == "rp0", "attach lands on the ctrl only")
	report(cmds[4].arguments.bus == "nvme0-subsys", "ns keeps its own bus",
		tostring(cmds[4].arguments.bus))
	report(cmds[4].arguments.addr == nil, "ns gets no attach address")
end

-- --- cold argv ----------------------------------------------------------------

do
	local argv = nvme.cold_args({ device = "vnvme", drive = "/tmp/nvme.img" },
		{ bus = "rp0", addr = "0.0" })
	report(#argv == 4, "two flags, two values", tostring(#argv))
	report(argv[1] == "-blockdev" and argv[3] == "-device", "blockdev then device")
	report(argv[2] == "cache.direct,driver=raw,file.driver=file,"
		.. "file.filename=/tmp/nvme.img,node-name=vnvme0-bdev",
		"blockdev args serialize with sorted dotted keys", argv[2])
	report(argv[4] == "addr=0.0,bus=rp0,drive=vnvme0-bdev,driver=vnvme,"
		.. "id=vnvme0,serial=vnvme0",
		"device args serialize the same way", argv[4])
end

-- --- teardown -----------------------------------------------------------------

do
	local cmds = nvme.remove_commands({ "nvme0", "nvme0-subsys" })
	report(#cmds == 2 and cmds[1].execute == "device_del", "remove_commands deletes ids")
	report(cmds[2].arguments.id == "nvme0-subsys", "remove_commands keeps the order")
end

-- --- summary ------------------------------------------------------------------

print(("\n%d passed, %d failed"):format(total - failed, failed))
if failed > 0 then error("nvme tests failed", 0) end
