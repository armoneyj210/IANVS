from janus_canonical.config import (
    CanonicalSettings,
)


def test_canonical_settings_load_from_environment(
    monkeypatch,
) -> None:
    monkeypatch.setenv(
        "JANUS_ENV",
        "test",
    )

    monkeypatch.setenv(
        "POSTGRES_HOST",
        "test-postgres",
    )

    monkeypatch.setenv(
        "POSTGRES_PORT",
        "5433",
    )

    monkeypatch.setenv(
        "POSTGRES_DB",
        "janus_test",
    )

    monkeypatch.setenv(
        "JANUS_CANONICAL_DB_USER",
        "janus_test_canonical",
    )

    monkeypatch.setenv(
        "JANUS_CANONICAL_DB_PASSWORD",
        "test-secret",
    )

    monkeypatch.setenv(
        "JANUS_CANONICAL_APPLICATION_NAME",
        "janus-canonical-test",
    )

    settings = CanonicalSettings(
        _env_file=None
    )

    assert settings.janus_env == "test"
    assert (
        settings.postgres_host
        == "test-postgres"
    )
    assert settings.postgres_port == 5433
    assert settings.postgres_db == "janus_test"

    assert (
        settings.db_user
        == "janus_test_canonical"
    )

    assert (
        settings.db_password.get_secret_value()
        == "test-secret"
    )

    assert (
        settings.application_name
        == "janus-canonical-test"
    )