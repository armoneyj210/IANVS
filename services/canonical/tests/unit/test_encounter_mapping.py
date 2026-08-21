from datetime import UTC, datetime

import pytest

from janus_canonical.encounter_mapping import (
    ENCOUNTER_IDENTIFIER_SYSTEM,
    ENCOUNTER_SOURCE_PATH,
    MAPPING_NAME,
    MAPPING_VERSION,
    map_synthea_encounter,
)

ENCOUNTER_ID = (
    "11111111-1111-1111-1111-111111111111"
)

PATIENT_ID = (
    "22222222-2222-2222-2222-222222222222"
)

PROVIDER_ID = (
    "33333333-3333-3333-3333-333333333333"
)


def test_encounter_mapping_contract_constants() -> None:
    assert MAPPING_NAME == "synthea-encounter"
    assert MAPPING_VERSION == "1"

    assert (
        ENCOUNTER_SOURCE_PATH
        == "csv/encounters.csv"
    )

    assert ENCOUNTER_IDENTIFIER_SYSTEM == (
        "urn:janus:source:synthea:encounter-id"
    )


def test_encounter_mapping_normalizes_fields() -> None:
    row = {
        "Id": f"  {ENCOUNTER_ID.upper()}  ",
        "PATIENT": (
            f"  {PATIENT_ID.upper()}  "
        ),
        "PROVIDER": (
            f"  {PROVIDER_ID.upper()}  "
        ),
        "START": (
            "2026-01-15T10:00:00-05:00"
        ),
        "STOP": (
            "2026-01-15T11:30:00-05:00"
        ),
        "ENCOUNTERCLASS": "  ambulatory  ",
        "REASONDESCRIPTION": (
            "  Routine examination  "
        ),
        "ORGANIZATION": "ignored",
        "PAYER": "ignored",
        "CODE": "ignored",
        "DESCRIPTION": "ignored",
        "BASE_ENCOUNTER_COST": "100",
        "TOTAL_CLAIM_COST": "200",
        "PAYER_COVERAGE": "150",
        "REASONCODE": "123",
    }

    mapped = map_synthea_encounter(row)

    assert (
        mapped.synthea_encounter_id
        == ENCOUNTER_ID
    )

    assert (
        mapped.synthea_patient_id
        == PATIENT_ID
    )

    assert (
        mapped.synthea_provider_id
        == PROVIDER_ID
    )

    assert mapped.start_at == datetime(
        2026,
        1,
        15,
        15,
        0,
        tzinfo=UTC,
    )

    assert mapped.end_at == datetime(
        2026,
        1,
        15,
        16,
        30,
        tzinfo=UTC,
    )

    assert (
        mapped.encounter_type
        == "ambulatory"
    )

    assert (
        mapped.reason
        == "Routine examination"
    )


def test_encounter_mapping_accepts_z_timestamp() -> None:
    mapped = map_synthea_encounter(
        {
            "Id": ENCOUNTER_ID,
            "PATIENT": PATIENT_ID,
            "PROVIDER": PROVIDER_ID,
            "START": (
                "2026-01-15T10:00:00Z"
            ),
            "STOP": (
                "2026-01-15T11:00:00Z"
            ),
            "ENCOUNTERCLASS":
                "ambulatory",
            "REASONDESCRIPTION": "",
        }
    )

    assert mapped.start_at == datetime(
        2026,
        1,
        15,
        10,
        0,
        tzinfo=UTC,
    )

    assert mapped.end_at == datetime(
        2026,
        1,
        15,
        11,
        0,
        tzinfo=UTC,
    )


def test_encounter_mapping_allows_blank_provider() -> None:
    mapped = map_synthea_encounter(
        {
            "Id": ENCOUNTER_ID,
            "PATIENT": PATIENT_ID,
            "PROVIDER": "",
            "START": (
                "2026-01-15T10:00:00Z"
            ),
            "STOP": (
                "2026-01-15T11:00:00Z"
            ),
            "ENCOUNTERCLASS":
                "ambulatory",
            "REASONDESCRIPTION": "",
        }
    )

    assert (
        mapped.synthea_provider_id
        is None
    )


