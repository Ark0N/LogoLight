# How corebrightnessd drives the logo

Research notes behind LogoLight's direct control, measured on a MacBook Pro with PROLED XDR
Display running macOS 27 (Darwin 27.2), November 2026. All of it is private, undocumented
behaviour and may change with any macOS update. The tools used are in
[`tools/probes`](../tools/probes), and every table below can be re-checked with them.

## The interface

`corebrightnessd` (root) owns the logo LED. Any process can talk to it through
`BrightnessSystemClient` in `/System/Library/PrivateFrameworks/CoreBrightness.framework`,
without root, entitlements or a sandbox exception. This was checked as an ad-hoc signed,
unsandboxed app run by an admin user.

- `-copyPropertyForKey:(NSString *)key` returns `id`, **retained** (+1, a "copy" method). Use
  `takeRetainedValue()`. 6,000 reads in a row were stable, with no memory growth.
- `-setProperty:(id)value forKey:(NSString *)key` returns `BOOL`. `YES` means the message was
  delivered, not that the change was applied.

LogoLight calls both through typed IMPs (`@convention(c)`); see
`Sources/LogoLightCore/LightEmitter.swift`.

The light emitter (LE) classes are `CBLEManager`, `CBLEPWMContainer`,
`CBLEPWMControlModule`, `CBLEPWMAutoBrightnessModule`, `CBLEPWMNitsMultiplier`,
`CBLEPWMNitsRateLimiter` and `CBLEBacklightModeStore`. From the disassembly:

- `-[CBLEPWMControlModule setProperty:forKey:]` handles these keys:
  - `LEBacklightMode`, `DisplayLogicalState` and `LEPWMFactorFadeDuration`
  - `ClamshellUpdate`, `DisplayPowerStateEvent` and `LEPWMFrameInfoProvider`
  - `RampSpringProfileMass`, `RampSpringProfileStiffness`, `RampSpringProfileDamping` and
    `RampSpringProfileVelocity`. **The fade is a spring animation**; these weren't tried.
- `-[CBKeyboardBacklightContainer setPropertyInternal:forKey:]` also handles
  `DisplayLogicalState`. See "The keyboard backlight".
- `-[CBLEManager setProperty:forKey:andClient:]` handles `DisplaySelect`, comparing it with
  `DisplayTypeSiri` and `DisplayTypeIcon`, and routes `DisplayBrightness`, `DisplayNitsKey` and
  `MaxBrightness` (`clientMappedSetKey:`) to the selected LED. That looks like a client can target
  the logo and set its brightness properly, instead of holding a fade. **Not tried yet.**
- `-[CBLEPWMControlModule copyPropertyInternalForKey:]` handles `DisplayNitsKey`,
  `LEBacklightMode`, `LEPWMState` and `StatusInfo`.

## Keys

| Key | Read | Write | Notes |
| --- | --- | --- | --- |
| `LEBacklightMode` | `0`/`2` | yes | `0` off, `2` on. `1` lights the logo too, but is saved as off. The daemon saves it itself with `setBool:(mode == 2) forKey:` into root's `com.apple.CoreBrightness` defaults, the same setting as Apple's documented `sudo defaults write … LEBacklightMode -int 0`. So it persists, and `defaults delete` still turns the logo on. |
| `LEPWMFactorFadeDuration` | `nil` | yes | Seconds, used by the **next** logical-state change. `0` means automatic (about 0.3 s). Changing it during a fade doesn't affect the fade in progress. |
| `DisplayLogicalState` | yes | yes | The display state the logo follows. Writing `1` (Blank) fades the logo to dark and `2` (Unblank) fades it to fully lit. **The keyboard backlight follows it too; the screen doesn't.** Writing the state it's already in is ignored, even mid-fade or while a level is held. Reading gives the last value sent to *anything*, including a keyboard-only write, so it doesn't show the logo's state once those are in use. |
| `LEPWMState` | dict | – | Live state, see below. |
| `ClamshellUpdate` | `0` | untested | |
| `LEPWMBrightnessNitsMapping` | array | accepted, no effect seen | Screen nits → logo nits. See "Brightness mappings". |
| `LEPWMLuxToMaxNitsRestrictionMapping` | array | accepted, no effect seen | Lux → maximum logo nits. |
| `LEPWMLuxToMinNitsRestrictionMapping` | array | accepted, no effect seen | Lux → minimum logo nits. |
| `RampSpringProfile*`, `LEPWMFollowTau`, `LEPWMStartupRampDuration`, `LEPWMRestriction{Rise,Fall}Duration`, `LEContainersInfo` | `nil` | untested | Names found in the binary. |
| `StatusInfo` | dict | – | A large status dump (`tools/probes/status`). |

