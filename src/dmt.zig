//! The DMT fold: the frame is mirrored up and down, left and right, then
//! folded into a turning funnel.
//!
//! `fold` is the whole visual model: it maps a screen point to the texel shown
//! there. Every pass mirrors both axes, shifts a little and samples further
//! out, so the picture repeats as nested, mirrored copies. The funnel pull
//! grows toward the middle, which bends those copies into a funnel. Colour is
//! the frame's own; the effect only moves pixels.

const std = @import("std");
const dvui = @import("dvui");
const geom = @import("geom.zig");

/// Folds an angle into one wedge of a kaleidoscope with `mirrors` facets, so
/// every facet shows the same slice of the frame reflected at its edges.
fn mirrorFold(angle: f32, mirrors: f32) f32 {
    const sector = std.math.tau / mirrors;
    const within = @mod(angle, sector);
    return @min(within, sector - within);
}

/// Everything the audio drives.
pub const FoldShape = struct {
    ring_count: f32 = rings_default,
    heart: f32 = 0,
    mirrors: f32 = 4,
};

/// The band a ring shows at, with every other ring reflected. Adjacent rings
/// meet at their edges, so the picture mirrors from the middle outwards.
fn ringBand(level: f32, band: f32) f32 {
    const parity = @mod(level, 2);
    return if (parity < 1) band else 1 - band;
}

/// Where the ring's picture sits between its two seams. The S-curve is flat at
/// both ends, so the fold line has no slope for the sampler to catch on; it
/// still runs 0 to 1, which keeps the parity flip continuous at a seam.
fn bandWithin(within: f32) f32 {
    const t = std.math.clamp(within, 0, 1);
    return t * t * (3 - 2 * t);
}

/// How far one kick pushes the rings outward, in ring widths.
const kick_push: f32 = 0.25;

/// Rings per e-fold of radius: the default granularity of the tunnel.
pub const rings_default: f32 = 2.2;

/// Ring phase advanced per effect second. Positive means the rings travel
/// outward, from the fulcrum to the edges.
const rush: f32 = 0.9;
/// How far each ring is turned against the next.
const twist: f32 = 0.55;

/// How far one kick swells the virtual window, as a fraction of its scale.
pub const window_pump: f32 = 0.12;

/// Effect speed against the wall clock.
const speed: f32 = 1.6;

/// Vertex every this many physical pixels. Mirror seams are sharp, so the grid
/// has to be fine.
const cell: f32 = 4;
/// Grid vertexes per frame. A window that would need more gets a coarser
/// stride, so the fold's cost stays flat as the window grows.
const vertex_budget: f32 = 260_000;

/// Motion for the effect: seeded speed wander and a turn that flips
/// direction on a schedule, so the loop never settles.
pub const Mood = struct {
    /// Speed against the clock's step.
    rate: f32 = 1,
    /// Radians per effect second; the sign is the turn direction.
    spin: f32 = 0.5,
};

/// The effect's own clock. Mood scales the step, never the elapsed time: a
/// multiplier on elapsed time shifts the phase every time the mood moves.
pub const Clock = struct {
    rush: f64 = 0,
    turn: f64 = 0,

    pub fn advance(self: *Clock, seconds: f64, mood_at: Mood) void {
        self.rush += seconds * @as(f64, mood_at.rate);
        self.turn += seconds * @as(f64, mood_at.spin);
    }
};

/// Seed is time alone: the effect changes without needing a track.
pub fn mood(time: f64) Mood {
    const t: f32 = @floatCast(time);
    const phase = 0.7;

    // 0.8 to 1.3, so the wander never cancels the clock's step.
    const rate = 1.05 + 0.2 * @sin(t * 0.37 + phase) + 0.05 * @sin(t * 0.11 + phase * 1.9);
    const epoch: i64 = @intFromFloat(@floor(time / 6.5));
    const flip: f32 = if (seeded(epoch) & 1 == 0) 1 else -1;

    return .{
        .rate = rate,
        .spin = flip * (0.35 + 0.2 * @sin(t * 0.23 + phase)),
    };
}

