<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# The `libvfn-simple` driver

`uses = "nvmecheck:libvfn-simple"`. For each (arch, test) pair it resumes the
arch's baseline VM, wires the declared NVMe devices, builds the test binary
for the guest architecture, copies it into the guest, runs it, and takes the
exit code as the verdict.

The test runs inside the guest with the controller bound to `vfio-pci` —
unbound from `nvme.ko`, no kernel NVMe driver in the path. The test binary
talks to the device directly: composing commands, ringing doorbells, decoding
completions.

## What a run looks like

For one test, per architecture:

1. The architecture's live disk is resumed from its base snapshot
   (`guest.boot`).
2. An NVMe controller is hot-plugged with the declared device parameters,
   backed by a fresh raw disk under `.makac/vm-images/`.
3. The controller is bound to `vfio-pci` in the guest.
4. The test binary, cross-compiled statically for the guest architecture, is
   copied in and executed, reading the controller BDF from `NVME_BDF`.
5. The VM is shut down with a clean QMP quit (`ctx.down()`).

The first run per architecture is slow: it downloads a cloud-init-enabled
base image and boots it once to apply one-time customization, then snapshots
the running VM. Every test after that resumes from that snapshot — an
accelerated VM resumes in seconds — and gets a fresh copy of its raw disk.

To follow the image build while it runs, set `MAKAC_IMG_VERBOSE=1` or tail
the serial log:

```sh
tail -f .makac/qemu/img/<image>/serial.log
```

```
 HOST                                GUEST  (resumed at the baseline snapshot)

 QMP: loadvm                ----->   VM is live in seconds, no boot

 QMP: device_add            ----->   NVMe controller appears on the PCI bus,
 (declared ctrl params +             backed by a fresh raw disk
  fresh raw disk)

 ssh: bind script           ----->   controller leaves nvme.ko, opens via
                                     /dev/vfio; its BDF becomes NVME_BDF

 zig build (static, guest arch)      (nothing on the guest yet)

 scp test binary            ----->   /tmp/<test>

 ssh: NVME_BDF run          ----->   zig test runner drives the controller
                                     through libvfn: queues, doorbells,
                                     CQEs, no kernel NVMe driver in between
                            <-----   stdout, stderr, exit code

 QMP: quit                  ----->   clean shutdown; live-disk writes and the
                                     raw NVMe disk are discarded
```

Note where the arrows cross: only QMP and SSH/scp bridge host and guest, and
the test binary is the only thing that ever touches the device directly.

Test programs are written in Zig, built with `zig build`. The deciding factor
is the toolchain: one command cross-compiles a static musl binary for
whichever architecture the guest runs — so guests (including the fully
emulated s390x one) never compile anything. The driver is indifferent to the
language; a statically linked C binary would work the same way.

## `with` shape

| Key | Type | Meaning |
|---|---|---|
| `program` | string (required) | Zig test root, relative to `tests/<suite>/` |
| `nvme` | spec, spec[], or `fun(ctx, with): string[]` | device setup (see below) |
| `pre_test` | `fun(ctx, with)` | after devices are added and bound, before the program runs |
| `post_test` | `fun(ctx, with, result)` | always runs (finally), even on failure — collect artifacts, clean up |

`nvme` is declarative: a single cluster spec
(`{ drive = "64M", ctrl = { ... } }`), a list of them (multi-controller
tests), or a function that adds/binds its own devices via `ctx` and returns
the BDFs. A bare size in `drive` resolves to a fresh per-run raw disk at
device-add time.

## Writing test programs

A batch's `program` is an ordinary Zig test root under
`tests/<suite>/batches/`; its `test {}` blocks run in the guest against the
controller. The driver sets the `NVME_BDF` environment variable to the PCI
BDF of the freshly-bound controller inside the guest, and the test binary
reads it to find its device. Never set it yourself:

```zig
const common = @import("common");

test "identify shows feature support" {
    const ctrl = try common.ctrl();  -- opens the controller from NVME_BDF
    -- build a command, submit, assert on the decoded CQE ...
}
```

A suite may have as many batches as it needs — each test entry points at its
own program. Nothing scans `batches/`; a program file that no entry names
never builds or runs.

If batches need shared code — opening the controller from `NVME_BDF`, common
teardown — put it in a `common.zig` in the suite directory: `build.zig` then
exposes it to every batch as the `common` import (only if the file exists),
and `common.zig` re-exports further suite files as needed, e.g.
`pub const spec = @import("spec.zig");`.

Where definitions live:

- Structures, constants and decoders that belong to the NVMe spec at large
  belong in `src/nvme` — shared by all suites, host-testable on both
  architectures. (See [Architecture](../architecture.md#major-components).)
- Non-standard or vendor-specific material — OCP commands, suite-specific
  helpers — stays in code local to the suite.

The only build configuration a suite can need: if its `spec.zig` has
host-side unit tests, add it to `test_roots` in `build.zig`. Batch programs
themselves are self-contained and referenced by path from the workflow.

## Example

A typical declaration (from `tests/tp4176/workflow.lua`):

```lua
{ name = "feature", tags = { "tp4176", "fast" },
  with = {
    program = "batches/feature.zig",
    nvme = { drive = "64M",
             ctrl = { serial = "deadbeef", msi = false, iocqes = 32, iosqes = 64 } },
  } }
```

## Batches

In this driver, what the harness calls a test is executed as a **batch**: one
program, its NVMe device(s), one VM session — from fresh snapshot to clean
shutdown.

The batch is the isolation unit: every batch runs in a VM resumed fresh from
the base snapshot, against a fresh per-batch raw disk. Resume is cheaper than
boot but not free (s390x: ~25 s), so the granularity is a tradeoff the test
writer makes — tests that cannot disturb each other (log-page inspections)
belong in one batch; a test that might wedge the controller or scribble its
disk does not. A batch must neither depend on, nor worry about, state from
any other batch.
