// Port of c3c src/compiler/sema_decls.c (revision 54bab366a): analysis of
// struct/union/bitstruct/enum/constset/fault/interface/typedef/alias/
// fntype/function/macro/method/variable declarations, attributes, contracts
// (doc headers, @return?), operator overloads and main wrapping. All functions
// are ported, in c3c order (`// file:line` comments point at the C source).
//
// Deviations from c3c:
// - `goto` is restructured: AGAIN/RETRY loops become `continue` (with `i--`
//   after an erase), error/exit labels become flags (`failed`,
//   `skip_to_exit`, `fail_check` + `break OUTER` in sema_analyse_var_decl_ct).
// - c3c erases from a local copy of a vector that shares the header with the
//   owning field; here erasing goes through the owning field
//   (`@vec_erase_at(&decl.strukt.members, i)`) and elements are re-read from it.
// - ByteSize locals are `long` (ByteSize is a distinct type in the port).
// - The static tables `OVERLOAD_NAME`, `OVERLOAD_MAY_BE_REVERSE` and the
//   function-static `attribute_domain` (`ATTRIBUTE_DOMAIN`) are module consts.
// - `expr_const_bytes_str` reads `const_expr.bytes` as a String (c3c uses the
//   NUL-terminated `bytes.ptr`).
// - SEMA_ERROR calls with a `cond ? "fmt1" : "fmt2"` format are split into two
//   calls (formats are compile-time checked). check_valid_symbol_match drops a
//   stray `decl->name` argument that no format specifier consumes.
// - sema_compare_method_with_interface reads the signatures by pointer
//   instead of copying them.
// - sema_check_body_const keeps c3c's recursion on the same node for
//   CT_COMPOUND_STMT.
// - DEBUG_LOG / REMINDER are dropped.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

enum MainSubType : char
{
	NORMAL,
	WINMAIN,
	WMAIN,
}

<* The String of a constant string/bytes expression (c3c reads `const_expr.bytes.ptr` as a C string). *>
fn String expr_const_bytes_str(Expr* expr) @inline => (String)expr.const_expr.bytes.ptr[:expr.const_expr.bytes.len];

// sema_decls.c:56 (static)
fn bool sema_resolve_align_expr(SemaContext* context, Expr* expr, AlignSize* result)
{
	if (!sema_analyse_expr_rvalue(context, expr)) return false;

	// Must be constant int
	if (!expr_is_const_int(expr)) return @sema_error_at(context, expr.loc, "Expected a constant integer value as argument.");

	// Must be <= MAX_ALIGNMENT
	if (int_ucomp(expr.const_expr.ixx, MAX_ALIGNMENT, GT))
	{
		return @sema_error_at(context, expr.loc, "Alignment must be less or equal to %d.", (long)MAX_ALIGNMENT);
	}

	// Must be > 0
	if (int_ucomp(expr.const_expr.ixx, 0, LE))
	{
		return @sema_error_at(context, expr.loc, "Alignment must be greater than zero.");
	}

	// Must be power of two
	ulong align = int_to_u64(expr.const_expr.ixx);
	if (!is_power_of_two(align))
	{
		return @sema_error_at(context, expr.loc, "Alignment must be a power of two.");
	}

	// Done
	*result = (AlignSize)align;
	return true;
}

// sema_decls.c:90 (static)
fn bool sema_check_section(SemaContext* context, Attr* attr)
{
	Expr* expr = attr.exprs[0];
	String section_string = (String)expr.const_expr.bytes.ptr[:expr.const_expr.bytes.len];
	// No restrictions except for MACH-O
	if (compiler.platform.object_format != MACHO)
	{
		return true;
	}
	scratch_buffer_clear();
	StringSlice slice = slice_from_string(section_string);
	StringSlice segment = slice_next_token(&slice, ',');
	StringSlice section = slice_next_token(&slice, ',');
	StringSlice attrs = slice_next_token(&slice, ',');
	StringSlice stub_size_str = slice_next_token(&slice, ',');
	(void)attrs;
	(void)stub_size_str;

	if (slice.len) return @sema_error_at(context, expr.loc, "Too many parts to the Mach-o section description.");

	slice_trim(&segment);
	if (!segment.len) return @sema_error_at(context, expr.loc, "The segment is missing, did you type it correctly?");

	slice_trim(&section);
	if (!section.len) return @sema_error_at(context, expr.loc, "Mach-o requires 'segment,section' as the format, did you type it correctly?");

	if (section.len > 16) return @sema_error_at(context, expr.loc, "Mach-o requires the section to be at the most 16 characters, can you shorten it?");

	return true;
}

// sema_decls.c:125 (static)
fn bool sema_check_param_uniqueness_and_type(SemaContext* context, Decl*[] decls, Decl* current, int current_index)
{
	String name = current.name;

	// There is no need to do a check if it is anonymous.
	if (name.ptr == null) return true;

	// Check for a duplicate name, this algorithm is O(n^2),
	// but is fine as parameters are typically few, and doing something like
	// a hash map would be more expensive to set up.
	for (int i = 0; i < current_index; i++)
	{
		// Does the name match?
		if (decls[i] && name.ptr == decls[i].name.ptr)
		{
			@sema_error_at(context, current.loc, "Duplicate parameter name '%s'.", name);
			@sema_note_prev_at(decls[i].loc, "Previous use of the name was here.");
			decl_poison(current);
			return false;
		}
	}

	// All ok
	return true;
}

// sema_decls.c:158 (static)
fn bool sema_resolve_implemented_interfaces(SemaContext* context, Decl* decl, bool resolve_interfaces)
{
	TypeInfo*[] interfaces = decl.interfaces;
	int count = (int)interfaces.len;

	// Let's max out the number of interfaces. Not strictly needed.
	if (count > MAX_INTERFACES) return @sema_error_at(context, interfaces[0].loc, "The maximum number of interfaces (%d) is exeeded.", MAX_INTERFACES);

	// No interfaces? Then we're done. This is the most common case.
	if (!count) return true;

	for (int i = 0; i < count; i++)
	{
		TypeInfo* inf_info = interfaces[i];

		// Resolve the name of the interface
		if (!sema_resolve_type_info(context, inf_info, RESOLVE_TYPE_DEFAULT)) return false;

		CanonicalType* inf_type = inf_info.type.canonical;

		// Check that it's a proper interface
		if (inf_type.type_kind != INTERFACE)
		{
			return @sema_error_at(context, inf_info.loc, "Expected an interface name, but %s is not an interface.",
							  type_quoted_error_string(inf_type));
		}

		// We don't permit duplicates as this would affect the implementation ordering.
		// O(n^2) more than 1-2 interfaces is EXTREMELY unlikely, and we cap at 127.
		for (int j = 0; j < i; j++)
		{
			if (interfaces[j].type.canonical == inf_type)
			{
				return @sema_error_at(context, inf_info.loc, "The interface '%s' was included more than once, "
											"this is not allowed, so please remove the duplicates.",
								  inf_type.name);
			}
		}
		// If this is a resolve_interfaces check, then we also resolve the interface itself (this would mean resolving function types)
		if (resolve_interfaces && !sema_analyse_decl(context, inf_type.decl)) return false;
	}
	return true;
}

// sema_decls.c:207 (static)
fn bool sema_analyse_struct_member(SemaContext* context, Decl* parent, Decl* decl, bool* erase_decl)
{
	// Resolution might already have been completed in some cases due to $checks
	if (decl.resolve_status == DONE)
	{
		// Broken? Exit
		if (!decl_ok(decl)) return false;

		// If it has a name, push it on the stack
		if (decl.name.ptr) sema_decl_stack_push(decl);
		return true;
	}

	// Detect circular dependency.
	if (decl.resolve_status == RUNNING) return @sema_error_at(context, decl.loc, "Circular dependency resolving member.");

	// Mark the unit, it should not have been assigned at this point.
	assert(!decl.unit || decl.is_templated || decl.unit == parent.unit);
	decl.unit = parent.unit;

	// Pick the domain for attribute analysis.
	AttributeDomain domain = ATTR_MEMBER;
	switch (decl.decl_kind)
	{
		case BITSTRUCT:
			domain = ATTR_BITSTRUCT;
		case UNION:
			domain = ATTR_UNION;
		case STRUCT:
			domain = ATTR_STRUCT;
		case VAR:
			break;
		default:
			unreachable();
	}

	// Check attributes.
	if (!sema_analyse_attributes(context, decl, decl.attributes, domain, erase_decl)) return decl_poison(decl);

	// If we should erase this declaration due to an @if, exit here.
	if (*erase_decl) return true;

	// If it has a name, place it in the decl stack to ensure it is unique.
	if (decl.name.ptr)
	{
		// Look in the stack for duplicate names
		Decl* other = sema_decl_stack_resolve_symbol(decl.name);
		if (other)
		{
			@sema_error_at(context, decl.loc, "Duplicate member name '%s'.", other.name);
			@sema_note_prev_at(other.loc, "Previous declaration was here.");
			return false;
		}
		// Push the name onto the stack.
		sema_decl_stack_push(decl);
	}

	bool is_export = parent.is_export;

	// Analysis depends on the underlying type.
	switch (decl.decl_kind)
	{
		// A regular member
		case VAR:
		{
			assert(decl.var_decl.kind == MEMBER);

			// Set it to running to detect circular dependencies
			decl.resolve_status = RUNNING;

			// Resolve the type
			// Inferred types are not strictly allowed, but we use the int[*] for the flexible array member.
			assert(decl.var_decl.type_info);
			TypeInfo* type_info = type_infoptr(decl.var_decl.type_info);
			if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_ALLOW_FLEXIBLE)) return false;

			// Check the resulting storage type:
			Type* type = type_info.type;
			switch (sema_resolve_storage_type(context, type))
			{
				case STORAGE_ERROR:
					return false;
				case STORAGE_NORMAL:
					break;
				case STORAGE_VOID:
					return @sema_error_at(context, type_info.loc, "Members cannot be %s.", type_quoted_error_string(type));
				case STORAGE_COMPILE_TIME:
					return @sema_error_at(context, type_info.loc, "Members cannot be %s.", type_invalid_storage_type_name(type));
				case STORAGE_WILDCARD:
				case STORAGE_UNKNOWN:
					return @sema_error_at(context, type_info.loc, "%s has unknown size and cannot be used as a member.", type_quoted_error_string(type));
			}
			decl.type = type;
			decl.resolve_status = DONE;
			return true;
		}
		// It might be a struct of union
		case STRUCT:
		case UNION:
			// Extend the nopadding attributes to nested structs.
			if (parent.attr_nopadding) decl.attr_nopadding = true;
			if (parent.strukt.is_compact) decl.strukt.is_compact = true;
			nextcase BITSTRUCT;
			// The common case for all inline types:
		case BITSTRUCT:
			// Set the nested type as export if this one is exported.
			decl.is_export = is_export;
			// Perform the analysis
			if (!sema_analyse_decl(context, decl)) return false;
			return true;
		default:
			unreachable();
	}
}

// sema_decls.c:328 (static)
fn bool sema_check_struct_holes(SemaContext* context, Decl* parent, Decl* member)
{
	// Get the underlying type, skipping things like typedef, constset
	Type* member_type = type_flatten(member.type);

	// If it's not a union or struct, then we're done
	if (!type_is_union_or_strukt(member_type)) return true;

	assert(member_type.decl.resolve_status == DONE);

	// If it doesn't have any holes then we're done.
	if (!member_type.decl.strukt.padded_decl_id) return true;

	// If the parent doesn't already have info about padding (i.e. it already signaled for this)
	// Then set it here.
	if (!parent.strukt.padded_decl_id) parent.strukt.padded_decl_id = member_type.decl.strukt.padded_decl_id;

	// If it's compact then it's an error.
	if (parent.strukt.is_compact)
	{
		@sema_error_at(context, member.loc, "%s has padding and can't be used as the type of '%s', because members of a `@compact` type must all have zero padding.", type_quoted_error_string(member_type), member.name);
		Decl* padded_decl = declptr(member_type.decl.strukt.padded_decl_id);

		if (decl_is_struct_type(padded_decl))
		{
			@sema_note_prev_at(padded_decl.loc, "The first padding in %s would be added to the end of this type.",
			          type_quoted_error_string(member_type));
		}
		else
		{
			@sema_note_prev_at(padded_decl.loc, "The first padded field in %s is here.", type_quoted_error_string(member_type));
		}
		return false;
	}

	// Otherwise just continue.
	return true;
}

// sema_decls.c:371 (static)
fn bool sema_analyse_union_members(SemaContext* context, Decl* union_decl)
{
	AlignSize max_size = 0;
	ArrayIndex max_alignment_element = 0;
	AlignSize max_alignment = 0;

	int member_count = (int)union_decl.strukt.members.len;
	assert(member_count > 0);

	// Check all members
	for (int i = 0; i < member_count; i++)
	{
		Decl* member = union_decl.strukt.members[i];

		// The member may already have been resolved if it is poisoned, then exit.
		if (!decl_ok(member)) return false;
		bool erase_decl = false;

		// Check the member
		if (!sema_analyse_struct_member(context, union_decl, member, &erase_decl)) // NOLINT
		{
			// Failed
			return decl_poison(member);
		}

		// If we need to erase it then do so.
		if (erase_decl)
		{
			@vec_erase_at(&union_decl.strukt.members, (usz)i);
			member_count--;
			// Go back and take the next one.
			i--;
			continue;
		}

		// We need to check for flexible array members, which is not supported in unions.
		if (member.type.type_kind == INFERRED_ARRAY)
		{
			decl_poison(member);
			return @sema_error_at(context, member.loc, "Flexible array members not allowed in unions.");
		}

		// Calculate alignment for the member
		AlignSize member_alignment;
		if (!sema_set_alignment(context, member.type, &member_alignment, false)) return false;

		// Detect holes
		if (!sema_check_struct_holes(context, union_decl, member)) return false;

		long member_size = type_size(member.type);
		if (member_size > (long)MAX_STRUCT_SIZE) return @sema_error_at(context, member.loc, "Union member '%s' would cause the union to become too large (exceeding %d GB).", member.name, (int)((long)MAX_STRUCT_SIZE >> 30));

		assert(member_size <= (long)MAX_TYPE_SIZE);

		// Update alignment from `@align` attribute if it exists
		if (member.alignment > member_alignment) member_alignment = member.alignment;

		// Update max alignment as needed
		if (member_alignment > max_alignment)
		{
			max_alignment = member_alignment;
			max_alignment_element = (ArrayIndex)i;
		}

		// Update max size as needed
		if (member_size > max_size)
		{
			max_size = (AlignSize)member_size;
			// If this is bigger than the previous with max
			// alignment, pick this as the maximum size field.
			// So given two elements with the same size, pick the one with the greater alignment
			if (max_alignment_element != (ArrayIndex)i && max_alignment == member_alignment)
			{
				max_alignment_element = (ArrayIndex)i;
			}
		}
		// Offset is always 0
		member.offset = 0;
	}
	// Because of `@if` we might not have any members left. That's an error.
	if (!member_count)
	{
		return @sema_error_at(context, union_decl.loc, "No union members exist after processing attributes, this is not allowed. Please make sure it has at least one member.");
	}

	assert(decl_ok(union_decl));

	// 1. If packed, then the alignment is 1, unless previously given
	if (union_decl.strukt.is_packed && !union_decl.alignment) union_decl.alignment = 1;

	// 2. otherwise pick the highest of the natural alignment and the given alignment.
	if (!union_decl.strukt.is_packed && union_decl.alignment < max_alignment) union_decl.alignment = max_alignment;

	// We're only packed if the max alignment is > 1
	union_decl.strukt.is_packed = union_decl.strukt.is_packed && max_alignment > 1;

	// "Representative" type is the one with the maximum alignment.
	assert(max_alignment_element >= 0);
	assert(max_alignment_element <= STRUCT_INDEX_MAX);
	union_decl.strukt.union_rep = (StructIndex)max_alignment_element;

	// All members share the same alignment
	foreach (member : union_decl.strukt.members)
	{
		member.alignment = union_decl.alignment;
	}

	assert(max_size);

	// The actual size might be larger than the max size due to alignment.
	AlignSize size = aligned_offset(max_size, union_decl.alignment);

	long rep_size = type_size(union_decl.strukt.members[max_alignment_element].type);

	// If the actual size is bigger than the real size, add
	// padding – typically used with LLVM lowering.
	if (size > rep_size)
	{
		long padding = size - rep_size;
		if (padding > MAX_STRUCT_PADDING) return @sema_error_at(context, union_decl.loc, "The struct padding would exceed %d.", padding);
		union_decl.strukt.padding = (ushort)padding;
	}

	union_decl.strukt.size = size;
	return true;
}

// sema_decls.c:505
fn AlignSize sema_get_max_natural_alignment(Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case OPTIONAL:
				// Use underlying type
				type = type.optional;
				continue;
			case TYPEDEF:
				// Use underlying type
				type = type.decl.distinct.type;
				continue;
			case ALIAS:
				// Use underlying type
				type = type.canonical;
				continue;
			case POISONED:
			case UNTYPEDLIST:
			case TYPEINFO:
			case MEMBER:
			case REFLECTION:
			case WILDCARD:
				unreachable();
			case VOID:
				// Set to 1 to allow void* to be handled easily.
				return 1;
			case BOOL:
			case I8..U128:
			case F16..F128:
				return type.builtin.abi_alignment;
			case ANY:
			case INTERFACE:
			case ANYFAULT:
			case TYPEID:
			case FUNC_PTR:
			case POINTER:
			case FUNC_RAW:
			case SLICE:
				return compiler.platform.align_pointer.align / 8;
			case ENUM:
			case CONSTSET:
				// Look at the container type
				type = enum_inner_type(type);
				continue;
			case STRUCT:
			case UNION:
			{
				// If packed => 1
				if (type.decl.strukt.is_packed) return 1;

				// Find the max alignment in all elements
				AlignSize max = 0;
				foreach (member : type.decl.strukt.members)
				{
					AlignSize member_max = sema_get_max_natural_alignment(member.type);
					if (member_max > max) max = member_max;
				}
				return max;
			}
			case BITSTRUCT:
				type = type.decl.strukt.container_type.type;
				continue;
			case SIMD_VECTOR:
				return type_abi_alignment(type);
			case ARRAY:
			case FLEXIBLE_ARRAY:
			case INFERRED_ARRAY:
			case VECTOR:
			case INFERRED_VECTOR:
				type = type.array.base;
				continue;
		}
	}
}

// sema_decls.c:581 (static)
fn bool sema_analyse_struct_members(SemaContext* context, Decl* decl)
{
	// Default alignment is 1 even if it is empty.
	AlignSize natural_alignment = 1;
	AlignSize actual_alignment = 1;
	bool is_unaligned = false;
	long size = 0;
	long offset = 0;
	bool is_packed = decl.strukt.is_packed;
	int member_count = (int)decl.strukt.members.len;
	assert(member_count > 0, "This analysis should only be called on member_count > 0");
	bool is_naturally_aligned = !is_packed;
	for (int i = 0; i < member_count; i++)
	{
		Decl* member = decl.strukt.members[i];
		// We might have already analysed and poisoned this decl, if so, exit.
		if (!decl_ok(member)) return decl_poison(decl);
		bool erase_decl = false;
		// Check the member
		if (!sema_analyse_struct_member(context, decl, member, &erase_decl)) // NOLINT
		{
			return decl_poison(decl);
		}
		// If we should erase it, do so.
		if (erase_decl)
		{
			@vec_erase_at(&decl.strukt.members, (usz)i);
			member_count--;
			i--;
			continue;
		}

		Type* member_type = type_flatten(member.type);
		// If this is a struct and it has a variable array ending, then it must also be the last struct.
		// So this is ok:
		// struct Foo { int x; struct { int x; int[*] y; } }
		// But not this:
		// struct Bar { struct { int x; int[*] y; } int x; }
		if (member_type.type_kind == STRUCT && member_type.decl.has_variable_array)
		{
			if (i != member_count - 1)
			{
				decl_poison(member);
				return @sema_error_at(context, member.loc, "A struct member with a flexible array must be the last element.");
			}
			// Mark it as a variable array.
			decl.has_variable_array = true;
		}
		else if (member_type.type_kind == INFERRED_ARRAY)
		{
			// Check chat it is the last element.
			if (i != member_count - 1)
			{
				decl_poison(member);
				return @sema_error_at(context, member.loc, "The flexible array member must be the last element.");
			}
			// And that it isn't the only element.
			if (i == 0)
			{
				decl_poison(member);
				return @sema_error_at(context, member.loc, "The flexible array member cannot be the only element.");
			}
			// Now replace the type, because we want a TYPE_FLEXIBLE_ARRAY rather than the assumed TYPE_INFERRED_ARRAY
			member.type = type_get_flexible_array(member.type.array.base);
			// And mark as variable array
			decl.has_variable_array = true;
		}

		assert(decl_ok(decl), "The declaration should be fine at this point.");

		// Grab the alignment of the member type
		AlignSize member_type_alignment;
		if (type_is_user_defined(member_type) && member_type.decl.resolve_status == RUNNING)
		{
			@sema_error_at(context, member_type.decl.loc, "Recursive definition of %s.", type_quoted_error_string(member_type));
			TypeInfo* type = type_infoptrzero(member.var_decl.type_info);
			if (type)
			{
				@sema_note_prev_at(type.loc, "Used as a member here.");
			}
			else
			{
				@sema_note_prev_at(member.loc, "Used as a member here.");
			}
			return decl_poison(decl);
		}
		if (!sema_set_alignment(context, member.type, &member_type_alignment, false)) return decl_poison(decl);
		// And get the natural alignment
		AlignSize member_natural_alignment = sema_get_max_natural_alignment(member.type);

		// If packed, then the alignment is 1
		AlignSize member_alignment = is_packed ? 1 : member_type_alignment;
		// If a member has an assigned alignment, then we use that one, even if it is packed.
		if (member.alignment)
		{
			member_alignment = member.alignment;
			// Update total alignment if we have a member that has bigger alignment.
			if (member_alignment > decl.alignment) decl.alignment = member_alignment;
		}

		// If the natural alignment is higher than the currently detected alignment,
		// then we update the natural alignment
		if (member_natural_alignment > natural_alignment)
		{
			natural_alignment = member_natural_alignment;
		}
		if (member_alignment > actual_alignment) actual_alignment = member_alignment;

		// In the case of a struct, we will align this to the next offset,
		// using the alignment of the member.
		AlignSize align_offset = aligned_offset((AlignSize)offset, member_alignment);

		AlignSize natural_align_offset = aligned_offset((AlignSize)offset, member_natural_alignment);

		// If the natural align is different from the aligned offset we have two cases:
		if (natural_align_offset != align_offset)
		{
			is_naturally_aligned = false;
			// If the natural alignment is greater, in this case the struct is unaligned.
			if (member_natural_alignment > member_alignment)
			{
				assert(natural_align_offset > align_offset);
				is_unaligned = true;
			}
			else
			{
				// Otherwise we have a greater offset, and in this case
				// we add padding for the difference.
				assert(natural_align_offset < align_offset);
				assert(align_offset - offset <= ALIGN_SIZE_MAX);
				member.padding = (AlignSize)(align_offset - offset);
			}
		}

		member.alignment = member_alignment;

		if (align_offset - offset != 0)
		{
			assert(decl_is_struct_type(decl));
			if (!decl.strukt.padded_decl_id) decl.strukt.padded_decl_id = declid(member);
			long padding = align_offset - offset;
			if (padding > ALIGN_SIZE_MAX) return @sema_error_at(context, member.loc, "The padding added would exceed %d.", (int)ALIGN_SIZE_MAX);
			if (decl.attr_nopadding || member.attr_nopadding)
			{
				return @sema_error_at(context, member.loc, "%d bytes of padding would be added to align this member which is not allowed with `@nopadding` and `@compact`.", (int)(padding));
			}
			member.padding = (AlignSize)(align_offset - offset);
		}

		if (!sema_check_struct_holes(context, decl, member)) return false;

		offset = align_offset;
		assert(offset <= (long)MAX_STRUCT_SIZE);
		member.offset = (TypeSize)offset;
		offset += type_size(member.type);
		if (offset > (long)MAX_STRUCT_SIZE) return @sema_error_at(context, member.loc, "Struct member '%s' would cause the struct to become too large (exceeding %d GB).", member.name, (int)((long)MAX_STRUCT_SIZE / ((long)1024 * 1024 * 1024)));
	}

	if (!member_count)
	{
		return @sema_error_at(context, decl.loc, "No members exist for this struct after processing attributes, creating an invalid empty struct. Please make sure every struct/inner struct has at least one member.");
	}

	// Set the alignment:

	// 1. If packed, use the alignment given, otherwise set to 1.
	if (decl.strukt.is_packed && !decl.alignment) decl.alignment = 1;

	// 2. otherwise pick the highest of the actual alignment and the given alignment.
	if (!decl.strukt.is_packed && decl.alignment < actual_alignment) decl.alignment = actual_alignment;

	// We must now possibly add the end padding.
	// First we calculate the actual size
	size = aligned_offset((AlignSize)offset, decl.alignment);

	// We might get a size that is greater than the natural alignment
	// in this case we need an additional padding
	AlignSize natural_size = aligned_offset((AlignSize)offset, natural_alignment);
	if (size > natural_size)
	{
		long padding = size - offset;
		if (padding > MAX_STRUCT_PADDING) return @sema_error_at(context, decl.loc, "The struct padding would exceed %d.", padding);
		decl.strukt.padding = (ushort)(size - offset);
	}

	// If the size is smaller the naturally aligned struct, then it is also unaligned
	if (size < natural_size)
	{
		is_unaligned = true;
	}
	if (is_unaligned && size > offset)
	{
		assert(!decl.strukt.padding || decl.strukt.padding == size - offset);
		long padding = size - offset;
		if (padding > MAX_STRUCT_PADDING) return @sema_error_at(context, decl.loc, "The struct padding would exceed %d.", padding);
		decl.strukt.padding = (ushort)(size - offset);
	}

	if (decl.attr_nopadding && type_is_substruct(decl.type))
	{
		Decl* first_member = decl.strukt.members[0];
		Type* type = type_flatten(first_member.type);
		if (type_is_union_or_strukt(type) && !type.decl.attr_nopadding)
		{
			return @sema_error_at(context, first_member.loc, "An inlined struct or union type also requires the `@nopadding` attribute.");
		}
	}

	if (size != offset)
	{
		assert(decl_is_struct_type(decl));
		if (!decl.strukt.padded_decl_id) decl.strukt.padded_decl_id = declid(decl);
		if (decl.attr_nopadding)
		{
			return @sema_error_at(context, decl.loc, "%d bytes of padding would be added to the end this struct which is not allowed with `@nopadding` and `@compact`.", (int)(size - offset));
		}
	}

	decl.strukt.is_packed = is_unaligned;
	// Strip padding if we are aligned.
	if (!decl.strukt.is_packed && is_naturally_aligned)
	{
		for (int i = 0; i < member_count; i++)
		{
			Decl* member = decl.strukt.members[i];
			member.padding = 0;
		}
	}
	assert(size <= (long)MAX_TYPE_SIZE);
	decl.strukt.size = (TypeSize)size;
	return true;
}

