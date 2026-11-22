// Local instruction combining for boolean and integer IR patterns.
module aro::backend::ir_opt;
import aro::backend::ir, aro::primitive_value, aro::value_interner;

fn ir::Ref instcombine_int_constant(ir::Ir* graph, DeclEditor* editor, ushort width, ulong bits, value_interner::InternerRef ty)
{
	if (width == 1) return editor.add_constant(bits == 0 ? value_interner::REF_ZERO : value_interner::REF_ONE, ty);
	return editor.add_constant(graph.interner.put(primitive_value::int_key(const_prop_signed(bits, width))), ty);
}

fn bool instcombine_is_compare(ir::InstTag tag)
{
	switch (tag)
	{
		case CMP_EQ: return true;
		case CMP_NE: return true;
		case CMP_SLT: return true;
		case CMP_SLTE: return true;
		case CMP_SGT: return true;
		case CMP_SGTE: return true;
		case CMP_ULT: return true;
		case CMP_ULTE: return true;
		case CMP_UGT: return true;
		case CMP_UGTE: return true;
		case FCMP_OEQ: return true;
		case FCMP_UNE: return true;
		default: return false;
	}
}

fn bool instcombine_bool_not(ir::Ir* graph, ir::Inst[] insts, ir::Inst inst, ir::Ref* operand)
{
	if (inst.ty != value_interner::REF_I1) return false;
	if (inst.tag == ir::InstTag.BIT_XOR)
	{
		ulong bits;
		ir::Ref value = inst.data.bin.lhs;
		ir::Ref constant = inst.data.bin.rhs;
		if (!scalar_constant_bits(graph, insts, constant, &bits))
		{
			value = inst.data.bin.rhs;
			constant = inst.data.bin.lhs;
			if (!scalar_constant_bits(graph, insts, constant, &bits)) return false;
		}
		if (bits != 1 || (usz)value >= (usz)insts.len || insts[(sz)value].ty != value_interner::REF_I1 || insts[(sz)constant].ty != value_interner::REF_I1) return false;
		*operand = value;
		return true;
	}
	if (inst.tag != ir::InstTag.CMP_EQ && inst.tag != ir::InstTag.CMP_NE) return false;
	ir::Ref value = inst.data.bin.lhs;
	ir::Ref constant = inst.data.bin.rhs;
	ulong bits;
	if (!scalar_constant_bits(graph, insts, constant, &bits))
	{
		value = inst.data.bin.rhs;
		constant = inst.data.bin.lhs;
		if (!scalar_constant_bits(graph, insts, constant, &bits)) return false;
	}
	if ((usz)value >= (usz)insts.len || (usz)constant >= (usz)insts.len || insts[(sz)value].ty != value_interner::REF_I1 || insts[(sz)constant].ty != value_interner::REF_I1) return false;
	if (!((bits == 0 && inst.tag == ir::InstTag.CMP_EQ) || (bits == 1 && inst.tag == ir::InstTag.CMP_NE))) return false;
	*operand = value;
	return true;
}

fn bool instcombine_bool_identity(ir::Ir* graph, ir::Inst[] insts, ir::Inst inst, ir::Ref* operand)
{
	if (inst.ty != value_interner::REF_I1 || (inst.tag != ir::InstTag.CMP_EQ && inst.tag != ir::InstTag.CMP_NE)) return false;
	ir::Ref value = inst.data.bin.lhs;
	ir::Ref constant = inst.data.bin.rhs;
	ulong bits;
	if (!scalar_constant_bits(graph, insts, constant, &bits))
	{
		value = inst.data.bin.rhs;
		constant = inst.data.bin.lhs;
		if (!scalar_constant_bits(graph, insts, constant, &bits)) return false;
	}
	if ((usz)value >= (usz)insts.len || (usz)constant >= (usz)insts.len || insts[(sz)value].ty != value_interner::REF_I1 || insts[(sz)constant].ty != value_interner::REF_I1) return false;
	if (!((bits == 0 && inst.tag == ir::InstTag.CMP_NE) || (bits == 1 && inst.tag == ir::InstTag.CMP_EQ))) return false;
	*operand = value;
	return true;
}

