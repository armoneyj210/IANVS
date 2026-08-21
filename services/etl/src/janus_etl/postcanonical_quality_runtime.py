from dataclasses import dataclass
from decimal import Decimal
from importlib.metadata import PackageNotFoundError, version
from typing import Any
from uuid import UUID

from psycopg.types.json import Jsonb

from janus_etl.config import QualitySettings
from janus_etl.db import open_connection

QUALITY_ENGINE_NAME = "janus-quality"

RULE_CODE = "JANUS-DQ-006"
RULE_VERSION = 1

RULESET_NAME = "janus-postcanonical-lineage"
RULESET_VERSION = "1"


@dataclass(frozen=True)
class LineageEvaluation:
    outcome: str
    records_evaluated: int
    records_passed: int
    records_failed: int
    score: Decimal
    details: dict[str, Any]


def _set_environment(
    cursor,
    settings: QualitySettings,
) -> None:
    cursor.execute(
        """
        SELECT set_config(
            'janus.environment',
            %s,
            false
        );
        """,
        (settings.janus_env,),
    )


def _engine_version() -> str:
    try:
        return version("janus-etl")
    except PackageNotFoundError:
        return "0+local"


def _write_system_event(
    cursor,
    *,
    event_type: str,
    outcome: str,
    message: str,
    metadata: dict[str, Any],
    severity: str = "info",
) -> UUID:
    event = {
        "event_type": event_type,
        "severity": severity,
        "outcome": outcome,
        "component": "postcanonical_quality_runtime",
        "message": message,
        "metadata": metadata,
    }

    cursor.execute(
        """
        SELECT ops.write_system_event(
            %s::jsonb
        ) AS system_event_id;
        """,
        (Jsonb(event),),
    )

    return cursor.fetchone()["system_event_id"]


def _load_dq006_rule(
    settings: QualitySettings,
) -> dict[str, Any]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                data_quality_rule_id,
                rule_code,
                rule_version,
                name,
                severity,
                blocking,
                implementation_ref,
                is_active
            FROM ingest.data_quality_rule
            WHERE rule_code = %s
              AND rule_version = %s
              AND is_active IS TRUE;
            """,
            (
                RULE_CODE,
                RULE_VERSION,
            ),
        )

        rule = cursor.fetchone()

    if rule is None:
        raise RuntimeError(
            "JANUS-DQ-006 v1 is missing or inactive"
        )

    if rule["severity"] != "fatal":
        raise RuntimeError(
            "JANUS-DQ-006 must remain fatal"
        )

    if rule["blocking"] is not True:
        raise RuntimeError(
            "JANUS-DQ-006 must remain blocking"
        )

    return rule


def _resolve_lineage_scope(
    settings: QualitySettings,
    *,
    canonical_promotion_run_id: UUID,
) -> dict[str, Any]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT *
            FROM ingest.resolve_postcanonical_lineage_scope(
                %s
            );
            """,
            (canonical_promotion_run_id,),
        )

        scope = cursor.fetchone()

    if scope is None:
        raise RuntimeError(
            "Post-canonical lineage scope resolver "
            "returned no result"
        )

    if scope["promotion_status"] != "completed":
        raise RuntimeError(
            "DQ-006 requires a completed canonical "
            "promotion"
        )

    return scope


def _load_patient_lineage_evidence(
    settings: QualitySettings,
    *,
    canonical_promotion_run_id: UUID,
) -> dict[str, Any]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT *
            FROM ingest.evaluate_canonical_lineage(
                %s
            );
            """,
            (canonical_promotion_run_id,),
        )

        evidence = cursor.fetchone()

    if evidence is None:
        raise RuntimeError(
            "Patient canonical lineage evaluator "
            "returned no evidence"
        )

    return evidence


def _load_provider_lineage_evidence(
    settings: QualitySettings,
    *,
    canonical_promotion_run_id: UUID,
) -> dict[str, Any]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT *
            FROM ingest.evaluate_provider_canonical_lineage(
                %s
            );
            """,
            (canonical_promotion_run_id,),
        )

        evidence = cursor.fetchone()

    if evidence is None:
        raise RuntimeError(
            "Provider canonical lineage evaluator "
            "returned no evidence"
        )

    return evidence


