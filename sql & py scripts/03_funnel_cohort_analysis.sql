-- =====================================================================
-- 03_funnel_cohort_analysis.sql
-- RiyalPay — Activation Funnel, Cohort Retention, Feature Adoption
-- Run against: riyalpay.db (clean_* tables)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ACTIVATION FUNNEL (overall)
-- Step order: signup_complete -> kyc_start -> kyc_approved -> first
-- successful transaction ("activation")
-- ---------------------------------------------------------------------
WITH first_event AS (
  SELECT user_id, event_name, MIN(event_timestamp) AS first_ts
  FROM clean_events
  WHERE user_id IS NOT NULL AND is_suspected_bot = 0
  GROUP BY user_id, event_name
),
first_txn AS (
  SELECT user_id, MIN(transaction_timestamp) AS first_txn_ts
  FROM clean_transactions
  WHERE status = 'success' AND transaction_type IN ('top_up','p2p_transfer','bill_pay','cashback')
  GROUP BY user_id
),
funnel_base AS (
  SELECT
    u.user_id,
    -- nested: anyone who started KYC (or transacted) necessarily signed up, even if their
    -- signup_complete event was never recorded (onboarding tracking gap, profiling check 16)
    MAX(CASE WHEN fe.event_name IN ('signup_complete','kyc_start','kyc_approved') OR ft.user_id IS NOT NULL THEN 1 ELSE 0 END) AS reached_signup,
    MAX(CASE WHEN fe.event_name IN ('kyc_start','kyc_approved') OR ft.user_id IS NOT NULL THEN 1 ELSE 0 END) AS reached_kyc_start,
    MAX(CASE WHEN fe.event_name = 'kyc_approved' OR ft.user_id IS NOT NULL THEN 1 ELSE 0 END) AS reached_kyc_approved,
    MAX(CASE WHEN ft.user_id IS NOT NULL THEN 1 ELSE 0 END) AS reached_activation
  FROM clean_users u
  LEFT JOIN first_event fe ON fe.user_id = u.user_id
  LEFT JOIN first_txn ft ON ft.user_id = u.user_id
  WHERE u.is_test_account = 0
  GROUP BY u.user_id
)
SELECT
  SUM(reached_signup) AS signup_complete,
  SUM(reached_kyc_start) AS kyc_start,
  SUM(reached_kyc_approved) AS kyc_approved,
  SUM(reached_activation) AS activated,
  ROUND(SUM(reached_kyc_start) * 100.0 / NULLIF(SUM(reached_signup),0), 1) AS pct_signup_to_kyc_start,
  ROUND(SUM(reached_kyc_approved) * 100.0 / NULLIF(SUM(reached_kyc_start),0), 1) AS pct_kyc_start_to_approved,
  ROUND(SUM(reached_activation) * 100.0 / NULLIF(SUM(reached_kyc_approved),0), 1) AS pct_approved_to_activated,
  ROUND(SUM(reached_activation) * 100.0 / NULLIF(SUM(reached_signup),0), 1) AS pct_overall_signup_to_activated
FROM funnel_base;

