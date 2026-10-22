#!/usr/bin/env bash
set -euo pipefail

# ============ Configuration ============
# Quiet when ARKOS_QUIET=1 (passed in by build_image.sh --ci)
if [[ "${ARKOS_QUIET:-}" == "1" ]]; then
  RSYNC_PROGRESS="--quiet"
else
  RSYNC_PROGRESS="--info=progress2"
fi
P1_TARGET_MB=256              # p1 (boot) target size: 256MiB (stock 112MiB)
P2_TARGET_MB=11264            # p2 (root) target size: 11G, not changed on the device
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# Temp dir prefers ARKOS_WORK_DIR, otherwise the current directory
WORK_BASE="${ARKOS_WORK_DIR:-$(pwd)}"
TMP_DIR="${WORK_BASE}/tmp"    # Backup/restore dir; created by the script and deleted when done
# P3 filesystem type and label are detected automatically from the original p3
# =============================

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <image file path>"
  exit 1
fi
IMG="$1"
[[ -f "$IMG" ]] || { echo "Image not found: $IMG"; exit 1; }

# Runtime resources (mount points etc.)
P1_OLD_MNT="$(mktemp -d -t p1_old.XXXXXX)"
P1_NEW_MNT="$(mktemp -d -t p1_new.XXXXXX)"
P3_OLD_MNT="$(mktemp -d -t p3_old.XXXXXX)"
P3_NEW_MNT="$(mktemp -d -t p3_new.XXXXXX)"
LOOP=""

settle() {
  # Wait for kernel/udev to create device nodes; fall back to sleep in udev-less environments such as WSL
  if command -v udevadm >/dev/null 2>&1; then
    sudo udevadm settle || true
  else
    sleep 1
  fi
}

cleanup() {
  set +e
  mountpoint -q "$P1_OLD_MNT" && sudo umount "$P1_OLD_MNT"
  mountpoint -q "$P1_NEW_MNT" && sudo umount "$P1_NEW_MNT"
  mountpoint -q "$P3_OLD_MNT" && sudo umount "$P3_OLD_MNT"
  mountpoint -q "$P3_NEW_MNT" && sudo umount "$P3_NEW_MNT"
  [[ -d "$P1_OLD_MNT" ]] && rmdir "$P1_OLD_MNT" || true
  [[ -d "$P1_NEW_MNT" ]] && rmdir "$P1_NEW_MNT" || true
  [[ -d "$P3_OLD_MNT" ]] && rmdir "$P3_OLD_MNT" || true
  [[ -d "$P3_NEW_MNT" ]] && rmdir "$P3_NEW_MNT" || true
  # Clean up temporary btrfs mount point
  local btrfs_mnt="${WORK_BASE:-$(pwd)}/btrfs_resize"
  if [[ -d "$btrfs_mnt" ]]; then
    mountpoint -q "$btrfs_mnt" && sudo umount -l "$btrfs_mnt"
    sudo rmdir "$btrfs_mnt" 2>/dev/null
  fi
  # Detach current loop
  if [[ -n "${LOOP:-}" ]] && losetup -a | grep -q "^$LOOP:"; then
    sudo losetup -d "$LOOP" || true
  fi
}
trap cleanup EXIT

# Detach any loops already mapped to this image (if present)
echo "== Detaching old loops (if present) =="
while read -r dev; do
  [[ -n "$dev" ]] && sudo losetup -d "$dev" || true
done < <(losetup -j "$IMG" | cut -d: -f1)

# Map image to a loop (with partition scan), atomically returning a unique device name
echo "== Mapping image to loop (with partitions) =="
LOOP="$(sudo losetup --find --show -P "$IMG")"
settle
echo "Using loop: $LOOP"

# Clean up possibly leftover mount points (the device may already be mounted by another process)
echo "== Cleaning up leftover mount points =="
for part in "${LOOP}p1" "${LOOP}p2" "${LOOP}p3"; do
  if [[ -b "$part" ]]; then
    while read -r mnt; do
      [[ -n "$mnt" ]] && sudo umount -l "$mnt" 2>/dev/null || true
    done < <(findmnt -n -o TARGET "$part" 2>/dev/null || true)
  fi
done

# Sector info
SECTOR_SIZE="$(sudo blockdev --getss "$LOOP")"  # usually 512

# Helper: check whether p3 exists (machine-readable mode)
has_p3() {
  sudo parted -sm "$LOOP" unit s print | grep -qE '^3:'
}

