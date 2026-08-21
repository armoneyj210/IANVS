import csv
import hashlib
import subprocess
from importlib.metadata import (
    PackageNotFoundError,
    version,
)
from typing import Any
from uuid import UUID

from janus_etl.dataset_descriptor import (
    GovernedDatasetDescriptor,
)
from janus_etl.import_runtime import (
    _canonical_row_payload,
    preflight_release,
)
from psycopg import Error as PsycopgError
from psycopg.types.json import Jsonb

from janus_canonical.condition_mapping import (
    CONDITION_SOURCE_PATH,
    map_synthea_condition,
)
from janus_canonical.condition_mapping import (
    MAPPING_NAME as CONDITION_MAPPING_NAME,
)
from janus_canonical.condition_mapping import (
    MAPPING_VERSION as CONDITION_MAPPING_VERSION,
)
from janus_canonical.config import (
    REPO_ROOT,
    CanonicalSettings,
)
from janus_canonical.db import (
    _set_environment,
    open_connection,
)
from janus_canonical.encounter_mapping import (
    ENCOUNTER_SOURCE_PATH,
    map_synthea_encounter,
)
from janus_canonical.encounter_mapping import (
    MAPPING_NAME as ENCOUNTER_MAPPING_NAME,
)
from janus_canonical.encounter_mapping import (
    MAPPING_VERSION as ENCOUNTER_MAPPING_VERSION,
)
from janus_canonical.patient_mapping import (
    MAPPING_NAME,
    MAPPING_VERSION,
    PATIENT_SOURCE_PATH,
    map_synthea_patient,
)
from janus_canonical.provider_mapping import (
    MAPPING_NAME as PROVIDER_MAPPING_NAME,
)
from janus_canonical.provider_mapping import (
    MAPPING_VERSION as PROVIDER_MAPPING_VERSION,
)
from janus_canonical.provider_mapping import (
    ORGANIZATION_SOURCE_PATH,
    PROVIDER_SOURCE_PATH,
    map_synthea_organization,
    map_synthea_provider,
)


def _service_version() -> str:
    try:
        return version("janus-canonical")
    except PackageNotFoundError:
        return "0+local"


def _git_commit_sha() -> str | None:
    result = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return None

    commit = result.stdout.strip()

    return commit or None


def _write_system_event(
    cursor,
    *,
    event_type: str,
    outcome: str,
    message: str,
    metadata: dict[str, Any],
    severity: str = "info",
) -> UUID:
    event = {
        "event_type": event_type,
        "severity": severity,
        "outcome": outcome,
        "component": "promotion_runtime",
        "message": message,
        "metadata": metadata,
    }

    cursor.execute(
        """
        SELECT ops.write_system_event(
            %s::jsonb
        ) AS system_event_id;
        """,
        (Jsonb(event),),
    )

    return cursor.fetchone()["system_event_id"]


def _resolve_import_batch(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
    dataset_release_id: UUID,
) -> dict[str, Any]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                import_batch_id,
                dataset_release_id,
                status,
                environment,
                records_seen,
                records_accepted,
                records_rejected,
                correlation_id,
                completed_at
            FROM ingest.import_batch
            WHERE import_batch_id = %s;
            """,
            (import_batch_id,),
        )

        batch = cursor.fetchone()

    if batch is None:
        raise ValueError(
            f"Import batch not found: {import_batch_id}"
        )

    if (
        batch["dataset_release_id"]
        != dataset_release_id
    ):
        raise ValueError(
            "Import batch does not belong to the "
            "verified dataset release"
        )

    if batch["status"] != "completed":
        raise ValueError(
            "Canonical promotion requires a completed "
            f"import batch: status={batch['status']}"
        )

    if (
        batch["records_seen"]
        != batch["records_accepted"]
        or batch["records_rejected"] != 0
    ):
        raise ValueError(
            "Import batch counters do not authorize "
            "canonical promotion"
        )

    return batch


def _resolve_patient_source_file(
    preflight: dict[str, Any],
) -> dict[str, Any]:
    matches = [
        source_file
        for source_file in preflight[
            "importable_source_files"
        ]
        if source_file["relative_path"]
        == PATIENT_SOURCE_PATH
    ]

    if len(matches) != 1:
        raise RuntimeError(
            "Verified release must contain exactly one "
            f"{PATIENT_SOURCE_PATH} artifact"
        )

    return matches[0]


def _load_patient_source_records(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
    source_file_id: UUID,
) -> dict[int, dict[str, Any]]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                source_record_id,
                row_number,
                source_record_key,
                resource_type,
                record_locator,
                payload_sha256,
                record_status
            FROM ingest.source_record
            WHERE import_batch_id = %s
              AND source_file_id = %s
            ORDER BY row_number;
            """,
            (
                import_batch_id,
                source_file_id,
            ),
        )

        rows = cursor.fetchall()

    result: dict[int, dict[str, Any]] = {}

    for row in rows:
        row_number = row["row_number"]

        if row_number is None:
            raise RuntimeError(
                "Patient source record is missing "
                "its row number"
            )

        if row_number in result:
            raise RuntimeError(
                "Duplicate patient source row number: "
                f"{row_number}"
            )

        result[row_number] = row

    return result


def _begin_promotion(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    service_version = _service_version()
    git_commit_sha = _git_commit_sha()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.begin_canonical_promotion(
                %s,
                %s,
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                import_batch_id,
                MAPPING_NAME,
                MAPPING_VERSION,
                service_version,
                git_commit_sha,
            ),
        )

        promotion = cursor.fetchone()
        promotion_run_id = promotion[
            "canonical_promotion_run_id"
        ]

        event_id = _write_system_event(
            cursor,
            event_type=(
                "canonical.patient_promotion_started"
            ),
            outcome="success",
            message=(
                "Janus Synthea patient canonical "
                "promotion started"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name": MAPPING_NAME,
                "mapping_version": MAPPING_VERSION,
                "service_version": service_version,
                "git_commit_sha": git_commit_sha,
            },
        )

    return {
        "canonical_promotion_run_id":
            promotion_run_id,
        "service_version": service_version,
        "git_commit_sha": git_commit_sha,
        "system_event_id": event_id,
    }


def _fail_promotion(
    settings: CanonicalSettings,
    *,
    canonical_promotion_run_id: UUID,
    import_batch_id: UUID,
    error: Exception,
) -> None:
    error_summary = {
        "error_type": type(error).__name__,
        "message": str(error)[:2000],
    }

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.fail_canonical_promotion(
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                canonical_promotion_run_id,
                Jsonb(error_summary),
                Jsonb(
                    {
                        "mapping_name":
                            MAPPING_NAME,
                        "mapping_version":
                            MAPPING_VERSION,
                    }
                ),
            ),
        )

        _write_system_event(
            cursor,
            event_type=(
                "canonical.patient_promotion_failed"
            ),
            outcome="failure",
            severity="error",
            message=(
                "Janus Synthea patient canonical "
                "promotion failed"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    canonical_promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name": MAPPING_NAME,
                "mapping_version": MAPPING_VERSION,
                "error_type": error_summary[
                    "error_type"
                ],
            },
        )


