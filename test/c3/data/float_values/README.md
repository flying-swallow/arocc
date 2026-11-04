# Float and complex constant reference vectors

Expected results for the float and complex paths of `src/aro/Value.zig` and for
all of `src/aro/annex_g.zig`, at every width (f16, f32, f64, f80, f128). They
are inputs for the plan 10 C3 port (`src/c3/float_value.c3`,
`float_soft_narrow.c3`, `float_soft_wide.c3`, `float_print.c3`, `annex_g.c3`)
and its test target `//test/c3:float_value_tests`. These files are test data
only. No production target reads them, and nothing here needs Zig at build or
test time.

The generator is `test/migration/float_probe.zig`, a development-only program.
It was **run** with the Zig 0.17.0 binary, and every result was also checked
against an independent model (see Provenance).

## Files

| File | Ops | Vectors |
|---|---|---|
| `arith.txt` | `add`, `sub`, `mul`, `div` (real float branch of Value.add/sub/mul/div) | 6518 |
| `nan.txt` | `add`, `sub`, `mul`, `div`, `cast` with NaN results, NaN operands and f80 non-canonical encodings | 1229 |
| `cast.txt` | `cast` (`@floatCast`, all 20 width pairs) | 1660 |
| `int_float.txt` | `from_u64`, `from_i64`, `big_to_f128`, `int_to_float` | 1136 |
| `float_to_int.txt` | `float_to_int` (Value.floatToInt) | 3405 |
| `compare.txt` | `compare`, `compare_complex`, `classify` | 2037 |
| `print.txt` | `format_f64`, `print`, `print_complex` (Value.print) | 398 |
| `parse.txt` | `parse` (Parser.parseFloat) | 327 |
| `complex.txt` | `cadd`, `csub`, `cmul`, `cdiv`, `conj` | 7141 |
| `annex_helpers.txt` | `ilogb`, `scalbn`, `fmax`, `mul_add` | 1936 |

Each file ends with `# end: N vectors`. A parser can use that count to check
that it read every vector line.

## Line format

The files are plain ASCII with LF line endings. Blank lines and lines that
start with `#` are comments. Every other line is one vector:

```
op operand... = result... provenance
```

Fields are separated by a single space. The operand fields come before a lone
`=` field, the result fields come after it, and the last field is always the
provenance tag. The only field that can contain a space is a quoted string
(`print_complex` results such as `"1 + -2i"`). A string runs from the first `"`
after ` = ` to the last `"` on the line, and it never contains a `"` itself.

| Field kind | Syntax |
|---|---|
| width | `f16`, `f32`, `f64`, `f80`, `f128` |
| float | `0x` + the raw bit pattern in lowercase hex, zero-padded to 4 / 8 / 16 / 20 / 32 digits for f16 / f32 / f64 / f80 / f128. For f80 this is `sign:exponent(15):significand(64)` with the explicit integer bit at bit 63. |
| int | `[-]0x<hex>` with lowercase digits, no leading zeros, `0x0` for zero. It is sign and magnitude, not two's complement, and can be any size (up to 16385 bits). This is the same syntax as `test/c3/data/integer_values`. |
| dest | `bool`, or `s<N>` / `u<N>`: a signed or unsigned integer type of N bits |
| n | a decimal i32 |
| literal | a float literal exactly as Parser.parseFloat passes it to `std.fmt.parseFloat` (no spaces) |
| string | `"..."` |

### Ops

`T` is the width field. "Run" means the Zig expression in the middle column
was evaluated at run time on x86_64 (see Reference configuration).

