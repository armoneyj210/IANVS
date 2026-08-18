-- ============================================================
-- JANUS
-- Security Bootstrap 011
-- Canonical Promotion Authority
--
-- Run as PostgreSQL bootstrap/admin AFTER Flyway V011.
--
-- Creates the dedicated Canonical service identity and assigns
-- only the minimum capabilities necessary to:
--   * verify governed ingest provenance,
--   * read quality authorization,
--   * execute controlled promotion lifecycle functions,
--   * emit system telemetry.
--
-- It receives NO direct clinical writes.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CANONICAL CAPABILITY + LOGIN
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'janus_canonical_runtime'
    ) THEN
        CREATE ROLE janus_canonical_runtime
            NOLOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'janus_canonical_svc'
    ) THEN
        CREATE ROLE janus_canonical_svc
            LOGIN
            INHERIT
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
    END IF;

END
$$;


GRANT janus_canonical_runtime
TO janus_canonical_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


GRANT CONNECT
ON DATABASE therapy
TO janus_canonical_svc;


-- ============================================================
-- 2. READ-ONLY GOVERNED INGEST EVIDENCE
-- ============================================================

GRANT USAGE
ON SCHEMA ingest
TO janus_canonical_runtime;


GRANT SELECT
ON
    ingest.source_system,
    ingest.dataset,
    ingest.dataset_release,
    ingest.source_file,
    ingest.import_batch,
    ingest.source_record,
    ingest.data_quality_run,
    ingest.quality_gate_decision,
    ingest.v_quality_gate_effective_status,
    ingest.canonical_promotion_run,
    ingest.v_canonical_promotion_status,
    ingest.record_lineage
TO janus_canonical_runtime;


-- No direct control-plane writes.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON
    ingest.canonical_promotion_run,
    ingest.record_lineage,
    ingest.data_quality_run,
    ingest.quality_gate_decision
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


-- ============================================================
-- 3. CONTROLLED PROMOTION LIFECYCLE
-- ============================================================

GRANT EXECUTE
ON FUNCTION ingest.begin_canonical_promotion(
    UUID, TEXT, TEXT, TEXT, TEXT
)
TO janus_canonical_runtime;


GRANT EXECUTE
ON FUNCTION ingest.complete_canonical_promotion(
    UUID, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB
)
TO janus_canonical_runtime;


GRANT EXECUTE
ON FUNCTION ingest.fail_canonical_promotion(
    UUID, JSONB, JSONB
)
TO janus_canonical_runtime;


-- Explicit defense in depth:
-- ETL and Quality cannot invoke canonical authority.
REVOKE EXECUTE
ON FUNCTION ingest.begin_canonical_promotion(
    UUID, TEXT, TEXT, TEXT, TEXT
)
FROM
    janus_etl_svc,
    janus_quality_svc;


REVOKE EXECUTE
ON FUNCTION ingest.complete_canonical_promotion(
    UUID, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB
)
FROM
    janus_etl_svc,
    janus_quality_svc;


REVOKE EXECUTE
ON FUNCTION ingest.fail_canonical_promotion(
    UUID, JSONB, JSONB
)
FROM
    janus_etl_svc,
    janus_quality_svc;


-- ============================================================
-- 4. NO DIRECT CLINICAL AUTHORITY
--
-- V012 will introduce narrowly controlled SECURITY DEFINER
-- patient promotion functions. We deliberately do not grant
-- INSERT/UPDATE on clinical tables here.
-- ============================================================

REVOKE ALL
ON SCHEMA clinical
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


REVOKE ALL
ON ALL TABLES IN SCHEMA clinical
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


-- ============================================================
-- 5. NO GOVERNANCE AUTHORITY
-- ============================================================

REVOKE ALL
ON SCHEMA governance
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


REVOKE ALL
ON ALL TABLES IN SCHEMA governance
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


-- ============================================================
-- 6. CONTROLLED TELEMETRY
-- ============================================================

GRANT USAGE
ON SCHEMA ops
TO janus_canonical_svc;


GRANT EXECUTE
ON FUNCTION ops.write_system_event(JSONB)
TO janus_canonical_svc;


-- ============================================================
-- 7. GOVERNANCE REVIEW
--
-- Governance may inspect promotion provenance and lineage.
-- It receives no promotion execution authority.
-- ============================================================

GRANT SELECT
ON
    ingest.canonical_promotion_run,
    ingest.v_canonical_promotion_status,
    ingest.record_lineage
TO janus_governance_review;


REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON
    ingest.canonical_promotion_run,
    ingest.record_lineage
FROM
    janus_governance_review,
    janus_governance_svc;


REVOKE EXECUTE
ON FUNCTION ingest.begin_canonical_promotion(
    UUID, TEXT, TEXT, TEXT, TEXT
)
FROM
    janus_governance_review,
    janus_governance_svc;


REVOKE EXECUTE
ON FUNCTION ingest.complete_canonical_promotion(
    UUID, BIGINT, BIGINT, BIGINT, BIGINT, BIGINT, JSONB
)
FROM
    janus_governance_review,
    janus_governance_svc;


REVOKE EXECUTE
ON FUNCTION ingest.fail_canonical_promotion(
    UUID, JSONB, JSONB
)
FROM
    janus_governance_review,
    janus_governance_svc;


COMMIT;