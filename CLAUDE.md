# LogoLight: notes for picking up work

A macOS menu bar app that controls the illuminated Apple logo on the back of the MacBook Pro
with PROLED XDR Display: on/off, fades, effects. Start with `README.md` (features, how it
works, project layout). Then read `docs/corebrightnessd.md`, which has everything known about
the private interface the app uses, and `tools/probes/README.md` for the tools that found it.

## Build and test

```sh
make test      # swift run LogoLightTests (a plain executable, see below)
make app       # build/LogoLight.app, ad-hoc signed, hardened runtime
make install   # copy to /Applications, (re)launch
```

- **Command Line Tools only, no Xcode.** XCTest and swift-testing aren't available, so the tests
  are an executable target with a tiny harness (`Sources/LogoLightTests/Harness.swift`). Add new
  suites to `Sources/LogoLightTests/main.swift`.
- Swift 6 language mode with strict concurrency. Everything UI- and hardware-facing is
  `@MainActor`, and Timer and notification closures use `MainActor.assumeIsolated`.
- The app bundle is assembled by `scripts/build-app.sh` (there's no Xcode project).
  `Resources/Info.plist` is a template with `LSUIElement` (no Dock icon).

## Which Mac

Only the **MacBook Pro with PROLED XDR Display** has the logo. On any other Mac (e.g. the
Mac mini) everything builds, the tests pass (the one live-hardware test skips), and the app
runs but says the logo isn't available. So:

- Logic changes can be made and tested anywhere. The fakes in
  `Sources/LogoLightTests/ControllerTests.swift` (`SimulatedMac`, `FakeDaemon`, which logs every
  key it's sent, and `FakeClock`) model the real hardware's behaviour. Use
  `Fixture(timeDriven: true)` for new tests: the fake's fades then move as the code sleeps, along
  the measured curve in the daemon's 17.5 ms frames, so landings and overshoots look like the
  real logo's. Its timing is exact, though, and the real one isn't: a 10 ms sleep runs about 2 ms
  late, and frames come 12–19 ms apart. So timing-sensitive tests also run under the `Timing`
  variations in `FadeTests.swift` (polls up to 15 ms late, frames 12–19 ms apart); a landing that
  counted its sleeps instead of reading the clock passed with exact timing and bounced with late
  polls. The full suite takes about 20 s. `LightEmitter` takes the clock (the fake's `daemon.time` in tests). The fake can trace
  the level every millisecond, and `FakeClock.returnsWhenCancelledLate`
  makes a sleep that's cancelled once its time is up return normally, as `Task.sleep` does. (The older
  tests move a fade a step per read instead.)
- Anything that changes what the LED does must be checked on the MacBook before it's called
  done, with `tools/livecheck`. Say so explicitly if it wasn't.
- To see the panel anywhere, without touching the logo or the screen, draw it to PNGs in each
  state from a debug build: `LOGOLIGHT_RENDER_PANEL=/some/folder .build/debug/LogoLight`. It
  prints any label that doesn't fit, so check its output after changing the layout.
  The switches are `LogoSwitch`, drawn by the app: AppKit's `NSSwitch` draws grey inside a menu until
  the menu's window becomes key, a moment after it opens, which looked slow. What the panel shows
  and greys out is worked out in `PanelState` (LogoLightCore), which has tests.
  `LOGOLIGHT_OPEN_MENU=1 .build/debug/LogoLight` opens the real menu. Quit LogoLight first, and
  don't use it while the user is working: it interrupts them, and the menu won't stay open.

## Rules learned the hard way

- **Never let a failed build reach the hardware.** Chain build-and-run with `&&`, not `;`, and
  don't pipe the build (`swift build | tail && run` tests `tail`, not the build). Send its output
  to a file instead. This has gone wrong twice: a stale binary ran against the real logo.
- Writing to `corebrightnessd` changes the real logo immediately, for every user. Quit LogoLight
  before experimenting (its effects fight you), and restore normal lighting afterwards (the
  command is in `tools/probes/README.md`).
- Writing `DisplayLogicalState` with the value it already has is ignored. Release a held level
  with a state *change*.
- `DisplayLogicalState` moves the keyboard backlight as well as the logo, and reading it back gives
  the last value sent to anything. So `LightEmitter.setLit` corrects the keyboard after every Blank
  and remembers the logo's direction itself; when that isn't known (at launch, after a sleep or
  wake) it's `nil`, never read back, and the code writes both states at the hold duration. Check
  side effects with `tools/probes/ledsample`, and check logic with `tools/livecheck`: the unit
  tests missed the read-back problem until the fake was taught it.
- The `bklb-backlight-enabled` NVRAM variable is stale. Read the setting from
  `corebrightnessd`, or from the LED while the display is awake.
- The admin dialog (`do shell script … with administrator privileges`) asks for the password
  **every** time on macOS 27; there's no grace period. That's why direct control and the
  optional sudoers rule exist.

## Git

- Remote: `https://github.com/Ark0N/LogoLight` (**private**). Work on `main` unless asked
  otherwise, commit in small logical steps, and push when a piece of work is done.
- Commit messages: a short imperative subject, then a body that explains *why*. Use the same
  author as the existing commits (`git log -1 --format='%an <%ae>'`), set repo-locally with
  `git config user.name` and `git config user.email` if the new machine differs.

## Signing and distribution

- `make app` signs ad-hoc with the hardened runtime. For a release, on a Mac with a Developer ID
  certificate:
  ```sh
  xcrun notarytool store-credentials logolight --apple-id … --team-id …   # once
  SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" NOTARY_PROFILE=logolight make dist
  ```
  This builds, signs with a timestamp, notarizes, staples and zips into `dist/`.
  `scripts/notarize.sh` has the details. It hasn't been run with a real identity yet;
  the MacBook it was written on has no signing certificate.
- **The Mac App Store isn't an option** as the app stands. It relies on private API
  (`CoreBrightness`, App Review guideline 2.5.1), and Mac App Store apps must be sandboxed. The
  fallback path runs `defaults` as root through an admin dialog and can install a sudoers rule,
  neither of which is possible in the sandbox. Distribute it directly instead (Developer ID +
  notarization, e.g. GitHub Releases).
- The direct-control path was verified working with the hardened runtime (ad-hoc), with no
  entitlements needed.

## Open decisions (the user's call)

- **Bundle ID**: still the placeholder `io.github.logolight.LogoLight` (`BUNDLE_ID` in
  `scripts/build-app.sh`). Pick the real one before the first signed release; changing it later
  resets the saved preferences and the Launch at Login registration.
- **License**: none yet. That's fine while the repo is private.

## Status

See `git log` for history. Done and verified on the MacBook:
- On/off without a password, with fades.
- Effects (Breathe, Pulse, Heartbeat).
- Brightness, including effects peaking at it and turning on at it (`tools/livecheck`).
- Launch at Login.
- The documented-command fallback with the admin dialog, plus the optional sudoers rule.
- The `make install` flow.

The menu's control panel (`Sources/LogoLight/ControlPanel.swift`) was asked for as "nice sliders
so it looks like an iOS app, keep it simple", then specified: "one slider for turn logo off, then
the other sliders get greyed out, when its on then the other sliders are for the different
effects". So "slider" meant iOS-style switches: one for the logo and one per effect (at most one
on), all greyed out while the logo is off, keeping their state. The Brightness slider is the one
real slider, and greys out with them (one 0.22 s fade of their rows, as soon as the switch is
flipped, not when the logo's fade ends). The user then asked for the whole menu to be "much more
narrower", then "a little bit more narrow" and "remove the about logolight option"
and "the Q shortcut it terrible off to the right side". The menu has no About item and no ⌘Q,
whose shortcut column alone would make it 190 points wide. At their request the panel is 170
wide, measured:
- The widest row is Heartbeat's: the text column starts at 40, the label needs 61 (13 pt; 64 with
  Bold Text), then at least 4, the switch 40 and 8 to the card's edge (the tiles' inset), so 153
  (156); plus the 6-point margins, 165 (168). "Backlight" (the user renamed "Apple Logo") needs
  56.5, Breathe 47.5, Pulse 33. The renderer reports no truncated label.
