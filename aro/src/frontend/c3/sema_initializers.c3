// Port of c3c src/compiler/sema_initializers.c (revision 54bab366a): plain,
// designated and untyped initializer lists and the ConstInitializer helpers.
//
// Deviations from c3c:
// - `goto NO_MATCH` / `goto RETRY` are expanded in place / turned into loops.
// - sema_expr_analyse_struct_plain_initializer: when an empty anonymous
//   member gets a zero initializer inserted, c3c shifts from `size - 1`,
//   which drops the last element and leaves the appended NULL in the list;
//   the port shifts from `size` (the intended insert). The local `elements`
//   slice is refreshed after the list is changed (c3c's vector pointer is
//   shared until a reallocation).
// - sema_expr_analyse_designator writes the (possibly extended, see
//   sema_resolve_element_for_name's anonymous-member insertions) path back
//   to the designator: a C3 slice copy does not share c3c's vector header.
// - sema_create_const_initializer_from_designated_init reads
//   `designated_init.list` (c3c reads the overlapping `initializer_list`).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_initializers.c:39 (static)
fn bool const_init_local_init_may_be_global_inner(ConstInitializer* init, bool top)
{
	ConstInitializer*[] list;
	int len = -1;
	switch (init.kind)
	{
		case INIT_ZERO:
			return top;
		case INIT_STRUCT:
			list = init.init_struct;
			assert(init.type.decl.strukt.members.len == list.len);
			len = (int)list.len;
		case INIT_UNION:
			return const_init_local_init_may_be_global_inner(init.init_union.element, false);
		case INIT_VALUE:
		{
			Expr* val = init.init_value;
			if (!expr_is_const(val)) return false;
			if (expr_is_const_slice(val)) return false;
			return true;
		}
		case INIT_ARRAY:
			list = init.init_array.elements;
			len = (int)list.len;
		case INIT_ARRAY_FULL:
			list = init.init_array_full;
			len = (int)list.len;
		case INIT_ARRAY_VALUE:
			return const_init_local_init_may_be_global_inner(init.init_array_value.element, false);
	}
	for (int i = 0; i < len; i++)
	{
		ConstInitializer* subinit = list[i];
		if (!const_init_local_init_may_be_global_inner(subinit, false)) return false;
	}
	return true;
}

// sema_initializers.c:80
fn void const_init_rewrite_to_zero(ConstInitializer* init, Type* type)
{
	init.kind = INIT_ZERO;
	const_init_set_type(init, type);
}

// sema_initializers.c:86
fn ConstInitializer* const_init_new_array(Type* type, ConstInitializer*[] elements)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	init.kind = INIT_ARRAY;
	const_init_set_type(init, type);
	init.init_array.elements = elements;
	return init;
}

// sema_initializers.c:95
fn ConstInitializer* const_init_new_array_full(Type* type, ConstInitializer*[] elements)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	init.kind = INIT_ARRAY_FULL;
	const_init_set_type(init, type);
	init.init_array_full = elements;
	return init;
}

// sema_initializers.c:104
fn ConstInitializer* const_init_new_struct(Type* type, Expr*[] elements)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	init.kind = INIT_STRUCT;
	const_init_set_type(init, type);
	ConstInitializer*[] values = {};
	foreach (expr : elements)
	{
		if (expr_is_const_initializer(expr))
		{
			@vec_add(&values, expr.const_expr.initializer);
			continue;
		}
		@vec_add(&values, const_init_new_value(expr));
	}
	init.init_struct = values;
	return init;
}

// sema_initializers.c:123
fn ConstInitializer* const_init_new_union(Type* type, ArrayIndex index, Expr* value)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	const_init_set_type(init, type);
	init.kind = INIT_UNION;
	init.init_union.index = index;
	if (expr_is_const_initializer(value))
	{
		init.init_union.element = value.const_expr.initializer;
	}
	else
	{
		init.init_union.element = const_init_new_value(value);
	}
	return init;
}

// sema_initializers.c:140
fn ConstInitializer* const_init_new_array_value(Expr* expr, ArrayIndex index)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	const_init_set_type(init, expr.type);
	init.kind = INIT_ARRAY_VALUE;
	init.init_array_value.index = index;
	init.init_array_value.element = const_init_new_value(expr);
	return init;
}

// sema_initializers.c:150
fn ConstInitializer* const_init_new_zero_array_value(Type* type, ArrayIndex index)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	const_init_set_type(init, type);
	init.kind = INIT_ARRAY_VALUE;
	init.init_array_value.index = index;
	init.init_array_value.element = const_init_new_zero(type);
	return init;
}

// sema_initializers.c:159
fn ConstInitializer* const_init_new_zero(Type* type)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	init.kind = INIT_ZERO;
	const_init_set_type(init, type);
	return init;
}

// sema_initializers.c:166
fn bool const_init_local_init_may_be_global(ConstInitializer* init)
{
	return const_init_local_init_may_be_global_inner(init, true);
}

// sema_initializers.c:171 (static)
fn void sema_not_enough_elements_error(SemaContext* context, Expr* initializer, int element)
{
	if (element == 0)
	{
		@sema_error_at(context, initializer.loc, "The initializer is missing elements.");
		return;
	}
	@sema_error_at(context, initializer.initializer_list[element - 1].loc, "Too few elements in initializer, there should be elements after this one.");
}

