# Momentum 4 Findings

## Verified Path

The Sennheiser Momentum 4 play/pause button is not reaching this Mac as a normal HID media event.

The confirmed path on this machine is:

`Momentum 4 AVRCP -> bluetoothd -> mediaremoted / MediaRemote -> Music`

## Evidence

Bluetooth SDP probing showed classic audio-control services and no HID service:

- `Audio Sink`
- `AV Remote Control`
- `AV Remote Control Target`
- `AV Remote Control Controller`
- `Hands-Free`
- no `Human Interface Device`

The direct Bluetooth-side proof is in [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:21) and [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:167):

- `Received AVRCP Pause command from device 80:C3:BA:82:06:6B`
- `Received AVRCP Play command from device 80:C3:BA:82:06:6B`

The forwarding into the media stack is visible in [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:24), [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:28), [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:171), and [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:175):

- `SenderBundleIdentifier = <com.apple.bluetoothd>`
- `mediaremoted` receives the command from client bundle `com.apple.bluetoothd`

The resulting playback-state flips are visible in [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:43) and [log.txt](/Users/guilhem/Documents/projects/github/momentum4_playpause_block/log.txt:224):

- `Playing -> Paused`
- `Paused -> Playing`

## What Failed

These theories were falsified for Momentum 4 on this Mac:

- HID `discover`: keyboard media keys appeared, headset play/pause did not
- HID `seize`: the generic Apple `Audio / Headset` endpoint could be seized, but headset play/pause still produced no HID events
- HID `redirect`: keyboard forwarding and headset interception did not produce a working headset-only block
- event-tap theories: keyboard events appeared, headset play/pause did not

Conclusion:

- Momentum 4 play/pause is not exposed here as a public HID event
- public HID and public event-tap interception are not enough for this headset
- selective blocking must be attempted at the Bluetooth / MediaRemote layer, or by headset-specific compensation after detection

## Working Compensation Mapping

From the logs, the practical headset-only compensation mapping is:

- incoming headset `Play` should be countered with `Pause`
- incoming headset `Pause` should be countered with `Play`

That is why the diagnostic CLI now includes private MediaRemote probing plus AVRCP-address-based reactive compensation attempts.
