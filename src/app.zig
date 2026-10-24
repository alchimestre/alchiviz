//! The window: capture in, waveform out, the fold laid over it.

const std = @import("std");
const dvui = @import("dvui");
const audio = @import("audio.zig");
const dmt = @import("dmt.zig");
const signal = @import("signal.zig");
const wave = @import("wave.zig");

const panel = dvui.Color{ .r = 0x14, .g = 0x14, .b = 0x1f, .a = 0xff };
const ink = dvui.Color{ .r = 0xf8, .g = 0xf8, .b = 0xf2, .a = 0xff };
const muted = dvui.Color{ .r = 0x8a, .g = 0x8a, .b = 0x9e, .a = 0xff };

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    devices: []audio.Device,
    names: [][]const u8,
    selected: usize = 0,
    input: audio.Input = .{},
    ring: ?signal.Ring = null,
    open: bool = false,

    wave_target: ?dvui.Texture.Target = null,
    fold_cache: dmt.Cache = .{},
    clock: dmt.Clock = .{},
    elapsed: f64 = 0,
    last_ns: i96 = 0,
    now_ns: i96 = 0,
    last_sample_ns: i96 = 0,
    levels: signal.Levels = .{},

    error_text: []u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, requested: ?[]const u8) !App {
        // A missing audio subsystem must not stop the window from opening: the
        // panel can report it, and the user can retry from there.
        var audio_failed = false;
        const devices = audio.list(allocator) catch blk: {
            audio_failed = true;
            break :blk try allocator.alloc(audio.Device, 0);
        };
        errdefer audio.free(allocator, devices);

        const names = try allocator.alloc([]const u8, devices.len);
        errdefer allocator.free(names);
        for (devices, 0..) |device, index| names[index] = device.name;

        const chosen = if (requested) |needle|
            audio.find(devices, needle) orelse audio.preferred(devices)
        else
            audio.preferred(devices);

        var app: App = .{
            .allocator = allocator,
            .io = io,
            .devices = devices,
            .names = names,
            .selected = chosen,
        };

        app.select(chosen);
        if (audio_failed) {
            app.setError("audio subsystem unavailable");
        } else if (devices.len == 0) {
            app.setError("no recording devices");
        }
        return app;
    }

    pub fn deinit(self: *App) void {
        self.input.close();
        if (self.ring) |*ring| ring.deinit(self.allocator);
        self.fold_cache.deinit();
        if (self.wave_target) |target| target.destroyLater();
        if (self.error_text.len > 0) self.allocator.free(self.error_text);
        self.allocator.free(self.names);
        audio.free(self.allocator, self.devices);
    }

    /// Open a device and start its history from empty.
    pub fn select(self: *App, index: usize) void {
        if (index >= self.devices.len) return;
        self.selected = index;
        self.open = false;

        // A failed switch must not leave the previous device's capture on
        // screen under the new device's name.
        if (self.ring) |*ring| ring.deinit(self.allocator);
        self.ring = null;
        self.input.close();

        self.input.open(self.devices[index].id) catch |err| {
            self.setError(@errorName(err));
            return;
        };

        self.ring = signal.Ring.init(self.allocator, self.input.rate) catch |err| {
            self.input.close();
            self.setError(@errorName(err));
            return;
        };
        self.open = true;
        self.last_sample_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.setError("");
    }

    pub fn frame(self: *App) void {
        self.pump();

        const rect = dvui.currentWindow().rect_pixels;
        const size = dvui.Size.Physical{ .w = rect.w, .h = rect.h };
        const arena = dvui.currentWindow().arena();

        self.drawWaveform(arena, size) catch {
            // Without a drawable target the fold has nothing to sample; the
            // controls still run so the device can be changed.
            self.setError("the backend cannot draw offscreen");
            self.controls();
            return;
        };

        const texture = dvui.textureFromTarget(self.wave_target.?) catch {
            self.setError("the waveform texture could not be read");
            self.controls();
            return;
        };

        const levels = self.levels;
        const swell = 1 + levels.kick * dmt.window_pump;
        dmt.draw(texture, arena, &self.fold_cache, self.clock, size, .{ .w = size.w * swell, .h = size.h * swell }, .{
            .ring_count = dmt.rings_default + 2.2 * levels.level,
            .heart = levels.kick,
            .mirrors = 4,
        }) catch {
            self.setError("the fold could not be drawn");
        };

        self.controls();
    }

    fn controls(self: *App) void {
        var root = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .margin = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
        });
        defer root.deinit();

        var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .border = .{},
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            .color_fill = .{ .color = panel },
        });
        defer pane.deinit();

        dvui.labelNoFmt(@src(), "input", .{}, .{
            .font = .theme(.body),
            .color_text = .{ .color = muted },
            .id_extra = 1,
        });

        var choice = self.selected;
        if (dvui.dropdown(@src(), self.names, .{ .choice = &choice }, .{}, .{
            .min_size_content = .{ .w = 300 },
            .id_extra = 2,
        })) {
            if (choice != self.selected) self.select(choice);
        }

        if (self.open) {
            dvui.label(@src(), "{d:.1} kHz  ·  {d} ch  ·  level {d:.2}", .{
                self.input.rate / 1000,
                self.input.channels,
                self.levels.level,
            }, .{
                .font = .theme(.body),
                .color_text = .{ .color = ink },
                .id_extra = 3,
            });
            if (self.stalled()) {
                dvui.labelNoFmt(@src(), "no samples arriving", .{}, .{
                    .font = .theme(.body),
                    .color_text = .{ .color = dvui.Color{ .r = 0xff, .g = 0xc0, .b = 0x40 } },
                    .id_extra = 5,
                });
            }
        } else {
            const message = if (self.error_text.len > 0) self.error_text else "device closed";
            dvui.labelNoFmt(@src(), message, .{}, .{
                .font = .theme(.body),
                .color_text = .{ .color = dvui.Color{ .r = 0xff, .g = 0x55, .b = 0x55 } },
                .id_extra = 4,
            });
        }
    }

    /// Move the clock with the capture and follow its loudness.
    fn pump(self: *App) void {
        const now = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.now_ns = now;
        const seconds = if (now > self.last_ns)
            @as(f64, @floatFromInt(now - self.last_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))
        else
            0;
        self.last_ns = now;
        const step = @min(seconds, 0.1);
        self.elapsed += step;
        // The tunnel keeps moving through silence; only its speed follows the
        // capture.
        self.clock.advance(step * (0.6 + 1.4 * self.levels.level), dmt.mood(self.elapsed));

        const ring = if (self.ring) |*value| value else return;
        const before = ring.pushes;
        self.input.pull(ring);
        if (ring.pushes != before) self.last_sample_ns = now;

        const samples = ring.newest();
        if (samples.len == 0) {
            self.levels.silence();
            return;
        }

        const count: usize = @intFromFloat(@max(64, ring.rate / 60));
        const tail = @min(samples.len, count);
        const newest = signal.column(ring, samples.len - tail, samples.len, 0);

        self.levels.update(newest);
    }

    /// A loopback driver that stops feeding looks exactly like silence: the
    /// window goes dark. Say so when nothing has arrived for a while.
    fn stalled(self: *const App) bool {
        return captureStalled(self.open, self.last_sample_ns, self.now_ns);
    }

    /// Draw the waveform into its own texture, so the fold samples the
    /// waveform alone and the controls stay crisp above it.
    fn drawWaveform(self: *App, arena: std.mem.Allocator, size: dvui.Size.Physical) !void {
        if (size.w <= 0 or size.h <= 0) return error.EmptyWindow;
        const target = try sizedTarget(&self.wave_target, size);

        const previous = dvui.RenderTarget.setAsCurrent(.{ .texture = target, .offset = .{} });
        defer _ = dvui.RenderTarget.setAsCurrent(previous);
        dvui.clipSet(.{ .x = 0, .y = 0, .w = size.w, .h = size.h });
        defer dvui.clipSet(dvui.currentWindow().rect_pixels);

        const ring = if (self.ring) |*value| value else return;
        try wave.draw(arena, size, ring);
    }

    fn setError(self: *App, message: []const u8) void {
        if (std.mem.eql(u8, self.error_text, message)) return;
        if (self.error_text.len > 0) self.allocator.free(self.error_text);
        self.error_text = self.allocator.dupe(u8, message) catch &.{};
    }
};

/// Whether an open capture has stopped delivering samples.
pub fn captureStalled(open: bool, last_sample_ns: i96, now_ns: i96) bool {
    if (!open or last_sample_ns == 0) return false;
    return now_ns - last_sample_ns > 2 * std.time.ns_per_s;
}

/// A window-sized texture, reused until the window resizes.
fn sizedTarget(slot: *?dvui.Texture.Target, size: dvui.Size.Physical) !dvui.Texture.Target {
    const width: u32 = @intFromFloat(@max(1, @floor(size.w)));
    const height: u32 = @intFromFloat(@max(1, @floor(size.h)));
    if (slot.*) |target| {
        if (target.width == width and target.height == height) return target;
        target.destroyLater();
        slot.* = null;
    }
    const target = try dvui.Texture.Target.create(.{ .width = width, .height = height });
    slot.* = target;
    return target;
}

test "a stalled capture is reported only while the stream is open" {
    const second: i96 = std.time.ns_per_s;
    try std.testing.expect(!captureStalled(false, 5 * second, 9 * second));
    try std.testing.expect(!captureStalled(true, 5 * second, 6 * second));
    try std.testing.expect(captureStalled(true, 5 * second, 8 * second));
}
