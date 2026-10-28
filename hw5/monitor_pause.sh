#!/bin/bash
# disable the hourly DB auto-stop while actively using the database
gcloud --project=cedar-pottery-508921-u1 --quiet scheduler jobs pause hw5-db-check-hourly --location=us-central1
