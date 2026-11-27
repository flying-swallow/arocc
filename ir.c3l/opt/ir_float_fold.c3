// IEEE constant folding for scalar floating point IR.
module aro::backend::ir_opt;
import aro::backend::ir, aro::primitive_value, aro::value_interner, aro::bigint;
import std::collections::list;

fn bool float_fold_type(ir::Ir* graph, value_interner::InternerRef ty, primitive_value::PrimitiveType* tag)
{
	primitive_value::PrimitiveValue type_key = graph.interner.get(ty);
	if (type_key.tag != primitive_value::PrimitiveType.FLOAT_TY) return false;
	switch (type_key.ty_bits)
	{
		case 32: *tag = primitive_value::PrimitiveType.F32; return true;
		case 64: *tag = primitive_value::PrimitiveType.F64; return true;
		case 80: *tag = primitive_value::PrimitiveType.F80; return true;
		default: return false;
	}
}

fn bool float_fold_signaling_nan(primitive_value::PrimitiveValue value)
{
	if (!value.is_nan()) return false;
	// The quiet bit is the most significant stored fraction bit, including F80.
	return (value.float_bits() & ((uint128)1 << (value.tag.format.frac_bits - 1))) == 0;
}

<* x87 encodings with an exponent and explicit integer bit that disagree are noncanonical. *>
fn bool float_fold_canonical_f80(primitive_value::PrimitiveValue value)
{
	if (value.tag != primitive_value::PrimitiveType.F80) return true;
	primitive_value::F80Bits bits = value.f80();
	bool exponent_zero = (bits.hi & 0x7FFF) == 0;
	bool integer_bit = (bits.lo >> 63) != 0;
	return exponent_zero || integer_bit;
}

<* Read a float constant, accounting for the interner's shared zero/one refs. *>
fn bool float_fold_constant(ir::Ir* graph, ir::Inst[] insts, ir::Ref ref, primitive_value::PrimitiveType expected,
	primitive_value::PrimitiveValue* value)
{
	if ((usz)ref >= (usz)insts.len || insts[(sz)ref].tag != ir::InstTag.CONSTANT) return false;
	primitive_value::PrimitiveType constant_tag;
	if (!float_fold_type(graph, insts[(sz)ref].ty, &constant_tag) || constant_tag != expected) return false;
	primitive_value::PrimitiveValue key = graph.interner.get(insts[(sz)ref].data.constant);
	if (key.tag.kind == primitive_value::NumberKind.FLOAT)
	{
		if (key.tag != expected) return false;
		*value = key;
		return true;
	}
	// Float +0 and 1.0 map to REF_ZERO/REF_ONE, whose key is integer zero/one.
	if (insts[(sz)ref].data.constant == value_interner::REF_ZERO)
	{
		*value = primitive_value::zero(expected);
	}
	else if (insts[(sz)ref].data.constant == value_interner::REF_ONE)
	{
		*value = primitive_value::one(expected);
	}
	else { return false; }
	return true;
}

fn bool float_fold_compare(primitive_value::PrimitiveValue lhs, primitive_value::PrimitiveValue rhs, ir::InstTag tag)
{
	switch (tag)
	{
		case FCMP_OEQ: return lhs.compare(bigint::CompareOperator.EQ, rhs);
		case FCMP_UNE: return lhs.compare(bigint::CompareOperator.NEQ, rhs);
		case FCMP_OLT: return lhs.compare(bigint::CompareOperator.LT, rhs);
		case FCMP_OLE: return lhs.compare(bigint::CompareOperator.LTE, rhs);
		case FCMP_OGT: return lhs.compare(bigint::CompareOperator.GT, rhs);
		case FCMP_OGE: return lhs.compare(bigint::CompareOperator.GTE, rhs);
		default: return false;
	}
}

fn bool float_fold_is_compare(ir::InstTag tag)
{
	switch (tag)
	{
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE: return true;
		default: return false;
	}
}

<* Fold a constant floating point operation. Non-finite and out-of-range float-to-int
   conversions are left in IR because their language-level result is not portable. *>
