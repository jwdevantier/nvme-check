#!/usr/bin/env makac
-- workflows/uuid-mount.lua
-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier
-- SPDX-License-Identifier: BSD-2-Clause
--
-- STRAIGHT workflow (a single makac program, not a test-suite declaration):
-- boot a guest with one NVMe controller + one namespace, twice (a fresh QEMU
-- process each time), and print the namespace UUID descriptor (Identify,
-- NIDT 3h) each boot. If the two differ, QEMU's auto-generated namespace
-- UUID is not stable across a power cycle and there is work to do.
--
--   nix develop -c makac run workflows/uuid-mount.lua [amd64|s390x]
--
-- Why this is the whole check: hw/nvme now generates `ns->uuid` in
-- nvme_ns_init() when `uuid=` is not supplied. A new QEMU process generates a
-- new value; the descriptor is what the guest sees via Identify. (Linux also
-- has NVME_QUIRK_BOGUS_NID set for QEMU's 1b36:0010 controller, so its block
-- wwid ignores the descriptor -- the raw command below bypasses the driver.)

local archlib = require("pkgs/nvmecheck/arch")
local nvmelib = require("pkgs/nvmecheck/nvme")

local ARCH = arg[1] or "amd64"
local a = archlib.get(ARCH)

local PORT = 2331 -- distinct from archlib's 2301/2302 and the e2e 2090
local VM = "uuid-mount-" .. ARCH
local SSH_OPTS = { StrictHostKeyChecking = "no", UserKnownHostsFile = "/dev/null" }
local NS_SIZE = "128M"

-- --- host helpers ----------------------------------------------------------

--- Run a host command, raising on failure.
---@param argv string[]
---@return string
local function host(argv)
	local r = makac.exec(argv)
	assert(r.code == 0, ("host command failed: %s\n%s")
		:format(table.concat(argv, " "), r.stderr or ""))
	return r.stdout or ""
end

--- Run `cmd` in the guest under sh -c; return the step's `out` (never raises
--- on a non-zero exit -- non-zero is data here).
---@param target Target
---@param label string
---@param cmd string
---@return table
local function gsh(target, label, cmd)
	return step {
		name = label,
		uses = "shell",
		target = target,
		with = { cmd = { "sh", "-c", cmd }, ignore_exit_code = true },
	}.out
end

--- gsh() then trimmed stdout.
---@param target Target
---@param label string
---@param cmd string
---@return string
local function gout(target, label, cmd)
	return ((gsh(target, label, cmd).stdout or ""):gsub("%s+$", ""))
end

--- Poll until a block device node exists. -> true | false
---@param target Target
---@param dev string
---@param timeout_s integer
---@return boolean
local function wait_dev(target, dev, timeout_s)
	local deadline = os.time() + timeout_s
	while os.time() < deadline do
		if gsh(target, "wait " .. dev, "test -b " .. dev).code == 0 then return true end
		makac.time.sleep(2 * makac.time.ns_per_s)
	end
	return false
end

--- The namespace UUID descriptor (NIDT 3h) as returned by Identify; "" if the
--- guest's nvme-cli is missing or the controller returns no UUID descriptor.
---@param target Target
---@param label string
---@return string
local function ns_uuid(target, label)
	return gout(target, label,
		"nvme ns-descs /dev/nvme0n1 2>/dev/null | " ..
		"awk -F: '/^uuid/{gsub(/ /,\"\",$2); print $2; exit}'")
end

-- --- a stale VM would hold the overlay we are about to recreate ------------

local probe = step { name = "probe " .. VM, uses = "qemu:probe", with = { vm = VM } }
if probe.out.alive then
	step {
		name = "stop stale " .. VM,
		uses = "qemu:vm",
		with = { vm = VM, state = "stopped", guest_shutdown = false },
	}
end

-- --- images: cloud-init OS (cached) + small raw namespace disk -------------

local base = step {
	name = "image " .. a.image_name,
	uses = "qemu:img",
	with = archlib.image(a),
}

