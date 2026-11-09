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

- **The app builds with the Command Line Tools alone.** XCTest and swift-testing aren't available
  there, so the tests are an executable target with a tiny harness
  (`Sources/LogoLightTests/Harness.swift`). Add new suites to `Sources/LogoLightTests/main.swift`.
  Only the Control Center control (`Controls/`) needs Xcode 26+ (this MacBook has Xcode 27.2):
  `build-app.sh` builds it with `swiftc` and Xcode's `appintentsmetadataprocessor`, the way Xcode
  builds a widget extension, and leaves it out when that tool or the macOS 26 SDK is missing.
- Swift 6 language mode with strict concurrency. Everything UI- and hardware-facing is
  `@MainActor`, and Timer and notification closures use `MainActor.assumeIsolated`.
- The app bundle is assembled by `scripts/build-app.sh` (there's no Xcode project).
  `Resources/Info.plist` is a template with `LSUIElement` (no Dock icon).
- The Control Center control (Backlight, a toggle) is an extension. It's sandboxed (the system
  ignores extensions that aren't), and reaches the running app through `ControlLink` (a Mach port
  named `<bundle ID>.control`, the one name its entitlements let it look up); only the app touches
  the logo. `ControlLink.swift` is compiled into both, so it mustn't use the rest of LogoLightCore.
  WidgetKit gives apps no slider, only toggles and buttons. The user asked for a brightness slider
  there; Brighter/Dimmer buttons and a button opening the menu's slider were tried, and the user
  had them removed ("these buttons doesn't make much sense"). A debug build run from `.build` has no
  bundle ID and serves no port.

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

