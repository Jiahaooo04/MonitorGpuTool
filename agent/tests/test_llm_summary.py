import json

from runmon.llm_summary import (
    LLMSummarizer,
    _should_bypass_system_proxy,
    redact_secrets,
)


def test_redact_secrets_masks_common_credentials():
    text = (
        "Authorization: Bearer bearer-secret-123\n"
        "api_key=sk-secret-key-456\n"
        "password: hunter2\n"
        "CUDA out of memory"
    )

    redacted = redact_secrets(text)

    assert "bearer-secret-123" not in redacted
    assert "sk-secret-key-456" not in redacted
    assert "hunter2" not in redacted
    assert redacted.count("[REDACTED]") == 3
    assert "CUDA out of memory" in redacted


def test_summarize_sends_redacted_openai_compatible_request(monkeypatch):
    monkeypatch.setenv("RUNMON_TEST_LLM_KEY", "test-key")
    calls = []

    def transport(url, data, headers, timeout):
        calls.append((url, json.loads(data), headers, timeout))
        return {
            "choices": [{
                "message": {
                    "content": "**原因：** CUDA 显存不足。\n建议减小 batch_size。"
                }
            }]
        }

    summarizer = LLMSummarizer({
        "enabled": True,
        "base_url": "https://api.example.com/v1",
        "api_key_env": "RUNMON_TEST_LLM_KEY",
        "model": "example-chat",
        "timeout_s": 7,
    }, transport=transport)

    summary = summarizer.summarize(
        run_name="train.py",
        command="python train.py --token sk-command-secret",
        exit_code=1,
        log_tail="api_key=sk-log-secret\nRuntimeError: CUDA out of memory",
    )

    assert summary == "原因： CUDA 显存不足。 建议减小 batch_size。"
    url, payload, headers, timeout = calls[0]
    assert url == "https://api.example.com/v1/chat/completions"
    assert payload["model"] == "example-chat"
    assert payload["stream"] is False
    prompt = payload["messages"][-1]["content"]
    assert "sk-command-secret" not in prompt
    assert "sk-log-secret" not in prompt
    assert prompt.count("[REDACTED]") == 2
    assert headers["Authorization"] == "Bearer test-key"
    assert timeout == 7


def test_summarize_deepseek_disables_thinking():
    captured = {}

    def transport(_url, data, _headers, _timeout):
        captured.update(json.loads(data))
        return {"choices": [{"message": {"content": "Python 主动抛出了 RuntimeError。"}}]}

    summarizer = LLMSummarizer({
        "enabled": True,
        "base_url": "https://api.deepseek.com",
        "api_key": "test-key",
        "model": "deepseek-v4-flash",
    }, transport=transport)

    assert summarizer.summarize(
        run_name="job", command="python job.py", exit_code=1,
        log_tail="RuntimeError: boom",
    )
    assert captured["thinking"] == {"type": "disabled"}


def test_summarize_returns_none_when_disabled_or_request_fails():
    disabled = LLMSummarizer({})
    assert disabled.summarize(
        run_name="job", command="false", exit_code=1, log_tail="failed",
    ) is None

    def broken(*_args):
        raise TimeoutError("slow")

    enabled = LLMSummarizer({
        "enabled": True,
        "base_url": "http://127.0.0.1:11434/v1",
        "model": "local-model",
    }, transport=broken)
    assert enabled.summarize(
        run_name="job", command="false", exit_code=1, log_tail="failed",
    ) is None


def test_summary_is_bounded_and_plain_text():
    def transport(*_args):
        return {
            "choices": [{
                "message": {
                    "content": "# 分析\n```text\n" + ("显存不足 " * 80) + "\n```"
                }
            }]
        }

    summarizer = LLMSummarizer({
        "enabled": True,
        "base_url": "http://127.0.0.1:11434/v1",
        "model": "local-model",
    }, transport=transport)

    summary = summarizer.summarize(
        run_name="job", command="false", exit_code=1, log_tail="OOM",
    )

    assert summary is not None
    assert len(summary) <= 220
    assert "#" not in summary and "```" not in summary and "\n" not in summary


def test_connection_returns_preview_without_saving():
    def transport(_url, _data, _headers, _timeout):
        return {
            "choices": [{
                "message": {
                    "content": "可能是 CUDA 显存不足。建议减小 batch_size。"
                }
            }]
        }

    summarizer = LLMSummarizer({
        "enabled": True,
        "base_url": "https://api.example.com/v1",
        "api_key": "test-key",
        "model": "example-chat",
    }, transport=transport)

    result = summarizer.test_connection()

    assert result == {
        "ok": True,
        "summary": "可能是 CUDA 显存不足。建议减小 batch_size。",
    }


def test_connection_returns_safe_actionable_error():
    def broken(*_args):
        raise TimeoutError("api_key=sk-secret-timeout")

    summarizer = LLMSummarizer({
        "enabled": True,
        "base_url": "https://api.example.com/v1",
        "api_key": "test-key",
        "model": "example-chat",
    }, transport=broken)

    result = summarizer.test_connection()

    assert result["ok"] is False
    assert "连接超时" in result["error"]
    assert "sk-secret-timeout" not in result["error"]


def test_domestic_and_local_providers_bypass_broken_system_proxy():
    for provider in ("deepseek", "qwen", "kimi", "ollama"):
        assert _should_bypass_system_proxy({
            "provider": provider,
            "base_url": "https://api.example.com/v1",
        })

    assert _should_bypass_system_proxy({
        "provider": "custom",
        "base_url": "http://127.0.0.1:8000/v1",
    })
    assert not _should_bypass_system_proxy({
        "provider": "openai",
        "base_url": "https://api.openai.com/v1",
    })
    assert not _should_bypass_system_proxy({
        "provider": "deepseek",
        "base_url": "https://api.deepseek.com",
        "use_system_proxy": True,
    })
