"""
Builds a Power BI-ready star schema from the clean_* tables in riyalpay.db.

Design decision: we do NOT export the full 1.73M-row event log as-is. Power BI
Import mode can technically hold that volume, but the event_properties JSON
column would need per-row parsing in Power Query (slow) or DAX (worse), and
none of the four dashboard pages actually need row-level event access --
they need pre-aggregated marts. So: purpose-built fact tables per dashboard
page, at the grain each page actually needs. This keeps the .pbix small,
fast, and easy to review -- and is itself a defensible product-analytics
judgment call, not just a shortcut.
"""
import sqlite3
import pandas as pd
from datetime import datetime, timedelta

import os

# Expects riyalpay.db in the same folder as this script (see sql/00_load_raw.py
# and sql/02_reconcile_and_clean.py in the SQL package to build it). Writes the
# Power BI CSVs to a "powerbi_data" subfolder, created if it doesn't exist.
DB_PATH = "riyalpay.db"
OUT = "powerbi_data"
os.makedirs(OUT, exist_ok=True)

conn = sqlite3.connect(DB_PATH)

# =====================================================================
# DIM: users
# =====================================================================
dim_users = pd.read_sql("SELECT * FROM clean_users WHERE is_test_account = 0", conn)
dim_users.to_csv(f"{OUT}/dim_users.csv", index=False)
print(f"dim_users: {len(dim_users):,} rows")

# =====================================================================
# DIM: date (calendar table for time intelligence)
# =====================================================================
start, end = datetime(2025, 6, 1), datetime(2026, 7, 15)
dates = pd.date_range(start, end, freq="D")
dim_date = pd.DataFrame({
    "date": dates,
    "year": dates.year,
    "month": dates.month,
    "month_name": dates.strftime("%B"),
    "year_month": dates.strftime("%Y-%m"),
    "day_of_week": dates.strftime("%A"),
    "week_of_year": dates.isocalendar().week.astype(int),
    "is_weekend": dates.dayofweek.isin([4, 5]),  # Fri/Sat weekend (Saudi week)
})
dim_date.to_csv(f"{OUT}/dim_date.csv", index=False)
print(f"dim_date: {len(dim_date):,} rows")

# =====================================================================
# FACT: user funnel milestones (one row per user, wide format)
# This single table drives the entire activation funnel + time-to-activate
# analysis in Power BI -- no DAX event-chasing required.
# =====================================================================
first_event = pd.read_sql("""
    SELECT user_id, event_name, MIN(event_timestamp) AS first_ts
    FROM clean_events WHERE user_id IS NOT NULL AND is_suspected_bot = 0
    GROUP BY user_id, event_name
""", conn)
fe_pivot = first_event.pivot_table(index="user_id", columns="event_name", values="first_ts", aggfunc="first")

first_txn = pd.read_sql("""
    SELECT user_id, MIN(transaction_timestamp) AS first_activation_ts
    FROM clean_transactions WHERE status = 'success'
    GROUP BY user_id
""", conn)

users_base = dim_users[["user_id", "signup_date", "signup_channel", "platform", "city", "age_bracket", "kyc_status"]]
funnel = users_base.merge(fe_pivot[["signup_complete", "kyc_start", "kyc_approved"]] if
                           set(["signup_complete","kyc_start","kyc_approved"]).issubset(fe_pivot.columns)
                           else fe_pivot, on=None, left_on="user_id", right_index=True, how="left")
funnel = funnel.merge(first_txn, on="user_id", how="left")
funnel = funnel.rename(columns={"signup_complete": "signup_complete_ts",
                                 "kyc_start": "kyc_start_ts",
                                 "kyc_approved": "kyc_approved_ts"})
for col in ["signup_complete_ts", "kyc_start_ts", "kyc_approved_ts", "first_activation_ts"]:
    if col not in funnel.columns:
        funnel[col] = pd.NaT

# Nested funnel. Each stage is a subset of the one before it: a user who started
# KYC (or transacted) necessarily signed up, even if their signup_complete event
# was never recorded. ~1.4% of users (344) have KYC/transaction activity but NO
# signup_start / signup_otp_verify / signup_complete events -- an onboarding
# tracking gap (profiling check 16). Counting each stage independently left those
# users in the later stages but out of the signup base, overstating every
# conversion rate. They are counted as signed up here, and signup_event_missing
# keeps the gap visible rather than erasing it.
signup_event_seen = funnel["signup_complete_ts"].notna()
r_activation = funnel["first_activation_ts"].notna()
r_approved = funnel["kyc_approved_ts"].notna() | r_activation
r_kyc_start = funnel["kyc_start_ts"].notna() | r_approved
r_signup = signup_event_seen | r_kyc_start
funnel["reached_signup"] = r_signup
funnel["reached_kyc_start"] = r_kyc_start
funnel["reached_kyc_approved"] = r_approved
funnel["reached_activation"] = r_activation
funnel["signup_event_missing"] = r_signup & ~signup_event_seen
funnel["days_to_activation"] = (pd.to_datetime(funnel["first_activation_ts"]) -
                                 pd.to_datetime(funnel["signup_date"])).dt.days

funnel.to_csv(f"{OUT}/fact_user_funnel.csv", index=False)
print(f"fact_user_funnel: {len(funnel):,} rows")

