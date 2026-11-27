// Port of c3c src/compiler/parse_global.c: top level declarations (module,
// import, fn/macro, struct/union/bitstruct, enum/constset, faultdef,
// interface, alias/typedef/attrdef, generics, const/global variables,
// $include/$exec/$expand), type parsing, attributes, parameters and doc
// comment contracts.
//
// The exported functions (parser_internal.h) keep the stub signatures; the
// rest are c3c's file-local (static) functions. c3c's parse_attach_contracts,
// parse_optional_type_no_generic and parse_interface_impls are non-static but
// not exported by a header: they are plain functions here.
//
// Deviations from c3c:
// - `goto` is restructured: ON_MISMATCH (unify_generic_decl), DIRECT_SLICE
//   (parse_array_type_index), PARSE_EXPR (parse_attribute), ADD
//   (parse_attribute_list), CHECK_ELLIPSIS (parse_parameters), RESULT
//   (parse_func_macro_header), DECL (parse_decl_or_expr), END (parse_exec,
//   parse_contracts) and CONTRACT_NOT_ALLOWED (parse_top_level_statement,
//   a helper function) keep the same flow.
// - The `(Visibility)-1` "no visibility" sentinel of parse_attribute_list is
//   a separate bool.
// - A C NULL `const char*` argument (reject_visibility, names) is a String
//   with `ptr == null` (`NO_STRING`).
// - copy_attributes_single (copying.c) comes from parse_expr_support.c3
//   (shallow expression copies until copying.c is ported).
// - DEBUG_LOG calls are dropped.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

<* parse_global.c `FunctionParse`. *>
enum FunctionParse : char
{
	REGULAR,
	C3I,
	EXTERN,
	INTERFACE,
}

<* parse_global.c `DiscardedSubscript`. *>
enum DiscardedSubscript : char
{
	ERR,
	WILDCARD,
	SLICE,
	EXPR,
}

<* A C NULL `const char*`. *>
const String NO_STRING = {};

fn Decl* decl_new_var_current(ParseContext* c, TypeInfo* type, VarDeclKind kind) @inline
{
	return decl_new_var_loc(symstr(c), &c.span, type, kind);
}

<*
 Walk until we find the first top level construct, the current heuristic is this:
 public, typedef, struct, import, union, extern, enum, generic, attribute, define
 are *always* sync points.

 func, any type, CT_IDENT, CT_TYPE_IDENT, $if, $for, $switch, generic,
 doc comment start, asm, typeof, TYPE_IDENT, const, IDENT
 - are sync points only if they appear in the first column.
*>
fn void recover_top_level(ParseContext* c)
{
	advance(c);
	while (!tok_is(c, EOF))
	{
		switch (c.tok)
		{
			case IMPORT:
			case EXTERN:
			case ENUM:
			case ALIAS:
			case TYPEDEF:
			case ATTRDEF:
			case ATTRMACRO:
			case FAULTDEF:
				return;
			case CONST:
			case ASM:
			case CT_ASSERT:
			case CT_ERROR:
			case DOCS_START:
			case CT_IDENT:
			case CT_IF:
			case CT_FOR:
			case CT_SWITCH:
			case FN:
			case STRUCT:
			case UNION:
			case BITSTRUCT:
			case STATIC:
			case VOID..UNTYPEDLIST:
			case TYPE_IDENT:
			case CT_TYPE_IDENT:
			case CT_TYPEOF:
			case CT_TYPEFROM:
				// Only recover if this is in the first col.
				if (c.span.col == 1) return;
				advance(c);
			default:
				advance(c);
		}
	}
}

fn bool parse_decl_initializer(ParseContext* c, Decl* decl) @inline
{
	Expr* init = parse_expr(c);
	if (!expr_ok(init)) return false;
	decl.var_decl.init_expr = init;
	return true;
}

// --- Parse paths

<*
 module_path ::= IDENT (SCOPE IDENT)*

 @return "path or null if parsing failed."
*>
fn ModulePath* parse_module_path(ParseContext* c) @inline
{
	assert(tok_is(c, IDENT));
	scratch_buffer_clear();
	SourceLoc span = c.span;
	usz max_exceeded = 0;
	while (true)
	{
		String string = symstr(c);
		usz len = c.data.lex.len;
		if (!try_consume(c, IDENT))
		{
			if (token_is_keyword_ident(c.tok))
			{
				@print_error_here(c, "The module path cannot contain a reserved keyword, try another name.");
				return null;
			}
			if (token_is_some_ident(c.tok))
			{
				@print_error_here(c, "The elements of a module path must consist of only lower case letters, 0-9 and '_'.");
				return null;
			}
			@print_error_here(c, "Each '::' must be followed by a regular lower case sub module name.");
			return null;
		}
		if (len > MAX_MODULE_NAME)
		{
			@print_error_last(c, "The module name is too long, it's %d characters (%d more than the maximum allowed %d characters).",
				(int)len, (int)len - MAX_MODULE_NAME, MAX_MODULE_NAME);
			return null;
		}
		if (max_exceeded)
		{
			max_exceeded += len;
		}
		else
		{
			scratch_buffer_append(string);
			if (scratch_buffer_len() > MAX_MODULE_PATH)
			{
				max_exceeded = (usz)scratch_buffer_len();
			}
		}
		if (!try_consume(c, SCOPE))
		{
			span = extend_loc_with_token(&span, &c.prev_span);
			break;
		}
		if (max_exceeded)
		{
			max_exceeded += 2;
		}
		else
		{
			scratch_buffer_append("::");
		}
	}
	// This way we can highlight the entire span.
	if (max_exceeded)
	{
		SourceLoc loc_start = extend_loc_with_token(&span, &c.prev_span);
		@print_error_at_loc(&loc_start, "The full module path is too long, it's %d characters (%d more than the maximum allowed %d characters).", (long)max_exceeded, (long)max_exceeded - MAX_MODULE_PATH, (long)MAX_MODULE_PATH);
	}
	return path_create_from_string(scratch_buffer_str(), (uint)scratch_buffer_len(), make_loc(span));
}

// --- Parse import and module

<*
 We need to unify generic declarations using the parameter names, so that
 "struct Foo <Type> { ... }" and "const int ABC <Type> = Type::size" are unified.
*>
fn void unify_generic_decl(CompilationUnit* unit, Decl* decl) @inline
{
	usz params = decl.generic_decl.parameters.len;
	foreach (d : unit.mod.generic_sections)
	{
		usz candidate_params = d.generic_decl.parameters.len;
		if (candidate_params != params) continue;
		bool mismatch = false;
		for (usz i = 0; i < params; i++)
		{
			if (d.generic_decl.parameters[i].ptr != decl.generic_decl.parameters[i].ptr)
			{
				mismatch = true;
				break;
			}
		}
		if (mismatch) continue;
		decl.generic_decl.id = d.generic_decl.id;
		return;
	}
	decl.generic_decl.id = ++compiler.context.generic_id_counter;
}

fn bool parse_attach_contracts(Decl* generics, ContractDescription* contracts)
{
	if (!generics)
	{
		if (contracts.has_contracts)
		{
			@print_error_at(contracts.first_contract, "Contracts can only be used with generic declarations and modules.");
			return false;
		}
		return true;
	}

	if (contracts.first_non_require)
	{
		@print_error_at(contracts.first_non_require, "Invalid constraint - only '@require' is valid for generic declarations and modules.");
		return false;
	}
	if (contracts.first_variable_require)
	{
		@print_error_at(contracts.first_variable_require, "Invalid constraint - '@require' with variable references is only valid for functions, macros and function types.");
		return false;
	}
	foreach (e : contracts.requires) @vec_add(&generics.generic_decl.requires, e);
	return true;
}

<* Add the generic declaration to the current unit, the module and unify it's id. *>
fn void parse_attach_generics(ParseContext* c, Decl* generic_decl)
{
	assert(generic_decl.decl_kind == GENERIC);
	// Add to unit's generics
	@vec_add(&c.unit.generic_decls, generic_decl);
	// Unify it with other declarations of the same
	unify_generic_decl(c.unit, generic_decl);
	// Add to all the generic sections of the module
	@vec_add(&c.unit.mod.generic_sections, generic_decl);
}

<* module ::= MODULE module_path ('{' module_params '}')? (@public|@private|@local|@test|@export|@cname) EOS *>
fn bool parse_module(ParseContext* c)
{
	c.unit.module_doc = decl_from_contract_description(&c.contracts);
	if (tok_is(c, STRING))
	{
		return @print_error_here(c, "'module' should be followed by a plain identifier, not a string. Did you accidentally put the module name between \"\"?");
	}

	// Give some good error message:
	if (!tok_is(c, IDENT))
	{
		if (token_is_keyword_ident(c.tok))
		{
			return @print_error_here(c, "The module name cannot contain a reserved keyword, try another name.");
		}
		if (token_is_some_ident(c.tok))
		{
			return @print_error_here(c, "The module name must consist of only lower case letters, 0-9 and '_'.");
		}
		return @print_error_here(c, "'module' should be followed by a module name.");
	}

	ModulePath* path = parse_module_path(c);
	// Expect the module name
	if (!path)
	{
		// Create a fake path to continue
		path = calloc_arena(ModulePath::size);
		path.len = (uint)"#invalid".len;
		path.module_name = "#invalid";
		path.loc = 0;
		context_set_module(c, path);
		recover_top_level(c);
		return false;
	}

	if (!context_set_module(c, path)) return false;
	Visibility visibility = PUBLIC;
	bool weak = false;
	Attr*[] attrs;
	bool is_cond;
	bool is_feat_cond;

	// Is generic attached?
	Decl* generic_decl = parse_generic_decl(c);
	if (!decl_ok(generic_decl)) return false;

	// Parse the attributes
	if (!parse_attributes(c, &attrs, &visibility, null, &is_cond, NO_STRING, &weak, &is_feat_cond)) return false;

	// Attach contracts to the generics
	if (!parse_attach_contracts(generic_decl, &c.contracts)) return false;

	// Attach generics if they exist
	if (generic_decl)
	{
		parse_attach_generics(c, generic_decl);
		c.unit.default_generic_section = generic_decl;
	}

	// Pre-parse attributes
	foreach (attr : attrs)
	{
		if (attr.is_custom) { @print_error_at(attr.loc, "Custom attributes cannot be used with 'module'."); return false; }
		switch (attr.attr_kind)
		{
			case LINK:
				usz args = attr.exprs.len;
				if (args < 1) { @print_error_at(attr.loc, "'@link' needs at least 1 argument."); return false; }
				@vec_add(&c.unit.attr_links, attr);
				continue;
			case FEAT:
				@vec_add(&c.unit.feat_attributes, attr);
				continue;
			case IF:
				if (c.unit.if_attr) { @print_error_at(attr.loc, "'@if' appeared more than once."); return false; }
				c.unit.if_attr = attr;
				continue;
			case BENCHMARK:
				c.unit.benchmark_by_default = true;
				continue;
			case TEST:
				c.unit.test_by_default = true;
				continue;
			case EXPORT:
				if (attr.exprs.len) { @print_error_at(attr.loc, "Expected no arguments to '@export'"); return false; }
				if (c.unit.export_by_default)
				{
					@print_error_at(attr.loc, "'@export' appeared more than once.");
					return false;
				}
				c.unit.export_by_default = true;
				continue;
			case CNAME:
				if (attr.exprs.len != 1)
				{
					@print_error_at(attr.loc, "Expected 1 argument to '@cname(..), not %d'.", attr.exprs.len);
					return false;
				}
				Expr* expr = attr.exprs[0];
				if (expr.resolve_status != DONE || !expr_is_const_string(expr)) { @print_error_at(expr.loc, "Expected a constant string."); return false; }
				if (c.unit.mod.extname.ptr)
				{
					@print_error_at(attr.loc, "External name for the module may only be declared in one location.");
					return false;
				}
				c.unit.mod.extname = (String)expr.const_expr.bytes.ptr[:expr.const_expr.bytes.len];
				continue;
			default:
				break;
		}
		@print_error_at(attr.loc, "'%s' cannot be used after a module declaration.", attr.name);
		return false;
	}
	c.unit.default_visibility = visibility;
	c.unit.default_is_weak = weak;
	if (!consume_eos(c)) return false;
	return true;
}

fn bool consume_type_name(ParseContext* c, String type)
{
	if (tok_is(c, IDENT) || token_is_keyword_ident(c.tok))
	{
		return @print_error_here(c, "Names of %ss must start with an uppercase letter.", type);
	}
	if (tok_is(c, CONST_IDENT))
	{
		return @print_error_here(c, "Names of %ss cannot be all uppercase.", type);
	}
	return @consume(c, TYPE_IDENT, "'%s' should be followed by the name of the %s.", type, type);
}

fn bool consume_const_name(ParseContext* c, String type)
{
	if (tok_is(c, IDENT) || tok_is(c, TYPE_IDENT) || token_is_keyword_ident(c.tok))
	{
		return @print_error_here(c, "Names of %ss must be all uppercase.", type);
	}
	return @consume(c, CONST_IDENT, "A constant name was expected here, did you forget it?");
}

<* Parse an optional foo::bar:: *>
fn bool parse_path_prefix(ParseContext* c, ModulePath** path_ref)
{
	*path_ref = null;
	if (!tok_is(c, IDENT) || peek(c) != SCOPE) return true;

	ModulePath* path = calloc_arena(ModulePath::size);
	path.loc = make_loc(c.span);
	scratch_buffer_clear();
	scratch_buffer_append(symstr(c));
	SourceLoc last_loc = c.span;
	advance(c);
	advance(c);
	while (tok_is(c, IDENT) && peek(c) == SCOPE)
	{
		last_loc = c.span;
		scratch_buffer_append("::");
		scratch_buffer_append_len(symstr(c).ptr, c.data.lex.len);
		advance(c); advance(c);
	}

	TokenType type = IDENT;
	*sourcelocptr(path.loc) = extend_loc_with_token(sourcelocptr(path.loc), &last_loc);
	path.module_name = scratch_buffer_interned_as(&type);
	if (type != IDENT)
	{
		@print_error_at(path.loc, "A module name was expected here.");
		return false;
	}
	path.len = (uint)scratch_buffer_len();
	*path_ref = path;
	return true;
}

// --- Type parsing

<*
 base_type
		: VOID | BOOL | ICHAR | CHAR | SHORT | USHORT | INT | UINT | LONG | ULONG
		| INT128 | UINT128 | FLOAT | DOUBLE | FLOAT16 | FLOAT128
		| TYPE_IDENT
		| path_prefix TYPE_IDENT
		| CT_TYPE_IDENT
		| CT_TYPEOF '(' expr ')'
		| CT_TYPEFROM '(' expr ')'
		| CT_VATYPE '(' expr ')'
		| CT_EVALTYPE '(' expr ')'
		;

 Assume prev_token is the type.
 @return "TypeInfo (poisoned if fails)"
