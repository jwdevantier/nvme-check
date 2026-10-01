<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# Developer notes

## Unit tests
This library has some unit tests, some testing aspects of the [LibVFN](https://github.com/SamsungDS/libvfn)
binding, others testing utility code shared across actual device tests.
To run the tests:
```sh
zig build test --summary all
```

To add additional sets of tests, add your file(s) to `const test_roots` in
`build.zig`

A special case: the runner's `-w/--where` flag (see the [User guide](user-guide.md))
takes a boolean tag expression for test selection — `aer or feature`,
`(aer or feature) and not slow` — and that little expression language is
implemented as a standalone Lua module, `testlib/lib/tagexpr.lua`. Being Lua,
`zig build test` cannot see it, so it has its own unit suite, which doubles
as the reference for the full grammar:

```sh
makac run testlib/tests/tagexpr_test.lua
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

## Writing tests in C? (a sketch)

The test batch binaries are Zig programs, but libvfn is a C library, and nothing
in nvme-tests outright prevents writing tests in C.
`./src/probe.c` was translated from `./src/probe.zig` and compiled using the Zig
toolchain like so:

```sh
zig build libvfn-src   # materialize the fetched/overridden tree at zig-out/libvfn-src
zig cc -c src/probe.c -o /tmp/probe.o \
  -Izig-out/libvfn-src/include -Izig-out/libvfn-src/src \
  -Izig-out/libvfn-src/ccan -Ivendor
```

If deemed valuable, then `batch.run_all` could be extended to detect if the test
program has the `.c` extension, and if so, compile programs as shown above.
The cost would be maintaining data-structures in two languages, however.

## Building the book

```sh
nix develop .#site -c mdbook serve site --port 3000
```

Then open <http://localhost:3000>.
