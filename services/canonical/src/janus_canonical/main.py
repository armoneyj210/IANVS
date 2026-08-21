import argparse
from collections.abc import Sequence
from pathlib import Path
from uuid import UUID

from janus_etl.dataset_descriptor import (
    load_dataset_descriptor,
)

from janus_canonical.config import get_settings
from janus_canonical.db import health_check
from janus_canonical.promotion_runtime import (
    promote_conditions,
    promote_encounters,
    promote_medications,
    promote_patients,
    promote_providers,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="janus-canonical",
        description=(
            "Janus governed canonical promotion service"
        ),
    )

    subparsers = parser.add_subparsers(
        dest="command"
    )

    subparsers.add_parser(
        "health",
        help=(
            "Verify the Canonical service database "
            "identity"
        ),
    )

    promote_parser = subparsers.add_parser(
        "promote-patients",
        help=(
            "Promote quality-certified Synthea "
            "patients into canonical clinical state"
        ),
    )

    promote_parser.add_argument(
        "descriptor",
        type=Path,
        help=(
            "Path to Janus governed dataset "
            "descriptor JSON"
        ),
    )

    promote_parser.add_argument(
        "--batch",
        required=True,
        type=UUID,
        help="Completed governed import batch UUID",
    )

    provider_parser = subparsers.add_parser(
        "promote-providers",
        help=(
            "Promote quality-certified Synthea "
            "providers into canonical clinical state"
        ),
    )

    provider_parser.add_argument(
        "descriptor",
        type=Path,
        help=(
            "Path to Janus governed dataset "
            "descriptor JSON"
        ),
    )

    provider_parser.add_argument(
        "--batch",
        required=True,
        type=UUID,
        help="Completed governed import batch UUID",
    )

    encounter_parser = subparsers.add_parser(
        "promote-encounters",
        help=(
            "Promote quality-certified Synthea "
            "encounters into canonical clinical state"
        ),
    )

    encounter_parser.add_argument(
        "descriptor",
        type=Path,
        help=(
            "Path to Janus governed dataset "
            "descriptor JSON"
        ),
    )

    encounter_parser.add_argument(
        "--batch",
        required=True,
        type=UUID,
        help="Completed governed import batch UUID",
    )

    condition_parser = subparsers.add_parser(
        "promote-conditions",
        help=(
            "Promote quality-certified Synthea "
            "conditions into canonical clinical state"
        ),
    )

    condition_parser.add_argument(
        "descriptor",
        type=Path,
        help=(
            "Path to Janus governed dataset "
            "descriptor JSON"
        ),
    )

    condition_parser.add_argument(
        "--batch",
        required=True,
        type=UUID,
        help="Completed governed import batch UUID",
    )
    medication_parser = subparsers.add_parser(
        "promote-medications",
        help=(
            "Promote quality-certified Synthea "
            "medications into canonical clinical state"
        ),
    )

    medication_parser.add_argument(
        "descriptor",
        type=Path,
        help=(
            "Path to Janus governed dataset "
            "descriptor JSON"
        ),
    )

    medication_parser.add_argument(
        "--batch",
        required=True,
        type=UUID,
        help="Completed governed import batch UUID",
    )
    return parser




def run_health() -> None:
    settings = get_settings()

    result = health_check(settings)

    print("JANUS CANONICAL")
    print("---------------")
    print("Database connection successful.")
    print(
        f"Environment:  {settings.janus_env}"
    )
    print(
        f"Database:     {result['database']}"
    )
    print(
        f"Principal:    "
        f"{result['db_principal']}"
    )
    print(
        f"Application:  "
        f"{result['application_name']}"
    )
    print(
        f"System Event: "
        f"{result['system_event_id']}"
    )


