// Port of c3c src/compiler/types.c (builtin type globals, type_setup, the type
// caches behind type_get_ptr / slice / array / optional / vector, sizes and
// alignments, error-string rendering) plus the Type inline helpers of
// compiler_internal.h (type_new, type_is_*, type_flatten, ...).
//
// Not ported yet (sema): type_find_max_type and friends, the equivalence /
// pointer-equivalence checks, introspection mangling, type_is_subtype
// (needs FunctionPrototype), type_get_resolved_prototype, type_func_match,
// type_is_must_init, type_is_comparable / ordered, type_base_module.
//
// Deviations from c3c:
// - `goto RETRY` loops are `while (true)` loops.
// - TypeKind arithmetic (`kind + (TYPE_U8 - TYPE_I8)`) goes through `.ordinal`.
// - `str_printf` names use `%d` for c3c's `%llu`.
// - `types_reset()` (tests) clears the builtin types and caches.
// - Members of c3c's `t` named after C3 types/keywords get a `_` suffix
//   (`t.usz_`, `t.typeid_`, `t.any_`, ...).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

<* utils/common.h MAX_ARRAY_SIZE. *>
const ByteSize MAX_ARRAY_SIZE = (ByteSize)0x40000000;
const int ALIGN_SIZE_MAX = int::max;

struct BuiltinTypes
{
	Type u0, u1, i8, i16, i32, i64, i128;
	Type u8, u16, u32, u64, u128;
	Type bf16, f16, f32, f64, f128;
	Type usz_, sz_, uptr_, iptr_;
	Type string;
	Type voidstar, typeid_, fault_, member, reflection, typeinfo, untypedlist_;
	Type any_, wildcard;
}

<* c3c's static `t`. *>
BuiltinTypes t;

Type* type_bool = &t.u1;
Type* type_void = &t.u0;
Type* type_voidptr = &t.voidstar;
Type* type_float16 = &t.f16;
Type* type_bfloat = &t.bf16;
Type* type_float = &t.f32;
Type* type_double = &t.f64;
Type* type_f128 = &t.f128;
Type* type_typeid = &t.typeid_;
Type* type_any = &t.any_;
Type* type_typeinfo = &t.typeinfo;
Type* type_ichar = &t.i8;
Type* type_short = &t.i16;
Type* type_int = &t.i32;
Type* type_long = &t.i64;
Type* type_i128 = &t.i128;
Type* type_iptr = &t.iptr_;
Type* type_sz = &t.sz_;
Type* type_char = &t.u8;
Type* type_ushort = &t.u16;
Type* type_uint = &t.u32;
Type* type_ulong = &t.u64;
Type* type_u128 = &t.u128;
Type* type_uptr = &t.uptr_;
Type* type_usz = &t.usz_;
Type* type_fault = &t.fault_;
Type* type_untypedlist = &t.untypedlist_;
Type* type_wildcard = &t.wildcard;
Type* type_member = &t.member;
Type* type_reflection = &t.reflection;
Type* type_chars = null;
Type* type_wildcard_optional = null;
Type* type_string = &t.string;
Type* type_cint;
Type* type_cuint;

int size_slice;
AlignSize alignment_slice;
AlignSize max_alignment_vector;

const int PTR_OFFSET = 0;
const int INFERRED_ARRAY_OFFSET = 1;
const int FLEXIBLE_ARRAY_OFFSET = 2;
const int SLICE_OFFSET = 3;
const int INFERRED_VECTOR_OFFSET = 4;
const int OPTIONAL_OFFSET = 5;
const int ARRAY_OFFSET = 6;

<* Clear the builtin types (tests); `type_setup` fills them again. *>
fn void types_reset()
{
	t = {};
	type_chars = null;
	type_wildcard_optional = null;
	type_string = &t.string;
	type_cint = null;
	type_cuint = null;
	size_slice = 0;
	alignment_slice = 0;
	max_alignment_vector = 0;
}

fn void type_init_cint()
{
	type_cint = type_int_signed_by_bitsize(compiler.platform.width_c_int);
	type_cuint = type_int_unsigned_by_bitsize(compiler.platform.width_c_int);
}

fn Type* type_int_signed_by_bitsize(BitSize bitsize)
{
	switch (bitsize)
	{
		case 8: return type_ichar;
		case 16: return type_short;
		case 32: return type_int;
		case 64: return type_long;
		case 128: return type_i128;
		default: abort("Illegal bitsize %d", bitsize);
	}
}

fn Type* type_int_unsigned_by_bitsize(BitSize bit_size)
{
	switch (bit_size)
	{
		case 8: return type_char;
		case 16: return type_ushort;
		case 32: return type_uint;
		case 64: return type_ulong;
		case 128: return type_u128;
		default: abort("Illegal bitsize");
	}
}

fn String type_quoted_error_string_maybe_with_path(Type* type, Type* other_type)
{
	if (!str_eq(type_no_optional(type).name, type_no_optional(other_type).name)) return type_quoted_error_string(type);
	return type_quoted_error_string_with_path(type);
}

fn String type_error_string_maybe_with_path(Type* type, Type* other_type)
{
	if (!str_eq(type_no_optional(type).name, type_no_optional(other_type).name)) return type_to_error_string(type);
	return type_to_error_string_with_path(type);
}

fn String type_quoted_error_string(Type* type)
{
	if (type.canonical != type)
	{
		return @str_printf("'%s' (%s)", type_to_error_string(type), type_to_error_string(type.canonical));
	}
	return @str_printf("'%s'", type_to_error_string(type));
}

fn String type_quoted_error_string_with_path(Type* type)
{
	if (type.canonical != type)
	{
		return @str_printf("'%s' (%s)", type_to_error_string_with_path(type), type_to_error_string_with_path(type.canonical));
	}
	return @str_printf("'%s'", type_to_error_string_with_path(type));
}

fn void type_append_name_to_scratch(Type* type)
{
	type = type.canonical;
	switch (type.type_kind)
	{
		case POISONED:
		case ALIAS:
			unreachable();
		case STRUCT:
		case UNION:
		case BITSTRUCT:
			if (!type.decl.name.ptr)
			{
				scratch_buffer_append(type.name);
				break;
			}
			scratch_buffer_append(type.decl.name);
		case ENUM:
		case CONSTSET:
		case TYPEDEF:
		case INTERFACE:
			scratch_buffer_append(type.decl.name);
		case POINTER:
			type_append_name_to_scratch(type.pointer);
			scratch_buffer_append_char('*');
		case OPTIONAL:
			if (type.optional)
			{
				type_append_name_to_scratch(type.optional);
			}
			else
			{
				scratch_buffer_append("void");
			}
			scratch_buffer_append_char('?');
		case SLICE:
			type_append_name_to_scratch(type.array.base);
			scratch_buffer_append("[]");
		case FLEXIBLE_ARRAY:
			type_append_name_to_scratch(type.array.base);
			scratch_buffer_append("[*]");
		case VOID:
		case BOOL:
		case I8: case I16: case I32: case I64: case I128:
		case U8: case U16: case U32: case U64: case U128:
		case BF16: case F16: case F32: case F64: case F128:
		case TYPEID:
		case ANYFAULT:
		case ANY:
		case VECTOR: case INFERRED_VECTOR: case SIMD_VECTOR:
		case UNTYPEDLIST:
			scratch_buffer_append(type.name);
		case INFERRED_ARRAY:
		case TYPEINFO: case MEMBER: case REFLECTION:
		case WILDCARD:
			unreachable();
		case FUNC_PTR:
			type_append_func_to_scratch(type.pointer.function.signature);
		case FUNC_RAW:
			type_append_func_to_scratch(type.function.signature);
		case ARRAY:
			type_append_name_to_scratch(type.array.base);
			scratch_buffer_append_char('[');
			scratch_buffer_append_signed_int(type.array.len);
			scratch_buffer_append_char(']');
	}
}

