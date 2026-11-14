#!/usr/bin/env python3
"""Run the frozen Zig reference build and test steps, recording actual results.

This helper uses only the Python standard library. It refuses to run unless the
selected Zig executable has the exact version recorded by the migration
baseline and the Zig reference paths in the selected source tree match the
frozen commit. Command logs, caches, and output prefixes are kept in a
run-specific directory. Results are appended to reference-results.json;
baseline.json is never edited.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parents[2]
BASELINE_PATH = ROOT / "test" / "migration" / "baseline.json"
RESULTS_PATH = ROOT / "test" / "migration" / "reference-results.json"
COMMANDS = (
    ("build", ()),
    ("test-unit", ("test-unit",)),
    ("test-integration", ("test-integration",)),
    ("test-record", ("test-record",)),
    ("test-fmt", ("test-fmt",)),
)
TEST_LINE = re.compile(
    r"^\s*\d+/\d+\s+.*?\.\.\.?\s*(OK|PASS|PASSED|FAIL|FAILED|SKIP|SKIPPED|"
    r"SIG(?:ABRT|BUS|FPE|HUP|INT|ILL|KILL|QUIT|SEGV|TERM))\s*$",
    re.IGNORECASE,
)
SIGNAL_NAMES = {
    "SIGABRT",
    "SIGBUS",
    "SIGFPE",
    "SIGHUP",
    "SIGINT",
    "SIGILL",
    "SIGKILL",
    "SIGQUIT",
    "SIGSEGV",
    "SIGTERM",
}


def utc_now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def git(root, *args):
    return subprocess.run(
        ["git", "-C", str(root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def safe_reference_paths(value):
    paths = value.get("reference_paths")
    if not isinstance(paths, list) or not paths or not all(isinstance(p, str) for p in paths):
        raise ValueError("baseline reference.reference_paths must be a non-empty string list")
    for path in paths:
        candidate = Path(path)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise ValueError(f"unsafe reference path in baseline: {path!r}")
    return paths


def read_baseline():
    with BASELINE_PATH.open(encoding="utf-8") as stream:
        baseline = json.load(stream)
    reference = baseline.get("reference", {})
    required = reference.get("minimum_zig_version")
    commit = reference.get("commit")
    if not isinstance(required, str) or not required:
        raise ValueError("baseline reference.minimum_zig_version is missing")
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("baseline reference.commit must be a 40-character commit hash")
    return baseline, required, commit, safe_reference_paths(reference)


def check_declared_zig_version(required, source_root):
    zon_path = source_root / "build.zig.zon"
    try:
        text = zon_path.read_text(encoding="utf-8")
    except OSError as error:
        return None, f"could not read {zon_path}: {error}"
    match = re.search(r'^\s*\.minimum_zig_version\s*=\s*"([^"]+)"', text, re.MULTILINE)
    declared = match.group(1) if match else None
    if declared is None:
        return None, "could not read .minimum_zig_version from build.zig.zon"
    if declared != required:
        return declared, (
            f"build.zig.zon requires {declared}, but baseline.json records {required}"
        )
    return declared, None


def check_reference_tree(source_root, commit, paths):
    problems = []
    top_level = git(source_root, "rev-parse", "--show-toplevel")
    if top_level.returncode:
        details = top_level.stderr.strip() or "git could not find the source tree"
        return {
            "status": "blocked",
            "head_commit": None,
            "frozen_commit_available": False,
            "changed_paths": [],
            "untracked_paths": [],
            "blockers": [f"source tree {source_root} is not a Git worktree: {details}"],
        }
    git_root = Path(top_level.stdout.strip()).resolve()
    if git_root != source_root:
        return {
            "status": "blocked",
            "head_commit": None,
            "frozen_commit_available": False,
            "changed_paths": [],
            "untracked_paths": [],
            "blockers": [
                f"source tree {source_root} is not the root of its Git worktree ({git_root})"
            ],
        }

    object_check = git(source_root, "cat-file", "-e", f"{commit}^{{commit}}")
    if object_check.returncode:
        details = object_check.stderr.strip() or "git could not resolve the commit"
        return {
            "status": "blocked",
            "head_commit": None,
            "frozen_commit_available": False,
            "changed_paths": [],
            "untracked_paths": [],
            "blockers": [f"frozen reference commit {commit} is unavailable: {details}"],
        }

    head_result = git(source_root, "rev-parse", "HEAD")
    head = head_result.stdout.strip() if head_result.returncode == 0 else None
    if head is None:
        problems.append("could not determine the current repository HEAD")
    else:
        ancestor = git(source_root, "merge-base", "--is-ancestor", commit, head)
        if ancestor.returncode != 0:
            problems.append(f"HEAD {head} is not descended from frozen reference commit {commit}")

    changed_result = git(
        source_root, "diff", "--name-only", "--no-renames", commit, "--", *paths
    )
    changed = sorted(set(changed_result.stdout.splitlines()))
    if changed_result.returncode != 0:
        details = changed_result.stderr.strip() or "git diff failed"
        problems.append(f"could not compare reference paths with the frozen commit: {details}")
        changed = []
    elif changed:
        problems.append(
            "reference paths differ from the frozen commit: " + ", ".join(changed)
        )

    untracked_result = git(
        source_root, "ls-files", "--others", "--exclude-standard", "--", *paths
    )
    untracked = sorted(set(untracked_result.stdout.splitlines()))
    if untracked_result.returncode != 0:
        details = untracked_result.stderr.strip() or "git ls-files failed"
        problems.append(f"could not check for untracked reference files: {details}")
        untracked = []
    elif untracked:
        problems.append("untracked files are inside reference paths: " + ", ".join(untracked))

    return {
        "status": "blocked" if problems else "ready",
        "head_commit": head,
        "frozen_commit_available": True,
        "changed_paths": changed,
        "untracked_paths": untracked,
        "blockers": problems,
    }


def resolve_zig(requested):
    if requested:
        candidate = Path(requested).expanduser()
        if not candidate.is_absolute():
            candidate = (Path.cwd() / candidate).resolve()
        return str(candidate) if candidate.is_file() else None
    return shutil.which("zig")


def check_zig(requested, required, source_root):
    path = resolve_zig(requested)
    result = {
        "path": path,
        "reported_version": None,
        "version_exit_status": None,
        "status": "blocked",
        "blocker": None,
    }
    if path is None:
        result["blocker"] = (
            f"no Zig executable was found{f' at {requested!r}' if requested else ' on PATH'}; "
            f"required version is {required}"
        )
        return result

    try:
        version = subprocess.run(
            [path, "version"],
            cwd=source_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=30,
            check=False,
        )
        reported = version.stdout.strip()
        result["reported_version"] = reported or None
        result["version_exit_status"] = version.returncode
        if version.returncode != 0:
            result["blocker"] = (
                f"Zig version probe exited with status {version.returncode}: "
                f"{reported or '(no output)'}"
            )
        elif reported != required:
            result["blocker"] = (
                f"Zig at {path} reports {reported or '(no version)'}, but the required "
                f"frozen reference version is {required}; refusing to use another version"
            )
        else:
            result["status"] = "ready"
    except (OSError, subprocess.TimeoutExpired) as error:
        result["blocker"] = f"could not query Zig at {path}: {error}"
    return result


def parse_test_counts(output, process_signal=None):
    counts = {"passed": None, "failed": None, "skipped": None, "signaled": None}
    statuses = {"passed": 0, "failed": 0, "skipped": 0, "signaled": 0}
    parsed_lines = 0
    for line in output.splitlines():
        match = TEST_LINE.match(line)
        if not match:
            continue
        status = match.group(1).upper()
        parsed_lines += 1
        if status in ("OK", "PASS", "PASSED"):
            statuses["passed"] += 1
        elif status in ("FAIL", "FAILED"):
            statuses["failed"] += 1
        elif status in ("SKIP", "SKIPPED"):
            statuses["skipped"] += 1
        elif status in SIGNAL_NAMES:
            statuses["signaled"] += 1

    if parsed_lines:
        counts.update(statuses)
        source = "per-test status lines"
    else:
        patterns = {
            "passed": r"\b(\d+)\s+(?:tests?\s+)?passed\b",
            "failed": r"\b(\d+)\s+(?:tests?\s+)?failed\b",
            "skipped": r"\b(\d+)\s+(?:tests?\s+)?skipped\b",
        }
        found = False
        fraction = re.findall(
            r"\b(\d+)\s*/\s*(\d+)\s+tests?\s+passed\b", output, re.IGNORECASE
        )
        if fraction:
            counts["passed"] = int(fraction[-1][0])
            found = True
        for key, pattern in patterns.items():
            if key == "passed" and fraction:
                continue
            matches = re.findall(pattern, output, re.IGNORECASE)
            if matches:
                counts[key] = int(matches[-1])
                found = True
        source = "summary text" if found else None

    if process_signal:
        counts["signaled"] = (counts["signaled"] or 0) + 1
    elif counts["signaled"] is None and source == "summary text":
        counts["signaled"] = 0
    return counts, source


def command_record(label, step, log_path):
    return {
        "name": label,
        "step": list(step),
        "planned_argv": None,
        "status": "not_run",
        "exit_status": None,
        "process_signal": None,
        "duration_seconds": None,
        "log_path": str(log_path),
        "test_counts": {
            "passed": None,
            "failed": None,
            "skipped": None,
            "signaled": None,
            "source": None,
        },
        "argv": None,
    }


def load_results(path):
    if not path.exists():
        return (
            {"schema": 1, "artifact": "actual Zig reference gate runs", "runs": []},
            "runs",
        )
    with path.open(encoding="utf-8") as stream:
        current = json.load(stream)
    if not isinstance(current, dict) or current.get("schema") != 1:
        raise ValueError(
            f"{path} exists but is not a supported schema-1 results artifact; leaving it unchanged"
        )
    if current.get("artifact") == "actual Zig reference gate runs":
        key = "runs"
    elif current.get("artifact_kind") == "actual_reference_execution_results":
        # Preserve the existing execution evidence and attach this helper's
        # records in a separate field instead of translating or replacing it.
        key = "helper_runs"
        current.setdefault(key, [])
    else:
        raise ValueError(
            f"{path} has an unrecognized schema-1 artifact identity; leaving it unchanged"
        )
    if not isinstance(current.get(key), list):
        raise ValueError(
            f"{path} has a non-list {key!r} field; leaving it unchanged"
        )
    return current, key


def write_results(path, artifact):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = path.stat().st_mode & 0o777 if path.exists() else 0o644
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.",
            suffix=".tmp", delete=False
        ) as stream:
            temporary = Path(stream.name)
            json.dump(artifact, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def execute_command(zig_path, source_root, run_dir, label, step, timeout):
    command_dir = run_dir / "commands" / label
    cache_dir = command_dir / "cache"
    global_cache_dir = command_dir / "global-cache"
    output_dir = command_dir / "out"
    log_path = command_dir / "command.log"
    for path in (cache_dir, global_cache_dir, output_dir):
        path.mkdir(parents=True, exist_ok=True)

    argv = [zig_path, "build", *step,
            "--cache-dir", str(cache_dir),
            "--prefix", str(output_dir)]
    environment = os.environ.copy()
    environment["ZIG_GLOBAL_CACHE_DIR"] = str(global_cache_dir)
    record = command_record(label, step, log_path)
    record["argv"] = argv
    record["planned_argv"] = argv
    record["cwd"] = str(source_root)
    record["environment_overrides"] = {
        "ZIG_GLOBAL_CACHE_DIR": str(global_cache_dir)
    }
    start = time.monotonic()
    try:
        completed = subprocess.run(
            argv,
            cwd=source_root,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
        output = completed.stdout
        record["exit_status"] = completed.returncode
        if completed.returncode < 0:
            try:
                process_signal = signal.Signals(-completed.returncode).name
            except ValueError:
                process_signal = f"SIG{-completed.returncode}"
            record["process_signal"] = process_signal
            record["status"] = "signaled"
        else:
            record["status"] = "passed" if completed.returncode == 0 else "failed"
    except subprocess.TimeoutExpired as error:
        value = error.stdout or ""
        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="replace")
        output = value + f"\n[reference gate timed out after {timeout} seconds]\n"
        record["status"] = "timed_out"
    except OSError as error:
        output = f"[reference gate could not start command: {error}]\n"
        record["status"] = "could_not_start"
    record["duration_seconds"] = round(time.monotonic() - start, 3)
    log_path.write_text(output, encoding="utf-8", errors="replace")
    counts, source = parse_test_counts(output, record["process_signal"])
    record["test_counts"] = {**counts, "source": source}
    return record


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-tree", type=Path, default=ROOT,
        help=f"Git worktree containing the frozen Zig reference source (default: {ROOT})"
    )
    parser.add_argument(
        "--zig", help="specific Zig executable; if omitted, resolve zig from PATH"
    )
    parser.add_argument(
        "--results", type=Path, default=RESULTS_PATH,
        help=f"actual-results JSON artifact (default: {RESULTS_PATH})"
    )
    parser.add_argument(
        "--run-dir", type=Path,
        help="directory for per-command logs, caches, and outputs (default: a new directory under test/migration/reference-logs)"
    )
    parser.add_argument(
        "--timeout", type=int, default=1800,
        help="maximum seconds per command (default: 1800; 0 disables the timeout)"
    )
    return parser


def ensure_output_is_safe(path, reference_paths, source_root):
    """Keep configurable outputs away from protected source and metadata files."""
    path = path.expanduser().resolve()
    protected_files = {
        BASELINE_PATH.resolve(),
        (ROOT / "test" / "migration" / "inventory.py").resolve(),
        (source_root / "test" / "migration" / "baseline.json").resolve(),
        (source_root / "test" / "migration" / "inventory.py").resolve(),
    }
    if (
        path in protected_files
        or path.name == "BUILD.bazel"
        or path.suffix.lower() in {".md", ".rst", ".adoc"}
    ):
        raise ValueError(f"refusing to use protected repository path as output: {path}")
    protected_dirs = [ROOT / "docs", source_root / "docs"]
    protected_dirs.extend(ROOT / item for item in reference_paths)
    protected_dirs.extend(source_root / item for item in reference_paths)
    for protected in protected_dirs:
        protected = protected.resolve()
        if path == protected or protected in path.parents:
            raise ValueError(f"refusing to write output inside protected path {protected}: {path}")
    return path


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.timeout < 0:
        print("--timeout must be zero or a positive number", file=sys.stderr)
        return 2

    try:
        baseline, required, frozen_commit, paths = read_baseline()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"reference gate cannot read baseline metadata: {error}", file=sys.stderr)
        return 2

    source_root = args.source_tree.expanduser()
    if not source_root.is_absolute():
        source_root = Path.cwd() / source_root
    source_root = source_root.resolve()
    if not source_root.is_dir():
        print(f"reference gate source tree does not exist or is not a directory: {source_root}", file=sys.stderr)
        return 2

    run_id = f"{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"
    try:
        if args.run_dir:
            run_dir = args.run_dir.expanduser()
            if not run_dir.is_absolute():
                run_dir = Path.cwd() / run_dir
            run_dir = ensure_output_is_safe(run_dir, paths, source_root)
            if run_dir.exists() and any(run_dir.iterdir()):
                raise ValueError(f"run directory is not empty; refusing to replace its contents: {run_dir}")
        else:
            parent = ROOT / "test" / "migration" / "reference-logs"
            parent.mkdir(parents=True, exist_ok=True)
            run_dir = ensure_output_is_safe(parent / run_id, paths, source_root)
        results_path = args.results.expanduser()
        if not results_path.is_absolute():
            results_path = Path.cwd() / results_path
        results_path = ensure_output_is_safe(results_path, paths, source_root)
        if args.run_dir:
            run_dir.mkdir(parents=True, exist_ok=True)
        else:
            run_dir.mkdir()
    except (OSError, ValueError) as error:
        print(f"reference gate output path error: {error}", file=sys.stderr)
        return 2

    declared_version, declaration_problem = check_declared_zig_version(required, source_root)
    zig = check_zig(args.zig, required, source_root)
    tree = check_reference_tree(source_root, frozen_commit, paths)
    blockers = []
    if declaration_problem:
        blockers.append(declaration_problem)
    if zig["blocker"]:
        blockers.append(zig["blocker"])
    blockers.extend(tree["blockers"])
    preflight_status = "ready" if not blockers else "blocked"

    commands = []
    selected_zig = zig["path"] if zig["status"] == "ready" else f"<zig {required}>"
    for label, step in COMMANDS:
        log_path = run_dir / "commands" / label / "command.log"
        record = command_record(label, step, log_path)
        command_dir = run_dir / "commands" / label
        record["planned_argv"] = [
            selected_zig,
            "build",
            *step,
            "--cache-dir",
            str(command_dir / "cache"),
            "--prefix",
            str(command_dir / "out"),
        ]
        commands.append(record)

    run = {
        "run_id": run_id,
        "started_at": utc_now(),
        "finished_at": None,
        "status": "blocked" if blockers else "running",
        "repo_root": str(source_root),
        "baseline": str(BASELINE_PATH.relative_to(ROOT)),
        "required_zig_version": required,
        "build_zig_zon_minimum_version": declared_version,
        "frozen_commit": frozen_commit,
        "preflight": {
            "status": preflight_status,
            "blockers": blockers,
            "zig": zig,
            "reference_tree": tree,
        },
        "run_dir": str(run_dir),
        "commands": commands,
    }

    if blockers:
        for record in commands:
            record["log_path"] = str(Path(record["log_path"]))
            Path(record["log_path"]).parent.mkdir(parents=True, exist_ok=True)
            Path(record["log_path"]).write_text(
                "Reference command not run because preflight was blocked:\n"
                + "\n".join(f"- {reason}" for reason in blockers)
                + "\n",
                encoding="utf-8",
            )
    else:
        actual = []
        for label, step in COMMANDS:
            actual.append(
                execute_command(
                    zig["path"], source_root, run_dir, label, step, args.timeout or None
                )
            )
        commands = actual
        run["commands"] = actual
        run["status"] = (
            "passed" if all(item["status"] == "passed" for item in actual) else "failed"
        )

    run["finished_at"] = utc_now()
    try:
        artifact, runs_key = load_results(results_path)
        artifact[runs_key].append(run)
        write_results(results_path, artifact)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"reference gate could not update actual-results artifact: {error}", file=sys.stderr)
        return 2

    print(f"reference gate: {run['status']}")
    print(f"actual results: {results_path}")
    print(f"command logs: {run_dir / 'commands'}")
    for blocker in blockers:
        print(f"blocked: {blocker}", file=sys.stderr)
    for item in commands:
        print(f"{item['name']}: {item['status']} (exit={item['exit_status']})")
    return 0 if run["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
