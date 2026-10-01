# libvfn big-endian fixes (s390x)

This document describes the changes needed to make **libvfn** — a userspace
NVMe driver built on VFIO — work on **s390x**, a big-endian architecture, and
in particular against a QEMU-emulated NVMe controller inside an s390x guest.

It covers:

1. a primer on the relevant terminology (MMIO, BARs, doorbells, queues, DMA,
   VFIO/IOMMU, endianness, zPCI, PCI config space);
2. each fix, what it does, why it was needed, and **how it was found**;
3. how the result is verified; and
4. what is *not* yet covered.

The fixes live in a single patch (a squash of the three upstream commits on
top of the pinned revision) applied to a pinned upstream libvfn tree at
build time:

```
patches/libvfn-s390x.patch   # BE register access + non-mmap BAR MMIO + s390x
```

They are applied with `pkgs.applyPatches` in `flake.nix` to the pinned source
`github:SamsungDS/libvfn/ba741f7218eee2b0d89c468502b4e132819dd80f`, and the
result is handed to the Zig build via `$VFN_SRC` / `-Dlibvfn-src=`. No fork of
libvfn is required.

---

## 1. Terminology primer

### 1.1 MMIO (memory-mapped I/O)

Processors talk to devices in one of two ways. **Port I/O** uses dedicated
instructions (x86 `in`/`out`). **Memory-mapped I/O (MMIO)** instead places the
device's control and status registers into the CPU's *physical address space*:
a plain load or store to a particular address is intercepted by the bus and
routed to the device rather than to RAM.

Because MMIO addresses are not ordinary memory, the compiler must not cache,
reorder, or elide those accesses. libvfn therefore accesses them through
`volatile` pointers and dedicated helpers:

```c
static inline leint32_t mmio_read32(void *addr)
{
        return *(const volatile leint32_t __force *)addr;
}

static inline void mmio_write32(void *addr, leint32_t v)
{
        *(volatile leint32_t __force *)addr = v;
}
```

The `leint32_t` type (a `__bitwise`-annotated `uint32_t`) is a hint that the
value is in **little-endian** byte order; `__force` suppresses the annotation
warning on the raw pointer cast.

### 1.2 BARs (Base Address Registers)

A PCI function declares its MMIO regions through **Base Address Registers** in
its PCI configuration space. Firmware/OS assigns each BAR a base address and
records the region size; the driver then maps the region (in kernel space with
`ioremap`, or in userspace through VFIO `mmap`). An NVMe controller exposes its
register block in BAR0, typically with a 4 KiB register page followed by the
doorbell array.

### 1.3 NVMe in one page

NVMe (NVM Express) is a register-level interface for storage. The pieces that
matter here:

* **Controller registers** in BAR0: `CAP` (64-bit capabilities), `VS`
  (version), `CC` (controller configuration), `CSTS` (controller status),
  `AQA` (admin queue attributes), `ASQ`/`ACQ` (admin submission/completion
  queue base addresses), and the doorbells.
* **Queues.** A **submission queue (SQ)** holds commands the host wants the
  device to execute; each entry is a 64-byte **SQE** (submission queue entry).
  A **completion queue (CQ)** holds results; each entry is a 16-byte **CQE**
  (completion queue entry). Queue pairs are identified by a queue ID. Queue 0
  is the **admin queue pair**, used for controller management (Identify,
  Set Features, Create/Delete I/O queues, …).
* **Submission** is: build an SQE in host memory, advance the SQ tail, and ring
  the SQ doorbell. **Completion** is the device writing a CQE into host memory;
  the host consumes it and rings the CQ head doorbell.

### 1.4 Doorbells

A **doorbell** is a write-only MMIO register the host uses to notify the device
that a queue has moved. There are two per queue:

* the **SQ tail doorbell**: "I have added commands up to this index";
* the **CQ head doorbell**: "I have consumed completions up to this index".

Their addresses are computed from the BAR and the doorbell stride (`DSTRD`,
from `CAP`): for queue `qid`, the SQ tail is at
`BAR0 + 0x1000 + 2*qid*(4 << DSTRD)` and the CQ head at
`BAR0 + 0x1000 + (2*qid+1)*(4 << DSTRD)`. A doorbell write is a *doorbell
ring*; it is the event that makes the device look at a queue. If the doorbell
never reaches the device, the device never processes the command and the host
waits forever for a completion.

