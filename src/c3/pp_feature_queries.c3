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
//  - _Pragma / __pragma: validation (DIAG_PRAGMA_OPERATOR_STRING_LITERAL,
//    and __pragma's empty-argument DIAG_UNKNOWN_PRAGMA) is here; the pragma
//    itself (Zig pragmaOperator / msPragmaOperator) is plan 15 and returns
//    aro::UNSUPPORTED until then.
//
// Deviations from Zig:
//  - __identifier pushes a dupe of the argument token (Zig appends the token
//    itself, so the output and the macro arguments share one expansion
//    array, which deinitMacroArguments then frees under the output).
//  - embed_params_valid also skips WHITESPACE / COMMENT (as Zig
//    EmbedArgIterator.next does) when deciding that there are no parameters.
module aro::preprocessor;
import aro::source, aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics, aro::target;
import aro::lang_opts, aro::builtins;
import std::collections::list;

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
*>
fn bool has_feature(Compilation* comp, String ext_raw)
{
	String ext = attribute_normalize(ext_raw);
	Standard standard = comp.langopts.standard;
	switch (ext)
	{
		case "assume_nonnull":
		case "attribute_analyzer_noreturn":
		case "attribute_availability":
		case "attribute_availability_with_message":
		case "attribute_availability_app_extension":
		case "attribute_availability_with_version_underscores":
		case "attribute_availability_tvos":
		case "attribute_availability_watchos":
		case "attribute_availability_with_strict":
		case "attribute_availability_with_replacement":
		case "attribute_availability_in_templates":
		case "attribute_availability_swift":
		case "attribute_cf_returns_not_retained":
		case "attribute_cf_returns_retained":
		case "attribute_cf_returns_on_parameters":
		case "attribute_deprecated_with_message":
		case "attribute_deprecated_with_replacement":
		case "attribute_ext_vector_type":
		case "attribute_ns_returns_not_retained":
		case "attribute_ns_returns_retained":
		case "attribute_ns_consumes_self":
		case "attribute_ns_consumed":
		case "attribute_cf_consumed":
		case "attribute_overloadable":
		case "attribute_unavailable_with_message":
		case "attribute_unused_on_fields":
		case "attribute_diagnose_if_objc":
		case "c_thread_safety_attributes":
		case "enumerator_attributes":
		case "nullability":
		case "nullability_on_arrays":
		case "nullability_nullable_result":
			return true;
		case "blocks":
			return false; // TODO in Zig
		case "c_alignas":
		case "c_alignof":
		case "c_atomic":
		case "c_generic_selections":
		case "c_static_assert":
			return standard.at_least(C11);
		case "c_thread_local":
			return standard.at_least(C11) && comp.target.is_tls_supported();
		case "c_attributes":
		case "c_fixed_enum":
			return standard.at_least(C23);
		case "bounds_attributes":
			return comp.langopts.bounds_safety == CLANG;
		default:
			return false;
	}
}

<*
 Zig `features.hasExtension`: has_feature first; false if
 diagnostics.state.extensions is ERROR or FATAL (pedantic-errors); then the
 extension list (C11/C23 features true, c_thread_local = tls supported,
 overloadable_unmarked false, statement_attributes_with_gnu_syntax true,
 gnu_asm / gnu_asm_goto_with_outputs = langopts.gnu_asm, matrix_types* false,
 define_target_os_macros = langopts.has_target_os_macros()).
 As in Zig, has_feature receives the already normalized name (so it is
 normalized twice there).
*>
fn bool has_extension(Compilation* comp, String ext_raw)
{
	String ext = attribute_normalize(ext_raw);
	// Extensions are a superset of features, so check all features first.
	if (has_feature(comp, ext)) return true;

	// "-pedantic-errors" effectively disables extensions by erroring out on them.
	switch (comp.diagnostics.state.extensions)
	{
		case ERROR:
		case FATAL_ERROR:
			return false;
		default:
			break;
	}

	switch (ext)
	{
		case "c_alignas":
		case "c_alignof":
		case "c_atomic":
		case "c_generic_selections":
		case "c_static_assert":
		case "c_attributes":
		case "c_fixed_enum":
		case "statement_attributes_with_gnu_syntax":
			return true;
		case "c_thread_local":
			return comp.target.is_tls_supported();
		case "overloadable_unmarked":
		case "matrix_types":
		case "matrix_types_scalar_division":
			return false; // TODO in Zig
		case "gnu_asm":
		case "gnu_asm_goto_with_outputs":
			return comp.langopts.gnu_asm;
		case "define_target_os_macros":
			return comp.langopts.has_target_os_macros();
		default:
			return false;
	}
}

