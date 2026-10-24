-- testlib/lib/qemu_vfio.lua
-- The `nvmecheck:qemu-vfio` action: the single-VM libvfn test driver.
--
-- Lifecycle:
--
--   guest.boot(arch) -> setup devices (with.nvme) -> pre_test
--                    -> nvmecheck:build + scp + run(program)
--                    -> post_test -> ctx.down()
--
-- `with` payload:
--
--   program    string          Zig test root, relative to tests/<suite>/
--   <device>   DeviceSetup     one key per device the test can run on: "nvme"
--                              and/or "vnvme" today, or any name a custom
--                              QEMU build provides (looked up as with[dev])
--   pre_test   fun(ctx, with)
--   post_test  fun(ctx, with, result)   finally: runs even on failure
--   params     table<string, string>    the concrete case's parameters
--   suite      string                   injected by the runner
--   name       string                   injected by the runner
--   case       string                   injected by the runner
--
-- `params` is the concrete case's parameter table (params.arch, params.dev):
-- the runner does not interpret it, so the driver is where `arch` is read and
-- a case that does not declare it is an error.
--
-- `params.dev` names the QEMU device behind the controller ("nvme" when
-- absent), and the matching `with.<dev>` key carries its spec. So one test can
-- run its program against QEMU's test device (`with.nvme`) and its hardened
-- production controller (`with.vnvme`) from the same source. Any device name
-- is allowed — a custom QEMU build only needs its own `with.<name>`; an
-- unknown name is QEMU's to reject at device-add time.
--
-- Every device key takes the same type — one spec, a list of specs, or a
-- function(ctx, with) that adds/binds its own devices and returns BDFs — but
-- not the same spec *keys*: nvme.lua rejects `subsys`/`ns` for devices that own
-- a single implicit namespace. A bare size in `drive` ("64M") is resolved via
-- ctx.raw() at device-add time, when the VM (and thus ctx) exists.

---@class QemuVfioWith
---@field program string
---@field nvme? DeviceSetup device spec for `dev = "nvme"` (the default)
---@field vnvme? DeviceSetup device spec for `dev = "vnvme"`
---@field pre_test? fun(ctx: GuestCtx, with: QemuVfioWith)
---@field post_test? fun(ctx: GuestCtx, with: QemuVfioWith, result: QemuVfioResult)
---@field params table<string, string>
---@field suite string
---@field name? string
---@field case? string
-- A custom QEMU build adds its own key: `with[params.dev]` is whatever the
-- case's `dev` names, e.g. `with.mydevice = NvmeSpec`.

---@class QemuVfioResult
---@field dev string the QEMU device the case ran against
---@field devices ResolvedDevice[] controllers the case added and bound
---@field bdfs string[] their BDFs, in add order (what the program sees)
---@field bdf? string the first of them (nil when the test added none)
---@field code? integer
---@field stdout? string
---@field stderr? string
---@field bin? string host path of the built test program
---@field name? string file name of the test program inside the guest

local archlib = require("./arch")
local guestlib = require("./guest")

local M = {}

-- --- small helpers --------------------------------------------------------

---@param s string
---@return string
local function shquote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- a bare size like "64M", "1G", "512" (no path separators)
local SIZE = "^%s*%d+%s*[kKmMgGtTpP]?[iI]?[bB]?%s*$"

-- resolve_spec(ctx, name, spec, dev, index) -> a copy of `spec` stamped for
-- `dev`, with a bare size in `drive` turned into a fresh per-run raw disk.
--
-- `index` is the controller's position in the guest (0-based: nvme0, nvme1,
-- ...) and only fixes the default `id`, so a list of specs cannot collide on
-- ids, blockdev node names or serials. Everything else is the caller's.
---@param ctx GuestCtx
---@param name string
---@param spec NvmeSpec
---@param dev string
---@param index integer
---@return NvmeSpec
local function resolve_spec(ctx, name, spec, dev, index)
  assert(spec.device == nil or spec.device == dev,
    ("with.%s sets device = %q, but the case's 'dev' parameter is %q")
    :format(dev, tostring(spec.device), dev))
  -- shallow copy
  local s = {}
  for k, v in pairs(spec) do s[k] = v end
  s.device = dev
  s.id = s.id or (dev .. index)
  local d = s.drive
  -- drive may be specified as
  -- a. a table of drive opts
  -- b. a string path to a backing file
  -- c. a size value, indicating desired drive size.
  if type(d) == "string" and d:match(SIZE) then
    s.drive = ctx.raw(name, (d:gsub("%s", "")))
  end
  return s
