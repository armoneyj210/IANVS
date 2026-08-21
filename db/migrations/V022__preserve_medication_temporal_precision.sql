-- ============================================================
-- JANUS
-- V022
-- Preserve Medication Temporal Precision
--
-- Synthea medications.csv START/STOP values are UTC
-- timestamps, not date-only values.
--
-- The original canonical Medication model used DATE columns:
--
--     start_date DATE
--     end_date   DATE
--
-- Promoting the governed source into those columns would
-- silently discard time-of-day and timezone precision.
--
-- No canonical Medication rows have been promoted yet.
-- This migration therefore corrects the canonical model before
-- Medication becomes populated.
--
-- Result:
--
--     start_at TIMESTAMPTZ
--     end_at   TIMESTAMPTZ
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. FAIL CLOSED IF MEDICATION DATA ALREADY EXISTS
-- ============================================================

DO $$
DECLARE
    v_medication_count BIGINT;
BEGIN

    SELECT COUNT(*)
    INTO v_medication_count
    FROM clinical.medication;


    IF v_medication_count <> 0 THEN
        RAISE EXCEPTION
            'V022 requires clinical.medication to be empty before temporal precision migration; found % rows',
            v_medication_count
            USING ERRCODE = '55000';
    END IF;

END;
$$;


-- ============================================================
-- 2. REMOVE OLD DATE-BASED TEMPORAL CHECK
-- ============================================================

ALTER TABLE clinical.medication
DROP CONSTRAINT medication_check;


-- ============================================================
-- 3. RENAME TEMPORAL COLUMNS TO MATCH THEIR SEMANTICS
-- ============================================================

ALTER TABLE clinical.medication
RENAME COLUMN start_date TO start_at;


ALTER TABLE clinical.medication
RENAME COLUMN end_date TO end_at;


-- ============================================================
-- 4. PRESERVE FULL SOURCE TEMPORAL PRECISION
-- ============================================================

ALTER TABLE clinical.medication
ALTER COLUMN start_at
TYPE TIMESTAMPTZ
USING start_at::TIMESTAMPTZ;


ALTER TABLE clinical.medication
ALTER COLUMN end_at
TYPE TIMESTAMPTZ
USING end_at::TIMESTAMPTZ;


-- ============================================================
-- 5. RESTORE TEMPORAL INTEGRITY CHECK
-- ============================================================

ALTER TABLE clinical.medication
ADD CONSTRAINT medication_temporal_check
CHECK (
    end_at IS NULL
    OR start_at IS NULL
    OR end_at >= start_at
);


COMMENT ON COLUMN clinical.medication.start_at
IS
'Medication start instant. Stored as timestamp with time zone to preserve source temporal precision.';


COMMENT ON COLUMN clinical.medication.end_at
IS
'Medication end instant when known. Stored as timestamp with time zone to preserve source temporal precision.';


RESET ROLE;