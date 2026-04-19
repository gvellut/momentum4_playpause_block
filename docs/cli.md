# CLI Developer Guide

`Momentum4PlayPauseBlockCLI` is a foreground command-line tool that blocks media-control events from one Bluetooth headset while the process is running.

It uses the same HID blocking code as the menu bar app, but it does not use the app's `UserDefaults`, menu bar UI, or Login Item support.

Choose exactly one target mode when you run it:

- `--bluetooth-address <id>`
- `--generic-audio-headset`

Those two flags are mutually exclusive.

## Permissions

The CLI also needs macOS permission to inspect HID media events.

- `Input Monitoring`
  Allow the terminal app that launches the CLI in `System Settings > Privacy & Security > Input Monitoring`.

If you run the CLI from VS Code's integrated terminal, Terminal, iTerm, or another shell host, grant Input Monitoring to that host app.

Without that permission, the CLI will exit with an error after macOS denies HID listen access.

## Find The Bluetooth Address

Run:

```bash
system_profiler SPBluetoothDataType
```

Look for your headset and copy its `Address`, for example:

```text
MOMENTUM 4:
    Address: 80:C3:BA:82:06:6B
```

## Build

Debug build:

```bash
./scripts/sign-built-product.sh Momentum4PlayPauseBlockCLI debug
```

Release build:

```bash
./scripts/sign-built-product.sh Momentum4PlayPauseBlockCLI release
```

## Run

Run the signed development binary:

```bash
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug -- --bluetooth-address 80:C3:BA:82:06:6B
```

Or run it against the generic `Audio / Headset` endpoint:

```bash
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug -- --generic-audio-headset
```

The CLI stays in the foreground and keeps watching for the matching HID endpoint. Stop it with `Control-C`.

If the device is not connected yet, the CLI stays alive and waits until the headset appears.

## Use The Built Binary

After building, ask SwiftPM for the binary directory:

```bash
./scripts/swift-package.sh build --show-bin-path
```

Then run the binary directly:

```bash
<bin-path>/Momentum4PlayPauseBlockCLI --bluetooth-address 80:C3:BA:82:06:6B
```

Or:

```bash
<bin-path>/Momentum4PlayPauseBlockCLI --generic-audio-headset
```

For repeat use outside development, a release build is the better default.

## Why The Signed Dev Build Matters

Plain `swift build` outputs are rewritten on each compile and can look like a brand new unsigned program to macOS. That can make previously granted `Input Monitoring` approval stop applying.

The signed build and run scripts in this repo rebuild the CLI and then sign the resulting binary with `My Swift Dev Cert`, which gives the development binary a stable code identity across recompiles.