fn ir::Ref float_fold_value(ir::Ir* graph, DeclEditor* editor, ir::Inst inst)
{
	primitive_value::PrimitiveType result_tag;
	primitive_value::PrimitiveValue lhs, rhs, result;
	ushort int_width;
	switch (inst.tag)
	{
		case FNEG: case FABS: return ir::NONE;
		case FADD: case FSUB: case FMUL: case FDIV:
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
			if (!float_fold_type(graph, inst.ty, &result_tag))
			{
				// Comparisons return i1; derive their operand format instead.
				if (!float_fold_is_compare(inst.tag) ||
					(usz)inst.data.bin.lhs >= (usz)editor.insts.len()) return ir::NONE;
				if (!float_fold_type(graph, editor.insts.entries[(sz)inst.data.bin.lhs].ty, &result_tag)) return ir::NONE;
			}
			if (!float_fold_constant(graph, editor.insts.array_view(), inst.data.bin.lhs, result_tag, &lhs) ||
				!float_fold_constant(graph, editor.insts.array_view(), inst.data.bin.rhs, result_tag, &rhs)) return ir::NONE;
			if (float_fold_is_compare(inst.tag))
			{
				if (float_fold_signaling_nan(lhs) || float_fold_signaling_nan(rhs)) return ir::NONE;
				return editor.add_constant(float_fold_compare(lhs, rhs, inst.tag) ? value_interner::REF_ONE : value_interner::REF_ZERO, inst.ty);
			}
			if (lhs.is_nan() || rhs.is_nan()) return ir::NONE;
			switch (inst.tag)
			{
				case FADD: result = lhs.add(rhs);
				case FSUB: result = lhs.sub(rhs);
				case FMUL: result = lhs.mul(rhs);
				case FDIV: result = lhs.div(rhs);
				default: return ir::NONE;
			}
			if (result.is_nan()) return ir::NONE;
			return editor.add_constant(graph.interner.put(result), inst.ty);
		case FPEXT: case FPTRUNC:
			if (!float_fold_type(graph, inst.ty, &result_tag) || (usz)inst.data.ref >= (usz)editor.insts.len()) return ir::NONE;
			primitive_value::PrimitiveType source_tag;
			if (!float_fold_type(graph, editor.insts.entries[(sz)inst.data.ref].ty, &source_tag) ||
				!float_fold_constant(graph, editor.insts.array_view(), inst.data.ref, source_tag, &lhs) ||
				lhs.is_nan() || !float_fold_canonical_f80(lhs) ||
				(inst.tag == ir::InstTag.FPEXT && source_tag.width >= result_tag.width) ||
				(inst.tag == ir::InstTag.FPTRUNC && source_tag.width <= result_tag.width)) return ir::NONE;
			return editor.add_constant(graph.interner.put(lhs.cast(result_tag)), inst.ty);
		case SITOFP: case UITOFP:
			if (!float_fold_type(graph, inst.ty, &result_tag) || (usz)inst.data.ref >= (usz)editor.insts.len()) return ir::NONE;
			ushort source_width;
			ulong source_bits;
			if (!const_prop_int_width(graph, editor.insts.entries[(sz)inst.data.ref].ty, &source_width) ||
				!scalar_constant_bits(graph, editor.insts.array_view(), inst.data.ref, &source_bits)) return ir::NONE;
			if (inst.tag == ir::InstTag.SITOFP)
			{
				result = primitive_value::from_i64(const_prop_signed(source_bits, source_width), result_tag);
			}
			else
			{
				result = primitive_value::from_u64(source_bits, result_tag);
			}
			return editor.add_constant(graph.interner.put(result), inst.ty);
		case FPTOSI: case FPTOUI:
			if ((usz)inst.data.ref >= (usz)editor.insts.len() ||
				!float_fold_type(graph, editor.insts.entries[(sz)inst.data.ref].ty, &result_tag) ||
				!float_fold_constant(graph, editor.insts.array_view(), inst.data.ref, result_tag, &lhs) || !lhs.is_finite()) return ir::NONE;
			if (!const_prop_int_width(graph, inst.ty, &int_width)) return ir::NONE;
			primitive_value::F128Bits wide = lhs.to_f128();
			bigint::Signedness sign = inst.tag == ir::InstTag.FPTOSI ? bigint::Signedness.SIGNED : bigint::Signedness.UNSIGNED;
			int unbiased = (int)primitive_value::f128_exp_field(wide) - 16383;
			bool negative = lhs.signbit();
			// Keep the software conversion's two-limb buffer bounded. Unsigned
			// values in (-1, 0) truncate to zero and are valid.
			if (unbiased > 63 || (sign == bigint::Signedness.UNSIGNED && negative && unbiased >= 0) ||
				(sign == bigint::Signedness.SIGNED && !negative && unbiased >= 63)) return ir::NONE;
			bigint::Limb[2] limbs;
			bigint::BigIntMutable converted = { .limbs = limbs[..] };
			primitive_value::f128_to_big_int_trunc(wide, &converted);
			bigint::BigIntConst integer = converted.to_const();
			if (!integer.fits_in_twos_comp(sign, int_width)) return ir::NONE;
			ulong output_bits;
			if (sign == bigint::Signedness.SIGNED)
			{
				output_bits = (ulong)integer.to_i64()!!;
			}
			else
			{
				output_bits = integer.to_u64()!!;
			}
			return scalar_constant(graph, editor, int_width, output_bits, inst.ty);
		default: return ir::NONE;
	}
}
