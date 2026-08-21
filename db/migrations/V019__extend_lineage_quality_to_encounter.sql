-- ============================================================
-- JANUS
-- V019
-- Extend Post-Canonical Lineage Quality to Encounter v1
--
-- Adds independent JANUS-DQ-006 evaluation for:
--
--     synthea-encounter v1
--
-- Existing Patient and Provider lineage evaluators remain
-- unchanged.
--
-- Quality continues to receive no direct clinical access and
-- no direct canonical_promotion_run access.
--
-- Encounter DQ-006 verifies:
--
--   * one accepted encounters.csv source row per Encounter
--   * one Encounter lineage edge per source row
--   * one Encounter-Identifier lineage edge per source row
--   * no source-to-multiple-target ambiguity
--   * no target-to-multiple-source ambiguity
--   * Encounter Identifier belongs to the Encounter produced
--     from the same governed source row
--   * Encounter Identifier namespace/type/primary contract
--   * Patient dependency remains DQ-006 certified
--   * Provider dependency remains DQ-006 certified when present
--   * mapping/transformation/target contracts
--   * promotion counters
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. ENCOUNTER LINEAGE EVALUATOR
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.evaluate_encounter_canonical_lineage(
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

    expected_encounter_sources BIGINT,

    valid_encounter_lineage_edges BIGINT,
    encounter_lineage_sources BIGINT,
    encounter_lineage_targets BIGINT,

    valid_identifier_lineage_edges BIGINT,
    identifier_lineage_sources BIGINT,
    identifier_lineage_targets BIGINT,

    encounter_sources_missing_lineage BIGINT,
    encounter_sources_with_multiple_targets BIGINT,
    encounter_targets_with_multiple_sources BIGINT,

    identifier_sources_missing_lineage BIGINT,
    identifier_sources_with_multiple_targets BIGINT,
    identifier_targets_with_multiple_sources BIGINT,

    encounter_orphan_targets BIGINT,
    identifier_orphan_targets BIGINT,

    invalid_identifier_contract BIGINT,
    encounter_identifier_pair_mismatches BIGINT,

    encounters_with_provider BIGINT,

    uncertified_patient_dependencies BIGINT,
    uncertified_provider_dependencies BIGINT,

    wrong_source_artifact_edges BIGINT,
    wrong_mapping_version_edges BIGINT,
    wrong_transformation_edges BIGINT,
    unexpected_target_edges BIGINT,

    promotion_counter_mismatch BIGINT,
    encounter_target_count_mismatch BIGINT,
    identifier_target_count_mismatch BIGINT,

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

    v_expected_encounter_sources BIGINT;

    v_valid_encounter_lineage_edges BIGINT;
    v_encounter_lineage_sources BIGINT;
    v_encounter_lineage_targets BIGINT;

    v_valid_identifier_lineage_edges BIGINT;
    v_identifier_lineage_sources BIGINT;
    v_identifier_lineage_targets BIGINT;

    v_encounter_sources_missing_lineage BIGINT;
    v_encounter_sources_with_multiple_targets BIGINT;
    v_encounter_targets_with_multiple_sources BIGINT;

    v_identifier_sources_missing_lineage BIGINT;
    v_identifier_sources_with_multiple_targets BIGINT;
    v_identifier_targets_with_multiple_sources BIGINT;

    v_encounter_orphan_targets BIGINT;
    v_identifier_orphan_targets BIGINT;

    v_invalid_identifier_contract BIGINT;
    v_encounter_identifier_pair_mismatches BIGINT;

    v_encounters_with_provider BIGINT;

    v_uncertified_patient_dependencies BIGINT;
    v_uncertified_provider_dependencies BIGINT;

    v_wrong_source_artifact_edges BIGINT;
    v_wrong_mapping_version_edges BIGINT;
    v_wrong_transformation_edges BIGINT;
    v_unexpected_target_edges BIGINT;

    v_promotion_counter_mismatch BIGINT;
    v_encounter_target_count_mismatch BIGINT;
    v_identifier_target_count_mismatch BIGINT;

    v_violation_count BIGINT;
    v_lineage_complete BOOLEAN;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_quality_svc' THEN
        RAISE EXCEPTION
            'Encounter canonical lineage may only be evaluated by janus_quality_svc'
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


    IF v_mapping_name <> 'synthea-encounter'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Encounter DQ-006 v1 supports only synthea-encounter v1'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- EXPECTED GOVERNED ENCOUNTER SOURCES
    -- ========================================================

    SELECT COUNT(*)
    INTO v_expected_encounter_sources
    FROM ingest.source_record sr
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE sr.import_batch_id =
          v_import_batch_id
      AND sf.relative_path =
          'csv/encounters.csv'
      AND sr.resource_type =
          'encounters'
      AND sr.record_status =
          'accepted';


    -- ========================================================
    -- VALID ENCOUNTER LINEAGE
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
        JOIN clinical.encounter e
          ON e.encounter_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'encounters'
          AND sf.relative_path =
              'csv/encounters.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
    )
    SELECT
        COUNT(*),
        COUNT(DISTINCT source_record_id),
        COUNT(DISTINCT target_record_id)
    INTO
        v_valid_encounter_lineage_edges,
        v_encounter_lineage_sources,
        v_encounter_lineage_targets
    FROM valid_edges;


    -- ========================================================
    -- VALID ENCOUNTER IDENTIFIER LINEAGE
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
        JOIN clinical.encounter_identifier ei
          ON ei.encounter_identifier_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'encounters'
          AND sf.relative_path =
              'csv/encounters.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter_identifier'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter_identifier'
          AND rl.transformation_version =
              '1'
    )
    SELECT
        COUNT(*),
        COUNT(DISTINCT source_record_id),
        COUNT(DISTINCT target_record_id)
    INTO
        v_valid_identifier_lineage_edges,
        v_identifier_lineage_sources,
        v_identifier_lineage_targets
    FROM valid_edges;


    -- ========================================================
    -- ENCOUNTER SOURCES MISSING LINEAGE
    -- ========================================================

    WITH expected_sources AS (
        SELECT sr.source_record_id
        FROM ingest.source_record sr
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'encounters'
          AND sf.relative_path =
              'csv/encounters.csv'
    ),
    covered_sources AS (
        SELECT DISTINCT
            rl.source_record_id
        FROM ingest.record_lineage rl
        JOIN clinical.encounter e
          ON e.encounter_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_encounter_sources_missing_lineage
    FROM expected_sources expected
    LEFT JOIN covered_sources covered
      ON covered.source_record_id =
         expected.source_record_id
    WHERE covered.source_record_id IS NULL;


    -- ========================================================
    -- IDENTIFIER SOURCES MISSING LINEAGE
    -- ========================================================

    WITH expected_sources AS (
        SELECT sr.source_record_id
        FROM ingest.source_record sr
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'encounters'
          AND sf.relative_path =
              'csv/encounters.csv'
    ),
    covered_sources AS (
        SELECT DISTINCT
            rl.source_record_id
        FROM ingest.record_lineage rl
        JOIN clinical.encounter_identifier ei
          ON ei.encounter_identifier_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter_identifier'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter_identifier'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_identifier_sources_missing_lineage
    FROM expected_sources expected
    LEFT JOIN covered_sources covered
      ON covered.source_record_id =
         expected.source_record_id
    WHERE covered.source_record_id IS NULL;


    -- ========================================================
    -- ONE SOURCE -> AT MOST ONE ENCOUNTER TARGET
    -- ========================================================

    SELECT COUNT(*)
    INTO v_encounter_sources_with_multiple_targets
    FROM (
        SELECT
            rl.source_record_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
          AND rl.mapping_version =
              v_mapping_version
        GROUP BY rl.source_record_id
        HAVING COUNT(
            DISTINCT rl.target_record_id
        ) > 1
    ) multiple_targets;


    -- ========================================================
    -- ONE SOURCE -> AT MOST ONE IDENTIFIER TARGET
    -- ========================================================

    SELECT COUNT(*)
    INTO v_identifier_sources_with_multiple_targets
    FROM (
        SELECT
            rl.source_record_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter_identifier'
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter_identifier'
          AND rl.transformation_version =
              '1'
          AND rl.mapping_version =
              v_mapping_version
        GROUP BY rl.source_record_id
        HAVING COUNT(
            DISTINCT rl.target_record_id
        ) > 1
    ) multiple_targets;


    -- ========================================================
    -- ONE ENCOUNTER TARGET <- AT MOST ONE SOURCE
    -- ========================================================

    SELECT COUNT(*)
    INTO v_encounter_targets_with_multiple_sources
    FROM (
        SELECT
            rl.target_record_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
          AND rl.mapping_version =
              v_mapping_version
        GROUP BY rl.target_record_id
        HAVING COUNT(
            DISTINCT rl.source_record_id
        ) > 1
    ) multiple_sources;


    -- ========================================================
    -- ONE IDENTIFIER TARGET <- AT MOST ONE SOURCE
    -- ========================================================

    SELECT COUNT(*)
    INTO v_identifier_targets_with_multiple_sources
    FROM (
        SELECT
            rl.target_record_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter_identifier'
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter_identifier'
          AND rl.transformation_version =
              '1'
          AND rl.mapping_version =
              v_mapping_version
        GROUP BY rl.target_record_id
        HAVING COUNT(
            DISTINCT rl.source_record_id
        ) > 1
    ) multiple_sources;


    -- ========================================================
    -- ORPHAN ENCOUNTER TARGETS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_encounter_orphan_targets
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.encounter e
      ON e.encounter_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'encounter'
      AND rl.transformation_name =
          'janus.canonical.synthea_encounter'
      AND e.encounter_id IS NULL;


    -- ========================================================
    -- ORPHAN IDENTIFIER TARGETS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_identifier_orphan_targets
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.encounter_identifier ei
      ON ei.encounter_identifier_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'encounter_identifier'
      AND rl.transformation_name =
          'janus.canonical.synthea_encounter_identifier'
      AND ei.encounter_identifier_id IS NULL;


    -- ========================================================
    -- IDENTIFIER CONTRACT
    -- ========================================================

    SELECT COUNT(*)
    INTO v_invalid_identifier_contract
    FROM ingest.record_lineage rl
    JOIN clinical.encounter_identifier ei
      ON ei.encounter_identifier_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'encounter_identifier'
      AND rl.transformation_name =
          'janus.canonical.synthea_encounter_identifier'
      AND (
            ei.identifier_system
                IS DISTINCT FROM
                'urn:janus:source:synthea:encounter-id'

         OR ei.identifier_type
                IS DISTINCT FROM
                'synthea_encounter_id'

         OR ei.is_primary
                IS DISTINCT FROM
                TRUE
      );


    -- ========================================================
    -- ENCOUNTER / IDENTIFIER SAME-SOURCE PAIRING
    --
    -- The Encounter Identifier produced from a source row must
    -- belong to the Encounter produced from that SAME source
    -- row.
    -- ========================================================

    WITH encounter_edges AS (
        SELECT
            rl.source_record_id,
            rl.target_record_id AS encounter_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
    ),
    identifier_edges AS (
        SELECT
            rl.source_record_id,
            rl.target_record_id
                AS encounter_identifier_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter_identifier'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter_identifier'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_encounter_identifier_pair_mismatches
    FROM encounter_edges encounter_edge
    JOIN identifier_edges identifier_edge
      ON identifier_edge.source_record_id =
         encounter_edge.source_record_id
    JOIN clinical.encounter_identifier ei
      ON ei.encounter_identifier_id =
         identifier_edge.encounter_identifier_id
    WHERE ei.encounter_id
          IS DISTINCT FROM
          encounter_edge.encounter_id;


    -- ========================================================
    -- ENCOUNTERS WITH PROVIDER
    -- ========================================================

    WITH encounter_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS encounter_id
        FROM ingest.record_lineage rl
        JOIN clinical.encounter e
          ON e.encounter_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_encounters_with_provider
    FROM encounter_targets targets
    JOIN clinical.encounter e
      ON e.encounter_id =
         targets.encounter_id
    WHERE e.provider_id IS NOT NULL;


    -- ========================================================
    -- CERTIFIED PATIENT DEPENDENCY
    --
    -- Every Encounter Patient must remain backed by a completed
    -- and DQ-006-certified synthea-patient v1 promotion for
    -- this same import batch.
    -- ========================================================

    WITH encounter_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS encounter_id
        FROM ingest.record_lineage rl
        JOIN clinical.encounter e
          ON e.encounter_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_uncertified_patient_dependencies
    FROM encounter_targets targets
    JOIN clinical.encounter e
      ON e.encounter_id =
         targets.encounter_id
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
              e.patient_id
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
    -- CERTIFIED PROVIDER DEPENDENCY
    --
    -- Provider is nullable, so only populated Provider
    -- dependencies require certification.
    -- ========================================================

    WITH encounter_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS encounter_id
        FROM ingest.record_lineage rl
        JOIN clinical.encounter e
          ON e.encounter_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_encounter'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_uncertified_provider_dependencies
    FROM encounter_targets targets
    JOIN clinical.encounter e
      ON e.encounter_id =
         targets.encounter_id
    WHERE e.provider_id IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM ingest.record_lineage provider_lineage
        JOIN ingest.canonical_promotion_run provider_run
          ON provider_run.canonical_promotion_run_id =
             provider_lineage.canonical_promotion_run_id
        JOIN ingest.v_postcanonical_lineage_gate_status provider_quality
          ON provider_quality.canonical_promotion_run_id =
             provider_run.canonical_promotion_run_id
        WHERE provider_lineage.target_schema =
              'clinical'
          AND provider_lineage.target_table =
              'provider'
          AND provider_lineage.target_record_id =
              e.provider_id
          AND provider_run.import_batch_id =
              v_import_batch_id
          AND provider_run.mapping_name =
              'synthea-provider'
          AND provider_run.mapping_version =
              '1'
          AND provider_run.status =
              'completed'
          AND provider_quality.lineage_certified
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
                'encounters'

         OR sf.relative_path
                IS DISTINCT FROM
                'csv/encounters.csv'
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
      AND NOT (
            (
                rl.transformation_name =
                    'janus.canonical.synthea_encounter'
                AND rl.transformation_version =
                    '1'
            )
         OR (
                rl.transformation_name =
                    'janus.canonical.synthea_encounter_identifier'
                AND rl.transformation_version =
                    '1'
            )
      );


    -- ========================================================
    -- TARGET CONTRACT
    -- ========================================================

    SELECT COUNT(*)
    INTO v_unexpected_target_edges
    FROM ingest.record_lineage rl
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND NOT (
            (
                rl.target_schema =
                    'clinical'
                AND rl.target_table =
                    'encounter'
                AND rl.transformation_name =
                    'janus.canonical.synthea_encounter'
            )
         OR (
                rl.target_schema =
                    'clinical'
                AND rl.target_table =
                    'encounter_identifier'
                AND rl.transformation_name =
                    'janus.canonical.synthea_encounter_identifier'
            )
      );


    -- ========================================================
    -- PROMOTION COUNTER RECONCILIATION
    -- ========================================================

    v_promotion_counter_mismatch :=
        CASE
            WHEN v_records_seen
                    IS DISTINCT FROM
                    v_expected_encounter_sources

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


    v_encounter_target_count_mismatch :=
        CASE
            WHEN v_encounter_lineage_targets
                    IS DISTINCT FROM
                    v_expected_encounter_sources
            THEN 1
            ELSE 0
        END;


    v_identifier_target_count_mismatch :=
        CASE
            WHEN v_identifier_lineage_targets
                    IS DISTINCT FROM
                    v_expected_encounter_sources
            THEN 1
            ELSE 0
        END;


    -- ========================================================
    -- FINAL VIOLATION AGGREGATION
    -- ========================================================

    v_violation_count :=
          v_encounter_sources_missing_lineage
        + v_encounter_sources_with_multiple_targets
        + v_encounter_targets_with_multiple_sources

        + v_identifier_sources_missing_lineage
        + v_identifier_sources_with_multiple_targets
        + v_identifier_targets_with_multiple_sources

        + v_encounter_orphan_targets
        + v_identifier_orphan_targets

        + v_invalid_identifier_contract
        + v_encounter_identifier_pair_mismatches

        + v_uncertified_patient_dependencies
        + v_uncertified_provider_dependencies

        + v_wrong_source_artifact_edges
        + v_wrong_mapping_version_edges
        + v_wrong_transformation_edges
        + v_unexpected_target_edges

        + v_promotion_counter_mismatch
        + v_encounter_target_count_mismatch
        + v_identifier_target_count_mismatch;


    v_lineage_complete :=
        v_violation_count = 0

        AND v_expected_encounter_sources > 0

        AND v_valid_encounter_lineage_edges =
            v_expected_encounter_sources

        AND v_encounter_lineage_sources =
            v_expected_encounter_sources

        AND v_encounter_lineage_targets =
            v_expected_encounter_sources

        AND v_valid_identifier_lineage_edges =
            v_expected_encounter_sources

        AND v_identifier_lineage_sources =
            v_expected_encounter_sources

        AND v_identifier_lineage_targets =
            v_expected_encounter_sources;


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

        v_expected_encounter_sources,

        v_valid_encounter_lineage_edges,
        v_encounter_lineage_sources,
        v_encounter_lineage_targets,

        v_valid_identifier_lineage_edges,
        v_identifier_lineage_sources,
        v_identifier_lineage_targets,

        v_encounter_sources_missing_lineage,
        v_encounter_sources_with_multiple_targets,
        v_encounter_targets_with_multiple_sources,

        v_identifier_sources_missing_lineage,
        v_identifier_sources_with_multiple_targets,
        v_identifier_targets_with_multiple_sources,

        v_encounter_orphan_targets,
        v_identifier_orphan_targets,

        v_invalid_identifier_contract,
        v_encounter_identifier_pair_mismatches,

        v_encounters_with_provider,

        v_uncertified_patient_dependencies,
        v_uncertified_provider_dependencies,

        v_wrong_source_artifact_edges,
        v_wrong_mapping_version_edges,
        v_wrong_transformation_edges,
        v_unexpected_target_edges,

        v_promotion_counter_mismatch,
        v_encounter_target_count_mismatch,
        v_identifier_target_count_mismatch,

        v_violation_count,
        v_lineage_complete;

END;
$$;


REVOKE ALL
ON FUNCTION
ingest.evaluate_encounter_canonical_lineage(UUID)
FROM PUBLIC;


COMMENT ON FUNCTION
ingest.evaluate_encounter_canonical_lineage(UUID)
IS
'Least-privilege JANUS-DQ-006 evidence interface for synthea-encounter v1. Verifies dual-target Encounter lineage, Encounter-Identifier identity contract and pairing, certified Patient/Provider dependencies, artifact provenance, transformation contracts, target contracts, and promotion counters without granting Quality direct clinical access.';


-- ============================================================
-- 2. EXTEND CONTROLLED POST-CANONICAL DECISION WRITER
--
-- Patient and Provider branches remain unchanged.
-- Encounter v1 is added as an additional supported mapping.
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


        -- ----------------------------------------------------
        -- Independent evidence re-evaluation at decision time.
        -- ----------------------------------------------------

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
'Controlled JANUS-DQ-006 PASS/FAIL writer for janus-postcanonical-lineage v1. Independently re-evaluates the mapping-specific canonical lineage contract before certification. Supports synthea-patient v1, synthea-provider v1, and synthea-encounter v1.';


RESET ROLE;