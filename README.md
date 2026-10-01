# nvme-check

Black-box conformance tests for QEMU's emulated NVMe device (`hw/nvme`),
written in Zig and driven directly through
[libvfn](https://github.com/SamsungDS/libvfn) on a vfio-bound controller —
control queues, doorbells and issue any NVMe command, with no kernel NVMe driver
in between. Tests are grouped into related suites, sometimes named after the
Technical Proposal (TP) that introduced them.
The suite, so far, focuses on running tests on AMD64 (little-endian) and
S390x (big-endian).
The test runner is written in Lua, using [makac](https://github.com/jwdevantier/makac),
which provides an expanded API and packages for building and booting QEMU VMs.

The goal: a regression-check suite you can run against any QEMU build —
a release, a topic branch, a patch under review — to confirm the device still
conforms to the official NVM Express specifications.

## Documentation

**<https://jwdevantier.github.io/nvme-check/>**

That site covers installation, configuration, running and selecting tests,
the architecture, and how to write new suites. Everything below it in this
repository (this file included) defers to it.

## Working on the docs

The site is an mdBook under `site/`:

```sh
nix develop .#site -c mdbook serve site   # then open http://localhost:3000
```

The hosted site is whatever GitHub Pages last built from `site/` here — keep
`site/src/` the single source of truth.

## Repository map

- `tests/<tp>/` — the suites (one per TP: `spec.zig`, `common.zig`, `batches/`, `workflow.lua`)
- `src/` — the Zig support library (`vfn` libvfn bindings, `vfntest` conveniences)
- `testlib/` — the Lua harness (package `nvmecheck`) on top of makac + makac.qemu
- `nvme-check.lua` — the runner entry point
- `DESIGN.md` — the design notes; `DEVELOPMENT.md`, `DEV.md` — hacking notes

## License

BSD-2-Clause.
