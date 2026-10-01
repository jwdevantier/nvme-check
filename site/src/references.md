<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# References

This project is a payload on top of two upstream projects. Their own
documentation is the reference for everything they provide, and it is where you
should look when a workflow uses something this book does not explain.

## makac

<https://jwdevantier.github.io/makac/>

The orchestrator that builds images, boots VMs and runs the suites. Its
documentation covers the full Lua API and every concept makac introduces —
workflows, steps, actions, targets, facts, packages, fetchers, the project
directory, and the `makac` CLI. Start here when you need to know what a
`step { ... }` may contain, how `makac_project.lua` is resolved, or how
selection and fetching work.

## makac.qemu

<https://jwdevantier.github.io/makac.qemu/>

The QEMU package, wired into this project as the `qemu` alias (see
[Installation](installation.md)). It provides every QEMU-specific action and
documents each one — building an image (`qemu:img`), booting, resuming and
snapshotting a VM (`qemu:vm`, `qemu:loadvm`, `qemu:savevm`), probing a running
VM (`qemu:probe`), and driving QMP. Reach for it when you are reading or
writing a `workflow.lua` and need the exact `with` table an action expects.