# Read current sizes of p1 / p2 / p3 and compute how much each grows
PARTED_OUT="$(sudo parted -sm "$LOOP" unit s print)"
P1_START="$(awk -F: '$1=="1"{gsub(/s/,"",$2); print $2}' <<< "$PARTED_OUT")"
P1_END="$(awk -F: '$1=="1"{gsub(/s/,"",$3); print $3}' <<< "$PARTED_OUT")"
[[ -n "${P1_START:-}" && -n "${P1_END:-}" ]] || { echo "Could not read partition 1 info, exiting."; exit 1; }
P1_CUR_MB=$(( (P1_END - P1_START + 1) * SECTOR_SIZE / 1024 / 1024 ))

CUR_START="$(awk -F: '$1=="2"{gsub(/s/,"",$2); print $2}' <<< "$PARTED_OUT")"
CUR_END="$(awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}' <<< "$PARTED_OUT")"
[[ -n "${CUR_END:-}" ]] || { echo "Could not read partition 2 info, exiting."; exit 1; }
P2_CUR_MB=$(( (CUR_END - CUR_START + 1) * SECTOR_SIZE / 1024 / 1024 ))

P3_CUR_MB=0
if has_p3; then
  P3_START="$(awk -F: '$1=="3"{gsub(/s/,"",$2); print $2}' <<< "$PARTED_OUT")"
  P3_END="$(awk -F: '$1=="3"{gsub(/s/,"",$3); print $3}' <<< "$PARTED_OUT")"
  P3_CUR_MB=$(( (P3_END - P3_START + 1) * SECTOR_SIZE / 1024 / 1024 ))
fi

# Grow p1 to a fixed 256MiB; grow p2 to a fixed 11G; keep p3 as is (empty from factory)
# roms/ is packed as /roms.tar and extracted on first boot
BOOT_ADD_MB=$(( P1_TARGET_MB > P1_CUR_MB ? P1_TARGET_MB - P1_CUR_MB : 0 ))
P2_DELTA=$(( P2_TARGET_MB > P2_CUR_MB ? P2_TARGET_MB - P2_CUR_MB : 0 ))

echo "Current p1: ${P1_CUR_MB}MiB, p2: ${P2_CUR_MB}MiB (End: $CUR_END), p3: ${P3_CUR_MB}MiB"
echo "Target: p1 → ${P1_TARGET_MB}MiB (+${BOOT_ADD_MB}), p2 → ${P2_TARGET_MB}MiB (+${P2_DELTA}), p3 stays ${P3_CUR_MB}MiB"

# p3 backup always goes to $TMP_DIR/p3data (kept separate from the p1 backup in $TMP_DIR/bootfs;
# restore checks the HAD_P3 flag so the boot backup is never restored into p3 by mistake)
HAD_P3=0

# ======= Step 1: Back up p3 to TMP_DIR/p3data (if present) =======
if has_p3; then
  HAD_P3=1
  echo "p3 detected, preparing backup to $TMP_DIR/p3data"
  mkdir -p "$TMP_DIR/p3data"
  P3_DEV="${LOOP}p3"

  # Same as stock: rebuild p3 with its original type (stock image is NTFS)
  ORIG_P3_FS="$(sudo blkid -s TYPE -o value "$P3_DEV" 2>/dev/null || echo 'vfat')"
  ORIG_P3_LABEL="$(sudo blkid -s LABEL -o value "$P3_DEV" 2>/dev/null || echo 'EASYROMS')"
  echo "Original p3 type: $ORIG_P3_FS, label: $ORIG_P3_LABEL, new p3 will reuse them"

  echo "Mounting old p3 at $P3_OLD_MNT (read-only preferred)"
  if ! sudo mount -o ro "$P3_DEV" "$P3_OLD_MNT"; then
    echo "Read-only mount failed, trying normal mount"
    sudo mount "$P3_DEV" "$P3_OLD_MNT"
  fi

  echo "Backing up p3 -> $TMP_DIR/p3data (rsync -aH --delete, so the directory is an exact mirror)"
  sudo rsync -aH --delete $RSYNC_PROGRESS "$P3_OLD_MNT"/ "$TMP_DIR/p3data"/

  echo "Unmounting old p3 mount point"
  sudo umount "$P3_OLD_MNT"