*>
fn TypeInfo* parse_base_type(ParseContext* c) @inline
{
	if (try_consume(c, CT_TYPEFROM))
	{
		TypeInfo* type_info = type_info_new(INFO_TYPEFROM, make_loc(c.prev_span));
		if (!expect_advance(c, LPAREN)) return poisoned_type_info;
		Expr* inner = parse_expr(c);
		if (!expr_ok(inner)) return poisoned_type_info;
		type_info.unresolved_type_expr = inner;
		if (!expect_advance(c, RPAREN)) return poisoned_type_info;
		range_extend_prev(c, type_info.loc);
		return type_info;
	}
	if (try_consume(c, CT_TYPEOF))
	{
		TypeInfo* type_info = type_info_new(INFO_TYPEOF, make_loc(c.prev_span));
		if (!expect_advance(c, LPAREN)) return poisoned_type_info;
		Expr* inner = parse_expr(c);
		if (!expr_ok(inner)) return poisoned_type_info;
		type_info.unresolved_type_expr = inner;
		if (!expect_advance(c, RPAREN)) return poisoned_type_info;
		range_extend_prev(c, type_info.loc);
		return type_info;
	}
	SourceLoc range = c.span;
	ModulePath* path;
	if (!parse_path_prefix(c, &path)) return poisoned_type_info;
	if (path)
	{
		TypeInfo* type_info = type_info_new(INFO_IDENTIFIER, make_loc(range));
		type_info.unresolved.path = path;
		type_info.unresolved.name = symstr(c);
		if (!consume_type_name(c, "type")) return poisoned_type_info;
		range_extend_prev(c, type_info.loc);
		return type_info;
	}

	TypeInfo* type_info = null;
	switch (c.tok)
	{
		case TYPE_IDENT:
			type_info = type_info_new_curr(c, INFO_IDENTIFIER);
			type_info.unresolved.name = symstr(c);
		case CT_TYPE_IDENT:
			type_info = type_info_new_curr(c, INFO_CT_IDENTIFIER);
			type_info.unresolved.name = symstr(c);
		case VOID..UNTYPEDLIST:
			type_info = type_info_new_curr(c, INFO_IDENTIFIER);
			type_info.resolve_status = DONE;
			type_info.type = type_from_token(c.tok);
		default:
			if (c.tok == IDENT)
			{
				if (peek(c) == IDENT)
				{
					@print_error_here(c, "The name of a type must start with uppercase and contain at least one lowercase letter.");
				}
				else
				{
					@print_error_here(c, "A type name was expected, but this looks a variable or function name (as it doesn't start with an uppercase letter).");
				}
			}
			else
			{
				@print_error_here(c, "A type name was expected here.");
			}
			return poisoned_type_info;
	}
	advance(c);
	range_extend_prev(c, type_info.loc);
	return type_info;
}

<* generic_type ::= type generic_parameters *>
fn TypeInfo* parse_generic_type(ParseContext* c, TypeInfo* type) @inline
{
	assert(type_info_ok(type));
	TypeInfo* generic_type = type_info_new(INFO_GENERIC, type.loc);
	if (!parse_generic_expr_list(c, &generic_type.generic.params)) return poisoned_type_info;
	generic_type.generic.base = type;
	return generic_type;
}

<*
 array_type_index ::= '[' (constant_expression | '*')? ']'

 @param [&inout] c : "the parse context"
 @param [&inout] type : "the type to wrap, may not be poisoned."
 @return "type (poisoned if fails)"
*>
fn TypeInfo* parse_array_type_index(ParseContext* c, TypeInfo* type) @inline
{
	assert(type_info_ok(type));

	advance_and_verify(c, LBRACKET);
	if (try_consume(c, STAR))
	{
		if (!expect_advance(c, RBRACKET)) return poisoned_type_info;
		TypeInfo* inferred_array = type_info_new(INFO_INFERRED_ARRAY, type.loc);
		inferred_array.array.base = type;
		range_extend_prev(c, inferred_array.loc);
		return inferred_array;
	}
	if (try_consume(c, RBRACKET))
	{
		bool is_resolved = type.resolve_status == DONE;
		// c3c: goto DIRECT_SLICE
		bool direct_slice = is_resolved && !type_is_valid_for_array(type.type);
		if (!direct_slice)
		{
			switch (type.subtype)
			{
				case TYPE_COMPRESSED_NONE:
					type.subtype = TYPE_COMPRESSED_SUB;
				case TYPE_COMPRESSED_PTR:
					type.subtype = TYPE_COMPRESSED_PTRSUB;
				case TYPE_COMPRESSED_SUB:
					type.subtype = TYPE_COMPRESSED_SUBSUB;
				default:
					direct_slice = true;
			}
		}
		if (!direct_slice)
		{
			if (is_resolved)
			{
				type.type = type_get_slice(type.type);
			}
			range_extend_prev(c, type.loc);
			return type;
		}
		// DIRECT_SLICE:
		TypeInfo* slice = type_info_new(INFO_SLICE, type.loc);
		slice.array.base = type;
		slice.array.len = null;
		range_extend_prev(c, slice.loc);
		return slice;
	}
	TypeInfo* array = type_info_new(INFO_ARRAY, type.loc);
	array.array.base = type;
	Expr* len = parse_expr(c);
	if (!expr_ok(len)) return poisoned_type_info;
	array.array.len = len;
	if (!expect_advance(c, RBRACKET)) return poisoned_type_info;
	range_extend_prev(c, array.loc);
	return array;
}

<*
 vector_type_index ::= '[<' (constant_expression | '*') '>]'

 @param [&inout] c : "the parse context."
 @param [&inout] type : "the type to wrap, may not be poisoned."
 @return "type (poisoned if fails)"
*>
fn TypeInfo* parse_vector_type_index(ParseContext* c, TypeInfo* type) @inline
{
	assert(type_info_ok(type));

	advance_and_verify(c, LVEC);
	TypeInfo* vector = type_info_new(INFO_VECTOR, type.loc);
	vector.array.base = type;
	if (try_consume(c, STAR))
	{
		if (!expect_advance(c, RVEC)) return poisoned_type_info;
		vector.kind = INFO_INFERRED_VECTOR;
	}
	else
	{
		Expr* len = parse_expr(c);
		if (!expr_ok(len)) return poisoned_type_info;
		vector.array.len = len;
		if (!expect_advance(c, RVEC)) return poisoned_type_info;
	}
	if (tok_is(c, AT_IDENT))
	{
		if (symstr(c).ptr != kw_at_simd.ptr)
		{
			@print_error_here(c, "Only '@simd' is a valid attribute, found '%s'.", symstr(c));
			return poisoned_type_info;
		}
		if (vector.kind == INFO_INFERRED_VECTOR)
		{
			@print_error_here(c, "The '@simd' attribute cannot be used on an inferred vector type.");
			return poisoned_type_info;
		}
		advance(c);
		vector.is_simd = true;
	}
	range_extend_prev(c, vector.loc);
	return vector;
}

<*
 type ::= base_type ('*' | array_type_index | vector_type_index | generic_parameters)*

 Assume already stepped into.
 @return "Type, poisoned if parsing is invalid."
*>
fn TypeInfo* parse_type_with_base_maybe_generic(ParseContext* c, TypeInfo* type_info, bool allow_generic) @inline
{
	while (type_info_ok(type_info))
	{
		switch (c.tok)
		{
			case LVEC:
				type_info = parse_vector_type_index(c, type_info);
			case LBRACKET:
				type_info = parse_array_type_index(c, type_info);
			case LBRACE:
				if (!allow_generic) return type_info;
				type_info = parse_generic_type(c, type_info);
			case STAR:
				advance(c);
				switch (type_info.subtype)
				{
					case TYPE_COMPRESSED_NONE:
						type_info.subtype = TYPE_COMPRESSED_PTR;
					case TYPE_COMPRESSED_PTR:
						type_info.subtype = TYPE_COMPRESSED_PTRPTR;
					case TYPE_COMPRESSED_SUB:
						type_info.subtype = TYPE_COMPRESSED_SUBPTR;
					default:
						TypeInfo* ptr_type = type_info_new(INFO_POINTER, type_info.loc);
						assert(type_info != null);
						ptr_type.pointer = type_info;
						type_info = ptr_type;
						range_extend_prev(c, type_info.loc);
				}
				range_extend_prev(c, type_info.loc);
				if (type_info.resolve_status == DONE)
				{
					if (type_info.type == type_untypedlist)
					{
						@print_error_at(type_info.loc, "It's not possible to create a pointer to an untyped list.");
						return poisoned_type_info;
					}
					assert(type_info.type != null);
					type_info.type = type_get_ptr(type_info.type);
				}
			default:
				return type_info;
		}
	}
	return type_info;
}

fn TypeInfo* parse_type_with_base(ParseContext* c, TypeInfo* type_info)
{
	return parse_type_with_base_maybe_generic(c, type_info, true);
}

<*
 type ::= base_type modifiers

 Assume already stepped into.
 @return "Type, poisoned if parsing is invalid."
*>
fn TypeInfo* parse_type(ParseContext* c)
{
	TypeInfo* base = parse_base_type(c);
	if (!type_info_ok(base)) return poisoned_type_info;
	return parse_type_with_base(c, base);
}

fn DiscardedSubscript parse_discarded_subscript(ParseContext* c, TokenType end)
{
	if (end == RBRACKET && try_consume(c, end)) return SLICE;
	if (try_consume(c, STAR) || try_consume(c, QUESTION))
	{
		if (!expect_advance(c, end)) return ERR;
		return WILDCARD;
	}
	Expr* ex = parse_expr(c);
	if (!expr_ok(ex)) return ERR;
	if (!expect_advance(c, end)) return ERR;
	return EXPR;
}

fn bool parse_rethrow_bracket(ParseContext* c, SourceLoc* start) @inline
{
	if (try_consume(c, LBRACKET))
	{
		*start = extend_loc_with_token(start, &c.prev_span);
		switch (parse_discarded_subscript(c, RBRACKET))
		{
			case ERR:
				return false;
			case WILDCARD:
				@print_error_at_loc(start, "When declaring an optional array, the '[*]' should appear before the '?', e.g 'Foo[*]?'.");
				return false;
			case SLICE:
				@print_error_at_loc(start, "When declaring an optional slice the '[]' should appear before the '?', e.g 'Foo[]?'.");
				return false;
			case EXPR:
				@print_error_at_loc(start, "When declaring an optional array, the '[...]' should appear before the '?', e.g 'Foo[4]?'.");
				return false;
		}
		// c3c: UNREACHABLE (every case returns)
	}
	if (try_consume(c, LVEC))
	{
		switch (parse_discarded_subscript(c, RVEC))
		{
			case ERR:
				return false;
			case WILDCARD:
				*start = extend_loc_with_token(start, &c.span);
				@print_error_at_loc(start, "When declaring an optional vector, the '[<*>]' should appear before the '?', e.g 'Foo[<*>]?'.");
				return false;
			case SLICE:
				unreachable();
			case EXPR:
				*start = extend_loc_with_token(start, &c.span);
				@print_error_at_loc(start, "When declaring an optional vector, the '[<...>]' should appear before the '?', e.g 'Foo[<4>]?'.");
				return false;
		}
		// c3c: UNREACHABLE (every case returns)
	}
	return true;
}

<*
 optional_type ::= type '!'?
 @param [&inout] c
 @param allow_generic : "should generic be allowed"
 @return "The resulting type"
*>
fn TypeInfo* parse_optional_type_maybe_generic(ParseContext* c, bool allow_generic) @inline
{
	TypeInfo* info = parse_base_type(c);
	if (!type_info_ok(info)) return poisoned_type_info;
	info = parse_type_with_base_maybe_generic(c, info, allow_generic);
	if (!type_info_ok(info)) return poisoned_type_info;
	if (try_consume(c, QUESTION))
	{
		if (!parse_rethrow_bracket(c, sourcelocptr(info.loc))) return poisoned_type_info;
		assert(!info.optional);
		info.optional = true;
		if (info.resolve_status == DONE)
		{
			if (info.type == type_untypedlist)
			{
				range_extend_prev(c, info.loc);
				@print_error_at(info.loc, "%s cannot be used as an optional type, since it is compile-time only.", type_quoted_error_string(info.type));
				return poisoned_type_info;
			}
			info.type = type_get_optional(info.type);
		}
		range_extend_prev(c, info.loc);
	}
	return info;
}

<* optional_type ::= type '!'? *>
fn TypeInfo* parse_optional_type(ParseContext* c)
{
	return parse_optional_type_maybe_generic(c, true);
}

fn TypeInfo* parse_optional_type_no_generic(ParseContext* c)
{
	return parse_optional_type_maybe_generic(c, false);
}

// --- Decl parsing

<*
 interface_impls ::= '(' (type (',' type)* ','? )? ')'

 @param [&inout] c : "the context"
 @param [&inout] interfaces_ref : "the list to add interfaces to"
 @return "false if the parsing failed"
*>
fn bool parse_interface_impls(ParseContext* c, TypeInfo*[]* interfaces_ref)
{
	if (!try_consume(c, LPAREN)) return true;
	TypeInfo*[] interfaces;
	while (!try_consume(c, RPAREN))
	{
		TypeInfo* interface_ = parse_type(c);
		if (!type_info_ok(interface_)) return false;
		@vec_add(&interfaces, interface_);
		if (!try_consume(c, COMMA))
		{
			if (!expect_advance(c, RPAREN)) return false;
			break;
		}
	}
	*interfaces_ref = interfaces;
	return true;
}

<* after_type ::= (CT_IDENT | IDENT) attributes? ('=' decl_initializer)? *>
fn Decl* parse_local_decl_after_type(ParseContext* c, TypeInfo* type)
{
	if (tok_is(c, LPAREN))
	{
		@print_error_here(c, "Expected '{'.");
		return poisoned_decl;
	}

	if (tok_is(c, CT_IDENT))
	{
		Decl* decl = decl_new_var_current(c, type, LOCAL_CT);
		advance(c);
		if (try_consume(c, EQ))
		{
			if (!parse_decl_initializer(c, decl)) return poisoned_decl;
		}
		return decl;
	}

	if (!expect_ident(c, "variable name")) return poisoned_decl;

	Decl* decl = decl_new_var_current(c, type, LOCAL);
	advance(c);

	bool is_cond;
	bool is_feat_cond;
	if (!parse_attributes(c, &decl.attributes, null, null, &is_cond, "on local variables", null, &is_feat_cond)) return poisoned_decl;
	decl.is_cond = is_cond;
	decl.is_feat_cond = is_feat_cond;
	if (tok_is(c, EQ))
	{
		if (!decl)
		{
			@print_error_here(c, "Expected an identifier before '='.");
			return poisoned_decl;
		}
		advance_and_verify(c, EQ);
		if (!parse_decl_initializer(c, decl)) return poisoned_decl;
	}
	return decl;
}

<* decl_or_expr ::= var_decl | type local_decl_after_type | expression *>
fn Expr* parse_decl_or_expr(ParseContext* c)
{
	// var-initialization is done separately.
	Decl* decl;
	if (tok_is(c, VAR))
	{
		decl = parse_var_decl(c);
		if (!decl_ok(decl)) return poisoned_expr;
	}
	else
	{
		Expr* expr = parse_expr(c);

		// If it's not a type info, we assume an expr.
		if (expr.expr_kind != TYPEINFO) return expr;

		switch (c.tok)
		{
			case RPAREN:
			case RBRACKET:
			case RBRACE:
			case RVEC:
				return expr;
			default:
				break;
		}
		// Otherwise we expect a declaration.
		decl = parse_local_decl_after_type(c, expr.type_expr);
		if (!decl_ok(decl)) return poisoned_expr;
	}
	// DECL:
	assert(decl != null);
	Expr* decl_expr = expr_new(DECL, decl.loc);
	decl_expr.decl_expr = decl;
	return decl_expr;
}

<* const_decl ::= 'const' type? CONST_IDENT attributes? '=' const_expr *>
fn Decl* parse_const_declaration(ParseContext* c, bool is_global, bool is_extern)
{
	advance_and_verify(c, CONST);

	TypeInfo* type_info = null;

	// If not a const ident, assume we want the type
	if (c.tok != CONST_IDENT)
	{
		type_info = parse_optional_type(c);
		if (!type_info_ok(type_info)) return poisoned_decl;
	}

	// Create the decl
	Decl* decl = decl_new_var_loc(symstr(c), &c.span, type_info, CONST);

	// Check the name
	if (!consume_const_name(c, "const")) return poisoned_decl;

	// Differentiate between global and local attributes, global have visibility
	if (is_global)
	{
		if (!parse_attributes_for_global(c, decl)) return poisoned_decl;
	}
	else
	{
		bool is_cond;
		bool is_feat_cond;
		if (!parse_attributes(c, &decl.attributes, null, null, &is_cond, "on local declarations", null, &is_feat_cond)) return poisoned_decl;
		decl.is_cond = is_cond;
		decl.is_feat_cond = is_feat_cond;
	}

	if (is_extern) return decl;
	// Required initializer
	if (!expect_advance(c, EQ)) return poisoned_decl;
	if (!parse_decl_initializer(c, decl)) return poisoned_decl;
	range_extend_prev(c, decl.loc);
	return decl;
}

