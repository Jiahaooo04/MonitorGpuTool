"""蹲 GPU 空位:CLI `mon wait` 与 daemon 侧 App 蹲卡(gpu_watch)共用一套判定。"""
from __future__ import annotations

import json
import shlex
import time
from dataclasses import dataclass
from pathlib import Path

from .config import Config, data_dir
from .events import Event, format_duration
from .notify import Notifier, make_channels
from .sampler import GpuSample
from .store import RunStore

GPU_FREE = "gpu_free"
HEARTBEAT_S = 600  # 等待期间每 10 分钟在终端打一行心跳


@dataclass
class WaitSpec:
    count: int = 1              # 需要几张卡
    free_gb: float | None = None  # 每张卡需要的空闲显存 GB;None = 要整卡空闲
    hold_minutes: float = 3.0   # 条件需持续满足的分钟数(防止别人任务间隙的假空闲)


def card_ok(util_pct: int, used_mb: int, total_mb: int, free_gb: float | None) -> bool:
    """单张卡是否达标。free_gb=None 要求整卡空闲(容忍 Xorg 等残留占用)。"""
    if free_gb is not None:  # 共卡模式:只看空闲显存够不够
        return total_mb - used_mb >= free_gb * 1024
    return used_mb <= max(total_mb * 0.05, 1024) and util_pct <= 10


def qualified(samples: list[GpuSample], free_gb: float | None) -> list[GpuSample]:
    """返回满足条件的卡,空闲显存多的在前。"""
    good = [s for s in samples
            if card_ok(s.util_pct, s.mem_used_mb, s.mem_total_mb, free_gb)]
    good.sort(key=lambda s: s.mem_used_mb - s.mem_total_mb)
    return good


class HoldTracker:
    """跟踪条件连续满足的时长,满 hold 秒返回 True。"""

    def __init__(self, hold_seconds: float, clock=time.time) -> None:
        self.hold = hold_seconds
        self.clock = clock
        self.since: float | None = None

    def feed(self, ok: bool) -> bool:
        if not ok:
            self.since = None
            return False
        if self.since is None:
            self.since = self.clock()
        return self.clock() - self.since >= self.hold


