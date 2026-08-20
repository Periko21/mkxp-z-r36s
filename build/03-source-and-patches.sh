#!/usr/bin/env bash
# ============================================================================
# 03-source-and-patches.sh
#
# Clones mkxp-z and applies every patch this port needs. Two broad categories:
#
#   (1) SANDBOX WORKAROUNDS -- this build host can only reach github.com and
#       archive.ubuntu.com. Several of mkxp-z's vendored dependencies live on
#       gitlab.freedesktop.org / rubygems.org / skia.googlesource.com, so we
#       substitute equivalent sources or drop optional components.
#
#   (2) TARGET FIXES -- things genuinely required to make the engine work on
#       an R36S handheld (KMS/DRM video, ALSA audio, correct glibc linkage).
# ============================================================================
set -euo pipefail

SRC=/root/mkxp-z
ARCH=armv7old
DL="$SRC/linux/downloads/$ARCH"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    - %s\n' "$*"; }

# Small helper: exact string replacement in a file, erroring if not found.
# Safer than sed for multi-line C/meson/Makefile snippets.
patch_file() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys, pathlib
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
text = p.read_text()
if old not in text and new in text:
    print(f"    (already patched: {path})"); sys.exit(0)
if text.count(old) != 1:
    sys.exit(f"FATAL: expected exactly 1 match in {path}, found {text.count(old)}")
p.write_text(text.replace(old, new))
PY
}

# ---------------------------------------------------------------------------
log "Cloning mkxp-z"
# ---------------------------------------------------------------------------
rm -rf "$SRC"
git clone -q --recurse-submodules https://github.com/mkxp-z/mkxp-z "$SRC"
mkdir -p "$DL"

# ---------------------------------------------------------------------------
log "PATCH 1: new cross-target definition (linux/target-armv7old.sh)"
# ---------------------------------------------------------------------------
# Mirrors the upstream target-armv7.sh but pins the gcc-9 / glibc-2.31
# toolchain and uses its own ARCH so it never collides with a stock build.
cat > "$SRC/linux/target-$ARCH.sh" <<'EOF'
#!/usr/bin/env bash
# Cross-target for the R36S / ArkOS handheld (Rockchip RK3326, 32-bit armhf).
#
# Identical to upstream's target-armv7.sh except that ARCH is distinct, so the
# unversioned arm-linux-gnueabihf-gcc symlink (pointed at gcc-9 / glibc 2.31 by
# 01-host-toolchain.sh) is what actually gets used. Building against a glibc
# NEWER than the device's produces a binary that either won't start at all
# ("GLIBC_2.3x not found") or, if you bundle a newer glibc to compensate,
# can't dlopen the device's GPU drivers (GLIBC_PRIVATE symbol mismatch in the
# device's own libpthread). Matching the device's glibc avoids both.
export ARCH=armv7old
export ARCH_OPENSSL=linux-armv4
export ARCH_CFLAGS="-mcpu=generic-armv7-a+vfpv3-d16 -mtune=generic-armv7-a+vfpv3-d16"
export ARCH_CONFIGURE=arm-linux-gnueabihf
export CC="$ARCH_CONFIGURE-gcc"
export ARCH_CMAKE_TOOLCHAIN=toolchain-arm32.cmake
export ARCH_MESON_TOOLCHAIN=meson-armv7.txt
EOF
note "created linux/target-$ARCH.sh"

# ---------------------------------------------------------------------------
log "PATCH 2: SDL2 build flags (KMS/DRM video + ALSA audio, no D-Bus)"
# ---------------------------------------------------------------------------
# - D-Bus lives on gitlab.freedesktop.org (unreachable) and only provides
#   desktop power-management integration, meaningless on a handheld.
# - KMSDRM is THE video driver for a console with no X11/Wayland. It is only
#   compiled in if libdrm+gbm+egl are detected, hence the stub sysroot.
# - ALSA is THE audio driver on ArkOS. Without it SDL2 falls back to OSS
#   (/dev/dsp), which does not exist -> "No such audio device".
# Both are built _SHARED (dlopen'd at runtime against the device's own
# libraries), so the stubs never end up in the shipped binary.
patch_file "$SRC/linux/Makefile" \
'$(DOWNLOADS)/sdl2/cmakebuild/Makefile: $(DOWNLOADS)/sdl2/CMakeLists.txt $(LIBDIR)/libdbus-1.so.3.38.3
	cd $(DOWNLOADS)/sdl2; \
	mkdir cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no -DSDL_DBUS=yes' \
'$(DOWNLOADS)/sdl2/cmakebuild/Makefile: $(DOWNLOADS)/sdl2/CMakeLists.txt
	cd $(DOWNLOADS)/sdl2; \
	mkdir cmakebuild; cd cmakebuild; \
	$(CMAKE) -DBUILD_SHARED_LIBS=no \
	-DSDL_DBUS=no \
	-DSDL_KMSDRM=ON -DSDL_KMSDRM_SHARED=ON \
	-DSDL_ALSA=ON -DSDL_ALSA_SHARED=ON'
