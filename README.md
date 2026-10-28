# CS528 HW5: File server + Cloud SQL

Everything for this homework is in [`hw5/`](hw5/).

| | |
|---|---|
| GCP project | `cedar-pottery-508921-u1` (hard-coded in the scripts) |
| Bucket | `gs://cedar-pottery-508921-u1-pages` (pages from HW2 in `pages/`) |
| Cloud SQL | `hw5-db`: MySQL 8.0, db-f1-micro, database `hw5`, user `hw5app` (password in Secret Manager `hw5-db-password`) |
| Web VM | `hw5-web`: e2-small, static IP `hw5-web-ip`, runs `hw5/web_server.py` |
| Listener VM | `hw5-listener`: e2-micro, runs the unmodified `hw5/forbidden_listener.py` |
| DB monitor | Cloud Run function `hw5-db-monitor` + Cloud Scheduler job `hw5-db-check-hourly` |

## Quick start (Cloud Shell)

```bash
git clone https://github.com/Avaneesh-Moorthy/cloud-hw5.git && cd cloud-hw5/hw5
bash setup.sh            # everything; ~10 min the first time (Cloud SQL creation)
bash demo_curl.sh        # 1 good + 2 bad requests, tables before/after each
bash run_load_test.sh    # client VM: 2 clients x 50,000 requests, same seed
bash check_load_test.sh  # progress + server stage timings
.venv/bin/python stats.py --since "<start_utc from check_load_test.sh>"
bash cleanup.sh          # delete VMs + static IP, STOP the database, re-enable the monitor
```

## Files (`hw5/`)

| File | Purpose |
|---|---|
| `setup.sh` / `cleanup.sh` | create/start everything / tear down (DB is only stopped) |
| `startup.sh` | web VM startup script (run-once lock, systemd service `hw5-web`) |
| `startup_listener.sh`, `startup_client.sh` | listener VM / load-test client VM startup scripts |
| `setup_schema.py`, `db.py` | schema (`requests`, `failed_requests`) and DB connection helpers |
| `web_server.py` | service 1, records every request in Cloud SQL and times each stage |
| `forbidden_listener.py` | service 2 (unchanged from HW3/HW4) |
| `db_monitor/` | hourly function that stops the Cloud SQL instance if it is running |
| `db_start.sh`, `db_stop.sh`, `monitor_pause.sh`, `monitor_resume.sh` | start/stop helpers |
| `run_load_test.sh`, `check_load_test.sh`, `client/http-client` | load test |
| `dbq.py`, `demo_curl.sh`, `stats.py`, `stats.sql` | queries, curl demo, statistics |
