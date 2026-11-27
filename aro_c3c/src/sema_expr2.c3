// Port of the second half of c3c src/compiler/sema_expr.c (from line 7050;
// revision 54bab366a): access/swizzle, assignment and op-assign, binary and
// unary operators, comparisons, $defined / compile-time builtins, lambdas,
// the expression dispatchers and sema_analyse_expr*. Same module and
// conventions as sema_expr.c3, split so two files can be ported independently.
//
// Deviations from c3c:
// - gotos are restructured (flags, `while (true)` + continue/break, nextcase,
//   inlined failure tails); c3c's RESOLVE(expr, check) macro is expanded
//   inline in sema_analyse_expr / sema_analyse_expr_lvalue.
// - Function-local static tables become module consts / helpers:
//   SEMA_OP_ASSIGN_OVERLOAD_MAP, SEMA_OP_BASE_OVERLOAD_MAP (indexed by
//   BinaryOp.ordinal) and binop_prec_req() for BINOP_PREC_REQ[].
//   sema_expr_check_discard_error_args() stands in for its ERROR_ARGS label.
// - A NULL `Expr**` / `const char*` result is an empty slice / String tested
//   with `.ptr` (sema_vasplat_insert, the splat inserts, sema_addr_*).
// - Runtime format strings: `RETURN_SEMA_ERROR(node, error)` with a runtime
//   `error` is `@sema_error_at(..., "%s", error)`; the variadic error in
//   sema_binary_arithmetic_promotion calls sema_verror_range directly (no
//   inline notes). The "%% by zero" / "Division by zero" ternary is two calls.
// - sema_expr_check_shift_rhs: the "right hand shift must be an integer type"
//   error drops c3c's surplus left-type argument (its format has one %s).
// - sema_expr_analyse_lenof: c3c reads `expr` (the $lenof itself) for an
//   untyped list; the port reads `inner`.
// - sema_string_ident_token looks up with symtab_find (own hashing) instead
//   of an explicit fnv1a hash.
// - sema_expr_analyse_ct_stringify: span_to_string never fails yet, so the
//   "Failed to stringify" error cannot fire.
// - BoolErr functions return BOOL_TRUE / BOOL_FALSE; c3c truthy tests are
//   `!= BOOL_FALSE` (BOOL_ERR counts as true, like C).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_expr.c:7050
fn bool sema_expr_rewrite_insert_deref(SemaContext* context, Expr* original)
{
	if (expr_is_const_pointer(original) && !original.const_expr.ptr && !context.call_env.in_no_eval)
	{
		return @sema_error_at(context, original.loc, "This value is known to be null so you cannot dereference it.");
	}
	// Assume *(&x) => x
	if (original.expr_kind == UNARY && original.unary_expr.operator == ADDR)
	{
		*original = *original.unary_expr.expr;
		return true;
	}

	// Allocate our new and create our new inner, and overwrite the original.
	Expr* inner = expr_copy(original);
	original.expr_kind = UNARY;
	original.type = null;
	original.unary_expr = { .operator = DEREF, .expr = inner };

	// In the case the original is already resolved, we want to resolve the deref as well.
	if (original.resolve_status == DONE)
	{
		Type* no_fail = type_no_optional(inner.type);
		assert(no_fail.canonical.type_kind == POINTER);

		// Only fold to the canonical type if it wasn't a pointer.
		Type* pointee = no_fail.type_kind == POINTER ? no_fail.pointer : no_fail.canonical.pointer;
		original.type = type_add_optional(pointee, @is_optional(inner));
	}
	return true;
}

// sema_expr.c:7082
fn bool sema_check_swizzle_string(SemaContext* context, Expr* expr, String kw, int len, int vec_len, bool* is_overlapping_ref, int* index_ref)
{
	int index = 0;
	bool is_overlapping = false;
	for (int i = 0; i < len; i++)
	{
		char val = (char)(swizzle[kw[i]] - 1);
		if ((val & 0xF) >= vec_len)
		{
			if (!expr) return false;
			return @sema_error_at(context, expr.loc, "The '%c' component is not present in a vector of length %d, did you assume a longer vector?", kw[i], vec_len);
		}
		if (i == 0)
		{
			index = (int)val;
		}
		if (((index ^ (int)val) & 0x10) != 0)
		{
			if (!expr) return false;
			return @sema_error_at(context, expr.loc, "Mixing [xyzw] and [rgba] is not permitted, you will need to select one of them.");
		}
		if (!is_overlapping)
		{
			for (int j = 0; j < i; j++)
			{
				char prev = (char)(swizzle[kw[j]] - 1);
				if (val == prev)
				{
					is_overlapping = true;
					break;
				}
			}
		}
	}
	*index_ref = index & 0xF;
	*is_overlapping_ref = is_overlapping;
	return true;
}

// sema_expr.c:7120 (static)
fn bool sema_expr_analyse_swizzle(SemaContext* context, Expr* expr, Expr* parent, Type* flat_type, String kw, int len)
{
	int vec_len = (int)flat_type.array.len;
	Type* indexed_type = type_get_indexed_type(parent.type);
	// c3c: assert(indexed_type); -- C assert, compiled out in c3c release builds
	bool is_ref = expr.access_unresolved_expr.is_ref;
	bool is_lvalue = expr.access_unresolved_expr.is_lvalue;
	if (is_lvalue) is_ref = false;
	assert(len > 0);
	bool is_overlapping = false;
	int index;
	if (!sema_check_swizzle_string(context, expr, kw, len, vec_len, &is_overlapping, &index)) return false;
	if (len == 1)
	{
		expr.expr_kind = is_ref ? SUBSCRIPT_ADDR : SUBSCRIPT;
		expr.subscript_expr = {
			.index = { .expr = exprid(expr_new_const_int(expr.loc, type_sz, (ulong)index)) },
			.expr = exprid(parent),
			.ref = is_ref
		};
		if (is_lvalue)
		{
			if (!sema_expr_analyse_subscript_lvalue(context, expr, null)) return false;
		}
		else
		{
			if (!sema_expr_analyse_subscript(context, expr, null)) return false;
		}
		expr.resolve_status = DONE;
		if (is_ref)
		{
			if (!sema_expr_rewrite_insert_deref(context, expr)) return false;
		}
		return true;
	}
	Type* result = type_get_vector(indexed_type, flat_type.type_kind, len);
	expr.expr_kind = SWIZZLE;
	expr.swizzle_expr = { .parent = exprid(parent), .swizzle = kw, .is_overlapping = is_overlapping };
	expr.type = type_add_optional(result, @is_optional(parent));
	return true;
}

// sema_expr.c:7163 (static)
fn bool sema_analyse_maybe_dead_expr(SemaContext* context, Expr* expr, bool is_dead, Type* infer_type)
{
	if (!is_dead || context.active_scope.is_dead)
	{
		return infer_type ? sema_analyse_inferred_expr(context, infer_type, expr, null) : sema_analyse_expr_rvalue(context, expr);
	}
	context.active_scope.is_dead = true;
	bool success = infer_type ? sema_analyse_inferred_expr(context, infer_type, expr, null) : sema_analyse_expr_rvalue(context, expr);
	context.active_scope.is_dead = false;
	return success;
}

// sema_expr.c:7174
fn bool sema_kw_is_swizzle(String kw, int len)
{
	for (int i = 0; i < len; i++)
	{
		if (!swizzle[kw[i]]) return false;
	}
	return true;
}

// sema_expr.c:7183 (static)
fn void sema_expr_flatten_const_ident(Expr* expr)
{
	if (expr.expr_kind != IDENTIFIER) return;
	Decl* ident = expr.ident_expr;
	if (ident.decl_kind != VAR) return;
	switch (ident.var_decl.kind)
	{
		case CONST:
		case LOCAL_CT:
		case PARAM_CT:
			break;
		case GLOBAL:
		case LOCAL:
		case PARAM:
		case MEMBER:
		case BITMEMBER:
		case PARAM_EXPR:
		case UNWRAPPED:
		case ERASE:
		case REWRAPPED:
		case PARAM_CT_TYPE:
		case LOCAL_CT_TYPE:
			return;
	}
	Expr* init_expr = ident.var_decl.init_expr;
	if (!init_expr || init_expr.resolve_status != DONE) return;
	sema_expr_flatten_const_ident(init_expr);
	if (expr_is_const(init_expr))
	{
		expr_replace(expr, copy_expr_single(init_expr));
	}
}

// sema_expr.c:7216 (static)
fn bool sema_expr_analyse_type_property(SemaContext* context, Expr* expr, bool* missing_ref)
{
	Expr* parent = expr.type_property_expr.type;
	if (missing_ref) *missing_ref = false;
	if (!sema_analyse_expr(context, parent)) return false;
	Type* parent_type = parent.type_expr.type;
	String name = expr.type_property_expr.property;
	TypeProperty property = type_property_by_name(name);
	Type* canonical = parent_type.canonical;
	if (sema_type_property_is_valid_for_type(canonical, property))
	{
		return sema_expr_rewrite_to_type_property(context, expr, canonical, property, parent_type);
	}
	if (missing_ref)
	{
		*missing_ref = true;
		return false;
	}
	return @sema_error_at(context, expr.type_property_expr.token_span, "'%s' is not a valid property for %s.", name, type_quoted_error_string(parent_type));
}

// sema_expr.c:7233 (static)
fn bool sema_kw_is_non_runtime_type_property(String kw)
{
	return type_property_by_name(kw) != PROPERTY_NONE;
}

// sema_expr.c:7240 (static)
<*
 Analyse "x.y". The c3c gotos are restructured: CHECK_IF_CALLABLE is a flag,
 CHECK_DEEPER / FOUND_MEMBER_REFLECT a loop, MISSING_REF is inlined.
*>
fn bool sema_expr_analyse_access(SemaContext* context, Expr* expr, bool* missing_ref)
{
	Expr* parent = expr.access_unresolved_expr.parent;
	if (missing_ref) *missing_ref = false;

	int times_to_deref = 1;
	if (parent.expr_kind == SUBSCRIPT && !parent.subscript_expr.ref)
	{
		parent.subscript_expr.prefer_ref = true;
	}
	else if (expr.access_unresolved_expr.is_ref)
	{
		times_to_deref = 2;
		expr_set_to_ref(parent);
	}

	// 1. Resolve the left hand
	if (!sema_analyse_expr(context, parent)) return false;

	// 2. The right hand side may be a @ident or ident
	Expr* child = expr.access_unresolved_expr.child;

	if (child.expr_kind == TYPEINFO) return @sema_error_at(context, child.loc, "A type can't appear here.");

	// 3. Find the actual token.
	bool is_reflect = false;
	Expr* identifier = sema_expr_resolve_access_child(context, child, missing_ref, &is_reflect);
	if (!identifier) return false;
	Decl* member = null;
	Decl* decl = null;
	Expr* current_parent;
	bool optional;
	String kw;
	Type* underlying_type;
	Type* type = null;
	Type* flat_type = null;
	TypeKind flat_kind = POISONED;
	if (is_reflect)
	{
		Expr* reflect = identifier.const_expr.reflection;
		if (!expr_is_const_member(reflect)) return @sema_error_at(context, identifier.loc, "Expected a member reference.");
		optional = @is_optional(parent);
		underlying_type = type_no_optional(parent.type).canonical;
		if (underlying_type.type_kind == POINTER)
		{
			if (!sema_expr_rewrite_insert_deref(context, parent)) return false;
		}
		member = reflect.const_expr.member.decl;
		kw = member.name;
		TypeKind target_kind;
		ArrayIndex index;
		if (!sema_analyse_member_in_type(context, member, parent, &target_kind, &index)) return false;
		decl = underlying_type.decl;
		current_parent = parent;
	}
	else
	{
		kw = identifier.unresolved_ident_expr.ident;

		bool check_if_callable = false;
		switch (parent.expr_kind)
		{
			case TYPEINFO:
				// 2. If our left-hand side is a type, e.g. MyInt.abc, handle this here.
				return sema_expr_analyse_type_access(context, expr, parent.type_expr.type, identifier, missing_ref);
			case CONST:
				switch (parent.const_expr.const_kind)
				{
					case REF:
						decl = parent.const_expr.global_ref;
						check_if_callable = true;
					case REFLECTION:
						return sema_expr_analyse_reflection_access(context, expr, parent, identifier, missing_ref);
					case MEMBER:
						return sema_expr_analyse_member_access(context, expr, parent, identifier, missing_ref);
					default:
						break;
				}
			case IDENTIFIER:
				decl = parent.ident_expr;
				check_if_callable = true;
			default:
				break;
		}
		if (check_if_callable)
		{
			switch (decl.decl_kind)
			{
				case FUNC:
				case MACRO:
					return sema_analyse_macro_func_access(context, expr, decl, identifier, kw, missing_ref);
				default:
					break;
			}
			if (parent.type.type_kind == FUNC_RAW)
			{
				return sema_expr_analyse_type_access(context, expr, parent.type, identifier, missing_ref);
			}
		}

		if (!sema_may_subscript_or_access(context, parent, "have neither methods nor fields", missing_ref)) return false;

		// 6. Copy failability
		optional = @is_optional(parent);

		assert(expr.expr_kind == ACCESS_UNRESOLVED);
		assert(parent.resolve_status == DONE);

		// 7. Is this a pointer? If so we insert a deref.
		underlying_type = type_no_optional(parent.type).canonical;
		while (times_to_deref > 0 && underlying_type.type_kind == POINTER && underlying_type != type_voidptr)
		{
			times_to_deref--;
			if (!sema_cast_rvalue(context, parent, true)) return false;
			if (!sema_expr_rewrite_insert_deref(context, expr.access_unresolved_expr.parent)) return false;
			parent = expr.access_unresolved_expr.parent;
			underlying_type = type_no_optional(parent.type).canonical;
		}

		// 8. Depending on parent type, we have some hard coded types
		current_parent = parent;

		type = type_no_optional(parent.type).canonical;
		flat_type = type_flatten(type);
		flat_kind = flat_type.type_kind;
		if (kw_type.ptr == kw.ptr)
		{
			if (type_is_any_raw(flat_type))
			{
				expr_rewrite_to_builtin_access(expr, parent, TYPEOFANY, type_typeid);
				return true;
			}
			if (flat_kind == ANYFAULT)
			{
				expr_rewrite_to_builtin_access(expr, parent, TYPEOFANYFAULT, type_typeid);
				return true;
			}
		}
	}

	bool found_member_reflect = is_reflect;
	while (true)
	{
		if (!found_member_reflect)
		{
			// CHECK_DEEPER:

			// 9. Fix hard coded function `len` on slices and arrays
			if (kw.ptr == kw_len.ptr)
			{
				ArrayIndex index = sema_len_from_expr(current_parent);

				if (index > -1)
				{
					expr_rewrite_const_int(expr, type_sz, (ulong)index);
					return true;
				}
				switch (flat_kind)
				{
					case SLICE:
						if (!sema_type_has_subscript_overloads(type))
						{
							expr_rewrite_slice_len(expr, current_parent, type_sz);
							return true;
						}
					case ARRAY:
					case VECTOR:
					case SIMD_VECTOR:
						assert(sema_type_has_subscript_overloads(type));
					default:
						break;
				}
			}
			if (flat_kind == TYPEID)
			{
				bool was_error = false;
				if (sema_expr_rewrite_to_typeid_property(context, expr, current_parent, kw, &was_error)) return !was_error;
			}
			if (type_kind_is_real_vector(flat_kind))
			{
				int len = (int)kw.len;
				if (sema_kw_is_swizzle(kw, len))
				{
					return sema_expr_analyse_swizzle(context, expr, current_parent, flat_type, kw, len);
				}
			}
			// Hard coded ptr on slices and any
			if (kw.ptr == kw_ptr.ptr)
			{
				if (flat_kind == SLICE)
				{
					expr_rewrite_ptr_access(expr, current_parent, type_get_ptr(flat_type.array.base));
					return true;
				}
				if (type_is_any_raw(flat_type))
				{
					expr_rewrite_ptr_access(expr, current_parent, type_voidptr);
					return true;
				}
			}
			if (kw.ptr == kw_ordinal.ptr && flat_kind == ENUM)
			{
				if (expr.access_unresolved_expr.is_ref)
				{
					if (missing_ref)
					{
						*missing_ref = true;
						return false;
					}
					return @sema_error_at(context, expr.loc, "The ordinal is a value, it can't be assigned to or have its address taken.");
				}
				sema_expr_convert_enum_to_int(current_parent);
				expr_replace(expr, current_parent);
				return true;
			}
			if (kw.ptr == kw_description.ptr)
			{
				if (flat_type.type_kind == CONSTSET)
				{
					if (sema_cast_const(current_parent))
					{
						expr_rewrite_const_string_from_raw(expr, current_parent.const_expr.enum_val.name);
						return true;
					}
				}
				if (flat_kind == ENUM)
				{
					if (sema_cast_const(current_parent))
					{
						expr_rewrite_const_string_from_raw(expr, current_parent.const_expr.enum_val.name);
						return true;
					}
					expr_rewrite_to_builtin_access(expr, current_parent, ENUMNAME, type_string);
					return true;
				}
				if (flat_type == type_fault)
				{
					if (sema_cast_const(current_parent))
					{
						Decl* fault_ = current_parent.const_expr.fault_val;
						if (!fault_)
						{
							expr_rewrite_const_string_from_raw(expr, "null");
							return true;
						}
						scratch_buffer_clear();
						String module_name = fault_.unit.mod.name.module_name;
						// strrchr(module_name, ':')
						usz last_start = 0;
						for (usz i = module_name.len; i > 0; i--)
						{
							if (module_name[i - 1] == ':')
							{
								last_start = i;
								break;
							}
						}
						scratch_buffer_append(module_name[last_start..]);
						scratch_buffer_append("::");
						scratch_buffer_append(fault_.name);
						expr_rewrite_const_string_from_scratch(expr);
						return true;
					}
					expr_rewrite_to_builtin_access(expr, current_parent, FAULTNAME, type_string);
					return true;
				}
			}

			// 9. At this point we may only have distinct, struct, union, error, enum, interface
			if (!type_may_have_sub_elements(type))
			{
				Decl* method = sema_resolve_type_method(context, type, kw);
				if (!method)
				{
					if (missing_ref)
					{
						@vec_add(&compiler.context.types_with_failed_methods, type);
						*missing_ref = true;
						return false;
					}
					if (type == type_typeid && sema_kw_is_non_runtime_type_property(kw))
					{
						return @sema_error_at(context, expr.loc, "The type property '%s' is only available at compile time, but this expression is evaluated at runtime. If possible, try making the expression constant.", kw);
					}
					return @sema_error_at(context, expr.loc, "There is no member or method '%s' on %s", kw, type_quoted_error_string(parent.type));
				}

				assert(expr.expr_kind == ACCESS_UNRESOLVED);
				expr.type = method.type ? type_add_optional(method.type, optional) : null;
				expr.access_resolved_expr = { .parent = current_parent, .ref = method };
				expr.expr_kind = ACCESS_RESOLVED;
				return true;
			}

			// 10. Dump all members and methods into a decl stack.
			decl = type.decl;

			member = sema_decl_stack_find_decl_member(context, decl, kw, METHODS_INTERFACES_AND_FIELDS);
			if (!decl_ok(member)) return false;
		}
		found_member_reflect = false;

		// FOUND_MEMBER_REFLECT:
		if (member && decl.decl_kind == ENUM && member.decl_kind == VAR && sema_cast_const(parent))
		{
			if (!sema_analyse_decl(context, decl)) return false;
			Decl* ref = current_parent.const_expr.enum_val;
			if (!sema_analyse_decl(context, ref)) return false;
			assert(current_parent.const_expr.const_kind == ENUM);
			Expr* copy_init = copy_expr_single(ref.enum_constant.associated[member.var_decl.index]);
			expr_replace(expr, copy_init);
			assert(copy_init.resolve_status == DONE);
			return true;
		}
		Decl* private_ = null;
		if (!member && decl.decl_kind == INTERFACE)
		{
			Decl* inf = null;
			foreach (parent_interface : decl.interfaces)
			{
				if (!sema_resolve_type_info(context, parent_interface, RESOLVE_TYPE_NO_CHECK_DISTINCT)) return false;
				Decl* parent_decl = parent_interface.type.decl;
				Decl* value = sema_resolve_method(parent_decl, kw);
				if (value && member)
				{
					return @sema_error_at(context, expr.loc, "Ambiguous method '%s' on '%s', it was implemented on both '%s' and '%s'.", kw,
						type_to_error_string(parent.type),
						inf.name, parent_decl.name);
				}
				member = value;
				inf = parent_decl;
			}
		}

		// 11. If we didn't find a match...
		if (!member)
		{
			Type* parent_type = type_no_optional(parent.type).canonical;
			assert(type_is_user_defined(parent_type));
			// Tag as maybe wrong.
			if (!private_ && missing_ref && parent_type.decl.unit.mod.stage < POST_REGISTER)
			{
				parent_type.decl.is_method_checked = true;
			}
			// 11a. We have a potential embedded struct check:
			Expr* substruct = sema_enter_inline_member(current_parent, type);
			if (substruct)
			{
				current_parent = substruct;
				type = type_no_optional(current_parent.type).canonical;
				flat_type = type_flatten(type);
				flat_kind = flat_type.type_kind;
				continue; // goto CHECK_DEEPER
			}

			// 11b. Otherwise we give up.
			if (private_)
			{
				if (missing_ref)
				{
					*missing_ref = true;
					return false;
				}
				return @sema_error_at(context, expr.loc, "The method '%s' has private visibility.", kw);
			}

			if (parent_type.type_kind == INTERFACE)
			{
				if (missing_ref)
				{
					*missing_ref = true;
					return false;
				}
				return @sema_error_at(context, expr.loc, "The '%s' interface has no method '%s', did you spell it correctly?", parent_type.name, kw);
			}
			if (missing_ref)
			{
				*missing_ref = true;
				return false;
			}
			return @sema_error_at(context, expr.loc, "There is no field or method '%s.%s'.", type_to_error_string(parent.type), kw);
		}
		break;
	}

	if (!member.unit && !sema_analyse_decl(context, decl)) return false;
	if (!sema_analyse_decl(context, member)) return false;

	assert(member.type || member.decl_kind == MACRO);
	if (member.decl_kind == VAR)
	{
		if (member.var_decl.kind == BITMEMBER)
		{
			// Transform bitstruct access to expr_bitaccess.
			expr.expr_kind = BITACCESS;
		}
		else if (member.var_decl.kind == MEMBER && expr_is_const_initializer(current_parent))
		{
			if (!sema_expr_fold_to_member(expr, current_parent, member))
			{
				if (member.type.type_kind == FLEXIBLE_ARRAY)
				{
					return @sema_error_at(context, expr.loc, "Could not fold to member '%s', it's a flexible array member which is always empty.", member.name);
				}
				return @sema_error_at(context, expr.loc, "Could not fold to member '%s' – it wasn't the last assigned member.", member.name);
			}
			return true;
		}
	}
	// 13. Copy properties.
	expr.access_resolved_expr = { .parent = current_parent, .ref = member };
	if (expr.expr_kind == ACCESS_UNRESOLVED) expr.expr_kind = ACCESS_RESOLVED;
	expr.type = member.type ? type_add_optional(member.type, optional) : null;
	return true;
}

// sema_expr.c:7619 (static)
fn Expr*[] sema_prepare_splat_insert(Expr*[] exprs, int added, int insert_point)
{
	if (added == 0)
	{
		@vec_erase_at(&exprs, (usz)insert_point);
		return exprs;
	}
	int size = (int)exprs.len;
	assert(size);
	for (int i = 1; i < added; i++)
	{
		@vec_add(&exprs, null);
	}
	// Move everything upwards.
	for (int i = size - 1; i > insert_point; i--)
	{
		exprs[i + added - 1] = exprs[i];
	}
	return exprs;
}

// sema_expr.c:7639 (static)
<* A failure returns an empty slice with a null ptr (c3c NULL). *>
fn Expr*[] sema_vasplat_insert(SemaContext* context, Expr*[] init_expressions, Expr* expr, int insert_point)
{
	Expr*[] args = context.macro_varargs;
	int param_count = (int)args.len;
	ExprRange* range = &expr.vasplat_expr;
	Expr* start = exprptrzero(range.start);
	int start_idx = 0;
	if (start)
	{
		if (!sema_analyse_expr_rvalue(context, start)) return {};
		if (!expr_is_const_int(start))
		{
			@sema_error_at(context, expr.loc, "Expected a constant integer.");
			return {};
		}
		Int start_index = start.const_expr.ixx;
		if (int_is_neg(start_index))
		{
			@sema_error_at(context, expr.loc, "Expected a positive integer.");
			return {};
		}
		if (int_bits_needed(start_index) > 31)
		{
			@sema_error_at(context, expr.loc, "Start index is too big.");
			return {};
		}
		start_idx = (int)(ulong)start_index.i;
		if (param_count < start_idx)
		{
			@sema_error_at(context, expr.loc, "Start index exceeds the number of parameters (%d).", param_count);
			return {};
		}
		if (range.start_from_end) start_idx = param_count - start_idx;
	}
	Expr* end = exprptrzero(range.end);
	int end_idx = param_count;
	if (end)
	{
		if (!sema_analyse_expr_rvalue(context, end)) return {};
		if (!expr_is_const_int(end))
		{
			@sema_error_at(context, expr.loc, "Expected a constant integer.");
			return {};
		}
		Int end_index = end.const_expr.ixx;
		if (int_is_neg(end_index))
		{
			@sema_error_at(context, expr.loc, "Expected a positive integer.");
			return {};
		}
		if (int_bits_needed(end_index) > 31)
		{
			if (range.is_len)
			{
				@sema_error_at(context, expr.loc, "End index is too large.");
			}
			else
			{
				@sema_error_at(context, expr.loc, "Length is too large.");
			}
			return {};
		}
		end_idx = (int)(ulong)end_index.i;
		if (range.end_from_end)
		{
			if (end_idx > param_count)
			{
				@sema_error_at(context, expr.loc, "End index exceeds the number of parameters (%d).", param_count);
				return {};
			}
			end_idx = param_count - end_idx;
		}
		if (range.is_len)
		{
			end_idx = start_idx + end_idx;
		}
		else
		{
			end_idx++;
		}
		if (param_count < end_idx)
		{
			@sema_error_at(context, expr.loc, "End index would exceed the number of parameters.");
			return {};
		}
		if (end_idx < start_idx)
		{
			@sema_error_at(context, expr.loc, "The end index is before the start index.");
			return {};
		}
	}

	int added = end_idx - start_idx;

	// Zero splat
	if (!added)
	{
		@vec_erase_at(&init_expressions, (usz)insert_point);
		return init_expressions;
	}

	init_expressions = sema_prepare_splat_insert(init_expressions, added, insert_point);
	for (int i = start_idx; i < end_idx; i++)
	{
		init_expressions[insert_point + i - start_idx] = copy_expr_single(args[i]);
	}
	return init_expressions;
}

// sema_expr.c:7748
fn bool sema_expand_vasplat_exprs(SemaContext* context, Expr*[]* exprs_ptr, Decl*[]* macro_va_decl_ref)
{
	if (!context) return true;
	bool in_macro = context.current_macro != null;
	Expr*[] exprs = *exprs_ptr;
	int count = (int)exprs.len;
	bool expand;
	do
	{
		expand = false;
		for (int i = 0; i < count; i++)
		{
			Expr* arg = exprs[i];
			ExprKind kind = arg.expr_kind;
			if (in_macro && kind == VASPLAT)
			{
				exprs = sema_vasplat_insert(context, exprs, arg, i);
				// If we have null back it failed.
				if (!exprs.ptr) return false;
				count = (int)exprs.len;
				expand = true;
				break;
			}
			if (kind == SPLAT)
			{
				Expr* inner = arg.inner_expr;
				if (!sema_analyse_expr_rvalue(context, inner)) return false;
				Type* flat = type_flatten(inner.type);
				Expr*[] new_args;
				switch (flat.type_kind)
				{
					case VECTOR:
					case SIMD_VECTOR:
					case ARRAY:
					case SLICE:
					case UNTYPEDLIST:
						// These may be splatted like arrays
						ArrayIndex len = sema_len_from_expr(inner);
						if (len == -1)
						{
							return @sema_error_at(context, arg.loc,
								"Only a value with a length known at compile time can be splatted, but if you slice it to a constant length it will work (e.g. '...val[:2]').");
						}
						if (len == 0 && !expr_is_const(arg))
						{
							return @sema_error_at(context, arg.loc, "A non-constant zero size splat is not allowed.");
						}
						new_args = sema_splat_arraylike_insert(context, exprs, inner, len, i, macro_va_decl_ref, null);
					case STRUCT:
						new_args = sema_splat_struct_insert(context, exprs, inner, flat.decl, i, null);
					default:
						return @sema_error_at(context, arg.loc, "An argument of type %s cannot be splatted.",
							type_quoted_error_string(inner.type));
				}
				// SPLAT_DONE:
				if (!new_args.ptr) return false;
				exprs = new_args;
				count = (int)exprs.len;
				expand = true;
				break;
			}
		}
	} while (expand);
	*exprs_ptr = exprs;
	return true;
}

// sema_expr.c:7816 (static)
fn bool sema_expr_analyse_expr_list(SemaContext* context, Expr* expr)
{
	bool success = true;
	long last = (long)expr.expression_list.len - 1;
	for (int i = 0; i <= last; i++)
	{
		Expr* checked_expr = expr.expression_list[i];
		if (!sema_analyse_expr_rvalue(context, checked_expr)) return false;
		if (i != last && !sema_expr_check_discard(context, checked_expr)) return false;
	}
	expr.type = expr.expression_list[last].type;
	return success;
}

