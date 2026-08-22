-- ============================================================
-- JANUS
-- V024
-- Extend Post-Canonical Lineage Quality to Medication v1
--
-- Adds independent JANUS-DQ-006 evaluation for:
--
--     synthea-medication v1
--
-- Existing Patient, Provider, Encounter, and Condition
-- evaluators remain unchanged.
--
-- Quality receives no direct clinical access and no direct
-- canonical_promotion_run access.
--
-- Medication DQ-006 verifies:
--
--   * accepted medications.csv source coverage
--   * exactly one canonical Medication target per source
--   * exactly one governed source per Medication target
--   * no orphan Medication lineage
--   * certified Patient dependency
--   * certified Encounter dependency
--   * Medication.patient_id = Encounter.patient_id
--   * CODE and DESCRIPTION remain populated
--   * START remains populated
--   * STOP never precedes START
--   * start_at/end_at remain TIMESTAMPTZ
--   * no invented code_system
--   * no invented status
--   * no invented dose_text
--   * source/mapping/transformation/target contracts
--   * promotion counters reconcile
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. MEDICATION LINEAGE EVALUATOR
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.evaluate_medication_canonical_lineage(
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

    expected_medication_sources BIGINT,

    valid_medication_lineage_edges BIGINT,
    medication_lineage_sources BIGINT,
    medication_lineage_targets BIGINT,

    medication_sources_missing_lineage BIGINT,
    medication_sources_with_multiple_targets BIGINT,
    medication_targets_with_multiple_sources BIGINT,

    medication_orphan_targets BIGINT,

    medications_without_valid_patient BIGINT,
    medications_without_valid_encounter BIGINT,
    patient_encounter_mismatches BIGINT,

    medications_missing_code BIGINT,
    medications_missing_display BIGINT,
    medications_missing_start_at BIGINT,

    medication_temporal_violations BIGINT,
    temporal_column_contract_mismatch BIGINT,

    medications_with_unexpected_code_system BIGINT,
    medications_with_unexpected_status BIGINT,
    medications_with_unexpected_dose_text BIGINT,

    uncertified_patient_dependencies BIGINT,
    uncertified_encounter_dependencies BIGINT,

    wrong_source_artifact_edges BIGINT,
    wrong_mapping_version_edges BIGINT,
    wrong_transformation_edges BIGINT,
    unexpected_target_edges BIGINT,

    promotion_counter_mismatch BIGINT,
    medication_target_count_mismatch BIGINT,

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

    v_expected_medication_sources BIGINT;

    v_valid_medication_lineage_edges BIGINT;
    v_medication_lineage_sources BIGINT;
    v_medication_lineage_targets BIGINT;

    v_medication_sources_missing_lineage BIGINT;
    v_medication_sources_with_multiple_targets BIGINT;
    v_medication_targets_with_multiple_sources BIGINT;

    v_medication_orphan_targets BIGINT;

    v_medications_without_valid_patient BIGINT;
    v_medications_without_valid_encounter BIGINT;
    v_patient_encounter_mismatches BIGINT;

    v_medications_missing_code BIGINT;
    v_medications_missing_display BIGINT;
    v_medications_missing_start_at BIGINT;

    v_medication_temporal_violations BIGINT;
    v_temporal_column_contract_mismatch BIGINT;

    v_medications_with_unexpected_code_system BIGINT;
    v_medications_with_unexpected_status BIGINT;
    v_medications_with_unexpected_dose_text BIGINT;

    v_uncertified_patient_dependencies BIGINT;
    v_uncertified_encounter_dependencies BIGINT;

    v_wrong_source_artifact_edges BIGINT;
    v_wrong_mapping_version_edges BIGINT;
    v_wrong_transformation_edges BIGINT;
    v_unexpected_target_edges BIGINT;

    v_promotion_counter_mismatch BIGINT;
    v_medication_target_count_mismatch BIGINT;

    v_violation_count BIGINT;
    v_lineage_complete BOOLEAN;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_quality_svc' THEN
        RAISE EXCEPTION
            'Medication canonical lineage may only be evaluated by janus_quality_svc'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- PROMOTION CONTRACT
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


    IF v_mapping_name <> 'synthea-medication'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Medication DQ-006 v1 supports only synthea-medication v1'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- EXPECTED GOVERNED MEDICATION SOURCES
    -- ========================================================

    SELECT COUNT(*)
    INTO v_expected_medication_sources
    FROM ingest.source_record sr
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE sr.import_batch_id =
          v_import_batch_id
      AND sr.record_status =
          'accepted'
      AND sr.resource_type =
          'medications'
      AND sf.relative_path =
          'csv/medications.csv';


    -- ========================================================
    -- VALID MEDICATION LINEAGE
    -- ========================================================

    WITH valid_edges AS (
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
        JOIN clinical.medication m
          ON m.medication_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'medications'
          AND sf.relative_path =
              'csv/medications.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_medication'
          AND rl.transformation_version =
              '1'
    )
    SELECT
        COUNT(*),
        COUNT(DISTINCT source_record_id),
        COUNT(DISTINCT target_record_id)
    INTO
        v_valid_medication_lineage_edges,
        v_medication_lineage_sources,
        v_medication_lineage_targets
    FROM valid_edges;


    -- ========================================================
    -- EXPECTED SOURCES MISSING VALID LINEAGE
    -- ========================================================

    WITH expected_sources AS (
        SELECT
            sr.source_record_id
        FROM ingest.source_record sr
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'medications'
          AND sf.relative_path =
              'csv/medications.csv'
    ),
    covered_sources AS (
        SELECT DISTINCT
            rl.source_record_id
        FROM ingest.record_lineage rl
        JOIN clinical.medication m
          ON m.medication_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_medication'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_medication_sources_missing_lineage
    FROM expected_sources expected
    LEFT JOIN covered_sources covered
      ON covered.source_record_id =
         expected.source_record_id
    WHERE covered.source_record_id IS NULL;


    -- ========================================================
    -- ONE SOURCE -> AT MOST ONE MEDICATION TARGET
    -- ========================================================

    SELECT COUNT(*)
    INTO v_medication_sources_with_multiple_targets
    FROM (
        SELECT
            rl.source_record_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
        GROUP BY rl.source_record_id
        HAVING COUNT(
            DISTINCT rl.target_record_id
        ) > 1
    ) multiple_targets;


    -- ========================================================
    -- ONE MEDICATION TARGET <- AT MOST ONE SOURCE
    -- ========================================================

    SELECT COUNT(*)
    INTO v_medication_targets_with_multiple_sources
    FROM (
        SELECT
            rl.target_record_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
        GROUP BY rl.target_record_id
        HAVING COUNT(
            DISTINCT rl.source_record_id
        ) > 1
    ) multiple_sources;


    -- ========================================================
    -- ORPHAN MEDICATION TARGETS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_medication_orphan_targets
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.medication m
      ON m.medication_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'medication'
      AND m.medication_id IS NULL;


    -- ========================================================
    -- CANONICAL MEDICATION DEPENDENCY CONTRACT
    -- ========================================================

    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_without_valid_patient
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    LEFT JOIN clinical.patient p
      ON p.patient_id =
         m.patient_id
    WHERE p.patient_id IS NULL;


    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_without_valid_encounter
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    LEFT JOIN clinical.encounter e
      ON e.encounter_id =
         m.encounter_id
    WHERE e.encounter_id IS NULL;


    -- ========================================================
    -- PATIENT / ENCOUNTER CONSISTENCY
    -- ========================================================

    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_patient_encounter_mismatches
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    JOIN clinical.encounter e
      ON e.encounter_id =
         m.encounter_id
    WHERE m.patient_id
          IS DISTINCT FROM
          e.patient_id;


    -- ========================================================
    -- CODE / DISPLAY / START CONTRACT
    -- ========================================================

    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_missing_code
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE NULLIF(
        btrim(m.code),
        ''
    ) IS NULL;


    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_missing_display
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE NULLIF(
        btrim(m.display),
        ''
    ) IS NULL;


    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_missing_start_at
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE m.start_at IS NULL;


    -- ========================================================
    -- TEMPORAL VALUE CONTRACT
    -- ========================================================

    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medication_temporal_violations
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE m.end_at IS NOT NULL
      AND m.start_at IS NOT NULL
      AND m.end_at < m.start_at;


    -- ========================================================
    -- TEMPORAL SCHEMA CONTRACT
    --
    -- V022 corrected the canonical model specifically to avoid
    -- truncating source UTC timestamps into DATE values.
    -- DQ-006 makes that correction part of certification.
    -- ========================================================

    SELECT
        CASE
            WHEN COUNT(*) FILTER (
                WHERE a.attname IN (
                    'start_at',
                    'end_at'
                )
                  AND pg_catalog.format_type(
                      a.atttypid,
                      a.atttypmod
                  ) = 'timestamp with time zone'
            ) = 2
            THEN 0
            ELSE 1
        END
    INTO v_temporal_column_contract_mismatch
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c
      ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace n
      ON n.oid = c.relnamespace
    WHERE n.nspname = 'clinical'
      AND c.relname = 'medication'
      AND a.attnum > 0
      AND a.attisdropped IS FALSE
      AND a.attname IN (
          'start_at',
          'end_at'
      );


    -- ========================================================
    -- SOURCE DOES NOT PROVIDE THESE FACTS
    -- ========================================================

    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_with_unexpected_code_system
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE m.code_system IS NOT NULL;


    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_with_unexpected_status
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE m.status IS NOT NULL;


    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_medications_with_unexpected_dose_text
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE m.dose_text IS NOT NULL;


    -- ========================================================
    -- CERTIFIED PATIENT DEPENDENCY
    -- ========================================================

    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_uncertified_patient_dependencies
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM ingest.record_lineage patient_lineage
        JOIN ingest.canonical_promotion_run patient_run
          ON patient_run.canonical_promotion_run_id =
             patient_lineage.canonical_promotion_run_id
        JOIN ingest.v_postcanonical_lineage_gate_status patient_quality
          ON patient_quality.canonical_promotion_run_id =
             patient_run.canonical_promotion_run_id
        WHERE patient_lineage.target_schema =
              'clinical'
          AND patient_lineage.target_table =
              'patient'
          AND patient_lineage.target_record_id =
              m.patient_id
          AND patient_run.import_batch_id =
              v_import_batch_id
          AND patient_run.mapping_name =
              'synthea-patient'
          AND patient_run.mapping_version =
              '1'
          AND patient_run.status =
              'completed'
          AND patient_quality.lineage_certified
              IS TRUE
    );


    -- ========================================================
    -- CERTIFIED ENCOUNTER DEPENDENCY
    -- ========================================================

    WITH targets AS (
        SELECT DISTINCT
            rl.target_record_id AS medication_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'medication'
    )
    SELECT COUNT(*)
    INTO v_uncertified_encounter_dependencies
    FROM targets t
    JOIN clinical.medication m
      ON m.medication_id =
         t.medication_id
    WHERE NOT EXISTS (
        SELECT 1
        FROM ingest.record_lineage encounter_lineage
        JOIN ingest.canonical_promotion_run encounter_run
          ON encounter_run.canonical_promotion_run_id =
             encounter_lineage.canonical_promotion_run_id
        JOIN ingest.v_postcanonical_lineage_gate_status encounter_quality
          ON encounter_quality.canonical_promotion_run_id =
             encounter_run.canonical_promotion_run_id
        WHERE encounter_lineage.target_schema =
              'clinical'
          AND encounter_lineage.target_table =
              'encounter'
          AND encounter_lineage.target_record_id =
              m.encounter_id
          AND encounter_run.import_batch_id =
              v_import_batch_id
          AND encounter_run.mapping_name =
              'synthea-encounter'
          AND encounter_run.mapping_version =
              '1'
          AND encounter_run.status =
              'completed'
          AND encounter_quality.lineage_certified
              IS TRUE
    );


    -- ========================================================
    -- SOURCE ARTIFACT CONTRACT
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

         OR sr.record_status
                IS DISTINCT FROM
                'accepted'

         OR sr.resource_type
                IS DISTINCT FROM
                'medications'

         OR sf.relative_path
                IS DISTINCT FROM
                'csv/medications.csv'
      );


    -- ========================================================
    -- MAPPING VERSION CONTRACT
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
    -- TRANSFORMATION CONTRACT
    -- ========================================================

    SELECT COUNT(*)
    INTO v_wrong_transformation_edges
    FROM ingest.record_lineage rl
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND (
            rl.transformation_name
                IS DISTINCT FROM
                'janus.canonical.synthea_medication'

         OR rl.transformation_version
                IS DISTINCT FROM
                '1'
      );


    -- ========================================================
    -- TARGET CONTRACT
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

         OR rl.target_table
                IS DISTINCT FROM
                'medication'
      );


    -- ========================================================
    -- PROMOTION COUNTER RECONCILIATION
    -- ========================================================

    v_promotion_counter_mismatch :=
        CASE
            WHEN v_records_seen
                    IS DISTINCT FROM
                    v_expected_medication_sources

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


    v_medication_target_count_mismatch :=
        CASE
            WHEN v_medication_lineage_targets
                    IS DISTINCT FROM
                    v_expected_medication_sources
            THEN 1
            ELSE 0
        END;


    -- ========================================================
    -- FINAL VIOLATION AGGREGATION
    -- ========================================================

    v_violation_count :=
          v_medication_sources_missing_lineage
        + v_medication_sources_with_multiple_targets
        + v_medication_targets_with_multiple_sources

        + v_medication_orphan_targets

        + v_medications_without_valid_patient
        + v_medications_without_valid_encounter
        + v_patient_encounter_mismatches

        + v_medications_missing_code
        + v_medications_missing_display
        + v_medications_missing_start_at

        + v_medication_temporal_violations
        + v_temporal_column_contract_mismatch

        + v_medications_with_unexpected_code_system
        + v_medications_with_unexpected_status
        + v_medications_with_unexpected_dose_text

        + v_uncertified_patient_dependencies
        + v_uncertified_encounter_dependencies

        + v_wrong_source_artifact_edges
        + v_wrong_mapping_version_edges
        + v_wrong_transformation_edges
        + v_unexpected_target_edges

        + v_promotion_counter_mismatch
        + v_medication_target_count_mismatch;


    v_lineage_complete :=
        v_violation_count = 0

        AND v_expected_medication_sources > 0

        AND v_valid_medication_lineage_edges =
            v_expected_medication_sources

        AND v_medication_lineage_sources =
            v_expected_medication_sources

        AND v_medication_lineage_targets =
            v_expected_medication_sources;


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

        v_expected_medication_sources,

        v_valid_medication_lineage_edges,
        v_medication_lineage_sources,
        v_medication_lineage_targets,

        v_medication_sources_missing_lineage,
        v_medication_sources_with_multiple_targets,
        v_medication_targets_with_multiple_sources,

        v_medication_orphan_targets,

        v_medications_without_valid_patient,
        v_medications_without_valid_encounter,
        v_patient_encounter_mismatches,

        v_medications_missing_code,
        v_medications_missing_display,
        v_medications_missing_start_at,

        v_medication_temporal_violations,
        v_temporal_column_contract_mismatch,

        v_medications_with_unexpected_code_system,
        v_medications_with_unexpected_status,
        v_medications_with_unexpected_dose_text,

        v_uncertified_patient_dependencies,
        v_uncertified_encounter_dependencies,

        v_wrong_source_artifact_edges,
        v_wrong_mapping_version_edges,
        v_wrong_transformation_edges,
        v_unexpected_target_edges,

        v_promotion_counter_mismatch,
        v_medication_target_count_mismatch,

        v_violation_count,
        v_lineage_complete;

