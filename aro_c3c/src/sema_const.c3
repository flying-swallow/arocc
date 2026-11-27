// Port of c3c src/compiler/sema_const.c (revision 54bab366a): compile-time
// constant concatenation / append (`+++`) and sema_len_from_const.
//
// Deviations from c3c:
// - `goto ARRAY_LEN` / `goto RETRY` are restructured (a local init + fallthrough
//   to the shared tail, a `while (true)` loop).
// - `memcpy` / `malloc_arena` are mem::copy / calloc_arena.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;
import std::core::mem;

// sema_const.c:10
fn ArrayIndex sema_len_from_const(Expr* expr)
{
	// We also handle the case where we have a cast from a const array.
	if (!sema_cast_const(expr))
	{
		if (type_flatten(expr.type).type_kind != SLICE) return -1;
		if (expr.expr_kind == ExprKind.SLICE)
		{
			return range_const_len(&expr.slice_expr.range);
		}
		if (expr.expr_kind != MAKE_SLICE) return -1;
		return (ArrayIndex)expr.make_slice_expr.len;
	}
	ConstInitializer* init;
	switch (expr.const_expr.const_kind)
	{
		case FLOAT:
		case INTEGER:
		case BOOL:
		case ENUM:
		case FAULT:
		case TYPEID:
		case MEMBER:
		case REFLECTION:
		case REF:
			return -1;
		case POINTER:
			return -1;
		case BYTES:
		case STRING:
			return (ArrayIndex)expr.const_expr.bytes.len;
		case SLICE:
			if (!expr.const_expr.slice_init) return 0;
			init = expr.const_expr.slice_init;
		case INITIALIZER:
			init = expr.const_expr.initializer;
		case UNTYPED_LIST:
			return (ArrayIndex)expr.const_expr.untyped_list.len;
	}
	// ARRAY_LEN:
	if (type_is_arraylike(init.type)) return (ArrayIndex)init.type.array.len;
	return -1;
}

// sema_const.c:57 (static)
fn bool sema_expr_const_append(SemaContext* context, Expr* append_expr, Expr* list, Expr* element, bool* failed_ref)
{
	Expr*[] untyped_list = {};
	switch (list.const_expr.const_kind)
	{
		case INITIALIZER:
		case SLICE:
			assert(list.type != type_untypedlist);
			return sema_append_const_array_one(context, append_expr, list, element, failed_ref);
		case UNTYPED_LIST:
			untyped_list = list.const_expr.untyped_list;
		case POINTER:
		case BYTES:
		case STRING:
			return sema_append_concat_const_bytes(context, append_expr, list, element, failed_ref);
		default:
			return @sema_error_at(context, list.loc, "Expected some kind of list or vector here.");
	}
	@vec_add(&untyped_list, element);
	append_expr.expr_kind = CONST;
	append_expr.const_expr = { .untyped_list = untyped_list, .const_kind = UNTYPED_LIST };
	append_expr.type = type_untypedlist;
	append_expr.resolve_status = DONE;
	return true;
}

// sema_const.c:84 (static)
fn void expr_concat_const_bytes(Expr* expr, Type* type, bool is_bytes, String a, String b, ArrayIndex alen, ArrayIndex blen)
{
	Type* indexed = type_get_indexed_type(type);
	char* data = calloc_arena((usz)(alen + blen + 1));
	char* current = data;
	if (alen) mem::copy(current, a.ptr, alen);
	current += alen;
	if (blen) mem::copy(current, b.ptr, blen);
	current += blen;
	current[0] = '\0';
	expr.expr_kind = CONST;
	expr.const_expr = {
		.const_kind = is_bytes ? BYTES : STRING,
		.bytes = { .ptr = data, .len = alen + blen }
	};
	expr.resolve_status = DONE;
	expr.type = is_bytes ? type_get_array(indexed, alen + blen) : type;
}