// sema_expr.c:7831 (static)
fn bool sema_expr_analyse_cast(SemaContext* context, Expr* expr, bool* invalid_cast_ref)
{
	if (invalid_cast_ref) *invalid_cast_ref = false;
	Expr* inner = exprptr(expr.cast_expr.expr);
	TypeInfo* type_info = type_infoptr(expr.cast_expr.type_info);
	if (inner.expr_kind == INITIALIZER_LIST || inner.expr_kind == DESIGNATED_INITIALIZER_LIST)
	{
		expr.expr_kind = COMPOUND_LITERAL;
		expr.expr_compound_literal = { .initializer = inner, .type_info = type_info };
		return sema_expr_analyse_compound_literal(context, expr, invalid_cast_ref);
	}
	bool success = sema_resolve_type_info(context, type_info, RESOLVE_TYPE_ALLOW_INFER);
	if (!sema_analyse_expr_rvalue(context, inner) || !success) return false;

	Type* target_type = type_info.type;
	if (type_is_optional(target_type))
	{
		return @sema_error_at(context, type_info.loc, "Casting to an optional type is not allowed.");
	}
	if (invalid_cast_ref)
	{
		if (!cast_explicit_silent(context, inner, target_type))
		{
			*invalid_cast_ref = true;
			return false;
		}
	}
	else
	{
		if (!cast_explicit(context, inner, target_type)) return expr_poison(expr);
	}
	if (!expr_is_simple(inner, false) || !expr_is_simple(inner, true))
	{
		expr.expr_kind = RVALUE;
		expr.type = inner.type;
		expr.inner_expr = inner;
	}
	else
	{
		expr_replace(expr, inner);
	}
	return true;
}

// sema_expr.c:7875 (static)
fn bool sema_expr_analyse_slice_assign(SemaContext* context, Expr* expr, Type* left_type, Expr* right, bool* failed_ref)
{
	Expr* left = exprptr(expr.binary_expr.left);
	Type* left_flat = type_flatten(left_type);
	Type* base = left_flat.array.base;
	bool slice_copy = false;
	if (right.expr_kind == SLICE)
	{
		if (!sema_analyse_inferred_expr(context, left_type, right, null)) return false;
		if (left_flat == type_flatten(right.type) || right.type == type_untypedlist) slice_copy = true;
	}
	else
	{
		if (right.expr_kind == INITIALIZER_LIST && right.initializer_list.len)
		{
			Type* flat = type_flatten(base);
			switch (flat.type_kind)
			{
				case STRUCT:
				case VECTOR:
				case INFERRED_VECTOR:
				case SIMD_VECTOR:
				case ARRAY:
				case INFERRED_ARRAY:
				case FLEXIBLE_ARRAY:
				case UNION:
				case BITSTRUCT:
				case SLICE:
					break;
				default:
					return @sema_error_at(context, right.loc, "You are trying to assign this expression to each element in the slice, but the expression can't be cast to a value of type %s. Maybe you wanted to do a slice copy and forgot to add [..] at the end? Rather than 'a[..] = { ... }', try 'a[..] = { ... }[..]'.",
						type_quoted_error_string(base));
			}
		}
		if (!sema_analyse_inferred_expr(context, base, right, null)) return false;
	}
	if (!slice_copy)
	{
		Type* right_type = right.type.canonical;
		if (base.canonical != right_type && (type_is_arraylike(right_type) || right_type.type_kind == SLICE))
		{
			if (right_type.array.base.canonical == base.canonical)
			{
				if (failed_ref) { *failed_ref = true; return false; }
				return @sema_error_at(context, right.loc, "You cannot assign a slice, vector or array to a slicing without making an explicit [..] operation, e.g. 'foo[..] = my_array[..]', so you can try adding an explicit slicing to this expression.");
			}
		}
		if (!cast_implicit_checked(context, right, base, false, failed_ref)) return false;
		if (@is_optional(right))
		{
			return @sema_error_at(context, right.loc, "The right hand side may not be optional when using slice assign.");
		}
		expr.expr_kind = SLICE_ASSIGN;
		expr.type = right.type;
		expr.slice_assign_expr.left = exprid(left);
		expr.slice_assign_expr.right = exprid(right);
		return true;
	}

	// SLICE_COPY:
	while (right.expr_kind == SLICE)
	{
		Expr* inner = exprptr(right.slice_expr.expr);
		if (inner.expr_kind != IDENTIFIER) break;
		Decl* decl = inner.ident_expr;
		if (decl.decl_kind != VAR) break;
		if (!decl.var_decl.out_param || decl.var_decl.in_param) break;
		if (context.active_scope.flags & (SCOPE_ENSURE | SCOPE_ENSURE_MACRO)) break;
		return @sema_error_at(context, right.loc, "'out' parameters may not be read.");
	}

	if (!sema_analyse_expr_rhs(context, left_type, right, false, null, false)) return false;
	ExprRange* left_range = &left.slice_expr.range;
	IndexDiff left_len = range_const_len(left_range);
	IndexDiff right_len = 0;
	if (!expr_is_const(right))
	{
		assert(right.expr_kind == SLICE);
		ExprRange* right_range = &right.slice_expr.range;
		right_len = range_const_len(right_range);
	}
	else
	{
		right_len = (IndexDiff)sema_len_from_const(right);
	}
	if (left_len >= 0 && right_len >= 0 && left_len != right_len)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "Length mismatch between slices.");
	}
	expr.expr_kind = SLICE_COPY;
	expr.type = left.type;
	expr.slice_assign_expr.left = exprid(left);
	expr.slice_assign_expr.right = exprid(right);
	return true;
}

// sema_expr.c:7963
fn bool sema_expr_analyse_assign_right_side(SemaContext* context, Expr* expr, Type* left_type, Expr* right, bool is_unwrapped_var, bool is_declaration, bool* failed_ref)
{
	if (expr && exprptr(expr.binary_expr.left).expr_kind == SLICE)
	{
		return sema_expr_analyse_slice_assign(context, expr, left_type, right, failed_ref);
	}

	// 1. Evaluate right side to required type.
	bool to_optional = left_type && type_is_optional(left_type);
	if (is_declaration && left_type)
	{
		switch (left_type.type_kind)
		{
			case TYPEDEF:
			case CONSTSET:
				is_declaration = false;
			default:
				break;
		}
	}
	if (!sema_analyse_expr_rhs(context, left_type, right, is_unwrapped_var || to_optional, failed_ref, is_declaration)) return false;
	if (@is_optional(right) && !to_optional)
	{
		if (is_unwrapped_var)
		{
			return @sema_error_at(context, exprptr(expr.binary_expr.left).loc, "The variable is unwrapped in this context, if you don't want to unwrap it, use () around the variable to suppress unwrapping, like 'catch err = (x)' and 'try (x)'.");
		}
		if (!left_type) left_type = type_no_optional(right.type);
		if (failed_ref) { *failed_ref = true; return false; }
		return sema_error_failed_cast(context, right, right.type, left_type);
	}

	// 3. Set the result to the type on the right side.
	if (expr) expr.type = right.type;

	return true;
}

// sema_expr.c:8003 (static)
fn bool sema_expr_analyse_ct_identifier_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	assert(left.resolve_status == DONE);

	// Evaluate right side to using inference from last type.
	if (!sema_analyse_inferred_expr(context, left.type, right, null)) return false;

	if (!sema_cast_const(right) && !expr_is_runtime_const(right))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, right.loc, "You can only assign constants to a compile time variable.");
	}
	Decl* ident = left.ident_expr;

	ident.var_decl.init_expr = right;
	expr_replace(expr, right);
	ident.type = right.type;
	return true;
}

// sema_expr.c:8023 (static)
fn bool sema_expr_analyse_ct_subscript_rhs(SemaContext* context, Decl* ct_var, Expr* right)
{
	if (ct_var.type == type_untypedlist)
	{
		if (!sema_analyse_expr_rvalue(context, right)) return false;
	}
	else
	{
		if (!sema_analyse_expr_rhs(context, type_get_indexed_type(ct_var.type), right, false, null, false)) return false;
	}
	if (!expr_is_runtime_const(right))
	{
		return @sema_error_at(context, right.loc, "The argument must be a constant value.");
	}
	return true;
}

// sema_expr.c:8040 (static)
fn void sema_expr_analyse_ct_subscript_set_value(Expr* left, Decl* ct_var, Expr* right)
{
	ArrayIndex index = left.ct_subscript_expr.index;
	Expr* original_value = ct_var.var_decl.init_expr;
	assert(original_value.expr_kind == CONST);
	ExprConst* expr_const = &original_value.const_expr;

	switch (expr_const.const_kind)
	{
		case FLOAT:
		case INTEGER:
		case BOOL:
		case ENUM:
		case FAULT:
		case POINTER:
		case TYPEID:
		case REF:
		case MEMBER:
		case REFLECTION:
			unreachable();
		case BYTES:
		case STRING:
			char* copy = calloc_arena((usz)expr_const.bytes.len + 1);
			mem::copy(copy, expr_const.bytes.ptr, (sz)(expr_const.bytes.len + 1));
			// c3c: assert(right.const_expr.const_kind == INTEGER); -- C assert, compiled out in c3c release builds
			copy[index] = (char)right.const_expr.ixx.i;
			expr_const.bytes.ptr = copy;
		case SLICE:
			const_init_rewrite_array_at(expr_const.slice_init, right, index);
		case INITIALIZER:
			const_init_rewrite_array_at(expr_const.initializer, right, index);
		case UNTYPED_LIST:
			expr_const.untyped_list[index] = right;
	}
}

// sema_expr.c:8082 (static)
fn bool sema_expr_analyse_ct_subscript_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right)
{
	Decl* ct_var = left.ct_subscript_expr.ct_var;
	if (!sema_expr_analyse_ct_subscript_rhs(context, ct_var, right)) return false;
	sema_expr_analyse_ct_subscript_set_value(left, ct_var, right);
	expr_replace(expr, right);
	return true;
}

// sema_expr.c:8092 (static)
fn bool sema_expr_fold_hash(SemaContext* context, Expr* expr)
{
	// c3c: assert(expr.expr_kind == HASH_IDENT); -- C assert, compiled out in c3c release builds
	while (expr.expr_kind == HASH_IDENT)
	{
		assert(expr && expr.hash_ident_expr.identifier.ptr);
		Decl* decl = sema_resolve_symbol(context, expr.hash_ident_expr.identifier, null, expr.loc);

		// Already handled
		if (!decl) return expr_poison(expr);

		assert(decl.decl_kind == VAR);
		bool is_ref = expr.hash_ident_expr.is_ref;
		if (decl_is_defaulted_var(decl))
		{
			return @sema_error_at(context, expr.loc, "The parameter '%s' was not provided by the caller.", decl.name);
		}
		expr_replace(expr, copy_expr_single(decl.var_decl.init_expr));
		if (is_ref) expr_set_to_ref(expr);
	}
	return expr_ok(expr);
}

// sema_expr.c:8120 (static)
<* Analyse a = b *>
fn bool sema_expr_analyse_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	if (!sema_analyse_expr_lvalue(context, left, failed_ref)) return false;
	switch (left.expr_kind)
	{
		case IDENTIFIER:
			if (!expr_is_ct_ident(left)) break;
			// $foo = ...
			return sema_expr_analyse_ct_identifier_assign(context, expr, left, right, failed_ref);
		case CT_SUBSCRIPT:
			return sema_expr_analyse_ct_subscript_assign(context, expr, left, right);
		default:
			break;
	}
	if (left.type && left.type.type_kind == FLEXIBLE_ARRAY)
	{
		return @sema_error_at(context, left.loc, "You can't assign to a flexible array member, but you may index into it and mutate it that way.");
	}

	// 2. Check assignability
	if (!sema_expr_check_assign(context, left, failed_ref)) return false;

	bool is_unwrapped_var = expr_is_unwrapped_ident(left);

	Decl* generic = declptrzero(type_find_generic(left.type));
	if (generic)
	{
		Decl* temp = context.generic_infer;
		context.generic_infer = generic;
		generic = temp;
	}
	// 3. Evaluate right side to required type.
	if (!sema_expr_analyse_assign_right_side(context, expr, left.type, right, is_unwrapped_var, false, failed_ref))
	{
		context.generic_infer = generic;
		return false;
	}
	context.generic_infer = generic;
	if (is_unwrapped_var && @is_optional(right))
	{
		sema_rewrap_var(context, left.ident_expr);
		return true;
	}
	if (left.expr_kind == SUBSCRIPT_ASSIGN)
	{
		Decl* temp = decl_new_generated_var(right.type, LOCAL, right.loc);
		Expr* expr_rh = expr_generate_decl(temp, right);
		Expr*[] args = {};
		@vec_add(&args, exprptr(left.subscript_assign_expr.index));
		@vec_add(&args, expr_variable(temp));
		if (!sema_insert_method_call(context, expr, declptr(left.subscript_assign_expr.method), exprptr(left.subscript_assign_expr.expr), args, false)) return false;
		expr_rewrite_two(expr, expr_rh, expr_copy(expr));
		return true;
	}
	if (left.expr_kind == BITACCESS)
	{
		if (!sema_bit_assignment_check(context, right, left.access_resolved_expr.ref, failed_ref)) return false;
		expr.expr_kind = BITASSIGN;
	}
	return true;
}

// sema_expr.c:8188 (static)
<* Analyse define $foo = ... *>
fn bool sema_binary_analyse_ct_op_assign(SemaContext* context, Expr* expr, Expr* left)
{
	assert(expr_is_ct_ident(left));

	Decl* left_var = left.ident_expr;
	if (!sema_cast_ct_ident_rvalue(context, left)) return false;

	expr.binary_expr.operator = binaryop_assign_base_op(expr.binary_expr.operator);

	if (!sema_expr_analyse_binary(context, null, expr, null)) return false;
	expr.resolve_status = DONE;

	if (!expr_is_runtime_const(expr))
	{
		return @sema_error_at(context, expr.loc, "Expected this to result in a constant expression.");
	}

	left_var.var_decl.init_expr = copy_expr_single(expr);
	left_var.type = expr.type;
	return true;
}

// sema_expr.c:8215 (static)
<* Analyse $foo[1] += ... *>
fn bool sema_binary_analyse_ct_subscript_op_assign(SemaContext* context, Expr* expr, Expr* left)
{
	assert(left.expr_kind == CT_SUBSCRIPT);

	Decl* left_var = left.ct_subscript_expr.ct_var;
	ArrayIndex idx = left.ct_subscript_expr.index;
	Expr* lhs_expr = left_var.var_decl.init_expr;
	assert(lhs_expr.expr_kind == CONST);
	Expr* value = expr_from_const_expr_at_index(lhs_expr, idx);

	BinaryOp op = binaryop_assign_base_op(expr.binary_expr.operator);
	expr.binary_expr = { .left = exprid(value), .right = expr.binary_expr.right, .operator = op };
	expr.resolve_status = NOT_DONE;
	if (!sema_expr_analyse_ct_subscript_rhs(context, left_var, expr)) return false;
	sema_expr_analyse_ct_subscript_set_value(left, left_var, expr);
	return true;
}

// c3c: the static MAP in sema_insert_overload_in_op_assign_or_error.
const OperatorOverload[BINARYOP_LAST.ordinal + 1] SEMA_OP_ASSIGN_OVERLOAD_MAP = {
	[BinaryOp.ADD_ASSIGN.ordinal] = OVERLOAD_PLUS_ASSIGN,
	[BinaryOp.SUB_ASSIGN.ordinal] = OVERLOAD_MINUS_ASSIGN,
	[BinaryOp.MULT_ASSIGN.ordinal] = OVERLOAD_MULTIPLY_ASSIGN,
	[BinaryOp.DIV_ASSIGN.ordinal] = OVERLOAD_DIVIDE_ASSIGN,
	[BinaryOp.MOD_ASSIGN.ordinal] = OVERLOAD_REMINDER_ASSIGN,
	[BinaryOp.BIT_XOR_ASSIGN.ordinal] = OVERLOAD_XOR_ASSIGN,
	[BinaryOp.BIT_OR_ASSIGN.ordinal] = OVERLOAD_OR_ASSIGN,
	[BinaryOp.BIT_AND_ASSIGN.ordinal] = OVERLOAD_AND_ASSIGN,
	[BinaryOp.SHL_ASSIGN.ordinal] = OVERLOAD_SHL_ASSIGN,
	[BinaryOp.SHR_ASSIGN.ordinal] = OVERLOAD_SHR_ASSIGN,
};

// sema_expr.c:8233 (static)
fn BoolErr sema_insert_overload_in_op_assign_or_error(SemaContext* context, Expr* expr, Expr* left, Expr* right, BinaryOp operator, Type* lhs_type)
{
	// c3c: assert(type_is_user_defined(lhs_type)); -- C assert, compiled out in c3c release builds
	if (!sema_analyse_inferred_expr(context, lhs_type, right, null)) return BOOL_ERR;
	OperatorOverload overload = SEMA_OP_ASSIGN_OVERLOAD_MAP[operator.ordinal];
	// c3c: assert(overload, "Overload not mapped"); -- C assert, compiled out in c3c release builds
	if (!sema_replace_with_overload(context, expr, left, right, lhs_type, &overload)) return BOOL_ERR;
	if (!overload)
	{
		return BOOL_TRUE;
	}
	return BOOL_FALSE;
}

// sema_expr.c:8259 (static)
fn bool sema_rewrite_op_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, BinaryOp new_op)
{
	// Simple case: f += a => f = f + a
	if (left.expr_kind == IDENTIFIER)
	{
		Expr* lvalue = expr_copy(left);
		Expr* rvalue = expr_copy(left);
		expr.expr_kind = BINARY;
		left.expr_kind = BINARY;
		left.binary_expr = { .left = exprid(rvalue), .right = exprid(right), .operator = new_op };
		expr.binary_expr = { .left = exprid(lvalue), .right = exprid(left), .operator = ASSIGN, .grouped = false };
		expr.resolve_status = NOT_DONE;
		left.resolve_status = NOT_DONE;
		return sema_analyse_expr_rvalue(context, expr);
	}

	Type* lhs_type = type_no_optional(left.type).canonical;
	Decl* variable = decl_new_generated_var(type_get_ptr(left.type), LOCAL, left.loc);
	Expr* left_copy = expr_copy(left);

	// If we have a &[] overload, then replace left copy with that one.
	bool after_addr = false;
	if (left.expr_kind == SUBSCRIPT_ASSIGN)
	{
		Expr* parent = exprptr(left.subscript_assign_expr.expr);
		Type* parent_type = type_no_optional(parent.type).canonical;
		bool is_addr = parent_type.type_kind == POINTER;
		if (is_addr) parent_type = parent_type.pointer;
		Decl* operator = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_REF, null);
		Expr* index = exprptr(left.subscript_assign_expr.index);
		if (operator)
		{
			Expr*[] args = {};
			@vec_add(&args, index);
			if (!sema_insert_method_call(context, left_copy, operator, parent, args, false)) return false;
			after_addr = true;
		}
		else
		{
			// If we only have []=, then we need []
			operator = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_AT, null);
			if (!operator)
			{
				return @sema_error_at(context, left.loc, "There is no overload for [] for %s.", type_quoted_error_string(type_no_optional(left.type)));
			}
			Type* return_type = typeget(operator.func_decl.signature.rtype);
			if (type_no_optional(return_type.canonical) != lhs_type.canonical)
			{
				return @sema_error_at(context, expr.loc, "There is a type mismatch between the overload for [] and []= for %s.", type_quoted_error_string(type_no_optional(left.type)));
			}
			// First we want to create the indexed value and the index:
			Decl* index_val = decl_new_generated_var(index.type, LOCAL, index.loc);
			// We need to take the address of the parent here, otherwise this might fail,
			if (!is_addr) expr_insert_addr(parent);
			Decl* parent_val = decl_new_generated_var(parent.type, LOCAL, parent.loc);
			Expr*[] list = {};
			// temp = parent, temp_2 = index
			@vec_add(&list, expr_generate_decl(parent_val, parent));
			@vec_add(&list, expr_generate_decl(index_val, index));
			// Now, create a lhs of the binary add:
			Expr* lhs = expr_new_expr(SUBSCRIPT, left);
			Expr* parent_by_variable = expr_variable(parent_val);
			if (!sema_expr_rewrite_insert_deref(context, parent_by_variable)) return false;
			lhs.subscript_expr = { .expr = exprid(parent_by_variable), .index = { .expr = exprid(expr_variable(index_val)) } };
			// Now create the binary expression
			Expr* binary = expr_new_expr(BINARY, expr);
			binary.binary_expr = { .left = exprid(lhs), .right = exprid(right), .operator = new_op };
			// Finally, we need the assign, and here we just need to replace
			Expr* assign = expr_new_expr(BINARY, expr);
			assign.binary_expr = { .left = exprid(left), .right = exprid(binary), .operator = ASSIGN };
			// Now we need to patch the values in `left`:
			parent_by_variable = expr_variable(parent_val);
			if (!sema_expr_rewrite_insert_deref(context, parent_by_variable)) return false;
			left.subscript_assign_expr.expr = exprid(parent_by_variable);
			left.subscript_assign_expr.index = exprid(expr_variable(index_val));
			// We add the assign
			@vec_add(&list, assign);
			// And rewrite the expression to an expression list:
			expr.expr_kind = EXPRESSION_LIST;
			expr.expression_list = list;
			return sema_expr_analyse_expr_list(context, expr);
		}
	}

	// f => &f
	if (!after_addr) expr_insert_addr(left_copy);

	// AFTER_ADDR:

	// temp = &f
	Expr* init = expr_generate_decl(variable, left_copy);
	// lvalue = temp, rvalue = temp
	Expr* left_rvalue = expr_variable(variable);
	Expr* left_lvalue = expr_variable(variable);

	// lvalue = *temp, rvalue = *temp
	if (!sema_expr_rewrite_insert_deref(context, left_lvalue)) return false;
	if (!sema_expr_rewrite_insert_deref(context, left_rvalue)) return false;

	// init, expr -> lvalue = rvalue + a
	expr.expr_kind = BINARY;
	left.expr_kind = BINARY;
	left.binary_expr = { exprid(left_lvalue), exprid(right), new_op, false };
	expr.binary_expr = { exprid(left_rvalue), exprid(left), ASSIGN, false };
	expr.resolve_status = NOT_DONE;
	left.resolve_status = NOT_DONE;
	Expr* binary = expr_copy(expr);
	expr_rewrite_two(expr, init, binary);
	return sema_analyse_expr_rvalue(context, expr);
}

// sema_expr.c:8366 (static)
fn bool sema_expr_analyse_op_assign_enum_ptr(SemaContext* context, Expr* rhs, Type* flat, Type* base, Type* flat_rhs, BinaryOp op, bool* failed_ref)
{
	if (flat == base)
	{
		if (!type_is_integer(flat_rhs))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, rhs.loc,
				"The right side was '%s' but only integers are valid on the right side of %s when the left side is a pointer.",
				type_to_error_string(rhs.type),
				token_type_to_string(binaryop_to_token(op)));
		}
		if (!cast_implicit(context, rhs, type_sz, true)) return false;
	}
	else
	{
		Type* real_type = type_get_vector_from_vector(type_sz, flat);
		if (flat_rhs == type_untypedlist)
		{
			if (!cast_implicit(context, rhs, real_type, true)) return false;
			flat_rhs = type_flat_for_arithmethics(rhs.type);
		}
		if (!type_is_integer(flat_rhs) && (!type_kind_is_real_vector(flat_rhs.type_kind) || !type_is_integer(flat_rhs.array.base)))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, rhs.loc,
				"The right side was '%s' but only integers or integer vectors are valid on the right side of %s when the left side is a pointer vector.",
				type_to_error_string(rhs.type),
				token_type_to_string(binaryop_to_token(op)));
		}
		if (!cast_implicit(context, rhs, real_type, true)) return false;
	}
	return true;
}

// c3c: the static MAP in sema_expr_analyse_op_assign.
const OperatorOverload[BINARYOP_LAST.ordinal + 1] SEMA_OP_BASE_OVERLOAD_MAP = {
	[BinaryOp.ADD.ordinal] = OVERLOAD_PLUS,
	[BinaryOp.SUB.ordinal] = OVERLOAD_MINUS,
	[BinaryOp.DIV.ordinal] = OVERLOAD_DIVIDE,
	[BinaryOp.MOD.ordinal] = OVERLOAD_REMINDER,
	[BinaryOp.MULT.ordinal] = OVERLOAD_MULTIPLY,
	[BinaryOp.BIT_XOR.ordinal] = OVERLOAD_XOR,
	[BinaryOp.BIT_OR.ordinal] = OVERLOAD_OR,
	[BinaryOp.BIT_AND.ordinal] = OVERLOAD_AND,
	[BinaryOp.SHL.ordinal] = OVERLOAD_SHL,
	[BinaryOp.SHR.ordinal] = OVERLOAD_SHR,
};

// sema_expr.c:8406 (static)
<* Analyse *= /= %= ^= |= &= += -= <<= >>= *>
fn bool sema_expr_analyse_op_assign(SemaContext* context, Expr* expr, Expr* left, Expr* right, BinaryOp operator, bool* failed_ref)
{
	bool is_bit_op = false;
	bool is_shift = false;
	bool is_add_sub = false;
	bool int_only = false;
	switch (operator)
	{
		case MULT_ASSIGN:
		case DIV_ASSIGN:
		case MOD_ASSIGN:
			break;
		case BIT_AND_ASSIGN:
		case BIT_OR_ASSIGN:
		case BIT_XOR_ASSIGN:
			int_only = true;
			is_bit_op = true;
		case ADD_ASSIGN:
		case SUB_ASSIGN:
			is_add_sub = true;
		case SHL_ASSIGN:
		case SHR_ASSIGN:
			is_shift = true;
			int_only = true;
		default:
			unreachable();
	}
	// 1. Analyse left side.
	if (!sema_analyse_expr_lvalue(context, left, failed_ref)) return false;

	switch (left.expr_kind)
	{
		case IDENTIFIER:
			if (!expr_is_ct_ident(left)) break;
			return sema_binary_analyse_ct_op_assign(context, expr, left);
		case CT_SUBSCRIPT:
			return sema_binary_analyse_ct_subscript_op_assign(context, expr, left);
		default:
			break;
	}

	if (left.type && left.type.type_kind == FLEXIBLE_ARRAY)
	{
		return @sema_error_at(context, left.loc, "You can't assign to a flexible array member, but you may index into it and mutate it that way.");
	}

	// 2. Verify that the left side is assignable.

	if (!sema_expr_check_assign(context, left, failed_ref)) return false;

	Type* left_type_canonical = left.type.canonical;

	// 3. Check that it is readable
	if (!sema_cast_rvalue(context, left, false)) return false;

	Type* no_fail = type_no_optional(left.type);

	Type* canonical = no_fail.canonical;
	if (type_is_user_defined(canonical) && !(canonical.type_kind == BITSTRUCT && is_bit_op))
	{
		BoolErr b = sema_insert_overload_in_op_assign_or_error(context, expr, left, right, operator, no_fail.canonical);
		if (b == BOOL_ERR) return false;
		if (b == BOOL_TRUE) return true;
		// Maybe we have the corresponding implemented % * etc
		// The right hand side is now already checked.
		BinaryOp underlying_op = binaryop_assign_base_op(operator);
		OperatorOverload mapped_overload = SEMA_OP_BASE_OVERLOAD_MAP[underlying_op.ordinal];
		bool reverse = false;
		Decl* candidate = expr_may_ref(left) ? sema_find_typed_operator(context, mapped_overload, expr.loc, left, right, &reverse) : null;
		if (!decl_ok(candidate)) return false;
		if (candidate && typeget(candidate.func_decl.signature.rtype).canonical == canonical)
		{
			return sema_rewrite_op_assign(context, expr, left, right, underlying_op);
		}
	}
	// SKIP_OVERLOAD_CHECK:
	// 3. If this is only defined for ints (^= |= &= %=) verify that this is an int.
	Type* flat = type_flat_for_arithmethics(no_fail);
	Type* base = type_kind_is_real_vector(flat.type_kind) ? type_flat_for_arithmethics(flat.array.base) : flat;

	bool bitstruct_ok = false;
	if (int_only && !type_is_integer(base))
	{
		if (is_bit_op && (flat.type_kind == BITSTRUCT || flat == type_bool || type_flat_is_bool_vector(flat)))
		{
			bitstruct_ok = true;
		}
		else
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, left.loc, "Expected an integer here, not a value of type %s.", type_quoted_error_string(left.type));
		}
	}

	// 4. In any case, these ops are only defined on numbers.
	if (!bitstruct_ok && !type_is_numeric(base) && !(is_add_sub && type_underlying_may_add_sub(base)))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, left.loc, "Expected a numeric type here, not a value of type %s.", type_quoted_error_string(left.type));
	}

	// BITSTRUCT_OK:

	// 5. Analyse RHS
	if (base.type_kind == POINTER)
	{
		if (!sema_analyse_expr_rvalue(context, right)) return false;
	}
	else
	{
		if (!sema_analyse_inferred_expr(context, left.type, right, null)) return false;
	}

	// 3. Copy type & set properties.
	if (@is_optional(right) && !@is_optional(left))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, right.loc, "Cannot assign an optional value to a non-optional.");
	}

	expr.type = left.type;
	bool optional = @is_optional(left) || @is_optional(right);

	Type* type_rhs_inline = type_flat_for_arithmethics(right.type);

	if (base.type_kind == POINTER)
	{
		if (!sema_expr_analyse_op_assign_enum_ptr(context, right, flat, base, type_rhs_inline, expr.binary_expr.operator, failed_ref)) return false;
	}
	else
	{
		if (is_shift)
		{
			if (!sema_expr_check_shift_rhs(context, expr, left, type_flatten_and_inline(left.type), right, type_flatten_and_inline(right.type), failed_ref, true))
			{
				return false;
			}
		}
		else
		{
			// Otherwise cast left to right.
			if (!cast_implicit_binary(context, right, no_fail, failed_ref)) return false;
		}

		// 6. Check for zero in case of div or mod.
		if (sema_cast_const(right))
		{
			switch (operator)
			{
				case DIV_ASSIGN:
				case MOD_ASSIGN:
					switch (right.const_expr.const_kind)
					{
						case INTEGER:
							if (int_is_zero(right.const_expr.ixx))
							{
								if (failed_ref) { *failed_ref = true; return false; }
								if (operator == MOD_ASSIGN) return @sema_error_at(context, right.loc, "%% by zero not allowed.");
								return @sema_error_at(context, right.loc, "Division by zero not allowed.");
							}
						case FLOAT:
						default:
							break;
					}
				case SHL_ASSIGN:
				case SHR_ASSIGN:
					if (expr_is_const_int(right))
					{
						//  Make sure the value does not exceed the bitsize of
						//     the left hand side.
						if (int_ucomp(right.const_expr.ixx, left.type.canonical.builtin.bitsize, GT))
						{
							if (failed_ref) { *failed_ref = true; return false; }
							return @sema_error_at(context, right.loc, "The shift exceeds bitsize of '%s'.", type_to_error_string(left.type));
						}

						// 4b. Make sure that the right hand side is positive.
						if (int_is_neg(right.const_expr.ixx))
						{
							if (failed_ref) { *failed_ref = true; return false; }
							return @sema_error_at(context, right.loc, "A shift must be a positive number.");
						}
					}
				default:
					break;
			}
		}

		if (left.expr_kind == BITACCESS)
		{
			expr.expr_kind = BITASSIGN;
		}
	}

	// END:
	// Handle the subscript assign variant.
	if (left.expr_kind == SUBSCRIPT_ASSIGN)
	{
		return sema_analyse_assign_mutate_overloaded_subscript(context, expr, left, left_type_canonical);
	}
	// 7. Assign type
	expr.type = type_add_optional(left.type, optional);
	return true;
}

