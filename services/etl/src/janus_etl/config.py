from functools import lru_cache
from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict

REPO_ROOT = Path(__file__).resolve().parents[4]
ENV_FILE = REPO_ROOT / ".env"


class CommonSettings(BaseSettings):
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

    data_root: Path = Field(
        default=Path("data"),
        validation_alias="JANUS_DATA_ROOT",
    )

    @property
    def resolved_data_root(self) -> Path:
        if self.data_root.is_absolute():
            return self.data_root

        return REPO_ROOT / self.data_root


class Settings(CommonSettings):
    db_user: str = Field(
        validation_alias="JANUS_ETL_DB_USER",
    )

    db_password: SecretStr = Field(
        validation_alias="JANUS_ETL_DB_PASSWORD",
    )

    application_name: str = Field(
        default="janus-etl",
        validation_alias="JANUS_ETL_APPLICATION_NAME",
    )


class QualitySettings(CommonSettings):
    db_user: str = Field(
        validation_alias="JANUS_QUALITY_DB_USER",
    )

    db_password: SecretStr = Field(
        validation_alias="JANUS_QUALITY_DB_PASSWORD",
    )

    application_name: str = Field(
        default="janus-quality",
        validation_alias="JANUS_QUALITY_APPLICATION_NAME",
    )


DatabaseSettings = Settings | QualitySettings


@lru_cache
def get_settings() -> Settings:
    return Settings()


@lru_cache
def get_quality_settings() -> QualitySettings:
    return QualitySettings()