<* var_decl ::= VAR (IDENT '=' expression) | (CT_IDENT ('=' expression)?) | (CT_TYPE_IDENT ('=' expression)?) *>
fn Decl* parse_var_decl(ParseContext* c)
{
	// CT variants will naturally be macro only, for runtime variables it is enforced in the semantic
	// analyzer. The runtime variables must have an initializer unlike the CT ones.
	advance_and_verify(c, VAR);
	Decl* decl;
	bool is_cond;
	bool is_feat_cond;
	SourceLoc loc;
	switch (c.tok)
	{
		case CONST_IDENT:
			@print_error_here(c, "Constants must be declared using 'const' not 'var'.");
			return poisoned_decl;
		case IDENT:
			decl = decl_new_var_current(c, null, LOCAL);
			advance(c);
			if (!parse_attributes(c, &decl.attributes, null, null, &is_cond, "on local declarations", null, &is_feat_cond)) return poisoned_decl;
			decl.is_cond = is_cond;
			decl.is_feat_cond = is_feat_cond;
			if (!tok_is(c, EQ))
			{
				@print_error_here(c, "'var' must always have an initial value, or the type cannot be inferred.");
				return poisoned_decl;
			}
			advance_and_verify(c, EQ);
			Expr* init = parse_expr(c);
			if (!expr_ok(init)) return poisoned_decl;
			decl.var_decl.init_expr = init;
		case CT_IDENT:
		case CT_TYPE_IDENT:
			decl = decl_new_var_current(c, null, c.tok == CT_IDENT ? LOCAL_CT : LOCAL_CT_TYPE);
			advance(c);
			loc = c.span;
			if (!parse_attributes(c, &decl.attributes, null, null, &is_cond, "on local declarations", null, &is_feat_cond)) return poisoned_decl;
			if (is_cond || is_feat_cond || decl.attributes.len)
			{
				@print_error_at_loc(&loc, "Attributes are not allowed on compile time variables.");
				return poisoned_decl;
			}
			if (try_consume(c, EQ))
			{
				Expr* init = parse_expr(c);
				if (!expr_ok(init)) return poisoned_decl;
				decl.var_decl.init_expr = init;
			}
		default:
			@print_error_here(c, "Expected a compile time variable name ('$Foo' or '$foo').");
			return poisoned_decl;
	}
	return decl;
}

// --- Parse parameters & throws & attributes

fn Expr* parse_overload_from_token(ParseContext* c, TokenType token)
{
	OperatorOverload overload;
	switch (token)
	{
		case PLUS: overload = OVERLOAD_PLUS;
		case PLUS_ASSIGN: overload = OVERLOAD_PLUS_ASSIGN;
		case MINUS: overload = OVERLOAD_MINUS;
		case MINUS_ASSIGN: overload = OVERLOAD_MINUS_ASSIGN;
		case STAR: overload = OVERLOAD_MULTIPLY;
		case MULT_ASSIGN: overload = OVERLOAD_MULTIPLY_ASSIGN;
		case DIV: overload = OVERLOAD_DIVIDE;
		case DIV_ASSIGN: overload = OVERLOAD_DIVIDE_ASSIGN;
		case MOD: overload = OVERLOAD_REMINDER;
		case MOD_ASSIGN: overload = OVERLOAD_REMINDER_ASSIGN;
		case AMP: overload = OVERLOAD_AND;
		case BIT_AND_ASSIGN: overload = OVERLOAD_AND_ASSIGN;
		case BIT_OR: overload = OVERLOAD_OR;
		case BIT_OR_ASSIGN: overload = OVERLOAD_OR_ASSIGN;
		case BIT_XOR: overload = OVERLOAD_XOR;
		case BIT_XOR_ASSIGN: overload = OVERLOAD_XOR_ASSIGN;
		case SHL: overload = OVERLOAD_SHL;
		case SHL_ASSIGN: overload = OVERLOAD_SHL_ASSIGN;
		case SHR: overload = OVERLOAD_SHR;
		case SHR_ASSIGN: overload = OVERLOAD_SHR_ASSIGN;
		case BIT_NOT: overload = OVERLOAD_NEGATE;
		case EQEQ: overload = OVERLOAD_EQUAL;
		case LESS: overload = OVERLOAD_LESS_THAN;
		default:
			unreachable();
	}
	Expr* expr = expr_new_token(c, OPERATOR_CHARS);
	expr.resolve_status = DONE;
	expr.overload_expr = overload;
	advance(c);
	range_extend_prev(c, expr.loc);
	return expr;
}

<*
 attribute ::= (AT_IDENT | path_prefix? AT_TYPE_IDENT) attr_params?
 attr_params ::= '(' attr_param (',' attr_param)* ')'
 attr_param ::= const_expr | '&' '[' ']' | '[' ']' '='? | '-' | '+' | '/' | '%' | '==' | '<' | '<<' | '>>' | '|' | '&' | '^' | '~'
*>
fn bool parse_attribute(ParseContext* c, Attr** attribute_ref, bool expect_eos)
{
	SourceLoc start_loc = c.prev_span;
	ModulePath* path;
	if (!parse_path_prefix(c, &path)) return false;

	// Something not starting with `@` in attribute position:
	if (!tok_is(c, AT_IDENT) && !tok_is(c, AT_TYPE_IDENT))
	{
		// Started a path? If so hard error
		if (path)
		{
			if (expect_eos)
			{
				@print_error_after(&start_loc, "Expected a ';' here.");
				return false;
			}
			return @print_error_here(c, "Expected an attribute name.");
		}

		// Otherwise assume no attributes
		*attribute_ref = null;
		return true;
	}

	// Create an attribute
	Attr* attr = calloc_arena(Attr::size);
	attr.name = symstr(c);
	attr.loc = make_loc(c.span);
	attr.path = path;

	// Pre-defined idents
	if (tok_is(c, AT_IDENT))
	{
		// Error for foo::bar::@inline
		if (path) return @print_error_here(c, "Only user-defined attribute names can have a module path prefix.");

		// Check attribute it exists, theoretically we could defer this to semantic analysis
		AttributeType type = attribute_by_name(attr.name);
		if (type == NONE) return @print_error_here(c, "This is not a known valid attribute name.");
		attr.attr_kind = type;
	}
	else
	{
		attr.is_custom = true;
	}
	advance(c);
	Expr*[] list;

	// Consume the optional (expr | attr_param, ...)
	if (try_consume(c, LPAREN))
	{
		while (true)
		{
			Expr* expr = null;
			bool next_is_rparen = c.lexer.token_type == RPAREN;
			// c3c: goto PARSE_EXPR
			bool parse_as_expr = false;
			switch (c.tok)
			{
				case PLUS:
				case MINUS:
				case STAR:
				case DIV:
				case MOD:
				case BIT_NOT:
				case BIT_OR:
				case BIT_XOR:
				case SHL:
				case SHR:
				case EQEQ:
				case LESS:
				case BIT_AND_ASSIGN:
				case BIT_OR_ASSIGN:
				case BIT_XOR_ASSIGN:
				case PLUS_ASSIGN:
				case MINUS_ASSIGN:
				case MULT_ASSIGN:
				case DIV_ASSIGN:
				case MOD_ASSIGN:
				case SHL_ASSIGN:
				case SHR_ASSIGN:
					if (!next_is_rparen)
					{
						parse_as_expr = true;
						break;
					}
					expr = parse_overload_from_token(c, c.tok);
				case AMP:
					if (next_is_rparen)
					{
						expr = parse_overload_from_token(c, c.tok);
						break;
					}
					// &[]
					expr = expr_new_token(c, OPERATOR_CHARS);
					expr.resolve_status = DONE;
					advance(c);
					if (!expect_advance(c, LBRACKET)) return false;
					if (!expect_advance(c, RBRACKET)) return false;
					expr.overload_expr = OVERLOAD_ELEMENT_REF;
					range_extend_prev(c, expr.loc);
				case LBRACKET:
					// [] and []=
					expr = expr_new_token(c, OPERATOR_CHARS);
					expr.resolve_status = DONE;
					advance(c);
					if (!expect_advance(c, RBRACKET)) return false;
					expr.overload_expr = try_consume(c, EQ) ? OVERLOAD_ELEMENT_SET : OVERLOAD_ELEMENT_AT;
					range_extend_prev(c, expr.loc);
				case NOT_EQUAL:
				case LESS_EQ:
				case GREATER:
				case GREATER_EQ:
					return @print_error_here(c, "For comparisons, use '<' and '==', other comparison operations will be derived from those.");
				case PLUSPLUS:
				case MINUSMINUS:
					return @print_error_here(c, "Increment and decrement operators '++' and '--' cannot be directly overloaded, use '+=' and '-=' instead.");
				case DOT:
					return @print_error_here(c, "You cannot overload '.'.");
				default:
					parse_as_expr = true;
			}
			if (parse_as_expr)
			{
				// PARSE_EXPR:
				expr = parse_constant_expr(c);
				if (!expr_ok(expr)) return false;
			}
			@vec_add(&list, expr);
			if (try_consume(c, RPAREN)) break;
			if (!expect_advance(c, COMMA)) return false;
		}
	}

	attr.exprs = list;
	*attribute_ref = attr;
	return true;
}

<* Parse global attributes, setting visibility defaults from the parent unit. *>
fn bool parse_attributes_for_global(ParseContext* c, Decl* decl)
{
	Visibility visibility = c.unit.default_visibility;
	bool can_be_weak = decl.decl_kind == FUNC || decl.decl_kind == VAR;
	bool is_weak = c.unit.default_is_weak && can_be_weak;
	// Transfer the test / benchmark properties
	if (decl.decl_kind == FUNC && !decl.func_decl.attr_interface_method && !decl.func_decl.type_parent)
	{
		decl.func_decl.attr_test = c.unit.test_by_default;
		decl.func_decl.attr_benchmark = c.unit.benchmark_by_default;
	}
	decl.is_export = c.unit.export_by_default;
	bool is_builtin = false;
	bool is_cond;
	bool is_feat_cond;
	bool can_be_generic = decl_inherits_module_generic(decl);
	Decl* generics = parse_generic_decl(c);
	if (!decl_ok(generics)) return false;
	bool is_method = decl_is_fn_macro(decl) && decl.func_decl.type_parent;
	bool is_enum_const = decl.decl_kind == ENUM_CONSTANT;
	if (!parse_attributes(c, &decl.attributes, is_enum_const ? null : &visibility, decl_needs_prefix(decl) ? &is_builtin : null, &is_cond, is_method ? "for method declarations" : NO_STRING, &is_weak, &is_feat_cond)) return false;
	if (generics)
	{
		if (!can_be_generic)
		{
			@print_error_at(decl.loc, "This declaration cannot be generic.");
			return false;
		}
		parse_attach_generics(c, generics);
	}
	if (!generics && c.unit.default_generic_section && can_be_generic)
	{
		generics = c.unit.default_generic_section;
	}
	if (generics)
	{
		decl.generic_id = declid(generics);
		decl.is_template = true;
	}
	decl.is_cond = is_cond;
	decl.is_feat_cond = is_feat_cond;
	if (is_weak)
	{
		decl.is_weak_link = true;
		decl.is_weak = true;
	}
	else if (c.unit.is_interface_file)
	{
		decl.is_weak = true;
	}
	decl.is_autoimport = is_builtin;
	decl.visibility = visibility;
	return true;
}

fn bool warn_method_visibility(Attr* attr, String mod, String err) @inline
{
	switch (compiler.build.warnings.method_visibility)
	{
		case WARN:
			@sema_warning_at(attr.loc, "'%s' modifiers are ignored %s.", mod, err);
			return true;
		case ERROR:
			@print_error_at(attr.loc, "'%s' modifiers are not allowed %s.", mod, err);
			return false;
		default:
			return true;
	}
}

fn bool parse_attribute_list(ParseContext* c, Attr*[]* attributes_ref, Visibility* visibility_ref, bool* builtin_ref, bool* cond_ref, bool use_comma, String reject_visibility, bool* weak_ref, bool* feat_cond_ref) @inline
{
	// c3c: Visibility visibility = -1;
	bool has_visibility = false;
	if (cond_ref) *cond_ref = false;
	if (feat_cond_ref) *feat_cond_ref = false;
	while (true)
	{
		Attr* attr;
		if (!parse_attribute(c, &attr, false)) return false;
		if (!attr) return true;
		// c3c: Visibility parsed_visibility = (Visibility)-1;
		bool has_parsed_visibility = false;
		Visibility parsed_visibility = PUBLIC;
		// c3c: goto ADD
		bool skip_repeat_check = false;
		if (!attr.is_custom)
		{
			// This is important: if we would allow user defined attributes,
			// ordering between visibility of attributes would be complex.
			// since there is little
			bool parsed_builtin = false;
			switch (attr.attr_kind)
			{
				case PUBLIC:
					if (reject_visibility.ptr && attributes_ref)
					{
						if (!warn_method_visibility(attr, "@public", reject_visibility)) return false;
					}
					else if (reject_visibility.ptr)
					{
						@print_error_at(attr.loc, "Visibility modifiers are not allowed %s.", reject_visibility);
						return false;
					}
					parsed_visibility = PUBLIC;
					has_parsed_visibility = true;
				case PRIVATE:
					if (reject_visibility.ptr && attributes_ref)
					{
						if (!warn_method_visibility(attr, "@private", reject_visibility)) return false;
					}
					else if (reject_visibility.ptr)
					{
						@print_error_at(attr.loc, "Visibility modifiers are not allowed %s.", reject_visibility);
						return false;
					}
					parsed_visibility = PRIVATE;
					has_parsed_visibility = true;
				case WEAK:
					if (!weak_ref)
					{
						@print_error_at(attr.loc, "'@weak' is not allowed %s.", reject_visibility.ptr ? reject_visibility : "on this declaration.");
						return false;
					}
					*weak_ref = true;
					continue;
				case LOCAL:
					if (reject_visibility.ptr && attributes_ref)
					{
						if (!warn_method_visibility(attr, "@local", reject_visibility)) return false;
					}
					else if (reject_visibility.ptr)
					{
						@print_error_at(attr.loc, "Visibility modifiers are not allowed %s.", reject_visibility);
						return false;
					}
					parsed_visibility = LOCAL;
					has_parsed_visibility = true;
				case BUILTIN:
					parsed_builtin = true;
				case FEAT:
					if (!feat_cond_ref) { @print_error_at(attr.loc, "'%s' cannot be used here.", attr.name); return false; }
					*feat_cond_ref = true;
				case IF:
					if (!cond_ref) { @print_error_at(attr.loc, "'%s' cannot be used here.", attr.name); return false; }
					*cond_ref = true;
				default:
					break;
			}
			if (parsed_builtin)
			{
				if (!builtin_ref) { @print_error_at(attr.loc, "'@builtin' cannot be used here."); return false; }
				*builtin_ref = true;
				continue;
			}
			if (has_parsed_visibility)
			{
				if (!visibility_ref) { @print_error_at(attr.loc, "'%s' cannot be used here.", attr.name); return false; }
				if (has_visibility) { @print_error_at(attr.loc, "Only a single visibility attribute may be added."); return false; }
				*visibility_ref = parsed_visibility;
				has_visibility = true;
				continue;
			}
			if (attr.attr_kind == TAG || attr.attr_kind == FEAT) skip_repeat_check = true;
		}
		if (!skip_repeat_check)
		{
			String name = attr.name;
			foreach (other_attr : *attributes_ref)
			{
				if (other_attr.name.ptr == name.ptr) { @print_error_at(attr.loc, "Repeat of attribute '%s' here.", name); return false; }
			}
		}
		// ADD:
		@vec_add(attributes_ref, attr);
		if (use_comma && !try_consume(c, COMMA)) break;
	}
	return true;
}

