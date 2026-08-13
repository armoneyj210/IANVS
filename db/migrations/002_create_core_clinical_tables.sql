-- Janus
-- Migration 002
-- Core Clinical Data Model

BEGIN;

-- =========================================================
-- PATIENT
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.patient (
    patient_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    given_name TEXT,
    family_name TEXT,

    birth_date DATE,
    deceased_date DATE,

    sex_at_birth TEXT,
    gender_identity TEXT,
    race TEXT,
    ethnicity TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        deceased_date IS NULL
        OR birth_date IS NULL
        OR deceased_date >= birth_date
    )
);


-- =========================================================
-- PATIENT IDENTIFIER
-- Example: Synthea ID, FHIR ID, MRN
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.patient_identifier (
    patient_identifier_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id)
        ON DELETE CASCADE,

    identifier_system TEXT NOT NULL,
    identifier_value TEXT NOT NULL,
    identifier_type TEXT,

    is_primary BOOLEAN NOT NULL DEFAULT false,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (identifier_system, identifier_value)
);


-- =========================================================
-- PROVIDER
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.provider (
    provider_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    external_id TEXT,

    display_name TEXT,
    organization_name TEXT,
    specialty TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =========================================================
-- ENCOUNTER
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.encounter (
    encounter_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    provider_id UUID
        REFERENCES clinical.provider(provider_id),

    encounter_type TEXT,
    status TEXT,

    start_at TIMESTAMPTZ NOT NULL,
    end_at TIMESTAMPTZ,

    reason TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        end_at IS NULL
        OR end_at >= start_at
    )
);


-- =========================================================
-- CONDITION / DIAGNOSIS
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.condition (
    condition_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    encounter_id UUID
        REFERENCES clinical.encounter(encounter_id),

    code_system TEXT,
    code TEXT,
    display TEXT NOT NULL,

    clinical_status TEXT,

    onset_date DATE,
    resolved_date DATE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        resolved_date IS NULL
        OR onset_date IS NULL
        OR resolved_date >= onset_date
    )
);


-- =========================================================
-- MEDICATION
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.medication (
    medication_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    encounter_id UUID
        REFERENCES clinical.encounter(encounter_id),

    code_system TEXT,
    code TEXT,
    display TEXT NOT NULL,

    status TEXT,

    start_date DATE,
    end_date DATE,

    dose_text TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        end_date IS NULL
        OR start_date IS NULL
        OR end_date >= start_date
    )
);


-- =========================================================
-- OBSERVATION
-- Generic measurable clinical data
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.observation (
    observation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    encounter_id UUID
        REFERENCES clinical.encounter(encounter_id),

    code_system TEXT,
    code TEXT,
    display TEXT NOT NULL,

    value_numeric NUMERIC,
    value_text TEXT,
    unit TEXT,

    observed_at TIMESTAMPTZ NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =========================================================
-- ASSESSMENT
-- PHQ-9, GAD-7, etc.
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.assessment (
    assessment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    encounter_id UUID
        REFERENCES clinical.encounter(encounter_id),

    instrument_code TEXT NOT NULL,
    instrument_name TEXT,

    score NUMERIC,
    severity TEXT,

    responses JSONB,

    performed_at TIMESTAMPTZ NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =========================================================
-- THERAPY SESSION
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.therapy_session (
    therapy_session_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    provider_id UUID
        REFERENCES clinical.provider(provider_id),

    encounter_id UUID
        REFERENCES clinical.encounter(encounter_id),

    modality TEXT,

    session_number INTEGER,

    started_at TIMESTAMPTZ NOT NULL,
    ended_at TIMESTAMPTZ,

    session_summary TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        ended_at IS NULL
        OR ended_at >= started_at
    )
);


-- =========================================================
-- THERAPY GOAL
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.goal (
    goal_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    description TEXT NOT NULL,

    status TEXT NOT NULL DEFAULT 'active',

    target_date DATE,
    achieved_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =========================================================
-- INTERVENTION
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.intervention (
    intervention_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    therapy_session_id UUID
        REFERENCES clinical.therapy_session(therapy_session_id),

    goal_id UUID
        REFERENCES clinical.goal(goal_id),

    intervention_type TEXT NOT NULL,
    description TEXT,

    performed_at TIMESTAMPTZ NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =========================================================
-- OUTCOME
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.outcome (
    outcome_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    goal_id UUID
        REFERENCES clinical.goal(goal_id),

    intervention_id UUID
        REFERENCES clinical.intervention(intervention_id),

    assessment_id UUID
        REFERENCES clinical.assessment(assessment_id),

    outcome_type TEXT NOT NULL,

    value_numeric NUMERIC,
    value_text TEXT,
    unit TEXT,

    measured_at TIMESTAMPTZ NOT NULL,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- =========================================================
-- CONSENT
-- =========================================================

CREATE TABLE IF NOT EXISTS clinical.consent (
    consent_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    patient_id UUID NOT NULL
        REFERENCES clinical.patient(patient_id),

    consent_type TEXT NOT NULL,
    status TEXT NOT NULL,

    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,

    scope JSONB,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        effective_to IS NULL
        OR effective_to >= effective_from
    )
);


-- =========================================================
-- BASIC INDEXES
-- =========================================================

CREATE INDEX IF NOT EXISTS idx_encounter_patient
    ON clinical.encounter(patient_id);

CREATE INDEX IF NOT EXISTS idx_condition_patient
    ON clinical.condition(patient_id);

CREATE INDEX IF NOT EXISTS idx_medication_patient
    ON clinical.medication(patient_id);

CREATE INDEX IF NOT EXISTS idx_observation_patient
    ON clinical.observation(patient_id);

CREATE INDEX IF NOT EXISTS idx_observation_patient_time
    ON clinical.observation(patient_id, observed_at);

CREATE INDEX IF NOT EXISTS idx_assessment_patient
    ON clinical.assessment(patient_id);

CREATE INDEX IF NOT EXISTS idx_assessment_patient_time
    ON clinical.assessment(patient_id, performed_at);

CREATE INDEX IF NOT EXISTS idx_therapy_session_patient
    ON clinical.therapy_session(patient_id);

CREATE INDEX IF NOT EXISTS idx_goal_patient
    ON clinical.goal(patient_id);

CREATE INDEX IF NOT EXISTS idx_intervention_patient
    ON clinical.intervention(patient_id);

CREATE INDEX IF NOT EXISTS idx_outcome_patient
    ON clinical.outcome(patient_id);

CREATE INDEX IF NOT EXISTS idx_consent_patient
    ON clinical.consent(patient_id);

COMMIT;