//! The words under the panels: what the thing under the mouse does, what
//! changes when it is off or at either end, and which control drives it.

const std = @import("std");
const dmt = @import("dmt.zig");
const stages = @import("stages.zig");

/// One slider's row in the left pane.
pub const Knob = enum {
    speed,
    wander,
    window,
    lanes,
    colour,
    blur,
    mirror,
    gate,
    kick,

    pub fn label(self: Knob) []const u8 {
        return @tagName(self);
    }

    pub fn description(self: Knob) []const u8 {
        return switch (self) {
            .speed =>
            "How fast the effect clock steps. It scales the spin, the outward rush of the rings and " ++
                "the rate lanes start at, so it sets the whole motion's tempo rather than one part " ++
                "of it. Captured loudness nudges it too, but only while the kick stage is on.",
            .wander =>
            "How far the virtual window breathes over time. The window the fold is laid out on " ++
                "swells and shrinks by this much, so more or fewer lanes fit on screen without a " ++
                "slider moving. At the left the window is still; at the right it opens and closes " ++
                "by nearly half, which reads as the tunnel pulsing.",
            .window =>
            "The virtual window's scale, and so how many lanes fit on screen. Left is the real " ++
                "window, where one lane spans the frame and the tunnel is at its widest; right is " ++
                "six times it, the same picture cut into six times as many rings. The track is " ++
                "geometric, so each step right multiplies the density by about the same amount.",
            .lanes =>
            "Lanes per e-fold of radius: how tightly the rings are packed between the middle and " ++
                "the rim. Few lanes give fat rings, many give a fine tunnel. With the tunnel fold " ++
                "the bands stay the same width as they get denser; with rings and branches each " ++
                "ring widens outward, so this slider sets how many copies the frame is cut into.",
            .colour =>
            "How far the frame's colours open out from grey. Left keeps the heat ramp's own muted " ++
                "hues; right pushes every column to full chroma. It multiplies after the ramp, so it " ++
                "never changes which hue a column gets, only how far that hue sits from grey.",
            .blur =>
            "The soften pass over the 240 columns, run before the fold samples them. It smears each " ++
                "column into its neighbours, so hard column edges become gradients. The fold " ++
                "magnifies the middle, so a little here goes a long way there.",
            .mirror =>
            "The kaleidoscope's facet count, in whole numbers from two to sixteen. It only shows " ++
                "while the mirrors stage is on. The count divides the full turn, so every facet " ++
                "shows the same slice of the frame reflected at its edges.",
            .gate =>
            "Where quiet columns start being pulled down. It is a gentle downward expander, not a " ++
                "switch: a column at the threshold keeps half its level, one at twice the threshold " ++
                "keeps all of it, silence keeps none, and the ramp between is smooth, so passages " ++
                "fade into the tunnel instead of blinking out. The track runs to 1.0, so at the " ++
                "right end the whole frame is attenuated, the loudest columns included. Left is off.",
            .kick =>
            "How much of a captured hit reaches the fold, as a multiplier from 0 to 10. The " ++
                "capture fires a kick when the low band spikes above the smoothed level; this " ++
                "scales that firing before the beat sees it, so the low end needs a hard hit to " ++
                "move anything and the high end throws the rings on the smallest one. It only acts " ++
                "while the kick stage is on.",
        };
    }
};

/// The radial law the fold dropdown offers.
pub fn lawLabel(law: dmt.Fold) []const u8 {
    return @tagName(law);
}

pub fn lawDescription(law: dmt.Fold) []const u8 {
    return switch (law) {
        .tunnel =>
        "Log radius. Each ring covers the same fraction of an e-fold, so rings keep their " ++
            "thickness on screen and the picture reads as a tunnel receding: the middle is far " ++
            "away and the rim is close. Alternate rings are reflected across their seams, so the " ++
            "picture mirrors from the middle outwards.",
        .rings =>
        "Radius taken straight. Each ring is wider than the one inside it, so the frame repeats " ++
            "as copies that grow outward from the middle instead of receding into it. Alternate " ++
            "rings are still reflected, which is what makes neighbouring copies mirror each other.",
        .branches =>
        "Radius taken straight with the reflection removed: every ring points the same way, so " ++
            "the frame's own bands run out from the middle and the lanes read as branching rather " ++
            "than copying. Picking this law also switches the facets off.",
    };
}

/// Anything the mouse can rest on that has something to say.
pub const Subject = union(enum) {
    stage: stages.Stage,
    knob: Knob,
    law: dmt.Fold,

    pub fn title(self: Subject) []const u8 {
        return switch (self) {
            .stage => |stage| stage.label(),
            .knob => |knob| knob.label(),
            .law => |law| lawLabel(law),
        };
    }

    pub fn description(self: Subject) []const u8 {
        return switch (self) {
            .stage => |stage| stage.description(),
            .knob => |knob| knob.description(),
            .law => |law| lawDescription(law),
        };
    }
};

test "every knob and law carries a blurb" {
    inline for (@typeInfo(Knob).@"enum".field_values) |value| {
        const knob: Knob = @enumFromInt(value);
        try std.testing.expect(knob.description().len > 120);
    }
    inline for (@typeInfo(dmt.Fold).@"enum".field_values) |value| {
        const law: dmt.Fold = @enumFromInt(value);
        try std.testing.expect(lawDescription(law).len > 120);
    }
}
