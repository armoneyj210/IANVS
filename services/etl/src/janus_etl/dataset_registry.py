import csv
import json
import mimetypes
from pathlib import Path
from typing import Any

from psycopg.types.json import Jsonb

from janus_etl.config import Settings
from janus_etl.dataset_descriptor import (
    GovernedDatasetDescriptor,
)
from janus_etl.db import open_connection
from janus_etl.manifest import (
    MANIFEST_FILENAME,
    build_manifest,
    manifest_sha256,
)


def count_csv_rows(path: Path) -> int | None:
    if path.suffix.lower() != ".csv":
        return None

    with path.open(
        "r",
        encoding="utf-8-sig",
        newline="",
    ) as handle:
        reader = csv.reader(handle)

        try:
            next(reader)
        except StopIteration:
            return 0

        return sum(1 for _ in reader)


def load_and_verify_manifest(
    raw_directory: Path,
) -> tuple[dict[str, Any], str]:
    manifest_path = raw_directory / MANIFEST_FILENAME

    if not manifest_path.exists():
        raise FileNotFoundError(f"Dataset manifest not found: {manifest_path}")

    recorded_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    current_manifest = build_manifest(raw_directory)

    if recorded_manifest != current_manifest:
        raise ValueError("Raw dataset contents no longer match janus-manifest.json")

    return (
        recorded_manifest,
        manifest_sha256(recorded_manifest),
    )


