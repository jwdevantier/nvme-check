<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Configuration

Per-machine settings live in a config file. The QEMU binaries are required:
there are no built-in paths, and the suites refuse to run until they are set.
The only environment variable in the configuration story chooses which file to
read.

## The config file

`config.user.lua` at the repository root is the conventional location. It is
gitignored; `config.user.sample.lua` is an annotated starting point. Which file
is read, in precedence order:

1. `./nvme-check.lua -c/--config <path>` (must exist)
2. `NVME_CONFIG=<path>` (must exist)
3. `<project>/config.user.lua` (conventional; absent leaves the QEMU paths unset)

The `build` keys are optional. The QEMU paths are not. A malformed file fails
with its parse error. `makac doctor` shows what resolved from where. Copy the
sample and edit it:

```lua
{{#include ../../config.user.sample.lua}}
```

## QEMU binaries

The QEMU binaries are the one required part of the configuration. The harness
needs the binaries, not a QEMU source tree:

| Setting | Meaning | Config key |
|---|---|---|
| amd64 system | `qemu-system-x86_64` for amd64 guests | `qemu.amd64.bin` |
| s390x system | `qemu-system-s390x` for s390x guests | `qemu.s390x.bin` |

There are no built-in defaults. Until `qemu.<arch>.bin` is set, `makac doctor`
reports it as an error and the suites refuse to run with a message naming the
missing key. The config key is derived from the architecture name
(`qemu.<arch>.bin`), so a new architecture gains its own knob
automatically.

**NOTE:** `qemu-img` itself must be on `PATH`, otherwise steps which create
the images for the VMs will fail.

## SSH key

The harness authorizes one public key inside the guest through cloud-init, and
drives the VM over SSH with the matching private key. It reads
`~/.ssh/id_ed25519.pub` by default; override it with:

```lua
return {
  ssh = { pubkey = "~/.ssh/id_ed25519.pub" },
}
```

A leading `~/` is expanded to `$HOME`. The matching private key must be one
that `ssh` finds by default, or available through `ssh-agent`.

## The build toolchain

`build.nix` in `config.user.lua` determines how binaries are compiled. 
If `true`, test binaries are built using the nix development shell defined in
`flake.nix`. If `false`, test binaries are built using the `zig` binary on `PATH`.

`build.libvfn_src` in `config.user.lua` allows you to compile against a local copy
of libvfn, see [Developer notes](developer-notes.md#building-against-a-local-libvfn)
for details

## Environment variables

| Variable | Meaning |
|---|---|
| `NVME_CONFIG` | Which config file to load (see above). |
| `MAKAC_IMG_VERBOSE=1` | Stream the guest serial console during the first base-image build. A debugging toggle, not configuration. |
| `NVME_BDF` | Set by the harness and read by each test binary: the PCI BDF of the freshly-bound controller inside the guest. Never set this yourself. |

---

Once the QEMU binaries are set, continue to the
[Pre-flight check](pre-flight.md) to confirm the setup.
