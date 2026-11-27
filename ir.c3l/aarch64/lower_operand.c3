// ARM64 backend, organized like the sibling x86_64 backend.
module aro::backend::aarch64;
import aro::backend::ir, aro::primitive_value, aro::value_interner, aro::target;
import std::core::dstring, std::core::string, std::collections::list;

fn uint? Lowering.bits(&self, value_interner::InternerRef ty)
{
	if (ty == value_interner::REF_PTR) return 64;
	primitive_value::PrimitiveValue key = self.graph.interner.get(ty);
	if (key.tag == INT_TY && key.ty_bits > 0 && key.ty_bits <= 64) return key.ty_bits;
	if (key.tag == FLOAT_TY && (key.ty_bits == 32 || key.ty_bits == 64)) return key.ty_bits;
	self.fail("ARM64: unsupported value type (vectors and scalars wider than 64 bits are not implemented)")!;
	return 0;
}

fn bool Lowering.is_float(&self, value_interner::InternerRef ty)
	=> self.graph.interner.get(ty).tag == primitive_value::PrimitiveType.FLOAT_TY;

fn void Lowering.immediate(&self, uint reg, ulong value)
{
	self.emit(MOVZ, reg_op(gp(reg)), imm_op((long)(value & 65535)));
	for (uint shift = 16; shift < 64; shift += 16)
	{
		ulong part = (value >> shift) & 65535;
		if (part) self.emit(MOVK, reg_op(gp(reg)), imm_op((long)part), shift_op(shift));
	}
}

// Materialize every frame address: this also handles offsets beyond the
// immediate range of ldur/stur and add/sub. x15 never carries a live IR value.
fn void Lowering.address(&self, uint reg, uint offset)
{
	self.immediate(reg, offset);
	self.emit(SUB, reg_op(gp(reg)), reg_op(X29), reg_op(gp(reg)));
}

fn void Lowering.save_raw(&self, uint offset, uint reg)
{
	self.address(15, offset);
	self.emit(STR, reg_op(gp(reg)), mem_op(X15));
}

fn void? Lowering.normalize(&self, uint reg, uint bits, bool signed = false)
{
	if (bits < 64) self.emit(signed ? SBFX : UBFX, reg_op(gp(reg)), reg_op(gp(reg)), imm_op(0), imm_op(bits));
}

fn void? Lowering.save(&self, ir::Ref ref, uint reg = 9)
{
	uint width = self.bits(self.inst(ref).ty)!;
	self.normalize(reg, width)!;
	self.save_raw(self.slots[(sz)ref], reg);
}

fn void Lowering.symbol_address(&self, uint reg, String name)
{
	self.emit(ADRP, reg_op(gp(reg)), reloc_op(symbol(name), GOTPAGE));
	self.emit(LDR, reg_op(gp(reg)), symbol_mem_op(gp(reg), symbol(name), GOTPAGEOFF));
}

fn void? Lowering.load(&self, ir::Ref ref, uint reg = 9, bool signed = false)
{
	ir::Inst inst = self.inst(ref);
	uint width = self.bits(inst.ty)!;
	switch (inst.tag)
	{
		case SYMBOL: self.symbol_address(reg, inst.data.label);
		case LABEL_ADDR:
			self.emit(ADRP, reg_op(gp(reg)), reloc_op(self.label(inst.data.ref), PAGE));
			self.emit(ADD, reg_op(gp(reg)), reg_op(gp(reg)), reloc_op(self.label(inst.data.ref), PAGEOFF));
		case CONSTANT:
			primitive_value::PrimitiveValue key = self.graph.interner.get(inst.data.constant);
			if (key.tag == BYTES)
			{
				String name = string::tformat("Laro_string_%d_%d", self.function_id, self.next_label++);
				self.constants.appendf("%s:\n", name);
				foreach (byte : key.bytes) self.constants.appendf("\t.byte %d\n", (uint)byte);
				self.emit(ADRP, reg_op(gp(reg)), reloc_op(name, PAGE));
				self.emit(ADD, reg_op(gp(reg)), reg_op(gp(reg)), reloc_op(name, PAGEOFF));
			}
			else if (self.is_float(inst.ty))
			{
				ulong bits;
				if (inst.data.constant == value_interner::REF_ZERO) { bits = 0; }
				else if (inst.data.constant == value_interner::REF_ONE) { bits = width == 32 ? 0x3f800000 : 0x3ff0000000000000; }
				else { bits = (ulong)key.float_bits(); }
				self.immediate(reg, bits);
			}
			else if (key.tag == NULL) { self.immediate(reg, 0); }
			else if (key.tag == INT_POSITIVE || key.tag == INT_NEGATIVE) { self.immediate(reg, key.int_low_u64()); }
			else { self.fail("ARM64: unsupported constant")!; }
		default:
			self.address(15, self.slots[(sz)ref]);
			self.emit(LDR, reg_op(gp(reg)), mem_op(X15));
	}
	self.normalize(reg, width, signed)!;
}

fn void? Lowering.load_fp(&self, ir::Ref ref, uint reg)
{
	self.load(ref)!;
	uint width = self.bits(self.inst(ref).ty)!;
	self.emit(FMOV, reg_op(fp(reg, width)), reg_op(gp(9, width)));
}

fn void? Lowering.save_fp(&self, ir::Ref ref, uint reg)
{
	uint width = self.bits(self.inst(ref).ty)!;
	self.emit(FMOV, reg_op(gp(9, width)), reg_op(fp(reg, width)));
	self.save(ref)!;
}

fn Mnemonic load_op(uint bits) => bits <= 8 ? LDRB : bits <= 16 ? LDRH : LDR;
fn Mnemonic store_op(uint bits) => bits <= 8 ? STRB : bits <= 16 ? STRH : STR;

