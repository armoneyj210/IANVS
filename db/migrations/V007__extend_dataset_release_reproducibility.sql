-- ============================================================
-- JANUS
-- V007
-- Dataset Release Reproducibility Metadata
-- ============================================================

SET ROLE janus_owner;

ALTER TABLE ingest.dataset_release
    ADD COLUMN acquisition_method TEXT NOT NULL DEFAULT 'downloaded',

    ADD COLUMN source_commit_sha TEXT,

    ADD COLUMN generated_at TIMESTAMPTZ,

    ADD COLUMN generation_parameters JSONB
        NOT NULL DEFAULT '{}'::jsonb,

    ADD COLUMN release_metadata JSONB
        NOT NULL DEFAULT '{}'::jsonb;


ALTER TABLE ingest.dataset_release
    ADD CONSTRAINT chk_dataset_release_acquisition_method
    CHECK (
        acquisition_method IN (
            'generated',
            'downloaded',
            'api',
            'manual',
            'other'
        )
    );


ALTER TABLE ingest.dataset_release
    ADD CONSTRAINT chk_dataset_release_commit_sha
    CHECK (
        source_commit_sha IS NULL
        OR source_commit_sha ~ '^[0-9a-fA-F]{7,64}$'
    );


ALTER TABLE ingest.dataset_release
    ADD CONSTRAINT chk_dataset_release_generation_parameters
    CHECK (
        jsonb_typeof(generation_parameters) = 'object'
    );


ALTER TABLE ingest.dataset_release
    ADD CONSTRAINT chk_dataset_release_metadata
    CHECK (
        jsonb_typeof(release_metadata) = 'object'
    );


COMMENT ON COLUMN ingest.dataset_release.acquisition_method IS
'How Janus obtained or produced this exact dataset release.';

COMMENT ON COLUMN ingest.dataset_release.source_commit_sha IS
'Source generator commit SHA when applicable.';

COMMENT ON COLUMN ingest.dataset_release.generation_parameters IS
'Structured parameters required to reproduce synthetic dataset generation.';

COMMENT ON COLUMN ingest.dataset_release.release_metadata IS
'Additional structured non-secret metadata about this release.';


RESET ROLE;