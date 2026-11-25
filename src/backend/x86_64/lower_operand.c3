// Operand selection for x86-64 lowering: read values where they already live
// (allocated register, immediate, stack slot) and compute results straight into
// the value's allocated register, instead of staging everything in RAX/RCX.
//
// Safety: linear_scan frees a register only when an interval ends strictly
// before the next one starts, so a result's register never holds an operand
// of the instruction defining it, with one exception: preferred_register may
// hand over the register of `reusable_operand` (the operand the lowering first
// copies into the destination) when that operand dies at this instruction.
// The lowerings it covers read every other operand before writing dst, so
// two-address forms (`mov dst, lhs; op dst, rhs`) never lose a live input.
module aro::backend::x86_64;
import aro::backend::ir, aro::primitive_value, aro::value_interner;

<* The register a result is computed in: its allocated register, else RAX
   (then stored to its slot). Returned at 64 bits; resize with to_bits. *>
fn Register Lowering.dest_reg(&self, ir::Ref ref)
{
	return self.in_register(ref) ? self.value_regs[(sz)ref].to_bits(64) : RAX;
}

<* A value with a frame slot holding it (not a register, constant, symbol,
   ALLOC or folded node). *>
fn bool Lowering.in_slot(&self, ir::Ref ref)
{
	if (self.in_register(ref) || self.folded_away[(sz)ref]) return false;
	switch (self.inst(ref).tag)
	{
		case CONSTANT:
		case SYMBOL:
		case ALLOC:
			return false;
		default:
			return true;
	}
}

<* Read `ref` at width `w` as an instruction's source operand: an immediate
   (when `allow_imm` and it fits), its allocated register, its slot (when
   `allow_mem`), or else loaded into `scratch`. *>
fn Operand? Lowering.src_operand(&self, ir::Ref ref, ushort w, Register scratch, bool allow_imm = true, bool allow_mem = true)
{
	long imm;
	if (allow_imm && self.int_immediate(ref, w, &imm)) return imm_op(imm);
	if (self.in_register(ref)) return reg_op(self.value_regs[(sz)ref].to_bits(w));
	if (allow_mem && self.in_slot(ref)) return self.slot(ref, w);
	self.load(ref, scratch)!;
	return reg_op(scratch.to_bits(w));
}

<* A 64-bit register holding `ref` for use as an address base or index: its
   allocated register when the value is 64 bits wide, else loaded into `scratch`. *>
fn Register? Lowering.address_reg(&self, ir::Ref ref, Register scratch)
{
	if (self.in_register(ref) && self.bits(self.inst(ref).ty)! == 64) return self.value_regs[(sz)ref].to_bits(64);
	self.load(ref, scratch)!;
	return scratch.to_bits(64);
}

fn bool is_commutative(Mnemonic mnemonic)
{
	switch (mnemonic)
	{
		case ADD:
		case IMUL:
		case AND:
		case OR:
		case XOR:
			return true;
		default:
			return false;
	}
}

<* The ALU operand computed into the destination: lhs, or rhs when a
   commutative op moves a constant left operand to the right. *>
fn ir::Ref Lowering.alu_destination_operand(&self, ir::Inst inst, Mnemonic mnemonic)
{
	ir::Ref lhs = inst.data.bin.lhs;
	ir::Ref rhs = inst.data.bin.rhs;
	ushort? w = self.bits(self.inst(lhs).ty);
	if (catch w) return lhs;
	long imm;
	if (is_commutative(mnemonic) && self.int_immediate(lhs, w, &imm) && !self.int_immediate(rhs, w, &imm)) return rhs;
	return lhs;
}

<* Two-operand integer ALU (add, sub, imul, and, or, xor):
   `mov dst, lhs; op dst, rhs`, rhs as immediate, register or slot. A constant
   multiply is the three-operand `imul dst, lhs, imm`. 8/16-bit operations run
   on the 32-bit registers; the low bits of the result are the same. *>
fn void? Lowering.alu(&self, ir::Ref ref, Mnemonic mnemonic)
{
	ir::Inst inst = self.inst(ref);
	ir::Ref lhs = self.alu_destination_operand(inst, mnemonic);
	ir::Ref rhs = lhs == inst.data.bin.lhs ? inst.data.bin.rhs : inst.data.bin.lhs;
	ushort w = self.bits(self.inst(lhs).ty)!;
	ushort op_w = w < 32 ? 32 : w;
	long imm;
	Register dst = self.dest_reg(ref).to_bits(op_w);
	if (mnemonic == IMUL && self.int_immediate(rhs, w, &imm))
	{
		Operand source = self.src_operand(lhs, op_w, RCX, false)!;
		self.emit(IMUL, reg_op(dst), source, imm_op(imm));
		self.store(ref, dst.to_bits(64))!;
		return;
	}
	Operand right = self.src_operand(rhs, op_w, RCX)!;
	self.load(lhs, dst)!;
	self.emit(mnemonic, reg_op(dst), right);
	self.store(ref, dst.to_bits(64))!;
}

