//! The fold's stages, in the order a screen point goes through them. Every
//! stage can be switched off on its own, so the picture shows what the rest of
//! the fold does without it.

const std = @import("std");

pub const Stage = enum {
    fold,
    spin,
    mirrors,
    stagger,
    kick,

    pub fn label(self: Stage) []const u8 {
        return @tagName(self);
    }

    /// What the stage does and what its absence leaves, shown under the panels
    /// while the mouse is on its toggle.
    pub fn description(self: Stage) []const u8 {
        return switch (self) {
            .fold =>
            "Maps every screen point back into the frame. The radius picks a ring, alternate " ++
                "rings are reflected so the picture mirrors outwards, and the sampled point is " ++
                "wrapped at the frame's border instead of smearing. The dropdown beside the tick " ++
                "picks the radial law: tunnel takes the log radius, so rings keep their thickness " ++
                "and the picture recedes; rings takes the radius straight, so each copy is wider " ++
                "than the one inside it and the frame expands outward; branches is rings with " ++
                "every other ring no longer reflected and the facets switched off, so the lanes " ++
                "run straight out from the middle. The window slider sets how " ++
                "many rings fit and wander breathes that window. Off, the capture is drawn flat " ++
                "at full size with the panels over it.",
            .mirrors =>
            "Folds the spun angle into facets around the middle, so one frame is sampled once per " ++
                "facet and the picture becomes a kaleidoscope. The mirror slider sets the count " ++
                "from two to sixteen. Off leaves a single facet: the frame is sampled unfolded, " ++
                "the sweep around the middle no longer repeats, and the facet edges are gone.",
            .spin =>
            "Turns the whole sampling frame with the effect clock at three times the clock's own " ++
                "rate, so the seams and every facet edge sweep around the middle together. The " ++
                "speed slider scales the clock and so scales the spin. Off holds the frame's " ++
                "angle still: the lanes still expand outward, but nothing rotates.",
            .stagger =>
            "Starts each lane at its own point of the frame's sweep, so neighbouring lanes show " ++
                "different parts of the capture instead of the same one. The offset is half of a " ++
                "sweep per lane and wraps, so lanes three apart come back into line. Off makes " ++
                "every lane sample the same band, which collapses the tunnel into one repeating " ++
                "picture.",
            .kick =>
            "Pushes the rings outward on each beat, scaled by the loudness the capture reports, " ++
                "so a hit moves the whole tunnel a ring forward. Off keeps the expansion even " ++
                "with no punch on the beat.",
        };
    }
};

/// The fold's pipeline in rendering order, taken from the declaration order so
/// the panel can never list the stages in a different order than the mapping
/// applies them.
pub const all = std.enums.values(Stage);

pub const Toggles = struct {
    fold: bool = true,
    spin: bool = true,
    mirrors: bool = true,
    stagger: bool = true,
    kick: bool = true,

    pub fn enabled(self: Toggles, stage: Stage) bool {
        return switch (stage) {
            .fold => self.fold,
            .spin => self.spin,
            .mirrors => self.mirrors,
            .stagger => self.stagger,
            .kick => self.kick,
        };
    }

    pub fn set(self: *Toggles, stage: Stage, on: bool) void {
        switch (stage) {
            .fold => self.fold = on,
            .spin => self.spin = on,
            .mirrors => self.mirrors = on,
            .stagger => self.stagger = on,
            .kick => self.kick = on,
        }
    }
};

test "every stage starts on, and switching one off leaves the rest alone" {
    for (all) |stage| {
        var toggles = Toggles{};
        try std.testing.expect(toggles.enabled(stage));

        toggles.set(stage, false);
        try std.testing.expect(!toggles.enabled(stage));
        for (all) |other| {
            if (other == stage) continue;
            try std.testing.expect(toggles.enabled(other));
        }
    }
}

test "every stage has a label and a description" {
    for (all) |stage| {
        try std.testing.expect(std.mem.eql(u8, stage.label(), @tagName(stage)));
        try std.testing.expect(stage.description().len > 120);
    }
}