// sema_expr.c:8625 (static)
fn bool sema_replace_with_overload(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* left_type, OperatorOverload* operator_overload_ref)
{
	// c3c: assert(!type_is_optional(left_type) && left_type.canonical == left_type); -- C assert, compiled out in c3c release builds
	bool reverse;
	Decl* overload = sema_find_typed_operator(context, *operator_overload_ref, expr.loc, left, right, &reverse);
	if (!decl_ok(overload)) return false;
	if (overload)
	{
		*operator_overload_ref = (OperatorOverload)0; // NOLINT
		return sema_insert_binary_overload(context, expr, overload, left, right, reverse);
	}
	return true;
}

// sema_expr.c:8639 (static)
fn bool sema_check_untyped_promotion(SemaContext* context, Expr* expr, bool is_left, CanonicalType* max_flat, Type* max)
{
	Type* flat = type_flatten(expr.type);
	if (!type_is_unsigned(flat) || type_size(max_flat) != type_size(flat)) return true;
	if (sema_cast_const(expr) && expr_is_const_int(expr) && expr_const_will_overflow(&expr.const_expr, max_flat.type_kind))
	{
		return @sema_error_at(context, expr.loc,
			"This expression (%s) will be implicitly converted to a signed type due to the %s-hand side being signed, but the value does not fit %s. "
			"To fix this, either cast the value explicitly, or make the %s-hand side an unsigned type.",
			expr_const_to_error_string(&expr.const_expr), is_left ? "right" : "left", type_quoted_error_string(max),
			is_left ? "right" : "left");
	}

	return true;

}

// sema_expr.c:8655 (static)
fn bool sema_binary_arithmetic_promotion(SemaContext* context, Expr* left, Expr* right, Type* left_type, Type* right_type, Expr* parent, String error_message, bool allow_bool_vec, OperatorOverload* operator_overload_ref, bool* failed_ref)
{
	OperatorOverload overload = *operator_overload_ref;
	if (type_is_user_defined(left_type) || type_is_user_defined(right_type))
	{
		if (!sema_replace_with_overload(context, parent, left, right, left_type, operator_overload_ref)) return false;
		if (!*operator_overload_ref) return true;
	}

	if (overload == OVERLOAD_PLUS)
	{
		Type* cast_to_iptr = defer_iptr_cast(left);
		if (!cast_to_iptr) cast_to_iptr = defer_iptr_cast(right);
		left_type = type_no_optional(left.type).canonical;
		right_type = type_no_optional(right.type).canonical;
		if (type_is_pointer_like(left_type))
		{
			*operator_overload_ref = OVERLOAD_NONE; // NOLINT
			return sema_expr_analyse_ptr_add(context, parent, left, right, left_type, right_type, cast_to_iptr, failed_ref);
		}
		if (type_is_pointer_like(right_type))
		{
			*operator_overload_ref = OVERLOAD_NONE; // NOLINT
			return sema_expr_analyse_ptr_add(context, parent, right, left, right_type, left_type, cast_to_iptr, failed_ref); // NOLINT(readability-suspicious-call-argument)
		}
	}

	Type* max = cast_numeric_arithmetic_promotion(type_find_max_type(context, left_type, right_type, left, right));
	// Failed to resolve.
	if (max == poisoned_type) return false;
	Type* flat_max = max ? type_flatten(max) : null;
	if (!max || (!type_is_numeric(flat_max) && !(allow_bool_vec && (flat_max == type_bool || type_flat_is_bool_vector(flat_max)))))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		if (!error_message.ptr)
		{
			return sema_type_error_on_binop(context, parent);
		}
		// c3c RETURN_SEMA_ERROR with a runtime format string.
		sema_verror_range(sourcelocptrzero(parent.loc), error_message, type_quoted_error_string(left.type), type_quoted_error_string(right.type));
		return false;
	}
	if (type_is_signed(flat_max))
	{
		if (!sema_check_untyped_promotion(context, left, true, flat_max, max)) return false;
		if (!sema_check_untyped_promotion(context, right, false, flat_max, max)) return false;
	}
	return cast_implicit_binary(context, left, max, failed_ref) &&
		   cast_implicit_binary(context, right, max, failed_ref);
}

// sema_expr.c:8707 (static)
fn void sema_binary_unify_voidptr(Expr* left, Expr* right, Type** left_type_ref, Type** right_type_ref)
{
	if (*left_type_ref == *right_type_ref) return;
	if (*left_type_ref == type_voidptr)
	{
		cast_no_check(left, *right_type_ref, @is_optional(left));
		*left_type_ref = *right_type_ref;
	}
	if (*right_type_ref == type_voidptr)
	{
		cast_no_check(right, *left_type_ref, @is_optional(right));
		*right_type_ref = *left_type_ref;
	}
}

// sema_expr.c:8722 (static)
fn Type* defer_iptr_cast(Expr* maybe_pointer)
{
	// Do we have (iptr)(ptr) +- rhs? If so we change it to
	// (iptr)((char*)(ptr) +- 1)
	if (maybe_pointer.expr_kind == PTR_TO_INT
		&& type_flatten(maybe_pointer.type) == type_flatten(type_iptr))
	{
		maybe_pointer.expr_kind = RVALUE;
		Type* cast_to_iptr = maybe_pointer.type;
		maybe_pointer.type = type_get_ptr(type_char);
		return cast_to_iptr;
	}
	return null;
}

// sema_expr.c:8737 (static)
fn bool sema_expr_analyse_ptr_sub(SemaContext* context, Expr* expr, Expr* left, Expr* right, CanonicalType* left_type, Type* cast_to_iptr, bool* failed_ref)
{
	Type* right_type = type_no_optional(right.type).canonical;
	bool left_is_ptr_vector = left_type.type_kind != POINTER;
	ArrayIndex vec_len = left_is_ptr_vector ? left_type.array.len : 0;
	// We restore the type to ensure distinct types are tested against each other.
	left_type = type_no_optional(left.type).canonical;

	bool right_is_pointer_vector = type_is_pointer_vector(right_type);
	bool right_is_pointer = right_is_pointer_vector || right_type.type_kind == POINTER;

	Type* offset_type = vec_len ? type_get_vector_from_vector(type_sz, left_type) : type_sz;
	bool optional = @is_optional(right) || @is_optional(left);
	// 3. ptr - other pointer
	if (right_is_pointer)
	{
		// Restore the type
		right_type = type_no_optional(right.type).canonical;

		// 3a. Require that both types are the same.
		sema_binary_unify_voidptr(left, right, &left_type, &right_type);
		if (left_type != right_type)
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, expr.loc, "'%s' - '%s' is not allowed. Subtracting pointers of different types is not allowed.",
				type_to_error_string(left_type), type_to_error_string(right_type));
		}

		if (expr_both_const_foldable(left, right, SUB))
		{
			long diff = (long)(left.const_expr.ptr - right.const_expr.ptr) / (long)type_size(left_type.pointer);
			expr_rewrite_const_integer(expr, type_sz, i128_from_signed(diff));
			return true;
		}
		// 3b. Set the type
		expr.type = type_add_optional(offset_type, optional);
		return true;
	}

	right_type = right.type.canonical;

	bool right_is_vector = type_kind_is_real_vector(right_type.type_kind);
	// 4. Check that the right hand side is an integer.
	if (!type_flat_is_intlike(right_type))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "Cannot subtract '%s' from '%s'", type_to_error_string(right_type),
		                  type_to_error_string(left_type));
	}

	// 5. Make sure that the integer does not exceed sz in size.
	ArrayIndex max_size = right_is_vector ? type_size(offset_type) : type_size(type_sz);
	if (type_size(right_type) > max_size)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "Cannot subtract %s from a %s, you need to add an explicit a narrowing cast to %s.",
		                  type_quoted_error_string(right.type),
		                  left_is_ptr_vector ? "pointer vector" : "pointer",
		                  type_quoted_error_string(right_is_vector ? offset_type : type_sz));
	}

	// 6. Convert to sz
	if (!cast_implicit_binary(context, right, type_add_optional(offset_type, optional), failed_ref)) return false;

	if (left.expr_kind == POINTER_OFFSET)
	{
		SourceLocId old_loc = expr.loc;
		*expr = *left;
		left.loc = old_loc;
		left.expr_kind = BINARY;
		left.binary_expr = {
			.operator = SUB,
			.left = expr.pointer_offset_expr.offset,
			.right = exprid(right)
		};
		left.resolve_status = NOT_DONE;
		if (!sema_analyse_expr_rvalue(context, left)) return false;
		expr.pointer_offset_expr.offset = exprid(left);
	}
	else
	{
		expr.expr_kind = POINTER_OFFSET;
		expr.pointer_offset_expr.ptr = exprid(left);
		expr.pointer_offset_expr.offset = exprid(expr_negate_expr(right));
	}

	expr.resolve_status = NOT_DONE;
	if (!sema_analyse_expr_rvalue(context, expr)) return false;

	if (cast_to_iptr)
	{
		expr.resolve_status = DONE;
		return cast_explicit(context, expr, cast_to_iptr);
	}

	return true;
}

<*
 Analyse a - b
 @return "true if analysis succeeded"
*>
// sema_expr.c:8838 (static)
fn bool sema_expr_analyse_sub(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	// 1. Analyse a and b.
	if (!sema_binary_analyse_subexpr(context, left, right)) return false;

	// Do we have (iptr)(ptr) - rhs? If so we change it to
	// (iptr)((char*)(ptr) - 1)
	Type* cast_to_iptr = defer_iptr_cast(left);

	Type* left_type = type_no_optional(left.type).canonical;
	Type* right_type = type_no_optional(right.type).canonical;

	bool left_is_pointer_vector = type_is_pointer_vector(left_type);
	bool left_is_pointer = left_is_pointer_vector || left_type.type_kind == POINTER;

	// 2. Handle the ptr - x and ptr - other_pointer
	if (left_is_pointer)
	{
		return sema_expr_analyse_ptr_sub(context, expr, left, right, left_type, cast_to_iptr, failed_ref);
	}

	// 7. Attempt arithmetic promotion, to promote both to a common type.
	OperatorOverload overload = OVERLOAD_MINUS;
	if (!sema_binary_arithmetic_promotion(context, left, right, left_type, right_type, expr,
										  "The subtraction %s - %s is not possible.", false, &overload, failed_ref))
	{
		return false;
	}

	if (!overload) return true;

	// 8. Handle constant folding.
	if (expr_both_const_foldable(left, right, SUB))
	{
		expr_replace(expr, left);
		switch (left.const_expr.const_kind)
		{
			case INTEGER:
				expr.const_expr.ixx = int_sub(left.const_expr.ixx, right.const_expr.ixx);
			case FLOAT:
				expr.const_expr.fxx = float_sub(left.const_expr.fxx, right.const_expr.fxx);
			default:
				unreachable();
		}
	}

	expr_binary_unify_failability(expr, left, right);

	return true;

}

// sema_expr.c:8892 (static)
fn bool sema_expr_analyse_ptr_add(SemaContext* context, Expr* expr, Expr* left, Expr* right, CanonicalType* left_type, CanonicalType* right_type, Type* cast_to_iptr, bool* failed_ref)
{
	bool left_is_vec = type_kind_is_real_vector(left_type.type_kind);
	bool right_is_vec = type_kind_is_real_vector(right_type.type_kind);

	// 3a. Check that the other side is an integer of some sort.
	if (!type_is_integer(right_type))
	{
		if (!left_is_vec || !right_is_vec || !type_is_integer(right_type.array.base))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, right.loc, "A value of type '%s' cannot be added to '%s', an integer was expected here.",
			                  type_to_error_string(right.type),
			                  type_to_error_string(left.type));
		}
	}

	// 3b. Cast it to usz or sz depending on underlying type.
	//     Either is fine, but it looks a bit nicer if we actually do this and keep the sign.
	// This may fail if vectors are not the same size.
	if (!cast_explicit(context, right, left_is_vec ? type_get_vector_from_vector(type_sz, left_type) : type_sz)) return false;

	// Folding offset.
	if (left.expr_kind == POINTER_OFFSET)
	{
		SourceLocId old_loc = expr.loc;
		*expr = *left;
		left.loc = old_loc;
		left.expr_kind = BINARY;
		left.binary_expr = {
			.operator = ADD,
			.left = expr.pointer_offset_expr.offset,
			.right = exprid(right)
		};
		left.resolve_status = NOT_DONE;
		if (!sema_analyse_expr_rvalue(context, left)) return false;
		expr.pointer_offset_expr.offset = exprid(left);
	}
	else
	{
		// Set the type and other properties.
		expr.type = left.type;
		expr.pointer_offset_expr.ptr = exprid(left);
		expr.pointer_offset_expr.offset = exprid(right);
		expr.expr_kind = POINTER_OFFSET;
	}

	expr.resolve_status = NOT_DONE;
	if (!sema_analyse_expr_rvalue(context, expr)) return false;

	if (cast_to_iptr)
	{
		expr.resolve_status = DONE;
		return cast_explicit(context, expr, cast_to_iptr);
	}
	return true;
}

<*
 Analyse a + b
 @return "true if it succeeds."
*>
// sema_expr.c:8953 (static)
fn bool sema_expr_analyse_add(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	// 1. Promote everything to the recipient type – if possible
	//    this is safe in the pointer case actually.
	if (!sema_binary_analyse_subexpr(context, left, right)) return false;


	Type* left_type = type_no_optional(left.type).canonical;
	Type* right_type = type_no_optional(right.type).canonical;

	// 4. Do a binary arithmetic promotion
	OperatorOverload overload = OVERLOAD_PLUS;
	if (!sema_binary_arithmetic_promotion(context, left, right, left_type, right_type, expr,
		"Cannot do the addition %s + %s.", false, &overload, failed_ref))
	{
		return false;
	}
	if (!overload) return true;

	// 5. Handle the "both const" case. We should only see ints and floats at this point.
	if (expr_both_const_foldable(left, right, ADD))
	{
		expr_replace(expr, left);
		switch (left.const_expr.const_kind)
		{
			case INTEGER:
				expr.const_expr.ixx = int_add(left.const_expr.ixx, right.const_expr.ixx);
			case FLOAT:
				expr.const_expr.fxx = float_add(left.const_expr.fxx, right.const_expr.fxx);
			default:
				unreachable();
		}
	}

	// 6. Set the type & other properties.
	expr_binary_unify_failability(expr, left, right);

	return true;

}

<*
 Analyse a * b

 Will analyse a and b and then use arithmetic promotion on each.
 It will then try to promote both to a common type,

 @return "true if analysis worked."
*>
// sema_expr.c:9004 (static)
fn bool sema_expr_analyse_mult(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{

	// 1. Analyse the sub expressions and promote to a common type
	OperatorOverload overload = OVERLOAD_MULTIPLY;
	if (!sema_binary_analyse_arithmetic_subexpr(context, expr, "It is not possible to multiply %s by %s.", false, &overload, failed_ref)) return false;

	if (!overload) return true;

	// 2. Handle constant folding.
	if (expr_both_const_foldable(left, right, MULT))
	{
		expr_replace(expr, left);
		switch (left.const_expr.const_kind)
		{
			case INTEGER:
				expr.const_expr.ixx = int_mul(left.const_expr.ixx, right.const_expr.ixx);
			case FLOAT:
				expr.const_expr.fxx = float_mul(left.const_expr.fxx, right.const_expr.fxx);
			default:
				unreachable();
		}
	}

	// 3. Set the new type
	expr.type = type_add_optional(left.type, @is_optional(right));

	return true;
}

// sema_expr.c:9036 (static)
fn bool sema_convert_denominator_to_unsigned_if_needed(SemaContext* context, Expr* left, Expr* right)
{
	if (!type_is_unsigned(left.type.canonical) || !type_is_signed(right.type.canonical)) return true;
	if (type_size(left.type) < type_size(right.type)) return true;
	if (sema_cast_const(right) && expr_is_const_int(right) && !int_is_neg(right.const_expr.ixx))
	{
		return cast_implicit(context, right, type_int_unsigned_by_bitsize(type_bit_size(right.type.canonical)), true);
	}
	return false;
}

<*
 Analyse a / b
 @return "true if analysis completed ok."
*>
// sema_expr.c:9051 (static)
fn bool sema_expr_analyse_div(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	// 1. Analyse sub expressions and promote to a common type
	OperatorOverload overload = OVERLOAD_DIVIDE;
	if (!sema_convert_denominator_to_unsigned_if_needed(context, left, right))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "Cannot implicitly divide an unsigned integer by a non-const or negative signed integer, please use explicit casts.");
	}
	if (!sema_binary_analyse_arithmetic_subexpr(context, expr, "Cannot divide %s by %s.", false, &overload, failed_ref)) return false;
	if (!overload) return true;

	// 2. Check for a constant 0 on the rhs.
	if (sema_cast_const(right))
	{
		switch (right.const_expr.const_kind)
		{
			case FLOAT:
				// This is allowed, as it will generate a NaN
				break;
			case INTEGER:
				if (int_is_zero(right.const_expr.ixx))
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, right.loc, "This expression evaluates to zero and division by zero is not allowed.");
				}
			case INITIALIZER:
				// Do not analyse
				break;
			default:
				unreachable();
		}
	}

	// 3. Perform constant folding.
	if (expr_both_const_foldable(left, right, DIV))
	{
		expr_replace(expr, left);
		switch (left.const_expr.const_kind)
		{
			case INTEGER:
				expr.const_expr.ixx = int_div(left.const_expr.ixx, right.const_expr.ixx);
			case FLOAT:
				expr.const_expr.fxx = float_div(left.const_expr.fxx, right.const_expr.fxx);
			default:
				unreachable();
		}
	}

	// 4. Done.
	expr.type = type_add_optional(left.type, @is_optional(right));
	return true;

}

<*
 Analyse a % b
 @return "true if analysis succeeds."
*>
// sema_expr.c:9114 (static)
fn bool sema_expr_analyse_mod(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	// 1. Analyse both sides and promote to a common type
	OperatorOverload overload = OVERLOAD_REMINDER;
	if (!sema_convert_denominator_to_unsigned_if_needed(context, left, right))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "Cannot implicitly convert the values in a remainder operation with an unsigned nominator and non-const or negative signed denominator, please use explicit casts.");
	}

	if (!sema_binary_analyse_arithmetic_subexpr(context, expr, "Cannot calculate the remainder %s %% %s",
		false, &overload, failed_ref)) return false;
	if (!overload) return true;

	Type* flat = type_flatten(left.type);
	if (type_is_float(flat))
	{
		// 3. a % 0 is not valid, so detect it.
		if (sema_cast_const(right) && right.const_expr.fxx.f == 0.0)
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, right.loc, "Cannot perform %% with a constant zero.");
		}

		// 4. Constant fold
		if (expr_both_const_foldable(left, right, MOD))
		{
			expr_replace(expr, left);
			// 4a. Remember this is remainder.
			expr.const_expr.fxx = float_rem(left.const_expr.fxx, right.const_expr.fxx);
		}
	}
	else if (type_is_integer(flat))
	{
		// 3. a % 0 is not valid, so detect it.
		if (sema_cast_const(right) && int_is_zero(right.const_expr.ixx))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, right.loc, "Cannot perform %% with a constant zero.");
		}

		// 4. Constant fold
		if (expr_both_const_foldable(left, right, MOD))
		{
			expr_replace(expr, left);
			// 4a. Remember this is remainder.
			expr.const_expr.ixx = int_rem(left.const_expr.ixx, right.const_expr.ixx);
		}
	}

	expr.type = type_add_optional(left.type, @is_optional(right));
	return true;
}

<*
 Analyse a ^ b, a | b, a & b
 @return "true if the analysis succeeded."
*>
// sema_expr.c:9173 (static)
fn bool sema_expr_analyse_bit(SemaContext* context, Expr* expr, Expr* left, Expr* right, OperatorOverload overload, bool* failed_ref)
{
	// 1. Convert to common type if possible.
	if (!sema_binary_analyse_arithmetic_subexpr(context, expr, {}, true, &overload, failed_ref)) return false;
	if (!overload) return true;

	// 2. Check that both are integers or bools.
	Type* flat_left = type_flatten(left.type);
	bool is_bool = flat_left == type_bool;
	bool is_bitstruct = flat_left.type_kind == BITSTRUCT;

	if (!is_bool && !is_bitstruct && !expr_both_any_integer_or_integer_bool_vector(left, right))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return sema_type_error_on_binop(context, expr);
	}

	// 3. Do constant folding if both sides are constant.
	if (expr_both_const_foldable(left, right, BIT_AND))
	{
		BinaryOp op = expr.binary_expr.operator;
		expr_replace(expr, left);
		if (is_bool)
		{
			switch (op)
			{
				case BIT_AND:
					expr.const_expr.b = left.const_expr.b & right.const_expr.b;
				case BIT_XOR:
					expr.const_expr.b = left.const_expr.b ^ right.const_expr.b;
				case BIT_OR:
					expr.const_expr.b = left.const_expr.b | right.const_expr.b;
				default:
					unreachable();
			}
		}
		else if (is_bitstruct)
		{
			// Avoid merging with value casts, eg (Bitstruct)1 (c3c: goto DONE)
			if (expr_is_const_initializer(left) && expr_is_const_initializer(right))
			{
				ConstInitializer* merged = sema_merge_bitstruct_const_initializers(left.const_expr.initializer,
																				   right.const_expr.initializer, op);
				expr.const_expr.initializer = merged;
			}
		}
		else
		{
			switch (op)
			{
				case BIT_AND:
					expr.const_expr.ixx = int_and(left.const_expr.ixx, right.const_expr.ixx);
				case BIT_XOR:
					expr.const_expr.ixx = int_xor(left.const_expr.ixx, right.const_expr.ixx);
				case BIT_OR:
					expr.const_expr.ixx = int_or(left.const_expr.ixx, right.const_expr.ixx);
				default:
					unreachable();
			}
		}
	}
	// DONE:
	// 5. Assign the type
	expr_binary_unify_failability(expr, left, right);
	return true;
}

// sema_expr.c:9244 (static)
fn bool sema_expr_check_shift_rhs(SemaContext* context, Expr* expr, Expr* left, Type* left_type_flat, Expr* right, Type* right_type_flat, bool* failed_ref, bool is_assign)
{
	// For a constant rhs side we will make a series of checks.
	// We could extend this by checking vectors
	if (sema_cast_const(right) && expr_is_const_int(right))
	{
		// Make sure the value does not exceed the bitsize of
		// the left hand side. We ignore this check for lhs being a constant.
		Type* base = type_flatten(type_vector_base(left_type_flat));
		assert(type_kind_is_any_integer(base.type_kind));
		if (int_ucomp(right.const_expr.ixx, base.builtin.bitsize, GE))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, right.loc, "The shift (%s) is not less than the bitsize of %s.", int_to_str(right.const_expr.ixx, 10, false), type_quoted_error_string(type_no_optional(left.type)));
		}

		// Make sure that the RHS is positive.
		if (int_is_neg(right.const_expr.ixx))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, right.loc, "A shift must be a positive number.");
		}
	}

	// If LHS is vector but RHS isn't? Promote.
	bool lhs_is_vec = type_kind_is_real_vector(left_type_flat.type_kind);
	if (lhs_is_vec && !type_kind_is_real_vector(right_type_flat.type_kind))
	{
		// Create a vector from the right hand side.
		Type* right_vec = type_get_vector_from_vector(right.type, left_type_flat);
		if (!cast_explicit_checkable(context, right, right_vec, failed_ref)) return false;
	}

	bool rhs_is_vec = type_kind_is_real_vector(right_type_flat.type_kind);
	if (!lhs_is_vec && rhs_is_vec)
	{
		if (is_assign)
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, right.loc, "The shift cannot be a vector of type %s when shifting a variable of type %s.",
				type_quoted_error_string(right.type), type_quoted_error_string(left.type));
		}
		Type* left_vec = type_get_vector_from_vector(left.type, right_type_flat);
		if (!cast_explicit_checkable(context, left, left_vec, failed_ref)) return false;

	}
	// Same type is always ok
	Type* right_type = type_no_optional(right.type).canonical;
	if (type_no_optional(left.type).canonical == right_type) return true;

	Type* base = right_type;
	if (type_kind_is_real_vector(right_type.type_kind))
	{
		base = right_type.array.base.canonical;
		base = type_flat_distinct_enum_inline(base);
		right_type = type_get_vector_from_vector(base, right_type);
	}
	else
	{
		base = type_flat_distinct_enum_inline(base);
		right_type = base;
	}
	if (!type_is_integer(base))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		// c3c also passes the (unused) left type as an extra argument.
		return @sema_error_at(context, right.loc, "The right hand shift must be an integer type, or match the left hand side type, but it was %s",
			type_quoted_error_string(right.type));
	}
	return cast_implicit_binary(context, right, right_type, failed_ref);
}

<*
 Analyse >> and << operations.
 @return "true if the analysis succeeded."
*>
// sema_expr.c:9319 (static)
fn bool sema_expr_analyse_shift(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	// 1. Analyze both sides.
	if (!sema_binary_analyse_subexpr(context, left, right)) return false;

	Type* lhs_type = type_no_optional(left.type).canonical;
	bool shr = expr.binary_expr.operator == SHR;

	if (type_is_user_defined(lhs_type))
	{
		OperatorOverload overload = shr ? OVERLOAD_SHR : OVERLOAD_SHL;
		if (!sema_replace_with_overload(context, expr, left, right, lhs_type, &overload)) return false;
		if (!overload) return true;
	}

	// 3. Promote lhs using the usual numeric promotion.
	if (!cast_implicit_binary(context, left, cast_numeric_arithmetic_promotion(lhs_type), failed_ref)) return false;

	Type* flat_left = type_flatten_and_inline(left.type);
	Type* flat_right = type_flatten_and_inline(right.type);
	bool fail = false;
	if (type_kind_is_real_vector(flat_left.type_kind))
	{
		Type* left_base = type_flatten_and_inline(flat_left.array.base);
		if (!type_is_integer(left_base)) fail = true;
	}
	else
	{
		if (!type_is_integer(flat_left)) fail = true;
	}

	if (!fail && !type_is_numeric(flat_right)) fail = true;

	if (fail)
	{
		// FAIL:
		if (failed_ref) { *failed_ref = true; return false; }
		return sema_type_error_on_binop(context, expr);
	}

	if (!sema_expr_check_shift_rhs(context, expr, left, flat_left, right, flat_right, failed_ref, false)) return false;

	// Fold constant expressions.
	if (expr_both_const_foldable(left, right, SHL))
	{
		expr_replace(expr, left);
		if (shr)
		{
			expr.const_expr.ixx = int_shr64(left.const_expr.ixx, (ulong)right.const_expr.ixx.i);
		}
		else
		{
			expr.const_expr.ixx = int_shl64(left.const_expr.ixx, (ulong)right.const_expr.ixx.i);
		}
		return true;
	}

	// 6. Set the type
	expr.type = type_add_optional(left.type, @is_optional(right));
	return true;
}

// sema_expr.c:9377 (static)
fn bool sema_expr_analyse_and_or(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	if (!sema_binary_analyse_subexpr(context, left, right)) return false;
	if (!cast_explicit_checkable(context, left, type_bool, failed_ref) || !cast_explicit_checkable(context, right, type_bool, failed_ref)) return false;

	if (expr_both_const_foldable(left, right, AND))
	{
		if (expr.binary_expr.operator == AND)
		{
			expr_replace(expr, left);
			expr.const_expr.b &= right.const_expr.b;
		}
		else
		{
			expr_replace(expr, left);
			expr.const_expr.b |= right.const_expr.b;
		}
	}
	expr.type = type_add_optional(type_bool, @is_optional(left) || @is_optional(right));
	return true;
}

