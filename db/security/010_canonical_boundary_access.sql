-- ============================================================
-- JANUS
-- Security Bootstrap 010
-- Quality Authority and Canonical Boundary Access
--
-- Run using the PostgreSQL bootstrap/admin account.
-- No passwords belong in this file.
--
-- Run AFTER Flyway V010.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CREATE QUALITY CAPABILITY + LOGIN IDENTITIES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'janus_quality_rw'
    ) THEN
        CREATE ROLE janus_quality_rw
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
        WHERE rolname = 'janus_quality_svc'
    ) THEN
        CREATE ROLE janus_quality_svc
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


GRANT janus_quality_rw
TO janus_quality_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


GRANT CONNECT
ON DATABASE therapy
TO janus_quality_svc;


-- ============================================================
-- 2. ETL IS NO LONGER A QUALITY OR CLINICAL WRITE AUTHORITY
-- ============================================================

GRANT janus_clinical_ro
TO janus_etl_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;

REVOKE janus_clinical_rw
FROM janus_etl_svc;


REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ALL TABLES IN SCHEMA clinical
FROM janus_etl_svc;


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


-- ============================================================
-- 3. QUALITY SERVICE: LEAST-PRIVILEGE INGEST/DQ ACCESS
-- ============================================================

GRANT USAGE
ON SCHEMA ingest
TO janus_quality_rw;


GRANT SELECT
ON
    ingest.source_system,
    ingest.dataset,
    ingest.dataset_release,
    ingest.source_file,
    ingest.import_batch,
    ingest.source_record,
    ingest.data_quality_rule,
    ingest.data_quality_run,
    ingest.data_quality_result,
    ingest.validation_issue,
    ingest.quarantine_record,
    ingest.quality_gate_decision,
    ingest.v_data_quality_run_summary,
    ingest.v_quality_gate_effective_status
TO janus_quality_rw;


GRANT INSERT, UPDATE
ON ingest.data_quality_run
TO janus_quality_rw;


GRANT INSERT
ON
    ingest.data_quality_result,
    ingest.validation_issue,
    ingest.quarantine_record
TO janus_quality_rw;


-- Quality may change only the lifecycle status of an imported
-- source record. It may not alter its key/hash/locator/provenance.
GRANT UPDATE (record_status)
ON ingest.source_record
TO janus_quality_rw;


-- Historical DQ evidence is append-oriented.
REVOKE UPDATE, DELETE, TRUNCATE
ON
    ingest.data_quality_result,
    ingest.validation_issue,
    ingest.quarantine_record,
    ingest.quality_gate_decision
FROM janus_quality_rw;


-- Gate decisions can only be created through the controlled
-- SECURITY DEFINER function.
REVOKE INSERT
ON ingest.quality_gate_decision
FROM janus_quality_rw, janus_quality_svc;


GRANT EXECUTE
ON FUNCTION ingest.write_quality_gate_decision(
    UUID, TEXT, TEXT
)
TO janus_quality_svc;


-- ============================================================
-- 4. QUALITY TELEMETRY: SYSTEM EVENT ONLY
-- ============================================================

GRANT USAGE
ON SCHEMA ops
TO janus_quality_svc;


GRANT EXECUTE
ON FUNCTION ops.write_system_event(JSONB)
TO janus_quality_svc;


-- ============================================================
-- 5. QUALITY HAS NO CLINICAL OR GOVERNANCE AUTHORITY
-- ============================================================

REVOKE ALL
ON SCHEMA clinical
FROM janus_quality_rw, janus_quality_svc;

REVOKE ALL
ON ALL TABLES IN SCHEMA clinical
FROM janus_quality_rw, janus_quality_svc;


REVOKE ALL
ON SCHEMA governance
FROM janus_quality_rw, janus_quality_svc;

REVOKE ALL
ON ALL TABLES IN SCHEMA governance
FROM janus_quality_rw, janus_quality_svc;


-- ============================================================
-- 6. GOVERNANCE MAY REVIEW DQ EVIDENCE
--
-- Override authority remains intentionally absent.
-- ============================================================

GRANT SELECT
ON
    ingest.import_batch,
    ingest.data_quality_rule,
    ingest.data_quality_run,
    ingest.data_quality_result,
    ingest.validation_issue,
    ingest.quarantine_record,
    ingest.quality_gate_decision,
    ingest.v_data_quality_run_summary,
    ingest.v_quality_gate_effective_status
TO janus_governance_review;


REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ingest.quality_gate_decision
FROM janus_governance_review, janus_governance_svc;


COMMIT;