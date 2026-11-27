// Port of c3c src/compiler/abi/c_abi.c (revision 54bab366a): ABIArgInfo
// constructors and `c_abi_func_create`, which classifies a signature's
// parameters / return for the platform C ABI.
//
// Deviations from c3c:
// - `abi_arg_ignore` returns a module-level static instead of a function
//   static.
// - The 512-entry ParamInfo stack buffers are kept; the ABIArgInfo arrays
//   are arena-allocated slices (`FunctionPrototype.abi_args` is a slice).
// - `FATAL_ERROR` is `@error_exit`.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

ABIArgInfo abi_arg_ignore_info = { .kind = ARG_IGNORE };

// abi/c_abi.c:8 (static)
fn ABIArgInfo* abi_arg_new(ABIKind kind, ParamInfo param)
{
	ABIArgInfo* info = calloc_arena(ABIArgInfo::size);
	info.kind = kind;
	info.original_type = param.type;
	info.rewrite = param.rewrite;
	return info;
}

// abi/c_abi.c:17
fn ABIArgInfo* abi_arg_ignore()
{
	return &abi_arg_ignore_info;
}

// abi/c_abi.c:24
fn TypeSize abi_type_size(AbiType type)
{
	if (abi_type_is_type(type)) return type_size(type.type);
	switch (type.abi_type)
	{
		case ABI_TYPE_INT_24: return 3;
		case ABI_TYPE_INT_40: return 5;
		case ABI_TYPE_INT_48: return 6;
		case ABI_TYPE_INT_56: return 7;
		case ABI_TYPE_INT_VEC_2: return 8;
		case ABI_TYPE_FLOAT_VEC_2: return 8;
		case ABI_TYPE_FLOAT16_VEC_2: return 4;
		case ABI_TYPE_FLOAT16_VEC_4: return 8;
		case ABI_TYPE_BFLOAT16_VEC_2: return 4;
		case ABI_TYPE_BFLOAT16_VEC_4: return 8;
		case ABI_TYPE_INT_VEC_4: return 16;
		case ABI_TYPE_FLOAT_VEC_4: return 16;
		case ABI_TYPE_DOUBLE_VEC_2: return 16;
		case ABI_TYPE_LONG_VEC_2: return 16;
		case ABI_TYPE_DOUBLE_VEC_4: return 32;
		case ABI_TYPE_DOUBLE_VEC_8: return 64;
	}
	unreachable();
}

// abi/c_abi.c:49
fn AlignSize abi_type_abi_alignment(AbiType type)
{
	if (abi_type_is_type(type)) return type_abi_alignment(type.type);
	switch (type.abi_type)
	{
		case ABI_TYPE_FLOAT16_VEC_2:
		case ABI_TYPE_BFLOAT16_VEC_2:
		case ABI_TYPE_INT_24:
			return 4;
		case ABI_TYPE_INT_40:
		case ABI_TYPE_INT_48:
		case ABI_TYPE_INT_56:
		case ABI_TYPE_FLOAT16_VEC_4:
		case ABI_TYPE_BFLOAT16_VEC_4:
		case ABI_TYPE_FLOAT_VEC_2:
		case ABI_TYPE_INT_VEC_2:
			return 8;
		case ABI_TYPE_FLOAT_VEC_4:
		case ABI_TYPE_LONG_VEC_2:
		case ABI_TYPE_DOUBLE_VEC_2:
		case ABI_TYPE_INT_VEC_4:
			return 16;
		case ABI_TYPE_DOUBLE_VEC_4: return 32;
		case ABI_TYPE_DOUBLE_VEC_8: return 64;
	}
	unreachable();
}

// abi/c_abi.c:74
fn bool abi_arg_is_indirect(ABIArgInfo* info)
{
	switch (info.kind)
	{
		case ARG_IGNORE:
		case ARG_DIRECT:
		case ARG_DIRECT_COERCE:
		case ARG_DIRECT_COERCE_INT:
		case ARG_DIRECT_SPLIT_STRUCT_I32:
		case ARG_EXPAND:
		case ARG_DIRECT_PAIR:
		case ARG_EXPAND_COERCE:
			return false;
		case ARG_INDIRECT:
			return true;
	}
}

// abi/c_abi.c:93
fn ABIArgInfo* abi_arg_new_indirect_realigned(AlignSize alignment, Type* by_val_type, ParamInfo param)
{
	assert(alignment > 0);
	ABIArgInfo* info = abi_arg_new(ARG_INDIRECT, param);
	info.indirect.alignment = alignment;
	assert(info.indirect.alignment);
	info.attributes.realign = true;
	info.indirect.type = by_val_type;
	info.attributes.by_val = true;
	return info;
}

// abi/c_abi.c:105
fn ABIArgInfo* abi_arg_new_indirect_by_val(Type* by_val_type, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_INDIRECT, param);
	info.indirect.alignment = type_abi_alignment(by_val_type);
	info.indirect.type = by_val_type;
	info.attributes.by_val = true;
	assert(info.indirect.alignment);
	return info;
}

