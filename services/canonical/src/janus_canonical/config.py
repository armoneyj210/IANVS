from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[4]
ENV_FILE = REPO_ROOT / ".env"


class CanonicalSettings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=ENV_FILE,
        env_file_encoding="utf-8",
        extra="ignore",
    )

    janus_env: Literal[
        "development",
        "test",
        "staging",
        "production",
    ] = Field(
        default="development",
        validation_alias="JANUS_ENV",
    )

    postgres_host: str = Field(
        default="localhost",
        validation_alias="POSTGRES_HOST",
    )

    postgres_port: int = Field(
        default=5432,
        validation_alias="POSTGRES_PORT",
    )

    postgres_db: str = Field(
        default="therapy",
        validation_alias="POSTGRES_DB",
    )

    db_user: str = Field(
        validation_alias="JANUS_CANONICAL_DB_USER",
    )

    db_password: SecretStr = Field(
        validation_alias="JANUS_CANONICAL_DB_PASSWORD",
    )

    application_name: str = Field(
        default="janus-canonical",
        validation_alias=(
            "JANUS_CANONICAL_APPLICATION_NAME"
        ),
    )


@lru_cache
def get_settings() -> CanonicalSettings:
    return CanonicalSettings()