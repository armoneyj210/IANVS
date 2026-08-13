import argparse
from collections.abc import Sequence
from pathlib import Path

from janus_etl.config import get_settings
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

    parser.error(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    main()
