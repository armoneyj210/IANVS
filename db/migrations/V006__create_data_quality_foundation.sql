-- ============================================================
-- JANUS
-- V006
-- Enterprise Data Quality Foundation
-- ============================================================

SET ROLE janus_owner;


-- ============================================================
-- DATA QUALITY RULE REGISTRY
--
-- Versioned definitions of approved quality rules.
-- Do not execute arbitrary SQL stored in this table.
-- implementation_ref identifies code implementing the rule.
-- ============================================================

CREATE TABLE ingest.data_quality_rule (
    data_quality_rule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    rule_code TEXT NOT NULL,
    rule_version INTEGER NOT NULL DEFAULT 1,

    name TEXT NOT NULL,
    description TEXT NOT NULL,

    category TEXT NOT NULL,
    rule_scope TEXT NOT NULL,

    resource_type TEXT,
    field_path TEXT,

    severity TEXT NOT NULL,
    blocking BOOLEAN NOT NULL DEFAULT false,

    implementation_ref TEXT NOT NULL,

    parameters JSONB NOT NULL DEFAULT '{}'::jsonb,

    is_active BOOLEAN NOT NULL DEFAULT true,

    effective_from TIMESTAMPTZ NOT NULL DEFAULT now(),
    effective_to TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (rule_code, rule_version),

    CHECK (rule_version > 0),

    CHECK (
        category IN (
            'structural',
            'completeness',
            'validity',
            'uniqueness',
            'referential_integrity',
            'temporal',
            'clinical_plausibility',
            'terminology',
            'provenance',
            'privacy'
        )
    ),

    CHECK (
        rule_scope IN (
            'dataset',
            'batch',
            'file',
            'record',
            'field'
        )
    ),

    CHECK (
        severity IN (
            'info',
            'warning',
            'error',
            'fatal'
        )
    ),

    CHECK (
        effective_to IS NULL
        OR effective_to >= effective_from
    ),

    CHECK (
        jsonb_typeof(parameters) = 'object'
    )
);


-- ============================================================
-- DATA QUALITY RUN
--
-- One execution of the quality engine against an import batch.
-- ============================================================

CREATE TABLE ingest.data_quality_run (
    data_quality_run_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    import_batch_id UUID NOT NULL
        REFERENCES ingest.import_batch(import_batch_id),

    status TEXT NOT NULL DEFAULT 'pending',

    engine_name TEXT NOT NULL,
    engine_version TEXT NOT NULL,

    ruleset_name TEXT NOT NULL,
    ruleset_version TEXT NOT NULL,

    initiated_by TEXT NOT NULL,

    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,

    rules_evaluated INTEGER NOT NULL DEFAULT 0,
    rules_passed INTEGER NOT NULL DEFAULT 0,
    rules_warned INTEGER NOT NULL DEFAULT 0,
    rules_failed INTEGER NOT NULL DEFAULT 0,

    records_evaluated BIGINT NOT NULL DEFAULT 0,
    records_quarantined BIGINT NOT NULL DEFAULT 0,

    metrics JSONB NOT NULL DEFAULT '{}'::jsonb,

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

    CHECK (rules_evaluated >= 0),
    CHECK (rules_passed >= 0),
    CHECK (rules_warned >= 0),
    CHECK (rules_failed >= 0),

    CHECK (
        rules_passed + rules_warned + rules_failed
        <= rules_evaluated
    ),

    CHECK (records_evaluated >= 0),
    CHECK (records_quarantined >= 0),

    CHECK (
        records_quarantined <= records_evaluated
    ),

    CHECK (
        completed_at IS NULL
        OR started_at IS NULL
        OR completed_at >= started_at
    ),

    CHECK (
        jsonb_typeof(metrics) = 'object'
    )
);


-- ============================================================
-- DATA QUALITY RESULT
--
-- Aggregate result of one rule during one quality run.
-- ============================================================

CREATE TABLE ingest.data_quality_result (
    data_quality_result_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    data_quality_run_id UUID NOT NULL
        REFERENCES ingest.data_quality_run(data_quality_run_id),

    data_quality_rule_id UUID NOT NULL
        REFERENCES ingest.data_quality_rule(data_quality_rule_id),

    outcome TEXT NOT NULL,

    records_evaluated BIGINT NOT NULL DEFAULT 0,
    records_passed BIGINT NOT NULL DEFAULT 0,
    records_failed BIGINT NOT NULL DEFAULT 0,
    records_skipped BIGINT NOT NULL DEFAULT 0,

    score NUMERIC(7,6),

    details JSONB NOT NULL DEFAULT '{}'::jsonb,

    evaluated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE (
        data_quality_run_id,
        data_quality_rule_id
    ),

    CHECK (
        outcome IN (
            'pass',
            'warning',
            'fail',
            'error',
            'skipped'
        )
    ),

    CHECK (records_evaluated >= 0),
    CHECK (records_passed >= 0),
    CHECK (records_failed >= 0),
    CHECK (records_skipped >= 0),

    CHECK (
        records_passed + records_failed + records_skipped
        <= records_evaluated
    ),

    CHECK (
        score IS NULL
        OR score BETWEEN 0 AND 1
    ),

    CHECK (
        jsonb_typeof(details) = 'object'
    )
);


