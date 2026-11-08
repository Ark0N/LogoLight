<p align="center">
  <img src="docs/banner.jpg" width="100%" alt="LogoLight: Control your glowing Apple logo. Turn it off, dim it, or let it breathe, pulse or beat like a heart. Right from the menu bar. Free, open source, for the MacBook Pro with PROLED XDR Display. Beside the text, LogoLight's live view shows a large lid with the Apple logo glowing, next to its menu with Backlight and Breathe switched on.">
</p>

<p align="center">
  <a href="https://github.com/Ark0N/LogoLight/releases/latest/download/LogoLight-1.1.0.zip"><img src="docs/download-button.png" height="56" alt="Download LogoLight"></a>
  &nbsp;
  <a href="https://buymeacoffee.com/arkon"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="56" alt="Buy me a coffee"></a>
</p>

<p align="center">
  <a href="https://logolight.app"><img src="https://img.shields.io/badge/website-logolight.app-1f1f24?style=flat-square" alt="Website: logolight.app"></a>
  <img src="https://img.shields.io/badge/notarized-Developer%20ID-1f1f24?style=flat-square" alt="Notarized by Apple">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-1f1f24?style=flat-square" alt="MIT license"></a>
</p>

## Features

<table>
  <tr>
    <td width="290" align="center" valign="middle">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/media/menu-breathe-dark.gif">
        <img src="docs/media/menu-breathe-light.gif" width="255" alt="LogoLight's menu with the Backlight switch on and Breathe switched on: the live view of the lid shows the Apple logo slowly glowing, fading out and glowing again, above the brightness slider, the Battery switch, the effect switches and Morse code.">
      </picture>
    </td>
    <td valign="middle">
      <b>Backlight switch</b><br>
      At the top of the menu, or Option-click the menu bar icon. The logo fades out and back in smoothly, with no password.
      <br><br>
      <b>Live view</b><br>
      Your lid as it is right now, in its own finish (space black or silver), following effects and changes made elsewhere.
      <br><br>
      <b>Brightness</b><br>
      A slider that eases the logo onto each level. It still adapts to the light around you, scaled by your setting.
      <br><br>
      <b>Effects</b><br>
      Breathe, Pulse and Heartbeat, made from the LED's own hardware fades, peaking at your brightness.
      <br><br>
      <b>Battery indicator</b><br>
      Turn on Battery and the logo shows your charge: full brightness when it's full, dimming as it runs down.
      <br><br>
      <b>Morse code</b><br>
      Type a message and press play to flash it. Turn on loop to repeat it until you stop it.
      <br><br>
      <b>Control Center</b><br>
      A Backlight control for Control Center or the menu bar (macOS 26 or later).
      <br><br>
      <b>A password once, at most</b><br>
      Usually none at all. Where macOS asks, <a href="#fallback-the-documented-command">Disable Password</a> makes it the only time.
      <br><br>
      <b>Launch at Login</b><br>
      Nothing to set up: it remembers your brightness and effect.
    </td>
  </tr>
</table>

## See it glow

<table>
  <tr>
    <td align="center"><img src="docs/media/breathe.gif" width="330" alt="LogoLight's live view of the lid: the Apple logo slowly fades out and back in (Breathe)."><br><b>Breathe</b></td>
    <td align="center"><img src="docs/media/pulse.gif" width="330" alt="LogoLight's live view of the lid: the Apple logo fades out and back in at a steady pace (Pulse)."><br><b>Pulse</b></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/media/heartbeat.gif" width="330" alt="LogoLight's live view of the lid: the Apple logo beats twice, then rests (Heartbeat)."><br><b>Heartbeat</b></td>
    <td align="center"><img src="docs/media/on-off.gif" width="330" alt="LogoLight's live view of the lid: the Apple logo fades out, stays dark, then fades back in (the Backlight switch)."><br><b>On and off</b></td>
  </tr>
</table>

<sub>Drawn by LogoLight's own live view, with the effects' real timing (<code>swift scripts/make-media.swift</code> makes them again).</sub>

## Install

