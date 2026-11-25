// Sema contract for c3c src/compiler/asm_target.c (+ the target.h asm
// structs): the instruction / register tables sema_asm.c3 and sema_stmts.c3
// query. Owned by the sema_asm port: the public functions are stubs, the
// static table builders (init_asm_x86, reg_instr, ...) are not listed yet.
module aro::frontend::c3::compiler;

<* target.h `AsmArgType`. *>
struct AsmArgType
{
	bool is_write;
	bool is_readwrite;
	bool is_address;
	AsmArgBits imm_arg_ubits;
	AsmArgBits imm_arg_ibits;
	AsmArgBits ireg_bits;
	AsmArgBits float_bits;
	AsmArgBits vec_bits;
}

<* target.h `AsmInstruction`. *>
struct AsmInstruction
{
	String name;
	AsmArgType[MAX_ASM_INSTRUCTION_PARAMS] param; // Types of arguments available in each slot
	int param_count;
	Clobbers mask; // Which will it clobber
}

// asm_target.c:223
fn AsmInstruction* asm_instr_by_name(String name)
{
	unreachable("sema stub: asm_instr_by_name");
}

// asm_target.c:238
fn bool asm_clobber_is_register(int index)
{
	unreachable("sema stub: asm_clobber_is_register");
}

// asm_target.c:244
fn AsmRegister* asm_reg_by_name(PlatformTarget* target, String name)
{
	unreachable("sema stub: asm_reg_by_name");
}

fn bool asm_is_supported(ArchType arch)
{
	switch (arch)
	{
		case X86:
		case X86_64:
		case RISCV32:
		case RISCV64:
		case AARCH64:
			return true;
		default:
			return false;
	}
}

// asm_target.c:1094
fn void print_asm(PlatformTarget* target)
{
	unreachable("sema stub: print_asm");
}

// asm_target.c:1113
fn void init_asm(PlatformTarget* target)
{
	unreachable("sema stub: init_asm");
}
