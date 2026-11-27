// Port of c3c src/compiler/abi/c_abi_x64.c (revision 54bab366a): the SysV
// x86_64 C ABI classifier (based on Clang's X86_64ABIInfo).
//
// Deviations from c3c:
// - X64Class members drop the CLASS_ prefix (X64Class.NO_CLASS, ...).
// - `long` is a distinct type here, so sizes / offsets are cast at the
//   type_size() boundary; the arithmetic is unchanged.
// - `~(0U)` (all free int regs) passed as an int is -1, as in c3c.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

enum NamedArgument : char
{
	UNNAMED,
	NAMED,
}

struct Registers
{
	int sse_registers;
	int int_registers;
}

enum X64Class : char
{
	// No not change ordering.
	NO_CLASS,
	MEMORY,
	INTEGER,
	SSE,
	SSEUP,
}

// abi/c_abi_x64.c:19
fn bool try_use_registers(Registers* available, Registers* used)
{
	if (available.sse_registers < used.sse_registers) return false;
	if (available.int_registers < used.int_registers) return false;
	available.int_registers -= used.int_registers;
	available.sse_registers -= used.sse_registers;
	return true;
}

// abi/c_abi_x64.c:42
fn ABIArgInfo* x64_indirect_return_result(Type* type, ParamInfo param)
{
	if (type_is_abi_aggregate(type))
	{
		return abi_arg_new_indirect_not_by_val(type, param);
	}
	type = type_lowering(type);
	if (type_is_promotable_int_bool(type))
	{
		return abi_arg_new_direct_int_ext(type, param);
	}
	return abi_arg_new_direct(param);
}

// abi/c_abi_x64.c:57 (static)
fn bool x64_type_is_illegal_vector(Type* type)
{
	// Only check vectors.
	if (type.type_kind != SIMD_VECTOR) return false;
	long size = type_size(type);
	// Less than 64 bits or larger than the avx native size => not allowed.
	if (size <= 8 || size > compiler.platform.x64.native_vector_size_avx) return true;
	// If we pass i128 in mem, then check for that.
	if (compiler.platform.x64.pass_int128_vector_in_mem)
	{
		// Illegal if i128/u128
		TypeKind kind = type.array.base.type_kind;
		return kind == I128 || kind == U128;
	}
	// Otherwise fine!
	return false;
}

// abi/c_abi_x64.c:75
fn ABIArgInfo* x64_indirect_result(Type* type, int free_int_regs, ParamInfo param)
{
	// If this is a scalar LLVM value then assume LLVM will pass it in the right
	// place naturally.
	//
	// This assumption is optimistic, as there could be free registers available
	// when we need to pass this argument in memory, and LLVM could try to pass
	// the argument in the free register. This does not seem to happen currently,
	// but this code would be much safer if we could mark the argument with
	// 'onstack'. See PR12193.
	type = type_lowering(type);
	if (!type_is_abi_aggregate(type) && !x64_type_is_illegal_vector(type))
	{
		if (type_is_promotable_int_bool(type))
		{
			return abi_arg_new_direct_int_ext(type, param);
		}
		// No change, just put it on the stack
		return abi_arg_new_direct(param);
	}

	// The byval alignment
	int align = type_abi_alignment(type);

	// Pass as arguments if there are no more free int regs
	// (if 'onstack' appears, change this code)
	if (!free_int_regs)
	{
		long size = type_size(type);
		if (align <= 8 && size <= 8)
		{
			return abi_arg_new_direct_coerce_int(param);
		}
	}
	if (align < 8)
	{
		return abi_arg_new_indirect_realigned(8, type, param);
	}
	return abi_arg_new_indirect_by_val(type, param);
}

// abi/c_abi_x64.c:123
<*
 Based on X86_64ABIInfo::classifyRegCallStructTypeImpl in Clang
