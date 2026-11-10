"""Offline tests of scripts/invoke.py: region resolution and the client call. No AWS access."""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import invoke  # noqa: E402

ARN = "arn:aws:bedrock-agentcore:eu-west-1:111111111111:runtime/llmgw_agent_demo-AbCdEf1234"


@pytest.mark.parametrize(
    ("cli", "environ", "expected"),
    [
        ("us-east-1", {"AWS_REGION": "eu-central-1", "AWS_DEFAULT_REGION": "eu-north-1"}, "us-east-1"),
        (None, {"AWS_REGION": "eu-central-1", "AWS_DEFAULT_REGION": "eu-north-1"}, "eu-central-1"),
        (None, {"AWS_DEFAULT_REGION": "eu-north-1"}, "eu-north-1"),
        (None, {"AWS_REGION": ""}, "eu-west-1"),  # from the ARN
    ],
)
def test_resolve_region(cli, environ, expected):
    assert invoke.resolve_region(cli, environ, ARN) == expected


def test_no_region_anywhere_is_a_clear_error():
    with pytest.raises(SystemExit, match="No AWS region"):
        invoke.resolve_region(None, {}, "not-an-arn")


class _FakeClient:
    def __init__(self):
        self.calls = []

    def invoke_agent_runtime(self, **kwargs):
        self.calls.append(kwargs)
        return {"response": io.BytesIO(json.dumps({"result": "ok"}).encode())}


def test_client_gets_region_explicitly_with_only_aws_region_set(capsys):
    fake = _FakeClient()
    made = []

    def factory(service, **kwargs):
        made.append((service, kwargs))
        return fake

    rc = invoke.main(["hello", "--arn", ARN], environ={"AWS_REGION": "ap-southeast-2"}, client_factory=factory)

    assert rc == 0
    assert made == [("bedrock-agentcore", {"region_name": "ap-southeast-2"})]
    [call] = fake.calls
    assert call["agentRuntimeArn"] == ARN
    assert call["runtimeUserId"] == "example-user"
    assert len(call["runtimeSessionId"]) >= 33
    assert json.loads(call["payload"]) == {"prompt": "hello"}
    assert json.loads(capsys.readouterr().out) == {"result": "ok"}
