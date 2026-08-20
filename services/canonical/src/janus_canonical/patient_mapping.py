from dataclasses import dataclass
from datetime import date
from typing import Any

MAPPING_NAME = "synthea-patient"
MAPPING_VERSION = "1"

PATIENT_SOURCE_PATH = "csv/patients.csv"


@dataclass(frozen=True)
class SyntheaPatientMapping:
    synthea_id: str

    given_name: str | None
    family_name: str | None

    birth_date: date | None
    deceased_date: date | None

    race: str | None
    ethnicity: str | None

    ssn: str | None
    drivers: str | None
    passport: str | None


def _optional_text(
    value: Any,
) -> str | None:
    if value is None:
        return None

    text = str(value).strip()

    return text or None


def _required_text(
    value: Any,
    *,
    field_name: str,
) -> str:
    result = _optional_text(value)

    if result is None:
        raise ValueError(
            f"Synthea {field_name} is required"
        )

    return result


def _optional_date(
    value: Any,
    *,
    field_name: str,
) -> date | None:
    text = _optional_text(value)

    if text is None:
        return None

    try:
        return date.fromisoformat(text)
    except ValueError as error:
        raise ValueError(
            f"Invalid Synthea {field_name}: {text!r}"
        ) from error


def map_synthea_patient(
    row: dict[str | None, Any],
) -> SyntheaPatientMapping:
    if None in row:
        raise ValueError(
            "CSV row contains more values than "
            "the declared header"
        )

    birth_date = _optional_date(
        row.get("BIRTHDATE"),
        field_name="BIRTHDATE",
    )

    deceased_date = _optional_date(
        row.get("DEATHDATE"),
        field_name="DEATHDATE",
    )

    if (
        birth_date is not None
        and deceased_date is not None
        and deceased_date < birth_date
    ):
        raise ValueError(
            "Synthea DEATHDATE precedes BIRTHDATE"
        )

    return SyntheaPatientMapping(
        synthea_id=_required_text(
            row.get("Id"),
            field_name="Id",
        ),
        given_name=_optional_text(
            row.get("FIRST")
        ),
        family_name=_optional_text(
            row.get("LAST")
        ),
        birth_date=birth_date,
        deceased_date=deceased_date,
        race=_optional_text(
            row.get("RACE")
        ),
        ethnicity=_optional_text(
            row.get("ETHNICITY")
        ),
        ssn=_optional_text(
            row.get("SSN")
        ),
        drivers=_optional_text(
            row.get("DRIVERS")
        ),
        passport=_optional_text(
            row.get("PASSPORT")
        ),
    )