//! The frame the fold samples: the capture as nested depth layers, painted
//! through a heat ramp indexed by loudness, depth and column.

const std = @import("std");
const dvui = @import("dvui");
const signal = @import("signal.zig");

/// Pixels per bar.
pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 0xff };

/// Dracula's window surface, so the fold's dark gaps read as the same frame.
const background = Color{ .r = 0x0b, .g = 0x0b, .b = 0x12 };

/// Turns a colour through the wheel, `turns` of a full revolution, keeping its
/// saturation and value. One turn is the identity.
pub fn hueShift(colour: Color, turns: f32) Color {
    const r = @as(f32, @floatFromInt(colour.r)) / 255;
    const g = @as(f32, @floatFromInt(colour.g)) / 255;
    const b = @as(f32, @floatFromInt(colour.b)) / 255;
    const high = @max(r, @max(g, b));
    const low = @min(r, @min(g, b));
    const span = high - low;

    const hue = if (span == 0) 0 else blk: {
        const raw = if (high == r)
            @mod((g - b) / span, 6)
        else if (high == g)
            (b - r) / span + 2
        else
            (r - g) / span + 4;
        break :blk raw / 6;
    };
    const shifted = @mod(hue + turns, 1);
    const saturation = if (high == 0) 0 else span / high;

    return fromHsv(shifted, saturation, high, colour.a);
}

fn fromHsv(hue: f32, saturation: f32, value: f32, alpha: u8) Color {
    const sector = @mod(hue, 1) * 6;
    const offset = sector - @floor(sector);
    const low = value * (1 - saturation);
    const falling = value * (1 - saturation * offset);
    const rising = value * (1 - saturation * (1 - offset));

    const channels = switch (@as(u32, @intFromFloat(@floor(sector))) % 6) {
        0 => .{ value, rising, low },
        1 => .{ falling, value, low },
        2 => .{ low, value, rising },
        3 => .{ low, falling, value },
        4 => .{ rising, low, value },
        else => .{ value, low, falling },
    };
    return .{
        .r = toByte(channels[0]),
        .g = toByte(channels[1]),
        .b = toByte(channels[2]),
        .a = alpha,
    };
}

fn toByte(channel: f32) u8 {
    return @intFromFloat(std.math.clamp(channel * 255, 0, 255));
}

/// How the capture is drawn before the fold repeats it.
pub const Source = struct {
    gate: f32 = 0,
    /// Time in the capture's own clock, so a style that moves stays tied to
    /// the audio rather than to the wall clock.
    phase: f32 = 0,
};

pub fn drawSource(
    arena: std.mem.Allocator,
    size: dvui.Size.Physical,
    ring: *const signal.Ring,
    hue: f32,
    blur: f32,
    source: Source,
) !void {
    if (size.w <= 0 or size.h <= 0) return;
    try terrain(arena, size, ring, hue, blur, source);
}

fn prepare(arena: std.mem.Allocator, ring: *const signal.Ring, blur: f32, columns: usize, gate: f32) ![]signal.Column {
    const stats = try arena.alloc(signal.Column, columns);
    fill(stats, ring);
    compress(stats, gate);
    smooth(stats);
    const scratch = try arena.alloc(signal.Column, stats.len);
    soften(stats, scratch, blur);
    normalise(stats);
    return stats;
}

/// The gate: a column under the threshold is silence, so nothing is drawn for
/// it. Runs before the smoothing, so the gate closes on the capture and not on
/// the drawn envelope.
fn compress(stats: []signal.Column, cutoff: f32) void {
    if (cutoff <= 0) return;
    for (stats) |*stat| {
        const gain = knee(stat.peak, cutoff);
        stat.* = .{
            .peak = stat.peak * gain,
            .body = stat.body * gain,
            .low = stat.low * gain,
            .mid = stat.mid * gain,
            .high = stat.high * gain,
        };
    }
}

/// Smoothstep from silence at zero to no attenuation at twice the threshold, so
/// a column near the threshold fades rather than switching off.
fn knee(peak: f32, cutoff: f32) f32 {
    const t = std.math.clamp(peak / (2 * cutoff), 0, 1);
    return t * t * (3 - 2 * t);
}

