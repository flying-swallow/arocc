# Differential parser check: compare parse_probe errors with `c3c -P` (parse
# only) as (row, col, text) sets for every .c3 file in a c3c checkout.
#   bazel build //test/src/c3:parse_probe
#   python3 -I test/src/c3/parse_diff.py ~/projects/c3c [c3c-binary]
# Mismatch details go to parse_diff.txt in the current directory.
import collections, pathlib, re, subprocess, sys
repo = pathlib.Path(sys.argv[1])
C3C = sys.argv[2] if len(sys.argv) > 2 else str(repo / 'build' / 'c3c')
P = 'bazel-bin/test/src/c3/parse_probe'
files = sorted(str(f) for d in ('lib/std', 'test/test_suite', 'test/unit') for f in (repo / d).rglob('*.c3'))
stats=collections.Counter(); out=open('parse_diff.txt','w')
for f in files:
    try:
        a=subprocess.run([C3C,'-P','compile',f],capture_output=True,text=True,timeout=20)
    except subprocess.TimeoutExpired:
        stats['c3c_timeout']+=1; continue
    ours=subprocess.run([P,f],capture_output=True,text=True,timeout=20)
    ce=set((int(m.group(1)),int(m.group(2)),m.group(3).strip()) for m in re.finditer(r':(\d+):(\d+): error: (.*)',a.stdout+a.stderr))
    oe=set((int(m.group(1)),int(m.group(2)),m.group(3).strip()) for m in re.finditer(r':(\d+):(\d+)\) Error: (.*)',ours.stderr))
    crash = ours.returncode not in (0,1)
    if crash:
        stats['crash']+=1; out.write(f'CRASH {f}\n{ours.stderr[-600:]}\n'); continue
    if ce==oe: stats['match_err' if ce else 'match_ok']+=1
    else:
        stats['mismatch']+=1; out.write(f'MISMATCH {f}\n  c3c: {sorted(ce)[:3]}\n  ours: {sorted(oe)[:3]}\n')
print(dict(stats))
sys.exit(1 if stats['mismatch'] or stats['crash'] else 0)
