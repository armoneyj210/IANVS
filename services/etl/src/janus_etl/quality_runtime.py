import csv
import hashlib
from dataclasses import dataclass
from datetime import UTC, date, datetime, time
from decimal import Decimal
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any
from uuid import UUID

from psycopg.types.json import Jsonb

from janus_etl.config import QualitySettings
from janus_etl.dataset_descriptor import GovernedDatasetDescriptor
from janus_etl.db import open_connection
from janus_etl.import_runtime import preflight_release

QUALITY_ENGINE_NAME = "janus-quality"
RULESET_NAME = "janus-precanonical"
RULESET_VERSION = "2"

RULE_EXPECTATIONS = {
    "JANUS-DQ-001": {
        "version": 1,
        "implementation_ref": (
            "janus.quality.source_record_identifier"
        ),
        "severity": "fatal",
        "blocking": True,
    },
    "JANUS-DQ-002": {
        "version": 1,
        "implementation_ref": "janus.quality.provenance",
        "severity": "fatal",
        "blocking": True,
    },
    "JANUS-DQ-003": {
        "version": 1,
        "implementation_ref": (
            "janus.quality.patient_identifier_uniqueness"
        ),
        "severity": "error",
        "blocking": True,
    },
    "JANUS-DQ-004": {
        "version": 1,
        "implementation_ref": (
            "janus.quality.temporal_consistency"
        ),
        "severity": "error",
        "blocking": True,
    },
    "JANUS-DQ-005": {
        "version": 1,
        "implementation_ref": (
            "janus.quality.terminology_identification"
        ),
        "severity": "warning",
        "blocking": False,
    },
}

RULE_CODES = tuple(RULE_EXPECTATIONS)

DEFERRED_RULES = {
    "JANUS-DQ-006": (
        "Deferred until canonical clinical records and "
        "record_lineage exist."
    )
}


@dataclass(frozen=True)
class QualityIssue:
    source_record_id: UUID | None
    source_file_id: UUID | None
    severity: str
    field_path: str | None
    message: str
    details: dict[str, Any]
    quarantine: bool = False
    reason_code: str | None = None
    reason: str | None = None


@dataclass(frozen=True)
class RuleEvaluation:
    rule_code: str
    outcome: str
    records_evaluated: int
    records_passed: int
    records_failed: int
    records_skipped: int
    score: Decimal | None
    details: dict[str, Any]
    issues: tuple[QualityIssue, ...] = ()


def _set_environment(cursor, settings: QualitySettings) -> None:
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


def _engine_version() -> str:
    try:
        return version("janus-etl")
    except PackageNotFoundError:
        return "0+local"


def _score(passed: int, failed: int) -> Decimal | None:
    denominator = passed + failed

    if denominator == 0:
        return None

    return (
        Decimal(passed) / Decimal(denominator)
    ).quantize(Decimal("0.000001"))


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
        "component": "quality_runtime",
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


def _resolve_import_batch(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    dataset_release_id: UUID,
    expected_rows: int,
) -> dict[str, Any]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                import_batch_id,
                dataset_release_id,
                status,
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

        if batch["dataset_release_id"] != dataset_release_id:
            raise ValueError(
                "Import batch does not belong to the descriptor's "
                "registered dataset release"
            )

        if batch["status"] != "completed":
            raise ValueError(
                "Data quality requires a completed import batch: "
                f"status={batch['status']}"
            )

        if batch["records_seen"] != expected_rows:
            raise ValueError(
                "Import batch row count does not match the verified "
                "release: "
                f"batch={batch['records_seen']}, "
                f"release={expected_rows}"
            )

        return batch