*>
fn ABIArgInfo* x64_classify_reg_call_struct_type_check(Type* type, Registers* needed_registers, ParamInfo param)
{
	assert(x64_type_is_structure(type));

	// These are all passed in two registers.
	if (type.type_kind == SLICE || type.type_kind == ANY)
	{
		needed_registers.int_registers += 2;
		return abi_arg_new_direct(param);
	}

	// Struct, err type handled =>
	assert(type.type_kind == STRUCT);

	// Variable array structs are always passed by pointer.
	if (type.decl.has_variable_array) return x64_indirect_return_result(type, param);

	foreach (member : type.decl.strukt.members)
	{
		Type* member_type = lowered_member_type(member);
		ABIArgInfo* member_info;
		Registers temp_needed_registers = { 0, 0 };
		if (x64_type_is_structure(member_type))
		{
			// Recursively check the structure.
			member_info = x64_classify_reg_call_struct_type_check(member_type, &temp_needed_registers, param);
		}
		else
		{
			// Pass as single argument.
			member_info = x64_classify_argument_type(member_type, -1, &temp_needed_registers, NAMED, param);
		}
		if (abi_arg_is_indirect(member_info))
		{
			*needed_registers = { 0, 0 };
			return x64_indirect_return_result(type, param);
		}
		needed_registers.sse_registers += temp_needed_registers.sse_registers;
		needed_registers.int_registers += temp_needed_registers.int_registers;
	}
	// Send as direct.
	return abi_arg_new_direct(param);
}

// abi/c_abi_x64.c:169 (static)
fn X64Class x64_merge(X64Class accum, X64Class field)
{
	// 1. Same => result
	// 2. no class + something => something
	// 3. mem + something => mem
	// 4. int + something => int
	// 6. SSE

	// Accum should never be memory (we should have returned) or
	assert(accum != MEMORY);
	if (accum == field) return accum;

	// Swap
	if (accum.ordinal > field.ordinal)
	{
		X64Class temp = field;
		field = accum;
		accum = temp;
	}
	switch (accum)
	{
		case NO_CLASS:
			return field;
		case MEMORY:
			return MEMORY;
		case INTEGER:
			// Other can only be non MEM and non NO_CLASS
			return INTEGER;
		case SSEUP:
		case SSE:
			// Other can only be SSE type
			return SSE;
	}
}

// abi/c_abi_x64.c:204
fn void x64_classify_post_merge(long size, X64Class* lo_class, X64Class* hi_class)
{
	// If one is MEM => both is mem
	// If X87UP is not before X87 => mem
	// If size > 16 && first isn't SSE or any other is not SSEUP => mem
	// If SSEUP is not preceded by SSE/SSEUP => convert to SSE.
	if (*hi_class == MEMORY) *lo_class = MEMORY;
	if (size > 16 && (*lo_class != SSE || *hi_class != SSEUP)) *lo_class = MEMORY;
	if (*hi_class == SSEUP && *lo_class != SSE) *hi_class = SSE;
}

// abi/c_abi_x64.c:215
fn void x64_classify_struct_union(Type* type, long offset_base, X64Class* current, X64Class* lo_class, X64Class* hi_class, NamedArgument named_arg)
{
	long size = type_size(type);
	// 64 byte max.
	if (size > 64) return;

	// Variable sized member is passed in memory.
	if (type.decl.has_variable_array) return;

	// Re-classify
	*current = NO_CLASS;
	bool is_union = type.type_kind == UNION;

	Decl*[] members = type.decl.strukt.members;
	foreach (member : members)
	{
		long offset = offset_base + member.offset;
		// The only case a 256-bit or a 512-bit wide vector could be used is when
		// the struct contains a single 256-bit or 512-bit field. Early check
		// and fallback to memory.
		Type* member_type = lowered_member_type(member);
		if (size > 16 &&
			((!is_union && size != type_size(member_type))
			|| size > compiler.platform.x64.native_vector_size_avx))
		{
			*lo_class = MEMORY;
			x64_classify_post_merge(size, lo_class, hi_class);
			return;
		}
		// Not aligned?
		if (offset % type_abi_alignment(member_type))
		{
			*lo_class = MEMORY;
			x64_classify_post_merge(size, lo_class, hi_class);
			return;
		}

		X64Class field_lo;
		X64Class field_hi;
		x64_classify(member_type, offset, &field_lo, &field_hi, named_arg);
		*lo_class = x64_merge(*lo_class, field_lo);
		*hi_class = x64_merge(*hi_class, field_hi);
		if (*lo_class == MEMORY || *hi_class == MEMORY) break;
	}

	x64_classify_post_merge(size, lo_class, hi_class);
}

