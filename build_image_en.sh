#!/usr/bin/env bash
set -euo pipefail

# ArkOS4Clone one-shot build script
# Usage: sudo ./build_image.sh <image path> [work dir]
# The work dir holds the image copy and intermediate files, an
# ext4 filesystem is recommended for best performance

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Timestamp format (same as scripts/clone_support.sh)
BUILD_DATE="$(TZ=Asia/Shanghai date +%Y%m%d)"
OUTPUT_NAME="ArkOS4Clone-${BUILD_DATE}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    log_error "Please run this script with sudo"
    exit 1
  fi
}

check_image() {
  local img="$1"
  if [[ ! -f "$img" ]]; then
    log_error "Image file not found: $img"
    exit 1
  fi
  if [[ ! -r "$img" ]]; then
    log_error "Cannot read image file: $img"
    exit 1
  fi
  log_ok "Source image: $img"
}

check_tools() {
  local tools=(losetup mount umount parted rsync dd xz mkfs.exfat mkfs.ext4 e2fsck wipefs)
  for t in "${tools[@]}"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      log_error "Missing required tool: $t"
      exit 1
    fi
  done
  log_ok "Required tools present"
}

check_uboot_files() {
  local uboot_dir="$SCRIPT_DIR/uboot"
  local files=("idbloader.img" "uboot.img" "trust.img" "flash_uboot.sh")
  for f in "${files[@]}"; do
    if [[ ! -f "$uboot_dir/$f" ]]; then
      log_error "Missing U-Boot file: $uboot_dir/$f"
      exit 1
    fi
  done
  log_ok "U-Boot files checked"
}

check_jdk_file() {
  local jdk_dir="$SCRIPT_DIR/roms/j2me/jdk"
  local jdk_file="$SCRIPT_DIR/zulu11.48.21-ca-jdk11.0.11-linux_aarch64.tar.gz"
  local jdk_url="https://cdn.azul.com/zulu-embedded/bin/zulu11.48.21-ca-jdk11.0.11-linux_aarch64.tar.gz"

  if [[ -d "$jdk_dir" ]]; then
    log_ok "JDK already present: roms/j2me/jdk"
    return
  fi

  if [[ ! -f "$jdk_file" ]]; then
    log_info "Downloading JDK file..."
    # Download as the invoking user (avoids permission problems)
    if [[ -n "${SUDO_USER:-}" ]]; then
      if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$jdk_file" "$jdk_url"; then
        log_ok "JDK download complete"
      else
        log_error "JDK download failed"
        sudo -u "$SUDO_USER" rm -f "$jdk_file" 2>/dev/null || true
        exit 1
      fi
    else
      if wget $WGET_OPTS -O "$jdk_file" "$jdk_url"; then
        log_ok "JDK download complete"
      else
        log_error "JDK download failed"
        rm -f "$jdk_file"
        exit 1
      fi
    fi
  else
    log_ok "Using local JDK cache: $(basename "$jdk_file")"
  fi

  log_info "Extracting JDK to roms/j2me/jdk..."
  mkdir -p "$SCRIPT_DIR/roms/j2me"
  tar -xf "$jdk_file" -C "$SCRIPT_DIR/roms/j2me"
  mv "$SCRIPT_DIR/roms/j2me/zulu11.48.21-ca-jdk11.0.11-linux_aarch64" "$jdk_dir"
  rm -f "$jdk_file"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$SCRIPT_DIR/roms/j2me"
  fi
  log_ok "JDK ready: roms/j2me/jdk"
}