// sema_const.c:104 (static)
fn void expr_concat_character(Expr* expr, Type* type, String a, ArrayIndex alen, ulong c)
{
	char[4] append_array;
	int len;
	if (c <= 0x7f)
	{
		append_array[0] = (char)c;
		len = 1;
	}
	else if (c <= 0x7ff)
	{
		append_array[0] = (char)(0xC0 | (c >> 6));
		append_array[1] = (char)(0x80 | (c & 0x3F));
		len = 2;
	}
	else if (c <= 0xffff)
	{
		append_array[0] = (char)(0xE0 | (c >> 12));
		append_array[1] = (char)(0x80 | ((c >> 6) & 0x3F));
		append_array[2] = (char)(0x80 | (c & 0x3F));
		len = 3;
	}
	else
	{
		append_array[0] = (char)(0xF0 | (c >> 18));
		append_array[1] = (char)(0x80 | ((c >> 12) & 0x3F));
		append_array[2] = (char)(0x80 | ((c >> 6) & 0x3F));
		append_array[3] = (char)(0x80 | (c & 0x3F));
		len = 4;
	}
	expr_concat_const_bytes(expr, type, false, a, (String)append_array[:len], alen, len);
}

<*
 1. String + Bytes|String
 2. Bytes + Bytes|String
 3. Bytes + (i)char => Bytes
 4. String + character => String
 5. String + (i)char array/vector => String // Disallowed for now
 6. Bytes + (i)char array/vector => Bytes   // Disallowed for now
*>
// sema_const.c:145 (static)
fn bool sema_concat_bytes_and_other(SemaContext* context, Expr* expr, Expr* left, Expr* right, bool* failed_ref)
{
	ArrayIndex len = left.const_expr.bytes.len;
	if (len == (ArrayIndex)MAX_ARRAY_SIZE)
	{
		return @sema_error_at(context, expr.loc, "The result of the concatenation would exceed max supported length.");
	}
	bool is_bytes = left.const_expr.const_kind == BYTES;
	assert(is_bytes || left.const_expr.const_kind == STRING);
	Type* indexed = type_get_indexed_type(left.type);
	String left_bytes = (String)left.const_expr.bytes.ptr[:len];
	while (true) // RETRY
	{
		(void)sema_cast_const(right);
		assert(expr_is_const(right));
		switch (right.const_expr.const_kind)
		{
			case INTEGER:
				if (is_bytes)
				{
					// 2. Bytes + (i)char => Bytes
					if (!cast_implicit_checked(context, right, type_char, false, failed_ref)) return false;
					char c = (char)int_to_i64(right.const_expr.ixx);
					expr_concat_const_bytes(expr, left.type, true, left_bytes, (String)(&c)[:1], len, 1);
					return true;
				}
				// 1. String + character => String
				if (int_is_neg(right.const_expr.ixx) || int_icomp(right.const_expr.ixx, 0x10FFFF, GT))
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, right.loc, "Cannot concatenate a string with an non-unicode value.");
				}
				expr_concat_character(expr, left.type, left_bytes, len, (ulong)right.const_expr.ixx.i);
				return true;
			case FLOAT:
			case BOOL:
			case ENUM:
			case FAULT:
			case POINTER:
			case TYPEID:
			case MEMBER:
			case REFLECTION:
			case REF:
				if (failed_ref) { *failed_ref = true; return false; }
				return @sema_error_at(context, expr.loc, "Concatenating %s with %s is not possible at compile time.",
				                      type_quoted_error_string(left.type), type_to_error_string(right.type));
			case BYTES:
			case STRING:
				if (len > (ArrayIndex)MAX_ARRAY_SIZE - right.const_expr.bytes.len)
				{
					return @sema_error_at(context, expr.loc, "The result of the concatenation would exceed max supported length.");
				}
				expr_concat_const_bytes(expr, left.type, is_bytes, left_bytes,
				                        (String)right.const_expr.bytes.ptr[:right.const_expr.bytes.len],
				                        len, right.const_expr.bytes.len);
				return true;
			case UNTYPED_LIST:
				if (!cast_implicit_checked(context, right, type_get_inferred_array(indexed), false, failed_ref)) return false;
				continue;
			case SLICE:
			case INITIALIZER:
				if (!cast_implicit_checked(context, right, type_get_inferred_array(indexed), false, failed_ref)) return false;
				if (!sema_cast_const(right))
				{
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, right.loc, "Could not concatenate with the right hand side.");
				}
				expr_contract_array(&right.const_expr, left.const_expr.const_kind);
				continue;
		}
	}
}

