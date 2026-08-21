-- ============================================================
-- JANUS
-- V023
-- Controlled Synthea Medication Promotion v1
--
-- Source:
--     csv/medications.csv
--
-- Mapping:
--
-- PATIENT
--   -> certified canonical Patient
--   -> clinical.medication.patient_id
--
-- ENCOUNTER
--   -> certified canonical Encounter
--   -> clinical.medication.encounter_id
--
-- CODE
--   -> clinical.medication.code
--
-- DESCRIPTION
--   -> clinical.medication.display
--
-- START
--   -> clinical.medication.start_at
--
-- STOP
--   -> clinical.medication.end_at
--
-- Source does NOT provide an explicit terminology system,
-- medication status, or dose text.
--
-- Therefore v1 MUST preserve:
--
--     code_system = NULL
--     status      = NULL
--     dose_text   = NULL
--
-- v1 intentionally does NOT promote:
--
--     PAYER
--     BASE_COST
--     PAYER_COVERAGE
--     DISPENSES
--     TOTALCOST
--     REASONCODE
--     REASONDESCRIPTION
--
-- medications.csv contains no Medication Id.
-- No external Medication identifier is fabricated.
--
-- Governed identity:
--
-- source_record_id + payload_sha256
--     -> record_lineage
--     -> clinical.medication.medication_id
--
-- Dependencies:
--
-- Patient and Encounter must originate from independently
-- JANUS-DQ-006-certified promotions for the SAME import batch.
--
-- Cross-entity invariant:
--
-- resolved Encounter.patient_id MUST equal the independently
-- resolved source PATIENT.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. CONTROLLED SYNTHEA MEDICATION WRITER
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.promote_synthea_medication_v1(
    p_canonical_promotion_run_id UUID,

    p_source_record_id UUID,
    p_payload_sha256 TEXT,

    p_synthea_patient_id TEXT,
    p_synthea_encounter_id TEXT,

    p_start_at TIMESTAMPTZ,
    p_end_at TIMESTAMPTZ,

    p_code TEXT,
    p_description TEXT
)
RETURNS TABLE (
    canonical_medication_id UUID,
    medication_created BOOLEAN,
    lineage_edges_created INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest, clinical
AS $$
DECLARE
    -- Promotion evidence
    v_import_batch_id UUID;
    v_data_quality_run_id UUID;
    v_quality_gate_decision_id UUID;

    v_mapping_name TEXT;
    v_mapping_version TEXT;
    v_promotion_status TEXT;

    -- Source evidence
    v_source_batch_id UUID;
    v_source_status TEXT;
    v_source_hash TEXT;
    v_source_path TEXT;
    v_resource_type TEXT;

    -- Normalized source IDs
    v_synthea_patient_id TEXT;
    v_synthea_encounter_id TEXT;

    -- Canonical dependencies
    v_patient_id UUID;
    v_encounter_id UUID;
    v_encounter_patient_id UUID;

    -- Clinical values
    v_code TEXT;
    v_display TEXT;

    -- Canonical target
    v_medication_id UUID;

    -- Existing source-record identity
    v_existing_target_count BIGINT;

    -- Existing canonical values
    v_existing_patient_id UUID;
    v_existing_encounter_id UUID;
    v_existing_code_system TEXT;
    v_existing_code TEXT;
    v_existing_display TEXT;
    v_existing_status TEXT;
    v_existing_start_at TIMESTAMPTZ;
    v_existing_end_at TIMESTAMPTZ;
    v_existing_dose_text TEXT;

    -- Existing lineage contract
    v_existing_transformation_name TEXT;
    v_existing_transformation_version TEXT;
    v_existing_mapping_version TEXT;

    v_medication_created BOOLEAN := FALSE;

    v_lineage_edges_created INTEGER := 0;
    v_row_count INTEGER;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Synthea Medication promotion may only be executed by janus_canonical_svc'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- PROMOTION CONTRACT
    -- ========================================================

    SELECT
        cpr.import_batch_id,
        cpr.data_quality_run_id,
        cpr.quality_gate_decision_id,
        cpr.mapping_name,
        cpr.mapping_version,
        cpr.status
    INTO
        v_import_batch_id,
        v_data_quality_run_id,
        v_quality_gate_decision_id,
        v_mapping_name,
        v_mapping_version,
        v_promotion_status
    FROM ingest.canonical_promotion_run cpr
    WHERE cpr.canonical_promotion_run_id =
          p_canonical_promotion_run_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown canonical promotion run: %',
            p_canonical_promotion_run_id;
    END IF;


    IF v_promotion_status <> 'running' THEN
        RAISE EXCEPTION
            'Synthea Medication promotion requires a running canonical promotion'
            USING ERRCODE = '42501';
    END IF;


    IF v_mapping_name <> 'synthea-medication'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Canonical promotion must use synthea-medication v1'
            USING ERRCODE = '42501';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM ingest.v_quality_gate_effective_status q
        WHERE q.data_quality_run_id =
              v_data_quality_run_id
          AND q.quality_gate_decision_id =
              v_quality_gate_decision_id
          AND q.gate_allows_promotion IS TRUE
    ) THEN
        RAISE EXCEPTION
            'Canonical promotion quality authorization is not effective'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- SOURCE RECORD CONTRACT
    -- ========================================================

    IF NULLIF(
        btrim(p_payload_sha256),
        ''
    ) IS NULL
    THEN
        RAISE EXCEPTION
            'Medication source payload SHA-256 is required';
    END IF;


    SELECT
        sr.import_batch_id,
        sr.record_status,
        sr.payload_sha256,
        sf.relative_path,
        sr.resource_type
    INTO
        v_source_batch_id,
        v_source_status,
        v_source_hash,
        v_source_path,
        v_resource_type
    FROM ingest.source_record sr
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE sr.source_record_id =
          p_source_record_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown Medication source record: %',
            p_source_record_id;
    END IF;


    IF v_source_batch_id
        IS DISTINCT FROM
        v_import_batch_id
    THEN
        RAISE EXCEPTION
            'Medication source record does not belong to promotion import batch'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_status <> 'accepted' THEN
        RAISE EXCEPTION
            'Medication source record must be accepted'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_path
            IS DISTINCT FROM
            'csv/medications.csv'
       OR v_resource_type
            IS DISTINCT FROM
            'medications'
    THEN
        RAISE EXCEPTION
            'Medication source record must originate from csv/medications.csv'
            USING ERRCODE = '42501';
    END IF;


    IF lower(
        btrim(p_payload_sha256)
    )
       IS DISTINCT FROM
       lower(
           btrim(v_source_hash)
       )
    THEN
        RAISE EXCEPTION
            'Medication source payload SHA-256 does not match persisted evidence'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- NORMALIZE + RESOLVE PATIENT
    -- ========================================================

    IF NULLIF(
        btrim(p_synthea_patient_id),
        ''
    ) IS NULL
    THEN
        RAISE EXCEPTION
            'Synthea Medication PATIENT is required';
    END IF;


    v_synthea_patient_id :=
        lower(
            (
                btrim(
                    p_synthea_patient_id
                )::UUID
            )::TEXT
        );


    SELECT
        pi.patient_id
    INTO
        v_patient_id
    FROM clinical.patient_identifier pi
    WHERE pi.identifier_system =
          'urn:janus:source:synthea:patient-id'
      AND pi.identifier_value =
          v_synthea_patient_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Synthea Medication PATIENT does not resolve to a canonical Patient: %',
            v_synthea_patient_id
            USING ERRCODE = '23503';
    END IF;


    -- ========================================================
    -- REQUIRE CERTIFIED PATIENT DEPENDENCY
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM ingest.record_lineage rl
        JOIN ingest.canonical_promotion_run upstream
          ON upstream.canonical_promotion_run_id =
             rl.canonical_promotion_run_id
        JOIN ingest.v_postcanonical_lineage_gate_status quality
          ON quality.canonical_promotion_run_id =
             upstream.canonical_promotion_run_id
        WHERE rl.target_schema =
              'clinical'
          AND rl.target_table =
              'patient'
          AND rl.target_record_id =
              v_patient_id
          AND upstream.import_batch_id =
              v_import_batch_id
          AND upstream.mapping_name =
              'synthea-patient'
          AND upstream.mapping_version =
              '1'
          AND upstream.status =
              'completed'
          AND quality.lineage_certified IS TRUE
    ) THEN
        RAISE EXCEPTION
            'Resolved Patient is not backed by a certified synthea-patient v1 promotion for this import batch'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- NORMALIZE + RESOLVE ENCOUNTER
    -- ========================================================

    IF NULLIF(
        btrim(p_synthea_encounter_id),
        ''
    ) IS NULL
    THEN
        RAISE EXCEPTION
            'Synthea Medication ENCOUNTER is required';
    END IF;


    v_synthea_encounter_id :=
        lower(
            (
                btrim(
                    p_synthea_encounter_id
                )::UUID
            )::TEXT
        );


    SELECT
        e.encounter_id,
        e.patient_id
    INTO
        v_encounter_id,
        v_encounter_patient_id
    FROM clinical.encounter_identifier ei
    JOIN clinical.encounter e
      ON e.encounter_id =
         ei.encounter_id
    WHERE ei.identifier_system =
          'urn:janus:source:synthea:encounter-id'
      AND ei.identifier_value =
          v_synthea_encounter_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Synthea Medication ENCOUNTER does not resolve to a canonical Encounter: %',
            v_synthea_encounter_id
            USING ERRCODE = '23503';
    END IF;


    -- ========================================================
    -- REQUIRE CERTIFIED ENCOUNTER DEPENDENCY
    -- ========================================================

    IF NOT EXISTS (
        SELECT 1
        FROM ingest.record_lineage rl
        JOIN ingest.canonical_promotion_run upstream
          ON upstream.canonical_promotion_run_id =
             rl.canonical_promotion_run_id
        JOIN ingest.v_postcanonical_lineage_gate_status quality
          ON quality.canonical_promotion_run_id =
             upstream.canonical_promotion_run_id
        WHERE rl.target_schema =
              'clinical'
          AND rl.target_table =
              'encounter'
          AND rl.target_record_id =
              v_encounter_id
          AND upstream.import_batch_id =
              v_import_batch_id
          AND upstream.mapping_name =
              'synthea-encounter'
          AND upstream.mapping_version =
              '1'
          AND upstream.status =
              'completed'
          AND quality.lineage_certified IS TRUE
    ) THEN
        RAISE EXCEPTION
            'Resolved Encounter is not backed by a certified synthea-encounter v1 promotion for this import batch'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- PATIENT / ENCOUNTER CONSISTENCY
    -- ========================================================

    IF v_encounter_patient_id
        IS DISTINCT FROM
        v_patient_id
    THEN
        RAISE EXCEPTION
            'Medication PATIENT does not match resolved Encounter.patient_id'
            USING ERRCODE = '23514';
    END IF;


    -- ========================================================
    -- TEMPORAL CONTRACT
    -- ========================================================

    IF p_start_at IS NULL THEN
        RAISE EXCEPTION
            'Medication START is required';
    END IF;


    IF p_end_at IS NOT NULL
       AND p_end_at < p_start_at
    THEN
        RAISE EXCEPTION
            'Medication STOP may not precede START'
            USING ERRCODE = '23514';
    END IF;


    -- ========================================================
    -- CLINICAL VALUE CONTRACT
    -- ========================================================

    v_code :=
        NULLIF(
            btrim(p_code),
            ''
        );

    v_display :=
        NULLIF(
            btrim(p_description),
            ''
        );


    IF v_code IS NULL THEN
        RAISE EXCEPTION
            'Medication CODE is required';
    END IF;


    IF v_display IS NULL THEN
        RAISE EXCEPTION
            'Medication DESCRIPTION is required';
    END IF;


    -- ========================================================
    -- SERIALIZE GOVERNED SOURCE-RECORD IDENTITY
    --
    -- medications.csv has no external Medication Id.
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'janus:synthea-medication:source-record:'
            || p_source_record_id::TEXT,
            0
        )
    );


    -- ========================================================
    -- RESOLVE EXISTING MEDICATION FOR THIS SOURCE RECORD
    -- ========================================================

    SELECT
        COUNT(
            DISTINCT rl.target_record_id
        )
    INTO
        v_existing_target_count
    FROM ingest.record_lineage rl
    WHERE rl.source_record_id =
          p_source_record_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'medication';


    IF v_existing_target_count > 1 THEN
        RAISE EXCEPTION
            'Medication source record resolves to multiple canonical Medication targets'
            USING ERRCODE = '23505';
    END IF;


    SELECT
        rl.target_record_id,
        rl.transformation_name,
        rl.transformation_version,
        rl.mapping_version
    INTO
        v_medication_id,
        v_existing_transformation_name,
        v_existing_transformation_version,
        v_existing_mapping_version
    FROM ingest.record_lineage rl
    WHERE rl.source_record_id =
          p_source_record_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'medication'
    LIMIT 1;


    IF FOUND THEN

        IF v_existing_transformation_name
                IS DISTINCT FROM
                'janus.canonical.synthea_medication'
           OR v_existing_transformation_version
                IS DISTINCT FROM
                '1'
           OR v_existing_mapping_version
                IS DISTINCT FROM
                '1'
        THEN
            RAISE EXCEPTION
                'Existing Medication lineage uses an incompatible mapping contract'
                USING ERRCODE = '23505';
        END IF;


        SELECT
            m.patient_id,
            m.encounter_id,
            m.code_system,
            m.code,
            m.display,
            m.status,
            m.start_at,
            m.end_at,
            m.dose_text
        INTO
            v_existing_patient_id,
            v_existing_encounter_id,
            v_existing_code_system,
            v_existing_code,
            v_existing_display,
            v_existing_status,
            v_existing_start_at,
            v_existing_end_at,
            v_existing_dose_text
        FROM clinical.medication m
        WHERE m.medication_id =
              v_medication_id
        FOR UPDATE;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Existing Medication lineage target does not resolve to clinical.medication'
                USING ERRCODE = '23503';
        END IF;


        -- ====================================================
        -- IDEMPOTENT / FAIL-CLOSED REPLAY
        -- ====================================================

        IF v_existing_patient_id
                IS DISTINCT FROM
                v_patient_id

           OR v_existing_encounter_id
                IS DISTINCT FROM
                v_encounter_id

           -- Source does not provide a terminology system.
           OR v_existing_code_system
                IS NOT NULL

           OR v_existing_code
                IS DISTINCT FROM
                v_code

           OR v_existing_display
                IS DISTINCT FROM
                v_display

           -- Source does not provide status.
           OR v_existing_status
                IS NOT NULL

           OR v_existing_start_at
                IS DISTINCT FROM
                p_start_at

           OR v_existing_end_at
                IS DISTINCT FROM
                p_end_at

           -- Source does not provide dose text.
           OR v_existing_dose_text
                IS NOT NULL
        THEN
            RAISE EXCEPTION
                'Existing canonical Medication conflicts with synthea-medication v1 source facts'
                USING ERRCODE = '23505';
        END IF;


        v_medication_created := FALSE;


    ELSE

        -- ====================================================
        -- CREATE CANONICAL MEDICATION
        -- ====================================================

        INSERT INTO clinical.medication (
            patient_id,
            encounter_id,
            code_system,
            code,
            display,
            status,
            start_at,
            end_at,
            dose_text
        )
        VALUES (
            v_patient_id,
            v_encounter_id,
            NULL,
            v_code,
            v_display,
            NULL,
            p_start_at,
            p_end_at,
            NULL
        )
        RETURNING medication_id
        INTO v_medication_id;


        v_medication_created := TRUE;

    END IF;


    -- ========================================================
    -- MEDICATION LINEAGE
    -- ========================================================

    INSERT INTO ingest.record_lineage (
        source_record_id,
        target_schema,
        target_table,
        target_record_id,
        transformation_name,
        transformation_version,
        mapping_version,
        transformation_details,
        canonical_promotion_run_id
    )
    VALUES (
        p_source_record_id,
        'clinical',
        'medication',
        v_medication_id,
        'janus.canonical.synthea_medication',
        '1',
        '1',
        jsonb_build_object(
            'source_artifact',
                'csv/medications.csv',

            'mapped_fields',
                jsonb_build_array(
                    'PATIENT',
                    'ENCOUNTER',
                    'CODE',
                    'DESCRIPTION',
                    'START',
                    'STOP'
                ),

            'patient_resolution',
                'urn:janus:source:synthea:patient-id',

            'encounter_resolution',
                'urn:janus:source:synthea:encounter-id',

            'patient_encounter_match_required',
                TRUE,

            'source_temporal_precision',
                'timestamp_with_timezone',

            'code_system_mapped',
                FALSE,

            'status_mapped',
                FALSE,

            'dose_text_mapped',
                FALSE,

            'payer_mapped',
                FALSE,

            'financial_fields_mapped',
                FALSE,

            'reason_fields_mapped',
                FALSE,

            'external_medication_identifier',
                FALSE,

            'source_identity',
                'governed_source_record_id'
        ),
        p_canonical_promotion_run_id
    )
    ON CONFLICT (
        source_record_id,
        target_schema,
        target_table,
        target_record_id
    )
    DO NOTHING;


    GET DIAGNOSTICS
        v_row_count = ROW_COUNT;


    v_lineage_edges_created :=
        v_lineage_edges_created
        + v_row_count;


    -- ========================================================
    -- RESULT
    -- ========================================================

    RETURN QUERY
    SELECT
        v_medication_id,
        v_medication_created,
        v_lineage_edges_created;

END;
$$;


-- ============================================================
-- 2. DEFAULT DENY
-- ============================================================

REVOKE ALL
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
FROM PUBLIC;


COMMENT ON FUNCTION ingest.promote_synthea_medication_v1(
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
IS
'Controlled synthea-medication v1 canonical writer. Requires governed Medication evidence, certified Patient and Encounter dependencies from the same import batch, Patient/Encounter consistency, timezone-preserving temporal values, no fabricated terminology system/status/dose/identifier, and append-oriented source-record lineage.';


RESET ROLE;