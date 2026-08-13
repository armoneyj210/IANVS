-- ============================================================
-- JANUS
-- V008
-- Dataset Governance Review & Approval
-- ============================================================

SET ROLE janus_owner;

CREATE SCHEMA IF NOT EXISTS governance
AUTHORIZATION janus_owner;

COMMENT ON SCHEMA governance IS
'Janus governance, approval, policy and human-review control plane.';


-- ============================================================
-- DATASET REVIEW
-- ============================================================

CREATE TABLE governance.dataset_review (
    dataset_review_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    dataset_release_id UUID NOT NULL
        REFERENCES ingest.dataset_release(dataset_release_id),

    review_type TEXT NOT NULL DEFAULT 'initial_use',

    review_version INTEGER NOT NULL,

    intended_use TEXT NOT NULL,
    requested_by TEXT NOT NULL,

    review_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,

    opened_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    UNIQUE (
        dataset_release_id,
        review_type,
        review_version
    ),

    CHECK (review_version > 0),

    CHECK (
        review_type IN (
            'initial_use',
            'renewal',
            'scope_change',
            'risk_reassessment'
        )
    ),

    CHECK (
        jsonb_typeof(review_metadata) = 'object'
    )
);


-- ============================================================
-- DATASET DECISION
--
-- Append-only decision history.
-- ============================================================

CREATE TABLE governance.dataset_decision (
    dataset_decision_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    dataset_review_id UUID NOT NULL
        REFERENCES governance.dataset_review(dataset_review_id),

    decision TEXT NOT NULL,

    risk_level TEXT NOT NULL,

    reviewer_id TEXT NOT NULL,

    db_principal TEXT NOT NULL,

    reason TEXT NOT NULL,

    assessments JSONB NOT NULL DEFAULT '{}'::jsonb,
    evidence JSONB NOT NULL DEFAULT '{}'::jsonb,
    limitations JSONB NOT NULL DEFAULT '{}'::jsonb,

    supersedes_decision_id UUID
        REFERENCES governance.dataset_decision(dataset_decision_id),

    effective_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CHECK (
        decision IN (
            'approved',
            'rejected',
            'changes_required',
            'revoked'
        )
    ),

    CHECK (
        risk_level IN (
            'low',
            'medium',
            'high',
            'critical'
        )
    ),

    CHECK (
        supersedes_decision_id IS NULL
        OR supersedes_decision_id <> dataset_decision_id
    ),

    CHECK (jsonb_typeof(assessments) = 'object'),
    CHECK (jsonb_typeof(evidence) = 'object'),
    CHECK (jsonb_typeof(limitations) = 'object')
);


CREATE UNIQUE INDEX
uq_dataset_decision_supersedes
ON governance.dataset_decision(supersedes_decision_id)
WHERE supersedes_decision_id IS NOT NULL;


-- ============================================================
-- CURRENT GOVERNANCE STATUS
-- ============================================================

CREATE VIEW governance.v_dataset_release_status AS
SELECT
    dr.dataset_release_id,
    dr.release_label,

    COALESCE(latest.decision, 'pending') AS decision,

    latest.risk_level,
    latest.reviewer_id,
    latest.reason,
    latest.effective_at,

    CASE
        WHEN latest.decision = 'approved'
        THEN true
        ELSE false
    END AS import_allowed

FROM ingest.dataset_release dr

LEFT JOIN LATERAL (

    SELECT
        d.decision,
        d.risk_level,
        d.reviewer_id,
        d.reason,
        d.effective_at

    FROM governance.dataset_review r

    JOIN governance.dataset_decision d
      ON d.dataset_review_id = r.dataset_review_id

    WHERE r.dataset_release_id = dr.dataset_release_id

    ORDER BY
        d.effective_at DESC,
        d.created_at DESC,
        d.dataset_decision_id DESC

    LIMIT 1

) latest ON true;


-- ============================================================
-- APPEND-ONLY PROTECTION
-- ============================================================

CREATE OR REPLACE FUNCTION governance.prevent_governance_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, governance
AS $$
BEGIN
    RAISE EXCEPTION
        'Janus governance history is append-only. % is not permitted.',
        TG_OP
        USING ERRCODE = '42501';
END;
$$;


