<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# User guide
`./nvme-check.lua` is the entry point. It discovers the suites (any directory
under `tests/` containing a `workflow.lua`), applies your selection, and runs
the selected batches.

A workflow is a [makac](https://jwdevantier.github.io/makac) script with the
[makac.qemu](https://jwdevantier.github.io/makac.qemu) actions at its disposal,
so a suite can in principle drive several VMs and do arbitrary work around the
test run. In practice tests mostly tend to do the same setup work.
To that end, `nvme-check` provides several [test drivers](drivers.md).

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
./nvme-check.lua tp4176:aer

# show what would run, without running it
./nvme-check.lua --list
```

For what happens once a run starts — and why the first run per architecture
is slow — see
[the `libvfn-simple` driver](drivers/libvfn-simple.md#what-a-run-looks-like).

## Selecting tests

Selection has two axes: the suites named on the command line, and the
`--where` tag expression.

### Suites and single tests

The positional arguments name suites. `./nvme-check.lua tp4176` runs only that
suite; with no positional arguments, every discovered suite is selected.
An unknown name fails with the list of available suites.

To run a single test, name it as `suite:test`: `./nvme-check.lua tp4176:aer`.
The test name is applied as a name filter across the suites you selected
(test names are implicit tags — the same mechanism `--where aer` uses), and
it combines with the other flags: `-a s390x` further restricts the
architecture, `-w` is and-ed with it. Since the test is named explicitly, a
name that does not exist is an error listing the suite's tests, not an empty
selection.

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
usage: nvme-check.lua [suite[:test]...] [-c file] [-a arch]... [-w expr] [-l]
```

| Flag | Meaning |
|---|---|
| `suite[:test]` (positional) | Restrict to these suites, or to one test within a suite (default: all of `tests/*`). |
| `-c`, `--config file` | Which per-machine config file to use (see [Configuration](configuration.md)). |
| `-a`, `--arch arch` | Only this architecture (`amd64`, `s390x`, …). Repeatable or comma-separated. |
| `-w`, `--where expr` | Boolean tag expression, described above. |
| `-l`, `--list` | List the selected (architecture, batch) pairs without running anything. |
| `-h`, `--help` | Usage text. |

## Running a suite

Workflows are declarations loaded by the runner — there is no standalone
`makac run tests/<suite>/workflow.lua`. Run a whole suite by naming it:

```sh
./nvme-check.lua tp4176
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything selected passed (or `--list` succeeded). |
| 1 | A test failed, or a usage error (unknown suite, unknown test, unknown flag, missing flag value). |
| 2 | Malformed `--where` expression. |