// sema_expr.c:9399 (static)
fn bool sema_binary_is_unsigned_always_same_comparison(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* lhs_type, Type* rhs_type)
{
	if (context.active_scope.flags & (SCOPE_MACRO | SCOPE_ENSURE | SCOPE_ENSURE_MACRO)) return true;
	if (!sema_cast_const(left) && !sema_cast_const(right)) return true;
	if (!type_is_integer(left.type)) return true;
	if (expr_is_const_int(left) && type_is_unsigned(rhs_type))
	{
		if (int_is_neg(left.const_expr.ixx))
		{
			@sema_error_at(context, left.loc, "Comparing an unsigned value with a negative constant is only allowed inside of macros.");
			return false;
		}
		if (!int_is_zero(left.const_expr.ixx)) return true;
		switch (expr.binary_expr.operator)
		{
			case GT:
				return @sema_error_at(context, right.loc,
								  "Comparing '0 > unsigned expression' can never be true, and is only allowed inside of macro expansions.");
			case GE:
				return @sema_error_at(context, right.loc,
								  "Comparing '0 >= unsigned expression' is the same as 0 == expr and is a common bug, "
								  "for this reason it is only allowed inside of macro expansions.");
			case LE:
				return @sema_error_at(context, right.loc,
								  "Comparing '0 <= unsigned expression' is always true and is a common bug, "
								  "for this reason it is only allowed inside of macro expansions.");
			default:
				return true;
		}
	}
	if (!expr_is_const_int(right) || !type_is_unsigned(lhs_type)) return true;
	if (int_is_neg(right.const_expr.ixx))
	{
		@sema_error_at(context, right.loc, "Comparing an unsigned value with a negative constant is only allowed inside of macros.");
		return false;
	}
	if (!int_is_zero(right.const_expr.ixx)) return true;
	switch (expr.binary_expr.operator)
	{
		case LT:
			return @sema_error_at(context, right.loc,
							  "Comparing 'unsigned expression < 0' can never be true, and is only allowed inside of macro expansions.");
		case LE:
			return @sema_error_at(context, right.loc,
							  "Comparing 'unsigned expression <= 0' is the same as expr == 0 and is a common bug, "
							  "for this reason it is only allowed inside of macro expansions.");
		case GE:
			return @sema_error_at(context, right.loc,
							  "Comparing 'unsigned expression >= 0' is always true and is a common bug, "
							  "for this reason it is only allowed inside of macro expansions.");
		default:
			return true;
	}

}

// sema_expr.c:9458 (static)
fn BoolErr sema_type_has_overload(SemaContext* context, CanonicalType* type, OperatorOverload overload)
{
	// c3c: assert(type.canonical == type); -- C assert, compiled out in c3c release builds
	Decl* candidate = null;
	Decl* ambiguous = null;
	OverloadMatch match = sema_find_typed_operator_type(context, overload, OVERLOAD_TYPE_LEFT, type, type, null, &candidate, OVERLOAD_MATCH_NONE, &ambiguous);
	switch (match)
	{
		case OVERLOAD_MATCH_ERROR:
			return BOOL_ERR;
		case OVERLOAD_MATCH_EXACT:
		case OVERLOAD_MATCH_WILDCARD:
		case OVERLOAD_MATCH_CONVERSION:
			return BOOL_TRUE;
		case OVERLOAD_MATCH_NONE:
		case OVERLOAD_MATCH_AMBIGUOUS_WILDCARD:
		case OVERLOAD_MATCH_AMBIGUOUS_CONVERSION:
		case OVERLOAD_MATCH_AMBIGUOUS_EXACT:
			return BOOL_FALSE;
	}
	unreachable();
}

// sema_expr.c:9481
fn BoolErr sema_type_has_compare_overload(SemaContext* context, CanonicalType* type)
{
	BoolErr res = sema_type_has_overload(context, type, OVERLOAD_EQUAL);
	if (res != BOOL_TRUE) return res;
	return sema_type_has_overload(context, type, OVERLOAD_LESS_THAN);
}

// sema_expr.c:9488
fn BoolErr sema_type_has_equality_overload(SemaContext* context, Type* type)
{
	return sema_type_has_overload(context, type, OVERLOAD_EQUAL);
}

// sema_expr.c:9493
fn BoolErr sema_type_can_check_equality_with_overload(SemaContext* context, Type* type)
{
	while (true) // RETRY:
	{
		switch (type.type_kind)
		{
			case INFERRED_VECTOR:
			case INFERRED_ARRAY:
			case POISONED:
				unreachable();
			case VOID:
			case FLEXIBLE_ARRAY:
			case OPTIONAL:
			case UNTYPEDLIST:
			case TYPEINFO:
			case MEMBER:
			case REFLECTION:
				return BOOL_FALSE;
			case UNION:
			case STRUCT:
				return sema_type_has_equality_overload(context, type);
			case BITSTRUCT:
				return BOOL_TRUE;
			case ALIAS:
				type = type.canonical;
				continue;
			case SLICE:
			case ARRAY:
				// Arrays are comparable if elements are
				type = type.array.base;
				continue;
			case TYPEDEF:
			case CONSTSET:
				if (sema_type_has_equality_overload(context, type) != BOOL_FALSE) return BOOL_TRUE;
				type = type_inline(type);
				continue;
			case BOOL:
			case I8: case I16: case I32: case I64: case I128:
			case U8: case U16: case U32: case U64: case U128:
			case BF16: case F16: case F32: case F64: case F128:
			case ANY:
			case INTERFACE:
			case ANYFAULT:
			case TYPEID:
			case POINTER:
			case ENUM:
			case FUNC_PTR:
			case FUNC_RAW:
			case VECTOR:
			case SIMD_VECTOR:
			case WILDCARD:
				return BOOL_TRUE;
		}
		unreachable();
	}
}

// sema_expr.c:9544
fn BoolErr sema_type_can_order_with_overload(SemaContext* context, Type* type)
{
	while (true) // RETRY:
	{
		switch (type.type_kind)
		{
			case INFERRED_VECTOR:
			case INFERRED_ARRAY:
			case POISONED:
				unreachable();
			case VOID:
			case FLEXIBLE_ARRAY:
			case OPTIONAL:
			case UNTYPEDLIST:
			case TYPEINFO:
			case MEMBER:
			case REFLECTION:
				return BOOL_FALSE;
			case UNION:
			case STRUCT:
				return sema_type_has_compare_overload(context, type);
			case BITSTRUCT:
				return BOOL_TRUE;
			case ALIAS:
				type = type.canonical;
				continue;
			case SLICE:
			case ARRAY:
				// Arrays are comparable if elements are
				type = type.array.base;
				continue;
			case TYPEDEF:
			case CONSTSET:
				if (sema_type_has_compare_overload(context, type) != BOOL_FALSE) return BOOL_TRUE;
				type = type_inline(type);
				continue;
			case BOOL:
			case I8: case I16: case I32: case I64: case I128:
			case U8: case U16: case U32: case U64: case U128:
			case BF16: case F16: case F32: case F64: case F128:
			case ANY:
			case INTERFACE:
			case ANYFAULT:
			case TYPEID:
			case POINTER:
			case ENUM:
			case FUNC_PTR:
			case FUNC_RAW:
			case VECTOR:
			case SIMD_VECTOR:
			case WILDCARD:
				return BOOL_TRUE;
		}
		unreachable();
	}
}

// sema_expr.c:9595 (static)
fn Decl* ast_append_generated_local(Ast** ast_current_ref, Expr* init)
{
	Ast* ast = ast_new(DECLARE_STMT, init.loc);
	Decl* var_ = decl_new_generated_var(init.type, LOCAL, init.loc);
	// c3c: assert(init.resolve_status == DONE); -- C assert, compiled out in c3c release builds
	var_.var_decl.init_expr = init;
	ast.declare_stmt = var_;
	(*ast_current_ref).next = astid(ast);
	*ast_current_ref = ast;
	return var_;
}

// sema_expr.c:9607 (static)
fn bool sema_rewrite_slice_comparison(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* max)
{
	BinaryOp op = expr.binary_expr.operator;
	bool is_eq = op == EQ;
	Ast dummy;
	Ast* current = &dummy;
	Decl* left_var = left.expr_kind == IDENTIFIER ? left.ident_expr : ast_append_generated_local(&current, left);
	Decl* right_var = right.expr_kind == IDENTIFIER ? right.ident_expr : ast_append_generated_local(&current, right);
	Decl* len_var_left = null;
	ArrayIndex len = 0;
	SourceLocId default_loc = expr.loc;
	bool optional = @is_optional(left_var) || @is_optional(right_var);
	Type* return_type = optional ? type_get_optional(type_bool) : type_bool;

	Ast* compound_stmt = ast_new(COMPOUND_STMT, default_loc);
	Type* old_expected_block = context.expected_block_type;
	BlockExit** old_exit_ref = context.block_exit_ref;
	Ast*[] old_block_returns = context.block_returns;
	context.expected_block_type = return_type;
	BlockExit** block_exit_ref = calloc_arena(usz::size);
	context.block_exit_ref = block_exit_ref;
	bool success = false;
	DynamicScope old_scope = scope_start_with_flags(context, SCOPE_MACRO, default_loc);

	// c3c `goto EXIT` -> break out of this one-shot block.
	do
	{
		if (@is_optional(left_var))
		{
			Expr* expr_var = expr_variable(left_var);
			Expr* rethrow = expr_new(RETHROW, left.loc);
			rethrow.rethrow_expr.inner = expr_var;
			context.active_scope.flags |= SCOPE_COMPARISON;
			if (!sema_analyse_expr(context, rethrow)) break;
			context.active_scope.flags &= ~SCOPE_COMPARISON;
			left_var = ast_append_generated_local(&current, rethrow);
		}
		if (@is_optional(right_var))
		{
			Expr* expr_var = expr_variable(right_var);
			Expr* rethrow = expr_new(RETHROW, right.loc);
			rethrow.rethrow_expr.inner = expr_var;
			context.active_scope.flags |= SCOPE_COMPARISON;
			if (!sema_analyse_expr(context, rethrow)) break;
			context.active_scope.flags &= ~SCOPE_COMPARISON;
			right_var = ast_append_generated_local(&current, rethrow);
		}
		if (max.type_kind == ARRAY)
		{
			len = max.array.len;
		}
		else
		{
			Expr* len_left = expr_new(SLICE_LEN, left.loc);
			Expr* len_right = expr_new(SLICE_LEN, right.loc);
			len_left.inner_expr = expr_variable(left_var);
			len_right.inner_expr = expr_variable(right_var);
			len_left.type = type_sz;
			len_right.type = type_sz;
			if (!sema_analyse_expr_rvalue(context, len_left)) break;
			if (!sema_analyse_expr_rvalue(context, len_right)) break;
			len_var_left = ast_append_generated_local(&current, len_left);
			Ast* ast_if = ast_new(IF_STMT, default_loc);
			Expr* expr_comparison = expr_new_binary(default_loc, expr_variable(len_var_left), len_right, NE);
			Ast* ast_then = ast_new(RETURN_STMT, default_loc);
			ast_then.return_stmt.expr = expr_new_const_bool(default_loc, type_bool, !is_eq);
			ast_if.if_stmt.cond = exprid(expr_new_cond(expr_comparison));
			ast_if.if_stmt.then_body = astid(ast_then);
			current.next = astid(ast_if);
			current = ast_if;
		}
		Decl* index = ast_append_generated_local(&current, expr_new_const_int(default_loc, type_sz, 0));
		Ast* ast = ast_new(FOR_STMT, default_loc);
		Expr* cond_expr;
		if (len > 0)
		{
			cond_expr = expr_new_binary(default_loc, expr_variable(index), expr_new_const_int(default_loc, type_sz, (ulong)len), LT);
		}
		else
		{
			cond_expr = expr_new_binary(default_loc, expr_variable(index), expr_variable(len_var_left), LT);
		}
		ast.for_stmt.cond = exprid(expr_new_cond(cond_expr));
		Expr* update = expr_new(UNARY, default_loc);
		update.unary_expr.expr = expr_variable(index);
		update.unary_expr.operator = INC;
		update.unary_expr.no_wrap = true;
		ast.for_stmt.incr = exprid(update);

		Expr* left_check = expr_new(SUBSCRIPT, default_loc);
		left_check.subscript_expr.expr = exprid(expr_variable(left_var));
		left_check.subscript_expr.index.expr = exprid(expr_variable(index));
		left_check.subscript_expr.no_check = true;
		Expr* right_check = expr_new(SUBSCRIPT, default_loc);
		right_check.subscript_expr.expr = exprid(expr_variable(right_var));
		right_check.subscript_expr.index.expr = exprid(expr_variable(index));
		right_check.subscript_expr.no_check = true;

		Expr* expr_comparison = expr_new_binary(default_loc, left_check, right_check, NE);
		Ast* ast_then = ast_new(RETURN_STMT, default_loc);
		ast_then.return_stmt.expr = expr_new_const_bool(default_loc, type_bool, !is_eq);
		Ast* ast_if = ast_new(IF_STMT, default_loc);
		ast_if.if_stmt.cond = exprid(expr_new_cond(expr_comparison));
		ast_if.if_stmt.then_body = astid(ast_then);
		ast.for_stmt.body = astid(ast_if);

		current.next = astid(ast);
		current = ast;
		Ast* ast_after = ast_new(RETURN_STMT, default_loc);
		ast_after.return_stmt.expr = expr_new_const_bool(default_loc, type_bool, is_eq);
		current.next = astid(ast_after);
		AstId start = dummy.next;


		// Create macro
		compound_stmt.compound_stmt.first_stmt = start;

		success = sema_analyse_stmt_chain(context, compound_stmt);
	};

	// EXIT:
	if (!scope_end_check(context, old_scope)) return false;
	context.expected_block_type = old_expected_block;
	context.block_exit_ref = old_exit_ref;
	context.block_returns = old_block_returns;

	if (!success) return false;

	expr.expr_kind = MACRO_BLOCK;
	expr.resolve_status = DONE;
	expr.type = return_type;
	expr.macro_block = {
		.first_stmt = astid(compound_stmt),
		.block_exit = block_exit_ref
	};
	return true;
}

<*
 Analyze a == b, a != b, a > b, a < b, a >= b, a <= b
*>
// sema_expr.c:9749 (static)
fn bool sema_expr_analyse_comp(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	// 1. Analyse left and right side without any conversions.
	if (!sema_binary_analyse_subexpr(context, left, right)) return false;

	bool is_equality_type_op = expr.binary_expr.operator == NE || expr.binary_expr.operator == EQ;

	Type* left_type = type_no_optional(left.type).canonical;
	Type* right_type = type_no_optional(right.type).canonical;

	if (type_is_user_defined(left_type) || type_is_user_defined(right_type))
	{
		Decl* overload = null;
		bool negated_overload = false;
		bool reverse = false;
		// c3c `if (!overload) goto NEXT;` -> the `if (overload)` below.
		switch (expr.binary_expr.operator)
		{
			case LT:
				overload = sema_find_typed_operator(context, OVERLOAD_LESS_THAN, expr.loc, left, right, &reverse);
				if (!decl_ok(overload)) return false;
			case LE:
				overload = sema_find_typed_operator(context, OVERLOAD_LESS_THAN, expr.loc, right, left, &reverse);
				reverse = !reverse;
				negated_overload = true;
				if (!decl_ok(overload)) return false;
			case GE:
				overload = sema_find_typed_operator(context, OVERLOAD_LESS_THAN, expr.loc, left, right, &reverse);
				negated_overload = true;
				if (!decl_ok(overload)) return false;
			case GT:
				overload = sema_find_typed_operator(context, OVERLOAD_LESS_THAN, expr.loc, right, left, &reverse);
				reverse = !reverse;
				if (!decl_ok(overload)) return false;
			case NE:
				negated_overload = true;
				nextcase EQ;
			case EQ:
				overload = sema_find_typed_operator(context, OVERLOAD_EQUAL, expr.loc, left, right, &reverse);
				if (!decl_ok(overload)) return false;
			default:
				unreachable();
		}
		if (overload)
		{
			Expr*[] args = {};
			Decl* first_param = overload.func_decl.signature.params[1];
			if (first_param.type && first_param.type.canonical.type_kind == POINTER)
			{
				expr_insert_addr(right);
			}
			@vec_add(&args, right);
			if (!sema_insert_method_call(context, expr, overload, left, args, reverse)) return false;
			if (!negated_overload) return true;
			// c3c: assert(expr.resolve_status == DONE); -- C assert, compiled out in c3c release builds
			Expr* inner = expr_copy(expr);
			expr.expr_kind = UNARY;
			expr.unary_expr = { .expr = inner, .operator = NOT };
			expr.resolve_status = NOT_DONE;
			return sema_analyse_expr_rvalue(context, expr);
		}
	}
	// NEXT:
	// Flatten distinct/optional
	left_type = type_flat_distinct_inline(left_type).canonical;
	right_type = type_flat_distinct_inline(right_type).canonical;

	// 3. In the normal case, treat this as a binary op, finding the max type.
	Type* max = type_find_max_type(context, left_type, right_type, left, right);

	// 4. If no common type, then that's an error:
	if (!max)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "%s and %s are different types and cannot be compared.",
						  type_quoted_error_string(left.type), type_quoted_error_string(right.type));
	}
	if (max == poisoned_type) return false;

	max = max.canonical;

	if (type_kind_is_real_vector(max.type_kind) && !is_equality_type_op)
	{
		return @sema_error_at(context, expr.loc, "Vector types can only be tested for equality, for other comparison, use vector comparison functions.");
	}

	if (max == type_untypedlist)
	{
		return @sema_error_at(context, expr.loc, "Both sides are untyped and cannot be compared. Please cast one or both sides to a type, e.g. (Foo){ 1, 2 } == { 1, 2 }.");
	}

	if (!is_equality_type_op)
	{
		if (!type_is_ordered(max))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, expr.loc, "%s can only be compared using '!=' and '==' it "
									"cannot be ordered, did you make a mistake?",
							  type_quoted_error_string(left.type));
		}

		if (type_is_pointer_type(max))
		{

			// Only comparisons between the same type is allowed. Subtypes not allowed.
			if (left_type != right_type && left_type != type_voidptr && right_type != type_voidptr)
			{
				return @sema_error_at(context, expr.loc, "You are not allowed to compare pointers of different types, "
										"if you need to do, first convert all pointers to void*.");
			}
		}
	}

	// 6. Do the explicit cast.
	if (!cast_implicit_checked(context, left, max, false, failed_ref) || !cast_implicit_checked(context, right, max, false, failed_ref)) return false;
	bool success = cast_explicit_checkable(context, left, max, failed_ref) && cast_explicit_checkable(context, right, max, failed_ref);
	assert(success);

	if (!type_is_comparable(max))
	{
		if (is_equality_type_op && (max.type_kind == SLICE || max.type_kind == ARRAY))
		{
			Type* base = max.array.base;
			// Walk through nested arrays/slices
			while (base.type_kind == SLICE || base.type_kind == ARRAY) base = base.array.base;

			switch (sema_type_has_equality_overload(context, base))
			{
				case BOOL_ERR:
					return false;
				case BOOL_FALSE:
					break;
				case BOOL_TRUE:
					return sema_rewrite_slice_comparison(context, expr, left, right, max);
			}
		}

		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "%s does not support comparisons.",
						  type_quoted_error_string(left.type));
	}

	// 7. Do constant folding.
	if (expr_both_const_foldable(left, right, EQ))
	{
		expr.const_expr.b = expr_const_compare(&left.const_expr, &right.const_expr, expr.binary_expr.operator);
		expr.const_expr.const_kind = BOOL;
		expr.expr_kind = CONST;
		expr.resolve_status = DONE;
	}
	else
	{
		if (!sema_binary_is_unsigned_always_same_comparison(context, expr, left, right, left_type, right_type)) return false;
	}

	// 8. Set the type to bool
	expr.type = type_add_optional(type_bool, @is_optional(left) || @is_optional(right));

	return true;

}

// sema_expr.c:9920 (static)
fn bool sema_expr_analyse_deref(SemaContext* context, Expr* expr, bool* failed_ref)
{
	// 1. Check the inner expression
	Expr* inner = expr.unary_expr.expr;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;

	Type* inner_type_nofail = type_no_optional(inner.type);
	Type* canonical = inner_type_nofail.canonical;

	// 2. Check that we have a pointer, or dereference is not allowed.
	if (canonical.type_kind != POINTER)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, inner.loc, "Cannot dereference a value of type %s, it must be a pointer.",
		                      type_quoted_error_string(inner_type_nofail));
	}
	if (type_is_void(canonical.pointer))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, inner.loc, "A 'void*' cannot be dereferenced, you need to first cast it to a concrete type.");
	}

	// 3. This could be a constant, in which case we can inline any *&foo to "foo"
	//    and check for null.
	if (sema_cast_const(inner))
	{
		switch (inner.const_expr.const_kind)
		{
			case POINTER:
				if (!inner.const_expr.ptr)
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, inner.loc, "Dereferencing null is not allowed, did you do it by mistake?");
				}
			case REF:
				expr_replace(expr, expr_variable(inner.const_expr.global_ref));
			case BYTES:
			case STRING:
				if (inner.type.type_kind != POINTER) break;
				Type* inner_type = type_get_indexed_type(inner.type);
				if (!type_kind_is_any_integer(type_flatten(inner_type).type_kind)) break;
				if (!inner.const_expr.bytes.len)
				{
					return @sema_error_at(context, inner.loc, "You cannot dereference an empty constant array or slice.");
				}
				expr_rewrite_const_byte(expr, inner_type, (char)inner.const_expr.bytes.ptr[0]);
				return true;
			default:
				unreachable();
		}
	}

	// 4. Now the type might not be a pointer because of a typedef,
	//    otherwise we need to use the canonical representation.
	Type* deref_type = inner_type_nofail.type_kind == POINTER ? inner_type_nofail : canonical;

	// 5. And... set the type.
	expr.type = type_add_optional(deref_type.pointer, @is_optional(inner));
	return true;
}

// sema_expr.c:9989 (static)
fn String sema_addr_may_take_of_var(Expr* expr, Decl* decl)
{
	if (decl.decl_kind != VAR) return "This is not a regular variable.";
	decl_addr(decl);
	bool is_void = type_flatten(decl.type) == type_void;
	switch (decl.var_decl.kind)
	{
		case GLOBAL:
			if (is_void) return "You cannot take the address of a global of type 'void'";
			return {};
		case LOCAL:
			if (is_void) return "You cannot take the address of a variable of type 'void'";
			return {};
		case PARAM:
			if (is_void) return "You cannot take the address of a parameter of type 'void'";
			return {};
		case CONST:
			if (!decl.var_decl.type_info)
			{
				return "The constant is not typed, either type it or use && to take the reference to a temporary.";
			}
			assert(decl.type != type_void);
			return {};
		case PARAM_EXPR:
			return "It is not possible to take the address of a captured expression, but you can use && to take a reference to the temporary value.";
		case PARAM_CT:
		case PARAM_CT_TYPE:
		case LOCAL_CT_TYPE:
		case LOCAL_CT:
			return "It's not possible to take the address of a compile time value.";
		case MEMBER:
		case BITMEMBER:
		case UNWRAPPED:
		case REWRAPPED:
		case ERASE:
			unreachable();
	}
}

// sema_expr.c:10030 (static)
fn String sema_addr_may_take_of_ident(Expr* inner)
{
	Decl* decl = decl_raw(inner.ident_expr);
	switch (decl.decl_kind)
	{
		case POISONED:
			expr_poison(inner);
			return {};
		case FUNC:
			if (decl.func_decl.attr_interface_method)
			{
				return "You may not take the address of an interface method.";
			}
			if (decl.func_decl.attr_test)
			{
				return "You may not take the address of a '@test' function.";
			}
			if (decl.func_decl.attr_benchmark)
			{
				return "You may not take the address of a '@benchmark' function.";
			}
			return {};
		case VAR:
			return sema_addr_may_take_of_var(inner, decl);
		case MACRO:
			return "It is not possible to take the address of a macro.";
		case LABEL:
			return "It is not possible to take the address of a label.";
		default:
			unreachable();
	}
}

// sema_expr.c:10064 (static)
fn String sema_addr_check_may_take(Expr* inner)
{
	switch (inner.expr_kind)
	{
		case TRY_UNRESOLVED: case ACCESS_UNRESOLVED: case CATCH_UNRESOLVED: case UNRESOLVED_IDENTIFIER: case CAST:
		case TYPEID: case EMBED: case VASPLAT: case OTHER_CONTEXT: case VACOUNT: case VAARG:
		case IOTA_DECL: case LENGTHOF: case CT_IDENT: case TYPE_PROPERTY:
		case GENERIC_IDENT: case COMPOUND_LITERAL: case MACRO_BODY: case CT_SUBSCRIPT:
			unreachable();
		case IDENTIFIER:
			return sema_addr_may_take_of_ident(inner);
		case UNARY:
			if (inner.unary_expr.operator == DEREF) return {};
		case ACCESS_RESOLVED:
			Decl* decl = inner.access_resolved_expr.ref;
			switch (decl.decl_kind)
			{
				case FUNC:
					if (decl.func_decl.attr_interface_method) return {};
					return "Taking the address of a method should be done through the type e.g. '&Foo.method' not through the value.";
				case MACRO:
					return "It's not possible to take the address of a macro.";
				default:
					return sema_addr_check_may_take(inner.access_resolved_expr.parent);
			}
		case SUBSCRIPT_ADDR:
			return {};
		case SUBSCRIPT:
			return sema_addr_check_may_take(exprptr(inner.subscript_expr.expr));
		case TYPEINFO:
			return "It is not possible to take the address of a type.";
		case BITACCESS:
			return "You cannot take the address of a bitstruct member.";
		case TYPECALL:
			return "You cannot take the address of a type function.";
		case BUILTIN:
			return "You cannot take the address of a builtin function.";
		default:
			break;
	}
	return "To take the address of a temporary value, use '&&' instead of '&'.";
}

// sema_expr.c:10107 (static)
fn bool sema_expr_is_temporary(Expr* expr)
{
	switch (expr.expr_kind)
	{
		case IDENTIFIER:
		case CT_SUBSCRIPT:
			return false;
		case UNARY:
			return expr.unary_expr.operator != DEREF;
		case ACCESS_RESOLVED:
			Expr* parent = expr.access_resolved_expr.parent;
			return !type_is_pointer(type_flatten(parent.type)) && sema_expr_is_temporary(parent);
		case SUBSCRIPT:
		case SUBSCRIPT_ADDR:
			Expr* parent = exprptr(expr.subscript_expr.expr);
			return (type_is_arraylike(type_flatten(parent.type)) || parent.expr_kind == SLICE) && sema_expr_is_temporary(parent);
		case SLICE:
			Expr* parent = exprptr(expr.slice_expr.expr);
			return (type_is_arraylike(type_flatten(parent.type)) || parent.expr_kind == SLICE) && sema_expr_is_temporary(parent);
		default:
			return true;
	}
}

// sema_expr.c:10141 (static)
fn bool sema_expr_analyse_addr(SemaContext* context, Expr* expr, bool* failed_ref)
{
	Expr* inner;
	// RETRY: loop; `break` jumps to RESOLVED.
	while (true)
	{
		// 1. Evaluate the expression
		inner = expr.unary_expr.expr;
		if (inner.resolve_status == DONE) break;
		switch (inner.expr_kind)
		{
			case POISONED:
				return false;
			case OTHER_CONTEXT:
				Expr* inner_c = inner.expr_other_context.inner;
				SemaContext* c2 = inner.expr_other_context.context;
				inner.expr_other_context.is_ref = true;
				bool is_ref = true;
				expr_replace(inner, inner_c);
				if (is_ref) expr_set_to_ref(inner);
				return sema_expr_analyse_addr(c2, expr, failed_ref);
			case HASH_IDENT:
				if (!sema_expr_fold_hash(context, inner)) return false;
				continue;
			case SUBSCRIPT:
				inner.expr_kind = SUBSCRIPT_ADDR;
				if (failed_ref)
				{
					if (!sema_expr_analyse_subscript(context, inner, failed_ref)) return false;
				}
				if (!sema_analyse_expr(context, inner)) return false;
				if (inner.expr_kind == SUBSCRIPT_ADDR && sema_expr_is_temporary(inner))
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, exprptr(inner.subscript_expr.expr).loc, "To take the address of a temporary value, use '&&' instead of '&'.");
				}
				expr_replace(expr, inner);
				return true;
			case ACCESS_UNRESOLVED:
				inner.access_unresolved_expr.is_ref = true;
				inner.resolve_status = RUNNING;
				if (!sema_expr_analyse_access(context, inner, failed_ref)) return expr_poison(inner);
				inner.resolve_status = DONE;
			case CT_IDENT:
				return @sema_error_at(context, expr.loc, "It's not possible to take the address of a compile time value.");
			default:
				break;
		}

		if (!sema_analyse_expr(context, inner)) return false;
		if (expr_is_deref(inner) && inner.unary_expr.expr.expr_kind == SUBSCRIPT_ADDR && sema_expr_is_temporary(inner.unary_expr.expr))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, exprptr(inner.unary_expr.expr.subscript_expr.expr).loc, "To take the address of a temporary value, use '&&' instead of '&'.");
		}
		break;
	}

	// RESOLVED:
	if (expr_is_ct_ident(inner))
	{
		return @sema_error_at(context, expr.loc, "It's not possible to take the address of a compile time value.");
	}

	// 2. Take the address.
	String error = sema_addr_check_may_take(inner);
	if (error.ptr)
	{
		if (failed_ref)
		{
			*failed_ref = true;
			return false;
		}
		return @sema_error_at(context, inner.loc, "%s", error);
	}

	Type* no_optional = type_no_optional(inner.type).canonical;
	// 3. Get the pointer of the underlying type.
	if (no_optional.type_kind == FUNC_RAW)
	{
		expr.type = type_add_optional(type_get_func_ptr(no_optional), @is_optional(inner));
	}
	else
	{
		expr.type = type_get_ptr_recurse(inner.type);
	}
	if (inner.expr_kind == IDENTIFIER)
	{
		Decl* ident = inner.ident_expr;
		if (decl_is_global_ref(ident))
		{
			expr_rewrite_const_ref(expr, ident);
			return true;
		}
	}
	return true;
}

