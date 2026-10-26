#!/bin/sh
# Pending reboot and upgrades of the host, and its unattended-upgrades reboot settings, read
# through /host, for the textfile collector. Started in the background by entrypoint.sh and
# rewritten every APT_METRICS_INTERVAL seconds. apt runs from the host (chroot /host), read-only.
dir="$1"
interval="${APT_METRICS_INTERVAL:-300}"

# value of an apt option, as `apt-config dump` prints it: Key "value";
conf_get() {
  printf '%s\n' "$conf" | sed -n "s|^$1 \"\(.*\)\";$|\1|p" | tail -n 1
}

is_true() {
  case "$1" in true|yes|on|1) return 0 ;; *) return 1 ;; esac
}

# mtime of a file of the host, in seconds since epoch (empty if it is missing)
mtime() {
  stat -c %Y "/host$1" 2>/dev/null
}

# a timestamp property of a host timer, in seconds since epoch (empty if unknown or never)
timer_get() {
  v="$(chroot /host systemctl show "$1" -p "$2" --timestamp=unix 2>/dev/null)"
  v="${v#*=}"
  case "$v" in
    @[0-9]*) echo "${v#@}" ;;
    ""|n/a|0) ;;
    *) chroot /host date -d "$v" +%s 2>/dev/null ;;
  esac
}

# metric <name> <help> <value>: nothing when the value is empty
metric() {
  [ -n "$3" ] || return 0
  echo "# HELP $1 $2"
  echo "# TYPE $1 gauge"
  echo "$1 $3"
}

write_metrics() {
  required=0
  [ -f /host/run/reboot-required ] && required=1

  pending=""
  if sim="$(chroot /host apt-get -s -o Debug::NoLocking=1 upgrade 2>&1)"; then
    pending="$(printf '%s\n' "$sim" | grep -c '^Inst ')"
  else
    echo "apt-metrics: apt-get -s upgrade failed: $(printf '%s\n' "$sim" | grep '^E:' | head -n 2)" >&2
  fi

  conf="$(chroot /host apt-config dump 2>/dev/null)"
  periodic="$(conf_get 'APT::Periodic::Unattended-Upgrade')"
  auto="$(conf_get 'Unattended-Upgrade::Automatic-Reboot')"
  at="$(conf_get 'Unattended-Upgrade::Automatic-Reboot-Time')"
  [ -n "$at" ] || at="now"

  enabled=0
  [ -n "$periodic" ] && [ "$periodic" != 0 ] && enabled=1
  auto_reboot=0
  is_true "$auto" && auto_reboot=1

  tz="$(cat /host/etc/timezone 2>/dev/null || readlink /host/etc/localtime | sed 's|.*/zoneinfo/||')"
  [ -n "$tz" ] || tz="UTC"
  # +0200 -> 7200
  offset="$(chroot /host date +%z 2>/dev/null)"
  case "$offset" in
    [+-][0-9][0-9][0-9][0-9])
      sign="${offset%????}"; hh="${offset#?}"; hh="${hh%??}"; mm="${offset#???}"
      offset=$(( ${sign}1 * (${hh#0} * 3600 + ${mm#0} * 60) )) ;;
    *) offset=0 ;;
  esac

  # reboot planned by unattended-upgrades (shutdown -r HH:MM), in microseconds since epoch
  scheduled=0
  if grep -q '^MODE=reboot' /host/run/systemd/shutdown/scheduled 2>/dev/null; then
    usec="$(sed -n 's/^USEC=//p' /host/run/systemd/shutdown/scheduled)"
    [ -n "$usec" ] && scheduled=$(( usec / 1000000 ))
  fi

  # the daily run: when the timer fires (6:00 + random delay on Debian), and when
  # unattended-upgrade really went through (its stamp: a run that exits early, e.g. because apt
  # is locked, fires the timer but leaves the stamp, and does not plan the reboot either)
  timer_next="$(timer_get apt-daily-upgrade.timer NextElapseUSecRealtime)"
  timer_last="$(timer_get apt-daily-upgrade.timer LastTriggerUSec)"
  [ -n "$timer_last" ] || timer_last="$(mtime /var/lib/systemd/timers/stamp-apt-daily-upgrade.timer)"
  uu_last="$(mtime /var/lib/apt/periodic/unattended-upgrades-stamp)"
  lists_last="$(mtime /var/lib/apt/periodic/update-stamp)"

  {
    metric apt_upgrade_timer_next_timestamp_seconds \
      'Next run of apt-daily-upgrade.timer (unattended-upgrades).' "$timer_next"
    metric apt_upgrade_timer_last_timestamp_seconds \
      'Last time apt-daily-upgrade.timer fired.' "$timer_last"
    metric apt_unattended_upgrades_last_run_timestamp_seconds \
      'Last run of unattended-upgrades that went through (its stamp file).' "$uu_last"
    metric apt_lists_update_timestamp_seconds \
      'Last refresh of the package lists by apt-daily (update-stamp).' "$lists_last"
    echo '# HELP node_reboot_required 1 if a reboot is pending.'
    echo '# TYPE node_reboot_required gauge'
    echo "node_reboot_required $required"
    if [ -n "$pending" ]; then
      echo '# HELP apt_upgrades_pending Packages waiting to be upgraded.'
      echo '# TYPE apt_upgrades_pending gauge'
      echo "apt_upgrades_pending $pending"
    fi
    echo '# HELP apt_unattended_upgrades_enabled 1 if unattended-upgrades runs every day.'
    echo '# TYPE apt_unattended_upgrades_enabled gauge'
    echo "apt_unattended_upgrades_enabled $enabled"
    echo '# HELP apt_auto_reboot_enabled 1 if unattended-upgrades reboots by itself when an update needs it.'
    echo '# TYPE apt_auto_reboot_enabled gauge'
    echo "apt_auto_reboot_enabled $auto_reboot"
    case "$at" in
      [0-9]:[0-9][0-9]|[0-9][0-9]:[0-9][0-9])
        h="${at%%:*}"; m="${at#*:}"
        echo '# HELP apt_auto_reboot_time_seconds Configured reboot time, in seconds after midnight in the host time zone.'
        echo '# TYPE apt_auto_reboot_time_seconds gauge'
        echo "apt_auto_reboot_time_seconds{time=\"$at\",timezone=\"$tz\"} $(( ${h#0} * 3600 + ${m#0} * 60 ))" ;;
    esac
    echo '# HELP apt_auto_reboot_timezone_offset_seconds UTC offset of the host time zone, now.'
    echo '# TYPE apt_auto_reboot_timezone_offset_seconds gauge'
    echo "apt_auto_reboot_timezone_offset_seconds{timezone=\"$tz\"} $offset"
    echo '# HELP node_reboot_scheduled_timestamp_seconds Time of the planned reboot (0 if none).'
    echo '# TYPE node_reboot_scheduled_timestamp_seconds gauge'
    echo "node_reboot_scheduled_timestamp_seconds $scheduled"
  } > "$dir/apt.prom.$$" && mv "$dir/apt.prom.$$" "$dir/apt.prom"
}

while :; do
  write_metrics || echo "apt-metrics: could not write $dir/apt.prom" >&2
  sleep "$interval"
done
