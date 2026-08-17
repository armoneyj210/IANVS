from datetime import UTC
from decimal import Decimal
from uuid import uuid4

import pytest

from janus_etl import quality_runtime as qr


def _source_record(row_number: int) -> dict:
    return {
        "source_record_id": uuid4(),
        "row_number": row_number,
        "record_locator": f"row={row_number}",
        "record_status": "accepted",
    }


def test_score_returns_none_when_nothing_evaluated() -> None:
    assert qr._score(0, 0) is None


def test_score_is_deterministic_and_quantized() -> None:
    assert qr._score(2, 1) == Decimal("0.666667")


def test_identifier_fingerprint_is_normalized() -> None:
    first = qr._identifier_fingerprint(" Example-ID ")
    second = qr._identifier_fingerprint("example-id")

    assert first == second
    assert len(first) == 16
    assert "example-id" not in first


def test_parse_temporal_date_uses_utc() -> None:
    parsed = qr._parse_temporal("2026-08-16")

    assert parsed.year == 2026
    assert parsed.month == 8
    assert parsed.day == 16
    assert parsed.tzinfo == UTC


def test_parse_temporal_supports_z_timestamp() -> None:
    parsed = qr._parse_temporal(
        "2026-08-16T12:30:00Z"
    )

    assert parsed.tzinfo == UTC
    assert parsed.hour == 12
    assert parsed.minute == 30


def test_parse_temporal_rejects_blank_value() -> None:
    with pytest.raises(
        ValueError,
        match="blank temporal value",
    ):
        qr._parse_temporal("   ")


def test_dq003_detects_duplicate_patient_identifier(
    monkeypatch,
    tmp_path,
) -> None:
    csv_root = tmp_path / "csv"
    csv_root.mkdir()

    patients_path = csv_root / "patients.csv"

    patients_path.write_text(
        (
            "Id,SSN,DRIVERS,PASSPORT\n"
            "patient-1,123-45-6789,,\n"
            "patient-2,123-45-6789,,\n"
            "patient-3,987-65-4321,,\n"
        ),
        encoding="utf-8",
    )

    source_file_id = uuid4()

    record_map = {
        1: _source_record(1),
        2: _source_record(2),
        3: _source_record(3),
    }

    monkeypatch.setattr(
        qr,
        "_load_file_record_map",
        lambda *args, **kwargs: record_map,
    )

    result = qr._evaluate_dq003(
        object(),
        import_batch_id=uuid4(),
        raw_directory=tmp_path,
        source_files={
            "csv/patients.csv": {
                "source_file_id": source_file_id,
            }
        },
        severity="error",
    )

    assert result.rule_code == "JANUS-DQ-003"
    assert result.outcome == "fail"

    assert result.records_evaluated == 3
    assert result.records_passed == 1
    assert result.records_failed == 2

    assert result.details["duplicate_groups"] == 1
    assert (
        result.details["raw_identifier_values_logged"]
        is False
    )

    assert len(result.issues) == 2

    expected_fingerprint = qr._identifier_fingerprint(
        "123-45-6789"
    )

    for issue in result.issues:
        assert issue.quarantine is True
        assert issue.reason_code == (
            "DQ003_IDENTIFIER_DUPLICATE"
        )

        assert (
            issue.details["identifier_fingerprint"]
            == expected_fingerprint
        )

        # Raw patient identifier must never be copied
        # into DQ evidence.
        assert "123-45-6789" not in issue.message
        assert (
            "123-45-6789"
            not in str(issue.details)
        )


def test_dq003_passes_unique_patient_identifiers(
    monkeypatch,
    tmp_path,
) -> None:
    csv_root = tmp_path / "csv"
    csv_root.mkdir()

    (csv_root / "patients.csv").write_text(
        (
            "Id,SSN,DRIVERS,PASSPORT\n"
            "patient-1,111-11-1111,D1,P1\n"
            "patient-2,222-22-2222,D2,P2\n"
        ),
        encoding="utf-8",
    )

    record_map = {
        1: _source_record(1),
        2: _source_record(2),
    }

    monkeypatch.setattr(
        qr,
        "_load_file_record_map",
        lambda *args, **kwargs: record_map,
    )

    result = qr._evaluate_dq003(
        object(),
        import_batch_id=uuid4(),
        raw_directory=tmp_path,
        source_files={
            "csv/patients.csv": {
                "source_file_id": uuid4(),
            }
        },
        severity="error",
    )

    assert result.outcome == "pass"
    assert result.records_evaluated == 2
    assert result.records_passed == 2
    assert result.records_failed == 0
    assert result.issues == ()


