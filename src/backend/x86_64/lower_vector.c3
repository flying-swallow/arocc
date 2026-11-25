// SSE2 lowering of 128-bit IR vector values (see `ir::VectorShape`). Vectors are
// XMM-class values: `is_float_type` / `float_width` (128) cover them, so moves,
// slots, PHIs, LOAD and STORE go through the float paths (MOVUPS/MOVAPS). This
// file handles the operations `ir::sse2_vector_op` / `ir::sse2_vector_cast` /
// `ir::sse2_shuffle_kind` accept; producers never emit anything else.
// XMM0-XMM4 are scratch here; values never live in them (XMM_ALLOCATABLE_REGS).
module aro::backend::x86_64;
import aro::backend::ir;

<* Lower `ref` when it is a vector operation; false when the generic paths handle it. *>
fn bool? Lowering.lower_vector(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	switch (inst.tag)
	{
		case VSPLAT:
			self.vector_splat(ref)!;
			return true;
		case VEXTRACT:
			self.vector_extract(ref)!;
			return true;
		case VREDUCE_ADD:
			self.vector_reduce_add(ref)!;
			return true;
		case VSHUFFLE:
			self.vector_shuffle(ref)!;
			return true;
		case CMP_EQ: case CMP_NE: case CMP_SLT: case CMP_SLTE: case CMP_SGT: case CMP_SGTE:
		case CMP_ULT: case CMP_ULTE: case CMP_UGT: case CMP_UGTE:
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
			ir::VectorShape? operand = self.ir.vector_shape(self.inst(inst.data.bin.lhs).ty);
			if (catch operand) return false;
			if (operand.is_float)
			{
				self.vector_float_compare(ref, operand)!;
			}
			else
			{
				self.vector_int_compare(ref, operand)!;
			}
			return true;
		case SITOFP:
		case FPTOSI:
			if (!self.ir.is_vector(inst.ty)) return false;
			Register src = self.vector_source(inst.data.ref, XMM2)!;
			Register dst = self.vector_dest(ref, XMM0);
			self.emit(inst.tag == SITOFP ? CVTDQ2PS : CVTTPS2DQ, reg_op(dst), reg_op(src));
			self.store_float(ref, dst)!;
			return true;
		case NEGATE:
		case BIT_NOT:
		case FNEG:
		case FABS:
			ir::VectorShape? shape = self.ir.vector_shape(inst.ty);
			if (catch shape) return false;
			self.vector_unary(ref, shape)!;
			return true;
		case BIT_SHL:
		case BIT_LSHR:
		case BIT_ASHR:
			ir::VectorShape? shape = self.ir.vector_shape(inst.ty);
			if (catch shape) return false;
			self.vector_shift(ref, shape)!;
			return true;
		case ADD:
		case SUB:
		case MUL:
		case BIT_AND:
		case BIT_OR:
		case BIT_XOR:
		case FADD:
		case FSUB:
		case FMUL:
		case FDIV:
			break;
		default:
			return false;
	}
	ir::VectorShape? shape = self.ir.vector_shape(inst.ty);
	if (catch shape) return false;
	Mnemonic op;
	switch (inst.tag)
	{
		case ADD: op = shape.elem_bits == 8 ? PADDB : shape.elem_bits == 16 ? PADDW : shape.elem_bits == 32 ? PADDD : PADDQ;
		case SUB: op = sub_for(shape.elem_bits);
		case BIT_AND: op = PAND;
		case BIT_OR: op = POR;
		case BIT_XOR: op = PXOR;
		case FADD: op = shape.elem_bits == 32 ? ADDPS : ADDPD;
		case FSUB: op = shape.elem_bits == 32 ? SUBPS : SUBPD;
		case FMUL: op = shape.elem_bits == 32 ? MULPS : MULPD;
		case FDIV: op = shape.elem_bits == 32 ? DIVPS : DIVPD;
		case MUL:
			if (shape.elem_bits == 16) { op = PMULLW; break; }
			if (shape.elem_bits == 32) { self.vector_mul32(ref)!; return true; }
			self.fail("TODO: %d-bit vector lane multiply", shape.elem_bits)!;
		default: unreachable();
	}
	self.vector_alu(ref, op)!;
	return true;
}

