# Clocky

A native macOS menu-bar clock and battery overlay. Requires macOS 13+ and Swift 5.9+ (Xcode or Command Line Tools). No required external dependencies; primary iPhone USB/Wi-Fi readings use optional `libimobiledevice` tools. An experimental, opt-in BLE fallback uses built-in macOS frameworks.

## Build and run

From the repository root:

```sh
swift run Clocky
swift test
./scripts/build-app.sh
open build/Clocky.app
```

Quit the development instance from the Clocky menu before opening the bundle. The packaging script works from any working directory, defaults to release, and accepts `--debug`. It replaces only the generated `build/Clocky.app`, validates its plist, and ad hoc signs it for local use. It is **not notarized** or signed for distribution. The bundle identifier is `dev.xikxp1.clocky`.

For a short native-panel check in a logged-in graphical session:

```sh
swift run Clocky --smoke-test
# Or, after packaging:
./build/Clocky.app/Contents/MacOS/Clocky --smoke-test
```

This uses isolated preferences, checks panels, prints a result, and exits after about one second (nonzero on failure). It does not establish cross-app or full-screen behavior; see [manual testing](docs/TESTING.md).

## Use

- One clock per logical display; mirrored displays share a clock. Locked clocks pass clicks through to the app underneath.
- Compact battery icons sit in two columns beside the clock: **Mac** above **iPhone** on the left; **AirPods** above **AirPods case** on the right. AirPods shows the lower available earbud charge; AirPods Max shows its headset charge. Case charge is separate and never substitutes for missing earbud charge. Missing readings show **-**, not 0%. Settings retains full **L** (left), **R** (right), and **C** (case) details.
- **Battery visibility** in Settings has four independent, saved switches. Turning off one reading leaves its slot empty; turning off both readings in a column removes that column. Turning all four off restores a time-only clock. These switches affect overlays and their preview, not the full battery details in Settings.
- Choose **Move Clocks…** from the menu bar (or **Move Clocks** in Settings), drag each clock within its own display, then **Lock Positions**. Clocks start locked on every launch.
- SwiftUI **Settings…** provides System/12-hour/24-hour format, seconds, installed font families and faces, text size, text/background colors, and background opacity. Choose **System Default** to restore the original font. An unavailable saved font falls back to the system font without losing your selection. Appearance, visibility, and per-display positions persist locally. **Reset Positions** restores top-right placement without resetting appearance.
- **Start at Login** in Settings uses macOS's native login-item service. It is opt-in and never enabled automatically. Use the packaged `Clocky.app`, preferably from a stable location such as `/Applications`, before enabling it. Direct `swift run` and smoke tests cannot change login registration. If macOS requires approval, use **Manage Login Items…**; the pending request is shown as such, not as an active login item. Turning the toggle off unregisters Clocky without quitting it. macOS is the source of truth, including changes made in System Settings.
- **Show Clocks** hides/shows overlays without removing the menu-bar control. **Quit Clocky** exits without changing the login-item choice.

Overlays are nonactivating AppKit `NSPanel`s at `.statusBar` level with `.canJoinAllSpaces`, `.fullScreenAuxiliary`, and `.canJoinAllApplications`. They cannot become key/main windows and do not steal keyboard focus; opening Settings intentionally activates the app. Placement respects the display's usable area, including the menu bar, Dock, and notch safe area.

Clocky requires no Screen Recording or Accessibility permissions or special entitlements. It reads local system time and battery information and stores preferences locally, including BLE UUIDs/names only for devices you explicitly select. Battery history is not stored. When battery readings are active, macOS may request Bluetooth permission so Clocky can observe connection changes and refresh readings sooner. By default, Clocky only observes connections. Enabling the optional BLE fallback permits bounded scans and GATT connections to your explicitly selected iPhone; Clocky does not issue pair/unpair commands. Polling remains the fallback if event monitoring is unavailable. The optional iPhone helper can communicate with a paired device over your local network; Clocky sends no telemetry or data to Internet services. Enabling Start at Login may require macOS approval; registration/signature errors are displayed in Settings instead of silently claiming success. Direct `swift run` and the bundled app may use different preferences domains.

## Battery readings and iPhone setup

Battery readings refresh on launch while visible clocks have at least one battery reading enabled, or while Settings is visible. Mac, AirPods, and iPhone readings publish independently as each query finishes, so a slow iPhone lookup does not delay the others. Each source polls again approximately 30 seconds after its own query completes. Bluetooth connection/disconnection events also refresh **all three sources** after a one-second quiet period; bursts are coalesced, pre-event queries are cancelled, and replacement queries wait for their own previous helper to exit rather than overlapping it. During Clocky's own iPhone BLE read and a three-second cleanup grace period, connection-event refreshes are suppressed to avoid a self-triggered refresh loop; unrelated events during that window wait for normal polling. Polling and Bluetooth monitoring pause when no readings are displayed and Settings is closed/minimized, or when displays sleep, and resume with fresh samples. Reads run in the background with timeouts; an unavailable result clears only that source, not the other readings.

