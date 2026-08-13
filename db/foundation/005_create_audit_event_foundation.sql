-- ============================================================
-- JANUS
-- Migration 005
-- Enterprise Audit / Security / System Event Foundation
-- ============================================================

SET ROLE janus_owner;

BEGIN;


-- ============================================================
-- AUDIT EVENT
--
-- Answers:
-- Who did what?
-- To which patient/resource?
-- Why?
-- Through which service?
-- What was the outcome?
--
-- NOTE:
-- patient_id is intentionally NOT a foreign key.
-- Audit history must have an independent lifecycle from
-- canonical patient records.
-- ============================================================

CREATE TABLE IF NOT EXISTS ops.audit_event (
    audit_event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    schema_version SMALLINT NOT NULL DEFAULT 1,

    event_type TEXT NOT NULL,
    action TEXT NOT NULL,

    outcome TEXT NOT NULL,
    severity TEXT NOT NULL DEFAULT 'info',

    actor_type TEXT NOT NULL DEFAULT 'service',
    actor_id TEXT,

    db_principal TEXT NOT NULL,
    source_service TEXT NOT NULL,
    environment TEXT NOT NULL DEFAULT 'development',

    patient_id UUID,

    resource_type TEXT,
    resource_id TEXT,

    purpose_of_use TEXT,
    reason TEXT,

    correlation_id UUID,
    request_id UUID,

    trace_id TEXT,
    span_id TEXT,

    source_ip INET,
    user_agent TEXT,

    event_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

    CHECK (schema_version > 0),

    CHECK (
        outcome IN (
            'success',
            'failure',
            'denied',
            'allowed',
            'blocked',
            'partial',
            'unknown'
        )
    ),

    CHECK (
        severity IN (
            'debug',
            'info',
            'warning',
            'error',
            'critical'
        )
    ),

    CHECK (
        actor_type IN (
            'user',
            'service',
            'system',
            'agent',
            'model',
            'unknown'
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

    CHECK (
        patient_id IS NULL
        OR purpose_of_use IS NOT NULL
    ),

    CHECK (
        jsonb_typeof(event_metadata) = 'object'
    )
);


-- ============================================================
-- SECURITY EVENT
--
-- Security, access-control, policy, authentication,
-- authorization, or suspicious-activity events.
-- ============================================================

CREATE TABLE IF NOT EXISTS ops.security_event (
    security_event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    schema_version SMALLINT NOT NULL DEFAULT 1,

    event_type TEXT NOT NULL,
    severity TEXT NOT NULL,
    outcome TEXT NOT NULL,

    description TEXT NOT NULL,

    actor_type TEXT NOT NULL DEFAULT 'service',
    actor_id TEXT,

    db_principal TEXT NOT NULL,
    source_service TEXT NOT NULL,
    environment TEXT NOT NULL DEFAULT 'development',

    patient_id UUID,

    resource_type TEXT,
    resource_id TEXT,

    policy_id TEXT,
    rule_id TEXT,

    correlation_id UUID,
    request_id UUID,

    trace_id TEXT,
    span_id TEXT,

    source_ip INET,

    event_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

    CHECK (schema_version > 0),

    CHECK (
        severity IN (
            'info',
            'low',
            'medium',
            'high',
            'critical'
        )
    ),

    CHECK (
        outcome IN (
            'success',
            'failure',
            'denied',
            'allowed',
            'blocked',
            'detected',
            'unknown'
        )
    ),

    CHECK (
        actor_type IN (
            'user',
            'service',
            'system',
            'agent',
            'model',
            'unknown'
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

    CHECK (
        jsonb_typeof(event_metadata) = 'object'
    )
);


-- ============================================================
-- SYSTEM EVENT
--
-- Important application/workflow events.
--
-- This is NOT intended to replace OpenTelemetry or normal
-- application logs later.
-- ============================================================

CREATE TABLE IF NOT EXISTS ops.system_event (
    system_event_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    schema_version SMALLINT NOT NULL DEFAULT 1,

    event_type TEXT NOT NULL,

    severity TEXT NOT NULL DEFAULT 'info',
    outcome TEXT NOT NULL DEFAULT 'success',

    db_principal TEXT NOT NULL,
    source_service TEXT NOT NULL,
    component TEXT,

    environment TEXT NOT NULL DEFAULT 'development',

    message TEXT NOT NULL,

    duration_ms INTEGER,

    correlation_id UUID,
    request_id UUID,

    trace_id TEXT,
    span_id TEXT,

    event_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

    CHECK (schema_version > 0),

    CHECK (
        severity IN (
            'debug',
            'info',
            'warning',
            'error',
            'critical'
        )
    ),

    CHECK (
        outcome IN (
            'success',
            'failure',
            'partial',
            'cancelled',
            'unknown'
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

    CHECK (
        duration_ms IS NULL
        OR duration_ms >= 0
    ),

    CHECK (
        jsonb_typeof(event_metadata) = 'object'
    )
);


-- ============================================================
-- INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_audit_event_time
    ON ops.audit_event(occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_event_patient
    ON ops.audit_event(patient_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_event_actor
    ON ops.audit_event(actor_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_event_principal
    ON ops.audit_event(db_principal, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_audit_event_correlation
    ON ops.audit_event(correlation_id);

CREATE INDEX IF NOT EXISTS idx_audit_event_resource
    ON ops.audit_event(resource_type, resource_id);


CREATE INDEX IF NOT EXISTS idx_security_event_time
    ON ops.security_event(occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_security_event_severity
    ON ops.security_event(severity, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_security_event_patient
    ON ops.security_event(patient_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_security_event_correlation
    ON ops.security_event(correlation_id);


CREATE INDEX IF NOT EXISTS idx_system_event_time
    ON ops.system_event(occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_system_event_service
    ON ops.system_event(source_service, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_system_event_correlation
    ON ops.system_event(correlation_id);


-- ============================================================
-- APPEND-ONLY PROTECTION
--
-- Runtime permissions already deny UPDATE/DELETE.
-- These triggers add defense in depth.
-- ============================================================

CREATE OR REPLACE FUNCTION ops.prevent_event_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $$
BEGIN
    RAISE EXCEPTION
        'Janus event tables are append-only. % is not permitted on %.%',
        TG_OP,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME
        USING ERRCODE = '42501';
END;
$$;


-- Audit event mutation protection

CREATE TRIGGER trg_audit_event_no_mutation
BEFORE UPDATE OR DELETE
ON ops.audit_event
FOR EACH ROW
EXECUTE FUNCTION ops.prevent_event_mutation();

CREATE TRIGGER trg_audit_event_no_truncate
BEFORE TRUNCATE
ON ops.audit_event
FOR EACH STATEMENT
EXECUTE FUNCTION ops.prevent_event_mutation();


-- Security event mutation protection

CREATE TRIGGER trg_security_event_no_mutation
BEFORE UPDATE OR DELETE
ON ops.security_event
FOR EACH ROW
EXECUTE FUNCTION ops.prevent_event_mutation();

CREATE TRIGGER trg_security_event_no_truncate
BEFORE TRUNCATE
ON ops.security_event
FOR EACH STATEMENT
EXECUTE FUNCTION ops.prevent_event_mutation();


-- System event mutation protection

CREATE TRIGGER trg_system_event_no_mutation
BEFORE UPDATE OR DELETE
ON ops.system_event
FOR EACH ROW
EXECUTE FUNCTION ops.prevent_event_mutation();

CREATE TRIGGER trg_system_event_no_truncate
BEFORE TRUNCATE
ON ops.system_event
FOR EACH STATEMENT
EXECUTE FUNCTION ops.prevent_event_mutation();


-- ============================================================
-- CONTROLLED AUDIT WRITE FUNCTION
--
-- Runtime services do NOT directly insert audit rows.
-- They call this function.
--
-- PostgreSQL automatically captures:
--   session_user
--   application_name
--   client IP
-- ============================================================

CREATE OR REPLACE FUNCTION ops.write_audit_event(
    p_event JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $$
DECLARE
    v_event_id UUID;
    v_event_type TEXT;
    v_action TEXT;
    v_outcome TEXT;
    v_patient_id UUID;
    v_purpose TEXT;
    v_service TEXT;
    v_environment TEXT;
BEGIN

    IF p_event IS NULL
       OR jsonb_typeof(p_event) <> 'object'
    THEN
        RAISE EXCEPTION
            'Audit event must be a JSON object';
    END IF;

    v_event_type :=
        NULLIF(btrim(p_event ->> 'event_type'), '');

    v_action :=
        NULLIF(btrim(p_event ->> 'action'), '');

    v_outcome :=
        NULLIF(btrim(p_event ->> 'outcome'), '');

    IF v_event_type IS NULL
       OR v_action IS NULL
       OR v_outcome IS NULL
    THEN
        RAISE EXCEPTION
            'event_type, action and outcome are required';
    END IF;

    v_patient_id :=
        NULLIF(p_event ->> 'patient_id', '')::UUID;

    v_purpose :=
        NULLIF(btrim(p_event ->> 'purpose_of_use'), '');

    IF v_patient_id IS NOT NULL
       AND v_purpose IS NULL
    THEN
        RAISE EXCEPTION
            'purpose_of_use is required for patient-related audit events';
    END IF;

    v_service :=
        COALESCE(
            NULLIF(current_setting('application_name', true), ''),
            session_user::TEXT
        );

    v_environment :=
        COALESCE(
            NULLIF(current_setting('janus.environment', true), ''),
            NULLIF(p_event ->> 'environment', ''),
            'development'
        );

    INSERT INTO ops.audit_event (
        event_type,
        action,
        outcome,
        severity,

        actor_type,
        actor_id,

        db_principal,
        source_service,
        environment,

        patient_id,

        resource_type,
        resource_id,

        purpose_of_use,
        reason,

        correlation_id,
        request_id,

        trace_id,
        span_id,

        source_ip,
        user_agent,

        event_metadata
    )
    VALUES (
        v_event_type,
        v_action,
        v_outcome,

        COALESCE(
            NULLIF(p_event ->> 'severity', ''),
            'info'
        ),

        COALESCE(
            NULLIF(p_event ->> 'actor_type', ''),
            'service'
        ),

        NULLIF(p_event ->> 'actor_id', ''),

        session_user::TEXT,
        v_service,
        v_environment,

        v_patient_id,

        NULLIF(p_event ->> 'resource_type', ''),
        NULLIF(p_event ->> 'resource_id', ''),

        v_purpose,
        NULLIF(p_event ->> 'reason', ''),

        NULLIF(p_event ->> 'correlation_id', '')::UUID,
        NULLIF(p_event ->> 'request_id', '')::UUID,

        NULLIF(p_event ->> 'trace_id', ''),
        NULLIF(p_event ->> 'span_id', ''),

        inet_client_addr(),

        NULLIF(p_event ->> 'user_agent', ''),

        COALESCE(
            p_event -> 'metadata',
            '{}'::jsonb
        )
    )
    RETURNING audit_event_id
    INTO v_event_id;

    RETURN v_event_id;

END;
$$;


-- ============================================================
-- CONTROLLED SECURITY EVENT WRITE FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION ops.write_security_event(
    p_event JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $$
DECLARE
    v_event_id UUID;
    v_service TEXT;
    v_environment TEXT;
BEGIN

    IF p_event IS NULL
       OR jsonb_typeof(p_event) <> 'object'
    THEN
        RAISE EXCEPTION
            'Security event must be a JSON object';
    END IF;

    IF NULLIF(p_event ->> 'event_type', '') IS NULL
       OR NULLIF(p_event ->> 'severity', '') IS NULL
       OR NULLIF(p_event ->> 'outcome', '') IS NULL
       OR NULLIF(p_event ->> 'description', '') IS NULL
    THEN
        RAISE EXCEPTION
            'event_type, severity, outcome and description are required';
    END IF;

    v_service :=
        COALESCE(
            NULLIF(current_setting('application_name', true), ''),
            session_user::TEXT
        );

    v_environment :=
        COALESCE(
            NULLIF(current_setting('janus.environment', true), ''),
            NULLIF(p_event ->> 'environment', ''),
            'development'
        );

    INSERT INTO ops.security_event (
        event_type,
        severity,
        outcome,
        description,

        actor_type,
        actor_id,

        db_principal,
        source_service,
        environment,

        patient_id,

        resource_type,
        resource_id,

        policy_id,
        rule_id,

        correlation_id,
        request_id,

        trace_id,
        span_id,

        source_ip,

        event_metadata
    )
    VALUES (
        p_event ->> 'event_type',
        p_event ->> 'severity',
        p_event ->> 'outcome',
        p_event ->> 'description',

        COALESCE(
            NULLIF(p_event ->> 'actor_type', ''),
            'service'
        ),

        NULLIF(p_event ->> 'actor_id', ''),

        session_user::TEXT,
        v_service,
        v_environment,

        NULLIF(p_event ->> 'patient_id', '')::UUID,

        NULLIF(p_event ->> 'resource_type', ''),
        NULLIF(p_event ->> 'resource_id', ''),

        NULLIF(p_event ->> 'policy_id', ''),
        NULLIF(p_event ->> 'rule_id', ''),

        NULLIF(p_event ->> 'correlation_id', '')::UUID,
        NULLIF(p_event ->> 'request_id', '')::UUID,

        NULLIF(p_event ->> 'trace_id', ''),
        NULLIF(p_event ->> 'span_id', ''),

        inet_client_addr(),

        COALESCE(
            p_event -> 'metadata',
            '{}'::jsonb
        )
    )
    RETURNING security_event_id
    INTO v_event_id;

    RETURN v_event_id;

END;
$$;


-- ============================================================
-- CONTROLLED SYSTEM EVENT WRITE FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION ops.write_system_event(
    p_event JSONB
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $$
DECLARE
    v_event_id UUID;
    v_service TEXT;
    v_environment TEXT;
BEGIN

    IF p_event IS NULL
       OR jsonb_typeof(p_event) <> 'object'
    THEN
        RAISE EXCEPTION
            'System event must be a JSON object';
    END IF;

    IF NULLIF(p_event ->> 'event_type', '') IS NULL
       OR NULLIF(p_event ->> 'message', '') IS NULL
    THEN
        RAISE EXCEPTION
            'event_type and message are required';
    END IF;

    v_service :=
        COALESCE(
            NULLIF(current_setting('application_name', true), ''),
            session_user::TEXT
        );

    v_environment :=
        COALESCE(
            NULLIF(current_setting('janus.environment', true), ''),
            NULLIF(p_event ->> 'environment', ''),
            'development'
        );

    INSERT INTO ops.system_event (
        event_type,
        severity,
        outcome,

        db_principal,
        source_service,
        component,
        environment,

        message,
        duration_ms,

        correlation_id,
        request_id,

        trace_id,
        span_id,

        event_metadata
    )
    VALUES (
        p_event ->> 'event_type',

        COALESCE(
            NULLIF(p_event ->> 'severity', ''),
            'info'
        ),

        COALESCE(
            NULLIF(p_event ->> 'outcome', ''),
            'success'
        ),

        session_user::TEXT,
        v_service,

        NULLIF(p_event ->> 'component', ''),

        v_environment,

        p_event ->> 'message',

        NULLIF(p_event ->> 'duration_ms', '')::INTEGER,

        NULLIF(p_event ->> 'correlation_id', '')::UUID,
        NULLIF(p_event ->> 'request_id', '')::UUID,

        NULLIF(p_event ->> 'trace_id', ''),
        NULLIF(p_event ->> 'span_id', ''),

        COALESCE(
            p_event -> 'metadata',
            '{}'::jsonb
        )
    )
    RETURNING system_event_id
    INTO v_event_id;

    RETURN v_event_id;

END;
$$;


-- ============================================================
-- REMOVE DIRECT EVENT INSERT PERMISSION
--
-- Events must enter through controlled write functions.
-- ============================================================

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ops.audit_event
FROM PUBLIC, janus_ops_write;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ops.security_event
FROM PUBLIC, janus_ops_write;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
ON ops.system_event
FROM PUBLIC, janus_ops_write;


-- ============================================================
-- RUNTIME SERVICES MAY RESOLVE OPS FUNCTIONS
-- but still cannot read the underlying event tables.
-- ============================================================

GRANT USAGE ON SCHEMA ops TO
    janus_api_svc,
    janus_etl_svc,
    janus_twin_svc,
    janus_simulation_svc,
    janus_ops_svc,
    janus_migrator_svc;


-- ============================================================
-- FUNCTION SECURITY
-- ============================================================

REVOKE ALL
ON FUNCTION ops.write_audit_event(JSONB)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION ops.write_security_event(JSONB)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION ops.write_system_event(JSONB)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION ops.prevent_event_mutation()
FROM PUBLIC;


GRANT EXECUTE
ON FUNCTION ops.write_audit_event(JSONB)
TO
    janus_api_svc,
    janus_etl_svc,
    janus_twin_svc,
    janus_simulation_svc,
    janus_ops_svc,
    janus_migrator_svc;


GRANT EXECUTE
ON FUNCTION ops.write_security_event(JSONB)
TO
    janus_api_svc,
    janus_etl_svc,
    janus_twin_svc,
    janus_simulation_svc,
    janus_ops_svc,
    janus_migrator_svc;


GRANT EXECUTE
ON FUNCTION ops.write_system_event(JSONB)
TO
    janus_api_svc,
    janus_etl_svc,
    janus_twin_svc,
    janus_simulation_svc,
    janus_ops_svc,
    janus_migrator_svc;


-- ============================================================
-- DOCUMENTATION
-- ============================================================

COMMENT ON TABLE ops.audit_event IS
'Append-oriented Janus audit trail for access, actions, resources, purpose, actor and outcome.';

COMMENT ON TABLE ops.security_event IS
'Append-oriented Janus security and policy event history.';

COMMENT ON TABLE ops.system_event IS
'Append-oriented Janus control-plane workflow and system event history.';

COMMENT ON COLUMN ops.audit_event.patient_id IS
'Logical patient reference intentionally not enforced by FK so audit history has an independent retention lifecycle.';

COMMENT ON COLUMN ops.audit_event.event_metadata IS
'Structured non-secret metadata. Do not store clinical notes, raw PHI, credentials, tokens, prompts or other sensitive payloads here.';


COMMIT;

RESET ROLE;