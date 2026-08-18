-- ============================================================
-- JANUS
-- V010
-- Separate Quality Authority and Enforce Canonical Boundary
--
-- This migration is forward-only. V006-V009 remain unchanged.
--
-- Goals:
--   1. Remove DQ certification authority from janus_etl_svc.
--   2. Harden imported source records against post-import ETL
--      mutation.
--   3. Create a controlled automatic PASS/FAIL gate writer for
--      janus_quality_svc only.
--   4. Make the enterprise pre-canonical trust contract v2.
--   5. Keep override_pass / override_fail deny-by-default.
--   6. Expose a read-only effective gate status for the future
--      canonical loader.
--
-- Cluster role creation/membership/grants are intentionally
-- handled by db/security/010_canonical_boundary_access.sql.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. REMOVE QUALITY CERTIFICATION FROM THE INGEST CAPABILITY
-- ============================================================

REVOKE ALL
ON
    ingest.data_quality_rule,
    ingest.data_quality_run,
    ingest.data_quality_result,
    ingest.quarantine_record,
    ingest.quality_gate_decision
FROM janus_ingest_rw;


-- validation_issue remains SELECT/INSERT-capable for ETL because
-- ingestion validation evidence is broader than the DQ engine.
-- V009 already prevents ETL from rewriting historical issues.


-- Imported source facts may be created by ETL, but after import
-- ETL must not mutate record state, hashes, keys, or locators.
REVOKE UPDATE, DELETE, TRUNCATE
ON ingest.source_record
FROM janus_ingest_rw;

GRANT SELECT, INSERT
ON ingest.source_record
TO janus_ingest_rw;


-- Defense in depth against accidental direct grants.
REVOKE ALL
ON
    ingest.data_quality_rule,
    ingest.data_quality_run,
    ingest.data_quality_result,
    ingest.quarantine_record,
    ingest.quality_gate_decision
FROM janus_etl_svc;

REVOKE UPDATE, DELETE, TRUNCATE
ON ingest.source_record
FROM janus_etl_svc;


-- Future ingest tables are now default read-only to the broad
-- ingest capability. New write surfaces must be granted
-- explicitly by a later migration/security bootstrap.
ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA ingest
REVOKE INSERT, UPDATE
ON TABLES
FROM janus_ingest_rw;


-- ============================================================
-- 2. CONTROLLED AUTOMATIC QUALITY-GATE WRITER
--
-- Enterprise pre-canonical trust contract:
--   ruleset: janus-precanonical
--   ruleset version: 2
--   DQ rules: JANUS-DQ-001 through JANUS-DQ-005, version 1
--
-- v2 changes the execution authority, not the five rule
-- definitions. Historical v1 runs remain immutable evidence.
-- ============================================================