- Remote: `https://github.com/Ark0N/LogoLight` (**public** since 2026-11-07, MIT). Work on `main`
  unless asked otherwise, commit in small logical steps, and push when a piece of work is done.
  Releases are tagged (`v1.0.0` is commit 76c389a, build 105; `v1.1.0` is 8b7d3b4, build 134; `v1.1.1` is e41948d, build 138) and published as GitHub Releases
  with the notarized zip (`gh release create vX.Y.Z dist/LogoLight-X.Y.Z.zip`). `v1.2.0` is e6960d1,
  build 144.
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
  `scripts/notarize.sh` has the details. This MacBook has the Developer ID identity (team
  CGMJ6YKL5G) and the `logolight` notarytool profile. First run 2026-11-07 (1.0.0, build 94):
  Accepted, "Ready for distribution", no issues, stapled; `spctl` says Notarized Developer ID.
  The zip goes to `site/public/LogoLight.zip` (not in git) for the website's download.
  **1.0.0 shipped 2026-11-07**: build 105 (commit 76c389a, tag `v1.0.0`), notarized with no
  issues, on https://logolight.app and as a GitHub Release. **1.1.0 shipped 2026-11-08**: build
  134 (commit 8b7d3b4, tag `v1.1.0`), with the battery indicator and Morse code (PRs #1-#3; Lit
  with Lid Closed is in it but out of the menu), notarized with no issues; the user tried it first.
  The README's banner and menu GIF and the site's menu pictures were drawn again for it
  (`make-media.swift`, `make-banner.swift`, and the site's from `LOGOLIGHT_RENDER_PANEL` at scale 5,
  transparent: no effect for on and off, Breathe at 0.9 with the glow at 0 for the hero). The site's
  `og.jpg` then still showed the 1.0 menu (since 1.2.0 it's the banner, as `og-120.jpg`). **1.1.1 shipped the same
  day**: build 138 (commit e41948d, tag `v1.1.1`), Lit with Lid Closed back in the menu with
  "External display only" under it, notarized with no issues; the hero's HTML menu has the item.
  **1.2.0 shipped 2026-11-09**: build 144 (commit e6960d1, tag `v1.2.0`), the Sound effect (PR #4),
  notarized with no issues, on the site (a Sound feature tile, no change to the hero's demo, which
  is CSS animation) and as a GitHub Release. The user tried the branch build first and asked for a
  snappier rise and fall, which went in before the release. The README's banner and menu GIFs
  and the site's menu pictures were drawn again with the Sound row (the panel is now 450 points
  tall, so the site's menu pictures are 850 × 2250 and `.screen` is 626 points); the taglines say
  "or glow with your music". The site's pictures are cached for a day under their names (`_headers`),
  so redrawn ones get a new name: `menu-*-120.png` and `og-120.jpg` (the banner at 1200 × 630,
  `sips -z 630 1200 docs/banner.jpg`). The user saw the old pictures until that was done.
- The website deploys with `cd site && npx wrangler deploy` (wrangler is logged in with the
  user's Cloudflare account; the Worker "logolight" serves logolight.app and www). For a new
  version: bump `VERSION`, `make dist`, copy the zip to `site/public/LogoLight.zip`, update the
  version and date in the site's JSON-LD (`index.html`) and `llms.txt` and the sitemap's
  `lastmod`, deploy, tag, `gh release create`, then ping IndexNow (below).
- SEO and AI search: `robots.txt` welcomes every crawler and lists `sitemap.xml`; `llms.txt` is a
  plain-text summary for AI assistants; `index.html` has JSON-LD (the app, and the FAQ, which must
  match the page's). ChatGPT's search leans on Bing's index, so after a deploy that changes the
  page, tell Bing and the other IndexNow engines (the key file is
  `site/public/5ac2b92d275422183e47b25b5e0e0a4d.txt`):
  `curl "https://api.indexnow.org/indexnow?url=https://logolight.app/&key=5ac2b92d275422183e47b25b5e0e0a4d"`.
- `scripts/make-media.swift` makes the README's GIFs (`docs/media/`) and videos (`site/media/`,
  not uploaded: Safari needs Range requests for `<video>`, which static assets don't answer)
  from the live view's renders, with the effects' real timing. Re-run it after tuning effects.
- **The Mac App Store isn't an option** as the app stands. It relies on private API
  (`CoreBrightness`, App Review guideline 2.5.1), and Mac App Store apps must be sandboxed. The
  fallback path runs `defaults` as root through an admin dialog and can install a sudoers rule,
  neither of which is possible in the sandbox. Distribute it directly instead (Developer ID +
  notarization, e.g. GitHub Releases).
- The direct-control path was verified working with the hardened runtime (ad-hoc), with no
  entitlements needed.

## Decisions (the user's call)

- **Bundle ID**: `app.logolight.LogoLight`, after the user's domain, logolight.app (chosen
  2026-11-07, replacing the placeholder `io.github.logolight.LogoLight`; the user's settings were
  copied over with `defaults export`/`import`). Don't change it after the first release: that
  resets the saved preferences and Launch at Login, and orphans placed Control Center controls.
- **License**: MIT (chosen 2026-11-07); the repo went public with the 1.0.0 release. The website is
  in `site/` (Cloudflare Workers static assets, `logolight.app`). Donations go to
  buymeacoffee.com/arkon and never state an amount (the user's rule). On the site, the Apple
  logo appears only inside LogoLight's own renders (the user's choice, given Apple's trademark
  rules).

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

The panel's order is the user's: the Backlight switch first ("so its much easier to enable,
disable it"), then the live view, then the brightness slider (its own card), then the effects.
The live view is drawn as the lid of this MacBook Pro in its real proportions and
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

**The Control Center control** (2026-11-07, build 88): built, registered (`pluginkit -mAvvv -p
com.apple.widgetkit-extension` lists `app.logolight.LogoLight.Controls`), and its port checked
against the installed app with a small client built from `ControlLink.swift`: state, off and on
were answered in 2-3 ms, and the logo followed. A sandboxed test client could look the port up
with the entitlement and couldn't without it. Not yet seen by the user: the control in Control
Center's Edit Controls (under LogoLight, "Backlight"), a tap, and the control following the
menu's switch. Update: the user placed Backlight and tapped it; the log shows
`SetBacklightIntent.perform()` running in the extension and the logo turned off. After review: sends are serialized in
the extension (CF shares one remote port per name, and an invalidate lost other callers'
answers), a request that reached the app but wasn't answered isn't sent again (the app may be
showing the password dialog), a request for the state the switch already shows does nothing
(it used to fade the logo out and in), and a tap the fallback path drops while busy fails as "busy".
The app has an icon (`scripts/make-icon.swift`, also put in an asset catalog by `build-app.sh`
when Xcode's actool is there). It has no Apple logo, which Apple doesn't allow in icons. On the
user's Mac, Control Center's gallery kept showing the generic app icon (a grey grid on macOS 26+)
that macOS drew while the app had none: restarting ControlCenter and chronod, re-registering,
new versions, the real SDK and a reboot didn't help. A copy under a fresh bundle ID showed the
icon at once, so new installs are fine. What fixed it was clearing the system icon cache
(`sudo rm -rf /Library/Caches/com.apple.iconservices.store`, then restart), done by the user.
Gallery entries also stuck: chronod only adds or updates a control's kinds, so removed controls
stayed listed until the extension was unregistered (`pluginkit -r`, `lsregister -u`) and
registered again. chronod logs "purging instead because we shouldn't cache it ... isApple? false"
for this extension, as it did for every ad-hoc and Developer ID probe; that may only mean it
fetches the control's description when the gallery is opened.

**The battery indicator** (asked for on Reddit: "if its bright you have a full battery and it slowly
dims as your battery runs out"): a Battery switch under the brightness slider, in its card. While
it's on, the brightness is the battery's charge (100% is normal brightness, handed back to the
system), the slider greys out and shows it, and effects peak at it. The slider's own value is kept
(`LogoController.chosenBrightness`, saved as before) for when it's turned off; the switch is saved
as `FollowsBattery`. The charge comes from IOKit's power sources (`Battery.charge()`), re-read on
`kIOPSNotifyAnyPowerSource` (public; it fires about once a minute here, the percent-only one is
private), on a wake, and at launch, and only while the switch is on. A charge change is eased onto
like a slider click. Checked with `tools/livecheck` (2026-11-08, a stand-in charge stepped 70% →
69% → 40%, Pulse at 40%, off, 100%): every landing within 0.002, smooth, no bounce. Not yet seen
in the real menu, or followed through a real discharge.

**Lit with Lid Closed** (2026-11-08, asked for on Reddit): a menu item, off by default and saved as
`LightsWithLidClosed`, with a second line, "External display only" (`NSMenuItem.subtitle`, macOS
14.4+; 163 points at most, and `NSMenu` measured the menu still 170 wide). The user closed the lid
without an external display, where the Mac sleeps and the logo goes dark with it, and took that
for the option not working; it was out of the menu (1.1.0 shipped without it) until the user asked
for it back, explained in short words that don't widen the menu. With the lid closed and an external display, the logo is told the lid is
open and the keyboard that it's closed (docs/corebrightnessd.md, "The lid"). The app handles the
built-in display going away as a sleep, then a wake a second later, once `CBClamshellState`
shows the daemon has handled the lid; with the option off, that wake darkens a held level, which
the daemon alone left lit (it did before this, too). "Lit with Lid Closed" needs 158 points, so
the menu stays 170 wide. Checked on the MacBook with `tools/livecheck --lid`, the lid really
closed (second run, all ok): with the option off the held logo went dark; with it on it
relit at 0.5, two landings eased on (11% and 10% of top speed at the stop, no bounce), Pulse kept
its cycle (2.16–2.17 s), Heartbeat, off and on, the option off and on, a quit (dark) and a
relaunch (lit) all worked, and the keyboard stayed at 0 throughout and relit when the lid opened.
Not yet seen: the menu item in the real menu, the app's own screen-change handling (livecheck
calls the same controller methods), the logo by eye, and whether the external display changes
when the logo is lit this way.

**Morse code** (PR #1 from johnseth97, 2026-11-07, built on a Mac without the logo; merged
2026-11-08): `MorseCode` (LogoLightCore) turns a message into
`FadeStep`s with standard timing (dot 1 unit, dash 3, gaps 1/3/7, unit 0.2 s = 6 wpm), and
`LogoAnimator.startMorse` plays them once or in a loop, in place of the effect, which comes back
afterwards. Morse always flashes at full brightness: easing onto a level in between takes ≥ 0.15 s
(`land`), which would smear dots. Edges are 0.04 s fades. Tests (`MorseTests.swift`) measure the
flashes in the fake's 1 ms trace. Choosing an effect stops a message; turning the logo off or a
display sleep drops a message sent once and pauses a loop. The panel has a MORSE CODE card: a field,
play (`play.fill`, `stop.fill` while a message is sent) and a loop switch (`repeat`, accent-filled
when on, saved as `MorseLoops`; flipping it while a message is sent changes whether it carries on
after this pass, without restarting it). Loop was first a second play button that looped at once;
the user pressed loop and then play, as in a music player, and play (once) replaced the loop
after one pass, so it's a switch now (2026-11-08). On the MacBook
(`tools/livecheck --morse`, 2026-11-08) the first run cut dots short, one to 34 ms: a rise from
dark waits for corebrightnessd's display-ready gate (a frame from the display), 0–0.17 s with an
idle screen, and the flash was timed from the write. Morse now times each flash from when the logo
starts to rise (`timedFade(… waitingForRise:)`) and keeps every hold, so a held-back rise only
lengthens the gap before it; the fake can hold rises back (`FakeDaemon.riseDelay`). Two runs since:
flashes within 0.017 s of their length, gaps inside a letter 1.05–1.62 units and between letters
3.05–3.29, the keyboard's duty down by at most 0.007. A later run, with nothing changing on screen,
had rises held back the full 0.5 s, so the app now has the display show a frame at each rise from
dark (`onRiseFromDark`: the menu bar icon's opacity goes between 1 and 0.99, which can't be
seen); with that, a looping SOS's gaps stayed within 0.17 units of their length. Effects get it
too. Not yet watched by eye. Typing in the field inside the open menu was checked by the PR's
author (2026-11-07, with `LOGOLIGHT_SIMULATE=1`) and works.
`LOGOLIGHT_SIMULATE=1` (debug) runs the app against `SimulatedEmitterService`, a wall-clock
stand-in for corebrightnessd, so the live view can be watched on any Mac.

**Sound** (2026-11-09, asked for as "sync up the sound that is playing with the lighting"): a
fourth effect switch, "Sound", under Heartbeat in the EFFECTS card (`LogoEffect.sound`, saved as
the effect like the others, peaking at the brightness, paused and resumed with them). The sound
comes from a Core Audio process tap on every app's output (`SystemAudioLevel`, macOS 14.2+; the
row is hidden where `SystemSound.source()` is nil), metered by `LoudnessMeter` (fast-release
envelope against a slowly falling ceiling, 24 dB range, silence below -60 dBFS), and the logo
follows it through `SoundFollower` and `LightEmitter.move`/`holdNow` (docs/corebrightnessd.md,
"Following the sound"): a rise runs until the logo catches the sound, a fall until it drops to it
or to dark, a steady level is held once. The level is `peak × loudness²`. If the tap can't start
(`SoundError`), the effect is dropped, `onSoundFailed` runs, and the app shows an alert that can
open the System Audio Recording Only pane; `Resources/Info.plist` has
`NSAudioCaptureUsageDescription`. Checked on the MacBook with `tools/livecheck --sound` (beats at
2 Hz all peaked, the keyboard didn't dim) and `--hear` (the tap heard a system sound, also from a
hardened-runtime binary with no entitlements, with no permission prompt from Terminal). Not yet
seen: the permission prompt from the app itself (and whether a denial makes the tap fail, which
the alert covers, or deliver silence, which would just leave the logo dark), the logo by eye with
real music, the Sound row in the real menu, and the cost of the 33 Hz polling on battery. The
panel renders show the row fits (no truncated label).

**Not yet verified:**
- The live view animating in the real menu, now driven by a display link at 60 Hz. It has only
  been seen drawn offscreen, and `liveGlow` was checked through `tools/livecheck`.
- A real display sleep and wake (not just calling the handlers): with a held brightness, the
  logo should come back at that level, and the keyboard should go dark and relight. The lid
  closing left a held level lit (docs/corebrightnessd.md, "The lid"), and a display sleep may
  too: check that the logo goes dark.
- A way to set the logo's brightness without holding a fade. The `DisplaySelect` route in
  `docs/corebrightnessd.md` turned out to be a dead end (the logo's module ignores the brightness
  keys it would route); `setProperty:withKey:andDisplay:`, which addresses one display, hasn't been
  tried, and might reach the logo without the keyboard.
