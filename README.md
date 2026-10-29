# alchiviz

Real-time DMT tunnel fed by a live audio input. The capture is drawn as nested depth
layers through a heat ramp, then folded into a tunnel by the same transform as
alchimix's DMT mode.

## Requirements

- macOS with Homebrew `sdl3` and Zig 0.17
- No SDL3 or Zig install paths need configuring; the build asks Homebrew.

## Build and run

```sh
zig build run
```

Pass arguments through to the binary:

```sh
zig build run -- --device "eqMac Export"
```

## Picture

The capture is drawn as terrain: eighteen depth layers of the same waveform,
each smaller, dimmer and shifted by wandering noise, painted through a heat
ramp indexed by loudness, depth and column, so the frame spans the whole ramp.

That frame is then folded into lanes: the radius picks the lane, alternate lanes
are reflected so the picture mirrors outward, and each lane starts its sweep at a
different point of the frame. The clock turns the whole sampling
frame at `spin_rate` times its own turn, so the lanes and their seams sweep
around the middle, and the angle folds into kaleidoscope facets, which is where
the mirrors show. The panel is masked out of the fold and painted back sharp.

## Loudness

Input is compressed and lifted before it reaches the picture, so a quiet microphone and a loud mix land in the same range. The level follower rises in 4 ms, falls in 350 ms, pushes toward 0.3 of full scale, and boosts a quiet signal by at most 20x, so silence is not amplified into hiss. Constants are in `signal.Agc`.

## Controls

| slider | what it moves |
|---|---|
| `speed` | the effect clock's step, so lanes expand and turn faster or slower together |
| `wander` | how far the virtual window breathes, which changes how many lanes fit on screen |
| `window` | the virtual window's own scale, from the real window at the left to six times it at the right |
| `lanes` | lanes per e-fold of radius |
| `colour` | slides the whole heat ramp around the colour wheel |
| `blur` | the soften pass over the columns |
| `mirror` | kaleidoscope facets |
| `gate` | how hard quiet columns are pulled down |
| `kick` | how much of a captured hit reaches the fold, 0 to 6 |

### Gate

`gate` is a downward expander, not a switch. It ramps each column's gain from zero at silence to one at twice the slider's value, from `0` (off) to `1`, where the whole frame is attenuated. A column at the threshold keeps half its level, one at twice the threshold keeps all of it, and the curve between is smooth, so quiet passages fade into the tunnel instead of blinking out. Applied to the columns before the envelope is smoothed.

### Stages

The right panel is the fold, one toggle per stage, in the order a screen point goes through it. The blurb along the bottom describes the stage under the mouse: what it does, what it changes when off, and which slider moves it. Switching a stage off leaves the rest running, so the picture shows what it contributed.

| stage | what it does | off |
|---|---|---|
| `fold` | maps the window back into the frame; the dropdown picks the radial law | the capture, flat |
| `spin` | turns the sampling frame with the clock | fixed frame |
| `mirrors` | kaleidoscope facets, count from the `mirror` slider | one unfolded sample |
| `stagger` | starts each lane at its own point of the sweep | every lane shows the same band |
| `kick` | everything the beat does: pushes the rings out, adds lanes, widens the window, hurries the clock | the fold stops moving with the music |

The `fold` row also has a dropdown for the radial law. `tunnel` takes the log radius, so rings keep their screen thickness and the picture recedes. `rings` takes the radius straight, so each copy is wider than the one inside it and the frame expands outward from the middle. `branches` is `rings` without the reflection on every other ring, so the frame's lanes run straight out from the middle. The tick beside the dropdown switches the whole fold off.

## Rendering

`src/wave.zig` builds the frame; `src/stages.zig` lists the fold's stages and their descriptions, and `src/dmt.zig` flattens the switched-off ones in one `dmt.Lens` before either the shader or the CPU fold sees them.

Drawing goes through dvui on SDL3's GPU backend (Metal on macOS). The tunnel itself is a fragment shader: one fullscreen triangle drawn into the swapchain before dvui draws the panel over it, so the fold costs the CPU nothing per frame. `src/gpu.zig` holds the shader and the pipeline; it reproduces the same fold the CPU code in `src/dmt.zig` does.

If the pipeline cannot be created, the app says so on stderr and falls back to the CPU fold.

## Keys

Keybinds live in `$XDG_CONFIG_HOME/alchiviz/keys.conf`, or `~/.config/alchiviz/keys.conf` when `XDG_CONFIG_HOME` is unset. One `key = action` per line, `#` for comments. The file is optional; without it the defaults apply.

```
# actions: toggle-ui
h = toggle-ui
```

Keys are the names dvui uses: `a` to `z`, `zero` to `nine`, `escape`, `space`, `f1` to `f25`.

## Input

| Flag | Effect |
|---|---|
| none | the system output, then a loopback device if one is installed (eqMac, BlackHole, Loopback, Soundflower), then the system default recording device |
| `--device <text>` | device whose name contains `<text>`, case-insensitive |
| `--list-devices` | print recording devices (`*` marks the default choice) and exit |

The capture stream is mono float at 48 kHz whatever the device offers.

`system output` is a CoreAudio process tap: it copies whatever the default
output plays, so nothing has to be rerouted and playback keeps going. macOS
asks for System Audio Recording permission the first time. The tap is macOS
14.2 and later; on older systems, install a loopback driver and route the
output through it.

The device can also be switched from the dropdown in the top-left corner. The
selection lasts for the session.

## Tests

```sh
zig build test
```

## Source

| File | Holds |
|---|---|
| `src/main.zig` | argument parsing, window loop |
| `src/app.zig` | capture, levels, waveform texture, fold draw, controls |
| `src/audio.zig` | recording devices, capture stream |
| `src/tap.zig` | the system-output tap and its aggregate device |
| `src/signal.zig` | sample history ring, band split, column statistics |
| `src/wave.zig` | waveform bars and their colour |
| `src/dmt.zig` | the fold, its clock and its mesh |
| `src/geom.zig` | triangle grid helpers |
