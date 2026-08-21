-- ============================================================
-- JANUS
-- Security Bootstrap 015
-- Controlled Synthea Provider Promotion v1
--
-- Only the Canonical runtime receives execution authority.
--
-- No runtime receives direct clinical Provider DML as part of
-- this change.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CANONICAL CAPABILITY
-- ============================================================

GRANT EXECUTE
ON FUNCTION ingest.promote_synthea_provider_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TEXT,
    TEXT
)
TO janus_canonical_runtime;


-- ============================================================
-- 2. EXPLICITLY DENY OTHER AUTHORITIES
-- ============================================================

REVOKE EXECUTE
ON FUNCTION ingest.promote_synthea_provider_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    UUID,
    TEXT,
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
-- 3. CANONICAL STILL HAS NO DIRECT PROVIDER TABLE ACCESS
-- ============================================================

REVOKE ALL
ON TABLE clinical.provider
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


-- ============================================================
-- 4. DEFENSE IN DEPTH FOR ETL / QUALITY
-- ============================================================

REVOKE ALL
ON TABLE clinical.provider
FROM
    janus_etl_svc,
    janus_quality_rw,
    janus_quality_svc;


COMMIT;