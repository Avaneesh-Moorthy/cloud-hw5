#!/bin/bash
# run_load_test.sh - creates the client VM; its startup script immediately runs
# 2 clients x 50,000 requests (same seed) against the web server.
#   bash run_load_test.sh            # defaults: 2 clients, 50000 requests, seed 1
#   CLIENTS=2 NUM=50000 SEED=1 bash run_load_test.sh
set -euo pipefail
PROJECT_ID="cedar-pottery-508921-u1"; REGION="us-central1"; ZONE="us-central1-a"
CLIENTS=${CLIENTS:-2}; NUM=${NUM:-50000}; SEED=${SEED:-1}
CLIENT_URL="https://raw.githubusercontent.com/Avaneesh-Moorthy/cloud-hw5/main/hw5/client/http-client"
HERE="$(cd "$(dirname "$0")" && pwd)"
G="gcloud --project=$PROJECT_ID --quiet"
IP=$($G compute addresses describe hw5-web-ip --region=$REGION --format='value(address)')
# the database is in use for the next hours -> keep the auto-stop monitor paused
$G scheduler jobs pause hw5-db-check-hourly --location=$REGION 2>/dev/null || true
$G compute instances create hw5-client --zone=$ZONE --machine-type=e2-small \
  --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
  --no-service-account --no-scopes \
  --metadata="server-ip=$IP,num-requests=$NUM,seed=$SEED,clients=$CLIENTS,client-url=$CLIENT_URL" \
  --metadata-from-file=startup-script="$HERE/startup_client.sh"
echo "Load test started: $CLIENTS clients x $NUM requests, seed $SEED, server $IP"
echo "Check progress with:  bash check_load_test.sh"