// sema_decls.c:819 (static)
fn bool sema_analyse_struct_union(SemaContext* context, Decl* decl, bool* erase_decl)
{
	// Begin by analysing attributes
	bool is_union = decl.decl_kind == UNION;
	AttributeDomain domain = is_union ? ATTR_UNION : ATTR_STRUCT;

	// Resolve attributes
	if (!sema_analyse_attributes(context, decl, decl.attributes, domain, erase_decl)) return decl_poison(decl);

	// If we already had something deprecated, don't show more deprecation
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	// If an @if attribute erases it, end here
	if (*erase_decl) return true;

	// Resolve any implemented interfaces shallowly (i.e. functions are not resolved)
	if (!sema_resolve_implemented_interfaces(context, decl, false)) return decl_poison(decl);

	Decl*[] members = decl.strukt.members;

	// We require at least one member in C3. This simplifies semantics in corner cases.
	if (!members.len)
	{
		return @sema_error_at(context, decl.loc, "Zero sized %s are not permitted.", is_union ? "unions" : "structs");
	}

	// If we have a name, we need to create a new decl stack
	Decl** state = decl.name.ptr ? sema_decl_stack_store() : null;

	// Analyse the members
	bool success = is_union
			? sema_analyse_union_members(context, decl)
			: sema_analyse_struct_members(context, decl);

	// Restore if needed.
	if (decl.name.ptr) sema_decl_stack_restore(state);

	// Failed, so exit.
	if (!success) return decl_poison(decl);

	assert(decl_ok(decl));
	return true;
}

// sema_decls.c:867 (static)
fn bool sema_analyse_bitstruct_member(SemaContext* context, Decl* parent, Decl* member, int index, bool allow_overlap, bool* erase_decl)
{
	if (member.resolve_status == DONE)
	{
		if (!decl_ok(member)) return false;
		if (member.name.ptr) sema_decl_stack_push(member);
		return true;
	}

	TypeInfo* type_info = type_infoptr(member.var_decl.type_info);
	if (member.resolve_status == RUNNING)
	{
		return @sema_error_at(context, member.loc, "Circular dependency resolving member.");
	}

	if (!sema_analyse_attributes(context, member, member.attributes, ATTR_BITSTRUCT_MEMBER, erase_decl)) return decl_poison(member);
	if (*erase_decl) return true;

	if (member.name.ptr)
	{
		Decl* other = sema_decl_stack_resolve_symbol(member.name);
		if (other)
		{
			@sema_error_at(context, member.loc, "Duplicate member name '%s'.", other.name);
			@sema_note_prev_at(other.loc, "Previous declaration was here.");
			return false;
		}
		if (member.name.ptr) sema_decl_stack_push(member);
	}

	bool is_consecutive = parent.strukt.consecutive;

	// Resolve the type.
	if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return false;
	member.type = type_info.type;

	// Flatten the distinct and enum types.
	Type* member_type = type_flatten_for_bitstruct(member.type);

	// Only accept (flattened) integer and bool types
	if (!type_is_integer(member_type) && member_type != type_bool)
	{
		@sema_error_at(context, type_info.loc, "%s is not supported in a bitstruct, only enums, integer and boolean values may be used.",
				   type_quoted_error_string(member.type));
		return false;
	}

	// Grab the underlying bit type size.
	BitSize bits = type_size(parent.strukt.container_type.type) * (BitSize)8;

	if (bits > MAX_BITSTRUCT)
	{
		@sema_error_at(context, parent.strukt.container_type.loc, "Bitstruct size may not exceed %d bits.", MAX_BITSTRUCT);
		return false;
	}
	Int max_bits = { .type = I64, .i = (uint128)bits };

	// Resolve the bit range, starting with the beginning

	int start_bit, end_bit;

	if (is_consecutive)
	{
		assert(!member.var_decl.bit_is_expr, "Should always me inferred");
		if (member_type != type_bool)
		{
			@sema_error_at(context, type_info.loc, "For bitstructs without bit ranges, the types must all be 'bool'.");
			return false;
		}
		start_bit = end_bit = member.var_decl.start_bit;
		if (start_bit >= bits)
		{
			@sema_error_at(context, member.loc, "This element would overflow the bitstruct size (%d bits).", bits);
			return false;
		}
	}
	else
	{
		if (member.var_decl.bit_is_expr)
		{
			Expr* start = member.var_decl.start;
			if (!sema_analyse_expr_rvalue(context, start)) return false;

			// Check for negative, non integer or non const values.
			if (!sema_cast_const(start) || !type_is_integer(start.type) || int_is_neg(start.const_expr.ixx))
			{
				@sema_error_at(context, start.loc, "This must be a constant non-negative integer value.");
				return false;
			}

			// Check that we didn't exceed max bits.
			if (int_comp(start.const_expr.ixx, max_bits, GE))
			{
				@sema_error_at(context, start.loc, "Expected at the most a bit index of %d\n", bits - 1);
				return false;
			}

			end_bit = start_bit = (int)start.const_expr.ixx.i;

			// Handle the end
			Expr* end = member.var_decl.end;
			if (end)
			{
				// Analyse the end
				if (!sema_analyse_expr_rvalue(context, end)) return false;
				if (!sema_cast_const(end) || !type_is_integer(end.type) || int_is_neg(end.const_expr.ixx))
				{
					@sema_error_at(context, end.loc, "This must be a constant non-negative integer value.");
					return false;
				}
				if (int_comp(end.const_expr.ixx, max_bits, GE))
				{
					@sema_error_at(context, end.loc, "Expected at the most a bit index of %d.", bits - 1);
					return false;
				}
				end_bit = (int)end.const_expr.ixx.i;
			}
			else
			{
				// No end bit, this is only ok if the type is bool, otherwise a range is needed.
				// This prevents confusion with C style bits.
				if (member_type.type_kind != BOOL)
				{
					@sema_error_at(context, member.loc, "Only booleans may use non-range indices, try using %d..%d instead.", start_bit, start_bit);
					return false;
				}
			}
			// Check that we actually have a positive range.
			if (start_bit > end_bit)
			{
				@sema_error_at(context, start.loc, "The start bit must be smaller than the end bit index.");
				return false;
			}
		}
		else
		{
			start_bit = member.var_decl.start_bit;
			end_bit = member.var_decl.end_bit;
		}

		// Check how many bits we need.
		TypeSize bitsize_type = member_type == type_bool ? 1 : type_size(member_type) * 8;

		// And how many we have.
		TypeSize bits_available = end_bit + 1 - start_bit;

		// Assigning more than needed is not allowed.
		if (bitsize_type < bits_available)
		{
			@sema_error_at(context, member.loc, "The bit width of %s (%d) is less than the assigned bits (%d), try reducing the range.",
					   type_quoted_error_string(member.type), (int)bitsize_type, (int)bits_available);
			return false;
		}

		// Store the bits.
		member.var_decl.start_bit = start_bit;
		member.var_decl.end_bit = end_bit;
		member.var_decl.bit_is_expr = false;
	}

	// AFTER_BIT_CHECK:
	// Check for overlap
	if (!allow_overlap)
	{
		Decl*[] members = parent.strukt.members;
		for (int i = 0; i < index; i++)
		{
			Decl* other_member = members[i];
			// Check for overlap.
			if ((start_bit >= other_member.var_decl.start_bit || end_bit >= other_member.var_decl.start_bit)
			    && start_bit <= other_member.var_decl.end_bit)
			{
				@sema_error_at(context, member.loc, "Overlapping members, please use '@overlap' if this is intended.");
				@sema_note_prev_at(other_member.loc, "The other member was declared here.");
				return false;
			}
		}
	}
	member.resolve_status = DONE;
	return true;
}

// sema_decls.c:1054 (static)
fn bool sema_analyse_interface(SemaContext* context, Decl* decl, bool* erase_decl)
{
	// Begin with analysing attributes.
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_INTERFACE, erase_decl)) return false;

	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	// If erased using @if, we exit.
	if (*erase_decl) return true;

	if (context.unit.mod.is_compiler_rt) return @sema_error_at(context, decl.loc, "Interfaces may not be used in compiler-rt.");

	// Resolve the inherited interfaces deeply
	if (!sema_resolve_implemented_interfaces(context, decl, true)) return false;

	// Walk through the methods.
	int count = (int)decl.interface_methods.len;

	// Note that zero functions are allowed, this is useful for creating combinations of interfaces.
	for (int i = 0; i < count; i++)
	{
		Decl*[] functions = decl.interface_methods;
		Decl* method = functions[i];
		if (method.name.ptr == kw_ptr.ptr || method.name.ptr == kw_type.ptr)
		{
			return @sema_error_at(context, method.loc, "The method name '%s' would shadow the built-in property '.%s', "
							 "please select a different name.", method.name, method.name);
		}
		// The method might have been resolved earlier, if so we either exit or go to the next.
		// This might happen for example if it was resolved using $defined
		if (method.resolve_status == DONE)
		{
			if (!decl_ok(method)) return false;
			continue;
		}
		if (method.resolve_status == RUNNING)
		{
			@sema_error_at(context, method.loc, "Recursive definition of method, this is not allowed.");
			return decl_poison(method);
		}
		method.unit = decl.unit;
		method.resolve_status = RUNNING;
		if (method.decl_kind != FUNC)
		{
			@sema_error_at(context, method.loc, "Only functions are allowed here.");
			return decl_poison(method);
		}
		if (method.func_decl.type_parent)
		{
			@sema_error_at(context, decl_find_method_target(method).loc, "Interfaces should not be declared as methods.");
			return decl_poison(method);
		}
		bool erase = false;
		Decl*[] params = method.func_decl.signature.params;
		if (params.len && params[0] && params[0].var_decl.self_addr)
		{
			@sema_error_at(context, params[0].loc, "Interface methods have an implicit self, so '&' parameters are not allowed.");
			return decl_poison(method);
		}

		// Insert the first parameter, which is the implicit `void*`
		Decl* first = decl_new_var({}, decl.loc, null, PARAM);
		first.type = type_voidptr;
		first.var_decl.kind = PARAM;
		first.unit = context.unit;
		first.resolve_status = DONE;
		first.alignment = type_alloca_alignment(type_voidptr);
		@vec_insert_first(&method.func_decl.signature.params, first);
		method.unit = context.unit;
		method.func_decl.signature.vararg_index += 1;

		// Now we analyse the function as a regular function.
		if (!sema_analyse_func(context, method, &erase))
		{
			// This is necessary in order to allow this check to run again.
			decl_poison(method);
			@vec_erase_at(&method.func_decl.signature.params, 0);
			return false;
		}

		// We might need to erase the function.
		if (erase)
		{
			@vec_erase_at(&decl.interface_methods, (usz)i);
			count--;
			if (i >= count) break;
			i--;
			continue;
		}

		String name = method.name;
		// Do a simple check to ensure the same function isn't defined twice.
		// note that this doesn't check if it's overlapping an inherited method, this is deliberate.
		for (int j = 0; j < i; j++)
		{
			if (functions[j].name.ptr == name.ptr)
			{
				@sema_error_at(context, method.loc, "Duplicate definition of method '%s'.", name);
				@sema_note_prev_at(functions[j].loc, "The previous definition was here.");
				return decl_poison(method);
			}
		}
		method.resolve_status = DONE;
	}
	return true;
}

// sema_decls.c:1161 (static)
fn bool sema_deep_resolve_function_ptr(SemaContext* context, TypeInfo* type_to_resolve)
{
	Type* type = type_to_resolve.type;
	while (true)
	{
		switch (type.type_kind) // NOLINT
		{
			case POISONED:
			case VOID:
			case BOOL:
			case I8..U128:
			case F16..F128:
			case VECTOR:
			case SIMD_VECTOR:
			case INFERRED_VECTOR:
			case ANY:
			case INTERFACE:
			case ANYFAULT:
			case TYPEID:
			case ENUM:
			case CONSTSET:
			case STRUCT:
			case UNION:
			case BITSTRUCT:
			case TYPEDEF:
			case UNTYPEDLIST:
			case TYPEINFO:
			case MEMBER:
			case REFLECTION:
			case WILDCARD:
				return true;
			case ALIAS:
				if (type.decl.resolve_status != DONE && !sema_resolve_type_decl(context, type)) return false;
				type = type.canonical;
				continue;
			case POINTER:
			case FUNC_PTR:
				type = type.pointer;
				continue;
			case FUNC_RAW:
				return sema_analyse_decl(context, type.decl);
			case OPTIONAL:
				type = type.optional;
				continue;
			case ARRAY:
			case SLICE:
			case INFERRED_ARRAY:
			case FLEXIBLE_ARRAY:
				type = type.array.base;
				continue;
		}
	}
}

