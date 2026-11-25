// Port of c3c src/compiler/abi/c_abi_wasm.c (revision 54bab366a): the
// WebAssembly C ABI classifier.
//
// Deviations from c3c:
// - The ABIArgInfo arrays are arena-allocated slices (c3c `MALLOC`);
//   `wasm_create_params` returns an empty slice where c3c returns NULL.
// - c3c's commented-out experimental multivalue ABI blocks are summarised in
//   a comment instead of copied.
module aro::frontend::c3::compiler;

// abi/c_abi_wasm.c:7 (static)
fn ABIArgInfo* wasm_classify_argument_type(ParamInfo param)
{
	Type* type = type_lowering(param.type);
	if (type_is_abi_aggregate(type))
	{
		// Clang: Lower single-field structs to just pass a regular value. TODO: We
		// could do reasonable-size multiple-field structs too, using getExpand(),
		// though watch out for things like bitfields.
		Type* single_type = type_abi_find_single_struct_element(type, true);
		if (single_type) return abi_arg_new_direct_coerce_type(abi_type_get(single_type), param);

		// For the experimental multivalue ABI, fully expand all other aggregates
		// (not ported in c3c either: getExpand() unless the record has bitfields).
	}

	// Otherwise just do the default thing.
	return c_abi_classify_argument_type_default(param);
}

// abi/c_abi_wasm.c:38 (static)
fn ABIArgInfo* wasm_classify_return(ParamInfo param)
{
	Type* type = type_lowering(param.type);
	if (type_is_abi_aggregate(type))
	{
		Type* single_type = type_abi_find_single_struct_element(type, true);
		if (single_type) return abi_arg_new_direct_coerce_type(abi_type_get(single_type), param);
		// For the experimental multivalue ABI, return all other aggregates
		// directly (not ported in c3c either).
	}
	// Use default classification
	return c_abi_classify_return_type_default(param);
}

// abi/c_abi_wasm.c:55
fn ABIArgInfo*[] wasm_create_params(ParamInfo* params, int param_count)
{
	if (!param_count) return {};
	ABIArgInfo*[] args = ((ABIArgInfo**)calloc_arena(ABIArgInfo*::size * (usz)param_count))[:param_count];
	for (int i = 0; i < param_count; i++)
	{
		args[i] = wasm_classify_argument_type(params[i]);
	}
	return args;
}

// abi/c_abi_wasm.c:66
fn void c_abi_func_create_wasm(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	prototype.ret_abi_info = wasm_classify_return(prototype.return_info);
	prototype.abi_args = wasm_create_params(params, param_count);
	prototype.abi_varargs = wasm_create_params(vaargs, vaarg_count);
}
