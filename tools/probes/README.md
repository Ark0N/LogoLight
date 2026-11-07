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
| `classes` | Lists CoreBrightness's Objective-C classes (filtered to clients and LE classes). |
| `methods CLASS…` | Lists a class's methods, e.g. `methods BrightnessSystemClient CBLEPWMControlModule`. |

## Changing the logo

| Tool | What it does |
| --- | --- |
| `lectl KEY=VALUE[@SECONDS]…` | Sets each key in turn and prints the fade factor, nits and the PWM duty every 0.1 s. Values with a `.` are sent as doubles. The workhorse. |
| `setmode N` | Sets `LEBacklightMode` and watches the LED for 1.5 s. |
| `sidefx` | Blanks, unblanks, then sets mode 1 and 2, printing the screen state each time. It was used to check that `DisplayLogicalState` doesn't touch the screen. |
| `fadecurve` | Measures a 2 s fade's curve, a fade from the midpoint, and holding a level (see "Holding a level" in the notes). |
| `setmapping KEY JSON` | Writes a mapping key, e.g. `LEPWMLuxToMaxNitsRestrictionMapping '[[0,60],[190,300],[3.402823e38,300]]'`, watches for 5 s, then restores the original. |

## Reading the binary

CoreBrightness lives in the dyld shared cache, so there's no file to open in a disassembler;
`dyld_info` reads it from the cache. `build.sh` writes `cb.asm`, `cstrings.txt` and
`cfstrings.txt` next to the tools.

| Tool | What it does |
| --- | --- |
| `refs.py cb.asm 'SYMBOL'…` | Lists the CFString constants each function references, which is how the LE keys were found. Example: `python3 refs.py cb.asm '-[CBLEPWMControlModule setProperty:forKey:]'`. It needs `cfstr` and `cfstrings.txt` in the same folder. |
| `cfstr ADDR…` | Resolves `__cfstring` addresses (as printed in `cb.asm`) to their text, by reading them in-process with the image's slide. |
| `cstr ADDR:LEN…` | Same for C strings. |
| `stubs ADDR…` | Decodes `objc_msgSend` selector stubs (`adrp` plus `add x1`) to selector names. |
| `table ADDR…` | Prints a 7-entry table of `NSString` pointers, e.g. the `DisplayLogicalState` names. |
| `peek ADDR` | Prints six instruction words at an address. |

`lldb` can't attach to `corebrightnessd`, and can't run these tools, unless Developer Mode is
on, which it wasn't. So everything was read statically or through `BrightnessSystemClient`.
