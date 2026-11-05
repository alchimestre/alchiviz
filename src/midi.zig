//! MIDI control surfaces: CoreMIDI reads controllers on its own thread into a
//! lock-free queue, and a binding table turns the messages into the same values
//! the panel sets. Bindings live in `$XDG_CONFIG_HOME/alchiviz/midi.conf`, or
//! `~/.config/alchiviz/midi.conf` when `XDG_CONFIG_HOME` is unset.

const std = @import("std");
const c = @import("midi-c");
const folding = @import("fold.zig");
const wander = @import("wander.zig");
const stages = @import("stages.zig");

pub const Kind = enum { cc, note };

/// One control movement. A pad's velocity is its value, so a button reads like
/// a knob: 0 is released, 127 is pressed.
pub const Message = struct {
    kind: Kind,
    channel: u4,
    control: u7,
    value: u7,

    pub fn signature(self: Message) Signature {
        return .{ .kind = self.kind, .channel = self.channel, .control = self.control };
    }
};

/// The control a binding listens to. No channel accepts every channel, so a
/// controller that moves to another channel keeps working.
pub const Signature = struct {
    kind: Kind,
    channel: ?u4,
    control: u7,

    pub fn matches(self: Signature, message: Message) bool {
        if (self.kind != message.kind or self.control != message.control) return false;
        const channel = self.channel orelse return true;
        return channel == message.channel;
    }

    /// `cc 5`, `note 41`, `ch 8 cc 5`.
    pub fn label(self: Signature, buffer: []u8) []const u8 {
        const kind = if (self.kind == .cc) "cc" else "note";
        return if (self.channel) |channel|
            std.fmt.bufPrint(buffer, "ch {d} {s} {d}", .{ channel, kind, self.control }) catch kind
        else
            std.fmt.bufPrint(buffer, "{s} {d}", .{ kind, self.control }) catch kind;
    }
};

/// Anything a control can drive.
pub const Target = union(enum) {
    knob: wander.Parameter,
    intensity,
    wander: wander.Parameter,
    stage: stages.Stage,
    /// The fold mapping the dropdown picks, so each one gets its own pad.
    law: folding.Fold,

    /// The row's name in the menu.
    pub fn name(self: Target) []const u8 {
        return switch (self) {
            .knob => |parameter| @tagName(parameter),
            .intensity => "intensity",
            .wander => |parameter| @tagName(parameter),
            .stage => |stage| @tagName(stage),
            .law => |law| @tagName(law),
        };
    }

    /// How the target is written in the config file. Stages, folds and wander
    /// ticks share their names with sliders, so they carry a prefix.
    pub fn key(self: Target, buffer: []u8) []const u8 {
        return switch (self) {
            .knob => |parameter| @tagName(parameter),
            .intensity => "intensity",
            .wander => |parameter| std.fmt.bufPrint(buffer, "wander {s}", .{@tagName(parameter)}) catch @tagName(parameter),
            .stage => |stage| std.fmt.bufPrint(buffer, "stage {s}", .{@tagName(stage)}) catch @tagName(stage),
            .law => |law| std.fmt.bufPrint(buffer, "law {s}", .{@tagName(law)}) catch @tagName(law),
        };
    }

    /// Sliders follow their control's value; switches flip on a press.
    pub fn continuous(self: Target) bool {
        return switch (self) {
            .knob, .intensity => true,
            .wander, .stage, .law => false,
        };
    }
};

/// The rows the menu lists, one column each.
pub const sliders = blk: {
    var list: [1 + std.enums.values(wander.Parameter).len]Target = undefined;
    list[0] = .intensity;
    for (std.enums.values(wander.Parameter), 0..) |parameter, index| list[index + 1] = .{ .knob = parameter };
    break :blk list;
};

pub const wander_ticks = blk: {
    var list: [std.enums.values(wander.Parameter).len]Target = undefined;
    for (std.enums.values(wander.Parameter), 0..) |parameter, index| list[index] = .{ .wander = parameter };
    break :blk list;
};

pub const stages_list = blk: {
    var list: [stages.all.len]Target = undefined;
    for (stages.all, 0..) |stage, index| list[index] = .{ .stage = stage };
    break :blk list;
};

pub const laws = blk: {
    var list: [std.enums.values(folding.Fold).len]Target = undefined;
    for (std.enums.values(folding.Fold), 0..) |law, index| list[index] = .{ .law = law };
    break :blk list;
};

pub const Mode = enum {
    /// The value sets the target directly; anything over half counts as on.
    absolute,
    /// A press flips the target and a release does nothing.
    latch,
    /// Every message flips the target. A pad set to Toggle in Components
    /// sends 127 and 0 on successive presses, so its release is a press here.
    toggle,
};

/// Sliders take a value; everything else takes a press.
pub fn defaultMode(target: Target) Mode {
    return if (target.continuous()) .absolute else .latch;
}