// sema_decls.c:1210 (static)
fn bool sema_analyse_bitstruct(SemaContext* context, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_BITSTRUCT, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (!sema_resolve_implemented_interfaces(context, decl, false)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (*erase_decl) return true;
	if (!sema_resolve_type_info(context, decl.strukt.container_type, RESOLVE_TYPE_DEFAULT)) return false;
	Type* type = type_flatten(decl.strukt.container_type.type.canonical);
	if (!sema_resolve_type_decl(context, type)) return false;
	if (type_size(type) == 1)
	{
		decl.strukt.big_endian = false;
		decl.strukt.little_endian = false;
	}
	Type* base_type = type.type_kind == ARRAY ? type_flatten(type.array.base) : type;
	if (!type_is_integer(base_type) || (type.type_kind == ARRAY && type_size(type.array.base) > 1))
	{
		return @sema_error_at(context, decl.strukt.container_type.loc, "The type of the bitstruct cannot be %s but must be an integer or an array of chars.",
				type_quoted_error_string(decl.strukt.container_type.type));
	}
	int member_count = (int)decl.strukt.members.len;

	Decl** state = decl.name.ptr ? sema_decl_stack_store() : null;
	bool failed = false;
	for (int i = 0; i < member_count; i++)
	{
		Decl* member = decl.strukt.members[i];
		if (!decl_ok(member))
		{
			failed = true;
			break;
		}
		bool erase_decl_member = false;
		if (!sema_analyse_bitstruct_member(context, decl, member, i, decl.strukt.overlap, &erase_decl_member))
		{
			failed = true;
			break;
		}
		if (erase_decl_member)
		{
			@vec_erase_at(&decl.strukt.members, (usz)i);
			member_count--;
			i--;
			continue;
		}
	}
	if (state) sema_decl_stack_restore(state);
	if (failed) return decl_poison(decl);
	return true;
}

// sema_decls.c:1260 (static)
fn bool sema_analyse_signature(SemaContext* context, Signature* sig, TypeInfo* method_parent, Decl* decl)
{
	Variadic variadic_type = sig.variadic;
	Decl*[] params = sig.params;

	int param_count = (int)params.len;
	int vararg_index = sig.vararg_index;
	bool is_macro = sig.is_macro;
	bool is_macro_at_name = sig.is_at_macro || sig.is_safemacro;
	// Check return type
	assert(sig.rtype || sig.is_macro);
	Type* rtype = null;
	ResolveTypeKind resolve_type_kind_infer = is_macro ? RESOLVE_TYPE_ALLOW_INFER : RESOLVE_TYPE_DEFAULT;
	ResolveTypeKind resolve_type_kind = is_macro ? RESOLVE_TYPE_MACRO_METHOD : RESOLVE_TYPE_FUNC_METHOD;
	int format_index = (int)sig.attrs.format - 1;
	if (sig.rtype)
	{
		TypeInfo* rtype_info = type_infoptr(sig.rtype);
		if (!sema_resolve_type_info(context, type_infoptr(sig.rtype), resolve_type_kind_infer)) return false;
		rtype = rtype_info.type;
		switch (sema_resolve_storage_type(context, rtype))
		{
			case STORAGE_ERROR:
				return false;
			case STORAGE_VOID:
			case STORAGE_NORMAL:
				break;
			case STORAGE_UNKNOWN:
				return @sema_error_at(context, rtype_info.loc, "This type is of unknown size, and cannot be a return value. However, you can pass it by pointer.");
			case STORAGE_WILDCARD:
				return @sema_error_at(context, rtype_info.loc, "The type cannot be determined for this return value.");
			case STORAGE_COMPILE_TIME:
				if (is_macro) break;
				return @sema_error_at(context, rtype_info.loc, "A function may not return %s, only macros may do so.", type_invalid_storage_type_name(rtype));
		}
		if (sig.attrs.noreturn && !type_is_void(rtype))
		{
			return @sema_error_at(context, rtype_info.loc, "@noreturn cannot be used on %s not returning 'void'.", is_macro ? "macros" : "functions");
		}
		if (sig.attrs.nodiscard)
		{
			if (type_is_void(rtype))
			{
				return @sema_error_at(context, rtype_info.loc, "@nodiscard cannot be used on %s returning 'void'.",
								  is_macro ? "macros" : "functions");
			}
		}
		if (sig.attrs.maydiscard)
		{
			if (!type_is_optional(rtype))
			{
				return @sema_error_at(context, rtype_info.loc,
				                  "@maydiscard can only be used on %s returning optional values.",
				                  is_macro ? "macros" : "functions");
			}
		}
		if (!sema_deep_resolve_function_ptr(context, rtype_info)) return false;
	}

	// We don't support more than MAX_PARAMS number of params. This makes everything sane.
	if (param_count > MAX_PARAMS)
	{
		if (variadic_type != NONE)
		{
			return @sema_error_at(context, params[MAX_PARAMS].loc, "The number of params exceeded the max of %d.", MAX_PARAMS);
		}
		return @sema_error_at(context, params[MAX_PARAMS].loc, "The number of params exceeded the max of %d. To accept more arguments, "
											  "consider using varargs.", MAX_PARAMS);
	}

	if (method_parent)
	{
		if (!sema_resolve_type_info(context, method_parent, resolve_type_kind)) return false;
	}

	if (params.len && params[0] && params[0].var_decl.self_addr)
	{
		if (params[0].var_decl.type_info)
		{
			if (!method_parent)
			{
				TypeInfo* type_info = type_infoptr(params[0].var_decl.type_info);
				if (!sema_resolve_type_info(context, type_info, resolve_type_kind)) return false;
				return @sema_error_at(context, params[0].loc, "Self parameters `&` are only allowed on methods. Did you perhaps want '%s* %s'?", type_info.type.name, params[0].name);
			}
			return @sema_error_at(context, type_infoptr(params[0].var_decl.type_info).loc, "A self parameter should always be untyped, please remove the type here.");
		}
		if (!method_parent) return @sema_error_at(context, params[0].loc, "Self parameters are only allowed on methods.");
	}
	// Fill in the type if the first parameter is lacking a type.
	if (method_parent && params.len && params[0] && !params[0].var_decl.type_info)
	{
		Decl* param = params[0];
		if (param.var_decl.init_expr) return @sema_error_at(context, param.var_decl.init_expr.loc, "A self parameter cannot have a default value.");
		Type* inferred_type = null;
		switch (param.var_decl.kind)
		{
			case PARAM:
				if (param.var_decl.self_addr)
				{
					inferred_type = type_get_ptr(method_parent.type);
					param.var_decl.not_null = true;
					break;
				}
				nextcase PARAM_EXPR;
			case PARAM_EXPR:
			case PARAM_CT:
				inferred_type = method_parent.type;
			case PARAM_CT_TYPE:
				return @sema_error_at(context, param.loc, "Expected a parameter of type %s here.", type_quoted_error_string(method_parent.type));
			default:
				unreachable();
		}
		param.var_decl.type_info = type_info_id_new_base(inferred_type, param.loc);
		param.var_decl.is_self = true;
	}

	// Ensure it has at least one parameter if method.
	if (method_parent && !params.len)
	{
		return @sema_error_at(context, decl.loc, "A method must start with an argument of the type "
								"it is a method of, e.g. 'fn void %s.%s(%s* self)'.",
								type_to_error_string(method_parent.type), decl.name, type_to_error_string(method_parent.type));
	}

	if (format_index >= 0)
	{
		if (format_index >= param_count)
		{
			return @sema_error_at(context, decl.loc, "The format '@format()' index was out of range.");
		}
		if (sig.variadic != ANY && !is_macro)
		{
			return @sema_error_at(context, decl.loc, "'@format()' is only valid for a function or macro with 'args...' style vaargs.");
		}
		if (sig.vararg_index == format_index)
		{
			return @sema_error_at(context, decl.loc, "The format string cannot be a vaarg parameter.");
		}
	}

	// Check parameters
	for (int i = 0; i < param_count; i++)
	{
		Decl* param = params[i];
		if (!param)
		{
			assert(variadic_type == RAW);
			assert(i == vararg_index);
			continue;
		}
		if (vararg_index < i)
		{
			if (!is_macro && variadic_type == RAW)
			{
				@sema_error_at(context, param.loc, "C-style varargs cannot be followed by regular parameters.");
				return decl_poison(param);
			}

			// If we already reached a vararg (as a previous argument) and we have a
			// parameter without a name then that is an error.
			if (!param.name.ptr)
			{
				@sema_error_at(context, param.loc, "A parameter name was expected, as parameters after varargs must always be named.");
				return decl_poison(param);
			}
		}
		if (i == 0 && param.resolve_status == DONE)
		{
			assert(param.type == type_voidptr, "Expected the first parameter of an interface method.");
			continue;
		}

		assert(param.resolve_status == NOT_DONE, "The param shouldn't have been resolved yet.");
		param.resolve_status = RUNNING;
		bool erase = false;
		if (!sema_analyse_attributes(context, param, param.attributes, ATTR_PARAM, &erase))
		{
			return decl_poison(param);
		}
		assert(!erase);
		param.unit = context.unit;
		assert(param.decl_kind == VAR);
		VarDeclKind var_kind = param.var_decl.kind;
		TypeInfo* type_info = type_infoptrzero(param.var_decl.type_info);
		if (type_info)
		{
			if (!sema_resolve_type_info(context, type_info, resolve_type_kind_infer)) return decl_poison(param);
			param.type = type_info.type;
			switch (sema_resolve_storage_type(context, type_info.type))
			{
				case STORAGE_ERROR:
					return false;
				case STORAGE_VOID:
					// We may have `void` arguments. They are not allowed in C3. Theoretically they could
					// be permitted, but it would complicate semantics in general.
					if (param_count == 1 && !param.name.ptr && param.var_decl.kind == PARAM)
					{
						return @sema_error_at(context, param.loc, "C-style 'foo(void)' style argument declarations are not valid, please remove 'void'.");
					}
					return @sema_error_at(context, type_info.loc, "Parameters may not be of type 'void'.");
				case STORAGE_NORMAL:
					break;
				case STORAGE_UNKNOWN:
					return @sema_error_at(context, type_info.loc, "This type is of unknown size, and cannot be a parameter. However, you can pass it by pointer.");
				case STORAGE_WILDCARD:
					return @sema_error_at(context, type_info.loc, "The type cannot be determined for this parameter.");
				case STORAGE_COMPILE_TIME:
					return @sema_error_at(context, type_info.loc, "The type of a parameter may not %s.", type_invalid_storage_type_name(type_info.type));
			}
		}
		if (i == format_index)
		{
			if (!type_info || type_info.type.canonical != type_string)
			{
				SourceLocId loc = type_info ? type_info.loc : param.loc;
				@sema_error_at(context, loc, "The '@format()' format string must be be of type 'String'.");
				return decl_poison(param);
			}
		}
		if (type_info && param.var_decl.no_alias && !type_is_pointer(param.type) && type_flatten(param.type).type_kind != SLICE)
		{
			@sema_error_at(context, param.loc, "The parameter was set to @noalias, but it was neither a slice nor a pointer. You need to either remove '@noalias' or use pointer/slice type.");
			return decl_poison(param);
		}
		switch (var_kind)
		{
			case PARAM_EXPR:
				if (i == format_index)
				{
					@sema_error_at(context, param.loc, "'@format()' cannot be used with lazy arguments, please remove '@format' or make this a regular parameter.");
					return decl_poison(param);
				}
				if (!is_macro)
				{
					@sema_error_at(context, param.loc, "Only regular parameters are allowed for functions.");
					return decl_poison(param);
				}
				if (!is_macro_at_name)
				{
					@sema_error_at(context, param.loc, "Expression parameters are not allowed in function-like macros. Prefix the macro name with '@'.");
					return decl_poison(param);
				}
				nextcase PARAM_CT;
			case PARAM_CT:
				if (!is_macro)
				{
					@sema_error_at(context, param.loc, "Only regular parameters are allowed for functions.");
					return decl_poison(param);
				}
				nextcase PARAM;
			case PARAM:
				if (!param.type && !is_macro)
				{
					return @sema_error_at(context, param.loc, "Only typed parameters are allowed for functions.");
				}
				bool erase_decl = false;
				if (!sema_analyse_attributes_for_var(context, param, &erase_decl)) return false;
				assert(!erase_decl);
			case PARAM_CT_TYPE:
				if (type_info)
				{
					@sema_error_at(context, type_info.loc, "A compile time type parameter cannot have a type itself.");
					return decl_poison(param);
				}
				if (!is_macro)
				{
					@sema_error_at(context, param.loc, "Only regular parameters are allowed for functions.");
					return decl_poison(param);
				}
			case CONST:
			case GLOBAL:
			case LOCAL:
			case MEMBER:
			case BITMEMBER:
			case LOCAL_CT:
			case LOCAL_CT_TYPE:
			case UNWRAPPED:
			case REWRAPPED:
			case ERASE:
				unreachable();
		}
		if (param.var_decl.vararg)
		{
			if (var_kind != PARAM && var_kind != PARAM_CT)
			{
				@sema_error_at(context, param.loc, "Only regular parameters may be vararg.");
				return decl_poison(param);
			}
			if (!type_info)
			{
				@sema_error_at(context, param.loc, "Only typed parameters may be vararg.");
				return decl_poison(param);
			}
			// Update whether this was a vararg, and update "default" for the signature.
			if (param.var_decl.vararg)
			{
				if (vararg_index != i)
				{
					@sema_error_at(context, param.loc, "A %s may not have more than one vararg.", is_macro ? "macro" : "function");
					return decl_poison(param);
				}
			}
			type_info.type = type_get_slice(type_info.type);
		}

		if (type_info)
		{
			if (!sema_deep_resolve_function_ptr(context, type_info)) return false;
			param.type = type_info.type;
			if (!is_macro && !sema_set_alignment(context, param.type, &param.alignment, true)) return false;
		}

		if (param.var_decl.init_expr)
		{
			Expr* expr = param.var_decl.init_expr;
			if (expr_is_const(expr))
			{
				if (!sema_analyse_expr_rhs(context, param.type, expr, true, null, false)) return decl_poison(param);
			}
		}
		if (!sema_check_param_uniqueness_and_type(context, params, param, i)) return decl_poison(param);
		param.resolve_status = DONE;
	}
	return true;
}

// sema_decls.c:1590
fn bool sema_analyse_function_signature(SemaContext* context, Decl* func_decl, TypeInfo* parent, CallABI abi, Signature* signature)
{
	if (!sema_analyse_signature(context, signature, parent, func_decl)) return false;

	Variadic variadic_type = signature.variadic;

	// Remove the last empty value.
	if (variadic_type == RAW)
	{
		assert(signature.params.len && !signature.params[signature.vararg_index], "The last parameter must have been a raw variadic.");
		assert(signature.vararg_index == signature.params.len - 1);
		@vec_pop(&signature.params);
	}

	Decl*[] params = signature.params;
	Type*[] types = {};
	int param_count = (int)params.len;

	for (int i = 0; i < param_count; i++)
	{
		assert(params[i].resolve_status == DONE);
		assert(params[i].type.canonical);
		@vec_add(&types, params[i].type);
	}

	Type* raw_type = sema_resolve_type_get_func(signature, abi);
	assert(func_decl.type.type_kind == FUNC_RAW);
	assert(raw_type.function.prototype);
	func_decl.type.function.prototype = raw_type.function.prototype;
	return true;
}

// sema_decls.c:1624 (static)
fn bool sema_analyse_fntype(SemaContext* context, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_FNTYPE, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (*erase_decl) return true;
	Signature* sig = &decl.fntype_decl.signature;
	if (!sema_analyse_function_signature(context, decl, null, sig.abi, sig)) return decl_poison(decl);
	bool pure = false;
	if (!sema_analyse_doc_header(context, decl.docs, sig.params, {}, &pure, sig.variadic == RAW)) return decl_poison(decl);
	sig.attrs.is_pure = pure;
	return true;
}

// sema_decls.c:1638 (static)
fn bool sema_analyse_type_alias(SemaContext* context, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_ALIAS, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (*erase_decl) return true;

	bool is_export = decl.is_export;
	if (decl.type_alias_decl.is_func)
	{
		Decl* fn_decl = decl.type_alias_decl.decl;
		fn_decl.is_export = is_export;
		fn_decl.unit = decl.unit;
		fn_decl.type = type_new_func(fn_decl, &fn_decl.fntype_decl.signature);
		decl.type.canonical = type_get_func_ptr(fn_decl.type);
		return true;
	}
	Expr* info = decl.type_alias_decl.type_expr;
	if (!sema_analyse_expr(context, info)) return false;
	Type* type = null;
	if (info.expr_kind == TYPEINFO)
	{
		type = info.type_expr.type;
	}
	else
	{
		if (info.type.canonical != type_typeid) return @sema_error_at(context, decl.loc, "An upper-case alias must always alias a type.");
		if (!sema_cast_const(info) || !expr_is_const_typeid(info))
		{
			return @sema_error_at(context, info.loc, "A type alias requires a type or a constant typeid. This is a runtime value.");
		}
		type = info.const_expr.typeid_type;
	}
	if (type_is_optional(type))
	{
		return @sema_error_at(context, info.loc, "You cannot create an alias for an optional type like %s.", type_quoted_error_string(type));
	}
	switch (sema_resolve_storage_type(context, type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_NORMAL:
		case STORAGE_UNKNOWN:
		case STORAGE_VOID:
			break;
		case STORAGE_WILDCARD:
			return @sema_error_at(context, info.loc, "You cannot create an alias for the wildcard type.");
		case STORAGE_COMPILE_TIME:
			return @sema_error_at(context, info.loc, "You cannot create an alias for %s as it is a compile time type.",
							  type_invalid_storage_type_name(type));
	}
	decl.type.canonical = type.canonical;
	// Do we need anything else?
	return true;
}

// sema_decls.c:1697 (static)
fn bool sema_analyse_typedef(SemaContext* context, Decl* decl, bool* erase_decl)
{
	// Check the attributes on the distinct type.
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_TYPEDEF, erase_decl)) return false;
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	// Erase it?
	if (*erase_decl) return true;

	// Check the interfaces.
	if (!sema_resolve_implemented_interfaces(context, decl, false)) return false;

	// Infer the underlying type normally.
	TypeInfo* info = decl.distinct;
	if (!sema_resolve_type_info(context, info, RESOLVE_TYPE_DEFAULT)) return false;
	Type* inner_type = info.type;
	// Optional isn't allowed of course.
	if (type_is_optional(inner_type)) return @sema_error_at(context, decl.loc, "You cannot create a distinct type from an optional.");
	switch (sema_resolve_storage_type(context, inner_type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_NORMAL:
		case STORAGE_UNKNOWN:
		case STORAGE_VOID:
			break;
		case STORAGE_WILDCARD:
			return @sema_error_at(context, info.loc, "You cannot create a distinct type from the wildcard type.");
		case STORAGE_COMPILE_TIME:
			return @sema_error_at(context, info.loc, "You cannot create a distinct type for %s as it is a compile time type.",
							  type_invalid_storage_type_name(inner_type));
	}

	if (decl.distinct_align)
	{
		if (!sema_resolve_align_expr(context, decl.distinct_align, &decl.alignment)) return false;
		AlignSize default_size = type_abi_alignment(inner_type);
		// Remove "alignment"
		if (default_size == decl.alignment) decl.distinct_align = null;
	}
	// Distinct types drop the canonical part.
	info.type = info.type.canonical;
	return true;
}

// sema_decls.c:1742 (static)
fn bool sema_analyse_enum_param(SemaContext* context, Decl* param)
{
	assert(param.decl_kind == VAR && param.var_decl.kind == PARAM && param.var_decl.type_info);
	if (param.attributes.len)
	{
		return @sema_error_at(context, param.attributes[0].loc, "There are no valid attributes for associated values.");
	}
	param.resolved_attributes = true;
	param.attrs_resolved = null;
	TypeInfo* type_info = type_infoptr(param.var_decl.type_info);
	if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return false;
	if (sema_resolve_storage_type(context, type_info.type) != STORAGE_NORMAL)
	{
		return @sema_error_at(context, type_info.loc, "An associated value must be a runtime type, not %s.", type_invalid_storage_type_name(type_info.type));
	}
	assert(!param.var_decl.vararg);
	param.type = type_info.type;
	assert(param.name.ptr);
	if (param.name.ptr == kw_description.ptr || param.name.ptr == kw_ordinal.ptr)
	{
		return @sema_error_at(context, param.loc, "'%s' is not a valid parameter name for enums.", param.name);
	}
	Decl* other = sema_decl_stack_resolve_symbol(param.name);
	if (other)
	{
		return @sema_error_at(context, param.loc, "Duplicate parameter name '%s'.", param.name);
	}
	sema_decl_stack_push(param);
	assert(!param.var_decl.init_expr);
	return true;
}

// sema_decls.c:1774 (static)
fn void sema_print_enum_to_constset_error(SemaContext* context, Decl* decl, Expr* arg)
{
	TypeInfo* type_info = decl.enums.type_info;
	if (type_info.type == type_int)
	{
		@sema_error_at(context, arg.loc, "Assigning a value requires the declaration of associated values for the enum. Did you perhaps want C-style enums? In that case use constset, defined like 'constset %s : { ... }'", decl.name);
	}
	else
	{
		@sema_error_at(context, arg.loc, "Assigning a value requires the declaration of associated values for the enum. Did you perhaps want C-style enums? In that case use constset, defined like 'constset %s : %s { ... }'", decl.name, type_to_error_string(type_info.type));
	}
}

// sema_decls.c:1786 (static)
fn bool sema_analyse_enum(SemaContext* context, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_ENUM, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (*erase_decl) return true;
	if (!sema_resolve_implemented_interfaces(context, decl, false)) return decl_poison(decl);

	// Resolve the type of the enum.
	if (!sema_resolve_type_info(context, decl.enums.type_info, RESOLVE_TYPE_DEFAULT)) return false;

	Type* type = decl.enums.type_info.type;
	assert(!type_is_optional(type), "Already stopped when parsing.");

	Type* flat_underlying_type = type_flatten(type);
	// Require an integer type
	if (!type_is_integer(flat_underlying_type))
	{
		return @sema_error_at(context, decl.enums.type_info.loc, "The enum type must be an integer type not '%s'.", type_to_error_string(type));
	}

	Decl*[] associated_values = decl.enums.parameters;
	int associated_value_count = (int)associated_values.len;
	Decl** state = sema_decl_stack_store();
	for (int i = 0; i < associated_value_count; i++)
	{
		Decl* value = associated_values[i];
		switch (value.resolve_status)
		{
			case DONE:
				continue;
			case RUNNING:
				@sema_error_at(context, value.loc, "Recursive definition found.");
				sema_decl_stack_restore(state);
				return false;
			case NOT_DONE:
				value.resolve_status = RUNNING;
		}
		if (!sema_analyse_enum_param(context, value))
		{
			sema_decl_stack_restore(state);
			return false;
		}
	}
	sema_decl_stack_restore(state);

	bool success = true;
	int enums = (int)decl.enums.values.len;
	uint128 value = 0;

	for (int i = 0; i < enums; i++)
	{
		Decl* enum_value = decl.enums.values[i];

		bool erase_val = false;
		if (!sema_analyse_attributes(context, enum_value, enum_value.attributes, ATTR_ENUM_VALUE, &erase_val)) return decl_poison(decl);

		if (erase_val)
		{
			if (enums == 1)
			{
				return @sema_error_at(context, decl.loc, "No enum values left in enum after @if and @feat resolution, there must be at least one.");
			}
			@vec_erase_at(&decl.enums.values, (usz)i);
			enums--;
			i--;
			continue;
		}
		enum_value.type = decl.type;
		enum_value.enum_constant.inner_ordinal = i;
		assert(enum_value.resolve_status == NOT_DONE);
		assert(enum_value.decl_kind == ENUM_CONSTANT);

		// Start evaluating the constant
		enum_value.resolve_status = RUNNING;

		// Create a "fake" expression.
		// This will be evaluated later to catch the case

		Int val = { value, flat_underlying_type.type_kind };
		if (!int_fits(val, flat_underlying_type.type_kind))
		{
			return @sema_error_at(context, enum_value.loc,
			                  "The enum value would implicitly be %s which does not fit in %s.",
			                  i128_to_string(value, 10, type_is_signed(flat_underlying_type), false),
			                  type_quoted_error_string(type));
		}
		enum_value.enum_constant.inner_ordinal = (int)(ulong)value;

		// Update the value (c3c increments the low word only)
		value = (value & ~(uint128)ulong::max) | (uint128)((ulong)value + 1);

		Expr*[] args = enum_value.enum_constant.associated;
		int arg_count = (int)args.len;
		if (arg_count > associated_value_count)
		{
			if (!associated_value_count)
			{
				sema_print_enum_to_constset_error(context, decl, args[0]);
				return false;
			}
			return @sema_error_at(context, args[associated_value_count].loc, "You're adding too many values, only %d associated value%s are defined for '%s'.", associated_value_count, associated_value_count != 1 ? "s" : "", decl.name);
		}
		if (arg_count < associated_value_count)
		{
			return @sema_error_at(context, enum_value.loc, "Expected %d associated value%s for this enum value.", associated_value_count, associated_value_count != 1 ? "s" : "");
		}
	}
	decl.resolve_status = DONE;
	for (int i = 0; i < associated_value_count; i++)
	{
		Decl* param = associated_values[i];
		if (!sema_set_alignment(context, param.type, &param.alignment, true)) return false;
		param.resolve_status = DONE;
	}
	int taddr_start = (int)context.compilation_unit.generated_globals.len;
	Decl*[] enum_values = decl.enums.values;
	for (int i = 0; i < enums; i++)
	{
		Decl* enum_value = enum_values[i];
		Expr*[] args = enum_value.enum_constant.associated;
		int arg_count = (int)args.len;
		if (arg_count > associated_value_count)
		{
			if (!associated_value_count)
			{
				sema_print_enum_to_constset_error(context, decl, args[0]);
				return false;
			}
			return @sema_error_at(context, args[associated_value_count].loc, "You're adding too many values, only %d associated value%s are defined for '%s'.", associated_value_count, associated_value_count != 1 ? "s" : "", decl.name);
		}
		if (arg_count < associated_value_count)
		{
			return @sema_error_at(context, enum_value.loc, "Expected %d associated value%s for this enum value.", associated_value_count, associated_value_count != 1 ? "s" : "");
		}
		for (int j = 0; j < arg_count; j++)
		{
			Expr* arg = args[j];

			if (!sema_analyse_expr_rhs(context, associated_values[j].type, arg, false, null, false)) return false;
			if (!expr_is_runtime_const(arg))
			{
				return @sema_error_at(context, arg.loc, "Associated values must be constant expressions.");
			}
			sema_fold_global_init(arg);
		}
		enum_value.resolve_status = DONE;
	}
	sema_fixup_global_temps_after_generation(context.compilation_unit, taddr_start, decl, false);
	return success;
}

// sema_decls.c:1943 (static)
fn void sema_fixup_global_temps_after_generation(CompilationUnit* unit, int start, Decl* owner, bool writable)
{
	for (int i = start; i < unit.generated_globals.len; i++)
	{
		Decl* var_ = unit.generated_globals[i];
		if (var_.name.ptr) continue;
		scratch_buffer_set_extern_decl_name(owner, true);
		@scratch_buffer_printf(".$taddr%d", i - start);
		var_.name = var_.extname = scratch_buffer_copy();
		var_.is_templated = owner.is_templated;
		var_.instance_id = owner.instance_id;
		if (writable) var_.var_decl.kind = GLOBAL;
	}
}

// sema_decls.c:1958 (static)
fn bool sema_analyse_const_enum_constant_val(SemaContext* context, Decl* decl)
{
	Expr* value = decl.enum_constant.value;
	if (!sema_analyse_expr_rhs(context, decl.type, value, false, null, true)) return decl_poison(decl);
	if (!expr_is_runtime_const(value))
	{
		@sema_error_at(context, value.loc, "Expected an constant enum value.");
		return decl_poison(decl);
	}
	if (value.type != decl.type)
	{
		@sema_error_at(context, value.loc, "Expected an constant enum value of type %s, was %s", type_quoted_error_string(decl.type), type_quoted_error_string(value.type));
		return decl_poison(decl);
	}
	return true;
}

// sema_decls.c:1974 (static)
fn bool sema_analyse_constset(SemaContext* context, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_ENUM, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (*erase_decl) return true;
	if (!sema_resolve_implemented_interfaces(context, decl, false)) return decl_poison(decl);

	// Resolve the type of the enum.
	if (!sema_resolve_type_info(context, decl.enums.type_info, RESOLVE_TYPE_DEFAULT)) return false;

	Type* type = decl.enums.type_info.type;
	if (!sema_resolve_type_decl(context, type)) return false;
	Type* flat = type_flatten(type);
	assert(!type_is_optional(type), "Already stopped when parsing.");

	switch (sema_resolve_storage_type(context, type))
	{
		case STORAGE_ERROR:
			return decl_poison(decl);
		case STORAGE_NORMAL:
			break;
		case STORAGE_WILDCARD:
			@sema_error_at(context, decl.enums.type_info.loc, "No type can be inferred from the optional result.");
			return decl_poison(decl);
		case STORAGE_VOID:
			@sema_error_at(context, decl.enums.type_info.loc, "A constset may not have a void type.");
			return decl_poison(decl);
		case STORAGE_COMPILE_TIME:
			@sema_error_at(context, decl.enums.type_info.loc, "A constset may not be %s.", type_invalid_storage_type_name(type));
			return decl_poison(decl);
		case STORAGE_UNKNOWN:
			@sema_error_at(context, decl.enums.type_info.loc, "A constset may not be %s, as it has an unknown size.",
				type_quoted_error_string(type));
			return decl_poison(decl);
	}

	assert(!decl.enums.parameters.len);

	bool success = true;
	int enums = (int)decl.enums.values.len;

	for (int i = 0; i < enums; i++)
	{
		Decl* enum_value = decl.enums.values[i];

		bool erase_val = false;
		if (!sema_analyse_attributes(context, enum_value, enum_value.attributes, ATTR_ENUM_VALUE, &erase_val)) return decl_poison(decl);
		if (erase_val)
		{
			if (enums == 1)
			{
				return @sema_error_at(context, decl.loc, "No constset values left in constset after @if and @feat resolution, there must be at least one.");
			}
			@vec_erase_at(&decl.enums.values, (usz)i);
			enums--;
			i--;
			continue;
		}
		enum_value.type = decl.type;
		if (!enum_value.enum_constant.value)
		{
			if (!type_is_integer(flat))
			{
				return @sema_error_at(context, enum_value.loc, "Constsets with missing values must be of integer type.");
			}
			if (i == 0)
			{
				enum_value.enum_constant.value = expr_new_const_int(enum_value.loc, type, 0);
			}
			else
			{
				Expr* expr = expr_new(IOTA_DECL, enum_value.loc);
				expr.decl_expr = decl.enums.values[i - 1];
				enum_value.enum_constant.value = expr;
			}
		}
		assert(enum_value.resolve_status == NOT_DONE);
		assert(enum_value.decl_kind == ENUM_CONSTANT);
	}
	decl.resolve_status = DONE;
	int taddr_start = (int)context.compilation_unit.generated_globals.len;
	Decl*[] enum_values = decl.enums.values;
	for (int i = 0; i < enums; i++)
	{
		Decl* enum_value = enum_values[i];
		enum_value.resolve_status = RUNNING;
		if (!sema_analyse_const_enum_constant_val(context, enum_value)) return decl_poison(decl);
		enum_value.resolve_status = DONE;
	}
	sema_fixup_global_temps_after_generation(context.compilation_unit, taddr_start, decl, false);
	return success;
}

// sema_decls.c:2071 (static)
fn bool sema_analyse_fault(SemaContext* context, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_FAULT, erase_decl)) return decl_poison(decl);
	if (*erase_decl) return true;
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	decl.type = type_fault;
	decl.alignment = type_abi_alignment(type_string);
	return true;
}

// sema_decls.c:2082 (static)
fn String method_name_by_decl(Decl* method_like)
{
	switch (method_like.decl_kind)
	{
		case MACRO:
			return "macro method";
		case FUNC:
			return "method";
		default:
			unreachable();
	}
}

// sema_decls.c:2096 (static)
fn bool sema_analyse_operator_common(SemaContext* context, Decl* method, TypeInfo** rtype_ptr, Decl*[]* params_ptr, int parameters)
{
	Signature* signature = &method.func_decl.signature;
	Decl*[] params = *params_ptr = signature.params;
	int param_count = (int)params.len;
	if (param_count > parameters)
	{
		return @sema_error_at(context, params[parameters].loc, "Too many parameters, '%s' expects only %d.", method.name, parameters);
	}
	if (param_count < parameters)
	{
		return @sema_error_at(context, method.loc, "Not enough parameters, '%s' requires %d.", method.name, parameters);
	}

	if (!signature.rtype) return @sema_error_at(context, method.loc, "The return value must be explicitly typed for '%s'.", method.name);

	foreach (param : params)
	{
		if (!param.var_decl.type_info)
		{
			return @sema_error_at(context, param.loc, "All parameters must be explicitly typed for '%s'.", method.name);
		}
	}
	*rtype_ptr = type_infoptr(signature.rtype);
	return true;
}

// sema_decls.c:2124
fn bool sema_type_has_subscript_overloads(Type* type)
{
	type = type_no_optional(type).canonical;
	if (!type_may_have_sub_elements(type)) return false;
	Decl* def = type.decl;
	if (!def.method_table) return false;
	return def.method_table.has_subscript_overloads;
}

// sema_decls.c:2133
fn Decl* sema_find_untyped_operator(Type* type, OperatorOverload operator_overload, Decl* skipped)
{
	type = type_no_optional(type).canonical;
	// c3c: assert(operator_overload < OVERLOAD_TYPED_START); -- C assert, compiled out in c3c release builds
	if (!type_may_have_sub_elements(type)) return null;
	Decl* def = type.decl;
	if (!def.method_table) return null;
	Decl* decl = declptrzero(def.method_table.overloads[operator_overload]);
	if (!decl) return null;
	if (decl.decl_kind != DECLARRAY)
	{
		return decl == skipped ? null : decl;
	}
	foreach (candidate : decl.decls)
	{
		return candidate == skipped ? null : candidate;
	}
	return null;
}

// sema_decls.c:2155
fn OverloadMatch sema_find_typed_operator_type(SemaContext* context, OperatorOverload operator_overload, OverloadType overload_type, Type* lhs_type, Type* rhs_type, Expr* rhs, Decl** candidate_ref, OverloadMatch last_match, Decl** ambiguous_ref)
{
	Methods* methods = lhs_type.decl.method_table;
	if (!methods || last_match == OVERLOAD_MATCH_AMBIGUOUS_EXACT || last_match == OVERLOAD_MATCH_ERROR) return last_match;
	Decl* decl = declptrzero(methods.overloads[operator_overload]);
	if (!decl) return last_match;
	Decl*[] decls;
	Decl* candidate = *candidate_ref;
	if (decl.decl_kind == DECLARRAY)
	{
		decls = decl.decls;
	}
	else
	{
		decls = (&decl)[:1];
	}
	foreach (func : decls)
	{
		if (!sema_analyse_decl(context, func)) return OVERLOAD_MATCH_ERROR;
		assert(func.resolve_status == DONE);
		if (candidate == func) continue;
		if ((overload_type & func.func_decl.overload_type) == 0) continue;
		OverloadMatch match = OVERLOAD_MATCH_WILDCARD;
		if (!func.func_decl.is_wildcard_overload)
		{
			Type* first_arg = func.func_decl.signature.params[1].type.canonical;
			match = OVERLOAD_MATCH_EXACT;
			if (first_arg != rhs_type)
			{
				if (!rhs) continue;
				if (!may_cast(context, rhs, first_arg, false, true)) continue;
				match = OVERLOAD_MATCH_CONVERSION;
			}
		}
		bool is_match = false;
		if (last_match >= OVERLOAD_MATCH_AMBIGUOUS_START)
		{
			// c3c: assert(last_match != OVERLOAD_MATCH_AMBIGUOUS_EXACT); -- C assert, compiled out in c3c release builds
			if (match == OVERLOAD_MATCH_EXACT)
			{
				*ambiguous_ref = candidate;
				is_match = true;
			}
			else if (match == OVERLOAD_MATCH_CONVERSION && last_match == OVERLOAD_MATCH_AMBIGUOUS_WILDCARD)
			{
				*ambiguous_ref = candidate;
				is_match = true;
			}
			if (!is_match) continue;
		}
		if (!is_match && candidate)
		{
			if (last_match < match) continue;
			if (last_match == match)
			{
				*ambiguous_ref = func;
				*candidate_ref = candidate;
				switch (match)
				{
					case OVERLOAD_MATCH_EXACT:
						return OVERLOAD_MATCH_AMBIGUOUS_EXACT;
					case OVERLOAD_MATCH_CONVERSION:
						last_match = OVERLOAD_MATCH_AMBIGUOUS_CONVERSION;
						continue;
					case OVERLOAD_MATCH_WILDCARD:
						last_match = OVERLOAD_MATCH_AMBIGUOUS_WILDCARD;
						continue;
					default:
						unreachable();
				}
			}
			// last_match > match: goto MATCH
		}
		// MATCH:
		candidate = func;
		last_match = match;
	}
	*candidate_ref = candidate;
	return last_match;
}

// sema_decls.c:2237
fn String operator_overload_to_string(OperatorOverload operator_overload)
{
	switch (operator_overload)
	{
		case OVERLOAD_NONE:
		case OVERLOAD_ELEMENT_AT:
		case OVERLOAD_ELEMENT_REF:
		case OVERLOAD_ELEMENT_SET:
		case OVERLOAD_LEN:				unreachable();
		case OVERLOAD_NEGATE:			return "~";
		case OVERLOAD_UNARY_MINUS:		return "-";
		case OVERLOAD_PLUS:				return "+";
		case OVERLOAD_MINUS:			return "-";
		case OVERLOAD_MULTIPLY:			return "*";
		case OVERLOAD_DIVIDE:			return "/";
		case OVERLOAD_REMINDER:			return "%";
		case OVERLOAD_AND:				return "&";
		case OVERLOAD_OR:				return "|";
		case OVERLOAD_XOR:				return "^";
		case OVERLOAD_LESS_THAN:		return "<";
		case OVERLOAD_SHL:				return "<<";
		case OVERLOAD_SHR:				return ">>";
		case OVERLOAD_EQUAL:			return "==";
		case OVERLOAD_PLUS_ASSIGN:		return "+=";
		case OVERLOAD_MINUS_ASSIGN:		return "-=";
		case OVERLOAD_MULTIPLY_ASSIGN:	return "*=";
		case OVERLOAD_DIVIDE_ASSIGN:	return "/=";
		case OVERLOAD_REMINDER_ASSIGN:	return "%=";
		case OVERLOAD_AND_ASSIGN:		return "&=";
		case OVERLOAD_OR_ASSIGN:		return "|=";
		case OVERLOAD_XOR_ASSIGN:		return "^=";
		case OVERLOAD_SHL_ASSIGN:		return "<<=";
		case OVERLOAD_SHR_ASSIGN:		return ">>=";
	}
	unreachable();
}

// sema_decls.c:2274
fn Decl* sema_find_typed_operator(SemaContext* context, OperatorOverload operator_overload, SourceLocId loc, Expr* lhs, Expr* rhs, bool* reverse)
{
	// c3c: assert(operator_overload >= OVERLOAD_TYPED_START); -- C assert, compiled out in c3c release builds
	// c3c: assert(lhs && rhs); -- C assert, compiled out in c3c release builds
	Type* left_type = type_no_optional(lhs.type).canonical;
	Type* right_type = type_no_optional(rhs.type).canonical;
	Decl* candidate = null;
	Decl* ambiguous = null;
	OverloadMatch current_match = OVERLOAD_MATCH_NONE;
	*reverse = false;
	Decl* first = null;
	if (type_is_user_defined(left_type))
	{
		current_match = sema_find_typed_operator_type(context, operator_overload, OVERLOAD_TYPE_LEFT, left_type, right_type, rhs, &candidate, current_match, &ambiguous);
		first = candidate;
	}
	if (type_is_user_defined(right_type))
	{
		current_match = sema_find_typed_operator_type(context, operator_overload, OVERLOAD_TYPE_RIGHT, right_type, left_type, lhs, &candidate, current_match, &ambiguous);
	}

	if (current_match >= OVERLOAD_MATCH_AMBIGUOUS_START)
	{
		@sema_error_at(context, loc, "%s %s %s has more than one candidate method, and is ambiguous. One solution is to call the desired method directly, instead of using operators, to select the right one.",
		              type_quoted_error_string(lhs.type),
		              operator_overload_to_string(operator_overload),
		              type_quoted_error_string(rhs.type));
		@sema_note_prev_at(candidate.loc, "One candidate was here.");
		@sema_note_prev_at(ambiguous.loc, "Another candidate was found here.");
		return poisoned_decl;
	}

	if (current_match == OVERLOAD_MATCH_ERROR) return poisoned_decl;
	if (candidate != first) *reverse = true;

	return candidate;
}

// sema_decls.c:2312 (static)
fn bool sema_analyse_operator_unary(SemaContext* context, Decl* method, OperatorOverload operator_overload)
{
	// c3c: assert(operator_overload == OVERLOAD_NEGATE || operator_overload == OVERLOAD_UNARY_MINUS); -- C assert, compiled out in c3c release builds
	TypeInfo* rtype;
	Decl*[] params;
	if (!sema_analyse_operator_common(context, method, &rtype, &params, 1)) return false;
	if (!rtype) return @sema_error_at(context, method.loc, "The return value must be explicitly typed for '%s'.", method.name);
	if (rtype.type.canonical != decl_find_method_target(method).type.canonical)
	{
		return @sema_error_at(context, rtype.loc, "The return value must be %s but was %s.", type_quoted_error_string(decl_find_method_target(method).type),
			type_quoted_error_string(rtype.type));
	}
	return true;
}

