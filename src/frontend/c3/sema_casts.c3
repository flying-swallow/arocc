// Port of c3c src/compiler/sema_casts.c (revision 54bab366a): implicit and
// explicit conversions, the cast rule / cast function tables.
//
// Deviations from c3c:
// - RETURN_CAST_ERROR(node, ...) is `return @sema_error_at(cc.context, node.loc, ...)`
//   (print_error_at + sema_print_inline, which is what sema_error_at does).
// - `goto RETRY` / `goto CHECK_SIZE` are restructured as labelled loops.
// - The local `may_cast` of rule_to_distinct is `may_cast_` (it shadows the fn).
// - `ldexp(1, n)` is the local helper `pow2`.
// - `cast_rules` / `cast_function` / `group_from_type` are positional tables
//   (C rows shorter than CONV_LAST + 1 are padded with null, C's implicit zero;
//   `group_from_type[TYPE_FUNC_RAW]`, missing in c3c, stays 0 = CONV_VOID).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;
import std::core::mem, std::math;

struct CastContext
{
	SemaContext* context;
	Expr* expr;
	Type* from;
	Type* to_type;
	Type* to;
	ConvGroup from_group;
	ConvGroup to_group;
	bool is_binary_conversion;
}

alias CastRule = fn bool(CastContext* cc, bool is_explicit, bool is_silent);
alias CastFunction = fn void(Expr* expr, Type* to_type);

<* Try to make an implicit cast. Optional types are allowed. *>
// sema_casts.c:49
fn bool cast_implicit(SemaContext* context, Expr* expr, Type* to_type, bool is_binary)
{
	return cast_if_valid(context, expr, to_type, false, false, is_binary);
}

<* Try to make an implicit cast. Optional types are allowed. *>
// sema_casts.c:57
fn bool cast_implicit_checked(SemaContext* context, Expr* expr, Type* to_type, bool is_binary, bool* failed_ref)
{
	if (failed_ref)
	{
		if (cast_if_valid(context, expr, to_type, false, true, is_binary)) return true;
		*failed_ref = true;
		return false;
	}
	return cast_if_valid(context, expr, to_type, false, false, is_binary);
}

// sema_casts.c:68
fn bool cast_implicit_binary(SemaContext* context, Expr* expr, Type* to_type, bool* failed_ref)
{
	return cast_implicit_checked(context, expr, to_type, true, failed_ref);
}

<* Try to make an explicit cast, Optional types are allowed. *>
// sema_casts.c:75
fn bool cast_explicit(SemaContext* context, Expr* expr, Type* to_type)
{
	return cast_if_valid(context, expr, to_type, true, false, false);
}

<* Try to make an explicit cast, Optional types are allowed. *>
// sema_casts.c:83
fn bool cast_explicit_checkable(SemaContext* context, Expr* expr, Type* to_type, bool* failed_ref)
{
	if (failed_ref)
	{
		if (cast_if_valid(context, expr, to_type, true, true, false)) return true;
		*failed_ref = true;
		return false;
	}
	return cast_if_valid(context, expr, to_type, true, false, false);
}

<* Try to make an explicit cast, Optional types are allowed. *>
// sema_casts.c:97
fn bool cast_explicit_silent(SemaContext* context, Expr* expr, Type* to_type)
{
	return cast_if_valid(context, expr, to_type, true, true, false);
}

<* Silent implicit casting will attempt a cast, but will silently back out if it fails. *>
// sema_casts.c:104
fn bool cast_implicit_silent(SemaContext* context, Expr* expr, Type* to_type, bool is_binary_conversion)
{
	return cast_if_valid(context, expr, to_type, false, true, is_binary_conversion);
}

// sema_casts.c:110
fn bool may_cast(SemaContext* context, Expr* expr, Type* to_type, bool is_explicit, bool is_silent)
{
	Type* from_type = expr.type.canonical;
	Type* to = to_type.canonical;
	CastContext cc = {
		.from_group = type_to_group(from_type),
		.from = from_type,
		.to_group = type_to_group(to),
		.to = to,
		.to_type = to_type,
		.expr = expr,
		.context = context,
	};
	return cast_is_allowed(&cc, is_explicit, is_silent);
}

// sema_casts.c:126 (static)
fn bool cast_is_allowed(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* from_type = cc.from;
	assert(from_type == from_type.canonical);
	// Check simple equality.
	from_type = from_type.canonical;
	if (from_type == cc.to) return true;

	// Make sure they have the same group.
	ConvGroup from_group = cc.from_group;
	ConvGroup to_group = cc.to_group;

	CastRule rule = (from_group == CONV_NO || to_group == CONV_NO) ? null : cast_rules[from_group][to_group];

	// No rule => no
	if (!rule)
	{
		if (is_silent) return false;
		if (type_is_inner_type(cc.to_type))
		{
			return @sema_error_at(cc.context, cc.expr.loc, "You cannot cast %s to the inner type %s.", type_quoted_error_string(cc.expr.type), type_quoted_error_string(cc.to_type));
		}

		Type* expr_type = type_no_optional(cc.expr.type);
		// Improve the error when incorrectly casting (char[])char*
		if (cc.to_type.type_kind == SLICE && expr_type.type_kind == POINTER && cc.to_type.array.base == expr_type.pointer)
		{
			return @sema_error_at(cc.context, cc.expr.loc, "You cannot cast %s to %s. However, you may slice the pointer with an explicit length to create a slice, e.g. 'foo_ptr[:len]'.", type_quoted_error_string(cc.expr.type), type_quoted_error_string(cc.to_type));
		}
		// (int[4])*int*
		if (cc.to_type.type_kind == ARRAY && cc.to_type.array.base == expr_type
			&& cc.expr.expr_kind == UNARY && cc.expr.unary_expr.operator == DEREF
			&& type_no_optional(cc.expr.unary_expr.expr.type).type_kind == POINTER && type_no_optional(cc.expr.unary_expr.expr.type).pointer == cc.to_type.array.base)
		{
			return @sema_error_at(cc.context, cc.expr.loc, "You cannot directly cast from a dereferenced %s to %s. "
			                      "However, you can could cast the pointer to the array before doing dereference, e.g. "
			                      "'*(%s*)foo'",
			                      type_quoted_error_string(cc.expr.unary_expr.expr.type), type_quoted_error_string(cc.to_type),
			                      type_to_error_string(cc.to_type));
		}
		if (cc.to_type.type_kind == ENUM && type_is_integer(expr_type))
		{
			return @sema_error_at(cc.context, cc.expr.loc, "It is not possible to cast %s to the enum %s, but you can use .from_ordinal() to convert it. E.g. '%s.from_ordinal(foo)'.",
			                      type_quoted_error_string(cc.expr.type),
			                      type_quoted_error_string(cc.to_type),
			                      type_to_error_string(cc.to_type));
		}
		return @sema_error_at(cc.context, cc.expr.loc, "You cannot cast %s to %s.", type_quoted_error_string(cc.expr.type), type_quoted_error_string(cc.to_type));
	}

	return rule(cc, is_explicit, is_silent);
}

<* Perform the cast with no additional checks. Casting from untyped not allowed. *>
// sema_casts.c:182
fn void cast_no_check(Expr* expr, Type* to_type, bool add_optional)
{
	Type* to = type_flatten(to_type);
	Type* from = type_flatten(expr.type);
	if (from == to)
	{
		expr.type = type_add_optional(to_type, add_optional);
		return;
	}
	ConvGroup to_group = type_to_group(to);
	ConvGroup from_group = type_to_group(from);
	CastFunction func = cast_function[from_group][to_group];
	if (func)
	{
		func(expr, to_type);
		expr.type = type_add_optional(expr.type, add_optional);
		return;
	}
	@error_exit("Missing cast function from %s to %s\n", type_quoted_error_string(expr.type), type_quoted_error_string(to_type));
}

<*
 Given lhs and rhs, promote to the maximum bit size, this will retain
 signed/unsigned type of each side.
*>
// sema_casts.c:207
fn void cast_to_int_to_max_bit_size(Expr* lhs, Expr* rhs, Type* left_type, Type* right_type)
{
	int bit_size_left = left_type.builtin.bitsize;
	int bit_size_right = right_type.builtin.bitsize;

	assert(bit_size_left && bit_size_right);

	// Simple case they are the same size, just return.
	if (bit_size_left == bit_size_right) return;

	// Lhs is smaller than rhs, so widen it using the right type
	if (bit_size_left < bit_size_right)
	{
		Type* to = lhs.type.type_kind < U8
		           ? type_int_signed_by_bitsize(bit_size_right)
		           : type_int_unsigned_by_bitsize(bit_size_right);
		cast_no_check(lhs, to, @is_optional(lhs));
		return;
	}

	// Rhs is smaller, do the same thing as above but with the rhs.
	Type* to = rhs.type.type_kind < U8
	           ? type_int_signed_by_bitsize(bit_size_left)
	           : type_int_unsigned_by_bitsize(bit_size_left);
	cast_no_check(rhs, to, @is_optional(rhs));
}

<*
 Perform vararg promotions typical for C style varargs:
 1. Widen int and bool to C int size
 2. Widen float and smaller to double
 3. Turn slices into pointers
*>
// sema_casts.c:241
fn void cast_promote_vararg(Expr* arg)
{
	// Remove things like distinct, optional, enum etc.
	Type* arg_type = type_flatten(arg.type);

	// 1. Promote any integer or bool to at least CInt
	if (type_is_promotable_int_bool(arg_type))
	{
		cast_no_check(arg, type_cint, @is_optional(arg));
		return;
	}

	// 2. Promote any float to at least double
	if (type_is_promotable_float(arg_type))
	{
		cast_no_check(arg, type_double, @is_optional(arg));
		return;
	}

	// 3. Turn slices into pointers
	if (arg_type.type_kind == SLICE)
	{
		cast_no_check(arg, type_get_ptr(arg_type.array.base), @is_optional(arg));
	}

	// We convert non-simd vectors to arrays
	if (arg_type.type_kind == VECTOR)
	{
		cast_no_check(arg, type_array_from_vector(arg_type), @is_optional(arg));
	}
}

<* General error due to casts. *>
// sema_casts.c:277
fn bool sema_error_failed_cast(SemaContext* context, Expr* expr, Type* from, Type* to)
{
	return @sema_error_at(context, expr.loc, "The cast %s to %s is not allowed.", type_quoted_error_string(from), type_quoted_error_string(to));
}

<* Create a type by inferring the length. *>
// sema_casts.c:285 (static)
fn Type* type_infer_len_from_actual_type(Type* to_infer, Type* actual_type)
{
	// This may be called on types not inferable,
	// if so we assume the original type
	if (!type_len_is_inferred(to_infer)) return to_infer;

	// Handle int[*]? a = { ... } by stripping the optional.
	bool is_optional = type_is_optional(to_infer);

	// c3c: assert(is_optional || !type_is_optional(actual_type), "int[*] x = { may_fail } should have been caught."); -- C assert, compiled out in c3c release builds

	// Strip the optional
	if (is_optional) to_infer = to_infer.optional;

	// And from the actual type.
	actual_type = type_no_optional(actual_type);

	Type* actual = type_get_indexed_type(actual_type);
	if (!actual) return actual_type;

	// Grab the underlying indexed type,
	// because we can only have [*] [] [<*>] [<>] * here
	Type* indexed = type_get_indexed_type(to_infer);

	// We should always have indexed types.
	assert(indexed);

	// The underlying type may also be inferred.
	// In this case, infer it.
	if (type_len_is_inferred(indexed))
	{
		// if we have int[*][*] => the inner is int[*], we cast it here.
		indexed = type_infer_len_from_actual_type(indexed, actual);
	}

	// Construct the real type
	switch (to_infer.type_kind)
	{
		case POINTER:
			// The case of int[*]* x = ...
			return type_add_optional(type_get_ptr(indexed), is_optional);
		case ARRAY:
			// The case of int[*][2] x = ...
			return type_add_optional(type_get_array(indexed, to_infer.array.len), is_optional);
		case INFERRED_ARRAY:
			if (!type_is_arraylike(type_flatten(actual_type))) return to_infer;
			return type_add_optional(type_get_array(indexed, type_flatten(actual_type).array.len), is_optional);
		case INFERRED_VECTOR:
			if (!type_is_arraylike(type_flatten(actual_type))) return to_infer;
			return type_add_optional(type_get_vector(indexed, VECTOR, (int)type_flatten(actual_type).array.len), is_optional);
		case SLICE:
			return type_add_optional(type_get_slice(indexed), is_optional);
		case VECTOR:
		case SIMD_VECTOR:
			// The case of int[*]*[<2>] x = ...
			return type_add_optional(type_get_vector(indexed, to_infer.type_kind, (int)to_infer.array.len), is_optional);
		default:
			unreachable();
	}
}

// sema_casts.c:345 (static)
fn bool cast_if_valid(SemaContext* context, Expr* expr, Type* to_type, bool is_explicit, bool is_silent, bool is_binary_conversion)
{
	if (expr.expr_kind == OPERATOR_CHARS)
	{
		if (is_silent) return false;
		return @sema_error_at(context, expr.loc, "Operators may not be used outside of operator attributes.");
	}
	if (expr.expr_kind == CALL && expr.call_expr.no_return)
	{
		expr.type = to_type;
		return true;
	}
	Type* from_type = expr.type;

	if (from_type == to_type) return true;

	bool is_void_silence = type_is_void(to_type) && is_explicit;
	bool add_optional = type_is_optional(to_type) || type_is_optional(from_type);
	from_type = type_no_optional(from_type);
	to_type = type_no_optional(to_type);

	if (is_void_silence && from_type != type_untypedlist)
	{
		expr_rewrite_discard(expr);
		return true;
	}

	from_type = from_type.canonical;
	Type* to = to_type.canonical;
	CastContext cc = {
		.is_binary_conversion = is_binary_conversion,
		.from_group = type_to_group(from_type),
		.from = from_type,
		.to_group = type_to_group(to),
		.to = to,
		.to_type = to_type,
		.expr = expr,
		.context = context,
	};
	if (!sema_resolve_type_decl(context, to)) return false;
	if (!cast_is_allowed(&cc, is_explicit, is_silent))
	{
		return false;
	}

	cast_no_check(expr, to_type, add_optional);
	return true;
}

