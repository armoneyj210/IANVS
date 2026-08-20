from datetime import date

import pytest

from janus_canonical.patient_mapping import (
    map_synthea_patient,
)


def _patient_row() -> dict[str, str]:
    return {
        "Id": "patient-123",
        "BIRTHDATE": "1980-01-02",
        "DEATHDATE": "",
        "SSN": "999-12-3456",
        "DRIVERS": "S99999999",
        "PASSPORT": "X12345678",
        "FIRST": "Ada",
        "LAST": "Lovelace",
        "GENDER": "F",
        "RACE": "white",
        "ETHNICITY": "nonhispanic",
    }


def test_maps_patient_without_inventing_gender() -> None:
    patient = map_synthea_patient(
        _patient_row()
    )

    assert patient.synthea_id == "patient-123"
    assert patient.given_name == "Ada"
    assert patient.family_name == "Lovelace"

    assert patient.birth_date == date(
        1980,
        1,
        2,
    )

    assert patient.deceased_date is None

    assert patient.race == "white"
    assert patient.ethnicity == "nonhispanic"

    assert patient.ssn == "999-12-3456"
    assert patient.drivers == "S99999999"
    assert patient.passport == "X12345678"

    assert not hasattr(
        patient,
        "gender",
    )

    assert not hasattr(
        patient,
        "sex_at_birth",
    )

    assert not hasattr(
        patient,
        "gender_identity",
    )


def test_blank_optional_values_become_none() -> None:
    row = _patient_row()

    row["SSN"] = " "
    row["DRIVERS"] = ""
    row["PASSPORT"] = ""

    patient = map_synthea_patient(row)

    assert patient.ssn is None
    assert patient.drivers is None
    assert patient.passport is None


def test_patient_id_is_required() -> None:
    row = _patient_row()
    row["Id"] = ""

    with pytest.raises(
        ValueError,
        match="Synthea Id is required",
    ):
        map_synthea_patient(row)


def test_invalid_temporal_order_is_rejected() -> None:
    row = _patient_row()

    row["BIRTHDATE"] = "2020-01-01"
    row["DEATHDATE"] = "2019-12-31"

    with pytest.raises(
        ValueError,
        match=(
            "DEATHDATE precedes BIRTHDATE"
        ),
    ):
        map_synthea_patient(row)