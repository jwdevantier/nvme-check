-- testlib/lib/arch.lua
-- The two architectures the NVMe tests run against, their BASE machine
-- arguments, the NVMe attach point, and the seed/up/down session helpers.
--
-- A test takes the base args and appends the NVMe devices it wants (see
-- lib/nvme.lua); the helpers here only cover the parts every test shares:
-- the boot disk placeholder `{{ disk }}`, a user-mode NIC with an ssh
-- forward, and (for Q35) a few pre-created PCIe root ports to hotplug onto.
--
-- Flow, per test: seed (build image + baseline; a no-op once it exists) ->
-- up (resume the baseline) -> test work -> down (clean QMP quit).

local images = require("./images")
local config = require("./config")

---@alias ArchName "amd64"|"s390x"

---@class Arch
---@field name ArchName
---@field qemu_bin string
---@field qemu_img string
---@field ssh_port integer
---@field vm_name string
---@field hostname string
---@field image_name string
---@field live_disk string
---@field snap_tag string
---@field instance_id_file string
---@field machine string
---@field cpu string
---@field boot_dev string
---@field net_dev string
---@field root_ports integer
---@field iommu? string
---@field base_url string
---@field base_sha256 string
---@field build_args string[]
---@field img_size? string
---@field img_timeout_s? number
---@field img_verbose? boolean

---@class Session
---@field vm any
---@field target Target
---@field pid integer
---@field disk Disk

---@alias Disk { backing: string, path: string }

local M = {}

---@param ... table
---@return table
local function merge(...)
	local t = {}
	for _, src in ipairs({ ... }) do
		for k, v in pairs(src or {}) do t[k] = v end
	end
	return t
end

-- Per-arch constants. Ports are distinct from the e2e live_/s390_ sets
-- (2090 / 2290 / 2291).
--
-- The QEMU binaries have no built-in default: they are the per-machine
-- `qemu.<arch>.bin` / `qemu.img` from the config file (config.user.sample.lua).
-- M.get refuses an arch whose binaries are unset, so a suite cannot run on a
-- machine that was never configured for it; `makac doctor nvmecheck` reports
-- the same. A new arch automatically gains its config knob as qemu.<arch>.bin.
local function qemu_bin(arch_name)
	return config.qemu_bin(arch_name)
end

local function qemu_img()
	return config.qemu_img()
end

local DEF = {
	amd64 = {
		name = "amd64",
		qemu_bin = qemu_bin("amd64"),
		qemu_img = qemu_img(),
		ssh_port = 2301,
		vm_name = "nvme-amd64",
		hostname = "nvme-amd64",
		image_name = "nvme-amd64-base",
		live_disk = ".makac/vm-images/nvme-amd64-live.qcow2",
		snap_tag = "nvme-amd64-base",
		instance_id_file = ".makac/vm-images/nvme-amd64_instance_id",
		machine = "q35,accel=kvm,kernel-irqchip=split",
		cpu = "host",
		boot_dev = "virtio-blk-pci,drive=bdrv.boot,bootindex=0",
		net_dev = "virtio-net-pci,netdev=net0",
		root_ports = 4, -- NVMe hotplug targets (Q35 cannot create them later)
		-- An emulated IOMMU: required for the guest to bind a device to
		-- vfio-pci (no IOMMU group otherwise; `bind` fails with EIO).
		-- kernel-irqchip=split is needed for intremap. s390x needs none.
		iommu = "intel-iommu,intremap=on,caching-mode=on",
		base_url = "https://cloud-images.ubuntu.com/noble/20260926/noble-server-cloudimg-amd64.img",
		base_sha256 = "6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2",
		build_args = {
			"-m", "2048", "-smp", "2", "-cpu", "host", "-enable-kvm",
			"-drive", "file={{ img_self }},if=virtio",
			"-cdrom", "{{ cloud_init_iso }}",
			"-boot", "order=c",
			"-device", "virtio-net-pci,netdev=net0",
			"-netdev", "user,id=net0",
		},
	},
	s390x = {
		name = "s390x",
		qemu_bin = qemu_bin("s390x"),
		qemu_img = qemu_img(),
		ssh_port = 2302,
		vm_name = "nvme-s390x",
		hostname = "nvme-s390x",
		image_name = "nvme-s390x-base",
		live_disk = ".makac/vm-images/nvme-s390x-live.qcow2",
		snap_tag = "nvme-s390x-base",
		instance_id_file = ".makac/vm-images/nvme-s390x_instance_id",
		machine = "s390-ccw-virtio",
		cpu = "max",
		boot_dev = "virtio-blk-ccw,drive=bdrv.boot,bootindex=0",
		net_dev = "virtio-net-ccw,netdev=net0",
		root_ports = 0, -- zPCI: QEMU allocates the function + address
		base_url = "https://cloud-images.ubuntu.com/noble/20260926/noble-server-cloudimg-s390x.img",
		base_sha256 = "4107f676ee7b53057a7014f7203eab3e9f6a948bd31fea7e2894b44efce3e5fb",
		build_args = {
			"-m", "2048", "-smp", "2", "-cpu", "max",
			"-drive", "id=bdrv.boot,file={{ img_self }},format=qcow2,if=none",
			"-device", "virtio-blk-ccw,drive=bdrv.boot,bootindex=0",
			"-drive", "id=bdrv.seed,file={{ cloud_init_iso }},format=raw,if=none,readonly=on",
			"-device", "virtio-blk-ccw,drive=bdrv.seed",
			"-netdev", "user,id=net0",
			"-device", "virtio-net-ccw,netdev=net0",
			"-boot", "order=c",
		},
	},
}

