//! The system output, as a recording device.
//!
//! macOS publishes no loopback device, so SDL can only list microphones. A
//! process tap copies whatever the output device plays without touching the
//! stream, so playback carries on. The tap is attached to an aggregate device
//! and read with its own IO proc: an aggregate is not a recording device to
//! anything enumerating until something starts it, which is why this does not
//! go through SDL.

const std = @import("std");
const signal = @import("signal.zig");

const OSStatus = i32;
const AudioObjectID = u32;
const AudioDeviceIOProcID = ?*anyopaque;

const PropertyAddress = extern struct {
    selector: u32,
    scope: u32,
    element: u32,
};

const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32,
};

const AudioBuffer = extern struct {
    channels: u32,
    byte_size: u32,
    data: ?*anyopaque,
};

const AudioBufferList = extern struct {
    count: u32,
    buffers: [1]AudioBuffer,
};

const AudioTimeStamp = extern struct {
    sample_time: f64,
    host_time: u64,
    rate_scalar: f64,
    word_clock_time: u64,
    smpte_time: [4]u32,
    flags: u32,
    reserved: u32,
};

const object_system: u32 = 1;
const scope_global: u32 = fromFourCC("glob");
const devices_selector: u32 = fromFourCC("dev#");
const uid_selector: u32 = fromFourCC("uid ");
const default_output_selector: u32 = fromFourCC("dOut");
const format_selector: u32 = fromFourCC("tfmt");
const kCFStringEncodingUTF8: u32 = 0x0800_0100;
const kAudioFormatLinearPCM: u32 = fromFourCC("lpcm");
const kAudioFormatFlagIsFloat: u32 = 1 << 0;
const kAudioFormatFlagIsPacked: u32 = 1 << 3;

extern fn AudioObjectGetPropertyDataSize(object: AudioObjectID, address: *const PropertyAddress, qualifier_size: u32, qualifier: ?*const anyopaque, out: *u32) OSStatus;
extern fn AudioObjectGetPropertyData(object: AudioObjectID, address: *const PropertyAddress, qualifier_size: u32, qualifier: ?*const anyopaque, io: *u32, out: ?*anyopaque) OSStatus;
extern fn AudioObjectSetPropertyData(object: AudioObjectID, address: *const PropertyAddress, qualifier_size: u32, qualifier: ?*const anyopaque, size: u32, data: ?*const anyopaque) OSStatus;
extern fn AudioHardwareCreateProcessTap(description: ?*anyopaque, out: *AudioObjectID) OSStatus;
extern fn AudioHardwareDestroyProcessTap(tap: AudioObjectID) OSStatus;
extern fn AudioHardwareCreateAggregateDevice(description: ?*anyopaque, out: *AudioObjectID) OSStatus;
extern fn AudioHardwareDestroyAggregateDevice(aggregate: AudioObjectID) OSStatus;
extern fn AudioDeviceCreateIOProcID(device: AudioObjectID, proc: *const anyopaque, client: ?*anyopaque, out: *AudioDeviceIOProcID) OSStatus;
extern fn AudioDeviceDestroyIOProcID(device: AudioObjectID, proc: AudioDeviceIOProcID) OSStatus;
extern fn AudioDeviceStart(device: AudioObjectID, proc: AudioDeviceIOProcID) OSStatus;
extern fn AudioDeviceStop(device: AudioObjectID, proc: AudioDeviceIOProcID) OSStatus;

extern fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
extern fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
extern fn objc_msgSend() callconv(.c) void;

extern fn CFStringCreateWithCString(allocator: ?*anyopaque, bytes: [*:0]const u8, encoding: u32) ?*anyopaque;
extern fn CFStringGetCString(string: ?*anyopaque, out: [*]u8, size: isize, encoding: u32) bool;
extern fn CFDictionaryCreateMutable(
    allocator: ?*anyopaque,
    capacity: isize,
    key_callbacks: ?*const anyopaque,
    value_callbacks: ?*const anyopaque,
) ?*anyopaque;
extern fn CFDictionarySetValue(dictionary: ?*anyopaque, key: ?*const anyopaque, value: ?*const anyopaque) void;
extern fn CFArrayCreate(
    allocator: ?*anyopaque,
    values: [*]const ?*const anyopaque,
    count: isize,
    callbacks: ?*const anyopaque,
) ?*anyopaque;
extern fn CFRelease(value: ?*anyopaque) void;

extern var kCFBooleanTrue: ?*anyopaque;
extern var kCFTypeDictionaryKeyCallBacks: anyopaque;
extern var kCFTypeDictionaryValueCallBacks: anyopaque;
extern var kCFTypeArrayCallBacks: anyopaque;

