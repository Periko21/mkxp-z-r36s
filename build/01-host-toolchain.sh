#!/usr/bin/env bash
# ============================================================================
# 01-host-toolchain.sh
#
# Rebuilds the cross-compilation host environment for the R36S / ArkOS port.
#
# KEY DECISION: we deliberately use Ubuntu 20.04 "focal"'s gcc-9 armhf cross
# toolchain (glibc 2.31) rather than the distro-default one (glibc 2.39).
# The device's own glibc is older than 2.39, and a binary built against 2.39
# fails at runtime with "GLIBC_2.3x version not found". Bundling our own newer
# glibc alongside the binary "fixes" that but then breaks dlopen() of the
# device's GPU drivers, because those pull in the device's OWN libpthread,
# which resolves GLIBC_PRIVATE symbols only against its exact sibling libc.
# Matching the toolchain's glibc to the device's is the only clean fix.
# ============================================================================
set -euo pipefail

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

log "Installing host build tools"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y --no-install-recommends \
    meson libtool libtool-bin xxd qemu-user-static \
    binutils-arm-linux-gnueabihf bison >/dev/null

log "Adding Ubuntu 20.04 (focal) apt source, amd64 only"
# arch=amd64 is required: archive.ubuntu.com has no armhf pool (that lives on
# ports.ubuntu.com, which is not reachable from this sandbox), so an
# unrestricted entry makes 'apt-get update' fail on a 404.
cat > /etc/apt/sources.list.d/focal-cross.list <<'EOF'
deb [arch=amd64] http://archive.ubuntu.com/ubuntu focal main universe
EOF
APTOPT=(-o Dir::Etc::sourcelist=sources.list.d/focal-cross.list -o Dir::Etc::sourceparts=-)
apt-get update "${APTOPT[@]}" >/dev/null

log "Installing focal armhf sysroot (glibc 2.31) + gcc-9 cross compiler"
# libc and the gcc runtime libs must be downgraded in ONE transaction, since
# the newer runtime libs declare "Depends: libc6-armhf-cross (>= 2.39)".
apt-get "${APTOPT[@]}" install --no-install-recommends --allow-downgrades -y \
    libc6-armhf-cross=2.31-0ubuntu7cross1 \
    libc6-dev-armhf-cross=2.31-0ubuntu7cross1 \
    linux-libc-dev-armhf-cross=5.4.0-21.25cross1 \
    libstdc++6-armhf-cross=10-20200411-0ubuntu1cross1 \
    libgcc-s1-armhf-cross=10-20200411-0ubuntu1cross1 \
    libgomp1-armhf-cross=10-20200411-0ubuntu1cross1 \
    libatomic1-armhf-cross=10-20200411-0ubuntu1cross1 >/dev/null

apt-get "${APTOPT[@]}" install --no-install-recommends -y \
    gcc-9-arm-linux-gnueabihf g++-9-arm-linux-gnueabihf >/dev/null

log "Creating unversioned cross-compiler symlinks -> gcc-9"
# mkxp-z's cmake/meson cross files hardcode the unversioned names.
for t in gcc g++ cpp gcc-ar gcc-nm gcc-ranlib; do
    ln -sf "arm-linux-gnueabihf-${t}-9" "/usr/bin/arm-linux-gnueabihf-${t}"
done

log "Verifying"
arm-linux-gnueabihf-gcc --version | head -1
arm-linux-gnueabihf-g++ --version | head -1
printf 'target glibc: '
strings /usr/arm-linux-gnueabihf/lib/libc.so.6 | grep -oE 'release version [0-9.]+' | head -1
echo 'int main(void){return 0;}' > /tmp/_t.c
arm-linux-gnueabihf-gcc /tmp/_t.c -o /tmp/_t
file /tmp/_t | sed 's/, BuildID.*//'
rm -f /tmp/_t /tmp/_t.c

log "Host toolchain ready"
