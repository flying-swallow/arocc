// The parts of c3c src/compiler/codegen_internal.h, c_abi_internal.h and
// codegen_general.c that the C ABI port (c_abi*.c3) needs to build function
// prototypes during sema: type lowering, the AbiType helpers,
// type_abi_find_single_struct_element and type_is_homogeneous_aggregate
// (with its statics). Owned by the ABI port.
//
// Deviations from c3c:
// - c3c's `goto`/`while (1)` lowering loops are `while (true)` + `continue`.
// - The `ByVal` enum keeps its C member names as BY_VAL / BY_VAL_SKIP.
// - type_is_homogeneous_aggregate: `goto TYPECHECK` is the shared tail,
//   repeated in the struct and array cases.
module aro::frontend::c3::compiler;

<* c_abi_internal.h `ByVal`. *>
enum ByVal : char
{
	BY_VAL,
	BY_VAL_SKIP,
}

<* c_abi_internal.h `Regs`. *>
struct Regs
{
	int int_regs;
	int float_regs;
}

// ---------------------------------------------------------------------------
// codegen_internal.h

<*
 keep_typeid_fault: anyfault and typeid stay themselves instead of becoming
 uptr (the C backend gives them C pointer types, which static initializers
 need as address constants).
*>
fn LoweredType* type_lowering_ex(Type* type, bool keep_typeid_fault)
{
	while (true)
	{
		assert(type);
		type = type.canonical;
		switch (type.type_kind)
		{
			case ALIAS:
				unreachable();
			case OPTIONAL:
				type = type.optional;
				continue;
			case TYPEDEF:
				type = type.decl.distinct.type;
				continue;
			case CONSTSET:
			case ENUM:
				type = enum_inner_type(type);
				continue;
			case FUNC_PTR:
				Type* raw_func = type.pointer;
				if (raw_func.function.prototype && raw_func.function.prototype.raw_type == raw_func) return type;
				FunctionPrototype* proto = type_get_resolved_prototype(raw_func);
				return type_get_func_ptr(proto.raw_type);
			case INTERFACE:
				return type_any;
			case ANYFAULT:
			case TYPEID:
				return keep_typeid_fault ? type : type_uptr.canonical;
			case BITSTRUCT:
				type = type.decl.strukt.container_type.type;
				continue;
			case WILDCARD:
				type = type_void;
				continue;
			case POINTER:
				Type* pointer = type.pointer;
				Type* flat = type_lowering_ex(pointer, keep_typeid_fault);
				if (flat == pointer) return type;
				return type_get_ptr(flat);
			case SLICE:
			case ARRAY:
			case VECTOR:
			case SIMD_VECTOR:
			case FLEXIBLE_ARRAY:
				Type* arr_type = type.array.base;
				Type* flat = type_lowering_ex(arr_type, keep_typeid_fault);
				if (flat == arr_type) return type;
				switch (type.type_kind)
				{
					case SLICE:
						return type_get_slice(flat);
					case ARRAY:
						return type_get_array(flat, type.array.len);
					case VECTOR:
					case SIMD_VECTOR:
						return type_get_vector_from_vector(flat, type);
					case FLEXIBLE_ARRAY:
						return type_get_flexible_array(flat);
					default:
						unreachable();
				}
			default:
				return type;
		}
	}
}

fn LoweredType* type_lowering(Type* type) @inline => type_lowering_ex(type, false);

