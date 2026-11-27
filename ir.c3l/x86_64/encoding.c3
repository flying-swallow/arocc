// Port of the operand model and lookup of the Zig compiler's
// src/codegen/x86_64/Encoding.zig (`Op`, `Op.fromOperand`, `Op.isSubset`,
// `findByMnemonic`) plus the operand shape of encoder.zig's `Instruction`.
// The table is generated into encoding_table.c3; encode.c3 emits one row as
// instruction bytes and a possible relocation fixup.
//
// Deviations (C3 port):
// - `Op`'s classification switches (isRegister/isMemory/isImmediate, class,
//   regBitSize/memBitSize/immBitSize, isSigned, toReg) are enum associated
//   values. `exact` stands for Zig's `toReg() != .none` (the operand names one
//   specific register, so only that register matches).
// - The rows were generated from Intel XED for the
//   mnemonics lowering uses: x86_64 baseline, legacy SSE/SSE2 and x87; the "shortest encoding" choice uses `Entry.estimate_len`.
// - Operands also carry symbol and label references; those classify as `rel32`
//   (branch/call targets) or rip-relative memory, which an assembler or a later
//   machine-code emitter turns into relocations.
module aro::backend::x86_64;
import std::collections::list;

<* Zig `Encoding.Op` with its classification as associated values. *>
enum Op : char (bool is_reg, bool is_mem, bool is_imm, bool exact, RegClass class, ushort reg_bits, ushort mem_bits, ushort imm_bits, bool imm_signed)
{
	NONE { false, false, false, false, GENERAL_PURPOSE, 0, 0, 0, false },
	UNITY { false, false, true, false, GENERAL_PURPOSE, 0, 0, 1, false },
	IMM8 { false, false, true, false, GENERAL_PURPOSE, 0, 0, 8, false },
	IMM16 { false, false, true, false, GENERAL_PURPOSE, 0, 0, 16, false },
	IMM32 { false, false, true, false, GENERAL_PURPOSE, 0, 0, 32, false },
	IMM64 { false, false, true, false, GENERAL_PURPOSE, 0, 0, 64, false },
	IMM8S { false, false, true, false, GENERAL_PURPOSE, 0, 0, 8, true },
	IMM16S { false, false, true, false, GENERAL_PURPOSE, 0, 0, 16, true },
	IMM32S { false, false, true, false, GENERAL_PURPOSE, 0, 0, 32, true },
	AL { true, false, false, true, GENERAL_PURPOSE, 8, 0, 0, false },
	AX { true, false, false, true, GENERAL_PURPOSE, 16, 0, 0, false },
	EAX { true, false, false, true, GENERAL_PURPOSE, 32, 0, 0, false },
	RAX { true, false, false, true, GENERAL_PURPOSE, 64, 0, 0, false },
	CL { true, false, false, true, GENERAL_PURPOSE, 8, 0, 0, false },
	DX { true, false, false, true, GENERAL_PURPOSE, 16, 0, 0, false },
	RIP { true, false, false, true, IP, 64, 0, 0, false },
	EIP { true, false, false, true, IP, 32, 0, 0, false },
	IP { true, false, false, true, IP, 16, 0, 0, false },
	R8 { true, false, false, false, GENERAL_PURPOSE, 8, 0, 0, false },
	R16 { true, false, false, false, GENERAL_PURPOSE, 16, 0, 0, false },
	R32 { true, false, false, false, GENERAL_PURPOSE, 32, 0, 0, false },
	R64 { true, false, false, false, GENERAL_PURPOSE, 64, 0, 0, false },
	RM8 { true, true, false, false, GENERAL_PURPOSE, 8, 8, 0, false },
	RM16 { true, true, false, false, GENERAL_PURPOSE, 16, 16, 0, false },
	RM32 { true, true, false, false, GENERAL_PURPOSE, 32, 32, 0, false },
	RM64 { true, true, false, false, GENERAL_PURPOSE, 64, 64, 0, false },
	R32_M8 { true, true, false, false, GENERAL_PURPOSE, 32, 8, 0, false },
	R32_M16 { true, true, false, false, GENERAL_PURPOSE, 32, 16, 0, false },
	R64_M16 { true, true, false, false, GENERAL_PURPOSE, 64, 16, 0, false },
	M8 { false, true, false, false, GENERAL_PURPOSE, 0, 8, 0, false },
	M16 { false, true, false, false, GENERAL_PURPOSE, 0, 16, 0, false },
	M32 { false, true, false, false, GENERAL_PURPOSE, 0, 32, 0, false },
	M64 { false, true, false, false, GENERAL_PURPOSE, 0, 64, 0, false },
	M80 { false, true, false, false, GENERAL_PURPOSE, 0, 80, 0, false },
	M128 { false, true, false, false, GENERAL_PURPOSE, 0, 128, 0, false },
	M256 { false, true, false, false, GENERAL_PURPOSE, 0, 256, 0, false },
	REL8 { false, false, true, false, GENERAL_PURPOSE, 0, 0, 8, true },
	REL16 { false, false, true, false, GENERAL_PURPOSE, 0, 0, 16, true },
	REL32 { false, false, true, false, GENERAL_PURPOSE, 0, 0, 32, true },
	M { false, true, false, false, GENERAL_PURPOSE, 0, 0, 0, false },
	MOFFS { false, true, false, false, SEGMENT, 0, 0, 0, false },
	MRIP8 { false, true, false, false, GENERAL_PURPOSE, 0, 8, 0, false },
	SREG { true, false, false, false, SEGMENT, 16, 0, 0, false },
	ST0 { true, false, false, true, X87, 80, 0, 0, false },
	ST { true, false, false, false, X87, 80, 0, 0, false },
	MM { true, false, false, false, MMX, 64, 0, 0, false },
	MM_M64 { true, true, false, false, MMX, 64, 64, 0, false },
	XMM0 { true, false, false, true, SSE, 128, 0, 0, false },
	XMM { true, false, false, false, SSE, 128, 0, 0, false },
	XMM_M8 { true, true, false, false, SSE, 128, 8, 0, false },
	XMM_M16 { true, true, false, false, SSE, 128, 16, 0, false },
	XMM_M32 { true, true, false, false, SSE, 128, 32, 0, false },
	XMM_M64 { true, true, false, false, SSE, 128, 64, 0, false },
	XMM_M128 { true, true, false, false, SSE, 128, 128, 0, false },
	YMM { true, false, false, false, SSE, 256, 0, 0, false },
	YMM_M256 { true, true, false, false, SSE, 256, 256, 0, false },
	CR { true, false, false, false, CR, 64, 0, 0, false },
	DR { true, false, false, false, DR, 64, 0, 0, false },
}

