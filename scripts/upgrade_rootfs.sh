#!/usr/bin/env bash
# Upgrade the Debian packages of a mounted arm64 rootfs to the latest point
# release of its own Debian release (apt-get upgrade: no dist-upgrade, no new
# or removed packages). Runs apt inside a chroot through qemu-aarch64 (the
# caller must have binfmt_misc set up for aarch64).
#
# Protected (apt-mark hold) so dArkOS's own builds are not replaced:
# - every package whose installed files differ from the Debian package
#   (dpkg --verify), e.g. libraries dArkOS rebuilt and copied over
# - kernel, firmware, boot and Mali/GPU driver packages
#
#   upgrade_rootfs.sh <rootfs mountpoint> [report file]
set -euo pipefail

ROOT="${1:?usage: upgrade_rootfs.sh <rootfs> [report]}"
REPORT="${2:-/dev/stdout}"
[ -x "$ROOT/usr/bin/apt-get" ] || { echo "no apt-get in $ROOT" >&2; exit 1; }

mounted=()
bind() { mkdir -p "$ROOT$1"; mount --bind "$1" "$ROOT$1"; mounted+=("$ROOT$1"); }
cleanup() {
  rm -f "$ROOT/usr/sbin/policy-rc.d"
  [ -f "$ROOT/etc/resolv.conf.upgrade-bak" ] && mv -f "$ROOT/etc/resolv.conf.upgrade-bak" "$ROOT/etc/resolv.conf"
  for ((i=${#mounted[@]}-1; i>=0; i--)); do umount -l "${mounted[i]}" 2>/dev/null || true; done
}
trap cleanup EXIT

bind /proc; bind /sys; bind /dev; bind /dev/pts
# no services may start inside the image
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"; chmod +x "$ROOT/usr/sbin/policy-rc.d"
# name resolution for apt
if [ -e "$ROOT/etc/resolv.conf" ] || [ -L "$ROOT/etc/resolv.conf" ]; then mv -f "$ROOT/etc/resolv.conf" "$ROOT/etc/resolv.conf.upgrade-bak"; fi
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

in_root() { chroot "$ROOT" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive LC_ALL=C "$@"; }

{
  echo "== Debian release: $(cat "$ROOT/etc/debian_version" 2>/dev/null)"

  # packages whose files dArkOS changed: keep them as they are
  # (content changed, "5"; config files, marked "c", are kept by --force-confold anyway)
  modified=$(in_root dpkg --verify 2>/dev/null | awk '$NF ~ /^\// && $1 ~ /5/ && $2 != "c" {print $NF}' \
    | while read -r f; do in_root dpkg -S "$f" 2>/dev/null | cut -d: -f1 | tr ',' '\n'; done \
    | sed 's/^ *//' | sort -u)
  fixed=$(in_root dpkg-query -W -f '${Package}\n' 2>/dev/null \
    | grep -E '^(linux-|firmware-|raspi|u-boot|grub|initramfs-tools|libmali|mali|rockchip|plymouth)' || true)
  hold=$(printf '%s\n%s\n' "$modified" "$fixed" | grep -v '^$' | sort -u)
  echo "== held ($(echo "$hold" | grep -c . || true) packages):"
  echo "$hold" | sed 's/^/   /'
  [ -n "$hold" ] && echo "$hold" | in_root xargs apt-mark hold >/dev/null

  in_root apt-get update -q
  echo "== to upgrade:"
  in_root apt-get -s upgrade | awk '/^Inst / {print "   " $2, $3, $4}'
  in_root apt-get -y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef upgrade
  in_root apt-get clean

  # holds were only for this upgrade
  [ -n "$hold" ] && echo "$hold" | in_root xargs apt-mark unhold >/dev/null
  echo "== Debian release after: $(cat "$ROOT/etc/debian_version" 2>/dev/null)"
} 2>&1 | tee -a "$REPORT"