fn LoweredType* type_lowering_abi(Type* type)
{
	while (true)
	{
		assert(type);
		type = type.canonical;
		switch (type.type_kind)
		{
			case ALIAS:
				unreachable();
			case OPTIONAL:
				type = type.optional;
				continue;
			case TYPEDEF:
				type = type.decl.distinct.type;
				continue;
			case CONSTSET:
			case ENUM:
				type = enum_inner_type(type);
				continue;
			case FUNC_PTR:
				Type* raw_func = type.pointer;
				if (raw_func.function.prototype && raw_func.function.prototype.raw_type == raw_func) return type;
				FunctionPrototype* proto = type_get_resolved_prototype(raw_func);
				return type_get_func_ptr(proto.raw_type);
			case INTERFACE:
				return type_any;
			case ANYFAULT:
			case TYPEID:
				return type_uptr.canonical;
			case BITSTRUCT:
				type = type.decl.strukt.container_type.type;
				continue;
			case WILDCARD:
				type = type_void;
				continue;
			case POINTER:
				Type* pointer = type.pointer;
				Type* flat = type_lowering_abi(pointer);
				if (flat == pointer) return type;
				return type_get_ptr(flat);
			case SLICE:
			case ARRAY:
			case VECTOR:
			case FLEXIBLE_ARRAY:
			case SIMD_VECTOR:
				Type* flat = type_lowering_abi(type.array.base);
				switch (type.type_kind)
				{
					case SLICE:
						return type_get_slice(flat);
					case SIMD_VECTOR:
						return type_get_vector(flat, SIMD_VECTOR, (int)type.array.len);
					case ARRAY:
					case VECTOR:
						return type_get_array(flat, type.array.len);
					case FLEXIBLE_ARRAY:
						return type_get_flexible_array(flat);
					default:
						unreachable();
				}
			default:
				return type;
		}
	}
}

fn bool abi_type_match(AbiType type, Type* other_type)
{
	assert(other_type);
	other_type = other_type.canonical;
	if (type.abi_type & 0x01)
	{
		switch (type.abi_type)
		{
			case ABI_TYPE_INT_24:
			case ABI_TYPE_INT_40:
			case ABI_TYPE_INT_48:
			case ABI_TYPE_INT_56:
				return false;
			case ABI_TYPE_INT_VEC_2:
				return other_type == type_get_vector(type_uint, SIMD_VECTOR, 2);
			case ABI_TYPE_INT_VEC_4:
				return other_type == type_get_vector(type_uint, SIMD_VECTOR, 4);
			case ABI_TYPE_FLOAT_VEC_2:
				return other_type == type_get_vector(type_float, SIMD_VECTOR, 2);
			case ABI_TYPE_FLOAT_VEC_4:
				return other_type == type_get_vector(type_float, SIMD_VECTOR, 4);
			case ABI_TYPE_FLOAT16_VEC_2:
				return other_type == type_get_vector(type_float16, SIMD_VECTOR, 2);
			case ABI_TYPE_FLOAT16_VEC_4:
				return other_type == type_get_vector(type_float16, SIMD_VECTOR, 4);
			case ABI_TYPE_BFLOAT16_VEC_2:
				return other_type == type_get_vector(type_bfloat, SIMD_VECTOR, 2);
			case ABI_TYPE_BFLOAT16_VEC_4:
				return other_type == type_get_vector(type_bfloat, SIMD_VECTOR, 4);
			case ABI_TYPE_LONG_VEC_2:
				return other_type == type_get_vector(type_ulong, SIMD_VECTOR, 2);
			case ABI_TYPE_DOUBLE_VEC_2:
				return other_type == type_get_vector(type_double, SIMD_VECTOR, 2);
			case ABI_TYPE_DOUBLE_VEC_4:
				return other_type == type_get_vector(type_double, SIMD_VECTOR, 4);
			case ABI_TYPE_DOUBLE_VEC_8:
				return other_type == type_get_vector(type_double, SIMD_VECTOR, 8);
		}
		unreachable();
	}
	return type.type == other_type.canonical;
}

fn bool abi_type_is_integer(AbiType type) @inline
{
	return !abi_type_is_type(type) || type_is_integer(type.type);
}

fn bool abi_type_is_float(AbiType type) @inline
{
	return abi_type_is_type(type) && type_is_float(type.type);
}

fn bool abi_type_is_type(AbiType type) @inline
{
	return !(type.abi_type & 0x01);
}

fn bool abi_type_is_valid(AbiType type) @inline
{
	return type.abi_type != 0;
}

fn bool expr_is_vector_index_or_swizzle(Expr* expr)
{
	return (expr.expr_kind == SUBSCRIPT && type_kind_is_real_vector(type_lowering(exprtype(expr.subscript_expr.expr)).type_kind))
	       || (expr.expr_kind == SWIZZLE && type_kind_is_real_vector(type_lowering(exprtype(expr.swizzle_expr.parent)).type_kind));
}

fn Type* lowered_member_type(Decl* member) @inline
{
	return type_lowering_abi(member.type);
}

