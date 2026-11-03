---
title: 'C3 migration 09 [Constant values]: Port constant storage and integer arithmetic'
state: waiting
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
