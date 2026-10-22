"""
Loads the five raw CSV exports into a SQLite database, completely as-is —
no cleaning, no type coercion beyond what SQLite infers. This mirrors a raw
landing zone in a real warehouse. All cleaning happens in SQL from here on,
so the SQL work is inspectable and reviewable (not buried in pandas).
"""
import sqlite3
import pandas as pd
import os

DB_PATH = "riyalpay.db"
if os.path.exists(DB_PATH):
    os.remove(DB_PATH)

conn = sqlite3.connect(DB_PATH)

files = {
    "raw_users": "users_raw.csv",
    "raw_experiment_assignments": "experiment_assignments_raw.csv",
    "raw_events_pre_migration": "events_pre_migration_raw.csv",
    "raw_events_post_migration": "events_post_migration_raw.csv",
    "raw_transactions": "transactions_raw.csv",
}

for table, fname in files.items():
    df = pd.read_csv(f"{fname}")
    df.to_sql(table, conn, if_exists="replace", index=False)
    print(f"Loaded {table}: {len(df):,} rows, columns={list(df.columns)}")

conn.commit()
conn.close()
print("riyalpay.db created.")
