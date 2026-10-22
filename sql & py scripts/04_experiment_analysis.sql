-- =====================================================================
-- 04_experiment_analysis.sql
-- RiyalPay — exp_kyc_streamline_2026: assignment integrity + outcome pull
-- Run against: riyalpay.db (clean_* tables)
-- NOTE: this script prepares the aggregates; the actual significance test,
-- confidence intervals, and power analysis are done in Python (rate ratios
-- alone don't tell you if a result is statistically meaningful) — see the
-- companion notebook.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. SAMPLE RATIO MISMATCH (SRM) CHECK — the first thing to check, always,
-- before trusting any experiment readout
-- ---------------------------------------------------------------------
SELECT platform, variant, COUNT(*) AS n_users
FROM clean_experiment_assignments
WHERE is_contaminated = 0
GROUP BY platform, variant
ORDER BY platform, variant;
-- Expect: iOS close to 50/50, Android meaningfully skewed. This alone
-- disqualifies a naive pooled readout of the experiment.

-- ---------------------------------------------------------------------
-- 2. CONTAMINATION SUMMARY
-- ---------------------------------------------------------------------
SELECT
  COUNT(*) AS total_assigned_users,
  SUM(is_contaminated) AS contaminated_users,
  ROUND(SUM(is_contaminated) * 100.0 / COUNT(*), 2) AS pct_contaminated
FROM clean_experiment_assignments;

-- ---------------------------------------------------------------------
-- 3. PRIMARY OUTCOME BY ARM: KYC approval rate
-- (excludes contaminated users; this is the "intent-to-treat" style pull —
-- every assigned, non-contaminated user counted whether or not they
-- actually completed the flow)
-- ---------------------------------------------------------------------
WITH kyc_outcome AS (
  SELECT user_id, MAX(CASE WHEN event_name = 'kyc_approved' THEN 1 ELSE 0 END) AS approved
  FROM clean_events
  WHERE is_suspected_bot = 0
  GROUP BY user_id
)
SELECT
  ea.platform,
  ea.variant,
  COUNT(*) AS n_assigned,
  SUM(COALESCE(k.approved, 0)) AS n_approved,
  ROUND(SUM(COALESCE(k.approved, 0)) * 100.0 / COUNT(*), 2) AS approval_rate_pct
FROM clean_experiment_assignments ea
LEFT JOIN kyc_outcome k ON k.user_id = ea.user_id
WHERE ea.is_contaminated = 0
GROUP BY ea.platform, ea.variant
ORDER BY ea.platform, ea.variant;

-- ---------------------------------------------------------------------
-- 4. SECONDARY OUTCOME BY ARM: downstream activation rate
-- (did the KYC change actually move the metric leadership cares about?)
-- ---------------------------------------------------------------------
WITH activated AS (
  SELECT DISTINCT user_id FROM clean_transactions WHERE status = 'success'
)
SELECT
  ea.platform,
  ea.variant,
  COUNT(*) AS n_assigned,
  COUNT(a.user_id) AS n_activated,
  ROUND(COUNT(a.user_id) * 100.0 / COUNT(*), 2) AS activation_rate_pct
FROM clean_experiment_assignments ea
LEFT JOIN activated a ON a.user_id = ea.user_id
WHERE ea.is_contaminated = 0
GROUP BY ea.platform, ea.variant
ORDER BY ea.platform, ea.variant;

-- ---------------------------------------------------------------------
-- 5. WEEKLY KYC-APPROVAL RATE BY ARM (to check for a novelty effect —
-- does the treatment's lift shrink over the 6-week window?)
-- ---------------------------------------------------------------------
WITH kyc_outcome AS (
  SELECT user_id, MIN(CASE WHEN event_name = 'kyc_approved' THEN event_timestamp END) AS approved_ts
  FROM clean_events
  WHERE is_suspected_bot = 0
  GROUP BY user_id
)
SELECT
  ea.variant,
  CAST(((JULIANDAY(ea.assignment_date) - JULIANDAY('2026-02-02')) / 7) AS INT) + 1 AS experiment_week,
  COUNT(*) AS n_assigned,
  SUM(CASE WHEN k.approved_ts IS NOT NULL THEN 1 ELSE 0 END) AS n_approved,
  ROUND(SUM(CASE WHEN k.approved_ts IS NOT NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS approval_rate_pct
FROM clean_experiment_assignments ea
LEFT JOIN kyc_outcome k ON k.user_id = ea.user_id
WHERE ea.is_contaminated = 0
GROUP BY ea.variant, experiment_week
ORDER BY experiment_week, ea.variant;
