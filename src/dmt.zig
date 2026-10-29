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
const stages = @import("stages.zig");

/// Folds an angle into one wedge of a kaleidoscope with `mirrors` facets, so
/// every facet shows the same slice of the frame reflected at its edges.
fn mirrorFold(angle: f32, mirrors: f32) f32 {
    if (mirrors <= 1) return angle;
    const sector = std.math.tau / mirrors;
    const within = @mod(angle, sector);
    return @min(within, sector - within);
}

/// The fold's radial law: how a screen radius picks its place in the frame.
pub const Fold = enum {
    /// Log radius, so rings keep their thickness as they run out and the
    /// picture reads as a tunnel receding toward the middle.
    tunnel,
    /// Linear radius, so each ring is wider than the one inside it and the
    /// frame reads as copies of itself expanding from the middle.
    rings,
    /// The rings law without the reflection every other ring carries, so the
    /// frame's own lanes run straight out from the middle.
    branches,
};

/// The radius the rest of the fold measures rings in.
fn depthRadius(kind: Fold, radius: f32, half: f32) f32 {
    return switch (kind) {
        .tunnel => @log(radius / half + 0.01),
        .rings, .branches => radius / half,
    };
}

/// The band a ring shows. Tunnel and rings reflect every other ring, so the
/// picture mirrors from the middle outwards; branches runs them straight, so
/// the frame's lanes continue outward instead of changing direction.
fn foldBand(kind: Fold, level: f32, within: f32) f32 {
    const eased = bandWithin(within);
    return if (kind == .branches) eased else ringBand(level, eased);
}

/// Everything the audio drives.
pub const FoldShape = struct {
    ring_count: f32 = rings_default,
    heart: f32 = 0,
    mirrors: f32 = 4,
    fold: Fold = .tunnel,
};

/// The band a ring shows at, with every other ring reflected, so the picture
/// mirrors from the middle outwards.
fn ringBand(level: f32, band: f32) f32 {
    const parity = @mod(level, 2);
    return if (parity < 1) band else 1 - band;
}

/// Where the ring's picture sits between its two seams. The S-curve is flat at
/// both ends, so the fold line has no slope for the sampler to catch on.
fn bandWithin(within: f32) f32 {
    const t = std.math.clamp(within, 0, 1);
    return t * t * (3 - 2 * t);
}

/// How soft the edge around a still rect is, in pixels.
const calm: f32 = 1.5;

/// The gate: how hard quiet columns are pulled down, as a down-expander
/// threshold. Twice the threshold is where attenuation reaches nothing, so the
/// top of the track attenuates the whole frame.
pub const gate_track: Track = .{ .min = 0, .max = 1 };

/// The ceiling on a captured hit: how much of the capture's own kick reaches the
/// fold. At the right end the hit passes whole; at the left it is blocked.
pub const kick_track: Track = .{ .min = 0, .max = 1 };

/// How far one kick pushes the rings outward, in ring widths.
const kick_push: f32 = 0.8;

/// Rings the loudness adds on top of the lanes slider.
const ring_push: f32 = 2.2;

/// What the beat adds to the fold.
pub const Beat = struct {
    /// Extra lanes while the music is loud.
    rings: f32 = 0,
    /// How much wider the virtual window gets on a hit.
    pump: f32 = 0,
    /// Multiplier on the clock's step, so the tunnel moves with the music.
    pace: f32 = 1,
};

/// The beat's whole grip on the fold. `loudness` is the smoothed level, `kick`
/// the captured hit. Switched off, every term is neutral, so the picture no
/// longer moves with the music at all.
pub fn beat(loudness: f32, kick: f32, enabled: bool) Beat {
    if (!enabled) return .{};
    return .{
        .rings = ring_push * loudness,
        .pump = kick * window_pump,
        .pace = 0.6 + 1.4 * loudness,
    };
}

/// Rings per e-fold of radius: the default granularity of the tunnel.
pub const rings_default: f32 = 2.2;

/// Radians of spin per unit of the clock's turn: the sweep the lanes make.
const spin_rate: f32 = 3;

