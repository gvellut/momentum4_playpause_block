Implement in the app and CLI the path that works 
 "target": "Momentum4PlayPauseBlockDiagCLI",
[
  "--theory",
  "now-playing-proxy",
  "--proxy-mode",
  "bypass-hid",
  "--proxy-hid-match",
  "keychron-only"
]

Make clear the limitations in README and in a text of the settings panel
- Apple Music only (since osascript is used to control it)

Manage the settings panel conffiguration : what can be configured ?
source to allow forward : 
- specific device matchesKeychronK1Pro (product = ...Name ) => let user enter free text OR also add some way to capture source of some input : click a button let the user type a key => grab the product name and fill the text field
- All keyboards : isKeyboardInterface
- all HID => Default

others ?

The bluetooth Id of the Momentum 4 headset is useles now so remove the configuration

Leave the states : 
enable block / forward
start at login
hide from menubar

with the other mentioned stuff kept like if launched from /Application => open Settings panel (instead of showing the icon in menu bar ; can reenable the icon from there ; but not in menu bar : closing hte panel does not reshow the icon in menubar)

Make the request for permissions in the settings Panel : when enabling or some other standard flow. on first launch : not have to launch multiple times : ie control Music +  input monitoring
If possible (not sure) : make it possible to not have to relaunch : otherwise : make it so relaunch only once after the permissions are set by user

Keep the CLI used for the tests ( "target": "Momentum4PlayPauseBlockDiagCLI",) in code. But remove from tasks and README and target and code. Do not use that code from anywhere else in the app or main CLI.
document in the README  the limitations
Change the CLI Momentum4PlayPauseBlockCLI : so it reuses the same as the app (only the path that works)
Clean up the tests so only that path that works should be tested (and that is present in the CLI and app)