END;
$$;


REVOKE ALL
ON FUNCTION
ingest.evaluate_medication_canonical_lineage(UUID)
FROM PUBLIC;


COMMENT ON FUNCTION
ingest.evaluate_medication_canonical_lineage(UUID)
IS
'Least-privilege JANUS-DQ-006 evidence interface for synthea-medication v1. Verifies Medication lineage completeness, certified Patient and Encounter dependencies, Patient/Encounter consistency, code/display/start temporal contracts, TIMESTAMPTZ preservation, absence of invented code system/status/dose facts, artifact provenance, mapping/transformation contracts, and promotion counters without granting Quality direct clinical access.';


-- ============================================================
-- 2. EXTEND CONTROLLED POST-CANONICAL DECISION WRITER
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

    v_mapping_name TEXT;
    v_mapping_version TEXT;

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
                WHERE rule.rule_code =
                      'JANUS-DQ-006'
                  AND rule.rule_version = 1
                  AND rule.blocking IS TRUE
            ),
            MAX(result.outcome),
            MAX(result.records_failed)
        INTO
            v_result_count,
            v_expected_result_count,
            v_result_outcome,
            v_result_failed
        FROM ingest.data_quality_result result
        JOIN ingest.data_quality_rule rule
          ON rule.data_quality_rule_id =
             result.data_quality_rule_id
        WHERE result.data_quality_run_id =
              p_data_quality_run_id;


        IF v_result_count <> 1
           OR v_expected_result_count <> 1
        THEN
            RAISE EXCEPTION
                'Post-canonical lineage run must contain exactly one JANUS-DQ-006 v1 result'
                USING ERRCODE = '42501';
        END IF;


        SELECT
            cpr.mapping_name,
            cpr.mapping_version
        INTO
            v_mapping_name,
            v_mapping_version
        FROM ingest.canonical_promotion_run cpr
        WHERE cpr.canonical_promotion_run_id =
              v_canonical_promotion_run_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Canonical promotion bound to DQ run no longer exists'
                USING ERRCODE = '42501';
        END IF;


        IF v_mapping_name = 'synthea-patient'
           AND v_mapping_version = '1'
        THEN

            SELECT evidence.lineage_complete
            INTO v_lineage_complete
            FROM ingest.evaluate_canonical_lineage(
                v_canonical_promotion_run_id
            ) evidence;


        ELSIF v_mapping_name = 'synthea-provider'
              AND v_mapping_version = '1'
        THEN

            SELECT evidence.lineage_complete
            INTO v_lineage_complete
            FROM ingest.evaluate_provider_canonical_lineage(
                v_canonical_promotion_run_id
            ) evidence;


        ELSIF v_mapping_name = 'synthea-encounter'
              AND v_mapping_version = '1'
        THEN

            SELECT evidence.lineage_complete
            INTO v_lineage_complete
            FROM ingest.evaluate_encounter_canonical_lineage(
                v_canonical_promotion_run_id
            ) evidence;


        ELSIF v_mapping_name = 'synthea-condition'
              AND v_mapping_version = '1'
        THEN

            SELECT evidence.lineage_complete
            INTO v_lineage_complete
            FROM ingest.evaluate_condition_canonical_lineage(
                v_canonical_promotion_run_id
            ) evidence;


        ELSIF v_mapping_name = 'synthea-medication'
              AND v_mapping_version = '1'
        THEN

            SELECT evidence.lineage_complete
            INTO v_lineage_complete
            FROM ingest.evaluate_medication_canonical_lineage(
                v_canonical_promotion_run_id
            ) evidence;


        ELSE

            RAISE EXCEPTION
                'Unsupported mapping for JANUS-DQ-006 certification: % v%',
                v_mapping_name,
                v_mapping_version
                USING ERRCODE = '42501';

        END IF;


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
'Controlled JANUS-DQ-006 PASS/FAIL writer for janus-postcanonical-lineage v1. Independently re-evaluates the mapping-specific canonical lineage contract before certification. Supports synthea-patient v1, synthea-provider v1, synthea-encounter v1, synthea-condition v1, and synthea-medication v1.';


RESET ROLE;