fn Mnemonic sub_for(ushort bits) @local => bits == 8 ? PSUBB : bits == 16 ? PSUBW : bits == 32 ? PSUBD : PSUBQ;

<* `dst = lhs op rhs` for a lane-wise SSE2 operation. *>
fn void? Lowering.vector_alu(&self, ir::Ref ref, Mnemonic op)
{
	ir::Inst inst = self.inst(ref);
	// dst is the result's register (never an operand's, see lower_operand.c3).
	Register dst = self.in_register(ref) ? self.value_regs[(sz)ref] : XMM0;
	Register right = XMM1;
	if (self.in_register(inst.data.bin.rhs))
	{
		right = self.value_regs[(sz)inst.data.bin.rhs];
	}
	else
	{
		self.load_float(inst.data.bin.rhs, XMM1)!;
	}
	self.load_float(inst.data.bin.lhs, dst)!;
	self.emit(op, reg_op(dst), reg_op(right));
	self.store_float(ref, dst)!;
}

<* v4i32 multiply without SSE4.1 PMULLD: PMULUDQ multiplies lanes 0 and 2 to
   64 bits, so the odd lanes are shuffled down for a second PMULUDQ and the low
   halves of both results are interleaved back. *>
fn void? Lowering.vector_mul32(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	self.load_float(inst.data.bin.lhs, XMM1)!;
	self.load_float(inst.data.bin.rhs, XMM2)!;
	self.emit(PSHUFD, reg_op(XMM3), reg_op(XMM1), imm_op(0xF5));
	self.emit(PSHUFD, reg_op(XMM4), reg_op(XMM2), imm_op(0xF5));
	self.emit(PMULUDQ, reg_op(XMM1), reg_op(XMM2));
	self.emit(PMULUDQ, reg_op(XMM3), reg_op(XMM4));
	Register dst = self.in_register(ref) ? self.value_regs[(sz)ref] : XMM0;
	self.emit(PSHUFD, reg_op(dst), reg_op(XMM1), imm_op(0x08));
	self.emit(PSHUFD, reg_op(XMM3), reg_op(XMM3), imm_op(0x08));
	self.emit(PUNPCKLDQ, reg_op(dst), reg_op(XMM3));
	self.store_float(ref, dst)!;
}

<* A register holding vector `ref`: its own when register-allocated, else `scratch` after a load. *>
fn Register? Lowering.vector_source(&self, ir::Ref ref, Register scratch)
{
	if (self.in_register(ref)) return self.value_regs[(sz)ref];
	self.load_float(ref, scratch)!;
	return scratch;
}

<* Where to compute vector `ref`: its own register, or XMM1 when it has none or
   that register is `avoid` (a source still read after the destination is written). *>
fn Register Lowering.vector_dest(&self, ir::Ref ref, Register avoid)
{
	if (self.in_register(ref) && self.value_regs[(sz)ref].enc != avoid.enc) return self.value_regs[(sz)ref];
	return XMM1;
}

<* `dst = first; dst = dst op second` (with `imm` when not negative), reading
   `second` in place; the caller stores `dst`. *>
fn Register? Lowering.vector_two_address(&self, ir::Ref ref, ir::Ref first, ir::Ref second, Mnemonic op, int imm = -1)
{
	Register right = self.vector_source(second, XMM2)!;
	Register dst = self.vector_dest(ref, right);
	self.load_float(first, dst)!;
	if (imm < 0)
	{
		self.emit(op, reg_op(dst), reg_op(right));
	}
	else
	{
		self.emit(op, reg_op(dst), reg_op(right), imm_op(imm));
	}
	return dst;
}

<* `xmm` = every lane all ones. *>
fn void Lowering.vector_all_ones(&self, Register xmm) @local => self.emit(PCMPEQD, reg_op(xmm), reg_op(xmm));

