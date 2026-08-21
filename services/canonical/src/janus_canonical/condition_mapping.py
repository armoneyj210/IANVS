from dataclasses import dataclass
from datetime import date
from uuid import UUID

MAPPING_NAME = "synthea-condition"
MAPPING_VERSION = "1"

CONDITION_SOURCE_PATH = "csv/conditions.csv"


@dataclass(frozen=True)
class SyntheaConditionMapping:
    synthea_patient_id: str
    synthea_encounter_id: str

    onset_date: date
    resolved_date: date | None

    code_system: str
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


def _parse_date(
    value: str,
    *,
    field_name: str,
) -> date:
    normalized = value.strip()

    try:
        return date.fromisoformat(
            normalized
        )
    except ValueError as error:
        raise ValueError(
            f"{field_name} must be a valid "
            "ISO-8601 date"
        ) from error


def _required_date(
    value: str | None,
    *,
    field_name: str,
) -> date:
    normalized = _required_text(
        value,
        field_name=field_name,
    )

    return _parse_date(
        normalized,
        field_name=field_name,
    )


def _optional_date(
    value: str | None,
    *,
    field_name: str,
) -> date | None:
    normalized = _optional_text(value)

    if normalized is None:
        return None

    return _parse_date(
        normalized,
        field_name=field_name,
    )


def map_synthea_condition(
    row: dict[str, str | None],
) -> SyntheaConditionMapping:
    synthea_patient_id = (
        _required_uuid_text(
            row.get("PATIENT"),
            field_name=(
                "conditions.csv.PATIENT"
            ),
        )
    )

    synthea_encounter_id = (
        _required_uuid_text(
            row.get("ENCOUNTER"),
            field_name=(
                "conditions.csv.ENCOUNTER"
            ),
        )
    )

    onset_date = _required_date(
        row.get("START"),
        field_name="conditions.csv.START",
    )

    resolved_date = _optional_date(
        row.get("STOP"),
        field_name="conditions.csv.STOP",
    )

    if (
        resolved_date is not None
        and resolved_date < onset_date
    ):
        raise ValueError(
            "conditions.csv.STOP may not precede "
            "conditions.csv.START"
        )

    code_system = _required_text(
        row.get("SYSTEM"),
        field_name="conditions.csv.SYSTEM",
    )

    code = _required_text(
        row.get("CODE"),
        field_name="conditions.csv.CODE",
    )

    display = _required_text(
        row.get("DESCRIPTION"),
        field_name=(
            "conditions.csv.DESCRIPTION"
        ),
    )

    return SyntheaConditionMapping(
        synthea_patient_id=(
            synthea_patient_id
        ),
        synthea_encounter_id=(
            synthea_encounter_id
        ),
        onset_date=onset_date,
        resolved_date=resolved_date,
        code_system=code_system,
        code=code,
        display=display,
    )