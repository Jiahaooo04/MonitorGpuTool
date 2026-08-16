#!/usr/bin/env python3
"""Validate final APK versions and generate the app update manifest."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


DEFAULT_DOWNLOAD_URL = (
    "https://runmon.linxiexie.com/downloads/RunMon-arm64.apk"
)


class MetadataError(RuntimeError):
    pass


def _parse_pubspec_version(path: Path) -> tuple[str, int]:
    match = re.search(
        r"^version:\s*[\"']?([^+\"'\s]+)\+(\d+)[\"']?\s*$",
        path.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )
    if not match:
        raise MetadataError(f"无法读取 {path} 中的 version: x.y.z+code")
    return match.group(1), int(match.group(2))


def _find_apkanalyzer(explicit: str | None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    if os.environ.get("APKANALYZER"):
        candidates.append(Path(os.environ["APKANALYZER"]).expanduser())
    on_path = shutil.which("apkanalyzer")
    if on_path:
        candidates.append(Path(on_path))

    sdk_roots = [
        os.environ.get("ANDROID_SDK_ROOT"),
        os.environ.get("ANDROID_HOME"),
        str(Path.home() / "Library/Android/sdk"),
    ]
    for root_value in sdk_roots:
        if not root_value:
            continue
        root = Path(root_value).expanduser()
        candidates.append(root / "cmdline-tools/latest/bin/apkanalyzer")
        candidates.extend(
            sorted(
                root.glob("cmdline-tools/*/bin/apkanalyzer"),
                reverse=True,
            )
        )

    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise MetadataError(
        "找不到 apkanalyzer；请安装 Android SDK cmdline-tools，"
        "或通过 APKANALYZER/--apkanalyzer 指定路径"
    )


def _read_apk_field(analyzer: Path, apk: Path, field: str) -> str:
    if not apk.is_file():
        raise MetadataError(f"找不到最终 APK：{apk}")
    try:
        result = subprocess.run(
            [str(analyzer), "manifest", field, str(apk)],
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise MetadataError(f"读取 {apk.name} 元数据失败：{exc}") from exc
    value = result.stdout.strip()
    if result.returncode != 0 or not value:
        detail = result.stderr.strip() or f"退出码 {result.returncode}"
        raise MetadataError(f"读取 {apk.name} 的 {field} 失败：{detail}")
    return value


def _read_apk_version(analyzer: Path, apk: Path) -> tuple[str, int]:
    version_name = _read_apk_field(analyzer, apk, "version-name")
    raw_code = _read_apk_field(analyzer, apk, "version-code")
    try:
        version_code = int(raw_code)
    except ValueError as exc:
        raise MetadataError(
            f"{apk.name} 的 versionCode 不是整数：{raw_code}"
        ) from exc
    return version_name, version_code


def _expected_payload(args: argparse.Namespace) -> dict[str, object]:
    analyzer = _find_apkanalyzer(args.apkanalyzer)
    apk_versions = {
        Path(apk): _read_apk_version(analyzer, Path(apk))
        for apk in args.apks
    }
    unique_version_names = {version[0] for version in apk_versions.values()}
    if len(unique_version_names) != 1:
        detail = "，".join(
            f"{apk.name}={name}+{code}"
            for apk, (name, code) in apk_versions.items()
        )
        raise MetadataError(f"APK versionName 不一致：{detail}")

    base_apk = Path(args.base_apk)
    update_apk = Path(args.update_apk)
    if base_apk not in apk_versions:
        raise MetadataError(f"基础 APK 不在发布列表中：{base_apk}")
    if update_apk not in apk_versions:
        raise MetadataError(f"更新 APK 不在发布列表中：{update_apk}")

    apk_version = next(iter(unique_version_names))
    base_version, base_code = apk_versions[base_apk]
    update_version, update_code = apk_versions[update_apk]
    pubspec_version, pubspec_code = _parse_pubspec_version(Path(args.pubspec))
    if (base_version, base_code) != (pubspec_version, pubspec_code):
        raise MetadataError(
            "基础 APK 与 pubspec.yaml 版本不一致："
            f"{base_apk.name}={base_version}+{base_code}，"
            f"pubspec.yaml={pubspec_version}+{pubspec_code}"
        )
    if update_version != apk_version:
        raise MetadataError(
            f"更新 APK versionName 不一致：{update_apk.name}={update_version}"
        )

    notes = Path(args.notes_file).read_text(encoding="utf-8").strip()
    if not notes:
        raise MetadataError(f"更新说明为空：{args.notes_file}")
    return {
        "version": apk_version,
        "versionCode": update_code,
        "notes": notes,
        "url": args.url,
    }


def _write_payload(output: Path, payload: dict[str, object]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(f"{output.suffix}.tmp")
    temporary.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(output)


def _check_payload(output: Path, expected: dict[str, object]) -> None:
    if not output.is_file():
        raise MetadataError(f"version.json 不存在：{output}")
    try:
        actual = json.loads(output.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MetadataError(f"version.json 无法读取：{exc}") from exc
    if actual != expected:
        raise MetadataError("version.json 与最终 APK 不一致")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="从最终 APK 读取版本并生成/校验 version.json"
    )
    parser.add_argument("--apkanalyzer", help="apkanalyzer 可执行文件路径")
    parser.add_argument("--pubspec", required=True, help="Flutter pubspec.yaml")
    parser.add_argument("--notes-file", required=True, help="更新说明文本文件")
    parser.add_argument("--output", required=True, help="version.json 输出路径")
    parser.add_argument("--url", default=DEFAULT_DOWNLOAD_URL, help="APK 下载地址")
    parser.add_argument(
        "--base-apk",
        required=True,
        help="用于核对 pubspec build number 的万能 APK",
    )
    parser.add_argument(
        "--update-apk",
        required=True,
        help="更新地址实际下载的 APK；versionCode 以它为准",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="只校验现有 version.json，不改写文件",
    )
    parser.add_argument("apks", nargs="+", help="最终发布的 APK 文件")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        payload = _expected_payload(args)
        output = Path(args.output)
        if args.check:
            _check_payload(output, payload)
            action = "校验通过"
        else:
            _write_payload(output, payload)
            _check_payload(output, payload)
            action = "已生成并复核"
        print(
            f"==> {action}：{output} "
            f"(v{payload['version']}, versionCode {payload['versionCode']})"
        )
        return 0
    except (MetadataError, OSError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