fn flush(at: Quad, size: dvui.Size.Physical) !void {
    try dvui.renderTriangles(.{
        .vertexes = at.vertexes[0 .. at.next * 4],
        .indices = at.indices[0 .. at.next * 6],
        .bounds = .{ .x = 0, .y = 0, .w = size.w, .h = size.h },
    }, null);
}

/// The capture as a floor of depth layers: the same waveform drawn again and
/// again, each layer further back, smaller, dimmer, and shifted sideways by a
/// wandering noise. The noise is a function of column, layer and time, so a
/// frame can be reproduced exactly and the wander keeps moving.
fn terrain(arena: std.mem.Allocator, size: dvui.Size.Physical, ring: *const signal.Ring, hue: f32, blur: f32, source: Source) !void {
    const columns: usize = 240;
    const layers: usize = 18;
    const stats = try prepare(arena, ring, blur, columns, source.gate);

    const quads = columns * layers + 1;
    const vertexes = try arena.alloc(dvui.Vertex, quads * 4);
    const indices = try arena.alloc(dvui.Vertex.Index, quads * 6);
    var at: Quad = .{ .vertexes = vertexes, .indices = indices, .next = 0 };
    at.append(.{ .x = 0, .y = 0, .w = size.w, .h = size.h }, background);

    // Far layers first, so the near ones cover them.
    for (0..layers) |layer| {
        const t = @as(f32, @floatFromInt(layer)) / @as(f32, @floatFromInt(layers - 1));
        const scale = 0.55 + 0.45 * t;
        const gain = size.h * 0.30 * (0.65 + 0.35 * t);
        const width = size.w / @as(f32, @floatFromInt(columns)) * scale;
        const span = width * @as(f32, @floatFromInt(columns));

        const inset = (size.w - span) / 2;
        const baseline = size.h * (0.42 + 0.46 * t);
        const dim = mix(background, .{ .r = 0xff, .g = 0xff, .b = 0xff }, 0.75 + 0.25 * t);

        for (stats, 0..) |stat, index| {
            const height = gain * stat.peak;
            if (height < 1) continue;
            const wander = wobble(index, layer, source.phase) * size.w * 0.05 * (1 - t);
            const left = inset + width * @as(f32, @floatFromInt(index)) + wander;
            // Heatmap: loudness picks the ramp, depth slides along it, and the
            // columns sweep it too, so the floor spans every hue instead of
            // one band of them.
            const loudness = @min(1, stat.peak * 0.85 + stat.high * 0.5);
            const sweep = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(columns));
            const shade = hueShift(heat(@mod(loudness * 0.7 + t * 0.2 + sweep * 0.45, 1)), hue);
            const color = mul(shade, dim);
            at.append(.{ .x = left, .y = baseline - height, .w = width, .h = height }, color);
        }
    }
    try flush(at, size);
}

/// Heatmap ramp: cold for quiet, red for loud, with the depth layer sliding
/// along it so the floor of ridges reads as a gradient rather than one colour.
fn heat(value: f32) Color {
    const stops = [_]Color{
        .{ .r = 0x12, .g = 0x1b, .b = 0x4a },
        .{ .r = 0x00, .g = 0x9f, .b = 0xd0 },
        .{ .r = 0x2e, .g = 0xd0, .b = 0x6a },
        .{ .r = 0xff, .g = 0xd1, .b = 0x3a },
        .{ .r = 0xff, .g = 0x45, .b = 0x2a },
    };
    const along = std.math.clamp(value, 0, 1) * @as(f32, @floatFromInt(stops.len - 1));
    const lower: usize = @intFromFloat(@min(@floor(along), @as(f32, @floatFromInt(stops.len - 2))));
    return mix(stops[lower], stops[lower + 1], along - @as(f32, @floatFromInt(lower)));
}

/// Smooth pseudo noise over column, layer and time: three sines, no state, so
/// the same frame always draws the same way.
fn wobble(index: usize, layer: usize, phase: f32) f32 {
    const x = @as(f32, @floatFromInt(index)) * 0.13;
    const z = @as(f32, @floatFromInt(layer)) * 0.9;
    return @sin(x + phase * 0.9 + @sin(z * 1.7)) * @cos(z * 0.6 + x * 0.4 + phase * 0.3);
}

