# Probe tools

Small command-line tools used to work out how `corebrightnessd` drives the logo. They're
research scripts, not part of the app, and are kept so the findings in
[`docs/corebrightnessd.md`](../../docs/corebrightnessd.md) can be checked again, e.g. after a
macOS update.

```sh
tools/probes/build.sh          # builds everything into .build/probes, plus the dumps refs.py needs
cd .build/probes
./props LEPWMState LEBacklightMode DisplayLogicalState
```

**Most of these change the real logo.** Only run them on the MacBook Pro with PROLED XDR
Display, quit LogoLight first (its effects would interfere), and put the logo back to normal
afterwards:

```sh
./lectl LEPWMFactorFadeDuration=0.5@0.05 DisplayLogicalState=1@0.05 DisplayLogicalState=2@1 LEPWMFactorFadeDuration=0@0.3
```

The flip to `1` and back matters: setting `DisplayLogicalState` to the state it's already in
is ignored, so a held level isn't released by a lone `DisplayLogicalState=2`.

## Reading state (safe)

| Tool | What it does |
| --- | --- |
| `props KEY…` | Prints `copyPropertyForKey:` for each key, e.g. `LEPWMState`, `LEBacklightMode`, `DisplayLogicalState`, `LEPWMBrightnessNitsMapping`. |
| `status` | Prints the big `StatusInfo` dump. |
| `ledsample [SECONDS]` | Prints the logo's fade level and the real output of the logo and keyboard LEDs about 3 times a second, from the I/O Registry. Run it while something else changes the logo, to see side effects. |
| `classes` | Lists CoreBrightness's Objective-C classes (filtered to clients and LE classes). |
| `methods CLASS…` | Lists a class's methods, e.g. `methods BrightnessSystemClient CBLEPWMControlModule`. |

## Changing the logo

| Tool | What it does |
| --- | --- |
| `lectl KEY=VALUE[@SECONDS]…` | Sets each key in turn and prints the fade factor, nits and the PWM duty every 0.1 s. Values with a `.` are sent as doubles. The workhorse. |
| `lidawake [log]` | Keeps the Mac awake with the lid closed and no external display, and tries each way of relighting the logo there. Asks aloud for the lid to be closed. |
| `setmode N` | Sets `LEBacklightMode` and watches the LED for 1.5 s. |
| `sidefx` | Blanks, unblanks, then sets mode 1 and 2, printing the screen state each time. It was used to check that `DisplayLogicalState` doesn't touch the screen. |
| `fadecurve` | Measures a 2 s fade's curve, a fade from the midpoint, and holding a level (see "Holding a level" in the notes). |
| `clamshell` | With an external display attached: asks aloud for the lid to be closed, then tries ways of lighting the logo with it closed (`ClamshellUpdate`, `DisplayLogicalState`), reading both LEDs from the I/O Registry, restores normal lighting and says which way worked. `--sample-only` writes nothing. See "The lid" in the notes. |
| `setmapping KEY JSON` | Writes a mapping key, e.g. `LEPWMLuxToMaxNitsRestrictionMapping '[[0,60],[190,300],[3.402823e38,300]]'`, watches for 5 s, then restores the original. |

## The screen

Not the logo: the display drivers' temporal dithering, which the app's Disable Dithering turns
off. It can be run while LogoLight runs (with Disable Dithering unchecked).

| Tool | What it does |
| --- | --- |
| `dither` | Prints each display pipe (`IOMobileFramebufferAP`) and its `enableDither`. Safe. |
| `dither off`, `dither on` | Sets it on every pipe, as [Stillcolor](https://github.com/aiaf/Stillcolor) does, and prints what each then reads. It takes effect at once, and a restart turns dithering back on. |
| `dither try` | Off, reads it back, and on again after a second. |

## Reading the binary

CoreBrightness lives in the dyld shared cache, so there's no file to open in a disassembler;
`dyld_info` reads it from the cache. `build.sh` writes `cb.asm`, `cstrings.txt` and
`cfstrings.txt` next to the tools.

| Tool | What it does |
| --- | --- |
| `refs.py cb.asm 'SYMBOL'…` | Lists the CFString constants each function references, which is how the LE keys were found. Example: `python3 refs.py cb.asm '-[CBLEPWMControlModule setProperty:forKey:]'`. It needs `cfstr` and `cfstrings.txt` in the same folder. |
| `whoref.py cb.asm KEY…` | The reverse: lists the functions that reference a key, e.g. to find everything that reads `DisplayLogicalState`. |
| `calls.py cb.asm 'SYMBOL'…` | Prints what a function does, in order: selectors sent, keys referenced and branches. It needs `stubs` too. |
| `cfstr ADDR…` | Resolves `__cfstring` addresses (as printed in `cb.asm`) to their text, by reading them in-process with the image's slide. |
| `cstr ADDR:LEN…` | Same for C strings. |
| `stubs ADDR…` | Decodes `objc_msgSend` selector stubs (`adrp` plus `add x1`) to selector names. |
| `table ADDR…` | Prints a 7-entry table of `NSString` pointers, e.g. the `DisplayLogicalState` names. |
| `peek ADDR` | Prints six instruction words at an address. |

`lldb` can't attach to `corebrightnessd`, and can't run these tools, unless Developer Mode is
on, which it wasn't. So everything was read statically or through `BrightnessSystemClient`.
