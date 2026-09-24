# Clocky

A native macOS menu-bar clock overlay. Requires macOS 13+ and Swift 5.9+ (Xcode or Command Line Tools). No external dependencies.

## Build and run

From the repository root:

```sh
swift run Clocky
swift test
./scripts/build-app.sh
open build/Clocky.app
```

Quit the development instance from the Clocky menu before opening the bundle. The packaging script works from any working directory, defaults to release, and accepts `--debug`. It replaces only the generated `build/Clocky.app`, validates its plist, and ad hoc signs it for local use. It is **not notarized** or signed for distribution. The bundle identifier is `local.clocky.app`.

For a short native-panel check in a logged-in graphical session:

```sh
swift run Clocky --smoke-test
# Or, after packaging:
./build/Clocky.app/Contents/MacOS/Clocky --smoke-test
```

This uses isolated preferences, checks panels, prints a result, and exits after about one second (nonzero on failure). It does not establish cross-app or full-screen behavior; see [manual testing](docs/TESTING.md).

## Use

- One clock per logical display; mirrored displays share a clock. Locked clocks pass clicks through to the app underneath.
- Choose **Move Clocks…** from the menu bar (or **Move Clocks** in Settings), drag each clock within its own display, then **Lock Positions**. Clocks start locked on every launch.
- SwiftUI **Settings…** provides System/12-hour/24-hour format, seconds, installed font families and faces, text size, text/background colors, and background opacity. Choose **System Default** to restore the original font. An unavailable saved font falls back to the system font without losing your selection. Appearance, visibility, and per-display positions persist locally. **Reset Positions** restores top-right placement without resetting appearance.
- **Start at Login** in Settings uses macOS's native login-item service. It is opt-in and never enabled automatically. Use the packaged `Clocky.app`, preferably from a stable location such as `/Applications`, before enabling it. Direct `swift run` and smoke tests cannot change login registration. If macOS requires approval, use **Manage Login Items…**; the pending request is shown as such, not as an active login item. Turning the toggle off unregisters Clocky without quitting it. macOS is the source of truth, including changes made in System Settings.
- **Show Clocks** hides/shows overlays without removing the menu-bar control. **Quit Clocky** exits without changing the login-item choice.

Overlays are nonactivating AppKit `NSPanel`s at `.statusBar` level with `.canJoinAllSpaces`, `.fullScreenAuxiliary`, and `.canJoinAllApplications`. They cannot become key/main windows and do not steal keyboard focus; opening Settings intentionally activates the app. Placement respects the display's usable area, including the menu bar, Dock, and notch safe area.

Clocky makes no network requests and requires no Screen Recording or Accessibility permissions or special entitlements. Enabling Start at Login may require macOS approval; registration/signature errors are displayed in Settings instead of silently claiming success. It reads local system time and stores appearance preferences locally. Direct `swift run` and the bundled app may use different preferences domains.

Visibility above secure system UI, the lock screen, or exclusive full-screen apps **cannot be guaranteed**. Spaces, normal full-screen apps, Stage Manager, and multi-display behavior still require manual validation on the target macOS/hardware; automated checks are not proof of universal “always on top” behavior.