| op | operands | results | Zig reference |
|---|---|---|---|
| `add` `sub` `mul` `div` | T a b | r | `a + b` etc. on two T values (Value.add/sub/mul/div real branch at width T) |
| `cast` | S D a | r | `@as(D, @floatCast(a))` for an S value (Value.floatCast, toFloat of a float key) |
| `from_u64` / `from_i64` | T x | r | `@as(T, @floatFromInt(@as(u64/i64, x)))` |
| `big_to_f128` | x | r (f128) | Value.zig `bigIntToFloat(limbs, positive)` (64-bit limbs, one `@mulAdd(f128, 2^64, acc, limb)` per limb) |
| `int_to_float` | T x | r | Value.intToFloat / Value.toFloat(T) of the **interned** int x. See "Interned int representation" below. |
| `float_to_int` | T dest a | v kind | Value.floatToInt of a T value to dest. v is the stored int, or `none` (Value `.none`). kind is a FloatToIntChangeKind: `none`, `out_of_range`, `overflow`, `nonzero_to_zero`, `value_changed`. |
| `compare` | T a b | six digits | Value.compare float branch: `std.math.compare(@as(f128, a), op, @as(f128, b))` for op = eq, neq, lt, lte, gt, gte, in that order. Each digit is `1` (true) or `0` (false). For example, `100101` means equal. |
| `compare_complex` | T a_re a_im b_re b_im | `1`/`0` | Value.compare complex branch (op is always neq): `!(re ==) or !(im ==)` at f128 |
| `classify` | T a | class sign | class is `nan` / `inf` / `zero` / `normal` / `subnormal`, from `std.math.isNan`, `isInf`, `x == 0` and `isNormal` in that order. sign is `std.math.signbit`: `pos` / `neg`. |
| `format_f64` | a (f64) | string | `w.print("{d}", .{a})` |
| `print` | T a | string | Value.print `.float` arm (f16: `@round(x*1000)/1000`, f32: `@round(x*1e6)/1e6`, otherwise `@as(f64, @floatCast(x))`, then `{d}`) |
| `print_complex` | T re im | string | Value.print `.complex` arm (`"{d} + {d}i"`; cf32 is rounded like f32, every other width is a plain f64 cast, cf16 included) |
| `parse` | T literal | r | Parser.parseFloat: `@as(T, @floatCast(try std.fmt.parseFloat(f128, literal)))` |
| `cadd` / `csub` | T a b c d | x y | Value.complexAddSub: `(a + c, b + d)` / `(a - c, b - d)` |
| `cmul` / `cdiv` | T a b c d | x y | `annex_g.complexFloatMul/Div(T, a, b, c, d)` for (a + bi) op (c + di) |
| `conj` | T re im | re' im' | Value.complexConj: `(re, -im)`, a sign flip only |
| `ilogb` | T a | n | `std.math.ilogb(a)` (used by complexFloatDiv) |
| `scalbn` | T a n | r | `std.math.scalbn(a, n)` = `std.math.ldexp` (used by complexFloatDiv) |
| `fmax` | T a b | r | `@max(a, b)` (complexFloatDiv applies it to `@abs` values) |
| `mul_add` | f128 a b c | r | `@mulAdd(f128, a, b, c)` (bigIntToFloat's fused step) |

Operand values are canonical encodings, except the f80 non-canonical ones in
`nan.txt` and `compare.txt` (pseudo-NaN, pseudo-infinity, unnormal,
pseudo-denormal), which all carry `zig-0.17.0-run`.

## Provenance

| Tag | Meaning |
|---|---|
| `zig-0.17.0` | The run result **agrees** with the probe's independent model. The model is an exact big-integer implementation of IEEE 754 round-to-nearest-even for each format. It covers + - * /, casts, int<->float conversion, fma, scalbn, ilogb, ordering and float->int truncation, plus the NaN rules documented below. Complex mul/div are re-run through the same model, line for line as in annex_g.zig. |
| `zig-0.17.0-dblround` | The run result agrees with the model of the reference's **two-step** rounding. It differs from one correct rounding. The C3 port must keep these results (see "Double rounding"). |
| `zig-0.17.0-libbug` | The run disagreed with the model on a path that runs in Zig 0.17.0's `compiler_rt` or `std.math` (see "Library defects"). The vector holds the **model** value. The `# lib-bug:` comment on the line before records the value Zig 0.17.0 actually produced. |
| `zig-0.17.0-run` | No independent model exists. This covers the `print`/`format_f64`/`print_complex` strings, `parse`, `fmax`, `conj`, and f80 non-canonical operands. The value is what the run produced. Print strings are also checked to have no exponent and to round-trip through `std.fmt.parseFloat(f64)` to the value printed. |
| `aro-test` | The case comes from the embedded `test complexFloatMul` / `test complexFloatDiv` blocks in `src/aro/annex_g.zig`. The test assertion (inf / NaN) was checked, and the full bits agree with the model. |

Generation aborts if a vector disagrees with the model on a hardware path
(SSE/x87 arithmetic, any comparison, float->int, and so on). The final
canonical run had 0 such disagreements. It recorded 97 `libbug` vectors, 32
`dblround` vectors and 15 `aro-test` vectors.

## Reference configuration

Aro's Value.zig computes on real Zig floats at run time, so "the reference" is
whatever the Zig build of Aro executes. That depends on the backend and the
CPU. The committed vectors come from the **canonical** configuration:

```
zig run -fllvm -mcpu=baseline   (Debug, x86_64-linux, LLVM backend)
```

Each file header records this. In this configuration, f16 is computed in f32
SSE plus compiler_rt `__extendhfsf2`/`__truncsfhf2` conversions. f32/f64 use
SSE. f80 uses the x87 (64-bit precision control). f128 and the remaining f16
conversions use Zig compiler_rt.

The probe was also run with `-fllvm -mcpu=native` (this host has F16C), with
`-fno-llvm -mcpu=baseline` and with `-fno-llvm -mcpu=native`. The self-hosted
x86_64 backend is what a plain `zig build` of Aro uses for Debug on x86_64
(`build.zig` only sets `use_llvm` with `-Dllvm`). Release builds use LLVM.
Across all four configurations, **every non-NaN result is identical**. The
probe compared every vector, and the only exceptions are one or two `fmax`
results for `@max` of a -0 and a +0, which never reaches Annex G because it
passes `@abs` values. All other differences are NaN sign or payload bits:

| Config | Differences from canonical |
|---|---|
| LLVM, native (F16C) | f16 -> f32 of a signaling NaN is quieted (`vcvtph2ps`); 3 vectors |
| self-hosted, native | f32/f64 `add`/`mul` with two NaN operands return the **second** NaN (operands swapped for commutative ops); f16 -> f32/f80 sNaN quieted |
| self-hosted, baseline | as above, and f16 arithmetic uses compiler_rt `__addhf3`... directly: invalid -> **+**NaN `0x7e00`, `a - NaN` flips the NaN's sign; f16 -> f64 sNaN not quieted |

No Aro C source produces a signaling NaN (`__builtin_nan` ORs the payload into
`std.math.nan(T)`, which is quiet). Two-NaN operations and invalid operations
can happen, though, for example `0.0/0.0` or `__builtin_nan("") + __builtin_nan("1")`.
So the NaN *sign* of the f16 default NaN, and two-NaN results at f32/f64, are
genuinely configuration-dependent in the reference. The C3 port follows the
canonical configuration.

Caveat: Aro pins Zig 0.18.0-dev, and that Zig was **not** run. These vectors
come from Zig 0.17.0's code generation, compiler_rt and std (`fmt`,
`parse_float`, `math`). They are **not** differential evidence against the
pinned 0.18-dev binary. The Aro tree cannot be imported under 0.17, so the
probe carries its own copy of the Value.zig float logic and a verbatim copy of
annex_g.zig. Each copy keeps the original's control flow and replaces the
interner with plain values.