// abi/c_abi_x64.c:263
fn void x64_classify_array(Type* type, long offset_base, X64Class* current, X64Class* lo_class, X64Class* hi_class, NamedArgument named_arg)
{
	long size = type_size(type);
	Type* element = lowered_array_element_type(type);
	long element_size = type_size(element);
	// Bigger than 64 bytes => MEM
	if (size > 64) return;

	if (offset_base % type_abi_alignment(element))
	{
		*lo_class = MEMORY;
		x64_classify_post_merge(size, lo_class, hi_class);
		return;
	}

	// Re-classify
	*current = NO_CLASS;
	// The only case a 256-bit or a 512-bit wide vector could be used is when
	// the struct contains a single 256-bit or 512-bit field. Early check
	// and fallback to memory.
	if (size > 16 && (size != type_size(element) || size > compiler.platform.x64.native_vector_size_avx))
	{
		*lo_class = MEMORY;
		return;
	}

	long offset = offset_base;
	for (ArrayIndex i = 0; i < type.array.len; i++)
	{
		X64Class field_lo;
		X64Class field_hi;
		x64_classify(element, offset, &field_lo, &field_hi, named_arg);
		offset += element_size;
		*lo_class = x64_merge(*lo_class, field_lo);
		*hi_class = x64_merge(*hi_class, field_hi);
		if (*lo_class == MEMORY || *hi_class == MEMORY) break;
	}
	x64_classify_post_merge(size, lo_class, hi_class);
	assert(*hi_class != SSEUP || *lo_class == SSE);
}

// abi/c_abi_x64.c:304
fn void x64_classify_vector(Type* type, long offset_base, X64Class* current, X64Class* lo_class, X64Class* hi_class, NamedArgument named_arg)
{
	int size = type_size(type);
	// Pass as int
	if (size == 1 || size == 2 || size == 4)
	{
		*current = INTEGER;
		// Check boundary crossing
		long lo = offset_base / 8;
		long hi = (offset_base + size - 1) / 8;

		// If it crosses boundary, split it.
		if (hi != lo)
		{
			*hi_class = *lo_class;
		}
		return;
	}
	Type* element = type.array.base;
	if (size == 8)
	{
		// 1 x double passed in memory (by gcc)
		if (element.type_kind == F64) return;

		// 1 x "long long" is passed different on older clang and
		// gcc, we pick SSE which is the GCC and later Clang standard.
		*current = SSE;
		// Split if crossing boundary.
		if (offset_base && offset_base != 8)
		{
			*hi_class = *lo_class;
		}
		return;
	}
	if (size == 16 || (named_arg == NAMED && size <= compiler.platform.x64.native_vector_size_avx))
	{
		if (compiler.platform.x64.pass_int128_vector_in_mem
			&& size != 16 && type_is_int128(element)) return;

		*lo_class = SSE;
		*hi_class = SSEUP;
	}
	// Default pass by mem
}

// abi/c_abi_x64.c:351 (static)
fn Decl* x64_get_member_at_offset(Decl* decl, int offset)
{
	if (type_size(decl.type) <= offset) return null;
	Decl*[] members = decl.strukt.members;
	Decl* last_match = null;
	foreach (member : members)
	{
		if (member.offset > offset) break;
		last_match = member;
	}
	assert(last_match);
	return last_match;
}

