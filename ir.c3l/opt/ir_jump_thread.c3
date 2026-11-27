// Conservative SSA jump threading for short, constant PHI-fed branch chains.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, aro::primitive_value, std::collections::list;

fn bool jump_thread_supported(ir::InstTag tag)
{
	switch (tag)
	{
		case ir::InstTag.ZEXT: case ir::InstTag.SEXT: case ir::InstTag.TRUNC:
		case ir::InstTag.CMP_EQ: case ir::InstTag.CMP_NE:
		case ir::InstTag.CMP_SLT: case ir::InstTag.CMP_SLTE:
		case ir::InstTag.CMP_SGT: case ir::InstTag.CMP_SGTE:
		case ir::InstTag.CMP_ULT: case ir::InstTag.CMP_ULTE:
		case ir::InstTag.CMP_UGT: case ir::InstTag.CMP_UGTE: return true;
		default: return false;
	}
}

fn bool jump_thread_phi_input_only(ir::Inst inst, ir::Ref label, ir::Ref value)
{
	if (inst.tag != ir::InstTag.PHI) return false;
	bool found = false;
	foreach (input : inst.data.phi) if (input.value == value)
	{
		if (input.label != label) return false;
		found = true;
	}
	return found;
}

fn bool jump_thread_edge_to(Cfg* cfg, CfgBlock* pred, uint pred_index, uint target_index, sz term_pos)
{
	if (term_pos == pred.end) return pred_index + 1 == target_index;
	ir::Ref ref = cfg.decl.body[term_pos];
	ir::Inst* term = &cfg.decl.instructions[(sz)ref];
	switch (term.tag)
	{
		case ir::InstTag.JMP:
			return (usz)term.data.ref < (usz)cfg.block_of_ref.len &&
				cfg.block_of_ref[(sz)term.data.ref] == target_index;
		case ir::InstTag.BRANCH:
			bool then_matches = (usz)term.data.branch.then_label < (usz)cfg.block_of_ref.len &&
				cfg.block_of_ref[(sz)term.data.branch.then_label] == target_index;
			bool else_matches = (usz)term.data.branch.else_label < (usz)cfg.block_of_ref.len &&
				cfg.block_of_ref[(sz)term.data.branch.else_label] == target_index;
			return then_matches != else_matches;
		default: return false;
	}
}

fn bool jump_thread_is_loop_header(Cfg* cfg, uint block_index)
{
	foreach (pred : cfg.blocks[(sz)block_index].preds)
	{
		if (cfg.dominates(block_index, pred)) return true;
	}
	return false;
}

<* Fold `ref` from known PHI constants. Every `values` slot written is pushed on
   `touched` so the caller can reset only those between candidates. *>
fn bool jump_thread_eval(ir::Ir* graph, ir::Decl* decl, ir::Inst[] insts,
	ConstPropValue[] values, list::List{ir::Ref}* touched, ir::Ref ref, uint depth)
{
	if (depth > 4 || (usz)ref >= (usz)insts.len) return false;
	if (values[(sz)ref].tag == ConstPropTag.CONSTANT) return true;
	ir::Inst* inst = &insts[(sz)ref];
	if (inst.tag == ir::InstTag.CONSTANT)
	{
		touched.push(ref);
		values[(sz)ref] = const_prop_constant_inst(graph, inst);
		return values[(sz)ref].tag == ConstPropTag.CONSTANT;
	}
	if (!jump_thread_supported(inst.tag)) return false;
	if (inst.tag == ir::InstTag.ZEXT || inst.tag == ir::InstTag.SEXT || inst.tag == ir::InstTag.TRUNC)
	{
		if (!jump_thread_eval(graph, decl, insts, values, touched, inst.data.ref, depth + 1)) return false;
	}
	else
	{
		if (!jump_thread_eval(graph, decl, insts, values, touched, inst.data.bin.lhs, depth + 1) ||
			!jump_thread_eval(graph, decl, insts, values, touched, inst.data.bin.rhs, depth + 1)) return false;
	}
	if (inst.tag == ir::InstTag.ZEXT || inst.tag == ir::InstTag.SEXT || inst.tag == ir::InstTag.TRUNC)
	{
		ushort src_width, dst_width;
		if (!const_prop_int_width(graph, insts[(sz)inst.data.ref].ty, &src_width) ||
			!const_prop_int_width(graph, inst.ty, &dst_width)) return false;
		ulong bits = values[(sz)inst.data.ref].bits & const_prop_mask(src_width);
		if (inst.tag == ir::InstTag.SEXT) bits = (ulong)const_prop_signed(bits, src_width);
		touched.push(ref);
		values[(sz)ref] = const_prop_constant(dst_width, bits);
	}
	else
	{
		touched.push(ref);
		values[(sz)ref] = const_prop_binary(graph, decl, inst, values);
	}
	return values[(sz)ref].tag == ConstPropTag.CONSTANT;
}

