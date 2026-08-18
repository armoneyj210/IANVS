-- ============================================================
-- JANUS
-- V011
-- Canonical Promotion Foundation
--
-- Goals:
--   1. Introduce an explicit canonical-promotion execution object.
--   2. Bind every promotion to:
--        Import Batch
--        Pre-canonical DQ Run
--        Quality Gate Decision
--        Mapping name/version
--        Runtime/version/git commit
--   3. Permit promotion only after an enterprise v2 quality PASS.
--   4. Remove record_lineage write authority from ETL.
--   5. Require all new lineage to belong to a promotion run.
--   6. Keep ETL, Quality, and Canonical services from writing
--      clinical tables directly.
--
-- Patient-specific clinical writes are intentionally NOT
-- implemented here. They will be introduced in V012 after this
-- generic control plane is tested.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. CANONICAL PROMOTION RUN
-- ============================================================

CREATE TABLE ingest.canonical_promotion_run (
    canonical_promotion_run_id UUID PRIMARY KEY
        DEFAULT gen_random_uuid(),

    import_batch_id UUID NOT NULL
        REFERENCES ingest.import_batch(import_batch_id),

    data_quality_run_id UUID NOT NULL
        REFERENCES ingest.data_quality_run(data_quality_run_id),

    quality_gate_decision_id UUID NOT NULL
        REFERENCES ingest.quality_gate_decision(
            quality_gate_decision_id
        ),

    mapping_name TEXT NOT NULL,
    mapping_version TEXT NOT NULL,

    environment TEXT NOT NULL,

    service_name TEXT NOT NULL,
    service_version TEXT NOT NULL,
    git_commit_sha TEXT,

    status TEXT NOT NULL
        CHECK (
            status IN (
                'running',
                'completed',
                'failed'
            )
        ),

    initiated_by TEXT NOT NULL,

    correlation_id UUID NOT NULL
        DEFAULT gen_random_uuid(),

    started_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,

    records_seen BIGINT NOT NULL DEFAULT 0
        CHECK (records_seen >= 0),

    records_created BIGINT NOT NULL DEFAULT 0
        CHECK (records_created >= 0),

    records_existing BIGINT NOT NULL DEFAULT 0
        CHECK (records_existing >= 0),

    records_failed BIGINT NOT NULL DEFAULT 0
        CHECK (records_failed >= 0),

    identifiers_created BIGINT NOT NULL DEFAULT 0
        CHECK (identifiers_created >= 0),

    metrics JSONB NOT NULL DEFAULT '{}'::jsonb,

    error_summary JSONB,

    created_at TIMESTAMPTZ NOT NULL
        DEFAULT clock_timestamp(),

    CONSTRAINT canonical_promotion_terminal_time_ck
        CHECK (
            (
                status = 'running'
                AND completed_at IS NULL
            )
            OR
            (
                status IN ('completed', 'failed')
                AND completed_at IS NOT NULL
            )
        ),

    CONSTRAINT canonical_promotion_counter_ck
        CHECK (
            records_seen =
                records_created
                + records_existing
                + records_failed
        )
);


COMMENT ON TABLE ingest.canonical_promotion_run IS
'Governed execution record for promotion of quality-certified source records into canonical clinical state.';


COMMENT ON COLUMN
    ingest.canonical_promotion_run.data_quality_run_id IS
'Pre-canonical quality run that authorized this promotion.';


COMMENT ON COLUMN
    ingest.canonical_promotion_run.quality_gate_decision_id IS
'Exact quality PASS decision used to authorize this promotion.';


COMMENT ON COLUMN
    ingest.canonical_promotion_run.mapping_version IS
'Version of the deterministic canonical mapping contract.';


-- Only one active execution for one mapping contract.
CREATE UNIQUE INDEX
    ux_canonical_promotion_active
ON ingest.canonical_promotion_run (
    import_batch_id,
    mapping_name,
    mapping_version
)
WHERE status = 'running';


-- One successful execution of a specific mapping contract.
-- Failed runs may be retried.
CREATE UNIQUE INDEX
    ux_canonical_promotion_completed
ON ingest.canonical_promotion_run (
    import_batch_id,
    mapping_name,
    mapping_version
)
WHERE status = 'completed';


CREATE INDEX
    ix_canonical_promotion_import_batch
ON ingest.canonical_promotion_run (
    import_batch_id,
    created_at
);


CREATE INDEX
    ix_canonical_promotion_quality_run
