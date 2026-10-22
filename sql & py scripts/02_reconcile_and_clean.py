"""
02_reconcile_and_clean.py

Reconciliation and cleaning layer. JSON key-remapping is done here in Python
(cleaner than string-hacking JSON in SQLite) rather than in SQL; every other
transformation is a straightforward, auditable rule. Writes clean_* tables
back into riyalpay.db, alongside the untouched raw_* tables, so both layers
are inspectable side by side.
"""
import sqlite3
import pandas as pd
import json
from datetime import timedelta

DB = "riyalpay.db"  # expects riyalpay.db in the same folder (run 00_load_raw.py first)
conn = sqlite3.connect(DB)

# =====================================================================
# 1. CLEAN USERS
# =====================================================================
users = pd.read_sql("SELECT * FROM raw_users", conn)

# 1a. de-dupe: keep first occurrence per user_id (arbitrary but documented rule)
before = len(users)
users = users.sort_index().drop_duplicates(subset="user_id", keep="first")
print(f"clean_users: dropped {before - len(users)} duplicate rows ({before} -> {len(users)})")

# 1b. normalize city text: trim, title-case, fix known aliases
# NOTE: "jedda" is a genuine misspelling of Jeddah (missing the second "h"),
# not a casing/whitespace issue -- .strip().lower() alone won't catch it,
# so it needs an explicit alias entry same as makkah/madinah.
CITY_ALIASES = {"makkah": "Mecca", "madinah": "Medina", "jedda": "Jeddah"}
def normalize_city(c):
    if pd.isna(c):
        return None
    c2 = c.strip().lower()
    c2 = CITY_ALIASES.get(c2, c2)
    return c2.title() if c2 not in ("mecca", "medina") else c2.title()

users["city_clean"] = users["city"].map(normalize_city)
users["is_test_account"] = users["is_test_account"].astype(str).str.lower().eq("true")

users_out = users[["user_id", "signup_date", "signup_channel", "platform",
                    "city_clean", "age_bracket", "kyc_status", "is_test_account"]].rename(
                    columns={"city_clean": "city"})
users_out.to_sql("clean_users", conn, if_exists="replace", index=False)
print(f"clean_users written: {len(users_out)} rows")

# =====================================================================
# 2. CLEAN EVENTS — reconcile pre/post migration schemas
# =====================================================================
pre = pd.read_sql("SELECT * FROM raw_events_pre_migration", conn)
post = pd.read_sql("SELECT * FROM raw_events_post_migration", conn)

EVENT_RENAME_PRE = {"p2p_transfer_success": "send_money_success",
                     "p2p_transfer_failed": "send_money_failed",
                     "p2p_transfer_start": "send_money_start"}
KEY_UNMAP_PRE = {"amt": "amount", "curr": "currency", "pay_method": "method",
                  "recip_type": "recipient_type", "fail_reason": "reason",
                  "doc_type": "document_type", "biller_cat": "biller_category",
                  "cmp_id": "campaign_id", "exp_variant": "experiment_variant"}

def remap_props(raw_json):
    try:
        d = json.loads(raw_json) if raw_json and raw_json != "{}" else {}
    except (json.JSONDecodeError, TypeError):
        return {}
    return {KEY_UNMAP_PRE.get(k, k): v for k, v in d.items()}

pre["event_name"] = pre["event"].map(lambda e: EVENT_RENAME_PRE.get(e, e))
pre["event_timestamp_utc"] = pd.to_datetime(pre["ts"]) + timedelta(hours=3)  # was stored as naive Riyadh local (UTC+3)
pre["ingested_at_utc"] = pd.to_datetime(pre["ingested_at"]) + timedelta(hours=3)
pre["platform_clean"] = pre["plat"].map({"ios": "iOS", "android": "Android"})
pre["event_properties"] = pre["props"].map(lambda p: json.dumps(remap_props(p)))
pre_clean = pre[["uid", "event_name", "event_timestamp_utc", "platform_clean", "ver",
                  "event_properties", "ingested_at_utc"]].rename(
                  columns={"uid": "user_id", "event_timestamp_utc": "event_timestamp",
                           "platform_clean": "platform", "ver": "app_version",
                           "ingested_at_utc": "ingested_at"})
pre_clean["source_schema"] = "legacy_sdk"

post["event_timestamp"] = pd.to_datetime(post["event_timestamp"]).dt.tz_localize(None)
post["ingested_at"] = pd.to_datetime(post["ingested_at"]).dt.tz_localize(None)
post_clean = post[["user_id", "event_name", "event_timestamp", "platform", "app_version",
                    "event_properties", "ingested_at"]].copy()
