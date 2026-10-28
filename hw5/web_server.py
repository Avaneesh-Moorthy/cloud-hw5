"""
HW5 service 1 - the HW4 file server, extended to record every request in Cloud SQL
and to time each stage of request handling.

Behaviour (unchanged from HW4):
  GET  /<file>                -> 200 + file      (file is in the URL path)
  POST /  {"filename": ...}   -> 200 + file      (file is in the payload)
  missing file                -> 404  Cloud Logging severity WARNING
  other HTTP methods          -> 501  Cloud Logging severity ERROR
  X-country is export-banned  -> 400  Cloud Logging severity CRITICAL + Pub/Sub -> listener

New in HW5:
  * every request is inserted into table `requests`
    (country, client ip, gender, age, income, is_banned, time of day, file, status)
  * every request that does not return 200 is also inserted into `failed_requests`
    (time of request, requested file, error code)
  * each stage runs in its own function and is timed with time.perf_counter_ns():
        extract_request_info()  - parse the request and its headers
        read_from_storage()     - read the file from Cloud Storage
        send_response()         - send the response to the client
        record_in_database()    - insert into Cloud SQL
    aggregated timings are written to --timings-file every 15 s (and on shutdown).
"""

import argparse
import datetime
import html
import json
import logging
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote

import sqlalchemy

import db

FORBIDDEN = {"north korea", "iran", "cuba", "myanmar", "iraq",
             "libya", "sudan", "zimbabwe", "syria"}

CFG = {"bucket": "", "prefix": "pages/", "topic": ""}
STATE = {"bucket": None, "publisher": None, "log": None, "engine": None}


# =================================================================== timing
class Timings:
    """Thread-safe collection of per-request stage durations (nanoseconds)."""
    STAGES = ("extract_request_info", "read_from_storage", "send_response",
              "record_in_database", "total")

    def __init__(self):
        self.lock = threading.Lock()
        self.samples = {s: [] for s in self.STAGES}

    def add(self, stage, ns):
        with self.lock:
            self.samples[stage].append(ns)

    def summary(self):
        with self.lock:
            snap = {k: list(v) for k, v in self.samples.items()}
        out = {}
        for stage, v in snap.items():
            if not v:
                continue
            v.sort()
            n = len(v)
            pct = lambda p: v[min(n - 1, int(p * n))] / 1e6  # noqa: E731
            out[stage] = {"count": n,
                          "mean_ms": round(sum(v) / n / 1e6, 3),
                          "p50_ms": round(pct(0.50), 3),
                          "p95_ms": round(pct(0.95), 3),
                          "p99_ms": round(pct(0.99), 3),
                          "max_ms": round(v[-1] / 1e6, 3),
                          "total_s": round(sum(v) / 1e9, 1)}
        return out


TIMINGS = Timings()


def timed(stage):
    """Decorator: measure the wrapped function with the high-resolution clock."""
    def wrap(fn):
        def inner(*a, **kw):
            t0 = time.perf_counter_ns()
            try:
                return fn(*a, **kw)
            finally:
                TIMINGS.add(stage, time.perf_counter_ns() - t0)
        inner.__name__ = fn.__name__
        return inner
    return wrap


def write_timings(path):
    data = {"written_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "stages": TIMINGS.summary()}
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path)


def timings_writer(path, every=15.0):
    while True:
        time.sleep(every)
        try:
            write_timings(path)
        except OSError as e:
            print("could not write timings:", e, flush=True)


# ================================================================== logging
def setup_logging(use_cloud):
    log = logging.getLogger("hw5-web-server")
    log.setLevel(logging.INFO)
    log.propagate = False
    if use_cloud:
        import google.cloud.logging
        from google.cloud.logging.handlers import CloudLoggingHandler
        log.addHandler(CloudLoggingHandler(google.cloud.logging.Client(), name="hw5-web-server"))
    else:
        class J(logging.Formatter):
            def format(self, r):
                return json.dumps({"severity": r.levelname, "message": r.getMessage(),
                                   **getattr(r, "json_fields", {})})
        h = logging.StreamHandler(sys.stdout)
        h.setFormatter(J())
        log.addHandler(h)
    return log


def log_event(severity, info, status, reason):
    fields = {"status": status, "reason": reason, "method": info["method"],
              "path": info["path"], "file": info["file"], "country": info["country"],
              "client_ip": info["client_ip"]}
    print(f"{severity} {status}: {reason} | method={info['method']} path={info['path']}", flush=True)
    STATE["log"].log(getattr(logging, severity), f"{status} {reason}",
                     extra={"json_fields": fields,
                            "http_request": {"requestMethod": info["method"],
                                             "requestUrl": info["path"], "status": status}})