// sema_decls.c:2327 (static)
fn bool sema_analyse_operator_arithmetics(SemaContext* context, Decl* method, OperatorOverload operator_overload)
{
	Signature* signature = &method.func_decl.signature;
	Decl*[] params = signature.params;
	uint param_count = (uint)params.len;
	if (param_count > 2)
	{
		return @sema_error_at(context, params[2].loc, "Too many parameters, '%s' expects only 2 parameters.", method.name);
	}
	if (param_count < 2)
	{
		return @sema_error_at(context, method.loc, "Not enough parameters, '%s' requires 2 parameters.", method.name);
	}
	if (!signature.rtype) return @sema_error_at(context, method.loc, "The return value must be explicitly typed for '%s'.", method.name);
	TypeInfo* rtype = type_infoptr(signature.rtype);
	if (@is_optional(rtype))
	{
		return @sema_error_at(context, rtype.loc, "The return type may not be an optional.");
	}
	if (operator_overload == OVERLOAD_EQUAL || operator_overload == OVERLOAD_LESS_THAN)
	{
		if (rtype.type.canonical != type_bool)
		{
			return @sema_error_at(context, rtype.loc, "The return type was %s, but it must be bool for comparisons.", type_quoted_error_string(rtype.type));
		}
	}
	if (operator_overload < OVERLOAD_PLUS_ASSIGN && type_is_void(rtype.type))
	{
		return @sema_error_at(context, rtype.loc, "The return type may not be %s.", type_quoted_error_string(rtype.type));
	}
	// Set it as pure
	method.func_decl.signature.attrs.is_pure = true;
	return true;
}

// sema_decls.c:2362 (static)
fn bool sema_analyse_operator_element_at(SemaContext* context, Decl* method)
{
	TypeInfo* rtype;
	Decl*[] params;
	if (!sema_analyse_operator_common(context, method, &rtype, &params, 2)) return false;
	switch (sema_resolve_storage_type(context, rtype.type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_NORMAL:
			break;
		case STORAGE_VOID:
		case STORAGE_WILDCARD:
			return @sema_error_at(context, rtype.loc, "The return type cannot be 'void'.");
		case STORAGE_COMPILE_TIME:
			return @sema_error_at(context, rtype.loc, "The return type is %s which is a compile time type, which isn't allowed.",
			                  type_invalid_storage_type_name(rtype.type));
		case STORAGE_UNKNOWN:
			return @sema_error_at(context, rtype.loc, "%s has unknown size and cannot be used as a return type.",
			                  type_quoted_error_string(rtype.type));
	}
	if (method.func_decl.operator == OVERLOAD_ELEMENT_REF && !type_is_pointer(type_no_optional(rtype.type)))
	{
		return @sema_error_at(context, rtype.loc, "The return type must be a pointer, but it is returning %s, did you mean to overload [] instead?",
		                  type_quoted_error_string(rtype.type));
	}
	return true;
}

// sema_decls.c:2391 (static)
fn bool sema_analyse_operator_element_set(SemaContext* context, Decl* method)
{
	TypeInfo* rtype;
	Decl*[] params;
	return sema_analyse_operator_common(context, method, &rtype, &params, 3);
}

// sema_decls.c:2398 (static)
fn bool sema_analyse_operator_len(SemaContext* context, Decl* method)
{
	TypeInfo* rtype;
	Decl*[] params;
	if (!sema_analyse_operator_common(context, method, &rtype, &params, 1)) return false;
	if (!type_is_integer(rtype.type))
	{
		return @sema_error_at(context, rtype.loc, "The return type must be an integer type.");
	}
	return true;
}

// sema_decls.c:2410 (static)
fn bool sema_check_operator_method_validity(SemaContext* context, Decl* method)
{
	OperatorOverload operator = method.func_decl.operator;
	switch (operator)
	{
		case OVERLOAD_ELEMENT_SET:
			return sema_analyse_operator_element_set(context, method);
		case OVERLOAD_ELEMENT_AT:
		case OVERLOAD_ELEMENT_REF:
			return sema_analyse_operator_element_at(context, method);
		case OVERLOAD_LEN:
			return sema_analyse_operator_len(context, method);
		case OVERLOAD_PLUS:
		case OVERLOAD_MULTIPLY:
		case OVERLOAD_MINUS:
		case OVERLOAD_DIVIDE:
		case OVERLOAD_REMINDER:
		case OVERLOAD_EQUAL:
		case OVERLOAD_LESS_THAN:
		case OVERLOAD_AND:
		case OVERLOAD_OR:
		case OVERLOAD_XOR:
		case OVERLOAD_SHL:
		case OVERLOAD_SHR:
		case OVERLOAD_PLUS_ASSIGN:
		case OVERLOAD_MINUS_ASSIGN:
		case OVERLOAD_MULTIPLY_ASSIGN:
		case OVERLOAD_DIVIDE_ASSIGN:
		case OVERLOAD_REMINDER_ASSIGN:
		case OVERLOAD_AND_ASSIGN:
		case OVERLOAD_OR_ASSIGN:
		case OVERLOAD_XOR_ASSIGN:
		case OVERLOAD_SHR_ASSIGN:
		case OVERLOAD_SHL_ASSIGN:
			return sema_analyse_operator_arithmetics(context, method, operator);
		case OVERLOAD_NEGATE:
		case OVERLOAD_UNARY_MINUS:
			return sema_analyse_operator_unary(context, method, operator);
		case OVERLOAD_NONE:
			unreachable();
	}
	unreachable("Method had unexpected operator %d", operator);
}

// sema_decls.c:2455
fn bool sema_decl_if_cond(SemaContext* context, Decl* decl)
{
	Attr* attr = attr_find_kind(decl.attributes, IF);
	decl.is_if = true;
	assert(attr);
	if (attr.exprs.len != 1)
	{
		return @sema_error_at(context, attr.loc, "Expected an argument to '@if'.");
	}
	if (!decl.is_templated)
	{
		if (compiler.build.warnings.deprecation == ERROR) return @sema_error_at(context, attr.loc, "Top declaration '@if' is deprecated except for generic declarations, please use '@feat' instead.");
		@sema_deprecated(attr.loc, "Top declaration '@if' is deprecated except for generic declarations, please use '@feat' instead.");
	}
	Expr* expr = attr.exprs[0];
	context.call_env.in_if_resolution = attr.loc;
	bool success = sema_analyse_ct_expr(context, expr);
	context.call_env.in_if_resolution = 0;
	if (!success) return false;
	if (expr.type.canonical != type_bool)
	{
		return @sema_error_at(context, expr.loc, "Expected a boolean value not %s.", type_quoted_error_string(expr.type));
	}
	if (expr.const_expr.b) return true;
	decl.decl_kind = ERASED;
	context.call_env.in_if_resolution = 0;
	return false;
}

// sema_decls.c:2484 (static)
fn SourceLocId method_find_overload_span(Decl* method)
{
	assert(method.resolved_attributes && method.attrs_resolved);
	return method.attrs_resolved.overload;
}

// sema_decls.c:2490 (static)
fn bool unit_add_base_extension_method(SemaContext* context, Type* type, Decl* method)
{
	Decl* other = declptrzero(methodtable_set(&compiler.context.method_extensions, method));
	if (other)
	{
		@sema_error_at(context, method.loc, "This %s is already defined.", method_name_by_decl(method));
		@sema_note_prev_at(other.loc, "The previous definition was here.");
		return false;
	}
	foreach (t : compiler.context.types_with_failed_methods)
	{
		if (t == type)
		{
			return @sema_error_at(context, method.loc, "A method was added to %s which already was checked for method availability, declarations must be reordered.", type_quoted_error_string(type));
		}
	}
	@vec_add(&compiler.context.method_extension_list, method);
	return true;
}

// sema_decls.c:2511 (static)
fn void sema_get_overload_arguments(Decl* method, Type** value_ref, Type** index_ref)
{
	switch (method.func_decl.operator)
	{
		case OVERLOAD_LEN:
			unreachable();
		case OVERLOAD_ELEMENT_AT:
			*value_ref = type_no_optional(typeget(method.func_decl.signature.rtype).canonical);
			*index_ref = method.func_decl.signature.params[1].type.canonical;
			return;
		case OVERLOAD_ELEMENT_REF:
			*value_ref = type_no_optional(typeget(method.func_decl.signature.rtype)).canonical.pointer;
			*index_ref = method.func_decl.signature.params[1].type.canonical;
			return;
		case OVERLOAD_ELEMENT_SET:
			*value_ref = method.func_decl.signature.params[2].type.canonical;
			*index_ref = method.func_decl.signature.params[1].type.canonical;
			return;
		default:
			unreachable();
	}
}

const String[OVERLOADS_COUNT + 1] OVERLOAD_NAME =
{
	[OVERLOAD_ELEMENT_AT] = "[]",
	[OVERLOAD_ELEMENT_REF] = "&[]",
	[OVERLOAD_ELEMENT_SET] = "[]=",
	[OVERLOAD_LEN] = ".len",
	[OVERLOAD_NEGATE] = "~",
	[OVERLOAD_UNARY_MINUS] = "-",
	[OVERLOAD_PLUS] = "+",
	[OVERLOAD_MINUS] = "-",
	[OVERLOAD_MULTIPLY] = "*",
	[OVERLOAD_DIVIDE] = "/",
	[OVERLOAD_REMINDER] = "%",
	[OVERLOAD_AND] = "&",
	[OVERLOAD_OR] = "|",
	[OVERLOAD_XOR] = "^",
	[OVERLOAD_LESS_THAN] = "<",
	[OVERLOAD_SHL] = "<<",
	[OVERLOAD_SHR] = ">>",
	[OVERLOAD_EQUAL] = "==",
	[OVERLOAD_PLUS_ASSIGN] = "+=",
	[OVERLOAD_MINUS_ASSIGN] = "-=",
	[OVERLOAD_MULTIPLY_ASSIGN] = "*=",
	[OVERLOAD_DIVIDE_ASSIGN] = "/=",
	[OVERLOAD_REMINDER_ASSIGN] = "%=",
	[OVERLOAD_AND_ASSIGN] = "&=",
	[OVERLOAD_OR_ASSIGN] = "|=",
	[OVERLOAD_XOR_ASSIGN] = "^=",
	[OVERLOAD_SHL_ASSIGN] = "<<=",
	[OVERLOAD_SHR_ASSIGN] = ">>=",
};

const bool[OVERLOADS_COUNT + 1] OVERLOAD_MAY_BE_REVERSE =
{
	[OVERLOAD_PLUS] = true,
	[OVERLOAD_MINUS] = true,
	[OVERLOAD_MULTIPLY] = true,
	[OVERLOAD_DIVIDE] = true,
	[OVERLOAD_REMINDER] = true,
	[OVERLOAD_AND] = true,
	[OVERLOAD_OR] = true,
	[OVERLOAD_XOR] = true,
	[OVERLOAD_SHL] = true,
	[OVERLOAD_SHR] = true,
	[OVERLOAD_EQUAL] = true,
	[OVERLOAD_LESS_THAN] = true,
};

// sema_decls.c:2582 (static)
fn bool sema_is_valid_operator_for_type(SemaContext* context, Type* type, OperatorOverload operator, Decl* method)
{
	switch (type.canonical.type_kind)
	{
		case BITSTRUCT:
			switch (operator)
			{
				case OVERLOAD_XOR:
				case OVERLOAD_AND:
				case OVERLOAD_OR:
				case OVERLOAD_XOR_ASSIGN:
				case OVERLOAD_AND_ASSIGN:
				case OVERLOAD_OR_ASSIGN:
				case OVERLOAD_NEGATE:
					return @sema_error_at(context, method_find_overload_span(method), "Bitstructs do not support overloading the '%s' operator.",
						operator_overload_to_string(operator));
				default:
					return true;
			}
		case ENUM:
			if (operator == OVERLOAD_LEN)
			{
				return @sema_error_at(context, method_find_overload_span(method), "Enums already have a .len property, you can't use '@operator(len)' on them.");
			}
			if (operator == OVERLOAD_EQUAL || operator == OVERLOAD_LESS_THAN)
			{
				return @sema_error_at(context, method_find_overload_span(method), "Enums do not support overloading the '%s' operator.", operator_overload_to_string(operator));
			}
			return true;
		default:
			return true;
	}
}

// sema_decls.c:2622 (static)
fn bool sema_analyse_operator_method(SemaContext* context, Type* parent_type, Decl* method)
{
	// Check it's valid for the operator type.
	if (!sema_check_operator_method_validity(context, method)) return false;

	// See if the operator has already been defined.
	OperatorOverload operator = method.func_decl.operator;

	Type* second_param = null;
	bool is_wildcard = false;
	if (method.func_decl.signature.params.len > 1)
	{
		second_param = method.func_decl.signature.params[1].type;
		if (!second_param)
		{
			if (method.func_decl.overload_type & OVERLOAD_TYPE_RIGHT)
			{
				return @sema_error_at(context, method.loc, "Only regular overloads can have untyped right hand parameters");
			}
			is_wildcard = (method.func_decl.is_wildcard_overload = true);
			second_param = type_void;
		}
		second_param = second_param.canonical;
	}

	if (!type_is_user_defined(parent_type))
	{
		return @sema_error_at(context, method.loc, "Only user-defined types may have overloads.");
	}

	Decl* other = null;
	if (operator >= OVERLOAD_TYPED_START)
	{
		Methods* methods = parent_type.decl.method_table;
		Decl* decl = methods ? declptrzero(methods.overloads[operator]) : null;
		if (decl)
		{
			Decl*[] decls;
			if (decl.decl_kind == DECLARRAY)
			{
				decls = decl.decls;
			}
			else
			{
				decls = (&decl)[:1];
			}
			OverloadType type = method.func_decl.overload_type;
			// c3c: assert(type); -- C assert, compiled out in c3c release builds
			foreach (func : decls)
			{
				if (func == method) continue;
				// c3c: assert(func.func_decl.operator); -- C assert, compiled out in c3c release builds
				if ((func.func_decl.overload_type & type) == 0) continue;
				if (!sema_analyse_decl(context, func)) return false;
				assert(func.decl_kind == FUNC || func.decl_kind == MACRO);
				if (is_wildcard && func.func_decl.is_wildcard_overload)
				{
					other = func;
					break;
				}
				if (is_wildcard || func.func_decl.is_wildcard_overload) continue;
				if (func.func_decl.signature.params[1].type.canonical != second_param) continue;
				other = func;
				break;
			}
		}
	}
	else
	{
		other = sema_find_untyped_operator(parent_type, operator, method);
	}
	if (other)
	{
		@sema_error_at(context, method_find_overload_span(method), "This operator is already defined for '%s'.", parent_type.name);
		@sema_note_prev_at(other.loc, "The previous definition was here.");
		return false;
	}
	// NONE:
	if (!sema_is_valid_operator_for_type(context, parent_type, operator, method)) return false;

	// Check that actual types match up
	Type* value;
	Type* index_type;
	switch (operator)
	{
		case OVERLOAD_LEN:
			// No dependency
			return true;
		case OVERLOAD_ELEMENT_AT:
			// [] compares &[]
			other = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_REF, method);
			if (other)
			{
				if (!sema_analyse_decl(context, other)) return false;
				sema_get_overload_arguments(other, &value, &index_type);
				break;
			}
			// And []=
			other = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_SET, method);
			if (other)
			{
				if (!sema_analyse_decl(context, other)) return false;
				sema_get_overload_arguments(other, &value, &index_type);
				break;
			}
			return true;
		case OVERLOAD_ELEMENT_REF:
			// &[] compares []
			other = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_AT, method);
			if (other)
			{
				if (!sema_analyse_decl(context, other)) return false;
				sema_get_overload_arguments(other, &value, &index_type);
				break;
			}
			// And []=
			other = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_SET, method);
			if (other)
			{
				if (!sema_analyse_decl(context, other)) return false;
				sema_get_overload_arguments(other, &value, &index_type);
				break;
			}
			return true;
		case OVERLOAD_ELEMENT_SET:
			// []= compares &[]
			other = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_REF, method);
			if (other)
			{
				if (!sema_analyse_decl(context, other)) return false;
				sema_get_overload_arguments(other, &value, &index_type);
				break;
			}
			// And []
			other = sema_find_untyped_operator(parent_type, OVERLOAD_ELEMENT_AT, method);
			if (other)
			{
				if (!sema_analyse_decl(context, other)) return false;
				sema_get_overload_arguments(other, &value, &index_type);
				break;
			}
			return true;
		case OVERLOAD_SHL:
		case OVERLOAD_SHR:
		case OVERLOAD_PLUS:
		case OVERLOAD_DIVIDE:
		case OVERLOAD_REMINDER:
		case OVERLOAD_UNARY_MINUS:
		case OVERLOAD_AND:
		case OVERLOAD_OR:
		case OVERLOAD_XOR:
		case OVERLOAD_NEGATE:
		case OVERLOAD_MULTIPLY:
		case OVERLOAD_MINUS:
		case OVERLOAD_EQUAL:
		case OVERLOAD_LESS_THAN:
		case OVERLOAD_PLUS_ASSIGN:
		case OVERLOAD_MINUS_ASSIGN:
		case OVERLOAD_MULTIPLY_ASSIGN:
		case OVERLOAD_DIVIDE_ASSIGN:
		case OVERLOAD_REMINDER_ASSIGN:
		case OVERLOAD_AND_ASSIGN:
		case OVERLOAD_OR_ASSIGN:
		case OVERLOAD_XOR_ASSIGN:
		case OVERLOAD_SHL_ASSIGN:
		case OVERLOAD_SHR_ASSIGN:
			return true;
		default:
			unreachable();
	}

	// We have an operator to compare with.
	Type* this_value;
	Type* this_index_type;
	sema_get_overload_arguments(method, &this_value, &this_index_type);

	// So compare the value
	if (this_value != value)
	{
		if (operator == OVERLOAD_ELEMENT_REF)
		{
			value = type_get_ptr(value);
			this_value = type_get_ptr(this_value);
		}
		@sema_error_at(context, method.loc, "There is a mismatch of the 'value' type compared to that of another operator: expected %s but got %s.",
		           type_quoted_error_string(value), type_quoted_error_string(this_value));
		@sema_note_prev_at(other.loc, "The other definition is here.");
		return false;
	}

	// And the index.
	if (this_index_type != index_type)
	{
		@sema_error_at(context, method.loc, "There is a mismatch of the 'index' type compared to that of another operator: expected %s but got %s.",
		           type_quoted_error_string(index_type), type_quoted_error_string(this_index_type));
		@sema_note_prev_at(other.loc, "The other definition is here.");
		return false;
	}

	// Everything worked! Done.
	return true;
}

// sema_decls.c:2838 (static)
fn bool type_add_method(SemaContext* context, Type* parent_type, Decl* method)
{
	assert(parent_type.canonical == parent_type);
	String name = method.name;

	// Attributes needs to be resolved early
	bool erase_decl = false;
	if (!sema_analyse_attributes(context, method, method.attributes, method.decl_kind == MACRO ? ATTR_MACRO : ATTR_FUNC, &erase_decl)) return decl_poison(method);
	if (erase_decl)
	{
		method.decl_kind = ERASED;
		return true;
	}
	if (method.func_decl.operator && method.func_decl.signature.variadic != NONE)
	{
		return @sema_error_at(context, method.loc, "Methods with '@operator' may not be variadic.");
	}

	// Is it a base extension?
	if (!type_is_user_defined(parent_type)) return unit_add_base_extension_method(context, parent_type, method);

	// Resolve it as a user-defined type extension.
	Decl* parent = parent_type.decl;

	// If we found it, issue an error.
	Decl* other = sema_resolve_method(parent, name);
	if (!decl_ok(other)) return false;
	if (other)
	{
		// We might sometimes end up adding the same method twice.
		if (other == method) return false;
		@sema_error_at(context, method.loc, "This %s is already defined for '%s'.",
		           method_name_by_decl(method), parent_type.name);
		@sema_note_prev_at(other.loc, "The previous definition was here.");
		return decl_poison(method);
	}
	if (parent.is_method_checked)
	{
		return @sema_error_at(context, method.loc, "A method was added to %s which already was checked for method availability, declarations must be reordered.", type_quoted_error_string(parent_type));
	}

	Methods* table = parent.method_table;
	if (!table)
	{
		table = parent.method_table = calloc_arena(Methods::size);
		decltable_init(&table.method_table, 64);
	}
	methods_add(table, method);
	return true;
}

// sema_decls.c:2894 (static)
fn Decl* sema_interface_method_by_name(SemaContext* context, Decl* interface_, String name)
{
	if (!sema_analyse_decl(context, interface_)) return poisoned_decl;
	foreach (method : interface_.interface_methods)
	{
		if (method.name.ptr == name.ptr) return method;
	}
	foreach (parent_type : interface_.interfaces)
	{
		if (!sema_resolve_type_info(context, parent_type, RESOLVE_TYPE_DEFAULT)) return poisoned_decl;
		// Deviation: c3c reads `parent_type->type->decl`, which for an interface
		// named through an alias is the alias decl (its interface_methods/interfaces
		// overlay unrelated union bytes, zero in C). Use the canonical interface.
		Decl* res = sema_interface_method_by_name(context, parent_type.type.canonical.decl, name);
		if (res) return res;
	}
	return null;
}

// sema_decls.c:2922 (static)
fn Decl* sema_find_interface_for_method(SemaContext* context, CanonicalType* parent_type, Decl* method)
{
	// Can the parent even implement a interface?
	switch (parent_type.type_kind)
	{
		case STRUCT:
		case UNION:
		case TYPEDEF:
		case ENUM:
			break;
		case ALIAS:
			unreachable();
		default:
			return null;
	}
	String name = method.name;
	Decl* first_match = null;
	Decl* first_interface = null;

	// Walk through all implemented interfaces.
	foreach (proto : parent_type.decl.interfaces)
	{
		if (!sema_resolve_type_info(context, proto, RESOLVE_TYPE_DEFAULT)) return poisoned_decl;
		// Deviation: canonical decl, see sema_interface_method_by_name.
		Decl* interface_ = proto.type.canonical.decl;
		Decl* match = sema_interface_method_by_name(context, interface_, name);
		if (!decl_ok(match)) return poisoned_decl;
		if (!match) continue;
		assert(interface_.resolve_status == DONE);

		// Is there a already a match?
		if (first_match)
		{
			if (first_match.type.function.prototype.raw_type == match.type.function.prototype.raw_type) continue;
			@sema_error_at(context, method.loc,
			           "Both '%s' and '%s' interfaces have a method matching '%s' but their signatures are different, "
			           "which prevents it from being implemented.",
			           first_interface.name, interface_.name, name);
			return poisoned_decl;
		}

		// Update the match.
		first_match = match;
		first_interface = interface_;
	}

	// No match => return NULL.
	if (!first_match) return null;

	// Analyse the interface.
	if (!sema_analyse_decl(context, first_interface)) return poisoned_decl;

	// Return the match.
	return first_match;
}

// sema_decls.c:2987 (static)
fn bool sema_compare_method_with_interface(SemaContext* context, Decl* decl, Decl* implemented_method)
{
	Signature* interface_sig = &implemented_method.func_decl.signature;
	Signature* this_sig = &decl.func_decl.signature;
	Type* any_rtype = typeget(interface_sig.rtype);
	Type* this_rtype = typeget(this_sig.rtype);

	// Do the return types match?
	if (any_rtype.canonical != this_rtype.canonical)
	{
		@sema_error_at(context, type_infoptr(this_sig.rtype).loc, "The prototype method has a return type %s, but this function returns %s, they need to match.",
		           type_quoted_error_string(any_rtype), type_quoted_error_string(this_rtype));
		@sema_note_prev_at(type_infoptr(interface_sig.rtype).loc, "The interface definition is here.");
		return false;
	}

	Decl*[] any_params = interface_sig.params;
	Decl*[] this_params = this_sig.params;
	int any_param_count = (int)any_params.len;
	int this_param_count = (int)this_params.len;

	// Do the param counts match?
	if (any_param_count != this_param_count)
	{
		if (any_param_count > this_param_count)
		{
			@sema_error_at(context, decl.loc, "This function is missing parameters, %d parameters were expected.", any_param_count);
			@sema_note_prev_at(any_params[this_param_count].loc, "Compare with the interface definition.");
			return false;
		}
		@sema_error_at(context, this_params[any_param_count].loc, "This function has too many parameters (%d).", this_param_count);
		@sema_note_prev_at(decl.loc, "Compare with the interface, which has only %d parameter%s.",
		          any_param_count, any_param_count == 1 ? "" : "s");
		return false;
	}

	// Check each param.
	foreach (i, param : this_params)
	{
		if (i == 0) continue;
		if (param.type.canonical != any_params[i].type.canonical)
		{
			@sema_error_at(context, vartype(param).loc,
			           "The prototype argument has type %s, but in this function it has type %s. Please make them match.",
			           type_quoted_error_string(any_params[i].type), type_quoted_error_string(param.type));
			@sema_note_prev_at(vartype(any_params[i]).loc, "The interface definition is here.");
			return false;
		}
	}
	return true;
}

// sema_decls.c:3051 (static)
fn bool sema_analyse_method(SemaContext* context, Decl* decl)
{
	assert(decl.decl_kind == FUNC);

	// Check for @init, @finalizer, @test and @benchmark
	if (decl.func_decl.attr_init | decl.func_decl.attr_finalizer)
	{
		@sema_error_at(context, decl.loc, "Methods may not have '@init' or '@finalizer' attributes.");
		return decl_poison(decl);
	}
	if (decl.func_decl.attr_test || decl.func_decl.attr_benchmark)
	{
		@sema_error_at(context, decl.loc, "Methods may not be annotated %s.", decl.func_decl.attr_test ? "@test" : "@benchmark");
		return decl_poison(decl);
	}

	// Resolve the parent type.
	TypeInfo* parent_type = decl_find_method_target(decl);

	assert(parent_type.resolve_status == DONE);
	Type* par_type = parent_type.type.canonical;

	// Resolve declaration of parent as needed.
	if (!sema_resolve_type_decl(context, par_type)) return false;
	String kw = decl.name;
	String errname = {};
	switch (par_type.canonical.type_kind)
	{
		case ENUM:
			if (kw.ptr == kw_ordinal.ptr || kw.ptr == kw_description.ptr)
			{
				errname = "an enum";
				break;
			}
			nextcase STRUCT;
		case STRUCT:
		case UNION:
		case BITSTRUCT:
		{
			Decl* d = sema_decl_stack_find_decl_member(context, par_type.canonical.decl, kw, FIELDS_ONLY);
			if (!decl_ok(d)) return false;
			if (d) return @sema_error_at(context, decl.loc, "%s already has a field with the same name.", type_quoted_error_string(par_type));
		}
		case ANYFAULT:
			if (kw.ptr == kw_type.ptr || kw.ptr == kw_description.ptr)
			{
				errname = "'fault'";
			}
		case ANY:
		case INTERFACE:
			if (kw.ptr == kw_ptr.ptr || kw.ptr == kw_type.ptr)
			{
				errname = "an interface or 'any'";
			}
		case SLICE:
			if (kw.ptr == kw_ptr.ptr || kw.ptr == kw_len.ptr)
			{
				errname = "a slice";
			}
		case VECTOR:
		case SIMD_VECTOR:
		case INFERRED_VECTOR:
			if (sema_kw_is_swizzle(decl.name, (int)decl.name.len))
			{
				return @sema_error_at(context, decl.loc, "\"%s\" is not a valid method name for a vector, since it matches a swizzle combination.", kw);
			}
			nextcase ARRAY;
		case ARRAY:
		case INFERRED_ARRAY:
		case FLEXIBLE_ARRAY:
			if (kw.ptr == kw_len.ptr)
			{
				errname = "a vector or array";
			}
		case POISONED:
		case VOID:
		case F16..F128:
		case I8..U128:
		case BOOL:
		case FUNC_PTR:
		case POINTER:
		case FUNC_RAW:
		case TYPEDEF:
		case CONSTSET:
			break;
		case TYPEID:
			if (type_property_by_name(kw) != PROPERTY_NONE)
			{
				return @sema_error_at(context, decl.loc, "\"%s\" is not a valid method name for a typeid as this is the name of a type property.", decl.name);
			}
		case ALIAS:
		case OPTIONAL:
		case UNTYPEDLIST:
		case TYPEINFO:
		case MEMBER:
		case REFLECTION:
		case WILDCARD:
			unreachable();
	}
	if (errname.ptr)
	{
		// NOT_VALID_NAME:
		return @sema_error_at(context, decl.loc, "\"%s\" is not a valid method name for %s, as this would shadow the built-in property '.%s'.", kw, errname, kw);
	}
	Decl*[] params = decl.func_decl.signature.params;
	bool is_dynamic = decl.func_decl.attr_dynamic;

	// Ensure that the first parameter is valid.
	// c3c reads the popped raw-vararg NULL slot past the end of the vector here.
	Decl* first_param = params.len ? params[0] : null;
	if (!first_param)
	{
		assert(decl.func_decl.signature.vararg_index == 0);
		return @sema_error_at(context, decl.loc, "The first parameter of a method must always be a regular argument, it cannot be a vaarg.");
	}
	if (!sema_is_valid_method_param(context, params[0], par_type, is_dynamic)) return false;

	// Make dynamic checks.
	if (is_dynamic)
	{
		if (par_type.type_kind == INTERFACE)
		{
			return @sema_error_at(context, decl.loc, "Interfaces may not implement '@dynamic' methods, only regular methods.");
		}
		if (par_type == type_any)
		{
			return @sema_error_at(context, decl.loc, "'any' may not implement '@dynamic' methods, only regular methods.");
		}
		// Retrieve the implemented method.
		Decl* implemented_method = sema_find_interface_for_method(context, par_type, decl);
		if (!decl_ok(implemented_method)) return false;

		// If it's implementing a method, check it.
		if (implemented_method)
		{
			assert(implemented_method.resolve_status == DONE);
			if (!sema_compare_method_with_interface(context, decl, implemented_method)) return false;
			decl.func_decl.interface_method = declid(implemented_method);
		}
		else
		{
			decl.func_decl.interface_method = 0;
		}
	}
	// Is it an operator?
	if (decl.func_decl.operator)
	{
		// We must resolve it here to avoid recursion.
		decl.resolve_status = DONE;
		if (!sema_analyse_operator_method(context, par_type, decl)) return false;
	}

	return true;
}