Enums, read from the name tables in the binary:

- `DisplayLogicalState`: 0 Unpowered, 1 Blank, 2 Unblank, 3 Dim, 4 Undim, 5 Fade, 6 Unfade.
- `DisplayPowerStateEvent`: 0 None, 1 WillWake, 2 DidWake, 3 WillSleep, 4 DidSleep, 5 WillDim, 6 DidDim.

### `LEPWMState`

An example, taken during a fade at 7 lux with the screen at about 600 nits:

```
AppliedNits = 202.7677        DisplayNits = 599.9999       Lux = 7
MaxNitsRestriction = 202.7677 MinNitsRestriction = 16.7978 PWMNitsPreRestriction = 999.9998
Factor = 0.4455301           NitsMultiplier = 1.1          FinalNits = 99.37305
ChargerState = 1
```

- `PWMNitsPreRestriction` is `DisplayNits` mapped through `LEPWMBrightnessNitsMapping`.
- `AppliedNits` is that, clamped to `[MinNitsRestriction, MaxNitsRestriction]`. Those come
  from the lux mappings, so the logo follows the screen brightness and ambient light.
- `FinalNits = AppliedNits × Factor × NitsMultiplier` (202.77 × 0.4455 × 1.1 = 99.37).
- `Factor` (0–1) is the fade position that `DisplayLogicalState` animates. It's the only
  brightness input LogoLight can control.

### Brightness mappings

The defaults on this Mac, as `[input, logo nits]` pairs:

```
LEPWMBrightnessNitsMapping           [0,0] [0.1,12.5] [16.84,12.5] [34.12,28.62] [50,45.37] [69.11,65.52] [140,150] [300,300] [600,1000] [3.4e38,1000]
LEPWMLuxToMaxNitsRestrictionMapping  [0,180] [190,1000] [3.4e38,1000]
LEPWMLuxToMinNitsRestrictionMapping  [0,12.5] [190,150] [560,300] [1350,1000] [3.4e38,1000]
```

Writing a scaled-down copy of any of them returns `YES` and reads back, but `AppliedNits`
didn't change within 5 s. Maybe it would on the next lux or screen-brightness change; that
wasn't pursued. The originals were written back. **LogoLight doesn't use these.**

## The keyboard backlight

The keyboard LED (`kbd-backlight@0`, the same kind of PWM device as the logo) reacts to
`DisplayLogicalState` too. Measured with `tools/probes/ledsample`: on Blank it fades from 14% to
off, and it stays off for as long as the state is Blank, even when the logo is held at a visible
level.

`-[BrightnessSystemClient setProperty:withKey:keyboardID:]` sends a key to one keyboard only (IDs
come from `-[KeyboardBrightnessClient copyKeyboardBacklightIDs]`). Writing Unblank to the keyboards
straight after each global Blank keeps the keyboard lit while the logo fades. Over a 50 s run of
brightness changes, all three effects and off/on, the keyboard LED stayed on in all 154 samples,
at 23–25% with one dip to 19% while the logo switched back on.

