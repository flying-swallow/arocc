// Sema contract stubs for c3c src/compiler/abi/c_abi_x64.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
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
	unreachable("sema stub: try_use_registers");
}

// abi/c_abi_x64.c:42
fn ABIArgInfo* x64_indirect_return_result(Type* type, ParamInfo param)
{
	unreachable("sema stub: x64_indirect_return_result");
}

// abi/c_abi_x64.c:57 (static)
fn bool x64_type_is_illegal_vector(Type* type)
{
	unreachable("sema stub: x64_type_is_illegal_vector");
}

// abi/c_abi_x64.c:75
fn ABIArgInfo* x64_indirect_result(Type* type, int free_int_regs, ParamInfo param)
{
	unreachable("sema stub: x64_indirect_result");
}

// abi/c_abi_x64.c:123
fn ABIArgInfo* x64_classify_reg_call_struct_type_check(Type* type, Registers* needed_registers, ParamInfo param)
{
	unreachable("sema stub: x64_classify_reg_call_struct_type_check");
}

// abi/c_abi_x64.c:169 (static)
fn X64Class x64_merge(X64Class accum, X64Class field)
{
	unreachable("sema stub: x64_merge");
}

// abi/c_abi_x64.c:204
fn void x64_classify_post_merge(ByteSize size, X64Class* lo_class, X64Class* hi_class)
{
	unreachable("sema stub: x64_classify_post_merge");
}

// abi/c_abi_x64.c:215
fn void x64_classify_struct_union(Type* type, ByteSize offset_base, X64Class* current, X64Class* lo_class, X64Class* hi_class, NamedArgument named_arg)
{
	unreachable("sema stub: x64_classify_struct_union");
}

// abi/c_abi_x64.c:263
fn void x64_classify_array(Type* type, ByteSize offset_base, X64Class* current, X64Class* lo_class, X64Class* hi_class, NamedArgument named_arg)
{
	unreachable("sema stub: x64_classify_array");
}

// abi/c_abi_x64.c:304
fn void x64_classify_vector(Type* type, ByteSize offset_base, X64Class* current, X64Class* lo_class, X64Class* hi_class, NamedArgument named_arg)
{
	unreachable("sema stub: x64_classify_vector");
}

// abi/c_abi_x64.c:351 (static)
fn Decl* x64_get_member_at_offset(Decl* decl, int offset)
{
	unreachable("sema stub: x64_get_member_at_offset");
}

// abi/c_abi_x64.c:365 (static)
fn void x64_classify(Type* type, ByteSize offset_base, X64Class* lo_class, X64Class* hi_class, NamedArgument named)
{
	unreachable("sema stub: x64_classify");
}

// abi/c_abi_x64.c:428
fn bool x64_bits_contain_no_user_data(Type* type, int start, int end)
{
	unreachable("sema stub: x64_bits_contain_no_user_data");
}

// abi/c_abi_x64.c:466
fn bool x64_contains_float_at_offset(LoweredType* type, int offset)
{
	unreachable("sema stub: x64_contains_float_at_offset");
}

// abi/c_abi_x64.c:489 (static)
fn Type* x64_get_fp_type_at_offset(Type* type, int ir_offset)
{
	unreachable("sema stub: x64_get_fp_type_at_offset");
}

// abi/c_abi_x64.c:536 (static)
fn AbiType x64_get_sse_type_at_offset(Type* type, int ir_offset, Type* source_type, int source_offset)
{
	unreachable("sema stub: x64_get_sse_type_at_offset");
}

// abi/c_abi_x64.c:588
fn AbiType x64_get_int_type_at_offset(Type* type, int offset, Type* source_type, int source_offset)
{
	unreachable("sema stub: x64_get_int_type_at_offset");
}

// abi/c_abi_x64.c:663 (static)
fn AbiType x64_get_byte_vector_type(Type* type)
{
	unreachable("sema stub: x64_get_byte_vector_type");
}

// abi/c_abi_x64.c:701 (static)
fn ABIArgInfo* x64_get_argument_pair_return(AbiType low_type, AbiType high_type, ParamInfo param)
{
	unreachable("sema stub: x64_get_argument_pair_return");
}

// abi/c_abi_x64.c:715
fn ABIArgInfo* x64_classify_return(ParamInfo param)
{
	unreachable("sema stub: x64_classify_return");
}

// abi/c_abi_x64.c:809 (static)
fn ABIArgInfo* x64_classify_argument_type(Type* type, int free_int_regs, Registers* needed_registers, NamedArgument is_named, ParamInfo param)
{
	unreachable("sema stub: x64_classify_argument_type");
}

// abi/c_abi_x64.c:894 (static)
fn bool x64_type_is_structure(Type* type)
{
	unreachable("sema stub: x64_type_is_structure");
}

// abi/c_abi_x64.c:914 (static)
fn ABIArgInfo* x64_classify_parameter(ParamInfo param, Registers* available_registers, NamedArgument named)
{
	unreachable("sema stub: x64_classify_parameter");
}

// abi/c_abi_x64.c:928
fn void c_abi_func_create_x64(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	unreachable("sema stub: c_abi_func_create_x64");
}