def test_encounter_mapping_allows_blank_stop() -> None:
    mapped = map_synthea_encounter(
        {
            "Id": ENCOUNTER_ID,
            "PATIENT": PATIENT_ID,
            "PROVIDER": PROVIDER_ID,
            "START": (
                "2026-01-15T10:00:00Z"
            ),
            "STOP": "",
            "ENCOUNTERCLASS":
                "ambulatory",
            "REASONDESCRIPTION": "",
        }
    )

    assert mapped.end_at is None


def test_encounter_mapping_normalizes_blank_reason() -> None:
    mapped = map_synthea_encounter(
        {
            "Id": ENCOUNTER_ID,
            "PATIENT": PATIENT_ID,
            "PROVIDER": PROVIDER_ID,
            "START": (
                "2026-01-15T10:00:00Z"
            ),
            "STOP": (
                "2026-01-15T11:00:00Z"
            ),
            "ENCOUNTERCLASS":
                "ambulatory",
            "REASONDESCRIPTION": "   ",
        }
    )

    assert mapped.reason is None


def test_encounter_mapping_requires_encounter_id() -> None:
    with pytest.raises(
        ValueError,
        match="encounters.csv.Id is required",
    ):
        map_synthea_encounter(
            {
                "Id": "",
                "PATIENT": PATIENT_ID,
                "PROVIDER": PROVIDER_ID,
                "START": (
                    "2026-01-15T10:00:00Z"
                ),
                "STOP": (
                    "2026-01-15T11:00:00Z"
                ),
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_requires_patient() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.PATIENT is required"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": "",
                "PROVIDER": PROVIDER_ID,
                "START": (
                    "2026-01-15T10:00:00Z"
                ),
                "STOP": (
                    "2026-01-15T11:00:00Z"
                ),
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_rejects_invalid_patient_uuid() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.PATIENT must be "
            "a valid UUID"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": "not-a-uuid",
                "PROVIDER": PROVIDER_ID,
                "START": (
                    "2026-01-15T10:00:00Z"
                ),
                "STOP": (
                    "2026-01-15T11:00:00Z"
                ),
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_rejects_invalid_provider_uuid() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.PROVIDER must be "
            "a valid UUID"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": PATIENT_ID,
                "PROVIDER": "not-a-uuid",
                "START": (
                    "2026-01-15T10:00:00Z"
                ),
                "STOP": (
                    "2026-01-15T11:00:00Z"
                ),
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_requires_start() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.START is required"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": PATIENT_ID,
                "PROVIDER": PROVIDER_ID,
                "START": "",
                "STOP": (
                    "2026-01-15T11:00:00Z"
                ),
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_rejects_invalid_start() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.START must be "
            "a valid ISO-8601 timestamp"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": PATIENT_ID,
                "PROVIDER": PROVIDER_ID,
                "START": "not-a-date",
                "STOP": "",
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_requires_timezone() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.START must include "
            "a timezone offset"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": PATIENT_ID,
                "PROVIDER": PROVIDER_ID,
                "START": (
                    "2026-01-15T10:00:00"
                ),
                "STOP": "",
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_rejects_end_before_start() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.STOP may not precede "
            "encounters.csv.START"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": PATIENT_ID,
                "PROVIDER": PROVIDER_ID,
                "START": (
                    "2026-01-15T11:00:00Z"
                ),
                "STOP": (
                    "2026-01-15T10:00:00Z"
                ),
                "ENCOUNTERCLASS":
                    "ambulatory",
            }
        )


def test_encounter_mapping_requires_encounter_class() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "encounters.csv.ENCOUNTERCLASS "
            "is required"
        ),
    ):
        map_synthea_encounter(
            {
                "Id": ENCOUNTER_ID,
                "PATIENT": PATIENT_ID,
                "PROVIDER": PROVIDER_ID,
                "START": (
                    "2026-01-15T10:00:00Z"
                ),
                "STOP": (
                    "2026-01-15T11:00:00Z"
                ),
                "ENCOUNTERCLASS": "",
            }
        )