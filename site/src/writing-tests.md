<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Writing tests

## Vocabulary

- **Suite** — a directory under `tests/` **containing a `workflow.lua`**, for
  example `tests/tp4176/`. The organising unit: one suite's spec model, its
  test programs, and its workflow. In this repository each suite happens to
  test one NVMe Technical Proposal (TP), which is where the `tp4176` naming
  comes from. The runner discovers suites by that file: a `tests/<dir>/`
  without a `workflow.lua` is skipped, silently.
- **Batch** — one Zig test binary plus the NVMe device parameters it runs
  against, executed in one fresh VM session. A batch exists only as an entry
  in the suite workflow's `batches` table — nothing scans the `batches/`
  directory, so a program file that no entry names is dead code.
- **Program** — a Zig test root (one file under `tests/<suite>/batches/`) that
  compiles into one test binary.

## Adding a batch to an existing suite

### 1. Write the test program

Create `tests/<suite>/batches/<name>.zig`. It is an ordinary Zig test root; its
`test {}` blocks run in the guest against the bound controller. The controller
BDF arrives via the `NVME_BDF` environment variable, and `common.zig` in the
suite directory holds the shared setup (opening the controller via libvfn, and
so on).

```zig
// tests/tp4176/batches/example.zig
const common = @import("common");
const spec = @import("common").spec;

test "rate limit: identify shows support" {
    _ = try common.ctrl(); // opens the controller from NVME_BDF
    // build a command with spec.*, submit via common.admin(),
    // assert on the decoded CQE ...
}
```

`common` is a module import wired by `build.zig` (only when
`tests/<suite>/common.zig` exists — see below); the suite's spec
definitions, `spec.zig`, are an ordinary file re-exported from it as
`common.spec`, with no `build.zig` involvement.

Spec structures, decoders and expectations belong in `spec.zig`, not in the
batch. If you find yourself defining a structure layout or an encoder in a
batch file, move it.

### 2. Register the batch in the workflow

Add an entry to the `batches` table in `tests/<suite>/workflow.lua`:

```lua
{ name = "example", program = "batches/example.zig", nvme = nvme(), tags = { "tp4176" } },
```

- `name` and the architecture name are implicit selection tags, so
  `--where "example"` runs just this batch.
- `nvme` describes the device: `drive` size and controller properties. Each
  batch gets its own table because the harness resolves `drive` to a fresh raw
  disk at device-add time.
- Tag slow batches `"slow"` so `--where "not slow"` keeps quick iteration fast.

### 3. Run it

```sh
./nvme-check.lua tp4176 -w example
```

There is no separate build registration step per batch — `build.zig` needs
no edit — but the workflow entry *is* the registration: until a row in
`batches` names the program, nothing builds or runs it.

## Starting a new suite

Strictly required: a `batches/` directory with at least one program, and a
`workflow.lua`. Everything else below is the recommended skeleton — the
build registers `common.zig` only if the file exists, and the spec
definitions are the suite's own file, so a suite with no shared setup needs
neither.

1. `mkdir tests/<suite>` with:
   - `workflow.lua` — required; model it on `tests/tp4176/workflow.lua`: an
     `nvme()` device-spec factory and a `batches` table passed to
     `batch.run_all("<suite>", batches)`.
   - `batches/` — required; at least a `smoke.zig` that proves the device
     comes up with the feature enabled.
   - `common.zig` — recommended; shared batch setup (controller open from
     `NVME_BDF`, common teardown). Once it exists, `build.zig` exposes it to
     batches as the `common` import — no build edit needed.
   - `spec.zig` — recommended when the suite defines its own spec
     structures; constants, layouts and decoders plus host-side unit tests,
     imported from `common.zig` as
     `pub const spec = @import("spec.zig");`. If the suite needs
     little-endian conversion helpers, put them here (this is what
     keeps s390x honest).
   - `README.md` — what the suite specifies, which QEMU implements it, and any
     caveats.
2. If the suite has a `spec.zig` with unit tests, add
   `"tests/<suite>/spec.zig"` to `test_roots` in `build.zig`. That is the
   only build change a new suite can need; batch programs are self-contained
   and referenced by path from the workflow.
3. Verify `zig build test` covers the suite's unit tests on the host,
   then run a guest smoke batch on one architecture before filling out the
   matrix.

## Portability checklist

- [ ] The batch runs identically on amd64 and s390x (`./nvme-check.lua --list`
      to confirm it appears on both).
- [ ] Slow or poll-heavy batches are tagged `"slow"`.
