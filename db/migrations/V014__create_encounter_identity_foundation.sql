-- ============================================================
-- JANUS
-- V014
-- Encounter Identity Foundation
--
-- Introduces source-system-aware identifiers for canonical
-- encounters.
--
-- This table deliberately separates:
--
--     canonical encounter identity
--
-- from:
--
--     external/source encounter identifiers
--
-- It becomes the resolution boundary used later by conditions,
-- medications, observations, assessments, therapy sessions,
-- and other encounter-linked clinical facts.
--
-- No mapping/promotion behavior is introduced here.
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- 1. ENCOUNTER IDENTIFIER
-- ============================================================

CREATE TABLE clinical.encounter_identifier (
    encounter_identifier_id UUID
        PRIMARY KEY
        DEFAULT gen_random_uuid(),

    encounter_id UUID
        NOT NULL
        REFERENCES clinical.encounter (
            encounter_id
        )
        ON DELETE CASCADE,

    identifier_system TEXT
        NOT NULL,

    identifier_value TEXT
        NOT NULL,

    identifier_type TEXT,

    is_primary BOOLEAN
        NOT NULL
        DEFAULT FALSE,

    created_at TIMESTAMPTZ
        NOT NULL
        DEFAULT now(),

    CONSTRAINT
        encounter_identifier_system_value_uk
    UNIQUE (
        identifier_system,
        identifier_value
    ),

    CONSTRAINT
        encounter_identifier_system_not_blank_ck
    CHECK (
        btrim(identifier_system) <> ''
    ),

    CONSTRAINT
        encounter_identifier_value_not_blank_ck
    CHECK (
        btrim(identifier_value) <> ''
    )
);


-- ============================================================
-- 2. LOOKUP INDEXES
-- ============================================================

CREATE INDEX
    idx_encounter_identifier_encounter
ON clinical.encounter_identifier (
    encounter_id
);


CREATE INDEX
    idx_encounter_identifier_system
ON clinical.encounter_identifier (
    identifier_system
);


-- ============================================================
-- 3. DOCUMENT CONTRACT
-- ============================================================

COMMENT ON TABLE clinical.encounter_identifier
IS
'Source-system-aware identifiers associated with canonical clinical encounters. Canonical encounter_id remains internal identity; external identifiers are namespaced by identifier_system.';


COMMENT ON COLUMN
clinical.encounter_identifier.encounter_identifier_id
IS
'Internal immutable identifier for the encounter-identifier association.';


COMMENT ON COLUMN
clinical.encounter_identifier.encounter_id
IS
'Canonical Janus encounter referenced by this external identifier.';


COMMENT ON COLUMN
clinical.encounter_identifier.identifier_system
IS
'Namespace defining the authority and semantic meaning of identifier_value. Example: urn:janus:source:synthea:encounter-id.';


COMMENT ON COLUMN
clinical.encounter_identifier.identifier_value
IS
'Identifier value exactly associated with the source namespace after controlled normalization.';


COMMENT ON COLUMN
clinical.encounter_identifier.identifier_type
IS
'Optional identifier classification. Example: synthea_encounter_id.';


COMMENT ON COLUMN
clinical.encounter_identifier.is_primary
IS
'Indicates whether this identifier is considered a primary identifier for the encounter within the current canonical representation.';


COMMENT ON COLUMN
clinical.encounter_identifier.created_at
IS
'Timestamp when this canonical identifier association was created.';


RESET ROLE;