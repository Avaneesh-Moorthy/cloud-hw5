#!/bin/bash
# stop the Cloud SQL instance (keeps all data) and re-enable the auto-stop monitor
gcloud --project=cedar-pottery-508921-u1 --quiet sql instances patch hw5-db --activation-policy=NEVER
gcloud --project=cedar-pottery-508921-u1 --quiet scheduler jobs resume hw5-db-check-hourly --location=us-central1 || true