def promote_patients(
    settings: CanonicalSettings,
    descriptor: GovernedDatasetDescriptor,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    # Re-verify the full governed release before reading
    # patients.csv for canonical promotion.
    preflight = preflight_release(
        settings,
        descriptor,
    )

    dataset_release_id = preflight["release"][
        "dataset_release_id"
    ]

    batch = _resolve_import_batch(
        settings,
        import_batch_id=import_batch_id,
        dataset_release_id=dataset_release_id,
    )

    patient_source_file = (
        _resolve_patient_source_file(preflight)
    )

    expected_patient_rows = (
        patient_source_file["row_count"]
    )

    if expected_patient_rows is None:
        raise RuntimeError(
            "Registered patients.csv row count "
            "is missing"
        )

    source_records = _load_patient_source_records(
        settings,
        import_batch_id=import_batch_id,
        source_file_id=patient_source_file[
            "source_file_id"
        ],
    )

    if len(source_records) != expected_patient_rows:
        raise RuntimeError(
            "Patient source-record count does not "
            "match the verified patients.csv row count: "
            f"source_records={len(source_records)}, "
            f"verified_rows={expected_patient_rows}"
        )

    promotion = _begin_promotion(
        settings,
        import_batch_id=import_batch_id,
    )

    promotion_run_id = promotion[
        "canonical_promotion_run_id"
    ]

    records_seen = 0
    records_created = 0
    records_existing = 0
    identifiers_created = 0
    lineage_edges_created = 0

    patient_file_path = (
        preflight["raw_directory"]
        / PATIENT_SOURCE_PATH
    )

    try:
        with (
            open_connection(settings) as conn,
            conn.cursor() as cursor,
            patient_file_path.open(
                "r",
                encoding="utf-8-sig",
                newline="",
            ) as handle,
        ):
            _set_environment(cursor, settings)

            reader = csv.DictReader(handle)

            if reader.fieldnames is None:
                raise RuntimeError(
                    "patients.csv has no header"
                )

            for row_number, row in enumerate(
                reader,
                start=1,
            ):
                source_record = source_records.get(
                    row_number
                )

                if source_record is None:
                    raise RuntimeError(
                        "Verified patients.csv row has "
                        "no matching governed source record: "
                        f"row={row_number}"
                    )

                if (
                    source_record["record_status"]
                    != "accepted"
                ):
                    raise RuntimeError(
                        "Patient source record is not "
                        "accepted: "
                        f"row={row_number}, "
                        f"status="
                        f"{source_record['record_status']}"
                    )

                payload = _canonical_row_payload(
                    row
                )

                payload_sha256 = hashlib.sha256(
                    payload
                ).hexdigest()

                if (
                    payload_sha256
                    != source_record[
                        "payload_sha256"
                    ]
                ):
                    raise RuntimeError(
                        "Physical patient source row "
                        "does not match imported payload "
                        f"hash: row={row_number}"
                    )

                patient = map_synthea_patient(
                    row
                )

                cursor.execute(
                    """
                    SELECT *
                    FROM ingest.promote_synthea_patient_v1(
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s
                    );
                    """,
                    (
                        promotion_run_id,
                        source_record[
                            "source_record_id"
                        ],
                        payload_sha256,
                        patient.given_name,
                        patient.family_name,
                        patient.birth_date,
                        patient.deceased_date,
                        patient.race,
                        patient.ethnicity,
                        patient.synthea_id,
                        patient.ssn,
                        patient.drivers,
                        patient.passport,
                    ),
                )

                result = cursor.fetchone()

                if result is None:
                    raise RuntimeError(
                        "Controlled patient promotion "
                        "returned no result"
                    )

                records_seen += 1

                if result["patient_created"]:
                    records_created += 1
                else:
                    records_existing += 1

                identifiers_created += result[
                    "identifiers_created"
                ]

                lineage_edges_created += result[
                    "lineage_edges_created"
                ]

            if records_seen != expected_patient_rows:
                raise RuntimeError(
                    "Canonical patient row count does "
                    "not match verified patients.csv: "
                    f"expected={expected_patient_rows}, "
                    f"actual={records_seen}"
                )

            metrics = {
                "mapping_name": MAPPING_NAME,
                "mapping_version": MAPPING_VERSION,
                "source_artifact":
                    PATIENT_SOURCE_PATH,
                "dataset_release_id": str(
                    dataset_release_id
                ),
                "lineage_edges_created":
                    lineage_edges_created,
                "gender_mapped": False,
                "raw_identifier_values_logged": False,
            }

            cursor.execute(
                """
                SELECT ingest.complete_canonical_promotion(
                    %s,
                    %s,
                    %s,
                    %s,
                    0,
                    %s,
                    %s
                ) AS canonical_promotion_run_id;
                """,
                (
                    promotion_run_id,
                    records_seen,
                    records_created,
                    records_existing,
                    identifiers_created,
                    Jsonb(metrics),
                ),
            )

            completed = cursor.fetchone()

            if completed is None:
                raise RuntimeError(
                    "Canonical promotion completion "
                    "returned no result"
                )

            completed_event_id = (
                _write_system_event(
                    cursor,
                    event_type=(
                        "canonical."
                        "patient_promotion_completed"
                    ),
                    outcome="success",
                    message=(
                        "Janus Synthea patient "
                        "canonical promotion completed"
                    ),
                    metadata={
                        "canonical_promotion_run_id":
                            str(promotion_run_id),
                        "import_batch_id":
                            str(import_batch_id),
                        "records_seen":
                            records_seen,
                        "records_created":
                            records_created,
                        "records_existing":
                            records_existing,
                        "identifiers_created":
                            identifiers_created,
                        "lineage_edges_created":
                            lineage_edges_created,
                    },
                )
            )

        return {
            "canonical_promotion_run_id":
                promotion_run_id,
            "import_batch_id": import_batch_id,
            "dataset_release_id":
                dataset_release_id,
            "release_label": preflight[
                "release"
            ]["release_label"],
            "mapping_name": MAPPING_NAME,
            "mapping_version": MAPPING_VERSION,
            "records_seen": records_seen,
            "records_created": records_created,
            "records_existing": records_existing,
            "records_failed": 0,
            "identifiers_created":
                identifiers_created,
            "lineage_edges_created":
                lineage_edges_created,
            "started_system_event_id":
                promotion["system_event_id"],
            "completed_system_event_id":
                completed_event_id,
            "import_correlation_id":
                batch["correlation_id"],
        }

    except Exception as error:
        try:
            _fail_promotion(
                settings,
                canonical_promotion_run_id=(
                    promotion_run_id
                ),
                import_batch_id=import_batch_id,
                error=error,
            )
        except PsycopgError as fail_error:
            error.add_note(
                "Canonical fail-closed recording "
                "also failed: "
                f"{type(fail_error).__name__}: "
                f"{fail_error}"
            )

        raise

def _resolve_provider_source_file(
    preflight: dict[str, Any],
    relative_path: str,
) -> dict[str, Any]:
    matches = [
        source_file
        for source_file in preflight[
            "importable_source_files"
        ]
        if source_file["relative_path"]
        == relative_path
    ]

    if len(matches) != 1:
        raise RuntimeError(
            "Verified release must contain exactly one "
            f"{relative_path} artifact"
        )

    return matches[0]


def _load_provider_source_records(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
    source_file_id: UUID,
    source_label: str,
) -> dict[int, dict[str, Any]]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                source_record_id,
                row_number,
                source_record_key,
                resource_type,
                record_locator,
                payload_sha256,
                record_status
            FROM ingest.source_record
            WHERE import_batch_id = %s
              AND source_file_id = %s
            ORDER BY row_number;
            """,
            (
                import_batch_id,
                source_file_id,
            ),
        )

        rows = cursor.fetchall()

    result: dict[int, dict[str, Any]] = {}

    for row in rows:
        row_number = row["row_number"]

        if row_number is None:
            raise RuntimeError(
                f"{source_label} source record "
                "is missing its row number"
            )

        if row_number in result:
            raise RuntimeError(
                f"Duplicate {source_label} source "
                f"row number: {row_number}"
            )

        result[row_number] = row

    return result


def _verified_provider_payload_sha256(
    *,
    row: dict[str, str | None],
    source_record: dict[str, Any],
    source_label: str,
    row_number: int,
) -> str:
    if (
        source_record["record_status"]
        != "accepted"
    ):
        raise RuntimeError(
            f"{source_label} source record is not "
            "accepted: "
            f"row={row_number}, "
            f"status="
            f"{source_record['record_status']}"
        )

    payload = _canonical_row_payload(row)

    payload_sha256 = hashlib.sha256(
        payload
    ).hexdigest()

    if (
        payload_sha256
        != source_record["payload_sha256"]
    ):
        raise RuntimeError(
            f"Physical {source_label} source row "
            "does not match imported payload hash: "
            f"row={row_number}"
        )

    return payload_sha256


def _load_verified_provider_organizations(
    preflight: dict[str, Any],
    *,
    source_records: dict[
        int,
        dict[str, Any],
    ],
    expected_rows: int,
) -> dict[str, dict[str, Any]]:
    organization_file_path = (
        preflight["raw_directory"]
        / ORGANIZATION_SOURCE_PATH
    )

    organizations: dict[
        str,
        dict[str, Any],
    ] = {}

    rows_seen = 0

    with organization_file_path.open(
        "r",
        encoding="utf-8-sig",
        newline="",
    ) as handle:
        reader = csv.DictReader(handle)

        if reader.fieldnames is None:
            raise RuntimeError(
                "organizations.csv has no header"
            )

        for row_number, row in enumerate(
            reader,
            start=1,
        ):
            source_record = source_records.get(
                row_number
            )

            if source_record is None:
                raise RuntimeError(
                    "Verified organizations.csv row "
                    "has no matching governed source "
                    f"record: row={row_number}"
                )

            payload_sha256 = (
                _verified_provider_payload_sha256(
                    row=row,
                    source_record=source_record,
                    source_label="Organization",
                    row_number=row_number,
                )
            )

            organization = (
                map_synthea_organization(row)
            )

            organization_id = (
                organization.
                synthea_organization_id
            )

            if organization_id in organizations:
                raise RuntimeError(
                    "Duplicate normalized Synthea "
                    "organization Id: "
                    f"{organization_id}"
                )

            organizations[
                organization_id
            ] = {
                "source_record_id":
                    source_record[
                        "source_record_id"
                    ],
                "payload_sha256":
                    payload_sha256,
                "organization":
                    organization,
            }

            rows_seen += 1

    if rows_seen != expected_rows:
        raise RuntimeError(
            "Verified organization row count does "
            "not match organizations.csv: "
            f"expected={expected_rows}, "
            f"actual={rows_seen}"
        )

    return organizations


def _begin_provider_promotion(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    service_version = _service_version()
    git_commit_sha = _git_commit_sha()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.begin_canonical_promotion(
                %s,
                %s,
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                import_batch_id,
                PROVIDER_MAPPING_NAME,
                PROVIDER_MAPPING_VERSION,
                service_version,
                git_commit_sha,
            ),
        )

        promotion = cursor.fetchone()

        if promotion is None:
            raise RuntimeError(
                "Provider promotion start returned "
                "no result"
            )

        promotion_run_id = promotion[
            "canonical_promotion_run_id"
        ]

        event_id = _write_system_event(
            cursor,
            event_type=(
                "canonical."
                "provider_promotion_started"
            ),
            outcome="success",
            message=(
                "Janus Synthea provider canonical "
                "promotion started"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name":
                    PROVIDER_MAPPING_NAME,
                "mapping_version":
                    PROVIDER_MAPPING_VERSION,
                "service_version":
                    service_version,
                "git_commit_sha":
                    git_commit_sha,
            },
        )

    return {
        "canonical_promotion_run_id":
            promotion_run_id,
        "service_version": service_version,
        "git_commit_sha": git_commit_sha,
        "system_event_id": event_id,
    }


def _fail_provider_promotion(
    settings: CanonicalSettings,
    *,
    canonical_promotion_run_id: UUID,
    import_batch_id: UUID,
    error: Exception,
) -> None:
    error_summary = {
        "error_type": type(error).__name__,
        "message": str(error)[:2000],
    }

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.fail_canonical_promotion(
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                canonical_promotion_run_id,
                Jsonb(error_summary),
                Jsonb(
                    {
                        "mapping_name":
                            PROVIDER_MAPPING_NAME,
                        "mapping_version":
                            PROVIDER_MAPPING_VERSION,
                    }
                ),
            ),
        )

        _write_system_event(
            cursor,
            event_type=(
                "canonical."
                "provider_promotion_failed"
            ),
            outcome="failure",
            severity="error",
            message=(
                "Janus Synthea provider canonical "
                "promotion failed"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    canonical_promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name":
                    PROVIDER_MAPPING_NAME,
                "mapping_version":
                    PROVIDER_MAPPING_VERSION,
                "error_type":
                    error_summary["error_type"],
            },
        )


def promote_providers(
    settings: CanonicalSettings,
    descriptor: GovernedDatasetDescriptor,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    preflight = preflight_release(
        settings,
        descriptor,
    )

    dataset_release_id = preflight["release"][
        "dataset_release_id"
    ]

    batch = _resolve_import_batch(
        settings,
        import_batch_id=import_batch_id,
        dataset_release_id=dataset_release_id,
    )

    provider_source_file = (
        _resolve_provider_source_file(
            preflight,
            PROVIDER_SOURCE_PATH,
        )
    )

    organization_source_file = (
        _resolve_provider_source_file(
            preflight,
            ORGANIZATION_SOURCE_PATH,
        )
    )

    expected_provider_rows = (
        provider_source_file["row_count"]
    )

    expected_organization_rows = (
        organization_source_file["row_count"]
    )

    if expected_provider_rows is None:
        raise RuntimeError(
            "Registered providers.csv row count "
            "is missing"
        )

    if expected_organization_rows is None:
        raise RuntimeError(
            "Registered organizations.csv row count "
            "is missing"
        )

    provider_source_records = (
        _load_provider_source_records(
            settings,
            import_batch_id=import_batch_id,
            source_file_id=provider_source_file[
                "source_file_id"
            ],
            source_label="Provider",
        )
    )

    organization_source_records = (
        _load_provider_source_records(
            settings,
            import_batch_id=import_batch_id,
            source_file_id=(
                organization_source_file[
                    "source_file_id"
                ]
            ),
            source_label="Organization",
        )
    )

    if (
        len(provider_source_records)
        != expected_provider_rows
    ):
        raise RuntimeError(
            "Provider source-record count does "
            "not match verified providers.csv: "
            f"source_records="
            f"{len(provider_source_records)}, "
            f"verified_rows="
            f"{expected_provider_rows}"
        )

    if (
        len(organization_source_records)
        != expected_organization_rows
    ):
        raise RuntimeError(
            "Organization source-record count does "
            "not match verified organizations.csv: "
            f"source_records="
            f"{len(organization_source_records)}, "
            f"verified_rows="
            f"{expected_organization_rows}"
        )

    organizations = (
        _load_verified_provider_organizations(
            preflight,
            source_records=(
                organization_source_records
            ),
            expected_rows=(
                expected_organization_rows
            ),
        )
    )

    promotion = _begin_provider_promotion(
        settings,
        import_batch_id=import_batch_id,
    )

    promotion_run_id = promotion[
        "canonical_promotion_run_id"
    ]

    records_seen = 0
    records_created = 0
    records_existing = 0
    lineage_edges_created = 0

    providers_with_organization = 0

    organization_ids_used: set[str] = set()

    provider_file_path = (
        preflight["raw_directory"]
        / PROVIDER_SOURCE_PATH
    )

    try:
        with (
            open_connection(settings) as conn,
            conn.cursor() as cursor,
            provider_file_path.open(
                "r",
                encoding="utf-8-sig",
                newline="",
            ) as handle,
        ):
            _set_environment(cursor, settings)

            reader = csv.DictReader(handle)

            if reader.fieldnames is None:
                raise RuntimeError(
                    "providers.csv has no header"
                )

            for row_number, row in enumerate(
                reader,
                start=1,
            ):
                source_record = (
                    provider_source_records.get(
                        row_number
                    )
                )

                if source_record is None:
                    raise RuntimeError(
                        "Verified providers.csv row "
                        "has no matching governed "
                        "source record: "
                        f"row={row_number}"
                    )

                provider_payload_sha256 = (
                    _verified_provider_payload_sha256(
                        row=row,
                        source_record=source_record,
                        source_label="Provider",
                        row_number=row_number,
                    )
                )

                provider = (
                    map_synthea_provider(row)
                )

                organization_source_record_id = (
                    None
                )
                organization_payload_sha256 = None
                synthea_organization_id = None
                organization_name = None

                if (
                    provider.
                    synthea_organization_id
                    is not None
                ):
                    organization_evidence = (
                        organizations.get(
                            provider.
                            synthea_organization_id
                        )
                    )

                    if organization_evidence is None:
                        raise RuntimeError(
                            "Provider references an "
                            "unknown governed "
                            "organization: "
                            f"provider="
                            f"{provider.synthea_provider_id}, "
                            f"organization="
                            f"{provider.synthea_organization_id}"
                        )

                    organization = (
                        organization_evidence[
                            "organization"
                        ]
                    )

                    organization_source_record_id = (
                        organization_evidence[
                            "source_record_id"
                        ]
                    )

                    organization_payload_sha256 = (
                        organization_evidence[
                            "payload_sha256"
                        ]
                    )

                    synthea_organization_id = (
                        organization.
                        synthea_organization_id
                    )

                    organization_name = (
                        organization.
                        organization_name
                    )

                    providers_with_organization += 1

                    organization_ids_used.add(
                        synthea_organization_id
                    )

                cursor.execute(
                    """
                    SELECT *
                    FROM ingest.promote_synthea_provider_v1(
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s
                    );
                    """,
                    (
                        promotion_run_id,
                        source_record[
                            "source_record_id"
                        ],
                        provider_payload_sha256,
                        provider.synthea_provider_id,
                        provider.display_name,
                        provider.specialty,
                        organization_source_record_id,
                        organization_payload_sha256,
                        synthea_organization_id,
                        organization_name,
                    ),
                )

                result = cursor.fetchone()

                if result is None:
                    raise RuntimeError(
                        "Controlled provider "
                        "promotion returned no result"
                    )

                records_seen += 1

                if result["provider_created"]:
                    records_created += 1
                else:
                    records_existing += 1

                lineage_edges_created += result[
                    "lineage_edges_created"
                ]

            if (
                records_seen
                != expected_provider_rows
            ):
                raise RuntimeError(
                    "Canonical provider row count "
                    "does not match providers.csv: "
                    f"expected="
                    f"{expected_provider_rows}, "
                    f"actual={records_seen}"
                )

            metrics = {
                "mapping_name":
                    PROVIDER_MAPPING_NAME,
                "mapping_version":
                    PROVIDER_MAPPING_VERSION,
                "source_artifacts": [
                    PROVIDER_SOURCE_PATH,
                    ORGANIZATION_SOURCE_PATH,
                ],
                "dataset_release_id": str(
                    dataset_release_id
                ),
                "organizations_verified":
                    expected_organization_rows,
                "providers_with_organization":
                    providers_with_organization,
                "distinct_organizations_used":
                    len(organization_ids_used),
                "lineage_edges_created":
                    lineage_edges_created,
                "gender_mapped": False,
                "provider_address_mapped":
                    False,
                "source_aggregate_counters_mapped":
                    False,
                "raw_identifier_values_logged":
                    False,
            }

            cursor.execute(
                """
                SELECT ingest.complete_canonical_promotion(
                    %s,
                    %s,
                    %s,
                    %s,
                    0,
                    0,
                    %s
                ) AS canonical_promotion_run_id;
                """,
                (
                    promotion_run_id,
                    records_seen,
                    records_created,
                    records_existing,
                    Jsonb(metrics),
                ),
            )

            completed = cursor.fetchone()

            if completed is None:
                raise RuntimeError(
                    "Provider promotion completion "
                    "returned no result"
                )

            completed_event_id = (
                _write_system_event(
                    cursor,
                    event_type=(
                        "canonical."
                        "provider_promotion_completed"
                    ),
                    outcome="success",
                    message=(
                        "Janus Synthea provider "
                        "canonical promotion completed"
                    ),
                    metadata={
                        "canonical_promotion_run_id":
                            str(promotion_run_id),
                        "import_batch_id":
                            str(import_batch_id),
                        "records_seen":
                            records_seen,
                        "records_created":
                            records_created,
                        "records_existing":
                            records_existing,
                        "providers_with_organization":
                            providers_with_organization,
                        "distinct_organizations_used":
                            len(
                                organization_ids_used
                            ),
                        "lineage_edges_created":
                            lineage_edges_created,
                    },
                )
            )

        return {
            "canonical_promotion_run_id":
                promotion_run_id,
            "import_batch_id":
                import_batch_id,
            "dataset_release_id":
                dataset_release_id,
            "release_label":
                preflight["release"][
                    "release_label"
                ],
            "mapping_name":
                PROVIDER_MAPPING_NAME,
            "mapping_version":
                PROVIDER_MAPPING_VERSION,
            "records_seen":
                records_seen,
            "records_created":
                records_created,
            "records_existing":
                records_existing,
            "records_failed":
                0,
            "providers_with_organization":
                providers_with_organization,
            "distinct_organizations_used":
                len(organization_ids_used),
            "lineage_edges_created":
                lineage_edges_created,
            "started_system_event_id":
                promotion["system_event_id"],
            "completed_system_event_id":
                completed_event_id,
            "import_correlation_id":
                batch["correlation_id"],
        }

    except Exception as error:
        try:
            _fail_provider_promotion(
                settings,
                canonical_promotion_run_id=(
                    promotion_run_id
                ),
                import_batch_id=(
                    import_batch_id
                ),
                error=error,
            )
        except PsycopgError as fail_error:
            error.add_note(
                "Canonical fail-closed recording "
                "also failed: "
                f"{type(fail_error).__name__}: "
                f"{fail_error}"
            )

        raise

def _resolve_encounter_source_file(
    preflight: dict[str, Any],
) -> dict[str, Any]:
    matches = [
        source_file
        for source_file in preflight[
            "importable_source_files"
        ]
        if source_file["relative_path"]
        == ENCOUNTER_SOURCE_PATH
    ]

    if len(matches) != 1:
        raise RuntimeError(
            "Verified release must contain exactly one "
            f"{ENCOUNTER_SOURCE_PATH} artifact"
        )

    return matches[0]


def _load_encounter_source_records(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
    source_file_id: UUID,
) -> dict[int, dict[str, Any]]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                source_record_id,
                row_number,
                source_record_key,
                resource_type,
                record_locator,
                payload_sha256,
                record_status
            FROM ingest.source_record
            WHERE import_batch_id = %s
              AND source_file_id = %s
            ORDER BY row_number;
            """,
            (
                import_batch_id,
                source_file_id,
            ),
        )

        rows = cursor.fetchall()

    result: dict[int, dict[str, Any]] = {}

    for row in rows:
        row_number = row["row_number"]

        if row_number is None:
            raise RuntimeError(
                "Encounter source record is missing "
                "its row number"
            )

        if row_number in result:
            raise RuntimeError(
                "Duplicate Encounter source row "
                f"number: {row_number}"
            )

        result[row_number] = row

    return result


