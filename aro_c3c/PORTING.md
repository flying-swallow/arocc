# Porting c3c into `aro_c3c/src`

The C3 frontend is a port of c3c (reference revision
`54bab366a`, see `c3.c3`). It lowers to `aro::backend::ir`; codegen follows
the design of c3c's C backend (`src/compiler/c_codegen*.c`).

## Isolation

Nothing here may reference `aro::frontend::c::*` or `aro::api`
(`//aro_cc/test/unit/c3:isolation_test`). Allowed shared modules: `aro::backend::*`,
`aro::target`, `aro::bigint`, `aro::value_interner`, `aro::primitive_value`,
`aro::string_interner`, `aro::source`, `aro::terminal`, `aro::utf8`, std.

## Modules

- `aro::frontend::c3::tokens`, `::lexer`, `::symtab`, `::diagnostics`: small
  standalone modules (done).
- `aro::frontend::c3::compiler`: everything else (AST, parser, sema,
  codegen). One module, like c3c's single C namespace, so ported code calls
  helpers without module prefixes. Files mirror c3c files: `ast.c3`
  (compiler_internal.h types), `ast_enums.c3` (enums.h), `ast_helpers.c3`
  (ast.c + Ast/Decl/TypeInfo inline helpers, `poisoned_*`), `expr.c3`
  (expr.c subset + Expr inline helpers), `types.c3` (types.c + Type inline
  helpers), `bigint.c3`, `float.c3`, `stringutils.c3` (utils/stringutils.c,
  scratch buffer), `tables.c3` (STable/HTable/PathTable/DeclTable),
  `symtab_globals.c3` (symtab_init, `kw_*`, `attribute_list`, ...),
  `context.c3` (context.c + module.c), `compiler.c3` (CompilerState
  `compiler`, `global_symtab`, `global_diagnostics`, `compiler_reset()`),
  `diagnostics_inline.c3` (diagnostics.c), `parser.c3` (parser.c +
  parser_internal.h inlines), `parse_expr.c3`, `parse_stmt.c3`,
  `parse_global.c3`, ...
- Each file's header comment lists what is not ported yet and its deviations.

## Style (decided with the user)

- **Port mechanically.** Same function names (snake_case is already c3c's
  style), same control flow, same comments where useful. Keep one c3c
  function per C3 function so the two can be diffed.
- **Globals like c3c.** c3c's global state (`compiler`, arenas, symtab
  `kw_*`, builtin `type_*` pointers, `poisoned_*`) are module-level globals.
  Provide reset functions for tests.
- **Inline, format-checked diagnostics.** Keep c3c's message text at the call
  site, verbatim (c3c test files match on it). Use the macros in
  `diagnostics_inline.c3` (`@print_error_at(loc, "fmt", ...)` etc.), which
  check arguments with `@format` at compile time. C `%s` on a `const char*`
  becomes `%s` on a `String`; `%d`/`%u`/`%llu` become `%d`; `%c` stays.

## Mechanical translation rules

| C (c3c) | C3 port |
|---|---|
| `Decl **v` vector, `vec_add(v, x)`, `vec_size(v)`, `FOREACH(T, x, v)` | `Decl*[] v`, `@vec_add(&v, x)`, `v.len`, `foreach (x : v)` |
| `const char *name` | `String name` (interned/arena copies keep a trailing NUL) |
| `NULL` | `null`; an empty `String` is `""`/`{}` (check `.len`, or `.ptr == null` where c3c tests for NULL) |
| `AST_IF_STMT`, `EXPR_CALL`, `DECL_VAR`, `TYPE_I32`, `TOKEN_IDENT` | `AstKind.IF_STMT` / `IF_STMT` (inferred), `ExprKind.CALL`, `DeclKind.VAR`, `TypeKind.I32`, `TokenType.IDENT` |
| enum range markers (`TYPE_INTEGER_FIRST`) and flag enums (`ATTR_FUNC`, `SCOPE_MACRO`) | module constants with the C name (`TYPE_INTEGER_FIRST`, `ATTR_FUNC`) |
| `SourceLoc` | `SourceLoc` (alias of `tokens::SourceSpan`) |
| `File`, `Path`, `Range` | `SourceFile`, `ModulePath`, `ExprRange` |
| keyword-named fields | see the header of `ast.c3` (`var` -> `var_decl`, `alias` -> `alias_decl`, `defer` -> `defer_id`, `import` -> `import_decl`, `module` -> `module_name`/`mod`, `macro` -> `macro_decl`, `fault` -> `fault_val`, `typeid` -> `typeid_type`/`typeid_expr`) |
| `UNREACHABLE` | `unreachable()` |
| `ASSERT(x)` | `assert(x)` |
| `INLINE`/`static inline` | plain `fn` |
| C `switch` fallthrough | C3 cases do not fall through: use empty `case A:` lists or `nextcase` |
| `goto` | restructure (flag, loop + `break`, helper fn, `nextcase`) |
| `bool x : 1` bit-fields | plain fields |
| `Int128` math (`i128_add64` ...) | `uint128` arithmetic |

