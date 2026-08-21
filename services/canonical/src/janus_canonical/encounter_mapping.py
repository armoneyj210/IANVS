from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID

MAPPING_NAME = "synthea-encounter"
MAPPING_VERSION = "1"

ENCOUNTER_SOURCE_PATH = "csv/encounters.csv"

ENCOUNTER_IDENTIFIER_SYSTEM = (
    "urn:janus:source:synthea:encounter-id"
)


@dataclass(frozen=True)
class SyntheaEncounterMapping:
    synthea_encounter_id: str
    synthea_patient_id: str
    synthea_provider_id: str | None

    start_at: datetime
    end_at: datetime | None

    encounter_type: str
    reason: str | None


def _optional_text(
    value: str | None,
) -> str | None:
    if value is None:
        return None

    normalized = value.strip()

    return normalized or None


def _required_text(
    value: str | None,
    *,
    field_name: str,
) -> str:
    normalized = _optional_text(value)

    if normalized is None:
        raise ValueError(
            f"{field_name} is required"
        )

    return normalized


def _required_uuid_text(
    value: str | None,
    *,
    field_name: str,
) -> str:
    normalized = _required_text(
        value,
        field_name=field_name,
    )

    try:
        parsed = UUID(normalized)
    except ValueError as error:
        raise ValueError(
            f"{field_name} must be a valid UUID"
        ) from error

    return str(parsed)


def _optional_uuid_text(
    value: str | None,
    *,
    field_name: str,
) -> str | None:
    normalized = _optional_text(value)

    if normalized is None:
        return None

    try:
        parsed = UUID(normalized)
    except ValueError as error:
        raise ValueError(
            f"{field_name} must be a valid UUID"
        ) from error

    return str(parsed)


def _parse_datetime(
    value: str,
    *,
    field_name: str,
) -> datetime:
    normalized = value.strip()

    if normalized.endswith(
        ("Z", "z")
    ):
        normalized = (
            normalized[:-1]
            + "+00:00"
        )

    try:
        parsed = datetime.fromisoformat(
            normalized
        )
    except ValueError as error:
        raise ValueError(
            f"{field_name} must be a valid "
            "ISO-8601 timestamp"
        ) from error

    if (
        parsed.tzinfo is None
        or parsed.utcoffset() is None
    ):
        raise ValueError(
            f"{field_name} must include "
            "a timezone offset"
        )

    return parsed.astimezone(UTC)


def _required_datetime(
    value: str | None,
    *,
    field_name: str,
) -> datetime:
    normalized = _required_text(
        value,
        field_name=field_name,
    )

    return _parse_datetime(
        normalized,
        field_name=field_name,
    )


def _optional_datetime(
    value: str | None,
    *,
    field_name: str,
) -> datetime | None:
    normalized = _optional_text(value)

    if normalized is None:
        return None

    return _parse_datetime(
        normalized,
        field_name=field_name,
    )


def map_synthea_encounter(
    row: dict[str, str | None],
) -> SyntheaEncounterMapping:
    synthea_encounter_id = (
        _required_uuid_text(
            row.get("Id"),
            field_name="encounters.csv.Id",
        )
    )

    synthea_patient_id = (
        _required_uuid_text(
            row.get("PATIENT"),
            field_name=(
                "encounters.csv.PATIENT"
            ),
        )
    )

    synthea_provider_id = (
        _optional_uuid_text(
            row.get("PROVIDER"),
            field_name=(
                "encounters.csv.PROVIDER"
            ),
        )
    )

    start_at = _required_datetime(
        row.get("START"),
        field_name="encounters.csv.START",
    )

    end_at = _optional_datetime(
        row.get("STOP"),
        field_name="encounters.csv.STOP",
    )

    if (
        end_at is not None
        and end_at < start_at
    ):
        raise ValueError(
            "encounters.csv.STOP may not "
            "precede encounters.csv.START"
        )

    encounter_type = _required_text(
        row.get("ENCOUNTERCLASS"),
        field_name=(
            "encounters.csv.ENCOUNTERCLASS"
        ),
    )

    reason = _optional_text(
        row.get("REASONDESCRIPTION")
    )

    return SyntheaEncounterMapping(
        synthea_encounter_id=(
            synthea_encounter_id
        ),
        synthea_patient_id=(
            synthea_patient_id
        ),
        synthea_provider_id=(
            synthea_provider_id
        ),
        start_at=start_at,
        end_at=end_at,
        encounter_type=encounter_type,
        reason=reason,
    )