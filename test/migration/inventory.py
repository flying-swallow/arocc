#!/usr/bin/env python3
"""Regenerate test/migration/baseline.json from the Zig reference sources.

The Zig reference (Zig 0.18.0-dev.828+9da287565) could not be obtained in the
migration environment, so nothing here comes from running a compiler. Every
number is derived by reading files with the same rules the Zig harnesses use:

  * test/runner.zig        caseFromFile / runCaseExtra   -> test/cases/*.c
  * test/record_runner.zig parseTargetsFromCode / runCase -> test/records/*_test.c
  * build.zig              test-unit root (src/aro.zig)   -> embedded `test` blocks
  * src/aro.zig, src/backend.zig                          -> public exports

Usage:
  python3 test/migration/inventory.py            # rewrite baseline.json
  python3 test/migration/inventory.py --check    # fail if baseline.json is stale
  python3 test/migration/inventory.py --stdout   # print, do not write

Output is deterministic: entries are sorted, no timestamps or host data are
read at generation time. `recorded_environment` is a fixed record of the
environment the baseline was taken in; update it by hand when that changes.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "test", "migration", "baseline.json")

# Paths that make up the Zig reference. The reference commit is the last
# commit touching any of these, so adding migration files does not move it.
REFERENCE_PATHS = [
    "build",
    "build.zig",
    "build.zig.zon",
    "include",
    "src/aro",
    "src/aro.zig",
    "src/assembly_backend",
    "src/assembly_backend.zig",
    "src/backend",
    "src/backend.zig",
    "src/main.zig",
    "test/cases",
    "test/fuzz",
    "test/record_runner.zig",
    "test/records",
    "test/runner.zig",
]

RECORDED_ENVIRONMENT = {
    "recorded_on": "2026-11-03",
    "zig_required": "0.18.0-dev.828+9da287565 (build.zig.zon minimum_zig_version)",
    "zig_available": None,
    "zig_note": "No Zig executable can build this repo here: the required 0.18.0-dev "
    "build cannot be downloaded (ziglang.org is blocked). Do not substitute an older "
    "Zig; its failures are not Aro regressions.",
    "c3c": "0.8.5 (/home/user/tools/c3/c3c, git 640091d3303a393f9651d644063b837fc19d05f1, LLVM 23.1.2)",
    "bazel": "9.1.0 (/home/user/tools/bazel, pinned by .bazelversion)",
    "python": "3.13 (only needed for this inventory script)",
}

REFERENCE_STATUS = {
    "status": "reference not executed: compiler unavailable",
    "commands_not_run": [
        "zig build",
        "zig build test-unit",
        "zig build test-integration",
        "zig build test-record",
        "zig build test-fmt",
    ],
    "pass_fail_counts": None,
    "note": "No pass/fail/skip counts exist for the Zig reference. The counts below "
    "are fixture inventories derived from source, not test results. Never claim a "
    "green Zig suite or differential parity without logs from a real run.",
}

# Mirrors Case.Kind in test/runner.zig.
CASE_KINDS = ["syntax", "syntax_ignore_errors", "expand_error", "expand", "expand_partial", "compare_output"]


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def reference_commit():
    try:
        out = subprocess.run(
            ["git", "-C", ROOT, "log", "-1", "--format=%H", "--"] + REFERENCE_PATHS,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return out or None
    except (OSError, subprocess.CalledProcessError):
        return None


def digest(paths):
    h = hashlib.sha256()
    for p in sorted(paths, key=rel):
        h.update(rel(p).encode())
        h.update(b"\0")
        h.update(read_bytes(p))
        h.update(b"\0")
    return h.hexdigest()


def walk_files(base):
    out = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for f in sorted(filenames):
            out.append(os.path.join(dirpath, f))
    return out


# ---------------------------------------------------------------- test/cases


def parse_manifest(name, contents):
    """Port of caseFromFile in test/runner.zig. Returns (case, error)."""
    start_key = b"/** manifest:"
    start = contents.find(start_key)
    if start < 0:
        return None, "TestManifestMissing"
    end = contents.rfind(b"*/")  # mem.findLast
    if end < 0:
        return None, "UnterminatedManifest"
    if end < start + len(start_key):
        return None, "UnterminatedManifest (last */ precedes manifest start)"
    manifest = contents[start + len(start_key) : end].strip(b" \t\n\r").decode("utf-8", "replace")

    lines = manifest.split("\n")
    it = iter(lines)
    first = next(it, None)
    if first is None:
        return None, "TestManifestMissingType"
    kind = first.strip(" \t\r")
    if kind not in CASE_KINDS:
        return None, "TestManifestInvalidType: " + kind

    skips, args, env, env_errors = [], [], [], []
    trailing = []
    in_trailing = False
    for line in it:
        if in_trailing:
            trailing.append(line.strip(" \t\r"))
            continue
        trimmed = line.strip(" \t\r")
        if trimmed == "":
            in_trailing = True  # start of trailing data
            continue
        if "=" not in trimmed:
            return None, "TestManifestMissingValue: " + trimmed
        key_raw, value_raw = trimmed.split("=", 1)
        key = key_raw.rstrip(" \t")
        value = value_raw.lstrip(" \t")
        if key == "skip":
            skips.append(value)
        elif key == "args":
            args = [a for a in value.split(" ") if a]  # replaces earlier args
        elif key == "env":
            env = []
            for kv in [a for a in value.split(" ") if a]:
                if "=" not in kv:
                    env_errors.append(kv)  # runner prints and continues
                    continue
                k, v = kv.split("=", 1)
                env.append(k + "=" + v)
        else:
            return None, "TestManifestUnknownOption: " + key

    case = {"name": name, "kind": kind, "args": args, "env": env, "skips": skips}
    if kind == "compare_output":
        # compare_output keeps the raw rest of the manifest; the runner never runs it.
        case["compare_output_bytes"] = len("\n".join(trailing).encode())
    elif kind == "syntax_ignore_errors":
        pass
    else:
        case["expected_diagnostics"] = len(trailing)
        blank = sum(1 for t in trailing if t == "")
        if blank:
            case["blank_expected_lines"] = blank
    if env_errors:
        case["invalid_env_pairs"] = env_errors
    return case, None


def inventory_cases():
    cases_dir = os.path.join(ROOT, "test", "cases")
    entries = sorted(os.listdir(cases_dir))
    ast_dir = os.path.join(cases_dir, "ast")
    exp_dir = os.path.join(cases_dir, "expanded")
    ast_files = set(os.listdir(ast_dir)) if os.path.isdir(ast_dir) else set()
    exp_files = set(os.listdir(exp_dir)) if os.path.isdir(exp_dir) else set()

    cases, errors, non_c = [], [], []
    subdirs = []
    for e in entries:
        p = os.path.join(cases_dir, e)
        if os.path.isdir(p):
            subdirs.append(e)
            continue
        if e == "README.md":
            continue
        if not e.endswith(".c"):
            non_c.append(e)  # runner reports InvalidName -> failure
            continue
        name = e[: -len(".c")]
        case, err = parse_manifest(name, read_bytes(p))
        if err:
            errors.append({"file": e, "error": err})
            continue
        kind = case["kind"]
        if kind in ("syntax", "syntax_ignore_errors"):
            case["ast_golden"] = e in ast_files
        if kind in ("expand", "expand_partial"):
            case["expanded_golden"] = e in exp_files
        cases.append(case)

    by_kind = {k: 0 for k in CASE_KINDS}
    for c in cases:
        by_kind[c["kind"]] += 1

    used_ast = {c["name"] + ".c" for c in cases if c.get("ast_golden")}
    used_exp = {c["name"] + ".c" for c in cases if c.get("expanded_golden")}

    missing_expanded = sorted(c["name"] for c in cases if c["kind"] in ("expand", "expand_partial") and not c["expanded_golden"])
    with_skips = [c for c in cases if c["skips"]]
    compare_output = sorted(c["name"] for c in cases if c["kind"] == "compare_output")
    skip_lines_active = sum(len(c["skips"]) for c in cases if c["kind"] != "compare_output")

    summary = {
        "top_level_files": len([e for e in entries if not os.path.isdir(os.path.join(cases_dir, e))]),
        "c_fixtures": len(cases) + len(errors),
        "parsed": len(cases),
        "manifest_errors": len(errors),
        "non_c_files": len(non_c),
        "by_kind": by_kind,
        "active": len(cases) - by_kind["compare_output"],
        "unimplemented_compare_output": by_kind["compare_output"],
        "with_args": sum(1 for c in cases if c["args"]),
        "with_env": sum(1 for c in cases if c["env"]),
        "with_skip": len(with_skips),
        "skip_lines_total": sum(len(c["skips"]) for c in cases),
        "syntax_with_ast_golden": sum(1 for c in cases if c.get("ast_golden")),
        "expand_with_expanded_golden": len(used_exp),
        "expand_missing_expanded_golden": len(missing_expanded),
        "runner_skip_stat_if_all_pass": by_kind["compare_output"] + skip_lines_active,
    }
    return {
        "source": "test/cases/*.c via test/runner.zig caseFromFile (run with cwd test/cases)",
        "runner_semantics": {
            "base_args": ["<arocc>", "-fno-color-diagnostics", "<case>.c"],
            "syntax|syntax_ignore_errors": ["-fsyntax-only", "--verbose-ast"],
            "expand|expand_partial|expand_error": ["-E", "-P"],
            "compare_output": "unimplemented: runner prints 'TODO compare output', counts 1 skipped, never runs arocc",
            "diagnostics": "stderr lines containing 'error: ', 'warning: ' or 'note: ' (minus the Darwin --sysroot note) must match the expected lines in order by substring, and the counts must match",
            "syntax": "stdout must equal ast/<case>.c when that file exists (optional)",
            "expand": "stdout must equal expanded/<case>.c (missing file is a failure)",
            "expand_partial": "stdout must END WITH expanded/<case>.c (missing file is a failure); trailing lines are expected diagnostics",
            "expand_error": "diagnostics only",
            "skip": "skip lines do not skip the case; each is printed and added to the skipped count after the case passes",
            "subdirectories": "ignored by the runner (support files): " + ", ".join(subdirs),
        },
        "summary": summary,
        "compare_output_cases": compare_output,
        "skipped_cases": [{"name": c["name"], "kind": c["kind"], "skips": c["skips"]} for c in with_skips],
        "expand_missing_expanded_golden": missing_expanded,
        "manifest_errors": errors,
        "non_c_files": non_c,
        "orphan_ast_goldens": sorted(ast_files - used_ast),
        "orphan_expanded_goldens": sorted(exp_files - used_exp),
        "cases": cases,
    }


# -------------------------------------------------------------- test/records

# record_runner.zig compErr: expected failures keyed "target|test".
RECORD_EXPECTED_FAILURES = {
    "x86_64-x86_64-windows-gnu:Gcc|0068": {"parse": False, "layout": True, "extra": True, "offset": False},
    "x86_64-x86_64-windows-gnu:Gcc|0082": {"parse": False, "layout": True, "extra": True, "offset": False},
}


def inventory_records():
    rec_dir = os.path.join(ROOT, "test", "records")
    files = sorted(
        e for e in os.listdir(rec_dir) if os.path.isfile(os.path.join(rec_dir, e)) and "_test.c" in e.lower()
    )
    other = sorted(e for e in os.listdir(rec_dir) if e not in files)
    per_file = []
    by_compiler, by_arch, by_os = {}, {}, {}
    total = 0
    invalid = 0
    for f in files:
        src = read_bytes(os.path.join(rec_dir, f)).decode("utf-8", "replace")
        test_name = f.split("_", 1)[0]
        mappings = []
        idx = 0
        while True:
            m = src.find("// MAPPING|", idx)
            if m < 0:
                break
            nl = src.find("\n", m)
            line = src[m:] if nl < 0 else src[m:nl]
            idx = m + len(line)
            parts = [p for p in line.split("|") if p]
            define = parts[1]
            targets = []
            for t in parts[2:]:
                if t.startswith("END"):
                    break
                targets.append(t)
            mappings.append({"define": define, "targets": len(targets)})
            for t in targets:
                total += 1
                tgt, compiler = t.split(":", 1)
                arch, _model, os_, _abi = tgt.split("-")[:4]
                by_compiler[compiler] = by_compiler.get(compiler, 0) + 1
                by_arch[arch] = by_arch.get(arch, 0) + 1
                by_os[os_] = by_os.get(os_, 0) + 1
                if os_ in ("ios", "macos") and arch in ("x86", "arm"):
                    invalid += 1
        per_file.append({"test": test_name, "file": f, "mappings": mappings, "cases": sum(x["targets"] for x in mappings)})
    return {
        "source": "test/records/*_test.c via test/record_runner.zig parseTargetsFromCode (run with cwd = repo root)",
        "runner_semantics": {
            "invocation": "<arocc> <file> -fsyntax-only -fno-color-diagnostics -target <arch>-<os>-<abi> -mcpu <model> --verbose-ast -D <DEFINE> --emulate=<clang|gcc|msvc> [-fms-extensions if msvc abi and Clang] [-DMSVC if msvc abi]",
            "invalid_target": "os ios/macos with arch x86/arm is counted as an invalid target and not run",
            "classification": "an 'error:' line followed by a line with _Static_assert classifies as extra (_extra_), offset (_bitoffsetof), layout (sizeof/_alignof); any other error is parse",
            "expected_failures": RECORD_EXPECTED_FAILURES,
            "global_test_exclude": [],
            "summary_quirk": "the 'All N tests passed' branch compares ok_count to the number of files, not cases, so a fully green run prints 'N passed; 0 skipped' instead",
            "prerequisites": "built arocc executable as argv[1]; Zig std.Target.Query.parse must accept every target/model string (cannot be verified without the pinned Zig)",
        },
        "summary": {
            "files": len(files),
            "cases": total,
            "predicted_invalid_targets": invalid,
            "cases_to_run": total - invalid,
            "expected_failures": len(RECORD_EXPECTED_FAILURES),
            "by_compiler": dict(sorted(by_compiler.items())),
            "by_arch": dict(sorted(by_arch.items())),
            "by_os": dict(sorted(by_os.items())),
        },
        "other_files": other,
        "files": per_file,
    }


# --------------------------------------------------------------- unit tests

TEST_RE = re.compile(r'^\s*test(?:\s+"((?:[^"\\]|\\.)*)"|\s+([A-Za-z_][A-Za-z0-9_]*))?\s*\{')


def inventory_unit_tests():
    aro_root = os.path.join(ROOT, "src", "aro.zig")
    aro_src = read_bytes(aro_root).decode()
    m = re.search(r"^test\s*\{(.*?)^\}", aro_src, re.S | re.M)
    referenced = sorted(set(re.findall(r'@import\("([^"]+)"\)', m.group(1)))) if m else []

    zig_files = []
    for base in ("src", "build", "test"):
        for p in walk_files(os.path.join(ROOT, base)):
            if p.endswith(".zig"):
                zig_files.append(p)
    files = []
    total = 0
    for p in sorted(zig_files, key=rel):
        r = rel(p)
        names, anon = [], 0
        for line in read_bytes(p).decode("utf-8", "replace").split("\n"):
            mm = TEST_RE.match(line)
            if not mm:
                continue
            if mm.group(1) is not None:
                names.append(mm.group(1))
            elif mm.group(2) is not None:
                names.append("decltest " + mm.group(2))
            else:
                anon += 1
        if not names and not anon:
            continue
        if r.startswith("src/aro/") or r == "src/aro.zig":
            module = "aro (test-unit root module)"
        elif r.startswith("src/backend"):
            module = "aro_backend (separate module: not compiled by test-unit)"
        else:
            module = "other (not compiled by test-unit)"
        rel_to_src = r[len("src/"):] if r.startswith("src/") else r
        entry = {
            "file": r,
            "module": module,
            "named": len(names),
            "anonymous": anon,
            "explicitly_referenced_by_aro_zig": rel_to_src in referenced,
            "names": names,
        }
        total += len(names) + anon
        files.append(entry)
    named_total = sum(f["named"] for f in files)
    return {
        "source": "`test` blocks in src/, build/, test/ *.zig; build.zig test-unit roots at src/aro.zig",
        "note": "Which blocks Zig actually compiles depends on semantic analysis reachability; "
        "this lists every block in source. Anonymous blocks are import-only aggregators.",
        "summary": {
            "files_with_tests": len(files),
            "blocks_total": total,
            "named": named_total,
            "anonymous": total - named_total,
        },
        "aro_zig_test_imports": referenced,
        "files": files,
    }


# ------------------------------------------------------------ public exports

def exports_of(path):
    src = read_bytes(path).decode()
    out = []
    for line in src.split("\n"):
        if not line.startswith("pub "):
            continue
        m = re.match(r"^pub\s+(const|var|fn)\s+([A-Za-z_][A-Za-z0-9_]*)\s*(.*)$", line)
        if not m:
            continue
        kind, name, rest = m.groups()
        rest = rest.strip()
        if kind == "fn":
            value = "fn"
        else:
            value = rest[1:].strip().rstrip(";").strip() if rest.startswith("=") else rest
            if value.endswith("{"):
                value = value[:-1].strip() + " { ... }"
        out.append({"name": name, "kind": kind, "value": value})
    return out


def enum_fields(path, name):
    src = read_bytes(path).decode()
    m = re.search(r"pub const " + name + r" = enum \{(.*?)\};", src, re.S)
    if not m:
        return []
    return [x.strip().rstrip(",") for x in m.group(1).split("\n") if x.strip()]


def inventory_exports():
    aro = os.path.join(ROOT, "src", "aro.zig")
    backend = os.path.join(ROOT, "src", "backend.zig")
    return {
        "note": "Parity requirement: the C3 library must expose an equivalent for each name.",
        "src/aro.zig": exports_of(aro),
        "src/backend.zig": exports_of(backend),
        "backend.CallingConvention": enum_fields(backend, "CallingConvention"),
    }


BACKEND_LIMITATIONS = {
    "note": "Parity requirements describing current behavior, not promises to implement missing codegen. Derived from source.",
    "items": [
        {
            "where": "src/aro/Driver.zig processSource",
            "behavior": "Past -fsyntax-only / -E, only x86_64 ELF targets are accepted; anything else is fatal: 'unsupported target {arch}-{os}-{abi}, currently only x86-64 elf is supported'.",
        },
        {
            "where": "src/aro/Driver.zig (-O handling)",
            "behavior": "-O0 selects the non-optimizing assembly backend (use_assembly_backend); every other -O level goes through IR (tree.genIr) and Ir.render.",
        },
        {
            "where": "src/assembly_backend.zig genAsm",
            "behavior": "Only x86_64 is implemented; any other arch panics 'genAsm not implemented'.",
        },
        {
            "where": "src/assembly_backend/x86_64.zig",
            "behavior": "Emits data only. Function definitions fail with diagnostic 'TODO: Codegen functions'. Aggregate/array/struct/union initializers -> 'TODO: Codegen multiple inits' / 'Codegen aggregates'; _Complex -> 'TODO: Codegen _Complex values'; non-8/16/32/64/128-bit ints -> 'TODO: Codegen _BitInt values'; pointers -> 'TODO: Codegen pointer'. Scalars, floats (16/32/64/80/128), strings, .bss/.data/.tdata/.tbss/.comm, -fdata-sections, and the .note.GNU-stack section are emitted.",
        },
        {
            "where": "src/backend/Ir/x86/Renderer.zig",
            "behavior": "Every IR decl fails with 'TODO implement lowering functions'; Driver reports 'unable to render Ir to machine code: ...'. So no object code is produced for any function via the IR path.",
        },
        {
            "where": "src/aro/CodeGen.zig (AST -> IR)",
            "behavior": "Fails with 'TODO ...' for: global assembly, struct bitfields, union types, blocks, complex, atomic, VLAs, nullptr_t, case ranges, several statements/expressions/casts/lvalues/builtins/initializers, static/thread_local compound literals, memcpy, and global variables (genVar).",
        },
        {
            "where": "src/backend/Object.zig",
            "behavior": "Only ELF object format exists (other formats are unreachable).",
        },
    ],
}


def build_baseline():
    ref_files = []
    for p in REFERENCE_PATHS:
        ap = os.path.join(ROOT, p)
        if os.path.isdir(ap):
            ref_files.extend(walk_files(ap))
        elif os.path.isfile(ap):
            ref_files.append(ap)
    zon = read_bytes(os.path.join(ROOT, "build.zig.zon")).decode()
    min_zig = re.search(r'\.minimum_zig_version\s*=\s*"([^"]+)"', zon).group(1)
    version = re.search(r'\.version\s*=\s*"([^"]+)"', zon).group(1)
    return {
        "schema": 1,
        "generator": "test/migration/inventory.py",
        "reference": {
            "commit": reference_commit(),
            "commit_rule": "last git commit touching reference_paths",
            "reference_paths": REFERENCE_PATHS,
            "inputs_sha256": digest(ref_files),
            "input_files": len(ref_files),
            "aro_version": version,
            "minimum_zig_version": min_zig,
        },
        "reference_status": REFERENCE_STATUS,
        "recorded_environment": RECORDED_ENVIRONMENT,
        "reference_commands": {
            "build": "zig build --cache-dir <ref>/cache --prefix <ref>/out",
            "test-unit": "zig build test-unit --cache-dir <ref>/cache --prefix <ref>/out",
            "test-integration": "zig build test-integration --cache-dir <ref>/cache --prefix <ref>/out",
            "test-record": "zig build test-record --cache-dir <ref>/cache --prefix <ref>/out",
            "executable": "<ref>/out/bin/arocc",
        },
        "c3_build": {
            "binary": "//:aro_c3",
            "smoke_test": "//test/c3:build_smoke",
            "command": "C3C=/home/user/tools/c3/c3c /home/user/tools/bazel --output_user_root=/home/user/tools/bazel_root test //test/c3:build_smoke",
        },
        "integration_cases": inventory_cases(),
        "record_cases": inventory_records(),
        "unit_tests": inventory_unit_tests(),
        "public_exports": inventory_exports(),
        "backend_limitations": BACKEND_LIMITATIONS,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--stdout", action="store_true")
    a = ap.parse_args()
    text = json.dumps(build_baseline(), indent=2, sort_keys=False, ensure_ascii=False) + "\n"
    if a.stdout:
        sys.stdout.write(text)
        return 0
    if a.check:
        try:
            cur = read_bytes(OUT).decode()
        except FileNotFoundError:
            cur = ""
        if cur != text:
            sys.stderr.write("test/migration/baseline.json is stale; run python3 test/migration/inventory.py\n")
            return 1
        print("baseline.json is up to date")
        return 0
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print("wrote " + rel(OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