def run_promote_patients(
    descriptor_path: Path,
    import_batch_id: UUID,
) -> None:
    settings = get_settings()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    print("JANUS CANONICAL PATIENT PROMOTION")
    print("---------------------------------")
    print(
        f"Environment:  {settings.janus_env}"
    )
    print(
        f"Release:      "
        f"{descriptor.release.release_label}"
    )
    print(
        f"Import Batch: {import_batch_id}"
    )
    print()

    result = promote_patients(
        settings,
        descriptor,
        import_batch_id=import_batch_id,
    )

    print("Canonical patient promotion completed.")
    print(
        f"Promotion Run:      "
        f"{result['canonical_promotion_run_id']}"
    )
    print(
        f"Mapping:            "
        f"{result['mapping_name']} "
        f"v{result['mapping_version']}"
    )
    print(
        f"Records Seen:       "
        f"{result['records_seen']}"
    )
    print(
        f"Patients Created:   "
        f"{result['records_created']}"
    )
    print(
        f"Patients Existing:  "
        f"{result['records_existing']}"
    )
    print(
        f"Records Failed:     "
        f"{result['records_failed']}"
    )
    print(
        f"Identifiers Created:"
        f" {result['identifiers_created']}"
    )
    print(
        f"Lineage Edges:      "
        f"{result['lineage_edges_created']}"
    )
    print(
        f"Completed Event:    "
        f"{result['completed_system_event_id']}"
    )

def run_promote_providers(
    descriptor_path: Path,
    import_batch_id: UUID,
) -> None:
    settings = get_settings()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    print("JANUS CANONICAL PROVIDER PROMOTION")
    print("----------------------------------")
    print(
        f"Environment:  {settings.janus_env}"
    )
    print(
        f"Release:      "
        f"{descriptor.release.release_label}"
    )
    print(
        f"Import Batch: {import_batch_id}"
    )
    print()

    result = promote_providers(
        settings,
        descriptor,
        import_batch_id=import_batch_id,
    )

    print("Canonical provider promotion completed.")
    print(
        f"Promotion Run:      "
        f"{result['canonical_promotion_run_id']}"
    )
    print(
        f"Mapping:            "
        f"{result['mapping_name']} "
        f"v{result['mapping_version']}"
    )
    print(
        f"Records Seen:       "
        f"{result['records_seen']}"
    )
    print(
        f"Providers Created:  "
        f"{result['records_created']}"
    )
    print(
        f"Providers Existing: "
        f"{result['records_existing']}"
    )
    print(
        f"Records Failed:     "
        f"{result['records_failed']}"
    )
    print(
        f"With Organization:  "
        f"{result['providers_with_organization']}"
    )
    print(
        f"Organizations Used: "
        f"{result['distinct_organizations_used']}"
    )
    print(
        f"Lineage Edges:      "
        f"{result['lineage_edges_created']}"
    )
    print(
        f"Completed Event:    "
        f"{result['completed_system_event_id']}"
    )

def run_promote_encounters(
    descriptor_path: Path,
    import_batch_id: UUID,
) -> None:
    settings = get_settings()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    print("JANUS CANONICAL ENCOUNTER PROMOTION")
    print("-----------------------------------")
    print(
        f"Environment:  {settings.janus_env}"
    )
    print(
        f"Release:      "
        f"{descriptor.release.release_label}"
    )
    print(
        f"Import Batch: {import_batch_id}"
    )
    print()

    result = promote_encounters(
        settings,
        descriptor,
        import_batch_id=import_batch_id,
    )

    print("Canonical Encounter promotion completed.")
    print(
        f"Promotion Run:       "
        f"{result['canonical_promotion_run_id']}"
    )
    print(
        f"Mapping:             "
        f"{result['mapping_name']} "
        f"v{result['mapping_version']}"
    )
    print(
        f"Records Seen:        "
        f"{result['records_seen']}"
    )
    print(
        f"Encounters Created:  "
        f"{result['records_created']}"
    )
    print(
        f"Encounters Existing: "
        f"{result['records_existing']}"
    )
    print(
        f"Records Failed:      "
        f"{result['records_failed']}"
    )
    print(
        f"Identifiers Created: "
        f"{result['identifiers_created']}"
    )
    print(
        f"With Provider:       "
        f"{result['encounters_with_provider']}"
    )
    print(
        f"Without Provider:    "
        f"{result['encounters_without_provider']}"
    )
    print(
        f"With Reason:         "
        f"{result['encounters_with_reason']}"
    )
    print(
        f"Without Reason:      "
        f"{result['encounters_without_reason']}"
    )
    print(
        f"Lineage Edges:       "
        f"{result['lineage_edges_created']}"
    )
    print(
        f"Completed Event:     "
        f"{result['completed_system_event_id']}"
    )