note "SDL2: KMSDRM + ALSA on (shared/dlopen), D-Bus off"

# ---------------------------------------------------------------------------
log "PATCH 3: OpenAL Soft must have the ALSA backend"
# ---------------------------------------------------------------------------
# mkxp-z aborts with "Could not detect an available audio device" if
# alcOpenDevice() returns null, which is what happens when OpenAL Soft was
# built with no backend the device actually has. REQUIRE_ALSA makes a missing
# ALSA a hard build error instead of a silent runtime failure discovered an
# hour later on the handheld.
patch_file "$SRC/linux/Makefile" \
'OPENAL_FLAGS := -DALSOFT_CPUEXT_NEON=no ${OPENAL_FLAGS}' \
'OPENAL_FLAGS := -DALSOFT_CPUEXT_NEON=no -DALSOFT_BACKEND_ALSA=ON -DALSOFT_REQUIRE_ALSA=ON ${OPENAL_FLAGS}'
note "OpenAL: ALSA backend required"

# ---------------------------------------------------------------------------
log "PATCH 4: drop the separate libiconv dependency"
# ---------------------------------------------------------------------------
# GNU libiconv is hosted on ftp.gnu.org (unreachable) and isn't packaged by
# Ubuntu at all -- because on glibc targets it's redundant: glibc provides
# iconv_open/iconv/iconv_close natively. mkxp-z only ever calls those three,
# never locale_charset (which would need the real GNU libcharset).
patch_file "$SRC/linux/Makefile" \
'fluidsynth uchardet iconv' \
'fluidsynth uchardet'
# libcharset goes too: it only exists as part of GNU libiconv, and the symbol
# mkxp-z would want from it (locale_charset) is never actually called.
patch_file "$SRC/src/meson.build" \
"    bz2 = compilers['cpp'].find_library('bz2')
    # FIXME: Specifically asking for static doesn't work if iconv isn't
    # installed in the system prefix somewhere
    iconv = compilers['cpp'].find_library('iconv')
    global_dependencies += compilers['cpp'].find_library('charset')" \
"    bz2 = compilers['cpp'].find_library('bz2')
    # On a glibc target, iconv_open/iconv/iconv_close come straight from libc,
    # so there is no separate -liconv/-lcharset to link (and GNU libiconv is
    # not obtainable here anyway). mkxp-z only calls those three functions.
    iconv = declare_dependency()"
note "iconv now satisfied by glibc"

# ---------------------------------------------------------------------------
log "PATCH 5: disable SDL2_image's exotic codecs"
# ---------------------------------------------------------------------------
# JPEG-XL pulls in libjxl, whose 'skcms' submodule lives on
# skia.googlesource.com (unreachable). RPG Maker XP games only ever ship
# PNG/JPG, so JXL/AVIF/WEBP/TIF are pure dead weight here. They must be
# switched off EXPLICITLY: SDL2IMAGE_VENDORED=yes auto-enables any format
# whose submodule directory merely exists, even when it's an empty stub.
patch_file "$SRC/linux/Makefile" \
'	-DSDL2IMAGE_JXL=yes \
	-DSDL2IMAGE_JXL_SHARED=no \' \
'	-DSDL2IMAGE_JXL=no \
	-DSDL2IMAGE_AVIF=no \
	-DSDL2IMAGE_WEBP=no \
	-DSDL2IMAGE_TIF=no \'
