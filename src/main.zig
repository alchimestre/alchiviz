//! Opens the window and drives one frame per event.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const audio = @import("audio.zig");
const App = @import("app.zig").App;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]

    var device: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        }
        if (std.mem.eql(u8, arg, "--list-devices")) {
            return listDevices(init);
        }
        if (std.mem.eql(u8, arg, "--device")) {
            device = args.next() orelse return error.MissingDeviceName;
            continue;
        }
        usage();
        return error.UnknownArgument;
    }

    return run(init, device);
}

fn run(init: std.process.Init, device: ?[]const u8) !void {
    var app = try App.init(init.gpa, init.io, device);
    defer app.deinit();

    if (device) |needle| {
        if (app.devices.len > 0 and audio.find(app.devices, needle) == null) {
            std.debug.print("no recording device matches \"{s}\"; using {s}\n", .{
                needle,
                app.devices[app.selected].name,
            });
        }
    }

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .allocator = init.gpa,
        .size = .{ .w = 1280, .h = 800 },
        .min_size = .{ .w = 640, .h = 400 },
        .vsync = true,
        .title = "alchiviz",
    });
    defer backend.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = dvui.Theme.builtin.adwaita_dark,
        .open_flag = &window_open,
    });
    defer win.deinit();

    var interrupted = false;
    while (window_open) {
        const frame_start = win.beginWait(interrupted);
        try win.begin(frame_start);
        if (try backend.addAllEvents(&win)) break;

        app.frame();
        const frame_end = try win.end(.{});

        // The waveform moves every frame, so no wait goes past a frame's worth
        // of time even when nothing is happening.
        const wait = @min(win.waitTime(frame_end), 16_667);
        interrupted = try backend.waitEventTimeout(wait);
    }
}

fn listDevices(init: std.process.Init) void {
    const devices = audio.list(init.gpa) catch |err| {
        std.debug.print("cannot list recording devices: {s}\n", .{@errorName(err)});
        return;
    };
    defer audio.free(init.gpa, devices);

    if (devices.len == 0) {
        std.debug.print("no recording devices\n", .{});
        return;
    }
    const preferred = audio.preferred(devices);
    for (devices, 0..) |listed, index| {
        std.debug.print("{s}{s}\n", .{ if (index == preferred) "* " else "  ", listed.name });
    }
}

fn usage() void {
    std.debug.print(
        \\usage: alchiviz [--device <name>] [--list-devices]
        \\
        \\  --device <name>   recording device to visualize, matched on part of
        \\                    its name (default: a system loopback when one is
        \\                    installed, otherwise the system recording device)
        \\  --list-devices    print the recording devices and exit
        \\
    , .{});
}
