// Builtin function macros and feature queries (plan 14): src/aro/features.zig
// (hasFeature / hasExtension), Compilation.zig isTarget* queries and
// Preprocessor.zig handleBuiltinMacro, pasteStringsUnsafe,
// reconstructIncludeString and expandFuncMacro's `.macro_param_builtin_func`
// arm.
// OWNER: plan 14.5 `queries`.
//
// Query dispatch contract (builtin_expand_func):
//  - Identifier queries (__has_attribute, __has_declspec_attribute,
//    __has_feature, __has_extension, __has_builtin, __is_target_*),
//    __has_warning, __is_identifier and __has_include(_next) go through
//    Preprocessor.handle_builtin_macro and produce one PP_NUM "0\n"/"1\n".
//  - __has_include / __has_include_next answers come ONLY from
//    pp.files.has_include (FileProvider, plan 15). __has_embed answers come
//    ONLY from pp.files.find_embed with limit 1. Nothing here touches the
//    file system or fabricates an answer; with the default
//    preprocessor::UNSUPPORTED_FILES provider the expansion fails with
//    aro::UNSUPPORTED.
//  - Attribute existence (__has_attribute, __has_declspec_attribute,
//    vendor-qualified __has_c_attribute) goes through attribute_exists,
//    which returns aro::UNSUPPORTED until plan 16's aro::attribute lands
//    (Zig Attribute.Namespaced.fromString != null); the integrator replaces
//    its body.
//  - _Pragma / __pragma: validation (DIAG_PRAGMA_OPERATOR_STRING_LITERAL) is
//    here; the pragma itself (Zig pragmaOperator / msPragmaOperator) is plan
//    15 and returns aro::UNSUPPORTED until then.
//
// Stage 0: signatures only; every body is a stub except attribute_normalize
// and HAS_BUILTIN_SPECIAL_CASES.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics, aro::target;
import aro::lang_opts, aro::builtins;

<* Zig `error.ExpectedStringLiteral` from pasteStringsUnsafe. *>
excuse EXPECTED_STRING_LITERAL;

<* Zig `Macro.Builtin.has_builtin_special_cases`: names __has_builtin accepts under emulate NO/CLANG. *>
const String[*] HAS_BUILTIN_SPECIAL_CASES = {
	"__is_target_arch",
	"__is_target_vendor",
	"__is_target_os",
	"__is_target_environment",
	"__is_target_variant_os",
	"__is_target_variant_environment",
};

<* Zig `Attribute.normalize`: strip one leading and trailing "__" from names of length >= 4. *>
fn String attribute_normalize(String name)
{
	if (name.len >= 4 && name.starts_with("__") && name.ends_with("__")) return name[2 : name.len - 4];
	return name;
}

<* Zig `Attribute.Syntax` values the preprocessor queries. *>
enum AttrQuerySyntax : char
{
	STANDARD,
	GNU,
	DECLSPEC,
}

<*
 Zig `Attribute.Namespaced.fromString(syntax, vendor, name) != null`
 (`vendor` "" means null). Plan 16 provides the attribute tables; until the
 integrator wires them this returns aro::UNSUPPORTED.
 OWNER: 14.5 (body replaced at integration with plan 16).
*>
fn bool? attribute_exists(AttrQuerySyntax syntax, String vendor, String name) => aro::UNSUPPORTED~;

<*
 Zig `features.hasFeature(comp, ext)`: attribute_normalize(ext) looked up in
 the features.zig `list` (assume_nonnull ... attribute_diagnose_if_objc
 true, blocks false, c_thread_safety_attributes/enumerator_attributes/
 nullability* true, c_alignas/c_alignof/c_atomic/c_generic_selections/
 c_static_assert = standard >= C11, c_thread_local = C11 &&
 target.is_tls_supported(), c_attributes/c_fixed_enum = standard >= C23,
 bounds_attributes = bounds_safety == CLANG); unknown -> false.
 OWNER: 14.5.
*>
fn bool has_feature(Compilation* comp, String ext_raw)
{
	unreachable("stage 0 stub");
}

