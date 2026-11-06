#!/bin/sh
# Wait for ES's first frame, at most 30 s, then let the writers run.
i=0
while [ ! -e /tmp/es-ready ] && [ "$i" -lt 300 ]; do
  sleep 0.1
  i=$((i + 1))
done
echo 500 > /proc/sys/vm/dirty_writeback_centisecs
