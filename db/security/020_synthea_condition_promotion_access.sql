-- ============================================================
-- JANUS
-- Security Bootstrap 020
-- Controlled Synthea Condition Promotion v1
--
-- Canonical runtime may invoke only the controlled writer.
-- No direct clinical.condition DML is granted.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CANONICAL RUNTIME MAY EXECUTE CONTROLLED WRITER
-- ============================================================

GRANT EXECUTE
ON FUNCTION ingest.promote_synthea_condition_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT
)
TO janus_canonical_runtime;


-- ============================================================
-- 2. OTHER SERVICE AUTHORITIES MAY NOT EXECUTE WRITER
-- ============================================================

REVOKE EXECUTE
ON FUNCTION ingest.promote_synthea_condition_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT
)
FROM
    janus_etl_svc,
    janus_quality_svc,
    janus_governance_svc,
    janus_governance_review,
    janus_api_svc,
    janus_twin_svc,
    janus_simulation_svc,
    janus_ops_svc;


-- ============================================================
-- 3. PRESERVE NO-DIRECT-DML CANONICAL BOUNDARY
-- ============================================================

REVOKE ALL
ON TABLE clinical.condition
FROM
    janus_canonical_runtime,
    janus_canonical_svc,
    janus_etl_svc,
    janus_quality_svc;


COMMIT;
