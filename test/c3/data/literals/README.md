# Numeric and text literal reference vectors

Expected results for plan 11 (numeric and text literal decoding). They cover
`src/aro/Tokenizer/number_literal.zig`, `src/aro/Tokenizer/text_literal.zig`,
the literal value logic of `src/aro/Parser.zig` (`parseNumberToken`,
`parseInt`, `fixedSizeInt`, `bitInt`, `parseFloat`, `getMSVCIntSuffixType`,
`charLiteral`, `stringLiteral`), the `#if` literal rules of
`src/aro/Preprocessor/Parser.zig` (`primaryExpr`) and the decoding loop of
`Preprocessor.unescapeUcn`. They are inputs for the C3 port
(`src/c3/number_literal.c3`, `number_value.c3`, `text_literal.c3`,
`text_literal_semantics.c3`) and its test target `//test/c3:literal_tests`.
These files are test data only. No production target reads them, and nothing
here needs Zig or Python at build or test time.

There are two generators, both development-only:

- `test/migration/literal_fixtures.py` extracts expectations from the
  `test/cases` fixtures (the oracle) into `fixtures.txt`.
- `test/migration/literal_probe.zig` is a standalone Zig 0.17.0 program
  carrying copies of the Zig sources listed above. It was **run** to compute
  the curated vectors in every other file. It then re-evaluates every line of
  `fixtures.txt` and reports disagreements (see Cross-check).

## Files

| File | Ops | Vectors | Source |
|---|---|---|---|
| `fixtures.txt` | `fixture_diag`, `fixture_type`, `fixture_eq`, `fixture_ast` | 273 | test/cases (oracle) |
| `suffix.txt` | `prefix`, `suffix`, `suffix_props` | 575 | probe |
| `number.txt` | `number` | 2125 | probe |
| `pp.txt` | `pp_number`, `pp_char` | 259 | probe |
| `char.txt` | `char` | 2048 | probe |
| `string.txt` | `string`, `ucn_ident` | 684 | probe |
| `kinds.txt` | `kind_info`, `concat`, `target_info` | 114 | probe |

Each file ends with `# end: N vectors`. A parser can use that count to check
that it read every vector line.

## Line format

The files are ASCII with LF line endings. Blank lines and lines that start
with `#` are comments. Every other line is one vector:

```
op input... = result... provenance [ | diag ]*
```

The part before the first ` | ` is split on single spaces. The input fields
come before a lone `=` field, the result fields come after it, and the last
field before ` | ` (or the end of the line) is the provenance tag. Each
` | `-separated segment after that is one diagnostic (see Diagnostics).

### Encoding

Literal spellings (token text, including prefixes and quotes), fixture case
names and C bytes in suffix/bytes fields are **percent-encoded**: every byte
outside 0x21..0x7E, and every `%` and `|`, is written as `%XX` (uppercase hex).
For example `'é'` is `'%C3%A9'`, `'\%'` is `'\%25'` and `"a b"` is `"a%20b"`.
The token is the exact source spelling: `'\n'` in a vector is the four bytes
quote, backslash, `n`, quote. Diagnostic text uses the same encoding except
that spaces are kept (0x20 is not encoded).

### Configurations

`config` is `<triple>/<std>/<emulate>[/ms][/uchar|/schar]`:

| Part | Meaning |
|---|---|
| triple | target, e.g. `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-windows-msvc`, `avr-freestanding-none`. Fixtures keep the spelling of their `--target=` (`x86_64-linux`, `arm64-apple-darwin`, ...); no `--target` is the native `x86_64-linux-gnu`. |
| std | `LangOpts.Standard` tag: `c89`, `gnu89`, `c99`, `c11`, `c17`, `default`, `gnu17`, `c23`, `gnu23`, `c2y` (ordered as in LangOpts.zig; `default` sits between `c17` and `gnu17`) |
| emulate | `gcc`, `clang`, `msvc`, `no` (`LangOpts.emulate`) |
| `ms` | `ms_extensions` on (`--emulate=msvc` turns it on; `/ms` is written whenever it is on) |
| `uchar` / `schar` | `-funsigned-char` / `-fsigned-char` (`char_signedness_override`) |