def _load_rules(settings: QualitySettings) -> dict[str, dict[str, Any]]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                data_quality_rule_id,
                rule_code,
                rule_version,
                name,
                severity,
                blocking,
                implementation_ref
            FROM ingest.data_quality_rule
            WHERE rule_code = ANY(%s)
              AND rule_version = 1
              AND is_active IS TRUE
            ORDER BY rule_code;
            """,
            (list(RULE_CODES),),
        )

        rules = {
            row["rule_code"]: row
            for row in cursor.fetchall()
        }

    missing = sorted(set(RULE_CODES) - set(rules))

    if missing:
        raise RuntimeError(
            "Required data-quality rules are missing or inactive: "
            f"{missing}"
        )

    for rule_code, expectation in RULE_EXPECTATIONS.items():
        rule = rules[rule_code]

        for field in (
            "rule_version",
            "implementation_ref",
            "severity",
            "blocking",
        ):
            expected_field = (
                "version"
                if field == "rule_version"
                else field
            )
            expected = expectation[expected_field]
            actual = rule[field]

            if actual != expected:
                raise RuntimeError(
                    "Data-quality rule registry does not match "
                    "the pinned runtime contract: "
                    f"{rule_code}.{field}: "
                    f"database={actual!r}, "
                    f"expected={expected!r}"
                )

    return rules


def _create_quality_run(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT data_quality_run_id, status
            FROM ingest.data_quality_run
            WHERE import_batch_id = %s
              AND ruleset_name = %s
              AND ruleset_version = %s
            ORDER BY created_at DESC
            LIMIT 1;
            """,
            (
                import_batch_id,
                RULESET_NAME,
                RULESET_VERSION,
            ),
        )

        existing = cursor.fetchone()

        if existing is not None:
            raise RuntimeError(
                "A quality run already exists for this batch and "
                "ruleset version: "
                f"{existing['data_quality_run_id']} "
                f"({existing['status']})"
            )

        cursor.execute(
            """
            INSERT INTO ingest.data_quality_run (
                import_batch_id,
                status,
                engine_name,
                engine_version,
                ruleset_name,
                ruleset_version,
                initiated_by,
                started_at,
                metrics
            )
            VALUES (
                %s,
                'running',
                %s,
                %s,
                %s,
                %s,
                current_user,
                clock_timestamp(),
                %s
            )
            RETURNING
                data_quality_run_id,
                import_batch_id,
                status,
                engine_name,
                engine_version,
                ruleset_name,
                ruleset_version,
                initiated_by,
                started_at;
            """,
            (
                import_batch_id,
                QUALITY_ENGINE_NAME,
                _engine_version(),
                RULESET_NAME,
                RULESET_VERSION,
                Jsonb(
                    {
                        "deferred_rules": DEFERRED_RULES,
                        "authority_principal": "janus_quality_svc",
                    }
                ),
            ),
        )

        quality_run = cursor.fetchone()

        event_id = _write_system_event(
            cursor,
            event_type="data_quality.run_started",
            outcome="success",
            message="Janus pre-canonical data-quality run started",
            metadata={
                "data_quality_run_id": str(
                    quality_run["data_quality_run_id"]
                ),
                "import_batch_id": str(import_batch_id),
                "ruleset_name": RULESET_NAME,
                "ruleset_version": RULESET_VERSION,
            },
        )

        return {
            **quality_run,
            "system_event_id": event_id,
        }


def _load_file_record_map(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    source_file_id: UUID,
) -> dict[int, dict[str, Any]]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                source_record_id,
                row_number,
                record_locator,
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

        records = cursor.fetchall()

    result: dict[int, dict[str, Any]] = {}

    for record in records:
        row_number = record["row_number"]

        if row_number is None:
            raise RuntimeError(
                "Row-oriented source record is missing row_number"
            )

        result[row_number] = record

    return result


def _require_source_record(
    record_map: dict[int, dict[str, Any]],
    *,
    relative_path: str,
    row_number: int,
) -> dict[str, Any]:
    record = record_map.get(row_number)

    if record is None:
        raise RuntimeError(
            "Verified raw CSV row has no matching source record: "
            f"{relative_path} row {row_number}"
        )

    return record


