-- testlib/lib/nvme.lua
-- Pure NVMe device wiring: a test's *spec* -> an ordered device *plan* ->
-- QMP commands (hotplug) or `-device`/`-drive` argv (cold plug).
--
-- No socket, no VM, no `step` here: these are table-builders, so the same
-- spec can be rendered for either attachment path or inspected in a log.
--
-- Spec schema (all optional except meaning):
--   device        QEMU device behind the controller (default "nvme"): any
--                 name a `-device`/`device_add` accepts, e.g. "nvme" (QEMU's
--                 test device) or "vnvme" (its hardened production
--                 controller). Custom builds need nothing here — an unknown
--                 name is QEMU's to reject.
--   id            base id (default "<device>0"); sub-ids derive from it
--   serial        ctrl serial (default id)
--   drive         namespace backing: a path string (raw/qcow2 by drive_format)
--                 or a full blockdev-args table; nil = no namespace
--   drive_node    blockdev node name (default id.."-bdev")
--   drive_format  "raw" (default) | "qcow2" | ...
--   drive_cache   blockdev cache mode (default { direct = true }) — table or
--                 false to omit
--   subsys        nil/false = none; true = {} or a table of nvme-subsys params
--   subsys_id     default id.."-subsys"
--   ctrl          extra controller params (merged last, wins)
--   ns            extra nvme-ns params (merged last, wins); PRESENCE means an
--                 explicit namespace. When nil and `drive` is set, the drive is
--                 attached to the CTRL instead (implicit nsid 1) so the stack
--                 stays hotpluggable.
--   ns_id         default id.."-ns"
--   nsid          default 1
--
-- Only "nvme" has separate subsystem/namespace objects. Every other device
-- owns a single implicit nsid-1 namespace fed by `drive`, so `subsys`/`ns` on
-- such a spec is an error rather than a silently ignored key.
--
-- `attach` (from the arch) fixes WHERE the controller lands, e.g.
-- { bus = "rp0", addr = "0.0" } for amd64 Q35, {} for s390 zPCI. It is merged
-- last, so it wins over the defaults and over `spec.ctrl`.
--
-- THIS QEMU BUILD: only the controller is hotpluggable. TYPE_NVME_BUS has no
-- hotplug handler, so `device_add nvme-ns` fails with "Bus ... does not support
-- hotplugging" and `device_add nvme-subsys` fails with "can not be hotplugged".
-- Consequences:
--   * hotplug path: give `drive` and NO `ns` (implicit nsid 1). ctrl-level
--     params (block sizes, ...) ride the ctrl; NS-only params (zns.*, fdp.*)
--     cannot.
--   * NS/ctrl-subsys params: use the COLD path (nvme.cold_args) in a test's
--     machine args, i.e. boot/restart with the stack present.

-- `device` decides which keys are legal: QEMU's test device ("nvme") honours
-- all of them, while a device with one implicit namespace ("vnvme", ...) takes
-- only `id`, `serial`, `drive*` and `ctrl`, and rejects `subsys*`/`ns*`.
---@class NvmeSpec
---@field device? string         QEMU device: "nvme" (default) or any other
---@field id? string             base id, default "<device>0"
---@field serial? string         controller serial, default the id
---@field drive? string|table    namespace backing: a path, or blockdev args
---@field drive_node? string     blockdev node, default "<id>-bdev"
---@field drive_format? string   "raw" (default) | "qcow2" | ...
---@field drive_cache? table|false  blockdev cache, default { direct = true }
---@field ctrl? table<string, any>  extra controller properties (merged last)
---@field subsys? boolean|table    nvme only: no subsystem, or its properties
---@field subsys_id? string         nvme only, default "<id>-subsys"
---@field ns? table<string, any>   nvme only: presence means an explicit namespace
---@field ns_id? string             nvme only, default "<id>-ns"
---@field nsid? integer             nvme only, default 1

-- What a driver accepts for one device key (`with.nvme`, `with.vnvme`,
-- `with.<custom>`): one controller, a list of controllers, or a function that
-- adds and binds its own devices and returns their BDFs.
---@alias DeviceSetup NvmeSpec|NvmeSpec[]|fun(ctx: any, with: table): string[]

---@class NvmePlanEntry
---@field kind "blockdev"|"subsys"|"ctrl"|"ns"
---@field id string
---@field driver? string QEMU type of a device entry (nil for blockdev)
---@field args table<string, any>

---@class QmpCommand
---@field execute string
---@field arguments? table<string, any>

---@class QmpResult
---@field return? any
---@field error? { class: string, desc: string }

local M = {}

-- merge(...): shallow, later wins, fresh table.
---@param ... table
---@return table
local function merge(...)
	local t = {}
	for _, src in ipairs({ ... }) do
		for k, v in pairs(src or {}) do t[k] = v end
	end
	return t
end

-- --- serialization (cold argv only) --------------------------------------

