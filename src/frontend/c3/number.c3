// Port of c3c src/compiler/number.c (revision 54bab366a): constant
// comparison, range / overflow checks and constant printing.
//
// Deviations from c3c:
// - `%g` / `%p` use the C3 formatter, which may differ from libc in corner
//   cases (exponent digits, pointer padding).
// - expr_const_to_error_string's CONST_STRING case reproduces c3c's
//   `"\"%*.s\""` exactly: a width of `len` with precision 0, i.e. `len`
//   spaces between the quotes.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

const Real FLOAT32_LIMIT = 340282346638528859811704183484516925440.0;
const Real FLOAT64_LIMIT = double::max;
const Real FLOAT16_LIMIT = 65504;
const Real BFLOAT_LIMIT = 338953138925153547590470800371487866880.0;

// number.c:14 (static)
fn bool compare_bool(bool left, bool right, BinaryOp op)
{
	switch (op)
	{
		case EQ: return left == right;
		case NE: return left != right;
		case GT: return left > right;
		case LT: return left < right;
		case GE: return left >= right;
		case LE: return left <= right;
		default: unreachable();
	}
}

// number.c:34 (static)
fn bool compare_fps(Real left, Real right, BinaryOp op)
{
	switch (op)
	{
		case GE: return left >= right;
		case LE: return left <= right;
		case NE: return left != right;
		case GT: return left > right;
		case LT: return left < right;
		case EQ: return left == right;
		default: unreachable();
	}
}

// number.c:54
fn void expr_contract_array(ExprConst* expr_const, ConstKind contract_type)
{
	if (expr_const.const_kind == SLICE && !expr_const.slice_init)
	{
		*expr_const = { .const_kind = contract_type, .bytes = { null, 0 } };
		return;
	}
	assert(expr_const.const_kind == INITIALIZER || expr_const.const_kind == SLICE);
	ConstInitializer* initializer = expr_const.const_kind == SLICE
			? expr_const.slice_init
			: expr_const.initializer;
	Type* type = initializer.type;
	assert(type_is_any_arraylike(type));
	ArrayIndex len = type.array.len;
	assert(len > 0);
	char* arr = calloc_arena((usz)len);
	switch (initializer.kind)
	{
		case INIT_ZERO:
			break;
		case INIT_STRUCT:
		case INIT_UNION:
		case INIT_VALUE:
		case INIT_ARRAY_VALUE:
			unreachable();
		case INIT_ARRAY:
			foreach (init : initializer.init_array.elements)
			{
				assert(init.kind == INIT_ARRAY_VALUE);
				arr[init.init_array_value.index] = (char)int_to_i64(init.init_array_value.element.init_value.const_expr.ixx);
			}
		case INIT_ARRAY_FULL:
			foreach (i, init : initializer.init_array_full)
			{
				assert(init.kind == INIT_VALUE);
				arr[i] = (char)int_to_i64(init.init_value.const_expr.ixx);
			}
	}
	*expr_const = { .const_kind = contract_type, .bytes = { arr, len } };
}

// number.c:101 (static)
fn bool const_is_bytes(ConstKind kind) @inline
{
	return kind == BYTES || kind == STRING;
}

// number.c:106 (static)
fn ConstInitializer* expr_const_array_init_at(ConstInitializer* init, ArrayIndex index)
{
	switch (init.kind)
	{
		case INIT_ZERO:
			return null;
		case INIT_STRUCT:
		case INIT_UNION:
		case INIT_VALUE:
		case INIT_ARRAY_VALUE:
			unreachable();
		case INIT_ARRAY:
			foreach (e : init.init_array.elements)
			{
				ArrayIndex idx = e.init_array_value.index;
				if (idx != index) continue;
				return e.init_array_value.element;
			}
			return null;
		case INIT_ARRAY_FULL:
			return init.init_array_full[index];
	}
	unreachable();
}

// number.c:133 (static)
fn void swap_to_zero_to_left(ConstInitializer** left_ref, ConstInitializer** right_ref) @inline
{
	ConstInitializer* right = *right_ref;
	if (right.kind == INIT_ZERO)
	{
		*right_ref = *left_ref;
		*left_ref = right;
	}
}

