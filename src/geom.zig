//! Triangle buffers shared by the waveform and the fold.

const std = @import("std");
const dvui = @import("dvui");

pub const Mesh = struct {
    vertexes: []dvui.Vertex,
    indices: []dvui.Vertex.Index,
};

/// Index list for `columns` x `rows` quads, two triangles each.
pub fn gridIndices(arena: std.mem.Allocator, columns: usize, rows: usize) ![]dvui.Vertex.Index {
    const across = columns + 1;
    const indices = try arena.alloc(dvui.Vertex.Index, columns * rows * 6);

    var at: usize = 0;
    for (0..rows) |row| {
        for (0..columns) |column| {
            const top_left = row * across + column;
            const top_right = top_left + 1;
            const bottom_left = top_left + across;
            const bottom_right = bottom_left + 1;

            indices[at] = @intCast(bottom_left);
            indices[at + 1] = @intCast(bottom_right);
            indices[at + 2] = @intCast(top_right);
            indices[at + 3] = @intCast(bottom_left);
            indices[at + 4] = @intCast(top_right);
            indices[at + 5] = @intCast(top_left);
            at += 6;
        }
    }
    return indices;
}

pub fn sampleUV(source: f32, extent: f32) f32 {
    return std.math.clamp(source / extent, 0, 1);
}

/// Zero inside any of `rects`, one beyond `calm` from all of them, smooth in
/// between. The fold multiplies its strength by this so the panel stays flat.
pub fn stillMask(x: f32, y: f32, rects: []const dvui.Rect.Physical, calm: f32) f32 {
    var mask: f32 = 1;
    for (rects) |rect| {
        const dx = @max(@max(rect.x - x, x - (rect.x + rect.w)), 0);
        const dy = @max(@max(rect.y - y, y - (rect.y + rect.h)), 0);
        const distance = @sqrt(dx * dx + dy * dy);
        const t = std.math.clamp(distance / calm, 0, 1);
        mask = @min(mask, t * t * (3 - 2 * t));
    }
    return mask;
}

/// A quad covering `rect`, each corner sampling its own texel, so a control
/// can be painted back exactly as it was drawn.
pub fn quadMesh(arena: std.mem.Allocator, rect: dvui.Rect.Physical, size: dvui.Size.Physical) !Mesh {
    const corners = [_]dvui.Point.Physical{
        .{ .x = rect.x, .y = rect.y },
        .{ .x = rect.x + rect.w, .y = rect.y },
        .{ .x = rect.x + rect.w, .y = rect.y + rect.h },
        .{ .x = rect.x, .y = rect.y + rect.h },
    };

    const vertexes = try arena.alloc(dvui.Vertex, corners.len);
    for (corners, 0..) |corner, at| {
        vertexes[at] = .{
            .pos = corner,
            .col = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            .uv = .{ sampleUV(corner.x, size.w), sampleUV(corner.y, size.h) },
        };
    }

    const indices = try arena.alloc(dvui.Vertex.Index, 6);
    const fan = [_]dvui.Vertex.Index{ 0, 1, 2, 0, 2, 3 };
    @memcpy(indices, &fan);

    return .{ .vertexes = vertexes, .indices = indices };
}

/// Paint every rect in `rects` back from `texture`, untouched.
pub fn repaint(
    arena: std.mem.Allocator,
    rects: []const dvui.Rect.Physical,
    size: dvui.Size.Physical,
    texture: dvui.Texture,
) !void {
    for (rects) |rect| {
        if (rect.w <= 0 or rect.h <= 0) continue;
        const quad = try quadMesh(arena, rect, size);
        try dvui.renderTriangles(.{
            .vertexes = quad.vertexes,
            .indices = quad.indices,
            .bounds = rect,
        }, texture);
    }
}

test "the still mask is flat inside a rect and clear of it" {
    const rects = [_]dvui.Rect.Physical{.{ .x = 10, .y = 10, .w = 40, .h = 20 }};
    try std.testing.expectEqual(@as(f32, 0), stillMask(30, 20, &rects, 2));
    try std.testing.expectEqual(@as(f32, 1), stillMask(100, 100, &rects, 2));
    const edge = stillMask(51, 20, &rects, 2);
    try std.testing.expect(edge > 0 and edge < 1);
    try std.testing.expectEqual(@as(f32, 1), stillMask(30, 20, &.{}, 2));
}

test "the grid indices cover every quad once" {
    const indices = try gridIndices(std.testing.allocator, 3, 2);
    defer std.testing.allocator.free(indices);

    try std.testing.expectEqual(@as(usize, 3 * 2 * 6), indices.len);
    var highest: usize = 0;
    for (indices) |index| highest = @max(highest, index);
    try std.testing.expectEqual(@as(usize, 3 + 1) * (2 + 1) - 1, highest);
}
