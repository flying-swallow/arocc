// Register, condition, instruction and operand data, following x86_64/bits.c3.
module aro::backend::aarch64;

enum RegisterClass : char { GP, FP }
enum Register : char (String name, char enc, RegisterClass class)
{
	X0 { "x0", 0, GP },
	X1 { "x1", 1, GP },
	X2 { "x2", 2, GP },
	X3 { "x3", 3, GP },
	X4 { "x4", 4, GP },
	X5 { "x5", 5, GP },
	X6 { "x6", 6, GP },
	X7 { "x7", 7, GP },
	X8 { "x8", 8, GP },
	X9 { "x9", 9, GP },
	X10 { "x10", 10, GP },
	X11 { "x11", 11, GP },
	X12 { "x12", 12, GP },
	X13 { "x13", 13, GP },
	X14 { "x14", 14, GP },
	X15 { "x15", 15, GP },
	X16 { "x16", 16, GP },
	X17 { "x17", 17, GP },
	X18 { "x18", 18, GP },
	X19 { "x19", 19, GP },
	X20 { "x20", 20, GP },
	X21 { "x21", 21, GP },
	X22 { "x22", 22, GP },
	X23 { "x23", 23, GP },
	X24 { "x24", 24, GP },
	X25 { "x25", 25, GP },
	X26 { "x26", 26, GP },
	X27 { "x27", 27, GP },
	X28 { "x28", 28, GP },
	X29 { "x29", 29, GP },
	X30 { "x30", 30, GP },
	W0 { "w0", 0, GP },
	W1 { "w1", 1, GP },
	W2 { "w2", 2, GP },
	W3 { "w3", 3, GP },
	W4 { "w4", 4, GP },
	W5 { "w5", 5, GP },
	W6 { "w6", 6, GP },
	W7 { "w7", 7, GP },
	W8 { "w8", 8, GP },
	W9 { "w9", 9, GP },
	W10 { "w10", 10, GP },
	W11 { "w11", 11, GP },
	W12 { "w12", 12, GP },
	W13 { "w13", 13, GP },
	W14 { "w14", 14, GP },
	W15 { "w15", 15, GP },
	W16 { "w16", 16, GP },
	W17 { "w17", 17, GP },
	W18 { "w18", 18, GP },
	W19 { "w19", 19, GP },
	W20 { "w20", 20, GP },
	W21 { "w21", 21, GP },
	W22 { "w22", 22, GP },
	W23 { "w23", 23, GP },
	W24 { "w24", 24, GP },
	W25 { "w25", 25, GP },
	W26 { "w26", 26, GP },
	W27 { "w27", 27, GP },
	W28 { "w28", 28, GP },
	W29 { "w29", 29, GP },
	W30 { "w30", 30, GP },
	S0 { "s0", 0, FP },
	S1 { "s1", 1, FP },
	S2 { "s2", 2, FP },
	S3 { "s3", 3, FP },
	S4 { "s4", 4, FP },
	S5 { "s5", 5, FP },
	S6 { "s6", 6, FP },
	S7 { "s7", 7, FP },
	S8 { "s8", 8, FP },
	S9 { "s9", 9, FP },
	S10 { "s10", 10, FP },
	S11 { "s11", 11, FP },
	S12 { "s12", 12, FP },
	S13 { "s13", 13, FP },
	S14 { "s14", 14, FP },
	S15 { "s15", 15, FP },
	S16 { "s16", 16, FP },
	S17 { "s17", 17, FP },
	S18 { "s18", 18, FP },
	S19 { "s19", 19, FP },
	S20 { "s20", 20, FP },
	S21 { "s21", 21, FP },
	S22 { "s22", 22, FP },
	S23 { "s23", 23, FP },
	S24 { "s24", 24, FP },
	S25 { "s25", 25, FP },
	S26 { "s26", 26, FP },
	S27 { "s27", 27, FP },
	S28 { "s28", 28, FP },
	S29 { "s29", 29, FP },
	S30 { "s30", 30, FP },
	S31 { "s31", 31, FP },
	D0 { "d0", 0, FP },
	D1 { "d1", 1, FP },
	D2 { "d2", 2, FP },
	D3 { "d3", 3, FP },
	D4 { "d4", 4, FP },
	D5 { "d5", 5, FP },
	D6 { "d6", 6, FP },
	D7 { "d7", 7, FP },
	D8 { "d8", 8, FP },
	D9 { "d9", 9, FP },
	D10 { "d10", 10, FP },
	D11 { "d11", 11, FP },
	D12 { "d12", 12, FP },
	D13 { "d13", 13, FP },
	D14 { "d14", 14, FP },
	D15 { "d15", 15, FP },
	D16 { "d16", 16, FP },
	D17 { "d17", 17, FP },
	D18 { "d18", 18, FP },
	D19 { "d19", 19, FP },
	D20 { "d20", 20, FP },
	D21 { "d21", 21, FP },
	D22 { "d22", 22, FP },
	D23 { "d23", 23, FP },
	D24 { "d24", 24, FP },
	D25 { "d25", 25, FP },
	D26 { "d26", 26, FP },
	D27 { "d27", 27, FP },
	D28 { "d28", 28, FP },
	D29 { "d29", 29, FP },
	D30 { "d30", 30, FP },
	D31 { "d31", 31, FP },
	SP { "sp", 31, GP },
	XZR { "xzr", 31, GP },
	WZR { "wzr", 31, GP },
}

