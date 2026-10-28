"""
setup_schema.py - create the HW5 tables in Cloud SQL (called by setup.sh).

Idempotent: uses CREATE TABLE IF NOT EXISTS, so running it again is harmless.
Connects with the Cloud SQL Python Connector using the caller's Application
Default Credentials (Cloud Shell provides these automatically) and the app
user's password from Secret Manager / the DB_PASS environment variable.

usage: python3 setup_schema.py --instance PROJECT:REGION:INSTANCE [--project P]
"""
import argparse

import sqlalchemy

import db


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="cedar-pottery-508921-u1")
    ap.add_argument("--instance", required=True)
    ap.add_argument("--db-name", default="hw5")
    ap.add_argument("--db-user", default="hw5app")
    ap.add_argument("--db-secret", default="hw5-db-password")
    a = ap.parse_args()
    engine = db.make_engine(a.instance, a.db_user, db.get_password(a.project, a.db_secret),
                            a.db_name, pool_size=1)
    db.create_schema(engine)
    with engine.connect() as c:
        for t in ("requests", "failed_requests"):
            print(f"--- {t}")
            for row in c.execute(sqlalchemy.text(f"SHOW COLUMNS FROM {t}")):
                print("   ", row[0], row[1], "PRI" if row[3] == "PRI" else "")
    print("schema ready")


if __name__ == "__main__":
    main()
