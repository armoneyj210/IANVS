-- ============================================================
-- JANUS
-- Migration 003
-- Enterprise Ingestion Provenance and Data Lineage
-- ============================================================

BEGIN;

-- ============================================================
-- SOURCE SYSTEM
-- Where data ultimately originates.
-- Examples: Synthea, Kaggle, hospital EHR, external API.
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.source_system (
    source_system_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    name TEXT NOT NULL UNIQUE,

    source_type TEXT NOT NULL,

    description TEXT,
    base_uri TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        source_type IN (
            'synthetic_generator',
            'public_dataset',
            'ehr',
            'api',
            'file',
            'other'
        )
    )
);


-- ============================================================
-- DATASET
-- Logical dataset and its governance/licensing information.
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.dataset (
    dataset_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    source_system_id UUID NOT NULL
        REFERENCES ingest.source_system(source_system_id),

    name TEXT NOT NULL,
    description TEXT,

    homepage_uri TEXT,

    license_name TEXT,
    license_uri TEXT,
    usage_notes TEXT,

    data_classification TEXT NOT NULL DEFAULT 'synthetic',

    contains_phi BOOLEAN NOT NULL DEFAULT false,

    review_status TEXT NOT NULL DEFAULT 'candidate',
    reviewed_by TEXT,
    reviewed_at TIMESTAMPTZ,
    review_notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (source_system_id, name),

    CHECK (
        data_classification IN (
            'synthetic',
            'public',
            'deidentified',
            'restricted',
            'phi'
        )
    ),

    CHECK (
        review_status IN (
            'candidate',
            'approved',
            'rejected',
            'retired'
        )
    )
);


-- ============================================================
-- DATASET RELEASE
-- Exact version/snapshot of a dataset.
--
-- This is important because "Synthea" alone is not enough.
-- We need to know exactly WHICH Synthea output/version was used.
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.dataset_release (
    dataset_release_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    dataset_id UUID NOT NULL
        REFERENCES ingest.dataset(dataset_id),

    release_label TEXT NOT NULL,

    source_version TEXT,

    released_at TIMESTAMPTZ,
    retrieved_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    source_uri TEXT,

    manifest_sha256 TEXT,

    notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (dataset_id, release_label),

    CHECK (
        manifest_sha256 IS NULL
        OR manifest_sha256 ~ '^[0-9a-fA-F]{64}$'
    )
);


-- ============================================================
-- SOURCE FILE
-- Physical file belonging to a dataset release.
--
-- Examples:
-- patients.csv
-- encounters.csv
-- observations.csv
-- patient-123.fhir.json
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.source_file (
    source_file_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    dataset_release_id UUID NOT NULL
        REFERENCES ingest.dataset_release(dataset_release_id),

    relative_path TEXT NOT NULL,

    media_type TEXT,

    size_bytes BIGINT,
    row_count BIGINT,

    sha256 TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (dataset_release_id, relative_path),

    CHECK (
        size_bytes IS NULL
        OR size_bytes >= 0
    ),

    CHECK (
        row_count IS NULL
        OR row_count >= 0
    ),

    CHECK (
        sha256 IS NULL
        OR sha256 ~ '^[0-9a-fA-F]{64}$'
    )
);


-- ============================================================
-- IMPORT BATCH
-- One execution of an ETL/import workflow.
--
-- Example:
-- "Import 100 Synthea patients on Aug 12, 2026"
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.import_batch (
    import_batch_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    dataset_release_id UUID NOT NULL
        REFERENCES ingest.dataset_release(dataset_release_id),

    status TEXT NOT NULL DEFAULT 'pending',

    environment TEXT NOT NULL DEFAULT 'development',

    etl_name TEXT NOT NULL,
    etl_version TEXT NOT NULL,

    mapping_version TEXT,

    git_commit_sha TEXT,

    initiated_by TEXT NOT NULL,

    correlation_id UUID NOT NULL DEFAULT gen_random_uuid(),

    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,

    records_seen BIGINT NOT NULL DEFAULT 0,
    records_accepted BIGINT NOT NULL DEFAULT 0,
    records_rejected BIGINT NOT NULL DEFAULT 0,

    error_summary JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        status IN (
            'pending',
            'running',
            'completed',
            'completed_with_errors',
            'failed',
            'cancelled'
        )
    ),

    CHECK (
        environment IN (
            'development',
            'test',
            'staging',
            'production'
        )
    ),

    CHECK (records_seen >= 0),
    CHECK (records_accepted >= 0),
    CHECK (records_rejected >= 0),

    CHECK (
        records_accepted + records_rejected <= records_seen
    ),

    CHECK (
        completed_at IS NULL
        OR started_at IS NULL
        OR completed_at >= started_at
    )
);