-- flatten_args: dotted-key form, keys sorted, `true` = bare flag. Nested
-- tables become `prefix.subkey=...` (blockdev's file.driver/file.filename).
---@param out string[]
---@param prefix string
---@param value any
local function flatten_args(out, prefix, value)
	if type(value) ~= "table" then
		out[#out + 1] = prefix .. "=" .. tostring(value)
		return
	end
	local keys = {}
	for k in pairs(value) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local v = value[k]
		local key = prefix == "" and k or (prefix .. "." .. k)
		if v == true then
			out[#out + 1] = key
		elseif v ~= nil and v ~= false then
			flatten_args(out, key, v)
		end
	end
end

local function serialize(args)
	local flat = {}
	flatten_args(flat, "", args)
	return table.concat(flat, ",")
end

-- --- plan ----------------------------------------------------------------

local BLOCKDEV_DRIVER = { raw = "raw", qcow2 = "qcow2" }

-- plan(spec) -> ordered list of devices:
--   { kind = "blockdev"|"subsys"|"ctrl"|"ns", id = <str>,
--     driver = <QEMU type, device entries only>, args = <table> }
---@param spec? NvmeSpec
---@return NvmePlanEntry[]
function M.plan(spec)
	spec = spec or {}
	local device = spec.device or "nvme"
	local id = spec.id or (device .. "0")
	local plan = {}

	if device ~= "nvme" then
		assert(not spec.subsys and spec.ns == nil and spec.nsid == nil
			and spec.ns_id == nil and spec.subsys_id == nil,
			("nvme: device '%s' has a single implicit namespace: drop 'subsys'/'ns'")
			:format(device))
	end

	local drive_node
	local drive = spec.drive
	if drive ~= nil then
		drive_node = spec.drive_node or (id .. "-bdev")
		local args
		if type(drive) == "table" then
			args = merge(drive, { ["node-name"] = drive_node })
			args.driver = args.driver or spec.drive_format or "raw"
		else
			local format = spec.drive_format or "raw"
			assert(BLOCKDEV_DRIVER[format] or format ~= "", "unknown drive_format")
			args = {
				["node-name"] = drive_node,
				driver = format,
				["read-only"] = false,
				file = { driver = "file", filename = drive },
			}
			if spec.drive_cache ~= false then
				args.cache = spec.drive_cache or { direct = true }
			end
		end
		plan[#plan + 1] = { kind = "blockdev", id = drive_node, args = args }
	end

	local subsys_id
	if spec.subsys then
		subsys_id = spec.subsys_id or (id .. "-subsys")
		plan[#plan + 1] = {
			kind = "subsys", id = subsys_id, driver = "nvme-subsys",
			args = spec.subsys == true and {} or spec.subsys,
		}
	end

	local has_ns = spec.ns ~= nil
	local ctrl = {
		id = id,
		serial = spec.serial or id,
	}
	if subsys_id then ctrl.subsys = subsys_id end
	-- implicit namespace: the drive rides the controller's blkconf
	if drive_node and not has_ns then ctrl.drive = drive_node end
	plan[#plan + 1] = {
		kind = "ctrl", id = id, driver = device,
		args = merge(ctrl, spec.ctrl or {}),
	}

	if has_ns then
		local ns = {
			id = spec.ns_id or (id .. "-ns"),
			bus = subsys_id or id,
			nsid = spec.nsid or 1,
		}
		if drive_node then ns.drive = drive_node end
		plan[#plan + 1] = {
			kind = "ns", id = ns.id, driver = "nvme-ns",
			args = merge(ns, spec.ns),
		}
	end

	return plan
end

-- --- render: QMP (hotplug) -----------------------------------------------

-- render_args(entry) -> the QEMU arguments for one plan entry. The device type
-- rides the entry (`driver`), so a ctrl spec can name any QEMU NVMe device.
---@param d NvmePlanEntry
---@return table<string, any>
local function render_args(d)
	return merge(d.args, { driver = d.driver })
end

-- commands(spec, attach?) -> list of QMP command tables, in dependency order.
-- `attach` lands on the controller only.
---@param spec NvmeSpec
---@param attach? table<string, any>
---@return QmpCommand[]
function M.commands(spec, attach)
	local plan = M.plan(spec)
	local cmds = {}
	for _, d in ipairs(plan) do
		if d.kind == "blockdev" then
			cmds[#cmds + 1] = { execute = "blockdev-add", arguments = d.args }
		else
			local args = render_args(d)
			if d.kind == "ctrl" then args = merge(args, attach or {}) end
			cmds[#cmds + 1] = { execute = "device_add", arguments = args }
		end
	end
	return cmds
end

-- --- render: cold argv ----------------------------------------------------

-- cold_args(spec, attach?) -> argv words for a machine spec. Uses
-- `-blockdev` for the backing (nested args serialize with dotted keys) and
-- `-device` for subsys/ctrl/ns.
---@param spec NvmeSpec
---@param attach? table<string, any>
---@return string[]
function M.cold_args(spec, attach)
	local plan = M.plan(spec)
	local out = {}
	for _, d in ipairs(plan) do
		if d.kind == "blockdev" then
			out[#out + 1] = "-blockdev"
			out[#out + 1] = serialize(d.args)
		else
			local args = render_args(d)
			if d.kind == "ctrl" then args = merge(args, attach or {}) end
			out[#out + 1] = "-device"
			out[#out + 1] = serialize(args)
		end
	end
	return out
end

-- --- teardown -------------------------------------------------------------

-- remove_commands(ids) -> device_del commands for the given ctrl/subsys ids.
-- The namespaces and blockdev children go with their controller (QEMU
-- detaches them), so deleting the controller is enough; pass a subsys id too
-- when one was created explicitly.
---@param ids string[]
---@return QmpCommand[]
function M.remove_commands(ids)
	local cmds = {}
	for _, id in ipairs(ids) do
		cmds[#cmds + 1] = { execute = "device_del", arguments = { id = id } }
	end
	return cmds
end

return M
