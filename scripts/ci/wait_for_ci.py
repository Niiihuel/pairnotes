#!/usr/bin/env python3
"""Fail closed unless ci.yml for this exact main push succeeds within 15 minutes."""

import json
import os
import re
import subprocess
import sys
import time


def fetch_runs(repository, sha, timeout):
    command = [
        "gh", "api", "--method", "GET",
        f"repos/{repository}/actions/workflows/ci.yml/runs",
        "-f", "branch=main", "-f", "event=push", "-f", f"head_sha={sha}",
        "-f", "per_page=100",
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError("GitHub CI lookup could not complete") from error
    if result.returncode:
        raise RuntimeError("GitHub CI lookup failed; refusing distribution")
    try:
        runs = json.loads(result.stdout)["workflow_runs"]
        if not isinstance(runs, list):
            raise ValueError("invalid runs")
        return runs
    except (KeyError, TypeError, ValueError) as error:
        raise RuntimeError("GitHub CI lookup returned invalid data") from error


def matching_run(runs, sha):
    matches = [run for run in runs if run.get("head_sha") == sha
               and run.get("head_branch") == "main" and run.get("event") == "push"
               and run.get("path") == ".github/workflows/ci.yml"]
    return max(matches, key=lambda run: (run["id"], run["run_attempt"]), default=None)


def wait_for_ci(repository, sha, fetch=fetch_runs, clock=time.monotonic, sleep=time.sleep):
    deadline = clock() + 15 * 60
    previous = None
    while clock() < deadline:
        run = matching_run(fetch(repository, sha, min(30, deadline - clock())), sha)
        state = (run["id"], run["run_attempt"], run["status"], run.get("conclusion")) if run else None
        if state != previous or run is None:
            print(f"CI for {sha}: {state if run else 'awaiting matching main push run'}", flush=True)
            previous = state
        if run and run["status"] == "completed":
            if run.get("conclusion") != "success":
                raise RuntimeError(f"Matching CI concluded {run.get('conclusion')}; distribution blocked")
            print(f"Verified https://github.com/{repository}/actions/runs/{run['id']} "
                  f"attempt {run['run_attempt']} for {sha}", flush=True)
            return run
        if run and run["status"] not in {"queued", "in_progress", "waiting", "pending", "requested"}:
            raise RuntimeError("Unexpected CI status; distribution blocked")
        sleep(max(0, min(20, deadline - clock())))
    raise RuntimeError("Timed out waiting for successful CI of this exact commit; distribution blocked")


def main():
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    sha = os.environ.get("GITHUB_SHA", "")
    if (os.environ.get("GITHUB_REF") != "refs/heads/main"
            or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)
            or not re.fullmatch(r"[0-9a-f]{40}", sha)):
        raise RuntimeError("Distribution requires a full commit SHA on main")
    wait_for_ci(repository, sha)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, KeyError, TypeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        sys.exit(1)