-- ============================================================
-- SOURCE RECORD
-- Represents the exact source record consumed by ETL.
--
-- Examples:
-- CSV row 42
-- FHIR Patient/abc123
-- FHIR Observation/xyz456
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.source_record (
    source_record_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    import_batch_id UUID NOT NULL
        REFERENCES ingest.import_batch(import_batch_id),

    source_file_id UUID
        REFERENCES ingest.source_file(source_file_id),

    source_record_key TEXT NOT NULL,

    resource_type TEXT,

    row_number BIGINT,

    record_locator TEXT,

    raw_storage_uri TEXT,

    payload_sha256 TEXT,

    record_status TEXT NOT NULL DEFAULT 'accepted',

    imported_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (
        import_batch_id,
        source_file_id,
        source_record_key
    ),

    CHECK (
        row_number IS NULL
        OR row_number > 0
    ),

    CHECK (
        payload_sha256 IS NULL
        OR payload_sha256 ~ '^[0-9a-fA-F]{64}$'
    ),

    CHECK (
        record_status IN (
            'accepted',
            'rejected',
            'quarantined'
        )
    )
);


-- ============================================================
-- VALIDATION ISSUE
-- Records warnings/errors discovered during ingestion.
--
-- We store issues rather than hiding or silently fixing them.
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.validation_issue (
    validation_issue_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    import_batch_id UUID NOT NULL
        REFERENCES ingest.import_batch(import_batch_id),

    source_file_id UUID
        REFERENCES ingest.source_file(source_file_id),

    source_record_id UUID
        REFERENCES ingest.source_record(source_record_id),

    rule_code TEXT NOT NULL,

    severity TEXT NOT NULL,

    field_path TEXT,

    message TEXT NOT NULL,

    details JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        severity IN (
            'info',
            'warning',
            'error',
            'fatal'
        )
    )
);


-- ============================================================
-- RECORD LINEAGE
--
-- This is the critical bridge:
--
-- source record
--      ↓
-- transformation
--      ↓
-- canonical clinical record
--
-- One source record may create multiple clinical records.
-- Multiple source records may contribute to one clinical record.
-- ============================================================

CREATE TABLE IF NOT EXISTS ingest.record_lineage (
    lineage_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    source_record_id UUID NOT NULL
        REFERENCES ingest.source_record(source_record_id),

    target_schema TEXT NOT NULL DEFAULT 'clinical',

    target_table TEXT NOT NULL,

    target_record_id UUID NOT NULL,

    transformation_name TEXT NOT NULL,
    transformation_version TEXT NOT NULL,

    mapping_version TEXT,

    transformation_details JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (
        source_record_id,
        target_schema,
        target_table,
        target_record_id
    ),

    CHECK (
        target_schema = 'clinical'
    ),

    CHECK (
        target_table IN (
            'patient',
            'patient_identifier',
            'provider',
            'encounter',
            'condition',
            'medication',
            'observation',
            'assessment',
            'therapy_session',
            'goal',
            'intervention',
            'outcome',
            'consent'
        )
    )
);


-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_dataset_source_system
    ON ingest.dataset(source_system_id);

CREATE INDEX IF NOT EXISTS idx_dataset_release_dataset
    ON ingest.dataset_release(dataset_id);

CREATE INDEX IF NOT EXISTS idx_source_file_release
    ON ingest.source_file(dataset_release_id);

CREATE INDEX IF NOT EXISTS idx_import_batch_release
    ON ingest.import_batch(dataset_release_id);

CREATE INDEX IF NOT EXISTS idx_import_batch_status
    ON ingest.import_batch(status);

CREATE INDEX IF NOT EXISTS idx_import_batch_correlation
    ON ingest.import_batch(correlation_id);

CREATE INDEX IF NOT EXISTS idx_source_record_batch
    ON ingest.source_record(import_batch_id);

CREATE INDEX IF NOT EXISTS idx_source_record_file
    ON ingest.source_record(source_file_id);

CREATE INDEX IF NOT EXISTS idx_source_record_key
    ON ingest.source_record(source_record_key);

CREATE INDEX IF NOT EXISTS idx_validation_issue_batch
    ON ingest.validation_issue(import_batch_id);

CREATE INDEX IF NOT EXISTS idx_validation_issue_record
    ON ingest.validation_issue(source_record_id);

CREATE INDEX IF NOT EXISTS idx_lineage_source
    ON ingest.record_lineage(source_record_id);

CREATE INDEX IF NOT EXISTS idx_lineage_target
    ON ingest.record_lineage(
        target_schema,
        target_table,
        target_record_id
    );


-- ============================================================
-- DOCUMENTATION
-- PostgreSQL stores these comments with the database schema.
-- ============================================================

COMMENT ON SCHEMA ingest IS
'Janus ingestion, dataset provenance, validation, and source-to-canonical lineage.';

COMMENT ON TABLE ingest.source_system IS
'External or synthetic system from which source data originates.';

COMMENT ON TABLE ingest.dataset IS
'Logical source dataset including licensing, classification, and review metadata.';

COMMENT ON TABLE ingest.dataset_release IS
'Exact version or snapshot of a source dataset used by Janus.';

COMMENT ON TABLE ingest.source_file IS
'Physical source asset belonging to a dataset release.';

COMMENT ON TABLE ingest.import_batch IS
'Single execution of a Janus ETL/import workflow.';

COMMENT ON TABLE ingest.source_record IS
'Individual source record processed during an import batch.';

COMMENT ON TABLE ingest.validation_issue IS
'Validation warning or error discovered during ingestion.';

COMMENT ON TABLE ingest.record_lineage IS
'Traceability between source records and canonical clinical records created from them.';

COMMIT;