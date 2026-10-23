#!/usr/bin/env makac
-- nvme-check — front-end test runner for the test suites.
--
-- Discovers tests/<suite>/workflow.lua, loads each suite's DECLARATION
-- (`return { uses?, tests = {...} }` — a test is a step-spec the harness
-- knows four things about: name/uses/tags/params; the driver must be named by
-- the test or the suite; see
-- tmp-decomplect-vfio-and-tests.md), expands each test's top-level `params`
-- into concrete test-cases (lib/params.lua), selects them in one pass across
-- the union of suites, then executes each test-case as a makac step:
-- `res.err` is a FAIL, anything else a PASS.
--
-- Tag selection: -w/--where takes a pytest-style boolean expression
-- (testlib/lib/tagexpr.lua); the suite, the test name and the concrete
-- test-case label (`inspect[arch=s390x]`) are implicit tags, next to a test's
-- own tags and one `key=value` tag per parameter. There is no separate way to
-- pick an architecture: `-w 'arch=s390x'` is it.
--
-- Usage:
--   ./nvme-check.lua [--help]
--   ./nvme-check.lua [suite...] [-c file] [-w expr] [-l]
--
--   suite               one or more suites (default: all of tests/*)
--   -c, --config file   per-machine config file (default: config.user.lua;
--                       env: NVME_CONFIG; see config.user.sample.lua)
--   -w, --where expr    boolean tag expression, pytest -m style
--   -l, --list          list the selected test-cases, run nothing
--   -h, --help          this text
--
-- Examples:
--   ./nvme-check.lua
--   ./nvme-check.lua tp4176 -w 'arch=s390x'
--   ./nvme-check.lua 'nvme14m:inspect[arch=s390x]'
--   ./nvme-check.lua tp4176:identify        (every test-case of one test)
--   ./nvme-check.lua --where "fast and not slow"
--   ./nvme-check.lua -c ci.lua --where "(aer or feature) and arch=amd64"
--   ./nvme-check.lua tp4176 -w aer --list

-- the config module is required first and -c/--config applied before anything
-- else loads: the config file is what config.get() answers from later on.
local config = require("pkgs/nvmecheck/config")

local USAGE = [=[
usage: nvme-check.lua [SUITE...] [-c FILE] [-w EXPR] [-l]
       nvme-check.lua --help

  A suite is a directory under tests/. A selector names a suite
  (`nvme14m`), one test in it (`tp4176:aer`, all of its test-cases) or one
  exact test-case (`tp4176:aer[arch=s390x]`, quote it — `[` and `]` are
  shell globs). Several selectors may be given; the default is every suite.

  Examples:
    ./nvme-check.lua                           every suite, every test-case
    ./nvme-check.lua nvme14m                   one suite
    ./nvme-check.lua tp4176:aer                one test: all its test-cases
    ./nvme-check.lua 'tp4176:aer[arch=s390x]'  one exact test-case
    ./nvme-check.lua --list -w 'fast'          list matches; run nothing

  Query: -w takes a pytest -m style boolean expression over tags. Every
  test-case is tagged with its suite (`nvme14m`), its test name (`aer`),
  its full name (`aer[arch=s390x]`), its declared tags (`fast`,
  `destructive`) and one `key=value` per parameter. Matching is exact:
    -w 'aer'                               a test: both of its test-cases
    -w 'fast and not qtest'                two tags
    -w 'arch=s390x'                        a parameter
    -w '(aer or feature) and arch=amd64'   parentheses group

  -c, --config FILE per-machine config (default: config.user.lua;
                    env: NVME_CONFIG; see config.user.sample.lua)
  -w, --where EXPR  tag expression, pytest -m style (see Query above)
  -l, --list        print the selected test-cases and tags; run nothing
  -h, --help        this text

  documentation: https://jwdevantier.github.io/nvme-check/
                 see "Selecting tests" in the user guide for -w syntax
]=]

-- --- tiny arg parser ------------------------------------------------------

---@param argv string[]
---@return { suites: string[], test_names: string[], test_reqs: { suite: string, name: string }[], sel: Selection, config_path: string? }
local function parse_args(argv)
	local sel = {} ---@type Selection
	local suites = {}
	local test_names = {}   -- test names folded into the where expression
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
			elseif flag == "-w" or flag == "--where" then
				sel.where = value()
			elseif flag == "-c" or flag == "--config" then
				config_path = value()
			else
				error(("unknown flag: %s\n%s"):format(a, USAGE), 0)
			end
		else
			-- positional: suite, or suite:test (the name becomes a where
			-- filter, so it may be a base name or one concrete test-case label;
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

-- positional suite and suite:test args are implicit selection tags: fold them
-- into the where expression (and-ed with any -w the user gave). The test part
-- may be a base name (every test-case of that test) or a concrete test-case
-- label — the
-- lexer accepts the brackets and commas, so 'inspect[arch=s390x]' goes through
-- verbatim.
local filters = {}
if #parsed.suites > 0 then
	filters[#filters + 1] = "(" .. table.concat(parsed.suites, " or ") .. ")"
end
if #parsed.test_names > 0 then
	filters[#filters + 1] = "(" .. table.concat(parsed.test_names, " or ") .. ")"
end
if #filters > 0 then
	local folded = table.concat(filters, " and ")
	if parsed.sel.where then
		parsed.sel.where = "(" .. parsed.sel.where .. ") and " .. folded
	else
		parsed.sel.where = folded
	end
end

-- now that the config file choice is settled, load the harness modules (no
-- QEMU paths are resolved at load time any more; parameter keys are opaque to
-- the runner, so it never learns which one, if any, is an architecture)
local selection = require("pkgs/nvmecheck/selection")
local params = require("pkgs/nvmecheck/params")
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

-- collection is global: every suite is loaded, so `--list` always reports the
-- complete concrete universe and "skipped" counts exactly the test-cases the
-- tag expression rejected — including the test-cases a positional suite/test
-- filter left out. An unknown suite is still a hard error.
for _, suite in ipairs(parsed.suites) do
	if not known[suite] then
		error(("unknown suite '%s' (available: %s)")
			:format(suite, table.concat(available, ", ")), 0)
	end
end
local suites = available

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
			params = t.params,
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

-- Expand every declaration into concrete test-cases (one per params entry;
-- one unparameterized test-case when params is absent). A malformed
-- declaration is a user-facing load error naming the suite and test.
local cases = params.expand_all(all_tests)

-- suite:test typo check: an explicitly named test that does not exist should
-- fail loudly, not silently select nothing (unlike -w, where an unknown tag
-- legitimately matches nothing). The request may name a test (all its
-- test-cases) or one concrete test-case label, e.g. 'inspect[arch=s390x]'.
for _, req in ipairs(parsed.test_reqs) do
	local found, avail, seen = false, {}, {}
	for _, c in ipairs(cases) do
		if c.suite == req.suite then
			if not seen[c.name] then
				seen[c.name] = true
				avail[#avail + 1] = c.name
			end
			if c.name == req.name or c.label == req.name then found = true end
		end
	end
	if not found then
		table.sort(avail)
		error(("unknown test '%s' in suite '%s' (available: %s; a concrete "
			.. "test-case name such as 'inspect[arch=s390x]' works too)")
			:format(req.name, req.suite, table.concat(avail, ", ")), 0)
	end
end

-- --- one selection pass over the union of all suites ------------------------

local selected, skipped = selection.expand(cases, parsed.sel)

if parsed.sel.list then
	for _, c in ipairs(selected) do
		print(("  %-48s %s"):format(c.suite .. ":" .. c.label, table.concat(c.tags, ",")))
	end
	print(("\n%d selected, %d skipped"):format(#selected, skipped))
	os.exit(0)
end

-- --- execute: one step per concrete test-case -------------------------------
--
-- Parameters are opaque to the runner, so it cannot know which one, if any, is
-- an architecture: there was deliberately no up-front "is this arch
-- configured?" check before selection. Each driver reports a missing QEMU
-- binary itself, when it interprets the parameter it cares about.

local failures = {}
for _, c in ipairs(selected) do
	local label = c.suite .. ":" .. c.label
	print(("\n=== %s ==="):format(label))

	-- with is driver-owned; the runner injects only params/suite/name/case
	local with = {}
	for k, v in pairs(c.with) do with[k] = v end
	local cparams = {}
	for k, v in pairs(c.params) do cparams[k] = v end
	with.params = cparams
	with.suite = c.suite
	with.name = c.name
	with.case = c.label

	local ok, res = pcall(step, { name = label, uses = c.uses, with = with })
	-- NB: not `ok and res.err or tostring(res)` — a nil res.err must stay nil
	local err
	if ok then err = res and res.err else err = tostring(res) end
	if err == nil then
		print(("  PASS %s"):format(label))
	else
		-- concise here; the full err (which for qemu-vfio embeds the
		-- guest's whole stdout/stderr) is printed once in the global summary
		print(("  FAIL %s"):format(label))
		failures[#failures + 1] = { name = label, err = tostring(err) }
	end
end

print(("\n%d ran, %d skipped, %d failed"):format(#selected, skipped, #failures))
if #failures > 0 then
	for _, f in ipairs(failures) do
		print(("  FAIL %s: %s"):format(f.name, f.err))
	end
	error("nvme-check: failures", 0)
end
