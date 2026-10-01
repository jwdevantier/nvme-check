<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Overview

nvme-check is a suite of **black-box conformance tests for QEMU's emulated
NVMe device** (`hw/nvme`). It exists to make it easy to express, extend and
run tests that answer one question: *does this QEMU build's NVMe controller
behave the way the official NVM Express specifications say it must?*

The motivation is practical. `hw/nvme` is actively developed — new features
and reworks land routinely, and patches need review. "Looks correct" is hard
to establish from reading a diff, and QEMU's own test coverage for the device
exercises only a fraction of the specification's observable surface. This
project closes that gap from the outside: the suites here form a
**regression-check suite** you can run against any QEMU build — a release, a
topic branch, a patch under review — to confirm the device still conforms.

## Black-box, via libvfn

The tests know nothing about QEMU internals. They see what a real driver
sees: a PCI function with NVMe register space behind it. Each test binary
runs *inside* a guest VM where the emulated controller has been unbound from
`nvme.ko` and handed to `vfio-pci`, then drives the device directly through
[libvfn](https://github.com/SamsungDS/libvfn) — configuring the controller,
creating queues, ringing doorbells, decoding CQEs — with no kernel NVMe
driver in between. Whatever the spec promises on the wire is exactly what the tests can
assert on, and exactly what would break a real consumer if QEMU got it wrong.

Because the tests are black-box, nothing in them is tied to a specific QEMU
source tree or build system. [Configuration](configuration.md) points the
harness at whatever `qemu-system-*` binaries you want tested; swapping in a
patched build is a config edit.

## How it is organized

- Tests are grouped into **suites** under `tests/`, one per NVMe Technical
  Proposal or feature (currently TP4176, Rate Limiting). A suite pairs a pure
  wire-format model (`spec.zig`, unit-tested on the host) with one or more
  **batches** of device test cases written in Zig.
- Each **batch** runs in its own fresh VM session: the emulated controller is
  hot-plugged with the device parameters the batch declares, bound to
  vfio-pci, and driven by a statically compiled test binary.
- Every batch runs on **amd64 and s390x** — the little-endian/big-endian
  spread is deliberate, and has already flushed out wire-conversion bugs.

The surrounding machinery — cross-compiling the test binaries, building and
snapshotting guest base images, hot-plugging devices over QMP, ferrying
binaries in over SSH — is handled by [makac](https://jwdevantier.github.io/makac/)
and its [QEMU package](https://jwdevantier.github.io/makac.qemu/). This book
documents what nvme-check adds on top; the [References](references.md) page
points to those projects' own documentation for everything underneath.

```sh
./nvme-check.lua            # every suite, every architecture
./nvme-check.lua tp4176 -w aer   # one batch
```

## Reading guide

- [Installation](installation.md) → [Configuration](configuration.md) →
  [Pre-flight check](pre-flight.md): get a working setup.
- [User guide](user-guide.md): run and select tests.
- [Architecture](architecture.md): how the Zig and Lua halves are split, and why.
- [Writing tests](writing-tests.md): add a batch or a new suite.
- [Developer notes](developer-notes.md): test layers, libvfn hacking, building
  this book.

## Current state

The harness and its two-architecture matrix are the mature part; the suite
catalogue is thin. TP4176 is the first suite and the template for the rest —
adding coverage for more TPs and base-spec behaviour is the ongoing work. If
you want to review an `hw/nvme` patch's spec conformance, or pin down
behaviour before it regresses, [Writing tests](writing-tests.md) is where to
start.
