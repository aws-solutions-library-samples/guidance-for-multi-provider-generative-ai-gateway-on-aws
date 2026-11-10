# Load test

Measures the gateway's capacity and behaviour under load without model cost: a
fake OpenAI-compatible upstream streams synthetic tokens with a configurable
latency, and a [locust](https://locust.io) (MIT License) driver loads the
gateway with chat completions, streaming and not. Both run inside the gateway
VPC (a VPN or a laptop link can limit and distort the results).

What a run tells you:

- **Per-task capacity**: concurrent streams and requests per second at which
  time to first token (TTFT), total time or errors start to climb.
- **CPU and memory per task** at each load level, and whether CPU
  target tracking scales the service out before latency degrades.
- **Memory over time** under steady load (leaks show as per-task growth that is
  not reclaimed).
- **Errors**: HTTP status classes, ALB 5xx/502s, streams cut short.

```text
locust driver (EC2, SSM) ──> gateway ALB ──> LiteLLM tasks ──> internal NLB ──> fake upstream (ECS)
```

| Path | Content |
| --- | --- |
| `fake_upstream/server.py` | Fake upstream: `/v1/chat/completions`, SSE streaming, latency profile from the environment or a `/p/<ttft_ms>/<itl_ms>/<tokens>/v1` path prefix |
| `locust/locustfile.py` | Scenario: closed-loop users (one request in flight each), stream/non-stream mix, cache-busting prompts, optional step profile, per-request JSONL log |
| `terraform/` | Fake upstream (Fargate + internal NLB), driver (EC2, no inbound), artifacts bucket, key secret |
| `scripts/gateway.sh` | Registers the fake models and a virtual key on the gateway; removes them |
| `scripts/driver.sh` | Starts, checks, fetches and stops runs on the driver through SSM |

## Prerequisites

- A deployed gateway ([deployment guide](../docs/deployment.md)), its admin
  (master) key in Secrets Manager, and a machine that reaches the gateway URL
  for the admin API (`scripts/gateway.sh`).
- Private subnets with outbound internet access (NAT): the fake upstream
  installs [aiohttp](https://github.com/aio-libs/aiohttp) (Apache License 2.0)
  from PyPI, the driver installs locust.
- Terraform >= 1.11, the AWS CLI, `jq`, `curl`; Python 3.11+ with
  `pip install -r requirements.txt` for the tests.

The fake upstream is unauthenticated: it serves synthetic text only, and its
security groups admit only the gateway tasks and the driver. The driver has no
inbound rules. Results are designed to contain no prompts or keys.

A private gateway admits its VPC CIDR by default. If the gateway sets
`client_cidrs`, the VPC CIDR is no longer admitted: add the driver's security
group (the `driver_security_group_id` output) to the gateway's
`client_security_group_ids` and redeploy the gateway.

The load-test infrastructure (the driver instance, the fake upstream's Fargate
tasks, its load balancer and Container Insights) runs and is billed around the
clock until you destroy it, and the load also scales the gateway out. Shutting
it down is your responsibility: run the [teardown](#teardown) right after the
test.

## Deploy

All commands on this page run from `loadtest/`:

```bash
cd loadtest
cat > terraform/loadtest.auto.tfvars <<'EOF'
vpc_id                    = "vpc-..."
subnet_ids                = ["subnet-...", "subnet-..."]   # private, with NAT
gateway_security_group_id = "sg-..."                       # <deployment_name>-service-sg
gateway_url               = "http://internal-<alb>.<region>.elb.amazonaws.com"   # or https://<gateway host>
EOF
terraform -chdir=terraform init && terraform -chdir=terraform apply
```

The load-test configuration, scenarios and results you deploy or upload are
"Your Content" as defined in the
[AWS Customer Agreement](https://aws.amazon.com/agreement/). AWS does not claim
ownership of it.

State is local by default; `terraform/providers.tf` shows how to keep it in the gateway's
state bucket under a `loadtest/` key. The latency profile (`fake_profile`)
defaults to 500 ms TTFT, 25 ms between tokens, 100-400 tokens per response and
one token per SSE chunk (about 7 s per stream; one token per chunk is the most
demanding case for the gateway, which processes every chunk).

Register the models and the key (the key goes straight into the driver's secret):

```bash
export GATEWAY_URL=http://internal-<alb>...   MASTER_KEY_SECRET_ID=<deployment>-master-key...
scripts/gateway.sh setup
```

This adds `<prefix>-fake` (the profile above) and `<prefix>-fake-instant` (no
delays, 20 tokens: measures the gateway's own overhead).

## Run

```bash
# 1. Control: the driver straight at the fake upstream. It must hold far more
#    load than the gateway will, or the fake upstream is the bottleneck.
FAKE=$(terraform -chdir=terraform output -raw fake_api_base)
scripts/driver.sh run control GATEWAY_URL=${FAKE%/v1} MODEL=fake STEPS=50:120,200:120,500:180

# 2. Saturation: step the concurrency up, hold each step long enough for
#    1-minute metrics (>= 4 min).
scripts/driver.sh run steps STEPS=10:300,20:300,40:300,60:300,80:300,120:300

# 3. Soak: steady load below saturation for >= 60 min (memory over time).
scripts/driver.sh run soak USERS=40 SPAWN_RATE=2 RUN_TIME=75m

scripts/driver.sh status steps      # running | done (exit status)
scripts/driver.sh fetch steps       # -> loadtest/results/steps/
scripts/driver.sh stop              # stops every running locust
```

Scenario settings (`KEY=VALUE`): `STEPS` or `USERS`/`SPAWN_RATE`/`RUN_TIME`,
`MODEL`, `STREAM_RATIO` (default 0.8), `PROMPT_CHARS` (2000), `MAX_TOKENS`,
`WAIT_MIN`/`WAIT_MAX` (think time, 1-3 s), `PROCESSES` (locust processes,
default one per vCPU). Every prompt starts with a UUID, so that prompts are not
repeated and the gateway's response cache (Redis) is bypassed.

The user count is the number of requests in flight: each user sends one request,
waits for the whole response (or stream), thinks, and repeats.

## Read the results

`driver.sh fetch` copies a run to `results/<run>/`:

| File | Content |
| --- | --- |
| `run.json` | Start time (epoch) and scenario settings |
| `requests-*.jsonl` | One line per request: start time `t`, `kind` (stream/chat), `status`, `ttft_ms`, `total_ms`, `chunks`, `tokens`, `overhead_ms` (LiteLLM's `x-litellm-overhead-duration-ms`), `error` |
| `locust_stats.csv`, `locust_stats_history.csv`, `report.html` | Locust's own aggregates; "chat stream" is the whole stream |
| `locust.log` | Locust output, including CPU warnings for the driver |

Group the JSONL lines by step (start time + step durations from `run.json`) or
by minute for percentiles of TTFT and total time, the request rate and the
error classes. On the server side, in CloudWatch for the run window:

| Question | Where |
| --- | --- |
| Task CPU and memory, per task | Container Insights performance log group `/aws/ecs/containerinsights/<deployment>-cluster/performance`, `Type = "Task"` events (`CpuUtilized / CpuReserved`, `MemoryUtilized`), in Logs Insights by `bin(1m), TaskId` |
| What auto scaling sees | `AWS/ECS` `CPUUtilization` / `MemoryUtilization` (service average), `ECS/ContainerInsights` `RunningTaskCount` / `DesiredTaskCount` |
| Scale-out and scale-in | Application Auto Scaling scaling activities of `service/<deployment>-cluster/<deployment>-litellm`, and the service's events |
| Errors at the load balancer | `AWS/ApplicationELB` `HTTPCode_ELB_5XX_Count` (`_502`, `_503`, `_504`) vs `HTTPCode_Target_5XX_Count`, `TargetResponseTime`, `HealthyHostCount` |
| Why LiteLLM failed requests | The LiteLLM log group: `ERROR` / `WARNING` messages in the run window |
| Fake upstream headroom | Container Insights of `<prefix>-cluster`: its CPU must stay well below its limit |

- **Saturation point**: the step at which TTFT p95 or the error share climbs
  while the request rate stops growing. Compare the task CPU at that step with
  the CPU target-tracking value: if the service does not reach the target
  before latency climbs, CPU scaling does not protect latency. LiteLLM runs one
  worker process per task: a single worker process can use at most one vCPU,
  so the CPU average of a 2-vCPU task cannot exceed about 50 %.
- **Memory**: per-task memory over a long steady run. Growth that continues at
  constant load, and is not returned after the load stops, is a leak.
- **Errors**: the `error` field (HTTP status and body, or the exception for
  streams cut short) and the ALB counts (ELB 502s without matching target 5xx
  point at connection reuse between the ALB and the tasks).
- `overhead_ms` is time spent in the gateway outside the upstream call.
- Runs can differ noticeably with identical settings; repeat a step before
  reading a small difference into it.

Load against a shared gateway also writes the request logs (S3) and spend
records (database) of every request; the auto scaling policies act on it as on
real traffic.

## Teardown

```bash
scripts/gateway.sh teardown            # models and keys named <prefix>-*
terraform -chdir=terraform destroy
```

## Tests

```bash
pip install -r requirements.txt
ruff check . && pytest                 # fake upstream, stream parsing
terraform -chdir=terraform test        # mocked provider, no AWS access
```
