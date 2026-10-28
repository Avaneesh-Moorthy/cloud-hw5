#!/bin/bash
# startup_client.sh - VM startup script for the LOAD-TEST CLIENT VM (hw5-client, Ubuntu 24.04).
# Downloads the provided Linux http-client and starts N copies in parallel, all with
# the SAME random seed, each sending NUM requests to the web server. Runs once.
# Progress / results: /var/log/hw5_load/
set -uo pipefail
if [ -f /var/log/startup_already_done ]; then
  echo "Startup script already ran once. Skipping."
  exit 0
fi
touch /var/log/startup_already_done          # never restart the load test on reboot

md() { curl -sf -H "Metadata-Flavor: Google" \
       "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"; }
SERVER=$(md server-ip); NUM=$(md num-requests); SEED=$(md seed); CLIENTS=$(md clients)
CLIENT_URL=$(md client-url)

OUT=/var/log/hw5_load; mkdir -p $OUT
curl -sfL "$CLIENT_URL" -o /usr/local/bin/http-client && chmod +x /usr/local/bin/http-client

# wait until the web server answers
until curl -sf -o /dev/null "http://$SERVER/1.html"; do sleep 10; done

date -u '+%Y-%m-%d %H:%M:%S' > $OUT/start_utc
for i in $(seq 1 "$CLIENTS"); do
  ( s=$(date +%s)
    /usr/local/bin/http-client -d "$SERVER" -p 80 -b none -w pages -n "$NUM" -i 11999 \
        -r "$SEED" -t 30 > $OUT/client_$i.log 2>&1
    echo "exit=$? seconds=$(( $(date +%s) - s ))" > $OUT/client_$i.done ) &
done
wait
date -u '+%Y-%m-%d %H:%M:%S' > $OUT/end_utc