<*
 Zig `features.hasExtension`: has_feature first; false if
 diagnostics.state.extensions is ERROR or FATAL (pedantic-errors); then the
 extension list (C11/C23 features true, c_thread_local = tls supported,
 overloadable_unmarked false, statement_attributes_with_gnu_syntax true,
 gnu_asm / gnu_asm_goto_with_outputs = langopts.gnu_asm, matrix_types* false,
 define_target_os_macros = langopts.has_target_os_macros()).
 OWNER: 14.5.
*>
fn bool has_extension(Compilation* comp, String ext_raw)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Compilation.isTargetArch`: target::parse_arch_name(query) (false on
 failure); arch must equal target.cpu.arch; with a sub-arch whose
 to_feature(arch) exists, that feature must be enabled. OWNER: 14.5.
*>
fn bool Compilation.is_target_arch(&self, String query)
{
	unreachable("stage 0 stub");
}

<* Zig `Compilation.isTargetOs`: Target.is_os(query). OWNER: 14.5. *>
fn bool Compilation.is_target_os(&self, String query)
{
	unreachable("stage 0 stub");
}

<* Zig `Compilation.isTargetVendor`: target::vendor_parse_name(query) == target.vendor (false if unknown). OWNER: 14.5. *>
fn bool Compilation.is_target_vendor(&self, String query)
{
	unreachable("stage 0 stub");
}

<* Zig `Compilation.isTargetAbi`: Target.is_abi(query). OWNER: 14.5. *>
fn bool Compilation.is_target_abi(&self, String query)
{
	unreachable("stage 0 stub");
}

<* Zig `isTargetVariantOs`: Darwin with has_darwin_target_variant -> darwin_target_variant.is_os(query); else false. OWNER: 14.5. *>
fn bool Compilation.is_target_variant_os(&self, String query)
{
	unreachable("stage 0 stub");
}

<* Zig `isTargetVariantEnvironment`: as is_target_variant_os with is_abi. OWNER: 14.5. *>
fn bool Compilation.is_target_variant_environment(&self, String query)
{
	unreachable("stage 0 stub");
}

<*
 Zig `pasteStringsUnsafe`: join an optionally parenthesized series of
 STRING_LITERAL tokens (MACRO_WS skipped) without their quotes. The result
 is a view of char_buf beyond its length at entry (the length is restored,
 so it is valid only until char_buf is next written). EXPECTED_STRING_LITERAL
 on an empty series or any other token. Shared with plan 15 (pragmas).
 @return? EXPECTED_STRING_LITERAL
*>
fn String? Preprocessor.paste_strings_unsafe(&self, TokenWithExpansionLocs[] toks)
{
	unreachable("stage 0 stub");
}

<*
 Zig `reconstructIncludeString`: trim MACRO_WS, concatenate
 expanded_slice_extra(PRESERVE_MACRO_WS) of the tokens into char_buf (with
 `embed_args` non-null, stop after a leading string literal or a '>' and
 store the remaining tokens there) and validate "<...>" / "\"...\"".
 Diagnosed failures (DIAG_EXPECTED_FILENAME, DIAG_CLOSING_PAREN,
 DIAG_EMPTY_FILENAME, DIAG_HEADER_STR_CLOSING + DIAG_HEADER_STR_MATCH)
 return "" (Zig null; a valid result is at least 3 bytes). The result is a
 view of char_buf past its restored length: copy or use it before the next
 char_buf write. Shared with plan 15 (#include / #embed).
 @return? compilation::FATAL_ERROR
*>
fn String? Preprocessor.reconstruct_include_string(&self, TokenWithExpansionLocs[] param_toks, TokenWithExpansionLocs[]* embed_args, TokenWithExpansionLocs first)
{
	unreachable("stage 0 stub");
}

<*
 Zig `handleBuiltinMacro` for the identifier queries, __has_warning,
 __is_identifier and __has_include(_next):
 - identifier queries: exactly one macro identifier (MACRO_WS/COMMENT
   skipped) else DIAG_FEATURE_CHECK_REQUIRES_IDENTIFIER (at the offending
   token, or an EOF token at src_loc) and false. __has_attribute ->
   attribute_exists(GNU); __has_declspec_attribute -> declspec_attrs &&
   attribute_exists(DECLSPEC); __has_builtin -> builtins::from_name or
   (emulate NO/CLANG and HAS_BUILTIN_SPECIAL_CASES); is_target_* -> the
   Compilation queries above.
 - __has_warning: paste_strings_unsafe (DIAG_EXPECTED_STR_LITERAL_IN
   "__has_warning"), must start with "-W" (DIAG_MALFORMED_WARNING_CHECK),
   then diagnostics::warning_exists(rest).
 - __is_identifier: one token (DIAG_BUILTIN_MISSING_R_PAREN "builtin
   feature-check macro"), true for IDENTIFIER / EXTENDED_IDENTIFIER.
 - __has_include(_next): outside EXPR DIAG_PREPROCESSING_DIRECTIVE_ONLY
   (kind name "has_include"/"has_include_next") at src_loc;
   reconstruct_include_string; quotes/angle type; FIRST lookup for
   __has_include or include_depth == 0 (the latter with
   DIAG_INCLUDE_NEXT_OUTSIDE_HEADER), else NEXT; answer =
   files.has_include(ctx, pp, filename, src_loc.id, type, which).
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn bool? Preprocessor.handle_builtin_macro(&self, BuiltinFunc builtin, TokenWithExpansionLocs[] param_toks, Location src_loc, EvalContext eval_ctx)
{
	unreachable("stage 0 stub");
}

<*
 Plan-15 seam for __has_embed: Zig runs EmbedArgIterator.param() over
 `embed_args` and answers "0" on an unknown/invalid parameter. Until plan 15
 provides the iterator: true when `embed_args` holds only MACRO_WS,
 otherwise aro::UNSUPPORTED.
 OWNER: 14.5 (replaced by plan 15).
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn bool? Preprocessor.embed_params_valid(&self, TokenWithExpansionLocs[] embed_args, TokenWithExpansionLocs eof)
{
	unreachable("stage 0 stub");
}

<*
 BuiltinProvider.expand_func: Zig expandFuncMacro's
 `.macro_param_builtin_func` arm for `kind`, appending to `buf`; generated
 tokens use pp.make_generated_token(start, id, tokens::from_raw(raw)).
 - query kinds (see handle_builtin_macro): empty expanded_args[0] ->
   DIAG_EXPECTED_ARGUMENTS (1, 0) at macro_tok and false; one PP_NUM
   "<0|1>\n".
 - __has_c_attribute: [vendor ::] identifier parsing exactly as Zig; vendor
   form -> attribute_exists(STANDARD, vendor, attr) as "1\n"/"0\n";
   otherwise the C23 table (deprecated/fallthrough/maybe_unused 201904L,
   nodiscard 202003L, noreturn/_Noreturn 202202L, unsequenced/reproducible
   202207L) on attribute_normalize(name), else "0\n".
 - __has_embed: outside EXPR DIAG_PREPROCESSING_DIRECTIVE_ONLY "has_embed"
   at macro_tok; reconstruct_include_string with embed args;
   embed_params_valid; files.find_embed(..., arg[0].loc.id, type, 1):
   FILE_NOT_FOUND -> "0\n", else "1\n" if non-empty / "2\n" if empty (the
   returned bytes are freed with comp.gpa).
 - _Pragma: exactly one STRING_LITERAL (MACRO_WS/COMMENT skipped) else
   DIAG_PRAGMA_OPERATOR_STRING_LITERAL; when valid and eval_ctx !=
   NO_PRAGMA -> plan 15 pragmaOperator (aro::UNSUPPORTED for now).
 - __identifier: one macro identifier becomes IDENTIFIER (pushed as is);
   DIAG_BUILTIN_MISSING_R_PAREN "identifier", DIAG_CANNOT_CONVERT_TO_IDENTIFIER
   (token symbol), DIAG_EXPECTED_IDENTIFIER exactly as Zig.
 - __pragma: plan 15 msPragmaOperator (aro::UNSUPPORTED for now).
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn void? builtin_expand_func(void* ctx, Preprocessor* pp, BuiltinFunc kind, TokenWithExpansionLocs macro_tok, RawToken raw, MacroArguments* expanded_args, EvalContext eval_ctx, ExpandBuf* buf)
{
	unreachable("stage 0 stub");
}
