# DESIGN — NVMe TP test suites in `nvme-check`

> **Status:** agreed shape, pre-implementation. This document is the reference
> for the layout that merges the Zig payload (this repo) with the makac
> orchestration currently living in `~/repos/makac.e2e/nvme-tests`. It is meant
> to be worked over before any code is written.

---

## 1. Goals

- One repository per test family: the **Zig payload** and the **makac
  orchestration** live together, so a TP's test code and the QEMU device setup
  needed to exercise it evolve as one unit.
- A **TP (technical proposal) is the collection**: one directory holding its
  pure spec model, its Zig test programs, and its workflow.
- Keep the makac snapshot/resume model: seed once per arch, then run each
  **batch** against a freshly resumed VM.
- Keep the Zig side idiomatic: ordinary `test {}` blocks, cross-compiled as
  static binaries and shipped into the guest.
- Keep the orchestration in Lua, where the author has full freedom.

## 2. Non-goals / deferred

- No custom CLI dispatch binary (`nvme-suites run <suite>`) — dropped.
- No custom Zig test runner initially. Zig's built-in runner is used as-is.
  Runtime filtering via a custom `test_runner` is a later option (§10).
- No changes to the carried libvfn sources / patches in this design.

## 3. Ownership split

| Layer | Owns | Knows about |
|---|---|---|
| Zig `src/` | talking to libvfn and generic NVMe | libvfn C API |
| Zig `<tp>/spec.zig` | the TP's wire formats + expectations | the NVMe spec only |
| Zig `<tp>/batches/*.zig` | device test cases (`test {}`) | libvfn + `spec.zig` |
| Lua `<tp>/workflow.lua` | batch list, device params, hooks | makac, QEMU |
| Lua `testlib/` (pkg `nvmecheck`) | generic VM harness, arch matrix, selection | makac, makac.qemu |

The Zig side knows NVMe. The Lua side knows QEMU. Neither reaches across.

### Guiding principle: thin bindings, opportunistic test support

The Zig libvfn binding (`src/vfn/`) stays close to the upstream C API — a
direct, predictable mapping, not an opinionated wrapper. Idiomatic test
conveniences belong in a **separate test-support layer** (`src/vfntest/`,
imported as `vfntest`), extracted opportunistically as common patterns emerge.
That layer must not become a second NVMe abstraction API unless experience
demonstrates that the abstraction is warranted.

## 4. Concepts

### TP (collection)
One directory under `tests/`, e.g. `tests/tp4176/`. Holds `workflow.lua`,
`spec.zig`, `batches/`, and a `README.md`. This replaces the old
"one binary / one suite per collection" idea: the TP is the organising unit,
and it may contain several **batches**.

### spec.zig (pure)
The NVMe-on-the-wire model for the TP:

- wire structures the TP introduces that libvfn does not already declare
  (e.g. Rate Limit feature data, Rate Limit log page, descriptors);
- encoders (build command CDWs / feature buffers);
- decoders (typed views over returned buffers);
- expectation predicates (e.g. `isInvalidField(cqe)`);
- `test {}` blocks over synthetic buffers and captured fixtures.

Generic structures already in libvfn are re-exported/referenced, not
duplicated. NVMe is little-endian on the wire; LE conversion lives here, which
is what makes the same code correct on s390x.

`spec.zig` is the **only** thing on the host `zig build test` path.

### program
A Zig test root — one file under `<tp>/batches/` — that the build compiles into
**one test binary**. It contains the device-facing `test {}` cases. The test
binary reads the controller BDF from the `NVME_BDF` environment variable.

### batch
The unit of isolation and of VM cost:

```
batch = one test binary (program) + a set of NVMe device params
```

A batch means: load the VM from persisted state, hot-plug the NVMe devices via
QMP using the provided params, scp the test binary over, run it, capture the
result, kill the VM.

### workflow.lua
A makac workflow, run directly with `makac run`. It declares the batches inline
and drives the arch × batch loop; `./nvme-check.lua` discovers and drives the
per-TP workflows (§6).

## 5. Batch contract

### Shape

```lua
{
  name      = "identify",                  -- logs / reporting
  program   = "batches/identify.zig",      -- Zig test root -> one test binary
  nvme      = <cluster | cluster[] | fn>,  -- default: one cluster (see below)
  archs     = { "amd64", "s390x" },        -- default: both
  tags      = { "fast", "tp4176" },        -- selection (arch tags implied)
  pre_test  = function(ctx, b) ... end,    -- optional; after device setup
  post_test = function(ctx, b, result) ... end,  -- optional; always runs
}
```