fn Type* lowered_array_element_type(Type* array_type) @inline
{
	return type_lowering_abi(array_type.array.base);
}

// ---------------------------------------------------------------------------
// c_abi_internal.h

fn AbiType abi_type_get(Type* type) @inline
{
	return { .type = type };
}

fn AbiType abi_type_spec(AbiSpecType type) @inline
{
	return { .abi_type = type };
}

fn AbiType abi_type_get_int_bits(BitSize bits)
{
	switch (bits)
	{
		case 24:
			return { .abi_type = ABI_TYPE_INT_24 };
		case 40:
			return { .abi_type = ABI_TYPE_INT_40 };
		case 48:
			return { .abi_type = ABI_TYPE_INT_48 };
		case 56:
			return { .abi_type = ABI_TYPE_INT_56 };
		case 8:
		case 16:
		case 32:
		case 64:
		case 128:
			return { .type = type_int_unsigned_by_bitsize((uint)bits) };
		default:
			unreachable();
	}
}

fn void abi_type_set_type(AbiType* abi_type, Type* type) @inline
{
	abi_type.type = type;
}

// ---------------------------------------------------------------------------
// codegen_general.c

<* Based on isSingleElementStruct in Clang *>
fn Type* type_abi_find_single_struct_element(Type* type, bool in_abi)
{
	if (!type_is_union_or_strukt(type)) return null;

	// Elements with a variable array? If so no.
	if (type.decl.has_variable_array) return null;

	Type* found = null;
	foreach (member : type.decl.strukt.members)
	{
		// Already one field found, not single field.
		if (found) return null;

		Type* field_type = type_lowering(member.type);

		// Flatten single element arrays.
		while (field_type.type_kind == ARRAY)
		{
			if (field_type.array.len != 1) break;
			field_type = field_type.array.base;
		}

		if (type_is_union_or_strukt(field_type))
		{
			field_type = type_abi_find_single_struct_element(field_type, in_abi);
			if (!field_type) return null;
		}
		found = field_type;
	}
	// If there is some padding? Then ignore.
	if (found && type_size(type) != type_size(found)) found = null;
	return found;
}

// codegen_general.c:45 (static)
fn bool type_is_homogenous_base_type(Type* type)
{
	type = type.canonical;
	switch (compiler.platform.abi)
	{
		case PPC64_SVR4:
			switch (type.type_kind)
			{
				case F128:
					if (!compiler.platform.float128_supported) return false;
					nextcase;
				case F32:
				case F64:
					return !compiler.platform.ppc64.is_softfp;
				case SIMD_VECTOR:
					return type_size(type) == 128 / 8;
				default:
					return false;
			}
		case X64:
		case WIN64:
		case X86:
			switch (type.type_kind)
			{
				case F64:
				case F32:
					return true;
				case SIMD_VECTOR:
					switch (type_size(type))
					{
						case 16:
						case 32:
						case 64:
							// vec128 256 512 ok
							return true;
						default:
							return false;
					}
				default:
					return false;
			}
		case AARCH64:
			switch (type.type_kind)
			{
				case BF16:
				case F16:
				case F32:
				case F64:
				case F128:
					return true;
				case SIMD_VECTOR:
					switch (type_size(type))
					{
						case 8:
						case 16:
							// vector 64, 128 => true
							return true;
						default:
							return false;
					}
				default:
					return false;
			}
		case ARM:
			switch (type.type_kind)
			{
				case F32:
				case F64:
				case F128:
					return true;
				case SIMD_VECTOR:
					switch (type_size(type))
					{
						case 8:
						case 16:
							return true;
						default:
							break;
					}
					// c3c: FALLTHROUGH into default.
					return false;
				default:
					return false;
			}
		case UNKNOWN:
		case WASM:
		case PPC32:
		case RISCV:
		case AVR:
		case XTENSA:
			return false;
	}
}