fn void type_append_func_to_scratch(Signature* signature)
{
	type_append_name_to_scratch(typeget(signature.rtype));
	scratch_buffer_append_char('(');
	usz elements = signature.params.len;
	for (usz i = 0; i < elements; i++)
	{
		if (i > 0)
		{
			scratch_buffer_append_char(',');
		}
		type_append_name_to_scratch(signature.params[i].type);
	}
	if (signature.variadic == RAW)
	{
		if (elements > 0) scratch_buffer_append_char(',');
		scratch_buffer_append("...");
	}
	scratch_buffer_append_char(')');
}

fn bool type_is_inner_type(Type* type)
{
	switch (type.type_kind)
	{
		case STRUCT:
		case UNION:
		case BITSTRUCT:
			return type.decl.strukt.parent != 0;
		default:
			return false;
	}
}

fn void type_add_parent_to_scratch(Decl* decl)
{
	switch (decl.decl_kind)
	{
		case STRUCT:
		case UNION:
		case BITSTRUCT:
			if (decl.strukt.parent)
			{
				Decl* parent = declptr(decl.strukt.parent);
				type_add_parent_to_scratch(parent);
				if (!parent.name.ptr) return;
				scratch_buffer_append(parent.name);
				scratch_buffer_append_char('.');
			}
			return;
		default:
			return;
	}
}

fn String type_to_error_string(Type* type)
{
	switch (type.type_kind)
	{
		case POISONED:
			return "poisoned";
		case VOID:
		case BOOL:
		case I8: case I16: case I32: case I64: case I128:
		case U8: case U16: case U32: case U64: case U128:
		case BF16: case F16: case F32: case F64: case F128:
		case ANYFAULT:
		case UNTYPEDLIST:
		case ANY:
		case MEMBER:
		case REFLECTION:
		case WILDCARD:
			return type.name;
		case ENUM:
		case CONSTSET:
		case ALIAS:
		case STRUCT:
		case UNION:
		case TYPEDEF:
		case BITSTRUCT:
		case INTERFACE:
			Decl* decl = type.decl;
			if (!type_is_inner_type(type)) return type.name;
			scratch_buffer_clear();
			type_add_parent_to_scratch(decl);
			scratch_buffer_append(decl.name.ptr ? decl.name : "(anon)");
			return scratch_buffer_copy();
		case FUNC_PTR:
		case FUNC_RAW:
			if (type.type_kind == FUNC_PTR) type = type.pointer;
			if (!type.function.prototype) return type.name;
			scratch_buffer_clear();
			scratch_buffer_append("fn ");
			type_append_func_to_scratch(type.function.signature);
			return scratch_buffer_copy();
		case INFERRED_VECTOR:
			return @str_printf("%s[<*>]", type_to_error_string(type.array.base));
		case VECTOR:
			return @str_printf("%s[<%d>]", type_to_error_string(type.array.base), (ulong)type.array.len);
		case SIMD_VECTOR:
			return @str_printf("%s[<%d>] @simd", type_to_error_string(type.array.base), (ulong)type.array.len);
		case TYPEINFO:
			return "typeinfo";
		case TYPEID:
			return "typeid";
		case POINTER:
			return @str_printf("%s*", type_to_error_string(type.pointer));
		case OPTIONAL:
			if (!type.optional) return "void?";
			return @str_printf("%s?", type_to_error_string(type.optional));
		case ARRAY:
			return @str_printf("%s[%d]", type_to_error_string(type.array.base), (ulong)type.array.len);
		case INFERRED_ARRAY:
		case FLEXIBLE_ARRAY:
			return @str_printf("%s[*]", type_to_error_string(type.array.base));
		case SLICE:
			return @str_printf("%s[]", type_to_error_string(type.array.base));
	}
}

fn String type_to_error_string_with_path(Type* type)
{
	switch (type.type_kind)
	{
		case POISONED:
			return "poisoned";
		case VOID:
		case BOOL:
		case I8: case I16: case I32: case I64: case I128:
		case U8: case U16: case U32: case U64: case U128:
		case BF16: case F16: case F32: case F64: case F128:
		case ANYFAULT:
		case UNTYPEDLIST:
		case ANY:
		case MEMBER:
		case REFLECTION:
		case WILDCARD:
			return type.name;
		case ENUM:
		case CONSTSET:
		case ALIAS:
		case STRUCT:
		case UNION:
		case TYPEDEF:
		case BITSTRUCT:
		case INTERFACE:
			Decl* decl = type.decl;
			scratch_buffer_clear();
			scratch_buffer_append(decl.unit.mod.name.module_name);
			scratch_buffer_append("::");
			if (type_is_inner_type(type))
			{
				type_add_parent_to_scratch(decl);
			}
			scratch_buffer_append(decl.name);
			return scratch_buffer_copy();
		case FUNC_PTR:
		case FUNC_RAW:
			if (type.type_kind == FUNC_PTR) type = type.pointer;
			if (!type.function.prototype) return type.name;
			scratch_buffer_clear();
			scratch_buffer_append("fn ");
			type_append_func_to_scratch(type.function.signature);
			return scratch_buffer_copy();
		case INFERRED_VECTOR:
			return @str_printf("%s[<*>]", type_to_error_string_with_path(type.array.base));
		case VECTOR:
			return @str_printf("%s[<%d>]", type_to_error_string_with_path(type.array.base), (ulong)type.array.len);
		case SIMD_VECTOR:
			return @str_printf("%s[<%d>] @simd", type_to_error_string_with_path(type.array.base), (ulong)type.array.len);
		case TYPEINFO:
			return "typeinfo";
		case TYPEID:
			return "typeid";
		case POINTER:
			return @str_printf("%s*", type_to_error_string_with_path(type.pointer));
		case OPTIONAL:
			if (!type.optional) return "void?";
			return @str_printf("%s?", type_to_error_string_with_path(type.optional));
		case ARRAY:
			return @str_printf("%s[%d]", type_to_error_string_with_path(type.array.base), (ulong)type.array.len);
		case INFERRED_ARRAY:
		case FLEXIBLE_ARRAY:
			return @str_printf("%s[*]", type_to_error_string_with_path(type.array.base));
		case SLICE:
			return @str_printf("%s[]", type_to_error_string_with_path(type.array.base));
	}
}

fn bool type_is_matching_int(Type* type1, Type* type2)
{
	assert(type1.canonical == type1 && type2.canonical == type2);
	TypeKind typekind1 = type1.type_kind;
	TypeKind typekind2 = type2.type_kind;
	if (typekind1 == typekind2) return type_kind_is_any_integer(typekind1);
	usz delta = TypeKind.U8.ordinal - TypeKind.I8.ordinal;
	if (type_kind_is_signed(typekind1)) return typekind1.ordinal + delta == typekind2.ordinal;
	if (type_kind_is_unsigned(typekind1)) return typekind2.ordinal + delta == typekind1.ordinal;
	return false;
}

<* Only call after all types are resolved. *>
fn TypeSize type_size(Type* type)
{
	if (type.size != (TypeSize)~(ByteSize)0)
	{
		assert(type.size != 0 || type_flatten(type).type_kind == FLEXIBLE_ARRAY);
		return type.size;
	}
	switch (type.type_kind)
	{
		case BITSTRUCT:
			assert(type.decl.resolve_status == DONE);
			return type.size = type_size(type.decl.strukt.container_type.type);
		case TYPEDEF:
			assert(type.decl.resolve_status == DONE);
			return type.size = type_size(type.decl.distinct.type);
		case TYPEINFO: case INFERRED_ARRAY: case INFERRED_VECTOR: case POISONED: case MEMBER: case WILDCARD: case REFLECTION:
		case FUNC_RAW:
		case UNTYPEDLIST:
			unreachable();
		case FLEXIBLE_ARRAY:
			return type.size = 0;
		case OPTIONAL:
			return type.size = type_size(type.optional);
		case ALIAS:
			return type.size = type_size(type.canonical);
		case ENUM:
		case CONSTSET:
			assert(type.decl.enums.type_info.resolve_status == DONE);
			return type.size = type_size(enum_inner_type(type).canonical);
		case STRUCT:
		case UNION:
			assert(type.decl.resolve_status == DONE);
			return type.size = type.decl.strukt.size;
		case VOID:
			return type.size = 1;
		case BOOL:
		case TYPEID:
		case I8: case I16: case I32: case I64: case I128:
		case U8: case U16: case U32: case U64: case U128:
		case BF16: case F16: case F32: case F64: case F128:
		case ANYFAULT:
			// Always cached
			unreachable();
		case INTERFACE:
		case ANY:
			return type.size = t.uptr_.canonical.builtin.bytesize * 2;
		case FUNC_PTR:
		case POINTER:
			return type.size = t.uptr_.canonical.builtin.bytesize;
		case VECTOR: case SIMD_VECTOR:
		case ARRAY:
			if ((ByteSize)type_size(type.array.base) > (ByteSize)((long)MAX_ARRAY_SIZE / type.array.len)) return type.size = (TypeSize)MAX_ARRAY_SIZE + 1;
			return type.size = type_size(type.array.base) * (TypeSize)type.array.len;
		case SLICE:
			return type.size = size_slice;
	}
}

