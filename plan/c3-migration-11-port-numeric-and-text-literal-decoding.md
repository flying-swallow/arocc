---
title: 'C3 migration 11 [Lexing & literals]: Port numeric and text literal decoding'
state: complete
depends_on:
- c3-migration-05-port-diagnostic-state-and-rendering
- c3-migration-06-port-language-modes-unicode-tables-and-tokenizer
- c3-migration-10-preserve-floating-and-complex-constant-semantics
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/number_literal.c3, text_literal.c3 and test/c3/literal_tests.c3; register //test/c3:literal_tests. Follow Tokenizer/number_literal.zig Prefix/Suffix parsing and text_literal.zig Item/Kind, concatenation, escape/UCN decoding, encoding validation and target wchar limits; extract reusable conversion semantics from Parser.zig parseFloat/fixedSizeInt/parseInt/bitInt/parseNumberToken and charLiteral/stringLiteral without introducing a parser dependency. Preserve C standard/emulation gates, binary/octal/hex forms, digit separators, imaginary and extended-width suffixes, UTF8/16/32 and wide strings, invalid-encoding diagnostics and concatenation restrictions. Return typed literal values and diagnostic locations through existing C3 modules. Acceptance: bazel test //test/c3:literal_tests with reference-derived values and exact diagnostic text for malformed suffixes, overflowing integers, f80/f128 rounding, surrogate and UCN boundaries, multichar constants and mixed encodings. The preprocessor must be able to use the syntax/character decoder without requiring a full AST

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define the typed literal result records and the diagnostic message IDs both literal modules emit. Keep the decoder API parser-free so the preprocessor can call it.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **11.1 `number-syntax`**: owns `src/c3/number_literal.c3`. Prefix/Suffix parsing, digit separators, binary/octal/hex, imaginary and extended-width suffixes, standard/emulation gates.
- **11.2 `number-values`**: owns `src/c3/number_value.c3`. Conversion logic extracted from Parser.zig parseInt/fixedSizeInt/bitInt/parseFloat/parseNumberToken (f128 parse then cast).
- **11.3 `text-decoding`**: owns `src/c3/text_literal.c3`. Item/Kind, escapes, UCNs, UTF-8/16/32 and wide encoding validation, target wchar limits.
- **11.4 `char-string`**: owns `src/c3/text_literal_semantics.c3`. charLiteral/stringLiteral semantics: multichar constants, concatenation rules and restrictions.
- **11.5 `vectors`**: owns `test/c3/data/literals/*`. Reference values and exact diagnostic text from the pinned Zig build for malformed suffixes, overflow, f80/f128 rounding, surrogates.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/literal_tests.c3`, register `//test/c3:literal_tests`, confirm a no-AST decode path works.

## Completion notes (stage 2 integrator)

- Merged: `number_literal.c3` (11.1), `number_value.c3` (11.2), `text_literal.c3` (11.3), `text_literal_semantics.c3` (11.4), vectors `test/c3/data/literals/*.txt` (11.5). All four modules are in `//:aro_c3_lib`. Their unit targets (`number_literal_tests`, `number_value_tests`, `number_value_manual_tests`, `text_literal_tests`, `text_literal_semantics_tests`, `text_literal_semantics_manual_tests`, `literal_contract_tests`) run in `//test/...`; the `manual` tags are removed.
- Seams fixed: number_value uses number_literal's `Suffix` methods (the local copies are gone). `Value.print` on a bytes value calls `text_literal_semantics::print_string`, which is Zig printString. Zig `Compilation.wcharMax` / `float80Type` / `CharUnitSize` now live in `compilation.c3` as `Compilation.wchar_max()`, `Compilation.float80_type()` (fault `compilation::NO_FLOAT80`) and `compilation::CharUnitSize`. String literals decode with max_codepoint 0x10FFFF, and char constants use `kind.max_codepoint(comp)`, as Parser.zig does. `u"\U0001F917"` gives the surrogate pair `3ed8 17dd`.
- `//test/c3:literal_tests` (`test/c3/literal_tests.c3`) is data-driven over all 6,078 vectors: kinds/target_info, suffix, number, pp, char, string, ucn_ident and 273 fixture-derived lines. It uses only the parser-free API (token bytes plus Location, no token list or AST), so it also confirms the no-AST decode path. Results are compared as text. Diagnostics are compared in emission order with their exact text and expanded column, under -Weverything, because the vectors list them before the effective-kind filter. Fixture `[-W...]` suffixes are checked against the template option. The test asserts every file's `# end: N` count. It also has explicit acceptance cases that render the full diagnostic lines (`t0.c:1:1: error: invalid suffix 'w' on floating constant`, ...), for: malformed suffixes, overflow, f80/f128 0.1 rounding, UCN/surrogate boundaries, multichar constants, mixed encodings, and printString.
- Result: all 6,078 vectors pass, in fastbuild and in `-c opt`. That includes the 29 `dblround` vectors (f128 parse, then cast). `bazel test //test/...`: 37/37 pass in both modes.
- Normalisations (documented in the test header, with their counts asserted):
  - 397 vectors: Zig `Key.toRef` interns a float equal to +0.0 or 1.0 as the static int zero/one, so the value of `1.0f` is the int 1. The probe keeps the float.
  - 99 vectors: for an imaginary float the inner float_literal node has no value. The oracle `test/cases/ast/__float80.c` shows this. NumberValue.literal_val is therefore `none`, while the probe reports the parsed float.
- Reference panics (`= unreachable`, 29 vectors): the port's results are pinned in `UNREACHABLE_RESULTS`.
  - `0x.p1`: the port reports the new C3-only error `hexadecimal floating constant requires a significand` (`NumberValueDiag.HEX_FLOAT_NO_SIGNIFICAND`, added in number_value.c3) and uses +0.0.
  - `'€'` / `'😀'` on a signed-char target: the port truncates to 8 bits and sign-extends (-0x54 / 0x0), after char_too_large.
  - `'\é'` / `"\é"`: `unknown escape sequence '\xc3'`, then 0xA9 decodes as improperly encoded text.
- Caveat: apart from the `fixture*` lines, the vectors come from a Zig 0.17.0 port of the Aro sources, not from the pinned 0.18-dev binary.
