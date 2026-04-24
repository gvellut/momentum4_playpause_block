# Momentum4 PlayPause Block

Momentum4 PlayPause Block is a macOS 15+ menu bar app that blocks remote play/pause commands by the Sennheiser Momentum 4 headset.

It solves the issue I have where every smart feature (including on-head detection) is disabled with the Sennheiser app but the music still pauses or plays sometimes when I move the earcup to scratch my ear. Manual pause / play with keyboard key press or the Apple Music controls still works.

## How it blocks the headset

- a hidden AppKit-backed process with a silent now-playing proxy so macOS routes media commands to it. The controls from the headset are not routed through HID (which would make it easy to intercept and block), so a more complex process is used.
- HID correlation so only approved HID play/pause presses are treated as real local input.
- Apple Music forwarding through `osascript` for approved presses
- swallowing of remote play/pause commands that do not correlate with an allowed HID source
- the menu bar app stays in the menu bar unless you choose to hide it

## Limitations

- Apple Music only. Forwarding uses AppleScript to control `Music`, so Spotify and other players are not supported in the current version.
- The supported path is source-based, not headset-ID-based. While blocking is enabled, non-approved remote play/pause sources are swallowed globally: The app targets the way the Sennheiser Momentum 4 connects to macOS for swallowing its events. It may work for other headsets with similar setup (AVRCP) but not a given.

## Settings

The settings apply immediately.

- `Enable / disable block`
- `Source to allow forward`
  - `Specific device name`
  - `All keyboards`
  - `All HID`
- `Exact HID product name`
  Only shown for `Specific device name`.
- `Capture From Key Press`
  Listen for the next HID key press and fill the device name automatically.
- `Show / Hide icon in menubar`
- `Open at Login`

If the menu bar icon is hidden and you open the app manually from `/Applications`, the app opens Settings without restoring the icon. Re-enable the icon from Settings if you want it back in the menu bar.

## Permissions

The supported path needs:

- `Input Monitoring`
  Needed so the app can observe HID play/pause presses.
- `Automation` for `Music`
  Needed because the approved play/pause command is forwarded to Apple Music through AppleScript.

Enable blocking from Settings to trigger the permission flow. On some systems macOS may still require one relaunch after both permissions are granted.

## Building The App

You do not need Xcode for this repo. Command Line Tools are enough.

Build the signed release app bundle:

```bash
./scripts/build-app.sh
```

The script uses `My Swift Dev Cert` as the default `SIGNING_IDENTITY`. Override it if your local certificate has a different name:

```bash
SIGNING_IDENTITY="Your Certificate Name" ./scripts/build-app.sh
```

The result is:

```text
dist/Momentum4PlayPauseBlock.app
```

## Simple CLI for testing

`Momentum4PlayPauseBlockCLI` uses the same Apple Music-only proxy path as the menu bar app, but it stays in the foreground, keeps event-driven ownership reclaim enabled, and uses a `15s` timed reclaim backstop by default.

CLI details are in [docs/cli.md](docs/cli.md).
