// Port of c3c src/compiler/asm_target.c (revision 54bab366a) plus the
// target.h asm structs and the asm/x86.h clobber / register tables: the
// inline-asm instruction and register tables sema_asm.c3 and sema_stmts.c3
// query.
//
// Deviations from c3c:
// - The x86 / x86_64 (init_asm_x86, asm/x86.h) and RISC-V (init_asm_riscv,
//   asm/riscv.h) tables are ported. The aarch64 initializer (asm/aarch64.h)
//   is not: it reports the unsupported arch through @error_exit (arm, wasm
//   and ppc error out in c3c too), and `print_asm` only prints x86 clobbers.
// - The tables hash the interned name pointer (`String.ptr`), like c3c.
//   `init_asm` clears both tables first, since `compiler_reset` (tests)
//   re-creates the symtab and resets `asm_initialized`.
// - The descriptor parser walks a String slice; reading past its end yields
//   0 where c3c hits the NUL terminator. A `null` descriptor is "".
// - `print_arch_asm` copies the instruction table to the heap (c3c sorts a
//   stack copy) and sorts with std::sort::quicksort.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;
import std::io, std::sort;

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

// ---------------------------------------------------------------------------
// asm/riscv.h

const int RISCV_X0 = 0;
const int RISCV_X1 = 1;
const int RISCV_X2 = 2;
const int RISCV_X3 = 3;
const int RISCV_X4 = 4;
const int RISCV_X5 = 5;
const int RISCV_X6 = 6;
const int RISCV_X7 = 7;
const int RISCV_X8 = 8;
const int RISCV_X9 = 9;
const int RISCV_X10 = 10;
const int RISCV_X11 = 11;
const int RISCV_X12 = 12;
const int RISCV_X13 = 13;
const int RISCV_X14 = 14;
const int RISCV_X15 = 15;
const int RISCV_X16 = 16;
const int RISCV_X17 = 17;
const int RISCV_X18 = 18;
const int RISCV_X19 = 19;
const int RISCV_X20 = 20;
const int RISCV_X21 = 21;
const int RISCV_X22 = 22;
const int RISCV_X23 = 23;
const int RISCV_X24 = 24;
const int RISCV_X25 = 25;
const int RISCV_X26 = 26;
const int RISCV_X27 = 27;
const int RISCV_X28 = 28;
const int RISCV_X29 = 29;
const int RISCV_X30 = 30;
const int RISCV_X31 = 31;
const int RISCV_F0 = 32;
const int RISCV_F1 = 33;
const int RISCV_F2 = 34;
const int RISCV_F3 = 35;
const int RISCV_F4 = 36;
const int RISCV_F5 = 37;
const int RISCV_F6 = 38;
const int RISCV_F7 = 39;
const int RISCV_F8 = 40;
const int RISCV_F9 = 41;
const int RISCV_F10 = 42;
const int RISCV_F11 = 43;
const int RISCV_F12 = 44;
const int RISCV_F13 = 45;
const int RISCV_F14 = 46;
const int RISCV_F15 = 47;
const int RISCV_F16 = 48;
const int RISCV_F17 = 49;
const int RISCV_F18 = 50;
const int RISCV_F19 = 51;
const int RISCV_F20 = 52;
const int RISCV_F21 = 53;
const int RISCV_F22 = 54;
const int RISCV_F23 = 55;
const int RISCV_F24 = 56;
const int RISCV_F25 = 57;
const int RISCV_F26 = 58;
const int RISCV_F27 = 59;
const int RISCV_F28 = 60;
const int RISCV_F29 = 61;
const int RISCV_F30 = 62;
const int RISCV_F31 = 63;
const int RISCV_MIE = 64;
const int RISCV_MSTATUS = 65;
const int RISCV_MTVEC = 66;
const int RISCV_MCAUSE = 67;
const int RISCV_MEPC = 68;
const int RISCV_MTVAL = 69;
const int RISCV_MSIP = 70;

const String[] RISCV_CLOBBER_NAMES = {
	"x0", // RISCV_X0
	"x1", // RISCV_X1
	"x2", // RISCV_X2
	"x3", // RISCV_X3
	"x4", // RISCV_X4
	"x5", // RISCV_X5
	"x6", // RISCV_X6
	"x7", // RISCV_X7
	"x8", // RISCV_X8
	"x9", // RISCV_X9
	"x10", // RISCV_X10
	"x11", // RISCV_X11
	"x12", // RISCV_X12
	"x13", // RISCV_X13
	"x14", // RISCV_X14
	"x15", // RISCV_X15
	"x16", // RISCV_X16
	"x17", // RISCV_X17
	"x18", // RISCV_X18
	"x19", // RISCV_X19
	"x20", // RISCV_X20
	"x21", // RISCV_X21
	"x22", // RISCV_X22
	"x23", // RISCV_X23
	"x24", // RISCV_X24
	"x25", // RISCV_X25
	"x26", // RISCV_X26
	"x27", // RISCV_X27
	"x28", // RISCV_X28
	"x29", // RISCV_X29
	"x30", // RISCV_X30
	"x31", // RISCV_X31
	"f0", // RISCV_F0
	"f1", // RISCV_F1
	"f2", // RISCV_F2
	"f3", // RISCV_F3
	"f4", // RISCV_F4
	"f5", // RISCV_F5
	"f6", // RISCV_F6
	"f7", // RISCV_F7
	"f8", // RISCV_F8
	"f9", // RISCV_F9
	"f10", // RISCV_F10
	"f11", // RISCV_F11
	"f12", // RISCV_F12
	"f13", // RISCV_F13
	"f14", // RISCV_F14
	"f15", // RISCV_F15
	"f16", // RISCV_F16
	"f17", // RISCV_F17
	"f18", // RISCV_F18
	"f19", // RISCV_F19
	"f20", // RISCV_F20
	"f21", // RISCV_F21
	"f22", // RISCV_F22
	"f23", // RISCV_F23
	"f24", // RISCV_F24
	"f25", // RISCV_F25
	"f26", // RISCV_F26
	"f27", // RISCV_F27
	"f28", // RISCV_F28
	"f29", // RISCV_F29
	"f30", // RISCV_F30
	"f31", // RISCV_F31
	"mie", // RISCV_MIE
	"mstatus", // RISCV_MSTATUS
	"mtvec", // RISCV_MTVEC
	"mcause", // RISCV_MCAUSE
	"mepc", // RISCV_MEPC
	"mtval", // RISCV_MTVAL
	"msip", // RISCV_MSIP
};
const String[] RISCV_GP_INTEGER_REGS = { "$x0", "$x1", "$x2", "$x3", "$x4", "$x5", "$x6", "$x7", "$x8", "$x9", "$x10", "$x11", "$x12", "$x13", "$x14", "$x15", "$x16", "$x17", "$x18", "$x19", "$x20", "$x21", "$x22", "$x23", "$x24", "$x25", "$x26", "$x27", "$x28", "$x29", "$x30", "$x31" };
const String[] RISCV_ARG_INTEGER_REGS = { "$a0", "$a1", "$a2", "$a3", "$a4", "$a5", "$a6", "$a7" };
const String[] RISCV_TEMP_INTEGER_REGS = { "$t0", "$t1", "$t2", "$t3", "$t4", "$t5", "$t6" };
const String[] RISCV_SAVE_INTEGER_REGS = { "$s0", "$s1", "$s2", "$s3", "$s4", "$s5", "$s6", "$s7", "$s8", "$s9", "$s10", "$s11" };
const String[] RISCV_FLOAT_REGS = { "$f0", "$f1", "$f2", "$f3", "$f4", "$f5", "$f6", "$f7", "$f8", "$f9", "$f10", "$f11", "$f12", "$f13", "$f14", "$f15", "$f16", "$f17", "$f18", "$f19", "$f20", "$f21", "$f22", "$f23", "$f24", "$f25", "$f26", "$f27", "$f28", "$f29", "$f30", "$f31" };
const String[] RISCV_MACHINE_INTEGER_REGS = { "$mie", "$mstatus", "$mtvec", "$mcause", "$mepc", "$mtval", "$msip" };