else
  echo "No p3 found, skipping backup."
  # Set defaults (used when creating the new p3)
  ORIG_P3_FS="exfat"
  ORIG_P3_LABEL="EASYROMS"
  echo "Will create p3 with defaults: filesystem=$ORIG_P3_FS, label=$ORIG_P3_LABEL"
fi

# ======= Step 2: Delete p3 partition (must clear the way) =======
echo "== Deleting old partition 3 =="
if sudo parted -s "$LOOP" rm 3 2>/dev/null; then
  echo "Deleted p3 (if it existed)"
else
  echo "Could not delete p3 (it may not have existed), continuing."
fi

# Check again; abort if p3 still exists
if has_p3; then
  echo "Error: p3 still exists, cannot continue resizing. Check the partition table and retry."
  sudo parted "$LOOP" unit s print || true
  exit 1
fi

if (( BOOT_ADD_MB > 0 )); then
  # ======= Step 3A: Grow p1 (boot) =======
  # p2 sits right after p1, so growing p1 requires shifting all of p2's raw data to the right:
  # back up p1 contents → delete p1/p2 table entries → move p2 raw data inside the image file →
  # recreate p1 at 256MiB (restore contents after mkfs) → recreate p2 at the new start
  # (boot.ini boots by partition number with "load mmc 1:1", no UUID references, so rebuilding FAT is safe)

  NEW_P1_END=$(( P1_START + P1_TARGET_MB * 1024 * 1024 / SECTOR_SIZE - 1 ))
  NEW_P2_START=$(( NEW_P1_END + 1 ))
  SHIFT_SECTORS=$(( NEW_P2_START - CUR_START ))
  SHIFT_BYTES=$(( SHIFT_SECTORS * SECTOR_SIZE ))
  MOVE_SRC=$(( CUR_START * SECTOR_SIZE ))
  MOVE_LEN=$(( (CUR_END - CUR_START + 1) * SECTOR_SIZE ))

  # Safety assertions: new p2 start is 1MiB-aligned; move destination does not go past the current end of file
  (( NEW_P2_START % (1024 * 1024 / SECTOR_SIZE) == 0 )) \
    || { echo "Error: new p2 start ${NEW_P2_START}s is not 1MiB-aligned, exiting."; exit 1; }
  IMG_SIZE_BYTES="$(stat -c %s "$IMG")"
  (( MOVE_SRC + MOVE_LEN + SHIFT_BYTES <= IMG_SIZE_BYTES )) \
    || { echo "Error: p2 move destination extends past end of image, exiting."; exit 1; }

  echo "== Backing up p1 (boot) contents -> $TMP_DIR/bootfs =="
  mkdir -p "$TMP_DIR/bootfs"
  ORIG_P1_LABEL="$(sudo blkid -s LABEL -o value "${LOOP}p1" 2>/dev/null || echo 'BOOT')"
  echo "Original p1 label: $ORIG_P1_LABEL (reused after rebuild)"
  if ! sudo mount -o ro "${LOOP}p1" "$P1_OLD_MNT"; then
    echo "Read-only mount failed, trying normal mount"
    sudo mount "${LOOP}p1" "$P1_OLD_MNT"
  fi
  sudo rsync -rltD --delete --no-owner --no-group --no-perms --omit-dir-times \
    $RSYNC_PROGRESS "$P1_OLD_MNT"/ "$TMP_DIR/bootfs"/
  sudo umount "$P1_OLD_MNT"

  echo "== Deleting old partitions 1/2 (p3 already deleted; p2 data is still in the image file) =="
  sudo parted -s "$LOOP" rm 2
  sudo parted -s "$LOOP" rm 1
  sudo partprobe "$LOOP" || true

  echo "== Shifting p2 raw data right by ${SHIFT_SECTORS} sectors (+${BOOT_ADD_MB}MiB), ${P2_CUR_MB}MiB total =="
  # Detach loop and move data directly in the image file (avoids loop cache / file write inconsistency)
  sudo losetup -d "$LOOP"
  LOOP=""
  # Move in reverse chunks (chunk < shift, moving from the end backwards, so overlapping src/dst never clobbers unread data)
  CHUNK=$(( 16 * 1024 * 1024 ))
  remaining=$MOVE_LEN
  src_off=$(( MOVE_SRC + MOVE_LEN ))
  next_report=$(( 1024 * 1024 * 1024 ))
  while (( remaining > 0 )); do
    (( n = remaining < CHUNK ? remaining : CHUNK ))
    src_off=$(( src_off - n ))
    dd if="$IMG" of="$IMG" bs="$CHUNK" conv=notrunc status=none \
      iflag=count_bytes,skip_bytes oflag=seek_bytes \
      skip="$src_off" seek="$(( src_off + SHIFT_BYTES ))" count="$n"
    remaining=$(( remaining - n ))
    if [[ "${ARKOS_QUIET:-}" != "1" ]] && (( MOVE_LEN - remaining >= next_report )); then
      echo "  Moved $(( (MOVE_LEN - remaining) / 1024 / 1024 )) / $(( MOVE_LEN / 1024 / 1024 )) MiB"
      next_report=$(( next_report + 1024 * 1024 * 1024 ))
    fi
  done
  sync

  echo "== Enlarging image +$(( P2_DELTA + BOOT_ADD_MB ))MiB =="
  truncate -s +"$(( P2_DELTA + BOOT_ADD_MB ))M" "$IMG"

  echo "== Refreshing loop size =="
  LOOP="$(sudo losetup --find --show -P "$IMG")"
  settle
  echo "loop refreshed: $LOOP"

  echo "== Rebuilding p1: ${P1_TARGET_MB}MiB FAT32 (${P1_START}s - ${NEW_P1_END}s) =="
  sudo parted -s "$LOOP" unit s "mkpart primary fat32 ${P1_START}s ${NEW_P1_END}s"
  # Partition type 0x0b, same as stock (parted defaults to 0x0c)
  sudo sfdisk --change-id "$LOOP" 1 b 2>/dev/null || true
  sudo partprobe "$LOOP" || true
  settle
  sudo mkfs.vfat -F 32 -n "$ORIG_P1_LABEL" "${LOOP}p1"
  echo "== Restoring p1 contents =="
  sudo mount "${LOOP}p1" "$P1_NEW_MNT"
  sudo rsync -rltD --no-owner --no-group --no-perms --omit-dir-times \
    $RSYNC_PROGRESS "$TMP_DIR/bootfs"/ "$P1_NEW_MNT"/
  sync
  sudo umount "$P1_NEW_MNT"

  echo "== Rebuilding p2: ${P2_TARGET_MB}MiB (starting at ${NEW_P2_START}s) =="
  NEW_P2_END=$(( NEW_P2_START + P2_TARGET_MB * 1024 * 1024 / SECTOR_SIZE - 1 ))
  sudo parted -s "$LOOP" unit s "mkpart primary ${NEW_P2_START}s ${NEW_P2_END}s"
  sudo partprobe "$LOOP" || true
  settle
