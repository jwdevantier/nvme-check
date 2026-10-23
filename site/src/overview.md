<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Overview

**In short:** nvme-check provides a full-featured test runner, enables it to
handle complex test setup/teardown through [test drivers](drivers.md), all to
compress complex test workflows down to a single command.

nvme-check discovers and filters tests, expands parameterized tests into
concrete test-cases, and its [test drivers](drivers.md) do whatever needs
doing before the test runs: (re)build a VM image, boot and snapshot a guest,
cross-compile the test program, bind device(s) to VFIO — and so on.

nvme-check knows nothing about NVMe, VFIO or qtest — it is specialized entirely
through the driver used. Implement a different driver and it can drive a fuzzer,
a linter or tests of the NVMe kernel drivers in Linux or FreeBSD. It is the
drivers that specialize it for QEMU's `hw/nvme` device.

## Tests and test-cases
Every test, whether `qtest`, `qemu-vfio`, or a driver you add yourself, is
defined, listed and selected the same way.
A suite holds tests, and a test *may* be parameterized, producing a test-case
per set of parameters. The test-case is the unit that is listed, filtered and
run.
Tag a test and `--where <query>` filters on the tag; parameterize the test and
each parameter becomes a `<param>=<value>` tag you can filter on the same way.
Parameterization is how you declare which architecture(s) and device(s) a test
runs against, and tags group tests — even across test suites and types — for
easy selection.

```sh
./nvme-check.lua                           # every suite, every test-case (24)
./nvme-check.lua tp4176:aer                # one test: both of its test-cases
./nvme-check.lua 'tp4176:aer[arch=s390x]'  # one test-case
./nvme-check.lua --list -w 'arch=s390x'    # what would run: 10 of 24
```

See [selecting test-cases](user-guide.md#selecting-test-cases) for the query
language, and remember: `--list` shows what a query selects without running
anything.

## Test drivers
[`qtest`](drivers/qtest.md) test-cases run on the host: the driver checks the
test-case's parameters, compiles the program and runs it; the program starts
QEMU with `-accel qtest` and talks to it over a socket. White-box,
device-specific, fast.

[`qemu-vfio`](drivers/qemu-vfio.md) test-cases run inside a Linux guest,
talking directly to the device over vfio-pci. nvme-check builds the VM image
once with cloud-init (rebuilt only when its inputs change), boots the guest
and snapshots it, so a test-case starts from saved state instead of a boot.
The declared NVMe devices are hot-plugged over QMP per test-case: clean state,
and every test specifies the device(s) and their parameters.

[`base`](drivers/base.md) is perfect for one-off tests. It does nothing except
run the Lua function you define. That function gets imperative tools — the
[Lua standard library](https://www.lua.org/manual/5.4/#index) and the expanded
[Makac Lua API](https://jwdevantier.github.io/makac/lua-api/makac-api.html) —
plus the high-level, declarative VM and image actions of
[makac.qemu](https://jwdevantier.github.io/makac.qemu/reference/index.html).

## Extensible
A new [driver](drivers.md) wraps the orchestration around a different kind of
test: boot a Linux or FreeBSD guest and exercise its kernel NVMe driver, or
run a fuzzer through the same discovery, tagging and reporting.

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