fn Decl* parse_generic_decl(ParseContext* c)
{
	SourceLoc start = c.span;
	if (!try_consume(c, LESS)) return null;
	if (try_consume(c, GREATER))
	{
		@print_error_here(c, "The generic parameter list cannot be empty, it needs at least one element.");
		return poisoned_decl;
	}

	String[] tokens;

	// No params
	while (true)
	{
		switch (c.tok)
		{
			case TYPE_IDENT:
			case CONST_IDENT:
				break;
			case COMMA:
				@print_error_here(c, "Unexpected ','");
				return poisoned_decl;
			case IDENT:
				@print_error_here(c, "The generic parameter must be a type or a constant.");
				return poisoned_decl;
			case CT_IDENT:
			case CT_TYPE_IDENT:
				@print_error_here(c, "The generic parameter cannot be a $-prefixed name.");
				return poisoned_decl;
			default:
				@print_error_here(c, "Only generic parameters are allowed here.");
				return poisoned_decl;
		}
		@vec_add(&tokens, symstr(c));
		advance(c);
		if (!try_consume(c, COMMA))
		{
			if (!@consume(c, GREATER, "Expected '>'.")) return poisoned_decl;
			Decl* decl = decl_new_loc(GENERIC, "", extend_loc_with_token(&start, &c.prev_span));
			decl.generic_decl.parameters = tokens;
			return decl;
		}
	}
}

<*
 attribute_list ::= attribute*

 Patch visibility and builtin attributes immediately.

 @return "true if parsing succeeded, false if recovery is needed"
*>
fn bool parse_attributes(ParseContext* c, Attr*[]* attributes_ref, Visibility* visibility_ref, bool* builtin_ref, bool* cond_ref, String reject_visibility, bool* weak_ref, bool* feat_cond_ref)
{
	return parse_attribute_list(c, attributes_ref, visibility_ref, builtin_ref, cond_ref, false, reject_visibility, weak_ref, feat_cond_ref);
}

<*
 global_declaration ::= TLOCAL? optional_type IDENT (('=' expression)? | (',' IDENT)* opt_attributes) ';'

 @return "true if parsing succeeded"
*>
fn Decl* parse_global_declaration(ParseContext* c) @inline
{
	bool threadlocal = try_consume(c, TLOCAL);

	TypeInfo* type = parse_optional_type(c);
	if (!type_info_ok(type)) return poisoned_decl;

	if (tok_is(c, CONST_IDENT))
	{
		@print_error_here(c, "This looks like a constant variable, did you forget 'const'?");
		return poisoned_decl;
	}

	Decl* decl;
	Decl*[] decls;
	// Parse IDENT (',' IDENT)*
	while (true)
	{
		decl = decl_new_var_current(c, type, GLOBAL);
		decl.docs = decl_from_contract_description(&c.contracts);
		// Update threadlocal setting
		decl.var_decl.is_threadlocal = threadlocal;
		if (!try_consume(c, IDENT))
		{
			if (token_is_some_ident(c.tok))
			{
				if ((c.tok == TYPE_IDENT || c.tok == CONST_IDENT) &&
					c.lexer.token_type == LPAREN)
				{
					@print_error_here(c, "This looks like the beginning of a C style function declaration. Unfortunately it seems to be missing the initial 'fn' and the function name does not start with a lower case.");
					return poisoned_decl;
				}
				@print_error_here(c, "I expected a variable name here, but global variables need to start with lower case.");
				return poisoned_decl;
			}
			@print_error_here(c, "The name of a global variable was expected here");
			return poisoned_decl;
		}
		if (!try_consume(c, COMMA)) break;
		@vec_add(&decls, decl);
	}
	// Add the last, or we miss it.
	if (decls.len) @vec_add(&decls, decl);

	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	// If we get '=' we can't have multiple idents.
	if (try_consume(c, EQ))
	{
		if (decls.len)
		{
			@print_error_here(c, "Initialization is not allowed with multiple declarations.");
			return poisoned_decl;
		}
		if (!parse_decl_initializer(c, decl)) return poisoned_decl;
	}
	else if (!decl.attributes.len)
	{
		if (tok_is(c, LPAREN) && !threadlocal)
		{
			// Guess we forgot `fn`? -> improve error reporting.
			@print_error_at(type.loc, "This looks like the beginning of a function declaration but it's missing the initial `fn`. Did you forget it?");
			return poisoned_decl;
		}
		if (tok_is(c, LBRACKET))
		{
			// Maybe we were doing int foo[4] = ...
			@print_error_here(c, "This looks like a declaration of the format 'int foo[4]' which is c-style array declaration. In C3, you need to use something like 'int[4] foo' instead.");
			return poisoned_decl;
		}
	}
	if (!consume_eos(c)) return poisoned_decl;
	Attr*[] attributes = decl.attributes;
	// Copy the attributes to the other variables.

	if (attributes.len)
	{
		foreach (d : decls)
		{
			if (d == decl) continue;
			d.attributes = copy_attributes_single(attributes);
		}
	}
	int generics_id = decl.is_template ? (int)decl.generic_id : -1;
	if (generics_id > -1)
	{
		foreach (d : decls)
		{
			if (d == decl) continue;
			d.generic_id = (DeclId)generics_id;
			d.is_template = true;
		}
	}
	// If we have multiple decls, then we return that as a bundled decl_globals
	if (decls.len)
	{
		decl = decl_calloc();
		decl.decl_kind = GROUP;
		decl.decls = decls;
		if (generics_id > -1)
		{
			decl.generic_id = (DeclId)generics_id;
			decl.is_template = true;
		}
		return decl;
	}
	return decl;
}

<* enum_param_decl ::= type IDENT attributes? *>
fn bool parse_enum_param_decl(ParseContext* c, Decl*[]* parameters) @inline
{
	TypeInfo* type = parse_optional_type(c);
	if (!type_info_ok(type)) return false;
	if (type.optional) { @print_error_at(type.loc, "Parameters may not be optional."); return false; }
	Decl* param = decl_new_var_current(c, type, PARAM);
	if (!try_consume(c, IDENT))
	{
		if (token_is_keyword_ident(c.tok)) return @print_error_here(c, "Keywords cannot be used as member names.");
		if (token_is_some_ident(c.tok)) return @print_error_here(c, "Expected a name starting with a lower-case letter.");
		return @print_error_here(c, "Expected a member name here.");
	}
	if (!parse_attributes(c, &param.attributes, null, null, null, "on parameter declarations", null, null)) return false;
	@vec_add(parameters, param);
	range_extend_prev(c, param.loc);
	return true;
}

fn bool parse_next_is_typed_parameter(ParseContext* c, ParameterParseKind parse_kind)
{
	switch (c.tok)
	{
		case IDENT:
			return peek(c) == SCOPE;
		case VOID..UNTYPEDLIST:
		case TYPE_IDENT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
			return true;
		case CT_TYPE_IDENT:
			if (parse_kind == LAMBDA) return true;
			if (parse_kind != CALL) return false;
			switch (peek(c))
			{
				case IDENT:
				case HASH_IDENT:
				case CT_IDENT:
					return true;
				default:
					return false;
			}
		default:
			return false;
	}
}

fn bool is_end_of_param_list(ParseContext* c) @inline
{
	return tok_is(c, EOS) || tok_is(c, RPAREN);
}

<*
 parameters ::= (parameter (',' parameter)*)?
 non_type_ident = IDENT | HASH_IDENT | CT_IDENT
 parameter ::= type ELLIPSIS? (non_type_ident ('=' expr))?
             | ELLIPSIS (CT_TYPE_IDENT | non_type_ident ('=' expr)?)?
*>
fn bool parse_parameters(ParseContext* c, Decl*[]* params_ref, Variadic* variadic, int* vararg_index_ref, ParameterParseKind parse_kind)
{
	Decl*[] params;
	bool var_arg_found = false;
	while (!is_end_of_param_list(c))
	{
		bool ellipsis = try_consume(c, ELLIPSIS);

		// Check for "raw" variadic arguments. This is allowed on C functions and macros.
		if (ellipsis)
		{
			// In the future maybe this
			if (!is_end_of_param_list(c) && !tok_is(c, COMMA))
			{
				return @print_error_here(c, "Expected ')' here.");
			}
			// Variadics might not be allowed
			if (!variadic)
			{
				return @print_error_last(c, "Variadic parameters are not allowed.");
			}
			// Check that we only have one variadic parameter.
			if (var_arg_found)
			{
				return @print_error_last(c, "Only a single variadic parameter is allowed.");
			}
			// Set the variadic type and insert a dummy argument.
			*variadic = RAW;
			*vararg_index_ref = (int)params.len;
			var_arg_found = true;
			@vec_add(&params, (Decl*)null);
			if (!try_consume(c, COMMA)) break;
			continue;
		}

		// Now we have the following possibilities: "foo", "Foo foo", "Foo... foo", "foo...", "Foo"
		TypeInfo* type = null;
		if (parse_next_is_typed_parameter(c, parse_kind))
		{
			// Parse the type,
			type = parse_optional_type(c);
			if (!type_info_ok(type)) return false;
			ellipsis = try_consume(c, ELLIPSIS);
			// We might have Foo...
			if (ellipsis)
			{
				if (!variadic)
				{
					@print_error_here(c, "Variadic arguments are not allowed.");
					return false;
				}
				if (var_arg_found)
				{
					SourceLoc loc = extend_loc_with_token(sourcelocptr(type.loc), &c.prev_span);
					@print_error_at_loc(&loc, "Only a single variadic parameter is allowed.");
					return false;
				}
				var_arg_found = true;
				*variadic = TYPED;
			}
		}
		// We have parsed the optional type, next get the optional variable name
		VarDeclKind param_kind;
		String name = NO_STRING;
		SourceLoc loc = c.span;
		bool no_name = false;
		bool ref = false;
		// c3c: goto CHECK_ELLIPSIS
		bool check_ellipsis = false;
		switch (c.tok)
		{
			case CONST_IDENT:
			case CT_CONST_IDENT:
				// We reserve upper case constants for globals.
				return @print_error_here(c, "Parameter names may not be all uppercase.");
			case CT_IDENT:
				// ct_var $foo
				name = symstr(c);
				advance_and_verify(c, CT_IDENT);
				param_kind = PARAM_CT;
				check_ellipsis = true;
			case IDENT:
				// normal "foo"
				name = symstr(c);
				param_kind = PARAM;
				advance_and_verify(c, IDENT);
				// Check for "foo..." which defines an implicit "any" vararg
				check_ellipsis = true;
			case AMP:
				// reference &foo
				advance_and_verify(c, AMP);
				name = symstr(c);
				if (!try_consume(c, IDENT))
				{
					return @print_error_here(c, "A regular variable name, e.g. 'foo' was expected after the '&'.");
				}
				if (params.len > 0)
				{
					return @print_error_here(c, "Only the first parameter may be a self parameter using '&'.");
				}
				// This will catch Type... &foo and &foo..., neither is allowed.
				if (ellipsis || tok_is(c, ELLIPSIS))
				{
					return @print_error_last(c, "'&foo' parameters may not be followed by '...’");
				}

				// Span includes the "&"
				loc = extend_loc_with_token(&loc, &c.span);
				ref = true;
				param_kind = PARAM;
			case HASH_IDENT:
				// expression #foo
				name = symstr(c);
				advance_and_verify(c, HASH_IDENT);
				if (ellipsis || tok_is(c, ELLIPSIS))
				{
					return @print_error_last(c, "Expression parameters may not be vaargs, use untyped macro vaargs '...' instead.");
				}
				param_kind = PARAM_EXPR;
				// Compile time type $Type
			case CT_TYPE_IDENT:
				name = symstr(c);
				advance_and_verify(c, CT_TYPE_IDENT);
				if (ellipsis || tok_is(c, ELLIPSIS))
				{
					return @print_error_last(c, "Expression parameters may not be vaargs, use untyped macro vaargs '...' instead.");
				}
				param_kind = PARAM_CT_TYPE;
			case COMMA:
			case EOS:
			case RPAREN:
				// Handle "Type..." and "Type"
				if (!type && !ellipsis)
				{
					@print_error_after(&c.prev_span, "Expected a parameter.");
					return false;
				}
				if (parse_kind == MACRO && ellipsis && type)
				{
					@print_error_after(&c.prev_span, "A typed macro vaarg must have a parameter name.");
				}
				no_name = true;
				loc = c.prev_span;
				param_kind = PARAM;
			default:
				// c3c: case TOKEN_CONST, then FALLTHROUGH to default.
				if (c.tok == CONST && token_is_any_type(peek(c)))
				{
					return @print_error_here(c, "'const' is not allowed here, did you try to make a C style const parameter? In that case, consider using contracts with '@param [in]' for the parameter.");
				}
				if (token_is_keyword(c.tok))
				{
					return @print_error_here(c, "'%s' is a keyword and cannot be used as a parameter name.", symstr(c));
				}
				return @print_error_here(c, "Expected a parameter.");
		}
		if (check_ellipsis)
		{
			// CHECK_ELLIPSIS:
			if (try_consume(c, ELLIPSIS))
			{
				// Did we get Foo... foo...
				if (ellipsis)
				{
					return @print_error_last(c, "Unexpected '...' following a vararg declaration.");
				}
				ellipsis = true;
				if (!variadic)
				{
					loc = extend_loc_with_token(&loc, &c.prev_span);
					@print_error_at_loc(&loc, "Variadic parameters are not allowed.");
					return false;
				}
				// Did we get Foo foo...? If so then that's an error.
				if (type)
				{
					return @print_error_last(c, "For typed vaargs '...', needs to appear after the type.");
				}
				if (param_kind == PARAM_CT)
				{
					return @print_error_last(c, "Untyped constant vaargs are not supported. Use raw macro vaargs instead.");
				}
				if (var_arg_found)
				{
					loc = extend_loc_with_token(&loc, &c.prev_span);
					@print_error_at_loc(&loc, "Only a single variadic parameter is allowed.");
					return false;
				}
				// This is "foo..."
				*variadic = ANY;
				// We generate the type as type_any
				type = type_info_new_base(type_any, make_loc(c.span));
			}
		}
		if (type && type.optional)
		{
			@print_error_at(type.loc, "Parameters may not be optional.");
			return false;
		}
		Decl* param = decl_new_var_loc(name, &loc, type, param_kind);
		param.var_decl.type_info = type ? type_infoid(type) : 0;
		param.var_decl.self_addr = ref;
		if (!parse_attributes(c, &param.attributes, null, null, null, "on parameters", null, null)) return false;
		if (!no_name)
		{
			if (try_consume(c, EQ))
			{
				if (try_consume(c, ELLIPSIS))
				{
					if (parse_kind != MACRO)
					{
						return @print_error_here(c, "Optional arguments with '...' is only allowed as macro arguments.");
					}
					param.var_decl.no_init = true;
				}
				else
				{
					if (!parse_decl_initializer(c, param)) return false;
				}
			}
		}
		if (ellipsis)
		{
			var_arg_found = true;
			param.var_decl.vararg = ellipsis;
			*vararg_index_ref = (int)params.len;
		}
		@vec_add(&params, param);
		if (!try_consume(c, COMMA)) break;
	}
	if (tok_is(c, LBRACE) || tok_is(c, STAR) || tok_is(c, LBRACKET))
	{
		return @print_error_last(c, "Expected the name of a type here. ('%s' in a parameter list must follow a type).", token_type_to_string(c.tok));
	}

	*params_ref = params;
	return true;
}

<* fn_parameter_list ::= '(' parameters ')' *>
fn bool parse_fn_parameter_list(ParseContext* c, Signature* signature) @inline
{
	Decl*[] decls;
	if (!expect_advance(c, LPAREN)) return false;
	Variadic variadic = NONE;
	int vararg_index = -1;
	if (!parse_parameters(c, &decls, &variadic, &vararg_index, FUNC)) return false;
	if (!expect_advance(c, RPAREN)) return false;
	signature.vararg_index = vararg_index < 0 ? (int)decls.len : vararg_index;
	signature.params = decls;
	signature.variadic = variadic;

	return true;
}

// --- Parse types

fn bool parse_element_contract(ParseContext* c, ContractDescription* contracts, String error)
{
	if (!parse_contracts(c, contracts)) return false;
	if (!contracts.has_contracts) return true;
	@print_error_at(contracts.first_contract, "No constraints are allowed on %s.", error);
	return false;
}

fn void attach_deprecation_from_contract(ParseContext* c, ContractDescription* contract, Decl* decl) @inline
{
	if (contract.deprecated) @vec_add(&decl.attributes, contract.deprecated);
	contract.deprecated = null;
}