end

-- --- device setup ---------------------------------------------------------
--
-- Three steps, deliberately kept apart:
--
--   declare_devices(with, dev)     pure: what did the test ask for?
--   plan_devices(ctx, with, dev)   resolve each spec (device + id stamped,
--                                  drive materialised) -- no VM mutation
--   apply_devices(ctx, planned)    add every stack, then bind every controller
--
-- Nothing before apply_devices touches QEMU or the guest, so a bad spec or a
-- failed disk copy costs a boot and nothing else.

-- One controller the test asked for, resolved but not yet created.
---@class PlannedDevice
---@field name string per-controller name: backing image + step names
---@field spec NvmeSpec resolved spec: device/id stamped, drive = a real path
---@field index integer position in the guest; the controller is nvme<index>

-- One controller the run actually has: the plan plus the BDF vfio-pci owns.
---@class ResolvedDevice
---@field name string
---@field spec? NvmeSpec nil when a `with.<dev>` function added it itself
---@field bdf string PCI address handed to the program as NVME_BDF(S)
---@field index? integer nil for the function form: the callee owns placement

-- declare_devices(with, dev) -> NvmeSpec[]
-- `with.<dev>` is one spec, an array-like list of specs, or a function (left
-- to setup_devices: it does its own add/bind). A spec never has a `[1]`, so
-- its presence is what distinguishes a list from a single spec.
---@param with QemuVfioWith
---@param dev string
---@return NvmeSpec[]
local function declare_devices(with, dev)
  local decl = with[dev]
  if decl == nil then return {} end
  if decl[1] ~= nil then return decl end
  return { decl }
end

-- plan_devices(ctx, with, dev) -> PlannedDevice[]
---@param ctx GuestCtx
---@param with QemuVfioWith
---@param dev string
---@return PlannedDevice[]
local function plan_devices(ctx, with, dev)
  local specs = declare_devices(with, dev)
  local base = with.name or with.program or "test"
  local planned = {}
  for i, spec in ipairs(specs) do
    -- distinct per controller, so two stacks cannot share a backing image
    local name = #specs > 1 and (base .. "-" .. i) or base
    planned[i] = {
      name = name,
      spec = resolve_spec(ctx, name, spec, dev, i - 1),
      index = i - 1,
    }
  end
  return planned
end

-- apply_devices(ctx, planned) -> ResolvedDevice[]  (fills in `bdf`)
---@param ctx GuestCtx
---@param planned PlannedDevice[]
---@return ResolvedDevice[]
local function apply_devices(ctx, planned)
  -- Add every stack first: if one fails, no earlier controller has been taken
  -- from nvme.ko yet. The kernel still names them nvme0, nvme1, ... in add
  -- order, which is what `index` records.
  for _, d in ipairs(planned) do ctx.add_nvme(d.spec) end
  for _, d in ipairs(planned) do d.bdf = ctx.bind_vfio("nvme" .. d.index) end
  return planned
end

-- setup_devices(ctx, with, dev) -> ResolvedDevice[]
-- The `with.<dev>` function form is normalised into the same shape, with the
-- BDFs it returns and no spec (it created the controllers itself).
---@param ctx GuestCtx
---@param with QemuVfioWith
---@param dev string QEMU device type (the `with` key naming the spec)
---@return ResolvedDevice[]
local function setup_devices(ctx, with, dev)
  if type(with[dev]) == "function" then
    local base = with.name or with.program or "test"
    local done = {}
    for i, bdf in ipairs(with[dev](ctx, with) or {}) do
      done[i] = { name = ("%s-%d"):format(base, i), bdf = bdf }
    end
    return done
  end
  return apply_devices(ctx, plan_devices(ctx, with, dev))
end