// abi/c_abi_x64.c:365 (static)
fn void x64_classify(Type* type, long offset_base, X64Class* lo_class, X64Class* hi_class, NamedArgument named)
{
	*lo_class = NO_CLASS;
	*hi_class = NO_CLASS;
	X64Class* current = offset_base < 8 ? lo_class : hi_class;
	*current = MEMORY;
	type = type_lowering(type);
	switch (type.type_kind)
	{
		// LOWERED_TYPES
		case TYPEINFO:
		case INFERRED_ARRAY:
		case INFERRED_VECTOR:
		case POISONED:
		case MEMBER:
		case WILDCARD:
		case REFLECTION:
		case ENUM:
		case ALIAS:
		case TYPEID:
		case TYPEDEF:
		case ANYFAULT:
		case BITSTRUCT:
		case OPTIONAL:
		case INTERFACE:
		case CONSTSET:
		case UNTYPEDLIST:
		case FUNC_RAW:
		case VECTOR:
			unreachable();
		case VOID:
			*current = NO_CLASS;
		case I128:
		case U128:
		case SLICE:
		case ANY:
			*lo_class = INTEGER;
			*hi_class = INTEGER;
		case BOOL:
		case U8:
		case U16:
		case U32:
		case U64:
		case I8:
		case I16:
		case I32:
		case I64:
			*current = INTEGER;
		case BF16:
		case F16:
		case F32:
		case F64:
			*current = SSE;
		case F128:
			*lo_class = SSE;
			*hi_class = SSEUP;
		case POINTER:
		case FUNC_PTR:
			*current = INTEGER;
		case STRUCT:
		case UNION:
			x64_classify_struct_union(type, offset_base, current, lo_class, hi_class, named);
		case FLEXIBLE_ARRAY:
		case ARRAY:
			x64_classify_array(type, offset_base, current, lo_class, hi_class, named);
		case SIMD_VECTOR:
			x64_classify_vector(type, offset_base, current, lo_class, hi_class, named);
	}
}

// abi/c_abi_x64.c:428
fn bool x64_bits_contain_no_user_data(Type* type, int start, int end)
{
	// If the bytes being queried are off the end of the type, there is no user
	// data hiding here.  This handles analysis of builtins, vectors and other
	// types that don't contain interesting padding.
	TypeSize size = type_size(type);
	if (size <= start) return true;
	if (type.type_kind == ARRAY)
	{
		// Check each field to see if the field overlaps with the queried range.
		Type* element_type = lowered_array_element_type(type);
		TypeSize element_size = type_size(element_type);
		for (int i = 0; i < type.array.len; i++)
		{
			// If the field is after the span we care about, then we're done..
			TypeSize offset = i * element_size;
			if (offset >= end) break;
			int element_start = offset < start ? start - offset : 0;
			if (!x64_bits_contain_no_user_data(element_type, element_start, end - offset)) return false;
		}
		// No overlap
		return true;
	}
	if (type.type_kind == STRUCT || type.type_kind == UNION)
	{
		foreach (member : type.decl.strukt.members)
		{
			int offset = member.offset;
			if (offset >= end) break;
			int field_start = offset < start ? start - offset : 0;
			if (!x64_bits_contain_no_user_data(lowered_member_type(member), field_start, end - offset)) return false;
		}
		// No overlap
		return true;
	}
	return false;
}

// abi/c_abi_x64.c:466
fn bool x64_contains_float_at_offset(LoweredType* type, int offset)
{
	if (offset == 0 && type.type_kind == F32) return true;

	// If this is a struct, recurse into the field at the specified offset.
	if (type.type_kind == STRUCT)
	{
		Decl* member = x64_get_member_at_offset(type.decl, offset);
		// Offset is past the end of the struct, i.e. in trailing padding.
		if (!member) return false;
		offset -= member.offset;
		return x64_contains_float_at_offset(lowered_member_type(member), offset);
	}
	if (type.type_kind == ARRAY)
	{
		Type* element_type = lowered_array_element_type(type);
		int element_size = type_size(element_type);
		offset -= (offset / element_size) * element_size;
		return x64_contains_float_at_offset(element_type, offset);
	}
	return false;
}