- `nvme` takes a single **cluster** spec (the default), an array of cluster
  specs, or a function for full control — see "NVMe device setup" below. Reuse
  is the author's business.
- `program` is resolved relative to the TP directory.

### Lifecycle

```
up(arch)                             -- resume persisted snapshot
setup devices per b.nvme             -- add cluster(s) + bind; -> BDF list
pre_test(ctx, b)                     -- device(s) live, BDF(s) known
build + put + run(program)  ->  result
post_test(ctx, b, result)            -- ALWAYS runs (finally)
down(arch)                           -- kill VM
```

- `pre_test(ctx, b)` — preparatory work, after the NVMe devices are added and
  bound and the BDF(s) are known: scp extra resources, tweak guest state,
  prepare namespaces, etc.
- `post_test(ctx, b, result)` — collect artifacts/logs, cleanup. Runs under
  `pcall` so it executes even if `pre_test` or the program failed.
- `result = { code, stdout, stderr, bin, bdf, bdfs }`.

There is **no data channel** between hooks and the program: the workflow is a
Lua closure, so hooks close over whatever they need.

### NVMe device setup ("clusters")

A **cluster** is one NVMe stack — a subsystem, a namespace, and a controller —
i.e. one value `ctx.add_nvme` accepts. `nvme` supports three tiers so the
common case stays a single line while the rare case is unconstrained:

```lua
-- default: one cluster (the vast majority of batches)
nvme = { drive = "64M", ctrl = { rate_limit = true } }

-- several clusters, still declarative
nvme = {
  { id = "a", drive = "64M", ctrl = { rate_limit = true } },
  { id = "b", drive = "64M", ctrl = { serial = "second" } },
}

-- full control: add/bind anything, return the BDFs to expose
nvme = function(ctx, b)
  ctx.add_nvme { ... }
  ctx.add_nvme { ... }
  return { ctx.bind_vfio("nvme0"), ctx.bind_vfio("nvme1") }
end
```

The framework normalizes all three forms, adds the declared clusters, binds
their controllers, and exposes the result to the program. A cluster's `drive`
may be a bare size (e.g. `"64M"`): that is declarative data, resolved by the
framework at device-add time — after the VM is up — via
`ctx.raw(batch_name, size)`.

- `NVME_BDF` — the primary (first) controller's BDF;
- `NVME_BDFS` — comma-separated list of all bound BDFs, in declaration order;
- `result.bdf` / `result.bdfs` — the same, as Lua values.

A **function** form is responsible for adding *and* binding its own devices;
the framework then skips its own add/bind and uses the returned BDF list. This
is the escape hatch for topologies the declarative forms cannot express.

### Escape hatch

`batch.run(...)` is a convenience, not a cage. If a batch needs something the
helper cannot express (e.g. acting before hot-plug), the author writes the
makac steps inline and does not use the helper. This keeps the formal contract
honest.

## 6. Selection: tags and arches

Per-batch `tags` and `archs`, selected through the `./nvme-check.lua` runner:

- `-w/--where <expr>` — pytest-style boolean expressions over tags
  (`"amd64 and not slow"`), parsed by `testlib/lib/tagexpr.lua`.
- implicit tags — the arch under run and each batch's `name`, so
  `--where "s390x"` and `--where "aer"` select as expected; arch filters do
  not leak across a two-arch batch's instances.
- `-l/--list` — print the selection and run nothing.
- `-a/--arch` — restrict the arch matrix without the tag language.

Filtering lives in `testlib/lib/batch.lua` (`batch.run_all` +
`batch.set_selection`), so `workflow.lua` stays a declarative list plus a
one-line run loop.

## 7. Repository layout

