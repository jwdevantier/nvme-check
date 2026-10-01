#!/usr/bin/env makac
-- testlib/tests/tagexpr_test.lua
--
-- Unit tests for the tag-expression DSL (testlib/lib/tagexpr.lua).
-- Pure evaluation only — no VMs involved.
--
--   makac run testlib/tests/tagexpr_test.lua

local tagexpr = require("pkgs/nvmecheck/tagexpr")

local total, failed = 0, 0

local function report(ok, label, detail)
	total = total + 1
	if not ok then
		failed = failed + 1
		print(("FAIL %s%s"):format(label, detail and ("\n     " .. detail) or ""))
	end
end

-- --- evaluation (truth) cases ----------------------------------------------

---@param tags string[]
---@return table<string, boolean>
local function set(tags)
	local s = {}
	for _, t in ipairs(tags) do s[t] = true end
	return s
end

for _, c in ipairs({
	-- atoms
	{ "aer",              { "aer" },                true },
	{ "aer",              { "feature" },            false },
	{ "log_page",         { "log_page" },           true },  -- underscores
	{ "tp4176",           { "tp4176" },             true },  -- digits
	{ "rate-limit",       { "rate-limit" },         true },  -- hyphens
	{ "v1.4",             { "v1.4" },               true },  -- dots
	{ "s390x",            { "amd64" },              false },
	-- and / or / not
	{ "fast and s390x",   { "fast", "s390x" },      true },
	{ "fast and s390x",   { "fast" },               false },
	{ "aer or feature",   { "feature" },            true },
	{ "aer or feature",   { "identify" },           false },
	{ "not slow",         { "fast" },               true },
	{ "not slow",         { "slow" },               false },
	{ "not not fast",     { "fast" },               true },
	-- precedence: not > and > or
	{ "a or b and c",     { "b" },                  false }, -- a or (b and c)
	{ "a or b and c",     { "b", "c" },             true },
	{ "a or b and c",     { "a" },                  true },
	{ "not a and b",      { "a", "b" },             false }, -- (not a) and b
	{ "not a and b",      { "b" },                  true },
	-- parentheses
	{ "(a or b) and c",   { "a" },                  false },
	{ "(a or b) and c",   { "a", "c" },             true },
	{ "not (a or b)",     { "c" },                  true },
	{ "not (a or b)",     { "b" },                  false },
	{ "((a))",            { "a" },                  true },
	-- associativity: and/or are left-assoc (result identical either way)
	{ "a and b and c",    { "a", "b", "c" },        true },
	{ "a or b or c",      { "c" },                  true },
	-- whitespace tolerance
	{ "  fast  and\ts390x ", { "fast", "s390x" },   true },
	-- identifiers are case-sensitive, keywords lowercase-only
	{ "FAST",             { "fast" },               false },
	{ "NOT",              { "slow" },               false }, -- "NOT" is a tag, not the keyword
	-- unknown tags select nothing (a typo is visible via --list, not hidden)
	{ "nosuchtag",        { "aer" },                false },
}) do
	local src, tags, expected = c[1], c[2], c[3]
	local label = ("eval %-30s"):format(("%q"):format(src))
	local pred, err = tagexpr.compile(src)
	if not pred then
		report(false, label, tagexpr.explain(src, err))
	else
		report(pred(set(tags)) == expected, ("%s over {%s}"):format(label, table.concat(tags, ", ")),
			("expected %s"):format(tostring(expected)))
	end
end

-- --- syntax error cases ------------------------------------------------------

for _, c in ipairs({
	--  src,                    expected position (byte index)
	{ "",                       1 },   -- empty
	{ "   ",                    1 },   -- whitespace-only
	{ "(",                      2 },   -- ended inside a paren
	{ "a and",                  6 },   -- missing operand
	{ "and a",                  1 },   -- leading operator
	{ "a b",                    3 },   -- trailing junk
	{ "a or )",                 6 },   -- operator then close
	{ "a | b",                  3 },   -- unknown character
	{ "(a",                     3 },   -- unclosed paren
	{ "a)",                     2 },   -- stray close paren
	{ "a and and b",            7 },   -- doubled operator
	{ "-fast",                  1 },   -- identifier may not start with '-'
	{ ".5",                     1 },   -- ... nor with '.'
}) do
	local src, want_pos = c[1], c[2]
	local label = ("err  %-30s"):format(("%q"):format(src))
	local pred, err = tagexpr.compile(src)
	if pred then
		report(false, label, "compiled successfully, expected a syntax error")
	else
		report(err.pos == want_pos, label .. " pos",
			("pos %d, expected %d — %s"):format(err.pos, want_pos, err.msg))
	end
end

-- --- explain() rendering ------------------------------------------------------

do
	local src = "a or )"
	local pred, err = tagexpr.compile(src)
	local shown = pred and "<compiled>" or tagexpr.explain(src, err)
	report(shown:find("^invalid tag expression: ") ~= nil, "explain prefix", shown)
	report(shown:find("\n  a or %)\n") ~= nil, "explain echo", shown)
	report(shown:find("%^") ~= nil, "explain caret", shown)
end

-- --- summary ------------------------------------------------------------------

print(("\n%d passed, %d failed"):format(total - failed, failed))
if failed > 0 then error("tagexpr tests failed", 0) end