def _verified_encounter_payload_sha256(
    *,
    row: dict[str, str | None],
    source_record: dict[str, Any],
    row_number: int,
) -> str:
    if (
        source_record["record_status"]
        != "accepted"
    ):
        raise RuntimeError(
            "Encounter source record is not "
            "accepted: "
            f"row={row_number}, "
            f"status="
            f"{source_record['record_status']}"
        )

    if (
        source_record["resource_type"]
        != "encounters"
    ):
        raise RuntimeError(
            "Encounter governed source record has "
            "unexpected resource type: "
            f"row={row_number}, "
            f"resource_type="
            f"{source_record['resource_type']}"
        )

    payload = _canonical_row_payload(row)

    payload_sha256 = hashlib.sha256(
        payload
    ).hexdigest()

    if (
        payload_sha256
        != source_record["payload_sha256"]
    ):
        raise RuntimeError(
            "Physical Encounter source row does not "
            "match imported payload hash: "
            f"row={row_number}"
        )

    return payload_sha256


def _begin_encounter_promotion(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    service_version = _service_version()
    git_commit_sha = _git_commit_sha()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.begin_canonical_promotion(
                %s,
                %s,
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                import_batch_id,
                ENCOUNTER_MAPPING_NAME,
                ENCOUNTER_MAPPING_VERSION,
                service_version,
                git_commit_sha,
            ),
        )

        promotion = cursor.fetchone()

        if promotion is None:
            raise RuntimeError(
                "Encounter promotion start returned "
                "no result"
            )

        promotion_run_id = promotion[
            "canonical_promotion_run_id"
        ]

        event_id = _write_system_event(
            cursor,
            event_type=(
                "canonical."
                "encounter_promotion_started"
            ),
            outcome="success",
            message=(
                "Janus Synthea Encounter canonical "
                "promotion started"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name":
                    ENCOUNTER_MAPPING_NAME,
                "mapping_version":
                    ENCOUNTER_MAPPING_VERSION,
                "service_version":
                    service_version,
                "git_commit_sha":
                    git_commit_sha,
            },
        )

    return {
        "canonical_promotion_run_id":
            promotion_run_id,
        "service_version":
            service_version,
        "git_commit_sha":
            git_commit_sha,
        "system_event_id":
            event_id,
    }


