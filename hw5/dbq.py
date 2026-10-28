"""
dbq.py - run SQL against the HW5 database and print the results as a table.

usage: python3 dbq.py --instance P:R:I "SELECT ..." ["SELECT ..." ...]
       python3 dbq.py --instance P:R:I --tables      # row counts + last 5 rows of each table
"""
import argparse

import sqlalchemy

import db


def show(conn, sql):
    res = conn.execute(sqlalchemy.text(sql))
    cols = list(res.keys())
    rows = [[("" if v is None else str(v)) for v in r] for r in res]
    w = [max([len(c)] + [len(r[i]) for r in rows]) for i, c in enumerate(cols)]
    line = "+".join("-" * (x + 2) for x in w)
    print(f"mysql> {' '.join(sql.split())};")
    print("+" + line + "+")
    print("| " + " | ".join(c.ljust(w[i]) for i, c in enumerate(cols)) + " |")
    print("+" + line + "+")
    for r in rows:
        print("| " + " | ".join(v.ljust(w[i]) for i, v in enumerate(r)) + " |")
    print("+" + line + "+")
    print(f"{len(rows)} row(s)\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="cedar-pottery-508921-u1")
    ap.add_argument("--instance", default="cedar-pottery-508921-u1:us-central1:hw5-db")
    ap.add_argument("--db-name", default="hw5")
    ap.add_argument("--db-user", default="hw5app")
    ap.add_argument("--db-secret", default="hw5-db-password")
    ap.add_argument("--tables", action="store_true")
    ap.add_argument("sql", nargs="*")
    a = ap.parse_args()
    engine = db.make_engine(a.instance, a.db_user, db.get_password(a.project, a.db_secret),
                            a.db_name, pool_size=1)
    queries = list(a.sql)
    if a.tables:
        queries += [
            "SELECT (SELECT COUNT(*) FROM requests) AS requests_rows, "
            "(SELECT COUNT(*) FROM failed_requests) AS failed_requests_rows",
            "SELECT * FROM requests ORDER BY request_id DESC LIMIT 5",
            "SELECT * FROM failed_requests ORDER BY failure_id DESC LIMIT 5"]
    with engine.connect() as conn:
        for q in queries:
            show(conn, q)


if __name__ == "__main__":
    main()
