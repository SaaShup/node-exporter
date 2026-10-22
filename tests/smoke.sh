#!/usr/bin/env bash
# Smoke test: the image starts with the flags baked in entrypoint.sh, serves metrics, keeps the
# run-time arguments, and apt-metrics.sh writes the textfile metrics from the host's apt.
#   tests/smoke.sh               builds the image from the repo
#   IMAGE=<ref> tests/smoke.sh   tests an existing image
# Needs docker and curl. Listens on 127.0.0.1:$SMOKE_PORT (default 19100) with the host network.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=0
if [ -z "${IMAGE:-}" ]; then IMAGE=node-exporter:smoke; BUILD=1; fi
HOST_IMAGE=node-exporter-smoke-host
PORT="${SMOKE_PORT:-19100}"
ADDR="127.0.0.1:$PORT"
NAME="node-exporter-smoke-$$"
TMP="$(mktemp -d)"
failures=0

cleanup() {
  docker rm -f "$NAME" "$NAME-host" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { echo "  ok   $*"; }
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }

# expect <file> <regex> <label>
expect() {
  if grep -Eq "$2" "$1"; then pass "$3"; else fail "$3 (no line matching: $2)"; fi
}

# wait_metrics <path> <out> <regex>: retries until the endpoint serves a line matching regex
# (apt-metrics.sh writes its file a few seconds after the start) or the container stops
wait_metrics() {
  for _ in $(seq 1 60); do
    if curl -fsS "http://$ADDR$1" -o "$2" 2>/dev/null && grep -Eq "$3" "$2"; then return 0; fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != "true" ]; then break; fi
    sleep 1
  done
  echo "--- container logs ---"; docker logs "$NAME" 2>&1 | tail -30
  return 1
}

if [ "$BUILD" = 1 ]; then
  echo "== build $IMAGE"
  docker build -q -t "$IMAGE" . >/dev/null
fi

echo "== labels and env"
labels="$(docker image inspect -f '{{json .Config.Labels}}' "$IMAGE")"
[[ "$labels" == *'"prometheus_scrape":"true"'* ]] && pass "prometheus_scrape=true" || fail "prometheus_scrape label: $labels"
[[ "$labels" == *'"prometheus_address":"172.31.0.1:9100"'* ]] && pass "prometheus_address=172.31.0.1:9100" || fail "prometheus_address label: $labels"
env="$(docker image inspect -f '{{json .Config.Env}}' "$IMAGE")"
[[ "$env" == *'LISTEN_ADDRESS=172.31.0.1:9100'* ]] && pass "default LISTEN_ADDRESS" || fail "LISTEN_ADDRESS env: $env"

echo "== default address without the traefik network"
if ip -4 addr 2>/dev/null | grep -q 'inet 172\.31\.0\.1/'; then
  echo "  skip 172.31.0.1 exists on this host"
else
  docker run -d --name "$NAME" --network host --pid host -v /:/host:ro,rslave "$IMAGE" >/dev/null
  docker wait "$NAME" >/dev/null 2>&1 || true
  if docker logs "$NAME" 2>&1 | grep -q 'cannot assign requested address'; then
    pass "exits with 'cannot assign requested address'"
  else
    fail "expected exit with 'cannot assign requested address'"; docker logs "$NAME" 2>&1 | tail -10
  fi
  docker rm -f "$NAME" >/dev/null
fi

echo "== run as documented (host /, host network, host PID)"
docker run -d --name "$NAME" --network host --pid host -v /:/host:ro,rslave \
  -e LISTEN_ADDRESS="$ADDR" "$IMAGE" >/dev/null
m="$TMP/metrics"
if wait_metrics /metrics "$m" '^node_reboot_required '; then
  pass "metrics served on $ADDR"
  expect "$m" '^node_exporter_build_info\{' "node_exporter_build_info"
  expect "$m" '^node_uname_info\{' "node_uname_info"
  expect "$m" '^node_boot_time_seconds ' "node_boot_time_seconds"
  expect "$m" '^node_memory_MemTotal_bytes ' "node_memory_MemTotal_bytes"
  # rootfs is /host: the host's / must be reported as mountpoint="/", not "/host"
  expect "$m" '^node_filesystem_size_bytes\{[^}]*mountpoint="/"' "filesystem / seen through --path.rootfs"
  if grep -Eq '^node_filesystem_size_bytes\{[^}]*mountpoint="/host' "$m"; then
    fail "filesystem mountpoints still prefixed with /host"
  else
    pass "no /host-prefixed mountpoints"
  fi
  # collectors that must work on any VM (the others depend on hardware: zfs, nfs, infiniband...)
  for c in cpu diskstats filesystem loadavg meminfo netdev stat time uname textfile; do
    expect "$m" "^node_scrape_collector_success\{collector=\"$c\"\} 1$" "collector $c"
  done
  expect "$m" '^node_reboot_required [01]$' "node_reboot_required from the host"
  if [ -x /usr/bin/apt-get ]; then
    expect "$m" '^apt_upgrades_pending [0-9]+$' "apt_upgrades_pending from the host's apt"
  else
    echo "  skip apt_upgrades_pending: no apt on this host"
  fi
  expect "$m" '^node_textfile_scrape_error 0$' "node_textfile_scrape_error 0"