## Parser porting cheat sheet

- Reporting (diagnostics_inline.c3 header has the full table):
  `PRINT_ERROR_HERE(...)` -> `@print_error_here(c, ...)`,
  `RETURN_PRINT_ERROR_HERE(...)` -> `return @print_error_here(c, ...);`,
  `PRINT_ERROR_AT(node, ...)` -> `@print_error_at(node.loc, ...)`,
  `RETURN_PRINT_ERROR_AT(v, node, ...)` -> `{ @print_error_at(node.loc, ...); return v; }`,
  `PRINT_ERROR_LAST` -> `@print_error_last(c, ...)`,
  `print_error_after(&c->prev_span, ...)` -> `@print_error_after(&c.prev_span, ...)`,
  `SEMA_NOTE(node, ...)` -> `@sema_note_prev_at(node.loc, ...)`,
  `SEMA_ERROR(node, ...)` -> `@sema_error_at(context, node.loc, ...)`,
  `consume(c, tok, msg)` -> `@consume(c, tok, msg)`.
  The error macros return `false`.
- Returning macros (parser.c3 header): `CONSUME_OR_RET(t, r)` ->
  `if (!expect_advance(c, t)) return r;`, `CONSUME_EOS_OR_RET(r)` ->
  `if (!consume_eos(c)) return r;`, `EXPECT_OR_RET(t, r)` ->
  `if (!expect(c, t)) return r;`, `ASSIGN_EXPR_OR_RET(x, e, r)` ->
  `Expr* tmp = e; if (!expr_ok(tmp)) return r; x = tmp;` (same for AST, TYPE,
  DECL, *ID), `RANGE_EXTEND_PREV(x)` -> `range_extend_prev(c, x.loc);`,
  `EXPR_NEW_TOKEN(k)` -> `expr_new_token(c, k)`, `NEW_AST_TOKEN(k)` ->
  `new_ast_token(c, k)`.
- Token data: `c->data.lex_start` / `lex_len` -> `c.data.lex.ptr` /
  `c.data.lex.len`; `c->data.strlen` -> `c.data.string.len`;
  `symstr(c)` is a String.
- Case groups from enums.h: `TYPE_TOKENS` -> `case VOID..UNTYPEDLIST:`,
  `NON_VOID_TYPE_TOKENS` -> `case BOOL..UNTYPEDLIST:`, `CT_TYPE_TOKENS` ->
  `case CT_TYPE_IDENT: case CT_TYPEOF: case CT_TYPEFROM:`, `TYPELIKE_TOKENS` ->
  `TYPE_TOKENS` + `TYPE_IDENT` + `CT_TYPE_TOKENS`; `ALL_INTS`, `ALL_FLOATS`,
  `VECTORS` etc. are spelled out (see types.c3).
- `i128_*` arithmetic is uint128 math on `Int.i`; `(Int128){ 0, x }` is `x`.
- Interned names compare by pointer like c3c (`a.ptr == b.ptr`); HTable keys
  are `name.ptr`; a C NULL `const char*` is a String with `ptr == null`.
- Locals/params named after C3 keywords get a `_` suffix (`alias_`, `var_`,
  `fault_`) or a short name (`import` -> `imp`).
- Global state: `compiler.context.errors_found` etc. (CompilerState
  `compiler`), interning via `symtab_add(String, TokenType*)`.

