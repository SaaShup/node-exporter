FROM quay.io/prometheus/node-exporter:v1.12.1

# Everything is baked in; the container still needs, at run time (an image can't ask for them):
#   --network host --pid host -v /:/host:ro,rslave
# It listens on LISTEN_ADDRESS. When not set, entrypoint.sh resolves it from the IP currently
# carried by the LISTEN_INTERFACE interface (default "traefik", the paashup traefik network's
# bridge: same name on every host even though its subnet/gateway differs), falling back to
# 172.31.0.1:9100 if that interface doesn't exist. Prometheus reaches node-exporter there, and
# the port is not exposed on the public IP.
#   - udev data: disk model/serial in node_disk_info
#   - textfile: node_reboot_required, apt_upgrades_pending and the unattended-upgrades reboot
#     settings, written by apt-metrics.sh (host apt, through chroot /host) every
#     APT_METRICS_INTERVAL seconds
ENV APT_METRICS_INTERVAL=300

USER root

VOLUME /host/tmp

COPY --chmod=755 apt-metrics.sh /apt-metrics.sh
COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD []

# With another LISTEN_ADDRESS, override prometheus_address with the same value.
LABEL prometheus_address="172.31.0.1:9100" \
      prometheus_scrape="true"
