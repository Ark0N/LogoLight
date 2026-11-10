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
  `MaxBrightness` (`clientMappedSetKey:`) to the modules of the selected type, by calling their
  `setProperty:forKey:` with the same key. That looked like a way to set the logo's brightness
  properly, instead of holding a fade, but `-[CBLEPWMControlModule setProperty:forKey:]` handles
  only the keys above (read again on 2026-11-09, `tools/probes/refs.py`), so the logo's module
  would ignore them. **A dead end, not tried live.**
- `BrightnessSystemClient` also has `setProperty:withKey:andDisplay:` and
  `copyPropertyForKey:andDisplay:`, which address one display. Whether the logo's module answers to
  a display ID (which would let `DisplayLogicalState` reach it without the keyboard) **hasn't been
  tried**.
- `-[CBLEPWMControlModule copyPropertyInternalForKey:]` handles `DisplayNitsKey`,
  `LEBacklightMode`, `LEPWMState` and `StatusInfo`.

## Keys

| Key | Read | Write | Notes |
| --- | --- | --- | --- |
| `LEBacklightMode` | `0`/`2` | yes | `0` off, `2` on. `1` lights the logo too, but is saved as off. The daemon saves it itself with `setBool:(mode == 2) forKey:` into root's `com.apple.CoreBrightness` defaults, the same setting as Apple's documented `sudo defaults write … LEBacklightMode -int 0`. So it persists, and `defaults delete` still turns the logo on. |
| `LEPWMFactorFadeDuration` | `nil` | yes | Seconds, used by the **next** logical-state change. `0` means automatic (about 0.3 s). Changing it during a fade doesn't affect the fade in progress. |
| `DisplayLogicalState` | yes | yes | The display state the logo follows. Writing `1` (Blank) fades the logo to dark and `2` (Unblank) fades it to fully lit. **The keyboard backlight follows it too; the screen doesn't.** Writing the state it's already in is ignored, even mid-fade or while a level is held. Reading gives the last value sent to *anything*, including a keyboard-only write, so it doesn't show the logo's state once those are in use. |
| `LEPWMState` | dict | – | Live state, see below. |
| `ClamshellUpdate` | `0` | yes | Whether the lid is closed, as told to every module. While the logo's module has been told it's closed, the logo is dark whatever `DisplayLogicalState` says. See "The lid". |
| `CBClamshellState` | `0`/`1` | – | The lid as the daemon's own lid handling last saw it (`BLControl._clamshellClosed`). A client's `ClamshellUpdate` doesn't change it. |
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
inverse (by bisection) and `D` the distance to 0 or 1. Segments end on the clock, not by
counting polls, and a segment's fade is held once it has covered three quarters of its part:
a real 10 ms sleep runs about 2 ms late (median; 5 ms at p90), so a 50 ms segment counted in
polls let a third daemon frame through at the spring's top speed, and the next segment
overcorrected (in the fake, a click bounced and was held up to 0.06 off). The probe timed its
segments by the clock too. A segment that finds the logo already past its point (a short frame
or a very late poll) holds it there instead of turning back, and after a stall, segments whose
time is up are skipped rather than started and replaced at once. The hold ends it. Measured:

- Slider moves with 4–5 segments (0.7 → 0.3, 0.3 → 0.8, 0.8 → 0.265) stopped at 0.24–0.51 per
  second, 10–17% of the top speed, landing within 0.003, 0.022 and 0.002. The keyboard dipped
  to 0.168–0.173.
- The effect-style rise with 6 segments stopped at 0.03 per second (11%) instead of 0.14 (89%),
  landed at 0.265 and took 0.5 s longer. The keyboard dipped to 0.182.

In LogoLight, a move to 0 or 1 stays a plain fade. A level is eased onto only once its target
has stayed put for two polls, so a slider being dragged is followed as before, and a change
while easing on stops it short for a new fade. The time a peak's fade overran (on the clock)
is taken from the holds that follow, so an effect keeps its cycle length. In the tests' fake
(which moves in frames, as above), with exact and late polls (up to 15 ms) and frames 12–19 ms apart,
slider clicks land within 0.01 without going back and stop under 25% of the top speed, and
Breathe, Pulse and Heartbeat keep their cycle within 0.1 s at brightness 0.5. Heartbeat's holds
after its beats are too short to make up for easing on, so its rest is about 0.26 s shorter.

Not tested yet: what `corebrightnessd` does with a held level when the display **really**
sleeps and wakes, since its own Blank/Unblank could use the huge duration. LogoLight resets the
duration when the display sleeps and reapplies the level after it wakes; those two handlers
were only exercised by calling them directly. If LogoLight crashes while holding a level, the
huge duration stays in the daemon until LogoLight is reopened, which replaces it: with the
automatic duration, or with a new hold at the saved level.

## Following the sound

