#!/bin/bash
# =============================================================================
# HW5 setup.sh - provisions everything and starts all services.
#
#   cd hw5 && bash setup.sh
#
# Creates (or, if it already exists, re-uses / starts):
#   * APIs, 3 least-privilege service accounts and their IAM bindings
#   * Secret Manager secret with the database password (generated once)
#   * Cloud SQL for MySQL instance + database + user + schema (setup_schema.py)
#   * Pub/Sub topic/subscription for forbidden requests
#   * static external IP + firewall rule for port 80
#   * VM hw5-web      (web server, started by startup.sh)
#   * VM hw5-listener (forbidden-country listener, started by startup_listener.sh)
#   * Cloud Run function hw5-db-monitor + hourly Cloud Scheduler job that stops
#     the database if it is running. The job is left PAUSED while the environment
#     is in use; cleanup.sh resumes it.
# Safe to re-run.
# =============================================================================
set -euo pipefail

# ---- settings (project ID is hard-coded on purpose) --------------------------
PROJECT_ID="cedar-pottery-508921-u1"
REGION="us-central1"
ZONE="us-central1-a"
BUCKET="cedar-pottery-508921-u1-pages"
PREFIX="pages/"
REPO="https://github.com/Avaneesh-Moorthy/cloud-hw5.git"

SQL_INSTANCE="hw5-db"
SQL_TIER="db-f1-micro"
DB_NAME="hw5"
DB_USER="hw5app"
DB_SECRET="hw5-db-password"

WEB_VM="hw5-web";           WEB_TYPE="e2-small"
LISTENER_VM="hw5-listener"; LISTENER_TYPE="e2-micro"
STATIC_IP_NAME="hw5-web-ip"
FIREWALL="hw5-allow-http"
TOPIC="hw5-forbidden";      SUBSCRIPTION="hw5-forbidden-sub"
CHECK_TOPIC="hw5-db-check"; FUNCTION="hw5-db-monitor"; JOB="hw5-db-check-hourly"

WEB_SA="hw5-web-server@${PROJECT_ID}.iam.gserviceaccount.com"
LIS_SA="hw5-listener@${PROJECT_ID}.iam.gserviceaccount.com"
MON_SA="hw5-db-monitor@${PROJECT_ID}.iam.gserviceaccount.com"
CONN_NAME="${PROJECT_ID}:${REGION}:${SQL_INSTANCE}"

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
G="gcloud --project=${PROJECT_ID} --quiet"
say() { echo; echo "==> $*"; }
exists() { "$@" >/dev/null 2>&1; }

# ---------------------------------------------------------------------- APIs
enable_apis() {
  say "Enabling APIs"
  $G services enable compute.googleapis.com sqladmin.googleapis.com \
    secretmanager.googleapis.com pubsub.googleapis.com logging.googleapis.com \
    cloudfunctions.googleapis.com run.googleapis.com cloudbuild.googleapis.com \
    eventarc.googleapis.com artifactregistry.googleapis.com cloudscheduler.googleapis.com \
    iam.googleapis.com
}

# ------------------------------------------------------------ service accounts
create_service_accounts() {
  say "Service accounts"
  exists $G iam service-accounts describe "$WEB_SA" || \
    $G iam service-accounts create hw5-web-server --display-name="HW5 web server VM"
  exists $G iam service-accounts describe "$LIS_SA" || \
    $G iam service-accounts create hw5-listener --display-name="HW5 forbidden listener VM"
  exists $G iam service-accounts describe "$MON_SA" || \
    $G iam service-accounts create hw5-db-monitor --display-name="HW5 Cloud SQL monitor function"
  sleep 10
}

# ----------------------------------------------------------- database password
create_secret() {
  say "Database password secret"
  if ! exists $G secrets describe "$DB_SECRET"; then
    openssl rand -base64 24 | tr -d '\n/+=' | $G secrets create "$DB_SECRET" \
      --replication-policy=automatic --data-file=-
  fi
  DB_PASS="$($G secrets versions access latest --secret="$DB_SECRET")"
  export DB_PASS
}

# ------------------------------------- local Python tools (schema, queries, stats)
make_tools_venv() {
  say "Python virtualenv for setup_schema.py / dbq.py / stats.py"
  [ -x "$HERE/.venv/bin/python" ] || python3 -m venv "$HERE/.venv"
  "$HERE/.venv/bin/pip" install -q -r "$HERE/requirements-tools.txt"
}