<* Perform analysis for a plain initializer, that is one initializing all fields. *>
// sema_initializers.c:185 (static)
fn bool sema_expr_analyse_struct_plain_initializer(SemaContext* context, Decl* assigned, Expr* initializer, bool* no_match_ref)
{
	assert(assigned.resolve_status == DONE);
	Expr*[] elements = initializer.initializer_list;
	Decl*[] members = assigned.strukt.members;
	ArrayIndex size = (ArrayIndex)elements.len;
	int elements_needed = decl_count_elements(assigned);

	// 1. For struct number of members must be the same as the size of the struct.
	//    Since we already handled the case with an empty initializer before going here
	//    zero entries must be an error.
	assert(size > 0, "We should already have handled the size == 0 case.");

	// 2. We don't support this actually, but we used to. Maybe we will in the future.
	if (elements_needed == 0)
	{
		if (no_match_ref) { *no_match_ref = true; return false; }
		// Generate a nice error message for zero.
		return @sema_error_at(context, elements[0].loc, "Too many elements in initializer, it must be empty.");
	}

	bool optional = false;

	bool is_bitstruct = assigned.decl_kind == BITSTRUCT;
	if (is_bitstruct && assigned.strukt.overlap)
	{
		if (assigned.strukt.members.len > 1 && elements.len > 1)
		{
			return @sema_error_at(context, elements[0].loc, "Bitstructs with @overlap must use designated initialization.");
		}
	}

	// 3. Loop through all elements.
	ArrayIndex max_loop = size > elements_needed ? size : (ArrayIndex)elements_needed;
	for (ArrayIndex i = 0; i < max_loop; i++)
	{
		// 4. Check if we exceeded the list of elements in the struct/union.
		//    This way we can check the other elements which might help the
		//    user pinpoint where they put the double elements.
		if (i >= elements_needed)
		{
			if (no_match_ref) { *no_match_ref = true; return false; }
			assert(i < size);
			return @sema_error_at(context, elements[i].loc, "Too many elements in initializer, expected only %d.", elements_needed);
		}
		// 5. We might have anonymous members
		Decl* member = members[i];
		if (member.decl_kind != VAR && !member.name.ptr)
		{
			int sub_element_count = decl_count_elements(member);
			if (!sub_element_count)
			{
				@vec_add(&initializer.initializer_list, null);
				for (int j = (int)size; j > i; j--)
				{
					initializer.initializer_list[j] = initializer.initializer_list[j - 1];
				}
				Expr* new_initializer = expr_new(CONST, initializer.loc);
				expr_rewrite_const_initializer(new_initializer, member.type, const_init_new_zero(type_flatten(member.type)));
				initializer.initializer_list[i] = new_initializer;
				elements = initializer.initializer_list;
				size += 1;
				continue;
			}
			if (i >= size)
			{
				if (no_match_ref) { *no_match_ref = true; return false; }
				sema_not_enough_elements_error(context, initializer, (int)i);
				return false;
			}
			Expr* new_initializer = expr_new(INITIALIZER_LIST, elements[i].loc);
			ArrayIndex max_index_to_copy = i + sub_element_count < size ? i + sub_element_count : size;
			for (ArrayIndex j = i; j < max_index_to_copy; j++)
			{
				@vec_add(&new_initializer.initializer_list, elements[j]);
			}
			int reduce_by = (int)(max_index_to_copy - i - 1);
			size -= reduce_by;
			elements_needed -= reduce_by;
			max_loop = size > elements_needed ? size : (ArrayIndex)elements_needed;
			assert(size <= initializer.initializer_list.len);
			@vec_resize(&initializer.initializer_list, (usz)size);
			elements = initializer.initializer_list;
			elements[i] = new_initializer;
		}
		if (i >= size)
		{
			if (no_match_ref) { *no_match_ref = true; return false; }
			sema_not_enough_elements_error(context, initializer, (int)i);
			return false;
		}
		Expr* element = elements[i];
		// 6. We know the required type, so resolve the expression.
		if (!sema_analyse_expr_rhs(context, members[i].type, element, true, no_match_ref, false)) return false;
		if (member.decl_kind == VAR && member.var_decl.kind == BITMEMBER)
		{
			if (!sema_bit_assignment_check(context, element, members[i], no_match_ref)) return false;
		}
		optional = optional || @is_optional(element);
	}
	assert(initializer.type);
	if (optional) initializer.type = type_get_optional(initializer.type);

	// 6. There's the case of too few values as well. Mark the last field as wrong.
	assert(elements_needed <= size);
	initializer.resolve_status = DONE;
	if (expr_is_runtime_const(initializer))
	{
		foreach (element : elements) sema_cast_const(element);
		bool is_union = type_flatten(initializer.type).type_kind == UNION;
		assert(!is_union || elements.len == 1);
		ConstInitializer* init;
		if (is_union)
		{
			Expr* expr = elements[0];
			init = const_init_new_union(initializer.type, 0, expr);
		}
		else
		{
			init = const_init_new_struct(initializer.type, elements);
		}
		expr_rewrite_const_initializer(initializer, initializer.type, init);
	}

	// 7. Done!
	return true;
}

// sema_initializers.c:315
fn Expr* sema_create_struct_from_expressions(Decl* struct_decl, SourceLocId loc, Expr*[] exprs)
{
	return expr_new_const_initializer(loc, struct_decl.type,
	                                  const_init_new_struct(struct_decl.type, exprs));
}

