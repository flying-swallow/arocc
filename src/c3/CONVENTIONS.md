# C3 port conventions

Shared rules for every module under `src/c3/`. Established by plan 04 (source, string_interner, compilation); follow them unless a plan says otherwise.

## Modules and files
- One Zig file maps to one C3 file and one submodule: `src/aro/Foo.zig` becomes `src/c3/foo.c3` with `module aro::foo;`. The root module `aro` (`aro.c3`) holds only crate-wide items.
- A large Zig file may be split over several C3 files that all declare the same module (`aro::target` is target.c3/target_cpu.c3/target_data.c3; `aro::type_store` is type_store*.c3 plus type_print.c3). Each file lists its own imports.
- Every file is listed explicitly in `//:aro_c3_lib` (root `BUILD.bazel`). Tests go in `test/c3/<name>_tests.c3` and are registered as `c3_test` in `test/c3/BUILD.bazel`.
- Test files use `module <name>_tests;` and mark each test `fn void x() @test`. Helpers that take parameters must not be inside a `@test` module section, because c3c rejects them there.

## Naming
- Types use PascalCase. Zig's nested types are flattened with the parent's name as a prefix where needed to stay unambiguous: `Source.Id` becomes `SourceId`, `Source.Kind` becomes `SourceKind` and `StringInterner.StringId` becomes `StringId`. Types that are already distinctive (`Location`, `ExpandedLocation`) keep their names.
- Functions and methods are snake_case ports of the Zig names (`addSourceFromBuffer` becomes `add_source_from_buffer`). Methods take `&self`, or `self` for small values.
- Enum values and constants are SCREAMING_CASE (`SourceKind.USER`, `source::UNUSED_ID`).
- `alias` is a C3 keyword. Use `is_alias` / `al` instead.
- Sizes and indices from the stdlib are `sz` (signed) in c3c 0.8.5 (`List.len()`, slice `.len`). Stored IDs and offsets keep Zig's widths (`uint` for u32).

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
- Generated table data is produced by a checked-in script under `tools/` that reads the Zig source (`tools/gen_identifier_tables.py`, with `--check`), never hand-copied.

## Errors
- Zig error sets map to C3 faults declared with `excuse` in the module that raises them, named in SCREAMING_CASE (`error.FileTooBig` becomes `compilation::FILE_TOO_BIG`). Fallible functions return `T?` and callers propagate with `!`.
- Stage-0 stubs return `aro::UNSUPPORTED~`.
- Misuse that Zig `assert`s on becomes `@require` contracts or `assert`. It is not a fault.
- Zig `error.FatalError` is `compilation::FATAL_ERROR`. Diagnostics go through `Compilation.diagnostics` (a borrowed `Diagnostics*`; `Compilation.init` allocates an IGNORE sink when none is passed).
- Zig optional fields (`?Option`, `?ExpandedLocation`) become a `has_x` flag next to the value (`Message.has_opt` / `opt`).
- Zig `Diagnostic` constants (`fmt`, `kind`, `opt`, `extension`) become `diagnostics::DiagnosticTemplate` constants in the caller's module, named `DIAG_<ZIG_NAME>` so they do not clash with `Option` values. Format them with `diagnostics::format_args` / `template_index`; build messages with `.message(text)` / `.message_at(text, loc)`.

## Known c3c 0.8.5 issues
- Comparing a bitstruct field of a module-level constant struct (`source::UNUSED_LOCATION.id == x`) crashes the compiler. Copy the constant to a local first.
- `test::eq(uint_value, 3)` is rejected (int vs uint). Tests use a local `check` macro that compares integers as `long`.
- `@private` on methods is ignored and produces a warning, so don't use it.
- Empty fall-through `case` lists must not contain blank or comment-only lines (compile error); put comments at the end of a `case` line.
- `uint.max` does not exist; write the literal (`0xFFFF_FFFF`).
- A `char[]` slice (e.g. of a `char[N]` buffer) does not convert implicitly to `String`; take `char[]` or cast.
- In `assert(a <= b + 1)` mixing `usz` and `uint`, c3c demands an explicit widening cast.
- `void?` is not allowed as a variable type. Capture the fault with `fault f = @catch(call());`.
- An enum's value count is `Enum::len` and its values `Enum::values`; `Enum.len` does not compile.
- Functions and globals from other modules need their module prefix (`diagnostics::warning_exists`, `compilation::DIAG_CTRL_Z_EOF`). Types and enum values do not.
- `int`, `float` (and other type names) cannot be struct/union member names; Zig `Key.int`/`.float`/`.complex` became `int_val`/`float_val`/`complex_val`.
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
- Modules may import each other cyclically, and a module may add methods to another module's type (`fn KeyFloat.add(...)` in `aro::float_value`); callers must import the defining module.
- A doc-comment (`<* ... *>`) line that starts with `@name(` is parsed as a custom contract ("Expected a string description"); start such lines with a word (`Zig @round(...)`).
- `uint128 * (ulong_a - 1)` is rejected ("widening ... done in more than one way"); cast the subtraction: `(uint128)(a - 1)`.
- A compound `float16` expression (`a * c + b * d`) is evaluated in `float` and rounded to half only at the end; Zig rounds after every operation. Round each step (assign or return through a `float16` function).
- Small-int arithmetic is promoted to `int`: `(ushort_val << 1) >> 11` keeps the shifted-out bit. Cast back (`(ushort)(x << 1)`) where Zig's fixed-width wrap matters.
- Observed (not minimised): `KeyComplex r = cond ? annex_g::complex_float_mul(..) : annex_g::complex_float_div(..);` lost `r.cf64[1]` at -O0; an `if`/`else` assignment works.
- `cond ? x : y` on a struct holding an anonymous union (`KeyFloat`) is miscompiled at -O0: the result's upper union bytes are garbage (f128 `hi`). Use `if` + separate `return`/assignment; a ternary on the union member type itself (`F128Bits`) works.
- A conditional `c ? 1 : 0` is an `int` and does not convert implicitly to `uint128` in arithmetic (`x + (c ? 1 : 0)`); assign it to a `uint128` local first.
- A module name may be at most 31 characters (`module text_literal_semantics_manual_tests;` is rejected); shorten test module names.
- An enum value's name: `e.nameof` does not compile; format it with `string::tformat("%s", e)` (or `io::printf`).
- Constants of a `typedef`'d integer type need an explicit cast (`const Precedence P = (Precedence)1;`).
- `if (c) a; else b;` without braces is a compile error when there is an `else`.
- `union` and `macro` are keywords, so they cannot be method or parameter names (Zig `Hideset.union` is `union_of`).
- `HashMap{K, V}` rejects a `typedef`'d integer key ("No .hash function found on the key"); key by the underlying integer (`HashMap{uint, V}` with `(uint)node`).
- `aro::tokens` and `aro::type_store` both export `TokenIndex`; a module importing both must write `tokens::TokenIndex` (ambiguity error otherwise).
- The variable of `if (catch f = x) { ... } else { ... }` is still in scope in the `else` branch, so a nested `catch f` there is a shadowing error; use another name.
