#!/bin/bash
# re-enable the hourly DB auto-stop; also runs it once right now
gcloud --project=cedar-pottery-508921-u1 --quiet scheduler jobs resume hw5-db-check-hourly --location=us-central1
gcloud --project=cedar-pottery-508921-u1 --quiet scheduler jobs run hw5-db-check-hourly --location=us-central1
