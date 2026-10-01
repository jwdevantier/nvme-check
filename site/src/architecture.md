<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Architecture

This page is the component map for contributors: what exists, how the pieces
relate, and what you touch when adding a test. It follows one batch run —
`./nvme-check.lua tp4176 -w aer` — from runner to result.

## Why the test runs inside the guest, off the kernel driver

The controller under test is handed to `vfio-pci` in a guest VM, which takes
the kernel's NVMe driver out of the path. That gives the test complete
control: it composes any command — valid, edge-case, or deliberately wrong —
and decides exactly when to ring the doorbell. Nothing between the test and
the device interprets, coalesces, or corrects anything.

And because the test runs in a real OS rather than in isolation, there is a
full system around it: verifying effects out of band, with ordinary tools
outside the test binary, is always an option.

Everything else about the design follows from this one decision:

- The guest image has no toolchain, so test programs are **cross-compiled
  statically on the host** and copied in.
- The control plane is **SSH** (plus cloud-init at image-build time).
- QEMU's role is *device provider only*: the harness boots and hot-plugs it,
  but never introspects the device-under-test beyond what the spec defines.

## The components, in order of contact

| Component | What it is | You touch it to |
|---|---|---|
| `nvme-check.lua` | The runner: discovers `tests/*/workflow.lua`, applies `-a`/`-w` selection, runs each suite | Add CLI-level selection features |
| `tests/<suite>/workflow.lua` | The suite's batch registry: for each batch, its program path, NVMe device parameters, tags | Register or retune a batch |
| `testlib/` (package `nvmecheck`) | The VM plumbing on makac + makac.qemu: base-image build (once per arch), snapshot resume (per batch), QMP device hot-plug, vfio-bind, build + scp + run | Change how batches are *executed* |
| `build.zig` + `src/` | Cross-compiles each batch program statically for the guest arch | Add to the shared test library |
| `tests/<suite>/batches/*.zig` | The tests. Ordinary `test {}` blocks, run by zig's test runner inside the guest, reading the controller BDF from `NVME_BDF` | **This is where new tests go** |

Two rules about `src/`:

- `src/vfn` is a thin binding of the libvfn C API; conveniences belong in
  `src/vfntest`.
- Wire formats — encode, decode, expectations — never live in a batch file.
  They live in `src/nvme` (base spec) or the suite's `spec.zig` (see below).

## What a run looks like

The same run, in motion. A run selects (architecture, batch) pairs and
executes each pair in one VM session. For each batch, per architecture:

1. The architecture's live disk is resumed from its base snapshot.
2. An NVMe controller is hot-plugged with the batch's device parameters, backed
   by a fresh raw disk under `.makac/vm-images/`.
3. The controller is bound to `vfio-pci` in the guest.
4. The batch's test binary, cross-compiled statically for the guest
   architecture, is copied in and executed, reading the controller BDF from
   `NVME_BDF`.
5. The VM is shut down with a clean QMP quit.

The slow base-image build happens once per architecture; every batch after
that starts from the same resumed snapshot and a fresh copy of its raw disk.

```
 HOST                                GUEST  (resumed at the baseline snapshot)

 QMP: loadvm                ----->   VM is live in seconds, no boot

 QMP: device_add            ----->   NVMe controller appears on the PCI bus,
 (batch's ctrl params +              backed by a fresh raw disk
  fresh raw disk)

 ssh: bind script           ----->   controller leaves nvme.ko, opens via
                                     /dev/vfio; its BDF becomes NVME_BDF

 zig build (static, guest arch)      (nothing on the guest yet)

 scp batch binary           ----->   /tmp/<batch>

 ssh: NVME_BDF run          ----->   zig test runner drives the controller
                                     through libvfn: queues, doorbells,
                                     CQEs, no kernel NVMe driver in between
                            <-----   stdout, stderr, exit code

 QMP: quit                  ----->   clean shutdown; live-disk writes and the
                                     raw NVMe disk are discarded
```

Note where the arrows cross: only QMP and SSH/scp bridge host and guest, and
the test binary is the only thing that ever touches the device directly.

## Why Zig

Two reasons, in order of importance:

1. **The toolchain and target list.** One `zig build` produces a static musl
   binary for s390x from an amd64 host — the emulated s390x VM, where merely
   resuming a snapshot takes ~25 seconds on a laptop, never compiles a thing.
   No toolchain needs shipping into any guest.
2. **Ergonomics that suit test code.** Allocators that detect leaks and
   use-after-free, `defer`/`errdefer` for teardown — while staying legible
   to a C programmer.

## The amd64/s390x axis exists to catch bugs

The matrix is not about breadth of coverage. NVMe is little-endian on the
wire; running the identical test binary on a little-endian (amd64, KVM) and
a big-endian (s390x, fully emulated) guest flushes out host-endian
assumptions that would otherwise hide until someone ran the test on real
big-endian hardware. This is why `spec.zig` holds all wire conversion:
endian-correctness is localized, testable on the host, and identical across
batches.

The architectures differ in setup, not in what the tests see:

- **amd64**: Q35 + KVM; pre-created PCIe root ports as NVMe hot-plug targets;
  an emulated intel-iommu (no IOMMU group, no vfio-pci binding otherwise).
- **s390x**: `s390-ccw-virtio`, fully emulated; zPCI allocates the function
  and address itself; no IOMMU dance needed.

## The batch is the isolation unit

Every batch runs in a VM resumed fresh from the base snapshot, against a
fresh per-batch raw disk. Resume is cheaper than boot but not free
(s390x: ~25 s), so the batch granularity is a deliberate tradeoff — as a test
writer you decide which tests share a session. Log-page inspections that
cannot disturb each other belong in one batch; a test that might wedge the
controller or scribble its disk does not. Corollary: a batch must neither
depend on, nor worry about, state from any other batch.

## State on disk

Everything generated is local and gitignored:

| Path | Contents |
|---|---|
| `.makac/vm-images/` | Live VM disks (`*-live.qcow2`), per-batch raw NVMe disks, instance-id files |
| `.makac/qemu/img/` | Base image build state and `serial.log` |
| `logs/` | Test run logs |

The base-image snapshot is built once per architecture; every batch starts
from that same resumed snapshot and a fresh copy of its raw disk. The live
disks are large, disposable artifacts — keeping them under the
already-gitignored `.makac/` means `rm -rf .makac` is a complete reset.

## Known wart: the shared wire module is thin

`src/nvme/nvme.zig` is intended to be *the* shared model of the base spec —
same role the `hw/nvme/nvme.h` and `include/block/nvme.h` headers play in
QEMU — with suites adding local structures only when genuinely necessary
(e.g. a TP not yet integrated upstream). Today the module is skeletal and
`tests/tp4176/spec.zig` is carrying structures that belong in it. This should
be fixed before the project is broadly public; when it is, "suite-local
`spec.zig`" shrinks to strictly TP-specific layouts.
