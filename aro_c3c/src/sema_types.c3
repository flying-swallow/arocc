// Port of c3c src/compiler/sema_types.c (revision 54bab366a): TypeInfo
// resolution and the function prototype map.
//
// Deviations from c3c:
// - `goto APPEND_QUALIFIERS` / `goto RETRY` are restructured (a flag-free
//   fallthrough to the shared tail, a `while (true)` loop).
// - `'%.*s'` messages take a String slice.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

struct FuncTypeEntry
{
	uint key;
	Type* value;
}

struct FuncMap
{
	uint count;
	uint capacity;
	uint max_load;
	FuncTypeEntry* entries;
}

<* c3c `map` (the function prototype hash map, see type_func_prototype_init). *>
FuncMap map;

// sema_types.c:17 (static)
fn bool sema_resolve_ptr_type(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	// Try to resolve this type shallowly.
	if (!sema_resolve_type(context, type_info.pointer, resolve_kind))
	{
		return type_info_poison(type_info);
	}
	if (!sema_check_ptr_type(context, type_info, type_info.pointer.type)) return type_info_poison(type_info);

	// Construct the type after resolving the underlying type.
	type_info.type = type_get_ptr(type_info.pointer.type);
	type_info.resolve_status = DONE;
	return true;
}

// sema_types.c:32
fn bool sema_resolve_type_info(SemaContext* context, TypeInfo* type_info, ResolveTypeKind kind)
{
	return sema_resolve_type(context, type_info, kind);
}

// sema_types.c:37
fn bool sema_resolve_array_like_len(SemaContext* context, TypeInfo* type_info, ArrayIndex* len_ref)
{
	// Get the expression describing the length.
	Expr* len_expr = type_info.array.len;

	// Analyse it.
	if (!sema_analyse_expr_rvalue(context, len_expr)) return type_info_poison(type_info);

	if (!cast_to_index_len(context, len_expr, true)) return type_info_poison(type_info);

	// A constant expression is assumed.
	if (!sema_cast_const(len_expr))
	{
		@sema_error_at(context, len_expr.loc, "Expected a constant value as length.");
		return type_info_poison(type_info);
	}

	// The constant must be an integer (and not just a distinct integer)
	if (!type_is_integer(len_expr.type.canonical))
	{
		@sema_error_at(context, len_expr.loc, "Expected an integer value.");
		return type_info_poison(type_info);
	}

	bool is_vector = type_info.kind == INFO_VECTOR;

	// Check the length:
	Int len = len_expr.const_expr.ixx;

	// Is it negative?
	if (int_is_neg(len))
	{
		if (is_vector)
		{
			@sema_error_at(context, len_expr.loc, "A vector may not have a negative width.");
		}
		else
		{
			@sema_error_at(context, len_expr.loc, "An array may not have a negative length.");
		}
		return type_info_poison(type_info);
	}

	// Is it zero?
	if (int_is_zero(len))
	{
		if (is_vector)
		{
			@sema_error_at(context, len_expr.loc, "A vector may not have a zero width.");
		}
		else
		{
			@sema_error_at(context, len_expr.loc, "An array may not have zero length.");
		}
		return type_info_poison(type_info);
	}

	// Check max values.
	if (int_icomp(len, is_vector ? (long)compiler.build.max_vector_size / 8 : (long)MAX_ARRAY_SIZE, GT))
	{
		if (is_vector)
		{
			@sema_error_at(context, len_expr.loc, "A vector may not exceed %d in bit width.", compiler.build.max_vector_size);
			return type_info_poison(type_info);
		}
		@sema_error_at(context, len_expr.loc, "The array size may not exceed %d MB.", (long)MAX_ARRAY_SIZE / (1024L * 1024));
		return type_info_poison(type_info);
	}
	// We're done, return the size and mark it as a success.
	*len_ref = (ArrayIndex)(ulong)len.i;
	return true;
}