ON ingest.canonical_promotion_run (
    data_quality_run_id
);


-- ============================================================
-- 2. PROMOTION RUN LIFECYCLE HARDENING
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.enforce_canonical_promotion_run_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Terminal promotion history is immutable.
    IF OLD.status <> 'running' THEN
        RAISE EXCEPTION
            'Terminal canonical promotion run % is immutable',
            OLD.canonical_promotion_run_id
            USING ERRCODE = '42501';
    END IF;


    -- Authorization/provenance identity may never change.
    IF NEW.canonical_promotion_run_id
            IS DISTINCT FROM OLD.canonical_promotion_run_id
       OR NEW.import_batch_id
            IS DISTINCT FROM OLD.import_batch_id
       OR NEW.data_quality_run_id
            IS DISTINCT FROM OLD.data_quality_run_id
       OR NEW.quality_gate_decision_id
            IS DISTINCT FROM OLD.quality_gate_decision_id
       OR NEW.mapping_name
            IS DISTINCT FROM OLD.mapping_name
       OR NEW.mapping_version
            IS DISTINCT FROM OLD.mapping_version
       OR NEW.environment
            IS DISTINCT FROM OLD.environment
       OR NEW.service_name
            IS DISTINCT FROM OLD.service_name
       OR NEW.service_version
            IS DISTINCT FROM OLD.service_version
       OR NEW.git_commit_sha
            IS DISTINCT FROM OLD.git_commit_sha
       OR NEW.initiated_by
            IS DISTINCT FROM OLD.initiated_by
       OR NEW.correlation_id
            IS DISTINCT FROM OLD.correlation_id
       OR NEW.started_at
            IS DISTINCT FROM OLD.started_at
       OR NEW.created_at
            IS DISTINCT FROM OLD.created_at
    THEN
        RAISE EXCEPTION
            'Canonical promotion authorization/provenance fields are immutable'
            USING ERRCODE = '42501';
    END IF;


    -- This table is not a mutable progress ledger.
    -- A running record transitions exactly once to a terminal
    -- state.
    IF NEW.status = 'running' THEN
        RAISE EXCEPTION
            'Canonical promotion lifecycle update must terminate the run'
            USING ERRCODE = '42501';
    END IF;


    IF NEW.status = 'completed' THEN

        IF NEW.completed_at IS NULL THEN
            RAISE EXCEPTION
                'Completed canonical promotion requires completed_at';
        END IF;

        IF NEW.error_summary IS NOT NULL THEN
            RAISE EXCEPTION
                'Completed canonical promotion cannot contain error_summary';
        END IF;

        IF NEW.records_failed <> 0 THEN
            RAISE EXCEPTION
                'Canonical promotion with failed records cannot complete';
        END IF;

        IF NEW.records_seen <= 0 THEN
            RAISE EXCEPTION
                'Completed canonical promotion must evaluate at least one source record';
        END IF;

    ELSIF NEW.status = 'failed' THEN

        IF NEW.completed_at IS NULL THEN
            RAISE EXCEPTION
                'Failed canonical promotion requires completed_at';
        END IF;

        IF NEW.error_summary IS NULL THEN
            RAISE EXCEPTION
                'Failed canonical promotion requires error_summary';
        END IF;

    ELSE
        RAISE EXCEPTION
            'Invalid canonical promotion transition';
    END IF;


    RETURN NEW;

END;
$$;


CREATE TRIGGER
    trg_canonical_promotion_run_update
BEFORE UPDATE
ON ingest.canonical_promotion_run
FOR EACH ROW
EXECUTE FUNCTION
    ingest.enforce_canonical_promotion_run_update();


CREATE OR REPLACE FUNCTION
ingest.reject_canonical_promotion_history_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'Canonical promotion history is append-oriented and cannot be deleted or truncated'
        USING ERRCODE = '42501';
END;
$$;


CREATE TRIGGER
    trg_canonical_promotion_run_delete
BEFORE DELETE
ON ingest.canonical_promotion_run
FOR EACH ROW
EXECUTE FUNCTION
    ingest.reject_canonical_promotion_history_change();


CREATE TRIGGER
    trg_canonical_promotion_run_truncate
BEFORE TRUNCATE
ON ingest.canonical_promotion_run
FOR EACH STATEMENT
EXECUTE FUNCTION
    ingest.reject_canonical_promotion_history_change();