/// Where in the frame's sweep each lane starts, as a fraction of one, so no two
/// neighbouring lanes show the same picture.
const lane_offset: f32 = 0.37;

/// How far each lane's own copy of the frame is turned against the one inside
/// it.
const spin: f32 = 0.35;

/// How far each ring is turned against the next, by depth rather than by ring
/// index: the index is a step, and a step at a seam shows two different texels
/// on either side of it. Without this every ring samples the same slice, so the
/// outward travel looks frozen the moment the content repeats.
const ring_shift: f32 = 0.6;

/// Ring phase advanced per effect second. Positive means the rings travel
/// outward, from the fulcrum to the edges.
const rush: f32 = 0.9;
/// How far one kick swells the virtual window, as a fraction of its scale.
pub const window_pump: f32 = 0.12;

/// Effect speed against the wall clock. The speed slider scales the step the
/// app feeds the clock, never this.
const speed: f32 = 1.6;

/// A slider's travel: the value range it edits, and the mapping between that
/// value and the slider's 0..1 position.
pub const Track = struct {
    min: f32,
    max: f32,
    /// Equal slider moves are equal magnifications, so the middle of the travel
    /// lands somewhere useful rather than hugging the small end.
    geometric: bool = false,
    /// Whole-number values only, for counts whose seams have to join.
    whole: bool = false,

    /// Where `held` sits on the slider.
    pub fn fraction(self: Track, held: f32) f32 {
        const inside = std.math.clamp(held, self.min, self.max);
        if (self.geometric) return @log(inside / self.min) / @log(self.max / self.min);
        return (inside - self.min) / (self.max - self.min);
    }

    /// The value at slider position `position`.
    pub fn value(self: Track, position: f32) f32 {
        const at = std.math.clamp(position, 0, 1);
        if (self.geometric) return self.min * std.math.pow(f32, self.max / self.min, at);
        const linear = self.min + at * (self.max - self.min);
        return if (self.whole) @round(linear) else linear;
    }
};

/// Slider tracks for the DMT panel. The mixer's DMT mode drove the same seven
/// values, so a slider reads the same amount in either app.
pub const speed_track: Track = .{ .min = 0.2, .max = 2 };

/// 0 holds the window still; 1.2 is the widest swing.
pub const wander_track: Track = .{ .min = 0, .max = 1.2 };

/// The wander itself, as a fraction of the window scale to add to it. Goals are
/// seeded from the time and joined by a smoothstep, so the tunnel breathes
/// without a random walk to carry between frames.
pub fn wander(time: f64, limit: f32) f32 {
    const period: f64 = 5.5;
    const steps = time / period;
    const epoch: i64 = @intFromFloat(@floor(steps));
    const within: f32 = @floatCast(steps - @floor(steps));
    const eased = within * within * (3 - 2 * within);
    const from = wanderGoal(epoch);
    const to = wanderGoal(epoch + 1);
    return limit * (from + (to - from) * eased);
}

/// A goal in [-1, 1), seeded from the wander's epoch.
fn wanderGoal(epoch: i64) f32 {
    const unit = @as(f64, @floatFromInt(seeded(epoch) >> 11)) / 9007199254740992;
    return @floatCast(unit * 2 - 1);
}

/// The virtual window. It opens from the real window and only widens: the left
/// end is the real window, the right end is six times it.
pub const window_track: Track = .{ .min = 1, .max = 6, .geometric = true };

/// The window the fold is laid out on: the real window when DMT started,
/// scaled.
pub fn virtualSize(base: dvui.Size.Physical, scale: f32) dvui.Size.Physical {
    return .{ .w = base.w * scale, .h = base.h * scale };
}

/// Lane count: few wide lanes at the bottom of the track, many thin ones at the
/// top.
pub const rings_track: Track = .{ .min = 0.9, .max = 7 };

