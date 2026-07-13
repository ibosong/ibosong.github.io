#!/usr/bin/env bash
# Remove files and systemd units created by install-transmission-nas-guard.sh.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Error: run as root" >&2; exit 1; }

systemctl disable --now nas-guard.timer 2>/dev/null || true
systemctl disable --now transmission-nas.service 2>/dev/null || true

rm -f \
  /etc/systemd/system/nas-guard.timer \
  /etc/systemd/system/nas-guard.service \
  /etc/systemd/system/transmission-nas.service \
  /usr/local/sbin/transmission-nas-guard

systemctl daemon-reload
systemctl reset-failed

echo "Removed NAS guard. Transmission remains stopped."
echo "To start it normally: docker start transmission"
echo "If desired, restore Docker auto-start: docker update --restart=unless-stopped transmission"
