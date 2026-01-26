const std = @import("std");

fn getVersionString(b: *std.Build) ![]const u8 {
    const allocator = b.allocator;
    const command = [_][]const u8{ "git", "describe", "--tags", "--always" };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &command,
    }) catch |err| {
        std.log.warn("Failed to get git version: {s}", .{@errorName(err)});
        return "unknown";
    };
    if (result.term.Exited != 0)
        return "unknown";
    const version = std.mem.trimRight(u8, result.stdout, "\r\n");
    return allocator.dupe(u8, version);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const version = getVersionString(b) catch "unknown";
    options.addOption([]const u8, "version", version);
    const strip: bool = if (optimize == std.builtin.OptimizeMode.ReleaseFast) true else false;

    // fssimu2
    const fssimu2 = b.dependency("fssimu2", .{
        .target = target,
        .optimize = optimize,
    });

    // Optional build option, support for rav1e av1 encoder, add with -Drav1e=true
    const use_rav1e = b.option(bool, "rav1e", "Include rav1e support") orelse false;

    // oavif
    const bin = b.addExecutable(.{
        .name = "oavif",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    bin.root_module.addOptions("build_opts", options);
    bin.root_module.addIncludePath(b.path("src"));
    bin.root_module.addIncludePath(b.path("src/include"));
    bin.root_module.addIncludePath(b.path("third-party/"));

    // local import
    bin.root_module.addImport("fssimu2", fssimu2.module("fssimu2"));

    // system decoder libs
    bin.root_module.linkSystemLibrary("jpeg", .{ .preferred_link_mode = .static });
    bin.root_module.linkSystemLibrary("webp", .{ .preferred_link_mode = .static });
    bin.root_module.linkSystemLibrary("webpmux", .{ .preferred_link_mode = .static });
    bin.root_module.linkSystemLibrary("avif", .{ .preferred_link_mode = .static });
    bin.root_module.linkSystemLibrary("spng", .{ .preferred_link_mode = .static });
    bin.root_module.linkSystemLibrary("heif", .{ .preferred_link_mode = .static });

    if (use_rav1e) {
        bin.root_module.linkSystemLibrary("rav1e", .{ .preferred_link_mode = .static });
    }
    b.installArtifact(bin);
}
