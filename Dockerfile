FROM quay.io/prometheus/node-exporter:v1.12.1

# Everything is baked in; the container still needs, at run time (an image can't ask for them):
#   --network host --pid host -v /:/host:ro,rslave
# It listens on LISTEN_ADDRESS, by default the gateway of the paashup traefik network
# (172.31.0.0/16): Prometheus reaches it there, and the port is not exposed on the public IP.
#   - udev data: disk model/serial in node_disk_info
#   - textfile: node_reboot_required, apt_upgrades_pending and the unattended-upgrades reboot
#     settings, written by apt-metrics.sh (host apt, through chroot /host) every
#     APT_METRICS_INTERVAL seconds
ENV LISTEN_ADDRESS=172.31.0.1:9100 \
    APT_METRICS_INTERVAL=300

# root only for apt-metrics.sh: chroot /host needs it to run the host's apt (the host stays
# mounted read-only). node_exporter itself, the part on the network, runs as nobody.
USER root

# apt needs a writable /tmp in the chroot when its binary cache is missing or stale (it then
# re-reads the InRelease files). A volume there, not the host's /tmp: the rest of /host stays
# read-only and nothing has to be added at run time.
VOLUME /host/tmp

COPY --chmod=755 apt-metrics.sh /apt-metrics.sh
COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD []

# With another LISTEN_ADDRESS, override prometheus_address with the same value.
LABEL prometheus_address="172.31.0.1:9100" \
      prometheus_scrape="true"
