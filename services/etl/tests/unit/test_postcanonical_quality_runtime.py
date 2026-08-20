from uuid import uuid4

from janus_etl.postcanonical_quality_runtime import (
    _evaluate_lineage_evidence,
)


def _passing_evidence() -> dict:
    return {
        "canonical_promotion_run_id":
            uuid4(),
        "import_batch_id":
            uuid4(),
        "mapping_name":
            "synthea-patient",
        "mapping_version":
            "1",
        "promotion_records_seen":
            112,
        "promotion_records_created":
            112,
        "promotion_records_existing":
            0,
        "promotion_records_failed":
            0,
        "expected_patient_sources":
            112,
        "valid_patient_lineage_edges":
            112,
        "patient_lineage_sources":
            112,
        "patient_lineage_targets":
            112,
        "patient_sources_missing_lineage":
            0,
        "patient_sources_with_multiple_targets":
            0,
        "patient_orphan_targets":
            0,
        "expected_identifier_targets":
            300,
        "valid_identifier_lineage_edges":
            300,
        "identifier_lineage_targets":
            300,
        "identifier_targets_missing_lineage":
            0,
        "identifier_orphan_targets":
            0,
        "unexpected_identifier_lineage_edges":
            0,
        "wrong_source_artifact_edges":
            0,
        "wrong_mapping_version_edges":
            0,
        "wrong_transformation_edges":
            0,
        "unexpected_target_edges":
            0,
        "promotion_counter_mismatch":
            0,
        "patient_target_count_mismatch":
            0,
        "violation_count":
            0,
        "lineage_complete":
            True,
    }


def test_complete_lineage_passes() -> None:
    evidence = _passing_evidence()

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "pass"
    assert result.records_evaluated == 1
    assert result.records_passed == 1
    assert result.records_failed == 0


def test_missing_patient_lineage_fails() -> None:
    evidence = _passing_evidence()

    evidence[
        "patient_sources_missing_lineage"
    ] = 1

    evidence[
        "valid_patient_lineage_edges"
    ] = 111

    evidence[
        "patient_lineage_sources"
    ] = 111

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"
    assert result.records_passed == 0
    assert result.records_failed == 1


def test_quality_does_not_trust_boolean_alone() -> None:
    evidence = _passing_evidence()

    evidence[
        "wrong_mapping_version_edges"
    ] = 1

    # Deliberately simulate inconsistent aggregate evidence.
    evidence["violation_count"] = 0
    evidence["lineage_complete"] = True

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"