// abi/c_abi_x64.c:489 (static)
fn Type* x64_get_fp_type_at_offset(Type* type, int ir_offset)
{
	while (true)
	{
		if (!ir_offset && type_is_float(type)) return type;
		switch (type.type_kind)
		{
			case STRUCT:
				Decl* decl = type.decl;
				if (decl.strukt.padding && ir_offset >= type_size(type) - decl.strukt.padding) return null;
				Decl* element = decl.strukt.members[0];
				foreach (member : decl.strukt.members)
				{
					if (member.offset > ir_offset)
					{
						if (ir_offset >= member.offset - member.padding) return null;
						break;
					}
					element = member;
				}
				type = lowered_member_type(element);
				ir_offset -= element.offset;
			case UNION:
				Decl* decl = type.decl;
				if (decl.strukt.padding && ir_offset >= type_size(type) - decl.strukt.padding) return null;
				Decl* element = decl.strukt.members[decl.strukt.union_rep];
				type = lowered_member_type(element);
				ir_offset -= element.offset;
			case ARRAY:
				type = lowered_array_element_type(type);
				long size = type_size(type);
				ir_offset -= (int)((ir_offset / size) * size);
			default:
				return null;
		}
	}
}

// abi/c_abi_x64.c:536 (static)
fn AbiType x64_get_sse_type_at_offset(Type* type, int ir_offset, Type* source_type, int source_offset)
{
	Type* float_type = x64_get_fp_type_at_offset(type, ir_offset);
	if (!float_type || float_type == type_double) return abi_type_get(type_double);

	long size = type_size(float_type);
	long source_size = (long)type_size(source_type) - source_offset;

	Type* float_type2 = null;
	if (source_size > size)
	{
		float_type2 = x64_get_fp_type_at_offset(type, ir_offset + (int)size);
	}

	if (!float_type2)
	{
		// Check if type is half / bf16 + float, float will be at offset + 4 due
		// to alignment.
		if (type_is_16bit_float(float_type) && source_size > 4)
		{
			float_type2 = x64_get_fp_type_at_offset(type, ir_offset + 4);
		}
		// If we can't get a second FP type, return a simple half or float.
		if (!float_type2) return abi_type_get(float_type);
	}

	if (float_type == type_float && float_type == float_type2)
	{
		return abi_type_spec(ABI_TYPE_FLOAT_VEC_2);
	}

	if (type_is_16bit_float(float_type) && type_is_16bit_float(float_type2))
	{
		bool has_following_float = source_size > 4
				&& x64_get_fp_type_at_offset(type, ir_offset + 4) != null;
		if (float_type.type_kind == BF16)
		{
			return abi_type_spec(has_following_float ? ABI_TYPE_BFLOAT16_VEC_4 : ABI_TYPE_BFLOAT16_VEC_2);
		}
		return abi_type_spec(has_following_float ? ABI_TYPE_FLOAT16_VEC_4 : ABI_TYPE_FLOAT16_VEC_2);
	}

	if (type_is_16bit_float(float_type) || type_is_16bit_float(float_type2))
	{
		return abi_type_spec(ABI_TYPE_FLOAT16_VEC_4);
	}
	return abi_type_get(type_double);
}

// abi/c_abi_x64.c:588
<*
 Based off X86_64ABIInfo::GetINTEGERTypeAtOffset in Clang
