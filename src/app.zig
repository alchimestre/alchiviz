//! The window: capture in, waveform out, the fold laid over it.

const std = @import("std");
const dvui = @import("dvui");
const audio = @import("audio.zig");
const dmt = @import("dmt.zig");
const geom = @import("geom.zig");
const signal = @import("signal.zig");
const tap = @import("tap.zig");
const keys = @import("keys.zig");
const gpu = @import("gpu.zig");
const wave = @import("wave.zig");
const stages = @import("stages.zig");
const blurbs = @import("blurbs.zig");

const panel = dvui.Color{ .r = 0x14, .g = 0x14, .b = 0x1f, .a = 0xff };
const ink = dvui.Color{ .r = 0xf8, .g = 0xf8, .b = 0xf2, .a = 0xff };
const muted = dvui.Color{ .r = 0x8a, .g = 0x8a, .b = 0x9e, .a = 0xff };

fn maybeStills(hidden: bool, stills: []const dvui.Rect.Physical) []const dvui.Rect.Physical {
    return if (hidden) &.{} else stills;
}

/// One swatch of the colour bar. Explicit rect, so the cells stack over each
/// other instead of taking positions from the box's layout.
fn paintCell(id: u32, extra: u32, rect: struct { x: f32, w: f32, h: f32 }, colour: wave.Color) void {
    var cell: dvui.BoxWidget = undefined;
    cell.init(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id + extra,
        .rect = .{
            .x = rect.x,
            .y = 0,
            .w = rect.w,
            .h = rect.h,
        },
        .padding = .{},
        .margin = .{},
        .background = true,
        .border = .{},
        .color_fill = .{ .color = dvui.Color{
            .r = colour.r,
            .g = colour.g,
            .b = colour.b,
            .a = colour.a,
        } },
    });
    cell.drawBackground();
    cell.deinit();
}

fn inside(rect: dvui.Rect.Physical, point: dvui.Point.Physical) bool {
    return point.x >= rect.x and point.x < rect.x + rect.w and
        point.y >= rect.y and point.y < rect.y + rect.h;
}

