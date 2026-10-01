-- testlib/makac_package.lua
-- The `nvmecheck` makac package: the NVMe test harness. Loaded in place via
-- the filesystem fetcher (makac_project.lua wires it under the alias
-- `nvmecheck`). Modules live in testlib/lib/; workflows reach them as
-- `require("pkgs/nvmecheck/<name>")`, the package itself uses './<name>'.

local zigtest = require("./zigtest")

return {
  -- the harness drives QEMU through the qemu package's actions
  requires = { qemu = "the NVMe test harness boots VMs via qemu:vm/qemu:img; wire the makac.qemu package under the alias 'qemu'" },

  actions = {
    build = zigtest.build,
  },
}
