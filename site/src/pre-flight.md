<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Pre-flight check

`makac doctor` reports the health of makac itself and every package, and is the
last thing to run before using the suites:

```sh
makac doctor              # everything
makac doctor nvmecheck    # just this project's package
```

It checks the resolved configuration, the QEMU binaries and `qemu-img`, the
batch-build toolchain (your Zig, or Nix), and that the harness modules load.
`makac.qemu` adds its own checks, including `genisoimage`. If the report is
clean, things should work; a later failure caused by a missing tool is a bug in
the health check.

The first run on a fresh checkout reports the QEMU paths as errors until you
set `qemu.<arch>.bin` and `qemu.img` in `config.user.lua`; that is expected.
