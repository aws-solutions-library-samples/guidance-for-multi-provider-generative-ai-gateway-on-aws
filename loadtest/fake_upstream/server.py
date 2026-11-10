"""OpenAI-compatible fake LLM upstream for gateway load tests.

Serves POST /v1/chat/completions (streaming and non-streaming) with a
configurable time to first token, inter-token delay and response length, so the
gateway can be loaded without model cost. Responses are synthetic text; the
request body is read and discarded.

Latency profile (environment, overridable per model through a path prefix):
  FAKE_TTFT_MS        time to first token, default 300
  FAKE_ITL_MS         delay between streamed tokens, default 20
  FAKE_TOKENS_MIN     response length range in tokens, default 100
  FAKE_TOKENS_MAX     default 300
  FAKE_JITTER         relative jitter on every delay (0..1), default 0.2
  FAKE_TOKENS_PER_CHUNK  tokens per SSE chunk, default 1

Path prefix /p/<ttft_ms>/<itl_ms>/<tokens>/v1/... overrides the profile for
one registered model (for example /p/0/0/10/v1 for an instant upstream).

Process model: FAKE_WORKERS processes share the port (SO_REUSEPORT).
Bind: FAKE_HOST, default 127.0.0.1; the container sets 0.0.0.0 and the
network (security groups) is the boundary.
"""

from __future__ import annotations

import asyncio
import json
import multiprocessing
import os
import random
import time
import uuid
from dataclasses import dataclass, replace

from aiohttp import web

WORDS = (  # noqa: SIM905 - prose is easier to edit than a word list
    "the gateway routes each request to a provider and streams the answer back "
    "while budgets rate limits and logs are applied on the way through"
).split()


@dataclass(frozen=True)
class Profile:
    ttft_ms: float
    itl_ms: float
    tokens_min: int
    tokens_max: int
    jitter: float
    tokens_per_chunk: int

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> Profile:
        env = os.environ if env is None else env
        return cls(
            ttft_ms=float(env.get("FAKE_TTFT_MS", "300")),
            itl_ms=float(env.get("FAKE_ITL_MS", "20")),
            tokens_min=int(env.get("FAKE_TOKENS_MIN", "100")),
            tokens_max=int(env.get("FAKE_TOKENS_MAX", "300")),
            jitter=float(env.get("FAKE_JITTER", "0.2")),
            tokens_per_chunk=max(1, int(env.get("FAKE_TOKENS_PER_CHUNK", "1"))),
        )

    def delay(self, ms: float) -> float:
        if ms <= 0:
            return 0.0
        return max(0.0, ms * (1 + random.uniform(-self.jitter, self.jitter))) / 1000

    def tokens(self, max_tokens: int | None) -> int:
        n = random.randint(self.tokens_min, max(self.tokens_min, self.tokens_max))
        return min(n, max_tokens) if max_tokens else n


PROFILE = web.AppKey("profile", Profile)


def profile_for(request: web.Request) -> Profile:
    base = request.app[PROFILE]
    if "ttft" not in request.match_info:
        return base
    tokens = int(request.match_info["tokens"])
    return replace(
        base,
        ttft_ms=float(request.match_info["ttft"]),
        itl_ms=float(request.match_info["itl"]),
        tokens_min=tokens,
        tokens_max=tokens,
    )


def prompt_tokens(body: dict) -> int:
    # About four characters per token, enough for usage accounting.
    chars = sum(len(str(m.get("content", ""))) for m in body.get("messages", []))
    return max(1, chars // 4)


def chunk(
    cid: str, model: str, created: int, delta: dict, finish: str | None = None, usage: dict | None = None
) -> bytes:
    payload = {
        "id": cid,
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}] if usage is None else [],
    }
    if usage is not None:
        payload["usage"] = usage
    return b"data: " + json.dumps(payload, separators=(",", ":")).encode() + b"\n\n"


async def chat_completions(request: web.Request) -> web.StreamResponse:
    try:
        body = await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        return web.json_response(
            {"error": {"message": "invalid JSON body", "type": "invalid_request_error"}}, status=400
        )
    profile = profile_for(request)
    model = str(body.get("model", "fake"))
    max_tokens = body.get("max_tokens") or body.get("max_completion_tokens")
    n_out = profile.tokens(int(max_tokens) if max_tokens else None)
    n_in = prompt_tokens(body)
    usage = {"prompt_tokens": n_in, "completion_tokens": n_out, "total_tokens": n_in + n_out}
    cid = "chatcmpl-" + uuid.uuid4().hex
    created = int(time.time())
    words = [WORDS[i % len(WORDS)] for i in range(n_out)]

    await asyncio.sleep(profile.delay(profile.ttft_ms))

    if not body.get("stream"):
        await asyncio.sleep(profile.delay(profile.itl_ms * n_out))
        return web.json_response(
            {
                "id": cid,
                "object": "chat.completion",
                "created": created,
                "model": model,
                "choices": [
                    {"index": 0, "message": {"role": "assistant", "content": " ".join(words)}, "finish_reason": "stop"}
                ],
                "usage": usage,
            }
        )

    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
    await resp.prepare(request)
    await resp.write(chunk(cid, model, created, {"role": "assistant", "content": ""}))
    step = profile.tokens_per_chunk
    for i in range(0, n_out, step):
        if i:
            await asyncio.sleep(profile.delay(profile.itl_ms * step))
        text = "".join(" " + w for w in words[i : i + step])
        await resp.write(chunk(cid, model, created, {"content": text}))
    await resp.write(chunk(cid, model, created, {}, finish="stop"))
    if (body.get("stream_options") or {}).get("include_usage"):
        await resp.write(chunk(cid, model, created, {}, usage=usage))
    await resp.write(b"data: [DONE]\n\n")
    await resp.write_eof()
    return resp


async def models(_: web.Request) -> web.Response:
    return web.json_response({"object": "list", "data": [{"id": "fake", "object": "model", "owned_by": "fake"}]})


async def health(_: web.Request) -> web.Response:
    return web.json_response({"status": "ok"})


def make_app(profile: Profile | None = None) -> web.Application:
    app = web.Application(client_max_size=32 * 1024 * 1024)
    app[PROFILE] = profile or Profile.from_env()
    for prefix in ("", "/v1", "/p/{ttft}/{itl}/{tokens}", "/p/{ttft}/{itl}/{tokens}/v1"):
        app.router.add_post(prefix + "/chat/completions", chat_completions)
        app.router.add_get(prefix + "/models", models)
    app.router.add_get("/health", health)
    return app


def serve(host: str, port: int) -> None:
    web.run_app(make_app(), host=host, port=port, reuse_port=True, access_log=None, print=None)


def main() -> None:
    host = os.environ.get("FAKE_HOST", "127.0.0.1")
    port = int(os.environ.get("FAKE_PORT", "8080"))
    workers = int(os.environ.get("FAKE_WORKERS", str(os.cpu_count() or 1)))
    print(f"fake upstream on {host}:{port}, {workers} worker(s), profile {Profile.from_env()}", flush=True)
    if workers <= 1:
        serve(host, port)
        return
    procs = [multiprocessing.Process(target=serve, args=(host, port)) for _ in range(workers)]
    for p in procs:
        p.start()
    for p in procs:
        p.join()


if __name__ == "__main__":
    main()
