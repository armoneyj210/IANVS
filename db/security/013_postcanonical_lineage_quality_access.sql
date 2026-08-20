-- ============================================================
-- JANUS
-- Security Bootstrap 013
-- Post-Canonical Lineage Quality Access
--
-- Run as PostgreSQL bootstrap/admin AFTER Flyway V013.
--
-- Quality receives narrow aggregate lineage evaluation and
-- certification capabilities.
--
-- Quality still receives NO clinical schema/table access.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. QUALITY MAY EXECUTE NARROW LINEAGE EVALUATION
-- ============================================================

GRANT EXECUTE
ON FUNCTION ingest.evaluate_canonical_lineage(UUID)
TO janus_quality_svc;


GRANT EXECUTE
ON FUNCTION ingest.write_postcanonical_lineage_decision(
    UUID,
    TEXT,
    TEXT
)
TO janus_quality_svc;


GRANT SELECT
ON ingest.v_postcanonical_lineage_gate_status
TO janus_quality_rw;


-- ============================================================
-- 2. EXPLICITLY DENY OTHER SERVICE AUTHORITIES
-- ============================================================

REVOKE EXECUTE
ON FUNCTION ingest.evaluate_canonical_lineage(UUID)
FROM
    janus_etl_svc,
    janus_canonical_svc,
    janus_governance_svc,
    janus_governance_review;


REVOKE EXECUTE
ON FUNCTION ingest.write_postcanonical_lineage_decision(
    UUID,
    TEXT,
    TEXT
)
FROM
    janus_etl_svc,
    janus_canonical_svc,
    janus_governance_svc,
    janus_governance_review;


-- ============================================================
-- 3. QUALITY STILL HAS ZERO CLINICAL ACCESS
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
-- 4. GOVERNANCE MAY REVIEW CERTIFICATION EVIDENCE
-- ============================================================

GRANT SELECT
ON ingest.v_postcanonical_lineage_gate_status
TO janus_governance_review;


-- Governance observes; it does not certify.
REVOKE EXECUTE
ON FUNCTION ingest.write_postcanonical_lineage_decision(
    UUID,
    TEXT,
    TEXT
)
FROM
    janus_governance_review,
    janus_governance_svc;


COMMIT;