// sema_expr.c:10240 (static)
fn bool sema_expr_analyse_neg_plus(SemaContext* context, Expr* expr, bool* failed_ref)
{
	// 1. Check the inner expression
	Expr* inner = expr.unary_expr.expr;
	bool is_plus = expr.unary_expr.operator == PLUS;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;

	// 2. Check if it's possible to negate this (i.e. is it an int, float or vector)
	Type* no_fail = type_no_optional(inner.type);
	Type* canonical = no_fail.canonical;

	// Check for overload
	if (type_is_user_defined(canonical))
	{
		Decl* overload = sema_find_untyped_operator(canonical, OVERLOAD_UNARY_MINUS, null);
		if (overload)
		{
			// Plus just returns inner
			if (is_plus)
			{
				expr_replace(expr, inner);
				return true;
			}
			return sema_insert_method_call(context, expr, overload, inner, {}, false);
		}
	}
	if (!type_may_negate(no_fail))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		if (is_plus)
		{
			return @sema_error_at(context, expr.loc, "Cannot use '+' with an expression of type %s.", type_quoted_error_string(no_fail));
		}
		return @sema_error_at(context, expr.loc, "Cannot negate an expression of type %s.", type_quoted_error_string(no_fail));
	}
	// 3. Promote the type
	Type* result_type = cast_numeric_arithmetic_promotion(no_fail);
	if (!cast_implicit_checked(context, inner, result_type, false, failed_ref)) return false;

	// If it's a plus, we simply replace the inner with the outer or with a recast.
	if (is_plus)
	{
		if (expr_is_const(expr))
		{
			expr_replace(expr, inner);
			return true;
		}
		expr.expr_kind = RECAST;
		expr.inner_expr = inner;
		expr.type = inner.type;
		return true;
	}
	// 4. If it's non-const, we're done.
	if (!expr_const_foldable_unary(inner, NEG))
	{
		expr.type = inner.type;
		return true;
	}

	// 5. Otherwise constant fold.
	expr_replace(expr, inner);
	switch (expr.const_expr.const_kind)
	{
		case INTEGER:
			expr.const_expr.ixx = int_neg(inner.const_expr.ixx);
			return true;
		case FLOAT:
			expr.const_expr.fxx = float_neg(expr.const_expr.fxx);
		default:
			unreachable();
	}
	return true;
}

// sema_expr.c:10320 (static)
fn bool sema_expr_analyse_bit_not(SemaContext* context, Expr* expr, bool* failed_ref)
{
	// 1. Analyse the inner expression.
	Expr* inner = expr.unary_expr.expr;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;

	// 2. Check that it's a vector, bool
	Type* canonical = type_no_optional(inner.type).canonical;

	if (type_is_user_defined(canonical) && canonical.type_kind != BITSTRUCT)
	{
		Decl* overload = sema_find_untyped_operator(canonical, OVERLOAD_NEGATE, null);
		if (overload) return sema_insert_method_call(context, expr, overload, inner, {}, false);
	}

	Type* flat = type_flatten(canonical);
	bool is_bitstruct = flat.type_kind == BITSTRUCT;
	if (!type_is_integer_or_bool_kind(flat) && !is_bitstruct)
	{
		Type* vector_type = type_vector_type(canonical);
		// goto VALID_VEC
		if (!vector_type || (!type_is_integer(vector_type) && vector_type != type_bool))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, expr.loc, "Cannot bit negate '%s'.", type_to_error_string(inner.type));
		}
	}

	// VALID_VEC:
	if (is_bitstruct && sema_cast_const(inner) && expr_is_const_initializer(inner))
	{
		expr_replace(expr, inner);
		sema_invert_bitstruct_const_initializer(expr.const_expr.initializer);
		return true;
	}

	// Arithmetic promotion
	Type* result_type = cast_numeric_arithmetic_promotion(type_no_optional(inner.type));
	if (!cast_implicit_checked(context, inner, result_type, false, failed_ref)) return false;

	// 3. The simple case, non-const.
	if (!expr_const_foldable_unary(inner, BITNEG))
	{
		expr.type = inner.type;
		return true;
	}

	// 4. Otherwise handle const bool
	expr_replace(expr, inner);
	if (expr.const_expr.const_kind == BOOL)
	{
		expr.const_expr.b = !expr.const_expr.b;
		return true;
	}

	// 5. Perform ~ constant folded
	expr.const_expr.ixx = int_not(inner.const_expr.ixx);
	return true;
}

// sema_expr.c:10380 (static)
fn bool sema_expr_analyse_not(SemaContext* context, Expr* expr, bool* failed_ref)
{
	// 1. Evaluate inner
	Expr* inner = expr.unary_expr.expr;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;

	// 2. Check whether the type is a vector
	Type* type = type_no_optional(inner.type);
	Type* flat = type_flatten(type);
	if (type_kind_is_any_vector(flat.type_kind))
	{
		// This may be some form of bool vector.
		if (type_flatten(flat.array.base) == type_bool)
		{
			// If so then we're done.
			expr.type = inner.type;
			return true;
		}
		Type* canonical = type.canonical;
		switch (canonical.type_kind)
		{
			case VECTOR:
			case SIMD_VECTOR:
				expr.type = type_add_optional(type_get_vector_from_vector(type_bool, canonical), @is_optional(inner));
				return true;
			case INFERRED_VECTOR:
				unreachable();
			default:
				break;
		}
	}

	if (!cast_explicit_silent(context, inner, type_add_optional(type_bool, @is_optional(inner))))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "This expression of type %s can't be converted to a boolean value.", type_quoted_error_string(inner.type));
	}

	expr.type = type_add_optional(type_bool, @is_optional(inner));

	if (inner.expr_kind == INT_TO_BOOL)
	{
		inner.int_to_bool_expr.negate = !inner.int_to_bool_expr.negate;
		expr_replace(expr, inner);
		return true;
	}

	if (sema_cast_const(inner))
	{
		assert(expr_const_foldable_unary(inner, NOT));
		assert(inner.const_expr.const_kind == BOOL);
		bool b = !inner.const_expr.b;
		expr.const_expr.const_kind = BOOL;
		expr.expr_kind = CONST;
		expr.resolve_status = DONE;
		expr.const_expr.b = b;
		return true;
	}

	return true;
}

// sema_expr.c:10440 (static)
fn void sema_expr_inc_dec_const_enum(bool dec, Expr* value)
{
	Decl* enum_val = value.const_expr.enum_val;
	Decl*[] values = enum_val.type.decl.enums.values;
	int count = (int)values.len;
	for (int i = 0; i < count; i++)
	{
		if (values[i] == enum_val)
		{
			int next_val;
			if (dec)
			{
				next_val = (i + count - 1) % count;
			}
			else
			{
				next_val = (i + 1) % count;
			}
			value.const_expr.enum_val = values[next_val];
			return;
		}
	}
	unreachable();
}

// sema_expr.c:10465 (static)
fn void sema_expr_inc_dec_const_int(bool dec, Expr* value)
{
	if (dec)
	{
		value.const_expr.ixx = int_sub64(value.const_expr.ixx, 1);
	}
	else
	{
		value.const_expr.ixx = int_add64(value.const_expr.ixx, 1);
	}
}

// sema_expr.c:10477 (static)
fn bool sema_expr_analyse_ct_subscript_incdec(SemaContext* context, Expr* expr, Expr* inner)
{
	Decl* ct_var = inner.ct_subscript_expr.ct_var;
	Expr* init = ct_var.var_decl.init_expr;
	ArrayIndex index = inner.ct_subscript_expr.index;
	bool post = expr.expr_kind == POST_UNARY;
	bool dec = expr.unary_expr.operator == DEC;
	Expr* value = expr_from_const_expr_at_index(init, index);
	if (!expr_ok(value)) return false;
	if (post)
	{
		expr_replace(expr, copy_expr_single(value));
	}
	if (expr_is_const_int(value))
	{
		sema_expr_inc_dec_const_int(dec, value);
	}
	else if (expr_is_const_enum(value))
	{
		sema_expr_inc_dec_const_enum(dec, value);
	}
	else
	{
		return @sema_error_at(context, expr.loc, "The indexed type is not an integer or enum.");
	}
	if (!post)
	{
		expr_replace(expr, value);
	}
	sema_expr_analyse_ct_subscript_set_value(inner, ct_var, value);
	return true;
}

// sema_expr.c:10509 (static)
fn bool sema_expr_analyse_ct_incdec(SemaContext* context, Expr* expr, Expr* inner)
{
	assert(expr_is_ct_ident(inner));

	Decl* var_ = inner.ident_expr;
	Expr* start_value = var_.var_decl.init_expr;
	if (!start_value) return @sema_error_at(context, expr.loc, "The compile time variable '%s' must be assigned a starting value before it can be incremented or decremented.", var_.name);
	Expr* end_value = start_value;
	if (expr.expr_kind == POST_UNARY)
	{
		var_.var_decl.init_expr = end_value = expr_copy(start_value);
	}
	bool is_dec = expr.unary_expr.operator == DEC;
	if (expr_is_const_int(start_value))
	{
		sema_expr_inc_dec_const_int(is_dec, end_value);
	}
	else if (expr_is_const_enum(start_value))
	{
		sema_expr_inc_dec_const_enum(is_dec, end_value);
	}
	else
	{
		return @sema_error_at(context, expr.loc, "The compile time variable '%s' does not hold an integer or enum.", var_.name);
	}
	expr_replace(expr, start_value);
	return true;
}

// sema_expr.c:10538 (static)
fn bool sema_analyse_assign_mutate_overloaded_subscript(SemaContext* context, Expr* main, Expr* subscript_expr, Type* type)
{
	Expr* increased = exprptr(subscript_expr.subscript_assign_expr.expr);
	Type* type_check = type_no_optional(increased.type).canonical;
	bool is_addr = type_check.type_kind == POINTER;
	if (is_addr) type_check = type_check.pointer;
	Decl* operator = sema_find_untyped_operator(type_check, OVERLOAD_ELEMENT_REF, null);
	Expr*[] args = {};
	// The simple case: we have &[] so just replace it by that.
	if (operator)
	{
		@vec_add(&args, exprptr(subscript_expr.subscript_assign_expr.index));
		if (!sema_insert_method_call(context, subscript_expr, operator, exprptr(subscript_expr.subscript_assign_expr.expr), args, false)) return false;
		if (!sema_expr_rewrite_insert_deref(context, subscript_expr)) return false;
		main.type = subscript_expr.type;
		return true;
	}
	// We need []= and [] now.
	operator = sema_find_untyped_operator(type_check, OVERLOAD_ELEMENT_AT, null);
	if (!operator)
	{
		return @sema_error_at(context, main.loc, "There is no overload for [] for %s.", type_quoted_error_string(increased.type));
	}
	Type* return_type = typeget(operator.func_decl.signature.rtype);
	if (type_no_optional(return_type.canonical) != type.canonical)
	{
		return @sema_error_at(context, main.loc, "There is a type mismatch between overload for [] and []= for %s.", type_quoted_error_string(increased.type));
	}
	bool is_optional_result = type_is_optional(increased.type) || type_is_optional(return_type);
	Type* result_type = type_add_optional(subscript_expr.type, is_optional_result);
	if (!is_addr) expr_insert_addr(increased);
	Expr* index = exprptr(subscript_expr.subscript_assign_expr.index);
	switch (sema_resolve_storage_type(context, index.type))
	{
		case STORAGE_ERROR:
		case STORAGE_VOID:
		case STORAGE_COMPILE_TIME:
		case STORAGE_WILDCARD:
		case STORAGE_UNKNOWN:
			return @sema_error_at(context, index.loc, "You cannot index using %s.", type_invalid_storage_type_name(index.type));
		case STORAGE_NORMAL:
			break;
	}
	Decl* temp_val = decl_new_generated_var(increased.type, LOCAL, increased.loc);
	Decl* index_val = decl_new_generated_var(index.type, LOCAL, index.loc);
	Decl* value_val = decl_new_generated_var(type_add_optional(return_type, is_optional_result), LOCAL, main.loc);
	Decl* result_val = decl_new_generated_var(result_type, LOCAL, main.loc);
	Expr* decl_expr = expr_generate_decl(temp_val, increased);
	Expr* decl_index_expr = expr_generate_decl(index_val, index);
	Expr* mutate = expr_copy(main);
	mutate.resolve_status = NOT_DONE;
	mutate.type = return_type;
	switch (main.expr_kind)
	{
		case UNARY:
		case POST_UNARY:
			mutate.unary_expr.expr = expr_variable(value_val);
		case BINARY:
			mutate.binary_expr.left = exprid(expr_variable(value_val));
		default:
			unreachable();
	}
	if (!sema_analyse_expr(context, mutate)) return false;
	main.expr_kind = EXPRESSION_LIST;
	main.expression_list = {};
	// temp = indexed
	@vec_add(&main.expression_list, decl_expr);
	// temp_index = index
	@vec_add(&main.expression_list, decl_index_expr);
	Expr* get_expr = expr_new(ACCESS_RESOLVED, increased.loc);
	@vec_add(&args, expr_variable(index_val));
	Expr* temp_val_1 = expr_variable(temp_val);
	if (!sema_expr_rewrite_insert_deref(context, temp_val_1)) return false;
	if (!sema_insert_method_call(context, get_expr, operator, temp_val_1, args, false)) return false;
	Expr* value_val_expr = expr_generate_decl(value_val, get_expr);
	// temp_value = func(temp, temp_index)
	@vec_add(&main.expression_list, value_val_expr);
	// temp_result = temp_value++, temp_result *= temp_value etc
	@vec_add(&main.expression_list, expr_generate_decl(result_val, mutate));

	args = {};
	@vec_add(&args, expr_variable(index_val));
	@vec_add(&args, expr_variable(value_val));
	Expr* temp_val_2 = expr_variable(temp_val);
	if (!sema_expr_rewrite_insert_deref(context, temp_val_2)) return false;
	if (!sema_insert_method_call(context, subscript_expr, declptr(subscript_expr.subscript_assign_expr.method), temp_val_2, args, false)) return false;
	assert(subscript_expr.expr_kind == CALL);
	subscript_expr.call_expr.has_optional_arg = false;
	@vec_add(&main.expression_list, subscript_expr);
	@vec_add(&main.expression_list, expr_variable(result_val));
	return sema_expr_analyse_expr_list(context, main);
}

// sema_expr.c:10637 (static)
fn bool sema_expr_analyse_incdec(SemaContext* context, Expr* expr, bool* failed_ref)
{
	// 1. Analyse the lvalue to update
	Expr* inner = expr.unary_expr.expr;
	if (!sema_analyse_expr_lvalue(context, inner, failed_ref)) return false;

	// 2. Assert it's an l-value
	if (!sema_expr_check_assign(context, inner, failed_ref)) return false;

	// 3. This might be a $foo, if to handle it.
	if (expr_is_ct_ident(inner))
	{
		return sema_expr_analyse_ct_incdec(context, expr, inner);
	}

	if (inner.expr_kind == CT_SUBSCRIPT)
	{
		return sema_expr_analyse_ct_subscript_incdec(context, expr, inner);
	}

	// 4. Flatten typedef, enum, distinct, optional
	Type* type = type_flatten(inner.type);

	if (type.type_kind != POISONED)
	{
		// 5. We can only inc/dec numbers or pointers.
		if (type.type_kind != ENUM && !type_underlying_may_add_sub(type) && !type_kind_is_real_vector(type.type_kind))
		{
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, inner.loc, "The expression must be a vector, enum, number or a pointer.");
		}
	}

	if (inner.expr_kind == SUBSCRIPT_ASSIGN)
	{
		return sema_analyse_assign_mutate_overloaded_subscript(context, expr, inner, type);
	}

	// 6. Done, the result is same as the inner type.
	expr.type = inner.type;
	return true;
}

// sema_expr.c:10683 (static)
fn bool sema_expr_analyse_taddr(SemaContext* context, Expr* expr, bool* failed_ref)
{
	Expr* inner = expr.unary_expr.expr;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;

	Type* type = inner.type;

	switch (sema_resolve_storage_type(context, type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_NORMAL:
			break;
		default:
			if (failed_ref)
			{
				*failed_ref = true;
				return false;
			}
			return @sema_error_at(context, expr.loc, "It is not possible to take the address from a value of type %s.",
			                      type_quoted_error_string(type));
	}
	if (context.call_env.kind != ENV_FUNCTION)
	{
		if (expr_is_const_storage(inner, false)) sema_cast_const(inner);
		if (inner.expr_kind == IDENTIFIER && inner.ident_expr.decl_kind == VAR && inner.ident_expr.var_decl.kind == CONST && inner.ident_expr.var_decl.init_expr)
		{
			expr_replace(inner, copy_expr_single(inner.ident_expr.var_decl.init_expr));
		}
		// Generate global && temps.
		if (!context.call_env.in_no_eval && (sema_cast_const(inner) || (expr_is_runtime_const(inner) && !expr_may_ref(inner))))
		{
			Decl* decl = decl_new_generated_var(type, CONST, expr.loc);
			decl.var_decl.init_expr = inner;
			decl.var_decl.is_addr = true;
			decl.unit = context.compilation_unit;
			decl.visibility = LOCAL;
			decl.resolve_status = DONE;
			@vec_add(&context.compilation_unit.generated_globals, decl);
			expr_rewrite_const_ref(expr, decl);
			expr.type = type_get_ptr_recurse(type);
			return true;
		}
	}
	else if (expr_is_const_storage(inner, false))
	{
		Decl* temp = decl_new_generated_var(type, LOCAL, inner.loc);
		expr_rewrite_two(inner, expr_generate_decl(temp, expr_copy(inner)), expr_variable(temp));
		if (!sema_analyse_expr_rvalue(context, inner)) return false;
	}
	// 2. The type is the resulting type of the expression.
	expr.type = type_get_ptr_recurse(inner.type);
	return true;
}

// sema_expr.c:10738 (static)
fn bool expr_is_ungrouped_binary(Expr* expr)
{
	return expr.expr_kind == BINARY && !expr.binary_expr.grouped;
}

// sema_expr.c:10743: the static BINOP_PREC_REQ table of sema_binary_check_unclear_op_precedence.
fn int binop_prec_req(BinaryOp op) @local
{
	switch (op)
	{
		// bitwise operations
		case BIT_OR:
		case BIT_XOR:
		case BIT_AND:
			return 1;
		// comparison operations
		case GT:
		case GE:
		case LT:
		case LE:
		case NE:
		case EQ:
			return 2;
		case SHR:
		case SHL:
			return 3;
		default:
			return 0;
	}
}

// sema_expr.c:10743 (static)
fn bool sema_binary_check_unclear_op_precedence(Expr* left_side, Expr* main_expr, Expr* right_side)
{
	BinaryOp main_op = main_expr.binary_expr.operator;
	int precedence_main = binop_prec_req(main_op);
	if (expr_is_ungrouped_binary(left_side))
	{
		BinaryOp left_op = left_side.binary_expr.operator;
		int precedence_left = binop_prec_req(left_op);
		if (precedence_left && (precedence_left == precedence_main))
		{
			// ^|& has special rules
			if (precedence_left != 1 || left_op != main_op) return true;
		}
	}
	if (expr_is_ungrouped_binary(right_side))
	{
		BinaryOp right_op = right_side.binary_expr.operator;
		int precedence_right = binop_prec_req(right_op);
		if (precedence_right && (precedence_right == precedence_main))
		{
			// ^|& has special rules
			if (precedence_right != 1 || right_op != main_op) return true;
		}
	}
	return false;
}

// sema_expr.c:10789 (static)
fn bool expr_is_ungrouped_ternary(Expr* expr)
{
	return expr.expr_kind == TERNARY && !expr.ternary_expr.grouped;
}

// sema_expr.c:10794 (static)
fn bool sema_expr_analyse_or_error(SemaContext* context, Expr* expr, Expr* left, Expr* right, Type* infer_type, bool* failed_ref)
{
	bool lhs_is_embed = left.expr_kind == EMBED;
	if (expr_is_ungrouped_ternary(left) || expr_is_ungrouped_ternary(right))
	{
		return @sema_error_at(context, expr.loc, "Unclear precedence using ternary with ??, please use () to remove ambiguity.");
	}
	if (lhs_is_embed)
	{
		if (!sema_expr_analyse_embed(context, left, true)) return false;
	}
	else
	{
		if (!sema_analyse_inferred_expr(context, infer_type, left, null)) return false;
	}

	Type* type = left.type;
	if (!type_is_optional(type))
	{
		if (lhs_is_embed)
		{
			expr_replace(expr, left);
			return true;
		}
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, left.loc, "No optional to use '??' with, please remove the '??'.");
	}

	EndJump active_scope_jump = context.active_scope.end_jump;

	// First we analyse the "else" and try to implicitly cast.
	if (!sema_analyse_inferred_expr(context, infer_type, right, null)) return false;

	if (left.expr_kind == OPTIONAL)
	{
		Expr* fault_ = left.inner_expr;
		if (expr_is_pure(fault_))
		{
			expr_replace(expr, right);
			return true;
		}
		expr.expr_kind = TWO;
		expr.two_expr.first = fault_;
		expr.two_expr.last = right;
		expr.type = right.type;
		return true;
	}

	// Ignore the jump here.
	context.active_scope.end_jump = active_scope_jump;

	// Here we might need to insert casts.
	Type* else_type = right.type;

	// Remove any possible optional of the else type.
	bool add_optional = type_is_optional(else_type);
	type = type_no_optional(type);
	else_type = type_no_optional(else_type);
	Type* common = type_find_max_type(context, type, else_type, left, right);
	if (!common)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		if (else_type == type_fault)
		{
			return @sema_error_at(context, right.loc, "There is no common type for %s and %s, did you perhaps forget a '~' after the last expression?", type_quoted_error_string(type), type_quoted_error_string(else_type));
		}
		return @sema_error_at(context, right.loc, "Cannot find a common type for %s and %s.", type_quoted_error_string(type), type_quoted_error_string(else_type));
	}
	// Might have been an error.
	if (common == poisoned_type) return false;

	if (!cast_both_implicit(context, left, right, common, false, failed_ref)) return false;
	expr.type = type_add_optional(common, add_optional);
	return true;
}

// sema_expr.c:10871 (static)
fn bool sema_expr_analyse_ct_and_or(SemaContext* context, Expr* expr, Expr* left, Expr* right)
{
	assert(expr.resolve_status == RUNNING);
	bool is_and = expr.binary_expr.operator == CT_AND;
	if (!sema_analyse_expr_rvalue(context, left)) return false;
	if (!sema_cast_const(left) || !expr_is_const_bool(left)) return @sema_error_at(context, left.loc, "Expected this to evaluate to a constant boolean.");
	if (left.const_expr.b != is_and)
	{
		expr_rewrite_const_bool(expr, type_bool, !is_and);
		return true;
	}
	if (!sema_analyse_expr_rvalue(context, right)) return false;
	if (sema_cast_const(right) && expr_is_const_bool(right))
	{
		expr_rewrite_const_bool(expr, type_bool, right.const_expr.b);
		return true;
	}
	if (!cast_implicit(context, right, type_bool, false)) return false;
	expr_replace(expr, right);
	return true;
}

// sema_expr.c:10893 (static)
fn bool sema_expr_analyse_ct_concat_assign(SemaContext* context, Expr* concat_expr, Expr* left, Expr* right, bool* failed_ref)
{
	assert(concat_expr.resolve_status == RUNNING);
	Expr* left_copy = copy_expr_single(left);
	if (!sema_analyse_expr_lvalue(context, left_copy, null)) return false;
	if (!sema_analyse_expr_rvalue(context, left)) return false;
	if (!sema_analyse_inferred_expr(context, left.type, right, failed_ref)) return false;
	if (!sema_expr_analyse_ct_concat(context, concat_expr, left, right, failed_ref)) return false;
	Expr* result_copy = copy_expr_single(concat_expr);
	concat_expr.binary_expr.left = exprid(left_copy);
	concat_expr.binary_expr.right = exprid(result_copy);
	concat_expr.resolve_status = NOT_DONE;
	concat_expr.binary_expr.operator = ASSIGN;
	concat_expr.expr_kind = BINARY;
	concat_expr.resolve_status = RUNNING;
	return sema_expr_analyse_binary(context, null, concat_expr, failed_ref);
}

// sema_expr.c:10911 (static)
fn bool sema_expr_analyse_binary(SemaContext* context, Type* infer_type, Expr* expr, bool* failed_ref)
{
	assert(expr.resolve_status == RUNNING);
	Expr* left = exprptr(expr.binary_expr.left);
	Expr* right = exprptr(expr.binary_expr.right);
	// check if both sides have a binary operation where the precedence is unclear. Example: a ^ b | c
	if (sema_binary_check_unclear_op_precedence(left, expr, right))
	{
		return @sema_error_at(context, expr.loc, "You need to add explicit parentheses to clarify precedence.");
	}
	BinaryOp operator = expr.binary_expr.operator;
	if (operator == CT_CONCAT_ASSIGN)
	{
		return sema_expr_analyse_ct_concat_assign(context, expr, left, right, failed_ref);
	}
	if (operator >= ASSIGN)
	{
		if (left.expr_kind != TYPEINFO)
		{
			if (!sema_analyse_expr_lvalue(context, left, failed_ref)) return false;
		}
	}
	else
	{
		if (operator == ELSE) return sema_expr_analyse_or_error(context, expr, left, right, infer_type, failed_ref);
		if (!sema_binary_analyse_with_inference(context, left, right, operator, infer_type)) return false;
	}
	switch (operator)
	{
		case ELSE:
			unreachable();
		case CT_CONCAT:
			return sema_expr_analyse_ct_concat(context, expr, left, right, failed_ref);
		case CT_CONCAT_ASSIGN:
			unreachable();
		case CT_OR:
		case CT_AND:
			return sema_expr_analyse_ct_and_or(context, expr, left, right);
		case ASSIGN:
			return sema_expr_analyse_assign(context, expr, left, right, failed_ref);
		case MULT:
			return sema_expr_analyse_mult(context, expr, left, right, failed_ref);
		case ADD:
			return sema_expr_analyse_add(context, expr, left, right, failed_ref);
		case SUB:
			return sema_expr_analyse_sub(context, expr, left, right, failed_ref);
		case DIV:
			return sema_expr_analyse_div(context, expr, left, right, failed_ref);
		case MOD:
			return sema_expr_analyse_mod(context, expr, left, right, failed_ref);
		case AND:
		case OR:
			return sema_expr_analyse_and_or(context, expr, left, right, failed_ref);
		case BIT_OR:
			return sema_expr_analyse_bit(context, expr, left, right, OVERLOAD_OR, failed_ref);
		case BIT_XOR:
			return sema_expr_analyse_bit(context, expr, left, right, OVERLOAD_XOR, failed_ref);
		case BIT_AND:
			return sema_expr_analyse_bit(context, expr, left, right, OVERLOAD_AND, failed_ref);
		case VEC_NE:
		case VEC_EQ:
		case VEC_GT:
		case VEC_GE:
		case VEC_LT:
		case VEC_LE:
			unreachable();
		case NE:
		case EQ:
		case GT:
		case GE:
		case LT:
		case LE:
			return sema_expr_analyse_comp(context, expr, left, right, failed_ref);
		case SHR:
		case SHL:
			return sema_expr_analyse_shift(context, expr, left, right, failed_ref);
		case ADD_ASSIGN:
		case SUB_ASSIGN:
		case BIT_AND_ASSIGN:
		case BIT_OR_ASSIGN:
		case BIT_XOR_ASSIGN:
		case MOD_ASSIGN:
		case MULT_ASSIGN:
		case DIV_ASSIGN:
		case SHR_ASSIGN:
		case SHL_ASSIGN:
			return sema_expr_analyse_op_assign(context, expr, left, right, operator, failed_ref);
		case ERROR:
			break;
	}
	unreachable();
}

// sema_expr.c:11014 (static)
fn bool sema_expr_analyse_unary(SemaContext* context, Expr* expr, bool* failed_ref)
{
	if (failed_ref) *failed_ref = false;
	assert(expr.resolve_status == RUNNING);
	switch (expr.unary_expr.operator)
	{
		case DEREF:
			return sema_expr_analyse_deref(context, expr, failed_ref);
		case ADDR:
			return sema_expr_analyse_addr(context, expr, failed_ref);
		case NEG:
		case PLUS:
			return sema_expr_analyse_neg_plus(context, expr, failed_ref);
		case BITNEG:
			return sema_expr_analyse_bit_not(context, expr, failed_ref);
		case NOT:
			return sema_expr_analyse_not(context, expr, failed_ref);
		case DEC:
		case INC:
			return sema_expr_analyse_incdec(context, expr, failed_ref);
		case TADDR:
			return sema_expr_analyse_taddr(context, expr, failed_ref);
		case ERROR:
			return false;
	}
}

// sema_expr.c:11043 (static)
fn bool sema_expr_analyse_rethrow(SemaContext* context, Expr* expr, Type* to)
{
	if (context.call_env.kind != ENV_FUNCTION)
	{
		if (context.call_env.kind == ENV_FUNCTION_STATIC)
		{
			return @sema_error_at(context, expr.loc, "Rethrow cannot be used for a static initializer.");
		}
		return @sema_error_at(context, expr.loc, "Rethrow cannot be used outside of a function.");
	}
	if (!context.current_macro && (context.active_scope.flags & (SCOPE_MACRO | SCOPE_ENSURE | SCOPE_ENSURE_MACRO)) && !(context.active_scope.flags & SCOPE_COMPARISON))
	{
		return @sema_error_at(context, expr.loc, "Rethrows using '!' is not allowed in contracts.");
	}
	Expr* inner = expr.rethrow_expr.inner;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;

	if (context.active_scope.in_defer) return @sema_error_at(context, expr.loc, "Rethrows are not allowed inside of defers.");

	expr.type = type_no_optional(inner.type);

	if (!@is_optional(inner))
	{
		return @sema_error_at(context, expr.loc, "No optional to rethrow before '!' in the expression, please remove '!'.");
	}

	if (context.active_scope.flags & SCOPE_MACRO)
	{
		if (!(context.active_scope.flags & SCOPE_COMPARISON))
		{
			TypeInfoId rtype = context.current_macro.func_decl.signature.rtype;
			if (rtype && !type_is_optional(typeget(rtype)))
			{
				return @sema_error_at(context, expr.loc, "Rethrow is only allowed in macros with an optional or inferred return type. "
				                                         "Did you mean to use '!!' instead?");
			}
		}
		@vec_add(&context.block_returns, null);
		expr.rethrow_expr.in_block = context.block_exit_ref;
		expr.rethrow_expr.cleanup = context_get_defers(context, context.block_return_defer, false);
	}
	else
	{
		expr.rethrow_expr.cleanup = context_get_defers(context, 0, false);
		expr.rethrow_expr.in_block = null;
		if (context.rtype && context.rtype.type_kind != OPTIONAL)
		{
			// Sometimes people write "int? foo = bar()!;" which is likely a mistake.
			if (to && type_is_optional(to))
			{
				return @sema_error_at(context, expr.loc, "This expression is doing a rethrow, "
				                                         "but '%s' returns %s, which isn't an optional type. Since you are assigning to "
				                                         "an optional, maybe you added '!' by mistake?",
				                      context.call_env.current_function.name,
				                      type_quoted_error_string(context.rtype));
			}
			return @sema_error_at(context, expr.loc, "This expression is doing a rethrow, "
			                                         "but '%s' returns %s, which isn't an optional type. Did you intend to use '!!' instead?",
			                      context.call_env.current_function.name,
			                      type_quoted_error_string(context.rtype));
		}
		if (context.call_env.is_naked_fn)
		{
			return @sema_error_at(context, expr.loc, "Rethrow is not allowed in a '@naked' function.");
		}
	}
	if (inner.expr_kind == OPTIONAL && !context.call_env.in_no_eval)
	{
		set_jump_end(context, expr.loc);
	}

	return true;
}