CREATE OR REPLACE FUNCTION ingest.write_quality_gate_decision(
    p_data_quality_run_id UUID,
    p_decision TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest
AS $$
DECLARE
    v_decision_id UUID;

    v_status TEXT;
    v_ruleset_name TEXT;
    v_ruleset_version TEXT;
    v_rules_evaluated INTEGER;
    v_records_quarantined BIGINT;

    v_result_count BIGINT;
    v_expected_result_count BIGINT;
    v_blocking_failure BOOLEAN;

    v_reason TEXT;
BEGIN

    IF session_user::TEXT <> 'janus_quality_svc' THEN
        RAISE EXCEPTION
            'Automatic quality-gate decisions may only be written by janus_quality_svc'
            USING ERRCODE = '42501';
    END IF;


    IF p_decision NOT IN ('pass', 'fail') THEN
        RAISE EXCEPTION
            'Automatic quality-gate decision must be pass or fail, not %',
            p_decision
            USING ERRCODE = '42501';
    END IF;


    SELECT
        status,
        ruleset_name,
        ruleset_version,
        rules_evaluated,
        records_quarantined
    INTO
        v_status,
        v_ruleset_name,
        v_ruleset_version,
        v_rules_evaluated,
        v_records_quarantined
    FROM ingest.data_quality_run
    WHERE data_quality_run_id = p_data_quality_run_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown data quality run: %',
            p_data_quality_run_id;
    END IF;


    IF EXISTS (
        SELECT 1
        FROM ingest.quality_gate_decision
        WHERE data_quality_run_id = p_data_quality_run_id
          AND decision IN ('pass', 'fail')
    ) THEN
        RAISE EXCEPTION
            'Automatic quality-gate decision already exists for run %',
            p_data_quality_run_id;
    END IF;


    -- Runtime execution failure always fails closed.
    IF v_status = 'failed' THEN

        IF p_decision <> 'fail' THEN
            RAISE EXCEPTION
                'Failed data-quality run % may only receive a fail decision',
                p_data_quality_run_id
                USING ERRCODE = '42501';
        END IF;


    ELSIF v_status = 'completed' THEN

        IF v_ruleset_name IS DISTINCT FROM 'janus-precanonical'
           OR v_ruleset_version IS DISTINCT FROM '2'
           OR v_rules_evaluated IS DISTINCT FROM 5
        THEN
            RAISE EXCEPTION
                'Data-quality run % does not match the authorized pre-canonical v2 contract',
                p_data_quality_run_id
                USING ERRCODE = '42501';
        END IF;


        SELECT
            COUNT(*),
            COUNT(*) FILTER (
                WHERE q.rule_version = 1
                  AND q.rule_code IN (
                      'JANUS-DQ-001',
                      'JANUS-DQ-002',
                      'JANUS-DQ-003',
                      'JANUS-DQ-004',
                      'JANUS-DQ-005'
                  )
            ),
            COALESCE(
                BOOL_OR(
                    q.blocking
                    AND r.outcome IN ('fail', 'error')
                ),
                FALSE
            )
        INTO
            v_result_count,
            v_expected_result_count,
            v_blocking_failure
        FROM ingest.data_quality_result r
        JOIN ingest.data_quality_rule q
          ON q.data_quality_rule_id =
             r.data_quality_rule_id
        WHERE r.data_quality_run_id =
              p_data_quality_run_id;


        IF v_result_count <> 5
           OR v_expected_result_count <> 5
        THEN
            RAISE EXCEPTION
                'Data-quality run % must contain exactly the five authorized pre-canonical v1 rule results',
                p_data_quality_run_id
                USING ERRCODE = '42501';
        END IF;


        IF p_decision = 'pass'
           AND (
               v_blocking_failure
               OR COALESCE(v_records_quarantined, 0) > 0
           )
        THEN
            RAISE EXCEPTION
                'Data-quality run % contains blocking failures or quarantined records and cannot pass',
                p_data_quality_run_id
                USING ERRCODE = '42501';
        END IF;


        IF p_decision = 'fail'
           AND NOT v_blocking_failure
           AND COALESCE(v_records_quarantined, 0) = 0
        THEN
            RAISE EXCEPTION
                'Data-quality run % contains no blocking failure and cannot receive an automatic fail decision',
                p_data_quality_run_id
                USING ERRCODE = '42501';
        END IF;


    ELSE

        RAISE EXCEPTION
            'Data-quality run % is not terminal; current status is %',
            p_data_quality_run_id,
            v_status
            USING ERRCODE = '42501';

    END IF;


    v_reason := NULLIF(btrim(p_reason), '');

    IF v_reason IS NULL THEN
        v_reason := CASE
            WHEN p_decision = 'pass'
            THEN
                'All pre-canonical blocking quality rules passed under the v2 quality-authority contract. Non-blocking warnings may remain.'
            ELSE
                'Pre-canonical quality evaluation failed closed under the v2 quality-authority contract.'
        END;
    END IF;


    INSERT INTO ingest.quality_gate_decision (
        data_quality_run_id,
        decision,
        decided_by,
        decision_reason
    )
    VALUES (
        p_data_quality_run_id,
        p_decision,
        session_user::TEXT,
        v_reason
    )
    RETURNING quality_gate_decision_id
    INTO v_decision_id;


    RETURN v_decision_id;

END;
$$;


REVOKE ALL
ON FUNCTION ingest.write_quality_gate_decision(
    UUID, TEXT, TEXT
)
FROM PUBLIC;


COMMENT ON FUNCTION ingest.write_quality_gate_decision(
    UUID, TEXT, TEXT
) IS
'Controlled automatic quality-gate writer for janus_quality_svc. Accepts pass/fail only and validates the janus-precanonical v2 persisted DQ contract before appending a decision.';


-- ============================================================
-- 3. EFFECTIVE ENTERPRISE QUALITY-GATE STATUS
--
-- Historical v1 ETL-certified runs remain visible but do not
-- authorize promotion after V010. The future canonical loader
-- must see a v2 PASS certified by janus_quality_svc.
-- ============================================================

CREATE OR REPLACE VIEW ingest.v_quality_gate_effective_status AS
SELECT
    r.data_quality_run_id,
    r.import_batch_id,
    r.status AS data_quality_run_status,
    r.ruleset_name,
    r.ruleset_version,
    r.rules_evaluated,
    r.rules_passed,
    r.rules_warned,
    r.rules_failed,
    r.records_evaluated,
    r.records_quarantined,

    latest.quality_gate_decision_id,
    latest.decision AS latest_gate_decision,
    latest.decided_by,
    latest.decision_reason,
    latest.created_at AS gate_decided_at,

    CASE
        WHEN r.status = 'completed'
         AND r.ruleset_name = 'janus-precanonical'
         AND r.ruleset_version = '2'
         AND r.rules_evaluated = 5
         AND COALESCE(r.records_quarantined, 0) = 0
         AND latest.decision = 'pass'
         AND latest.decided_by = 'janus_quality_svc'
        THEN TRUE
        ELSE FALSE
    END AS gate_allows_promotion

FROM ingest.data_quality_run r

LEFT JOIN LATERAL (
    SELECT
        q.quality_gate_decision_id,
        q.decision,
        q.decided_by,
        q.decision_reason,
        q.created_at
    FROM ingest.quality_gate_decision q
    WHERE q.data_quality_run_id =
          r.data_quality_run_id
    ORDER BY
        q.created_at DESC,
        q.quality_gate_decision_id DESC
    LIMIT 1
) latest ON TRUE;


REVOKE ALL
ON ingest.v_quality_gate_effective_status
FROM PUBLIC, janus_ingest_rw, janus_etl_svc;


COMMENT ON VIEW ingest.v_quality_gate_effective_status IS
'Effective enterprise quality-gate status. Only completed janus-precanonical v2 PASS decisions certified by janus_quality_svc authorize future canonical promotion.';


RESET ROLE;