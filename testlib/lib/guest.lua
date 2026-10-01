-- testlib/lib/guest.lua
-- The `ctx` handed to every test function: guest command/file helpers plus
-- NVMe wiring on top of lib/nvme.lua and lib/arch.lua.
--
--   ctx.arch                 "amd64" | "s390x"
--   ctx.vm                   the resumed VM's qemu handle
--   ctx.target               the VM's ssh target
--   ctx.log(fmt, ...)        prefixed progress print
--   ctx.sh(cmd, opts?)       run on the guest (string -> `sh -c`); -> {code,stdout,stderr}
--   ctx.ok(cmd, opts?)       ctx.sh that raises on non-zero; -> stdout
--   ctx.put(src, dst)        host file -> guest
--   ctx.get(src, dst)        guest file -> host
--   ctx.wait(pred, t, iv?)   poll pred() until truthy; -> value | nil, err
--   ctx.wait_dev(dev, t?)    wait for a block device node to exist
--   ctx.raw(name, size?)     manifest-cached raw disk + fresh per-run copy; -> path
--   ctx.add_nvme(spec, attach?)  QMP-add a stack; -> results (raises on error)
--   ctx.del_nvme(id)         QMP device_del
--   ctx.bind_vfio(name?)   hand a controller to vfio-pci; -> the controller's BDF
--   ctx.spawn(opts?)         a second VM on the same baseline (rare; see README)
--   ctx.teardown()           stop/free anything ctx.spawn created (runner calls it)

local archlib = require("./arch")
local nvmelib = require("./nvme")

---@alias Predicate fun(): any

---@class GuestCtx
---@field arch ArchName
---@field vm any
---@field target Target
---@field log fun(fmt: string, ...: any)
---@field sh fun(cmd: string|string[], opts?: RunOpts): RunResult
---@field ok fun(cmd: string|string[], opts?: RunOpts): string
---@field put fun(src: string, dst: string)
---@field get fun(src: string, dst: string)
---@field wait fun(pred: Predicate, timeout_s?: number, interval_s?: number): any, string?
---@field wait_dev fun(dev: string, timeout_s?: number): boolean?, string?
---@field raw fun(name: string, size?: string): string
---@field add_nvme fun(spec: NvmeSpec, attach?: table<string, any>): QmpResult[]
---@field del_nvme fun(id: string)
---@field bind_vfio fun(): string
---@field spawn fun(opts?: SpawnOpts): SpawnedVm
---@field teardown fun()

---@class SpawnOpts
---@field name? string
---@field ssh_port? integer

---@class SpawnedVm
---@field name string
---@field vm any
---@field target Target
---@field pid integer
---@field disk string

local M = {}

