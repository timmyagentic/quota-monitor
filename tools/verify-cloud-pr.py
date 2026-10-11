#!/usr/bin/env python3
"""Read-only exact-head verification. Requires an already authenticated gh CLI."""
import argparse
import json
import re
import subprocess

REPO = "timmyagentic/quota-monitor"
REQUIRED = {
    "macOS Swift tests": {"static QA checks", "swift build -c release (smoke)"},
    "Cloud development checks": {"Run ./qa/bootstrap-cloud.sh", "Run ./qa/run-cloud.sh"},
}


def gh(*args):
    return json.loads(subprocess.check_output(["gh", *args], text=True))


def validate(pr, sha, run, jobs):
    if pr["headRefOid"] != sha or pr["isDraft"]:
        raise ValueError("PR head changed or PR is draft")
    if run["headSha"] != sha or run["status"] != "completed" or run["conclusion"] != "success":
        raise ValueError("Latest tests run is not successful for the requested SHA")
    for name, steps in REQUIRED.items():
        matches = [j for j in jobs if j["name"] == name]
        if len(matches) != 1 or matches[0]["conclusion"] != "success":
            raise ValueError(f"Required real job did not pass: {name}")
        job = matches[0]
        if name == "macOS Swift tests" and "macos-15" not in job.get("labels", []):
            raise ValueError("Swift job did not run on macos-15")
        passed = {s["name"] for s in job["steps"] if s["conclusion"] == "success"}
        if not steps <= passed:
            raise ValueError(f"Required steps skipped or failed: {name}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("pr", type=int)
    p.add_argument("sha")
    args = p.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        p.error("a full 40-character commit SHA is required")
    pr = gh("pr", "view", str(args.pr), "--repo", REPO, "--json", "headRefOid,isDraft,url")
    runs = gh("run", "list", "--repo", REPO, "--workflow", "tests.yml", "--commit", args.sha,
              "--event", "pull_request", "--json", "databaseId,headSha,status,conclusion,url", "--limit", "1")
    if not runs:
        raise ValueError("No pull_request tests run for this SHA")
    run = runs[0]
    # Latest attempt only; paginated API avoids accidentally omitting a job.
    pages = gh("api", "--paginate", "--slurp", f"repos/{REPO}/actions/runs/{run['databaseId']}/jobs?filter=latest&per_page=100")
    jobs = [job for page in pages for job in page["jobs"]]
    validate(pr, args.sha, run, jobs)
    # Re-read head after collecting CI evidence to detect a concurrent push.
    final_pr = gh("pr", "view", str(args.pr), "--repo", REPO, "--json", "headRefOid,isDraft")
    validate(final_pr, args.sha, run, jobs)
    print(json.dumps({"sha": args.sha, "pr": pr["url"], "run": run["url"],
                      "verified_jobs": list(REQUIRED), "gui": "UNVERIFIED", "publication": "UNVERIFIED"}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"UNVERIFIED: {error}")
