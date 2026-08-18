import os
from uuid import uuid4

import pytest
from psycopg.errors import InsufficientPrivilege

from janus_etl.config import (
    get_quality_settings,
)
from janus_etl.db import open_connection
from janus_etl.quality_runtime import (
    RULE_CODES,
    RULESET_NAME,
    RULESET_VERSION,
    _load_rules,
)

RUN_INTEGRATION_TESTS = (
    os.getenv("JANUS_RUN_INTEGRATION_TESTS") == "1"
)

APPROVED_RELEASE_LABEL = os.getenv(
    "JANUS_TEST_APPROVED_RELEASE_LABEL"
)


pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not RUN_INTEGRATION_TESTS,
        reason=(
            "Set JANUS_RUN_INTEGRATION_TESTS=1 "
            "to run database integration tests"
        ),
    ),
]


def test_quality_rule_registry_matches_runtime() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    rules = _load_rules(settings)

    assert set(rules) == set(RULE_CODES)
    assert len(rules) == 5

    assert rules["JANUS-DQ-001"]["blocking"] is True
    assert rules["JANUS-DQ-002"]["blocking"] is True
    assert rules["JANUS-DQ-003"]["blocking"] is True
    assert rules["JANUS-DQ-004"]["blocking"] is True
    assert rules["JANUS-DQ-005"]["blocking"] is False


def test_quality_identity_and_permissions() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        cursor.execute(
            """
            SELECT
                session_user AS principal,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_rule',
                    'SELECT'
                ) AS rule_select,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_rule',
                    'INSERT'
                ) AS rule_insert,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_run',
                    'INSERT'
                ) AS run_insert,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_run',
                    'UPDATE'
                ) AS run_update,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_result',
                    'INSERT'
                ) AS result_insert,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_result',
                    'UPDATE'
                ) AS result_update,

                has_table_privilege(
                    current_user,
                    'ingest.validation_issue',
                    'INSERT'
                ) AS issue_insert,

                has_table_privilege(
                    current_user,
                    'ingest.quarantine_record',
                    'INSERT'
                ) AS quarantine_insert,

                has_column_privilege(
                    current_user,
                    'ingest.source_record',
                    'record_status',
                    'UPDATE'
                ) AS source_status_update,

                has_column_privilege(
                    current_user,
                    'ingest.source_record',
                    'payload_sha256',
                    'UPDATE'
                ) AS source_hash_update,

                has_table_privilege(
                    current_user,
                    'ingest.quality_gate_decision',
                    'INSERT'
                ) AS gate_insert,

                has_function_privilege(
                    current_user,
                    'ingest.write_quality_gate_decision(uuid,text,text)',
                    'EXECUTE'
                ) AS gate_execute,

                has_table_privilege(
                    current_user,
                    'clinical.patient',
                    'INSERT'
                ) AS clinical_insert,

                has_schema_privilege(
                    current_user,
                    'governance',
                    'USAGE'
                ) AS governance_usage;
            """
        )

        permissions = cursor.fetchone()

    assert permissions is not None
    assert permissions["principal"] == "janus_quality_svc"

    assert permissions["rule_select"] is True
    assert permissions["rule_insert"] is False

    assert permissions["run_insert"] is True
    assert permissions["run_update"] is True

    assert permissions["result_insert"] is True
    assert permissions["result_update"] is False

    assert permissions["issue_insert"] is True
    assert permissions["quarantine_insert"] is True

    assert permissions["source_status_update"] is True
    assert permissions["source_hash_update"] is False

    assert permissions["gate_insert"] is False
    assert permissions["gate_execute"] is True

    assert permissions["clinical_insert"] is False
    assert permissions["governance_usage"] is False


