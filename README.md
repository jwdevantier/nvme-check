# nvme-check

Black-box conformance tests for NVMe controllers, written in Zig and driven
through [libvfn](https://github.com/SamsungDS/libvfn) over the admin queue of a
vfio-bound controller. Tests are grouped by NVMe Technical Proposal (TP) and run
against emulated QEMU NVMe devices — on amd64 and s390x — with
[makac](https://github.com/jwdevantier/makac) building and booting the VMs.

Currently: **TP4176 (Rate Limiting)**.

Full documentation lives in the mdBook site under `site/`:

```sh
nix develop .#site -c mdbook serve site   # then open http://localhost:3000
```

## Running a test

Prerequisites: `makac` plus the `makac.qemu` package (wired in
`makac_project.lua`), a QEMU build, and `qemu-img`/`genisoimage` on `PATH`.
The QEMU binaries have no defaults — set `qemu.<arch>.bin` and `qemu.img` in
`config.user.lua` (see `config.user.sample.lua`); guest access uses `ssh.pubkey`,
default `~/.ssh/id_ed25519.pub`. Nix provides pinned versions of
all of these (`nix develop`) but is not required — zig fetches libvfn itself
via `build.zig.zon`, and the harness builds with the ambient `zig` when nix is
absent (or set `build.nix = false` in `config.user.lua` to force ambient
builds). `makac doctor nvmecheck` reports the resolved configuration and
checks the QEMU paths exist. The
first run per architecture builds a base
image and a snapshot; later runs resume it. The first image build is slow — to
watch it, set `MAKAC_IMG_VERBOSE=1` (streams the guest's serial console) or
`tail -f .makac/qemu/img/<image>/serial.log`.

```sh
# host-only: pure spec/unit tests, no VM
zig build test

# run everything (each batches/*.zig in its own fresh VM)
./nvme-check.lua

# selection: pytest-style --where expressions; arch and batch name are tags
./nvme-check.lua -a s390x                        # one arch
./nvme-check.lua tp4176 -w aer                   # one batch of one TP
./nvme-check.lua -w "fast and not slow"         # boolean tag expressions
./nvme-check.lua --list                          # show what would run
```

`./nvme-check.lua` is a makac script (see `nvme-check.lua --help`). Running a single
TP's workflow directly also works — it runs the whole TP (listing is the
runner's `--list`):

```sh
makac run tests/tp4176/workflow.lua
```

For each **batch** the harness resumes the snapshot, hot-plugs a controller with
the batch's device params (TP4176 needs `rate-limit=on`), binds it to vfio-pci,
copies the batch's Zig test binary into the guest, runs it, and tears the VM
down. The program reads the controller BDF from `$NVME_BDF`.

## Defining a test

A **TP** is a directory under `tests/`. A **batch** is one Zig test binary plus
the NVMe device params it runs against, executed in one VM session.

```
tests/my_tp/
├── spec.zig            # pure wire model + host tests (no device)
├── common.zig          # shared device state for the batch programs
├── batches/
│   └── my_case.zig     # device cases: test {} blocks
├── workflow.lua        # batch list (program + device params + tags/archs)
└── README.md
```

1. **`spec.zig`** — the spec-side model: wire structs, field offsets, command
   builders, decoders. Pure; add `test {}` blocks over synthetic buffers and
   `zig build test` runs them on the host. Import `vfn_c` for the libvfn C
   types. Add `"tests/my_tp/spec.zig"` to `test_roots` in `build.zig` (that is
   the only build change a new TP needs — batch programs are self-contained).

2. **`common.zig`** — open the controller once per batch and share helpers
   (admin submit, page-aligned DMA buffers). Import it as `@import("common")`.

3. **`batches/<name>.zig`** — the device-facing cases: ordinary `test {}`
   blocks importing `common`, `spec`, and the infra modules `vfn`, `nvme`,
   `vfntest`. The controller BDF comes from `$NVME_BDF`.

   ```zig
   const common = @import("common");
   const spec = @import("spec");

   test "my_case" {
       _ = try common.ctrl();
       // build a command with spec.*, submit with common.admin(),
       // assert on nvme.status(cqe) ...
   }
   ```

4. **`workflow.lua`** — declare the batches and run them:

   ```lua
   local batch = require("pkgs/nvmecheck/batch")

   local batches = {
     {
       name    = "my_case",
       program = "batches/my_case.zig",   -- one file -> one test binary
       nvme    = { drive = "64M", ctrl = { ["rate-limit"] = true } },
       archs   = { "amd64", "s390x" },     -- default: both
       tags    = { "my_tp" },
       -- pre_test  = function(ctx, b) ... end,          -- optional
       -- post_test = function(ctx, b, result) ... end,  -- optional; always runs
     },
   }

   batch.run_all("my_tp", batches)
   ```

   `nvme` is declarative: one cluster (`drive`, `ctrl`, `subsys`, `ns`, …), a
   list of them, or a function for full control. A bare `drive` size is resolved
   to a fresh per-run raw disk when the device is added. `archs`/`tags` feed
   `--where` selection (batch name and arch name are implicit tags).

See `DESIGN.md` for the full design (batch lifecycle, hooks, escape hatches,
the Zig/Lua split) and `LIBVFN-BE-FIXES.md` for the carried libvfn patches.