def _evaluate_dq001(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    severity: str,
) -> RuleEvaluation:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT COUNT(*) AS record_count
            FROM ingest.source_record
            WHERE import_batch_id = %s;
            """,
            (import_batch_id,),
        )
        total = cursor.fetchone()["record_count"]

        cursor.execute(
            """
            SELECT
                source_record_id,
                source_file_id
            FROM ingest.source_record
            WHERE import_batch_id = %s
              AND btrim(source_record_key) = '';
            """,
            (import_batch_id,),
        )
        failures = cursor.fetchall()

    issues = tuple(
        QualityIssue(
            source_record_id=row["source_record_id"],
            source_file_id=row["source_file_id"],
            severity=severity,
            field_path="source_record_key",
            message="Source record key is blank.",
            details={"failure_type": "blank_source_record_key"},
            quarantine=True,
            reason_code="DQ001_SOURCE_RECORD_IDENTIFIER",
            reason="Source record identifier requirement failed.",
        )
        for row in failures
    )

    failed = len(failures)
    passed = total - failed

    return RuleEvaluation(
        rule_code="JANUS-DQ-001",
        outcome="fail" if failed else "pass",
        records_evaluated=total,
        records_passed=passed,
        records_failed=failed,
        records_skipped=0,
        score=_score(passed, failed),
        details={
            "requirement": "nonblank_source_record_key",
        },
        issues=issues,
    )


def _evaluate_dq002(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    severity: str,
) -> RuleEvaluation:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT COUNT(*) AS record_count
            FROM ingest.source_record
            WHERE import_batch_id = %s;
            """,
            (import_batch_id,),
        )
        total = cursor.fetchone()["record_count"]

        cursor.execute(
            """
            SELECT
                sr.source_record_id,
                sr.source_file_id,
                CASE
                    WHEN sr.source_file_id IS NULL
                        THEN 'missing_source_file'
                    WHEN sf.source_file_id IS NULL
                        THEN 'orphaned_source_file'
                    WHEN sf.dataset_release_id
                         <> ib.dataset_release_id
                        THEN 'release_mismatch'
                    ELSE 'unknown_provenance_failure'
                END AS failure_type
            FROM ingest.source_record sr
            JOIN ingest.import_batch ib
              ON ib.import_batch_id = sr.import_batch_id
            LEFT JOIN ingest.source_file sf
              ON sf.source_file_id = sr.source_file_id
            WHERE sr.import_batch_id = %s
              AND (
                    sr.source_file_id IS NULL
                 OR sf.source_file_id IS NULL
                 OR sf.dataset_release_id
                    <> ib.dataset_release_id
              );
            """,
            (import_batch_id,),
        )
        failures = cursor.fetchall()

    issues = tuple(
        QualityIssue(
            source_record_id=row["source_record_id"],
            source_file_id=row["source_file_id"],
            severity=severity,
            field_path=None,
            message="Source record provenance chain is incomplete.",
            details={"failure_type": row["failure_type"]},
            quarantine=True,
            reason_code="DQ002_DATASET_PROVENANCE",
            reason="Dataset provenance requirement failed.",
        )
        for row in failures
    )

    failed = len(failures)
    passed = total - failed

    return RuleEvaluation(
        rule_code="JANUS-DQ-002",
        outcome="fail" if failed else "pass",
        records_evaluated=total,
        records_passed=passed,
        records_failed=failed,
        records_skipped=0,
        score=_score(passed, failed),
        details={
            "approval_evidence": (
                "ingest.import_batch V008 governance gate"
            ),
            "direct_governance_read": False,
        },
        issues=issues,
    )


def _identifier_fingerprint(value: str) -> str:
    return hashlib.sha256(
        value.strip().casefold().encode("utf-8")
    ).hexdigest()[:16]


