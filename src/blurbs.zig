//! The words under the panels: what the thing under the mouse does, what
//! changes when it is off or at either end, and which control drives it.

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

    pub fn available(self: Knob, toggles: stages.Toggles) bool {
        return switch (self) {
            .window, .lanes => toggles.fold,
            .mirror => toggles.fold and toggles.mirrors,
            .kick => toggles.fold and toggles.kick,
            else => true,
        };
    }

    pub fn description(self: Knob) []const u8 {
        return switch (self) {
            .speed => "How fast the effect clock steps. It scales the spin, the outward rush of the rings and " ++
                "the rate lanes start at, so it sets the whole motion's tempo rather than one part " ++
                "of it. Captured loudness nudges it too, but only while the kick stage is on.",
            .wander => "How far enabled sliders drift around their base positions. The wander tick to the " ++
                "right of each other slider selects it independently, including colour. Left is off; " ++
                "right gives the widest movement. Values stay inside their tracks, and mirror counts " ++
                "stay whole. Turning a tick off restores that slider's base value.",
            .window => "The virtual window's scale, and so how many lanes fit on screen. Left is the real " ++
                "window, where one lane spans the frame and the tunnel is at its widest; right is " ++
                "six times it, the same picture cut into six times as many rings. The track is " ++
                "geometric, so each step right multiplies the density by about the same amount.",
            .lanes => "Lanes per e-fold of radius: how tightly the rings are packed between the middle and " ++
                "the rim. Few lanes give fat rings, many give a fine tunnel. With the tunnel fold " ++
                "the bands stay the same width as they get denser; with rings each ring widens " ++
                "outward, so this slider sets how many copies the frame is cut into.",
            .colour => "Slides the whole heat ramp around the colour wheel, keeping every column's place in " ++
                "it. Left leaves the ramp as it is; right takes it once round and back, so the cold " ++
                "end, the hot end and every band between them change hue together.",
            .blur => "The soften pass over the 240 columns, run before the fold samples them. It smears each " ++
                "column into its neighbours, so hard column edges become gradients. The fold " ++
                "magnifies the middle, so a little here goes a long way there.",
            .mirror => "The kaleidoscope's facet count, in whole numbers from one to thirty-two. At the " ++
                "minimum it bypasses kaleidoscope mirroring, like switching the mirrors stage off. " ++
                "Higher counts fold the spun and sheared angle into repeated reflected facets.",
            .gate => "Where quiet columns start being pulled down. It is a gentle downward expander, not a " ++
                "switch: a column at the threshold keeps half its level, one at twice the threshold " ++
                "keeps all of it, silence keeps none, and the ramp between is smooth, so passages " ++
                "fade into the tunnel instead of blinking out. Applied after blur and level " ++
                "normalisation, so the output stays thin. The track runs to 8.0; at maximum even " ++
                "the tallest columns keep only about 1.1% of their ungated height. Left is off.",
            .kick => "How much of the music reaches the fold, from none at the left to the whole " ++
                "punch at the right. The capture fires a kick when the low band spikes above " ++
                "the smoothed level. This scales the hit's throw, the window swell, the extra " ++
                "lanes and the clock's hurry together, so the left end holds the fold still " ++
                "while the source keeps drawing.",
        };
    }
};

/// The radial law the fold dropdown offers.
pub fn lawLabel(law: dmt.Fold) []const u8 {
    return @tagName(law);
}

pub fn lawDescription(law: dmt.Fold) []const u8 {
    return switch (law) {
        .tunnel => "Log radius. Each ring covers the same fraction of an e-fold, so rings keep their " ++
            "thickness on screen and the picture reads as a tunnel receding: the middle is far " ++
            "away and the rim is close. Alternate rings are reflected across their seams, so the " ++
            "picture mirrors from the middle outwards.",
        .rings => "Radius taken straight. Each ring is wider than the one inside it, so the frame repeats " ++
            "as copies that grow outward from the middle instead of receding into it. Alternate " ++
            "rings are still reflected, which is what makes neighbouring copies mirror each other.",
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
