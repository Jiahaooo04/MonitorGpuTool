import os
import subprocess
import sys
import time
from types import SimpleNamespace

from monitorgputool import sampler
from monitorgputool.sampler import GpuSample, disk_usage, process_tree, util_for_indices, util_for_pids


def gs(index, util, pids):
    return GpuSample(index=index, util_pct=util, mem_used_mb=0, mem_total_mb=0, temp_c=0, pids=pids)


def test_util_for_pids():
    samples = [gs(0, 90, {111: 4000}), gs(1, 5, {222: 100})]
    assert util_for_pids(samples, {111}) == 90
    assert util_for_pids(samples, {111, 222}) == 90
    assert util_for_pids(samples, {999}) is None
    assert util_for_pids([], {111}) is None


def test_util_for_indices():
    samples = [gs(0, 30, {}), gs(1, 70, {})]
    assert util_for_indices(samples, {1}) == 70
    assert util_for_indices(samples, {0, 1}) == 70
    assert util_for_indices(samples, {5}) is None


def test_process_tree():
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    try:
        time.sleep(0.2)
        tree = process_tree(os.getpid())
        assert os.getpid() in tree and child.pid in tree
    finally:
        child.kill()
        child.wait()
    assert process_tree(99999999) == set()


def test_disk_usage_returns_mounts():
    mounts = disk_usage()
    assert mounts and all(0 <= pct <= 100 for _, pct in mounts)


def test_sample_processes_reports_user_cpu_and_memory(monkeypatch):
    state = {"cpu_total": 1.0}
    clock = iter([10.0, 12.0])

    class FakeProcess:
        def __init__(self, pid):
            assert pid == 27182
            self.pid = pid

        def create_time(self):
            return 1000.0

        def cpu_times(self):
            return SimpleNamespace(user=state["cpu_total"], system=0.0)

        def memory_info(self):
            return SimpleNamespace(rss=7 * 1024**3)

        def memory_percent(self):
            return 5.7

        def username(self):
            return "alice"

        def name(self):
            return "python"

    monkeypatch.setattr(sampler.psutil, "Process", FakeProcess)
    monkeypatch.setattr(sampler.time, "monotonic", lambda: next(clock))
    sampler._PROCESS_CPU.clear()

    first = sampler.sample_processes({27182})[27182]
    assert first.cpu_pct == 0

    state["cpu_total"] = 3.64
    second = sampler.sample_processes({27182})[27182]
    assert second.pid == 27182
    assert second.user == "alice"
    assert second.name == "python"
    assert second.cpu_pct == 132.0
    assert second.mem_used_mb == 7168
    assert second.mem_pct == 5.7


def test_sample_processes_skips_gone_or_inaccessible_pids(monkeypatch):
    def missing_process(pid):
        if pid == 1:
            raise sampler.psutil.NoSuchProcess(pid)
        raise sampler.psutil.AccessDenied(pid)

    monkeypatch.setattr(sampler.psutil, "Process", missing_process)
    sampler._PROCESS_CPU.clear()

    assert sampler.sample_processes({1, 2}) == {}

