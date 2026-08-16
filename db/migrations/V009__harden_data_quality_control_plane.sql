-- ============================================================
-- JANUS
-- V009
-- Harden Data Quality Control Plane
--
-- Runtime ETL may execute approved DQ rules and persist
-- results, but it must not modify the rule registry or
-- rewrite historical validation/results.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- DATA QUALITY RULE REGISTRY
--
-- Rules are control-plane configuration.
-- Runtime services may read but not mutate them.
-- Changes must occur through governed migrations.
-- ============================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ingest.data_quality_rule
FROM janus_ingest_rw;

GRANT SELECT
ON ingest.data_quality_rule
TO janus_ingest_rw;


-- ============================================================
-- DATA QUALITY RESULTS
--
-- Results are append-oriented execution evidence.
-- Runtime may create and read results, but not rewrite them.
-- ============================================================

REVOKE UPDATE, DELETE, TRUNCATE
ON ingest.data_quality_result
FROM janus_ingest_rw;

GRANT SELECT, INSERT
ON ingest.data_quality_result
TO janus_ingest_rw;


-- ============================================================
-- VALIDATION ISSUES
--
-- Validation findings are append-oriented evidence.
-- Do not permit the ETL runtime to rewrite findings after
-- they have been recorded.
-- ============================================================

REVOKE UPDATE, DELETE, TRUNCATE
ON ingest.validation_issue
FROM janus_ingest_rw;

GRANT SELECT, INSERT
ON ingest.validation_issue
TO janus_ingest_rw;


-- ============================================================
-- DATA QUALITY RUN
--
-- Runs require UPDATE because their lifecycle transitions:
--
-- pending -> running -> completed / failed
-- ============================================================

REVOKE DELETE, TRUNCATE
ON ingest.data_quality_run
FROM janus_ingest_rw;

GRANT SELECT, INSERT, UPDATE
ON ingest.data_quality_run
TO janus_ingest_rw;


-- ============================================================
-- QUALITY GATE DECISION
--
-- V006 already protects this table with append-only triggers.
-- Reinforce the intended runtime privileges here explicitly.
-- ============================================================

REVOKE UPDATE, DELETE, TRUNCATE
ON ingest.quality_gate_decision
FROM janus_ingest_rw;

GRANT SELECT, INSERT
ON ingest.quality_gate_decision
TO janus_ingest_rw;


RESET ROLE;