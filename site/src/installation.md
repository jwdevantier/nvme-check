<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Installation

Running the suites needs four things on the host:

| Requirement | Provides | Notes |
|---|---|---|
| `makac` | Test orchestration | The binary itself; see below. |
| `zig` 0.16.x | Builds the test binaries | `build.zig.zon` enforces the version. |
| A QEMU build | `qemu-system-{x86_64,s390x}`, `qemu-img` | The device *under test*; see [Configuration](configuration.md). |
| `genisoimage`, `ssh`, `scp` | Cloud-init ISO, guest access | The guest is authorized with `ssh.pubkey`, default `~/.ssh/id_ed25519.pub`. |

There are two supported ways to get these: Nix, which pins every version and
is the setup the project is developed on, and a traditional Linux install,
which is best-effort. Both then need the `makac.qemu` package.


## With Nix

The default dev shell provides:

* The Zig toolchain
  * used to compile libvfn test programs
* the Zig language server,
* qemu-utils
  * provides `qemu-img`, needed to create VM images
* `genisoimage`
  * cloud-init builders compose a ISO for VM customization
* `makac`
  * The orchestrator

```sh
nix develop
```

Start your editor from inside this shell so it has access to `zls`.

Finally, proceed to [fetch the makac packages](#fetch-the-packages).

## Traditional Setup

Install each dependency with your package manager:

- `makac`
  - See [makac docs](https://jwdevantier.github.io/makac/installation.html) and pick the option most appropriate for you.
- **`zig` 0.16.x**
  - [ziglang.org](https://ziglang.org/download/) provides binary packages for various operating systems
- **QEMU**
  — a build providing `qemu-system-x86_64`, `qemu-system-s390x`, and
  `qemu-img`. Whether a suite is meaningful depends on this build implementing
  the feature under test.
- **`genisoimage`** — from the `cdrkit` package.
- **The OpenSSH client** — for `ssh` and `scp`.

Finally, proceed to [fetch the makac packages](#fetch-the-packages).

## Fetch the packages

`makac_project.lua` at the repository root is the project's dependency
manifest - run `makac fetch` to install the package(s) this project
depends on ([makac.qemu](https://jwdevantier.github.io/makac.qemu/)).

```
# install required (makac) packages
makac fetch
```

Fetching is explicit: `makac` never fetches on its own, so run this after a
fresh clone, and again whenever the pinned revision changes.

Next, set the QEMU binaries on the [Configuration](configuration.md) page:
there are no defaults, and the suites refuse to run until they are set. The
[Pre-flight check](pre-flight.md) then confirms the setup.