*>
fn AbiType x64_get_int_type_at_offset(Type* type, int offset, Type* source_type, int source_offset)
{
	type = type_lowering(type);
	switch (type.type_kind)
	{
		// LOWERED_TYPES
		case TYPEINFO:
		case INFERRED_ARRAY:
		case INFERRED_VECTOR:
		case POISONED:
		case MEMBER:
		case WILDCARD:
		case REFLECTION:
		case ENUM:
		case ALIAS:
		case TYPEID:
		case TYPEDEF:
		case ANYFAULT:
		case BITSTRUCT:
		case OPTIONAL:
		case INTERFACE:
		case CONSTSET:
		case VOID:
		case FUNC_RAW:
		case VECTOR:
		case UNTYPEDLIST:
			unreachable();
		case U64:
		case I64:
		case POINTER:
		case FUNC_PTR:
			if (!offset) return abi_type_get(type);
		case BOOL:
		case U8:
		case I8:
		case I16:
		case U16:
		case U32:
		case I32:
			if (offset) break;
			if (x64_bits_contain_no_user_data(source_type,
											  source_offset + type_size(type),
											  source_offset + 8))
			{
				return abi_type_get(type);
			}
		case STRUCT:
			Decl* member = x64_get_member_at_offset(type.decl, offset);
			if (member)
			{
				return x64_get_int_type_at_offset(lowered_member_type(member), offset - member.offset, source_type, source_offset);
			}
		case ANY:
			if (offset < 8) return abi_type_get(type_ulong);
			if (offset < 16) return abi_type_get(type_voidptr);
		case SLICE:
			if (offset < 8) return abi_type_get(type_voidptr);
			if (offset < 16) return abi_type_get(type_ulong);
		case FLEXIBLE_ARRAY:
			unreachable();
		case ARRAY:
			Type* element = lowered_array_element_type(type);
			TypeSize element_size = type_size(element);
			TypeSize element_offset = (offset / element_size) * element_size;
			return x64_get_int_type_at_offset(element, offset - element_offset, source_type, source_offset);
		case I128:
		case U128:
		case BF16:
		case F16:
		case F32:
		case F64:
		case F128:
		case UNION:
		case SIMD_VECTOR:
			break;
	}
	long size = type_size(source_type);
	assert(size != source_offset);
	if (size - source_offset > 8) return abi_type_get(type_ulong);
	return abi_type_get_int_bits((BitSize)(size - source_offset) * 8);
}

// abi/c_abi_x64.c:663 (static)
<*
 This is only called on SSE.
*>
fn AbiType x64_get_byte_vector_type(Type* type)
{
	// Wrapper structs/arrays that only contain vectors are passed just like
	// vectors; strip them off if present.
	Type* inner_type = type_abi_find_single_struct_element(type, true);
	if (inner_type) type = inner_type;
	type = type_lowering(type);

	// If vector
	if (type.type_kind == SIMD_VECTOR)
	{
		Type* element = type.array.base.canonical;
		if (compiler.platform.x64.pass_int128_vector_in_mem && type_is_int128(element))
		{
			// Convert to u64
			return { .abi_type = ABI_TYPE_LONG_VEC_2 };
		}
		return abi_type_get(type);
	}

	if (type.type_kind == F128) return abi_type_get(type);

	int size = type_size(type);

	assert(size == 16 || size == 32 || size == 64);

	// Return a vector type based on the size.
	switch (size)
	{
		case 16: return { .abi_type = ABI_TYPE_DOUBLE_VEC_2 };
		case 32: return { .abi_type = ABI_TYPE_DOUBLE_VEC_4 };
		case 64: return { .abi_type = ABI_TYPE_DOUBLE_VEC_8 };
		default:
			unreachable();
	}
}

// abi/c_abi_x64.c:701 (static)
fn ABIArgInfo* x64_get_argument_pair_return(AbiType low_type, AbiType high_type, ParamInfo param)
{
	TypeSize low_size = abi_type_size(low_type);
	int hi_start = aligned_offset(low_size, abi_type_abi_alignment(high_type));
	assert(hi_start != 0 && hi_start <= 8);
	if (hi_start != 8)
	{
		low_type = abi_type_is_float(low_type) ? abi_type_get(type_double) : abi_type_get(type_long);
	}

	return abi_arg_new_direct_pair(low_type, high_type, param);
}

