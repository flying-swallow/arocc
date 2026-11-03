---
title: 'C3 migration 06 [Lexing & literals]: Port language modes, Unicode tables and tokenizer'
state: complete
depends_on:
- c3-migration-04-port-source-ownership-and-compilation-storage
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a19fa9-2336-7a90-9966-bb5d1d12e81c
- 01a19fc9-8ed1-7002-867f-2cf8d2c846dc
---

Add src/c3/lang_opts.c3, char_info.c3, identifier_tables.c3, tokenizer.c3 and test/c3/tokenizer_tests.c3; register //test/c3:tokenizer_tests. Grounding: src/aro/LangOpts.zig Standard aliases and keyword/emulation options; char_info.zig and char_info/identifier_tables.zig; Tokenizer.zig Token.Id, getTokenId, UCNKind.classify, next, nextNoWS and nextNoWSComments. Preserve token IDs semantically, byte ranges, source/line/splice accounting, keyword gating by standard, digraphs, comments, preprocessing-number boundaries and malformed literal tokens. Copy Unicode table data with its existing LICENSE-UNICODE attribution, not the host library's potentially different Unicode version. Keep literal semantic decoding for the separate numeric/literals step. Use small language-option enums without requiring a full target implementation yet. Port expectTokens/expectTokensExtra unit cases; retain the progress invariant from testOne for arbitrary bytes including embedded NUL. Acceptance: bazel test //test/c3:tokenizer_tests in dbg/opt, existing lexical cases across C89/C99/C11/C23/C2Y and deterministic randomized byte streams that terminate at EOF without out-of-range access

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