The keyboard must still go dark with the display, so LogoLight only does this while the display
is awake, and sends the keyboards Blank when the display sleeps. A real sleep hasn't been measured
yet, so it isn't known how that lines up with the daemon's own states.

## The fade curve

A fade's duration covers the whole transition from the current factor to the end (0 or 1),
wherever it starts. It's the same eased curve both ways (fast in the middle, slow at the end,
consistent with a spring). Progress, as a fraction of the way from start to end, at fractions
of the duration (2 s fade, sampled every 0.1 s):

| t / duration | 0 | .05 | .1 | .15 | .2 | .25 | .3 | .35 | .4 | .45 | .5 | .55 | .6 | .65 | .7 | .75 | .8 | .85 | .9 | .95 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| progress | 0 | .04 | .13 | .24 | .37 | .48 | .57 | .66 | .74 | .79 | .84 | .88 | .91 | .93 | .95 | .97 | .98 | .99 | .99 | 1 |

Unblanking from 0 reached 0.5 after 0.57 s of a 2 s fade. Unblanking from 0.51 over 2 s
followed the same curve, scaled to the remaining 0.49.

The table fits a critically damped spring, `p(s) = 1 - (1 + k·s)·exp(-k·s)` with `k = 6.51`
and `s` the share of the duration elapsed, to within 0.009 rms. Its top speed is at
`s = 0.154`. As far as has been measured, every fade starts from rest: a new fade doesn't
keep the speed of the one it replaces. The fake `corebrightnessd` in the tests uses this curve,
moved in the daemon's frames (see "Easing onto a level").

## Holding a level

There's no key for the logo's brightness, but the fade can be stopped at any level:

1. Start a normal fade toward the level: set the duration, then write the state that heads
   that way.
2. Poll `LEPWMState.Factor` (every 10 ms is fine) until it passes the level (or ease onto it,
   see "Easing onto a level").
3. Set `LEPWMFactorFadeDuration` to a huge value (`1e9` s is accepted) and write the
   **opposite** state. That starts a new fade from the current factor which, at that speed,
   never visibly moves. It was measured flat to 2 decimals over 2–3.5 s; at 1e9 s it would
   take decades to drift.

Leaving a held level takes a state *change* again. Writing the state the logo is already in
is ignored, so to go up from a level held in Unblank, write Blank with the huge duration
first (nothing moves), then Unblank with the real duration.

When it isn't known which state the logo is in (the state can't be read back once the
keyboard has been written to, and the daemon changes it itself when the display sleeps and
wakes), write Blank and then Unblank, both with the huge duration. Whichever is a change
starts a fade too slow to see, so nothing moves either way, and the state is then known.

A fade carries on after whatever started it stops watching it, e.g. when an effect step is
cancelled. So a level that's reached "already" still needs a hold, or that fade carries the
logo past it.

To return to normal (fully lit, automatic duration), do the same flip with a short duration
and end in Unblank. Then set the duration to `0`, so the daemon's own fades use the automatic
duration again.

Measured through `LogoController` (`tools/livecheck`), a level lands within about 0.02 of its
target. It stayed flat over 3 s, moving up or down from a held level works, and a simulated
60 Hz slider drag ended exactly on target (that was before the fade started following the
drag, which hasn't been checked on the MacBook yet). Effects peak at the level; Heartbeat's
quickest beats overshoot a little (0.30 for a level of 0.265), because polling can't stop a
very fast fade precisely. All of that was with the fade cut short at the level; LogoLight now
eases onto it instead (next section), which hasn't been through `tools/livecheck` yet.

## Easing onto a level

Cutting a fade short at a level stops the logo at speed. Measured on 2026-11-07, with LogoLight
quit and a sampler reading `Factor` and the PWM duty of `bklb-backlight` and `kbd-backlight`
every ~6 ms (known keys only, ending with the normal-lighting restore):

- **The daemon moves in frames.** `Factor` and the logo's PWM change about every 17.5 ms
  (median; p10 12.4 ms, p90 19.3 ms), so about 57 times a second, not on every read. A new fade
  first moves 18–20 ms after the state write, in both directions. Restarting a fade at 60 Hz
  mostly stalls it, since each restart costs about a frame: a 60 Hz glide up to 0.8 ended at 0.727.
- **Cut short**, with a stretched fade polled every 10 ms: 0.25 s slider moves (1 → 0.265,
  0.265 → 0.7, 0.7 → 0.3) stopped at 44–75% of the move's top speed (2.2–3.1 per second just
  before the stop). An effect-style rise from 0 to 0.265 over 3.5 s stopped at 89% of it.
