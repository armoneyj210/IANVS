from pathlib import Path

from janus_etl.main import main
from janus_etl.manifest import MANIFEST_FILENAME


def test_manifest_cli(
    tmp_path: Path,
    capsys,
) -> None:
    source = tmp_path / "patients.csv"

    source.write_text(
        "patient_id,name\n1,Alice\n",
        encoding="utf-8",
    )

    main(
        [
            "manifest",
            str(tmp_path),
        ]
    )

    output = capsys.readouterr().out

    assert "JANUS DATASET MANIFEST" in output
    assert "Manifest SHA256:" in output

    assert (tmp_path / MANIFEST_FILENAME).exists()
