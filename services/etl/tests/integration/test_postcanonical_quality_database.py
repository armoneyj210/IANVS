import os
from uuid import UUID

import pytest
from psycopg.errors import InsufficientPrivilege

from janus_etl.config import (
    get_quality_settings,
)
from janus_etl.db import open_connection
from janus_etl.postcanonical_quality_runtime import (
    _evaluate_lineage_evidence,
    _load_dq006_rule,
    _load_lineage_evidence,
)

RUN_INTEGRATION_TESTS = (
    os.getenv(
        "JANUS_RUN_INTEGRATION_TESTS"
    )
    == "1"
)

PROMOTION_RUN_ID = os.getenv(
    "JANUS_TEST_CANONICAL_PROMOTION_RUN_ID"
)
PROVIDER_PROMOTION_RUN_ID = os.getenv(
    "JANUS_TEST_PROVIDER_PROMOTION_RUN_ID"
)


pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not RUN_INTEGRATION_TESTS,
        reason=(
            "Set JANUS_RUN_INTEGRATION_TESTS=1 "
            "to run database integration tests"
        ),
    ),
]


def test_dq006_registry_contract() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    rule = _load_dq006_rule(settings)

    assert rule["rule_code"] == "JANUS-DQ-006"
    assert rule["rule_version"] == 1
    assert rule["severity"] == "fatal"
    assert rule["blocking"] is True


def test_postcanonical_quality_permissions() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        cursor.execute(
            """
            SELECT
                session_user AS principal,

                has_schema_privilege(
                    current_user,
                    'clinical',
                    'USAGE'
                ) AS clinical_usage,

                has_table_privilege(
                    current_user,
                    'ingest.canonical_promotion_run',
                    'SELECT'
                ) AS promotion_select,

                has_function_privilege(
                    current_user,
                    'ingest.evaluate_canonical_lineage(uuid)',
                    'EXECUTE'
                ) AS evidence_execute,

                has_function_privilege(
                    current_user,
                    'ingest.resolve_postcanonical_lineage_scope(uuid)',
                    'EXECUTE'
                ) AS scope_execute,

                has_function_privilege(
                    current_user,
                    'ingest.evaluate_provider_canonical_lineage(uuid)',
                    'EXECUTE'
                ) AS provider_evidence_execute,

                has_function_privilege(
                    current_user,
                    'ingest.write_postcanonical_lineage_decision(uuid,text,text)',
                    'EXECUTE'
                ) AS gate_execute;
            """
        )

        permissions = cursor.fetchone()

    assert permissions is not None

    assert (
        permissions["principal"]
        == "janus_quality_svc"
    )

    assert permissions["clinical_usage"] is False
    assert permissions["promotion_select"] is False

    assert permissions["evidence_execute"] is True
    assert permissions["gate_execute"] is True
    assert permissions["scope_execute"] is True

    assert (
        permissions[
            "provider_evidence_execute"
        ]
        is True
    )

def test_direct_clinical_access_remains_denied() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT patient_id
                FROM clinical.patient
                LIMIT 1;
                """
            )

        conn.rollback()


@pytest.mark.skipif(
    not PROMOTION_RUN_ID,
    reason=(
        "Set JANUS_TEST_CANONICAL_PROMOTION_RUN_ID "
        "to test DQ-006 evidence"
    ),
)
def test_patient_promotion_passes_dq006_evidence() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    promotion_run_id = UUID(
        PROMOTION_RUN_ID
    )

    evidence = _load_lineage_evidence(
        settings,
        canonical_promotion_run_id=(
            promotion_run_id
        ),
    )

    evaluation = _evaluate_lineage_evidence(
        evidence
    )

    assert (
        evidence["expected_patient_sources"]
        == 112
    )

    assert (
        evidence[
            "patient_sources_missing_lineage"
        ]
        == 0
    )

    assert evidence["violation_count"] == 0
    assert evidence["lineage_complete"] is True

    assert evaluation.outcome == "pass"

@pytest.mark.skipif(
    not PROVIDER_PROMOTION_RUN_ID,
    reason=(
        "Set JANUS_TEST_PROVIDER_PROMOTION_RUN_ID "
        "to test Provider DQ-006 evidence"
    ),
)
def test_provider_promotion_passes_dq006_evidence() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    promotion_run_id = UUID(
        PROVIDER_PROMOTION_RUN_ID
    )

    evidence = _load_lineage_evidence(
        settings,
        canonical_promotion_run_id=(
            promotion_run_id
        ),
    )

    evaluation = _evaluate_lineage_evidence(
        evidence
    )

    assert (
        evidence["mapping_name"]
        == "synthea-provider"
    )

    assert evidence["mapping_version"] == "1"

    assert (
        evidence["expected_provider_sources"]
        == 264
    )

    assert (
        evidence[
            "provider_sources_missing_lineage"
        ]
        == 0
    )

    assert (
        evidence[
            "provider_targets_missing_"
            "organization_lineage"
        ]
        == 0
    )

    assert (
        evidence[
            "provider_targets_with_unexpected_"
            "organization_lineage"
        ]
        == 0
    )

    assert (
        evidence[
            "provider_targets_with_multiple_"
            "organization_edges"
        ]
        == 0
    )

    assert (
        evidence["violation_count"]
        == 0
    )

    assert (
        evidence["lineage_complete"]
        is True
    )

    assert evaluation.outcome == "pass"