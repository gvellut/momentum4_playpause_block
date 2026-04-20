# Momentum4 PlayPause Block

Momentum4 PlayPause Block is a macOS 15+ menu bar app and companion CLI that block remote play/pause commands by owning the active media-command path, then forwarding only approved HID play/pause presses back to Apple Music.

## What The Supported Path Does

- Swallows remote play/pause commands that do not correlate with an allowed HID source.
- Forwards approved HID play/pause presses to Apple Music.
- Keeps the app in the menu bar unless you choose to hide it.

## Limitations

- Apple Music only.
  Forwarding uses AppleScript to control `Music`, so Spotify and other players are not supported by the production path.
- The app no longer targets a Bluetooth address.
  The supported path is source-based, not headset-ID-based.
- While blocking is enabled, non-approved remote play/pause sources are swallowed globally.

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

The result is:

```text
dist/Momentum4PlayPauseBlock.app
```

## Main CLI

`Momentum4PlayPauseBlockCLI` uses the same Apple Music-only proxy path as the menu bar app, but it stays in the foreground and does not use the app’s stored settings.

Examples:

```bash
./scripts/sign-built-product.sh Momentum4PlayPauseBlockCLI debug
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug -- --forward-source any-keyboard
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug -- --forward-source specific-product-name --product-name "Keychron K1 Pro"
```

CLI details are in [docs/cli.md](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/docs/cli.md:1).

## Developer Notes

Useful commands:

```bash
./scripts/sign-built-product.sh Momentum4PlayPauseBlock debug
./scripts/sign-built-product.sh Momentum4PlayPauseBlockCLI debug
./scripts/swift-package.sh test
./scripts/build-app.sh
```

The package still contains an internal diagnostic executable for experimentation, but it is intentionally not part of the documented or surfaced production workflow.
