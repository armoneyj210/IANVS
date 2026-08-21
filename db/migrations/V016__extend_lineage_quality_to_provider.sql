-- ============================================================
-- JANUS
-- V016
-- Extend Post-Canonical Lineage Quality to Provider v1
--
-- Adds independent JANUS-DQ-006 evaluation for:
--
--     synthea-provider v1
--
-- Existing Patient lineage evaluation remains unchanged.
--
-- Quality still receives:
--   * no clinical schema/table access
--   * no canonical promotion table access
--
-- Instead, narrow SECURITY DEFINER interfaces expose only the
-- evidence needed for independent lineage certification.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. NARROW PROMOTION-SCOPE RESOLVER
--
-- Quality needs to know which lineage evaluator applies to a
-- promotion UUID, but must NOT SELECT canonical_promotion_run
-- directly.
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.resolve_postcanonical_lineage_scope(
    p_canonical_promotion_run_id UUID
)
RETURNS TABLE (
    canonical_promotion_run_id UUID,
    import_batch_id UUID,
    mapping_name TEXT,
    mapping_version TEXT,
    promotion_status TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest
AS $$
BEGIN

    IF session_user::TEXT <> 'janus_quality_svc' THEN
        RAISE EXCEPTION
            'Post-canonical lineage scope may only be resolved by janus_quality_svc'
            USING ERRCODE = '42501';
    END IF;


    RETURN QUERY
    SELECT
        cpr.canonical_promotion_run_id,
        cpr.import_batch_id,
        cpr.mapping_name,
        cpr.mapping_version,
        cpr.status
    FROM ingest.canonical_promotion_run cpr
    WHERE cpr.canonical_promotion_run_id =
          p_canonical_promotion_run_id;


    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Unknown canonical promotion run: %',
            p_canonical_promotion_run_id;
    END IF;

END;
$$;


REVOKE ALL
ON FUNCTION
ingest.resolve_postcanonical_lineage_scope(UUID)
FROM PUBLIC;


COMMENT ON FUNCTION
ingest.resolve_postcanonical_lineage_scope(UUID)
IS
'Narrow Quality-only scope resolver for post-canonical lineage evaluation. Exposes promotion identity, import batch, mapping, version, and status without granting direct canonical_promotion_run access.';


-- ============================================================
-- 2. PROVIDER LINEAGE EVALUATOR
--
-- Provider v1 has TWO valid provenance patterns:
--
-- providers.csv
--     -> clinical.provider
--
-- organizations.csv
--     -> clinical.provider
--
-- The second edge is required only when canonical
-- organization_name is populated.
-- ============================================================

CREATE OR REPLACE FUNCTION
ingest.evaluate_provider_canonical_lineage(
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

    expected_provider_sources BIGINT,

    valid_provider_lineage_edges BIGINT,
    provider_lineage_sources BIGINT,
    provider_lineage_targets BIGINT,

    provider_sources_missing_lineage BIGINT,
    provider_sources_with_multiple_targets BIGINT,
    provider_orphan_targets BIGINT,

    providers_with_organization_name BIGINT,

    valid_organization_lineage_edges BIGINT,
    organization_lineage_targets BIGINT,

    provider_targets_missing_organization_lineage BIGINT,
    provider_targets_with_unexpected_organization_lineage BIGINT,
    provider_targets_with_multiple_organization_edges BIGINT,
    organization_orphan_targets BIGINT,

    wrong_source_artifact_edges BIGINT,
    wrong_mapping_version_edges BIGINT,
    wrong_transformation_edges BIGINT,
    unexpected_target_edges BIGINT,

    promotion_counter_mismatch BIGINT,
    provider_target_count_mismatch BIGINT,

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

    v_expected_provider_sources BIGINT;

    v_valid_provider_lineage_edges BIGINT;
    v_provider_lineage_sources BIGINT;
    v_provider_lineage_targets BIGINT;

    v_provider_sources_missing_lineage BIGINT;
    v_provider_sources_with_multiple_targets BIGINT;
    v_provider_orphan_targets BIGINT;

    v_providers_with_organization_name BIGINT;

    v_valid_organization_lineage_edges BIGINT;
    v_organization_lineage_targets BIGINT;

    v_provider_targets_missing_org_lineage BIGINT;
    v_provider_targets_unexpected_org_lineage BIGINT;
    v_provider_targets_multiple_org_edges BIGINT;
    v_organization_orphan_targets BIGINT;

    v_wrong_source_artifact_edges BIGINT;
    v_wrong_mapping_version_edges BIGINT;
    v_wrong_transformation_edges BIGINT;
    v_unexpected_target_edges BIGINT;

    v_promotion_counter_mismatch BIGINT;
    v_provider_target_count_mismatch BIGINT;

    v_violation_count BIGINT;
    v_lineage_complete BOOLEAN;
BEGIN

    -- ========================================================
    -- AUTHORITY
    -- ========================================================

    IF session_user::TEXT <> 'janus_quality_svc' THEN
        RAISE EXCEPTION
            'Provider canonical lineage may only be evaluated by janus_quality_svc'
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


    IF v_mapping_name <> 'synthea-provider'
       OR v_mapping_version <> '1'
    THEN
        RAISE EXCEPTION
            'Provider DQ-006 v1 supports only synthea-provider v1'
            USING ERRCODE = '42501';
    END IF;


    -- ========================================================
    -- EXPECTED PROVIDER SOURCES
    -- ========================================================

    SELECT COUNT(*)
    INTO v_expected_provider_sources
    FROM ingest.source_record sr
    JOIN ingest.source_file sf
      ON sf.source_file_id =
         sr.source_file_id
    WHERE sr.import_batch_id =
          v_import_batch_id
      AND sf.relative_path =
          'csv/providers.csv'
      AND sr.resource_type =
          'providers'
      AND sr.record_status =
          'accepted';


    -- ========================================================
    -- VALID DIRECT PROVIDER LINEAGE
    -- ========================================================

    WITH valid_provider_edges AS (
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
        JOIN clinical.provider p
          ON p.provider_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'providers'
          AND sf.relative_path =
              'csv/providers.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider'
          AND rl.transformation_version =
              '1'
    )
    SELECT
        COUNT(*),
        COUNT(DISTINCT source_record_id),
        COUNT(DISTINCT target_record_id)
    INTO
        v_valid_provider_lineage_edges,
        v_provider_lineage_sources,
        v_provider_lineage_targets
    FROM valid_provider_edges;


    -- ========================================================
    -- PROVIDER SOURCES MISSING DIRECT LINEAGE
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
              'providers'
          AND sf.relative_path =
              'csv/providers.csv'
    ),
    covered_sources AS (
        SELECT DISTINCT
            rl.source_record_id
        FROM ingest.record_lineage rl
        JOIN clinical.provider p
          ON p.provider_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_provider_sources_missing_lineage
    FROM expected_sources expected
    LEFT JOIN covered_sources covered
      ON covered.source_record_id =
         expected.source_record_id
    WHERE covered.source_record_id IS NULL;


    -- ========================================================
    -- ONE PROVIDER SOURCE MUST NOT RESOLVE TO MULTIPLE TARGETS
    -- ========================================================

    WITH valid_provider_edges AS (
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
        JOIN clinical.provider p
          ON p.provider_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'providers'
          AND sf.relative_path =
              'csv/providers.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_provider_sources_with_multiple_targets
    FROM (
        SELECT
            source_record_id
        FROM valid_provider_edges
        GROUP BY source_record_id
        HAVING COUNT(
            DISTINCT target_record_id
        ) > 1
    ) duplicate_sources;


    -- ========================================================
    -- DIRECT PROVIDER ORPHANS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_provider_orphan_targets
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.provider p
      ON p.provider_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'provider'
      AND rl.transformation_name =
          'janus.canonical.synthea_provider'
      AND p.provider_id IS NULL;


    -- ========================================================
    -- TARGET SET CREATED/RESOLVED BY PROVIDER SOURCE LINEAGE
    -- ========================================================

    WITH provider_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS provider_id
        FROM ingest.record_lineage rl
        JOIN clinical.provider p
          ON p.provider_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_providers_with_organization_name
    FROM provider_targets targets
    JOIN clinical.provider p
      ON p.provider_id =
         targets.provider_id
    WHERE p.organization_name IS NOT NULL;


    -- ========================================================
    -- VALID ORGANIZATION -> PROVIDER LINEAGE
    -- ========================================================

    WITH provider_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS provider_id
        FROM ingest.record_lineage rl
        JOIN clinical.provider p
          ON p.provider_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider'
          AND rl.transformation_version =
              '1'
    ),
    valid_org_edges AS (
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
        JOIN clinical.provider p
          ON p.provider_id =
             rl.target_record_id
        JOIN provider_targets targets
          ON targets.provider_id =
             p.provider_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'organizations'
          AND sf.relative_path =
              'csv/organizations.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider_organization'
          AND rl.transformation_version =
              '1'
    )
    SELECT
        COUNT(*),
        COUNT(DISTINCT target_record_id)
    INTO
        v_valid_organization_lineage_edges,
        v_organization_lineage_targets
    FROM valid_org_edges;


    -- ========================================================
    -- ORGANIZATION NAME REQUIRES ORGANIZATION LINEAGE
    -- ========================================================

    WITH provider_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS provider_id
        FROM ingest.record_lineage rl
        JOIN clinical.provider p
          ON p.provider_id =
             rl.target_record_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider'
          AND rl.transformation_version =
              '1'
    ),
    valid_org_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS provider_id
        FROM ingest.record_lineage rl
        JOIN ingest.source_record sr
          ON sr.source_record_id =
             rl.source_record_id
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'organizations'
          AND sf.relative_path =
              'csv/organizations.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider_organization'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_provider_targets_missing_org_lineage
    FROM provider_targets targets
    JOIN clinical.provider p
      ON p.provider_id =
         targets.provider_id
    LEFT JOIN valid_org_targets org
      ON org.provider_id =
         targets.provider_id
    WHERE p.organization_name IS NOT NULL
      AND org.provider_id IS NULL;


    -- ========================================================
    -- NO ORGANIZATION LINEAGE WHEN ORGANIZATION NAME IS NULL
    -- ========================================================

    WITH provider_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS provider_id
        FROM ingest.record_lineage rl
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.transformation_name =
              'janus.canonical.synthea_provider'
    ),
    valid_org_targets AS (
        SELECT DISTINCT
            rl.target_record_id AS provider_id
        FROM ingest.record_lineage rl
        JOIN ingest.source_record sr
          ON sr.source_record_id =
             rl.source_record_id
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'organizations'
          AND sf.relative_path =
              'csv/organizations.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider_organization'
          AND rl.transformation_version =
              '1'
    )
    SELECT COUNT(*)
    INTO v_provider_targets_unexpected_org_lineage
    FROM provider_targets targets
    JOIN clinical.provider p
      ON p.provider_id =
         targets.provider_id
    JOIN valid_org_targets org
      ON org.provider_id =
         targets.provider_id
    WHERE p.organization_name IS NULL;


    -- ========================================================
    -- AT MOST ONE ORGANIZATION EDGE PER PROVIDER TARGET
    -- ========================================================

    SELECT COUNT(*)
    INTO v_provider_targets_multiple_org_edges
    FROM (
        SELECT
            rl.target_record_id
        FROM ingest.record_lineage rl
        JOIN ingest.source_record sr
          ON sr.source_record_id =
             rl.source_record_id
        JOIN ingest.source_file sf
          ON sf.source_file_id =
             sr.source_file_id
        WHERE rl.canonical_promotion_run_id =
              p_canonical_promotion_run_id
          AND sr.import_batch_id =
              v_import_batch_id
          AND sr.record_status =
              'accepted'
          AND sr.resource_type =
              'organizations'
          AND sf.relative_path =
              'csv/organizations.csv'
          AND rl.target_schema =
              'clinical'
          AND rl.target_table =
              'provider'
          AND rl.mapping_version =
              v_mapping_version
          AND rl.transformation_name =
              'janus.canonical.synthea_provider_organization'
          AND rl.transformation_version =
              '1'
        GROUP BY
            rl.target_record_id
        HAVING COUNT(*) > 1
    ) multiple_org_edges;


    -- ========================================================
    -- ORGANIZATION LINEAGE ORPHANS
    -- ========================================================

    SELECT COUNT(*)
    INTO v_organization_orphan_targets
    FROM ingest.record_lineage rl
    LEFT JOIN clinical.provider p
      ON p.provider_id =
         rl.target_record_id
    WHERE rl.canonical_promotion_run_id =
          p_canonical_promotion_run_id
      AND rl.target_schema =
          'clinical'
      AND rl.target_table =
          'provider'
      AND rl.transformation_name =
          'janus.canonical.synthea_provider_organization'
      AND p.provider_id IS NULL;


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

         OR sr.record_status
                IS DISTINCT FROM
                'accepted'

         OR (
                rl.transformation_name =
                    'janus.canonical.synthea_provider'
                AND (
                    sf.relative_path
                        IS DISTINCT FROM
                        'csv/providers.csv'
                    OR sr.resource_type
                        IS DISTINCT FROM
                        'providers'
                )
            )

         OR (
                rl.transformation_name =
                    'janus.canonical.synthea_provider_organization'
                AND (
                    sf.relative_path
                        IS DISTINCT FROM
                        'csv/organizations.csv'
                    OR sr.resource_type
                        IS DISTINCT FROM
                        'organizations'
                )
            )
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
                rl.transformation_name =
                    'janus.canonical.synthea_provider'
                AND rl.transformation_version
                    IS DISTINCT FROM
                    '1'
            )

         OR (
                rl.transformation_name =
                    'janus.canonical.synthea_provider_organization'
                AND rl.transformation_version
                    IS DISTINCT FROM
                    '1'
            )

         OR rl.transformation_name NOT IN (
                'janus.canonical.synthea_provider',
                'janus.canonical.synthea_provider_organization'
            )
      );


    -- ========================================================
    -- PROVIDER PROMOTION MAY TARGET ONLY clinical.provider
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
                'provider'
      );


    -- ========================================================
    -- PROMOTION COUNTER RECONCILIATION
    -- ========================================================

    v_promotion_counter_mismatch :=
        CASE
            WHEN v_records_seen
                    IS DISTINCT FROM
                    v_expected_provider_sources

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


    v_provider_target_count_mismatch :=
        CASE
            WHEN v_provider_lineage_targets
                    IS DISTINCT FROM
                    v_expected_provider_sources
            THEN 1
            ELSE 0
        END;


    -- ========================================================
    -- FINAL DQ-006 EVIDENCE
    -- ========================================================

    v_violation_count :=
          v_provider_sources_missing_lineage
        + v_provider_sources_with_multiple_targets
        + v_provider_orphan_targets
        + v_provider_targets_missing_org_lineage
        + v_provider_targets_unexpected_org_lineage
        + v_provider_targets_multiple_org_edges
        + v_organization_orphan_targets
        + v_wrong_source_artifact_edges
        + v_wrong_mapping_version_edges
        + v_wrong_transformation_edges
        + v_unexpected_target_edges
        + v_promotion_counter_mismatch
        + v_provider_target_count_mismatch;


    v_lineage_complete :=
        v_violation_count = 0

        AND v_expected_provider_sources > 0

        AND v_valid_provider_lineage_edges =
            v_expected_provider_sources

        AND v_provider_lineage_sources =
            v_expected_provider_sources

        AND v_provider_lineage_targets =
            v_expected_provider_sources

        AND v_valid_organization_lineage_edges =
            v_providers_with_organization_name

        AND v_organization_lineage_targets =
            v_providers_with_organization_name;


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

        v_expected_provider_sources,

        v_valid_provider_lineage_edges,
        v_provider_lineage_sources,
        v_provider_lineage_targets,

        v_provider_sources_missing_lineage,
        v_provider_sources_with_multiple_targets,
        v_provider_orphan_targets,

        v_providers_with_organization_name,

        v_valid_organization_lineage_edges,
        v_organization_lineage_targets,

        v_provider_targets_missing_org_lineage,
        v_provider_targets_unexpected_org_lineage,
        v_provider_targets_multiple_org_edges,
        v_organization_orphan_targets,

        v_wrong_source_artifact_edges,
        v_wrong_mapping_version_edges,
        v_wrong_transformation_edges,
        v_unexpected_target_edges,

        v_promotion_counter_mismatch,
        v_provider_target_count_mismatch,

        v_violation_count,
        v_lineage_complete;

END;
$$;


REVOKE ALL
ON FUNCTION
ingest.evaluate_provider_canonical_lineage(UUID)
FROM PUBLIC;


COMMENT ON FUNCTION
ingest.evaluate_provider_canonical_lineage(UUID)
IS
'Least-privilege JANUS-DQ-006 evidence interface for synthea-provider v1. Verifies complete Provider source lineage, conditional Organization lineage, target existence, artifact provenance, transformation contracts, and promotion counter reconciliation without granting Quality direct clinical access.';


-- ============================================================
-- 3. EXTEND CONTROLLED DQ-006 GATE WRITER
--
-- Existing Patient evaluator remains unchanged.
--
-- The writer chooses the correct independent evidence function
-- from the promotion mapping bound to the DQ run.
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


    -- Failed runtime executions fail closed.
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
'Controlled JANUS-DQ-006 PASS/FAIL writer for janus-postcanonical-lineage v1. Independently re-evaluates the lineage contract appropriate to the bound canonical mapping before certification.';


RESET ROLE;