<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Overview

nvme-check is a set of black-box conformance tests for QEMU's emulated NVMe
device (`hw/nvme`). Tests are written in Zig, grouped into test suites, and
can be run against any QEMU build — a release, or a patch under review —
to check the device against the official NVM Express specifications.

## How tests talk to the device

Each test binary runs inside a guest VM where the emulated controller has
been unbound from `nvme.ko` and handed to `vfio-pci`. From there the test
drives the controller itself, through
[libvfn](https://github.com/SamsungDS/libvfn): configuring it, creating
queues, ringing doorbells, decoding completions — with no kernel NVMe driver
in between. What the specification promises is exactly what a test can check,
and exactly what a real consumer relies on.

Nothing in a test is tied to QEMU internals. The device under test is simply
a configured `qemu-system-*` binary (see [Configuration](configuration.md));
pointing the suites at a patched build is a config edit. The surrounding
machinery — building VM images, booting VMs, hot-plugging the controller over QMP,
copying the test binary in and running it — comes from
[makac](https://jwdevantier.github.io/makac/) and its
[QEMU package](https://jwdevantier.github.io/makac.qemu/); their own
documentation ([References](references.md)) covers everything underneath.

```sh
./nvme-check.lua                 # every suite, every architecture
./nvme-check.lua tp4176 -w aer   # one batch
```

## Reading guide

- [Installation](installation.md) → [Configuration](configuration.md) →
  [Pre-flight check](pre-flight.md): get a working setup.
- [User guide](user-guide.md): run and select tests.
- [Architecture](architecture.md): what the components are and how a run flows.
- [Writing tests](writing-tests.md): add a batch or a new suite.
- [Developer notes](developer-notes.md): unit tests, libvfn hacking, building
  this book.