// sema_casts.c:395 (static)
fn bool may_convert_int_float(CanonicalType* from, CanonicalType* to)
{
	// c3c: assert(from.canonical == from && to.canonical == to); -- C assert, compiled out in c3c release builds
	if (from == to) return true;
	if (type_is_float(from))
	{
		// float16 and bfloat have the same size but neither contains the other.
		if (type_is_float(to) && type_size(from) == type_size(to)) return false;
		return type_size(from) <= type_size(to);
	}
	if (type_is_signed(from))
	{
		if (!type_is_signed(to)) return false;
		return type_size(from) <= type_size(to);
	}
	if (type_is_signed(to))
	{
		return type_size(from) < type_size(to);
	}
	return type_size(from) <= type_size(to);
}

<*
 Check whether an expression may narrow.
 1. If it has an intrinsic type, then compare it against the type. If the bitwidth is smaller or same => ok
 2. If it is a constant, then if it fits in the type it is ok.
 3. If it has sub expressions, recursively check those if they affect the type.
 4. Widening casts are ignored, all other casts are opaque.
*>
// sema_casts.c:424 (static)
fn Expr* recursive_may_narrow(Expr* expr, Type* type)
{
	while RETRY: (true)
	{
		switch (expr.expr_kind)
		{
			case RECAST:
				expr = expr.inner_expr;
				continue RETRY;
			case BITASSIGN:
			case BINARY:
				switch (expr.binary_expr.operator)
				{
					case ERROR:
						unreachable();
					case SUB:
						if (type_is_pointer_type(exprptr(expr.binary_expr.right).type)) return expr;
						nextcase MULT;
					case MULT:
					case ADD:
					case DIV:
					case MOD:
					case BIT_OR:
					case BIT_XOR:
					case BIT_AND:
					case ELSE:
						// *, -, +, /, %, |, ^, &, ?? -> check both sides.
						Expr* res = recursive_may_narrow(exprptr(expr.binary_expr.left), type);
						if (res) return res;
						expr = exprptr(expr.binary_expr.right);
						continue RETRY;
					case SHR:
					case SHL:
					case ASSIGN:
					case ADD_ASSIGN:
					case BIT_AND_ASSIGN:
					case BIT_OR_ASSIGN:
					case BIT_XOR_ASSIGN:
					case DIV_ASSIGN:
					case MOD_ASSIGN:
					case MULT_ASSIGN:
					case SHR_ASSIGN:
					case SHL_ASSIGN:
					case SUB_ASSIGN:
						// For shifts and assignment, ignore the right hand side.
						expr = exprptr(expr.binary_expr.left);
						continue RETRY;
					case AND:
					case OR:
					case GT:
					case GE:
					case LT:
					case LE:
					case NE:
					case EQ:
						return null;
					case CT_OR:
					case CT_AND:
					case CT_CONCAT:
					case CT_CONCAT_ASSIGN:
						// This should be folded already.
						unreachable();
					case VEC_GT:
					case VEC_GE:
					case VEC_LT:
					case VEC_LE:
					case VEC_NE:
					case VEC_EQ:
						// Functions
						return null;
				}
			case SLICE_LEN:
				if (type_size(type) < type_size(type_cint)) return expr;
				return null;
			case BUILTIN_ACCESS:
				switch (expr.builtin_access_expr.kind)
				{
					case TYPEOFANYFAULT:
					case TYPEOFANY:
					case ENUMNAME:
					case FAULTNAME:
						// For the rest, just check size.
						break RETRY;
				}
			case EXPRESSION_LIST:
				// Only the last expression counts for narrowing.
				// It's unclear if this can happen.
				expr = @veclast(expr.expression_list);
				continue RETRY;
			case TWO:
				expr = expr.two_expr.last;
				continue RETRY;
			case TERNARY:
				// In the case a ?: b -> check a and b
				// In the case a ? b : c -> check b and c
				Expr* res = recursive_may_narrow(exprptr(expr.ternary_expr.then_expr
						? expr.ternary_expr.then_expr
						: expr.ternary_expr.cond), type);
				if (res) return res;
				expr = exprptr(expr.ternary_expr.else_expr);
				continue RETRY;
			case EXT_TRUNC:
				if (may_convert_int_float(type_flatten(expr.type), type)) return null;
				// Otherwise just look through it.
				expr = expr.ext_trunc_expr.inner;
				continue RETRY;
			case CAST:
				unreachable();
			case CONST:
				// For constants, just check that they will fit.
				switch (expr.const_expr.const_kind)
				{
					case ENUM:
					case INTEGER:
						if (expr_const_will_overflow(&expr.const_expr, type_flatten(type).type_kind))
						{
							return expr;
						}
						return null;
					case FLOAT:
						if (!expr_const_float_fits_type(&expr.const_expr, type_flatten(type).type_kind))
						{
							return expr;
						}
						return null;
					default:
						break RETRY;
				}
			case POST_UNARY:
				expr = expr.unary_expr.expr;
				continue RETRY;
			case FORCE_UNWRAP:
				expr = expr.inner_expr;
				continue RETRY;
			case RETHROW:
				expr = expr.rethrow_expr.inner;
				continue RETRY;
			case UNARY:
				switch (expr.unary_expr.operator)
				{
					case ADDR:
					case TADDR:
						return expr;
					case ERROR:
						unreachable();
					case DEREF:
						// Check sizes.
						break RETRY;
					case PLUS:
					case NEG:
					case BITNEG:
					case INC:
					case DEC:
						expr = expr.unary_expr.expr;
						continue RETRY;
					case NOT:
						break RETRY;
				}
			default:
				// Check type sizes
				break;
		}
		break;
	}
	// CHECK_SIZE:
	if (may_convert_int_float(type_flatten(expr.type), type)) return null;
	return expr;
}

// sema_casts.c:602 (static)
fn bool sema_error_const_int_out_of_range(CastContext* cc, Expr* expr, Expr* problem, Type* to_type)
{
	assert(expr_is_const(expr));
	if (expr.const_expr.is_character && expr.type.type_kind != U128)
	{
		return @sema_error_at(cc.context, problem.loc, "The unicode character U+%04x cannot fit in a %s.", (uint)expr.const_expr.ixx.i, type_quoted_error_string(to_type));
	}
	if (expr.const_expr.const_kind == ENUM)
	{
		return @sema_error_at(cc.context, problem.loc, "The ordinal '%d' is out of range for %s, so you need an explicit cast to truncate the value.",
		                      expr.const_expr.enum_val.var_decl.index,
		                      type_quoted_error_string(to_type));
	}
	return @sema_error_at(cc.context, problem.loc, "The value '%s' is out of range for %s, so you need an explicit cast to truncate the value.",
	                      expr_const_to_error_string(&expr.const_expr), type_quoted_error_string(to_type));
}

<* Recursively change a const list to an initializer list. *>
// sema_casts.c:624 (static)
fn void expr_recursively_rewrite_untyped_list(Expr* expr, Type* to_type)
{
	assert(expr_is_const_untyped_list(expr));
	expr.expr_kind = CONST;
	Expr*[] values = expr.const_expr.untyped_list;
	int count = (int)values.len;
	ConstInitializer*[] elements = {};
	Type* flat = type_flatten(to_type);
	bool is_slice = flat.type_kind == SLICE;
	if (type_is_infer_type(flat))
	{
		// c3c: assert(values.len > 0); -- C assert, compiled out in c3c release builds
		to_type = type_from_inferred(flat, type_get_indexed_type(to_type), (int)values.len);
		flat = type_flatten(to_type);
	}
	// Handle {}
	if (!count)
	{
		if (is_slice)
		{
			expr_rewrite_const_slice(expr, to_type, null);
			return;
		}
		expr_rewrite_const_initializer(expr, to_type, const_init_new_zero(flat));
		return;
	}
	switch (flat.type_kind)
	{
		case VECTOR:
		case SIMD_VECTOR:
			Type* indexed = type_get_indexed_type(to_type);
			foreach (e : values)
			{
				@vec_add(&elements, const_init_new_value(e));
				cast_no_check(e, indexed, false);
			}
			expr_rewrite_const_initializer(expr, to_type, const_init_new_array_full(flat, elements));
			return;
		case SLICE:
		case ARRAY:
			Type* indexed = type_get_indexed_type(to_type);
			foreach (e : values)
			{
				if (e.type == type_untypedlist)
				{
					expr_recursively_rewrite_untyped_list(e, indexed);
				}
				cast_no_check(e, indexed, false);
				@vec_add(&elements, const_init_new_value(e));
			}
			if (is_slice)
			{
				expr_rewrite_const_slice(expr, to_type, const_init_new_array_full(type_get_array(indexed, count), elements));
				return;
			}
			expr_rewrite_const_initializer(expr, to_type, const_init_new_array_full(to_type, elements));
			return;
		case STRUCT:
		case BITSTRUCT:
			break;
		default:
			unreachable();
	}
	Decl* decl = flat.decl;
	Decl*[] members = decl.strukt.members;

	foreach (idx, e : values)
	{
		Type* type = members[idx].type;
		if (e.type == type_untypedlist)
		{
			expr_recursively_rewrite_untyped_list(e, type);
		}
		cast_no_check(e, type, false);
	}
	expr_rewrite_const_initializer(expr, to_type, const_init_new_struct(flat, values));
}

// sema_casts.c:706
fn bool cast_to_index_len(SemaContext* context, Expr* index, bool is_len)
{
	Type* type = index.type;
	type = type_no_optional(type);
	type = type_flat_distinct_enum_inline(type);
	switch (type.type_kind)
	{
		case I8:
		case I16:
		case I32:
		case I64:
			if (!sema_check_array_index(context, index, is_len)) return false;
			return cast_explicit(context, index, type_sz);
		case U8:
		case U16:
		case U32:
		case U64:
			if (!sema_check_array_index(context, index, is_len)) return false;
			if (!cast_explicit(context, index, type_usz)) return false;
			return cast_explicit(context, index, type_sz);
		case U128:
			return @sema_error_at(context, index.loc, "You need to explicitly cast this to a uint or ulong.");
		case I128:
			return @sema_error_at(context, index.loc, "You need to explicitly cast this to an int or long.");
		case ENUM:
			return cast_explicit(context, index, type_sz);
		default:
			return @sema_error_at(context, index.loc, "An integer value was expected here, but it is a value of type %s, which can't be implicitly converted into an integer %s.",
			                      type_quoted_error_string(index.type), is_len ? "length" : "index");
	}
}

// sema_casts.c:738
fn Type* cast_numeric_arithmetic_promotion(Type* type)
{
	if (!type || type == poisoned_type) return type;
	Type* canonical = type.canonical;
	switch (canonical.type_kind)
	{
		case I8:
		case I16:
		case I32:
		case I64:
		case I128:
		case U8:
		case U16:
		case U32:
		case U64:
		case U128:
			if (canonical.builtin.bitsize < compiler.platform.width_c_int) return type_cint;
			return type;
		case BF16:
		case F16:
			// Promote F16 to a real type.
			return type_float;
		case OPTIONAL:
			unreachable();
		default:
			return type;
	}
}

// sema_casts.c:759 (static)
fn bool report_cast_error(CastContext* cc, bool may_cast_explicit)
{
	Expr* expr = cc.expr;
	Type* to = cc.to_type;
	if (type_is_inner_type(to))
	{
		if (may_cast_explicit)
		{
			return @sema_error_at(cc.context, expr.loc,
			                      "Implicitly casting %s to the inner type %s is not permitted, but you may do an explicit cast by placing '($Typefrom(%s.typeid))' before the expression.",
			                      type_quoted_error_string(type_no_optional(expr.type)),
			                      type_quoted_error_string(to),
			                      type_to_error_string(type_no_optional(to)));
		}
		return @sema_error_at(cc.context, expr.loc,
		                      "It is not possible to cast %s to the inner type %s.",
		                      type_quoted_error_string(type_no_optional(expr.type)), type_quoted_error_string(to));
	}
	Type* expr_type = type_no_optional(expr.type).canonical;
	TypeKind type_kind = expr_type.type_kind;
	if (may_cast_explicit)
	{
		Type* typeto = type_no_optional(to);
		Type* from = type_no_optional(expr.type);
		if (type_kind == TYPEDEF && type_no_optional(to).canonical.type_kind == TYPEDEF)
		{
			return @sema_error_at(cc.context, expr.loc,
			                      "Implicitly casting %s to %s is not permitted. It's possible to do an explicit cast by placing '(%s)' before the expression. However, explicit casts between distinct types are usually not intended and are not safe.",
			                      type_quoted_error_string_maybe_with_path(from, typeto),
			                      type_quoted_error_string_maybe_with_path(to, from),
			                      type_error_string_maybe_with_path(typeto, from));
		}
		return @sema_error_at(cc.context, expr.loc,
		                      "Implicitly casting %s to %s is not permitted, but you may do an explicit cast by placing '(%s)' before the expression.",
		                      type_quoted_error_string_maybe_with_path(from, typeto),
		                      type_quoted_error_string_maybe_with_path(to, from),
		                      type_error_string_maybe_with_path(typeto, from));
	}
	if (to.type_kind == INTERFACE && type_kind != POINTER)
	{
		return @sema_error_at(cc.context, expr.loc,
		                      "You can only convert pointers to an interface like %s. "
		                      "Try passing the address of the expression instead.",
		                      type_quoted_error_string(to));
	}
	if (to.type_kind == ANY && type_kind != POINTER)
	{
		return @sema_error_at(cc.context, expr.loc, "You can only convert pointers to 'any'. "
		                      "Try passing the address of the expression instead.");
	}
	// Improve the error when incorrectly casting (String)ZString
	if (to == type_string && str_eq(expr_type.name, "ZString"))
	{
		return @sema_error_at(cc.context, expr.loc, "It is not possible to cast a ZString to a String but you can use .str_view() to do the conversion. E.g. 'my_zstring.str_view()'.");
	}
	if (type_kind == ENUM && type_is_integer(to))
	{
		if (to == enum_inner_type(expr_type))
		{
			return @sema_error_at(cc.context, expr.loc, "It is not possible to implicitly cast the enum %s to %s, but you can use an explicit cast or .ordinal to get the ordinal value. E.g. 'my_enum.ordinal'.",
			                      type_quoted_error_string(type_no_optional(expr.type)),
			                      type_quoted_error_string(type_no_optional(to)));
		}
		return @sema_error_at(cc.context, expr.loc, "It is not possible to implicitly cast the enum %s to %s, but you can use an explicit cast or .ordinal to get the ordinal and cast it. E.g. '(%s)my_enum.ordinal'.",
		                      type_quoted_error_string(type_no_optional(expr.type)),
		                      type_quoted_error_string(type_no_optional(to)),
		                      type_to_error_string(type_no_optional(to)));
	}
	return @sema_error_at(cc.context, expr.loc,
	                      "It is not possible to cast %s to %s.",
	                      type_quoted_error_string(type_no_optional(expr.type)), type_quoted_error_string(to));
}

