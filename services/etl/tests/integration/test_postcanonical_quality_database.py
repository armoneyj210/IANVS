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
ENCOUNTER_PROMOTION_RUN_ID = os.getenv(
    "JANUS_TEST_ENCOUNTER_PROMOTION_RUN_ID"
)
CONDITION_PROMOTION_RUN_ID = os.getenv(
    "JANUS_TEST_CONDITION_PROMOTION_RUN_ID"
)
MEDICATION_PROMOTION_RUN_ID = os.getenv(
    "JANUS_TEST_MEDICATION_PROMOTION_RUN_ID"
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
                    'ingest.evaluate_encounter_canonical_lineage(uuid)',
                    'EXECUTE'
                ) AS encounter_evidence_execute,

                has_function_privilege(
                    current_user,
                    'ingest.evaluate_condition_canonical_lineage(uuid)',
                    'EXECUTE'
                ) AS condition_evidence_execute,

                has_function_privilege( 
                    current_user,
                    'ingest.evaluate_medication_canonical_lineage(uuid)',
                    'EXECUTE'
                ) AS medication_evidence_execute,

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
    assert (
        permissions[
            "encounter_evidence_execute"
        ]
        is True
    )

    assert (
        permissions[
            "condition_evidence_execute"
        ]
        is True
    )

    assert (
        permissions[
            "medication_evidence_execute"
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

@pytest.mark.skipif(
    not ENCOUNTER_PROMOTION_RUN_ID,
    reason=(
        "Set JANUS_TEST_ENCOUNTER_PROMOTION_RUN_ID "
        "to test Encounter DQ-006 evidence"
    ),
)
def test_encounter_promotion_passes_dq006_evidence() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    promotion_run_id = UUID(
        ENCOUNTER_PROMOTION_RUN_ID
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
        == "synthea-encounter"
    )

    assert evidence["mapping_version"] == "1"

    assert (
        evidence["expected_encounter_sources"]
        == 6950
    )

    assert (
        evidence[
            "valid_encounter_lineage_edges"
        ]
        == 6950
    )

    assert (
        evidence[
            "valid_identifier_lineage_edges"
        ]
        == 6950
    )

    assert (
        evidence[
            "encounter_sources_missing_lineage"
        ]
        == 0
    )

    assert (
        evidence[
            "identifier_sources_missing_lineage"
        ]
        == 0
    )

    assert (
        evidence[
            "invalid_identifier_contract"
        ]
        == 0
    )

    assert (
        evidence[
            "encounter_identifier_pair_mismatches"
        ]
        == 0
    )

    assert (
        evidence[
            "uncertified_patient_dependencies"
        ]
        == 0
    )

    assert (
        evidence[
            "uncertified_provider_dependencies"
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

@pytest.mark.skipif(
    not CONDITION_PROMOTION_RUN_ID,
    reason=(
        "Set JANUS_TEST_CONDITION_PROMOTION_RUN_ID "
        "to test Condition DQ-006 evidence"
    ),
)
def test_condition_promotion_passes_dq006_evidence() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    promotion_run_id = UUID(
        CONDITION_PROMOTION_RUN_ID
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
        == "synthea-condition"
    )

    assert evidence["mapping_version"] == "1"

    assert (
        evidence["expected_condition_sources"]
        == 3932
    )

    assert (
        evidence[
            "valid_condition_lineage_edges"
        ]
        == 3932
    )

    assert (
        evidence[
            "condition_lineage_sources"
        ]
        == 3932
    )

    assert (
        evidence[
            "condition_lineage_targets"
        ]
        == 3932
    )

    assert (
        evidence[
            "condition_sources_missing_lineage"
        ]
        == 0
    )

    assert (
        evidence[
            "condition_sources_with_multiple_targets"
        ]
        == 0
    )

    assert (
        evidence[
            "condition_targets_with_multiple_sources"
        ]
        == 0
    )

    assert (
        evidence[
            "condition_orphan_targets"
        ]
        == 0
    )

    assert (
        evidence[
            "conditions_without_valid_patient"
        ]
        == 0
    )

    assert (
        evidence[
            "conditions_without_valid_encounter"
        ]
        == 0
    )

    assert (
        evidence[
            "patient_encounter_mismatches"
        ]
        == 0
    )

    assert (
        evidence[
            "conditions_missing_code_system"
        ]
        == 0
    )

    assert (
        evidence[
            "conditions_missing_code"
        ]
        == 0
    )

    assert (
        evidence[
            "conditions_missing_display"
        ]
        == 0
    )

    assert (
        evidence[
            "conditions_missing_onset_date"
        ]
        == 0
    )

    assert (
        evidence[
            "condition_temporal_violations"
        ]
        == 0
    )

    assert (
        evidence[
            "conditions_with_unexpected_clinical_status"
        ]
        == 0
    )

    assert (
        evidence[
            "uncertified_patient_dependencies"
        ]
        == 0
    )

    assert (
        evidence[
            "uncertified_encounter_dependencies"
        ]
        == 0
    )

    assert evidence["violation_count"] == 0
    assert evidence["lineage_complete"] is True

    assert evaluation.outcome == "pass"

@pytest.mark.skipif(
    not MEDICATION_PROMOTION_RUN_ID,
    reason=(
        "Set JANUS_TEST_MEDICATION_PROMOTION_RUN_ID "
        "to test Medication DQ-006 evidence"
    ),
)
def test_medication_promotion_passes_dq006_evidence() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    promotion_run_id = UUID(
        MEDICATION_PROMOTION_RUN_ID
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
        == "synthea-medication"
    )

    assert evidence["mapping_version"] == "1"

    assert (
        evidence[
            "expected_medication_sources"
        ]
        == 5615
    )

    assert (
        evidence[
            "valid_medication_lineage_edges"
        ]
        == 5615
    )

    assert (
        evidence[
            "medication_lineage_sources"
        ]
        == 5615
    )

    assert (
        evidence[
            "medication_lineage_targets"
        ]
        == 5615
    )

    assert (
        evidence[
            "medication_sources_missing_lineage"
        ]
        == 0
    )

    assert (
        evidence[
            "medication_sources_with_multiple_targets"
        ]
        == 0
    )

    assert (
        evidence[
            "medication_targets_with_multiple_sources"
        ]
        == 0
    )

    assert (
        evidence[
            "medication_orphan_targets"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_without_valid_patient"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_without_valid_encounter"
        ]
        == 0
    )

    assert (
        evidence[
            "patient_encounter_mismatches"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_missing_code"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_missing_display"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_missing_start_at"
        ]
        == 0
    )

    assert (
        evidence[
            "medication_temporal_violations"
        ]
        == 0
    )

    assert (
        evidence[
            "temporal_column_contract_mismatch"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_with_unexpected_code_system"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_with_unexpected_status"
        ]
        == 0
    )

    assert (
        evidence[
            "medications_with_unexpected_dose_text"
        ]
        == 0
    )

    assert (
        evidence[
            "uncertified_patient_dependencies"
        ]
        == 0
    )

    assert (
        evidence[
            "uncertified_encounter_dependencies"
        ]
        == 0
    )

    assert (
        evidence[
            "wrong_source_artifact_edges"
        ]
        == 0
    )

    assert (
        evidence[
            "wrong_mapping_version_edges"
        ]
        == 0
    )

    assert (
        evidence[
            "wrong_transformation_edges"
        ]
        == 0
    )

    assert (
        evidence[
            "unexpected_target_edges"
        ]
        == 0
    )

    assert (
        evidence[
            "promotion_counter_mismatch"
        ]
        == 0
    )

    assert (
        evidence[
            "medication_target_count_mismatch"
        ]
        == 0
    )

    assert evidence["violation_count"] == 0
    assert evidence["lineage_complete"] is True

    assert evaluation.outcome == "pass"