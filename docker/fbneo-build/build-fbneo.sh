#!/bin/bash
# Cross-build the FBNeo libretro core tuned for the RK3326 (Cortex-A35), in
# the Debian trixie container that builds ES (GCC 14), from a pinned
# libretro/FBNeo commit plus patches/.
#
#   docker/fbneo-build/build-fbneo.sh [--install]
#
# Output: build-work/fbneo/fbneo_a35_libretro.so (stripped). It is a separate
# core next to the image's fbneo and fbneo_plus. --install also puts it into
# rootfs/dArkOS as fbneo_a35_libretro.so.xz (large cores are stored
# compressed; clone_support.sh unpacks them) with fbneo_a35_libretro.info
# from this folder.
#
# Measured on the R36 Ultra, Raiden 2 attract mode, steady state: shipped
# fbneo_plus (GCC 5.4) 52.7 fps, this commit with GCC 14 and -mcpu=cortex-a35
# 54.0, with patches/0001 55.7; frames 600, 1800 and 3000 identical.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
COMMIT=a836e52
IMAGE=arkos4clone-es-build
OUT="$REPO/build-work/fbneo"
CORES="$REPO/rootfs/dArkOS/home/ark/.config/retroarch/cores"
INSTALL=no
[[ "${1:-}" == "--install" ]] && INSTALL=yes

mkdir -p "$OUT"
docker image inspect "$IMAGE" >/dev/null 2>&1 ||
  docker build -q -t "$IMAGE" "$REPO/docker/es-build" >/dev/null

docker run --rm -e COMMIT="$COMMIT" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$REPO/docker/fbneo-build:/in:ro" \
  -v "$OUT:/work" \
  "$IMAGE" bash -euo pipefail -c '
    trap "chown -R $HOST_UID:$HOST_GID /work" EXIT
    git config --global --add safe.directory "*"
    [[ -d /work/src/.git ]] || git clone -q --filter=blob:none \
      https://github.com/libretro/FBNeo /work/src
    git -C /work/src fetch -q origin "$COMMIT" 2>/dev/null || true
    tree=/work/tree
    rm -rf "$tree"
    git -C /work/src worktree prune
    git -C /work/src worktree add -q --detach "$tree" "$COMMIT"
    git -C "$tree" apply /in/patches/*.patch
    make -C "$tree/src/burner/libretro" -j"$(nproc)" platform=unix \
      CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++ AR=aarch64-linux-gnu-ar \
      PLATFORM_DEFINES="-mcpu=cortex-a35" > /work/make.log 2>&1 ||
      { grep -E "error" /work/make.log | head -20; exit 1; }
    aarch64-linux-gnu-strip --strip-unneeded \
      -o /work/fbneo_a35_libretro.so "$tree/src/burner/libretro/fbneo_libretro.so"
  '
echo "built $OUT/fbneo_a35_libretro.so"

if [[ "$INSTALL" == yes ]]; then
  xz -9 -T0 -c "$OUT/fbneo_a35_libretro.so" > "$CORES/fbneo_a35_libretro.so.xz"
  install -m 644 "$REPO/docker/fbneo-build/fbneo_a35_libretro.info" "$CORES/"
  echo "installed into $CORES"
fi
