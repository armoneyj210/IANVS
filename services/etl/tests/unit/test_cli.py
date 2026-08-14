from pathlib import Path

from janus_etl.main import build_parser, main
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

def test_import_release_command_is_registered() -> None:
    parser = build_parser()

    args = parser.parse_args(
        [
            "import-release",
            "synthea.json",
        ]
    )

    assert args.command == "import-release"
    assert args.descriptor == Path("synthea.json")

def test_register_dataset_command_is_registered() -> None:
    parser = build_parser()

    args = parser.parse_args(
        [
            "register-dataset",
            "synthea.json",
        ]
    )

    assert args.command == "register-dataset"
    assert args.descriptor == Path("synthea.json")