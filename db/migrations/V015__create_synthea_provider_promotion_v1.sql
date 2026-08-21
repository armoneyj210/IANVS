-- ============================================================
-- JANUS
-- V015
-- Controlled Synthea Provider Promotion v1
--
-- Mapping:
--
-- providers.csv.Id
--   -> clinical.provider.external_id
--
-- providers.csv.NAME
--   -> clinical.provider.display_name
--
-- providers.csv.SPECIALITY
--   -> clinical.provider.specialty
--
-- providers.csv.ORGANIZATION
--   -> organizations.csv.Id
--   -> organizations.csv.NAME
--   -> clinical.provider.organization_name
--
-- Source fields intentionally NOT canonicalized:
--   GENDER
--   ADDRESS
--   CITY
--   STATE
--   ZIP
--   LAT
--   LON
--   ENCOUNTERS
--   PROCEDURES
--
-- Provenance:
--
--   providers.csv row
--        -> clinical.provider
--
--   organizations.csv row
--        -> clinical.provider
--
-- when an organization reference exists.
--
-- Clinical writes remain behind a SECURITY DEFINER function.
-- janus_canonical_svc receives no direct clinical DML.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. PROVIDER SOURCE IDENTITY CONTRACT
--
-- provider.external_id is now treated as a fully namespaced
-- external/source identifier.
-- ============================================================

ALTER TABLE clinical.provider
ADD CONSTRAINT provider_external_id_not_blank_ck
CHECK (
    external_id IS NULL
    OR btrim(external_id) <> ''
);


CREATE UNIQUE INDEX ux_provider_external_id
ON clinical.provider (
    external_id
)
WHERE external_id IS NOT NULL;


COMMENT ON COLUMN clinical.provider.external_id
IS
'Fully namespaced source identifier for the canonical provider. Example: urn:janus:source:synthea:provider-id:<uuid>.';