# ============================================================ stage 1: parse
def _parse_client_time(value):
    """X-time looks like '2026-10-27 18:00:00'. Returns (datetime | None, hour | None)."""
    if not value:
        return None, None
    for fmt in ("%Y-%m-%d %H:%M:%S", "%H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.datetime.strptime(value.strip(), fmt)
            return (dt if dt.year > 1900 else None), dt.hour
        except ValueError:
            pass
    return None, None


def _clean(v, n):
    v = (v or "").strip()
    return v[:n] if v else None


@timed("extract_request_info")
def extract_request_info(req, body_name=None):
    """Turn the raw request into a dict with everything the server and the DB need."""
    if req.command == "POST":
        name = body_name or ""
    else:
        name = req.path.split("?")[0]
    name = unquote(name).lstrip("/")
    h = req.headers
    country = _clean(h.get("X-country"), 64)
    client_time, hour = _parse_client_time(h.get("X-time"))
    return {
        "received_at": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        "method": req.command,
        "path": req.path,
        "file": name[:255],
        "country": country,
        "client_ip": _clean(h.get("X-client-IP"), 45) or req.client_address[0],
        "gender": _clean(h.get("X-gender"), 16),
        "age_group": _clean(h.get("X-age"), 16),
        "income_group": _clean(h.get("X-income"), 16),
        "is_banned": bool(country and country.lower() in FORBIDDEN),
        "client_time": client_time,
        "time_of_day": hour,
    }


# ========================================================= stage 2: storage
def _candidates(name):
    if name.startswith(CFG["bucket"] + "/"):
        name = name[len(CFG["bucket"]) + 1:]
    if name.startswith(CFG["prefix"]):
        return [name]
    return [CFG["prefix"] + name.split("/")[-1], name]


@timed("read_from_storage")
def read_from_storage(name):
    """Return the file's bytes, or None if it is not in the bucket."""
    from google.api_core.exceptions import NotFound
    for obj in _candidates(name):
        if not obj or obj.endswith("/"):
            continue
        try:
            return STATE["bucket"].blob(obj).download_as_bytes()
        except NotFound:
            continue
    return None


# ============================================================ stage 3: send
@timed("send_response")
def send_response(req, status, body, ctype="text/plain; charset=utf-8"):
    try:
        req.send_response(status)
        req.send_header("Content-Type", ctype)
        req.send_header("Content-Length", str(len(body)))
        req.end_headers()
        if req.command != "HEAD":
            req.wfile.write(body)
        req.wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        pass


# ======================================================== stage 4: database
INSERT_REQUEST = sqlalchemy.text("""
    INSERT INTO requests (received_at, country, client_ip, gender, age_group, income_group,
                          is_banned, client_time, time_of_day, requested_file, status_code)
    VALUES (:received_at, :country, :client_ip, :gender, :age_group, :income_group,
            :is_banned, :client_time, :time_of_day, :file, :status)""")
INSERT_FAILED = sqlalchemy.text("""
    INSERT INTO failed_requests (request_time, requested_file, error_code)
    VALUES (:received_at, :file, :status)""")


@timed("record_in_database")
def record_in_database(info, status):
    """Insert the request (and, if it failed, the failure) in one transaction."""
    row = dict(info, status=status)
    try:
        with STATE["engine"].begin() as conn:
            conn.execute(INSERT_REQUEST, row)
            if status != 200:
                conn.execute(INSERT_FAILED, row)
    except Exception as e:  # never let a DB problem take the web server down
        print("DB insert failed:", repr(e), flush=True)


def publish_forbidden(info):
    if not CFG["topic"]:
        return
    msg = {"time": info["received_at"].isoformat(timespec="seconds") + "+00:00",
           "country": info["country"], "file": info["file"], "method": info["method"],
           "client_ip": info["client_ip"]}
    fut = STATE["publisher"].publish(CFG["topic"], json.dumps(msg).encode(),
                                     country=info["country"])
    fut.add_done_callback(lambda f: f.exception() and
                          print("Pub/Sub publish failed:", f.exception(), flush=True))
    return msg


FORM = b"""<!doctype html><html><body style="font-family:sans-serif">
<h2>HW5 file server (VM + Cloud SQL)</h2>
<p>GET: append a file name to the URL, e.g. <code>/123.html</code></p>
<form method="POST"><label>File name (sent with POST):
<input name="filename" value="123.html"></label> <button type="submit">POST</button></form>
</body></html>"""


# ================================================================== handler
class Handler(BaseHTTPRequestHandler):
    server_version = "HW5FileServer/1.0"
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt, *args):
        pass

    def __getattr__(self, name):            # do_PUT, do_DELETE, do_TRACE, ...
        if name.startswith("do_"):
            return self.handle_not_implemented
        raise AttributeError(name)

    def do_GET(self):
        if self.path.split("?")[0] == "/":
            return send_response(self, 200, FORM, "text/html; charset=utf-8")
        self.handle_file_request(extract_request_info(self))

    def do_POST(self):
        n = min(int(self.headers.get("Content-Length") or 0), 1 << 20)
        raw = self.rfile.read(n).decode("utf-8", "replace") if n else ""
        ctype = self.headers.get("Content-Type", "")
        name = ""
        if "json" in ctype:
            try:
                d = json.loads(raw)
                name = str(d.get("filename") or d.get("file") or "")
            except (ValueError, AttributeError):
                pass
        elif "form" in ctype:
            q = parse_qs(raw)
            name = (q.get("filename") or q.get("file") or [""])[0]
        else:
            name = raw.strip()
        self.handle_file_request(extract_request_info(self, name))

    def handle_not_implemented(self):
        t0 = time.perf_counter_ns()
        info = extract_request_info(self)
        log_event("ERROR", info, 501, "method not implemented")
        send_response(self, 501, b"501 Not Implemented\n")
        record_in_database(info, 501)
        TIMINGS.add("total", time.perf_counter_ns() - t0)

    def handle_file_request(self, info):
        t0 = time.perf_counter_ns()
        if info["is_banned"]:
            msg = publish_forbidden(info)
            log_event("CRITICAL", info, 400, "forbidden country")
            status, body = 400, (f"400 Permission denied: export to "
                                 f"{html.escape(info['country'])} is prohibited\n").encode()
            ctype = "text/plain; charset=utf-8"
        else:
            data = read_from_storage(info["file"]) if info["file"] else None
            if data is None:
                log_event("WARNING", info, 404, "file not found")
                status, body = 404, f"404 Not Found: {html.escape(info['file'])}\n".encode()
                ctype = "text/plain; charset=utf-8"
            else:
                status, body, ctype = 200, data, "text/html; charset=utf-8"
        send_response(self, status, body, ctype)
        record_in_database(info, status)
        TIMINGS.add("total", time.perf_counter_ns() - t0)


