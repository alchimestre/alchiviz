const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Every frame warps the whole window, so an optimised build is the normal
    // one; `-Doptimize=Debug` still works when a backtrace is wanted.
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimisation mode") orelse .fast;

    // The window and the capture stream must bind to the same SDL.
    const sdl_prefix = b.option([]const u8, "sdl3-prefix", "Prefix of the SDL3 install") orelse
        std.mem.trimEnd(u8, b.run(&.{ "brew", "--prefix", "sdl3" }), "\r\n");

    const sdl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    sdl_translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdl_prefix, "include" }) });
    const sdlc = sdl_translate.createModule();

    // dvui compiles SDL3 from source unless the system copy is enabled; two
    // copies of SDL in one process duplicate every Objective-C class.
    _ = b.systemIntegrationOption("sdl3", .{ .default = true });
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3gpu,
        // dvui's default u16 index wraps once a frame pushes more than 65,535
        // vertices; the full-window fold passes that and the wrapped indices
        // drew stray red triangles.
        .@"vertex-index" = .u32,
    });

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "dvui", .module = dvui.module("dvui_sdl3gpu") },
        .{ .name = "sdl-backend", .module = dvui.module("sdl3gpu") },
        .{ .name = "sdl3-c", .module = sdlc },
    };

    const exe = b.addExecutable(.{
        .name = "alchiviz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    linkSdl(b, exe.root_module, sdl_prefix);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run alchiviz").dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    linkSdl(b, tests.root_module, sdl_prefix);
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}

fn linkSdl(b: *std.Build, mod: *std.Build.Module, prefix: []const u8) void {
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    mod.linkSystemLibrary("SDL3", .{});
    mod.link_libc = true;
}