check_pm_libs() {
  local pm_libs_dir="$SCRIPT_DIR/roms/tools/PortMaster/libs"
  local runtimes_url="https://github.com/PortsMaster/PortMaster-New/releases/download/2026-09-02_1031/runtimes.all.aarch64.zip"

  # Required file list
  local required_files=(
    "ags_3.6.squashfs"
    "dotnet-8.0.12.squashfs"
    "frt_2.1.6.squashfs"
    "frt_3.0.6_v1.squashfs"
    "frt_3.1.2.squashfs"
    "frt_3.2.3.squashfs"
    "frt_3.3.4.squashfs"
    "frt_3.4.5.squashfs"
    "frt_3.5.2.squashfs"
    "frt_3.5.3.squashfs"
    "frt_3.6.squashfs"
    "frt_4.0.4.squashfs"
    "frt_4.1.3.squashfs"
    "gmtoolkit.squashfs"
    "godot_4.2.2.mono.squashfs"
    "godot_4.2.2.squashfs"
    "godot_4.3.mono.squashfs"
    "godot_4.3.squashfs"
    "godot_4.4.1.mono.squashfs"
    "godot_4.4.1.squashfs"
    "godot_4.4.mono.squashfs"
    "godot_4.4.squashfs"
    "godot_4.5.mono.squashfs"
    "godot_4.5.squashfs"
    "godot_4.6.3.mono.squashfs"
    "godot_4.7.1.mono.squashfs"
    "mesa_pkg_0.1.squashfs"
    "mono-6.12.0.122-aarch64.squashfs"
    "python_3.11.squashfs"
    "pyxel_2.2.8_python_3.11.squashfs"
    "pyxel_2.3.18_python_3.11.squashfs"
    "pyxel_2.4.6_python_3.11.squashfs"
    "pyxel_2.9.5_python_3.11.squashfs"
    "qt6-eglfs-6.6.3-aarch64.squashfs"
    "renpy_8.1.3.squashfs"
    "renpy_8.3.4.squashfs"
    "rlvm.squashfs"
    "solarus-1.6.5.squashfs"
    "weston_pkg_0.2.squashfs"
    "zulu11.48.21-ca-jdk11.0.11-linux.squashfs"
    "zulu17.48.15-ca-jdk17.0.10-linux.squashfs"
    "zulu17.54.21-ca-jre17.0.13-linux.squashfs"
    "zulu23.32.11-ca-jre23.0.2-linux.squashfs"
    "zulu8.86.0.25-ca-jdk8.0.452-linux.squashfs"
  )

  # Check for missing files
  local missing=0
  for f in "${required_files[@]}"; do
    if [[ ! -f "$pm_libs_dir/$f" ]]; then
      missing=1
      break
    fi
  done

  if [[ $missing -eq 0 ]]; then
    log_ok "pm_libs files complete: roms/tools/PortMaster/libs"
    return
  fi

  log_info "Downloading PortMaster runtimes (~1.6GB)..."
  mkdir -p "$pm_libs_dir"
  local zip_file="$pm_libs_dir/runtimes.zip"

  # Download
  if [[ -n "${SUDO_USER:-}" ]]; then
    if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$zip_file" "$runtimes_url"; then
      log_ok "runtimes download complete"
    else
      log_error "runtimes download failed"
      sudo -u "$SUDO_USER" rm -f "$zip_file" 2>/dev/null || true
      exit 1
    fi
    # Extract
    log_info "Extracting runtimes..."
    sudo -u "$SUDO_USER" unzip -o -q "$zip_file" -d "$pm_libs_dir"
    sudo -u "$SUDO_USER" rm -f "$zip_file"
  else
    if wget $WGET_OPTS -O "$zip_file" "$runtimes_url"; then
      log_ok "runtimes download complete"
    else
      log_error "runtimes download failed"
      rm -f "$zip_file"
      exit 1
    fi
    # Extract
    log_info "Extracting runtimes..."
    unzip -o -q "$zip_file" -d "$pm_libs_dir"
    rm -f "$zip_file"
  fi

  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$pm_libs_dir"
  fi
  log_ok "pm_libs files ready: roms/tools/PortMaster/libs"
}

