# Environment for build_image.sh: the same tools the GitHub Actions job
# installs, plus qemu for the optional Debian upgrade of the arm64 rootfs.
# Must run --privileged with the host's /dev (loop devices, mounts); see
# docker/build-image.sh.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git file python3 sudo \
      parted fdisk util-linux rsync xz-utils unzip p7zip-full cpio gzip \
      e2fsprogs dosfstools btrfs-progs f2fs-tools exfatprogs exfat-fuse ntfs-3g \
      golang-go \
      qemu-user-static \
 && rm -rf /var/lib/apt/lists/*