def _evaluate_dq003(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    raw_directory: Path,
    source_files: dict[str, dict[str, Any]],
    severity: str,
) -> RuleEvaluation:
    relative_path = "csv/patients.csv"
    source_file = source_files[relative_path]
    file_path = raw_directory / relative_path

    record_map = _load_file_record_map(
        settings,
        import_batch_id=import_batch_id,
        source_file_id=source_file["source_file_id"],
    )

    identifier_fields = (
        "Id",
        "SSN",
        "DRIVERS",
        "PASSPORT",
    )

    seen: dict[str, dict[str, list[int]]] = {
        field: {}
        for field in identifier_fields
    }
    total = 0

    with file_path.open(
        "r",
        encoding="utf-8-sig",
        newline="",
    ) as handle:
        reader = csv.DictReader(handle)

        for row_number, row in enumerate(reader, start=1):
            total += 1

            for field in identifier_fields:
                value = (row.get(field) or "").strip()

                if not value:
                    continue

                normalized = value.casefold()
                seen[field].setdefault(
                    normalized,
                    [],
                ).append(row_number)

    failed_rows: set[int] = set()
    issues: list[QualityIssue] = []
    duplicate_groups = 0

    for field, values in seen.items():
        for normalized, row_numbers in values.items():
            if len(row_numbers) < 2:
                continue

            duplicate_groups += 1
            fingerprint = _identifier_fingerprint(normalized)

            for row_number in row_numbers:
                failed_rows.add(row_number)
                source_record = _require_source_record(
                    record_map,
                    relative_path=relative_path,
                    row_number=row_number,
                )

                issues.append(
                    QualityIssue(
                        source_record_id=(
                            source_record["source_record_id"]
                        ),
                        source_file_id=(
                            source_file["source_file_id"]
                        ),
                        severity=severity,
                        field_path=field,
                        message=(
                            "Patient identifier is duplicated "
                            "within its identifier system."
                        ),
                        details={
                            "identifier_system": field,
                            "identifier_fingerprint": fingerprint,
                            "duplicate_count": len(row_numbers),
                        },
                        quarantine=True,
                        reason_code="DQ003_IDENTIFIER_DUPLICATE",
                        reason=(
                            "Patient identifier uniqueness "
                            "requirement failed."
                        ),
                    )
                )

    failed = len(failed_rows)
    passed = total - failed

    return RuleEvaluation(
        rule_code="JANUS-DQ-003",
        outcome="fail" if failed else "pass",
        records_evaluated=total,
        records_passed=passed,
        records_failed=failed,
        records_skipped=0,
        score=_score(passed, failed),
        details={
            "identifier_systems": list(identifier_fields),
            "duplicate_groups": duplicate_groups,
            "raw_identifier_values_logged": False,
        },
        issues=tuple(issues),
    )


def _parse_temporal(value: str) -> datetime:
    text = value.strip()

    if not text:
        raise ValueError("blank temporal value")

    if len(text) == 10:
        parsed_date = date.fromisoformat(text)

        return datetime.combine(
            parsed_date,
            time.min,
            tzinfo=UTC,
        )

    parsed = datetime.fromisoformat(text)

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    
    return parsed.astimezone(UTC)


