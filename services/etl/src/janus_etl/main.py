import argparse
from collections.abc import Sequence
from pathlib import Path

from janus_etl.config import get_settings
from janus_etl.dataset_descriptor import (
    load_dataset_descriptor,
)
from janus_etl.dataset_registry import register_dataset
from janus_etl.db import health_check
from janus_etl.manifest import write_manifest


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="janus-etl",
        description="Janus governed ETL service",
    )

    subparsers = parser.add_subparsers(
        dest="command",
    )

    subparsers.add_parser(
        "health",
        help="Verify the Janus ETL database connection",
    )

    manifest_parser = subparsers.add_parser(
        "manifest",
        help="Generate a SHA-256 manifest for a raw dataset",
    )

    manifest_parser.add_argument(
        "directory",
        type=Path,
        help="Raw dataset directory",
    )

    register_parser = subparsers.add_parser(
        "register-dataset",
        help="Register a governed dataset release",
    )

    register_parser.add_argument(
        "descriptor",
        type=Path,
        help="Path to Janus dataset descriptor JSON",
    )

    return parser


def run_health() -> None:
    settings = get_settings()

    print("JANUS ETL")
    print("---------")
    print(f"Environment: {settings.janus_env}")
    print(f"Data root:   {settings.resolved_data_root}")
    print()

    result = health_check(settings)

    print("Database connection successful.")
    print(f"Database:     {result['database']}")
    print(f"Principal:    {result['db_principal']}")
    print(f"Application:  {result['application_name']}")
    print(f"System event: {result['system_event_id']}")


def run_manifest(directory: Path) -> None:
    manifest_path, manifest_digest = write_manifest(directory)

    print("JANUS DATASET MANIFEST")
    print("----------------------")
    print(f"Dataset:         {directory.resolve()}")
    print(f"Manifest:        {manifest_path}")
    print(f"Manifest SHA256: {manifest_digest}")


def run_register_dataset(
    descriptor_path: Path,
) -> None:
    settings = get_settings()

    descriptor = load_dataset_descriptor(descriptor_path)

    result = register_dataset(
        settings,
        descriptor,
    )

    print("JANUS DATASET REGISTRATION")
    print("--------------------------")
    print(f"Dataset ID:         {result['dataset_id']}")
    print(f"Dataset Release ID: {result['dataset_release_id']}")
    print(f"Files Registered:   {result['file_count']}")
    print(f"Manifest SHA256:    {result['manifest_sha256']}")
    print(f"System Event:       {result['system_event_id']}")


def main(
    argv: Sequence[str] | None = None,
) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)

    # Preserve existing behavior:
    # janus-etl by itself performs the health check.
    if args.command in (None, "health"):
        run_health()
        return

    if args.command == "manifest":
        run_manifest(args.directory)
        return

    if args.command == "register-dataset":
        run_register_dataset(args.descriptor)
        return

    parser.error(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    main()
