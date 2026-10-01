-- testlib/lib/batch.lua
-- Batch selection + execution.
--
-- A batch is `{ name, program, nvme, archs?, tags?, pre_test?, post_test? }`.
-- `run` implements the lifecycle from DESIGN.md §5:
--
--   up(arch) -> setup devices (b.nvme) -> pre_test -> build+put+run(program)
--            -> post_test -> down(arch)
--
-- `nvme` is declarative:
--   * a cluster spec: { drive = "64M", ctrl = {...}, ... }
--   * a list of them, or
--   * a function(ctx, b) that adds/binds its own devices and returns BDFs.
-- A bare size in `drive` ("64M") is resolved via ctx.raw() at device-add
-- time, when the VM (and thus ctx) exists.

local archlib = require("./arch")
local guestlib = require("./guest")
local tagexpr = require("./tagexpr")

---@class NvmeTest
---@field name? string
---@field program string
---@field nvme? NvmeSpec|NvmeSpec[]|fun(ctx: GuestCtx, b: NvmeTest): string[]
---@field archs? string[]
---@field tags? string[]
---@field pre_test? fun(ctx: GuestCtx, b: NvmeTest)
---@field post_test? fun(ctx: GuestCtx, b: NvmeTest, result: table)

local M = {}

-- --- small helpers --------------------------------------------------------

---@param t string[]
---@param v string
---@return boolean
local function has(t, v)
	for _, x in ipairs(t) do if x == v then return true end end
	return false
end

---@param s string
---@return string
local function shquote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- a bare size like "64M", "1G", "512" (no path separators)
local SIZE = "^%s*%d+%s*[kKmMgGtTpP]?[iI]?[bB]?%s*$"

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