def _evaluate_dq004(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    raw_directory: Path,
    source_files: dict[str, dict[str, Any]],
    severity: str,
) -> RuleEvaluation:
    temporal_specs = (
        ("csv/conditions.csv", "START", "STOP"),
        ("csv/encounters.csv", "START", "STOP"),
        ("csv/medications.csv", "START", "STOP"),
        ("csv/patients.csv", "BIRTHDATE", "DEATHDATE"),
    )

    total = 0
    failed = 0
    issues: list[QualityIssue] = []
    file_metrics: dict[str, dict[str, int]] = {}

    for relative_path, start_field, end_field in temporal_specs:
        source_file = source_files[relative_path]
        record_map = _load_file_record_map(
            settings,
            import_batch_id=import_batch_id,
            source_file_id=source_file["source_file_id"],
        )

        file_total = 0
        file_failed = 0

        with (raw_directory / relative_path).open(
            "r",
            encoding="utf-8-sig",
            newline="",
        ) as handle:
            reader = csv.DictReader(handle)

            for row_number, row in enumerate(reader, start=1):
                total += 1
                file_total += 1

                start_value = (row.get(start_field) or "").strip()
                end_value = (row.get(end_field) or "").strip()

                failure_type: str | None = None

                try:
                    start_time = _parse_temporal(start_value)
                except ValueError:
                    failure_type = "invalid_or_missing_start"
                    start_time = None

                end_time: datetime | None = None

                if failure_type is None and end_value:
                    try:
                        end_time = _parse_temporal(end_value)
                    except ValueError:
                        failure_type = "invalid_end"

                if (
                    failure_type is None
                    and start_time is not None
                    and end_time is not None
                    and end_time < start_time
                ):
                    failure_type = "end_before_start"

                if failure_type is None:
                    continue

                failed += 1
                file_failed += 1

                source_record = _require_source_record(
                    record_map,
                    relative_path=relative_path,
                    row_number=row_number,
                )

                issues.append(
                    QualityIssue(
                        source_record_id=(
                            source_record["source_record_id"]
                        ),
                        source_file_id=(
                            source_file["source_file_id"]
                        ),
                        severity=severity,
                        field_path=(
                            f"{start_field}/{end_field}"
                        ),
                        message=(
                            "Temporal consistency requirement "
                            "failed for this source record."
                        ),
                        details={
                            "relative_path": relative_path,
                            "start_field": start_field,
                            "end_field": end_field,
                            "failure_type": failure_type,
                            "raw_temporal_values_logged": False,
                        },
                        quarantine=True,
                        reason_code="DQ004_TEMPORAL_CONSISTENCY",
                        reason=(
                            "Temporal consistency requirement "
                            "failed."
                        ),
                    )
                )

        file_metrics[relative_path] = {
            "records_evaluated": file_total,
            "records_failed": file_failed,
        }

    passed = total - failed

    return RuleEvaluation(
        rule_code="JANUS-DQ-004",
        outcome="fail" if failed else "pass",
        records_evaluated=total,
        records_passed=passed,
        records_failed=failed,
        records_skipped=0,
        score=_score(passed, failed),
        details={"files": file_metrics},
        issues=tuple(issues),
    )


def _evaluate_dq005(
    *,
    raw_directory: Path,
    source_files: dict[str, dict[str, Any]],
    severity: str,
) -> RuleEvaluation:
    terminology_specs = (
        ("csv/conditions.csv", "CODE", "SYSTEM"),
        ("csv/encounters.csv", "CODE", None),
        ("csv/medications.csv", "CODE", None),
        ("csv/observations.csv", "CODE", None),
    )

    evaluated = 0
    passed = 0
    failed = 0
    skipped = 0
    issues: list[QualityIssue] = []
    file_metrics: dict[str, dict[str, int]] = {}

    for relative_path, code_field, system_field in terminology_specs:
        coded_records = 0
        identified_records = 0
        missing_system_records = 0
        skipped_records = 0

        with (raw_directory / relative_path).open(
            "r",
            encoding="utf-8-sig",
            newline="",
        ) as handle:
            reader = csv.DictReader(handle)

            for row in reader:
                code = (row.get(code_field) or "").strip()

                if not code:
                    skipped += 1
                    skipped_records += 1
                    continue

                evaluated += 1
                coded_records += 1

                system = ""
                if system_field is not None:
                    system = (
                        row.get(system_field) or ""
                    ).strip()

                if system:
                    passed += 1
                    identified_records += 1
                else:
                    failed += 1
                    missing_system_records += 1

        file_metrics[relative_path] = {
            "coded_records": coded_records,
            "identified_system_records": identified_records,
            "missing_system_records": missing_system_records,
            "skipped_records": skipped_records,
        }

        if missing_system_records:
            issues.append(
                QualityIssue(
                    source_record_id=None,
                    source_file_id=(
                        source_files[relative_path][
                            "source_file_id"
                        ]
                    ),
                    severity=severity,
                    field_path=(
                        system_field or "SYSTEM"
                    ),
                    message=(
                        "Coded records do not identify a coding "
                        "system in this source artifact."
                    ),
                    details={
                        "relative_path": relative_path,
                        "coded_records": coded_records,
                        "missing_system_records": (
                            missing_system_records
                        ),
                        "source_exposes_system_field": (
                            system_field is not None
                        ),
                    },
                )
            )

    return RuleEvaluation(
        rule_code="JANUS-DQ-005",
        outcome="warning" if failed else "pass",
        records_evaluated=evaluated + skipped,
        records_passed=passed,
        records_failed=failed,
        records_skipped=skipped,
        score=_score(passed, failed),
        details={
            "files": file_metrics,
            "warning_is_blocking": False,
            "coding_system_inference_performed": False,
        },
        issues=tuple(issues),
    )


