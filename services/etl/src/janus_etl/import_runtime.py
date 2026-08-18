import csv
import hashlib
import json
import subprocess
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any
from uuid import UUID

from psycopg.types.json import Jsonb

from janus_etl.config import (
    REPO_ROOT,
    DatabaseSettings,
    Settings,
)
from janus_etl.dataset_descriptor import GovernedDatasetDescriptor
from janus_etl.dataset_registry import (
    count_csv_rows,
    load_and_verify_manifest,
)
from janus_etl.db import open_connection


def _set_environment(
    cursor,
    settings: DatabaseSettings,
) -> None:
    cursor.execute(
        """
        SELECT set_config(
            'janus.environment',
            %s,
            false
        );
        """,
        (settings.janus_env,),
    )


def _etl_version() -> str:
    try:
        return version("janus-etl")
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
    component: str,
    message: str,
    metadata: dict[str, Any],
    severity: str = "info",
) -> UUID:
    event = {
        "event_type": event_type,
        "severity": severity,
        "outcome": outcome,
        "component": component,
        "message": message,
        "metadata": metadata,
    }

    cursor.execute(
        """
        SELECT ops.write_system_event(%s::jsonb)
        AS system_event_id;
        """,
        (Jsonb(event),),
    )

    return cursor.fetchone()["system_event_id"]


def _resolve_registered_release(
    settings: DatabaseSettings,
    descriptor: GovernedDatasetDescriptor,
    manifest_digest: str,
) -> dict[str, Any]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                dr.dataset_release_id,
                dr.release_label,
                dr.manifest_sha256,
                d.dataset_id,
                d.name AS dataset_name,
                ss.source_system_id,
                ss.name AS source_system_name
            FROM ingest.dataset_release dr
            JOIN ingest.dataset d
              ON d.dataset_id = dr.dataset_id
            JOIN ingest.source_system ss
              ON ss.source_system_id = d.source_system_id
            WHERE ss.name = %s
              AND d.name = %s
              AND dr.release_label = %s;
            """,
            (
                descriptor.source_system.name,
                descriptor.dataset.name,
                descriptor.release.release_label,
            ),
        )

        release = cursor.fetchone()

        if release is None:
            raise ValueError(
                "Dataset release is not registered in Janus: "
                f"{descriptor.release.release_label}"
            )

        if release["manifest_sha256"] != manifest_digest:
            raise ValueError(
                "Registered dataset release manifest SHA-256 does not "
                "match the verified raw dataset manifest"
            )

        return release


def _load_registered_source_files(
    settings: DatabaseSettings,
    dataset_release_id: UUID,
) -> list[dict[str, Any]]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                source_file_id,
                relative_path,
                media_type,
                size_bytes,
                row_count,
                sha256
            FROM ingest.source_file
            WHERE dataset_release_id = %s
            ORDER BY relative_path;
            """,
            (dataset_release_id,),
        )

        return list(cursor.fetchall())


