-- testlib/lib/libvfn_simple.lua
-- The `nvmecheck:libvfn-simple` action: the single-VM libvfn test driver.
--
-- Lifecycle (formerly batch.run, see DESIGN.md §5):
--
--   guest.boot(arch) -> setup devices (with.nvme) -> pre_test
--                    -> nvmecheck:build + scp + run(program)
--                    -> post_test -> ctx.down()
--
-- with = {
--   program   = "batches/identify.zig",   -- relative to tests/<suite>/
--   nvme?     = NvmeSpec | NvmeSpec[] | fun(ctx, with): string[],
--   pre_test?  = fun(ctx, with),
--   post_test? = fun(ctx, with, result),  -- finally: runs even on failure
--   arch/suite/name = <injected by the runner>,
-- }
--
-- `nvme` is declarative: a cluster spec ({ drive = "64M", ctrl = {...}, ... }),
-- a list of them, or a function(ctx, with) that adds/binds its own devices and
-- returns BDFs. A bare size in `drive` ("64M") is resolved via ctx.raw() at
-- device-add time, when the VM (and thus ctx) exists.

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

---@param ctx GuestCtx
---@param name string
---@param spec NvmeSpec
---@return NvmeSpec
local function with_resolved_drive(ctx, name, spec)
  local d = spec.drive
  if type(d) == "string" and d:match(SIZE) then
    local s = {}
    for k, v in pairs(spec) do s[k] = v end
    s.drive = ctx.raw(name, (d:gsub("%s", "")))
    return s
  end
  return spec
end

-- --- device setup ---------------------------------------------------------

-- setup_devices(ctx, with) -> string[]  (the BDFs to expose to the program)
---@param ctx GuestCtx
---@param with table
---@return string[]
local function setup_devices(ctx, with)
  local nvme = with.nvme
  local bdfs = {}

  if type(nvme) == "function" then
    local ret = nvme(ctx, with)
    for _, v in ipairs(ret or {}) do bdfs[#bdfs + 1] = v end
    return bdfs
  end

  local clusters
  if nvme == nil then
    clusters = {}
  elseif nvme[1] ~= nil then
    clusters = nvme
  else
    clusters = { nvme }
  end

  for i, spec in ipairs(clusters) do
    local name = with.name or with.program or "test"
    if #clusters > 1 then name = name .. "-" .. i end
    ctx.add_nvme(with_resolved_drive(ctx, name, spec))
    -- kernel names controllers nvme0, nvme1, ... in add order
    bdfs[#bdfs + 1] = ctx.bind_vfio("nvme" .. (i - 1))
  end
  return bdfs
end

-- --- program build + run --------------------------------------------------

---@param ctx GuestCtx
---@param arch string 'arch' component of qemu-system-<arch>
---@param suite string name of the test-suite
---@param with table the action's payload
---@param bdfs string[]
---@return table
local function run_program(ctx, arch, suite, with, bdfs)
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
  }
end

-- --- the action -----------------------------------------------------------

-- run(with) -> { err } | { changed = true, out = result }
-- post_test and ctx.down() are finallys: they run even when setup/the
-- program failed. Raises become { err } at the boundary.
---@param with table
---@return table
function M.run(with)
  assert(type(with) == "table", "nvmecheck:libvfn-simple: 'with' table is required")
  local arch = assert(with.arch, "nvmecheck:libvfn-simple: 'arch' (runner-injected) is required")
  local suite = assert(with.suite, "nvmecheck:libvfn-simple: 'suite' (runner-injected) is required")
  local program = assert(with.program, "nvmecheck:libvfn-simple: 'program' is required")

  local ctx = nil ---@type GuestCtx?
  local result = { bdfs = {} } ---@type table

  local ok, err = pcall(function()
    ctx = guestlib.boot(arch)
    local bdfs = setup_devices(ctx, with)
    result.bdfs = bdfs
    result.bdf = bdfs[1]

    if with.pre_test then with.pre_test(ctx, with) end

    local r = run_program(ctx, arch, suite, with, bdfs)
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