// codegen_general.c:136 (static)
fn bool type_homogenous_aggregate_small_enough(Type* type, int members)
{
	switch (compiler.platform.abi)
	{
		case PPC64_SVR4:
			if (type.type_kind == F128 && compiler.platform.float128_supported) return members <= 8;
			if (type.type_kind == SIMD_VECTOR) return members <= 8;
			// Use max 8 registers.
			return ((type_size(type) + 7) / 8) * members <= 8;
		case X64:
		case WIN64:
		case X86:
		case AARCH64:
		case ARM:
			return members <= 4;
		case UNKNOWN:
		case WASM:
		case PPC32:
		case RISCV:
		case AVR:
		case XTENSA:
			return false;
	}
}

// codegen_general.c:171
<*
 Calculate whether this is a homogeneous aggregate for the ABI.
 Based on bool ABIInfo::isHomogeneousAggregate in Clang.
 (c3c's `goto TYPECHECK` is the shared tail repeated in the struct / array
 cases.)
 @param type : "the (flattened) type to check."
 @param base : "the base type of the aggregate"
 @param elements : "the elements found"
 @return "true if it is an aggregate, false otherwise."
*>
fn bool type_is_homogeneous_aggregate(LoweredType* type, Type** base, int* elements)
{
	assert(base && type && elements);
	*elements = 0;
	switch (type.type_kind)
	{
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
			unreachable();
		case VECTOR:
			// Converted in ABI
			unreachable();
		case VOID:
		case FUNC_RAW:
		case SLICE:
			return false;
		case ANY:
			*base = type_uptr.canonical;
			*elements = 2;
			return true;
		case STRUCT:
		case UNION:
			if (type.decl.has_variable_array) return false;
			*elements = 0;
			foreach (member : type.decl.strukt.members)
			{
				int member_mult = 1;
				// Flatten the type.
				LoweredType* member_type = lowered_member_type(member);
				// Go down deep into  a nester array.
				while (member_type.type_kind == ARRAY)
				{
					assert(member_type.array.len, "Zero length arrays not allowed");
					member_mult *= (int)member_type.array.len;
					member_type = member_type.array.base;
				}
				int member_members = 0;

				// Check recursively if the field member is homogeneous
				if (!type_is_homogeneous_aggregate(member_type, base, &member_members)) return false;
				member_members *= member_mult;
				// In the case of a union, grab the bigger set of elements.
				if (type.type_kind == UNION)
				{
					*elements = max(*elements, member_members);
				}
				else
				{
					*elements += member_members;
				}
			}
			assert(base);
			if (!*base) return false;

			// Ensure no padding
			if (type_size(*base) * *elements != type_size(type)) return false;
			// TYPECHECK:
			if (*elements == 0) return false;
			return type_homogenous_aggregate_small_enough(type, *elements);
		case FLEXIBLE_ARRAY:
			// Same with scaled vectors
			return false;
		case ARRAY:
			// Empty arrays? Not homogeneous.
			if (type.array.len == 0) return false;
			// Check the underlying type and multiply by length.
			if (!type_is_homogeneous_aggregate(lowered_array_element_type(type), base, elements)) return false;
			*elements *= (int)type.array.len;
			// TYPECHECK:
			if (*elements == 0) return false;
			return type_homogenous_aggregate_small_enough(type, *elements);
		case BOOL:
			// Lower bool to unsigned char
			type = type_char;
		case I8:
		case I16:
		case I32:
		case I64:
		case I128:
			// Lower signed to unsigned
			type = type_int_unsigned_by_bitsize(type.builtin.bitsize);
		case U8:
		case U16:
		case U32:
		case U64:
		case U128:
		case BF16:
		case F16:
		case F32:
		case F64:
		case F128:
		case SIMD_VECTOR:
			break;
		case POINTER:
		case FUNC_PTR:
			// All pointers are the same.
			type = type_voidptr;
	}
	// The common case:
	*elements = 1;
	// Is it a valid base type?
	if (!type_is_homogenous_base_type(type)) return false;
	// If we don't have a base type yet, set it.
	if (!*base)
	{
		*base = type;
		// Special handling of non-power-of-2 vectors (disabled in c3c).
	}
	// One is vector - other isn't => failure
	if (((*base).type_kind == SIMD_VECTOR) != (type.type_kind == SIMD_VECTOR)) return false;

	// Size does not match => failure
	if (type_size(*base) != type_size(type)) return false;

	// TYPECHECK:
	if (*elements == 0) return false;
	return type_homogenous_aggregate_small_enough(type, *elements);
}