// sema_casts.c:833 (static)
fn bool sema_cast_error(CastContext* cc, bool may_cast_explicit, bool is_silent)
{
	if (is_silent) return false;
	report_cast_error(cc, may_cast_explicit);
	return false;
}

// RULES ----

// sema_casts.c:842 (static)
fn TypeCmpResult match_pointers(CastContext* cc, Type* to_ptr, Type* from_ptr, bool flatten)
{
	return type_is_pointer_equivalent(cc.context, to_ptr, from_ptr, flatten);
}

// sema_casts.c:847 (static)
fn bool rule_voidptr_to_any(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (expr_is_const_pointer(cc.expr) && !cc.expr.const_expr.ptr) return true;
	if (is_silent) return false;
	return @sema_error_at(cc.context, cc.expr.loc,
	                      "Casting a 'void*' to %s is not permitted (except when the 'void*' is a constant null).",
	                      type_quoted_error_string(cc.to));
}

// sema_casts.c:856 (static)
fn bool rule_ptr_to_ptr(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (is_explicit) return true;
	switch (match_pointers(cc, cc.to, cc.from, false))
	{
		case TYPE_SAME:
			return true;
		case TYPE_ERROR:
			return false;
		case TYPE_ALIGNMENT_INCREASE:
			if (is_silent) return false;
			return @sema_error_at(cc.context, cc.expr.loc,
			                      "Implicitly casting %s (alignment %d) to %s (alignment %d) is not permitted, "
			                      "it would require an explicit cast. Before using an explicit cast, please make "
			                      "sure you understand the ramifications as the explicit cast might crash your program if used incorrectly.",
			                      type_quoted_error_string(type_no_optional(cc.expr.type)),
			                      type_abi_alignment(type_get_indexed_type(cc.expr.type)),
			                      type_quoted_error_string(cc.to),
			                      type_abi_alignment(type_get_indexed_type(cc.to)));
		case TYPE_MISMATCH:
		case TYPE_SAME_INT_SIZE:
			return sema_cast_error(cc, true, is_silent);
	}
	unreachable();
}

// sema_casts.c:883 (static)
fn bool rule_all_ok(CastContext* cc, bool is_explicit, bool silent)
{
	return true;
}

// sema_casts.c:888 (static)
fn bool rule_int_to_ptr(CastContext* cc, bool is_explicit, bool is_silent)
{
	// Handle const:
	Expr* expr = cc.expr;
	if (sema_cast_const(expr))
	{
		if (!is_explicit) return sema_cast_error(cc, true, is_silent);

		// For if the type doesn't fit, insert an error.
		Int i = expr.const_expr.ixx;
		if (!int_fits(i, type_uptr.canonical.type_kind))
		{
			if (is_silent) return false;
			return @sema_error_at(cc.context, expr.loc, "'%s' does not fit in a pointer.", int_to_str(i, 16, true));
		}
		return true;
	}

	// A non-constant integer must be exactly the size of a pointer.
	if (type_size(cc.from) < type_size(type_uptr))
	{
		if (is_silent) return false;
		if (is_explicit)
		{
			return @sema_error_at(cc.context, expr.loc, "You cannot convert an integer smaller than pointer size to a pointer, "
			                      "try first widening it to pointer size, for example write '(%s)(uptr)some_value' instead.", type_to_error_string(cc.to));
		}
		return @sema_error_at(cc.context, expr.loc, "You cannot implicitly convert an integer to a pointer, you may use an explicit cast "
		                      "if you first widen the value to pointer size, e.g. '(%s)(uptr)some_value'.", type_to_error_string(cc.to));
	}
	if (type_size(cc.from) > type_size(type_uptr))
	{
		if (is_silent) return false;
		if (is_explicit)
		{
			return @sema_error_at(cc.context, expr.loc, "You cannot convert an integer larger than pointer size to a pointer, "
			                      "try first narrowing it to pointer size, for example write '(%s)(uptr)some_value' instead.", type_to_error_string(cc.to));
		}
		return @sema_error_at(cc.context, expr.loc, "You cannot implicitly convert an integer to a pointer, you may use an explicit cast "
		                      "if you first narrow the value to pointer size, e.g. '(%s)(uptr)some_value'.", type_to_error_string(cc.to));
	}

	if (!is_explicit) return sema_cast_error(cc, true, is_silent);

	return true;
}

// sema_casts.c:936 (static)
fn bool rule_ptr_to_int(CastContext* cc, bool is_explicit, bool is_silent)
{
	bool too_small = type_size(cc.to) < type_size(type_uptr);
	if (!is_explicit) return sema_cast_error(cc, !too_small, is_silent);

	// The type must be uptr or bigger.
	if (too_small)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "Casting %s to %s is not allowed because '%s' is smaller than a pointer. "
		                      "Use (%s)(iptr) if you want this lossy cast.",
		                      type_quoted_error_string(cc.expr.type), type_quoted_error_string(cc.to_type),
		                      type_to_error_string(cc.to_type), type_to_error_string(cc.to_type));
	}
	return true;
}

// sema_casts.c:953 (static)
fn bool rule_arrptr_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* slice_base = cc.to.array.base;
	Type* from_base = cc.from.pointer.array.base;

	// int[<2>]*, int[2]*
	if (is_explicit)
	{
		slice_base = type_flatten(slice_base);
		from_base = type_flatten(from_base);
	}
	// Same base type? E.g. int[2]* -> int[], then we're done.
	if (from_base == slice_base)
	{
		return true;
	}

	if (slice_base.type_kind == POINTER && from_base.type_kind == POINTER)
	{
		switch (match_pointers(cc, slice_base, from_base, is_explicit))
		{
			case TYPE_SAME:
				return true;
			case TYPE_SAME_INT_SIZE:
				if (is_explicit) return true;
			case TYPE_ALIGNMENT_INCREASE:
				if (is_explicit) return true;
				if (is_silent) return false;
				return @sema_error_at(cc.context, cc.expr.loc,
				                      "Implicitly casting %s (with element alignment %d) to %s (element alignment %d) is not permitted – "
				                      "it would require an explicit cast. Before using an explicit cast, please make "
				                      "sure you understand the ramifications as the explicit cast might crash your program if used incorrectly.",
				                      type_quoted_error_string(type_no_optional(cc.expr.type)),
				                      type_abi_alignment(type_get_indexed_type(from_base)),
				                      type_quoted_error_string(cc.to),
				                      type_abi_alignment(type_get_indexed_type(slice_base)));
			case TYPE_ERROR:
				return false;
			case TYPE_MISMATCH:
				break;
			default:
				unreachable();
		}
	}
	bool may_explicit = !is_silent && rule_arrptr_to_slice(cc, true, true);
	return sema_cast_error(cc, may_explicit, is_silent);
}

// sema_casts.c:1003 (static)
fn bool rule_ulist_to_struct(CastContext* cc, bool is_explicit, bool is_silent)
{
	assert(expr_is_const_untyped_list(cc.expr));
	Expr*[] expressions = cc.expr.const_expr.untyped_list;
	int size = (int)expressions.len;
	if (!size) return true;
	Decl* strukt = cc.to.decl;
	Decl*[] members = strukt.strukt.members;
	if (size != members.len)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "%s may only be initialized with 0 elements or %d, not %d.",
		                      type_quoted_error_string(cc.to_type),
		                      members.len, size);
	}
	if (!sema_analyse_decl(cc.context, strukt)) return false;
	foreach (i, expr : expressions)
	{
		if (!may_cast(cc.context, expr, members[i].type, false, is_silent)) return false;
	}
	return true;
}

// sema_casts.c:1026 (static)
fn bool rule_ulist_to_vecarr(CastContext* cc, bool is_explicit, bool is_silent)
{
	Expr*[] expressions = cc.expr.const_expr.untyped_list;
	int size = (int)expressions.len;
	if (!size) return true;
	if (size != cc.to.array.len)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "%s may only be initialized with 0 elements or %d, not %d.",
		                      type_quoted_error_string(cc.to_type),
		                      cc.to.array.len, size);
	}
	Type* base = cc.to.array.base;
	foreach (expr : expressions)
	{
		if (!may_cast(cc.context, expr, base, false, is_silent)) return false;
	}
	return true;
}

// sema_casts.c:1046 (static)
fn bool rule_ulist_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	assert(expr_is_const_untyped_list(cc.expr));
	Type* base = cc.to.array.base;
	foreach (expr : cc.expr.const_expr.untyped_list)
	{
		if (!may_cast(cc.context, expr, base, false, is_silent)) return false;
	}
	return true;
}

// sema_casts.c:1057 (static)
fn bool rule_ulist_to_inferred(CastContext* cc, bool is_explicit, bool is_silent)
{
	Expr*[] expressions = cc.expr.const_expr.untyped_list;
	int size = (int)expressions.len;
	if (!size)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "This untyped list would infer to a zero elements, which is not allowed.");
	}
	Type* base = cc.to.array.base;
	bool is_infer = type_is_infer_type(base);
	ArrayIndex inferred_len = -1;
	foreach (expr : expressions)
	{
		if (!may_cast(cc.context, expr, base, false, true))
		{
			if (is_silent) return false;
			return @sema_error_at(cc.context, cc.expr.loc, "This untyped list contained an element of type %s which could not be converted to %s.",
			                      type_quoted_error_string(expr.type), type_quoted_error_string(base));
		}
		if (is_infer)
		{
			ArrayIndex len = sema_len_from_const(expr);
			if (len == 0) continue;
			if (inferred_len < 0)
			{
				inferred_len = len;
			}
			else
			{
				if (inferred_len != len)
				{
					if (is_silent) return false;
					return @sema_error_at(cc.context, cc.expr.loc, "This untyped list contains elements that have different lengths, so it is not possible to infer the length for %s.",
					                      type_quoted_error_string(cc.to_type));
				}
			}
		}
	}
	if (is_infer && inferred_len < 0)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "This untyped list would infer to a zero elements, which is not allowed.");
	}
	return true;
}

// sema_casts.c:1104 (static)
fn bool rule_slice_to_ptr(CastContext* cc, bool is_explicit, bool is_silent)
{
	// Explicitly, like for any pointer.
	if (is_explicit) return true;
	Type* slice_base = cc.from.array.base;
	// A slice is also convertible to `Type[N]*` if it is known to be N long.
	Type* to_pointee = cc.to.pointer;
	TypeCmpResult cmp;
	if (to_pointee.type_kind == ARRAY && to_pointee.array.len == sema_len_from_const(cc.expr))
	{
		cmp = type_array_element_is_equivalent(cc.context, to_pointee.array.base, slice_base, false);
	}
	else
	{
		cmp = match_pointers(cc, cc.to, type_get_ptr(slice_base), false);
	}
	switch (cmp)
	{
		case TYPE_SAME:
			return true;
		case TYPE_SAME_INT_SIZE:
			if (expr_is_const_string(cc.expr)) return true;
		case TYPE_ERROR:
			return false;
		case TYPE_MISMATCH:
			break;
		case TYPE_ALIGNMENT_INCREASE:
			if (is_silent) return false;
			return @sema_error_at(cc.context, cc.expr.loc,
			                      "Implicitly casting %s to %s (which has a different element alignment) is not permitted – "
			                      "it would require an explicit cast. Before using an explicit cast, please make "
			                      "sure you understand the ramifications as the explicit cast might crash your program if used incorrectly.",
			                      type_quoted_error_string(type_no_optional(cc.expr.type)),
			                      type_quoted_error_string(cc.to));
		default:
			unreachable();
	}
	return sema_cast_error(cc, true, is_silent);
}

// sema_casts.c:1145 (static)
fn bool rule_slice_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* from_type = cc.from;
	Type* from_base = from_type.array.base;
	Type* array_base = cc.to.array.base;

	// Same base type? Ok
	if (from_base.canonical == array_base.canonical) return true;

	switch (type_array_element_is_equivalent(cc.context, array_base, from_base, is_explicit))
	{
		case TYPE_ERROR:
			return false;
		case TYPE_SAME_INT_SIZE:
			// Signed <-> unsigned needs an explicit cast, as it does for `int` -> `uint` and `int*` -> `uint*`.
			// A constant string or bytes is text, which may be stored in any one byte integer.
			if (is_explicit || expr_is_const_string(cc.expr) || expr_is_const_bytes(cc.expr)) return true;
			nextcase TYPE_MISMATCH;
		case TYPE_MISMATCH:
		case TYPE_ALIGNMENT_INCREASE:
			if (is_silent) return false;
			return sema_cast_error(cc, is_explicit ? false : rule_slice_to_slice(cc, true, true), is_silent);
		case TYPE_SAME:
			return true;
	}
	unreachable();
}

// sema_casts.c:1174 (static)
fn bool rule_arr_to_arr(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (!rule_slice_to_slice(cc, is_explicit, is_silent)) return false;
	if (type_flatten(cc.to).array.len != type_flatten(cc.from).array.len)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "Arrays of different lengths may not be converted.");
	}
	return true;
}

