#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# ArkOS4Clone injection script
# rsyncs the repo's boot/ rootfs/ roms/ trees into the mounted image:
#   boot/dArkOS  + boot/ArkOS   -> $MOUNT_DIR/boot
#   rootfs/dArkOS + rootfs/ArkOS -> $MOUNT_DIR/root
#   roms/ (if present) -> packed as /roms.tar in the image, extracted to the enlarged p3 on first boot
# ARKOS_IMAGE_NAME determines the sync strategy:
#   *dArkOS*: sync dArkOS, permissions 777 / 1000:1000
#   other   : sync dArkOS first, then ArkOS, permissions 777 / 1002:1002
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
MOUNT_DIR="${ARKOS_MNT:-/home/lcdyk/arkos/mnt}"
# Guard: if MOUNT_DIR is empty or the root path, the later find/rm -rf would sweep the host filesystem
if [[ -z "$MOUNT_DIR" || "$MOUNT_DIR" == "/" || ! -d "$MOUNT_DIR/root/usr/lib" ]]; then
  echo "[ERROR] Invalid MOUNT_DIR: '${MOUNT_DIR:-empty}' (image not mounted?)"
  exit 1
fi
UPDATE_DATE="$(TZ=Asia/Shanghai date +%Y%m%d)"
MODDER="kk&lcdyk"