def _load_lineage_evidence(
    settings: QualitySettings,
    *,
    canonical_promotion_run_id: UUID,
) -> dict[str, Any]:
    scope = _resolve_lineage_scope(
        settings,
        canonical_promotion_run_id=(
            canonical_promotion_run_id
        ),
    )

    mapping_name = scope["mapping_name"]
    mapping_version = scope["mapping_version"]

    if (
        mapping_name == "synthea-patient"
        and mapping_version == "1"
    ):
        return _load_patient_lineage_evidence(
            settings,
            canonical_promotion_run_id=(
                canonical_promotion_run_id
            ),
        )

    if (
        mapping_name == "synthea-provider"
        and mapping_version == "1"
    ):
        return _load_provider_lineage_evidence(
            settings,
            canonical_promotion_run_id=(
                canonical_promotion_run_id
            ),
        )

    raise RuntimeError(
        "Unsupported canonical mapping for "
        "JANUS-DQ-006: "
        f"{mapping_name} v{mapping_version}"
    )

def _json_safe_evidence(
    evidence: dict[str, Any],
) -> dict[str, Any]:
    result: dict[str, Any] = {}

    for key, value in evidence.items():
        if isinstance(value, UUID):
            result[key] = str(value)
        else:
            result[key] = value

    return result


def _evaluate_patient_lineage_evidence(
    evidence: dict[str, Any],
) -> LineageEvaluation:
    expected_patient_sources = evidence[
        "expected_patient_sources"
    ]

    expected_identifier_targets = evidence[
        "expected_identifier_targets"
    ]

    violation_fields = (
        "patient_sources_missing_lineage",
        "patient_sources_with_multiple_targets",
        "patient_orphan_targets",
        "identifier_targets_missing_lineage",
        "identifier_orphan_targets",
        "unexpected_identifier_lineage_edges",
        "wrong_source_artifact_edges",
        "wrong_mapping_version_edges",
        "wrong_transformation_edges",
        "unexpected_target_edges",
        "promotion_counter_mismatch",
        "patient_target_count_mismatch",
    )

    no_violations = all(
        evidence[field] == 0
        for field in violation_fields
    )

    patient_coverage_complete = (
        expected_patient_sources > 0
        and evidence[
            "promotion_records_seen"
        ]
        == expected_patient_sources
        and evidence[
            "promotion_records_failed"
        ]
        == 0
        and evidence[
            "valid_patient_lineage_edges"
        ]
        == expected_patient_sources
        and evidence[
            "patient_lineage_sources"
        ]
        == expected_patient_sources
        and evidence[
            "patient_lineage_targets"
        ]
        == expected_patient_sources
    )

    identifier_coverage_complete = (
        expected_identifier_targets >= 0
        and evidence[
            "valid_identifier_lineage_edges"
        ]
        == expected_identifier_targets
        and evidence[
            "identifier_lineage_targets"
        ]
        == expected_identifier_targets
    )

    aggregate_contract_consistent = (
        evidence["violation_count"] == 0
        and evidence["lineage_complete"] is True
    )

    passed = (
        no_violations
        and patient_coverage_complete
        and identifier_coverage_complete
        and aggregate_contract_consistent
    )

    details = {
        "requirement":
            "100_percent_canonical_lineage",
        "mapping_name":
            evidence["mapping_name"],
        "mapping_version":
            evidence["mapping_version"],
        "evidence":
            _json_safe_evidence(evidence),
        "quality_interpretation": {
            "no_violations":
                no_violations,
            "patient_coverage_complete":
                patient_coverage_complete,
            "identifier_coverage_complete":
                identifier_coverage_complete,
            "aggregate_contract_consistent":
                aggregate_contract_consistent,
        },
    }

    return LineageEvaluation(
        outcome="pass" if passed else "fail",
        records_evaluated=1,
        records_passed=1 if passed else 0,
        records_failed=0 if passed else 1,
        score=(
            Decimal("1.000000")
            if passed
            else Decimal("0.000000")
        ),
        details=details,
    )