- The menu's own items need 143 ("Launch at Login", "Quit LogoLight"), or 153 with
  "Disable Password", so the panel sets the menu's width.
- The switches are 40 × 24 with a round knob 20 across, about an iOS switch's proportions: the
  user chose them over a regular `NSSwitch`'s size on macOS 27 (54 × 24 with a 32 × 20 capsule
  knob, which would need a 179-point panel).

The live view at the top is drawn as the lid of this MacBook Pro in its real proportions and
its own finish, space black or silver (`MacFinish`, read from the device tree's `housing-color` and
Launch Services' device types). They also asked for a live view "so fully synced up": `LogoPreview` shows
`LogoController.liveGlow`, read from the hardware on each frame (a display link, at 60 Hz) while
the menu is open. With the menu closed, only a 10 s refresh runs, which keeps the menu bar icon in
step with changes made elsewhere (every second while the menu is open).

The user also reported "the keyboard is glowing at the same time". The fix keeps the keyboard
steady, on the assumption that this was unwanted; they weren't asked. If they like it, it could
become an option.

Seen working in the real menu: the effect switches and the slider (the user's saved settings
changed).

**Checked on the MacBook with `tools/livecheck`** (2026-11-07, build 87; not yet watched by eye):
- A level in between is eased onto with a few short fades instead of a fade cut short at
  speed (docs/corebrightnessd.md, "Easing onto a level"): the slider, turning on at a brightness,
  a wake or launch, and effect peaks, whose hold is shortened to make up for it. Five slider
  clicks each took 0.35–0.42 s, slowed to 7–19% of their top speed in the last 60 ms, went back
  0.000 and ended within 0.002 of the level. The keyboard's duty dipped by 0.02–0.03 from about
  0.15 during each; whether that shows is for the eye.
- A drag ends at its level; a relaunch after a level held going up goes straight to the saved
  level with no bump; turning on with Pulse chosen rises steadily from dark; a wake handled
  through `scheduleWake` keeps the level; Pulse, Heartbeat and Breathe peak at the brightness
  (Heartbeat 0.007 above it).

**Changed since the last look by eye** (watch the logo):
- The landings above: that each slows to a stop and the keyboard doesn't visibly dim.
- The time a peak's easing takes is taken from the holds after it, so effects keep their cycle
  length; Heartbeat's rest gets shorter by about 0.26 s at brightness 0.5, since its holds after
  the beats are too short. Ask the user whether that rhythm looks right, or whether its beats
  should stay sharp instead.
- Effects have longer rises than falls (starting values in `LogoEffect.cycle`, to tune by eye),
  and turning on with an effect starts it with a rise from dark instead of a separate fade in.
- Nudging the slider at the top and back should end at normal full brightness (livecheck only
  goes back to 1 from a level in between). A followed target missed by more than 0.02 gets a
  new fade, and a fade cancelled as its sleep returns writes nothing more.
- Choosing None, a wake and launch fade over 0.8 s instead of 0.25 s. Sleeps have a 2 ms
  tolerance, and App Nap is held off while animating.
- Without direct control, the first admin dialog also installs the sudoers rule, in one script
  (the install, quietly, then the command), and says so in its prompt; the user asked for the
  password to be needed only once, by default. The menu item is now **Disable Password**.
  Unchecking it sets the app's `KeepsPassword` default, so the rule isn't installed again. To try
  it on the MacBook, the controller has to be given no emitter, since corebrightnessd normally
  takes every change.

**Changed since the last look at the real menu** (drawn offscreen only; open the menu with
`LOGOLIGHT_OPEN_MENU` when the user isn't working):
- The switches' knob can also be dragged. Check that they're blue on the very first frame, and
  that a drag works inside the menu.
- The menu opens on mouse-down. Check a quick click, press-drag-release onto an item, and that
  Option-click toggles the logo without the menu flashing.
- After a flip, the switch stays usable and the rows grey out or come back at once. Flip
  quickly back and forth during a fade: only the last flip should be applied after it, and
  on-off-on shouldn't blink the logo (`tools/livecheck` can't flip the panel's switch).
- A password dialog or an error alert closes the menu first, including when corebrightnessd
  rejects a direct switch and it falls back to the dialog (`willPromptForPassword`). Without
  direct control, a flip that `sudo` makes (the rule is installed) leaves the menu open, with the
  switch disabled until it's done.
- `pkill LogoLight` now quits cleanly (the logo returns to normal), and the make targets wait
  for it to exit before opening the new build. One that's blocked (a password dialog is open)
  can't take the signal until it's answered, so after 2 s they kill it instead (checked with a
  stand-in process only).
- Closing the lid with an external display attached pauses an effect, and opening it resumes
  it; connecting an external display with the lid open changes nothing, also after a sleep and
  wake during which a display was unplugged.

**Not yet verified:**
- The live view animating in the real menu, now driven by a display link at 60 Hz. It has only
  been seen drawn offscreen, and `liveGlow` was checked through `tools/livecheck`.
- A real display sleep and wake (not just calling the handlers): with a held brightness, the
  logo should come back at that level, and the keyboard should go dark and relight.
- The `DisplaySelect` route in `docs/corebrightnessd.md`, which might replace holding a fade with a
  real brightness control. Worth trying if the hold causes trouble.
