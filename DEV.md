# DEV.md

Scratch pad of commands & knobs. Unpolished on purpose — the real docs live
in `site/` + `README.md` + `DEVELOPMENT.md`; this is the capture layer that
eventually feeds them.

## builds

```sh
# host unit tests (spec.zig test {} blocks; no VM)
zig build test

# host tests against a LOCAL libvfn checkout (default: pinned zon dep)
zig build test -Dlibvfn-src=~/repos/libvfn

# guest batch binary by hand (what the harness runs under the hood)
zig build -Dprogram=tests/tp4176/batches/aer.zig \
          -Dtarget=s390x-linux-musl -Dstatic=true \
          -Dprogram-name=aer --prefix /tmp/out

# through the harness, every batch build with local libvfn:
# config.user.lua -> build = { libvfn_src = "/home/me/repos/libvfn" }
```

libvfn promotion path: hack with `-Dlibvfn-src` → push to fork
(jwdevantier/libvfn) → bump SHA+hash in build.zig.zon via
`zig fetch <archive-url>` → CI/everyone gets it.

zig cc as a C compiler (src/probe.c, the C port of probe.zig):

```sh
zig build libvfn-src   # materialize the fetched/overridden tree at zig-out/libvfn-src
zig cc -c src/probe.c -o /tmp/probe.o \
  -Izig-out/libvfn-src/include -Izig-out/libvfn-src/src \
  -Izig-out/libvfn-src/ccan -Ivendor
```

zig-out/libvfn-src is copied from the same LazyPath the build compiles — the
pinned zon dependency, or the -Dlibvfn-src override — so it always matches.
(`-Ivendor` supplies the in-tree meson-generated trace/events.h. The zig
package cache keeps only the libvfn tarball, NOT an unpacked tree — don't go
looking for `-I` paths there.)

## zig-the-language vs zig-the-toolchain (2026-09 discussion)

Cross-compiling static guest binaries (s390x-musl etc.) is a property of the
**zig toolchain**, not the language: `zig cc -target s390x-linux-musl` gives
C sources the same treat. build.zig already compiles C (it builds libvfn), so
C batches (`batches/foo.c` with a `main()`) would work without any toolchain
change — only test-harness glue (no `test {}` runner in C; use
main-returns-nonzero or a micro assert header).

What stays Zig-only: `test {}` blocks, defer/errdefer, error unions,
`zig build test`. What C would kill: the vfn_c.h/vfn_shim.c shim apparatus
(~250 lines existing only for translate-c) — a C test sees libvfn's headers
and struct layouts directly.

Evidence piece: src/probe.c is a line-for-line C port of probe.zig; compile
clean via the recipe above. If "should tests be C?" ever gets re-opened (e.g.
upstreaming conformance cases to QEMU qtest / libvfn), port ONE real batch
(smoke) in C through the VM and compare before deciding anything.

zig targets hardcoded in testlib/lib/zigtest.lua: amd64=x86_64-linux-musl,
s390x=s390x-linux-musl.

## running tests

```sh
./nvme-check.lua                       # everything
./nvme-check.lua -l                    # list (arch, batch) pairs
./nvme-check.lua tp4176 -w aer         # one batch
./nvme-check.lua -a s390x              # one arch
./nvme-check.lua -w "fast and not slow"
./nvme-check.lua -c /tmp/ci.lua        # alternate config file

# a whole TP without the runner (no selection knobs):
makac run tests/tp4176/workflow.lua

# the tagexpr DSL's own unit tests (pure lua, instant):
makac run testlib/tests/tagexpr_test.lua
```

## config surface (the ONLY config surface)

file: `config.user.lua` (gitignored; `config.user.sample.lua` is the template)

which file: `-c/--config <path>` > `$NVME_CONFIG` > `./config.user.lua`

```lua
return {
  qemu = {
    amd64 = { bin = "..." },   -- qemu-system-x86_64
    s390x = { bin = "..." },   -- qemu-system-s390x
    img   = "...",             -- qemu-img
  },
  build = {
    nix = false,               -- true: always nix develop; unset: auto
    libvfn_src = "...",        -- else pinned build.zig.zon dependency
  },
}
```

check it: `makac doctor nvmecheck` (says WHAT resolved from WHERE + existence
checks + advice per failure).

## env vars that still exist (on purpose)

- `NVME_CONFIG` — which config file (the one config knob)
- `MAKAC_IMG_VERBOSE=1` — stream guest serial during base-image build
- `NVME_BDF` — harness → guest: controller BDF. never set by hand.

## first run / watching slow things

```sh
MAKAC_IMG_VERBOSE=1 ./nvme-check.lua tp4176 -w smoke
tail -f .makac/qemu/img/<image>/serial.log
```

## state on disk (all gitignored, all disposable)

- `.makac/vm-images/` — live disks (`*-live.qcow2`), per-batch raw NVMe disks
- `.makac/qemu/img/` — base-image build state + serial.log
- `logs/`
- `rm -rf .makac` = full reset (images rebuild on next run)

## docs site

```sh
nix develop .#site -c mdbook serve site --port 3000   # http://localhost:3000
```
