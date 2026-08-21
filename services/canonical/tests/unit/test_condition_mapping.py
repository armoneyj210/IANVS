from datetime import date

import pytest

from janus_canonical.condition_mapping import (
    CONDITION_SOURCE_PATH,
    MAPPING_NAME,
    MAPPING_VERSION,
    map_synthea_condition,
)

PATIENT_ID = (
    "22222222-2222-2222-2222-222222222222"
)

ENCOUNTER_ID = (
    "11111111-1111-1111-1111-111111111111"
)


def _valid_row() -> dict[str, str]:
    return {
        "START": "2026-01-15",
        "STOP": "2026-02-20",
        "PATIENT": PATIENT_ID,
        "ENCOUNTER": ENCOUNTER_ID,
        "SYSTEM": "http://snomed.info/sct",
        "CODE": "123456",
        "DESCRIPTION": "Test condition",
    }


def test_condition_mapping_contract_constants() -> None:
    assert MAPPING_NAME == "synthea-condition"
    assert MAPPING_VERSION == "1"

    assert (
        CONDITION_SOURCE_PATH
        == "csv/conditions.csv"
    )


def test_condition_mapping_normalizes_fields() -> None:
    row = _valid_row()

    row["PATIENT"] = (
        f"  {PATIENT_ID.upper()}  "
    )

    row["ENCOUNTER"] = (
        f"  {ENCOUNTER_ID.upper()}  "
    )

    row["SYSTEM"] = (
        "  http://snomed.info/sct  "
    )

    row["CODE"] = "  123456  "

    row["DESCRIPTION"] = (
        "  Test condition  "
    )

    mapped = map_synthea_condition(row)

    assert (
        mapped.synthea_patient_id
        == PATIENT_ID
    )

    assert (
        mapped.synthea_encounter_id
        == ENCOUNTER_ID
    )

    assert mapped.onset_date == date(
        2026,
        1,
        15,
    )

    assert mapped.resolved_date == date(
        2026,
        2,
        20,
    )

    assert (
        mapped.code_system
        == "http://snomed.info/sct"
    )

    assert mapped.code == "123456"

    assert (
        mapped.display
        == "Test condition"
    )


def test_condition_mapping_allows_blank_stop() -> None:
    row = _valid_row()

    row["STOP"] = ""

    mapped = map_synthea_condition(row)

    assert mapped.resolved_date is None


def test_condition_mapping_requires_patient() -> None:
    row = _valid_row()

    row["PATIENT"] = ""

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.PATIENT is required"
        ),
    ):
        map_synthea_condition(row)


def test_condition_mapping_rejects_invalid_patient_uuid() -> None:
    row = _valid_row()

    row["PATIENT"] = "not-a-uuid"

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.PATIENT must be "
            "a valid UUID"
        ),
    ):
        map_synthea_condition(row)


def test_condition_mapping_requires_encounter() -> None:
    row = _valid_row()

    row["ENCOUNTER"] = ""

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.ENCOUNTER is required"
        ),
    ):
        map_synthea_condition(row)


def test_condition_mapping_rejects_invalid_encounter_uuid() -> None:
    row = _valid_row()

    row["ENCOUNTER"] = "not-a-uuid"

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.ENCOUNTER must be "
            "a valid UUID"
        ),
    ):
        map_synthea_condition(row)


def test_condition_mapping_requires_start() -> None:
    row = _valid_row()

    row["START"] = ""

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.START is required"
        ),
    ):
        map_synthea_condition(row)


def test_condition_mapping_rejects_invalid_start() -> None:
    row = _valid_row()

    row["START"] = "not-a-date"

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.START must be "
            "a valid ISO-8601 date"
        ),
    ):
        map_synthea_condition(row)


def test_condition_mapping_rejects_invalid_stop() -> None:
    row = _valid_row()

    row["STOP"] = "not-a-date"

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.STOP must be "
            "a valid ISO-8601 date"
        ),
    ):
        map_synthea_condition(row)


def test_condition_mapping_rejects_stop_before_start() -> None:
    row = _valid_row()

    row["START"] = "2026-02-20"
    row["STOP"] = "2026-01-15"

    with pytest.raises(
        ValueError,
        match=(
            "conditions.csv.STOP may not precede "
            "conditions.csv.START"
        ),
    ):
        map_synthea_condition(row)


@pytest.mark.parametrize(
    ("field", "message"),
    [
        (
            "SYSTEM",
            "conditions.csv.SYSTEM is required",
        ),
        (
            "CODE",
            "conditions.csv.CODE is required",
        ),
        (
            "DESCRIPTION",
            (
                "conditions.csv.DESCRIPTION "
                "is required"
            ),
        ),
    ],
)
def test_condition_mapping_requires_coding_fields(
    field: str,
    message: str,
) -> None:
    row = _valid_row()

    row[field] = "   "

    with pytest.raises(
        ValueError,
        match=message,
    ):
        map_synthea_condition(row)