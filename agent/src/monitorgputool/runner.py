from __future__ import annotations

import json
import os
import pty
import select
import shlex
import signal
import subprocess
import sys
import termios
import threading
import time
import tty
from concurrent.futures import Future, ThreadPoolExecutor

from . import sampler
from .config import Config, data_dir
from .events import Event, EventEngine
from .llm_summary import LLMSummarizer
from .notify import Notifier, make_channels
from .progress import ProgressParser
from .store import RunStore


ERROR_MERGE_GRACE_SECONDS = 1.0
DEFAULT_NOTIFICATION_TAIL_LINES = 3
MAX_NOTIFICATION_TAIL_CHARS = 400


def _notification_tail(text: str, max_lines: int) -> str:
    lines = [
        line for line in text.replace("\r", "\n").splitlines()
        if line.strip()
    ]
    return "\n".join(lines[-max_lines:])[-MAX_NOTIFICATION_TAIL_CHARS:]


class RunWrapper:
    def __init__(self, command: list[str], name: str | None = None,
                 store: RunStore | None = None, config: Config | None = None,
                 notifier: Notifier | None = None, gpu_indices: str = "",
                 summarizer: LLMSummarizer | None = None) -> None:
        self.command = command
        self.config = config or Config.load()
        self.store = store or RunStore()
        self.notifier = notifier or Notifier(self.store, make_channels(self.config))
        self.engine = EventEngine(self.store, self.config)
        self.summarizer = summarizer or LLMSummarizer(self.config.llm)
        self.parser = ProgressParser()
        self.gpu_indices = gpu_indices
        display = shlex.join([os.path.basename(command[0])] + list(command[1:]))
        self.name = name or display[:60]
        self.run = None
        self.child_pid: int | None = None
        self._gpu_history: list[tuple[float, float]] = []
        self._out_buf = ""
        self._err_window = ""
        self._last_flush = 0.0
        self._alert_pool: ThreadPoolExecutor | None = None
        self._alert_future: Future[str | None] | None = None
        self._llm_attempted = False
        self._llm_summary: str | None = None
        self._process_exited = threading.Event()
        self._exit_code: int | None = None

    def execute(self) -> int:
        log_dir = data_dir() / "logs"
        self.run = self.store.create_run(
            name=self.name, command=shlex.join(self.command), cwd=os.getcwd(),
            log_path="", gpu_indices=self.gpu_indices)
        log_path = log_dir / f"{self.run.id}.log"
        self.store.update_run(self.run.id, log_path=str(log_path))
        try:  # rerun 用的环境快照(仅存本机,含 token 等敏感值 → 0600)
            env_snap = log_dir / f"{self.run.id}.env.json"
            env_snap.write_text(json.dumps(dict(os.environ)), encoding="utf-8")
            env_snap.chmod(0o600)
        except Exception:
            pass

        pid, master = pty.fork()
        if pid == 0:  # 子进程
            try:
                os.execvp(self.command[0], self.command)
            except Exception:
                os._exit(127)  # 命令不存在等:干净退出,勿把异常抛穿父进程栈
        self.child_pid = pid
        self.store.update_run(self.run.id, pid=pid, status="running")
        self.notifier.start()  # 在 fork 之后再起线程,避免多线程 fork 风险

        stop_monitor = threading.Event()
        mon = threading.Thread(target=self._monitor, args=(stop_monitor,), daemon=True)
        mon.start()
        try:
            exit_code = self._pump(master, log_path)
            self._exit_code = exit_code
            self._process_exited.set()
        finally:
            stop_monitor.set()
            mon.join(timeout=2)
        self._flush_output(time.time())  # 落库残留输出

        status = "completed" if exit_code == 0 else "failed"
        st = self.parser.state
        final_progress = 100.0 if (exit_code == 0 and st.percent is not None) else st.percent
        self.store.update_run(self.run.id, status=status, exit_code=exit_code,
                              ended_at=time.time(), progress=final_progress,
                              eta_seconds=None if exit_code == 0 else st.eta_seconds,
                              last_loss=st.loss)
        try:
            final_run = self.store.get_run(self.run.id)
            if self.summarizer.enabled:
                self._wait_for_alert()
                ev = self.engine.on_exit(
                    final_run, exit_code, record=exit_code == 0
                )
                if exit_code == 0:
                    self.notifier.notify(ev)
                else:
                    if not self._llm_attempted:
                        self._llm_attempted = True
                        self._llm_summary = self.summarizer.summarize(
                            run_name=final_run.name,
                            command=final_run.command,
                            exit_code=exit_code,
                            log_tail=final_run.output_tail,
                        )
                    self._publish_deferred(ev, self._llm_summary)
            else:
                self._wait_for_alert()
                ev = self.engine.on_exit(
                    final_run, exit_code, record=exit_code == 0
                )
                if exit_code == 0:
                    self.notifier.notify(ev)
                else:
                    tail = self._short_notification_tail(
                        final_run.output_tail
                    )
                    if tail:
                        ev.body = f"日志末尾:\n{tail}\n{ev.body}"
                    self._publish_deferred(ev, None)
            self.notifier.flush(timeout=15)
            self.notifier.stop()
        except Exception:
            pass
        finally:
            if self._alert_pool is not None:
                self._alert_pool.shutdown(wait=True)
        try:
            final = self.store.get_run(self.run.id)
            if final is not None and final.shutdown_after:
                print("\n[mon] 任务结束,按设置执行自动关机…", flush=True)
                subprocess.run(shlex.split(self.config.shutdown_command), timeout=30)
        except Exception as exc:
            print(f"[mon] 自动关机失败:{exc}", flush=True)
        return exit_code

    def _pump(self, master: int, log_path) -> int:
        stdin_fd = sys.stdin.fileno() if sys.stdin.isatty() else None
        old_attrs = None
        if stdin_fd is not None:
            try:
                old_attrs = termios.tcgetattr(stdin_fd)
                tty.setcbreak(stdin_fd)
            except termios.error:
                stdin_fd = None

        def fwd(signum, _frame):
            try:
                os.kill(self.child_pid, signum)
            except ProcessLookupError:
                pass

        old_int = signal.signal(signal.SIGINT, fwd)
        old_term = signal.signal(signal.SIGTERM, fwd)
        log = open(log_path, "ab")
        try:
            while True:
                fds = [master] + ([stdin_fd] if stdin_fd is not None else [])
                try:
                    r, _, _ = select.select(fds, [], [], 1.0)
                except InterruptedError:
                    continue
                if master in r:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    try:
                        os.write(sys.stdout.fileno(), chunk)
                    except OSError:
                        pass
                    log.write(chunk)
                    log.flush()
                    self._ingest(chunk.decode("utf-8", errors="replace"))
                if stdin_fd is not None and stdin_fd in r:
                    data = os.read(stdin_fd, 4096)
                    if data:
                        os.write(master, data)
        finally:
            log.close()
            signal.signal(signal.SIGINT, old_int)
            signal.signal(signal.SIGTERM, old_term)
            if old_attrs is not None:
                termios.tcsetattr(stdin_fd, termios.TCSADRAIN, old_attrs)
            os.close(master)
        _, status = os.waitpid(self.child_pid, 0)
        if os.WIFEXITED(status):
            return os.WEXITSTATUS(status)
        if os.WIFSIGNALED(status):
            return 128 + os.WTERMSIG(status)
        return 1

    def _ingest(self, text: str) -> None:
        try:
            self._out_buf += text
            # 错误检测在最近 16KB 窗口上做,避免关键字被读边界劈开而漏检
            self._err_window = (self._err_window + text)[-16384:]
            if self._alert_future is None or self._alert_future.done():
                self._wait_for_alert()
                if ev := self.engine.on_output(
                    self.run, self._err_window, record=False
                ):
                    self._queue_error_event(ev, self._err_window)
            self.parser.feed(text)
            now = time.time()
            if now - self._last_flush > 1.0 or len(self._out_buf) >= 262144:
                self._flush_output(now)
        except Exception:
            pass  # 监控故障不影响任务

    def _queue_error_event(self, ev: Event, log_tail: str) -> None:
        if self._alert_pool is None:
            self._alert_pool = ThreadPoolExecutor(
                max_workers=1, thread_name_prefix="monitorgputool-alert"
            )
        if self.summarizer.enabled:
            self._llm_attempted = True
        self._alert_future = self._alert_pool.submit(
            self._analyze_and_publish, ev, log_tail
        )

    def _analyze_and_publish(self, ev: Event, log_tail: str) -> str | None:
        summary = None
        if self.summarizer.enabled:
            summary = self.summarizer.summarize(
                run_name=self.run.name,
                command=self.run.command,
                exit_code=None,
                log_tail=log_tail,
            )
        else:
            tail = self._short_notification_tail(log_tail)
            if tail:
                ev.body = f"日志末尾:\n{tail}"
        self._llm_summary = summary
        if (self._process_exited.wait(ERROR_MERGE_GRACE_SECONDS)
                and self._exit_code not in (None, 0)):
            return summary
        self._publish_deferred(ev, summary)
        return summary

    def _publish_deferred(self, ev: Event, summary: str | None) -> None:
        if summary:
            ev.body = f"AI 分析:{summary}\n{ev.body}"
        self.engine.record(ev)
        self.notifier.notify(ev)

    def _wait_for_alert(self) -> None:
        if self._alert_future is None:
            return
        try:
            self._llm_summary = self._alert_future.result()
        except Exception:
            self._llm_summary = None
        finally:
            self._alert_future = None

    def _short_notification_tail(self, text: str) -> str:
        lines = self.config.notify_include_tail or DEFAULT_NOTIFICATION_TAIL_LINES
        return _notification_tail(text, max(1, min(int(lines), 10)))

    def _flush_output(self, now: float) -> None:
        if self._out_buf:
            self.store.append_output(self.run.id, self._out_buf,
                                     self.config.ring_buffer_kb * 1024)
            self._out_buf = ""
        st = self.parser.state
        self.store.update_run(self.run.id, progress=st.percent,
                              eta_seconds=st.eta_seconds, last_loss=st.loss)
        self._last_flush = now

    def _monitor(self, stop: threading.Event) -> None:
        ticks = 0
        while not stop.wait(self.config.sample_interval_s):
            try:
                ticks += 1
                if ticks % 12 == 0:  # ~每分钟重读配置:手机端改的阈值对运行中任务也生效
                    self.config = Config.load()
                    self.engine.config = self.config
                now = time.time()
                samples = sampler.sample_gpus()
                if self.gpu_indices:
                    idxs = {int(i) for i in self.gpu_indices.split(",") if i.strip()}
                    util = sampler.util_for_indices(samples, idxs)
                else:
                    util = sampler.util_for_pids(
                        samples, sampler.process_tree(self.child_pid))
                run = self.store.get_run(self.run.id)
                if run is None:
                    continue
                pending = []
                if util is not None:
                    self._gpu_history.append((now, util))
                    cutoff = now - (self.config.hang_gpu_minutes + 5) * 60
                    self._gpu_history = [(t, u) for t, u in self._gpu_history if t >= cutoff]
                    if ev := self.engine.check_gpu_hang(run, self._gpu_history):
                        pending.append(ev)
                if ev := self.engine.check_log_silence(run):
                    pending.append(ev)
                if ev := self.engine.check_disk(sampler.disk_usage()):
                    pending.append(ev)
                for ev in pending:
                    self.notifier.notify(ev)
            except Exception:
                pass  # 监控故障不影响任务
