-- ============================================================
-- JANUS
-- V020
-- Controlled Synthea Condition Promotion v1
--
-- Mapping:
--
-- conditions.csv.PATIENT
--   -> resolve certified canonical Patient
--   -> clinical.condition.patient_id
--
-- conditions.csv.ENCOUNTER
--   -> resolve certified canonical Encounter
--   -> clinical.condition.encounter_id
--
-- conditions.csv.SYSTEM
--   -> clinical.condition.code_system
--
-- conditions.csv.CODE
--   -> clinical.condition.code
--
-- conditions.csv.DESCRIPTION
--   -> clinical.condition.display
--
-- conditions.csv.START
--   -> clinical.condition.onset_date
--
-- conditions.csv.STOP
--   -> clinical.condition.resolved_date
--
-- Source contains no clinical status.
-- clinical.condition.clinical_status therefore remains NULL.
--
-- Synthea conditions.csv contains no Condition Id.
-- v1 does NOT fabricate an external Condition identifier.
--
-- Governed identity:
--
-- source_record_id + payload_sha256
--     -> record_lineage
--     -> clinical.condition.condition_id
--
-- Enterprise dependency contract:
--
-- Condition promotion may consume only Patient and Encounter
-- identities produced by completed and independently DQ-006-
-- certified canonical promotions for the SAME governed import
-- batch.
--
-- Cross-entity invariant:
--
-- resolved Encounter.patient_id MUST equal the independently
-- resolved source PATIENT.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. CONTROLLED SYNTHEA CONDITION WRITER
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.promote_synthea_condition_v1(
    p_canonical_promotion_run_id UUID,

    p_source_record_id UUID,
    p_payload_sha256 TEXT,

    p_synthea_patient_id TEXT,
    p_synthea_encounter_id TEXT,

    p_onset_date DATE,
    p_resolved_date DATE,

    p_code_system TEXT,
    p_code TEXT,
    p_description TEXT
)
RETURNS TABLE (
    canonical_condition_id UUID,
    condition_created BOOLEAN,
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

    -- Normalized clinical values
    v_code_system TEXT;
    v_code TEXT;
    v_display TEXT;

    -- Canonical target
    v_condition_id UUID;

    -- Existing target contract
    v_existing_target_count BIGINT;

    v_existing_patient_id UUID;
    v_existing_encounter_id UUID;
    v_existing_code_system TEXT;
    v_existing_code TEXT;
    v_existing_display TEXT;
    v_existing_clinical_status TEXT;
    v_existing_onset_date DATE;
    v_existing_resolved_date DATE;

    v_existing_transformation_name TEXT;
    v_existing_transformation_version TEXT;
    v_existing_mapping_version TEXT;

    v_condition_created BOOLEAN := FALSE;

    v_lineage_edges_created INTEGER := 0;
    v_row_count INTEGER;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Synthea Condition promotion may only be executed by janus_canonical_svc'
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
            'Synthea Condition promotion requires a running canonical promotion'
            USING ERRCODE = '42501';
    END IF;


    IF v_mapping_name <> 'synthea-condition'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Canonical promotion must use synthea-condition v1'
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
            'Condition source payload SHA-256 is required';
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
            'Unknown Condition source record: %',
            p_source_record_id;
    END IF;


    IF v_source_batch_id
        IS DISTINCT FROM
        v_import_batch_id
    THEN
        RAISE EXCEPTION
            'Condition source record does not belong to promotion import batch'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_status <> 'accepted' THEN
        RAISE EXCEPTION
            'Condition source record must be accepted'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_path
            IS DISTINCT FROM
            'csv/conditions.csv'
       OR v_resource_type
            IS DISTINCT FROM
            'conditions'
    THEN
        RAISE EXCEPTION
            'Condition source record must originate from csv/conditions.csv'
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
            'Condition source payload SHA-256 does not match persisted evidence'
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
            'Synthea Condition PATIENT is required';
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
            'Synthea Condition PATIENT does not resolve to a canonical Patient: %',
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
            'Synthea Condition ENCOUNTER is required';
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
            'Synthea Condition ENCOUNTER does not resolve to a canonical Encounter: %',
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
            'Condition PATIENT does not match resolved Encounter.patient_id'
            USING ERRCODE = '23514';
    END IF;


    -- ========================================================
    -- TEMPORAL CONTRACT
    -- ========================================================

    IF p_onset_date IS NULL THEN
        RAISE EXCEPTION
            'Condition START is required';
    END IF;


    IF p_resolved_date IS NOT NULL
       AND p_resolved_date < p_onset_date
    THEN
        RAISE EXCEPTION
            'Condition STOP may not precede START'
            USING ERRCODE = '23514';
    END IF;


    -- ========================================================
    -- CODING CONTRACT
    -- ========================================================

    v_code_system :=
        NULLIF(
            btrim(p_code_system),
            ''
        );

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


    IF v_code_system IS NULL THEN
        RAISE EXCEPTION
            'Condition SYSTEM is required';
    END IF;


    IF v_code IS NULL THEN
        RAISE EXCEPTION
            'Condition CODE is required';
    END IF;


    IF v_display IS NULL THEN
        RAISE EXCEPTION
            'Condition DESCRIPTION is required';
    END IF;


    -- ========================================================
    -- SERIALIZE GOVERNED SOURCE-RECORD IDENTITY
    --
    -- conditions.csv has no external Condition Id.
    -- Therefore the governed source_record_id is the source
    -- identity for v1 replay and provenance.
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'janus:synthea-condition:source-record:'
            || p_source_record_id::TEXT,
            0
        )
    );


    -- ========================================================
    -- RESOLVE ANY EXISTING CONDITION FOR THIS SOURCE RECORD
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
          'condition';


    IF v_existing_target_count > 1 THEN
        RAISE EXCEPTION
            'Condition source record resolves to multiple canonical Condition targets'
            USING ERRCODE = '23505';
    END IF;


    SELECT
        rl.target_record_id,
        rl.transformation_name,
        rl.transformation_version,
        rl.mapping_version
    INTO
        v_condition_id,
        v_existing_transformation_name,
        v_existing_transformation_version,
        v_existing_mapping_version
    FROM ingest.record_lineage rl
    WHERE rl.source_record_id =
          p_source_record_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'condition'
    LIMIT 1;


    IF FOUND THEN

        IF v_existing_transformation_name
                IS DISTINCT FROM
                'janus.canonical.synthea_condition'
           OR v_existing_transformation_version
                IS DISTINCT FROM
                '1'
           OR v_existing_mapping_version
                IS DISTINCT FROM
                '1'
        THEN
            RAISE EXCEPTION
                'Existing Condition lineage uses an incompatible mapping contract'
                USING ERRCODE = '23505';
        END IF;


        SELECT
            c.patient_id,
            c.encounter_id,
            c.code_system,
            c.code,
            c.display,
            c.clinical_status,
            c.onset_date,
            c.resolved_date
        INTO
            v_existing_patient_id,
            v_existing_encounter_id,
            v_existing_code_system,
            v_existing_code,
            v_existing_display,
            v_existing_clinical_status,
            v_existing_onset_date,
            v_existing_resolved_date
        FROM clinical.condition c
        WHERE c.condition_id =
              v_condition_id
        FOR UPDATE;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Existing Condition lineage target does not resolve to clinical.condition'
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

           OR v_existing_code_system
                IS DISTINCT FROM
                v_code_system

           OR v_existing_code
                IS DISTINCT FROM
                v_code

           OR v_existing_display
                IS DISTINCT FROM
                v_display

           -- Source has no clinical status.
           OR v_existing_clinical_status
                IS NOT NULL

           OR v_existing_onset_date
                IS DISTINCT FROM
                p_onset_date

           OR v_existing_resolved_date
                IS DISTINCT FROM
                p_resolved_date
        THEN
            RAISE EXCEPTION
                'Existing canonical Condition conflicts with synthea-condition v1 source facts'
                USING ERRCODE = '23505';
        END IF;


        v_condition_created := FALSE;


    ELSE

        -- ====================================================
        -- CREATE CANONICAL CONDITION
        -- ====================================================

        INSERT INTO clinical.condition (
            patient_id,
            encounter_id,
            code_system,
            code,
            display,
            clinical_status,
            onset_date,
            resolved_date
        )
        VALUES (
            v_patient_id,
            v_encounter_id,
            v_code_system,
            v_code,
            v_display,
            NULL,
            p_onset_date,
            p_resolved_date
        )
        RETURNING condition_id
        INTO v_condition_id;


        v_condition_created := TRUE;

    END IF;


    -- ========================================================
    -- CONDITION LINEAGE
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
        'condition',
        v_condition_id,
        'janus.canonical.synthea_condition',
        '1',
        '1',
        jsonb_build_object(
            'source_artifact',
                'csv/conditions.csv',

            'mapped_fields',
                jsonb_build_array(
                    'PATIENT',
                    'ENCOUNTER',
                    'SYSTEM',
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

            'clinical_status_mapped',
                FALSE,

            'external_condition_identifier',
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
        v_condition_id,
        v_condition_created,
        v_lineage_edges_created;

END;
$$;


-- ============================================================
-- 2. DEFAULT DENY
-- ============================================================

REVOKE ALL
ON FUNCTION ingest.promote_synthea_condition_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT
)
FROM PUBLIC;


COMMENT ON FUNCTION ingest.promote_synthea_condition_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT
)
IS
'Controlled synthea-condition v1 canonical writer. Requires governed Condition evidence, independently certified Patient and Encounter dependencies from the same import batch, Patient/Encounter consistency, explicit coding and temporal contracts, no invented clinical status, and append-oriented source-record lineage.';


RESET ROLE;