<*
 Expect pointer to after '{'

 struct_body ::= '{' struct_declaration_list '}'

 struct_declaration_list ::= struct_member_decl+

 struct_member_decl ::=
        (type_expression identifier_list opt_attributes ';')
 		| struct_or_union IDENT opt_attributes struct_body
		| struct_or_union opt_attributes struct_body
 		| BITSTRUCT IDENT ':' type opt_attributes struct_body
		| BITSTRUCT ':' type opt_attributes struct_body

 @param [&inout] c : "the parse context"
 @param [&inout] parent : "the parent of the struct"
*>
fn bool parse_struct_body(ParseContext* c, Decl* parent)
{
	if (!expect_advance(c, LBRACE)) return false;

	assert(decl_is_struct_type(parent));
	ArrayIndex index = 0;
	while (!tok_is(c, RBRACE))
	{
		ContractDescription contracts = {};
		if (!parse_element_contract(c, &contracts, "struct/union members")) return false;
		TokenType token_type = c.tok;
		if (token_type == STRUCT || token_type == UNION || token_type == BITSTRUCT)
		{
			DeclKind decl_kind = decl_from_token(token_type);
			Decl* member;
			if (peek(c) != IDENT)
			{
				member = decl_new_with_type(NO_STRING, &c.span, decl_kind);
				advance(c);
				if (token_is_some_ident(c.tok))
				{
					return @print_error_here(c, "The name of an inner struct or union must be a name starting with a lowercase letter.");
				}
			}
			else
			{
				advance(c);
				member = decl_new_with_type(symstr(c), &c.span, decl_kind);
				advance_and_verify(c, IDENT);
			}
			scratch_buffer_clear();
			scratch_buffer_append(parent.type.name);
			scratch_buffer_append(".");
			if (member.name.ptr)
			{
				scratch_buffer_append(member.name);
			}
			else
			{
				scratch_buffer_append_unsigned_int((ulong)index);
			}
			member.type.name = scratch_buffer_interned();

			member.strukt.parent = declid(parent);
			if (decl_kind == BITSTRUCT)
			{
				if (!@consume(c, COLON, "':' followed by bitstruct type (e.g. 'int') was expected here.")) return false;
				TypeInfo* container_type = parse_optional_type_no_generic(c);
				if (!type_info_ok(container_type)) return false;
				member.strukt.container_type = container_type;
				if (!parse_attributes_for_global(c, member)) return false;
				if (!parse_bitstruct_body(c, member)) return false;
			}
			else
			{
				bool is_cond;
				bool is_feat_cond;
				if (!parse_attributes(c, &member.attributes, null, null, &is_cond, "on struct and union fields", null, &is_feat_cond)) return false;
				member.is_cond = is_cond;
				member.is_feat_cond = is_feat_cond;
				if (!parse_struct_body(c, member)) return false;
			}
			member.docs = decl_from_contract_description(&contracts);
			attach_deprecation_from_contract(c, &contracts, member);
			@vec_add(&parent.strukt.members, member);
			index++;
			if (index > MAX_MEMBERS)
			{
				@print_error_at(member.loc, "Can't add another member: the count would exceed maximum of %d elements.", MAX_MEMBERS);
				return false;
			}
			continue;
		}
		bool was_inline = false;
		if (tok_is(c, INLINE))
		{
			if (parent.decl_kind != STRUCT)
			{
				return @print_error_here(c, "Only structs may have 'inline' elements, did you make a mistake?");
			}
			if (index > 0)
			{
				return @print_error_last(c, "Only the first element may be 'inline', did you order your fields wrong?");
			}
			parent.is_substruct = true;
			was_inline = true;
			advance(c);
		}
		TypeInfo* type = parse_type(c);
		if (!type_info_ok(type)) return false;

		sz first_member_index = (sz)parent.strukt.members.len;
		while (true)
		{
			if (!tok_is(c, IDENT)) return @print_error_here(c, "A valid member name was expected here.");

			Decl* member = decl_new_var_current(c, type, MEMBER);
			member.docs = decl_from_contract_description(&contracts);
			@vec_add(&parent.strukt.members, member);
			index++;
			if (index > MAX_MEMBERS)
			{
				@print_error_at(member.loc, "Can't add another member: the count would exceed maximum of %d elements.", MAX_MEMBERS);
				return false;
			}
			advance(c);
			bool is_cond;
			bool is_feat_cond;
			if (!parse_attributes(c, &member.attributes, null, null, &is_cond, "on struct and union fields", null, &is_feat_cond)) return false;
			member.is_cond = is_cond;
			member.is_feat_cond = is_feat_cond;
			if (!try_consume(c, COMMA)) break;
			if (was_inline)
			{
				@print_error_at(member.loc, "'inline' can only be applied to a single member, so please define it on its own line.");
				return false;
			}
			if (token_is_any_type(c.tok))
			{
				return @print_error_last(c, "Did you accidentally use ',' rather than ';' between your declarations?");
			}
		}
		Decl*[] members = parent.strukt.members;
		sz last_index = (sz)members.len - 1;
		if (last_index != first_member_index)
		{
			Decl* last_member = members[last_index];
			Attr*[] attributes = last_member.attributes;
			if (attributes.len)
			{
				// Copy attributes
				bool is_cond = last_member.is_cond;
				bool is_feat_cond = last_member.is_feat_cond;
				for (sz i = first_member_index; i < last_index; i++)
				{
					Decl* member = members[i];
					if (is_cond) member.is_cond = true;
					if (is_feat_cond) member.is_feat_cond = true;
					assert(!member.attributes.len);
					member.attributes = copy_attributes_single(attributes);
				}
			}
		}
		if (!consume_eos(c)) return false;
	}
	advance_and_verify(c, RBRACE);
	return true;
}