pub const Binding = struct {
    signature: Signature,
    target: Target,
    mode: Mode,
    /// The last value seen, so a latch flips once per press rather than once
    /// per packet.
    last: u7 = 0,
    /// What the controller's light last showed for this binding, so feedback
    /// goes out only when it changes. Not part of the config file.
    lit: ?bool = null,
};

pub const Bindings = struct {
    list: std.ArrayListUnmanaged(Binding) = .empty,

    pub fn deinit(self: *Bindings, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    /// A line read back from the config. Two lines on one control are a macro,
    /// so nothing is deduplicated here.
    pub fn put(self: *Bindings, allocator: std.mem.Allocator, binding: Binding) !void {
        try self.list.append(allocator, binding);
    }

    /// A learned binding: one control and one target each, so a rebind replaces
    /// instead of stacking.
    pub fn assign(self: *Bindings, allocator: std.mem.Allocator, binding: Binding) !void {
        self.removeTarget(binding.target);
        self.removeSignature(binding.signature);
        try self.list.append(allocator, binding);
    }

    pub fn removeTarget(self: *Bindings, target: Target) void {
        var index: usize = 0;
        while (index < self.list.items.len) {
            if (std.meta.eql(self.list.items[index].target, target)) {
                _ = self.list.swapRemove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn removeSignature(self: *Bindings, signature: Signature) void {
        var index: usize = 0;
        while (index < self.list.items.len) {
            if (std.meta.eql(self.list.items[index].signature, signature)) {
                _ = self.list.swapRemove(index);
            } else {
                index += 1;
            }
        }
    }

    pub fn forTarget(self: *const Bindings, target: Target) ?*const Binding {
        for (self.list.items) |*binding| {
            if (std.meta.eql(binding.target, target)) return binding;
        }
        return null;
    }

    pub fn forTargetMut(self: *Bindings, target: Target) ?*Binding {
        for (self.list.items) |*binding| {
            if (std.meta.eql(binding.target, target)) return binding;
        }
        return null;
    }

    /// The file body, one binding per line.
    pub fn text(self: *const Bindings, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, header);
        for (self.list.items) |binding| {
            var line: [160]u8 = undefined;
            var key_buffer: [32]u8 = undefined;
            const kind = if (binding.signature.kind == .cc) "cc" else "note";
            const target = binding.target.key(&key_buffer);
            const written = if (binding.signature.channel) |channel|
                std.fmt.bufPrint(&line, "ch {d} {s} {d} = {s} {s}\n", .{
                    channel, kind, binding.signature.control, target, @tagName(binding.mode),
                })
            else
                std.fmt.bufPrint(&line, "{s} {d} = {s} {s}\n", .{
                    kind, binding.signature.control, target, @tagName(binding.mode),
                });
            try out.appendSlice(allocator, written catch continue);
        }
        return out.toOwnedSlice(allocator);
    }
};

pub const header =
    \\# alchiviz midi: one binding per line.
    \\#   cc 5 = speed              a control change drives a slider
    \\#   note 41 = stage fold      a pad flips a switch
    \\#   note 50 = law rings       a pad picks one of the folds
    \\#   ch 8 cc 5 = blur          "ch" pins the channel, 0 to 15; without it
    \\#                             every channel is accepted
    \\#   cc 20 = speed             two lines on one control are a macro: that
    \\#   cc 20 = blur              control then moves both targets
    \\
;

/// The values a binding writes. Separate from the widgets so a mapping can be
/// tested without a window.
pub const Sink = struct {
    values: *wander.Values,
    intensity: *f32,
    wandering: *std.EnumSet(wander.Parameter),
    toggles: *stages.Toggles,
    law: *folding.Fold,
};

/// Apply one message to every binding that listens to it. Returns whether
/// anything moved.
pub fn apply(bindings: *Bindings, message: Message, sink: Sink) bool {
    var changed = false;
    for (bindings.list.items) |*binding| {
        if (!binding.signature.matches(message)) continue;
        const on = switch (binding.mode) {
            .absolute => message.value >= 64,
            .latch => blk: {
                const pressed = message.value >= 64 and binding.last < 64;
                binding.last = message.value;
                if (!pressed) continue;
                break :blk !switched(binding.target, sink);
            },
            .toggle => blk: {
                binding.last = message.value;
                break :blk !switched(binding.target, sink);
            },
        };
        switch (binding.target) {
            .knob => |parameter| switch (parameter) {
                inline else => |named| {
                    const track = named.track();
                    const fraction = @as(f32, @floatFromInt(message.value)) / 127;
                    @field(sink.values.*, @tagName(named)) = track.value(fraction);
                },
            },
            .intensity => sink.intensity.* = @as(f32, @floatFromInt(message.value)) / 127,
            .wander => |parameter| {
                if (on) sink.wandering.insert(parameter) else sink.wandering.remove(parameter);
            },
            .stage => |stage| sink.toggles.set(stage, on),
            // A fold is a choice, not a switch: pressing its pad picks it.
            .law => |law| sink.law.* = law,
        }
        changed = true;
    }
    return changed;
}

fn switched(target: Target, sink: Sink) bool {
    return switch (target) {
        .wander => |parameter| sink.wandering.contains(parameter),
        .stage => |stage| sink.toggles.enabled(stage),
        .law => |law| sink.law.* == law,
        .knob, .intensity => false,
    };
}

/// What the controller's light should show for a binding, or null when the
/// target is a slider with no light of its own.
pub fn lightOf(binding: Binding, sink: Sink) ?bool {
    return switch (binding.target) {
        .knob, .intensity => null,
        else => switched(binding.target, sink),
    };
}

/// `[ch <n>] (cc|note) <n> = <target> [absolute|latch|toggle]`
pub fn parseLine(line: []const u8) ?Binding {
    // A trailing comment is prose, not a target.
    const code = if (std.mem.indexOfScalar(u8, line, '#')) |comment| line[0..comment] else line;
    const split = std.mem.indexOfScalar(u8, code, '=') orelse return null;
    var left = std.mem.tokenizeAny(u8, code[0..split], " \t");
    var right = std.mem.tokenizeAny(u8, code[split + 1 ..], " \t");

    var signature: Signature = .{ .kind = .cc, .channel = null, .control = 0 };
    var have_control = false;
    while (left.next()) |token| {
        if (std.mem.eql(u8, token, "ch")) {
            const text = left.next() orelse return null;
            signature.channel = std.fmt.parseInt(u4, text, 10) catch return null;
        } else if (std.mem.eql(u8, token, "cc") or std.mem.eql(u8, token, "note")) {
            const text = left.next() orelse return null;
            signature.control = std.fmt.parseInt(u7, text, 10) catch return null;
            signature.kind = if (token[0] == 'n') .note else .cc;
            have_control = true;
        } else return null;
    }
    if (!have_control) return null;

    const target = parseTarget(&right) orelse return null;
    const mode = if (!target.continuous()) blk: {
        if (right.next()) |token| {
            if (std.meta.stringToEnum(Mode, token)) |named| break :blk named;
        }
        break :blk Mode.latch;
    } else Mode.absolute;
    return .{ .signature = signature, .target = target, .mode = mode };
}

fn parseTarget(tokens: *std.mem.TokenIterator(u8, .any)) ?Target {
    const token = tokens.next() orelse return null;
    if (std.mem.eql(u8, token, "intensity")) return .intensity;
    if (std.mem.eql(u8, token, "stage")) {
        const name = tokens.next() orelse return null;
        return .{ .stage = std.meta.stringToEnum(stages.Stage, name) orelse return null };
    }
    if (std.mem.eql(u8, token, "wander")) {
        const name = tokens.next() orelse return null;
        return .{ .wander = std.meta.stringToEnum(wander.Parameter, name) orelse return null };
    }
    if (std.mem.eql(u8, token, "law")) {
        const name = tokens.next() orelse return null;
        return .{ .law = std.meta.stringToEnum(folding.Fold, name) orelse return null };
    }
    return .{ .knob = std.meta.stringToEnum(wander.Parameter, token) orelse return null };
}

pub fn load(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, io: std.Io) Bindings {
    var bindings: Bindings = .{};
    var content: [4096]u8 = undefined;
    var path_buffer: [1024]u8 = undefined;
    const path = configPath(environ, &path_buffer) orelse return bindings;
    const text = std.Io.Dir.cwd().readFile(io, path, &content) catch return bindings;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const binding = parseLine(line) orelse continue;
        bindings.put(allocator, binding) catch return bindings;
    }
    return bindings;
}

/// Write the table back, so a learned control survives a restart.
pub fn save(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bindings: *const Bindings) !void {
    const text = try bindings.text(allocator);
    defer allocator.free(text);

    if (std.fs.path.dirname(path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io, directory);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// One line for the menu when a bind or a write failed.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.OutOfMemory => "out of memory storing the binding",
        else => "could not write the midi config",
    };
}

/// Where the bindings live on disk, beside the keybinds.
pub fn configPath(environ: *const std.process.Environ.Map, buffer: []u8) ?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |base| {
        return std.fmt.bufPrint(buffer, "{s}/alchiviz/midi.conf", .{base}) catch null;
    }
    const home = environ.get("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/alchiviz/midi.conf", .{home}) catch null;
}

/// The open CoreMIDI client and its input port. A controller plugged in after
/// startup needs a restart, which the menu says.
pub const Input = struct {
    client: c.MIDIClientRef = 0,
    port: c.MIDIPortRef = 0,
    /// The port that drives the controller's lights, and the destination it
    /// picked once a source has spoken.
    output: c.MIDIPortRef = 0,
    destination: c.MIDIEndpointRef = 0,
    destination_name: [96]u8 = undefined,
    destination_len: usize = 0,
    sources: usize = 0,
    queue: Queue = .{},
    /// The source that last sent, so the menu names the controller in use
    /// rather than whichever endpoint came first.
    origin: std.atomic.Value(c.MIDIEndpointRef) = std.atomic.Value(c.MIDIEndpointRef).init(0),
    name: [96]u8 = undefined,
    name_len: usize = 0,
    name_origin: c.MIDIEndpointRef = 0,
    started: bool = false,

    /// The queue is the only memory the CoreMIDI thread touches, so the port
    /// gets its address and nothing else. The port lives on the heap so that
    /// address outlives any copy of the struct that owns it.
    pub fn start(allocator: std.mem.Allocator) !*Input {
        const self = try allocator.create(Input);
        errdefer allocator.destroy(self);
        self.* = .{};
        try self.open();
        return self;
    }

    fn open(self: *Input) !void {
        if (self.started) return;
        const name = cfString("alchiviz");
        if (c.MIDIClientCreate(name, null, null, &self.client) != 0) return error.MidiClient;
        if (c.MIDIInputPortCreate(self.client, name, read, &self.queue, &self.port) != 0) {
            _ = c.MIDIClientDispose(self.client);
            self.client = 0;
            return error.MidiPort;
        }
        // Feedback is optional: without an output port the app still plays.
        if (c.MIDIOutputPortCreate(self.client, name, &self.output) != 0) self.output = 0;

        const count = c.MIDIGetNumberOfSources();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const source = c.MIDIGetSource(index);
            if (source == 0) continue;
            // The endpoint comes back on every packet, so the menu can name
            // the controller that is actually moving.
            if (c.MIDIPortConnectSource(self.port, source, @ptrFromInt(@as(usize, source))) == 0) self.sources += 1;
        }
        self.started = true;
    }

    pub fn stop(self: *Input, allocator: std.mem.Allocator) void {
        if (self.started) {
            _ = c.MIDIPortDispose(self.port);
            if (self.output != 0) _ = c.MIDIPortDispose(self.output);
            _ = c.MIDIClientDispose(self.client);
            self.port = 0;
            self.output = 0;
            self.destination = 0;
            self.client = 0;
            self.sources = 0;
            self.started = false;
        }
        allocator.destroy(self);
    }

    /// The next message, oldest first, or null when nothing is waiting. The
    /// queue's sender is copied out here, because only this thread reads it.
    pub fn next(self: *Input) ?Message {
        const message = self.queue.pop();
        if (message != null) self.origin.store(self.queue.origin.load(.acquire), .release);
        return message;
    }

    /// Set one control's light. The Launch Control colours a control from a
    /// channel 1 control change at the control's index, and lights a pad from
    /// a note, so the message mirrors what the control sends. Returns false
    /// when there is nothing to send it to, so the caller does not remember a
    /// light it never set.
    pub fn send(self: *Input, signature: Signature, on: bool) bool {
        if (!self.started or self.output == 0) return false;
        self.resolveDestination();
        if (self.destination == 0) return false;

        const value: u7 = if (on) 127 else 0;
        const channel = signature.channel orelse 0;
        const status: u8 = switch (signature.kind) {
            .cc => 0xB0,
            .note => 0x90 | @as(u8, channel),
        };
        return c.alchiviz_midi_send3(self.output, self.destination, status, signature.control, value) == 0;
    }

    /// Feedback goes to the destination that shares the longest name prefix
    /// with the source that is sending, so two controllers do not talk over
    /// each other's lights.
    fn resolveDestination(self: *Input) void {
        if (self.destination != 0) return;
        const origin = self.origin.load(.acquire);
        if (origin == 0) return;

        var origin_buffer: [96]u8 = undefined;
        const origin_name = origin_buffer[0 .. displayName(origin, &origin_buffer) orelse return];

        var best: c.MIDIEndpointRef = 0;
        var best_shared: usize = 4;
        var best_name: [96]u8 = undefined;
        var best_name_len: usize = 0;
        const count = c.MIDIGetNumberOfDestinations();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const candidate = c.MIDIGetDestination(index);
            if (candidate == 0) continue;
            var name_buffer: [96]u8 = undefined;
            const name = name_buffer[0 .. displayName(candidate, &name_buffer) orelse continue];
            const shared = commonPrefix(origin_name, name);
            if (shared > best_shared) {
                best_shared = shared;
                best = candidate;
                best_name_len = name.len;
                @memcpy(best_name[0..name.len], name);
            }
        }
        self.destination = best;
        self.destination_len = best_name_len;
        @memcpy(self.destination_name[0..best_name_len], best_name[0..best_name_len]);
    }

    /// The destination the lights go to, once one has been picked; the menu
    /// shows it so a controller with no matching destination is visible.
    pub fn destinationName(self: *const Input) ?[]const u8 {
        if (self.destination_len == 0) return null;
        return self.destination_name[0..self.destination_len];
    }

    pub fn deviceName(self: *Input) []const u8 {
        const origin = self.origin.load(.acquire);
        if (origin != self.name_origin) {
            self.name_origin = origin;
            self.name_len = 0;
            if (origin != 0) {
                if (displayName(origin, &self.name)) |length| self.name_len = length;
            }
        }
        if (self.name_len > 0) return self.name[0..self.name_len];
        if (self.sources == 0) return "no controller";
        return "waiting for a message";
    }

    fn cfString(text: [*:0]const u8) c.CFStringRef {
        return @ptrCast(c.CFStringCreateWithCString(null, text, ALCHIVIZ_UTF8));
    }
};