// number.c:144 (static)
fn bool expr_const_compare_bitstruct(ExprConst* left, ExprConst* right, BinaryOp op)
{
	ConstInitializer* lhs = left.initializer;
	ConstInitializer* rhs = right.initializer;
	swap_to_zero_to_left(&lhs, &rhs);
	bool find_eq = op == EQ;
	if (lhs.kind == INIT_ZERO) return const_init_is_zero(rhs) ? find_eq : !find_eq;
	ConstInitializer*[] lhs_inits = lhs.init_struct;
	ConstInitializer*[] rhs_inits = rhs.init_struct;
	Decl*[] members = lhs.type.decl.strukt.members;
	usz len = members.len;
	for (usz i = 0; i < len; i++)
	{
		ConstInitializer* init_lhs = lhs_inits[i];
		ConstInitializer* init_rhs = rhs_inits[i];
		swap_to_zero_to_left(&init_lhs, &init_rhs);
		// Zero case
		if (init_lhs.kind == INIT_ZERO)
		{
			if (const_init_is_zero(init_rhs)) continue;
			return !find_eq;
		}
		// Both should have values
		Expr* lhs_expr = init_lhs.init_value;
		Expr* rhs_expr = init_rhs.init_value;

		bool to_const = sema_cast_const(lhs_expr) && sema_cast_const(rhs_expr);
		// c3c: assert(to_const); -- C assert, compiled out in c3c release builds
		if (!expr_const_compare(&lhs_expr.const_expr, &rhs_expr.const_expr, EQ))
		{
			return !find_eq;
		}
	}
	return find_eq;
}

// number.c:181
fn bool expr_const_compare(ExprConst* left, ExprConst* right, BinaryOp op)
{
	bool is_eq;
	ConstKind left_kind = left.const_kind;
	ConstKind right_kind = right.const_kind;
	ExprConst replace;
	if (left_kind != right_kind)
	{
		if (const_is_bytes(left_kind))
		{
			if (!const_is_bytes(right_kind))
			{
				replace = *right;
				expr_contract_array(&replace, left_kind);
				right = &replace;
			}
		}
		else if (const_is_bytes(right_kind))
		{
			if (!const_is_bytes(left_kind))
			{
				replace = *left;
				expr_contract_array(&replace, right_kind);
				left = &replace;
			}
		}
	}
	switch (left.const_kind)
	{
		case BOOL:
			return compare_bool(left.b, right.b, op);
		case INTEGER:
			assert(right.const_kind != ENUM);
			return int_comp(left.ixx, right.ixx, op);
		case FAULT:
			assert(right.const_kind == FAULT);
			is_eq = right.fault_val == left.fault_val
				|| (right.fault_val && left.fault_val && decl_flatten(right.fault_val) == decl_flatten(left.fault_val));
			return op == EQ ? is_eq : !is_eq;
		case REF:
			assert(right.const_kind == POINTER || right.const_kind == REF);
			is_eq = right.const_kind == REF && decl_flatten(right.global_ref) == decl_flatten(left.global_ref);
			return op == EQ ? is_eq : !is_eq;
		case FLOAT:
			return compare_fps(left.fxx.f, right.fxx.f, op);
		case POINTER:
			Int a = { .i = left.ptr, .type = U64 };
			Int b = { .i = right.ptr, .type = U64 };
			return int_comp(a, b, op);
		case TYPEID:
			is_eq = left.typeid_type == right.typeid_type;
		case ENUM:
			Decl* left_decl = left.enum_val;
			// The error case
			assert(right.const_kind == left.const_kind);
			Decl* right_decl = right.enum_val;
			// Non-matching cannot be compared.
			if (right_decl.type != left_decl.type) return false;
			long right_ordinal = right.enum_val.enum_constant.inner_ordinal;
			long left_ordinal = left_decl.enum_constant.inner_ordinal;
			switch (op)
			{
				case GT: return left_ordinal > right_ordinal;
				case GE: return left_ordinal >= right_ordinal;
				case LT: return left_ordinal < right_ordinal;
				case LE: return left_ordinal <= right_ordinal;
				case NE: return left_ordinal != right_ordinal;
				case EQ: return left_ordinal == right_ordinal;
				default: return false;
			}
		case BYTES:
		case STRING:
			if (left.bytes.len != right.bytes.len)
			{
				is_eq = false;
				break;
			}
			if (right.bytes.ptr == left.bytes.ptr)
			{
				is_eq = true;
				break;
			}
			is_eq = left.bytes.ptr[:left.bytes.len] == right.bytes.ptr[:left.bytes.len];
		case INITIALIZER:
			if (type_kind_is_real_vector(left.initializer.type.type_kind))
			{
				ConstInitializer* lhs = left.initializer;
				ConstInitializer* rhs = right.initializer;
				ArrayIndex len = lhs.type.canonical.array.len;
				bool rhs_is_zero = rhs.kind == INIT_ZERO;
				if (lhs.kind == INIT_ZERO && rhs_is_zero) return op == EQ;
				for (ArrayIndex i = 0; i < len; i++)
				{
					ConstInitializer* ai = expr_const_array_init_at(lhs, i);
					ConstInitializer* bi = expr_const_array_init_at(rhs, i);
					bool a_is_zero = !ai || const_init_is_zero(ai);
					bool b_is_zero = !bi || const_init_is_zero(bi);
					if (a_is_zero || b_is_zero)
					{
						if (a_is_zero != b_is_zero) return op != EQ; // MISMATCH
						continue;
					}
					// c3c: assert(ai && bi); -- C assert, compiled out in c3c release builds
					// c3c: assert(bi.kind == INIT_VALUE && ai.kind == INIT_VALUE); -- C assert, compiled out in c3c release builds
					Expr* a_value = ai.init_value;
					Expr* b_value = bi.init_value;
					bool is_equal = expr_const_compare(&a_value.const_expr, &b_value.const_expr, EQ);
					if (is_equal) continue;
					return op != EQ; // MISMATCH
				}
				return op == EQ;
			}
			if (left.initializer.type.type_kind == BITSTRUCT)
			{
				return expr_const_compare_bitstruct(left, right, op);
			}
			unreachable();
		case SLICE:
		case UNTYPED_LIST:
		case REFLECTION:
			unreachable();
		case MEMBER:
			is_eq = left.member.decl == right.member.decl;
	}
	// RETURN:
	// c3c: assert((op == EQ) || (op == NE)); -- C assert, compiled out in c3c release builds
	return op == EQ ? is_eq : !is_eq;
}