-- ============================================================
-- 3. MAKE RECORD_LINEAGE CANONICAL-PROMOTION AWARE
--
-- We intentionally fail the migration if lineage already exists.
-- At the current Janus checkpoint there should be zero lineage
-- rows because canonical promotion has not begun.
--
-- Silently assigning historical lineage to an invented promotion
-- would corrupt provenance.
-- ============================================================

LOCK TABLE ingest.record_lineage
IN ACCESS EXCLUSIVE MODE;


DO $$
BEGIN

    IF EXISTS (
        SELECT 1
        FROM ingest.record_lineage
        LIMIT 1
    ) THEN
        RAISE EXCEPTION
            'V011 requires ingest.record_lineage to be empty before canonical promotion begins';
    END IF;

END;
$$;


ALTER TABLE ingest.record_lineage
ADD COLUMN canonical_promotion_run_id UUID;


ALTER TABLE ingest.record_lineage
ADD CONSTRAINT
    record_lineage_canonical_promotion_run_fk
FOREIGN KEY (canonical_promotion_run_id)
REFERENCES ingest.canonical_promotion_run(
    canonical_promotion_run_id
);


-- Every lineage edge created from this point forward must carry
-- both a promotion run and a mapping version.
ALTER TABLE ingest.record_lineage
ALTER COLUMN canonical_promotion_run_id SET NOT NULL;


ALTER TABLE ingest.record_lineage
ALTER COLUMN mapping_version SET NOT NULL;


CREATE INDEX
    ix_record_lineage_canonical_promotion
ON ingest.record_lineage (
    canonical_promotion_run_id
);


-- ============================================================
-- 4. LINEAGE INSERT INTEGRITY
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.enforce_record_lineage_promotion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_import_batch_id UUID;
    v_run_mapping_version TEXT;
    v_run_status TEXT;

    v_source_import_batch_id UUID;
    v_source_record_status TEXT;
BEGIN

    SELECT
        import_batch_id,
        mapping_version,
        status
    INTO
        v_run_import_batch_id,
        v_run_mapping_version,
        v_run_status
    FROM ingest.canonical_promotion_run
    WHERE canonical_promotion_run_id =
          NEW.canonical_promotion_run_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown canonical promotion run: %',
            NEW.canonical_promotion_run_id;
    END IF;


    IF v_run_status <> 'running' THEN
        RAISE EXCEPTION
            'Lineage may only be written during a running canonical promotion'
            USING ERRCODE = '42501';
    END IF;


    SELECT
        import_batch_id,
        record_status
    INTO
        v_source_import_batch_id,
        v_source_record_status
    FROM ingest.source_record
    WHERE source_record_id =
          NEW.source_record_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown source record: %',
            NEW.source_record_id;
    END IF;


    IF v_source_import_batch_id
        IS DISTINCT FROM v_run_import_batch_id
    THEN
        RAISE EXCEPTION
            'Source record does not belong to the canonical promotion import batch'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_record_status <> 'accepted' THEN
        RAISE EXCEPTION
            'Only accepted source records may be promoted; source record % has status %',
            NEW.source_record_id,
            v_source_record_status
            USING ERRCODE = '42501';
    END IF;


    IF NEW.mapping_version
        IS DISTINCT FROM v_run_mapping_version
    THEN
        RAISE EXCEPTION
            'Lineage mapping version must match its canonical promotion run'
            USING ERRCODE = '42501';
    END IF;


    IF NEW.target_record_id IS NULL THEN
        RAISE EXCEPTION
            'Canonical lineage requires a target_record_id';
    END IF;


    RETURN NEW;

END;
$$;


CREATE TRIGGER
    trg_record_lineage_promotion
BEFORE INSERT
ON ingest.record_lineage
FOR EACH ROW
EXECUTE FUNCTION
    ingest.enforce_record_lineage_promotion();


-- Lineage itself is append-only evidence.
CREATE OR REPLACE FUNCTION
ingest.reject_record_lineage_history_change()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION
        'Canonical record lineage is append-only'
        USING ERRCODE = '42501';
END;
$$;


CREATE TRIGGER
    trg_record_lineage_update
BEFORE UPDATE
ON ingest.record_lineage
FOR EACH ROW
EXECUTE FUNCTION
    ingest.reject_record_lineage_history_change();


CREATE TRIGGER
    trg_record_lineage_delete
BEFORE DELETE
ON ingest.record_lineage
FOR EACH ROW
EXECUTE FUNCTION
    ingest.reject_record_lineage_history_change();


CREATE TRIGGER
    trg_record_lineage_truncate
