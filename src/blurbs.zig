//! The words under the panels: what the thing under the mouse does, what
//! changes when it is off or at either end, and which control drives it.

const folding = @import("fold.zig");
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
            .window => "The virtual window's scale, from one to six times the real window on a geometric " ++
                "track. Tunnel and rings use it to size their lanes. Mandelbrot uses it to adjust " ++
                "the framing of its zoom route through different boundary regions.",
            .lanes => "Texture repetition along the fold's depth. Tunnel uses log radius; " ++
                "rings uses linear radius; mandelbrot uses normalized escape time. Mandelbrot " ++
                "lane changes are gradual and keep the boundary geometry unchanged.",
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
            .kick => "Amount of bass-driven motion. Tunnel and rings combine a hit's throw, " ++
                "window swell, extra lanes and clock pace. Mandelbrot uses a small, smoothed " ++
                "texture pulse without changing the camera, lane count or clock pace. " ++
                "The left end removes audio modulation from the fold.",
        };
    }
};

/// The mapping offered by the fold dropdown.
pub fn lawLabel(law: folding.Fold) []const u8 {
    return @tagName(law);
}

pub fn lawDescription(law: folding.Fold) []const u8 {
    return switch (law) {
        .tunnel => "Log radius. Each ring covers the same fraction of an e-fold, so rings keep their " ++
            "thickness on screen and the picture reads as a tunnel receding: the middle is far " ++
            "away and the rim is close. Alternate rings are reflected across their seams, so the " ++
            "picture mirrors from the middle outwards.",
        .rings => "Radius taken straight. Each ring is wider than the one inside it, so the frame repeats " ++
            "as copies that grow outward from the middle instead of receding into it. Alternate " ++
            "rings are still reflected, which is what makes neighbouring copies mirror each other.",
        .mandelbrot => "Visits three boundary regions for sixty effect-clock seconds each. " ++
            "The camera magnifies each view 160 times over the first fifty-four seconds. " ++
            "The final six seconds hold both cameras and crossfade the pictures. " ++
            "Speed controls the pace; window adjusts framing. Escape time and orbit angle " ++
            "select pixels from the audio image. The route repeats every three effect-clock minutes.",
    };
}

/// Anything the mouse can rest on that has something to say.
pub const Subject = union(enum) {
    stage: stages.Stage,
    knob: Knob,
    law: folding.Fold,

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
