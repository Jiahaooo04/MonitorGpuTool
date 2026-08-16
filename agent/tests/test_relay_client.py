import json
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest

from runmon import relay_client, sampler
from runmon.crypto import decrypt, generate_key
from runmon.relay_client import SyncState, compute_sync_messages, handle_command, heartbeat_payload
from runmon.sampler import GpuSample
from runmon.store import RunStore


@pytest.fixture()
def store(tmp_path, monkeypatch):
    monkeypatch.setenv("RUNMON_DATA_DIR", str(tmp_path / "data"))
    return RunStore(tmp_path / "t.db")


KEY = generate_key()


def test_sync_first_pass_sends_snapshot_and_tail(store):
    run = store.create_run(name="train", command="c", cwd="", log_path="")
    store.append_output(run.id, "hello\n", max_tail_chars=1000)
    state = SyncState()
    msgs = compute_sync_messages(store, state, KEY)
    types = [m["t"] for m in msgs]
    assert types == ["snapshot", "tail"]
    snap = decrypt(msgs[0]["enc"], KEY)
    assert snap["runs"][0]["name"] == "train"
    tail = decrypt(msgs[1]["enc"], KEY)
    assert tail["tail"] == "hello\n" and tail["run_id"] == run.id
    # 无变化 → 不发
    assert compute_sync_messages(store, state, KEY) == []


def test_sync_detects_output_and_status_change(store):
    run = store.create_run(name="a", command="c", cwd="", log_path="")
    state = SyncState()
    compute_sync_messages(store, state, KEY)
    store.append_output(run.id, "more", max_tail_chars=1000)
    msgs = compute_sync_messages(store, state, KEY)
    assert [m["t"] for m in msgs] == ["tail"]              # 输出增长只发尾窗,不动快照
    store.update_run(run.id, status="completed", exit_code=0)
    msgs = compute_sync_messages(store, state, KEY)
    assert [m["t"] for m in msgs] == ["snapshot"]          # 状态变化才发快照


def test_sync_forwards_events(store):
    state = SyncState()
    compute_sync_messages(store, state, KEY)
    store.record_event("r1", "failed", time.time(),
                       payload='{"type":"failed","title":"x","level":"critical","body":"","run_id":"r1"}')
    msgs = compute_sync_messages(store, state, KEY)
    evs = [m for m in msgs if m["t"] == "event"]
    assert len(evs) == 1 and decrypt(evs[0]["enc"], KEY)["type"] == "failed"
    assert compute_sync_messages(store, state, KEY) == []       # 不重发


def test_handle_mute(store):
    run = store.create_run(name="a", command="c", cwd="", log_path="")
    res = handle_command(store, {"op": "mute", "run_id": run.id, "args": {"hours": 1}})
    assert res["ok"] is True
    assert store.get_run(run.id).muted_until > time.time() + 3000
    res = handle_command(store, {"op": "mute", "run_id": run.id, "args": {"hours": 0}})
    assert store.get_run(run.id).muted_until > time.time() + 10 * 365 * 86400  # 永久


def test_handle_tail(store, tmp_path):
    log = tmp_path / "x.log"
    log.write_text("\n".join(f"line{i}" for i in range(200)))
    run = store.create_run(name="a", command="c", cwd="", log_path=str(log))
    res = handle_command(store, {"op": "tail", "run_id": run.id, "args": {"lines": 5}})
    assert res["ok"] is True
    assert res["tail"].splitlines() == [f"line{i}" for i in range(195, 200)]


def test_handle_stop(store):
    proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                            start_new_session=True)
    run = store.create_run(name="sleepy", command="c", cwd="", log_path="")
    store.update_run(run.id, status="running", pid=proc.pid)
    res = handle_command(store, {"op": "stop", "run_id": run.id})
    assert res["ok"] is True
    assert proc.wait(timeout=15) != 0


def test_handle_unknown(store):
    assert handle_command(store, {"op": "format_disk"})["ok"] is False


def test_handle_shutdown_after(store):
    run = store.create_run(name="a", command="c", cwd="", log_path="")
    res = handle_command(store, {"op": "shutdown_after", "run_id": run.id,
                                 "args": {"enabled": True}})
    assert res["ok"] is True and store.get_run(run.id).shutdown_after == 1
    handle_command(store, {"op": "shutdown_after", "run_id": run.id,
                           "args": {"enabled": False}})
    assert store.get_run(run.id).shutdown_after == 0


def test_handle_delete_run(store, tmp_path):
    log = tmp_path / "d.log"
    log.write_text("x")
    run = store.create_run(name="old", command="c", cwd="", log_path=str(log))
    env = log.parent / f"{run.id}.env.json"
    env.write_text("{}")
    # 运行中不让删
    store.update_run(run.id, status="running")
    assert handle_command(store, {"op": "delete_run", "run_id": run.id})["ok"] is False
    # 已结束 → 删记录 + 日志 + 环境快照
    store.update_run(run.id, status="completed")
    res = handle_command(store, {"op": "delete_run", "run_id": run.id})
    assert res["ok"] is True
    assert store.get_run(run.id) is None
    assert not log.exists() and not env.exists()
    # 不存在
    assert handle_command(store, {"op": "delete_run", "run_id": "nope"})["ok"] is False


