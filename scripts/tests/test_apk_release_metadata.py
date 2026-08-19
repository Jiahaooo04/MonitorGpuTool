from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "apk_release_metadata.py"
BUILD_SCRIPT = Path(__file__).parents[1] / "build-apk.sh"


def _write_fake_apkanalyzer(
    path: Path,
    *,
    second_version: str = "1.0.7",
) -> None:
    path.write_text(
        "#!/bin/sh\n"
        'if [ "$1" != "manifest" ]; then exit 2; fi\n'
        'name="$(basename "$3")"\n'
        'case "$2" in\n'
        '  version-name)\n'
        f'    if [ "$name" = "second.apk" ]; then echo "{second_version}"; '
        'else echo "1.0.7"; fi ;;\n'
        '  version-code)\n'
        '    case "$name" in\n'
        '      first.apk|MonitorGpuTool.apk) echo "6" ;;\n'
        '      second.apk|MonitorGpuTool-arm64.apk) echo "2006" ;;\n'
        '      MonitorGpuTool-arm32.apk) echo "1006" ;;\n'
        '      MonitorGpuTool-x86.apk) echo "4006" ;;\n'
        '      *) exit 2 ;;\n'
        '    esac ;;\n'
        "  *) exit 2 ;;\n"
        "esac\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def _fixture(
    tmp_path: Path,
    *,
    second_version: str = "1.0.7",
) -> dict[str, Path]:
    pubspec = tmp_path / "pubspec.yaml"
    pubspec.write_text("name: MonitorGpuTool_app\nversion: 1.0.7+6\n", encoding="utf-8")
    notes = tmp_path / "release-notes.txt"
    notes.write_text("· 新增 AI 报错总结\n· 新增 GPU 占用进程详情\n", encoding="utf-8")
    first_apk = tmp_path / "first.apk"
    second_apk = tmp_path / "second.apk"
    first_apk.touch()
    second_apk.touch()
    analyzer = tmp_path / "apkanalyzer"
    _write_fake_apkanalyzer(analyzer, second_version=second_version)
    return {
        "pubspec": pubspec,
        "notes": notes,
        "first_apk": first_apk,
        "second_apk": second_apk,
        "analyzer": analyzer,
        "output": tmp_path / "version.json",
    }


def _run(paths: dict[str, Path], *extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--apkanalyzer",
            str(paths["analyzer"]),
            "--pubspec",
            str(paths["pubspec"]),
            "--notes-file",
            str(paths["notes"]),
            "--output",
            str(paths["output"]),
            "--url",
            "https://example.test/MonitorGpuTool-arm64.apk",
            "--base-apk",
            str(paths["first_apk"]),
            "--update-apk",
            str(paths["second_apk"]),
            *extra,
            str(paths["first_apk"]),
            str(paths["second_apk"]),
        ],
        text=True,
        capture_output=True,
        check=False,
    )


def test_uses_real_version_code_from_the_update_apk(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)

    result = _run(paths)

    assert result.returncode == 0, result.stderr
    assert json.loads(paths["output"].read_text(encoding="utf-8")) == {
        "version": "1.0.7",
        "versionCode": 2006,
        "notes": "· 新增 AI 报错总结\n· 新增 GPU 占用进程详情",
        "url": "https://example.test/MonitorGpuTool-arm64.apk",
    }


def test_rejects_apks_with_different_version_names(tmp_path: Path) -> None:
    paths = _fixture(tmp_path, second_version="1.0.8")

    result = _run(paths)

    assert result.returncode != 0
    assert "APK versionName 不一致" in result.stderr
    assert not paths["output"].exists()


def test_rejects_apk_that_does_not_match_pubspec(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    paths["pubspec"].write_text(
        "name: MonitorGpuTool_app\nversion: 1.0.7+5\n", encoding="utf-8"
    )

    result = _run(paths)

    assert result.returncode != 0
    assert "pubspec.yaml" in result.stderr
    assert not paths["output"].exists()


def test_check_mode_rejects_stale_version_json(tmp_path: Path) -> None:
    paths = _fixture(tmp_path)
    stale = {
        "version": "1.0.6",
        "versionCode": 5,
        "notes": "旧内容",
        "url": "https://example.test/MonitorGpuTool-arm64.apk",
    }
    paths["output"].write_text(
        json.dumps(stale, ensure_ascii=False), encoding="utf-8"
    )

    result = _run(paths, "--check")

    assert result.returncode != 0
    assert "version.json 与最终 APK 不一致" in result.stderr
    assert json.loads(paths["output"].read_text(encoding="utf-8")) == stale


def test_build_script_metadata_only_generates_manifest_without_flutter(
    tmp_path: Path,
) -> None:
    project = tmp_path / "project"
    scripts = project / "scripts"
    app = project / "app"
    apk_dir = app / "build/app/outputs/flutter-apk"
    site = project / "site"
    scripts.mkdir(parents=True)
    apk_dir.mkdir(parents=True)
    site.mkdir()
    shutil.copy2(BUILD_SCRIPT, scripts / "build-apk.sh")
    shutil.copy2(SCRIPT, scripts / "apk_release_metadata.py")
    (app / "pubspec.yaml").write_text(
        "name: MonitorGpuTool_app\nversion: 1.0.7+6\n", encoding="utf-8"
    )
    (app / "release-notes.txt").write_text(
        "· 更新通知内容", encoding="utf-8"
    )
    for name in (
        "MonitorGpuTool.apk",
        "MonitorGpuTool-arm64.apk",
        "MonitorGpuTool-arm32.apk",
        "MonitorGpuTool-x86.apk",
    ):
        (apk_dir / name).touch()
    analyzer = tmp_path / "apkanalyzer"
    _write_fake_apkanalyzer(analyzer)

    env = dict(os.environ)
    env["APKANALYZER"] = str(analyzer)
    result = subprocess.run(
        ["bash", str(scripts / "build-apk.sh"), "--metadata-only"],
        text=True,
        capture_output=True,
        env=env,
        timeout=30,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads((site / "version.json").read_text(encoding="utf-8"))[
        "versionCode"
    ] == 2006