fn ir::InstTag instcombine_unsigned_equivalent(ir::InstTag tag)
{
	switch (tag)
	{
		case CMP_SLT: return ir::InstTag.CMP_ULT;
		case CMP_SLTE: return ir::InstTag.CMP_ULTE;
		case CMP_SGT: return ir::InstTag.CMP_UGT;
		case CMP_SGTE: return ir::InstTag.CMP_UGTE;
		default: return tag;
	}
}

fn ir::InstTag instcombine_reverse_compare(ir::InstTag tag)
{
	switch (tag)
	{
		case CMP_SLT: return ir::InstTag.CMP_SGT;
		case CMP_SLTE: return ir::InstTag.CMP_SGTE;
		case CMP_SGT: return ir::InstTag.CMP_SLT;
		case CMP_SGTE: return ir::InstTag.CMP_SLTE;
		case CMP_ULT: return ir::InstTag.CMP_UGT;
		case CMP_ULTE: return ir::InstTag.CMP_UGTE;
		case CMP_UGT: return ir::InstTag.CMP_ULT;
		case CMP_UGTE: return ir::InstTag.CMP_ULTE;
		default: return tag;
	}
}

<* Simplify one instruction. `replacement` is set for value replacement; CFG/value operands may also be edited in place. *>
fn bool instcombine_inst(ir::Ir* graph, DeclEditor* editor, ir::Ref ref, ir::Ref* replacement)
{
	*replacement = ir::NONE;
	if ((usz)ref >= (usz)editor.insts.len()) return false;
	// Keep this copy before appending constants, which may grow the instruction list.
	ir::Inst inst = editor.insts.entries[(sz)ref];
	ir::Inst[] insts = editor.insts.array_view();
	ir::Ref outer;
	if (instcombine_bool_not(graph, insts, inst, &outer) && outer != ref && (usz)outer < (usz)insts.len)
	{
		ir::Ref inner;
		if (instcombine_bool_not(graph, insts, insts[(sz)outer], &inner) && inner != ref) { *replacement = inner; return true; }
	}

	if (inst.tag == ir::InstTag.CMP_EQ || inst.tag == ir::InstTag.CMP_NE)
	{
		if (inst.ty == value_interner::REF_I1)
		{
			ir::Ref operand;
			if (instcombine_bool_identity(graph, insts, inst, &operand)) { *replacement = operand; return true; }
			if (instcombine_bool_not(graph, insts, inst, &operand) && (usz)operand < (usz)insts.len && instcombine_is_compare(insts[(sz)operand].tag))
			{
				ir::Inst compared = insts[(sz)operand];
				ir::InstTag inverse = ir::inverse_compare(compared.tag)!!;
				editor.insts.entries[(sz)ref] = { .tag = inverse, .data.bin = compared.data.bin, .ty = value_interner::REF_I1 };
				return true;
			}
		}
		if (inst.data.bin.lhs == inst.data.bin.rhs)
		{
			ushort width;
			if (const_prop_int_width(graph, inst.ty, &width))
			{
				*replacement = instcombine_int_constant(graph, editor, width, inst.tag == ir::InstTag.CMP_EQ ? 1 : 0, inst.ty);
				return *replacement != ir::NONE;
			}
		}
	}

	if (inst.tag == ir::InstTag.BRANCH || inst.tag == ir::InstTag.SELECT)
	{
		ir::Ref condition = inst.data.branch.cond;
		if ((usz)condition < (usz)insts.len)
		{
			ir::Inst cond_inst = insts[(sz)condition];
			ir::Ref operand;
			if (instcombine_bool_not(graph, insts, cond_inst, &operand))
			{
				editor.insts.entries[(sz)ref].data.branch.cond = operand;
				ir::Ref tmp = editor.insts.entries[(sz)ref].data.branch.then_label;
				editor.insts.entries[(sz)ref].data.branch.then_label = editor.insts.entries[(sz)ref].data.branch.else_label;
				editor.insts.entries[(sz)ref].data.branch.else_label = tmp;
				return true;
			}
			if (instcombine_bool_identity(graph, insts, cond_inst, &operand))
			{
				editor.insts.entries[(sz)ref].data.branch.cond = operand;
				return true;
			}
		}
	}

	if (inst.tag == ir::InstTag.SELECT)
	{
		if (inst.data.branch.then_label == inst.data.branch.else_label) { *replacement = inst.data.branch.then_label; return true; }
		if (inst.ty == value_interner::REF_I1)
		{
			ulong yes, no;
			if ((usz)inst.data.branch.then_label < (usz)insts.len && (usz)inst.data.branch.else_label < (usz)insts.len &&
				insts[(sz)inst.data.branch.then_label].ty == value_interner::REF_I1 && insts[(sz)inst.data.branch.else_label].ty == value_interner::REF_I1 &&
				scalar_constant_bits(graph, insts, inst.data.branch.then_label, &yes) && scalar_constant_bits(graph, insts, inst.data.branch.else_label, &no) && yes <= 1 && no <= 1)
			{
				if (yes == 1 && no == 0) { *replacement = inst.data.branch.cond; return true; }
				if (yes == 0 && no == 1 && (usz)inst.data.branch.cond < (usz)insts.len && instcombine_is_compare(insts[(sz)inst.data.branch.cond].tag))
				{
					ir::Inst cond = insts[(sz)inst.data.branch.cond];
					ir::InstTag inverse = ir::inverse_compare(cond.tag)!!;
					editor.insts.entries[(sz)ref] = { .tag = inverse, .data.bin = cond.data.bin, .ty = value_interner::REF_I1 };
					return true;
				}
			}
		}
	}

	// Merge cast chains when their composition has the same integer result.
	if (inst.tag == ir::InstTag.TRUNC || inst.tag == ir::InstTag.ZEXT || inst.tag == ir::InstTag.SEXT)
	{
		if ((usz)inst.data.ref < (usz)insts.len)
		{
			ir::Inst inner = insts[(sz)inst.data.ref];
			if (inner.tag == ir::InstTag.TRUNC || inner.tag == ir::InstTag.ZEXT || inner.tag == ir::InstTag.SEXT)
			{
				ushort source_width, middle_width, target_width;
				// i128 cast pairs are skipped by const_prop_int_width; LLVM handles these in CastInst::isEliminableCastPair.
				if ((usz)inner.data.ref < (usz)insts.len && insts[(sz)inner.data.ref].tag != ir::InstTag.CONSTANT &&
					const_prop_int_width(graph, insts[(sz)inner.data.ref].ty, &source_width) &&
					const_prop_int_width(graph, inner.ty, &middle_width) && const_prop_int_width(graph, inst.ty, &target_width))
				{
					bool inner_valid = inner.tag == ir::InstTag.TRUNC ? middle_width < source_width : source_width < middle_width;
					bool outer_valid = inst.tag == ir::InstTag.TRUNC ? target_width < middle_width : middle_width < target_width;
					if (inner_valid && outer_valid)
					{
						if ((inst.tag == ir::InstTag.TRUNC && inner.tag == ir::InstTag.TRUNC) ||
							(inst.tag == ir::InstTag.ZEXT && inner.tag == ir::InstTag.ZEXT) ||
							(inst.tag == ir::InstTag.SEXT && inner.tag == ir::InstTag.SEXT))
						{
							editor.insts.entries[(sz)ref].data.ref = inner.data.ref;
							return true;
						}
						if (inst.tag == ir::InstTag.SEXT && inner.tag == ir::InstTag.ZEXT)
						{
							editor.insts.entries[(sz)ref].tag = ir::InstTag.ZEXT;
							editor.insts.entries[(sz)ref].data.ref = inner.data.ref;
							return true;
						}
						if (inst.tag == ir::InstTag.TRUNC && (inner.tag == ir::InstTag.ZEXT || inner.tag == ir::InstTag.SEXT))
						{
							if (target_width < source_width)
							{
								editor.insts.entries[(sz)ref].tag = ir::InstTag.TRUNC;
								editor.insts.entries[(sz)ref].data.ref = inner.data.ref;
								return true;
							}
							if (target_width == source_width)
							{
								*replacement = inner.data.ref;
								return true;
							}
							if (target_width > source_width)
							{
								editor.insts.entries[(sz)ref].tag = inner.tag;
								editor.insts.entries[(sz)ref].data.ref = inner.data.ref;
								return true;
							}
						}
					}
				}
			}
		}
	}

	// Canonicalize x - C as x + (-C mod 2^N).
	if (inst.tag == ir::InstTag.SUB)
	{
		ushort width;
		if (const_prop_int_width(graph, inst.ty, &width) && width > 0 &&
			(usz)inst.data.bin.lhs < (usz)insts.len && (usz)inst.data.bin.rhs < (usz)insts.len &&
			insts[(sz)inst.data.bin.lhs].ty == inst.ty && insts[(sz)inst.data.bin.rhs].ty == inst.ty)
		{
			ulong constant_bits;
			if (scalar_constant_bits(graph, insts, inst.data.bin.rhs, &constant_bits))
			{
				ulong negated = (0 - constant_bits) & const_prop_mask(width);
				ir::Ref constant = instcombine_int_constant(graph, editor, width, negated, inst.ty);
				if (constant == ir::NONE) return false;
				editor.insts.entries[(sz)ref] = { .tag = ir::InstTag.ADD, .data.bin = { inst.data.bin.lhs, constant }, .ty = inst.ty };
				return true;
			}
		}
	}

	// Combine constants in (x op C1) op C2, keeping the outer instruction.
	if (inst.tag == ir::InstTag.ADD || inst.tag == ir::InstTag.MUL || inst.tag == ir::InstTag.BIT_AND ||
		inst.tag == ir::InstTag.BIT_OR || inst.tag == ir::InstTag.BIT_XOR)
	{
		ushort width;
		if (const_prop_int_width(graph, inst.ty, &width) && width > 0 &&
			(usz)inst.data.bin.lhs < (usz)insts.len && (usz)inst.data.bin.rhs < (usz)insts.len)
		{
			ir::Ref inner_ref = ir::NONE;
			ir::Ref outer_constant = ir::NONE;
			ulong outer_bits;
			if (insts[(sz)inst.data.bin.lhs].tag == inst.tag && insts[(sz)inst.data.bin.lhs].ty == inst.ty &&
				scalar_constant_bits(graph, insts, inst.data.bin.rhs, &outer_bits))
			{
				inner_ref = inst.data.bin.lhs;
				outer_constant = inst.data.bin.rhs;
			}
			else if (insts[(sz)inst.data.bin.rhs].tag == inst.tag && insts[(sz)inst.data.bin.rhs].ty == inst.ty &&
				scalar_constant_bits(graph, insts, inst.data.bin.lhs, &outer_bits))
			{
				inner_ref = inst.data.bin.rhs;
				outer_constant = inst.data.bin.lhs;
			}
			ulong c1, c2;
			if (inner_ref != ir::NONE && outer_constant != ir::NONE)
			{
				ir::Inst inner = insts[(sz)inner_ref];
				ir::Ref inner_constant = ir::NONE;
				ir::Ref value = ir::NONE;
				if ((usz)inner.data.bin.lhs < (usz)insts.len && insts[(sz)inner.data.bin.lhs].ty == inst.ty &&
					scalar_constant_bits(graph, insts, inner.data.bin.lhs, &c1))
				{
					inner_constant = inner.data.bin.lhs;
					value = inner.data.bin.rhs;
				}
				else if ((usz)inner.data.bin.rhs < (usz)insts.len && insts[(sz)inner.data.bin.rhs].ty == inst.ty &&
					scalar_constant_bits(graph, insts, inner.data.bin.rhs, &c1))
				{
					inner_constant = inner.data.bin.rhs;
					value = inner.data.bin.lhs;
				}
				if (inner_constant != ir::NONE && value != ref && (usz)value < (usz)insts.len && insts[(sz)value].ty == inst.ty &&
					insts[(sz)outer_constant].ty == inst.ty && scalar_constant_bits(graph, insts, outer_constant, &c2))
				{
					ulong mask = const_prop_mask(width);
					if (inst.tag == ir::InstTag.ADD) { c1 = (c1 + c2) & mask; }
					else if (inst.tag == ir::InstTag.MUL) { c1 = (c1 * c2) & mask; }
					else if (inst.tag == ir::InstTag.BIT_AND) { c1 = (c1 & c2) & mask; }
					else if (inst.tag == ir::InstTag.BIT_OR) { c1 = (c1 | c2) & mask; }
					else { c1 = (c1 ^ c2) & mask; }
					ir::Ref combined = instcombine_int_constant(graph, editor, width, c1, inst.ty);
					if (combined == ir::NONE) return false;
					editor.insts.entries[(sz)ref].data.bin = { value, combined };
					return true;
				}
			}
		}
	}

	if (instcombine_is_compare(inst.tag))
	{
		if ((usz)inst.data.bin.lhs >= (usz)insts.len || (usz)inst.data.bin.rhs >= (usz)insts.len) return false;
		ir::Inst lhs = insts[(sz)inst.data.bin.lhs];
		ir::Inst rhs = insts[(sz)inst.data.bin.rhs];
		ushort compare_width;
		if (!const_prop_int_width(graph, lhs.ty, &compare_width)) return false;

		// Deliberate subset: LLVM foldICmpWithZextOrSext also handles mixed extensions and different source widths.
		// Paired extensions with equal source types can be compared at the source width.
		if ((lhs.tag == ir::InstTag.ZEXT || lhs.tag == ir::InstTag.SEXT) && rhs.tag == lhs.tag && lhs.ty == rhs.ty &&
			(usz)lhs.data.ref < (usz)insts.len && (usz)rhs.data.ref < (usz)insts.len)
		{
			ir::Inst x = insts[(sz)lhs.data.ref];
			ir::Inst y = insts[(sz)rhs.data.ref];
			ushort source_width, other_source_width;
			if (x.ty == y.ty && const_prop_int_width(graph, x.ty, &source_width) && const_prop_int_width(graph, y.ty, &other_source_width) &&
				source_width == other_source_width && source_width < compare_width)
			{
				if (lhs.tag == ir::InstTag.SEXT && source_width == 1 &&
					(inst.tag == ir::InstTag.CMP_SLT || inst.tag == ir::InstTag.CMP_SLTE || inst.tag == ir::InstTag.CMP_SGT || inst.tag == ir::InstTag.CMP_SGTE)) return false;
				ir::InstTag new_tag = inst.tag;
				if (lhs.tag == ir::InstTag.ZEXT)
				{
					new_tag = instcombine_unsigned_equivalent(inst.tag);
				}
				editor.insts.entries[(sz)ref] = { .tag = new_tag, .data.bin = { lhs.data.ref, rhs.data.ref }, .ty = inst.ty };
				return true;
			}
		}

		// Normalize a single extension against a constant, allowing the extension on either side.
		bool extension_on_lhs = lhs.tag == ir::InstTag.ZEXT || lhs.tag == ir::InstTag.SEXT;
		bool extension_on_rhs = rhs.tag == ir::InstTag.ZEXT || rhs.tag == ir::InstTag.SEXT;
		ir::Inst ext = extension_on_lhs ? lhs : rhs;
		ir::Inst constant = extension_on_lhs ? rhs : lhs;
		if ((extension_on_lhs || extension_on_rhs) && constant.tag == ir::InstTag.CONSTANT && (usz)ext.data.ref < (usz)insts.len)
		{
			ushort source_width, ext_width;
			ulong bits;
			if (const_prop_int_width(graph, insts[(sz)ext.data.ref].ty, &source_width) && const_prop_int_width(graph, ext.ty, &ext_width) &&
				source_width < ext_width && ext_width == compare_width && scalar_constant_bits(graph, insts, extension_on_lhs ? inst.data.bin.rhs : inst.data.bin.lhs, &bits))
			{
				ir::InstTag predicate = extension_on_lhs ? inst.tag : instcombine_reverse_compare(inst.tag);
				ulong source_mask = const_prop_mask(source_width);
				long min_value = source_width == 64 ? long::min : -((long)1 << (source_width - 1));
				long max_value = source_width == 64 ? long::max : (((long)1 << (source_width - 1)) - 1);
				bool fits = false;
				if (ext.tag == ir::InstTag.ZEXT) { fits = bits <= source_mask; }
				else
				{
					// source_width is below ext_width <= 64, so the 64-bit bounds are unreachable; retained for clarity.
					// LLVM's corresponding fold is foldICmpWithZextOrSext.
					long signed_bits = const_prop_signed(bits, ext_width);
					fits = signed_bits >= min_value && signed_bits <= max_value;
				}
				if (ext.tag == ir::InstTag.SEXT && source_width == 1 &&
					(predicate == ir::InstTag.CMP_SLT || predicate == ir::InstTag.CMP_SLTE || predicate == ir::InstTag.CMP_SGT || predicate == ir::InstTag.CMP_SGTE)) return false;
				if (fits)
				{
					ir::InstTag new_tag = predicate;
					ulong new_bits = bits & source_mask;
					if (ext.tag == ir::InstTag.ZEXT)
					{
						new_tag = instcombine_unsigned_equivalent(predicate);
					}
					ir::Ref c = instcombine_int_constant(graph, editor, source_width, new_bits, insts[(sz)ext.data.ref].ty);
					// predicate already accounts for swapping when the extension was on the RHS;
					// keep the narrow value on the left to preserve that predicate's operand order.
					editor.insts.entries[(sz)ref] = { .tag = new_tag, .data.bin = { ext.data.ref, c }, .ty = inst.ty };
					return true;
				}
				if (ext.tag == ir::InstTag.ZEXT || predicate == ir::InstTag.CMP_EQ || predicate == ir::InstTag.CMP_NE ||
					(extension_on_rhs && (predicate == ir::InstTag.CMP_SLT || predicate == ir::InstTag.CMP_SLTE ||
					predicate == ir::InstTag.CMP_SGT || predicate == ir::InstTag.CMP_SGTE)))
				{
					bool result = false;
					if (ext.tag == ir::InstTag.ZEXT)
					{
						switch (predicate)
						{
							case CMP_EQ: result = false;
							case CMP_NE: result = true;
							case CMP_ULT: result = true;
							case CMP_ULTE: result = true;
							case CMP_UGT: result = false;
							case CMP_UGTE: result = false;
							// Deliberate simplification: LLVM simplifyICmpInst folds these by the sign of C.
							case CMP_SLT: return false;
							case CMP_SLTE: return false;
							case CMP_SGT: return false;
							case CMP_SGTE: return false;
							default: return false;
						}
					}
					// Deliberate simplification: LLVM simplifyICmpInst and foldICmpWithZextOrSext
					// also fold signed predicates and rewrite some unsigned predicates for out-of-range C.
					else if (predicate == ir::InstTag.CMP_EQ || predicate == ir::InstTag.CMP_NE)
					{
						result = predicate == ir::InstTag.CMP_NE;
					}
					else
					{
						long signed_bits = const_prop_signed(bits, ext_width);
						if (signed_bits < min_value)
						{
							result = predicate == ir::InstTag.CMP_SGT || predicate == ir::InstTag.CMP_SGTE;
						}
						else if (signed_bits > max_value)
						{
							result = predicate == ir::InstTag.CMP_SLT || predicate == ir::InstTag.CMP_SLTE;
						}
					}
					*replacement = instcombine_int_constant(graph, editor, 1, result ? 1 : 0, value_interner::REF_I1);
					return *replacement != ir::NONE;
				}
			}
		}
	}
	return false;
}
