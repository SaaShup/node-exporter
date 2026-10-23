# saashup/node-exporter

Repackages `quay.io/prometheus/node-exporter` as a versioned, buildable
image. It reports the VM itself: OS, kernel, uptime,
CPU/RAM/disk/network, and through the textfile collector the pending
reboot (`node_reboot_required`), the upgrades (`apt_upgrades_pending`) and
the unattended-upgrades reboot settings.

- `Dockerfile` → static metadata (Prometheus scrape labels) and default
  flags (`--path.rootfs=/host`, udev data, textfile directory).
- `docker-compose.yml` → everything host-specific.

## What the image sets, what the container must set

Baked in (`entrypoint.sh`): `--path.rootfs=/host`, udev data, the textfile
directory, and `--web.listen-address=$LISTEN_ADDRESS` (default
`172.31.0.1:9100`), plus the labels `prometheus_scrape=true` and
`prometheus_address=172.31.0.1:9100`. Arguments given at run time are
**added** to these flags.

Required at run time:

| Setting | docker run | paasbox UI (Docker container) |
|---|---|---|
| host network | `--network host` | Network: `host` |
| host PID namespace | `--pid host` | PID mode: `host` |
| host filesystem | `-v /:/host:ro,rslave` | Bind: `/` → `/host`, read-only |

`172.31.0.1` is the gateway of the paashup `traefik` network
(`172.31.0.0/16`): Prometheus reaches node-exporter there, and port 9100
is not exposed on the public IP. If that network has another subnet, set
`LISTEN_ADDRESS=<gateway>:9100` **and** the label
`prometheus_address=<gateway>:9100`. Without the `traefik` network the
container exits (`cannot assign requested address`).

The textfile metrics are written by `apt-metrics.sh`, started next to
node_exporter: every `APT_METRICS_INTERVAL` seconds (default 300) it runs
the host's apt through `chroot /host` and writes `/tmp/textfile/apt.prom`
inside the container. Nothing has to be installed on the host.
When apt's binary cache is missing or stale, apt needs a writable `/tmp`
in the chroot: the image declares a volume on `/host/tmp` for it (the
host's `/tmp` is not touched, the rest of `/host` stays read-only).
`chroot` needs root, so only this loop runs as root (it reads the host,
mounted read-only, and listens on nothing); node_exporter, the part on
the network, runs as `nobody`.

| Metric | Value |
|---|---|
| `node_reboot_required` | 1 if `/run/reboot-required` exists |
| `apt_upgrades_pending` | packages `apt-get -s upgrade` would install |
| `apt_unattended_upgrades_enabled` | 1 if `APT::Periodic::Unattended-Upgrade` is set |
| `apt_auto_reboot_enabled` | `Unattended-Upgrade::Automatic-Reboot` |
| `apt_auto_reboot_time_seconds{time,timezone}` | `Automatic-Reboot-Time`, in seconds after midnight in the host time zone (absent when it is `now`) |
| `apt_auto_reboot_timezone_offset_seconds{timezone}` | UTC offset of the host time zone |
| `node_reboot_scheduled_timestamp_seconds` | time of the reboot planned by unattended-upgrades, 0 if none |
| `apt_upgrade_timer_next_timestamp_seconds` | next run of `apt-daily-upgrade.timer` (absent when systemd can't be asked) |
| `apt_upgrade_timer_last_timestamp_seconds` | last time that timer fired |
| `apt_unattended_upgrades_last_run_timestamp_seconds` | last run of unattended-upgrades that went through (`unattended-upgrades-stamp`); older than the timer's last fire = that run exited early (apt locked…) and planned no reboot |
| `apt_lists_update_timestamp_seconds` | last refresh of the package lists by apt-daily (`update-stamp`) |

## Usage

```bash
docker compose up -d --build
```
or

```bash
docker run -d \
  --name node-exporter \
  --restart unless-stopped \
  --network host \
  --pid host \
  -v /:/host:ro,rslave \
  --log-driver syslog \
  --log-opt syslog-address=udp://127.0.0.1:5514 \
  --log-opt tag="{{.Name}}" \
  ghcr.io/saashup/node-exporter:vX.Y.Z
```

Metrics are exposed on `http://172.31.0.1:9100/metrics`.

## Tests

```bash
tests/smoke.sh                 # builds the image, then tests it
IMAGE=<ref> tests/smoke.sh     # tests an existing image
```

It runs the container as documented (on `127.0.0.1:$SMOKE_PORT`,
default 19100) and checks the labels, the core collectors, `/` seen
through `--path.rootfs`, node_exporter running as `nobody`, run-time
arguments added to the baked flags, and the apt metrics, against both
the real host and a Debian rootfs with a known unattended-upgrades
config. CI runs it on every push to `main`, on pull requests and
before each release.

## Release

Push a `vX.Y.Z` tag: the workflow builds and pushes
`ghcr.io/<repo>:vX.Y.Z`, `:vX.Y` and `:vX`, then notifies the upgrade webhook.
