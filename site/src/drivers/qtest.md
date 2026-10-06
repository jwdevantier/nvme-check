<!-- SPDX-FileCopyrightText: 2026 Jesper Wendel Devantier -->
<!-- SPDX-License-Identifier: BSD-2-Clause -->

# The `qtest` driver

Runs a Zig program directly on the host, which spawns a headless QEMU instance
with `-accel qtest` and drives it over a socket speaking the qtest protocol.
No guest code or VM image is required.

## Using the qtest driver
This example assumes we are creating a new test-suite, possibly exercising
a new version of the specification or a new technical-proposal (TP).

To start, we create `./tests/foo` and write a `workflow.lua` file within,
which returns a data-structure, describing the tests provided by this workflow:

```lua

return {
  -- driver used for all test-cases, unless test specifically
  -- overrides it.
  uses = "nvmecheck:qtest",
  tests = {
    {
      -- a descriptive name
      name = "bringup-datapath",
      -- tag as desired, should generally add 'qtest' and 'fast'
      tags = { "qtest", "fast" },
      -- mark architecture(s) appropriate for this test
      archs = { "amd64" },
      with = {
        -- test program to run, relative to `./tests/<suite>`
        program = "batches/bringup_datapath.zig"
      }
    },
  }
}
```

## Example Program

A qtest-lane program is a host-native Zig test binary that spawns its own
QEMU; it needs nothing from a suite-local helper. The driver exports
`NVME_QTEST_QEMU` / `NVME_QTEST_MACHINE`, `qtest.launch` reads them and supplies
the machine base argv, and the program supplies only the device-side argv
(`-drive`, `-device`, ...):

```zig
const std = @import("std");
const qtest = @import("qtest");

// kill the spawned QEMU if an expect fails
pub const panic = std.debug.FullPanic(qtest.panicHook);

/// The -device argv below places the controller here (bus 0, dev 4, fn 0).
const devfn: qtest.pci.ConfigAddr = .{ .bus = 0, .dev = 4, .func = 0 };
/// BAR0 (16 KiB), which we assign in the low PCI hole — no BIOS under qtest.
const BAR0: u64 = 0xF010_0000;

test "reg-read" {
    const s = try qtest.launch(std.heap.smp_allocator, &.{
        "-drive",  "id=drv0,if=none,file=null-co://,file.read-zeroes=on,format=raw",
        "-device", "nvme,addr=04.0,drive=drv0,serial=foo",
    });
    defer s.deinit();

    try qtest.pci.enable(s, devfn);
    try qtest.pci.assignBar64(s, devfn, 0, BAR0);

    const cap = try s.read(u64, BAR0 + 0x00);
    try std.testing.expectEqual(@as(u64, 0x7ff), cap & 0xffff);
}
```

Note that the exit code determines success or failure, and that Zig returns
a non-zero exit code in case one or more tests are failing. In case a test
fails, the captured test output (stdout) is also printed.

Generally, test programs should use a separate `test "name" {}` block per
test and use the `std.testing.*` functions for assertions.

Finally, note `pub const panic = ...` — this ensures that the QEMU process
is properly killed if the program encounters a panic.

## The client API

The client lives in `src/qtest`, imported as `qtest`. It speaks QEMU's
line-based qtest protocol, but you don't talk to the protocol directly:
`qtest.launch` returns a `*Session` — a live connection to the spawned machine —
and you drive the machine through the session's methods. The session owns the
qtest socket, a QMP monitor socket, and the machine facts (including a
guest-memory allocator); `deinit` quits QEMU and cleans up:

```zig
const s = try qtest.launch(std.heap.smp_allocator, extra_argv);
defer s.deinit();
```

Each request gets exactly one reply. A `FAIL`/`ERR` reply — or a malformed
one — becomes `error.Protocol`; a reply that never arrives becomes
`error.Timeout`. Asynchronous `IRQ` lines may interleave and are absorbed
rather than handed back.

### Memory

Guest memory is addressed by guest-physical address (`u64`). Single values:

| Call                  | Meaning |
|-----------------------|----------------------------------------------------------|
| `read(T, addr)`       | read one value of type `T` — `u8`, `u16`, `u32` or `u64` |
| `write(T, addr, val)` | write one value of type `T`                              |

The width is the type, not a suffix in the name: `read(u32, addr)` is a 32-bit
read.

Larger buffers (queues, PRP lists, command structures) use the bulk calls,
which copy between host memory and guest memory:

| Call | Meaning |
|--------------------------------------------------------|------------------------------------------------------------|
| `memRead(addr, dest)` / `memWrite(addr, source)`       | bulk copy, hex on the wire                                 |
| `memReadB64(addr, dest)` / `memWriteB64(addr, source)` | bulk copy, base64 on the wire (cheaper for large transfers)|
| `memset(addr, size, pattern)`                          | fill guest memory with a byte                              |

**NOTE:** `dest` and `source` are Zig slices, so they carry their own length: `dest.len`
is how many bytes to read, `source.len` how many to write.

### Registers

Device registers are memory-mapped: they sit at the device's BAR addresses and
are read and written with the same calls as any other memory —
`read(u32, bar + offset)`, `write(u32, bar + offset, val)`. (See I/O ports for
enabling a device and assigning its BARs.)

### Allocating guest memory

The machine is assigned a chunk of memory. For convenience, use the provided
bump allocator to "reserve" guest memory. Use it for anything the device will
DMA to or from: queues, PRP lists, data buffers etc.

```zig
const gmem = s.guestMem();
const asq = try gmem.alloc(4096, 4096);       // page-aligned address
const prp = try gmem.allocFor([4096]u8, 1);   // space for n items of T
```

### I/O ports

x86 has a second address space, I/O ports, reached with `in32(port)` and
`out32(port, val)` (32-bit). PCI configuration rides on it: `qtest.pci.enable(s,
a)` and `qtest.pci.assignBar64(s, a, bar, addr)` — as in the example above, a
device's registers are unreachable until its BARs are assigned.

### Time

`clockStep(ns)` advances the emulated clock; under `-accel qtest`, time only
moves when you tell it to.

### Interrupts

`irqLevel(n)` returns the last level seen for IRQ `n` — `true` raised, `false`
lowered — or `null` if it has never changed. Level changes arrive
asynchronously and are cached as the session reads.

### QMP

`qmpExecute(name, args_json)` sends one QMP command over its own socket and
returns the raw JSON reply, skipping events; `args_json` is the command's
`"arguments"` value, or `null`. Most tests don't need it.
