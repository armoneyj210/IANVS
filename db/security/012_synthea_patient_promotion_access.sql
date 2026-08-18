-- ============================================================
-- JANUS
-- Security Bootstrap 012
-- Synthea Patient Promotion v1
--
-- Run as PostgreSQL bootstrap/admin AFTER Flyway V012.
--
-- The Canonical service receives EXECUTE only.
-- It receives no clinical table writes.
-- ============================================================

BEGIN;


-- ============================================================
-- CANONICAL SERVICE
-- ============================================================

GRANT EXECUTE
ON FUNCTION ingest.promote_synthea_patient_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT
)
TO janus_canonical_runtime;


-- ============================================================
-- DENY EVERY OTHER SERVICE
-- ============================================================

REVOKE EXECUTE
ON FUNCTION ingest.promote_synthea_patient_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT
)
FROM
    janus_etl_svc,
    janus_quality_svc,
    janus_governance_svc,
    janus_governance_review;


-- ============================================================
-- DEFENSE IN DEPTH
-- ============================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON
    clinical.patient,
    clinical.patient_identifier
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ingest.record_lineage
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


COMMIT;