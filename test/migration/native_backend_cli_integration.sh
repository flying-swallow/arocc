#!/bin/sh
# Compile a supported data-only C source with aro_c3, then verify its native
# object by linking it to a separately compiled C consumer.
set -eu

if [ "$#" -ne 4 ]; then
	echo "usage: $0 <aro_c3> <backend_data.c> <backend_consumer.c> <c_compiler>" >&2
	exit 2
fi

aro_c3=$1
data_source=$2
consumer_source=$3
c_compiler=$4

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
	echo "SKIP: native backend CLI integration requires Linux x86-64"
	exit 0
fi

for executable in "$aro_c3" "$c_compiler"; do
	if [ ! -x "$executable" ]; then
		echo "native backend CLI integration: not executable: $executable" >&2
		exit 1
	fi
done
for source in "$data_source" "$consumer_source"; do
	if [ ! -r "$source" ]; then
		echo "native backend CLI integration: source is not readable: $source" >&2
		exit 1
	fi
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/aro-native-backend.XXXXXX")
trap 'rm -rf "$tmpdir"' 0 HUP INT TERM
data_object=$tmpdir/backend_data.o
consumer_object=$tmpdir/backend_consumer.o
binary=$tmpdir/backend_consumer

# The declared native tool runfiles keep cc and as side by side. aro_c3 finds
# its assembler through PATH, so expose that directory for its invocation.
native_tools_dir=$(dirname "$c_compiler")
PATH="$native_tools_dir:$PATH"
export PATH

"$aro_c3" -c "$data_source" -o "$data_object"
"$c_compiler" -c "$consumer_source" -o "$consumer_object"
"$c_compiler" "$consumer_object" "$data_object" -o "$binary"
"$binary"

echo "native backend CLI integration passed: exported scalar and string contents verified"
