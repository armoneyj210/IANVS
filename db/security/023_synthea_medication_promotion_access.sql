-- ============================================================
-- JANUS
-- Security Bootstrap 023
-- Controlled Synthea Medication Promotion v1
--
-- Canonical runtime may invoke only the controlled writer.
-- No direct clinical.medication DML is granted.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CANONICAL RUNTIME MAY EXECUTE CONTROLLED WRITER
-- ============================================================

GRANT EXECUTE
ON FUNCTION ingest.promote_synthea_medication_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    TEXT
)
TO janus_canonical_runtime;


-- ============================================================
-- 2. OTHER SERVICE AUTHORITIES MAY NOT EXECUTE WRITER
-- ============================================================

REVOKE EXECUTE
ON FUNCTION ingest.promote_synthea_medication_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
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
ON TABLE clinical.medication
FROM
    janus_canonical_runtime,
    janus_canonical_svc,
    janus_etl_svc,
    janus_quality_svc;


COMMIT;