def _evaluate_provider_lineage_evidence(
    evidence: dict[str, Any],
) -> LineageEvaluation:
    expected_provider_sources = evidence[
        "expected_provider_sources"
    ]

    providers_with_organization_name = evidence[
        "providers_with_organization_name"
    ]

    violation_fields = (
        "provider_sources_missing_lineage",
        "provider_sources_with_multiple_targets",
        "provider_orphan_targets",
        (
            "provider_targets_missing_"
            "organization_lineage"
        ),
        (
            "provider_targets_with_unexpected_"
            "organization_lineage"
        ),
        (
            "provider_targets_with_multiple_"
            "organization_edges"
        ),
        "organization_orphan_targets",
        "wrong_source_artifact_edges",
        "wrong_mapping_version_edges",
        "wrong_transformation_edges",
        "unexpected_target_edges",
        "promotion_counter_mismatch",
        "provider_target_count_mismatch",
    )

    no_violations = all(
        evidence[field] == 0
        for field in violation_fields
    )

    provider_coverage_complete = (
        expected_provider_sources > 0
        and evidence[
            "promotion_records_seen"
        ]
        == expected_provider_sources
        and evidence[
            "promotion_records_failed"
        ]
        == 0
        and evidence[
            "valid_provider_lineage_edges"
        ]
        == expected_provider_sources
        and evidence[
            "provider_lineage_sources"
        ]
        == expected_provider_sources
        and evidence[
            "provider_lineage_targets"
        ]
        == expected_provider_sources
    )

    organization_coverage_complete = (
        providers_with_organization_name >= 0
        and evidence[
            "valid_organization_lineage_edges"
        ]
        == providers_with_organization_name
        and evidence[
            "organization_lineage_targets"
        ]
        == providers_with_organization_name
    )

    aggregate_contract_consistent = (
        evidence["violation_count"] == 0
        and evidence["lineage_complete"] is True
    )

    passed = (
        no_violations
        and provider_coverage_complete
        and organization_coverage_complete
        and aggregate_contract_consistent
    )

    details = {
        "requirement":
            "100_percent_canonical_lineage",
        "mapping_name":
            evidence["mapping_name"],
        "mapping_version":
            evidence["mapping_version"],
        "evidence":
            _json_safe_evidence(evidence),
        "quality_interpretation": {
            "no_violations":
                no_violations,
            "provider_coverage_complete":
                provider_coverage_complete,
            "organization_coverage_complete":
                organization_coverage_complete,
            "aggregate_contract_consistent":
                aggregate_contract_consistent,
        },
    }

    return LineageEvaluation(
        outcome="pass" if passed else "fail",
        records_evaluated=1,
        records_passed=1 if passed else 0,
        records_failed=0 if passed else 1,
        score=(
            Decimal("1.000000")
            if passed
            else Decimal("0.000000")
        ),
        details=details,
    )


def _evaluate_lineage_evidence(
    evidence: dict[str, Any],
) -> LineageEvaluation:
    mapping_name = evidence["mapping_name"]
    mapping_version = evidence[
        "mapping_version"
    ]

    if (
        mapping_name == "synthea-patient"
        and mapping_version == "1"
    ):
        return _evaluate_patient_lineage_evidence(
            evidence
        )

    if (
        mapping_name == "synthea-provider"
        and mapping_version == "1"
    ):
        return _evaluate_provider_lineage_evidence(
            evidence
        )

    raise RuntimeError(
        "Unsupported canonical mapping for "
        "JANUS-DQ-006 evaluation: "
        f"{mapping_name} v{mapping_version}"
    )