// sema_decls.c:3208 (static)
fn String attribute_domain_to_string(AttributeDomain domain)
{
	switch (domain)
	{
		case ATTR_NONE:             unreachable();
		case ATTR_MACRO:            return "macro";
		case ATTR_LOCAL:            return "local variable";
		case ATTR_LOCAL_STATIC:     return "local static variable";
		case ATTR_BITSTRUCT:        return "bitstruct";
		case ATTR_INTERFACE:        return "interface";
		case ATTR_MEMBER:           return "member";
		case ATTR_BITSTRUCT_MEMBER: return "bitstruct member";
		case ATTR_FUNC:             return "function";
		case ATTR_PARAM:            return "parameter";
		case ATTR_ENUM_VALUE:       return "enum or constset value";
		case ATTR_GLOBAL:           return "global variable";
		case ATTR_ENUM:             return "enum";
		case ATTR_STRUCT:           return "struct";
		case ATTR_UNION:            return "union";
		case ATTR_CONST:            return "constant";
		case ATTR_FAULT:            return "excuse";
		case ATTR_ALIAS:            return "alias";
		case ATTR_CALL:             return "call";
		case ATTR_TYPEDEF:          return "typedef";
		case ATTR_INTERFACE_METHOD: return "interface method";
		case ATTR_FNTYPE:           return "function type";
	}
	unreachable();
}

// sema_decls.c:3243 (static)
fn bool update_abi(Decl* decl, CallABI abi)
{
	// If it is a function type, update the ABI on the type
	if (decl.decl_kind == FNTYPE)
	{
		decl.fntype_decl.signature.abi = abi;
		return true;
	}
	// Otherwise update it on the function
	decl.func_decl.signature.abi = abi;
	return true;
}

// sema_decls.c:3266 (static)
fn bool update_call_abi_from_string(SemaContext* context, Decl* decl, Expr* expr)
{
	String str = expr_const_bytes_str(expr);
	// C decl is easy
	if (str_eq(str, "cdecl")) return update_abi(decl, C);

	// Check veccall
	if (str_eq(str, "veccall"))
	{
		switch (compiler.platform.arch)
		{
			case X86_64:
				return update_abi(decl, X64_VECTOR);
			case ARM:
			case ARMB:
			case AARCH64:
			case AARCH64_32:
			case AARCH64_BE:
				return update_abi(decl, AAPCS_VFP);
			case X86:
				// Unsupported
				return true;
			default:
				return true;
		}
	}
	// Finally check stdcall.
	if (str_eq(str, "stdcall"))
	{
		if (compiler.platform.arch == ARM || compiler.platform.arch == ARMB)
		{
			return update_abi(decl, AAPCS);
		}
		return true;
	}
	return @sema_error_at(context, expr.loc, "Unknown call convention, only 'cdecl', 'stdcall' and 'veccall' are supported");
}

// sema_decls.c:3307 (static)
fn bool sema_analyse_attribute_int_const(SemaContext* context, Expr* expr)
{
	assert(expr);

	// Analyse
	if (!sema_analyse_expr_rvalue(context, expr)) return false;

	// Check type, don't allow typedefs.
	if (!sema_cast_const(expr) || !expr_is_const_int(expr) || !type_is_integer(expr.type))
	{
		return @sema_error_at(context, expr.loc, "Expected an integer compile time constant value.");
	}
	return true;
}

// sema_decls.c:3325 (static)
fn bool sema_analyse_attribute_string_const(SemaContext* context, Expr* expr)
{
	assert(expr);

	// Analyse
	if (!sema_analyse_expr_rvalue(context, expr)) return false;

	// Check the expression and type
	if (!sema_cast_const(expr) || !expr_is_const_string(expr) || expr.type != type_string)
	{
		return @sema_error_at(context, expr.loc, "Expected a compile time constant String.");
	}
	return true;
}

// sema_decls.c:3340 (static)
fn bool sema_analyse_attribute_bool_const(SemaContext* context, Expr* expr)
{
	assert(expr);
	if (!sema_analyse_expr_rvalue(context, expr)) return false;
	if (!sema_cast_const(expr) || !cast_explicit_silent(context, expr, type_bool) || !expr_is_const_bool(expr))
	{
		return @sema_error_at(context, expr.loc, "Expected a boolean compile time constant.");
	}
	return true;
}

// sema_decls.c:3351 (static)
fn StackProtector stack_protector_from_string(String name)
{
	if (str_eq(name, "none")) return STACK_PROTECTOR_NONE;
	if (str_eq(name, "basic")) return STACK_PROTECTOR_BASIC;
	if (str_eq(name, "strong")) return STACK_PROTECTOR_STRONG;
	if (str_eq(name, "all")) return STACK_PROTECTOR_ALL;
	return STACK_PROTECTOR_NOT_SET;
}

// sema_decls.c:3360 (static)
fn StackProbe stack_probe_from_string(String name)
{
	if (str_eq(name, "none")) return STACK_PROBE_NONE;
	if (str_eq(name, "call")) return STACK_PROBE_CALL;
	if (str_eq(name, "inline")) return STACK_PROBE_INLINE;
	return STACK_PROBE_NOT_SET;
}

<* The static `attribute_domain` table of c3c sema_analyse_attribute. *>
const AttributeDomain[NUMBER_OF_ATTRIBUTES.ordinal] ATTRIBUTE_DOMAIN = {
	[AttributeType.ALIGN.ordinal] = ATTR_FUNC | ATTR_CONST | LOCAL_VARIABLE_TYPES | ATTR_GLOBAL | ATTR_BITSTRUCT | ATTR_STRUCT | ATTR_UNION | ATTR_MEMBER,
	[AttributeType.ALLOW_DEPRECATED.ordinal] = ATTR_FUNC,
	[AttributeType.ASMNAME.ordinal] = ATTR_FUNC | ATTR_GLOBAL | ATTR_CONST,
	[AttributeType.BENCHMARK.ordinal] = ATTR_FUNC,
	[AttributeType.BIGENDIAN.ordinal] = ATTR_BITSTRUCT,
	[AttributeType.BUILTIN.ordinal] = ATTR_MACRO | ATTR_FUNC | ATTR_GLOBAL | ATTR_CONST,
	[AttributeType.CALLCONV.ordinal] = ATTR_FUNC | ATTR_INTERFACE_METHOD | ATTR_FNTYPE,
	[AttributeType.STACKPROBE.ordinal] = ATTR_FUNC | ATTR_FNTYPE,
	[AttributeType.NOSTACKPROBE.ordinal] = ATTR_FUNC | ATTR_FNTYPE,
	[AttributeType.STACKPROTECTOR.ordinal] = ATTR_FUNC | ATTR_FNTYPE,
	[AttributeType.NOSTACKPROTECTOR.ordinal] = ATTR_FUNC | ATTR_FNTYPE,
	[AttributeType.CNAME.ordinal] = ATTR_FUNC | ATTR_GLOBAL | ATTR_CONST | USER_DEFINED_TYPES,
	[AttributeType.COMPACT.ordinal] = ATTR_STRUCT | ATTR_UNION,
	[AttributeType.CONST.ordinal] = ATTR_MACRO,
	[AttributeType.CONSTINIT.ordinal] = ATTR_TYPEDEF | ATTR_ENUM,
	[AttributeType.DEPRECATED.ordinal] = (AttributeDomain)~(ATTR_CALL | ATTR_PARAM),
	[AttributeType.DYNAMIC.ordinal] = ATTR_FUNC,
	[AttributeType.EXPORT.ordinal] = ATTR_FUNC | ATTR_GLOBAL | ATTR_CONST | USER_DEFINED_TYPES | ATTR_ALIAS,
	[AttributeType.FINALIZER.ordinal] = ATTR_FUNC,
	[AttributeType.FORMAT.ordinal] = ATTR_FUNC | ATTR_MACRO | ATTR_FNTYPE,
	[AttributeType.IF.ordinal] = (AttributeDomain)~(ATTR_CALL | ATTR_PARAM),
	[AttributeType.FEAT.ordinal] = (AttributeDomain)~(ATTR_CALL | ATTR_PARAM),
	[AttributeType.INIT.ordinal] = ATTR_FUNC,
	[AttributeType.INLINE.ordinal] = ATTR_FUNC | ATTR_CALL,
	[AttributeType.JUMP.ordinal] = (AttributeDomain)0, // Special, used for switch only
	[AttributeType.LINK.ordinal] = ATTR_FUNC | ATTR_MACRO | ATTR_CONST | ATTR_GLOBAL,
	[AttributeType.LITTLEENDIAN.ordinal] = ATTR_BITSTRUCT,
	[AttributeType.LOCAL.ordinal] = ATTR_FUNC | ATTR_MACRO | ATTR_GLOBAL | ATTR_CONST | USER_DEFINED_TYPES | ATTR_ALIAS | ATTR_INTERFACE,
	[AttributeType.MAYDISCARD.ordinal] = CALLABLE_TYPE,
	[AttributeType.MUSTINIT.ordinal] = ATTR_STRUCT | ATTR_UNION | ATTR_BITSTRUCT | ATTR_TYPEDEF,
	[AttributeType.NAKED.ordinal] = ATTR_FUNC,
	[AttributeType.NOALIAS.ordinal] = ATTR_PARAM,
	[AttributeType.NODISCARD.ordinal] = CALLABLE_TYPE,
	[AttributeType.NOINIT.ordinal] = ATTR_GLOBAL | LOCAL_VARIABLE_TYPES,
	[AttributeType.NOINLINE.ordinal] = ATTR_FUNC | ATTR_CALL,
	[AttributeType.NOPADDING.ordinal] = ATTR_STRUCT | ATTR_UNION | ATTR_MEMBER,
	[AttributeType.NORETURN.ordinal] = CALLABLE_TYPE,
	[AttributeType.NOREDZONE.ordinal] = ATTR_FUNC,
	[AttributeType.NOSANITIZE.ordinal] = ATTR_FUNC,
	[AttributeType.NOSTRIP.ordinal] = ATTR_FUNC | ATTR_GLOBAL | ATTR_CONST | EXPORTED_USER_DEFINED_TYPES | ATTR_LOCAL_STATIC,
	[AttributeType.OBFUSCATE.ordinal] = ATTR_ENUM | ATTR_FAULT,
	[AttributeType.OPERATOR.ordinal] = ATTR_MACRO | ATTR_FUNC,
	[AttributeType.OPERATOR_R.ordinal] = ATTR_MACRO | ATTR_FUNC,
	[AttributeType.OPERATOR_S.ordinal] = ATTR_MACRO | ATTR_FUNC,
	[AttributeType.OPTIONAL.ordinal] = ATTR_INTERFACE_METHOD,
	[AttributeType.OVERLAP.ordinal] = ATTR_BITSTRUCT,
	[AttributeType.PACKED.ordinal] = ATTR_STRUCT | ATTR_UNION,
	[AttributeType.PRIVATE.ordinal] = ATTR_FUNC | ATTR_MACRO | ATTR_GLOBAL | ATTR_CONST | USER_DEFINED_TYPES | ATTR_ALIAS | ATTR_INTERFACE,
	[AttributeType.PUBLIC.ordinal] = ATTR_FUNC | ATTR_MACRO | ATTR_GLOBAL | ATTR_CONST | USER_DEFINED_TYPES | ATTR_ALIAS | ATTR_INTERFACE,
	[AttributeType.PURE.ordinal] = ATTR_CALL,
	[AttributeType.REFLECT.ordinal] = ATTR_FUNC | ATTR_GLOBAL | ATTR_CONST | USER_DEFINED_TYPES,
	[AttributeType.SAFEMACRO.ordinal] = ATTR_MACRO,
	[AttributeType.SAFEINFER.ordinal] = ATTR_GLOBAL | LOCAL_VARIABLE_TYPES,
	[AttributeType.SECTION.ordinal] = ATTR_FUNC | ATTR_CONST | ATTR_GLOBAL | ATTR_LOCAL_STATIC,
	[AttributeType.SIMD.ordinal] = (AttributeDomain)0,
	[AttributeType.TAG.ordinal] = ATTR_BITSTRUCT_MEMBER | ATTR_MEMBER | USER_DEFINED_TYPES | CALLABLE_TYPE | LOCAL_VARIABLE_TYPES | ATTR_GLOBAL | ATTR_PARAM,
	[AttributeType.TEST.ordinal] = ATTR_FUNC,
	[AttributeType.UNUSED.ordinal] = (AttributeDomain)~(ATTR_CALL),
	[AttributeType.USED.ordinal] = (AttributeDomain)~(ATTR_CALL),
	[AttributeType.WASM.ordinal] = ATTR_FUNC,
	[AttributeType.WEAK.ordinal] = ATTR_FUNC | ATTR_CONST | ATTR_GLOBAL | ATTR_ALIAS | ATTR_TYPEDEF | ATTR_ENUM,
	[AttributeType.WEAKLINK.ordinal] = ATTR_FUNC | ATTR_CONST | ATTR_GLOBAL,
	[AttributeType.WINMAIN.ordinal] = ATTR_FUNC,
};

// sema_decls.c:3372 (static)
fn bool sema_analyse_attribute(SemaContext* context, ResolvedAttrData* attr_data, Decl* decl, Attr* attr, AttributeDomain domain, bool* erase_decl)
{
	AttributeType type = attr.attr_kind;
	assert(type.ordinal < NUMBER_OF_ATTRIBUTES.ordinal);
	// First check if it doesn't match the domain.
	if ((ATTRIBUTE_DOMAIN[type.ordinal] & domain) != domain)
	{
		return @sema_error_at(context, attr.loc, "'%s' is not a valid %s attribute.", attr.name, attribute_domain_to_string(domain));
	}

	int args = (int)attr.exprs.len;

	// Check that attributes aren't more than 1 on most attributes.
	if (args > 1 && type != LINK && type != TAG && type != WASM && type != FEAT)
	{
		return @sema_error_at(context, attr.exprs[1].loc, "Too many arguments for the attribute.");
	}

	// Grab the first, because that's the common case
	Expr* expr = args ? attr.exprs[0] : null;

	switch (type)
	{
		case PRIVATE:
		case PUBLIC:
		case LOCAL:
		case BUILTIN:
		case NORECURSE:
		case WEAK:
			// These are pseudo-attributes and are processed separately.
			unreachable();
		case DEPRECATED:
			if (attr_data.deprecated.ptr) return @sema_error_at(context, attr.loc, "There can't be more than a single '@deprecated' tag.");
			// We expect an optional string.
			attr_data.deprecated = "";
			if (expr)
			{
				if (!sema_analyse_attribute_string_const(context, expr)) return false;
				attr_data.deprecated = expr_const_bytes_str(expr);
			}
			return true;
		case ALLOW_DEPRECATED:
			decl.allow_deprecated = true;
		case OPTIONAL:
			decl.func_decl.attr_optional = true;
		case WINMAIN:
			if (decl.name.ptr != kw_main.ptr) return @sema_error_at(context, attr.loc, "'@winmain' can only be used on the 'main' function.");
			decl.func_decl.attr_winmain = true;
		case CALLCONV:
			if (!expr) return @sema_error_at(context, decl.loc, "Expected a string argument.");
			if (!sema_analyse_attribute_string_const(context, expr)) return false;
			if (!update_call_abi_from_string(context, decl, expr)) return false;
			return true;
		case STACKPROBE:
			if (!expr) return @sema_error_at(context, attr.loc, "Expected a string argument.");
			if (!sema_analyse_attribute_string_const(context, expr)) return false;
			if ((decl.func_decl.stack_probe = (char)(1 + stack_probe_from_string(expr_const_bytes_str(expr)))) == STACK_PROBE_NOT_SET + 1) // NOLINT
			{
				return @sema_error_at(context, expr.loc, "Unknown stack probe level, only 'none', 'call' and 'inline' are supported");
			}
			return true;
		case NOREDZONE:
			decl.func_decl.attr_noredzone = true;
			return true;
		case NOSTACKPROBE:
			decl.func_decl.stack_probe = (char)(STACK_PROBE_NONE + 1);
			return true;
		case STACKPROTECTOR:
			if (!expr) return @sema_error_at(context, attr.loc, "Expected a string argument.");
			if (!sema_analyse_attribute_string_const(context, expr)) return false;
			if ((decl.func_decl.stack_protector = (char)(1 + stack_protector_from_string(expr_const_bytes_str(expr)))) == STACK_PROTECTOR_NOT_SET + 1) // NOLINT
			{
				return @sema_error_at(context, expr.loc, "Unknown stack protection level, only 'none', 'basic', 'strong' and 'all' are supported");
			}
			return true;
		case NOSTACKPROTECTOR:
			decl.func_decl.stack_protector = (char)(STACK_PROTECTOR_NONE + 1);
			return true;
		case BENCHMARK:
			decl.func_decl.attr_benchmark = true;
		case TAG:
		{
			decl.has_tag = true;
			if (args != 2) return @sema_error_at(context, attr.loc, "'@tag' requires two arguments.");
			Expr* string = attr.exprs[0];
			Expr* val = attr.exprs[1];
			if (!sema_analyse_expr_rvalue(context, string)) return false;
			if (!sema_cast_const(string) || !expr_is_const_string(string)) return @sema_error_at(context, string.loc, "Expected a constant string here, usage is: '@tag(name, value)'.");
			if (!sema_analyse_expr_rvalue(context, val)) return false;
			if (!sema_cast_const(val)) return @sema_error_at(context, val.loc, "Expected a constant value here, usage is: '@tag(name, value)'.");
			String name = expr_const_bytes_str(string);
			foreach (i, tag : attr_data.tags)
			{
				// Overwrite if already found
				if (str_eq(expr_const_bytes_str(tag.exprs[0]), name))
				{
					attr_data.tags[i] = attr;
					return true;
				}
			}
			@vec_add(&attr_data.tags, attr);
			return true;
		}
		case TEST:
			decl.func_decl.attr_test = true;
		case OPERATOR_R:
		case OPERATOR_S:
		case OPERATOR:
		{
			assert(decl.decl_kind == FUNC || decl.decl_kind == MACRO);
			bool failed_op_type = !expr;
			if (!failed_op_type && decl.func_decl.operator)
			{
				return @sema_error_at(context, attr.loc, "This method already has overload, it can't match multiple ones.");
			}
			if (!failed_op_type)
			{
				switch (expr.expr_kind)
				{
					case UNRESOLVED_IDENTIFIER:
						if (expr.unresolved_ident_expr.path || expr.unresolved_ident_expr.ident.ptr != kw_len.ptr)
						{
							failed_op_type = true;
							break;
						}
						decl.func_decl.operator = OVERLOAD_LEN;
					case OPERATOR_CHARS:
						decl.func_decl.operator = expr.overload_expr;
						switch (type)
						{
							case OPERATOR:
								decl.func_decl.overload_type = (char)OVERLOAD_TYPE_LEFT;
							case OPERATOR_R:
								if (!OVERLOAD_MAY_BE_REVERSE[expr.overload_expr])
								{
									return @sema_error_at(context, attr.loc, "'%s' may not be used with @operator_r(), only @operator().", OVERLOAD_NAME[expr.overload_expr]);
								}
								decl.func_decl.overload_type = (char)OVERLOAD_TYPE_RIGHT;
							case OPERATOR_S:
								if (!OVERLOAD_MAY_BE_REVERSE[expr.overload_expr] || expr.overload_expr == OVERLOAD_LESS_THAN)
								{
									return @sema_error_at(context, attr.loc, "'%s' may not be used with @operator_s(), only @operator().", OVERLOAD_NAME[expr.overload_expr]);
								}
								decl.func_decl.overload_type = (char)OVERLOAD_TYPE_SYMMETRIC;
							default:
								unreachable();
						}
					default:
						failed_op_type = true;
				}
			}
			if (!failed_op_type)
			{
				attr_data.overload = attr.loc;
				if (!decl.func_decl.type_parent)
				{
					return @sema_error_at(context, expr.loc, "@operator(...) can only be used with methods.");
				}
				return true;
			}
			// FAILED_OP_TYPE:
			return @sema_error_at(context, attr.loc, "'operator' requires an operator type argument. It should be any of the arithmetic and bit operators, equality operators, '[]', '[]=', '&[]' or 'len'.");
		}
		case ALIGN:
			if (!expr)
			{
				return @sema_error_at(context, attr.loc, "'align' requires an power-of-2 argument, e.g. align(8).");
			}
			return sema_resolve_align_expr(context, expr, &decl.alignment);
		case WASM:
			if (args > 2) return @sema_error_at(context, attr.exprs[2].loc, "Too many arguments to '@wasm', expected 0, 1 or 2 arguments");
			decl.is_export = true;
			if (decl.is_templated)
			{
				return @sema_error_at(context, attr.loc, "'@wasm' is not allowed on generic declarations.");
			}
			if (args == 0) return true;
			if (decl.has_extname)
			{
				return @sema_error_at(context, expr.loc, "An external name is already defined, please use '@wasm` without an argument.");
			}
			if (args == 2)
			{
				if (!decl.is_extern)
				{
					return @sema_error_at(context, expr.loc, "Specifying a wasm import module name is only valid for extern declarations.");
				}
				Expr* mod = expr;
				expr = attr.exprs[1];
				if (!sema_analyse_attribute_string_const(context, mod)) return false;
				attr_data.wasm_module = expr_const_bytes_str(mod);
			}
			if (!sema_analyse_attribute_string_const(context, expr)) return false;
			decl.extname = expr_const_bytes_str(expr);
			decl.has_extname = true;
			return true;
		case EXPORT:
			if (decl.is_templated)
			{
				return @sema_error_at(context, attr.loc, "'@export' is not allowed on generic declarations.");
			}
			if (expr)
			{
				if (!sema_analyse_attribute_string_const(context, expr)) return false;
				if (decl.has_extname)
				{
					return @sema_error_at(context, expr.loc, "An external name is already defined, please use '@export` without an argument.");
				}
				decl.has_extname = true;
				decl.extname = expr_const_bytes_str(expr);
			}
			decl.is_export = true;
			return true;
		case NOSTRIP:
			decl.no_strip = true;
		case NOALIAS:
			decl.var_decl.no_alias = true;
		case FEAT:
			switch (sema_retain_feat(attr))
			{
				case BOOL_ERR: return false;
				case BOOL_FALSE: *erase_decl = true; return true;
				case BOOL_TRUE: return true;
			}
			unreachable();
		case IF:
			if (!expr) return @sema_error_at(context, attr.loc, "'@if' requires a boolean argument.");
			if (!sema_analyse_attribute_bool_const(context, expr)) return false;
			if (!expr.const_expr.b) *erase_decl = true;
			return true;
		case FINALIZER:
			decl.func_decl.attr_finalizer = true;
			// Ugly
			nextcase INIT;
		case FORMAT:
			if (args != 1) return @sema_error_at(context, attr.loc, "'@format' expects the index of the format string as the argument, e.g. '@format(1)'.");
			if (!sema_analyse_attribute_int_const(context, expr)) return false;
			Int i = expr.const_expr.ixx;
			if (int_is_neg(i) || int_icomp(i, 127, GT))
			{
				return @sema_error_at(context, expr.loc, "The index must be between 0 and 127.");
			}
			ushort val = (ushort)i.i;
			Signature* sig_ref = decl.decl_kind == FNTYPE ? &decl.fntype_decl.signature : &decl.func_decl.signature;
			if (sig_ref.attrs.format) return @sema_error_at(context, attr.loc, "'@format' may not appear twice.");
			sig_ref.attrs.format = (char)(val + 1);
			return true;
		case LINK:
			if (args < 1) return @sema_error_at(context, attr.loc, "'@link' requires at least one argument.");
			Expr* cond = args > 1 ? attr.exprs[0] : null;
			if (cond && !sema_analyse_expr_rvalue(context, cond)) return false;
			int start = 0;
			bool has_link = true;
			if (cond && expr_is_const_bool(cond))
			{
				start = 1;
				has_link = cond.const_expr.b;
			}
			for (int i = start; i < args; i++)
			{
				Expr* string = attr.exprs[i];
				if (!sema_analyse_expr_rvalue(context, string)) return false;
				if (!expr_is_const_string(string)) return @sema_error_at(context, string.loc, "Expected a constant string here, usage is: '@link(cond1, link1, link2, ...)'.");
				if (has_link) @vec_add(&attr_data.links, expr_const_bytes_str(string));
			}
			return true;
		case INIT:
			// FINALIZER jumps here (c3c `goto PARSE`).
			if (type == INIT) decl.func_decl.attr_init = true;
			// PARSE:
			if (expr)
			{
				if (!sema_analyse_attribute_int_const(context, expr)) return false;
				ulong prio = decl.func_decl.priority = (uint)(ulong)expr.const_expr.ixx.i;
				if (expr_const_will_overflow(&expr.const_expr, U16) || prio > MAX_PRIORITY || prio < 1)
				{
					return @sema_error_at(context, attr.loc, "The priority must be a value between 1 and %d", MAX_PRIORITY);
				}
			}
			if (!decl.func_decl.priority) decl.func_decl.priority = MAX_PRIORITY;
			return true;
		case CONSTINIT:
			decl.attr_constinit = true;
		case MUSTINIT:
			decl.attr_mustinit = true;
		case SIMD:
			return @sema_error_at(context, attr.loc, "'@simd' is only allowed on typedef types.");
		case SECTION:
		case ASMNAME:
		case CNAME:
			if (decl.is_templated)
			{
				return @sema_error_at(context, attr.loc, "'%s' attributes are not allowed for generic declarations.", attr.name);
			}
			if (!expr)
			{
				return @sema_error_at(context, attr.loc, "'%s' requires a string argument, e.g. %s(\"foo\").", attr.name, attr.name);
			}
			if (!sema_analyse_attribute_string_const(context, expr)) return false;
			if (type != SECTION)
			{
				if (!expr.const_expr.bytes.len) return @sema_error_at(context, expr.loc, "'%s' requires a non-empty name.", attr.name);
				if (decl.has_extname) return @sema_error_at(context, attr.loc, "An external name is already defined, so '%s' cannot be used.", attr.name);
			}
			switch (type)
			{
				case SECTION:
					if (!sema_check_section(context, attr)) return false;
					attr_data.section = expr_const_bytes_str(expr);
				case ASMNAME:
					decl.has_extname = true;
					scratch_buffer_clear();
					scratch_buffer_append_char(1);
					scratch_buffer_append_len(expr.const_expr.bytes.ptr, (usz)expr.const_expr.bytes.len);
					decl.extname = scratch_buffer_copy();
				case CNAME:
					decl.has_extname = true;
					decl.extname = expr_const_bytes_str(expr);
				default:
					unreachable();
			}
			return true;
		case NOINLINE:
			if (decl.func_decl.attr_inline)
			{
				return @sema_error_at(context, attr.loc, "@noinline cannot be combined with @inline.");
			}
			decl.func_decl.attr_noinline = true;
		case NOPADDING:
			decl.attr_nopadding = true;
		case COMPACT:
			decl.attr_nopadding = true;
			decl.strukt.is_compact = true;
		case SAFEINFER:
			decl.var_decl.safe_infer = true;
		case NOINIT:
			decl.var_decl.no_init = true;
		case CONST:
			decl.func_decl.signature.attrs.always_const = true;
		case NODISCARD:
		{
			Signature* sig_ref = decl.decl_kind == FNTYPE ? &decl.fntype_decl.signature : &decl.func_decl.signature;
			if (sig_ref.attrs.noreturn) return @sema_error_at(context, attr.loc, "@nodiscard cannot be combined with @noreturn.");
			if (sig_ref.attrs.maydiscard) return @sema_error_at(context, attr.loc, "@nodiscard cannot be combined with @maydiscard.");
			sig_ref.attrs.nodiscard = true;
		}
		case MAYDISCARD:
		{
			Signature* sig_ref = decl.decl_kind == FNTYPE ? &decl.fntype_decl.signature : &decl.func_decl.signature;
			if (sig_ref.attrs.noreturn) return @sema_error_at(context, attr.loc, "@maydiscard cannot be combined with @noreturn.");
			if (sig_ref.attrs.nodiscard) return @sema_error_at(context, attr.loc, "@maydiscard cannot be combined with @nodiscard.");
			sig_ref.attrs.maydiscard = true;
		}
		case INLINE:
			if (decl.func_decl.attr_noinline)
			{
				return @sema_error_at(context, attr.loc, "@inline cannot be combined with @noinline.");
			}
			decl.func_decl.attr_inline = true;
		case NORETURN:
		{
			Signature* sig_ref = decl.decl_kind == FNTYPE ? &decl.fntype_decl.signature : &decl.func_decl.signature;
			if (sig_ref.attrs.maydiscard) return @sema_error_at(context, attr.loc, "@noreturn cannot be combined with @maydiscard.");
			if (sig_ref.attrs.nodiscard) return @sema_error_at(context, attr.loc, "@noreturn cannot be combined with @nodiscard.");
			sig_ref.attrs.noreturn = true;
		}
		case NOSANITIZE:
			if (!expr)
			{
				return @sema_error_at(context, attr.loc, "'%s' requires a string argument, e.g. %s(\"address\").", attr.name, attr.name);
			}
			if (!sema_analyse_attribute_string_const(context, expr)) return false;
			String str = expr_const_bytes_str(expr);
			if (str_eq(str, "address"))
			{
				decl.func_decl.attr_nosanitize_address = true;
			}
			else if (str_eq(str, "memory"))
			{
				decl.func_decl.attr_nosanitize_memory = true;
			}
			else if (str_eq(str, "thread"))
			{
				decl.func_decl.attr_nosanitize_thread = true;
			}
			else
			{
				return @sema_error_at(context, expr.loc, "Expected \"address\", \"memory\" or \"thread\" as argument.");
			}
			return true;
		case WEAKLINK:
			decl.is_weak_link = true;
		case NAKED:
			assert(domain == ATTR_FUNC);
			decl.func_decl.attr_naked = true;
		case OVERLAP:
			decl.strukt.overlap = true;
		case DYNAMIC:
			decl.func_decl.attr_dynamic = true;
		case BIGENDIAN:
			if (decl.strukt.little_endian)
			{
				@sema_error_at(context, attr.loc, "Attribute cannot be combined with @littleendian");
				return decl_poison(decl);
			}
			decl.strukt.big_endian = true;
		case LITTLEENDIAN:
			if (decl.strukt.big_endian)
			{
				@sema_error_at(context, attr.loc, "Attribute cannot be combined with @bigendian");
				return decl_poison(decl);
			}
			decl.strukt.little_endian = true;
		case PACKED:
			decl.strukt.is_packed = true;
		case UNUSED:
			if (decl.is_must_use)
			{
				return @sema_error_at(context, attr.loc, "@unused cannot be combined with @used.");
			}
			decl.is_maybe_unused = true;
		case USED:
			if (decl.is_maybe_unused)
			{
				return @sema_error_at(context, attr.loc, "@used cannot be combined with @unused.");
			}
			decl.is_must_use = true;
		case PURE:
			// Only used for calls.
			unreachable();
		case SAFEMACRO:
			decl.func_decl.signature.is_safemacro = true;
		case REFLECT:
			decl.will_reflect = true;
		case OBFUSCATE:
			decl.obfuscate = true;
		case JUMP:
			break;
		case NONE:
			unreachable();
	}
	if (expr) return @sema_error_at(context, expr.loc, "'%s' should not have any arguments.", attr.name);
	return true;
}