BEFORE TRUNCATE
ON ingest.record_lineage
FOR EACH STATEMENT
EXECUTE FUNCTION
    ingest.reject_record_lineage_history_change();


-- ============================================================
-- 5. BEGIN CANONICAL PROMOTION
--
-- This is the authorization boundary.
--
-- It does NOT write clinical data.
-- It proves that a canonical runtime is permitted to begin.
-- ============================================================

CREATE OR REPLACE FUNCTION ingest.begin_canonical_promotion(
    p_import_batch_id UUID,
    p_mapping_name TEXT,
    p_mapping_version TEXT,
    p_service_version TEXT,
    p_git_commit_sha TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest
AS $$
DECLARE
    v_promotion_run_id UUID;

    v_import_status TEXT;
    v_import_environment TEXT;
    v_records_seen BIGINT;
    v_records_accepted BIGINT;
    v_records_rejected BIGINT;

    v_source_record_count BIGINT;
    v_quarantined_source_count BIGINT;

    v_data_quality_run_id UUID;
    v_quality_gate_decision_id UUID;

    v_environment TEXT;
    v_service_name TEXT;
BEGIN

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Canonical promotion may only be initiated by janus_canonical_svc'
            USING ERRCODE = '42501';
    END IF;


    IF NULLIF(btrim(p_mapping_name), '') IS NULL THEN
        RAISE EXCEPTION
            'Canonical mapping name is required';
    END IF;


    IF NULLIF(btrim(p_mapping_version), '') IS NULL THEN
        RAISE EXCEPTION
            'Canonical mapping version is required';
    END IF;


    IF NULLIF(btrim(p_service_version), '') IS NULL THEN
        RAISE EXCEPTION
            'Canonical service version is required';
    END IF;


    SELECT
        status,
        environment,
        records_seen,
        records_accepted,
        records_rejected
    INTO
        v_import_status,
        v_import_environment,
        v_records_seen,
        v_records_accepted,
        v_records_rejected
    FROM ingest.import_batch
    WHERE import_batch_id =
          p_import_batch_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown import batch: %',
            p_import_batch_id;
    END IF;


    IF v_import_status <> 'completed' THEN
        RAISE EXCEPTION
            'Canonical promotion requires a completed import batch'
            USING ERRCODE = '42501';
    END IF;


    IF v_records_seen
        IS DISTINCT FROM v_records_accepted
       OR COALESCE(v_records_rejected, 0) <> 0
    THEN
        RAISE EXCEPTION
            'Import batch counters do not authorize canonical promotion'
            USING ERRCODE = '42501';
    END IF;


    SELECT COUNT(*)
    INTO v_source_record_count
    FROM ingest.source_record
    WHERE import_batch_id =
          p_import_batch_id;


    IF v_source_record_count
        IS DISTINCT FROM v_records_seen
    THEN
        RAISE EXCEPTION
            'Persisted source-record count does not match completed import batch'
            USING ERRCODE = '42501';
    END IF;


    SELECT COUNT(*)
    INTO v_quarantined_source_count
    FROM ingest.source_record
    WHERE import_batch_id =
          p_import_batch_id
      AND record_status = 'quarantined';


    IF v_quarantined_source_count <> 0 THEN
        RAISE EXCEPTION
            'Canonical promotion is forbidden while source records are quarantined'
            USING ERRCODE = '42501';
    END IF;


    -- V010 already pins the exact enterprise trust contract:
    -- janus-precanonical v2
    -- completed
    -- five rules
    -- zero quarantined
    -- PASS
    -- decided_by janus_quality_svc.
    SELECT
        data_quality_run_id,
        quality_gate_decision_id
    INTO
        v_data_quality_run_id,
        v_quality_gate_decision_id
    FROM ingest.v_quality_gate_effective_status
    WHERE import_batch_id =
          p_import_batch_id
      AND gate_allows_promotion IS TRUE
    ORDER BY
        gate_decided_at DESC,
        data_quality_run_id DESC
    LIMIT 1;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'No enterprise-authorized pre-canonical quality PASS exists for import batch %',
            p_import_batch_id
            USING ERRCODE = '42501';
    END IF;


    IF EXISTS (
        SELECT 1
        FROM ingest.canonical_promotion_run
        WHERE import_batch_id =
              p_import_batch_id
          AND mapping_name =
              p_mapping_name
          AND mapping_version =
              p_mapping_version
          AND status IN (
              'running',
              'completed'
          )
    ) THEN
        RAISE EXCEPTION
            'Canonical promotion already exists for import batch %, mapping % v%',
            p_import_batch_id,
            p_mapping_name,
            p_mapping_version;
    END IF;


    v_environment :=
        current_setting(
            'janus.environment',
            true
        );


    IF v_environment IS NULL
       OR v_environment NOT IN (
           'development',
           'test',
           'staging',
           'production'
       )
    THEN
        RAISE EXCEPTION
            'janus.environment must be set before canonical promotion';
    END IF;


    IF v_environment <> v_import_environment THEN
        RAISE EXCEPTION
            'Canonical environment % does not match import environment %',
            v_environment,
            v_import_environment
            USING ERRCODE = '42501';
    END IF;


    v_service_name :=
        NULLIF(
            current_setting(
                'application_name',
                true
            ),
            ''
        );


    IF v_service_name IS NULL THEN
        v_service_name :=
            'janus-canonical';
    END IF;


    INSERT INTO ingest.canonical_promotion_run (
        import_batch_id,
        data_quality_run_id,
        quality_gate_decision_id,
        mapping_name,
        mapping_version,
        environment,
        service_name,
        service_version,
        git_commit_sha,
        status,
        initiated_by,
        started_at
    )
    VALUES (
        p_import_batch_id,
        v_data_quality_run_id,
        v_quality_gate_decision_id,
        btrim(p_mapping_name),
        btrim(p_mapping_version),
        v_environment,
        v_service_name,
        btrim(p_service_version),
        NULLIF(btrim(p_git_commit_sha), ''),
        'running',
        session_user::TEXT,
        clock_timestamp()
    )
    RETURNING canonical_promotion_run_id
    INTO v_promotion_run_id;


    RETURN v_promotion_run_id;

END;
$$;


-- ============================================================
-- 6. COMPLETE CANONICAL PROMOTION
--
-- Re-check the exact quality authorization at completion so a
-- promotion cannot finish after its authorization is no longer
-- effective.
-- ============================================================

CREATE OR REPLACE FUNCTION ingest.complete_canonical_promotion(
    p_canonical_promotion_run_id UUID,
    p_records_seen BIGINT,
    p_records_created BIGINT,
    p_records_existing BIGINT,
    p_records_failed BIGINT,
    p_identifiers_created BIGINT,
    p_metrics JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest
AS $$
DECLARE
    v_data_quality_run_id UUID;
    v_quality_gate_decision_id UUID;
    v_status TEXT;
BEGIN

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Canonical promotion may only be completed by janus_canonical_svc'
            USING ERRCODE = '42501';
    END IF;


    IF p_records_seen <= 0 THEN
        RAISE EXCEPTION
            'Completed canonical promotion must evaluate at least one source record';
    END IF;


    IF p_records_created < 0
       OR p_records_existing < 0
       OR p_records_failed < 0
       OR p_identifiers_created < 0
    THEN
        RAISE EXCEPTION
            'Canonical promotion counters cannot be negative';
    END IF;


    IF p_records_seen
        <> (
            p_records_created
            + p_records_existing
            + p_records_failed
        )
    THEN
        RAISE EXCEPTION
            'Canonical promotion source counters do not reconcile';
    END IF;


    IF p_records_failed <> 0 THEN
        RAISE EXCEPTION
            'Canonical promotion with failed records must fail closed';
    END IF;


    SELECT
        data_quality_run_id,
        quality_gate_decision_id,
        status
    INTO
        v_data_quality_run_id,
        v_quality_gate_decision_id,
        v_status
    FROM ingest.canonical_promotion_run
    WHERE canonical_promotion_run_id =
          p_canonical_promotion_run_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown canonical promotion run: %',
            p_canonical_promotion_run_id;
    END IF;


    IF v_status <> 'running' THEN
        RAISE EXCEPTION
            'Canonical promotion run is not running'
            USING ERRCODE = '42501';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM ingest.v_quality_gate_effective_status
        WHERE data_quality_run_id =
              v_data_quality_run_id
          AND quality_gate_decision_id =
              v_quality_gate_decision_id
          AND gate_allows_promotion IS TRUE
    ) THEN
        RAISE EXCEPTION
            'Canonical promotion quality authorization is no longer effective'
            USING ERRCODE = '42501';
    END IF;


    UPDATE ingest.canonical_promotion_run
    SET
        status = 'completed',
        completed_at = clock_timestamp(),
        records_seen = p_records_seen,
        records_created = p_records_created,
        records_existing = p_records_existing,
        records_failed = p_records_failed,
        identifiers_created =
            p_identifiers_created,
        metrics =
            COALESCE(
                p_metrics,
                '{}'::jsonb
            ),
        error_summary = NULL
    WHERE canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND status = 'running';


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Canonical promotion run could not be completed';
    END IF;


    RETURN p_canonical_promotion_run_id;

END;
$$;


-- ============================================================
-- 7. FAIL CANONICAL PROMOTION
-- ============================================================

CREATE OR REPLACE FUNCTION ingest.fail_canonical_promotion(
    p_canonical_promotion_run_id UUID,
    p_error_summary JSONB,
    p_metrics JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest
AS $$
BEGIN

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Canonical promotion may only be failed by janus_canonical_svc'
            USING ERRCODE = '42501';
    END IF;


    IF p_error_summary IS NULL
       OR p_error_summary = '{}'::jsonb
    THEN
        RAISE EXCEPTION
            'Failed canonical promotion requires error evidence';
    END IF;


    UPDATE ingest.canonical_promotion_run
    SET
        status = 'failed',
        completed_at = clock_timestamp(),
        metrics =
            COALESCE(
                p_metrics,
                '{}'::jsonb
            ),
        error_summary =
            p_error_summary
    WHERE canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND status = 'running';


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Canonical promotion run is missing or no longer running';
    END IF;


    RETURN p_canonical_promotion_run_id;

END;
$$;


-- ============================================================
-- 8. READ-ONLY PROMOTION STATUS VIEW
-- ============================================================

CREATE OR REPLACE VIEW
ingest.v_canonical_promotion_status
AS
SELECT
    cpr.canonical_promotion_run_id,
    cpr.import_batch_id,
    cpr.data_quality_run_id,
    cpr.quality_gate_decision_id,

    cpr.mapping_name,
    cpr.mapping_version,

    cpr.environment,
    cpr.service_name,
    cpr.service_version,
    cpr.git_commit_sha,

    cpr.status,
    cpr.initiated_by,
    cpr.correlation_id,

    cpr.started_at,
    cpr.completed_at,

    cpr.records_seen,
    cpr.records_created,
    cpr.records_existing,
    cpr.records_failed,
    cpr.identifiers_created,

    cpr.metrics,
    cpr.error_summary,

    q.latest_gate_decision,
    q.decided_by AS quality_decided_by,
    q.gate_allows_promotion

FROM ingest.canonical_promotion_run cpr

LEFT JOIN ingest.v_quality_gate_effective_status q
  ON q.data_quality_run_id =
     cpr.data_quality_run_id
 AND q.quality_gate_decision_id =
     cpr.quality_gate_decision_id;


-- ============================================================
-- 9. PRIVILEGE HARDENING
-- ============================================================

REVOKE ALL
ON ingest.canonical_promotion_run
FROM PUBLIC, janus_ingest_rw, janus_etl_svc;


REVOKE ALL
ON ingest.v_canonical_promotion_status
FROM PUBLIC, janus_ingest_rw, janus_etl_svc;


-- Historical lineage was originally part of the broad ingest
-- write capability. Canonical authority now owns this boundary.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ingest.record_lineage
FROM
    janus_ingest_rw,
    janus_etl_svc,
    janus_quality_svc;


-- Controlled functions are default deny.
REVOKE ALL
ON FUNCTION ingest.begin_canonical_promotion(
    UUID, TEXT, TEXT, TEXT, TEXT
)
FROM PUBLIC;


REVOKE ALL
ON FUNCTION ingest.complete_canonical_promotion(
    UUID, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB
)
FROM PUBLIC;


REVOKE ALL
ON FUNCTION ingest.fail_canonical_promotion(
    UUID, JSONB, JSONB
)
FROM PUBLIC;


COMMENT ON FUNCTION ingest.begin_canonical_promotion(
    UUID, TEXT, TEXT, TEXT, TEXT
) IS
'Authorizes a canonical promotion only after independently verifying the completed import and V010 enterprise quality gate.';


COMMENT ON FUNCTION ingest.complete_canonical_promotion(
    UUID, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB
) IS
'Terminates a canonical promotion successfully after counter reconciliation and revalidation of the exact quality authorization.';


COMMENT ON FUNCTION ingest.fail_canonical_promotion(
    UUID, JSONB, JSONB
) IS
'Fails a running canonical promotion closed with structured error evidence.';


RESET ROLE;