<* Perform analysis for a plain initializer, that is one initializing all fields. *>
// sema_initializers.c:325 (static)
fn bool sema_expr_analyse_array_plain_initializer(SemaContext* context, Type* assigned, Type* flattened, Expr* initializer, bool* no_match_ref)
{
	Expr*[] elements = initializer.initializer_list;
	bool inferred_len = type_len_is_inferred(flattened);

	// We have the case where "Foo = int[*]"
	if (inferred_len && !type_len_is_inferred(assigned))
	{
		assert(assigned.type_kind == ALIAS);
		assert(assigned.decl.decl_kind == TYPE_ALIAS);
		while (assigned.type_kind == ALIAS) assigned = assigned.decl.type;
		assert(type_len_is_inferred(assigned));
	}
	// Prefer the typedef index: define Bar = int; Bar[1] => Bar and not int
	Type* inner_type = type_get_indexed_type(assigned);
	assert(inner_type);
	int count = (int)elements.len;
	int expected_members = (int)flattened.array.len;
	assert(count > 0, "We should already have handled the size == 0 case.");

	if (expected_members == 0 && !inferred_len)
	{
		if (no_match_ref) { *no_match_ref = true; return false; }
		// Generate a nice error message for zero.
		return @sema_error_at(context, elements[0].loc, "Too many elements in initializer, it must be empty.");
	}
	if (expected_members > 0 && count != expected_members)
	{
		return @sema_error_at(context, elements[0].loc, "Too %s (%d) elements in initializer, expected %d.", count > expected_members ? "many" : "few", count, expected_members);
	}

	bool optional = false;
	bool inner_is_inferred = type_len_is_inferred(inner_type);
	Type* inferred_element = null;
	if (!sema_resolve_type_structure(context, inner_type)) return false;
	for (int i = 0; i < count; i++)
	{
		Expr* element = elements[i];
		if (!inferred_len && i >= expected_members)
		{
			if (no_match_ref) { *no_match_ref = true; return false; }
			return @sema_error_at(context, element.loc, "Too many elements in initializer, expected only %d.", expected_members);
		}

		if (!sema_analyse_expr_rhs(context, inner_type, element, true, no_match_ref, false)) return false;
		if (inner_is_inferred)
		{
			if (inferred_element)
			{
				if (!cast_implicit_checked(context, element, inferred_element, false, no_match_ref))
				{
					if (!no_match_ref) @sema_note_prev_at(elements[0].loc, "Type inferred from here.");
					return false;
				}
			}
			else
			{
				inferred_element = element.type;
			}
		}

		optional = optional || @is_optional(element);
	}
	if (inner_is_inferred)
	{
		if (!inferred_element)
		{
			if (no_match_ref) { *no_match_ref = true; return false; }
			return @sema_error_at(context, initializer.loc, "Zero sized elements are not allowed when inferring size.");
		}
		inner_type = inferred_element;
	}
	if (inferred_len)
	{
		initializer.type = type_from_inferred(flattened, inner_type, count);
	}
	else
	{
		initializer.type = assigned;
	}

	assert(initializer.type);
	if (optional) initializer.type = type_get_optional(initializer.type);

	if (!inferred_len && expected_members > count)
	{
		if (no_match_ref) { *no_match_ref = true; return false; }
		return @sema_error_at(context, elements[count - 1].loc, "Too few elements in initializer, %d elements are needed. Current count: %d.", expected_members, count);
	}

	initializer.resolve_status = DONE;
	if (expr_is_runtime_const(initializer))
	{
		ConstInitializer*[] inits = {};
		foreach (expr : elements)
		{
			if (expr_is_const_initializer(expr))
			{
				@vec_add(&inits, expr.const_expr.initializer);
				continue;
			}
			@vec_add(&inits, const_init_new_value(expr));
		}
		ConstInitializer* const_init = const_init_new_array_full(initializer.type, inits);
		expr_rewrite_const_initializer(initializer, initializer.type, const_init);
	}

	// 7. Done!
	return true;
}

// sema_initializers.c:440 (static)
fn bool sema_expr_analyse_untyped_initializer(SemaContext* context, Expr* initializer, bool* no_match_ref)
{
	Expr*[] init_list = initializer.initializer_list;
	foreach (element : init_list)
	{
		if (!sema_analyse_expr_rvalue(context, element)) return false;
		if (!sema_cast_const(element))
		{
			if (no_match_ref)
			{
				*no_match_ref = true;
				return false;
			}
			return @sema_error_at(context, element.loc, "An untyped list can only have "
			                      "constant elements, you can try "
			                      "to type the list by prefixing the type and possibly enclosing it in parentheses, "
			                      "e.g. '((int[2]){ a, b })'.");
		}
	}
	initializer.expr_kind = CONST;
	initializer.const_expr = { .const_kind = UNTYPED_LIST, .untyped_list = init_list };
	initializer.type = type_untypedlist;
	initializer.resolve_status = DONE;
	return true;
}

// sema_initializers.c:466 (static)
fn bool sema_expr_analyse_designated_initializer(SemaContext* context, Type* assigned, Type* flattened, Expr* initializer, bool* no_match_ref)
{
	Expr*[] init_expressions = initializer.designated_init.list;
	Expr* splat = initializer.designated_init.splat;
	if (splat)
	{
		if (!sema_analyse_expr_rvalue(context, splat)) return false;
		sema_cast_const(splat);
		if (@is_optional(splat))
		{
			return @sema_error_at(context, splat.loc, "An optional splat is not permitted.");
		}
	}
	Type* original = flattened.canonical;
	bool is_structlike = type_is_union_or_strukt(original) || original.type_kind == BITSTRUCT;
	ArrayIndex max_index = -1;
	bool optional = false;
	Type* inner_type = null;
	bool is_inferred = type_is_infer_type(flattened);
	foreach (expr : init_expressions)
	{
		Decl* member;
		Type* result = sema_expr_analyse_designator(context, original, expr, &max_index, &member, no_match_ref);
		if (!result) return false;
		bool is_bitmember = member && member.decl_kind == VAR && member.var_decl.kind == BITMEMBER;
		Expr* value = expr.designator_expr.value;
		if (!value && is_bitmember && member.var_decl.start_bit == member.var_decl.end_bit && type_flatten(result) == type_bool)
		{
			value = expr_new_const_bool(0, result, true);
			expr.designator_expr.value = value;
		}
		if (!value) return @sema_error_at(context, expr.loc, "This initializer needs a value.");
		if (!sema_analyse_expr_rhs(context, result, value, true, no_match_ref, false)) return false;
		if (is_bitmember)
		{
			if (!sema_bit_assignment_check(context, value, member, no_match_ref)) return false;
		}
		optional = optional || @is_optional(value);
		expr.resolve_status = DONE;
		if (!inner_type)
		{
			inner_type = type_no_optional(value.type);
		}
	}
	Type* type;
	if (!is_structlike && is_inferred)
	{
		if (max_index >= (ArrayIndex)MAX_ARRAY_SIZE)
		{
			return @sema_error_at(context, initializer.loc, "Inferred size would exceed max supported array size (%d).", (long)MAX_ARRAY_SIZE);
		}
		type = type_from_inferred(flattened, flattened.array.base, (int)(max_index + 1));
	}
	else
	{
		if (!is_structlike && type_is_inferred(flattened))
		{
			return @sema_error_at(context, initializer.loc, "Inferring size when having non-top inference is not supported.");
		}
		type = assigned;
	}
	if (splat && type.canonical != splat.type.canonical)
	{
		if (type_is_subtype(splat.type.canonical, type.canonical))
		{
			Decl* decl = original.decl;
			Expr* designator = expr_new(DESIGNATOR, initializer.loc);
			DesignatorElement*[] elements = {};
			while (true)
			{
				DesignatorElement* designator_element = calloc_arena(DesignatorElement::size);
				designator_element.kind = FIELD;
				designator_element.index = 0;
				@vec_add(&elements, designator_element);
				// c3c: assert(decl.is_substruct); -- C assert, compiled out in c3c release builds
				Decl* member = decl.strukt.members[0];
				if (member.type.canonical == splat.type) break;
				decl = member;
			}
			designator.resolve_status = DONE;
			designator.designator_expr.path = elements;
			designator.designator_expr.value = splat;
			designator.type = splat.type;
			@vec_insert_first(&initializer.designated_init.list, designator);
			initializer.designated_init.splat = null;
		}
		else
		{
			return @sema_error_at(context, splat.loc, "Splat type does not match initializer type.");
		}
	}
	initializer.type = type_add_optional(type, optional);
	initializer.resolve_status = DONE;
	if (!optional && expr_is_runtime_const(initializer))
	{
		ConstInitializer* const_init = calloc_arena(ConstInitializer::size);
		sema_create_const_initializer_from_designated_init(const_init, initializer);
		expr_rewrite_const_initializer(initializer, initializer.type, const_init);
	}
	return true;
}

