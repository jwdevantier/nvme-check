-- testlib/lib/selection.lua
-- Pure test selection: which concrete test cases does a run cover?
--
-- Selection receives the concrete cases that collection has already expanded
-- from test declarations (lib/params.lua); it never looks at `params`, `with`
-- or `uses`. See spec-test-parametrization.md.
--
-- The suite, the base test name and the concrete case label are implicit tags,
-- so --where "tp4176", --where "my_test" and --where "inspect[arch=s390x]" all
-- select as expected, next to the ordinary tags a test declares. `where` is a
-- pytest-style boolean expression (lib/tagexpr.lua); matching is exact.

local tagexpr = require("./tagexpr")

---@class Case
---@field name string the test's base name
---@field label string the concrete name, e.g. "inspect[arch=amd64,dev=vnvme]"
---@field params table<string, string> this case's parameters ({} if unparameterized)
---@field tags string[] declared tags, then parameter tags
---@field uses string action id executing the case, e.g. "nvmecheck:qemu-vfio"
---@field suite string suite the case was loaded from
---@field with table<string, any> driver-owned payload

---@class Selection
---@field list? boolean if true, enumerate selected cases instead of executing
---@field where? string pytest-style boolean expression (see lib/tagexpr.lua)

local M = {}

---@param c Case
---@return table<string, boolean>
local function tag_set(c)
  local set = { [c.suite] = true, [c.name] = true, [c.label] = true }
  for _, t in ipairs(c.tags or {}) do set[t] = true end
  return set
end

-- expand(cases, sel?) -> selected, skipped
-- selected: Case[] in input order; skipped counts the cases the tag expression
-- filtered out.
---@param cases Case[]
---@param sel? Selection
---@return Case[], integer
function M.expand(cases, sel)
  sel = sel or {}
  local where_pred = nil
  if sel.where then
    local pred, err = tagexpr.compile(sel.where)
    if not pred then error(tagexpr.explain(sel.where, err), 0) end
    where_pred = pred
  end

  local selected, skipped = {}, 0
  for _, c in ipairs(cases) do
    if where_pred == nil or where_pred(tag_set(c)) then
      selected[#selected + 1] = c
    else
      skipped = skipped + 1
    end
  end
  return selected, skipped
end

return M
