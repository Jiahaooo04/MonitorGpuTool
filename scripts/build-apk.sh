#!/usr/bin/env bash
# 构建全部安卓 APK，并从最终 APK 自动生成/校验官网 version.json。
# 用法:
#   ./scripts/build-apk.sh                       # 构建 + 生成 + 复核
#   ./scripts/build-apk.sh --metadata-only       # 用已有 APK 重新生成
#   ./scripts/build-apk.sh --check-version-json  # 只校验，不改文件
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
APK_DIR="$APP_DIR/build/app/outputs/flutter-apk"
NOTES_FILE="${MONITORGPUTOOL_RELEASE_NOTES_FILE:-${RUNMON_RELEASE_NOTES_FILE:-$APP_DIR/release-notes.txt}}"
VERSION_JSON="${MONITORGPUTOOL_VERSION_JSON:-${RUNMON_VERSION_JSON:-$ROOT/site/version.json}}"
PYTHON="${PYTHON:-python3}"
MODE=build

usage() {
  sed -n '2,6p' "$0" | sed 's/^# //'
}

while (($#)); do
  case "$1" in
    --metadata-only)
      MODE=metadata
      ;;
    --check-version-json)
      MODE=check
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

export PATH="/opt/homebrew/bin:$PATH"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
# Flutter/Gradle 走直连,避开系统代理(它会拦 dl.google.com)
unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY all_proxy

if [[ "$MODE" == build ]]; then
  cd "$APP_DIR"
  echo "==> 构建三个架构分包…"
  flutter build apk --release --split-per-abi
  echo "==> 构建万能版…"
  flutter build apk --release

  echo "==> 重命名…"
  cp "$APK_DIR/app-arm64-v8a-release.apk" \
    "$APK_DIR/MonitorGpuTool-arm64.apk"   # 现代手机,装这个
  cp "$APK_DIR/app-armeabi-v7a-release.apk" \
    "$APK_DIR/MonitorGpuTool-arm32.apk"   # 老 32 位手机
  cp "$APK_DIR/app-x86_64-release.apk" \
    "$APK_DIR/MonitorGpuTool-x86.apk"     # 电脑模拟器
  cp "$APK_DIR/app-release.apk" \
    "$APK_DIR/MonitorGpuTool.apk"         # 通用版(装任何机器)
fi

APKS=(
  "$APK_DIR/MonitorGpuTool.apk"
  "$APK_DIR/MonitorGpuTool-arm64.apk"
  "$APK_DIR/MonitorGpuTool-arm32.apk"
  "$APK_DIR/MonitorGpuTool-x86.apk"
)
METADATA_ARGS=(
  --pubspec "$APP_DIR/pubspec.yaml"
  --notes-file "$NOTES_FILE"
  --output "$VERSION_JSON"
  --base-apk "$APK_DIR/MonitorGpuTool.apk"
  --update-apk "$APK_DIR/MonitorGpuTool-arm64.apk"
)
if [[ "$MODE" == check ]]; then
  METADATA_ARGS+=(--check)
  METADATA_ACTION=校验
else
  METADATA_ACTION=生成并复核
fi

echo "==> 读取最终 APK 版本并${METADATA_ACTION} version.json…"
"$PYTHON" "$ROOT/scripts/apk_release_metadata.py" \
  "${METADATA_ARGS[@]}" "${APKS[@]}"

if [[ "$MODE" == build ]]; then
  echo ""
  echo "==> 完成,可以发出去的 APK:"
  ls -lh "${APKS[@]}" | awk '{print "   " $5 "  " $9}'
  echo ""
  echo "日常手机装:MonitorGpuTool-arm64.apk(现代安卓都是 arm64)"
fi
