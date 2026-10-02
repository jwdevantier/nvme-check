-- testlib/lib/base.lua
-- The `nvmecheck:base` action: the free-reign test driver.
--
-- The harness supplies no VM, no build, no guest context — the test's `run`
-- function gets whatever it was defined with and executes steps to its
-- heart's content (raise to FAIL, return to PASS). This is the fall-back for
-- anything the structured drivers don't cover: multi-VM tests (boot several
-- guests with require("pkgs/nvmecheck/guest").boot), qtest-style tests, or
-- plain host-side checks.
--
-- with = {
--   run  = fun(args: { arch: string, suite: string, name: string, args: any }),
--   args = <freeform, driver-owned; handed to run as args.args>,
--   arch/suite/name = <injected by the runner>,
-- }

local M = {}

---@param with table
---@return table
function M.run(with)
  assert(type(with) == "table", "nvmecheck:base: 'with' table is required")
  local fn = assert(with.run, "nvmecheck:base: a 'run' function is required")
  local ok, res = pcall(fn, {
    arch = with.arch,
    suite = with.suite,
    name = with.name,
    args = with.args,
  })
  if not ok then
    return { err = tostring(res) }
  end
  return { changed = true, out = { result = res } }
end

return M
