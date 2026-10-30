#!/bin/sh
# Every flag a paashup needs, so the container only has to be started with the host network,
# the host PID namespace and / mounted read-only at /host. Arguments given at run time are
# added after these (they don't replace them).
set -e
TEXTFILE_DIR=/tmp/textfile
mkdir -p "$TEXTFILE_DIR"
/apt-metrics.sh "$TEXTFILE_DIR" &

  iface="${LISTEN_INTERFACE:-traefik}"
  ip="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [ -n "$ip" ]; then
    LISTEN_ADDRESS="$ip:9100"
  else
    echo "entrypoint: no IPv4 address on interface '$iface', falling back to 172.31.0.1:9100" >&2
  fi
fi

exec setuidgid nobody /bin/node_exporter \
  --path.rootfs=/host \
  --path.udev.data=/host/run/udev/data \
  --collector.textfile.directory="$TEXTFILE_DIR" \
  --web.listen-address="${LISTEN_ADDRESS:-172.31.0.1:9100}" \
  "$@"