check_install_portmaster() {
  # Fetch the latest release's Install.PortMaster.sh from PortMaster-GUI
  # and put it into roms/tools/ (bind-mounted as /opt/system/Tools on
  # the device). Cached: skip the download when the local file is not
  # older than the online asset's update time; if the API fails, reuse
  # a local copy (error only when there is none)
  local dst="$SCRIPT_DIR/roms/tools/Install.PortMaster.sh"
  local url="" updated_at=""

  log_info "Fetching latest Install.PortMaster.sh info..."
  local api_json
  # --connect-timeout/--max-time: sudo strips proxy env vars, and direct
  # GitHub API access (no proxy) can hang forever
  api_json=$(curl -s --connect-timeout 8 --max-time 25 \
    https://api.github.com/repos/PortsMaster/PortMaster-GUI/releases/latest 2>/dev/null || true)
  if [[ -n "$api_json" ]]; then
    # NOTE: the JSON must be fed via a here-string -- the script's stdin
    # is a sudo password pipe (EOF), so python reading stdin would get
    # empty input and always fail to parse
    read -r url updated_at <<< "$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    a = next(a for a in d['assets'] if a['name'] == 'Install.PortMaster.sh')
    print(a['browser_download_url'], a['updated_at'])
except Exception:
    pass
" "$api_json" 2>/dev/null || true)"
  fi

  # Cache check: skip the download if the local file exists and is not
  # older than the online update time
  if [[ -s "$dst" ]]; then
    if [[ -n "$updated_at" ]]; then
      local asset_epoch local_epoch
      asset_epoch=$(date -d "$updated_at" +%s 2>/dev/null || echo 0)
      local_epoch=$(stat -c%Y "$dst" 2>/dev/null || echo 0)
      if (( local_epoch >= asset_epoch )); then
        log_ok "Local Install.PortMaster.sh is up to date ($(date -d "@$local_epoch" '+%F %T')), skipping download"
        return 0
      fi
      log_info "Newer version online ($(date -d "@$asset_epoch" '+%F %T')), re-downloading..."
    else
      log_warn "Cannot check for updates (GitHub API unreachable), using the local copy"
      log_warn "Tip: if you need a proxy, run sudo -E ./build_image.sh ... to keep environment variables"
      return 0
    fi
  else
    if [[ -z "$url" ]]; then
      log_error "Failed to get the Install.PortMaster.sh download URL (GitHub API) and there is no local copy"
      exit 1
    fi
  fi

  mkdir -p "$(dirname "$dst")"
  log_info "Downloading Install.PortMaster.sh ($url)..."
  if [[ -n "${SUDO_USER:-}" ]]; then
    sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$dst" "$url"
  else
    wget $WGET_OPTS -O "$dst" "$url"
  fi
  if [[ ! -s "$dst" ]]; then
    log_error "Install.PortMaster.sh download failed"
    rm -f "$dst"
    exit 1
  fi
  chmod +x "$dst"
  log_ok "Install.PortMaster.sh ready: roms/tools/ ($(du -h "$dst" | cut -f1))"
}

check_work_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    log_info "Creating work dir: $dir"
    mkdir -p "$dir"
  fi
  # Check writability
  if [[ ! -w "$dir" ]]; then
    log_error "Work dir is not writable: $dir"
    exit 1
  fi
  log_ok "Work dir: $dir"
}

