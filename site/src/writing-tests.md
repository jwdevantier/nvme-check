<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Writing tests

## Test suites

A test suite is a directory under `tests/` containing a `workflow.lua`, such
as `tests/tp4176/`.

Suites could be named after a particular revision of the NVMe specification
that they target, or the technical proposal (TP) introducing the feature.

The runner discovers suites by `workflow.lua`; a directory without one is
skipped, silently.

The `workflow.lua` module returns a table with two fields:

- `uses` — *optional*, which driver runs the suite's tests. A driver is a
  makac action; see [Test drivers](drivers.md).
- `tests` — the tests to run (below).

## Adding tests

Each entry in `tests` is one test:

- `name` (required) — used in output and filtering.
- `uses` — the test driver for this test; overrides the suite-level one.
- `with` — the test data handed to the driver. What goes here is defined by
  the driver, see [test drivers](drivers.md).
- `tags` — strings for filtering. The test's name, its suite and its
  concrete test-case name are implicit. Tag slow tests `"slow"` so
  `--where "not slow"` keeps iterating fast.
- `params` — an array of tables, each declaring one concrete test-case for the
  test. Every entry becomes a test-case named `name[k=v,...]` (keys sorted) and
  each value contributes a `<key>=<value>` tag, so
  `params = { { arch = "amd64" }, { arch = "s390x" } }` runs the test twice —
  once tagged `arch=amd64`, once tagged `arch=s390x`. A test with no `params`
  runs once. `with.params` is filled in by the runner; declaring it yourself
  is an error.

A minimal suite, using the `base` driver:

```lua
-- tests/mysuite/workflow.lua
return {
  uses = "nvmecheck:base",          -- the driver for every test...
  tests = {
    { name = "smoke",
      with = { run = function(args)
        -- error("...") fails the test; returning passes it
      end } },

    { name = "another-check",
      with = { run = function(args) ... end } },

    { name = "identify",            -- ...unless the test says otherwise
      uses = "nvmecheck:qemu-vfio",
      params = { { arch = "amd64" }, { arch = "s390x" } },
      with = { program = "programs/identify.zig",
               nvme = { drive = "64M", ctrl = {} } } },
  },
}
```

## Running

```sh
./nvme-check.lua mysuite            # the whole suite
./nvme-check.lua -w identify        # by (implicit) tag
./nvme-check.lua --list             # enumerate without running
```

Filtering is tag-based: the test's name, its suite and its concrete test-case
name are implicit tags — see
[Selecting test-cases](user-guide.md#selecting-test-cases).
