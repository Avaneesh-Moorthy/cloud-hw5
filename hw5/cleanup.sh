#!/bin/bash
# =============================================================================
# HW5 cleanup.sh - tears down what setup.sh created so nothing keeps billing.
#   * deletes the VMs (web, listener, client) and the firewall rule
#   * releases and deletes the static IP
#   * STOPS (does not delete) the Cloud SQL instance
#   * resumes the hourly DB monitor (stops the DB if anyone starts it and forgets)
# No `gcloud auth application-default login` is used anywhere, so nothing to revoke.
# =============================================================================
set -uo pipefail
PROJECT_ID="cedar-pottery-508921-u1"
REGION="us-central1"; ZONE="us-central1-a"
G="gcloud --project=$PROJECT_ID --quiet"

echo "==> Deleting VMs"
for vm in hw5-web hw5-listener hw5-client; do
  $G compute instances describe "$vm" --zone=$ZONE >/dev/null 2>&1 && \
    $G compute instances delete "$vm" --zone=$ZONE
done

echo "==> Releasing static IP"
$G compute addresses describe hw5-web-ip --region=$REGION >/dev/null 2>&1 && \
  $G compute addresses delete hw5-web-ip --region=$REGION

echo "==> Deleting firewall rule"
$G compute firewall-rules describe hw5-allow-http >/dev/null 2>&1 && \
  $G compute firewall-rules delete hw5-allow-http

echo "==> Stopping Cloud SQL (not deleting)"
$G sql instances describe hw5-db >/dev/null 2>&1 && \
  $G sql instances patch hw5-db --activation-policy=NEVER

echo "==> Re-enabling the hourly DB monitor"
$G scheduler jobs resume hw5-db-check-hourly --location=$REGION 2>/dev/null || true

echo "==> Remaining VMs / addresses / DB state:"
$G compute instances list
$G compute addresses list
$G sql instances list --format="table(name,state,settings.activationPolicy)"
