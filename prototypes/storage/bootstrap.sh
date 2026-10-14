#!/bin/sh
set -eu
mount -t tmpfs -o size=8m,uid=1000,gid=1000,nodev,nosuid tmpfs /bounded
if [ "${1:-}" = filtered ]; then
  set -- storage-filter sh /probe/probe.sh
else
  set -- sh /probe/probe.sh
fi
exec setpriv --no-new-privs --bounding-set=-all --inh-caps=-all --ambient-caps=-all \
  --reuid=1000 --regid=1000 --clear-groups "$@"
