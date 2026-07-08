const std = @import("std");

fn getVersionString(b: *std.Build) ![]const u8 {
    const allocator = b.allocator;
    const command = [_][]const u8{ "git", "describe", "--tags", "--always" };
    var code: u8 = undefined;
    const stdout = b.runAllowFail(&command, &code, .inherit) catch |err| {
        std.log.warn("Failed to get git version: {s}", .{@errorName(err)});
        return "unknown";
    };
    const version = std.mem.trimEnd(u8, stdout, "\r\n");
    return allocator.dupe(u8, version);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const version = getVersionString(b) catch "unknown";
    options.addOption([]const u8, "version", version);
    const strip: bool =
        if (optimize == std.builtin.OptimizeMode.ReleaseFast) true else false;

    // fssimu2
    const fssimu2 = b.dependency("fssimu2", .{
        .target = target,
        .optimize = optimize,
    });

    // simpleimgio
    const simpleimgio = b.dependency("simpleimgio", .{
        .target = target,
        .optimize = optimize,
    });

    // libspng
    const spng = b.dependency("spng", .{
        .target = target,
        .optimize = optimize,
        .linkage = .static,
    });

    // oavif
    const bin = b.addExecutable(.{
        .name = "oavif",
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
        }),
    });
    bin.root_module.addOptions("build_opts", options);
    bin.root_module.addIncludePath(b.path("src"));
    bin.root_module.addIncludePath(b.path("src/include"));
    bin.root_module.addIncludePath(b.path("third-party/"));

    // local import
    bin.root_module.addImport("fssimu2", fssimu2.module("fssimu2"));
    bin.root_module.addImport("simpleimgio", simpleimgio.module("simpleimgio"));

    bin.root_module.linkLibrary(spng.artifact("spng"));
    bin.root_module.linkSystemLibrary("avif", .{ .preferred_link_mode = .static });
    bin.root_module.linkSystemLibrary("aom", .{ .preferred_link_mode = .static });

    b.installArtifact(bin);
}
