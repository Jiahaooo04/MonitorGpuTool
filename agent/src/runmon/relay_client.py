"""mon daemon:与 relay 的 WSS 长连,加密同步任务状态,接收白名单指令。"""
from __future__ import annotations

import asyncio
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import psutil

from . import __version__, sampler
from .config import Config
from .crypto import decrypt, encrypt, key_from_b64
from .store import RunStore

TAIL_WINDOW = 8192          # 同步给手机的输出尾窗(字符)
SYNC_INTERVAL = 1.0
HEARTBEAT_INTERVAL = 10.0
PERMANENT_MUTE = 4102444800.0   # 2100-01-01,视作"永久"
LLM_PROVIDERS = {"deepseek", "openai", "qwen", "kimi", "ollama", "custom"}


def run_snapshot(store: RunStore) -> list[dict]:
    return [{"id": r.id, "name": r.name, "status": r.status, "progress": r.progress,
             "eta_seconds": r.eta_seconds, "last_loss": r.last_loss,
             "started_at": r.started_at, "ended_at": r.ended_at,
             "exit_code": r.exit_code, "muted_until": r.muted_until,
             "shutdown_after": r.shutdown_after}
            for r in store.list_runs(limit=50)]


class SyncState:
    def __init__(self) -> None:
        self.last_snapshot_json = ""
        self.tail_lengths: dict[str, int] = {}
        self.last_event_id = 0


def compute_sync_messages(store: RunStore, state: SyncState, key: bytes,
                          now: float | None = None) -> list[dict]:
    """diff 本地 store,产出需要发给 relay 的消息(纯函数,可单测)。"""
    msgs: list[dict] = []
    snap = run_snapshot(store)
    snap_json = json.dumps(snap, sort_keys=True)
    if snap_json != state.last_snapshot_json:
        state.last_snapshot_json = snap_json
        payload = {"runs": snap}
        if now is not None:
            payload["server_now"] = now  # App 用它校准与服务器的时钟偏差
        msgs.append({"t": "snapshot", "enc": encrypt(payload, key)})
    for r in store.list_runs(limit=50):
        if state.tail_lengths.get(r.id) != r.output_length:
            state.tail_lengths[r.id] = r.output_length
            msgs.append({"t": "tail", "run": r.id,
                         "enc": encrypt({"run_id": r.id, "tail": r.output_tail[-TAIL_WINDOW:],
                                         "len": r.output_length}, key)})
    for row in store.events_since(state.last_event_id):
        state.last_event_id = row["id"]
        if row["payload"]:
            msgs.append({"t": "event", "enc": encrypt(json.loads(row["payload"]), key)})
    return msgs


def heartbeat_payload() -> dict:
    gpu_samples = sampler.sample_gpus()
    processes = sampler.sample_processes({
        pid for gpu in gpu_samples for pid in gpu.pids
    })
    gpus = []
    for gpu in gpu_samples:
        process_rows = []
        for pid, gpu_mem_mb in sorted(gpu.pids.items()):
            process = processes.get(pid)
            if process is None:
                continue
            process_rows.append({
                "pid": process.pid,
                "user": process.user,
                "name": process.name,
                "cpu_pct": process.cpu_pct,
                "mem_used_mb": process.mem_used_mb,
                "mem_pct": process.mem_pct,
                "gpu_mem_mb": gpu_mem_mb,
            })
        gpus.append({
            "index": gpu.index,
            "util": gpu.util_pct,
            "mem_used": gpu.mem_used_mb,
            "mem_total": gpu.mem_total_mb,
            "temp": gpu.temp_c,
            "processes": process_rows,
        })
    return {"gpus": gpus, "cpu": psutil.cpu_percent(interval=None),
            "mem": psutil.virtual_memory().percent,
            "disk": [{"mount": m, "used_pct": p} for m, p in sampler.disk_usage()],
            "ts": time.time()}


def _tail_file(path: str, lines: int) -> str:
    with open(path, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 256 * 1024))
        data = f.read().decode("utf-8", errors="replace")
    return "\n".join(data.replace("\r", "\n").splitlines()[-lines:])


