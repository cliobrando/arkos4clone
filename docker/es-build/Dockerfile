# Cross-build environment for EmulationStation-fcamod (arm64 dArkOS images).
#
# Debian trixie, the release the dArkOS rootfs is built on, so the arm64
# libraries ES links against are the same versions the device runs. Only
# the Mali GPU driver (libmali) is not a Debian package; build-es.sh mounts
# it from es-build/r36-device-libs.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture arm64 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git cmake make pkg-config file \
      crossbuild-essential-arm64 \
      rapidjson-dev \
      libsdl2-dev:arm64 libsdl2-mixer-dev:arm64 \
      libfreeimage-dev:arm64 libfreetype-dev:arm64 \
      libcurl4-openssl-dev:arm64 libvlc-dev:arm64 libasound2-dev:arm64 \
      libdrm-dev:arm64 libegl-dev:arm64 libgles-dev:arm64 \
      libavformat-dev:arm64 libavcodec-dev:arm64 libavutil-dev:arm64 \
      libswscale-dev:arm64 libswresample-dev:arm64 \
 && rm -rf /var/lib/apt/lists/*

COPY toolchain-aarch64.cmake /opt/toolchain-aarch64.cmake
