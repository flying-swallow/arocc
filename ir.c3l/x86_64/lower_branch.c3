// Compare-and-branch lowering for x86-64: a compare whose only use is the
// BRANCH or SELECT right after it is not materialized as a 0/1 byte; that
// instruction emits the CMP/UCOMIS itself and reads the flags (Jcc / CMOVcc).
module aro::backend::x86_64;
import aro::backend::ir, aro::primitive_value, aro::value_interner;

<* UCOMISS/UCOMISD report unordered with ZF=PF=CF=1. `==` must also see NP,
   `!=` also accepts P; the other relations are rewritten to A/AE, which
   already reject unordered. *>
enum ParityRule : char
{
	NONE,
	AND_NP,
	OR_P,
}

struct FlagCondition
{
	Condition cc;
	ParityRule parity;
}

<* Whether `ref` (a compare) can set flags for the BRANCH or SELECT using it.
   Wide integers and x87 compares keep their materialized form; a SELECT's
   CMOV cannot test parity, so float equality stays materialized there. *>
fn bool Lowering.fusable_compare(&self, ir::Ref ref, bool for_select)
{
	ir::Inst inst = self.inst(ref);
	// Read the operand only once the tag says `data` is a BinData.
	switch (inst.tag)
	{
		case CMP_EQ:
		case CMP_NE:
		case CMP_SLT:
		case CMP_SLTE:
		case CMP_SGT:
		case CMP_SGTE:
		case CMP_ULT:
		case CMP_ULTE:
		case CMP_UGT:
		case CMP_UGTE:
			return !self.is_wide_int(self.inst(inst.data.bin.lhs).ty);
		case FCMP_OEQ:
		case FCMP_UNE:
			return !for_select && self.is_xmm_float_type(self.inst(inst.data.bin.lhs).ty);
		case FCMP_OLT:
		case FCMP_OLE:
		case FCMP_OGT:
		case FCMP_OGE:
			return self.is_xmm_float_type(self.inst(inst.data.bin.lhs).ty);
		default:
			return false;
	}
}

<* Mark compares consumed directly by the next emitting BRANCH/SELECT as
   folded away. `total_uses` counts every use, PHI inputs included. *>
fn void Lowering.compute_compare_fusions(&self, uint[] total_uses)
{
	usz count = self.decl.instructions.len;
	ir::Ref previous = ir::NONE;
	foreach (ref : self.decl.body)
	{
		if ((usz)ref >= count) continue;
		ir::Inst inst = self.inst(ref);
		if ((inst.tag == BRANCH || inst.tag == SELECT) && previous != ir::NONE && inst.data.branch.cond == previous &&
			total_uses[(sz)previous] == 1 && self.fusable_compare(previous, inst.tag == SELECT))
		{
			self.folded_away[(sz)previous] = true;
		}
		// Instructions that emit no code leave the flags alone.
		if (self.folded_away[(sz)ref]) continue;
		switch (inst.tag)
		{
			case CONSTANT:
			case SYMBOL:
			case ALLOC:
				continue;
			default:
				previous = ref;
		}
	}
}

<* The IR compare tag's condition code (signed or unsigned, before any i1 or
   float rewriting). *>
fn Condition compare_condition(ir::InstTag tag)
{
	switch (tag)
	{
		case CMP_EQ: return E;
		case CMP_NE: return NE;
		case CMP_SLT: return L;
		case CMP_SLTE: return LE;
		case CMP_SGT: return G;
		case CMP_SGTE: return GE;
		case CMP_ULT: return B;
		case CMP_ULTE: return BE;
		case CMP_UGT: return A;
		case CMP_UGTE: return AE;
		case FCMP_OEQ: return E;
		case FCMP_UNE: return NE;
		case FCMP_OLT: return B;
		case FCMP_OLE: return BE;
		case FCMP_OGT: return A;
		default: return AE;
	}
}

<* The condition that holds for (b, a) when `cc` holds for (a, b). *>
fn Condition swapped_condition(Condition cc)
{
	switch (cc)
	{
		case A: return B;
		case AE: return BE;
		case B: return A;
		case BE: return AE;
		case G: return L;
		case GE: return LE;
		case L: return G;
		case LE: return GE;
		default: return cc;
	}
}

<*
 @require cc != P && cc != NP : "CMOV has no parity forms here"