def _create_quality_run(
    settings: QualitySettings,
    *,
    canonical_promotion_run_id: UUID,
    import_batch_id: UUID,
) -> dict[str, Any]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                data_quality_run_id,
                status
            FROM ingest.data_quality_run
            WHERE canonical_promotion_run_id = %s
              AND ruleset_name = %s
              AND ruleset_version = %s
              AND status IN (
                  'running',
                  'completed'
              )
            LIMIT 1;
            """,
            (
                canonical_promotion_run_id,
                RULESET_NAME,
                RULESET_VERSION,
            ),
        )

        existing = cursor.fetchone()

        if existing is not None:
            raise RuntimeError(
                "A post-canonical lineage quality run "
                "already exists for this promotion: "
                f"{existing['data_quality_run_id']} "
                f"({existing['status']})"
            )

        cursor.execute(
            """
            INSERT INTO ingest.data_quality_run (
                import_batch_id,
                canonical_promotion_run_id,
                status,
                engine_name,
                engine_version,
                ruleset_name,
                ruleset_version,
                initiated_by,
                started_at,
                metrics
            )
            VALUES (
                %s,
                %s,
                'running',
                %s,
                %s,
                %s,
                %s,
                current_user,
                clock_timestamp(),
                %s
            )
            RETURNING
                data_quality_run_id,
                import_batch_id,
                canonical_promotion_run_id,
                status,
                ruleset_name,
                ruleset_version,
                initiated_by,
                started_at;
            """,
            (
                import_batch_id,
                canonical_promotion_run_id,
                QUALITY_ENGINE_NAME,
                _engine_version(),
                RULESET_NAME,
                RULESET_VERSION,
                Jsonb(
                    {
                        "authority_principal":
                            "janus_quality_svc",
                        "rule_codes": [
                            RULE_CODE
                        ],
                    }
                ),
            ),
        )

        quality_run = cursor.fetchone()

        event_id = _write_system_event(
            cursor,
            event_type=(
                "data_quality."
                "postcanonical_lineage_started"
            ),
            outcome="success",
            message=(
                "Janus post-canonical lineage "
                "quality run started"
            ),
            metadata={
                "data_quality_run_id": str(
                    quality_run[
                        "data_quality_run_id"
                    ]
                ),
                "canonical_promotion_run_id": str(
                    canonical_promotion_run_id
                ),
                "ruleset_name": RULESET_NAME,
                "ruleset_version": RULESET_VERSION,
            },
        )

    return {
        **quality_run,
        "system_event_id": event_id,
    }


def _persist_result(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    data_quality_run_id: UUID,
    rule: dict[str, Any],
    evaluation: LineageEvaluation,
) -> None:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            INSERT INTO ingest.data_quality_result (
                data_quality_run_id,
                data_quality_rule_id,
                outcome,
                records_evaluated,
                records_passed,
                records_failed,
                records_skipped,
                score,
                details
            )
            VALUES (
                %s,
                %s,
                %s,
                %s,
                %s,
                %s,
                0,
                %s,
                %s
            );
            """,
            (
                data_quality_run_id,
                rule["data_quality_rule_id"],
                evaluation.outcome,
                evaluation.records_evaluated,
                evaluation.records_passed,
                evaluation.records_failed,
                evaluation.score,
                Jsonb(evaluation.details),
            ),
        )

        if evaluation.outcome == "pass":
            return

        cursor.execute(
            """
            INSERT INTO ingest.validation_issue (
                import_batch_id,
                source_file_id,
                source_record_id,
                rule_code,
                severity,
                field_path,
                message,
                details,
                data_quality_run_id,
                data_quality_rule_id
            )
            VALUES (
                %s,
                NULL,
                NULL,
                %s,
                %s,
                'canonical_lineage',
                %s,
                %s,
                %s,
                %s
            );
            """,
            (
                import_batch_id,
                RULE_CODE,
                rule["severity"],
                (
                    "Canonical lineage integrity "
                    "is incomplete."
                ),
                Jsonb(evaluation.details),
                data_quality_run_id,
                rule["data_quality_rule_id"],
            ),
        )


def _complete_quality_run(
    settings: QualitySettings,
    *,
    data_quality_run_id: UUID,
    canonical_promotion_run_id: UUID,
    evaluation: LineageEvaluation,
) -> dict[str, Any]:
    gate_decision = evaluation.outcome

    metrics = {
        "authority_principal":
            "janus_quality_svc",
        "rule_code": RULE_CODE,
        "gate_decision": gate_decision,
        "lineage_complete": (
            gate_decision == "pass"
        ),
    }

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            UPDATE ingest.data_quality_run
            SET
                status = 'completed',
                completed_at = clock_timestamp(),
                rules_evaluated = 1,
                rules_passed = %s,
                rules_warned = 0,
                rules_failed = %s,
                records_evaluated = 1,
                records_quarantined = 0,
                metrics = %s
            WHERE data_quality_run_id = %s
              AND status = 'running'
            RETURNING
                data_quality_run_id,
                status,
                completed_at,
                rules_evaluated,
                rules_passed,
                rules_warned,
                rules_failed,
                records_evaluated,
                records_quarantined;
            """,
            (
                1
                if evaluation.outcome == "pass"
                else 0,
                1
                if evaluation.outcome == "fail"
                else 0,
                Jsonb(metrics),
                data_quality_run_id,
            ),
        )

        completed = cursor.fetchone()

        if completed is None:
            raise RuntimeError(
                "Post-canonical lineage quality "
                "run is no longer running"
            )

        cursor.execute(
            """
            SELECT
                ingest.write_postcanonical_lineage_decision(
                    %s,
                    %s,
                    %s
                )
                AS quality_gate_decision_id;
            """,
            (
                data_quality_run_id,
                gate_decision,
                (
                    "JANUS-DQ-006 independently "
                    "verified complete canonical "
                    "lineage."
                    if gate_decision == "pass"
                    else
                    "JANUS-DQ-006 detected incomplete "
                    "canonical lineage."
                ),
            ),
        )

        gate = cursor.fetchone()

        event_id = _write_system_event(
            cursor,
            event_type=(
                "data_quality."
                "postcanonical_lineage_completed"
            ),
            outcome=(
                "success"
                if gate_decision == "pass"
                else "failure"
            ),
            severity=(
                "info"
                if gate_decision == "pass"
                else "error"
            ),
            message=(
                "Janus post-canonical lineage "
                "quality run completed"
            ),
            metadata={
                "data_quality_run_id": str(
                    data_quality_run_id
                ),
                "canonical_promotion_run_id": str(
                    canonical_promotion_run_id
                ),
                "gate_decision":
                    gate_decision,
            },
        )

    return {
        **completed,
        "gate_decision": gate_decision,
        "quality_gate_decision_id": gate[
            "quality_gate_decision_id"
        ],
        "system_event_id": event_id,
    }


def _fail_quality_run(
    settings: QualitySettings,
    *,
    data_quality_run_id: UUID,
    canonical_promotion_run_id: UUID,
    error: Exception,
) -> None:
    error_summary = {
        "error_type": type(error).__name__,
        "message": str(error)[:2000],
    }

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            UPDATE ingest.data_quality_run
            SET
                status = 'failed',
                completed_at = clock_timestamp(),
                metrics = metrics || %s
            WHERE data_quality_run_id = %s
              AND status = 'running'
            RETURNING data_quality_run_id;
            """,
            (
                Jsonb(
                    {
                        "runtime_error":
                            error_summary
                    }
                ),
                data_quality_run_id,
            ),
        )

        updated = cursor.fetchone()

        if updated is None:
            return

        cursor.execute(
            """
            SELECT
                ingest.write_postcanonical_lineage_decision(
                    %s,
                    'fail',
                    %s
                );
            """,
            (
                data_quality_run_id,
                (
                    "Post-canonical lineage "
                    "quality runtime failed closed: "
                    f"{error_summary['error_type']}"
                ),
            ),
        )

        _write_system_event(
            cursor,
            event_type=(
                "data_quality."
                "postcanonical_lineage_failed"
            ),
            outcome="failure",
            severity="error",
            message=(
                "Janus post-canonical lineage "
                "quality runtime failed"
            ),
            metadata={
                "data_quality_run_id": str(
                    data_quality_run_id
                ),
                "canonical_promotion_run_id": str(
                    canonical_promotion_run_id
                ),
                **error_summary,
            },
        )


