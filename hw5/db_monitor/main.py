"""
db_monitor - Cloud Run function (gen2), triggered every hour by Cloud Scheduler
through the Pub/Sub topic `hw5-db-check`.

It checks the Cloud SQL instance and, if it is running, stops it by setting its
activation policy to NEVER (stopping, not deleting - data and settings are kept).

To work with the database for a while, pause the scheduler job
(scripts: monitor_pause.sh / monitor_resume.sh, or
 gcloud scheduler jobs pause hw5-db-check-hourly --location=us-central1).

Environment: PROJECT_ID, INSTANCE (the Cloud SQL instance name).
Runs as service account hw5-db-monitor, which has roles/cloudsql.editor.
"""
import json
import os

import functions_framework
import google.auth
from googleapiclient import discovery

PROJECT = os.environ.get("PROJECT_ID", "cedar-pottery-508921-u1")
INSTANCE = os.environ.get("INSTANCE", "hw5-db")


def check_and_stop(project=PROJECT, instance=INSTANCE, sqladmin=None):
    if sqladmin is None:
        creds, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
        sqladmin = discovery.build("sqladmin", "v1beta4", credentials=creds, cache_discovery=False)
    inst = sqladmin.instances().get(project=project, instance=instance).execute()
    state = inst.get("state")                                    # RUNNABLE, STOPPED, ...
    policy = inst.get("settings", {}).get("activationPolicy")    # ALWAYS = running, NEVER = stopped
    result = {"instance": instance, "state": state, "activationPolicy": policy}
    if state == "RUNNABLE" and policy == "ALWAYS":
        op = sqladmin.instances().patch(
            project=project, instance=instance,
            body={"settings": {"activationPolicy": "NEVER"}}).execute()
        result.update(action="stopping", operation=op.get("name"))
        print(json.dumps({"severity": "WARNING",
                          "message": f"Cloud SQL instance {instance} was running - stopping it",
                          **result}))
    else:
        result["action"] = "none"
        print(json.dumps({"severity": "INFO",
                          "message": f"Cloud SQL instance {instance} is not running - nothing to do",
                          **result}))
    return result


@functions_framework.cloud_event
def db_monitor(cloud_event):
    check_and_stop()
