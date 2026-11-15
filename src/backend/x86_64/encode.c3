// Encode one instruction using the selected row from encoding_table.c3.
// This module has no lowering or object-writer state; unresolved targets and
// RIP-relative operands are returned as a single fixup for the caller.
module aro::backend::x86_64;
import aro::backend::object;

enum FixupKind : char
{
	NONE,
	LOCAL_REL32,
	SYMBOL,
}

struct Fixup
{
	FixupKind kind;
	String name;
	object::RelocKind reloc;
	char offset;
	long addend;
}

struct Encoded
{
	char[16] bytes;
	char len;
	Fixup fixup;
}

fn void push_byte(Encoded* out, char byte)
{
	assert(out.len < out.bytes.len, "x86 instruction exceeded the encoder buffer");
	out.bytes[(usz)out.len++] = byte;
}

fn void push_le(Encoded* out, ulong value, uint count)
{
	for (uint i = 0; i < count; i++) push_byte(out, (char)(value >> (i * 8)));
}

fn void push_zeros(Encoded* out, uint count)
{
	for (uint i = 0; i < count; i++) push_byte(out, 0);
}

fn bool needs_byte_rex(Register reg)
{
	return reg == SPL || reg == BPL || reg == SIL || reg == DIL;
}

fn bool has_high_byte(Operand[] ops)
{
	foreach (op : ops) if (op.kind == REG && op.reg.is_high_byte()) return true;
	return false;
}

fn bool has_byte_rex(Operand[] ops)
{
	foreach (op : ops) if (op.kind == REG && needs_byte_rex(op.reg)) return true;
	return false;
}

<*
 Encode one instruction from the selected x86 encoding row. Branch targets and
 RIP-relative symbols remain zero-filled and are described by `fixup`.
 @return? NO_ENCODING
*>
fn Encoded? encode(Mnemonic mnemonic, Operand[] ops)
{
	Entry entry = find(mnemonic, ops)!;
	Encoded out = {};
	Entry row = entry;
	bool has_modrm = false;
	Operand rm_op = {};
	uint reg_code = 0;
	bool reg_is_operand = false;
	Operand reg_op = {};
	bool opcode_reg = false;
	uint rex = 0;

	switch (row.op_en)
	{
		case M: case MI: case M1: case MC:
			has_modrm = true;
			rm_op = ops[0];
			reg_code = (uint)row.modrm_ext;
		case MR:
			has_modrm = true;
			rm_op = ops[0];
			reg_op = ops[1];
			reg_code = (uint)reg_op.reg.enc;
			reg_is_operand = true;
		case RM: case RMI:
			has_modrm = true;
			rm_op = ops[1];
			reg_op = ops[0];
			reg_code = (uint)reg_op.reg.enc;
			reg_is_operand = true;
		case O: case OI:
			opcode_reg = true;
		case Z: case ZI: case I: case D:
			break;
		default: break;
	}
	switch (row.op_en)
	{
		case Z: case ZI: case I: case D: case O: case OI:
		case M: case MI: case M1: case MC: case MR: case RM: case RMI:
			break;
		default: return NO_ENCODING~;
	}
	switch (row.mode)
	{
		case NONE: case SHORT: case LONG: case REX: case REX_SHORT: break;
		default: return NO_ENCODING~;
	}

	if (row.mode == SHORT || row.mode == REX_SHORT) push_byte(&out, 0x66);
	if (row.mode == LONG) rex |= 0x08;
	if (opcode_reg && ops[0].reg.is_extended()) rex |= 0x01;
	if (reg_is_operand && reg_op.reg.is_extended()) rex |= 0x04;
	if (has_modrm)
	{
		if (rm_op.kind == REG && rm_op.reg.is_extended()) rex |= 0x01;
		if (rm_op.kind == MEM && rm_op.mem.base_kind == REG && rm_op.mem.base.is_extended()) rex |= 0x01;
	}
	bool emit_rex = row.mode == REX || row.mode == REX_SHORT || rex != 0 || has_byte_rex(ops);
	if (emit_rex && has_high_byte(ops)) return NO_ENCODING~;
	if (emit_rex) push_byte(&out, (char)(0x40 | rex));

	for (usz i = 0; i < (usz)row.opc_len; i++)
	{
		uint opcode = (uint)row.opc[i];
		if (opcode_reg && i + 1 == (usz)row.opc_len) opcode += (uint)ops[0].reg.enc & 7;
		push_byte(&out, (char)opcode);
	}

	if (row.op_en == D)
	{
		Operand target = ops[0];
		char fixup_offset = out.len;
		push_zeros(&out, 4);
		if (target.target.starts_with(".L"))
		{
			out.fixup = { .kind = LOCAL_REL32, .name = target.target, .reloc = object::RelocKind.AUTO, .offset = fixup_offset, .addend = -4 };
		}
		else
		{
			out.fixup = { .kind = SYMBOL, .name = target.target, .reloc = object::RelocKind.PLT32, .offset = fixup_offset, .addend = -4 };
		}
		return out;
	}

	if (has_modrm)
	{
		uint mod = 3;
		uint rm_code = 0;
		Memory memory = {};
		bool memory_rm = rm_op.kind == MEM;
		if (rm_op.kind == REG)
		{
			rm_code = (uint)rm_op.reg.enc & 7;
		}
		else if (memory_rm)
		{
			memory = rm_op.mem;
			if (memory.base_kind == REG)
			{
				rm_code = (uint)memory.base.enc & 7;
				if (memory.disp == 0 && rm_code != 5)
				{
					mod = 0;
				}
				else if (memory.disp >= -128 && memory.disp <= 127)
				{
					mod = 1;
				}
				else
				{
					mod = 2;
				}
			}
			else
			{
				mod = 0;
				rm_code = 5;
			}
		}
		else
		{
			return NO_ENCODING~;
		}
		push_byte(&out, (char)((mod << 6) | ((reg_code & 7) << 3) | (rm_code & 7)));
		if (memory_rm && memory.base_kind == REG && ((uint)memory.base.enc & 7) == 4)
		{
			uint base = (uint)memory.base.enc & 7;
			push_byte(&out, (char)(0x20 | base)); // scale=1, no index, base
		}
		if (memory_rm)
		{
			if (memory.base_kind == REG)
			{
				if (mod == 1) push_le(&out, (ulong)(long)memory.disp, 1);
				if (mod == 2) push_le(&out, (ulong)(long)memory.disp, 4);
			}
			else
			{
				char fixup_offset = out.len;
				push_zeros(&out, 4);
				out.fixup = {
					.kind = SYMBOL,
					.name = memory.name,
					.reloc = memory.gotpc ? object::RelocKind.REX_GOTPCRELX : object::RelocKind.PC32,
					.offset = fixup_offset,
					.addend = memory.disp,
				};
			}
		}
	}

	for (usz i = 0; i < 4; i++)
	{
		Op expected = row.ops[i];
		if (expected.imm_bits == 0 || expected == UNITY || ops[i].kind != IMM) continue;
		push_le(&out, (ulong)ops[i].imm, (uint)expected.imm_bits / 8);
	}

	if (out.fixup.kind == SYMBOL && out.fixup.reloc != object::RelocKind.PLT32)
	{
		long bytes_after_disp = (long)out.len - (long)out.fixup.offset;
		out.fixup.addend = (long)out.fixup.addend - bytes_after_disp;
	}
	return out;
}
