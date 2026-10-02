-- testlib/makac_package.lua
-- The `nvmecheck` makac package: the NVMe test harness. Loaded in place via
-- the filesystem fetcher (makac_project.lua wires it under the alias
-- `nvmecheck`). Modules live in testlib/lib/; workflows reach them as
-- `require("pkgs/nvmecheck/<name>")`, the package itself uses './<name>'.

local zigtest = require("./zigtest")
local base = require("./base")
local libvfn_simple = require("./libvfn_simple")

return {
  -- the harness drives QEMU through the qemu package's actions
  requires = { qemu = "the NVMe test harness boots VMs via qemu:vm/qemu:img; wire the makac.qemu package under the alias 'qemu'" },

  actions = {
    build = zigtest.build,
    -- test drivers: a test is a step-spec with harness-known keys
    -- (name/uses/tags/archs); these are the stock `uses` values. See
    -- tmp-decomplect-vfio-and-tests.md.
    base = base.run,
    ["libvfn-simple"] = libvfn_simple.run,
  },
}
