#!/bin/bash
# check_load_test.sh - shows load-test progress (client VM) and the server's stage timings.
PROJECT_ID="cedar-pottery-508921-u1"; ZONE="us-central1-a"
G="gcloud --project=$PROJECT_ID"
echo "== client VM =="
$G compute ssh hw5-client --zone=$ZONE --command='cd /var/log/hw5_load 2>/dev/null && \
  echo "start: $(cat start_utc 2>/dev/null)  end: $(cat end_utc 2>/dev/null || echo running)"; \
  for f in client_*.done; do [ -f "$f" ] && echo "$f: $(cat $f)"; done; \
  echo "clients still running: $(pgrep -fc /usr/local/bin/http-client)"; \
  for f in client_*.log; do echo "$f: $(grep -ciE "timeout received|refused|reset by peer|errno" $f) client-side errors"; done'
echo "== web server: requests recorded so far + stage timings =="
$G compute ssh hw5-web --zone=$ZONE --command='cat /var/tmp/hw5_timings.json'