fn Register gp(uint index, uint bits = 64)
{
	assert(index < 31);
	return Register::values[(bits <= 32 ? 31 : 0) + index];
}
fn Register fp(uint index, uint bits)
{
	assert(index < 32 && (bits == 32 || bits == 64));
	return Register::values[(bits == 32 ? 62 : 94) + index];
}

enum Mnemonic : char (String name)
{
	MOV { "mov" },
	MOVZ { "movz" },
	MOVK { "movk" },
	ADD { "add" },
	SUB { "sub" },
	MUL { "mul" },
	AND { "and" },
	ORR { "orr" },
	EOR { "eor" },
	LSL { "lsl" },
	LSR { "lsr" },
	ASR { "asr" },
	SDIV { "sdiv" },
	UDIV { "udiv" },
	MSUB { "msub" },
	NEG { "neg" },
	MVN { "mvn" },
	UBFX { "ubfx" },
	SBFX { "sbfx" },
	LDR { "ldr" },
	LDRB { "ldrb" },
	LDRH { "ldrh" },
	STR { "str" },
	STRB { "strb" },
	STRH { "strh" },
	STP { "stp" },
	LDP { "ldp" },
	ADRP { "adrp" },
	B { "b" },
	BL { "bl" },
	BLR { "blr" },
	BR { "br" },
	CBZ { "cbz" },
	CMP { "cmp" },
	CSET { "cset" },
	CSEL { "csel" },
	FMOV { "fmov" },
	FADD { "fadd" },
	FSUB { "fsub" },
	FMUL { "fmul" },
	FDIV { "fdiv" },
	FCMP { "fcmp" },
	FNEG { "fneg" },
	FABS { "fabs" },
	FCVT { "fcvt" },
	SCVTF { "scvtf" },
	UCVTF { "ucvtf" },
	FCVTZS { "fcvtzs" },
	FCVTZU { "fcvtzu" },
	RBIT { "rbit" },
	CLZ { "clz" },
	RET { "ret" },
	B_NE { "b.ne" },
}

enum Condition : char (String name)
{
	EQ { "eq" }, NE { "ne" }, LT { "lt" }, LE { "le" },
	GT { "gt" }, GE { "ge" }, LO { "lo" }, LS { "ls" },
	HI { "hi" }, HS { "hs" },
}
enum OperandKind : char { NONE, REG, IMM, MEM, TARGET, RELOC, SHIFT, CONDITION }
enum Relocation : char (String name)
{
	PAGE { "@PAGE" }, PAGEOFF { "@PAGEOFF" },
	GOTPAGE { "@GOTPAGE" }, GOTPAGEOFF { "@GOTPAGEOFF" },
}
enum AddressMode : char { OFFSET, PRE_INDEX }
struct Memory
{
	Register base;
	long displacement;
	AddressMode mode;
	String symbol;
	Relocation relocation;
}
struct Operand
{
	OperandKind kind;
	Register reg;
	long immediate;
	Memory memory;
	String target;
	Relocation relocation;
	Condition condition;
}
fn Operand reg_op(Register reg) => { .kind = REG, .reg = reg };
fn Operand imm_op(long value) => { .kind = IMM, .immediate = value };
fn Operand mem_op(Register base, long displacement = 0, AddressMode mode = OFFSET)
	=> { .kind = MEM, .memory = { .base = base, .displacement = displacement, .mode = mode } };
fn Operand target_op(String target) => { .kind = TARGET, .target = target };
fn Operand reloc_op(String target, Relocation relocation)
	=> { .kind = RELOC, .target = target, .relocation = relocation };
fn Operand symbol_mem_op(Register base, String symbol, Relocation relocation)
	=> { .kind = MEM, .memory = { .base = base, .symbol = symbol, .relocation = relocation } };
fn Operand shift_op(uint amount) => { .kind = SHIFT, .immediate = amount };
fn Operand cond_op(Condition condition) => { .kind = CONDITION, .condition = condition };