-- setup_devices(ctx, b) -> string[]  (the BDFs to expose to the program)
---@param ctx GuestCtx
---@param b NvmeTest
---@return string[]
local function setup_devices(ctx, b)
	local nvme = b.nvme
	local bdfs = {}

	if type(nvme) == "function" then
		local ret = nvme(ctx, b)
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
		local name = b.name or b.program or "batch"
		if #clusters > 1 then name = name .. "-" .. i end
		ctx.add_nvme(with_resolved_drive(ctx, name, spec))
		-- kernel names controllers nvme0, nvme1, ... in add order
		bdfs[#bdfs + 1] = ctx.bind_vfio("nvme" .. (i - 1))
	end
	return bdfs
end

-- --- program build + run --------------------------------------------------

---@param ctx GuestCtx
---@param arch string
---@param tp string
---@param b NvmeTest
---@param bdfs string[]
---@return table
local function run_program(ctx, arch, tp, b, bdfs)
	local program = ("tests/%s/%s"):format(tp, b.program)
	local name = b.name or "batch"

	local built = step {
		name = ("build %s"):format(name),
		uses = "nvmecheck:build",
		with = { arch = arch, program = program, name = name },
	}
	local bin = built.out.path
	local gname = built.out.name

	ctx.put(bin, "/root/" .. gname)
	ctx.ok("chmod +x /root/" .. gname)

	local env = ("NVME_BDF=%s NVME_BDFS=%s "):format(
		shquote(bdfs[1] or ""), shquote(table.concat(bdfs, ",")))
	local out = ctx.sh(env .. "timeout -k 5 120 /root/" .. gname)

	return {
		code = out.code, stdout = out.stdout, stderr = out.stderr,
		bin = bin, name = gname, bdf = bdfs[1], bdfs = bdfs,
	}
end

-- --- one batch ------------------------------------------------------------

-- run(arch, tp, b) -> result { code, stdout, stderr, bin, bdf, bdfs }
-- Raises if the program failed. post_test always runs.
---@param arch string
---@param tp string
---@param b NvmeTest
---@return table
function M.run(arch, tp, b)
	local session = archlib.up(arch)
	local ctx = guestlib.context(arch, session)
	local result = { bdfs = {} }

	local ok, err = pcall(function()
		local bdfs = setup_devices(ctx, b)
		result.bdfs = bdfs
		result.bdf = bdfs[1]

		if b.pre_test then b.pre_test(ctx, b) end

		local r = run_program(ctx, arch, tp, b, bdfs)
		for k, v in pairs(r) do result[k] = v end

		assert(r.code == 0, ("batch '%s' failed (exit %d)\nstdout:\n%s\nstderr:\n%s")
			:format(b.name or b.program or "?", r.code, r.stdout or "", r.stderr or ""))
	end)

	-- post_test is a finally: run it even when setup/the program failed
	if b.post_test then pcall(b.post_test, ctx, b, result) end
	pcall(archlib.down, arch)

	if not ok then error(err, 0) end
	return result
end

-- --- selection ------------------------------------------------------------

---@param b NvmeTest
---@param arch string
---@return table<string, boolean>
local function tag_set(b, arch)
	-- The arch being run and the batch `name` are implicit tags, so
	-- --where "s390x" and --where "my_batch" both select as expected.
	local set = { [arch] = true }
	if b.name then set[b.name] = true end
	for _, t in ipairs(b.tags or {}) do set[t] = true end
	return set
end

---@param b NvmeTest
---@param arch string
---@return boolean
local function arch_selected(b, arch)
	return has(b.archs or archlib.names, arch)
end

-- run_all(tp, batches, opts?) — loop arch x batch with arch/tag selection.
--
-- Selection: archs (matrix restriction) and `where` (a pytest-style tag
-- expression; lib/tagexpr.lua). Sources, in precedence order: run_all opts,
-- then set_selection (a driving runner, i.e. nvme-check.lua).

---@class Selection
---@field archs? string[]
---@field list? boolean
---@field where? string  -- pytest-style boolean expression (see lib/tagexpr.lua)

local runner_sel = nil ---@type Selection?

-- set_selection(sel) — a driving runner (nvme-check.lua) installs CLI-derived
-- selection once; every workflow it loads then runs under it.
---@param sel Selection
function M.set_selection(sel)
	runner_sel = sel
end

---@param tp string
---@param batches NvmeTest[]
---@param opts? { archs?: string[], list?: boolean, where?: string }
function M.run_all(tp, batches, opts)
	opts = opts or {}
	local sel = runner_sel or {}
	local arches = opts.archs or sel.archs or archlib.names
	local list_only = opts.list or sel.list
	local where = opts.where or sel.where
	local where_pred = nil
	if where then
		local pred, err = tagexpr.compile(where)
		if not pred then error(tagexpr.explain(where, err), 0) end
		where_pred = pred
	end

	-- Refuse up front when an arch in play has no QEMU binaries configured,
	-- rather than failing one batch at a time (M.get raises a clear message).
	if not list_only then
		for _, arch in ipairs(arches) do archlib.get(arch) end
	end

	local ran, skipped, failures = 0, 0, {}
	for _, arch in ipairs(arches) do
		for _, b in ipairs(batches) do
			local label = b.name or b.program or "?"
			if arch_selected(b, arch)
				and (where_pred == nil or where_pred(tag_set(b, arch))) then
				ran = ran + 1
				if list_only then
					print(("  %-6s %-44s %s"):format(arch, label,
						table.concat(b.tags or {}, ",")))
				else
					print(("\n=== [%s] %s ==="):format(arch, label))
					local ok, err = pcall(M.run, arch, tp, b)
					if ok then
						print(("  PASS [%s] %s"):format(arch, label))
					else
						print(("  FAIL [%s] %s: %s"):format(arch, label, tostring(err)))
						failures[#failures + 1] = { arch = arch, name = label, err = tostring(err) }
					end
				end
			else
				skipped = skipped + 1
			end
		end
	end

	local verb = list_only and "selected" or "ran"
	print(("\n%d %s, %d skipped, %d failed"):format(ran, verb, skipped, #failures))
	if #failures > 0 then
		for _, f in ipairs(failures) do
			print(("  FAIL [%s] %s: %s"):format(f.arch, f.name, f.err))
		end
		error("nvmecheck: failures", 0)
	end
end

return M
