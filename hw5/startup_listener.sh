#!/bin/bash
# startup_listener.sh - VM startup script for the FORBIDDEN-COUNTRY LISTENER VM (hw5-listener).
# Runs the unmodified second app (forbidden_listener.py) as a systemd service.
set -euo pipefail
if [ -f /var/log/startup_already_done ]; then
  echo "Startup script already ran once. Skipping."
  exit 0
fi

md() { curl -sf -H "Metadata-Flavor: Google" \
       "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
PROJECT=$(curl -sf -H "Metadata-Flavor: Google" \
          http://metadata.google.internal/computeMetadata/v1/project/project-id)
REPO=$(md repo); BUCKET=$(md bucket); SUB=$(md subscription)

apt-get update -y
apt-get install -y python3-venv git
id hw5 >/dev/null 2>&1 || useradd --system --home-dir /opt/hw5 --shell /usr/sbin/nologin hw5
mkdir -p /opt/hw5
rm -rf /opt/hw5/repo && git clone --depth 1 "$REPO" /opt/hw5/repo
python3 -m venv /opt/hw5/venv
/opt/hw5/venv/bin/pip install -q -r /opt/hw5/repo/hw5/requirements-listener.txt
chown -R hw5:hw5 /opt/hw5

cat > /etc/systemd/system/hw5-listener.service <<UNIT
[Unit]
Description=HW5 forbidden-country listener
After=network-online.target
Wants=network-online.target

[Service]
User=hw5
ExecStart=/opt/hw5/venv/bin/python -u /opt/hw5/repo/hw5/forbidden_listener.py --project $PROJECT --subscription $SUB --bucket $BUCKET --log-object forbidden_logs/hw5_forbidden_requests.log
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now hw5-listener

touch /var/log/startup_already_done
