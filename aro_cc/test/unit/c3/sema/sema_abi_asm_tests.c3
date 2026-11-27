// Tests for the C ABI and inline asm table ports (src/frontend/c3/c_abi.c3,
// c_abi_x64.c3, asm_target.c3, sema_asm.c3): SysV x86_64 classification of
// builtin types, the AbiType helpers, and the x86_64 instruction / register
// tables built by init_asm. Expectations follow c3c 54bab366a (and the
// AMD64 psABI). Struct classification needs sema-laid-out types, so it is
// left to the c3c test suite.
module c3_sema_abi_asm_tests;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

fn ABIArgInfo* ret_of(Type* type) => compiler::x64_classify_return({ .type = type });

fn String intern(String name, TokenType type)
{
	return compiler::symtab_add(name, &type);
}

module c3_sema_abi_asm_tests @test;
import aro::frontend::c3::compiler, aro::frontend::c3::tokens;

fn void abi_type_helpers()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	check(compiler::abi_type_size(compiler::abi_type_spec(compiler::ABI_TYPE_INT_24)), 3);
	check(compiler::abi_type_size(compiler::abi_type_spec(compiler::ABI_TYPE_DOUBLE_VEC_4)), 32);
	check(compiler::abi_type_abi_alignment(compiler::abi_type_spec(compiler::ABI_TYPE_INT_56)), 8);
	check(compiler::abi_type_size(compiler::abi_type_get(compiler::type_long)), 8);
	assert(compiler::abi_arg_ignore().kind == ARG_IGNORE);
	assert(!compiler::abi_arg_is_indirect(compiler::abi_arg_ignore()));
	ABIArgInfo* info = compiler::abi_arg_new_indirect_by_val(compiler::type_double, { .type = compiler::type_double });
	assert(compiler::abi_arg_is_indirect(info));
	check(info.indirect.alignment, 8);
	assert(info.attributes.by_val);
	ABIArgInfo* bits = compiler::abi_arg_new_direct_coerce_type_bits(40, { .type = compiler::type_long });
	check(bits.direct_coerce_type.abi_type, compiler::ABI_TYPE_INT_40);
}

fn void x64_merge_rules()
{
	assert(compiler::x64_merge(NO_CLASS, SSE) == SSE);
	assert(compiler::x64_merge(INTEGER, SSE) == INTEGER);
	assert(compiler::x64_merge(SSE, INTEGER) == INTEGER);
	assert(compiler::x64_merge(SSE, SSEUP) == SSE);
	assert(compiler::x64_merge(NO_CLASS, MEMORY) == MEMORY);
	X64Class lo = SSE;
	X64Class hi = INTEGER;
	compiler::x64_classify_post_merge(24, &lo, &hi);
	assert(lo == MEMORY);
	lo = INTEGER;
	hi = SSEUP;
	compiler::x64_classify_post_merge(16, &lo, &hi);
	assert(hi == SSE);
}

fn void x64_scalar_returns()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	assert(ret_of(compiler::type_void).kind == ARG_IGNORE);
	assert(ret_of(compiler::type_int).kind == ARG_DIRECT);
	assert(ret_of(compiler::type_long).kind == ARG_DIRECT);
	assert(ret_of(compiler::type_double).kind == ARG_DIRECT);
	assert(ret_of(compiler::type_float).kind == ARG_DIRECT);
	assert(ret_of(compiler::type_voidptr).kind == ARG_DIRECT);
	// Promotable ints are coerced with an extension attribute.
	ABIArgInfo* b = ret_of(compiler::type_bool);
	assert(b.kind == ARG_DIRECT_COERCE);
	assert(b.attributes.zeroext && !b.attributes.signext);
	ABIArgInfo* c = ret_of(compiler::type_ichar);
	assert(c.kind == ARG_DIRECT_COERCE);
	assert(c.attributes.signext);
	ABIArgInfo* s = ret_of(compiler::type_short);
	assert(s.attributes.signext);
}

fn void x64_pair_returns()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	// A slice is { ptr, len } in rax:rdx.
	ABIArgInfo* slice = ret_of(compiler::type_get_slice(compiler::type_char));
	assert(slice.kind == ARG_DIRECT_PAIR);
	assert(slice.direct_pair.lo.type == compiler::type_voidptr);
	assert(slice.direct_pair.hi.type == compiler::type_ulong);
	// i128 is INTEGER / INTEGER.
	ABIArgInfo* i128 = ret_of(compiler::type_i128);
	assert(i128.kind == ARG_DIRECT_PAIR);
	assert(i128.direct_pair.lo.type == compiler::type_ulong);
	assert(i128.direct_pair.hi.type == compiler::type_ulong);
	// float[<2>] (8 bytes) is a single SSE eightbyte.
	Type* v2 = compiler::type_get_vector(compiler::type_float, SIMD_VECTOR, 2);
	X64Class lo;
	X64Class hi;
	compiler::x64_classify(v2, 0, &lo, &hi, NAMED);
	assert(lo == SSE && hi == NO_CLASS);
	// float[<4>] (16 bytes) is SSE / SSEUP, passed as the vector itself.
	Type* v4 = compiler::type_get_vector(compiler::type_float, SIMD_VECTOR, 4);
	compiler::x64_classify(v4, 0, &lo, &hi, NAMED);
	assert(lo == SSE && hi == SSEUP);
	assert(ret_of(v4).kind == ARG_DIRECT);
}

