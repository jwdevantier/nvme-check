#!/usr/bin/env makac
-- nvme-check — front-end test runner for the test suites.
--
-- Discovers tests/<suite>/workflow.lua, loads each suite's DECLARATION
-- (`return { uses?, tests = {...} }` — a test is a step-spec the harness
-- knows two things about: name/uses/tags/archs; the driver must be named by
-- the test or the suite; see
-- tmp-decomplect-vfio-and-tests.md), selects (arch, test) pairs in one pass
-- across the union of suites, then executes each pair as a makac step:
-- `res.err` is a FAIL, anything else a PASS.
--
-- Tag selection: -w/--where takes a pytest-style boolean expression
-- (testlib/lib/tagexpr.lua); test name, suite and arch are implicit tags.
--
-- Usage:
--   ./nvme-check.lua [--help]
--   ./nvme-check.lua [suite...] [-c file] [-a arch]... [-w expr] [-l]
--
--   suite               one or more suites (default: all of tests/*)
--   -c, --config file   per-machine config file (default: config.user.lua;
--                       env: NVME_CONFIG; see config.user.sample.lua)
--   -a, --arch arch     only this arch (repeatable, or comma-separated)
--   -w, --where expr    boolean tag expression, pytest -m style
--   -l, --list          list selected (arch, test) pairs, run nothing
--   -h, --help          this text
--
-- Examples:
--   ./nvme-check.lua
--   ./nvme-check.lua tp4176 --arch s390x
--   ./nvme-check.lua tp4176:identify        (one test — suite:test)
--   ./nvme-check.lua --where "fast and not slow"
--   ./nvme-check.lua -c ci.lua --where "(aer or feature) and amd64"
--   ./nvme-check.lua tp4176 -w aer --list

-- config/ is required first and -c/--config applied before anything else
-- loads: requiring arch/selection evaluates the QEMU paths at load time.
local config = require("pkgs/nvmecheck/config")

local USAGE = [=[
usage: nvme-check.lua [suite[:test]...] [-c file] [-a arch]... [-w expr] [-l]

  suite[:test]      one or more suites, or suite:test pairs
                    (default: all of tests/*)
  -c, --config file per-machine config file (default: config.user.lua;
                    env: NVME_CONFIG; see config.user.sample.lua)
  -a, --arch arch   only this arch (repeatable, or comma-separated)
  -w, --where expr  boolean tag expression, pytest -m style:
                    "aer or feature", "fast and not slow", ...
  -l, --list        list selected (arch, test) pairs, run nothing
  -h, --help        this text
]=]

-- --- tiny arg parser ------------------------------------------------------

---@param s string
---@return string[]
local function split_csv(s)
	local out = {}
	for w in s:gmatch("[^,]+") do out[#out + 1] = w end
	return out
end

---@param acc string[]
---@param s string
local function push_csv(acc, s)
	for _, w in ipairs(split_csv(s)) do acc[#acc + 1] = w end
end

---@param argv string[]
---@return { suites: string[], test_names: string[], test_reqs: { suite: string, name: string }[], sel: Selection, config_path: string? }
local function parse_args(argv)
	local sel = { archs = {} } ---@type Selection
	local suites = {}
	local test_names = {}   -- batch names folded into the where expression
	local test_reqs = {}    -- {suite, name} pairs, for typo validation
	local config_path = nil
	local i = 1
	while i <= #argv do
		local a = argv[i]
		local flag, inline = a:match("^(%-[%-%a]+)=?(.*)$")
		if flag then
			if inline == "" then inline = nil end
			-- value-taking flags consume the next arg when no --flag=value form
			local function value()
				if inline == nil then i = i + 1; inline = argv[i] end
				assert(inline, flag .. " requires a value")
				return inline
			end
			if flag == "-h" or flag == "--help" then
				io.write(USAGE)
				os.exit(0)
			elseif flag == "-l" or flag == "--list" then
				sel.list = true
			elseif flag == "-a" or flag == "--arch" then
				push_csv(sel.archs, value())
			elseif flag == "-w" or flag == "--where" then
				sel.where = value()
			elseif flag == "-c" or flag == "--config" then
				config_path = value()
			else
				error(("unknown flag: %s\n%s"):format(a, USAGE), 0)
			end
		else
			-- positional: suite, or suite:test (test name becomes a where filter;
			-- the pair is validated after suites are loaded)
			local s, t = a:match("^([^:]+):([^:]+)$")
			if s then
				suites[#suites + 1] = s
				test_names[#test_names + 1] = t
				test_reqs[#test_reqs + 1] = { suite = s, name = t }
			else
				suites[#suites + 1] = a
			end
		end
		i = i + 1
	end
	if #sel.archs == 0 then sel.archs = nil end
	return { suites = suites, test_names = test_names, test_reqs = test_reqs, sel = sel, config_path = config_path }
end

-- --- suite discovery --------------------------------------------------------

---@return string[]
local function discover_suites()
	local tests_dir = SCRIPT_DIR .. "/tests"
	local entries, err = makac.fs.listdir(tests_dir)
	assert(entries, ("cannot read %s: %s"):format(tests_dir, tostring(err)))
	local suites = {}
	for _, e in ipairs(entries) do
		if e.is_dir and makac.fs.stat(tests_dir .. "/" .. e.name .. "/workflow.lua") then
			suites[#suites + 1] = e.name
		end
	end
	table.sort(suites)
	return suites
end

-- --- main -------------------------------------------------------------------

local parsed = parse_args(arg)
if parsed.config_path then config.set_path(parsed.config_path) end

-- suite:test args: the test name is an implicit selection tag, so fold the
-- names into the where expression (and-ed with any -w the user gave)
if #parsed.test_names > 0 then
	local name_expr = "(" .. table.concat(parsed.test_names, " or ") .. ")"
	if parsed.sel.where then
		parsed.sel.where = "(" .. parsed.sel.where .. ") and " .. name_expr
	else
		parsed.sel.where = name_expr
	end
end

-- now that the config file choice is settled, load the harness modules
-- (selection -> arch resolves QEMU paths from it at load time)
local selection = require("pkgs/nvmecheck/selection")
local archlib = require("pkgs/nvmecheck/arch")
local tagexpr = require("pkgs/nvmecheck/tagexpr")

-- validate the --where expression up front: a typo must fail in milliseconds,
-- not after the first VM boots
if parsed.sel.where then
	local pred, err = tagexpr.compile(parsed.sel.where)
	if not pred then
		io.stderr:write(tagexpr.explain(parsed.sel.where, err) .. "\n")
		os.exit(2)
	end
end
local available = discover_suites()
local known = {}
for _, suite in ipairs(available) do known[suite] = true end

local suites = parsed.suites
if #suites == 0 then
	suites = available
else
	for _, suite in ipairs(suites) do
		if not known[suite] then
			error(("unknown suite '%s' (available: %s)")
				:format(suite, table.concat(available, ", ")), 0)
		end
	end
	-- dedupe: 'tp4176:aer tp4176:feature' would otherwise load a suite twice
	local seen, unique = {}, {}
	for _, suite in ipairs(suites) do
		if not seen[suite] then seen[suite] = true; unique[#unique + 1] = suite end
	end
	suites = unique
end

-- --- loading suite declarations --------------------------------------------

-- load_suite(suite) -> TestDef[]: dofile the workflow's declaration, stamp
-- each test with its suite and resolve its driver (per-test `uses`, then the
-- suite default; a test with neither is an error — there is no default
-- driver).
---@param suite string
---@return TestDef[]
local function load_suite(suite)
	local path = SCRIPT_DIR .. "/tests/" .. suite .. "/workflow.lua"
	local def = dofile(path)
	assert(type(def) == "table" and type(def.tests) == "table",
		("%s must return { uses?, tests = {...} }"):format(path))
	local tests = {}
	for i, t in ipairs(def.tests) do
		assert(type(t) == "table" and type(t.name) == "string",
			("%s: test #%d needs a name"):format(path, i))
		assert(type(t.with or {}) == "table",
			("%s: test '%s': 'with' must be a table"):format(path, t.name))
		assert(t.uses or def.uses,
			("%s: test '%s' names no driver (set 'uses' on the test or the suite)"):format(path, t.name))
		tests[#tests + 1] = {
			name = t.name,
			uses = t.uses or def.uses,
			suite = suite,
			tags = t.tags,
			archs = t.archs,
			with = t.with or {},
		}
	end
	return tests
end

local all_tests = {} ---@type TestDef[]
local load_failed = {}
for _, suite in ipairs(suites) do
	local ok, res = pcall(load_suite, suite)
	if ok then
		for _, t in ipairs(res) do all_tests[#all_tests + 1] = t end
	else
		load_failed[#load_failed + 1] = { suite = suite, err = tostring(res) }
	end
end
if #load_failed > 0 then
	for _, f in ipairs(load_failed) do
		print(("workflow %s failed to load: %s"):format(f.suite, f.err))
	end
	error("nvme-check: failures", 0)
end

-- suite:test typo check: an explicitly named test that does not exist should
-- fail loudly, not silently select nothing (unlike -w, where an unknown tag
-- legitimately matches nothing).
for _, req in ipairs(parsed.test_reqs) do
	local found, avail = false, {}
	for _, t in ipairs(all_tests) do
		if t.suite == req.suite then
			avail[#avail + 1] = t.name
			if t.name == req.name then found = true end
		end
	end
	if not found then
		table.sort(avail)
		error(("unknown test '%s' in suite '%s' (available: %s)")
			:format(req.name, req.suite, table.concat(avail, ", ")), 0)
	end
end

-- --- one selection pass over the union of all suites ------------------------

local selected, skipped = selection.expand(all_tests, parsed.sel)

if parsed.sel.list then
	for _, p in ipairs(selected) do
		print(("  %-6s %-24s %s"):format(p.arch,
			p.test.suite .. ":" .. p.test.name,
			table.concat(p.test.tags or {}, ",")))
	end
	print(("\n%d selected, %d skipped"):format(#selected, skipped))
	os.exit(0)
end

-- Refuse up front when an arch in play has no QEMU binaries configured,
-- rather than failing one test at a time.
for _, arch in ipairs(parsed.sel.archs or archlib.names) do archlib.get(arch) end

-- --- execute: one step per (arch, test) pair --------------------------------

local failures = {}
for _, p in ipairs(selected) do
	local label = p.test.suite .. ":" .. p.test.name
	print(("\n=== [%s] %s ==="):format(p.arch, label))

	-- with is driver-owned; the runner injects only arch/suite/name
	local with = {}
	for k, v in pairs(p.test.with) do with[k] = v end
	with.arch = p.arch
	with.suite = p.test.suite
	with.name = p.test.name

	local ok, res = pcall(step, { name = label, uses = p.test.uses, with = with })
	-- NB: not `ok and res.err or tostring(res)` — a nil res.err must stay nil
	local err
	if ok then err = res and res.err else err = tostring(res) end
	if err == nil then
		print(("  PASS [%s] %s"):format(p.arch, label))
	else
		-- concise here; the full err (which for libvfn-simple embeds the
		-- guest's whole stdout/stderr) is printed once in the global summary
		print(("  FAIL [%s] %s"):format(p.arch, label))
		failures[#failures + 1] = { arch = p.arch, name = label, err = tostring(err) }
	end
end

print(("\n%d ran, %d skipped, %d failed"):format(#selected, skipped, #failures))
if #failures > 0 then
	for _, f in ipairs(failures) do
		print(("  FAIL [%s] %s: %s"):format(f.arch, f.name, f.err))
	end
	error("nvme-check: failures", 0)
end