const ALCHIVIZ_UTF8 = c.ALCHIVIZ_UTF8;

/// A single-producer queue: the CoreMIDI thread writes, the frame reads, and a
/// full queue drops the newest message rather than growing.
pub const Queue = struct {
    pub const capacity = 256;
    slots: [capacity]Message = undefined,
    /// The endpoint that sent the newest message, written by the reader.
    origin: std.atomic.Value(c.MIDIEndpointRef) = std.atomic.Value(c.MIDIEndpointRef).init(0),
    head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn push(self: *Queue, message: Message) void {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head -% tail == capacity) return;
        self.slots[head % capacity] = message;
        self.head.store(head +% 1, .release);
    }

    fn pop(self: *Queue) ?Message {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        if (tail == head) return null;
        const message = self.slots[tail % capacity];
        self.tail.store(tail +% 1, .release);
        return message;
    }
};

fn read(list: [*c]const c.MIDIPacketList, ref: ?*anyopaque, connection: ?*anyopaque) callconv(.c) void {
    const queue: *Queue = @ptrCast(@alignCast(ref orelse return));
    if (connection) |endpoint| queue.origin.store(@truncate(@intFromPtr(endpoint)), .release);
    var packet = c.alchiviz_midi_packet_first(list);
    var index: u32 = 0;
    while (index < c.alchiviz_midi_packet_count(list)) : (index += 1) {
        const length = @min(@as(usize, c.alchiviz_midi_packet_length(packet)), 256);
        const bytes = c.alchiviz_midi_packet_bytes(packet)[0..length];
        // The header promises no running status, so every message is whole and
        // three bytes wide.
        var offset: usize = 0;
        while (offset + 3 <= bytes.len) : (offset += 3) {
            if (parseMessage(bytes[offset..][0..3])) |message| queue.push(message);
        }
        packet = c.alchiviz_midi_packet_next(packet);
    }
}

