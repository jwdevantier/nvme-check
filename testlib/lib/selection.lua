-- testlib/lib/selection.lua
-- Pure test selection: which (arch, test) pairs does a run cover?
--
-- A test is a step-spec the harness knows two things about: the harness-owned
-- keys are `name`, `uses`, `tags?`, `archs?` (selection reads only these,
-- never `with`). See tmp-decomplect-vfio-and-tests.md.
--
-- The arch being run, the suite and the test `name` are implicit tags, so
-- --where "s390x", --where "tp4176" and --where "my_test" all select as
-- expected. `where` is a pytest-style boolean expression (lib/tagexpr.lua).

local archlib = require("./arch")
local tagexpr = require("./tagexpr")

---@class TestDef
---@field name string test name, short and descriptive
---@field uses string action id executing the test, e.g. "nvmecheck:libvfn-simple"
---@field suite string suite the test was loaded from (stamped by the runner)
---@field tags? string[] filter tags; e.g. slow tests should be tagged 'slow'
---@field archs? string[] if provided, limit execution to these architectures
---@field with table<string, any> driver-owned payload (plus runner-injected arch/suite/name)

---@class Selection
---@field archs? string[] if provided, only run tests against these architectures
---@field list? boolean if true, enumerate selected tests instead of executing
---@field where? string pytest-style boolean expression (see lib/tagexpr.lua)

local M = {}

---@param t string[]
---@param v string
---@return boolean
local function has(t, v)
  for _, x in ipairs(t) do if x == v then return true end end
  return false
end

---@param test TestDef
---@param arch string
---@return table<string, boolean>
local function tag_set(test, arch)
  local set = { [arch] = true, [test.suite] = true, [test.name] = true }
  for _, t in ipairs(test.tags or {}) do set[t] = true end
  return set
end

-- expand(tests, sel?) -> pairs, skipped
-- pairs: { arch = <arch>, test = <TestDef> }[] in arch-major order, suite/test
-- input order within each arch.
---@param tests TestDef[]
---@param sel? Selection
---@return { arch: string, test: TestDef }[], integer
function M.expand(tests, sel)
  sel = sel or {}
  local arches = sel.archs or archlib.names
  local where_pred = nil
  if sel.where then
    local pred, err = tagexpr.compile(sel.where)
    if not pred then error(tagexpr.explain(sel.where, err), 0) end
    where_pred = pred
  end

  local pairs, skipped = {}, 0
  for _, arch in ipairs(arches) do
    for _, test in ipairs(tests) do
      if has(test.archs or archlib.names, arch)
          and (where_pred == nil or where_pred(tag_set(test, arch))) then
        pairs[#pairs + 1] = { arch = arch, test = test }
      else
        skipped = skipped + 1
      end
    end
  end
  return pairs, skipped
end

return M