1. **[Download LogoLight](https://github.com/Ark0N/LogoLight/releases/latest/download/LogoLight-1.1.0.zip)**.
   It's signed with a Developer ID and notarized by Apple.
2. Unzip it, move **LogoLight** to your Applications folder and open it. It lives in the menu bar.

Needs a MacBook Pro with PROLED XDR Display and macOS 14 or later (these Macs ship with macOS 27).
On other Macs, LogoLight opens but says the logo isn't available.

### Add it to Control Center

1. Click Control Center in the menu bar, then **Edit Controls** at the bottom.
2. Search for **LogoLight**.
3. Drag **Backlight** into Control Center, or straight into the menu bar.

<p align="center">
  <img src="docs/control-center.png" width="720" alt="Control Center with LogoLight's Backlight button at the top left. An arrow points to it: one tap turns the glowing logo on your lid on or off, shown as the lid lit and dark. A second arrow points to Edit Controls, with the steps to add it: open Control Center, click Edit Controls, search for LogoLight, drag Backlight in.">
</p>

<sub>Apple only lets apps add switches and buttons to Control Center, so the brightness slider stays in LogoLight's own menu.</sub>

## How it works

<details>
<summary><b>The details</b>: the private interface, the fades, Control Center, reading the state and the password fallback</summary>

Apple documents a single setting for the logo in
[About the illuminated Apple logo](https://support.apple.com/en-us/149248):

```sh
sudo defaults write com.apple.CoreBrightness LEBacklightMode -int 0   # turn off
sudo defaults delete com.apple.CoreBrightness LEBacklightMode         # turn back on
```

The logo is driven by `corebrightnessd`, which watches that setting. While the logo is on,
it sets the brightness automatically from the screen brightness and ambient light. The
setting applies to every user account, and also in macOS Recovery.

#### Direct control (no password)

`corebrightnessd`'s light emitter ("LE") module also accepts a few keys from any app through
CoreBrightness's `BrightnessSystemClient`, the interface Control Center uses for brightness:

| Key | What it does |
| --- | --- |
| `LEBacklightMode` | `0` off, `2` on. `corebrightnessd` (running as root) saves it to the same `LEBacklightMode` default as the command above, so it persists, and `defaults delete` still turns the logo back on. |
| `LEPWMFactorFadeDuration` | How long the logo's fade takes, in seconds. `0` restores the automatic duration. |
| `DisplayLogicalState` | `1` (Blank) fades the logo out and `2` (Unblank) fades it back in. The screen is unaffected, but the keyboard backlight follows it too (see below). |
| `LEPWMState` | Live state, e.g. `Factor` (fade position), `FinalNits`, `Lux` (read only). |

LogoLight uses these to switch the logo without a password and to fade it smoothly:
turning off fades out over a second first, and turning on starts from dark and fades in
(with an effect chosen, the effect's first rise is the fade in). The effects are loops of
the same fades. They pause when the logo is off, the display sleeps, or the built-in display
goes away (lid closed with an external display).

The keyboard backlight also listens to `DisplayLogicalState`, so right after every Blank,
LogoLight tells the keyboard alone that the display is still on, which keeps it lit. When the
display really sleeps, the keyboard goes dark as usual.

There's no key for the logo's brightness, so the slider stops a fade part way: LogoLight
watches `Factor`, and near the level it eases the logo on with a few short fades, so it slows
to a stop instead of halting at speed. Then it starts a fade the other way that's so slow it
never visibly moves. The level lasts until the next change. While the slider is dragged, the
running fade follows it rather than starting again at every step. Quitting LogoLight returns
the logo to normal brightness.

This is private API, found by inspecting CoreBrightness (the details, measurements and
the tools used are in [docs/corebrightnessd.md](docs/corebrightnessd.md) and
[tools/probes](tools/probes)). LogoLight loads it dynamically and,
if it's missing or `corebrightnessd` doesn't take a change, falls back to running Apple's
documented command as root (see below). Brightness and effects need direct control, and are
hidden without it.

#### The Control Center control

The control is a WidgetKit extension inside the app (`Controls/`). Extensions must be sandboxed,
so it can't reach `corebrightnessd` itself, and only the app may change the logo anyway, since
the app also holds the brightness and plays effects. The app serves a Mach port named after its
bundle ID (`app.logolight.LogoLight.control`), and the extension is allowed to look up just that
name. A tap asks the app to flip its switch, as Option-click does; if LogoLight isn't running, it's
opened in the background first. The app reloads the control whenever its switch changes. (Apple
only lets apps add switches and buttons to Control Center, so there's no brightness slider
there.)

#### Reading the state

The setting is read from `corebrightnessd` (`LEBacklightMode`). The logo's `bklb-backlight` PWM
device in the I/O Registry shows whether the LED is lit, and how brightly:

```sh
ioreg -r -n bklb-backlight@0 | grep -E '"(enabled|high-period|low-period)"'
```

`high-period / (high-period + low-period)` is the LED's current output level. (The menu doesn't
show it: the live view uses the fade level instead, which is on the slider's scale.) Without
direct control, LogoLight reads the setting from `enabled` while the screen is on. It doesn't
rely on the `bklb-backlight-enabled` NVRAM variable, which `corebrightnessd` only reads at
startup and which isn't updated as soon as the setting changes.

#### Fallback: the documented command

If direct control isn't available, LogoLight runs the documented command as root, which
needs your password in the standard macOS administrator dialog. You only enter it once: the
first time, the dialog says it will also turn on **Disable Password** (a menu item that's only
shown in this case, or if it's already on), and together with the change it installs this
sudoers rule to `/etc/sudoers.d/logolight`:

```
lee ALL = (root) NOPASSWD: /usr/bin/defaults write com.apple.CoreBrightness LEBacklightMode -int 0, /usr/bin/defaults delete com.apple.CoreBrightness LEBacklightMode
```

It allows only those two exact commands, for your user only. The rule is checked with
`visudo` before it's installed (owned by root, mode `0440`), so a bad rule can't break
`sudo`. After that, the logo switches without a password. If the rule can't be installed, or
`sudo` doesn't honor it, the dialog comes back as before, and stops offering the rule while
LogoLight is running.

Uncheck **Disable Password** to remove the rule and be asked every time. LogoLight remembers
that and doesn't install the rule again until you check the item again. (Deleting the file
yourself, `sudo rm /etc/sudoers.d/logolight`, also removes it, but then the next password
installs it again.)

</details>

## Build from source

Needs macOS 14 or later and Xcode or the Command Line Tools (`xcode-select --install`). Without
Xcode 26 or later, the app is built without the Control Center control (it needs Xcode's App
Intents tools).

```sh
make test      # run the tests
make app       # build build/LogoLight.app
make install   # copy it to /Applications and open it
```

`make run` builds and opens the app from `build/` without installing it.

No MacBook Pro with PROLED XDR Display? A debug build can simulate the logo, touching no hardware,
so the whole menu works and its live view shows what the logo would do (effects, brightness, Morse):

```sh
swift build && LOGOLIGHT_SIMULATE=1 .build/debug/LogoLight
```

The app is ad-hoc signed, with the hardened runtime. To sign it with your Developer ID,
notarize it and zip it for distribution:

```sh
xcrun notarytool store-credentials logolight --apple-id YOU@EXAMPLE.COM --team-id TEAMID   # once
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=logolight make dist
```

Other overrides for `scripts/build-app.sh`: `VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`.

LogoLight can't go on the Mac App Store: it uses private API, and the App Store requires the
App Sandbox, which rules out both direct control and the admin-command fallback.

<details>
<summary><b>Project layout</b> and tests</summary>

| Path | What's there |
| --- | --- |
| `Sources/LogoLightCore` | `LogoController`; direct control, brightness and effects (`LightEmitter`, `LogoEffect`); reading the state (I/O Registry); the documented command, the admin dialog and the sudoers rule; what the menu shows (`PanelState`) |
| `Sources/LogoLight` | The AppKit menu bar app, including the control panel (`ControlPanel.swift`) |
| `Sources/LogoLightTests` | The test suite (`swift run LogoLightTests`) |
| `Controls` | The Control Center control, an extension built by `scripts/build-app.sh` |
| `Resources/Info.plist` | App bundle metadata (template) |
| `scripts/build-app.sh` | Builds and signs `LogoLight.app` |
| `scripts/notarize.sh` | Notarizes, staples and zips a Developer ID build (`make dist`) |
| `docs/corebrightnessd.md` | Research notes: the keys, the fade curve, holding a level |
| `tools/probes` | The command-line tools used for that research |
| `tools/livecheck` | Checks brightness and effects against the real logo |
| `CLAUDE.md` | Notes for picking up work on the project |

The tests are a plain executable instead of an XCTest bundle, because XCTest and
swift-testing only ship with a full Xcode install. They cover the exact commands,
shell and AppleScript quoting, the sudoers rule (checked with the real `visudo`), the
controller and effects against a simulated Mac and a fake `corebrightnessd` that logs
every key it's sent and moves its fades along the measured curve, and a read-only check of
this Mac's real logo state.

</details>

## Uninstall

1. If **Disable Password** is checked, uncheck it first (this removes the sudoers rule).
2. Turn off **Launch at Login** if you turned it on.
3. Quit LogoLight and delete it from Applications (`make uninstall`).

The logo setting itself stays as you left it (an effect stops when the app quits). To turn
the logo back on without the app:
`sudo defaults delete com.apple.CoreBrightness LEBacklightMode`.

## Support

LogoLight is free. If you like it, you can buy me a coffee:

<a href="https://buymeacoffee.com/arkon"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" height="48" alt="Buy me a coffee"></a>

## License

MIT, see [LICENSE](LICENSE).

<sub>LogoLight is not affiliated with or endorsed by Apple Inc. Apple, the Apple logo and MacBook Pro are trademarks of Apple Inc., registered in the U.S. and other countries.</sub>
