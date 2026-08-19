<div align="center">

[![English](https://img.shields.io/badge/English-2563EB?style=for-the-badge)](README.md) [![简体中文](https://img.shields.io/badge/简体中文-64748B?style=for-the-badge)](README.zh-CN.md)

</div>

# MonitorGpuTool (monitorgputool)

**Long-job companion** — when a training run, crawler, or long script is running on your server, your phone knows the moment it "finished, failed, or silently stalled." Zero-instrumentation, not a line of training code changed.

`monitorgputool` is the Python CLI (`mon` / `monitorgputool`) you install on the server that runs your jobs. It does two things: it **pushes notifications** to your phone when something happens, and — paired with the MonitorGpuTool app — it streams a **live view** you can watch and remote-control from your phone.

## Install

```bash
pip install monitorgputool
```

Requires Python ≥ 3.10. GPU metrics use NVIDIA NVML; on a machine without a GPU it degrades gracefully (everything else keeps working).

> **conda users:** `mon` is a system-level tool — no need to install it into every virtual env. `pipx install monitorgputool` installs it once, globally available, no reinstalling when you switch envs.

---

## Two ways to use it

### A · Notifications only — no app, no relay

The lightest setup: you just want your phone to buzz when a job finishes, fails, or stalls. **No MonitorGpuTool app needed** — notifications arrive in the ntfy / Bark / WeCom / Telegram app you already have.

```bash
# 1. Configure a channel (pick one)
mon init --ntfy-topic my-secret-topic-2333   # ntfy: install the ntfy app, subscribe to this topic
mon init --wecom-key <webhook>               # WeCom (企业微信) group bot — most reliable in China
mon init --bark-key <key>                    # iOS Bark

# 2. Wrap your command
mon run -- python train.py
```

Done — the six event types below get pushed to your phone.

### B · Live monitoring on your phone — MonitorGpuTool app + relay

The full experience: watch the **live terminal**, resource charts, progress/ETA, and **remote-control** the job from the MonitorGpuTool app.

```bash
# 1. Pair with the app (one time). Prints a QR code — scan it in the app.
mon pair

# 2. Keep the connection alive. The phone sees live data ONLY while this runs.
#    Run it in tmux/nohup so it survives after you disconnect (see "mon daemon" below).
mon daemon

# 3. Run your job (in another shell)
mon run -- python train.py
```

Now open the app: live terminal, GPU/CPU/memory curves, progress/loss/ETA, and buttons to **stop / re-run / pull logs / open a terminal**.

> **First time?** Run `mon demo` instead of a real job to test the whole chain end-to-end.

---

## Command reference

| Command | What it does |
|---|---|
| `mon run -- <cmd>` | Run and monitor a command (the everyday wrapper) |
| `mon wait` | Camp for free GPUs: phone buzzes when cards free up; with a command, auto-start it (reserved run) |
| `mon attach` | Take over a job already running in tmux — no restart |
| `mon daemon` | Keep the live connection to your phone open |
| `mon pair` | Pair with the MonitorGpuTool app (prints a QR code) |
| `mon init` | Configure notification channels |
| `mon ls` | List jobs (progress / elapsed) |
| `mon status <job>` | Job details + output tail + ETA/loss |
| `mon stop <job>` | Stop a job (SIGINT → SIGTERM → SIGKILL) |
| `mon logs -f <job>` | Follow a job's output live |
| `mon demo` | Run a fake training job to test the setup |

### `mon run` — wrap and monitor

```bash
mon run -- python train.py                          # simplest — your command after the --
mon run --name exp1 --gpu 0,1 -- python train.py    # name the job + bind specific GPUs
```
Progress, ETA, and loss are parsed automatically from stdout (works with tqdm / `Epoch x/y` / `loss=…`) — no instrumentation needed. Try `mon demo` / `mon demo --fail` first to see it in action.

### `mon wait` — camp for GPUs & reserve a run

All the cards taken? Let MonitorGpuTool watch them for you — your phone buzzes the moment they free up; attach a command and it auto-starts once they do:

```bash
mon wait --gpus 2 --free-gb 30 -d       # phone buzzes when 2 cards each have 30GB free (-d = camp in background)
mon wait --gpus 2 -- python train.py    # wait for 2 fully-idle cards, then auto-start with CUDA_VISIBLE_DEVICES set
```

- Without `--free-gb` a card must be **fully idle** (util ≤10%, VRAM ≤5% used); with it, only free VRAM matters (sharing a busy card is fine)
- The condition must **hold for 3 minutes** before firing (tune with `--hold`, 0 = immediate) — a brief gap between someone else's jobs won't fool it
- The reserved job is a regular `mon run`: live view, event notifications, and remote control all apply

### `mon attach` — take over a tmux job

Already have a job running in a tmux session (maybe you started it days ago)? Take it over **without restarting**:
```bash
mon attach            # attach to the job in the current tmux pane
```
From then on it's monitored exactly like a `mon run` job — events, live view, and remote control all apply.

### `mon daemon` — keep the phone connection alive

`mon daemon` is the bridge to your phone: it syncs job state to the relay and receives your remote commands. **The live view in the app only works while the daemon is running.** (Notifications from `mon run` do *not* need it — those go out directly.)

By default it runs in the **foreground** and holds the terminal. **To run it in the background** so it survives closing your SSH session:

```bash
mon daemon -d      # detach: runs in the background and frees the terminal
                   # prints the pid + log path; stop it later with: kill <pid>
```

Prefer to manage it yourself? Use tmux or nohup instead:
```bash
tmux new -s mon; mon daemon          # Ctrl+B then D to detach; tmux attach -t mon to return
nohup mon daemon > ~/mon-daemon.log 2>&1 &
```

### `mon pair` — pair with the app

```bash
mon pair                                  # uses the default public relay; prints a QR code
mon pair --relay https://your-relay.com   # point at your own self-hosted relay
```
Scan the printed QR code in the MonitorGpuTool app to link this server to your phone. One-time per server.

### `mon logs` — follow output

```bash
mon logs -f exp1      # tail -f style; works even for backgrounded re-runs
```

### `mon ls` / `mon status` / `mon stop` — manage jobs

```bash
mon ls                # all jobs, with progress and elapsed time
mon status exp1       # details + output tail + ETA/loss
mon stop exp1         # stop (SIGINT → SIGTERM → SIGKILL)
```

---

## What lands on your phone (six events)

| Event | Trigger (default, configurable) | Level |
|---|---|---|
| ✅ Done | exit code 0 | info |
| ❌ Failed | non-zero exit code | critical |
| ⚠️ Error output | log shows Traceback / CUDA OOM / Segfault | critical |
| 🧊 GPU stall | process alive but GPU utilization <5% for 10 min | critical |
| 🤫 Log silence | no new output for 30 min | warning |
| 💾 Disk alert | any mount point reaches 90% used by default (adjustable from 50–99% in the app) | warning |

The same kind of event notifies at most once per 30 minutes; failed notifications retry with exponential backoff (up to 1 hour) and are persisted locally so nothing is lost.

When error output is immediately followed by a non-zero exit, MonitorGpuTool merges
both signals into one failure notification instead of buzzing twice. Without
LLM summaries enabled, that notification includes only the last three
non-empty log lines; the full log remains available in the app.

## Notification channels

`mon init` accepts combinations and can push to several channels at once:

```bash
mon init --ntfy-topic TOPIC [--ntfy-server https://your-self-hosted-ntfy]
mon init --bark-key KEY                  # iOS Bark
mon init --wecom-key WEBHOOK_URL         # WeCom (企业微信) group bot — most reliable in China
mon init --telegram BOT_TOKEN:CHAT_ID    # Telegram bot
mon init --webhook https://your/hook     # generic webhook (Feishu / DingTalk / custom)
```

## Config

Config lives in `~/.config/monitorgputool/config.toml`; all thresholds are adjustable:

```toml
hang_gpu_minutes = 20      # GPU-stall detection window
silence_minutes = 60       # log-silence alert
disk_threshold_pct = 90    # disk alert threshold (50–99)
```

The disk threshold can also be changed under **Settings → Disk alert
threshold** in the app. It is sent to every online server and persisted in
that server's agent config.

### Optional: turn failures into plain-language LLM summaries

When enabled, `mon run` sends the tail of a Traceback / CUDA OOM / Segfault or
failed job to your own OpenAI-compatible endpoint, then merges the error and
exit status into one notification with a one- or two-sentence diagnosis. It
is off by default. A timeout, API error, or missing configuration falls back
to the short log-tail notification, so delivery never depends on the LLM.

The easiest setup is in the app: open a server, tap **Error summary**, select a
provider and model, enter the API key, test the connection, then save. Each
server keeps its own configuration. The key reaches the agent over the
end-to-end encrypted channel; the relay never sees it, and the app never reads
the saved key back from the server.

You can also edit the server configuration directly:

```toml
[llm]
enabled = true
provider = "deepseek"
base_url = "https://api.deepseek.com"
api_key_env = "MONITORGPUTOOL_LLM_API_KEY"  # recommended: keep the key out of the file
model = "deepseek-v4-flash"
timeout_s = 10
```

Export the key before starting the job:

```bash
export MONITORGPUTOOL_LLM_API_KEY="your API key"
mon run python train.py
```

You may instead set `api_key = "..."` inside `[llm]`; the config file remains
mode `0600`. Before sending logs, MonitorGpuTool masks common API keys, tokens,
passwords, and `Authorization: Bearer` credentials, then keeps only the last
100 lines / 12,000 characters. The log excerpt goes to the LLM provider you
selected and never through the MonitorGpuTool relay. DeepSeek, Qwen, Kimi, OpenAI, and
local Ollama servers with an OpenAI-compatible endpoint are supported.

## Notes

- GPU sampling relies on NVIDIA NVML; on machines without a GPU it degrades gracefully.
- Each GPU heartbeat includes a safe process summary (user, PID, process name, CPU, RAM, and VRAM) for the app's tap-to-inspect sheet. MonitorGpuTool deliberately does not read process command lines or environment variables.
- For the phone app, self-hosting the relay, and the big picture, see the [project README](../README.md).