/// Kaleidoscope facets.
pub const mirrors_track: Track = .{ .min = 2, .max = 16, .whole = true };

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
    view: Lens,
    size: dvui.Size.Physical,
    canvas: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
) dvui.Point.Physical {
    if (size.w <= 0 or size.h <= 0) return p;
    if (canvas.w <= 0 or canvas.h <= 0) return p;

    // The controls sit out of the fold, with a soft edge so nothing next to
    // them is torn.
    const strength = geom.stillMask(p.x, p.y, stills, view.calm);
    if (strength <= 0) return p;

    // Radius is measured against the virtual window, so the ring the point
    // lands in depends on the canvas and never on how big the real window is.
    const half = @min(canvas.w, canvas.h) / 2;
    const centre = dvui.Point.Physical{ .x = size.w / 2, .y = size.h / 2 };
    const q = dvui.Point.Physical{ .x = p.x - centre.x, .y = p.y - centre.y };
    const radius = @sqrt(q.x * q.x + q.y * q.y);

    // The radius picks the ring, and alternate rings are reflected, so the
    // picture mirrors outwards from the middle.
    const depth_radius = depthRadius(view.fold, radius, half);
    const angle0 = std.math.atan2(q.y, q.x);
    const depth = depth_radius * view.ring_count - view.rush_phase - view.heart * view.kick_push;
    const level = @floor(depth);
    const band = foldBand(view.fold, level, depth - level);

    // Spin turns the whole sampling frame, so the seams and the facets sweep
    // around the middle. It comes before the mirror fold, or the two sides of
    // every mirror would offset by their own angle. The ring shift shears the
    // folded angle, so the lanes wind outward.
    const angle = mirrorFold(angle0 + view.turn_phase * view.spin_rate, view.mirrors) +
        depth * view.ring_shift;

    // Stagger starts each lane at its own point of the sweep, so neighbouring
    // lanes never show the same picture.
    const lane_band = @mod(band + level * view.lane_offset, 1);

    // The sweep: from the middle of the frame out to its edge and back, which
    // is what reads as expansion.
    const reach = half * lane_band;
    const local = dvui.Point.Physical{
        .x = @abs(@cos(angle)) * reach,
        .y = @abs(@sin(angle)) * reach,
    };

    // Each lane turns its own copy of the frame, so the rings stand against
    // each other instead of lining up.
    const turned = level * view.spin;
    const source = dvui.Point.Physical{
        .x = wrap(centre.x + local.x * @cos(turned) - local.y * @sin(turned), size.w),
        .y = wrap(centre.y + local.x * @sin(turned) + local.y * @cos(turned), size.h),
    };
    return .{
        .x = mix(p.x, wrap(source.x, size.w), strength),
        .y = mix(p.y, wrap(source.y, size.h), strength),
    };
}

fn mix(from: f32, to: f32, amount: f32) f32 {
    return from + (to - from) * amount;
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

/// The numbers the fold runs on, so the fragment shader can be fed the same
/// ones the CPU fold uses.
pub const Lens = struct {
    rush_phase: f32,
    turn_phase: f32,
    ring_count: f32,
    heart: f32,
    kick_push: f32,
    mirrors: f32,
    spin_rate: f32,
    spin: f32,
    ring_shift: f32,
    lane_offset: f32,
    calm: f32,
    fold: Fold,
};

/// The lens with the stages that are switched off flattened out: no spin, no
/// facets, no shear, no lane offset, no beat push.
pub fn lens(clock: Clock, shape: FoldShape, toggles: stages.Toggles) Lens {
    const spinning = toggles.enabled(.spin);
    const pushing = toggles.enabled(.kick);
    return .{
        .rush_phase = @floatCast(clock.rush * speed),
        .turn_phase = if (spinning) @floatCast(clock.turn * speed) else 0,
        .ring_count = shape.ring_count,
        .heart = if (pushing) shape.heart else 0,
        .kick_push = if (pushing) kick_push else 0,
        .mirrors = if (toggles.enabled(.mirrors)) shape.mirrors else 1,
        .spin_rate = if (spinning) spin_rate else 0,
        .spin = spin,
        .ring_shift = ring_shift,
        .lane_offset = if (toggles.enabled(.stagger)) lane_offset else 0,
        .calm = calm,
        .fold = shape.fold,
    };
}

/// A grid of quads over the window, every vertex showing a folded texel.
/// The fallback for when the shader pipeline cannot be built; the shader in
/// `gpu.zig` does this on the GPU otherwise.
pub fn mesh(
    arena: std.mem.Allocator,
    cache: *Cache,
    view: Lens,
    size: dvui.Size.Physical,
    canvas: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
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
            const source = fold(.{ .x = x, .y = y }, view, size, canvas, stills);
            const uv = dvui.Point.Physical{
                .x = geom.sampleUV(source.x, size.w),
                .y = geom.sampleUV(source.y, size.h),
            };
            // Depth: the far end of the tunnel is dark and the near rim is
            // bright, so the eye reads the rings as distance coming at it.
            vertexes[at] = .{
                .pos = .{ .x = x, .y = y },
                .col = .{ .r = 255, .g = 255, .b = 255 },
                .uv = .{ uv.x, uv.y },
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
        // Cleared before the rebuild: a failed allocation must not leave a
        // freed pointer with a non-zero len, or the next frame frees it again.
        self.* = .{};

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
    view: Lens,
    size: dvui.Size.Physical,
    canvas: dvui.Size.Physical,
    stills: []const dvui.Rect.Physical,
) !void {
    if (size.w <= 0 or size.h <= 0) return;
    const bounds = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };

    const grid = try mesh(arena, cache, view, size, canvas, stills);
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
            const shown = fold(p, lens(.{ .rush = time }, .{}, .{}), framesize, framesize, &.{});
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
            const shown = fold(p, lens(.{ .rush = time }, .{}, .{}), framesize, framesize, &.{});
            if (@abs(shown.x - p.x) + @abs(shown.y - p.y) > 20) folded += 1;
        }
    }
    try std.testing.expect(folded > 100);
}

