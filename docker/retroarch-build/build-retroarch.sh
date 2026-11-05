#!/bin/bash
# Cross-build RetroArch for the dArkOS image, in the Debian trixie container:
# both frontends, from the release tag plus patches/, into rootfs/dArkOS.
#
#   docker/retroarch-build/build-retroarch.sh [--no-install]
#
# patches/0001 carries what the image depends on (console_detect rotation,
# menu and widget scale, joypad order, reboot/shutdown entries); a build
# without it has a half-size menu and a differently ordered joypad. Sources
# and objects stay in build-work/retroarch, the binaries also land there.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
TAG=v1.22.2
IMAGE=arkos4clone-retroarch-build
INSTALL=yes
[[ "${1:-}" == "--no-install" ]] && INSTALL=no

mkdir -p "$REPO/build-work/retroarch"
docker image inspect "$IMAGE" >/dev/null 2>&1 ||
  docker build -q -t "$IMAGE" "$REPO/docker/retroarch-build" >/dev/null

docker run --rm -e TAG="$TAG" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$REPO/docker/retroarch-build:/in:ro" \
  -v "$REPO/build-work/retroarch:/work" \
  "$IMAGE" bash -euo pipefail -c '
    trap "chown -R $HOST_UID:$HOST_GID /work" EXIT
    export TMPDIR=/work/tmp   # LTO temporaries are large
    mkdir -p "$TMPDIR"
    git config --global --add safe.directory "*"
    [[ -d /work/src/.git ]] || git clone -q --filter=blob:none \
      https://github.com/libretro/RetroArch /work/src

    build() {
      local triplet=$1 out=$2 cpu=$3; shift 3
      local tree=/work/tree-$out
      rm -rf "$tree"
      git -C /work/src worktree prune
      git -C /work/src worktree add -q --detach "$tree" "$TAG"
      git -C "$tree" apply /in/patches/*.patch

      mkdir -p "$tree/.rga/rga"
      cp /in/rga/*.h "$tree/.rga/rga/"
      $triplet-gcc -shared -fPIC -Wl,-soname,librga.so.2 \
        -o "$tree/.rga/librga.so" /in/rga/rga-stub.c

      local opt="-O3 $cpu -fomit-frame-pointer -flto=auto"
      opt+=" -ffunction-sections -fdata-sections -fno-semantic-interposition"
      opt+=" -I$tree/.rga"

      cd "$tree"
      PKG_CONFIG_LIBDIR=/usr/lib/$triplet/pkgconfig:/usr/share/pkgconfig \
      CFLAGS="$opt" CXXFLAGS="$opt" \
      LDFLAGS="-L$tree/.rga -Wl,-O1,--as-needed,--gc-sections,--hash-style=gnu" \
      ./configure --host=$triplet --prefix=/usr "$@" \
        --enable-kms --enable-egl --enable-odroidgo2 --enable-udev \
        --enable-opengles --enable-opengles3 --enable-opengles3_1 \
        --enable-opengles3_2 --enable-alsa --enable-freetype --enable-threads \
        --enable-networking --enable-ozone --enable-sdl2 \
        --disable-opengl1 --disable-vulkan --disable-wayland --disable-x11 \
        --disable-pulse --disable-ffmpeg --disable-mpv --disable-qt \
        --disable-oss --disable-al --disable-jack --disable-sixel \
        --disable-caca --disable-v4l2 --disable-videoprocessor \
        >/work/configure-$out.log 2>&1
      make -j"$(nproc)" >/work/make-$out.log 2>&1
      $triplet-strip -s retroarch -o /work/$out
      echo "built $out: $(stat -c%s /work/$out) bytes"
    }

    build aarch64-linux-gnu retroarch "-mcpu=cortex-a35"
    build arm-linux-gnueabihf retroarch32 \
      "-mcpu=cortex-a35 -mfpu=neon-fp-armv8 -mfloat-abi=hard" \
      --enable-neon --enable-floathard
  '

if [[ $INSTALL == yes ]]; then
  install -m 755 "$REPO/build-work/retroarch/retroarch" \
    "$REPO/build-work/retroarch/retroarch32" \
    "$REPO/rootfs/dArkOS/opt/retroarch/bin/"
  echo "installed into rootfs/dArkOS/opt/retroarch/bin"
fi
