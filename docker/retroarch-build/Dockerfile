# Cross-build environment for RetroArch (arm64 and armhf dArkOS images).
#
# Debian trixie, the release the dArkOS rootfs is built on, so both binaries
# link against the library versions the device runs. libmali and librga are
# not Debian packages: Mali answers to the same libEGL.so.1, libGLESv2.so.2
# and libgbm.so.1 names at run time, librga is stubbed at link time.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture arm64 \
 && dpkg --add-architecture armhf \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git make pkg-config file binutils \
      crossbuild-essential-arm64 crossbuild-essential-armhf \
      libasound2-dev:arm64 libasound2-dev:armhf \
      libfreetype-dev:arm64 libfreetype-dev:armhf \
      libudev-dev:arm64 libudev-dev:armhf \
      libxkbcommon-dev:arm64 libxkbcommon-dev:armhf \
      libdrm-dev:arm64 libdrm-dev:armhf \
      libgbm-dev:arm64 libgbm-dev:armhf \
      libegl-dev:arm64 libegl-dev:armhf \
      libgles-dev:arm64 libgles-dev:armhf \
      libsdl2-dev:arm64 libsdl2-dev:armhf \
      libpng-dev:arm64 libpng-dev:armhf \
      zlib1g-dev:arm64 zlib1g-dev:armhf \
 && rm -rf /var/lib/apt/lists/*
