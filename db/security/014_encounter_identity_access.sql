-- ============================================================
-- JANUS
-- Security Bootstrap 014
-- Encounter Identity Foundation
--
-- The table exists for controlled canonical operations.
--
-- ETL, Quality, Canonical runtime, and Governance do not gain
-- direct table access merely because the table now exists.
--
-- Future SECURITY DEFINER mapping functions will access this
-- table as janus_owner.
-- ============================================================

BEGIN;

-- ============================================================
-- 0. HARDEN ETL / CLINICAL SEPARATION
--
-- ETL previously inherited janus_clinical_ro, which allowed
-- it to browse canonical clinical facts.
--
-- Canonical facts are outside the ETL authority boundary.
-- ============================================================

REVOKE
    janus_clinical_ro,
    janus_clinical_rw
FROM janus_etl_svc;

-- ============================================================
-- 1. REMOVE PUBLIC ACCESS
-- ============================================================

REVOKE ALL
ON TABLE clinical.encounter_identifier
FROM PUBLIC;


-- ============================================================
-- 2. ETL MUST NOT ACCESS CANONICAL ENCOUNTER IDENTIFIERS
-- ============================================================

REVOKE ALL
ON TABLE clinical.encounter_identifier
FROM
    janus_etl_svc;


-- ============================================================
-- 3. QUALITY REMAINS OUTSIDE CLINICAL TABLES
-- ============================================================

REVOKE ALL
ON TABLE clinical.encounter_identifier
FROM
    janus_quality_rw,
    janus_quality_svc;


-- ============================================================
-- 4. CANONICAL SERVICE DOES NOT RECEIVE DIRECT CLINICAL DML
--
-- Controlled SECURITY DEFINER functions will be introduced
-- with Encounter Mapping v1.
-- ============================================================

REVOKE ALL
ON TABLE clinical.encounter_identifier
FROM
    janus_canonical_runtime,
    janus_canonical_svc;


-- ============================================================
-- 5. GOVERNANCE REVIEWS PROVENANCE, NOT CLINICAL TABLES
-- ============================================================

REVOKE ALL
ON TABLE clinical.encounter_identifier
FROM
    janus_governance_review,
    janus_governance_svc;


COMMIT;