// sema_initializers.c:570 (static)
fn bool sema_expr_analyse_initializer(SemaContext* context, Type* assigned_type, Type* flattened, Expr* expr, bool* no_match_ref)
{
	// Note at this point this we either have
	// EXPR_DESIGNATED_INITIALIZER_LIST
	// or EXPR_INITIALIZER_LIST
	// or EXPR_CONST with a ConstInitializer

	// 1. Designated initializer is separately evaluated.
	if (expr.expr_kind == DESIGNATED_INITIALIZER_LIST)
	{
		return sema_expr_analyse_designated_initializer(context, assigned_type, flattened, expr, no_match_ref);
	}

	if (expr.expr_kind == CONST)
	{
		assert(expr.const_expr.const_kind == INITIALIZER);
		return cast_implicit_checked(context, expr, assigned_type, false, no_match_ref);
	}
	assert(expr.expr_kind == INITIALIZER_LIST);

	// 2. Grab the expressions inside.
	Expr*[] init_expressions = expr.initializer_list;

	int init_expression_count = (int)init_expressions.len;

	// 3. Zero size init will initialize to empty.
	if (init_expression_count == 0)
	{
		if (type_len_is_inferred(assigned_type))
		{
			if (no_match_ref) { *no_match_ref = true; return false; }
			return @sema_error_at(context, expr.loc, "Zero length arrays / vectors are not permitted.");
		}
		if (flattened == type_untypedlist)
		{
			expr_rewrite_const_untyped_list(expr, {});
			return true;
		}
		expr_rewrite_const_initializer(expr, assigned_type, const_init_new_zero(flattened));
		return true;
	}

	// 4. We might have a complist, because were analyzing $foo = { ... } or similar.
	if (assigned_type == type_untypedlist)
	{
		return sema_expr_analyse_untyped_initializer(context, expr, no_match_ref);
	}

	// 5. If not, then we see if we have an array.
	if (flattened.type_kind == UNTYPEDLIST ||
		flattened.type_kind == ARRAY ||
		flattened.type_kind == INFERRED_ARRAY ||
		flattened.type_kind == FLEXIBLE_ARRAY ||
		flattened.type_kind == SLICE ||
		type_kind_is_any_vector(flattened.type_kind))
	{
		return sema_expr_analyse_array_plain_initializer(context, assigned_type, flattened, expr, no_match_ref);
	}

	expr.type = assigned_type;
	return sema_expr_analyse_struct_plain_initializer(context, flattened.decl, expr, no_match_ref);
}

<* Create a const initializer. *>
// sema_initializers.c:639 (static)
fn void sema_create_const_initializer_from_designated_init(ConstInitializer* const_init, Expr* initializer)
{
	// Flatten the type since the external type might be typedef or a distinct type.
	Type* flattened = type_flatten(initializer.type);
	if (initializer.designated_init.splat)
	{
		Expr* splat = initializer.designated_init.splat;
		assert(expr_is_const_initializer(splat));
		*const_init = *splat.const_expr.initializer;
	}
	else
	{
		const_init_rewrite_to_zero(const_init, flattened);
	}
	assert(type_flatten(initializer.type).type_kind != SLICE);
	// Loop through the initializers.
	foreach (expr : initializer.designated_init.list)
	{
		DesignatorElement*[] path = expr.designator_expr.path;
		Expr* value = expr.designator_expr.value;
		assert(value);
		sema_update_const_initializer_with_designator(const_init, path.ptr, path.ptr + path.len, value);
	}
}

// sema_initializers.c:664
fn void sema_invert_bitstruct_const_initializer(ConstInitializer* initializer)
{
	Decl*[] members = initializer.type.decl.strukt.members;
	int len = (int)members.len;

	// Expand
	if (initializer.kind == INIT_ZERO)
	{
		initializer.kind = INIT_STRUCT;
		initializer.init_struct = {};
		for (int i = 0; i < len; i++)
		{
			@vec_add(&initializer.init_struct, const_init_new_zero(type_flatten(members[i].type)));
		}
	}

	assert(initializer.init_struct.len == len);
	foreach (i, init : initializer.init_struct)
	{
		Type* type = init.type;
		if (type == type_bool)
		{
			if (init.kind == INIT_ZERO)
			{
				const_init_rewrite_to_value(init, expr_new_const_bool(0, init.type, true));
				continue;
			}
			init.init_value.const_expr.b = !init.init_value.const_expr.b;
			continue;
		}
		Decl* member = members[i];
		int bits = member.var_decl.end_bit - member.var_decl.start_bit;
		if (init.kind == INIT_ZERO)
		{
			const_init_rewrite_to_value(init, expr_new_const_int(0, init.type, 0));
		}
		Int res = init.init_value.const_expr.ixx;
		res = int_not(res);
		Int neg = int_not({ .type = res.type });
		int bits_used = 128 - (int)i128_clz(&neg.i);
		if (bits_used > bits)
		{
			neg.i = i128_lshr64(neg.i, (ulong)(bits_used - bits));
			res = int_and(res, neg);
		}
		init.init_value.const_expr.ixx = res;
	}
}