-- ============================================================
-- LINK EXISTING VALIDATION ISSUES TO QUALITY FRAMEWORK
-- ============================================================

ALTER TABLE ingest.validation_issue
    ADD COLUMN IF NOT EXISTS data_quality_run_id UUID
        REFERENCES ingest.data_quality_run(data_quality_run_id);

ALTER TABLE ingest.validation_issue
    ADD COLUMN IF NOT EXISTS data_quality_rule_id UUID
        REFERENCES ingest.data_quality_rule(data_quality_rule_id);


-- ============================================================
-- QUARANTINE
--
-- Source records that fail blocking quality rules are isolated
-- before becoming canonical patient data.
-- ============================================================

CREATE TABLE ingest.quarantine_record (
    quarantine_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    source_record_id UUID NOT NULL
        REFERENCES ingest.source_record(source_record_id),

    data_quality_run_id UUID NOT NULL
        REFERENCES ingest.data_quality_run(data_quality_run_id),

    data_quality_rule_id UUID
        REFERENCES ingest.data_quality_rule(data_quality_rule_id),

    status TEXT NOT NULL DEFAULT 'quarantined',

    reason_code TEXT NOT NULL,
    reason TEXT NOT NULL,

    quarantined_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    released_at TIMESTAMPTZ,
    released_by TEXT,

    resolution_notes TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        status IN (
            'quarantined',
            'released',
            'rejected'
        )
    ),

    CHECK (
        released_at IS NULL
        OR released_at >= quarantined_at
    ),

    CHECK (
        status <> 'released'
        OR released_at IS NOT NULL
    )
);


-- Only one active quarantine entry per source record.

CREATE UNIQUE INDEX uq_quarantine_active_record
    ON ingest.quarantine_record(source_record_id)
    WHERE status = 'quarantined';


-- ============================================================
-- QUALITY GATE DECISION
--
-- Explicit decision controlling whether an import batch may
-- proceed toward canonical clinical loading.
--
-- Multiple decisions are allowed so overrides/re-evaluations
-- do not destroy earlier history.
-- ============================================================

CREATE TABLE ingest.quality_gate_decision (
    quality_gate_decision_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    data_quality_run_id UUID NOT NULL
        REFERENCES ingest.data_quality_run(data_quality_run_id),

    decision TEXT NOT NULL,

    decided_by TEXT NOT NULL,
    decision_reason TEXT,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (
        decision IN (
            'pass',
            'fail',
            'override_pass',
            'override_fail'
        )
    ),

    CHECK (
        decision NOT IN ('override_pass', 'override_fail')
        OR decision_reason IS NOT NULL
    )
);


-- ============================================================
-- APPEND-ONLY QUALITY GATE HISTORY
-- ============================================================

CREATE OR REPLACE FUNCTION ingest.prevent_quality_gate_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ingest
AS $$
BEGIN
    RAISE EXCEPTION
        'Janus quality gate decisions are append-only. % is not permitted.',
        TG_OP
        USING ERRCODE = '42501';
END;
$$;


CREATE TRIGGER trg_quality_gate_no_update_delete
BEFORE UPDATE OR DELETE
ON ingest.quality_gate_decision
FOR EACH ROW
EXECUTE FUNCTION ingest.prevent_quality_gate_mutation();


CREATE TRIGGER trg_quality_gate_no_truncate
BEFORE TRUNCATE
ON ingest.quality_gate_decision
FOR EACH STATEMENT
EXECUTE FUNCTION ingest.prevent_quality_gate_mutation();


-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX idx_dq_rule_active
    ON ingest.data_quality_rule(is_active, category);

CREATE INDEX idx_dq_run_batch
    ON ingest.data_quality_run(import_batch_id);

CREATE INDEX idx_dq_run_status
    ON ingest.data_quality_run(status);

CREATE INDEX idx_dq_result_run
    ON ingest.data_quality_result(data_quality_run_id);

CREATE INDEX idx_dq_result_rule
    ON ingest.data_quality_result(data_quality_rule_id);

CREATE INDEX idx_validation_issue_dq_run
    ON ingest.validation_issue(data_quality_run_id);

