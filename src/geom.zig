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

test "the grid indices cover every quad once" {
    const indices = try gridIndices(std.testing.allocator, 3, 2);
    defer std.testing.allocator.free(indices);

    try std.testing.expectEqual(@as(usize, 3 * 2 * 6), indices.len);
    var highest: usize = 0;
    for (indices) |index| highest = @max(highest, index);
    try std.testing.expectEqual(@as(usize, 3 + 1) * (2 + 1) - 1, highest);
}
