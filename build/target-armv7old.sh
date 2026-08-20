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
