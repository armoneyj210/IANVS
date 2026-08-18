-- ============================================================
-- JANUS
-- V012
-- Synthea Patient Canonical Promotion v1
--
-- First controlled canonical clinical writer.
--
-- Scope:
--   csv/patients.csv
--       ->
--   clinical.patient
--   clinical.patient_identifier
--   ingest.record_lineage
--
-- Security model:
--   * janus_canonical_svc receives NO direct clinical access.
--   * Clinical + lineage writes occur only through this
--     SECURITY DEFINER function.
--   * Every write is bound to:
--       canonical promotion run
--       source record
--       source payload hash
--       mapping name/version
--       authorized v2 quality gate
--
-- Semantic rule:
--   Synthea GENDER is intentionally NOT mapped to either
--   clinical.sex_at_birth or clinical.gender_identity.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. CONTROLLED PATIENT PROMOTION WRITER
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.promote_synthea_patient_v1(
    p_canonical_promotion_run_id UUID,
    p_source_record_id UUID,
    p_source_payload_sha256 TEXT,

    p_given_name TEXT,
    p_family_name TEXT,
    p_birth_date DATE,
    p_deceased_date DATE,
    p_race TEXT,
    p_ethnicity TEXT,

    p_synthea_id TEXT,
    p_ssn TEXT,
    p_drivers TEXT,
    p_passport TEXT
)
RETURNS TABLE (
    canonical_patient_id UUID,
    patient_created BOOLEAN,
    identifiers_created INTEGER,
    lineage_edges_created INTEGER
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

    v_source_import_batch_id UUID;
    v_source_file_id UUID;
    v_source_record_status TEXT;
    v_source_resource_type TEXT;
    v_source_payload_sha256 TEXT;
    v_source_relative_path TEXT;

    v_patient_id UUID;
    v_patient_created BOOLEAN := FALSE;

    v_existing_given_name TEXT;
    v_existing_family_name TEXT;
    v_existing_birth_date DATE;
    v_existing_deceased_date DATE;
    v_existing_race TEXT;
    v_existing_ethnicity TEXT;

    v_given_name TEXT;
    v_family_name TEXT;
    v_race TEXT;
    v_ethnicity TEXT;

    v_identifier_systems TEXT[];
    v_identifier_types TEXT[];
    v_identifier_values TEXT[];

    v_identifier_system TEXT;
    v_identifier_type TEXT;
    v_identifier_value TEXT;

    v_patient_identifier_id UUID;
    v_existing_identifier_patient_id UUID;

    v_identifiers_created INTEGER := 0;
    v_lineage_edges_created INTEGER := 0;

    v_index INTEGER;
    v_row_count INTEGER;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Synthea patient promotion may only be executed by janus_canonical_svc'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- NORMALIZE SOURCE VALUES
    -- ========================================================

    v_given_name :=
        NULLIF(btrim(p_given_name), '');

    v_family_name :=
        NULLIF(btrim(p_family_name), '');

    v_race :=
        NULLIF(btrim(p_race), '');

    v_ethnicity :=
        NULLIF(btrim(p_ethnicity), '');


    IF NULLIF(btrim(p_synthea_id), '') IS NULL THEN
        RAISE EXCEPTION
            'Synthea patient Id is required for canonical promotion';
    END IF;


    IF NULLIF(btrim(p_source_payload_sha256), '') IS NULL THEN
        RAISE EXCEPTION
            'Source payload SHA-256 is required for canonical promotion';
    END IF;


    -- ========================================================
    -- VERIFY PROMOTION RUN
    -- ========================================================

    SELECT
        cpr.import_batch_id,
        cpr.mapping_name,
        cpr.mapping_version,
        cpr.status
    INTO
        v_import_batch_id,
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
            'Canonical patient writes require a running promotion'
            USING ERRCODE = '42501';
    END IF;


    IF v_mapping_name <> 'synthea-patient'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Promotion run does not use the authorized Synthea patient v1 mapping contract'
            USING ERRCODE = '42501';
    END IF;


    -- Revalidate the upstream enterprise quality authorization.
    IF NOT EXISTS (
        SELECT 1
        FROM ingest.canonical_promotion_run cpr
        JOIN ingest.v_quality_gate_effective_status q
          ON q.data_quality_run_id =
             cpr.data_quality_run_id
         AND q.quality_gate_decision_id =
             cpr.quality_gate_decision_id
        WHERE cpr.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND q.gate_allows_promotion IS TRUE
    ) THEN
        RAISE EXCEPTION
            'Canonical promotion no longer has an effective enterprise quality authorization'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- VERIFY EXACT GOVERNED SOURCE RECORD
    -- ========================================================

    SELECT
        sr.import_batch_id,
        sr.source_file_id,
        sr.record_status,
        sr.resource_type,
        sr.payload_sha256,
        sf.relative_path
    INTO
        v_source_import_batch_id,
        v_source_file_id,
        v_source_record_status,
        v_source_resource_type,
        v_source_payload_sha256,
        v_source_relative_path
    FROM ingest.source_record sr
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE sr.source_record_id =
          p_source_record_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown source record: %',
            p_source_record_id;
    END IF;


    IF v_source_import_batch_id
        IS DISTINCT FROM v_import_batch_id
    THEN
        RAISE EXCEPTION
            'Source record does not belong to the authorized import batch'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_record_status <> 'accepted' THEN
        RAISE EXCEPTION
            'Only accepted source records may be promoted'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_resource_type <> 'patients'
       OR v_source_relative_path <> 'csv/patients.csv'
    THEN
        RAISE EXCEPTION
            'Synthea patient mapping v1 only accepts csv/patients.csv source records'
            USING ERRCODE = '42501';
    END IF;


    IF lower(v_source_payload_sha256)
        IS DISTINCT FROM
       lower(btrim(p_source_payload_sha256))
    THEN
        RAISE EXCEPTION
            'Physical source-row payload SHA-256 does not match the governed source record'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- RESOLVE PATIENT USING SYNTHETIC SOURCE PRIMARY ID
    --
    -- Synthetic identifiers intentionally live in a Janus
    -- source namespace so they cannot be confused with
    -- production identity systems.
    -- ========================================================

    SELECT pi.patient_id
    INTO v_patient_id
    FROM clinical.patient_identifier pi
    WHERE pi.identifier_system =
          'urn:janus:source:synthea:patient-id'
      AND pi.identifier_value =
          btrim(p_synthea_id);


    IF FOUND THEN

        -- Existing identity may be reused only when canonical
        -- facts agree exactly with this mapping contract.
        SELECT
            p.given_name,
            p.family_name,
            p.birth_date,
            p.deceased_date,
            p.race,
            p.ethnicity
        INTO
            v_existing_given_name,
            v_existing_family_name,
            v_existing_birth_date,
            v_existing_deceased_date,
            v_existing_race,
            v_existing_ethnicity
        FROM clinical.patient p
        WHERE p.patient_id =
              v_patient_id;


        IF v_existing_given_name
                IS DISTINCT FROM v_given_name
           OR v_existing_family_name
                IS DISTINCT FROM v_family_name
           OR v_existing_birth_date
                IS DISTINCT FROM p_birth_date
           OR v_existing_deceased_date
                IS DISTINCT FROM p_deceased_date
           OR v_existing_race
                IS DISTINCT FROM v_race
           OR v_existing_ethnicity
                IS DISTINCT FROM v_ethnicity
        THEN
            RAISE EXCEPTION
                'Existing canonical patient conflicts with the Synthea patient v1 mapping'
                USING ERRCODE = '23514';
        END IF;

    ELSE

        INSERT INTO clinical.patient (
            given_name,
            family_name,
            birth_date,
            deceased_date,
            sex_at_birth,
            gender_identity,
            race,
            ethnicity
        )
        VALUES (
            v_given_name,
            v_family_name,
            p_birth_date,
            p_deceased_date,

            -- Explicitly not inferred from Synthea GENDER.
            NULL,
            NULL,

            v_race,
            v_ethnicity
        )
        RETURNING patient_id
        INTO v_patient_id;


        v_patient_created := TRUE;

    END IF;


    -- ========================================================
    -- PATIENT LINEAGE
    -- ========================================================

    INSERT INTO ingest.record_lineage (
        source_record_id,
        canonical_promotion_run_id,
        target_schema,
        target_table,
        target_record_id,
        transformation_name,
        transformation_version,
        mapping_version,
        transformation_details
    )
    VALUES (
        p_source_record_id,
        p_canonical_promotion_run_id,
        'clinical',
        'patient',
        v_patient_id,
        'janus.canonical.synthea_patient',
        '1',
        v_mapping_version,
        jsonb_build_object(
            'mapping_name',
            v_mapping_name,
            'mapping_version',
            v_mapping_version,
            'source_artifact',
            'csv/patients.csv',
            'gender_mapped',
            FALSE
        )
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
    -- IDENTIFIER MAPPING
    -- ========================================================

    v_identifier_systems := ARRAY[
        'urn:janus:source:synthea:patient-id',
        'urn:janus:source:synthea:ssn',
        'urn:janus:source:synthea:drivers-license',
        'urn:janus:source:synthea:passport'
    ];


    v_identifier_types := ARRAY[
        'synthea_patient_id',
        'ssn',
        'driver_license',
        'passport'
    ];


    v_identifier_values := ARRAY[
        NULLIF(btrim(p_synthea_id), ''),
        NULLIF(btrim(p_ssn), ''),
        NULLIF(btrim(p_drivers), ''),
        NULLIF(btrim(p_passport), '')
    ];


    FOR v_index IN 1..array_length(
        v_identifier_values,
        1
    )
    LOOP

        v_identifier_system :=
            v_identifier_systems[v_index];

        v_identifier_type :=
            v_identifier_types[v_index];

        v_identifier_value :=
            v_identifier_values[v_index];


        IF v_identifier_value IS NULL THEN
            CONTINUE;
        END IF;


        v_patient_identifier_id := NULL;
        v_existing_identifier_patient_id := NULL;


        SELECT
            pi.patient_identifier_id,
            pi.patient_id
        INTO
            v_patient_identifier_id,
            v_existing_identifier_patient_id
        FROM clinical.patient_identifier pi
        WHERE pi.identifier_system =
              v_identifier_system
          AND pi.identifier_value =
              v_identifier_value;


        IF FOUND THEN

            IF v_existing_identifier_patient_id
                IS DISTINCT FROM v_patient_id
            THEN
                RAISE EXCEPTION
                    'Identifier collision: system % is already attached to a different canonical patient',
                    v_identifier_system
                    USING ERRCODE = '23505';
            END IF;

        ELSE

            INSERT INTO clinical.patient_identifier (
                patient_id,
                identifier_system,
                identifier_value,
                identifier_type,
                is_primary
            )
            VALUES (
                v_patient_id,
                v_identifier_system,
                v_identifier_value,
                v_identifier_type,
                v_index = 1
            )
            RETURNING patient_identifier_id
            INTO v_patient_identifier_id;


            v_identifiers_created :=
                v_identifiers_created + 1;

        END IF;


        -- ====================================================
        -- IDENTIFIER LINEAGE
        -- ====================================================

        INSERT INTO ingest.record_lineage (
            source_record_id,
            canonical_promotion_run_id,
            target_schema,
            target_table,
            target_record_id,
            transformation_name,
            transformation_version,
            mapping_version,
            transformation_details
        )
        VALUES (
            p_source_record_id,
            p_canonical_promotion_run_id,
            'clinical',
            'patient_identifier',
            v_patient_identifier_id,
            'janus.canonical.synthea_patient_identifier',
            '1',
            v_mapping_version,
            jsonb_build_object(
                'mapping_name',
                v_mapping_name,
                'mapping_version',
                v_mapping_version,
                'identifier_system',
                v_identifier_system,
                'identifier_type',
                v_identifier_type,
                'identifier_value_logged',
                FALSE
            )
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

    END LOOP;


    -- ========================================================
    -- RETURN NON-SENSITIVE EXECUTION METADATA
    -- ========================================================

    RETURN QUERY
    SELECT
        v_patient_id,
        v_patient_created,
        v_identifiers_created,
        v_lineage_edges_created;

END;
$$;


-- ============================================================
-- 2. PRIVILEGE HARDENING
-- ============================================================

REVOKE ALL
ON FUNCTION ingest.promote_synthea_patient_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT
)
FROM PUBLIC;


-- Canonical service still receives no direct clinical or
-- lineage write capability.
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON
    clinical.patient,
    clinical.patient_identifier
FROM
    janus_etl_svc,
    janus_quality_svc;


REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ingest.record_lineage
FROM
    janus_etl_svc,
    janus_quality_svc;


COMMENT ON FUNCTION ingest.promote_synthea_patient_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    DATE,
    DATE,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TEXT
) IS
'Atomic Synthea patient v1 canonical writer. Verifies canonical authority, exact governed source provenance and active v2 quality authorization before inserting or resolving clinical.patient, patient_identifier and record_lineage.';


RESET ROLE;