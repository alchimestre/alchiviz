# alchiviz

Real-time viz by a live audio input.

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
