<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# The `base` driver

`uses = "nvmecheck:base"`. The base driver runs a Lua function of your
choosing and imposes no workflow by design: the harness contributes selection
and the pass/fail convention, the rest is the `run` function's business. It
is for one-off tests that still belong in the catalogue — a lint pass over
the QEMU code, self-tests and lint checks, running QEMU's existing NVMe
qtest or something entirely different.

## `with` shape

| Key | Type | Meaning |
|---|---|---|
| `run` | `fun(args)` (required) | the test itself; raise to FAIL, return to PASS |
| `args` | any | freeform payload handed to `run` as `args.args` |

`run` receives one table: `params`, `case`, `suite` and `name` (set by the
runner [before the driver is called](../drivers.md#the-contract)), plus the
test's own `args` from `with`.

## Example: reimplementing the vfio test flow

The pieces the stock drivers are built from are usable directly — enough to
rebuild the whole vfio flow in a test body (`qemu-vfio` is essentially
this plus its `pre_test`/`post_test` hooks):

```lua
{ name = "diy-identify", uses = "nvmecheck:base",
  with = {
    run = function(args)
      local guest = require("pkgs/nvmecheck/guest")
      local join  = require("path").join

      -- machine up: ensure image, spawn, loadvm baseline snapshot, ssh up
      local ctx = guest.boot(args.params.arch)

      -- device: fresh drive, QMP-hotplug the controller, hand it to vfio.
      -- add_nvme() returns the QMP replies; the BDF comes from bind_vfio(),
      -- which takes the *kernel's* controller name (nvme0, nvme1, ...).
      local disk = ctx.raw("diy-identify", "64M")  -- cached image, fresh copy per run
      ctx.add_nvme { drive = disk, ctrl = { serial = "deadbeef", msi = false } }
      local bdf = ctx.bind_vfio("nvme0")

      -- compile for the guest (static musl test binary)
      local bin = step {
        uses = "nvmecheck:build",
        with = { arch = args.params.arch,
                 program = join("tests", args.suite, "programs/identify.zig") },
      }.out.path

      -- ship + run + observe (env is prefixed onto the command: ctx.sh is sh -c)
      ctx.put(bin, "/tmp/x")
      local res = ctx.sh(("NVME_BDF=%s /tmp/x"):format(bdf))

      ctx.down()
      if res.code ~= 0 then error(res.stderr) end
    end,
  } }
```

`guest.boot(arch, extra?)` resumes the arch's baseline VM and returns the
guest context (`sh`, `put`, `add_nvme`, `bind_vfio`, `down`, ...): see
[Architecture](../architecture.md) for the components underneath.