fn bool type_flat_is_numlike(Type* type)
{
	type = type_flatten(type);
	if (type_kind_is_real_vector(type.type_kind)) type = type_flatten(type.array.base);
	TypeKind kind = type.type_kind;
	return kind >= TYPE_NUM_FIRST && kind <= TYPE_NUM_LAST;
}

fn bool type_flat_is_floatlike(Type* type)
{
	type = type_flatten(type);
	if (type_kind_is_real_vector(type.type_kind)) type = type_flatten(type.array.base);
	TypeKind kind = type.type_kind;
	return kind >= TYPE_FLOAT_FIRST && kind <= TYPE_FLOAT_LAST;
}

fn bool type_flat_is_intlike(Type* type)
{
	type = type_flatten(type);
	if (type_kind_is_real_vector(type.type_kind)) type = type_flatten(type.array.base);
	TypeKind kind = type.type_kind;
	return kind >= TYPE_INTEGER_FIRST && kind <= TYPE_INTEGER_LAST;
}

fn bool type_flat_is_boolintlike(Type* type)
{
	type = type_flatten(type);
	if (type_kind_is_real_vector(type.type_kind)) type = type_flatten(type.array.base);
	TypeKind kind = type.type_kind;
	return kind == BOOL || (kind >= TYPE_INTEGER_FIRST && kind <= TYPE_INTEGER_LAST);
}

fn bool type_is_int128(Type* type)
{
	TypeKind kind = type.canonical.type_kind;
	return kind == U128 || kind == I128;
}

fn AlignSize type_alignment_(Type* type, bool alloca)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case POISONED:
			case UNTYPEDLIST:
			case TYPEINFO: case MEMBER: case REFLECTION:
			case WILDCARD:
				unreachable();
			case BITSTRUCT:
				if (type.decl.alignment) return type.decl.alignment;
				type = type.decl.strukt.container_type.type;
				continue;
			case INFERRED_VECTOR:
			case VECTOR:
				if (!alloca)
				{
					type = type.array.base.canonical;
					continue;
				}
				nextcase SIMD_VECTOR;
			case SIMD_VECTOR:
				ArrayIndex len = type.array.len;
				if (!len) len = 1;
				ByteSize width = (ByteSize)type_size(type.array.base) * (ByteSize)len;
				AlignSize alignment = (AlignSize)(int)width;
				if (max_alignment_vector && alignment > max_alignment_vector) return max_alignment_vector;
				if (!is_power_of_two((ulong)alignment))
				{
					alignment = (AlignSize)next_highest_power_of_2((uint)alignment);
				}
				return alignment;
			case VOID:
				return 1;
			case OPTIONAL:
				type = type.optional;
				continue;
			case TYPEDEF:
				if (type.decl.alignment) return type.decl.alignment;
				type = type.decl.distinct.type;
				continue;
			case ALIAS:
				type = type.canonical;
				continue;
			case ENUM:
			case CONSTSET:
				type = enum_inner_type(type).canonical;
				continue;
			case STRUCT:
			case UNION:
				assert(type.decl.resolve_status == DONE);
				return type.decl.alignment;
			case BOOL:
			case I8: case I16: case I32: case I64: case I128:
			case U8: case U16: case U32: case U64: case U128:
			case BF16: case F16: case F32: case F64: case F128:
			case ANYFAULT:
				return type.builtin.abi_alignment;
			case FUNC_RAW:
			case FUNC_PTR:
			case INTERFACE:
			case ANY:
			case POINTER:
			case TYPEID:
				return t.uptr_.canonical.builtin.abi_alignment;
			case ARRAY:
			case INFERRED_ARRAY:
			case FLEXIBLE_ARRAY:
				type = type.array.base.canonical;
				if (type.type_kind == VECTOR)
				{
					type = type.array.base;
				}
				continue;
			case SLICE:
				return alignment_slice;
		}
	}
}

fn AlignSize type_abi_alignment(Type* type) => type_alignment_(type, false);

fn void create_type_cache(Type* type)
{
	assert(type.type_cache.ptr == null);
	for (int i = 0; i < ARRAY_OFFSET; i++)
	{
		@vec_add(&type.type_cache, null);
	}
}

fn Type* type_generate_ptr(Type* ptr_type, bool canonical)
{
	if (canonical) ptr_type = ptr_type.canonical;
	if (!ptr_type.type_cache.ptr)
	{
		create_type_cache(ptr_type);
	}
	Type* ptr = ptr_type.type_cache[PTR_OFFSET];
	if (ptr == null)
	{
		ptr = type_new(POINTER, @str_printf("%s*", ptr_type.name));
		ptr.pointer = ptr_type;
		ptr_type.type_cache[PTR_OFFSET] = ptr;
		if (ptr_type == ptr_type.canonical)
		{
			ptr.canonical = ptr;
		}
		else
		{
			ptr.canonical = type_generate_ptr(ptr_type.canonical, true);
		}
	}
	return ptr;
}

fn Type* type_generate_optional(Type* optional_type, bool canonical)
{
	if (canonical) optional_type = optional_type.canonical;
	if (!optional_type.type_cache.ptr)
	{
		create_type_cache(optional_type);
	}
	Type* optional = optional_type.type_cache[OPTIONAL_OFFSET];
	if (optional == null)
	{
		optional = type_new(OPTIONAL, @str_printf("%s?", optional_type.name));
		optional.pointer = optional_type;
		optional_type.type_cache[OPTIONAL_OFFSET] = optional;
		if (optional_type == optional_type.canonical)
		{
			optional.canonical = optional;
		}
		else
		{
			optional.canonical = type_generate_optional(optional_type.canonical, true);
		}
	}
	return optional;
}

fn Type* type_generate_slice(Type* arr_type, bool canonical)
{
	if (canonical) arr_type = arr_type.canonical;
	if (!arr_type.type_cache.ptr)
	{
		create_type_cache(arr_type);
	}
	Type* arr = arr_type.type_cache[SLICE_OFFSET];
	if (arr == null)
	{
		arr = type_new(SLICE, @str_printf("%s[]", arr_type.name));
		arr.array.base = arr_type;
		arr_type.type_cache[SLICE_OFFSET] = arr;
		if (arr_type == arr_type.canonical)
		{
			arr.canonical = arr;
		}
		else
		{
			arr.canonical = type_generate_slice(arr_type.canonical, true);
		}
	}
	return arr;
}

fn Type* type_generate_inferred_array(Type* arr_type, bool canonical)
{
	if (canonical) arr_type = arr_type.canonical;
	if (!arr_type.type_cache.ptr)
	{
		create_type_cache(arr_type);
	}
	Type* arr = arr_type.type_cache[INFERRED_ARRAY_OFFSET];
	if (arr == null)
	{
		arr = type_new(INFERRED_ARRAY, @str_printf("%s[*]", arr_type.name));
		arr.array.base = arr_type;
		arr_type.type_cache[INFERRED_ARRAY_OFFSET] = arr;
		if (arr_type == arr_type.canonical)
		{
			arr.canonical = arr;
		}
		else
		{
			arr.canonical = type_generate_inferred_array(arr_type.canonical, true);
		}
	}
	return arr;
}

