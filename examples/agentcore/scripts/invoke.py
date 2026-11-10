#!/usr/bin/env python3
"""Invoke the deployed agent through AgentCore Runtime and print its reply.

    AWS_REGION=<region> python3 scripts/invoke.py "How many words are in 'the quick brown fox'?"

The region is --region, else AWS_REGION, else AWS_DEFAULT_REGION, else the
region in the runtime ARN; it is passed to the client explicitly (boto3 itself
does not read AWS_REGION).

The runtime ARN is read from the example's Terraform outputs unless --arn is
given. The call is signed with your AWS credentials (bedrock-agentcore:
InvokeAgentRuntime and InvokeAgentRuntimeForUser on the runtime). The user ID
names the end user the runtime issues the invocation's workload access token
for, which the agent exchanges for its gateway key at AgentCore Identity.

Requires boto3 (pip install boto3).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import uuid
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

import boto3

TF_DIR = Path(__file__).resolve().parents[1] / "terraform"


def runtime_arn_from_terraform() -> str:
    out = subprocess.run(
        ["terraform", f"-chdir={TF_DIR}", "output", "-raw", "agent_runtime_arn"],
        check=True,
        capture_output=True,
        text=True,
    )
    return out.stdout.strip()


def resolve_region(cli_region: str | None, environ: Mapping[str, str], arn: str) -> str:
    """--region, then AWS_REGION, then AWS_DEFAULT_REGION, then the runtime ARN's region."""
    for candidate in (cli_region, environ.get("AWS_REGION"), environ.get("AWS_DEFAULT_REGION")):
        if candidate:
            return candidate
    parts = arn.split(":")
    if len(parts) > 3 and parts[2] == "bedrock-agentcore" and parts[3]:
        return parts[3]
    raise SystemExit("No AWS region: pass --region or set AWS_REGION.")


def main(
    argv: Sequence[str] | None = None,
    environ: Mapping[str, str] = os.environ,
    client_factory: Callable[..., Any] = boto3.client,
) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("prompt")
    parser.add_argument("--arn", help="agent runtime ARN (default: Terraform output agent_runtime_arn)")
    parser.add_argument("--region", help="AWS region (default: AWS_REGION, then AWS_DEFAULT_REGION)")
    parser.add_argument("--user-id", default="example-user", help="runtime user ID (default: example-user)")
    parser.add_argument("--session-id", help="runtime session ID, 33+ characters (default: a new one)")
    args = parser.parse_args(argv)

    arn = args.arn or runtime_arn_from_terraform()
    region = resolve_region(args.region, environ, arn)
    session_id = args.session_id or f"{uuid.uuid4()}-{uuid.uuid4().hex[:8]}"
    client = client_factory("bedrock-agentcore", region_name=region)
    resp = client.invoke_agent_runtime(
        agentRuntimeArn=arn,
        runtimeSessionId=session_id,
        runtimeUserId=args.user_id,
        contentType="application/json",
        accept="application/json",
        payload=json.dumps({"prompt": args.prompt}).encode(),
    )
    body = resp["response"].read().decode()
    try:
        print(json.dumps(json.loads(body), indent=2))
    except json.JSONDecodeError:
        print(body)
    print(f"session: {session_id}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