# =====================================================================
# FACT: monthly cohort retention (cohort_month x month_offset grid)
# =====================================================================
# Retention rules (each one fixes a real problem found while building the page):
#  1. Month offset = CALENDAR months between signup month and activity month.
#     The earlier version divided days by 30, which mislabels any span that
#     crosses February (28 days): Jan/Feb cohorts got merged and missing cells.
#  2. Only COMPLETE months are counted. The data ends mid-July 2026, so July is
#     a partial month and would understate the last cell of every cohort
#     (e.g. the June cohort's Month 1 read 36.7%). LAST_COMPLETE_MONTH below.
#  3. platform and signup_channel are kept as columns so the page can be sliced.
#     retention_pct is stored per row for convenience, but anything that
#     aggregates rows must use SUM(active_users) / SUM(cohort_size) (a DAX
#     measure) -- averaging percentages weights a 204-user cohort like a 4,810-user one.
LAST_COMPLETE_MONTH = "2026-06-01"   # data pull date is 2026-07-15
cohort_sql = f"""
WITH cohort AS (
  SELECT user_id, platform, signup_channel,
         DATE(signup_date, 'start of month') AS cohort_month
  FROM clean_users WHERE is_test_account = 0
),
activity AS (
  SELECT DISTINCT c.cohort_month, c.platform, c.signup_channel, e.user_id,
         (CAST(strftime('%Y', e.event_timestamp) AS INT) - CAST(strftime('%Y', c.cohort_month) AS INT)) * 12
       + (CAST(strftime('%m', e.event_timestamp) AS INT) - CAST(strftime('%m', c.cohort_month) AS INT)) AS month_offset
  FROM clean_events e JOIN cohort c ON c.user_id = e.user_id
  WHERE e.is_suspected_bot = 0
    AND DATE(e.event_timestamp, 'start of month') <= '{LAST_COMPLETE_MONTH}'
)
SELECT cohort_month, month_offset, platform, signup_channel, COUNT(DISTINCT user_id) AS active_users
FROM activity WHERE month_offset BETWEEN 0 AND 6
GROUP BY cohort_month, month_offset, platform, signup_channel
ORDER BY cohort_month, month_offset, platform, signup_channel
"""
cohort_df = pd.read_sql(cohort_sql, conn)
cohort_size = pd.read_sql("""
    SELECT DATE(signup_date, 'start of month') AS cohort_month, platform, signup_channel, COUNT(*) AS cohort_size
    FROM clean_users WHERE is_test_account = 0 GROUP BY cohort_month, platform, signup_channel
""", conn)
cohort_df = cohort_df.merge(cohort_size, on=["cohort_month", "platform", "signup_channel"], how="left")
cohort_df["retention_pct"] = (cohort_df["active_users"] / cohort_df["cohort_size"] * 100).round(1)
cohort_df.to_csv(f"{OUT}/fact_cohort_retention.csv", index=False)
print(f"fact_cohort_retention: {len(cohort_df):,} rows")

# =====================================================================
# FACT: experiment user-level outcomes (one row per assigned, clean user)
# Kept at user grain (not pre-aggregated) so Power BI can slice by any
# dimension -- platform, channel, city -- without re-querying SQL.
# =====================================================================
exp = pd.read_sql("""
    SELECT user_id, experiment_id, variant, assignment_date, platform, is_contaminated
    FROM clean_experiment_assignments
""", conn)
exp_clean = exp[exp["is_contaminated"] == 0].copy()

kyc_outcome = pd.read_sql("""
    SELECT user_id, MAX(CASE WHEN event_name='kyc_approved' THEN 1 ELSE 0 END) AS kyc_approved
    FROM clean_events WHERE is_suspected_bot = 0 GROUP BY user_id
""", conn)
activated = pd.read_sql("SELECT DISTINCT user_id, 1 AS activated FROM clean_transactions WHERE status='success'", conn)

exp_outcomes = exp_clean.merge(kyc_outcome, on="user_id", how="left").merge(activated, on="user_id", how="left")
exp_outcomes["kyc_approved"] = exp_outcomes["kyc_approved"].fillna(0).astype(int)
exp_outcomes["activated"] = exp_outcomes["activated"].fillna(0).astype(int)
exp_outcomes["experiment_week"] = ((pd.to_datetime(exp_outcomes["assignment_date"]) -
                                     pd.Timestamp("2026-02-02")).dt.days // 7) + 1
exp_outcomes.to_csv(f"{OUT}/fact_experiment_user_outcomes.csv", index=False)
print(f"fact_experiment_user_outcomes: {len(exp_outcomes):,} rows")

# also keep the FULL (uncleaned) assignment log as its own table, so the SRM
# chart can show the actual skew -- excluding contamination would hide it
exp.to_csv(f"{OUT}/fact_experiment_assignments_all.csv", index=False)
print(f"fact_experiment_assignments_all: {len(exp):,} rows")

# =====================================================================
# FACT: transactions (cleaned)
# =====================================================================
txn = pd.read_sql("SELECT * FROM clean_transactions", conn)
txn.to_csv(f"{OUT}/fact_transactions.csv", index=False)
print(f"fact_transactions: {len(txn):,} rows")

# =====================================================================
# FACT: daily event summary (for engagement/trend visuals without
# importing the full 1.73M-row event log)
# =====================================================================
daily_events = pd.read_sql("""
    SELECT DATE(event_timestamp) AS event_date, event_name, platform, COUNT(*) AS n_events,
           COUNT(DISTINCT user_id) AS n_unique_users
    FROM clean_events
    WHERE is_suspected_bot = 0
    GROUP BY event_date, event_name, platform
""", conn)
daily_events.to_csv(f"{OUT}/fact_daily_event_summary.csv", index=False)
print(f"fact_daily_event_summary: {len(daily_events):,} rows")

conn.close()
print("\nAll Power BI export tables written.")