// sema_types.c:98 (static)
fn bool sema_check_array_type(SemaContext* context, TypeInfo* original_info, Type* base, TypeInfoKind kind, ArrayIndex len, Type** result_ref)
{
	if (base.type_kind == OPTIONAL)
	{
		return @sema_error_at(context, original_info.loc, "You cannot form an array with an optional element type.");
	}
	Type* distinct_base = type_flatten(base);

	if (type_is_infer_type(distinct_base))
	{
		return @sema_error_at(context, original_info.loc, "The array element may not be a type of inferred length.");
	}
	// We don't want to allow arrays with flexible members
	if (distinct_base.type_kind == STRUCT)
	{
		// If the struct is resolved, we can check immediately
		if (distinct_base.decl.resolve_status == DONE)
		{
			if (distinct_base.decl.has_variable_array)
			{
				return @sema_error_at(context, original_info.loc, "Arrays of structs with flexible array members is not allowed.");
			}
		}
		else
		{
			// Otherwise we have to defer it:
			@vec_add(&context.unit.check_type_variable_array, original_info);
		}
	}
	switch (kind)
	{
		case INFO_SLICE:
			if (!type_is_valid_for_array(base))
			{
				return @sema_error_at(context, original_info.loc,
				                      "You cannot form a slice with elements of type %s.",
				                      type_quoted_error_string(base));
			}
			*result_ref = type_get_slice(base);
		case INFO_INFERRED_ARRAY:
			if (!type_is_valid_for_array(base))
			{
				return @sema_error_at(context, original_info.loc,
				                      "You cannot form an array with elements of type %s.",
				                      type_quoted_error_string(base));
			}
			*result_ref = type_get_inferred_array(base);
		case INFO_INFERRED_VECTOR:
			if (!type_is_valid_for_vector(base))
			{
				return @sema_error_at(context, original_info.loc,
				                      "You cannot form a vector with elements of type %s.",
				                      type_quoted_error_string(base));
			}
			*result_ref = type_get_inferred_vector(base);
		case INFO_VECTOR:
			if (!type_is_valid_for_vector(base))
			{
				return @sema_error_at(context, original_info.loc, "You cannot form a vector with elements of type %s.", type_quoted_error_string(base));
			}
			if (original_info.is_simd && !is_power_of_two((ulong)len)) return @sema_error_at(context, original_info.loc, "The length of a @simd vector must be a power of two.");
			*result_ref = type_get_vector(base, original_info.is_simd ? SIMD_VECTOR : VECTOR, (int)len);
		case INFO_ARRAY:
			if (!type_is_valid_for_array(base))
			{
				return @sema_error_at(context, original_info.loc,
				                      "You cannot form an array with elements of type %s.",
				                      type_quoted_error_string(base));
			}
			*result_ref = type_get_array(base, len);
		default:
			unreachable();
	}
	return true;
}

// sema_types.c:179 (static)
fn bool sema_resolve_array_type(SemaContext* context, TypeInfo* type, ResolveTypeKind resolve_kind)
{
	// Check the underlying type
	if (!sema_resolve_type(context, type.array.base, resolve_kind)) return type_info_poison(type);

	ArrayIndex len;
	TypeInfoKind kind = type.kind;
	switch (kind)
	{
		case INFO_ARRAY:
		case INFO_VECTOR:
			if (!sema_resolve_array_like_len(context, type, &len)) return type_info_poison(type);
		default:
			len = 0;
	}
	if (!sema_check_array_type(context, type, type.array.base.type, kind, len, &type.type)) return type_info_poison(type);
	assert(!type.array.len || sema_cast_const(type.array.len));
	type.resolve_status = DONE;
	if (kind == INFO_VECTOR)
	{
		if (kind == INFO_VECTOR && type_size(type.type) > compiler.build.max_vector_size / 8)
		{
			return @sema_error_at(context, type.loc, "Vectors with bitsize over %d are not supported (this vector is %d bits), "
			                      "but you can increase the maximum allowed using '--max-vector-size'.",
			                      compiler.build.max_vector_size, (ulong)type_size(type.type) * 8);
		}
	}
	return true;
}