fn Type* type_generate_inferred_vector(Type* arr_type, bool canonical)
{
	if (canonical) arr_type = arr_type.canonical;
	if (!arr_type.type_cache.ptr)
	{
		create_type_cache(arr_type);
	}
	Type* arr = arr_type.type_cache[INFERRED_VECTOR_OFFSET];
	if (arr == null)
	{
		arr = type_new(INFERRED_VECTOR, @str_printf("%s[<*>]", arr_type.name));
		arr.array.base = arr_type;
		arr_type.type_cache[INFERRED_VECTOR_OFFSET] = arr;
		if (arr_type == arr_type.canonical)
		{
			arr.canonical = arr;
		}
		else
		{
			arr.canonical = type_generate_inferred_vector(arr_type.canonical, true);
		}
	}
	return arr;
}

fn Type* type_generate_flexible_array(Type* arr_type, bool canonical)
{
	if (canonical) arr_type = arr_type.canonical;
	if (!arr_type.type_cache.ptr)
	{
		create_type_cache(arr_type);
	}
	Type* arr = arr_type.type_cache[FLEXIBLE_ARRAY_OFFSET];
	if (arr == null)
	{
		arr = type_new(FLEXIBLE_ARRAY, @str_printf("%s[*]", arr_type.name));
		arr.array.base = arr_type;
		arr.array.len = 0;
		arr_type.type_cache[FLEXIBLE_ARRAY_OFFSET] = arr;
		if (arr_type == arr_type.canonical)
		{
			arr.canonical = arr;
		}
		else
		{
			arr.canonical = type_generate_flexible_array(arr_type.canonical, true);
		}
	}
	return arr;
}

fn Type* type_get_ptr_recurse(Type* ptr_type)
{
	if (ptr_type.type_kind == OPTIONAL)
	{
		ptr_type = ptr_type.optional;
		return type_get_optional(type_get_ptr(ptr_type));
	}
	return type_get_ptr(ptr_type);
}

fn Type* type_get_ptr(Type* ptr_type)
{
	assert(ptr_type.type_kind != FUNC_RAW);
	assert(ptr_type.type_kind != UNTYPEDLIST);
	assert(!type_is_optional(ptr_type));
	return type_generate_ptr(ptr_type, false);
}

fn Type* type_get_func_ptr(Type* func_type)
{
	assert(func_type.type_kind == FUNC_RAW);
	if (func_type.func_ptr) return func_type.func_ptr;
	Type* type = func_type.func_ptr = type_new(FUNC_PTR, func_type.name);
	type.pointer = func_type;
	type.canonical = type;
	return type;
}

fn Type* type_get_optional(Type* optional_type)
{
	assert(!type_is_optional(optional_type));
	return type_generate_optional(optional_type, false);
}

fn Type* type_get_slice(Type* arr_type)
{
	assert(type_is_valid_for_array(arr_type));
	return type_generate_slice(arr_type, false);
}

fn Type* type_get_inferred_array(Type* arr_type)
{
	assert(type_is_valid_for_array(arr_type));
	return type_generate_inferred_array(arr_type, false);
}

fn Type* type_get_inferred_vector(Type* arr_type)
{
	assert(type_is_valid_for_array(arr_type));
	return type_generate_inferred_vector(arr_type, false);
}

fn AlignSize type_alloca_alignment(Type* type)
{
	AlignSize align = type_alignment_(type, true);
	if (align < 16 && (compiler.platform.abi == X64 || compiler.platform.abi == WIN64))
	{
		type = type_flatten(type);
		if (type.type_kind == ARRAY && type_size(type) >= 16) return 16;
	}
	return align;
}

fn Type* type_get_flexible_array(Type* arr_type)
{
	assert(type_is_valid_for_array(arr_type));
	return type_generate_flexible_array(arr_type, false);
}

fn Type* type_get_indexed_type(Type* type)
{
	while (true)
	{
		if (type == type_voidptr) return null;
		switch (type.type_kind)
		{
			case POINTER:
				return type.pointer;
			case ARRAY:
			case SLICE:
			case INFERRED_ARRAY:
			case INFERRED_VECTOR:
			case FLEXIBLE_ARRAY:
			case VECTOR: case SIMD_VECTOR:
				return type.array.base;
			case CONSTSET:
				type = enum_inner_type(type);
			case TYPEDEF:
				type = type.decl.distinct.type;
			case OPTIONAL:
				type = type.optional;
			case ALIAS:
				type = type.canonical;
			default:
				return null;
		}
	}
}

fn Type* type_create_array(Type* element_type, ArrayIndex len, TypeKind kind, bool canonical)
{
	if (canonical) element_type = element_type.canonical;
	if (!element_type.type_cache.ptr)
	{
		create_type_cache(element_type);
	}
	usz entries = element_type.type_cache.len;
	for (usz i = ARRAY_OFFSET; i < entries; i++)
	{
		Type* ptr_vec = element_type.type_cache[i];
		if (ptr_vec.type_kind != kind) continue;
		if (ptr_vec.array.len == len) return ptr_vec;
	}
	Type* vec_arr;
	switch (kind)
	{
		case ARRAY:
			vec_arr = type_new(ARRAY, @str_printf("%s[%d]", element_type.name, (ulong)len));
			vec_arr.array.base = element_type;
			vec_arr.array.len = len;
		case VECTOR:
			vec_arr = type_new(kind, @str_printf("%s[<%d>]", element_type.name, (ulong)len));
			vec_arr.array.base = element_type;
			vec_arr.array.len = len;
		case SIMD_VECTOR:
			vec_arr = type_new(kind, @str_printf("%s[<%d>] @simd", element_type.name, (ulong)len));
			vec_arr.array.base = element_type;
			vec_arr.array.len = len;
		default:
			unreachable();
	}
	if (element_type.canonical == element_type)
	{
		vec_arr.canonical = vec_arr;
	}
	else
	{
		vec_arr.canonical = type_create_array(element_type, len, kind, true);
	}
	@vec_add(&element_type.type_cache, vec_arr);
	return vec_arr;
}

fn Type* type_array_from_vector(Type* vec_type)
{
	assert(type_kind_is_real_vector(vec_type.type_kind));
	return type_get_array(vec_type.array.base, vec_type.array.len);
}

fn Type* type_vector_from_array(Type* vec_type)
{
	assert(vec_type.type_kind == ARRAY);
	return type_get_vector(vec_type.array.base, VECTOR, (int)vec_type.array.len);
}

fn Type* type_get_array(Type* arr_type, ArrayIndex len)
{
	assert(len > 0, "Created a zero length array");
	assert(type_is_valid_for_array(arr_type));
	return type_create_array(arr_type, len, ARRAY, false);
}

fn bool type_is_valid_for_vector(Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case I8: case I16: case I32: case I64: case I128:
			case U8: case U16: case U32: case U64: case U128:
			case BF16: case F16: case F32: case F64: case F128:
			case BOOL:
			case POINTER:
			case ENUM:
			case TYPEID:
			case ANYFAULT:
				return true;
			case TYPEDEF:
				assert(type.decl.resolve_status == DONE);
				type = type.decl.distinct.type;
			case ALIAS:
				type = type.canonical;
			default:
				return false;
		}
	}
}

fn bool type_is_valid_for_array(Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case TYPEDEF:
				assert(type.decl.resolve_status == DONE);
				type = type.decl.distinct.type;
			case ANY:
			case INTERFACE:
			case ANYFAULT:
			case TYPEID:
			case POINTER:
			case ENUM:
			case CONSTSET:
			case FUNC_PTR:
			case FUNC_RAW:
			case STRUCT:
			case UNION:
			case BITSTRUCT:
			case I8: case I16: case I32: case I64: case I128:
			case U8: case U16: case U32: case U64: case U128:
			case BF16: case F16: case F32: case F64: case F128:
			case BOOL:
			case ARRAY:
			case SLICE:
			case VECTOR: case SIMD_VECTOR:
				return true;
			case ALIAS:
				assert(type.decl.resolve_status == DONE);
				type = type.canonical;
			case FLEXIBLE_ARRAY:
			case INFERRED_ARRAY:
			case INFERRED_VECTOR:
				type = type.array.base;
			case OPTIONAL:
			case WILDCARD:
			case POISONED:
			case UNTYPEDLIST:
			case VOID:
			case TYPEINFO: case MEMBER: case REFLECTION:
				return false;
		}
	}
}