/// Splitmix64 over the flip epoch.
fn seeded(epoch: i64) u64 {
    var z = @as(u64, @bitCast(epoch)) +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// The texel shown at `p`.
///
/// `size` is the real window, which bounds the sampled texels; `canvas` is the
/// virtual window the tunnel's geometry is laid out on.
pub fn fold(
    p: dvui.Point.Physical,
    clock: Clock,
    size: dvui.Size.Physical,
    canvas: dvui.Size.Physical,
    shape: FoldShape,
) dvui.Point.Physical {
    if (size.w <= 0 or size.h <= 0) return p;
    if (canvas.w <= 0 or canvas.h <= 0) return p;

    const rush_phase: f32 = @floatCast(clock.rush * speed);
    const turn_phase: f32 = @floatCast(clock.turn * speed);
    // Radius is measured against the virtual window, so the ring the point
    // lands in depends on the canvas and never on how big the real window is.
    const half = @min(canvas.w, canvas.h) / 2;
    const centre = dvui.Point.Physical{ .x = size.w / 2, .y = size.h / 2 };
    const q = dvui.Point.Physical{ .x = p.x - centre.x, .y = p.y - centre.y };
    const radius = @sqrt(q.x * q.x + q.y * q.y);

    // Tunnel: the log radius picks the ring, and the phase pushes every ring
    // outward, so the frame is always leaving the fulcrum.
    const log_radius = @log(radius / half + 0.01);
    const angle0 = std.math.atan2(q.y, q.x);
    // The seams drift with the angle, so the rings wind into a spiral instead
    // of closing into circles. A sine of the angle is continuous through
    // atan2's cut, where a linear shear would leave one hard ray.
    const depth = log_radius * shape.ring_count - rush_phase - shape.heart * kick_push;
    const level = @floor(depth);
    const band = ringBand(level, bandWithin(depth - level));

    // Each ring shows the frame again at a full radius, turned against its
    // neighbour, and alternate rings are turned inside out, so the picture
    // reflects across every ring boundary on its way out from the middle.
    // Mirroring both axes folds that copy into V chevrons.
    //
    // The ring's angle is `turn` twice over, once inside the ring and once as
    // the mirror rotation, so one rotation of the radial unit vector covers
    // both: no atan2, and a single sine and cosine per vertex.
    const turned = angle0 + log_radius * shape.ring_count * twist + turn_phase * 2;
    const angle = mirrorFold(turned, shape.mirrors);
    const around = @cos(angle);
    const across = @sin(angle);
    const reach = half * band;
    // Folding into one quadrant is what mirrors the frame.
    const local = dvui.Point.Physical{ .x = @abs(around) * reach, .y = @abs(across) * reach };

    const source = dvui.Point.Physical{ .x = centre.x + local.x, .y = centre.y + local.y };
    return .{
        .x = wrap(source.x, size.w),
        .y = wrap(source.y, size.h),
    };
}

/// Reflect `v` into `[0, extent]`. The reflection is the fold, so the frame
/// repeats at the border instead of smearing.
fn wrap(v: f32, extent: f32) f32 {
    if (extent <= 0) return v;
    const period = 2 * extent;
    var bounced = @mod(v, period);
    if (bounced < 0) bounced += period;
    if (bounced > extent) bounced = extent * 2 - bounced;
    return bounced;
}

/// A grid of quads over the window, every vertex showing a folded texel.
pub fn mesh(
    arena: std.mem.Allocator,
    cache: *Cache,
    clock: Clock,
    size: dvui.Size.Physical,
    canvas: dvui.Size.Physical,
    shape: FoldShape,
) !geom.Mesh {
    const grid = gridShape(size);
    const across = grid.columns + 1;
    const down = @as(f32, @floatFromInt(grid.rows));
    const right = @as(f32, @floatFromInt(grid.columns));

    const vertexes = try arena.alloc(dvui.Vertex, across * (grid.rows + 1));
    var at: usize = 0;
    for (0..grid.rows + 1) |row| {
        const y = size.h * @as(f32, @floatFromInt(row)) / down;
        for (0..across) |column| {
            const x = size.w * @as(f32, @floatFromInt(column)) / right;
            const source = fold(.{ .x = x, .y = y }, clock, size, canvas, shape);
            vertexes[at] = .{
                .pos = .{ .x = x, .y = y },
                .col = .{ .r = 255, .g = 255, .b = 255 },
                .uv = .{ geom.sampleUV(source.x, size.w), geom.sampleUV(source.y, size.h) },
            };
            at += 1;
        }
    }

    return .{
        .vertexes = vertexes,
        .indices = try cache.indices(grid.columns, grid.rows),
    };
}

const Shape = struct { columns: usize, rows: usize };

/// The grid's topology only changes when the window does, so the index buffer
/// lives here instead of being rebuilt and handed to the frame arena every
/// frame.
pub const Cache = struct {
    columns: usize = 0,
    rows: usize = 0,
    values: []dvui.Vertex.Index = &.{},

    pub fn deinit(self: *Cache) void {
        if (self.values.len > 0) std.heap.page_allocator.free(self.values);
        self.* = .{};
    }

    fn indices(self: *Cache, columns: usize, rows: usize) ![]dvui.Vertex.Index {
        if (self.columns == columns and self.rows == rows and self.values.len > 0) {
            return self.values;
        }
        if (self.values.len > 0) std.heap.page_allocator.free(self.values);

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const built = try geom.gridIndices(arena.allocator(), columns, rows);

        self.values = try std.heap.page_allocator.dupe(dvui.Vertex.Index, built);
        self.columns = columns;
        self.rows = rows;
        return self.values;
    }
};

/// Grid that covers `size`: one vertex per `cell` pixels, coarsened only when
/// a finer grid would need more vertexes than the index buffer can address.
fn gridShape(size: dvui.Size.Physical) Shape {
    const stride = @max(cell, @sqrt(size.w * size.h / vertex_budget));
    return .{
        .columns = @intFromFloat(@max(1, @ceil(size.w / stride))),
        .rows = @intFromFloat(@max(1, @ceil(size.h / stride))),
    };
}

/// Lay the frame back through the fold.
pub fn draw(
    texture: dvui.Texture,
    arena: std.mem.Allocator,
    cache: *Cache,
    clock: Clock,
    size: dvui.Size.Physical,
    canvas: dvui.Size.Physical,
    shape: FoldShape,
) !void {
    if (size.w <= 0 or size.h <= 0) return;
    const bounds = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };

    const grid = try mesh(arena, cache, clock, size, canvas, shape);
    try dvui.renderTriangles(.{
        .vertexes = grid.vertexes,
        .indices = grid.indices,
        .bounds = bounds,
    }, texture);
}

