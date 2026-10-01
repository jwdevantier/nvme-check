# TP4176 (Rate Limiting) tests

Black-box tests for QEMU's TP4176 Rate Limiting emulation, exercised over the
admin queue of a vfio-bound controller. Ported from the Odin suite at
`~/repos/nvme-tests/tp4176/`.

## What it needs

- A controller created with QEMU's **`rate-limit=on`** property, which the
  workflow sets (`nvme.ctrl["rate-limit"] = true`). Without it the feature is
  simply not there and most tests fail.
- A namespace (the workflow gives each batch a fresh 64M raw disk).
- DMA buffers that are page-aligned and a page multiple in length — the
  iommufd backend rejects unaligned `user_va`/`length`. `vfntest.pageBuffer`
  handles this.

## Batches

Each batch is one Zig test binary run against one freshly-resumed VM, so the
controller is only ever touched by tests that share a batch.

| Batch | Program | Covers |
|---|---|---|
| `identify` | `batches/identify.zig` | Identify CNS 06h/CSI 00h: NVM CS version, RLA (HLS/SLS), SLMC |
| `log_page` | `batches/log_page.zig` | Log Page 28h header + descriptor cross-references; Generation Count increments |
| `feature`  | `batches/feature.zig`  | Set/Get Features 28h round-trip + rejections; Async Event Config RLCCN |
| `aer`      | `batches/aer.zig`      | Full AER flow: RLCCN enable → event on config change |

The pure wire model lives in `spec.zig` and is unit-tested on the host
(`zig build test`); the `batches/` programs are the device-facing cases.

## Run

```sh
# host-only spec tests (no device, no makac)
zig build test

# end-to-end (the runner: --where selects, --list lists)
./nvme-check.lua tp4176
./nvme-check.lua tp4176 -w s390x
./nvme-check.lua tp4176 --list
```

The target controller is selected by the harness; the batch programs read the
BDF from `$NVME_BDF` (set by `testlib/lib/batch.lua`).

## Notes

- The Odin suite needed a mutex because its runner was multi-threaded; the Zig
  test runner is single-threaded, so `common.zig` just shares one lazily-opened
  controller per batch.
- The AER batch uses the libvfn request-tracking API directly (`nvme_rq_*`,
  `nvme_cq_*`) rather than `nvme_admin()`, so the wait loop does not drain the
  AER's completion.