# safe: best-effort operation; on failure keep going and fail the build at the end
FAIL_COUNT=0
safe() {
  if ! "$@"; then
    echo "[WARN] Failed: $*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# fatal: critical operation; on failure abort the build immediately to avoid producing a broken image
fatal() {
  if ! "$@"; then
    echo "[ERROR] Fatal failure: $*"
    exit 1
  fi
}

echo "== Free space on image root partition before injection =="
df -h "$MOUNT_DIR/root" || true

# rsync options for the boot partition (FAT32) and root partition (ext4)
# root uses -p with --chmod=D0777,F0777 so written content is 777, --chown sets ownership
# -c compares by checksum: the ArkOS/dArkOS trees have identical mtimes (git checkout),
# and files like BMPs have "same resolution = same size", so the quick -t check would miss overrides with different content
RSYNC_BOOT_OPTS="-rltcD --no-owner --no-group --no-perms --omit-dir-times"
RSYNC_ROOT_OPTS="-rlptcD --omit-dir-times"

echo "== Extracting large cores (.so.xz -> .so, skipped if already extracted) =="
while IFS= read -r -d '' core_xz; do
  core_so="${core_xz%.xz}"
  # The archive is a git deliverable, keep it in place; it is excluded from the image via rsync --exclude
  if [[ ! -f "$core_so" ]]; then
    echo "Extracting $core_xz"
    fatal xz -dk -T0 "$core_xz"
  else
    echo "Already extracted, skipping $core_xz"
  fi
done < <(find rootfs -name '*.so.xz' -print0)

sync_boot() {
  fatal sudo rsync $RSYNC_BOOT_OPTS "boot/$1/" "$MOUNT_DIR/boot/"
}

sync_rootfs() {
  # $1: rootfs/ subdirectory, $2: owner (e.g. 1002:1002)
  fatal sudo rsync $RSYNC_ROOT_OPTS --exclude='/home/ark/.config/retroarch*/cores/*.so.xz' --chown="$2" --chmod=D0777,F0777 "rootfs/$1/" "$MOUNT_DIR/root/"
}

pack_roms_tar() {
  # roms/ is packed as /roms.tar in the image (stored on p2); first-boot expandtoexfat.sh extracts it after growing p3
  # Note: the extract command is tar -xf /roms.tar -C /, so member paths must have the roms/ prefix
  # Packing is done in a temporary view under /tmp: the project roms/ only holds additions (things the stock roms.tar lacks),
  # the stock skeleton is merged in temporarily at pack time and never written back to the project directory
  if [[ ! -d roms ]]; then
    echo "== Skipping roms packing (no roms/ directory) =="
    return 0
  fi
  echo "== Packing roms/ -> image /roms.tar =="

  # Empty roms directories and the pymo scanner needed on first boot (sources live in the rootfs tree)
  local d
  for d in hbmame native32 bbk flash gametank spmp8000 krkr2 pymo; do
    mkdir -p "roms/$d"
  done
  if [[ ! -f roms/pymo/Scan_for_new_games.pymo && -f rootfs/dArkOS/opt/pymo/Scan_for_new_games.pymo ]]; then
    cp -f rootfs/dArkOS/opt/pymo/Scan_for_new_games.pymo roms/pymo/
  fi


  # Assemble the packing view: project additions + stock skeleton (first boot reformats p3, so the skeleton must be in the tar)
  # Content goes under stage/roms/, so tar members carry the roms/ prefix
  local stage need_mb avail_mb
  stage="$(mktemp -d -t roms_stage.XXXXXXX)"
  need_mb="$(du -sm roms | cut -f1)"
  avail_mb="$(df -Pm /tmp | awk 'NR==2{print $4}')"
  if (( avail_mb < need_mb + 500 )); then
    echo "[ERROR] Not enough space in /tmp: packing needs about ${need_mb}MB, only ${avail_mb}MB left"
    exit 1
  fi
  mkdir -p "$stage/roms"

  # Merge order: stock skeleton first, project additions after (project overrides stock) --
  # otherwise the stock image's old PortMaster/PortMaster.sh would overwrite the version freshly downloaded at build time
  if [[ -d "$MOUNT_DIR/roms" ]]; then
    echo "== Merging stock roms skeleton (into the package only, not the project directory) =="
    fatal sudo rsync -a --checksum \
      --exclude 'System Volume Information' \
      --exclude 'EUMONBMP.SYS' \
      --exclude '*.CBM' \
      --exclude 'tools/Gamma' \
      --exclude 'tools/ES-logo-changer' \
      --exclude 'tools/PortMaster.sh' \
      \
      "$MOUNT_DIR/roms/" "$stage/roms"/
  fi

  # Stock tempthemes theme packs (if present): dArkOS ships 5 themes incl. freeplay, ArkOS ships the full nes-box
  if [[ -d "$MOUNT_DIR/root/tempthemes" ]]; then
    echo "== Merging stock tempthemes themes (into the package only) =="
    fatal sudo rsync -a "$MOUNT_DIR/root/tempthemes/" "$stage/roms/themes/"
  fi

  # --checksum: the project must unconditionally override stock (avoids missed overrides with same size/mtime, lesson from the logo incident)
  # Themes (roms/themes, incl. full es-theme-nes-box + pymo) go straight into the tar with the project additions
  fatal sudo rsync -a --checksum \
    \
    roms/ "$stage/roms"/

  # Gamma / ES-logo-changer are no longer shipped (belt and braces: delete them even if they leak into stage another way)
  safe sudo rm -rf "$stage/roms/tools/Gamma" "$stage/roms/tools/ES-logo-changer" "$stage/roms/tools/PortMaster.sh"

  # -h dereferences symlinks: exFAT on the device does not support links
  # --owner=0 --group=0: normalize archive ownership to root (otherwise the build machine's uid ends up in the package;
  # exFAT on the device does not support chown, so extraction would report Operation not permitted for every file)
  fatal sudo tar -h --hard-dereference --owner=0 --group=0 -cf "$MOUNT_DIR/root/roms.tar" -C "$stage" roms
  fatal sudo chmod 777 "$MOUNT_DIR/root/roms.tar"
  safe sudo rm -rf "$stage"
}

cleanup_stock() {
  # Delete stock files kept in the image
  safe sudo rm -rf "$MOUNT_DIR/boot/BMPs" "$MOUNT_DIR/boot/ScreenFiles"
  safe sudo rm -rf "$MOUNT_DIR/boot/boot.ini" "$MOUNT_DIR"/boot/*.dtb "$MOUNT_DIR"/boot/*.orig \
    "$MOUNT_DIR"/boot/*.tony "$MOUNT_DIR"/boot/Image "$MOUNT_DIR"/boot/*.bmp \
    "$MOUNT_DIR/boot/WHERE_ARE_MY_ROMS.txt"
  safe sudo rm -f "$MOUNT_DIR/boot/DTB Change Tool.exe"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/DeviceType"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Change LED to Red.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Update.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Wifi.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Network Info.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Enable Remote Services.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Disable Remote Services.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Change Time.sh"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/NDS Overlays"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Change Ports SDL.sh"
  safe sudo find "$MOUNT_DIR/root/opt/system/Advanced" -name 'Restore*.sh' ! -name 'Restore ArkOS Settings.sh' -exec rm -f {} +
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Screen - Switch to Original Screen Timings.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Reset EmulationStation Controls.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Fix Global Hotkeys.sh"
  safe sudo rm -f "$MOUNT_DIR/root/etc/emulationstation/es_input.cfg"
  # tempthemes mechanism is retired: themes ship in roms.tar, the image no longer carries them
  safe sudo rm -rf "$MOUNT_DIR/root/tempthemes"
  # None of Mesa's Vulkan drivers (panfrost/lvp etc.) can drive this GPU (Mali kbase), yet the loader loads each one,
  # and lvp pulls in LLVM, adding about 3.6s to every Vulkan program's startup; keep only mali.json
  if [[ -d "$MOUNT_DIR/root/usr/share/vulkan/icd.d" ]]; then
    safe sudo find "$MOUNT_DIR/root/usr/share/vulkan/icd.d" -name '*.json' ! -name 'mali.json' -delete
  fi
  # p3 stays stock NTFS from the factory; first-boot expandtoexfat.sh converts it to exFAT and switches fstab
  # (fstab.exfat stays on the boot partition for first boot; tempthemes is retired and deleted -- themes ship in roms.tar)
}

prune_old_libs() {
  # Clean redundant libraries out of the stock image (image builds only; OTA does not touch libraries on the device)
  local arch_dir dir f b newest real
  local sdl2_keep=" libSDL2-2.0.so.0.3200.10 libSDL2-2.0.so.0.18.2 "
  local lib_dirs=(
    "$MOUNT_DIR/root/usr/lib/arm-linux-gnueabihf"
    "$MOUNT_DIR/root/usr/lib/aarch64-linux-gnu"
  )

  # ---- 1) Library junk: leftover stock .bak/.zip/.last files (23M flycast backup etc.) ----
  local junk_dirs=(
    "${lib_dirs[@]}"
    "$MOUNT_DIR/root/home/ark/.config/retroarch/cores"
    "$MOUNT_DIR/root/home/ark/.config/retroarch32/cores"
    "$MOUNT_DIR/root/opt/mupen64plus"
  )
  for dir in "${junk_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' f; do
      safe sudo rm -f "$f"
      echo "  Deleting junk library file: ${f#$MOUNT_DIR/root}"
    done < <(sudo find "$dir" -maxdepth 1 \( -name '*.bak' -o -name '*.zip' -o -name '*.last' \) -type f -print0 2>/dev/null)
  done

  # ---- 2) Old SDL2 versions: per architecture keep 0.18.2 (coco/mvem/dragon LD_PRELOAD)
  #         and the newest version in that directory (64-bit = 0.3200.10 main version; 32-bit stock has no
  #         0.3200.10, keep its newest 0.3000.10, replaced with 0.3200.10 by quirks on first boot) ----
  for arch_dir in "${lib_dirs[@]}"; do
    [[ -d "$arch_dir" ]] || continue
    local keep_newest
    keep_newest=$(ls -1 "$arch_dir" 2>/dev/null | grep -E '^libSDL2-2\.0\.so\.0\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    local keep=" libSDL2-2.0.so.0.18.2 ${keep_newest:+$keep_newest} "
    for f in "$arch_dir"/libSDL2-2.0.so.0.*[0-9]; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      b="$(basename "$f")"
      [[ "$keep" == *" $b "* ]] && continue
      safe sudo rm -f "$f"
      echo "  Deleting extra SDL2: $b"
    done
  done

  # ---- 3) SDL2 soname/dev link fix: stock links may point to versions just deleted,
  #         redirect to the newest version kept per architecture (32-bit = 0.3000.10, 64-bit = 0.3200.10) ----
  for arch_dir in "${lib_dirs[@]}"; do
    [[ -d "$arch_dir" ]] || continue
    newest=$(ls -1 "$arch_dir" 2>/dev/null | grep -E '^libSDL2-2\.0\.so\.0\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    [[ -n "$newest" ]] || continue
    if [[ "$(readlink "$arch_dir/libSDL2-2.0.so.0" 2>/dev/null)" != "$newest" ]]; then
      fatal sudo ln -sfn "$newest" "$arch_dir/libSDL2-2.0.so.0"
      echo "  SDL2 soname link fix: libSDL2-2.0.so.0 -> $newest"
    fi
    if [[ "$(readlink "$arch_dir/libSDL2.so" 2>/dev/null)" != "libSDL2-2.0.so.0" ]]; then
      fatal sudo ln -sfn "libSDL2-2.0.so.0" "$arch_dir/libSDL2.so"
      echo "  SDL2 dev link fix: libSDL2.so -> libSDL2-2.0.so.0"
    fi
  done

  # ---- 4) Collapse identical copies sharing a base name into a symlink chain ----
  # Stock copied intermediate layers that should be symlinks as real files (Qt5 triplets/solarus/linapple etc.).
  # Only convert when every file in the group is identical (verified with cmp); keep the one with the longest version as the real file.
  local collapse_dirs=(
    "${lib_dirs[@]}"
    "$MOUNT_DIR/root/opt/solarus"
    "$MOUNT_DIR/root/opt/linapple/libs"
    "$MOUNT_DIR/root/opt/mupen64plus"
  )
  local -A seen_members=()
  for dir in "${collapse_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    local -A groups=()
    for f in "$dir"/*.so*; do
      [[ -f "$f" && ! -L "$f" ]] || continue
      b="${f##*/}"
      b="${b%%.so*}.so"
      groups["$b"]="${groups["$b"]:+${groups["$b"]}|}$f"
    done
    for b in "${!groups[@]}"; do
      IFS='|' read -r -a real <<< "${groups[$b]}"
      (( ${#real[@]} >= 2 )) || continue
      newest=$(printf '%s\n' "${real[@]}" | sed "s|$dir/||" | sort -V | tail -1)
      keep="$dir/$newest"
      local ok=1
      for f in "${real[@]}"; do
        [[ "$f" == "$keep" ]] && continue
        sudo cmp -s "$f" "$keep" || { ok=0; break; }
      done
      (( ok )) || continue
      for f in "${real[@]}"; do
        [[ "$f" == "$keep" ]] && continue
        safe sudo rm -f "$f"
        fatal sudo ln -sfn "$(basename "$keep")" "${f%/*}/${f##*/}"
        echo "  File to link: ${f#$MOUNT_DIR/root} -> $(basename "$keep")"
      done
    done
    unset groups
  done
}

if [[ "$ARKOS_IMAGE_NAME" == *dArkOS* ]]; then
  # ============================================================
  # dArkOS (UID=1000)
  # ============================================================
  echo "=== dArkOS image detected: sync dArkOS, permissions 777 / 1000:1000 ==="
  CHOWN_USER="1000:1000"

  echo "== sync boot/dArkOS =="
  sync_boot dArkOS

  echo "== sync rootfs/dArkOS =="
  sync_rootfs dArkOS 1000:1000
  pack_roms_tar

  echo "== Cleaning files dArkOS does not need =="
  cleanup_stock
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/batt_led.service"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/Backup dArkOS Settings"
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/logo.service" \
    "$MOUNT_DIR/root/etc/systemd/system/multi-user.target.wants/logo.service"

  echo "== Setting dArkOS plymouth title =="
  safe sudo sed -i "/title\=/c\title\=dArkOS4Clone ($UPDATE_DATE)($MODDER)" "$MOUNT_DIR/root/usr/share/plymouth/themes/text.plymouth"

else
  # ============================================================
  # ArkOS (UID=1002): dArkOS first, then ArkOS layered on top
  # ============================================================
  echo "=== ArkOS image detected: sync dArkOS first, then ArkOS, permissions 777 / 1002:1002 ==="
  CHOWN_USER="1002:1002"

  echo "== sync boot/dArkOS + boot/ArkOS =="
  sync_boot dArkOS
  sync_boot ArkOS

  # Free up space
  echo "== Saving space =="
  prune_old_libs
  safe sudo rm -rf "$MOUNT_DIR/root/usr/lib/gcc"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/ppssppgo"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/hypseus"
  # Stock build/dev files: the device is a consumer handheld, nothing is ever compiled on it
  # Header files / kernel build directories
  safe sudo rm -rf "$MOUNT_DIR/root/usr/include" "$MOUNT_DIR/root/usr/src"
  # Static libraries .a (link-time only artifacts, ~91M) and libtool .la
  # -prune skips modules/firmware dirs; -print0/-0 handles unusual filenames
  # Note: .pc files and pkg-config are kept -- some runtimes call them, and together they are <100KB, not worth deleting
  safe sudo find "$MOUNT_DIR/root/usr/lib" "$MOUNT_DIR/root/usr/local/lib" \
    \( -type d \( -name modules -o -name firmware \) \) -prune -o \
    \( -name '*.a' -o -name '*.la' \) -type f -print0 2>/dev/null |
    xargs -0 -r sudo rm -f
  # cmake dev metadata (cmake itself is deleted too)
  safe sudo rm -rf "$MOUNT_DIR/root"/usr/lib/*/cmake "$MOUNT_DIR/root"/usr/lib/cmake
  # Leftover cross-compilers/build tools (/usr/bin, ~25M); keep native pkg-config
  safe sudo rm -f "$MOUNT_DIR/root"/usr/bin/aarch64-linux-gnu-* \
    "$MOUNT_DIR/root"/usr/bin/aarch64-unknown-* \
    "$MOUNT_DIR/root"/usr/bin/c89-gcc "$MOUNT_DIR/root"/usr/bin/c99-gcc \
    "$MOUNT_DIR/root"/usr/bin/cmake "$MOUNT_DIR/root"/usr/bin/ccmake \
    "$MOUNT_DIR/root"/usr/bin/ctest "$MOUNT_DIR/root"/usr/bin/cpack

  echo "== sync rootfs/dArkOS + rootfs/ArkOS =="
  sync_rootfs dArkOS 1002:1002
  sync_rootfs ArkOS 1002:1002
  pack_roms_tar

  echo "== Cleaning files ArkOS does not need =="
  cleanup_stock
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/batt_led.service"
  safe sudo rm -f "$MOUNT_DIR/root/etc/systemd/system/ddtbcheck.service"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/Read from SD1 and SD2 for Roms"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Read from SD1 and SD2 for Roms.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Switch to SD2 for Roms.sh"
  safe sudo rm -f "$MOUNT_DIR/root/opt/system/Advanced/Switch to main SD for Roms.sh"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Advanced/Video Boot/"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Tools/Gamma/"
  safe sudo rm -rf "$MOUNT_DIR/root/opt/system/Tools/ES-logo-changer/"
  safe sudo rm -f "$MOUNT_DIR/root/usr/local/bin/Read from SD1 and SD2 for Roms"
  safe sudo rm -f "$MOUNT_DIR/root/usr/local/bin/Switch to SD2 for Roms.sh"
  safe sudo rm -f "$MOUNT_DIR/root/usr/local/bin/Switch to main SD for Roms.sh"

  echo "== Removing random logo =="
  safe sudo sed -i '/imageshift\.sh/d' "$MOUNT_DIR/root/var/spool/cron/crontabs/root"
  safe sudo rm -f "$MOUNT_DIR/root/home/ark/.config/imageshift.sh"
  safe sudo chown -R $CHOWN_USER "$MOUNT_DIR/root/lib/systemd/system/mpv.service"
  safe sudo chmod 777 "$MOUNT_DIR/root/lib/systemd/system/mpv.service"

  echo "== Setting ArkOS plymouth title =="
  safe sudo sed -i "/title\=/c\title\=ArkOS4Clone ($UPDATE_DATE)($MODDER)" "$MOUNT_DIR/root/usr/share/plymouth/themes/text.plymouth"
fi

echo "== Free space on image root partition after injection =="
df -h "$MOUNT_DIR/root" || true
cat "$MOUNT_DIR/root/usr/share/plymouth/themes/text.plymouth"
if (( FAIL_COUNT > 0 )); then
  echo "[ERROR] $FAIL_COUNT command(s) failed during injection, the image may be incomplete, aborting build."
  exit 1
fi
echo "== Done =="