// sema_casts.c:1185 (static)
fn bool rule_arr_to_vec(CastContext* cc, bool is_explicit, bool is_silent)
{
	ArrayIndex len = cc.from.array.len;
	if (len != cc.to.array.len) return sema_cast_error(cc, false, is_silent);
	Type* base = cc.from.array.base;
	switch (type_to_group(type_flatten(base)))
	{
		case CONV_BOOL:
		case CONV_INT:
		case CONV_FLOAT:
		case CONV_POINTER:
		case CONV_ENUM:
		case CONV_TYPEID:
		case CONV_ANYFAULT:
		case CONV_VOIDPTR:
		case CONV_VAPTR:
			break;
		default:
			return sema_cast_error(cc, false, is_silent);
	}
	cast_context_set_from(cc, type_get_vector(base, cc.to.type_kind, (int)len));
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1209 (static)
fn bool rule_vec_to_arr(CastContext* cc, bool is_explicit, bool is_silent)
{
	ArrayIndex len = cc.from.array.len;
	if (len != cc.to.array.len) return sema_cast_error(cc, false, is_silent);
	Type* base = cc.from.array.base;
	cast_context_set_from(cc, type_get_array(base, len));
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1218 (static)
fn bool rule_vecarr_to_slice(CastContext* cc, bool is_explicit, bool is_silent)
{
	Expr* expr = cc.expr;
	if (expr_is_const(expr))
	{
		cast_context_set_to(cc, type_get_inferred_array(type_get_indexed_type(cc.to_type)));
		return cast_is_allowed(cc, is_explicit, is_silent);
	}
	if (is_silent) return false;
	return @sema_error_at(cc.context, expr.loc, "Conversions from arrays or vectors to slices are only permitted on constant arrays, use `&arr` or `arr[..]` instead.");
}

// sema_casts.c:1230 (static)
fn bool rule_slice_to_vecarr(CastContext* cc, bool is_explicit, bool is_silent)
{
	Expr* expr = cc.expr;
	ArrayIndex size = sema_len_from_const(expr);
	if (size < 0)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, expr.loc, "Conversions from slices to arrays or vectors are only permitted on constant slices.");
	}
	Type* base = cc.from.array.base;
	// A constant string or bytes is zero extended to fit a longer array.
	if (cc.to_group == CONV_ARRAY && (expr_is_const_string(expr) || expr_is_const_bytes(expr)))
	{
		if ((ArrayIndex)cc.to.array.len > size) size = (ArrayIndex)cc.to.array.len;
	}
	// Check before creating the type, a zero length array is not a valid type.
	if (size == 0)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, expr.loc, "Zero sized slices can't be converted to arrays or vectors.");
	}
	if (cc.to_group == CONV_ARRAY)
	{
		cast_context_set_from(cc, type_get_array(base, size));
	}
	else
	{
		if (!type_is_valid_for_vector(base))
		{
			return report_cast_error(cc, false);
		}
		cast_context_set_from(cc, type_get_vector(cc.from.array.base, cc.to.type_kind, (int)size));
	}
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1266 (static)
fn bool rule_slice_to_infer(CastContext* cc, bool is_explicit, bool is_silent)
{
	Expr* expr = cc.expr;
	// 1. We might infer something above.
	if (cc.to.type_kind == SLICE)
	{
		cast_context_set_from(cc, cc.from.array.base);
		cast_context_set_to(cc, cc.to.array.base);
		return cast_is_allowed(cc, is_explicit, is_silent);
	}
	// 2. Otherwise there is a vector matching.
	ArrayIndex size = sema_len_from_const(expr);
	if (size < 0)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, expr.loc, "Conversions from slices to arrays or vectors are only permitted on constant slices.");
	}
	if (size == 0)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, expr.loc, "Zero sized slices can't be converted to arrays or vectors.");
	}
	cast_context_set_from(cc, type_get_array(cc.from.array.base, size));
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1292 (static)
fn bool rule_vecarr_to_infer(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* new_type = type_infer_len_from_actual_type(cc.to, cc.from);
	if (type_is_inferred(new_type))
	{
		return sema_cast_error(cc, false, is_silent);
	}
	cast_context_set_to(cc, new_type);
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1303 (static)
fn BoolErr type_implements_interface_ignore_substruct(CastContext* cc, Decl* decl, Type* interface_)
{
	foreach (interface_type : decl.interfaces)
	{
		if (!sema_resolve_type_info(cc.context, interface_type, RESOLVE_TYPE_DEFAULT)) return BOOL_ERR;
		// The interface may have been named through an alias.
		Type* implemented = interface_type.type.canonical;
		if (implemented == interface_) return BOOL_TRUE;
		BoolErr res = type_implements_interface_ignore_substruct(cc, implemented.decl, interface_);
		if (res != BOOL_FALSE) return res;
	}

	return BOOL_FALSE;
}

// sema_casts.c:1317 (static)
fn bool type_implements_interface(CastContext* cc, Decl* decl, Type* interface_)
{
	while (true) // RETRY
	{
		BoolErr result = type_implements_interface_ignore_substruct(cc, decl, interface_);
		if (result != BOOL_FALSE) return result == BOOL_TRUE;
		if (!decl.is_substruct) return false;
		Type* inner;
		switch (decl.decl_kind)
		{
			case TYPEDEF:
				inner = decl.distinct.type.canonical;
			case STRUCT:
				inner = decl.strukt.members[0].type.canonical;
			case CONSTSET:
				// Could be made to work.
				return false;
			default:
				unreachable();
		}
		if (!type_may_implement_interface(inner)) return false;
		decl = inner.decl;
	}
}

// sema_casts.c:1342 (static)
fn bool rule_ptr_to_interface(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (is_explicit) return true;

	Type* pointee = cc.from.pointer;
	if (type_may_implement_interface(pointee))
	{
		Type* interface_ = cc.to;
		if (type_implements_interface(cc, pointee.decl, interface_)) return true;
	}
	if (is_silent) return false;
	return @sema_error_at(cc.context, cc.expr.loc, "%s cannot be implicitly cast to %s, but you can use an explicit "
	                      "cast to (unsafely) assume the interface is implemented.",
	                      type_quoted_error_string(cc.expr.type), type_quoted_error_string(cc.to_type));
}

// sema_casts.c:1358 (static)
fn bool is_parent_interface(Type* from_interface, Type* to_interface)
{
	foreach (parent : from_interface.decl.interfaces)
	{
		Type* parent_type = parent.type.canonical;
		if (parent_type == to_interface) return true;
		if (is_parent_interface(parent_type, to_interface)) return true;
	}
	return false;
}

// sema_casts.c:1369 (static)
fn bool rule_interface_to_interface(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (is_explicit) return true;

	Type* from_interface = cc.from;
	Type* interface_ = cc.to.canonical;
	if (!sema_resolve_type_decl(cc.context, from_interface)) return false;
	if (is_parent_interface(from_interface, interface_)) return true;
	if (is_silent) return false;
	return @sema_error_at(cc.context, cc.expr.loc, "%s is not a parent interface of %s, but you can insert an explicit cast '(%s)value' to enforce the (unsafe) conversion.",
	                      type_quoted_error_string(cc.to), type_quoted_error_string(from_interface),
	                      type_to_error_string(cc.to_type));
}

// sema_casts.c:1383 (static)
fn bool rule_ptr_to_infer(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (cc.to.type_kind != POINTER) return sema_cast_error(cc, false, is_silent);

	Type* new_type = type_infer_len_from_actual_type(cc.to, cc.from);

	if (type_to_group(new_type) == CONV_INFERRED)
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "This expression, of type %s, cannot be used to infer the length of %s.", type_quoted_error_string(cc.from), type_quoted_error_string(cc.to));
	}
	cast_context_set_to(cc, new_type.pointer.canonical);
	cast_context_set_from(cc, cc.from.pointer);
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1399 (static)
fn bool rule_explicit_ok(CastContext* cc, bool is_explicit, bool silent)
{
	if (is_explicit) return true;
	if (!silent)
	{
		return @sema_error_at(cc.context, cc.expr.loc, "%s cannot implicitly be converted to %s, but you may use a cast.", type_quoted_error_string(cc.expr.type), type_quoted_error_string(cc.to_type));
	}
	return false;
}

// sema_casts.c:1410 (static)
fn bool rule_int_to_float(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (is_explicit) return true;

	Expr* expr = cc.expr;

	if (!expr_is_simple(expr, true))
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, expr.loc, "This conversion requires an explicit cast to %s, because the widening of the expression may be done in more than one way.",
		                      type_quoted_error_string(cc.to_type));
	}
	return true;
}

<* c3c `ldexp(1, e)` for 0 <= e <= 128: exactly 2^e. *>
fn Real pow2(int e) @local
{
	Real r = 1.0;
	for (int i = 0; i < e; i++) r *= 2.0;
	return r;
}

<* A constant float is truncated towards zero, so it fits if the truncated value is in the range of the integer. *>
// sema_casts.c:1426 (static)
fn bool const_float_fits_int(Real d, Type* int_type)
{
	if (math::is_nan(d)) return false;
	d = math::trunc(d);
	int bits = (int)type_bit_size(int_type);
	if (type_is_signed(int_type)) return d >= -pow2(bits - 1) && d < pow2(bits - 1);
	return d >= 0 && d < pow2(bits);
}

// sema_casts.c:1435 (static)
fn bool rule_float_to_int(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (!is_explicit) return rule_explicit_ok(cc, false, is_silent);
	Expr* expr = cc.expr;
	if (!sema_cast_const(expr) || !expr_is_const_float(expr)) return true;
	if (const_float_fits_int(expr.const_expr.fxx.f, cc.to)) return true;
	if (is_silent) return false;
	return @sema_error_at(cc.context, expr.loc, "The value '%s' is out of range for %s.",
	                      expr_const_to_error_string(&expr.const_expr), type_quoted_error_string(cc.to_type));
}

<* Find the constant in a float vector (or array) that does not fit the integer type, if any. *>
// sema_casts.c:1447 (static)
fn Expr* const_float_vector_problem(ConstInitializer* init, Type* int_type)
{
	switch (init.kind)
	{
		case INIT_ZERO:
			return null;
		case INIT_VALUE:
			if (!expr_is_const_float(init.init_value)) return null;
			return const_float_fits_int(init.init_value.const_expr.fxx.f, int_type) ? null : init.init_value;
		case INIT_ARRAY:
			foreach (element : init.init_array.elements)
			{
				Expr* problem = const_float_vector_problem(element, int_type);
				if (problem) return problem;
			}
			return null;
		case INIT_ARRAY_FULL:
			foreach (element : init.init_array_full)
			{
				Expr* problem = const_float_vector_problem(element, int_type);
				if (problem) return problem;
			}
			return null;
		case INIT_ARRAY_VALUE:
			return const_float_vector_problem(init.init_array_value.element, int_type);
		case INIT_STRUCT:
		case INIT_UNION:
			unreachable();
	}
}

// sema_casts.c:1483 (static)
fn bool expr_is_pointer_diff(Expr* expr)
{
	if (expr.type != type_sz) return false;
	if (expr.expr_kind != BINARY) return false;
	if (expr.binary_expr.operator != SUB) return false;
	return type_is_pointer(exprptr(expr.binary_expr.left).type) && type_is_pointer(exprptr(expr.binary_expr.right).type);
}

// sema_casts.c:1491 (static)
fn bool rule_widen_narrow(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (is_explicit) return true;

	ByteSize to_size = (ByteSize)type_size(cc.to);
	ByteSize from_size = (ByteSize)type_size(cc.from);

	Expr* expr = cc.expr;
	bool is_const = sema_cast_const(expr) && expr_is_const_number(expr);

	// If widening, require simple.
	if (to_size > from_size)
	{
		if (expr_is_simple(cc.expr, type_is_float(cc.to)))
		{
			// Do we have an unsigned <-> signed conversion and it's not constant?
			if (type_is_integer(cc.to) && type_is_integer(cc.from) && type_is_signed(cc.from) && type_is_unsigned(cc.to))
			{
				if (!is_const) return sema_cast_error(cc, true, is_silent);
				if (int_is_neg(cc.expr.const_expr.ixx))
				{
					if (is_silent) return false;
					return @sema_error_at(cc.context, expr.loc, "The value '%s' is out of range for %s, so an explicit cast is needed.", expr_const_to_error_string(&expr.const_expr),
					                      type_quoted_error_string(cc.to_type));
				}
			}
			return true;
		}

		if (is_silent) return false;
		return @sema_error_at(cc.context, expr.loc, "This conversion requires an explicit cast to %s, because the widening of the expression may be done in more than one way.",
		                      type_quoted_error_string(cc.to_type));
	}

	// If const, check in range.
	if (is_const && expr_const_will_overflow(&expr.const_expr, cc.to.type_kind))
	{
		if (!is_silent)
		{
			if (cc.to_group != CONV_INT)
			{
				return @sema_error_at(cc.context, expr.loc, "The value '%s' is out of range for %s, so you need an explicit cast to truncate the value.", expr_const_to_error_string(&expr.const_expr),
				                      type_quoted_error_string(cc.to_type));
			}
			sema_error_const_int_out_of_range(cc, expr, expr, cc.to_type);
		}
		return false;
	}

	// Check if narrowing works
	Expr* problem = recursive_may_narrow(expr, cc.to);
	if (problem)
	{
		if (is_silent) return false;
		// &x - &y might something they attempt to narrow. That's not allowed.
		if (problem.expr_kind == BINARY
			&& problem.binary_expr.operator == SUB
			&& type_is_pointer_type(exprptr(problem.binary_expr.right).type))
		{
			return @sema_error_at(cc.context, expr.loc, "A pointer diff cannot implicitly be cast to %s, but you may use an explicit cast.", type_quoted_error_string(cc.to_type));
		}
		// If it's an integer that's the problem, zoom in on that one.
		if (type_is_integer(type_flatten(problem.type))) expr = problem;
		// Otherwise require a cast.
		if (expr_is_const_number(expr))
		{
			return @sema_error_at(cc.context, expr.loc, "The value of the expression (%s) is out of range and cannot implicitly be narrowed to %s, but you may use a cast.",
			                      expr_const_to_error_string(&expr.const_expr),
			                      type_quoted_error_string(cc.to_type));
		}
		if (expr_is_pointer_diff(expr))
		{
			return @sema_error_at(cc.context, expr.loc, "A pointer diff has the type %s which cannot implicitly be narrowed to %s. You can use an explicit cast if you know the conversion is safe.",
			                      type_quoted_error_string(expr.type), type_quoted_error_string(cc.to_type));
		}

		return @sema_error_at(cc.context, expr.loc, "%s cannot implicitly be narrowed to %s, but you may use a cast.",
		                      type_quoted_error_string(expr.type), type_quoted_error_string(cc.to_type));
	}
	return true;
}