/// Channel voice messages only: control changes and notes. Everything else a
/// controller sends is not a control.
pub fn parseMessage(bytes: []const u8) ?Message {
    if (bytes.len < 3) return null;
    const status = bytes[0];
    const kind: Kind = switch (status & 0xF0) {
        // A note-off is a note-on at zero on most surfaces, including the pads
        // on a Launch Control.
        0x80, 0x90 => .note,
        0xB0 => .cc,
        else => return null,
    };
    if (bytes[1] > 127 or bytes[2] > 127) return null;
    return .{
        .kind = kind,
        .channel = @truncate(status & 0x0F),
        .control = @intCast(bytes[1]),
        .value = if (status & 0xF0 == 0x80) 0 else @intCast(bytes[2]),
    };
}

/// The endpoint's display name, copied into `buffer`. Returns its length, or
/// null when the framework has no name for it.
/// Leading bytes two endpoint names share, so a source is paired with the
/// destination of the same device.
fn commonPrefix(a: []const u8, b: []const u8) usize {
    const shortest = @min(a.len, b.len);
    var index: usize = 0;
    while (index < shortest and a[index] == b[index]) : (index += 1) {}
    return index;
}

fn displayName(endpoint: c.MIDIEndpointRef, buffer: []u8) ?usize {
    var text: c.CFStringRef = null;
    if (c.MIDIObjectGetStringProperty(endpoint, c.kMIDIPropertyDisplayName, &text) != 0 or text == null) return null;
    defer c.CFRelease(text);

    var local: [96]u8 = undefined;
    if (c.CFStringGetCString(text, @ptrCast(&local), local.len, ALCHIVIZ_UTF8) == 0) return null;
    const length = std.mem.len(@as([*:0]const u8, @ptrCast(&local)));
    const copied = @min(length, buffer.len);
    @memcpy(buffer[0..copied], local[0..copied]);
    return copied;
}

