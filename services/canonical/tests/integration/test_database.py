import os
from uuid import uuid4

import pytest
from psycopg.errors import (
    InsufficientPrivilege,
    RaiseException,
)

from janus_canonical.config import (
    get_settings,
)
from janus_canonical.db import (
    health_check,
    open_connection,
)

RUN_INTEGRATION_TESTS = (
    os.getenv(
        "JANUS_RUN_INTEGRATION_TESTS"
    )
    == "1"
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


def test_canonical_health_check() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    result = health_check(settings)

    assert result["database"] == "therapy"

    assert (
        result["db_principal"]
        == "janus_canonical_svc"
    )

    assert (
        result["application_name"]
        == "janus-canonical"
    )

    assert result["system_event_id"] is not None


def test_canonical_permission_boundary() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        cursor.execute(
            """
            SELECT
                session_user AS principal,

                has_schema_privilege(
                    current_user,
                    'ingest',
                    'USAGE'
                ) AS ingest_usage,

                has_table_privilege(
                    current_user,
                    'ingest.source_record',
                    'SELECT'
                ) AS source_select,

                has_table_privilege(
                    current_user,
                    'ingest.canonical_promotion_run',
                    'INSERT'
                ) AS promotion_insert,

                has_table_privilege(
                    current_user,
                    'ingest.record_lineage',
                    'INSERT'
                ) AS lineage_insert,

                has_function_privilege(
                    current_user,
                    'ingest.begin_canonical_promotion(uuid,text,text,text,text)',
                    'EXECUTE'
                ) AS begin_execute,

                has_function_privilege(
                    current_user,
                    'ingest.promote_synthea_patient_v1(uuid,uuid,text,text,text,date,date,text,text,text,text,text,text)',
                    'EXECUTE'
                ) AS patient_execute,

                has_function_privilege(
                    current_user,
                    'ingest.promote_synthea_condition_v1(uuid,uuid,text,text,text,date,date,text,text,text)',
                    'EXECUTE'
                ) AS condition_execute,

                has_function_privilege(
                    current_user,
                    'ingest.promote_synthea_medication_v1(uuid,uuid,text,text,text,timestamp with time zone,timestamp with time zone,text,text)',
                    'EXECUTE'
                ) AS medication_execute,

                has_schema_privilege(
                    current_user,
                    'clinical',
                    'USAGE'
                ) AS clinical_usage,

                has_schema_privilege(
                    current_user,
                    'governance',
                    'USAGE'
                ) AS governance_usage;
            """
        )

        permissions = cursor.fetchone()

    assert permissions is not None

    assert (
        permissions["principal"]
        == "janus_canonical_svc"
    )

    assert permissions["ingest_usage"] is True
    assert permissions["source_select"] is True

    assert (
        permissions["promotion_insert"]
        is False
    )

    assert (
        permissions["lineage_insert"]
        is False
    )

    assert permissions["begin_execute"] is True
    assert permissions["patient_execute"] is True
    assert permissions["condition_execute"] is True
    assert permissions["medication_execute"] is True
    assert permissions["clinical_usage"] is False

    assert (
        permissions["governance_usage"]
        is False
    )

def test_encounter_identifier_is_allowed_lineage_target() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        cursor.execute(
            """
            SELECT
                pg_get_constraintdef(
                    c.oid,
                    TRUE
                ) AS constraint_definition
            FROM pg_catalog.pg_constraint c
            WHERE c.conrelid =
                  'ingest.record_lineage'::regclass
              AND c.conname =
                  'record_lineage_target_table_check';
            """
        )

        constraint = cursor.fetchone()

    assert constraint is not None

    assert (
        "encounter_identifier"
        in constraint["constraint_definition"]
    )

def test_direct_clinical_read_is_denied() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(
                InsufficientPrivilege
            ),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT patient_id
                FROM clinical.patient
                LIMIT 1;
                """
            )

        conn.rollback()


def test_patient_writer_rejects_unknown_run() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(
                RaiseException,
                match=(
                    "Unknown canonical "
                    "promotion run"
                ),
            ),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT *
                FROM ingest.promote_synthea_patient_v1(
                    %s,
                    %s,
                    %s,
                    'Test',
                    'Patient',
                    '2000-01-01',
                    NULL,
                    NULL,
                    NULL,
                    'synthea-test-id',
                    NULL,
                    NULL,
                    NULL
                );
                """,
                (
                    uuid4(),
                    uuid4(),
                    "0" * 64,
                ),
            )

        conn.rollback()

def test_condition_writer_rejects_unknown_run() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(
                RaiseException,
                match=(
                    "Unknown canonical "
                    "promotion run"
                ),
            ),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT *
                FROM ingest.promote_synthea_condition_v1(
                    %s,
                    %s,
                    %s,
                    %s,
                    %s,
                    '2026-01-15',
                    NULL,
                    'http://snomed.info/sct',
                    '123456',
                    'Test condition'
                );
                """,
                (
                    uuid4(),
                    uuid4(),
                    "0" * 64,
                    str(uuid4()),
                    str(uuid4()),
                ),
            )

        conn.rollback()

def test_medication_writer_rejects_unknown_run() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with open_connection(settings) as conn:
        with (
            pytest.raises(
                RaiseException,
                match=(
                    "Unknown canonical "
                    "promotion run"
                ),
            ),
            conn.cursor() as cursor,
        ):
            cursor.execute(
                """
                SELECT *
                FROM ingest.promote_synthea_medication_v1(
                    %s,
                    %s,
                    %s,
                    %s,
                    %s,
                    '2026-01-15T12:30:45Z',
                    NULL,
                    '123456',
                    'Test medication'
                );
                """,
                (
                    uuid4(),
                    uuid4(),
                    "0" * 64,
                    str(uuid4()),
                    str(uuid4()),
                ),
            )

        conn.rollback()

@pytest.mark.skipif(
    not APPROVED_RELEASE_LABEL,
    reason=(
        "Set JANUS_TEST_APPROVED_RELEASE_LABEL "
        "to verify the canonical quality "
        "authorization prerequisite"
    ),
)
def test_enterprise_quality_gate_is_visible() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    with (
        open_connection(settings) as conn,
        conn.cursor() as cursor,
    ):
        cursor.execute(
            """
            SELECT
                q.data_quality_run_id,
                q.quality_gate_decision_id,
                q.latest_gate_decision,
                q.decided_by,
                q.gate_allows_promotion
            FROM ingest.v_quality_gate_effective_status q
            JOIN ingest.import_batch ib
              ON ib.import_batch_id =
                 q.import_batch_id
            JOIN ingest.dataset_release dr
              ON dr.dataset_release_id =
                 ib.dataset_release_id
            WHERE dr.release_label = %s
              AND q.gate_allows_promotion IS TRUE
            ORDER BY q.gate_decided_at DESC
            LIMIT 1;
            """,
            (APPROVED_RELEASE_LABEL,),
        )

        authorization = cursor.fetchone()

    assert authorization is not None

    assert (
        authorization["latest_gate_decision"]
        == "pass"
    )

    assert (
        authorization["decided_by"]
        == "janus_quality_svc"
    )

    assert (
        authorization[
            "gate_allows_promotion"
        ]
        is True
    )