else
  fail "metrics not served on $ADDR"
fi
# default columns: `docker top -o` fails with --pid host
procs="$(docker top "$NAME" 2>/dev/null || true)"
if grep -E '/bin/node_exporter' <<<"$procs" | grep -Eq '^(nobody|65534) '; then
  pass "node_exporter runs as nobody"
else
  fail "node_exporter not running as nobody: $procs"
fi
grep -q 'apt-metrics.sh' <<<"$procs" && pass "apt-metrics.sh running" || fail "apt-metrics.sh not running: $procs"
if docker logs "$NAME" 2>&1 | grep -E 'level=ERROR|apt-metrics:'; then
  fail "errors in container logs"
else
  pass "no error in logs"
fi
docker rm -f "$NAME" >/dev/null

echo "== apt metrics on a known host, run-time arguments"
# a Debian host where a reboot is required, unattended-upgrades reboots at 02:30 Paris time
# and has planned one
docker build -q -t "$HOST_IMAGE" - >/dev/null <<'EOF'
FROM debian:trixie-slim
RUN printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
      > /etc/apt/apt.conf.d/20auto-upgrades \
 && printf 'Unattended-Upgrade::Automatic-Reboot "true";\nUnattended-Upgrade::Automatic-Reboot-Time "02:30";\n' \
      > /etc/apt/apt.conf.d/52reboot \
 && ln -sf /usr/share/zoneinfo/Europe/Paris /etc/localtime && echo Europe/Paris > /etc/timezone \
 && mkdir -p /run/systemd/shutdown && touch /run/reboot-required \
 && printf 'USEC=1893461400000000\nWARN_WALL=1\nMODE=reboot\n' > /run/systemd/shutdown/scheduled
EOF
mkdir "$TMP/root"
docker create --name "$NAME-host" "$HOST_IMAGE" >/dev/null
docker export "$NAME-host" | tar -x -C "$TMP/root" --exclude='dev/*' 2>/dev/null || true
docker rm "$NAME-host" >/dev/null
# an extra argument must be added to the baked flags, not replace them
docker run -d --name "$NAME" --network host --pid host -v "$TMP/root:/host:ro" \
  -e LISTEN_ADDRESS="$ADDR" "$IMAGE" --web.telemetry-path=/smoke-metrics >/dev/null
m="$TMP/metrics-host"
if wait_metrics /smoke-metrics "$m" '^apt_upgrades_pending '; then
  pass "run-time argument applied (--web.telemetry-path)"
  expect "$m" '^node_reboot_required 1$' "node_reboot_required 1"
  expect "$m" '^apt_upgrades_pending 0$' "apt_upgrades_pending 0 (chroot apt-get works)"
  expect "$m" '^apt_unattended_upgrades_enabled 1$' "apt_unattended_upgrades_enabled 1"
  expect "$m" '^apt_auto_reboot_enabled 1$' "apt_auto_reboot_enabled 1"
  expect "$m" '^apt_auto_reboot_time_seconds\{time="02:30",timezone="Europe/Paris"\} 9000$' "apt_auto_reboot_time_seconds 02:30"
  expect "$m" '^apt_auto_reboot_timezone_offset_seconds\{timezone="Europe/Paris"\} (3600|7200)$' "Europe/Paris offset"
  # node_exporter re-exposes textfile values as floats: 1893461400 -> 1.8934614e+09
  expect "$m" '^node_reboot_scheduled_timestamp_seconds (1893461400|1\.8934614e\+09)$' "node_reboot_scheduled_timestamp_seconds"
else
  fail "apt metrics not served on $ADDR/smoke-metrics"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "all checks passed"