// abi/c_abi_x64.c:715
fn ABIArgInfo* x64_classify_return(ParamInfo param)
{
	Type* return_type = type_lowering(param.type);
	// AMD64-ABI 3.2.3p4: Rule 1. Classify the return type with the
	// classification algorithm.
	X64Class hi_class;
	X64Class lo_class;
	x64_classify(return_type, 0, &lo_class, &hi_class, NAMED);

	// Invariants
	assert(hi_class != MEMORY || lo_class == MEMORY);
	assert(hi_class != SSEUP || lo_class == SSE);

	AbiType result_type = ABI_TYPE_EMPTY;
	switch (lo_class)
	{
		case NO_CLASS:
			if (hi_class == NO_CLASS)
			{
				return abi_arg_ignore();
			}
			// If low part is padding, keep type null
			assert(hi_class == SSE || hi_class == INTEGER);
		case SSEUP:
			unreachable();
		case MEMORY:
			// AMD64-ABI 3.2.3p4: Rule 2. Types of class memory are returned via
			// hidden argument.
			return x64_indirect_return_result(return_type, param);
		case INTEGER:
			// AMD64-ABI 3.2.3p4: Rule 3. If the class is INTEGER, the next
			// available register of the sequence %rax, %rdx is used.
			result_type = x64_get_int_type_at_offset(return_type, 0, return_type, 0);
			if (hi_class == NO_CLASS && type_is_promotable_int_bool(return_type))
			{
				return abi_arg_new_direct_coerce_int_ext(return_type, param);
			}
		case SSE:
			result_type = x64_get_sse_type_at_offset(return_type, 0, return_type, 0);
	}

	AbiType high_part = ABI_TYPE_EMPTY;
	switch (hi_class)
	{
		case MEMORY:
		case NO_CLASS:
			// Previously handled.
			break;
		case INTEGER:
			assert(lo_class != NO_CLASS);
			high_part = x64_get_int_type_at_offset(return_type, 8, return_type, 8);
		case SSE:
			assert(lo_class != NO_CLASS);
			high_part = x64_get_sse_type_at_offset(return_type, 8, return_type, 8);
		case SSEUP:
			// AMD64-ABI 3.2.3p4: Rule 5. If the class is SSEUP, the eightbyte
			// is passed in the next available eightbyte chunk if the last used
			// vector register.
			//
			// SSEUP should always be preceded by SSE, just widen.
			assert(lo_class == SSE, "Unexpected SSEUp classification.");
			result_type = x64_get_byte_vector_type(return_type);
	}

	// If a high part was specified, merge it together with the low part.  It is
	// known to pass in the high eightbyte of the result.  We do this by forming a
	// first class struct aggregate with the high and low part: {low, high}
	if (abi_type_is_valid(high_part)) return x64_get_argument_pair_return(result_type, high_part, param);

	if (abi_type_match(result_type, return_type))
	{
		return abi_arg_new_direct(param);
	}
	return abi_arg_new_direct_coerce_type(result_type, param);
}

// abi/c_abi_x64.c:809 (static)
<*
 Based off X86_64ABIInfo::classifyArgumentType in Clang.
 It completely ignores the x87 type, which C3 does not use.

 @param type : "the type to classify, it should already have been flattened."
