// Sema contract stubs for the non-x64 C ABIs that c_abi.c3's
// `c_abi_func_create` dispatches to (c3c src/compiler/abi/c_abi_win64.c,
// c_abi_x86.c, c_abi_aarch64.c, c_abi_riscv.c, c_abi_wasm.c). Only x86_64
// Linux is targeted for now; port these when another target is added.
module aro::frontend::c3::compiler;

// abi/c_abi_win64.c
fn void c_abi_func_create_win64(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	unreachable("sema stub: c_abi_func_create_win64");
}

// abi/c_abi_x86.c
fn void c_abi_func_create_x86(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	unreachable("sema stub: c_abi_func_create_x86");
}

// abi/c_abi_aarch64.c
fn void c_abi_func_create_aarch64(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	unreachable("sema stub: c_abi_func_create_aarch64");
}

// abi/c_abi_riscv.c
fn void c_abi_func_create_riscv(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	unreachable("sema stub: c_abi_func_create_riscv");
}

// abi/c_abi_wasm.c
fn void c_abi_func_create_wasm(FunctionPrototype* prototype, ParamInfo* params, int param_count, ParamInfo* vaargs, int vaarg_count)
{
	unreachable("sema stub: c_abi_func_create_wasm");
}

