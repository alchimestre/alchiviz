//! Keybinds, read from `$XDG_CONFIG_HOME/alchiviz/keys.conf` (or
//! `~/.config/alchiviz/keys.conf`). One `key = action` per line; `#` starts a
//! comment. A missing file, an unreadable one, or a line that names nothing
//! known leaves the defaults, so the window always opens with its keys.

const std = @import("std");
const dvui = @import("dvui");

pub const Action = enum { toggle_ui };

pub const Binds = struct {
    toggle_ui: dvui.enums.Key = .h,
};

pub const template =
    \\# alchiviz keybinds: one "key = action" per line.
    \\# Keys are the names dvui uses: a to z, 0 to 9, escape, space, f1 to f12.
    \\# Actions: toggle-ui.
    \\h = toggle-ui
    \\
;

pub fn load(environ: *const std.process.Environ.Map, io: std.Io) Binds {
    var binds: Binds = .{};

    var content: [4096]u8 = undefined;
    const text = readConfig(environ, io, &content) orelse return binds;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..split], " \t");
        const name = std.mem.trim(u8, line[split + 1 ..], " \t");

        const code = std.meta.stringToEnum(dvui.enums.Key, key) orelse continue;
        switch (actionFor(name) orelse continue) {
            .toggle_ui => binds.toggle_ui = code,
        }
    }
    return binds;
}

/// The file spells actions the way prose does, `toggle-ui`.
fn actionFor(name: []const u8) ?Action {
    const listed = .{.{ "toggle-ui", Action.toggle_ui }};
    inline for (listed) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn readConfig(environ: *const std.process.Environ.Map, io: std.Io, buffer: []u8) ?[]const u8 {
    var path_buffer: [1024]u8 = undefined;
    const path = configPath(environ, &path_buffer) orelse return null;
    return std.Io.Dir.cwd().readFile(io, path, buffer) catch null;
}

/// Where the keybinds live on disk.
pub fn configPath(environ: *const std.process.Environ.Map, buffer: []u8) ?[]const u8 {
    if (environ.get("XDG_CONFIG_HOME")) |base| {
        return std.fmt.bufPrint(buffer, "{s}/alchiviz/keys.conf", .{base}) catch null;
    }
    const home = environ.get("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/alchiviz/keys.conf", .{home}) catch null;
}

test "a bind line names its key and its action" {
    const parsed = std.meta.stringToEnum(dvui.enums.Key, "h");
    try std.testing.expectEqual(dvui.enums.Key.h, parsed.?);
    try std.testing.expectEqual(Action.toggle_ui, actionFor("toggle-ui").?);
    try std.testing.expect(actionFor("nonsense") == null);
}

test "the config path follows the home directory" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    var buffer: [1024]u8 = undefined;
    try std.testing.expect(configPath(&environ, &buffer) == null);
}

test "the template binds hide the panel" {
    try std.testing.expectEqual(dvui.enums.Key.h, (@as(Binds, .{})).toggle_ui);
    try std.testing.expect(std.mem.indexOf(u8, template, "h = toggle-ui") != null);
}
