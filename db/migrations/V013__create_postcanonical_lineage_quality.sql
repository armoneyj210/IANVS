-- ============================================================
-- JANUS
-- V013
-- Post-Canonical Lineage Quality Authority
--
-- Introduces the independent quality boundary for:
--
--   JANUS-DQ-006
--   Canonical Lineage Required
--
-- Ruleset:
--   janus-postcanonical-lineage v1
--
-- Goals:
--   1. Bind post-canonical DQ evidence to the exact canonical
--      promotion being evaluated.
--   2. Allow Quality to evaluate lineage without granting
--      Quality access to the clinical schema.
--   3. Require 100% lineage integrity for Patient Mapping v1.
--   4. Create a dedicated controlled PASS/FAIL writer.
--   5. Preserve pre-canonical v2 history unchanged.
--
-- Quality evaluates.
-- Canonical does not certify itself.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. VERIFY EXISTING DQ-006 REGISTRY CONTRACT
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM ingest.data_quality_rule
        WHERE rule_code = 'JANUS-DQ-006'
          AND rule_version = 1
          AND severity = 'fatal'
          AND blocking IS TRUE
          AND is_active IS TRUE
    ) THEN
        RAISE EXCEPTION
            'JANUS-DQ-006 v1 must exist as an active fatal blocking rule before V013';
    END IF;

END;
$$;


-- ============================================================
-- 2. BIND DATA-QUALITY RUNS TO CANONICAL PROMOTIONS
--
-- Existing pre-canonical runs remain NULL here.
-- Post-canonical lineage runs must carry the exact promotion ID.
-- ============================================================

ALTER TABLE ingest.data_quality_run
ADD COLUMN canonical_promotion_run_id UUID;


ALTER TABLE ingest.data_quality_run
ADD CONSTRAINT
    data_quality_run_canonical_promotion_fk
FOREIGN KEY (canonical_promotion_run_id)
REFERENCES ingest.canonical_promotion_run (
    canonical_promotion_run_id
);


ALTER TABLE ingest.data_quality_run
ADD CONSTRAINT
    data_quality_run_postcanonical_scope_ck
CHECK (
    ruleset_name <> 'janus-postcanonical-lineage'
    OR canonical_promotion_run_id IS NOT NULL
);


CREATE INDEX
    ix_data_quality_run_canonical_promotion
ON ingest.data_quality_run (
    canonical_promotion_run_id,
    created_at
);


-- One active/successful certification of one promotion under
-- one post-canonical ruleset version.
--
-- A failed execution may be retried, but completed/running
-- evidence cannot be duplicated.
CREATE UNIQUE INDEX
    ux_data_quality_run_postcanonical_active
ON ingest.data_quality_run (
    canonical_promotion_run_id,
    ruleset_name,
    ruleset_version
)
WHERE canonical_promotion_run_id IS NOT NULL
  AND status IN ('running', 'completed');


-- ============================================================
-- 3. POST-CANONICAL SCOPE IS IMMUTABLE
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.enforce_quality_run_canonical_scope_immutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    IF NEW.canonical_promotion_run_id
        IS DISTINCT FROM
       OLD.canonical_promotion_run_id
    THEN
        RAISE EXCEPTION
            'Canonical promotion scope of a data-quality run is immutable'
            USING ERRCODE = '42501';
    END IF;

    RETURN NEW;

END;
$$;


CREATE TRIGGER
    trg_quality_run_canonical_scope_immutable
BEFORE UPDATE
ON ingest.data_quality_run
FOR EACH ROW
EXECUTE FUNCTION
    ingest.enforce_quality_run_canonical_scope_immutable();


