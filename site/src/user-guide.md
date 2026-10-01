<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# User guide
`./nvme-check.lua` is the entry point. It discovers the suites (any directory
under `tests/` containing a `workflow.lua`), applies your selection, and runs
the selected batches.

A workflow is a makac script with the makac.qemu actions at its disposal, so a
suite can in principle drive several VMs and do arbitrary work around the test
run. In practice a suite usually needs one thing: boot a VM with the NVMe
device configured a particular way, run a test binary against it, shut the VM
down. For that common case the workflow simply declares a `batches` table —
one row per test program, with its device parameters and tags, as in
[tests/tp4176/workflow.lua](https://github.com/jwdevantier/nvme-check/blob/main/tests/tp4176/workflow.lua).

Before the first run, set the QEMU binaries in the
[Configuration](configuration.md); there are no defaults, and the suites refuse
to run without them.

## Running tests

```sh
# everything: every suite, every architecture
./nvme-check.lua

# one suite on one architecture
./nvme-check.lua tp4176 -a s390x

# one batch
./nvme-check.lua tp4176 -w aer

# show what would run, without running it
./nvme-check.lua --list
```

The first run per architecture is slow: it downloads a cloud image, boots it,
and snapshots the result. Later runs resume the snapshot in seconds. To watch
the initial build, set `MAKAC_IMG_VERBOSE=1` or follow the serial log:

```sh
tail -f .makac/qemu/img/<image>/serial.log
```

For what happens once a run starts, see
[Architecture](architecture.md#what-a-run-looks-like).

## Selecting tests

Selection has two axes: the suites named on the command line, and the
`--where` tag expression.

### Suites

The positional arguments name suites. `./nvme-check.lua tp4176` runs only that
suite; with no positional arguments, every discovered suite is selected.
An unknown name fails with the list of available suites.

### Tags

Every batch is tagged, and `--where` filters on those tags. There are three
sources of tags:

1. The batch's `tags` list in its `workflow.lua` (for example `tp4176`,
   `fast`, `slow`).
2. The batch's `name`.
3. The architecture it runs on (`amd64`, `s390x`).

So `--where aer` selects the batch named `aer`, and `--where s390x` selects
everything that runs on s390x.

### The `--where` expression language

`--where` takes a boolean expression over tags, in the style of pytest's `-m`:

| Expression | Selects batches that … |
|---|---|
| `aer` | carry the tag `aer` |
| `fast and s390x` | carry both |
| `aer or feature` | carry either |
| `not slow` | do not carry `slow` |
| `(aer or feature) and not slow` | parentheses group; `not` binds tightest, then `and`, then `or` |

Identifiers are case-sensitive and may contain letters, digits, `_`, `-`, and
`.`; the words `and`, `or`, and `not` are reserved.

An unknown tag selects nothing, so an unexpectedly empty run is usually a typo
— check with `--list`. A malformed expression fails before any VM boots, with
a caret at the offending position and exit code 2:

```
invalid tag expression: expected a tag or '(' but the expression ended here
  aer and
         ^
```

The expression language is a standalone module, `testlib/lib/tagexpr.lua`,
with its own unit suite at `testlib/tests/tagexpr_test.lua`. That suite is the
reference for the full grammar:

```sh
makac run testlib/tests/tagexpr_test.lua
```

## Flags

```
usage: nvme-check.lua [suite...] [-c file] [-a arch]... [-w expr] [-l]
```

| Flag | Meaning |
|---|---|
| `suite` (positional) | Restrict to these suites (default: all of `tests/*`). |
| `-c`, `--config file` | Which per-machine config file to use (see [Configuration](configuration.md)). |
| `-a`, `--arch arch` | Only this architecture (`amd64`, `s390x`, …). Repeatable or comma-separated. |
| `-w`, `--where expr` | Boolean tag expression, described above. |
| `-l`, `--list` | List the selected (architecture, batch) pairs without running anything. |
| `-h`, `--help` | Usage text. |

## Running a suite directly

Each suite's workflow is also runnable without the runner:

```sh
makac run tests/tp4176/workflow.lua
```

That runs the whole suite. Listing and selection are the runner's job.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything selected passed (or `--list` succeeded). |
| 1 | A test failed, or a usage error (unknown suite, unknown flag, missing flag value). |
| 2 | Malformed `--where` expression. |