@pytest.mark.skipif(
    not APPROVED_RELEASE_LABEL,
    reason=(
        "Set JANUS_TEST_APPROVED_RELEASE_LABEL "
        "to test DQ persistence"
    ),
)
def test_quality_persistence_contract_rolls_back() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT ib.import_batch_id
                FROM ingest.import_batch ib
                JOIN ingest.dataset_release dr
                  ON dr.dataset_release_id =
                     ib.dataset_release_id
                WHERE dr.release_label = %s
                  AND ib.status = 'completed'
                ORDER BY ib.created_at DESC
                LIMIT 1;
                """,
                (APPROVED_RELEASE_LABEL,),
            )

            batch = cursor.fetchone()
            assert batch is not None

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
                    'janus-quality-integration-test',
                    'test',
                    %s,
                    %s,
                    current_user,
                    clock_timestamp(),
                    '{}'::jsonb
                )
                RETURNING data_quality_run_id;
                """,
                (
                    batch["import_batch_id"],
                    RULESET_NAME,
                    RULESET_VERSION,
                ),
            )

            quality_run = cursor.fetchone()
            assert quality_run is not None

            cursor.execute(
                """
                SELECT
                    data_quality_rule_id,
                    rule_code
                FROM ingest.data_quality_rule
                WHERE rule_code = ANY(%s)
                  AND rule_version = 1
                ORDER BY rule_code;
                """,
                (list(RULE_CODES),),
            )

            rules = cursor.fetchall()
            assert len(rules) == 5

            for rule in rules:
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
                        %s,
                        %s,
                        'pass',
                        1,
                        1,
                        0,
                        0,
                        1.0,
                        '{"integration_test": true}'::jsonb
                    );
                    """,
                    (
                        quality_run["data_quality_run_id"],
                        rule["data_quality_rule_id"],
                    ),
                )

            cursor.execute(
                """
                UPDATE ingest.data_quality_run
                SET
                    status = 'completed',
                    completed_at = clock_timestamp(),
                    rules_evaluated = 5,
                    rules_passed = 5,
                    rules_warned = 0,
                    rules_failed = 0,
                    records_evaluated = 1,
                    records_quarantined = 0
                WHERE data_quality_run_id = %s;
                """,
                (quality_run["data_quality_run_id"],),
            )

            cursor.execute(
                """
                SELECT ingest.write_quality_gate_decision(
                    %s,
                    'pass',
                    'Integration test only'
                ) AS quality_gate_decision_id;
                """,
                (quality_run["data_quality_run_id"],),
            )

            gate = cursor.fetchone()
            assert gate is not None

            cursor.execute(
                """
                SELECT
                    decision,
                    decided_by
                FROM ingest.quality_gate_decision
                WHERE quality_gate_decision_id = %s;
                """,
                (gate["quality_gate_decision_id"],),
            )

            persisted_gate = cursor.fetchone()

            assert persisted_gate is not None
            assert persisted_gate["decision"] == "pass"
            assert (
                persisted_gate["decided_by"]
                == "janus_quality_svc"
            )

        conn.rollback()


def test_quality_cannot_insert_gate_directly() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                INSERT INTO ingest.quality_gate_decision (
                    data_quality_run_id,
                    decision,
                    decided_by
                )
                VALUES (
                    %s,
                    'override_pass',
                    current_user
                );
                """,
                (uuid4(),),
            )

        conn.rollback()


def test_quality_cannot_request_override() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT ingest.write_quality_gate_decision(
                    %s,
                    'override_pass',
                    'Integration test only'
                );
                """,
                (uuid4(),),
            )

        conn.rollback()


def test_quality_rule_registry_is_not_mutable() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                UPDATE ingest.data_quality_rule
                SET name = name
                WHERE rule_code = 'JANUS-DQ-001';
                """
            )

        conn.rollback()


def test_quality_result_history_is_not_mutable() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                UPDATE ingest.data_quality_result
                SET details = details
                WHERE false;
                """
            )

        conn.rollback()


def test_validation_issue_history_is_not_mutable() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                UPDATE ingest.validation_issue
                SET details = details
                WHERE false;
                """
            )

        conn.rollback()


def test_quality_gate_history_is_not_mutable() -> None:
    get_quality_settings.cache_clear()
    settings = get_quality_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                UPDATE ingest.quality_gate_decision
                SET decision_reason = decision_reason
                WHERE false;
                """
            )

        conn.rollback()