/// What `--list-midi` prints: every source the framework reports.
pub fn listSources() void {
    const count = c.MIDIGetNumberOfSources();
    if (count == 0) {
        std.debug.print("no midi sources\n", .{});
        return;
    }
    var index: usize = 0;
    while (index < count) : (index += 1) {
        var buffer: [96]u8 = undefined;
        const length = displayName(c.MIDIGetSource(index), &buffer) orelse {
            std.debug.print("source {d}\n", .{index});
            continue;
        };
        std.debug.print("{s}\n", .{buffer[0..length]});
    }
}

test "a control change reaches the matching binding" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .cc, .channel = null, .control = 5 },
        .target = .{ .knob = .blur },
        .mode = .absolute,
    });

    var values: wander.Values = .{};
    var intensity: f32 = 0;
    var wandering: std.EnumSet(wander.Parameter) = .empty;
    var toggles: stages.Toggles = .{};
    var law: folding.Fold = .tunnel;
    const sink: Sink = .{ .values = &values, .intensity = &intensity, .wandering = &wandering, .toggles = &toggles, .law = &law };

    try std.testing.expect(apply(&bindings, .{ .kind = .cc, .channel = 8, .control = 5, .value = 127 }, sink));
    try std.testing.expectApproxEqAbs(@as(f32, 1), values.blur, 0.001);
    try std.testing.expect(apply(&bindings, .{ .kind = .cc, .channel = 8, .control = 5, .value = 0 }, sink));
    try std.testing.expectApproxEqAbs(@as(f32, 0), values.blur, 0.001);
    try std.testing.expect(!apply(&bindings, .{ .kind = .cc, .channel = 8, .control = 6, .value = 64 }, sink));
    try std.testing.expect(!apply(&bindings, .{ .kind = .note, .channel = 8, .control = 5, .value = 64 }, sink));
}