<* Integer compare into a 0/-1 mask. SSE2 has only == and signed >, so `<` swaps
   the operands, `<=` / `>=` / `!=` invert the opposite compare, and unsigned
   compares flip each lane's sign bit first. *>
fn void? Lowering.vector_int_compare(&self, ir::Ref ref, ir::VectorShape shape)
{
	ir::Inst inst = self.inst(ref);
	ir::Ref a = inst.data.bin.lhs;
	ir::Ref b = inst.data.bin.rhs;
	bool is_unsigned;
	bool equality;
	bool swap;
	bool invert;
	switch (inst.tag)
	{
		case CMP_EQ: equality = true;
		case CMP_NE: equality = true; invert = true;
		case CMP_SGT: break;
		case CMP_SLT: swap = true;
		case CMP_SGTE: swap = true; invert = true;
		case CMP_SLTE: invert = true;
		case CMP_UGT: is_unsigned = true;
		case CMP_ULT: is_unsigned = true; swap = true;
		case CMP_UGTE: is_unsigned = true; swap = true; invert = true;
		case CMP_ULTE: is_unsigned = true; invert = true;
		default: unreachable();
	}
	if (swap) @swap(a, b);
	ushort bits = shape.elem_bits;
	Mnemonic op = equality ? (bits == 8 ? PCMPEQB : bits == 16 ? PCMPEQW : PCMPEQD)
		: (bits == 8 ? PCMPGTB : bits == 16 ? PCMPGTW : PCMPGTD);
	if (!is_unsigned)
	{
		Register dst = self.vector_two_address(ref, a, b, op)!;
		if (invert)
		{
			self.vector_all_ones(XMM3);
			self.emit(PXOR, reg_op(dst), reg_op(XMM3));
		}
		self.store_float(ref, dst)!;
		return;
	}
	self.load_float(a, XMM1)!;
	self.load_float(b, XMM2)!;
	{
		long sign = bits == 8 ? 0x80808080 : bits == 16 ? 0x80008000 : 0x80000000;
		self.emit(MOV, reg_op(EAX), imm_op((long)(int)sign));
		self.emit(MOVD, reg_op(XMM3), reg_op(EAX));
		self.emit(PSHUFD, reg_op(XMM3), reg_op(XMM3), imm_op(0));
		self.emit(PXOR, reg_op(XMM1), reg_op(XMM3));
		self.emit(PXOR, reg_op(XMM2), reg_op(XMM3));
	}
	self.emit(op, reg_op(XMM1), reg_op(XMM2));
	if (invert)
	{
		self.vector_all_ones(XMM3);
		self.emit(PXOR, reg_op(XMM1), reg_op(XMM3));
	}
	self.store_float(ref, XMM1)!;
}

<* Float compare into a 0/-1 mask with CMPPS/CMPPD; `>` and `>=` swap to `<` / `<=`. *>
fn void? Lowering.vector_float_compare(&self, ir::Ref ref, ir::VectorShape shape)
{
	ir::Inst inst = self.inst(ref);
	ir::Ref a = inst.data.bin.lhs;
	ir::Ref b = inst.data.bin.rhs;
	int predicate;
	switch (inst.tag)
	{
		case FCMP_OEQ: predicate = 0;
		case FCMP_OLT: predicate = 1;
		case FCMP_OLE: predicate = 2;
		case FCMP_UNE: predicate = 4;
		case FCMP_OGT: predicate = 1; @swap(a, b);
		case FCMP_OGE: predicate = 2; @swap(a, b);
		default: unreachable();
	}
	Register dst = self.vector_two_address(ref, a, b, shape.elem_bits == 32 ? CMPPS : CMPPD, predicate)!;
	self.store_float(ref, dst)!;
}

<* Lane-wise NEGATE (0 - x), BIT_NOT (x ^ ones), FNEG (flip the sign bits) and
   FABS (clear them); the masks are built from all-ones with shifts. *>
