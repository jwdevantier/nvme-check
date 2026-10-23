<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Test drivers

A test declares *what* should run. A **driver** decides *how* it runs.

Concretely, a driver is a makac action, and a test's `uses` field names it:

```lua
-- tests/<suite>/workflow.lua
return {
  uses = "nvmecheck:qemu-vfio",   -- driver for every test in the suite
  tests = {
    { name = "identify",              -- runs under the suite's driver
      tags = { "tp4176" },
      with = { program = "batches/identify.zig", nvme = { ... } } },

    { name = "smoke", uses = "nvmecheck:base",   -- per-test override
      with = { run = function(args) ... end } },
  },
}
```

`uses` must be set by the test or by the suite (a test's own value
overrides its suite's). There is no harness-level default: a test with
neither is a load-time error.

## The contract

The harness — `nvme-check.lua` plus `testlib/lib/selection.lua` — knows
exactly four things about a test: `name`, `uses`, `tags`, `params`. That is
all selection ever sees, and all listing ever prints.

Everything else lives in `with`, which is **driver-owned**: the harness never
reads it, with one documented exception — before invoking the driver, the
runner sets these four fields:

| Injected key | Value |
|---|---|
| `with.params` | the test-case's parameter table, e.g. `{ arch = "s390x" }` |
| `with.suite` | the suite the test was declared in |
| `with.name` | the test's base name |
| `with.case` | the test-case name, e.g. `inspect[arch=s390x]` |

`with.params` is a copy: a driver may read it but cannot alter the test-case. A
driver that needs a parameter (the stock VM drivers need `params.arch`)
asserts its presence itself — the runner does not interpret parameter keys.

Pass/fail follows makac's action convention: the driver raises or returns
`{ err = ... }` to FAIL; anything else is a PASS. `out` may carry whatever
the driver wants reported (exit code, stdout, ...).

## The stock drivers

- [The `qemu-vfio` driver](drivers/qemu-vfio.md) — one VM per test-case, one
  test binary, exit code: boot the baseline, wire the declared NVMe devices,
  build + ship + run.
- [The `qtest` driver](drivers/qtest.md) — a host-native program spawning
  `-accel qtest` QEMU and driving it over the qtest protocol; no VM.
- [The `base` driver](drivers/base.md) — free reign: the harness supplies
  nothing, the test's `run` function does everything (multi-VM, VM-less,
  experiments).

Drivers are registered like any other action, in
`testlib/makac_package.lua` — and nothing is special about the stock ones:
a driver from another package works untouched (`uses = "my-pkg:my-driver"`).

## Writing your own driver

A driver is a function `run(with) -> StepResult`, registered as an action.
The minimal skeleton:

```lua
local M = {}
function M.run(with)
  local params = assert(with.params, "params are runner-injected")
  local ok, err = pcall(function()
    -- ... do the thing ...
  end)
  if not ok then return { err = tostring(err) } end
  return { changed = true, out = {} }
end
return M
```

Test actions are deliberately non-idempotent — they always run and return
`changed = true`. (Makac's action idiom leans convergent-infra; nothing in
`step` requires it. Caching, where it exists at all, lives inside individual
actions like `qemu:img`, not in dispatch.)
