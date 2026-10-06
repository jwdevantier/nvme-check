# NVMe 1.4 mandatory-baseline tests

Black-box checks of the **mandatory** NVMe over PCIe 1.4 baseline, driven
through libvfn on a vfio-bound controller. The checklist is
`~/nvme-1.4.poc.overview.md`; this suite implements the device-facing half of
it and deliberately omits everything the overview marks optional (Format NVM,
SGL, CMB/PMR, telemetry, reservations, firmware download, ...).

## What it needs

- A single controller with a 512-byte-LBA namespace (the workflow declares
  `logical_block_size = 512` and a fresh 64M raw disk).
- DMA buffers that are page-aligned and a page multiple in length — the
  iommufd backend rejects anything else. `vfntest.pageBuffer` handles this.

## Batch

One program, one VM session, a series of `test {}` blocks. They run in
declaration order over one controller; the queue/I/O tests come last because
Set Features Number of Queues is only legal while no I/O queue exists.

| Test | Overview | Covers |
|---|---|---|
| `transport registers and controller enable state` | §0 | CAP/VS/CC/CSTS/AQA/ASQ/ACQ readable, CC.EN + RDY, IOSQES/IOCQES, VS ≥ 1.4 |
| `transport one memory BAR and MSI-X capability` | §0 | BAR0 is the only memory BAR (no BAR2/4), MSI-X capability present |
| `transport interrupt masking INTMS INTMC` | §0 | INTMS sets / INTMC clears mask bits |
| `admin Identify Controller mandatory fields` | §5 | VER, SQES/CQES, NN, VWC, SUBNQN, SN/MN, ... |
| `admin Identify Namespace mandatory fields` | §5 | NSZE/NCAP/NUSE, NLBAF/FLBAS, LBAF0 size, no metadata |
| `admin Identify Active Namespace ID list` | §5 | CNS 02h lists NSID 1 |
| `admin Identify Namespace Identification Descriptor list` | §5 | CNS 03h descriptors well-formed |
| `admin Get Features mandatory IDs` | §2 | FID 01/02/04/05/07/0A/0B |
| `admin Set/Get Features reserved FID rejected` | §2 | unknown FID → Invalid Field + DNR |
| `admin Set/Get Features Number of Queues` | §0/§2 | Set/Get 07h agree |
| `admin Get Log Page mandatory IDs` | §3 | 01h Error Info, 02h SMART/Health, 03h Firmware Slot |
| `admin Async Event Request and Abort` | §1 | AER 0Ch aborted by Abort 08h (both mandatory) |
| `admin Create and Delete IO CQ and SQ` | §1 | 05h/01h create, 00h/04h delete |
| `io Write Read Flush PRP round-trip` | §4 | NVM 01h/02h/00h over PRP1/PRP2 + PRP list |

The spec definitions are pure (no device, no libvfn calls), live in
`spec.zig`, and are unit-tested on the host (`zig build test`).

## Run

```sh
zig build test                 # host-only spec tests (no device, no makac)

./nvme-check.lua nvme14
./nvme-check.lua nvme14 --list
```

The harness selects the controller; the batch reads its BDF from `$NVME_BDF`.

## Notes

- VS/Identify VER are asserted `>= 1.4` rather than `== 1.4`: the mandatory
  *behavior* is the baseline, and a newer controller is still conformant.
- `nvme_init()` performs the reset → admin queue → enable → Identify bring-up
  that the qtest lane's `bringup_datapath.zig` does by hand; this suite is the
  libvfn-lane expression of the same intent, at command granularity.
