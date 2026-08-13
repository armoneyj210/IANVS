-- ============================================================
-- JANUS
-- Security Bootstrap 004
-- Database Roles, Ownership and Least Privilege
-- This is fun
-- IMPORTANT:
-- No passwords belong in this file.
-- Run using the PostgreSQL bootstrap/admin account.
-- ============================================================

BEGIN;


-- ============================================================
-- 1. CREATE NON-LOGIN CAPABILITY ROLES
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_owner'
    ) THEN
        CREATE ROLE janus_owner
            NOLOGIN
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_ingest_rw'
    ) THEN
        CREATE ROLE janus_ingest_rw NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_clinical_ro'
    ) THEN
        CREATE ROLE janus_clinical_ro NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_clinical_rw'
    ) THEN
        CREATE ROLE janus_clinical_rw NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_twin_ro'
    ) THEN
        CREATE ROLE janus_twin_ro NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_twin_rw'
    ) THEN
        CREATE ROLE janus_twin_rw NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_simulation_ro'
    ) THEN
        CREATE ROLE janus_simulation_ro NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_simulation_rw'
    ) THEN
        CREATE ROLE janus_simulation_rw NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_ops_write'
    ) THEN
        CREATE ROLE janus_ops_write NOLOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_ops_read'
    ) THEN
        CREATE ROLE janus_ops_read NOLOGIN;
    END IF;

END
$$;


-- ============================================================
-- 2. CREATE LOGIN SERVICE IDENTITIES
-- No passwords are defined here.
-- ============================================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_migrator_svc'
    ) THEN
        CREATE ROLE janus_migrator_svc
            LOGIN
            NOINHERIT
            NOSUPERUSER
            NOCREATEDB
            NOCREATEROLE
            NOREPLICATION
            NOBYPASSRLS;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_etl_svc'
    ) THEN
        CREATE ROLE janus_etl_svc LOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_api_svc'
    ) THEN
        CREATE ROLE janus_api_svc LOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_twin_svc'
    ) THEN
        CREATE ROLE janus_twin_svc LOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_simulation_svc'
    ) THEN
        CREATE ROLE janus_simulation_svc LOGIN;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_roles WHERE rolname = 'janus_ops_svc'
    ) THEN
        CREATE ROLE janus_ops_svc LOGIN;
    END IF;

END
$$;


-- ============================================================
-- 3. ROLE MEMBERSHIPS
--
-- Runtime services inherit capabilities.
-- They CANNOT SET ROLE into capability roles.
--
-- Migrator does NOT inherit owner privileges.
-- It must explicitly SET ROLE janus_owner.
-- ============================================================

GRANT janus_owner
TO janus_migrator_svc
WITH ADMIN FALSE, INHERIT FALSE, SET TRUE;


GRANT janus_ingest_rw, janus_clinical_rw
TO janus_etl_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


GRANT
    janus_clinical_ro,
    janus_twin_ro,
    janus_simulation_ro
TO janus_api_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


GRANT
    janus_clinical_ro,
    janus_twin_rw
TO janus_twin_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


GRANT
    janus_clinical_ro,
    janus_twin_ro,
    janus_simulation_rw
TO janus_simulation_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


GRANT janus_ops_write
TO janus_ops_svc
WITH ADMIN FALSE, INHERIT TRUE, SET FALSE;


-- ============================================================
-- 4. DATABASE OWNERSHIP
-- ============================================================

ALTER DATABASE therapy OWNER TO janus_owner;


-- ============================================================
-- 5. SCHEMA OWNERSHIP
-- ============================================================

ALTER SCHEMA ingest OWNER TO janus_owner;
ALTER SCHEMA clinical OWNER TO janus_owner;
ALTER SCHEMA twin OWNER TO janus_owner;
ALTER SCHEMA simulation OWNER TO janus_owner;
ALTER SCHEMA ops OWNER TO janus_owner;
-- ============================================================
-- FLYWAY METADATA OWNERSHIP / ACCESS
-- ============================================================

ALTER SCHEMA janus_meta OWNER TO janus_owner;

GRANT USAGE, CREATE
ON SCHEMA janus_meta
TO janus_migrator_svc;

ALTER TABLE janus_meta.flyway_schema_history
OWNER TO janus_owner;

GRANT SELECT, INSERT, UPDATE, DELETE
ON TABLE janus_meta.flyway_schema_history
TO janus_migrator_svc;

-- ============================================================
-- 6. EXISTING CLINICAL OBJECT OWNERSHIP
-- ============================================================

ALTER TABLE clinical.patient OWNER TO janus_owner;
ALTER TABLE clinical.patient_identifier OWNER TO janus_owner;
ALTER TABLE clinical.provider OWNER TO janus_owner;
ALTER TABLE clinical.encounter OWNER TO janus_owner;
ALTER TABLE clinical.condition OWNER TO janus_owner;
ALTER TABLE clinical.medication OWNER TO janus_owner;
ALTER TABLE clinical.observation OWNER TO janus_owner;
ALTER TABLE clinical.assessment OWNER TO janus_owner;
ALTER TABLE clinical.therapy_session OWNER TO janus_owner;
ALTER TABLE clinical.goal OWNER TO janus_owner;
ALTER TABLE clinical.intervention OWNER TO janus_owner;
ALTER TABLE clinical.outcome OWNER TO janus_owner;
ALTER TABLE clinical.consent OWNER TO janus_owner;


-- ============================================================
-- 7. EXISTING INGEST OBJECT OWNERSHIP
-- ============================================================