const framesize = dvui.Size.Physical{ .w = 1180, .h = 720 };

test "the fold always samples inside the frame" {
    const time: f64 = 3.7;
    for (0..40) |row| {
        for (0..40) |column| {
            const p = dvui.Point.Physical{
                .x = @as(f32, @floatFromInt(column)) * 29.5,
                .y = @as(f32, @floatFromInt(row)) * 18.0,
            };
            const shown = fold(p, .{ .rush = time }, framesize, framesize, .{});
            try std.testing.expect(shown.x >= 0 and shown.x <= framesize.w);
            try std.testing.expect(shown.y >= 0 and shown.y <= framesize.h);
        }
    }
}

test "the frame is folded, not copied" {
    const time: f64 = 5.0;
    var folded: usize = 0;
    var row: usize = 0;
    while (row < 20) : (row += 1) {
        var column: usize = 0;
        while (column < 20) : (column += 1) {
            const p = dvui.Point.Physical{
                .x = 60 + @as(f32, @floatFromInt(column)) * 55,
                .y = 60 + @as(f32, @floatFromInt(row)) * 32,
            };
            const shown = fold(p, .{ .rush = time }, framesize, framesize, .{});
            if (@abs(shown.x - p.x) + @abs(shown.y - p.y) > 20) folded += 1;
        }
    }
    try std.testing.expect(folded > 100);
}

test "the mirror axes turn with the clock" {
    const p = dvui.Point.Physical{ .x = 700, .y = 300 };
    const before = fold(p, .{ .rush = 0 }, framesize, framesize, .{});
    const after = fold(p, .{ .rush = 1 }, framesize, framesize, .{});
    try std.testing.expect(@abs(before.x - after.x) + @abs(before.y - after.y) > 0.5);
}

test "the phase advances by the step, not by the elapsed time" {
    var clock: Clock = .{};
    var seconds: f64 = 0;
    while (seconds < 120) : (seconds += 0.5) {
        clock.advance(0.5, mood(seconds));
    }

    const before = clock.rush;
    const step = 0.01;
    clock.advance(step, mood(seconds));
    const moved = clock.rush - before;

    // A quarter faster or slower than the step, never a jump of the whole
    // effect clock.
    try std.testing.expect(moved > step * 0.8 and moved < step * 1.3);
}

test "speed and turn are seeded, not stepped" {
    const start = mood(0);
    try std.testing.expect(start.rate > 0.8 and start.rate < 1.3);

    var flips: usize = 0;
    var epoch: i64 = 0;
    while (epoch < 9) : (epoch += 1) {
        const before = mood(@as(f64, @floatFromInt(epoch)) * 6.5 + 0.1).spin;
        const after = mood(@as(f64, @floatFromInt(epoch + 1)) * 6.5 + 0.1).spin;
        if ((before > 0) != (after > 0)) flips += 1;
    }
    try std.testing.expect(flips > 0);

    const one = mood(12.31);
    const again = mood(12.31);
    try std.testing.expectEqual(one.rate, again.rate);
    try std.testing.expectEqual(one.spin, again.spin);
}