*>
fn Mnemonic cmov_mnemonic(Condition cc)
{
	switch (cc)
	{
		case A: return CMOVA;
		case AE: return CMOVAE;
		case B: return CMOVB;
		case BE: return CMOVBE;
		case E: return CMOVE;
		case G: return CMOVG;
		case GE: return CMOVGE;
		case L: return CMOVL;
		case LE: return CMOVLE;
		default: return CMOVNE;
	}
}

<* `ref` lives in an allocated register (not a constant, symbol or ALLOC). *>
fn bool Lowering.in_register(&self, ir::Ref ref)
{
	if (self.spill_all || !self.value_in_reg[(sz)ref]) return false;
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

<* `ref` is an integer (or null pointer) constant encodable as a CMP
   immediate at width `w` (imm8/16/32, sign-extended imm32 at 64 bits). *>
fn bool Lowering.int_immediate(&self, ir::Ref ref, ushort w, long* out)
{
	ir::Inst inst = self.inst(ref);
	if (inst.tag != CONSTANT || self.is_float_type(inst.ty)) return false;
	primitive_value::PrimitiveValue key = self.ir.interner.get(inst.data.constant);
	switch (key.tag)
	{
		case NULL:
			*out = 0;
			return true;
		case INT_POSITIVE:
		case INT_NEGATIVE:
			if (!key.int_fits_64()) return false;
			long value = (long)key.int_low_u64();
			switch (w)
			{
				case 8: value = (long)(ichar)value;
				case 16: value = (long)(short)value;
				case 32: value = (long)(int)value;
				default: if (value != (long)(int)value) return false;
			}
			*out = value;
			return true;
		default:
			return false;
	}
}

<* Emit CMP for integer compare `inst` and return the condition that holds
   when the compare is true. Operands are used in place when they are an
   allocated register, an immediate or a stack slot. *>
fn Condition? Lowering.int_compare_flags(&self, ir::Inst inst)
{
	Condition cc = compare_condition(inst.tag);
	ir::Ref lhs = inst.data.bin.lhs;
	ir::Ref rhs = inst.data.bin.rhs;
	value_interner::InternerRef operand_ty = self.inst(lhs).ty;
	uint ty_bits = 0;
	if (operand_ty != value_interner::REF_PTR)
	{
		primitive_value::PrimitiveValue key = self.ir.interner.get(operand_ty);
		if (key.tag == primitive_value::PrimitiveType.INT_TY) ty_bits = key.ty_bits;
	}
	if (ty_bits == 1)
	{
		// i1 is stored as 0/1, but signed interpretation is 0/-1. Reverse
		// only the signed ordering condition to compare the stored bits.
		switch (inst.tag)
		{
			case CMP_SLT: cc = A;
			case CMP_SLTE: cc = AE;
			case CMP_SGT: cc = B;
			case CMP_SGTE: cc = BE;
			default: break;
		}
	}
	ushort w = self.bits(operand_ty)!;
	if (ty_bits != 0 && ty_bits < w)
	{
		// i1 is zero-extended and uses the reversed unsigned condition above;
		// other odd widths are sign-extended for signed predicates, as LLVM's
		// PromoteSetCCOperands does, and zero-extended otherwise.
		bool signed_predicate = ty_bits != 1 && (inst.tag == CMP_SLT || inst.tag == CMP_SLTE ||
			inst.tag == CMP_SGT || inst.tag == CMP_SGTE);
		self.load(lhs, RAX)!;
		self.load(rhs, RCX)!;
		self.normalize_width(RAX, operand_ty, w, signed_predicate)!;
		self.normalize_width(RCX, operand_ty, w, signed_predicate)!;
		self.emit(CMP, reg_op(Register.RAX.to_bits(w)), reg_op(Register.RCX.to_bits(w)));
		return cc;
	}
	long imm;
	// CMP takes an immediate only on the right.
	if (self.int_immediate(lhs, w, &imm) && !self.int_immediate(rhs, w, &imm))
	{
		ir::Ref swapped = lhs;
		lhs = rhs;
		rhs = swapped;
		cc = swapped_condition(cc);
	}
	Register left = Register.RAX.to_bits(w);
	if (self.in_register(lhs))
	{
		left = self.value_regs[(sz)lhs].to_bits(w);
	}
	else
	{
		self.load(lhs, RAX)!;
	}
	Operand right;
	if (self.int_immediate(rhs, w, &imm))
	{
		right = imm_op(imm);
	}
	else if (self.in_register(rhs))
	{
		right = reg_op(self.value_regs[(sz)rhs].to_bits(w));
	}
	else
	{
		switch (self.inst(rhs).tag)
		{
			case CONSTANT:
			case SYMBOL:
			case ALLOC:
				self.load(rhs, RCX)!;
				right = reg_op(Register.RCX.to_bits(w));
			default:
				right = self.slot(rhs, w);
		}
	}
	self.emit(CMP, reg_op(left), right);
	return cc;
}

<* Emit UCOMISS/UCOMISD for float compare `inst`. `<` and `<=` swap their
   operands and test A/AE, so only equality needs the parity flag. *>
fn FlagCondition? Lowering.float_compare_flags(&self, ir::Inst inst)
{
	Condition cc = compare_condition(inst.tag);
	ir::Ref lhs = inst.data.bin.lhs;
	ir::Ref rhs = inst.data.bin.rhs;
	ParityRule parity = NONE;
	switch (cc)
	{
		case B:
		case BE:
			ir::Ref swapped = lhs;
			lhs = rhs;
			rhs = swapped;
			cc = cc == Condition.B ? Condition.A : Condition.AE;
		case E: parity = AND_NP;
		case NE: parity = OR_P;
		default: break;
	}
	ushort width = self.float_width(self.inst(lhs).ty)!;
	Register left = XMM0;
	if (self.in_register(lhs))
	{
		left = self.value_regs[(sz)lhs];
	}
	else
	{
		self.load_float(lhs, XMM0)!;
	}
	Register right = XMM1;
	if (self.in_register(rhs))
	{
		right = self.value_regs[(sz)rhs];
	}
	else
	{
		self.load_float(rhs, XMM1)!;
	}
	self.emit(width == 32 ? UCOMISS : UCOMISD, reg_op(left), reg_op(right));
	return { cc, parity };
}

<* Set the flags for i1 value `cond` and return the condition meaning "true".
   A fused compare emits its CMP/UCOMIS here; any other i1 is a 0/1 byte. *>
fn FlagCondition? Lowering.condition_flags(&self, ir::Ref cond)
{
	if (self.folded_away[(sz)cond])
	{
		ir::Inst compare = self.inst(cond);
		if (self.is_float_type(self.inst(compare.data.bin.lhs).ty)) return self.float_compare_flags(compare);
		return { self.int_compare_flags(compare)!, NONE };
	}
	if (self.in_register(cond))
	{
		Register reg = self.value_regs[(sz)cond].to_bits(8);
		self.emit(TEST, reg_op(reg), reg_op(reg));
	}
	else
	{
		self.load(cond, RAX)!;
		self.emit(TEST, reg_op(AL), reg_op(AL));
	}
	return { NE, NONE };
}

<* Jump to `label` when the flags say `fc` is `sense`. *>
fn void Lowering.jump_if(&self, FlagCondition fc, bool sense, String label)
{
	Condition cc = fc.cc;
	ParityRule parity = fc.parity;
	if (!sense)
	{
		// !(cc && NP) == !cc || P, and !(cc || P) == !cc && NP.
		cc = cc.negated;
		switch (parity)
		{
			case AND_NP: parity = OR_P;
			case OR_P: parity = AND_NP;
			default: break;
		}
	}
	switch (parity)
	{
		case NONE:
			self.emit(cc.jump, target_op(label));
		case OR_P:
			self.emit(JP, target_op(label));
			self.emit(cc.jump, target_op(label));
		case AND_NP:
			String skip = self.new_edge_label();
			self.emit(JP, target_op(skip));
			self.emit(cc.jump, target_op(label));
			self.emit_label(skip);
	}
}

<* Materialize the flags condition `fc` as 0/1 in AL (clobbers CL). *>
fn void Lowering.set_from_flags(&self, FlagCondition fc)
{
	self.emit(fc.cc.set, reg_op(AL));
	switch (fc.parity)
	{
		case AND_NP:
			self.emit(SETNP, reg_op(CL));
			self.emit(AND, reg_op(AL), reg_op(CL));
		case OR_P:
			self.emit(SETP, reg_op(CL));
			self.emit(OR, reg_op(AL), reg_op(CL));
		default: break;
	}
}

<* Whether entering `target` from the current block runs PHI copies. *>
fn bool Lowering.edge_has_copies(&self, ir::Ref target)
{
	if ((usz)target >= self.label_body_next.len) return false;
	usz start = self.label_body_next[(sz)target];
	if (start == 0) return false;
	for (usz i = start; i < self.decl.body.len && self.inst(self.decl.body[i]).tag == PHI; i++)
	{
		foreach (input : self.inst(self.decl.body[i]).data.phi)
		{
			if (input.label == self.current_label) return true;
		}
	}
	return false;
}

<* JMP to `target` after its PHI copies, or fall into it when it is the next block. *>
fn void? Lowering.jump_or_fall_through(&self, ir::Ref target)
{
	self.edge_copies(target)!;
	if (target != self.fallthrough_label) self.emit(JMP, target_op(self.labels[(sz)target]));
}

<*
 Conditional branch. The Jcc goes straight to a successor whose edge has no
 PHI copies; the other successor's copies follow it, ending in a JMP unless
 that block comes next. When both edges copy, the Jcc goes to a stub that
 does its copies and jumps on.
*>
fn void? Lowering.branch(&self, ir::Ref ref)
{
	ir::BranchData b = self.inst(ref).data.branch;
	ir::Ref then_label = b.then_label;
	ir::Ref else_label = b.else_label;
	bool then_copies = self.edge_has_copies(then_label);
	bool else_copies = self.edge_has_copies(else_label);
	bool jump_then = then_copies != else_copies ? !then_copies : then_label != self.fallthrough_label;
	ir::Ref jump_target = jump_then ? then_label : else_label;
	ir::Ref rest = jump_then ? else_label : then_label;
	bool stub = jump_then ? then_copies : else_copies;
	FlagCondition fc = self.condition_flags(b.cond)!;
	String jump_label = stub ? self.new_edge_label() : self.labels[(sz)jump_target];
	self.jump_if(fc, jump_then, jump_label);
	self.edge_copies(rest)!;
	if (stub || rest != self.fallthrough_label) self.emit(JMP, target_op(self.labels[(sz)rest]));
	if (stub)
	{
		self.emit_label(jump_label);
		self.jump_or_fall_through(jump_target)!;
	}
}

fn void? Lowering.select(&self, ir::Ref ref)
{
	ir::BranchData select = self.inst(ref).data.branch;
	if (!self.is_float_type(self.inst(ref).ty))
	{
		// Both arms are already-materialized SSA values; the CMOV does not
		// speculate arm effects. Arms load first: loading a null constant
		// (XOR) would clobber the condition's flags.
		ushort width = self.bits(self.inst(ref).ty)! <= 32 ? 32 : 64;
		if (self.folded_away[(sz)select.cond])
		{
			// The fused compare uses RAX/RCX, so the arms go to RDX/R11.
			Register result = Register.RDX.to_bits(width);
			Register other = Register.R11.to_bits(width);
			self.load(select.then_label, result)!;
			self.load(select.else_label, other)!;
			FlagCondition fc = self.condition_flags(select.cond)!;
			self.emit(cmov_mnemonic(fc.cc.negated), reg_op(result), reg_op(other));
			self.store(ref, RDX)!;
			return;
		}
		// i1 values are represented as 0/1 in their byte, so testing the byte is enough.
		self.load(select.then_label, Register.RAX.to_bits(width))!;
		self.load(select.else_label, Register.RCX.to_bits(width))!;
		self.load(select.cond, RDX)!;
		self.emit(TEST, reg_op(DL), reg_op(DL));
		self.emit(CMOVE, reg_op(Register.RAX.to_bits(width)), reg_op(Register.RCX.to_bits(width)));
		self.store(ref, RAX)!;
		return;
	}
	// Keep floating-point selects as branches. Moving the bits preserves signed zero and NaN payloads.
	String else_label = self.new_edge_label();
	String done_label = self.new_edge_label();
	self.jump_if(self.condition_flags(select.cond)!, false, else_label);
	self.load_float(select.then_label, XMM0)!;
	self.store_float(ref, XMM0)!;
	self.emit(JMP, target_op(done_label));
	self.emit_label(else_label);
	self.load_float(select.else_label, XMM0)!;
	self.store_float(ref, XMM0)!;
	self.emit_label(done_label);
}