// sema_casts.c:1573 (static)
fn bool rule_not_applicable(CastContext* cc, bool is_explicit, bool is_silent)
{
	unreachable();
}

// sema_casts.c:1578 (static)
fn bool rule_from_explicit_flattened(CastContext* cc, bool is_silent)
{
	CastContext original_cc = *cc;
	bool to_any_or_interface = cc.to_group == CONV_ANY || cc.to_group == CONV_INTERFACE;
	// Look through one level at a time, the closest first, and use the first one that converts.
	// The attempts are silent: the error is only reported once, below.
	Type* flat = cc.from;
	while (true)
	{
		Type* old = flat;
		flat = type_flatten_once(old);
		if (flat == old) break;
		// A distinct type is not the pointer it wraps, unless it is inline. Without inline we may only look
		// through it to an `any` or an interface: `(any)&p` is probably what was meant for a pointer.
		if (to_any_or_interface && flat.type_kind != ANY && flat.type_kind != INTERFACE && !type_has_inline(old)) break;
		cast_context_set_from(cc, flat);
		if (cast_is_allowed(cc, true, true)) return true;
		*cc = original_cc;
	}
	// Nothing converted. Report the error for the fully flattened type, which has the specific error.
	flat = type_flatten(original_cc.from);
	if (to_any_or_interface && flat.type_kind != ANY && flat.type_kind != INTERFACE)
	{
		return sema_cast_error(cc, false, is_silent);
	}
	cast_context_set_from(cc, flat);
	return cast_is_allowed(cc, true, is_silent);
}

// sema_casts.c:1607 (static)
fn bool rule_from_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* from_type = cc.from;
	assert(from_type == from_type.canonical);

	// Explicit just flattens and tries again.
	if (is_explicit)
	{
		return rule_from_explicit_flattened(cc, is_silent);
	}
	// No inline? Then it's an error.
	if (!type_has_inline(from_type))
	{
		return sema_cast_error(cc, rule_from_distinct(cc, true, true), is_silent);
	}
	// Try the types we inline one at a time, the closest first, so an inline type converts to any
	// of the types it inlines. The attempts are silent: the error is only reported once, below.
	CastContext original_cc = *cc;
	while (type_has_inline(from_type))
	{
		from_type = type_inline(from_type);
		cast_context_set_from(cc, from_type);
		if (cast_is_allowed(cc, false, true)) return true;
		*cc = original_cc;
	}
	// None converted. Report the error for the innermost type, which has the specific error.
	if (is_silent) return false;
	cast_context_set_from(cc, from_type);
	return cast_is_allowed(cc, false, false);
}

// sema_casts.c:1638 (static)
fn bool rule_to_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* from_type = cc.from;
	assert(from_type == from_type.canonical);
	Type* flat = type_flatten(cc.to);
	ConvGroup flat_group = type_to_group(flat);
	Expr* expr = cc.expr;
	bool is_const = sema_cast_const(expr);
	// Allow DistinctFooFn a = &myfunc;
	if (!is_const && from_type.type_kind == FUNC_PTR
		&& expr.expr_kind == UNARY && expr.unary_expr.operator == ADDR
		&& expr.unary_expr.expr.expr_kind == IDENTIFIER
		&& expr.unary_expr.expr.ident_expr.decl_kind == FUNC)
	{
		is_const = true;
	}
	if (is_const && (cc.is_binary_conversion || cc.to.decl.attr_constinit))
	{
		Type* to_type = cc.to;
		cc.to = flat;
		cc.to_group = flat_group;

		// If it's silent or explicit, just run it:
		if (is_silent || is_explicit)
		{
			if (!cast_is_allowed(cc, is_explicit, is_silent)) return false;
			if (!is_explicit && !cc.is_binary_conversion && !to_type.decl.attr_constinit && !expr_is_const_untyped_list(cc.expr))
			{
				if (compiler.build.warnings.deprecation == ERROR)
				{
					return sema_cast_error(cc, cast_is_allowed(cc, true, true), is_silent);
				}
			}
			return true;
		}
		// Loud and implicit:
		if (cast_is_allowed(cc, false, true))
		{
			return cc.is_binary_conversion || to_type.decl.attr_constinit || expr_is_const_untyped_list(cc.expr);
		}
		return sema_cast_error(cc, cast_is_allowed(cc, true, true), is_silent);
	}

	cc.to = flat;
	cc.to_group = flat_group;
	bool may_cast_ = cast_is_allowed(cc, true, true);
	if (may_cast_ && is_explicit) return true;
	if (is_explicit && cc.to_type == type_string && cc.from.type_kind == ARRAY && cc.from.array.base == type_char)
	{
		if (is_silent) return false;
		@sema_error_at(cc.context, cc.expr.loc, "To convert a %s array to a String, you first have to take its address: '(String)&x'.", type_quoted_error_string(cc.from));
		return false;
	}
	return sema_cast_error(cc, may_cast_, is_silent);
}

// sema_casts.c:1694 (static)
fn bool rule_to_from_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	// Handle the explicit case, in this case it's allowed if they cast to the same underlying type.
	if (is_explicit)
	{
		cast_context_set_from(cc, type_flatten(cc.from));
		return rule_to_distinct(cc, is_explicit, is_silent);
	}
	// The implicit case, if to is a parent of from, then it is ok.
	if (type_is_subtype(cc.to, cc.from)) return true;
	// It's not possible to inline from, so it's an error.
	if (!cc.from.decl.is_substruct)
	{
		return sema_cast_error(cc, rule_to_from_distinct(cc, true, true), is_silent);
	}
	// Let's to a flattering of the from, and see if it's allowed then.
	cast_context_set_from(cc, type_flat_distinct_inline(cc.from));
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1714 (static)
fn bool rule_to_struct_to_distinct(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* from = cc.from;
	// 1. The distinct type is a subtype.
	if (type_is_subtype(cc.to, from)) return true;
	// 2. We don't check for subtype after this, just use regular "to distinct" rules.
	return rule_to_distinct(cc, is_explicit, is_silent);
}

// sema_casts.c:1723 (static)
fn bool rule_struct_to_struct(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* from = cc.from;
	// 1. The distinct type is a subtype.
	if (type_is_subtype(cc.to, from)) return true;

	return sema_cast_error(cc, false, is_silent);
}

// sema_casts.c:1732 (static)
fn bool rule_vec_to_vec(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (cc.from.array.len != cc.to.array.len) return sema_cast_error(cc, false, is_silent);
	Type* from_base = cc.from.array.base;
	// A constant float vector must fit when it is cast to an integer vector.
	Type* to_base = type_flatten(cc.to.array.base);
	if (is_explicit && type_is_float(type_flatten(from_base)) && type_is_integer(to_base) && sema_cast_const(cc.expr))
	{
		ConstInitializer* init = null;
		if (expr_is_const_initializer(cc.expr)) init = cc.expr.const_expr.initializer;
		if (expr_is_const_slice(cc.expr)) init = cc.expr.const_expr.slice_init;
		Expr* problem = init ? const_float_vector_problem(init, to_base) : null;
		if (problem)
		{
			if (is_silent) return false;
			return @sema_error_at(cc.context, cc.expr.loc, "The value '%s' is out of range for %s.",
			                      expr_const_to_error_string(&problem.const_expr), type_quoted_error_string(cc.to_type));
		}
	}
	CastContext cc_copy = *cc;
	cast_context_set_to(cc, cc.to.array.base);
	// Allow bool vectors to expand to any int.
	if (from_base == type_bool && cc.to_group == CONV_INT) return true;
	// Create a fake expression that can't be folded for some checking if the
	// the elements could be cast.
	Expr temp = { .expr_kind = MACRO_BLOCK, .type = from_base, .loc = cc.expr.loc, .resolve_status = DONE };
	cc.expr = &temp;
	cast_context_set_from(cc, from_base);
	bool success = cast_is_allowed(cc, is_explicit, true);
	*cc = cc_copy;
	if (is_silent) return success;
	if (success) return true;
	return sema_cast_error(cc, is_explicit ? false : rule_vec_to_vec(cc, true, true), false);
}

// sema_casts.c:1767 (static)
fn bool rule_expand_to_vec(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (!is_explicit && !cc.is_binary_conversion)
	{
		if (is_silent) return false;
		bool explicit_works = rule_expand_to_vec(cc, true, true);
		return sema_cast_error(cc, explicit_works, false);
	}
	cast_context_set_to(cc, cc.to.array.base);
	return cast_is_allowed(cc, is_explicit, is_silent);
}

// sema_casts.c:1779 (static)
fn bool rule_int_to_bits(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* base_type = cc.to.decl.strukt.container_type.type;
	Type* from_type = cc.from;
	Expr* expr = cc.expr;
	bool success = false;
	do
	{
		if (!type_is_integer(base_type)) break;
		if (type_size(base_type) == type_size(from_type))
		{
			success = true;
			break;
		}
		if (!sema_cast_const(expr) || !expr_is_const_int(expr)) break;
		if (!int_fits(cc.expr.const_expr.ixx, base_type.canonical.type_kind))
		{
			if (is_silent) return false;
			return @sema_error_at(cc.context, expr.loc, "The value '%s' does not fit in the container type of the bitstruct %s, which is %s.", int_to_str(cc.expr.const_expr.ixx, 10, false), type_quoted_error_string(cc.to), type_quoted_error_string(base_type));
		}
		success = true;
	} while (false);
	if (!is_explicit || !success) return sema_cast_error(cc, success, is_silent);
	return true;
}

// sema_casts.c:1805 (static)
fn bool rule_int_to_enum(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (!is_explicit) return sema_cast_error(cc, true, is_silent);
	Decl* decl = cc.to.decl;
	if (sema_cast_const(cc.expr))
	{
		Int to_convert = cc.expr.const_expr.ixx;
		if (int_is_neg(to_convert))
		{
			if (is_silent) return false;
			return @sema_error_at(cc.context, cc.expr.loc, "Casting a negative number cannot yield a valid enum.");
		}
		int max_enums = (int)decl.enums.values.len;
		Int max = { .i = (uint128)max_enums, .type = U32 };
		if (int_comp(to_convert, max, GE))
		{
			if (is_silent) return false;
			return @sema_error_at(cc.context, cc.expr.loc, "The value '%s' exceeds the max ordinal '%d'.", int_to_str(to_convert, 10, false), max_enums - 1);
		}
	}
	return true;
}

// sema_casts.c:1828 (static)
fn bool rule_arr_to_bits(CastContext* cc, bool is_explicit, bool is_silent)
{
	Type* base_type = type_flatten(cc.to.decl.strukt.container_type.type);
	Type* from_type = type_flatten(cc.from);
	bool success = from_type == base_type;
	if (!is_explicit || !success) return sema_cast_error(cc, success, is_silent);
	return true;
}

// sema_casts.c:1839 (static)
fn bool rule_enum_to_value(CastContext* cc, bool is_explicit, bool is_silent)
{
	Decl* enum_decl = cc.from.decl;

	assert(enum_decl.decl_kind != CONSTSET);

	Type* inner = enum_decl.enums.type_info.type;
	if (!type_is_integer_or_bool_kind(type_flatten(cc.to)))
	{
		if (is_silent) return false;
		return @sema_error_at(cc.context, cc.expr.loc, "An enum %s can only be cast to an int type, casting directly to %s is not valid.",
		                      type_quoted_error_string(enum_decl.type), type_quoted_error_string(cc.to_type));
	}
	if (is_explicit)
	{
		cast_context_set_from(cc, type_flatten(inner));
		// Explicit just flattens and tries again.
		return cast_is_allowed(cc, is_explicit, is_silent);
	}
	return sema_cast_error(cc, false, is_silent);
}

// sema_casts.c:1861 (static)
fn bool rule_bits_to_arr(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (is_silent && !is_explicit) return false;
	Type* base_type = cc.from.decl.strukt.container_type.type.canonical;
	Type* to = cc.to;
	if (base_type != to) return sema_cast_error(cc, false, is_silent);
	if (!is_explicit) return sema_cast_error(cc, true, is_silent);
	return true;
}

// sema_casts.c:1871 (static)
fn bool rule_bits_to_int(CastContext* cc, bool is_explicit, bool is_silent)
{
	if (is_silent && !is_explicit) return false;
	Type* base_type = cc.from.decl.strukt.container_type.type.canonical;
	Type* to = cc.to;
	while (base_type != to) // RETRY
	{
		if (base_type.type_kind == TYPEDEF && (base_type.decl.is_substruct || is_explicit))
		{
			base_type = base_type.decl.distinct.type.canonical;
			continue;
		}
		if (!type_is_integer(base_type) || type_size(to) < type_size(base_type))
		{
			return sema_cast_error(cc, false, is_silent);
		}
		break;
	}
	if (!is_explicit) return sema_cast_error(cc, true, is_silent);
	return true;
}

// CASTS ----

// sema_casts.c:1896 (static)
fn void cast_vaptr_to_slice(Expr* expr, Type* type)
{
	Type* flat = type_flatten(expr.type);
	assert(flat.type_kind == POINTER);
	flat = flat.pointer;
	assert(flat.array.len > 0);
	Expr* inner = expr_copy(expr);
	expr.make_slice_expr = { .ptr = inner, .len = flat.array.len };
	expr.expr_kind = MAKE_SLICE;
	expr.resolve_status = DONE;
	expr.type = type;
}

// sema_casts.c:1909 (static)
fn void cast_ptr_to_any(Expr* expr, Type* type)
{
	Expr* inner = expr_copy(expr);
	Expr* typeid_ = expr_copy(expr);
	Type* flat = type_flatten(expr.type);
	// c3c: assert(flat.type_kind == POINTER); -- C assert, compiled out in c3c release builds
	expr_rewrite_const_typeid(typeid_, flat.pointer);
	expr.expr_kind = MAKE_ANY;
	expr.make_any_expr = { .inner = inner, .typeid_expr = typeid_ };
	expr.type = type;
}

