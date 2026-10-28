"""
stats.py - answer the HW5 questions from the database (runs every query in stats.sql).

usage: python3 stats.py [--instance P:R:I] [--since '2026-10-28 00:00:00']
  --since  only count requests received at/after this UTC time (e.g. the start of
           the load test), so the few curl demo requests can be excluded.
"""
import argparse
import os

import sqlalchemy

import db
from dbq import show


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="cedar-pottery-508921-u1")
    ap.add_argument("--instance", default="cedar-pottery-508921-u1:us-central1:hw5-db")
    ap.add_argument("--db-name", default="hw5")
    ap.add_argument("--db-user", default="hw5app")
    ap.add_argument("--db-secret", default="hw5-db-password")
    ap.add_argument("--since", help="UTC 'YYYY-MM-DD HH:MM:SS'")
    a = ap.parse_args()
    sql = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "stats.sql")).read()
    queries = [q.strip() for q in "\n".join(l for l in sql.splitlines()
                                            if not l.strip().startswith("--")).split(";") if q.strip()]
    if a.since:
        f = f"'{a.since}'"
        queries = [q.replace("FROM requests WHERE", f"FROM requests WHERE received_at >= {f} AND")
                    .replace("FROM requests GROUP", f"FROM requests WHERE received_at >= {f} GROUP")
                    .replace("FROM requests;", f"FROM requests WHERE received_at >= {f};")
                    .replace("FROM failed_requests GROUP", f"FROM failed_requests WHERE request_time >= {f} GROUP")
                   for q in queries]
        queries = [q + (f" WHERE received_at >= {f}" if q.endswith("FROM requests") else "") for q in queries]
    engine = db.make_engine(a.instance, a.db_user, db.get_password(a.project, a.db_secret),
                            a.db_name, pool_size=1)
    with engine.connect() as conn:
        for q in queries:
            show(conn, q)


if __name__ == "__main__":
    main()