def preflight_release(
    settings: DatabaseSettings,
    descriptor: GovernedDatasetDescriptor,
) -> dict[str, Any]:
    raw_directory = descriptor.resolve_raw_directory()

    manifest, manifest_digest = load_and_verify_manifest(
        raw_directory
    )

    release = _resolve_registered_release(
        settings,
        descriptor,
        manifest_digest,
    )

    registered_files = _load_registered_source_files(
        settings,
        release["dataset_release_id"],
    )

    manifest_files = {
        record["path"]: record
        for record in manifest["files"]
    }

    registered_paths = {
        record["relative_path"]
        for record in registered_files
    }

    manifest_paths = set(manifest_files)

    if registered_paths != manifest_paths:
        missing_from_db = sorted(
            manifest_paths - registered_paths
        )
        missing_from_manifest = sorted(
            registered_paths - manifest_paths
        )

        raise ValueError(
            "Registered source-file set does not match the "
            "verified manifest. "
            f"missing_from_db={missing_from_db}, "
            f"missing_from_manifest={missing_from_manifest}"
        )

    expected_rows = 0
    importable_source_files: list[dict[str, Any]] = []
    verified_non_tabular_files: list[dict[str, Any]] = []

    for source_file in registered_files:
        relative_path = source_file["relative_path"]
        file_path = raw_directory / relative_path
        manifest_file = manifest_files[relative_path]

        # Every governed artifact must match the approved
        # manifest, regardless of whether the current ETL
        # runtime imports it as row-oriented data.
        if source_file["sha256"] != manifest_file["sha256"]:
            raise ValueError(
                f"Registered SHA-256 mismatch for {relative_path}"
            )

        if (
            source_file["size_bytes"]
            != manifest_file["size_bytes"]
        ):
            raise ValueError(
                f"Registered size mismatch for {relative_path}"
            )

        if file_path.suffix.lower() == ".csv":
            current_row_count = count_csv_rows(file_path)

            if source_file["row_count"] != current_row_count:
                raise ValueError(
                    "Registered CSV row count differs from the "
                    f"physical file: {relative_path}: "
                    f"database={source_file['row_count']}, "
                    f"physical={current_row_count}"
                )

            expected_rows += current_row_count or 0
            importable_source_files.append(source_file)

        else:
            # Non-tabular artifacts remain part of the governed,
            # reproducible release and have already passed
            # manifest/hash/size verification. They are not
            # converted into fake row-oriented source records.
            verified_non_tabular_files.append(source_file)

    return {
        "raw_directory": raw_directory,
        "release": release,
        "source_files": registered_files,
        "importable_source_files": importable_source_files,
        "verified_non_tabular_files": verified_non_tabular_files,
        "manifest_sha256": manifest_digest,
        "expected_rows": expected_rows,
        "verified_artifact_count": len(registered_files),
        "importable_file_count": len(importable_source_files),
        "non_tabular_file_count": len(
            verified_non_tabular_files
        ),
    }


def create_import_batch(
    settings: Settings,
    dataset_release_id: UUID,
) -> dict[str, Any]:
    etl_version = _etl_version()
    git_commit_sha = _git_commit_sha()

    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        # Serialize batch creation for one release.
        cursor.execute(
            """
            SELECT pg_advisory_xact_lock(
                hashtextextended(%s, 0)
            );
            """,
            (str(dataset_release_id),),
        )

        cursor.execute(
            """
            SELECT import_batch_id
            FROM ingest.import_batch
            WHERE dataset_release_id = %s
              AND status IN ('pending', 'running')
            ORDER BY created_at DESC
            LIMIT 1;
            """,
            (dataset_release_id,),
        )

        active_batch = cursor.fetchone()

        if active_batch is not None:
            raise RuntimeError(
                "An active import batch already exists for "
                "this release: "
                f"{active_batch['import_batch_id']}"
            )

        cursor.execute(
            """
            INSERT INTO ingest.import_batch (
                dataset_release_id,
                status,
                environment,
                etl_name,
                etl_version,
                mapping_version,
                git_commit_sha,
                initiated_by,
                started_at
            )
            VALUES (
                %s,
                'running',
                %s,
                %s,
                %s,
                NULL,
                %s,
                current_user,
                clock_timestamp()
            )
            RETURNING
                import_batch_id,
                dataset_release_id,
                status,
                environment,
                etl_name,
                etl_version,
                mapping_version,
                git_commit_sha,
                initiated_by,
                correlation_id,
                started_at;
            """,
            (
                dataset_release_id,
                settings.janus_env,
                settings.application_name,
                etl_version,
                git_commit_sha,
            ),
        )

        batch = cursor.fetchone()

        event_id = _write_system_event(
            cursor,
            event_type="dataset.import_started",
            outcome="success",
            component="import_runtime",
            message="Janus governed dataset import started",
            metadata={
                "import_batch_id": str(
                    batch["import_batch_id"]
                ),
                "dataset_release_id": str(
                    dataset_release_id
                ),
                "correlation_id": str(
                    batch["correlation_id"]
                ),
                "etl_version": etl_version,
                "git_commit_sha": git_commit_sha,
            },
        )

        return {
            **batch,
            "system_event_id": event_id,
        }