```
nvme-check/
├── build.zig
├── flake.nix
├── patches/
│   └── libvfn-s390x.patch
├── vendor/
├── src/                      # generic, TP-agnostic Zig infra
│   ├── vfn/                  #   thin Zig wrappers over libvfn (C API)
│   ├── nvme/                 #   shared wire types (e.g. cqe status decode)
│   ├── vfntest/              #   test-support conveniences (thin, opportunistic)
│   ├── vfn_c.h
│   └── vfn_shim.c
├── testlib/                  # our makac package "nvmecheck" (not tests)
│   ├── makac.lua             #   package manifest: exports actions (build)
│   ├── lib/                  #   pkg modules: require("pkgs/nvmecheck/<name>")
│   │   ├── arch.lua          #     amd64 / s390x: qemu bin, machine args, attach
│   │   ├── guest.lua         #     ctx: add_nvme, bind_vfio, put, sh, wait_dev
│   │   ├── images.lua        #     base + raw image specs
│   │   ├── nvme.lua          #     device params -> QMP / cold-plug argv (pure)
│   │   ├── zigtest.lua       #     implements the build action (one root file)
│   │   └── batch.lua         #     select + run one batch (the lifecycle above)
│   └── templates/
│       ├── user-data.tpl
│       └── meta-data.tpl
├── tests/                    # tests only: one directory per TP
│   └── tp4176/
│       ├── workflow.lua      #   makac run tests/tp4176/workflow.lua
│       ├── spec.zig          #   pure; host `zig build test`
│       ├── batches/
│       │   ├── identify.zig  #   one root file = one batch binary
│       │   ├── log_page.zig
│       │   └── feature.zig
│       └── README.md
├── .makac/                   # gitignored (auto-created) data directory
└── makac_project.lua         # tracked: wires the qemu + nvmecheck packages
```

## 8. Build and entry points

```sh
# Host unit tests — pure spec, no makac, no QEMU:
zig build test

# End-to-end, one TP (workflow loops arch × batch); `makac` is the binary from
# the makac checkout (~/repos/makac/makac):
cd ~/repos/nvme-check
makac run tests/tp4176/workflow.lua

# Selection (the runner — see test-runner.md):
./nvme-check.lua tp4176 -w s390x
./nvme-check.lua tp4176 -w "amd64 and fast and not slow"
./nvme-check.lua tp4176 --list
```

### Harness package: `nvmecheck`

`testlib/` is a **makac package** — `makac_package.lua` at its root, modules
under `lib/` — loaded in place by the filesystem fetcher:

```lua
-- makac_project.lua  (tracked; .makac/ is gitignored)
return {
  inputs = {
    ["makac.qemu"] = { fetcher = "filesystem", with = { path = "/home/nixos/repos/makac.qemu" } },
    ["nvmecheck"]  = { fetcher = "filesystem", with = { path = "testlib" } },
  },
  packages = { qemu = "makac.qemu", nvmecheck = "nvmecheck" },
}
```

`inputs` says where the code comes from (the key is the package's canonical
name — its `makac_package.lua` declares the same `name`, checked); `packages`
wires an alias to an input. `resolve_pkg_dir` resolves a relative path against
the project root, so `testlib` means `<repo>/testlib`. `makac run` calls
`load_packages()` **before** the workflow runs, so the package's actions are
registered with no `require` in the workflow.

```lua
-- testlib/makac_package.lua
return {
  name = "nvmecheck",
  requires = { qemu = "...wire makac.qemu under the alias 'qemu'..." },
  actions = { build = require("./zigtest").build },
}
```

The manifest registers each name under the alias: `build` → action
`nvmecheck:build`. Workflows reach package modules as
`require("pkgs/nvmecheck/<name>")` (mapped to `testlib/lib/<name>.lua`); the
package's own modules use package-rooted relative imports
(`require("./zigtest")`), so the harness never depends on the alias it is
wired under. The manifest's `requires` is checked at load: if the `qemu`
alias is not wired, the run fails with the message above.

> The project file lives at `makac_project.lua`, BESIDE the conventionally
> gitignored `.makac/` data directory. This is makac's standard layout: the
> whole data directory is ignored and the project file is an ordinary tracked
> file.

### The `nvmecheck:build` action

`step { uses = "nvmecheck:build", with = {...} }` cross-compiles one batch root
for the guest arch and returns the binary path:

| `with` | |
|---|---|
| `arch` | `"amd64"` / `"s390x"` → target triple |
| `program` | the batch's Zig test root |
| `name` | output binary name |
| `libvfn_src` | optional libvfn override (else the pinned build.zig.zon dependency) |

It wraps `zig build -Dtarget=<triple> -Dstatic=true -Dprogram=<program>
-Dlibvfn-src=<...> --prefix <tmp>` and returns `out = { path = ... }`. The
`-Dprogram=` interface is owned by the action, not exposed to workflows.

