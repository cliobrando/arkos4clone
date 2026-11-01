#!/usr/bin/env bash
# Build a complete dArkOS4Clone/ArkOS4Clone image with build_image.sh inside
# a Debian trixie container (same steps as the GitHub Actions job).
#
#   docker/build-image.sh [--upgrade] [source image]
#
#   --upgrade      upgrade the base image's Debian packages to the latest
#                  point release of its release before arkos4clone's files
#                  are injected (scripts/upgrade_rootfs.sh)
#   source image   default: dArkOS-download/dArkOS_G350_trixie_09022026.img
#
# The container runs --privileged with the host's /dev, because
# build_image.sh attaches the image as loop devices and mounts its
# partitions. With --upgrade it registers qemu-aarch64 and qemu-arm in
# binfmt_misc (host-wide) and removes them again afterwards if they were
# not there before.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UPGRADE=0
[ "${1:-}" = "--upgrade" ] && { UPGRADE=1; shift; }
SRC="$(realpath "${1:-$REPO/dArkOS-download/dArkOS_G350_trixie_09022026.img}")"
WORK="$REPO/build-work"
IMAGE=arkos4clone-image-build

[ -f "$SRC" ] || { echo "source image not found: $SRC" >&2; exit 1; }
case "$SRC" in "$REPO"/*) ;; *) echo "source image must be inside $REPO" >&2; exit 1;; esac
mkdir -p "$WORK"

docker build -q -t "$IMAGE" "$REPO/docker/image-build" >/dev/null

docker run --rm --privileged -v /dev:/dev -v "$REPO:$REPO" -w "$REPO" \
  -e ARKOS_UPGRADE_DEBIAN="$UPGRADE" -e SRC="$SRC" -e WORK="$WORK" -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  "$IMAGE" bash -euc '
    BINFMT=/proc/sys/fs/binfmt_misc
    registered=""
    if [ "$ARKOS_UPGRADE_DEBIAN" = 1 ]; then
      mountpoint -q $BINFMT || mount -t binfmt_misc binfmt_misc $BINFMT
      # F: the interpreter is opened now, so it also works inside the chroot.
      # armhf too: the image carries 32-bit packages (RetroArch32, cores)
      # whose install scripts run 32-bit binaries.
      reg() {  # name, magic, mask, interpreter
        [ -e $BINFMT/$1 ] && return 0
        printf "%s" ":$1:M::$2:$3:$4:F" > $BINFMT/register && registered="$registered $1"
      }
      reg qemu-aarch64 "\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00" \
        "\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" /usr/bin/qemu-aarch64-static
      reg qemu-arm "\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00" \
        "\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff" /usr/bin/qemu-arm-static
    fi
    cleanup() { for b in $registered; do echo -1 > $BINFMT/$b || true; done; chown -R "$HOST_UID:$HOST_GID" "$WORK" 2>/dev/null || true; }
    trap cleanup EXIT
    ./build_image.sh "$SRC" "$WORK" --ci
    # the finished image is moved next to build_image.sh; hand it back to the user
    chown "$HOST_UID:$HOST_GID" ./*4Clone-*.img.xz* 2>/dev/null || true
  '

ls -lh "$REPO"/*4Clone-*.img.xz* 2>/dev/null || true
[ "$UPGRADE" = 1 ] && echo "Debian upgrade report: $WORK/debian-upgrade-report.txt"