class GpuWaiter:
    def __init__(self, spec: WaitSpec, command: list[str] | None = None,
                 name: str | None = None, store: RunStore | None = None,
                 config: Config | None = None, sample_fn=None,
                 clock=time.time, sleep=time.sleep) -> None:
        from . import sampler
        self.spec = spec
        self.command = command or []
        self.name = name
        self.config = config or Config.load()
        self.store = store or RunStore()
        self.sample_fn = sample_fn or sampler.sample_gpus
        self.clock = clock
        self.sleep = sleep

    def _fmt(self, cards: list[GpuSample]) -> str:
        return " · ".join(f"卡{s.index} 空闲{(s.mem_total_mb - s.mem_used_mb) / 1024:.0f}GB"
                          for s in cards)

    def _announce(self) -> None:
        req = (f"每张空闲显存 ≥{self.spec.free_gb:g}GB" if self.spec.free_gb is not None
               else "整卡空闲")
        hold = (f",持续满足 {self.spec.hold_minutes:g} 分钟后"
                if self.spec.hold_minutes else ",满足即")
        act = f"自动启动:{shlex.join(self.command)}" if self.command else "通知手机"
        print(f"[mon wait] 蹲 {self.spec.count} 张 GPU({req}){hold}{act}", flush=True)
        if not self.config.channels and not self.config.relay.get("device_token"):
            print("[mon wait] ⚠️ 未配置通知通道也未配对手机(mon init / mon pair),"
                  "等到后只有终端提示", flush=True)

    def execute(self) -> int:
        self._announce()
        tracker = HoldTracker(self.spec.hold_minutes * 60, clock=self.clock)
        started = self.clock()
        last_beat = started
        prev_ok: bool | None = None
        while True:
            good = qualified(self.sample_fn(), self.spec.free_gb)
            ok = len(good) >= self.spec.count
            if tracker.feed(ok):
                return self._fire(good[:self.spec.count])
            now = self.clock()
            if ok != prev_ok:  # 只在状态翻转时打印,避免刷屏
                prev_ok = ok
                if ok:
                    print(f"[mon wait] 条件满足({self._fmt(good)}),"
                          f"开始计时 {self.spec.hold_minutes:g} 分钟…", flush=True)
                else:
                    print(f"[mon wait] 条件中断(当前 {len(good)}/{self.spec.count} 张满足),"
                          "继续等待", flush=True)
            if now - last_beat >= HEARTBEAT_S:
                last_beat = now
                print(f"[mon wait] 仍在等待({len(good)}/{self.spec.count} 张满足,"
                      f"已等 {format_duration(now - started)})", flush=True)
            self.sleep(self.config.sample_interval_s)

    def _fire(self, cards: list[GpuSample]) -> int:
        desc = self._fmt(cards)
        held = (f"(已持续满足 {self.spec.hold_minutes:g} 分钟)"
                if self.spec.hold_minutes else "")
        if self.command:
            ev = Event(GPU_FREE, "info", "🚀 GPU 就绪,预约任务已启动",
                       f"{desc}\n开始执行:{shlex.join(self.command)}")
        else:  # 纯蹲卡:时效性强,按 critical 推送(抢卡要快)
            ev = Event(GPU_FREE, "critical",
                       f"🎉 GPU 空位来了:{len(cards)} 张卡就绪", f"{desc}{held}")
        self.store.record_event(None, GPU_FREE, self.clock(),
                                payload=json.dumps(ev.to_dict(), ensure_ascii=False))
        notifier = Notifier(self.store, make_channels(self.config))
        notifier.notify(ev)
        notifier.flush(timeout=15)
        notifier.stop()
        print(f"[mon wait] 🎉 等到啦:{desc}", flush=True)
        if not self.command:
            return 0
        import os
        idx = ",".join(str(s.index) for s in sorted(cards, key=lambda s: s.index))
        # PCI_BUS_ID 让 CUDA 编号与 nvidia-smi/NVML 一致,再圈定选中的卡
        os.environ["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"
        os.environ["CUDA_VISIBLE_DEVICES"] = idx
        print(f"[mon wait] 启动预约任务(CUDA_VISIBLE_DEVICES={idx}):"
              f"{shlex.join(self.command)}", flush=True)
        from .runner import RunWrapper
        return RunWrapper(self.command, name=self.name, store=self.store,
                          config=self.config, gpu_indices=idx).execute()


# ---------- daemon 侧蹲卡(手机 App 下发,配置落盘,随心跳评估) ----------

def watch_path() -> Path:
    return data_dir() / "gpu_watch.json"


def load_watch() -> dict | None:
    try:
        w = json.loads(watch_path().read_text(encoding="utf-8"))
        return w if w.get("cards") else None
    except Exception:
        return None


def save_watch(watch: dict) -> None:
    watch_path().write_text(json.dumps(watch, ensure_ascii=False), encoding="utf-8")


def clear_watch() -> None:
    try:
        watch_path().unlink()
    except FileNotFoundError:
        pass


def set_watch(args: dict) -> dict:
    """校验 App 下发的蹲卡配置并落盘。cards: {"卡号": 需要的空闲GB 或 null(整卡)}"""
    try:
        cards = {str(int(k)): (None if v is None else max(0.0, float(v)))
                 for k, v in (args.get("cards") or {}).items()}
    except (TypeError, ValueError):
        return {"ok": False, "error": "cards 格式错误"}
    if not cards:
        return {"ok": False, "error": "至少选择一张卡"}
    command = str(args.get("command") or "").strip()
    if command and not Config.load().enable_terminal:
        return {"ok": False,
                "error": "服务器已禁用远程执行(enable_terminal=false),只能蹲卡通知"}
    hold = args.get("hold_minutes", 3)
    save_watch({"cards": cards,
                "hold_minutes": max(0.0, float(3 if hold is None else hold)),
                "command": command,
                "name": str(args.get("name") or "").strip()[:60],
                "created_at": time.time()})
    return {"ok": True}


class GpuWatchManager:
    """daemon 持有:每次心跳喂入 GPU 采样,评估蹲卡条件,满足即通知/预约执行。"""

    def __init__(self, store: RunStore, config: Config, clock=time.time) -> None:
        self.store = store
        self.config = config
        self.clock = clock
        self._sig: str | None = None  # 当前 watch 的内容签名,变了就重置计时
        self._tracker: HoldTracker | None = None

    def poll(self, gpus: list[dict]) -> dict | None:
        """gpus 为心跳里的采样([{index,util,mem_used,mem_total},…])。
        返回给 App 展示的蹲卡状态;没有蹲卡任务时返回 None。"""
        watch = load_watch()
        if watch is None:
            self._sig = None
            return None
        sig = json.dumps(watch, sort_keys=True)
        if sig != self._sig:  # 新建/修改的蹲卡任务:重新计时
            self._sig = sig
            self._tracker = HoldTracker(
                float(watch.get("hold_minutes", 3)) * 60, clock=self.clock)
        by_idx = {int(g["index"]): g for g in gpus}
        states, all_ok = [], True
        for k, need in watch["cards"].items():
            g = by_idx.get(int(k))
            ok = g is not None and card_ok(
                int(g["util"]), int(g["mem_used"]), int(g["mem_total"]),
                None if need is None else float(need))
            states.append({"index": int(k), "ok": ok,
                           "free_mb": (g["mem_total"] - g["mem_used"]) if g else 0})
            all_ok = all_ok and ok
        fired = self._tracker.feed(all_ok)
        status = {**watch, "ok": all_ok, "since": self._tracker.since,
                  "card_states": sorted(states, key=lambda s: s["index"])}
        if fired:
            self._fire(watch, status["card_states"])
            clear_watch()
            self._sig = None
            status["fired"] = True
        return status

    def _fire(self, watch: dict, states: list[dict]) -> None:
        desc = " · ".join(f"卡{s['index']} 空闲{s['free_mb'] / 1024:.0f}GB"
                          for s in states)
        command = (watch.get("command") or "").strip()
        idx = ",".join(str(s["index"]) for s in states)
        if command:
            if not self.config.enable_terminal:  # set 时已拦,这里兜底(配置可能中途改)
                ev = Event(GPU_FREE, "critical", "🎉 蹲到卡了(预约未执行)",
                           f"{desc}\n服务器已禁用远程执行(enable_terminal=false)")
            elif self._launch(command, watch.get("name") or "", idx):
                ev = Event(GPU_FREE, "info", "🚀 GPU 就绪,预约任务已启动",
                           f"{desc}\n开始执行:{command}")
            else:
                ev = Event(GPU_FREE, "critical", "🎉 蹲到卡了(预约启动失败)",
                           f"{desc}\n命令未能启动,请上服务器手动处理")
        else:
            hold = float(watch.get("hold_minutes", 3))
            ev = Event(GPU_FREE, "critical",
                       f"🎉 蹲到卡了:选中的 {len(states)} 张全部就绪",
                       desc + (f"(已持续满足 {hold:g} 分钟)" if hold else ""))
        self.store.record_event(None, GPU_FREE, self.clock(),
                                payload=json.dumps(ev.to_dict(), ensure_ascii=False))
        notifier = Notifier(self.store, make_channels(self.config))
        notifier.notify(ev)
        notifier.flush(timeout=15)
        notifier.stop()

    def _launch(self, command: str, name: str, idx: str) -> bool:
        import os
        import subprocess
        import sys
        import time
        from pathlib import Path
        from .config import data_dir

        env = dict(os.environ)
        env["CUDA_DEVICE_ORDER"] = "PCI_BUS_ID"  # Ensure CUDA device index aligns with nvidia-smi
        if idx:
            env["CUDA_VISIBLE_DEVICES"] = idx

        # Generate isolated runner script to reproduce full interactive terminal environment
        script_dir = data_dir() / "scripts"
        script_dir.mkdir(parents=True, exist_ok=True)
        script_file = script_dir / f"launch_{int(time.time())}_{os.getpid()}.sh"

        # Wrap command into step-by-step terminal execution if not already wrapped
        if "_monitorgputool_step" in command or "_runmon_step" in command:
            exec_body = command
        else:
            lines = []
            for line in command.splitlines():
                trimmed = line.strip()
                if not trimmed:
                    continue
                if trimmed.startswith("#"):
                    lines.append(line)
                else:
                    escaped = line.replace("'", "'\\''")
                    lines.append(f"_monitorgputool_step '{escaped}'")
            exec_body = "\n".join(lines) if lines else command

        script_content = f"""#!/usr/bin/env bash
# 1. Search and source conda from common paths if conda command is not yet available
if ! type conda >/dev/null 2>&1; then
    for _d in "$CONDA_EXE" "$MAMBA_EXE" \
              "$HOME/miniconda3" "$HOME/anaconda3" "$HOME/miniconda" "$HOME/anaconda" \
              "$HOME/miniforge3" "$HOME/mambaforge" "$HOME/.conda" \
              "/opt/conda" "/opt/miniconda3" "/opt/anaconda3" \
              "/usr/local/miniconda3" "/usr/local/anaconda3" \
              "/data/miniconda3" "/data/anaconda3" \
              /data/home/*/miniconda* /data/home/*/anaconda* \
              /home/*/miniconda* /home/*/anaconda* /home/*/miniforge* /home/*/mambaforge*; do
        if [ -n "$_d" ]; then
            if [ -f "$_d/etc/profile.d/conda.sh" ]; then
                . "$_d/etc/profile.d/conda.sh" 2>/dev/null
                break
            elif [ -f "$_d/bin/conda" ]; then
                export PATH="$_d/bin:$PATH"
                eval "$("$_d/bin/conda" shell.bash hook 2>/dev/null)" || true
                break
            fi
        fi
    done
fi

# 2. Extract and source conda initialize block from shell rc files if still needed
if ! type conda >/dev/null 2>&1; then
    for rc in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        if [ -f "$rc" ]; then
            eval "$(sed -n '/# >>> conda initialize >>>/,/# <<< conda initialize <<</p' "$rc" 2>/dev/null)"
            if type conda >/dev/null 2>&1; then
                break
            fi
        fi
    done
fi

# 3. Inject Conda Shell Hook
if type conda >/dev/null 2>&1; then
    eval "$(conda shell.bash hook 2>/dev/null)" || true
fi

# 4. Load system and user environment profiles
[ -f /etc/profile ] && . /etc/profile 2>/dev/null
[ -f ~/.profile ] && . ~/.profile 2>/dev/null
[ -f "$HOME/.bash_profile" ] && . "$HOME/.bash_profile" 2>/dev/null
if [ -f "$HOME/.bashrc" ]; then
    eval "$(sed -e 's/\\[ -z "\\$PS1" \\] && return//g' -e 's/case \\$- in \\*i\\*\\) ;; \\*\\) return;; esac//g' "$HOME/.bashrc" 2>/dev/null)" 2>/dev/null || true
fi

# 5. Interactive terminal prompt generator and step-by-step runner
_monitorgputool_prompt() {{
    local _env=""
    if [ -n "$CONDA_DEFAULT_ENV" ]; then
        _env="($CONDA_DEFAULT_ENV) "
    elif [ -n "$VIRTUAL_ENV" ]; then
        _env="($(basename "$VIRTUAL_ENV")) "
    fi
    local _u="${{USER:-$(id -un 2>/dev/null || whoami 2>/dev/null || echo user)}}"
    local _h="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo localhost)"
    local _cwd="$PWD"
    local _disp_cwd="$_cwd"
    if [ -n "$HOME" ]; then
        if [ "$_cwd" = "$HOME" ]; then
            _disp_cwd="~"
        elif [[ "$_cwd" == "$HOME/"* ]]; then
            _disp_cwd="~${{_cwd#$HOME}}"
        fi
    fi
    local _sym="$"
    if [ "${{EUID:-$(id -u 2>/dev/null)}}" = "0" ]; then
        _sym="#"
    fi
    printf "\\033[00m%s\\033[01;32m%s@%s\\033[00m:\\033[01;34m%s\\033[00m%s " "$_env" "$_u" "$_h" "$_disp_cwd" "$_sym"
}}

_monitorgputool_step() {{
    local _cmd="$1"
    [ -z "$_cmd" ] && return 0
    _monitorgputool_prompt
    printf "%s\\n" "$_cmd"
    eval "$_cmd"
    local _ret=$?
    if [ $_ret -ne 0 ]; then
        printf "\\033[01;31m[MonitorGpuTool] 步骤执行失败 (退出码: %d)\\033[00m\\n" "$_ret"
        _monitorgputool_prompt
        printf "\\n"
        exit $_ret
    fi
    return 0
}}

# Alias for backward compatibility
_runmon_prompt() {{ _monitorgputool_prompt; }}
_runmon_step() {{ _monitorgputool_step "$@"; }}

# 6. Sequentially execute user commands step-by-step
{exec_body}

# 7. Print concluding terminal prompt
_monitorgputool_prompt
printf "\\n"
"""
        script_file.write_text(script_content, encoding="utf-8")
        script_file.chmod(0o755)

        argv = [sys.executable, "-m", "monitorgputool", "run", "--name", name or "预约任务",
                "--gpu", idx, "--", "bash", "-l", str(script_file)]
        try:
            subprocess.Popen(argv, cwd=os.path.expanduser("~"), env=env,
                             start_new_session=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return True
        except Exception:
            return False