## Answers to the open questions in `src/c3/float_value.c3`

### 1. Default NaN sign per width

This is the result of an invalid operation (0/0, inf - inf, 0 * inf,
inf / inf). It is the same for all four ops, in both operand orders, and for
signed zeros (`nan.txt`, "invalid operations" sections):

```
div f16 0x0000 0x0000 = 0xfe00 zig-0.17.0
div f32 0x00000000 0x00000000 = 0xffc00000 zig-0.17.0
div f64 0x0000000000000000 0x0000000000000000 = 0xfff8000000000000 zig-0.17.0
div f80 0x00000000000000000000 0x00000000000000000000 = 0xffffc000000000000000 zig-0.17.0
div f128 0x00000000000000000000000000000000 0x00000000000000000000000000000000 = 0x7fff8000000000000000000000000000 zig-0.17.0
```

These confirm the contract constants `DEFAULT_NAN_F16/F32/F64/F80/F128`:
negative for f16/f32/f64/f80, **positive** for f128. Only f16 depends on the
configuration (the self-hosted backend with a baseline CPU gives `0x7e00`, see
above).

### 2. x87 rule for two NaN f80 operands

The result is order-independent and is always returned quieted:

1. A quiet NaN beats a signaling NaN, whatever the significands are.
2. Between two NaNs of the same kind, the larger 64-bit significand wins. The
   sign is ignored, and the explicit integer bit and quiet bit are included.