check_portmaster() {
  local pm_dir="$SCRIPT_DIR/PortMaster"
  local pm_dst="$SCRIPT_DIR/roms/tools/PortMaster"
  local pm_url="https://github.com/PortsMaster/PortMaster-GUI/releases/download/2026.09.13-0343/PortMaster.zip"

  if [[ -d "$pm_dst" && -f "$pm_dst/PortMaster.sh" ]]; then
    log_ok "PortMaster already present: roms/tools/PortMaster"
    return
  fi

  if [[ ! -d "$pm_dir" || ! -f "$pm_dir/PortMaster.sh" ]]; then
    log_info "Downloading PortMaster..."
    local zip_file="$SCRIPT_DIR/PortMaster.zip"

    if [[ -n "${SUDO_USER:-}" ]]; then
      if sudo -u "$SUDO_USER" wget $WGET_OPTS -O "$zip_file" "$pm_url"; then
        log_ok "PortMaster download complete"
      else
        log_error "PortMaster download failed"
        sudo -u "$SUDO_USER" rm -f "$zip_file" 2>/dev/null || true
        exit 1
      fi
      log_info "Extracting PortMaster..."
      sudo -u "$SUDO_USER" unzip -q -o "$zip_file" -d "$SCRIPT_DIR"
      sudo -u "$SUDO_USER" rm -f "$zip_file"
    else
      if wget $WGET_OPTS -O "$zip_file" "$pm_url"; then
        log_ok "PortMaster download complete"
      else
        log_error "PortMaster download failed"
        rm -f "$zip_file"
        exit 1
      fi
      # Extract
      log_info "Extracting PortMaster..."
      unzip -q -o "$zip_file" -d "$SCRIPT_DIR"
      rm -f "$zip_file"
    fi
  else
    log_ok "Using local PortMaster cache: ./PortMaster"
  fi

  mkdir -p "$pm_dst"
  cp -rf "$pm_dir/." "$pm_dst/"
  cp -f "$pm_dir/PortMaster.sh" "$SCRIPT_DIR/roms/tools/PortMaster.sh"
  if [[ -n "${SUDO_USER:-}" ]]; then
    chown -R "$SUDO_USER" "$SCRIPT_DIR/roms/tools"
  fi
  log_ok "PortMaster ready: roms/tools/PortMaster"
}

check_clone_dependencies() {
  log_info "Checking scripts/clone_support.sh dependencies..."
  local missing=0
  local missing_list=""

  # Required directories
  local dirs=(
    "boot/dArkOS"
    "boot/ArkOS"
    "rootfs/dArkOS"
    "rootfs/ArkOS"
  )

  # Required files
  local files=(
    "boot/dArkOS/dtb_selector_linux32"
    "boot/dArkOS/dtb_selector_macos"
    "boot/dArkOS/dtb_selector_win32.exe"
    "boot/dArkOS/clone.sh"
    "boot/dArkOS/expandtoexfat.sh"
    "boot/ArkOS/expandtoexfat.sh"
  )

  for f in "${files[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
      missing=1
      missing_list="$missing_list\n  Missing file: $f"
    fi
  done

  if [[ $missing -eq 1 ]]; then
    log_error "scripts/clone_support.sh dependency check failed"
    echo -e "$missing_list"
    exit 1
  fi

  log_ok "scripts/clone_support.sh dependency check passed"
}

step_build_dtb_selector() {
  log_info "Step 0/8: building the dtb_selector tool..."
  if [[ -f "$SCRIPT_DIR/scripts/build_dtb_selector.sh" ]]; then
    cd "$SCRIPT_DIR"
    # Build as the invoking user (keeps the PATH environment)
    if [[ -n "${SUDO_USER:-}" ]]; then
      if sudo -u "$SUDO_USER" env PATH="$PATH" ./scripts/build_dtb_selector.sh; then
        log_ok "dtb_selector build complete"
      else
        log_warn "dtb_selector build failed, skipping (it may already exist)"
      fi
    else
      if ./scripts/build_dtb_selector.sh; then
        log_ok "dtb_selector build complete"
      else
        log_warn "dtb_selector build failed, skipping (it may already exist)"
      fi
    fi
    cd - > /dev/null
  else
    log_warn "scripts/build_dtb_selector.sh not found, skipping"
  fi
}

copy_image() {
  local src="$1"
  local dst="$2"
  log_info "Step 1/8: copying the source image to the work dir..."
  cp "$src" "$dst"
  log_ok "Work copy created: $dst"
}

step_grow() {
  local img="$1"
  log_info "Step 2/8: growing the image partitions..."
  if "$SCRIPT_DIR/scripts/repart_image.sh" "$img"; then
    log_ok "Partition resize complete"
  else
    log_error "Partition resize failed"
    exit 1
  fi
}