// sema_expr.c:11119 (static)
fn bool sema_expr_analyse_force_unwrap(SemaContext* context, Expr* expr)
{
	Expr* inner = expr.inner_expr;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;
	if (!@is_optional(inner))
	{
		return @sema_error_at(context, expr.loc, "No optional to rethrow before '!!' in the expression, please remove '!!'.");
	}
	expr.type = type_no_optional(inner.type);
	if (expr.inner_expr.expr_kind == OPTIONAL && !context.call_env.in_no_eval)
	{
		set_jump_end(context, expr.loc);
	}
	return true;
}

// sema_expr.c:11135 (static)
fn bool sema_expr_analyse_typeid(SemaContext* context, Expr* expr)
{
	if (!sema_resolve_type_info(context, expr.typeid_expr, RESOLVE_TYPE_DEFAULT)) return expr_poison(expr);
	Type* type = expr.type_expr.type;
	switch (type.type_kind)
	{
		case TYPEINFO:
		case INFERRED_ARRAY:
		case INFERRED_VECTOR:
		case POISONED:
		case MEMBER:
		case WILDCARD:
		case REFLECTION:
			return @sema_error_at(context, expr.typeid_expr.loc, "Cannot get typeid of %s: this type exists only at compile time. Only runtime types have a typeid.", type_quoted_error_string(type));
		default:
			break;
	}
	expr.expr_kind = CONST;
	expr.resolve_status = DONE;
	expr.const_expr.const_kind = TYPEID;
	expr.const_expr.typeid_type = type.canonical;
	expr.type = type_typeid;
	return true;
}

// sema_expr.c:11154 (static)
fn bool sema_expr_analyse_optional(SemaContext* context, Expr* expr, bool* failed_ref)
{
	Expr* inner = expr.inner_expr;
	if (failed_ref) *failed_ref = false;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;

	if (@is_optional(inner))
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, inner.loc, "The inner expression is already an optional.");
	}

	if (inner.expr_kind == OPTIONAL)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, inner.loc, "It looks like you added one too many '~' after the error.");
	}

	Type* type = inner.type.canonical;

	if (type != type_fault)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, inner.loc, "You cannot use the '~' operator on expressions of type %s",
		                      type_quoted_error_string(type));
	}
	assert(type.type_kind == ANYFAULT || type.decl.resolve_status == DONE);
	expr.type = type_wildcard_optional;
	return true;
}

// sema_expr.c:11188 (static)
fn bool sema_expr_analyse_compiler_const(SemaContext* context, Expr* expr, bool report_missing)
{
	String string = expr.builtin_expr.ident;
	BuiltinDefine def = DEF_NONE;
	for (int i = 0; i < NUMBER_OF_BUILTIN_DEFINES.ordinal; i++)
	{
		if (string.ptr == builtin_defines[i].ptr)
		{
			def = BuiltinDefine::values[i];
			break;
		}
	}
	switch (def)
	{
		case DEF_TIME:
			expr_rewrite_const_string_from_raw(expr, time_get());
			return true;
		case DEF_DATE:
			expr_rewrite_const_string_from_raw(expr, date_get());
			return true;
		case DEF_FILE:
			if (context.call_env.current_function)
			{
				expr_rewrite_const_string_from_raw(expr, context.call_env.current_function.unit.file.name);
				return true;
			}
			expr_rewrite_const_string_from_raw(expr, context.compilation_unit.file.name);
			return true;
		case DEF_FILEPATH:
			if (context.call_env.current_function)
			{
				expr_rewrite_const_string_from_raw(expr, context.call_env.current_function.unit.file.full_path);
				return true;
			}
			expr_rewrite_const_string_from_raw(expr, context.compilation_unit.file.full_path);
			return true;
		case DEF_MODULE:
			if (context.original_module)
			{
				expr_rewrite_const_string_from_raw(expr, context.original_module.name.module_name);
			}
			else
			{
				expr_rewrite_const_string_from_raw(expr, context.compilation_unit.mod.name.module_name);
			}
			return true;
		case DEF_LINE:
		{
			InliningSpan* span = context.inlined_at;
			if (span)
			{
				while (span.prev) span = span.prev;
				expr_rewrite_const_int(expr, type_sz, sourcelocptr(span.loc).row);
			}
			else
			{
				expr_rewrite_const_int(expr, type_sz, sourcelocptr(expr.loc).row);
			}
			return true;
		}
		case DEF_LINE_RAW:
			expr_rewrite_const_int(expr, type_sz, sourcelocptr(expr.loc).row);
			return true;
		case DEF_FUNCTION:
			switch (context.call_env.kind)
			{
				case ENV_GLOBAL_INIT:
				case ENV_ATTR:
					if (report_missing)
					{
						@sema_error_at(context, expr.loc, "$$FUNCEXPR is not defined outside of a function.");
					}
					return false;
				case ENV_FUNCTION:
				case ENV_FUNCTION_STATIC:
					expr.expr_kind = IDENTIFIER;
					expr_resolve_ident(expr, context.call_env.current_function);
					return true;
			}
			unreachable();
		case DEF_FUNC:
			switch (context.call_env.kind)
			{
				case ENV_GLOBAL_INIT:
					expr_rewrite_const_string_from_raw(expr, "<GLOBAL>");
					return true;
				case ENV_FUNCTION_STATIC:
				case ENV_FUNCTION:
				{
					Decl* current_func = context.call_env.current_function;
					TypeInfo* func_type = decl_find_target_if_method(current_func);
					if (func_type)
					{
						scratch_buffer_clear();
						scratch_buffer_append(func_type.type.name);
						scratch_buffer_append_char('.');
						scratch_buffer_append(current_func.name);
						expr_rewrite_const_string_from_scratch(expr);
						return true;
					}
					expr_rewrite_const_string_from_raw(expr, current_func.name);
					return true;
				}
				case ENV_ATTR:
					expr_rewrite_const_string_from_raw(expr, "<attribute>");
					return true;
			}
			unreachable();
		case DEF_NONE:
		{
			Expr* value = htable_get(&compiler.context.compiler_defines, (void*)string.ptr);
			if (!value)
			{
				if (report_missing)
				{
					@sema_error_at(context, expr.loc, "The compiler constant '%s' was not defined, did you mistype or forget to add it?", string);
				}
				return false;
			}
			expr_replace(expr, value);
			return true;
		}
		case DEF_PANIC_FN:
		{
			Decl* panic_fn = sema_panic_fn(context);
			if (!panic_fn)
			{
				if (compiler.context.errors_found) return false;
				expr_rewrite_const_null(expr, type_voidptr);
				return true;
			}
			expr_rewrite_const_ref(expr, panic_fn);
			expr.type = type_get_func_ptr(panic_fn.type);
			return true;
		}
		case DEF_BENCHMARK_NAMES:
			if (!compiler.build.build_benchmark)
			{
				expr_rewrite_const_empty_slice(expr, type_get_slice(type_string));
				return true;
			}
			expr.type = type_get_slice(type_string);
			expr.benchmark_hook_expr = DEF_BENCHMARK_NAMES;
			expr.expr_kind = BENCHMARK_HOOK;
			return true;
		case DEF_BENCHMARK_FNS:
			if (!compiler.build.build_benchmark)
			{
				expr_rewrite_const_empty_slice(expr, type_get_slice(type_voidptr));
				return true;
			}
			expr.type = type_get_slice(type_voidptr);
			expr.benchmark_hook_expr = DEF_BENCHMARK_FNS;
			expr.expr_kind = BENCHMARK_HOOK;
			return true;
		case DEF_TEST_NAMES:
			if (!compiler.build.build_test)
			{
				expr_rewrite_const_empty_slice(expr, type_get_slice(type_string));
				return true;
			}
			expr.type = type_get_slice(type_string);
			expr.test_hook_expr = DEF_TEST_NAMES;
			expr.expr_kind = TEST_HOOK;
			return true;
		case DEF_TEST_FNS:
			if (!compiler.build.build_test)
			{
				expr_rewrite_const_empty_slice(expr, type_get_slice(type_voidptr));
				return true;
			}
			expr.type = type_get_slice(type_voidptr);
			expr.test_hook_expr = DEF_TEST_FNS;
			expr.expr_kind = TEST_HOOK;
			return true;
	}
	unreachable();
}

// sema_expr.c:11369 (static)
fn bool sema_expr_rewrite_to_type_nameof(SemaContext* context, Expr* expr, Type* type, int level)
{
	if (type_is_func_ptr(type))
	{
		if (!sema_resolve_type_decl(context, type)) return false;
		type = type.pointer.function.prototype.raw_type;
	}

	if (level == 2)
	{
		if (!sema_resolve_type_decl(context, type)) return false;
		if (type_is_user_defined(type))
		{
			scratch_buffer_set_extern_decl_name(type.decl, true);
			expr_rewrite_const_string_from_scratch(expr);
		}
		else
		{
			expr_rewrite_const_string_from_raw(expr, type.name);
		}
		return true;
	}

	if (!level || type_is_builtin(type.type_kind))
	{
		expr_rewrite_const_string_from_raw(expr, type.name);
		return true;
	}
	scratch_buffer_clear();

	Module* mod = type_base_module(type);
	if (mod)
	{
		scratch_buffer_append(mod.name.module_name);
		scratch_buffer_append("::");
	}
	scratch_buffer_append(type.name);
	expr_rewrite_const_string_from_scratch(expr);
	return true;
}

// sema_expr.c:11411 (static)
fn Type* sema_expr_check_type_exists(SemaContext* context, TypeInfo* type_info)
{
	if (type_info.resolve_status == DONE)
	{
		return type_info.type;
	}
	switch (type_info.kind)
	{
		case INFO_POISON:
			return poisoned_type;
		case INFO_GENERIC:
		{
			TypeInfo* base = type_info.generic.base;
			if (base.kind == INFO_IDENTIFIER && base.resolve_status != DONE)
			{
				if (!sema_parameterized_type_is_found(context, base.unresolved.path, base.unresolved.name, type_info.loc)) return null;
			}
			if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return poisoned_type;
			return type_info.type;
		}
		case INFO_VECTOR:
		{
			ArrayIndex size;
			if (!sema_resolve_array_like_len(context, type_info, &size)) return poisoned_type;
			Type* type = sema_expr_check_type_exists(context, type_info.array.base);
			if (!type) return null;
			if (!type_ok(type)) return type;
			if (!type_is_valid_for_vector(type))
			{
				@sema_error_at(context, type_info.array.base.loc,
						   "%s is not of a vectorizable type.",
						   type_quoted_error_string(type));
				return poisoned_type;
			}
			// Vectors are limited in length so casting to int is safe.
			return type_get_vector(type, type_info.is_simd ? TypeKind.SIMD_VECTOR : TypeKind.VECTOR, (int)size);
		}
		case INFO_ARRAY:
		{
			ArrayIndex size;
			if (!sema_resolve_array_like_len(context, type_info, &size)) return poisoned_type;
			Type* type = sema_expr_check_type_exists(context, type_info.array.base);
			if (!type) return null;
			if (!type_ok(type)) return type;
			if (!type_is_valid_for_array(type))
			{
				@sema_error_at(context, type_info.array.base.loc,
						   "You cannot form an array with elements of type %s.",
						   type_quoted_error_string(type));
				return poisoned_type;
			}
			return type_get_array(type, size);
		}
		case INFO_CT_IDENTIFIER:
		case INFO_IDENTIFIER:
		{
			Decl* decl = sema_find_path_symbol(context, type_info.unresolved.name, type_info.unresolved.path);
			if (!decl) return null;
			if (!decl_ok(decl)) return poisoned_type;
			if (type_info.kind == INFO_CT_IDENTIFIER)
			{
				Expr* init = decl.var_decl.init_expr;
				if (decl.var_decl.defaulted && !init) return null;
				if (init.expr_kind == CONST)
				{
					assert(init.const_expr.const_kind == TYPEID);
					return init.const_expr.typeid_type;
				}
				assert(init.expr_kind == TYPEINFO);
				return init.type_expr.type.canonical;
			}
			return decl.type.canonical;
		}
		case INFO_TYPEFROM:
		{
			Expr* expr = type_info.unresolved_type_expr;
			if (!sema_analyse_expr_rvalue(context, expr)) return poisoned_type;
			if (sema_cast_const(expr) && expr_is_const_string(expr))
			{
				TypeInfo* info = sema_type_info_from_string(context, expr, false);
				if (!info) return null;
				if (!type_info_ok(info)) return poisoned_type;
				Type* type = sema_expr_check_type_exists(context, info);
				if (!type || !type_ok(type)) return type;
			}
			if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return poisoned_type;
			return type_info.type;
		}
		case INFO_TYPEOF:
			if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return poisoned_type;
			return type_info.type;
		case INFO_SLICE:
		{
			// If it's an array, make sure we can resolve the length
			Type* type = sema_expr_check_type_exists(context, type_info.array.base);
			if (!type) return null;
			if (!type_ok(type)) return type;
			if (!type_is_valid_for_array(type))
			{
				@sema_error_at(context, type_info.array.base.loc,
						   "You cannot form a slice with elements of type %s.",
						   type_quoted_error_string(type));
				return poisoned_type;
			}
			return type_get_slice(type);
		}
		case INFO_INFERRED_ARRAY:
		{
			// If it's an array, make sure we can resolve the length
			Type* type = sema_expr_check_type_exists(context, type_info.array.base);
			if (!type) return null;
			if (!type_ok(type)) return type;
			if (!type_is_valid_for_array(type))
			{
				@sema_error_at(context, type_info.array.base.loc,
						   "You cannot form an array with elements of type %s.",
						   type_quoted_error_string(type));
				return poisoned_type;
			}
			return type_get_inferred_array(type);
		}
		case INFO_INFERRED_VECTOR:
		{
			// If it's a vector, make sure we can resolve the length
			Type* type = sema_expr_check_type_exists(context, type_info.array.base);
			if (!type) return null;
			if (!type_ok(type)) return type;
			if (!type_is_valid_for_vector(type))
			{
				@sema_error_at(context, type_info.array.base.loc,
						   "%s is not of a vectorizable type.",
						   type_quoted_error_string(type));
				return poisoned_type;
			}
			return type_get_inferred_vector(type);
		}
		case INFO_POINTER:
		{
			// If it's an array, make sure we can resolve the length
			Type* type = sema_expr_check_type_exists(context, type_info.array.base);
			if (!type) return null;
			if (!type_ok(type)) return type;
			return type_get_ptr(type);
		}
	}
	unreachable();
}

// sema_expr.c:11560 (static)
fn bool sema_may_reuse_lambda(Decl* lambda, Type*[] types)
{
	Signature* sig = &lambda.func_decl.signature;
	if (typeget(sig.rtype).canonical != types[0]) return false;
	foreach (i, param : sig.params)
	{
		TypeInfo* info = vartype(param);
		assert(info && types[i + 1]);
		if (info.type.canonical != types[i + 1]) return false;
	}
	return true;
}

// sema_expr.c:11573 (static)
fn Type* sema_evaluate_type_copy(SemaContext* context, TypeInfo* type_info)
{
	if (type_info.resolve_status == DONE) return type_info.type;
	type_info = copy_type_info_single(type_info);
	if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return null;
	return type_info.type;
}

// sema_expr.c:11581 (static)
fn bool lambda_parameter_match(Decl*[] ct_lambda_params, Decl* candidate)
{
	usz param_count = ct_lambda_params.len;
	if (candidate.func_decl.lambda_ct_parameters.len != param_count) return false;
	foreach (i, param : candidate.func_decl.lambda_ct_parameters)
	{
		Decl* ct_param = ct_lambda_params[i];
		if (param.name.ptr != ct_param.name.ptr) return false;
		if (!param.var_decl.is_read) continue;
		assert(ct_param.resolve_status == DONE || param.resolve_status == DONE);
		assert(ct_param.var_decl.kind == param.var_decl.kind);
		if ((ct_param.var_decl.init_expr == null) != (param.var_decl.init_expr == null)) return false;
		if (!param.var_decl.init_expr) continue;
		switch (ct_param.var_decl.kind)
		{
			case LOCAL_CT_TYPE:
			case PARAM_CT_TYPE:
				if (ct_param.var_decl.init_expr.const_expr.typeid_type.canonical !=
					param.var_decl.init_expr.const_expr.typeid_type.canonical)
				{
					return false;
				}
			case LOCAL_CT:
			case PARAM_CT:
				if (!expr_is_const(ct_param.var_decl.init_expr)) return false;
				if (!expr_is_const(param.var_decl.init_expr)) return false;
				if (type_no_optional(ct_param.var_decl.init_expr.type).canonical
					!= type_no_optional(param.var_decl.init_expr.type).canonical) return false;
				if (!expr_both_const_foldable(ct_param.var_decl.init_expr, param.var_decl.init_expr, BinaryOp.EQ)) return false;
				if (!expr_const_compare(&ct_param.var_decl.init_expr.const_expr,
										&param.var_decl.init_expr.const_expr, BinaryOp.EQ)) return false;
			default:
				unreachable();
		}
	}
	return true;
}

// sema_expr.c:11621 (static)
fn Decl* sema_find_cached_lambda(SemaContext* context, Type* func_type, Decl* original, Decl*[] ct_lambda_parameters)
{
	usz cached = original.func_decl.generated_lambda.len;
	if (!cached) return null;
	// If it has a function type, then we just use that for comparison.
	if (func_type)
	{
		Type* raw = func_type.canonical.pointer.function.prototype.raw_type;
		foreach (candidate : original.func_decl.generated_lambda)
		{
			if (raw == candidate.type.function.prototype.raw_type &&
				lambda_parameter_match(ct_lambda_parameters, candidate))
			{
				return candidate;
			}
		}
		return null;
	}
	Signature* sig = &original.func_decl.signature;
	if (!sig.rtype) return null;
	Type* rtype = sema_evaluate_type_copy(context, type_infoptr(sig.rtype));
	if (!rtype) return null;
	Type*[200] types;
	types[0] = rtype;
	foreach (i, param : sig.params)
	{
		TypeInfo* info = vartype(param);
		if (!info) return null;
		Type* type = sema_evaluate_type_copy(context, info);
		if (!type) return null;
		assert(i < 198);
		types[i + 1] = type;
	}

	foreach (candidate : original.func_decl.generated_lambda)
	{
		if (sema_may_reuse_lambda(candidate, &types) &&
			lambda_parameter_match(ct_lambda_parameters, candidate))
		{
			return candidate;
		}
	}
	return null;
}

// sema_expr.c:11667 (static)
fn bool sema_expr_analyse_embed(SemaContext* context, Expr* expr, bool allow_fail)
{
	Expr* filename = expr.embed_expr.filename;
	if (!sema_analyse_ct_expr(context, filename)) return false;
	Expr* len_expr = expr.embed_expr.len;
	usz len = ~(usz)0;
	if (len_expr)
	{
		if (!sema_analyse_ct_expr(context, len_expr)) return false;
		if (!expr_is_const_int(len_expr)) return @sema_error_at(context, len_expr.loc, "Expected an integer value.");
		Int i = len_expr.const_expr.ixx;
		if (int_is_neg(i) || int_is_zero(i)) return @sema_error_at(context, len_expr.loc, "Expected a positive value for the limit.");
		Int max = { .i = (uint128)len, .type = U64 };
		if (int_comp(i, max, BinaryOp.LT))
		{
			len = (usz)int_to_u64(i);
		}
	}
	if (!expr_is_const_string(filename)) return @sema_error_at(context, filename.loc, "A compile time string was expected.");
	if (!filename.const_expr.bytes.len) return @sema_error_at(context, filename.loc, "Expected a non-empty string.");
	CompilationUnit* unit = context.unit;
	String string = (String)filename.const_expr.bytes.ptr[:filename.const_expr.bytes.len];
	String path;
	String name;
	if (file_path_is_relative(string) && file_namesplit(unit.file.full_path, &name, &path))
	{
		string = file_append_path(path, string);
	}
	char* content = file_read_binary(string, &len);
	if (!content)
	{
		if (!allow_fail) return @sema_error_at(context, expr.loc, "Failed to load '%s'.", string);
		if (!compiler.context.io_error_file_not_found)
		{
			Module* mod = global_context_find_module(kw_std__io);
			Decl* io_error = mod ? module_find_symbol(mod, kw_FILE_NOT_FOUND) : null;
			Decl* fault_ = poisoned_decl;
			if (io_error && io_error.decl_kind == FAULT)
			{
				fault_ = io_error;
			}
			compiler.context.io_error_file_not_found = fault_;
		}
		if (!decl_ok(compiler.context.io_error_file_not_found))
		{
			return @sema_error_at(context, expr.loc, "Cannot generate an optional result, no IoError.FILE_NOT_FOUND could be located.");
		}
		expr.expr_kind = OPTIONAL;
		expr.inner_expr = filename;
		filename.expr_kind = CONST;
		filename.const_expr.const_kind = FAULT;
		filename.type = type_fault;
		expr.type = type_wildcard_optional;
		filename.const_expr.fault_val = compiler.context.io_error_file_not_found;
		filename.resolve_status = DONE;
		expr.resolve_status = DONE;
		return true;
	}
	expr.const_expr = {
			.const_kind = BYTES,
			.bytes = { .ptr = content, .len = (ArrayIndex)len },
	};
	expr.expr_kind = CONST;
	expr.resolve_status = DONE;
	expr.type = type_get_slice(type_char);
	return true;
}

// sema_expr.c:11736 (static)
fn bool sema_expr_analyse_generic_ident(SemaContext* context, Expr* expr)
{
	Expr* parent = exprptr(expr.generic_ident_expr.parent);
	if (parent.expr_kind != UNRESOLVED_IDENTIFIER)
	{
		return @sema_error_at(context, parent.loc, "Expected an identifier to parameterize.");
	}
	if (compiler.generic_depth >= MAX_GENERIC_DEPTH)
	{
		return @sema_error_at(context, parent.loc, "Generic resolution of this identifier has become deeply nested, it was aborted after reaching %d recursions.", compiler.generic_depth);
	}
	compiler.generic_depth++;
	Decl* symbol = sema_analyse_parameterized_identifier(context, parent.unresolved_ident_expr.path,
	                                                     parent.unresolved_ident_expr.ident, parent.loc,
	                                                     expr.generic_ident_expr.parameters, expr.loc);
	compiler.generic_depth--;
	if (!sema_analyse_decl(context, symbol)) return false;
	if (decl_needs_prefix(symbol) && symbol.unit.mod != context.unit.mod && !parent.unresolved_ident_expr.path)
	{
		String message;
		switch (symbol.decl_kind)
		{
			case VAR:
				message = "Globals";
			case FUNC:
				message = "Functions";
			case MACRO:
				message = "Macros";
			case ALIAS:
				message = "Aliases";
			case FAULT:
				message = "Faults";
			default:
				unreachable();
		}
		return @sema_error_at(context, expr.loc, "%s from other modules must be prefixed with the module name, please use %s::%s(...) instead.", message, symbol.unit.mod.short_path, symbol.name);
	}
	expr_resolve_ident(expr, symbol);
	return true;
}

// sema_expr.c:11782 (static)
fn bool sema_expr_analyse_lambda(SemaContext* context, Type* target_type, Expr* expr)
{
	Decl* decl = expr.lambda_expr;
	if (!decl_ok(decl)) return false;
	// c3c: assert(decl->resolve_status != RESOLVE_DONE); -- a C assert, compiled out
	// in c3c release builds; a lambda in a re-expanded macro body arrives resolved
	// and is deep-copied below when `multiple`.
	Type* flat = target_type ? type_flatten(target_type) : null;
	if (flat)
	{
		if (!type_is_func_ptr(flat))
		{
			return @sema_error_at(context, expr.loc, "Can't convert a lambda to %s.", type_quoted_error_string(target_type));
		}
		if (!sema_resolve_type_decl(context, flat.pointer)) return false;
	}

	// c3c tests the vector pointer (non-null once acquired), not its size.
	bool multiple = context.current_macro || context.ct_locals.ptr;

	// Capture CT variables
	Decl*[] ct_lambda_parameters = copy_decl_list_single(context.ct_locals);

	if (multiple && decl.resolve_status != DONE)
	{
		Decl* decl_cached = sema_find_cached_lambda(context, flat, decl, ct_lambda_parameters);
		if (decl_cached)
		{
			if (!decl_ok(decl_cached)) return false;
			expr.type = type_get_func_ptr(decl_cached.type);
			expr_rewrite_const_ref(expr, decl_cached);
			return true;
		}
	}
	Decl* original = decl;
	if (multiple) decl = expr.lambda_expr = copy_lambda_deep(decl);
	Signature* sig = &decl.func_decl.signature;
	Signature* to_sig = flat ? flat.canonical.pointer.function.signature : null;
	if (sig.variadic == RAW)
	{
		if (to_sig)
		{
			if (to_sig.variadic == RAW)
			{
				return @sema_error_at(context, decl.loc, "A lambda may not use C-style vaargs. Consequently it can never implement the %s function type.", type_quoted_error_string(flat));
			}
			return @sema_error_at(context, expr.loc, "The lambda doesn't match the required type %s.", type_quoted_error_string(target_type));
		}
		return @sema_error_at(context, decl.loc, "A lambda may not use C-style vaargs.");
	}
	if (!sig.rtype)
	{
		if (!to_sig) return @sema_error_at(context, expr.loc, "Inferred lambda expressions cannot be used unless the type can be determined.");
		sig.rtype = type_info_id_new_base(typeget(to_sig.rtype), expr.loc);
	}
	if (to_sig && to_sig.params.len != sig.params.len)
	{
		return @sema_error_at(context, expr.loc, "The lambda doesn't match the required type %s.", type_quoted_error_string(target_type));
	}
	foreach (i, param : sig.params)
	{
		if (param.var_decl.type_info) continue;
		if (!to_sig) return @sema_error_at(context, expr.loc, "Inferred lambda expressions cannot be used unless the type can be determined.");
		param.var_decl.type_info = type_info_id_new_base(to_sig.params[i].type, param.loc);
	}
	CompilationUnit* unit = decl.unit = context.unit;
	assert(!decl.name.len); // c3c ASSERT_SPAN (always on)
	scratch_buffer_clear();
	scratch_buffer_append_module(unit.mod, false);
	scratch_buffer_append(".");
	switch (context.call_env.kind)
	{
		case ENV_GLOBAL_INIT:
			scratch_buffer_append("$global");
		case ENV_FUNCTION:
		case ENV_FUNCTION_STATIC:
			if (context.current_macro)
			{
				if (context.current_macro.name[0] == '@')
				{
					scratch_buffer_append_char('$');
					scratch_buffer_append(context.current_macro.name[1..]);
				}
				else
				{
					scratch_buffer_append(context.current_macro.name);
				}
			}
			else
			{
				scratch_buffer_append(context.call_env.current_function.name);
			}
		case ENV_ATTR:
			scratch_buffer_append("$attr");
	}
	scratch_buffer_append("$lambda");
	scratch_buffer_append_unsigned_int((ulong)++unit.mod.lambda_count);
	decl.name = scratch_buffer_copy();
	decl.extname = decl.name;
	decl.type = type_new_func(decl, sig);
	bool erase_decl = false;
	if (!sema_analyse_func_macro(context, decl, ATTR_FUNC, &erase_decl)) return false;
	if (erase_decl)
	{
		return @sema_error_at(context, decl.loc, "`@if` can't be placed on a lambda.");
	}
	if (!sema_analyse_function_signature(context, decl, null, sig.abi, sig)) return false;
	if (flat && flat.pointer.function.prototype.raw_type != decl.type.function.prototype.raw_type)
	{
		return @sema_error_at(context, expr.loc, "The lambda has type %s, which doesn't match the required type %s.",
						  type_quoted_error_string(decl.type),
						  type_quoted_error_string(target_type));
	}
	decl.func_decl.lambda_ct_parameters = ct_lambda_parameters;
	decl.func_decl.is_lambda = true;
	if (context_is_macro(context) || !context.call_env.current_function)
	{
		decl.func_decl.in_macro = true;
	}
	decl.alignment = type_alloca_alignment(decl.type);

	if (context.generic_instance)
	{
		decl.is_templated = true;
		decl.instance_id = declid(context.generic_instance);
	}

	// Before function analysis, lambda evaluation is deferred
	if (unit.mod.stage < AnalysisStage.FUNCTIONS)
	{
		// Because we cannot check if the parameter is used before everything, set them all as read.
		foreach (d : ct_lambda_parameters)
		{
			decl_read(d);
		}
		@vec_add(&unit.mod.lambdas_to_evaluate, decl);
	}
	else
	{
		decl.resolve_status = DONE;
		SemaContext lambda_context;
		sema_context_init(&lambda_context, context.unit);
		bool success = sema_analyse_function_body(&lambda_context, decl, context.macro_call_depth);
		sema_context_destroy(&lambda_context);
		if (!success)
		{
			if (multiple) @vec_add(&original.func_decl.generated_lambda, decl);
			return decl_poison(decl);
		}
		@vec_add(&unit.lambdas, decl);
	}

	expr.type = type_get_func_ptr(decl.type);
	expr.resolve_status = DONE;
	expr_rewrite_const_ref(expr, decl);
	// If it's a distinct type we have to make a cast.
	if (target_type && expr.type != target_type && !cast_explicit(context, expr, target_type)) return false;
	if (multiple)
	{
		@vec_add(&original.func_decl.generated_lambda, decl);
	}
	decl.resolve_status = DONE;
	return true;
}