def test_dq004_detects_end_before_start(
    monkeypatch,
    tmp_path,
) -> None:
    csv_root = tmp_path / "csv"
    csv_root.mkdir()

    (csv_root / "conditions.csv").write_text(
        "START,STOP\n"
        "2026-01-01,2026-02-01\n",
        encoding="utf-8",
    )

    (csv_root / "encounters.csv").write_text(
        "START,STOP\n"
        "2026-03-02,2026-03-01\n",
        encoding="utf-8",
    )

    (csv_root / "medications.csv").write_text(
        "START,STOP\n"
        "2026-04-01,\n",
        encoding="utf-8",
    )

    (csv_root / "patients.csv").write_text(
        "BIRTHDATE,DEATHDATE\n"
        "1980-01-01,\n",
        encoding="utf-8",
    )

    monkeypatch.setattr(
        qr,
        "_load_file_record_map",
        lambda *args, **kwargs: {
            1: _source_record(1),
        },
    )

    source_files = {
        "csv/conditions.csv": {
            "source_file_id": uuid4(),
        },
        "csv/encounters.csv": {
            "source_file_id": uuid4(),
        },
        "csv/medications.csv": {
            "source_file_id": uuid4(),
        },
        "csv/patients.csv": {
            "source_file_id": uuid4(),
        },
    }

    result = qr._evaluate_dq004(
        object(),
        import_batch_id=uuid4(),
        raw_directory=tmp_path,
        source_files=source_files,
        severity="error",
    )

    assert result.rule_code == "JANUS-DQ-004"
    assert result.outcome == "fail"

    assert result.records_evaluated == 4
    assert result.records_passed == 3
    assert result.records_failed == 1

    assert len(result.issues) == 1

    issue = result.issues[0]

    assert issue.quarantine is True
    assert issue.reason_code == (
        "DQ004_TEMPORAL_CONSISTENCY"
    )

    assert (
        issue.details["failure_type"]
        == "end_before_start"
    )

    assert (
        issue.details["raw_temporal_values_logged"]
        is False
    )

    # Raw dates should not be copied into validation evidence.
    assert "2026-03-02" not in issue.message
    assert "2026-03-01" not in str(issue.details)


def test_dq005_warns_without_inventing_coding_system(
    tmp_path,
) -> None:
    csv_root = tmp_path / "csv"
    csv_root.mkdir()

    (csv_root / "conditions.csv").write_text(
        "CODE,SYSTEM\n"
        "12345,http://snomed.info/sct\n",
        encoding="utf-8",
    )

    (csv_root / "encounters.csv").write_text(
        "CODE\n"
        "67890\n",
        encoding="utf-8",
    )

    (csv_root / "medications.csv").write_text(
        "CODE\n"
        "11111\n",
        encoding="utf-8",
    )

    (csv_root / "observations.csv").write_text(
        'CODE\n'
        '""\n',
        encoding="utf-8",
    )

    source_files = {
        "csv/conditions.csv": {
            "source_file_id": uuid4(),
        },
        "csv/encounters.csv": {
            "source_file_id": uuid4(),
        },
        "csv/medications.csv": {
            "source_file_id": uuid4(),
        },
        "csv/observations.csv": {
            "source_file_id": uuid4(),
        },
    }

    result = qr._evaluate_dq005(
        raw_directory=tmp_path,
        source_files=source_files,
        severity="warning",
    )

    assert result.rule_code == "JANUS-DQ-005"
    assert result.outcome == "warning"

    assert result.records_evaluated == 4
    assert result.records_passed == 1
    assert result.records_failed == 2
    assert result.records_skipped == 1

    assert result.score == Decimal("0.333333")

    assert (
        result.details[
            "coding_system_inference_performed"
        ]
        is False
    )

    assert (
        result.details["warning_is_blocking"]
        is False
    )

    # One aggregate warning for each coded file that
    # lacks terminology-system identification.
    assert len(result.issues) == 2

    assert all(
        issue.quarantine is False
        for issue in result.issues
    )


def test_dq006_is_explicitly_deferred() -> None:
    assert "JANUS-DQ-006" in qr.DEFERRED_RULES

    reason = qr.DEFERRED_RULES["JANUS-DQ-006"]

    assert "canonical" in reason.lower()
    assert "record_lineage" in reason