// sema_casts.c:1920 (static)
fn void cast_struct_to_inline(Expr* expr, Type* type)
{
	ConstInitializer* init = sema_cast_const(expr) && expr_is_const_initializer(expr) ? expr.const_expr.initializer : null;
	while (init && init.kind == INIT_STRUCT && type_flatten(init.type) != type_flatten(type)) init = init.init_struct[0];
	if (!init)
	{
		expr_rewrite_addr_conversion(expr, type);
		return;
	}
	switch (init.kind)
	{
		case INIT_ZERO:
			expr_rewrite_to_const_zero(expr, type);
			return;
		case INIT_VALUE:
			expr_replace(expr, init.init_value);
			expr.type = type;
			return;
		default:
			expr_rewrite_const_initializer(expr, type, init);
			return;
	}
}

// sema_casts.c:1943 (static)
fn void cast_fault_to_ptr(Expr* expr, Type* type) { expr_rewrite_to_int_to_ptr(expr, type); }

// sema_casts.c:1944 (static)
fn void cast_typeid_to_int(Expr* expr, Type* type) { expr_rewrite_ext_trunc(expr, type, false); }

// sema_casts.c:1945 (static)
fn void cast_fault_to_int(Expr* expr, Type* type) { cast_typeid_to_int(expr, type); }

// sema_casts.c:1946 (static)
fn void cast_typeid_to_ptr(Expr* expr, Type* type) { expr_rewrite_to_int_to_ptr(expr, type); }

// sema_casts.c:1947 (static)
fn void cast_any_to_bool(Expr* expr, Type* type)
{
	expr_rewrite_ptr_access(expr, expr_copy(expr), type_voidptr);
	expr_rewrite_int_to_bool(expr, false);
	expr.type = type;
}

// sema_casts.c:1953 (static)
fn void cast_any_to_ptr(Expr* expr, Type* type) { expr_rewrite_ptr_access(expr, expr_copy(expr), type); }

// sema_casts.c:1954 (static)
fn void cast_all_to_void(Expr* expr, Type* to_type) { expr_rewrite_discard(expr); }

// sema_casts.c:1955 (static)
fn void cast_retype(Expr* expr, Type* to_type) { expr.type = to_type; }

// sema_casts.c:1957 (static)
fn void vector_const_initializer_convert_to_type(ConstInitializer* initializer, Type* to_type)
{
	switch (initializer.kind)
	{
		case INIT_ARRAY:
			Type* element_type = type_flatten(to_type).array.base;
			foreach (element : initializer.init_array.elements)
			{
				vector_const_initializer_convert_to_type(element, element_type);
			}
		case INIT_ARRAY_FULL:
			Type* element_type = type_flatten(to_type).array.base;
			foreach (element : initializer.init_array_full)
			{
				vector_const_initializer_convert_to_type(element, element_type);
			}
		case INIT_VALUE:
			Type* to_flat = type_flatten(to_type);
			bool is_neg_conversion = to_flat != type_bool && type_flatten(initializer.type) == type_bool;
			if (is_neg_conversion)
			{
				bool is_true = initializer.init_value.const_expr.b;
				if (type_is_float(to_flat))
				{
					initializer.init_value.const_expr = {
						.const_kind = FLOAT,
						.fxx = { .f = is_true ? 1.0 : 0, .type = to_flat.type_kind },
					};
				}
				else
				{
					initializer.init_value.const_expr = {
						.const_kind = INTEGER,
						.ixx = int_conv({ .i = is_true ? uint128::max : 0, .type = I128 }, to_flat.type_kind),
					};
				}
				initializer.init_value.type = to_type;
			}
			else
			{
				cast_no_check(initializer.init_value, to_type, @is_optional(initializer.init_value));
			}
		case INIT_ZERO:
			break;
		case INIT_UNION:
		case INIT_STRUCT:
			unreachable();
		case INIT_ARRAY_VALUE:
			vector_const_initializer_convert_to_type(initializer.init_array_value.element, to_type);
	}
	const_init_set_type(initializer, to_type);
}

<* Insert a PTRPTR cast or update the pointer type *>
// sema_casts.c:2024 (static)
fn void cast_ptr_to_ptr(Expr* expr, Type* type)
{
	if (!sema_cast_const(expr) || expr.const_expr.const_kind == STRING)
	{
		expr_rewrite_rvalue(expr, type);
		return;
	}

	// Insert the cast, this removes the ability to narrow it.
	expr.type = type;
	expr.const_expr.is_hex = false;
}

<* Convert any fp to another fp type using CAST_FPFP *>
// sema_casts.c:2041 (static)
fn void cast_float_to_float(Expr* expr, Type* type)
{
	// Change to same type should never enter here.
	assert(type_flatten(type) != type_flatten(expr.type));

	// Insert runtime cast if needed.
	if (!sema_cast_const(expr))
	{
		// float16 and bfloat have the same size and there is no direct conversion, so go through float.
		if (type_size(type_flatten(type)) == type_size(type_flatten(expr.type)))
		{
			expr_rewrite_ext_trunc(expr, type_float, true);
		}
		expr_rewrite_ext_trunc(expr, type, true);
		return;
	}

	// Otherwise rewrite the const, which may cause rounding.
	expr_rewrite_const_float(expr, type, expr.const_expr.fxx.f);
}

<*
 Convert from any floating point to int using CAST_FPINT
 Const conversion will disable narrowable and hex.
*>
// sema_casts.c:2066 (static)
fn void cast_float_to_int(Expr* expr, Type* type)
{
	if (!sema_cast_const(expr))
	{
		expr_rewrite_to_float_to_int(expr, type);
		return;
	}

	// Run the int->real to and rewrite.
	Real d = expr.const_expr.fxx.f;
	expr.const_expr.ixx = int_from_real(d, type_flatten(type).type_kind);
	expr.const_expr.const_kind = INTEGER;
	expr.const_expr.is_character = false;
	expr.type = type;
	expr.const_expr.is_hex = false;
}

<* Convert between integers: CAST_INTINT *>
// sema_casts.c:2088 (static)
fn void cast_int_to_int(Expr* expr, Type* type)
{
	// Fold pointer casts if narrowing
	// So (int)(uptr)&x => (int)&x in the backend.
	if (expr.expr_kind == PTR_TO_INT
	    && type_size(type) <= type_size(expr.type))
	{
		expr.type = type;
		return;
	}

	// Insert runtime casts on non-const.

	if (!sema_cast_const(expr) || !expr_is_const_int(expr))
	{
		expr_rewrite_ext_trunc(expr, type, type_is_signed(type_flatten_to_int(expr.type)));
		return;
	}

	Type* flat = type_flatten_to_int(type);
	// Hand this off to the int conversion.
	expr.const_expr.ixx = int_conv(expr.const_expr.ixx, flat.type_kind);
	expr.const_expr.const_kind = INTEGER;
	expr.type = type;
	expr.const_expr.is_hex = false;
}

<* Convert 1 => { 1, 1, 1, 1 } using CAST_EXPVEC *>
// sema_casts.c:2118 (static)
fn void cast_expand_to_vec(Expr* expr, Type* type)
{
	// Fold pointer casts if narrowing
	Type* base = type_get_indexed_type(type);
	cast_no_check(expr, base, @is_optional(expr));
	Expr* inner = expr_copy(expr);
	expr.expr_kind = SCALAR_TO_VECTOR;
	expr.inner_expr = inner;
	expr.type = type;
	expr.resolve_status = DONE;
}

// sema_casts.c:2130 (static)
fn void cast_bitstruct_to_int_arr(Expr* expr, Type* type)
{
	if (type_size(expr.type) < type_size(type))
	{
		expr_rewrite_recast(expr, type_flatten(expr.type).decl.strukt.container_type.type);
		cast_int_to_int(expr, type);
		return;
	}
	expr_rewrite_recast(expr, type);
}

// sema_casts.c:2140 (static)
fn void cast_int_arr_to_bitstruct(Expr* expr, Type* type)
{
	if (expr_is_const_int(expr))
	{
		Type* widening_type = type_flatten(type).decl.strukt.container_type.type.canonical;
		expr.const_expr.ixx = int_conv(expr.const_expr.ixx, widening_type.type_kind);
		expr.type = widening_type;
	}
	expr_rewrite_recast(expr, type);
}

// sema_casts.c:2151 (static)
fn void cast_bitstruct_to_bool(Expr* expr, Type* type)
{
	expr_rewrite_int_to_bool(expr, false);
	expr.type = type;
}

<*
 Cast a signed or unsigned integer -> floating point, using CAST_INTFP
 for runtime, otherwise do const transformation.
*>
// sema_casts.c:2162 (static)
fn void cast_int_to_float(Expr* expr, Type* type)
{
	if (!sema_cast_const(expr))
	{
		expr_rewrite_to_int_to_float(expr, type);
		return;
	}

	int precision;
	switch (type_flatten(type).type_kind)
	{
		case F16: precision = 11;
		case BF16: precision = 8;
		case F32: precision = 24;
		default: precision = 53;
	}
	Real f = int_to_real(expr.const_expr.ixx, precision);
	expr_rewrite_const_float(expr, type, f);
}

// sema_casts.c:2182 (static)
fn void cast_int_to_enum(Expr* expr, Type* type)
{
	Decl* decl = type_flatten(type).decl;
	if (sema_cast_const(expr))
	{
		Int to_convert = expr.const_expr.ixx;
		int max_enums = (int)decl.enums.values.len;
		// c3c: assert((ulong)max_enums > (ulong)to_convert.i); -- C assert, compiled out in c3c release builds
		expr.expr_kind = CONST;
		expr.const_expr = {
			.enum_val = decl.enums.values[(ulong)to_convert.i],
			.const_kind = ENUM
		};
		expr.type = type;
		return;
	}

	Expr* inner = copy_expr_single(expr);
	expr.expr_kind = ENUM_FROM_ORD;
	expr.inner_expr = inner;
	expr.type = type;
}

// sema_casts.c:2206 (static)
fn void cast_enum_to_value(Expr* expr, Type* to_type)
{
	sema_expr_convert_enum_to_int(expr);
	cast_no_check(expr, to_type, @is_optional(expr));
}

<*
 Cast using CAST_VECARR, casting an array to a vector. For the constant, this
 is a simple type change, see array_to_vec.
*>
// sema_casts.c:2216 (static)
fn void cast_vec_to_arr(Expr* expr, Type* to_type)
{
	if (!sema_cast_const(expr))
	{
		expr.inner_expr = expr_copy(expr);
		expr.expr_kind = VECTOR_TO_ARRAY;
		expr.type = to_type;
		expr.resolve_status = DONE;
		return;
	}

	assert(expr.const_expr.const_kind == INITIALIZER);
	ConstInitializer* list = expr.const_expr.initializer;
	const_init_set_type(list, to_type);
	expr.type = to_type;
}

<*
 Convert vector -> vector. This is somewhat complex as there are various functions
 we need to invoke depending on the underlying type.
*>
// sema_casts.c:2237 (static)
fn void cast_vec_to_vec(Expr* expr, Type* to_type)
{
	if (!sema_cast_const(expr) || !expr_is_const_initializer(expr))
	{
		// Extract indexed types.
		Type* from_type = type_flatten(expr.type);
		Type* from_element = type_flatten(from_type.array.base);
		Type* to_element = type_flatten(type_flatten(to_type).array.base);

		// float vec -> float/int/bool vec
		if (type_is_float(from_element))
		{
			switch (to_element.type_kind)
			{
				case BF16:
				case F16:
				case F32:
				case F64:
				case F128:
					// float16 and bfloat have the same size and there is no direct conversion, so go through float.
					if (from_element != to_element && type_size(from_element) == type_size(to_element))
					{
						expr_rewrite_ext_trunc(expr, type_get_vector(type_float, from_type.type_kind, (int)from_type.array.len), true);
					}
					expr_rewrite_ext_trunc(expr, to_type, true);
					return;
				case BOOL:
					Expr* left = expr_copy(expr);
					Expr* right = expr_new_expr(CONST, expr);
					expr_rewrite_to_const_zero(right, left.type);
					expr_rewrite_to_binary(expr, left, right, VEC_NE);
					expr.type = to_type;
					return;
				case I8:
				case I16:
				case I32:
				case I64:
				case I128:
				case U8:
				case U16:
				case U32:
				case U64:
				case U128:
					expr_rewrite_to_float_to_int(expr, to_type);
					return;
				default:
					unreachable();
			}
		}

		// bool vec -> float vec
		if (from_element == type_bool)
		{
			// Special conversion to retain the sign.
			if (type_is_integer(to_element))
			{
				expr_rewrite_ext_trunc(expr, to_type, true);
				return;
			}
			if (type_is_float(to_element))
			{
				expr_rewrite_to_int_to_float(expr, to_type);
				return;
			}
			if (to_element == type_bool)
			{
				expr_rewrite_recast(expr, to_type);
				return;
			}
			unreachable();
		}

		if (type_is_integer(from_element))
		{
			switch (to_element.type_kind)
			{
				case BF16:
				case F16:
				case F32:
				case F64:
				case F128:
					expr_rewrite_to_int_to_float(expr, to_type);
					return;
				case BOOL:
					Expr* left = expr_copy(expr);
					Expr* right = expr_new_expr(CONST, expr);
					expr_rewrite_to_const_zero(right, left.type);
					expr_rewrite_to_binary(expr, left, right, VEC_NE);
					expr.type = to_type;
					return;
				case ENUM:
				case I8:
				case I16:
				case I32:
				case I64:
				case I128:
				case U8:
				case U16:
				case U32:
				case U64:
				case U128:
					expr_rewrite_ext_trunc(expr, to_type, type_is_signed(from_element));
					return;
				case POINTER:
				case FUNC_PTR:
				case TYPEID:
				case ANYFAULT:
					expr_rewrite_to_int_to_ptr(expr, to_type);
					return;
				default:
					unreachable();
			}
		}
		// The rest will be different pointer types
		switch (to_element.type_kind)
		{
			case BF16:
			case F16:
			case F32:
			case F64:
			case F128:
				unreachable();
			case BOOL:
				Expr* inner = expr_copy(expr);
				expr.expr_kind = INT_TO_BOOL;
				expr.int_to_bool_expr = { .inner = inner, .negate = false };
				expr.type = to_type;
				return;
			case I8:
			case I16:
			case I32:
			case I64:
			case I128:
			case U8:
			case U16:
			case U32:
			case U64:
			case U128:
				expr_rewrite_to_ptr_to_int(expr, to_type);
				return;
			case POINTER:
			case FUNC_PTR:
			case TYPEID:
			case ANYFAULT:
				expr_rewrite_rvalue(expr, to_type);
				return;
			default:
				unreachable();
		}
	}

	assert(expr.const_expr.const_kind == INITIALIZER);

	// For the const initializer we need to change the internal type
	ConstInitializer* list = expr.const_expr.initializer;
	vector_const_initializer_convert_to_type(list, to_type);
	expr.type = to_type;
}

