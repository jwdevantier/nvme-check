<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Architecture

The project has two halves with a deliberate gap between them: the Zig side
knows NVMe, the Lua side knows QEMU, and neither reaches across.

```
┌────────────── host ──────────────────────────────────────────────┐
│  makac  ──runs──▶ tests/<suite>/workflow.lua (testlib: nvmecheck)│
│      │                    │                                      │
│      │                    ▼                                      │
│      │            qemu:vm / qemu:img / qemu:qmp  (makac.qemu)    │
│      │                    │                                      │
│      ▼                    ▼                                      │
│  build.zig ──▶ static test binaries ──scp──▶ ┌── QEMU guest ──┐  │
│  (libvfn + spec + batches)                   │ vfio-pci bound │  │
│                                              │ NVMe ctrl      │  │
│                                              │ ◀── libvfn ── test│
│                                              └────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

## Ownership split

| Layer | Owns | Knows about |
|---|---|---|
| Zig `src/vfn/` | Talking to libvfn | The libvfn C API, nothing else |
| Zig `src/vfntest/` | Idiomatic test conveniences | `src/vfn/` |
| Zig `tests/<suite>/spec.zig` | The suite's wire formats and expectations | The NVMe spec only |
| Zig `tests/<suite>/batches/*.zig` | Device test cases (`test {}` blocks) | libvfn and `spec.zig` |
| Lua `tests/<suite>/workflow.lua` | Batch list, device parameters, hooks | makac, QEMU |
| Lua `testlib/` (package `nvmecheck`) | Generic VM harness, arch matrix, selection | makac, makac.qemu |

### Thin bindings, opportunistic test support

`src/vfn/` stays close to the upstream C API: a direct, predictable mapping
rather than an opinionated wrapper. Conveniences belong in the separate
`vfntest` layer, extracted if- and as common patterns emerge.

### spec.zig is pure

`spec.zig` models the suite on the wire: structures libvfn does not already
declare, encoders and decoders, and expectation predicates, plus `test {}`
blocks over synthetic buffers. Its tests run on the host with `zig build test`,
as do the modules under `src/`. NVMe is little-endian on the wire; the little-endian conversions
living here are what make the same test code correct on big-endian s390x.

## The architecture matrix

`testlib/lib/arch.lua` holds one spec per architecture (currently `amd64` and
`s390x`): machine type, CPU, boot and network devices, NVMe attach point, SSH
port, image name, and the base cloud image URL and SHA-256. The QEMU binary
comes from the per-machine [configuration](configuration.md).

The differences that matter:

- **amd64** boots Q35 with KVM and pre-created PCIe root ports (the NVMe
  hot-plug targets), and needs an emulated **intel-iommu** so the guest can
  bind devices to vfio-pci at all.
- **s390x** boots `s390-ccw-virtio` fully emulated. zPCI means QEMU allocates
  the function and address itself, and no IOMMU dance is needed.

## State on disk

Everything generated is local and gitignored:

| Path | Contents |
|---|---|
| `.makac/vm-images/` | Live VM disks (`*-live.qcow2`), per-batch raw NVMe disks, instance-id files |
| `.makac/qemu/img/` | Base image build state and `serial.log` |
| `logs/` | Test run logs |

The base-image snapshot is seeded once per architecture; each batch then runs
against a freshly resumed VM with a fresh copy of its raw disk, so batches
cannot pollute each other.

### Why live disks under `.makac/`?

They are large (400+ MB), disposable build artifacts, not source. Keeping them
under the already-gitignored `.makac/` root means a fresh clone needs no extra
ignore rules and `rm -rf .makac` is a complete reset.