def register_dataset(
    settings: Settings,
    descriptor: GovernedDatasetDescriptor,
) -> dict[str, Any]:
    raw_directory = descriptor.resolve_raw_directory()

    manifest, manifest_digest = load_and_verify_manifest(raw_directory)

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
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

        # -----------------------------------------------------
        # Source System
        # -----------------------------------------------------

        cursor.execute(
            """
            INSERT INTO ingest.source_system (
                name,
                source_type,
                description,
                base_uri
            )
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (name)
            DO UPDATE SET
                description = EXCLUDED.description,
                base_uri = EXCLUDED.base_uri,
                updated_at = now()
            RETURNING source_system_id;
            """,
            (
                descriptor.source_system.name,
                descriptor.source_system.source_type,
                descriptor.source_system.description,
                descriptor.source_system.base_uri,
            ),
        )

        source_system = cursor.fetchone()
        source_system_id = source_system["source_system_id"]

        # -----------------------------------------------------
        # Dataset
        # -----------------------------------------------------

        cursor.execute(
            """
            SELECT *
            FROM ingest.dataset
            WHERE source_system_id = %s
              AND name = %s;
            """,
            (
                source_system_id,
                descriptor.dataset.name,
            ),
        )

        existing_dataset = cursor.fetchone()

        if existing_dataset is None:
            cursor.execute(
                """
                INSERT INTO ingest.dataset (
                    source_system_id,
                    name,
                    description,
                    homepage_uri,
                    license_name,
                    license_uri,
                    usage_notes,
                    data_classification,
                    contains_phi,
                    review_status
                )
                VALUES (
                    %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s
                )
                RETURNING dataset_id;
                """,
                (
                    source_system_id,
                    descriptor.dataset.name,
                    descriptor.dataset.description,
                    descriptor.dataset.homepage_uri,
                    descriptor.dataset.license_name,
                    descriptor.dataset.license_uri,
                    descriptor.dataset.usage_notes,
                    descriptor.dataset.data_classification,
                    descriptor.dataset.contains_phi,
                    descriptor.dataset.review_status,
                ),
            )

            dataset_id = cursor.fetchone()["dataset_id"]

        else:
            dataset_id = existing_dataset["dataset_id"]

            immutable_fields = {
                "license_name": descriptor.dataset.license_name,
                "license_uri": descriptor.dataset.license_uri,
                "data_classification": descriptor.dataset.data_classification,
                "contains_phi": descriptor.dataset.contains_phi,
            }

            for field, expected in immutable_fields.items():
                actual = existing_dataset[field]

                if actual != expected:
                    raise ValueError(
                        "Dataset governance metadata mismatch: "
                        f"{field}: database={actual!r}, "
                        f"descriptor={expected!r}"
                    )

        # -----------------------------------------------------
        # Dataset Release
        # -----------------------------------------------------

        cursor.execute(
            """
            SELECT *
            FROM ingest.dataset_release
            WHERE dataset_id = %s
              AND release_label = %s;
            """,
            (
                dataset_id,
                descriptor.release.release_label,
            ),
        )

        existing_release = cursor.fetchone()

        if existing_release is None:
            cursor.execute(
                """
                INSERT INTO ingest.dataset_release (
                    dataset_id,
                    release_label,
                    source_version,
                    source_uri,
                    manifest_sha256,
                    source_commit_sha,
                    acquisition_method,
                    generated_at,
                    generation_parameters,
                    release_metadata
                )
                VALUES (
                    %s, %s, %s, %s, %s,
                    %s, %s, now(), %s, %s
                )
                RETURNING dataset_release_id;
                """,
                (
                    dataset_id,
                    descriptor.release.release_label,
                    descriptor.release.source_version,
                    descriptor.release.source_uri,
                    manifest_digest,
                    descriptor.release.source_commit_sha,
                    descriptor.release.acquisition_method,
                    Jsonb(descriptor.release.generation_parameters),
                    Jsonb(descriptor.release.release_metadata),
                ),
            )

            dataset_release_id = cursor.fetchone()["dataset_release_id"]

        else:
            dataset_release_id = existing_release["dataset_release_id"]

            if existing_release["manifest_sha256"] != manifest_digest:
                raise ValueError(
                    "Dataset release already exists with a different manifest SHA-256"
                )

            if existing_release["source_version"] != descriptor.release.source_version:
                raise ValueError("Dataset release source version mismatch")

            if (
                existing_release["source_commit_sha"]
                != descriptor.release.source_commit_sha
            ):
                raise ValueError("Dataset release source commit mismatch")

        # -----------------------------------------------------
        # Source Files
        # -----------------------------------------------------

        file_count = 0

        for file_record in manifest["files"]:
            relative_path = file_record["path"]

            file_path = raw_directory / relative_path

            media_type, _ = mimetypes.guess_type(file_path)

            row_count = count_csv_rows(file_path)

            cursor.execute(
                """
                SELECT *
                FROM ingest.source_file
                WHERE dataset_release_id = %s
                  AND relative_path = %s;
                """,
                (
                    dataset_release_id,
                    relative_path,
                ),
            )

            existing_file = cursor.fetchone()

            if existing_file is None:
                cursor.execute(
                    """
                    INSERT INTO ingest.source_file (
                        dataset_release_id,
                        relative_path,
                        media_type,
                        size_bytes,
                        row_count,
                        sha256
                    )
                    VALUES (
                        %s, %s, %s, %s, %s, %s
                    );
                    """,
                    (
                        dataset_release_id,
                        relative_path,
                        media_type,
                        file_record["size_bytes"],
                        row_count,
                        file_record["sha256"],
                    ),
                )

            else:
                if (
                    existing_file["sha256"] != file_record["sha256"]
                    or existing_file["size_bytes"] != file_record["size_bytes"]
                ):
                    raise ValueError(
                        "Registered source file differs from "
                        f"raw artifact: {relative_path}"
                    )

            file_count += 1

        # -----------------------------------------------------
        # Operational event
        # -----------------------------------------------------

        event = {
            "event_type": "dataset.registered",
            "severity": "info",
            "outcome": "success",
            "component": "dataset_registry",
            "message": ("Janus dataset release registration completed"),
            "metadata": {
                "dataset_id": str(dataset_id),
                "dataset_release_id": str(dataset_release_id),
                "release_label": descriptor.release.release_label,
                "manifest_sha256": manifest_digest,
                "file_count": file_count,
                "review_status": descriptor.dataset.review_status,
            },
        }

        cursor.execute(
            """
            SELECT ops.write_system_event(%s::jsonb)
            AS system_event_id;
            """,
            (Jsonb(event),),
        )

        event_result = cursor.fetchone()

        return {
            "source_system_id": source_system_id,
            "dataset_id": dataset_id,
            "dataset_release_id": dataset_release_id,
            "manifest_sha256": manifest_digest,
            "file_count": file_count,
            "system_event_id": event_result["system_event_id"],
        }