def _canonical_row_payload(
    row: dict[str | None, str | list[str] | None],
) -> bytes:
    if None in row:
        raise ValueError(
            "CSV row contains more values than the "
            "declared header"
        )

    payload = json.dumps(
        row,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )

    return payload.encode("utf-8")

def _import_csv_file(
    settings: Settings,
    *,
    import_batch_id: UUID,
    dataset_release_id: UUID,
    raw_directory: Path,
    source_file: dict[str, Any],
    insert_batch_size: int = 1000,
) -> int:
    relative_path = source_file["relative_path"]
    file_path = raw_directory / relative_path
    expected_row_count = source_file["row_count"]

    records: list[tuple[Any, ...]] = []
    imported_count = 0

    # Raw resource type. This is NOT yet a canonical
    # clinical resource classification.
    resource_type = Path(relative_path).stem

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
        file_path.open(
            "r",
            encoding="utf-8-sig",
            newline="",
        ) as handle,
    ):
        _set_environment(cursor, settings)

        reader = csv.DictReader(handle)

        if reader.fieldnames is None:
            if expected_row_count not in (None, 0):
                raise ValueError(
                    f"CSV header missing from {relative_path}"
                )
            return 0

        for row_number, row in enumerate(
            reader,
            start=1,
        ):
            payload = _canonical_row_payload(row)

            payload_sha256 = hashlib.sha256(
                payload
            ).hexdigest()

            source_record_key = (
                f"row:{row_number}:"
                f"{payload_sha256[:16]}"
            )

            record_locator = (
                f"{relative_path}#row={row_number}"
            )

            raw_storage_uri = None

            records.append(
                (
                    import_batch_id,
                    source_file["source_file_id"],
                    source_record_key,
                    resource_type,
                    row_number,
                    record_locator,
                    raw_storage_uri,
                    payload_sha256,
                    "accepted",
                )
            )

            if len(records) >= insert_batch_size:
                cursor.executemany(
                    """
                    INSERT INTO ingest.source_record (
                        import_batch_id,
                        source_file_id,
                        source_record_key,
                        resource_type,
                        row_number,
                        record_locator,
                        raw_storage_uri,
                        payload_sha256,
                        record_status
                    )
                    VALUES (
                        %s, %s, %s, %s, %s,
                        %s, %s, %s, %s
                    );
                    """,
                    records,
                )

                imported_count += len(records)
                records.clear()

        if records:
            cursor.executemany(
                """
                INSERT INTO ingest.source_record (
                    import_batch_id,
                    source_file_id,
                    source_record_key,
                    resource_type,
                    row_number,
                    record_locator,
                    raw_storage_uri,
                    payload_sha256,
                    record_status
                )
                VALUES (
                    %s, %s, %s, %s, %s,
                    %s, %s, %s, %s
                );
                """,
                records,
            )

            imported_count += len(records)

        if imported_count != expected_row_count:
            raise ValueError(
                "Imported CSV row count does not match "
                "the registered row count for "
                f"{relative_path}: "
                f"expected={expected_row_count}, "
                f"actual={imported_count}"
            )

        cursor.execute(
            """
            UPDATE ingest.import_batch
            SET
                records_seen = records_seen + %s,
                records_accepted =
                    records_accepted + %s
            WHERE import_batch_id = %s
              AND status = 'running';
            """,
            (
                imported_count,
                imported_count,
                import_batch_id,
            ),
        )

        if cursor.rowcount != 1:
            raise RuntimeError(
                "Import batch is no longer in running "
                f"state: {import_batch_id}"
            )

    return imported_count


