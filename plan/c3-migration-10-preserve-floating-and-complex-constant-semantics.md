---
title: 'C3 migration 10 [Constant values]: Preserve floating and complex constant semantics'
state: waiting
depends_on:
- c3-migration-09-port-constant-storage-and-integer-arithmetic
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/float_value.c3 and annex_g.c3; extend value.c3/value_interner.c3 and add test/c3/float_value_tests.c3 with //test/c3:float_value_tests. Port Value.zig floatToInt/intToFloat/floatCast, arithmetic, comparisons, NaN/Inf tests and printing plus annex_g.zig complexFloatMul/Div. The reference stores f16/f32/f64/f80/f128 and complex variants; Parser.parseFloat first parses f128 then casts. Implement explicit bit-format storage and rounding/conversion routines, using software operations for widths the pinned C3 compiler cannot faithfully provide; do not silently use double/host long double. Reuse bigint for exact conversion and specify behavior for NaN payloads, signed zero, infinities, subnormals and overflow status. Include compiler capability checks as tests before selecting native operations. Production must not shell out to Zig. Acceptance: bazel test //test/c3:float_value_tests in dbg/opt using reference-derived bit-pattern vectors at every width, rounding ties and overflow/underflow, large integer conversions, imaginary operations and the Annex G infinity/NaN cases. Match current behavior even when it differs from an idealized arithmetic implementation; document observed reference exceptions

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Specify the float storage format per width (f16/f32/f64/f80/f128 + complex) in `float_value.c3`, and add compiler capability-check tests that decide which widths may use native operations.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **10.1 `narrow-float`**: owns `src/c3/float_soft_narrow.c3`. f16/f32/f64 arithmetic, rounding and conversion (native only where capability tests pass).
- **10.2 `wide-float`**: owns `src/c3/float_soft_wide.c3`. Software f80/f128 arithmetic, rounding ties, subnormals, overflow/underflow status.
- **10.3 `conversions`**: owns `src/c3/float_value.c3` (conversion section). floatToInt/intToFloat via bigint, floatCast, NaN payloads, signed zero, infinities.
- **10.4 `compare-print`**: owns `src/c3/float_print.c3`. Comparisons, NaN/Inf predicates, value printing matching the reference.
- **10.5 `annex-g`**: owns `src/c3/annex_g.c3`. complexFloatMul/complexFloatDiv including infinity/NaN cases.
- **10.6 `vectors`**: owns `test/migration/float_probe.zig`, `test/c3/data/float_values/*`. Reference bit-pattern vectors at every width; note observed reference quirks.

**Stage 2: integrator (1 agent, serial).** Extend value.c3/value_interner.c3 for float/complex keys, write `test/c3/float_value_tests.c3`, register `//test/c3:float_value_tests`, run dbg+opt.