The Sound effect moves the logo after the music, with the fades above and as few writes as it
can (`SoundFollower`, `LightEmitter.move`): every fade toward dark dims the keyboard a little (see
"Easing onto a level"), so the follower doesn't retarget the fade on every look. Every 30 ms it
reads `Factor` and the sound's loudness. When the sound is louder than the logo is bright (by a
deadband of 0.05), it starts one fade toward lit, with the duration that reaches the level in
about 0.05 s, and lets it run (it heads for 1) until the logo has caught up; then it holds the
logo with one write, or, if the sound has dropped meanwhile, starts one fade toward dark (0.1 s to
the level). Those were 0.08 and 0.2 s at first, with the meter's envelope releasing over 0.12 s,
which the user found slow by eye; the envelope now releases over 0.06 s. Measured again with
those: the same 10 peaks for 10 beats (0.95–1.00), each lit for 0.08–0.18 s instead of 0.23, the
keyboard unchanged, and the steady half loudness settled at 0.215. A fall to silence is left to end at 0 by itself, so the next rise is a change of
state and costs no turn-round, and the app shows a frame for the display-ready gate. A steady
sound is held once and then left alone.

Measured with `tools/livecheck --sound` on 2026-11-09 (a stand-in for the sound, so the timing
is the follower's own): beats at 2 Hz, each 0.12 s loud, gave 10 peaks for 10 beats, all reaching
1.00, each lit (above 0.7) for 0.23 s, 0.49–0.51 s apart; a steady half loudness settled at 0.277
(0.25 asked for, inside the deadband plus a frame's travel) and didn't move in 2 s; loud at
brightness 0.5 gave 0.277 (0.265). The keyboard's duty was 0.122 at its lowest and 0.125 on
average over the 5 s of beats, against 0.126 at rest (a darker room than the measurements above),
so two fades toward dark a second don't dim it visibly.

The sound itself comes from a Core Audio process tap on every process's output
(`SystemAudioLevel`, macOS 14.2+), read through a private aggregate device with the default output
device, as Apple's sample code does. From Terminal it delivered audio at once, also from a binary
signed with the hardened runtime and no entitlements; the app's `NSAudioCaptureUsageDescription`
is for the System Audio Recording Only permission macOS asks for.

## The lid

Measured on 2026-11-08 with an external display attached and the lid closed, with
`tools/probes/clamshell` and then `tools/livecheck --lid`, and read from the disassembly. This is
how LogoLight's Lit with Lid Closed works.

- When the lid closes, `BLControl` (on an `IOPMrootDomain` interest notification, which carries
  `AppleClamshellState`) sends `ClamshellUpdate = 1` to every display container, the keyboards,
  the colour module and the LE manager. It sends it again only on a real lid change, or when one
  of those is set up (`setupLEManager`, `addDisplayContainerForBrightnessControl:`,
  `keyboardBacklightHIDDeviceArrived:`).
- `-[CBLEPWMControlModule _resolveTargetFactor]` gives the logo a target of 0 while the module's
  `_clamshellClosed` is set, whatever `DisplayLogicalState` says. The same goes for
  `_displayBrightnessZero`, a shutdown, and the WillSleep and DidSleep power states. With the lid
  closed, Blank then Unblank did nothing.
- A client's `ClamshellUpdate` reaches the same modules (`-[BLControl
  _setPropertyWithKey:property:client:]`). With the lid closed, writing `0` relit the logo, which
  stayed lit. Writing `1` to the keyboards only (`setProperty:withKey:keyboardID:`) then took the
  keyboard dark again within 0.5 s and left the logo lit. Writing `1` to everything darkened it
  in 0.3 s. Lit like this, the logo gave 17% duty at full brightness: the light sensor is covered,
  so it glows as it would in a dark room (180 applied nits, against 220–280 with the lid open in
  the same room).
- `DisplayNits` stayed at 392 with the lid closed, so `_displayBrightnessZero`, which is set when
  the built-in panel's nits fall to 0 and which clients can't write, didn't get in the way.
- `CBClamshellState` (`-[BLControl copyPropertyInternalForKey:]`) reads `BLControl._clamshellClosed`,
  which only the daemon's own lid handling sets. It shows when the daemon has handled the lid
  closing: an override written before that would be undone by the daemon's own update. It also
  shows when the lid has really opened.
- **A held level survives a lid change.** Held at 0.265, the logo stayed lit (8% duty) after the
  lid closed, and a client's `ClamshellUpdate = 1` was ignored the same way. A hold heading for
  dark isn't a change of target, and one heading for lit gets a new fade at the hold's endless
  duration. So before Lit with Lid Closed, a logo below full brightness stayed lit on a closed lid.
  To darken it, LogoLight tells it the lid is open, hands it back to normal (the automatic
  duration, then Unblank), and tells it the lid is closed again. A display sleep (DidSleep also
  only sets the target to 0) may leave a held level lit in the same way; that hasn't been checked.
- A rise from a factor of exactly 0 waits for the display-ready gate (`CBLEPWMDisplayReadyGate`:
  a lit display frame, or a 0.5 s provider timeout, or 1 s). With the lid closed, the override's
  first rise started 0.65 s after it was written (between 0.5 and 0.8 s in the probe). Later
  rises from dark were held back little: Pulse's cycles took 2.15–2.19 s with the lid closed,
  against 2.16–2.25 s with it open (2.15 s planned). **With the lid open and an idle screen, rises
  from dark were held back 0–0.17 s** (Morse code's flashes, `tools/livecheck --morse`), and in a
  later run, with nothing at all changing on screen, often by the full 0.5 s. A 0.2 s dot can't
  absorb that, so quick flashes are timed from when the logo starts to rise, and **the app has the
  display show a new frame** at each rise from dark: its menu bar icon's opacity goes between 1
  and 0.99 (`LightEmitter.onRiseFromDark`). A looping SOS in the app, measured from outside: gaps
  within 0.17 units of their length (mean 0.12) with that, against up to 0.63 (mean 0.22) in the
  same minute without it. A fall to dark isn't gated.
- Below the daemon, `bklb-backlight@0` is a PWM device on its own controller
  (`AppleARMPWMDevice` on `pwm1@5044000`), outside the display pipeline, with no lid property.
- **Telling every module the lid is open tints external displays.** Measured on 2026-11-09 on a
  Mac17,13 (macOS 27.2) with two third-party external displays and the lid closed: after the
  global `ClamshellUpdate = 0`, both displays' colour modules had `ColorAdaptationActive = 1`
  (True Tone, adapting to the covered light sensor) and a `ColorRampTarget` diagonal of
  0.91 / 0.85 / 0.71, which looks warm and dim. Read per display with
  `copyPropertyForKey:andDisplay:` (keys `ColorAdaptationActive`, `ColorRamp`).
- **A display alone can be told the lid is closed again.** `setProperty:withKey:andDisplay:` (the
  display ID is the CoreGraphics one, as listed in `CBDisplayList` → `CBDisplayDeviceIDs`) goes
  to `-[BLControl setProperty:forKey:andHandle:error:]`, which passes the key to the display
  container whose `displayID` matches; the container passes it to its own modules, and
  `-[CBColorModule clamshellStatePropertyHandler:]` calls `updateClamshellState:`. Writing
  `ClamshellUpdate = 1` to both displays turned True Tone off on them (diagonal 1 / 1 / 1) within
  3 s, and the logo stayed at `Factor` 1: its module isn't in a display container. Lit with Lid
  Closed does this after its global write (`LightEmitter.overrideLid()`).
- **Not checked:** the built-in display's brightness when the lid opens again, and an Apple
  display with its own light sensor (Studio Display). A display attached during the override
  should get the daemon's own lid state from `addDisplayContainerForBrightnessControl:` (read from
  the disassembly, not tried).

- **With no external display, the same override works once the Mac is kept awake.** Measured on
  2026-11-10 with `tools/probes/lidawake`, on power: with a `PreventSystemSleep` assertion (and, in
  that run, an idle-sleep assertion and the root domain's `kPMSetClamshellSleepState` too) the Mac
  stayed awake for the minute the lid was closed. The logo went dark and the keyboard followed
  within 0.3 s; `CBClamshellState` read 1 at once. The global `ClamshellUpdate = 0` relit the logo
  (18% duty at a factor of 1), the keyboards told `1` stayed dark, fades out and in worked, and it
  stayed lit when left alone. `DisplayPowerStateEvent` wasn't needed. The built-in display stays
  online meanwhile and `CGDisplayIsAsleep` says 0, so the lid itself has to be asked
  (`AppleClamshellState` on `IOPMrootDomain`, and its `kIOPMMessageClamshellStateChange` interest
  notification). Which of the three kept the Mac awake wasn't separated; LogoLight uses the
  assertion alone, which goes away with the process.
- **A client's `DisplayPowerStateEvent = 4` (DidSleep) darkens the logo until a DidWake.** The
  probe wrote it at its end, and the logo stayed dark with the lid open (`Factor` 0, with
  `DisplayLogicalState` 2, `CBClamshellState` 0 and `ClamshellUpdate = 0` written again) until
  `DisplayPowerStateEvent = 2` was written, which lit it within 3 s. LogoLight never writes this key.

## Reading the LED without corebrightnessd

- I/O Registry `bklb-backlight@0` has `enabled`, `high-period` and `low-period`. The duty cycle
  `high / (high + low)` is the LED's actual output. `enabled` is `No` while the display is
  asleep. Command: `ioreg -r -n bklb-backlight@0 -w0`.
- The NVRAM variable `bklb-backlight-enabled` (in `IODeviceTree:/options`) is **stale**: the
  daemon only reads it at startup (`CBLENVRAM boolForKey:outValue:`) and doesn't update it
  when the setting changes. Don't use it to check whether a change was applied.
- Screen asleep or awake: `CGDisplayIsAsleep` on the built-in display (`CGDisplayIsBuiltin`).