## C3 quirks to remember (c3c 0.8.7 here)

- C3 keywords cannot be identifiers or field names: `var`, `alias`, `defer`,
  `import`, `module`, `macro`, `fault`, `typeid`, `any`, `fn`, `int`, ...
- Use `$Typeof(x)` and `T::size` (not `$typeof`/`.sizeof`).
- Allocation is `alloc::malloc(a, (sz)n)` / `alloc::free(a, p)`; sizes are
  `sz` (signed), so cast `usz` explicitly.
- No implicit int->bool in conditions for chars? Prefer explicit `!= 0`.
- A doc comment (`<* ... *>`) must not contain `*>` or start a line with
  `@word(`.
- Functions/globals from other modules need a module prefix; types and enum
  values do not. Inside `aro::frontend::c3::compiler` no prefix is needed.
- Type names may not be all caps (`ABI` -> `Abi`), and type keywords
  (`int128`, `float16`, `usz`, `typeid`, `any`, ...) cannot be member names.
- `foreach (i, x : slice)` gives a signed `sz` index; enum counts are
  `Enum::len`, values `Enum::values[i]`; arrays index enums by `.ordinal`.
- Test files: helpers go in a plain `module x;` section, tests in a
  following `module x @test;` section (with the imports repeated).
- More quirks: `src/CONVENTIONS.md` (bottom section).

## Testing

- Unit tests: `aro_cc/test/unit/c3/<area>/<name>_tests.c3`, `c3_test` with
  `deps = ["//:aro_c3_frontend_lib"]`, plus the area's `test_suite(name="all")`
  and an entry in `//aro_cc/test/unit/c3:all`.
- Every new source file must be listed in `//:aro_c3_frontend_lib`
  (root `BUILD.bazel`).
- Do not run `bazel test //...`; run `bazel test //aro_cc/test/unit/c3:all`.
- Differential checks against real c3c (`~/projects/c3c/build/c3c`): lexer
  `aro_cc/test/src/c3/lex_diff.sh`; parser: `-P` (parse only) once `parse_probe`
  exists; sema: `aro_cc/test/src/c3/sema_diff.py` (`KINDS=c3,c3t`, `STDLIB=1`,
  `PROBE=<check_probe copy>`; .c3t files are split per `// #file:` and run
  with their `// #target:`).