# The meson side must stop demanding the CMake targets those codecs export.
python3 - "$SRC/src/meson.build" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); t = p.read_text()
n, cnt = re.subn(r"modules: \[[^\]]*SDL2_image::SDL2_image-static[^\]]*\]",
                 "modules: ['SDL2_image::SDL2_image-static']", t)
if cnt == 0: sys.exit("FATAL: no SDL2_image modules list found")
p.write_text(n); print(f"    - rewrote {cnt} SDL2_image module list(s)")
PY
note "SDL2_image: PNG/JPG only"

# ---------------------------------------------------------------------------
log "PATCH 6: GLES headers + rpath (root meson.build)"
# ---------------------------------------------------------------------------
# SDL_opengles2.h #includes the system Khronos GLES2 headers, which no armhf
# cross sysroot provides. SDL ships its own fallback copies behind this macro.
patch_file "$SRC/meson.build" \
"if gfx_backend == 'gles'
    # Needs to be manually set up for now
    global_args += '-DGLES2_HEADER'" \
"if gfx_backend == 'gles'
    # Needs to be manually set up for now
    global_args += '-DGLES2_HEADER'
    # No system Khronos GLES2/EGL headers exist in this cross sysroot, so use
    # the fallback copies SDL2 bundles for exactly this situation.
    global_args += '-DSDL_USE_BUILTIN_OPENGL_DEFINITIONS'"

# We link normally against the DEVICE's glibc (see target-armv7old.sh), and add
# only a plain rpath so our own libstdc++/libgomp/libgcc_s -- which may be newer
# than the console's -- are found next to the binary. Deliberately NOT an
# ELF-interpreter override: replacing the loader/libc is what previously broke
# dlopen() of the device's GPU drivers.
patch_file "$SRC/meson.build" \
"# ====================
# Main source
# ====================" \
"# Our own libstdc++/libgomp/libgcc_s ship next to the binary in case the
# console's are older than what this C++14 build needs. A plain rpath is
# enough and, unlike a --dynamic-linker override, leaves the device's own
# libc/libpthread untouched so its GPU drivers still dlopen correctly.
if host_system == 'linux'
    global_link_args += [
        '-Wl,-rpath,/roms/ports/mkxp',
        # --as-needed drops DT_NEEDED entries for libraries no symbol is
        # actually resolved from. Without it the link line's -lasound leaves a
        # hard runtime dependency on the console having libasound.so.2, even
        # though OpenAL Soft only ever dlopen()s it. With it, a console lacking
        # ALSA still starts the engine and the launcher's silent-audio fallback
        # can take over, instead of the binary refusing to load at all.
        '-Wl,--as-needed',
    ]
endif

# ====================
# Main source
# ===================="
note "GLES fallback headers + /roms/ports/mkxp rpath"

