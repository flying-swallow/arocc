# C3 port conventions

Shared rules for every module under `src/`. Established by plan 04 (source, string_interner, compilation); follow them unless a plan says otherwise.

## Modules and files
- C-specific modules live under `src/frontend/c/` and use `aro::frontend::c::<module>` namespaces, including the compilation context, diagnostics, driver, and C AST-to-IR lowering. Shared numeric, source, utility, target, toolchain, and backend modules retain their existing locations and namespaces. The root module `aro` (`aro.c3`) holds only crate-wide items.
- This directory boundary establishes ownership; existing backend dependencies on C compilation, diagnostics, and typed constant operations remain explicit. Backend independence requires a separate interface refactor. The public `aro::api` facade remains stable; direct C module imports use the new namespace.
- A large Zig file may be split over several C3 files that all declare the same module (`aro::target` is target.c3/target_cpu.c3/target_data.c3; `aro::frontend::c::type_store` is type_store*.c3 plus type_print.c3). Each file lists its own imports.
- Every file is listed explicitly in `//:aro_c3_lib` (root `BUILD.bazel`). Unit tests go in `test/unit/<area>/<name>_tests.c3` and are registered as `c3_test` (and in the `all` suite) in that area's `BUILD.bazel`, with their data under `test/unit/<area>/data/`; integration cases are files in `test/test_suite/<area>/`; harness code lives in `test/src/` (see `test/README.MD`).
- Test files use `module <name>_tests;` and mark each test `fn void x() @test`. Helpers that take parameters must not be inside a `@test` module section, because c3c rejects them there.

## Naming
- Types use PascalCase. Zig's nested types are flattened with the parent's name as a prefix where needed to stay unambiguous: `Source.Id` becomes `SourceId`, `Source.Kind` becomes `SourceKind` and `StringInterner.StringId` becomes `StringId`. Types that are already distinctive (`Location`, `ExpandedLocation`) keep their names.
- Functions and methods are snake_case ports of the Zig names (`addSourceFromBuffer` becomes `add_source_from_buffer`). Methods take `&self`, or `self` for small values.
- Enum values and constants are SCREAMING_CASE (`SourceKind.USER`, `source::UNUSED_ID`).
- `alias` is a C3 keyword. Use `is_alias` / `al` instead.
- Stored IDs and offsets keep Zig's widths (`uint` for u32); size and index types follow the selected C3 stdlib API.

## IDs and handles
- Handles are value types that never hold pointers. Plain indices use `typedef X = uint;`, a distinct type (`StringId`). Indices that carry flag bits use a `bitstruct` with the Zig field layout (`SourceId`: `index : 0..30`, `is_alias : 31`).
- Sentinels are module constants named after the Zig enum tags: `source::UNUSED_ID`, `source::GENERATED_ID`, `string_interner::EMPTY`. Zero-initialization is a valid index 0 and never a sentinel, so set sentinel fields explicitly (`Location` defaults: use `source::UNUSED_LOCATION`).
- A `Source` (or any record returned by value) may hold slices only into memory whose address never changes until the owner is freed. Growing a container must not invalidate them. Owned bytes are separate heap allocations, never storage inside a `List`'s backing array.

