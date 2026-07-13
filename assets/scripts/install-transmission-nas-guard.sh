#!/usr/bin/env bash
# Install a safe NAS guard for one Docker Transmission container.
set -Eeuo pipefail

MOUNT_PATH="${1:-/mnt/nas_media}"
NAS_HOST="${2:-192.168.50.2}"
CONTAINER="${3:-transmission}"
INTERVAL="${4:-30}"

die() { echo "Error: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ "$MOUNT_PATH" == /* ]] || die "mount path must be absolute"
[[ "$NAS_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "NAS host contains unsupported characters"
[[ "$CONTAINER" =~ ^[A-Za-z0-9_.-]+$ ]] || die "container name contains unsupported characters"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "interval must be a positive number of seconds"

for command in docker findmnt systemctl systemd-escape timeout logger; do
  command -v "$command" >/dev/null || die "missing command: $command"
done

[[ "$(findmnt -rn -T "$MOUNT_PATH" -o FSTYPE)" == cifs ]] || die "$MOUNT_PATH is not a mounted CIFS filesystem"
docker inspect "$CONTAINER" >/dev/null || die "Docker container not found: $CONTAINER"

MOUNT_UNIT="$(systemd-escape -p --suffix=mount "$MOUNT_PATH")"
systemctl daemon-reload
systemctl cat "$MOUNT_UNIT" >/dev/null 2>&1 || die "no systemd mount unit for $MOUNT_PATH; add it to /etc/fstab first"

DOCKER_BIN="$(command -v docker)"
FINDMNT_BIN="$(command -v findmnt)"
SYSTEMCTL_BIN="$(command -v systemctl)"
TIMEOUT_BIN="$(command -v timeout)"
LOGGER_BIN="$(command -v logger)"
GUARD_BIN=/usr/local/sbin/transmission-nas-guard

install -m 755 /dev/stdin "$GUARD_BIN" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "\$("$FINDMNT_BIN" -rn -T "$MOUNT_PATH" -o FSTYPE)" == cifs ]] &&
   "$TIMEOUT_BIN" 5 /bin/bash -c 'echo >/dev/tcp/$NAS_HOST/445'
then
  exit 0
fi

if "$SYSTEMCTL_BIN" is-active --quiet transmission-nas.service; then
  "$LOGGER_BIN" -t nas-guard "NAS unavailable; stopping $CONTAINER"
  "$SYSTEMCTL_BIN" stop transmission-nas.service
fi
EOF

install -m 644 /dev/stdin /etc/systemd/system/transmission-nas.service <<EOF
[Unit]
Description=Transmission with NAS storage
Wants=network-online.target
Requires=docker.service $MOUNT_UNIT
After=network-online.target docker.service $MOUNT_UNIT
BindsTo=$MOUNT_UNIT

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c '[ "\$("$FINDMNT_BIN" -rn -T "$MOUNT_PATH" -o FSTYPE)" = cifs ]'
ExecStart=$DOCKER_BIN start $CONTAINER
ExecStop=-$DOCKER_BIN stop -t 30 $CONTAINER

[Install]
WantedBy=multi-user.target
EOF

install -m 644 /dev/stdin /etc/systemd/system/nas-guard.service <<EOF
[Unit]
Description=Stop Transmission when NAS is unavailable

[Service]
Type=oneshot
ExecStart=$GUARD_BIN
EOF

install -m 644 /dev/stdin /etc/systemd/system/nas-guard.timer <<EOF
[Unit]
Description=Check NAS every $INTERVAL seconds

[Timer]
OnBootSec=$INTERVAL
OnUnitActiveSec=$INTERVAL

[Install]
WantedBy=timers.target
EOF

"$GUARD_BIN"
docker update --restart=no "$CONTAINER" >/dev/null
docker stop "$CONTAINER" >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable --now transmission-nas.service nas-guard.timer

echo "Installed. Verify with: systemctl status transmission-nas.service nas-guard.timer"
echo "Logs: journalctl -t nas-guard"
echo "After NAS recovers: systemctl start transmission-nas.service"
