# WindowBuddy

WindowBuddy is a macOS menu bar app for arranging and orchestrating application windows. It provides automatic tiling groups, focus groups, focused-window resizing, and global hotkeys for common window workflows.

## Features

- Configure app groups for automatic tiling.
- Choose per-group screen layout, tile direction, and maximum columns.
- Widen the focused tiled window, with per-app resize behavior.
- Hide, reveal, and switch focus groups together.
- Remember and manage Finder's last window behavior.
- Run from the menu bar, with an optional Dock icon.

## Hotkeys

- `Option` + `Up Arrow`: Fill the frontmost window and temporarily remove it from tiling.
- `Option` + `Down Arrow`: Restore the most recently removed window to tiling.
- `Command` + `Shift` + `7`: Resize auto-tiled windows.
- `Command` + `Shift` + `6`: Toggle focus groups.
- `Command` + `Shift` + `8`: Open settings.

## Requirements

- macOS 26.4 or newer, matching the current Xcode deployment target.
- Xcode 26.5 or newer, or the Xcode beta currently used by this project.
- Accessibility permission for WindowBuddy, required for moving and inspecting windows.

## Build

Open `WindowBuddy.xcodeproj` in Xcode and build the `WindowBuddy` scheme.

From the command line:

```sh
xcodebuild -project WindowBuddy.xcodeproj -scheme WindowBuddy -configuration Debug build
```

If your active developer directory points at Command Line Tools instead of Xcode, select Xcode first or set `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project WindowBuddy.xcodeproj -scheme WindowBuddy -configuration Debug build
```

## Open Source

WindowBuddy is released under the MIT License. See `LICENSE`.
