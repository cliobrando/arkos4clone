#!/bin/sh
# Wait for ES's first frame, at most 30 s, then let the writers run.
i=0
while [ ! -e /tmp/es-ready ] && [ "$i" -lt 300 ]; do
  sleep 0.1
  i=$((i + 1))
done
# Flush every 15 s instead of the kernel's 5 s, as ROCKNIX does: fewer small
# SD writes (they stall reads on these cards); a hard power-off can lose up
# to 15 s of writes.
echo 1500 > /proc/sys/vm/dirty_writeback_centisecs
