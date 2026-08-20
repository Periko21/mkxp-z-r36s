#!/usr/bin/env bash
# ============================================================================
# 05-build-and-package.sh
#
# Builds the mkxp-z executable itself and assembles the ArkOS port package:
#
#     Fire Ash.sh        <- launcher, goes in /roms/ports/
#     mkxp/mkxp-z        <- the engine
#     mkxp/lib*.so*      <- C++ runtime, in case the console's is older
#
# The player's own game data (Data/, Graphics/, Audio/, Game.ini, ...) already
# lives in /roms/ports/mkxp on the device and is intentionally left untouched.
# ============================================================================
set -euo pipefail

SRC=/root/mkxp-z
ARCH=armv7old
PREFIX="$SRC/linux/build-$ARCH"
BUILD="$SRC/build-$ARCH"
PKG=/root/package
OUT=/root/fire-ash-port.zip
SYSLIB=/usr/arm-linux-gnueabihf/lib

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    - %s\n' "$*"; }

cd "$SRC"
# shellcheck disable=SC1090
source "linux/target-$ARCH.sh"
# vars.sh exports PKG_CONFIG_LIBDIR, which is what points meson at our
# cross-built dependencies instead of the host's. It appends to LD_LIBRARY_PATH
# unguarded and prints a harmless error from upstream's Ruby workaround once the
# nested install dir has been cleaned up, so relax -u/-e just for this.
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
set +eu
source linux/vars.sh 2>/dev/null
set -eu
test -n "${PKG_CONFIG_LIBDIR:-}" || { echo "FATAL: vars.sh did not export PKG_CONFIG_LIBDIR"; exit 1; }

log "Configuring mkxp-z (meson)"
rm -rf "$BUILD"
meson setup --cross-file "./linux/$ARCH_MESON_TOOLCHAIN" "$BUILD" \
    -Dgfx_backend=gles \
    -Dworkdir_current=true 2>&1 | tail -25

log "Compiling"
ninja -C "$BUILD" 2>&1 | grep -vE "^\.\./|^ *[0-9]+ \||^ *\||note:|warning:|^In file|^ +\^|^ +~" | tail -15
ninja -C "$BUILD" install >/dev/null 2>&1 || true

# Prefer the installed copy: `ninja install` rewrites the placeholder rpath
# meson pads into the build-tree binary with the real install_rpath.
EXE=$(ls /usr/local/bin/mkxp-z.* 2>/dev/null | head -1)
[ -x "${EXE:-}" ] || EXE=$(ls "$BUILD"/mkxp-z.* | grep -v '\.p$' | head -1)
test -x "$EXE"

log "Binary properties"
arm-linux-gnueabihf-readelf -d "$EXE" | grep -E "NEEDED|RUNPATH" | sed 's/^ */    /'
printf '    highest glibc symbol required: '
arm-linux-gnueabihf-objdump -T "$EXE" | grep -oE 'GLIBC_[0-9.]+' | sort -V -u | tail -1
printf '    runtime-dlopened drivers: '
strings "$EXE" | grep -E '^lib(drm|gbm|EGL|GLESv2|asound)\.so' | tr '\n' ' '; echo

log "Assembling package"
rm -rf "$PKG"; mkdir -p "$PKG/mkxp"
cp "$EXE" "$PKG/mkxp/mkxp-z"
arm-linux-gnueabihf-strip "$PKG/mkxp/mkxp-z"

# Ship the C++/OpenMP runtime next to the binary (found via the rpath compiled
# in by PATCH 6). glibc itself is deliberately NOT shipped -- the engine is
# built against 2.31 precisely so it can use the console's own.
cp -a "$SYSLIB/libstdc++.so.6."*  "$PKG/mkxp/"
cp -a "$SYSLIB/libgomp.so.1."*    "$PKG/mkxp/"
cp -a "$SYSLIB/libgcc_s.so.1"     "$PKG/mkxp/"
( cd "$PKG/mkxp"
  ln -sf libstdc++.so.6.* libstdc++.so.6
  ln -sf libgomp.so.1.*   libgomp.so.1 )

# Ruby is linked shared (see 04-build-deps.sh), so its library must travel with
# the engine -- it is what carries Ruby's C extensions, zlib above all, which
# RPG Maker XP script data cannot be decompressed without.
cp -a "$PREFIX/lib/libruby.so.3.1.3" "$PKG/mkxp/"
( cd "$PKG/mkxp" && ln -sf libruby.so.3.1.3 libruby.so.3.1 )
arm-linux-gnueabihf-strip "$PKG/mkxp/libruby.so.3.1.3"

# Everything the executable asks for at load time must be either a plain glibc
# library (present on any ArkOS install) or shipped here. Catch omissions now.
for lib in $(arm-linux-gnueabihf-readelf -d "$EXE" \
             | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
    case "$lib" in
        libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|\
        libutil.so.1|libcrypt.so.[12]|ld-linux-armhf.so.3) continue ;;
    esac
    test -e "$PKG/mkxp/$lib" || { echo "FATAL: $lib is required but not shipped"; exit 1; }
done
note "shipped: $(cd "$PKG/mkxp" && ls lib*.so* | tr '\n' ' ')"

# The SELECT+START quit helper: ArkOS expects that combo to return to the
# frontend, but mkxp-z reads the pad through SDL and knows nothing about it, so
# without this the only way out of the game is resetting the console.
arm-linux-gnueabihf-gcc -O2 $ARCH_CFLAGS -Wall -Wextra \
    -o "$PKG/mkxp/exitwatch" /root/build/exitwatch.c
arm-linux-gnueabihf-strip "$PKG/mkxp/exitwatch"
note "exitwatch built ($(stat -c %s "$PKG/mkxp/exitwatch") bytes)"

# Engine settings: fixes the clipped text and stops the whole game running in
# slow motion when the hardware cannot sustain RPG Maker XP's 40 fps.
cp /root/build/mkxp.json "$PKG/mkxp/mkxp.json"
note "mkxp.json shipped (font metrics + frameSkip + printFPS)"

cp /root/build/launcher.sh "$PKG/Fire Ash.sh"
chmod +x "$PKG/Fire Ash.sh"

( cd "$PKG" && rm -f "$OUT" && zip -qr "$OUT" "Fire Ash.sh" mkxp/ )
log "Package written to $OUT"
unzip -l "$OUT" | tail -15
