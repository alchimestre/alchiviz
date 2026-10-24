//! The capture history the waveform is drawn from: a rolling window of mono
//! samples and the three band envelopes the waveform is coloured by.
//!
//! The ring is mirrored, so the newest samples are always one contiguous slice
//! and the draw pass never wraps an index.

const std = @import("std");

/// Seconds of capture the waveform shows across the window.
pub const history_seconds: f32 = 6;

/// Edges of the rekordbox-style three-band split.
const low_cutoff: f32 = 150;
const mid_cutoff: f32 = 2000;

pub const Ring = struct {
    samples: []f32,
    low: []f32,
    mid: []f32,
    high: []f32,
    capacity: usize,
    head: usize = 0,
    written: usize = 0,
    /// Total samples accepted since the last reset.
    pushes: u64 = 0,
    rate: f32,
    low_coef: f32,
    mid_coef: f32,
    low_state: f32 = 0,
    mid_state: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, rate: f32) !Ring {
        const capacity: usize = @intFromFloat(@max(1, @ceil(history_seconds * rate)));
        return initWithCapacity(allocator, rate, capacity);
    }

    pub fn initWithCapacity(allocator: std.mem.Allocator, rate: f32, capacity: usize) !Ring {
        const samples = try allocator.alloc(f32, capacity * 2);
        errdefer allocator.free(samples);
        const low = try allocator.alloc(f32, capacity * 2);
        errdefer allocator.free(low);
        const mid = try allocator.alloc(f32, capacity * 2);
        errdefer allocator.free(mid);
        const high = try allocator.alloc(f32, capacity * 2);

        return .{
            .samples = samples,
            .low = low,
            .mid = mid,
            .high = high,
            .capacity = capacity,
            .rate = rate,
            .low_coef = onePoleCoefficient(low_cutoff, rate),
            .mid_coef = onePoleCoefficient(mid_cutoff, rate),
        };
    }

    pub fn deinit(self: *Ring, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        allocator.free(self.low);
        allocator.free(self.mid);
        allocator.free(self.high);
        self.* = undefined;
    }

    /// Forget the capture, keeping the allocation.
    pub fn reset(self: *Ring) void {
        self.head = 0;
        self.written = 0;
        self.pushes = 0;
        self.low_state = 0;
        self.mid_state = 0;
    }

    pub fn push(self: *Ring, raw: f32) void {
        // One non-finite sample would poison the filters and every bar that
        // reads them.
        const sample = if (std.math.isFinite(raw)) raw else 0;

        const low = onePole(&self.low_state, sample, self.low_coef);
        const mid_raw = onePole(&self.mid_state, sample, self.mid_coef);

        const at = self.head;
        self.samples[at] = sample;
        self.samples[at + self.capacity] = sample;
        self.low[at] = @abs(low);
        self.low[at + self.capacity] = @abs(low);
        self.mid[at] = @abs(mid_raw - low);
        self.mid[at + self.capacity] = @abs(mid_raw - low);
        self.high[at] = @abs(sample - mid_raw);
        self.high[at + self.capacity] = @abs(sample - mid_raw);

        self.head = (at + 1) % self.capacity;
        self.pushes +%= 1;
        if (self.written < self.capacity) self.written += 1;
    }

    pub fn newest(self: *const Ring) []const f32 {
        return self.newestOf(self.samples);
    }

    pub fn newestLow(self: *const Ring) []const f32 {
        return self.newestOf(self.low);
    }

    pub fn newestMid(self: *const Ring) []const f32 {
        return self.newestOf(self.mid);
    }

    pub fn newestHigh(self: *const Ring) []const f32 {
        return self.newestOf(self.high);
    }

    fn newestOf(self: *const Ring, values: []const f32) []const f32 {
        const end = self.head + self.capacity;
        return values[end - self.written .. end];
    }
};

/// One column of the waveform: its peak, the body under it, and the band
/// levels that colour it.
pub const Column = struct {
    peak: f32 = 0,
    body: f32 = 0,
    low: f32 = 0,
    mid: f32 = 0,
    high: f32 = 0,
};