3. On equal significands, the **positive** NaN wins.

Evidence (`nan.txt`, f80 sections, both orders for all four ops):

```
add f80 0x7fffc000000000000001 0xffffc000000000000002 = 0xffffc000000000000002   (larger significand, sign ignored)
add f80 0xffffa000000000000006 0x7fffc000000000000001 = 0x7fffc000000000000001   (qNaN beats sNaN)
add f80 0xffff8000000000000001 0x7fffc000000000000000 = 0x7fffc000000000000000   (qNaN beats sNaN with larger payload)
add f80 0xffffc000000000000005 0x7fffc000000000000005 = 0x7fffc000000000000005   (tie -> positive)
add f80 0xffff8000000000000005 0x7fff8000000000000005 = 0x7fffc000000000000005   (two sNaNs, tie -> positive, quieted)
```

With one NaN operand, that NaN is returned quieted, sign kept. The contract's
"larger significand wins" needs rules 1 and 3 added.

Every other width follows "first NaN operand (lhs if NaN, else rhs), quieted,
sign and payload kept", with one exception. f128 `sub` with only the rhs a NaN
returns that NaN with its **sign flipped**, because compiler_rt `__subtf3` is
`__addtf3(a, -b)`. For example,
`sub f128 0x3fff0... 0x7fff8...01 = 0xffff8...01`. f16 `sub` does not flip in
the canonical configuration (`sub f16 0x3c00 0x7e01 = 0x7e01`).

### 3. Do widening casts quiet NaNs?

It depends on the width pair, because each pair takes a different
instruction or compiler_rt routine. Results for the signaling NaNs in
`nan.txt` (canonical):

| Cast | Quiet bit | Implementation |
|---|---|---|
| f16 -> f32 | kept as is | `__extendhfsf2` (`cast f16 f32 0x7c01 = 0x7f802000`) |
| f16 -> f64 | **set** | `__extendhfsf2` then SSE `cvtss2sd` (`= 0x7ff8040000000000`) |
| f16 -> f80 | kept as is | `__extendhfxf2` (`= 0x7fff8020000000000000`) |
| f16 -> f128 | kept as is | `__extendhftf2` |
| f32 -> f64 | **set** | SSE (`cast f32 f64 0x7f800001 = 0x7ff8000020000000`) |
| f32 -> f80, f64 -> f80 | **set** | x87 `fld` (`= 0x7fffc000010000000000`) |
| f32/f64/f80 -> f128 | kept as is | compiler_rt `extendf` (`cast f80 f128 0x7fff8000000000000001 = 0x7fff0000000000000002000000000000`) |
| any narrowing except f128 -> f80 | **set** | SSE / x87 `fstp` / compiler_rt `truncf` |
| f128 -> f80 | kept as is | `__trunctfxf2` (see the lib-bug below for payloads below bit 49) |

The payload is always aligned at the top of the fraction field, and the sign
is always kept. The contract was right that widening is not uniform. Its
"x87 loads quiet any -> f80" is wrong for f16 -> f80. Its "compiler-rt extendf
keeps f16 -> f32/f64" is wrong for f16 -> f64 under LLVM. Its "narrowing
quiets" does not hold for f128 -> f80.

### 4. f16 arithmetic behaviour