def run_promote_conditions(
    descriptor_path: Path,
    import_batch_id: UUID,
) -> None:
    settings = get_settings()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    print("JANUS CANONICAL CONDITION PROMOTION")
    print("-----------------------------------")
    print(
        f"Environment:  {settings.janus_env}"
    )
    print(
        f"Release:      "
        f"{descriptor.release.release_label}"
    )
    print(
        f"Import Batch: {import_batch_id}"
    )
    print()

    result = promote_conditions(
        settings,
        descriptor,
        import_batch_id=import_batch_id,
    )

    print("Canonical Condition promotion completed.")
    print(
        f"Promotion Run:        "
        f"{result['canonical_promotion_run_id']}"
    )
    print(
        f"Mapping:              "
        f"{result['mapping_name']} "
        f"v{result['mapping_version']}"
    )
    print(
        f"Records Seen:         "
        f"{result['records_seen']}"
    )
    print(
        f"Conditions Created:   "
        f"{result['records_created']}"
    )
    print(
        f"Conditions Existing:  "
        f"{result['records_existing']}"
    )
    print(
        f"Records Failed:       "
        f"{result['records_failed']}"
    )
    print(
        f"With Resolved Date:   "
        f"{result['conditions_with_resolved_date']}"
    )
    print(
        f"Without Resolved Date:"
        f" {result['conditions_without_resolved_date']}"
    )
    print(
        f"Lineage Edges:        "
        f"{result['lineage_edges_created']}"
    )
    print(
        f"Completed Event:      "
        f"{result['completed_system_event_id']}"
    )

def run_promote_medications(
    descriptor_path: Path,
    import_batch_id: UUID,
) -> None:
    settings = get_settings()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    print("JANUS CANONICAL MEDICATION PROMOTION")
    print("------------------------------------")
    print(
        f"Environment:  {settings.janus_env}"
    )
    print(
        f"Release:      "
        f"{descriptor.release.release_label}"
    )
    print(
        f"Import Batch: {import_batch_id}"
    )
    print()

    result = promote_medications(
        settings,
        descriptor,
        import_batch_id=import_batch_id,
    )

    print("Canonical Medication promotion completed.")
    print(
        f"Promotion Run:         "
        f"{result['canonical_promotion_run_id']}"
    )
    print(
        f"Mapping:               "
        f"{result['mapping_name']} "
        f"v{result['mapping_version']}"
    )
    print(
        f"Records Seen:          "
        f"{result['records_seen']}"
    )
    print(
        f"Medications Created:   "
        f"{result['records_created']}"
    )
    print(
        f"Medications Existing:  "
        f"{result['records_existing']}"
    )
    print(
        f"Records Failed:        "
        f"{result['records_failed']}"
    )
    print(
        f"With End Timestamp:    "
        f"{result['medications_with_end_at']}"
    )
    print(
        f"Without End Timestamp: "
        f"{result['medications_without_end_at']}"
    )
    print(
        f"Lineage Edges:         "
        f"{result['lineage_edges_created']}"
    )
    print(
        f"Completed Event:       "
        f"{result['completed_system_event_id']}"
    )
def main(
    argv: Sequence[str] | None = None,
) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command in (None, "health"):
        run_health()
        return

    if args.command == "promote-patients":
        run_promote_patients(
            args.descriptor,
            args.batch,
        )
        return

    if args.command == "promote-providers":
        run_promote_providers(
            args.descriptor,
            args.batch,
        )
        return

    if args.command == "promote-encounters":
        run_promote_encounters(
            args.descriptor,
            args.batch,
        )
        return

    if args.command == "promote-conditions":
        run_promote_conditions(
            args.descriptor,
            args.batch,
        )
        return
    if args.command == "promote-medications":
        run_promote_medications(
            args.descriptor,
            args.batch,
        )
        return
    parser.error(
        f"Unsupported command: {args.command}"
    )


if __name__ == "__main__":
    main()