---@param arch_name ArchName
---@param session Session
---@return GuestCtx
function M.context(arch_name, session)
	local a = archlib.get(arch_name)
	local nvme_index = 0
	---@type SpawnedVm[]
	local spawned = {}
	local ctx = {
		arch = arch_name,
		vm = session.vm,
		target = session.target,
	}
	---@cast ctx GuestCtx

	function ctx.log(fmt, ...)
		print(("[nvmecheck/%s] " .. fmt):format(arch_name, ...))
	end

	function ctx.sh(cmd, opts)
		if type(cmd) == "table" then
			return ctx.target:run(cmd, opts)
		end
		return ctx.target:run({ "sh", "-c", cmd }, opts)
	end

	function ctx.ok(cmd, opts)
		local r = ctx.sh(cmd, opts)
		if r.code ~= 0 then
			error(("guest command failed (code %d): %s\nstdout: %s\nstderr: %s")
				:format(r.code, tostring(cmd), r.stdout or "", r.stderr or ""), 0)
		end
		return r.stdout or ""
	end

	function ctx.put(src, dst) ctx.target:put(src, dst) end
	function ctx.get(src, dst) ctx.target:get(src, dst) end

	function ctx.wait(pred, timeout_s, interval_s)
		timeout_s = timeout_s or 60
		interval_s = interval_s or 1
		local t = makac.time
		local deadline = t.now() + timeout_s * t.ns_per_s
		while true do
			local ok, res = pcall(pred)
			if ok and res then return res end
			if t.now() > deadline then
				return nil, ("timed out after %ss"):format(timeout_s)
			end
			t.sleep(interval_s * t.ns_per_s)
		end
	end

	function ctx.wait_dev(dev, timeout_s)
		return ctx.wait(function()
			return ctx.sh("test -b " .. dev).code == 0
		end, timeout_s or 60)
	end

	-- fresh copy of a manifest-cached raw image (so tests don't share a disk)
	function ctx.raw(name, size)
		local spec = archlib.raw_spec(a, name, size)
		local img = step { name = "raw " .. spec.name, uses = "qemu:img", with = spec }
		local dest = (".makac/vm-images/nvme-%s-%s.img"):format(a.name, name)
		makac.fs.mkdir_p(".makac/vm-images")
		assert(makac.exec({ "cp", "-f", img.out.path, dest }).code == 0,
			"copying raw backing " .. spec.name)
		return dest
	end

	function ctx.add_nvme(spec, attach)
		if attach == nil then
			attach = archlib.nvme_attach(a, nvme_index)
			nvme_index = nvme_index + 1
		end
		local id = spec.id or "nvme"
		local res = step {
			name = "nvme add " .. id,
			uses = "qemu:qmp/send",
			with = { vm = ctx.vm, commands = nvmelib.commands(spec, attach) },
		}
		for i, r in ipairs(res.out.results) do
			if r.error ~= nil then
				error(("nvme add %s: command %d failed: %s"):format(id, i, r.error.desc), 0)
			end
		end
		return res.out.results
	end

	function ctx.del_nvme(id)
		step {
			name = "nvme del " .. id,
			uses = "qemu:qmp/send",
			with = { vm = ctx.vm, commands = nvmelib.remove_commands({ id }) },
		}
	end

	-- Hand a controller to vfio-pci (amd64 needs the emulated intel-iommu for
	-- an iommu_group; s390x zPCI provides one natively); -> the controller's BDF.
	-- `name` defaults to "nvme0"; use "nvme1", ... for multi-controller batches.
	function ctx.bind_vfio(name)
		name = name or "nvme0"
		assert(ctx.wait(function()
			return ctx.sh("test -e /sys/class/nvme/" .. name).code == 0
		end, 90), "controller " .. name .. " never appeared")
		local bdf = assert(
			ctx.ok("cat /sys/class/nvme/" .. name .. "/device/uevent"):match("PCI_SLOT_NAME=([^\n]+)"),
			"could not read the controller's BDF")
		assert(ctx.sh("test -e /sys/bus/pci/devices/" .. bdf .. "/iommu_group").code == 0,
			"no iommu_group for " .. bdf .. " (amd64 needs the emulated intel-iommu)")
		ctx.ok("modprobe vfio-pci")
		ctx.ok("echo " .. bdf .. " > /sys/bus/pci/drivers/nvme/unbind")
		ctx.ok("echo vfio-pci > /sys/bus/pci/devices/" .. bdf .. "/driver_override")
		ctx.ok("echo " .. bdf .. " > /sys/bus/pci/drivers/vfio-pci/bind")
		return bdf
	end

	-- Rare multi-VM case: a second VM on the SAME arch baseline. A full copy
	-- is used because -loadvm only looks in the top device, so an overlay
	-- would not see the snapshot. Distinct ssh port avoids the forward clash.
	function ctx.spawn(opts)
		opts = opts or {}
		local n = #spawned + 1
		local name = opts.name or (a.vm_name .. "-b" .. n)
		local port = opts.ssh_port or (a.ssh_port + n)
		local paths = archlib.paths(a)
		local disk = (".makac/vm-images/nvme-%s-spawn%d.qcow2"):format(a.name, n)
		assert(makac.exec({ "cp", "-f", paths.live_disk, disk }).code == 0,
			"copying live disk for " .. name)
		local vm = step {
			name = "spawn " .. name,
			uses = "qemu:loadvm",
			with = archlib.vm_with(a, { backing = paths.image, path = disk }, {
				vm = name, snapshot = a.snap_tag, state = "started", ssh_port = port,
				wait_ssh = { timeout_s = 600, interval_s = 3 },
			}),
		}
		assert(vm.err == nil, tostring(vm.err))
		local sp = { name = name, vm = vm.out.handle, target = vm.out.target, pid = vm.out.pid, disk = disk }
		spawned[#spawned + 1] = sp
		return sp
	end

	function ctx.teardown()
		for _, sp in ipairs(spawned) do
			pcall(function()
				step {
					name = "stop spawned " .. sp.name, uses = "qemu:vm",
					with = { vm = sp.name, state = "stopped", guest_shutdown = false },
				}
			end)
			os.remove(sp.disk)
		end
		spawned = {}
	end

	return ctx
end

return M
