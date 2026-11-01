#!/usr/bin/env bash
# Build EmulationStation-fcamod for arm64 dArkOS inside the Debian trixie
# container, independent of the host's installed packages.
#
#   docker/es-build/build-es.sh [ES source dir] [output binary] [extra cmake args...]
#
# Defaults: ./EmulationStation-fcamod, es-build/emulationstation.new.
# The build directory is kept per source dir (es-build/docker-build-<name>)
# so rebuilds are incremental. Example with the VPU video backend:
#   docker/es-build/build-es.sh EmulationStation-fcamod es-build/es.mpp \
#       -DENABLE_MPP_VIDEO=ON -DES_VIDEO_DEPS_INCLUDE=/mpp-include
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$(realpath "${1:-$REPO/EmulationStation-fcamod}")"
OUT="$(realpath -m "${2:-$REPO/es-build/emulationstation.new}")"
shift $(( $# > 2 ? 2 : $# ))
IMAGE=arkos4clone-es-build
MALI="$REPO/es-build/r36-device-libs/usr/lib/aarch64-linux-gnu/mali"
MPP_INC="$REPO/es-build/video-deps/include/rockchip"
GO2="$REPO/libgo2-r36/src"   # ES includes the libgo2 headers (renderer), it does not link it
BUILD="$REPO/es-build/docker-build-$(basename "$SRC")"

[ -f "$SRC/CMakeLists.txt" ] || { echo "no CMakeLists.txt in $SRC" >&2; exit 1; }
[ -d "$MALI" ] || { echo "libmali not found in $MALI" >&2; exit 1; }
[ -f "$GO2/audio.h" ] || { echo "libgo2 headers not found in $GO2" >&2; exit 1; }
mkdir -p "$BUILD" "$(dirname "$OUT")"

docker build -q -t "$IMAGE" "$REPO/docker/es-build" >/dev/null

MPP_MOUNT=()
[ -d "$MPP_INC" ] && MPP_MOUNT=(-v "$MPP_INC:/mpp-include/rockchip:ro")

docker run --rm -u "$(id -u):$(id -g)" \
  -v "$SRC:/src" -v "$BUILD:/build" -v "$MALI:/mali:ro" -v "$GO2:/opt/go2-include/go2:ro" "${MPP_MOUNT[@]}" \
  -v "$(dirname "$OUT"):/out" \
  "$IMAGE" bash -euc '
    # link GLES/EGL against the device Mali driver, as the image runs it
    mkdir -p /tmp/mali-link
    ln -sf /mali/libmali-bifrost-g31-g29p1.so /tmp/mali-link/libmali.so.1
    for l in libmali.so libGLESv1_CM.so libGLESv2.so libEGL.so; do ln -sf libmali.so.1 /tmp/mali-link/$l; done
    log=/build/build.log
    fail() { echo "build failed, end of $log:" >&2; grep -E "error|Error" "$log" | head -20 >&2; exit 1; }
    if [ ! -f /build/Makefile ]; then
      cmake -S /src -B /build -DCMAKE_TOOLCHAIN_FILE=/opt/toolchain-aarch64.cmake \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release \
        -DGLES=ON -DGL=OFF -DGLSystem="Embedded OpenGL" \
        -DCMAKE_CXX_FLAGS="-include cstdint -I/opt/go2-include" \
        -DCMAKE_CXX_STANDARD_LIBRARIES="-lGLESv1_CM" \
        -DCMAKE_EXE_LINKER_FLAGS="-L/tmp/mali-link -Wl,-rpath-link,/tmp/mali-link" \
        "$@" > "$log" 2>&1 || fail
    fi
    # the binary is written into the source tree; never ship a stale one
    rm -f /src/emulationstation
    cmake --build /build --parallel "$(nproc)" > "$log" 2>&1 || fail
    cp /src/emulationstation "/out/$(basename "'"$OUT"'")"
  ' -- "$@"

echo "built $OUT"
