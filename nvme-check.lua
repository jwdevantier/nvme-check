#!/usr/bin/env makac
-- nvme-check — front-end test runner for the test suites.
--
-- Discovers tests/<suite>/workflow.lua, parses CLI selection, and drives each
-- suite's workflow under it. Standalone runs keep working: 'makac run
-- tests/tp4176/workflow.lua' runs the whole suite.
--
-- Tag selection: -w/--where takes a pytest-style boolean expression
-- (testlib/lib/tagexpr.lua); batch name and arch are implicit tags.
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
--   -l, --list          list selected (arch, batch) pairs, run nothing
--   -h, --help          this text
--
-- Examples:
--   ./nvme-check.lua
--   ./nvme-check.lua tp4176 --arch s390x
--   ./nvme-check.lua --where "fast and not slow"
--   ./nvme-check.lua -c ci.lua --where "(aer or feature) and amd64"
--   ./nvme-check.lua tp4176 -w aer --list

-- config/ is required first and -c/--config applied before anything else
-- loads: requiring batch/arch evaluates the QEMU paths at load time.
local config = require("pkgs/nvmecheck/config")

local USAGE = [=[
usage: nvme-check.lua [suite...] [-c file] [-a arch]... [-w expr] [-l]

  suite             one or more suites (default: all of tests/*)
  -c, --config file per-machine config file (default: config.user.lua;
                    env: NVME_CONFIG; see config.user.sample.lua)
  -a, --arch arch   only this arch (repeatable, or comma-separated)
  -w, --where expr  boolean tag expression, pytest -m style:
                    "aer or feature", "fast and not slow", ...
  -l, --list        list selected (arch, batch) pairs, run nothing
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
---@return { suites: string[], sel: Selection, config_path: string? }
local function parse_args(argv)
	local sel = { archs = {} } ---@type Selection
	local suites = {}
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
			suites[#suites + 1] = a
		end
		i = i + 1
	end
	if #sel.archs == 0 then sel.archs = nil end
	return { suites = suites, sel = sel, config_path = config_path }
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

-- now that the config file choice is settled, load the harness modules
-- (batch -> arch resolves QEMU paths from it at load time)
local batch = require("pkgs/nvmecheck/batch")
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
end

batch.set_selection(parsed.sel)

local failed = {}
for _, suite in ipairs(suites) do
	local ok, err = pcall(dofile, SCRIPT_DIR .. "/tests/" .. suite .. "/workflow.lua")
	if not ok then failed[#failed + 1] = { suite = suite, err = tostring(err) } end
end

if #failed > 0 then
	for _, f in ipairs(failed) do
		print(("workflow %s failed: %s"):format(f.suite, f.err))
	end
	error("nvme-check: failures", 0)
end
