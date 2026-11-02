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
            .fold => "Maps every screen point back into the frame. The radius picks a ring, alternate " ++
                "rings are reflected so the picture mirrors outwards, and the sampled point is " ++
                "wrapped at the frame's border instead of smearing. The dropdown beside the tick " ++
                "picks the radial law: tunnel takes the log radius, so rings keep their thickness " ++
                "and the picture recedes; rings takes the radius straight, so each copy is wider " ++
                "than the one inside it and the frame expands outward. The window slider sets how " ++
                "many rings fit; its wander tick lets the master intensity vary that scale. Off, the capture is drawn flat " ++
                "at full size with the panels over it.",
            .continuous => "Samples connected bands without wrapping the outer edge back to the centre or " ++
                "turning each lane separately. Off wraps the full-reach endpoint to the centre and " ++
                "turns each lane separately.",
            .mirrors => "Folds the angle after clock spin and radial shear into kaleidoscope facets. The " ++
                "mirror slider sets a whole count from one to thirty-two. One bypasses the " ++
                "kaleidoscope, as does switching this stage off. The radial fold still reflects " ++
                "alternate rings.",
            .spin => "Turns the whole sampling frame with the effect clock at three times the clock's own " ++
                "rate, so the seams and every facet edge sweep around the middle together. The " ++
                "speed slider scales the clock and so scales the spin. Off holds the frame's " ++
                "angle still: the lanes still expand outward, but nothing rotates.",
            .kick => "Moves the tunnel with the bass. The rings breathe and the clock hurries on the low " ++
                "band, and each captured hit pushes the rings outward on top of that, so mids and " ++
                "highs leave the fold alone. Off keeps the expansion even, with no punch and no " ++
                "haste on the beat.",
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
