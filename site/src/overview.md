<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Overview

nvme-check is a test setup for QEMU's emulated NVMe device (`hw/nvme`): its
immediate purpose is checking that the device behaves as the official NVM
Express specifications require — against any QEMU build, including one
carrying a patch under review.

There are two parts to that, and the second may be useful well beyond NVMe:

1. **A test runner**, `./nvme-check.lua`. It auto-discovers suites under
   `tests/`, loads each suite's declared tests, and can enumerate, filter and
   execute them. Filtering is a pytest-inspired tag expression
   (`-w "fast and not slow"`); a test's name, its suite and the architecture
   are implicit tags.

2. **VM test infrastructure.** Per-architecture base images are customized
   with cloud-init, built once and snapshotted; a test then resumes a running
   VM from saved state in seconds rather than booting. On top of that: device
   hot-plug over QMP, binding a device to vfio-pci, SSH/SCP control of the
   guest — and the same cross-compiled test binary runs on both amd64 and
   s390x.

How a test actually runs is the job of a *driver* — a makac action named by
the test's `uses` field (see [Test drivers](drivers.md)). The stock
[`libvfn-simple`](drivers/libvfn-simple.md) driver uses the VM infrastructure
for black-box device tests: the controller is handed to `vfio-pci`, and a
test binary drives it directly over
[libvfn](https://github.com/SamsungDS/libvfn) — queues, doorbells, CQEs, no
kernel NVMe driver in between. That is the path the current NVMe catalogue
(TP4176 and friends) takes, and nothing ties a test to it: the
[`base`](drivers/base.md) driver runs an arbitrary function, so the catalogue
can just as well hold QEMU's linter scripts, its existing NVMe qtest, or
anything else deserving a regression check.

```sh
./nvme-check.lua                 # every suite, every architecture
./nvme-check.lua tp4176:aer      # one test
./nvme-check.lua --list          # enumerate, run nothing
```

## Reading guide

- [Installation](installation.md) → [Configuration](configuration.md) →
  [Pre-flight check](pre-flight.md): get a working setup.
- [User guide](user-guide.md): run and select tests.
- [Architecture](architecture.md): what the components are and how they relate.
- [Writing tests](writing-tests.md): add a test or a suite;
  [Test drivers](drivers.md): what `uses` names, the driver contract, writing
  your own.
- [Developer notes](developer-notes.md): unit tests, libvfn hacking, building
  this book.