# ------------------------------------------------------------------ Cloud SQL
setup_cloud_sql() {
  say "Cloud SQL"
  if exists $G sql instances describe "$SQL_INSTANCE" && \
     exists $G sql databases describe "$DB_NAME" --instance="$SQL_INSTANCE"; then
    echo "Instance $SQL_INSTANCE and database $DB_NAME already exist -> starting the server only"
    $G sql instances patch "$SQL_INSTANCE" --activation-policy=ALWAYS
    return
  fi

  if ! exists $G sql instances describe "$SQL_INSTANCE"; then
    echo "Creating Cloud SQL instance $SQL_INSTANCE (MySQL 8.0, $SQL_TIER) - takes ~5-10 minutes"
    $G sql instances create "$SQL_INSTANCE" --database-version=MYSQL_8_0 \
      --edition=enterprise --tier="$SQL_TIER" --region="$REGION" \
      --storage-type=SSD --storage-size=10 --no-storage-auto-increase \
      --availability-type=zonal --no-backup --root-password="$(openssl rand -hex 16)"
  else
    $G sql instances patch "$SQL_INSTANCE" --activation-policy=ALWAYS
  fi
  $G sql databases create "$DB_NAME" --instance="$SQL_INSTANCE" || true
  if [ -n "$($G sql users list --instance="$SQL_INSTANCE" --filter="name=$DB_USER" --format="value(name)" 2>/dev/null)" ]; then
    $G sql users set-password "$DB_USER" --host=% --instance="$SQL_INSTANCE" --password="$DB_PASS"
  else
    $G sql users create "$DB_USER" --host=% --instance="$SQL_INSTANCE" --password="$DB_PASS"
  fi

  echo "Creating the schema with setup_schema.py"
  "$HERE/.venv/bin/python" "$HERE/setup_schema.py" --project "$PROJECT_ID" --instance "$CONN_NAME" \
    --db-name "$DB_NAME" --db-user "$DB_USER" --db-secret "$DB_SECRET"
}

# -------------------------------------------------------------------- Pub/Sub
setup_pubsub() {
  say "Pub/Sub"
  exists $G pubsub topics describe "$TOPIC" || $G pubsub topics create "$TOPIC"
  exists $G pubsub subscriptions describe "$SUBSCRIPTION" || \
    $G pubsub subscriptions create "$SUBSCRIPTION" --topic="$TOPIC"
  exists $G pubsub topics describe "$CHECK_TOPIC" || $G pubsub topics create "$CHECK_TOPIC"
}

# ------------------------------------------------------------------------ IAM
grant_roles() {
  say "Least-privilege IAM"
  local PNUM; PNUM=$($G projects describe "$PROJECT_ID" --format='value(projectNumber)')
  # web server VM: read pages, publish forbidden requests, write logs, use Cloud SQL, read DB password
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --project="$PROJECT_ID" \
    --member="serviceAccount:$WEB_SA" --role=roles/storage.objectViewer --quiet >/dev/null
  $G pubsub topics add-iam-policy-binding "$TOPIC" \
    --member="serviceAccount:$WEB_SA" --role=roles/pubsub.publisher >/dev/null
  for r in roles/logging.logWriter roles/cloudsql.client; do
    $G projects add-iam-policy-binding "$PROJECT_ID" --condition=None \
      --member="serviceAccount:$WEB_SA" --role="$r" >/dev/null
  done
  $G secrets add-iam-policy-binding "$DB_SECRET" \
    --member="serviceAccount:$WEB_SA" --role=roles/secretmanager.secretAccessor >/dev/null
  # listener VM: pull forbidden messages, append them to a log file in the bucket
  $G pubsub subscriptions add-iam-policy-binding "$SUBSCRIPTION" \
    --member="serviceAccount:$LIS_SA" --role=roles/pubsub.subscriber >/dev/null
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --project="$PROJECT_ID" \
    --member="serviceAccount:$LIS_SA" --role=roles/storage.objectUser --quiet >/dev/null
  # monitor function: read and stop the Cloud SQL instance
  $G projects add-iam-policy-binding "$PROJECT_ID" --condition=None \
    --member="serviceAccount:$MON_SA" --role=roles/cloudsql.editor >/dev/null
  # Cloud Build (function deployment) uses the default compute service account
  $G projects add-iam-policy-binding "$PROJECT_ID" --condition=None \
    --member="serviceAccount:${PNUM}-compute@developer.gserviceaccount.com" \
    --role=roles/cloudbuild.builds.builder >/dev/null
}

