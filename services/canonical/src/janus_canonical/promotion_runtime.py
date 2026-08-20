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

from janus_canonical.config import (
    REPO_ROOT,
    CanonicalSettings,
)
from janus_canonical.db import (
    _set_environment,
    open_connection,
)
from janus_canonical.patient_mapping import (
    MAPPING_NAME,
    MAPPING_VERSION,
    PATIENT_SOURCE_PATH,
    map_synthea_patient,
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