### 1.5 DMA

The device does not read its SQEs from registers; it **DMA**-reads them from
host memory, and DMA-writes CQEs back. The host must publish that memory to the
device — either as a physical address or, under an IOMMU, as an **IOVA**
(I/O virtual address) that the IOMMU translates to a physical page.

### 1.6 VFIO and the IOMMU

**VFIO** is the Linux facility that lets a userspace process drive a device
directly. The process:

1. opens a **VFIO container** and adds the device's **IOMMU group** to it;
2. selects an IOMMU type (type1) and learns the usable IOVA range;
3. maps host buffers into the container with `VFIO_IOMMU_MAP_DMA`, obtaining
   IOVAs to program into the device;
4. accesses the device's BARs and config space through the device fd.

libvfn wraps all of this. On a modern kernel it prefers the **iommufd**
backend, falling back to the classic **vfio type1** backend. On s390x the vfio
backend is used.

### 1.7 Endianness

* **Little-endian (LE)**: the least-significant byte is stored at the lowest
  address (x86-64, aarch64 — both little-endian).
* **Big-endian (BE)**: the most-significant byte is at the lowest address
  (s390x).

**PCI configuration space and all NVMe registers are defined to be
little-endian**, regardless of the host CPU. On a BE host, every multi-byte
value read from or written to a device must be byte-swapped. libvfn provides
`cpu_to_le32()` / `le32_to_cpu()` (and 16/64-bit variants) for exactly this. A
common failure mode is to apply those conversions to *some* accesses but not
others, or to apply them inconsistently.

### 1.8 PCI configuration space and bus master

PCI configuration space is a 256-byte per-function block. The **`PCI_COMMAND`**
register lives at offset `0x04` and is a 16-bit little-endian word:

* bit 0 — I/O space enable
* bit 1 — memory space enable
* **bit 2 — bus master enable**

A device may not initiate DMA unless **bus master** is enabled. Firmware usually
enables it; a kernel driver sets it on probe and the PCI core clears it on
unbind. A userspace driver (libvfn) must therefore set it again after taking
over the device.

### 1.9 s390x / zPCI

s390x is IBM's big-endian mainframe architecture. PCI on s390x is **zPCI**, and
it is unusual:

* **BARs are not memory-mapped into the CPU address space.** They are accessed
  through the `pcilg` (PCI Load) and `pcistg` (PCI Store) instructions. There is
  no page of RAM that "is" the BAR.
* Because of this, the Linux kernel compiles out BAR `mmap` support on s390:
  `drivers/vfio/pci/Kconfig` contains

  ```
  config VFIO_PCI_MMAP
          def_bool y if !S390
  ```

  So a VFIO BAR region never advertises `VFIO_REGION_INFO_FLAG_MMAP`, and
  `mmap()` of it fails with `EINVAL`. The only userspace access is
  `pread()`/`pwrite()` on the VFIO device fd.
* zPCI provides its own IOMMU, and QEMU emulates both the function and its
  IOMMU (through `pcilg`/`pcistg`, the CLP instructions, and the `rpcit`
  "refresh PCI translation" instruction).

### 1.10 libvfn

libvfn is a C library that implements an NVMe driver in userspace on top of
VFIO. The calls used by the test here are `nvme_init()` (reset, configure and
enable the controller, then Identify) and `nvme_admin()` (issue an admin
command). It has an MMIO layer (`support/mmio.h`), a VFIO PCI layer
(`vfio/pci.c`), an IOMMU layer (`iommu/`), and an NVMe core (`nvme/`).

---

## 2. The goal and the setup

The goal was to drive a **QEMU-emulated NVMe controller from inside an s390x
guest**, from a static, self-contained binary, so that big-endian bugs in the
QEMU device model (and in any userspace driver) would surface. libvfn is
compiled for s390x **entirely with the Zig build system** (`build.zig`), with
no meson, so that it can be cross-compiled to a static `s390x-linux-musl`
binary from the x86-64 host. A small Zig program (`src/probe.zig`) links
libvfn, calls `nvme_init()` and an Identify, and prints the controller's
vendor/SSVID/serial/model. A `makac` test builds that probe on the host, ships
it into the guest, binds the controller to `vfio-pci`, runs it, and asserts on
its exit code.