// sema_const.c:215 (static)
fn bool sema_append_concat_const_bytes(SemaContext* context, Expr* expr, Expr* list, Expr* element, bool* failed_ref)
{
	Type* indexed = type_get_indexed_type(list.type);
	assert(indexed, "This should always work");
	if (!cast_implicit_checked(context, element, indexed, false, failed_ref)) return false;
	usz str_len = (usz)list.const_expr.bytes.len;
	bool is_bytes = list.const_expr.const_kind == BYTES;
	char* data = calloc_arena(str_len + 2);
	char* current = data;
	if (str_len) mem::copy(current, list.const_expr.bytes.ptr, (sz)str_len);
	current += (sz)str_len;
	current[0] = (char)element.const_expr.ixx.i;
	current[1] = '\0';
	expr.expr_kind = CONST;
	expr.const_expr = {
		.const_kind = list.const_expr.const_kind,
		.bytes = { .ptr = data, .len = (ArrayIndex)str_len + 1 }
	};
	expr.resolve_status = DONE;
	expr.type = is_bytes ? type_get_array(indexed, (ArrayIndex)str_len + 1) : list.type;
	return true;
}

// sema_const.c:239 (static)
fn bool sema_append_const_array_one(SemaContext* context, Expr* expr, Expr* list, Expr* element, bool* failed_ref)
{
	Type* array_type = type_flatten(list.type);
	bool is_slice = list.const_expr.const_kind == SLICE;
	Type* indexed = type_get_indexed_type(is_slice ? list.type : list.const_expr.initializer.type);
	if (!cast_implicit_checked(context, element, indexed, false, failed_ref)) return false;
	if (expr_is_empty_const_slice(list))
	{
		// Create a single length array
		ConstInitializer* first_element = const_init_new_value(element);
		ConstInitializer*[] list_of_elements = {};
		@vec_add(&list_of_elements, first_element);
		list.const_expr.slice_init = const_init_new_array_full(type_get_array(array_type.array.base, 1), list_of_elements);
		expr_replace(expr, list);
		return true;
	}
	ConstInitializer* init = is_slice ? list.const_expr.slice_init : list.const_expr.initializer;
	assert(!type_is_inferred(array_type));
	bool is_vector = type_kind_is_real_vector(array_type.type_kind);
	ArrayIndex len = sema_len_from_const(list) + 1;
	Type* new_inner_type = is_vector ? type_get_vector(indexed, array_type.type_kind, (int)len) : type_get_array(indexed, len);
	Type* new_outer_type = list.type;
	if (!is_slice)
	{
		Type* outer_indexed = type_get_indexed_type(init.type);
		new_outer_type = is_vector ? type_get_vector(outer_indexed, array_type.type_kind, (int)len) : type_get_array(outer_indexed, len);
	}
	switch (init.kind)
	{
		case INIT_ZERO:
			init.kind = INIT_ARRAY;
			const_init_set_type(init, new_inner_type);
			ConstInitializer*[] inits = {};
			@vec_add(&inits, const_init_new_array_value(element, len - 1));
			init.init_array.elements = inits;
			expr_replace(expr, list);
			expr.type = new_outer_type;
		case INIT_ARRAY:
			const_init_set_type(init, new_inner_type);
			@vec_add(&init.init_array.elements, const_init_new_array_value(element, len - 1));
			expr_replace(expr, list);
			expr.type = new_outer_type;
		case INIT_ARRAY_FULL:
			const_init_set_type(init, new_inner_type);
			@vec_add(&init.init_array_full, const_init_new_value(element));
			expr_replace(expr, list);
			expr.type = new_outer_type;
		case INIT_ARRAY_VALUE:
		case INIT_STRUCT:
		case INIT_UNION:
		case INIT_VALUE:
			unreachable();
	}
	return true;
}

// sema_const.c:300 (static)
fn ConstInitializer* expr_const_initializer_from_expr(Expr* expr)
{
	assert(expr.expr_kind == CONST);
	switch (expr.const_expr.const_kind)
	{
		case SLICE:
			return expr.const_expr.slice_init;
		case INITIALIZER:
			return expr.const_expr.initializer;
		default:
			unreachable();
	}
}

<*
 The following valid cases exist:

 1. String/Bytes + ... => String/Bytes
 2. Vector/slice/array + Untyped list => Merged untyped list
 3. Vector/slice/array + arraylike => vector/array iff canonical match, otherwise Untyped list
 4. Untyped list + Vector/array/slice => Merged untyped list
 5. Vector/array/slice + element => Vector/array/slice + 1 len iff canonical match, Untyped list otherwise
 6. Untyped list + element => Untyped list