/// The tap delivers mono float samples at this rate.
pub const sample_rate: f32 = 48000;

/// The aggregate carries this name. It is filtered out of SDL's device list:
/// it is captured through this module, never through SDL.
pub const aggregate_name = "alchiviz system output";

/// Long enough that a main thread stalled for a second still drains everything,
/// short enough to stay a rounding error in memory.
const queue_seconds: usize = 2;

/// Prefix of the aggregate's UID. Each run appends its own number: a killed
/// process can leave an aggregate the HAL still reserves the UID for, and that
/// leftover is neither listed nor reachable by UID, so a fixed UID wedges every
/// later run.
const aggregate_uid_prefix = "com.alchiviz.system-output";

/// The HAL lists a new aggregate a few milliseconds after creating it.
const registration_attempts: usize = 100;
const registration_pause = std.Io.Duration.fromNanoseconds(5 * std.time.ns_per_ms);

/// Samples the IO proc has written and the main thread has not read yet.
///
/// The IO proc runs on CoreAudio's realtime thread: it may not allocate, lock,
/// or wait. The counters are the whole handoff.
const Queue = struct {
    samples: []f32,
    written: std.atomic.Value(u64) = .init(0),
    read: std.atomic.Value(u64) = .init(0),

    fn push(self: *Queue, incoming: []const f32) void {
        const capacity: u64 = @intCast(self.samples.len);
        const written = self.written.load(.monotonic);
        const used = written -% self.read.load(.acquire);
        if (used >= capacity) return;

        const take: usize = @intCast(@min(incoming.len, capacity - used));
        for (incoming[0..take], 0..) |sample, index| {
            self.samples[@intCast((written + index) % capacity)] = sample;
        }
        self.written.store(written + take, .release);
    }

    fn pop(self: *Queue, out: []f32) usize {
        const capacity: u64 = @intCast(self.samples.len);
        const read = self.read.load(.monotonic);
        const used: usize = @intCast(self.written.load(.acquire) -% read);
        const take = @min(out.len, used);
        for (out[0..take], 0..) |*sample, index| {
            sample.* = self.samples[@intCast((read + index) % capacity)];
        }
        if (take > 0) self.read.store(read + take, .release);
        return take;
    }
};

/// A mono tap of everything the system output plays.
pub const SystemTap = struct {
    aggregate: AudioObjectID,
    tap: AudioObjectID,
    proc: AudioDeviceIOProcID,
    queue: *Queue,

    /// Close the capture and give back everything it allocated. The io proc is
    /// stopped first: destroying the device under a running proc crashes.
    pub fn stop(self: *SystemTap, allocator: std.mem.Allocator) void {
        if (self.aggregate != 0) {
            _ = AudioDeviceStop(self.aggregate, self.proc);
            if (self.proc != null) _ = AudioDeviceDestroyIOProcID(self.aggregate, self.proc);
            _ = AudioHardwareDestroyAggregateDevice(self.aggregate);
        }
        if (self.tap != 0) _ = AudioHardwareDestroyProcessTap(self.tap);
        allocator.free(self.queue.samples);
        allocator.destroy(self.queue);
        self.* = .{ .aggregate = 0, .tap = 0, .proc = null, .queue = undefined };
    }

    /// Move everything captured since the last call into the history ring.
    pub fn pull(self: *SystemTap, ring: *signal.Ring) void {
        var buffer: [4096]f32 = undefined;
        while (true) {
            const taken = self.queue.pop(&buffer);
            if (taken == 0) return;
            for (buffer[0..taken]) |sample| ring.push(sample);
        }
    }
};

pub fn start(io: std.Io, allocator: std.mem.Allocator) !SystemTap {
    const description = try describe();
    defer release(description);

    var tap_id: AudioObjectID = 0;
    if (AudioHardwareCreateProcessTap(description, &tap_id) != 0 or tap_id == 0)
        return error.TapDenied;
    errdefer _ = AudioHardwareDestroyProcessTap(tap_id);


    const uuid = try tapUUID(description);
    const output = defaultOutputUid() orelse return error.NoOutputDevice;
    defer release(output);
    var aggregate: AudioObjectID = 0;
    if (AudioHardwareCreateAggregateDevice(try aggregateDescription(uuid, output, try runUid(io)), &aggregate) != 0 or
        aggregate == 0) return error.AggregateFailed;
    errdefer _ = AudioHardwareDestroyAggregateDevice(aggregate);
    try awaitRegistration(io, aggregate);

    const queue = try allocator.create(Queue);
    errdefer allocator.destroy(queue);
    const samples = try allocator.alloc(f32, queue_seconds * @as(usize, @intFromFloat(sample_rate)));
    errdefer allocator.free(samples);
    queue.* = .{ .samples = samples };

    var capture: SystemTap = .{ .aggregate = aggregate, .tap = tap_id, .proc = null, .queue = queue };
    if (AudioDeviceCreateIOProcID(aggregate, &ioProc, capture.queue, &capture.proc) != 0)
        return error.TapStartFailed;
    if (AudioDeviceStart(aggregate, capture.proc) != 0) return error.TapStartFailed;
    return capture;
}