// ---------------------------------------------------------------------------
// asm/x86.h

const int X86_CC = 0;
const int X86_DF = 1;
const int X86_RAX = 2;
const int X86_RBX = 3;
const int X86_RCX = 4;
const int X86_RDX = 5;
const int X86_RSP = 6;
const int X86_RSI = 7;
const int X86_RDI = 8;
const int X86_R8 = 9;
const int X86_R9 = 10;
const int X86_R10 = 11;
const int X86_R11 = 12;
const int X86_R12 = 13;
const int X86_R13 = 14;
const int X86_R14 = 15;
const int X86_R15 = 16;
const int X86_XMM0 = 17;
const int X86_XMM1 = 18;
const int X86_XMM2 = 19;
const int X86_XMM3 = 20;
const int X86_XMM4 = 21;
const int X86_XMM5 = 22;
const int X86_XMM6 = 23;
const int X86_XMM7 = 24;
const int X86_XMM8 = 25;
const int X86_XMM9 = 26;
const int X86_XMM10 = 27;
const int X86_XMM11 = 28;
const int X86_XMM12 = 29;
const int X86_XMM13 = 30;
const int X86_XMM14 = 31;
const int X86_XMM15 = 32;
const int X86_K0 = 33;
const int X86_K1 = 34;
const int X86_K2 = 35;
const int X86_K3 = 36;
const int X86_K4 = 37;
const int X86_K5 = 38;
const int X86_K6 = 39;
const int X86_K7 = 40;
const int X86_ST0 = 41;
const int X86_ST1 = 42;
const int X86_ST2 = 43;
const int X86_ST3 = 44;
const int X86_ST4 = 45;
const int X86_ST5 = 46;
const int X86_ST6 = 47;
const int X86_ST7 = 48;
const int X86_MM0 = 49;
const int X86_MM1 = 50;
const int X86_MM2 = 51;
const int X86_MM3 = 52;
const int X86_MM4 = 53;
const int X86_MM5 = 54;
const int X86_MM6 = 55;
const int X86_MM7 = 56;
const int X86_TMM0 = 57;
const int X86_TMM1 = 58;
const int X86_TMM2 = 59;
const int X86_TMM3 = 60;
const int X86_TMM4 = 61;
const int X86_TMM5 = 62;
const int X86_TMM6 = 63;
const int X86_TMM7 = 64;
const int X86_CR0 = 65;
const int X86_CR2 = 66;
const int X86_CR3 = 67;
const int X86_CR4 = 68;

const String[] X86_CLOBBER_NAMES = {
	"cc", // X86_CC
	"", // X86_DF
	"rax", // X86_RAX
	"rbx", // X86_RBX
	"rcx", // X86_RCX
	"rdx", // X86_RDX
	"rsp", // X86_RSP
	"rsi", // X86_RSI
	"rdi", // X86_RDI
	"r8", // X86_R8
	"r9", // X86_R9
	"r10", // X86_R10
	"r11", // X86_R11
	"r12", // X86_R12
	"r13", // X86_R13
	"r14", // X86_R14
	"r15", // X86_R15
	"xmm0", // X86_XMM0
	"xmm1", // X86_XMM1
	"xmm2", // X86_XMM2
	"xmm3", // X86_XMM3
	"xmm4", // X86_XMM4
	"xmm5", // X86_XMM5
	"xmm6", // X86_XMM6
	"xmm7", // X86_XMM7
	"xmm8", // X86_XMM8
	"xmm9", // X86_XMM9
	"xmm10", // X86_XMM10
	"xmm11", // X86_XMM11
	"xmm12", // X86_XMM12
	"xmm13", // X86_XMM13
	"xmm14", // X86_XMM14
	"xmm15", // X86_XMM15
	"k0", // X86_K0
	"k1", // X86_K1
	"k2", // X86_K2
	"k3", // X86_K3
	"k4", // X86_K4
	"k5", // X86_K5
	"k6", // X86_K6
	"k7", // X86_K7
	"st0", // X86_ST0
	"st1", // X86_ST1
	"st2", // X86_ST2
	"st3", // X86_ST3
	"st4", // X86_ST4
	"st5", // X86_ST5
	"st6", // X86_ST6
	"st7", // X86_ST7
	"mm0", // X86_MM0
	"mm1", // X86_MM1
	"mm2", // X86_MM2
	"mm3", // X86_MM3
	"mm4", // X86_MM4
	"mm5", // X86_MM5
	"mm6", // X86_MM6
	"mm7", // X86_MM7
	"tmm0", // X86_TMM0
	"tmm1", // X86_TMM1
	"tmm2", // X86_TMM2
	"tmm3", // X86_TMM3
	"tmm4", // X86_TMM4
	"tmm5", // X86_TMM5
	"tmm6", // X86_TMM6
	"tmm7", // X86_TMM7
	"cr0", // X86_CR0
	"cr2", // X86_CR2
	"cr3", // X86_CR3
	"cr4", // X86_CR4
};

const String[] X64_QUAD_REGS = { "$rax", "$rbx", "$rcx", "$rdx", "$rsp", "$rbp", "$rsi", "$rdi", "$r8", "$r9", "$r10", "$r11", "$r12", "$r13", "$r14", "$r15" };
const String[] X86_LONG_REGS = { "$eax", "$ebx", "$ecx", "$edx", "$esp", "$ebp", "$esi", "$edi", "$r8d", "$r9d", "$r10d", "$r11d", "$r12d", "$r13d", "$r14d", "$r15d" };
const String[] X86_WORD_REGS = { "$ax", "$bx", "$cx", "$dx", "$sp", "$bp", "$si", "$di", "$r8w", "$r9w", "$r10w", "$r11w", "$r12w", "$r13w", "$r14w", "$r15w" };
const String[] X86_LOW_BYTE_REGS = { "$al", "$bl", "$cl", "$dl", "$spl", "$bpl", "$sil", "$dil", "$r8b", "$r9b", "$r10b", "$r11b", "$r12b", "$r13b", "$r14b", "$r15b" };
const String[] X86_HIGH_BYTE_REGS = { "$ah", "$bh", "$ch", "$dh" };
const String[] X86_FLOAT_REGS = { "$st0", "$st1", "$st2", "$st3", "$st4", "$st5", "$st6", "$st7" };
const String[] X86_XMM_REGS = { "$xmm0", "$xmm1", "$xmm2", "$xmm3", "$xmm4", "$xmm5", "$xmm6", "$xmm7", "$xmm8", "$xmm9", "$xmm10", "$xmm11", "$xmm12", "$xmm13", "$xmm14", "$xmm15" };
const String[] X86_YMM_REGS = { "$ymm0", "$ymm1", "$ymm2", "$ymm3", "$ymm4", "$ymm5", "$ymm6", "$ymm7", "$ymm8", "$ymm9", "$ymm10", "$ymm11", "$ymm12", "$ymm13", "$ymm14", "$ymm15" };
const String[] X86_ZMM_REGS = { "$zmm0", "$zmm1", "$zmm2", "$zmm3", "$zmm4", "$zmm5", "$zmm6", "$zmm7", "$zmm8", "$zmm9", "$zmm10", "$zmm11", "$zmm12", "$zmm13", "$zmm14", "$zmm15" };
const String[] X86_CONTROL_REGS = { "$cr0", "$cr2", "$cr3", "$cr4" };

// ---------------------------------------------------------------------------
// asm_target.c

macro uint @asm_ptr_hash(String name) => (uint)(((uptr)name.ptr * 31) ^ ((uptr)name.ptr >> 15));

const Clobbers NO_CLOBBER = { .mask[0] = 0 };