test "a channel-pinned binding ignores other channels" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .cc, .channel = 8, .control = 5 },
        .target = .{ .knob = .gate },
        .mode = .absolute,
    });
    var values: wander.Values = .{};
    var intensity: f32 = 0;
    var wandering: std.EnumSet(wander.Parameter) = .empty;
    var toggles: stages.Toggles = .{};
    var law: folding.Fold = .tunnel;
    const sink: Sink = .{ .values = &values, .intensity = &intensity, .wandering = &wandering, .toggles = &toggles, .law = &law };

    try std.testing.expect(!apply(&bindings, .{ .kind = .cc, .channel = 7, .control = 5, .value = 127 }, sink));
    try std.testing.expect(apply(&bindings, .{ .kind = .cc, .channel = 8, .control = 5, .value = 127 }, sink));
}

test "a latch flips once per press and ignores the release" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .note, .channel = null, .control = 41 },
        .target = .{ .stage = .mirrors },
        .mode = .latch,
    });
    var values: wander.Values = .{};
    var intensity: f32 = 0;
    var wandering: std.EnumSet(wander.Parameter) = .empty;
    var toggles: stages.Toggles = .{};
    var law: folding.Fold = .tunnel;
    const sink: Sink = .{ .values = &values, .intensity = &intensity, .wandering = &wandering, .toggles = &toggles, .law = &law };

    const pressed: Message = .{ .kind = .note, .channel = 0, .control = 41, .value = 127 };
    const released: Message = .{ .kind = .note, .channel = 0, .control = 41, .value = 0 };
    try std.testing.expect(toggles.mirrors);
    _ = apply(&bindings, pressed, sink);
    try std.testing.expect(!toggles.mirrors);
    // A press that repeats while held does not flip again.
    _ = apply(&bindings, pressed, sink);
    try std.testing.expect(!toggles.mirrors);
    _ = apply(&bindings, released, sink);
    try std.testing.expect(!toggles.mirrors);
    _ = apply(&bindings, pressed, sink);
    try std.testing.expect(toggles.mirrors);
}

test "a toggle pad flips on both of its values" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .note, .channel = 0, .control = 42 },
        .target = .{ .stage = .spin },
        .mode = .toggle,
    });
    var values: wander.Values = .{};
    var intensity: f32 = 0;
    var wandering: std.EnumSet(wander.Parameter) = .empty;
    var toggles: stages.Toggles = .{};
    var law: folding.Fold = .tunnel;
    const sink: Sink = .{ .values = &values, .intensity = &intensity, .wandering = &wandering, .toggles = &toggles, .law = &law };

    const button: Signature = .{ .kind = .note, .channel = 0, .control = 42 };
    try std.testing.expect(toggles.spin);
    // A pad set to Toggle in Components sends 127, then 0, then 127…
    _ = apply(&bindings, .{ .kind = button.kind, .channel = 0, .control = 42, .value = 127 }, sink);
    try std.testing.expect(!toggles.spin);
    _ = apply(&bindings, .{ .kind = button.kind, .channel = 0, .control = 42, .value = 0 }, sink);
    try std.testing.expect(toggles.spin);
    _ = apply(&bindings, .{ .kind = button.kind, .channel = 0, .control = 42, .value = 127 }, sink);
    try std.testing.expect(!toggles.spin);
}

test "each fold picks its law from its own pad" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .note, .channel = 0, .control = 50 },
        .target = .{ .law = .tunnel },
        .mode = .latch,
    });
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .note, .channel = 0, .control = 51 },
        .target = .{ .law = .rings },
        .mode = .latch,
    });
    var values: wander.Values = .{};
    var intensity: f32 = 0;
    var wandering: std.EnumSet(wander.Parameter) = .empty;
    var toggles: stages.Toggles = .{};
    var law: folding.Fold = .mandelbrot;
    const sink: Sink = .{ .values = &values, .intensity = &intensity, .wandering = &wandering, .toggles = &toggles, .law = &law };

    _ = apply(&bindings, .{ .kind = .note, .channel = 0, .control = 51, .value = 127 }, sink);
    try std.testing.expectEqual(folding.Fold.rings, law);

    _ = apply(&bindings, .{ .kind = .note, .channel = 0, .control = 50, .value = 127 }, sink);
    try std.testing.expectEqual(folding.Fold.tunnel, law);

    // A selected fold is lit; the pads for the others are dark.
    const tunnel = bindings.forTarget(.{ .law = .tunnel }).?;
    const rings = bindings.forTarget(.{ .law = .rings }).?;
    try std.testing.expectEqual(true, lightOf(tunnel.*, sink).?);
    try std.testing.expectEqual(false, lightOf(rings.*, sink).?);
}

