#!/bin/bash
# Warm what ES actually needs at cold start: the /roms directory entries and
# gamelist metadata (~2-3 s of eMMC reads). Deliberately NOT the binary or
# libraries: a full preload storm slowed ES's scan by tens of seconds, while
# the binary page-in is already sub-second by itself.
( ls /roms >/dev/null 2>&1
  for d in /roms/*/; do ls "$d" >/dev/null 2>&1; done
  find /roms -maxdepth 2 -name gamelist.xml | xargs cat 2>/dev/null > /dev/null
  cat /etc/emulationstation/es_systems.cfg >/dev/null 2>&1
  cat /home/ark/.emulationstation/collections/*.cfg >/dev/null 2>&1
) >/dev/null 2>&1 &
exit 0
