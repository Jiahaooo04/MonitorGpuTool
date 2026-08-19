from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from typing import Any
from urllib.parse import urlparse

from . import __version__

_MAX_SUMMARY_CHARS = 220
_DEFAULT_TIMEOUT_S = 10.0
_AUTH_BEARER_RE = re.compile(
    r"(?i)(\bauthorization\s*:\s*bearer\s+)[^\s,;]+"
)
_NAMED_SECRET_RE = re.compile(
    r"(?i)(?P<name>(?:--)?(?:api[_-]?key|token|password|passwd|secret))"
    r"(?P<sep>\s*(?:=|:|\s)\s*)"
    r"(?P<quote>['\"]?)(?P<value>[^\s,'\";]+)(?P=quote)"
)
_RAW_API_KEY_RE = re.compile(r"\bsk-[A-Za-z0-9_-]{8,}\b")

Transport = Callable[[str, bytes, dict[str, str], float], Mapping[str, Any]]


def redact_secrets(text: str) -> str:
    """遮盖常见凭证格式,避免把日志里的秘密发给 LLM。"""
    text = _AUTH_BEARER_RE.sub(r"\1[REDACTED]", text)
    text = _NAMED_SECRET_RE.sub(
        lambda m: f"{m.group('name')}{m.group('sep')}[REDACTED]", text
    )
    return _RAW_API_KEY_RE.sub("[REDACTED]", text)