// sema_decls.c:3917 (static)
fn bool sema_analyse_custom_attribute(SemaContext* context, ResolvedAttrData* attr_data_ref, Decl* decl, Attr* attr, AttributeDomain domain, Decl* top, bool* erase_decl)
{
	// Custom attributes.
	// First find it.
	Decl* attr_decl = sema_resolve_symbol(context, attr.name, attr.path, attr.loc);
	if (!attr_decl) return false;

	// Detect direct cycles @Foo = @Bar @Bar = @Foo
	if (attr_decl == top)
	{
		@sema_error_at(context, top.loc, "Recursive declaration of attribute '%s'.", top.name);
		return decl_poison(attr_decl);
	}

	// Handle the case where the current function is the declaration itself.
	if (context.call_env.kind == ENV_ATTR && context.call_env.attr_declaration == attr_decl)
	{
		decl_poison(attr_decl);
		return @sema_error_at(context, attr_decl.loc, "Recursive declaration of attribute '%s' – it contains itself.",
		                  attr_decl.name);
	}

	// Grab all the parameters to the attribute and copy them.
	Decl*[] params = attr_decl.attr_decl.params;
	int param_count = (int)params.len;
	params = copy_decl_list_single(params);

	// Get the arguments
	Expr*[] args = attr.exprs;

	// Check that the parameters match. No varargs are allowed on attributes,
	// there seems to be little use for it.
	if (param_count != args.len)
	{
		@sema_error_at(context, attr.loc, "Expected %d parameter(s).", param_count);
		@sema_note_prev_at(attr_decl.loc, "The declaration was here.");
		return false;
	}

	// Ok, we have the list of inner attributes.
	Attr*[] attributes = attr_decl.attr_decl.attrs;
	attributes = copy_attributes_single(attributes);

	// Now we need to evaluate these attributes in the attribute definition
	// context.
	SemaContext eval_context;
	sema_context_init(&eval_context, attr_decl.unit);
	eval_context.macro_call_depth = context.macro_call_depth + 1;
	CallEnv eval_env = { .kind = ENV_ATTR, .attr_declaration = decl };
	eval_context.call_env = eval_env;
	// We copy the compilation unit.
	eval_context.compilation_unit = context.unit;

	// First we need to analyse each expression in the current scope
	for (int j = 0; j < param_count; j++)
	{
		Decl* param = params[j];
		Expr* expr = args[j];
		if (param.var_decl.type_info)
		{
			if (!sema_resolve_type_info(context, type_infoptr(param.var_decl.type_info), RESOLVE_TYPE_DEFAULT)) return false;
			Type* type = typeget(param.var_decl.type_info);
			assert(type);
			eval_context.rtype = type;
			if (!sema_analyse_inferred_expr(context, type, expr, null) || !cast_implicit(context, expr, type, false))
			{
				sema_context_destroy(&eval_context);
				return false;
			}
			if (!sema_cast_const(expr))
			{
				@sema_error_at(context, expr.loc, "Expected a compile time value.");
				sema_context_destroy(&eval_context);
				return false;
			}
		}
		else
		{
			eval_context.rtype = type_void;
			if (!sema_analyse_ct_expr(context, args[j]))
			{
				sema_context_destroy(&eval_context);
				return false;
			}
		}
		params[j].var_decl.init_expr = expr;
		params[j].var_decl.kind = CONST;
		// Then add them to the evaluation context.
		// (Yes this is messy)
		sema_add_local(&eval_context, params[j]);
	}
	eval_context.rtype = type_void;
	// Now we've added everything to the evaluation context, so we can (recursively)
	// apply it to the contained attributes, which in turn may be derived attributes.
	if (!sema_analyse_attributes_inner(&eval_context, attr_data_ref, decl, attributes, domain, top ? top : attr_decl, erase_decl))
	{
		sema_context_destroy(&eval_context);
		return false;
	}
	// Then destroy the eval context.
	sema_context_destroy(&eval_context);
	// Stop evaluating on erase.
	return true;
}

// sema_decls.c:4015 (static)
fn bool sema_analyse_attributes_inner(SemaContext* context, ResolvedAttrData* attr_data_ref, Decl* decl, Attr*[] attrs, AttributeDomain domain, Decl* top, bool* erase_decl)
{
	// Detect cycles of the type @Foo = @BarCyclic, @BarCyclic = @BarCyclic
	if (context.macro_call_depth > 1024)
	{
		if (!top) top = decl;
		return @sema_error_at(context, top.loc, "Recursive declaration of attribute '%s'.", top.name);
	}

	// Walk through all of the attributes.
	foreach (attr : attrs)
	{
		if (attr.is_custom)
		{
			if (!sema_analyse_custom_attribute(context, attr_data_ref, decl, attr, domain, top, erase_decl)) return false;
		}
		else
		{
			// The simple case, we have a built in attribute:
			if (!sema_analyse_attribute(context, attr_data_ref, decl, attr, domain, erase_decl)) return false;
		}
		if (*erase_decl) return true;
	}
	return true;
}

// sema_decls.c:4042
fn bool sema_analyse_attributes(SemaContext* context, Decl* decl, Attr*[] attrs, AttributeDomain domain, bool* erase_decl)
{
	if (decl.resolved_attributes) return true;
	ResolvedAttrData data = { .tags = {}, .overload = 0 };
	if (!sema_analyse_attributes_inner(context, &data, decl, attrs, domain, null, erase_decl)) return false;
	if (*erase_decl) return true;
	decl.resolved_attributes = true;
	if (data.tags.len || data.deprecated.ptr || data.links.len || data.section.ptr || data.overload || data.wasm_module.ptr)
	{
		ResolvedAttrData* copy = calloc_arena(ResolvedAttrData::size);
		*copy = data;
		decl.attrs_resolved = copy;
	}
	else
	{
		decl.attrs_resolved = null;
	}
	return true;
}

// sema_decls.c:4063
fn bool sema_analyse_optional_returns(SemaContext* context, Decl* contracts)
{
	// Avoid recursion.
	if (contracts.resolve_status != NOT_DONE) return true;

	// Manually set it to running.
	contracts.resolve_status = RUNNING;

	Decl*[] result = {};
	bool failed = false;
	foreach (expr : contracts.contracts_decl.opt_returns)
	{
		// Case 1 "io::read!"
		if (expr.expr_kind == RETHROW)
		{
			Expr* inner = expr.rethrow_expr.inner;
			// Not an rvalue, so just analyse it.
			if (!sema_analyse_expr(context, inner))
			{
				failed = true;
				break;
			}
			Decl* decl = null;
			// Should be a function or a function typoe
			switch (inner.expr_kind)
			{
				case IDENTIFIER:
					// This should be a macro or a function
					decl = inner.ident_expr;
				case TYPEINFO:
				{
					// If it's a type, then it should be something like
					// alias Foo = fn void?() which can have contracts.
					Type* type = inner.type_expr.type;
					if (type.type_kind != ALIAS) break;
					Decl* alias_ = type.decl;
					assert(alias_.decl_kind == TYPE_ALIAS);
					if (!alias_.type_alias_decl.is_func) break;
					decl = alias_.type_alias_decl.decl;
				}
				default:
					break;
			}
			if (decl)
			{
				decl = decl_flatten(decl);
				if (decl.decl_kind != FNTYPE && decl.decl_kind != FUNC && decl.decl_kind != MACRO) decl = null;
			}
			if (decl)
			{
				// Analyse it and get its contracts
				if (!sema_analyse_decl(context, decl))
				{
					failed = true;
					break;
				}
				DeclId contract_id = decl.docs;
				if (!contract_id) continue;
				Decl* sub_contracts = declptr(contract_id);
				// No contracts -> continue
				if (!sub_contracts.contracts_decl.opt_returns.len) continue;
				// Resolve as needed, then add sub contracts.
				switch (sub_contracts.resolve_status)
				{
					case DONE:
					case RUNNING:
						break;
					case NOT_DONE:
						if (!sema_analyse_optional_returns(context, sub_contracts)) failed = true;
				}
				if (failed) break;
				foreach (d : sub_contracts.contracts_decl.opt_returns_resolved) @vec_add(&result, d);
				continue;
			}
			// goto IS_FAULT
		}
		// IS_FAULT:
		// Here we expect a fault, like `io::EOF`
		if (!sema_analyse_expr_rvalue(context, expr))
		{
			failed = true;
			break;
		}
		// Typedef isn't ok, alias is ok.
		if (expr.type.canonical != type_fault)
		{
			@sema_error_at(context, expr.loc, "Expected a fault here.");
			failed = true;
			break;
		}
		// Could be something that didn't return a constant fault.
		if (!expr_is_const_fault(expr))
		{
			@sema_error_at(context, expr.loc, "A constant fault is required.");
			failed = true;
			break;
		}
		// A fault could be null, exclude that
		Decl* decl = expr.const_expr.fault_val;
		if (!decl)
		{
			@sema_error_at(context, expr.loc, "A non-null fault is required.");
			failed = true;
			break;
		}
		// Otherwise add
		@vec_add(&result, decl);
	}
	if (failed)
	{
		// FAIL:
		// If we fail, clear out the returns.
		contracts.resolve_status = DONE;
		contracts.contracts_decl.opt_returns_resolved = {};
		return false;
	}
	contracts.resolve_status = DONE;
	contracts.contracts_decl.opt_returns_resolved = result;
	return true;
}

// sema_decls.c:4159 (static)
fn Decl* contract_find_param_by_name(String name, Decl*[] params, Decl*[] extra_params)
{
	foreach (param : params)
	{
		if (param && param.name.ptr == name.ptr) return param;
	}
	foreach (param : extra_params)
	{
		if (param && param.name.ptr == name.ptr) return param;
	}
	return null;
}

// sema_decls.c:4171 (static)
fn bool sema_analyse_doc_header(SemaContext* context, DeclId docs, Decl*[] params, Decl*[] extra_params, bool* pure_ref, bool is_raw_vaarg)
{
	bool va_param_found = false;
	if (!docs) return true;
	Decl* contracts = declptr(docs);
	if (!sema_analyse_optional_returns(context, contracts)) return false;
	if (contracts.contracts_decl.pure) *pure_ref = true;

	foreach (e : contracts.contracts_decl.requires)
	{
		String name = e.contract_expr.param.name;
		if (!name.ptr) continue;
		int index = -1;
		foreach (i, param : params)
		{
			if (param.name.ptr == name.ptr)
			{
				index = (int)i;
				break;
			}
		}
		if (index < 0) return @sema_error_at(context, e.loc, "No parameter with the name '%s' could be found.", name);
		e.contract_expr.param.found = true;
		e.contract_expr.param.index = index;
	}
	foreach (&param_contract : contracts.contracts_decl.params)
	{
		if (!param_contract.name.ptr)
		{
			if (va_param_found)
			{
				return @sema_error_at(context, param_contract.loc, "The '...' @param may not be repeated.");
			}
			if (param_contract.modifier != ANY)
			{
				return @sema_error_at(context, param_contract.loc, "'...' @params may not have any in-out modifiers.");
			}
			if (!is_raw_vaarg)
			{
				return @sema_error_at(context, param_contract.loc, "'...' @params are only allowed macros and functions with a '...' parameter.");
			}
			va_param_found = true;
			continue;
		}
		Decl* param = contract_find_param_by_name(param_contract.name, params, extra_params);
		if (!param)
		{
			return @sema_error_at(context, param_contract.loc, "There is no parameter '%s', did you misspell it?", param_contract.name);
		}
		Type* type = param.type;
		if (type) type = type_flatten(type);
		bool may_be_pointer = !type || type_is_pointer(type) || type_is_any_raw(type);
		if (param_contract.by_ref)
		{
			if (!may_be_pointer)
			{
				return @sema_error_at(context, param_contract.loc, "'&' can only be added to pointer type parameters.");
			}
			param.var_decl.not_null = true;
		}
		switch (param_contract.modifier)
		{
			case ANY:
				continue; // ADDED
			case OWN:
				param.var_decl.own_param = true;
			case INIT:
				param.var_decl.init_param = true;
			case DROP:
				param.var_decl.drop_param = true;
			case IN:
				param.var_decl.in_param = true;
			case OUT:
				param.var_decl.out_param = true;
			case INOUT:
				param.var_decl.out_param = true;
				param.var_decl.in_param = true;
		}
		if (!may_be_pointer && type.type_kind != SLICE)
		{
			return @sema_error_at(context, param_contract.loc, "'in', 'out', 'inout', 'init', 'drop' or 'own' may only be added to pointers and slices.");
		}
		// ADDED:
	}
	return true;
}

// sema_decls.c:4265 (static)
fn MainType sema_find_main_type(SemaContext* context, Signature* sig, bool is_winmain)
{
	Decl*[] params = sig.params;
	int param_count = (int)params.len;
	bool is_win32 = compiler.platform.os == WIN32;
	Type* arg_type;
	Type* arg_type2;
	switch (param_count)
	{
		case 0:
			return MainType.TYPE_NO_ARGS;
		case 1:
			arg_type = type_flatten(params[0].type);
			if (arg_type == type_get_slice(type_string)) return MainType.TYPE_ARGS;
			@sema_error_at(context, params[0].loc, "Expected a parameter of type 'String[]'.");
			return MainType.TYPE_ERROR;
		case 2:
			arg_type = type_flatten(params[0].type);
			arg_type2 = type_flatten(params[1].type);
			if (arg_type != type_cint)
			{
				@sema_error_at(context, params[0].loc,
						   "Expected a parameter of type %s for a C-style main.",
						   type_quoted_error_string(type_cint));
				return MainType.TYPE_ERROR;
			}
			if (arg_type2.type_kind != POINTER
				|| type_flatten(arg_type2.pointer) != type_get_ptr(type_char))
			{
				@sema_error_at(context, params[1].loc, "Expected a parameter of type 'char**' for a C-style main.");
				return MainType.TYPE_ERROR;
			}
			if (is_winmain)
			{
				@sema_error_at(context, params[0].loc, "For '@winmain' functions, C-style 'main' with argc + argv isn't valid. It compiles if you remove the '@winmain' attribute.");
				return MainType.TYPE_ERROR;
			}
			return MainType.TYPE_RAW;
		case 4:
			if (!is_win32 || !is_winmain) break;
			for (int i = 0; i < 2; i++)
			{
				arg_type = type_flatten(params[i].type);
				if (arg_type != type_voidptr)
				{
					@sema_error_at(context, params[i].loc, "Expected a parameter of type 'void*' (Win32_HINSTANCE)");
					return MainType.TYPE_ERROR;
				}
			}
			arg_type2 = type_flatten(params[2].type);
			if (arg_type2 != type_get_slice(type_string))
			{
				@sema_error_at(context, params[1].loc, "Expected a parameter of type 'String[]'.");
				return MainType.TYPE_ERROR;
			}
			if (type_flatten(params[3].type) != type_cint)
			{
				@sema_error_at(context, params[3].loc, "Expected a parameter of type %s for the 'showCmd' parameter.",
						   type_quoted_error_string(type_cint));
				return MainType.TYPE_ERROR;
			}
			if (!is_win32)
			{
				@sema_error_at(context, params[0].loc, "'main(Win32_HINSTANCE, Win32_HINSTANCE, String[], int) is only valid for Windows.");
				return MainType.TYPE_ERROR;
			}
			return MainType.TYPE_WIN;
		default:
			break;
	}
	if (is_win32 & is_winmain)
	{
		@sema_error_at(context, params[0].loc, "Expected zero, 1 or 4 parameters for main.");
	}
	else
	{
		@sema_error_at(context, params[0].loc, "Expected zero or 1 parameters for main.");
	}
	return MainType.TYPE_ERROR;
}

// sema_decls.c:4341 (static)
fn BoolErr sema_evaluate_feature(Expr* expr)
{
	if (expr.expr_kind != UNRESOLVED_IDENTIFIER)
	{
		@print_error_at(expr.loc, "One or more feature names were expected here, like '@feat(MY_FEATURE)'. Arbitrary expressions are only valid when using `@if`.");
		return BOOL_ERR;
	}
	if (!expr.unresolved_ident_expr.is_const)
	{
		@print_error_at(expr.loc, "A feature name was expected here, features are all uppercase, like 'FOO'.");
		return BOOL_ERR;
	}
	if (expr.unresolved_ident_expr.path)
	{
		@print_error_at(expr.loc, "A feature name cannot have a path, did you want to use `@if` instead?");
		return BOOL_ERR;
	}
	String name = expr.unresolved_ident_expr.ident;
	return htable_get(&compiler.context.features, (void*)name.ptr) ? BOOL_TRUE : BOOL_FALSE;
}

// sema_decls.c:4360 (static)
fn BoolErr sema_evaluate_feature_expression(Expr* expr)
{
	if (expr.expr_kind == UNARY && expr.unary_expr.operator.ordinal != 0)
	{
		switch (sema_evaluate_feature_expression(expr.unary_expr.expr))
		{
			case BOOL_ERR: return BOOL_ERR;
			case BOOL_TRUE: return BOOL_FALSE;
			case BOOL_FALSE: return BOOL_TRUE;
		}
		unreachable();
	}
	if (expr.expr_kind == BINARY)
	{
		switch (expr.binary_expr.operator)
		{
			case BIT_AND:
			case BIT_OR:
			{
				BoolErr res = sema_evaluate_feature_expression(exprptr(expr.binary_expr.left));
				if (res == BOOL_ERR) return BOOL_ERR;
				BoolErr res2 = sema_evaluate_feature_expression(exprptr(expr.binary_expr.right));
				if (res2 == BOOL_ERR) return BOOL_ERR;
				if (expr.binary_expr.operator == BIT_AND)
				{
					return res == BOOL_TRUE && res2 == BOOL_TRUE ? BOOL_TRUE : BOOL_FALSE;
				}
				return res == BOOL_TRUE || res2 == BOOL_TRUE ? BOOL_TRUE : BOOL_FALSE;
			}
			default:
				break;
		}
	}
	return sema_evaluate_feature(expr);
}

// sema_decls.c:4396
fn BoolErr sema_evaluate_feature_expr_list(Expr*[] exprs)
{
	foreach (expr : exprs)
	{
		BoolErr res_inner = sema_evaluate_feature_expression(expr);
		switch (res_inner)
		{
			case BOOL_ERR:   return BOOL_ERR;
			case BOOL_TRUE:  return BOOL_TRUE;
			case BOOL_FALSE: continue;
		}
	}
	return BOOL_FALSE;
}

// sema_decls.c:4411
fn BoolErr sema_retain_feat(Attr* attr)
{
	assert(attr.attr_kind == FEAT);
	if (!attr.exprs.len)
	{
		@print_error_at(attr.loc, "'@feat' needs at least one feature to match.");
		return BOOL_ERR;
	}
	return sema_evaluate_feature_expr_list(attr.exprs);
}

// sema_decls.c:4418
fn BoolErr sema_retain_conditional_feat(Attr*[] attrs)
{
	foreach (attr : attrs)
	{
		if (attr.attr_kind != FEAT) continue;
		BoolErr result = sema_retain_feat(attr);
		if (result != BOOL_TRUE) return result;
	}
	return BOOL_TRUE;
}

// sema_decls.c:4429
fn Decl* sema_create_runner_main(SemaContext* context, Decl* decl)
{
	bool is_win32 = compiler.platform.os == WIN32;
	Decl* function = decl_new(FUNC, {}, decl.loc);
	function.is_export = true;
	function.has_extname = true;
	function.extname = kw_mainstub;
	function.name = kw_mainstub;
	function.unit = decl.unit;

	// Pick wWinMain, main or wmain
	Decl*[4] params = { null, null, null, null };
	int param_count;
	if (is_win32)
	{
		function.extname = kw_wmain;
		params[0] = decl_new_generated_var(type_cint, PARAM, decl.loc);
		params[1] = decl_new_generated_var(type_get_ptr(type_get_ptr(type_ushort)), PARAM, decl.loc);
		param_count = 2;
	}
	else
	{
		function.extname = kw_main;
		params[0] = decl_new_generated_var(type_cint, PARAM, decl.loc);
		params[1] = decl_new_generated_var(type_get_ptr(type_get_ptr(type_char)), PARAM, decl.loc);
		param_count = 2;
	}

	function.has_extname = true;
	function.func_decl.signature.rtype = type_infoid(type_info_new_base(type_cint, decl.loc));
	function.func_decl.signature.vararg_index = param_count;
	Decl*[] main_params = {};
	for (int i = 0; i < param_count; i++) @vec_add(&main_params, params[i]);
	function.func_decl.signature.params = main_params;
	Ast* body = new_ast(COMPOUND_STMT, decl.loc);
	AstId* next = &body.compound_stmt.first_stmt;
	Ast* ret_stmt = new_ast(RETURN_STMT, decl.loc);
	String kw_main_invoker = symtab_preset(is_win32 ? "@_wmain_runner" : "@_main_runner", AT_IDENT);
	Decl* d = sema_find_symbol(context, kw_main_invoker);
	if (!d)
	{
		@sema_error_at(context, decl.loc, "Missing main forwarding function '%s'.", kw_main_invoker);
		return poisoned_decl;
	}
	Expr* invoker = expr_new(IDENTIFIER, decl.loc);
	expr_resolve_ident(invoker, d);
	Expr* call = expr_new(CALL, decl.loc);
	Expr* fn_ref = expr_variable(decl);
	@vec_add(&call.call_expr.arguments, fn_ref);
	for (int i = 0; i < param_count; i++)
	{
		Expr* arg = expr_variable(params[i]);
		@vec_add(&call.call_expr.arguments, arg);
	}
	call.call_expr.function = exprid(invoker);
	for (int i = 0; i < param_count; i++) params[i].resolve_status = NOT_DONE;
	ast_append(&next, ret_stmt);
	ret_stmt.return_stmt.expr = call;
	function.func_decl.body = astid(body);
	function.is_synthetic = true;
	return function;
}

