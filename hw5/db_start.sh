#!/bin/bash
# start the Cloud SQL instance and pause the auto-stop monitor while working
gcloud --project=cedar-pottery-508921-u1 --quiet scheduler jobs pause hw5-db-check-hourly --location=us-central1 || true
gcloud --project=cedar-pottery-508921-u1 --quiet sql instances patch hw5-db --activation-policy=ALWAYS