fn Type* type_get_vector_bool(Type* original_type, TypeKind kind)
{
	Type* type = type_flatten(original_type);
	ByteSize size = (ByteSize)type_size(type.array.base);
	return type_get_vector(type_int_signed_by_bitsize((BitSize)((int)size * 8)), kind, (int)original_type.array.len);
}

fn Type* type_get_vector_from_vector(Type* base_type, Type* orginal_vector)
{
	assert(type_kind_is_real_vector(orginal_vector.type_kind));
	bool opt = type_is_optional(base_type);
	if (opt) base_type = type_no_optional(base_type);
	Type* res = type_get_vector(base_type, orginal_vector.type_kind, (int)orginal_vector.array.len);
	if (opt) res = type_get_optional(res);
	return res;
}

fn Type* type_get_simd_from_vector(Type* orginal_vector)
{
	assert(orginal_vector.type_kind == VECTOR);
	return type_get_vector(orginal_vector.array.base, SIMD_VECTOR, (int)orginal_vector.array.len);
}

fn Type* type_get_vector(Type* vector_type, TypeKind kind, int len)
{
	assert(type_kind_is_real_vector(kind) && type_is_valid_for_vector(vector_type));
	return type_create_array(vector_type, len, kind, false);
}

fn void type_create(String name, Type* location, TypeKind kind, int bitsize, int align, int pref_align)
{
	assert(align != 0);
	int byte_size = (bitsize + 7) / 8;
	*location = {
		.type_kind = kind,
		.size = byte_size,
		.builtin.bytesize = (char)byte_size,
		.builtin.bitsize = (char)bitsize,
		.builtin.abi_alignment = (char)align,
		.builtin.pref_alignment = (char)(pref_align ? pref_align : align),
		.name = name,
		.canonical = location,
	};
	global_context_add_type(location);
}

fn void type_init(String name, Type* location, TypeKind kind, int bitsize, AlignData align)
{
	assert(align.align != 0);
	int byte_size = (bitsize + 7) / 8;
	*location = {
		.type_kind = kind,
		.size = byte_size,
		.builtin.bytesize = (char)byte_size,
		.builtin.bitsize = (char)bitsize,
		.builtin.abi_alignment = (char)(align.align / 8),
		.builtin.pref_alignment = (char)((align.pref_align ? align.pref_align : align.align) / 8),
		.name = name,
		.canonical = location,
	};
	global_context_add_type(location);
}

fn void type_create_alias(String name, Type* location, Type* canonical)
{
	Decl* decl = decl_new(TYPE_ALIAS, name, 0);
	decl.resolve_status = DONE;
	decl.type_alias_decl.type_expr = expr_new_const_typeid(0, canonical);
	decl.unit = compiler.context.core_unit;
	decl.is_export = true;
	*location = {
		.decl = decl,
		.size = (TypeSize)~(ByteSize)0,
		.type_kind = ALIAS,
		.name = name,
		.canonical = canonical
	};
	decl.type = location;
	global_context_add_type(location);
}

fn Type* type_new_func(Decl* decl, Signature* sig)
{
	Type* type = type_new(FUNC_RAW, decl.name);
	type.canonical = type;
	type.function.signature = sig;
	type.function.decl = decl;
	return type;
}

fn void type_init_int(String name, Type* type, TypeKind kind, BitSizes bits)
{
	int actual_bits = bits.ordinal ? (int)(8 << (bits.ordinal - 1)) : 1;
	type_init(name, type, kind, actual_bits, compiler.platform.integers[bits.ordinal]);
}

fn void type_create_float(String name, Type* type, TypeKind kind, BitSizes bits)
{
	int actual_bits = bits.ordinal ? (int)(8 << (bits.ordinal - 1)) : 1;
	type_init(name, type, kind, actual_bits, compiler.platform.floats[bits.ordinal]);
}

<* Assume names are already interned. *>
fn Type* type_create_struct(String name, Type*[] types, String[] names)
{
	Decl* decl = decl_new_with_type(symtab_preset(name, TYPE_IDENT), null, STRUCT);
	decl.extname = decl.name;
	AlignSize offset = 0;
	AlignSize max_align = 0;
	foreach (i, member_type : types)
	{
		Decl* member = decl_new_var(names[i], 0, type_info_new_base(member_type, 0), MEMBER);
		member.unit = compiler.context.core_unit;
		member.type = member_type;
		member.resolve_status = DONE;
		AlignSize align = type_abi_alignment(member_type);
		if (align > max_align) max_align = align;
		member.offset = aligned_offset(offset, align);
		offset = member.offset + type_size(member_type);
		member.alignment = align;
		@vec_add(&decl.strukt.members, member);
	}
	decl.strukt.size = aligned_offset(offset, max_align);
	decl.alignment = max_align;
	decl.is_weak = true;
	decl.resolve_status = DONE;
	unit_register_global_decl(compiler.context.core_unit, decl);
	return decl.type;
}

fn void type_setup(PlatformTarget* target)
{
	max_alignment_vector = (AlignSize)target.align_max_vector;

	type_create_float("float16", &t.f16, F16, BITS16);
	type_create_float("bfloat", &t.bf16, BF16, BITS16);
	type_create_float("float", &t.f32, F32, BITS32);
	type_create_float("double", &t.f64, F64, BITS64);
	type_create_float("float128", &t.f128, F128, BITS128);

	type_init_int("ichar", &t.i8, I8, BITS8);
	type_init_int("short", &t.i16, I16, BITS16);
	type_init_int("int", &t.i32, I32, BITS32);
	type_init_int("long", &t.i64, I64, BITS64);
	type_init_int("int128", &t.i128, I128, BITS128);

	type_init_int("bool", &t.u1, BOOL, BITS8);
	type_init_int("char", &t.u8, U8, BITS8);
	type_init_int("ushort", &t.u16, U16, BITS16);
	type_init_int("uint", &t.u32, U32, BITS32);
	type_init_int("ulong", &t.u64, U64, BITS64);
	type_init_int("uint128", &t.u128, U128, BITS128);

	type_init_int("void", &t.u0, VOID, BITS8);

	type_create("typeinfo", &t.typeinfo, TYPEINFO, 1, 1, 1);
	type_create("member_ref", &t.member, MEMBER, 1, 1, 1);
	type_create("reflection_ref", &t.reflection, REFLECTION, 1, 1, 1);
	type_create("untypedlist", &t.untypedlist_, UNTYPEDLIST, 1, 1, 1);
	type_create("void", &t.wildcard, WILDCARD, 1, 1, 1);
	type_init("typeid", &t.typeid_, TYPEID, target.width_pointer, target.align_pointer);
	type_init("void*", &t.voidstar, POINTER, target.width_pointer, target.align_pointer);
	create_type_cache(type_void);
	type_void.type_cache[0] = &t.voidstar;
	t.voidstar.pointer = type_void;
	type_create("any", &t.any_, ANY, target.width_pointer * 2, target.align_pointer.align, target.align_pointer.pref_align);

	type_create_alias("usz", &t.usz_, type_int_unsigned_by_bitsize(target.width_pointer));
	type_create_alias("sz", &t.sz_, type_int_signed_by_bitsize(target.width_pointer));
	type_create_alias("uptr", &t.uptr_, type_int_unsigned_by_bitsize(target.width_pointer));
	type_create_alias("iptr", &t.iptr_, type_int_signed_by_bitsize(target.width_pointer));

	AlignSize ptr_align = type_abi_alignment(&t.voidstar);
	AlignSize usz_align = type_abi_alignment(t.usz_.canonical);
	alignment_slice = ptr_align > usz_align ? ptr_align : usz_align;
	size_slice = (int)(alignment_slice * 2);
	type_init("fault", &t.fault_, ANYFAULT, target.width_pointer, target.align_pointer);
	type_chars = type_get_slice(type_char);
	type_wildcard_optional = type_get_optional(type_wildcard);
	Decl* string_decl = decl_new_with_type(symtab_preset("String", TYPE_IDENT), null, TYPEDEF);
	string_decl.resolved_attributes = true;
	string_decl.extname = string_decl.name;
	string_decl.is_substruct = true;
	string_decl.distinct = type_info_new_base(type_chars, 0);
	string_decl.alignment = target.align_pointer.align / 8;
	string_decl.attr_constinit = true;
	string_decl.resolve_status = DONE;
	type_string = string_decl.type;
	unit_register_global_decl(compiler.context.core_unit, string_decl);
}