// sema_expr.c:11949 (static)
fn bool sema_expr_analyse_ct_feature(SemaContext* context, Expr* expr)
{
	if (expr.resolve_status == DONE) return expr_ok(expr);

	Expr* inner = expr.inner_expr;
	if (inner.expr_kind == EXPRESSION_LIST)
	{
		switch (sema_evaluate_feature_expr_list(inner.expression_list))
		{
			case BOOL_TRUE:
				expr_rewrite_const_bool(expr, type_bool, true);
				return true;
			case BOOL_FALSE:
				expr_rewrite_const_bool(expr, type_bool, false);
				return true;
			case BOOL_ERR:
				return false;
		}
		unreachable();
	}
	// c3c `goto ERROR`.
	if (inner.expr_kind != UNRESOLVED_IDENTIFIER || !inner.unresolved_ident_expr.is_const)
	{
		return @sema_error_at(context, inner.loc, "Expected a feature name here, e.g. $feat(MY_FEATURE).");
	}

	String name = inner.unresolved_ident_expr.ident;
	void* value = htable_get(&compiler.context.features, (void*)name.ptr);
	assert(!value || value == (void*)name.ptr);
	expr_rewrite_const_bool(expr, type_bool, value != null);
	return true;
}

// sema_expr.c:11982 (static)
fn bool sema_expr_analyse_lenof(SemaContext* context, Expr* expr, bool* missing_ref)
{
	Expr* inner = expr.inner_expr;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;
	Type* canonical = inner.type.canonical;
	Decl* len = sema_find_untyped_operator(canonical, OVERLOAD_LEN, null);
	if (len)
	{
		return sema_insert_method_call(context, expr, len, inner, {}, false);
	}
	// c3c `goto RETRY` / `goto FAIL`: loop + `nextcase default`.
	while (true)
	{
		switch (canonical.type_kind)
		{
			case UNTYPEDLIST:
				// c3c asserts and reads `expr` here, which is the $lenof expression itself; the list is `inner`.
				assert(expr_is_const_untyped_list(inner));
				expr_rewrite_const_int(expr, type_sz, inner.const_expr.untyped_list.len);
				return true;
			case TYPEDEF:
			case CONSTSET:
				if (sema_type_has_subscript_overloads(canonical)) nextcase default;
				canonical = type_flatten(canonical);
				continue;
			case ARRAY:
			case VECTOR:
			case SIMD_VECTOR:
				expr_rewrite_const_int(expr, type_sz, (ulong)canonical.array.len);
				return true;
			case SLICE:
				expr_rewrite_slice_len(expr, inner, type_sz);
				return true;
			case STRUCT:
				if (canonical.decl.is_substruct && !sema_type_has_subscript_overloads(canonical))
				{
					Expr* expr_access = expr_access_inline_member(copy_expr_single(expr), canonical.decl);
					*expr = *expr_access;
					canonical = expr.type.canonical;
					continue;
				}
				nextcase default;
			default:
				if (missing_ref)
				{
					*missing_ref = true;
					return false;
				}
				return @sema_error_at(context, inner.loc, "%s does not support lengthof()", type_quoted_error_string(inner.type));
		}
	}
}

