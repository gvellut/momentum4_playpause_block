# Momentum4 PlayPause Block

Momentum4 PlayPause Block is a small macOS 15+ menu bar app that blocks media button events coming from one Bluetooth headset, such as a Sennheiser Momentum 4, without blocking media keys from other devices like keyboards.

The app lives in the background. Left-click the menu bar icon to open a menu with:

- `Preferences…`
- `Quit`

The icon is a simple circle:

- Filled circle: blocking is enabled
- Outline circle: blocking is disabled

If you hide the menu bar icon and later reopen the app from `/Applications`, the icon will appear again so you can interact with it and hide it later if you want.

## Preferences

The settings apply immediately.

- `Enable / disable block`
- `Show / Hide icon in menubar`
- `Open at Login`
- `Use generic Audio / Headset target`
- `Target Bluetooth Address`
- `Check`

The app has two explicit targeting modes:

- `Bluetooth address mode`
  This is the default. Blocking stays unavailable until you enter a full Bluetooth address, and the app will only block a media-control HID endpoint that can be linked back to that exact address.
- `Generic Audio / Headset mode`
  This ignores the Bluetooth address field and matches a media-control HID endpoint with `Transport = Audio` and `Product = Headset`.

The `Check` button tests the currently selected mode and shows whether the app found a matching media-control HID endpoint, plus rejection details when nothing matches.

On first launch, the app opens Preferences with blocking turned off and no device configured yet.

## Permissions

The app uses macOS HID APIs to inspect and seize the target headset’s media-control HID endpoint. For that to work, macOS may ask for:

- `Input Monitoring`
  Allow the app in `System Settings > Privacy & Security > Input Monitoring`.
- `Login Items` approval
  If you turn on `Open at Login`, macOS may ask for approval in `System Settings > General > Login Items`.

The app does not rely on an Accessibility event tap for its main blocking behavior.

## Finding Your Headset Address

If you need to change the target device, run:

```bash
system_profiler SPBluetoothDataType
```

Look for your headset entry. Example:

```text
MOMENTUM 4:
    Address: 80:C3:BA:82:06:6B
```

Copy that Bluetooth address into the `Target Bluetooth Address` field in Preferences.

If the exact Bluetooth address cannot be linked to any exposed media-control HID endpoint on your Mac, you can switch to `Use generic Audio / Headset target` and use `Check` again.

## Building The App

You do not need Xcode for this repo. Command Line Tools are enough.

1. Build the release `.app` bundle:

```bash
./scripts/build-app.sh
```

2. The signed app will be created at:

```text
dist/Momentum4PlayPauseBlock.app
```

3. Move it to `/Applications` if you want it to behave like a normal installed app.

## Developer Notes

Useful command-line workflows:

```bash
./scripts/sign-built-product.sh Momentum4PlayPauseBlock debug
./scripts/run-signed-product.sh Momentum4PlayPauseBlock debug
./scripts/sign-built-product.sh Momentum4PlayPauseBlockCLI debug
./scripts/run-signed-product.sh Momentum4PlayPauseBlockCLI debug -- --bluetooth-address 80:C3:BA:82:06:6B
./scripts/swift-package.sh test
./scripts/build-app.sh
```

### CLI Tool

The repo also includes a foreground CLI tool named `Momentum4PlayPauseBlockCLI`.

- It blocks the configured Bluetooth headset while the process is running.
- It does not share settings with the menu bar app.
- It can run in either strict Bluetooth-address mode or generic `Audio / Headset` mode, but not both at once.
- It requires the same HID/Input Monitoring permission, but the permission is granted to the terminal app that launches it.
- For development builds, use the signed build and run scripts so recompiles keep the same code identity in macOS.

Developer docs for the CLI are in [docs/cli.md](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/docs/cli.md:1).

### Signing

The packaging script signs the app with:

```text
My Swift Dev Cert
```

The VS Code build tasks now sign the debug and release executables with the same certificate, so a rebuild does not turn them back into a new unsigned binary from macOS's point of view.

Override it if needed:

```bash
SIGNING_IDENTITY="Your Certificate Name" ./scripts/build-app.sh
```

The script fails fast if the configured certificate is missing, because `Open at Login` requires a properly signed app bundle.

### VS Code

VS Code tasks are included for:

- Building the app target
- Running the app target
- Building the CLI target
- Running the CLI target
- Running the package test suite
- Building the signed `.app` bundle