-- ---------------------------------------------------------------------
-- 2. FUNNEL BY ACQUISITION CHANNEL
-- ---------------------------------------------------------------------
WITH first_event AS (
  SELECT user_id, event_name, MIN(event_timestamp) AS first_ts
  FROM clean_events WHERE user_id IS NOT NULL AND is_suspected_bot = 0
  GROUP BY user_id, event_name
),
first_txn AS (
  SELECT user_id, MIN(transaction_timestamp) AS first_txn_ts
  FROM clean_transactions WHERE status = 'success'
  GROUP BY user_id
),
-- same base as the headline funnel: users who completed signup (nested -- includes
-- users whose signup events are missing but who clearly went on to KYC/transact)
signed_up AS (
  SELECT DISTINCT user_id FROM first_event WHERE event_name IN ('signup_complete','kyc_start','kyc_approved')
)
SELECT
  u.signup_channel,
  COUNT(DISTINCT u.user_id) AS signups,
  SUM(CASE WHEN fe_kyc.user_id IS NOT NULL THEN 1 ELSE 0 END) AS reached_kyc,
  SUM(CASE WHEN ft.user_id IS NOT NULL THEN 1 ELSE 0 END) AS activated,
  ROUND(SUM(CASE WHEN ft.user_id IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(DISTINCT u.user_id), 1) AS activation_rate_pct
FROM clean_users u
LEFT JOIN (SELECT DISTINCT user_id FROM first_event WHERE event_name = 'kyc_start') fe_kyc ON fe_kyc.user_id = u.user_id
LEFT JOIN first_txn ft ON ft.user_id = u.user_id
WHERE u.is_test_account = 0 AND u.user_id IN (SELECT user_id FROM signed_up)
GROUP BY u.signup_channel
ORDER BY activation_rate_pct DESC;

-- ---------------------------------------------------------------------
-- 3. FUNNEL BY PLATFORM
-- ---------------------------------------------------------------------
WITH first_txn AS (
  SELECT user_id, MIN(transaction_timestamp) AS first_txn_ts
  FROM clean_transactions WHERE status = 'success'
  GROUP BY user_id
)
SELECT
  u.platform,
  COUNT(DISTINCT u.user_id) AS signups,
  SUM(CASE WHEN ft.user_id IS NOT NULL THEN 1 ELSE 0 END) AS activated,
  ROUND(SUM(CASE WHEN ft.user_id IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(DISTINCT u.user_id), 1) AS activation_rate_pct
FROM clean_users u
LEFT JOIN first_txn ft ON ft.user_id = u.user_id
WHERE u.is_test_account = 0
  AND u.user_id IN (SELECT user_id FROM clean_events
                    WHERE event_name IN ('signup_complete','kyc_start','kyc_approved') AND is_suspected_bot = 0)
GROUP BY u.platform;

-- ---------------------------------------------------------------------
-- 4. MONTHLY SIGNUP COHORT RETENTION (M0-M6)
-- "Retained" = at least one home_view (or any event) in that relative month
-- ---------------------------------------------------------------------
WITH cohort AS (
  SELECT user_id, DATE(signup_date, 'start of month') AS cohort_month
  FROM clean_users WHERE is_test_account = 0
),
activity AS (
  SELECT e.user_id,
         c.cohort_month,
         -- calendar-month offset (NOT days / 30: that mislabels any span crossing February)
         (CAST(strftime('%Y', e.event_timestamp) AS INT) - CAST(strftime('%Y', c.cohort_month) AS INT)) * 12
       + (CAST(strftime('%m', e.event_timestamp) AS INT) - CAST(strftime('%m', c.cohort_month) AS INT)) AS month_offset
  FROM clean_events e
  JOIN cohort c ON c.user_id = e.user_id
  WHERE e.is_suspected_bot = 0
    -- complete months only: data ends 2026-07-15, so July 2026 is a partial month
    AND DATE(e.event_timestamp, 'start of month') <= '2026-06-01'
)
SELECT
  cohort_month,
  month_offset,
  COUNT(DISTINCT user_id) AS active_users
FROM activity
WHERE month_offset BETWEEN 0 AND 6
GROUP BY cohort_month, month_offset
ORDER BY cohort_month, month_offset;
-- Pivot this (cohort_month x month_offset) in Python/Power BI for the classic
-- retention triangle / heatmap view.

-- ---------------------------------------------------------------------
-- 5. FEATURE ADOPTION (among activated users)
-- ---------------------------------------------------------------------
WITH activated_users AS (
  SELECT DISTINCT user_id FROM clean_transactions WHERE status = 'success'
)
SELECT
  (SELECT COUNT(*) FROM activated_users) AS activated_user_base,
  COUNT(DISTINCT CASE WHEN t.transaction_type = 'p2p_transfer' THEN t.user_id END) AS used_send_money,
  COUNT(DISTINCT CASE WHEN t.transaction_type = 'bill_pay' THEN t.user_id END) AS used_bill_pay,
  COUNT(DISTINCT CASE WHEN t.transaction_type = 'cashback' THEN t.user_id END) AS used_cashback,
  ROUND(COUNT(DISTINCT CASE WHEN t.transaction_type = 'p2p_transfer' THEN t.user_id END) * 100.0 / (SELECT COUNT(*) FROM activated_users), 1) AS pct_send_money,
  ROUND(COUNT(DISTINCT CASE WHEN t.transaction_type = 'bill_pay' THEN t.user_id END) * 100.0 / (SELECT COUNT(*) FROM activated_users), 1) AS pct_bill_pay,
  ROUND(COUNT(DISTINCT CASE WHEN t.transaction_type = 'cashback' THEN t.user_id END) * 100.0 / (SELECT COUNT(*) FROM activated_users), 1) AS pct_cashback
FROM clean_transactions t
WHERE t.status = 'success';

-- ---------------------------------------------------------------------
-- 6. TIME-TO-ACTIVATION (days from signup to first successful transaction)
-- using window functions for a distribution view
-- ---------------------------------------------------------------------
WITH first_txn AS (
  SELECT user_id, MIN(transaction_timestamp) AS first_txn_ts
  FROM clean_transactions WHERE status = 'success'
  GROUP BY user_id
),
days_to_activate AS (
  SELECT
    u.user_id,
    CAST(JULIANDAY(ft.first_txn_ts) - JULIANDAY(u.signup_date) AS INT) AS days_to_activation
  FROM clean_users u
  JOIN first_txn ft ON ft.user_id = u.user_id
  WHERE u.is_test_account = 0
)
SELECT
  MIN(days_to_activation) AS min_days,
  ROUND(AVG(days_to_activation), 1) AS avg_days,
  (SELECT days_to_activation FROM days_to_activate ORDER BY days_to_activation
     LIMIT 1 OFFSET (SELECT COUNT(*) FROM days_to_activate) / 2) AS median_days,
  MAX(days_to_activation) AS max_days
FROM days_to_activate;
