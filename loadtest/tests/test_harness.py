"""Offline tests: the fake upstream speaks the OpenAI chat API and the locust
scenario parses its stream."""

import server
from locustfile import parse_sse, parse_steps

INSTANT = server.Profile(ttft_ms=0, itl_ms=0, tokens_min=5, tokens_max=5, jitter=0, tokens_per_chunk=1)


async def test_non_streaming_completion(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post(
        "/v1/chat/completions", json={"model": "m", "messages": [{"role": "user", "content": "x" * 40}]}
    )
    assert resp.status == 200
    body = await resp.json()
    assert body["object"] == "chat.completion"
    assert body["usage"] == {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
    assert len(body["choices"][0]["message"]["content"].split()) == 5


async def test_stream_parses_with_the_scenario_parser(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post(
        "/v1/chat/completions",
        json={"model": "m", "stream": True, "stream_options": {"include_usage": True}, "messages": []},
    )
    assert resp.headers["Content-Type"].startswith("text/event-stream")
    lines = (await resp.text()).splitlines()
    first, chunks, tokens, done = parse_sse(lines)
    assert first is not None and chunks == 5 and tokens == 5 and done


async def test_path_profile_overrides_length(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post("/p/0/0/3/v1/chat/completions", json={"stream": True, "messages": []})
    _, chunks, tokens, done = parse_sse((await resp.text()).splitlines())
    assert (chunks, tokens, done) == (3, None, True)  # no usage chunk unless asked


async def test_max_tokens_caps_the_response(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post("/v1/chat/completions", json={"max_tokens": 2, "messages": []})
    assert (await resp.json())["usage"]["completion_tokens"] == 2


async def test_invalid_json_is_a_400(aiohttp_client):
    client = await aiohttp_client(server.make_app(INSTANT))
    resp = await client.post("/v1/chat/completions", data=b"{nope")
    assert resp.status == 400


def test_parse_sse_handles_spaced_json_and_truncation():
    spaced = 'data: {"choices": [{"delta": {"content": " hi"}}]}'
    empty = 'data: {"choices": [{"delta": {"role": "assistant", "content": ""}}]}'
    first, chunks, tokens, done = parse_sse([empty, spaced, spaced])
    assert chunks == 2 and first is not None and tokens is None and not done


def test_parse_steps():
    assert parse_steps("10:60, 20:120") == [(10, 60), (20, 120)]