`kinds.txt` `target_info` lists, for every probe configuration, the target
facts the literal code reads (char signedness, `wchar_t`, `intmax_t`,
`uint_least16_t`, `uint_least32_t`, int/long/long long/double/long double
bits, `hasInt128`, `float80Type`). A C3 test should assert those against
`target.c3` first, so that a target-table difference is not mistaken for a
literal-decoding bug.

### Types and values

| Field | Syntax |
|---|---|
| type | Zig `QualType` decl names: `char schar uchar short ushort int uint long ulong long_long ulong_long int128 uint128`, `float double long_double float16 bf16 float128 float32 float64 float32x float64x dfloat32 dfloat64 dfloat128 dfloat64x`; `bitint_s<N>` / `bitint_u<N>` for `_BitInt(N)` / `unsigned _BitInt(N)`; `complex_<type>` for `_Complex`; `<elem>[<len>]` for a string array (elem is the concrete int type, e.g. `ushort[3]` for `L"..."` on Windows) |
| int | `[-]0x<hex>`, lowercase, sign and magnitude, `0x0` for zero (same as `test/c3/data/integer_values`) |
| float | `f16:` / `f32:` / `f64:` / `f80:` / `f128:` + the raw bits zero-padded to 4/8/16/20/32 hex digits (same bit syntax as `test/c3/data/float_values`). The width is the **bit size of the literal's type** on that target, as in Parser.parseFloat: `bf16` is stored as an f16 key, `float32x` as f64, `float64x`/`dfloat64x` as f128, `double` as f32 on AVR. |
| complex | `cf16:` ... `cf128:` + `<re bits>:<im bits>` |
| `none` | Value `.none` (imaginary integer literals) |
| bytes | lowercase hex of the interned bytes, little-endian code units, NUL terminator included |

### Ops

| op | input | result |
|---|---|---|
| `prefix` | msvc(0/1) buf | Prefix.fromString tag, Prefix.stringLen |
| `suffix` | `int`/`float` msvc(0/1) buf (`-` for empty) | Suffix tag (Zig spelling: `None`, `ULL`, `IF32x`, ...) or `invalid` (null) |
| `suffix_props` | Suffix tag | isImaginary isSignedInteger isBitInt isFloat80 isMSVCExtension (`1`/`0`; isSignedInteger is `-` where Zig has `unreachable`) |
| `number` | config literal | `fail` (number_literal.Parser.parse returned ParsingFailed), or `prefix suffix bytes qt val literal_qt literal_val`. `bytes` is Parser.Result.bytes. `qt`/`val` are the expression (complex type and value for imaginary literals); `literal_qt`/`literal_val` are the int_literal / float_literal node (NumberValue.literal_qt / literal_val). |
| `pp_number` | config literal | `fail`, `rejected` (float or imaginary: `float_literal_in_expr`, primaryExpr returns null), `signed <int>` or `unsigned <int>` |
| `pp_char` | config token | `signed <int>` / `unsigned <int>` (primaryExpr char literal arm) |
| `char` | config token | `kind qt signed\|unsigned <int>` (Parser.charLiteral; `kind` is the text_literal.Kind, `char` for empty/unterminated tokens) |
| `string` | config N tok1..tokN | `kind unit qt bytes`, `cannot_concat <i>` (unsupported_str_cat at token i), `unterminated <i>` (preprocessor already reported it) or `fail` (ParsingFailed: an improperly encoded piece in a concatenation) |
| `ucn_ident` | config identifier | the unescaped UTF-8 bytes (`-` if empty) |
| `kind_info` | config kind | maxCodepoint maxInt charLiteralType elementType charUnitSize internalStorageAlignment wcharMax |
| `concat` | kind kind | Kind.concat result or `cannot_concat` |
| `target_info` | config | see Configurations |

Token ids come from the spelling, as the tokenizer would assign them: a
prefix (`u8`, `u`, `U`, `L`) and quote select the kind; `''`, `u8''` etc. are
`empty_char_literal`; a token whose closing quote is missing (or escaped) is
`unterminated_char_literal` / `unterminated_string_literal`.

