# alchiviz

Real-time audio visualiser with texture folds. The capture is drawn as nested
depth layers through a heat ramp, then folded across the screen.

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

Tunnel and rings fold the frame into radial lanes. Mandelbrot uses escape time
and orbit angle to select pixels from that same frame. The clock, mirrors and
depth shear move the sampled texture. The panels stay sharp over the fold.

## Loudness

Input is compressed and lifted before it reaches the picture, so a quiet microphone and a loud mix land in the same range. The level follower rises in 4 ms, falls in 350 ms, pushes toward 0.3 of full scale, and boosts a quiet signal by at most 20x, so silence is not amplified into hiss. Constants are in `signal.Agc`.

## Controls

| slider | what it moves |
|---|---|
| `speed` | the effect clock's step, so lanes expand and turn faster or slower together |
| `wander` | master intensity for every slider whose right-hand wander tick is on; left is off |
| `window` | the virtual window's own scale, from the real window at the left to six times it at the right |
| `lanes` | lanes per e-fold of radius, from 0.5625 to 4.375; default 1.375 |
| `colour` | slides the whole heat ramp around the colour wheel |
| `blur` | the soften pass over the columns |
| `mirror` | kaleidoscope facets, one to thirty-two; minimum bypasses kaleidoscope mirroring |
| `gate` | how hard quiet columns are pulled down |
| `kick` | how much beat motion reaches the fold, from none at the left to full punch at the right |

Each slider except `wander` has a wander tick on its right. Enabled values drift independently around the slider's base position. The handle stays at that base; unticking restores it. Values stay within the track, including whole mirror counts. Only `window` has wander enabled at startup.

The intensity sets the excursion in slider travel, up to half the track in either direction, reflected at the ends. `window` follows its geometric track. The master remains available with `fold` off for `speed`, `colour`, `blur` and `gate`.

### Gate

`gate` is a downward expander, not a switch. It ramps each column's gain from zero at silence to one at twice the slider's value, from `0` (off) to `8`. A column at the threshold keeps half its level, one at twice the threshold keeps all of it, and the curve between is smooth, so quiet passages fade into the tunnel instead of blinking out. Applied after smoothing, blur and level normalisation. At maximum, even the tallest columns retain only about 1.1% of their ungated height.

### Stages

Use `continuous` in the right panel to compare connected bands with endpoint wrapping and per-lane rotation. It starts off. The bottom blurb describes the hovered control.

| stage | what it does | off |
|---|---|---|
| `fold` | maps the window back into the frame through the selected mapping | the capture, flat |
| `continuous` | samples connected bands, reflects alternate bands and skips per-lane rotation | wraps the full-reach endpoint to the centre and rotates each lane |
| `spin` | turns the sampling frame with the clock | fixed frame |
| `mirrors` | kaleidoscope facets, count from the `mirror` slider | one unfolded sample |
| `kick` | everything the beat does: pushes the rings out, adds lanes, widens the window, hurries the clock | the fold stops moving with the music |

Choose a mapping in the `fold` dropdown. Its tick switches the whole fold off.

| Mapping | Texture coordinates |
|---|---|
| `tunnel` | log radius and screen angle |
| `rings` | linear radius and screen angle |
| `mandelbrot` | smooth escape time and orbit angle from `z = z*z + c`, starting at `z = 0` |

Mandelbrot visits each of three boundary regions for sixty effect-clock seconds.
The camera magnifies each view 160 times over the first fifty-four seconds.
The final six seconds hold both cameras and crossfade the pictures.
`speed` controls the pace. The route repeats every three effect-clock minutes.

`kick` applies a small, smoothed texture pulse without changing the camera,
lane count or clock pace. Lane changes are gradual; lane boundaries stay connected.
`continuous` disables separate lane rotation.
Each orbit uses at most 192 iterations. Fractal edges use one sample per pixel.
`window` adjusts framing. Spin and mirrors alter the sampled image.

Unavailable controls are grey and cannot be changed. Their values are kept when switching modes.

| condition | unavailable controls |
|---|---|
| `mirrors` off | `mirror` slider |
| `kick` off | `kick` slider |
| `fold` off | mapping dropdown, `continuous`, `spin`, `mirrors`, `window`, `lanes`, `mirror`, `kick` slider |

`speed` and the `kick` stage remain active with `fold` off: the clock also animates the source.

## Rendering

`src/wave.zig` builds the frame; `src/stages.zig` lists the fold's stages and their descriptions, and `src/fold.zig` flattens the switched-off ones in one `folding.Lens` before either the shader or the CPU fold sees them.

Drawing goes through dvui on SDL3's GPU backend (Metal on macOS). The fold is a fragment shader: one fullscreen triangle drawn into the swapchain before dvui draws the panel over it. `src/gpu.zig` holds the shader and the pipeline; it reproduces the same fold the CPU code in `src/fold.zig` does.

OS events are pumped before each frame starts. Fullscreen and resize transitions cannot change the active frame's render-target dimensions.

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
| `--backdrop <file>` | image tiled across the frame under the waveform |
| `--tiles <n>` | copies of the backdrop across the width (default 8) |
| `--list-devices` | print recording devices (`*` marks the default choice) and exit |

The backdrop repeats as a grid of square cells, `--tiles` copies across the
width and as many rows as fit. It is sampled nearest so pixel art stays sharp,
and it replaces the flat background the waveform draws over. Formats are what
stb reads: PNG, JPEG, BMP, TGA, GIF, PSD, HDR. A file that will not decode
prints one line and the frame draws as if the flag were absent.


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
| `src/fold.zig` | the fold, its clock and its mesh |
| `src/mandelbrot.zig` | boundary-region reference orbits and zoom route |
| `src/geom.zig` | triangle grid helpers |