*>
// sema_const.c:325
fn bool sema_expr_analyse_ct_concat(SemaContext* context, Expr* concat_expr, Expr* left, Expr* right, bool* failed_ref)
{
	assert(concat_expr.resolve_status == RUNNING);
	if (!sema_check_left_right_const(context, left, right, failed_ref)) return false;
	ArrayIndex len = 0;
	TypeKind vec_type = POISONED;
	Type* indexed_type = null;
	Type* element_type = left.type.canonical;
	Type* right_type = right.type.canonical;
	switch (left.const_expr.const_kind)
	{
		case POINTER:
		case FLOAT:
		case INTEGER:
		case BOOL:
		case ENUM:
		case FAULT:
		case TYPEID:
		case REF:
		case MEMBER:
		case REFLECTION:
			if (failed_ref) { *failed_ref = true; return false; }
			return @sema_error_at(context, left.loc, "Only bytes, strings and list-like constants can be concatenated.");
		case BYTES:
		case STRING:
			return sema_concat_bytes_and_other(context, concat_expr, left, right, failed_ref);
		case SLICE:
		case INITIALIZER:
			switch (type_flatten(element_type).type_kind)
			{
				case SIMD_VECTOR:
					vec_type = SIMD_VECTOR;
				case VECTOR:
					vec_type = VECTOR;
				case INFERRED_VECTOR:
				case INFERRED_ARRAY:
					unreachable();
				case SLICE:
				case ARRAY:
					break;
				case STRUCT:
				case UNION:
					if (failed_ref) { *failed_ref = true; return false; }
					return @sema_error_at(context, left.loc, "Only bytes, strings and array-like constants can be concatenated.");
				default:
					unreachable();
			}
			len = sema_len_from_const(left);
			indexed_type = type_get_indexed_type(element_type);
		case UNTYPED_LIST:
			len = left.const_expr.untyped_list.len;
	}
	ArrayIndex len_lhs = len;
	switch (right.const_expr.const_kind)
	{
		case FLOAT:
		case INTEGER:
		case BOOL:
		case ENUM:
		case FAULT:
		case POINTER:
		case TYPEID:
		case MEMBER:
		case REFLECTION:
		case REF:
			return sema_expr_const_append(context, concat_expr, left, right, failed_ref);
		case BYTES:
		case STRING:
			if (left.type == type_untypedlist || indexed_type == right_type) return sema_expr_const_append(context, concat_expr, left, right, failed_ref);
			if (!type_is_integer(indexed_type) || type_size(indexed_type) != 1)
			{
				if (failed_ref) { *failed_ref = true; return false; }
				return @sema_error_at(context, right.loc, "You can't concatenate %s and %s.", type_quoted_error_string(left.type),
				                      type_to_error_string(right_type));
			}
			if (!cast_implicit_checked(context, right, type_get_inferred_array(indexed_type), false, failed_ref)) return false;
			expr_contract_array(&left.const_expr, BYTES);
			return sema_concat_bytes_and_other(context, concat_expr, left, right, failed_ref);
		case UNTYPED_LIST:
			break;
		case INITIALIZER:
			if (!indexed_type && type_is_union_or_strukt(right.const_expr.initializer.type))
			{
				return sema_expr_const_append(context, concat_expr, left, right, failed_ref);
			}
			nextcase SLICE;
		case SLICE:
			if (indexed_type && cast_implicit_silent(context, right, indexed_type, false)) return sema_expr_const_append(context, concat_expr, left, right, failed_ref);
	}
	if (indexed_type && !cast_implicit_silent(context, right, type_get_inferred_array(indexed_type), false))
	{
		indexed_type = null;
	}
	ArrayIndex len_rhs = sema_len_from_const(right);
	if (len > max_array_index() - len_rhs)
	{
		return @sema_error_at(context, left.loc, "Constant expression would exceed the maximum length (%d).", max_array_index());
	}
	len += len_rhs;
	if (!indexed_type)
	{
		Expr*[] untyped_exprs = {};
		Expr*[2] exprs = { left, right };
		for (int i = 0; i < 2; i++)
		{
			Expr* single_expr = exprs[i];
			if (expr_is_const_untyped_list(single_expr))
			{
				foreach (expr_untyped : single_expr.const_expr.untyped_list)
				{
					@vec_add(&untyped_exprs, expr_untyped);
				}
				continue;
			}
			ConstInitializer* init = expr_const_initializer_from_expr(single_expr);
			// Skip zero arrays from slices.
			if (!init) continue;
			switch (init.kind)
			{
				case INIT_UNION:
				case INIT_STRUCT:
				case INIT_ARRAY_VALUE:
				case INIT_VALUE:
					unreachable();
				case INIT_ARRAY_FULL:
					Expr* el;
					foreach (val : init.init_array_full)
					{
						switch (val.kind)
						{
							case INIT_VALUE:
								@vec_add(&untyped_exprs, val.init_value);
							default:
								el = expr_new_expr(CONST, single_expr);
								expr_rewrite_const_initializer(el, val.type, val);
								@vec_add(&untyped_exprs, el);
						}
					}
					continue;
				case INIT_ZERO:
					Type* index_type = type_get_indexed_type(type_flatten(init.type));
					ArrayIndex len_zero = i == 0 ? len_lhs : len_rhs;
					for (ArrayIndex j = 0; j < len_zero; j++)
					{
						Expr* zero = expr_new_expr(CONST, single_expr);
						expr_rewrite_to_const_zero(zero, index_type);
						@vec_add(&untyped_exprs, zero);
					}
					continue;
				case INIT_ARRAY:
					Type* index_type = type_get_indexed_type(type_flatten(init.type));
					ArrayIndex len_zero = i == 0 ? len_lhs : len_rhs;
					ArrayIndex offset = untyped_exprs.len;
					for (ArrayIndex j = 0; j < len_zero; j++)
					{
						Expr* zero = expr_new_expr(CONST, single_expr);
						expr_rewrite_to_const_zero(zero, index_type);
						@vec_add(&untyped_exprs, zero);
					}
					foreach (element : init.init_array.elements)
					{
						assert(element.kind == INIT_ARRAY_VALUE);
						ConstInitializer* inner_element = element.init_array_value.element;
						Expr* inner_expr = untyped_exprs[offset + element.init_array_value.index];
						switch (inner_element.kind)
						{
							case INIT_ZERO:
								break;
							case INIT_STRUCT:
							case INIT_UNION:
							case INIT_ARRAY:
							case INIT_ARRAY_FULL:
							case INIT_ARRAY_VALUE:
								expr_rewrite_const_initializer(inner_expr, index_type, inner_element);
							case INIT_VALUE:
								*inner_expr = *inner_element.init_value;
						}
					}
					continue;
			}
		}
		concat_expr.expr_kind = CONST;
		concat_expr.type = type_untypedlist;
		concat_expr.resolve_status = DONE;
		concat_expr.const_expr = {
			.const_kind = UNTYPED_LIST,
			.untyped_list = untyped_exprs
		};
		return true;
	}
	// Zero slice + zero slice => slice
	if (len == 0)
	{
		expr_rewrite_to_const_zero(concat_expr, type_get_slice(indexed_type));
	}
	Type* type = vec_type == POISONED ? type_get_array(indexed_type, len) : type_get_vector(indexed_type, vec_type, (int)len);
	ConstInitializer* lhs_init = expr_const_initializer_from_expr(left);
	ConstInitializer* rhs_init = expr_const_initializer_from_expr(right);
	if (!rhs_init)
	{
		rhs_init = lhs_init;
		lhs_init = null;
	}
	if (!lhs_init)
	{
		assert(rhs_init);
		expr_rewrite_const_initializer(concat_expr, type, rhs_init);
		return true;
	}

	switch (lhs_init.kind)
	{
		case INIT_UNION:
		case INIT_STRUCT:
		case INIT_ARRAY_VALUE:
		case INIT_VALUE:
			unreachable();
		case INIT_ZERO:
			switch (rhs_init.kind)
			{
				case INIT_ZERO:
					// { 0, 0, 0 } + { 0, 0, 0 }
					expr_rewrite_const_initializer(concat_expr, type, const_init_new_zero(type));
					return true;
				case INIT_ARRAY_FULL:
					// { 0, 0, 0 } + { 1, 2, 3 }
					ConstInitializer*[] inits = {};
					for (ArrayIndex i = 0; i < len_lhs; i++)
					{
						@vec_add(&inits, const_init_new_zero(indexed_type));
					}
					foreach (init : rhs_init.init_array_full)
					{
						@vec_add(&inits, init);
					}
					expr_rewrite_const_initializer(concat_expr, type, const_init_new_array_full(type, inits));
					return true;
				case INIT_ARRAY:
					// { 0, 0, 0 } + { 1 => 3 }
					foreach (element : rhs_init.init_array.elements)
					{
						assert(element.kind == INIT_ARRAY_VALUE);
						element.init_array_value.index += (ArrayIndex)len_lhs;
					}
					const_init_set_type(rhs_init, type);
					expr_rewrite_const_initializer(concat_expr, type, rhs_init);
					return true;
				case INIT_STRUCT:
				case INIT_UNION:
				case INIT_VALUE:
				case INIT_ARRAY_VALUE:
					unreachable();
			}
		case INIT_ARRAY_FULL:
			switch (rhs_init.kind)
			{
				case INIT_UNION:
				case INIT_STRUCT:
				case INIT_ARRAY_VALUE:
				case INIT_VALUE:
					unreachable();
				case INIT_ZERO:
					// { 1, 2, 3 } + { 0, 0, 0 }
					ConstInitializer*[] inits = {};
					foreach (init : lhs_init.init_array_full)
					{
						@vec_add(&inits, init);
					}
					for (ArrayIndex i = 0; i < len_rhs; i++)
					{
						@vec_add(&inits, const_init_new_zero(indexed_type));
					}
					expr_rewrite_const_initializer(concat_expr, type, const_init_new_array_full(type, inits));
					return true;
				case INIT_ARRAY_FULL:
					// { 1, 2, 3 } + { 1, 2, 3 }
					ConstInitializer*[] inits = {};
					foreach (init : lhs_init.init_array_full)
					{
						@vec_add(&inits, init);
					}
					foreach (init : rhs_init.init_array_full)
					{
						@vec_add(&inits, init);
					}
					expr_rewrite_const_initializer(concat_expr, type, const_init_new_array_full(type, inits));
					return true;
				case INIT_ARRAY:
					// { 1, 2, 3 } + { 1 => 3 }
					ConstInitializer*[] inits = {};
					foreach (init : lhs_init.init_array_full)
					{
						@vec_add(&inits, init);
					}
					for (ArrayIndex i = 0; i < len_rhs; i++)
					{
						@vec_add(&inits, const_init_new_zero(indexed_type));
					}
					foreach (element : rhs_init.init_array.elements)
					{
						assert(element.kind == INIT_ARRAY_VALUE);
						inits[element.init_array_value.index + len_lhs] = element.init_array_value.element;
					}
					expr_rewrite_const_initializer(concat_expr, type, const_init_new_array_full(type, inits));
					return true;
			}
		case INIT_ARRAY:
			switch (rhs_init.kind)
			{
				case INIT_UNION:
				case INIT_STRUCT:
				case INIT_ARRAY_VALUE:
				case INIT_VALUE:
					unreachable();
				case INIT_ZERO:
					// { 1 => 3 } + { 0, 0, 0 }
					const_init_set_type(lhs_init, type);
					expr_rewrite_const_initializer(concat_expr, type, lhs_init);
					return true;
				case INIT_ARRAY_FULL:
					// { 1 => 3 } + { 1, 2, 3 }
					ConstInitializer*[] inits = {};
					for (ArrayIndex i = 0; i < len_lhs; i++)
					{
						@vec_add(&inits, const_init_new_zero(indexed_type));
					}
					foreach (element : lhs_init.init_array.elements)
					{
						assert(element.kind == INIT_ARRAY_VALUE);
						inits[element.init_array_value.index] = element.init_array_value.element;
					}
					foreach (init : rhs_init.init_array_full)
					{
						@vec_add(&inits, init);
					}
					expr_rewrite_const_initializer(concat_expr, type, const_init_new_array_full(type, inits));
					return true;
				case INIT_ARRAY:
					// { 1 => 3 } + { 1 => 3 }
					ConstInitializer*[] inits = {};
					foreach (element : lhs_init.init_array.elements)
					{
						@vec_add(&inits, element);
					}
					foreach (element : rhs_init.init_array.elements)
					{
						assert(element.kind == INIT_ARRAY_VALUE);
						element.init_array_value.index += (ArrayIndex)len_lhs;
						@vec_add(&inits, element);
					}
					expr_rewrite_const_initializer(concat_expr, type, const_init_new_array(type, inits));
					return true;
			}
	}
}
