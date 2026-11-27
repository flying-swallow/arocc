#!/usr/bin/env python3
"""Run c3c test_suite cases through aro_c3c's check-only frontend."""

from __future__ import annotations

import argparse
import dataclasses
import pathlib
import re
import subprocess
import sys
import tempfile


DIAGNOSTIC = re.compile(r"^\((.+):(\d+):(\d+)\) (Error|Warning|Note): (.*)$")
TRAILING = re.compile(r"// #(error|warning):\s*(.*)$")
SUPPORTED_DIRECTIVES = {"error", "file", "target", "skip"}
UNSUPPORTED_DIRECTIVES = {"expect", "opt", "safe", "debuginfo", "deprecation"}


@dataclasses.dataclass(frozen=True)
class Expected:
    filename: str
    line: int
    severity: str
    message: str


@dataclasses.dataclass
class Case:
    sources: dict[str, list[str]]
    expected: list[Expected]
    target: str | None = None
    skipped: bool = False
    unsupported: list[str] = dataclasses.field(default_factory=list)


def parse_case(path: pathlib.Path) -> Case:
    single = path.suffix == ".c3"
    first_name = path.stem + ".c3"
    case = Case({first_name: []}, [])
    current = first_name
    output_section = False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.rstrip("\r")
        if line.startswith(("// #", "/* #")):
            directive = line[4:].strip()
            key, sep, value = directive.partition(":")
            value = value.strip()
            if key == "skip":
                case.skipped = True
            elif key == "file":
                if single or not value or pathlib.PurePath(value).name != value or value in case.sources:
                    case.unsupported.append(f"invalid #file: {value}")
                else:
                    current = value
                    case.sources[current] = []
                    output_section = False
            elif key == "expect":
                case.unsupported.append("#expect requires code generation")
                output_section = True
            elif key == "target":
                if not output_section:
                    case.target = value
            elif key == "error":
                if not output_section:
                    case.expected.append(Expected(current, len(case.sources[current]) + 1, "Error", value))
            elif key in UNSUPPORTED_DIRECTIVES:
                case.unsupported.append(f"#{key} requires an unsupported compiler option")
            elif key not in SUPPORTED_DIRECTIVES:
                case.unsupported.append(f"unknown directive #{key}")
            continue
        if output_section:
            continue
        trailing = TRAILING.search(line)
        if trailing:
            severity = "Error" if trailing.group(1) == "error" else "Warning"
            case.expected.append(Expected(current, len(case.sources[current]) + 1, severity, trailing.group(2).strip()))
        case.sources[current].append(line + "\n")
    return case


def check_diagnostics(case: Case, output: str, exit_code: int) -> list[str]:
    issues = []
    actual = []
    for line in output.splitlines():
        match = DIAGNOSTIC.fullmatch(line)
        if match:
            if match.group(4) == "Note":
                continue
            actual.append(Expected(pathlib.Path(match.group(1)).name, int(match.group(2)), match.group(4), match.group(5)))
        elif line.strip():
            issues.append(f"unexpected compiler output: {line[:300]}")
    unmatched = actual[:]
    for expected in case.expected:
        match_index = next((i for i, item in enumerate(unmatched)
                            if item.filename == expected.filename and item.line == expected.line
                            and item.severity == expected.severity and expected.message in item.message), None)
        if match_index is None:
            issues.append(f"missing {expected.severity} at {expected.filename}:{expected.line}: {expected.message}")
        else:
            unmatched.pop(match_index)
    for item in unmatched:
        issues.append(f"unexpected {item.severity} at {item.filename}:{item.line}: {item.message}")
    if exit_code not in (0, 1):
        issues.append(f"compiler exited with status {exit_code}")
    elif exit_code == 0 and any(item.severity == "Error" for item in case.expected):
        issues.append("compiler succeeded despite expected errors")
    elif exit_code == 1 and not any(item.severity == "Error" for item in actual):
        issues.append("compiler failed without a source error")
    return issues


def run_case(path: pathlib.Path, compiler: pathlib.Path, stdlib: pathlib.Path) -> tuple[str, list[str]]:
    case = parse_case(path)
    if case.skipped:
        return "skip", []
    if case.unsupported:
        return "unsupported", case.unsupported
    with tempfile.TemporaryDirectory(prefix="aro-c3c-") as temp:
        root = pathlib.Path(temp)
        sources = []
        for name, lines in case.sources.items():
            source = root / name
            source.write_text("".join(lines), encoding="utf-8")
            sources.append(str(source))
        command = [str(compiler), "--check", "--stdlib", str(stdlib)]
        if case.target:
            command += ["--target", case.target]
        command += sources
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=45, cwd=root)
        except subprocess.TimeoutExpired:
            return "fail", ["compiler timed out after 45 seconds"]
        issues = check_diagnostics(case, result.stderr, result.returncode)
        return ("fail" if issues else "pass"), issues


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiler", type=pathlib.Path, required=True)
    parser.add_argument("--stdlib", type=pathlib.Path, required=True)
    parser.add_argument("--suite-root", type=pathlib.Path, required=True)
    parser.add_argument("--area", required=True)
    args = parser.parse_args()
    compiler = args.compiler.resolve()
    stdlib = args.stdlib.resolve()
    directory = args.suite_root.resolve() / args.area
    if not compiler.is_file() or not stdlib.is_dir() or not directory.is_dir():
        parser.error("compiler, stdlib, or test area is missing")
    paths = sorted(path for path in directory.rglob("*") if path.suffix in (".c3", ".c3t"))
    counts = {"pass": 0, "fail": 0, "skip": 0, "unsupported": 0}
    for path in paths:
        status, issues = run_case(path, compiler, stdlib)
        counts[status] += 1
        if issues:
            print(f"{status.upper()} {path.relative_to(args.suite_root.resolve())}")
            for issue in issues[:8]:
                print(f"  {issue}")
    print(f"{args.area}: " + ", ".join(f"{key}={value}" for key, value in counts.items()))
    return 1 if counts["fail"] or counts["unsupported"] or not paths else 0


if __name__ == "__main__":
    sys.exit(main())