post_clean["source_schema"] = "segment"

events = pd.concat([pre_clean, post_clean], ignore_index=True)
before = len(events)

# 2a. drop exact duplicates (same user, event, timestamp)
events = events.drop_duplicates(subset=["user_id", "event_name", "event_timestamp"], keep="first")
print(f"clean_events: dropped {before - len(events)} exact-duplicate rows")

# 2b. flag (not silently drop) suspected bot traffic at the EVENT level: any
# user with more than 100 events inside a single clock hour. A real user
# generates tens of events a MONTH, so a burst this dense is not human.
# Why event-level and not user-level: an earlier version averaged events over
# each user's whole history (events/day > 200). A one-hour burst landing on a
# real user ID was diluted by months of normal activity and slipped through
# (found via a "events dated before signup" check, see profiling check 14).
# Flagging only the burst events also keeps that user's genuine signup/KYC
# events in the funnel instead of discarding the whole user.
BURST_THRESHOLD = 100  # events per user per hour
ident = events["user_id"].notna()
events["_hour"] = events["event_timestamp"].dt.floor("h")
hourly = events[ident].groupby(["user_id", "_hour"])["event_name"].transform("size")
events["is_suspected_bot"] = False
events.loc[ident, "is_suspected_bot"] = (hourly > BURST_THRESHOLD).values
events = events.drop(columns="_hour")
n_bot_users = events.loc[events["is_suspected_bot"], "user_id"].nunique()
print(f"clean_events: flagged {events['is_suspected_bot'].sum():,} burst events "
      f"from {n_bot_users} user_ids (>{BURST_THRESHOLD} events/user/hour)")

# 2c. flag genuine app_version gaps (addresses profiling check 8). app_version
# itself is left untouched -- including the literal "unknown" string, which is
# a valid sentinel for anonymous (no user_id) pre-signup traffic, not a defect.
# The real data-quality issue is NULL on an IDENTIFIED user's event (a true
# logging gap). We don't silently drop or impute these rows -- same philosophy
# as is_suspected_bot/is_contaminated: flag, don't erase, so downstream queries
# can filter deliberately instead of every analyst re-deriving this logic.
events["is_version_gap"] = events["app_version"].isna() & events["user_id"].notna()
print(f"clean_events: flagged {events['is_version_gap'].sum():,} genuine app_version gaps "
      f"(identified users with no logged version) -- 'unknown' on anonymous events is untouched, not a gap")

events.to_sql("clean_events", conn, if_exists="replace", index=False)
print(f"clean_events written: {len(events)} rows")

# =====================================================================
# 3. CLEAN TRANSACTIONS — normalize currency
# =====================================================================
txn = pd.read_sql("SELECT * FROM raw_transactions", conn)
CURRENCY_MAP = {"SAR": "SAR", "SR": "SAR", "ريال": "SAR"}
txn["currency_clean"] = txn["currency"].map(lambda c: CURRENCY_MAP.get(c, None))
txn["currency_was_missing_or_unmapped"] = txn["currency_clean"].isna()
txn["currency_clean"] = txn["currency_clean"].fillna("SAR")  # assume SAR (only currency in this product) but flag was_missing
txn_out = txn.rename(columns={"currency_clean": "currency_normalized"})
txn_out.to_sql("clean_transactions", conn, if_exists="replace", index=False)
print(f"clean_transactions written: {len(txn_out)} rows")

# =====================================================================
# 4. CLEAN EXPERIMENT ASSIGNMENTS — resolve duplicates/contamination
# =====================================================================
exp = pd.read_sql("SELECT * FROM raw_experiment_assignments", conn)
variant_counts = exp.groupby("user_id")["variant"].nunique()
contaminated_users = set(variant_counts[variant_counts > 1].index)
exp["is_contaminated"] = exp["user_id"].isin(contaminated_users)

# keep earliest assignment per user as their "assignment of record"
exp_sorted = exp.sort_values("assignment_date")
exp_dedup = exp_sorted.drop_duplicates(subset="user_id", keep="first").copy()
exp_dedup["is_contaminated"] = exp_dedup["user_id"].isin(contaminated_users)
print(f"clean_experiment_assignments: {len(exp)} raw rows -> {len(exp_dedup)} unique users "
      f"({len(contaminated_users)} flagged contaminated)")

exp_dedup.to_sql("clean_experiment_assignments", conn, if_exists="replace", index=False)

conn.commit()
conn.close()
print("\nAll clean_* tables written to riyalpay.db")
