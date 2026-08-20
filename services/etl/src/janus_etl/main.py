import argparse
from collections.abc import Sequence
from pathlib import Path
from uuid import UUID

from janus_etl.config import (
    get_quality_settings,
    get_settings,
)
from janus_etl.dataset_descriptor import (
    load_dataset_descriptor,
)
from janus_etl.dataset_registry import register_dataset
from janus_etl.db import health_check
from janus_etl.import_runtime import import_release
from janus_etl.manifest import write_manifest
from janus_etl.postcanonical_quality_runtime import (
    postcanonical_lineage_quality_run,
)
from janus_etl.quality_runtime import quality_run


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

    import_parser = subparsers.add_parser(
        "import-release",
        help=(
            "Import a governed registered dataset "
            "release into the ingest layer"
        ),
    )
    quality_parser = subparsers.add_parser(
        "quality-run",
        help=(
            "Execute the governed pre-canonical "
            "data-quality ruleset"
        ),
    )

    quality_parser.add_argument(
        "descriptor",
        type=Path,
        help="Path to Janus dataset descriptor JSON",
    )

    quality_parser.add_argument(
        "--batch",
        required=True,
        type=UUID,
        help="Completed governed import batch UUID",
    )

    lineage_quality_parser = (
        subparsers.add_parser(
            "lineage-quality-run",
            help=(
                "Execute JANUS-DQ-006 against a "
                "completed canonical promotion"
            ),
        )
    )

    lineage_quality_parser.add_argument(
        "--promotion",
        required=True,
        type=UUID,
        help=(
            "Completed canonical promotion run UUID"
        ),
    )   

    import_parser.add_argument(
        "descriptor",
        type=Path,
        help="Path to Janus dataset descriptor JSON",
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

def run_import_release(
    descriptor_path: Path,
) -> None:
    settings = get_settings()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    print("JANUS GOVERNED DATASET IMPORT")
    print("-----------------------------")
    print(f"Environment: {settings.janus_env}")
    print(
        f"Release:     "
        f"{descriptor.release.release_label}"
    )
    print()

    result = import_release(
        settings,
        descriptor,
    )

    print("Import completed.")
    print(
        f"Import Batch ID:  "
        f"{result['import_batch_id']}"
    )
    print(
        f"Dataset Release:  "
        f"{result['dataset_release_id']}"
    )
    print(
        f"Files Imported:   "
        f"{result['file_count']}"
    )
    print(
        f"Records Seen:     "
        f"{result['records_seen']}"
    )
    print(
        f"Records Accepted: "
        f"{result['records_accepted']}"
    )
    print(
        f"Records Rejected: "
        f"{result['records_rejected']}"
    )
    print(
        f"Manifest SHA256:  "
        f"{result['manifest_sha256']}"
    )
    print(
        f"System Event:     "
        f"{result['system_event_id']}"
    )

def run_quality(
    descriptor_path: Path,
    import_batch_id: UUID,
) -> None:
    settings = get_quality_settings()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    print("JANUS PRE-CANONICAL DATA QUALITY")
    print("--------------------------------")
    print(f"Environment:  {settings.janus_env}")
    print(
        f"Release:      "
        f"{descriptor.release.release_label}"
    )
    print(f"Import Batch: {import_batch_id}")
    print()

    result = quality_run(
        settings,
        descriptor,
        import_batch_id=import_batch_id,
    )

    print("Quality run completed.")
    print(
        f"DQ Run ID:          "
        f"{result['data_quality_run_id']}"
    )
    print(
        f"Ruleset:            "
        f"{result['ruleset_name']} "
        f"v{result['ruleset_version']}"
    )
    print(
        f"Rules Evaluated:    "
        f"{result['rules_evaluated']}"
    )
    print(
        f"Rules Passed:       "
        f"{result['rules_passed']}"
    )
    print(
        f"Rules Warned:       "
        f"{result['rules_warned']}"
    )
    print(
        f"Rules Failed:       "
        f"{result['rules_failed']}"
    )
    print(
        f"Records Evaluated:  "
        f"{result['records_evaluated']}"
    )
    print(
        f"Records Quarantined:"
        f" {result['records_quarantined']}"
    )
    print(
        f"Quality Gate:       "
        f"{result['gate_decision'].upper()}"
    )
    print(
        f"Gate Decision ID:   "
        f"{result['quality_gate_decision_id']}"
    )
    print(
        f"System Event:       "
        f"{result['system_event_id']}"
    )

    print()
    print("Rule Results:")

    for rule in result["rule_results"]:
        print(
            f"  {rule['rule_code']}: "
            f"{rule['outcome'].upper()} "
            f"(evaluated={rule['records_evaluated']}, "
            f"failed={rule['records_failed']})"
        )

    if result["deferred_rules"]:
        print()
        print("Deferred Rules:")

        for rule_code, reason in (
            result["deferred_rules"].items()
        ):
            print(f"  {rule_code}: {reason}")

def run_lineage_quality(
    canonical_promotion_run_id: UUID,
) -> None:
    settings = get_quality_settings()

    print("JANUS POST-CANONICAL LINEAGE QUALITY")
    print("------------------------------------")
    print(f"Environment: {settings.janus_env}")
    print(
        f"Promotion:   "
        f"{canonical_promotion_run_id}"
    )
    print()

    result = postcanonical_lineage_quality_run(
        settings,
        canonical_promotion_run_id=(
            canonical_promotion_run_id
        ),
    )

    print("Post-canonical quality completed.")
    print(
        f"DQ Run ID:       "
        f"{result['data_quality_run_id']}"
    )
    print(
        f"Ruleset:         "
        f"{result['ruleset_name']} "
        f"v{result['ruleset_version']}"
    )
    print(
        f"Rule:            "
        f"{result['rule_code']}"
    )
    print(
        f"Rule Outcome:    "
        f"{result['rule_outcome'].upper()}"
    )
    print(
        f"Records Failed:  "
        f"{result['records_failed']}"
    )
    print(
        f"Quality Gate:    "
        f"{result['gate_decision'].upper()}"
    )
    print(
        f"Gate Decision:   "
        f"{result['quality_gate_decision_id']}"
    )
    print(
        f"System Event:    "
        f"{result['system_event_id']}"
    )

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

    if args.command == "import-release":
        run_import_release(args.descriptor)
        return

    if args.command == "quality-run":
        run_quality(
            args.descriptor,
            args.batch,
        )
        return

    if args.command == "lineage-quality-run":
        run_lineage_quality(
            args.promotion,
        )
        return

    parser.error(f"Unsupported command: {args.command}")


if __name__ == "__main__":
    main()
