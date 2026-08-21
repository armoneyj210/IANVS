-- ============================================================
-- JANUS
-- Security Bootstrap 019
-- Encounter Post-Canonical Lineage Quality
--
-- Quality receives only the narrow Encounter lineage evidence
-- interface.
--
-- No clinical access is granted.
-- No canonical_promotion_run access is granted.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. QUALITY MAY EXECUTE ENCOUNTER DQ-006 EVIDENCE
-- ============================================================

GRANT EXECUTE
ON FUNCTION
ingest.evaluate_encounter_canonical_lineage(UUID)
TO janus_quality_svc;


-- ============================================================
-- 2. OTHER AUTHORITIES MAY NOT EXECUTE IT
-- ============================================================

REVOKE EXECUTE
ON FUNCTION
ingest.evaluate_encounter_canonical_lineage(UUID)
FROM
    janus_etl_svc,
    janus_canonical_svc,
    janus_governance_svc,
    janus_governance_review;


-- ============================================================
-- 3. QUALITY STILL HAS NO DIRECT CLINICAL ACCESS
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
-- 4. QUALITY STILL MAY NOT READ PROMOTION TABLE DIRECTLY
-- ============================================================

REVOKE ALL
ON TABLE ingest.canonical_promotion_run
FROM
    janus_quality_rw,
    janus_quality_svc;


COMMIT;