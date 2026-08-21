from datetime import UTC, datetime

import pytest

from janus_canonical.medication_mapping import (
    MAPPING_NAME,
    MAPPING_VERSION,
    MEDICATION_SOURCE_PATH,
    map_synthea_medication,
)

PATIENT_ID = (
    "22222222-2222-2222-2222-222222222222"
)

ENCOUNTER_ID = (
    "11111111-1111-1111-1111-111111111111"
)


def _valid_row() -> dict[str, str]:
    return {
        "START": "2026-01-15T12:30:45Z",
        "STOP": "2026-02-20T18:45:10Z",
        "PATIENT": PATIENT_ID,
        "PAYER": "payer-id",
        "ENCOUNTER": ENCOUNTER_ID,
        "CODE": "123456",
        "DESCRIPTION": "Test medication",
        "BASE_COST": "10.00",
        "PAYER_COVERAGE": "5.00",
        "DISPENSES": "1",
        "TOTALCOST": "10.00",
        "REASONCODE": "999999",
        "REASONDESCRIPTION": "Test reason",
    }


def test_medication_mapping_contract_constants() -> None:
    assert MAPPING_NAME == "synthea-medication"
    assert MAPPING_VERSION == "1"

    assert (
        MEDICATION_SOURCE_PATH
        == "csv/medications.csv"
    )


def test_medication_mapping_normalizes_fields() -> None:
    row = _valid_row()

    row["PATIENT"] = (
        f"  {PATIENT_ID.upper()}  "
    )

    row["ENCOUNTER"] = (
        f"  {ENCOUNTER_ID.upper()}  "
    )

    row["CODE"] = "  123456  "

    row["DESCRIPTION"] = (
        "  Test medication  "
    )

    mapped = map_synthea_medication(row)

    assert (
        mapped.synthea_patient_id
        == PATIENT_ID
    )

    assert (
        mapped.synthea_encounter_id
        == ENCOUNTER_ID
    )

    assert mapped.start_at == datetime(
        2026,
        1,
        15,
        12,
        30,
        45,
        tzinfo=UTC,
    )

    assert mapped.end_at == datetime(
        2026,
        2,
        20,
        18,
        45,
        10,
        tzinfo=UTC,
    )

    assert mapped.code == "123456"

    assert (
        mapped.display
        == "Test medication"
    )


def test_medication_mapping_normalizes_offset_to_utc() -> None:
    row = _valid_row()

    row["START"] = (
        "2026-01-15T07:30:45-05:00"
    )

    mapped = map_synthea_medication(row)

    assert mapped.start_at == datetime(
        2026,
        1,
        15,
        12,
        30,
        45,
        tzinfo=UTC,
    )


def test_medication_mapping_allows_blank_stop() -> None:
    row = _valid_row()

    row["STOP"] = ""

    mapped = map_synthea_medication(row)

    assert mapped.end_at is None


def test_medication_mapping_requires_patient() -> None:
    row = _valid_row()

    row["PATIENT"] = ""

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.PATIENT is required"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_rejects_invalid_patient_uuid() -> None:
    row = _valid_row()

    row["PATIENT"] = "not-a-uuid"

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.PATIENT must be "
            "a valid UUID"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_requires_encounter() -> None:
    row = _valid_row()

    row["ENCOUNTER"] = ""

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.ENCOUNTER is required"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_rejects_invalid_encounter_uuid() -> None:
    row = _valid_row()

    row["ENCOUNTER"] = "not-a-uuid"

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.ENCOUNTER must be "
            "a valid UUID"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_requires_start() -> None:
    row = _valid_row()

    row["START"] = ""

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.START is required"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_rejects_invalid_start() -> None:
    row = _valid_row()

    row["START"] = "not-a-datetime"

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.START must be "
            "a valid ISO-8601 datetime"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_requires_start_timezone() -> None:
    row = _valid_row()

    row["START"] = "2026-01-15T12:30:45"

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.START must include "
            "timezone information"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_rejects_invalid_stop() -> None:
    row = _valid_row()

    row["STOP"] = "not-a-datetime"

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.STOP must be "
            "a valid ISO-8601 datetime"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_requires_stop_timezone() -> None:
    row = _valid_row()

    row["STOP"] = "2026-02-20T18:45:10"

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.STOP must include "
            "timezone information"
        ),
    ):
        map_synthea_medication(row)


def test_medication_mapping_rejects_stop_before_start() -> None:
    row = _valid_row()

    row["START"] = "2026-02-20T18:45:10Z"
    row["STOP"] = "2026-01-15T12:30:45Z"

    with pytest.raises(
        ValueError,
        match=(
            "medications.csv.STOP may not precede "
            "medications.csv.START"
        ),
    ):
        map_synthea_medication(row)


@pytest.mark.parametrize(
    ("field", "message"),
    [
        (
            "CODE",
            "medications.csv.CODE is required",
        ),
        (
            "DESCRIPTION",
            (
                "medications.csv.DESCRIPTION "
                "is required"
            ),
        ),
    ],
)
def test_medication_mapping_requires_clinical_fields(
    field: str,
    message: str,
) -> None:
    row = _valid_row()

    row[field] = "   "

    with pytest.raises(
        ValueError,
        match=message,
    ):
        map_synthea_medication(row)


def test_medication_mapping_does_not_promote_unmapped_fields() -> None:
    mapped = map_synthea_medication(
        _valid_row()
    )

    assert not hasattr(
        mapped,
        "payer",
    )

    assert not hasattr(
        mapped,
        "reason_code",
    )

    assert not hasattr(
        mapped,
        "reason_description",
    )

    assert not hasattr(
        mapped,
        "dose_text",
    )
    