# ---------------------------------------------------------------------------
log "PATCH 7: opt-in verbose SDL logging (src/main.cpp)"
# ---------------------------------------------------------------------------
# The handheld is the only place several of these failures reproduce, and its
# only debugging channel is the log file the launcher writes. This turns that
# log from "kmsdrm not available" into the actual reason.
patch_file "$SRC/src/main.cpp" \
"    /* initialize SDL first */" \
"    /* Opt-in verbose logging, enabled by the launcher script, so that video
     * and audio init failures on the handheld are diagnosable from its log. */
    if (SDL_getenv(\"MKXPZ_SDL_DEBUG\"))
      SDL_LogSetAllPriority(SDL_LOG_PRIORITY_DEBUG);

    /* initialize SDL first */"
note "MKXPZ_SDL_DEBUG env var"

# ---------------------------------------------------------------------------
log "PATCH 8: build FluidSynth without any sound-card output drivers"
# ---------------------------------------------------------------------------
# mkxp-z uses FluidSynth purely as a MIDI *synthesiser*, rendering into a
# buffer that OpenAL then plays; FluidSynth never needs to touch the sound
# card itself. Left enabled, its ALSA driver adds "Requires.private: alsa" to
# fluidsynth.pc, which drags -lasound onto the static link line and leaves a
# hard DT_NEEDED on libasound.so.2 even though not one snd_* symbol is used.
patch_file "$SRC/linux/Makefile" \
'-Denable-systemd=no -Denable-dbus=no' \
'-Denable-systemd=no -Denable-dbus=no -Denable-alsa=no -Denable-oss=no -Denable-pulseaudio=no'
note "FluidSynth: synthesis only, no audio output drivers"

# ---------------------------------------------------------------------------
log "PATCH 10: Nintendo-style face buttons"
# ---------------------------------------------------------------------------
# mkxp-z's PC default puts confirm on the bottom face button and cancel on the
# right one. Every other emulator on an ArkOS handheld follows the Game Boy
# convention (right = confirm), so the stock mapping feels inverted there.
# There is no way to rebind on the device either: the F1 settings menu needs a
# keyboard, and it opens a second SDL window, which KMS/DRM cannot display.
patch_file "$SRC/src/input/keybindings.cpp" \
'	{ SDL_CONTROLLER_BUTTON_B, Input::B  },
	{ SDL_CONTROLLER_BUTTON_A, Input::C },' \
'	{ SDL_CONTROLLER_BUTTON_B, Input::C  },
	{ SDL_CONTROLLER_BUTTON_A, Input::B  },'
note "right button = confirm, bottom button = cancel/menu"

# ---------------------------------------------------------------------------
log "Pre-staging dependencies whose upstream hosts are unreachable"
# ---------------------------------------------------------------------------
cd "$DL"

# pixman: gitlab.freedesktop.org -> identical release tarball from Ubuntu.
note "pixman 0.42.2 (from archive.ubuntu.com)"
curl -fsSL -o pixman.tar.gz \
  https://archive.ubuntu.com/ubuntu/pool/main/p/pixman/pixman_0.42.2.orig.tar.gz
rm -rf pixman && mkdir pixman && tar xzf pixman.tar.gz -C pixman --strip-components=1
# The Makefile invokes ./autogen.sh; the tarball already ships a generated
# ./configure, so hand it straight through.
printf '#!/bin/sh\nexec ./configure "$@"\n' > pixman/autogen.sh
chmod +x pixman/autogen.sh

# uchardet: also gitlab.freedesktop.org.
note "uchardet 0.0.8 (from archive.ubuntu.com)"
curl -fsSL -o uchardet.tar.xz \
  https://archive.ubuntu.com/ubuntu/pool/main/u/uchardet/uchardet_0.0.8.orig.tar.xz
rm -rf uchardet && mkdir uchardet && tar xJf uchardet.tar.xz -C uchardet --strip-components=1

# zlib and bzip2 have no rule in mkxp-z's Makefile at all (it expects them from
# the distro), so we fetch and build them ourselves in the next phase.
note "zlib 1.3.1 (from github)"
curl -fsSL -o zlib.tar.gz \
  https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
rm -rf zlib && mkdir zlib && tar xzf zlib.tar.gz -C zlib --strip-components=1

note "bzip2 1.0.8 (from archive.ubuntu.com)"
curl -fsSL -o bzip2.tar.gz \
  https://archive.ubuntu.com/ubuntu/pool/main/b/bzip2/bzip2_1.0.8.orig.tar.gz
rm -rf bzip2 && mkdir bzip2 && tar xzf bzip2.tar.gz -C bzip2 --strip-components=1

note "alsa-lib 1.2.11 (from github)"
rm -rf alsa-lib
git clone -q --depth 1 -b v1.2.11 https://github.com/alsa-project/alsa-lib alsa-lib

# SDL_image: clone ourselves and init ONLY the submodules we kept enabled,
# because its external/download.sh unconditionally recurses into libjxl.
# SDL2 is pre-cloned so the KMS/DRM fixes can be applied before the dependency
# build ever compiles it.
note "SDL2 (mkxp-z fork) + KMS/DRM pageflip and latency fixes"
rm -rf sdl2
git clone -q https://github.com/mkxp-z/SDL sdl2 -b mkxp-z-2.28.1
python3 /root/build/patch-kmsdrm.py

# SDL_image: clone ourselves and init ONLY the submodules we kept enabled,
# because its external/download.sh unconditionally recurses into libjxl.
note "SDL_image (jpeg/libpng/zlib submodules only)"
rm -rf sdl2_image
git clone -q https://github.com/mkxp-z/SDL_image -b mkxp-z sdl2_image
git -C sdl2_image submodule update --init --depth 1 \
    external/jpeg external/libpng external/zlib >/dev/null

log "Source tree ready at $SRC"