/// Mean absolute level around one column's span, with a window reaching
/// `radius` samples past it on both sides so neighbouring bars average into
/// the body under the outline.
pub fn column(ring: *const Ring, from: usize, to: usize, radius: usize) Column {
    const samples = ring.newest();
    if (samples.len == 0) return .{};

    const start = from -| radius;
    const end = @min(samples.len, @max(to, from) + radius);
    if (end <= start) return .{};

    var peak: f32 = 0;
    var sum: f32 = 0;
    for (samples[start..end]) |value| {
        const level = @abs(value);
        peak = @max(peak, level);
        sum += level;
    }

    const bands_end = @min(samples.len, @max(to, from));
    const span = if (bands_end > from) bands_end - from else 0;
    return .{
        .peak = @min(1, peak),
        .body = @min(1, sum / @as(f32, @floatFromInt(end - start))),
        .low = if (span > 0) mean(ring.newestLow()[from..bands_end]) else 0,
        .mid = if (span > 0) mean(ring.newestMid()[from..bands_end]) else 0,
        .high = if (span > 0) mean(ring.newestHigh()[from..bands_end]) else 0,
    };
}

/// What the fold reacts to: a normalised loudness, a slow reference that keeps
/// quiet passages moving the rings, and a kick that fires when the low band
/// jumps above its own average.
pub const Levels = struct {
    level: f32 = 0,
    reference: f32 = 0.08,
    low_average: f32 = 0,
    kick: f32 = 0,

    pub fn update(self: *Levels, newest: Column) void {
        self.reference = @max(newest.peak, self.reference * 0.9995);
        const relative = @min(1, newest.peak / self.reference);
        self.level = self.level * 0.75 + relative * 0.25;

        self.low_average = self.low_average * 0.96 + newest.low * 0.04;
        const excess = @max(0, newest.low - self.low_average * 1.05);
        self.kick = @max(self.kick * 0.92, @min(1, excess * 4));
    }

    /// No samples at all: let both settle instead of leaving the last hit on
    /// screen.
    pub fn silence(self: *Levels) void {
        self.level *= 0.9;
        self.kick *= 0.9;
    }
};

fn mean(values: []const f32) f32 {
    if (values.len == 0) return 0;
    var sum: f32 = 0;
    for (values) |value| sum += value;
    return sum / @as(f32, @floatFromInt(values.len));
}

fn onePoleCoefficient(cutoff: f32, rate: f32) f32 {
    return @exp(-std.math.tau * cutoff / rate);
}

fn onePole(state: *f32, input: f32, coefficient: f32) f32 {
    state.* += (1 - coefficient) * (input - state.*);
    return state.*;
}

fn sine(rate: f32, hz: f32, at: usize) f32 {
    const phase = std.math.tau * hz * @as(f32, @floatFromInt(at)) / rate;
    return @sin(phase);
}

test "the ring hands back the newest samples in order" {
    var ring = try Ring.initWithCapacity(std.testing.allocator, 48000, 5);
    defer ring.deinit(std.testing.allocator);

    for ([_]f32{ 1, 2, 3, 4, 5 }) |value| ring.push(value);

    const newest = ring.newest();
    try std.testing.expectEqual(@as(usize, 5), newest.len);
    try std.testing.expectEqualSlices(f32, &.{ 1, 2, 3, 4, 5 }, newest);

    // Past capacity the oldest samples fall out and the order still holds.
    ring.push(6);
    try std.testing.expectEqualSlices(f32, &.{ 2, 3, 4, 5, 6 }, ring.newest());
}

test "a non-finite sample cannot poison the history" {
    var ring = try Ring.initWithCapacity(std.testing.allocator, 48000, 4);
    defer ring.deinit(std.testing.allocator);

    ring.push(std.math.nan(f32));
    ring.push(std.math.inf(f32));
    ring.push(0.5);

    for (ring.newest()) |value| try std.testing.expect(std.math.isFinite(value));
    for (ring.newestLow()) |value| try std.testing.expect(std.math.isFinite(value));
    for (ring.newestHigh()) |value| try std.testing.expect(std.math.isFinite(value));
    try std.testing.expectEqual(@as(f32, 0.5), ring.newest()[2]);
}