- **Finite results are correctly rounded** (round to nearest, ties to even,
  subnormals kept). All finite f16 `add`/`sub`/`mul`/`div` vectors (cross
  product, half-ulp ties, mul ties (1+2^-s)(1+2^-t), subnormal ties,
  overflow/underflow boundaries, random) agree with a single correct rounding
  in every configuration. The reference computes in f32 and rounds once to f16.
  f32 has more than 2*11+2 bits, so that double rounding is harmless for these
  four ops. A direct soft-float f16 implementation is therefore exact.
- NaN results follow the f32 rules in the canonical configuration: the first
  NaN operand, quieted, with its payload; invalid gives `0xfe00`. The f32 path
  keeps the f16 sNaN signaling through `__extendhfsf2` and quiets it in the SSE
  op, so `add f16 0x7c01 0x3c00 = 0x7e01`.

## Other reference behaviour the vectors pin down

### Double rounding (`zig-0.17.0-dblround`, keep it)

- **Parser.parseFloat** parses to f128 and then `@floatCast`s to the
  literal's width. A decimal just above a midpoint of the narrow format first
  rounds to that exact midpoint in f128, and then ties to even, so it can come
  out one ulp below the correctly rounded value. For example,
  `parse f64 1.00000000000000011102230246251565404236316680908203125000...0001 = 0x3ff0000000000000`,
  where a direct `parseFloat(f64, ...)` gives `...0001`. The `parse` lines
  tagged `dblround` are exactly those where `std.fmt.parseFloat(T, s)` would
  differ. f16, f32, f64 and f80 are all affected.
- **bigIntToFloat** rounds once per 64-bit limb, so ints of three or more
  limbs can differ from correct rounding:
  `big_to_f128 0x8000...40000000000000000001 = 0x40be0...` (correctly rounded
  would be one ulp up).
- **Value.toFloat of a big int** is bigIntToFloat (to f128) followed by
  `@floatCast` to the target width. That is a second rounding, which affects
  f32/f64/f80 for ints above 113 bits, for example
  `int_to_float f64 0x40000000000002000000000000001 = 0x4710000000000000`.

### Interned int representation (`int_to_float`)

Aro's interner (`src/backend/Interner.zig` put/get) gives Value.toFloat an int
in one of three forms. `.u64` is used when the int fits u32. `.i64` is used
when it is negative and fits i32. `.big_int` is used otherwise, including for
values in [2^32, 2^64).
`int_to_float` vectors follow that rule: only the `.big_int` form takes the
f128 hub and its double rounding. Below 2^113 this is still exact, because
f128 holds the int exactly. `from_u64`/`from_i64` test the plain
`@floatFromInt` primitive over the whole 64-bit range.

### float_to_int

- The source is first widened to f128 (exact). Then the conversion goes, in
  order: `bool` (`none` iff the value is 0 or 1, so NaN is `0x1 value_changed`);
  unsigned and `< 0` (so not -0.0, not NaN) gives `0x0 out_of_range`;
  non-finite gives `none overflow`.
- Otherwise it truncates. The stored value is the **untruncated** integer, so
  `out_of_range` vectors carry the full value, for example 2^200 for `u8`.
  `-0.5` gives `0x0 nonzero_to_zero`, positive.

### Comparisons and predicates

`compare` goes through f128: -0 == +0, NaN is unordered (`010000`). The
Value-level `shallowCompare` (same interned ref means equal) is not represented
here. Note for the integrator: float keys are compared with `std.meta.eql`,
which uses `==` on floats, so every NaN constant is interned separately and two
NaN Values never share a ref. f80 non-canonical encodings classify as `nan`,
and pseudo-denormals as `subnormal`, which matches the contract's
classification rule. In x87 arithmetic, every non-canonical operand except a
pseudo-denormal is an invalid operand (result `0xffffc000000000000000`). A
pseudo-denormal acts as the normal value 2^-16382 (`nan.txt`).

### Printing

`{d}` prints the shortest round-trip digits without an exponent, so `1e300`
prints 301 digits. Specials print as `inf`, `-inf`, `nan` and `-nan` (the NaN
sign bit is printed), and -0 prints as `-0`. f16/f32 values are rounded to
3/6 decimals in f64 first, so tiny values print `0` or `-0`. f80/f128 values
outside the f64 range print `inf`. cf16 is **not** rounded, unlike f16.