<* Shift by a constant count (`shl dst, imm`) or by CL. Narrow operands are
   first sign- or zero-extended to 32 bits, so right shifts see the right bits. *>
fn void? Lowering.shift(&self, ir::Ref ref, Mnemonic mnemonic, bool signed)
{
	ir::Inst inst = self.inst(ref);
	Register dst = self.dest_reg(ref);
	long count;
	bool constant_count = self.int_immediate(inst.data.bin.rhs, self.bits(self.inst(inst.data.bin.rhs).ty)!, &count);
	if (!constant_count) self.load(inst.data.bin.rhs, RCX)!;
	ushort w = self.load_extended(inst.data.bin.lhs, dst, signed)!;
	if (constant_count)
	{
		// The hardware masks the count the same way for the CL form.
		self.emit(mnemonic, reg_op(dst.to_bits(w)), imm_op(count & (w == 64 ? 63 : 31)));
	}
	else
	{
		self.emit(mnemonic, reg_op(dst.to_bits(w)), reg_op(CL));
	}
	self.store(ref, dst)!;
}

<* SEXT/ZEXT: MOVSX/MOVSXD/MOVZX from the operand's register or slot into dst. *>
fn void? Lowering.extend(&self, ir::Ref ref, bool signed)
{
	ir::Inst inst = self.inst(ref);
	ir::Ref source = inst.data.ref;
	Register dst = self.dest_reg(ref);
	ushort to = self.bits(inst.ty)!;
	ushort from = self.bits(self.inst(source).ty)!;
	primitive_value::PrimitiveValue key = self.ir.interner.get(self.inst(source).ty);
	bool odd_width = self.inst(source).ty != value_interner::REF_PTR && key.tag == primitive_value::PrimitiveType.INT_TY &&
		key.ty_bits != 0 && key.ty_bits < from;
	if (odd_width || self.inst(source).tag == CONSTANT || from >= to)
	{
		// An odd source width is extended from its exact width first; the
		// MOVSX/MOVZX below only extends from the rounded register width.
		from = self.load(source, dst)!;
		self.normalize_width(dst, self.inst(source).ty, from, signed)!;
		if (from < to) self.extend_in_place(dst, from, to, signed);
		self.store(ref, dst)!;
		return;
	}
	Operand operand = self.src_operand(source, from, RCX, false)!;
	if (from == 32 && !signed)
	{
		// Writing a 32-bit register zero-extends into the full register.
		self.emit(MOV, reg_op(dst.to_bits(32)), operand);
	}
	else if (from == 32)
	{
		self.emit(MOVSXD, reg_op(dst.to_bits(64)), operand);
	}
	else
	{
		self.emit(signed ? MOVSX : MOVZX, reg_op(dst.to_bits(to < 32 ? 32 : to)), operand);
	}
	self.store(ref, dst)!;
}

<* Extend `reg` from `from` bits to `to` bits where it is. *>
fn void Lowering.extend_in_place(&self, Register reg, ushort from, ushort to, bool signed)
{
	if (from == 32)
	{
		if (signed)
		{
			self.emit(MOVSXD, reg_op(reg.to_bits(64)), reg_op(reg.to_bits(32)));
		}
		else
		{
			self.emit(MOV, reg_op(reg.to_bits(32)), reg_op(reg.to_bits(32)));
		}
		return;
	}
	self.emit(signed ? MOVSX : MOVZX, reg_op(reg.to_bits(to < 32 ? 32 : to)), reg_op(reg.to_bits(from)));
}

fn bool is_reg_mov(Line* line)
{
	return !line.is_label && !line.is_raw && line.mnemonic == MOV && line.op_count == 2 &&
		line.ops[0].kind == REG && line.ops[1].kind == REG;
}

<*
 Local cleanup of the function's lines, after lowering:
 - `mov r, r` is dropped, except at 32 bits (it zero-extends);
 - in `mov a, b` directly followed by `mov b, a`, the second move is dropped
   (b already equals a; no label sits between them), again except at 32 bits.
 Memory forms are left alone: a frame slot may be a volatile local.
*>
fn void Lowering.peephole(&self)
{
	usz out = 0;
	usz len = (usz)self.lines.len();
	for (usz i = 0; i < len; i++)
	{
		Line* line = &self.lines[(sz)i];
		if (is_reg_mov(line))
		{
			Register dst = line.ops[0].reg;
			Register src = line.ops[1].reg;
			if (dst == src && dst.bits != 32) continue;
			if (out > 0)
			{
				Line* previous = &self.lines[(sz)out - 1];
				if (is_reg_mov(previous) && previous.ops[0].reg == src && previous.ops[1].reg == dst && dst.bits != 32) continue;
			}
		}
		if (out != i) self.lines[(sz)out] = *line;
		out++;
	}
	while ((usz)self.lines.len() > out) self.lines.pop()!!;
}