<* Zig `Op.isSubset`: an operand of class `self` can be encoded where `target` is expected. *>
fn bool Op.is_subset(self, Op target)
{
	switch (self)
	{
		case NONE: case M: case MOFFS: case SREG: return self == target;
		default: break;
	}
	if (self.is_reg && target.is_reg)
	{
		if (target.exact) return self == target;
		return self.class == target.class && self.reg_bits == target.reg_bits;
	}
	if (self.is_mem && target.is_mem)
	{
		switch (target)
		{
			case M: return true;
			case MOFFS: case MRIP8: return self == target;
			default: return self.mem_bits == target.mem_bits;
		}
	}
	if (self.is_imm && target.is_imm)
	{
		ushort bits = self.imm_bits;
		switch (target)
		{
			case IMM64: return bits <= 64;
			case IMM32S: case REL32: return bits < 32 || (bits == 32 && self.imm_signed);
			case IMM32: return bits <= 32;
			case IMM16S: case REL16: return bits < 16 || (bits == 16 && self.imm_signed);
			case IMM16: return bits <= 16;
			case IMM8S: case REL8: return bits < 8 || (bits == 8 && self.imm_signed);
			case IMM8: return bits <= 8;
			default: return self == target;
		}
	}
	return false;
}

<* One row of the generated ENCODINGS table (encoding_table.c3). *>
struct Entry
{
	Mnemonic mnemonic;
	OpEn op_en;
	Op[4] ops;
	char[3] opc;
	char opc_len;
	char modrm_ext;
	Mode mode;
}

<* What a memory operand is relative to. *>
enum MemBase : char
{
	<* `[reg + disp]` *>
	REG,
	<* `[rip + symbol + disp]`: a global or function. *>
	SYMBOL,
	<* `[rip + label]`: a local data label such as a string constant. *>
	LABEL,
}

<* A memory operand. `bits == 0` is an unsized operand (Zig `.m`, e.g. lea). *>
struct Memory
{
	MemBase base_kind;
	Register base;
	Register index;
	char scale;
	bool has_index;
	int disp;
	String name;
	ushort bits;
	<* SYMBOL memory operands can use the GOT for undefined symbols. *>
	bool gotpc;
}

enum OperandKind : char
{
	NONE,
	REG,
	MEM,
	IMM,
	<* A branch or call target: a local label or a global symbol (rel32). *>
	TARGET,
}

<* Zig `encoder.Instruction.Operand` (reg / mem / imm), plus branch targets. *>
struct Operand
{
	OperandKind kind;
	Register reg;
	Memory mem;
	long imm;
	<* TARGET: the label or symbol name; `external` targets are called through the PLT. *>
	String target;
	bool external;
}

fn Operand reg_op(Register reg) => { .kind = REG, .reg = reg };
fn Operand imm_op(long value) => { .kind = IMM, .imm = value };
fn Operand mem_op(Register base, int disp, ushort bits) => { .kind = MEM, .mem = { .base_kind = REG, .base = base, .disp = disp, .bits = bits } };
fn Operand sib_mem_op(Register base, Register index, char scale, int disp, ushort bits) => { .kind = MEM, .mem = { .base_kind = REG, .base = base, .index = index, .scale = scale, .has_index = true, .disp = disp, .bits = bits } };
fn Operand symbol_mem_op(String name, ushort bits = 0) => { .kind = MEM, .mem = { .base_kind = SYMBOL, .base = RIP, .name = name, .bits = bits } };
fn Operand got_symbol_mem_op(String name, ushort bits = 64) => { .kind = MEM, .mem = { .base_kind = SYMBOL, .base = RIP, .name = name, .bits = bits, .gotpc = true } };
fn Operand label_mem_op(String name, ushort bits = 0) => { .kind = MEM, .mem = { .base_kind = LABEL, .base = RIP, .name = name, .bits = bits } };
fn Operand target_op(String name, bool external = false) => { .kind = TARGET, .target = name, .external = external };