- **The keyboard** rests at a duty of 0.197–0.200. One Blank and its correction (a move) dip
  it to about 0.19, 4–6 of them in quick succession to 0.168–0.173, and about 70 (a 20 Hz glide
  over 1.2 s) to 0.129, which is visible.

What LogoLight does now (`LightEmitter`), which is the hybrid that worked: the stretched fade
carries the logo until it has covered 70% of the way to the level, measuring its speed `v`.
Then it eases out, following `1 - (1 - u)²` over `L = 2·|r| / |v|` (kept between 0.15 and
1.2 s), where `r` is the distance left, so the ease starts at the fade's speed. That's done in
a fixed few segments, 4 (6 when `L` is 0.4 s or more), each `max(0.05, L / N)` long. Each segment
starts a fade (turning round first) with the duration that covers its part of the way by the
segment's end, after the start latency: `(segment − 0.018) / t(delta / D)`, with `t` the spring's
inverse (by bisection) and `D` the distance to 0 or 1. The hold ends it. Measured:

- Slider moves with 4–5 segments (0.7 → 0.3, 0.3 → 0.8, 0.8 → 0.265) stopped at 0.24–0.51 per
  second, 10–17% of the top speed, landing within 0.003, 0.022 and 0.002. The keyboard dipped
  to 0.168–0.173.
- The effect-style rise with 6 segments stopped at 0.03 per second (11%) instead of 0.14 (89%),
  landed at 0.265 and took 0.5 s longer. The keyboard dipped to 0.182.

In LogoLight, a move to 0 or 1 stays a plain fade. A level is eased onto only once its target
has stayed put for two polls, so a slider being dragged is followed as before, and a change
while easing on stops it short for a new fade. An effect shortens the hold after a peak by
the time its fade overran. In the tests' fake (which moves in frames, as above), slider clicks
land within 0.002 and stop at 6–13% of the top speed, and Breathe and Pulse keep their cycle
within 0.1 s. Heartbeat's holds after its beats are too short to make up for easing on, so at
brightness 0.5 its cycle takes about 1.8 s instead of 1.55 s.

Not tested yet: what `corebrightnessd` does with a held level when the display **really**
sleeps and wakes, since its own Blank/Unblank could use the huge duration. LogoLight resets the
duration when the display sleeps and reapplies the level after it wakes; those two handlers
were only exercised by calling them directly. If LogoLight crashes while holding a level, the
huge duration stays in the daemon until LogoLight is reopened, which replaces it: with the
automatic duration, or with a new hold at the saved level.

## Reading the LED without corebrightnessd

- I/O Registry `bklb-backlight@0` has `enabled`, `high-period` and `low-period`. The duty cycle
  `high / (high + low)` is the LED's actual output. `enabled` is `No` while the display is
  asleep. Command: `ioreg -r -n bklb-backlight@0 -w0`.
- The NVRAM variable `bklb-backlight-enabled` (in `IODeviceTree:/options`) is **stale**: the
  daemon only reads it at startup (`CBLENVRAM boolForKey:outValue:`) and doesn't update it
  when the setting changes. Don't use it to check whether a change was applied.
- Screen asleep or awake: `CGDisplayIsAsleep` on the built-in display (`CGDisplayIsBuiltin`).
