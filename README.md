# mkxp-z for the R36S (ArkOS / RK3326)

Play **Pokémon Fire Ash** and **Pokémon Infinite Fusion** natively on the R36S — no streaming, no PC.

A working native build of the [mkxp-z](https://github.com/mkxp-z/mkxp-z) RPG Maker
XP/VX/VX Ace engine for the **R36S** handheld running **ArkOS**, plus the complete,
reproducible cross-compilation setup used to produce it.

This lets RPG Maker XP games run natively on the handheld — no streaming, no
emulation of a Windows layer.

> **This repository contains no game data.** It ships an engine, not a game. See
> [What this does not include](#what-this-does-not-include).

---

## Status

Tested on an R36S (Rockchip RK3326, Mali-G31, ArkOS) with a Pokémon Essentials
based RPG Maker XP game:

| | |
|---|---|
| Video | KMS/DRM at 640×480, OpenGL ES 3.2 on Mali-G31 |
| Audio | ALSA via OpenAL Soft |
| Input | Gamepad, Nintendo-style face buttons |
| Exit | `SELECT` + `START` returns to the ArkOS frontend |
| Speed | 40 fps (RPG Maker XP's target) at roughly half of one CPU core |

If your game does *not* hold 40 fps, read
[Performance](#performance-when-the-game-crawls-it-is-usually-not-the-engine)
before assuming the port is at fault — on this hardware it usually isn't.

---

## Install

1. Download `fire-ash-port.zip` from the [Releases](../../releases) page.
2. Copy the launcher `.sh` to the **root** of `/roms/ports` on the SD card
   (alongside `StardewValley.sh` and friends).
3. Copy the `mkxp` folder next to it, so you end up with `/roms/ports/mkxp/`.
4. Put **your own copy** of the game's files (`Data/`, `Graphics/`, `Audio/`,
   `Game.ini`, …) inside `/roms/ports/mkxp/`.
5. The port appears in the Ports menu.

### Diagnostics

Create an empty file called `debug.txt` inside `/roms/ports/mkxp/` and the
launcher will, for that run:

- write verbose SDL diagnostics into `mkxp-log.txt`, and
- sample temperature, CPU frequency, CPU usage and free memory every 5 seconds
  into `perf-log.txt`.

Delete it for normal play: the verbose SDL log is one line per frame written to
the SD card, which is itself a slowdown. `mkxp.json` leaves `printFPS` on
regardless — one line per second is free, and it is what makes it possible to
measure a performance complaint instead of guessing at it.

---

## What this does not include

No game data of any kind. The engine is useless on its own; you supply the game
you already own or have obtained yourself.

Do not redistribute Pokémon fan games or any other copyrighted RPG Maker content
with this port. The engine is free software; the games generally are not, and
fan games in particular tend to contain third-party intellectual property.

---

## Performance: when the game crawls, it is usually not the engine

The port held 40 fps in most places but collapsed to 8 fps in specific areas,
badly enough to be unplayable. Chasing that produced the single most useful
finding in this whole project, so it is written up in full — the method
transfers to any game.

### What the numbers said

`printFPS` plus the `debug.txt` sampler gave a minute-by-minute picture, and it
ruled out three obvious suspects outright:

| Suspect | Measurement | Verdict |
|---|---|---|
| Thermal throttling | 1512 MHz in **all 75 samples**, never once lower, at up to 74 °C | Not it |
| Running out of RAM | 371 MB still free at worst, **0 bytes** of swap touched | Not it |
| CPU governor asleep | `governor=performance`, already applied by the launcher | Not it |

What it *was*:

| | fps | CPU |
|---|---|---|
| Normal area | 40 | **54%** of one core |
| Slow area | 8–19 | **112%** of one core |

112% out of a possible 400%. One core pinned, three idle. RPG Maker runs game
logic in a single Ruby thread by design, so the other three cores cannot help
and no engine setting changes that.

### What actually fixed it

Pokémon Essentials **v19** does not use RPG Maker's native map drawing — it
ships its own tilemap renderer written in Ruby. Animated tiles, water above
all, are recomputed in Ruby every frame. That is why the slowdown was tied to
specific areas rather than to time, and why it saturated exactly one core.

Fire Ash's own changelog turns out to name the problem:

> *"Improved the game's graphics renderer to reduce lag near water"*
> *"Added the option to reduce the speed of tile animations to reduce lag"* — v3.7

**Setting tile animation speed to slow, in the game's own options menu, fixed
it completely.** No engine change, no rebuild.

### If your game has no such option

Two dials in `mkxp.json` change *which symptom* you get when the hardware cannot
sustain 40 fps. Neither makes the game faster:

- `"frameSkip": true` — the engine stops **drawing** frames to keep the game
  logic at the correct speed. Timing stays right, but in heavy areas the picture
  becomes a slideshow and you end up walking blind.
- `"frameSkip": false` — every frame is drawn, so you see everything, but the
  whole game runs in slow motion.

This port ships `false`. Try both and keep the one that bothers you less.

Beyond that, the honest answer is that the bottleneck is the game's Ruby code.
Rebuilding the engine tuned for the exact core (`-mcpu=cortex-a35` instead of
the generic ARMv7 profile used here) would be worth maybe 10–20%, which does not
close a 5× gap.

---

## Controlling the in-game day/night cycle

Pokémon Essentials decides whether it is day or night by reading `Time.now.hour`
— the system clock. On the R36S that has an awkward consequence: the console has
**no battery-backed RTC**, so with Wi-Fi off it boots to the same fixed date
every single time. The day/night cycle is effectively frozen at whatever hour
that default happens to be, and night-only encounters and evolutions stay
unreachable without anyone working out why.

`tools/` holds three ArkOS ports that set the console clock, so you can pick the
time of day before launching the game:

| File | What it does |
|---|---|
| `CambiarHora.sh` | On-screen menu: night / day / dawn / dusk / small-hours presets, exact time, date, and re-enabling network sync |
| `Hora-Noche.sh` | Sets the clock to 22:00 and exits |
| `Hora-Dia.sh` | Sets the clock to 12:00 and exits |

Copy them to the root of `/roms/ports` and restart EmulationStation; they appear
in the Ports menu. Run one, then launch the game. The on-screen text is in
Spanish — it is a handful of `dialog` calls, easy to translate.

Two details that are easy to get wrong:

- **Network time sync has to go off first.** With Wi-Fi on, `systemd-timesyncd`
  puts the real time back within seconds and the script looks broken.
  `CambiarHora.sh` runs `timedatectl set-ntp false` before touching the clock,
  and has a menu entry to turn it back on.
- **`hwclock --systohc` does nothing on this hardware.** There is no RTC to
  write to, so the clock resets on every boot. Setting it is a per-session step,
  not a one-off.

`CambiarHora.sh` follows the standard ArkOS script pattern
(`/opt/inttools/gptokeyb` for gamepad input, `dialog` for the menu) rather than
PortMaster, which this console has no reason to have installed. The two preset
scripts depend on neither and exist as a fallback for when `dialog` or
`gptokeyb` is missing.

In Essentials v19 night runs 20:00–05:00 and day 10:00–17:00. Individual games
may move those boundaries, but 22:00 and 12:00 land in the right period either
way.

> There is a second approach: the launcher can export a fake POSIX timezone
> (`TZ=GAME±hh:mm`) so that *only the game process* sees a shifted clock. It
> leaves the console clock alone and network sync cannot undo it. The Fire Ash
> launcher does not do this; the [Infinite Fusion launcher](#a-second-game-pok%C3%A9mon-infinite-fusion)
> does, if you drop a `hora.txt` containing e.g. `22:00` into its folder.
> **Do not combine it with the clock scripts** — the two offsets add up.

---

## A second game: Pokémon Infinite Fusion

The same engine binary also runs **Pokémon Infinite Fusion** (6.8.x) — with the
**complete** art set, including the hand-drawn fusion sprites. PortMaster
declined this game because it "requires mkxp-z which we don't have running";
this is that.

It is installed **in parallel** to the first game, so neither can break the
other:

```
/roms/ports/PokemonInfiniteFusion.sh     <- infinite-fusion/PokemonInfiniteFusion.sh
/roms/ports/mkxp-fusion/                 <- same files as mkxp/ (engine, libs,
                                            mkxp.json, exitwatch) + your copy
                                            of the game
```

Delete the game's `.git` folder (~2 GB of updater packs) before copying — it
does nothing on the console.

### Memory was the real problem: zram

The console has no swap. Infinite Fusion's sprite sheets are huge (the
`spritesheets_custom` sheets are 1920×2784, ~20 MB each decoded), and when RAM
ran out the kernel killed the game silently — the log just stopped mid-line.

The launcher sets up **512 MB of compressed swap in RAM (zram)** before starting
the engine:

- ArkOS does not run ports as root, so it goes through `sudo -n`. If sudo would
  ask for a password it gives up in milliseconds and the game starts without
  zram instead of hanging.
- It asks for `lz4`; this kernel does not offer it, so the kernel default
  (`lzo`) is what actually runs. `vm.swappiness=100`, `vm.page-cluster=0`.
- It only tears down zram on exit if it was the one that set it up, and it
  leaves any pre-existing swap alone.
- An empty `sin-zram.txt` in the game folder disables it, for comparisons.

Measured over a full session with every sprite folder in place:

| | |
|---|---|
| Real compression ratio | 2.75 : 1 (79 MB of data in 29 MB of RAM) |
| Swap used, peak | 99 MB of 511 |
| Process RSS, peak | 761 MB |
| Free memory, minimum | 68 MB |
| Kernel OOM kills | none |
| Frame rate | 32.8 fps average, locked at 40 about half the time |

Without the custom sprite sheets the average was 35.7 fps — the full art costs
about 3 fps. If memory kills ever come back, raising `ZRAM_MB` is the first
lever.

### In-game options that matter

| Option | Value | Why |
|---|---|---|
| Download data | **Off** | With no network each attempt can only fail, and blocks until it times out |
| Text entry | **Cursor** | "Keyboard" waits for a physical keyboard and stalls character creation |
| Device | **Mobile** | Matches what the console is: no keyboard, no mouse, no network |

### What else the launcher does

- **Post-mortem.** When the engine exits, the launcher appends to `mkxp-log.txt`
  the exit code decoded (0 clean, 137 killed, 139 segfault, 143 SELECT+START),
  whether `exitwatch` intervened, zram `mm_stat`, free memory and any OOM lines
  from the kernel. Without it an OOM kill and a forced quit look identical.
- **Save quarantine.** Before launch, any 0-byte `*.rxdata` / `*.dat` outside
  `Data/` (the result of cutting power mid-write) is *moved* — never deleted — to
  `saves-corruptas/`, so a broken save cannot stop the game from booting. Moves
  are logged to `guardados-apartados.txt`.
- **`debug.txt`** enables verbose SDL logging and 5-second sampling (now
  including swap used and RSS) into `perf-log.txt`, same as the Fire Ash
  launcher.
- **`hora.txt`** — per-game fake time, see the day/night section above.

### Testing notes

- **Power-cycle the console between test runs.** Mali GPU memory left behind by
  a SIGKILLed process survives the process and accumulates; comparing two runs
  without a reboot gives false numbers. (That is how the sprite folders were
  wrongly blamed for crashes that were really a lack of swap.)
- Initial load takes 45–85 s: that is Ruby reading and deserialising ~100 MB of
  `.dat` files from the SD card.
- **Known issue:** confirm/cancel feel swapped compared with Fire Ash (A cancels,
  B confirms). It is the same binary, so this comes from the game, not the
  engine.

---

## The problems that had to be solved

Cross-compiling for this device is not just a matter of pointing a compiler at
ARM. Everything below was a real failure discovered on the hardware, and each
one is fixed in `patches/` or `build/`.

### 1. `GLIBC_2.3x not found` — the binary would not start

The distro's armhf cross-compiler targets a much newer glibc than ArkOS ships.

The obvious workaround — bundling a newer glibc and forcing it with
`--dynamic-linker` — *makes things worse*: the console's GPU drivers, which are
`dlopen`ed at runtime, pull in the console's **own** `libpthread`, and that
resolves `GLIBC_PRIVATE` symbols only against its exact sibling libc. Mixing
the two produced

```
libpthread.so.0: undefined symbol: __libc_dlclose, version GLIBC_PRIVATE
```

Fully static linking fails differently: glibc cannot `dlopen` from a static
binary at all (`dl-call-libc-early-init` aborts).

**Fix:** build against a glibc *older* than the device's, using Ubuntu 20.04's
gcc-9 armhf cross toolchain (glibc 2.31), and link normally against the
console's own libc. Only `libstdc++`/`libgomp`/`libgcc_s`/`libruby` travel with
the binary. See `build/01-host-toolchain.sh`.

### 2. `Could not initialize OpenGL / GLES library`

SDL2 was compiling with only the `dummy` and `offscreen` video drivers. Its
`CheckKMSDRM()` needs `libdrm`+`gbm`+`egl` at configure time, and a cross
sysroot has none of them, so the KMS/DRM driver was silently skipped.

**Fix:** a *detection stub* sysroot (`build/02-gpu-stubs.sh`). Because SDL2 is
configured with `SDL_KMSDRM_SHARED=ON` it never links these libraries — it only
needs the headers to compile, and the SONAME strings, which it `dlopen`s at
runtime against the device's real drivers. Nothing from the stubs ships.

### 3. `Could not detect an available audio device`

Same shape of problem: with no ALSA headers at configure time, SDL2 and OpenAL
Soft fell back to OSS (`/dev/dsp`), which does not exist on ArkOS.

**Fix:** cross-build `alsa-lib`, and make a missing ALSA backend a hard build
error rather than a silent runtime failure discovered an hour later on the
handheld.

FluidSynth then started detecting ALSA too and dragged `-lasound` onto the link
line without using a single symbol from it, leaving a pointless hard dependency
on `libasound.so.2`. It is now built with no audio output drivers at all —
mkxp-z only ever uses it as a MIDI *synthesiser*, rendering into a buffer.

### 4. `cannot load such file -- zlib (LoadError)`

Ruby's `libruby-static.a` contains only the ~88 core interpreter objects. The
standard-library C extensions — `zlib` above all — are linked **exclusively**
into `libruby.so`. RPG Maker XP games `require 'zlib'` while decompressing
their script data, so a statically linked Ruby kills the game at startup.

**Fix:** keep upstream's shared Ruby and ship `libruby.so.3.1` with the engine.

### 5. `Could not queue pageflip: -22` — every single frame

The most interesting one. With vsync off (mkxp-z's default) SDL2 requests
`DRM_MODE_PAGE_FLIP_ASYNC` whenever the driver advertises
`DRM_CAP_ASYNC_PAGE_FLIP`. Rockchip's driver advertises the capability and then
rejects every async flip with `-EINVAL`.

Nothing the game drew was ever scanned out properly: it rendered into the buffer
still being displayed. On screen that looked like torn, half-drawn text and
sluggish input — and, since every failure wrote a line to the SD card, the
logging alone was a measurable slowdown.

This is a known hazard in the kernel graphics stack; Linux later grew
`drm_mode_config.atomic_async_page_flip_not_supported` precisely because drivers
were advertising a capability they did not implement. SDL2 does not handle the
rejection.

**Fix** (`patches/0001-…`): if an async flip is rejected, retry it synchronously
and stop requesting async. One rejected ioctl per session instead of one per
frame. This is not specific to this game or this engine — it should help any
SDL2 KMS/DRM application on these handhelds. Reported upstream as
[libsdl-org/SDL#16174](https://github.com/libsdl-org/SDL/issues/16174).

### 6. Text with the bottoms of characters cut off

Not tearing, and not a missing font. mkxp-z reproduces RGSS's habit of
reporting a *nominal* font height; its own source says so:

```c
/* RGSS normalizes the reported heights.
 * Note that this may result in the bottoms
 * of some characters being cut off. */
```

**Fix:** `"fontHeightReporting": 1` and `"fontOutlineCrop": false` in
`build/mkxp.json`.

### 7. Slow motion, or a frozen picture — pick one

When the hardware cannot sustain RPG Maker XP's 40 fps, `frameSkip` decides
which way it degrades, and it is easy to mistake one symptom for a separate bug.
With it off the game runs in slow motion; with it on the logic keeps correct
speed but heavy areas turn into a slideshow you cannot navigate.

It is a choice of symptom, not a fix. The underlying cause is almost always the
game rather than the engine — see
[Performance](#performance-when-the-game-crawls-it-is-usually-not-the-engine).

### 8. No way to quit without resetting the console

ArkOS's usual `SELECT`+`START` does nothing, because mkxp-z reads the pad
through SDL and knows nothing about that convention. mkxp-z's own key-binding
menu is not an option either: it needs F1, and it opens a second SDL window,
which KMS/DRM cannot display.

**Fix:** `build/exitwatch.c`, a ~5 KB helper that watches the evdev devices
**read-only** — never grabbing them, so SDL keeps receiving every event — and on
the combo sends `SIGTERM` (which SDL turns into a clean `SDL_QUIT`), escalating
to `SIGKILL` only after a grace period.

### 9. Face buttons felt inverted

mkxp-z's PC default puts confirm on the bottom face button. Every other emulator
on the handheld follows the Game Boy convention. `patches/0003-…` swaps them:

| Button | Action |
|---|---|
| Right | Confirm / talk |
| Bottom | Cancel / open menu |
| Left | Run |
| L1 / R1 | L / R |

### Build-environment workarounds

Also handled in `build/`, and worth knowing if you rebuild: libpng's zlib
version cross-check, Ruby's doubly-nested `DESTDIR` install, Ruby's bundled gems
being fetched from the network, SDL_image's JPEG-XL submodule chain, and
mkxp-z's dependency Makefile racing under `-j` because each library's *configure*
step does not depend on the libraries it will look for.

---

## Rebuilding

Needs a Debian/Ubuntu x86-64 host with network access. Run in order:

```sh
sudo build/01-host-toolchain.sh     # gcc-9 armhf cross toolchain, glibc 2.31
sudo build/02-gpu-stubs.sh          # libdrm/gbm/EGL detection stubs
     build/03-source-and-patches.sh # clone mkxp-z + SDL2, apply every patch
     build/04-build-deps.sh         # cross-build all dependencies (slow: Ruby)
     build/05-build-and-package.sh  # build the engine, produce the zip
```

Each script explains *why* every non-obvious step exists. Patches are also
provided standalone in `patches/` if you only want the fixes.

The scripts write to absolute paths under `/root` and are meant for a throwaway
container or VM, not your daily machine.

---

## Licensing

mkxp-z is **GPLv2 or later**. Built with its default `enable-https` option it
also links OpenSSL, which in practice makes the resulting binaries **GPLv3**.
That is why this repository exists in the form it does: distributing the binary
obliges you to offer the corresponding source, and these scripts and patches are
that source.

Bundled or statically linked components keep their own licences — among them
SDL2 (Zlib), OpenAL Soft and FluidSynth (LGPL), FreeType, Ruby, and the GCC
runtime libraries (GPLv3 with the Runtime Library Exception). See `NOTICE.md`.
The LGPL components are statically linked, so the build scripts here double as
the means to relink them.

Not legal advice — if you plan to redistribute widely, read the licences.
