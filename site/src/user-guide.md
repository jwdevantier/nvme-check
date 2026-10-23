<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# User guide

`./nvme-check.lua` is the entry point. It discovers the suites (any directory
under `tests/` containing a `workflow.lua`), applies your selection, and runs
the selected test-cases.

Suites are [makac](https://jwdevantier.github.io/makac) workflows, and
`nvme-check` provides several [test drivers](drivers.md) so tests rarely write
that plumbing themselves.

Before the first run, set the QEMU binaries in the
[Configuration](configuration.md); there are no defaults, and the suites refuse
to run without them.

## Running

```sh
# every suite, every test-case
./nvme-check.lua

# one suite
./nvme-check.lua tp4176

# one test: all of its test-cases
./nvme-check.lua tp4176:aer

# one test-case
./nvme-check.lua 'nvme14m:inspect[arch=s390x]'

# show what would run, without running it
./nvme-check.lua --list -w 'arch=s390x'
```

A workflow is a declaration, not a script: it is run through the runner, never
`makac run tests/<suite>/workflow.lua`. For what happens once a run starts —
and why the first run per architecture is slow — see
[the `qemu-vfio` driver](drivers/qemu-vfio.md#what-a-run-looks-like).

## Selecting test-cases

Two inputs decide what runs: the positional selectors on the command line and
the `-w` tag expression. Both apply to the same universe — every test-case the
runner discovered — which `--list` prints.

### Suites, tests and test-cases

`./nvme-check.lua tp4176` runs one suite; with no positional selectors every
discovered suite is selected, and an unknown name is an error listing the
available suites.

`suite:test` narrows to every test-case of one test (`tp4176:aer`); a
misspelled test is an error listing that suite's tests, never a silent empty
selection.

Append the parameters in brackets to pick exactly one test-case — the brackets
are shell globs, so quote the argument:

```sh
./nvme-check.lua 'nvme14m:inspect[arch=s390x]'
```

### Tags

Every test-case is tagged, and `--where` filters on those tags. There are three
sources of tags:

1. The test's `tags` list in its `workflow.lua` (for example `tp4176`,
   `fast`, `slow`).
2. One `<key>=<value>` tag per parameter. A test declaring
   `params = { { arch = "amd64" }, { arch = "s390x" } }` produces two
   test-cases, tagged `arch=amd64` and `arch=s390x`; a test without `params`
   is one unparameterized test-case.
3. The suite, the test's base name and the concrete test-case's name
   (`nvme14m`, `inspect`, `inspect[arch=s390x]`).

So `--where aer` selects every test-case of the test named `aer`, and
`--where 'arch=s390x'` selects every test-case whose parameters say it runs on
s390x.

### The `--where` expression language

`--where` takes a boolean expression over tags, in the style of pytest's `-m`:

| Expression | Selects test-cases that … |
|---|---|
| `aer` | carry the tag `aer` |
| `fast and arch=s390x` | carry both |
| `aer or feature` | carry either |
| `not slow` | do not carry `slow` |
| `(aer or feature) and not slow` | parentheses group; `not` binds tightest, then `and`, then `or` |

Identifiers are case-sensitive and may contain letters, digits, `_`, `-`,
`.` — and, because parameter tags and test-case names contain them, `=`, `[`,
`]` and `,`. The words `and`, `or` and `not` are reserved. Matching is exact:
`arch=s390x` is one tag, not a substring search; a bare `s390x` is a
different tag.

An unknown tag selects nothing, so an unexpectedly empty run is usually a typo
— check with `--list`. A malformed expression fails before any VM boots, with
a caret at the offending position and exit code 2:

```
invalid tag expression: expected a tag or '(' but the expression ended here
  aer and
         ^
```

## Options

`./nvme-check.lua --help` prints the same list at the terminal; positional
selection is covered in [Selecting test-cases](#selecting-test-cases).

| Option | Meaning |
|---|---|
| `-c`, `--config FILE` | Per-machine config file (see [Configuration](configuration.md)). |
| `-w`, `--where EXPR` | Boolean tag expression, described above. |
| `-l`, `--list` | Print one line per selected test-case (`suite:name[params]` and its tags); run nothing. |
| `-h`, `--help` | Usage text. |

The config file is `-c` if given, else `$NVME_CONFIG`, else the conventional
`config.user.lua` in the project root.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Everything selected passed (or `--list` succeeded). |
| 1 | A test failed, or a usage error (unknown suite, unknown test, unknown flag, missing flag value). |
| 2 | Malformed `--where` expression. |
