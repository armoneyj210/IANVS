import os
from pathlib import Path

import pytest

from janus_etl.config import get_settings
from janus_etl.dataset_descriptor import (
    load_dataset_descriptor,
)
from janus_etl.import_runtime import preflight_release


RUN_INTEGRATION_TESTS = (
    os.getenv("JANUS_RUN_INTEGRATION_TESTS") == "1"
)

DATASET_DESCRIPTOR = os.getenv(
    "JANUS_TEST_DATASET_DESCRIPTOR"
)

EXPECTED_RELEASE_LABEL = (
    "synthea-v4.0.0-seed-20260813-pop100-v1"
)

EXPECTED_DATASET_RELEASE_ID = (
    "32f6e360-e3f4-4f3b-b944-738d35cafe26"
)

EXPECTED_MANIFEST_SHA256 = (
    "3fe6086f03e334e2ac3d07977ea18e0f"
    "83adba2f0b4c99b81feaaf0e90bd8704"
)

EXPECTED_FILE_COUNT = 10
EXPECTED_ROW_COUNT = 94076
EXPECTED_IMPORTABLE_FILE_COUNT = 7
EXPECTED_NON_TABULAR_FILE_COUNT = 3

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


@pytest.mark.skipif(
    not DATASET_DESCRIPTOR,
    reason=(
        "Set JANUS_TEST_DATASET_DESCRIPTOR "
        "to the governed dataset descriptor JSON"
    ),
)
def test_registered_synthea_release_preflight() -> None:
    get_settings.cache_clear()
    settings = get_settings()

    descriptor_path = Path(DATASET_DESCRIPTOR)

    assert descriptor_path.exists()
    assert descriptor_path.is_file()

    descriptor = load_dataset_descriptor(
        descriptor_path
    )

    assert (
        descriptor.release.release_label
        == EXPECTED_RELEASE_LABEL
    )

    result = preflight_release(
        settings,
        descriptor,
    )

    assert (
        str(
            result["release"][
                "dataset_release_id"
            ]
        )
        == EXPECTED_DATASET_RELEASE_ID
    )

    assert (
        result["manifest_sha256"]
        == EXPECTED_MANIFEST_SHA256
    )

    assert (
        len(result["source_files"])
        == EXPECTED_FILE_COUNT
    )

    assert (
        result["expected_rows"]
        == EXPECTED_ROW_COUNT
    )

    assert (
    result["verified_artifact_count"]
    == EXPECTED_FILE_COUNT
    )

    assert (
        result["importable_file_count"]
        == EXPECTED_IMPORTABLE_FILE_COUNT
    )

    assert (
        result["non_tabular_file_count"]
        == EXPECTED_NON_TABULAR_FILE_COUNT
    )

    assert (
        len(result["importable_source_files"])
        == EXPECTED_IMPORTABLE_FILE_COUNT
    )

    assert (
        len(result["verified_non_tabular_files"])
        == EXPECTED_NON_TABULAR_FILE_COUNT
    )

    raw_directory = result["raw_directory"]

    assert raw_directory.exists()
    assert raw_directory.is_dir()

    for source_file in result["source_files"]:
        source_path = (
            raw_directory
            / source_file["relative_path"]
        )

        assert source_path.exists()
        assert source_path.is_file()