#!/usr/bin/env makac
-- testlib/tests/selection_test.lua
--
-- Unit tests for case selection (testlib/lib/selection.lua).
-- Pure filtering only — the cases are built by hand, no suites are loaded and
-- no VMs/config are involved.
--
--   makac run testlib/tests/selection_test.lua

local selection = require("pkgs/nvmecheck/selection")

local total, failed = 0, 0

local function report(ok, label, detail)
	total = total + 1
	if not ok then
		failed = failed + 1
		print(("FAIL %s%s"):format(label, detail and ("\n     " .. detail) or ""))
	end
end

-- --- fixtures ----------------------------------------------------------------

---@param suite string
---@param name string
---@param label string
---@param tags string[]
---@return Case
local function case(suite, name, label, tags)
	return { suite = suite, name = name, label = label, tags = tags, params = {} }
end

-- Two suites, one base test name with three parametrizations, plus a plain
-- test and a qtest test (which has its own parameter).
local cases = {
	case("nvme14m", "inspect", "inspect[arch=amd64]", { "nvme14", "fast", "arch=amd64" }),
	case("nvme14m", "inspect", "inspect[arch=s390x]", { "nvme14", "fast", "arch=s390x" }),
	case("tp4176", "inspect", "inspect[arch=amd64,dev=nvme]", { "tp4176", "arch=amd64", "dev=nvme" }),
	case("tp4176", "aer", "aer", { "tp4176", "slow" }),
	case("nvme15m", "feature", "feature[arch=s390x]", { "nvme15", "arch=s390x" }),
}

---@param sel? Selection
---@return Case[], integer
local function expand(sel)
	return selection.expand(cases, sel)
end

---@param selected Case[]
---@return string[]
local function labels(selected)
	local out = {}
	for _, c in ipairs(selected) do out[#out + 1] = c.suite .. ":" .. c.label end
	return out
end

---@param selected Case[]
---@param want string[]
---@return boolean, string
local function same(selected, want)
	local got = labels(selected)
	if #got ~= #want then
		return false, ("got [%s]"):format(table.concat(got, ", "))
	end
	for i = 1, #want do
		if got[i] ~= want[i] then
			return false, ("got [%s]"):format(table.concat(got, ", "))
		end
	end
	return true, ""
end

-- --- no where: everything, in input order -------------------------------------

do
	local selected, skipped = expand(nil)
	local ok, detail = same(selected, {
		"nvme14m:inspect[arch=amd64]",
		"nvme14m:inspect[arch=s390x]",
		"tp4176:inspect[arch=amd64,dev=nvme]",
		"tp4176:aer",
		"nvme15m:feature[arch=s390x]",
	})
	report(ok, "no where selects every case in input order", detail)
	report(#selected == #cases, "no where selects all", ("%d of %d"):format(#selected, #cases))
	report(skipped == 0, "no where skips none", ("skipped %d"):format(skipped))

	local empty_sel, empty_skipped = expand({})
	report(#empty_sel == #cases and empty_skipped == 0, "empty sel behaves like no where")
end

-- --- implicit tags: suite, base name, label ----------------------------------

do
	local selected, skipped = expand({ where = "nvme14m" })
	local ok, detail = same(selected, {
		"nvme14m:inspect[arch=amd64]",
		"nvme14m:inspect[arch=s390x]",
	})
	report(ok, "suite is an implicit tag", detail)
	report(skipped == #cases - #selected, "suite filter skips the rest",
		("skipped %d, expected %d"):format(skipped, #cases - #selected))
end

do
	-- the base name selects every parametrization, across suites
	local selected, skipped = expand({ where = "inspect" })
	local ok, detail = same(selected, {
		"nvme14m:inspect[arch=amd64]",
		"nvme14m:inspect[arch=s390x]",
		"tp4176:inspect[arch=amd64,dev=nvme]",
	})
	report(ok, "base name selects all its parametrizations", detail)
	report(skipped == 2, "base name filter skips the others", ("skipped %d"):format(skipped))
end

do
	-- the concrete label selects exactly one case
	local selected, skipped = expand({ where = "inspect[arch=s390x]" })
	local ok, detail = same(selected, { "nvme14m:inspect[arch=s390x]" })
	report(ok, "label selects exactly one case", detail)
	report(skipped == #cases - 1, "label filter skips the rest", ("skipped %d"):format(skipped))

	local multi = (expand({ where = "inspect[arch=amd64,dev=nvme]" }))
	local ok2, detail2 = same(multi, { "tp4176:inspect[arch=amd64,dev=nvme]" })
	report(ok2, "label with several parameters selects one case", detail2)

	-- exact matching: a label never matches a prefix of a longer one, so
	-- `inspect[arch=amd64]` leaves the amd64,nvme case alone
	local exact = (expand({ where = "inspect[arch=amd64]" }))
	local ok3, detail3 = same(exact, { "nvme14m:inspect[arch=amd64]" })
	report(ok3, "labels match exactly, never as a prefix", detail3)
end

-- --- parameter and declared tags ---------------------------------------------

do
	local selected = (expand({ where = "arch=s390x" }))
	local ok, detail = same(selected, {
		"nvme14m:inspect[arch=s390x]",
		"nvme15m:feature[arch=s390x]",
	})
	report(ok, "parameter tags select their cases", detail)
end

do
	local selected = (expand({ where = "dev=nvme" }))
	local ok, detail = same(selected, { "tp4176:inspect[arch=amd64,dev=nvme]" })
	report(ok, "a non-arch parameter tag works too", detail)

	local none, skipped = expand({ where = "dev=vnvme" })
	report(#none == 0 and skipped == #cases, "unknown parameter tag selects nothing")
end

do
	local selected = (expand({ where = "fast" }))
	local ok, detail = same(selected, {
		"nvme14m:inspect[arch=amd64]",
		"nvme14m:inspect[arch=s390x]",
	})
	report(ok, "declared tags select their cases", detail)
end

do
	local selected = (expand({ where = "fast and arch=amd64" }))
	local ok, detail = same(selected, { "nvme14m:inspect[arch=amd64]" })
	report(ok, "a where expression combines implicit and parameter tags", detail)

	local aer = (expand({ where = "slow and not fast" }))
	local ok2, detail2 = same(aer, { "tp4176:aer" })
	report(ok2, "not/and work over declared tags", detail2)
end

-- --- skipped accounting ------------------------------------------------------

do
	for _, w in ipairs({ "aer", "arch=amd64", "nvme15m", "fast or slow", "nosuchtag" }) do
		local selected, skipped = expand({ where = w })
		report(skipped == #cases - #selected,
			("skipped accounting: %q"):format(w),
			("selected %d, skipped %d, cases %d"):format(#selected, skipped, #cases))
	end
end

-- --- malformed where raises ---------------------------------------------------

do
	local ok, err = pcall(selection.expand, cases, { where = "a and" })
	report(not ok, "a malformed where raises", tostring(err))
	local msg = tostring(err)
	report(msg:find("^invalid tag expression: "), "the error is the tagexpr.explain message", msg)
	report(msg:find("expected a tag"), "the error explains the syntax problem", msg)

	local ok2, err2 = pcall(selection.expand, cases, { where = "a | b" })
	report(not ok2 and tostring(err2):find("unexpected character"), "bad characters raise too",
		tostring(err2))
end

-- --- summary ------------------------------------------------------------------

print(("\n%d passed, %d failed"):format(total - failed, failed))
if failed > 0 then error("selection tests failed", 0) end