CREATE TRIGGER trg_dataset_review_no_update_delete
BEFORE UPDATE OR DELETE
ON governance.dataset_review
FOR EACH ROW
EXECUTE FUNCTION governance.prevent_governance_mutation();


CREATE TRIGGER trg_dataset_review_no_truncate
BEFORE TRUNCATE
ON governance.dataset_review
FOR EACH STATEMENT
EXECUTE FUNCTION governance.prevent_governance_mutation();


CREATE TRIGGER trg_dataset_decision_no_update_delete
BEFORE UPDATE OR DELETE
ON governance.dataset_decision
FOR EACH ROW
EXECUTE FUNCTION governance.prevent_governance_mutation();


CREATE TRIGGER trg_dataset_decision_no_truncate
BEFORE TRUNCATE
ON governance.dataset_decision
FOR EACH STATEMENT
EXECUTE FUNCTION governance.prevent_governance_mutation();


-- ============================================================
-- OPEN REVIEW
-- ============================================================

CREATE OR REPLACE FUNCTION governance.open_dataset_review(
    p_dataset_release_id UUID,
    p_intended_use TEXT,
    p_requested_by TEXT,
    p_review_type TEXT DEFAULT 'initial_use',
    p_metadata JSONB DEFAULT '{}'::jsonb
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, governance, ingest, ops
AS $$
DECLARE
    v_review_id UUID;
    v_review_version INTEGER;
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM ingest.dataset_release
        WHERE dataset_release_id = p_dataset_release_id
    ) THEN
        RAISE EXCEPTION
            'Unknown dataset release: %',
            p_dataset_release_id;
    END IF;

    IF p_metadata IS NULL
       OR jsonb_typeof(p_metadata) <> 'object'
    THEN
        RAISE EXCEPTION
            'Review metadata must be a JSON object';
    END IF;

    SELECT COALESCE(MAX(review_version), 0) + 1
    INTO v_review_version
    FROM governance.dataset_review
    WHERE dataset_release_id = p_dataset_release_id
      AND review_type = p_review_type;

    INSERT INTO governance.dataset_review (
        dataset_release_id,
        review_type,
        review_version,
        intended_use,
        requested_by,
        review_metadata
    )
    VALUES (
        p_dataset_release_id,
        p_review_type,
        v_review_version,
        p_intended_use,
        p_requested_by,
        p_metadata
    )
    RETURNING dataset_review_id
    INTO v_review_id;

    PERFORM ops.write_audit_event(
        jsonb_build_object(
            'event_type', 'governance',
            'action', 'dataset.review.open',
            'outcome', 'success',
            'severity', 'info',
            'actor_type', 'service',
            'resource_type', 'ingest.dataset_release',
            'resource_id', p_dataset_release_id::TEXT,
            'purpose_of_use', 'dataset_governance',
            'reason', p_intended_use,
            'metadata', jsonb_build_object(
                'dataset_review_id', v_review_id,
                'review_version', v_review_version
            )
        )
    );

    RETURN v_review_id;

END;
$$;


-- ============================================================
-- WRITE GOVERNANCE DECISION
-- ============================================================