---

## 3. The fixes

### Fix 1 — s390x architecture support (compile-time)

**Files:** `include/vfn/support/barrier.h`, `include/vfn/support/ticks.h`,
new `include/vfn/support/arch/s390x/tod.h`, new
`src/support/arch/s390x/tod.c`, plus meson wiring
(`include/vfn/support/meson.build`, `src/support/meson.build`, and new
`arch/s390x/meson.build` files).

**What it does.** libvfn only knew x86-64 and aarch64 and emitted
`#error unsupported architecture` for anything else. This fix adds the s390x
branch:

* **Barriers** (`barrier.h`): s390x is weakly ordered, so real memory barriers
  are required. The patch defines `rmb()`, `wmb()` and `mb()` as
  `__sync_synchronize()` (a full compiler/hardware barrier) and keeps
  `dma_rmb()` as a plain compiler `barrier()`.
* **Timestamps** (`ticks.h` + `arch/s390x/tod.{h,c}`): instead of inline
  assembly on the s390x Time-of-Day clock, `get_ticks_arch()` uses
  `clock_gettime(CLOCK_MONOTONIC_RAW)` in nanoseconds and
  `get_ticks_freq_arch()` reports `1000000000`. Ticks are only used for
  timeouts, so a portable source is sufficient.
* **meson wiring**: registers the new arch directory so the tree also builds
  with meson. (Our Zig build uses its own source list; the meson edits keep the
  patch self-consistent.)

**Why it was needed.** Without it, libvfn cannot be compiled for s390x at all:
the preprocessor `#error`s.

**How it was found.** Immediately, on the first cross-compile attempt. The
errors pointed at `barrier.h` and `ticks.h`. (An earlier attempt used shadow
headers in our tree; those were folded into this patch against the pinned
source, so nothing outside libvfn is overridden.)

> Note: an initial build failure from ccan including `<sys/unistd.h>` was **not**
> a libvfn problem — it was a `build.zig` configuration bug
> (`HAVE_SYS_UNISTD_H` not being defined for musl) and was fixed in
> `build.zig`, not in the patch.

### Fix 2 — 64-bit MMIO helpers were little-endian-only

**File:** `include/vfn/support/mmio.h`
(`mmio_lh_read64`, `mmio_lh_write64`, `mmio_hl_write64`).

**What it does.** These helpers access a 64-bit register as two 32-bit MMIO
operations (some hardware requires a specific 32-bit access order). The
original code reassembled/split the halves assuming a little-endian host:

```c
/* original */
static inline leint64_t mmio_lh_read64(void *addr)
{
        uint32_t lo, hi;
        lo = *(const volatile uint32_t *)addr;
        hi = *(const volatile uint32_t *)((char *)addr + 4);
        return (leint64_t __force)(((uint64_t)hi << 32) | lo);
}
```

On a BE host this is wrong: the *first* 32-bit load (the low address, which is
the low word in the little-endian register) becomes the *high* half of the
native 64-bit image, and vice versa. The write helpers had the mirror bug
(`(leint32_t)v` and `v >> 32` split the native `leint64_t` without conversion).

The fix reassembles according to host byte order and converts correctly on
write:

```c
/* patched */
static inline leint64_t mmio_lh_read64(void *addr)
{
        uint32_t a, b;
        uint64_t v;
        a = mmio_read32(addr);            /* low word first */
        b = mmio_read32((char *)addr + 4);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
        v = ((uint64_t)b << 32) | a;
#else
        v = ((uint64_t)a << 32) | b;
#endif
        return (leint64_t __force)v;
}

static inline void mmio_lh_write64(void *addr, leint64_t v)
{
        uint64_t x = le64_to_cpu(v);
        mmio_write32(addr, cpu_to_le32((uint32_t)x));
        mmio_write32((char *)addr + 4, cpu_to_le32((uint32_t)(x >> 32)));
}

static inline void mmio_hl_write64(void *addr, leint64_t v)
{
        uint64_t x = le64_to_cpu(v);
        mmio_write32((char *)addr + 4, cpu_to_le32((uint32_t)(x >> 32)));
        mmio_write32(addr, cpu_to_le32((uint32_t)x));
}
```