local raw = step {
	name = "image ns-" .. NS_SIZE,
	uses = "qemu:img",
	with = archlib.raw_spec(a, "uuidmount", NS_SIZE),
}

local root = tostring(makac.fs.cwd())
local vm_dir = ".makac/vm-images"
makac.fs.mkdir_p(vm_dir)
local os_disk = root .. "/" .. vm_dir .. "/" .. VM .. "-os.qcow2"
local ns_disk = root .. "/" .. vm_dir .. "/" .. VM .. "-ns.img"

host({ "cp", "-f", tostring(raw.out.path), ns_disk })

-- fresh OS overlay per run (the guest is pristine); qemu:vm's own with.disk
-- is avoided so the overlay is not recreated between the two boots.
os.remove(os_disk)
host({ "qemu-img", "create", "-f", "qcow2",
	"-b", tostring(base.out.path), "-F", "qcow2", os_disk })

-- --- machine: one controller, one namespace, cold-plugged ------------------

local args = archlib.base_args(a, PORT)
for i, w in ipairs(args) do
	args[i] = (w:gsub("{{ disk }}", os_disk))
end

local ns_spec = {
	id = "nvme0",
	serial = "uuidmount",
	drive = ns_disk,
	drive_format = "raw",
	ns = {},  -- an explicit nvme-ns (not the controller's implicit nsid 1)
	nsid = 1,
}
for _, w in ipairs(nvmelib.cold_args(ns_spec, archlib.nvme_attach(a, 0))) do
	args[#args + 1] = w
end

---@return table
local function start_with()
	return {
		vm = VM,
		state = "started",
		qemu_bin = a.qemu_bin,
		args = args,
		ssh = { port = PORT, options = SSH_OPTS },
		wait_ssh = { timeout_s = 900, interval_s = 3 },
	}
end

--- Boot (or power-cycle into) the VM, wait for the namespace, read the UUID.
---@param label string
---@return table
local function boot_and_read(label)
	local r = step { name = label, uses = "qemu:vm", with = start_with() }
	local t = r.out.target
	assert(wait_dev(t, "/dev/nvme0n1", 180), "namespace /dev/nvme0n1 never appeared")

	local uuid = ns_uuid(t, label .. ": ns uuid")
	local wwid = gout(t, label .. ": ns wwid", "cat /sys/block/nvme0n1/wwid")
	local kernel = gout(t, label .. ": kernel", "uname -r")
	print(("[uuid-mount] %s: namespace UUID = %s"):format(label, uuid ~= "" and uuid or "<none>"))
	print(("[uuid-mount] %s: block wwid    = %s"):format(label, wwid))
	return { uuid = uuid, wwid = wwid, kernel = kernel }
end

-- --- boot #1 ---------------------------------------------------------------

local b1 = boot_and_read("boot #1 " .. VM)

-- --- power cycle: a fresh QEMU process => a fresh auto-generated UUID ------

step {
	name = "power-cycle (stop) " .. VM,
	uses = "qemu:vm",
	with = { vm = VM, state = "stopped", guest_shutdown = false },
}

-- --- boot #2 ---------------------------------------------------------------

local b2 = boot_and_read("boot #2 " .. VM)

step {
	name = "stop " .. VM,
	uses = "qemu:vm",
	with = { vm = VM, state = "stopped", guest_shutdown = false },
}

-- --- report ----------------------------------------------------------------

if b1.uuid == "" or b2.uuid == "" then
	print("\n[uuid-mount] could not read the namespace UUID descriptor on both boots " ..
		"(is nvme-cli present in the guest?)")
end

if b1.uuid ~= b2.uuid then
	print(([[

================================================================
 namespace UUID CHANGED between boots:
   boot 1: %s
   boot 2: %s
 => QEMU's auto-generated namespace UUID is not stable across a
    power cycle. Work to do.
================================================================
]]):format(b1.uuid, b2.uuid))
else
	print(([[

================================================================
 namespace UUID is stable across boots: %s
   (block wwid was %s on both boots)
================================================================
]]):format(b1.uuid, b1.wwid))
end
