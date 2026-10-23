-- testlib/lib/params.lua
-- Pure parameter expansion: turn a test declaration into concrete test cases.
--
-- A test may declare `params` as an array of { key = value } tables; each entry
-- becomes one concrete case, labelled `name[k=v,...]` (keys sorted, values
-- verbatim). Each parameter contributes a `k=v` tag, after the declared tags.
-- No params means exactly one unparameterized case. Parameter keys are opaque
-- here: this module only formats and validates them, never interprets them.
-- See spec-test-parametrization.md.

---@class TestDef -- as loaded from a suite declaration (plus `suite`)
---@field name string
---@field uses string
---@field suite string
---@field tags? string[]
---@field params? table<string, string>[]
---@field with table

---@class Case -- one concrete test case, produced by expansion
---@field name string -- the test's base name
---@field label string -- "inspect[arch=amd64,dev=vnvme]" or just "inspect"
---@field params table<string, string> -- copy of the entry; {} when unparameterized
---@field tags string[] -- declaration tags, then parameter tags, deduplicated
---@field uses string
---@field suite string
---@field with table

local M = {}

---@param name string
---@param params? table<string, string>
---@return string
function M.label(name, params)
  if params == nil or next(params) == nil then return name end
  local keys = {}
  for k in pairs(params) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. params[k] end
  return name .. "[" .. table.concat(parts, ",") .. "]"
end

---@param prefix string
---@param fmt string
---@return string
local function fail(prefix, fmt, ...)
  error(prefix .. fmt:format(...), 0)
end

---@param test TestDef
---@param prefix string
---@return string[]|nil
local function validate(test, prefix)
  if type(test.with) == "table" and test.with.params ~= nil then
    fail(prefix, "'with.params' is runner-owned; declare a top-level 'params' array")
  end
  local params = test.params
  if params == nil then return nil end
  if type(params) ~= "table" or #params == 0 then
    fail(prefix, "'params', if present, must be a non-empty array of tables")
  end
  for i, entry in ipairs(params) do
    if type(entry) ~= "table" then
      fail(prefix, "params[%d] must be a table", i)
    elseif next(entry) == nil then
      fail(prefix, "params[%d] is empty", i)
    end
    for k, v in pairs(entry) do
      if type(k) ~= "string" then
        fail(prefix, "params[%d]: key %q must be a string", i, k)
      elseif type(v) ~= "string" then
        fail(prefix, "params[%d]: value of %q must be a string, got %s", i, k, type(v))
      end
    end
  end
  return params
end

---@param test TestDef
---@param params table<string, string>
---@return Case
local function mkcase(test, params)
  local tags, seen = {}, {}
  local function add(t)
    if not seen[t] then
      seen[t] = true
      tags[#tags + 1] = t
    end
  end
  for _, t in ipairs(test.tags or {}) do add(t) end
  local keys = {}
  for k in pairs(params) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do add(k .. "=" .. params[k]) end
  return {
    name = test.name,
    label = M.label(test.name, params),
    params = params,
    tags = tags,
    uses = test.uses,
    suite = test.suite,
    with = test.with,
  }
end

---@param test TestDef
---@return Case[]
function M.expand(test)
  local prefix = ("%s: test '%s': "):format(test.suite, test.name)
  local params = validate(test, prefix)
  if params == nil then
    return { mkcase(test, {}) }
  end
  local cases = {}
  for _, entry in ipairs(params) do
    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    cases[#cases + 1] = mkcase(test, copy)
  end
  return cases
end

---@param tests TestDef[]
---@return Case[]
function M.expand_all(tests)
  local cases = {}
  for _, test in ipairs(tests) do
    for _, case in ipairs(M.expand(test)) do
      cases[#cases + 1] = case
    end
  end
  return cases
end

return M