// sema_expr.c:12031 (static)
fn bool sema_expr_analyse_ct_defined(SemaContext* context, Expr* expr)
{
	if (expr.resolve_status == DONE) return expr_ok(expr);

	Expr*[] list = expr.expression_list;

	bool success = true;
	bool failed = false;
	usz list_len = list.len;
	if (!list_len) return @sema_error_at(context, expr.loc, "Expected at least one expression to test.");
	for (usz i = 0; i < list_len; i++)
	{
		Expr* main_expr = list[i];
		SemaContext* active_context = context;
		bool in_no_eval = active_context.call_env.in_no_eval;
		active_context.call_env.in_no_eval = true;
		bool unroll_hash = false;
		// c3c `goto RETRY` -> `continue RETRY`, `goto FAIL` -> `fail = true; break RETRY;`.
		bool fail = false;
		while RETRY: (true)
		{
			switch (main_expr.expr_kind)
			{
				case OTHER_CONTEXT:
					active_context.call_env.in_no_eval = in_no_eval;
					active_context = main_expr.expr_other_context.context;
					in_no_eval = active_context.call_env.in_no_eval;
					active_context.call_env.in_no_eval = true;
					main_expr = main_expr.expr_other_context.inner;
					continue RETRY;
				case LENGTHOF:
					if (!sema_expr_analyse_lenof(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case ACCESS_UNRESOLVED:
					if (!sema_expr_analyse_access(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case TYPE_PROPERTY:
					if (!sema_expr_analyse_type_property(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case UNRESOLVED_IDENTIFIER:
					if (!sema_expr_analyse_identifier(active_context, null, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case HASH_IDENT:
					if (unroll_hash)
					{
						Decl* decl = sema_resolve_symbol(active_context, main_expr.hash_ident_expr.identifier, null, main_expr.loc);
						if (!decl) { fail = true; break RETRY; }
						if (decl_is_defaulted_var(decl))
						{
							success = false;
							break;
						}
						bool is_ref = main_expr.hash_ident_expr.is_ref;
						main_expr = copy_expr_single(decl.var_decl.init_expr);
						if (is_ref) expr_set_to_ref(main_expr);
						continue RETRY;
					}
					Decl* decl = sema_find_symbol(active_context, main_expr.hash_ident_expr.identifier);
					if (!decl_ok(decl)) { fail = true; break RETRY; }
					success = decl != null && !decl_is_defaulted_var(decl);
				case COMPILER_CONST:
					success = sema_expr_analyse_compiler_const(active_context, main_expr, false);
				case BUILTIN:
					success = sema_expr_analyse_builtin(active_context, main_expr, false);
				case UNARY:
				case POST_UNARY:
					main_expr.resolve_status = RUNNING;
					if (!sema_expr_analyse_unary(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case TYPEINFO:
					Type* type = sema_expr_check_type_exists(active_context, main_expr.type_expr);
					if (!type_ok(type)) { fail = true; break RETRY; }
					success = type != null;
				case CT_EVAL:
					Expr* eval = sema_ct_eval_expr(active_context, EVAL_IDENTIFIER, main_expr.inner_expr, false, null);
					if (!expr_ok(eval)) return false;
					if (eval)
					{
						main_expr = eval;
						continue RETRY;
					}
					success = false;
				case SUBSCRIPT:
					if (!sema_expr_analyse_subscript(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case CAST:
					TypeInfo* typeinfo = type_infoptr(main_expr.cast_expr.type_info);
					if (typeinfo.resolve_status == DONE && typeinfo.type == type_void)
					{
						main_expr = exprptr(main_expr.cast_expr.expr);
						unroll_hash = true;
						continue RETRY;
					}
					if (!sema_expr_analyse_cast(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case CT_IDENT:
					Decl* decl = sema_find_symbol(active_context, main_expr.ct_ident_expr.identifier);
					if (!decl_ok(decl)) { fail = true; break RETRY; }
					success = decl != null && !decl_is_defaulted_var(decl);
				case CALL:
					bool no_match = false;
					if (!sema_expr_analyse_call(active_context, main_expr, &no_match))
					{
						if (!no_match) { fail = true; break RETRY; }
						success = false;
					}
				case FORCE_UNWRAP:
					if (!sema_analyse_expr_rvalue(active_context, main_expr.inner_expr)) { fail = true; break RETRY; }
					success = @is_optional(main_expr.inner_expr);
				case RETHROW:
					if (!sema_analyse_expr_rvalue(active_context, main_expr.rethrow_expr.inner)) { fail = true; break RETRY; }
					success = @is_optional(main_expr.rethrow_expr.inner);
				case OPTIONAL:
					if (!sema_expr_analyse_optional(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case POISONED:
					success = false;
				case CATCH_UNRESOLVED:
				case CATCH:
				case COND:
				case TEST_HOOK:
				case DESIGNATOR:
				case BENCHMARK_HOOK:
				case TRY_UNRESOLVED:
				case TRY:
				case TRY_UNWRAP_CHAIN:
				case OPERATOR_CHARS:
				case MACRO_BODY_EXPANSION:
				case BUILTIN_ACCESS:
				case LAST_FAULT:
				case DEFAULT_ARG:
				case IDENTIFIER:
				case NAMED_ARGUMENT:
				case NAMED_EVAL_ARGUMENT:
				case ACCESS_RESOLVED:
				case CT_SUBSCRIPT:
				case IOTA_DECL:
				case CONTRACT:
					unreachable();
				case DECL:
					if (!sema_analyse_local(active_context, main_expr.decl_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case BINARY:
					main_expr.resolve_status = RUNNING;
					if (!sema_expr_analyse_binary(active_context, null, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case CT_REFLECT:
					if (!sema_expr_analyse_ct_reflect(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case COMPOUND_LITERAL:
					if (!sema_expr_analyse_compound_literal(active_context, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case VAARG:
					if (active_context.macro_has_vaargs && !expr_ok(sema_expr_analyse_ct_arg_index(active_context, &main_expr.vaarg_index, &failed)))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
						break;
					}
					main_expr.resolve_status = RUNNING;
					if (!sema_expr_analyse_vaarg(active_context, null, main_expr, &failed))
					{
						if (!failed) { fail = true; break RETRY; }
						success = false;
					}
				case BITACCESS:
				case BITASSIGN:
				case EMBED:
				case GENERIC_IDENT:
				case MACRO_BODY:
				case POINTER_OFFSET:
				case RETVAL:
				case SLICE:
				case SLICE_ASSIGN:
				case SLICE_COPY:
				case SUBSCRIPT_ADDR:
				case SUBSCRIPT_ASSIGN:
				case SWIZZLE:
				case VASPLAT: // c3c REMINDER("Check if these should be analysed"), falls through.
				case INITIALIZER_LIST:
				case DESIGNATED_INITIALIZER_LIST:
				case ASM:
				case CONST:
				case NOP:
				case MACRO_BLOCK:
				case LAMBDA:
				case CT_DEFINED:
				case STRINGIFY:
				case TERNARY:
				case EXPRESSION_LIST:
				case TYPEID:
				case TYPEID_INFO:
				case TYPECALL:
				case MEMBER_GET:
				case MEMBER_SET:
				case SPLAT:
				case VACOUNT:
				case EXT_TRUNC:
				case INT_TO_BOOL:
				case VECTOR_TO_ARRAY:
				case SLICE_TO_VEC_ARRAY:
				case SCALAR_TO_VECTOR:
				case PTR_ACCESS:
				case ENUM_FROM_ORD:
				case SLICE_LEN:
				case VECTOR_FROM_ARRAY:
				case RVALUE:
				case RECAST:
				case MAKE_ANY:
				case DISCARD:
				case ADDR_CONVERSION:
				case FLOAT_TO_INT:
				case INT_TO_FLOAT:
				case INT_TO_PTR:
				case PTR_TO_INT:
				case MAKE_SLICE:
				case TWO:
				case MAYBE_DEREF:
				case CT_FEATURE:
					if (!sema_analyse_expr_rvalue(active_context, main_expr)) { fail = true; break RETRY; }
			}
			break;
		}
		active_context.call_env.in_no_eval = in_no_eval;
		if (fail) return false;
		if (success) continue;
		break;
	}
	expr_rewrite_const_bool(expr, type_bool, success);
	return true;
}

// sema_expr.c:12338 (static)
fn bool sema_expr_analyse_vaarg(SemaContext* context, Type* infer_type, Expr* expr, bool* no_match_ref)
{
	assert(expr.resolve_status == RUNNING);
	if (!context.macro_has_vaargs)
	{
		return @sema_error_at(context, expr.loc, "'$vaarg' can only be used inside of a macro with untyped vaargs.");
	}
	// A normal argument, this means we only evaluate it once.
	Expr* arg_expr = sema_expr_analyse_ct_arg_index(context, &expr.vaarg_index, null);
	if (!expr_ok(arg_expr)) return false;
	arg_expr = copy_expr_single(arg_expr);
	if (!sema_analyse_inferred_expr(context, infer_type, arg_expr, no_match_ref)) return false;
	expr_replace(expr, arg_expr);
	return true;
}

// sema_expr.c:12353 (static)
fn bool sema_expr_analyse_vacount(SemaContext* context, Expr* expr)
{
	assert(expr.resolve_status == RUNNING);
	if (!context.macro_has_vaargs)
	{
		return @sema_error_at(context, expr.loc, "'$vaarg.len' can only be used inside of a macro with untyped vaargs.");
	}
	expr_rewrite_const_int(expr, type_sz, context.macro_varargs.len);
	return true;
}

// sema_expr.c:12364 (static)
fn bool sema_expr_analyse_maybe_deref(SemaContext* context, Expr* expr)
{
	Expr* inner = expr.inner_expr;
	if (!sema_analyse_expr_rvalue(context, inner)) return false;
	if (type_is_pointer(inner.type))
	{
		expr.expr_kind = UNARY;
		expr.unary_expr = { .expr = inner, .operator = DEREF };
		return sema_expr_analyse_unary(context, expr, null);
	}
	expr_replace(expr, inner);
	return true;
}

// sema_expr.c:12378 (static)
fn bool sema_expr_analyse_iota_decl(SemaContext* context, Expr* expr)
{
	Decl* decl = expr.iota_decl_expr;
	if (!decl_ok(decl)) return false;
	if (decl.resolve_status != DONE)
	{
		return @sema_error_at(context, expr.loc, "Enum constants values should never need to be resolved out of order.");
	}
	Expr* iota_expr = decl.enum_constant.value;
	// c3c: assert(expr_is_const_int(iota_expr)); -- C assert, compiled out in c3c release builds

	Int value = iota_expr.const_expr.ixx;
	Int add = int_add64(value, 1);
	if (int_comp(add, value, LT))
	{
		return @sema_error_at(context, expr.loc, "Enum value would overflow the maximum value of the container type %s.", type_quoted_error_string(type_flatten(decl.type)));
	}
	expr_rewrite_const_integer(expr, iota_expr.type, add.i);
	return true;
}

// sema_expr.c:12401 (static)
fn bool sema_expr_analyse_ct_stringify(SemaContext* context, Expr* expr)
{
	Expr* inner = expr.inner_expr;
	// Only hash ident style stringify reaches here.
	while (true)
	{
		switch (inner.expr_kind)
		{
			case VAARG:
				Expr* arg_expr = sema_expr_analyse_ct_arg_index(context, &inner.vaarg_index, null);
				if (!expr_ok(arg_expr)) return false;
				inner = arg_expr;
				continue;
			case OTHER_CONTEXT:
				context = inner.expr_other_context.context;
				inner = inner.expr_other_context.inner;
				continue;
			case HASH_IDENT:
				Decl* decl = sema_resolve_symbol(context, inner.ct_ident_expr.identifier, null, inner.loc);
				if (!decl) return false;
				inner = decl.var_decl.init_expr;
				continue;
			default:
				break;
		}
		break;
	}
	String desc = span_to_string(inner.loc);
	if (!desc.ptr)
	{
		return @sema_error_at(context, expr.loc, "Failed to stringify hash variable contents - they must be a single line and not exceed 255 characters.");
	}
	expr_rewrite_const_string_from_raw(expr, desc);
	return true;
}

// sema_expr.c:12440 (static)
fn bool sema_expr_resolve_ct_eval(SemaContext* context, Expr* expr)
{
	Expr* result = sema_ct_eval_expr(context, EVAL_IDENTIFIER, expr.inner_expr, true, null);
	if (!expr_ok(result) || !result) return false;
	expr_replace(expr, result);
	return true;
}

// sema_expr.c:12448 (static)
fn bool sema_expr_analyse_ct_reflect(SemaContext* context, Expr* expr, bool* failed_ref)
{
	Expr* inner = expr.inner_expr;
	bool old_no_eval = context.call_env.in_no_eval;
	context.call_env.in_no_eval = true;
	bool success = sema_analyse_expr(context, inner);
	context.call_env.in_no_eval = old_no_eval;
	if (!success) return false;
	expr.const_expr = { .const_kind = REFLECTION, .reflection = inner };
	expr.expr_kind = CONST;
	expr.type = type_reflection;
	return true;
}

// sema_expr.c:12463 (static)
fn BuiltinFunction builtin_by_name(String name)
{
	for (int i = 0; i < NUMBER_OF_BUILTINS.ordinal; i++)
	{
		if (builtin_list[i].ptr == name.ptr) return BuiltinFunction::values[i];
	}
	return BuiltinFunction.NONE;
}

// sema_expr.c:12473 (static)
fn bool sema_expr_analyse_retval(SemaContext* context, Expr* expr)
{
	if ((context.active_scope.flags & (SCOPE_ENSURE | SCOPE_ENSURE_MACRO)) == 0)
	{
		return @sema_error_at(context, expr.loc, "'return' as a value can only be used inside of an '@ensure'.");
	}
	Expr* return_value = context.return_expr;
	bool is_macro_ensure = (context.active_scope.flags & SCOPE_ENSURE_MACRO) != 0;
	if (is_macro_ensure)
	{
		expr.type = type_no_optional(return_value.type);
	}
	else
	{
		expr.type = type_no_optional(context.rtype);
		if (type_is_void(expr.type))
		{
			return @sema_error_at(context, expr.loc, "'return' cannot be used on void functions.");
		}
	}
	assert(return_value);

	if (expr_is_runtime_const(return_value))
	{
		expr_replace(expr, copy_expr_single(return_value));
	}
	return true;
}

// sema_expr.c:12502 (static)
fn bool sema_expr_analyse_builtin(SemaContext* context, Expr* expr, bool throw_error)
{
	String builtin_char = expr.builtin_expr.ident;
	BuiltinFunction func = builtin_by_name(builtin_char);
	if (func == BuiltinFunction.NONE)
	{
		if (throw_error) @sema_error_at(context, expr.loc, "Unsupported builtin '%s'.", builtin_char);
		return false;
	}
	expr.builtin_expr.builtin = func;
	String top_module_name = context.unit.mod.top_module.name.module_name;
	if (top_module_name.ptr != kw_std.ptr && top_module_name.ptr != kw_compiler_rt.ptr && !context.unit.mod.is_compiler_rt)
	{
		return @sema_warn_at(context, expr.loc, compiler.build.warnings.builtin, "Builtins are intended for internal use inside of the standard library, please access this function through the standard library macro instead.");
	}
	expr.type = null;
	return true;
}

// sema_expr.c:12521 (static)
fn bool sema_expr_analyse_compound_literal(SemaContext* context, Expr* expr, bool* no_match_ref)
{
	TypeInfo* type_info = expr.expr_compound_literal.type_info;
	// We allow inferring the size of arrays.
	if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_ALLOW_INFER)) return false;
	Type* type = type_info.type;
	if (type_is_optional(type))
	{
		return @sema_error_at(context, type_info.loc, "The type here should always be written as a plain type and not an optional, please remove the '~'.");
	}
	if (!sema_resolve_type_structure(context, type)) return false;
	if (!sema_expr_analyse_initializer_list(context, type, expr.expr_compound_literal.initializer, no_match_ref)) return false;
	expr_replace(expr, expr.expr_compound_literal.initializer);
	return true;
}

// sema_expr.c:12538 (static)
fn bool sema_analyse_expr_dispatch(SemaContext* context, Expr* expr)
{
	switch (expr.expr_kind)
	{
		case ASM:
		case BENCHMARK_HOOK:
		case CATCH:
		case CATCH_UNRESOLVED:
		case COND:
		case CONTRACT:
		case CT_SUBSCRIPT:
		case DEFAULT_ARG:
		case DESIGNATOR:
		case ENUM_FROM_ORD:
		case FLOAT_TO_INT:
		case INT_TO_FLOAT:
		case INT_TO_PTR:
		case MACRO_BODY:
		case MACRO_BODY_EXPANSION:
		case MAKE_SLICE:
		case MEMBER_GET:
		case MEMBER_SET:
		case NAMED_ARGUMENT:
		case NAMED_EVAL_ARGUMENT:
		case NOP:
		case OPERATOR_CHARS:
		case PTR_TO_INT:
		case SCALAR_TO_VECTOR:
		case SLICE_TO_VEC_ARRAY:
		case SWIZZLE:
		case TEST_HOOK:
		case TRY:
		case TRY_UNRESOLVED:
		case TRY_UNWRAP_CHAIN:
		case TYPEID_INFO:
		case VECTOR_TO_ARRAY:
			unreachable();
		case TYPE_PROPERTY:
			return sema_expr_analyse_type_property(context, expr, null);
		case LENGTHOF:
			return sema_expr_analyse_lenof(context, expr, null);
		case IOTA_DECL:
			return sema_expr_analyse_iota_decl(context, expr);
		case TWO:
			if (!sema_analyse_expr_rvalue(context, expr.two_expr.first)) return false;
			if (!sema_analyse_expr(context, expr.two_expr.last)) return false;
			expr.type = expr.two_expr.last.type;
			return true;
		case MAKE_ANY:
			if (!sema_analyse_expr_rvalue(context, expr.make_any_expr.typeid_expr)) return false;
			return sema_analyse_expr_rvalue(context, expr.make_any_expr.inner);
		case MAYBE_DEREF:
			return sema_expr_analyse_maybe_deref(context, expr);
		case RVALUE:
		case RECAST:
		case ADDR_CONVERSION:
		case DISCARD:
		case PTR_ACCESS:
		case SLICE_LEN:
		case VECTOR_FROM_ARRAY:
			return sema_analyse_expr_rvalue(context, expr.inner_expr);
		case INT_TO_BOOL:
			return sema_analyse_expr_rvalue(context, expr.int_to_bool_expr.inner);
		case EXT_TRUNC:
			return sema_analyse_expr_rvalue(context, expr.ext_trunc_expr.inner);
		case SPLAT:
			return @sema_error_at(context, expr.loc, "Splat ('...') may only appear in initializers and calls.");
		case TYPECALL:
			return @sema_error_at(context, expr.loc, "Expected '()' after this.");
		case OTHER_CONTEXT:
			SemaContext* new_context = expr.expr_other_context.context;
			expr_replace(expr, expr.expr_other_context.inner);
			if (expr.resolve_status == DONE) return expr_ok(expr);
			ContextSwitchState state = context_switch_state_push(context, new_context);
			expr.resolve_status = RUNNING;
			bool success = sema_analyse_expr_dispatch(new_context, expr);
			context_switch_stat_pop(new_context, state);
			return success;
		case EMBED:
			return sema_expr_analyse_embed(context, expr, false);
		case VASPLAT:
			return @sema_error_at(context, expr.loc, "'...$vaarg' can only be used inside of macros.");
		case CT_REFLECT:
			return sema_expr_analyse_ct_reflect(context, expr, null);
		case GENERIC_IDENT:
			return sema_expr_analyse_generic_ident(context, expr);
		case LAMBDA:
			return sema_expr_analyse_lambda(context, null, expr);
		case CT_DEFINED:
			return sema_expr_analyse_ct_defined(context, expr);
		case VAARG:
			return sema_expr_analyse_vaarg(context, null, expr, null);
		case VACOUNT:
			return sema_expr_analyse_vacount(context, expr);
		case STRINGIFY:
			if (!sema_expr_analyse_ct_stringify(context, expr)) return false;
			return true;
		case DECL:
			Decl* decl = expr.decl_expr;
			bool erase = decl.var_decl.kind == LOCAL_CT_TYPE || decl.var_decl.kind == LOCAL_CT;
			if (!sema_analyse_local(context, decl, null)) return false;
			if (decl.decl_kind == ERASED)
			{
				expr.expr_kind = NOP;
				expr.type = type_void;
				return true;
			}
			if (erase)
			{
				Expr* init = decl.var_decl.init_expr;
				if (init)
				{
					expr_replace(expr, copy_expr_single(decl.var_decl.init_expr));
					return true;
				}
				expr.expr_kind = NOP;
				expr.type = type_void;
				return true;
			}
			expr.type = decl.type;
			return true;
		case LAST_FAULT:
			expr.type = type_fault;
			return true;
		case RETVAL:
			return sema_expr_analyse_retval(context, expr);
		case BUILTIN:
			return sema_expr_analyse_builtin(context, expr, true);
		case CT_FEATURE:
			return sema_expr_analyse_ct_feature(context, expr);
		case HASH_IDENT:
			if (!sema_expr_fold_hash(context, expr)) return false;
			return sema_analyse_expr(context, expr);
		case CT_IDENT:
			return sema_expr_analyse_ct_identifier(context, expr);
		case OPTIONAL:
			return sema_expr_analyse_optional(context, expr, null);
		case COMPILER_CONST:
			return sema_expr_analyse_compiler_const(context, expr, true);
		case POINTER_OFFSET:
			return sema_expr_analyse_pointer_offset(context, expr);
		case POISONED:
			return false;
		case SLICE_ASSIGN:
		case BUILTIN_ACCESS:
		case SLICE_COPY:
		case BITASSIGN: // Created during semantic analysis
			unreachable();
		case MACRO_BLOCK:
			unreachable();
		case TYPEINFO:
			expr.type = type_typeinfo;
			return sema_resolve_type_info(context, expr.type_expr, RESOLVE_TYPE_DEFAULT);
		case SLICE:
			return sema_expr_analyse_slice(context, expr);
		case FORCE_UNWRAP:
			return sema_expr_analyse_force_unwrap(context, expr);
		case COMPOUND_LITERAL:
			return sema_expr_analyse_compound_literal(context, expr, null);
		case RETHROW:
			return sema_expr_analyse_rethrow(context, expr, null);
		case CONST:
			return true;
		case CT_EVAL:
			if (!sema_expr_resolve_ct_eval(context, expr)) return false;
			return sema_analyse_expr_dispatch(context, expr);
		case BINARY:
			return sema_expr_analyse_binary(context, null, expr, null);
		case TERNARY:
			return sema_expr_analyse_ternary(context, null, expr);
		case UNARY:
		case POST_UNARY:
			return sema_expr_analyse_unary(context, expr, null);
		case TYPEID:
			return sema_expr_analyse_typeid(context, expr);
		case IDENTIFIER:
			unreachable();
		case UNRESOLVED_IDENTIFIER:
			return sema_expr_analyse_identifier(context, null, expr, null);
		case CALL:
			return sema_expr_analyse_call(context, expr, null);
		case SUBSCRIPT:
		case SUBSCRIPT_ADDR:
			return sema_expr_analyse_subscript(context, expr, null);
		case BITACCESS:
		case SUBSCRIPT_ASSIGN:
		case ACCESS_RESOLVED:
			unreachable();
		case ACCESS_UNRESOLVED:
			return sema_expr_analyse_access(context, expr, null);
		case INITIALIZER_LIST:
		case DESIGNATED_INITIALIZER_LIST:
			return sema_expr_analyse_initializer_list(context, type_untypedlist, expr, null);
		case CAST:
			return sema_expr_analyse_cast(context, expr, null);
		case EXPRESSION_LIST:
			return sema_expr_analyse_expr_list(context, expr);
	}
	unreachable();
}

// sema_expr.c:12745
fn bool sema_analyse_cond_expr(SemaContext* context, Expr* expr, CondResult* result)
{
	if (expr_is_ungrouped_binary(expr) && expr.binary_expr.operator == ASSIGN)
	{
		return @sema_error_at(context, expr.loc, "Assignment expressions must be enclosed in an extra () in conditionals.");
	}
	if (!sema_analyse_expr_rvalue(context, expr)) return false;
	if (@is_optional(expr))
	{
		return @sema_error_at(context, expr.loc, "An optional %s cannot be implicitly converted to a regular boolean value, "
								"use '@ok(<expr>)' and '@catch(<expr>)' to conditionally execute on success "
								"or failure.",
								type_quoted_error_string(expr.type));
	}
	if (!cast_explicit(context, expr, type_bool)) return false;
	if (sema_cast_const(expr) && expr_is_const_bool(expr))
	{
		*result = expr.const_expr.b ? COND_TRUE : COND_FALSE;
	}
	return true;
}

// sema_expr.c:12767 (static)
fn bool sema_analyse_expr_rhs_param(SemaContext* context, Type* to, Expr* expr, bool* no_match_ref)
{
	Decl* generic = context.generic_infer;
	context.generic_infer = declptrzero(to ? type_find_generic(to) : 0);
	bool success = sema_analyse_expr_rhs(context, to, expr, true, no_match_ref, false);
	context.generic_infer = generic;
	return success;
}

// sema_expr.c:12776
fn bool sema_analyse_expr_rhs(SemaContext* context, Type* to, Expr* expr, bool allow_optional, bool* no_match_ref, bool as_binary)
{
	if (expr.expr_kind == EMBED && allow_optional)
	{
		if (!sema_expr_analyse_embed(context, expr, true)) return false;
	}
	else
	{
		Decl* generic;
		if (to && (generic = declptrzero(type_find_generic(to))) != null) // NOLINT
		{
			Decl* generic_prev = context.generic_infer;
			context.generic_infer = generic;
			bool success = sema_analyse_inferred_expr(context, to, expr, no_match_ref);
			context.generic_infer = generic_prev;
			if (!success) return false;
		}
		else
		{
			if (!sema_analyse_inferred_expr(context, to, expr, no_match_ref)) return false;
		}
	}
	if (!sema_cast_rvalue(context, expr, true)) return false;
	if (to) to = type_no_optional(to);
	Type* to_canonical = to ? type_no_optional(to).canonical : null;
	Type* rhs_type = expr.type;
	Type* rhs_type_canonical = rhs_type.canonical;
	// Let's have a better error on `return io::FILE_NOT_FOUND;` when the return type is not fault.
	if (to && allow_optional && to_canonical != rhs_type_canonical && rhs_type_canonical == type_fault)
	{
		Type* flat = type_flatten(to);
		if (flat != type_fault && sema_cast_const(expr))
		{
			if (no_match_ref) { *no_match_ref = true; return false; }
			@print_error_after(sourcelocptr(expr.loc), "You need to add a trailing '~' here to make this an optional.");
			return false;
		}
	}
	// Let's see if we have a fixed slice (c3c `goto NO_SLICE` clears `fixed_slice`).
	bool fixed_slice = to && type_is_arraylike(to_canonical) && expr.expr_kind == SLICE && rhs_type_canonical.type_kind == SLICE;
	Type* element = null;
	IndexDiff len = 0;
	if (fixed_slice)
	{
		element = type_get_indexed_type(rhs_type_canonical).canonical;
		if (element != type_get_indexed_type(to_canonical).canonical) fixed_slice = false;
	}
	if (fixed_slice)
	{
		len = range_const_len(&expr.slice_expr.range);
		if (len < 1) fixed_slice = false;
	}
	if (fixed_slice)
	{
		if (len != to_canonical.array.len)
		{
			if (no_match_ref) { *no_match_ref = true; return false; }
			return @sema_error_at(context, expr.loc, "Slice length mismatch, expected %d but got %d.", (long)to_canonical.array.len, (long)len);
		}
		// Given x[3..7] -> (int[5]*)x[3..7]
		cast_no_check(expr, type_get_ptr(type_get_array(element, len)), @is_optional(expr));
		// Deref
		if (!sema_expr_rewrite_insert_deref(context, expr)) return false;
		cast_no_check(expr, to, @is_optional(expr));
		return true;
	}
	if (to)
	{
		if (as_binary)
		{
			if (!cast_implicit_binary(context, expr, to, no_match_ref)) return false;
		}
		else
		{
			if (!cast_implicit_checked(context, expr, to, false, no_match_ref)) return false;
		}
	}
	if (!allow_optional && @is_optional(expr))
	{
		if (no_match_ref) { *no_match_ref = true; return false; }
		return @sema_error_at(context, expr.loc, "It is not possible to cast from %s to %s.", type_quoted_error_string(expr.type),
				   type_quoted_error_string(type_no_optional(expr.type)));
	}
	return true;
}

// sema_expr.c:12858 (static)
fn bool sema_cast_ct_ident_rvalue(SemaContext* context, Expr* expr)
{
	Decl* decl = expr.ident_expr;
	Expr* copy = copy_expr_single(decl.var_decl.init_expr);
	if (!copy)
	{
		return @sema_error_at(context, expr.loc, "'%s' was not yet initialized to any value, assign a value to it before use.", decl.name);
	}
	if (!sema_analyse_expr_rvalue(context, copy)) return false;
	sema_cast_const(copy);
	expr_replace(expr, copy);
	return true;
}

// sema_expr.c:12872 (static)
fn bool sema_cast_rvalue(SemaContext* context, Expr* expr, bool mutate)
{
	if (!expr_ok(expr)) return false;
	switch (expr.expr_kind)
	{
		case MEMBER_SET:
			return @sema_error_at(context, expr.loc, "Expected two parameters to 'set', e.g. '$member.set(v, new_value)'.");
		case MEMBER_GET:
			return @sema_error_at(context, expr.loc, "Expected a parameter to 'get', e.g. '$member.get(v)'.");
		case MACRO_BODY_EXPANSION:
			if (!expr.body_expansion_expr.first_stmt)
			{
				return @sema_error_at(context, expr.loc, "'%s' must be followed by ().", declptr(context.current_macro.func_decl.body_param).name); // NOLINT
			}
		case TYPECALL:
			return @sema_error_at(context, expr.loc, "A tag name must be given.");
		case BUILTIN:
			return @sema_error_at(context, expr.loc, "A builtin must be followed by ().");
		case ACCESS_RESOLVED:
			if (expr.access_resolved_expr.ref.decl_kind == FUNC)
			{
				return @sema_error_at(context, expr.loc, "A function name must be followed by '(' or preceded by '&'.");
			}
			if (expr.access_resolved_expr.ref.decl_kind == MACRO)
			{
				return @sema_error_at(context, expr.loc, "A macro name must be followed by '('.");
			}
			// We may have kept FOO.x.y as a reference, fold it now if y is not an aggregate.
			if (mutate)
			{
				sema_expr_flatten_const_ident(expr.access_resolved_expr.parent);
				if (!sema_cast_rvalue(context, expr.access_resolved_expr.parent, mutate)) return false;
			}
			return true;
		case TYPEINFO:
			switch (type_no_optional(expr.type_expr.type).type_kind)
			{
				case TYPEINFO:
				case INFERRED_ARRAY:
				case INFERRED_VECTOR:
				case POISONED:
				case MEMBER:
				case WILDCARD:
				case REFLECTION:
					return @sema_error_at(context, expr.loc, "You cannot take the typeid of a compile time type.");
				default:
					expr_rewrite_const_typeid(expr, expr.type_expr.type);
					return true;
			}
		case CT_IDENT:
			unreachable();
		case IDENTIFIER:
			if (mutate && !sema_cast_ident_rvalue(context, expr)) return false;
		case SLICE:
			Expr* inner = exprptr(expr.subscript_expr.expr);
			if (inner.expr_kind != IDENTIFIER) break;
			Decl* decl = inner.ident_expr;
			if (decl.decl_kind != VAR) break;
			if (!decl.var_decl.out_param || decl.var_decl.in_param) break;
			if (context.active_scope.flags & (SCOPE_ENSURE | SCOPE_ENSURE_MACRO)) break;
		case SUBSCRIPT:
			Expr* inner = exprptr(expr.subscript_expr.expr);
			if (inner.expr_kind != IDENTIFIER) break;
			Decl* decl = inner.ident_expr;
			if (decl.decl_kind != VAR) break;
			if (!decl.var_decl.out_param || decl.var_decl.in_param) break;
			if (context.active_scope.flags & (SCOPE_ENSURE | SCOPE_ENSURE_MACRO)) break;
			return @sema_error_at(context, expr.loc, "'out' parameters may not be read.");
		case UNARY:
			if (expr.unary_expr.operator != DEREF) break;
			Expr* inner = expr.inner_expr;
			if (inner.expr_kind != IDENTIFIER) break;
			Decl* decl = inner.ident_expr;
			if (decl.decl_kind != VAR) break;
			if (expr.unary_expr.no_read) break;
			if (!decl.var_decl.out_param || decl.var_decl.in_param) break;
			if (context.active_scope.flags & (SCOPE_ENSURE | SCOPE_ENSURE_MACRO)) return true;
			return @sema_error_at(context, expr.loc, "'out' parameters may not be read.");
		default:
			break;
	}
	return true;
}

// sema_expr.c:12960
fn bool sema_analyse_ct_expr(SemaContext* context, Expr* expr)
{
	if (!sema_analyse_expr(context, expr)) return false;
	if (expr.expr_kind == TYPEINFO)
	{
		Type* cond_val = expr.type_expr.type;
		expr.expr_kind = CONST;
		expr.const_expr.const_kind = TYPEID;
		expr.const_expr.typeid_type = cond_val.canonical;
		expr.type = type_typeid;
	}
	if (!sema_cast_rvalue(context, expr, true)) return false;
	if (!sema_cast_const(expr))
	{
		return @sema_error_at(context, expr.loc, "Expected a compile time expression.");
	}
	return true;
}

// sema_expr.c:12979
fn bool sema_analyse_expr(SemaContext* context, Expr* expr)
{
	// c3c RESOLVE(expr, sema_analyse_expr_dispatch(context, expr))
	switch (expr.resolve_status)
	{
		case NOT_DONE:
			expr.resolve_status = RUNNING;
			if (!sema_analyse_expr_dispatch(context, expr)) return expr_poison(expr);
			expr.resolve_status = DONE;
			return true;
		case RUNNING:
			@sema_error_at(context, expr.loc, "Recursive resolution of expression.");
			return expr_poison(expr);
		case DONE:
			return expr_ok(expr);
	}
}

// sema_expr.c:12984 (static)
fn bool sema_analyse_expr_lvalue_dispatch(SemaContext* context, Expr* expr, bool* failed_ref)
{
	// c3c `goto RETRY` -> `continue RETRY`, `goto IDENT_CHECK` -> `nextcase IDENTIFIER`,
	// `goto FAILED_REF` -> `*failed_ref = true; return false;`.
	while RETRY: (true)
	{
		switch (expr.expr_kind)
		{
			case HASH_IDENT:
				if (!sema_expr_fold_hash(context, expr)) return false;
				continue RETRY;
			case CT_IDENT:
				return sema_expr_resolve_ct_identifier(context, expr);
			case SUBSCRIPT:
				return sema_expr_analyse_subscript_lvalue(context, expr, failed_ref);
			case OTHER_CONTEXT:
				SemaContext* new_context = expr.expr_other_context.context;
				expr_replace(expr, expr.expr_other_context.inner);
				if (expr.resolve_status == DONE) return expr_ok(expr);
				ContextSwitchState state = context_switch_state_push(context, new_context);
				expr.resolve_status = RUNNING;
				bool success = sema_analyse_expr_lvalue_dispatch(new_context, expr, failed_ref);
				context_switch_stat_pop(new_context, state);
				return success;
			case SWIZZLE:
				if (failed_ref) { *failed_ref = true; return false; }
				return @sema_error_at(context, expr.loc, "You cannot use swizzling to assign to multiple elements, use element-wise assign instead.");
			case LAMBDA:
				if (failed_ref) { *failed_ref = true; return false; }
				return @sema_error_at(context, expr.loc, "This expression is a value and cannot be assigned to.");
			case CONST:
				if (failed_ref) { *failed_ref = true; return false; }
				return @sema_error_at(context, expr.loc, "You cannot assign to a constant expression.");
			case GENERIC_IDENT:
				if (!sema_analyse_expr_dispatch(context, expr)) return false;
				nextcase IDENTIFIER;
			case UNRESOLVED_IDENTIFIER:
				if (!sema_analyse_expr_dispatch(context, expr)) return false;
				continue RETRY;
			case IDENTIFIER:
				Decl* decl = expr.ident_expr;
				if (decl.decl_kind != VAR)
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, expr.loc, "You cannot assign a value to %s.", decl_to_a_name(decl));
				}
				if (decl.var_decl.kind == CONST)
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, expr.loc, "You cannot assign to a constant.");
				}
				decl = decl_raw(decl);
				switch (decl.var_decl.kind)
				{
					case LOCAL_CT:
					case LOCAL_CT_TYPE:
					case LOCAL:
					case GLOBAL:
					case PARAM:
					case PARAM_CT:
					case PARAM_CT_TYPE:
						return true;
					case MEMBER:
					case BITMEMBER:
						break;
					case CONST:
					case PARAM_EXPR:
					case UNWRAPPED:
					case ERASE:
					case REWRAPPED:
						unreachable();
				}
				unreachable();
			case POISONED:
				return false;
			case UNARY:
				if (!sema_analyse_expr_dispatch(context, expr)) return false;
				if (expr.unary_expr.operator != DEREF) break;
				if (@is_optional(expr))
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, expr.loc, "You cannot assign to a dereferenced optional.");
				}
				return true;
			case VAARG:
				break;
			case RECAST:
			case CAST:
				if (failed_ref) { *failed_ref = true; return false; }
				return @sema_error_at(context, expr.loc, "Assignment to casts is not possible (this sub-expression is a value, not an address), maybe you put the order of the operators wrong?");
			case CT_EVAL:
				if (!sema_expr_resolve_ct_eval(context, expr)) return false;
				continue RETRY;
			case SLICE:
				return sema_expr_analyse_slice(context, expr);
			case ACCESS_UNRESOLVED:
				expr.access_unresolved_expr.is_lvalue = true;
				expr.access_unresolved_expr.is_ref = true;
				return sema_expr_analyse_access(context, expr, failed_ref);
			case ADDR_CONVERSION:
			case ASM:
			case BENCHMARK_HOOK:
			case BINARY:
			case BITASSIGN:
			case BUILTIN:
			case BUILTIN_ACCESS:
			case CALL:
			case CATCH:
			case CATCH_UNRESOLVED:
			case COMPILER_CONST:
			case COMPOUND_LITERAL:
			case COND:
			case CT_FEATURE:
			case CT_DEFINED:
			case DECL:
			case DEFAULT_ARG:
			case DESIGNATED_INITIALIZER_LIST:
			case DESIGNATOR:
			case DISCARD:
			case EMBED:
			case ENUM_FROM_ORD:
			case EXPRESSION_LIST:
			case EXT_TRUNC:
			case FLOAT_TO_INT:
			case FORCE_UNWRAP:
			case INITIALIZER_LIST:
			case INT_TO_BOOL:
			case INT_TO_FLOAT:
			case INT_TO_PTR:
			case IOTA_DECL:
			case LAST_FAULT:
			case LENGTHOF:
			case MACRO_BLOCK:
			case MACRO_BODY:
			case MACRO_BODY_EXPANSION:
			case MAKE_ANY:
			case MAKE_SLICE:
			case MAYBE_DEREF:
			case MEMBER_GET:
			case MEMBER_SET:
			case NAMED_ARGUMENT:
			case NAMED_EVAL_ARGUMENT:
			case NOP:
			case OPERATOR_CHARS:
			case OPTIONAL:
			case POINTER_OFFSET:
			case POST_UNARY:
			case PTR_ACCESS:
			case PTR_TO_INT:
			case RETHROW:
			case RETVAL:
			case RVALUE:
			case SCALAR_TO_VECTOR:
			case SLICE_ASSIGN:
			case SLICE_COPY:
			case SLICE_LEN:
			case SLICE_TO_VEC_ARRAY:
			case SPLAT:
			case STRINGIFY:
			case SUBSCRIPT_ADDR:
			case TERNARY:
			case TEST_HOOK:
			case TRY:
			case TRY_UNRESOLVED:
			case TRY_UNWRAP_CHAIN:
			case TWO:
			case TYPECALL:
			case TYPEID:
			case TYPEID_INFO:
			case TYPEINFO:
			case VASPLAT:
			case VECTOR_FROM_ARRAY:
			case VECTOR_TO_ARRAY:
			case CT_REFLECT:
			case TYPE_PROPERTY:
			case VACOUNT:
				break;
			case BITACCESS:
			case SUBSCRIPT_ASSIGN:
			case ACCESS_RESOLVED:
			case CT_SUBSCRIPT:
			case CONTRACT:
				unreachable();
		}
		break;
	}
	if (failed_ref) { *failed_ref = true; return false; }
	return @sema_error_at(context, expr.loc, "An assignable expression, like a variable, was expected here.");
}

// sema_expr.c:13180
fn bool sema_analyse_expr_lvalue(SemaContext* context, Expr* expr, bool* failed_ref)
{
	assert(expr);
	// c3c RESOLVE(expr, sema_analyse_expr_lvalue_dispatch(context, expr, failed_ref))
	switch (expr.resolve_status)
	{
		case NOT_DONE:
			expr.resolve_status = RUNNING;
			if (!sema_analyse_expr_lvalue_dispatch(context, expr, failed_ref)) return expr_poison(expr);
			expr.resolve_status = DONE;
			return true;
		case RUNNING:
			@sema_error_at(context, expr.loc, "Recursive resolution of expression.");
			return expr_poison(expr);
		case DONE:
			return expr_ok(expr);
	}
}

// sema_expr.c:13186
fn bool sema_expr_check_discard(SemaContext* context, Expr* expr)
{
	switch (expr.expr_kind)
	{
		case EXPRESSION_LIST:
			foreach (expr_element : expr.expression_list)
			{
				if (!sema_expr_check_discard(context, expr_element)) return false;
			}
			return true;
		case DECL:
		case SUBSCRIPT_ASSIGN:
		case SLICE_ASSIGN:
			return true;
		case BINARY:
			if (expr.binary_expr.operator.ordinal >= BinaryOp.ASSIGN.ordinal) return true;
		case UNARY:
		case POST_UNARY:
			switch (expr.unary_expr.operator)
			{
				case DEC:
				case INC:
					return true;
				default:
					break;
			}
		case MACRO_BLOCK:
			if (expr.macro_block.is_must_use)
			{
				if (expr.macro_block.is_optional_return)
				{
					return @sema_error_at(context, expr.loc, "The macro returns %s, which is an optional and must be handled. "
											"You can either assign it to a variable, rethrow it using '!', "
											"panic with '!!', use if-catch etc. You can also silence the error using a void cast (e.g. '(void)the_call()') to ignore the error.",
									  type_quoted_error_string(expr.type));
				}
				return @sema_error_at(context, expr.loc, "The called macro is marked `@nodiscard` meaning the result should be kept. You can still discard it using a void cast (e.g. '(void)the_call()') if you want.");
			}
			if (expr.macro_block.had_optional_arg) return sema_expr_check_discard_error_args(context, expr);
			return true;
		case CALL:
			if (expr.call_expr.must_use)
			{
				if (expr.call_expr.is_optional_return)
				{
					return @sema_error_at(context, expr.loc, "The function returns %s, which is an optional and must be handled. "
											"You can either assign it to a variable, rethrow it using '!', "
											"panic with '!!', use if-catch etc. You can also silence the error using a void cast (e.g. '(void)the_call()') to ignore the error.",
											type_quoted_error_string(expr.type));
				}
				return @sema_error_at(context, expr.loc, "The called function is marked `@nodiscard` meaning the result should be kept. You can still discard it using a void cast (e.g. '(void)the_call()') if you want.");
			}
			if (expr.call_expr.has_optional_arg) return sema_expr_check_discard_error_args(context, expr);
			return true;
		default:
			break;
	}
	if (!@is_optional(expr))
	{
		if (expr.expr_kind == BINARY && expr.binary_expr.operator == EQ)
		{
			return @sema_error_at(context, expr.loc, "This equals check was discarded, which isn't allowed. You can assign it to a variable or explicitly ignore it with a void cast '(void)' if this is what you want.");
		}
		return true;
	}
	return @sema_error_at(context, expr.loc, "An optional value was discarded, you can assign it to a variable, ignore it with a void cast '(void)', rethrow on optional with '!' or panic '!!' to avoid this error.");
}

<* sema_expr_check_discard's `ERROR_ARGS:` label. *>
fn bool sema_expr_check_discard_error_args(SemaContext* context, Expr* expr) @local
{
	return @sema_error_at(context, expr.loc, "The result of this call is optional due to its argument(s). This optional result may not be implicitly discarded. Please assign it to a variable, ignore it with '(void)', rethrow with '!' or panic with '!!'.");
}

// sema_expr.c:13260
fn bool sema_analyse_expr_rvalue(SemaContext* context, Expr* expr)
{
	return sema_analyse_expr(context, expr) && sema_cast_rvalue(context, expr, true);
}

// sema_expr.c:13265
fn bool sema_cast_const(Expr* expr)
{
	assert(expr.resolve_status == DONE);
	switch (expr.expr_kind)
	{
		case TRY_UNRESOLVED: // UNRESOLVED_EXPRS
		case ACCESS_UNRESOLVED:
		case CATCH_UNRESOLVED:
		case UNRESOLVED_IDENTIFIER:
		case CAST:
		case TYPEID:
		case EMBED:
		case VASPLAT:
		case OTHER_CONTEXT:
		case VACOUNT:
		case VAARG:
		case IOTA_DECL:
		case LENGTHOF:
		case CT_IDENT:
		case TYPE_PROPERTY:
		case GENERIC_IDENT:
		case COMPOUND_LITERAL:
		case MACRO_BODY:
		case CT_SUBSCRIPT:
			unreachable();
		case RECAST:
			if (sema_cast_const(expr.inner_expr))
			{
				Type* type = expr.type;
				expr_replace(expr, expr.inner_expr);
				expr.type = type;
				return true;
			}
			return false;
		case ACCESS_RESOLVED:
		case BITACCESS:
			Expr* parent = expr.access_resolved_expr.parent;
			Type* flat = type_flatten(parent.type);
			if (!sema_cast_const(parent)) return false;
			switch (flat.type_kind)
			{
				case UNION:
				case UNTYPEDLIST:
				case STRUCT:
					break;
				case BITSTRUCT:
					if (!expr_is_const_initializer(parent)) return false;
				default:
					return false;
			}
			if (!sema_expr_fold_to_member(expr, parent, expr.access_resolved_expr.ref)) return false;
			return true;
		case SLICE:
			return false;
		case SUBSCRIPT:
			if (!expr_is_const(exprptr(expr.subscript_expr.index.expr))) return false;
			Expr* parent = exprptr(expr.subscript_expr.expr);
			Type* flat_type = type_flatten(parent.type);
			if (!sema_cast_const(parent)) return false;
			if (flat_type.type_kind != SLICE && !type_is_any_arraylike(flat_type) && flat_type.type_kind != UNTYPEDLIST) return false;
			return sema_expr_fold_to_index(expr, parent, expr.subscript_expr.index);
		case IDENTIFIER:
			sema_expr_flatten_const_ident(expr);
			return expr_is_const(expr);
		case CONST:
			return true;
		default:
			return false;
	}
}

// sema_expr.c:13324
fn bool sema_analyse_inferred_expr(SemaContext* context, Type* to, Expr* expr, bool* no_match_ref)
{
	Type* original_type = to;
	to = type_no_optional(to);
	// c3c `goto RETRY` -> `continue RETRY`.
	while RETRY: (true)
	{
		switch (expr.resolve_status)
		{
			case NOT_DONE:
				break;
			case RUNNING:
				@sema_error_at(context, expr.loc, "Recursive resolution of list.");
				return expr_poison(expr);
			case DONE:
				if (!sema_cast_rvalue(context, expr, true)) return false;
				if (to && expr.type != to)
				{
					cast_implicit_silent(context, expr, to, false);
				}
				return expr_ok(expr);
		}

		expr.resolve_status = RUNNING;
		switch (expr.expr_kind)
		{
			case HASH_IDENT:
				if (!sema_expr_fold_hash(context, expr)) return false;
				continue RETRY;
			case OTHER_CONTEXT:
				InliningSpan* new_span = context.inlined_at;
				context = expr.expr_other_context.context;
				InliningSpan* old_span = context.inlined_at;
				context.inlined_at = new_span;
				expr_replace(expr, expr.expr_other_context.inner);
				bool success = sema_analyse_inferred_expr(context, original_type, expr, no_match_ref);
				context.inlined_at = old_span;
				return success;
			case DESIGNATED_INITIALIZER_LIST:
			case INITIALIZER_LIST:
				if (!sema_expr_analyse_initializer_list(context, to, expr, no_match_ref)) return expr_poison(expr);
			case UNRESOLVED_IDENTIFIER:
				if (!sema_expr_analyse_identifier(context, to, expr, null)) return expr_poison(expr);
			case LAMBDA:
				if (!sema_expr_analyse_lambda(context, to, expr)) return expr_poison(expr);
			case BINARY:
				if (!sema_expr_analyse_binary(context, to, expr, null)) return expr_poison(expr);
			case TERNARY:
				if (!sema_expr_analyse_ternary(context, to, expr)) return expr_poison(expr);
			case VAARG:
				if (!sema_expr_analyse_vaarg(context, to, expr, no_match_ref)) return expr_poison(expr);
			case RETHROW:
				if (!sema_expr_analyse_rethrow(context, expr, original_type)) return expr_poison(expr);
			case CT_EVAL:
				if (!sema_expr_resolve_ct_eval(context, expr)) return expr_poison(expr);
				continue RETRY;
			case UNARY:
				if (to)
				{
					Type* canonical = to.canonical;
					switch (canonical.type_kind)
					{
						case POINTER:
							if (canonical == type_voidptr) break;
							if (expr.unary_expr.operator != TADDR) break;
							if (!sema_analyse_inferred_expr(context, type_get_indexed_type(to), expr.unary_expr.expr, null)) return expr_poison(expr);
						case CONSTSET:
							switch (expr.unary_expr.operator)
							{
								case ERROR:
								case DEREF:
								case ADDR:
								case NOT:
								case INC:
								case DEC:
								case TADDR:
									break;
								case NEG:
								case PLUS:
								case BITNEG:
									if (!sema_analyse_inferred_expr(context, to, expr.unary_expr.expr, null)) return expr_poison(expr);
							}
						default:
							break;
					}
				}
				nextcase default;
			default:
				if (!sema_analyse_expr_dispatch(context, expr)) return expr_poison(expr);
		}
		break;
	}
	if (!sema_cast_rvalue(context, expr, true)) return false;
	expr.resolve_status = DONE;
	return true;
}

// sema_expr.c:13432 (static)
fn TokenType sema_string_ident_token(String string, ArrayIndex len, String* interned_ref)
{
	TokenType normal = IDENT;
	TokenType const_token = CONST_IDENT;
	TokenType type_token = TYPE_IDENT;
	ArrayIndex i = 0;
	switch (len ? string[0] : 0)
	{
		case '@':
			normal = AT_IDENT;
			const_token = AT_CONST_IDENT;
			type_token = AT_TYPE_IDENT;
			i = 1;
		case '$':
			normal = CT_IDENT;
			const_token = CT_CONST_IDENT;
			type_token = CT_TYPE_IDENT;
			i = 1;
		case '#':
			normal = HASH_IDENT;
			const_token = INVALID_TOKEN;
			type_token = INVALID_TOKEN;
			i = 1;
		default:
			break;
	}
	TokenType type = INVALID_TOKEN;
	for (; i < len; i++)
	{
		char c = string[i];
		if (char_is_lower(c))
		{
			if (type == INVALID_TOKEN)
			{
				type = normal;
			}
			else if (type == const_token)
			{
				type = type_token;
			}
		}
		else if (char_is_upper(c))
		{
			if (type == INVALID_TOKEN) type = const_token;
		}
		else if (c != '_' && (!char_is_digit(c) || type == INVALID_TOKEN))
		{
			return INVALID_TOKEN;
		}
	}
	if (type == INVALID_TOKEN) return INVALID_TOKEN;
	// c3c hashes with fnv1a here; Symtab.find hashes itself.
	*interned_ref = symtab_find(string[:len], &type);
	return type;
}

// sema_expr.c:13484
fn TokenType sema_splitpathref(String string, ArrayIndex len, ModulePath** path_ref, String* ident_ref)
{
	*path_ref = null;
	*ident_ref = {};
	ArrayIndex ident_start = 0;
	for (ArrayIndex i = 0; i + 1 < len; i++)
	{
		if (string[i] != ':' || string[i + 1] != ':') continue;
		String segment;
		if (sema_string_ident_token(string[ident_start..], i - ident_start, &segment) != IDENT) return INVALID_TOKEN;
		ident_start = i + 2;
		i++;
	}
	if (ident_start) *path_ref = path_create_from_string(string, (uint)(ident_start - 2), 0);
	TokenType type = sema_string_ident_token(string[ident_start..], len - ident_start, ident_ref);
	switch (type)
	{
		case TYPE_IDENT:
		case IDENT:
		case CONST_IDENT:
		case AT_IDENT:
		case CT_TYPE_IDENT:
		case CT_IDENT:
		case HASH_IDENT:
		case VOID..UNTYPEDLIST:
			return type;
		default:
			*ident_ref = {};
			return INVALID_TOKEN;
	}
}

// sema_expr.c:13520
fn bool sema_insert_method_call(SemaContext* context, Expr* method_call, Decl* method_decl, Expr* parent, Expr*[] arguments, bool reverse_overload)
{
	SourceLocId original_loc = method_call.loc;
	Expr* resolve = method_call;
	// In this case we need to resolve the second argument first.
	if (reverse_overload)
	{
		if (!expr_is_const(parent))
		{
			Decl* temp = decl_new_generated_var(parent.type, LOCAL, parent.loc);
			Expr* generate = expr_generate_decl(temp, expr_copy(parent));
			parent.expr_kind = IDENTIFIER;
			parent.ident_expr = temp;
			parent.resolve_status = DONE;
			parent.type = temp.type;
			if (!sema_analyse_expr_rvalue(context, generate)) return false;
			Expr* copied_method = expr_copy(method_call);
			expr_rewrite_two(method_call, generate, copied_method);
			method_call = copied_method;
		}
		Expr* arg0 = arguments[0];
		arguments[0] = parent;
		parent = arg0;
	}
	*method_call = { .expr_kind = CALL,
			.loc = original_loc,
			.resolve_status = RUNNING,
			.call_expr = {
				.func_ref = declid(method_decl),
				.arguments = arguments,
				.is_func_ref = true,
				.is_type_method = true,
			}
	};
	Type* type = type_no_optional(parent.type).canonical;
	Decl* first_param = method_decl.func_decl.signature.params[0];
	Type* first = first_param.type.canonical;
	// Deref / addr as needed.
	if (type != first)
	{
		if (first.type_kind == POINTER && first.pointer == type)
		{
			expr_insert_addr(parent);
		}
		else if (type.type_kind == POINTER && type.pointer == first)
		{
			if (!sema_expr_rewrite_insert_deref(context, parent)) return false;
		}
	}
	assert(first == type_no_optional(parent.type).canonical);
	if (!sema_expr_analyse_general_call(context, method_call, method_decl, parent, false,
										null)) return expr_poison(method_call);
	method_call.resolve_status = DONE;
	if (resolve != method_call)
	{
		resolve.resolve_status = DONE;
		resolve.type = method_call.type;
	}
	return true;
}

// sema_expr.c:13579 (static)
fn bool sema_insert_binary_overload(SemaContext* context, Expr* expr, Decl* overload, Expr* lhs, Expr* rhs, bool reverse)
{
	Expr*[] args = {};
	@vec_add(&args, rhs);
	return sema_insert_method_call(context, expr, overload, lhs, args, reverse);
}

// sema_expr.c:13587
fn bool sema_bit_assignment_check(SemaContext* context, Expr* right, Decl* member, bool* failed_ref)
{
	// Don't check non-consts and non integers.
	if (!sema_cast_const(right) || !type_is_integer(right.type)) return true;

	int bits = member.var_decl.end_bit - member.var_decl.start_bit + 1;

	// If we have enough bits to fit, then we're done.
	if (bits >= type_bit_size(right.type) || int_is_zero(right.const_expr.ixx)) return true;

	if (int_bits_needed(right.const_expr.ixx) > bits)
	{
		if (failed_ref) { *failed_ref = true; return false; }
		return @sema_error_at(context, right.loc, "This constant would be truncated if stored in the "
								 "bitstruct, do you need a wider bit range?");
	}
	return true;
}
