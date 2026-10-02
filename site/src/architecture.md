<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Architecture

nvme-check organizes tests into **test suites**: any child directory of
`tests/` containing a `workflow.lua` is a suite.

A suite describes one or more tests to run and defines the **driver** suited
to run them (set on the suite, overridable per test). A driver is a [makac
action](https://jwdevantier.github.io/makac/concepts/actions.html): it
receives the test's data and does the work required to actually run the test.
Two drivers ship with nvme-check:

- [`base`](drivers/base.md), where you define the function that runs the
  test;
- [`libvfn-simple`](drivers/libvfn-simple.md), which boots an
  architecture-appropriate VM, hot-plugs the declared NVMe device(s),
  compiles the program described by the test, copies it in over SCP and runs
  it.

The `nvme-check.lua` script itself auto-discovers test suites and can
enumerate or run tests — and provides a PyTest-inspired [tag filtering
language](user-guide.md#selecting-tests) to run only a subset of tests based
on how they are tagged.

## Major components

| Component | What it is |
|---|---|
| `nvme-check.lua` | The test runner; discovers test suites (`tests/*/workflow.lua`), collects tests, filters tests based on provided query arguments and executes (or lists, in case of `--list`) what matched |
| `tests/<suite>/workflow.lua` | Describes the tests to run; each test may individually specify the driver to use (`uses`) and provides the test data (`with`) to the driver |
| `testlib/lib/selection.lua` | The filtering; turns the collected tests plus the query arguments into the list of (architecture, test) pairs to execute or list |
| `testlib/lib/libvfn_simple.lua` | The `libvfn-simple` driver; boots the architecture's VM from its snapshot, hot-plugs and binds the declared NVMe devices, builds the test, copies it in, runs it — the exit code is the verdict |
| `testlib/lib/base.lua` | The `base` driver; calls the test's `run` function — a raise is a FAIL, anything else a PASS |
| `testlib/lib/arch.lua`, `guest.lua`, `nvme.lua`, `images.lua` | The VM machinery; architecture definitions, base-image builds, `guest.boot`, QMP device hot-plug and vfio-bind |
| `build.zig` + `src/` | The build setup and shared test library; compiles each test program statically for the guest architecture.<br><br>• `src/vfn` binds the libvfn C API (conveniences belong in `src/vfntest`);<br>• `src/nvme` defines the NVMe spec structures and constants — the closest equivalent to QEMU's `include/block/nvme.h`.<br><br>Suites keep vendor-specific deviations and definitions internally |
| `tests/<suite>/batches/*.zig` | The test programs themselves; `test {}` blocks run by zig's test runner inside the guest against the controller at `$NVME_BDF` |

## Architectures

Tests run on amd64 (KVM) and s390x (fully emulated): little- and big-endian
guests executing the same test binaries. NVMe structures are little-endian,
so the point of the second architecture is flushing out host-endian
assumptions — which is why all byte-order conversion is localized in
`src/nvme/spec.zig`, host-testable and identical for every batch.

## State on disk

Everything generated is local and gitignored:

| Path | Contents |
|---|---|
| `.makac/vm-images/` | Live VM disks (`*-live.qcow2`), per-batch raw NVMe disks, instance-id files |
| `.makac/qemu/img/` | Base image build state and `serial.log` |
| `logs/` | Test run logs |

Base images are built once per architecture. The live disks are large,
disposable artifacts — keeping them under the already-gitignored `.makac/`
means `rm -rf .makac` is a complete reset.