### `unreachable`

`result` is `unreachable` when the Zig code reaches safety-checked illegal
behaviour for that input (a panic in a Debug build of Aro, undefined behaviour
in a release build). The comment line just before says where. Only the
diagnostics recorded before that point are listed. The C3 port has no
reference behaviour to match on these inputs; it must not crash, and a C3 test
should only check the listed diagnostics. Occurrences:

| Where | Inputs |
|---|---|
| `text_literal.Parser.parse`: `@intCast(val)` to u8 when a plain char constant holds one character above 0xFF on a signed-char target | `'€'`, `'😀'` (UTF-8 text) |
| `Ascii.init`: `@intCast` to u7 of a non-ASCII byte after a backslash (unknown escape) | `'\é'`, `"\é"` |
| `Parser.parseFloat`: `std.fmt.parseFloat(f128, ...) catch unreachable` on a literal the syntax check accepted | `0x.p1` |

## Diagnostics

A diagnostic segment is

```
template tok:offset text
```

- `template` is the Zig constant name: `number_literal.Parser.Diagnostic`
  (`invalid_int_suffix`, `c23_binary`, ...), `text_literal.Parser.Diagnostic`
  (`escape_sequence_overflow`, `four_char_char_literal`,
  `multichar_literal_warning`, ...) or the Parser/Preprocessor diagnostics
  `int_literal_too_big`, `implicitly_unsigned_literal`,
  `gnu_imaginary_constant`, `float_literal_in_expr`, `unsupported_str_cat`,
  `empty_char_literal_error`, `unterminated_char_literal_error`. The C3
  templates are the same names upper-cased with `DIAG_` (number_value and
  text_literal_semantics return them as `NumberValueDiag` /
  `TextSemanticsDiag`).
- `tok` is the index of the token within the vector's input (always 0 except
  for multi-token `string` runs).
- `offset` is the byte offset added to that token's location: 0 for the start
  of the token (prefix included), otherwise text_literal's `offset` field. It
  reproduces Zig's quirks exactly, e.g. `escape_sequence_overflow` for
  `u'\xFFFFFFFF'` is at offset 2 (the `\` after `u'`), and
  `invalid_universal_character` in an identifier is at `start + 2` because
  unescapeUcn uses `Kind.utf_8` (prefixLen 2).
- `text` is the final formatted message without the ` [-W...]` option suffix.

Diagnostics are recorded in emission order **before the effective-kind
filter**: everything the Zig code passes to `effectiveKind` is listed, even
templates whose default kind is `off` (`c23_binary`, `c2y_octal`,
`four_char_char_literal`, `non_standard_escape_char`,
`gnu_imaginary_constant`, `pre_c23_bitint`, `pre_c2y_octal`, ...). A test of
the reporting path applies the template's kind/option (as in the C3
`DiagnosticTemplate`) to decide what is shown. This is the same order and set
Zig produces with every diagnostic enabled. text_literal's `errored` latch
behaves as in Zig either way, because Zig sets it in `err` whether or not the
diagnostic is shown. `pre_c23_binary`, `ucn_basic_char_warning` and
`ucn_control_char_warning` never occur because the Zig code cannot reach them.

`fixtures.txt` messages are the fixture's expected lines and keep the
` [-W...]` suffix. They contain only what the fixture's flags show.

## fixtures.txt

`literal_fixtures.py` reads every top-level `test/cases/*.c`, its manifest
(`args` give the configuration) and its expected diagnostics:

