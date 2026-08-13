from typing import Any

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from janus_etl.config import Settings


def open_connection(settings: Settings):
    return psycopg.connect(
        host=settings.postgres_host,
        port=settings.postgres_port,
        dbname=settings.postgres_db,
        user=settings.db_user,
        password=settings.db_password.get_secret_value(),
        application_name=settings.application_name,
        connect_timeout=5,
        row_factory=dict_row,
    )


def health_check(settings: Settings) -> dict[str, Any]:
    with open_connection(settings) as conn, conn.cursor() as cursor:
        # Set Janus environment for this DB session.
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

        cursor.execute(
            """
                SELECT
                    current_database() AS database,
                    session_user AS db_principal,
                    current_setting('application_name') AS application_name,
                    version() AS postgres_version;
                """
        )

        identity = cursor.fetchone()

        event = {
            "event_type": "etl.health_check",
            "severity": "info",
            "outcome": "success",
            "component": "database",
            "message": "Janus ETL database health check succeeded",
            "metadata": {
                "database": identity["database"],
                "db_principal": identity["db_principal"],
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
            **identity,
            "system_event_id": event_result["system_event_id"],
        }
