Create multiple binaries : ie I want the menubar app for deployment (that you implemented): but I also want a simple CLI that blocks the device bluetooth when the program is run (no other setting is necessary ; it does not need to share setting with the menubar app). It can have a parameter : the bluetooth ID that needs to be blocked.

Write developer docs for the CLI tool (including permissions).

Use the shared code + add target in Package.swift
Also separate what belons in the .app and what is common with both (so 3 packages : common, cli, app + if you want an app support for the code that is in Core now but related to GUI funtionality only)

Also : change the .app : when first launched, since the bluetooth device needs to be configured, do not enable the block : it should only start to block when the user has entered a bluetoot device ID and enabled the block in the setting panel. The enablement is not possible unless the bluetooth ID is filled. 