/// Scales a colour, keeping its alpha.
fn mul(colour: Color, by: Color) Color {
    return .{
        .r = @intCast(@as(u32, colour.r) * by.r / 255),
        .g = @intCast(@as(u32, colour.g) * by.g / 255),
        .b = @intCast(@as(u32, colour.b) * by.b / 255),
        .a = colour.a,
    };
}

fn fill(stats: []signal.Column, ring: *const signal.Ring) void {
    for (stats) |*stat| stat.* = .{};

    const samples = ring.newest();
    if (samples.len == 0) return;

    // The window shows a fixed span of time, newest at the right. Until the
    // history holds that much, the columns before the capture started stay
    // empty and the waveform scrolls in from the right edge.
    const span: usize = @intFromFloat(@max(1, signal.history_seconds * ring.rate));

    const columns = stats.len;
    // Bin on whole bars: audio arrives in callbacks shorter than a bar, so
    // binning on the raw count re-sliced every bar mid-frame. Quantising keeps
    // a bar on the same audio between callbacks.
    const width = @max(1, span / columns);
    const settled = samples.len / width * width;
    for (stats, 0..) |*stat, index| {
        const range = barRange(columns, index, span, settled) orelse {
            stat.* = .{};
            continue;
        };
        const radius = @max(1, (range.to - range.from) / 2);
        stat.* = signal.column(ring, range.from, @max(range.to, range.from + 1), radius);
    }
}

const Range = struct { from: usize, to: usize };

/// The samples one bar reads, newest at the right edge. Null when the bar's
/// newest end is older than the whole capture.
fn barRange(columns: usize, index: usize, span: usize, available: usize) ?Range {
    const left_age = span * (columns - index) / columns;
    const right_age = span * (columns - index - 1) / columns;
    if (right_age >= available) return null;

    return .{
        .from = available - @min(left_age, available),
        .to = available - right_age,
    };
}

/// Scale the bars against the loudest one on screen, so a quiet capture still
/// fills the window. The scaling is one factor for the whole frame: a per-bar
/// factor would flatten the envelope into a wall.
fn normalise(stats: []signal.Column) void {
    var loudest: f32 = 0;
    for (stats) |stat| loudest = @max(loudest, stat.peak);
    const reference = @max(0.08, loudest);
    for (stats) |*stat| {
        stat.peak = @min(1, stat.peak / reference);
        stat.body = @min(1, stat.body / reference);
    }
}

/// Columns the soften pass reaches across at full blur.
const max_soften: usize = 24;

/// Average the columns over a window that grows with the blur slider. The fold
/// repeats this waveform, so fewer, softer bars read as a blurred tunnel
/// without a second render target.
fn soften(stats: []signal.Column, scratch: []signal.Column, blur: f32) void {
    const radius: usize = @intFromFloat(@round(std.math.clamp(blur, 0, 1) * max_soften));
    if (radius == 0 or stats.len == 0) return;

    const source = scratch[0..stats.len];
    @memcpy(source, stats);
    const width = radius * 2 + 1;

    for (stats, 0..) |*stat, index| {
        var sum: signal.Column = .{};
        for (0..width) |offset| {
            const shifted = @as(isize, @intCast(index)) + @as(isize, @intCast(offset)) - @as(isize, @intCast(radius));
            const at: usize = @intCast(std.math.clamp(shifted, 0, @as(isize, @intCast(stats.len - 1))));
            sum.peak += source[at].peak;
            sum.body += source[at].body;
            sum.low += source[at].low;
            sum.mid += source[at].mid;
            sum.high += source[at].high;
        }
        const count: f32 = @floatFromInt(width);
        stat.* = .{
            .peak = sum.peak / count,
            .body = sum.body / count,
            .low = sum.low / count,
            .mid = sum.mid / count,
            .high = sum.high / count,
        };
    }
}