fn int type_kind_bitsize(TypeKind kind)
{
	switch (kind)
	{
		case I8:
		case U8:
			return 8;
		case I16:
		case U16:
		case F16:
		case BF16:
			return 16;
		case I32:
		case U32:
		case F32:
			return 32;
		case I64:
		case U64:
		case F64:
			return 64;
		case I128:
		case U128:
		case F128:
			return 128;
		default:
			unreachable();
	}
}

fn bool type_is_scalar(Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case TYPEINFO: case INFERRED_ARRAY: case INFERRED_VECTOR: case POISONED: case MEMBER: case WILDCARD: case REFLECTION:
				unreachable();
			case VOID:
			case FUNC_RAW:
			case STRUCT:
			case UNION:
			case ARRAY:
			case SLICE:
			case VECTOR: case SIMD_VECTOR:
			case INTERFACE:
			case ANY:
			case FLEXIBLE_ARRAY:
			case UNTYPEDLIST:
				return false;
			case BOOL:
			case I8: case I16: case I32: case I64: case I128:
			case U8: case U16: case U32: case U64: case U128:
			case BF16: case F16: case F32: case F64: case F128:
			case TYPEID:
			case POINTER:
			case FUNC_PTR:
			case ENUM:
			case CONSTSET:
			case ANYFAULT:
				return true;
			case BITSTRUCT:
				type = type.decl.strukt.container_type.type;
			case TYPEDEF:
				type = type.decl.distinct.type;
			case OPTIONAL:
				type = type.optional;
				if (!type) return false;
			case ALIAS:
				type = type.canonical;
		}
	}
}

fn Type* type_find_parent_type(Type* type)
{
	assert(type.canonical != null);
	Decl* decl;
	switch (type.type_kind)
	{
		case CONSTSET:
			decl = type.decl;
			return decl.is_substruct ? decl.enums.type_info.type : null;
		case TYPEDEF:
			decl = type.decl;
			return decl.is_substruct ? decl.distinct.type : null;
		case STRUCT:
			decl = type.decl;
			return decl.is_substruct ? decl.strukt.members[0].type : null;
		default:
			return null;
	}
}

fn Type* type_from_token(TokenType type)
{
	switch (type)
	{
		case ANY: return type_any;
		case UNTYPEDLIST: return type_untypedlist;
		case FAULT: return type_fault;
		case VOID: return type_void;
		case BOOL: return type_bool;
		case CHAR: return type_char;
		case FLOAT16: return type_float16;
		case BFLOAT: return type_bfloat;
		case DOUBLE: return type_double;
		case FLOAT: return type_float;
		case FLOAT128: return type_f128;
		case INT128: return type_i128;
		case ICHAR: return type_ichar;
		case INT: return type_int;
		case IPTR: return type_iptr;
		case SZ: return type_sz;
		case LONG: return type_long;
		case SHORT: return type_short;
		case UINT128: return type_u128;
		case UINT: return type_uint;
		case ULONG: return type_ulong;
		case UPTR: return type_uptr;
		case USHORT: return type_ushort;
		case USZ: return type_usz;
		case TYPEID: return type_typeid;
		default: unreachable();
	}
}

fn bool type_may_have_sub_elements(Type* type)
{
	switch (type_flatten(type).type_kind)
	{
		case UNION:
		case STRUCT:
		case ENUM:
		case CONSTSET:
		case BITSTRUCT:
		case INTERFACE:
			return true;
		default:
			return false;
	}
}

// ---------------------------------------------------------------------------
// Inline helpers (compiler_internal.h)

fn Type* type_no_optional(Type* type)
{
	if (!type) return null;
	if (type.type_kind == OPTIONAL) return type.optional;
	return type;
}

fn bool type_is_pointer_sized_or_more(Type* type) => type_is_integer(type) && type_size(type) >= type_size(type_uptr);
fn bool type_is_pointer_sized(Type* type) => type_is_integer(type) && type_size(type) == type_size(type_uptr);

<* c3c DECL_TYPE_KIND_REAL. *>
fn TypeKind type_kind_real(Type* t_) @inline
{
	TypeKind k_ = t_.type_kind;
	if (k_ == ALIAS) k_ = t_.canonical.type_kind;
	return k_;
}

fn Type* type_add_optional(Type* type, bool make_optional)
{
	if (!make_optional || type.type_kind == OPTIONAL) return type;
	return type_get_optional(type);
}

fn Type* type_from_inferred(Type* flattened, Type* element_type, int count)
{
	switch (flattened.type_kind)
	{
		case POINTER:
			assert(count == 0);
			return type_get_ptr(element_type);
		case SIMD_VECTOR:
			assert(flattened.array.len == count);
			return type_get_vector(element_type, SIMD_VECTOR, count);
		case VECTOR:
			assert(flattened.array.len == count);
			return type_get_vector(element_type, VECTOR, count);
		case INFERRED_VECTOR:
			return type_get_vector(element_type, VECTOR, count);
		case ARRAY:
			assert(flattened.array.len == count);
			return type_get_array(element_type, count);
		case INFERRED_ARRAY:
			return type_get_array(element_type, count);
		default:
			unreachable();
	}
}

fn bool type_len_is_inferred(Type* type)
{
	if (!type) return true;
	while (true)
	{
		switch (type.type_kind)
		{
			case ALIAS:
				type = type.canonical;
			case OPTIONAL:
				type = type.optional;
			case ARRAY:
			case SLICE:
			case VECTOR: case SIMD_VECTOR:
				type = type.array.base;
			case INFERRED_ARRAY:
			case INFERRED_VECTOR:
				return true;
			case POINTER:
				type = type.pointer;
				if (type.canonical.type_kind == FLEXIBLE_ARRAY) return false;
			default:
				return false;
		}
	}
}

fn bool type_is_wildcard(Type* type) => type == type_wildcard || type == type_wildcard_optional;

fn bool type_is_any_raw(Type* type)
{
	switch (type.type_kind)
	{
		case ANY:
		case INTERFACE:
			return true;
		default:
			return false;
	}
}

fn bool type_is_any(Type* type) => type.canonical == type_any;

fn bool type_is_optional(Type* type)
{
	if (!type) return false;
	return type_kind_real(type) == OPTIONAL;
}

fn bool type_may_implement_interface(Type* type)
{
	switch (type_kind_real(type))
	{
		case STRUCT:
		case UNION:
		case ENUM:
		case CONSTSET:
		case TYPEDEF:
		case BITSTRUCT:
			return true;
		default:
			return false;
	}
}

fn bool type_is_void(Type* type) => type.canonical == type_void;

fn bool type_is_integer(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= TYPE_INTEGER_FIRST && kind <= TYPE_INTEGER_LAST;
}

fn bool type_is_integer_signed(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= TYPE_INT_FIRST && kind <= TYPE_INT_LAST;
}

fn bool type_is_integer_or_bool_kind(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= BOOL && kind <= U128;
}

fn bool type_is_integer_unsigned(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= TYPE_UINT_FIRST && kind <= TYPE_UINT_LAST;
}