def postcanonical_lineage_quality_run(
    settings: QualitySettings,
    *,
    canonical_promotion_run_id: UUID,
) -> dict[str, Any]:
    # First controlled evaluation resolves the promotion scope
    # without granting Quality direct promotion-table access.
    initial_evidence = _load_lineage_evidence(
        settings,
        canonical_promotion_run_id=(
            canonical_promotion_run_id
        ),
    )

    import_batch_id = initial_evidence[
        "import_batch_id"
    ]

    rule = _load_dq006_rule(settings)

    run = _create_quality_run(
        settings,
        canonical_promotion_run_id=(
            canonical_promotion_run_id
        ),
        import_batch_id=import_batch_id,
    )

    data_quality_run_id = run[
        "data_quality_run_id"
    ]

    try:
        # Evaluate again after run creation.
        # The controlled gate writer independently evaluates
        # a third time when certification is written.
        evidence = _load_lineage_evidence(
            settings,
            canonical_promotion_run_id=(
                canonical_promotion_run_id
            ),
        )

        if evidence["import_batch_id"] != import_batch_id:
            raise RuntimeError(
                "Canonical promotion scope changed "
                "during DQ-006 evaluation"
            )

        evaluation = _evaluate_lineage_evidence(
            evidence
        )

        _persist_result(
            settings,
            import_batch_id=import_batch_id,
            data_quality_run_id=(
                data_quality_run_id
            ),
            rule=rule,
            evaluation=evaluation,
        )

        completed = _complete_quality_run(
            settings,
            data_quality_run_id=(
                data_quality_run_id
            ),
            canonical_promotion_run_id=(
                canonical_promotion_run_id
            ),
            evaluation=evaluation,
        )

        return {
            "data_quality_run_id":
                data_quality_run_id,
            "canonical_promotion_run_id":
                canonical_promotion_run_id,
            "import_batch_id":
                import_batch_id,
            "ruleset_name":
                RULESET_NAME,
            "ruleset_version":
                RULESET_VERSION,
            "rule_code":
                RULE_CODE,
            "rule_outcome":
                evaluation.outcome,
            "records_evaluated":
                evaluation.records_evaluated,
            "records_failed":
                evaluation.records_failed,
            "evidence":
                evaluation.details["evidence"],
            **completed,
        }

    except Exception as error:
        _fail_quality_run(
            settings,
            data_quality_run_id=(
                data_quality_run_id
            ),
            canonical_promotion_run_id=(
                canonical_promotion_run_id
            ),
            error=error,
        )
        raise