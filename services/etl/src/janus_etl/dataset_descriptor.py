import json
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

from janus_etl.config import REPO_ROOT


class SourceSystemDescriptor(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    source_type: Literal[
        "synthetic_generator",
        "public_dataset",
        "ehr",
        "api",
        "file",
        "other",
    ]
    description: str | None = None
    base_uri: str | None = None


class DatasetDescriptor(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str
    description: str | None = None
    homepage_uri: str | None = None

    license_name: str | None = None
    license_uri: str | None = None
    usage_notes: str | None = None

    data_classification: Literal[
        "synthetic",
        "public",
        "deidentified",
        "restricted",
        "phi",
    ]

    contains_phi: bool

    review_status: Literal[
        "candidate",
        "approved",
        "rejected",
        "retired",
    ] = "candidate"


class ReleaseDescriptor(BaseModel):
    model_config = ConfigDict(extra="forbid")

    release_label: str
    source_version: str | None = None
    source_commit_sha: str | None = None

    acquisition_method: Literal[
        "generated",
        "downloaded",
        "api",
        "manual",
        "other",
    ]

    source_uri: str | None = None

    generation_parameters: dict[str, Any] = Field(default_factory=dict)

    release_metadata: dict[str, Any] = Field(default_factory=dict)


class GovernedDatasetDescriptor(BaseModel):
    model_config = ConfigDict(extra="forbid")

    descriptor_schema_version: int
    raw_directory: str

    source_system: SourceSystemDescriptor
    dataset: DatasetDescriptor
    release: ReleaseDescriptor

    def resolve_raw_directory(self) -> Path:
        path = (REPO_ROOT / self.raw_directory).resolve()

        allowed_root = (REPO_ROOT / "data" / "raw").resolve()

        if not path.is_relative_to(allowed_root):
            raise ValueError(f"Dataset raw directory must be beneath {allowed_root}")

        return path


def load_dataset_descriptor(
    descriptor_path: Path,
) -> GovernedDatasetDescriptor:
    data = json.loads(descriptor_path.read_text(encoding="utf-8"))

    return GovernedDatasetDescriptor.model_validate(data)