---@type ArchName[]
M.names = { "amd64", "s390x" }

---@param name ArchName
---@return Arch
function M.get(name)
	local a = assert(DEF[name], ("unknown arch %q (have: %s)"):format(tostring(name),
		table.concat(M.names, ", ")))
	if not a.qemu_bin then
		error(("qemu.%s.bin is not set; set it in config.user.lua (see config.user.sample.lua)")
			:format(name), 0)
	end
	if not a.qemu_img then
		error("qemu.img is not set; set it in config.user.lua (see config.user.sample.lua)", 0)
	end
	return a
end

-- Public helpers accept an arch NAME or a descriptor; resolve either.
---@param a Arch|ArchName
---@return Arch
local function resolve(a)
	if type(a) == "string" then return M.get(a) end
	return a
end

-- base_args(a, port?) -> the shared machine argv. Tests append NVMe devices
-- to a COPY of this (never mutate the returned table's identity expectations
-- are per-call, so just append).
---@param a Arch|ArchName
---@param port? integer
---@return string[]
function M.base_args(a, port)
	a = resolve(a)
	port = port or a.ssh_port
	local args = {
		"-machine", a.machine,
		"-cpu", a.cpu,
		"-smp", "2",
		"-m", "2048",
		"-drive", "id=bdrv.boot,file={{ disk }},format=qcow2,if=none",
		"-device", a.boot_dev,
		"-netdev", ("user,id=net0,hostfwd=tcp::%d-:22"):format(port),
		"-device", a.net_dev,
		"-display", "none",
	}
	for i = 0, (a.root_ports or 0) - 1 do
		args[#args + 1] = "-device"
		args[#args + 1] = ("pcie-root-port,id=rp%d,chassis=%d,slot=%d"):format(i, i + 1, i)
	end
	if a.iommu then
		args[#args + 1] = "-device"
		args[#args + 1] = a.iommu
	end
	return args
end

-- nvme_attach(a, index?) -> the QMP args that place the Nth NVMe controller.
-- amd64: a pre-created root port with a pinned BDF. s390x: empty (zPCI).
---@param a Arch|ArchName
---@param index? integer
---@return table<string, string>
function M.nvme_attach(a, index)
	a = resolve(a)
	if (a.root_ports or 0) > 0 then
		return { bus = ("rp%d"):format(index or 0), addr = "0.0" }
	end
	return {}
end

---@param a Arch|ArchName
---@return ImgSpec
function M.image(a)
	a = resolve(a)
	return images.cloud_init(a)
end

-- raw_spec(a, name, size?) -> a manifest-cached empty disk for namespaces.
---@param a Arch|ArchName
---@param name string
---@param size? string
---@return ImgSpec
function M.raw_spec(a, name, size)
	a = resolve(a)
	return images.raw(("nvme-%s-%s"):format(a.name, name), size)
end

-- paths(a) -> absolute paths that must agree between seed and up.
---@param a Arch|ArchName
---@return { live_disk: string, image: string }
function M.paths(a)
	a = resolve(a)
	local root = tostring(makac.fs.cwd())
	return {
		live_disk = root .. "/" .. a.live_disk,
		image = makac.data_dir .. "/qemu/img/" .. a.image_name .. "/image",
	}
end

---@param a Arch
---@param live_disk_abs string
---@return boolean
local function has_baseline(a, live_disk_abs)
	if makac.fs.stat(live_disk_abs) == nil then return false end
	local r = makac.exec({ a.qemu_img, "snapshot", "-l", live_disk_abs })
	return r.code == 0 and (r.stdout or ""):find(a.snap_tag, 1, true) ~= nil
end

-- vm_with(a, disk, extra?) -> the `qemu:vm`/`qemu:loadvm` with-table.
-- `disk` is { backing =, path = }; `extra` is merged last (snapshot, state,
-- ssh_port, args, wait_ssh, ...).
---@param a Arch|ArchName
---@param disk Disk
---@param extra? table<string, any>
---@return table<string, any>
function M.vm_with(a, disk, extra)
	extra = extra or {}
	local port = extra.ssh_port or a.ssh_port
	local w = {
		vm = a.vm_name,
		qemu_bin = a.qemu_bin,
		args = extra.args or M.base_args(a, port),
		disk = disk,
		ssh = {
			port = port,
			options = { StrictHostKeyChecking = "no", UserKnownHostsFile = "/dev/null" },
		},
		wait_ssh = extra.wait_ssh or { timeout_s = 600, interval_s = 3 },
	}
	for k, v in pairs(extra) do w[k] = v end
	return w
end

---@param vm StepResult
---@return Session
local function session(vm)
	assert(vm.err == nil, tostring(vm.err))
	return {
		vm = vm.out.handle,
		target = vm.out.target,
		pid = vm.out.pid,
		disk = vm.out.disk,
	}
end

-- seed(a) -> { backing, path }: build the base image (cached) and ensure the
-- persistent live disk carries the baseline snapshot. Idempotent; refuses
-- while the VM runs.
---@param a Arch|ArchName
---@return Disk
function M.seed(a)
	a = resolve(a)
	-- live disks, snapshots and instance-id files live under .makac/vm-images/ (gitignored)
	makac.fs.mkdir_p(".makac/vm-images")
	local p = step { name = "probe " .. a.vm_name, uses = "qemu:probe", with = { vm = a.vm_name } }
	assert(not p.out.alive,
		("%s is running; run its down first"):format(a.vm_name))

	-- image builds (download + cloud-init) can take minutes; point the user at
	-- the live output when it is not already being streamed.
	local img_state_dir = makac.data_dir .. "/qemu/img/" .. a.image_name
	if makac.fs.stat(img_state_dir .. "/image") == nil and
		not (a.img_verbose or os.getenv("MAKAC_IMG_VERBOSE")) then
		print(("[nvmecheck] building image '%s' (this can take a few minutes)"):format(a.image_name))
		print("[nvmecheck]   stream it:  MAKAC_IMG_VERBOSE=1 makac run ...")
		print(("[nvmecheck]   or follow:  tail -f %s/serial.log"):format(img_state_dir))
	end

	local img = step { name = "image " .. a.image_name, uses = "qemu:img", with = M.image(a) }
	local disk = { backing = img.out.path, path = M.paths(a).live_disk }

	if has_baseline(a, disk.path) then
		print(("baseline %q already in %s — no-op"):format(a.snap_tag, a.live_disk))
		return disk
	end

	print("seeding " .. a.live_disk .. " (persistent overlay + baseline snapshot)")
	local vm = step { name = "boot " .. a.vm_name .. " (seed)", uses = "qemu:vm",
		with = M.vm_with(a, disk) }
	local save = step { name = "savevm " .. a.snap_tag, uses = "qemu:savevm",
		with = { vm = vm.out.handle, tag = a.snap_tag } }
	assert(save.err == nil, "baseline savevm: " .. tostring(save.err))
	step { name = "stop " .. a.vm_name .. " (seeded)", uses = "qemu:vm",
		with = { vm = a.vm_name, state = "stopped", guest_shutdown = false } }
	return disk
end

-- up(a, extra?) -> { vm = handle, target, pid }: resume the baseline. On an
-- already-running VM this is a no-op that still returns the handle/target
-- (qemu:loadvm `state = "started"`). `extra.ssh_port` / `extra.args` let a
-- test (or a second VM) diverge from the defaults.
---@param a Arch|ArchName
---@param extra? table<string, any>
---@return Session
function M.up(a, extra)
	a = resolve(a)
	local p = step { name = "probe " .. a.vm_name, uses = "qemu:probe", with = { vm = a.vm_name } }
	local disk
	if p.out.alive then
		local img = step { name = "image " .. a.image_name, uses = "qemu:img", with = M.image(a) }
		disk = { backing = img.out.path, path = M.paths(a).live_disk }
	else
		disk = M.seed(a)
	end
	local vm = step { name = "resume " .. a.vm_name, uses = "qemu:loadvm",
		with = M.vm_with(a, disk, merge({ snapshot = a.snap_tag, state = "started" }, extra or {})) }
	return session(vm)
end

-- down(a): stop with a clean QMP quit (no guest powerdown handshake — the
-- snapshot is reloaded on every up anyway).
---@param a Arch|ArchName
function M.down(a)
	a = resolve(a)
	step { name = "stop " .. a.vm_name, uses = "qemu:vm",
		with = { vm = a.vm_name, state = "stopped", guest_shutdown = false } }
end

return M