def _post_json(
    url: str, data: bytes, headers: dict[str, str], timeout: float
) -> Mapping[str, Any]:
    req = urllib.request.Request(
        url, data=data, headers=headers, method="POST"
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def _post_json_direct(
    url: str, data: bytes, headers: dict[str, str], timeout: float
) -> Mapping[str, Any]:
    """绕过进程里的 HTTP_PROXY；国内/本地模型经常被海外代理误伤。"""
    req = urllib.request.Request(
        url, data=data, headers=headers, method="POST"
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def _should_bypass_system_proxy(config: Mapping[str, Any]) -> bool:
    if "use_system_proxy" in config:
        return not bool(config["use_system_proxy"])
    provider = str(config.get("provider", "")).lower()
    if provider in {"deepseek", "qwen", "kimi", "ollama"}:
        return True
    host = (
        urlparse(str(config.get("base_url", ""))).hostname or ""
    ).lower()
    return host in {"127.0.0.1", "localhost", "::1"}


def _chat_url(base_url: str) -> str:
    url = base_url.rstrip("/")
    if url.endswith("/chat/completions"):
        return url
    return f"{url}/chat/completions"


def _plain_summary(value: str) -> str:
    value = value.replace("```", " ")
    value = value.replace("**", "").replace("__", "").replace("`", "")
    value = re.sub(r"(?m)^\s*#{1,6}\s*", "", value)
    value = re.sub(r"(?m)^\s*[-*]\s+", "", value)
    value = " ".join(value.split())
    if len(value) > _MAX_SUMMARY_CHARS:
        value = value[:_MAX_SUMMARY_CHARS - 1].rstrip() + "…"
    return value


def _friendly_error(exc: Exception) -> str:
    """把网络异常压成可展示、不会泄露凭证的一句话。"""
    if isinstance(exc, TimeoutError):
        return "连接超时，请检查服务器网络或稍后重试"
    if isinstance(exc, urllib.error.HTTPError):
        detail = ""
        try:
            body = exc.read().decode("utf-8", errors="replace")
            data = json.loads(body)
            detail = str(
                data.get("error", {}).get("message")
                or data.get("message")
                or ""
            )
        except Exception:
            detail = ""
        suffix = f"：{detail}" if detail else ""
        return redact_secrets(f"接口返回 HTTP {exc.code}{suffix}")[:260]
    if isinstance(exc, urllib.error.URLError):
        reason = redact_secrets(str(exc.reason))
        return f"无法连接接口：{reason}"[:260]
    message = redact_secrets(str(exc)).strip()
    return (f"测试失败：{message}" if message else "测试失败，请检查配置")[:260]


class LLMSummarizer:
    """使用用户配置的 OpenAI 兼容接口总结任务错误。"""

    def __init__(
        self,
        config: Mapping[str, Any] | None,
        *,
        transport: Transport | None = None,
        environ: Mapping[str, str] | None = None,
    ) -> None:
        self.config = dict(config or {})
        self.transport = transport
        self.environ = environ or os.environ

    @property
    def enabled(self) -> bool:
        return (
            bool(self.config.get("enabled", False))
            and bool(str(self.config.get("base_url", "")).strip())
            and bool(str(self.config.get("model", "")).strip())
        )

    def _api_key(self) -> str:
        direct = str(self.config.get("api_key", "")).strip()
        if direct:
            return direct
        env_name = str(self.config.get("api_key_env", "")).strip()
        if env_name and self.environ.get(env_name):
            return str(self.environ.get(env_name, "")).strip()
        return str(
            self.environ.get("MONITORGPUTOOL_LLM_API_KEY")
            or self.environ.get("RUNMON_LLM_API_KEY")
            or ""
        ).strip()

    def summarize(
        self,
        *,
        run_name: str,
        command: str,
        exit_code: int | None,
        log_tail: str,
    ) -> str | None:
        if not self.enabled:
            return None
        try:
            return self._request_summary(
                run_name=run_name,
                command=command,
                exit_code=exit_code,
                log_tail=log_tail,
            )
        except Exception:
            return None

    def test_connection(self) -> dict[str, Any]:
        """用一段固定假日志验证接口；失败原因可安全返回给 App。"""
        if not self.enabled:
            return {"ok": False, "error": "请先填写接口地址和模型"}
        try:
            summary = self._request_summary(
                run_name="RunMon 接口测试",
                command="python train.py",
                exit_code=1,
                log_tail=(
                    "RuntimeError: CUDA out of memory. "
                    "Tried to allocate 2.00 GiB."
                ),
            )
            if not summary:
                return {"ok": False, "error": "接口已响应，但没有返回可读文本"}
            return {"ok": True, "summary": summary}
        except Exception as exc:
            return {"ok": False, "error": _friendly_error(exc)}

    def _request_summary(
        self,
        *,
        run_name: str,
        command: str,
        exit_code: int | None,
        log_tail: str,
    ) -> str | None:
        max_lines = max(10, min(int(self.config.get("max_log_lines", 100)), 500))
        max_chars = max(1000, min(int(self.config.get("max_log_chars", 12000)), 50000))
        tail = "\n".join(log_tail.splitlines()[-max_lines:])[-max_chars:]
        context = redact_secrets(
            f"任务名:{run_name}\n"
            f"命令:{command}\n"
            f"退出码:{exit_code if exit_code is not None else '尚未退出'}\n"
            f"日志尾部:\n{tail}"
        )
        payload: dict[str, Any] = {
            "model": str(self.config["model"]),
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "你是服务器任务报错助手。根据命令、退出码和日志判断最可能的"
                        "失败原因,用简体中文输出一到两句纯文本:先说明原因,再给一条"
                        "可执行建议。不使用 Markdown;证据不足时明确说“可能”,不要编造。"
                    ),
                },
                {"role": "user", "content": context},
            ],
            "stream": False,
        }
        base_url = str(self.config["base_url"]).strip()
        provider = str(self.config.get("provider", "")).lower()
        if provider == "openai" or "api.openai.com" in base_url.lower():
            payload["max_completion_tokens"] = 160
        else:
            payload["max_tokens"] = 160
            payload["temperature"] = 0.1
        if provider == "deepseek" or "api.deepseek.com" in base_url.lower():
            payload["thinking"] = {"type": "disabled"}

        headers = {
            "Content-Type": "application/json",
            "User-Agent": f"monitorgputool/{__version__}",
        }
        api_key = self._api_key()
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"

        timeout = max(
            1.0, min(float(self.config.get("timeout_s", _DEFAULT_TIMEOUT_S)), 30.0)
        )
        transport = self.transport or (
            _post_json_direct
            if _should_bypass_system_proxy(self.config)
            else _post_json
        )
        response = transport(
            _chat_url(base_url),
            json.dumps(payload, ensure_ascii=False).encode(),
            headers,
            timeout,
        )
        content = response["choices"][0]["message"]["content"]
        summary = _plain_summary(str(content))
        return summary or None