## Allocation
- Every owning struct is set up with `init(&self, Allocator a, ...)` and stores the allocator. Its methods do not take an allocator parameter. `free(&self)` releases everything and resets to `{}`, matching stdlib `List.free` (Zig's `deinit`).
- `Compilation.gpa` is the allocator for compilation-owned data. `Compilation.arena` is caller-provided, not owned, and may be null until a ticket needs it.
- Free functions that return new memory take the `Allocator` as their first parameter.
- Always `init` containers explicitly with the owning allocator. Never rely on the implicit temp-allocator initialization of `List`/`HashMap`.
- **Running out of memory panics** (stdlib `alloc::malloc` / `List.push` behaviour). It is not a fault. Zig's `checkAllAllocationFailures` tests become `TrackingAllocator` leak checks (`allocation_count() == 0` after `free`) over repeated create/destroy.
- Zero-terminated buffers are `String buf` with `buf.ptr[buf.len] == 0`, allocated with `len + 1` bytes and freed via `buf.ptr`.
- Borrowed keys: `string_interner::StringTable` (a stand-in for Zig's `StringArrayHashMapUnmanaged`) and `StringInterner` never copy keys. The caller keeps the bytes alive. Do not use stdlib `HashMap{String, _}` where Zig borrows keys, because it copies String keys.

## Porting Zig constructs (plan 06)
- C3 struct fields have no default values. When Zig's `.{}` defaults are not all zero, provide a module constant with them (`lang_opts::DEFAULT`) and start from it.
- Zig `?T` struct fields become `T` plus a `has_*` flag, or a small `Tristate { UNSET, OFF, ON }` for `?bool`.
- Zig functions returning `?[]const u8` return `String?` with a module fault (`tokenizer::NO_LEXEME`), or `""` when the empty string can never be a real value (documented on the function).
- Zig labeled `switch` with `continue :loop .state` maps to `switch LOOP: (State.START)` with `nextcase LOOP: State.X;`.
- Zig `enum(u8)` with explicit tag values: use an associated value, `enum E : char (char value) { A { 1 }, ... }`, and read `e.value`.
- Generated table data is produced by a checked-in script under `tools/` that reads the Zig source (`bazel run //tools/gen_identifier_tables -- --check`), never hand-copied.

## Errors
- Zig error sets map to C3 faults declared with `excuse` in the module that raises them, named in SCREAMING_CASE (`error.FileTooBig` becomes `compilation::FILE_TOO_BIG`). Fallible functions return `T?` and callers propagate with `!`.
- Stage-0 stubs return `aro::UNSUPPORTED~`.
- Misuse that Zig `assert`s on becomes `@require` contracts or `assert`. It is not a fault.
- Zig `error.FatalError` is `compilation::FATAL_ERROR`. Diagnostics go through `Compilation.diagnostics` (a borrowed `Diagnostics*`; `Compilation.init` allocates an IGNORE sink when none is passed).
- Zig optional fields (`?Option`, `?ExpandedLocation`) become a `has_x` flag next to the value (`Message.has_opt` / `opt`).
- Every Zig `Diagnostic` table (Parser, Preprocessor, Attribute, Compilation, literals, pragmas, linker) is a group of entries in the single `enum Diagnostic : ushort (String fmt, MessageKind kind, DiagMeta meta, DiagnosticType type)` in `src/frontend/c/diagnostics.c3` (module `aro::frontend::c::diagnostics`). `type` names the group; entries are grouped by type in Zig order. A diagnostic shared by several tables with identical text/options appears once (first group wins); a name clash with different text gets a group prefix (`PP_OVERFLOW`). Never add a per-module mirror enum: pass `Diagnostic` values across module boundaries (e.g. `NumberValueDiags`), or emit with `Diagnostic.@emit` on the owning Parser (SymbolStack does). `fmt` is C3 printf syntax: Zig `{s}` and the type/token/value placeholders become `%s` (pass a Printable wrapper such as `Parser.fmt_qt` / `fmt_value` or `text_literal::Ascii`), `{d}` becomes `%d`. `meta` is `diagnostics::DiagMeta`, including the Parser suppress-version fields (zero = none); `Diagnostic.should_emit`/`emit` apply them.
- Emit parser diagnostics with `Diagnostic.X.@emit(p, tok, args...)` (a compile-time-receiver macro in src/frontend/c/diagnostics.c3; `p` is any `parser::IQueryable`, i.e. the Parser), or `@emit_at(p, loc, expansion_locs, args...)` for an explicit location. Other families use their macro (`Preprocessor.err`/`err_raw`/`err_loc`, `Wip.emit`, `LiteralSite.err`, `TextLiteralParser.err`). Every macro passes `$diag.fmt` to `string::tformat`, whose `@format` makes c3c check argument count and types at each call site. Never hand-write message text: if the text differs, the args or the enum entry are wrong. There is no runtime-diagnostic emitter: when the diagnostic depends on runtime state, branch (`if`/`switch`) over constant `@emit` calls, or pass a `$diag` body parameter (see `NumberDiags.@each`). `Diagnostic.report`/`report_at` are the internal sinks under the macros. Build a `Message` from any diagnostic with `diagnostics::@message(diag, text)` / `@message_at(diag, text, loc)`; `Diagnostics.@enabled(diag)` is the OFF check; `Diagnostic.enabled(q)` adds the extension/version gates.
- Free-form printf diagnostics (`add_driver_error`, `Toolchain.err`, ...) carry `@format(n)` so their callers are checked the same way.
- The expression grammar is plain `Parser` methods in `module aro::frontend::c::parser`, split across parser_expression.c3 (`parse_expr_prec`), parser_postfix.c3 (`parse_postfix_expr`) and parser_primary.c3 (`parse_primary_expr`); no seam structs or interfaces between them. Tests drive it with real tokens and seeded symbols (`Parser.define_symbol`), not fake productions.
- Remaining grammar seams are C3 interfaces, not `void* ctx` + fn-pointer structs: `IParserHandler` (declarations, type names, builtin calls, statement-expression bodies), `IExpressionGrammar`, `pragma::IPragma`. Methods are `@optional` where a production may be missing; a missing method or a `parser::HOOK_ABSENT` fault means "unavailable". Implementers mark methods `@dynamic`.
- Grammar helper structs take `parser::Parser* p` as a method parameter instead of caching it in a field (e.g. `StatementParser.parse_statement(p)`): a cached pointer has to be re-synced at every entry point and goes stale silently.
- Interfaces that exist only so tests can hook into code are named `I*TestProbe` and compiled out of release builds: declare the interface and its holder field `@feat(TESTING)` (top-level `@if` is deprecated), and wrap each dispatch in `$if env::TESTING: ... $endif`. Never make a production type implement a probe interface (a struct's interface list can't be feature-gated) and never switch a field's type with an `@feat(TESTING)`/`@feat(!TESTING)` alias pair. Instead the holder keeps a concrete pointer to the production type (static release calls) plus an `I*TestProbe probe @feat(TESTING)` field that each dispatch checks first, so the interface is compiled out entirely. Examples: `pack::TreeParserAdapter.probe`, `parser_statement::StatementParser.local_declaration_probe`. A probe that substitutes a production on Parser itself is a `@feat(TESTING)` field checked before the real call, e.g. `Parser.initializer_test_probe`. Example: `parser_declaration::IDeclarationTestProbe` (DeclarationParser grammar overrides; an installed probe replaces the implicit typedef prelude).
- Per-member facts of an enum are associated values (`TokenId` spelling/category/`TokenProps`, `TypeInt`/`TypeFloat` index/name/width/rank, the diagnostic enums), not `switch` tables. When converting one, dump every member's old method results and diff against the new ones.

## Compiler setup and validation status

- `.bazelversion` pins Bazel 9.1.0. `tools/c3c_repo.bzl` records the observed C3 0.8.6 pre-release candidate and resolves the host compiler from `C3C` or `PATH`; set `C3C=/absolute/path/to/c3/install/c3c` explicitly for reproducible local invocations. The repository rule is local and non-hermetic: both `c3c` and its adjacent `lib/std` come from that installation.
- The inspected host compiler reports C3 0.8.6 pre-release, Git `61d33ae1dce61f80dd81660db2f9910208c74284`, LLVM 22.1.8. SHA-256 of that local `c3c` executable: `d8d3274a371d16162d27a02a1fe16f190cb713fea573f9efa3e7efb91a59be09`. This is not a checksum for a complete distribution or standard library and does not identify a portable install artifact.
- This compiler is an observed candidate, not yet a validated supported version. The retained Bazel attempts executed no tests: server startup failed in Netty (`channel not registered to an event loop`), and batch startup with writable isolated output roots failed in `NetworkMetricsCollector` because `loopbackInterfaceNames` was null. Disabling `--experimental_collect_system_network_usage` for Bazel 9.1.0 batch invocations passed those startup failures but registry mapping then failed with `Operation not permitted` at `https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/modules/rules_python/1.7.0/MODULE.bazel` (clean-cache fetch), `https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/modules/rules_java/9.1.0/MODULE.bazel` (dbg), and `https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/modules/rules_license/1.0.0/MODULE.bazel` (opt). Earlier reports separately name `platforms` 1.0.0, but do not retain its complete leaf URL. A separate later compilation attempt reported parser syntax errors before any tests. Treat these as distinct startup, dependency-fetch, and source-compilation failures. Direct compiler runs do not count as Bazel tests.
- For revalidation, put Bazel startup options before the Bazel command and keep the compiler override explicit, for example:

  ```sh
  C3C=/absolute/path/to/c3/install/c3c bazel --batch --output_user_root=/path/to/writable/bazel-root fetch --experimental_collect_system_network_usage=false //:aro_c3 //test/unit/...
  C3C=/absolute/path/to/c3/install/c3c bazel --batch --output_user_root=/path/to/writable/bazel-root build --experimental_collect_system_network_usage=false -c dbg //:aro_c3
  C3C=/absolute/path/to/c3/install/c3c bazel --batch --output_user_root=/path/to/writable/bazel-root test --experimental_collect_system_network_usage=false -c dbg //test/unit/driver:build_smoke
  ```

  Repeat the build and test commands with `-c opt`, then run the complete registered C3 unit target list in both modes. A clean-cache fetch must succeed before reporting green validation. The configured BCR base is `https://raw.githubusercontent.com/bazelbuild/bazel-central-registry/main/`. The Linux CI route builds C3 from pinned commit `61d33ae1dce61f80dd81660db2f9910208c74284` with CMake/`C3_FETCH_LLVM=ON`, asserts the compiler-reported Git hash, and places its `lib/` beside `c3c`; CI logs a checksum for the resulting binary. This makes source provisioning repeatable, while support remains unselected until clean-cache debug/optimized builds and tests succeed. No clean-cache resolution has passed in the inspected environment.

## Historical notes: known c3c 0.8.5 issues

The following issues were observed against the earlier c3c 0.8.5 compiler. Recheck any issue that affects new code against the selected compiler; these observations do not establish that 0.8.5 is currently supported or that the 0.8.6 pre-release is compatible.
- Earlier conventions recorded `List.len()` and slice `.len` as `sz` (signed) under c3c 0.8.5. Keep this as baseline metadata until the selected compiler's behavior is verified by the debug and optimized Bazel runs.
- Comparing a bitstruct field of a module-level constant struct (`source::UNUSED_LOCATION.id == x`) crashes the compiler. Copy the constant to a local first.
- `test::eq(uint_value, 3)` is rejected (int vs uint). Tests use a local `check` macro that compares integers as `long`.
- `@private` on methods is ignored and produces a warning, so don't use it.
- Empty fall-through `case` lists must not contain blank or comment-only lines (compile error); put comments at the end of a `case` line.
- `uint.max` does not exist; write the literal (`0xFFFF_FFFF`).
- A `char[]` slice (e.g. of a `char[N]` buffer) does not convert implicitly to `String`; take `char[]` or cast.
- In `assert(a <= b + 1)` mixing `usz` and `uint`, c3c demands an explicit widening cast.
- `void?` is not allowed as a variable type. Capture the fault with `fault f = @catch(call());`.
- An enum's value count is `Enum::len` and its values `Enum::values`; `Enum.len` does not compile.
- Functions and globals from other modules need their module prefix (`diagnostics::warning_exists`, `diagnostics::@message`). Types and enum values do not.
- `int`, `float` (and other type names) cannot be struct/union member names. Interner keys sidestep this: numeric keys are flat (`primitive_value::PrimitiveType.INT_POSITIVE`/`INT_NEGATIVE`, `F16`..`F128`, `CF16`..`CF128`) with ints in `PrimitiveValue.limbs` (`int_key` puts limbs in `tmem`) and floats/complexes inline in `fbits`/`cbits` (no allocation).
- A `<* @return? A, B *>` contract is enforced: a stub returning `aro::UNSUPPORTED~` from such a function does not compile. Stage-0 stubs of functions with declared faults, or with no fault at all (Zig `!T` where the only error is OOM), use `unreachable("stage 0 stub")`.
- Two modules may not both export a type with the same name if a third imports both (`type_store::Order` exists, so bigint's `std.math.Order` is `BigIntOrder`).
- `DString.str_view().ptr` is not the start of the allocation, so freeing it leaks or crashes. Return `copy_str(a)` and `free()` the DString.
- `int.min` / `long.min` don't compile; write `int::min` / `long::min`.
- `@local` on methods is ignored with a warning, like `@private`.
- `any` is a type and can't be a variable name.
- A `{...}` slice literal can't be returned from a function; use a module-level `const`.
- Integer limits are `long::min`, `ulong::max`, `usz::max`, and the byte size is `usz::size`; `long.min` and `usz.sizeof` do not compile.
- Integer literal suffixes such as `1u64` are rejected ("not a valid literal"). Write `(ulong)1 << 40`; plain `1 << 40` is an `int` shift and is a compile error.
- `if (catch x = f())` declares a new `x`; it cannot assign to an existing variable (shadowing error). Assign to a `T?` local first, then `if (catch tmp)`.
- Two doc-comment blocks (`<* ... *>`) in a row on one declaration are a compile error; merge them.
- `Enum.from_ordinal(i)` does not exist; use `Enum::values[i]`.
- `@clz` / `@ctz` need compile-time constants; at run time use the methods `x.clz()` / `x.ctz()` (they work on `uint128`).
- A type name needs a lowercase letter: `struct A` is parsed as a constant (`Abc` works).
- `float128` literals are folded at double precision (`(float128)0.1` is the widened double); build f128 constants from bits.
- Modules may import each other cyclically, and a module may add methods to another module's type (`fn PrimitiveValue.hash(...)` in `aro::value_interner`); callers must import the defining module.
- Constant layering: `aro::primitive_value` (`primitive_value.c3`, `primitive_float.c3`, `float_*.c3`) is pure code on `PrimitiveValue` bits and never mentions `Value`, `Compilation` or `QualType`; `aro::value_interner` is storage only (refs, `hash`/`eql`, `put`/`get`); anything taking a `Value` and a `Compilation*` lives in `aro::frontend::c::value` (`value.c3`, floats in `value_float.c3`). Build keys with `primitive_value::int_key`/`float_key`/`complex_key`.
- A doc-comment (`<* ... *>`) line that starts with `@name(` is parsed as a custom contract ("Expected a string description"); start such lines with a word (`Zig @round(...)`).
- `uint128 * (ulong_a - 1)` is rejected ("widening ... done in more than one way"); cast the subtraction: `(uint128)(a - 1)`.
- A compound `float16` expression (`a * c + b * d`) is evaluated in `float` and rounded to half only at the end; Zig rounds after every operation. Round each step (assign or return through a `float16` function).
- Small-int arithmetic is promoted to `int`: `(ushort_val << 1) >> 11` keeps the shifted-out bit. Cast back (`(ushort)(x << 1)`) where Zig's fixed-width wrap matters.
- c3c (0.8.5–0.8.7) lowers a union to its first largest member's LLVM type, and `cond ? x : y` on an aggregate is a by-value load/phi/store. At -O0 that copies field by field and drops the representative member's padding bytes, so with the old `F80Bits {ulong, ushort}` as `KeyFloat`'s/`KeyComplex`'s union rep the upper `f128`/`cf128` bytes came back as garbage (c3c repro: `test/unit/regression/ternary.c3`, `ternary_union_with_padded_rep`). `F80Bits`/`F128Bits`/`FloatBits` are now padding-free `uint128` bitstructs, which avoids it; the existing `if`/`else` rewrites are kept. Don't put a padded struct in a union that is copied by value.
- A conditional `c ? 1 : 0` is an `int` and does not convert implicitly to `uint128` in arithmetic (`x + (c ? 1 : 0)`); assign it to a `uint128` local first.
- A module name may be at most 31 characters (`module text_literal_semantics_manual_tests;` is rejected); shorten test module names.
- An enum value's name: `e.nameof` does not compile; format it with `string::tformat("%s", e)` (or `io::printf`).
- Constants of a `typedef`'d integer type need an explicit cast (`const Precedence P = (Precedence)1;`).
- `if (c) a; else b;` without braces is a compile error when there is an `else`.
- `union` and `macro` are keywords, so they cannot be method or parameter names (Zig `Hideset.union` is `union_of`).
- `HashMap{K, V}` rejects a `typedef`'d integer key ("No .hash function found on the key"); key by the underlying integer (`HashMap{uint, V}` with `(uint)node`).
- `aro::frontend::c::tokens` and `aro::frontend::c::type_store` both export `TokenIndex`; a module importing both must write `tokens::TokenIndex` (ambiguity error otherwise).
- The variable of `if (catch f = x) { ... } else { ... }` is still in scope in the `else` branch, so a nested `catch f` there is a shadowing error; use another name.
- Imports at the top of a test file do not carry into a later `module X @test;` section; repeat the imports.