fn void? Lowering.vector_unary(&self, ir::Ref ref, ir::VectorShape shape)
{
	ir::Inst inst = self.inst(ref);
	bool wide = shape.elem_bits == 64;
	if (inst.tag == NEGATE)
	{
		Register src = self.vector_source(inst.data.ref, XMM2)!;
		Register dst = self.vector_dest(ref, src);
		self.emit(PXOR, reg_op(dst), reg_op(dst));
		self.emit(sub_for(shape.elem_bits), reg_op(dst), reg_op(src));
		self.store_float(ref, dst)!;
		return;
	}
	// The mask goes in XMM2, which never holds a value, so dst may be the operand's register.
	self.vector_all_ones(XMM2);
	Mnemonic op;
	switch (inst.tag)
	{
		case BIT_NOT:
			op = PXOR;
		case FNEG:
			self.emit(wide ? PSLLQ : PSLLD, reg_op(XMM2), imm_op(wide ? 63 : 31));
			op = XORPS;
		case FABS:
			self.emit(wide ? PSRLQ : PSRLD, reg_op(XMM2), imm_op(1));
			op = ANDPS;
		default: unreachable();
	}
	Register dst = self.vector_dest(ref, XMM2);
	self.load_float(inst.data.ref, dst)!;
	self.emit(op, reg_op(dst), reg_op(XMM2));
	self.store_float(ref, dst)!;
}

<* The immediate count of vector shift `inst`: its count is a VSPLAT of a
   constant in [0, 256). Lowering then never reads the splat, so
   `@each_lowered_use` leaves it out and an otherwise unused splat is folded away. *>
fn bool Lowering.vector_shift_immediate(&self, ir::Inst inst, long* imm)
{
	switch (inst.tag)
	{
		case BIT_SHL:
		case BIT_LSHR:
		case BIT_ASHR:
			break;
		default:
			return false;
	}
	ir::VectorShape? shape = self.ir.vector_shape(inst.ty);
	if (catch shape) return false;
	ir::Inst count = self.inst(inst.data.bin.rhs);
	if (count.tag != VSPLAT) return false;
	return self.int_immediate(count.data.ref, shape.elem_bits, imm) && *imm >= 0 && *imm < 256;
}

<* Shift every lane by the scalar a VSPLAT count holds: an immediate when it is
   a constant, else the count in the low quadword of XMM2. *>
fn void? Lowering.vector_shift(&self, ir::Ref ref, ir::VectorShape shape)
{
	ir::Inst inst = self.inst(ref);
	ir::Inst count = self.inst(inst.data.bin.rhs);
	if (count.tag != VSPLAT) self.fail("vector shift count must be a VSPLAT")!;
	ushort bits = shape.elem_bits;
	Mnemonic op;
	switch (inst.tag)
	{
		case BIT_SHL: op = bits == 16 ? PSLLW : bits == 32 ? PSLLD : PSLLQ;
		case BIT_LSHR: op = bits == 16 ? PSRLW : bits == 32 ? PSRLD : PSRLQ;
		case BIT_ASHR: op = bits == 16 ? PSRAW : PSRAD;
		default: unreachable();
	}
	Register dst = self.vector_dest(ref, XMM2);
	self.load_float(inst.data.bin.lhs, dst)!;
	long imm;
	if (self.vector_shift_immediate(inst, &imm))
	{
		self.emit(op, reg_op(dst), imm_op(imm));
	}
	else
	{
		// Read the count from the splat vector (the scalar's interval ends at the
		// VSPLAT). SSE2 takes the whole low quadword as the count, so narrower
		// lanes are isolated first.
		self.load_float(inst.data.bin.rhs, XMM2)!;
		if (bits != 64)
		{
			if (bits == 16)
			{
				self.emit(PEXTRW, reg_op(EAX), reg_op(XMM2), imm_op(0));
			}
			else
			{
				self.emit(MOVD, reg_op(EAX), reg_op(XMM2));
			}
			self.emit(MOVD, reg_op(XMM2), reg_op(EAX));
		}
		self.emit(op, reg_op(dst), reg_op(XMM2));
	}
	self.store_float(ref, dst)!;
}

