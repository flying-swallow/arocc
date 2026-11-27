# Reusable C3 IR

The source tree separates the compiler from the reusable IR:

- `aro/src/` and `aro/app/`: language frontends, driver, and compiler entry point.
- `ir.c3l/core/`: indexed IR, builder, shared diagnostics, type/value interner, and numeric support.
- `ir.c3l/opt/`: analyses, verifier, optimization passes, and legalization.
- `ir.c3l/aarch64/`, `ir.c3l/x86_64/`, and `ir.c3l/*.c3`: machine lowering, rendering, object emission, and linking.
- `ir.c3l/support/`: shared target descriptions, terminal output, and bitsets.

Use the public `//ir.c3l:ir` Bazel source library for the reusable backend. It includes
IR construction, verification, optimization, text dumping, machine lowering,
and object emission, without depending on either language frontend.
`//ir.c3l:core` and `//ir.c3l:optimizer` select smaller subsets from the same module.
The compiler consumes `//ir.c3l:ir` and `//ir.c3l:compiler_adapters`.

All backend sources live in this module, including legacy AST assembly and
linker adapters. Those adapters still consume compiler AST, diagnostics, or
toolchain interfaces and are collected separately in `//ir.c3l:compiler_adapters`;
they are compiled together with the consuming compiler sources. They are not
part of the standalone `//ir.c3l:ir` target.

The `ir.c3l/manifest.json` manifest also declares the native C3 library name
`ir`, with the reusable backend sources and no compiler adapters.

Existing C3 module names (`aro::backend::ir`, `aro::value_interner`, and
`aro::backend::ir_opt`) remain unchanged.

A consumer using the repository's C3 rules can declare:

```starlark
c3_binary(
    name = "my_tool",
    srcs = ["main.c3"],
    deps = ["@arocc//ir.c3l:ir"],
)
```

Use `@arocc//ir.c3l:core` for construction alone or `@arocc//ir.c3l:optimizer` for
construction, verification, and optimization without machine code generation.
These targets collect source files for whole-program C3 compilation; they do
not produce a binary ABI or a C interface.

Run `bazel run //:ir_example` to build, verify, and optimize an `increment(i32)`
function without either language frontend or machine backend. Run
`bazel test //test/unit/backend:ir_core_tests` for the core-only ownership test.

## Ownership and current limits

Keep the interner alive until all IR using it has been freed. `Builder.finish()`
transfers completed declarations and their arenas into an `Ir`; the builder can
then be freed. Free the graph before freeing the interner. `ErrorList` owns its
message allocations and borrows names; free it before freeing the graph.
Instruction references are indices, and optimization/compaction can invalidate
references held by consumers.

This is an initial extraction. The verifier still shares the optimizer module,
optimization levels retain the `aro::code_gen_options` namespace. Some instructions describe ABI
and target-specific behavior; this is not yet a target-neutral public API.