// sema_types.c:213 (static)
fn bool sema_resolve_type_on_use(SemaContext* context, Decl* decl, TypeInfo* type_info, ResolveTypeKind resolve_type_kind)
{
	decl = decl_flatten(decl);
	switch (decl.decl_kind)
	{
		case ERASED:
			unreachable();
		case STRUCT:
		case BITSTRUCT:
		case UNION:
		case ENUM:
		case INTERFACE:
			type_info.type = decl.type;
			type_info.resolve_status = DONE;
			return true;
		case FNTYPE:
			type_info.type = decl.type;
			type_info.resolve_status = DONE;
			return true;
		case CONSTSET:
		case TYPEDEF:
			if (resolve_type_kind & RESOLVE_TYPE_NO_CHECK_DISTINCT)
			{
				type_info.type = decl.type;
				type_info.resolve_status = DONE;
				return true;
			}
			nextcase TYPE_ALIAS;
		case TYPE_ALIAS:
			if (!sema_analyse_decl(context, decl)) return type_info_poison(type_info);
			type_info.type = decl.type;
			assert(type_info.type.canonical.type_kind != ALIAS);
			type_info.resolve_status = DONE;
			return true;
		case POISONED:
			return type_info_poison(type_info);
		case VAR:
			if (decl.var_decl.kind == PARAM_CT_TYPE || decl.var_decl.kind == LOCAL_CT_TYPE)
			{
				decl_read(decl);
				Expr* init_expr = decl.var_decl.init_expr;
				if (!init_expr)
				{
					if (decl_is_defaulted_var(decl))
					{
						return @sema_error_at(context, type_info.loc, "The parameter '%s' was not provided by the caller.", decl.name);
					}
					return @sema_error_at(context, type_info.loc, "You need to assign a type to '%s' before using it.", decl.name);
				}
				assert(expr_is_const_typeid(init_expr));
				assert(init_expr.resolve_status == DONE);
				type_info.type = init_expr.const_expr.typeid_type;
				return true;
			}
			nextcase ALIAS;
		case ALIAS:
		case ALIAS_PATH:
		case ATTRIBUTE:
		case ENUM_CONSTANT:
		case FAULT:
		case FUNC:
		case IMPORT:
		case LABEL:
		case MACRO:
			@sema_error_at(context, type_info.loc, "This is not a type.");
			return type_info_poison(type_info);
		case BODYPARAM:
		case CT_ASSERT:
		case CT_ECHO:
		case CT_EXEC:
		case CT_EXPAND:
		case CT_INCLUDE:
		case DECLARRAY:
		case GROUP:
		case GENERIC:
		case GENERIC_INSTANCE:
		case CONTRACT:
			unreachable();
	}
}

// sema_types.c:295 (static)
fn bool sema_resolve_type_identifier(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_type_kind)
{
	if (type_info.unresolved.name.ptr == type_string.name.ptr && !type_info.unresolved.path)
	{
		type_info.type = type_string;
		type_info.resolve_status = DONE;
		return true;
	}
	Decl* decl = sema_resolve_symbol(context, type_info.unresolved.name, type_info.unresolved.path, type_info.loc);

	// Already handled
	if (!decl) return type_info_poison(type_info);

	return sema_resolve_type_on_use(context, decl, type_info, resolve_type_kind);
}

