"""Locust scenario for the LiteLLM gateway: chat completions, streaming and not.

Every simulated user holds at most one request in flight (closed loop), so the
user count is the number of concurrent requests (streams) against the gateway.

Configuration (environment):
  API_KEY          LiteLLM virtual key (required)
  MODEL            model name registered on the gateway, default llmgw-load-fake
  STREAM_RATIO     share of streaming requests, 0..1, default 0.8
  PROMPT_CHARS     user prompt size in characters (~4 per token), default 2000
  MAX_TOKENS       max_tokens sent with every request, default unset
  WAIT_MIN/WAIT_MAX  think time between a user's requests in seconds, default 1/3
  STEPS            optional step profile "users:seconds,users:seconds,..."; the
                   run stops after the last step. Without it, -u/-t apply.
  SPAWN_RATE       users started per second between steps, default 5
  REQUEST_LOG_DIR  directory for the per-request JSONL log, default ./results

Every prompt starts with a random UUID, so that prompts are not repeated and
the gateway's response cache is bypassed (identical prompts would load Redis,
not the gateway).

Locust statistics: "chat stream" times the whole stream (first byte to
[DONE]); "chat" times the whole response. Time to first token, chunk counts and
the gateway's own x-litellm-overhead-duration-ms header go to the per-request
log only, so locust's aggregate request rate stays the real request rate.
"""

from __future__ import annotations

import json
import os
import random
import re
import time
import uuid

from locust.runners import WorkerRunner

from locust import FastHttpUser, LoadTestShape, between, events, task

MODEL = os.environ.get("MODEL", "llmgw-load-fake")
STREAM_RATIO = float(os.environ.get("STREAM_RATIO", "0.8"))
PROMPT_CHARS = int(os.environ.get("PROMPT_CHARS", "2000"))
MAX_TOKENS = int(os.environ["MAX_TOKENS"]) if os.environ.get("MAX_TOKENS") else None
WAIT_MIN = float(os.environ.get("WAIT_MIN", "1"))
WAIT_MAX = float(os.environ.get("WAIT_MAX", "3"))
LOG_DIR = os.environ.get("REQUEST_LOG_DIR", "results")

FILLER = (
    "Summarise the operational trade-offs of running a shared model gateway for many teams, "
    "covering budgets, rate limits, fallbacks, observability and failure handling. "
)