<* Mask entry `i` as a lane of its own source (or `i` itself when undefined). *>
fn uint shuffle_source_lane(char[16] mask, uint i, uint lanes) @local
{
	return mask[i] == ir::SHUFFLE_UNDEF ? i % lanes : (uint)mask[i] % lanes;
}

fn void? Lowering.vector_shuffle(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::VectorShape? maybe_shape = self.ir.vector_shape(inst.ty);
	if (catch maybe_shape) self.fail("VSHUFFLE needs a vector type")!;
	ir::VectorShape shape = maybe_shape!!;
	uint lanes = shape.lanes;
	char[16] mask = inst.data.shuffle.mask;
	ir::ShuffleSelect select = ir::sse2_shuffle_kind(shape, mask[:lanes]);
	ir::Ref first = select.swap ? inst.data.shuffle.rhs : inst.data.shuffle.lhs;
	ir::Ref second = select.swap ? inst.data.shuffle.lhs : inst.data.shuffle.rhs;
	switch (select.kind)
	{
		case NONE:
			self.fail("VSHUFFLE mask is not selectable with SSE2")!;
		case PERMUTE:
			int control = 0;
			if (lanes == 4)
			{
				for (uint i = 0; i < 4; i++) control |= (int)shuffle_source_lane(mask, i, 4) << (2 * i);
			}
			else
			{
				for (uint j = 0; j < 2; j++)
				{
					int lane = (int)shuffle_source_lane(mask, j, 2);
					control |= (2 * lane) << (4 * j) | (2 * lane + 1) << (4 * j + 2);
				}
			}
			Register src = self.vector_source(first, XMM2)!;
			Register dst = self.vector_dest(ref, XMM0);
			self.emit(PSHUFD, reg_op(dst), reg_op(src), imm_op(control));
			self.store_float(ref, dst)!;
			return;
		case SHUFFLE_PAIRS:
			int control = 0;
			for (uint i = 0; i < lanes; i++)
			{
				control |= (int)shuffle_source_lane(mask, i, lanes) << (lanes == 4 ? 2 * i : i);
			}
			self.store_float(ref, self.vector_two_address(ref, first, second, lanes == 4 ? SHUFPS : SHUFPD, control)!)!;
		case UNPACK_LO:
		case UNPACK_HI:
			bool lo = select.kind == UNPACK_LO;
			Mnemonic op;
			switch (shape.elem_bits)
			{
				case 8: op = lo ? PUNPCKLBW : PUNPCKHBW;
				case 16: op = lo ? PUNPCKLWD : PUNPCKHWD;
				case 32: op = lo ? PUNPCKLDQ : PUNPCKHDQ;
				default: op = lo ? PUNPCKLQDQ : PUNPCKHQDQ;
			}
			self.store_float(ref, self.vector_two_address(ref, first, second, op)!)!;
	}
}

fn void? Lowering.vector_splat(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::VectorShape? maybe_shape = self.ir.vector_shape(inst.ty);
	if (catch maybe_shape) self.fail("VSPLAT needs a vector type")!;
	ir::VectorShape shape = maybe_shape!!;
	ushort bits = shape.elem_bits;
	if (shape.is_float)
	{
		self.load_float(inst.data.ref, XMM0)!;
	}
	else
	{
		self.load(inst.data.ref, RAX)!;
		if (bits == 64)
		{
			self.emit(MOVQ, reg_op(XMM0), reg_op(RAX));
		}
		else
		{
			self.emit(MOVD, reg_op(XMM0), reg_op(EAX));
		}
		// Widen lane 0 to 32 bits by duplicating it; the other bytes are don't-cares.
		if (bits == 8) self.emit(PUNPCKLBW, reg_op(XMM0), reg_op(XMM0));
		if (bits <= 16) self.emit(PUNPCKLWD, reg_op(XMM0), reg_op(XMM0));
	}
	Register dst = self.in_register(ref) ? self.value_regs[(sz)ref] : XMM1;
	self.emit(PSHUFD, reg_op(dst), reg_op(XMM0), imm_op(bits == 64 ? 0x44 : 0x00));
	self.store_float(ref, dst)!;
}