test "the push count follows the capture and resets" {
    var ring = try Ring.initWithCapacity(std.testing.allocator, 48000, 4);
    defer ring.deinit(std.testing.allocator);

    ring.push(0.1);
    ring.push(0.2);
    try std.testing.expectEqual(@as(u64, 2), ring.pushes);

    // The ring wraps but the count keeps going.
    var step: usize = 0;
    while (step < 10) : (step += 1) ring.push(0.3);
    try std.testing.expectEqual(@as(u64, 12), ring.pushes);

    ring.reset();
    try std.testing.expectEqual(@as(u64, 0), ring.pushes);
    try std.testing.expectEqual(@as(usize, 0), ring.newest().len);
}

test "the ring wraps without reordering" {
    var ring = try Ring.initWithCapacity(std.testing.allocator, 48000, 4);
    defer ring.deinit(std.testing.allocator);

    var step: usize = 0;
    while (step < 100) : (step += 1) {
        ring.push(@floatFromInt(step));
        const newest = ring.newest();
        try std.testing.expectEqual(@as(usize, @min(step + 1, 4)), newest.len);
        for (newest, 0..) |value, at| {
            const expected = step + 1 - newest.len + at;
            try std.testing.expectEqual(@as(f32, @floatFromInt(expected)), value);
        }
    }
}

test "a column takes its peak and its body from its span" {
    var ring = try Ring.initWithCapacity(std.testing.allocator, 48000, 8);
    defer ring.deinit(std.testing.allocator);

    for ([_]f32{ 0, 0.5, 1, 0.5, 0 }) |value| ring.push(value);

    const middle = column(&ring, 2, 3, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 1), middle.peak, 1e-6);
    // Body averages the neighbours the radius reaches: (0.5 + 1 + 0.5) / 3.
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), middle.body, 1e-6);
}

test "a low-band spike fires the kick and fades" {
    var levels: Levels = .{};
    const quiet = Column{ .peak = 0.2, .body = 0.1, .low = 0.2 };
    var step: usize = 0;
    while (step < 200) : (step += 1) levels.update(quiet);
    try std.testing.expect(levels.kick < 0.05);

    levels.update(.{ .peak = 0.5, .body = 0.3, .low = 0.5 });
    try std.testing.expect(levels.kick > 0.2);

    const fired = levels.kick;
    step = 0;
    while (step < 20) : (step += 1) levels.update(quiet);
    try std.testing.expect(levels.kick < fired);
}

test "the level follows the capture and settles in silence" {
    var levels: Levels = .{};
    var step: usize = 0;
    while (step < 60) : (step += 1) levels.update(.{ .peak = 0.4, .body = 0.3, .low = 0.1 });
    try std.testing.expect(levels.level > 0.8);

    step = 0;
    while (step < 10) : (step += 1) levels.silence();
    try std.testing.expect(levels.level < 0.5);
}

test "bands split a low tone into low and a high tone into high" {
    var low_ring = try Ring.init(std.testing.allocator, 48000);
    defer low_ring.deinit(std.testing.allocator);
    var high_ring = try Ring.init(std.testing.allocator, 48000);
    defer high_ring.deinit(std.testing.allocator);

    var at: usize = 0;
    while (at < 24000) : (at += 1) {
        low_ring.push(sine(48000, 100, at));
        high_ring.push(sine(48000, 6000, at));
    }

    // A full-scale sine averages 2/pi in absolute value; the split leaves the
    // tone almost entirely in its own band.
    const low_band = column(&low_ring, 20000, 23999, 0);
    try std.testing.expect(low_band.low > 0.4);
    try std.testing.expect(low_band.high < 0.05);

    const high_band = column(&high_ring, 20000, 23999, 0);
    try std.testing.expect(high_band.high > 0.35);
    try std.testing.expect(high_band.low < 0.02);
}
