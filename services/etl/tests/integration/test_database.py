import os

import pytest
from psycopg.errors import InsufficientPrivilege

from janus_etl.config import get_settings
from janus_etl.db import health_check, open_connection

RUN_INTEGRATION_TESTS = os.getenv("JANUS_RUN_INTEGRATION_TESTS") == "1"
APPROVED_RELEASE_LABEL = os.getenv("JANUS_TEST_APPROVED_RELEASE_LABEL")

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


def test_etl_health_check() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    result = health_check(settings)

    assert result["database"] == "therapy"
    assert result["db_principal"] == "janus_etl_svc"
    assert result["application_name"] == "janus-etl"
    assert result["system_event_id"] is not None


def test_etl_permission_boundary() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        cursor.execute(
            """
            SELECT
                has_schema_privilege(
                    current_user,
                    'clinical',
                    'CREATE'
                ) AS can_create_clinical_objects,

                has_table_privilege(
                    current_user,
                    'clinical.patient',
                    'SELECT'
                ) AS can_select_patient,

                has_table_privilege(
                    current_user,
                    'clinical.patient',
                    'INSERT'
                ) AS can_insert_patient,

                has_table_privilege(
                    current_user,
                    'ingest.source_record',
                    'INSERT'
                ) AS can_insert_source_record,

                has_table_privilege(
                    current_user,
                    'ingest.source_record',
                    'UPDATE'
                ) AS can_update_source_record,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_run',
                    'INSERT'
                ) AS can_insert_quality_run,

                has_table_privilege(
                    current_user,
                    'ingest.data_quality_result',
                    'INSERT'
                ) AS can_insert_quality_result,

                has_table_privilege(
                    current_user,
                    'ingest.quality_gate_decision',
                    'INSERT'
                ) AS can_insert_gate_decision;
            """
        )

        permissions = cursor.fetchone()

    assert permissions is not None
    assert permissions["can_create_clinical_objects"] is False
    assert permissions["can_select_patient"] is True
    assert permissions["can_insert_patient"] is False

    assert permissions["can_insert_source_record"] is True
    assert permissions["can_update_source_record"] is False

    assert permissions["can_insert_quality_run"] is False
    assert permissions["can_insert_quality_result"] is False
    assert permissions["can_insert_gate_decision"] is False


def test_etl_cannot_call_quality_gate_writer() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT ingest.write_quality_gate_decision(
                    %s::uuid,
                    'pass',
                    'ETL must not certify quality'
                );
                """,
                ("00000000-0000-0000-0000-000000000000",),
            )

        conn.rollback()


def test_etl_governance_boundary() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with open_connection(settings) as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT has_schema_privilege(
                    current_user,
                    'governance',
                    'USAGE'
                ) AS can_use_governance;
                """
            )

            permissions = cursor.fetchone()

        assert permissions is not None
        assert permissions["can_use_governance"] is False

        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT 1
                FROM governance.dataset_review
                LIMIT 1;
                """
            )

        conn.rollback()

        with (
            pytest.raises(InsufficientPrivilege),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT 1
                FROM governance.dataset_decision
                LIMIT 1;
                """
            )

        conn.rollback()


@pytest.mark.skipif(
    not APPROVED_RELEASE_LABEL,
    reason=(
        "Set JANUS_TEST_APPROVED_RELEASE_LABEL "
        "to test an approved dataset release"
    ),
)
def test_approved_release_passes_import_gate() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with open_connection(settings) as conn:
        with conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT dataset_release_id
                FROM ingest.dataset_release
                WHERE release_label = %s;
                """,
                (APPROVED_RELEASE_LABEL,),
            )

            release = cursor.fetchone()

            assert release is not None

            cursor.execute(
                """
                INSERT INTO ingest.import_batch (
                    dataset_release_id,
                    status,
                    environment,
                    etl_name,
                    etl_version,
                    initiated_by,
                    started_at
                )
                VALUES (
                    %s,
                    'running',
                    %s,
                    'janus-etl-test',
                    'test',
                    current_user,
                    clock_timestamp()
                )
                RETURNING
                    import_batch_id,
                    status;
                """,
                (
                    release["dataset_release_id"],
                    settings.janus_env,
                ),
            )

            batch = cursor.fetchone()

            assert batch is not None
            assert batch["status"] == "running"

        conn.rollback()