**Why it was needed.** `CAP` and `CMBMSC` are read via `mmio_read64()`, and
`ASQ`/`ACQ` are written via `mmio_hl_write64()`. If the halves are swapped, the
driver reads a nonsense `CAP` and programs the device with a nonsense admin
queue address.

**How it was found.** Because the failure happened before any device was
involved, it was isolated with a **device-free unit test run under
`qemu-s390x` user-mode emulation**. A test helper placed the raw little-endian
bytes of a known register (`CAP = 0x4008200f0107ff`, i.e. bytes
`ff 07 01 0f 20 08 40 00`) into memory and decoded them through libvfn's own
helpers. On the LE host the decode was correct; on s390x it was not:

```
host (LE):   read64 = 0x4008200f0107ff   (correct)
s390x (BE):  read64 = 0xf0107ff00400820  (WRONG)
             read64_raw = 0x20084000ff07010f
```

After the fix, both hosts produce `0x4008200f0107ff`, and a matching write
round-trip test produces the expected little-endian bytes
(`88 77 66 55 44 33 22 11` for `0x1122334455667788`) on both.

### Fix 3 — `pci_set_bus_master` never enabled bus master on big-endian

**File:** `src/vfio/pci.c`, function `pci_set_bus_master()`. **This was the
critical fix — the one that turned "hangs forever" into "works".**

**What it does.** Before doing DMA, libvfn sets the PCI bus-master bit in
`PCI_COMMAND`. The original code read the config word with a raw
`pread()` and OR-ed the bit in native order:

```c
/* original */
static int pci_set_bus_master(struct vfio_pci_device *pci)
{
        uint16_t pci_cmd;
        if (vfio_pci_read_config(pci, &pci_cmd, sizeof(pci_cmd), PCI_COMMAND) < 0)
                return -1;
        pci_cmd |= PCI_COMMAND_MASTER;
        if (vfio_pci_write_config(pci, &pci_cmd, sizeof(pci_cmd), PCI_COMMAND) < 0)
                return -1;
        return 0;
}
```

`vfio_pci_read_config()`/`write_config()` copy raw bytes to/from the device's
configuration space, which is **little-endian**. Interpreting those bytes as a
native `uint16_t` on a BE host byte-swaps the value. The subsequent
`|= PCI_COMMAND_MASTER` then sets the wrong bit of the swapped representation,
and the write reproduces the original bytes unchanged — so **bus master is
never enabled**.

Concretely, a controller whose `PCI_COMMAND` is `0x0402` (little-endian) has
memory space enabled (bit 1). On s390x the raw word is read as `0x0204`;
OR-ing `0x0004` leaves `0x0204` (that bit is already set in the swapped view),
and the write stores the same bytes back. `PCI_COMMAND` stays `0x0402`, and
**bit 2 — bus master — remains clear**.

The fix treats configuration space as little-endian:

```c
/* patched */
static int pci_set_bus_master(struct vfio_pci_device *pci)
{
        leint16_t le_cmd;
        uint16_t pci_cmd;

        if (vfio_pci_read_config(pci, &le_cmd, sizeof(le_cmd), PCI_COMMAND) < 0)
                return -1;

        /* PCI config space is little endian regardless of host byte order */
        pci_cmd = le16_to_cpu(le_cmd) | PCI_COMMAND_MASTER;
        le_cmd = cpu_to_le16(pci_cmd);

        if (vfio_pci_write_config(pci, &le_cmd, sizeof(le_cmd), PCI_COMMAND) < 0)
                return -1;
        return 0;
}
```

**Why it was needed.** With bus master disabled the device is forbidden from
initiating DMA. The controller receives the doorbell, tries to fetch the SQE,
and the access fails with a bus-master/MEMTX error. No completion is ever
posted. libvfn's completion loop (`nvme_cq_get_cqes()` in `src/nvme/queue.c`)
spins forever waiting for a CQE, so `nvme_init()` hangs. On x86-64 the same
code works by accident, because the host is little-endian like the config
space.

**How it was found.** This was the hardest part and took an escalating set of
tools:

