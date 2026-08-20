# mkxp-z for the R36S (ArkOS / RK3326)

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

---

## Install

1. Download `fire-ash-port.zip` from the [Releases](../../releases) page.
2. Copy the launcher `.sh` to the **root** of `/roms/ports` on the SD card
   (alongside `StardewValley.sh` and friends).
3. Copy the `mkxp` folder next to it, so you end up with `/roms/ports/mkxp/`.
4. Put **your own copy** of the game's files (`Data/`, `Graphics/`, `Audio/`,
   `Game.ini`, …) inside `/roms/ports/mkxp/`.
5. The port appears in the Ports menu.

If something goes wrong, create an empty file called `debug.txt` inside
`/roms/ports/mkxp/` and run it again: the launcher then writes verbose SDL
diagnostics into `mkxp-log.txt`. Leave it off for normal play — the log is
written to the SD card and, at one line per frame, is itself a slowdown.

---

## What this does not include

No game data of any kind. The engine is useless on its own; you supply the game
you already own or have obtained yourself.

Do not redistribute Pokémon fan games or any other copyrighted RPG Maker content
with this port. The engine is free software; the games generally are not, and
fan games in particular tend to contain third-party intellectual property.

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
SDL2 KMS/DRM application on these handhelds.

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

### 7. The whole game running in slow motion

mkxp-z ships with `frameSkip` **disabled**. When the hardware cannot sustain the
40 fps RPG Maker XP asks for, the engine does not drop frames — it delays the
game *logic*. Menus did not merely look choppy, they genuinely ran slow.

**Fix:** `"frameSkip": true`. `"printFPS": true` is also enabled so the log
carries real numbers instead of impressions.

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