// sema_initializers.c:714
fn ConstInitializer* sema_merge_bitstruct_const_initializers(ConstInitializer* lhs, ConstInitializer* rhs, BinaryOp op)
{
	if (rhs.kind == INIT_ZERO)
	{
		ConstInitializer* temp = lhs;
		lhs = rhs;
		rhs = temp;
	}

	if (lhs.kind == INIT_ZERO)
	{
		if (rhs.kind == INIT_ZERO)
		{
			lhs.kind = INIT_ZERO;
			return lhs;
		}
		switch (op)
		{
			case BIT_OR:
			case BIT_XOR:
				return rhs;
			case BIT_AND:
				lhs.kind = INIT_ZERO;
				return lhs;
			default:
				unreachable();
		}
	}
	assert(lhs.kind == INIT_STRUCT && rhs.kind == INIT_STRUCT);
	ConstInitializer*[] lhs_inits = lhs.init_struct;
	ConstInitializer*[] rhs_inits = rhs.init_struct;
	Decl*[] members = lhs.type.decl.strukt.members;
	int len = (int)members.len;
	for (int i = 0; i < len; i++)
	{
		ConstInitializer* init_lhs = lhs_inits[i];
		ConstInitializer* init_rhs = rhs_inits[i];
		// Switch to check const int in a simple way.
		if (init_rhs.kind == INIT_ZERO)
		{
			ConstInitializer* temp = init_lhs;
			init_lhs = init_rhs;
			init_rhs = temp;
		}
		if (init_lhs.kind == INIT_ZERO)
		{
			lhs_inits[i] = op == BIT_AND ? init_lhs : init_rhs;
			continue;
		}
		// We know switch happened, init_lhs == init_lhs[i]
		Expr* lhs_expr = init_lhs.init_value;
		Expr* rhs_expr = init_rhs.init_value;
		if (init_lhs.type == type_bool)
		{
			switch (op)
			{
				case BIT_OR:
					lhs_expr.const_expr.b |= rhs_expr.const_expr.b;
				case BIT_XOR:
					lhs_expr.const_expr.b ^= rhs_expr.const_expr.b;
				case BIT_AND:
					lhs_expr.const_expr.b &= rhs_expr.const_expr.b;
				default:
					unreachable();
			}
			continue;
		}
		assert(type_is_integer(type_flatten(init_lhs.type)));
		switch (op)
		{
			case BIT_AND:
				lhs_expr.const_expr.ixx = int_and(lhs_expr.const_expr.ixx, rhs_expr.const_expr.ixx);
			case BIT_XOR:
				lhs_expr.const_expr.ixx = int_xor(lhs_expr.const_expr.ixx, rhs_expr.const_expr.ixx);
			case BIT_OR:
				lhs_expr.const_expr.ixx = int_or(lhs_expr.const_expr.ixx, rhs_expr.const_expr.ixx);
			default:
				unreachable();
		}
	}
	return lhs;
}

// sema_initializers.c:803
fn bool sema_expr_analyse_initializer_list(SemaContext* context, Type* to, Expr* expr, bool* no_match_ref)
{
	if (!to) to = type_untypedlist;
	assert(to);
	Type* flattened = type_flatten(to);
	if (expr.expr_kind == INITIALIZER_LIST && !sema_expand_vasplat_exprs(context, &expr.initializer_list, null)) return false;
	bool is_zero_init = (expr.expr_kind == INITIALIZER_LIST && !expr.initializer_list.len) ||
			(expr.resolve_status == DONE && sema_initializer_list_is_empty(expr));

	if (!sema_resolve_type_structure(context, to)) return false;
	switch (flattened.type_kind)
	{
		case ANY:
		case INTERFACE:
			if (is_zero_init)
			{
				expr_rewrite_to_const_zero(expr, to);
				return true;
			}
		case UNTYPEDLIST:
		case STRUCT:
		case UNION:
		case BITSTRUCT:
		case VECTOR: case INFERRED_VECTOR: case SIMD_VECTOR: case ARRAY: case INFERRED_ARRAY: case FLEXIBLE_ARRAY:
			return sema_expr_analyse_initializer(context, to, flattened, expr, no_match_ref);
		case SLICE:
		{
			if (is_zero_init)
			{
				if (type_len_is_inferred(flattened.array.base))
				{
					return @sema_error_at(context, expr.loc, "Inferring the slice inner type from an empty initializer is not possible.");
				}
				expr_rewrite_const_empty_slice(expr, to);
				return true;
			}
			// Resolve this as an inferred array.
			Type* type = type_get_inferred_array(flattened.array.base);
			if (!sema_expr_analyse_initializer(context, type, type, expr, no_match_ref)) return false;
			if (context.call_env.kind == ENV_FUNCTION && type_size(expr.type) > compiler.build.max_stack_object_size * 1024)
			{
				usz size = (usz)type_size(expr.type);
				return @sema_error_at(context,
					expr.loc, "The size of this stack allocated expression (%s%d Kb) exceeds the maximum allowed stack object size (%d Kb), "
					"you can increase this limit with --max-stack-object-size, but be aware that too large objects "
					"allocated on the stack may lead to the stack running out of memory.", size % 1024 == 0 ? "" : "over ",
					size / 1024,
					compiler.build.max_stack_object_size);
			}
			if (expr_is_const_initializer(expr))
			{
				ConstInitializer* init = expr.const_expr.initializer;
				expr.const_expr.slice_init = init;
				expr.const_expr.const_kind = SLICE;
				expr.type = to;
				return true;
			}
			expr.resolve_status = DONE;
			expr_insert_addr(expr);
			if (!sema_analyse_expr_rvalue(context, expr)) return false;
			if (no_match_ref)
			{
				if (!cast_explicit_silent(context, expr, to)) { *no_match_ref = true; return false; }
				return true;
			}
			return cast_explicit(context, expr, to);
		}
		case POINTER:
		case FUNC_PTR:
			if (is_zero_init)
			{
				expr_rewrite_to_const_zero(expr, to);
				return true;
			}
			if (no_match_ref) { *no_match_ref = true; return false; }
			return @sema_error_at(context, expr.loc, "Pointers cannot be initialized using an initializer list, instead you need to take the address of an array.");
		case VOID:
		case POISONED:
		case FUNC_RAW:
		case ALIAS:
		case OPTIONAL:
		case TYPEINFO:
		case MEMBER:
		case REFLECTION:
			if (no_match_ref) { *no_match_ref = true; return false; }
			return @sema_error_at(context, expr.loc, "You cannot use %s with an initializer list.", type_quoted_error_string(to));
		default:
			if (is_zero_init)
			{
				expr_rewrite_to_const_zero(expr, flattened);
				expr.type = to;
				return true;
			}
	}
	if (no_match_ref) { *no_match_ref = true; return false; }
	return @sema_error_at(context, expr.loc, "You cannot use %s with a non-empty initializer list.", type_quoted_error_string(to));
}

