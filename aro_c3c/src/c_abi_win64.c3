// Port of c3c src/compiler/abi/c_abi_win64.c (revision 54bab366a): the
// Windows x64 C ABI classifier (incl. __vectorcall HVA handling).
//
// Deviations from c3c:
// - The ABIArgInfo arrays are arena-allocated slices (c3c `MALLOC`);
//   `win64_create_params` returns an empty slice where c3c returns NULL.
// - The function-static `max_param_vector_calls_as_reg` is a plain local.
// - `compiler.build.feature.pass_win64_simd_as_arrays` is tested with `!= 0`
//   (C truthiness of the Win64Simd value, as in c3c).
// - `long` (ByteSize) is cast to int / ulong at the helper boundaries.
module aro::frontend::c3::compiler;

// abi/c_abi_win64.c:7
fn ABIArgInfo* win64_classify(Regs* regs, ParamInfo param, bool is_return, bool is_vector_call)
{
	Type* type = param.type;
	if (type_is_void(type)) return abi_arg_ignore();

	// Lower enums etc.
	type = type_lowering(type);

	// Variable array has to be passed indirectly.
	if (type_is_union_or_strukt(type) && type.decl.has_variable_array)
	{
		return abi_arg_new_indirect_not_by_val(type, param);
	}

	Type* base = null;
	int elements = 0;
	if (is_vector_call && type_is_homogeneous_aggregate(type, &base, &elements))
	{
		// Enough registers AND return / builtin / vector
		if (regs.float_regs >= elements &&
			(is_return || type_is_builtin(type.type_kind) || type.type_kind == SIMD_VECTOR))
		{
			regs.float_regs -= elements;
			return abi_arg_new_direct(param);
		}
		// HVAs are handled later.
		if (is_return || (!type_is_builtin(type.type_kind) && type.type_kind != SIMD_VECTOR))
		{
			return abi_arg_new_indirect_not_by_val(type, param);
		}
		// => to main handling.
	}
	ByteSize size = type_size(type);
	bool type_is_vector_to_pass_as_array = compiler.build.feature.pass_win64_simd_as_arrays != 0 && type.type_kind == SIMD_VECTOR;
	// Vectors are returned in XMM0 (YMM0 / ZMM0 for wider ones).
	if (is_return && type.type_kind == SIMD_VECTOR && !type_is_vector_to_pass_as_array)
	{
		return abi_arg_new_direct(param);
	}
	if (type_is_vector_to_pass_as_array || type_is_abi_aggregate(type))
	{
		// Not 1, 2, 4, 8? Pass indirect.
		if (size > 8 || !is_power_of_two((ulong)size))
		{
			return abi_arg_new_indirect_not_by_val(type, param);
		}
		// Coerce to integer.
		return abi_arg_new_direct_coerce_type_bits((int)(size * 8), param);
	}
	if (type_is_builtin(type.type_kind))
	{
		switch (type.type_kind)
		{
			case BOOL:
				return abi_arg_new_direct_int_ext(type_bool, param);
			case U128:
			case I128:
				// Pass by val since greater than 8 bytes.
				if (!is_return) return abi_arg_new_indirect_not_by_val(type, param);
				// Make i128 return in XMM0
				return abi_arg_new_direct_coerce_type_spec(ABI_TYPE_LONG_VEC_2, param);
			default:
				break;
		}
	}
	if (size > 8)
	{
		return abi_arg_new_indirect_not_by_val(type, param);
	}
	return abi_arg_new_direct(param);
}

// abi/c_abi_win64.c:79
fn ABIArgInfo* win64_reclassify_hva_arg(Regs* regs, ParamInfo param, ABIArgInfo* info)
{
	// Assumes vectorCall calling convention.
	Type* base = null;
	int elements = 0;
	Type* type = type_lowering(param.type);
	if (!type_is_builtin(type.type_kind) && type.type_kind != SIMD_VECTOR && type_is_homogeneous_aggregate(type, &base, &elements))
	{
		if (regs.float_regs >= elements)
		{
			regs.float_regs -= elements;
			ABIArgInfo* new_info = abi_arg_new_direct_by_reg(true, param);
			return new_info;
		}
	}
	return info;
}

// abi/c_abi_win64.c:97 (static)
fn void win64_vector_call_args(Regs* regs, FunctionPrototype* prototype, ParamInfo* params, int param_count, bool is_vector)
{
	int max_param_vector_calls_as_reg = 6;
	int count = 0;
	if (param_count)
	{
		ABIArgInfo*[] args = ((ABIArgInfo**)calloc_arena(ABIArgInfo*::size * (usz)param_count))[:param_count];
		for (int i = 0; i < param_count; i++)
		{
			if (count < max_param_vector_calls_as_reg)
			{
				args[i] = win64_classify(regs, params[i], false, is_vector);
			}
			else
			{
				// Cannot be passed in registers pretend no registers.
				int float_regs = regs.float_regs;
				regs.float_regs = 0;
				args[i] = win64_classify(regs, params[i], false, is_vector);
				regs.float_regs = float_regs;
			}
			count++;
		}
		for (int i = 0; i < param_count; i++)
		{
			args[i] = win64_reclassify_hva_arg(regs, params[i], args[i]);
		}
		prototype.abi_args = args;
	}
}

// abi/c_abi_win64.c:128
fn ABIArgInfo*[] win64_create_params(ParamInfo* params, int param_count, Regs* regs, bool is_vector_call)
{
	if (!param_count) return {};
	ABIArgInfo*[] args = ((ABIArgInfo**)calloc_arena(ABIArgInfo*::size * (usz)param_count))[:param_count];
	for (int i = 0; i < param_count; i++)
	{
		args[i] = win64_classify(regs, params[i], false, is_vector_call);
	}
	return args;
}

// abi/c_abi_win64.c:139
fn void c_abi_func_create_win64(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	// allow calling sysv?

	// Set up return registers.
	Regs regs = { 0, 0 };
	bool is_vector_call = false;
	switch (prototype.call_abi)
	{
		case X64_VECTOR:
			regs.float_regs = 4;
			is_vector_call = true;
		default:
			regs.float_regs = 0;
	}

	prototype.ret_abi_info = win64_classify(&regs, prototype.return_info, true, is_vector_call);

	// Set up parameter registers.
	switch (prototype.call_abi)
	{
		case X64_VECTOR:
			regs.float_regs = 6;
			is_vector_call = true;
		default:
			regs.float_regs = 0;
	}
	if (is_vector_call)
	{
		win64_vector_call_args(&regs, prototype, params, param_count, is_vector_call);
		return;
	}

	prototype.abi_args = win64_create_params(params, param_count, &regs, is_vector_call);
	prototype.abi_varargs = win64_create_params(vaargs, vaarg_count, &regs, is_vector_call);
}
