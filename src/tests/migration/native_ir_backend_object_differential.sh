#!/bin/sh
# Compare executable behavior from the system-as and integrated object paths
# for every C case. Both objects are linked with the host cc's default PIE mode.
set -eu

if [ "$#" -lt 3 ]; then
	echo "usage: $0 <aro_c3> <c_compiler> <case.c>..." >&2
	exit 2
fi

aro_c3=$1
c_compiler=$2
shift 2

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
	echo "SKIP: native Ir object differential requires Linux x86-64"
	exit 0
fi

for executable in "$aro_c3" "$c_compiler"; do
	if [ ! -x "$executable" ]; then
		echo "native Ir object differential: not executable: $executable" >&2
		exit 1
	fi
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/aro-native-ir-diff.XXXXXX")
trap 'rm -rf "$tmpdir"' 0 HUP INT TERM

# aro_c3 resolves the system assembler through PATH. Keep the declared native
# tools first so the baseline uses the assembler paired with the supplied cc.
native_tools_dir=$(dirname "$c_compiler")
PATH="$native_tools_dir:$PATH"
export PATH

objdump_path=$native_tools_dir/objdump
if [ ! -x "$objdump_path" ]; then
	objdump_path=$(command -v objdump 2>/dev/null || true)
fi

dump_objects() {
	if [ -z "$objdump_path" ] || [ ! -x "$objdump_path" ]; then
		echo "objdump unavailable; skipping object dumps"
		return
	fi
	for object in "$system_object" "$integrated_object"; do
		if [ -f "$object" ]; then
			echo "--- objdump -dr $object"
			"$objdump_path" -dr "$object" || true
		fi
	done
}

failures=0
for source in "$@"; do
	name=$(basename "$source" .c)
	expected=$(sed -n '1s#^// expect \([0-9][0-9]*\)$#\1#p' "$source")
	if [ -z "$expected" ]; then
		echo "FAIL $name: first line must be '// expect N'"
		failures=$((failures + 1))
		continue
	fi

	system_object=$tmpdir/$name.system.o
	integrated_object=$tmpdir/$name.integrated.o
	system_binary=$tmpdir/$name.system
	integrated_binary=$tmpdir/$name.integrated
	if "$aro_c3" -O1 -c "$source" -o "$system_object" 2>"$tmpdir/$name.system.compile.err"; then
		system_compile_status=0
	else
		system_compile_status=$?
	fi
	if "$aro_c3" -O1 -fintegrated-as -c "$source" -o "$integrated_object" 2>"$tmpdir/$name.integrated.compile.err"; then
		integrated_compile_status=0
	else
		integrated_compile_status=$?
	fi
	if [ "$system_compile_status" -ne 0 ] || [ "$integrated_compile_status" -ne 0 ]; then
		echo "FAIL $name: compile statuses system-as=$system_compile_status integrated=$integrated_compile_status"
		if [ "$system_compile_status" -ne 0 ]; then head -n 3 "$tmpdir/$name.system.compile.err"; fi
		if [ "$integrated_compile_status" -ne 0 ]; then head -n 3 "$tmpdir/$name.integrated.compile.err"; fi
		dump_objects
		failures=$((failures + 1))
		continue
	fi

	if "$c_compiler" "$system_object" -o "$system_binary" 2>"$tmpdir/$name.system.link.err"; then
		system_link_status=0
	else
		system_link_status=$?
	fi
	if "$c_compiler" "$integrated_object" -o "$integrated_binary" 2>"$tmpdir/$name.integrated.link.err"; then
		integrated_link_status=0
	else
		integrated_link_status=$?
	fi
	if [ "$system_link_status" -ne 0 ] || [ "$integrated_link_status" -ne 0 ]; then
		echo "FAIL $name: link statuses system-as=$system_link_status integrated=$integrated_link_status"
		if [ "$system_link_status" -ne 0 ]; then head -n 3 "$tmpdir/$name.system.link.err"; fi
		if [ "$integrated_link_status" -ne 0 ]; then head -n 3 "$tmpdir/$name.integrated.link.err"; fi
		dump_objects
		failures=$((failures + 1))
		continue
	fi

	set +e
	"$system_binary"
	system_status=$?
	"$integrated_binary"
	integrated_status=$?
	set -e
	if [ "$system_status" -eq "$expected" ] && [ "$integrated_status" -eq "$expected" ] && [ "$system_status" -eq "$integrated_status" ]; then
		echo "ok $name"
	else
		echo "FAIL $name: system-as exit $system_status, integrated exit $integrated_status, expected $expected"
		dump_objects
		failures=$((failures + 1))
	fi
done

if [ "$failures" -ne 0 ]; then
	echo "native Ir object differential: $failures case(s) failed" >&2
	exit 1
fi
echo "native Ir object differential passed: $# case(s)"
