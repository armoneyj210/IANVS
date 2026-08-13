import hashlib
import json
from pathlib import Path

from janus_etl.manifest import (
    MANIFEST_FILENAME,
    build_manifest,
    manifest_sha256,
    sha256_file,
    write_manifest,
)


def test_sha256_file(tmp_path: Path) -> None:
    test_file = tmp_path / "example.txt"
    test_file.write_bytes(b"abc")

    expected = hashlib.sha256(b"abc").hexdigest()

    assert sha256_file(test_file) == expected


def test_manifest_contains_expected_files(
    tmp_path: Path,
) -> None:
    first = tmp_path / "patients.csv"
    second = tmp_path / "encounters.csv"

    first.write_text(
        "patient_id,name\n1,Alice\n",
        encoding="utf-8",
    )

    second.write_text(
        "encounter_id,patient_id\n10,1\n",
        encoding="utf-8",
    )

    manifest = build_manifest(tmp_path)

    assert manifest["schema_version"] == 1
    assert manifest["algorithm"] == "sha256"
    assert manifest["file_count"] == 2

    paths = [record["path"] for record in manifest["files"]]

    assert paths == [
        "encounters.csv",
        "patients.csv",
    ]


def test_manifest_is_deterministic(
    tmp_path: Path,
) -> None:
    source = tmp_path / "patients.csv"

    source.write_text(
        "id\n1\n",
        encoding="utf-8",
    )

    first = build_manifest(tmp_path)
    second = build_manifest(tmp_path)

    assert first == second
    assert manifest_sha256(first) == manifest_sha256(second)


def test_file_change_changes_manifest_digest(
    tmp_path: Path,
) -> None:
    source = tmp_path / "patients.csv"

    source.write_text(
        "id\n1\n",
        encoding="utf-8",
    )

    first = build_manifest(tmp_path)
    first_digest = manifest_sha256(first)

    source.write_text(
        "id\n1\n2\n",
        encoding="utf-8",
    )

    second = build_manifest(tmp_path)
    second_digest = manifest_sha256(second)

    assert first_digest != second_digest


def test_generated_manifest_does_not_hash_itself(
    tmp_path: Path,
) -> None:
    source = tmp_path / "patients.csv"

    source.write_text(
        "id\n1\n",
        encoding="utf-8",
    )

    manifest_path, digest = write_manifest(tmp_path)

    assert manifest_path.name == MANIFEST_FILENAME
    assert len(digest) == 64

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    assert manifest["file_count"] == 1
    assert manifest["files"][0]["path"] == "patients.csv"

    rebuilt = build_manifest(tmp_path)

    assert rebuilt == manifest
