# Differential sema check: compare check_probe errors with
# `c3c -C --use-stdlib=no compile <file>` (check only, no stdlib) as
# (file, row, col, text) sets for c3c test_suite files.
#   bazel build //test/src/c3:check_probe
#   python3 -I test/src/c3/sema_diff.py ~/projects/c3c [c3c-binary] [filter-substring]
# With STDLIB=1 in the environment both sides use the c3c checkout's lib/std
# (c3c's default `-C compile`, check_probe `--lib <repo>/lib`).
# KINDS=c3,c3t selects the file kinds (default: c3). PROBE=<path> overrides the
# check_probe binary (default bazel-bin/test/src/c3/check_probe).
# .c3t files are split like c3c's test/src/test_suite_runner.c3: header
# directive lines (`// #...` / `/* #...` at line start) are dropped, the first
# file is <basename>.c3, `// #file: <name>` starts the next file, everything
# after `#expect:` is expected LLVM/C output (not a source, not compared), and
# `// #target: <name>` is passed as `--target` to both sides. #safe / #opt /
# #debuginfo / #deprecation only matter for codegen and are ignored.
# Details go to sema_diff.txt; crashes are bucketed by the stub/panic they hit.
import collections, os, pathlib, re, subprocess, sys, tempfile
repo = pathlib.Path(sys.argv[1])
C3C = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else str(repo / 'build' / 'c3c')
FILTER = sys.argv[3] if len(sys.argv) > 3 else ''
P = os.path.abspath(os.environ.get('PROBE', 'bazel-bin/test/src/c3/check_probe'))
KINDS = [k.strip() for k in os.environ.get('KINDS', 'c3').split(',') if k.strip()]
files = sorted(str(f) for k in KINDS for f in (repo / 'test/test_suite').rglob('*.' + k) if FILTER in str(f))
stats = collections.Counter(); panics = collections.Counter(); out = open('sema_diff.txt', 'w')
def errs(text, pat):
    return set((pathlib.Path(m.group(1)).name, int(m.group(2)), int(m.group(3)), m.group(4).strip()) for m in re.finditer(pat, text))

def split_c3t(path, tmp):
    """test_suite_runner.c3 test_file: returns (source paths, target or None)."""
    sources = []; target = None; cur = None; is_output = False
    def start(name):
        nonlocal cur
        cur = open(os.path.join(tmp, name), 'w'); sources.append(cur.name)
    start(pathlib.Path(path).name[:-len('.c3t')] + '.c3')
    for line in pathlib.Path(path).read_text(errors='replace').split('\n'):
        line = line.rstrip('\r')
        if line.startswith('// #') or line.startswith('/* #'):
            key, _, value = line[4:].strip().partition(':')
            value = value.strip()
            if key == 'target' and not is_output: target = value
            elif key == 'file':
                cur.close(); start(value); is_output = False
            elif key == 'expect':
                cur.close(); cur = open(os.devnull, 'w'); is_output = True
            continue
        cur.write(line + '\n')
    cur.close()
    return sources, target

for f in files:
    with tempfile.TemporaryDirectory() as tmp:
        if f.endswith('.c3t'):
            srcs, target = split_c3t(f, tmp)
        else:
            srcs, target = [f], None
        tgt = ['--target', target] if target else []
        try:
            if os.environ.get('STDLIB'):
                a = subprocess.run([C3C, '-C', 'compile', *tgt, *srcs], capture_output=True, text=True, timeout=60, cwd=tmp, stdin=subprocess.DEVNULL)
                o = subprocess.run([P, *tgt, '--lib', str(repo / 'lib'), *srcs], capture_output=True, text=True, timeout=60, cwd=tmp)
            else:
                a = subprocess.run([C3C, '-C', '--use-stdlib=no', 'compile', *tgt, *srcs], capture_output=True, text=True, timeout=30, cwd=tmp, stdin=subprocess.DEVNULL)
                o = subprocess.run([P, *tgt, *srcs], capture_output=True, text=True, timeout=30, cwd=tmp)
        except subprocess.TimeoutExpired:
            stats['timeout'] += 1; out.write(f'TIMEOUT {f}\n'); continue
    ce = errs(a.stdout + a.stderr, r'([^\s:()]+):(\d+):(\d+): error: (.*)')
    oe = errs(o.stderr, r'\(([^\s:()]+):(\d+):(\d+)\) Error: (.*)')
    if o.returncode not in (0, 1):
        m = re.search(r"(sema stub: \w+|unreachable[^\n]*|ERROR: '[^\n]*)", o.stderr)
        key = m.group(1)[:90] if m else f'exit {o.returncode}'
        stats['crash'] += 1; panics[key] += 1; out.write(f'CRASH {f}: {key}\n'); continue
    if ce == oe: stats['match_err' if ce else 'match_ok'] += 1
    else:
        stats['mismatch'] += 1
        out.write(f'MISMATCH {f}\n  c3c-only: {sorted(ce - oe)[:3]}\n  ours-only: {sorted(oe - ce)[:3]}\n')
print(dict(stats))
for k, v in panics.most_common(15): print(f'{v:5d}  {k}')
