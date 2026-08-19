import json
import sys

import pytest

from monitorgputool.config import Config, data_dir
from monitorgputool.notify import Notifier
from monitorgputool.runner import RunWrapper
from monitorgputool.store import RunStore


class MemoryChannel:
    name = "mem"

    def __init__(self):
        self.sent = []

    def send(self, ev):
        self.sent.append(ev)


class FakeSummarizer:
    enabled = True

    def __init__(self):
        self.calls = []

    def summarize(self, **context):
        self.calls.append(context)
        return "CUDA 显存不足,建议减小 batch_size。"


@pytest.fixture()
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("MONITORGPUTOOL_DATA_DIR", str(tmp_path / "data"))
    store = RunStore(tmp_path / "t.db")
    ch = MemoryChannel()
    notifier = Notifier(store, [ch])
    return store, ch, notifier


def make_wrapper(env, code: str, **kw):
    store, ch, notifier = env
    cfg = Config(sample_interval_s=3600)      # 测试中默认不触发监控采样
    return RunWrapper([sys.executable, "-u", "-c", code],
                      store=store, config=cfg, notifier=notifier, **kw), store, ch


def test_success_run(env):
    w, store, ch = make_wrapper(env, "print('hello-world')")
    assert w.execute() == 0
    run = store.get_run(w.run.id)
    assert run.status == "completed" and run.exit_code == 0
    assert "hello-world" in run.output_tail
    assert [e.type for e in ch.sent] == ["completed"]
    # 完整日志与 env 快照落盘
    assert "hello-world" in (data_dir() / "logs" / f"{run.id}.log").read_text()
    assert json.loads((data_dir() / "logs" / f"{run.id}.env.json").read_text())


def test_error_warning_merges_into_immediate_failure_without_llm(
        env, monkeypatch):
    import monitorgputool.runner as runner_mod
    monkeypatch.setattr(
        runner_mod, "ERROR_MERGE_GRACE_SECONDS", 0.05
    )
    w, store, ch = make_wrapper(env, "raise RuntimeError('boom')")
    assert w.execute() == 1
    run = store.get_run(w.run.id)
    assert run.status == "failed" and run.exit_code == 1
    assert [e.type for e in ch.sent
            if e.type in ("error_pattern", "failed")] == ["failed"]
    assert "RuntimeError: boom" in ch.sent[-1].body
    assert "耗时" in ch.sent[-1].body


def test_error_warning_still_emits_without_llm_when_task_keeps_running(
        env, monkeypatch):
    import monitorgputool.runner as runner_mod
    monkeypatch.setattr(
        runner_mod, "ERROR_MERGE_GRACE_SECONDS", 0.02
    )
    code = """
import sys
import time
sys.stderr.write("RuntimeError: CUDA out of memory\\n")
sys.stderr.flush()
time.sleep(0.1)
"""
    w, _, ch = make_wrapper(env, code)

    assert w.execute() == 0

    assert [event.type for event in ch.sent
            if event.type in ("error_pattern", "completed")] == [
        "error_pattern", "completed",
    ]


def test_llm_error_warning_merges_into_immediate_failure(env, monkeypatch):
    import monitorgputool.runner as runner_mod
    monkeypatch.setattr(
        runner_mod, "ERROR_MERGE_GRACE_SECONDS", 0.05, raising=False
    )
    summarizer = FakeSummarizer()
    w, store, ch = make_wrapper(
        env,
        (
            "print('\\n'.join(f'context-line-{i}' for i in range(20))); "
            "raise RuntimeError('CUDA out of memory')"
        ),
        summarizer=summarizer,
    )

    assert w.execute() == 1

    alerts = [event for event in ch.sent
              if event.type in ("error_pattern", "failed")]
    assert [event.type for event in alerts] == ["failed"]
    assert "AI 分析:CUDA 显存不足" in alerts[0].body
    assert len(summarizer.calls) == 1
    assert "CUDA out of memory" in summarizer.calls[0]["log_tail"]
    assert len(summarizer.calls[0]["log_tail"].splitlines()) > 3

    payloads = [json.loads(row["payload"])
                for row in store.events_since(0)]
    persisted = [payload for payload in payloads
                 if payload["type"] in ("error_pattern", "failed")]
    assert [payload["type"] for payload in persisted] == ["failed"]
    assert "AI 分析:CUDA 显存不足" in persisted[0]["body"]


def test_llm_error_warning_still_emits_when_task_keeps_running(
        env, monkeypatch):
    import monitorgputool.runner as runner_mod
    monkeypatch.setattr(
        runner_mod, "ERROR_MERGE_GRACE_SECONDS", 0.02, raising=False
    )
    code = """
import sys
import time
sys.stderr.write("RuntimeError: CUDA out of memory\\n")
sys.stderr.flush()
time.sleep(0.1)
"""
    w, _, ch = make_wrapper(env, code, summarizer=FakeSummarizer())

    assert w.execute() == 0

    assert [event.type for event in ch.sent
            if event.type in ("error_pattern", "completed")] == [
        "error_pattern", "completed",
    ]


def test_progress_recorded(env):
    code = r"""
import sys
sys.stdout.write("Epoch 1/2\n")
sys.stdout.write("50%|-----| 50/100 [00:10<00:10,  5.0it/s] loss=0.5\n")
"""
    w, store, _ = make_wrapper(env, code)
    w.execute()
    run = store.get_run(w.run.id)
    # 成功完成的任务进度收敛到 100%,loss 保留最后解析值
    assert run.progress == 100.0 and run.last_loss == 0.5


def test_monitor_disk_event(env, monkeypatch):
    store, ch, notifier = env
    import monitorgputool.runner as runner_mod
    monkeypatch.setattr(runner_mod.sampler, "disk_usage", lambda: [("/", 99.0)])
    monkeypatch.setattr(runner_mod.sampler, "sample_gpus", lambda: [])
    cfg = Config(sample_interval_s=0)        # 立即采样
    w = RunWrapper([sys.executable, "-c", "import time; time.sleep(0.6)"],
                   store=store, config=cfg, notifier=notifier)
    w.execute()
    assert "disk_full" in [e.type for e in ch.sent]


def test_default_name_is_command(env):
    w, store, _ = make_wrapper(env, "pass")
    w.execute()
    assert "-c" in store.get_run(w.run.id).name