<* Propagate values implied by a branch edge into blocks dominated by that edge. *>
fn bool correlated_value_prop(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
		foreach (inst : decl.instructions)
		{
			if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;
		}
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.idom.len) cfg.compute_dominators();
		Uses* uses = analyses.get_uses();
		DeclEditor editor; editor.begin(decl);
		bool changed = false;
		foreach (source_index : cfg.rpo)
		{
			CfgBlock* source = &cfg.blocks[(sz)source_index];
			sz term_pos = block_terminator_position(decl, source);
			if (term_pos >= source.end) continue;
			ir::Ref branch_ref = decl.body[term_pos];
			ir::Inst* branch = &decl.instructions[(sz)branch_ref];
			if (branch.tag != ir::InstTag.BRANCH) continue;
			ir::Ref cond_ref = branch.data.branch.cond;
			if ((usz)cond_ref >= (usz)decl.instructions.len) continue;
			ir::Inst* cond = &decl.instructions[(sz)cond_ref];
			bool eq_ne = cond.tag == ir::InstTag.CMP_EQ || cond.tag == ir::InstTag.CMP_NE;
			bool float_compare = cond.tag == ir::InstTag.FCMP_OEQ || cond.tag == ir::InstTag.FCMP_UNE ||
				cond.tag == ir::InstTag.FCMP_OLT || cond.tag == ir::InstTag.FCMP_OLE ||
				cond.tag == ir::InstTag.FCMP_OGT || cond.tag == ir::InstTag.FCMP_OGE;
			bool direct_i1 = cond.tag != ir::InstTag.CONSTANT && cond.ty == value_interner::REF_I1 &&
				!eq_ne && !float_compare;
			ir::Ref value_ref = ir::NONE;
			ir::Ref replacement_ref = ir::NONE;
			bool comparison = false;
			if (direct_i1)
			{
				value_ref = cond_ref;
			}
			else if (eq_ne)
			{
				ir::Ref lhs = cond.data.bin.lhs;
				ir::Ref rhs = cond.data.bin.rhs;
				bool lhs_const = (usz)lhs < (usz)decl.instructions.len && decl.instructions[(sz)lhs].tag == ir::InstTag.CONSTANT;
				bool rhs_const = (usz)rhs < (usz)decl.instructions.len && decl.instructions[(sz)rhs].tag == ir::InstTag.CONSTANT;
				if (lhs_const == rhs_const) continue;
				value_ref = lhs_const ? rhs : lhs;
				replacement_ref = lhs_const ? lhs : rhs;
				if ((usz)value_ref >= (usz)decl.instructions.len ||
					decl.instructions[(sz)value_ref].tag == ir::InstTag.CONSTANT ||
					(usz)replacement_ref >= (usz)decl.instructions.len ||
					decl.instructions[(sz)value_ref].ty != decl.instructions[(sz)replacement_ref].ty) continue;
				ushort width;
				bool integer_value = const_prop_int_width(graph, decl.instructions[(sz)value_ref].ty, &width);
				if (!integer_value)
				{
					// Pointer equality is supported only when the constant is null.
					if ((usz)value_ref >= (usz)decl.instructions.len ||
						graph.interner.get(decl.instructions[(sz)value_ref].ty).tag != primitive_value::PrimitiveType.PTR_TY ||
						decl.instructions[(sz)replacement_ref].tag != ir::InstTag.CONSTANT ||
						decl.instructions[(sz)replacement_ref].data.constant != value_interner::REF_NULL) continue;
				}
				else
				{
					ulong ignored_bits;
					if (!scalar_constant_bits(graph, decl.instructions, replacement_ref, &ignored_bits)) continue;
				}
				comparison = true;
			}
			else { continue; }
			uint edge_count = direct_i1 ? 2 : 1;
			for (uint edge = 0; edge < edge_count; edge++)
			{
				bool take_then = direct_i1 ? edge == 0 : cond.tag == ir::InstTag.CMP_EQ;
				// For CMP_EQ the then edge proves equality; for CMP_NE the else edge does.
				if (comparison && cond.tag == ir::InstTag.CMP_NE) take_then = false;
				ir::Ref edge_label = take_then ? branch.data.branch.then_label : branch.data.branch.else_label;
				ir::Ref other_label = take_then ? branch.data.branch.else_label : branch.data.branch.then_label;
				if (edge_label == other_label || (usz)edge_label >= (usz)cfg.block_of_ref.len ||
					(usz)other_label >= (usz)cfg.block_of_ref.len) continue;
				uint edge_block = cfg.block_of_ref[(sz)edge_label];
				uint other_block = cfg.block_of_ref[(sz)other_label];
				if (edge_block == NONE_BLOCK || other_block == NONE_BLOCK || edge_block == other_block) continue;
				CfgBlock* target = &cfg.blocks[(sz)edge_block];
				if (!cfg.reachable[(sz)edge_block] || target.preds.len() != 1 || target.preds[0] != source_index) continue;
				ir::Ref constant = replacement_ref;
				if (direct_i1) constant = editor.add_constant(take_then ? value_interner::REF_ONE : value_interner::REF_ZERO, value_interner::REF_I1);
				foreach (user_ref : uses.of(value_ref))
				{
					if (user_ref == cond_ref || (usz)user_ref >= (usz)decl.instructions.len) continue;
					uint user_block = cfg.block_of_ref[(sz)user_ref];
					if (user_block == NONE_BLOCK) continue;
					ir::Inst* user = &editor.insts.entries[(sz)user_ref];
					if (user.tag == ir::InstTag.PHI)
					{
						foreach (i, input : user.data.phi)
						{
							if (input.value != value_ref || (usz)input.label >= (usz)cfg.block_of_ref.len) continue;
							uint input_block = cfg.block_of_ref[(sz)input.label];
							if (input_block != NONE_BLOCK && cfg.dominates(edge_block, input_block))
							{
								user.data.phi[i].value = constant;
								changed = true;
							}
						}
					}
					else if (cfg.dominates(edge_block, user_block))
					{
						@each_value_operand(user; ir::Ref* slot)
						{
							if (*slot == value_ref) { *slot = constant; changed = true; }
						};
					}
				}
			}
		}
		if (changed) { editor.commit(); }
		else { editor.free(); }
		return changed;
	};
}

