# momentum4 playpause block

Write a swift menu app for macos 15 and up.

It should allow to block play / pause events coming from the headphone Sennheiser Momentum 4 (but not from other devices like keyboards). It will essentially run in the background, except there will be a menubar item.

system_profiler SPBluetoothDataType shows :

MOMENTUM 4:
              Address: 80:C3:BA:82:06:6B
              Minor Type: Headset
              RSSI: -50
              Services: 0x800019 < HFP AVRCP A2DP ACL >

for it (so no vendor Id or product Id)


## dev

Use 

Swift 6
Swift UI

You should setup all the swift CLI needed to build from VSCode and command line (XCode will NOT be used)

Use "My Swift Dev Cert" for signing (local certificate ; the app will not be distributed beyond my computer)

## Interaction

When left click on the icon in menu bar : popup menu below the menubar button :

Preferences ...
Quit

On Preferences :
settings panel opens

"Enable / disable block" toggle button : default is enabled
toggle button : "Show / Hide icon in menubar"
toggle button : "Open at Login"

They take effect right away (no OK needed)

For the menubar icon :
Use a generic icon with a circle (like a flower or a circle) only the one color like standard menubar icons (they appear white)
If block disabled : the icon should have only an outline. If enabled, the icon should be filled.

Wire those options in the app.

## Functionality

When the block is enabled, the events play pause sent from the headphone (and just those from the headphone ; not from a BT keyboard for ex) are sinkholed and do not interact further (eg with Apple Music or other media player).

Look at code sample/code.swift . you can use it for reference (do not use it as is in the software). Maybe it works, maybe it does not : another LLM gave me that. It told me :

Yes! To do this, we have to change our strategy.
Because the CGEventTap method from the previous answer operates at a very high software level, it sees all play/pause commands exactly the same, no matter who sent them.
To selectively block only the Momentum 4 and leave your Keychron alone, we must go deeper into the IOKit Hardware APIs.
macOS exposes "Media Key" devices (like keyboards and AVRCP headset commands) via the IOHIDManager. We can use an Apple API flag called kIOHIDOptionsTypeSeizeDevice.
By "seizing" the specific virtual HID device that macOS creates for your Momentum 4, your Swift script will take exclusive control over it. macOS will be locked out of reading its buttons, completely neutralizing the headset's play/pause commands, while the Keychron continues to function normally.

## Showing the menubar icon if the user re-opens the app from the /Applications folder.

If the menubar icon was configured as hidden : reopening from /Application shows it again (with the correct icon form is block is enabled or disabled). The user can interact with it then and rehide it explcitly at some point.

## first launch

the very first manual launch :  check for a "First Launch" flag in UserDefaults.

func applicationDidFinishLaunching(_ notification: Notification) {
    let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
    if !hasLaunchedBefore {
        windowManager.showSettings()
        UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
    }
}

## Documentation 

Write a README from POV of users (not developers). What permission to give in macos
Write a section for developer : how to build the .app in command line.