def test_handle_config_set(store, tmp_path, monkeypatch):
    monkeypatch.setenv("RUNMON_CONFIG", str(tmp_path / "cfg.toml"))
    from runmon.config import Config
    res = handle_command(store, {"op": "config_set",
                                 "args": {"disk_threshold_pct": 85}})
    assert res["ok"] is True
    assert Config.load().disk_threshold_pct == 85
    assert handle_command(store, {"op": "config_set",
                                  "args": {"disk_threshold_pct": 30}})["ok"] is False
    assert handle_command(store, {"op": "config_set",
                                  "args": {"disk_threshold_pct": "x"}})["ok"] is False
    assert Config.load().disk_threshold_pct == 85  # 非法值不写入


def test_handle_llm_config_is_per_agent_and_never_returns_key(
        store, tmp_path, monkeypatch):
    monkeypatch.setenv("RUNMON_CONFIG", str(tmp_path / "cfg.toml"))
    from runmon.config import Config

    saved = handle_command(store, {
        "op": "llm_config_set",
        "args": {
            "enabled": True,
            "provider": "deepseek",
            "base_url": "https://api.deepseek.com",
            "model": "deepseek-v4-flash",
            "api_key": "server-only-secret",
        },
    })

    assert saved["ok"] is True
    assert saved["api_key_set"] is True
    assert "api_key" not in saved
    assert Config.load().llm["api_key"] == "server-only-secret"

    public = handle_command(store, {"op": "llm_config_get"})
    assert public == {
        "ok": True,
        "op": "llm_config_get",
        "enabled": True,
        "provider": "deepseek",
        "base_url": "https://api.deepseek.com",
        "model": "deepseek-v4-flash",
        "api_key_set": True,
    }

    # App 留空代表保留旧 Key,而不是误删。
    changed = handle_command(store, {
        "op": "llm_config_set",
        "args": {
            "enabled": True,
            "provider": "deepseek",
            "base_url": "https://api.deepseek.com",
            "model": "deepseek-v4-pro",
            "api_key": "",
        },
    })
    assert changed["ok"] is True
    assert Config.load().llm["api_key"] == "server-only-secret"


def test_handle_llm_test_uses_unsaved_form_values(
        store, tmp_path, monkeypatch):
    monkeypatch.setenv("RUNMON_CONFIG", str(tmp_path / "cfg.toml"))
    captured = {}

    def fake_test(self):
        captured.update(self.config)
        return {"ok": True, "summary": "接口正常"}

    monkeypatch.setattr(
        "runmon.llm_summary.LLMSummarizer.test_connection", fake_test
    )

    result = handle_command(store, {
        "op": "llm_test",
        "args": {
            "provider": "custom",
            "base_url": "https://llm.example.com/v1",
            "model": "my-model",
            "api_key": "temporary-secret",
        },
    })

    assert result == {
        "ok": True,
        "op": "llm_test",
        "summary": "接口正常",
    }
    assert captured["enabled"] is True
    assert captured["api_key"] == "temporary-secret"
    from runmon.config import Config
    assert Config.load().llm == {}


def test_handle_llm_rejects_invalid_endpoint(store, tmp_path, monkeypatch):
    monkeypatch.setenv("RUNMON_CONFIG", str(tmp_path / "cfg.toml"))

    result = handle_command(store, {
        "op": "llm_config_set",
        "args": {
            "enabled": True,
            "provider": "custom",
            "base_url": "file:///etc/passwd",
            "model": "bad",
        },
    })

    assert result["ok"] is False
    assert "http" in result["error"]


def test_heartbeat_includes_safe_gpu_process_summaries(monkeypatch):
    monkeypatch.setattr(
        sampler,
        "sample_gpus",
        lambda: [
            GpuSample(0, 92, 22528, 24576, 71, {27182: 18432, 28104: 4096}),
            GpuSample(1, 3, 1024, 24576, 42, {}),
        ],
    )
    monkeypatch.setattr(
        sampler,
        "sample_processes",
        lambda pids: {
            27182: SimpleNamespace(
                pid=27182,
                user="alice",
                name="python",
                cpu_pct=132.0,
                mem_used_mb=7270,
                mem_pct=5.7,
            ),
            28104: SimpleNamespace(
                pid=28104,
                user="bob",
                name="python",
                cpu_pct=18.4,
                mem_used_mb=2048,
                mem_pct=1.6,
            ),
        },
    )
    monkeypatch.setattr(relay_client.psutil, "cpu_percent", lambda interval=None: 35)
    monkeypatch.setattr(
        relay_client.psutil,
        "virtual_memory",
        lambda: SimpleNamespace(percent=82),
    )
    monkeypatch.setattr(sampler, "disk_usage", lambda: [])

    payload = heartbeat_payload()

    assert payload["gpus"][0]["processes"] == [
        {
            "pid": 27182,
            "user": "alice",
            "name": "python",
            "cpu_pct": 132.0,
            "mem_used_mb": 7270,
            "mem_pct": 5.7,
            "gpu_mem_mb": 18432,
        },
        {
            "pid": 28104,
            "user": "bob",
            "name": "python",
            "cpu_pct": 18.4,
            "mem_used_mb": 2048,
            "mem_pct": 1.6,
            "gpu_mem_mb": 4096,
        },
    ]
    assert payload["gpus"][1]["processes"] == []
    assert "command" not in json.dumps(payload)
    assert "cmdline" not in json.dumps(payload)
