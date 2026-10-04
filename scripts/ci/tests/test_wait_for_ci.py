import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("wait_for_ci", Path(__file__).parents[1] / "wait_for_ci.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
SHA = "a" * 40


def run(**changes):
    return dict({"id": 10, "run_attempt": 1, "head_sha": SHA, "head_branch": "main",
                 "event": "push", "path": ".github/workflows/ci.yml",
                 "status": "completed", "conclusion": "success"}, **changes)


class WaitForCITests(unittest.TestCase):
    def wait(self, responses):
        now = [0]
        def fetch(*_args):
            return responses.pop(0) if len(responses) > 1 else responses[0]
        def sleep(seconds):
            now[0] += seconds
        return gate.wait_for_ci("example/pairnotes", SHA, fetch, lambda: now[0], sleep)

    def test_latest_run_and_attempt_take_precedence_over_old_success(self):
        with self.assertRaisesRegex(RuntimeError, "failure"):
            self.wait([[run(), run(id=11, conclusion="failure")]])
        with self.assertRaisesRegex(RuntimeError, "cancelled"):
            self.wait([[run(), run(run_attempt=2, conclusion="cancelled")]])

    def test_requires_exact_sha_main_push_and_workflow(self):
        for changes in ({"head_sha": "b" * 40}, {"head_branch": "other"},
                        {"event": "workflow_dispatch"}, {"path": ".github/workflows/other.yml"}):
            with self.subTest(changes=changes), self.assertRaisesRegex(RuntimeError, "Timed out"):
                self.wait([[run(**changes)]])

    def test_waits_for_new_run_and_current_attempt_completion(self):
        result = self.wait([[], [run(status="in_progress", conclusion=None, run_attempt=2)],
                            [run(run_attempt=2)]])
        self.assertEqual(result["run_attempt"], 2)

    def test_all_non_success_conclusions_fail_closed(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped", "neutral", "action_required", None):
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(RuntimeError, "blocked"):
                self.wait([[run(conclusion=conclusion)]])

    def test_no_run_and_still_running_time_out(self):
        for responses in ([[]], [[run(status="queued", conclusion=None)]]):
            with self.assertRaisesRegex(RuntimeError, "Timed out"):
                self.wait(responses)

    def test_api_uses_read_only_filtered_get_and_failure_cannot_pass(self):
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, json.dumps({"workflow_runs": [run()]}))) as cli:
            self.assertEqual(gate.fetch_runs("example/pairnotes", SHA, 30), [run()])
        command = cli.call_args.args[0]
        self.assertEqual(command[:4], ["gh", "api", "--method", "GET"])
        self.assertIn(f"head_sha={SHA}", command)
        self.assertIn("branch=main", command)
        self.assertIn("event=push", command)
        with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "private")):
            with self.assertRaisesRegex(RuntimeError, "lookup failed"):
                gate.fetch_runs("example/pairnotes", SHA, 30)


if __name__ == "__main__":
    unittest.main()