fn AsmInstruction* insert_instruction_named(PlatformTarget* target, String name) @local
{
	TokenType token_type = IDENT;
	String interned = symtab_add(name, &token_type);
	uint hash = @asm_ptr_hash(interned);
	uint slot = hash & ASM_INSTRUCTION_MASK;
	while (true)
	{
		AsmInstruction* instr = &target.instructions[slot];
		if (!instr.name.ptr)
		{
			instr.name = interned;
			return instr;
		}
		slot = (slot + 1) & ASM_INSTRUCTION_MASK;
	}
}

<* The char at `index` of the descriptor, 0 past its end (c3c's NUL). *>
fn char desc_at(String desc, usz index) @local @inline => index < desc.len ? desc[index] : 0;

fn void desc_skip(String* desc, usz count) @local @inline
{
	*desc = count >= desc.len ? "" : (*desc)[count..];
}

fn AsmArgBits parse_bits(String* desc) @local
{
	if (desc.starts_with("80"))
	{
		desc_skip(desc, 2);
		return ARG_BITS_80;
	}
	if (desc.starts_with("8"))
	{
		desc_skip(desc, 1);
		return ARG_BITS_8;
	}
	if (desc.starts_with("16"))
	{
		desc_skip(desc, 2);
		return ARG_BITS_16;
	}
	if (desc.starts_with("20"))
	{
		desc_skip(desc, 2);
		return ARG_BITS_20;
	}
	if (desc.starts_with("32"))
	{
		desc_skip(desc, 2);
		return ARG_BITS_32;
	}
	if (desc.starts_with("64"))
	{
		desc_skip(desc, 2);
		return ARG_BITS_64;
	}
	if (desc.starts_with("128"))
	{
		desc_skip(desc, 3);
		return ARG_BITS_128;
	}
	if (desc.starts_with("12"))
	{
		desc_skip(desc, 2);
		return ARG_BITS_12;
	}
	if (desc.starts_with("256"))
	{
		desc_skip(desc, 3);
		return ARG_BITS_256;
	}
	if (desc.starts_with("512"))
	{
		desc_skip(desc, 3);
		return ARG_BITS_512;
	}
	if (desc.starts_with("5"))
	{
		desc_skip(desc, 1);
		return ARG_BITS_5;
	}
	@error_exit("Invalid bits: %s.", *desc);
}

fn AsmArgType decode_arg_type(String* desc) @local
{
	AsmArgType arg_type = { .is_readwrite = false };
	if (desc_at(*desc, 0) == 'w')
	{
		arg_type.is_write = true;
		assert(desc_at(*desc, 1) == ':');
		desc_skip(desc, 2);
	}
	else if (desc_at(*desc, 0) == 'r' && desc_at(*desc, 1) == 'w')
	{
		arg_type.is_readwrite = true;
		arg_type.is_write = true;
		assert(desc_at(*desc, 2) == ':');
		desc_skip(desc, 3);
	}
	while (true)
	{
		char c = desc_at(*desc, 0);
		desc_skip(desc, 1);
		if (c == 0 || c == ',') break;
		switch (c)
		{
			case 'r':
				arg_type.ireg_bits |= parse_bits(desc);
			case 'm':
				if (!desc.starts_with("em")) @error_exit("Unexpected string m%s", *desc);
				arg_type.is_address = true;
				desc_skip(desc, 2);
			case 'v':
				arg_type.vec_bits |= parse_bits(desc);
			case 'i':
				if (!desc.starts_with("mm")) @error_exit("Unexpected string 'i%s'.", *desc);
				desc_skip(desc, 2);
				c = desc_at(*desc, 0);
				if (c == 'i')
				{
					desc_skip(desc, 1);
					arg_type.imm_arg_ibits |= parse_bits(desc);
					break;
				}
				if (c == 'u')
				{
					desc_skip(desc, 1);
					arg_type.imm_arg_ubits |= parse_bits(desc);
					break;
				}
				AsmArgBits bits = parse_bits(desc);
				arg_type.imm_arg_ibits |= bits;
				arg_type.imm_arg_ubits |= bits;
			default:
				@error_exit("Unexpected string '%c%s'.", c, *desc);
		}
		// NEXT:
		switch (desc_at(*desc, 0))
		{
			case '/':
				desc_skip(desc, 1);
				continue;
			case ',':
				desc_skip(desc, 1);
				while (desc_at(*desc, 0) == ' ') desc_skip(desc, 1);
				return arg_type;
			case 0:
				return arg_type;
			default:
				@error_exit("Expected '/' or end: '%s'.", *desc);
		}
	}
	return arg_type;
}

fn void reg_instr_clob(PlatformTarget* target, String name, Clobbers mask, String args) @local
{
	AsmInstruction* instr = insert_instruction_named(target, name);
	instr.mask = mask;
	int param_count = 0;
	while (args.len > 0)
	{
		assert(param_count <= MAX_ASM_INSTRUCTION_PARAMS);
		instr.param[param_count++] = decode_arg_type(&args);
	}
	instr.param_count = param_count;
}

fn void reg_instr(PlatformTarget* target, String name, String args) @local
{
	AsmInstruction* instr = insert_instruction_named(target, name);
	instr.mask = NO_CLOBBER;
	int param_count = 0;
	while (args.len > 0)
	{
		assert(param_count <= MAX_ASM_INSTRUCTION_PARAMS);
		instr.param[param_count++] = decode_arg_type(&args);
	}
	instr.param_count = param_count;
}

fn void reg_register(PlatformTarget* target, String name, AsmRegisterType reg_type, AsmArgBits bits, uint clobber_id) @local
{
	TokenType token_type = CT_IDENT;
	String interned = symtab_add(name, &token_type);
	uint hash = @asm_ptr_hash(interned);
	uint slot = hash & ASM_REGISTER_MASK;
	while (true)
	{
		AsmRegister* reg = &target.registers[slot];
		if (!reg.name.ptr)
		{
			*reg = { .name = interned, .type = reg_type, .bits = bits, .clobber_index = (int)clobber_id };
			target.register_count++;
			return;
		}
		slot = (slot + 1) & ASM_REGISTER_MASK;
	}
}

fn void reg_register_list(PlatformTarget* target, String[] names, int count, AsmRegisterType param, int bitsize, int first_clobber) @local
{
	for (int i = 0; i < count; i++) reg_register(target, names[i], param, bitsize, (uint)(i + first_clobber));
}

// asm_target.c:223
fn AsmInstruction* asm_instr_by_name(String name)
{
	uint hash = @asm_ptr_hash(name);
	uint slot = hash & ASM_INSTRUCTION_MASK;
	while (true)
	{
		AsmInstruction* inst = &compiler.platform.instructions[slot];
		if (inst.name.ptr == name.ptr) return inst;
		if (inst.name.ptr == null) return null;
		slot = (slot + 1) & ASM_INSTRUCTION_MASK;
	}
}

// asm_target.c:238
<*
 Whether a clobber is a register a compiler allocates. The RISC-V machine CSRs (mstatus, ...) are clobbers C3 tracks,
 but not register names a C compiler accepts in an asm clobber list.
*>
fn bool asm_clobber_is_register(int index)
{
	if (compiler.platform.clobber_name_list.ptr == RISCV_CLOBBER_NAMES.ptr) return index <= RISCV_F31;
	return true;
}

// asm_target.c:244
fn AsmRegister* asm_reg_by_name(PlatformTarget* target, String name)
{
	uint hash = @asm_ptr_hash(name);
	uint slot = hash & ASM_REGISTER_MASK;
	while (true)
	{
		AsmRegister* reg = &target.registers[slot];
		String reg_name = reg.name;
		if (reg_name.ptr == name.ptr) return reg;
		if (!reg_name.ptr) return null;
		slot = (slot + 1) & ASM_REGISTER_MASK;
	}
}

fn void init_asm_unsupported(PlatformTarget* target, String arch) @local
{
	@error_exit("%s inline asm is not supported yet, only x86 / x86_64.", arch);
}

// asm_target.c:428 (static)
fn void init_asm_riscv(PlatformTarget* target) @local
{
	target.clobber_name_list = RISCV_CLOBBER_NAMES;
	target.extra_clobbers = {};
	int bits = 0;
	switch (target.arch)
	{
		case RISCV64:
			// math
			reg_instr(target, "add", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "sub", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "addi", "w:r64/mem, r64/mem, immi12");
			reg_instr(target, "neg", "w:r64/mem, r64/mem");
			// bit
			reg_instr(target, "and", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "or", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "xor", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "not", "w:r64/mem, r64/mem");
			reg_instr(target, "andi", "w:r64/mem, r64/mem, immi12");
			reg_instr(target, "ori", "w:r64/mem, r64/mem, immi12");
			reg_instr(target, "xori", "w:r64/mem, r64/mem, immi12");
			// shift
			reg_instr(target, "sll", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "srl", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "sra", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "slli", "w:r64/mem, r64/mem, immu5");
			reg_instr(target, "srli", "w:r64/mem, r64/mem, immu5");
			reg_instr(target, "srai", "w:r64/mem, r64/mem, immu5");
			// load
			reg_instr(target, "li", "w:r64/mem, immi64");
			reg_instr(target, "lui", "w:r64, immu20");
			reg_instr(target, "auipc", "w:r64, immu20");
			reg_instr(target, "mv", "w:r64/mem, r64/mem");
			reg_instr(target, "ld", "w:r64/mem, mem");
			reg_instr(target, "lw", "w:r64/mem, mem");
			reg_instr(target, "lh", "w:r64/mem, mem");
			reg_instr(target, "lhu", "w:r64/mem, mem");
			reg_instr(target, "lb", "w:r64/mem, mem");
			reg_instr(target, "lbu", "w:r64/mem, mem");
			// store
			reg_instr(target, "sd", "r64/mem, w:mem");
			reg_instr(target, "sw", "r64/mem, w:mem");
			reg_instr(target, "sh", "r64/mem, w:mem");
			reg_instr(target, "sb", "r64/mem, w:mem");
			// Misc
			reg_instr(target, "nop", "");
			reg_instr(target, "ebreak", "");
			reg_instr(target, "ecall", "");
			reg_instr(target, "eret", "");
			// Jump
			reg_instr(target, "j", "immi20");
			reg_instr(target, "jal", "w:r64/mem, immi20");
			reg_instr(target, "jalr", "w:r64/mem, r64/mem, immi20");
			reg_instr(target, "ret", "");
			// Set
			reg_instr(target, "slt", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "slti", "w:r64/mem, r64/mem, immi12");
			reg_instr(target, "sltu", "w:r64/mem, r64/mem, r64/mem");
			reg_instr(target, "sltiu", "w:r64/mem, r64/mem, immu12");
			reg_instr(target, "seqz", "w:r64/mem, r64/mem");
			reg_instr(target, "snez", "w:r64/mem, r64/mem");
			reg_instr(target, "sltz", "w:r64/mem, r64/mem");
			reg_instr(target, "sgtz", "w:r64/mem, r64/mem");
			// CSR
			reg_instr(target, "csrw", "w:r64/immu12, r64/mem");
			reg_instr(target, "csrr", "w:r64/mem, r64/immu12");
			reg_instr(target, "csrrw", "w:r64/mem, rw:r64/immu12, r64/mem");
			reg_instr(target, "csrrs", "w:r64/mem, rw:r64/immu12, r64/mem");
			reg_instr(target, "csrrc", "w:r64/mem, rw:r64/immu12, r64/mem");
			reg_instr(target, "csrrwi", "w:r64/mem, rw:r64/immu12, immu5");
			reg_instr(target, "csrrsi", "w:r64/mem, rw:r64/immu12, immu5");
			reg_instr(target, "csrrci", "w:r64/mem, rw:r64/immu12, immu5");
			// Interrupt
			reg_instr(target, "wfi", "");
			reg_instr(target, "mret", "");

			bits = ARG_BITS_64;
		case RISCV32:
			// math
			reg_instr(target, "add", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "sub", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "addi", "w:r32/mem, r32/mem, immi12");
			reg_instr(target, "neg", "w:r32/mem, r32/mem");
			// bit
			reg_instr(target, "and", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "or", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "xor", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "not", "w:r32/mem, r32/mem");
			reg_instr(target, "andi", "w:r32/mem, r32/mem, immi12");
			reg_instr(target, "ori", "w:r32/mem, r32/mem, immi12");
			reg_instr(target, "xori", "w:r32/mem, r32/mem, immi12");
			// shift
			reg_instr(target, "sll", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "srl", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "sra", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "slli", "w:r32/mem, r32/mem, immu5");
			reg_instr(target, "srli", "w:r32/mem, r32/mem, immu5");
			reg_instr(target, "srai", "w:r32/mem, r32/mem, immu5");
			// load
			reg_instr(target, "li", "w:r32/mem, immi32");
			reg_instr(target, "lui", "w:r32, immu20");
			reg_instr(target, "auipc", "w:r32, immu20");
			reg_instr(target, "mv", "w:r32/mem, r32/mem");
			reg_instr(target, "lw", "w:r32/mem, mem");
			reg_instr(target, "lh", "w:r32/mem, mem");
			reg_instr(target, "lhu", "w:r32/mem, mem");
			reg_instr(target, "lb", "w:r32/mem, mem");
			reg_instr(target, "lbu", "w:r32/mem, mem");
			// store
			reg_instr(target, "sw", "r32/mem, w:mem");
			reg_instr(target, "sh", "r32/mem, w:mem");
			reg_instr(target, "sb", "r32/mem, w:mem");
			// Misc
			reg_instr(target, "nop", "");
			reg_instr(target, "ebreak", "");
			reg_instr(target, "ecall", "");
			reg_instr(target, "eret", "");
			// Jump
			reg_instr(target, "j", "immi20");
			reg_instr(target, "jal", "w:r32/mem, immi20");
			reg_instr(target, "jalr", "w:r32/mem, r32/mem, immi20");
			reg_instr(target, "ret", "");
			// Set
			reg_instr(target, "slt", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "slti", "w:r32/mem, r32/mem, immi12");
			reg_instr(target, "sltu", "w:r32/mem, r32/mem, r32/mem");
			reg_instr(target, "sltiu", "w:r32/mem, r32/mem, immu12");
			reg_instr(target, "seqz", "w:r32/mem, r32/mem");
			reg_instr(target, "snez", "w:r32/mem, r32/mem");
			reg_instr(target, "sltz", "w:r32/mem, r32/mem");
			reg_instr(target, "sgtz", "w:r32/mem, r32/mem");
			// CSR
			reg_instr(target, "csrw", "w:r32/immu12, r32/mem");
			reg_instr(target, "csrr", "w:r32/mem, r32/immu12");
			reg_instr(target, "csrrw", "w:r32/mem, rw:r32/immu12, r32/mem");
			reg_instr(target, "csrrs", "w:r32/mem, rw:r32/immu12, r32/mem");
			reg_instr(target, "csrrc", "w:r32/mem, rw:r32/immu12, r32/mem");
			reg_instr(target, "csrrwi", "w:r32/mem, rw:r32/immu12, immu5");
			reg_instr(target, "csrrsi", "w:r32/mem, rw:r32/immu12, immu5");
			reg_instr(target, "csrrci", "w:r32/mem, rw:r32/immu12, immu5");
			// Interrupt
			reg_instr(target, "wfi", "");
			reg_instr(target, "mret", "");

			bits = ARG_BITS_32;
		default:
			unreachable();
	}
	reg_register_list(target, RISCV_GP_INTEGER_REGS, 32, REG_INT, bits, RISCV_X0);
	reg_register_list(target, RISCV_ARG_INTEGER_REGS, 8, REG_INT, bits, RISCV_X10);
	reg_register_list(target, RISCV_TEMP_INTEGER_REGS, 3, REG_INT, bits, RISCV_X5);
	reg_register_list(target, RISCV_TEMP_INTEGER_REGS[3..], 4, REG_INT, bits, RISCV_X28);
	reg_register_list(target, RISCV_SAVE_INTEGER_REGS, 2, REG_INT, bits, RISCV_X8);
	reg_register_list(target, RISCV_SAVE_INTEGER_REGS[2..], 10, REG_INT, bits, RISCV_X18);
	reg_register_list(target, RISCV_MACHINE_INTEGER_REGS, 3, REG_INT, bits, RISCV_MIE);
	reg_register(target, "$ra", REG_INT, bits, RISCV_X1);
	reg_register(target, "$sp", REG_INT, bits, RISCV_X2);
	reg_register(target, "$gp", REG_INT, bits, RISCV_X3);
	reg_register(target, "$tp", REG_INT, bits, RISCV_X4);
	reg_register(target, "$zero", REG_INT, bits, RISCV_X0);
}

// asm_target.c:596 (static)
fn void init_asm_x86(PlatformTarget* target) @local
{
	Clobbers rax_mask = clobbers_make(X86_RAX);
	Clobbers cc_flag_mask = clobbers_make(X86_CC);
	Clobbers rax_cc_mask = clobbers_make_from(cc_flag_mask, X86_RAX);
	Clobbers rcx_cc_mask = clobbers_make_from(cc_flag_mask, X86_RCX);
	Clobbers rax_rdx_cc_mask = clobbers_make_from(cc_flag_mask, X86_RAX, X86_RDX);
	Clobbers xmm_0_7_cc_mask = clobbers_make_from(cc_flag_mask, X86_XMM0, X86_XMM1, X86_XMM2, X86_XMM3, X86_XMM4, X86_XMM5, X86_XMM6, X86_XMM7);
	Clobbers xmm_0_2_xmm_4_6_cc_mask = clobbers_make_from(cc_flag_mask, X86_XMM0, X86_XMM1, X86_XMM2, X86_XMM4, X86_XMM5, X86_XMM6);
	Clobbers xmm_0_6_cc_mask = clobbers_make_from(cc_flag_mask, X86_XMM0, X86_XMM1, X86_XMM2, X86_XMM3, X86_XMM4, X86_XMM5, X86_XMM6);
	Clobbers xmm0_mask = clobbers_make(X86_XMM0);
	Clobbers xmm0_cc_mask = clobbers_make_from(cc_flag_mask, X86_XMM0);
	Clobbers rax_xmm0_cc_mask = clobbers_make_from(cc_flag_mask, X86_RAX, X86_XMM0);
	Clobbers lo16_vec_mask = clobbers_make(X86_XMM0, X86_XMM1, X86_XMM2, X86_XMM3, X86_XMM4, X86_XMM5, X86_XMM6, X86_XMM7,
			X86_XMM8, X86_XMM9, X86_XMM10, X86_XMM11, X86_XMM12, X86_XMM13, X86_XMM14, X86_XMM15);



	bool is_x64 = target.arch == ArchType.X86_64;
	if (!is_x64)
	{
		reg_instr_clob(target, "aaa", rax_mask, "");
		reg_instr_clob(target, "into", cc_flag_mask, "");
		reg_instr(target, "pushl", "r32/mem/imm32");
		reg_instr(target, "popl", "w:r32/mem/imm32");
	}
	if (is_x64)
	{
		reg_instr_clob(target, "syscall", clobbers_make_from(cc_flag_mask, X86_RAX, X86_R11, X86_RCX), "");
		reg_instr(target, "pushq", "r64/mem");
		reg_instr(target, "popq", "w:r64/mem");
	}
	reg_instr_clob(target, "adcb", cc_flag_mask, "rw:r8/mem, r8/mem/imm8");
	reg_instr_clob(target, "adcw", cc_flag_mask, "rw:r16/mem, r16/mem/imm16/immi8");
	reg_instr_clob(target, "adcl", cc_flag_mask, "rw:r32/mem, r32/mem/imm32/immi8");
	reg_instr_clob(target, "adcq", cc_flag_mask, "rw:r64/mem, r64/mem/immi32/immi8");

	reg_instr_clob(target, "addb", cc_flag_mask, "rw:r8/mem, r8/mem/imm8");
	reg_instr_clob(target, "addw", cc_flag_mask, "rw:r16/mem, r16/mem/imm16/immi8");
	reg_instr_clob(target, "addl", cc_flag_mask, "rw:r32/mem, r32/mem/imm32/immi8");
	reg_instr_clob(target, "addq", cc_flag_mask, "rw:r64/mem, r64/mem/immi32/immi8");

	reg_instr(target, "addpd", "rw:v128, v128/mem");
	reg_instr(target, "addps", "rw:v128, v128/mem");
	reg_instr(target, "addsd", "rw:v128, v128/mem");
	reg_instr(target, "addss", "rw:v128, v128/mem");
	reg_instr(target, "vaddpd", "w:v128/v256/v512, v128/v256/v512, v128/v256/v512/mem");
	reg_instr(target, "vaddps", "w:v128/v256/v512, v128/v256/v512, v128/v256/v512/mem");
	reg_instr(target, "vaddsd", "w:v128, v128, v128/mem");
	reg_instr(target, "vaddss", "w:v128, v128, v128/mem");
	reg_instr(target, "bswapl", "rw:r32");
	reg_instr(target, "bswapq", "rw:r64");
	reg_instr_clob(target, "cbtw", rax_mask, "");
	reg_instr_clob(target, "cwtl", rax_mask, "");
	reg_instr_clob(target, "cltq", rax_mask, "");
	reg_instr_clob(target, "clc", rax_mask, "");
	reg_instr_clob(target, "cld", rax_mask, "");
	reg_instr(target, "clflush", "mem");
	reg_instr(target, "cmovaw", "w:r16, r16/mem");
	reg_instr(target, "cmoval", "w:r32, r32/mem");
	reg_instr(target, "cmovaq", "w:r64, r64/mem");
	reg_instr(target, "cmovaew", "w:r16, r16/mem");
	reg_instr(target, "cmovael", "w:r32, r32/mem");
	reg_instr(target, "cmovaeq", "w:r64, r64/mem");
	reg_instr(target, "cmovbw", "w:r16, r16/mem");
	reg_instr(target, "cmovbl", "w:r32, r32/mem");
	reg_instr(target, "cmovbq", "w:r64, r64/mem");
	reg_instr(target, "cmovbew", "w:r16, r16/mem");
	reg_instr(target, "cmovbel", "w:r32, r32/mem");
	reg_instr(target, "cmovbeq", "w:r64, r64/mem");
	reg_instr_clob(target, "cmpxchgb", rax_cc_mask,   "rw:r8/mem, r8");
	reg_instr_clob(target, "cmpxchgl", rax_cc_mask,   "rw:r16/mem, r16");
	reg_instr_clob(target, "cmpxchgw", rax_cc_mask,   "rw:r32/mem, r32");
	reg_instr_clob(target, "cmpxchgq", rax_cc_mask,   "rw:r64/mem, r64");
	reg_instr_clob(target, "cmpxchg8b", rax_cc_mask,  "rw:r64/mem");
	reg_instr_clob(target, "cmpxchg16b", rax_cc_mask, "rw:r64/mem");
	reg_instr_clob(target, "decb", cc_flag_mask, "r8/mem");
	reg_instr_clob(target, "decw", cc_flag_mask, "r16/mem");
	reg_instr_clob(target, "decl", cc_flag_mask, "r32/mem");
	reg_instr_clob(target, "decq", cc_flag_mask, "r64/mem");
	reg_instr_clob(target, "divb",  rax_rdx_cc_mask, "r8/mem");
	reg_instr_clob(target, "divw",  rax_rdx_cc_mask, "r16/mem");
	reg_instr_clob(target, "divl",  rax_rdx_cc_mask, "r32/mem");
	reg_instr_clob(target, "divq",  rax_rdx_cc_mask, "r64/mem");
	reg_instr_clob(target, "idivb", rax_rdx_cc_mask, "r8/mem");
	reg_instr_clob(target, "idivw", rax_rdx_cc_mask, "r16/mem");
	reg_instr_clob(target, "idivl", rax_rdx_cc_mask, "r32/mem");
	reg_instr_clob(target, "idivq", rax_rdx_cc_mask, "r64/mem");

	reg_instr(target, "movb", "w:r8/mem, r8/mem/imm8");
	reg_instr(target, "movsbw", "w:r16/mem, r8/mem");
	reg_instr(target, "movzbw", "w:r16/mem, r8/mem");
	reg_instr(target, "movsbl", "w:r32/mem, r8/mem");
	reg_instr(target, "movzbl", "w:r32/mem, r8/mem");
	reg_instr(target, "movsbq", "w:r64/mem, r8/mem");
	reg_instr(target, "movzbq", "w:r64/mem, r8/mem");
	reg_instr(target, "movw", "w:r16/mem, r16/mem/imm16"); // Add seg
	reg_instr(target, "movswl", "w:r32/mem, r16/mem");
	reg_instr(target, "movzwl", "w:r32/mem, r16/mem");
	reg_instr(target, "movswq", "w:r64/mem, r16/mem");
	reg_instr(target, "movzwq", "w:r64/mem, r16/mem");
	reg_instr(target, "movl", "w:r32/mem, r32/mem/imm32");
	reg_instr(target, "movslq", "w:r64/mem, r32/mem");
	reg_instr(target, "movzlq", "w:r64/mem, r32/mem");
	reg_instr(target, "movq", "w:r64/mem, r64/mem/immi32/imm64"); // Seg
	//reg_instr("mov", "wAARG_SEG | AARG_W, AARG_R16 | AARG_R64, ""); // Seg
	/*
	reg_instr("movabsb", AARG_R8 | AARG_IMM64, AARG_R8 | AARG_IMM64, ""); // Missing segment
	reg_instr("movawsw", AARG_R16 | AARG_IMM64, AARG_R16 | AARG_IMM64, ""); // Missing segment
	reg_instr("movalsl", AARG_R32 | AARG_IMM64, AARG_R32 | AARG_IMM64, ""); // Missing segment
	reg_instr("movaqsq", AARG_R64 | AARG_IMM64, AARG_R64 | AARG_IMM64, ""); // Missing segment*/
	reg_instr(target, "nop", "");
	reg_instr(target, "nopw", "");
	reg_instr(target, "nopl", "");
	reg_instr_clob(target, "orb", cc_flag_mask, "rw:r8/mem, r8/mem/imm8");
	reg_instr_clob(target, "orw", cc_flag_mask, "rw:r16/mem, r16/mem/imm16");
	reg_instr_clob(target, "orl", cc_flag_mask, "rw:r32/mem, r32/mem/imm32");
	reg_instr_clob(target, "orq", cc_flag_mask, "rw:r64/mem, r64/mem/immi32/imm64");
	reg_instr_clob(target, "negb", cc_flag_mask, "rw:r8/mem");
	reg_instr_clob(target, "negw", cc_flag_mask, "rw:r16/mem");
	reg_instr_clob(target, "negl", cc_flag_mask, "rw:r32/mem");
	reg_instr_clob(target, "negq", cc_flag_mask, "rw:r64/mem");
	reg_instr(target, "notb", "rw:r8/mem");
	reg_instr(target, "notw", "rw:r16/mem");
	reg_instr(target, "notl", "rw:r32/mem");
	reg_instr(target, "notq", "rw:r64/mem");
	reg_instr_clob(target, "xorb", cc_flag_mask, "rw:r8/mem, r8/mem/imm8");
	reg_instr_clob(target, "xorw", cc_flag_mask, "rw:r16/mem, r16/mem/imm16");
	reg_instr_clob(target, "xorl", cc_flag_mask, "rw:r32/mem, r32/mem/imm32");
	reg_instr_clob(target, "xorq", cc_flag_mask, "rw:r64/mem, r64/mem/immi32/imm64");
	reg_instr_clob(target, "mulb", rax_cc_mask, "r8/mem");
	reg_instr_clob(target, "mulw", rax_rdx_cc_mask, "r16/mem");
	reg_instr_clob(target, "mull", rax_rdx_cc_mask, "r32/mem");
	reg_instr_clob(target, "mulq", rax_rdx_cc_mask, "rw:r64/mem");
	reg_instr_clob(target, "subb", rax_cc_mask, "rw:r8/mem, r8/mem/imm8");
	reg_instr_clob(target, "subw", rax_cc_mask, "rw:r16/mem, r16/mem/imm16");
	reg_instr_clob(target, "subl", rax_cc_mask, "rw:r32/mem, r32/mem/imm32");
	reg_instr_clob(target, "subq", rax_cc_mask, "rw:r64/mem, r64/mem/immi32/imm64");
	reg_instr_clob(target, "cpuid",  clobbers_make_from(cc_flag_mask, X86_RAX, X86_RBX, X86_RCX, X86_RDX), "");
	reg_instr(target, "hlt", "");
	reg_instr(target, "in", "w:r8/r16/r32, r16/imm8"); // Actually ensure reg_al_ax and dx
	reg_instr_clob(target, "incb", cc_flag_mask, "rw:r8/mem");
	reg_instr_clob(target, "incw", cc_flag_mask, "rw:r16/mem");
	reg_instr_clob(target, "incl", cc_flag_mask, "rw:r32/mem");
	reg_instr_clob(target, "incq", cc_flag_mask, "rw:r64/mem");
	reg_instr(target, "insb", "");
	reg_instr(target, "insw", "");
	reg_instr(target, "insl", "");
	reg_instr_clob(target, "int", cc_flag_mask, "imm8");
	reg_instr_clob(target, "int3", cc_flag_mask, "");
	reg_instr_clob(target, "int1", cc_flag_mask, "");
	reg_instr(target, "invd", "");
	reg_instr(target, "invpcid", "r32/r64, mem");
	reg_instr(target, "invlpg", "w:mem");
	reg_instr(target, "invlpga", "r32, r64"); // c, a check this one!
	reg_instr(target, "iret", "");
	reg_instr(target, "iretl", "");
	reg_instr(target, "iretw", "");
	reg_instr(target, "iretq", "");
	reg_instr_clob(target, "rdtsc",  clobbers_make_from(rax_mask, X86_RDX), "");
	reg_instr_clob(target, "rdtscp",  clobbers_make_from(rax_mask, X86_RDX, X86_RCX), "");
	reg_instr(target, "ret", "");
	reg_instr(target, "push", "imm8");
	reg_instr(target, "pushw", "r16/mem/imm16");
	reg_instr(target, "popw", "w:r16/mem");

	reg_instr(target, "stui", "");
	reg_instr(target, "clui", "");
	reg_instr(target, "senduipi", "r64");
	reg_instr(target, "uiret", "");

	reg_instr_clob(target, "xaddb", cc_flag_mask, "rw:r8/mem,  rw:r8");
	reg_instr_clob(target, "xaddw", cc_flag_mask, "rw:r16/mem, rw:r16");
	reg_instr_clob(target, "xaddl", cc_flag_mask, "rw:r32/mem, rw:r32");
	reg_instr_clob(target, "xaddq", cc_flag_mask, "rw:r64/mem, rw:r64");
	reg_instr(target, "xchgb", "rw:r8/mem, rw:r8/mem");
	reg_instr(target, "xchgw", "rw:r16/mem, rw:r16/mem");
	reg_instr(target, "xchgl", "rw:r32/mem, rw:r32/mem");
	reg_instr(target, "xchgq", "rw:r64/mem, rw:r64/mem");

	reg_instr_clob(target, "xgetbv", rax_rdx_cc_mask , "");

	// BMI1
	reg_instr_clob(target, "andn", cc_flag_mask, "w:r32/r64, r32/r64, r32/r64/mem");
	reg_instr_clob(target, "bextr", cc_flag_mask, "w:r32/r64, r32/r64/mem, r32/r64");
	reg_instr_clob(target, "blsi", cc_flag_mask, "w:r32/r64, r32/r64/mem");
	reg_instr_clob(target, "blsmsk", cc_flag_mask, "w:r32/r64, r32/r64/mem");
	reg_instr_clob(target, "blsr", cc_flag_mask, "w:r32/r64, r32/r64/mem");
	reg_instr_clob(target, "tzcnt", cc_flag_mask, "w:r16/r32/r64, r16/r32/r64/mem");

	// LZCNT
	reg_instr_clob(target, "lzcnt", cc_flag_mask, "w:r16/r32/r64, r16/r32/r64/mem");

	// BMI2
	reg_instr(target, "bzhi", "w:r32/r64, r32/r64/mem, r32/r64");
	reg_instr(target, "mulx", "w:r32/r64, r32/r64, r32/r64/mem");
	reg_instr(target, "pdep", "w:r32/r64, r32/r64, r32/r64/mem");
	reg_instr(target, "pext", "w:r32/r64, r32/r64, r32/r64/mem");
	reg_instr(target, "rorx", "w:r32/r64, r32/r64/mem, imm8");
	reg_instr(target, "sarx", "w:r32/r64, r32/r64/mem, r32/r64");
	reg_instr(target, "shlx", "w:r32/r64, r32/r64/mem, r32/r64");
	reg_instr(target, "shrx", "w:r32/r64, r32/r64/mem, r32/r64");

	// ADX
	reg_instr_clob(target, "adcx", cc_flag_mask, "rw:r32/r64, r32/r64/mem");
	reg_instr_clob(target, "adox", cc_flag_mask, "rw:r32/r64, r32/r64/mem");

	// PCLMULQDQ
	reg_instr(target, "pclmulqdq", "rw:v128, v128/mem, imm8");
	reg_instr(target, "vpclmulqdq", "w:v128/v256/v512, v128/v256/v512, v128/v256/v512/mem, imm8");

	// SSE4.2 and VEX versions (no EVEX PCMPGTQ)
	// Wish I could split crc32[l,q] here since it's got weird encodings, but AT&T does it's suffixes off of
	// the source here, which I thought was worse. Ideally this has no suffixes anyway.
	reg_instr_clob(target, "crc32", cc_flag_mask, "rw:r32/r64, r8/r16/r32/r64/mem");
	reg_instr_clob(target, "pcmpestri", rcx_cc_mask, "v128, v128, imm8");
	reg_instr_clob(target, "vpcmpestri", rcx_cc_mask, "v128, v128, imm8");
	reg_instr_clob(target, "pcmpestrm", xmm0_cc_mask, "v128, v128, imm8");
	reg_instr_clob(target, "vpcmpestrm", xmm0_cc_mask, "v128, v128, imm8");
	reg_instr_clob(target, "pcmpistri", rcx_cc_mask, "v128, v128, imm8");
	reg_instr_clob(target, "vpcmpistri", rcx_cc_mask, "v128, v128, imm8");
	reg_instr_clob(target, "popcnt", cc_flag_mask, "w:r16/r32/r64, r16/r32/r64/mem");
	reg_instr(target, "pcmpgtq", "rw:v128, v128/mem");
	reg_instr(target, "vpcmpgtq", "w:v128/v256, v128/v256, v128/v256/mem");

	// VZERO*
	reg_instr_clob(target, "vzeroupper", lo16_vec_mask, "");
	reg_instr_clob(target, "vzeroall", lo16_vec_mask, "");

	// AES VAES
	reg_instr(target, "aesdec", "rw:v128, v128/mem");
	reg_instr(target, "vaesdec", "w:v128/v256/v512, v128/v256/v512, v128/v256/v512/mem");
	reg_instr(target, "aesdeclast", "rw:v128, v128/mem");
	reg_instr(target, "vaesdeclast", "w:v128/v256/v512, v128/v256/v512, v128/v256/v512/mem");
	reg_instr(target, "aesenc", "rw:v128, v128/mem");
	reg_instr(target, "vaesenc", "w:v128/v256/v512, v128/v256/v512, v128/v256/v512/mem");
	reg_instr(target, "aesenclast", "rw:v128, v128/mem");
	reg_instr(target, "vaesenclast", "w:v128/v256/v512, v128/v256/v512, v128/v256/v512/mem");
	reg_instr(target, "aesimc", "w:v128, v128/mem");
	reg_instr(target, "vaesimc", "w:v128, v128/mem");
	reg_instr(target, "aeskeygenassist", "w:v128, v128/mem, imm8");
	reg_instr(target, "vaeskeygenassist", "w:v128, v128/mem, imm8");

	// AESKLE
	reg_instr_clob(target, "aesdec128kl", cc_flag_mask, "rw:v128, mem"); // 384 bit mem load
	reg_instr_clob(target, "aesdec256kl", cc_flag_mask, "rw:v128, mem"); // 512 bit mem load
	reg_instr_clob(target, "aesenc128kl", cc_flag_mask, "rw:v128, mem"); // 384 bit mem load
	reg_instr_clob(target, "aesenc256kl", cc_flag_mask, "rw:v128, mem"); // 512 bit mem load
	reg_instr_clob(target, "encodekey128", xmm_0_2_xmm_4_6_cc_mask, "r32, r32");
	reg_instr_clob(target, "encodekey256", xmm_0_6_cc_mask, "r32, r32");

	// AES_WIDE
	reg_instr_clob(target, "aesdecwide128kl", xmm_0_7_cc_mask, "mem"); // 384 bit mem load
	reg_instr_clob(target, "aesdecwide256kl", xmm_0_7_cc_mask, "mem"); // 512 bit mem load
	reg_instr_clob(target, "aesencwide128kl", xmm_0_7_cc_mask, "mem"); // 384 bit mem load
	reg_instr_clob(target, "aesencwide256kl", xmm_0_7_cc_mask, "mem"); // 512 bit mem load

	// KEY_LOCKER
	reg_instr_clob(target, "loadiwkey", rax_xmm0_cc_mask, "v128, v128");

	// SHA
	reg_instr(target, "sha1msg1", "rw:v128, v128/mem");
	reg_instr(target, "sha1msg2", "rw:v128, v128/mem");
	reg_instr(target, "sha1nexte", "rw:v128, v128/mem");
	reg_instr(target, "sha1rnds4", "rw:v128, v128/mem, imm8");
	reg_instr(target, "sha256msg1", "rw:v128, v128/mem");
	reg_instr(target, "sha256msg2", "rw:v128, v128/mem");
	reg_instr_clob(target, "sha256rnds2", xmm0_mask, "rw:v128, v128/mem");

	// SHA512
	reg_instr(target, "vsha512msg1", "rw:v256, v128");
	reg_instr(target, "vsha512msg2", "rw:v256, v256");
	reg_instr(target, "vsha512rnds2", "rw:v256, v256, v128");

	// SM3
	reg_instr(target, "vsm3msg1", "rw:v128, v128, v128/mem");
	reg_instr(target, "vsm3msg2", "rw:v128, v128, v128/mem");
	reg_instr(target, "vsm3rnds2", "rw:v128, v128, v128/mem, imm8");

	// SM4
	reg_instr(target, "vsm4key4", "w:v128/v256, v128/v256, v128/v256/mem");
	reg_instr(target, "vsm4rnds4", "w:v128/v256, v128/v256, v128/v256/mem");

	// RDRAND
	reg_instr_clob(target, "rdrand", cc_flag_mask, "w:r16/r32/r64");

	// RDSEED
	reg_instr_clob(target, "rdseed", cc_flag_mask, "w:r16/r32/r64");

	// LGDT, LIDT
	reg_instr(target, "lgdt", "mem");
	reg_instr(target, "lidt", "mem");

	target.clobber_name_list = X86_CLOBBER_NAMES;
	target.extra_clobbers = "~{flags},~{dirflag},~{fspr}";


	if (target.arch == ArchType.X86)
	{
		reg_register_list(target, X86_LONG_REGS, 8, REG_INT, ARG_BITS_32, X86_RAX);
		reg_register_list(target, X86_WORD_REGS, 8, REG_INT, ARG_BITS_16, X86_RAX);
		reg_register_list(target, X86_LOW_BYTE_REGS, 8, REG_INT, ARG_BITS_8, X86_RAX);
		reg_register_list(target, X86_FLOAT_REGS, 8, REG_FLOAT, ARG_BITS_80, X86_ST0);
		reg_register_list(target, X86_XMM_REGS, 8, REF_FVEC, ARG_BITS_128, X86_MM0);
		reg_register_list(target, X86_CONTROL_REGS, 4 , REG_INT, ARG_BITS_32, X86_CR0);
	}
	else
	{
		reg_register_list(target, X64_QUAD_REGS, 16, REG_INT, ARG_BITS_64, X86_RAX);
		reg_register_list(target, X86_LONG_REGS, 16, REG_INT, ARG_BITS_32, X86_RAX);
		reg_register_list(target, X86_WORD_REGS, 16, REG_INT, ARG_BITS_16, X86_RAX);
		reg_register_list(target, X86_LOW_BYTE_REGS, 16, REG_INT, ARG_BITS_8, X86_RAX);
		reg_register_list(target, X86_HIGH_BYTE_REGS, 4, REG_INT, ARG_BITS_8, X86_RAX);
		reg_register_list(target, X86_XMM_REGS, 16, REF_FVEC, ARG_BITS_128, X86_XMM0);
		reg_register_list(target, X86_YMM_REGS, 16, REF_FVEC, ARG_BITS_256, X86_XMM0);
		reg_register_list(target, X86_ZMM_REGS, 16, REF_FVEC, ARG_BITS_512, X86_XMM0);
		reg_register_list(target, X86_CONTROL_REGS, 4, REG_INT, ARG_BITS_64, X86_CR0);
	}

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

fn void scratch_append_bit(String name, String string, bool* has_print_reg) @local
{
	if (*has_print_reg)
	{
		scratch_buffer_append("/");
	}
	else
	{
		*has_print_reg = true;
	}
	scratch_buffer_append(name);
	scratch_buffer_append(string);
}

fn void scratch_append_bits(String name, AsmArgBits bits) @local
{
	bool has_print = false;
	if (bits & ARG_BITS_512) scratch_append_bit(name, "512", &has_print);
	if (bits & ARG_BITS_256) scratch_append_bit(name, "256", &has_print);
	if (bits & ARG_BITS_128) scratch_append_bit(name, "128", &has_print);
	if (bits & ARG_BITS_80) scratch_append_bit(name, "80", &has_print);
	if (bits & ARG_BITS_64) scratch_append_bit(name, "64", &has_print);
	if (bits & ARG_BITS_32) scratch_append_bit(name, "32", &has_print);
	if (bits & ARG_BITS_20) scratch_append_bit(name, "20", &has_print);
	if (bits & ARG_BITS_16) scratch_append_bit(name, "16", &has_print);
	if (bits & ARG_BITS_12) scratch_append_bit(name, "12", &has_print);
	if (bits & ARG_BITS_8) scratch_append_bit(name, "8", &has_print);
	if (bits & ARG_BITS_5) scratch_append_bit(name, "5", &has_print);
}

fn void arm_arg_to_scratch(AsmArgType type) @local
{
	scratch_buffer_clear();
	if (type.is_write && !type.is_readwrite) scratch_buffer_append("w");
	if (type.is_readwrite) scratch_buffer_append("rw");
	if (scratch_buffer_len()) scratch_buffer_append(":");
	bool has_print = false;
	if (type.imm_arg_ubits)
	{
		scratch_append_bits("immu", type.imm_arg_ubits);
		has_print = true;
	}
	if (type.imm_arg_ibits)
	{
		if (has_print) scratch_buffer_append("/");
		scratch_append_bits("imm", type.imm_arg_ibits);
		has_print = true;
	}
	if (type.ireg_bits)
	{
		if (has_print) scratch_buffer_append("/");
		scratch_append_bits("r", type.ireg_bits);
		has_print = true;
	}
	if (type.float_bits)
	{
		if (has_print) scratch_buffer_append("/");
		scratch_append_bits("f", type.float_bits);
		has_print = true;
	}
	if (type.vec_bits)
	{
		if (has_print) scratch_buffer_append("/");
		scratch_append_bits("v", type.vec_bits);
		has_print = true;
	}
	if (type.is_address)
	{
		if (has_print) scratch_buffer_append("/");
		scratch_buffer_append("mem");
	}
}

fn int comp(AsmInstruction* a, AsmInstruction* b) @local
{
	if (a.name.ptr == b.name.ptr) return 0;
	if (!a.name.ptr) return -1;
	if (!b.name.ptr) return 1;
	return a.name.compare_to(b.name);
}

fn void print_arch_asm(PlatformTarget* target) @local
{
	AsmInstruction[] instructions = mem::new_array(AsmInstruction, ASM_INSTRUCTION_MAX);
	defer free(instructions);
	instructions[..] = target.instructions[..];
	quicksort(instructions, &comp);
	io::printf("+------------+--------------------------------+-----------------------------------------------------------------------+\n");
	io::printf("| instr      | clobbers                       | args                                                                  |\n");
	io::printf("+------------+--------------------------------+-----------------------------------------------------------------------+\n");
	for (int i = 0; i < ASM_INSTRUCTION_MAX; i++)
	{
		AsmInstruction* instruction = &instructions[i];
		if (!instruction.name.ptr) continue;
		io::printf("| %-10s | ", instruction.name);
		scratch_buffer_clear();
		Clobbers clobbers = instruction.mask;
		switch (target.arch)
		{
			case X86_64:
			case X86:
				for (int cl = 0; cl <= X86_TMM7; cl++)
				{
					if (clobbers.mask[cl / 64] & (1UL << (cl % 64)))
					{
						scratch_buffer_append(X86_CLOBBER_NAMES[cl]);
						scratch_buffer_append(", ");
					}
				}
			default:
				unreachable();
		}
		if (scratch_buffer_len()) scratch_buffer_delete(2);
		io::printf("%-30s | ", scratch_buffer_str());
		int len = 0;
		for (int j = 0; j < instruction.param_count; j++)
		{
			if (j != 0)
			{
				len += 2;
				io::printf(", ");
			}
			arm_arg_to_scratch(instruction.param[j]);
			io::printf("%s", scratch_buffer_str());
			len += scratch_buffer_len();
		}
		for (int j = 0; j < 70 - len; j++) io::printf(" ");
		io::printf("|\n");
	}
	io::printf("+------------+--------------------------------+-----------------------------------------------------------------------+\n");
}

// asm_target.c:1094
fn void print_asm(PlatformTarget* target)
{
	init_asm(target);
	switch (target.arch)
	{
		case X86_64:
		case X86:
			print_arch_asm(target);
			return;
		default:
			io::printf("Printing ASM for target is not yet supported.");
			return;
	}
}

// asm_target.c:1113
fn void init_asm(PlatformTarget* target)
{
	if (target.asm_initialized) return;
	target.asm_initialized = true;
	// Deviation: start from empty tables (see the file header).
	target.instructions = {};
	target.registers = {};
	target.register_count = 0;
	switch (target.arch)
	{
		case X86_64:
		case X86:
			init_asm_x86(target);
			return;
		case AARCH64:
		case AARCH64_BE:
			init_asm_unsupported(target, "AArch64");
		case ARM:
		case ARMB:
		case THUMB:
		case THUMBEB:
			init_asm_unsupported(target, "ARM");
		case WASM64:
		case WASM32:
			init_asm_unsupported(target, "Wasm");
		case AVR:
			@error_exit("AVR asm support not yet available.");
		case XTENSA:
			@error_exit("Xtensa asm support not yet available.");
		case UNKNOWN:
			@error_exit("Unknown arch does not support asm.");
		case PPC:
		case PPC64:
		case PPC64LE:
			init_asm_unsupported(target, "PPC");
		case RISCV32:
		case RISCV64:
			init_asm_riscv(target);
			return;
		default:
			@error_exit("Arch is unsupported and does not support inline asm.");
	}
}
