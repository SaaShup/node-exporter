# saashup/node-exporter

Repackages `quay.io/prometheus/node-exporter` as a versioned, buildable
image. It reports the VM itself: OS, kernel, uptime,
CPU/RAM/disk/network, and through the textfile collector the pending
reboot (`node_reboot_required`) and upgrades (`apt_upgrades_pending`).

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

For the textfile metrics, the `node-exporter-apt` timer installed by
`paashup-install.sh` writes `/var/lib/node_exporter/textfile/apt.prom`
on the host. Without it these two metrics are simply absent.

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

## Release

Push a `vX.Y.Z` tag: the workflow builds and pushes
`ghcr.io/<repo>:vX.Y.Z`, `:vX.Y` and `:vX`, then notifies the upgrade webhook.