// abi/c_abi.c:115
fn ABIArgInfo* abi_arg_new_indirect_not_by_val(Type* type, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_INDIRECT, param);
	info.indirect.alignment = type_abi_alignment(type);
	assert(info.indirect.alignment);
	info.indirect.type = type;
	info.attributes.by_val = false;
	return info;
}

// abi/c_abi.c:125
fn ABIArgInfo* abi_arg_new_direct_int_ext(Type* int_to_extend, ParamInfo param)
{
	return abi_arg_new_direct_int_ext_by_reg(int_to_extend, false, param);
}

// abi/c_abi.c:130
fn ABIArgInfo* abi_arg_new_direct_coerce_int_ext(Type* int_to_extend, ParamInfo param)
{
	return abi_arg_new_direct_coerce_int_ext_by_reg(int_to_extend, false, param);
}

// abi/c_abi.c:135
fn ABIArgInfo* abi_arg_new_direct_coerce_int_ext_by_reg(Type* int_to_extend, bool by_reg, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new_direct_coerce_type(abi_type_get(int_to_extend), param);
	if (type_is_signed(int_to_extend))
	{
		info.attributes.signext = true;
	}
	else
	{
		info.attributes.zeroext = true;
	}
	info.attributes.by_reg = by_reg;
	return info;
}

// abi/c_abi.c:150
fn ABIArgInfo* abi_arg_new_direct_int_ext_by_reg(Type* int_to_extend, bool by_reg, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_DIRECT, param);
	if (type_is_signed(int_to_extend))
	{
		info.attributes.signext = true;
	}
	else
	{
		info.attributes.zeroext = true;
	}
	info.attributes.by_reg = by_reg;
	return info;
}

// abi/c_abi.c:165
fn ABIArgInfo* abi_arg_new_direct_pair(AbiType low_type, AbiType high_type, ParamInfo param)
{
	ABIArgInfo* arg_info = abi_arg_new(ARG_DIRECT_PAIR, param);
	arg_info.direct_pair.hi = high_type;
	arg_info.direct_pair.lo = low_type;
	return arg_info;
}

// abi/c_abi.c:173
fn ABIArgInfo* abi_arg_new_direct_by_reg(bool by_reg, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_DIRECT, param);
	info.attributes.by_reg = by_reg;
	return info;
}

// abi/c_abi.c:180
fn ABIArgInfo* abi_arg_new_direct(ParamInfo param)
{
	return abi_arg_new_direct_by_reg(false, param);
}

// abi/c_abi.c:186
fn ABIArgInfo* abi_arg_new_expand(ParamInfo param)
{
	return abi_arg_new(ARG_EXPAND, param);
}

// abi/c_abi.c:192
fn ABIArgInfo* abi_arg_new_expand_coerce_pair(Type* first_element, Type* second_element, int hi_offset, bool packed, ParamInfo param)
{
	ABIArgInfo* arg = abi_arg_new(ARG_EXPAND_COERCE, param);
	arg.coerce_expand.lo = first_element;
	arg.coerce_expand.hi = second_element;
	arg.coerce_expand.offset_hi = (char)hi_offset;
	arg.coerce_expand.packed = packed;
	return arg;
}

// abi/c_abi.c:202
fn ABIArgInfo* abi_arg_new_direct_coerce_int(ParamInfo param)
{
	return abi_arg_new(ARG_DIRECT_COERCE_INT, param);
}

// abi/c_abi.c:207
fn ABIArgInfo* abi_arg_new_direct_coerce_type_spec(AbiSpecType type, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_DIRECT_COERCE, param);
	info.direct_coerce_type = { .abi_type = type };
	return info;
}

// abi/c_abi.c:214
fn ABIArgInfo* abi_arg_new_direct_coerce_type(AbiType type, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_DIRECT_COERCE, param);
	info.direct_coerce_type = type;
	return info;
}

// abi/c_abi.c:221
fn ABIArgInfo* abi_arg_new_direct_coerce_type_bits(int bits, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_DIRECT_COERCE, param);
	info.direct_coerce_type = abi_type_get_int_bits(bits);
	return info;
}

// abi/c_abi.c:228
fn ABIArgInfo* abi_arg_new_direct_struct_expand_i32(char elements, ParamInfo param)
{
	ABIArgInfo* info = abi_arg_new(ARG_DIRECT_SPLIT_STRUCT_I32, param);
	info.direct_struct_expand = elements;
	return info;
}

<* Allocate a `count`-entry ABIArgInfo* slice on the AST arena (c3c `MALLOC`). *>
fn ABIArgInfo*[] abi_arg_array_new(int count) @local
{
	return ((ABIArgInfo**)calloc_arena(ABIArgInfo*::size * (usz)count))[:count];
}

