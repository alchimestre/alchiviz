# alchiviz

Real-time DMT tunnel fed by a live audio input. The capture is drawn as a
waveform across the whole window, then folded by the same transform as
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

## Input

| Flag | Effect |
|---|---|
| none | a loopback device if one is installed (eqMac, BlackHole, Loopback, Soundflower), otherwise the system default recording device |
| `--device <text>` | device whose name contains `<text>`, case-insensitive |
| `--list-devices` | print recording devices (`*` marks the default choice) and exit |

The capture stream is mono float at 48 kHz whatever the device offers.

To visualize the system's main output on macOS, install a loopback driver and
route the output through it; the visualizer picks it up without further
configuration.

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
| `src/signal.zig` | sample history ring, band split, column statistics |
| `src/wave.zig` | waveform bars and their colour |
| `src/dmt.zig` | the fold, its clock and its mesh |
| `src/geom.zig` | triangle grid helpers |