1. **Observed the symptom in the guest.** On amd64 the probe passed; on s390x
   it hung. Adding libvfn's runtime debug logging (via a shim calling
   `logv_set(LOG_DEBUG)`) showed it got through VFIO/IOMMU setup and the
   BAR mappings and then stalled in the completion wait.
2. **Checked the BAR path first.** The s390x run failed earlier with
   `vfio/pci: failed to map bar region`; that led to Fix 4 (below). Once BAR
   access worked, the symptom became a hang.
3. **Confirmed MMIO was reaching the device.** QEMU trace events
   (`pci_nvme_mmio_*`) showed every register write and the doorbell
   (`pci_nvme_mmio_doorbell_sq sqid 0 new_tail 1`), so the doorbell was fine.
4. **Instrumented QEMU.** Temporary `fprintf` tracing was added to the s390x
   IOMMU and NVMe paths (`reg_ioat`, `rpcit_service_call`,
   `s390_pci_update_iotlb`, `s390_pci_iommu_xlate`, `nvme_process_sq`,
   `nvme_addr_read`) and QEMU was rebuilt. This showed that the guest *did*
   program the IOTLB correctly, that the NVMe model entered
   `nvme_process_sq()` with the right admin queue address, and that the SQE
   read failed:
   ```
   QPCDBG process_sq sqid=0 head=0 tail=1 dma_addr=0x100031000
   QPCDBG nvme_addr_read addr=0x100031000 size=64 -> 2   (MEMTX_ERROR)
   QPCDBG process_sq READ-FAILED addr=0x100031000
   ```
5. **Ruled out the IOMMU.** The IOTLB had the right mapping
   (`iotlb MAP iova=0x100031000 translated=0x4140000 perm=0x3`), and
   `s390_translate_iommu()` was never even called for the failing address — the
   failure happened *before* translation.
6. **Found the gate.** Printing the device's `PCI_COMMAND` at the point of the
   failed access gave `pci_cmd=0x402`: memory space enabled, **bus master
   clear**. That pointed straight at `pci_set_bus_master()`, and the
   byte-swap analysis above followed.

### Fix 4 — BAR access without `mmap` (pread/pwrite backend)

**Files:** `src/vfio/pci.c` (`vfio_pci_map_bar`, `vfio_pci_unmap_bar`, plus a
small synthetic-region registry) and `include/vfn/support/mmio.h`
(`mmio_read32`/`mmio_write32`).

**What it does.** `vfio_pci_map_bar()` normally `mmap()`s a BAR region and
returns a real pointer. On s390x that is impossible (see §1.9), so the patch
adds a fallback:

* a reserved `PROT_NONE` virtual-address window is allocated
  (`mmap(NULL, span, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE)`);
