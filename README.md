<img src="https://aro.vexu.eu/aro-logo.svg" alt="Aro" width="120px"/> <!-- Graphic design is my passion -->

# Aro

A C compiler with the goal of providing fast compilation and low memory usage with good diagnostics.

The project intends to support standard C and all common extensions:

| Version          | Status                      | Issue                                                                              |
| ---------------- | --------------------------- | ---------------------------------------------------------------------------------- |
| C2Y              | Partial                     | [C2y support](https://github.com/Vexu/arocc/issues/1130)                           |
| C23              | Complete                    |                                                                                    |
| C17              | Complete excluding warnings | [Ensure C17 compatibility](https://github.com/Vexu/arocc/issues/820)               |
| C11              | Complete excluding warnings | [Ensure C11 compatibility](https://github.com/Vexu/arocc/issues/821)               |
| C99              | Complete excluding warnings | [Ensure C99 compatibility](https://github.com/Vexu/arocc/issues/822)               |
| C95              | Complete                    |                                                                                    |
| C89              | Complete                    |                                                                                    |
| GNU extensions   | Partial                     | [Ensure GNU C extension compatibility](https://github.com/Vexu/arocc/issues/824)   |
| Clang extensions | Partial                     | [Ensure Clang C extension compatibility](https://github.com/Vexu/arocc/issues/825) |

Aro will be used as the C frontend for [C to Zig translation](https://github.com/ziglang/translate-c/) in the Zig toolchain.

## Codegen

Earlier there was a proof of concept backend capable of producing a valid hello world binary
but it was removed to make way for a new more capable backend which is still under construction.
The new backend will reuse parts of the self-hosted Zig compiler.

[#542](https://github.com/Vexu/arocc/issues/542)

### ARM64 macOS code generation in the C3 compiler

The C3 compiler has a native ARM64 backend for Apple Silicon macOS, organized
like the x86-64 backend. It uses Apple's assembler and linker through `xcrun`;
install Xcode Command Line Tools and the host C3 compiler before building.

```sh
bazel build //:aro_cc
./bazel-bin/aro_cc/aro_cc hello.c -o hello
./hello
```

`-S`, `-c`, `-O0` through `-O3`, and `-fwhole-program` are supported. The first
version handles scalar C, structs and floating-point aggregates, globals,
varargs and libc interoperability. `-fintegrated-as`, vectors, inline assembly,
atomics, TLS and 128-bit arithmetic are not supported on ARM64 yet.

Some Xcode SDK headers still encounter C frontend parsing gaps for Apple
availability and nullability annotations. The backend does not yet make those
headers fully usable; the native ABI tests declare libc functions directly.

See [the backend design](ir.c3l/aarch64/README.md). Run native execution
and Apple Clang interoperability checks with:

```sh
bazel test //aro_cc/test/unit/backend:aarch64_tests //aro_cc/test/src/cli:darwin_arm64_integration
```

### Optional optimizer in the C3 compiler

The C3 compiler includes IR optimization by default. Build it without the
transformation passes using:

```sh
bazel build //:aro_cc --define=aro_optimizer=false
```

This build still generates, verifies, and lowers IR. Optimization flags such
as `-O2` produce one warning per invocation and fall back to `-O0`, including
the optimization-related predefined macros. Build without the define to
include the optimizer again. `--verify-ir` works in either build, also at `-O0`.

The driver calls the same `ir_opt::run` interface in both builds; the build
selects either the transformation implementation or a stub. CFG analysis and
verification live in `aro::backend::ir_support`. Source distributions contain
the implementation selected when the archive was built. When assembling
sources manually, include exactly one optimizer implementation.

## Using aro as a module

The following assumes that your package has a `build.zig.zon` file.

```sh-session
zig fetch --save git+https://github.com/Vexu/arocc.git
```

Add the following to your `build.zig`:

```zig
const aro = b.dependency("aro", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("aro", aro.module("aro"));

// Optional; this will make aro's builtin includes (the `include` directory of this repo) available to `Toolchain`
b.installDirectory(.{
    .source_dir = aro.path("include"),
    .install_dir = .prefix,
    .install_subdir = "include",
});

```

Now you can do

```zig
const aro = @import("aro");
```

in your Zig code.

### Reusable C3 IR

The independent frontends live in `aro_cc/src/` and `aro_c3c/src/`, shared compiler tooling lives in `aro/compiler/`, and backend code lives in `ir.c3l/`. See [IR library usage](docs/ir-library.md) and run `bazel run //:ir_example` for a frontend-free example.

See [compiler library layout](docs/compiler-layout.md) for the independent C and C3 frontends and shared compiler tooling.

### Compiler executables

`aro_cc` compiles C. `aro_c3c` is the separate C3 compiler; its current port
supports parsing and semantic checks:

```sh
bazel build //:aro_cc //:aro_c3c
./bazel-bin/aro_c3c/aro_c3c --check example.c3
```

C3 code generation is not implemented yet. Both compilers use the shared
utilities in `aro/compiler/` and the backend in `ir.c3l/`.