<*
 Zig `Compilation.isTargetArch`: target::parse_arch_name(query) (false on
 failure); arch must equal target.cpu.arch; with a sub-arch whose
 to_feature(arch) exists, that feature must be enabled.
*>
fn bool Compilation.is_target_arch(&self, String query)
{
	ArchSubArch? parsed = target::parse_arch_name(query);
	if (catch parsed) return false;
	if (parsed.arch != self.target.cpu.arch) return false;
	if (!parsed.has_sub) return true;
	Feature? feature = parsed.sub.to_feature(parsed.arch);
	if (catch feature) return true;
	return self.target.cpu.features.has(feature);
}

<* Zig `Compilation.isTargetOs`: Target.is_os(query). *>
fn bool Compilation.is_target_os(&self, String query) => self.target.is_os(query);

<* Zig `Compilation.isTargetVendor`: target::vendor_parse_name(query) == target.vendor (false if unknown). *>
fn bool Compilation.is_target_vendor(&self, String query)
{
	Vendor? vendor = target::vendor_parse_name(query);
	if (catch vendor) return false;
	return vendor == self.target.vendor;
}

<* Zig `Compilation.isTargetAbi`: Target.is_abi(query). *>
fn bool Compilation.is_target_abi(&self, String query) => self.target.is_abi(query);

<* Zig `isTargetVariantOs`: Darwin with has_darwin_target_variant -> darwin_target_variant.is_os(query); else false. *>
fn bool Compilation.is_target_variant_os(&self, String query)
{
	if (!self.target.os.tag.is_darwin() || !self.has_darwin_target_variant) return false;
	return self.darwin_target_variant.is_os(query);
}

<* Zig `isTargetVariantEnvironment`: as is_target_variant_os with is_abi. *>
fn bool Compilation.is_target_variant_environment(&self, String query)
{
	if (!self.target.os.tag.is_darwin() || !self.has_darwin_target_variant) return false;
	return self.darwin_target_variant.is_abi(query);
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
	sz char_top = self.char_buf.len();
	defer self.char_buf.size = char_top;
	TokenWithExpansionLocs[] unwrapped = toks;
	if (toks.len >= 2 && toks[0].id == L_PAREN && toks[^1].id == R_PAREN) unwrapped = toks[1 : toks.len - 2];
	if (unwrapped.len == 0) return EXPECTED_STRING_LITERAL~;

	foreach (tok : unwrapped)
	{
		if (tok.id == MACRO_WS) continue;
		if (tok.id != STRING_LITERAL) return EXPECTED_STRING_LITERAL~;
		String str = self.expanded_slice(tok);
		self.char_buf.push_all((char[])str[1 : str.len - 2]);
	}
	return (String)self.char_buf.array_view()[char_top..];
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
	if (param_toks.len == 0)
	{
		self.err(first, DIAG_EXPECTED_FILENAME)!;
		return "";
	}

	sz char_top = self.char_buf.len();
	defer self.char_buf.size = char_top;

	// Trim leading/trailing whitespace
	sz begin = 0;
	sz end = param_toks.len;
	while (begin < end && param_toks[begin].id == MACRO_WS) begin++;
	while (end > begin && param_toks[end - 1].id == MACRO_WS) end--;
	TokenWithExpansionLocs[] params = param_toks[begin:end - begin];

	if (params.len == 0)
	{
		self.err(first, DIAG_EXPECTED_FILENAME)!;
		return "";
	}
	// no string pasting
	if (!embed_args && params[0].id == STRING_LITERAL && params.len > 1)
	{
		self.err(params[1], DIAG_CLOSING_PAREN)!;
		return "";
	}

	foreach (i, tok : params)
	{
		String str = self.expanded_slice_extra(tok, PRESERVE_MACRO_WS);
		self.char_buf.push_all((char[])str);
		if (embed_args)
		{
			if ((i == 0 && tok.id == STRING_LITERAL) || tok.id == ANGLE_BRACKET_RIGHT)
			{
				*embed_args = params[i + 1..];
				break;
			}
		}
	}

	String include_str = (String)self.char_buf.array_view()[char_top..];
	if (include_str.len < 3)
	{
		if (include_str.len == 0)
		{
			self.err(first, DIAG_EXPECTED_FILENAME)!;
			return "";
		}
		self.err(params[0], DIAG_EMPTY_FILENAME)!;
		return "";
	}

	switch (include_str[0])
	{
		case '<':
			if (include_str[^1] != '>')
			{
				// Ugly hack to find out where the '>' should go, since we don't have the closing ')' location
				TokenWithExpansionLocs closing = first;
				String buf = self.comp.get_source(closing.loc.id).buf;
				sz pos = closing.loc.byte_offset;
				while (pos < buf.len && buf[pos] != '\n') pos++;
				closing.loc.byte_offset = (uint)pos;
				self.err(closing, DIAG_HEADER_STR_CLOSING)!;
				self.err(params[0], DIAG_HEADER_STR_MATCH)!;
				return "";
			}
			return include_str;
		case '"':
			return include_str;
		default:
			self.err(params[0], DIAG_EXPECTED_FILENAME)!;
			return "";
	}
}