<* $Typeof(...) *>
// sema_types.c:314 (static)
fn bool sema_resolve_typeof(SemaContext* context, TypeInfo* type_info)
{
	Expr* expr = type_info.unresolved_type_expr;
	bool in_no_eval = context.call_env.in_no_eval;
	context.call_env.in_no_eval = true;
	bool success = sema_analyse_expr(context, expr);
	context.call_env.in_no_eval = in_no_eval;
	if (!success) return false;
	Type* expr_type = expr.type;
	switch (expr.expr_kind)
	{
		case BUILTIN:
			return @sema_error_at(context, expr.loc, "A builtin function has no defined type.");
		case TYPECALL:
			return @sema_error_at(context, expr.loc, "A type function has no defined type.");
		case ACCESS_RESOLVED:
			if (expr.access_resolved_expr.ref.decl_kind == MACRO)
			{
				return @sema_error_at(context, expr.loc, "A macro has no defined type.");
			}
		case IDENTIFIER:
			if (expr.ident_expr.decl_kind == MACRO)
			{
				return @sema_error_at(context, expr.loc, "A macro has no defined type.");
			}
		default:
			break;
	}
	assert(expr_type != null);
	if (expr_type.type_kind == FUNC_RAW) expr_type = type_get_func_ptr(expr_type);
	switch (sema_resolve_storage_type(context, expr_type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_COMPILE_TIME:
			if (expr_type.type_kind == TYPEINFO) expr_type = type_typeid;
			nextcase STORAGE_NORMAL;
		case STORAGE_NORMAL:
		case STORAGE_VOID:
		case STORAGE_UNKNOWN:
			type_info.type = expr_type;
			return true;
		case STORAGE_WILDCARD:
			if (expr_type.type_kind == OPTIONAL)
			{
				type_info.type = type_get_optional(type_void);
				return true;
			}
			return @sema_error_at(context, expr.loc, "This %sexpression lacks a concrete type.", type_is_optional(expr_type) ? "optional " : "");
	}
	unreachable();
}

// sema_types.c:369
fn TypeInfo* sema_type_info_from_string(SemaContext* context, Expr* expr, bool report_missing)
{
	char* bytes = expr.const_expr.bytes.ptr;
	ArrayIndex len = expr.const_expr.bytes.len;
	String str = (String)bytes[:len];
	ModulePath* path;
	String ident;
	TokenType token = sema_splitpathref(str, len, &path, &ident);
	switch (token)
	{
		case VOID..UNTYPEDLIST:
			if (path) break;
			return type_info_new_base(type_from_token(token), expr.loc);
		case CT_TYPE_IDENT:
		case TYPE_IDENT:
			if (path && token == CT_TYPE_IDENT) break;
			if (!ident.ptr)
			{
				if (!report_missing) return null;
				@sema_error_at(context, expr.loc, "'%s' could not be found, did you spell it right?", str);
				return poisoned_type_info;
			}
			TypeInfo* info = type_info_new(token == CT_TYPE_IDENT ? INFO_CT_IDENTIFIER : INFO_IDENTIFIER, expr.loc);
			info.unresolved.name = ident;
			info.unresolved.path = path;
			return info;
		case INVALID_TOKEN:
			@sema_error_at(context, expr.loc, "'%s' could not be resolved to a valid symbol.", str);
			return poisoned_type_info;
		default:
			@sema_error_at(context, expr.loc, "Expected a type, not a regular identifier '%s'.", str);
			return poisoned_type_info;
	}
	@sema_error_at(context, expr.loc, "Unexpected path in '%s'.", str);
	return poisoned_type_info;
}

// sema_types.c:407 (static)
fn bool sema_resolve_typefrom(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	Expr* expr = type_info.unresolved_type_expr;
	if (!sema_analyse_expr_rvalue(context, expr)) return false;
	if (!sema_cast_const(expr))
	{
		return @sema_error_at(context, expr.loc, "Expected a constant value.");
	}
	switch (expr.const_expr.const_kind)
	{
		case TYPEID:
			type_info.type = expr.const_expr.typeid_type;
			return true;
		case STRING:
			break;
		default:
			return @sema_error_at(context, expr.loc, "Expected a constant string or typeid value.");
	}

	String str = (String)expr.const_expr.bytes.ptr[:expr.const_expr.bytes.len];
	TypeInfo* info = sema_type_info_from_string(context, expr, true);
	if (!type_info_ok(info)) return false;
	if (!sema_resolve_type(context, info, resolve_kind)) return false;
	switch (sema_resolve_storage_type(context, info.type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_VOID:
		case STORAGE_UNKNOWN:
		case STORAGE_NORMAL:
			type_info.type = info.type;
			return true;
		case STORAGE_WILDCARD:
			return @sema_error_at(context, expr.loc, "$Typefrom failed to resolve \"%s\" to a definite type.", str);
		case STORAGE_COMPILE_TIME:
			return @sema_error_at(context, expr.loc, "$Typefrom does not support compile-time types.");
	}
	unreachable();
}

// sema_types.c:449
fn bool sema_unresolved_type_is_generic(SemaContext* context, TypeInfo* type_info)
{
	Decl* seen = null;
	int steps = 0;
	while (true) // RETRY
	{
		if (type_info.kind == INFO_GENERIC) return true;
		if (type_info.resolve_status == DONE) return false;
		if (type_info.kind != INFO_IDENTIFIER) return false;
		if (type_info.subtype != TYPE_COMPRESSED_NONE) return false;
		Decl* decl = sema_find_path_symbol(context, type_info.unresolved.name, type_info.unresolved.path);
		if (!decl) return false;
		if (decl.decl_kind != TYPE_ALIAS) return false;
		if (decl.resolve_status == DONE) return false;
		// Brent's method to detect recursion.
		if (decl == seen) return false;
		steps++;
		if ((steps & (steps - 1)) == 0) seen = decl;
		if (decl.type_alias_decl.is_func) return false;
		Expr* expr = decl.type_alias_decl.type_expr;
		if (expr.expr_kind != TYPEINFO) return false;
		type_info = expr.type_expr;
	}
}

<* Foo{...} *>
// sema_types.c:474 (static)
fn bool sema_resolve_generic_type(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	TypeInfo* inner = type_info.generic.base;
	if (inner.kind != INFO_IDENTIFIER || inner.subtype != TYPE_COMPRESSED_NONE || inner.optional)
	{
		return @sema_error_at(context, inner.loc, "Parameterization required a concrete type name here.");
	}
	switch (inner.resolve_status)
	{
		case DONE:
			return @sema_error_at(context, inner.loc, "A user-defined generic type was expected here, but the type was %s.", type_quoted_error_string(inner.type));
		case RUNNING:
			return @sema_error_at(context, inner.loc, "Resolving the type %s entered a recursive loop.", type_quoted_error_string(inner.type));
		default:
			break;
	}
	if (compiler.generic_depth >= MAX_GENERIC_DEPTH)
	{
		return @sema_error_at(context, type_info.loc, "Generic resolution of this type has become deeply nested, it was aborted after reaching %d recursions.", compiler.generic_depth);
	}
	compiler.generic_depth++;
	Decl* type = sema_analyse_parameterized_identifier(context, inner.unresolved.path, inner.unresolved.name,
	                                                   inner.loc, type_info.generic.params, type_info.loc);
	compiler.generic_depth--;
	if (!decl_ok(type)) return false;
	assert(type != null);
	type_info.type = type.type;
	if (compiler.generic_depth != 0)
	{
		if (!context.current_macro && (context.call_env.kind == ENV_FUNCTION || context.call_env.kind == ENV_FUNCTION_STATIC)
			&& !context.call_env.current_function.func_decl.in_macro && !context.generic_instance)
		{
			return @sema_error_at(context, type_info.loc, "Recursively generic type declarations are only allowed inside of macros. Use `alias` to define an alias for the type instead.");
		}
	}
	return sema_resolve_type_on_use(context, type, type_info, resolve_kind);
}

// sema_types.c:512 (static)
fn bool sema_check_ptr_type(SemaContext* context, TypeInfo* type_info, Type* inner)
{
	CanonicalType* type = inner.canonical;
	switch (type.type_kind)
	{
		case TYPEINFO:
		case INFERRED_ARRAY:
		case INFERRED_VECTOR:
		case POISONED:
		case MEMBER:
		case WILDCARD:
		case REFLECTION:
		case UNTYPEDLIST:
			if (type_is_infer_type(type))
			{
				return @sema_error_at(context, type_info.loc, "A pointer to a type of inferred length is not supported.");
			}
			return @sema_error_at(context, type_info.loc, "Pointers to %s are not supported.", type_quoted_error_string(inner));
		default:
			return true;
	}
}

// sema_types.c:529 (static)
fn bool sema_resolve_type(SemaContext* context, TypeInfo* type_info, ResolveTypeKind resolve_kind)
{
	// Ok, already resolved.
	if (type_info.resolve_status == DONE) return type_info_ok(type_info);

	// We might have the resolve already running, if so then that's bad.
	if (type_info.resolve_status == RUNNING)
	{
		if (type_info.kind == INFO_GENERIC)
		{
			@sema_error_at(context, type_info.loc, "Circular dependency resolving generic type.");
		}
		else
		{
			@sema_error_at(context, type_info.loc,
			               "Circular dependency resolving type '%s'.",
			               type_info.unresolved.name);
		}
		return type_info_poison(type_info);
	}

	type_info.resolve_status = RUNNING;
	TypeInfoCompressedKind kind = type_info.subtype;
	switch (kind)
	{
		case TYPE_COMPRESSED_NONE:
		case TYPE_COMPRESSED_PTR:
		case TYPE_COMPRESSED_SUBPTR:
		case TYPE_COMPRESSED_PTRPTR:
		case TYPE_COMPRESSED_PTRSUB:
			break;
		case TYPE_COMPRESSED_SUB:
		case TYPE_COMPRESSED_SUBSUB:
			resolve_kind = resolve_kind & ~RESOLVE_TYPE_NO_CHECK_DISTINCT;
	}
	switch (type_info.kind)
	{
		case INFO_POISON:
			unreachable();
		case INFO_GENERIC:
			if (!sema_resolve_generic_type(context, type_info, resolve_kind)) return type_info_poison(type_info);
		case INFO_CT_IDENTIFIER:
		case INFO_IDENTIFIER:
			// $Type or Foo
			if (!sema_resolve_type_identifier(context, type_info, resolve_kind)) return type_info_poison(type_info);
		case INFO_TYPEOF:
			if (!sema_resolve_typeof(context, type_info)) return type_info_poison(type_info);
		case INFO_TYPEFROM:
			if (!sema_resolve_typefrom(context, type_info, resolve_kind)) return type_info_poison(type_info);
		case INFO_INFERRED_VECTOR:
		case INFO_INFERRED_ARRAY:
			if (!(resolve_kind & RESOLVE_TYPE_ALLOW_INFER)
				&& (type_info.kind != INFO_INFERRED_ARRAY || !(resolve_kind & RESOLVE_TYPE_ALLOW_FLEXIBLE)))
			{
				@sema_error_at(context, type_info.loc, "Inferred %s types can only be used in declarations with initializers and as macro parameters.",
				               type_info.kind == INFO_INFERRED_VECTOR ? "vector" : "array");
				return type_info_poison(type_info);
			}
			nextcase INFO_SLICE;
		case INFO_SLICE:
		case INFO_ARRAY:
		case INFO_VECTOR:
			if (!sema_resolve_array_type(context, type_info, resolve_kind & ~RESOLVE_TYPE_NO_CHECK_DISTINCT))
			{
				return type_info_poison(type_info);
			}
		case INFO_POINTER:
			if (!sema_resolve_ptr_type(context, type_info, resolve_kind)) return type_info_poison(type_info);
	}
	// APPEND_QUALIFIERS:
	Type* type = type_no_optional(type_info.type);
	switch (kind)
	{
		case TYPE_COMPRESSED_NONE:
			break;
		case TYPE_COMPRESSED_PTR:
			if (!sema_check_ptr_type(context, type_info, type)) return type_info_poison(type_info);
			type = type_get_ptr(type);
		case TYPE_COMPRESSED_SUB:
			if (!sema_check_array_type(context, type_info, type, INFO_SLICE, 0, &type)) return type_info_poison(type_info);
		case TYPE_COMPRESSED_SUBPTR:
			if (!sema_check_array_type(context, type_info, type, INFO_SLICE, 0, &type)) return type_info_poison(type_info);
			type = type_get_ptr(type);
		case TYPE_COMPRESSED_PTRPTR:
			if (!sema_check_ptr_type(context, type_info, type)) return type_info_poison(type_info);
			type = type_get_ptr(type_get_ptr(type));
		case TYPE_COMPRESSED_PTRSUB:
			if (!sema_check_ptr_type(context, type_info, type)) return type_info_poison(type_info);
			type = type_get_slice(type_get_ptr(type));
		case TYPE_COMPRESSED_SUBSUB:
			if (!sema_check_array_type(context, type_info, type, INFO_SLICE, 0, &type)) return type_info_poison(type_info);
			type = type_get_slice(type);
	}
	if (type.type_kind == UNTYPEDLIST && type_info.optional)
	{
		@sema_error_at(context, type_info.loc, "%s cannot be used as an optional type, since it is compile-time only.", type_quoted_error_string(type));
		return type_info_poison(type_info);
	}

	type_info.type = type_add_optional(type, type_info.optional || type_is_optional(type_info.type));
	type_info.resolve_status = DONE;
	return true;
}

// sema_types.c:662
fn void type_func_prototype_init(uint capacity)
{
	assert(is_power_of_two(capacity) && capacity > 1);
	map.entries = calloc_arena(capacity * FuncTypeEntry::size);
	map.capacity = capacity;
	map.max_load = (uint)(TABLE_MAX_LOAD * capacity);
}

// sema_types.c:670 (static)
fn Type* flatten_raw_function_type(Type* type)
{
	Type* other;
	Type* current;
	switch (type.type_kind)
	{
		case ALIAS:
			return flatten_raw_function_type(type.canonical);
		case FUNC_RAW:
			return type.function.prototype.raw_type;
		case OPTIONAL:
			current = type.optional;
			other = flatten_raw_function_type(current);
			return other == current ? type : type_get_optional(other);
		case FUNC_PTR:
			current = type.pointer;
			other = flatten_raw_function_type(current);
			return other == current ? type : type_get_func_ptr(other);
		case POINTER:
			current = type.pointer;
			other = flatten_raw_function_type(current);
			return other == current ? type : type_get_ptr(other);
		case ARRAY:
			current = type.array.base;
			other = flatten_raw_function_type(current);
			return other == current ? type : type_get_array(other, type.array.len);
		case SLICE:
			current = type.array.base;
			other = flatten_raw_function_type(current);
			return other == current ? type : type_get_slice(other);
		case FLEXIBLE_ARRAY:
			current = type.array.base;
			other = flatten_raw_function_type(current);
			return other == current ? type : type_get_flexible_array(other);
		case INFERRED_ARRAY:
			current = type.array.base;
			other = flatten_raw_function_type(current);
			return other == current ? type : type_get_inferred_array(other);
		default:
			return type;
	}
}

// sema_types.c:712 (static)
fn uint hash_function(Signature* sig)
{
	uptr hash = sig.variadic == RAW ? 0 : 1;
	Type* rtype = typeget(sig.rtype);
	hash = hash * 31 + (uptr)flatten_raw_function_type(rtype);
	if (sig.attrs.is_simd && type_flat_is_vector(rtype)) hash++;
	foreach (param : sig.params)
	{
		hash = hash * 31 + (uptr)flatten_raw_function_type(param.type.canonical);
	}
	return (uint)((hash >> 16) ^ hash);
}

// sema_types.c:726 (static)
fn Type* func_create_new_func_proto(Signature* sig, CallABI abi, uint hash, FuncTypeEntry* entry)
{
	usz param_count = sig.params.len;
	FunctionPrototype* proto = calloc_arena(FunctionPrototype::size);
	Type* rtype = type_infoptr(sig.rtype).type;
	Decl*[] param_copy = {};
	if (param_count)
	{
		for (usz i = 0; i < param_count; i++)
		{
			Decl* decl = decl_copy(sig.params[i]);
			decl.type = decl.type.canonical;
			decl.var_decl.type_info = 0;
			decl.var_decl.init_expr = null;
			decl.name = {};
			@vec_add(&param_copy, decl);
		}
	}

	scratch_buffer_clear();
	scratch_buffer_append("fn ");
	type_append_name_to_scratch(rtype.canonical);
	scratch_buffer_append_char('(');
	foreach (idx, val : sig.params)
	{
		if (idx != 0) scratch_buffer_append(", ");
		type_append_name_to_scratch(val.type.canonical);
	}
	scratch_buffer_append_char(')');
	Type* type = type_new(FUNC_RAW, scratch_buffer_interned());
	Signature* copy_sig = calloc_arena(Signature::size);
	*copy_sig = *sig;
	copy_sig.attrs = { .nodiscard = false };
	copy_sig.params = param_copy;
	proto.raw_type = type;
	type.function.prototype = proto;
	type.function.decl = null;
	type.function.signature = copy_sig;
	type.canonical = type;
	entry.key = hash;
	entry.value = type;

	map.count++;
	if (map.count >= map.max_load)
	{
		FuncTypeEntry* entries = map.entries;
		uint old_capacity = map.capacity;
		uint new_capacity = map.capacity = old_capacity << 2;
		map.max_load = (uint)(new_capacity * TABLE_MAX_LOAD);
		FuncTypeEntry* new_map = calloc_arena(new_capacity * FuncTypeEntry::size);
		uint new_mask = new_capacity - 1;
		for (uint i = 0; i < old_capacity; i++)
		{
			uint key = entries[i].key;
			if (!key) continue;
			uint index = key & new_mask;
			while (true)
			{
				entry = &new_map[index];
				if (!entry.key)
				{
					entry.key = key;
					entry.value = entries[i].value;
					break;
				}
				index = (index + 1) & new_mask;
			}
		}
		map.entries = new_map;
	}
	return type;
}

// sema_types.c:801 (static)
fn bool compare_func_param(Type* one, Type* other)
{
	if (one == other) return true;
	one = one.canonical;
	other = other.canonical;
	if (one == other) return true;
	if (one.type_kind != other.type_kind) return false;
	switch (one.type_kind)
	{
		case POINTER:
		case FUNC_PTR:
			return compare_func_param(one.pointer, other.pointer);
		case ARRAY:
			if (one.array.len != other.array.len) return false;
			nextcase SLICE;
		case SLICE:
		case FLEXIBLE_ARRAY:
			return compare_func_param(one.array.base, other.array.base);
		case FUNC_RAW:
			return one.function.prototype.raw_type == other.function.prototype.raw_type;
		case OPTIONAL:
			return compare_func_param(one.optional, other.optional);
		default:
			return false;
	}
}

// sema_types.c:828 (static)
fn int compare_function(Signature* sig, FunctionPrototype* proto)
{
	bool is_raw_variadic = sig.variadic == RAW;
	if (is_raw_variadic != proto.raw_variadic) return -1;
	Decl*[] params = sig.params;
	Signature* raw_sig = proto.raw_type.function.signature;
	Decl*[] other_params = raw_sig.params;
	usz param_count = params.len;
	if (param_count != other_params.len) return -1;
	if (!compare_func_param(typeget(sig.rtype), typeget(proto.raw_type.function.signature.rtype))) return -1;
	foreach (i, param : params)
	{
		Type* other_param = other_params[i].type;
		if (!compare_func_param(param.type.canonical, other_param.canonical)) return -1;
	}
	return 0;
}

// sema_types.c:846
fn Type* sema_resolve_type_get_func(Signature* signature, CallABI abi)
{
	uint hash = hash_function(signature);
	uint mask = map.capacity - 1;
	uint index = hash & mask;
	FuncTypeEntry* entries = map.entries;
	while (true)
	{
		FuncTypeEntry* entry = &entries[index];
		if (!entry.key)
		{
			return func_create_new_func_proto(signature, abi, hash, entry);
		}
		if (entry.key == hash && compare_function(signature, entry.value.function.prototype) == 0)
		{
			return entry.value;
		}
		index = (index + 1) & mask;
	}
}
