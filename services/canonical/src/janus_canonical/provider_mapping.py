from dataclasses import dataclass
from uuid import UUID

MAPPING_NAME = "synthea-provider"
MAPPING_VERSION = "1"

PROVIDER_SOURCE_PATH = "csv/providers.csv"
ORGANIZATION_SOURCE_PATH = "csv/organizations.csv"

PROVIDER_EXTERNAL_ID_PREFIX = (
    "urn:janus:source:synthea:provider-id:"
)


@dataclass(frozen=True)
class SyntheaProviderMapping:
    synthea_provider_id: str
    external_id: str
    display_name: str | None
    specialty: str | None
    synthea_organization_id: str | None


@dataclass(frozen=True)
class SyntheaOrganizationMapping:
    synthea_organization_id: str
    organization_name: str


def _optional_text(
    value: str | None,
) -> str | None:
    if value is None:
        return None

    normalized = value.strip()

    return normalized or None


def _required_uuid_text(
    value: str | None,
    *,
    field_name: str,
) -> str:
    normalized = _optional_text(value)

    if normalized is None:
        raise ValueError(
            f"{field_name} is required"
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


def provider_external_id(
    synthea_provider_id: str,
) -> str:
    provider_id = _required_uuid_text(
        synthea_provider_id,
        field_name="providers.csv.Id",
    )

    return (
        PROVIDER_EXTERNAL_ID_PREFIX
        + provider_id
    )


def map_synthea_provider(
    row: dict[str, str | None],
) -> SyntheaProviderMapping:
    synthea_provider_id = _required_uuid_text(
        row.get("Id"),
        field_name="providers.csv.Id",
    )

    synthea_organization_id = (
        _optional_uuid_text(
            row.get("ORGANIZATION"),
            field_name=(
                "providers.csv.ORGANIZATION"
            ),
        )
    )

    return SyntheaProviderMapping(
        synthea_provider_id=(
            synthea_provider_id
        ),
        external_id=(
            PROVIDER_EXTERNAL_ID_PREFIX
            + synthea_provider_id
        ),
        display_name=_optional_text(
            row.get("NAME")
        ),
        specialty=_optional_text(
            row.get("SPECIALITY")
        ),
        synthea_organization_id=(
            synthea_organization_id
        ),
    )


def map_synthea_organization(
    row: dict[str, str | None],
) -> SyntheaOrganizationMapping:
    synthea_organization_id = (
        _required_uuid_text(
            row.get("Id"),
            field_name=(
                "organizations.csv.Id"
            ),
        )
    )

    organization_name = _optional_text(
        row.get("NAME")
    )

    if organization_name is None:
        raise ValueError(
            "organizations.csv.NAME is required "
            "for Provider Mapping v1"
        )

    return SyntheaOrganizationMapping(
        synthea_organization_id=(
            synthea_organization_id
        ),
        organization_name=organization_name,
    )