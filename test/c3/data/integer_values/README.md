# Integer constant differential vectors

Expected results for the integer paths of `src/aro/Value.zig`. The plan 09 C3
port (`src/c3/bigint.c3`, `src/c3/value.c3`) is tested against them in
`//test/c3:integer_value_tests`. These files are test data only. No production
target reads them, and nothing here needs Zig at build or test time.

## Files

| File | Ops | Vectors |
|---|---|---|
| `bit_counts.txt` | `min_unsigned_bits`, `min_signed_bits` | 107 |
| `limits.txt` | `min_int`, `max_int` | 74 |
| `int_cast.txt` | `int_cast` | 2288 |
| `arith.txt` | `add`, `sub`, `mul`, `div`, `rem`, `order` | 17472 |
| `shifts.txt` | `shl`, `shr` | 8800 |
| `bitwise.txt` | `bit_and`, `bit_or`, `bit_xor`, `bit_not` | 1131 |

Each file ends with `# end: N vectors`. A parser can use that count to check
that it read every vector line.

## Line format

The files are plain ASCII with LF line endings. Blank lines and lines that
start with `#` are comments. Every other line is one vector with exactly
**8 fields**, separated by a single space:

```
op sign bits lhs rhs result flag provenance
```

| Field | Syntax | Meaning |
|---|---|---|
| `op` | identifier | The operation (see below). |
| `sign` | `s` / `u` / `_` | The operation type's signedness. `_` means the op takes no type. |
| `bits` | decimal / `_` | The operation type's bit width (`QualType.bitSizeof`). `_` means the op takes no type. |
| `lhs` | int / `_` | The first operand. |
| `rhs` | int / `_` | The second operand (the shift amount for shifts). |
| `result` | int / decimal / `none` / `_` | The expected result. It is decimal only for the bit-count ops. `none` is `Value{}` (`opt_ref == .none`). |
| `flag` | word | The expected secondary return (see below). `_` means the op has none. |
| `provenance` | word | Where the vector came from (see below). |

An **int** is written `[-]0x<hex digits>`, with lowercase digits, no leading
zeros, no separators, and `0x0` for zero. Negative values are sign and
magnitude, not two's complement: `-0x80` is -128. A value can be any size,
and many are wider than 128 bits (up to 301 bits). This matches the
`BigIntConst` model of sign plus magnitude limbs, and the C3 side can parse it
with `BigIntMutable.set_string(16, ...)` after removing the `-`/`0x` prefix.

### Ops

Each op maps to a Value.zig function. `T` is `(sign, bits)`.

| op | Value.zig | fields used | flag |
|---|---|---|---|
| `min_unsigned_bits` | `minUnsignedBits(lhs)` (lhs >= 0) | lhs, result (decimal) | `_` |
| `min_signed_bits` | `minSignedBits(lhs)` (lhs < 0) | lhs, result (decimal) | `_` |
| `min_int` / `max_int` | `minInt(T)` / `maxInt(T)` | T, result | `_` |
| `int_cast` | `v = lhs; v.intCast(T)` | T, lhs, result | `none` / `truncated` / `sign_changed` (`IntCastChangeKind`) |
| `add` / `sub` / `mul` | `res.add(lhs, rhs, T)` etc. | T, lhs, rhs, result | `overflow` / `ok` (the returned bool) |
| `div` | `res.div(lhs, rhs, T)` (rhs != 0) | T, lhs, rhs, result | `overflow` / `ok` |
| `rem` | `rem(lhs, rhs, T)` (rhs != 0) | T, lhs, rhs, result (may be `none`) | `_` |
| `order` | `compare` on two ints (`BigIntConst.order`) | T (informational), lhs, rhs | `lt` / `eq` / `gt` |
| `shl` | `res.shl(lhs, rhs, T)` | T, lhs, rhs, result | `overflow` / `ok` |
| `shr` | `shr(lhs, rhs, T)` | T, lhs, rhs, result | `_` |
| `bit_and` / `bit_or` / `bit_xor` | `bitAnd` / `bitOr` / `bitXor` (no type) | lhs, rhs, result | `_` |
| `bit_not` | `bitNot(lhs, T)` | T, lhs, result | `_` |