<* Zig `Macro.Builtin.Func` tag names used in diagnostics (`@tagName(builtin)`). *>
fn String builtin_func_tag_name(BuiltinFunc f) @local
{
	switch (f)
	{
		case HAS_INCLUDE: return "has_include";
		case HAS_INCLUDE_NEXT: return "has_include_next";
		case HAS_EMBED: return "has_embed";
		default: unreachable("tag name only needed for include queries");
	}
}

<* Zig `has_builtin_special_cases.has(name)`. *>
fn bool is_has_builtin_special_case(String name) @local
{
	foreach (s : HAS_BUILTIN_SPECIAL_CASES)
	{
		if (s == name) return true;
	}
	return false;
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
 @require param_toks.len > 0 || (builtin != HAS_WARNING && builtin != HAS_INCLUDE && builtin != HAS_INCLUDE_NEXT)
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn bool? Preprocessor.handle_builtin_macro(&self, BuiltinFunc builtin, TokenWithExpansionLocs[] param_toks, Location src_loc, EvalContext eval_ctx)
{
	switch (builtin)
	{
		case HAS_ATTRIBUTE:
		case HAS_DECLSPEC_ATTRIBUTE:
		case HAS_FEATURE:
		case HAS_EXTENSION:
		case HAS_BUILTIN:
		case IS_TARGET_ARCH:
		case IS_TARGET_OS:
		case IS_TARGET_VENDOR:
		case IS_TARGET_ENVIRONMENT:
		case IS_TARGET_VARIANT_OS:
		case IS_TARGET_VARIANT_ENVIRONMENT:
			bool has_invalid;
			TokenWithExpansionLocs invalid;
			bool has_identifier;
			TokenWithExpansionLocs identifier;
			foreach (tok : param_toks)
			{
				if (tok.id == MACRO_WS || tok.id == COMMENT) continue;
				if (!tok.id.is_macro_identifier())
				{
					invalid = tok;
					has_invalid = true;
					break;
				}
				if (has_identifier)
				{
					invalid = tok;
					has_invalid = true;
				}
				else
				{
					identifier = tok;
					has_identifier = true;
				}
			}
			if (!has_identifier && !has_invalid)
			{
				invalid = { .id = EOF, .loc = src_loc };
				has_invalid = true;
			}
			if (has_invalid)
			{
				self.err(invalid, DIAG_FEATURE_CHECK_REQUIRES_IDENTIFIER)!;
				return false;
			}

			String ident_str = self.expanded_slice(identifier);
			Compilation* comp = self.comp;
			switch (builtin)
			{
				case HAS_ATTRIBUTE:
					return attribute_exists(GNU, "", ident_str);
				case HAS_DECLSPEC_ATTRIBUTE:
					if (!comp.langopts.declspec_attrs) return false;
					return attribute_exists(DECLSPEC, "", ident_str);
				case HAS_FEATURE:
					return has_feature(comp, ident_str);
				case HAS_EXTENSION:
					return has_extension(comp, ident_str);
				case HAS_BUILTIN:
					if (@ok(builtins::from_name(comp, ident_str))) return true;
					Compiler emulate = comp.langopts.emulate;
					return (emulate == NO || emulate == CLANG) && is_has_builtin_special_case(ident_str);
				case IS_TARGET_ARCH: return comp.is_target_arch(ident_str);
				case IS_TARGET_OS: return comp.is_target_os(ident_str);
				case IS_TARGET_VENDOR: return comp.is_target_vendor(ident_str);
				case IS_TARGET_ENVIRONMENT: return comp.is_target_abi(ident_str);
				case IS_TARGET_VARIANT_OS: return comp.is_target_variant_os(ident_str);
				case IS_TARGET_VARIANT_ENVIRONMENT: return comp.is_target_variant_environment(ident_str);
				default: unreachable();
			}
		case HAS_WARNING:
			String? actual_param = self.paste_strings_unsafe(param_toks);
			if (catch f = actual_param)
			{
				if (f != EXPECTED_STRING_LITERAL) return f~;
				self.err(param_toks[0], DIAG_EXPECTED_STR_LITERAL_IN, { diagnostics::arg_str("__has_warning") })!;
				return false;
			}
			if (!actual_param.starts_with("-W"))
			{
				self.err(param_toks[0], DIAG_MALFORMED_WARNING_CHECK, { diagnostics::arg_str("__has_warning") })!;
				return false;
			}
			return diagnostics::warning_exists(actual_param[2..]);
		case IS_IDENTIFIER:
			bool has_invalid;
			TokenWithExpansionLocs invalid;
			bool has_identifier;
			TokenWithExpansionLocs identifier;
			foreach (tok : param_toks)
			{
				if (tok.id == MACRO_WS || tok.id == COMMENT) continue;
				if (has_identifier)
				{
					invalid = tok;
					has_invalid = true;
				}
				else
				{
					identifier = tok;
					has_identifier = true;
				}
			}
			if (!has_identifier && !has_invalid)
			{
				invalid = { .id = EOF, .loc = src_loc };
				has_invalid = true;
			}
			if (has_invalid)
			{
				self.err(invalid, DIAG_BUILTIN_MISSING_R_PAREN, { diagnostics::arg_str("builtin feature-check macro") })!;
				return false;
			}
			return identifier.id == IDENTIFIER || identifier.id == EXTENDED_IDENTIFIER;
		case HAS_INCLUDE:
		case HAS_INCLUDE_NEXT:
			if (eval_ctx != EXPR)
			{
				self.err_loc(src_loc, DIAG_PREPROCESSING_DIRECTIVE_ONLY, { diagnostics::arg_str(builtin_func_tag_name(builtin)) })!;
			}
			String include_str = self.reconstruct_include_string(param_toks, null, param_toks[0])!;
			if (include_str.len == 0) return false;
			IncludeType include_type = include_str[0] == '"' ? IncludeType.QUOTES : IncludeType.ANGLE_BRACKETS;
			// A view of char_buf past its length, as in Zig.
			String filename = include_str[1 : include_str.len - 2];
			WhichInclude which = NEXT;
			if (builtin == HAS_INCLUDE || self.include_depth == 0)
			{
				if (builtin == HAS_INCLUDE_NEXT) self.err_loc(src_loc, DIAG_INCLUDE_NEXT_OUTSIDE_HEADER)!;
				which = FIRST;
			}
			return self.files.has_include(self.files.ctx, self, filename, src_loc.id, include_type, which);
		default:
			unreachable("not a handle_builtin_macro builtin");
	}
}

<*
 Plan-15 seam for __has_embed: Zig runs EmbedArgIterator.param() over
 `embed_args` and answers "0" on an unknown/invalid parameter. Until plan 15
 provides the iterator: true when `embed_args` holds only MACRO_WS (or
 WHITESPACE / COMMENT, which the iterator also skips), otherwise
 aro::UNSUPPORTED.
 OWNER: 14.5 (replaced by plan 15).
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn bool? Preprocessor.embed_params_valid(&self, TokenWithExpansionLocs[] embed_args, TokenWithExpansionLocs eof)
{
	foreach (tok : embed_args)
	{
		switch (tok.id)
		{
			case WHITESPACE:
			case COMMENT:
			case MACRO_WS:
				continue;
			default:
				return aro::UNSUPPORTED~;
		}
	}
	return true;
}

<* Append `text` to generated_buf and one generated PP_NUM token for it to `buf`. *>
fn void push_generated_number(Preprocessor* pp, String text, RawToken raw, ExpandBuf* buf) @local
{
	sz start = pp.comp.generated_buf.len();
	pp.comp.generated_buf.push_all((char[])text);
	buf.push(pp.make_generated_token(start, PP_NUM, tokens::from_raw(raw)));
}

<* Zig `std.StaticStringMap` of C23 standard attributes for __has_c_attribute; "" if unknown. *>
fn String c23_attribute_version(String name) @local
{
	switch (name)
	{
		case "deprecated":
		case "fallthrough":
		case "maybe_unused":
			return "201904L\n";
		case "nodiscard":
			return "202003L\n";
		case "noreturn":
		case "_Noreturn":
			return "202202L\n";
		case "unsequenced":
		case "reproducible":
			return "202207L\n";
		default:
			return "";
	}
}

<*
 Zig expandFuncMacro's __has_c_attribute arm: the text of the PP_NUM.
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn String? Preprocessor.has_c_attribute_result(&self, TokenWithExpansionLocs macro_tok, TokenWithExpansionLocs[] arg)
{
	String not_found = "0\n";
	if (arg.len == 0)
	{
		self.err(macro_tok, DIAG_EXPECTED_ARGUMENTS, { diagnostics::arg_int(1), diagnostics::arg_int(0) })!;
		return not_found;
	}
	bool has_invalid;
	TokenWithExpansionLocs invalid;
	bool has_vendor;
	TokenWithExpansionLocs vendor_ident;
	bool has_colon_colon;
	bool has_attr;
	TokenWithExpansionLocs attr_ident;
	foreach (tok : arg)
	{
		if (tok.id == MACRO_WS || tok.id == COMMENT) continue;
		if (tok.id == COLON_COLON)
		{
			if (has_colon_colon || !has_attr)
			{
				invalid = tok;
				has_invalid = true;
				break;
			}
			vendor_ident = attr_ident;
			has_vendor = true;
			has_attr = false;
			has_colon_colon = true;
			continue;
		}
		if (!tok.id.is_macro_identifier() || has_attr)
		{
			invalid = tok;
			has_invalid = true;
			break;
		}
		attr_ident = tok;
		has_attr = true;
	}
	if (has_vendor && !has_attr)
	{
		// Zig `invalid = vendor_ident` (overrides an earlier invalid token).
		invalid = vendor_ident;
		has_invalid = true;
	}
	else if (!has_attr && !has_invalid)
	{
		invalid = { .id = EOF, .loc = macro_tok.loc };
		has_invalid = true;
	}
	if (has_invalid)
	{
		self.err(invalid, DIAG_FEATURE_CHECK_REQUIRES_IDENTIFIER)!;
		return not_found;
	}
	if (has_vendor)
	{
		String vendor_str = self.expanded_slice(vendor_ident);
		String attr_str = self.expanded_slice(attr_ident);
		return attribute_exists(STANDARD, vendor_str, attr_str)! ? "1\n" : "0\n";
	}
	String version = c23_attribute_version(attribute_normalize(self.expanded_slice(attr_ident)));
	return version.len ? version : not_found;
}

<*
 Zig expandFuncMacro's __has_embed arm: the text of the PP_NUM.
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn String? Preprocessor.has_embed_result(&self, TokenWithExpansionLocs macro_tok, RawToken raw, TokenWithExpansionLocs[] arg, EvalContext eval_ctx)
{
	if (eval_ctx != EXPR)
	{
		self.err(macro_tok, DIAG_PREPROCESSING_DIRECTIVE_ONLY, { diagnostics::arg_str("has_embed") })!;
	}
	String not_found = "0\n";
	if (arg.len == 0)
	{
		self.err(macro_tok, DIAG_EXPECTED_ARGUMENTS, { diagnostics::arg_int(1), diagnostics::arg_int(0) })!;
		return not_found;
	}
	TokenWithExpansionLocs[] embed_args = {};
	String include_str = self.reconstruct_include_string(arg, &embed_args, arg[0])!;
	if (include_str.len == 0) return not_found;
	// A view of char_buf past its length, as in Zig (nothing below writes char_buf).
	String filename = include_str[1 : include_str.len - 2];
	IncludeType include_type = include_str[0] == '"' ? IncludeType.QUOTES : IncludeType.ANGLE_BRACKETS;

	TokenWithExpansionLocs prev = tokens::from_raw(raw);
	prev.id = EOF;
	if (!self.embed_params_valid(embed_args, prev)!) return not_found;

	char[]? contents = self.files.find_embed(self.files.ctx, self, filename, arg[0].loc.id, include_type, 1);
	if (catch f = contents)
	{
		if (f == FILE_NOT_FOUND) return not_found;
		return f~;
	}
	sz len = contents.len;
	if (contents.ptr) alloc::free(self.comp.gpa, contents.ptr);
	return len != 0 ? "1\n" : "2\n";
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
 - __identifier: one macro identifier becomes IDENTIFIER (a dupe is
   pushed); DIAG_BUILTIN_MISSING_R_PAREN "identifier",
   DIAG_CANNOT_CONVERT_TO_IDENTIFIER (token symbol), DIAG_EXPECTED_IDENTIFIER
   exactly as Zig.
 - __pragma: no arguments -> DIAG_UNKNOWN_PRAGMA at macro_tok (as Zig
   msPragmaOperator); otherwise plan 15 msPragmaOperator (aro::UNSUPPORTED
   for now).
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn void? builtin_expand_func(void* ctx, Preprocessor* pp, BuiltinFunc kind, TokenWithExpansionLocs macro_tok, RawToken raw, MacroArguments* expanded_args, EvalContext eval_ctx, ExpandBuf* buf)
{
	TokenWithExpansionLocs[] arg = (*expanded_args)[0];
	switch (kind)
	{
		case HAS_ATTRIBUTE:
		case HAS_DECLSPEC_ATTRIBUTE:
		case HAS_WARNING:
		case HAS_FEATURE:
		case HAS_EXTENSION:
		case HAS_BUILTIN:
		case HAS_INCLUDE:
		case HAS_INCLUDE_NEXT:
		case IS_IDENTIFIER:
		case IS_TARGET_ARCH:
		case IS_TARGET_OS:
		case IS_TARGET_VENDOR:
		case IS_TARGET_ENVIRONMENT:
		case IS_TARGET_VARIANT_OS:
		case IS_TARGET_VARIANT_ENVIRONMENT:
			bool result;
			if (arg.len == 0)
			{
				pp.err(macro_tok, DIAG_EXPECTED_ARGUMENTS, { diagnostics::arg_int(1), diagnostics::arg_int(0) })!;
			}
			else
			{
				result = pp.handle_builtin_macro(kind, arg, macro_tok.loc, eval_ctx)!;
			}
			push_generated_number(pp, result ? "1\n" : "0\n", raw, buf);
		case HAS_C_ATTRIBUTE:
			String result = pp.has_c_attribute_result(macro_tok, arg)!;
			push_generated_number(pp, result, raw, buf);
		case HAS_EMBED:
			String result = pp.has_embed_result(macro_tok, raw, arg, eval_ctx)!;
			push_generated_number(pp, result, raw, buf);
		case PRAGMA_OPERATOR:
			// Clang and GCC require exactly one token (so, no parentheses or string pasting)
			// even though their error messages indicate otherwise. Ours is slightly more
			// descriptive.
			bool has_invalid;
			TokenWithExpansionLocs invalid;
			bool has_string;
			foreach (tok : arg)
			{
				if (tok.id == MACRO_WS || tok.id == COMMENT) continue;
				if (tok.id == STRING_LITERAL && !has_string)
				{
					has_string = true;
					continue;
				}
				invalid = tok;
				has_invalid = true;
				break;
			}
			if (!has_string && !has_invalid)
			{
				invalid = macro_tok;
				has_invalid = true;
			}
			if (has_invalid)
			{
				pp.err(invalid, DIAG_PRAGMA_OPERATOR_STRING_LITERAL)!;
			}
			else if (eval_ctx != NO_PRAGMA)
			{
				// Plan 15: Zig pragmaOperator(string, buf).
				return aro::UNSUPPORTED~;
			}
		case MS_IDENTIFIER:
			// Expect '__identifier' '(' macro-identifier ')'
			bool has_ident;
			TokenWithExpansionLocs ident;
			foreach (tok : arg)
			{
				if (tok.id == MACRO_WS || tok.id == COMMENT) continue;
				if (has_ident)
				{
					pp.err(tok, DIAG_BUILTIN_MISSING_R_PAREN, { diagnostics::arg_str("identifier") })!;
					return;
				}
				if (tok.id.is_macro_identifier())
				{
					ident = tok;
					has_ident = true;
				}
				else
				{
					pp.err(tok, DIAG_CANNOT_CONVERT_TO_IDENTIFIER, { diagnostics::arg_str(tok.id.symbol()) })!;
					return;
				}
			}
			if (has_ident)
			{
				TokenWithExpansionLocs copy = ident.dupe(pp.comp.gpa);
				copy.id = IDENTIFIER;
				buf.push(copy);
			}
			else
			{
				pp.err(macro_tok, DIAG_EXPECTED_IDENTIFIER)!;
			}
		case MS_PRAGMA:
			if (arg.len == 0)
			{
				pp.err(macro_tok, DIAG_UNKNOWN_PRAGMA)!;
				return;
			}
			// Plan 15: Zig msPragmaOperator(macro_tok, arg).
			return aro::UNSUPPORTED~;
	}
}
