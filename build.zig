const std = @import("std");
const editor = @import("build/editor.zig");

/// Build libvfn (and ccan) from source with the Zig build system — no meson.
/// This is what makes cross-compilation (e.g. an s390x big-endian target)
/// and static linking work from any host.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const static = b.option(bool, "static", "link the executable statically") orelse false;
    const program = b.option([]const u8, "program", "Zig test root to build as a guest test binary");
    const program_name = b.option([]const u8, "program-name", "output name for -Dprogram (default: the file stem)");

    // Where the libvfn sources live: the pinned build.zig.zon dependency
    // (the jwdevantier/libvfn fork, upstream + the s390x/BE patch set),
    // unless overridden with -Dlibvfn-src (the harness feeds this from
    // config.user.lua's build.libvfn_src; testlib/lib/config.lua).
    const src_opt = b.option(
        []const u8,
        "libvfn-src",
        "path to a libvfn source tree (default: the pinned zon dependency)",
    );
    const libvfn: std.Build.LazyPath = if (src_opt) |p|
        .{ .cwd_relative = b.pathResolve(&.{ b.build_root.path orelse ".", p }) }
    else
        b.dependency("libvfn", .{}).path(".");
    const vendor: std.Build.LazyPath = b.path("vendor");

    // The only "meson" bits we deliberately carry in-tree: the generated
    // trace events and the crc64 table. They change rarely and pulling in
    // perl/host-tools to regenerate them is not worth it during normal
    // builds. The three config-host.h macros are passed as -D below.
    const define_flags: []const []const u8 = &.{
        "-DHAVE_VFIO_DEVICE_BIND_IOMMUFD",
        "-DHAVE_IOMMU_FAULT_QUEUE_ALLOC",
        "-DNVME_AQ_QSIZE=32",
    };
    const c_flags: []const []const u8 = &.{
        "-std=gnu11",
        "-D_GNU_SOURCE", // meson adds this by default; needed for sched_getcpu etc.
        "-Wall",
        "-Wextra",
        "-Wno-unused-parameter",
        "-fno-strict-overflow",
    };

    // ---------------------------------------------------------------- ccan
    const ccan_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ccan_config = b.addConfigHeader(.{ .include_path = "config.h" }, .{
        .HAVE_ATTRIBUTE_COLD = true,
        .HAVE_ATTRIBUTE_CONST = true,
        .HAVE_ATTRIBUTE_DEPRECATED = true,
        .HAVE_ATTRIBUTE_NONNULL = true,
        .HAVE_ATTRIBUTE_NORETURN = true,
        .HAVE_ATTRIBUTE_PRINTF = true,
        .HAVE_ATTRIBUTE_PURE = true,
        .HAVE_ATTRIBUTE_RETURNS_NONNULL = true,
        .HAVE_ATTRIBUTE_SENTINEL = true,
        .HAVE_ATTRIBUTE_UNUSED = true,
        .HAVE_ATTRIBUTE_USED = true,
        .HAVE_BUILTIN_CHOOSE_EXPR = true,
        .HAVE_BUILTIN_CONSTANT_P = true,
        .HAVE_BUILTIN_CPU_SUPPORTS = !target.result.cpu.arch.isAARCH64(),
        .HAVE_BUILTIN_EXPECT = true,
        .HAVE_BUILTIN_TYPES_COMPATIBLE_P = true,
        .HAVE_CLOCK_GETTIME = true,
        .HAVE_COMPOUND_LITERALS = true,
        .HAVE_ERR_H = true,
        .HAVE_ISBLANK = true,
        .HAVE_STATEMENT_EXPR = true,
        .HAVE_STRUCT_TIMESPEC = true,
        .HAVE_SYS_UNISTD_H = !target.result.abi.isMusl(),
        .HAVE_TYPEOF = true,
        .HAVE_WARN_UNUSED_RESULT = true,
    });
    ccan_mod.addConfigHeader(ccan_config);
    ccan_mod.addIncludePath(libvfn.path(b, "ccan"));
    ccan_mod.addCSourceFiles(.{
        .root = libvfn.path(b, "ccan"),
        .files = &.{
            "ccan/err/err.c",
            "ccan/list/list.c",
            "ccan/opt/helpers.c",
            "ccan/opt/opt.c",
            "ccan/opt/parse.c",
            "ccan/opt/usage.c",
            "ccan/str/str.c",
            "ccan/tap/tap.c",
            "ccan/time/time.c",
        },
        .flags = c_flags,
    });
    const ccan = b.addLibrary(.{
        .name = "ccan",
        .linkage = .static,
        .root_module = ccan_mod,
    });

    // -------------------------------------------------------------- libvfn
    const vfn_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // `vendor` last: it only supplies the meson-generated trace/events.h and
    // crc64table.h; upstream headers must win.
    vfn_mod.addIncludePath(libvfn.path(b, "src"));
    vfn_mod.addIncludePath(libvfn.path(b, "include"));
    vfn_mod.addIncludePath(libvfn.path(b, "ccan"));
    vfn_mod.addIncludePath(vendor);
    vfn_mod.linkLibrary(ccan);
    // ccan's headers `#include "config.h"`, so vfn's compile needs the
    // generated header too (linkLibrary does not propagate it correctly here).
    vfn_mod.addConfigHeader(ccan_config);

    const vfn_flags: []const []const u8 = c_flags;
    vfn_mod.addCSourceFiles(.{
        .root = libvfn.path(b, "src"),
        .files = &.{
            "trace.c",
            "support/io.c",
            "support/log.c",
            "support/mem.c",
            "support/mmio.c",
            "support/ticks.c",
            "support/timer.c",
            "util/skiplist.c",
            "pci/util.c",
            "iommu/context.c",
            "iommu/dma.c",
            "iommu/dmabuf.c",
            "iommu/vfio.c",
            "iommu/iommufd.c",
            "vfio/device.c",
            "vfio/pci.c",
            "nvme/core.c",
            "nvme/queue.c",
            "nvme/util.c",
            "nvme/rq.c",
        },
        .flags = vfn_flags ++ define_flags,
    });
    vfn_mod.addCSourceFiles(.{
        // generated trace event table (checked in)
        .root = vendor,
        .files = &.{"vfn/trace/events.c"},
        .flags = vfn_flags,
    });
    vfn_mod.addCSourceFiles(.{
        // C shim exporting the demoted header-only helpers (see src/vfn_shim.c)
        .root = b.path("src"),
        .files = &.{"vfn_shim.c"},
        .flags = vfn_flags ++ define_flags,
    });
    if (target.result.cpu.arch == .x86_64) {
        vfn_mod.addCSourceFiles(.{
            .root = libvfn.path(b, "src"),
            .files = &.{"support/arch/x86_64/rdtsc.c"},
            .flags = vfn_flags,
        });
    }
    if (target.result.cpu.arch == .s390x) {
        vfn_mod.addCSourceFiles(.{
            .root = libvfn.path(b, "src"),
            .files = &.{"support/arch/s390x/tod.c"},
            .flags = vfn_flags,
        });
    }
    const vfn = b.addLibrary(.{
        .name = "vfn",
        .linkage = .static,
        .root_module = vfn_mod,
    });

    // ----------------------------------------------------------------- exe
    // Zig bindings: translate-c the public headers for the target (so e.g.
    // <vfn/support/endian.h> picks the right byte order), and import the
    // generated module as "vfn_c".
    const tc = b.addTranslateC(.{
        .root_source_file = b.path("src/vfn_c.h"),
        .target = target,
        .optimize = optimize,
    });
    tc.defineCMacro("_GNU_SOURCE", null);
    tc.defineCMacro("HAVE_VFIO_DEVICE_BIND_IOMMUFD", null);
    tc.defineCMacro("HAVE_IOMMU_FAULT_QUEUE_ALLOC", null);
    tc.defineCMacro("NVME_AQ_QSIZE", "32");
    tc.addIncludePath(libvfn.path(b, "include"));
    tc.addIncludePath(vendor);
    const vfn_c = tc.createModule();

    // Zig-facing infra modules (DESIGN.md §3): thin libvfn binding, shared
    // NVMe spec structures, test-support conveniences. Batch programs and host
    // unit tests import these as "vfn", "nvme", "vfntest".
    const vfn_zig = b.addModule("vfn", .{
        .root_source_file = b.path("src/vfn/vfn.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vfn_zig.addImport("vfn_c", vfn_c);
    vfn_zig.linkLibrary(vfn);

    const nvme_zig = b.addModule("nvme", .{
        .root_source_file = b.path("src/nvme/nvme.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nvme_zig.addImport("vfn_c", vfn_c);
    nvme_zig.linkLibrary(vfn);

    // qtest-protocol client for host-side tests (no libvfn; talks to a
    // -accel qtest QEMU over a unix socket). Imported as "qtest".
    const qtest_zig = b.addModule("qtest", .{
        .root_source_file = b.path("src/qtest/qtest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const vfntest_zig = b.addModule("vfntest", .{
        .root_source_file = b.path("src/vfntest/vfntest.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    vfntest_zig.addImport("vfn_c", vfn_c);
    vfntest_zig.addImport("vfn", vfn_zig);
    vfntest_zig.addImport("nvme", nvme_zig);
    vfntest_zig.linkLibrary(vfn);

    // Optional: build one Zig test root as a guest test binary. Invoked by the
    // `nvmecheck:build` makac action (DESIGN.md §8); the output lands in
    // <prefix>/bin/<program-name>. The suite's common.zig, if present, is
    // exposed as the named import "common" next to the batch program; anything
    // else a suite needs (its spec definitions, helpers) is reached through common's
    // re-exports as ordinary file imports, so adding a suite needs no
    // build.zig change here.
    if (program) |prog| {
        const pname = program_name orelse std.fs.path.stem(prog);
        // tests/<tp>/batches/<name>.zig -> tests/<tp>
        const tp_dir = std.fs.path.dirname(std.fs.path.dirname(prog) orelse "") orelse "";

        const prog_mod = b.createModule(.{
            .root_source_file = b.path(prog),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        prog_mod.linkLibrary(vfn);
        prog_mod.addImport("vfn_c", vfn_c);
        prog_mod.addImport("vfn", vfn_zig);
        prog_mod.addImport("nvme", nvme_zig);
        prog_mod.addImport("vfntest", vfntest_zig);
        prog_mod.addImport("qtest", qtest_zig);

        const common_rel = b.pathJoin(&.{ tp_dir, "common.zig" });
        const has_common = if (b.build_root.handle.access(b.graph.io, common_rel, .{})) |_| true else |_| false;
        if (has_common) {
            const common_mod = b.createModule(.{
                .root_source_file = b.path(common_rel),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            common_mod.addImport("vfn_c", vfn_c);
            common_mod.addImport("vfn", vfn_zig);
            common_mod.addImport("nvme", nvme_zig);
            common_mod.addImport("vfntest", vfntest_zig);
            common_mod.addImport("qtest", qtest_zig);
            prog_mod.addImport("common", common_mod);
        }

        const prog_test = b.addTest(.{ .name = pname, .root_module = prog_mod });
        if (static) prog_test.linkage = .static;
        b.installArtifact(prog_test);
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.linkLibrary(vfn);
    exe_mod.addImport("vfn_c", vfn_c);
    const exe = b.addExecutable(.{
        .name = "nvme-check",
        .root_module = exe_mod,
        .linkage = if (static) .static else null,
    });
    b.installArtifact(exe);

    // Real device probe (nvme_init + Identify); used by the makac.e2e test.
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    probe_mod.linkLibrary(vfn);
    probe_mod.addImport("vfn_c", vfn_c);
    const probe = b.addExecutable(.{
        .name = "nvme-probe",
        .root_module = probe_mod,
        .linkage = if (static) .static else null,
    });
    b.installArtifact(probe);

    // Materialize the fetched libvfn tree at zig-out/libvfn-src, for host
    // tools that want the same headers the build uses without a second
    // checkout (e.g. the `zig cc -I...` compile check of src/probe.c).
    const vfn_src_install = b.addInstallDirectory(.{
        .source_dir = libvfn,
        .install_dir = .{ .custom = "" },
        .install_subdir = "libvfn-src",
    });
    b.step("libvfn-src", "Copy the (fetched) libvfn tree to zig-out/libvfn-src")
        .dependOn(&vfn_src_install.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the smoke test").dependOn(&run.step);

    // Unit tests for shared code (no device, no makac): one test binary per
    // root, run with `zig build test`. Pure spec roots depend only on the
    // translate-c binding; add roots as TPs land.
    const test_step = b.step("test", "Run unit tests");
    const test_roots = [_][]const u8{
        "src/tests.zig",
        "src/nvme/nvme.zig",
        "src/qtest/guestmem.zig",
        "src/qtest/qtest.zig",
        "tests/tp4176/spec.zig",
        "tests/nvme14m/spec.zig",
    };
    for (test_roots) |root| {
        const m = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        m.addImport("vfn_c", vfn_c);
        const t = b.addTest(.{ .name = b.fmt("test-{s}", .{std.fs.path.stem(root)}), .root_module = m });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // Language-server support (see build/editor.zig). `zls` resolves named
    // `@import`s from the root build graph, but the per-suite modules only
    // exist when a batch is built with `-Dprogram=...`; this widens the
    // default graph for the editor without changing what `zig build` builds.
    editor.indexSuites(b, target, optimize, .{
        .vfn_c = vfn_c,
        .vfn = vfn_zig,
        .nvme = nvme_zig,
        .vfntest = vfntest_zig,
        .qtest = qtest_zig,
    });
}
