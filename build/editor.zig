//! Editor / language-server support only — nothing here affects `zig build`.
//!
//! `zls` resolves `@import("name")` from the build graph, and it only ever
//! inspects the root `build.zig`, run with no `-Dprogram`. The per-suite
//! modules that `-Dprogram` normally materialises — each suite's `common` and
//! its batch programs — are therefore invisible to it, so go-to-definition on
//! anything reached through `@import("vfn")`, `@import("common")`, ... comes
//! back empty.
//!
//! Registering those roots with `addModule` puts them in the default graph.
//! Public modules are never compiled unless a compile step imports them, so
//! `zig build` still builds exactly what it built before; this only widens what
//! the language server can resolve.

const std = @import("std");

/// Handles for the shared modules every suite imports by name.
pub const Infra = struct {
    vfn_c: *std.Build.Module,
    vfn: *std.Build.Module,
    nvme: *std.Build.Module,
    vfntest: *std.Build.Module,
    qtest: *std.Build.Module,
};

/// Walk `tests/<suite>/` and expose each `common.zig` and `batches/*.zig` to
/// the language server. Discovery mirrors the on-disk layout, so adding a
/// suite or batch needs no change here.
pub fn indexSuites(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    infra: Infra,
) void {
    const tests_dir = b.build_root.handle.openDir(b.graph.io, "tests", .{ .iterate = true }) catch return;
    var suites = tests_dir.iterate();
    while (suites.next(b.graph.io) catch null) |suite| {
        if (suite.kind != .directory) continue;

        const common_rel = b.pathJoin(&.{ "tests", suite.name, "common.zig" });
        const common_mod: ?*std.Build.Module = if (b.build_root.handle.access(b.graph.io, common_rel, .{})) |_| blk: {
            break :blk addSuiteRoot(b, target, optimize, infra, b.fmt("common_{s}", .{suite.name}), common_rel, null);
        } else |_| null;

        const batches_rel = b.pathJoin(&.{ "tests", suite.name, "batches" });
        const batches_dir = b.build_root.handle.openDir(b.graph.io, batches_rel, .{ .iterate = true }) catch continue;
        var batches = batches_dir.iterate();
        while (batches.next(b.graph.io) catch null) |batch| {
            if (batch.kind != .file) continue;
            if (!std.mem.endsWith(u8, batch.name, ".zig")) continue;
            _ = addSuiteRoot(
                b,
                target,
                optimize,
                infra,
                b.fmt("batch_{s}_{s}", .{ suite.name, std.fs.path.stem(batch.name) }),
                b.pathJoin(&.{ batches_rel, batch.name }),
                common_mod,
            );
        }
    }
}

fn addSuiteRoot(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    infra: Infra,
    name: []const u8,
    root: []const u8,
    common: ?*std.Build.Module,
) *std.Build.Module {
    const m = b.addModule(name, .{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    m.addImport("vfn_c", infra.vfn_c);
    m.addImport("vfn", infra.vfn);
    m.addImport("nvme", infra.nvme);
    m.addImport("vfntest", infra.vfntest);
    m.addImport("qtest", infra.qtest);
    if (common) |cm| m.addImport("common", cm);
    return m;
}
