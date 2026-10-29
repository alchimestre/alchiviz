//! Recording devices and the capture stream.
//!
//! The stream asks SDL for mono float samples at 48 kHz, so a stereo loopback
//! and a mono microphone arrive in the same shape.

const std = @import("std");
const sdl = @import("sdl3-c");
const signal = @import("signal.zig");
const tap = @import("tap.zig");

pub const sample_rate: u32 = 48000;

pub const Device = struct {
    id: sdl.SDL_AudioDeviceID,
    name: []u8,
};

/// Every recording device SDL can see, with owned names.
pub fn list(allocator: std.mem.Allocator) ![]Device {
    if (!sdl.SDL_InitSubSystem(sdl.SDL_INIT_AUDIO)) return error.AudioInit;

    var count: c_int = 0;
    const ids = sdl.SDL_GetAudioRecordingDevices(&count);
    if (ids == null or count <= 0) return allocator.alloc(Device, 0);
    defer sdl.SDL_free(ids);

    const devices = try allocator.alloc(Device, @intCast(count));
    var built: usize = 0;
    errdefer {
        for (devices[0..built]) |device| allocator.free(device.name);
        allocator.free(devices);
    }

    for (ids[0..@intCast(count)]) |id| {
        const raw = sdl.SDL_GetAudioDeviceName(id);
        const name: []const u8 = if (raw == null) "" else std.mem.span(raw);
        // The system-output tap appears here as its own aggregate device. It
        // is captured through `tap.zig`, so offering it twice would be a trap.
        if (containsIgnoreCase(name, tap.aggregate_name)) continue;
        devices[built] = .{ .id = id, .name = try allocator.dupe(u8, name) };
        built += 1;
    }
    return try allocator.realloc(devices, built);
}

pub fn free(allocator: std.mem.Allocator, devices: []Device) void {
    for (devices) |device| allocator.free(device.name);
    allocator.free(devices);
}

/// The device the visualizer starts on: the system-output tap, then a system
/// loopback when one is installed (eqMac, BlackHole, Loopback, Soundflower),
/// otherwise the system's default recording device.
pub fn preferred(devices: []const Device) usize {
    if (find(devices, "alchiviz")) |index| return index;
    if (loopbackIndex(devices)) |index| return index;

    const default_name = sdl.SDL_GetAudioDeviceName(sdl.SDL_AUDIO_DEVICE_DEFAULT_RECORDING);
    if (default_name != null) {
        const wanted = std.mem.span(default_name);
        for (devices, 0..) |device, index| {
            if (std.mem.eql(u8, device.name, wanted)) return index;
        }
    }
    return 0;
}

fn loopbackIndex(devices: []const Device) ?usize {
    const loopbacks = [_][]const u8{ "eqmac", "blackhole", "loopback", "soundflower" };
    for (devices, 0..) |device, index| {
        for (loopbacks) |marker| {
            if (containsIgnoreCase(device.name, marker)) return index;
        }
    }
    return null;
}

/// Index of the device whose name holds `needle`, ignoring case.
pub fn find(devices: []const Device, needle: []const u8) ?usize {
    for (devices, 0..) |device, index| {
        if (containsIgnoreCase(device.name, needle)) return index;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var at: usize = 0;
    while (at + needle.len <= haystack.len) : (at += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[at .. at + needle.len], needle)) return true;
    }
    return false;
}

pub const Input = struct {
    stream: ?*sdl.SDL_AudioStream = null,
    agc: signal.Agc = .{},
    rate: f32 = @floatFromInt(sample_rate),
    channels: usize = 1,

    pub fn open(self: *Input, device_id: sdl.SDL_AudioDeviceID) !void {
        self.close();

        const wanted = sdl.SDL_AudioSpec{
            .format = sdl.SDL_AUDIO_F32,
            .channels = 1,
            .freq = sample_rate,
        };
        const stream = sdl.SDL_OpenAudioDeviceStream(device_id, &wanted, null, null) orelse
            return error.DeviceOpenFailed;
        errdefer sdl.SDL_DestroyAudioStream(stream);

        if (!sdl.SDL_ResumeAudioStreamDevice(stream)) return error.DeviceResumeFailed;

        // The device side may differ; the stream's output side is what the app
        // reads, and SDL has already converted it to the requested spec.
        var source: sdl.SDL_AudioSpec = undefined;
        var target: sdl.SDL_AudioSpec = undefined;
        if (sdl.SDL_GetAudioStreamFormat(stream, &source, &target)) {
            if (target.freq > 0) self.rate = @floatFromInt(target.freq);
            self.channels = @max(1, target.channels);
        }
        self.stream = stream;
    }

    pub fn close(self: *Input) void {
        if (self.stream) |stream| sdl.SDL_DestroyAudioStream(stream);
        self.stream = null;
    }

    /// Drain everything the device has captured into the history ring.
    pub fn pull(self: *Input, ring: *signal.Ring) void {
        const stream = self.stream orelse return;
        var buffer: [8192]f32 = undefined;

        var rounds: usize = 0;
        while (rounds < 32) : (rounds += 1) {
            const available = sdl.SDL_GetAudioStreamAvailable(stream);
            if (available <= 0) break;

            const wanted = @min(buffer.len * @sizeOf(f32), @as(usize, @intCast(available)));
            const got = sdl.SDL_GetAudioStreamData(stream, @ptrCast(&buffer), @intCast(wanted));
            if (got <= 0) break;

            const samples: usize = @as(usize, @intCast(got)) / @sizeOf(f32);
            var at: usize = 0;
            while (at + self.channels <= samples) : (at += self.channels) {
                var sum: f32 = 0;
                for (buffer[at .. at + self.channels]) |value| sum += value;
                const mixed = sum / @as(f32, @floatFromInt(self.channels));
                ring.push(self.agc.process(mixed, @floatFromInt(sample_rate)));
            }

            if (@as(usize, @intCast(got)) < wanted) break;
        }
    }
};

pub fn lastError() []const u8 {
    const message = sdl.SDL_GetError();
    if (message == null) return "";
    return std.mem.span(message);
}

test "the loopback is preferred over the default recording device" {
    const names = [_][]u8{ @constCast("MacBook Air Microphone"), @constCast("eqMac Export") };
    var devices = [_]Device{
        .{ .id = 1, .name = names[0] },
        .{ .id = 2, .name = names[1] },
    };
    try std.testing.expectEqual(@as(?usize, 1), loopbackIndex(&devices));
    try std.testing.expectEqual(@as(?usize, 1), find(&devices, "eqmac"));
    try std.testing.expectEqual(@as(?usize, null), find(&devices, "blackhole"));
}
