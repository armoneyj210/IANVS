-- ============================================================
-- JANUS
-- Security Bootstrap 008
-- Dataset Governance Identity
-- ============================================================

BEGIN;

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'janus_governance_review'
    ) THEN
        CREATE ROLE janus_governance_review
            NOLOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'janus_governance_svc'
    ) THEN
        CREATE ROLE janus_governance_svc
            LOGIN
            INHERIT
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
    END IF;

END
$$;


GRANT janus_governance_review
TO janus_governance_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


GRANT CONNECT
ON DATABASE therapy
TO janus_governance_svc;


GRANT USAGE
ON SCHEMA ingest
TO janus_governance_review;


GRANT USAGE
ON SCHEMA governance
TO janus_governance_review;


GRANT SELECT
ON
    ingest.source_system,
    ingest.dataset,
    ingest.dataset_release,
    ingest.source_file
TO janus_governance_review;


GRANT SELECT
ON
    governance.dataset_review,
    governance.dataset_decision,
    governance.v_dataset_release_status
TO janus_governance_review;


GRANT EXECUTE
ON FUNCTION governance.open_dataset_review(
    UUID, TEXT, TEXT, TEXT, JSONB
)
TO janus_governance_review;


GRANT EXECUTE
ON FUNCTION governance.write_dataset_decision(
    UUID, TEXT, TEXT, TEXT, TEXT,
    JSONB, JSONB, JSONB, UUID
)
TO janus_governance_review;


REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON governance.dataset_review
FROM janus_governance_review;


REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON governance.dataset_decision
FROM janus_governance_review;


COMMIT;