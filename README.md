# LogoLight

A small macOS menu bar app that turns the illuminated Apple logo on the back of the
**MacBook Pro with PROLED XDR Display** on and off.

<img src="docs/menu.png" width="326" alt="The LogoLight menu: Logo Illumination: On, glowing at 18%, with Turn Logo Off, Toggle Without Password, Launch at Login, About and Quit">



- Shows whether the logo is on, and how brightly it's glowing right now
- **Turn Logo Off / On** from the menu (⌘T), or **Option-click** the icon to toggle instantly
- Optional **Toggle Without Password** so you don't have to authenticate every time
- **Launch at Login**
- No Xcode needed to build: just the Command Line Tools

## How it works

Apple documents a single setting for the logo in
[About the illuminated Apple logo](https://support.apple.com/en-us/149248):

```sh
sudo defaults write com.apple.CoreBrightness LEBacklightMode -int 0   # turn off
sudo defaults delete com.apple.CoreBrightness LEBacklightMode         # turn back on
```

LogoLight runs exactly those commands. There's no brightness control: while it's on,
macOS sets the brightness automatically from the screen brightness and ambient light.
The setting applies to every user account, and also in macOS Recovery.

**Reading the state needs no password.** `corebrightnessd` mirrors the setting into the
`bklb-backlight-enabled` NVRAM variable, and the logo's LED is driven by the
`bklb-backlight` PWM device. LogoLight reads both from the I/O Registry, so it can show
the setting and the LED's live output level (its PWM duty cycle):

```sh
nvram bklb-backlight-enabled                                        # true / false
ioreg -r -n bklb-backlight@0 | grep -E '"(enabled|high-period|low-period)"'
```

**Changing the setting needs root.** By default LogoLight asks with the standard macOS
administrator dialog. macOS then remembers the authorization for five minutes.

### Toggle Without Password

If you turn on **Toggle Without Password**, LogoLight explains what it's about to do and then,
after you enter your password once, installs this sudoers rule to `/etc/sudoers.d/logolight`:

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

The logo setting itself stays as you left it. To turn the logo back on without the app:
`sudo defaults delete com.apple.CoreBrightness LEBacklightMode`.

## Project layout

| Path | What's there |
| --- | --- |
| `Sources/LogoLightCore` | Reading the state (I/O Registry), the privileged commands, the sudoers rule, `LogoController` |
| `Sources/LogoLight` | The AppKit menu bar app |
| `Sources/LogoLightTests` | The test suite (`swift run LogoLightTests`) |
| `Resources/Info.plist` | App bundle metadata (template) |
| `scripts/build-app.sh` | Builds and signs `LogoLight.app` |

The tests are a plain executable instead of an XCTest bundle, because XCTest and
swift-testing only ship with a full Xcode install. They cover the exact commands,
shell and AppleScript quoting, the sudoers rule (checked with the real `visudo`),
the controller against a simulated Mac, and a read-only check of this Mac's real logo state.

---

LogoLight is not affiliated with or endorsed by Apple Inc.