def _fail_encounter_promotion(
    settings: CanonicalSettings,
    *,
    canonical_promotion_run_id: UUID,
    import_batch_id: UUID,
    error: Exception,
) -> None:
    error_summary = {
        "error_type": type(error).__name__,
        "message": str(error)[:2000],
    }

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.fail_canonical_promotion(
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                canonical_promotion_run_id,
                Jsonb(error_summary),
                Jsonb(
                    {
                        "mapping_name":
                            ENCOUNTER_MAPPING_NAME,
                        "mapping_version":
                            ENCOUNTER_MAPPING_VERSION,
                    }
                ),
            ),
        )

        _write_system_event(
            cursor,
            event_type=(
                "canonical."
                "encounter_promotion_failed"
            ),
            outcome="failure",
            severity="error",
            message=(
                "Janus Synthea Encounter canonical "
                "promotion failed"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    canonical_promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name":
                    ENCOUNTER_MAPPING_NAME,
                "mapping_version":
                    ENCOUNTER_MAPPING_VERSION,
                "error_type":
                    error_summary["error_type"],
            },
        )


def promote_encounters(
    settings: CanonicalSettings,
    descriptor: GovernedDatasetDescriptor,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    # Re-verify the governed release before consuming the
    # physical encounters.csv artifact.
    preflight = preflight_release(
        settings,
        descriptor,
    )

    dataset_release_id = preflight["release"][
        "dataset_release_id"
    ]

    batch = _resolve_import_batch(
        settings,
        import_batch_id=import_batch_id,
        dataset_release_id=dataset_release_id,
    )

    encounter_source_file = (
        _resolve_encounter_source_file(
            preflight
        )
    )

    expected_encounter_rows = (
        encounter_source_file["row_count"]
    )

    if expected_encounter_rows is None:
        raise RuntimeError(
            "Registered encounters.csv row count "
            "is missing"
        )

    source_records = (
        _load_encounter_source_records(
            settings,
            import_batch_id=import_batch_id,
            source_file_id=(
                encounter_source_file[
                    "source_file_id"
                ]
            ),
        )
    )

    if (
        len(source_records)
        != expected_encounter_rows
    ):
        raise RuntimeError(
            "Encounter source-record count does not "
            "match verified encounters.csv row count: "
            f"source_records={len(source_records)}, "
            f"verified_rows={expected_encounter_rows}"
        )

    promotion = _begin_encounter_promotion(
        settings,
        import_batch_id=import_batch_id,
    )

    promotion_run_id = promotion[
        "canonical_promotion_run_id"
    ]

    records_seen = 0
    records_created = 0
    records_existing = 0

    identifiers_created = 0
    lineage_edges_created = 0

    encounters_with_provider = 0
    encounters_without_provider = 0

    encounters_with_reason = 0
    encounters_without_reason = 0

    encounter_file_path = (
        preflight["raw_directory"]
        / ENCOUNTER_SOURCE_PATH
    )

    try:
        with (
            open_connection(settings) as conn,
            conn.cursor() as cursor,
            encounter_file_path.open(
                "r",
                encoding="utf-8-sig",
                newline="",
            ) as handle,
        ):
            _set_environment(cursor, settings)

            reader = csv.DictReader(handle)

            if reader.fieldnames is None:
                raise RuntimeError(
                    "encounters.csv has no header"
                )

            for row_number, row in enumerate(
                reader,
                start=1,
            ):
                source_record = (
                    source_records.get(
                        row_number
                    )
                )

                if source_record is None:
                    raise RuntimeError(
                        "Verified encounters.csv row "
                        "has no matching governed "
                        "source record: "
                        f"row={row_number}"
                    )

                payload_sha256 = (
                    _verified_encounter_payload_sha256(
                        row=row,
                        source_record=source_record,
                        row_number=row_number,
                    )
                )

                encounter = (
                    map_synthea_encounter(row)
                )

                if (
                    encounter.synthea_provider_id
                    is None
                ):
                    encounters_without_provider += 1
                else:
                    encounters_with_provider += 1

                if encounter.reason is None:
                    encounters_without_reason += 1
                else:
                    encounters_with_reason += 1

                cursor.execute(
                    """
                    SELECT *
                    FROM ingest.promote_synthea_encounter_v1(
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s
                    );
                    """,
                    (
                        promotion_run_id,
                        source_record[
                            "source_record_id"
                        ],
                        payload_sha256,
                        encounter.
                        synthea_encounter_id,
                        encounter.
                        synthea_patient_id,
                        encounter.
                        synthea_provider_id,
                        encounter.start_at,
                        encounter.end_at,
                        encounter.encounter_type,
                        encounter.reason,
                    ),
                )

                result = cursor.fetchone()

                if result is None:
                    raise RuntimeError(
                        "Controlled Encounter "
                        "promotion returned no result"
                    )

                records_seen += 1

                if result["encounter_created"]:
                    records_created += 1
                else:
                    records_existing += 1

                if result["identifier_created"]:
                    identifiers_created += 1

                lineage_edges_created += result[
                    "lineage_edges_created"
                ]

            if (
                records_seen
                != expected_encounter_rows
            ):
                raise RuntimeError(
                    "Canonical Encounter row count "
                    "does not match encounters.csv: "
                    f"expected="
                    f"{expected_encounter_rows}, "
                    f"actual={records_seen}"
                )

            if (
                records_created
                + records_existing
                != records_seen
            ):
                raise RuntimeError(
                    "Encounter promotion counters "
                    "do not reconcile"
                )

            metrics = {
                "mapping_name":
                    ENCOUNTER_MAPPING_NAME,

                "mapping_version":
                    ENCOUNTER_MAPPING_VERSION,

                "source_artifact":
                    ENCOUNTER_SOURCE_PATH,

                "dataset_release_id":
                    str(dataset_release_id),

                "identifiers_created":
                    identifiers_created,

                "lineage_edges_created":
                    lineage_edges_created,

                "encounters_with_provider":
                    encounters_with_provider,

                "encounters_without_provider":
                    encounters_without_provider,

                "encounters_with_reason":
                    encounters_with_reason,

                "encounters_without_reason":
                    encounters_without_reason,

                "patient_dependency_certification_required":
                    True,

                "provider_dependency_certification_required":
                    True,

                "status_mapped":
                    False,

                "reason_source_field":
                    "REASONDESCRIPTION",

                "description_mapped":
                    False,

                "code_mapped":
                    False,

                "organization_mapped":
                    False,

                "payer_mapped":
                    False,

                "financial_fields_mapped":
                    False,

                "raw_identifier_values_logged":
                    False,
            }

            cursor.execute(
                """
                SELECT ingest.complete_canonical_promotion(
                    %s,
                    %s,
                    %s,
                    %s,
                    0,
                    %s,
                    %s
                ) AS canonical_promotion_run_id;
                """,
                (
                    promotion_run_id,
                    records_seen,
                    records_created,
                    records_existing,
                    identifiers_created,
                    Jsonb(metrics),
                ),
            )

            completed = cursor.fetchone()

            if completed is None:
                raise RuntimeError(
                    "Encounter promotion completion "
                    "returned no result"
                )

            completed_event_id = (
                _write_system_event(
                    cursor,
                    event_type=(
                        "canonical."
                        "encounter_promotion_completed"
                    ),
                    outcome="success",
                    message=(
                        "Janus Synthea Encounter "
                        "canonical promotion completed"
                    ),
                    metadata={
                        "canonical_promotion_run_id":
                            str(promotion_run_id),

                        "import_batch_id":
                            str(import_batch_id),

                        "records_seen":
                            records_seen,

                        "records_created":
                            records_created,

                        "records_existing":
                            records_existing,

                        "identifiers_created":
                            identifiers_created,

                        "lineage_edges_created":
                            lineage_edges_created,

                        "encounters_with_provider":
                            encounters_with_provider,

                        "encounters_with_reason":
                            encounters_with_reason,
                    },
                )
            )

        return {
            "canonical_promotion_run_id":
                promotion_run_id,

            "import_batch_id":
                import_batch_id,

            "dataset_release_id":
                dataset_release_id,

            "release_label":
                preflight["release"][
                    "release_label"
                ],

            "mapping_name":
                ENCOUNTER_MAPPING_NAME,

            "mapping_version":
                ENCOUNTER_MAPPING_VERSION,

            "records_seen":
                records_seen,

            "records_created":
                records_created,

            "records_existing":
                records_existing,

            "records_failed":
                0,

            "identifiers_created":
                identifiers_created,

            "lineage_edges_created":
                lineage_edges_created,

            "encounters_with_provider":
                encounters_with_provider,

            "encounters_without_provider":
                encounters_without_provider,

            "encounters_with_reason":
                encounters_with_reason,

            "encounters_without_reason":
                encounters_without_reason,

            "started_system_event_id":
                promotion["system_event_id"],

            "completed_system_event_id":
                completed_event_id,

            "import_correlation_id":
                batch["correlation_id"],
        }

    except Exception as error:
        try:
            _fail_encounter_promotion(
                settings,
                canonical_promotion_run_id=(
                    promotion_run_id
                ),
                import_batch_id=(
                    import_batch_id
                ),
                error=error,
            )
        except PsycopgError as fail_error:
            error.add_note(
                "Canonical fail-closed recording "
                "also failed: "
                f"{type(fail_error).__name__}: "
                f"{fail_error}"
            )

        raise

def _resolve_condition_source_file(
    preflight: dict[str, Any],
) -> dict[str, Any]:
    matches = [
        source_file
        for source_file in preflight[
            "importable_source_files"
        ]
        if source_file["relative_path"]
        == CONDITION_SOURCE_PATH
    ]

    if len(matches) != 1:
        raise RuntimeError(
            "Verified release must contain exactly one "
            f"{CONDITION_SOURCE_PATH} artifact"
        )

    return matches[0]


def _load_condition_source_records(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
    source_file_id: UUID,
) -> dict[int, dict[str, Any]]:
    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                source_record_id,
                row_number,
                source_record_key,
                resource_type,
                record_locator,
                payload_sha256,
                record_status
            FROM ingest.source_record
            WHERE import_batch_id = %s
              AND source_file_id = %s
            ORDER BY row_number;
            """,
            (
                import_batch_id,
                source_file_id,
            ),
        )

        rows = cursor.fetchall()

    result: dict[int, dict[str, Any]] = {}

    for row in rows:
        row_number = row["row_number"]

        if row_number is None:
            raise RuntimeError(
                "Condition source record is missing "
                "its row number"
            )

        if row_number in result:
            raise RuntimeError(
                "Duplicate Condition source row "
                f"number: {row_number}"
            )

        result[row_number] = row

    return result


def _verified_condition_payload_sha256(
    *,
    row: dict[str, str | None],
    source_record: dict[str, Any],
    row_number: int,
) -> str:
    if (
        source_record["record_status"]
        != "accepted"
    ):
        raise RuntimeError(
            "Condition source record is not "
            "accepted: "
            f"row={row_number}, "
            f"status="
            f"{source_record['record_status']}"
        )

    if (
        source_record["resource_type"]
        != "conditions"
    ):
        raise RuntimeError(
            "Condition governed source record has "
            "unexpected resource type: "
            f"row={row_number}, "
            f"resource_type="
            f"{source_record['resource_type']}"
        )

    payload = _canonical_row_payload(row)

    payload_sha256 = hashlib.sha256(
        payload
    ).hexdigest()

    if (
        payload_sha256
        != source_record["payload_sha256"]
    ):
        raise RuntimeError(
            "Physical Condition source row does not "
            "match imported payload hash: "
            f"row={row_number}"
        )

    return payload_sha256


def _begin_condition_promotion(
    settings: CanonicalSettings,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    service_version = _service_version()
    git_commit_sha = _git_commit_sha()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.begin_canonical_promotion(
                %s,
                %s,
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                import_batch_id,
                CONDITION_MAPPING_NAME,
                CONDITION_MAPPING_VERSION,
                service_version,
                git_commit_sha,
            ),
        )

        promotion = cursor.fetchone()

        if promotion is None:
            raise RuntimeError(
                "Condition promotion start returned "
                "no result"
            )

        promotion_run_id = promotion[
            "canonical_promotion_run_id"
        ]

        event_id = _write_system_event(
            cursor,
            event_type=(
                "canonical."
                "condition_promotion_started"
            ),
            outcome="success",
            message=(
                "Janus Synthea Condition canonical "
                "promotion started"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name":
                    CONDITION_MAPPING_NAME,
                "mapping_version":
                    CONDITION_MAPPING_VERSION,
                "service_version":
                    service_version,
                "git_commit_sha":
                    git_commit_sha,
            },
        )

    return {
        "canonical_promotion_run_id":
            promotion_run_id,
        "service_version":
            service_version,
        "git_commit_sha":
            git_commit_sha,
        "system_event_id":
            event_id,
    }


def _fail_condition_promotion(
    settings: CanonicalSettings,
    *,
    canonical_promotion_run_id: UUID,
    import_batch_id: UUID,
    error: Exception,
) -> None:
    error_summary = {
        "error_type": type(error).__name__,
        "message": str(error)[:2000],
    }

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT ingest.fail_canonical_promotion(
                %s,
                %s,
                %s
            ) AS canonical_promotion_run_id;
            """,
            (
                canonical_promotion_run_id,
                Jsonb(error_summary),
                Jsonb(
                    {
                        "mapping_name":
                            CONDITION_MAPPING_NAME,
                        "mapping_version":
                            CONDITION_MAPPING_VERSION,
                    }
                ),
            ),
        )

        _write_system_event(
            cursor,
            event_type=(
                "canonical."
                "condition_promotion_failed"
            ),
            outcome="failure",
            severity="error",
            message=(
                "Janus Synthea Condition canonical "
                "promotion failed"
            ),
            metadata={
                "canonical_promotion_run_id": str(
                    canonical_promotion_run_id
                ),
                "import_batch_id": str(
                    import_batch_id
                ),
                "mapping_name":
                    CONDITION_MAPPING_NAME,
                "mapping_version":
                    CONDITION_MAPPING_VERSION,
                "error_type":
                    error_summary["error_type"],
            },
        )