test "a slider has no light to drive" {
    var values: wander.Values = .{};
    var intensity: f32 = 0;
    var wandering: std.EnumSet(wander.Parameter) = .empty;
    var toggles: stages.Toggles = .{};
    var law: folding.Fold = .tunnel;
    const sink: Sink = .{ .values = &values, .intensity = &intensity, .wandering = &wandering, .toggles = &toggles, .law = &law };

    const binding: Binding = .{
        .signature = .{ .kind = .cc, .channel = null, .control = 5 },
        .target = .{ .knob = .speed },
        .mode = .absolute,
    };
    try std.testing.expect(lightOf(binding, sink) == null);

    const tick: Binding = .{
        .signature = .{ .kind = .cc, .channel = null, .control = 6 },
        .target = .{ .wander = .speed },
        .mode = .latch,
    };
    try std.testing.expectEqual(false, lightOf(tick, sink).?);
}

test "a fold pad and a toggle mode survive the file" {
    const binding = parseLine("note 50 = law rings toggle") orelse return error.NotParsed;
    try std.testing.expectEqual(Mode.toggle, binding.mode);
    try std.testing.expectEqual(folding.Fold.rings, binding.target.law);

    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, binding);
    const text = try bindings.text(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "note 50 = law rings toggle") != null);
}

test "a destination pairs with the source of the same device" {
    try std.testing.expect(commonPrefix("LCXL3 1 MIDI Out", "LCXL3 1 MIDI In") > 4);
    try std.testing.expect(commonPrefix("LCXL3 1 MIDI Out", "Traktor Z1 MK2") < 4);
}

test "two bindings on one control move both targets" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    const signature: Signature = .{ .kind = .cc, .channel = null, .control = 20 };
    try bindings.put(std.testing.allocator, .{ .signature = signature, .target = .{ .knob = .speed }, .mode = .absolute });
    try bindings.put(std.testing.allocator, .{ .signature = signature, .target = .{ .knob = .blur }, .mode = .absolute });

    var values: wander.Values = .{};
    var intensity: f32 = 0;
    var wandering: std.EnumSet(wander.Parameter) = .empty;
    var toggles: stages.Toggles = .{};
    var law: folding.Fold = .tunnel;
    const sink: Sink = .{ .values = &values, .intensity = &intensity, .wandering = &wandering, .toggles = &toggles, .law = &law };
    _ = apply(&bindings, .{ .kind = .cc, .channel = 3, .control = 20, .value = 127 }, sink);
    try std.testing.expectApproxEqAbs(@as(f32, 1), values.blur, 0.001);
    try std.testing.expectApproxEqAbs(wander.Parameter.speed.track().max, values.speed, 0.001);
}

test "learning replaces the control and the target it already had" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    const first: Signature = .{ .kind = .cc, .channel = null, .control = 5 };
    try bindings.assign(std.testing.allocator, .{ .signature = first, .target = .{ .knob = .speed }, .mode = .absolute });
    // The same control learns a second target: the old one goes.
    try bindings.assign(std.testing.allocator, .{ .signature = first, .target = .{ .knob = .blur }, .mode = .absolute });
    try std.testing.expectEqual(@as(usize, 1), bindings.list.items.len);
    try std.testing.expect(bindings.forTarget(.{ .knob = .speed }) == null);
    // A new control learns the target: the old control goes.
    try bindings.assign(std.testing.allocator, .{
        .signature = .{ .kind = .note, .channel = 2, .control = 41 },
        .target = .{ .knob = .blur },
        .mode = .absolute,
    });
    try std.testing.expectEqual(@as(usize, 1), bindings.list.items.len);
    try std.testing.expectEqual(Kind.note, bindings.list.items[0].signature.kind);
}

test "the config round-trips through its own text" {
    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .cc, .channel = 8, .control = 5 },
        .target = .{ .knob = .speed },
        .mode = .absolute,
    });
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .note, .channel = null, .control = 41 },
        .target = .{ .stage = .fold },
        .mode = .latch,
    });
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .cc, .channel = null, .control = 21 },
        .target = .{ .wander = .blur },
        .mode = .latch,
    });

    const written = try bindings.text(std.testing.allocator);
    defer std.testing.allocator.free(written);

    var reparsed: Bindings = .{};
    defer reparsed.deinit(std.testing.allocator);
    var lines = std.mem.splitScalar(u8, written, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        try reparsed.put(std.testing.allocator, parseLine(line) orelse return error.Unparsed);
    }
    try std.testing.expectEqual(@as(usize, 3), reparsed.list.items.len);
    try std.testing.expectEqualDeep(bindings.list.items[0], reparsed.list.items[0]);
    try std.testing.expectEqualDeep(bindings.list.items[1], reparsed.list.items[1]);
    try std.testing.expectEqualDeep(bindings.list.items[2], reparsed.list.items[2]);
}

