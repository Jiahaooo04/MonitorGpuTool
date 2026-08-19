#!/usr/bin/env bash
# 本地联调:起 relay + 配对 + daemon,手机与电脑同 WiFi 即可真机测试 App。
# 用法:./scripts/dev-stack.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VENV=.venv/bin
IP=$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
PORT=8080
export MONITORGPUTOOL_DATA_DIR="${MONITORGPUTOOL_DATA_DIR:-/tmp/monitorgputool-dev/data}"
export MONITORGPUTOOL_CONFIG="${MONITORGPUTOOL_CONFIG:-/tmp/monitorgputool-dev/config.toml}"
mkdir -p /tmp/monitorgputool-dev

echo "==> 启动 relay: http://$IP:$PORT (Ctrl+C 全部退出)"
$VENV/python -m runmon_relay --host 0.0.0.0 --port $PORT --db /tmp/monitorgputool-dev/relay.db &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null' EXIT
sleep 1

if ! grep -q "device_token" "$MONITORGPUTOOL_CONFIG" 2>/dev/null; then
  echo "==> 生成配对载荷(在手机 App 里粘贴):"
  $VENV/mon pair --relay "http://$IP:$PORT" --no-wait
else
  echo "==> 已配对过(如需重新配对:rm $MONITORGPUTOOL_CONFIG)"
fi

echo "==> 启动 mon daemon;另开终端跑演示任务:"
echo "    MONITORGPUTOOL_DATA_DIR=$MONITORGPUTOOL_DATA_DIR MONITORGPUTOOL_CONFIG=$MONITORGPUTOOL_CONFIG $VENV/mon demo"
$VENV/mon daemon
