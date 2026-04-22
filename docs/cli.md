# CLI Guide

`Momentum4PlayPauseBlockCLI` runs the supported Apple Music-only proxy path in the foreground.

It does not use the app’s `UserDefaults`, menu bar UI, or Login Item support, but it does use the same forwarding model:

- swallow remote play/pause commands by default
- allow forwarding only from the HID source mode you choose
- send approved commands to Apple Music through AppleScript

## Options

- `--forward-source specific-product-name | any-keyboard | any-hid`
  Default: `any-hid`
- `--product-name "Exact HID Product Name"`
  Required only when `--forward-source specific-product-name` is used

## Permissions

The CLI needs the same permissions as the app:

- `Input Monitoring`
  Grant it to the terminal host that launches the CLI.
- `Automation` for `Music`
  The first forwarded command may trigger the Music automation prompt.

On some systems macOS may still require one relaunch after both permissions are granted.

## Notes

- Apple Music only.
- The repo's supported script workflow packages the app bundle only; the CLI target remains available for development
