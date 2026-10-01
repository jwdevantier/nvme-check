<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Developer notes

## Test layers

Three layers, fastest first:

| Layer | What | Command | Cost |
|---|---|---|---|
| Tag-expression DSL | `testlib/lib/tagexpr.lua` unit tests | `makac run testlib/tests/tagexpr_test.lua` | milliseconds |
| Host spec tests | `test {}` in `tests/<suite>/spec.zig` and `src/` | `zig build test` | seconds |
| Guest suites | `tests/<suite>/batches/*.zig` in fresh VMs | `./nvme-check.lua` | minutes |

## What a run looks like

A run selects (architecture, batch) pairs and executes each pair in one VM
session. For each batch, per architecture:

1. The architecture's live disk is resumed from its base snapshot.
2. An NVMe controller is hot-plugged with the batch's device parameters, backed
   by a fresh raw disk under `.makac/vm-images/`.
3. The controller is bound to `vfio-pci` in the guest.
4. The batch's test binary, cross-compiled statically for the guest
   architecture, is copied in and executed, reading the controller BDF from
   `NVME_BDF`.
5. The VM is shut down with a clean QMP quit.

The slow base-image build happens once per architecture; every batch after
that starts from the same resumed snapshot and a fresh copy of its raw disk.

```
 HOST                                GUEST  (resumed at the baseline snapshot)

 QMP: loadvm                ----->   VM is live in seconds, no boot

 QMP: device_add            ----->   NVMe controller appears on the PCI bus,
 (batch's ctrl params +              backed by a fresh raw disk
  fresh raw disk)

 ssh: bind script           ----->   controller leaves nvme.ko, opens via
                                     /dev/vfio; its BDF becomes NVME_BDF

 zig build (static, guest arch)      (nothing on the guest yet)

 scp batch binary           ----->   /tmp/<batch>

 ssh: NVME_BDF run          ----->   zig test runner drives the controller
                                     through libvfn: admin queue, doorbells,
                                     CQEs, no kernel NVMe driver in between
                            <-----   stdout, stderr, exit code

 QMP: quit                  ----->   clean shutdown; live-disk writes and the
                                     raw NVMe disk are discarded
```

## Building against a local libvfn

The default libvfn is the pinned `build.zig.zon` dependency, a fork
(`jwdevantier/libvfn`) carrying upstream plus the s390x and big-endian fixes,
hash-verified by Zig.

To develop against a local checkout instead, point the build at it. For a host
build:

```sh
zig build test -Dlibvfn-src=~/repos/libvfn
```

To make the harness use it for every batch build, set it in the config file:

```lua
return {
  build = { libvfn_src = "/home/me/repos/libvfn" },
}
```

`build.zig` copies the same tree it compiles to `zig-out/libvfn-src`, so that
path always matches what was built, whether it came from the pinned dependency
or the override.

The promotion path for a change is: hack locally with `-Dlibvfn-src`, push to
the fork, then bump the SHA and hash in `build.zig.zon` via
`zig fetch <archive-url>` so everyone else picks it up.

## Building the book

```sh
nix develop .#site -c mdbook serve site --port 3000
```

Then open <http://localhost:3000>.