<* One bounded rewrite; CFG is rebuilt after each successful edge change.
   Scans predecessors from `*resume_p`. On success
   `*resume_p` is the predecessor block just threaded, so the next call does not
   re-probe every earlier rejected candidate. *>
fn bool jump_thread_once(ir::Ir* graph, ir::Decl* decl, uint* resume_p, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
		foreach (inst : decl.instructions)
		{
			if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;
		}
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.idom.len) cfg.compute_dominators();
		Uses* uses = analyses.get_uses();
		ir::Ref[] phi_refs = alloc::new_array(tmem, ir::Ref, decl.body.len);
		// One lattice for all candidates; only slots in `touched` are reset between them.
		ConstPropValue[] values = alloc::new_array(tmem, ConstPropValue, (sz)decl.instructions.len);
		for (usz i = 0; i < (usz)decl.instructions.len; i++) values[i] = const_prop_top();
		list::List{ir::Ref} touched;
		touched.init(mem, 0);
		defer touched.free();
		for (uint p = *resume_p; p < (uint)cfg.blocks.len; p++)
		{
			if (!cfg.reachable[(sz)p]) continue;
			CfgBlock* pred = &cfg.blocks[(sz)p];
			sz pterm = block_terminator_position(decl, pred);
			ir::Inst* pred_term = pterm == pred.end ? null : &decl.instructions[(sz)decl.body[pterm]];
			if (pred_term != null && pred_term.tag != ir::InstTag.JMP && pred_term.tag != ir::InstTag.BRANCH) continue;
			foreach (s : pred.succs)
			{
				if (s == 0 || s == p || !cfg.reachable[(sz)s]) continue;
				CfgBlock* block = &cfg.blocks[(sz)s];
				if (!jump_thread_edge_to(cfg, pred, p, s, pterm)) continue;
				// Avoid threading through loop headers, which can create irreducible CFGs.
				if (jump_thread_is_loop_header(cfg, s)) continue;
				sz end = block_terminator_position(decl, block);
				if (end == block.end) continue;
				ir::Ref term_ref = decl.body[end];
				ir::Inst* term = &decl.instructions[(sz)term_ref];
				if (term.tag != ir::InstTag.BRANCH) continue;
				sz pos = block.start + 1;
				uint phi_count = 0;
				while (pos < end && decl.instructions[(sz)decl.body[pos]].tag == ir::InstTag.PHI)
				{
					phi_refs[phi_count++] = decl.body[pos++];
				}
				if (phi_count == 0) continue;
				ir::Ref[3] chain; uint chain_count = 0;
				while (pos < end && chain_count < 3 && jump_thread_supported(decl.instructions[(sz)decl.body[pos]].tag))
				{
					chain[chain_count++] = decl.body[pos++];
				}
				if (pos != end) continue;
				bool[3] chain_depends_on_phi = {};
				for (uint i = 0; i < chain_count; i++)
				{
					ir::Inst* inst = &decl.instructions[(sz)chain[i]];
					ir::Ref lhs = inst.tag == ir::InstTag.ZEXT || inst.tag == ir::InstTag.SEXT || inst.tag == ir::InstTag.TRUNC
						? inst.data.ref : inst.data.bin.lhs;
					ir::Ref rhs = inst.tag == ir::InstTag.ZEXT || inst.tag == ir::InstTag.SEXT || inst.tag == ir::InstTag.TRUNC
						? ir::NONE : inst.data.bin.rhs;
					for (uint j = 0; j < phi_count; j++)
					{
						if (lhs == phi_refs[j] || rhs == phi_refs[j]) chain_depends_on_phi[i] = true;
					}
					for (uint j = 0; j < i; j++)
					{
						if ((lhs == chain[j] || rhs == chain[j]) && chain_depends_on_phi[j]) chain_depends_on_phi[i] = true;
					}
				}
				bool cond_depends_on_phi = false;
				for (uint i = 0; i < phi_count; i++) if (term.data.branch.cond == phi_refs[i]) cond_depends_on_phi = true;
				for (uint i = 0; i < chain_count; i++)
				{
					if (term.data.branch.cond == chain[i] && chain_depends_on_phi[i]) cond_depends_on_phi = true;
				}
				if (!cond_depends_on_phi) continue;
				bool[3] chain_feeds_branch = {};
				for (uint i = chain_count; i > 0; i--)
				{
					uint index = i - 1;
					if (term.data.branch.cond == chain[index]) chain_feeds_branch[index] = true;
					foreach (user : uses.of(chain[index]))
					{
						for (uint j = index + 1; j < chain_count; j++)
						{
							if (user == chain[j] && chain_feeds_branch[j]) chain_feeds_branch[index] = true;
						}
					}
				}
				foreach (r : touched) values[(sz)r] = const_prop_top();
				touched.clear();
				bool valid = true;
				for (uint i = 0; i < phi_count && valid; i++)
				{
					ir::Inst* phi = &decl.instructions[(sz)phi_refs[i]];
					foreach (user : uses.of(phi_refs[i]))
					{
						bool allowed = user == term_ref;
						for (uint j = 0; j < chain_count; j++) if (user == chain[j]) allowed = true;
						ir::Inst* use_inst = &decl.instructions[(sz)user];
						if ((usz)user < (usz)cfg.block_of_ref.len && cfg.block_of_ref[(sz)user] == s) allowed = true;
						if (use_inst.tag == ir::InstTag.PHI && (usz)user < (usz)cfg.block_of_ref.len)
						{
							uint use_block = cfg.block_of_ref[(sz)user];
							if ((use_block == cfg.block_of_ref[(sz)term.data.branch.then_label] ||
								use_block == cfg.block_of_ref[(sz)term.data.branch.else_label]) &&
								jump_thread_phi_input_only(*use_inst, block.label, phi_refs[i])) allowed = true;
						}
						if (!allowed) valid = false;
					}
					ir::Ref selected = ir::NONE;
					foreach (input : phi.data.phi)
					{
						if (input.label != pred.label) continue;
						selected = input.value;
					}
					ulong input_bits;
					if (selected == ir::NONE)
					{
						valid = false;
					}
					else
					{
						ushort width;
						if (const_prop_int_width(graph, phi.ty, &width) &&
							scalar_constant_bits(graph, decl.instructions, selected, &input_bits))
						{
							touched.push(phi_refs[i]);
							values[(sz)phi_refs[i]] = const_prop_constant(width, input_bits);
						}
					}
				}
				for (uint i = 0; i < chain_count && valid; i++)
				{
					ir::Ref ref = chain[i];
					// Only values feeding the branch are needed to choose a successor.
					// Validate uses for every chain definition, though: a dead chain
					// instruction may still escape B through an otherwise-illegal use.
					if (chain_feeds_branch[i] && !jump_thread_eval(graph, decl, decl.instructions, values, &touched, ref, 0)) valid = false;
					// Definitions in S must be private to its PHI/chain/terminator.
					foreach (user : uses.of(ref))
					{
						bool allowed = user == term_ref;
						for (uint j = 0; j < chain_count; j++) if (user == chain[j]) allowed = true;
						ir::Inst* use_inst = &decl.instructions[(sz)user];
						if ((usz)user < (usz)cfg.block_of_ref.len && cfg.block_of_ref[(sz)user] == s) allowed = true;
						if (use_inst.tag == ir::InstTag.PHI && (usz)user < (usz)cfg.block_of_ref.len)
						{
							uint use_block = cfg.block_of_ref[(sz)user];
							if ((use_block == cfg.block_of_ref[(sz)term.data.branch.then_label] ||
								use_block == cfg.block_of_ref[(sz)term.data.branch.else_label]) &&
								jump_thread_phi_input_only(*use_inst, block.label, ref)) allowed = true;
						}
						if (!allowed) valid = false;
					}
				}
				if (!valid) continue;
				bool cond_is_local = false;
				for (uint i = 0; i < phi_count; i++) if (phi_refs[i] == term.data.branch.cond) cond_is_local = true;
				for (uint i = 0; i < chain_count; i++) if (chain[i] == term.data.branch.cond) cond_is_local = true;
				if (!cond_is_local) continue;
				ConstPropValue cond = const_prop_ref(values, decl, term.data.branch.cond);
				if (cond.tag != ConstPropTag.CONSTANT) continue;
				ir::Ref destination = cond.bits != 0 ? term.data.branch.then_label : term.data.branch.else_label;
				if ((usz)destination >= (usz)cfg.block_of_ref.len) continue;
				uint d = cfg.block_of_ref[(sz)destination];
				if (d == NONE_BLOCK || d == s) continue;
				// Do not add a shortcut into a loop header or a new backedge. These
				// are the cases where bypassing B can change the loop's entry shape.
				if (jump_thread_is_loop_header(cfg, d) || cfg.dominates(d, p)) continue;
				bool already_pred = false;
				foreach (dpred : cfg.blocks[(sz)d].preds) if (dpred == p) already_pred = true;
				if (already_pred) continue;
				// Every destination PHI must have a B input that can be mapped to P.
				bool phis_ok = true;
				for (sz q = cfg.blocks[(sz)d].start + 1; q < cfg.blocks[(sz)d].end; q++)
				{
					ir::Inst* phi = &decl.instructions[(sz)decl.body[q]];
					if (phi.tag != ir::InstTag.PHI) break;
					bool found = false;
					foreach (input : phi.data.phi) if (input.label == block.label)
					{
						found = true;
					}
					if (!found) phis_ok = false;
				}
				if (!phis_ok) continue;
				// Successor PHIs may consume an otherwise-dead chain result. Those
				// values are copied as constants below, so evaluate them before editing.
				for (sz q = cfg.blocks[(sz)d].start + 1; q < cfg.blocks[(sz)d].end && valid; q++)
				{
					ir::Inst* phi = &decl.instructions[(sz)decl.body[q]];
					if (phi.tag != ir::InstTag.PHI) break;
					foreach (input : phi.data.phi)
					{
						if (input.label != block.label) continue;
						for (uint i = 0; i < chain_count; i++) if (input.value == chain[i])
						{
							if (!jump_thread_eval(graph, decl, decl.instructions, values, &touched, input.value, 0)) valid = false;
						}
					}
				}
				if (!valid) continue;
				DeclEditor editor; editor.begin(decl);
				if (pred_term == null)
				{
					ir::Ref jump = editor.append({ .tag = ir::InstTag.JMP, .data.ref = destination, .ty = value_interner::REF_VOID });
					editor.insert_body(pred.end, jump);
				}
				else
				{
					ir::Inst* edited_term = &editor.insts.entries[(sz)decl.body[pterm]];
					cfg_redirect_target(edited_term, block.label, destination);
				}
				// Remove the old P incoming value from every PHI in B.
				for (sz q = block.start + 1; q < end; q++)
				{
					ir::Inst* phi = &editor.insts.entries[(sz)decl.body[q]];
					if (phi.tag != ir::InstTag.PHI) break;
					usz kept = 0;
					foreach (input : phi.data.phi) if (input.label != pred.label) kept++;
					ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, (sz)kept);
					usz k = 0;
					foreach (input : phi.data.phi) if (input.label != pred.label) inputs[k++] = input;
					phi.data.phi = inputs;
				}
				for (sz q = cfg.blocks[(sz)d].start + 1; q < cfg.blocks[(sz)d].end; q++)
				{
					ir::Inst* phi = &editor.insts.entries[(sz)decl.body[q]];
					if (phi.tag != ir::InstTag.PHI) break;
					usz old_len = (usz)phi.data.phi.len;
					ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, (sz)(old_len + 1));
					for (usz k = 0; k < old_len; k++) inputs[k] = phi.data.phi[k];
					bool inserted = false;
					for (usz k = 0; k < old_len; k++)
					{
						if (inputs[k].label == block.label)
						{
							ir::Ref mapped = inputs[k].value;
							if ((usz)mapped < (usz)cfg.block_of_ref.len && cfg.block_of_ref[(sz)mapped] == s)
							{
								ir::Inst* mapped_inst = &decl.instructions[(sz)mapped];
								if (mapped_inst.tag == ir::InstTag.PHI)
								{
									bool found = false;
									foreach (binput : mapped_inst.data.phi)
									{
										if (binput.label == pred.label) { mapped = binput.value; found = true; }
									}
									if (!found) { phis_ok = false; }
								}
								else
								{
									ConstPropValue mapped_value = values[(sz)mapped];
									if (mapped_value.tag != ConstPropTag.CONSTANT) { phis_ok = false; }
									else
									{
										ushort width;
										if (!const_prop_int_width(graph, mapped_inst.ty, &width)) { phis_ok = false; }
										else { mapped = scalar_constant(graph, &editor, width, mapped_value.bits, mapped_inst.ty); }
									}
								}
							}
							inputs[old_len] = { .label = pred.label, .value = mapped };
							inserted = true;
						}
					}
					if (inserted) phi.data.phi = inputs;
				}
				if (!phis_ok) { editor.free(); continue; }
				editor.commit();
				analyses.mark_dirty();
				*resume_p = p;
				return true;
			}
		}
		return false;
	};
}

<* Rebuild cap: jump threading here is a "lite" pass, so huge functions stop early. *>
const usz JUMP_THREAD_MAX_REBUILDS = 64;

fn bool jump_thread(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		// Each thread removes one predecessor edge of a non-header block, so the
		// block count bounds useful rebuilds.
		usz label_count = 0;
		foreach (ref : decl.body)
		{
			if ((usz)ref < (usz)decl.instructions.len && decl.instructions[(sz)ref].tag == ir::InstTag.LABEL) label_count++;
		}
		usz max_rebuilds = label_count < JUMP_THREAD_MAX_REBUILDS ? label_count : JUMP_THREAD_MAX_REBUILDS;
		bool changed = false;
		uint resume = 0;
		for (usz i = 0; i < max_rebuilds; i++)
		{
			if (jump_thread_once(graph, decl, &resume, cached))
			{
				changed = true;
				continue;
			}
			// Threads never add or remove labels, so block indices are stable across
			// calls; candidates before `resume` get one wrap-around pass.
			if (resume == 0) break;
			resume = 0;
			if (!jump_thread_once(graph, decl, &resume, cached)) break;
			changed = true;
		}
		return changed;
	};
}
