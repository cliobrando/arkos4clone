#!/bin/bash
# Turn Samba file sharing (smbd, nmbd) on or off, now and at boot.
if systemctl is-active --quiet smbd; then
  sudo systemctl disable --now smbd nmbd > /dev/null 2>&1
  printf "\n\n\e[93mSamba file sharing is now OFF (also at boot)...\n"
else
  sudo systemctl unmask smbd nmbd > /dev/null 2>&1
  sudo systemctl enable --now nmbd smbd > /dev/null 2>&1
  if systemctl is-active --quiet smbd; then
    printf "\n\n\e[32mSamba file sharing is now ON (also at boot)...\n"
  else
    printf "\n\n\e[91mSamba could not be started...\n"
  fi
fi
printf "\033[0m"
sleep 3