-- ============================================================
-- 4. CONTROLLED DQ-006 LINEAGE EVIDENCE
--
-- IMPORTANT:
-- janus_quality_svc still receives NO clinical schema access.
--
-- This SECURITY DEFINER function performs narrow aggregate
-- inspection as janus_owner and returns only provenance metrics.
--
-- Current supported contract:
--   synthea-patient v1
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.evaluate_canonical_lineage(
    p_canonical_promotion_run_id UUID
)
RETURNS TABLE (
    canonical_promotion_run_id UUID,
    import_batch_id UUID,
    mapping_name TEXT,
    mapping_version TEXT,

    promotion_records_seen BIGINT,
    promotion_records_created BIGINT,
    promotion_records_existing BIGINT,
    promotion_records_failed BIGINT,

    expected_patient_sources BIGINT,

    valid_patient_lineage_edges BIGINT,
    patient_lineage_sources BIGINT,
    patient_lineage_targets BIGINT,

    patient_sources_missing_lineage BIGINT,
    patient_sources_with_multiple_targets BIGINT,
    patient_orphan_targets BIGINT,

    expected_identifier_targets BIGINT,
    valid_identifier_lineage_edges BIGINT,
    identifier_lineage_targets BIGINT,

    identifier_targets_missing_lineage BIGINT,
    identifier_orphan_targets BIGINT,
    unexpected_identifier_lineage_edges BIGINT,

    wrong_source_artifact_edges BIGINT,
    wrong_mapping_version_edges BIGINT,
    wrong_transformation_edges BIGINT,
    unexpected_target_edges BIGINT,

    promotion_counter_mismatch BIGINT,
    patient_target_count_mismatch BIGINT,

    violation_count BIGINT,
    lineage_complete BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest, clinical
AS $$
DECLARE
    v_import_batch_id UUID;
    v_mapping_name TEXT;
    v_mapping_version TEXT;
    v_promotion_status TEXT;

    v_records_seen BIGINT;
    v_records_created BIGINT;
    v_records_existing BIGINT;
    v_records_failed BIGINT;

    v_expected_patient_sources BIGINT;

    v_valid_patient_lineage_edges BIGINT;
    v_patient_lineage_sources BIGINT;
    v_patient_lineage_targets BIGINT;

    v_patient_sources_missing_lineage BIGINT;
    v_patient_sources_with_multiple_targets BIGINT;
    v_patient_orphan_targets BIGINT;

    v_expected_identifier_targets BIGINT;
    v_valid_identifier_lineage_edges BIGINT;
    v_identifier_lineage_targets BIGINT;

    v_identifier_targets_missing_lineage BIGINT;
    v_identifier_orphan_targets BIGINT;
    v_unexpected_identifier_lineage_edges BIGINT;

    v_wrong_source_artifact_edges BIGINT;
    v_wrong_mapping_version_edges BIGINT;
    v_wrong_transformation_edges BIGINT;
    v_unexpected_target_edges BIGINT;

    v_promotion_counter_mismatch BIGINT;
    v_patient_target_count_mismatch BIGINT;

    v_violation_count BIGINT;
    v_lineage_complete BOOLEAN;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_quality_svc' THEN
        RAISE EXCEPTION
            'Canonical lineage evidence may only be evaluated by janus_quality_svc'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- RESOLVE PROMOTION
    -- ========================================================

    SELECT
        cpr.import_batch_id,
        cpr.mapping_name,
        cpr.mapping_version,
        cpr.status,
        cpr.records_seen,
        cpr.records_created,
        cpr.records_existing,
        cpr.records_failed
    INTO
        v_import_batch_id,
        v_mapping_name,
        v_mapping_version,
        v_promotion_status,
        v_records_seen,
        v_records_created,
        v_records_existing,
        v_records_failed
    FROM ingest.canonical_promotion_run cpr
    WHERE cpr.canonical_promotion_run_id =
          p_canonical_promotion_run_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown canonical promotion run: %',
            p_canonical_promotion_run_id;
    END IF;


    IF v_promotion_status <> 'completed' THEN
        RAISE EXCEPTION
            'DQ-006 requires a completed canonical promotion'
            USING ERRCODE = '42501';
    END IF;


    IF v_mapping_name <> 'synthea-patient'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'DQ-006 v1 currently supports only synthea-patient v1'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- EXPECTED SOURCE POPULATION
    -- ========================================================

    SELECT COUNT(*)
    INTO v_expected_patient_sources
    FROM ingest.source_record sr
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE sr.import_batch_id =
          v_import_batch_id
      AND sf.relative_path =
          'csv/patients.csv'
      AND sr.record_status =
          'accepted';


    -- ========================================================
    -- VALID PATIENT LINEAGE
    --
    -- An edge counts as valid only when:
    --   * it belongs to this promotion,
    --   * its source belongs to this import,
    --   * source artifact is patients.csv,
    --   * source is accepted,
    --   * mapping/transformation contract matches,
    --   * target exists.
    -- ========================================================

    WITH valid_patient_edges AS (
        SELECT
            rl.source_record_id,
            rl.target_record_id
        FROM ingest.record_lineage rl
        JOIN ingest.source_record sr
          ON sr.source_record_id =
             rl.source_record_id
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        JOIN clinical.patient p
          ON p.patient_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sf.relative_path =
              'csv/patients.csv'
          AND sr.record_status =
              'accepted'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient'
          AND rl.transformation_version =
              '1'
    )
    SELECT
        COUNT(*),
        COUNT(DISTINCT source_record_id),
        COUNT(DISTINCT target_record_id)
    INTO
        v_valid_patient_lineage_edges,
        v_patient_lineage_sources,
        v_patient_lineage_targets
    FROM valid_patient_edges;


    -- ========================================================
    -- MISSING PATIENT SOURCE COVERAGE
    -- ========================================================

    WITH expected_sources AS (
        SELECT sr.source_record_id
        FROM ingest.source_record sr
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE sr.import_batch_id =
              v_import_batch_id
          AND sf.relative_path =
              'csv/patients.csv'
          AND sr.record_status =
              'accepted'
    ),
    covered_sources AS (
        SELECT DISTINCT
            rl.source_record_id
        FROM ingest.record_lineage rl
        JOIN clinical.patient p
          ON p.patient_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_patient_sources_missing_lineage
    FROM expected_sources e
    LEFT JOIN covered_sources c
      ON c.source_record_id =
         e.source_record_id
    WHERE c.source_record_id IS NULL;


    -- ========================================================
    -- MULTIPLE PATIENT TARGETS FROM ONE SOURCE
    -- ========================================================

    WITH valid_patient_edges AS (
        SELECT
            rl.source_record_id,
            rl.target_record_id
        FROM ingest.record_lineage rl
        JOIN ingest.source_record sr
          ON sr.source_record_id =
             rl.source_record_id
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        JOIN clinical.patient p
          ON p.patient_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sf.relative_path =
              'csv/patients.csv'
          AND sr.record_status =
              'accepted'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_patient_sources_with_multiple_targets
    FROM (
        SELECT source_record_id
        FROM valid_patient_edges
        GROUP BY source_record_id
        HAVING COUNT(
            DISTINCT target_record_id
        ) > 1
    ) duplicated_sources;


    -- ========================================================
    -- ORPHAN PATIENT TARGETS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_patient_orphan_targets
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.patient p
      ON p.patient_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'patient'
      AND p.patient_id IS NULL;


    -- ========================================================
    -- EXPECTED IDENTIFIERS FOR PROMOTED PATIENT TARGETS
    --
    -- We inspect only the four source identifier systems
    -- defined by Synthea Patient Mapping v1.
    -- ========================================================

    WITH patient_pairs AS (
        SELECT DISTINCT
            rl.source_record_id,
            rl.target_record_id AS patient_id
        FROM ingest.record_lineage rl
        JOIN clinical.patient p
          ON p.patient_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_expected_identifier_targets
    FROM clinical.patient_identifier pi
    JOIN patient_pairs pp
      ON pp.patient_id =
         pi.patient_id
    WHERE pi.identifier_system IN (
        'urn:janus:source:synthea:patient-id',
        'urn:janus:source:synthea:ssn',
        'urn:janus:source:synthea:drivers-license',
        'urn:janus:source:synthea:passport'
    );


    -- ========================================================
    -- VALID IDENTIFIER LINEAGE
    --
    -- Identifier lineage must originate from the SAME source
    -- record that produced its owning patient.
    -- ========================================================

    WITH patient_pairs AS (
        SELECT DISTINCT
            rl.source_record_id,
            rl.target_record_id AS patient_id
        FROM ingest.record_lineage rl
        JOIN clinical.patient p
          ON p.patient_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient'
          AND rl.transformation_version =
              '1'
    ),
    valid_identifier_edges AS (
        SELECT
            rl.source_record_id,
            rl.target_record_id
        FROM ingest.record_lineage rl
        JOIN clinical.patient_identifier pi
          ON pi.patient_identifier_id =
             rl.target_record_id
        JOIN patient_pairs pp
          ON pp.patient_id =
             pi.patient_id
         AND pp.source_record_id =
             rl.source_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient_identifier'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient_identifier'
          AND rl.transformation_version =
              '1'
          AND pi.identifier_system IN (
              'urn:janus:source:synthea:patient-id',
              'urn:janus:source:synthea:ssn',
              'urn:janus:source:synthea:drivers-license',
              'urn:janus:source:synthea:passport'
          )
    )
    SELECT
        COUNT(*),
        COUNT(DISTINCT target_record_id)
    INTO
        v_valid_identifier_lineage_edges,
        v_identifier_lineage_targets
    FROM valid_identifier_edges;


    -- ========================================================
    -- IDENTIFIER TARGETS MISSING LINEAGE
    -- ========================================================

    WITH patient_pairs AS (
        SELECT DISTINCT
            rl.source_record_id,
            rl.target_record_id AS patient_id
        FROM ingest.record_lineage rl
        JOIN clinical.patient p
          ON p.patient_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient'
          AND rl.transformation_version =
              '1'
    ),
    expected_identifiers AS (
        SELECT
            pp.source_record_id,
            pi.patient_identifier_id
        FROM patient_pairs pp
        JOIN clinical.patient_identifier pi
          ON pi.patient_id =
             pp.patient_id
        WHERE pi.identifier_system IN (
            'urn:janus:source:synthea:patient-id',
            'urn:janus:source:synthea:ssn',
            'urn:janus:source:synthea:drivers-license',
            'urn:janus:source:synthea:passport'
        )
    ),
    valid_identifier_edges AS (
        SELECT
            rl.source_record_id,
            rl.target_record_id
                AS patient_identifier_id
        FROM ingest.record_lineage rl
        JOIN clinical.patient_identifier pi
          ON pi.patient_identifier_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient_identifier'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient_identifier'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_identifier_targets_missing_lineage
    FROM expected_identifiers ei
    LEFT JOIN valid_identifier_edges ve
      ON ve.source_record_id =
         ei.source_record_id
     AND ve.patient_identifier_id =
         ei.patient_identifier_id
    WHERE ve.patient_identifier_id IS NULL;


    -- ========================================================
    -- ORPHAN IDENTIFIER TARGETS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_identifier_orphan_targets
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.patient_identifier pi
      ON pi.patient_identifier_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'patient_identifier'
      AND pi.patient_identifier_id IS NULL;


    -- ========================================================
    -- EXTRA / WRONG IDENTIFIER LINEAGE
    --
    -- An identifier edge is unexpected when it does not map
    -- to an allowed identifier belonging to the patient created
    -- from the same source record.
    -- ========================================================

    WITH patient_pairs AS (
        SELECT DISTINCT
            rl.source_record_id,
            rl.target_record_id AS patient_id
        FROM ingest.record_lineage rl
        JOIN clinical.patient p
          ON p.patient_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_patient'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_unexpected_identifier_lineage_edges
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.patient_identifier pi
      ON pi.patient_identifier_id =
         rl.target_record_id
    LEFT JOIN patient_pairs pp
      ON pp.source_record_id =
         rl.source_record_id
     AND pp.patient_id =
         pi.patient_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'patient_identifier'
      AND (
            pi.patient_identifier_id IS NULL
         OR pp.patient_id IS NULL
         OR pi.identifier_system NOT IN (
              'urn:janus:source:synthea:patient-id',
              'urn:janus:source:synthea:ssn',
              'urn:janus:source:synthea:drivers-license',
              'urn:janus:source:synthea:passport'
         )
      );


    -- ========================================================
    -- WRONG SOURCE ARTIFACT / IMPORT / STATUS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_wrong_source_artifact_edges
    FROM ingest.record_lineage rl
    JOIN ingest.source_record sr
      ON sr.source_record_id =
         rl.source_record_id
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND (
            sr.import_batch_id
                IS DISTINCT FROM
                v_import_batch_id
         OR sf.relative_path
                IS DISTINCT FROM
                'csv/patients.csv'
         OR sr.record_status
                IS DISTINCT FROM
                'accepted'
      );


    -- ========================================================
    -- WRONG MAPPING VERSION
    -- ========================================================

    SELECT COUNT(*)
    INTO v_wrong_mapping_version_edges
    FROM ingest.record_lineage rl
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.mapping_version
          IS DISTINCT FROM
          v_mapping_version;


    -- ========================================================
    -- WRONG TRANSFORMATION CONTRACT
    -- ========================================================

    SELECT COUNT(*)
    INTO v_wrong_transformation_edges
    FROM ingest.record_lineage rl
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND (
            (
                rl.target_schema = 'clinical'
                AND rl.target_table = 'patient'
                AND (
                    rl.transformation_name
                        IS DISTINCT FROM
                        'janus.canonical.synthea_patient'
                    OR
                    rl.transformation_version
                        IS DISTINCT FROM
                        '1'
                )
            )
            OR
            (
                rl.target_schema = 'clinical'
                AND rl.target_table =
                    'patient_identifier'
                AND (
                    rl.transformation_name
                        IS DISTINCT FROM
                        'janus.canonical.synthea_patient_identifier'
                    OR
                    rl.transformation_version
                        IS DISTINCT FROM
                        '1'
                )
            )
      );


    -- ========================================================
    -- UNEXPECTED TARGET TYPES
    -- ========================================================

    SELECT COUNT(*)
    INTO v_unexpected_target_edges
    FROM ingest.record_lineage rl
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND (
            rl.target_schema
                IS DISTINCT FROM
                'clinical'
         OR rl.target_table NOT IN (
                'patient',
                'patient_identifier'
            )
      );


    -- ========================================================
    -- PROMOTION COUNTER RECONCILIATION
    -- ========================================================

    v_promotion_counter_mismatch :=
        CASE
            WHEN v_records_seen
                    IS DISTINCT FROM
                    v_expected_patient_sources
              OR (
                    v_records_created
                    + v_records_existing
                    + v_records_failed
                 )
                    IS DISTINCT FROM
                    v_records_seen
              OR v_records_failed <> 0
            THEN 1
            ELSE 0
        END;


    -- Patient Mapping v1 is one source patient -> one canonical
    -- patient target.
    v_patient_target_count_mismatch :=
        CASE
            WHEN v_patient_lineage_targets
                    IS DISTINCT FROM
                    v_expected_patient_sources
            THEN 1
            ELSE 0
        END;


    -- ========================================================
    -- FINAL DQ-006 DECISION EVIDENCE
    -- ========================================================

    v_violation_count :=
          v_patient_sources_missing_lineage
        + v_patient_sources_with_multiple_targets
        + v_patient_orphan_targets
        + v_identifier_targets_missing_lineage
        + v_identifier_orphan_targets
        + v_unexpected_identifier_lineage_edges
        + v_wrong_source_artifact_edges
        + v_wrong_mapping_version_edges
        + v_wrong_transformation_edges
        + v_unexpected_target_edges
        + v_promotion_counter_mismatch
        + v_patient_target_count_mismatch;


    v_lineage_complete :=
        v_violation_count = 0
        AND v_expected_patient_sources > 0
        AND v_valid_patient_lineage_edges =
            v_expected_patient_sources
        AND v_patient_lineage_sources =
            v_expected_patient_sources
        AND v_expected_identifier_targets =
            v_valid_identifier_lineage_edges
        AND v_identifier_lineage_targets =
            v_expected_identifier_targets;


    RETURN QUERY
    SELECT
        p_canonical_promotion_run_id,
        v_import_batch_id,
        v_mapping_name,
        v_mapping_version,

        v_records_seen,
        v_records_created,
        v_records_existing,
        v_records_failed,

        v_expected_patient_sources,

        v_valid_patient_lineage_edges,
        v_patient_lineage_sources,
        v_patient_lineage_targets,

        v_patient_sources_missing_lineage,
        v_patient_sources_with_multiple_targets,
        v_patient_orphan_targets,

        v_expected_identifier_targets,
        v_valid_identifier_lineage_edges,
        v_identifier_lineage_targets,

        v_identifier_targets_missing_lineage,
        v_identifier_orphan_targets,
        v_unexpected_identifier_lineage_edges,

        v_wrong_source_artifact_edges,
        v_wrong_mapping_version_edges,
        v_wrong_transformation_edges,
        v_unexpected_target_edges,

        v_promotion_counter_mismatch,
        v_patient_target_count_mismatch,

        v_violation_count,
        v_lineage_complete;

END;
$$;


REVOKE ALL
ON FUNCTION ingest.evaluate_canonical_lineage(UUID)
FROM PUBLIC;


COMMENT ON FUNCTION
ingest.evaluate_canonical_lineage(UUID)
IS
'Least-privilege DQ-006 evidence interface. Returns aggregate canonical lineage integrity metrics for a completed synthea-patient v1 promotion without granting janus_quality_svc direct clinical access.';


-- ============================================================
-- 5. CONTROLLED POST-CANONICAL GATE WRITER
--
-- This is deliberately separate from V010's pre-canonical
-- writer.
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.write_postcanonical_lineage_decision(
    p_data_quality_run_id UUID,
    p_decision TEXT,
    p_reason TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest
AS $$
DECLARE
    v_decision_id UUID;

    v_status TEXT;
    v_ruleset_name TEXT;
    v_ruleset_version TEXT;
    v_rules_evaluated INTEGER;
    v_records_quarantined BIGINT;

    v_canonical_promotion_run_id UUID;

    v_result_count BIGINT;
    v_expected_result_count BIGINT;

    v_result_outcome TEXT;
    v_result_failed BIGINT;

    v_lineage_complete BOOLEAN;

    v_reason TEXT;
BEGIN

    IF session_user::TEXT <> 'janus_quality_svc' THEN
        RAISE EXCEPTION
            'Post-canonical lineage decisions may only be written by janus_quality_svc'
            USING ERRCODE = '42501';
    END IF;


    IF p_decision NOT IN ('pass', 'fail') THEN
        RAISE EXCEPTION
            'Post-canonical automatic decision must be pass or fail'
            USING ERRCODE = '42501';
    END IF;


    SELECT
        status,
        ruleset_name,
        ruleset_version,
        rules_evaluated,
        records_quarantined,
        canonical_promotion_run_id
    INTO
        v_status,
        v_ruleset_name,
        v_ruleset_version,
        v_rules_evaluated,
        v_records_quarantined,
        v_canonical_promotion_run_id
    FROM ingest.data_quality_run
    WHERE data_quality_run_id =
          p_data_quality_run_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown data-quality run: %',
            p_data_quality_run_id;
    END IF;


    IF EXISTS (
        SELECT 1
        FROM ingest.quality_gate_decision
        WHERE data_quality_run_id =
              p_data_quality_run_id
          AND decision IN ('pass', 'fail')
    ) THEN
        RAISE EXCEPTION
            'Automatic decision already exists for data-quality run %',
            p_data_quality_run_id;
    END IF;


    -- Runtime failure fails closed even if no rule result was
    -- successfully persisted.
    IF v_status = 'failed' THEN

        IF p_decision <> 'fail' THEN
            RAISE EXCEPTION
                'Failed post-canonical quality run may only receive fail'
                USING ERRCODE = '42501';
        END IF;

    ELSIF v_status = 'completed' THEN

        IF v_ruleset_name
                IS DISTINCT FROM
                'janus-postcanonical-lineage'
           OR v_ruleset_version
                IS DISTINCT FROM
                '1'
           OR v_rules_evaluated
                IS DISTINCT FROM
                1
           OR v_canonical_promotion_run_id
                IS NULL
        THEN
            RAISE EXCEPTION
                'Data-quality run does not match janus-postcanonical-lineage v1'
                USING ERRCODE = '42501';
        END IF;


        IF COALESCE(
            v_records_quarantined,
            0
        ) <> 0
        THEN
            RAISE EXCEPTION
                'Post-canonical lineage quality must not quarantine source records'
                USING ERRCODE = '42501';
        END IF;


        SELECT
            COUNT(*),
            COUNT(*) FILTER (
                WHERE q.rule_code =
                      'JANUS-DQ-006'
                  AND q.rule_version = 1
                  AND q.blocking IS TRUE
            ),
            MAX(r.outcome),
            MAX(r.records_failed)
        INTO
            v_result_count,
            v_expected_result_count,
            v_result_outcome,
            v_result_failed
        FROM ingest.data_quality_result r
        JOIN ingest.data_quality_rule q
          ON q.data_quality_rule_id =
             r.data_quality_rule_id
        WHERE r.data_quality_run_id =
              p_data_quality_run_id;


        IF v_result_count <> 1
           OR v_expected_result_count <> 1
        THEN
            RAISE EXCEPTION
                'Post-canonical lineage run must contain exactly one JANUS-DQ-006 v1 result'
                USING ERRCODE = '42501';
        END IF;


        -- Independently re-evaluate the current aggregate
        -- lineage evidence at decision time.
        SELECT e.lineage_complete
        INTO v_lineage_complete
        FROM ingest.evaluate_canonical_lineage(
            v_canonical_promotion_run_id
        ) e;


        IF p_decision = 'pass'
           AND (
                v_result_outcome
                    IS DISTINCT FROM
                    'pass'
                OR COALESCE(
                    v_result_failed,
                    0
                ) <> 0
                OR v_lineage_complete
                    IS NOT TRUE
           )
        THEN
            RAISE EXCEPTION
                'JANUS-DQ-006 evidence does not permit PASS'
                USING ERRCODE = '42501';
        END IF;


        IF p_decision = 'fail'
           AND (
                v_result_outcome
                    NOT IN ('fail', 'error')
                OR COALESCE(
                    v_result_failed,
                    0
                ) = 0
                OR v_lineage_complete
                    IS TRUE
           )
        THEN
            RAISE EXCEPTION
                'JANUS-DQ-006 evidence does not permit automatic FAIL'
                USING ERRCODE = '42501';
        END IF;

    ELSE

        RAISE EXCEPTION
            'Post-canonical data-quality run is not terminal'
            USING ERRCODE = '42501';

    END IF;


    v_reason :=
        NULLIF(
            btrim(p_reason),
            ''
        );


    IF v_reason IS NULL THEN
        v_reason :=
            CASE
                WHEN p_decision = 'pass'
                THEN
                    'JANUS-DQ-006 verified complete canonical lineage under janus-postcanonical-lineage v1.'
                ELSE
                    'JANUS-DQ-006 failed closed because canonical lineage integrity was incomplete or evaluation failed.'
            END;
    END IF;


    INSERT INTO ingest.quality_gate_decision (
        data_quality_run_id,
        decision,
        decided_by,
        decision_reason
    )
    VALUES (
        p_data_quality_run_id,
        p_decision,
        session_user::TEXT,
        v_reason
    )
    RETURNING quality_gate_decision_id
    INTO v_decision_id;


    RETURN v_decision_id;

END;
$$;


REVOKE ALL
ON FUNCTION
ingest.write_postcanonical_lineage_decision(
    UUID,
    TEXT,
    TEXT
)
FROM PUBLIC;


COMMENT ON FUNCTION
ingest.write_postcanonical_lineage_decision(
    UUID,
    TEXT,
    TEXT
)
IS
'Controlled automatic PASS/FAIL writer for janus-postcanonical-lineage v1. Only janus_quality_svc may certify JANUS-DQ-006.';


-- ============================================================
-- 6. EFFECTIVE POST-CANONICAL LINEAGE STATUS
-- ============================================================

CREATE OR REPLACE VIEW
ingest.v_postcanonical_lineage_gate_status
AS
SELECT
    r.data_quality_run_id,
    r.import_batch_id,
    r.canonical_promotion_run_id,

    r.status AS data_quality_run_status,

    r.ruleset_name,
    r.ruleset_version,

    r.rules_evaluated,
    r.rules_passed,
    r.rules_warned,
    r.rules_failed,

    r.records_evaluated,
    r.records_quarantined,

    dq006.result_count
        AS dq006_result_count,

    dq006.outcome
        AS dq006_outcome,

    dq006.records_failed
        AS dq006_records_failed,

    latest.quality_gate_decision_id,

    latest.decision
        AS latest_gate_decision,

    latest.decided_by,

    latest.decision_reason,

    latest.created_at
        AS gate_decided_at,

    CASE
        WHEN r.status = 'completed'

         AND r.ruleset_name =
             'janus-postcanonical-lineage'

         AND r.ruleset_version = '1'

         AND r.rules_evaluated = 1

         AND COALESCE(
             r.records_quarantined,
             0
         ) = 0

         -- Exactly one DQ-006 result must exist.
         AND dq006.result_count = 1

         AND dq006.outcome = 'pass'

         AND COALESCE(
             dq006.records_failed,
             0
         ) = 0

         AND latest.decision = 'pass'

         AND latest.decided_by =
             'janus_quality_svc'

        THEN TRUE
        ELSE FALSE
    END AS lineage_certified

FROM ingest.data_quality_run r


-- ------------------------------------------------------------
-- DQ-006 result evidence
--
-- data_quality_result has no created_at column.
-- Do not arbitrarily choose a result.
--
-- Aggregate the DQ-006 result set and require exactly one row
-- in the effective certification contract above.
-- ------------------------------------------------------------

LEFT JOIN LATERAL (
    SELECT
        COUNT(*) AS result_count,

        MAX(dqr.outcome)
            AS outcome,

        MAX(dqr.records_failed)
            AS records_failed

    FROM ingest.data_quality_result dqr

    JOIN ingest.data_quality_rule rule
      ON rule.data_quality_rule_id =
         dqr.data_quality_rule_id

    WHERE dqr.data_quality_run_id =
          r.data_quality_run_id

      AND rule.rule_code =
          'JANUS-DQ-006'

      AND rule.rule_version = 1

) dq006 ON TRUE


-- ------------------------------------------------------------
-- Latest gate decision
--
-- quality_gate_decision DOES carry created_at, so its existing
-- temporal ordering remains appropriate.
-- ------------------------------------------------------------

LEFT JOIN LATERAL (
    SELECT
        q.quality_gate_decision_id,
        q.decision,
        q.decided_by,
        q.decision_reason,
        q.created_at

    FROM ingest.quality_gate_decision q

    WHERE q.data_quality_run_id =
          r.data_quality_run_id

    ORDER BY
        q.created_at DESC,
        q.quality_gate_decision_id DESC

    LIMIT 1

) latest ON TRUE


WHERE r.canonical_promotion_run_id
      IS NOT NULL;


REVOKE ALL
ON ingest.v_postcanonical_lineage_gate_status
FROM
    PUBLIC,
    janus_ingest_rw,
    janus_etl_svc;


COMMENT ON VIEW
ingest.v_postcanonical_lineage_gate_status
IS
'Effective JANUS-DQ-006 certification state for canonical promotion runs. A promotion is lineage-certified only by a completed janus-postcanonical-lineage v1 PASS from janus_quality_svc.';


RESET ROLE;