### Annex G

- `cmul` reproduces the reference quirk in the "recover infinities from
  overflow" branch. NaN operands are zeroed but `recalc` stays false, so the
  result stays NaN + NaNi. C Annex G recalculates here. An example is
  `cmul T max nan max 0` in the "recovery paths" section.
- `@max` (fmax): when one operand is NaN the other is returned. With two NaNs
  the rhs is returned unchanged (not quieted). For `@max(-0, +0)` the order of
  the zeros matters and differs between widths and backends; Annex G never hits
  that case.

## Library defects (`zig-0.17.0-libbug`)

These are Zig 0.17.0 library results that are not correctly rounded, or not
NaN-preserving. The vectors hold the model value, and the Zig output is in the
preceding `# lib-bug:` comment. Following the precedent of
`test/c3/data/integer_values` (`std-bug`), the C3 port should produce the
vector value. The pinned 0.18-dev library may or may not share these bugs. If
the integrator decides to match a defect instead, the observed value is right
there.

| Count | Where | Defect |
|---|---|---|
| 24 | `div f128` (arith.txt) | compiler_rt `__divtf3` subnormal results: it rounds before shifting into the subnormal range, has no ties-to-even, and deep underflow goes through an out-of-range `@intCast` and returns garbage. For example, `3*2^-16494 / 2` gives 1 ulp instead of 2, and `div f128 0x1 0x3fff0...` (minsub / 1.0) gives 0. |
| 4 | `mul f128` (arith.txt) | compiler_rt `__multf3`: largest subnormal times max is 1 ulp low (`0x...fc` instead of `0x...fd`) |
| 23 | `cast f80 f16` (cast.txt) | compiler_rt `__truncxfhf2`: f16 subnormal results are wrong, sometimes by many ulps (`0x3fedc9... -> 0x0049`, correct `0x0064`) |
| 1 | `cast f128 f80` (nan.txt) | compiler_rt `__trunctfxf2` does not quiet, so a signaling f128 NaN whose payload lies only below bit 49 becomes **+inf** (`0x7fff8000000000000000`). The vector holds the NaN-preserving `0x7fffc000000000000000`. |
| 30 | `scalbn` (annex_helpers.txt), all widths | `std.math.ldexp(±0, n)` for large positive n returns a nonzero value, or inf, because the zero takes the "subnormal input" path. For example, `scalbn(0.0, 1023)` gives `0x3ca0...` for f64, and for f80 an *unnormal*. |
| 15 | `cdiv` (complex.txt), all widths | the same ldexp defect reached through complexFloatDiv. A zero partial quotient scaled by a large `-logb`, for example `(max + max i) / (minsub + minsub i)`, gives an imaginary part of 0.25 instead of +0. Each of these was confirmed to be exactly the ldexp effect: the model with Zig's real `scalbn` reproduces the run. |

The contract's scalbn note ("bit-exact including its own rounding ... severe
underflow -> signed zero") still holds for nonzero inputs. Every finite nonzero
`scalbn` vector, including the subnormal-result ties, agrees with correct
rounding.

## Regenerating

This is a development step only and never runs in Bazel. From the repo root:

```
ZIG_GLOBAL_CACHE_DIR=$TMP/zc ZIG_LOCAL_CACHE_DIR=$TMP/zc \
  /home/user/tools/zig/ziglang/zig run -fllvm -mcpu=baseline \
  test/migration/float_probe.zig -- test/c3/data/float_values
```

The output is deterministic. Pseudo-random operands come from a fixed-seed
splitmix64 in the probe, and a second run leaves `git diff` empty. The probe
exits with an error if any vector disagrees with the model on a non-library
path. To reproduce the configuration comparison, run with `-fllvm -mcpu=native`
or `-fno-llvm` into a scratch directory. In those configurations disagreements
are only reported, not fatal. stderr also prints how often the NaN results
agree with the stage-0 contract's original NaN rules.
