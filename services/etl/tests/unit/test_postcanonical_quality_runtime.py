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

def _passing_provider_evidence() -> dict:
    return {
        "canonical_promotion_run_id":
            uuid4(),
        "import_batch_id":
            uuid4(),
        "mapping_name":
            "synthea-provider",
        "mapping_version":
            "1",

        "promotion_records_seen":
            264,
        "promotion_records_created":
            264,
        "promotion_records_existing":
            0,
        "promotion_records_failed":
            0,

        "expected_provider_sources":
            264,

        "valid_provider_lineage_edges":
            264,
        "provider_lineage_sources":
            264,
        "provider_lineage_targets":
            264,

        "provider_sources_missing_lineage":
            0,
        "provider_sources_with_multiple_targets":
            0,
        "provider_orphan_targets":
            0,

        "providers_with_organization_name":
            200,

        "valid_organization_lineage_edges":
            200,
        "organization_lineage_targets":
            200,

        (
            "provider_targets_missing_"
            "organization_lineage"
        ):
            0,

        (
            "provider_targets_with_unexpected_"
            "organization_lineage"
        ):
            0,

        (
            "provider_targets_with_multiple_"
            "organization_edges"
        ):
            0,

        "organization_orphan_targets":
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
        "provider_target_count_mismatch":
            0,

        "violation_count":
            0,
        "lineage_complete":
            True,
    }


def test_complete_provider_lineage_passes() -> None:
    evidence = _passing_provider_evidence()

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "pass"
    assert result.records_evaluated == 1
    assert result.records_passed == 1
    assert result.records_failed == 0


def test_missing_provider_lineage_fails() -> None:
    evidence = _passing_provider_evidence()

    evidence[
        "provider_sources_missing_lineage"
    ] = 1

    evidence[
        "valid_provider_lineage_edges"
    ] = 263

    evidence[
        "provider_lineage_sources"
    ] = 263

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"
    assert result.records_passed == 0
    assert result.records_failed == 1


def test_missing_provider_organization_lineage_fails() -> None:
    evidence = _passing_provider_evidence()

    evidence[
        "provider_targets_missing_"
        "organization_lineage"
    ] = 1

    evidence[
        "valid_organization_lineage_edges"
    ] = 199

    evidence[
        "organization_lineage_targets"
    ] = 199

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"
    assert result.records_failed == 1


def test_provider_quality_does_not_trust_boolean_alone() -> None:
    evidence = _passing_provider_evidence()

    evidence[
        "wrong_source_artifact_edges"
    ] = 1

    # Simulate inconsistent aggregate output.
    evidence["violation_count"] = 0
    evidence["lineage_complete"] = True

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"

def _passing_encounter_evidence() -> dict:
    return {
        "canonical_promotion_run_id":
            uuid4(),
        "import_batch_id":
            uuid4(),
        "mapping_name":
            "synthea-encounter",
        "mapping_version":
            "1",

        "promotion_records_seen":
            6950,
        "promotion_records_created":
            6950,
        "promotion_records_existing":
            0,
        "promotion_records_failed":
            0,

        "expected_encounter_sources":
            6950,

        "valid_encounter_lineage_edges":
            6950,
        "encounter_lineage_sources":
            6950,
        "encounter_lineage_targets":
            6950,

        "valid_identifier_lineage_edges":
            6950,
        "identifier_lineage_sources":
            6950,
        "identifier_lineage_targets":
            6950,

        "encounter_sources_missing_lineage":
            0,
        "encounter_sources_with_multiple_targets":
            0,
        "encounter_targets_with_multiple_sources":
            0,

        "identifier_sources_missing_lineage":
            0,
        "identifier_sources_with_multiple_targets":
            0,
        "identifier_targets_with_multiple_sources":
            0,

        "encounter_orphan_targets":
            0,
        "identifier_orphan_targets":
            0,

        "invalid_identifier_contract":
            0,
        "encounter_identifier_pair_mismatches":
            0,

        "encounters_with_provider":
            6950,

        "uncertified_patient_dependencies":
            0,
        "uncertified_provider_dependencies":
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
        "encounter_target_count_mismatch":
            0,
        "identifier_target_count_mismatch":
            0,

        "violation_count":
            0,
        "lineage_complete":
            True,
    }


def test_complete_encounter_lineage_passes() -> None:
    evidence = _passing_encounter_evidence()

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "pass"
    assert result.records_evaluated == 1
    assert result.records_passed == 1
    assert result.records_failed == 0


def test_missing_encounter_lineage_fails() -> None:
    evidence = _passing_encounter_evidence()

    evidence[
        "encounter_sources_missing_lineage"
    ] = 1

    evidence[
        "valid_encounter_lineage_edges"
    ] = 6949

    evidence[
        "encounter_lineage_sources"
    ] = 6949

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"
    assert result.records_failed == 1


def test_missing_encounter_identifier_lineage_fails() -> None:
    evidence = _passing_encounter_evidence()

    evidence[
        "identifier_sources_missing_lineage"
    ] = 1

    evidence[
        "valid_identifier_lineage_edges"
    ] = 6949

    evidence[
        "identifier_lineage_sources"
    ] = 6949

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"
    assert result.records_failed == 1


def test_encounter_identifier_pair_mismatch_fails() -> None:
    evidence = _passing_encounter_evidence()

    evidence[
        "encounter_identifier_pair_mismatches"
    ] = 1

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"


def test_uncertified_patient_dependency_fails() -> None:
    evidence = _passing_encounter_evidence()

    evidence[
        "uncertified_patient_dependencies"
    ] = 1

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"


def test_uncertified_provider_dependency_fails() -> None:
    evidence = _passing_encounter_evidence()

    evidence[
        "uncertified_provider_dependencies"
    ] = 1

    evidence["violation_count"] = 1
    evidence["lineage_complete"] = False

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"


def test_encounter_quality_does_not_trust_boolean_alone() -> None:
    evidence = _passing_encounter_evidence()

    evidence[
        "wrong_transformation_edges"
    ] = 1

    # Deliberately simulate inconsistent aggregate evidence.
    evidence["violation_count"] = 0
    evidence["lineage_complete"] = True

    result = _evaluate_lineage_evidence(
        evidence
    )

    assert result.outcome == "fail"