def _persist_evaluation(
    settings: QualitySettings,
    *,
    import_batch_id: UUID,
    data_quality_run_id: UUID,
    rule: dict[str, Any],
    evaluation: RuleEvaluation,
) -> None:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            INSERT INTO ingest.data_quality_result (
                data_quality_run_id,
                data_quality_rule_id,
                outcome,
                records_evaluated,
                records_passed,
                records_failed,
                records_skipped,
                score,
                details
            )
            VALUES (
                %s, %s, %s, %s, %s,
                %s, %s, %s, %s
            );
            """,
            (
                data_quality_run_id,
                rule["data_quality_rule_id"],
                evaluation.outcome,
                evaluation.records_evaluated,
                evaluation.records_passed,
                evaluation.records_failed,
                evaluation.records_skipped,
                evaluation.score,
                Jsonb(evaluation.details),
            ),
        )

        for issue in evaluation.issues:
            cursor.execute(
                """
                INSERT INTO ingest.validation_issue (
                    import_batch_id,
                    source_file_id,
                    source_record_id,
                    rule_code,
                    severity,
                    field_path,
                    message,
                    details,
                    data_quality_run_id,
                    data_quality_rule_id
                )
                VALUES (
                    %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s
                );
                """,
                (
                    import_batch_id,
                    issue.source_file_id,
                    issue.source_record_id,
                    evaluation.rule_code,
                    issue.severity,
                    issue.field_path,
                    issue.message,
                    Jsonb(issue.details),
                    data_quality_run_id,
                    rule["data_quality_rule_id"],
                ),
            )

            if not issue.quarantine:
                continue

            if issue.source_record_id is None:
                raise RuntimeError(
                    "Blocking quality issue cannot quarantine "
                    "without source_record_id"
                )

            cursor.execute(
                """
                INSERT INTO ingest.quarantine_record (
                    source_record_id,
                    data_quality_run_id,
                    data_quality_rule_id,
                    status,
                    reason_code,
                    reason
                )
                VALUES (
                    %s, %s, %s,
                    'quarantined', %s, %s
                )
                ON CONFLICT (source_record_id)
                    WHERE status = 'quarantined'
                DO NOTHING;
                """,
                (
                    issue.source_record_id,
                    data_quality_run_id,
                    rule["data_quality_rule_id"],
                    issue.reason_code or evaluation.rule_code,
                    issue.reason or issue.message,
                ),
            )

            cursor.execute(
                """
                UPDATE ingest.source_record
                SET record_status = 'quarantined'
                WHERE source_record_id = %s
                  AND record_status <> 'quarantined';
                """,
                (issue.source_record_id,),
            )


def _complete_quality_run(
    settings: QualitySettings,
    *,
    data_quality_run_id: UUID,
    import_batch_id: UUID,
    records_evaluated: int,
) -> dict[str, Any]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        _set_environment(cursor, settings)

        cursor.execute(
            """
            SELECT
                COUNT(*) AS rules_evaluated,
                COUNT(*) FILTER (
                    WHERE r.outcome = 'pass'
                ) AS rules_passed,
                COUNT(*) FILTER (
                    WHERE r.outcome = 'warning'
                ) AS rules_warned,
                COUNT(*) FILTER (
                    WHERE r.outcome IN ('fail', 'error')
                ) AS rules_failed,
                BOOL_OR(
                    q.blocking
                    AND r.outcome IN ('fail', 'error')
                ) AS blocking_failure
            FROM ingest.data_quality_result r
            JOIN ingest.data_quality_rule q
              ON q.data_quality_rule_id = r.data_quality_rule_id
            WHERE r.data_quality_run_id = %s;
            """,
            (data_quality_run_id,),
        )
        summary = cursor.fetchone()

        if summary["rules_evaluated"] != len(RULE_CODES):
            raise RuntimeError(
                "Quality run does not contain the expected five "
                "pre-canonical rule results"
            )

        cursor.execute(
            """
            SELECT COUNT(*) AS quarantined_count
            FROM ingest.quarantine_record
            WHERE data_quality_run_id = %s
              AND status = 'quarantined';
            """,
            (data_quality_run_id,),
        )
        quarantined_count = cursor.fetchone()[
            "quarantined_count"
        ]

        gate_decision = (
            "fail"
            if summary["blocking_failure"]
            else "pass"
        )

        metrics = {
            "deferred_rules": DEFERRED_RULES,
            "gate_decision": gate_decision,
            "blocking_failure": bool(
                summary["blocking_failure"]
            ),
            "authority_principal": "janus_quality_svc",
        }

        cursor.execute(
            """
            UPDATE ingest.data_quality_run
            SET
                status = 'completed',
                completed_at = clock_timestamp(),
                rules_evaluated = %s,
                rules_passed = %s,
                rules_warned = %s,
                rules_failed = %s,
                records_evaluated = %s,
                records_quarantined = %s,
                metrics = %s
            WHERE data_quality_run_id = %s
              AND status = 'running'
            RETURNING
                data_quality_run_id,
                status,
                completed_at,
                rules_evaluated,
                rules_passed,
                rules_warned,
                rules_failed,
                records_evaluated,
                records_quarantined;
            """,
            (
                summary["rules_evaluated"],
                summary["rules_passed"],
                summary["rules_warned"],
                summary["rules_failed"],
                records_evaluated,
                quarantined_count,
                Jsonb(metrics),
                data_quality_run_id,
            ),
        )
        quality_run = cursor.fetchone()

        if quality_run is None:
            raise RuntimeError(
                "Quality run is no longer in running state"
            )

        cursor.execute(
            """
            SELECT ingest.write_quality_gate_decision(
                %s,
                %s,
                %s
            ) AS quality_gate_decision_id;
            """,
            (
                data_quality_run_id,
                gate_decision,
                (
                    "Pre-canonical blocking quality rules failed."
                    if gate_decision == "fail"
                    else (
                        "All pre-canonical blocking quality rules "
                        "passed. Non-blocking warnings may remain."
                    )
                ),
            ),
        )
        gate = cursor.fetchone()

        event_id = _write_system_event(
            cursor,
            event_type="data_quality.run_completed",
            outcome=(
                "failure"
                if gate_decision == "fail"
                else "success"
            ),
            severity=(
                "warning"
                if gate_decision == "fail"
                else "info"
            ),
            message="Janus pre-canonical data-quality run completed",
            metadata={
                "data_quality_run_id": str(data_quality_run_id),
                "import_batch_id": str(import_batch_id),
                "gate_decision": gate_decision,
                "rules_evaluated": summary["rules_evaluated"],
                "rules_failed": summary["rules_failed"],
                "records_quarantined": quarantined_count,
                "deferred_rules": list(DEFERRED_RULES),
            },
        )

        return {
            **quality_run,
            "gate_decision": gate_decision,
            "quality_gate_decision_id": gate[
                "quality_gate_decision_id"
            ],
            "system_event_id": event_id,
        }


def _fail_quality_run(
    settings: QualitySettings,
    *,
    data_quality_run_id: UUID,
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
            UPDATE ingest.data_quality_run
            SET
                status = 'failed',
                completed_at = clock_timestamp(),
                metrics = metrics || %s
            WHERE data_quality_run_id = %s
              AND status = 'running'
            RETURNING data_quality_run_id;
            """,
            (
                Jsonb({"runtime_error": error_summary}),
                data_quality_run_id,
            ),
        )
        updated = cursor.fetchone()

        if updated is None:
            return

        cursor.execute(
            """
            SELECT ingest.write_quality_gate_decision(
                %s,
                'fail',
                %s
            ) AS quality_gate_decision_id;
            """,
            (
                data_quality_run_id,
                (
                    "Quality runtime failed closed: "
                    f"{error_summary['error_type']}"
                ),
            ),
        )

        _write_system_event(
            cursor,
            event_type="data_quality.run_failed",
            outcome="failure",
            severity="error",
            message="Janus pre-canonical data-quality run failed",
            metadata={
                "data_quality_run_id": str(data_quality_run_id),
                "import_batch_id": str(import_batch_id),
                **error_summary,
            },
        )


