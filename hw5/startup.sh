#!/bin/bash
# startup.sh - VM startup script for the WEB SERVER VM (hw5-web).
# Passed with: gcloud compute instances create ... --metadata-from-file startup-script=startup.sh
# Runs as root at every boot; does the installation only once (lock file).
# After that, systemd starts the web server on every boot by itself.
set -euo pipefail
if [ -f /var/log/startup_already_done ]; then
  echo "Startup script already ran once. Skipping."
  exit 0
fi

md() { curl -sf -H "Metadata-Flavor: Google" \
       "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
PROJECT=$(curl -sf -H "Metadata-Flavor: Google" \
          http://metadata.google.internal/computeMetadata/v1/project/project-id)
REPO=$(md repo); BUCKET=$(md bucket); PREFIX=$(md prefix); TOPIC=$(md topic)
SQL_INSTANCE=$(md sql-instance); DB_NAME=$(md db-name); DB_USER=$(md db-user); DB_SECRET=$(md db-secret)

apt-get update -y
apt-get install -y python3-venv python3-pip git
id hw5 >/dev/null 2>&1 || useradd --system --home-dir /opt/hw5 --shell /usr/sbin/nologin hw5
mkdir -p /opt/hw5
rm -rf /opt/hw5/repo && git clone --depth 1 "$REPO" /opt/hw5/repo
python3 -m venv /opt/hw5/venv
/opt/hw5/venv/bin/pip install -q -r /opt/hw5/repo/hw5/requirements.txt
chown -R hw5:hw5 /opt/hw5

cat > /etc/systemd/system/hw5-web.service <<UNIT
[Unit]
Description=HW5 file web server (Cloud SQL)
After=network-online.target
Wants=network-online.target

[Service]
User=hw5
WorkingDirectory=/opt/hw5/repo/hw5
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/opt/hw5/venv/bin/python -u web_server.py --port 80 --project $PROJECT --bucket $BUCKET --prefix $PREFIX --topic $TOPIC --instance $SQL_INSTANCE --db-name $DB_NAME --db-user $DB_USER --db-secret $DB_SECRET --timings-file /var/tmp/hw5_timings.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now hw5-web

touch /var/log/startup_already_done