* if the region does not advertise `VFIO_REGION_INFO_FLAG_MMAP` (on
  s390x/zPCI it never does; see §1.9), a slot in that window is handed out
  as a **synthetic address** for the region (recording the device fd, the
  region's file offset, and its size). Keying the fallback off the flag
  rather than an `mmap()` failure means a genuine `mmap()` error on a
  mappable region (ENOMEM, ...) still fails loudly;
* `mmio_read32()`/`mmio_write32()` first ask
  `vfn_mmio_synth_read()`/`vfn_mmio_synth_write()` whether the address is
  synthetic; if so they perform `pread()`/`pwrite()` on the device fd at
  `region_file_offset + offset_in_region` instead of dereferencing it. The
  accessors return a three-state result (`NOT_SYNTH`/`DONE`/`ERROR`): a
  failed access on a synthetic address is never mistaken for a non-synthetic
  one (which would dereference the `PROT_NONE` window), accesses are bounded
  against the recorded region size, and a short/failed read yields the
  conventional all-ones error value rather than uninitialized data;
* `vfio_pci_unmap_bar()` just releases the slot for synthetic regions.
  Slots are *owned*: the mapping device records them in its
  `vfio_pci_device.synth_bars[]` list, allocation is serialized with a
  mutex, unmap only releases regions owned by that device (an in-arena
  address never reaches `munmap()`), and `vfio_pci_close()` drains any
  leaked mappings before closing the device fd.

The window is `PROT_NONE` on purpose: any code path that forgets to go through
the MMIO helpers and dereferences a synthetic address faults immediately rather
than silently corrupting memory.

(During development a `VFN_SYNTH_BAR=1` environment knob forced the synthetic
path even where `mmap()` would work, to validate the backend on amd64; it has
since been removed.)

**Why it was needed.** Without it, `vfio_pci_map_bar()` returns `NULL` on
s390x (`mmap` fails with `EINVAL`) and libvfn aborts controller setup. This is
a *platform* difference, not a bug in libvfn's logic: s390x VFIO simply has no
mappable BAR. (The `pread`/`pwrite` approach is exactly how the kernel exposes
those regions, and how libvfn already accessed PCI configuration space.)

**How it was found.** The s390x probe failed with
`vfio/pci: failed to map bar region` and `errno=22`. Printing the region info
showed `bar0 flags=0x3`:

```
flags = VFIO_REGION_INFO_FLAG_READ | VFIO_REGION_INFO_FLAG_WRITE   (0x3)
```

with `VFIO_REGION_INFO_FLAG_MMAP` (0x4) absent. Reading the guest kernel's
`drivers/vfio/pci/Kconfig` explained why: `VFIO_PCI_MMAP` is off on S390, and
s390x BARs are `pcilg`/`pcistg`-only. Before writing the backend, the core
assumption was validated directly: on s390x, `pread()` of BAR0 returned bytes
**identical** to the amd64 `mmap()` read —

```
s390x: CAP: pread rc=8 le=0x4008200f0107ff ... mmio=0x0
amd64: CAP: pread rc=8 le=0x4008200f0107ff ... mmio=0x4008200f0107ff
```

so `pread`/`pwrite` are byte-for-byte equivalent to the mapped access. The
backend itself was then validated on amd64 via a (since removed)
`VFN_SYNTH_BAR=1` knob: libvfn completed `nvme_init` and Identify through the
synthetic path.

---

## 4. How everything fits together

* **Fix 1** is required just to build.
* **Fix 2** is required for correct 64-bit register access on any BE host.
* **Fix 3** is required for the device to be allowed to DMA at all on BE; it
  is what made the end-to-end path work.
* **Fix 4** is required because s390x VFIO cannot map BARs; it is what made
  MMIO possible in the first place.

Three of the four are genuine big-endian bugs in libvfn (Fixes 2, 3, and the
fact that Fix 4's absence only manifests on s390x). Fix 3 in particular is the
kind of bug the whole exercise was meant to surface: code that is "obviously
correct" on little-endian and silently broken on big-endian.

---

## 5. Verification

### 5.1 Device-free endianness tests (qemu-user)

Run the smoke binary on the host and under `qemu-s390x`:

```
# host (LE)
mmio read32=0xf0107ff read64_raw=0x4008200f0107ff read64=0x4008200f0107ff (want 0x4008200f0107ff)
mmio write lh=8877665544332211 hl=8877665544332211 want=8877665544332211

# s390x (BE)
mmio read32=0xf0107ff read64_raw=0xff07010f20084000 read64=0x4008200f0107ff (want 0x4008200f0107ff)
mmio write lh=8877665544332211 hl=8877665544332211 want=8877665544332211
```

### 5.2 Real device, both architectures

Against a QEMU-emulated NVMe bound to `vfio-pci`:

```
[s390x]  vfio/pci: pci class code is 0x010802
[s390x]  iommu/vfio: iova range 0 is [0x100000000; 0x17fffffff]
[s390x]  CAP: pread rc=8 le=0x4008200f0107ff be=0xff07010f20084000 mmio=0x4008200f0107ff
[s390x]  nvme_init + Identify OK on 0001:00:00.0
[s390x]    vid=0x1b36 ssvid=0x1af4
[s390x]    sn=zig
[s390x]    mn=QEMU NVMe Ctrl
         PASS

[amd64]  nvme_init + Identify OK on 0000:01:00.0
         PASS
```

A zero exit code means userspace actually drove the device: it mapped the BAR,
reset and configured the controller, programmed the admin queue, rang the
doorbell, the device DMA-read the SQE and DMA-wrote a completion, and libvfn
parsed the Identify Controller data. All of this was verified with a **pristine
QEMU** — the debug instrumentation used during the investigation was reverted
before the final runs.

### 5.3 Backend isolation matrix (on amd64)

| IOMMU backend | BAR access | result |
|---|---|---|
| iommufd | mmap | pass |
| iommufd | synthetic (forced fallback, dev-time knob) | pass |
| vfio type1 (`VFN_IOMMU_FORCE_VFIO=1`) | mmap | pass |

This showed the synthetic BAR backend and libvfn's vfio type1 IOMMU path are
both correct in isolation, before the s390x-specific bugs were addressed.

---

## 6. Scope and what is *not* tested

Tested:

* `nvme_init()` plus a single Identify Controller admin command, on amd64 and
  s390x, both passing;
* the endianness helpers on both endiannesses (device-free);
* the synthetic BAR backend and both IOMMU backends on amd64.

Not tested:

* **namespace I/O** (I/O queue pair creation, reads/writes, PRP/SGL data
  transfer);
* **real passed-through hardware on physical s390x** — everything here is
  against QEMU's emulated zPCI device and emulated zPCI IOMMU. A real device
  uses a real IOMMU and is a different (and in some ways simpler) path;
* other libvfn features (persistence, I/O queue depth stress). Shadow
  doorbells were silently broken on big-endian (the buffer contents were
  stored/loaded in native byte order): now fixed in
  `patches/libvfn-s390x.patch`.
  `nvme-tests/tests/03_dbbuf.lua` covers this explicitly, on both
  endiannesses: the probe self-checks `nvme_try_dbbuf()`'s byte order without
  a device, then asserts the device recorded the submitted tail in the shadow
  EventIdx, with a `dbcs=off` control. (The admin queue alone cannot catch a
  wrong shadow *store*: QEMU mirrors the MMIO doorbell into the shadow buffer
  for qid 0, which is why the encoding is pinned by the device-free self-test.
  A wrong event-index *load* hangs the queue and is caught either way.) **CMB is not merely untested but incompatible
  with non-mappable BARs**: it is used as ordinary memory (queue entries are
  copied into it, and its pages are pinned into the IOMMU), which a synthetic
  `pread`/`pwrite`-backed region cannot provide; `nvme_configure_cmb()` now
  refuses it explicitly (`ENOTSUP`) when the CMB BAR is synthetic.

A natural next step would be to extend the probe to create an I/O queue pair
and perform a read/write against the emulated namespace, which would exercise
the data-path endianness as well.

---

## 7. Glossary

| Term | Meaning |
|---|---|
| **MMIO** | Memory-mapped I/O; device registers placed in the CPU physical address space and accessed with ordinary loads/stores. |
| **BAR** | Base Address Register; a PCI config register describing an MMIO region of a device. |
| **NVMe** | NVM Express; a register-level storage interface. |
| **SQ / CQ** | Submission queue / completion queue. |
| **SQE / CQE** | Submission queue entry (64 bytes) / completion queue entry (16 bytes). |
| **Admin queue** | Queue pair 0, used for controller management. |
| **Doorbell** | Write-only MMIO register used to notify the device that a queue has moved. |
| **DSTRD** | Doorbell stride, from `CAP`; scales doorbell spacing. |
| **DMA** | Direct Memory Access; the device reading/writing host memory itself. |
| **IOVA** | I/O virtual address; the address a device uses, translated by an IOMMU. |
| **IOMMU** | I/O memory management unit; translates IOVAs to physical addresses. |
| **VFIO** | Linux framework for userspace device drivers, including DMA/IOMMU setup. |
| **iommufd** | The newer kernel interface for IOMMU management; libvfn's preferred backend. |
| **type1** | The classic VFIO IOMMU (DMA mapping) backend. |
| **zPCI** | PCI on s390x; BARs are accessed via `pcilg`/`pcistg`, not memory-mapped. |
| **PCI config space** | Per-function 256-byte configuration block; little-endian. |
| **`PCI_COMMAND`** | Config register at offset `0x04`; bit 2 is bus-master enable. |
| **LE / BE** | Little-endian / big-endian byte order. |
| **bus master** | Permission for a PCI device to initiate DMA; must be enabled in `PCI_COMMAND`. |