CREATE OR REPLACE FUNCTION governance.write_dataset_decision(
    p_dataset_review_id UUID,
    p_decision TEXT,
    p_risk_level TEXT,
    p_reviewer_id TEXT,
    p_reason TEXT,
    p_assessments JSONB DEFAULT '{}'::jsonb,
    p_evidence JSONB DEFAULT '{}'::jsonb,
    p_limitations JSONB DEFAULT '{}'::jsonb,
    p_supersedes_decision_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, governance, ingest, ops
AS $$
DECLARE
    v_decision_id UUID;
    v_release_id UUID;
    v_latest_decision_id UUID;
BEGIN

    SELECT dataset_release_id
    INTO v_release_id
    FROM governance.dataset_review
    WHERE dataset_review_id = p_dataset_review_id;

    IF v_release_id IS NULL THEN
        RAISE EXCEPTION
            'Unknown dataset review: %',
            p_dataset_review_id;
    END IF;


    SELECT dataset_decision_id
    INTO v_latest_decision_id
    FROM governance.dataset_decision
    WHERE dataset_review_id = p_dataset_review_id
    ORDER BY
        effective_at DESC,
        created_at DESC,
        dataset_decision_id DESC
    LIMIT 1;


    IF v_latest_decision_id IS NULL
       AND p_supersedes_decision_id IS NOT NULL
    THEN
        RAISE EXCEPTION
            'No prior decision exists to supersede';
    END IF;


    IF v_latest_decision_id IS NOT NULL
       AND p_supersedes_decision_id IS DISTINCT FROM v_latest_decision_id
    THEN
        RAISE EXCEPTION
            'New decision must supersede the current decision: %',
            v_latest_decision_id;
    END IF;


    INSERT INTO governance.dataset_decision (
        dataset_review_id,
        decision,
        risk_level,
        reviewer_id,
        db_principal,
        reason,
        assessments,
        evidence,
        limitations,
        supersedes_decision_id
    )
    VALUES (
        p_dataset_review_id,
        p_decision,
        p_risk_level,
        p_reviewer_id,
        session_user::TEXT,
        p_reason,
        p_assessments,
        p_evidence,
        p_limitations,
        p_supersedes_decision_id
    )
    RETURNING dataset_decision_id
    INTO v_decision_id;


    PERFORM ops.write_audit_event(
        jsonb_build_object(
            'event_type', 'governance',
            'action', 'dataset.review.decision',
            'outcome', 'success',
            'severity', 'info',
            'actor_type', 'user',
            'actor_id', p_reviewer_id,
            'resource_type', 'ingest.dataset_release',
            'resource_id', v_release_id::TEXT,
            'purpose_of_use', 'dataset_governance',
            'reason', p_reason,
            'metadata', jsonb_build_object(
                'dataset_review_id', p_dataset_review_id,
                'dataset_decision_id', v_decision_id,
                'decision', p_decision,
                'risk_level', p_risk_level
            )
        )
    );

    RETURN v_decision_id;

END;
$$;


-- ============================================================
-- IMPORT GATE
--
-- A release cannot enter an import batch unless its latest
-- governance decision is APPROVED.
-- ============================================================

CREATE OR REPLACE FUNCTION governance.enforce_approved_release_for_import()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, governance, ingest
AS $$
DECLARE
    v_decision TEXT;
BEGIN

    IF NEW.status IN ('pending', 'running') THEN

        SELECT decision
        INTO v_decision
        FROM governance.v_dataset_release_status
        WHERE dataset_release_id = NEW.dataset_release_id;

        IF COALESCE(v_decision, 'pending') <> 'approved' THEN
            RAISE EXCEPTION
                'Dataset release % is not approved for import. Current governance decision: %',
                NEW.dataset_release_id,
                COALESCE(v_decision, 'pending')
                USING ERRCODE = '42501';
        END IF;

    END IF;

    RETURN NEW;

END;
$$;


CREATE TRIGGER trg_import_batch_governance_gate
BEFORE INSERT OR UPDATE OF dataset_release_id, status
ON ingest.import_batch
FOR EACH ROW
EXECUTE FUNCTION governance.enforce_approved_release_for_import();


-- ============================================================
-- SECURITY DEFAULTS
-- ============================================================

REVOKE ALL ON SCHEMA governance FROM PUBLIC;

REVOKE ALL
ON ALL TABLES IN SCHEMA governance
FROM PUBLIC;

REVOKE ALL
ON FUNCTION governance.open_dataset_review(
    UUID, TEXT, TEXT, TEXT, JSONB
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION governance.write_dataset_decision(
    UUID, TEXT, TEXT, TEXT, TEXT,
    JSONB, JSONB, JSONB, UUID
)
FROM PUBLIC;

REVOKE ALL
ON FUNCTION governance.prevent_governance_mutation()
FROM PUBLIC;

REVOKE ALL
ON FUNCTION governance.enforce_approved_release_for_import()
FROM PUBLIC;


COMMENT ON TABLE governance.dataset_review IS
'Append-oriented governance review history for dataset releases.';

COMMENT ON TABLE governance.dataset_decision IS
'Append-oriented approval, rejection, change-request and revocation decisions.';

COMMENT ON VIEW governance.v_dataset_release_status IS
'Current governance decision and import eligibility for each dataset release.';


RESET ROLE;