#!/bin/sh
# Every flag a paashup needs, so the container only has to be started with the host network,
# the host PID namespace and / mounted read-only at /host. Arguments given at run time are
# added after these (they don't replace them).
set -e
exec /bin/node_exporter \
  --path.rootfs=/host \
  --path.udev.data=/host/run/udev/data \
  --collector.textfile.directory=/host/var/lib/node_exporter/textfile \
  --web.listen-address="${LISTEN_ADDRESS:-172.31.0.1:9100}" \
  "$@"