CREATE INDEX idx_validation_issue_dq_rule
    ON ingest.validation_issue(data_quality_rule_id);

CREATE INDEX idx_quarantine_run
    ON ingest.quarantine_record(data_quality_run_id);

CREATE INDEX idx_quality_gate_run
    ON ingest.quality_gate_decision(data_quality_run_id);


-- ============================================================
-- QUALITY SUMMARY VIEW
--
-- Live operational summary. PostgreSQL views store the query,
-- rather than materializing a second copy of these results.
-- ============================================================

CREATE VIEW ingest.v_data_quality_run_summary AS
SELECT
    r.data_quality_run_id,
    r.import_batch_id,
    r.status,
    r.engine_name,
    r.engine_version,
    r.ruleset_name,
    r.ruleset_version,

    r.rules_evaluated,
    r.rules_passed,
    r.rules_warned,
    r.rules_failed,

    r.records_evaluated,
    r.records_quarantined,

    CASE
        WHEN r.rules_evaluated = 0 THEN NULL
        ELSE ROUND(
            r.rules_passed::NUMERIC
            / r.rules_evaluated::NUMERIC,
            4
        )
    END AS rule_pass_rate,

    r.started_at,
    r.completed_at,

    (
        SELECT q.decision
        FROM ingest.quality_gate_decision q
        WHERE q.data_quality_run_id = r.data_quality_run_id
        ORDER BY q.created_at DESC
        LIMIT 1
    ) AS latest_gate_decision

FROM ingest.data_quality_run r;


-- ============================================================
-- PERMISSIONS
-- ============================================================

REVOKE UPDATE, DELETE, TRUNCATE
ON ingest.quality_gate_decision
FROM PUBLIC, janus_ingest_rw;

REVOKE ALL
ON FUNCTION ingest.prevent_quality_gate_mutation()
FROM PUBLIC;


-- ============================================================
-- INITIAL RULE REGISTRY
--
-- These define Janus rule identities.
-- The ETL quality engine will implement them in Python.
-- ============================================================

INSERT INTO ingest.data_quality_rule (
    rule_code,
    rule_version,
    name,
    description,
    category,
    rule_scope,
    severity,
    blocking,
    implementation_ref
)
VALUES

(
    'JANUS-DQ-001',
    1,
    'Source Record Identifier Required',
    'Every imported source record must have a stable source record key.',
    'completeness',
    'record',
    'fatal',
    true,
    'janus.quality.source_record_identifier'
),

(
    'JANUS-DQ-002',
    1,
    'Dataset Provenance Required',
    'Imported records must trace to an approved dataset release and import batch.',
    'provenance',
    'record',
    'fatal',
    true,
    'janus.quality.provenance'
),

(
    'JANUS-DQ-003',
    1,
    'Patient Identifier Uniqueness',
    'Patient identifiers must be unique within their identifier system.',
    'uniqueness',
    'record',
    'error',
    true,
    'janus.quality.patient_identifier_uniqueness'
),

(
    'JANUS-DQ-004',
    1,
    'Temporal Consistency',
    'Clinical start/end and onset/resolution values must be temporally consistent.',
    'temporal',
    'record',
    'error',
    true,
    'janus.quality.temporal_consistency'
),

(
    'JANUS-DQ-005',
    1,
    'Clinical Terminology Identification',
    'Coded clinical concepts should identify their coding system where available.',
    'terminology',
    'field',
    'warning',
    false,
    'janus.quality.terminology_identification'
),

(
    'JANUS-DQ-006',
    1,
    'Canonical Lineage Required',
    'Every canonical clinical record produced by ETL must retain source-record lineage.',
    'provenance',
    'record',
    'fatal',
    true,
    'janus.quality.canonical_lineage'
)

ON CONFLICT (rule_code, rule_version)
DO NOTHING;


-- ============================================================
-- DOCUMENTATION
-- ============================================================

COMMENT ON TABLE ingest.data_quality_rule IS
'Versioned Janus data-quality rule registry.';

COMMENT ON TABLE ingest.data_quality_run IS
'Execution of a governed quality ruleset against an import batch.';

COMMENT ON TABLE ingest.data_quality_result IS
'Per-rule aggregate result from a Janus data-quality run.';

COMMENT ON TABLE ingest.quarantine_record IS
'Source records isolated from canonical loading due to quality failures.';

COMMENT ON TABLE ingest.quality_gate_decision IS
'Append-oriented quality gate decisions controlling dataset promotion.';

COMMENT ON VIEW ingest.v_data_quality_run_summary IS
'Current summary of Janus data-quality runs and latest gate decisions.';


RESET ROLE;