fn void? Lowering.vector_extract(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::VectorShape? maybe_shape = self.ir.vector_shape(self.inst(inst.data.bin.lhs).ty);
	if (catch maybe_shape) self.fail("VEXTRACT needs a vector operand")!;
	ir::VectorShape shape = maybe_shape!!;
	long lane;
	if (!self.int_immediate(inst.data.bin.rhs, 32, &lane) || lane < 0 || lane >= shape.lanes) self.fail("VEXTRACT lane must be a constant in range")!;
	self.load_float(inst.data.bin.lhs, XMM1)!;
	if (shape.elem_bits <= 16)
	{
		// PEXTRW zero-extends the 16-bit word holding the lane.
		long word = shape.elem_bits == 8 ? lane >> 1 : lane;
		self.emit(PEXTRW, reg_op(EAX), reg_op(XMM1), imm_op(word));
		if (shape.elem_bits == 8 && (lane & 1)) self.emit(SHR, reg_op(EAX), imm_op(8));
		self.store(ref, RAX)!;
		return;
	}
	int control = shape.elem_bits == 64 ? (int)((2 * lane) | ((2 * lane + 1) << 2)) : (int)lane;
	self.emit(PSHUFD, reg_op(XMM0), reg_op(XMM1), imm_op(control));
	if (shape.is_float)
	{
		self.store_float(ref, XMM0)!;
		return;
	}
	if (shape.elem_bits == 64)
	{
		self.emit(MOVQ, reg_op(RAX), reg_op(XMM0));
	}
	else
	{
		self.emit(MOVD, reg_op(EAX), reg_op(XMM0));
	}
	self.store(ref, RAX)!;
}

fn void? Lowering.vector_reduce_add(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::VectorShape? maybe_shape = self.ir.vector_shape(self.inst(inst.data.ref).ty);
	if (catch maybe_shape) self.fail("VREDUCE_ADD needs a vector operand")!;
	ir::VectorShape shape = maybe_shape!!;
	if (shape.is_float) self.fail("TODO: float vector reduce")!;
	ushort bits = shape.elem_bits;
	Mnemonic add = bits == 8 ? PADDB : bits == 16 ? PADDW : bits == 32 ? PADDD : PADDQ;
	// Fold halves into the low lane: 64-bit halves, then 32-bit, 16-bit and 8-bit
	// ones as the lane width needs. XMM0 is a scratch copy.
	self.load_float(inst.data.ref, XMM0)!;
	self.emit(PSHUFD, reg_op(XMM1), reg_op(XMM0), imm_op(0x4E));
	self.emit(add, reg_op(XMM0), reg_op(XMM1));
	if (bits <= 32)
	{
		self.emit(PSHUFD, reg_op(XMM1), reg_op(XMM0), imm_op(0xB1));
		self.emit(add, reg_op(XMM0), reg_op(XMM1));
	}
	if (bits <= 16)
	{
		self.emit(MOVAPS, reg_op(XMM1), reg_op(XMM0));
		self.emit(PSRLD, reg_op(XMM1), imm_op(16));
		self.emit(add, reg_op(XMM0), reg_op(XMM1));
	}
	if (bits == 8)
	{
		self.emit(MOVAPS, reg_op(XMM1), reg_op(XMM0));
		self.emit(PSRLW, reg_op(XMM1), imm_op(8));
		self.emit(add, reg_op(XMM0), reg_op(XMM1));
	}
	if (bits == 64)
	{
		self.emit(MOVQ, reg_op(RAX), reg_op(XMM0));
	}
	else
	{
		self.emit(MOVD, reg_op(EAX), reg_op(XMM0));
	}
	self.store(ref, RAX)!;
}
