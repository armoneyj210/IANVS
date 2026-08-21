from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import UUID

MAPPING_NAME = "synthea-medication"
MAPPING_VERSION = "1"

MEDICATION_SOURCE_PATH = "csv/medications.csv"


@dataclass(frozen=True)
class SyntheaMedicationMapping:
    synthea_patient_id: str
    synthea_encounter_id: str

    start_at: datetime
    end_at: datetime | None

    code: str
    display: str


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


def _parse_datetime(
    value: str,
    *,
    field_name: str,
) -> datetime:
    normalized = value.strip()

    if normalized.endswith("Z"):
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
            "ISO-8601 datetime"
        ) from error

    if (
        parsed.tzinfo is None
        or parsed.utcoffset() is None
    ):
        raise ValueError(
            f"{field_name} must include "
            "timezone information"
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


def map_synthea_medication(
    row: dict[str, str | None],
) -> SyntheaMedicationMapping:
    synthea_patient_id = (
        _required_uuid_text(
            row.get("PATIENT"),
            field_name=(
                "medications.csv.PATIENT"
            ),
        )
    )

    synthea_encounter_id = (
        _required_uuid_text(
            row.get("ENCOUNTER"),
            field_name=(
                "medications.csv.ENCOUNTER"
            ),
        )
    )

    start_at = _required_datetime(
        row.get("START"),
        field_name="medications.csv.START",
    )

    end_at = _optional_datetime(
        row.get("STOP"),
        field_name="medications.csv.STOP",
    )

    if (
        end_at is not None
        and end_at < start_at
    ):
        raise ValueError(
            "medications.csv.STOP may not precede "
            "medications.csv.START"
        )

    code = _required_text(
        row.get("CODE"),
        field_name="medications.csv.CODE",
    )

    display = _required_text(
        row.get("DESCRIPTION"),
        field_name=(
            "medications.csv.DESCRIPTION"
        ),
    )

    return SyntheaMedicationMapping(
        synthea_patient_id=(
            synthea_patient_id
        ),
        synthea_encounter_id=(
            synthea_encounter_id
        ),
        start_at=start_at,
        end_at=end_at,
        code=code,
        display=display,
    )