def quality_run(
    settings: QualitySettings,
    descriptor: GovernedDatasetDescriptor,
    *,
    import_batch_id: UUID,
) -> dict[str, Any]:
    # Re-verify the governed release before using raw artifacts
    # for source-value quality checks.
    preflight = preflight_release(settings, descriptor)

    dataset_release_id = preflight["release"][
        "dataset_release_id"
    ]

    batch = _resolve_import_batch(
        settings,
        import_batch_id=import_batch_id,
        dataset_release_id=dataset_release_id,
        expected_rows=preflight["expected_rows"],
    )

    rules = _load_rules(settings)

    run = _create_quality_run(
        settings,
        import_batch_id=import_batch_id,
    )
    data_quality_run_id = run["data_quality_run_id"]

    source_files = {
        source_file["relative_path"]: source_file
        for source_file in preflight["importable_source_files"]
    }

    try:
        evaluations = (
            _evaluate_dq001(
                settings,
                import_batch_id=import_batch_id,
                severity=rules["JANUS-DQ-001"]["severity"],
            ),
            _evaluate_dq002(
                settings,
                import_batch_id=import_batch_id,
                severity=rules["JANUS-DQ-002"]["severity"],
            ),
            _evaluate_dq003(
                settings,
                import_batch_id=import_batch_id,
                raw_directory=preflight["raw_directory"],
                source_files=source_files,
                severity=rules["JANUS-DQ-003"]["severity"],
            ),
            _evaluate_dq004(
                settings,
                import_batch_id=import_batch_id,
                raw_directory=preflight["raw_directory"],
                source_files=source_files,
                severity=rules["JANUS-DQ-004"]["severity"],
            ),
            _evaluate_dq005(
                raw_directory=preflight["raw_directory"],
                source_files=source_files,
                severity=rules["JANUS-DQ-005"]["severity"],
            ),
        )

        for evaluation in evaluations:
            _persist_evaluation(
                settings,
                import_batch_id=import_batch_id,
                data_quality_run_id=data_quality_run_id,
                rule=rules[evaluation.rule_code],
                evaluation=evaluation,
            )

        completed = _complete_quality_run(
            settings,
            data_quality_run_id=data_quality_run_id,
            import_batch_id=import_batch_id,
            records_evaluated=batch["records_seen"],
        )

        return {
            "data_quality_run_id": data_quality_run_id,
            "import_batch_id": import_batch_id,
            "dataset_release_id": dataset_release_id,
            "release_label": preflight["release"]["release_label"],
            "ruleset_name": RULESET_NAME,
            "ruleset_version": RULESET_VERSION,
            "deferred_rules": DEFERRED_RULES,
            "rule_results": [
                {
                    "rule_code": evaluation.rule_code,
                    "outcome": evaluation.outcome,
                    "records_evaluated": (
                        evaluation.records_evaluated
                    ),
                    "records_failed": evaluation.records_failed,
                }
                for evaluation in evaluations
            ],
            **completed,
        }

    except Exception as error:
        _fail_quality_run(
            settings,
            data_quality_run_id=data_quality_run_id,
            import_batch_id=import_batch_id,
            error=error,
        )
        raise