fn ioProc(
    _: AudioObjectID,
    _: ?*const AudioTimeStamp,
    input: ?*const AudioBufferList,
    _: ?*const AudioTimeStamp,
    _: ?*AudioBufferList,
    _: ?*const AudioTimeStamp,
    client: ?*anyopaque,
) callconv(.c) OSStatus {
    const queue: *Queue = @ptrCast(@alignCast(client orelse return 0));
    const list = input orelse return 0;

    var index: u32 = 0;
    while (index < list.count) : (index += 1) {
        const buffer = list.buffers[index];
        const data = buffer.data orelse continue;
        const floats: [*]const f32 = @ptrCast(@alignCast(data));
        queue.push(floats[0 .. buffer.byte_size / @sizeOf(f32)]);
    }
    return 0;
}

/// A `CATapDescription` for a mono tap of every process, excluding none.
fn describe() !?*anyopaque {
    const class = objc_getClass("CATapDescription") orelse return error.NoTapDescription;
    const array_class = objc_getClass("NSArray") orelse return error.NoTapDescription;
    const empty = send0(array_class, sel("array"));

    const allocated = send0(class, sel("alloc"));
    const tap = send1(allocated, sel("initMonoGlobalTapButExcludeProcesses:"), empty) orelse
        return error.NoTapDescription;
    errdefer release(tap);

    const name = cf("alchiviz");
    defer release(name);
    send1Void(tap, sel("setName:"), name);
    return tap;
}

/// The tap's UUID, as a string the aggregate description names it by.
fn tapUUID(description: ?*anyopaque) !?*anyopaque {
    const uuid = send0(description, sel("UUID")) orelse return error.NoTapUUID;
    return send0(uuid, sel("UUIDString")) orelse error.NoTapUUID;
}

fn aggregateDescription(tap_uuid: ?*anyopaque, output_uid: ?*anyopaque, uid: []const u8) !?*anyopaque {
    const sub_tap = dictionary() orelse return error.AggregateFailed;
    defer release(sub_tap);
    CFDictionarySetValue(sub_tap, cf("uid"), tap_uuid);

    var taps = [_]?*const anyopaque{sub_tap};
    const tap_list = CFArrayCreate(null, &taps, 1, &kCFTypeArrayCallBacks);
    if (tap_list == null) return error.AggregateFailed;
    defer release(tap_list);

    const sub_device = dictionary() orelse return error.AggregateFailed;
    defer release(sub_device);
    CFDictionarySetValue(sub_device, cf("uid"), output_uid);

    var sub_devices = [_]?*const anyopaque{sub_device};
    const sub_list = CFArrayCreate(null, &sub_devices, 1, &kCFTypeArrayCallBacks);
    if (sub_list == null) return error.AggregateFailed;
    defer release(sub_list);

    const description = dictionary() orelse return error.AggregateFailed;
    CFDictionarySetValue(description, cf("name"), cf(aggregate_name));
    CFDictionarySetValue(description, cf("uid"), cf(uid));
    CFDictionarySetValue(description, cf("private"), kCFBooleanTrue);
    CFDictionarySetValue(description, cf("tapautostart"), kCFBooleanTrue);
    CFDictionarySetValue(description, cf("taps"), tap_list);
    // Without a sub-device the tap has no clock and AudioDeviceStart answers
    // kAudioHardwareIllegalOperationError.
    CFDictionarySetValue(description, cf("subdevices"), sub_list);
    CFDictionarySetValue(description, cf("master"), output_uid);
    return description;
}

/// A UID no earlier run can already hold.
fn runUid(io: std.Io) ![]const u8 {
    const Holder = struct {
        var buffer: [128]u8 = undefined;
    };
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    return std.fmt.bufPrint(&Holder.buffer, "{s}.{d}", .{ aggregate_uid_prefix, stamp });
}

