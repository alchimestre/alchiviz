//! A still image painted under the waveform, so the fold repeats a picture
//! instead of an empty page.

const std = @import("std");
const dvui = @import("dvui");
const image = @import("image.zig");

/// Copies of the backdrop across the frame width, and the one place the
/// default is written: the CLI flag, the app field and the wave source all
/// read it from here.
pub const default_tiles: f32 = 8;

/// What `--backdrop` and `--tiles` ask for, passed through as one value.
pub const Options = struct {
    /// Absent draws no backdrop.
    path: ?[]const u8 = null,
    tiles: f32 = default_tiles,
};

pub const Backdrop = struct {
    allocator: std.mem.Allocator,
    /// Decoded pixels, held until the first frame uploads them: dvui textures
    /// cannot be created before a window begins.
    pending: ?image.Image = null,
    uploaded: ?dvui.Texture = null,
    /// Set after a failure is reported, so a broken image costs one line in
    /// the log instead of one per frame.
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Backdrop {
        return .{ .allocator = allocator };
    }

    /// The caller reports the error: `App.init` puts it in the on-screen error
    /// line, and a backdrop that will not load must not stop the frame.
    pub fn open(self: *Backdrop, path: []const u8) !void {
        self.pending = try image.load(self.allocator, path);
    }

    pub fn deinit(self: *Backdrop) void {
        if (self.pending) |pending| pending.deinit(self.allocator);
        self.pending = null;
    }

    /// dvui queues a texture for the window that owns it, so this only works
    /// between `Window.begin` and `Window.end`.
    pub fn release(self: *Backdrop) void {
        if (self.uploaded) |held| dvui.textureDestroyLater(held);
        self.uploaded = null;
    }

    /// The uploaded image, created on first use: dvui textures cannot be made
    /// before a window begins.
    pub fn texture(self: *Backdrop) ?dvui.Texture {
        if (self.failed) return null;
        if (self.uploaded == null) self.upload();
        return self.uploaded;
    }

    fn upload(self: *Backdrop) void {
        const pending = self.pending orelse return;
        self.uploaded = dvui.textureCreate(pending.pma, .{
            .width = pending.width,
            .height = pending.height,
            .interpolation = .nearest,
            .wrap_u = .repeat,
            .wrap_v = .repeat,
        }) catch |err| {
            std.debug.print("backdrop upload failed: {s}\n", .{@errorName(err)});
            self.failed = true;
            return;
        };
        pending.deinit(self.allocator);
        self.pending = null;
    }
};

test "a backdrop that fails to open holds nothing to draw" {
    var backdrop = Backdrop.init(std.testing.allocator);
    defer backdrop.deinit();

    try std.testing.expectError(error.FileNotFound, backdrop.open("/nonexistent/alchi/backdrop.png"));
    try std.testing.expect(backdrop.pending == null);
    try std.testing.expect(backdrop.uploaded == null);
}
