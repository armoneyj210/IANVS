import os

import pytest

from janus_etl.config import get_settings
from janus_etl.db import health_check, open_connection

RUN_INTEGRATION_TESTS = os.getenv("JANUS_RUN_INTEGRATION_TESTS") == "1"


pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(
        not RUN_INTEGRATION_TESTS,
        reason=("Set JANUS_RUN_INTEGRATION_TESTS=1 to run database integration tests"),
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
                    'INSERT'
                ) AS can_insert_patient,

                has_table_privilege(
                    current_user,
                    'clinical.patient',
                    'DELETE'
                ) AS can_delete_patient;
            """
        )

        permissions = cursor.fetchone()

    assert permissions is not None

    assert permissions["can_create_clinical_objects"] is False

    assert permissions["can_insert_patient"] is True

    assert permissions["can_delete_patient"] is False
