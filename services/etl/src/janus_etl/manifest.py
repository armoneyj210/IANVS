import hashlib
import json
from pathlib import Path
from typing import Any

MANIFEST_SCHEMA_VERSION = 1
MANIFEST_FILENAME = "janus-manifest.json"

HASH_ALGORITHM = "sha256"

CHUNK_SIZE = 1024 * 1024


def sha256_file(path: Path) -> str:
    """Calculate SHA-256 for a file without loading it all into memory."""

    digest = hashlib.sha256()

    with path.open("rb") as file_handle:
        while chunk := file_handle.read(CHUNK_SIZE):
            digest.update(chunk)

    return digest.hexdigest()


def build_manifest(root: Path) -> dict[str, Any]:
    """
    Build a deterministic manifest for all files beneath root.

    Relative paths use POSIX separators so the manifest is
    stable across Windows/Linux environments.
    """

    root = root.resolve()

    if not root.exists():
        raise FileNotFoundError(f"Dataset root does not exist: {root}")

    if not root.is_dir():
        raise NotADirectoryError(f"Dataset root is not a directory: {root}")

    files: list[dict[str, Any]] = []

    for path in sorted(root.rglob("*")):
        if not path.is_file():
            continue

        if path.is_symlink():
            raise ValueError(f"Symbolic links are not allowed in raw datasets: {path}")

        if path.name == MANIFEST_FILENAME:
            continue

        relative_path = path.relative_to(root).as_posix()

        files.append(
            {
                "path": relative_path,
                "size_bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )

    return {
        "schema_version": MANIFEST_SCHEMA_VERSION,
        "algorithm": HASH_ALGORITHM,
        "file_count": len(files),
        "total_bytes": sum(file["size_bytes"] for file in files),
        "files": files,
    }


def canonical_manifest_bytes(
    manifest: dict[str, Any],
) -> bytes:
    """
    Serialize a manifest deterministically.

    Equivalent manifest content produces equivalent bytes.
    """

    return json.dumps(
        manifest,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def manifest_sha256(
    manifest: dict[str, Any],
) -> str:
    return hashlib.sha256(canonical_manifest_bytes(manifest)).hexdigest()


def write_manifest(
    root: Path,
) -> tuple[Path, str]:
    """
    Write the canonical Janus manifest.

    Returns:
        manifest path
        SHA-256 of the manifest itself
    """

    manifest = build_manifest(root)

    output_path = root / MANIFEST_FILENAME

    output_path.write_bytes(canonical_manifest_bytes(manifest))

    return output_path, manifest_sha256(manifest)