// sema_casts.c:2365 (static)
fn void cast_untyped_list_to_other(Expr* expr, Type* to_type)
{
	assert(expr_is_const_untyped_list(expr));
	// Recursively set the type of all ConstInitializer inside.
	expr_recursively_rewrite_untyped_list(expr, to_type);
}

// sema_casts.c:2373 (static)
fn void cast_slice_to_ptr(Expr* expr, Type* type)
{
	if (expr_is_const_string(expr) || expr_is_const_bytes(expr))
	{
		expr.type = type;
		return;
	}

	expr_rewrite_ptr_access(expr, expr_copy(expr), type);
}

<*
 Cast any int to a pointer, will use CAST_INTPTR after a conversion to uptr for runtime.
 Compile time it will check that the value fits the pointer size.
*>
// sema_casts.c:2388 (static)
fn void cast_int_to_ptr(Expr* expr, Type* type)
{
	assert(type_bit_size(type_uptr) <= 64, "For > 64 bit pointers, this code needs updating.");

	// Handle const:
	if (sema_cast_const(expr))
	{
		expr.type = type;
		expr.const_expr.ptr = (ulong)expr.const_expr.ixx.i;
		expr.const_expr.const_kind = POINTER;
		return;
	}
	// This may be a narrowing
	cast_no_check(expr, type_uptr, @is_optional(expr));
	expr_rewrite_to_int_to_ptr(expr, type);
}

<*
 Bool into a signed or unsigned int using CAST_BOOLINT
 or rewrite to 0 / 1 for false / true.
*>
// sema_casts.c:2409 (static)
fn void cast_bool_to_int(Expr* expr, Type* type)
{
	if (!sema_cast_const(expr))
	{
		expr_rewrite_ext_trunc(expr, type, false);
		return;
	}
	expr_rewrite_const_int(expr, type, expr.const_expr.b ? 1 : 0);
}

<*
 Cast bool to float using CAST_BOOLFP
 or rewrite to 0.0 / 1.0 for false / true
*>
// sema_casts.c:2424 (static)
fn void cast_bool_to_float(Expr* expr, Type* type)
{
	if (!sema_cast_const(expr))
	{
		expr_rewrite_to_int_to_float(expr, type);
		return;
	}

	assert(expr.const_expr.const_kind == BOOL);
	expr_rewrite_const_float(expr, type, expr.const_expr.b ? 1.0 : 0.0);
}

<*
 Cast int to bool using CAST_INTBOOL
 or rewrite 0 => false, any other value => true
*>
// sema_casts.c:2440 (static)
fn void cast_int_to_bool(Expr* expr, Type* type)
{
	if (!expr_is_const(expr))
	{
		expr_rewrite_int_to_bool(expr, false);
		expr.type = type;
		return;
	}

	expr_rewrite_const_bool(expr, type, !int_is_zero(expr.const_expr.ixx));
}

<*
 Cast any float to bool using CAST_FPBOOL
 or rewrite 0.0 => false, any other value => true
*>
// sema_casts.c:2456 (static)
fn void cast_float_to_bool(Expr* expr, Type* type)
{
	if (!expr_is_const(expr))
	{
		Expr* left = expr_copy(expr);
		Expr* right = expr_new_expr(CONST, expr);
		expr_rewrite_const_float(right, left.type, 0);
		expr.expr_kind = BINARY;
		expr.binary_expr.left = exprid(left);
		expr.binary_expr.right = exprid(right);
		expr.binary_expr.operator = NE;
		expr.type = type;
		return;
	}

	expr_rewrite_const_bool(expr, type, expr.const_expr.fxx.f != 0.0);
}

<* Insert the PTRXI cast, or on const do a rewrite. *>
// sema_casts.c:2477 (static)
fn void cast_ptr_to_int(Expr* expr, Type* type)
{
	if (sema_cast_const(expr) && expr_is_const_pointer(expr))
	{
		// Revisit this to support pointers > 64 bits.
		expr_rewrite_const_int(expr, type, expr.const_expr.ptr);
		return;
	}
	expr_rewrite_to_ptr_to_int(expr, type);
}

<* Insert the PTRBOOL cast or on const do a rewrite. *>
// sema_casts.c:2491 (static)
fn void cast_ptr_to_bool(Expr* expr, Type* type)
{
	if (!expr_is_const(expr))
	{
		expr_rewrite_int_to_bool(expr, false);
		expr.type = type;
		return;
	}

	// It may be a pointer
	switch (expr.const_expr.const_kind)
	{
		case POINTER:
			expr_rewrite_const_bool(expr, type, expr.const_expr.ptr != 0);
			return;
		case REF:
			expr_rewrite_const_bool(expr, type, true);
			return;
		default:
			break;
	}

	// Or it's a string, in which case it is always true.
	assert(expr.const_expr.const_kind == STRING);
	expr_rewrite_const_bool(expr, type, true);
}

// sema_casts.c:2520 (static)
fn void cast_slice_to_bool(Expr* expr, Type* type)
{
	if (expr_is_const_string(expr) || expr_is_const_bytes(expr))
	{
		expr_rewrite_const_bool(expr, type, expr.const_expr.bytes.len > 0);
		return;
	}
	if (expr_is_const_slice(expr))
	{
		expr_rewrite_const_bool(expr, type, sema_len_from_const(expr) > 0);
		return;
	}
	Expr* inner = expr_copy(expr);
	Expr* len = expr_copy(expr);
	expr_rewrite_slice_len(len, inner, type_sz);
	expr_rewrite_to_binary(expr, len, expr_new_const_int(expr.loc, type_sz, 0), NE);
	expr.type = type;
}

<*
 We have two cases:
 1. int[] -> Foo[] where Foo is a distinct or typedef or pointer. Then we can just redefine
 2. The second case is something like int[] -> float[] for this case we need to make a bitcast using CAST_SASA.
*>
// sema_casts.c:2544 (static)
fn void cast_slice_to_slice(Expr* expr, Type* to_type)
{
	if (sema_cast_const(expr))
	{
		expr.type = to_type;
		return;
	}
	expr_rewrite_recast(expr, to_type);
}

// sema_casts.c:2554 (static)
fn void cast_vecarr_to_slice(Expr* expr, Type* to_type)
{
	if (!sema_cast_const(expr))
	{
		unreachable();
	}
	assert(expr_is_const(expr));
	switch (expr.const_expr.const_kind)
	{
		case FLOAT:
		case INTEGER:
		case BOOL:
		case ENUM:
		case FAULT:
		case POINTER:
		case TYPEID:
		case SLICE:
		case UNTYPED_LIST:
		case REF:
		case MEMBER:
		case REFLECTION:
			unreachable();
		case BYTES:
		case STRING:
			expr.type = to_type;
			return;
		case INITIALIZER:
			ConstInitializer* init = expr.const_expr.slice_init;
			expr_rewrite_const_slice(expr, to_type, init);
			return;
	}
}

<*
 A constant string or bytes may be converted to a longer array, where the extra elements are zero.
 Make the constant itself that long, so that its length always matches its array type.
*>
// sema_casts.c:2594 (static)
fn void const_bytes_zero_extend(Expr* expr, ArrayIndex len)
{
	ArrayIndex old_len = expr.const_expr.bytes.len;
	if (len <= old_len) return;
	char* data = calloc_arena((usz)len + 1);
	mem::copy(data, expr.const_expr.bytes.ptr, old_len);
	expr.const_expr.bytes.ptr = data;
	expr.const_expr.bytes.len = len;
}

// sema_casts.c:2604 (static)
fn void cast_slice_to_arr(Expr* expr, Type* to_type)
{
	if (!sema_cast_const(expr))
	{
		switch (expr.expr_kind)
		{
			case SLICE:
			case MAKE_SLICE:
				expr.inner_expr = expr_copy(expr);
				expr.expr_kind = SLICE_TO_VEC_ARRAY;
				expr.type = to_type;
				expr.resolve_status = DONE;
				return;
			default:
				unreachable();
		}
	}
	if (expr_is_const_slice(expr))
	{
		expr.const_expr.const_kind = INITIALIZER;
	}
	else if (expr_is_const_string(expr) || expr_is_const_bytes(expr))
	{
		const_bytes_zero_extend(expr, type_flatten(to_type).array.len);
	}
	assert(expr_is_const(expr));
	expr.type = to_type;
}

// sema_casts.c:2635 (static)
fn void expr_rewrite_bytes_to_const_initializer(Expr* expr, Type* target_type)
{
	Type* flat_vec = type_flatten(target_type);
	Type* base = type_flatten(flat_vec.array.base);
	Type* elem = type_get_indexed_type(expr.type);
	bool is_signed = elem && type_is_signed(type_flatten(elem));
	ConstInitializer*[] inits = {};
	for (int i = 0; i < expr.const_expr.bytes.len; i++)
	{
		char c = expr.const_expr.bytes.ptr[i];
		Expr* conv_expr = expr_new_const_int(expr.loc, is_signed ? type_ichar : type_char, is_signed ? (ulong)(long)(ichar)c : (ulong)c);
		cast_no_check(conv_expr, base, false);

		ConstInitializer* init = const_init_new_value(conv_expr);
		@vec_add(&inits, init);
	}
	assert(inits.len);
	Type* type = type_get_vector(base, flat_vec.type_kind, (int)expr.const_expr.bytes.len);
	ConstInitializer* slice = const_init_new_array_full(type, inits);
	expr_rewrite_const_initializer(expr, type, slice);
}

// sema_casts.c:2657 (static)
fn void cast_slice_to_vec(Expr* expr, Type* to_type)
{
	Type* flat = type_flatten(to_type);
	Type* base = type_get_indexed_type(expr.type);
	if (base.canonical != flat.array.base.canonical)
	{
		cast_slice_to_vec(expr, type_get_vector(base, flat.type_kind, (int)flat.array.len));
		cast_no_check(expr, to_type, false);
		return;
	}
	if (!sema_cast_const(expr))
	{
		switch (expr.expr_kind)
		{
			case SLICE:
			case MAKE_SLICE:
				expr.inner_expr = expr_copy(expr);
				expr.expr_kind = SLICE_TO_VEC_ARRAY;
				expr.type = to_type;
				expr.resolve_status = DONE;
				return;
			default:
				unreachable();
		}
	}
	if (expr_is_const_bytes(expr) || expr_is_const_string(expr))
	{
		expr_rewrite_bytes_to_const_initializer(expr, to_type);
	}

	if (expr_is_const_slice(expr))
	{
		expr.const_expr.const_kind = INITIALIZER;
	}
	assert(expr_is_const(expr));
	expr.type = to_type;
}

// sema_casts.c:2697 (static)
fn void cast_slice_to_infer(Expr* expr, Type* to_type)
{
	ArrayIndex len = sema_len_from_const(expr);
	assert(len > 0);
	Type* indexed = type_get_indexed_type(expr.type);
	to_type = type_infer_len_from_actual_type(to_type, type_get_array(indexed, len));
	cast_no_check(expr, to_type, false);
}

// sema_casts.c:2706 (static)
fn void cast_vecarr_to_infer(Expr* expr, Type* to_type)
{
	to_type = type_infer_len_from_actual_type(to_type, type_flatten(expr.type));
	cast_no_check(expr, to_type, false);
}

// sema_casts.c:2712 (static)
fn void cast_ptr_to_infer(Expr* expr, Type* to_type)
{
	to_type = type_infer_len_from_actual_type(to_type, type_flatten(expr.type));
	cast_no_check(expr, to_type, false);
}

<*
 Cast using CAST_ARRVEC, casting an array to a vector. For the constant, this
 is a simple type change.
*>
// sema_casts.c:2723 (static)
fn void cast_arr_to_vec(Expr* expr, Type* to_type)
{
	Type* index_vec = type_get_indexed_type(to_type).canonical;
	Type* index_arr = type_get_indexed_type(expr.type).canonical;
	Type* to_temp = index_vec == index_arr ? to_type : type_get_vector(index_arr, type_flatten(to_type).type_kind, (int)type_flatten(expr.type).array.len);
	if (sema_cast_const(expr))
	{
		if (expr.const_expr.const_kind == BYTES || expr.const_expr.const_kind == STRING)
		{
			expr_rewrite_bytes_to_const_initializer(expr, to_type);
			expr.type = to_type;
			return;
		}
		assert(expr.const_expr.const_kind == INITIALIZER);
		ConstInitializer* list = expr.const_expr.initializer;
		list.type = type_flatten(to_temp);
		expr.type = to_temp;
	}
	else
	{
		Expr* inner = expr_copy(expr);
		expr.expr_kind = VECTOR_FROM_ARRAY;
		expr.inner_expr = inner;
		expr.type = to_temp;
	}
	if (to_temp != to_type)
	{
		cast_vec_to_vec(expr, to_type);
	}
}

// sema_casts.c:2754 (static)
fn void cast_arr_to_arr(Expr* expr, Type* to_type)
{
	assert(type_size(to_type) == type_size(expr.type));
	expr_rewrite_recast(expr, to_type);
}

// sema_casts.c:2760 (static)
fn void cast_anyfault_to_bool(Expr* expr, Type* to_type)
{
	expr_rewrite_int_to_bool(expr, false);
	expr.type = to_type;
}

// sema_casts.c:2765 (static)
fn void cast_typeid_to_bool(Expr* expr, Type* to_type) { expr_rewrite_int_to_bool(expr, false); expr.type = to_type; }


