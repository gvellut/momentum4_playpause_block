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

Default `any-hid` mode:

```bash
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug
```

Allow only keyboard HID sources:

```bash
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug -- --forward-source any-keyboard
```

Allow one exact HID product name:

```bash
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug -- --forward-source specific-product-name --product-name "Keychron K1 Pro"
```

The CLI stays in the foreground until you stop it with `Control-C`.

## Notes

- Apple Music only.
- The CLI no longer accepts Bluetooth-address or generic-headset flags.
- The documented production path is source-based, not headset-ID-based.