def _rerun(run) -> dict:
    env = dict(os.environ)
    try:
        env_path = Path(run.log_path).parent / f"{run.id}.env.json"
        if env_path.exists():
            env = json.loads(env_path.read_text(encoding="utf-8"))
    except Exception:
        pass
    cmd = [sys.executable, "-m", "runmon", "run",
           "--name", f"{run.name}-rerun", "--"] + shlex.split(run.command)
    subprocess.Popen(cmd, cwd=run.cwd or None, env=env, start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     stdin=subprocess.DEVNULL)
    return {"ok": True, "op": "rerun", "run_id": run.id}


def _infer_llm_provider(base_url: str) -> str:
    host = (urlparse(base_url).hostname or "").lower()
    if "deepseek" in host:
        return "deepseek"
    if "openai.com" in host:
        return "openai"
    if "dashscope" in host or "aliyuncs.com" in host:
        return "qwen"
    if "moonshot" in host or "kimi" in host:
        return "kimi"
    if host in {"127.0.0.1", "localhost", "::1"}:
        return "ollama"
    return "custom"


def _public_llm_config(config: dict, op: str) -> dict:
    base_url = str(config.get("base_url", "")).strip()
    env_name = str(config.get("api_key_env", "")).strip()
    return {
        "ok": True,
        "op": op,
        "enabled": bool(config.get("enabled", False)),
        "provider": str(
            config.get("provider") or _infer_llm_provider(base_url)
        ),
        "base_url": base_url,
        "model": str(config.get("model", "")).strip(),
        "api_key_set": bool(str(config.get("api_key", "")).strip())
        or bool(env_name and os.environ.get(env_name)),
    }


def _merge_llm_config(
    current: dict, args: dict, *, force_enabled: bool = False
) -> tuple[dict | None, str | None]:
    config = dict(current)
    provider = str(args.get("provider", config.get("provider", "custom"))).strip()
    if provider not in LLM_PROVIDERS:
        return None, "不支持的供应商"

    base_url = str(args.get("base_url", config.get("base_url", ""))).strip()
    model = str(args.get("model", config.get("model", ""))).strip()
    enabled = True if force_enabled else bool(args.get(
        "enabled", config.get("enabled", False)
    ))
    if enabled or base_url or model:
        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            return None, "接口地址必须是有效的 http/https URL"
        if len(base_url) > 2048:
            return None, "接口地址过长"
        if not model:
            return None, "请选择或填写模型"
        if len(model) > 160:
            return None, "模型名称过长"

    config.update({
        "enabled": enabled,
        "provider": provider,
        "base_url": base_url.rstrip("/"),
        "model": model,
    })
    api_key = str(args.get("api_key", "")).strip()
    if len(api_key) > 4096:
        return None, "API Key 过长"
    if args.get("clear_api_key") is True:
        config.pop("api_key", None)
    elif api_key:
        config["api_key"] = api_key
    return config, None


