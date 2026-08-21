-- ============================================================
-- JANUS
-- Security Bootstrap 016
-- Provider Post-Canonical Lineage Quality
--
-- Quality receives narrow evidence interfaces only.
--
-- It does NOT receive:
--   * clinical access
--   * canonical_promotion_run SELECT
--   * Canonical writer authority
-- ============================================================

BEGIN;


-- ============================================================
-- 1. QUALITY NARROW SCOPE RESOLUTION
-- ============================================================

GRANT EXECUTE
ON FUNCTION
ingest.resolve_postcanonical_lineage_scope(UUID)
TO janus_quality_svc;


-- ============================================================
-- 2. QUALITY PROVIDER LINEAGE EVIDENCE
-- ============================================================

GRANT EXECUTE
ON FUNCTION
ingest.evaluate_provider_canonical_lineage(UUID)
TO janus_quality_svc;


-- ============================================================
-- 3. OTHER AUTHORITIES MUST NOT USE THE EVALUATOR
-- ============================================================

REVOKE EXECUTE
ON FUNCTION
ingest.resolve_postcanonical_lineage_scope(UUID)
FROM
    janus_etl_svc,
    janus_canonical_svc,
    janus_governance_svc,
    janus_governance_review;


REVOKE EXECUTE
ON FUNCTION
ingest.evaluate_provider_canonical_lineage(UUID)
FROM
    janus_etl_svc,
    janus_canonical_svc,
    janus_governance_svc,
    janus_governance_review;


-- ============================================================
-- 4. QUALITY STILL HAS ZERO CLINICAL ACCESS
-- ============================================================

REVOKE ALL
ON SCHEMA clinical
FROM
    janus_quality_rw,
    janus_quality_svc;


REVOKE ALL
ON ALL TABLES IN SCHEMA clinical
FROM
    janus_quality_rw,
    janus_quality_svc;


-- ============================================================
-- 5. QUALITY STILL MAY NOT READ PROMOTION TABLE DIRECTLY
-- ============================================================

REVOKE ALL
ON TABLE ingest.canonical_promotion_run
FROM
    janus_quality_rw,
    janus_quality_svc;


COMMIT;