// sema_decls.c:4499 (static)
fn Decl* sema_create_synthetic_main(SemaContext* context, Decl* decl, MainType main, MainSubType sub_type)
{
	Decl* function = decl_new(FUNC, {}, decl.loc);
	function.is_export = true;
	function.has_extname = true;
	function.extname = kw_mainstub;
	function.name = kw_mainstub;
	function.unit = decl.unit;

	// Pick wWinMain, main or wmain
	Decl*[4] params = { null, null, null, null };
	int param_count;
	switch (sub_type)
	{
		case WINMAIN:
			function.extname = kw_winmain;
			params[0] = decl_new_generated_var(type_voidptr, PARAM, decl.loc);
			params[1] = decl_new_generated_var(type_voidptr, PARAM, decl.loc);
			params[2] = decl_new_generated_var(type_get_ptr(type_ushort), PARAM, decl.loc);
			params[3] = decl_new_generated_var(type_cint, PARAM, decl.loc);
			param_count = 4;
		case WMAIN:
			function.extname = kw_wmain;
			params[0] = decl_new_generated_var(type_cint, PARAM, decl.loc);
			params[1] = decl_new_generated_var(type_get_ptr(type_get_ptr(type_ushort)), PARAM, decl.loc);
			param_count = 2;
		case NORMAL:
			function.extname = kw_main;
			params[0] = decl_new_generated_var(type_cint, PARAM, decl.loc);
			params[1] = decl_new_generated_var(type_get_ptr(type_get_ptr(type_char)), PARAM, decl.loc);
			param_count = 2;
	}

	function.has_extname = true;
	function.func_decl.signature.rtype = type_infoid(type_info_new_base(type_cint, decl.loc));
	function.func_decl.signature.vararg_index = param_count;
	Decl*[] main_params = {};
	for (int i = 0; i < param_count; i++) @vec_add(&main_params, params[i]);
	function.func_decl.signature.params = main_params;
	Ast* body = new_ast(COMPOUND_STMT, decl.loc);
	AstId* next = &body.compound_stmt.first_stmt;
	Ast* ret_stmt = new_ast(RETURN_STMT, decl.loc);
	String main_invoker;
	switch (main)
	{
		case TYPE_ARGS:
			switch (sub_type)
			{
				case WINMAIN: main_invoker = "@win_main_args";
				case WMAIN: main_invoker = "@wmain_main";
				default: main_invoker = "@main_args";
			}
		case TYPE_NO_ARGS:
			switch (sub_type)
			{
				case WINMAIN: main_invoker = "@win_main_no_args";
				case WMAIN: main_invoker = "@wmain_main_no_args";
				default: main_invoker = "@main_no_args";
			}
		case TYPE_WIN:
			assert(sub_type == WINMAIN);
			main_invoker = "@win_main";
		default:
			unreachable();
	}
	String kw_main_invoker = symtab_preset(main_invoker, AT_IDENT);
	Decl* d = sema_find_symbol(context, kw_main_invoker);
	if (!d)
	{
		if (compiler.build.use_stdlib == USE_STDLIB_OFF)
		{
			@sema_error_at(context, decl.loc, "With the standard library disabled and the forwarding macro '%s' not implemented, you may need to use a main function type that doesn't require "
	"forwarding, such as 'fn int main()'.", kw_main_invoker);
			return poisoned_decl;
		}
		@sema_error_at(context, decl.loc, "The stdlib seems to be missing the forwarding main macro '%s'; either provide an implementation or "
				   "use a simpler main function type that doesn't require forwarding, such as 'fn int main()'.", kw_main_invoker);
		return poisoned_decl;
	}
	Expr* invoker = expr_new(IDENTIFIER, decl.loc);
	expr_resolve_ident(invoker, d);
	Expr* call = expr_new(CALL, decl.loc);
	Expr* fn_ref = expr_variable(decl);
	@vec_add(&call.call_expr.arguments, fn_ref);
	for (int i = 0; i < param_count; i++)
	{
		Expr* arg = expr_variable(params[i]);
		@vec_add(&call.call_expr.arguments, arg);
	}
	call.call_expr.function = exprid(invoker);
	for (int i = 0; i < param_count; i++) params[i].resolve_status = NOT_DONE;
	ast_append(&next, ret_stmt);
	ret_stmt.return_stmt.expr = call;
	function.func_decl.body = astid(body);
	function.is_synthetic = true;
	return function;
}

// sema_decls.c:4605 (static)
fn bool sema_analyse_main_function(SemaContext* context, Decl* decl)
{
	assert(decl != context.unit.main_function);
	bool is_win32 = compiler.platform.os == WIN32;
	MainSubType sub_type = decl.func_decl.attr_winmain && is_win32 ? MainSubType.WINMAIN : MainSubType.NORMAL;
	if (decl.visibility != PUBLIC)
	{
		return @sema_error_at(context, decl.loc, "A main function must be public.");
	}
	Signature* signature = &decl.func_decl.signature;
	TypeInfo* rtype_info = type_infoptr(signature.rtype);
	Type* rtype = rtype_info.type;
	bool is_int_return = true;
	if (type_is_optional(rtype))
	{
		return @sema_error_at(context, rtype_info.loc, "The return type of 'main' cannot be an optional.");
	}

	if (type_is_void(rtype)) is_int_return = false;

	if (is_int_return && type_flatten(rtype) != type_cint)
	{
		return @sema_error_at(context, rtype_info.loc, "Expected a return type of 'void' or %s.", type_quoted_error_string(type_cint));
	}
	MainType type = sema_find_main_type(context, signature, sub_type == WINMAIN);
	if (type == TYPE_ERROR) return false;
	if (compiler.build.type == TEST || compiler.build.type == BENCHMARK) return true;
	Decl* function;
	if (compiler.build.no_entry)
	{
		function = decl;
	}
	else
	{
		if (type == TYPE_RAW && !is_int_return)
		{
			return @sema_error_at(context, rtype_info.loc, "Int return is required for a C style main.");
		}

		if ((type == TYPE_RAW || (type == TYPE_NO_ARGS && !is_win32)) && is_int_return)
		{
			// Int return is pass-through at the moment.
			// For Emscripten: LLVM's Emscripten ABI renames `main` to `__original_main`
			// and generates its own `main` wrapper for argc/argv. If we also set is_export,
			// both get exported as "main" causing a duplicate export error.
			// So for Emscripten we set extname but skip is_export.
			bool is_emscripten = compiler.platform.os == EMSCRIPTEN;
			if (!is_emscripten) decl.is_export = true;

			decl.has_extname = true;
			decl.extname = kw_main;
			function = decl;
		}
		else
		{
			if (is_win32)
			{
				if (sub_type != WINMAIN) sub_type = WMAIN;
				switch (compiler.build.win.subsystem)
				{
					case WIN_SUBSYSTEM_DEFAULT:
						compiler.build.win.subsystem = (sub_type == WINMAIN) ? WIN_SUBSYSTEM_WINDOWS : WIN_SUBSYSTEM_CONSOLE;
					case WIN_SUBSYSTEM_WINDOWS:
						if (sub_type != WINMAIN) return @sema_error_at(context, decl.loc, "The 'windows' subsystem requires a WinMain-style function.");
					default:
						if (sub_type == WINMAIN) return @sema_error_at(context, decl.loc, "A WinMain-style function expected subsystem to be 'windows'.");
				}
			}
			function = sema_create_synthetic_main(context, decl, type, sub_type);
			if (!decl_ok(function)) return false;
		}
	}
	// REGISTER_MAIN:
	context.unit.main_function = function;
	if (compiler.context.main)
	{
		@sema_error_at(context, function.loc, "Duplicate main functions found.");
		@sema_note_prev_at(compiler.context.main.loc, "The first one was found here.");
		return false;
	}
	compiler.context.main = function;
	return true;
}

// sema_decls.c:4689 (static)
fn bool sema_analyse_func(SemaContext* context, Decl* decl, bool* erase_decl)
{
	bool is_interface_method = decl.func_decl.attr_interface_method;
	if (!sema_analyse_func_macro(context, decl, is_interface_method ? ATTR_INTERFACE_METHOD : ATTR_FUNC, erase_decl)) return false;
	if (*erase_decl) return true;

	bool is_test = decl.func_decl.attr_test;
	bool is_benchmark = decl.func_decl.attr_benchmark;
	bool is_init_finalizer = decl.func_decl.attr_init || decl.func_decl.attr_finalizer;
	Signature* sig = &decl.func_decl.signature;
	if (is_init_finalizer && (is_test || is_benchmark))
	{
		return @sema_error_at(context, decl.loc, "Test and benchmark functions may not also be marked '@init' or '@finalizer'.");
	}
	if (context.unit.mod.is_compiler_rt)
	{
		if (is_init_finalizer) return @sema_error_at(context, decl.loc, "Functions with '@init' and '@finalizer' may not be used in compiler-rt.");
		if (decl.func_decl.attr_dynamic) return @sema_error_at(context, decl.loc, "'@dynamic' methods may not be used in compiler-rt.");
		if (decl.is_extern) return @sema_error_at(context, decl.loc, "Extern functions are not allowed in compiler-rt.");
	}
	if (is_test || is_benchmark || is_init_finalizer)
	{
		assert(!is_interface_method);
		int params = (int)sig.params.len;
		if (params)
		{
			return @sema_error_at(context, sig.params[0] ? sig.params[0].loc : decl.loc, "%s functions may not take any parameters.",
							  is_init_finalizer ? "'@init' and '@finalizer'" : "'@test' and '@benchmark'");
		}
		TypeInfo* rtype_info = type_infoptr(sig.rtype);
		if (!sema_resolve_type_info(context, rtype_info, RESOLVE_TYPE_DEFAULT)) return false;
		Type* rtype = rtype_info.type;
		if (is_init_finalizer)
		{
			if (!type_is_void(rtype))
			{
				return @sema_error_at(context, rtype_info.loc, "'@init' and '@finalizer' functions may only return 'void'.");
			}
		}
		else if (!type_is_void(rtype))
		{
			return @sema_error_at(context, rtype_info.loc, "'@test' and '@benchmark' function may only return 'void' you can allow 'void!' by passing in '--old-test-bench=yes'.");
		}
	}
	// CHECK_DONE:
	decl.type = type_new_func(decl, sig);
	if (!sema_analyse_function_signature(context, decl, decl_find_target_if_method(decl), sig.abi, sig)) return decl_poison(decl);
	TypeInfo* rtype_info = type_infoptr(sig.rtype);
	assert(rtype_info);
	Type* rtype = rtype_info.type.canonical;
	if (sig.attrs.nodiscard)
	{
		if (type_is_void(rtype))
		{
			return @sema_error_at(context, rtype_info.loc, "@nodiscard cannot be used on functions returning 'void'.");
		}
	}
	if (sig.attrs.maydiscard && !type_is_optional(rtype))
	{
		return @sema_error_at(context, rtype_info.loc, "@maydiscard can only be used on functions returning optional values.");
	}

	if (decl.func_decl.type_parent)
	{
		if (!sema_analyse_method(context, decl)) return false;
	}
	else if (!is_interface_method)
	{
		if (decl.func_decl.attr_dynamic) return @sema_error_at(context, decl.loc, "Only methods may implement interfaces.");
		if (decl.name.ptr == kw_main.ptr)
		{
			if (is_test || is_benchmark)
			{
				return @sema_error_at(context, decl.loc, "The main function may not be annotated %s.", is_test ? "@test" : "@benchmark");
			}
			if (!sema_analyse_main_function(context, decl)) return false;
		}
	}

	// Do we have fn void any.foo(void*) { ... }?
	if (!decl.func_decl.body && !decl.is_extern && !decl.unit.is_interface_file && !is_interface_method)
	{
		return @sema_error_at(context, decl.loc, "Expected a function body, if you want to declare an extern function use "
								"'extern' or place it in an .c3i file.");
	}
	bool pure = false;

	if (!sema_analyse_doc_header(context, decl.docs, decl.func_decl.signature.params, {},
	                             &pure, sig.variadic == RAW)) return false;
	decl.func_decl.signature.attrs.is_pure = pure;
	if (!sema_set_alloca_alignment(context, decl.type, &decl.alignment)) return false;
	return true;
}

// sema_decls.c:4787 (static)
fn bool sema_is_valid_method_param(SemaContext* context, Decl* param, Type* parent_type, bool is_dynamic)
{
	assert(parent_type.canonical == parent_type, "Expected already the canonical version.");
	Type* param_type = param.type;

	if (param_type)
	{
		param_type = param_type.canonical;

		if (is_dynamic)
		{
			if (param_type.type_kind != POINTER || param_type.pointer != parent_type)
			{
				return @sema_error_at(context, type_infoptr(param.var_decl.type_info).loc,
								  "The first parameter must always be a pointer for '@dynamic' methods, "
								  "so please change its type to %s if possible.",
								  type_quoted_error_string(type_get_ptr(parent_type)));
			}
			return true;
		}

		// 1. Same type ok!
		if (param_type == parent_type) return true;

		switch (param_type.type_kind)
		{
			case POINTER:
				if (param_type.pointer == parent_type) return true;
			default:
				break;
		}
	}
	// ERROR:
	return @sema_error_at(context, type_infoptr(param.var_decl.type_info).loc,
					  "The first parameter of a method must be of type %s or %s.",
					  type_quoted_error_string(parent_type),
	                  type_quoted_error_string(type_get_ptr(parent_type)));
}

// sema_decls.c:4825 (static)
fn bool sema_analyse_macro_method(SemaContext* context, Decl* decl)
{
	// Resolve the type of the method.
	TypeInfo* parent_type_info = decl_find_method_target(decl);
	assert(parent_type_info.resolve_status == DONE);
	Type* parent_type = parent_type_info.type.canonical;

	// Check the first argument.
	Decl* first_param = decl.func_decl.signature.params.len ? decl.func_decl.signature.params[0] : null;
	if (!first_param)
	{
		return @sema_error_at(context, decl.loc, "The first parameter to this method must be of type %s or %s.", type_quoted_error_string(parent_type),
		                  type_quoted_error_string(type_get_ptr(parent_type)));
	}

	if (!sema_is_valid_method_param(context, first_param, parent_type, false)) return false;

	if (first_param.var_decl.kind != PARAM_EXPR && first_param.var_decl.kind != PARAM_CT && first_param.var_decl.kind != PARAM)
	{
		return @sema_error_at(context, first_param.loc, "The first parameter must be a compile time, regular or ref (&) type.");
	}
	// Is it an operator?
	if (decl.func_decl.operator)
	{
		decl.resolve_status = DONE;
		if (!sema_analyse_operator_method(context, parent_type, decl)) return false;
	}

	return true;
}

// sema_decls.c:4856 (static)
fn bool sema_analyse_macro_body(SemaContext* context, Decl*[] body_parameters)
{
	int body_param_count = (int)body_parameters.len;
	for (int i = 0; i < body_param_count; i++)
	{
		Decl* param = body_parameters[i];
		assert(param);
		param.resolve_status = RUNNING;
		assert(param.decl_kind == VAR);
		TypeInfo* type_info = type_infoptrzero(param.var_decl.type_info);
		VarDeclKind kind = param.var_decl.kind;
		if (param.var_decl.init_expr)
		{
			return @sema_error_at(context, param.var_decl.init_expr.loc, "Body parameters cannot use default values.");
		}
		if (param.var_decl.self_addr) return @sema_error_at(context, param.loc, "Body parameters cannot be '&' parameters.");
		switch (kind)
		{
			case PARAM:
			case PARAM_EXPR:
			case PARAM_CT:
			case PARAM_CT_TYPE:
				if (!type_info) break;
				if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_DEFAULT)) return false;
			case CONST:
			case GLOBAL:
			case LOCAL:
			case MEMBER:
			case BITMEMBER:
			case LOCAL_CT:
			case LOCAL_CT_TYPE:
			case UNWRAPPED:
			case REWRAPPED:
			case ERASE:
				unreachable();
		}
		if (!sema_check_param_uniqueness_and_type(context, body_parameters, param, i)) return false;
		param.resolve_status = DONE;
	}
	return true;
}

// sema_decls.c:4900 (static)
fn bool sema_check_body_const(SemaContext* context, Ast* body)
{
	while (body)
	{
		switch (body.ast_kind)
		{
			case CT_ASSERT:
			case CT_ECHO_STMT:
			case CT_EXPAND_STMT:
			case CT_FOREACH_STMT:
			case CT_FOR_STMT:
			case CT_IF_STMT:
			case CT_ELSE_STMT:
			case CT_SWITCH_STMT:
			case CT_TYPE_ASSIGN_STMT:
			case DECLARE_STMT:
			case DECLS_STMT:
			case NOP_STMT:
				body = astptrzero(body.next);
				continue;
			case CT_COMPOUND_STMT:
				// c3c recurses on the same node here.
				if (!sema_check_body_const(context, body)) return false;
				body = astptrzero(body.next);
				continue;
			case RETURN_STMT:
				if (!body.return_stmt.expr) return @sema_error_at(context, body.loc, "The 'return' in an `@const` must provide a value, e.g. 'return Foo.typeid;'");
				if (body.next) return @sema_error_at(context, body.loc, "There should not be any statements after 'return'.");
				body = null;
				continue;
			case EXPR_STMT:
				// For some cases we KNOW it's not correct.
				switch (body.expr_stmt.expr_kind)
				{
					case IDENTIFIER:
					case UNRESOLVED_IDENTIFIER:
					case LAMBDA:
					case FORCE_UNWRAP:
					case ASM:
					case TERNARY:
					case RETHROW:
						break;
					default:
						body = astptrzero(body.next);
						continue;
				}
				nextcase POISONED;
			case POISONED:
			case ASM_STMT:
			case ASM_LABEL:
			case ASM_BLOCK_STMT:
			case ASSERT_STMT:
			case BREAK_STMT:
			case CASE_STMT:
			case COMPOUND_STMT:
			case CONTINUE_STMT:
			case DEFAULT_STMT:
			case DEFER_STMT:
			case FOR_STMT:
			case FOREACH_STMT:
			case IF_STMT:
			case BLOCK_EXIT_STMT:
			case SWITCH_STMT:
			case NEXTCASE_STMT:
				return @sema_error_at(context, body.loc, "Only 'return' and compile time statements are allowed in an '@const' macro.");
		}
	}
	return true;
}

// sema_decls.c:4969 (static)
fn bool sema_analyse_macro(SemaContext* context, Decl* decl, bool* erase_decl)
{
	decl.func_decl.unit = context.unit;

	if (!sema_analyse_func_macro(context, decl, ATTR_MACRO, erase_decl)) return false;
	if (*erase_decl) return true;

	Signature* sig = &decl.func_decl.signature;
	if (!sema_analyse_signature(context, sig, decl_find_target_if_method(decl), decl)) return false;

	DeclId body_param = decl.func_decl.body_param;
	if (!decl.func_decl.signature.is_at_macro && body_param && !sig.is_safemacro)
	{
		return @sema_error_at(context, decl.loc, "Names of macros with a trailing body must start with '@'.");
	}
	Decl*[] body_parameters = body_param ? declptr(body_param).body_params : {};
	if (!sema_analyse_macro_body(context, body_parameters)) return false;
	bool pure = false;
	if (!sema_analyse_doc_header(context, decl.docs, sig.params, body_parameters,
	                             &pure, sig.variadic == RAW)) return false;
	if (decl.func_decl.type_parent)
	{
		if (!sema_analyse_macro_method(context, decl)) return false;
	}
	bool always_const = sig.attrs.always_const;
	// Sanity check "always const"
	if (always_const)
	{
		Type* rtype = typeget(sig.rtype);
		if (rtype == type_void) return @sema_error_at(context, decl.loc, "'@const' macros may not return 'void', they should always return a constant value.");
		if (rtype && type_no_optional(rtype) == type_void) return @sema_error_at(context, decl.loc, "'@const' macros may not return 'void?', they should always return a constant value.");
		if (body_parameters.len) return @sema_error_at(context, decl.loc, "'@const' macros cannot have body parameters.");
		Ast* body = astptr(decl.func_decl.body);
		assert(body.ast_kind == COMPOUND_STMT);
		body = astptrzero(body.compound_stmt.first_stmt);
		if (!body) return @sema_error_at(context, decl.loc, "'@const' macros cannot have an empty body.");
		sema_check_body_const(context, body);
	}
	decl.type = null;
	return true;
}

// sema_decls.c:5012 (static)
fn bool sema_analyse_attributes_for_var(SemaContext* context, Decl* decl, bool* erase_decl)
{
	AttributeDomain domain;
	switch (decl.var_decl.kind)
	{
		case CONST:
			domain = ATTR_CONST;
		case GLOBAL:
			domain = ATTR_GLOBAL;
		case PARAM:
		case PARAM_CT_TYPE:
		case PARAM_CT:
			domain = ATTR_PARAM;
		default:
			domain = decl.var_decl.is_static ? ATTR_LOCAL_STATIC : ATTR_LOCAL;
	}
	if (!sema_analyse_attributes(context, decl, decl.attributes, domain, erase_decl)) return decl_poison(decl);
	return true;
}

// sema_decls.c:5035 (static)
fn bool sema_type_is_valid_size(SemaContext* context, Type* type, SourceLocId loc)
{
	uint128 size = 1;
	while (true)
	{
		// RETRY:
		if (size > (uint128)(long)MAX_TYPE_SIZE)
		{
			return @sema_error_at(context, loc, "This type would exceed max type size of %d GB.", (int)((long)MAX_TYPE_SIZE >> 30));
		}
		switch (type.type_kind)
		{
			case BITSTRUCT:
				assert(type.decl.resolve_status == DONE);
				type = type.decl.strukt.container_type.type;
				continue;
			case TYPEDEF:
				type = type.decl.distinct.type;
				continue;
			case ALIAS:
				type = type.canonical;
				continue;
			case TYPEINFO:
			case INFERRED_ARRAY:
			case INFERRED_VECTOR:
			case POISONED:
			case MEMBER:
			case WILDCARD:
			case REFLECTION:
			case FUNC_RAW:
			case FLEXIBLE_ARRAY:
			case UNTYPEDLIST:
				return true;
			case OPTIONAL:
				type = type.optional;
				continue;
			case VOID:
				return true;
			case BOOL:
			case TYPEID:
			case I8..U128:
			case F16..F128:
			case ANYFAULT:
			case INTERFACE:
			case ANY:
			case FUNC_PTR:
			case POINTER:
			case STRUCT:
			case UNION:
			case ENUM:
			case CONSTSET:
			case SLICE:
				size = size * (uint128)(ulong)type_size(type);
			case VECTOR:
			case SIMD_VECTOR:
			case ARRAY:
				size = size * (uint128)type.array.len;
				type = type.array.base;
				continue;
		}
		break;
	}
	if (size > (uint128)(long)MAX_TYPE_SIZE)
	{
		return @sema_error_at(context, loc, "This type would exceed max type size of %d GB.", (int)((long)MAX_TYPE_SIZE >> 30));
	}
	return true;
}

// sema_decls.c:5093 (static)
fn bool sema_analyse_variable_type(SemaContext* context, Type* type, SourceLocId loc)
{
	switch (sema_resolve_storage_type(context, type))
	{
		case STORAGE_ERROR:
			return false;
		case STORAGE_NORMAL:
			return true;
		case STORAGE_VOID:
		case STORAGE_WILDCARD:
			if (type_is_optional(type))
			{
				return @sema_error_at(context, loc, "The use of %s as a variable type is not permitted, "
				                           "catch the error using 'if (catch err = foo) { ... }',"
										   " or use '@catch(foo)' to convert it to a 'fault'.",
				                     type_quoted_error_string(type));
			}
			return @sema_error_at(context, loc, "The use of %s as a variable type is not permitted.", type_quoted_error_string(type));
		case STORAGE_COMPILE_TIME:
			return @sema_error_at(context, loc, "The variable cannot be %s which is an compile time type.",
			                     type_invalid_storage_type_name(type));
		case STORAGE_UNKNOWN:
			return @sema_error_at(context, loc, "%s has unknown size, and so it cannot be a variable type.",
			                     type_quoted_error_string(type));
	}
	unreachable();
}

// sema_decls.c:5121 (static)
fn void sema_error_not_constant(SemaContext* context, Decl* target, Expr* init)
{
	if (init.expr_kind == IDENTIFIER)
	{
		Decl* decl = init.ident_expr;
		if (decl.decl_kind == VAR && decl.var_decl.kind == CONST && decl.is_extern)
		{
			@sema_error_at(context, init.loc, "%s must be assigned a compile-time constant. 'extern' constants are resolved at link time and therefore are not compile-time values.", target.name);
			return;
		}
	}
	@sema_error_at(context, init.loc, "Expected a compile time constant value assigned to %s.", target.name);
}