test "the mirror axes turn with the clock" {
    const p = dvui.Point.Physical{ .x = 700, .y = 300 };
    const before = fold(p, lens(.{ .rush = 0 }, .{}, .{}), framesize, framesize, &.{});
    const after = fold(p, lens(.{ .rush = 1 }, .{}, .{}), framesize, framesize, &.{});
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

test "each lane samples its own part of the frame" {
    const size = dvui.Size.Physical{ .w = 400, .h = 400 };
    const centre = dvui.Point.Physical{ .x = 200, .y = 200 };
    // Two points at the same angle, one lane apart, land on different points of
    // the frame: the reflection of alternate lanes is what keeps them distinct.
    const radius: f32 = 60;
    const inner = fold(.{ .x = centre.x + radius, .y = centre.y }, lens(.{}, .{}, .{}), size, size, &.{});
    const outer = fold(.{ .x = centre.x + radius * 2, .y = centre.y }, lens(.{}, .{}, .{}), size, size, &.{});
    try std.testing.expect(inner.x != outer.x or inner.y != outer.y);
}

test "alternate rings are reflected so the picture mirrors outwards" {
    try std.testing.expectEqual(@as(f32, 0.2), ringBand(0, 0.2));
    try std.testing.expectEqual(@as(f32, 0.8), ringBand(1, 0.2));
    // The seam between two rings is continuous: both sides show the edge.
    try std.testing.expectApproxEqAbs(ringBand(0, 1), ringBand(1, 0), 0.0001);
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
                    const shown = fold(p, lens(clock, .{}, .{}), size, canvas, &.{});
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

test "a switched-off stage drops out of the lens" {
    const shape = FoldShape{ .mirrors = 6, .heart = 0.8, .ring_count = 3 };
    const clock = Clock{ .rush = 1, .turn = 1 };
    const all_on = lens(clock, shape, .{});

    var toggles = stages.Toggles{};
    for ([_]stages.Stage{ .mirrors, .spin, .stagger, .kick }) |stage| toggles.set(stage, false);
    const plain = lens(clock, shape, toggles);

    try std.testing.expectEqual(@as(f32, 1), plain.mirrors);
    try std.testing.expectEqual(@as(f32, 0), plain.spin_rate);
    try std.testing.expectEqual(@as(f32, 0), plain.heart);
    try std.testing.expectEqual(@as(f32, 0), plain.turn_phase);

    // The ring count and the rush are not a switchable stage and stay put.
    try std.testing.expectEqual(all_on.ring_count, plain.ring_count);
    try std.testing.expectEqual(all_on.rush_phase, plain.rush_phase);
    try std.testing.expect(all_on.spin_rate > 0);
}

test "one facet samples the frame unfolded" {
    const size = dvui.Size.Physical{ .w = 400, .h = 400 };
    const radius: f32 = 90;
    const centre: f32 = 200;
    const angle: f32 = 0.2;
    const sector = @as(f32, std.math.tau) / 6;

    var no_mirrors = stages.Toggles{};
    no_mirrors.set(.mirrors, false);
    const faceted = lens(.{}, .{ .mirrors = 6 }, .{});
    const plain = lens(.{}, .{ .mirrors = 6 }, no_mirrors);

    const at = struct {
        fn point(at_angle: f32, middle: f32, reach: f32) dvui.Point.Physical {
            return .{
                .x = middle + @cos(at_angle) * reach,
                .y = middle + @sin(at_angle) * reach,
            };
        }
    }.point;

    // Six facets fold a full facet apart onto the same angle.
    const faceted_a = fold(at(angle, centre, radius), faceted, size, size, &.{});
    const faceted_b = fold(at(angle + sector, centre, radius), faceted, size, size, &.{});
    try std.testing.expectApproxEqAbs(faceted_a.x, faceted_b.x, 0.001);

    // Without the fold the same two points sample different places.
    const plain_a = fold(at(angle, centre, radius), plain, size, size, &.{});
    const plain_b = fold(at(angle + sector, centre, radius), plain, size, size, &.{});
    try std.testing.expect(@abs(plain_a.x - plain_b.x) > 1 or @abs(plain_a.y - plain_b.y) > 1);
}

test "the facets mirror across their edges" {
    const size = dvui.Size.Physical{ .w = 400, .h = 400 };
    const centre = dvui.Point.Physical{ .x = 200, .y = 200 };
    const radius: f32 = 90;
    const sector: f32 = @as(f32, std.math.tau) / 4;
    const angle: f32 = 0.3;

    const view = lens(.{}, .{ .mirrors = 4 }, .{});
    const first = fold(
        .{ .x = centre.x + @cos(angle) * radius, .y = centre.y + @sin(angle) * radius },
        view,
        size,
        size,
        &.{},
    );
    const mirrored = fold(
        .{ .x = centre.x + @cos(sector - angle) * radius, .y = centre.y + @sin(sector - angle) * radius },
        view,
        size,
        size,
        &.{},
    );

    try std.testing.expectApproxEqAbs(first.x, mirrored.x, 0.001);
    try std.testing.expectApproxEqAbs(first.y, mirrored.y, 0.001);
}

test "every slider track round-trips and clamps" {
    const tracks = [_]Track{ speed_track, wander_track, window_track, rings_track, mirrors_track, gate_track, kick_track };

    for (tracks) |track| {
        for ([_]f32{ 0, 0.25, 0.5, 0.75, 1 }) |position| {
            const held = track.value(position);
            try std.testing.expect(held >= track.min and held <= track.max);
            // A whole-number track can only land within half a step of where it
            // was asked to go.
            const tolerance: f32 = if (track.whole) 0.08 else 0.0001;
            try std.testing.expectApproxEqAbs(position, track.fraction(held), tolerance);
        }
        try std.testing.expectApproxEqAbs(@as(f32, 0), track.fraction(track.min - 5), 0.0001);
        try std.testing.expectApproxEqAbs(@as(f32, 1), track.fraction(track.max + 5), 0.0001);
    }
}

test "the window slider opens from the real window and only widens" {
    const base = dvui.Size.Physical{ .w = 1280, .h = 800 };

    // Leftmost is the real window.
    const closed = virtualSize(base, window_track.value(0));
    try std.testing.expectApproxEqAbs(base.w, closed.w, 0.001);
    try std.testing.expectApproxEqAbs(base.h, closed.h, 0.001);

    // Everything else is larger, and the right end is the widest.
    const middle = virtualSize(base, window_track.value(0.5));
    const wide = virtualSize(base, window_track.value(1));
    try std.testing.expect(closed.w < middle.w);
    try std.testing.expect(middle.w < wide.w);
}

test "the mirror track lands on whole facets inside the range" {
    for ([_]f32{ 0, 0.1, 0.31, 0.62, 1 }) |position| {
        const facets = mirrors_track.value(position);
        try std.testing.expectEqual(facets, @round(facets));
        try std.testing.expect(facets >= mirrors_track.min and facets <= mirrors_track.max);
        try std.testing.expectApproxEqAbs(position, mirrors_track.fraction(facets), 0.08);
    }
}

test "the wander stays inside its limit and never jumps at a seam" {
    const limit: f32 = 0.45;
    var time: f64 = 0;
    while (time < 60) : (time += 0.05) {
        const here = wander(time, limit);
        try std.testing.expect(@abs(here) <= limit + 0.0001);
        try std.testing.expectApproxEqAbs(here, wander(time, limit), 0.0001);
    }

    // Each period hands over to the next goal, so the breathing has no edge.
    var edge: f64 = 5.5;
    while (edge < 60) : (edge += 5.5) {
        const before = wander(edge - 0.001, limit);
        const after = wander(edge + 0.001, limit);
        try std.testing.expect(@abs(before - after) < 0.002);
    }
}

test "the wander reaches both ends of its travel" {
    var lowest: f32 = 0;
    var highest: f32 = 0;
    var time: f64 = 0;
    while (time < 400) : (time += 0.25) {
        const here = wander(time, 1);
        lowest = @min(lowest, here);
        highest = @max(highest, here);
    }
    try std.testing.expect(lowest < -0.5);
    try std.testing.expect(highest > 0.5);
}

test "the lane and mirror sliders change where the fold samples" {
    const clock = Clock{ .rush = 2, .turn = 0.5 };
    const cases = [_]FoldShape{
        .{ .ring_count = rings_track.min },
        .{ .ring_count = rings_track.max },
        .{ .mirrors = mirrors_track.min },
        .{ .mirrors = mirrors_track.max },
    };

    for (cases) |shape| {
        var moved: f32 = 0;
        for (0..6) |row| {
            for (0..6) |column| {
                const p = dvui.Point.Physical{
                    .x = 100 + @as(f32, @floatFromInt(column)) * 180,
                    .y = 80 + @as(f32, @floatFromInt(row)) * 110,
                };
                const base = fold(p, lens(clock, .{}, .{}), framesize, framesize, &.{});
                const shown = fold(p, lens(clock, shape, .{}), framesize, framesize, &.{});
                moved += @abs(shown.x - base.x) + @abs(shown.y - base.y);
            }
        }
        // Summed over a grid, so a single coincidental sample cannot pass it.
        try std.testing.expect(moved > 100);
    }
}


test "the beat leaves the fold steady when the kick stage is off" {
    const off = beat(1, 1, false);
    try std.testing.expectEqual(@as(f32, 0), off.rings);
    try std.testing.expectEqual(@as(f32, 0), off.pump);
    try std.testing.expectEqual(@as(f32, 1), off.pace);

    const on = beat(1, 1, true);
    try std.testing.expect(on.rings > 0);
    try std.testing.expect(on.pump > 0);
    try std.testing.expect(on.pace > 1);
}

test "branches runs the lanes straight where rings reflects them" {
    const across_ring = 0.3;
    try std.testing.expectApproxEqAbs(foldBand(.rings, 0, across_ring), foldBand(.rings, 2, across_ring), 0.0001);
    try std.testing.expectApproxEqAbs(1 - foldBand(.rings, 0, across_ring), foldBand(.rings, 1, across_ring), 0.0001);
    try std.testing.expectApproxEqAbs(foldBand(.branches, 0, across_ring), foldBand(.branches, 1, across_ring), 0.0001);
}

test "the rings fold expands outward where the tunnel recedes" {
    const half: f32 = 100;
    try std.testing.expectApproxEqAbs(@as(f32, 2), depthRadius(.rings, 2 * half, half), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), depthRadius(.rings, half, half), 0.0001);
    try std.testing.expect(depthRadius(.tunnel, 2 * half, half) < depthRadius(.tunnel, half, half) + 0.7);
}
