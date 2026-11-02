//! Image files for the backdrop, decoded by the stb handler dvui already
//! links: PNG, JPEG, BMP, TGA, GIF, PSD and HDR, premultiplied for upload.

const std = @import("std");
const dvui = @import("dvui");

/// No backdrop needs more than this; a bigger file is a mistake, not an image.
const max_file_bytes: usize = 64 * 1024 * 1024;

/// A few kilobytes of PNG can claim 40000x40000 and make stb allocate 6 GiB.
/// Refuse by header before decoding; 16 megapixels covers any real backdrop.
const max_pixels: u64 = 16 * 1024 * 1024;

const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub const Image = struct {
    /// Premultiplied RGBA, ready to hand to `dvui.textureCreate`.
    pma: []dvui.Color.PMA,
    width: u32,
    height: u32,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pma);
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    if (pngSize(bytes)) |size| {
        if (size.width * size.height > max_pixels) return error.ImageTooLarge;
    }
    const loaded = try dvui.Color.PMAImage.fromImageFile("backdrop", allocator, bytes);
    return .{ .pma = loaded.pma, .width = loaded.width, .height = loaded.height };
}

/// Dimensions from a PNG header, or null when the bytes are not a PNG.
fn pngSize(bytes: []const u8) ?struct { width: u64, height: u64 } {
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], &png_signature)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        .width = std.mem.readInt(u32, bytes[16..20], .big),
        .height = std.mem.readInt(u32, bytes[20..24], .big),
    };
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Image {
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
    defer allocator.free(bytes);
    return decode(allocator, bytes);
}

test "a header claiming more pixels than the limit is refused before decoding" {
    const header = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
        0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x9c, 0x40, // 40000
        0x00, 0x00, 0x9c, 0x40, // 40000
        0x08, 0x02, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.ImageTooLarge, decode(std.testing.allocator, &header));
}

test "a png arrives premultiplied and in rgb order" {
    const fixture = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00,
        0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d, 0xb4, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    };
    const image = try decode(std.testing.allocator, &fixture);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqual(@as(usize, 1), image.pma.len);
    // A pure red pixel: stb gives r, g, b, a, and full alpha leaves it alone.
    try std.testing.expectEqual(@as(u8, 0xff), image.pma[0].r);
    try std.testing.expectEqual(@as(u8, 0x00), image.pma[0].g);
    try std.testing.expectEqual(@as(u8, 0x00), image.pma[0].b);
    try std.testing.expectEqual(@as(u8, 0xff), image.pma[0].a);
}
