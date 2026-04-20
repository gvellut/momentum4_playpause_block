The logging option flag is not a MODE. It is an additional setting for blocking and log, not just log. So update the message to indicate that it IS NOT JUST A LOG. AND if ouy just log. ADD THE BLOCK. 

Anyway what you did does not work :

Also I have run it with --logging : nothing is logged : but play pause is sent by the headset (music is paused or restarted when touching the headset). So what you did does not work. So Only work on a simple CLI version the simplest possible  none of that overengineered code you have in the current version and diagnose the issues and in the end make it work either with ID or a generic headset.

Logging consumer-control events for generic Audio / Headset. Press Control-C to stop.
Logging media-control events from transport: Audio | product: Headset | manufacturer: Apple | uniqueID: 4294969983.

Nothing further but music is paused played wiht the headset anyway.

Create a new target and CLI single file : (do not modify the existing code) that tests a few things : I will run it in debug mode
do not create tests
add flags to enable to test any of the paths to check theories in turn.

Look at this code : it has an alternate to what you do : it disables RCD and redirects the events from some devices (so what you would need to do for the same is also disable rcd and redirect all the events EXCEPT the one from the headset)

/Users/guilhem/Documents/projects/external/mac_ear_control/mac_ear_control/AppDelegate.m

I have also put some code in sample/code2.swift you should use that or complete it so you can test some theories :

The Diagnostic Tool: Testing all Theories

To figure out exactly how to proceed, we need to know:

    What exact Usage Page and Key Code the MOMENTUM 4 is sending.

    Whether macOS throws an "Exclusive Access" error when we try to seize the device (proving rcd is blocking us).

    Which specific generic name we can reliably target to differentiate it from your Keychron keyboard.

Here is a comprehensive Swift diagnostic tool. It listens to all Keyboards, Consumer Controls, and Telephony devices. It will print out exactly what happens when you press buttons on your keyboard vs. your headset.
