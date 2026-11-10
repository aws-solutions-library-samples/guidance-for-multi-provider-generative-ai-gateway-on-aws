"""Offline tests of the agent: configuration, and a full invocation against a
local stand-in for the gateway's OpenAI-compatible API. No AWS access."""

from __future__ import annotations

import asyncio
import base64
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main  # noqa: E402


@pytest.fixture
def env(monkeypatch):
    monkeypatch.setenv("GATEWAY_BASE_URL", "http://gateway.internal/")
    monkeypatch.setenv("MODEL_ID", "test-model")
    monkeypatch.setenv("CREDENTIAL_PROVIDER", "test-provider")
    monkeypatch.delenv("MAX_TOKENS", raising=False)


def test_word_count():
    assert main.word_count("one two  three\nfour") == 4


def test_settings(env):
    s = main.gateway_settings()
    assert s == {
        "base_url": "http://gateway.internal",
        "model_id": "test-model",
        "credential_provider": "test-provider",
        "max_tokens": 1024,
        "ca_pem": None,
    }


def test_settings_reject_url_without_scheme(env, monkeypatch):
    monkeypatch.setenv("GATEWAY_BASE_URL", "gateway.internal")
    with pytest.raises(ValueError):
        main.gateway_settings()


def test_model_targets_gateway_openai_api(env):
    model = main.build_model(main.gateway_settings(), "sk-test")
    assert model.client_args["base_url"] == "http://gateway.internal/v1"
    assert model.client_args["api_key"] == "sk-test"
    assert model.get_config()["model_id"] == "test-model"


def test_model_without_private_ca_uses_default_client(env):
    model = main.build_model(main.gateway_settings(), "sk-test")
    assert "http_client" not in model.client_args


def test_model_trusts_a_private_ca(env, monkeypatch):
    import certifi

    # Any valid CA certificate stands in for the private one.
    bundle = Path(certifi.where()).read_text()
    end = "-----END CERTIFICATE-----"
    ca_pem = bundle[bundle.index("-----BEGIN CERTIFICATE-----") : bundle.index(end) + len(end)]
    monkeypatch.setenv("GATEWAY_CA_PEM_BASE64", base64.b64encode(ca_pem.encode()).decode())
    settings = main.gateway_settings()
    assert settings["ca_pem"] == ca_pem
    context = main.tls_context(ca_pem)
    assert context.verify_mode.name == "CERT_REQUIRED"
    assert len(context.get_ca_certs()) > 1
    http_client = main.openai.DefaultAsyncHttpxClient(verify=context)
    model = main.build_model(settings, "sk-test", http_client)
    assert model.client_args == {}
    assert str(model._custom_client.base_url) == "http://gateway.internal/v1/"
    asyncio.run(http_client.aclose())


def test_rejects_missing_prompt(env):
    assert "error" in asyncio.run(main.invoke({}))
    assert "error" in asyncio.run(main.invoke({"prompt": "  "}))


