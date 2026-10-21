FROM quay.io/prometheus/node-exporter:v1.12.1

# Everything is baked in; the container still needs, at run time (an image can't ask for them):
#   --network host --pid host -v /:/host:ro,rslave
# It listens on LISTEN_ADDRESS, by default the gateway of the paashup traefik network
# (172.31.0.0/16): Prometheus reaches it there, and the port is not exposed on the public IP.
#   - udev data: disk model/serial in node_disk_info
#   - textfile: node_reboot_required / apt_upgrades_pending, written on the host by the
#     node-exporter-apt timer (see paashup-install.sh) into /var/lib/node_exporter/textfile
ENV LISTEN_ADDRESS=172.31.0.1:9100

COPY --chmod=755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
CMD []

# With another LISTEN_ADDRESS, override prometheus_address with the same value.
LABEL prometheus_address="172.31.0.1:9100" \
      prometheus_scrape="true"
