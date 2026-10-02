<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Writing tests

## Test suites

A test suite is a directory under `tests/` containing a `workflow.lua` —
`tests/tp4176/`, for example. That is also all it takes to create one. Suites
in this repository are named after the TP or spec section they cover; any
documentation a suite needs (what it specifies, caveats, minimum QEMU
version, ...) goes in a `README.md` in the same directory.

The runner discovers suites by `workflow.lua`; a directory without one is
skipped, silently.

The `workflow.lua` module returns a table with two fields:

- `uses` — which driver runs the suite's tests. A driver is a makac action;
  see [Test drivers](drivers.md).
- `tests` — the tests to run (below).

## Adding tests

Each entry in `tests` is one test:

- `name` (required) — used in output and filtering.
- `uses` — the driver for this test; overrides the suite-level one.
- `with` — the test data handed to the driver. What goes here is defined by
  the driver: [`libvfn-simple`](drivers/libvfn-simple.md) expects a `program`
  and device parameters, [`base`](drivers/base.md) expects a `run` function.
- `tags` — strings for filtering. The test's name, its suite and the
  architecture name are implicit. Tag slow tests `"slow"` so
  `--where "not slow"` keeps iterating fast.
- `archs` — restrict to specific architectures; defaults to all.

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
      uses = "nvmecheck:libvfn-simple",
      with = { program = "batches/identify.zig",
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

Filtering is tag-based, with the test's name, suite and architecture name as
implicit tags — see [Selecting tests](user-guide.md#selecting-tests).
