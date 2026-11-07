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
  key it's sent, and `FakeClock`) model the real hardware's behaviour.
- Anything that changes what the LED does must be checked on the MacBook before it's called
  done. Say so explicitly if it wasn't.

## Rules learned the hard way

- **Chain build-and-run with `&&`, never `;`.** Once, a failed build fell through to running a
  stale binary, which switched the real logo off and on.
- Writing to `corebrightnessd` changes the real logo immediately, for every user. Quit LogoLight
  before experimenting (its effects fight you), and restore normal lighting afterwards (the
  command is in `tools/probes/README.md`).
- Writing `DisplayLogicalState` with the value it already has is ignored. Release a held level
  with a state *change*.
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
- Launch at Login.
- The documented-command fallback with the admin dialog, plus the optional sudoers rule.
- The `make install` flow.

**In progress** (started on the MacBook, 2026-11-07): an iOS-style control panel at the top of
the menu, asked for as "make some nice sliders for the app so it looks like an iOS app :) keep
it simple". The plan:
- **Logo switch**: an iOS-style switch, which replaces the Turn Logo Off/On item.
- **Brightness slider**: a thick capsule like Control Center's. It holds the logo's fade
  `Factor` at a level, using the technique in "Holding a level" in `docs/corebrightnessd.md`.
  Perceptual mapping: factor = 0.02 + 0.98 × slider². Effects fade between dark and this level.
- **Effect speed slider**: scales the effect step durations, 0.5×–2×.
- **Effect picker**: a segmented control (None / Breathe / Pulse / Heartbeat), which replaces
  the Effect submenu.
- The settings persist in UserDefaults.
- Sleep and wake: reset the fade duration on sleep, and reapply the level on wake.