// sema_decls.c:5139
fn bool sema_analyse_var_decl_ct(SemaContext* context, Decl* decl, bool* check_defined)
{
	Expr* init;
	assert(decl.decl_kind == VAR, "Should only be called on variables.");

	// Grab the optional type_info.
	TypeInfo* type_info = vartype(decl);
	// c3c's `goto FAIL_CHECK` / `goto FAIL` become `fail_check = true` / `fail = true` + `break OUTER`.
	bool fail_check = false;
	bool fail = false;
	switch OUTER: (decl.var_decl.kind)
	{
		case LOCAL_CT_TYPE:
			// Locally declared compile time type, like $Foo
			if (type_info)
			{
				@sema_error_at(context, type_info.loc, "Compile time type variables may not have a type.");
				fail = true;
				break OUTER;
			}
			// Check initialization.
			init = decl.var_decl.init_expr;
			if (init) // NOLINT
			{
				// Try to fold any constant into an lvalue.
				if (!sema_analyse_expr(context, init))
				{
					fail = true;
					break OUTER;
				}

				if (init.expr_kind == TYPEINFO)
				{
					Type* type = init.type_expr.type;
					expr_rewrite_const_typeid(init, type);
				}
				// If this isn't a type, it's an error.
				if (!sema_cast_const(init) || !expr_is_const_typeid(init))
				{
					if (check_defined)
					{
						fail_check = true;
						break OUTER;
					}
					@sema_error_at(context, decl.var_decl.init_expr.loc, "Expected a type assigned to %s.", decl.name);
					fail = true;
					break OUTER;
				}
			}
			// Otherwise we're done.
		case LOCAL_CT:
			// Resolve the type if it's present.
			if (type_info)
			{
				if (!sema_resolve_type_info(context, type_info, RESOLVE_TYPE_ALLOW_INFER))
				{
					fail = true;
					break OUTER;
				}
				// Set the type of the declaration.
				decl.type = type_info.type;
				init = decl.var_decl.init_expr;
				// If there is no init, set it to zero.
				if (!init)
				{
					if (type_is_inferred(decl.type))
					{
						if (check_defined)
						{
							fail_check = true;
							break OUTER;
						}
						@sema_error_at(context, type_info.loc, "No size could be inferred.");
						fail = true;
						break OUTER;
					}
					switch (sema_resolve_storage_type(context, decl.type))
					{
						case STORAGE_NORMAL:
						case STORAGE_COMPILE_TIME:
							break;
						case STORAGE_ERROR:
							fail = true;
							break OUTER;
						case STORAGE_VOID:
						case STORAGE_WILDCARD:
						case STORAGE_UNKNOWN:
							@sema_error_at(context, type_info.loc, "Expected a runtime or compile time type with a well-defined zero value.");
							fail = true;
							break OUTER;
					}
					decl.var_decl.init_expr = init = expr_new(POISONED, decl.loc);
					expr_rewrite_to_const_zero(init, type_no_optional(decl.type));
				}

				// Analyse the expression.
				if (!sema_analyse_expr_rhs(context, decl.type, init, false, null, false))
				{
					fail = true;
					break OUTER;
				}

				if (type_is_inferred(decl.type))
				{
					decl.type = init.type;
				}
				// Check that it is constant.
				if (!sema_cast_const(init) && !expr_is_runtime_const(init))
				{
					if (check_defined)
					{
						fail_check = true;
						break OUTER;
					}
					sema_error_not_constant(context, decl, init);
					fail = true;
					break OUTER;
				}
				break OUTER;
			}
			// If we don't have a type, resolve the expression.
			init = decl.var_decl.init_expr;
			if (init) // NOLINT
			{
				if (init.expr_kind == TYPEINFO)
				{
					if (check_defined)
					{
						fail_check = true;
						break OUTER;
					}
					@sema_error_at(context, init.loc, "You can't assign a type to a regular compile time variable like '%s', but it would be allowed if the variable was a compile time type variable. Such a variable needs to have a type-like name, e.g. '$MyType'.", decl.name);
					fail = true;
					break OUTER;
				}
				if (!sema_analyse_expr_rvalue(context, init))
				{
					fail = true;
					break OUTER;
				}

				// Check it is constant.
				if (!sema_cast_const(init) && !expr_is_runtime_const(init))
				{
					if (check_defined)
					{
						fail_check = true;
						break OUTER;
					}
					sema_error_not_constant(context, decl, init);
					fail = true;
					break OUTER;
				}
				switch (sema_resolve_storage_type(context, init.type))
				{
					case STORAGE_ERROR:
						return false;
					case STORAGE_NORMAL:
					case STORAGE_COMPILE_TIME:
					case STORAGE_UNKNOWN:
						break;
					case STORAGE_WILDCARD:
						return @sema_error_at(context, init.loc, "This expression has an unknown type.");
					case STORAGE_VOID:
						return @sema_error_at(context, init.loc, "This expression is not a real value, so you cannot assign it to a compile time variable.");
				}
				// Update the type.
				decl.type = init.type;
				break OUTER;
			}
			// Here we set a void type if both init and type is missing.
			decl.type = type_void;
		default:
			unreachable();
	}
	if (!fail && !fail_check)
	{
		if (check_defined) return true;
		decl.resolve_status = DONE;
		return sema_add_local(context, decl);
	}
	// FAIL_CHECK:
	if (fail_check && check_defined)
	{
		*check_defined = true;
		return false;
	}
	// FAIL:
	sema_add_local(context, decl);
	return decl_poison(decl);
}

// sema_decls.c:5283 (static)
fn bool sema_analyse_var_decl(SemaContext* context, Decl* decl, bool local, bool* check_defined)
{
	assert(decl.decl_kind == VAR, "Unexpected declaration type");

	VarDeclKind kind = decl.var_decl.kind;

	bool success = true;
	bool is_global = !local;
	switch (kind)
	{
		case LOCAL_CT:
		case LOCAL_CT_TYPE:
			return sema_analyse_var_decl_ct(context, decl, check_defined);
		case GLOBAL:
			is_global = true;
		case CONST:
			if (local) decl.var_decl.is_static = true;
		default:
			break;
	}

	TypeInfo* type_info = vartype(decl);
	// We expect a constant to actually be parsed correctly so that it has a value, so
	// this should always be true.
	if (!type_info && decl.is_extern)
	{
		return @sema_error_at(context, decl.loc, "A type is needed for the extern %s '%s'.", decl_to_name(decl), decl.name);
	}
	assert(type_info || decl.var_decl.init_expr);

	bool erase_decl = false;
	if (!sema_analyse_attributes_for_var(context, decl, &erase_decl)) return false;

	bool is_static = decl.var_decl.is_static;
	bool global_level_var = is_static || decl.var_decl.kind == CONST || is_global;

	if (decl.is_extern && decl.var_decl.init_expr)
	{
		assert(is_global);
		return @sema_error_at(context, decl.var_decl.init_expr.loc, "Extern globals may not have initializers.");
	}

	if (decl.var_decl.no_init && decl.var_decl.init_expr)
	{
		return @sema_error_at(context, decl.var_decl.init_expr.loc, "'@noinit' variables may not have initializers.");
	}
	if (erase_decl)
	{
		decl.decl_kind = ERASED;
		decl.resolve_status = DONE;
		return true;
	}
	if (context.unit.mod.is_compiler_rt)
	{
		if (decl.var_decl.is_threadlocal) return @sema_error_at(context, decl.loc, "Thread locals may not be used in compiler-rt.");
		if (decl.is_extern) return @sema_error_at(context, decl.loc, "Extern globals are not allowed in compiler-rt.");
	}

	if (is_global)
	{
	}
	else if (!check_defined)
	{
		if (context.call_env.kind == ENV_GLOBAL_INIT && !context.call_env.in_no_eval)
		{
			if (context.current_macro)
			{
				return @sema_error_at(context, decl.loc, "Macros with declarations may not be used outside of functions.");
			}
			return @sema_error_at(context, decl.loc, "Variable declarations may not be used outside of functions.");
		}
		// Add a local to the current context, will throw error on shadowing.
		if (!sema_add_local(context, decl)) return false;
	}

	// c3c `goto EXIT_OK` is `skip_to_exit`.
	bool skip_to_exit = false;

	// 1. Local or global constants: const int FOO = 123.
	if (!type_info)
	{
		Expr* init_expr = decl.var_decl.init_expr;
		// 1a. We require an init expression.
		if (!init_expr)
		{
			assert(kind == CONST);
			return @sema_error_at(context, decl.loc, "Constants need to have an initial value.");
		}
		assert(!decl.var_decl.no_init);
		if (!check_defined && kind == LOCAL && !context_is_macro(context) && init_expr.expr_kind != LAMBDA && !decl.var_decl.safe_infer)
		{
			return @sema_error_at(context, decl.loc, "Defining a variable using 'var %s = ...' is only allowed inside a macro, or when defining a lambda. You can override this by adding the attribute '@safeinfer' to the declaration.", decl.name);
		}
		if (!sema_analyse_expr_rvalue(context, init_expr)) return false;
		if (check_defined || global_level_var || !type_is_aggregate(init_expr.type)) sema_cast_const(init_expr);
		if (global_level_var) sema_fold_global_init(init_expr);
		if (global_level_var && !expr_is_runtime_const(init_expr))
		{
			if (check_defined) { *check_defined = true; return false; }
			return @sema_error_at(context, init_expr.loc, "This expression cannot be evaluated at compile time.");
		}
		decl.type = init_expr.type;
		switch (sema_resolve_storage_type(context, init_expr.type))
		{
			case STORAGE_ERROR:
				return false;
			case STORAGE_NORMAL:
				break;
			case STORAGE_WILDCARD:
				if (check_defined) { *check_defined = true; return false; }
				@sema_error_at(context, init_expr.loc, "No type can be inferred from the optional result.");
				return false;
			case STORAGE_VOID:
				if (check_defined) { *check_defined = true; return false; }
				return @sema_error_at(context, init_expr.loc, "You cannot initialize a value to 'void'.");
			case STORAGE_COMPILE_TIME:
				if (check_defined) { *check_defined = true; return false; }
				if (init_expr.type == type_untypedlist)
				{
					if (check_defined) { *check_defined = true; return false; }
					return @sema_error_at(context, init_expr.loc,
					           "The type of an untyped list cannot be inferred, you can try adding an explicit type to solve this.");
				}
				if (decl.var_decl.kind == CONST)
				{
					return @sema_error_at(context, init_expr.loc,
					           "You cannot initialize a constant to %s, but you can assign the expression to a compile time variable.",
					           type_invalid_storage_type_name(init_expr.type));
				}
				return @sema_error_at(context, init_expr.loc, "You can't store a compile time type in a variable.");
			case STORAGE_UNKNOWN:
				if (check_defined) { *check_defined = true; return false; }
				return @sema_error_at(context, init_expr.loc, "You cannot initialize a value to %s as it has unknown size.",
				           type_quoted_error_string(init_expr.type));
		}
		if (!decl.alignment)
		{
			if (!sema_set_alloca_alignment(context, decl.type, &decl.alignment)) return false;
		}
		if (!sema_analyse_variable_type(context, decl.type, init_expr.loc)) return false;
		// Skip further evaluation.
		skip_to_exit = true;
	}

	if (!skip_to_exit)
	{
		if (!sema_resolve_type_info(context, type_info,
		                            decl.var_decl.init_expr ? RESOLVE_TYPE_ALLOW_INFER
		                                                    : RESOLVE_TYPE_DEFAULT)) return false;

		Type* type = decl.type = type_info.type;
		if (!sema_analyse_variable_type(context, type, type_info.loc)) return false;

		type = type_no_optional(type);
		if (type_is_user_defined(type) && type.decl)
		{
			if (!sema_analyse_decl(context, type.decl)) return false;
			sema_display_deprecated_warning_on_use(context, type.decl, type_info.loc);
		}
		Type* init_type;
		if (decl.var_decl.no_init && (init_type = type_is_must_init(type)) != null) // NOLINT
		{
			if (init_type == type.canonical)
			{
				return @sema_error_at(context, type_info.loc, "%s requires initialization ('@mustinit'); remove '@noinit' or change the type.", type_quoted_error_string(decl.type));
			}
			return @sema_error_at(context, type_info.loc, "%s contains the type %s which requires initialization ('@mustinit'); remove '@noinit' or change the type.", type_quoted_error_string(decl.type), type_quoted_error_string(init_type));
		}

		if (is_static && context.call_env.pure)
		{
			return @sema_error_at(context, decl.loc, "'@pure' functions may not have static variables.");
		}

		bool infer_len = type_len_is_inferred(decl.type);
		if (!decl.var_decl.init_expr && infer_len)
		{
			return @sema_error_at(context, type_info.loc, "The length cannot be inferred without an initializer.");
		}
		if (!infer_len) decl.resolve_status = DONE;
		if (decl.var_decl.init_expr)
		{
			Expr* init = decl.var_decl.init_expr;
			if (!infer_len)
			{
				// Pre resolve to avoid problem with recursive definitions.
				if (!decl.alignment)
				{
					if (!sema_set_alloca_alignment(context, decl.type, &decl.alignment)) return false;
				}
			}

			CallEnvKind env_kind = context.call_env.kind;
			if (is_static) context.call_env.kind = ENV_FUNCTION_STATIC;
			int taddr_start = (int)context.compilation_unit.generated_globals.len;
			decl.in_init = true;

			Decl* generic = declptrzero(type_find_generic(decl.type));
			if (generic)
			{
				Decl* temp = context.generic_infer;
				context.generic_infer = generic;
				generic = temp;
			}
			success = sema_expr_analyse_assign_right_side(context, null, decl.type, init, false, true, check_defined);
			context.generic_infer = generic;
			if (!success && check_defined) return false;
			decl.in_init = false;
			context.call_env.kind = env_kind;
			sema_fixup_global_temps_after_generation(context.compilation_unit, taddr_start, decl, decl.var_decl.kind != CONST);
			if (infer_len)
			{
				if (!success) return decl_poison(decl);
				decl.type = type_add_optional(init.type, @is_optional(decl));
			}

			// 2. Check const-ness
			if (global_level_var)
			{
				if (!success) return decl_poison(decl);
				if (!expr_is_runtime_const(init))
				{
					if (check_defined) { *check_defined = true; return false; }
					return @sema_error_at(context, init.loc, "The expression must be a constant value.");
				}
			}
			if (success)
			{
				if (global_level_var || !type_is_aggregate(init.type)) sema_cast_const(init);
				if (global_level_var) sema_fold_global_init(init);
				if (expr_is_const(init))
				{
					init.const_expr.is_hex = false;
				}
			}
		}
	}
	// EXIT_OK:
	decl.resolve_status = DONE;
	// Patch the external name for local consts and static variables.
	if ((decl.var_decl.kind == CONST || is_static) && !decl.extname.ptr && context.call_env.kind == ENV_FUNCTION)
	{
		scratch_buffer_set_extern_decl_name(context.call_env.current_function, true);
		scratch_buffer_append_char('.');
		scratch_buffer_append(decl.name);
		decl.extname = scratch_buffer_copy();
	}
	if (!decl.alignment)
	{
		if (!sema_set_alloca_alignment(context, decl.type, &decl.alignment)) return false;
	}
	if (decl.type && !sema_type_is_valid_size(context, decl.type, decl.var_decl.type_info ? type_infoptr(decl.var_decl.type_info).loc : decl.loc)) return false;
	if (decl.var_decl.kind == LOCAL && !is_static && type_size(decl.type) > compiler.build.max_stack_object_size * 1024)
	{
		usz size = (usz)type_size(decl.type);
		return @sema_error_at(context,
			decl.loc, "The size of this local variable (%s%d Kb) exceeds the maximum allowed stack object size (%d Kb), "
			"you can increase this limit with --max-stack-object-size, but be aware that too large objects "
			"allocated on the stack may lead to the stack running out of memory.", size % 1024 == 0 ? "" : "over ",
			size / 1024,
			compiler.build.max_stack_object_size);
	}
	return success;
}

// sema_decls.c:5544 (static)
fn bool sema_analyse_attribute_decl(SemaContext* context, SemaContext* c, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(c, decl, decl.attributes, ATTR_ALIAS, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (*erase_decl) return true;

	Decl*[] params = decl.attr_decl.params;
	int param_count = (int)params.len;
	for (int i = 0; i < param_count; i++)
	{
		Decl* param = params[i];
		if (param.var_decl.kind != PARAM) return @sema_error_at(context, param.loc, "Expected a simple replacement parameter e.g. 'val' here.");
		if (param.var_decl.init_expr) return @sema_error_at(context, param.loc, "Attribute parameters may not have default values.");
		if (param.var_decl.type_info && !sema_resolve_type_info(c, type_infoptr(param.var_decl.type_info), RESOLVE_TYPE_DEFAULT)) return false;
		param.resolve_status = DONE;
		for (int j = 0; j < i; j++)
		{
			if (params[j].name.ptr == param.name.ptr)
			{
				return @sema_error_at(context, param.loc, "Duplicate parameter name '%s'.", param.name);
			}
		}
	}
	return true;
}

// sema_decls.c:5571 (static)
fn bool char_first_is_upper(String c)
{
	usz i = 0;
	while (i < c.len && c[i] == '_') i++;
	return i < c.len && char_is_upper(c[i]);
}

// sema_decls.c:5577 (static)
fn bool check_valid_symbol_match(SemaContext* context, bool was_constant, Expr* expr, Decl* decl)
{
	if (expr.expr_kind == TYPEINFO)
	{
		return @sema_error_at(context, decl.loc, "To alias a type, the alias name must start with uppercase and contain at least one lowercase letter.");
	}
	if (expr.expr_kind != IDENTIFIER)
	{
		return @sema_error_at(context, expr.loc, "A global variable or function name was expected here.");
	}
	if (char_first_is_upper(expr.ident_expr.name))
	{
		if (!was_constant)
		{
			// c3c passes a stray `decl->name` argument here (no format specifier uses it).
			return @sema_error_at(context, expr.loc, "An alias starting with a lowercase letter is expected to alias a non-constant. "
						"If you want to alias a constant, make sure the "
						"alias name is all uppercase letters.");
		}
	}
	else if (was_constant)
	{
		return @sema_error_at(context, decl.loc, "An uppercase alias is expected to alias a constant. "
						"If you want to alias a non-constant, make sure the alias name "
						"starts with a lower case letter.");
	}
	return true;
}

// sema_decls.c:5606 (static)
fn bool sema_analyse_alias(SemaContext* context, Decl* decl, bool* erase_decl)
{
	if (!sema_analyse_attributes(context, decl, decl.attributes, ATTR_ALIAS, erase_decl)) return decl_poison(decl);
	if (decl_is_deprecated(decl)) context.call_env.ignore_deprecation = true;

	if (*erase_decl) return true;
	bool was_constant = char_first_is_upper(decl.name);
	Expr* expr = decl.define_decl.alias_expr;
	while (expr.expr_kind == TERNARY && expr.ternary_expr.then_expr)
	{
		Expr* cond = exprptr(expr.ternary_expr.cond);
		CondResult res = COND_FALSE;
		Expr* then = exprptr(expr.ternary_expr.then_expr);
		Expr* els = exprptr(expr.ternary_expr.else_expr);
		if (!sema_analyse_cond_expr(context, cond, &res)) return false;
		bool is_const = expr.ternary_expr.is_const;
		switch (res)
		{
			case COND_MISSING:
				if (is_const)
				{
					return @sema_error_at(context, cond.loc, "When using '???' the cond expression must evaluate to a constant.");
				}
				return @sema_error_at(context, expr.loc, "This is not a compile time constant");
			case COND_FALSE:
				if (!is_const)
				{
					if (!sema_analyse_expr(context, then) || !check_valid_symbol_match(context, was_constant, then, decl)) return false;
				}
				expr = els;
			case COND_TRUE:
				if (!is_const)
				{
					if (!sema_analyse_expr(context, els) || !check_valid_symbol_match(context, was_constant, els, decl)) return false;
				}
				expr = then;
		}
	}
	if (!sema_analyse_expr(context, expr)) return false;
	if (!check_valid_symbol_match(context, was_constant, expr, decl)) return false;
	Decl* symbol = expr.ident_expr;
	while (true)
	{
		if (!sema_analyse_decl(context, symbol)) return false;
		if (symbol.decl_kind != ALIAS) break;
		symbol = symbol.define_decl.alias_decl;
	}
	if (symbol.name[0] == '@' && decl.name[0] != '@')
	{
		return @sema_error_at(context, expr.loc, "An at-macro like '%s' must be aliased with an identifier also starting with '@'.", symbol.name);
	}
	decl.type = symbol.type;
	decl.define_decl.alias_decl = symbol;
	if (symbol.visibility == LOCAL && decl.visibility.ordinal < Visibility.LOCAL.ordinal)
	{
		return @sema_error_at(context, decl.loc, "A local symbol like '%s' may not be aliased to 'private' or 'public' visibility, please change it to at least be '@private'", symbol.name);
	}
	return true;
}

// sema_decls.c:5668
fn bool sema_resolve_type_structure(SemaContext* context, Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case INTERFACE:
			case ANY:
			case POISONED:
			case VOID:
			case BOOL:
			case I8..U128:
			case F16..F128:
			case ANYFAULT:
			case TYPEID:
			case UNTYPEDLIST:
			case WILDCARD:
			case TYPEINFO:
			case MEMBER:
			case REFLECTION:
				return true;
			case FUNC_RAW:
			case ENUM:
			case CONSTSET:
			case STRUCT:
			case UNION:
			case BITSTRUCT:
				return sema_analyse_decl(context, type.decl);
			case POINTER:
			case FUNC_PTR:
				type = type.pointer;
				continue;
			case ALIAS:
				type = type.canonical;
				continue;
			case TYPEDEF:
				if (!sema_analyse_decl(context, type.decl)) return false;
				type = type.decl.distinct.type;
				continue;
			case ARRAY:
			case SLICE:
			case FLEXIBLE_ARRAY:
			case INFERRED_ARRAY:
			case VECTOR:
			case SIMD_VECTOR:
			case INFERRED_VECTOR:
				type = type.array.base;
				continue;
			case OPTIONAL:
				type = type.optional;
				continue;
		}
	}
}

// sema_decls.c:5718 (static)
fn Decl* type_is_possible_template(SemaContext* context, TypeInfo* type_info)
{
	if (type_info.resolve_status == DONE) return null;
	if (type_info.kind != INFO_IDENTIFIER) return null;
	if (type_info.subtype != TYPE_COMPRESSED_NONE) return null;
	Decl* candidate = sema_find_template_symbol(context, type_info.unresolved.name, type_info.unresolved.path);
	return candidate && candidate.is_template ? candidate : null;
}

// sema_decls.c:5726
fn bool sema_analyse_method_register(SemaContext* context, Decl* method)
{
	TypeInfo* parent_type_info = decl_find_method_target(method);
	// Maybe check if method->is_templated happens
	Decl* decl = method.is_templated ? null : type_is_possible_template(context, parent_type_info);
	if (decl)
	{
		Decl* generic_section = declptr(decl.generic_id);
		@vec_add(&generic_section.generic_decl.decls, method);
		method.is_template = true;
		method.generic_id = decl.generic_id;

		if (generic_section.generic_decl.instances.len)
		{
			Decl* instance = generic_section.generic_decl.instances[0];
			if (!instance.instance_decl.generated_decls.len) return false;
			instance.instance_decl.generated_decls = {};
			String decl_string = span_to_string(parent_type_info.loc);
			return @sema_error_at(context, instance.loc,
				"Instantiation of the generic type '%s' happens before methods are "
				"registered, please try to rearrange the instantiation order.",
				decl_string);
		}
		return false;
	}
	if (!sema_resolve_type_info(context, parent_type_info, method.decl_kind == MACRO ? RESOLVE_TYPE_MACRO_METHOD : RESOLVE_TYPE_FUNC_METHOD)) return false;

	// Can the type have methods?
	Type* parent_type = parent_type_info.type = parent_type_info.type.canonical;
	if (!type_may_have_method(parent_type))
	{
		return @sema_error_at(context, parent_type_info.loc, "Methods can not be associated with '%s'", type_to_error_string(parent_type));
	}

	if (!type_add_method(context, parent_type.canonical, method)) return false;
	return method.decl_kind != ERASED;
}

// sema_decls.c:5764
fn bool sema_compare_weak_decl(SemaContext* context, Decl* replaced, Decl* replacement)
{
	assert(replaced.decl_kind == replacement.decl_kind);
	Type* replaced_type = replaced.type;
	Type* replacement_type = replacement.type;
	bool var_mismatch = false;
	bool type_mismatch = false;
	switch (replaced.decl_kind)
	{
		case FUNC:
			if (replaced_type.function.prototype.raw_type != replacement_type.function.prototype.raw_type)
			{
				type_mismatch = true;
			}
		case VAR:
			if (!!replacement.var_decl.type_info != !!replaced.var_decl.type_info)
			{
				var_mismatch = true;
			}
			else if (replaced_type != replacement_type)
			{
				type_mismatch = true;
			}
		default:
			break;
	}
	if (var_mismatch)
	{
		// VAR_MISMATCH:
		@sema_error_at(context, replacement.loc, "The definition for '%s' doesn't match the replaced definition, mixing untyped and typed definitions is not permitted.", replacement.name);
		@sema_note_prev_at(replaced.loc, "The replaced definition was here.");
		return false;
	}
	if (type_mismatch)
	{
		// TYPE_MISMATCH:
		@sema_error_at(context, replacement.loc, "The definition for '%s' doesn't match the replaced definition, type mismatch between %s and %s.", replacement.name,
			type_quoted_error_string(replacement.type), type_quoted_error_string(replaced.type));
		@sema_note_prev_at(replaced.loc, "The replaced definition was here.");
		return false;
	}
	return true;
}

// sema_decls.c:5796
fn bool sema_analyse_local(SemaContext* context, Decl* decl, bool* failed_ref)
{
	if (decl.resolve_status == DONE) return decl_ok(decl);
	if (decl.resolve_status == RUNNING)
	{
		if (decl.name.ptr)
		{
			@sema_error_at(context, decl.loc, "Recursive definition of '%s'.", decl.name);
		}
		else
		{
			@sema_error_at(context, decl.loc, "Recursive definition of anonymous declaration.");
		}
		return decl_poison(decl);
	}
	decl.resolve_status = RUNNING;
	// c3c: assert(decl.decl_kind == VAR); -- C assert, compiled out in c3c release builds
	if (!sema_analyse_var_decl(context, decl, true, failed_ref))
	{
		if (failed_ref && *failed_ref) return false;
		return decl_poison(decl);
	}
	assert(failed_ref || decl.resolve_status == DONE);
	return true;
}

// sema_decls.c:5817
fn bool sema_analyse_decl(SemaContext* context, Decl* decl)
{
	if (decl.resolve_status == DONE) return decl_ok(decl);

	SemaContext temp_context;
	context = context_transform_for_eval(context, &temp_context, decl.unit);

	Decl* old_generic_instance = context.generic_instance;
	context.generic_instance = decl.is_templated ? declptr(decl.instance_id) : null;
	bool failed = false;
	if (decl.resolve_status == RUNNING)
	{
		if (decl.name.ptr)
		{
			@sema_error_at(context, decl.loc, "Recursive definition of '%s'.", decl.name);
		}
		else
		{
			@sema_error_at(context, decl.loc, "Recursive definition of anonymous declaration.");
		}
		failed = true;
	}
	bool erase_decl = false;
	if (!failed)
	{
		decl.resolve_status = RUNNING;
		assert(decl.unit);
		switch (decl.decl_kind)
		{
			case ERASED:
				break;
			case INTERFACE:
				failed = !sema_analyse_interface(context, decl, &erase_decl);
			case BITSTRUCT:
				failed = !sema_analyse_bitstruct(context, decl, &erase_decl);
			case STRUCT:
			case UNION:
				failed = !sema_analyse_struct_union(context, decl, &erase_decl);
			case FNTYPE:
				failed = !sema_analyse_fntype(context, decl, &erase_decl);
			case FUNC:
				failed = !sema_analyse_func(context, decl, &erase_decl);
			case MACRO:
				failed = !sema_analyse_macro(context, decl, &erase_decl);
			case VAR:
				failed = !sema_analyse_var_decl(context, decl, false, null);
			case ATTRIBUTE:
				failed = !sema_analyse_attribute_decl(context, context, decl, &erase_decl);
			case TYPEDEF:
				failed = !sema_analyse_typedef(context, decl, &erase_decl);
			case TYPE_ALIAS:
				failed = !sema_analyse_type_alias(context, decl, &erase_decl);
			case ENUM:
				failed = !sema_analyse_enum(context, decl, &erase_decl);
			case CONSTSET:
				failed = !sema_analyse_constset(context, decl, &erase_decl);
			case FAULT:
				failed = !sema_analyse_fault(context, decl, &erase_decl);
			case ALIAS:
				failed = !sema_analyse_alias(context, decl, &erase_decl);
			case ALIAS_PATH:
			case BODYPARAM:
			case CT_ASSERT:
			case CT_ECHO:
			case CT_EXEC:
			case CT_EXPAND:
			case CT_INCLUDE:
			case DECLARRAY:
			case ENUM_CONSTANT:
			case GROUP:
			case IMPORT:
			case LABEL:
			case POISONED:
			case GENERIC:
			case GENERIC_INSTANCE:
			case CONTRACT:
				unreachable();
		}
	}
	if (failed)
	{
		// FAILED:
		context.generic_instance = old_generic_instance;
		sema_context_destroy(&temp_context);
		return decl_poison(decl);
	}
	if (erase_decl)
	{
		decl.decl_kind = ERASED;
	}
	decl.resolve_status = DONE;
	context.generic_instance = old_generic_instance;
	sema_context_destroy(&temp_context);
	return true;
}