else
  # ======= Step 3B: p1 already at target, only grow p2 in place =======
  echo "p1 already at ${P1_TARGET_MB}MiB, skipping boot resize"

  echo "== Enlarging image +${P2_DELTA}MiB (p2 only; p3 unchanged) =="
  truncate -s +"${P2_DELTA}"M "$IMG"

  echo "== Refreshing loop size =="
  sudo losetup -d "$LOOP"
  LOOP="$(sudo losetup --find --show -P "$IMG")"
  settle
  echo "loop refreshed: $LOOP"

  ADD_SECTORS=$(( P2_DELTA * 1024 * 1024 / SECTOR_SIZE ))
  # Re-read p2 End (in case parted/kernel refresh shifted the boundary)
  CUR_END="$(sudo parted -sm "$LOOP" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')"
  [[ -n "${CUR_END:-}" ]] || { echo "Could not read partition 2 info after refresh, exiting."; exit 1; }
  NEW_END=$(( CUR_END + ADD_SECTORS ))
  echo "Extending p2 end sector to: $NEW_END"

  echo "== Extending p2 to the given sector (not 100%) =="
  if [ "$P2_DELTA" -gt 0 ]; then
    sudo parted -s "$LOOP" unit s "resizepart 2 ${NEW_END}s"
  else
    echo "p2 already at target size, skipping"
  fi
  sudo partprobe "$LOOP" || true
  settle
fi

