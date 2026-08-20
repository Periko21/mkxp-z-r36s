#!/usr/bin/env bash
# ============================================================================
# 02-gpu-stubs.sh
#
# Builds a "stub sysroot" of libdrm / libgbm / EGL headers + libraries so that
# SDL2's CheckKMSDRM() succeeds at configure time and compiles its KMS/DRM
# video driver in. Without this, SDL2 silently builds with only the "dummy"
# and "offscreen" video drivers and every window creation fails with
# "Could not initialize OpenGL / GLES library".
#
# WHY STUBS ARE SAFE HERE: SDL2 is configured with SDL_KMSDRM_SHARED=ON, which
# means it never links against libdrm/libgbm/libEGL. It only needs (a) the
# headers, to compile, and (b) the SONAME strings, which it bakes in and
# dlopen()s at runtime against the DEVICE's own real drivers. CMake derives
# those SONAMEs purely from the library FILENAMES, so amd64 binaries with the
# right names serve fine as detection stand-ins -- they are never executed,
# never linked, and never shipped.
# ============================================================================
set -euo pipefail

SYSROOT=/root/xsysroot
WORK=/root/build/gpu-stub-work

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Downloading libdrm / mesa-gbm / EGL development packages"
rm -rf "$WORK"; mkdir -p "$WORK"
cd "$WORK"
# Downloaded one at a time and tolerantly: exact package names/versions drift
# between Ubuntu releases, and we only need enough of them to supply headers.
for p in libdrm-dev libdrm2 libgbm-dev libgbm1 \
         libegl-dev libegl1 libegl1-mesa-dev libglvnd-dev mesa-common-dev; do
    apt-get download "$p" >/dev/null 2>&1 || echo "    (skipped $p)"
done
ls ./*.deb >/dev/null 2>&1 || { echo "FATAL: no packages downloaded"; exit 1; }
mkdir -p extracted
for deb in *.deb; do dpkg-deb -x "$deb" extracted/; done

log "Assembling stub sysroot at $SYSROOT"
rm -rf "$SYSROOT"; mkdir -p "$SYSROOT/include" "$SYSROOT/lib/pkgconfig"
SRC="$WORK/extracted/usr"

cp -r "$SRC/include/EGL"      "$SYSROOT/include/"
cp -r "$SRC/include/GLES"     "$SYSROOT/include/" 2>/dev/null || true
cp -r "$SRC/include/libdrm"   "$SYSROOT/include/"
cp    "$SRC/include/gbm.h"    "$SYSROOT/include/"
cp    "$SRC/include/xf86drm.h" "$SRC/include/xf86drmMode.h" "$SYSROOT/include/"

# Ubuntu ships no KHR/khrplatform.h (EGL/egl.h needs it); take it from Khronos.
mkdir -p "$SYSROOT/include/KHR"
curl -fsSL -o "$SYSROOT/include/KHR/khrplatform.h" \
  https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/main/api/KHR/khrplatform.h

# Copy with -a so the symlink chain (libfoo.so -> .so.N -> .so.N.M.P) survives:
# CMake resolves it to the real file and regex-strips the trailing version to
# derive the SONAME it will dlopen at runtime.
shopt -s nullglob
for f in "$SRC"/lib/x86_64-linux-gnu/libdrm.so* \
         "$SRC"/lib/x86_64-linux-gnu/libgbm.so* \
         "$SRC"/lib/x86_64-linux-gnu/libEGL.so*; do
    # skip libdrm_intel/libdrm_amdgpu/etc, we only want the plain ones
    case "$(basename "$f")" in libdrm_*) continue ;; esac
    cp -a "$f" "$SYSROOT/lib/"
done
shopt -u nullglob
# A dangling symlink would make CMake's find_library() reject the whole stub.
for f in "$SYSROOT"/lib/*.so*; do
    [ -e "$f" ] || { echo "FATAL: dangling symlink $f"; exit 1; }
done

log "Writing pkg-config files"
write_pc() {
    cat > "$SYSROOT/lib/pkgconfig/$1.pc" <<EOF
prefix=$SYSROOT
includedir=\${prefix}/include
libdir=\${prefix}/lib

Name: $1
Description: $3 (cross-compile detection stub; dlopen'd for real at runtime)
Version: $4
Libs: -L\${libdir} $2
Cflags: -I\${includedir}$5
EOF
}
write_pc libdrm "-ldrm" "Userspace interface to kernel DRM services" "2.4.125" " -I\${includedir}/libdrm"
write_pc gbm    "-lgbm" "Mesa gbm library"                           "25.2.8"  ""
write_pc egl    "-lEGL" "EGL library and headers"                    "1.5"     ""

log "Verifying"
ls "$SYSROOT/lib/"
PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig" pkg-config --cflags --libs libdrm gbm egl
log "GPU stub sysroot ready"
