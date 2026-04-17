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
- `Target Bluetooth Address`

The target Bluetooth address is advanced configuration. By default it is set to:

`80:C3:BA:82:06:6B`

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
./scripts/swift-package.sh build --product Momentum4PlayPauseBlock
./scripts/swift-package.sh run Momentum4PlayPauseBlock
./scripts/swift-package.sh test
./scripts/build-app.sh
```

### Signing

The packaging script signs the app with:

```text
My Swift Dev Cert
```

Override it if needed:

```bash
SIGNING_IDENTITY="Your Certificate Name" ./scripts/build-app.sh
```

The script fails fast if the configured certificate is missing, because `Open at Login` requires a properly signed app bundle.

### VS Code

VS Code tasks are included for:

- Building the app target
- Running the app target
- Running the package test suite
- Building the signed `.app` bundle