fn void x64_parameters_use_registers()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Registers regs = { .int_registers = 6, .sse_registers = 8 };
	Type* slice = compiler::type_get_slice(compiler::type_char);
	for (int i = 0; i < 3; i++)
	{
		ABIArgInfo* info = compiler::x64_classify_parameter({ .type = slice }, &regs, NAMED);
		assert(info.kind == ARG_DIRECT_PAIR);
	}
	check(regs.int_registers, 0);
	check(regs.sse_registers, 8);
	ABIArgInfo* d = compiler::x64_classify_parameter({ .type = compiler::type_double }, &regs, NAMED);
	assert(d.kind == ARG_DIRECT);
	check(regs.sse_registers, 7);
}

fn void x64_int_type_at_offset()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	Type* slice = compiler::type_get_slice(compiler::type_char);
	assert(compiler::x64_get_int_type_at_offset(slice, 0, slice, 0).type == compiler::type_voidptr);
	assert(compiler::x64_get_int_type_at_offset(slice, 8, slice, 8).type == compiler::type_ulong);
	assert(compiler::x64_get_int_type_at_offset(compiler::type_int, 0, compiler::type_int, 0).type == compiler::type_int);
	assert(compiler::x64_bits_contain_no_user_data(compiler::type_int, 4, 8));
	assert(!compiler::x64_bits_contain_no_user_data(compiler::type_long, 4, 8));
}

fn void x86_64_asm_tables()
{
	compiler::compiler_reset();
	defer compiler::compiler_free();
	PlatformTarget* target = &compiler::compiler.platform;
	assert(target.arch == X86_64);
	compiler::init_asm(target);
	assert(target.asm_initialized);
	check(target.register_count, 16 * 4 + 4 + 16 * 3 + 4);

	assert(compiler::asm_instr_by_name(intern("notaninstr", IDENT)) == null);
	AsmInstruction* movq = compiler::asm_instr_by_name(intern("movq", IDENT));
	assert(movq);
	check(movq.param_count, 2);
	assert(movq.param[0].is_write && !movq.param[0].is_readwrite);
	assert(movq.param[0].is_address);
	check(movq.param[0].ireg_bits, compiler::ARG_BITS_64);
	check(movq.param[1].imm_arg_ibits, compiler::ARG_BITS_32 | compiler::ARG_BITS_64);
	check(movq.param[1].imm_arg_ubits, compiler::ARG_BITS_64);

	AsmInstruction* xaddb = compiler::asm_instr_by_name(intern("xaddb", IDENT));
	check(xaddb.param_count, 2);
	assert(xaddb.param[0].is_readwrite && xaddb.param[1].is_readwrite);
	check(xaddb.param[1].ireg_bits, compiler::ARG_BITS_8);

	AsmInstruction* vaddps = compiler::asm_instr_by_name(intern("vaddps", IDENT));
	check(vaddps.param_count, 3);
	check(vaddps.param[2].vec_bits, compiler::ARG_BITS_128 | compiler::ARG_BITS_256 | compiler::ARG_BITS_512);
	assert(vaddps.param[2].is_address);

	AsmInstruction* nop = compiler::asm_instr_by_name(intern("nop", IDENT));
	check(nop.param_count, 0);
	AsmInstruction* cpuid = compiler::asm_instr_by_name(intern("cpuid", IDENT));
	foreach (reg : (int[]){ compiler::X86_CC, compiler::X86_RAX, compiler::X86_RBX, compiler::X86_RCX, compiler::X86_RDX })
	{
		assert(cpuid.mask.mask[0] & (1UL << reg));
	}
	assert(!(cpuid.mask.mask[0] & (1UL << compiler::X86_RSI)));
	// 32-bit only instructions are not registered on x86_64.
	assert(compiler::asm_instr_by_name(intern("pushl", IDENT)) == null);

	AsmRegister* rax = compiler::asm_reg_by_name(target, intern("$rax", CT_IDENT));
	assert(rax);
	assert(rax.type == REG_INT);
	check(rax.bits, compiler::ARG_BITS_64);
	check(rax.clobber_index, compiler::X86_RAX);
	AsmRegister* ah = compiler::asm_reg_by_name(target, intern("$ah", CT_IDENT));
	check(ah.bits, compiler::ARG_BITS_8);
	AsmRegister* ymm3 = compiler::asm_reg_by_name(target, intern("$ymm3", CT_IDENT));
	assert(ymm3.type == REF_FVEC);
	check(ymm3.clobber_index, compiler::X86_XMM3);
	assert(compiler::asm_reg_by_name(target, intern("$st0", CT_IDENT)) == null);
	test::eq(compiler::asm_clobber_by_index(compiler::X86_XMM15), "xmm15");

	// A second init after a reset starts from clean tables.
	target.asm_initialized = false;
	compiler::init_asm(target);
	check(target.register_count, 16 * 4 + 4 + 16 * 3 + 4);
}