`build.zig` responsibilities:

- build libvfn + ccan from source (unchanged);
- a `test` step rooted at the pure spec sources (`zig build test`, host only);
- accept `-Dprogram=<root> -Dtarget=<triple> -Dstatic=true` and produce a guest
  test binary, invoked by the `nvmecheck:build` action above.

## 9. How Zig tests are used here

- Tests are `test {}` blocks; the compiler discovers them at compile time.
- The unit is **one test binary built from one root file**. Zig has **no suite
  object**.
- `b.addTest` compiles but does not run; a run step is separate.
- Tests in imported files are included only if reachable (`_ = @import(...)`
  or `refAllDecls`).
- The built-in runner is sequential, prints each test, treats
  `error.SkipZigTest` as a skip, and exits non-zero on failure.
- **No runtime selection**: the built-in runner panics on unknown arguments and
  filters are compile-time only. This is precisely why a **batch = a root
  file** is the natural mapping: each batch binary is run once per VM resume,
  with no need for filtering.
- The BDF is passed via `NVME_BDF` (the runner accepts no custom arguments).
- Guest binaries are static (musl), so no in-guest libvfn, no headers, and no
  dynamic-loader workaround.

## 10. VM / snapshot flow

- Seeding is **outside** the batch: `archlib.seed(arch)` builds the base image,
  boots once, `savevm`s a baseline, and stops. It is a no-op once the baseline
  exists.
- Every batch does `up` (resume/`loadvm`) … `down` (kill/clean QMP quit).
- The archive image, snapshot, and raw disks are per arch.

## 11. Deferred / future directions

- **`makac file.lua`** (shorthand for `makac run file.lua`) and command-line
  arguments to workflows — would let batches/workflows take a filter directly
  instead of reading env vars.
- **Custom Zig test runner** (`addTest(.{ .test_runner = ... })`) to add runtime
  `--filter`/`--list` and allow one binary per TP run several times. Only worth
  it if the batch-per-binary cross-build/ship count becomes annoying.
- **Generated manifest / `--list`** if an orchestrator ever needs to enumerate
  cases (note: a cross-compiled guest binary cannot run `--list` on the host;
  a host-native build or a build-time manifest would be required).
- **`pre_device` / `post_device` hooks** (around `add_nvme`/`bind_vfio`) if a
  use-case ever warrants acting before hot-plug; today only `pre_test` /
  `post_test` exist.

## 12. Open questions

None currently. (The batch `nvme` forms, hooks, build action, and
test-support layer location are resolved — see §5, §8, and §3.)

## 13. Migration and dependencies

The harness currently in `~/repos/makac.e2e/nvme-tests` is the starting point:
we take what works and draw inspiration for the rest, then re-home it here.
This repository will be **self-contained**.

### Dependency boundary

This repo depends only on:

- **makac** (`~/repos/makac`, and its upstream) — the orchestrator that runs
  `workflow.lua`;
- **makac.qemu** (`~/repos/makac.qemu`, and its upstream) — the `qemu:*`
  actions and `pkgs/qemu/*` modules, wired in via `makac_project.lua` (the
  `filesystem` fetcher pointing at the makac.qemu checkout, or a git fetcher
  for upstream).

It does **not** depend on `~/repos/makac.e2e` or anything in it. All harness
code (`testlib/`, our own `nvmecheck` package), the cloud-init templates, and
the TP workflows are owned here and written by us.

### Runtime prerequisites (not packages of this repo)

- the `makac` binary (built from `~/repos/makac`);
- host tools the qemu package needs (e.g. `qemu-img`, `genisoimage`) on `PATH`;
- a QEMU build (the binaries referenced by `testlib/lib/arch.lua`);
- per-arch base images and baseline snapshots, built on first `seed` and cached
  locally (`.makac/` — including `vm-images/` — gitignored).

### Approach

Port/reimplement, from `makac.e2e/nvme-tests`, the parts that work:
`lib/{arch,guest,images,nvme}.lua` and `templates/` (rehomed under the
top-level `testlib/` makac package). Replace its `runner.lua` discovery model
with the per-TP `workflow.lua` + batch contract of §5; generalize `zigprobe.lua`
into `zigtest.lua` / `batch.lua`. Nothing in the final tree may `require` or
reference `makac.e2e`.