def prompt() -> str:
    body = (FILLER * (PROMPT_CHARS // len(FILLER) + 1))[:PROMPT_CHARS]
    return f"{uuid.uuid4()} {body}"


class RequestLog:
    """One JSON line per request; one file per locust process."""

    def __init__(self) -> None:
        self._fh = None

    def write(self, record: dict) -> None:
        if self._fh is None:
            os.makedirs(LOG_DIR, exist_ok=True)
            self._fh = open(os.path.join(LOG_DIR, f"requests-{os.getpid()}.jsonl"), "a", buffering=1)
        self._fh.write(json.dumps(record, separators=(",", ":")) + "\n")

    def close(self) -> None:
        if self._fh is not None:
            self._fh.close()
            self._fh = None


REQUEST_LOG = RequestLog()


@events.quitting.add_listener
def _close_log(**_kwargs) -> None:
    REQUEST_LOG.close()


@events.test_start.add_listener
def _write_run_meta(environment, **_kwargs) -> None:
    """The coordinating process records when the run started and how it was configured."""
    if isinstance(environment.runner, WorkerRunner):
        return
    os.makedirs(LOG_DIR, exist_ok=True)
    meta = {
        "start": time.time(),
        "host": environment.host,
        "model": MODEL,
        "stream_ratio": STREAM_RATIO,
        "prompt_chars": PROMPT_CHARS,
        "max_tokens": MAX_TOKENS,
        "wait": [WAIT_MIN, WAIT_MAX],
        "steps": os.environ.get("STEPS"),
    }
    with open(os.path.join(LOG_DIR, "run.json"), "w") as fh:
        json.dump(meta, fh, indent=1)


CONTENT = re.compile(r'"content":\s*"(?!")')


def parse_sse(lines) -> tuple[float | None, int, int | None, bool]:
    """Consume SSE lines; return (first-content time, content chunks, completion tokens, saw [DONE]).

    Content chunks are recognised by a regular expression rather than parsed
    as JSON (a stream has hundreds of them; the driver's CPU is the limit);
    only the usage chunk is decoded.
    """
    first = None
    chunks = 0
    tokens = None
    done = False
    for raw in lines:
        line = raw.strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            done = True
            break
        if CONTENT.search(data):
            chunks += 1
            if first is None:
                first = time.perf_counter()
        elif '"usage"' in data:
            try:
                usage = json.loads(data).get("usage") or {}
            except json.JSONDecodeError:
                continue
            tokens = usage.get("completion_tokens", tokens)
    return first, chunks, tokens, done


def iter_lines(response):
    """Yield SSE lines as they arrive.

    Reads line by line from the connection: FastResponse.iter_content(n) blocks
    until n bytes have arrived, which would delay the first token by however
    long the upstream takes to send n bytes.
    """
    raw = response._response
    while True:
        line = raw.readline(b"\n")
        if not line:
            return
        yield line.decode("utf-8", errors="replace")


class GatewayUser(FastHttpUser):
    wait_time = between(WAIT_MIN, WAIT_MAX)
    network_timeout = 600.0
    connection_timeout = 10.0
    concurrency = 1  # one connection per user: closed loop, one request in flight

    def on_start(self) -> None:
        key = os.environ.get("API_KEY")
        if not key:
            raise RuntimeError("API_KEY is not set")
        self.headers = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}

    def body(self, stream: bool) -> dict:
        body = {"model": MODEL, "messages": [{"role": "user", "content": prompt()}], "stream": stream}
        if stream:
            body["stream_options"] = {"include_usage": True}
        if MAX_TOKENS:
            body["max_tokens"] = MAX_TOKENS
        return body

    @task
    def chat(self) -> None:
        stream = random.random() < STREAM_RATIO
        record = {"t": time.time(), "kind": "stream" if stream else "chat"}
        start = time.perf_counter()
        with self.client.post(
            "/v1/chat/completions",
            data=json.dumps(self.body(stream)),
            headers=self.headers,
            name="chat stream" if stream else "chat",
            stream=stream,
            catch_response=True,
        ) as resp:
            record["status"] = resp.status_code
            overhead = (resp.headers or {}).get("x-litellm-overhead-duration-ms")
            if overhead:
                record["overhead_ms"] = float(overhead)
            try:
                if resp.status_code == 0:  # no HTTP response: connect/reset/timeout
                    error = getattr(resp, "error", None)
                    record["error"] = f"{type(error).__name__}: {error}"[:200]
                    resp.failure(record["error"])
                elif resp.status_code != 200:
                    text = (resp.text or "")[:200]
                    record["error"] = f"HTTP {resp.status_code} {text}".strip()
                    resp.failure(record["error"])
                elif stream:
                    first, chunks, tokens, done = parse_sse(iter_lines(resp))
                    end = time.perf_counter()
                    resp.request_meta["response_time"] = (end - start) * 1000
                    record.update(chunks=chunks, tokens=tokens)
                    if first is not None:
                        record["ttft_ms"] = round((first - start) * 1000, 1)
                    if not done or chunks == 0:
                        record["error"] = "stream ended without [DONE]" if not done else "stream without content"
                        resp.failure(record["error"])
                    else:
                        resp.success()
                else:
                    usage = resp.json().get("usage") or {}
                    record["tokens"] = usage.get("completion_tokens")
                    resp.success()
            except Exception as exc:  # network errors mid-stream, bad JSON
                record["error"] = f"{type(exc).__name__}: {exc}"[:200]
                resp.failure(record["error"])
            record["total_ms"] = round((time.perf_counter() - start) * 1000, 1)
        REQUEST_LOG.write(record)


def parse_steps(spec: str) -> list[tuple[int, int]]:
    steps = []
    for part in spec.split(","):
        users, seconds = part.strip().split(":")
        steps.append((int(users), int(seconds)))
    return steps


if os.environ.get("STEPS"):

    class StepShape(LoadTestShape):
        """Hold each user count for its duration, then stop."""

        steps = parse_steps(os.environ["STEPS"])
        spawn_rate = float(os.environ.get("SPAWN_RATE", "5"))

        def tick(self):
            elapsed = self.get_run_time()
            for users, seconds in self.steps:
                if elapsed < seconds:
                    return users, self.spawn_rate
                elapsed -= seconds
            return None