def handle_command(store: RunStore, cmd: dict) -> dict:
    """白名单指令执行。指令是语义枚举,app 无法下发任意 shell。"""
    op = cmd.get("op")
    run_id = str(cmd.get("run_id", ""))
    args = cmd.get("args") or {}
    run = store.resolve_run(run_id) if run_id else None
    if op == "stop":
        from .cli import stop_run
        ok = stop_run(store, run_id)
        return {"ok": ok, "op": op, "run_id": run_id}
    if op == "tail":
        if run is None or not run.log_path or not os.path.exists(run.log_path):
            return {"ok": False, "op": op, "error": "log not found"}
        text = _tail_file(run.log_path, int(args.get("lines", 100)))
        return {"ok": True, "op": op, "run_id": run.id, "tail": text}
    if op == "mute":
        if run is None:
            return {"ok": False, "op": op, "error": "run not found"}
        hours = float(args.get("hours", 8))
        until = time.time() + hours * 3600 if hours > 0 else PERMANENT_MUTE
        store.update_run(run.id, muted_until=until)
        return {"ok": True, "op": op, "run_id": run.id, "muted_until": until}
    if op == "shutdown_after":
        if run is None:
            return {"ok": False, "op": op, "error": "run not found"}
        enabled = 1 if args.get("enabled") else 0
        store.update_run(run.id, shutdown_after=enabled)
        return {"ok": True, "op": op, "run_id": run.id, "shutdown_after": enabled}
    if op == "rerun":
        if run is None:
            return {"ok": False, "op": op, "error": "run not found"}
        return _rerun(run)
    if op == "delete_run":
        if run is None:
            return {"ok": False, "op": op, "error": "run not found"}
        if run.status == "running":
            return {"ok": False, "op": op, "error": "任务运行中,先停止再删除"}
        for p in ([run.log_path] if run.log_path else []):
            for f in (Path(p), Path(p).parent / f"{run.id}.env.json"):
                try:
                    f.unlink()
                except OSError:
                    pass
        store.delete_run(run.id)
        return {"ok": True, "op": op, "run_id": run.id}
    if op == "config_set":
        # 白名单配置项:目前只放开磁盘告警阈值
        try:
            pct = int(args.get("disk_threshold_pct"))
        except (TypeError, ValueError):
            return {"ok": False, "op": op, "error": "invalid disk_threshold_pct"}
        if not 50 <= pct <= 99:
            return {"ok": False, "op": op, "error": "阈值需在 50–99 之间"}
        cfg = Config.load()
        cfg.disk_threshold_pct = pct
        cfg.save()
        return {"ok": True, "op": op, "disk_threshold_pct": pct}
    if op == "llm_config_get":
        return _public_llm_config(Config.load().llm, op)
    if op in {"llm_config_set", "llm_test"}:
        cfg = Config.load()
        llm, error = _merge_llm_config(
            cfg.llm, args, force_enabled=op == "llm_test"
        )
        if error is not None or llm is None:
            return {"ok": False, "op": op, "error": error or "配置无效"}
        if op == "llm_test":
            from .llm_summary import LLMSummarizer
            result = LLMSummarizer(llm).test_connection()
            return {"op": op, **result}
        cfg.llm = llm
        cfg.save()
        return _public_llm_config(llm, op)
    if op == "gpu_watch_set":
        from .gpuwait import set_watch
        return {"op": op, **set_watch(args)}
    if op == "gpu_watch_cancel":
        from .gpuwait import clear_watch
        clear_watch()
        return {"ok": True, "op": op}
    return {"ok": False, "error": f"unknown op: {op}"}


