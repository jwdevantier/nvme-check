-- testlib/lib/tagexpr.lua
--
-- Boolean expressions over tags, in the style of pytest's `-m MARKEXPR`:
--
--   "aer or feature"
--   "s390x and fast and not slow"
--   "(identify or smoke) and not slow"
--
-- Grammar (precedence: not > and > or; and/or are left-associative):
--
--   expr  := or
--   or    := and ("or" and)*
--   and   := unary ("and" unary)*
--   unary := "not" unary | atom
--   atom  := IDENT | "(" expr ")"
--   IDENT := [%w_%.%-]+
--
-- Identifiers are case-sensitive; `and`, `or`, `not` are reserved words
-- (lowercase only — a tag literally named "and" cannot be referenced).
--
-- The module is pure Lua (no makac dependencies) so it can be unit-tested
-- under any Lua 5.x runtime. See testlib/tests/tagexpr_test.lua.

local M = {}

---@class TagExprError
---@field msg string  -- human-readable description, no position embedded
---@field pos integer -- byte index into the source string

local IDENT_PAT = "^[%w_%.%-]+"

---@alias TagExprToken { kind: "ident"|"and"|"or"|"not"|"lparen"|"rparen"|"eof", value?: string, pos: integer }

---@param src string
---@return TagExprToken[]? tokens
---@return TagExprError? err
local function lex(src)
	local tokens = {}
	local i, n = 1, #src
	while true do
		local _, e = src:find("^[ \t\r\n]+", i)
		if e then i = e + 1 end
		if i > n then break end
		local c = src:sub(i, i)
		if c == "(" then
			tokens[#tokens + 1] = { kind = "lparen", value = "(", pos = i }
			i = i + 1
		elseif c == ")" then
			tokens[#tokens + 1] = { kind = "rparen", value = ")", pos = i }
			i = i + 1
		elseif c:match("[%w_]") then
			local s, e2 = src:find(IDENT_PAT, i)
			local word = src:sub(s, e2)
			local kind = ({ ["and"] = "and", ["or"] = "or", ["not"] = "not" })[word] or "ident"
			tokens[#tokens + 1] = { kind = kind, value = word, pos = i }
			i = e2 + 1
		else
			return nil, { msg = ("unexpected character '%s'"):format(c), pos = i }
		end
	end
	tokens[#tokens + 1] = { kind = "eof", value = "<end>", pos = n + 1 }
	return tokens
end

-- Parse failures carry position: thrown as TagExprError tables, caught by
-- compile().
local function fail(tok, msg)
	error({ msg = msg, pos = tok.pos }, 0)
end

-- Parsing builds predicate closures directly (no AST materializes). Each
-- parse_* returns (predicate, next_token_index).

local parse_or -- forward declaration (mutual recursion with parse_atom)

---@param ts TagExprToken[]
---@param i integer
local function parse_atom(ts, i)
	local tok = ts[i]
	if tok.kind == "ident" then
		local tag = tok.value
		return function(set) return set[tag] == true end, i + 1
	elseif tok.kind == "lparen" then
		local inner, j = parse_or(ts, i + 1)
		if ts[j].kind ~= "rparen" then
			fail(ts[j], ("expected ')' to close the '(' at column %d"):format(tok.pos))
		end
		return inner, j + 1
	elseif tok.kind == "eof" then
		fail(tok, "expected a tag or '(' but the expression ended here")
	else
		fail(tok, ("expected a tag or '(', got '%s'"):format(tok.value))
	end
end

---@param ts TagExprToken[]
---@param i integer
local function parse_unary(ts, i)
	if ts[i].kind == "not" then
		local sub, j = parse_unary(ts, i + 1)
		return function(set) return not sub(set) end, j
	end
	return parse_atom(ts, i)
end

---@param ts TagExprToken[]
---@param i integer
local function parse_and(ts, i)
	local left, j = parse_unary(ts, i)
	while ts[j].kind == "and" do
		local right
		right, j = parse_unary(ts, j + 1)
		local inner = left
		left = function(set) return inner(set) and right(set) end
	end
	return left, j
end

parse_or = function(ts, i)
	local left, j = parse_and(ts, i)
	while ts[j].kind == "or" do
		local right
		right, j = parse_and(ts, j + 1)
		local inner = left
		left = function(set) return inner(set) or right(set) end
	end
	return left, j
end

-- compile(src) -> predicate | nil, err
--
-- The predicate maps a tag set (table<string, boolean>) to a boolean. A
-- malformed expression yields nil plus a TagExprError with a byte position;
-- use explain() to render it for a user.
--
---@param src string
---@return (fun(set: table<string, boolean>): boolean)? predicate
---@return TagExprError? err
function M.compile(src)
	assert(type(src) == "string", "tagexpr.compile: src must be a string")
	local tokens, lerr = lex(src)
	if not tokens then return nil, lerr end
	if tokens[1].kind == "eof" then
		return nil, { msg = "empty expression", pos = 1 }
	end
	local ok, pred, j = pcall(parse_or, tokens, 1)
	if not ok then
		if type(pred) == "table" and pred.msg and pred.pos then
			return nil, pred ---@cast pred TagExprError
		end
		error(pred, 0) -- an internal error, not a syntax error: re-raise
	end
	if tokens[j].kind ~= "eof" then
		return nil, { msg = ("unexpected '%s' after a complete expression"):format(tokens[j].value), pos = tokens[j].pos }
	end
	return pred ---@cast pred fun(set: table<string, boolean>): boolean
end

-- explain(src, err) renders a compile error with a caret under the offending
-- position, for CLI error messages.
--
---@param src string
---@param err TagExprError
---@return string
function M.explain(src, err)
	-- the caret points into the (single-line) source; clip at a newline so a
	-- multi-line expression can't misalign it
	local shown = src:gsub("[\r\n].*$", "")
	local pos = math.min(err.pos, #shown + 1)
	return ("invalid tag expression: %s\n  %s\n  %s^"):format(err.msg, shown, (" "):rep(pos - 1))
end

return M