/// The UID of the default output device, which the aggregate runs on.
fn defaultOutputUid() ?*anyopaque {
    var address = PropertyAddress{ .selector = default_output_selector, .scope = scope_global, .element = 0 };
    var device: AudioObjectID = 0;
    var size: u32 = @sizeOf(AudioObjectID);
    if (AudioObjectGetPropertyData(object_system, &address, 0, null, &size, @ptrCast(&device)) != 0) return null;

    address = PropertyAddress{ .selector = uid_selector, .scope = scope_global, .element = 0 };
    var uid: ?*anyopaque = null;
    size = @sizeOf(?*anyopaque);
    if (AudioObjectGetPropertyData(device, &address, 0, null, &size, @ptrCast(&uid)) != 0) return null;
    return uid;
}

fn awaitRegistration(io: std.Io, device: AudioObjectID) !void {
    var attempt: usize = 0;
    while (attempt < registration_attempts) : (attempt += 1) {
        if (isListed(device)) return;
        std.Io.sleep(io, registration_pause, .awake) catch {};
    }
    return error.AggregateUnlisted;
}

fn isListed(device: AudioObjectID) bool {
    var listed: [64]AudioObjectID = undefined;
    for (deviceList(&listed)) |present| {
        if (present == device) return true;
    }
    return false;
}

/// The device IDs the HAL currently lists, written into `buffer`.
fn deviceList(buffer: []AudioObjectID) []AudioObjectID {
    var address = PropertyAddress{ .selector = devices_selector, .scope = scope_global, .element = 0 };
    var size: u32 = 0;
    if (AudioObjectGetPropertyDataSize(object_system, &address, 0, null, &size) != 0) return &.{};

    const count = @min(size / @sizeOf(u32), buffer.len);
    if (count == 0) return &.{};
    size = @intCast(count * @sizeOf(u32));
    if (AudioObjectGetPropertyData(object_system, &address, 0, null, &size, @ptrCast(buffer.ptr)) != 0)
        return &.{};
    return buffer[0 .. size / @sizeOf(u32)];
}

fn dictionary() ?*anyopaque {
    return CFDictionaryCreateMutable(
        null,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    );
}

fn cf(bytes: []const u8) ?*anyopaque {
    var buffer: [256]u8 = undefined;
    if (bytes.len >= buffer.len) return null;
    @memcpy(buffer[0..bytes.len], bytes);
    buffer[bytes.len] = 0;
    return CFStringCreateWithCString(null, buffer[0..bytes.len :0], kCFStringEncodingUTF8);
}

fn release(value: ?*anyopaque) void {
    if (value != null) CFRelease(value);
}

fn fromFourCC(four: *const [4]u8) u32 {
    return (@as(u32, four[0]) << 24) | (@as(u32, four[1]) << 16) | (@as(u32, four[2]) << 8) | four[3];
}

fn sel(name: [*:0]const u8) *anyopaque {
    return sel_registerName(name) orelse unreachable;
}

fn send0(target: ?*anyopaque, selector: *anyopaque) ?*anyopaque {
    const call: *const fn (?*anyopaque, *anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    return call(target, selector);
}

fn send1(target: ?*anyopaque, selector: *anyopaque, argument: ?*anyopaque) ?*anyopaque {
    const call: *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(&objc_msgSend);
    return call(target, selector, argument);
}

fn send1Void(target: ?*anyopaque, selector: *anyopaque, argument: ?*anyopaque) void {
    const call: *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void = @ptrCast(&objc_msgSend);
    call(target, selector, argument);
}

test "the queue hands samples over in order and wraps the buffer" {
    var storage: [8]f32 = undefined;
    var queue = Queue{ .samples = &storage };
    var out: [8]f32 = undefined;

    try std.testing.expectEqual(0, queue.pop(&out));

    // Two rounds that together pass the end of the buffer.
    for ([_][]const f32{ &.{ 1, 2, 3, 4, 5 }, &.{ 6, 7, 8, 9, 10, 11 } }) |batch| {
        queue.push(batch);
        const taken = queue.pop(&out);
        try std.testing.expectEqualSlices(f32, batch[0..taken], out[0..taken]);
        while (queue.pop(&out) > 0) {}
    }
}

test "the queue drops what does not fit instead of overrunning" {
    var storage: [4]f32 = undefined;
    var queue = Queue{ .samples = &storage };
    var out: [8]f32 = undefined;

    queue.push(&.{ 1, 2, 3, 4, 5, 6 });
    try std.testing.expectEqual(@as(usize, 4), queue.pop(&out));
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4 }, out[0..4]);

    // A full queue refuses rather than writing past the storage.
    queue.push(&.{ 7, 8, 9, 10 });
    queue.push(&.{ 11, 12 });
    try std.testing.expectEqual(@as(usize, 4), queue.pop(&out));
}
