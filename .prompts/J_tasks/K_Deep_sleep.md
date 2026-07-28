I requested Codex for a check as to why my computer was still warm even after it seemed to go into deep sleep (ie after screensaver run + displays turn balck) :

coreaudiod, created for PID 76796: /Users/guilhem/dev/projects/github/momentum4_playpause_block/.build/.../Momentum4PlayPauseBlock, holding audio idle-sleep.

So this is the issue. I would like for you to disable the block before sleep so when the display go to sleep after idle or if sleep is done manually or if computer is locked (then the displays go dark quickly), the block is disabled (and deep sleep can happen) and reenable it (only If block is enabled in the menubar app) when the computer and the displays wake up again (or on login ; but if I dont login after wake up and the screen lock is on, it goes back to sleep and the block turns off so deep sleep can happen). Either before the displays go dark or after. I just dont want the computer to be warm because of this app.

Yes, but **“before sleep” has two different meanings** on macOS.

If you mean **manual sleep / lid close / Apple menu Sleep**, use sleep/wake notifications:

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.willSleepNotification,
    object: nil,
    queue: .main
) { _ in
    disableAudioOutput()
}

NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil,
    queue: .main
) { _ in
    enableAudioOutput()
}
```

But if you mean **automatic idle sleep**, your current audio output may prevent macOS from ever reaching `willSleepNotification`. In that case you need an earlier signal: `IORegisterForSystemPower`, especially `kIOMessageCanSystemSleep`. In that callback, stop/close the audio output, then call `IOAllowPowerChange`.

Rough shape:

```swift
case kIOMessageCanSystemSleep:
    disableAudioOutput()
    IOAllowPowerChange(rootPort, messageArgument)
```

Then on wake:

```swift
case kIOMessageSystemHasPoweredOn:
    enableAudioOutput()
```

So the model is:

- `willSleepNotification`: good for manual/forced sleep cleanup.
- `kIOMessageCanSystemSleep`: best chance to release audio before automatic idle sleep.
- Wake: restart audio on `didWakeNotification` or `kIOMessageSystemHasPoweredOn`.

The critical part is that `disableAudioOutput()` must actually stop the audio device path, not just mute volume. Stop the engine/player/audio queue or close the output unit. Muting still leaves `coreaudiod` holding the sleep-prevention assertion.
