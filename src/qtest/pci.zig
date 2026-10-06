//! PCI config-space access for qtest-lane tests. The access mechanism comes
//! from the session's machine row (`row.pci_config`); today that is only x86
//! ioports 0xCF8/0xCFC (what libqos/pci-pc.c does). No BIOS runs under
//! -accel qtest, so tests program BARs and the command register themselves.
//!
//! Adding a machine with a different mechanism (ECAM/RTAS/...) means a new
//! `machines.Row.pci_config` variant plus an arm in the switches below.
//!
//! Scope: bus 0, 32/64-bit BARs in the low 4 GiB PCI hole. Anything needing
//! bridges, bridges' windows or above-4G mapping does not belong here yet.

const qtest = @import("qtest.zig");

const CF8: u16 = 0xCF8;
const CFC: u16 = 0xCFC;

pub const ConfigAddr = struct {
    bus: u8,
    dev: u5,
    func: u3,

    fn dword(self: ConfigAddr, off: u8) u32 {
        return 0x8000_0000 |
            (@as(u32, self.bus) << 16) |
            (@as(u32, self.dev) << 11) |
            (@as(u32, self.func) << 8) |
            @as(u32, off & 0xFC);
    }
};

pub fn configRead32(s: *qtest.Session, a: ConfigAddr, off: u8) qtest.Error!u32 {
    switch (s.row.pci_config) {
        .x86_ioports => {
            try s.out32(CF8, a.dword(off));
            return s.in32(CFC);
        },
    }
}

pub fn configWrite32(s: *qtest.Session, a: ConfigAddr, off: u8, val: u32) qtest.Error!void {
    switch (s.row.pci_config) {
        .x86_ioports => {
            try s.out32(CF8, a.dword(off));
            try s.out32(CFC, val);
        },
    }
}

pub fn configRead16(s: *qtest.Session, a: ConfigAddr, off: u8) qtest.Error!u16 {
    const shift: u5 = @intCast((off & 2) * 8);
    return @truncate(try configRead32(s, a, off) >> shift);
}

pub fn configWrite16(s: *qtest.Session, a: ConfigAddr, off: u8, val: u16) qtest.Error!void {
    const aligned = off & ~@as(u8, 2);
    const cur = try configRead32(s, a, aligned);
    const shift: u5 = @intCast((off & 2) * 8);
    const merged = (cur & ~(@as(u32, 0xFFFF) << shift)) | (@as(u32, val) << shift);
    try configWrite32(s, a, aligned, merged);
}

/// PCI_COMMAND: enable memory space + bus mastering (what qpci_device_enable
/// does, minus the I/O-space bit our devices don't need).
pub fn enable(s: *qtest.Session, a: ConfigAddr) qtest.Error!void {
    try configWrite16(s, a, 0x04, 0x6);
}

/// Assign a 64-bit BAR (all NVMe BARs are 64-bit). `bar` is the BAR index
/// (0, 2, 4); `addr` must be size-aligned. Not bothering with the
/// write-all-ones size probe: our tests know their BAR sizes from the device
/// parameters they passed on the command line.
pub fn assignBar64(s: *qtest.Session, a: ConfigAddr, bar: u8, addr: u64) qtest.Error!void {
    const off: u8 = 0x10 + bar * 4;
    try configWrite32(s, a, off, @truncate(addr));
    try configWrite32(s, a, off + 4, @truncate(addr >> 32));
}