/// Weight each bar with its neighbours, so the outline reads as a shape rather
/// than a picket fence.
fn smooth(stats: []signal.Column) void {
    if (stats.len == 0) return;
    var previous = stats[0];
    for (stats, 0..) |*stat, index| {
        const current = stat.*;
        const next = stats[@min(index + 1, stats.len - 1)];
        stat.peak = previous.peak * 0.25 + current.peak * 0.5 + next.peak * 0.25;
        stat.body = previous.body * 0.25 + current.body * 0.5 + next.body * 0.25;
        previous = current;
    }
}

fn mix(from: Color, to: Color, amount: f32) Color {
    const t = std.math.clamp(amount, 0, 1);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(from.r)) + (@as(f32, @floatFromInt(to.r)) - @as(f32, @floatFromInt(from.r))) * t),
        .g = @intFromFloat(@as(f32, @floatFromInt(from.g)) + (@as(f32, @floatFromInt(to.g)) - @as(f32, @floatFromInt(from.g))) * t),
        .b = @intFromFloat(@as(f32, @floatFromInt(from.b)) + (@as(f32, @floatFromInt(to.b)) - @as(f32, @floatFromInt(from.b))) * t),
    };
}

const Quad = struct {
    vertexes: []dvui.Vertex,
    indices: []dvui.Vertex.Index,
    next: usize = 0,

    fn append(self: *Quad, rect: dvui.Rect.Physical, color: Color) void {
        self.appendCorners(.{
            .{ .x = rect.x, .y = rect.y },
            .{ .x = rect.x + rect.w, .y = rect.y },
            .{ .x = rect.x + rect.w, .y = rect.y + rect.h },
            .{ .x = rect.x, .y = rect.y + rect.h },
        }, color);
    }

    fn appendCorners(self: *Quad, corners: [4]dvui.Point.Physical, color: Color) void {
        const first: dvui.Vertex.Index = @intCast(self.next * 4);
        for (corners, 0..) |corner, index| {
            self.vertexes[self.next * 4 + index] = .{
                .pos = corner,
                .col = .fromColor(.{ .r = color.r, .g = color.g, .b = color.b, .a = color.a }),
                .uv = .{ 0, 0 },
            };
        }
        const fan = [_]dvui.Vertex.Index{ 0, 1, 2, 0, 2, 3 };
        for (fan, 0..) |offset, index| self.indices[self.next * 6 + index] = first + offset;
        self.next += 1;
    }
};

test "the heat ramp runs from cold to hot" {
    const cold = heat(0);
    const hot = heat(1);
    try std.testing.expect(cold.b > cold.r);
    try std.testing.expect(hot.r > hot.b);
    try std.testing.expect(heat(0.5).g > heat(0).g);
    // Out of range values clamp instead of reading past the stops.
    try std.testing.expectEqual(cold.r, heat(-3).r);
    try std.testing.expectEqual(hot.r, heat(9).r);
}

test "the terrain noise is bounded and repeatable" {
    for (0..64) |index| {
        for (0..18) |layer| {
            const once = wobble(index, layer, 1.25);
            const again = wobble(index, layer, 1.25);
            try std.testing.expectEqual(once, again);
            try std.testing.expect(@abs(once) <= 1);
        }
    }
    // It moves with time, or the wander would freeze.
    try std.testing.expect(wobble(7, 3, 1.25) != wobble(7, 3, 1.30));
}

test "the gate pulls quiet columns down without cutting them" {
    var stats = [_]signal.Column{
        .{ .peak = 0.02, .low = 0.4 },
        .{ .peak = 0.1, .mid = 0.5 },
        .{ .peak = 0.15, .high = 0.6 },
        .{ .peak = 0.5, .high = 0.7 },
        .{},
    };
    compress(&stats, 0.1);

    // Under the knee: pulled far down, but never switched off.
    try std.testing.expect(stats[0].peak > 0);
    try std.testing.expect(stats[0].peak < 0.02 * 0.2);
    try std.testing.expect(stats[0].low > 0);
    // At the threshold: half the level. Past twice it: untouched.
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), stats[1].peak, 0.0001);
    try std.testing.expect(stats[2].peak > 0.1);
    try std.testing.expect(stats[2].peak < 0.15);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stats[3].peak, 0.0001);
    // Silence stays silent, and zero cutoff leaves the frame alone.
    try std.testing.expectEqual(@as(f32, 0), stats[4].peak);
    compress(&stats, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stats[3].peak, 0.0001);
}