test "a malformed line names nothing" {
    try std.testing.expect(parseLine("cc 5") == null);
    try std.testing.expect(parseLine("cc 5 = nonsense") == null);
    try std.testing.expect(parseLine("note 41 = stage nothing") == null);
    try std.testing.expect(parseLine("ch 99 cc 5 = speed") == null);
    try std.testing.expect(parseLine("slider 5 = speed") == null);
    const parsed = parseLine("cc 5 = speed").?;
    try std.testing.expectEqual(@as(u7, 5), parsed.signature.control);
    try std.testing.expectEqual(Mode.absolute, parsed.mode);
    // A slider has no switch to latch, so a mode on it is ignored.
    try std.testing.expectEqual(Mode.absolute, parseLine("cc 5 = speed latch").?.mode);
    // A trailing comment is prose.
    try std.testing.expectEqual(wander.Parameter.blur, parseLine("cc 7 = blur # a comment").?.target.knob);
}

test "three bytes become a control change or a note" {
    const cc = parseMessage(&.{ 0xB2, 7, 96 }) orelse return error.NotControl;
    try std.testing.expectEqual(Kind.cc, cc.kind);
    try std.testing.expectEqual(@as(u4, 2), cc.channel);
    try std.testing.expectEqual(@as(u7, 7), cc.control);
    try std.testing.expectEqual(@as(u7, 96), cc.value);

    const pressed = parseMessage(&.{ 0x90, 60, 100 }) orelse return error.NotNote;
    try std.testing.expectEqual(Kind.note, pressed.kind);
    try std.testing.expectEqual(@as(u7, 100), pressed.value);

    const released = parseMessage(&.{ 0x80, 60, 0 }) orelse return error.NotNote;
    try std.testing.expectEqual(@as(u7, 0), released.value);

    try std.testing.expect(parseMessage(&.{ 0xE0, 0, 64 }) == null);
    try std.testing.expect(parseMessage(&.{ 0xB0, 7 }) == null);
    try std.testing.expect(parseMessage(&.{ 0xB0, 200, 7 }) == null);
}

test "the queue keeps order and drops what it cannot hold" {
    var queue: Queue = .{};
    try std.testing.expect(queue.pop() == null);
    queue.push(.{ .kind = .cc, .channel = 1, .control = 2, .value = 10 });
    queue.push(.{ .kind = .cc, .channel = 1, .control = 2, .value = 11 });
    try std.testing.expectEqual(@as(u7, 10), queue.pop().?.value);
    try std.testing.expectEqual(@as(u7, 11), queue.pop().?.value);
    try std.testing.expect(queue.pop() == null);

    for (0..Queue.capacity + 5) |value| {
        queue.push(.{ .kind = .cc, .channel = 0, .control = 1, .value = @intCast(value % 128) });
    }
    var total: usize = 0;
    while (queue.pop() != null) total += 1;
    try std.testing.expectEqual(Queue.capacity, total);
}

test "the config path follows the home directory" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    var buffer: [1024]u8 = undefined;
    try std.testing.expect(configPath(&environ, &buffer) == null);
}

test "a saved table reads back" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var base_buffer: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", base);

    var path_buffer: [1024]u8 = undefined;
    const path = configPath(&environ, &path_buffer) orelse return error.NoConfigPath;

    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .cc, .channel = 8, .control = 5 },
        .target = .{ .knob = .speed },
        .mode = .absolute,
    });
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .note, .channel = 0, .control = 36 },
        .target = .intensity,
        .mode = .latch,
    });
    try save(std.testing.allocator, std.testing.io, path, &bindings);

    var loaded = load(std.testing.allocator, &environ, std.testing.io);
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(bindings.list.items.len, loaded.list.items.len);
    for (bindings.list.items) |binding| {
        const read_back = loaded.forTarget(binding.target) orelse return error.LostBinding;
        try std.testing.expectEqual(binding.signature, read_back.signature);
        // The file carries the control, not the mode: the target picks the mode.
        try std.testing.expectEqual(defaultMode(binding.target), read_back.mode);
    }
}

test "a save that cannot create its directory says so" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var blocker_buffer: [256]u8 = undefined;
    const blocker = try std.fmt.bufPrint(&blocker_buffer, ".zig-cache/tmp/{s}/blocker", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = blocker, .data = "" });

    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/alchiviz/midi.conf", .{blocker});

    var bindings: Bindings = .{};
    defer bindings.deinit(std.testing.allocator);
    try bindings.put(std.testing.allocator, .{
        .signature = .{ .kind = .cc, .channel = 1, .control = 2 },
        .target = .intensity,
        .mode = .absolute,
    });
    try std.testing.expectError(error.NotDir, save(std.testing.allocator, std.testing.io, path, &bindings));
}