- Targets: `compiler_reset(ArchOsTarget)` runs `target_setup` (default
  linux-x64, c3c's host default); `check_probe --target <name>`.

## Sema contract

The sema milestone is ported file-by-file in parallel. Every c3c function a
sema file defines already exists in the C3 file that mirrors it, with its
final signature and the body `unreachable("sema stub: <name>");`, in c3c
order, preceded by `// <c3c file>:<line>` (`(static)` marks C statics).
Port a body **in place** (keep the order, drop the stub line); do not move
functions between files, so cross-file calls keep compiling.

### Ownership map

| c3c file | C3 file | stubs |
|---|---|---|
| sema_expr.c | sema_expr.c3 | 250 |
| sema_decls.c | sema_decls.c3 | 96 |
| sema_stmts.c | sema_stmts.c3 | 67 |
| sema_casts.c | sema_casts.c3 | 122 |
| sema_types.c | sema_types.c3 | 21 |
| sema_const.c | sema_const.c3 | 9 |
| sema_builtins.c | sema_builtins.c3 | 20 |
| sema_initializers.c | sema_initializers.c3 | 36 |
| sema_name_resolution.c | sema_name_resolution.c3 | 56 |
| sema_generics.c | sema_generics.c3 | 6 |
| sema_passes.c | sema_passes.c3 | 32 (ported) |
| semantic_analyser.c | semantic_analyser.c3 | 32 (ported) |
| sema_liveness.c | sema_liveness.c3 | 19 |
| sema_static_analysis.c | sema_static_analysis.c3 | 33 |
| sema_asm.c (+ asm_target.c) | sema_asm.c3, asm_target.c3 | 20 + 5 |
| sema_errors.c | sema_errors.c3 | 1 (`sema_shadow_error` lives in diagnostics_inline.c3) |
| copying.c | copying.c3 | 45 (ported, incl. `copy_type_info_single` / `copy_attributes_single`) |
| number.c | number.c3 | 14 (ported) |
| methodtable.c | methodtable.c3 | 5 (ported) |
| abi/c_abi.c | c_abi.c3 | 26 |
| abi/c_abi_x64.c | c_abi_x64.c3 | 24 |
| abi/c_abi_{win64,x86,aarch64,riscv,wasm}.c | c_abi_{win64,x86,aarch64,riscv,wasm}.c3 | 0 (ported) |
| codegen_internal.h / c_abi_internal.h / codegen_general.c (ABI subset) | codegen_internal.c3 | 0 (ported) |
| types.c (rest) | types.c3 (merged) | 0 (ported) |
| expr.c (rest) | expr.c3 (merged) | 0 (ported) |
| bigint.c (rest) | bigint.c3 (merged) | 0 (ported) |
| symtab.c (rest) | symtab_rest.c3 | 0 (ported) |
| context.c (rest) | context.c3 (merged) | 0 (ported) |
| compiler.c (pipeline), source_file.c `source_file_load` | compiler_rest.c3 | 0 (ported) |
| utils (file_utils, time, benchmark, StringSlice, a5hash) | utils_rest.c3 | 0 (ported) |
| float.c, module.c, decltable.c, ast.c | already complete (float.c3, context.c3, tables.c3, ast_helpers.c3) | 0 |
| target.c (+ build_options.c / builder.c target bits) | target.c3 | 0 (ported; LLVM-only parts skipped, see its header) |

`*_rest.c3` files are companions of partially ported files; merge them into
the main file once they are done. Shared contract files, owned by nobody in
particular (append, do not reorder; coordinate changes to existing
declarations): `sema_internal.c3` (sema_internal.h: constants, scope/jump
macro helpers, inline fns), `sema_structs.c3` (SemaContext, CallEnv,
DynamicScope, JumpTarget, NameResolve, CopyStruct, ABIArgInfo / AbiType /
ParamInfo / FunctionPrototype, CompilerStats, PanicVariant, FindMember),
`compiler_inline.c3` (remaining compiler_internal.h inlines + enums.h /
common.h constants), `build_enums.c3` (build/target enums), `compiler.c3`
(BuildTarget / PlatformTarget / GlobalContext / CompilerState now carry
every field the c3c sema files read), `vmem.c3` (`@vec_resize`,
`@vec_insert_at`, `@vec_insert_first`, `@veclast` added).
File-local c3c types (CastContext, CalledDeclContext, SubscriptLookup,
SAContext, BuiltinArg, FuncMap, X64Class, MainSubType, ...) are declared at
the top of their file; file-local static tables (`cast_rules`,
`OVERLOAD_NAME`, ...) are ported with their file. `swizzle` (used across
files) is already ported in semantic_analyser.c3.

### Renames

| c3c | C3 | why |
|---|---|---|
| sema_builtins.c `static sema_expr_analyse_swizzle` | `sema_builtins_sema_expr_analyse_swizzle` | clashes with the sema_expr.c static of the same name |
| `sema_error_at` / `sema_warn_at` (semantic_analyser.c) | `@sema_error_at` / `@sema_warn_at` (diagnostics_inline.c3) | format-checked macros, not stubbed |
| `JumpTarget.defer` | `JumpTarget.defer_id` | `defer` is a keyword |
| `CalledDeclContext.macro` | `.macro_decl` | `macro` is a keyword |
| params named after keywords (`module`, `interface`, `var`, `alias`, `macro`, `typeid`) | `<name>_` | keyword |
| params of unnamed C prototypes | `arg<i>` | |

### Signature mapping

- `T **v` parameter: a slice `T*[]`, except out/iterator pointers, kept as
  `T**`: names ending in `_ref` / `_ptr` and `curr`, `end`, `current`,
  `ambiguous`, `matches`, `state`, `type`, `parent`, `asserts`.
  `T ***x` is `T*[]*`. A `T **` return is a slice, except
  `sema_decl_stack_store` (`Decl**`, a stack pointer).
- `const char *` / `char *` -> `String`; `const char **x_ref` -> `String*`,
  `const char **v` -> `String[]`; `Int128` -> `uint128`; `File` /
  `Path` / `Range` -> `SourceFile` / `ModulePath` / `ExprRange`;
  `CanonicalType` / `FlatType` / `LoweredType` are aliases of `Type`;
  `StringSlice` is `String`; fixed-width ints map to C3 ints
  (`uint32_t` -> `uint`, `size_t` -> `usz`, ...).
- C varargs: `type_func_match(..., Type*... arg_types)`,
  `clobbers_make(int, int...)` (a `-1` terminator is accepted, not needed).
- Callbacks: `CastRule`, `CastFunction` (sema_casts.c3), `DeclAppendFn`
  (types.c3) are `fn` aliases.
- `CopyStruct.fixups` is a slice (allocate MAX_FIXUPS on first use) instead
  of a 16 MB inline array. `AbiType.abi_type` overlays the low bits of
  `type` like c3c (little-endian).

### Macro mapping (sema_internal.h)

See the header of sema_internal.c3: `SCOPE_START` ->
`DynamicScope old_scope = scope_start(context, loc);`, `SCOPE_END` ->
`success = scope_end(context, old_scope, success);`, `PUSH_BREAK` ->
`JumpTarget old_break = push_break(context, ast);` ... `CHECK_ON_DEFINED(r)`
-> `if (r) { *r = true; return false; }`, `IS_OPTIONAL(x)` ->
`@is_optional(x)`, `VECLAST(v)` -> `@veclast(v)`, `vec_resize` /
`vec_insert_at` / `vec_pop` -> the `@vec_*` macros, `MALLOCS` / `CALLOCS` ->
`calloc_arena(T::size)`, `VECNEW` -> `{}`, `ASSERT_SPAN(n, c)` ->
`assert(c)`, `DEBUG_LOG` dropped, case-group macros (`ALL_INTS`,
`SPECIAL_TYPES` = `case TYPEINFO: case MEMBER: case REFLECTION:`) spelled out.

### Pipeline and stub check

- compiler_rest.c3 ports the check-only path: `compile()` (defines,
  feature flags, after compiler_reset()) -> `compiler_compile()` ->
  `sema_analysis_run()` -> `compiler_parse()`. semantic_analyser.c3 already
  ports the driver (`sema_analysis_run`, `sema_analyze_stage`,
  `sema_analyze_to_stage`, `analyze_generics`, `register_generic_decls`,
  `halt_on_error`, `sema_context_init/destroy`, the ct-stack and
  locals-list helpers); the passes it calls are stubs.
- `build_target_setup_defaults()` sets the c3c `compile` -O0 / strict
  defaults (warnings, safety, limits). compiler_reset() does not call it, so
  parser tests keep their state.
- `exit_compiler` calls `exit_hook` first (check_probe exits there).
- Stub check: `bazel build //aro_cc/test/src/c3:check_probe` compiles every stub;
  `bazel-bin/aro_cc/test/src/c3/check_probe <files>` runs parse + sema
  (`--use-stdlib=no -C`) and currently stops at
  `sema stub: type_func_prototype_init`. Remaining stubs:
  `grep -c 'unreachable("sema stub' src/frontend/c3/*.c3`.

## Assertions

c3c has two kinds: `ASSERT(x)` (utils/common.h) is always on, so port it as
`assert(x)`. Plain C `assert(x)` is compiled out in c3c's normal (Release,
NDEBUG) build, and some of them are actually false at run time (e.g. the
lambda `resolve_status` check in `sema_expr_analyse_lambda`). Port those as a
comment `// c3c: assert(...) -- compiled out in release` instead of a C3
`assert`, so the port behaves like the shipped c3c.

## Vector truthiness

A c3c vector is a pointer: `if (vec)` / `x || vec` tests whether it was ever
allocated, not whether it is non-empty (an emptied or `VECNEW`ed vector is
still non-null). Port such tests as `.ptr` (`.ptr != null`), not `.len`. Only
`vec_size(v)` becomes `.len`. Example: `multiple = current_macro || ct_locals`
in sema_expr_analyse_lambda, where `ct_locals` comes from
`global_context_acquire_locals_list()` (always non-null).
