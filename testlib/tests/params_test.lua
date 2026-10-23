#!/usr/bin/env makac
-- testlib/tests/params_test.lua
--
-- Unit tests for parameter expansion (testlib/lib/params.lua).
-- Pure Lua only — no VMs, no QEMU involved.
--
--   makac run testlib/tests/params_test.lua

local params = require("pkgs/nvmecheck/params")

local total, failed = 0, 0

local function report(ok, label, detail)
	total = total + 1
	if not ok then
		failed = failed + 1
		print(("FAIL %s%s"):format(label, detail and ("\n     " .. detail) or ""))
	end
end

---@param name string
---@param extra? table
---@return TestDef
local function decl(name, extra)
	local t = { suite = "mysuite", name = name, uses = "nvmecheck:base", with = {} }
	for k, v in pairs(extra or {}) do t[k] = v end
	return t
end

local function eq(got, want)
	return got == want
end

-- --- label() ------------------------------------------------------------------

for _, c in ipairs({
	{ "x", nil,                        "x" },
	{ "x", {},                         "x" },
	{ "x", { a = "1" },                "x[a=1]" },
	{ "x", { b = "2", a = "1" },       "x[a=1,b=2]" },
	{ "inspect", { dev = "nvme", arch = "amd64" }, "inspect[arch=amd64,dev=nvme]" },
	-- values are verbatim: no quoting or escaping
	{ "x", { a = "1,2" },              "x[a=1,2]" },
	{ "x", { a = "k=v" },              "x[a=k=v]" },
	{ "x", { a = "has space" },        "x[a=has space]" },
}) do
	local name, p, want = c[1], c[2], c[3]
	report(eq(params.label(name, p), want), ("label %-22s"):format(want),
		("got %q"):format(tostring(params.label(name, p))))
end

-- --- expand(): one case per entry, in declared order ---------------------------