test "the tunnel keeps its size when the real window resizes" {
    const clock = Clock{ .rush = 3.5, .turn = 1 };
    const narrow = dvui.Size.Physical{ .w = 1180, .h = 720 };
    const wide = dvui.Size.Physical{ .w = 1920, .h = 1080 };
    const canvas = narrow;

    // The same offset from the centre lands on the same texel offset in both
    // windows: the real window reveals more rings, it does not rescale them.
    for (0..10) |step| {
        const offset = 40 + @as(f32, @floatFromInt(step)) * 90;
        const a = fold(.{ .x = narrow.w / 2 + offset, .y = narrow.h / 2 - offset * 0.4 }, clock, narrow, canvas, .{});
        const b = fold(.{ .x = wide.w / 2 + offset, .y = wide.h / 2 - offset * 0.4 }, clock, wide, canvas, .{});
        try std.testing.expectApproxEqAbs(a.x - narrow.w / 2, b.x - wide.w / 2, 0.001);
        try std.testing.expectApproxEqAbs(a.y - narrow.h / 2, b.y - wide.h / 2, 0.001);
    }
}

test "the fold stays inside the frame at any window and canvas" {
    const clock = Clock{ .rush = 7.3, .turn = 2 };
    for ([_]dvui.Size.Physical{
        .{ .w = 1920, .h = 1080 },
        .{ .w = 3840, .h = 2160 },
        .{ .w = 800, .h = 1400 },
    }) |size| {
        for ([_]f32{ 1, 1.1, 1.3 }) |scale| {
            const canvas = dvui.Size.Physical{ .w = size.w * scale, .h = size.h * scale };
            for (0..12) |row| {
                for (0..12) |column| {
                    const p = dvui.Point.Physical{
                        .x = @as(f32, @floatFromInt(column)) * size.w / 11,
                        .y = @as(f32, @floatFromInt(row)) * size.h / 11,
                    };
                    const shown = fold(p, clock, size, canvas, .{});
                    try std.testing.expect(shown.x >= 0 and shown.x <= size.w);
                    try std.testing.expect(shown.y >= 0 and shown.y <= size.h);
                }
            }
        }
    }
}

test "the fold cache keeps its indices until the grid changes" {
    var cache: Cache = .{};
    defer cache.deinit();

    const first = try cache.indices(3, 2);
    try std.testing.expectEqual(@as(usize, 3 * 2 * 6), first.len);
    const again = try cache.indices(3, 2);
    try std.testing.expect(first.ptr == again.ptr);

    const wider = try cache.indices(4, 2);
    try std.testing.expectEqual(@as(usize, 4 * 2 * 6), wider.len);
    try std.testing.expect(wider.ptr != again.ptr);
}

test "the grid stays inside the vertex budget at any window size" {
    for ([_]dvui.Size.Physical{
        framesize,
        .{ .w = 3840, .h = 2160 },
        .{ .w = 7680, .h = 4320 },
    }) |size| {
        const shape = gridShape(size);
        const across = @as(f32, @floatFromInt(shape.columns + 1));
        const down = @as(f32, @floatFromInt(shape.rows + 1));
        // The stride bounds columns x rows to the budget; rounding each side
        // up costs at most one row and one column apiece.
        try std.testing.expect(across * down <= vertex_budget + 2 * (across + down));
    }
}

test "the kaleidoscope folds every facet the same way" {
    const sector: f32 = std.math.tau / @as(f32, 4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), mirrorFold(0.3, 4), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), mirrorFold(sector + 0.3, 4), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), mirrorFold(sector - 0.2, 4), 0.0001);
    // Two facets fold into a half turn, so opposite sides of the frame agree.
    try std.testing.expectApproxEqAbs(mirrorFold(0.7, 2), mirrorFold(std.math.pi + 0.7, 2), 0.0001);
}

test "the facets fold a point left of the centre onto the right" {
    const size = dvui.Size.Physical{ .w = 400, .h = 400 };
    const left = dvui.Point.Physical{ .x = 120, .y = 200 };

    const folded = fold(left, .{}, size, size, .{});
    try std.testing.expect(folded.x >= 200);
}

test "alternate rings are reflected so the picture mirrors outwards" {
    try std.testing.expectEqual(@as(f32, 0.2), ringBand(0, 0.2));
    try std.testing.expectEqual(@as(f32, 0.8), ringBand(1, 0.2));
    try std.testing.expectEqual(@as(f32, 0.2), ringBand(2, 0.2));

    // The seam between two rings is continuous: both sides show the edge.
    try std.testing.expectApproxEqAbs(ringBand(0, 1), ringBand(1, 0), 0.0001);
    try std.testing.expectApproxEqAbs(ringBand(-1, 0.3), 0.7, 0.0001);
}
