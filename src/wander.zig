const std = @import("std");
const dmt = @import("dmt.zig");

const phase_spacing: f64 = 71.3;
const maximum_excursion: f32 = 0.5;

pub const Parameter = enum {
    speed,
    window,
    lanes,
    colour,
    blur,
    mirror,
    gate,
    kick,

    pub fn track(self: Parameter) dmt.Track {
        return switch (self) {
            .speed => dmt.speed_track,
            .window => dmt.window_track,
            .lanes => dmt.rings_track,
            .mirror => dmt.mirrors_track,
            .gate => dmt.gate_track,
            .kick => dmt.kick_track,
            .colour, .blur => .{ .min = 0, .max = 1 },
        };
    }
};

pub const Values = struct {
    speed: f32 = 1,
    window: f32 = 1,
    lanes: f32 = dmt.rings_default,
    colour: f32 = 0,
    blur: f32 = 0,
    mirror: f32 = 4,
    gate: f32 = 0,
    kick: f32 = 1,
};

pub const State = struct {
    intensity: f32 = 0.45,
    enabled: std.EnumSet(Parameter) = std.EnumSet(Parameter).initOne(.window),

    pub fn apply(self: State, base: Values, time: f64) Values {
        var animated = base;
        if (self.intensity == 0) return animated;
        inline for (std.enums.values(Parameter)) |parameter| {
            if (self.enabled.contains(parameter)) {
                const track = parameter.track();
                const phase = @as(f64, @floatFromInt(@backingInt(parameter))) * phase_spacing;
                const offset = dmt.wander(time + phase, self.intensity * maximum_excursion);
                const position = @abs(track.fraction(@field(base, @tagName(parameter))) + offset);
                const reflected = if (position > 1) 2 - position else position;
                @field(animated, @tagName(parameter)) = track.value(reflected);
            }
        }
        return animated;
    }
};

test "zero intensity and disabled parameters preserve base values" {
    const base = Values{ .speed = 0.7, .window = 2, .colour = 0.4, .blur = 0.3, .gate = 2 };
    const stopped = State{ .intensity = 0, .enabled = .full };
    const disabled = State{ .intensity = 1, .enabled = .empty };
    try std.testing.expectEqualDeep(base, stopped.apply(base, 17));
    try std.testing.expectEqualDeep(base, disabled.apply(base, 17));
}

test "every enabled parameter moves independently within its track" {
    const state = State{ .intensity = 1, .enabled = .full };
    var base = Values{};
    inline for (std.enums.values(Parameter)) |parameter| {
        @field(base, @tagName(parameter)) = parameter.track().value(0.5);
    }
    var moved: std.EnumSet(Parameter) = .empty;
    var time: f64 = 0;
    while (time < 120) : (time += 0.25) {
        const actual = state.apply(base, time);
        inline for (std.enums.values(Parameter)) |parameter| {
            const track = parameter.track();
            const value = @field(actual, @tagName(parameter));
            try std.testing.expect(value >= track.min and value <= track.max);
            if (track.whole) try std.testing.expectEqual(@round(value), value);
            if (value != @field(base, @tagName(parameter))) moved.insert(parameter);
        }
    }
    try std.testing.expect(moved.eql(.full));
    const actual = state.apply(base, 17);
    try std.testing.expect(@abs(Parameter.speed.track().fraction(actual.speed) - actual.blur) > 0.01);
}

test "intensity scales continuous motion and toggles restore the base" {
    const base = Values{ .blur = 0.5 };
    var state = State{ .intensity = 0.2, .enabled = std.EnumSet(Parameter).initOne(.blur) };
    const gentle = state.apply(base, 17);
    state.intensity = 0.4;
    const stronger = state.apply(base, 17);
    try std.testing.expect(@abs(gentle.blur - base.blur) > 0.001);
    try std.testing.expectApproxEqAbs((gentle.blur - base.blur) * 2, stronger.blur - base.blur, 0.0001);
    state.enabled.remove(.blur);
    try std.testing.expectEqualDeep(base, state.apply(base, 17));
}

test "changing a selected base preserves other parameters and disabling restores it" {
    var base = Values{};
    var state = State{ .intensity = 0.7, .enabled = .initOne(.window) };
    const before = state.apply(base, 12);
    base.window = 3;
    const after = state.apply(base, 12);
    try std.testing.expect(before.window != after.window);
    try std.testing.expectEqual(base.speed, after.speed);
    try std.testing.expectEqual(base.colour, after.colour);
    state.enabled.remove(.window);
    try std.testing.expectEqualDeep(base, state.apply(base, 12));
}

test "wander reflects inward at both track ends" {
    const state = State{ .intensity = 1, .enabled = .initOne(.blur) };
    const low = state.apply(.{ .blur = 0 }, 17);
    const high = state.apply(.{ .blur = 1 }, 17);
    try std.testing.expect(low.blur > 0 and low.blur < maximum_excursion);
    try std.testing.expect(high.blur > 1 - maximum_excursion and high.blur < 1);
    try std.testing.expectApproxEqAbs(low.blur, 1 - high.blur, 0.0001);
}