The arithmetic, shift and `bit_not` operands are always in range for `T`, as
they are in Aro after the usual arithmetic conversions. `int_cast` sources and
the bitwise operands can be any width.

### Behaviour the vectors pin down (ported as-is from Value.zig)

- `int_cast` returns `sign_changed` whenever the source sign (negative or not)
  differs from the destination signedness. That includes non-negative values
  cast to a signed type, such as `int_cast s 32 0x0 ... sign_changed`.
  `truncated` takes priority over `sign_changed`, and it means
  `bitCountTwosComp(v) > bits`.
- `div` does **not** wrap its quotient. It only reports overflow, so
  `div s 8 -0x80 -0x1` gives `0x80 overflow`.
- `rem` of signed `min / -1` gives `none`. For a signed rhs < 1, it uses
  `lhs - (lhs / rhs) * rhs` through the wrapping div/mul/sub.
- `shl` with a shift count `> bits`, negative, or not representable as `usize`
  saturates to `maxInt(T)` (lhs >= 0, which includes 0) or `minInt(T)`
  (lhs < 0), and sets `overflow`. A shift of exactly `bits` takes the normal
  shift-then-truncate path.
- `shr` with a negative or non-`usize` count gives `0x0`. It shifts
  arithmetically, rounding toward negative infinity, so `-1 >> n` stays `-0x1`.
  It never truncates to `T`.
- The bitwise and/or/xor ops have no type. Their results are exact
  two's-complement values on the unbounded integers.
- `min_int` / `max_int` widths go down to 1 (`u`) and 2 (`s`).

## Provenance

| Tag | Meaning |
|---|---|
| `zig-0.17.0` | Computed by **running** `test/migration/value_probe.zig` with the Zig 0.17.0 binary. The probe ports the integer paths of `src/aro/Value.zig` near-verbatim onto that binary's `std.math.big.int`. Each result is also cross-checked against an independent full-precision reference: the exact result, reduced modulo 2^bits, with bitwise ops done on non-negative wrapped operands. Any mismatch stops generation. |
| `aro-test` | Expected value copied from the `test "minUnsignedBits"` / `test "minSignedBits"` blocks in `src/aro/Value.zig`. The same run reproduced it. |
| `zig-0.17.0-stdbug` | The verbatim port gave a wrong result because of a `std.math.big.int` defect (see below). The vector holds the exact reference result. A `# std-bug:` comment on the line before records the defective output. |

Caveat: Aro pins Zig 0.18.0-dev, and that Zig was **not** run. These vectors
come from Zig 0.17.0's `std.math.big.int`. They are **not** differential
evidence against the pinned 0.18-dev binary. The Aro tree cannot be imported
under 0.17, so the probe carries its own copy of the Value.zig logic, with
`Value` as `?Const` (`null` meaning `.none`), `QualType` as `(signedness, bits)`,
and the interner left out.

### Known std.math.big.int 0.17.0 defect (36 `bit_or` vectors)

`llsignedor` mishandles a negative operand with more limbs combined with a
shorter positive operand. When the borrow from `-a - 1` stops early, it skips
writing the higher result limbs (`while (i < a.len and a_borrow == 1)`), but
`Mutable.bitOr` still normalizes over `a.limbs.len`. With `r` aliasing `a` this
goes unnoticed. `Value.bitOr` passes a freshly allocated buffer, so the upper
limbs are uninitialised memory. For example, `1 | -(2^64 + 1)` should give
`-(2^64 + 1)`. The probe fills new buffers with Zig Debug's `0xaa` pattern, so
the defective output is deterministic. The C3 port must produce the exact
result recorded in these vectors, not the defective output.

## Regenerating

This is a development step only and never runs in Bazel. From the repo root:

```
ZIG_GLOBAL_CACHE_DIR=$TMP/zc ZIG_LOCAL_CACHE_DIR=$TMP/zc \
  /home/user/tools/zig/ziglang/zig run test/migration/value_probe.zig -- test/c3/data/integer_values
```

The output is deterministic. Pseudo-random operands come from a fixed-seed
splitmix64 in the probe, not from `std.Random`. A second run must leave
`git diff` empty.