*>
fn ABIArgInfo* x64_classify_argument_type(Type* type, int free_int_regs, Registers* needed_registers, NamedArgument is_named, ParamInfo param)
{
	assert(type == type_lowering(type));
	X64Class hi_class;
	X64Class lo_class;
	x64_classify(type, 0, &lo_class, &hi_class, is_named);

	// Invariants
	assert(hi_class != MEMORY || lo_class == MEMORY);
	assert(hi_class != SSEUP || lo_class == SSE);

	AbiType result_type = ABI_TYPE_EMPTY;
	*needed_registers = { 0, 0 };

	// Start by checking the lower class.
	switch (lo_class)
	{
		case NO_CLASS:
			// Only C++ would leave 8 bytes of padding, so we can ignore that case.
			assert(hi_class == NO_CLASS);
			return abi_arg_ignore();
		case SSEUP:
			unreachable();
		case MEMORY:
			return x64_indirect_result(type, free_int_regs, param);
		case INTEGER:
			needed_registers.int_registers++;
			result_type = x64_get_int_type_at_offset(type, 0, type, 0);
			if (hi_class == NO_CLASS && type_is_promotable_int_bool(type))
			{
				assert(abi_type_is_type(result_type));
				return abi_arg_new_direct_coerce_int_ext(result_type.type, param);
			}
		case SSE:
			result_type = x64_get_sse_type_at_offset(type, 0, type, 0);
			needed_registers.sse_registers++;
	}

	// At this point we know it's not MEMORY, since that's always handled.
	AbiType high_part = ABI_TYPE_EMPTY;
	switch (hi_class)
	{
		case MEMORY:
			unreachable();
		case NO_CLASS:
			break;
		case INTEGER:
			needed_registers.int_registers++;
			high_part = x64_get_int_type_at_offset(type, 8, type, 8);
			// Return directly into high part.
			assert(lo_class != NO_CLASS, "empty first 8 bytes not allowed, this is C++ stuff.");
		case SSE:
			needed_registers.sse_registers++;
			high_part = x64_get_sse_type_at_offset(type, 8, type, 8);
			assert(lo_class != NO_CLASS, "empty first 8 bytes not allowed, this is C++ stuff");
		case SSEUP:
			assert(lo_class == SSE, "Unexpected SSEUp classification.");
			result_type = x64_get_byte_vector_type(type);
	}

	// If a high part was specified, merge it together with the low part.  It is
	// known to pass in the high eightbyte of the result.  We do this by forming a
	// first class struct aggregate with the high and low part: {low, high}
	if (abi_type_is_valid(high_part)) return x64_get_argument_pair_return(result_type, high_part, param);

	if (abi_type_match(result_type, type))
	{
		return abi_arg_new_direct(param);
	}
	if (abi_type_is_type(result_type))
	{
		Type* result = result_type.type.canonical;
		if (type_is_integer(type) && type_is_integer(result) && type.builtin.bytesize == result.builtin.bytesize)
		{
			return abi_arg_new_direct(param);
		}
	}
	return abi_arg_new_direct_coerce_type(result_type, param);
}

// abi/c_abi_x64.c:894 (static)
fn bool x64_type_is_structure(Type* type)
{
	switch (type.type_kind)
	{
		case STRUCT:
		case SLICE:
		case ANY:
			return true;
		default:
			return false;
	}
}

// abi/c_abi_x64.c:914 (static)
<*
 This code is based on the loop operations in X86_64ABIInfo::computeInfo in Clang

 @param param : "param info"
 @param available_registers : "to update"
 @param named : "whether this is a named (non-vararg) parameter or not."
 @return "the calculated ABI"
*>
fn ABIArgInfo* x64_classify_parameter(ParamInfo param, Registers* available_registers, NamedArgument named)
{
	Registers needed_registers = { 0, 0 };
	Type* type = type_lowering(param.type);
	ABIArgInfo* info = x64_classify_argument_type(type, available_registers.int_registers, &needed_registers, named, param);

	// Check if we can fit in a register, we're golden.
	if (try_use_registers(available_registers, &needed_registers)) return info;

	// The rest needs to be passed indirectly.
	return x64_indirect_result(type, available_registers.int_registers, param);
}

// abi/c_abi_x64.c:928
fn void c_abi_func_create_x64(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	if (prototype.use_win64)
	{
		c_abi_func_create_win64(prototype, params, param_count, vaargs, vaarg_count);
		return;
	}

	Registers available_registers = {
		.int_registers = 6,
		.sse_registers = 8
	};

	prototype.ret_abi_info = x64_classify_return(prototype.return_info);
	if (abi_arg_is_indirect(prototype.ret_abi_info)) available_registers.int_registers--;

	if (param_count)
	{
		ABIArgInfo*[] args = ((ABIArgInfo**)calloc_arena(ABIArgInfo*::size * (usz)param_count))[:param_count];
		for (int i = 0; i < param_count; i++)
		{
			args[i] = x64_classify_parameter(params[i], &available_registers, NAMED);
		}
		prototype.abi_args = args;
	}
	if (vaarg_count)
	{
		ABIArgInfo*[] args = ((ABIArgInfo**)calloc_arena(ABIArgInfo*::size * (usz)vaarg_count))[:vaarg_count];
		for (int i = 0; i < vaarg_count; i++)
		{
			args[i] = x64_classify_parameter(vaargs[i], &available_registers, UNNAMED);
		}
		prototype.abi_varargs = args;
	}
}