fn bool type_is_arraylike(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind == ARRAY || kind == VECTOR || kind == FLEXIBLE_ARRAY || kind == SIMD_VECTOR;
}

fn bool type_is_any_arraylike(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= TYPE_FIRST_ARRAYLIKE && kind <= TYPE_LAST_ARRAYLIKE;
}

fn Type* type_pointer_type(Type* type)
{
	Type* res = type.canonical;
	if (res.type_kind != POINTER) return null;
	return res.pointer;
}

fn bool type_is_pointer_like(Type* type)
{
	TypeKind kind = type.type_kind;
	if (kind == TYPEDEF)
	{
		type = type_flat_distinct_inline(type);
		kind = type.type_kind;
	}
	switch (kind)
	{
		case POINTER:
			return true;
		case VECTOR: case SIMD_VECTOR:
			return type_is_pointer_like(type.array.base.canonical);
		default:
			return false;
	}
}

fn bool type_is_pointer_vector(Type* type)
{
	return type_kind_is_real_vector(type.type_kind) && type.array.base.canonical.type_kind == POINTER;
}

fn bool type_is_atomic(Type* type_flat)
{
	switch (type_flat.type_kind)
	{
		case I8: case I16: case I32: case I64: case I128:
		case U8: case U16: case U32: case U64: case U128:
		case BF16: case F16: case F32: case F64: case F128:
		case ENUM:
		case CONSTSET:
		case ANYFAULT:
		case TYPEID:
		case BOOL:
			break;
		default:
			return false;
	}
	return type_size(type_flat) <= type_size(type_uptr);
}

fn bool type_is_pointer(Type* type) => type_kind_real(type) == POINTER;

fn bool type_is_pointer_type(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind == POINTER || kind == FUNC_PTR;
}

fn AlignSize aligned_offset(AlignSize offset, AlignSize alignment) => ((offset + alignment - 1) / alignment) * alignment;

fn bool type_is_substruct(Type* type) => type_kind_real(type) == STRUCT && type.decl.is_substruct;

fn bool type_may_negate(Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case VECTOR: case SIMD_VECTOR:
				type = type.array.base;
			case BF16: case F16: case F32: case F64: case F128:
			case I8: case I16: case I32: case I64: case I128:
			case U8: case U16: case U32: case U64: case U128:
				return true;
			case TYPEDEF:
				type = type.decl.distinct.type;
			case CONSTSET:
				type = type.decl.enums.type_info.type;
			case ALIAS:
				type = type.canonical;
			case OPTIONAL:
				type = type.optional;
			default:
				return false;
		}
	}
}

fn bool type_is_float(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= TYPE_FLOAT_FIRST && kind <= TYPE_FLOAT_LAST;
}

fn bool type_is_16bit_float(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind == BF16 || kind == F16;
}

fn bool type_is_floatlike(Type* type)
{
	type = type.canonical;
	TypeKind kind = type.type_kind;
	if (type_kind_is_real_vector(kind) && type_is_float(type.array.base)) return true;
	return kind >= TYPE_FLOAT_FIRST && kind <= TYPE_FLOAT_LAST;
}

fn String type_invalid_storage_type_name(Type* type)
{
	while (true)
	{
		type = type.canonical;
		switch (type.type_kind)
		{
			case REFLECTION:
				return "a reflection reference";
			case MEMBER:
				return "a member reference";
			case UNTYPEDLIST:
				return "an untyped list";
			case FUNC_RAW:
				return "a raw function type";
			case FLEXIBLE_ARRAY:
				return "a flexible array";
			case TYPEINFO:
				return "a typeinfo";
			case WILDCARD:
				return "an empty value";
			case OPTIONAL:
				return "an optional with a compile time type";
			case TYPEDEF:
				type = type_flatten(type);
				if (type == type_void) return "a type with unknown size";
			case VOID:
				return "'void'";
			default:
				unreachable();
		}
	}
}

fn Type* enum_inner_type(Type* enum_type)
{
	assert(enum_type.type_kind == ENUM || enum_type.type_kind == CONSTSET);
	return enum_type.decl.enums.type_info.type;
}

fn Type* type_new(TypeKind kind, String name)
{
	Type* type = calloc_arena(Type::size);
	type.type_kind = kind;
	type.size = (TypeSize)~(ByteSize)0;
	assert(name.ptr != null);
	type.name = name;
	global_context_add_type(type);
	return type;
}

fn bool type_convert_will_trunc(Type* destination, Type* source)
{
	assert(type_flat_is_vector(destination) || type_is_builtin(destination.canonical.type_kind));
	assert(type_flat_is_vector(destination) || type_is_builtin(source.canonical.type_kind));
	return type_size(destination) < type_size(source);
}

fn Type* type_flatten_for_bitstruct(Type* type)
{
	type = type.canonical;
	while (true)
	{
		while (type.type_kind == TYPEDEF)
		{
			type = type.decl.distinct.type;
		}
		if (type.type_kind == ENUM || type.type_kind == CONSTSET)
		{
			type = enum_inner_type(type).canonical;
			continue;
		}
		return type;
	}
}

fn Type* type_base(Type* type)
{
	while (true)
	{
		type = type.canonical;
		switch (type.type_kind)
		{
			case TYPEDEF:
				type = type.decl.distinct.type;
			case ENUM:
			case CONSTSET:
				type = enum_inner_type(type);
			case OPTIONAL:
				type = type.optional;
			case ALIAS:
				unreachable();
			default:
				return type;
		}
	}
}

fn bool typekind_is_distinct_like(TypeKind kind) => kind == CONSTSET || kind == TYPEDEF;

fn bool type_is_distinct_like(Type* type) => typekind_is_distinct_like(type.type_kind);

fn bool type_has_inline(Type* type) => typekind_is_distinct_like(type.type_kind) && type.decl.is_substruct;

fn Type* type_inline(Type* type)
{
	assert(type_is_distinct_like(type));
	return type.type_kind == TYPEDEF ? type.decl.distinct.type.canonical : type.decl.enums.type_info.type.canonical;
}

fn Type* type_flat_distinct_inline(Type* type)
{
	while (true)
	{
		type = type.canonical;
		if (!type_has_inline(type)) return type;
		type = type_inline(type);
	}
}

fn Type* type_vector_base(Type* type)
{
	return type_kind_is_real_vector(type.type_kind) ? type.array.base.canonical : type;
}

fn Type* type_flatten_and_inline(Type* type)
{
	while (true)
	{
		type = type.canonical;
		switch (type.type_kind)
		{
			case OPTIONAL:
				type = type.optional;
			case TYPEDEF:
				type = type.decl.distinct.type;
			case CONSTSET:
				type = type.decl.enums.type_info.type;
			default:
				return type;
		}
	}
}

fn Type* type_flat_distinct_enum_inline(Type* type)
{
	while (true)
	{
		type = type.canonical;
		Decl* decl;
		switch (type.type_kind)
		{
			case TYPEDEF:
				decl = type.decl;
				if (!decl.is_substruct) return type;
				type = decl.distinct.type;
			case CONSTSET:
				decl = type.decl;
				if (!decl.is_substruct) return type;
				type = decl.enums.type_info.type;
			default:
				return type;
		}
	}
}

fn bool type_is_user_defined(Type* type)
{
	switch (type.type_kind)
	{
		case ENUM:
		case CONSTSET:
		case STRUCT:
		case FUNC_RAW:
		case UNION:
		case TYPEDEF:
		case BITSTRUCT:
		case ALIAS:
		case INTERFACE:
			return true;
		default:
			return false;
	}
}

fn DeclId type_find_generic(Type* type)
{
	type = type_no_optional(type);
	Type* canonical = type.canonical;
	while (type.type_kind == POINTER)
	{
		type = type.pointer.canonical;
	}
	if (canonical != type && type_is_user_defined(canonical))
	{
		Decl* decl = canonical.decl;
		if (decl.is_templated) return decl.generic_id;
	}
	if (!type_is_user_defined(type)) return 0;
	Decl* decl = type.decl;
	return decl.is_templated ? decl.generic_id : 0;
}