// number.c:325
fn bool expr_const_in_range(ExprConst* left, ExprConst* left_to, ExprConst* right, ExprConst* right_to)
{
	if (right == right_to && left == left_to) return expr_const_compare(left, right, EQ);
	if (expr_const_compare(left, right_to, GT) || expr_const_compare(left_to, right, LT)) return false;
	return true;
}

// number.c:332
fn bool expr_const_float_fits_type(ExprConst* expr_const, TypeKind kind)
{
	Real hi_limit;
	Real lo_limit;
	switch (kind)
	{
		case BF16:
			lo_limit = hi_limit = BFLOAT_LIMIT;
		case F16:
			lo_limit = hi_limit = FLOAT16_LIMIT;
		case F32:
			lo_limit = hi_limit = FLOAT32_LIMIT;
		case F64:
			lo_limit = hi_limit = FLOAT64_LIMIT;
		case F128:
			// Assume this to be true
			return true;
		case BOOL:
			return true;
		default:
			unreachable();
	}
	assert(expr_const.const_kind == FLOAT);
	return expr_const.fxx.f >= -lo_limit && expr_const.fxx.f <= hi_limit;
}

// number.c:362
fn bool expr_const_will_overflow(ExprConst* expr, TypeKind kind)
{
	switch (expr.const_kind)
	{
		case FLOAT:
			return !expr_const_float_fits_type(expr, kind);
		case INTEGER:
			return !int_fits(expr.ixx, kind);
		case BOOL:
			return false;
		case ENUM:
			Int i = { .i = (uint128)(ulong)(long)expr.enum_val.var_decl.index, .type = type_flatten(expr.enum_val.type).type_kind };
			return !int_fits(i, kind);
		case FAULT:
		case BYTES:
		case STRING:
		case POINTER:
		case TYPEID:
		case SLICE:
		case INITIALIZER:
		case UNTYPED_LIST:
		case MEMBER:
		case REFLECTION:
		case REF:
			unreachable();
	}
	unreachable();
}

// number.c:393
fn void const_init_to_scratch_buffer(ConstInitializer* init)
{
	// c3c: assert(init != null); -- C assert, compiled out in c3c release builds
	switch (init.kind)
	{
		case INIT_ZERO:
			scratch_buffer_append("{}");
			return;
		case INIT_STRUCT:
			scratch_buffer_append("{ ");
			foreach (i, sub : init.init_struct)
			{
				if (i != 0) scratch_buffer_append(", ");
				const_init_to_scratch_buffer(sub);
			}
			scratch_buffer_append(" }");
			return;
		case INIT_UNION:
			@scratch_buffer_printf("{ .%s = ", init.type.decl.strukt.members[init.init_union.index].name);
			const_init_to_scratch_buffer(init.init_union.element);
			scratch_buffer_append(" }");
			return;
		case INIT_VALUE:
			expr_const_to_scratch_buffer(&init.init_value.const_expr);
			return;
		case INIT_ARRAY:
			scratch_buffer_append("{ ");
			foreach (i, sub : init.init_array.elements)
			{
				if (i != 0) scratch_buffer_append(", ");
				const_init_to_scratch_buffer(sub);
			}
			scratch_buffer_append(" }");
			return;
		case INIT_ARRAY_FULL:
			scratch_buffer_append("{ ");
			foreach (i, sub : init.init_array_full)
			{
				if (i != 0) scratch_buffer_append(", ");
				const_init_to_scratch_buffer(sub);
			}
			scratch_buffer_append(" }");
			return;
		case INIT_ARRAY_VALUE:
			@scratch_buffer_printf("[%d] = ", (long)init.init_array_value.index);
			const_init_to_scratch_buffer(init.init_array_value.element);
			return;
	}
	unreachable();
}

