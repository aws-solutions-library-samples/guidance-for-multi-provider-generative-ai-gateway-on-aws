"""Offline tests of the container health check (templates/healthcheck.py.tftpl).

The script is rendered the way container.tf renders it (template variables
substituted, comment lines dropped; wiring.tftest.hcl asserts the task
definition carries exactly this rendering) and run the way ECS runs it:
sh -c 'python3 -c "<script>" || exit 1', against a local fake of the LiteLLM
liveliness path and the ECS task metadata endpoint.

  python3 -m unittest discover -s terraform/app/tests -p 'test_*.py'

Standard library only.
"""

from __future__ import annotations

import http.server
import json
import os
import re
import socket
import subprocess
import sys
import threading
import unittest

TEMPLATE = os.path.join(os.path.dirname(__file__), "..", "templates", "healthcheck.py.tftpl")
MIB = 2**20
THRESHOLD_MIB = 100


def render(liveliness_url: str, threshold_mib: int) -> str:
    with open(TEMPLATE) as fh:
        script = fh.read()
    script = script.replace("${liveliness_url}", liveliness_url).replace("${threshold_mib}", str(threshold_mib))
    return re.sub(r"(?m)^[ ]*#.*\n", "", script)


class Fake(http.server.BaseHTTPRequestHandler):
    """Serves /health/liveliness and /v4/task/stats from class attributes."""

    liveliness_status = 200
    stats: object = {}

    def do_GET(self):
        if self.path == "/health/liveliness":
            body, status = b'"I\'m alive!"', self.liveliness_status
        elif self.path == "/v4/task/stats":
            body = self.stats if isinstance(self.stats, bytes) else json.dumps(self.stats).encode()
            status = 200
        else:
            body, status = b"not found", 404
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def container(usage_mib: float, **detail_mib: float) -> dict:
    return {"memory_stats": {"usage": int(usage_mib * MIB), "stats": {k: int(v * MIB) for k, v in detail_mib.items()}}}


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HealthCheckTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.script = render(f"{cls.base}/health/liveliness", THRESHOLD_MIB)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def setUp(self):
        Fake.liveliness_status = 200
        Fake.stats = {}

    def run_check(self, metadata: str | None = "default") -> int:
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        if metadata == "default":
            env["ECS_CONTAINER_METADATA_URI_V4"] = f"{self.base}/v4"
        elif metadata is not None:
            env["ECS_CONTAINER_METADATA_URI_V4"] = metadata
        command = f'{sys.executable} -c "{self.script}" || exit 1'
        return subprocess.run(["sh", "-c", command], check=False, env=env, capture_output=True, timeout=30).returncode

    def test_script_is_shell_safe(self):
        self.assertIsNone(re.search(r'["`$\\]', self.script))
        self.assertNotIn("#", "".join(line.strip()[:1] for line in self.script.splitlines()))

    def test_below_threshold_is_healthy(self):
        Fake.stats = {"a": container(50, inactive_file=0)}
        self.assertEqual(self.run_check(), 0)

    def test_at_threshold_is_unhealthy(self):
        Fake.stats = {"a": container(THRESHOLD_MIB, inactive_file=0)}
        self.assertEqual(self.run_check(), 1)

    def test_page_cache_is_excluded_cgroup_v2(self):
        Fake.stats = {"a": container(150, inactive_file=60)}  # 90 MiB in use
        self.assertEqual(self.run_check(), 0)

    def test_page_cache_is_excluded_cgroup_v1(self):
        Fake.stats = {"a": container(150, total_inactive_file=60)}
        self.assertEqual(self.run_check(), 0)

    def test_memory_is_summed_over_the_task(self):
        Fake.stats = {"a": container(60), "b": container(60, inactive_file=5)}  # 115 MiB
        self.assertEqual(self.run_check(), 1)

    def test_container_without_stats_counts_as_zero(self):
        Fake.stats = {"a": container(40), "b": None, "c": {}}
        self.assertEqual(self.run_check(), 0)

    def test_metadata_unreachable_liveliness_decides(self):
        closed = f"http://127.0.0.1:{free_port()}/v4"
        self.assertEqual(self.run_check(metadata=closed), 0)
        Fake.liveliness_status = 500
        self.assertEqual(self.run_check(metadata=closed), 1)

    def test_metadata_unset_liveliness_decides(self):
        self.assertEqual(self.run_check(metadata=None), 0)

    def test_unexpected_payload_fails_open(self):
        Fake.stats = b"not json"
        self.assertEqual(self.run_check(), 0)
        Fake.stats = ["a", "list"]
        self.assertEqual(self.run_check(), 0)

    def test_liveliness_failure_is_unhealthy_whatever_the_memory(self):
        Fake.liveliness_status = 500
        Fake.stats = {"a": container(10)}
        self.assertEqual(self.run_check(), 1)


if __name__ == "__main__":
    unittest.main()