// sema_initializers.c:907
fn void const_init_rewrite_to_value(ConstInitializer* const_init, Expr* value)
{
	// Possibly this is already a const initializers, in that case
	// overwrite what is inside, eg [1] = { .a = 1 }
	if (expr_is_const_initializer(value))
	{
		*const_init = *value.const_expr.initializer;
		value.const_expr.initializer = const_init;
		assert(type_flatten(value.type).type_kind != SLICE);
		return;
	}
	if (value.expr_kind == IDENTIFIER)
	{
		Decl* ident = decl_flatten(value.ident_expr);
		assert(ident.decl_kind == VAR);
		assert(ident.var_decl.kind == CONST);
		const_init_rewrite_to_value(const_init, copy_expr_single(ident.var_decl.init_expr));
		return;
	}
	const_init.init_value = value;
	const_init_set_type(const_init, value.type);
	const_init.kind = INIT_VALUE;
}

// sema_initializers.c:931
fn bool const_init_is_zero(ConstInitializer* init)
{
	while (true) // RETRY:
	{
		switch (init.kind)
		{
			case INIT_ZERO:
				return true;
			case INIT_STRUCT:
			{
				foreach (i : init.init_struct)
				{
					if (!const_init_is_zero(i)) return false;
				}
				return true;
			}
			case INIT_UNION:
				init = init.init_union.element;
				continue;
			case INIT_VALUE:
				return expr_is_zero(init.init_value);
			case INIT_ARRAY:
			{
				foreach (i : init.init_array.elements)
				{
					if (!const_init_is_zero(i)) return false;
				}
				return true;
			}
			case INIT_ARRAY_FULL:
			{
				foreach (i : init.init_array_full)
				{
					if (!const_init_is_zero(i)) return false;
				}
				return true;
			}
			case INIT_ARRAY_VALUE:
				return const_init_is_zero(init.init_array_value.element);
		}
		unreachable();
	}
}

// sema_initializers.c:972
fn ConstInitializer* const_init_new_value(Expr* value)
{
	ConstInitializer* init = calloc_arena(ConstInitializer::size);
	const_init_rewrite_to_value(init, value);
	return init;
}

<* Update a struct element, e.g. { .a = 1 } or { .a[12] = { .b } } *>
// sema_initializers.c:982 (static)
fn void sema_update_const_initializer_with_designator_struct(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	// Get the current path element that we're processing
	DesignatorElement* element = curr[0];
	assert(element.kind == FIELD);
	DesignatorElement** next_element = curr + 1;
	bool is_last_path_element = next_element == end;

	Decl*[] elements = const_init.type.decl.strukt.members;

	// Convert a zero struct and expand it into all its parts.
	if (const_init.kind == INIT_ZERO)
	{
		if (is_last_path_element && sema_initializer_list_is_empty(value))
		{
			// In this case we can ignore it.
			return;
		}
		const_init.init_struct = {};
		// Allocate array containing all elements { a, b, c ... }
		foreach (el : elements)
		{
			// Create zero initializers for each of those { a: zeroinit, b: zeroinit, ... }
			@vec_add(&const_init.init_struct, const_init_new_zero(type_flatten(el.type)));
		}
		// Change type to CONST_INIT_STRUCT since we expanded.
		const_init.kind = INIT_STRUCT;
	}

	// We should always have expanded the struct at this point.
	assert(const_init.kind == INIT_STRUCT);

	// Find the ConstInitializer to change
	ConstInitializer* sub_element = const_init.init_struct[element.index];

	// If this isn't the last element, we recurse.
	if (!is_last_path_element)
	{
		sema_update_const_initializer_with_designator(sub_element, next_element, end, value);
		return;
	}

	// Otherwise we update the value in that particular element.
	const_init_rewrite_to_value(sub_element, value);
}

<*
 Update a union element, which is different from structs, since we're here
 only keeping a single value.
 Note that if we have two fields "a" and "b", then in this case { .b = 2, .a = 1 },
 we will completely discard the information in ".b = 2", even if there had been
 an overlap. In essence we're implicitly clearing the memory when we assign to .a, meaning
 we are allowed to completely overwrite the "memory" of .b
*>
// sema_initializers.c:1039 (static)
fn void sema_update_const_initializer_with_designator_union(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	DesignatorElement* element = curr[0];
	assert(element.kind == FIELD);
	ConstInitializer* sub_element = const_init.init_union.element;

	// If it's an empty initializer, just clear everything back to CONST_INIT_ZERO
	// That is we get for example: { .b = { 1, 3 }, .a = { } }. This would then simply
	// become { }
	DesignatorElement** next_element = curr + 1;
	bool is_at_last_path_element = next_element == end;
	if (is_at_last_path_element && sema_initializer_list_is_empty(value))
	{
		const_init.kind = INIT_ZERO;
		return;
	}

	// If we currently have a zero, then we create a sub element that is zero.
	if (const_init.kind == INIT_ZERO)
	{
		sub_element = const_init.init_union.element = calloc_arena(ConstInitializer::size);
		sub_element.kind = INIT_ZERO;
		const_init.init_union.element = sub_element;
	}
	else if (element.index != const_init.init_union.index)
	{
		// We will zero out the sub element if it wasn't a union
		sub_element.kind = INIT_ZERO;
	}

	// Update of the sub element.
	const_init_set_type(sub_element, const_init.type.decl.strukt.members[element.index].type);
	// And the index
	const_init.init_union.index = element.index;

	// And the type
	const_init.kind = INIT_UNION;

	// If we're not at the last element in the path, descend further.
	if (!is_at_last_path_element)
	{
		sema_update_const_initializer_with_designator(sub_element, next_element, end, value);
		return;
	}

	// Otherwise just set the current type.
	const_init_rewrite_to_value(sub_element, value);
}

