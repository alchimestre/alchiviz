//! Opens the window and drives one frame per event.

const std = @import("std");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const c = SDLBackend.c;
const gpu = @import("gpu.zig");
const audio = @import("audio.zig");
const tap = @import("tap.zig");
const App = @import("app.zig").App;
const backdrop_mod = @import("backdrop.zig");

/// One frame at 60 Hz, in microseconds.
const frame_budget_us: u32 = 16_667;

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next(); // argv[0]

    var device: ?[]const u8 = null;
    var backdrop: ?[]const u8 = null;
    var tiles: f32 = backdrop_mod.default_tiles;
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
        if (std.mem.eql(u8, arg, "--backdrop")) {
            backdrop = args.next() orelse return error.MissingBackdropPath;
            continue;
        }
        if (std.mem.eql(u8, arg, "--tiles")) {
            const text = args.next() orelse return error.MissingTileCount;
            tiles = std.fmt.parseFloat(f32, text) catch return error.BadTileCount;
            if (!(tiles > 0)) return error.BadTileCount;
            continue;
        }
        usage();
        return error.UnknownArgument;
    }

    return run(init, device, .{ .path = backdrop, .tiles = tiles });
}

fn run(init: std.process.Init, device: ?[]const u8, backdrop: backdrop_mod.Options) !void {
    var app = try App.init(init.gpa, init.io, init.environ_map, device, backdrop);

    if (device) |needle| {
        if (app.devices.len > 0 and audio.find(app.devices, needle) == null) {
            std.debug.print("no recording device matches \"{s}\"; using {s}\n", .{
                needle,
                app.devices[app.selected].name,
            });
        }
    }

    // The only fallible step before the app's own defer is registered.
    var backend = SDLBackend.initWindow(.{
        .io = init.io,
        .allocator = init.gpa,
        .size = .{ .w = 1280, .h = 800 },
        .min_size = .{ .w = 640, .h = 400 },
        .vsync = true,
        .title = "alchiviz",
    }) catch |err| {
        app.deinit();
        return err;
    };
    defer backend.deinit();

    var painter: ?gpu.Painter = gpu.Painter.init(&backend) catch |err| blk: {
        app.gpu_message = std.mem.sliceTo(&gpu.last_error, 0);
        std.debug.print("[gpu] tunnel stays on the CPU ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (painter) |*running| running.deinit();
    app.painter = if (painter) |*running| running else null;
    // Registered after the backend so it runs before it: destroying the stream
    // after SDL_Quit walks a freed audio device.
    defer app.deinit();

    var window_open = true;
    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = dvui.Theme.builtin.adwaita_dark,
        .open_flag = &window_open,
    });
    defer win.deinit();

    var interrupted = false;
    while (window_open) {
        const frame_start = win.beginWait(interrupted);
        // PollEvent can resize the window mid-frame and invalidate target dimensions.
        c.SDL_PumpEvents();
        try win.begin(frame_start);
        if (try queuedEvents(&backend, &win)) {
            app.release();
            break;
        }

        app.gpu_frame = .{
            .cmd = backend.cmd,
            .swapchain = backend.swapchain_texture,
        };
        app.frame();
        const frame_end = try win.end(.{});


        // dvui has no animation to wait for, so this wait is what paces the
        // waveform. It has to be the part of the frame budget the frame has
        // not already spent: a full-frame wait on top of a 12 ms frame lands
        // every frame after the vblank and half the frame rate is lost.
        const now_ns: i128 = @intCast(std.Io.Clock.awake.now(init.io).nanoseconds);
        const spent_us = std.math.clamp(@divTrunc(now_ns - frame_start, std.time.ns_per_us), 0, frame_budget_us);
        const wait = @min(win.waitTime(frame_end), frame_budget_us - @as(u32, @intCast(spent_us)));
        interrupted = try backend.waitEventTimeout(wait);
    }
}

fn queuedEvents(backend: *SDLBackend, win: *dvui.Window) !bool {
    var event: c.SDL_Event = undefined;
    while (true) {
        const count = c.SDL_PeepEvents(&event, 1, c.SDL_GETEVENT, c.SDL_EVENT_FIRST, c.SDL_EVENT_LAST);
        if (count < 0) {
            std.log.err("SDL_PeepEvents failed: {s}", .{c.SDL_GetError()});
            return error.EventQueue;
        }
        if (count == 0) return false;
        _ = try backend.addEvent(win, event);
        switch (event.type) {
            c.SDL_EVENT_WINDOW_CLOSE_REQUESTED, c.SDL_EVENT_QUIT => return true,
            else => {},
        }
    }
}

fn listDevices(init: std.process.Init) void {
    // The tap is not an SDL device, so probing it is the only way the list can
    // say whether the system output is capturable.
    var system_tap = tap.start(init.io, init.gpa) catch |err| blk: {
        std.debug.print("system output unavailable ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (system_tap) |*running| running.stop(init.gpa);

    const devices = audio.list(init.gpa) catch |err| {
        std.debug.print("cannot list recording devices: {s}\n", .{@errorName(err)});
        return;
    };
    defer audio.free(init.gpa, devices);

    const preferred = audio.preferred(devices);
    if (system_tap != null) std.debug.print("* system output\n", .{});
    if (devices.len == 0 and system_tap == null) std.debug.print("no recording devices\n", .{});
    for (devices, 0..) |listed, index| {
        const mark = if (system_tap == null and index == preferred) "* " else "  ";
        std.debug.print("{s}{s}\n", .{ mark, listed.name });
    }
}

fn usage() void {
    std.debug.print(
        \\usage: alchiviz [--device <name>] [--backdrop <file>] [--tiles <n>] [--list-devices]
        \\
        \\  --device <name>   recording device to visualize, matched on part of
        \\                    its name (default: a system loopback when one is
        \\                    installed, otherwise the system recording device)
        \\  --backdrop <file> image painted across the whole frame before the
        \\                    waveform, so the fold repeats it
        \\  --tiles <n>       copies of the backdrop across the frame (default 8)
        \\  --list-devices    print the recording devices and exit
        \\
    , .{});
}