# ---------------------------------------------------------- network + static IP
setup_network() {
  say "Static IP and firewall"
  exists $G compute addresses describe "$STATIC_IP_NAME" --region="$REGION" || \
    $G compute addresses create "$STATIC_IP_NAME" --region="$REGION"
  STATIC_IP=$($G compute addresses describe "$STATIC_IP_NAME" --region="$REGION" --format='value(address)')
  exists $G compute firewall-rules describe "$FIREWALL" || \
    $G compute firewall-rules create "$FIREWALL" --network=default --direction=INGRESS \
      --allow=tcp:80 --source-ranges=0.0.0.0/0 --target-tags=hw5-web
}

# ------------------------------------------------------------------------ VMs
create_vms() {
  say "VM $WEB_VM ($WEB_TYPE, static IP $STATIC_IP)"
  exists $G compute instances describe "$WEB_VM" --zone="$ZONE" || \
    $G compute instances create "$WEB_VM" --zone="$ZONE" --machine-type="$WEB_TYPE" \
      --image-family=debian-12 --image-project=debian-cloud \
      --service-account="$WEB_SA" --scopes=cloud-platform \
      --address="$STATIC_IP" --tags=hw5-web \
      --metadata="repo=$REPO,bucket=$BUCKET,prefix=$PREFIX,topic=projects/$PROJECT_ID/topics/$TOPIC,sql-instance=$CONN_NAME,db-name=$DB_NAME,db-user=$DB_USER,db-secret=$DB_SECRET" \
      --metadata-from-file=startup-script="$HERE/startup.sh"

  say "VM $LISTENER_VM ($LISTENER_TYPE)"
  exists $G compute instances describe "$LISTENER_VM" --zone="$ZONE" || \
    $G compute instances create "$LISTENER_VM" --zone="$ZONE" --machine-type="$LISTENER_TYPE" \
      --image-family=debian-12 --image-project=debian-cloud \
      --service-account="$LIS_SA" --scopes=cloud-platform \
      --metadata="repo=$REPO,bucket=$BUCKET,subscription=$SUBSCRIPTION" \
      --metadata-from-file=startup-script="$HERE/startup_listener.sh"
}

# ------------------------------------------------- DB monitor function + schedule
deploy_db_monitor() {
  say "Cloud SQL monitor function + hourly schedule"
  $G functions deploy "$FUNCTION" --gen2 --runtime=python312 --region="$REGION" \
    --source="$HERE/db_monitor" --entry-point=db_monitor --trigger-topic="$CHECK_TOPIC" \
    --service-account="$MON_SA" --trigger-service-account="$MON_SA" \
    --set-env-vars="PROJECT_ID=$PROJECT_ID,INSTANCE=$SQL_INSTANCE" --memory=256Mi --max-instances=1
  $G functions add-invoker-policy-binding "$FUNCTION" --region="$REGION" \
    --member="serviceAccount:$MON_SA" >/dev/null
  if exists $G scheduler jobs describe "$JOB" --location="$REGION"; then
    $G scheduler jobs update pubsub "$JOB" --location="$REGION" --schedule="0 * * * *" \
      --topic="$CHECK_TOPIC" --message-body="check" >/dev/null
  else
    $G scheduler jobs create pubsub "$JOB" --location="$REGION" --schedule="0 * * * *" \
      --time-zone="Etc/UTC" --topic="$CHECK_TOPIC" --message-body="check"
  fi
  # we are about to use the database -> pause the monitor (cleanup.sh resumes it)
  $G scheduler jobs pause "$JOB" --location="$REGION" || true
}

# ======================================================================= main
$G config set project "$PROJECT_ID" >/dev/null 2>&1 || true
enable_apis
create_service_accounts
create_secret
make_tools_venv
setup_cloud_sql
setup_pubsub
grant_roles
setup_network
create_vms
deploy_db_monitor

say "Done."
echo "Web server : http://$STATIC_IP/123.html   (the VM needs ~3 minutes to install and start)"
echo "Database   : $CONN_NAME  (database $DB_NAME, user $DB_USER, password in secret $DB_SECRET)"
echo "Monitor    : $JOB is PAUSED while you work - run monitor_resume.sh (or cleanup.sh) when done"