do
	local test = decl("inspect", { params = {
		{ arch = "amd64", dev = "vnvme" },
		{ arch = "amd64", dev = "nvme" },
		{ arch = "s390x", dev = "nvme" },
	} })
	local cases = params.expand(test)
	report(#cases == 3, "one case per entry", ("got %d"):format(#cases))
	local want = {
		{ label = "inspect[arch=amd64,dev=vnvme]", arch = "amd64", dev = "vnvme" },
		{ label = "inspect[arch=amd64,dev=nvme]",  arch = "amd64", dev = "nvme" },
		{ label = "inspect[arch=s390x,dev=nvme]",  arch = "s390x", dev = "nvme" },
	}
	for i, w in ipairs(want) do
		local c = cases[i] or {}
		report(eq(c.label, w.label), ("order[%d] %-30s"):format(i, w.label),
			("got %q"):format(tostring(c.label)))
		report(c.params ~= nil and eq(c.params.arch, w.arch) and eq(c.params.dev, w.dev),
			("%s params"):format(w.label), "params mismatch")
		report(eq(c.name, "inspect"), ("%s name"):format(w.label),
			("got %q"):format(tostring(c.name)))
		report(eq(c.suite, "mysuite") and eq(c.uses, "nvmecheck:base"),
			("%s identity"):format(w.label), "suite/uses not copied")
		report(c.with == test.with, ("%s with"):format(w.label),
			"'with' not carried over")
	end
end

-- --- expand(): no params -> one unparameterized case --------------------------

do
	local test = decl("plain")
	local cases = params.expand(test)
	report(#cases == 1, "no params: one case", ("got %d"):format(#cases))
	local c = cases[1] or {}
	report(eq(c.label, "plain"), "no params: label", ("got %q"):format(tostring(c.label)))
	report(eq(c.name, "plain"), "no params: name", ("got %q"):format(tostring(c.name)))
	report(c.params ~= nil and next(c.params) == nil, "no params: params empty",
		"got a non-empty params table")
	report(c.params ~= cases[2], "no params: params is a table", "params is nil")
end

-- --- expand(): tags -----------------------------------------------------------

do
	local test = decl("aer", {
		tags = { "fast", "tp4176" },
		params = { { dev = "vnvme", arch = "s390x" } },
	})
	local c = params.expand(test)[1] or {}
	report(eq(table.concat(c.tags or {}, ","), "fast,tp4176,arch=s390x,dev=vnvme"),
		"tags: declared then parameter (sorted)",
		("got %q"):format(table.concat(c.tags or {}, ",")))
end

do
	-- a hand-written parameter tag is not repeated; the first occurrence wins
	local test = decl("aer", {
		tags = { "fast", "arch=s390x" },
		params = { { arch = "s390x" } },
	})
	local c = params.expand(test)[1] or {}
	report(eq(table.concat(c.tags or {}, ","), "fast,arch=s390x"),
		"tags: deduplicated",
		("got %q"):format(table.concat(c.tags or {}, ",")))
end

do
	-- declaration tags are not repeated either
	local test = decl("aer", { tags = { "fast", "fast" }, params = { { a = "1" } } })
	local c = params.expand(test)[1] or {}
	report(eq(table.concat(c.tags or {}, ","), "fast,a=1"),
		"tags: duplicate declaration tag collapsed",
		("got %q"):format(table.concat(c.tags or {}, ",")))
end

do
	-- no params: just the declaration tags
	local c = params.expand(decl("aer", { tags = { "slow" } }))[1] or {}
	report(eq(table.concat(c.tags or {}, ","), "slow"), "tags: unparameterized",
		("got %q"):format(table.concat(c.tags or {}, ",")))
end

-- --- expand_all(): concatenation in input order --------------------------------

do
	local cases = params.expand_all({
		decl("a", { params = { { x = "1" }, { x = "2" } } }),
		decl("b"),
	})
	local labels = {}
	for _, c in ipairs(cases) do labels[#labels + 1] = c.label end
	report(eq(table.concat(labels, " "), "a[x=1] a[x=2] b"), "expand_all order",
		("got %q"):format(table.concat(labels, " ")))
	report(eq(#params.expand_all({}), 0), "expand_all empty", "expected no cases")
end

-- --- validation errors ---------------------------------------------------------

---@param build fun(): TestDef
---@return string|nil error message
local function err_of(build)
	local ok, err = pcall(function() return params.expand(build()) end)
	if ok then return nil end
	return tostring(err)
end

---@param label string
---@param build fun(): TestDef
---@param needles string[] substrings the message must contain
local function expect_err(label, build, needles)
	local msg = err_of(build)
	if msg == nil then
		report(false, "err " .. label, "no error raised")
		return
	end
	local missing = {}
	for _, n in ipairs({ "mysuite", "mytest" }) do
		if not msg:find(n, 1, true) then missing[#missing + 1] = n end
	end
	for _, n in ipairs(needles) do
		if not msg:find(n, 1, true) then missing[#missing + 1] = n end
	end
	report(#missing == 0, "err " .. label,
		("message %q lacks %s"):format(msg, table.concat(missing, ", ")))
end

expect_err("with.params", function()
	local t = decl("mytest")
	t.with = { params = { arch = "amd64" } }
	return t
end, { "with.params", "runner-owned", "top-level 'params'" })

expect_err("params is a string", function()
	return decl("mytest", { params = "amd64" })
end, { "'params', if present, must be a non-empty array of tables" })

expect_err("params is a bare map", function()
	return decl("mytest", { params = { arch = "amd64" } })
end, { "'params', if present, must be a non-empty array of tables" })

expect_err("params is empty", function()
	return decl("mytest", { params = {} })
end, { "'params', if present, must be a non-empty array of tables" })

expect_err("entry is not a table", function()
	return decl("mytest", { params = { "amd64" } })
end, { "params[1] must be a table" })

expect_err("entry is empty", function()
	return decl("mytest", { params = { { arch = "amd64" }, {} } })
end, { "params[2] is empty" })

expect_err("key is not a string", function()
	return decl("mytest", { params = { { [1] = "amd64" } } })
end, { "params[1]: key 1 must be a string" })

expect_err("value is not a string", function()
	return decl("mytest", { params = { { arch = 64 } } })
end, { "params[1]: value of \"arch\" must be a string, got number" })

-- --- expand() does not mutate the declaration ----------------------------------

do
	local entry = { arch = "amd64" }
	local test = decl("mytest", { tags = { "fast" }, params = { entry, { arch = "s390x" } } })
	local cases = params.expand(test)
	report(#test.params == 2, "declaration: params kept",
		("got %d entries"):format(#test.params))
	report(test.params[1] == entry, "declaration: entry not replaced", "entry identity changed")
	report(eq(#test.tags, 1), "declaration: tags kept",
		("got %d"):format(#test.tags))

	cases[1].params.arch = "mips"
	cases[1].tags[1] = "changed"
	report(eq(cases[2].params.arch, "s390x"), "case params are copies",
		("second case arch is %q"):format(tostring(cases[2].params.arch)))
	report(eq(test.params[1].arch, "amd64"), "declaration untouched",
		("declaration arch is %q"):format(tostring(test.params[1].arch)))
	report(eq(test.tags[1], "fast"), "declaration tags untouched",
		("declaration tag is %q"):format(tostring(test.tags[1])))

	local empty = params.expand(decl("plain"))[1]
	empty.params.x = "1"
	local again = params.expand(decl("plain"))[1]
	report(next(again.params) == nil, "unparameterized params is a fresh table",
		"a later case saw an earlier case's params")
end

-- --- summary ------------------------------------------------------------------

print(("\n%d passed, %d failed"):format(total - failed, failed))
if failed > 0 then error("params tests failed", 0) end