step_convert_rootfs() {
  local img="$1"
  if [[ "${ARKOS_ROOTFS:-ext4}" == "keep" ]]; then
    log_info "Step 2/8: ARKOS_ROOTFS=keep, leaving the p2 filesystem unchanged"
    return
  fi
  log_info "Step 2/8: converting p2 to ext4 (if it is btrfs)..."
  if "$SCRIPT_DIR/scripts/convert_rootfs.sh" "$img"; then
    log_ok "p2 filesystem conversion complete"
  else
    log_error "p2 filesystem conversion failed"
    exit 1
  fi
}

step_flash_uboot() {
  local img="$1"
  log_info "Step 3/8: flashing U-Boot..."
  # Must run inside the uboot directory, with an absolute image path
  local abs_img
  if [[ "$img" = /* ]]; then
    abs_img="$img"
  else
    abs_img="$(pwd)/$img"
  fi
  cd "$SCRIPT_DIR/uboot"
  if ./flash_uboot.sh -y -i "$abs_img"; then
    log_ok "U-Boot flashing complete"
  else
    log_error "U-Boot flashing failed"
    cd "$SCRIPT_DIR"
    exit 1
  fi
  cd "$SCRIPT_DIR"
}

step_mount() {
  local img="$1"
  log_info "Step 4/8: mounting the image..."
  if "$SCRIPT_DIR/scripts/mount_arkos.sh" mount "$img"; then
    log_ok "Image mounted"
  else
    log_error "Image mount failed"
    exit 1
  fi
}

step_inject() {
  log_info "Step 5/8: injecting customizations..."
  if "$SCRIPT_DIR/scripts/clone_support.sh"; then
    log_ok "Content injection complete"
  else
    log_error "Content injection failed"
    # Try to unmount
    "$SCRIPT_DIR/scripts/mount_arkos.sh" unmount 2>/dev/null || true
    exit 1
  fi
}

step_unmount() {
  log_info "Step 6/8: unmounting the image..."
  # Online trim before unmounting: zero/punch free blocks so the xz
  # compression is faster and the archive doesn't grow
  if mountpoint -q "${ARKOS_MNT}/root" && command -v fstrim >/dev/null 2>&1; then
    log_info "Running fstrim on the root partition (zeroing free blocks)..."
    fstrim -v "${ARKOS_MNT}/root" || log_warn "fstrim failed (device doesn't support discard), skipping"
  fi
  if "$SCRIPT_DIR/scripts/mount_arkos.sh" unmount; then
    log_ok "Image unmounted"
  else
    log_error "Image unmount failed"
    exit 1
  fi
}

step_verify_fs() {
  log_info "Step 7/8: verifying the p2 filesystem ..."
  local img="$1"
  local loop="" rc=0 fstype=""

  # Declare the cleanup function before attaching the trap;
  # ${loop:-} for compat with set -u
  _verify_fs_cleanup() {
    if [[ -n "${loop:-}" ]]; then
      losetup -d "$loop" 2>/dev/null || true
    fi
    return 0
  }
  trap _verify_fs_cleanup RETURN

  # Crucial: check that a loop device was obtained *before* entering
  # trap-protected territory
  if ! loop=$(losetup --find -P --show "$img"); then
    loop=""
    log_error "Cannot create a loop device for $img"
    return 1
  fi

  fstype=$(blkid -o value -s TYPE "${loop}p2" 2>/dev/null || true)

  case "$fstype" in
    ext2|ext3|ext4)
      log_info "Verifying the p2 filesystem (e2fsck, $fstype)..."
      # -e makes the 'script' tool pass e2fsck's exit code through;
      # -y auto-answers the repair prompts
      script -e -q -c "e2fsck -fvy '${loop}p2'" /dev/null
      rc=$?
      if (( rc > 3 )); then
        log_error "p2 $fstype filesystem has unrepaired errors (e2fsck rc=$rc)"
        return 1
      fi
      ;;

    btrfs)
      log_info "Verifying the p2 filesystem (btrfs check, $fstype)..."
      if btrfs check --readonly "${loop}p2"; then
        rc=0
      else
        rc=$?
      fi
      if (( rc != 0 )); then
        log_error "p2 btrfs filesystem has errors (btrfs check rc=$rc)"
        return 1
      fi
      ;;

    "")
      log_error "Cannot determine the filesystem type of ${loop}p2 (blkid returned nothing)"
      return 1
      ;;

    *)
      log_error "Unsupported filesystem type: $fstype"
      return 1
      ;;
  esac

  log_ok "p2 filesystem verification passed ($fstype, rc=$rc)"

  # Full-byte readback gate for roms.tar: drop caches to force real
  # disk reads, intercepting btrfs/filesystem data block corruption
  # (the root cause of on-device EIO)
  mkdir -p /mnt/arkos_verify
  if mount -o ro "${loop}p2" /mnt/arkos_verify 2>/dev/null; then
    if [[ -f /mnt/arkos_verify/roms.tar ]]; then
      sync
      echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
      log_info "roms.tar full-byte readback check (cold cache, real block reads)..."
      if ! md5sum /mnt/arkos_verify/roms.tar > /dev/null 2>&1; then
        log_error "roms.tar readback hit an I/O error -- image data blocks are corrupt"
        umount /mnt/arkos_verify 2>/dev/null
        losetup -d "$loop" 2>/dev/null
        exit 1
      fi
      local members
      members=$(tar -tf /mnt/arkos_verify/roms.tar 2>/dev/null | wc -l)
      log_ok "roms.tar readback verified (${members} members, no I/O errors)"
    else
      log_warn "No roms.tar in the image, skipping the readback check"
    fi
    umount /mnt/arkos_verify 2>/dev/null || true
  fi
  rmdir /mnt/arkos_verify 2>/dev/null || true
}

step_compress() {
  local img="$1"
  local xz_file="${img}.xz"
  log_info "Step 8/8: compressing the image (xz -5)..."

  # Compression level 5, multithreaded
  if xz -5 -T0 -v "$img"; then
    log_ok "Compression complete: $xz_file"
    log_ok "File size: $(du -h "$xz_file" | cut -f1)"
    # Checksum sidecar: when the .xz is moved onto drives like /mnt/d
    # (9p), always run md5sum -c to verify it
    # (large writes on WSL 9p may silently lose data -- that is what
    # once corrupted a whole dArkOS image into all-zeros)
    md5sum "$xz_file" > "${xz_file}.md5"
    log_ok "Checksum file: ${xz_file}.md5"
  else
    log_error "Compression failed"
    exit 1
  fi
}

move_to_script_dir() {
  local xz_file="$1"
  local dest="$SCRIPT_DIR/$(basename "$xz_file")"
  log_info "Moving the output file into the script directory..."
  mv "$xz_file" "$dest" || true
  log_ok "Output file: $dest"
}

show_usage() {
  cat << USAGE
ArkOS4Clone one-shot build script

Usage:
  sudo ./build_image.sh <source image path> [work dir] [--ci]

Arguments:
  source image path  required, the original ArkOS image file
  work dir           optional, holds the image copy and intermediate files;
                     an ext4 filesystem is recommended for best performance;
                     defaults to the source image's directory
  --ci               optional, quiet mode, reduces noisy download logs

Environment variables:
  ARKOS_MNT       mount path (default: <work dir>/mnt)
  ARKOS_WORK_DIR  temporary work dir (default: <work dir>)
  ARKOS_ROOTFS    p2 filesystem: ext4 converts a btrfs p2 to ext4 (default),
                  keep leaves it unchanged

Examples:
  # Default work dir (the source image's directory)
  sudo ./build_image.sh /path/to/ArkOS-*.img

  # Explicit work dir (recommended, ext4 filesystem)
  sudo ./build_image.sh /mnt/e/ArkOS.img /home/lcdyk/arkos

Build steps:
  0. Build the dtb_selector tool (scripts/build_dtb_selector.sh)
  1. Copy the source image to the work dir
  2. Partition resize (scripts/repart_image.sh): p1 to 256M, p2 to 12G (dArkOS)
     or 11G (ArkOS), p3 rebuilt at its original size
     then convert p2 from btrfs to ext4 (scripts/convert_rootfs.sh)
  3. Flash U-Boot (flash_uboot.sh)
  4. Mount the image (scripts/mount_arkos.sh mount)
  5. Inject the customizations (scripts/clone_support.sh)
  6. Unmount the image (scripts/mount_arkos.sh unmount)
  7. Verify the p2 filesystem
  8. Compress the image and move the output into the script directory

Output:
  <script dir>/ArkOS4Clone-MMDDYYYY.img.xz

Notes:
  - The source image file is never modified
  - Prefer an ext4 work dir; avoid WSL /mnt paths for performance

USAGE
}

main() {
  # Check root privileges first
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    log_error "Please run this script with sudo"
    exit 1
  fi

  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_usage
    exit 0
  fi

  if [[ $# -lt 1 ]]; then
    log_error "Missing argument: image path"
    echo ""
    show_usage
    exit 1
  fi

  local source_image="$1"

  # Determine the work dir
  local work_dir
  if [[ $# -ge 2 ]]; then
    work_dir="$2"
  else
    # Default to the source image's directory
    work_dir="$(cd "$(dirname "$source_image")" && pwd)"
  fi

  # Make it an absolute path
  if [[ "$work_dir" != /* ]]; then
    work_dir="$(pwd)/$work_dir"
  fi

  # Environment variables
  ARKOS_MNT="${ARKOS_MNT:-${work_dir}/mnt}"
  ARKOS_WORK_DIR="${ARKOS_WORK_DIR:-${work_dir}}"
  ARKOS_IMAGE_NAME="$(basename "$source_image")"
  export ARKOS_MNT ARKOS_WORK_DIR ARKOS_IMAGE_NAME

  # Third argument --ci: quiet mode, reduces log spam in CI
  if [[ "${3:-}" == "--ci" ]]; then
    WGET_OPTS="-q"
    export ARKOS_QUIET=1
  else
    WGET_OPTS="-q --show-progress"
  fi

  # Output prefix depends on the source image name
  local output_prefix
  if [[ "$ARKOS_IMAGE_NAME" == *dArkOS* ]]; then
    output_prefix="dArkOS4Clone"
  else
    output_prefix="ArkOS4Clone"
  fi
  local work_image="${work_dir}/${output_prefix}-${BUILD_DATE}.img"

  echo "========================================"
  echo "  ArkOS4Clone one-shot build script"
  echo "========================================"
  echo "Source image:   $source_image"
  echo "Work dir:       $work_dir"
  echo "Work copy:      $work_image"
  echo "Mount path:     $ARKOS_MNT"
  echo "========================================"
  echo ""

  # Step 0: build the dtb_selector (no root needed)
  step_build_dtb_selector
  echo ""

  # Pre-checks (no root needed)
  check_tools
  check_jdk_file
  check_portmaster
  check_pm_libs
  check_install_portmaster
  check_clone_dependencies

  # Root-only checks
  check_image "$source_image"
  check_work_dir "$work_dir"
  check_uboot_files

  # Step 1: copy the image
  echo ""
  copy_image "$source_image" "$work_image"
  # Step 2: resize the partitions
  echo ""
  step_grow "$work_image"
  step_convert_rootfs "$work_image"
  # Step 3: flash U-Boot
  echo ""
  step_flash_uboot "$work_image"
  # Step 4: mount the image
  echo ""
  step_mount "$work_image"
  # Step 5: inject the customizations
  echo ""
  step_inject
  # Step 6: unmount the image
  echo ""
  step_unmount
  # Step 7: verify the p2 filesystem
  echo ""
  step_verify_fs "$work_image"
  # Step 8: compress and move
  echo ""
  step_compress "$work_image"
  move_to_script_dir "${work_image}.xz"

  echo ""
  echo "========================================"
  log_ok "Build complete!"
  echo "Output file: $SCRIPT_DIR/$(basename "${work_image}").xz"
  echo "Source kept: $source_image"
  echo "========================================"
}

main "$@"
