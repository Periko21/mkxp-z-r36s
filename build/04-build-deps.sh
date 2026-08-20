#!/usr/bin/env bash
# ============================================================================
# 04-build-deps.sh
#
# Cross-builds every library mkxp-z links against.
#
# Deliberately sequenced rather than one big parallel `make`: mkxp-z's
# dependency Makefile declares each library's *configure* step as depending
# only on its own sources, not on the libraries it will look for. Under -j2
# that lets e.g. vorbis's cmake run while libogg is still compiling, and it
# then hard-fails with "Could NOT find Ogg". Building group by group keeps
# the parallelism inside each library, where it is safe.
# ============================================================================
set -euo pipefail

SRC=/root/mkxp-z
ARCH=armv7old
LINUX="$SRC/linux"
DL="$LINUX/downloads/$ARCH"
PREFIX="$LINUX/build-$ARCH"
STUBS=/root/xsysroot
J=$(nproc)

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    - %s\n' "$*"; }

cd "$LINUX"
# shellcheck disable=SC1090
source "./target-$ARCH.sh"
export ARCH_CFLAGS CC

mk() { make ARCH="$ARCH" -j"$J" "$@"; }

log "Creating prefix directories"
mk init_dirs

# ---------------------------------------------------------------------------
log "zlib 1.3.1"
# ---------------------------------------------------------------------------
# mkxp-z's Makefile has no rule for zlib -- upstream expects the distro to
# provide it, which a cross sysroot does not. libpng and Ruby both need it.
( cd "$DL/zlib"
  CC="$CC" CFLAGS="-O3 $ARCH_CFLAGS" ./configure --prefix="$PREFIX" --static >/dev/null
  make -j"$J" >/dev/null && make install >/dev/null )
note "$(ls -la "$PREFIX/lib/libz.a" | awk '{print $NF, $5" bytes"}')"

# ---------------------------------------------------------------------------
log "bzip2 1.0.8"
# ---------------------------------------------------------------------------
# Same story as zlib. bzip2 has a hand-written Makefile, so the cross tools
# are passed in as variables rather than via ./configure.
( cd "$DL/bzip2"
  make -j"$J" libbz2.a \
      CC="$CC" AR=arm-linux-gnueabihf-ar RANLIB=arm-linux-gnueabihf-ranlib \
      CFLAGS="-Wall -Winline -O2 -D_FILE_OFFSET_BITS=64 $ARCH_CFLAGS" >/dev/null
  cp libbz2.a "$PREFIX/lib/"; cp bzlib.h "$PREFIX/include/" )
note "libbz2.a installed"

# ---------------------------------------------------------------------------
log "alsa-lib 1.2.11  (THE audio fix)"
# ---------------------------------------------------------------------------
# ArkOS uses ALSA. Without alsa-lib present at configure time, both SDL2 and
# OpenAL Soft silently build with only the OSS backend, and the engine dies
# on the handheld with "Could not detect an available audio device" after
# SDL logs "dsp: No such audio device". Built shared-only so that anything
# linking it links dynamically and resolves to the DEVICE's own libasound.
( cd "$DL/alsa-lib"
  autoreconf -vif >/dev/null 2>&1
  ./configure --host=arm-linux-gnueabihf --prefix="$PREFIX" \
              --enable-shared --disable-static --disable-python \
              CC="$CC" CFLAGS="-O2 $ARCH_CFLAGS" >/dev/null
  make -j"$J" >/dev/null && make install >/dev/null )
test -f "$PREFIX/include/alsa/asoundlib.h" || { echo "FATAL: alsa headers missing"; exit 1; }
test -e "$PREFIX/lib/libasound.so"         || { echo "FATAL: libasound.so missing"; exit 1; }
note "$(basename "$(readlink -f "$PREFIX/lib/libasound.so")")"

# ---------------------------------------------------------------------------
log "Installing GPU detection stubs into the cross prefix"
# ---------------------------------------------------------------------------
# SDL2's CheckKMSDRM() does pkg_check_modules(PKG_KMSDRM libdrm gbm egl); these
# .pc files are what make that succeed. See 02-gpu-stubs.sh for why stubs are
# sound here.
cp "$STUBS"/lib/pkgconfig/{libdrm,gbm,egl}.pc "$PREFIX/lib/pkgconfig/"
note "libdrm.pc gbm.pc egl.pc"

# ---------------------------------------------------------------------------
log "libogg  (built alone first, to dodge the configure-order race)"
# ---------------------------------------------------------------------------
mk libogg >/dev/null
note "libogg.a"

log "libvorbis + libtheora"
mk libvorbis >/dev/null && mk libtheora >/dev/null
note "libvorbis.a libtheora.a"

# ---------------------------------------------------------------------------
log "libpng  (with the cross-compile zlib version-check workaround)"
# ---------------------------------------------------------------------------
# Run only libpng's ./configure first, so pnglibconf.h exists...
mk "$DL/libpng/Makefile" >/dev/null
# ...then neutralise its zlib version cross-check. libpng records the ZLIB_VERNUM
# it saw while generating pnglibconf.h and re-asserts it at compile time:
#     #if PNG_ZLIB_VERNUM != 0 && PNG_ZLIB_VERNUM != ZLIB_VERNUM
#     #  error The include path of <zlib.h> is incorrect
# Cross-compiling, generation picks up a different zlib.h than the build does,
# so the two disagree (0x1300 vs our target's 0x1310). Setting the recorded
# value to 0 is libpng's own documented escape hatch ("or we must be using
# pnglibconf.h.prebuilt") and disables only this advisory check -- every other
# configured option is left exactly as ./configure decided.
if [ ! -f "$DL/libpng/pnglibconf.h" ]; then
    cp "$DL/libpng/scripts/pnglibconf.h.prebuilt" "$DL/libpng/pnglibconf.h"
