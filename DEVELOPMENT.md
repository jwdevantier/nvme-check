<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Development notes

Short version: three test layers, fastest first.

| Layer | What | Command | Cost |
|---|---|---|---|
| Tag-expression DSL | `testlib/lib/tagexpr.lua` unit tests | `makac run testlib/tests/tagexpr_test.lua` | milliseconds |
| Host spec/unit tests | `test {}` in `tests/<tp>/spec.zig`, `src/` | `zig build test` | seconds |
| NVMe batch suites | `tests/<tp>/batches/*.zig` in fresh VMs | `./nvme-check.lua` | minutes |

## Day-to-day commands

```sh
# fast loop while iterating on spec.zig / wire formats
zig build test

# after touching testlib selection logic
makac run testlib/tests/tagexpr_test.lua

# what would this even run?
./nvme-check.lua --list

# typical subsets
./nvme-check.lua -a s390x                        # one arch
./nvme-check.lua tp4176 -w aer                   # one batch
./nvme-check.lua -w "fast and not slow"         # expression selection
```

## Useful knobs

- Point at a different QEMU build: copy `config.user.sample.lua` to
  `config.user.lua` and set `qemu.<arch>.bin`.
  `makac doctor nvmecheck` shows what resolved from where.
- First base-image build per arch is slow: `MAKAC_IMG_VERBOSE=1` streams the
  guest serial console; or `tail -f .makac/qemu/img/<image>/serial.log`.
- Big disposable state (VM disks, logs) lives under `.makac/` — `rm -rf
  .makac` is a complete reset.

Full docs (runner CLI reference, architecture, adding tests): the mdBook
site — `nix develop .#site -c mdbook serve site`, then
http://localhost:3000. `DESIGN.md` remains the authoritative design record.