ALTER TABLE ingest.source_system OWNER TO janus_owner;
ALTER TABLE ingest.dataset OWNER TO janus_owner;
ALTER TABLE ingest.dataset_release OWNER TO janus_owner;
ALTER TABLE ingest.source_file OWNER TO janus_owner;
ALTER TABLE ingest.import_batch OWNER TO janus_owner;
ALTER TABLE ingest.source_record OWNER TO janus_owner;
ALTER TABLE ingest.validation_issue OWNER TO janus_owner;
ALTER TABLE ingest.record_lineage OWNER TO janus_owner;


-- ============================================================
-- 8. DEFAULT DENY
-- ============================================================

REVOKE ALL ON DATABASE therapy FROM PUBLIC;

REVOKE CREATE ON SCHEMA public FROM PUBLIC;

REVOKE ALL ON SCHEMA ingest FROM PUBLIC;
REVOKE ALL ON SCHEMA clinical FROM PUBLIC;
REVOKE ALL ON SCHEMA twin FROM PUBLIC;
REVOKE ALL ON SCHEMA simulation FROM PUBLIC;
REVOKE ALL ON SCHEMA ops FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA ingest FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA clinical FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA twin FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA simulation FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA ops FROM PUBLIC;


-- ============================================================
-- 9. DATABASE CONNECTION PERMISSIONS
-- ============================================================

GRANT CONNECT ON DATABASE therapy TO
    janus_migrator_svc,
    janus_etl_svc,
    janus_api_svc,
    janus_twin_svc,
    janus_simulation_svc,
    janus_ops_svc;


-- ============================================================
-- 10. SCHEMA ACCESS
-- USAGE permits resolving objects, not modifying them.
-- ============================================================

GRANT USAGE ON SCHEMA ingest
TO janus_ingest_rw;

GRANT USAGE ON SCHEMA clinical
TO janus_clinical_ro, janus_clinical_rw;

GRANT USAGE ON SCHEMA twin
TO janus_twin_ro, janus_twin_rw;

GRANT USAGE ON SCHEMA simulation
TO janus_simulation_ro, janus_simulation_rw;

GRANT USAGE ON SCHEMA ops
TO janus_ops_write, janus_ops_read;


-- ============================================================
-- 11. EXISTING TABLE PERMISSIONS
-- ============================================================

-- ETL provenance tables
GRANT SELECT, INSERT, UPDATE
ON ALL TABLES IN SCHEMA ingest
TO janus_ingest_rw;


-- Canonical clinical source data
GRANT SELECT
ON ALL TABLES IN SCHEMA clinical
TO janus_clinical_ro;

GRANT SELECT, INSERT, UPDATE
ON ALL TABLES IN SCHEMA clinical
TO janus_clinical_rw;


-- Digital Twin
GRANT SELECT
ON ALL TABLES IN SCHEMA twin
TO janus_twin_ro;

GRANT SELECT, INSERT, UPDATE
ON ALL TABLES IN SCHEMA twin
TO janus_twin_rw;


-- Simulations
GRANT SELECT
ON ALL TABLES IN SCHEMA simulation
TO janus_simulation_ro;

GRANT SELECT, INSERT, UPDATE
ON ALL TABLES IN SCHEMA simulation
TO janus_simulation_rw;


-- Operational telemetry/audit
-- Deliberately no UPDATE or DELETE for writer.
GRANT SELECT, INSERT
ON ALL TABLES IN SCHEMA ops
TO janus_ops_write;

GRANT SELECT
ON ALL TABLES IN SCHEMA ops
TO janus_ops_read;


-- ============================================================
-- 12. FUTURE TABLE DEFAULT PRIVILEGES
--
-- These permissions automatically apply to objects created
-- later BY janus_owner.
-- ============================================================

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA ingest
GRANT SELECT, INSERT, UPDATE ON TABLES
TO janus_ingest_rw;


ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA clinical
GRANT SELECT ON TABLES
TO janus_clinical_ro;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA clinical
GRANT SELECT, INSERT, UPDATE ON TABLES
TO janus_clinical_rw;


ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA twin
GRANT SELECT ON TABLES
TO janus_twin_ro;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA twin
GRANT SELECT, INSERT, UPDATE ON TABLES
TO janus_twin_rw;


ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA simulation
GRANT SELECT ON TABLES
TO janus_simulation_ro;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA simulation
GRANT SELECT, INSERT, UPDATE ON TABLES
TO janus_simulation_rw;


ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA ops
GRANT SELECT, INSERT ON TABLES
TO janus_ops_write;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA ops
GRANT SELECT ON TABLES
TO janus_ops_read;


-- ============================================================
-- 13. FUTURE SEQUENCE PERMISSIONS
-- Needed if SERIAL/IDENTITY sequences are introduced later.
-- ============================================================

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA ingest
GRANT USAGE, SELECT ON SEQUENCES
TO janus_ingest_rw;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA clinical
GRANT USAGE, SELECT ON SEQUENCES
TO janus_clinical_rw;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA twin
GRANT USAGE, SELECT ON SEQUENCES
TO janus_twin_rw;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA simulation
GRANT USAGE, SELECT ON SEQUENCES
TO janus_simulation_rw;

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
IN SCHEMA ops
GRANT USAGE, SELECT ON SEQUENCES
TO janus_ops_write;


-- ============================================================
-- 14. FUNCTIONS ARE DEFAULT-DENY
--
-- PostgreSQL normally grants function EXECUTE to PUBLIC.
-- Janus functions must be explicitly authorized.
-- ============================================================

ALTER DEFAULT PRIVILEGES
FOR ROLE janus_owner
REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;


COMMIT;