-- bdfs_of(devices) -> string[]  (the program's NVME_BDF/NVME_BDFS view)
---@param devices ResolvedDevice[]
---@return string[]
local function bdfs_of(devices)
  local out = {}
  for i, d in ipairs(devices) do out[i] = d.bdf end
  return out
end

-- --- program build + run --------------------------------------------------

---@param ctx GuestCtx
---@param arch string 'arch' component of qemu-system-<arch>
---@param suite string name of the test-suite
---@param with QemuVfioWith the action's payload
---@param devices ResolvedDevice[] controllers this run added and bound
---@return table
local function run_program(ctx, arch, suite, with, devices)
  local bdfs = bdfs_of(devices)
  local program = ("tests/%s/%s"):format(suite, with.program)
  local name = with.name or "test"

  local built = step {
    name = ("build %s"):format(name),
    uses = "nvmecheck:build",
    with = { arch = arch, program = program, name = name },
  }
  assert(built.err == nil, tostring(built.err))
  local bin = built.out.path
  local gname = built.out.name

  ctx.put(bin, "/root/" .. gname)
  ctx.ok("chmod +x /root/" .. gname)

  local env = ("NVME_BDF=%s NVME_BDFS=%s "):format(
    shquote(bdfs[1] or ""), shquote(table.concat(bdfs, ",")))
  local out = ctx.sh(env .. "timeout -k 5 120 /root/" .. gname)

  return {
    code = out.code,
    stdout = out.stdout,
    stderr = out.stderr,
    bin = bin,
    name = gname,
    bdf = bdfs[1],
    bdfs = bdfs,
    devices = devices,
  }
end

-- --- the action -----------------------------------------------------------

-- run(with) -> { err } | { changed = true, out = result }
-- post_test and ctx.down() are finallys: they run even when setup/the
-- program failed. Raises become { err } at the boundary.
---@param with QemuVfioWith
---@return table
function M.run(with)
  assert(type(with) == "table", "nvmecheck:qemu-vfio: 'with' table is required")
  local params = assert(with.params, "nvmecheck:qemu-vfio: 'with.params' (runner-injected) is required")
  local arch = assert(params.arch, "nvmecheck:qemu-vfio: 'params.arch' is required")
  local dev = params.dev or "nvme"
  local suite = assert(with.suite, "nvmecheck:qemu-vfio: 'suite' (runner-injected) is required")
  local program = assert(with.program, "nvmecheck:qemu-vfio: 'program' is required")

  assert(type(dev) == "string" and dev ~= "",
    ("nvmecheck:qemu-vfio: 'params.dev' must be a device name, got %s")
    :format(tostring(dev)))
  -- A test may add no devices at all (`with.nvme` absent). Only a case that
  -- names a device, or that declares one under another name, must have the
  -- spec its `dev` points at.
  if with[dev] == nil and (params.dev ~= nil or with.vnvme ~= nil) then
    local hint = (dev == "nvme" and with.vnvme ~= nil)
        and " (it declares 'with.vnvme': set dev = \"vnvme\" in params)"
        or ""
    error(("nvmecheck:qemu-vfio: 'dev' is %q, but the test declares no "
      .. "'with.%s'%s"):format(dev, dev, hint), 0)
  end

  local ctx = nil ---@type GuestCtx?
  local result = { bdfs = {}, devices = {} } ---@type QemuVfioResult

  local ok, err = pcall(function()
    ctx = guestlib.boot(arch)
    local devices = setup_devices(ctx, with, dev)
    result.dev = dev
    result.devices = devices
    result.bdfs = bdfs_of(devices)
    result.bdf = result.bdfs[1]

    if with.pre_test then with.pre_test(ctx, with) end

    local r = run_program(ctx, arch, suite, with, devices)
    for k, v in pairs(r) do result[k] = v end

    assert(
      r.code == 0,
      ("test '%s' failed (exit %d)\nstdout:\n%s\nstderr:\n%s")
      :format(with.name or program, r.code, r.stdout or "", r.stderr or ""))
  end)

  -- post_test is a finally, and the VM always goes down
  if with.post_test and ctx then pcall(with.post_test, ctx, with, result) end
  pcall(function()
    if ctx then ctx.down() else archlib.down(arch) end
  end)

  if not ok then return { err = tostring(err) } end
  return { changed = true, out = result }
end

return M
