//! Sampling controls and the effect stages exposed by the right panel.

const std = @import("std");

pub const Stage = enum {
    fold,
    continuous,
    spin,
    mirrors,
    kick,

    pub fn label(self: Stage) []const u8 {
        return @tagName(self);
    }

    /// What the stage does and what its absence leaves, shown under the panels
    /// while the mouse is on its toggle.
    pub fn description(self: Stage) []const u8 {
        return switch (self) {
            .fold => "Maps screen points back into the audio image. The dropdown selects tunnel, rings " ++
                "or mandelbrot. Tunnel uses log radius; rings uses linear radius; mandelbrot uses " ++
                "escape time and orbit angle. The window slider sets the view scale, and its wander " ++
                "tick varies that scale. Off draws the capture flat behind the panels.",
            .continuous => "Disables separate lane rotation. Tunnel and rings also keep the outer " ++
                "edge connected instead of wrapping it to the centre. Mandelbrot lane boundaries " ++
                "stay connected with either setting.",
            .mirrors => "Folds the angle after clock spin and radial shear into kaleidoscope facets. The " ++
                "mirror slider sets a whole count from one to thirty-two. One bypasses the " ++
                "kaleidoscope, as does switching this stage off. The radial fold still reflects " ++
                "alternate rings.",
            .spin => "Turns the whole sampling frame with the effect clock at three times the clock's own " ++
                "rate, so the seams and every facet edge sweep around the middle together. The " ++
                "speed slider scales the clock and so scales the spin. Off holds the frame's " ++
                "angle still: the lanes still expand outward, but nothing rotates.",
            .kick => "Applies bass-driven motion. Tunnel and rings change lane count, window scale " ++
                "and clock pace, with an extra push on each hit. Mandelbrot uses a small, smoothed " ++
                "texture pulse without changing camera scale, lane count or pace. Off removes " ++
                "audio modulation from the fold.",
        };
    }
};

pub const all = std.enums.values(Stage);

pub const Toggles = struct {
    fold: bool = true,
    continuous: bool = false,
    spin: bool = true,
    mirrors: bool = true,
    kick: bool = true,

    pub fn enabled(self: Toggles, stage: Stage) bool {
        return switch (stage) {
            .fold => self.fold,
            .continuous => self.continuous,
            .spin => self.spin,
            .mirrors => self.mirrors,
            .kick => self.kick,
        };
    }

    pub fn set(self: *Toggles, stage: Stage, on: bool) void {
        switch (stage) {
            .fold => self.fold = on,
            .continuous => self.continuous = on,
            .spin => self.spin = on,
            .mirrors => self.mirrors = on,
            .kick => self.kick = on,
        }
    }

    pub fn available(self: Toggles, stage: Stage) bool {
        return switch (stage) {
            .fold, .kick => true,
            else => self.fold,
        };
    }
};

test "fold controls stage availability" {
    var toggles = Toggles{};
    toggles.set(.fold, false);
    for (all) |stage| {
        try std.testing.expectEqual(stage == .fold or stage == .kick, toggles.available(stage));
    }
}
