-- =====================================================================
-- 01_profiling.sql
-- RiyalPay — Data Quality Profiling
-- Run against: riyalpay.db (raw_* tables, loaded as-received, untouched)
-- Purpose: surface data quality issues before any cleaning happens, so
-- every downstream cleaning decision is backed by evidence, not assumption.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. USERS: duplicate user_id rows (ETL double-write)
-- ---------------------------------------------------------------------
SELECT user_id, COUNT(*) AS n_rows
FROM raw_users
GROUP BY user_id
HAVING COUNT(*) > 1
ORDER BY n_rows DESC
LIMIT 20;

-- how many duplicated user_ids total, and do the duplicate rows actually
-- disagree with each other (i.e. are they true dupes or conflicting records)?
WITH dupes AS (
  SELECT user_id FROM raw_users GROUP BY user_id HAVING COUNT(*) > 1
)
SELECT COUNT(DISTINCT user_id) AS duplicated_user_ids,
       (SELECT COUNT(*) FROM raw_users WHERE user_id IN (SELECT user_id FROM dupes)) AS total_dupe_rows
FROM dupes;

-- ---------------------------------------------------------------------
-- 2. USERS: field-level completeness and messiness
-- ---------------------------------------------------------------------
SELECT
  COUNT(*) AS total_rows,
  SUM(CASE WHEN city IS NULL THEN 1 ELSE 0 END) AS null_city,
  SUM(CASE WHEN age_bracket IS NULL THEN 1 ELSE 0 END) AS null_age_bracket,
  SUM(CASE WHEN is_test_account = 'True' THEN 1 ELSE 0 END) AS test_accounts
FROM raw_users;

-- distinct raw city spellings -- this is the "messy text field" check
SELECT city, COUNT(*) AS n
FROM raw_users
GROUP BY city
ORDER BY n DESC;

-- ---------------------------------------------------------------------
-- 3. EVENTS: schema comparison between pre- and post-migration exports
-- ---------------------------------------------------------------------
-- distinct event names in each export -- do they even use the same taxonomy?
-- NOTE: an earlier version of this query used ORDER BY event_name + LIMIT 30,
-- which cut off alphabetically before it ever reached the 's' events --
-- meaning it never actually showed the send_money_* rows it was trying to
-- compare against p2p_transfer_*. Isolating only the mismatched names (below)
-- avoids that failure mode entirely, instead of hoping the LIMIT is generous
-- enough to reach the interesting part.
WITH combined AS (
  SELECT 'pre_migration' AS source, event AS event_name, COUNT(*) AS n
  FROM raw_events_pre_migration GROUP BY event
  UNION ALL
  SELECT 'post_migration' AS source, event_name, COUNT(*) AS n
  FROM raw_events_post_migration GROUP BY event_name
)
SELECT event_name, source, n
FROM combined
WHERE event_name IN (
  SELECT event_name FROM combined GROUP BY event_name HAVING COUNT(DISTINCT source) = 1
)
ORDER BY event_name, source;
-- Any event name appearing on only ONE side is either a rename across the
-- migration (needs an explicit mapping, e.g. p2p_transfer_* -> send_money_*)
-- or a genuinely new/retired event -- worth checking which case it is.

-- full side-by-side reference (all event names, both sources) for context
SELECT 'pre_migration' AS source, event AS event_name, COUNT(*) AS n
FROM raw_events_pre_migration GROUP BY event
UNION ALL
SELECT 'post_migration' AS source, event_name, COUNT(*) AS n
FROM raw_events_post_migration GROUP BY event_name
ORDER BY event_name, source;
-- Expect to find: p2p_transfer_* in pre-migration has no direct name match in
-- post-migration (renamed to send_money_*) -- this must be mapped explicitly.

-- date range covered by each export -- confirm the migration boundary
SELECT 'pre_migration' AS source, MIN(ts) AS min_ts, MAX(ts) AS max_ts FROM raw_events_pre_migration
UNION ALL
SELECT 'post_migration' AS source, MIN(event_timestamp), MAX(event_timestamp) FROM raw_events_post_migration;

-- ---------------------------------------------------------------------
-- 4. EVENTS: null user_id volume (anonymous / pre-signup traffic)
-- ---------------------------------------------------------------------
SELECT 'pre_migration' AS source, SUM(CASE WHEN uid IS NULL THEN 1 ELSE 0 END) AS null_user_id, COUNT(*) AS total
FROM raw_events_pre_migration
UNION ALL
SELECT 'post_migration', SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END), COUNT(*)
FROM raw_events_post_migration;