test "bars read the span from the right edge inwards" {
    const full = barRange(10, 9, 100, 100).?;
    try std.testing.expectEqual(@as(usize, 90), full.from);
    try std.testing.expectEqual(@as(usize, 100), full.to);

    const leftmost = barRange(10, 0, 100, 100).?;
    try std.testing.expectEqual(@as(usize, 0), leftmost.from);
    try std.testing.expectEqual(@as(usize, 10), leftmost.to);
}

test "bars before the capture started stay empty" {
    // Half the span captured: the left half has nothing to draw.
    try std.testing.expectEqual(@as(?Range, null), barRange(10, 0, 100, 50));
    try std.testing.expectEqual(@as(?Range, null), barRange(10, 4, 100, 50));

    const filled = barRange(10, 5, 100, 50).?;
    try std.testing.expectEqual(@as(usize, 0), filled.from);
    try std.testing.expectEqual(@as(usize, 10), filled.to);
}

test "the bars are scaled against the loudest one on screen" {
    var stats = [_]signal.Column{
        .{ .peak = 0.2, .body = 0.1 },
        .{ .peak = 0.1, .body = 0.05 },
        .{ .peak = 0, .body = 0 },
    };
    normalise(&stats);
    try std.testing.expectApproxEqAbs(@as(f32, 1), stats[0].peak, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stats[1].peak, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), stats[1].body, 1e-6);
    try std.testing.expectEqual(@as(f32, 0), stats[2].peak);
}

test "a quiet capture still fills part of the window" {
    var stats = [_]signal.Column{.{ .peak = 0.02, .body = 0.01 }};
    normalise(&stats);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), stats[0].peak, 1e-6);
}

test "blur softens the columns and leaves them alone at zero" {
    var stats: [64]signal.Column = undefined;
    for (&stats, 0..) |*stat, index| {
        stat.* = .{ .peak = if (index % 2 == 0) 1 else 0, .body = 0.5, .low = 0.2, .mid = 0.1, .high = 0.05 };
    }
    const before = stats;

    var scratch: [64]signal.Column = undefined;
    soften(&stats, &scratch, 0);
    for (stats, before) |got, want| try std.testing.expectEqual(want.peak, got.peak);

    soften(&stats, &scratch, 1);
    // The one-column peak/trough pattern is averaged away; the body of the
    // waveform survives, so the bars get soft rather than empty.
    try std.testing.expect(stats[32].peak > 0.3 and stats[32].peak < 0.7);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stats[32].body, 0.05);

    var sum: f32 = 0;
    for (stats) |stat| sum += stat.peak;
    try std.testing.expectApproxEqAbs(@as(f32, 32), sum, 3);
}

test "the colour slider slides the ramp through the wheel" {
    const red = Color{ .r = 200, .g = 40, .b = 40 };

    // Zero and one turn both land back on the colour, inside rounding.
    const still = hueShift(red, 0);
    try expectChannel(red.r, still.r);
    try expectChannel(red.g, still.g);
    const turned = hueShift(red, 1);
    try expectChannel(red.r, turned.r);
    try expectChannel(red.g, turned.g);

    // A third of a turn takes red to green, two thirds to blue.
    const green = hueShift(red, 1.0 / 3.0);
    try std.testing.expect(green.g > green.r and green.g > green.b);
    const blue = hueShift(red, 2.0 / 3.0);
    try std.testing.expect(blue.b > blue.r and blue.b > blue.g);

    // The shift keeps the tint's strength, so the ramp never goes grey or white.
    try std.testing.expectEqual(red.a, green.a);
    try std.testing.expect(green.g - green.b > 60);
    try std.testing.expectEqual(@as(u8, 0), hueShift(.{ .r = 0, .g = 0, .b = 0, .a = 0 }, 0.5).a);
}

/// One step of 8-bit rounding is the most the wheel can cost a channel.
fn expectChannel(expected: u8, actual: u8) !void {
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected)), @as(f32, @floatFromInt(actual)), 2);
}
