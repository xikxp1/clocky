# Testing Clocky

## Automated checks

On macOS 13+ with Swift 5.9+:

```sh
swift test
./scripts/build-app.sh
plutil -lint build/Clocky.app/Contents/Info.plist
codesign --verify --strict --verbose=2 build/Clocky.app
./build/Clocky.app/Contents/MacOS/Clocky --smoke-test
```

Core tests exercise formatting, update scheduling, preference decoding/sanitization, and overlay geometry. App tests cover settings persistence, corrupt-data recovery, installed-font resolution and measurement, and timer demand for hidden overlays and a visible settings preview. Login-item tests use mocks only: they cover enable/disable, external status changes, approval, errors, and packaged-app/smoke-test guards without changing your actual login items. The smoke test requires a logged-in graphical session, uses a unique isolated preferences suite, checks visible/bounded/nonactivating/click-through native panels, and exits after roughly one second. Neither check proves overlay ordering across other apps, Spaces, or full-screen modes. Ad hoc signature verification does not mean notarization or distribution approval.

## Manual checklist

Run only one Clocky instance. Record macOS version, Mac model, display layout/scaling, and relevant Spaces/Stage Manager settings. Manual preference changes persist; note your original Clocky and system settings and restore them afterward. Use a test account for system-clock experiments rather than altering a working machine's clock.

- [ ] **Launch and permissions:** `open build/Clocky.app` produces the clock menu-bar item, no Dock icon, and one clock per logical display. No Accessibility or Screen Recording request appears; do not grant either permission to make the overlay work. See the [README permission note](../README.md#use).
- [ ] **Locked interaction and focus:** type continuously in another app while clocks tick. Click, double-click, drag-select, and scroll through a locked overlay; the underlying app receives input and retains keyboard focus. Switching apps must not hide the clocks or activate Clocky.
- [ ] **Explicit positioning:** choose **Move Clocks…**; drag each clock to every edge/corner. Each stays on its own display and inside its usable area, without taking keyboard focus or snapping back on a tick. Choose **Lock Positions** and confirm click-through is restored. Relaunch: positions persist, but positioning mode does not.
- [ ] **Settings focus:** **Settings…** intentionally brings its window forward. Text fields, color pickers, and sliders work; closing Settings leaves clocks visible without making them focusable. Reopening Settings works. With overlays hidden and seconds enabled, the settings preview still ticks; closing/minimizing it stops that demand.
- [ ] **Extended displays:** use two or more displays, including displays left of/below the primary and with different scaling. Change primary display, rearrange, attach/detach/reconnect, and rotate where supported. Expect one clock per logical screen, no stale duplicate panels, bounded placement, and remembered per-display positions where the display identity stays stable.
- [ ] **Mirroring:** switch extended displays to mirroring and back. Mirrored displays share the logical desktop clock rather than stacking duplicate clocks. Unmirroring restores separate clocks; validate bounds and positions on each.
- [ ] **Spaces:** create/switch desktop Spaces, use Mission Control, and switch foreground apps on each display. Repeat with “Displays have separate Spaces” both on and off if practical (the OS may require logout). Confirm clocks return visibly without focus changes or orphaned panels.
- [ ] **Normal full screen:** enter/leave native full screen in several apps (for example Safari and a video player), switch full-screen Spaces, and repeat on an external display. Confirm visibility and focus behavior; record app/OS-specific failures rather than assuming all full-screen modes behave alike.
- [ ] **Stage Manager:** enable it, change groups, show the desktop, move windows between displays, and disable it. Check that clocks remain available, do not become ordinary staged windows, and do not take focus.
- [ ] **Sleep/wake:** sleep/wake displays and the Mac, including an external-display reconnect. Clocks should show current time promptly, without duplicates or frozen updates. Lock/unlock may hide overlays while locked; check recovery after unlocking, not visibility over the lock screen.
- [ ] **Time and locale:** test System, 12-hour, and 24-hour formats with seconds on/off. Check leading zeros, AM/PM, minute rollover, and (when practical) noon/midnight. Change system locale/12–24-hour preference and time zone; System mode should follow system formatting while explicit modes keep their hour cycle. In a test account, change wall-clock time and restore automatic time; expect prompt resynchronization rather than accumulated drift.
- [ ] **Resizing and notches:** test minimum/maximum text size, seconds toggles, longer 12-hour strings, all corners, and display scaling changes. Text should not clip and panels should remain bounded. On a notched Mac, test menu-bar auto-hide and Dock auto-hide/placement, including full screen; the clock must avoid the notch and usable-area edges.
- [ ] **Fonts:** select different installed families and faces, including bold/italic and proportional/monospaced fonts. Verify the preview and every overlay match, remain bounded, and do not clip at 14 and 96 pt. Relaunch to confirm font and face persist. Choose System Default to restore the original appearance. If a saved custom font is disabled/removed, expect a system-font fallback and an explanatory Settings message, not a crash or lost selection. Restore the font afterward. Resize Settings and confirm all controls remain accessible by scrolling.
- [ ] **Preferences:** change text/background colors and opacity (including 0% and 100%), size, time format, seconds, visibility, and positions. Quit/relaunch the same app form and confirm persistence. **Reset Positions** restores top-right positions on all displays without changing appearance. Development and bundled app preferences may be separate.
- [ ] **Menu tracking:** enable seconds and keep Clocky's menu open for several seconds. Overlays must continue updating during menu tracking, not catch up only after it closes.
- [ ] **Menu hide/show:** uncheck **Show Clocks**, verify all overlays disappear but the menu-bar item remains; re-enable and verify current time and saved positions. Hide while moving, show again, and confirm clocks are locked. **Move Clocks…** while hidden should show them in positioning mode. Confirm Settings visibility and menu checkmark agree.
- [ ] **Start at Login (explicit opt-in test):** use the packaged signed app in a stable location; merely opening Settings must not register it. Enable Start at Login and check macOS Login Items. If approval is needed, confirm the pending message and use Manage Login Items to approve it. Quit/relaunch and confirm the toggle reflects system status. Change the registration in System Settings, then return to Clocky and check that it refreshes. Disable the toggle (including while approval is pending) and verify registration is removed without quitting Clocky. With your consent, log out/in to test actual automatic launch. Restore your original login-item setting afterward. Direct `swift run` and `--smoke-test` must not allow registration. Registration errors must appear inline, with the toggle reflecting actual system status.
- [ ] **Exit:** **Quit Clocky** removes overlays and the menu-bar item. No background Clocky process remains. Quitting does not register or unregister the app; an explicitly enabled Start at Login choice remains in effect.

## Limits and reporting

Secure system surfaces, lock screens, screen savers, and some exclusive full-screen apps may cover Clocky. Do not treat visibility above them as a supported guarantee or raise the overlay to secure-system window levels to compensate. Record failures with reproduction steps and display/Spaces configuration. Complete the applicable manual checks on target hardware before claiming support; a passing build, unit suite, or smoke test alone is insufficient.
