# NVMe 1.4 mandatory-baseline tests

Black-box checks of the **mandatory** NVMe over PCIe 1.4 baseline, driven
through libvfn on a vfio-bound controller. Only mandatory behaviour is
asserted: optional (`O`) commands, features and log pages are out of scope.

The arbiter is the **NVMe Base Specification 1.4(c) text**, consulted through
the local extract at `~/repos/nvme14c_parser/nvme_1.4c_spec_extract.md`
(produced by `~/repos/nvme14c_parser/`, built from the ratified 1.4(c) PDF).
Figure/section numbers cited in source comments and this README are **1.4(c)**
numbers — they differ from the registered `BASE@2.3` document, whose
allowances are not the ones tested here.

## What it needs

- A single controller with a 512-byte-LBA namespace (the workflow declares
  `logical_block_size = 512` and a fresh 64M raw disk).
- DMA buffers that are page-aligned and a whole number of pages long — the
  iommufd backend rejects anything else. `vfntest.pageBuffer` handles this.

## Isolation: one program per concern

The suite is six batch programs, each registered as its own `workflow.lua`
entry. `workflow.lua` entry names are the `:` filter keys
(`./nvme-check.lua nvme14m:inspect -a amd64`). **Each entry is one controller
session** (`common.ctrl()` → libvfn `nvme_init`: reset → admin queue → enable
→ Identify); that session is the isolation mechanism: destructive work
(feature writes, I/O-queue lifecycle, reset, shutdown) cannot contaminate
read-only inspection or the queue-less feature checks.

Within a program, `test {}` blocks run in declaration order. Tests are kept
small and split by concern so that a QEMU non-conformance fails only the
narrowest possible test.

## Batches

### `inspect` — read-only transport, Identify and logs

Shares one session and mutates nothing (its MSI-X tests create and delete a
throwaway I/O queue pair; the log test submits a rejected Format NVM).

- `transport registers and controller enable state`
- `transport one memory BAR and MSI-X capability`
- `transport interrupt masking INTMS INTMC`
- `MSI-X vector setup and command completion`
- `MSI-X interrupt delivery`
- `admin Identify Controller mandatory fields`
- `admin Identify Controller 1.4 fields`
- `admin Identify Namespace mandatory fields`
- `admin Identify Active Namespace ID list`
- `admin Identify Namespace Identification Descriptor list`
- `admin Identify Namespace NSID semantics and NN`
- `admin Get Log Page mandatory IDs and contents`

### `features` — Get/Set Features

Mutates feature values, so it gets its own session and stays queue-less. The
Number-of-Queues test must run before any I/O queue exists.

- `admin Get Features mandatory IDs`
- `admin Set/Get Features reserved FID rejected`
- `admin Set Features mandatory IDs`
- `admin Set Features SEL and feature status codes`
- `admin Set/Get Features Number of Queues`

### `admin_errors` — admin error and asynchronous-event completions

Drives the admin queue directly, so it cannot share with `common.admin()`
users (an outstanding AER completion would be reaped as a spurious completion).

- `admin error completions`
- `admin Async Event Request and Abort`
- `admin Asynchronous Event Request limit`
- `admin asynchronous event delivery`

### `io` — I/O-queue lifecycle and the NVM datapath

All I/O-queue creation lives here, so `features` always sees a queue-less
controller. Declaration order matters: queue setup precedes the datapath.

- `admin Create and Delete IO CQ and SQ`
- `admin Create and Delete IO queue error statuses`
- `io Write Read Flush PRP round-trip`
- `admin Set Features Number of Queues after queue creation`

### `reset` — CC.EN reset/enable state machine

Terminal to its session: clearing `CC.EN` destroys libvfn's cached queues.

- `controller reset / enable state machine`

### `shutdown` — CC.SHN / CSTS.SHST

Terminal to its session; normal and abrupt shutdown each get their own test,
with a Controller Reset between them to resume.

- `controller normal shutdown: CC.SHN / CSTS.SHST`
- `controller abrupt shutdown: CC.SHN / CSTS.SHST`

## Run

```sh
# Host-only spec unit tests (spec.zig; no device, no makac) — always green.
zig build test

# The whole suite (all six batches), architecture pinned to amd64.
./nvme-check.lua nvme14m -a amd64

# One batch, by workflow.lua entry name.
./nvme-check.lua nvme14m:inspect -a amd64

# Acceptance: runs the host tests and all six batches, and exits 0 iff every
# failing Zig test is on the known-QEMU-failure allow-list.
tests/nvme14m/check-expected.sh
```

`check-expected.sh` also accepts `--parse-only FILE` to re-check an already
captured combined log. The harness selects the controller; the batch reads its
BDF from `$NVME_BDF` (default `0000:02:00.0`).

## Known gaps (QEMU is not conformant)

The device under test (QEMU's emulated NVMe controller) is **not** 1.4(c)
conformant and the suite is not required to pass on it. A test that fails
because QEMU does not meet the spec is a feature: the assertion is **not**
weakened; instead the failing Zig test name is recorded, with a 1.4(c)
citation and one-line reason, in
[`known-qemu-failures.txt`](known-qemu-failures.txt).

`check-expected.sh` is the gate: it runs `zig build test` plus every batch and
exits 0 iff **no test fails that is not on the allow-list**. The allow-list
starts empty and grows only as strict checks land. The current entries are the
QEMU non-conformances introduced by this loop — see the file for the
authoritative list. A failure not on the list is a bug in the suite or a new
regression, not a device tolerance.

## Version policy (decision B)

Accept `VS >= 00_01_04_00`: a controller implementing a later revision is also
conformant, so the suite is never pinned to `VS == 0x00010400`. Where 1.4(c)
reserves a field that a later revision defines (for example `CTRATT` bits for
FDPS/FCM/MDS, `OAES` bits 31:15 and 7:0, and `CSTS.ST`), the value is **printed
or surfaced, not failed** — a human can see the “violation” without the suite
rejecting a newer part. Only bits/behaviours 1.4(c) itself defines are
asserted.

## Spec definitions

The pure spec data and command builders (register offsets, opcodes, Identify
CNS, feature selectors, status codes) live in `spec.zig`; they make no device
or libvfn calls and are unit-tested on the host by `zig build test`.