class Daemon:
    def __init__(self, store: RunStore | None = None, config: Config | None = None) -> None:
        self.config = config or Config.load()
        relay = self.config.relay
        if not (relay.get("url") and relay.get("device_token") and relay.get("key")):
            raise SystemExit("relay 未配置。先运行:mon pair --relay <URL>")
        self.store = store or RunStore()
        self.key = key_from_b64(relay["key"])
        self.url = relay["url"].rstrip("/")
        self.device_id = relay["device_id"]
        self.token = relay["device_token"]
        self._pty = None
        self._ws = None
        self._sync_state = SyncState()  # 跨重连保留,避免重发全部历史事件
        # daemon 重启只同步新事件:重放历史会让手机炸通知,还会被 MIUI 判为骚扰降级
        self._sync_state.last_event_id = self.store.max_event_id()
        from .gpuwait import GpuWatchManager
        self._watch_mgr = GpuWatchManager(self.store, self.config)

    def _heartbeat(self) -> dict:
        """心跳 + 蹲卡评估共用同一次 GPU 采样。"""
        hb = heartbeat_payload()
        try:
            st = self._watch_mgr.poll(hb["gpus"])
            if st is not None:
                hb["gpu_watch"] = st
        except Exception:
            pass  # 蹲卡故障不影响心跳
        return hb

    def ws_url(self) -> str:
        u = self.url.replace("https://", "wss://").replace("http://", "ws://")
        return u + "/ws/agent"

    async def run_forever(self) -> None:
        import websockets
        backoff = 1.0
        while True:
            try:
                # proxy=None:绕过系统代理直连 relay——代理常会剥掉 WebSocket 升级头导致 404
                async with websockets.connect(
                        self.ws_url(), proxy=None,
                        additional_headers={"Authorization": f"Bearer {self.token}",
                                            "X-Device": self.device_id,
                                            "User-Agent": f"runmon/{__version__}"}) as ws:
                    backoff = 1.0
                    self._ws = ws
                    print(f"[mon daemon] 已连接 {self.url}")
                    await asyncio.gather(self._reader(ws), self._sync_loop(ws))
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                print(f"[mon daemon] 连接断开:{exc};{backoff:.0f}s 后重连")
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60.0)
            finally:
                self._ws = None
                self._close_pty()

    async def _reader(self, ws) -> None:
        async for raw in ws:
            try:
                msg = json.loads(raw)
                t = msg.get("t")
                if t == "cmd":
                    cmd = decrypt(msg["enc"], self.key)
                    result = await asyncio.to_thread(handle_command, self.store, cmd)
                    await ws.send(json.dumps({"t": "cmd_result",
                                              "cmd_id": msg.get("cmd_id"),
                                              "enc": encrypt(result, self.key)}))
                elif t and t.startswith("term_"):
                    await self._handle_term(ws, t, msg)
            except Exception as exc:
                print(f"[mon daemon] 指令处理失败:{exc}")

    async def _handle_term(self, ws, t: str, msg: dict) -> None:
        if t == "term_open":
            if not self.config.enable_terminal:
                await ws.send(json.dumps({"t": "term_output",
                    "enc": encrypt({"data": "\r\n[RunMon] 交互终端未启用。"
                        "在服务器 config.toml 设 enable_terminal = true 并重启 mon daemon。\r\n"},
                        self.key)}))
                return
            from .terminal import PtyShell
            self._close_pty()
            payload = decrypt(msg["enc"], self.key) if "enc" in msg else {}
            loop = asyncio.get_running_loop()

            def on_output(data: str) -> None:
                # pty 读线程在 loop 线程内(add_reader),可直接调度发送
                asyncio.run_coroutine_threadsafe(
                    ws.send(json.dumps({"t": "term_output",
                                        "enc": encrypt({"data": data}, self.key)})),
                    loop)

            self._pty = PtyShell(on_output)
            self._pty.open(loop, rows=int(payload.get("rows", 24)),
                           cols=int(payload.get("cols", 80)),
                           cwd=payload.get("cwd") or None)
        elif t == "term_input" and self._pty and self._pty.alive:
            self._pty.write(decrypt(msg["enc"], self.key).get("data", ""))
        elif t == "term_resize" and self._pty and self._pty.alive:
            p = decrypt(msg["enc"], self.key)
            self._pty.resize(int(p.get("rows", 24)), int(p.get("cols", 80)))
        elif t == "term_close":
            self._close_pty()

    def _close_pty(self) -> None:
        if self._pty is not None:
            self._pty.close()
            self._pty = None

    async def _sync_loop(self, ws) -> None:
        state = self._sync_state
        last_hb = 0.0
        last_prune = 0.0
        while True:
            try:  # L6: sqlite 瞬时锁等错误不该炸掉整条连接
                msgs = await asyncio.to_thread(
                    compute_sync_messages, self.store, state, self.key, time.time())
            except Exception:
                msgs = []
            if time.time() - last_prune > 3600:  # 每小时清理老 outbox/events
                last_prune = time.time()
                try:
                    await asyncio.to_thread(self.store.prune_old, time.time())
                except Exception:
                    pass
            for m in msgs:
                await ws.send(json.dumps(m))
            if time.time() - last_hb >= HEARTBEAT_INTERVAL:
                last_hb = time.time()
                hb = await asyncio.to_thread(self._heartbeat)
                await ws.send(json.dumps({"t": "hb", "enc": encrypt(hb, self.key)}))
            await asyncio.sleep(SYNC_INTERVAL)
