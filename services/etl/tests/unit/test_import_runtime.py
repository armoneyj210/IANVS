import hashlib

import pytest

from janus_etl.import_runtime import (
    _canonical_row_payload,
)


def test_canonical_row_payload_is_deterministic() -> None:
    first = {
        "B": "2",
        "A": "1",
    }

    second = {
        "A": "1",
        "B": "2",
    }

    first_payload = _canonical_row_payload(first)
    second_payload = _canonical_row_payload(second)

    assert first_payload == second_payload


def test_canonical_row_payload_has_stable_sha256() -> None:
    row = {
        "PATIENT": "patient-1",
        "CODE": "example-code",
        "VALUE": "42",
    }

    first_digest = hashlib.sha256(
        _canonical_row_payload(row)
    ).hexdigest()

    second_digest = hashlib.sha256(
        _canonical_row_payload(row)
    ).hexdigest()

    assert first_digest == second_digest
    assert len(first_digest) == 64


def test_canonical_row_payload_rejects_extra_columns() -> None:
    row = {
        "PATIENT": "patient-1",
        None: ["unexpected-value"],
    }

    with pytest.raises(
        ValueError,
        match="more values than the declared header",
    ):
        _canonical_row_payload(row)


def test_canonical_row_payload_preserves_empty_values() -> None:
    row = {
        "PATIENT": "patient-1",
        "VALUE": "",
    }

    payload = _canonical_row_payload(row)

    assert b'"VALUE":""' in payload


def test_canonical_row_payload_preserves_unicode() -> None:
    row = {
        "PATIENT": "patient-1",
        "NOTE": "caf\u00e9",
    }

    payload = _canonical_row_payload(row)

    assert "café".encode() in payload