echo "== Growing filesystem inside p2 (auto-detect ext4 / f2fs) =="
P2_DEV="${LOOP}p2"
P2_FS="$(blkid -s TYPE -o value "$P2_DEV" || true)"
case "$P2_FS" in
  ext4|"")
    sudo e2fsck -fy "$P2_DEV"
    sudo resize2fs "$P2_DEV"
    ;;
  f2fs)
    sudo fsck.f2fs -f "$P2_DEV" || true
    sudo resize.f2fs "$P2_DEV"
    ;;
  btrfs)
    # Use a fixed mount point under the work directory so it is clean
    P2_MNT="${WORK_BASE}/btrfs_resize"
    sudo mkdir -p "$P2_MNT"
    # Make sure any existing mounts are unmounted
    sudo umount -l "$P2_MNT" 2>/dev/null || true
    sudo umount -l "$P2_DEV" 2>/dev/null || true
    # Clear the btrfs kernel device cache (critical!)
    echo "Clearing btrfs device cache..."
    sudo btrfs device scan --forget 2>/dev/null || true
    # Mount and resize
    sudo mount -t btrfs "$P2_DEV" "$P2_MNT"
    sudo btrfs filesystem resize max "$P2_MNT"
    sudo umount "$P2_MNT"
    sudo rmdir "$P2_MNT" 2>/dev/null || true
    ;;
  *)
    echo "Warning: unknown/unsupported p2 filesystem type: $P2_FS"
    echo "Please grow the p2 filesystem manually before continuing."
    ;;
esac

# ======= Step 4: Rebuild p3 (from after p2 to end of disk) =======
echo "== Computing new p3 start sector (p2 End + 1) =="
P2_END_NOW="$(sudo parted -sm "$LOOP" unit s print | awk -F: '$1=="2"{gsub(/s/,"",$3); print $3}')"
[[ -n "${P2_END_NOW:-}" ]] || { echo "Could not read latest p2 End, exiting."; exit 1; }
P3_START=$(( P2_END_NOW + 1 ))
echo "p2 End: $P2_END_NOW"
echo "p3 Start: $P3_START"

echo "== Rebuilding p3 at the end =="
sudo parted -s "$LOOP" unit s "mkpart primary ${P3_START}s 100%"
# Set partition type to 0x07 (exFAT/NTFS): parted defaults to 83 (Linux), which Windows treats as hidden and does not show
sudo sfdisk --change-id "$LOOP" 3 7 2>/dev/null || true
sudo partprobe "$LOOP" || true
settle

echo "== Formatting new p3 =="
P3_DEV="${LOOP}p3"
echo "Using filesystem: $ORIG_P3_FS, label: $ORIG_P3_LABEL"
case "$ORIG_P3_FS" in
  vfat|fat32|fat16)
    sudo mkfs.vfat -F 32 -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  ntfs)
    sudo mkfs.ntfs -F -L "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  exfat)
    sudo mkfs.exfat -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
  *)
    echo "Warning: unknown filesystem type $ORIG_P3_FS, defaulting to exfat"
    sudo mkfs.exfat -n "$ORIG_P3_LABEL" "$P3_DEV"
    ;;
esac

# ======= Step 5: Restore data (exact mirror) =======
if (( HAD_P3 )); then
  echo "== Restoring data (exact mirror): $TMP_DIR/p3data -> new p3 =="
  sudo mount "$P3_DEV" "$P3_NEW_MNT"
  # FAT32/exFAT do not support Unix permissions, use --no-perms --no-owner --no-group
  case "$ORIG_P3_FS" in
    vfat|fat32|fat16|exfat)
      sudo rsync -rltD --no-perms --no-owner --no-group --delete $RSYNC_PROGRESS "$TMP_DIR/p3data"/ "$P3_NEW_MNT"/
      ;;
    *)
      sudo rsync -aH --delete $RSYNC_PROGRESS "$TMP_DIR/p3data"/ "$P3_NEW_MNT"/
      ;;
  esac
  sync
  sudo umount "$P3_NEW_MNT"
  echo "Restore complete."
else
  echo "Original image has no p3, skipping restore."
fi

# ======= Step 6: Optional check output =======
echo "== Final partition layout (MiB) =="
sudo parted "$LOOP" unit MiB print || true

# ======= Step 7: Delete tmp and detach loop =======
echo "== Deleting backup directory $TMP_DIR =="
sudo rm -rf "$TMP_DIR"

echo "== Detaching loop device =="
sudo losetup -d "$LOOP" || true
LOOP=""

echo "✅ Done: [back up p1+p3 → delete p3 → shift p2 data right and rebuild p1 (${P1_TARGET_MB}M) → rebuild p2 (${P2_TARGET_MB}M) → rebuild p3 → restore → clean tmp → detach loop]"