// sema_initializers.c:1091 (static)
fn ConstInitializer* sema_update_const_initializer_at_index(ConstInitializer* const_init, Type* element_type, ArrayIndex index, ArrayIndex* insert_index_ref)
{
	if (const_init.kind == INIT_ARRAY_FULL)
	{
		return const_init.init_array_full[index];
	}

	ConstInitializer*[] array_elements = const_init.init_array.elements;
	ArrayIndex insert_index = *insert_index_ref;
	ArrayIndex array_count = (ArrayIndex)array_elements.len;
	// Walk to the insert point or until we reached the end of the array.
	while (insert_index < array_count && array_elements[insert_index].init_array_value.index < index)
	{
		insert_index++;
	}
	// Pick up the initializer at the insert point.
	ConstInitializer* initializer = insert_index < array_count ? array_elements[insert_index] : null;

	// If we don't have an initializer, the location needs to be at the end.
	// Create and append:
	if (!initializer)
	{
		initializer = const_init_new_zero_array_value(element_type, index);
		@vec_add(&array_elements, initializer);
		array_count++;
	}
	else
	{
		// If we already have an initializer "found"
		// it might be after the index. In this case, we
		// need to do an insert.
		if (initializer.init_array_value.index != index)
		{
			assert(initializer.init_array_value.index > insert_index);

			// First we add a null at the end.
			@vec_add(&array_elements, null);
			// Shift all values one step up:
			for (ArrayIndex i = array_count; i > insert_index; i--)
			{
				array_elements[i] = array_elements[i - 1];
			}
			// Then we create our new entry.
			initializer = const_init_new_zero_array_value(element_type, index);
			// And assign it to the location.
			array_elements[insert_index] = initializer;
		}
	}

	const_init.init_array.elements = array_elements;
	*insert_index_ref = insert_index;
	return initializer.init_array_value.element;
}

// sema_initializers.c:1147
fn void const_init_rewrite_array_at(ConstInitializer* const_init, Expr* value, ArrayIndex index)
{
	// Expand zero into array.
	if (const_init.kind == INIT_ZERO)
	{
		const_init.kind = INIT_ARRAY;
		const_init.init_array.elements = {};
	}
	ConstInitializer* inner_value;
	if (const_init.kind == INIT_ARRAY_FULL)
	{
		inner_value = const_init.init_array_full[index];
	}
	else
	{
		// c3c: assert(const_init.kind == INIT_ARRAY); -- C assert, compiled out in c3c release builds
		Type* element_type = type_flatten(const_init.type.array.base);

		ArrayIndex insert_index = 0;
		inner_value = sema_update_const_initializer_at_index(const_init, element_type, index, &insert_index);
	}
	const_init_rewrite_to_value(inner_value, value);
}

<* Update an array { [2] = 1 } *>
// sema_initializers.c:1174 (static)
fn void sema_update_const_initializer_with_designator_array(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	DesignatorElement* element = curr[0];
	ArrayIndex low_index = element.index;
	ArrayIndex high_index = element.kind == RANGE ? element.index_end : element.index;
	assert(element.kind == ARRAY || element.kind == RANGE);

	// Expand zero into array.
	if (const_init.kind == INIT_ZERO)
	{
		const_init.kind = INIT_ARRAY;
		const_init.init_array.elements = {};
	}

	Type* element_type = type_flatten(const_init.type.array.base);
	DesignatorElement** next_element = curr + 1;
	bool is_last_path_element = next_element == end;

	// Get all the elements in the array

	ArrayIndex insert_index = 0;

	for (ArrayIndex index = low_index; index <= high_index; index++)
	{
		ConstInitializer* inner_value = sema_update_const_initializer_at_index(const_init, element_type, index, &insert_index);

		// Update
		if (!is_last_path_element)
		{
			sema_update_const_initializer_with_designator(inner_value, next_element, end, value);
			continue;
		}
		const_init_rewrite_to_value(inner_value, value);
	}
}

// sema_initializers.c:1213 (static)
fn void sema_update_const_initializer_with_designator(ConstInitializer* const_init, DesignatorElement** curr, DesignatorElement** end, Expr* value)
{
	switch (const_init.type.type_kind)
	{
		case STRUCT:
		case BITSTRUCT:
			sema_update_const_initializer_with_designator_struct(const_init, curr, end, value);
			return;
		case UNION:
			sema_update_const_initializer_with_designator_union(const_init, curr, end, value);
			return;
		case ARRAY:
		case VECTOR:
		case SIMD_VECTOR:
			sema_update_const_initializer_with_designator_array(const_init, curr, end, value);
			return;
		default:
			unreachable();
	}
}

// sema_initializers.c:1237 (static)
fn Type* sema_expr_analyse_designator(SemaContext* context, Type* current, Expr* expr, ArrayIndex* max_index, Decl** member_ptr, bool* no_match_ref)
{
	assert(expr.expr_kind == DESIGNATOR);
	DesignatorElement*[] path = expr.designator_expr.path;

	// Walk down into this path
	bool did_report_error = false;
	*member_ptr = null;
	for (int i = 0; i < path.len; i++)
	{
		Decl* member_found;
		Type* new_current = sema_find_type_of_element(context, current, &path, &i, &did_report_error, i == 0 ? max_index : null, &member_found);
		expr.designator_expr.path = path;
		if (!new_current)
		{
			if (did_report_error) return null;
			if (no_match_ref)
			{
				*no_match_ref = true;
				return null;
			}
			@sema_error_at(context, expr.loc, "This is not a valid member of '%s'.", type_to_error_string(current));
			return null;
		}
		current = new_current;
		*member_ptr = member_found;
	}
	return current;
}

// sema_initializers.c:1262 (static)
fn Type* sema_resolve_vector_element_for_name(SemaContext* context, FlatType* type, DesignatorElement* element, bool* did_report_error)
{
	Expr* field = element.field_expr;
	if (field.expr_kind != UNRESOLVED_IDENTIFIER) return null;
	String kw = field.unresolved_ident_expr.ident;
	int len = (int)kw.len;
	if (!sema_kw_is_swizzle(kw, len)) return null;
	bool is_overlapping = false;
	int index;
	if (!sema_check_swizzle_string(context, field, kw, len, (int)type.array.len, &is_overlapping, &index))
	{
		*did_report_error = true;
		return null;
	}
	ArrayIndex first = swizzle_index(kw[0]);
	ArrayIndex last = swizzle_index(kw[len - 1]);

	if (is_overlapping || (first + len != last + 1))
	{
		*did_report_error = true;
		@sema_error_at(context, field.loc, "Designated initializers using swizzling must be a contiguous range, like '.xyz = 123'.");
		return null;
	}
	assert(last < type.array.len);
	element.index = first;
	if (len == 1)
	{
		element.kind = ARRAY;
	}
	else
	{
		element.kind = RANGE;
		element.index_end = last;
	}
	return type.array.base;
}