<* typedef_declaration ::= 'typedef' TYPE_IDENT opt_interfaces attributes? '=' 'inline'? type ';' *>
fn Decl* parse_typedef_declaration(ParseContext* c) @inline
{
	advance(c);
	//advance_and_verify(c, TOKEN_TYPEDEF);

	Decl* decl = decl_new_with_type(symstr(c), &c.span, TYPEDEF);
	decl.docs = decl_from_contract_description(&c.contracts);

	if (!consume_type_name(c, "distinct type")) return poisoned_decl;
	if (!parse_interface_impls(c, &decl.interfaces)) return poisoned_decl;

	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	decl.type.type_kind = TYPEDEF;
	decl.decl_kind = TYPEDEF;

	if (!expect_advance(c, EQ)) return poisoned_decl;

	decl.is_substruct = try_consume(c, INLINE);

	if (tok_is(c, FN))
	{
		@print_error_here(c, "A distinct type cannot define a new function type, but you can make a distinct type from an existing function type, e.g. `alias FooFn = fn void(); typedef Bar = FooFn;`");
		return poisoned_decl;
	}
	// 2. Now parse the type which we know is here.
	TypeInfo* distinct = parse_optional_type(c);
	if (!type_info_ok(distinct)) return poisoned_decl;
	decl.distinct = distinct;

	while (tok_is(c, AT_IDENT))
	{
		String name = symstr(c);
		if (name.ptr == kw_at_align.ptr)
		{
			advance_and_verify(c, AT_IDENT);
			if (!expect_advance(c, LPAREN)) return poisoned_decl;
			Expr* align = parse_expr(c);
			if (!expr_ok(align)) return poisoned_decl;
			decl.distinct_align = align;
			if (!expect_advance(c, RPAREN)) return poisoned_decl;
		}
		else
		{
			@print_error_here(c, "Expected only attribute '@align' here, if you want to add an attribute to the typedef itself, place it before the '='.");
			return poisoned_decl;
		}
	}
	range_extend_prev(c, decl.loc);
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

<* struct_declaration ::= struct_or_union TYPE_IDENT opt_interfaces opt_attributes struct_body *>
fn Decl* parse_struct_declaration(ParseContext* c) @inline
{
	TokenType type = c.tok;

	advance(c);
	String type_name = type == STRUCT ? "struct" : "union";

	Decl* decl = decl_new_with_type(symstr(c), &c.span, decl_from_token(type));
	decl.docs = decl_from_contract_description(&c.contracts);

	if (!consume_type_name(c, type_name)) return poisoned_decl;
	if (!parse_interface_impls(c, &decl.interfaces)) return poisoned_decl;
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	if (!parse_struct_body(c, decl)) return poisoned_decl;

	return decl;
}

<*
 bitstruct_body ::= '{' bitstruct_def* | bitstruct_simple_def* '}'

 bitstruct_def ::= base_type IDENT ':' constant_expr (DOTDOT constant_expr)? ';'
 bitstruct_simple_def ::= base_type IDENT ';'
*>
fn bool parse_bitstruct_body(ParseContext* c, Decl* decl) @inline
{
	if (!expect_advance(c, LBRACE)) return false;

	bool is_consecutive = false;
	while (!try_consume(c, RBRACE))
	{
		ContractDescription contracts = {};
		if (!parse_element_contract(c, &contracts, "bitstruct members")) return decl_poison(decl);
		TypeInfo* type = parse_base_type(c);
		if (!type_info_ok(type)) return false;
		Decl* member_decl = decl_new_var_current(c, type, BITMEMBER);
		attach_deprecation_from_contract(c, &contracts, member_decl);
		if (!try_consume(c, IDENT))
		{
			if (try_consume(c, CONST_IDENT) || try_consume(c, TYPE_IDENT))
			{
				@print_error_last(c, "Expected a field name with an initial lower case.");
				return false;
			}
			@print_error_here(c, "Expected a field name at this position.");
			return false;
		}
		if (tok_is(c, EOS) || tok_is(c, AT_IDENT))
		{
			if (!is_consecutive)
			{
				if (decl.strukt.members.len)
				{
					@print_error_at(member_decl.loc, "Bitstructs either have bit ranges for all members, or no members have ranges – mixing is not permitted. Either add a range to this member or remove ranges from the other member(s).");
					return false;
				}
				is_consecutive = true;
			}
			bool is_cond;
			bool is_feat_cond;
			if (!parse_attributes(c, &member_decl.attributes, null, null, &is_cond, "on bitstruct fields", null, &is_feat_cond)) return false;
			member_decl.is_cond = is_cond;
			member_decl.is_feat_cond = is_feat_cond;
			if (!expect_advance(c, EOS)) return false;
			int index = (int)decl.strukt.members.len;
			member_decl.var_decl.start_bit = index;
			member_decl.var_decl.end_bit = index;
			@vec_add(&decl.strukt.members, member_decl);
			continue;
		}
		if (!expect_advance(c, COLON)) return false;
		Expr* start = parse_constant_expr(c);
		if (!expr_ok(start)) return false;
		member_decl.var_decl.start = start;
		member_decl.var_decl.bit_is_expr = true;
		if (try_consume(c, DOTDOT))
		{
			Expr* end = parse_constant_expr(c);
			if (!expr_ok(end)) return false;
			member_decl.var_decl.end = end;
		}
		else
		{
			member_decl.var_decl.end = null;
		}
		bool is_cond;
		bool is_feat_cond;
		if (!parse_attributes(c, &member_decl.attributes, null, null, &is_cond, "on bitstruct fields", null, &is_feat_cond)) return false;
		member_decl.is_cond = is_cond;
		member_decl.is_feat_cond = is_feat_cond;
		if (!consume_eos(c)) return false;
		if (is_consecutive)
		{
			@print_error_at(member_decl.var_decl.start.loc, "Bitstructs either have bit ranges for all members, or no members have ranges – mixing is not permitted. Either remove this range, or add ranges to all other members.");
			return false;
		}
		@vec_add(&decl.strukt.members, member_decl);
	}
	decl.strukt.consecutive = is_consecutive;
	return true;
}

fn bool parse_interface_body(ParseContext* c, Decl* interface_) @inline
{
	if (!expect_advance(c, LBRACE)) return false;
	Decl*[] fns;
	while (!try_consume(c, RBRACE))
	{
		ContractDescription method_contracts = {};
		if (!parse_contracts(c, &method_contracts)) return false;
		if (!tok_is(c, FN))
		{
			return @print_error_here(c, "Interfaces can only have function declarations, and they must start with 'fn' as usual.");
		}
		ContractDescription saved = c.contracts;
		c.contracts = method_contracts;
		Decl* interface_fn = parse_func_definition(c, INTERFACE);
		if (!decl_ok(interface_fn)) return false;
		c.contracts = saved;
		@vec_add(&fns, interface_fn);
	}
	interface_.interface_methods = fns;
	return true;
}

<* interface_declaration ::= 'interface' TYPE_IDENT ':' (TYPE_IDENT (',' TYPE_IDENT) interface_body *>
fn Decl* parse_interface_declaration(ParseContext* c) @inline
{
	advance_and_verify(c, INTERFACE);
	Decl* decl = decl_new_with_type(symstr(c), &c.span, INTERFACE);
	decl.docs = decl_from_contract_description(&c.contracts);
	if (!consume_type_name(c, "interface")) return poisoned_decl;
	TypeInfo*[] parents;
	if (try_consume(c, COLON))
	{
		do
		{
			TypeInfo* type = parse_optional_type_no_generic(c);
			if (!type_info_ok(type)) return poisoned_decl;
			@vec_add(&parents, type);
		} while (try_consume(c, COMMA));
	}
	decl.interfaces = parents;

	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	if (!parse_interface_body(c, decl)) return poisoned_decl;
	return decl;
}

<* bitstruct_declaration ::= 'bitstruct' TYPE_IDENT ':' type bitstruct_body *>
fn Decl* parse_bitstruct_declaration(ParseContext* c) @inline
{
	advance_and_verify(c, BITSTRUCT);

	Decl* decl = decl_new_with_type(symstr(c), &c.span, BITSTRUCT);
	decl.docs = decl_from_contract_description(&c.contracts);

	if (!consume_type_name(c, "bitstruct")) return poisoned_decl;

	if (!parse_interface_impls(c, &decl.interfaces)) return poisoned_decl;

	if (!@consume(c, COLON, "':' followed by bitstruct type (e.g. 'int') was expected here.")) return poisoned_decl;

	TypeInfo* type = parse_optional_type_no_generic(c);
	if (!type_info_ok(type)) return poisoned_decl;
	decl.strukt.container_type = type;

	if (type.optional) { @print_error_at(type.loc, "A bitstruct can't have an optional type."); return poisoned_decl; }

	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	if (!parse_bitstruct_body(c, decl)) return poisoned_decl;

	return decl;
}

fn Decl* parse_top_level_const_declaration(ParseContext* c, bool is_extern) @inline
{
	Decl* decl = parse_const_declaration(c, true, is_extern);
	if (!decl_ok(decl)) return poisoned_decl;
	if (decl_ok(decl)) decl.docs = decl_from_contract_description(&c.contracts);
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

<*
 macro_params ::= parameters? (EOS trailing_block_param)?

 trailing_block_param ::= AT_IDENT ( '(' parameters? ')' )?
*>
fn bool parse_macro_params(ParseContext* c, Decl* macro_)
{
	if (!expect_advance(c, LPAREN)) return false;

	// Parse the regular parameters.
	Variadic variadic = NONE;
	int vararg_index = -1;
	Decl*[] params;
	if (!parse_parameters(c, &params, &variadic, &vararg_index, MACRO)) return false;
	macro_.func_decl.signature.params = params;
	macro_.func_decl.signature.vararg_index = vararg_index < 0 ? (int)params.len : vararg_index;
	macro_.func_decl.signature.variadic = variadic;

	// Do we have trailing block parameters?
	if (try_consume(c, EOS))
	{
		// Consume AT_IDENT
		Decl* body_param = decl_new_loc(BODYPARAM, symstr(c), c.span);
		if (!@consume(c, AT_IDENT, "Expected an ending ')' or a block parameter on the format '@block(...).")) return false;
		if (try_consume(c, LPAREN))
		{
			if (!parse_parameters(c, &body_param.body_params, null, null, BODY)) return false;
			if (!expect_advance(c, RPAREN)) return false;
		}
		macro_.func_decl.body_param = declid(body_param);
	}
	else
	{
		macro_.func_decl.body_param = 0;
	}
	if (!expect_advance(c, RPAREN)) return false;
	return true;
}

fn void decl_add_type(Decl* decl, TypeKind kind) @inline
{
	Type* type = type_new(kind, decl.name);
	type.canonical = type;
	type.decl = decl;
	decl.type = type;
}

fn DeclId decl_from_contract_description(ContractDescription* description)
{
	if (!description.has_contracts && !description.comment.ptr) return 0;
	Decl* decl = decl_new(CONTRACT, "contract", description.first);
	decl.contracts_decl.ensures = description.ensures;
	decl.contracts_decl.requires = description.requires;
	decl.contracts_decl.pure = description.pure;
	decl.contracts_decl.params = description.params;
	decl.contracts_decl.opt_returns = description.opt_returns;
	decl.contracts_decl.comment = description.comment;
	decl.contracts_decl.return_desc = description.return_desc;
	return declid(decl);
}

<*
 typedef_declaration ::= ALIAS TYPE_IDENT attributes? '=' typedef_type ';'

 typedef_type ::= func_typedef | type generic_params?
 func_typedef ::= 'fn' optional_type parameter_type_list
*>
fn Decl* parse_alias_type(ParseContext* c) @inline
{
	advance_and_verify(c, ALIAS);

	Decl* decl = decl_new_loc(TYPE_ALIAS, symstr(c), c.span);
	if (!try_consume(c, TYPE_IDENT))
	{
		if (token_is_any_type(c.tok))
		{
			@print_error_here(c, "'%s' is the name of a built-in type and can't be used as an alias.",
							 token_type_to_string(c.tok));
			return poisoned_decl;
		}
		if (token_is_some_ident(c.tok))
		{
			@print_error_here(c, "The type name must start with an uppercase letter followed by at least 1 lowercase letter.");
			return poisoned_decl;
		}
		@print_error_here(c, "A type name was expected here.");
		return poisoned_decl;
	}

	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	if (!expect_advance(c, EQ)) return poisoned_decl;

	// 1. Did we have `fn`? In that case it's a function pointer.
	if (try_consume(c, FN))
	{
		decl.decl_kind = TYPE_ALIAS;
		decl_add_type(decl, ALIAS);
		decl.type_alias_decl.is_func = true;
		Decl* decl_type = decl_new_loc(FNTYPE, decl.name, c.prev_span);
		decl.type_alias_decl.decl = decl_type;
		TypeInfo* type_info = parse_optional_type(c);
		if (!type_info_ok(type_info)) return poisoned_decl;
		decl_type.fntype_decl.signature.rtype = type_infoid(type_info);
		decl_type.docs = decl_from_contract_description(&c.contracts);
		if (!parse_fn_parameter_list(c, &decl_type.fntype_decl.signature))
		{
			return poisoned_decl;
		}
		if (!parse_attributes(c, &decl_type.attributes, null, null, null, "on the target of an alias (maybe you intended it *before* the '='?)", null, null)) return poisoned_decl;
		attach_deprecation_from_contract(c, &c.contracts, decl_type);
		range_extend_prev(c, decl_type.loc);
		range_extend_prev(c, decl.loc);
		if (!consume_eos(c)) return poisoned_decl;
		return decl;
	}

	// 2. Now parse the type which we know is here.

	Expr* expr = parse_expr(c);
	if (!expr_ok(expr)) return poisoned_decl;

	decl.type_alias_decl.type_expr = expr;
	decl.type_alias_decl.is_func = false;
	decl.decl_kind = TYPE_ALIAS;
	decl_add_type(decl, ALIAS);
	decl.docs = decl_from_contract_description(&c.contracts);
	if (!parse_attach_contracts(decl_template_get_generic(decl), &c.contracts)) return poisoned_decl;
	range_extend_prev(c, decl.loc);
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

<* define_ident ::= 'alias' 'module' IDENT = path *>
fn Decl* parse_alias_module(ParseContext* c, Decl* decl, TokenType token_type) @inline
{
	advance_and_verify(c, MODULE);

	if (token_type != IDENT)
	{
		@print_error_at(decl.loc, "A (lower case) module name was expected here.");
		return poisoned_decl;
	}

	if (!str_is_valid_lowercase_name(decl.name))
	{
		@print_error_at(decl.loc, "The module name must be all lower case.");
		return poisoned_decl;
	}

	decl.decl_kind = ALIAS_PATH;

	if (!tok_is(c, IDENT))
	{
		@print_error_here(c, "'module' should be followed by a module name.");
		return poisoned_decl;
	}

	ModulePath* path = parse_module_path(c);
	if (!path) return poisoned_decl;

	decl.module_alias_decl.alias_path = path;

	range_extend_prev(c, decl.loc);
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

<*
 define_ident ::= 'alias' (IDENT | CONST_IDENT | AT_IDENT) attributes? '=' (('module' path) | identifier_alias generic_params?)

 identifier_alias ::= path? (IDENT | CONST_IDENT | AT_IDENT)
*>
fn Decl* parse_alias_ident(ParseContext* c) @inline
{
	// 1. Store the beginning of the "alias".
	advance_and_verify(c, ALIAS);

	// 2. At this point we expect an ident or a const token.
	//    since the Type is handled.
	TokenType alias_type = c.tok;
	if (alias_type != IDENT && alias_type != CONST_IDENT && alias_type != AT_IDENT)
	{
		if (token_is_keyword_ident(alias_type) && alias_type != FN)
		{
			@print_error_here(c, "'%s' is a reserved keyword, try another name.", token_type_to_string(alias_type));
		}
		else if (alias_type == TYPE_IDENT)
		{
			@print_error_here(c, "A variable, constant or attribute name was expected here. If you want to define a new type, use 'def' instead.");
		}
		else
		{
			@print_error_here(c, "A type, variable, constant or attribute name was expected here.");
		}
		return poisoned_decl;
	}

	// 3. Set up the "define".
	Decl* decl = decl_new_loc(ALIAS, symstr(c), c.span);

	// 4. Advance and consume the '='
	advance(c);

	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	if (!expect_advance(c, EQ)) return poisoned_decl;

	if (tok_is(c, MODULE))
	{
		return parse_alias_module(c, decl, alias_type);
	}
	if (decl.name.ptr == kw_main.ptr)
	{
		@print_error_at(decl.loc, "'main' is reserved and cannot be used as an alias.");
		return poisoned_decl;
	}

	if (tok_is(c, FN))
	{
		@print_error_at(decl.loc, "This looks like you're declaring a function type alias, and such an alias must have a valid type name, like 'Callback'.");
		return poisoned_decl;
	}

	Expr* alias_expr = parse_expr(c);
	if (!expr_ok(alias_expr)) return poisoned_decl;
	decl.define_decl.alias_expr = alias_expr;

	if (!parse_attach_contracts(decl_template_get_generic(decl), &c.contracts)) return poisoned_decl;
	range_extend_prev(c, decl.loc);
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

<* define_attribute ::= 'attrmacro' AT_TYPE_IDENT '(' parameter_list ')' opt_attributes '=' '{' attributes? '}' ';' *>
fn Decl* parse_attrdef(ParseContext* c) @inline
{
	advance(c);
	//advance_and_verify(c, TOKEN_ATTRDEF);

	Decl* decl = decl_new_loc(ATTRIBUTE, symstr(c), c.span);

	if (!@consume(c, AT_TYPE_IDENT, "Expected an attribute type name, like '@MyAttr'.")) return poisoned_decl;

	if (try_consume(c, LPAREN))
	{
		if (tok_is(c, RPAREN))
		{
			@print_error_at_loc(&c.prev_span, "At least one parameter was expected after '(' - try removing the '()'.");
			return poisoned_decl;
		}
		if (!parse_parameters(c, &decl.attr_decl.params, null, null, ATTR)) return poisoned_decl;
		if (!expect_advance(c, RPAREN)) return poisoned_decl;
	}

	Attr*[] attributes;
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;

	decl.docs = decl_from_contract_description(&c.contracts);

	// Empty
	if (try_consume(c, EOS)) return decl;

	if (!expect_advance(c, EQ)) return poisoned_decl;
	if (tok_is(c, EOS))
	{
		@print_error_here(c, "Expected a list of attributes.");
		return poisoned_decl;
	}

	bool is_cond;
	bool is_builtin = false;
	if (!parse_attribute_list(c, &attributes, null, decl_needs_prefix(decl) ? &is_builtin : null, &is_cond, true, "cannot be aliased using 'attrmacro'", null, null)) return poisoned_decl;
	decl.attr_decl.attrs = attributes;
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

<* define_decl ::= ALIAS define_type_body *>
fn Decl* parse_alias(ParseContext* c) @inline
{
	switch (peek(c))
	{
		case TYPE_IDENT:
			return parse_alias_type(c);
		default:
			return parse_alias_ident(c);
	}
}

fn bool parse_is_macro_name(ParseContext* c) @inline
{
	return (tok_is(c, IDENT) && peek(c) != SCOPE) || tok_is(c, AT_IDENT);
}

<*
 func_header ::= optional_type (type '.')? IDENT
 macro_header ::= optional_type? (type '.')? (IDENT | MACRO_IDENT)
*>
fn bool parse_func_macro_header(ParseContext* c, Decl* decl) @inline
{
	TypeInfo* rtype = null;
	TypeInfo* method_type = null;

	bool is_macro = decl.decl_kind == MACRO;

	// 1. If we have a macro and see the name, we're done (c3c: goto RESULT).
	if (!(is_macro && parse_is_macro_name(c)))
	{
		// 2. Now we must have a type - either that is the return type or the method type.
		if (is_macro && token_is_keyword(c.tok) && c.lexer.token_type == LPAREN)
		{
			return @print_error_here(c, "This is a reserved keyword and can't be used as a macro name.");
		}
		rtype = parse_optional_type(c);
		if (!type_info_ok(rtype)) return false;

		// 4. We might have a type here, if so then we read it.
		if (!tok_is(c, DOT) && !parse_is_macro_name(c) && !token_is_keyword(c.tok))
		{
			method_type = parse_type(c);
			if (!type_info_ok(method_type)) return false;
		}

		// 5. If we have a dot here, then we need to interpret this as method function.
		if (try_consume(c, DOT))
		{
			// 5a. What if we don't have a method type?
			if (!method_type)
			{
				// 5b. If the rtype is not optional or the return type was an optional, then this is an error.
				if (!is_macro || rtype.optional)
				{
					@print_error_last(c, "This looks like you are declaring a method without a return type?");
					return false;
				}
				method_type = rtype;
				rtype = null;
			}
		}
		else if (method_type)
		{
			// 5d. A method type but no dot is also wrong.
			if (method_type.kind == INFO_IDENTIFIER && tok_is(c, LPAREN))
			{
				if (method_type.resolve_status == DONE && !type_is_user_defined(method_type.type))
				{
					@print_error_at(method_type.loc, "A function name may not use a reserved type name like '%s'.", method_type.type.name);
					return false;
				}
				@print_error_at(method_type.loc, "A function name must start with lower case, as names starting with upper case are reserved for types.");
				return false;
			}
			@print_error_at(method_type.loc, "There is unexpectedly a type after the return type, did you forget a '.'?");
			return false;
		}
	}
	// RESULT:
	decl.name = symstr(c);
	decl.loc = make_loc(c.span);
	if (token_is_keyword(c.tok) && c.lexer.token_type == LPAREN)
	{
		return @print_error_here(c, "This is a reserved keyword and can't be used as a %s name.", is_macro ? "macro" : "function");
	}

	if (is_macro && c.tok != IDENT && c.tok != AT_IDENT)
	{
		@print_error_at_loc(&c.span, "Expected a macro name here, e.g. '@someName' or 'someName'.");
		return false;
	}
	if (!is_macro && c.tok != IDENT)
	{
		@print_error_at_loc(&c.span, "Expected a function name here, e.g. 'someName'.");
		return false;
	}
	advance(c);
	decl.func_decl.signature.rtype = rtype ? type_infoid(rtype) : 0;
	decl.func_decl.signature.is_macro = is_macro;
	decl.func_decl.signature.is_at_macro = decl.name[0] == '@';
	decl.func_decl.type_parent = method_type ? type_infoid(method_type) : 0;
	return true;
}

<*
 macro ::= MACRO macro_header '(' macro_params ')' opt_attributes macro_body
 macro_body ::= IMPLIES expression ';' | compound_statement
*>
fn Decl* parse_macro_declaration(ParseContext* c) @inline
{
	advance_and_verify(c, MACRO);

	Decl* decl = decl_calloc();
	decl.decl_kind = MACRO;
	decl.docs = decl_from_contract_description(&c.contracts);
	if (!parse_func_macro_header(c, decl)) return poisoned_decl;
	if (!parse_macro_params(c, decl)) return poisoned_decl;
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;
	attach_deprecation_from_contract(c, &c.contracts, decl);
	if (tok_is(c, IMPLIES))
	{
		Ast* body = parse_short_body(c, decl, false);
		if (!ast_ok(body)) return poisoned_decl;
		decl.func_decl.body = astid(body);
		return decl;
	}
	Ast* body = parse_compound_stmt(c);
	if (!ast_ok(body)) return poisoned_decl;
	decl.func_decl.body = astid(body);
	return decl;
}

fn Decl* parse_fault(ParseContext* c) @inline
{
	ContractDescription contracts = {};
	if (!parse_element_contract(c, &contracts, "faults")) return poisoned_decl;
	Decl* decl = decl_new_loc(FAULT, symstr(c), c.span);
	decl.docs = decl_from_contract_description(&contracts);
	if (!consume_const_name(c, "fault")) return poisoned_decl;
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;
	attach_deprecation_from_contract(c, &contracts, decl);
	return decl;
}

fn Decl* parse_faultdef_multirow(ParseContext* c) @inline
{
	Decl*[] decls;
	while (!try_consume(c, EOS))
	{
		Decl* decl = parse_fault(c);
		if (!decl_ok(decl)) return poisoned_decl;
		@vec_add(&decls, decl);
		if (try_consume(c, COMMA)) continue;
		if (!expect_advance(c, EOS)) return poisoned_decl;
		break;
	}
	if (!decls.len)
	{
		@print_error_last(c, "Expected the name of a fault here.");
		return poisoned_decl;
	}
	Decl* decl = decl_calloc();
	decl.decl_kind = GROUP;
	decl.decl_list = decls;
	decl.docs = decl_from_contract_description(&c.contracts);
	return decl;
}

<* faultdef_declaration ::= FAULTDEF CONST_IDENT (',' CONST_IDENT)* ','? ';' *>
fn Decl* parse_faultdef_declaration(ParseContext* c) @inline
{
	advance(c);
	// advance_and_verify(c, TOKEN_FAULTDEF);

	if (c.lexer.token_type == EOS)
	{
		Decl* decl = parse_fault(c);
		if (!decl_ok(decl)) return poisoned_decl;
		if (!consume_eos(c)) return poisoned_decl;
		return decl;
	}
	return parse_faultdef_multirow(c);
}

<*
 excuse_declaration ::= EXCUSE CONST_IDENT (',' CONST_IDENT)* ','? ';'
                      | EXCUSE '{' CONST_IDENT (',' CONST_IDENT)* ','? '}'
*>
fn Decl* parse_excuse_declaration(ParseContext* c) @inline
{
	advance(c);

	if (c.lexer.token_type == EOS)
	{
		Decl* decl = parse_fault(c);
		if (!decl_ok(decl)) return poisoned_decl;
		if (!consume_eos(c)) return poisoned_decl;
		return decl;
	}

	if (!try_consume(c, LBRACE))
	{
		return parse_faultdef_multirow(c);
	}

	Decl*[] decls;
	while (true)
	{
		Decl* decl = parse_fault(c);
		if (!decl_ok(decl)) return poisoned_decl;
		@vec_add(&decls, decl);
		if (!try_consume(c, COMMA))
		{
			if (!expect_advance(c, RBRACE)) return poisoned_decl;
			break;
		}
		if (try_consume(c, RBRACE)) break;
	}
	Decl* decl = decl_calloc();
	decl.decl_kind = GROUP;
	decl.decl_list = decls;
	decl.docs = decl_from_contract_description(&c.contracts);
	return decl;
}

<* enum_param_list ::= '(' enum_param* ')' *>
fn bool parse_enum_param_list(ParseContext* c, Decl*[]* parameters_ref) @inline
{
	// If no left parenthesis we're done.
	if (!try_consume(c, LPAREN)) return true;

	while (!try_consume(c, RPAREN))
	{
		if (!parse_enum_param_decl(c, parameters_ref)) return false;
		Decl* last_parameter = (*parameters_ref)[^1];
		assert(last_parameter != null);
		last_parameter.var_decl.index = (int)(*parameters_ref).len - 1; // NOLINT
		if (!try_consume(c, COMMA))
		{
			if (!expect(c, RPAREN)) return false;
		}
	}
	return true;
}

fn bool parse_enum_values(ParseContext* c, Decl*[]* values_ref, Visibility visibility, bool is_constset)
{
	Decl*[] values;
	SourceLoc start = c.prev_span;

	while (!try_consume(c, RBRACE))
	{
		ContractDescription contracts = {};
		if (!parse_element_contract(c, &contracts, "enum values")) return false;
		Decl* enum_const = decl_new_loc(ENUM_CONSTANT, symstr(c), c.span);
		enum_const.docs = decl_from_contract_description(&contracts);
		if (is_constset) enum_const.enum_constant.is_raw = is_constset;
		enum_const.visibility = visibility;
		String name = enum_const.name;
		if (!consume_const_name(c, "enum constant")) return false;
		foreach (other_constant : values)
		{
			if (other_constant.name.ptr == name.ptr)
			{
				@print_error_at(enum_const.loc, "This enum constant is declared twice.");
				@sema_note_prev_at(other_constant.loc, "The previous declaration was here.");
				return false;
			}
		}
		if (!parse_attributes_for_global(c, enum_const)) return false;
		attach_deprecation_from_contract(c, &contracts, enum_const);
		if (is_constset)
		{
			if (try_consume(c, EQ))
			{
				Expr* single = parse_constant_expr(c);
				if (!expr_ok(single)) return false;
				enum_const.enum_constant.value = single;
			}
		}
		else if (try_consume(c, LBRACE))
		{
			Expr*[] args;
			while (true)
			{
				if (try_consume(c, RBRACE)) break;
				Expr* arg = parse_expr(c);
				if (!expr_ok(arg)) return false;
				@vec_add(&args, arg);
				if (tok_is(c, COLON) && arg.expr_kind == UNRESOLVED_IDENTIFIER)
				{
					SourceLoc loc = extend_loc_with_token(sourcelocptr(arg.loc), &c.span);
					@print_error_at_loc(&loc,
						"This looks like a named param call, but that style of declaration is not supported for declaring enum associated values.");
					return false;
				}

				if (try_consume(c, COMMA)) continue;
				if (!try_consume(c, RBRACE)) return @print_error_here(c, "A comma or a closing brace was expected here.");
				break;
			}
			enum_const.enum_constant.associated = args;
		}
		@vec_add(&values, enum_const);
		// Allow trailing ','
		if (!try_consume(c, COMMA))
		{
			if (tok_is(c, CONST_IDENT))
			{
				return @print_error_here(c, "It looks like you forgot a comma before this identifier.");
			}
			if (!expect(c, RBRACE)) return false;
		}
	}
	if (!is_constset && values.len == 0)
	{
		@print_error_after(&start, "An enum must have at least one value.");
		return false;
	}
	*values_ref = values;
	return true;
}

<*
 Parse an enum declaration (after "enum")

 enum ::= ENUM TYPE_IDENT opt_interfaces (':' 'inline'? type? ('const' | enum_param_list?)?)? opt_attributes '{' enum_body '}'
 enum_body ::= enum_def (',' enum_def)* ','?
 enum_def ::= CONST_IDENT ('(' arg_list ')')?
*>
fn Decl* parse_enum_declaration(ParseContext* c) @inline
{
	bool is_constset = false;
	if (tok_is(c, CONSTDEF) || tok_is(c, CONSTSET))
	{
		advance(c);
		//advance_and_verify(c, TOKEN_CONSTSET);
		is_constset = true;
	}
	else
	{
		advance_and_verify(c, ENUM);
	}

	String name = symstr(c);
	SourceLoc loc = c.span;
	if (!consume_type_name(c, is_constset ? "constset" : "enum" )) return poisoned_decl;
	TypeInfo*[] interfaces;
	if (!parse_interface_impls(c, &interfaces)) return poisoned_decl;
	TypeInfo* type = null;

	bool val_is_inline = false;
	Decl*[] param_list;
	if (try_consume(c, COLON))
	{
		if (!tok_is(c, LPAREN) && !tok_is(c, LBRACE))
		{
			val_is_inline = try_consume(c, INLINE);
			if (val_is_inline && !is_constset)
			{
				@print_error_last(c, "An enum cannot have 'inline' on its underlying type.");
				return poisoned_decl;
			}
			type = parse_optional_type_no_generic(c);
			if (!type_info_ok(type)) return poisoned_decl;
			if (type.optional)
			{
				@print_error_at(type.loc, "An enum or constset can't have an optional type.");
				return poisoned_decl;
			}
		}
		if (is_constset)
		{
			if (tok_is(c, LPAREN))
			{
				@print_error_here(c, "Constsets cannot have associated values.");
				return poisoned_decl;
			}
		}
		else
		{
			if (!parse_enum_param_list(c, &param_list)) return poisoned_decl;
		}
	}

	Decl* decl = decl_new_with_type(name, &loc, is_constset ? CONSTSET : ENUM);
	decl.docs = decl_from_contract_description(&c.contracts);
	decl.interfaces = interfaces;
	if (param_list.len) decl.enums.parameters = param_list;
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;
	Visibility visibility = decl.visibility;
	if (!expect_advance(c, LBRACE)) return poisoned_decl;

	decl.enums.type_info = type ? type : type_info_new_base(type_int, decl.loc);
	if (is_constset && val_is_inline) decl.is_substruct = true;
	if (!parse_enum_values(c, &decl.enums.values, visibility, is_constset)) return poisoned_decl;
	return decl;
}

// --- Parse function

<*
 Starts after 'fn'

 func_definition ::= func_macro_header fn_parameter_list opt_attributes (func_body | ';')
 func_body ::= ('=>' short_body) | compound_stmt
*>
fn Decl* parse_func_definition(ParseContext* c, FunctionParse parse_kind) @inline
{
	advance_and_verify(c, FN);
	Decl* func = decl_calloc();
	func.decl_kind = FUNC;
	func.docs = decl_from_contract_description(&c.contracts);
	func.func_decl.attr_interface_method = parse_kind == INTERFACE;
	if (!parse_func_macro_header(c, func)) return poisoned_decl;
	if (func.name[0] == '@')
	{
		@print_error_at(func.loc, "Function names may not use '@'.");
		return poisoned_decl;
	}
	if (!parse_fn_parameter_list(c, &func.func_decl.signature)) return poisoned_decl;
	if (!parse_attributes_for_global(c, func)) return poisoned_decl;
	attach_deprecation_from_contract(c, &c.contracts, func);
	if (parse_kind != REGULAR)
	{
		if (tok_is(c, LBRACE) || tok_is(c, IMPLIES))
		{
			switch (parse_kind)
			{
				case REGULAR:
					unreachable();
				case C3I:
					@print_error_here(c, "An interface file may not contain function bodies.");
					return poisoned_decl;
				case EXTERN:
					@print_error_here(c, "An 'extern' function may not have a body.");
					return poisoned_decl;
				case INTERFACE:
					@print_error_here(c, "An interface method cannot have a body.");
					return poisoned_decl;
			}
			// c3c: UNREACHABLE (every case returns)
		}
		if (!@consume(c, EOS, "Expected ';' after the function declaration.")) return poisoned_decl;
		return func;
	}

	if (try_consume(c, EOS))
	{
		// Since this is a previous declaration, it's considered weak and will be replaced by the actual definition.
		func.is_weak = true;
		return func;
	}

	if (tok_is(c, IMPLIES))
	{
		Ast* body = parse_short_body(c, func, false);
		if (!ast_ok(body)) return poisoned_decl;
		func.func_decl.body = astid(body);
	}
	else if (tok_is(c, LBRACE))
	{
		Ast* body = parse_compound_stmt(c);
		if (!ast_ok(body)) return poisoned_decl;
		func.func_decl.body = astid(body);
	}
	else
	{
		@print_error_here(c, "Expected the beginning of a block or a short statement.");
		return poisoned_decl;
	}

	return func;
}

<*
 import ::= IMPORT import_path (',' import_path)* opt_attributes EOS

 @return "true if import succeeded"
*>
fn bool parse_import(ParseContext* c) @inline
{
	advance_and_verify(c, IMPORT);

	bool is_not_first = false;
	while (true)
	{
		if (!tok_is(c, IDENT))
		{
			if (is_not_first)
			{
				@print_error_last(c, "Another module name was expected after the comma.");
				return false;
			}
			if (tok_is(c, STRING))
			{
				@print_error_here(c, "An import should be followed by a plain identifier, not a string. Did you accidentally put the module name between \"\"?");
				return false;
			}
			@print_error_here(c, "Import statement should be followed by the name of the module to import.");
			return false;
		}
		is_not_first = true;
		ModulePath* path = parse_module_path(c);
		if (!path) return false;
		bool is_private = false;
		bool is_norecurse = false;
		while (tok_is(c, AT_IDENT))
		{
			String name = symstr(c);
			if (name.ptr == attribute_list[AttributeType.PUBLIC.ordinal].ptr)
			{
				is_private = true;
			}
			else if (name.ptr == attribute_list[AttributeType.NORECURSE.ordinal].ptr)
			{
				is_norecurse = true;
			}
			else
			{
				@print_error_here(c, "Only '@public' and '@norecurse' are valid attributes here.");
				return false;
			}
			advance_and_verify(c, AT_IDENT);
		}
		unit_add_import(c.unit, path, is_private, is_norecurse);
		if (tok_is(c, COLON) && peek(c) == IDENT)
		{
			@print_error_here(c, "'::' was expected here, did you make a mistake?");
			return false;
		}
		if (!try_consume(c, COMMA)) break;
	}

	if (!consume_eos(c)) return false;
	return true;
}

fn bool parse_doc_to_eol(ParseContext* c) @inline
{
	if (try_consume(c, DOCS_EOL)) return true;
	if (tok_is(c, DOCS_END)) return true;
	return false;
}

fn bool parse_doc_check_skip_string_eos(ParseContext* c) @inline
{
	if (tok_is(c, STRING)) return true;
	if (!tok_is(c, DOCS_EOL)) return false;
	if (peek(c) != STRING) return false;
	advance_and_verify(c, DOCS_EOL);
	return true;
}

fn bool parse_docs_to_comment(ParseContext* c) @inline
{
	if (try_consume(c, COLON)) return true;
	if (!tok_is(c, DOCS_EOL)) return false;
	if (peek(c) == COLON)
	{
		advance_and_verify(c, DOCS_EOL);
		advance_and_verify(c, COLON);
		return true;
	}
	return false;
}

fn bool parse_doc_discarded_comment(ParseContext* c)
{
	if (try_consume(c, STRING))
	{
		@print_error_at_loc(&c.span, "You need to use ':' before the description.");
		return false;
	}
	if (!parse_docs_to_comment(c)) return true;
	if (!parse_doc_check_skip_string_eos(c)) return true;
	return parse_joined_strings(c, null, null);
}

fn bool parse_doc_direct_comment(ParseContext* c, String* out_str)
{
	if (tok_is(c, DOCS_EOL) && peek(c) == STRING)
	{
		advance(c);
	}
	if (!tok_is(c, STRING)) return true;
	return parse_joined_strings(c, out_str, null);
}

<* contract ::= expression_list (':'? STRING)? *>
fn bool parse_doc_contract(ParseContext* c, Expr*[]* list_ref, SourceLocId* linked_to_param_ref) @inline
{
	Expr* expr = expr_new_token(c, CONTRACT);
	char* start = c.lexer.data.lex.ptr;
	advance(c);
	if (linked_to_param_ref && try_consume(c, LBRACKET))
	{
		if (!parse_contract_param_name(c, &expr.contract_expr.param.name)) return false;
		*linked_to_param_ref = expr.loc;
		start = c.lexer.data.lex.ptr;
		if (!expect_advance(c, RBRACKET)) return false;
	}
	Expr* decl_exprs = parse_expression_list(c, false);
	if (!expr_ok(decl_exprs)) return false;
	expr.contract_expr.decl_exprs = decl_exprs;
	range_extend_prev(c, expr.loc);
	char* end = start + 1;
	while (end[0] != '\n' && end[0] != '\0') end++;
	if (end > c.data.lex.ptr) end = c.data.lex.ptr;
	while (is_space(end[-1])) end--;
	scratch_buffer_clear();
	scratch_buffer_append_remove_space(start, (int)(end - start));
	expr.contract_expr.expr_string = scratch_buffer_copy();
	bool docs_to_comment = false;
	if (parse_docs_to_comment(c))
	{
		docs_to_comment = true;
		if (!parse_doc_check_skip_string_eos(c))
		{
			@print_error_at_loc(&c.prev_span, "Expected a string after ':'");
			return false;
		}
	}
	if (tok_is(c, STRING))
	{
		scratch_buffer_clear();
		if (!parse_joined_strings(c, null, null)) return false;
		expr.contract_expr.comment = scratch_buffer_copy();
		if (!docs_to_comment)
		{
			@print_error_at(expr.loc, "Expected a ':' before the description.");
			return false;
		}
	}
	@vec_add(list_ref, expr);
	return true;
}

fn bool parse_contract_param_name(ParseContext* c, String* name_ref) @inline
{
	switch (c.tok)
	{
		case IDENT:
		case CT_IDENT:
		case CT_TYPE_IDENT:
		case HASH_IDENT:
			*name_ref = symstr(c);
			advance(c);
			return true;
		case ELLIPSIS:
			*name_ref = NO_STRING;
			advance(c);
			return true;
		case TYPE_IDENT:
		case CT_CONST_IDENT:
		case CONST_IDENT:
			return @print_error_here(c, "This is not a valid parameter name.");
		default:
			return @print_error_here(c, "Expected a parameter name here.");
	}
}

<*
 param_contract ::= '@param' inout_attribute? any_identifier ( ':' STRING )?
 inout_attribute ::= '[' '&'? ('in' | 'inout' | 'out') ']'
*>
fn bool parse_contract_param(ParseContext* c, ContractParam[]* list_ref) @inline
{
	advance(c);

	// [inout] [in] [out]
	bool is_ref = false;
	InOutModifier mod = ANY;
	SourceLoc loc = c.span;
	if (try_consume(c, LBRACKET))
	{
		is_ref = try_consume(c, AMP);
		String modifier = tok_is(c, IDENT) ? symstr(c) : NO_STRING;
		if (modifier.ptr) advance(c);
		if (modifier.ptr == kw_in.ptr)
		{
			mod = IN;
		}
		else if (modifier.ptr == kw_inout.ptr)
		{
			mod = INOUT;
		}
		else if (modifier.ptr == kw_out.ptr)
		{
			mod = OUT;
		}
		else if (modifier.ptr == kw_own.ptr)
		{
			mod = OWN;
		}
		else if (modifier.ptr == kw_init.ptr)
		{
			mod = INIT;
		}
		else if (modifier.ptr == kw_drop.ptr)
		{
			mod = DROP;
		}
		else
		{
			return @print_error_last(c, "'in', 'out', 'inout', 'init', 'drop' or 'own' was expected.");
		}
		if (!expect_advance(c, RBRACKET)) return false;
	}

	ContractParam param = { .loc = make_loc(loc) };
	if (!parse_contract_param_name(c, &param.name)) return false;
	param.modifier = mod;

	param.by_ref = is_ref;
	range_extend_prev(c, param.loc);
	if (parse_docs_to_comment(c))
	{
		if (!parse_doc_check_skip_string_eos(c))
		{
			return @print_error_last(c, "Expected a string after ':'");
		}
		if (!parse_joined_strings(c, &param.description, null)) return false;
	}
	else
	{
		if (!try_consume(c, STRING))
		{
			if (!tok_is(c, DOCS_EOL) && !tok_is(c, DOCS_END))
			{
				if (tok_is(c, IDENT) || tok_is(c, TYPE_IDENT))
				{
					@print_error_here(c, "A string containing the parameter description was expected, did you forget enclosing the description in \"\" or ``?");
				}
				else
				{
					@print_error_here(c, "A string containing the description was expected after the parameter name.");
				}
				return false;
			}
		}
		else
		{
			@print_error_at(param.loc, "Expected a ':' before the description.");
			return false;
		}
	}
	@vec_add(list_ref, param);
	return true;
}

fn bool parse_doc_optreturn(ParseContext* c, Expr*[]* opt_return_ref) @inline
{
	advance_and_verify(c, QUESTION);
	while (true)
	{
		Expr* expr = parse_expr(c);
		if (!expr_ok(expr)) return false;
		@vec_add(opt_return_ref, expr);
		if (!try_consume(c, COMMA)) break;
	}
	// Just ignore our potential string:
	if (!parse_doc_discarded_comment(c)) return false;
	return true;
}

fn bool parse_contracts(ParseContext* c, ContractDescription* contracts_ref)
{
	if (!tok_is(c, DOCS_START)) return true;

	SourceLocId start_loc = make_loc(c.span);
	if (c.data.string.len > 0)
	{
		// c3c copies the comment out of the source buffer to get a NUL terminated string.
		contracts_ref.comment = str_copy(symstr(c));
		contracts_ref.comment_span = start_loc;
	}
	contracts_ref.first = start_loc;
	advance_and_verify(c, DOCS_START);
	bool return_comment = false;
	while (!try_consume(c, DOCS_END))
	{
		if (try_consume(c, DOCS_EOL)) continue;
		if (!tok_is(c, AT_IDENT))
		{
			return @print_error_here(c, "Expected a directive starting with '@' here, like '@param' or `@require`");
		}
		SourceLocId loc = make_loc(c.span);
		if (!contracts_ref.first) contracts_ref.first = loc;
		String name = symstr(c);
		if (name.ptr == kw_at_require.ptr)
		{
			if (!contracts_ref.has_contracts)
			{
				contracts_ref.first_contract = loc;
				contracts_ref.has_contracts = true;
			}
			SourceLocId linked_to_param = 0;
			if (!parse_doc_contract(c, &contracts_ref.requires, &linked_to_param)) return false;
			if (linked_to_param && !contracts_ref.first_variable_require) contracts_ref.first_variable_require = linked_to_param;
			// c3c: goto END
		}
		else
		{
			if (contracts_ref.first_non_require == 0)
			{
				contracts_ref.first_non_require = loc;
			}
			if (name.ptr == kw_at_param.ptr)
			{
				if (!contracts_ref.has_contracts)
				{
					contracts_ref.first_contract = loc;
					contracts_ref.has_contracts = true;
				}
				if (!parse_contract_param(c, &contracts_ref.params)) return false;
			}
			else if (name.ptr == kw_at_return.ptr)
			{
				advance(c);
				if (tok_is(c, QUESTION))
				{
					if (!contracts_ref.has_contracts)
					{
						contracts_ref.first_contract = loc;
						contracts_ref.has_contracts = true;
					}
					if (!parse_doc_optreturn(c, &contracts_ref.opt_returns)) return false;
				}
				else
				{
					if (return_comment)
					{
						return @print_error_here(c, "Only one `@return` directive is allowed per contract.");
					}
					return_comment = true;
					if (!parse_doc_direct_comment(c, &contracts_ref.return_desc)) return false;
				}
			}
			else if (name.ptr == kw_at_deprecated.ptr)
			{
				advance(c);
				if (contracts_ref.deprecated)
				{
					return @print_error_here(c, "Only one `@deprecated` directive is allowed per contract.");
				}
				Attr* attr = calloc_arena(Attr::size);
				attr.name = kw_at_deprecated;
				attr.loc = loc;
				attr.path = null;
				attr.attr_kind = DEPRECATED;
				if (tok_is(c, DOCS_EOL) && peek(c) == STRING)
				{
					advance(c);
				}
				SourceLoc start = c.span;
				if (tok_is(c, STRING))
				{
					String str = NO_STRING;
					usz len;
					if (!parse_joined_strings(c, &str, &len)) return false;
					Expr* e = expr_new_const_string(make_loc(extend_loc_with_token(&start, &c.prev_span)), str);
					@vec_add(&attr.exprs, e);
				}
				contracts_ref.deprecated = attr;
			}
			else if (name.ptr == kw_at_ensure.ptr)
			{
				if (!contracts_ref.has_contracts)
				{
					contracts_ref.first_contract = loc;
					contracts_ref.has_contracts = true;
				}
				if (!parse_doc_contract(c, &contracts_ref.ensures, null)) return false;
			}
			else if (name.ptr == kw_at_pure.ptr)
			{
				if (contracts_ref.pure)
				{
					return @print_error_here(c, "Multiple '@pure' declarations, please remove one.");
				}
				if (!contracts_ref.has_contracts)
				{
					contracts_ref.first_contract = loc;
					contracts_ref.has_contracts = true;
				}
				contracts_ref.pure = true;
				advance(c);
				if (!parse_doc_direct_comment(c, null)) return false;
			}
			else
			{
				advance(c);
				if (!parse_doc_direct_comment(c, null)) return false;
				if (parse_doc_to_eol(c)) continue;
				return @print_error_here(c, "Expected a string description for the custom contract '%s'.", name);
			}
		}
		// END:
		if (parse_doc_to_eol(c)) continue;
		@print_error_here(c, "Expected the end of the contract here.");
		return false;
	}
	return true;
}

fn Decl* parse_ct_include(ParseContext* c)
{
	Decl* decl = decl_new_loc(CT_INCLUDE, NO_STRING, c.span);
	advance_and_verify(c, CT_INCLUDE);
	Expr* filename = parse_constant_expr(c);
	if (!expr_ok(filename)) return poisoned_decl;
	decl.include.filename = filename;
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

fn Decl* parse_expand(ParseContext* c)
{
	Decl* decl = decl_new_loc(CT_EXPAND, NO_STRING, c.span);
	advance_and_verify(c, CT_EXPAND);
	if (!expect_advance(c, LPAREN)) return poisoned_decl;
	Expr* expand = parse_constant_expr(c);
	if (!expr_ok(expand)) return poisoned_decl;
	decl.expand_decl = expand;
	if (!expect_advance(c, RPAREN)) return poisoned_decl;
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

fn Decl* parse_exec(ParseContext* c)
{
	Decl* decl = decl_new_loc(CT_EXEC, NO_STRING, c.span);
	advance_and_verify(c, CT_EXEC);
	if (!expect_advance(c, LPAREN)) return poisoned_decl;
	Expr* filename = parse_constant_expr(c);
	if (!expr_ok(filename)) return poisoned_decl;
	decl.exec_decl.filename = filename;
	// We might just have `$exec("foo")` (c3c: goto END)
	if (!try_consume(c, RPAREN))
	{
		// Get the `,`
		if (!expect_advance(c, COMMA)) return poisoned_decl;
		if (!expect_advance(c, LBRACE)) return poisoned_decl;
		do
		{
			if (tok_is(c, RBRACE)) break;
			Expr* expr = parse_constant_expr(c);
			if (!expr_ok(expr)) return poisoned_decl;
			@vec_add(&decl.exec_decl.args, expr);
		} while (try_consume(c, COMMA));
		if (!expect_advance(c, RBRACE)) return poisoned_decl;
		if (!try_consume(c, RPAREN))
		{
			if (!expect_advance(c, COMMA)) return poisoned_decl;
			Expr* stdin_string = parse_constant_expr(c);
			if (!expr_ok(stdin_string)) return poisoned_decl;
			decl.exec_decl.stdin_string = stdin_string;
			if (!expect_advance(c, RPAREN)) return poisoned_decl;
		}
	}
	// END:
	if (!parse_attributes_for_global(c, decl)) return poisoned_decl;
	if (!consume_eos(c)) return poisoned_decl;
	return decl;
}

<* c3c parse_top_level_statement's CONTRACT_NOT_ALLOWED label. *>
fn Decl* parse_contract_not_allowed(ParseContext* c) @inline
{
	@print_error_at(c.contracts.first, "Contracts are only used for modules, functions and macros.");
	return poisoned_decl;
}

<*
 top_level_statement ::= struct_declaration | enum_declaration | fault_declaration | const_declaration
                       | global_declaration | macro_declaration | func_definition | typedef_declaration
                       | conditional_compilation | define_declaration | import_declaration | module_declaration
                       | distinct_declaration | interface_declaration
                       | static_declaration | ct_assert_declaration | ct_echo_declaration | bitstruct_declaration

 @return "Decl* or a poison value if parsing failed"
*>
fn Decl* parse_top_level_statement(ParseContext* c, ParseContext** context_out)
{
	c.contracts = {};
	if (!parse_contracts(c, &c.contracts)) return poisoned_decl;

	Decl* decl;
	TokenType tok = c.tok;
	if (tok != MODULE && !c.unit.mod)
	{
		if (!context_set_module_from_filename(c)) return poisoned_decl;
		c.unit.module_generated = true;
		// Pass the docs to the next thing.
	}
	bool attach_contracts = false;
	switch (tok)
	{
		case EXTERN:
			// Extern declarations
			advance(c);
			tok = c.tok;
			switch (tok)
			{
				case FN:
					decl = parse_func_definition(c, EXTERN);
				case CONST:
					decl = parse_top_level_const_declaration(c, true);
					attach_contracts = true;
				case IDENT:
				case TLOCAL:
				case VOID..UNTYPEDLIST:
				case TYPE_IDENT:
				case CT_TYPE_IDENT:
				case CT_TYPEOF:
				case CT_TYPEFROM:
					decl = parse_global_declaration(c);
					attach_contracts = true;
				default:
					@print_error_here(c, "Expected 'extern' to be followed by a function, constant or global variable.");
					return poisoned_decl;
			}
			if (!decl_ok(decl)) return decl;
			decl.is_extern = true;
		case MODULE:
			if (!context_out)
			{
				@print_error_here(c, "'module' is not valid inside an include.");
				return poisoned_decl;
			}
			advance(c);
			if (c.unit.mod)
			{
				if (c.unit.module_generated)
				{
					@print_error_at(c.unit.mod.name.loc, "This file begins with an auto-generated module '%s', which isn't compatible with having other module sections, please start the file with an explicit 'module'.",
						c.unit.mod.name.module_name);
					@sema_note_prev_at(make_loc(c.span), "This declaration creates the next module section.");
					c.unit.module_generated = false;
					return poisoned_decl;
				}
				// We might run into another module declaration. If so, create a new unit.
				ParseContext* new_context = calloc_arena(ParseContext::size);
				*new_context = *c;
				new_context.unit = unit_create(c.unit.file);
				c = new_context;
				*context_out = c;
			}
			if (!parse_module(c)) return poisoned_decl;
			return null;
		case DOCS_START:
			@print_error_here(c, "Multiple doc-comment blocks are not allowed. You can try combining them into a single '<* ... *>'.");
			return poisoned_decl;
		case ALIAS:
			decl = parse_alias(c);
			if (decl.decl_kind == ALIAS_PATH)
			{
				if (!context_out)
				{
					@print_error_here(c, "'alias module' may not appear inside a compile time statement.");
					return poisoned_decl;
				}
				if (!unit_add_alias(c.unit, decl)) return poisoned_decl;
				return null;
			}
		case ATTRMACRO:
		case ATTRDEF:
			decl = parse_attrdef(c);
			attach_contracts = true;
		case FN:
			decl = parse_func_definition(c, c.unit.is_interface_file ? FunctionParse.C3I : FunctionParse.REGULAR);
		case CT_ASSERT:
			if (c.contracts.has_contracts) return parse_contract_not_allowed(c);
			Ast* assert_ast = parse_ct_assert_stmt(c);
			if (!ast_ok(assert_ast)) return poisoned_decl;
			decl = decl_new_ct(CT_ASSERT, assert_ast.loc);
			decl.ct_assert_decl = assert_ast;
			return decl;
		case CT_ERROR:
			if (c.contracts.has_contracts) return parse_contract_not_allowed(c);
			Ast* error_ast = parse_ct_error_stmt(c);
			if (!ast_ok(error_ast)) return poisoned_decl;
			decl = decl_new_ct(CT_ASSERT, error_ast.loc);
			decl.ct_assert_decl = error_ast;
			return decl;
		case CT_ECHO:
			if (c.contracts.has_contracts) return parse_contract_not_allowed(c);
			Ast* echo_ast = parse_ct_echo_stmt(c);
			if (!ast_ok(echo_ast)) return poisoned_decl;
			decl = decl_new_ct(CT_ECHO, echo_ast.loc);
			decl.ct_echo_decl = echo_ast;
		case IMPORT:
			if (c.contracts.has_contracts) return parse_contract_not_allowed(c);
			if (!context_out)
			{
				@print_error_here(c, "'import' may not appear inside a compile time statement.");
				return poisoned_decl;
			}
			if (!parse_import(c)) return poisoned_decl;
			return null;
		case CT_INCLUDE:
			if (c.contracts.has_contracts) return parse_contract_not_allowed(c);
			decl = parse_ct_include(c);
		case CT_EXPAND:
			if (c.contracts.has_contracts) return parse_contract_not_allowed(c);
			decl = parse_expand(c);
		case CT_EXEC:
			if (c.contracts.has_contracts) return parse_contract_not_allowed(c);
			decl = parse_exec(c);
		case BITSTRUCT:
			decl = parse_bitstruct_declaration(c);
			attach_contracts = true;
		case INTERFACE:
			decl = parse_interface_declaration(c);
			attach_contracts = true;
		case TYPEDEF:
			decl = parse_typedef_declaration(c);
			attach_contracts = true;
		case CONST:
			decl = parse_top_level_const_declaration(c, false);
			attach_contracts = true;
		case STRUCT:
		case UNION:
			decl = parse_struct_declaration(c);
			attach_contracts = true;
		case MACRO:
			decl = parse_macro_declaration(c);
		case ENUM:
		case CONSTDEF:
		case CONSTSET:
			decl = parse_enum_declaration(c);
			attach_contracts = true;
		case FAULTDEF:
			decl = parse_faultdef_declaration(c);
			attach_contracts = true;
		case IDENT:
			if (symstr(c).ptr == kw_excuse.ptr)
			{
				decl = parse_excuse_declaration(c);
				attach_contracts = true;
				break;
			}
			decl = parse_global_declaration(c);
			attach_contracts = true;
		case EOF:
			@print_error_last(c, "Expected a top level declaration.");
			return poisoned_decl;
		case STATIC:
			@print_error_here(c, "'static' is only used with local variable declarations.");
			return poisoned_decl;
		case CT_CONST_IDENT:
			if (peek(c) == EQ)
			{
				@print_error_here(c, "Did you forget a 'const' before the name of this compile time constant?");
			}
			else
			{
				@print_error_here(c, "Compile time constant unexpectedly found.");
			}
			return poisoned_decl;
		case TLOCAL:
		case VOID..UNTYPEDLIST:
		case TYPE_IDENT:
		case CT_TYPE_IDENT:
		case CT_TYPEOF:
		case CT_TYPEFROM:
			decl = parse_global_declaration(c);
			attach_contracts = true;
		case EOS:
			@print_error_here(c, "';' wasn't expected here, try removing it.");
			return poisoned_decl;
		default:
			@print_error_here(c, "Expected the start of a global declaration here.");
			return poisoned_decl;
	}
	if (!decl_ok(decl)) return decl;
	attach_deprecation_from_contract(c, &c.contracts, decl);
	if (attach_contracts)
	{
		if (c.contracts.has_contracts && !parse_attach_contracts(decl_template_get_generic(decl), &c.contracts)) return poisoned_decl;
		if (c.contracts.opt_returns.len || c.contracts.return_desc.ptr || c.contracts.params.len)
		{
			@print_error_at(c.contracts.first_non_require, "'@param', '@return' and '@return?' can only be used with functions and macros.");
		}
	}
	assert(decl != null);
	return decl;
}
