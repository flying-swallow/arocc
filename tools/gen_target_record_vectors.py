#!/usr/bin/env python3
"""Regenerate the record-derived vectors in test/c3/target_tests.c3.

Reads test/records/0013_test.c (auto-generated from mahkoh/repr-c), whose
MAPPING groups assert sizeof/_Alignof of char, short, int, long, long long,
void*, float and double for 109 `arch-cpu-os-abi` targets, and writes one
RecordVector row per target between the BEGIN/END markers of
test/c3/target_tests.c3. x86/arm Darwin targets are left out because
test/record_runner.zig skips them as unsupported by aro.

Usage: tools/gen_target_record_vectors.py [--check]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECORDS = os.path.join(ROOT, "test", "records", "0013_test.c")
TESTS = os.path.join(ROOT, "test", "c3", "target_tests.c3")
BEGIN = "\t// BEGIN GENERATED RECORD VECTORS (tools/gen_target_record_vectors.py)\n"
END = "\t// END GENERATED RECORD VECTORS\n"

# typedef letter in 0013_test.c -> column order of RecordVector.values
ORDER = "AEGIKLMN"  # char, short, int, long, long long, void*, float, double


def rows():
    groups, targets, cur = {}, {}, None
    for line in open(RECORDS).read().split("\n"):
        m = re.match(r"// MAPPING\|(\w+)\|(.*)\|END", line)
        if m:
            targets[m.group(1)] = [t.split(":")[0] for t in m.group(2).split("|")]
            continue
        m = re.match(r"#(?:el)?if(?:def)? ?(?:defined\()?(\w+)\)?", line)
        if m and m.group(1) in targets:
            cur = m.group(1)
            groups[cur] = {}
            continue
        m = re.match(r"_Static_assert\((sizeof|_Alignof)\(([A-N])\) == (\d+)", line)
        if m and cur:
            groups[cur].setdefault(m.group(2), {})[m.group(1)] = int(m.group(3))
    out, seen = [], set()
    for g, vals in groups.items():
        nums = []
        for k in ORDER:
            nums += [vals[k]["sizeof"], vals[k]["_Alignof"]]
        for t in targets[g]:
            if t in seen:
                continue
            seen.add(t)
            arch, cpu, os_, abi = t.split("-")
            if os_ in ("ios", "macos") and arch in ("x86", "arm"):
                continue
            out.append('\t{ "%s-%s-%s", "%s", { %s } }, // group %s\n'
                       % (arch, os_, abi, cpu, ", ".join(map(str, nums)), g))
    return "".join(out)


def main():
    text = open(TESTS).read()
    start = text.index(BEGIN) + len(BEGIN)
    end = text.index(END)
    new = text[:start] + rows() + text[end:]
    if "--check" in sys.argv:
        if new != text:
            print("target_tests.c3 record vectors are stale; rerun tools/gen_target_record_vectors.py")
            return 1
        return 0
    open(TESTS, "w").write(new)
    return 0


if __name__ == "__main__":
    sys.exit(main())
