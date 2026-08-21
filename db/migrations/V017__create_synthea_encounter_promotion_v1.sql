-- ============================================================
-- JANUS
-- V017
-- Controlled Synthea Encounter Promotion v1
--
-- Mapping:
--
-- encounters.csv.Id
--   -> clinical.encounter_identifier
--
-- encounters.csv.PATIENT
--   -> resolve certified canonical Patient
--   -> clinical.encounter.patient_id
--
-- encounters.csv.PROVIDER
--   -> resolve certified canonical Provider
--   -> clinical.encounter.provider_id
--
-- encounters.csv.START
--   -> clinical.encounter.start_at
--
-- encounters.csv.STOP
--   -> clinical.encounter.end_at
--
-- encounters.csv.ENCOUNTERCLASS
--   -> clinical.encounter.encounter_type
--
-- encounters.csv.REASONDESCRIPTION
--   -> clinical.encounter.reason
--
-- Intentionally NOT mapped in v1:
--
--   ORGANIZATION
--   PAYER
--   CODE
--   DESCRIPTION
--   BASE_ENCOUNTER_COST
--   TOTAL_CLAIM_COST
--   PAYER_COVERAGE
--   REASONCODE
--
-- Source contains no canonical encounter status.
-- clinical.encounter.status therefore remains NULL.
--
-- Enterprise dependency contract:
--
-- Encounter promotion may consume only Patient and Provider
-- identities that were produced by completed and independently
-- DQ-006-certified canonical promotions for the SAME governed
-- import batch.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. CONTROLLED SYNTHEA ENCOUNTER WRITER
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.promote_synthea_encounter_v1(
    p_canonical_promotion_run_id UUID,

    p_source_record_id UUID,
    p_payload_sha256 TEXT,

    p_synthea_encounter_id TEXT,
    p_synthea_patient_id TEXT,
    p_synthea_provider_id TEXT,

    p_start_at TIMESTAMPTZ,
    p_end_at TIMESTAMPTZ,

    p_encounter_class TEXT,
    p_reason_description TEXT
)
RETURNS TABLE (
    canonical_encounter_id UUID,
    encounter_created BOOLEAN,
    identifier_created BOOLEAN,
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
    v_synthea_encounter_id TEXT;
    v_synthea_patient_id TEXT;
    v_synthea_provider_id TEXT;

    -- Canonical resolution
    v_patient_id UUID;
    v_provider_id UUID;

    v_provider_external_id TEXT;

    -- Encounter values
    v_encounter_type TEXT;
    v_reason TEXT;

    -- Existing / created identity
    v_encounter_id UUID;
    v_encounter_identifier_id UUID;

    v_existing_patient_id UUID;
    v_existing_provider_id UUID;
    v_existing_encounter_type TEXT;
    v_existing_status TEXT;
    v_existing_start_at TIMESTAMPTZ;
    v_existing_end_at TIMESTAMPTZ;
    v_existing_reason TEXT;

    v_encounter_created BOOLEAN := FALSE;
    v_identifier_created BOOLEAN := FALSE;

    v_lineage_edges_created INTEGER := 0;
    v_row_count INTEGER;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Synthea Encounter promotion may only be executed by janus_canonical_svc'
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
            'Synthea Encounter promotion requires a running canonical promotion'
            USING ERRCODE = '42501';
    END IF;


    IF v_mapping_name <> 'synthea-encounter'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Canonical promotion must use synthea-encounter v1'
            USING ERRCODE = '42501';
    END IF;


    -- Revalidate the exact pre-canonical authorization that
    -- was bound to this promotion.
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
            'Encounter source payload SHA-256 is required';
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
            'Unknown Encounter source record: %',
            p_source_record_id;
    END IF;


    IF v_source_batch_id
        IS DISTINCT FROM
        v_import_batch_id
    THEN
        RAISE EXCEPTION
            'Encounter source record does not belong to promotion import batch'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_status <> 'accepted' THEN
        RAISE EXCEPTION
            'Encounter source record must be accepted'
            USING ERRCODE = '42501';
    END IF;


    IF v_source_path
            IS DISTINCT FROM
            'csv/encounters.csv'
       OR v_resource_type
            IS DISTINCT FROM
            'encounters'
    THEN
        RAISE EXCEPTION
            'Encounter source record must originate from csv/encounters.csv'
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
            'Encounter source payload SHA-256 does not match persisted evidence'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- NORMALIZE ENCOUNTER IDENTITY
    -- ========================================================

    IF NULLIF(
        btrim(p_synthea_encounter_id),
        ''
    ) IS NULL
    THEN
        RAISE EXCEPTION
            'Synthea Encounter Id is required';
    END IF;


    v_synthea_encounter_id :=
        lower(
            (
                btrim(
                    p_synthea_encounter_id
                )::UUID
            )::TEXT
        );


    -- ========================================================
    -- NORMALIZE + RESOLVE PATIENT
    -- ========================================================

    IF NULLIF(
        btrim(p_synthea_patient_id),
        ''
    ) IS NULL
    THEN
        RAISE EXCEPTION
            'Synthea Encounter PATIENT is required';
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
            'Synthea Encounter PATIENT does not resolve to a canonical Patient: %',
            v_synthea_patient_id
            USING ERRCODE = '23503';
    END IF;


    -- ========================================================
    -- REQUIRE CERTIFIED PATIENT DEPENDENCY
    --
    -- Existence alone is not enough.
    -- The resolved Patient must belong to a completed,
    -- DQ-006-certified synthea-patient v1 promotion from the
    -- same import batch.
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
    -- NORMALIZE + RESOLVE PROVIDER
    --
    -- Provider is nullable in the canonical schema. The
    -- current Synthea cohort has Provider populated on all
    -- 6,950 rows, but the v1 writer remains structurally
    -- capable of accepting a null source Provider.
    -- ========================================================

    IF NULLIF(
        btrim(p_synthea_provider_id),
        ''
    ) IS NULL
    THEN
        v_synthea_provider_id := NULL;
        v_provider_id := NULL;

    ELSE

        v_synthea_provider_id :=
            lower(
                (
                    btrim(
                        p_synthea_provider_id
                    )::UUID
                )::TEXT
            );


        v_provider_external_id :=
            'urn:janus:source:synthea:provider-id:'
            || v_synthea_provider_id;


        SELECT
            p.provider_id
        INTO
            v_provider_id
        FROM clinical.provider p
        WHERE p.external_id =
              v_provider_external_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Synthea Encounter PROVIDER does not resolve to a canonical Provider: %',
                v_synthea_provider_id
                USING ERRCODE = '23503';
        END IF;


        -- ====================================================
        -- REQUIRE CERTIFIED PROVIDER DEPENDENCY
        -- ====================================================

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
                  'provider'
              AND rl.target_record_id =
                  v_provider_id
              AND upstream.import_batch_id =
                  v_import_batch_id
              AND upstream.mapping_name =
                  'synthea-provider'
              AND upstream.mapping_version =
                  '1'
              AND upstream.status =
                  'completed'
              AND quality.lineage_certified IS TRUE
        ) THEN
            RAISE EXCEPTION
                'Resolved Provider is not backed by a certified synthea-provider v1 promotion for this import batch'
                USING ERRCODE = '42501';
        END IF;

    END IF;


    -- ========================================================
    -- TEMPORAL CONTRACT
    -- ========================================================

    IF p_start_at IS NULL THEN
        RAISE EXCEPTION
            'Encounter START is required';
    END IF;


    IF p_end_at IS NOT NULL
       AND p_end_at < p_start_at
    THEN
        RAISE EXCEPTION
            'Encounter STOP may not precede START';
    END IF;


    -- ========================================================
    -- ENCOUNTER TYPE / REASON
    -- ========================================================

    v_encounter_type :=
        NULLIF(
            btrim(p_encounter_class),
            ''
        );


    IF v_encounter_type IS NULL THEN
        RAISE EXCEPTION
            'Encounter ENCOUNTERCLASS is required';
    END IF;


    v_reason :=
        NULLIF(
            btrim(p_reason_description),
            ''
        );


    -- ========================================================
    -- SERIALIZE SOURCE ENCOUNTER IDENTITY
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            'urn:janus:source:synthea:encounter-id:'
            || v_synthea_encounter_id,
            0
        )
    );


    -- ========================================================
    -- RESOLVE EXISTING ENCOUNTER BY SOURCE IDENTITY
    -- ========================================================

    SELECT
        ei.encounter_identifier_id,
        e.encounter_id,

        e.patient_id,
        e.provider_id,

        e.encounter_type,
        e.status,

        e.start_at,
        e.end_at,

        e.reason
    INTO
        v_encounter_identifier_id,
        v_encounter_id,

        v_existing_patient_id,
        v_existing_provider_id,

        v_existing_encounter_type,
        v_existing_status,

        v_existing_start_at,
        v_existing_end_at,

        v_existing_reason
    FROM clinical.encounter_identifier ei
    JOIN clinical.encounter e
      ON e.encounter_id =
         ei.encounter_id
    WHERE ei.identifier_system =
          'urn:janus:source:synthea:encounter-id'
      AND ei.identifier_value =
          v_synthea_encounter_id
    FOR UPDATE OF ei, e;


    IF FOUND THEN

        -- ====================================================
        -- IDEMPOTENT / FAIL-CLOSED REPLAY
        --
        -- Replaying identical source facts may resolve the same
        -- canonical Encounter.
        --
        -- Conflicting facts require a later explicit canonical
        -- reconciliation/versioning policy. v1 will not silently
        -- mutate historical Encounter facts.
        -- ====================================================

        IF v_existing_patient_id
                IS DISTINCT FROM
                v_patient_id

           OR v_existing_provider_id
                IS DISTINCT FROM
                v_provider_id

           OR v_existing_encounter_type
                IS DISTINCT FROM
                v_encounter_type

           -- Source contains no status. Existing status must
           -- therefore still be NULL under this mapping.
           OR v_existing_status
                IS NOT NULL

           OR v_existing_start_at
                IS DISTINCT FROM
                p_start_at

           OR v_existing_end_at
                IS DISTINCT FROM
                p_end_at

           OR v_existing_reason
                IS DISTINCT FROM
                v_reason
        THEN
            RAISE EXCEPTION
                'Existing canonical Encounter conflicts with synthea-encounter v1 source facts'
                USING ERRCODE = '23505';
        END IF;


        v_encounter_created := FALSE;
        v_identifier_created := FALSE;


    ELSE

        -- ====================================================
        -- CREATE CANONICAL ENCOUNTER
        -- ====================================================

        INSERT INTO clinical.encounter (
            patient_id,
            provider_id,
            encounter_type,
            status,
            start_at,
            end_at,
            reason
        )
        VALUES (
            v_patient_id,
            v_provider_id,
            v_encounter_type,
            NULL,
            p_start_at,
            p_end_at,
            v_reason
        )
        RETURNING encounter_id
        INTO v_encounter_id;


        v_encounter_created := TRUE;


        -- ====================================================
        -- CREATE SOURCE-AWARE ENCOUNTER IDENTITY
        -- ====================================================

        INSERT INTO clinical.encounter_identifier (
            encounter_id,
            identifier_system,
            identifier_value,
            identifier_type,
            is_primary
        )
        VALUES (
            v_encounter_id,
            'urn:janus:source:synthea:encounter-id',
            v_synthea_encounter_id,
            'synthea_encounter_id',
            TRUE
        )
        RETURNING encounter_identifier_id
        INTO v_encounter_identifier_id;


        v_identifier_created := TRUE;

    END IF;


    -- ========================================================
    -- ENCOUNTER LINEAGE
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
        'encounter',
        v_encounter_id,
        'janus.canonical.synthea_encounter',
        '1',
        '1',
        jsonb_build_object(
            'source_artifact',
                'csv/encounters.csv',

            'mapped_fields',
                jsonb_build_array(
                    'Id',
                    'PATIENT',
                    'PROVIDER',
                    'START',
                    'STOP',
                    'ENCOUNTERCLASS',
                    'REASONDESCRIPTION'
                ),

            'patient_resolution',
                'urn:janus:source:synthea:patient-id',

            'provider_resolution',
                'urn:janus:source:synthea:provider-id:<Id>',

            'status_mapped',
                FALSE,

            'unmapped_fields',
                jsonb_build_array(
                    'ORGANIZATION',
                    'PAYER',
                    'CODE',
                    'DESCRIPTION',
                    'BASE_ENCOUNTER_COST',
                    'TOTAL_CLAIM_COST',
                    'PAYER_COVERAGE',
                    'REASONCODE'
                )
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
    -- ENCOUNTER IDENTIFIER LINEAGE
    --
    -- Preserve provenance for both:
    --   * the clinical Encounter
    --   * its source-system identity
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
        'encounter_identifier',
        v_encounter_identifier_id,
        'janus.canonical.synthea_encounter_identifier',
        '1',
        '1',
        jsonb_build_object(
            'source_artifact',
                'csv/encounters.csv',

            'source_field',
                'Id',

            'identifier_system',
                'urn:janus:source:synthea:encounter-id',

            'identifier_type',
                'synthea_encounter_id',

            'is_primary',
                TRUE
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
        v_encounter_id,
        v_encounter_created,
        v_identifier_created,
        v_lineage_edges_created;

END;
$$;


-- ============================================================
-- 2. DEFAULT DENY
-- ============================================================

REVOKE ALL
ON FUNCTION ingest.promote_synthea_encounter_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    TEXT
)
FROM PUBLIC;


COMMENT ON FUNCTION ingest.promote_synthea_encounter_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    TIMESTAMPTZ,
    TIMESTAMPTZ,
    TEXT,
    TEXT
)
IS
'Controlled synthea-encounter v1 canonical writer. Requires governed Encounter evidence, certified Patient and Provider dependencies from the same import batch, deterministic source identity, temporal consistency, and append-oriented Encounter plus Encounter-identifier lineage.';


RESET ROLE;
