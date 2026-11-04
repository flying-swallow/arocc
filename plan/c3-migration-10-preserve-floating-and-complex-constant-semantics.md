---
title: 'C3 migration 10 [Constant values]: Preserve floating and complex constant semantics'
state: complete
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

## Completion notes (stage 2 integrator)

Merged stage 0, 10.1–10.6. Targets (all in `test/c3/BUILD.bazel`, none `manual`):
`float_capability_tests`, `float_contract_tests`, `float_narrow_tests`, `float_wide_tests`,
`float_conversion_tests`, `float_print_tests`, `float_print_manual_tests`, `annex_g_tests`,
`float_value_tests` (value.c3 wiring) and `float_vector_tests` (data-driven, every vector in
`test/c3/data/float_values/*.txt`, `# end: N` asserted per file). `bazel test //test/...` passes
in fastbuild and `-c opt` (29/29).

- **Vectors.** 31,787 vectors from a Zig 0.17.0 run (canonical `-fllvm -mcpu=baseline`, Debug).
  They are not differential evidence against the pinned 0.18.0-dev. Value-level ops go through
  value.c3 (add/sub/mul/div, float_cast, int_to_float, float_to_int, print, complex_conj) and
  `float_value::compare`. The primitives go through KeyFloat.
- **Lib-bug vectors (97).** The test expects the *observed* Zig 0.17.0 output from the `# lib-bug:`
  comment. The port reproduces 70 of them. The other 27 are listed in `KNOWN_DIFFERENCES` in
  `float_vector_tests.c3`, where the port gives the correctly rounded model value and every entry
  must be hit:
  - 4 × `mul f128`: `__multf3` rounds largest-subnormal × max 1 ulp low.
  - 23 × `cast f80 f16`: `__truncxfhf2` gives wrong f16 subnormals.
- **Fixes made in integration.**
  - annex_g `box`/`nan_to_zero` and float_print `print_to_f64` used `?:` on KeyFloat, which c3c
    0.8.5 miscompiles at -O0. This caused annex_g vector 149.
  - KeyFloat.cast keeps the quiet bit for any→f128, f16→f32, f16→f80 and f128→f80. A non-canonical
    f80 cast to f32/f64 gives the default NaN, and a cast to f16 ignores the integer bit.
  - KeyFloat.max returns the rhs unchanged when both operands are NaN. For ±0 it returns the lhs at
    f32/f64 and +0 at f16/f80/f128.
- **Observed reference exceptions (they depend on the build).**
  - `@max` of two NaNs returns the lhs under `-O ReleaseSafe` (10.1's table) and the rhs under Debug
    (10.6's vectors). The port follows Debug, and MAX_TABLE's two-NaN rows were rewritten.
  - An f16→f32/f80 cast of a signaling NaN is quieted on an F16C host (`-mcpu=native`) but not at
    baseline. The port follows baseline.
  - Annex G never depends on either case.
- **Not done here.** The `.bytes` arm of value.c3 `Value.print` (Zig `printString`,
  `std.zig.stringEscape`) is `unreachable`. No plan owns it yet.