def promote_conditions(
    settings: CanonicalSettings,
    descriptor: GovernedDatasetDescriptor,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    # Re-verify the governed release before consuming the
    # physical conditions.csv artifact.
    preflight = preflight_release(
        settings,
        descriptor,
    )

    dataset_release_id = preflight["release"][
        "dataset_release_id"
    ]

    batch = _resolve_import_batch(
        settings,
        import_batch_id=import_batch_id,
        dataset_release_id=dataset_release_id,
    )

    condition_source_file = (
        _resolve_condition_source_file(
            preflight
        )
    )

    expected_condition_rows = (
        condition_source_file["row_count"]
    )

    if expected_condition_rows is None:
        raise RuntimeError(
            "Registered conditions.csv row count "
            "is missing"
        )

    source_records = (
        _load_condition_source_records(
            settings,
            import_batch_id=import_batch_id,
            source_file_id=(
                condition_source_file[
                    "source_file_id"
                ]
            ),
        )
    )

    if (
        len(source_records)
        != expected_condition_rows
    ):
        raise RuntimeError(
            "Condition source-record count does not "
            "match verified conditions.csv row count: "
            f"source_records={len(source_records)}, "
            f"verified_rows={expected_condition_rows}"
        )

    promotion = _begin_condition_promotion(
        settings,
        import_batch_id=import_batch_id,
    )

    promotion_run_id = promotion[
        "canonical_promotion_run_id"
    ]

    records_seen = 0
    records_created = 0
    records_existing = 0

    lineage_edges_created = 0

    conditions_with_resolved_date = 0
    conditions_without_resolved_date = 0

    condition_file_path = (
        preflight["raw_directory"]
        / CONDITION_SOURCE_PATH
    )

    try:
        with (
            open_connection(settings) as conn,
            conn.cursor() as cursor,
            condition_file_path.open(
                "r",
                encoding="utf-8-sig",
                newline="",
            ) as handle,
        ):
            _set_environment(cursor, settings)

            reader = csv.DictReader(handle)

            if reader.fieldnames is None:
                raise RuntimeError(
                    "conditions.csv has no header"
                )

            for row_number, row in enumerate(
                reader,
                start=1,
            ):
                source_record = (
                    source_records.get(
                        row_number
                    )
                )

                if source_record is None:
                    raise RuntimeError(
                        "Verified conditions.csv row "
                        "has no matching governed "
                        "source record: "
                        f"row={row_number}"
                    )

                payload_sha256 = (
                    _verified_condition_payload_sha256(
                        row=row,
                        source_record=source_record,
                        row_number=row_number,
                    )
                )

                condition = (
                    map_synthea_condition(row)
                )

                cursor.execute(
                    """
                    SELECT *
                    FROM ingest.promote_synthea_condition_v1(
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s,
                        %s
                    );
                    """,
                    (
                        promotion_run_id,
                        source_record[
                            "source_record_id"
                        ],
                        payload_sha256,
                        condition.
                        synthea_patient_id,
                        condition.
                        synthea_encounter_id,
                        condition.onset_date,
                        condition.resolved_date,
                        condition.code_system,
                        condition.code,
                        condition.display,
                    ),
                )

                result = cursor.fetchone()

                if result is None:
                    raise RuntimeError(
                        "Controlled Condition "
                        "promotion returned no result"
                    )

                records_seen += 1

                if result["condition_created"]:
                    records_created += 1
                else:
                    records_existing += 1

                lineage_edges_created += result[
                    "lineage_edges_created"
                ]

                if (
                    condition.resolved_date
                    is None
                ):
                    conditions_without_resolved_date += 1
                else:
                    conditions_with_resolved_date += 1

            if (
                records_seen
                != expected_condition_rows
            ):
                raise RuntimeError(
                    "Canonical Condition row count "
                    "does not match conditions.csv: "
                    f"expected="
                    f"{expected_condition_rows}, "
                    f"actual={records_seen}"
                )

            if (
                records_created
                + records_existing
                != records_seen
            ):
                raise RuntimeError(
                    "Condition promotion counters "
                    "do not reconcile"
                )

            if (
                conditions_with_resolved_date
                + conditions_without_resolved_date
                != records_seen
            ):
                raise RuntimeError(
                    "Condition resolution-date counters "
                    "do not reconcile"
                )

            metrics = {
                "mapping_name":
                    CONDITION_MAPPING_NAME,

                "mapping_version":
                    CONDITION_MAPPING_VERSION,

                "source_artifact":
                    CONDITION_SOURCE_PATH,

                "dataset_release_id":
                    str(dataset_release_id),

                "lineage_edges_created":
                    lineage_edges_created,

                "conditions_with_resolved_date":
                    conditions_with_resolved_date,

                "conditions_without_resolved_date":
                    conditions_without_resolved_date,

                "patient_dependency_certification_required":
                    True,

                "encounter_dependency_certification_required":
                    True,

                "patient_encounter_match_required":
                    True,

                "clinical_status_mapped":
                    False,

                "external_condition_identifier":
                    False,

                "source_identity":
                    "governed_source_record_id",

                "raw_identifier_values_logged":
                    False,
            }

            cursor.execute(
                """
                SELECT ingest.complete_canonical_promotion(
                    %s,
                    %s,
                    %s,
                    %s,
                    0,
                    0,
                    %s
                ) AS canonical_promotion_run_id;
                """,
                (
                    promotion_run_id,
                    records_seen,
                    records_created,
                    records_existing,
                    Jsonb(metrics),
                ),
            )

            completed = cursor.fetchone()

            if completed is None:
                raise RuntimeError(
                    "Condition promotion completion "
                    "returned no result"
                )

            completed_event_id = (
                _write_system_event(
                    cursor,
                    event_type=(
                        "canonical."
                        "condition_promotion_completed"
                    ),
                    outcome="success",
                    message=(
                        "Janus Synthea Condition "
                        "canonical promotion completed"
                    ),
                    metadata={
                        "canonical_promotion_run_id":
                            str(promotion_run_id),

                        "import_batch_id":
                            str(import_batch_id),

                        "records_seen":
                            records_seen,

                        "records_created":
                            records_created,

                        "records_existing":
                            records_existing,

                        "lineage_edges_created":
                            lineage_edges_created,

                        "conditions_with_resolved_date":
                            conditions_with_resolved_date,

                        "conditions_without_resolved_date":
                            conditions_without_resolved_date,
                    },
                )
            )

        return {
            "canonical_promotion_run_id":
                promotion_run_id,

            "import_batch_id":
                import_batch_id,

            "dataset_release_id":
                dataset_release_id,

            "release_label":
                preflight["release"][
                    "release_label"
                ],

            "mapping_name":
                CONDITION_MAPPING_NAME,

            "mapping_version":
                CONDITION_MAPPING_VERSION,

            "records_seen":
                records_seen,

            "records_created":
                records_created,

            "records_existing":
                records_existing,

            "records_failed":
                0,

            "lineage_edges_created":
                lineage_edges_created,

            "conditions_with_resolved_date":
                conditions_with_resolved_date,

            "conditions_without_resolved_date":
                conditions_without_resolved_date,

            "started_system_event_id":
                promotion["system_event_id"],

            "completed_system_event_id":
                completed_event_id,

            "import_correlation_id":
                batch["correlation_id"],
        }

    except Exception as error:
        try:
            _fail_condition_promotion(
                settings,
                canonical_promotion_run_id=(
                    promotion_run_id
                ),
                import_batch_id=(
                    import_batch_id
                ),
                error=error,
            )
        except PsycopgError as fail_error:
            error.add_note(
                "Canonical fail-closed recording "
                "also failed: "
                f"{type(fail_error).__name__}: "
                f"{fail_error}"
            )

        raise