fn Type* type_flatten_to_int(Type* type)
{
	while (true)
	{
		type = type.canonical;
		switch (type.type_kind)
		{
			case TYPEDEF:
				type = type.decl.distinct.type;
			case OPTIONAL:
				type = type.optional;
			case BITSTRUCT:
				type = type.decl.strukt.container_type.type;
			case CONSTSET:
				type = type.decl.enums.type_info.type;
			case ENUM:
				return type;
			case VECTOR: case SIMD_VECTOR:
				assert(type_is_integer(type.array.base));
				return type;
			case ALIAS:
				unreachable();
			default:
				assert(type_is_integer(type));
				return type;
		}
	}
}

fn Type* type_distinct_inline(Type* type)
{
	while (true)
	{
		type = type.canonical;
		switch (type.type_kind)
		{
			case CONSTSET:
				type = enum_inner_type(type);
			case TYPEDEF:
				type = type.decl.distinct.type;
			case OPTIONAL:
				type = type.optional;
			case ALIAS:
				unreachable();
			default:
				return type;
		}
	}
}

fn Type* type_flatten_once(Type* type)
{
	type = type.canonical;
	switch (type.type_kind)
	{
		case CONSTSET: return enum_inner_type(type).canonical;
		case TYPEDEF: return type.decl.distinct.type.canonical;
		case OPTIONAL: return type.optional.canonical;
		case ALIAS: unreachable();
		default: return type;
	}
}

fn Type* type_flatten(Type* type)
{
	while (true)
	{
		type = type.canonical;
		switch (type.type_kind)
		{
			case CONSTSET:
				type = enum_inner_type(type);
			case TYPEDEF:
				type = type.decl.distinct.type;
			case OPTIONAL:
				type = type.optional;
			case ALIAS:
				unreachable();
			default:
				return type;
		}
	}
}

fn Type* type_flatten_no_export(Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case ALIAS:
				if (type.decl.is_export) return type;
				type = type.canonical;
			case TYPEDEF:
				if (type.decl.is_export) return type;
				type = type.decl.distinct.type;
			case CONSTSET:
				if (type.decl.is_export) return type;
				type = enum_inner_type(type);
			case OPTIONAL:
				type = type.optional;
			default:
				return type;
		}
	}
}

fn Type* type_vector_type(Type* type)
{
	Type* flatten = type_flatten(type);
	return type_kind_is_real_vector(flatten.type_kind) ? flatten.array.base : null;
}

fn bool type_is_builtin(TypeKind kind) => kind >= VOID && kind <= TYPEID;
fn bool type_kind_is_signed(TypeKind kind) => kind >= I8 && kind < U8;
fn bool type_kind_is_unsigned(TypeKind kind) => kind >= U8 && kind <= U128;
fn bool type_kind_is_any_integer(TypeKind kind) => kind >= I8 && kind <= U128;
fn bool type_kind_is_enum_or_fault(TypeKind kind) => kind == ENUM || kind == ANYFAULT;
fn bool type_is_unsigned(Type* type) => type.type_kind >= U8 && type.type_kind <= U128;
fn bool type_is_signed(Type* type) => type.type_kind >= I8 && type.type_kind <= I128;
fn bool type_ok(Type* type) => !type || type.type_kind != POISONED;

fn bool type_is_signed_any(Type* type)
{
	TypeKind kind = type.type_kind;
	if (kind >= I8 && kind < U8) return true;
	if (!type_kind_is_real_vector(kind)) return false;
	kind = type.array.base.type_kind;
	return kind >= I8 && kind < U8;
}

fn bool type_is_func_ptr(Type* fn_type) => fn_type.canonical.type_kind == FUNC_PTR;

fn bool type_is_infer_type(Type* type)
{
	TypeKind kind = type.type_kind;
	return kind == INFERRED_VECTOR || kind == INFERRED_ARRAY;
}

fn bool type_is_inferred(Type* type)
{
	while (true)
	{
		switch (type.type_kind)
		{
			case INFERRED_ARRAY:
			case INFERRED_VECTOR:
				return true;
			case ARRAY:
				type = type.array.base.canonical;
			case POINTER:
				type = type.pointer.canonical;
			default:
				return false;
		}
	}
}

fn bool type_is_number_or_bool(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= BOOL && kind <= TYPE_FLOAT_LAST;
}

fn bool type_is_number(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind >= I8 && kind <= TYPE_FLOAT_LAST;
}

fn Type* type_flat_for_arithmethics(Type* type)
{
	while (true)
	{
		type = type.canonical;
		Type* inner;
		switch (type.type_kind)
		{
			case OPTIONAL:
				type = type.optional;
				continue;
			case CONSTSET:
			case TYPEDEF:
				inner = type_inline(type);
				if (type.decl.is_substruct)
				{
					type = inner;
					continue;
				}
			default:
				return type;
		}
		inner = type_flat_for_arithmethics(inner);
		if (type_is_number_or_bool(inner)) return inner;
		return type;
	}
}

fn bool type_is_numeric(Type* type)
{
	while (true)
	{
		TypeKind kind = type_kind_real(type);
		if (kind >= I8 && kind <= TYPE_FLOAT_LAST) return true;
		if (type_kind_is_real_vector(type.type_kind))
		{
			type = type.array.base;
			continue;
		}
		return false;
	}
}

fn bool type_underlying_is_numeric(Type* type) => type_is_numeric(type_flatten(type));

fn bool type_underlying_may_add_sub(Type* type) => type.type_kind == POINTER || type_is_numeric(type);

fn bool type_is_vec(Type* type)
{
	assert(type_flatten(type) == type);
	TypeKind kind = type.type_kind;
	return kind == VECTOR || kind == SIMD_VECTOR;
}

fn bool type_kind_is_real_vector(TypeKind kind) => kind == VECTOR || kind == SIMD_VECTOR;

fn bool type_flat_is_vector(Type* type) => type_kind_is_real_vector(type_flatten(type).type_kind);

fn bool type_flat_is_vector_bitstruct(Type* type)
{
	TypeKind kind = type_flatten(type).type_kind;
	return kind == VECTOR || kind == BITSTRUCT || kind == SIMD_VECTOR;
}

fn bool type_kind_is_any_non_simd_vector(TypeKind kind) => kind == VECTOR || kind == INFERRED_VECTOR;

fn bool type_kind_is_any_vector(TypeKind kind) => kind == VECTOR || kind == INFERRED_VECTOR || kind == SIMD_VECTOR;

fn bool type_flat_is_bool_vector(Type* type)
{
	Type* flat = type_flatten(type);
	return type_kind_is_real_vector(flat.type_kind) && type_flatten(flat.array.base) == type_bool;
}

fn bool type_is_union_or_strukt(Type* type)
{
	TypeKind kind = type_kind_real(type);
	return kind == UNION || kind == STRUCT;
}

fn bool type_is_promotable_int_bool(Type* type)
{
	// If we support other architectures, update this.
	return type_is_integer_or_bool_kind(type) && type.builtin.bitsize < compiler.platform.width_c_int;
}

fn bool type_is_promotable_float(Type* type)
{
	// If we support other architectures, update this.
	return type_is_float(type.canonical) && type.builtin.bytesize < type_double.builtin.bytesize;
}

<* Minimum alignment, values are either offsets or alignments. *>
fn AlignSize type_min_alignment(AlignSize a, AlignSize b)
{
	assert(a >= 0 && b >= 0);
	return (a | b) & (1 + ~(a | b));
}

<* Minimum alignment, safe for sizes of a that exceed AlignSize. *>
fn AlignSize type_min_alignment_size(ByteSize a, AlignSize b)
{
	if (a > (ByteSize)ALIGN_SIZE_MAX) a = (ByteSize)ALIGN_SIZE_MAX;
	return type_min_alignment((AlignSize)a, b);
}

<* Max highest required alignment *>
fn AlignSize type_max_alignment(AlignSize a, AlignSize b) => a < b ? b : a;

fn BitSize type_bit_size(Type* type) => (BitSize)type_size(type) * 8;
