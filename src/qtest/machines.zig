//! Per-machine facts for the qtest lane — the things libqos *computes* per
//! platform and we hand-maintain as rows.
//!
//! One row today: x86_64 `pc` (PCI config via ioports CF8/CFC, 256 MiB RAM
//! from 0, BARs in the low PCI hole). A future ppc64/pseries row changes the
//! PCI config mechanism (host-executed RTAS) and needs the TCE hook for
//! datapath (qtest-spapr-put-tce-identity.patch in the research repo).

pub const Row = struct {
    /// the -machine value
    machine: []const u8,
    /// default RAM window (-m 256M): GuestMem bumps within this
    ram_base: u64,
    ram_top: u64,
    /// how config space is reached on the guest bus
    pci_config: enum { x86_ioports },
};

pub const pc: Row = .{
    .machine = "pc",
    .ram_base = 0x0010_0000, // skip low RAM by convention
    .ram_top = 0x1000_0000,
    .pci_config = .x86_ioports,
};

/// Lookup by the NVME_QTEST_MACHINE env value (the driver sets it from the
/// arch row; defaults to "pc" today).
pub fn byName(name: []const u8) ?Row {
    if (std.mem.eql(u8, name, "pc")) return pc;
    return null;
}

const std = @import("std");
