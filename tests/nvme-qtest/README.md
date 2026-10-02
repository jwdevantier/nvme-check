# nvme-qtest — qtest-protocol port of QEMU's nvme-test.c

Each test here is a 1:1 port of a test function in QEMU's
`tests/qtest/nvme-test.c` (the in-tree qtest suite), re-expressed as a plain
Zig test. The differences from upstream are deliberate:

| | upstream (in-tree) | here |
|---|---|---|
| test body | C + glib asserts, via libqtest/libqos | Zig `test {}` |
| protocol client | libqtest | `src/qtest` (~250 lines, protocol is documented in QEMU's `system/qtest.c`) |
| machine setup | qgraph fan-out across machines | fixed `-machine pc`, device at 04.0 |
| runner | meson `make check-qtest` | `./nvme-check.lua nvme-qtest` |

The tests run headless (`-accel qtest`): no guest OS, no RAM boot — MMIO/PIO
are poked directly and virtual time is host-controlled (`clock_step`).

| test | covers |
|---|---|
| `reg-read` | CAP read via 32-bit halves and one 64-bit read (MQES, MPSMAX) |
| `oob-cmb-access` | 2 MiB CMB (BAR2) read-back widths; partially out-of-bounds accesses at the window's last byte |
| `pmr-test-access` | PMRCAP bitfield layout; PMRCTL enable/disable with read-back through BAR4; PMRSTS NRDY transitions |
| `bringup-datapath` | **beyond upstream's nvme-test.c** (port of `nvme-qtest-poc.py`): CC.EN bring-up, admin queues, Identify, IO queue creation, NVMe Write→Read round-trip verified in guest RAM *and* on the backing image (after Flush), Get Features, SMART log, and the Set-Features-after-IO-queues CMD_SEQ_ERROR path |

Scope note: the qtest lane and the vfio lane test different things. Here you
get deterministic virtual time and free fault injection; there you get real
interrupt delivery, shadow doorbells and organic DMA layouts. See
`~/repos/qtest-vs-vfio-research/` for the analysis behind the split.