// The cast tables (end of sema_casts.c). Columns are the `to` group in ConvGroup order:
// void, wildc, bool, int, float, ptr, slice, vec, bitst, distc, array, strct, union, any, infc, enum, renum, func, typid, afaul, voidp, arrpt, infer, ulist
CastRule[CONV_LAST + 1][CONV_LAST + 1] cast_rules = {
	{ &rule_not_applicable, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // VOID (from) [padded 1]
	{ &rule_all_ok, &rule_not_applicable, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, &rule_all_ok, null, null }, // WILDCARD (from)
	{ &rule_explicit_ok, null, &rule_not_applicable, &rule_explicit_ok, &rule_explicit_ok, null, null, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, null, null, null, &rule_to_distinct, null, null, null, null, null, null, null }, // BOOL (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_widen_narrow, &rule_int_to_float, &rule_int_to_ptr, null, &rule_expand_to_vec, &rule_int_to_bits, &rule_to_distinct, null, null, null, null, null, &rule_int_to_enum, &rule_to_distinct, &rule_int_to_ptr, null, null, &rule_int_to_ptr, &rule_int_to_ptr, null, null }, // INT (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_float_to_int, &rule_widen_narrow, null, null, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, null, null, null, &rule_to_distinct, null, null, null, null, null, null, null }, // FLOAT (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_ptr_to_int, null, &rule_ptr_to_ptr, null, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_ptr_to_interface, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_ptr_to_ptr, &rule_ptr_to_infer, null }, // POINTER (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, null, null, &rule_slice_to_ptr, &rule_slice_to_slice, &rule_slice_to_vecarr, null, &rule_to_distinct, &rule_slice_to_vecarr, null, null, null, null, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_slice_to_ptr, &rule_slice_to_infer, null }, // SLICE (from)
	{ &rule_explicit_ok, null, null, null, null, null, &rule_vecarr_to_slice, &rule_vec_to_vec, null, &rule_to_distinct, &rule_vec_to_arr, null, null, null, null, null, &rule_to_distinct, null, null, null, null, null, &rule_vecarr_to_infer, null }, // VECTOR (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_bits_to_int, null, null, null, null, null, &rule_to_distinct, &rule_bits_to_arr, null, null, null, null, null, &rule_to_distinct, null, null, null, null, null, null, null }, // BITSTRUCT (from)
	{ &rule_explicit_ok, null, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_to_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_to_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, null }, // DISTINCT (from)
	{ &rule_explicit_ok, null, null, null, null, null, &rule_vecarr_to_slice, &rule_arr_to_vec, &rule_arr_to_bits, &rule_to_distinct, &rule_arr_to_arr, null, null, null, null, null, &rule_to_distinct, null, null, null, null, null, &rule_vecarr_to_infer, null }, // ARRAY (from)
	{ &rule_explicit_ok, null, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_to_struct_to_distinct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_to_struct_to_distinct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, &rule_struct_to_struct, null, null }, // STRUCT (from)
	{ &rule_explicit_ok, null, null, null, null, null, null, null, null, &rule_to_distinct, null, null, null, null, null, null, &rule_to_distinct, null, null, null, null, null, null, null }, // UNION (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, null, null, &rule_explicit_ok, null, null, null, &rule_to_distinct, null, null, null, &rule_not_applicable, &rule_explicit_ok, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_explicit_ok, null, null }, // ANY (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, null, null, &rule_explicit_ok, null, null, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_interface_to_interface, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_explicit_ok, null, null }, // INTERFACE (from)
	{ &rule_explicit_ok, null, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_to_distinct, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_to_distinct, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, &rule_enum_to_value, null }, // ENUM (from)
	{ &rule_explicit_ok, null, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_to_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, &rule_from_distinct, null }, // RAW_ENUM (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_ptr_to_int, null, null, null, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, null, null, null, &rule_to_distinct, &rule_ptr_to_ptr, null, null, &rule_all_ok, null, null, null }, // FUNC (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_ptr_to_int, null, &rule_explicit_ok, null, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, null, null, null, &rule_to_distinct, null, &rule_not_applicable, null, &rule_explicit_ok, &rule_explicit_ok, null, null }, // TYPEID (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_ptr_to_int, null, &rule_explicit_ok, null, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, null, null, null, &rule_to_distinct, null, null, &rule_not_applicable, &rule_explicit_ok, &rule_explicit_ok, null, null }, // ANYFAULT (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_ptr_to_int, null, &rule_all_ok, null, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, &rule_voidptr_to_any, &rule_voidptr_to_any, null, &rule_to_distinct, &rule_all_ok, null, null, &rule_not_applicable, &rule_all_ok, null, null }, // VOIDPTR (from)
	{ &rule_explicit_ok, null, &rule_explicit_ok, &rule_ptr_to_int, null, &rule_ptr_to_ptr, &rule_arrptr_to_slice, &rule_expand_to_vec, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_ptr_to_interface, null, &rule_to_distinct, null, null, null, &rule_all_ok, &rule_ptr_to_ptr, &rule_ptr_to_infer, null }, // VAPTR (from)
	{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // INFERRED (from)
	{ null, null, null, null, null, null, &rule_ulist_to_slice, &rule_ulist_to_vecarr, &rule_ulist_to_struct, &rule_to_distinct, &rule_ulist_to_vecarr, &rule_ulist_to_struct, null, null, null, null, &rule_to_distinct, null, null, null, null, null, &rule_ulist_to_inferred, null }, // UNTYPED_LIST (from)
};

CastFunction[CONV_LAST + 1][CONV_LAST + 1] cast_function = {
	{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // VOID (from)
	{ &cast_retype, null, &cast_retype, &cast_retype, &cast_retype, &cast_retype, &cast_retype, &cast_retype, &cast_retype, null, &cast_retype, &cast_retype, &cast_retype, &cast_retype, &cast_retype, &cast_retype, null, &cast_retype, &cast_retype, &cast_retype, &cast_retype, &cast_retype, null, null }, // WILDCARD (from)
	{ &cast_all_to_void, null, null, &cast_bool_to_int, &cast_bool_to_float, null, null, &cast_expand_to_vec, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // BOOL (from)
	{ &cast_all_to_void, null, &cast_int_to_bool, &cast_int_to_int, &cast_int_to_float, &cast_int_to_ptr, null, &cast_expand_to_vec, &cast_int_arr_to_bitstruct, null, null, null, null, null, null, &cast_int_to_enum, null, &cast_int_to_ptr, null, null, &cast_int_to_ptr, &cast_int_to_ptr, null, null }, // INT (from)
	{ &cast_all_to_void, null, &cast_float_to_bool, &cast_float_to_int, &cast_float_to_float, null, null, &cast_expand_to_vec, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // FLOAT (from)
	{ &cast_all_to_void, null, &cast_ptr_to_bool, &cast_ptr_to_int, null, &cast_ptr_to_ptr, null, &cast_expand_to_vec, null, null, null, null, null, &cast_ptr_to_any, &cast_ptr_to_any, null, null, null, null, null, &cast_ptr_to_ptr, &cast_ptr_to_ptr, &cast_ptr_to_infer, null }, // POINTER (from)
	{ &cast_all_to_void, null, &cast_slice_to_bool, null, null, &cast_slice_to_ptr, &cast_slice_to_slice, &cast_slice_to_vec, null, null, &cast_slice_to_arr, null, null, null, null, null, null, null, null, null, &cast_slice_to_ptr, &cast_slice_to_ptr, &cast_slice_to_infer, null }, // SLICE (from)
	{ &cast_all_to_void, null, null, null, null, null, &cast_vecarr_to_slice, &cast_vec_to_vec, null, null, &cast_vec_to_arr, null, null, null, null, null, null, null, null, null, null, null, &cast_vecarr_to_infer, null }, // VECTOR (from)
	{ &cast_all_to_void, null, &cast_bitstruct_to_bool, &cast_bitstruct_to_int_arr, null, null, null, null, null, null, &cast_bitstruct_to_int_arr, null, null, null, null, null, null, null, null, null, null, null, null, null }, // BITSTRUCT (from)
	{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // DISTINCT (from)
	{ &cast_all_to_void, null, null, null, null, null, &cast_vecarr_to_slice, &cast_arr_to_vec, &cast_int_arr_to_bitstruct, null, &cast_arr_to_arr, null, null, null, null, null, null, null, null, null, null, null, &cast_vecarr_to_infer, null }, // ARRAY (from)
	{ &cast_all_to_void, null, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, null, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, &cast_struct_to_inline, null, null }, // STRUCT (from)
	{ &cast_all_to_void, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // UNION (from)
	{ &cast_all_to_void, null, &cast_any_to_bool, null, null, &cast_any_to_ptr, null, null, null, null, null, null, null, &cast_ptr_to_ptr, &cast_ptr_to_ptr, null, null, null, null, null, &cast_any_to_ptr, &cast_any_to_ptr, null, null }, // ANY (from)
	{ &cast_all_to_void, null, &cast_any_to_bool, null, null, &cast_any_to_ptr, null, null, null, null, null, null, null, &cast_ptr_to_ptr, &cast_ptr_to_ptr, null, null, null, null, null, &cast_any_to_ptr, &cast_any_to_ptr, null, null }, // INTERFACE (from)
	{ &cast_all_to_void, null, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value, &cast_enum_to_value }, // ENUM (from)
	{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // RAW_ENUM (from)
	{ &cast_all_to_void, null, &cast_ptr_to_bool, &cast_ptr_to_int, null, null, null, &cast_expand_to_vec, null, null, null, null, null, null, null, null, null, &cast_ptr_to_ptr, null, null, &cast_ptr_to_ptr, null, null, null }, // FUNC (from)
	{ &cast_all_to_void, null, &cast_typeid_to_bool, &cast_typeid_to_int, null, &cast_typeid_to_ptr, null, &cast_expand_to_vec, null, null, null, null, null, null, null, null, null, null, null, null, &cast_typeid_to_ptr, &cast_typeid_to_ptr, null, null }, // TYPEID (from)
	{ &cast_all_to_void, null, &cast_anyfault_to_bool, &cast_fault_to_int, null, &cast_fault_to_ptr, null, &cast_expand_to_vec, null, null, null, null, null, null, null, null, null, null, null, null, &cast_fault_to_ptr, &cast_fault_to_ptr, null, null }, // ANYFAULT (from)
	{ &cast_all_to_void, null, &cast_ptr_to_bool, &cast_ptr_to_int, null, &cast_ptr_to_ptr, null, &cast_expand_to_vec, null, null, null, null, null, &cast_ptr_to_any, &cast_ptr_to_any, null, null, &cast_ptr_to_ptr, null, null, null, &cast_ptr_to_ptr, null, null }, // VOIDPTR (from)
	{ &cast_all_to_void, null, &cast_ptr_to_bool, &cast_ptr_to_int, null, &cast_ptr_to_ptr, &cast_vaptr_to_slice, &cast_expand_to_vec, null, null, null, null, null, &cast_ptr_to_any, &cast_ptr_to_any, null, null, null, null, null, &cast_ptr_to_ptr, &cast_ptr_to_ptr, &cast_ptr_to_infer, null }, // VAPTR (from)
	{ null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null, null }, // INFERRED (from)
	{ null, null, null, null, null, null, &cast_untyped_list_to_other, &cast_untyped_list_to_other, &cast_untyped_list_to_other, null, &cast_untyped_list_to_other, &cast_untyped_list_to_other, null, null, null, null, null, null, null, null, null, null, &cast_untyped_list_to_other, null }, // UNTYPED_LIST (from)
};

ConvGroup[TYPE_LAST.ordinal + 1] group_from_type = {
	CONV_NO, // POISONED
	CONV_VOID, // VOID
	CONV_BOOL, // BOOL
	CONV_INT, // I8
	CONV_INT, // I16
	CONV_INT, // I32
	CONV_INT, // I64
	CONV_INT, // I128
	CONV_INT, // U8
	CONV_INT, // U16
	CONV_INT, // U32
	CONV_INT, // U64
	CONV_INT, // U128
	CONV_FLOAT, // F16
	CONV_FLOAT, // BF16
	CONV_FLOAT, // F32
	CONV_FLOAT, // F64
	CONV_FLOAT, // F128
	CONV_ANY, // ANY
	CONV_INTERFACE, // INTERFACE
	CONV_ANYFAULT, // ANYFAULT
	CONV_TYPEID, // TYPEID
	CONV_FUNC, // FUNC_PTR
	CONV_POINTER, // POINTER
	CONV_DISTINCT, // TYPEDEF
	CONV_RAW_ENUM, // CONSTSET
	CONV_ENUM, // ENUM
	CONV_VOID, // FUNC_RAW: missing in c3c (implicit 0)
	CONV_STRUCT, // STRUCT
	CONV_UNION, // UNION
	CONV_BITSTRUCT, // BITSTRUCT
	CONV_NO, // ALIAS
	CONV_UNTYPED_LIST, // UNTYPEDLIST
	CONV_SLICE, // SLICE
	CONV_ARRAY, // ARRAY
	CONV_NO, // FLEXIBLE_ARRAY
	CONV_NO, // INFERRED_ARRAY
	CONV_VECTOR, // VECTOR
	CONV_VECTOR, // SIMD_VECTOR
	CONV_NO, // INFERRED_VECTOR
	CONV_NO, // OPTIONAL
	CONV_WILDCARD, // WILDCARD
	CONV_NO, // TYPEINFO
	CONV_NO, // MEMBER
	CONV_NO, // REFLECTION
};

// sema_casts.c:2958 (static)
fn ConvGroup type_to_group(Type* type)
{
	type = type.canonical;
	if (type == type_voidptr) return CONV_VOIDPTR;
	if (type.type_kind == POINTER && (type.pointer.type_kind == ARRAY || type_kind_is_real_vector(type.pointer.canonical.type_kind))) return CONV_VAPTR;
	if (type_len_is_inferred(type)) return CONV_INFERRED;
	return group_from_type[type.type_kind.ordinal];
}

// sema_casts.c:2967 (static)
fn void cast_context_set_from(CastContext* cc, Type* new_from)
{
	cc.from_group = type_to_group(cc.from = new_from);
}

// sema_casts.c:2972 (static)
fn void cast_context_set_to(CastContext* cc, Type* new_to)
{
	cc.to_group = type_to_group(cc.to = new_to);
}
