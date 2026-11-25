// Sema contract stubs for c3c src/compiler/abi/c_abi.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// abi/c_abi.c:8 (static)
fn ABIArgInfo* abi_arg_new(ABIKind kind, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new");
}

// abi/c_abi.c:17
fn ABIArgInfo* abi_arg_ignore()
{
	unreachable("sema stub: abi_arg_ignore");
}

// abi/c_abi.c:24
fn TypeSize abi_type_size(AbiType type)
{
	unreachable("sema stub: abi_type_size");
}

// abi/c_abi.c:49
fn AlignSize abi_type_abi_alignment(AbiType type)
{
	unreachable("sema stub: abi_type_abi_alignment");
}

// abi/c_abi.c:74
fn bool abi_arg_is_indirect(ABIArgInfo* info)
{
	unreachable("sema stub: abi_arg_is_indirect");
}

// abi/c_abi.c:93
fn ABIArgInfo* abi_arg_new_indirect_realigned(AlignSize alignment, Type* by_val_type, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_indirect_realigned");
}

// abi/c_abi.c:105
fn ABIArgInfo* abi_arg_new_indirect_by_val(Type* by_val_type, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_indirect_by_val");
}

// abi/c_abi.c:115
fn ABIArgInfo* abi_arg_new_indirect_not_by_val(Type* type, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_indirect_not_by_val");
}

// abi/c_abi.c:125
fn ABIArgInfo* abi_arg_new_direct_int_ext(Type* int_to_extend, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_int_ext");
}

// abi/c_abi.c:130
fn ABIArgInfo* abi_arg_new_direct_coerce_int_ext(Type* int_to_extend, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_coerce_int_ext");
}

// abi/c_abi.c:135
fn ABIArgInfo* abi_arg_new_direct_coerce_int_ext_by_reg(Type* int_to_extend, bool by_reg, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_coerce_int_ext_by_reg");
}

// abi/c_abi.c:150
fn ABIArgInfo* abi_arg_new_direct_int_ext_by_reg(Type* int_to_extend, bool by_reg, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_int_ext_by_reg");
}

// abi/c_abi.c:165
fn ABIArgInfo* abi_arg_new_direct_pair(AbiType low_type, AbiType high_type, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_pair");
}

// abi/c_abi.c:173
fn ABIArgInfo* abi_arg_new_direct_by_reg(bool by_reg, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_by_reg");
}

// abi/c_abi.c:180
fn ABIArgInfo* abi_arg_new_direct(ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct");
}

// abi/c_abi.c:186
fn ABIArgInfo* abi_arg_new_expand(ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_expand");
}

// abi/c_abi.c:192
fn ABIArgInfo* abi_arg_new_expand_coerce_pair(Type* first_element, Type* second_element, int hi_offset, bool packed, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_expand_coerce_pair");
}

// abi/c_abi.c:202
fn ABIArgInfo* abi_arg_new_direct_coerce_int(ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_coerce_int");
}

// abi/c_abi.c:207
fn ABIArgInfo* abi_arg_new_direct_coerce_type_spec(AbiSpecType type, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_coerce_type_spec");
}

// abi/c_abi.c:214
fn ABIArgInfo* abi_arg_new_direct_coerce_type(AbiType type, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_coerce_type");
}

// abi/c_abi.c:221
fn ABIArgInfo* abi_arg_new_direct_coerce_type_bits(int bits, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_coerce_type_bits");
}

// abi/c_abi.c:228
fn ABIArgInfo* abi_arg_new_direct_struct_expand_i32(char elements, ParamInfo param)
{
	unreachable("sema stub: abi_arg_new_direct_struct_expand_i32");
}

// abi/c_abi.c:236
fn void c_abi_func_create(Signature* sig, FunctionPrototype* proto, Expr*[] vaargs)
{
	unreachable("sema stub: c_abi_func_create");
}

// abi/c_abi.c:328
fn ABIArgInfo* c_abi_classify_return_type_default(ParamInfo param)
{
	unreachable("sema stub: c_abi_classify_return_type_default");
}

// abi/c_abi.c:335
fn ABIArgInfo* c_abi_classify_argument_type_default(ParamInfo param)
{
	unreachable("sema stub: c_abi_classify_argument_type_default");
}

// abi/c_abi.c:352
fn void c_abi_func_create_default(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	unreachable("sema stub: c_abi_func_create_default");
}