fi
sed -i -E 's/^#define PNG_ZLIB_VERNUM .*/#define PNG_ZLIB_VERNUM 0/' "$DL/libpng/pnglibconf.h"
grep -q '^#define PNG_ZLIB_VERNUM 0$' "$DL/libpng/pnglibconf.h" \
    || { echo "FATAL: could not neutralise PNG_ZLIB_VERNUM"; exit 1; }
mk libpng >/dev/null
note "libpng.a"

log "pixman + physfs"
mk pixman >/dev/null && mk physfs >/dev/null
note "libpixman-1.a libphysfs.a"

# ---------------------------------------------------------------------------
log "SDL2  (video: KMSDRM, audio: ALSA)"
# ---------------------------------------------------------------------------
mk sdl2 > /tmp/sdl2-build.log 2>&1
grep -E "SDL_(KMSDRM|ALSA|OSS|X11) " /tmp/sdl2-build.log | sed 's/^--/    /' || true
# Fail loudly instead of shipping another silently video-less or audio-less
# binary: verify the driver sources actually made it into the archive.
for want in kmsdrm alsa; do
    if ! ar t "$PREFIX/lib/libSDL2.a" | grep -qi "$want"; then
        echo "FATAL: SDL2 built WITHOUT $want support"; exit 1
    fi
done
note "verified: SDL2 contains both kmsdrm and alsa objects"

log "SDL2_image, SDL_sound, freetype, SDL2_ttf"
mk sdl2image >/dev/null && mk sdlsound >/dev/null
mk freetype >/dev/null && mk sdl2ttf >/dev/null
note "libSDL2_image.a libSDL2_sound.a libfreetype.a libSDL2_ttf.a"

# ---------------------------------------------------------------------------
log "OpenAL Soft  (ALSA backend required)"
# ---------------------------------------------------------------------------
mk openal > /tmp/openal-build.log 2>&1
grep -iE "alsa" /tmp/openal-build.log | head -5 || true
if ! ar t "$PREFIX/lib/libopenal.a" | grep -qi alsa; then
    echo "FATAL: OpenAL built WITHOUT the ALSA backend"; exit 1
fi
note "verified: libopenal.a contains the ALSA backend"

log "OpenSSL, FluidSynth, uchardet"
mk openssl >/dev/null && mk fluidsynth >/dev/null && mk uchardet >/dev/null
note "libssl.a libfluidsynth.a libuchardet.a"

# ---------------------------------------------------------------------------
log "Ruby 3.1.3  (slowest step by far)"
# ---------------------------------------------------------------------------
# Fetch + autoreconf only, so bundled_gems can be neutered before the build.
mk "$DL/ruby/configure" >/dev/null
# Ruby's build downloads its bundled gems from rubygems.org, which is not
# reachable here. Every one of them (minitest, rake, rbs, net-*, debug, ...)
# is a development/testing convenience; none is needed to execute RGSS game
# scripts, so the list is simply emptied.
printf '%s\n' '# gem-name version-to-bundle repository-url [optional-commit-hash-to-test-or-defaults-to-v-version]' \
    > "$DL/ruby/gems/bundled_gems"
note "bundled gems list emptied"
mk ruby >/dev/null

# Upstream ships a documented workaround for this in linux/vars.sh: Ruby's
# `make install DESTDIR=$PREFIX` writes into $PREFIX/$PREFIX instead of
# $PREFIX. Flatten it here, and delete the nested copy -- if it is left in
# place, vars.sh re-copies its stale contents over the real prefix every
# single time it is sourced, silently reverting the .pc edit below.
# $PREFIX is itself an absolute path, so DESTDIR-prefixing it yields
# "$PREFIX$PREFIX" -- not "$PREFIX/root$PREFIX".
NESTED="$PREFIX$PREFIX"
if [ -d "$NESTED" ]; then
    cp -a "$NESTED/." "$PREFIX/"
    rm -rf "${PREFIX:?}/root"
    note "flattened doubly-nested Ruby install"
fi
test -f "$PREFIX/lib/libruby-static.a" || { echo "FATAL: libruby-static.a missing"; exit 1; }

# Ruby is linked SHARED here, on purpose. libruby-static.a contains only the
# ~88 core interpreter objects; the standard-library C extensions (zlib,
# psych, stringio, ...) are linked exclusively into libruby.so. Pointing
# mkxp-z at -lruby-static therefore yields an engine whose Ruby cannot
#     require 'zlib'
# which RPG Maker XP games do while decompressing their script data -- the
# game then dies at startup with a LoadError. So keep upstream's shared
# linkage and ship libruby.so.3.1 next to the executable instead.
test -f "$PREFIX/lib/libruby.so.3.1.3" || { echo "FATAL: libruby.so missing"; exit 1; }
grep -q "LIBRUBYARG_SHARED} \${LIBS}" "$PREFIX/lib/pkgconfig/ruby-3.1.pc" \
    || { echo "FATAL: ruby-3.1.pc is not set to shared linkage"; exit 1; }
note "ruby linked shared (keeps the zlib/psych/... extensions)"

log "All dependencies built"
ls "$PREFIX/lib/"*.a | xargs -n1 basename | tr '\n' ' '; echo
