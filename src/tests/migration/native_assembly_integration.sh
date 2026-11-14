#!/bin/sh
# Assemble the integer-scalars probe output and inspect the resulting ELF
# object. Arguments are the probe binary, fixture, assembler, and readelf.
set -eu

if [ "$#" -ne 4 ]; then
    echo "usage: $0 <assembly_probe> <integer_scalars_fixture> <as> <readelf>" >&2
    exit 2
fi

probe=$1
fixture=$2
assembler=$3
readelf=$4

if [ "$(uname -s)" != "Linux" ] || [ "$(uname -m)" != "x86_64" ]; then
    echo "SKIP: native assembly integration requires Linux x86-64"
    exit 0
fi

for executable in "$probe" "$assembler" "$readelf"; do
    if [ ! -x "$executable" ]; then
        echo "native assembly integration: not executable: $executable" >&2
        exit 1
    fi
done
if [ ! -r "$fixture" ]; then
    echo "native assembly integration: fixture is not readable: $fixture" >&2
    exit 1
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/aro-native-assembly.XXXXXX")
trap 'rm -rf "$tmpdir"' 0 HUP INT TERM
assembly=$tmpdir/integer_scalars.s
object=$tmpdir/integer_scalars.o

"$probe" "$fixture" > "$assembly"
"$assembler" --64 -o "$object" "$assembly"

sections=$tmpdir/sections.txt
symbols=$tmpdir/symbols.txt
"$readelf" -SW "$object" > "$sections"
"$readelf" -sW "$object" > "$symbols"
data_index=$(awk '
    $1 == "[" && $3 == ".data" && $4 == "PROGBITS" {
        section_number = $2
        sub(/\]$/, "", section_number)
        print section_number
        exit
    }
' "$sections")
if [ -z "$data_index" ]; then
    echo "native assembly integration: object has no PROGBITS .data section" >&2
    cat "$sections" >&2
    exit 1
fi

check_symbol() {
    symbol=$1
    value=$2
    size=$3
    if ! awk -v symbol="$symbol" -v value="$value" -v size="$size" '
        $4 == "OBJECT" && $5 == "GLOBAL" && $6 == "DEFAULT" &&
            $7 == data_index && $8 == symbol && tolower($2) == value && $3 == size {
            found = 1
        }
        END { exit !found }
    ' data_index="$data_index" "$symbols"; then
        echo "native assembly integration: missing or incorrect ELF symbol $symbol" >&2
        cat "$symbols" >&2
        exit 1
    fi
}

# The emitter aligns each scalar: byte_value at 0, short_value at 2,
# int_value at 4, and long_value at 8. Confirm the type, binding, section,
# offset, and byte size recorded by the assembler.
check_symbol byte_value 0000000000000000 1
check_symbol short_value 0000000000000002 2
check_symbol int_value 0000000000000004 4
check_symbol long_value 0000000000000008 8

bytes=$tmpdir/data-bytes.txt
"$readelf" -x .data "$object" | awk '
    $1 ~ /^0x[[:xdigit:]]+$/ {
        for (i = 2; i <= NF && length($i) == 8 && $i ~ /^[[:xdigit:]]+$/; i++) {
            printf "%s", tolower($i)
        }
    }
' > "$bytes"
expected=ff0085ff7856341215cd5b0700000000
actual=$(cat "$bytes")
if [ "$actual" != "$expected" ]; then
    echo "native assembly integration: unexpected .data bytes" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    "$readelf" -x .data "$object" >&2
    exit 1
fi

echo "native assembly integration passed: four symbols and 16 .data bytes verified"