| op | line |
|---|---|
| `fixture_diag` | `case line:col config op input... = tok:offset kind fixture \| message`. `message` matches one of the literal diagnostic templates. `op input...` is the literal at that location, in the same form as the probe ops (`number`, `pp_number` inside `#if`/`#elif`, `char`, `pp_char`, `string N tok...` with the whole adjacent run, `ucn_ident`). `kind` is `error`/`warning`. Tokenizer diagnostics (`[-Winvalid-pp-token]`) are excluded. |
| `fixture_type` | `case line config op literal = type fixture`, from `VALUE_HAS_TYPE(lit, T)` / `EXPECT_TYPE(lit, T)` with a single literal token |
| `fixture_eq` | `case line config op literal = int fixture`, from `_Static_assert(lit == N, ...)`. The literal compares equal to N after the usual arithmetic conversions (N may be negative while the literal's type is unsigned). |
| `fixture_ast` | `case config op input = type value fixture-ast`, from `test/cases/ast/<case>.c`. `type` uses the names above, except that strings keep the AST spelling (`[7]char`) and `value` is the dump's text (`32.5`, `0 + 1i`, `"string"`), percent-encoded. |

The extractor finds the literal by lexing the source line and mapping Aro's
column (one per UTF-8 sequence) to a byte offset. The AST nodes are paired
with source tokens in order, by value and by a suffix-consistency check. Both
are heuristics; the cross-check below confirms every line.

## Provenance

| Tag | Meaning |
|---|---|
| `fixture` | Copied from a test/cases fixture's manifest or `_Static_assert`s (the reference oracle). |
| `fixture-ast` | Copied from a test/cases/ast dump. |
| `zig-0.17.0-port` | Computed by `literal_probe.zig` **run** with Zig 0.17.0: a copy of the Aro 0.18-dev source (see "Reference and caveats"). |
| `zig-0.17.0-port-dblround` | As above, for a float literal whose value differs from one direct rounding, because Parser.parseFloat parses to f128 and then `@floatCast`s (the double rounding documented in `test/c3/data/float_values/README.md`). The C3 port must keep these values. 29 vectors, e.g. `1.000000000000000111022302462515654042363166809082031250...01` gives `f64:0x3ff0000000000000`. |

## Cross-check

The probe re-evaluated all 273 `fixtures.txt` vectors under their
configuration: each `fixture_diag` message must be among the probe's
diagnostics with the same text and `tok:offset`; `fixture_type`,
`fixture_eq` and `fixture_ast` must match the probe's type and value (AST
float values are printed like Value.print). Result of the committed run:
**273 agree, 0 disagree**. An f64 sanity check of `number.txt` against
Python's correctly rounded `float()` differs only on the `dblround` vector
above.

## Reference and caveats

Aro pins Zig 0.18.0-dev, which was **not** run. The Aro tree cannot be
imported under 0.17, so the probe carries its own copies. Their changes are
mechanical:

- AST nodes, the interner and the token list are dropped. A QualType is a
  small struct, values are Zig floats and `std.math.big` ints, and
  `Value.intCast` / `maxInt` are reimplemented for plain ints.
- Diagnostics are recorded instead of reported (see Diagnostics). The
  `Diagnostic` constants were made `pub` so the probe can name them.
- `Ascii.init`, the char `@intCast` and parseFloat's `catch unreachable` flag
  `unreachable` instead of panicking.
- Target facts come from Zig 0.17.0's `std.Target` (`cTypeBitSize`,
  `cCharSignedness`, `ptrBitWidth`). The copies of Aro's own switches are
  `wcharMax`, `float80Type`, `intLeastN`, `smallestNBitIntTargetIndependent`,
  `intMaxType`, `hasInt128` and the `wchar` arm of `initNamedTypes`. The
  triple parser is small: it handles arch aliases and an optional vendor.
- `std.fmt.parseFloat`, `std.unicode` and `std.math.big` are Zig 0.17.0's.

So these vectors are **not** differential evidence against the pinned
0.18-dev binary. Only the `fixture*` vectors are reference output.

## Regenerating

This is a development step only and never runs in Bazel. From the repo root:

```
python3 test/migration/literal_fixtures.py
ZIG_GLOBAL_CACHE_DIR=$TMP/zc ZIG_LOCAL_CACHE_DIR=$TMP/zc \
  /home/user/tools/zig/ziglang/zig run test/migration/literal_probe.zig -- test/c3/data/literals
```

Run the extractor first, because the probe cross-checks `fixtures.txt`. The
probe prints every disagreement to stderr. The output is deterministic: a
second run leaves `git diff` empty.
