-- ============================================================
-- JANUS
-- Security Bootstrap 017
-- Controlled Synthea Encounter Promotion v1
--
-- Canonical receives only EXECUTE on the controlled writer.
--
-- No direct Encounter / Encounter-Identifier DML is granted.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CANONICAL EXECUTION CAPABILITY
-- ============================================================

GRANT EXECUTE
ON FUNCTION ingest.promote_synthea_encounter_v1(
    UUID,
    UUID,
    TEXT,
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
-- 2. EXPLICITLY DENY OTHER AUTHORITIES
-- ============================================================

REVOKE EXECUTE
ON FUNCTION ingest.promote_synthea_encounter_v1(
    UUID,
    UUID,
    TEXT,
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
    janus_quality_rw,
    janus_quality_svc,
    janus_governance_review,
    janus_governance_svc;


-- ============================================================
-- 3. CANONICAL HAS NO DIRECT ENCOUNTER DML
-- ============================================================

REVOKE ALL
ON TABLE
    clinical.encounter,
    clinical.encounter_identifier
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


-- ============================================================
-- 4. ETL / QUALITY ALSO HAVE NO DIRECT ENCOUNTER ACCESS
-- ============================================================

REVOKE ALL
ON TABLE
    clinical.encounter,
    clinical.encounter_identifier
FROM
    janus_etl_svc,
    janus_quality_rw,
    janus_quality_svc;


COMMIT;