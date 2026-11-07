# LogoLight

A small macOS menu bar app that turns the illuminated Apple logo on the back of the
**MacBook Pro with PROLED XDR Display** on and off.

<img src="docs/menu.png" width="345" alt="The LogoLight menu: Logo Illumination: On, glowing at 39%, with Turn Logo Off and an Effect submenu">

- Shows whether the logo is on, and how brightly it's glowing right now
- **Turn Logo Off / On** from the menu (⌘T), or **Option-click** the icon to toggle. The logo
  fades out and in smoothly, and no password is needed
- **Effects**: Breathe, Pulse and Heartbeat, using the LED's own hardware fades
- **Launch at Login**
- No Xcode needed to build: just the Command Line Tools

## How it works

Apple documents a single setting for the logo in
[About the illuminated Apple logo](https://support.apple.com/en-us/149248):

```sh
sudo defaults write com.apple.CoreBrightness LEBacklightMode -int 0   # turn off
sudo defaults delete com.apple.CoreBrightness LEBacklightMode         # turn back on
```

The logo is driven by `corebrightnessd`, which watches that setting. While the logo is on,
it sets the brightness automatically from the screen brightness and ambient light. The
setting applies to every user account, and also in macOS Recovery.

### Direct control (no password)

`corebrightnessd`'s light emitter ("LE") module also accepts a few keys from any app through
CoreBrightness's `BrightnessSystemClient`, the interface Control Center uses for brightness:

| Key | What it does |
| --- | --- |
| `LEBacklightMode` | `0` off, `2` on. `corebrightnessd` (running as root) saves it to the same `LEBacklightMode` default as the command above, so it persists, and `defaults delete` still turns the logo back on. |
| `LEPWMFactorFadeDuration` | How long the logo's fade takes, in seconds. `0` restores the automatic duration. |
| `DisplayLogicalState` | `1` (Blank) fades the logo out and `2` (Unblank) fades it back in. Only the logo follows this key; the screen is unaffected. |
| `LEPWMState` | Live state, e.g. `Factor` (fade position), `FinalNits`, `Lux` (read only). |

LogoLight uses these to switch the logo without a password and to fade it smoothly:
turning off fades out over a second first, and turning on starts from dark and fades in.
The effects are loops of the same fades. They pause when the logo is off or the display
sleeps, and normal lighting is restored when you choose **None** or quit.

This is private API, found by inspecting CoreBrightness. LogoLight loads it dynamically and,
if it's missing or `corebrightnessd` doesn't take a change, falls back to running Apple's
documented command as root (see below). Effects need direct control.

### Reading the state

The setting is read from `corebrightnessd` (`LEBacklightMode`). The menu's output level comes
from the logo's `bklb-backlight` PWM device in the I/O Registry:

```sh
ioreg -r -n bklb-backlight@0 | grep -E '"(enabled|high-period|low-period)"'
```

`high-period / (high-period + low-period)` is the LED's current output level. Without
direct control, LogoLight reads the setting from `enabled` while the screen is on. It doesn't
rely on the `bklb-backlight-enabled` NVRAM variable, which `corebrightnessd` only reads at
startup and which isn't updated as soon as the setting changes.

### Fallback: the documented command

If direct control isn't available, LogoLight runs the documented command as root, asking
for your password with the standard macOS administrator dialog each time. To avoid that, turn
on **Toggle Without Password** (only shown in this case, or if it's already on). LogoLight
explains what it's about to do and then, after you enter your password once, installs this
sudoers rule to `/etc/sudoers.d/logolight`:

```
lee ALL = (root) NOPASSWD: /usr/bin/defaults write com.apple.CoreBrightness LEBacklightMode -int 0, /usr/bin/defaults delete com.apple.CoreBrightness LEBacklightMode
```

It allows only those two exact commands, for your user only. The rule is checked with
`visudo` before it's installed (owned by root, mode `0440`), so a bad rule can't break
`sudo`. Turn the option off to remove it, or delete the file yourself:
`sudo rm /etc/sudoers.d/logolight`.

## Requirements

- A MacBook Pro with PROLED XDR Display (on other Macs the menu says the logo isn't available)
- macOS 14 or later to build and run (the PROLED models ship with macOS 27)
- Xcode or the Command Line Tools (`xcode-select --install`)

## Build and install

```sh
make test      # run the tests
make app       # build build/LogoLight.app
make install   # copy it to /Applications and open it
```

`make run` builds and opens the app from `build/` without installing it.

The app is ad-hoc signed. To sign with your Developer ID instead:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
```

Other overrides for `scripts/build-app.sh`: `VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`.

## Uninstall

1. If you turned on **Toggle Without Password**, turn it off first (this removes the sudoers rule).
2. Turn off **Launch at Login** if you turned it on.
3. Quit LogoLight and delete it from Applications (`make uninstall`).

The logo setting itself stays as you left it (an effect stops when the app quits). To turn
the logo back on without the app:
`sudo defaults delete com.apple.CoreBrightness LEBacklightMode`.

## Project layout

| Path | What's there |
| --- | --- |
| `Sources/LogoLightCore` | `LogoController`; direct control and effects (`LightEmitter`, `LogoEffect`); reading the state (I/O Registry); the documented command, the admin dialog and the sudoers rule |
| `Sources/LogoLight` | The AppKit menu bar app |
| `Sources/LogoLightTests` | The test suite (`swift run LogoLightTests`) |
| `Resources/Info.plist` | App bundle metadata (template) |
| `scripts/build-app.sh` | Builds and signs `LogoLight.app` |

The tests are a plain executable instead of an XCTest bundle, because XCTest and
swift-testing only ship with a full Xcode install. They cover the exact commands,
shell and AppleScript quoting, the sudoers rule (checked with the real `visudo`), the
controller and effects against a simulated Mac and a fake `corebrightnessd` that logs
every key it's sent, and a read-only check of this Mac's real logo state.

---

LogoLight is not affiliated with or endorsed by Apple Inc.
