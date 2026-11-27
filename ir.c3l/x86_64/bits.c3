// Port of the general-purpose parts of the Zig compiler's
// src/codegen/x86_64/bits.zig: registers and condition codes.
//
// Deviations (C3 port):
// - General-purpose, high-byte, X87, XMM and instruction-pointer registers are
//   ported. Member order within those groups follows bits.zig.
// - Register facts that bits.zig computes (`class`, `size`, `enc`) are enum
//   associated values.
// - Condition is restricted to the codes the lowering emits; `negate` maps to
//   the equivalent member of the subset (Zig `.na` is `.be`, etc.).
module aro::backend::x86_64;

<* Zig `Register.Class`. *>
enum RegClass : char
{
	GENERAL_PURPOSE,
	SEGMENT,
	X87,
	MMX,
	SSE,
	IP,
	CR,
	DR,
}

<* Zig `bits.Register` general-purpose, X87 and XMM subsets, with 4-bit encoding and size. *>
enum Register : char (String name, char enc, ushort bits, RegClass class)
{
	RAX { "rax", 0, 64, GENERAL_PURPOSE },
	RCX { "rcx", 1, 64, GENERAL_PURPOSE },
	RDX { "rdx", 2, 64, GENERAL_PURPOSE },
	RBX { "rbx", 3, 64, GENERAL_PURPOSE },
	RSP { "rsp", 4, 64, GENERAL_PURPOSE },
	RBP { "rbp", 5, 64, GENERAL_PURPOSE },
	RSI { "rsi", 6, 64, GENERAL_PURPOSE },
	RDI { "rdi", 7, 64, GENERAL_PURPOSE },
	R8 { "r8", 8, 64, GENERAL_PURPOSE },
	R9 { "r9", 9, 64, GENERAL_PURPOSE },
	R10 { "r10", 10, 64, GENERAL_PURPOSE },
	R11 { "r11", 11, 64, GENERAL_PURPOSE },
	R12 { "r12", 12, 64, GENERAL_PURPOSE },
	R13 { "r13", 13, 64, GENERAL_PURPOSE },
	R14 { "r14", 14, 64, GENERAL_PURPOSE },
	R15 { "r15", 15, 64, GENERAL_PURPOSE },

	EAX { "eax", 0, 32, GENERAL_PURPOSE },
	ECX { "ecx", 1, 32, GENERAL_PURPOSE },
	EDX { "edx", 2, 32, GENERAL_PURPOSE },
	EBX { "ebx", 3, 32, GENERAL_PURPOSE },
	ESP { "esp", 4, 32, GENERAL_PURPOSE },
	EBP { "ebp", 5, 32, GENERAL_PURPOSE },
	ESI { "esi", 6, 32, GENERAL_PURPOSE },
	EDI { "edi", 7, 32, GENERAL_PURPOSE },
	R8D { "r8d", 8, 32, GENERAL_PURPOSE },
	R9D { "r9d", 9, 32, GENERAL_PURPOSE },
	R10D { "r10d", 10, 32, GENERAL_PURPOSE },
	R11D { "r11d", 11, 32, GENERAL_PURPOSE },
	R12D { "r12d", 12, 32, GENERAL_PURPOSE },
	R13D { "r13d", 13, 32, GENERAL_PURPOSE },
	R14D { "r14d", 14, 32, GENERAL_PURPOSE },
	R15D { "r15d", 15, 32, GENERAL_PURPOSE },

	AX { "ax", 0, 16, GENERAL_PURPOSE },
	CX { "cx", 1, 16, GENERAL_PURPOSE },
	DX { "dx", 2, 16, GENERAL_PURPOSE },
	BX { "bx", 3, 16, GENERAL_PURPOSE },
	SP { "sp", 4, 16, GENERAL_PURPOSE },
	BP { "bp", 5, 16, GENERAL_PURPOSE },
	SI { "si", 6, 16, GENERAL_PURPOSE },
	DI { "di", 7, 16, GENERAL_PURPOSE },
	R8W { "r8w", 8, 16, GENERAL_PURPOSE },
	R9W { "r9w", 9, 16, GENERAL_PURPOSE },
	R10W { "r10w", 10, 16, GENERAL_PURPOSE },
	R11W { "r11w", 11, 16, GENERAL_PURPOSE },
	R12W { "r12w", 12, 16, GENERAL_PURPOSE },
	R13W { "r13w", 13, 16, GENERAL_PURPOSE },
	R14W { "r14w", 14, 16, GENERAL_PURPOSE },
	R15W { "r15w", 15, 16, GENERAL_PURPOSE },

	AL { "al", 0, 8, GENERAL_PURPOSE },
	CL { "cl", 1, 8, GENERAL_PURPOSE },
	DL { "dl", 2, 8, GENERAL_PURPOSE },
	BL { "bl", 3, 8, GENERAL_PURPOSE },
	SPL { "spl", 4, 8, GENERAL_PURPOSE },
	BPL { "bpl", 5, 8, GENERAL_PURPOSE },
	SIL { "sil", 6, 8, GENERAL_PURPOSE },
	DIL { "dil", 7, 8, GENERAL_PURPOSE },
	R8B { "r8b", 8, 8, GENERAL_PURPOSE },
	R9B { "r9b", 9, 8, GENERAL_PURPOSE },
	R10B { "r10b", 10, 8, GENERAL_PURPOSE },
	R11B { "r11b", 11, 8, GENERAL_PURPOSE },
	R12B { "r12b", 12, 8, GENERAL_PURPOSE },
	R13B { "r13b", 13, 8, GENERAL_PURPOSE },
	R14B { "r14b", 14, 8, GENERAL_PURPOSE },
	R15B { "r15b", 15, 8, GENERAL_PURPOSE },