-- ---------------------------------------------------------------------
-- 5. EVENTS: exact duplicate rows (client retry artifacts)
-- Check BOTH exports -- duplicates were introduced before the data was
-- split by migration date, so both files can contain them, not just one.
-- ---------------------------------------------------------------------
SELECT user_id, event_name, event_timestamp, COUNT(*) AS n
FROM raw_events_post_migration
WHERE user_id IS NOT NULL
GROUP BY user_id, event_name, event_timestamp
HAVING COUNT(*) > 1
ORDER BY n DESC
LIMIT 20;

SELECT uid AS user_id, event AS event_name, ts AS event_timestamp, COUNT(*) AS n
FROM raw_events_pre_migration
WHERE uid IS NOT NULL
GROUP BY uid, event, ts
HAVING COUNT(*) > 1
ORDER BY n DESC
LIMIT 20;

-- total duplicate row volume in each export, for a quick side-by-side scale check
SELECT 'post_migration' AS source, COUNT(*) AS duplicate_groups FROM (
  SELECT user_id, event_name, event_timestamp FROM raw_events_post_migration
  WHERE user_id IS NOT NULL GROUP BY user_id, event_name, event_timestamp HAVING COUNT(*) > 1
)
UNION ALL
SELECT 'pre_migration', COUNT(*) FROM (
  SELECT uid, event, ts FROM raw_events_pre_migration
  WHERE uid IS NOT NULL GROUP BY uid, event, ts HAVING COUNT(*) > 1
);

-- ---------------------------------------------------------------------
-- 6. EVENTS: suspiciously high-frequency users (likely bots, not caught
-- by is_test_account flag on the users table)
-- Check BOTH exports. Also: n_events alone is a weak signal on its own --
-- a long-tenured active user can rack up hundreds of events over many
-- months at a low, ordinary rate. events_per_day is the actual bot
-- signal (real bots here run 1,000+ events/day; genuine power users
-- top out around 20-30/day) -- keep n_events only as a cheap pre-filter,
-- and always eyeball events_per_day before calling something a bot.
-- ---------------------------------------------------------------------
SELECT user_id, COUNT(*) AS n_events,
       ROUND(COUNT(*) * 1.0 / (JULIANDAY(MAX(event_timestamp)) - JULIANDAY(MIN(event_timestamp)) + 1), 2) AS events_per_day
FROM raw_events_post_migration
WHERE user_id IS NOT NULL
GROUP BY user_id
HAVING n_events > 200
ORDER BY events_per_day DESC
LIMIT 30;

SELECT uid AS user_id, COUNT(*) AS n_events,
       ROUND(COUNT(*) * 1.0 / (JULIANDAY(MAX(ts)) - JULIANDAY(MIN(ts)) + 1), 2) AS events_per_day
FROM raw_events_pre_migration
WHERE uid IS NOT NULL
GROUP BY uid
HAVING n_events > 200
ORDER BY events_per_day DESC
LIMIT 30;

-- accurate total count (no LIMIT) -- the two queries above are previews only,
-- ordered by events_per_day to surface the worst offenders first, but do NOT
-- use len(df) on their results as "how many flagged users" -- it's capped at 30.
SELECT 'post_migration' AS source, COUNT(*) AS n_users_over_200_events FROM (
  SELECT user_id FROM raw_events_post_migration WHERE user_id IS NOT NULL
  GROUP BY user_id HAVING COUNT(*) > 200
)
UNION ALL
SELECT 'pre_migration', COUNT(*) FROM (
  SELECT uid FROM raw_events_pre_migration WHERE uid IS NOT NULL
  GROUP BY uid HAVING COUNT(*) > 200
);
-- NOTE: this counts everyone over the 200-event pre-filter, not just true
-- bots -- cross-reference against events_per_day (see comment above check 6)
-- to see how many of these are actually high-rate vs. just long-tenured.

-- ---------------------------------------------------------------------
-- 7. EVENTS: late-arriving data (ingested_at far after event_timestamp)
-- Check both exports -- same reasoning as checks 5 and 6: this messiness
-- was injected before the pre/post migration split, so it can appear in
-- either file.
-- ---------------------------------------------------------------------
SELECT
  CAST((JULIANDAY(ingested_at) - JULIANDAY(event_timestamp)) * 24 AS INT) AS hours_late_bucket,
  COUNT(*) AS n