-- ============================================================
-- 2. CONTROLLED SYNTHEA PROVIDER WRITER
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.promote_synthea_provider_v1(
    p_canonical_promotion_run_id UUID,

    p_provider_source_record_id UUID,
    p_provider_payload_sha256 TEXT,

    p_synthea_provider_id TEXT,
    p_display_name TEXT,
    p_specialty TEXT,

    p_organization_source_record_id UUID,
    p_organization_payload_sha256 TEXT,
    p_synthea_organization_id TEXT,
    p_organization_name TEXT
)
RETURNS TABLE (
    canonical_provider_id UUID,
    provider_created BOOLEAN,
    lineage_edges_created INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest, clinical
AS $$
DECLARE
    v_import_batch_id UUID;
    v_data_quality_run_id UUID;
    v_quality_gate_decision_id UUID;

    v_mapping_name TEXT;
    v_mapping_version TEXT;
    v_promotion_status TEXT;

    v_provider_source_batch_id UUID;
    v_provider_source_status TEXT;
    v_provider_source_hash TEXT;
    v_provider_source_path TEXT;
    v_provider_resource_type TEXT;

    v_org_source_batch_id UUID;
    v_org_source_status TEXT;
    v_org_source_hash TEXT;
    v_org_source_path TEXT;
    v_org_resource_type TEXT;

    v_synthea_provider_id TEXT;
    v_synthea_organization_id TEXT;

    v_external_id TEXT;
    v_display_name TEXT;
    v_specialty TEXT;
    v_organization_name TEXT;

    v_provider_id UUID;
    v_existing_display_name TEXT;
    v_existing_organization_name TEXT;
    v_existing_specialty TEXT;

    v_provider_created BOOLEAN := FALSE;

    v_lineage_edges_created INTEGER := 0;
    v_row_count INTEGER;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_canonical_svc' THEN
        RAISE EXCEPTION
            'Synthea Provider promotion may only be executed by janus_canonical_svc'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- RESOLVE / VERIFY PROMOTION
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
            'Synthea Provider promotion requires a running canonical promotion'
            USING ERRCODE = '42501';
    END IF;


    IF v_mapping_name <> 'synthea-provider'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Canonical promotion must use synthea-provider v1'
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
    -- NORMALIZE PROVIDER VALUES
    -- ========================================================

    IF NULLIF(
        btrim(p_synthea_provider_id),
        ''
    ) IS NULL
    THEN
        RAISE EXCEPTION
            'Synthea Provider Id is required';
    END IF;


    IF NULLIF(
        btrim(p_provider_payload_sha256),
        ''
    ) IS NULL
    THEN
        RAISE EXCEPTION
            'Provider source payload SHA-256 is required';
    END IF;


    -- Synthea Provider IDs are UUIDs. Canonicalize their text
    -- representation before constructing the source namespace.
    v_synthea_provider_id :=
        lower(
            (
                btrim(
                    p_synthea_provider_id
                )::UUID
            )::TEXT
        );


    v_external_id :=
        'urn:janus:source:synthea:provider-id:'
        || v_synthea_provider_id;


    v_display_name :=
        NULLIF(
            btrim(p_display_name),
            ''
        );


    v_specialty :=
        NULLIF(
            btrim(p_specialty),
            ''
        );


    -- ========================================================
    -- VERIFY PROVIDER SOURCE RECORD
    -- ========================================================

    SELECT
        sr.import_batch_id,
        sr.record_status,
        sr.payload_sha256,
        sf.relative_path,
        sr.resource_type
    INTO
        v_provider_source_batch_id,
        v_provider_source_status,
        v_provider_source_hash,
        v_provider_source_path,
        v_provider_resource_type
    FROM ingest.source_record sr
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE sr.source_record_id =
          p_provider_source_record_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown Provider source record: %',
            p_provider_source_record_id;
    END IF;


    IF v_provider_source_batch_id
        IS DISTINCT FROM
        v_import_batch_id
    THEN
        RAISE EXCEPTION
            'Provider source record does not belong to the promotion import batch'
            USING ERRCODE = '42501';
    END IF;


    IF v_provider_source_status <> 'accepted' THEN
        RAISE EXCEPTION
            'Provider source record must be accepted'
            USING ERRCODE = '42501';
    END IF;


    IF v_provider_source_path
        IS DISTINCT FROM
        'csv/providers.csv'
       OR v_provider_resource_type
        IS DISTINCT FROM
        'providers'
    THEN
        RAISE EXCEPTION
            'Provider source record must originate from csv/providers.csv'
            USING ERRCODE = '42501';
    END IF;


    IF lower(
        btrim(
            p_provider_payload_sha256
        )
    )
       IS DISTINCT FROM
       lower(
           btrim(
               v_provider_source_hash
           )
       )
    THEN
        RAISE EXCEPTION
            'Provider source payload SHA-256 does not match persisted evidence'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- ORGANIZATION SOURCE CONTRACT
    --
    -- Organization is optional at the canonical schema level,
    -- but when supplied all organization evidence must be
    -- supplied together.
    -- ========================================================

    IF p_organization_source_record_id IS NULL THEN

        IF NULLIF(
            btrim(p_organization_payload_sha256),
            ''
        ) IS NOT NULL
           OR NULLIF(
               btrim(p_synthea_organization_id),
               ''
           ) IS NOT NULL
           OR NULLIF(
               btrim(p_organization_name),
               ''
           ) IS NOT NULL
        THEN
            RAISE EXCEPTION
                'Organization source evidence must be all-null when organization source record is absent';
        END IF;


        v_synthea_organization_id := NULL;
        v_organization_name := NULL;


    ELSE

        IF NULLIF(
            btrim(p_organization_payload_sha256),
            ''
        ) IS NULL
           OR NULLIF(
               btrim(p_synthea_organization_id),
               ''
           ) IS NULL
           OR NULLIF(
               btrim(p_organization_name),
               ''
           ) IS NULL
        THEN
            RAISE EXCEPTION
                'Complete organization source evidence is required when organization source record is supplied';
        END IF;


        v_synthea_organization_id :=
            lower(
                (
                    btrim(
                        p_synthea_organization_id
                    )::UUID
                )::TEXT
            );


        v_organization_name :=
            btrim(
                p_organization_name
            );


        SELECT
            sr.import_batch_id,
            sr.record_status,
            sr.payload_sha256,
            sf.relative_path,
            sr.resource_type
        INTO
            v_org_source_batch_id,
            v_org_source_status,
            v_org_source_hash,
            v_org_source_path,
            v_org_resource_type
        FROM ingest.source_record sr
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE sr.source_record_id =
              p_organization_source_record_id;


        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Unknown Organization source record: %',
                p_organization_source_record_id;
        END IF;


        IF v_org_source_batch_id
            IS DISTINCT FROM
            v_import_batch_id
        THEN
            RAISE EXCEPTION
                'Organization source record does not belong to the promotion import batch'
                USING ERRCODE = '42501';
        END IF;


        IF v_org_source_status <> 'accepted' THEN
            RAISE EXCEPTION
                'Organization source record must be accepted'
                USING ERRCODE = '42501';
        END IF;


        IF v_org_source_path
            IS DISTINCT FROM
            'csv/organizations.csv'
           OR v_org_resource_type
            IS DISTINCT FROM
            'organizations'
        THEN
            RAISE EXCEPTION
                'Organization source record must originate from csv/organizations.csv'
                USING ERRCODE = '42501';
        END IF;


        IF lower(
            btrim(
                p_organization_payload_sha256
            )
        )
           IS DISTINCT FROM
           lower(
               btrim(
                   v_org_source_hash
               )
           )
        THEN
            RAISE EXCEPTION
                'Organization source payload SHA-256 does not match persisted evidence'
                USING ERRCODE = '42501';
        END IF;

    END IF;


    -- ========================================================
    -- SERIALIZE PROVIDER IDENTITY RESOLUTION
    --
    -- Different dataset releases must not race while resolving
    -- the same external Provider identity.
    -- ========================================================

    PERFORM pg_advisory_xact_lock(
        hashtextextended(
            v_external_id,
            0
        )
    );


    -- ========================================================
    -- RESOLVE OR CREATE CANONICAL PROVIDER
    -- ========================================================

    SELECT
        p.provider_id,
        p.display_name,
        p.organization_name,
        p.specialty
    INTO
        v_provider_id,
        v_existing_display_name,
        v_existing_organization_name,
        v_existing_specialty
    FROM clinical.provider p
    WHERE p.external_id =
          v_external_id
    FOR UPDATE;


    IF FOUND THEN

        -- Mapping v1 is deterministic and fail-closed.
        --
        -- A future provider-update/versioning policy must be
        -- explicit rather than silently mutating an existing
        -- canonical Provider.
        IF v_existing_display_name
                IS DISTINCT FROM
                v_display_name
           OR v_existing_organization_name
                IS DISTINCT FROM
                v_organization_name
           OR v_existing_specialty
                IS DISTINCT FROM
                v_specialty
        THEN
            RAISE EXCEPTION
                'Existing canonical Provider conflicts with synthea-provider v1 source facts'
                USING ERRCODE = '23505';
        END IF;


        v_provider_created := FALSE;


    ELSE

        INSERT INTO clinical.provider (
            external_id,
            display_name,
            organization_name,
            specialty
        )
        VALUES (
            v_external_id,
            v_display_name,
            v_organization_name,
            v_specialty
        )
        RETURNING provider_id
        INTO v_provider_id;


        v_provider_created := TRUE;

    END IF;


    -- ========================================================
    -- PROVIDER-SOURCE LINEAGE
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
        p_provider_source_record_id,
        'clinical',
        'provider',
        v_provider_id,
        'janus.canonical.synthea_provider',
        '1',
        '1',
        jsonb_build_object(
            'source_artifact',
                'csv/providers.csv',
            'mapped_fields',
                jsonb_build_array(
                    'Id',
                    'NAME',
                    'SPECIALITY'
                ),
            'organization_reference_field',
                'ORGANIZATION',
            'unmapped_fields',
                jsonb_build_array(
                    'GENDER',
                    'ADDRESS',
                    'CITY',
                    'STATE',
                    'ZIP',
                    'LAT',
                    'LON',
                    'ENCOUNTERS',
                    'PROCEDURES'
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
    -- ORGANIZATION-SOURCE LINEAGE
    --
    -- organization_name comes from organizations.csv.NAME.
    -- Preserve that source independently rather than claiming
    -- providers.csv supplied the organization name.
    -- ========================================================

    IF p_organization_source_record_id
       IS NOT NULL
    THEN

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
            p_organization_source_record_id,
            'clinical',
            'provider',
            v_provider_id,
            'janus.canonical.synthea_provider_organization',
            '1',
            '1',
            jsonb_build_object(
                'source_artifact',
                    'csv/organizations.csv',
                'mapped_fields',
                    jsonb_build_array(
                        'Id',
                        'NAME'
                    ),
                'relationship',
                    'provider_organization_name'
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

    END IF;


    -- ========================================================
    -- RESULT
    -- ========================================================

    RETURN QUERY
    SELECT
        v_provider_id,
        v_provider_created,
        v_lineage_edges_created;

END;
$$;


-- ============================================================
-- 3. DEFAULT DENY
-- ============================================================

REVOKE ALL
ON FUNCTION ingest.promote_synthea_provider_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TEXT,
    TEXT
)
FROM PUBLIC;


COMMENT ON FUNCTION ingest.promote_synthea_provider_v1(
    UUID,
    UUID,
    TEXT,
    TEXT,
    TEXT,
    TEXT,
    UUID,
    TEXT,
    TEXT,
    TEXT
)
IS
'Controlled synthea-provider v1 canonical writer. Validates promotion authority, exact governed provider/organization source records and hashes, creates or resolves a namespaced canonical Provider, and appends two-source lineage where organization evidence exists.';


RESET ROLE;