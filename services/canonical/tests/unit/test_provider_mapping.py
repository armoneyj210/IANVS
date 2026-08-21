import pytest

from janus_canonical.provider_mapping import (
    PROVIDER_EXTERNAL_ID_PREFIX,
    map_synthea_organization,
    map_synthea_provider,
    provider_external_id,
)

PROVIDER_ID = (
    "11111111-1111-1111-1111-111111111111"
)

ORGANIZATION_ID = (
    "22222222-2222-2222-2222-222222222222"
)


def test_provider_mapping_normalizes_fields() -> None:
    row = {
        "Id": f"  {PROVIDER_ID.upper()}  ",
        "ORGANIZATION": (
            f"  {ORGANIZATION_ID.upper()}  "
        ),
        "NAME": "  Dr. Example  ",
        "GENDER": "F",
        "SPECIALITY": "  General Practice  ",
        "ADDRESS": "123 Test Street",
        "CITY": "Boston",
        "STATE": "MA",
        "ZIP": "02101",
        "LAT": "42.0",
        "LON": "-71.0",
        "ENCOUNTERS": "100",
        "PROCEDURES": "50",
    }

    mapped = map_synthea_provider(row)

    assert (
        mapped.synthea_provider_id
        == PROVIDER_ID
    )

    assert mapped.external_id == (
        PROVIDER_EXTERNAL_ID_PREFIX
        + PROVIDER_ID
    )

    assert (
        mapped.display_name
        == "Dr. Example"
    )

    assert (
        mapped.specialty
        == "General Practice"
    )

    assert (
        mapped.synthea_organization_id
        == ORGANIZATION_ID
    )


def test_provider_mapping_allows_optional_blanks() -> None:
    row = {
        "Id": PROVIDER_ID,
        "ORGANIZATION": "",
        "NAME": " ",
        "SPECIALITY": None,
    }

    mapped = map_synthea_provider(row)

    assert mapped.display_name is None
    assert mapped.specialty is None

    assert (
        mapped.synthea_organization_id
        is None
    )


def test_provider_mapping_requires_provider_id() -> None:
    with pytest.raises(
        ValueError,
        match="providers.csv.Id is required",
    ):
        map_synthea_provider(
            {
                "Id": "",
                "ORGANIZATION": "",
            }
        )


def test_provider_mapping_rejects_invalid_provider_id() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "providers.csv.Id must be "
            "a valid UUID"
        ),
    ):
        map_synthea_provider(
            {
                "Id": "not-a-uuid",
                "ORGANIZATION": "",
            }
        )


def test_provider_mapping_rejects_invalid_organization_id() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "providers.csv.ORGANIZATION "
            "must be a valid UUID"
        ),
    ):
        map_synthea_provider(
            {
                "Id": PROVIDER_ID,
                "ORGANIZATION": "bad-org-id",
            }
        )


def test_organization_mapping_normalizes_values() -> None:
    mapped = map_synthea_organization(
        {
            "Id": (
                f" {ORGANIZATION_ID.upper()} "
            ),
            "NAME": "  Example Health  ",
        }
    )

    assert (
        mapped.synthea_organization_id
        == ORGANIZATION_ID
    )

    assert (
        mapped.organization_name
        == "Example Health"
    )


def test_organization_mapping_requires_name() -> None:
    with pytest.raises(
        ValueError,
        match=(
            "organizations.csv.NAME is required"
        ),
    ):
        map_synthea_organization(
            {
                "Id": ORGANIZATION_ID,
                "NAME": " ",
            }
        )


def test_provider_external_id_is_namespaced() -> None:
    result = provider_external_id(
        PROVIDER_ID.upper()
    )

    assert result == (
        PROVIDER_EXTERNAL_ID_PREFIX
        + PROVIDER_ID
    )
    