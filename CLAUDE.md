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
  the measured curve, so landings, overshoots and timing look like the real logo's. (The older
  tests move a fade a step per read instead.)
- Anything that changes what the LED does must be checked on the MacBook before it's called
  done, with `tools/livecheck`. Say so explicitly if it wasn't.
- To see the panel anywhere, without touching the logo or the screen, draw it to PNGs in each
  state from a debug build: `LOGOLIGHT_RENDER_PANEL=/some/folder .build/debug/LogoLight`.
  The switches are `LogoSwitch`, drawn by the app: AppKit's `NSSwitch` draws grey inside a menu until
  the menu's window becomes key, a moment after it opens, which looked slow.
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
real slider, and greys out with them. The user then asked for the whole menu to be "much more
narrower", then "a little bit more narrow" and "remove the about logolight option"
and "the Q shortcut it terrible off to the right side". It's 180 points wide, the least the
"Apple Logo" row allows; the menu has no About item and no ⌘Q, whose shortcut column alone would make
it 190. They also asked for a live view "so fully synced up": `LogoPreview` shows
`LogoController.liveGlow`, read from the hardware 30 times a second while the menu is open. The
menu bar icon doesn't animate, so nothing polls while the menu is closed.

The user also reported "the keyboard is glowing at the same time". The fix keeps the keyboard
steady, on the assumption that this was unwanted; they weren't asked. If they like it, it could
become an option.

Seen working in the real menu: the effect switches and the slider (the user's saved settings
changed).

**Changed since the last check on the MacBook** (logic tested with the time-driven fake only;
run `tools/livecheck` and watch the logo):
- The slider's fade now follows a drag instead of restarting at each step.
- Effects have longer rises than falls (starting values in `LogoEffect.cycle`, to tune by eye),
  and turning on with an effect starts it with a rise from dark instead of a separate fade in.
- Choosing None, a wake and launch fade over 0.8 s instead of 0.25 s. Launch
  (`LogoController.start`) goes straight to a saved level instead of relighting to full first.
- Sleeps have a 2 ms tolerance, and App Nap is held off while animating.

**Not yet verified:**
- The live view animating in the real menu. It has only been seen drawn offscreen, and
  `liveGlow` was checked through `tools/livecheck`.
- A real display sleep and wake (not just calling the handlers): with a held brightness, the
  logo should come back at that level, and the keyboard should go dark and relight.
- The `DisplaySelect` route in `docs/corebrightnessd.md`, which might replace holding a fade with a
  real brightness control. Worth trying if the hold causes trouble.