/// The swapchain the frame is drawing into, handed over by the loop.
pub const GpuFrame = struct {
    cmd: ?*anyopaque = null,
    swapchain: ?*anyopaque = null,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    devices: []audio.Device,
    names: [][]const u8,
    selected: usize = 0,
    input: audio.Input = .{},
    /// The system-output tap, when the machine allowed one. When it exists it
    /// is the first entry in `names`, and it captures through its own device
    /// rather than through `input`.
    system_tap: ?tap.SystemTap = null,
    /// Why the tap is missing, when it is: without this the panel silently
    /// offers the microphone and the system output looks like a missing driver.
    tap_failure: ?anyerror = null,
    ring: ?signal.Ring = null,
    open: bool = false,

    wave_target: ?dvui.Texture.Target = null,
    frame_target: ?dvui.Texture.Target = null,
    fold_cache: dmt.Cache = .{},
    clock: dmt.Clock = .{},
    elapsed: f64 = 0,
    last_ns: i96 = 0,
    now_ns: i96 = 0,
    last_sample_ns: i96 = 0,
    levels: signal.Levels = .{},

    /// The DMT panel: the same seven values the mixer's DMT mode exposed.
    effect_speed: f32 = 1,
    window_wander_limit: f32 = 0.45,
    virtual_scale: f32 = 1,
    virtual_base: ?dvui.Size.Physical = null,
    lane_rings: f32 = dmt.rings_default,
    lane_mirrors: f32 = 4,
    kick_pump: f32 = 1,
    lane_colour: f32 = 0,
    blur: f32 = 0,
    gate: f32 = 0,
    /// Which pipeline stages are switched on. Every stage has a toggle in the
    /// right panel; the blurb under the window describes the one hovered.
    toggles: stages.Toggles = .{},
    fold_kind: dmt.Fold = .tunnel,
    blurb_focus: blurbs.Subject = .{ .stage = .fold },
    /// Set when the GPU painter was created; the fold then runs in a shader.
    painter: ?*gpu.Painter = null, // kept for the CPU comparison run
    gpu_message: ?[]const u8 = null,
    gpu_frame: GpuFrame = .{},
    /// True while the panel is out of the way; the bind that flips it comes
    /// from the keys file.
    ui_hidden: bool = false,
    binds: keys.Binds = .{},
    /// The panels' rects once drawn, so the fold leaves them flat and they can
    /// be painted back exact: the input pane, the stage pane, the blurb.
    stills: [3]dvui.Rect.Physical = .{ .{}, .{}, .{} },

    error_text: []u8 = &.{},

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
        requested: ?[]const u8,
    ) !App {
        var tap_failure: ?anyerror = null;
        var system_tap = tap.start(io, allocator) catch |err| blk: {
            tap_failure = err;
            break :blk null;
        };
        errdefer if (system_tap) |*running| running.stop(allocator);

        // A missing audio subsystem must not stop the window from opening: the
        // panel can report it, and the user can retry from there.
        var audio_failed = false;
        const devices = audio.list(allocator) catch blk: {
            audio_failed = true;
            break :blk try allocator.alloc(audio.Device, 0);
        };
        errdefer audio.free(allocator, devices);

        // The tap takes the first slot when it exists, so one index space
        // covers "the system output" and the devices SDL lists.
        const tap_slot: usize = if (system_tap != null) 1 else 0;
        const names = try allocator.alloc([]const u8, devices.len + tap_slot);
        errdefer allocator.free(names);
        if (tap_slot == 1) names[0] = "system output";
        for (devices, 0..) |device, index| names[index + tap_slot] = device.name;

        const chosen = if (requested) |needle|
            if (audio.find(devices, needle)) |index| index + tap_slot else 0
        else if (tap_slot == 1)
            0
        else
            audio.preferred(devices);

        var app: App = .{
            .binds = keys.load(environ, io),
            .allocator = allocator,
            .io = io,
            .devices = devices,
            .names = names,
            .selected = chosen,
            .system_tap = system_tap,
            .tap_failure = tap_failure,
        };
        system_tap = null;

        app.select(chosen);
        if (audio_failed) {
            app.setError("audio subsystem unavailable");
        } else if (app.system_tap == null and devices.len == 0) {
            app.setError("no recording devices");
        }
        return app;
    }

    pub fn deinit(self: *App) void {
        // The stream holds the aggregate device open; closing the tap first
        // would leave it walking a destroyed device.
        self.input.close();
        if (self.system_tap) |*running| running.stop(self.allocator);
        self.system_tap = null;
        if (self.ring) |*ring| ring.deinit(self.allocator);
        self.ring = null;
        self.fold_cache.deinit();
        if (self.wave_target) |target| target.destroyLater();
        self.wave_target = null;
        if (self.error_text.len > 0) self.allocator.free(self.error_text);
        self.error_text = &.{};
        self.allocator.free(self.names);
        self.names = &.{};
        audio.free(self.allocator, self.devices);
        self.devices = &.{};
    }

    /// Open a device and start its history from empty.
    pub fn select(self: *App, index: usize) void {
        if (index >= self.names.len) return;
        self.selected = index;
        self.open = false;

        // A failed switch must not leave the previous device's capture on
        // screen under the new device's name.
        if (self.ring) |*ring| ring.deinit(self.allocator);
        self.ring = null;
        self.input.close();

        const rate = if (self.onTap()) tap.sample_rate else blk: {
            self.input.open(self.deviceAt(index).id) catch |err| {
                self.setError(@errorName(err));
                return;
            };
            break :blk self.input.rate;
        };

        self.ring = signal.Ring.init(self.allocator, rate) catch |err| {
            self.input.close();
            self.setError(@errorName(err));
            return;
        };
        self.open = true;
        self.last_sample_ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.setError("");
    }

    /// Whether the selected entry is the system-output tap.
    fn onTap(self: *const App) bool {
        return self.system_tap != null and self.selected == 0;
    }

    /// The SDL device behind an entry in `names`.
    fn deviceAt(self: *const App, index: usize) audio.Device {
        const tap_slot: usize = if (self.system_tap != null) 1 else 0;
        return self.devices[index - tap_slot];
    }

    pub fn frame(self: *App) void {
        self.pump();
        self.readKeys();
        const rect = dvui.currentWindow().rect_pixels;
        const size = dvui.Size.Physical{ .w = rect.w, .h = rect.h };
        const arena = dvui.currentWindow().arena();

        self.drawWaveform(arena, size) catch {
            // Without a drawable target the fold has nothing to sample; the
            // controls still run so the device can be changed.
            self.setError("the backend cannot draw offscreen");
            self.controls();
            return;
        };

        // The shader folds straight onto the swapchain with the panel drawn
        // over it, so only the CPU path needs the panel composited in.
        const fold = self.toggles.fold;
        const gpu_fold = fold and self.painter != null and
            self.gpu_frame.cmd != null and self.gpu_frame.swapchain != null;

        // Only stream mode and the CPU path compose the panel into the
        // picture. Hidden, there is nothing to keep flat.
        var texture: dvui.Texture = undefined;
        var stills: []const dvui.Rect.Physical = &.{};
        if (!gpu_fold and fold and !self.ui_hidden) {
            texture = self.composeFrame(arena, size) catch {
                self.setError("the backend cannot draw offscreen");
                self.controls();
                return;
            };
            stills = &self.stills;
        } else {
            texture = dvui.textureFromTarget(self.wave_target.?) catch {
                self.setError("the waveform texture could not be read");
                if (!self.ui_hidden) self.controls();
                return;
            };
        }

        const levels = self.levels;
        // Everything the beat does to the fold hangs off the kick stage, so
        // switching kick off leaves the picture steady against the music.
        const beat = dmt.beat(levels.low_level, levels.kick, self.kick_pump, self.toggles.kick);
        // The fold is laid out on the window it opened in, scaled by the window
        // slider and breathing with the wander and the kick.
        const swell = @max(0.2, 1 + dmt.wander(self.elapsed, self.window_wander_limit) + beat.pump);
        const canvas = dmt.virtualSize(self.windowBase(size), self.virtual_scale * swell);
        // The fold samples the frame where the screen point lands, so no axis
        // swap.
        const view = dmt.lens(self.clock, .{
            .ring_count = std.math.clamp(self.lane_rings + beat.rings, dmt.rings_track.min, dmt.rings_track.max),
            .heart = self.levels.kick,
            .pump = self.kick_pump,
            .mirrors = self.lane_mirrors,
            .fold = self.fold_kind,
        }, self.toggles);
        if (gpu_fold) {
            const values = gpu.Painter.pack(size, canvas, maybeStills(self.ui_hidden, stills), view);
            self.painter.?.paintOpaque(self.gpu_frame.cmd, self.gpu_frame.swapchain, texture, values) catch |err| {
                self.setError(@errorName(err));
            };
        } else if (fold) {
            dmt.draw(texture, arena, &self.fold_cache, view, size, canvas, stills) catch {
                self.setError("the fold could not be drawn");
            };
        } else {
            const whole = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };
            geom.repaint(arena, &.{whole}, size, texture) catch {
                self.setError("the waveform texture could not be shown");
            };
        }

        if (self.ui_hidden) return;
        if (!gpu_fold and fold) {
            geom.repaint(arena, stills, size, texture) catch {};
        } else {
            self.controls();
        }
    }

    /// The whole window in one texture: the waveform under the controls, so the
    /// fold has a picture to repeat rather than a strip to slide.
    fn composeFrame(self: *App, arena: std.mem.Allocator, size: dvui.Size.Physical) !dvui.Texture {
        const target = try sizedTarget(&self.frame_target, size);
        const previous = dvui.RenderTarget.setAsCurrent(.{ .texture = target, .offset = .{} });
        defer _ = dvui.RenderTarget.setAsCurrent(previous);
        dvui.clipSet(.{ .x = 0, .y = 0, .w = size.w, .h = size.h });
        defer dvui.clipSet(dvui.currentWindow().rect_pixels);

        const wave_texture = try dvui.textureFromTarget(self.wave_target.?);
        const whole = dvui.Rect.Physical{ .x = 0, .y = 0, .w = size.w, .h = size.h };
        const quad = try geom.quadMesh(arena, whole, size);
        try dvui.renderTriangles(.{
            .vertexes = quad.vertexes,
            .indices = quad.indices,
            .bounds = whole,
        }, wave_texture);

        self.controls();
        return try dvui.textureFromTarget(target);
    }

    /// The fold's own window: the size it had the first time a frame drew, so a
    /// later resize reveals more of the tunnel instead of rescaling it.
    fn windowBase(self: *App, size: dvui.Size.Physical) dvui.Size.Physical {
        // A frame can report an empty rect before the first present; latching
        // that would leave the fold on a zero canvas for the process lifetime.
        if (self.virtual_base == null and size.w > 0 and size.h > 0) self.virtual_base = size;
        return self.virtual_base orelse size;
    }

    /// The panels: the input pane on the left, the stage toggles on the right,
    /// and the stage blurb along the bottom.
    fn controls(self: *App) void {
        var root = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .margin = .{ .x = 12, .y = 12, .w = 12, .h = 12 },
        });
        defer root.deinit();

        // Scoped so the row closes before the blurb: an open box takes the
        // next widget into itself, which would lay the blurb out beside the
        // panels instead of under them.
        {
            // Expands over the free space, so the blurb sits at the bottom.
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .both,
                .id_extra = 90,
            });
            defer row.deinit();

            self.inputPane();
            var gap = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .min_size_content = .{ .w = 8 },
                .id_extra = 91,
            });
            gap.deinit();
            self.stagePane();
        }

        self.blurb();
    }

    fn inputPane(self: *App) void {
        var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .border = .{},
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            .color_fill = .{ .color = panel },
        });
        defer pane.deinit();

        dvui.labelNoFmt(@src(), "input", .{}, .{
            .font = .theme(.body),
            .color_text = .{ .color = muted },
            .id_extra = 1,
        });

        var choice = self.selected;
        if (dvui.dropdown(@src(), self.names, .{ .choice = &choice }, .{}, .{
            .min_size_content = .{ .w = 300 },
            .id_extra = 2,
        })) {
            if (choice != self.selected) self.select(choice);
        }

        if (self.tap_failure) |failure| {
            dvui.label(@src(), "system output unavailable ({s})", .{@errorName(failure)}, .{
                .font = .theme(.body),
                .color_text = .{ .color = muted },
                .id_extra = 5,
            });
        }

        if (self.open) {
            const rate = if (self.onTap()) tap.sample_rate else self.input.rate;
            const channels = if (self.onTap()) 1 else self.input.channels;
            dvui.label(@src(), "{d:.1} kHz  ·  {d} ch  ·  level {d:.2}", .{
                rate / 1000,
                channels,
                self.levels.level,
            }, .{
                .font = .theme(.body),
                .color_text = .{ .color = ink },
                .id_extra = 3,
            });
            if (self.stalled()) {
                dvui.labelNoFmt(@src(), "no samples arriving", .{}, .{
                    .font = .theme(.body),
                    .color_text = .{ .color = dvui.Color{ .r = 0xff, .g = 0xc0, .b = 0x40 } },
                    .id_extra = 5,
                });
            }
        } else {
            const message = if (self.error_text.len > 0) self.error_text else "device closed";
            dvui.labelNoFmt(@src(), message, .{}, .{
                .font = .theme(.body),
                .color_text = .{ .color = dvui.Color{ .r = 0xff, .g = 0x55, .b = 0x55 } },
                .id_extra = 4,
            });
        }

        if (self.painter == null) {
            dvui.labelNoFmt(@src(), self.gpu_message orelse "folding on the cpu", .{}, .{
                .font = .theme(.body),
                .color_text = .{ .color = muted },
                .id_extra = 991,
            });
        }
        if (self.sliderRow(.speed, dmt.speed_track.fraction(self.effect_speed), 10)) |fraction| {
            self.effect_speed = dmt.speed_track.value(fraction);
        }
        if (self.sliderRow(.wander, dmt.wander_track.fraction(self.window_wander_limit), 20)) |fraction| {
            self.window_wander_limit = dmt.wander_track.value(fraction);
        }
        if (self.sliderRow(.window, dmt.window_track.fraction(self.virtual_scale), 30)) |fraction| {
            self.virtual_scale = dmt.window_track.value(fraction);
        }
        if (self.sliderRow(.lanes, dmt.rings_track.fraction(self.lane_rings), 40)) |fraction| {
            self.lane_rings = dmt.rings_track.value(fraction);
        }
        if (self.colourBar(self.lane_colour, 50)) |fraction| {
            self.lane_colour = fraction;
        }
        if (self.sliderRow(.blur, self.blur, 60)) |fraction| {
            self.blur = fraction;
        }
        if (self.sliderRow(.mirror, dmt.mirrors_track.fraction(self.lane_mirrors), 70)) |fraction| {
            self.lane_mirrors = dmt.mirrors_track.value(fraction);
        }
        if (self.sliderRow(.gate, dmt.gate_track.fraction(self.gate), 80)) |fraction| {
            self.gate = dmt.gate_track.value(fraction);
        }
        if (self.sliderRow(.kick, dmt.kick_track.fraction(self.kick_pump), 90)) |fraction| {
            self.kick_pump = dmt.kick_track.value(fraction);
        }

        self.keepFlat(0, pane.data().rectScaleFromParent().r);
    }

    /// One toggle per pipeline stage. Hovering a row puts that stage in the
    /// blurb under the window.
    fn stagePane(self: *App) void {
        var pane = dvui.box(@src(), .{ .dir = .vertical }, .{
            .background = true,
            .border = .{},
            .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
            .color_fill = .{ .color = panel },
            .id_extra = 100,
        });
        defer pane.deinit();

        dvui.labelNoFmt(@src(), "stages", .{}, .{
            .font = .theme(.body),
            .color_text = .{ .color = muted },
            .id_extra = 101,
        });

        for (stages.all, 0..) |stage, index| {
            const extra: u32 = 110 + @as(u32, @intCast(index)) * 2;
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .id_extra = extra,
                .min_size_content = .{ .w = 150, .h = 20 },
            });
            defer row.deinit();

            var on = self.toggles.enabled(stage);
            if (dvui.checkbox(@src(), &on, stage.label(), .{
                .font = .theme(.body),
                .color_text = .{ .color = ink },
                .id_extra = extra + 1,
            })) {
                self.toggles.set(stage, !self.toggles.enabled(stage));
            }

            if (stage == .fold) self.lawPicker(extra + 900);

            if (inside(row.data().rectScaleFromParent().r, dvui.currentWindow().mouse_pt)) {
                self.blurb_focus = .{ .stage = stage };
            }
        }

        self.keepFlat(1, pane.data().rectScaleFromParent().r);
    }

    /// The fold's radial law, one entry per law, each with its own blurb while
    /// the menu is open.
    fn lawPicker(self: *App, id: u32) void {
        var picker: dvui.DropdownWidget = undefined;
        picker.init(@src(), .{
            .label = blurbs.lawLabel(self.fold_kind),
            .selected_index = @intFromEnum(self.fold_kind),
        }, .{
            .font = .theme(.body),
            .color_text = .{ .color = ink },
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 84, .h = 18 },
            .id_extra = id,
        });
        defer picker.deinit();

        if (!picker.dropped()) return;
        inline for (@typeInfo(dmt.Fold).@"enum".field_values) |value| {
            const law: dmt.Fold = @enumFromInt(value);
            var item = picker.addChoice();
            defer item.deinit();
            dvui.labelNoFmt(@src(), blurbs.lawLabel(law), .{}, item.data().options.strip().override(item.style()));

            if (item.mouse_over) self.blurb_focus = .{ .law = law };
            if (item.activeRect() != null) {
                // Branches is the fold without a mirror, so picking it drops
                // the facets rather than leaving a tick that cannot show.
                    self.fold_kind = law;
                picker.close();
            }
        }
    }

    /// What the thing under the mouse does, under the panels.
    fn blurb(self: *App) void {
        var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .background = true,
            .border = .{},
            .padding = .{ .x = 10, .y = 6, .w = 10, .h = 6 },
            .color_fill = .{ .color = panel },
            .expand = .horizontal,
            .min_size_content = .{ .h = 58 },
            .id_extra = 200,
        });
        defer strip.deinit();

        var text = dvui.textLayout(@src(), .{ .break_lines = true }, .{
            .font = .theme(.body),
            .color_text = .{ .color = ink },
            .expand = .horizontal,
            .id_extra = 201,
        });
        defer text.deinit();
        text.addText(self.blurb_focus.title(), .{});
        text.addText(": ", .{});
        text.addText(self.blurb_focus.description(), .{});

        self.keepFlat(2, strip.data().rectScaleFromParent().r);
    }

    /// Remember a panel's rect so the fold leaves it flat and it is painted
    /// back exact. A rect is only known once the box has laid its children out.
    fn keepFlat(self: *App, slot: usize, rect: dvui.Rect.Physical) void {
        if (rect.w <= 0 or rect.h <= 0) return;
        self.stills[slot] = .{
            .x = rect.x - 1,
            .y = rect.y - 1,
            .w = rect.w + 2,
            .h = rect.h + 2,
        };
    }

    /// The colour control: a bar painted with the whole hue wheel, so the row
    /// reads as colour before it is touched, and the handle sits at the hue in
    /// use. Same row as `sliderRow`, but dvui's slider paints its own track and
    /// cannot show a gradient.
    fn colourBar(self: *App, start: f32, id: u32) ?f32 {
        const width = 160;
        const height = 14;
        const cells = 32;
        const handle_width = 3;

        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id,
            .min_size_content = .{ .h = 22 },
        });
        defer row.deinit();

        if (inside(row.data().rectScaleFromParent().r, dvui.currentWindow().mouse_pt)) {
            self.blurb_focus = .{ .knob = .colour };
        }

        dvui.labelNoFmt(@src(), blurbs.Knob.colour.label(), .{}, .{
            .font = .theme(.body),
            .color_text = .{ .color = ink },
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 64 },
            .id_extra = id + 1,
        });

        var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id + 2,
            .gravity_y = 0.5,
            .min_size_content = .{ .w = width, .h = height },
            .max_size_content = .{ .w = width, .h = height },
            .padding = .{},
            .margin = .{},
        });
        defer bar.deinit();

        // A widget's `rect` is natural pixels and the box's own rect is still
        // the parent's spare width while it is built, so the bar is painted from
        // the size it was declared with.
        const span: f32 = @floatFromInt(width);
        const tall: f32 = @floatFromInt(height);
        const cell_width = span / @as(f32, @floatFromInt(cells));
        for (0..cells) |cell| {
            const turns = (@as(f32, @floatFromInt(cell)) + 0.5) / @as(f32, @floatFromInt(cells));
            paintCell(id, 3 + @as(u32, @intCast(cell)), .{
                .x = cell_width * @as(f32, @floatFromInt(cell)),
                .w = cell_width,
                .h = tall,
            }, wave.spectrum(turns));
        }
        const grip: f32 = @floatFromInt(handle_width);
        paintCell(id, 3 + @as(u32, @intCast(cells)), .{
            .x = std.math.clamp(start, 0, 1) * (span - grip),
            .w = grip,
            .h = tall,
        }, .{ .r = 0xff, .g = 0xff, .b = 0xff, .a = 0xff });

        return colourDrag(bar, span * bar.data().rectScale().s);
    }

    /// Press-and-drag over the bar, the way dvui's own slider reads it.
    fn colourDrag(bar: *dvui.BoxWidget, width: f32) ?f32 {
        const rs = bar.data().rectScale();
        var moved: ?f32 = null;
        for (dvui.events()) |*e| {
            if (!dvui.eventMatch(e, .{ .id = bar.data().id, .r = rs.r })) continue;
            switch (e.evt) {
                .mouse => |me| {
                    if (me.action == .press and me.button.pointer()) {
                        dvui.captureMouse(bar.data(), e.num);
                        e.handle(@src(), bar.data());
                        moved = me.p.x;
                    } else if (me.action == .motion and dvui.captured(bar.data().id)) {
                        e.handle(@src(), bar.data());
                        moved = me.p.x;
                    } else if (me.action == .release and me.button.pointer() and dvui.captured(bar.data().id)) {
                        dvui.captureMouse(null, e.num);
                        e.handle(@src(), bar.data());
                    }
                },
                else => {},
            }
        }
        const x = moved orelse return null;
        return std.math.clamp((x - rs.r.x) / width, 0, 1);
    }

    /// A label with a slider beside it. Returns the new position only when the
    /// slider moved.
    fn sliderRow(self: *App, knob: blurbs.Knob, start: f32, id: u32) ?f32 {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = id,
            .min_size_content = .{ .h = 22 },
        });
        defer row.deinit();

        if (inside(row.data().rectScaleFromParent().r, dvui.currentWindow().mouse_pt)) {
            self.blurb_focus = .{ .knob = knob };
        }

        dvui.labelNoFmt(@src(), knob.label(), .{}, .{
            .font = .theme(.body),
            .color_text = .{ .color = ink },
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 64 },
            .id_extra = id + 1,
        });

        var fraction = start;
        const moved = dvui.slider(@src(), .{ .fraction = &fraction }, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 160, .h = 14 },
            .max_size_content = .{ .w = 160, .h = 14 },
            .id_extra = id + 2,
        });
        return if (moved) fraction else null;
    }

    /// Move the clock with the capture and follow its loudness.
    fn pump(self: *App) void {
        const now = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.now_ns = now;
        const seconds = if (now > self.last_ns)
            @as(f64, @floatFromInt(now - self.last_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s))
        else
            0;
        self.last_ns = now;
        const step = @min(seconds, 0.1);
        self.elapsed += step;
        // The tunnel keeps moving through silence; only its speed follows the
        // capture.
        const beat = dmt.beat(self.levels.low_level, self.levels.kick, self.kick_pump, self.toggles.kick);
        self.clock.advance(step * self.effect_speed * beat.pace, dmt.mood(self.elapsed));

        const ring = if (self.ring) |*value| value else return;
        const before = ring.pushes;
        if (self.system_tap) |*system| {
            if (self.onTap()) system.pull(ring) else self.input.pull(ring);
        } else {
            self.input.pull(ring);
        }
        if (ring.pushes != before) self.last_sample_ns = now;

        const samples = ring.newest();
        if (samples.len == 0) {
            self.levels.silence(@floatCast(step));
            return;
        }

        const count: usize = @intFromFloat(@max(64, ring.rate / 60));
        const tail = @min(samples.len, count);
        const newest = signal.column(ring, samples.len - tail, samples.len, 0);

        self.levels.update(newest, @floatCast(step));
    }

    /// A loopback driver that stops feeding looks exactly like silence: the
    /// window goes dark. Say so when nothing has arrived for a while.
    fn stalled(self: *const App) bool {
        return captureStalled(self.open, self.last_sample_ns, self.now_ns);
    }

    /// Draw the waveform into its own texture, so the fold samples the
    /// waveform alone and the controls stay crisp above it.
    fn drawWaveform(self: *App, arena: std.mem.Allocator, size: dvui.Size.Physical) !void {
        if (size.w <= 0 or size.h <= 0) return error.EmptyWindow;
        const target = try sizedTarget(&self.wave_target, size);

        const previous = dvui.RenderTarget.setAsCurrent(.{ .texture = target, .offset = .{} });
        defer _ = dvui.RenderTarget.setAsCurrent(previous);
        dvui.clipSet(.{ .x = 0, .y = 0, .w = size.w, .h = size.h });
        defer dvui.clipSet(dvui.currentWindow().rect_pixels);

        const ring = if (self.ring) |*value| value else return;
        try wave.drawSource(arena, size, ring, self.lane_colour, self.blur, .{
            .gate = self.gate,
            .phase = @floatCast(self.clock.turn),
        });
    }

    /// Binds act on key-down only, and only when no modifier is held, so a
    /// typed letter in a widget cannot hide the panel.
    fn readKeys(self: *App) void {
        for (dvui.events()) |*event| {
            if (event.handled) continue;
            switch (event.evt) {
                .key => |key| {
                    if (!self.hidesPanel(key)) continue;
                    self.ui_hidden = !self.ui_hidden;
                    event.handled = true;
                },
                else => {},
            }
        }
    }

    /// Key-down with no modifier held. Typing the bound letter into a widget
    /// has a modifier or is not a key-down, so it cannot hide the panel.
    fn hidesPanel(self: *const App, key: dvui.Event.Key) bool {
        return key.action == .down and key.mod == .none and key.code == self.binds.toggle_ui;
    }

    fn setError(self: *App, message: []const u8) void {
        if (std.mem.eql(u8, self.error_text, message)) return;
        if (self.error_text.len > 0) self.allocator.free(self.error_text);
        self.error_text = self.allocator.dupe(u8, message) catch &.{};
    }
};

/// Whether an open capture has stopped delivering samples.
pub fn captureStalled(open: bool, last_sample_ns: i96, now_ns: i96) bool {
    if (!open or last_sample_ns == 0) return false;
    return now_ns - last_sample_ns > 2 * std.time.ns_per_s;
}

/// A window-sized texture, reused until the window resizes.
fn sizedTarget(slot: *?dvui.Texture.Target, size: dvui.Size.Physical) !dvui.Texture.Target {
    const width: u32 = @intFromFloat(@max(1, @floor(size.w)));
    const height: u32 = @intFromFloat(@max(1, @floor(size.h)));
    if (slot.*) |target| {
        if (target.width == width and target.height == height) return target;
        target.destroyLater();
        slot.* = null;
    }
    const target = try dvui.Texture.Target.create(.{ .width = width, .height = height });
    slot.* = target;
    return target;
}

test "a stalled capture is reported only while the stream is open" {
    const second: i96 = std.time.ns_per_s;
    try std.testing.expect(!captureStalled(false, 5 * second, 9 * second));
    try std.testing.expect(!captureStalled(true, 5 * second, 6 * second));
    try std.testing.expect(captureStalled(true, 5 * second, 8 * second));
}