// number.c:451
fn void expr_const_to_scratch_buffer(ExprConst* expr)
{
	switch (expr.const_kind)
	{
		case POINTER:
			if (!expr.ptr)
			{
				scratch_buffer_append("null");
			}
			else
			{
				@scratch_buffer_printf("%p", (void*)(uptr)expr.ptr);
			}
			return;
		case BOOL:
			scratch_buffer_append(expr.b ? "true" : "false");
			return;
		case INTEGER:
			scratch_buffer_append(int_to_str(expr.ixx, 10, false));
			return;
		case FLOAT:
			@scratch_buffer_printf("%g", expr.fxx.f);
			return;
		case STRING:
			scratch_buffer_append_len(expr.bytes.ptr, (usz)expr.bytes.len);
			return;
		case BYTES:
			scratch_buffer_append("<binary data>");
			return;
		case REF:
			scratch_buffer_append(expr.global_ref.name);
			return;
		case FAULT:
			scratch_buffer_append(expr.fault_val ? expr.fault_val.name : "null");
			return;
		case ENUM:
			scratch_buffer_append(expr.enum_val.name);
			return;
		case TYPEID:
			scratch_buffer_append(expr.typeid_type.name);
			return;
		case REFLECTION:
			scratch_buffer_append("mirror(");
			scratch_buffer_append(span_to_string(expr.reflection.loc));
			scratch_buffer_append(")");
			return;
		case MEMBER:
			scratch_buffer_append(expr.member.decl.name);
			return;
		case SLICE:
			if (!expr.slice_init)
			{
				scratch_buffer_append("{}");
				return;
			}
			const_init_to_scratch_buffer(expr.slice_init);
			return;
		case INITIALIZER:
			const_init_to_scratch_buffer(expr.initializer);
			return;
		case UNTYPED_LIST:
			if (!expr.untyped_list.len)
			{
				scratch_buffer_append("{}");
				return;
			}
			scratch_buffer_append("{ ");
			foreach (i, e : expr.untyped_list)
			{
				if (i != 0) scratch_buffer_append(", ");
				expr_const_to_scratch_buffer(&e.const_expr);
			}
			scratch_buffer_append(" }");
			return;
	}
	unreachable();
}

// number.c:530
fn String expr_const_to_error_string(ExprConst* expr)
{
	switch (expr.const_kind)
	{
		case POINTER:
			if (!expr.ptr) return "null";
			return @str_printf("%p", (void*)(uptr)expr.ptr);
		case BOOL:
			return expr.b ? "true" : "false";
		case INTEGER:
			return int_to_str(expr.ixx, expr.is_hex ? 16 : 10, true);
		case FLOAT:
			return @str_printf("%g", expr.fxx.f);
		case STRING:
			// c3c: str_printf("\"%*.s\"", len, ptr) pads `len` spaces.
			char* res = calloc_arena((usz)expr.bytes.len + 3);
			res[0] = '"';
			for (usz i = 1; i <= (usz)expr.bytes.len; i++) res[i] = ' ';
			res[(usz)expr.bytes.len + 1] = '"';
			return (String)res[:(usz)expr.bytes.len + 2];
		case BYTES:
			return "<binary data>";
		case REF:
			return expr.global_ref.name;
		case FAULT:
			return expr.fault_val ? expr.fault_val.name : "null";
		case ENUM:
			return expr.enum_val.name;
		case TYPEID:
			return type_to_error_string(expr.typeid_type);
		case REFLECTION:
			return "reflection struct";
		case MEMBER:
			return "member";
		case SLICE:
		case INITIALIZER:
			return "constant list";
		case UNTYPED_LIST:
			return "untyped list";
	}
	unreachable();
}