# ===================================================================== main
def setup(args):
    CFG.update(bucket=args.bucket, prefix=args.prefix, topic=args.topic)
    STATE["log"] = setup_logging(not args.local)
    if args.db_url:                               # local testing only
        STATE["engine"] = sqlalchemy.create_engine(args.db_url)
        return
    from google.cloud import pubsub_v1, storage
    STATE["bucket"] = storage.Client().bucket(args.bucket)
    STATE["publisher"] = pubsub_v1.PublisherClient()
    password = db.get_password(args.project, args.db_secret)
    STATE["engine"] = db.make_engine(args.instance, args.db_user, password, args.db_name,
                                     pool_size=8)
    db.create_schema(STATE["engine"])             # idempotent (CREATE TABLE IF NOT EXISTS)


def main():
    ap = argparse.ArgumentParser(description="HW5 file server")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--project", default="cedar-pottery-508921-u1")
    ap.add_argument("--bucket", default="cedar-pottery-508921-u1-pages")
    ap.add_argument("--prefix", default="pages/")
    ap.add_argument("--topic", default="")
    ap.add_argument("--instance", help="Cloud SQL connection name project:region:instance")
    ap.add_argument("--db-name", default="hw5")
    ap.add_argument("--db-user", default="hw5app")
    ap.add_argument("--db-secret", default="hw5-db-password")
    ap.add_argument("--timings-file", default="/var/tmp/hw5_timings.json")
    ap.add_argument("--db-url", help=argparse.SUPPRESS)
    ap.add_argument("--local", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()
    setup(args)

    threading.Thread(target=timings_writer, args=(args.timings_file,), daemon=True).start()

    def on_term(*_):
        write_timings(args.timings_file)
        sys.exit(0)
    signal.signal(signal.SIGTERM, on_term)

    srv = ThreadingHTTPServer(("0.0.0.0", args.port), Handler)
    srv.daemon_threads = True
    srv.request_queue_size = 128
    print(f"HW5 file server on :{args.port}, bucket={args.bucket}/{args.prefix}, "
          f"db={args.instance}/{args.db_name}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
