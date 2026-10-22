#!/bin/bash

# ArkOS4Clone on-device update entry point (counterpart of dArkOS's Update.sh)
# Placed where the original Update.sh lives on the device; runs when the user taps "Update" in settings
# Offline mode: put ArkOS4CloneUpdate.sh in /roms/update (or /roms2/update),
#          and the split archives for the matching date in /roms/update/<date>/; if a local script is found it runs directly, without going online;
#          on success the used script and the dated archive folders are deleted automatically

if [[ "$(stat -c "%U" /home/ark)" != "ark" ]]; then
  printf "Fixing home folder permissions.  Please wait..."
  sudo chown -R ark:ark /home/ark
  sudo chmod -R 755 /home/ark
fi

printf "\nChecking for updates.  Please wait..."

LOG_FILE="/home/ark/esupdate.log"

if [ -f "$LOG_FILE" ]; then
  sudo mv -f "$LOG_FILE" "$LOG_FILE.old"
fi

sudo timedatectl set-ntp 1

LOCATION="https://raw.githubusercontent.com/lcdyk0517/arkos4clone-updates/master/update_files"

# ---- Offline mode detection: use a local update script if one exists ----
LOCAL_DIR=""
for d in /roms/update /roms2/update; do
  if [ -f "$d/ArkOS4CloneUpdate.sh" ]; then
    LOCAL_DIR="$d"
    break
  fi
done

if [ -n "$LOCAL_DIR" ]; then
  RUN_SCRIPT="$LOCAL_DIR/ArkOS4CloneUpdate.sh"
  printf "\nUsing local update script in ${LOCAL_DIR}..."
else
  RUN_SCRIPT="/home/ark/ArkOS4CloneUpdate.sh"
  sudo rm -f "$RUN_SCRIPT"
  wget -t 3 -T 60 --no-check-certificate "$LOCATION"/ArkOS4CloneUpdate.sh -O "$RUN_SCRIPT" -a "$LOG_FILE"
  if [ $? -ne 0 ] || [ ! -s "$RUN_SCRIPT" ]; then
    sudo rm -f "$RUN_SCRIPT"
    sudo msgbox "Looks like OTA updating is currently down or your wifi or internet connection is not functioning correctly."
    printf "There was an error with attempting this update." | tee -a "$LOG_FILE"
    exit 1
  fi
fi

sudo chmod -v 777 "$RUN_SCRIPT" | tee -a "$LOG_FILE"

# The update script deletes itself on success, so grab the date first for offline cleanup
UPDATE_DATE="$(grep -m1 '^UPDATE_DATE=' "$RUN_SCRIPT" 2>/dev/null | tr -dc '0-9')"

"$RUN_SCRIPT"

if [ $? -ne 187 ]; then
  # The specific error was already shown in a popup by the update script; the offline script is left in place for troubleshooting, only a downloaded script is cleaned up
  printf "There was an error with attempting this update." | tee -a "$LOG_FILE"
  if [ -z "$LOCAL_DIR" ] && [ -f "$RUN_SCRIPT" ]; then
    rm -f "$RUN_SCRIPT"
  fi
else
  # Update finished: in offline mode delete the used script + all applied dated archive folders, in online mode delete the downloaded script
  if [ -n "$LOCAL_DIR" ]; then
    rm -f "$LOCAL_DIR/ArkOS4CloneUpdate.sh"
    for d in "$LOCAL_DIR"/[0-9]*; do
      [ -d "$d" ] || continue
      DATE_NAME="$(basename "$d")"
      case "$DATE_NAME" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *) continue ;;
      esac
      if [ -f "/home/ark/.update/.${DATE_NAME}" ]; then
        sudo rm -rf "$d"
      fi
    done
  elif [ -f "$RUN_SCRIPT" ]; then
    rm -f "$RUN_SCRIPT"
  fi
fi

if [ ! -z "$(pidof rg351p-js2xbox)" ]; then
  sudo kill -9 "$(pidof rg351p-js2xbox)"
  sudo rm -f /dev/input/by-path/platform-odroidgo2-joypad-event-joystick
fi