<* Zig `Op.fromOperand` for the operands the lowering produces. *>
fn Op Operand.op(self)
{
	switch (self.kind)
	{
		case NONE: return Op.NONE;
		case REG:
			switch (self.reg)
			{
				case AL: return Op.AL;
				case AX: return Op.AX;
				case EAX: return Op.EAX;
				case RAX: return Op.RAX;
				case CL: return Op.CL;
				case DX: return Op.DX;
				case RIP: return Op.RIP;
				case EIP: return Op.EIP;
				case IP: return Op.IP;
				case ST0: return Op.ST0;
				case XMM0: return Op.XMM0;
				default: break;
			}
			if (self.reg.class == X87) return Op.ST;
			if (self.reg.class == SSE) return Op.XMM;
			switch (self.reg.bits)
			{
				case 8: return Op.R8;
				case 16: return Op.R16;
				case 32: return Op.R32;
				default: return Op.R64;
			}
		case MEM:
			switch (self.mem.bits)
			{
				case 0: return self.mem.base_kind == REG ? Op.M : Op.MRIP8;
				case 8: return self.mem.base_kind == REG ? Op.M8 : Op.MRIP8;
				case 16: return Op.M16;
				case 32: return Op.M32;
				case 64: return Op.M64;
				case 80: return Op.M80;
				case 128: return Op.M128;
				default: return Op.M256;
			}
		case IMM:
			long x = self.imm;
			if (x == 1) return Op.UNITY;
			if (x >= ichar::min && x <= ichar::max) return Op.IMM8S;
			if (x >= 0 && x <= char::max) return Op.IMM8;
			if (x >= short::min && x <= short::max) return Op.IMM16S;
			if (x >= 0 && x <= ushort::max) return Op.IMM16;
			if (x >= int::min && x <= int::max) return Op.IMM32S;
			if (x >= 0 && x <= uint::max) return Op.IMM32;
			return Op.IMM64;
		case TARGET: return Op.REL32;
	}
}

<* Bytes the instruction would take (opcode, ModR/M, prefixes, immediates); ranks candidate rows. *>
fn usz Entry.estimate_len(&self)
{
	usz len = self.opc_len;
	switch (self.mode)
	{
		case SHORT: case LONG: case REX: case WAIT: len += 1;
		case REX_SHORT: len += 2;
		default: break;
	}
	switch (self.op_en)
	{
		case M: case MI: case MR: case RM: case M1: case MC: case RMI: case MRI: case MRC: len += 1;
		default: break;
	}
	foreach (op : self.ops)
	{
		if (op.is_imm && !op.is_mem) len += (usz)op.imm_bits / 8;
	}
	return len;
}

<* `imul r, imm` is an assembler alias of `imul r, r, imm` with no table row of
   its own; expand it into `buf` so lookup and encoding see the RMI form. *>
fn Operand[] expand_imul_alias(Mnemonic mnemonic, Operand[] ops, Operand[3]* buf)
{
	if (mnemonic != IMUL || ops.len != 2 || ops[0].kind != REG || ops[1].kind != IMM) return ops;
	*buf = { ops[0], ops[0], ops[1] };
	return (*buf)[..];
}

<*
 Zig `Encoding.findByMnemonic`: the shortest table row for `mnemonic` whose
 operand classes accept `ops`, or NO_ENCODING. A row needing a REX prefix is
 only chosen when an operand requires one (spl, bpl, sil, dil).
*>
fn Entry? find(Mnemonic mnemonic, Operand[] ops)
{
	Operand[3] alias_buf;
	ops = expand_imul_alias(mnemonic, ops, &alias_buf);
	Op[4] input = { Op.NONE, Op.NONE, Op.NONE, Op.NONE };
	bool rex_required = false;
	foreach (i, op : ops)
	{
		input[i] = op.op();
		if (op.kind == REG && (op.reg == SPL || op.reg == BPL || op.reg == SIL || op.reg == DIL)) rex_required = true;
	}
	Entry* best = null;
	usz best_len = 0;
	foreach (&entry : ENCODINGS)
	{
		if (entry.mnemonic != mnemonic) continue;
		switch (entry.mode)
		{
			case NONE: case SHORT: if (rex_required) continue;
			case REX: case REX_SHORT: if (!rex_required) continue;
			default: break;
		}
		bool matched = true;
		for (usz i = 0; i < 4; i++)
		{
			if (!input[i].is_subset(entry.ops[i])) { matched = false; break; }
		}
		if (!matched) continue;
		usz len = entry.estimate_len();
		if (!best || len < best_len) { best = entry; best_len = len; }
	}
	if (!best) return NO_ENCODING~;
	return *best;
}

<* No table row accepts the given mnemonic and operands. *>
excuse NO_ENCODING;
