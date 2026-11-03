---
title: 'C3 migration 09 [Constant values]: Port constant storage and integer arithmetic'
state: complete
depends_on:
- c3-migration-08-port-type-representation-and-qualified-type-oper
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/value_interner.c3, bigint.c3, value.c3 and test/c3/integer_value_tests.c3; wire into Compilation and //test/c3:integer_value_tests. Grounding: src/backend/Interner.zig Key/Ref/OptRef, limb/string/extra storage, hash/eql and put/get; src/aro/Value.zig intern/int/pointer, intCast, minUnsignedBits/minSignedBits, add/sub/mul/div/rem, shifts/bitwise ops and comparePointers. Port the full interner representation including explicit placeholders for float bit storage, but implement integer/byte/pointer value operations here. Preserve none versus null versus zero, arbitrary-width signed values, two's-complement truncation and overflow return values; do not replace Zig big integers with host long or 128-bit-only arithmetic. Use C3 limb operations with explicit overflow semantics and allocation cleanup. Pointer constants remain node plus byte-offset identities, not native addresses. Acceptance: bazel test //test/c3:integer_value_tests for existing bit-count cases, signed minima, >128-bit arithmetic, wrap/truncation/sign changes, division edge cases, shifts at boundaries, interning deduplication and distinct pointer bases. Generate development-only differential vectors with the pinned Zig implementation, retain expected vectors as test data, and ensure production targets have no Zig dependency

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define `value_interner.c3` Key/Ref/OptRef layout (including float bit-storage placeholders) and the `bigint.c3` public API (limb type, overflow-returning signatures).

**Stage 1: parallel agents (start together after stage 0 merges).**
- **09.1 `interner`**: owns `src/c3/value_interner.c3`. Limb/string/extra storage, hash/eql, put/get, deduplication; port Interner.zig.
- **09.2 `bigint`**: owns `src/c3/bigint.c3`. Arbitrary-width limb add/sub/mul/divrem, shifts, bitwise ops, two's-complement truncation, minUnsignedBits/minSignedBits, explicit overflow results. No host 128-bit shortcuts.
- **09.3 `value-ops`**: owns `src/c3/value.c3`. intern/int/pointer, intCast, none/null/zero, pointer constants as node+offset, comparePointers. Codes against the bigint API; temporary stubs are fine until bigint merges.
- **09.4 `vectors`**: owns `test/migration/value_probe.zig`, `test/c3/data/integer_values/*`. Dev-only pinned-Zig generator for differential vectors (>128-bit, signed minima, wrap, division edges, shift boundaries).

**Stage 2: integrator (1 agent, serial).** Wire into Compilation, write `test/c3/integer_value_tests.c3`, register `//test/c3:integer_value_tests`, confirm production targets have no Zig dependency.

## Completion notes (stage 2 integrator)

- Stage 1 merged: `src/c3/value_interner.c3`, `src/c3/bigint.c3`, `src/c3/value.c3` (all in `//:aro_c3_lib`), wired into `Compilation.interner` (init/free in `compilation.c3`). Unit targets `//test/c3:value_interner_tests`, `//test/c3:bigint_tests`, `//test/c3:integer_value_tests` (the `manual` tag is removed; it now runs in `//test/...`).
- New `//test/c3:integer_vector_tests` (`test/c3/integer_vector_tests.c3`, data `test/c3/data/integer_values/*.txt`, read relative to the runfiles root or from `$INTEGER_VECTORS_DIR`). It parses every vector line and checks it against `aro::value` on an x86_64-linux-gnu `Compilation`, with `_BitInt(bits)` types for `(sign, bits)`: results and secondary returns (overflow bool, `IntCastChangeKind`, ordering, with all six compare operators cross-checked), `none` results, and that the interned expected value has the same ref as the computed one (interner dedup across i64/u64/big-int keys). It asserts each file's `# end: N vectors` count and that a TrackingAllocator ends with no live allocations.
- Result: all 29,872 vectors pass (bit_counts 107, limits 74, int_cast 2288, arith 17472, shifts 8800, bitwise 1131, including the 36 `zig-0.17.0-stdbug` bit_or vectors). No mismatches were found, so value.c3 and bigint.c3 needed no changes. A mutation check on a corrupted copy of the data (a flipped flag, a changed result, a removed end marker) failed as expected.
- Cost: the test compiles in a few seconds and runs in about 0.7 s (fastbuild) / 0.8 s (opt), mostly allocator tracking.
- `bazel test //test/...`: 17/17 pass in fastbuild and in `-c opt`.
- No production target depends on Zig. `test/migration/value_probe.zig` is a development-only generator and is not referenced by any Bazel target. Caveat (from the vectors README): the vectors come from running Zig 0.17.0's std.math.big.int under a port of Value.zig. They are not differential evidence against the pinned Zig 0.18.0-dev.
- Float bit storage remains a placeholder for plan 10, as the plan intends.
