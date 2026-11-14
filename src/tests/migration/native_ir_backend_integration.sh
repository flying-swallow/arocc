#!/bin/sh
# Compile each C case through aro_c3's Ir backend (ARO_C3_OPT, default -O1:
# AST -> Ir -> x86_64
# assembly -> system `as`), link it with the host cc, run it, and compare its
# exit status with the case's `// expect N` first line.
set -eu

if [ "$#" -lt 3 ]; then
	echo "usage: $0 <aro_c3> <c_compiler> <case.c>..." >&2
	exit 2
fi

aro_c3=$1
c_compiler=$2
shift 2

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
	echo "SKIP: native Ir backend integration requires Linux x86-64"
	exit 0
fi

for executable in "$aro_c3" "$c_compiler"; do
	if [ ! -x "$executable" ]; then
		echo "native Ir backend integration: not executable: $executable" >&2
		exit 1
	fi
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/aro-native-ir.XXXXXX")
trap 'rm -rf "$tmpdir"' 0 HUP INT TERM

# aro_c3 finds `as` through PATH; the declared native tools keep cc and as together.
native_tools_dir=$(dirname "$c_compiler")
PATH="$native_tools_dir:$PATH"
export PATH

opt=${ARO_C3_OPT:--O1}
failures=0
for source in "$@"; do
	name=$(basename "$source" .c)
	expected=$(sed -n '1s#^// expect \([0-9][0-9]*\)$#\1#p' "$source")
	if [ -z "$expected" ]; then
		echo "FAIL $name: first line must be '// expect N'"
		failures=$((failures + 1))
		continue
	fi
	object=$tmpdir/$name.o
	binary=$tmpdir/$name
	if ! "$aro_c3" ${ARO_C3_FLAGS:-} "$opt" -c "$source" -o "$object" 2>"$tmpdir/$name.err"; then
		echo "FAIL $name: aro_c3 $opt -c failed: $(head -n 3 "$tmpdir/$name.err")"
		failures=$((failures + 1))
		continue
	fi
	if ! "$c_compiler" "$object" -o "$binary" 2>"$tmpdir/$name.err"; then
		echo "FAIL $name: link failed: $(head -n 3 "$tmpdir/$name.err")"
		failures=$((failures + 1))
		continue
	fi
	set +e
	"$binary"
	status=$?
	set -e
	if [ "$status" -ne "$expected" ]; then
		echo "FAIL $name: exit status $status, expected $expected"
		failures=$((failures + 1))
	else
		echo "ok $name"
	fi
done

if [ "$failures" -ne 0 ]; then
	echo "native Ir backend integration: $failures case(s) failed" >&2
	exit 1
fi
echo "native Ir backend integration passed: $# case(s)"
