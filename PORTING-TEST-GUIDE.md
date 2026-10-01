# Porting the TP4176 NVMe test suite

Precursor notes for porting the Odin `tp4176` suite into this repo using a
different toolchain. This document records **where everything lives** and **how
the tests are exercised against a live VM today**. No port has been done yet.

---

## 1. Source of truth: the Odin variant

`~/repos/nvme-tests` — Odin `core:testing` suites driving an NVMe controller
through [libvfn](https://github.com/SamsungDS/libvfn) over the admin queue of a
vfio-bound controller in a QEMU guest.

```
~/repos/nvme-tests/
├── build.sh                 # the only build entrypoint: ./build.sh <feature>
├── BUILD_CONF.sh            # optional config sourced by build.sh
├── BUILD_CONF.SAMPLE.sh
├── libvfn/                  # git submodule -> libvfn.odin (Odin FFI wrapper)
├── flake.nix                # Odin dev shell (odin dev-2026-06, ols, sqlite)
├── nix.patches/
├── workflows/templates/     # cloud-init meta-data/user-data templates
├── README.md
└── tp4176/                  # Rate Limiting (QEMU TP4176) suite
    ├── README.md
    └── test.odin
```

- Submodule: `git@github.com:jwdevantier/libvfn.odin.git` (the `vfn` package
  lives at `libvfn/vfn/`, imported as `import vfn "../libvfn/vfn"`).
- Build: `./build.sh tp4176` → `/tmp/tp4176-tests`
  (`odin build tp4176 -build-mode:test -collection:vfn=$VFN_ODIN_ROOT ...`).
  `BUILD_CONF.sh` currently sets `VFN_ODIN_ROOT="$PWD/libvfn"` and
  `VFN_LIB_ROOT="$HOME/repos/libvfn/build/src"`.

**The 12 tests** (`tp4176/test.odin`):

`identify_nvm_rla`, `log_page_structure`, `feature_set_get_roundtrip`,
`disable_clears_rle`, `gen_count_increments`, `invalid_tgt_rejected`,
`invalid_tid_rejected`, `invalid_rlm_rejected`, `soft_limit_accepted`,
`zero_ratios_rejected`, `async_config_rlccn`, `aer_rate_limit_change`.

They are black-box checks of QEMU's TP4176 Rate Limiting emulation against the
NVMe NVM Command Set / TP4176 text.

## 2. The runbook documents (placed elsewhere)

`~/repos/libvfn.odin.notes/` is a scratch directory (not a git repo). It holds
the run instructions:

| Path | Contents |
|---|---|
| `~/repos/libvfn.odin.notes/TEST-STEPS.md` | **The copy-paste runbook** (stop/start VM, compile, `put`, run). The doc to port. |
| `~/repos/libvfn.odin.notes/TEST-GUIDE.md` | Longer guide: qqmgr config, VM boot, cloud-init vfio template, loader/rpath notes, known issues. |
| `~/repos/libvfn.odin.notes/run_tp4176_tests.sh` | Scripted version of the steps (parses the test summary). |
| `~/repos/libvfn.odin.notes/test/vfio.toml` | Snapshot copy of the VM config. |
| `~/repos/libvfn.odin.notes/loader.md` | Why the guest's loader must be invoked explicitly. |

Verbatim duplicates exist under `~/repos/libvfn.odin.backup/`.

## 3. VM configuration

Working config: **`~/repos/qqmgr/vfio.toml`** (the notes copy differs only by
two `-d trace:nvme_*` lines).

- VMs: `[vm.vfio]` (the test VM) and `[vm.vfiobase]` (base it derives from).
- Images: `[img.raw-1]`, `[img.raw-2]`, `[img.boot]`, `[img.bootbase]`.
- Three emulated QEMU NVMe controllers, PCI `1b36:0010`, each with
  `rate-limit=on`: BDFs `0000:00:06.0`, `0000:02:00.0` (default),
  `0000:03:00.0`.
- `qemu_bin = /home/nixos/repos/qemu/build/qemu-system-x86_64` (custom QEMU;
  `qemu-img` comes from the nixpkgs dev shell — the custom tree lacks libaio).
- SSH root on `localhost:2090`; `[qemu].img` points at the nixpkgs `qemu-img`.

## 4. How the tests run today (condensed)

`qqmgr` commands must run inside a nix shell (`nix develop` in
`~/repos/qqmgr`, or `nix develop ~/repos/qqmgr --command`).

```sh
CONF=~/repos/qqmgr/vfio.toml

# 0/1. (Re)start the VM; QEMU edits require a restart.
nix develop --command ./qqmgr -c $CONF stop vfio
nix develop --command ./qqmgr -c $CONF start vfio && sleep 25

# Sanity: expect 3 "QEMU NVM Express Controller [1b36:0010]" + /dev/vfio groups.
nix develop --command ./qqmgr -c $CONF ssh vfio -- 'lspci -nn -d 1b36:0010; ls /dev/vfio'

# 2. Compile the tests on the host (Odin variant — ADAPT for this repo).
cd ~/repos/nvme-tests
export LIBRARY_PATH=~/repos/libvfn/build/src
nix develop --command ./build.sh tp4176        # -> /tmp/tp4176-tests

# 3. Transfer into the guest.
nix develop --command ./qqmgr -c $CONF put vfio /tmp/tp4176-tests /root/tp4176-tests

# 4. Run in the guest through the *guest's* loader.
nix develop --command ./qqmgr -c $CONF ssh vfio -- \
  '/lib64/ld-linux-x86-64.so.2 /root/tp4176-tests'
```

- Controller selected via `NVME_BDF` (default `0000:02:00.0`).
- The explicit loader path is required: host-built binaries bake a Nix store
  `PT_INTERP` that does not exist in the Fedora guest.

## 5. Prior pi sessions

Directory: `~/.pi/agent/sessions/--home-nixos-repos-nvme-tests--/`
(cwd `/home/nixos/repos/nvme-tests`).

| Session | Relevance |
|---|---|
| `2026-08-28T21-18-01-607Z_01a04a3c-…` | Initial suite structure; `build.sh`/`BUILD_CONF.sh` design. |
| `2026-08-29T19-50-55-774Z_01a04f13-…` | tp4176 comment/verification work; user msg #6 explicitly references `~/repos/libvfn.odin.notes/TEST-STEPS.md` and says: *"Only thing you have to adjust for is step 2 — the tests are now located here, in ./tp4176"*. |
| `2026-09-21T06-37-33-998Z_01a0c2af-…` | Trivial ("is ./libvfn a subrepo?"). |

Related session dirs: `--home-nixos-repos-libvfn.odin--`,
`--home-nixos-repos-qqmgr--`, `--home-nixos-notes.human-nvme-test-final--`.

Knowledge-base note `qqmgr_vm_mgmt` covers qqmgr usage, but references a stale
`base.yml` and omits the TP4176 specifics.

## 6. Target repo snapshot (`nvme-check`)

This repo currently has **no feature suites**. Relevant pieces:

- `build.zig` — builds libvfn + ccan from source (no meson), plus two Zig
  executables: `nvme-tests` (`src/main.zig`, header/endianness smoke test) and
  `nvme-probe` (`src/probe.zig`, real `nvme_init` + Identify). A `run` step
  runs the smoke test.
- `src/vfn_c.h`, `src/vfn_shim.c` — C shim for header-only helpers that
  `translate-c` demoted.
- `patches/libvfn-s390x.patch` — squashed BE + non-mmap BAR MMIO + s390x
  support; `flake.nix` applies it and exports `VFN_SRC` (dev shell) or
  `-Dlibvfn-src=`.
- `LIBVFN-BE-FIXES.md` — background on the carried libvfn fixes.

Porting target: add TP4176 suites alongside `src/`, compiled by `build.zig`
against the patched in-tree libvfn, replacing the Odin runner + submodule with
this repo's Zig/C tooling.

## 7. Porting considerations / gotchas

- **DMA buffers** handed to `nvme_admin()`/`iommu_map_vaddr()` must be
  page-aligned and a page multiple in length — the iommufd backend rejects
  unaligned `user_va`/`length` with `EINVAL` before the command is issued.
  Use `mmap`/page-sized allocations (`src/probe.zig` already does this).
- **Single controller for the whole run**: open one `nvme_ctrl` and learn the
  controller ID with an initial Identify (used as the TID for feature
  targeting).
- Tests are **serialized internally with a mutex** (multi-threaded runner,
  shared rate-limit state). In the Odin suite, `testing.fail_now` trap must not
  be used while holding it.
- **Stale result claim**: `TEST-STEPS.md` says "12 tests run; 6 pass, 6 fail".
  That reflects an older QEMU build — per the later session, all tests now pass.
- **Stale step 2**: the runbook's compile step targets
  `~/repos/libvfn.odin/tp4176-tests`; for `~/repos/nvme-tests` it is
  `./build.sh tp4176` (source dir `./tp4176`).
- **Loader/rpath**: host-built binaries need the guest loader invocation
  (`/lib64/ld-linux-x86-64.so.2`). A statically-linked Zig binary (this repo
  supports `-Dstatic`) may avoid this entirely — to be verified.

## 8. Open questions

- What "different set of tools" is the port targeting (Zig test runner vs. a
  C harness vs. scripting around `qqmgr`)?
- Should the VM/qqmgr orchestration be committed here (e.g. a `run-tp4176.sh`),
  or stay external like the Odin `run_tp4176_tests.sh`?
- Which libvfn API surface is needed: raw `nvme_admin()` + cq polling, or the
  Odin wrapper's higher-level helpers?