- **Mac:** the built-in laptop battery, read through macOS power-source APIs. A desktop Mac without an internal battery shows a dash (N/A in Settings).
- **AirPods:** connected devices reported by macOS Bluetooth system information. Case and individual earbud readings depend on what macOS exposes and may lag the hardware; opening the case may make its level available. Disconnected cached devices are ignored. With multiple connected sets, Clocky selects one deterministically, preferring the most complete readings.
- **iPhone (primary USB/Wi-Fi reader):** install the optional tools yourself, for example with Homebrew:

  ```sh
  brew install libimobiledevice
  ```

  Connect the iPhone over USB, unlock it, and establish trust/pairing with this Mac in Finder. Clocky does not install tools or issue pair/unpair commands. Before querying battery data, it checks the device's saved pairing HostID and validates the pairing, then lets the helper open an authenticated session. For Wi-Fi access, enable **Show this iPhone when on Wi-Fi** in Finder while connected by cable, apply the change, and keep both devices on the same network. Availability depends on iOS, pairing, network configuration, and the installed helper version; Bluetooth pairing alone is insufficient.

  With your already-paired phone connected, check whether the helper exposes the battery domain:

  ```sh
  idevicepair validate && ideviceinfo -x -q com.apple.mobile.battery
  # For an already paired device discoverable over Wi-Fi:
  idevicepair -n validate && ideviceinfo -n -x -q com.apple.mobile.battery
  ```

  Do not add `-s` to the battery query: it skips authentication and can return an empty dictionary even for a trusted phone. Clocky needs all three tools: `idevice_id`, `ideviceinfo`, and `idevicepair`. Wi-Fi validation requires a helper build supporting `idevicepair -n` (verified with 1.4.0). The helper handles authentication internally; keep the existing pairing valid, and repair trust in Finder if it has been revoked.

  Look for `BatteryCurrentCapacity`. If unavailable and no usable BLE fallback is configured, Clocky shows a dash (N/A in Settings). It detects tools in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`, or absolute directories in its launch environment's `PATH`. USB is preferred over Wi-Fi; with multiple devices, it uses the first readable iPhone in device-ID order, skipping iPads. The helper search is limited to four candidates and eight seconds per sample. Installing the tools is optional and does not affect Mac or AirPods readings.

### Optional BLE fallback (experimental)

In the packaged app, open **Settings → Optional Bluetooth fallback**, enable it, and choose **Scan for Devices**. Scans last up to five seconds. Open the AirPods case and keep your iPhone's Bluetooth on, then explicitly select each desired device. Names alone are not identity: the pickers also display a UUID suffix. Nearby Apple-device advertisements are only iPhone candidates, not proof that they expose a battery service.

- **Off by default.** Selected BLE UUIDs/names are remembered locally. **Forget** clears a selection; disabling BLE retains it without scanning or connecting. Bluetooth identifiers can change, requiring a new selection.
- **Primary readers win.** BLE is attempted only after a device's primary reading is wholly unavailable. A primary AirPods result with only its case level is still primary: missing earbuds are not filled from BLE. BLE selections do not change which devices the primary readers select, and different sources are never combined within an AirPods reading.
- **AirPods:** passive parsing of the selected UUID's freshly received, standard `0x07` advertisement. Levels use approximate ten-percentage-point steps and display `~70%`, with “approximately” in accessibility output. Unknown components remain unavailable. No precise encrypted payload or closed-case `0x12` decoding is attempted; closed-case availability is not guaranteed. AirPods Max supplies only its headset level, not a case battery.
- **iPhone:** a bounded GATT connection (up to ten seconds) reads Battery Service `180F` / Battery Level `2A19`. Clocky also requires Device Information fields reporting `Apple Inc.` and an `iPhone` model before using the result. These metadata checks are not cryptographic authentication. Only the explicitly selected UUID is connected, and Clocky releases its connection interest afterward. The reading is labeled **(BLE)** in Settings. iOS/device authorization and service availability vary; newer devices may not expose these fields, in which case the reading stays unavailable. No helper installation is required for this fallback.
- **Lifecycle:** scans and connections are cancelled when BLE is disabled, selections change, monitoring pauses, or Clocky quits. BLE observations are not reused as cached percentages. Denied permission, malformed packets, missing services, and timeouts do not prevent primary readers or other devices from updating. Self-generated GATT connection events are temporarily ignored as described above.

These are reverse-engineered/experimental device paths, not guaranteed Apple battery APIs. Protocol fixtures and automated tests do not establish compatibility with your specific firmware; compare readings with your devices before relying on them.

Visibility above secure system UI, the lock screen, or exclusive full-screen apps **cannot be guaranteed**. Spaces, normal full-screen apps, Stage Manager, and multi-display behavior still require manual validation on the target macOS/hardware; automated checks are not proof of universal “always on top” behavior.