def _complete_import_batch(
    settings: Settings,
    *,
    import_batch_id: UUID,
    expected_rows: int,
) -> dict[str, Any]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            UPDATE ingest.import_batch
            SET
                status = 'completed',
                completed_at = clock_timestamp()
            WHERE import_batch_id = %s
              AND status = 'running'
              AND records_seen = %s
              AND records_accepted = %s
              AND records_rejected = 0
            RETURNING
                import_batch_id,
                status,
                correlation_id,
                started_at,
                completed_at,
                records_seen,
                records_accepted,
                records_rejected;
            """,
            (
                import_batch_id,
                expected_rows,
                expected_rows,
            ),
        )

        batch = cursor.fetchone()

        if batch is None:
            raise RuntimeError(
                "Import batch counters do not match the "
                "preflight row-count contract; refusing "
                "to mark completed"
            )

        event_id = _write_system_event(
            cursor,
            event_type="dataset.import_completed",
            outcome="success",
            component="import_runtime",
            message="Janus governed dataset import completed",
            metadata={
                "import_batch_id": str(
                    import_batch_id
                ),
                "correlation_id": str(
                    batch["correlation_id"]
                ),
                "records_seen":
                    batch["records_seen"],
                "records_accepted":
                    batch["records_accepted"],
                "records_rejected":
                    batch["records_rejected"],
            },
        )

        return {
            **batch,
            "system_event_id": event_id,
        }


def _fail_import_batch(
    settings: Settings,
    *,
    import_batch_id: UUID,
    error: Exception,
) -> None:
    error_summary = {
        "error_type": type(error).__name__,
        "message": str(error)[:2000],
    }

    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            UPDATE ingest.import_batch
            SET
                status = 'failed',
                completed_at = clock_timestamp(),
                error_summary = %s
            WHERE import_batch_id = %s
              AND status = 'running'
            RETURNING correlation_id;
            """,
            (
                Jsonb(error_summary),
                import_batch_id,
            ),
        )

        batch = cursor.fetchone()

        if batch is None:
            return

        _write_system_event(
            cursor,
            event_type="dataset.import_failed",
            outcome="failure",
            component="import_runtime",
            severity="error",
            message="Janus governed dataset import failed",
            metadata={
                "import_batch_id": str(
                    import_batch_id
                ),
                "correlation_id": str(
                    batch["correlation_id"]
                ),
                **error_summary,
            },
        )


def import_release(
    settings: Settings,
    descriptor: GovernedDatasetDescriptor,
) -> dict[str, Any]:
    # Preflight happens BEFORE batch creation.
    # A mutated or inconsistent dataset therefore never
    # becomes an import execution.
    preflight = preflight_release(
        settings,
        descriptor,
    )

    # This INSERT exercises the V008 governance trigger.
    batch = create_import_batch(
        settings,
        preflight["release"]["dataset_release_id"],
    )

    import_batch_id = batch["import_batch_id"]

    try:
        imported_files = 0

        for source_file in preflight["importable_source_files"]:
            _import_csv_file(
                settings,
                import_batch_id=import_batch_id,
                dataset_release_id=(
                    preflight["release"][
                        "dataset_release_id"
                    ]
                ),
                raw_directory=preflight[
                    "raw_directory"
                ],
                source_file=source_file,
            )

            imported_files += 1

        completed = _complete_import_batch(
            settings,
            import_batch_id=import_batch_id,
            expected_rows=preflight[
                "expected_rows"
            ],
        )

        return {
            "import_batch_id": import_batch_id,
            "dataset_release_id": (
                preflight["release"][
                    "dataset_release_id"
                ]
            ),
            "release_label": (
                preflight["release"]["release_label"]
            ),
            "file_count": imported_files,
            "verified_artifact_count": preflight[
                "verified_artifact_count"
            ],
            "non_tabular_file_count": preflight[
                "non_tabular_file_count"
            ],
            "manifest_sha256": (
                preflight["manifest_sha256"]
            ),
            **completed,
        }

    except Exception as error:
        _fail_import_batch(
            settings,
            import_batch_id=import_batch_id,
            error=error,
        )
        raise