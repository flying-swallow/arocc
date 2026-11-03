---
title: 'C3 migration 11 [Lexing & literals]: Port numeric and text literal decoding'
state: waiting
depends_on:
- c3-migration-05-port-diagnostic-state-and-rendering
- c3-migration-06-port-language-modes-unicode-tables-and-tokenizer
- c3-migration-10-preserve-floating-and-complex-constant-semantics
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/number_literal.c3, text_literal.c3 and test/c3/literal_tests.c3; register //test/c3:literal_tests. Follow Tokenizer/number_literal.zig Prefix/Suffix parsing and text_literal.zig Item/Kind, concatenation, escape/UCN decoding, encoding validation and target wchar limits; extract reusable conversion semantics from Parser.zig parseFloat/fixedSizeInt/parseInt/bitInt/parseNumberToken and charLiteral/stringLiteral without introducing a parser dependency. Preserve C standard/emulation gates, binary/octal/hex forms, digit separators, imaginary and extended-width suffixes, UTF8/16/32 and wide strings, invalid-encoding diagnostics and concatenation restrictions. Return typed literal values and diagnostic locations through existing C3 modules. Acceptance: bazel test //test/c3:literal_tests with reference-derived values and exact diagnostic text for malformed suffixes, overflowing integers, f80/f128 rounding, surrogate and UCN boundaries, multichar constants and mixed encodings. The preprocessor must be able to use the syntax/character decoder without requiring a full AST

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