class _FakeGateway(BaseHTTPRequestHandler):
    """Answers /v1/chat/completions with a streamed completion and records requests."""

    requests: list[dict] = []
    tool_call_first = False

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).requests.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
        tool_answered = any(m.get("role") == "tool" for m in body.get("messages", []))
        if type(self).tool_call_first and not tool_answered:
            call = {"index": 0, "id": "call-1", "type": "function"}
            call["function"] = {"name": "word_count", "arguments": json.dumps({"text": "the quick brown fox"})}
            chunks = [
                {"choices": [{"index": 0, "delta": {"role": "assistant", "tool_calls": [call]}}]},
                {"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]},
                {"choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 5, "total_tokens": 16}},
            ]
            self._stream(body, chunks)
            return
        chunks = [
            {"choices": [{"index": 0, "delta": {"role": "assistant", "content": "Hello from the gateway."}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            {"choices": [], "usage": {"prompt_tokens": 11, "completion_tokens": 5, "total_tokens": 16}},
        ]
        self._stream(body, chunks)

    def _stream(self, body, chunks):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for c in chunks:
            c.update({"id": "x", "object": "chat.completion.chunk", "created": 0, "model": body["model"]})
            self.wfile.write(f"data: {json.dumps(c)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")


def test_invocation_goes_through_gateway_with_the_identity_key(env, monkeypatch):
    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeGateway)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setenv("GATEWAY_BASE_URL", f"http://127.0.0.1:{server.server_port}")

    requested = []

    def fake_fetcher(provider_name):
        requested.append(provider_name)

        async def fetch():
            return "sk-from-identity"

        return fetch

    monkeypatch.setattr(main, "key_fetcher", fake_fetcher)
    _FakeGateway.requests = []
    try:
        out = asyncio.run(main.invoke({"prompt": "Say hello."}))
    finally:
        server.shutdown()

    assert requested == ["test-provider"]
    assert out["result"] == "Hello from the gateway."
    assert out["usage"]["totalTokens"] == 16
    [req] = _FakeGateway.requests
    assert req["path"] == "/v1/chat/completions"
    assert req["auth"] == "Bearer sk-from-identity"
    assert req["body"]["model"] == "test-model"
    assert req["body"]["max_tokens"] == 1024
    assert any(t["function"]["name"] == "word_count" for t in req["body"]["tools"])


def test_tool_round_trip_with_private_ca_keeps_the_client_open(env, monkeypatch):
    """Two model calls in one invocation (tool call, then answer) over the injected client."""
    import certifi

    server = ThreadingHTTPServer(("127.0.0.1", 0), _FakeGateway)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setenv("GATEWAY_BASE_URL", f"http://127.0.0.1:{server.server_port}")
    bundle = Path(certifi.where()).read_text()
    end = "-----END CERTIFICATE-----"
    ca_pem = bundle[bundle.index("-----BEGIN CERTIFICATE-----") : bundle.index(end) + len(end)]
    monkeypatch.setenv("GATEWAY_CA_PEM_BASE64", base64.b64encode(ca_pem.encode()).decode())

    def fake_fetcher(provider_name):
        async def fetch():
            return "sk-from-identity"

        return fetch

    monkeypatch.setattr(main, "key_fetcher", fake_fetcher)
    _FakeGateway.requests = []
    _FakeGateway.tool_call_first = True
    try:
        out = asyncio.run(main.invoke({"prompt": "How many words are in 'the quick brown fox'?"}))
    finally:
        _FakeGateway.tool_call_first = False
        server.shutdown()

    assert out.get("result") == "Hello from the gateway.", out
    assert len(_FakeGateway.requests) == 2
    assert all(r["auth"] == "Bearer sk-from-identity" for r in _FakeGateway.requests)


def test_missing_workload_token_is_reported(env, monkeypatch):
    def fetcher(provider_name):
        async def fetch():
            raise ValueError("Workload access token has not been set.")

        return fetch

    monkeypatch.setattr(main, "key_fetcher", fetcher)
    out = asyncio.run(main.invoke({"prompt": "hi"}))
    assert out["error"].startswith("Could not obtain the gateway key")


class _RejectingGateway(BaseHTTPRequestHandler):
    """Answers like LiteLLM does for a key over its budget."""

    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        body = json.dumps({"error": {"message": "Budget has been exceeded!", "type": "budget_exceeded", "code": "400"}})
        self.send_response(400)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())


def test_gateway_rejection_is_reported(env, monkeypatch):
    server = ThreadingHTTPServer(("127.0.0.1", 0), _RejectingGateway)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    monkeypatch.setenv("GATEWAY_BASE_URL", f"http://127.0.0.1:{server.server_port}")

    def fetcher(provider_name):
        async def fetch():
            return "sk-test"

        return fetch

    monkeypatch.setattr(main, "key_fetcher", fetcher)
    try:
        out = asyncio.run(main.invoke({"prompt": "hi"}))
    finally:
        server.shutdown()
    assert "HTTP 400" in out["error"] and "Budget has been exceeded" in out["error"]
