//! The waveform: peak bars across the whole window, coloured by the three
//! bands, with the body under each bar dimmed.

const std = @import("std");
const dvui = @import("dvui");
const signal = @import("signal.zig");

/// Pixels per bar.
const step: f32 = 3;

pub const Color = struct { r: u8, g: u8, b: u8, a: u8 = 0xff };

/// Dracula's window surface, so the fold's dark gaps read as the same frame.
const background = Color{ .r = 0x0b, .g = 0x0b, .b = 0x12 };

/// Mean band levels over a bar, at the brightness of its peak. Low, mid and
/// high own red, green and blue, and brightness follows the square root of the
/// level so quiet bars stay readable.
pub fn tint(level: f32, low: f32, mid: f32, high: f32) Color {
    const strongest = @max(@max(low, @max(mid, high)), 0);
    if (strongest < 0.0001) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    const strength = 0.25 + 0.75 * @sqrt(std.math.clamp(level, 0, 1));
    const gain = 255 * strength / strongest;
    return .{
        .r = @intFromFloat(@min(255, low * gain)),
        .g = @intFromFloat(@min(255, mid * gain)),
        .b = @intFromFloat(@min(255, high * gain)),
    };
}

/// Draw the capture across the window, newest at the right edge.
pub fn draw(arena: std.mem.Allocator, size: dvui.Size.Physical, ring: *const signal.Ring) !void {
    if (size.w <= 0 or size.h <= 0) return;

    const columns: usize = @intFromFloat(@max(1, @ceil(size.w / step)));
    const stats = try arena.alloc(signal.Column, columns);
    fill(stats, ring);
    smooth(stats);
    normalise(stats);

    const quads = columns * 2 + 1;
    const vertexes = try arena.alloc(dvui.Vertex, quads * 4);
    const indices = try arena.alloc(dvui.Vertex.Index, quads * 6);
    var at: Quad = .{ .vertexes = vertexes, .indices = indices, .next = 0 };

    at.append(.{ .x = 0, .y = 0, .w = size.w, .h = size.h }, ambient(stats));
    for (stats, 0..) |stat, index| {
        const left = size.w * @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(columns));
        const right = size.w * @as(f32, @floatFromInt(index + 1)) / @as(f32, @floatFromInt(columns));
        const width = right - left;
        const color = tint(stat.peak, stat.low, stat.mid, stat.high);
        if (color.a == 0) continue;

        const body_h = size.h * stat.body;
        const peak_h = size.h * stat.peak;
        const dim = mix(background, color, 0.45);
        if (body_h > 0) at.append(.{ .x = left, .y = size.h - body_h, .w = width, .h = body_h }, dim);
        if (peak_h > body_h) at.append(.{ .x = left, .y = size.h - peak_h, .w = width, .h = peak_h - body_h }, color);
    }

    // Quads the mix skipped leave the index buffer short; only the used part
    // is drawn.
    try dvui.renderTriangles(.{
        .vertexes = vertexes[0 .. at.next * 4],
        .indices = indices[0 .. at.next * 6],
        .bounds = .{ .x = 0, .y = 0, .w = size.w, .h = size.h },
    }, null);
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
    for (stats, 0..) |*stat, index| {
        const range = barRange(columns, index, span, samples.len) orelse {
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

/// A dim wash in the current spectrum's colour, so the fold has something to
/// repeat even between the bars.
fn ambient(stats: []const signal.Column) Color {
    if (stats.len == 0) return background;
    var low: f32 = 0;
    var mid: f32 = 0;
    var high: f32 = 0;
    for (stats) |stat| {
        low += stat.low;
        mid += stat.mid;
        high += stat.high;
    }
    const count = @as(f32, @floatFromInt(stats.len));
    const colour = tint(0.35, low / count, mid / count, high / count);
    if (colour.a == 0) return background;
    return mix(background, colour, 0.22);
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
        const first: dvui.Vertex.Index = @intCast(self.next * 4);
        const corners = [_]dvui.Point.Physical{
            .{ .x = rect.x, .y = rect.y },
            .{ .x = rect.x + rect.w, .y = rect.y },
            .{ .x = rect.x + rect.w, .y = rect.y + rect.h },
            .{ .x = rect.x, .y = rect.y + rect.h },
        };
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

test "each band owns its RGB channel" {
    const kick = tint(1, 1, 0, 0);
    try std.testing.expect(kick.r == 255 and kick.g == 0 and kick.b == 0);

    const mids = tint(1, 0, 1, 0);
    try std.testing.expect(mids.g == 255 and mids.r == 0 and mids.b == 0);

    const highs = tint(1, 0, 0, 1);
    try std.testing.expect(highs.b == 255 and highs.r == 0 and highs.g == 0);
}

test "quiet bars stay visible but dimmer" {
    const soft = tint(0.1, 0.5, 0, 0).r;
    const loud = tint(1, 0.5, 0, 0).r;
    try std.testing.expect(soft < loud);
    try std.testing.expect(soft > 0);
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

test "silence leaves the background alone" {
    const silent = [_]signal.Column{.{}};
    try std.testing.expectEqual(background, ambient(&silent));
}

test "silence draws nothing" {
    try std.testing.expectEqual(@as(u8, 0), tint(0, 0, 0, 0).a);
}