// abi/c_abi.c:236
<* Fully set up the prototype correctly *>
fn void c_abi_func_create(Signature* sig, FunctionPrototype* proto, Expr*[] vaargs)
{
	assert(!proto.is_resolved);
	ParamInfo[512] vaarg_params @noinit;
	ParamInfo[512] params @noinit;
	proto.raw_variadic = sig.variadic == Variadic.RAW;
	proto.vararg_index = (ushort)sig.vararg_index;
	Type* rtype = type_infoptr(sig.rtype).type;
	Type* rtype_flat = type_flatten(rtype);
	int param_count = 0;
	if (rtype_flat.type_kind == VECTOR)
	{
		rtype_flat = type_array_from_vector(rtype_flat);
		proto.return_rewrite = RW_VEC_TO_ARRAY;
	}
	if (type_is_optional(rtype))
	{
		proto.return_info = { .type = type_fault };
		proto.return_result = type_no_optional(rtype);
		if (type_is_void(rtype_flat))
		{
			proto.ret_rewrite = OPTIONAL_VOID;
		}
		else
		{
			proto.ret_rewrite = OPTIONAL_VALUE;
			params[param_count++] = { .type = type_get_ptr(rtype_flat) };
		}
	}
	else
	{
		proto.return_info = { .type = rtype_flat };
		proto.return_result = rtype;
		proto.ret_rewrite = NORMAL;
	}
	proto.call_abi = sig.abi;

	usz param_decl_count = sig.params.len;
	for (usz i = 0; i < param_decl_count; i++)
	{
		Decl* decl = sig.params[i];
		Type* flat_type = type_flatten(decl.type);
		ParamInfo param_info = { .type = flat_type };
		if (flat_type.type_kind == VECTOR)
		{
			param_info.rewrite = RW_VEC_TO_ARRAY;
			param_info.type = type_array_from_vector(flat_type);
		}
		params[param_count++] = param_info;
	}
	int vaarg_count = 0;
	foreach (val : vaargs)
	{
		vaarg_params[vaarg_count++] = { .type = type_flatten(val.type) };
	}
	proto.param_vacount = (ushort)vaarg_count;
	proto.param_count = param_count;
	proto.is_resolved = true;
	switch (compiler.platform.abi)
	{
		case X64:
			c_abi_func_create_x64(proto, &params, param_count, &vaarg_params, vaarg_count);
			return;
		case X86:
			c_abi_func_create_x86(proto, &params, param_count, &vaarg_params, vaarg_count);
			return;
		case WIN64:
			c_abi_func_create_win64(proto, &params, param_count, &vaarg_params, vaarg_count);
			return;
		case AARCH64:
			c_abi_func_create_aarch64(proto, &params, param_count, &vaarg_params, vaarg_count);
			return;
		case RISCV:
			c_abi_func_create_riscv(proto, &params, param_count, &vaarg_params, vaarg_count);
			return;
		case WASM:
			c_abi_func_create_wasm(proto, &params, param_count, &vaarg_params, vaarg_count);
			return;
		case XTENSA:
		case AVR:
			c_abi_func_create_default(proto, &params, param_count, &vaarg_params, vaarg_count);
			return;
		case UNKNOWN:
		case ARM:
		case PPC32:
		case PPC64_SVR4:
			break;
	}
	@error_exit("Unsupported ABI");
}

// abi/c_abi.c:328
fn ABIArgInfo* c_abi_classify_return_type_default(ParamInfo param)
{
	Type* type = type_lowering(param.type);
	if (type_is_void(type)) return abi_arg_ignore();
	return c_abi_classify_argument_type_default(param);
}

// abi/c_abi.c:335
fn ABIArgInfo* c_abi_classify_argument_type_default(ParamInfo param)
{
	// Perform general lowering.
	Type* type = type_lowering(param.type);

	// Struct-likes are returned by sret
	if (type_is_abi_aggregate(type)) return abi_arg_new_indirect_by_val(type, param);

	if (type_is_int128(type) && !compiler.platform.int128_supported) return abi_arg_new_indirect_by_val(type, param);

	// Otherwise do we have a type that needs promotion?
	if (type_is_promotable_int_bool(type)) return abi_arg_new_direct_int_ext(type, param);

	// No, then do a direct pass.
	return abi_arg_new_direct(param);
}

// abi/c_abi.c:352
fn void c_abi_func_create_default(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	prototype.ret_abi_info = c_abi_classify_return_type_default(prototype.return_info);

	if (param_count)
	{
		ABIArgInfo*[] args = abi_arg_array_new(param_count);
		for (int i = 0; i < param_count; i++)
		{
			args[i] = c_abi_classify_argument_type_default(params[i]);
		}
		prototype.abi_args = args;
	}
	if (vaarg_count)
	{
		ABIArgInfo*[] args = abi_arg_array_new(vaarg_count);
		for (int i = 0; i < vaarg_count; i++)
		{
			args[i] = c_abi_classify_argument_type_default(vaargs[i]);
		}
		prototype.abi_varargs = args;
	}
}