	AH { "ah", 4, 8, GENERAL_PURPOSE },
	CH { "ch", 5, 8, GENERAL_PURPOSE },
	DH { "dh", 6, 8, GENERAL_PURPOSE },
	BH { "bh", 7, 8, GENERAL_PURPOSE },

	ST0 { "st0", 0, 80, X87 },
	ST1 { "st1", 1, 80, X87 },
	ST2 { "st2", 2, 80, X87 },
	ST3 { "st3", 3, 80, X87 },
	ST4 { "st4", 4, 80, X87 },
	ST5 { "st5", 5, 80, X87 },
	ST6 { "st6", 6, 80, X87 },
	ST7 { "st7", 7, 80, X87 },

	XMM0 { "xmm0", 0, 128, SSE },
	XMM1 { "xmm1", 1, 128, SSE },
	XMM2 { "xmm2", 2, 128, SSE },
	XMM3 { "xmm3", 3, 128, SSE },
	XMM4 { "xmm4", 4, 128, SSE },
	XMM5 { "xmm5", 5, 128, SSE },
	XMM6 { "xmm6", 6, 128, SSE },
	XMM7 { "xmm7", 7, 128, SSE },
	XMM8 { "xmm8", 8, 128, SSE },
	XMM9 { "xmm9", 9, 128, SSE },
	XMM10 { "xmm10", 10, 128, SSE },
	XMM11 { "xmm11", 11, 128, SSE },
	XMM12 { "xmm12", 12, 128, SSE },
	XMM13 { "xmm13", 13, 128, SSE },
	XMM14 { "xmm14", 14, 128, SSE },
	XMM15 { "xmm15", 15, 128, SSE },

	RIP { "rip", 0, 64, IP },
	EIP { "eip", 0, 32, IP },
	IP { "ip", 0, 16, IP },
}

<* The 64-bit general-purpose registers in encoding order (rax..r15). *>
const Register[16] GP64 = { RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI, R8, R9, R10, R11, R12, R13, R14, R15 };
const Register[16] GP32 = { EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI, R8D, R9D, R10D, R11D, R12D, R13D, R14D, R15D };
const Register[16] GP16 = { AX, CX, DX, BX, SP, BP, SI, DI, R8W, R9W, R10W, R11W, R12W, R13W, R14W, R15W };
const Register[16] GP8 = { AL, CL, DL, BL, SPL, BPL, SIL, DIL, R8B, R9B, R10B, R11B, R12B, R13B, R14B, R15B };
const Register[8] X87_REGS = { ST0, ST1, ST2, ST3, ST4, ST5, ST6, ST7 };
const Register[16] XMM_REGS = { XMM0, XMM1, XMM2, XMM3, XMM4, XMM5, XMM6, XMM7, XMM8, XMM9, XMM10, XMM11, XMM12, XMM13, XMM14, XMM15 };

<*
 Zig `Register.toSize`: the same general-purpose register at `bits` (8, 16,
 32 or 64), or the same XMM register (whose width is fixed at 128 bits).
 @require self.class == GENERAL_PURPOSE || self.class == SSE
*>
fn Register Register.to_bits(self, ushort bits)
{
	if (self.class == SSE) return self;
	switch (bits)
	{
		case 8: return GP8[self.enc];
		case 16: return GP16[self.enc];
		case 32: return GP32[self.enc];
		default: return GP64[self.enc];
	}
}

<* An XMM register. *>
fn bool Register.is_sse(self) => self.class == SSE;

<* ah, ch, dh or bh (Zig register class `gphi`). *>
fn bool Register.is_high_byte(self) => self == AH || self == CH || self == DH || self == BH;

<* Zig `Register.isExtended`: needs a REX.B/R/X bit (r8..r15 or xmm8..xmm15). *>
fn bool Register.is_extended(self) => self.enc >= 8 && (self.class == GENERAL_PURPOSE || self.class == SSE) && !self.is_high_byte();

<* Zig `bits.Condition` (subset), with the `set<cc>` / `j<cc>` mnemonics that test it. *>
enum Condition : char (String name, Condition negated, Mnemonic set, Mnemonic jump)
{
	<* above (unsigned >) *>
	A { "a", BE, SETA, JA },
	<* above or equal (unsigned >=) *>
	AE { "ae", B, SETAE, JAE },
	<* below (unsigned <) *>
	B { "b", AE, SETB, JB },
	<* below or equal (unsigned <=) *>
	BE { "be", A, SETBE, JBE },
	<* equal *>
	E { "e", NE, SETE, JE },
	<* greater (signed >) *>
	G { "g", LE, SETG, JG },
	<* greater or equal (signed >=) *>
	GE { "ge", L, SETGE, JGE },
	<* less (signed <) *>
	L { "l", GE, SETL, JL },
	<* less or equal (signed <=) *>
	LE { "le", G, SETLE, JLE },
	<* not equal *>
	NE { "ne", E, SETNE, JNE },
	<* parity set (unordered floating-point comparison) *>
	P { "p", NP, SETP, JP },
	<* parity clear (ordered floating-point comparison) *>
	NP { "np", P, SETNP, JNP },
}