FROM raw_events_post_migration
WHERE JULIANDAY(ingested_at) - JULIANDAY(event_timestamp) > 0.04  -- ~1hr+
GROUP BY hours_late_bucket
ORDER BY hours_late_bucket DESC
LIMIT 20;

SELECT
  CAST((JULIANDAY(ingested_at) - JULIANDAY(ts)) * 24 AS INT) AS hours_late_bucket,
  COUNT(*) AS n
FROM raw_events_pre_migration
WHERE JULIANDAY(ingested_at) - JULIANDAY(ts) > 0.04  -- ~1hr+
GROUP BY hours_late_bucket
ORDER BY hours_late_bucket DESC
LIMIT 20;

-- side-by-side scale check (accurate total -- use this for "found X%",
-- not the bucketed previews above, which only show 20 of the ~66 distinct
-- hour-buckets that actually exist)
SELECT 'post_migration' AS source,
       SUM(CASE WHEN JULIANDAY(ingested_at) - JULIANDAY(event_timestamp) > 0.04 THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS pct_late
FROM raw_events_post_migration
UNION ALL
SELECT 'pre_migration',
       SUM(CASE WHEN JULIANDAY(ingested_at) - JULIANDAY(ts) > 0.04 THEN 1 ELSE 0 END) * 1.0 / COUNT(*)
FROM raw_events_pre_migration;

-- ---------------------------------------------------------------------
-- 8. EVENTS: missing/unusable app_version -- check both exports, and
-- don't just check IS NULL: post-migration also uses the literal string
-- 'unknown' as a sentinel for anonymous (pre-signup, no user_id) traffic.
-- These are NOT the same kind of issue -- 'unknown' on anonymous events
-- is expected/benign (there's genuinely no app context yet), while NULL
-- on an IDENTIFIED user's event is a real logging gap worth investigating.
-- Broken out separately on purpose; blending them into one % would hide
-- which part is an actual pipeline problem.
-- ---------------------------------------------------------------------
SELECT
  CASE WHEN app_version IS NULL THEN 'null'
       WHEN LOWER(app_version) = 'unknown' THEN 'unknown'
       ELSE 'has_version' END AS version_status,
  CASE WHEN user_id IS NULL THEN 'anonymous' ELSE 'identified' END AS user_status,
  COUNT(*) AS n
FROM raw_events_post_migration
GROUP BY version_status, user_status
ORDER BY version_status, user_status;

SELECT
  CASE WHEN ver IS NULL THEN 'null'
       WHEN LOWER(ver) = 'unknown' THEN 'unknown'
       ELSE 'has_version' END AS version_status,
  CASE WHEN uid IS NULL THEN 'anonymous' ELSE 'identified' END AS user_status,
  COUNT(*) AS n
FROM raw_events_pre_migration
GROUP BY version_status, user_status
ORDER BY version_status, user_status;

-- the number that actually matters for data-quality escalation: NULL
-- version on an IDENTIFIED user's event (excludes the benign anonymous case)
SELECT 'post_migration' AS source,
       SUM(CASE WHEN app_version IS NULL AND user_id IS NOT NULL THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS pct_genuine_gap
FROM raw_events_post_migration
UNION ALL
SELECT 'pre_migration',
       SUM(CASE WHEN ver IS NULL AND uid IS NOT NULL THEN 1 ELSE 0 END) * 1.0 / COUNT(*)
FROM raw_events_pre_migration;

-- ---------------------------------------------------------------------
-- 9. TRANSACTIONS: currency field messiness
-- ---------------------------------------------------------------------
SELECT currency, COUNT(*) AS n
FROM raw_transactions
GROUP BY currency
ORDER BY n DESC;

-- ---------------------------------------------------------------------
-- 10. TRANSACTIONS: reconciliation gaps against events
-- (transactions with no linked_event_id -- tracking gap)
-- ---------------------------------------------------------------------
SELECT status, transaction_type,
       SUM(CASE WHEN linked_event_id IS NULL THEN 1 ELSE 0 END) AS missing_event_link,
       COUNT(*) AS total
FROM raw_transactions
GROUP BY status, transaction_type
ORDER BY total DESC;

-- ---------------------------------------------------------------------
-- 11. TRANSACTIONS: status distribution and the outage-day anomaly
-- ---------------------------------------------------------------------
WITH daily AS (
  SELECT DATE(transaction_timestamp) AS txn_date,
         SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) AS n_failed,
         COUNT(*) AS n_total,
         SUM(CASE WHEN status='failed' THEN 1 ELSE 0 END) * 1.0 / COUNT(*) AS failure_rate
  FROM raw_transactions
  WHERE transaction_type = 'top_up'
  GROUP BY txn_date
)
SELECT txn_date, n_failed, n_total, ROUND(failure_rate, 3) AS failure_rate
FROM daily
WHERE failure_rate > 0.15   -- baseline failure rate is roughly 5%; anything well above that is a signal
ORDER BY failure_rate DESC;
-- A day with failure_rate far above baseline (~5%) indicates a systemic
-- incident (e.g. a payment-gateway outage), not random noise.

-- ---------------------------------------------------------------------
-- 12. EXPERIMENT: assignment integrity — duplicate/contaminated assignments
-- ---------------------------------------------------------------------
SELECT user_id, COUNT(*) AS n_assignments, COUNT(DISTINCT variant) AS n_distinct_variants
FROM raw_experiment_assignments
GROUP BY user_id
HAVING COUNT(*) > 1
ORDER BY n_distinct_variants DESC, n_assignments DESC
LIMIT 20;
-- n_distinct_variants > 1 means the same user was assigned to BOTH arms —
-- a contamination case that must be resolved (typically: exclude) before analysis.

-- accurate total (no LIMIT) -- do NOT use len(df) on the preview above as
-- "how many users have duplicate assignments", it's capped at 20.
SELECT COUNT(*) AS n_users_with_duplicate_assignments FROM (
  SELECT user_id FROM raw_experiment_assignments
  GROUP BY user_id HAVING COUNT(*) > 1
);

-- ---------------------------------------------------------------------
-- 13. EXPERIMENT: sample ratio check by platform (the headline check)
-- ---------------------------------------------------------------------
SELECT platform, variant, COUNT(DISTINCT user_id) AS n_users
FROM raw_experiment_assignments
GROUP BY platform, variant
ORDER BY platform, variant;
-- Compare the control/treatment ratio within each platform to the intended
-- 50/50 split. A meaningfully skewed ratio on one platform but not the
-- other is a classic Sample Ratio Mismatch (SRM) signature.

-- ---------------------------------------------------------------------
-- 14. EVENTS: temporal integrity -- events dated BEFORE the user's signup
-- A user cannot act in the app before they exist. Checks both exports.
-- 1-day tolerance absorbs the pre-migration export's naive local-time
-- convention; real violations are days or weeks early, not hours.
-- (Found by this check: one-hour bursts of 300-900 home_view events on two
-- real user IDs, weeks before signup -- bot traffic whose ID collided with a
-- genuine user. A "events/day over the user's whole history" rule missed them
-- because months of normal activity diluted the burst.)
-- ---------------------------------------------------------------------
-- accurate totals first (no LIMIT)
WITH u AS (SELECT user_id, MIN(signup_date) AS signup_date FROM raw_users GROUP BY user_id)
SELECT 'post_migration' AS source, COUNT(*) AS events_before_signup, COUNT(DISTINCT e.user_id) AS users_affected
FROM raw_events_post_migration e JOIN u ON u.user_id = e.user_id
WHERE JULIANDAY(e.event_timestamp) < JULIANDAY(u.signup_date) - 1
UNION ALL
SELECT 'pre_migration', COUNT(*), COUNT(DISTINCT e.uid)
FROM raw_events_pre_migration e JOIN u ON u.user_id = e.uid
WHERE JULIANDAY(e.ts) < JULIANDAY(u.signup_date) - 1;

-- preview of the offenders (LIMIT is fine here -- totals are above)
WITH u AS (SELECT user_id, MIN(signup_date) AS signup_date FROM raw_users GROUP BY user_id)
SELECT e.user_id, u.signup_date, COUNT(*) AS events_before_signup,
       MIN(e.event_timestamp) AS earliest_event,
       COUNT(DISTINCT SUBSTR(e.event_timestamp, 1, 13)) AS distinct_hours
FROM raw_events_post_migration e JOIN u ON u.user_id = e.user_id
WHERE JULIANDAY(e.event_timestamp) < JULIANDAY(u.signup_date) - 1
GROUP BY e.user_id, u.signup_date
ORDER BY events_before_signup DESC
LIMIT 20;
-- distinct_hours = 1 (or very few) with hundreds of events is the burst signature.

-- ---------------------------------------------------------------------
-- 15. EVENTS: burst detection -- peak events per user per hour
-- This is the direct test behind the cleaning step's is_suspected_bot rule.
-- Check 14 (events before signup) only catches bursts that happen to land
-- BEFORE the user's signup date; a burst after signup looks like activity.
-- Check 6 (events/day over a user's whole history) dilutes a one-hour burst
-- across months. Peak-hour density is the signal that neither of those shows.
-- ---------------------------------------------------------------------
-- accurate totals first (no LIMIT). has_user_row separates IDs that belong to
-- no registered user at all (pure bots) from bursts on real users' IDs.
WITH hourly AS (
  SELECT user_id, SUBSTR(event_timestamp, 1, 13) AS hour_bucket, COUNT(*) AS n
  FROM raw_events_post_migration WHERE user_id IS NOT NULL
  GROUP BY user_id, hour_bucket HAVING COUNT(*) > 100
),
u AS (SELECT DISTINCT user_id FROM raw_users)
SELECT CASE WHEN u.user_id IS NULL THEN 'no user row (pure bot)' ELSE 'real user ID (collision)' END AS id_type,
       COUNT(DISTINCT h.user_id) AS user_ids,
       COUNT(*) AS burst_hours,
       SUM(h.n) AS events_in_burst_hours
FROM hourly h LEFT JOIN u ON u.user_id = h.user_id
GROUP BY id_type;

-- same check on the pre-migration export (uid / ts columns); expect none
SELECT COUNT(*) AS pre_migration_burst_hours FROM (
  SELECT uid, SUBSTR(ts, 1, 13) AS hour_bucket
  FROM raw_events_pre_migration WHERE uid IS NOT NULL
  GROUP BY uid, hour_bucket HAVING COUNT(*) > 100
);

-- preview of the heaviest bursts (LIMIT is fine here -- totals are above)
SELECT user_id, SUBSTR(event_timestamp, 1, 13) AS hour_bucket, COUNT(*) AS events_in_hour
FROM raw_events_post_migration WHERE user_id IS NOT NULL
GROUP BY user_id, hour_bucket HAVING COUNT(*) > 100
ORDER BY events_in_hour DESC
LIMIT 15;

-- ---------------------------------------------------------------------
-- 16. EVENTS: funnel integrity -- later-stage events without the earlier ones
-- A user cannot start KYC without signing up, or be approved without starting.
-- Any violation means a tracking gap (events never fired or never arrived), and
-- it silently corrupts funnel math if each stage is counted independently:
-- later stages contain users the earlier stages never counted.
-- Uses BOTH exports -- the same user's events can sit on either side of the
-- migration date, so the pre- and post-migration files must be combined.
-- ---------------------------------------------------------------------
WITH ev AS (
  SELECT uid AS user_id, event AS event_name FROM raw_events_pre_migration WHERE uid IS NOT NULL
  UNION ALL
  SELECT user_id, event_name FROM raw_events_post_migration WHERE user_id IS NOT NULL
),
per_user AS (
  SELECT user_id,
         MAX(event_name = 'signup_complete') AS has_signup,
         MAX(event_name = 'signup_start')    AS has_signup_start,
         MAX(event_name = 'kyc_start')       AS has_kyc_start,
         MAX(event_name = 'kyc_approved')    AS has_kyc_approved
  FROM ev GROUP BY user_id
)
SELECT
  SUM(CASE WHEN has_kyc_start = 1 AND has_signup = 0 THEN 1 ELSE 0 END)      AS kyc_start_without_signup_complete,
  SUM(CASE WHEN has_kyc_start = 1 AND has_signup_start = 0 THEN 1 ELSE 0 END) AS kyc_start_without_signup_start,
  SUM(CASE WHEN has_kyc_approved = 1 AND has_kyc_start = 0 THEN 1 ELSE 0 END) AS approved_without_kyc_start,
  SUM(CASE WHEN has_kyc_start = 1 THEN 1 ELSE 0 END)                         AS users_with_kyc_start
FROM per_user;
-- Transactions need an approved KYC. Successful transactions by users with no
-- kyc_approved event at all (in either export):
SELECT COUNT(DISTINCT t.user_id) AS txn_users_without_kyc_approved
FROM raw_transactions t
WHERE t.status = 'success'
  AND t.user_id NOT IN (
    SELECT uid FROM raw_events_pre_migration WHERE event = 'kyc_approved' AND uid IS NOT NULL
    UNION
    SELECT user_id FROM raw_events_post_migration WHERE event_name = 'kyc_approved' AND user_id IS NOT NULL
  );
