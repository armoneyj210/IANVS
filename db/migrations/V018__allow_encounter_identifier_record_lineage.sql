-- ============================================================
-- JANUS
-- V018
-- Allow Encounter Identifier as a Record Lineage Target
--
-- V017 introduced source-aware Encounter identity through:
--
--     clinical.encounter_identifier
--
-- The existing ingest.record_lineage target-table allowlist
-- predates that table and therefore rejects otherwise-valid
-- Encounter-Identifier provenance.
--
-- This migration preserves the existing allowlist exactly and
-- adds only:
--
--     encounter_identifier
--
-- Forward-only migration. V017 remains unchanged.
-- ============================================================

SET ROLE janus_owner;


ALTER TABLE ingest.record_lineage
DROP CONSTRAINT record_lineage_target_table_check;


ALTER TABLE ingest.record_lineage
ADD CONSTRAINT record_lineage_target_table_check
CHECK (
    target_table IN (
        'patient',
        'patient_identifier',
        'provider',
        'encounter',
        'encounter_identifier',
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
);


COMMENT ON CONSTRAINT
record_lineage_target_table_check
ON ingest.record_lineage
IS
'Allowlisted canonical target tables for governed source-to-canonical record lineage. Includes source-aware Patient and Encounter identifier targets.';


RESET ROLE;