// sema_initializers.c:1299 (static)
fn bool sema_initializer_list_is_empty(Expr* value)
{
	return expr_is_const_initializer(value) && value.const_expr.initializer.kind == INIT_ZERO;
}

// sema_initializers.c:1304 (static)
fn Type* sema_find_type_of_element(SemaContext* context, Type* type, DesignatorElement*[]* elements_ref, int* curr_index, bool* did_report_error, ArrayIndex* max_index, Decl** member_ptr)
{
	Type* type_flattened = type_flatten(type);
	DesignatorElement* element = (*elements_ref)[*curr_index];
	if (element.kind == ARRAY || element.kind == RANGE)
	{
		*member_ptr = null;
		ByteSize len;
		Type* base;
		switch (type_flattened.type_kind)
		{
			case INFERRED_ARRAY:
			case INFERRED_VECTOR:
				len = (ByteSize)max_array_index();
				base = type_flattened.array.base;
			case ARRAY:
			case VECTOR:
			case SIMD_VECTOR:
				len = (ByteSize)type_flattened.array.len;
				base = type_flattened.array.base;
			default:
				return null;
		}
		ArrayIndex index = sema_analyse_designator_index(context, element.index_expr);
		if (index < 0)
		{
			*did_report_error = true;
			return null;
		}
		if (index >= (ArrayIndex)len)
		{
			@sema_error_at(context, element.index_expr.loc, "The index may must be less than the array length (which was %d).", (ulong)len);
			*did_report_error = true;
			return null;
		}

		element.index = index;
		if (max_index && *max_index < index) *max_index = index;
		if (element.kind == RANGE)
		{
			ArrayIndex end_index = sema_analyse_designator_index(context, element.index_end_expr);
			if (end_index < 0)
			{
				*did_report_error = true;
				return null;
			}
			if (index > end_index)
			{
				@sema_error_at(context, element.index_end_expr.loc, "End index must be greater than start index.");
				*did_report_error = true;
				return null;
			}
			if (end_index >= (ArrayIndex)len)
			{
				*did_report_error = true;
				@sema_error_at(context, element.index_end_expr.loc, "The index must be less than the array length (which was %d).", (ulong)len);
				return null;
			}
			element.index_end = end_index;
			if (max_index && *max_index < end_index) *max_index = end_index;
		}
		return base;
	}
	assert(element.kind == FIELD);
	switch (type_flattened.type_kind)
	{
		case UNION:
		case STRUCT:
		case BITSTRUCT:
			break;
		case SIMD_VECTOR:
		case VECTOR:
			*member_ptr = null;
			return sema_resolve_vector_element_for_name(context, type_flattened, element, did_report_error);
		default:
			return null;
	}
	Decl* member = sema_resolve_element_for_name(context,
	                                             type_flattened.decl.strukt.members,
	                                             elements_ref,
	                                             curr_index, type_flattened.decl.is_substruct);
	*member_ptr = member;
	if (!member) return null;
	return member.type;
}

// sema_initializers.c:1392 (static)
fn ArrayIndex sema_analyse_designator_index(SemaContext* context, Expr* index)
{
	if (!sema_analyse_expr_rvalue(context, index))
	{
		return -1;
	}

	// Unless we already have type_usz, cast to type_sz;
	if (!cast_to_index_len(context, index, false))
	{
		return -1;
	}
	if (index.expr_kind != CONST)
	{
		@sema_error_at(context, index.loc, "The index must be a constant value.");
		return -1;
	}
	if (!sema_check_array_index(context, index, false)) return -1;

	long index_val = int_to_i64(index.const_expr.ixx);
	if (index_val < 0)
	{
		@sema_error_at(context, index.loc, "Negative index values is not allowed.");
		return -1;
	}
	return (ArrayIndex)index_val;
}

// sema_initializers.c:1420 (static)
fn Decl* sema_resolve_element_for_name(SemaContext* context, Decl*[] decls, DesignatorElement*[]* elements_ref, int* index, bool is_substruct)
{
	DesignatorElement* element = (*elements_ref)[*index];

	Expr* field = sema_expr_resolve_access_child(context, element.field_expr, null, null);
	if (!field) return poisoned_decl;

	if (field.expr_kind != UNRESOLVED_IDENTIFIER)
	{
		@sema_error_at(context, field.loc, "An identifier was expected.");
		return poisoned_decl;
	}
	String name = field.unresolved_ident_expr.ident;
	int old_index = *index;
	foreach (i, decl : decls)
	{
		// The simple case, we have a match.
		if (decl.name.ptr == name.ptr)
		{
			element.index = (ArrayIndex)i;
			return decl;
		}
		if (!decl.name.ptr)
		{
			assert(decl_has_members(decl));
			// Anonymous struct
			Decl* found = sema_resolve_element_for_name(context, decl.strukt.members, elements_ref, index, false);
			// No match, continue...
			if (!found) continue;

			// Create our anon field.
			DesignatorElement* anon_element = calloc_arena(DesignatorElement::size);
			anon_element.kind = FIELD;
			anon_element.index = (ArrayIndex)i;
			@vec_insert_at(elements_ref, (usz)old_index, anon_element);
			// Advance
			(*index)++;
			return found;
		}
	}
	if (!is_substruct) return null;
	Decl* first = decls[0];
	Type* flat = type_flatten(first.type);
	if (!type_is_union_or_strukt(flat) && flat.type_kind != BITSTRUCT) return null;
	if (first.decl_kind == VAR)
	{
		first = flat.decl;
	}

	Decl* found = sema_resolve_element_for_name(context, first.strukt.members, elements_ref, index, true);
	if (!found) return null;
	// Create our ref field.
	DesignatorElement* anon_element = calloc_arena(DesignatorElement::size);
	anon_element.kind = FIELD;
	anon_element.index = 0;
	@vec_insert_at(elements_ref, (usz)old_index, anon_element);
	// Advance
	(*index)++;
	return found;
}
