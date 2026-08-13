from pathlib import Path

from janus_etl.config import Settings


def test_settings_can_load_from_environment(
    monkeypatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setenv("JANUS_ENV", "test")
    monkeypatch.setenv("POSTGRES_HOST", "test-postgres")
    monkeypatch.setenv("POSTGRES_PORT", "5433")
    monkeypatch.setenv("POSTGRES_DB", "janus_test")

    monkeypatch.setenv(
        "JANUS_ETL_DB_USER",
        "janus_test_etl",
    )

    monkeypatch.setenv(
        "JANUS_ETL_DB_PASSWORD",
        "test-secret",
    )

    monkeypatch.setenv(
        "JANUS_ETL_APPLICATION_NAME",
        "janus-etl-test",
    )

    monkeypatch.setenv(
        "JANUS_DATA_ROOT",
        str(tmp_path),
    )

    settings = Settings()

    assert settings.janus_env == "test"
    assert settings.postgres_host == "test-postgres"
    assert settings.postgres_port == 5433
    assert settings.postgres_db == "janus_test"

    assert settings.db_user == "janus_test_etl"

    assert settings.db_password.get_secret_value() == "test-secret"

    assert settings.application_name == "janus-etl-test"

    assert settings.resolved_data_root == tmp_path
