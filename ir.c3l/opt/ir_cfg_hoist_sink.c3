// Conservative CFG motion for pure integer scalar expressions.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;

fn bool cfg_motion_scalar_available(ir::Decl* decl, Cfg* cfg, ir::Ref ref, uint block)
{
	if ((usz)ref >= (usz)decl.instructions.len) return false;
	ir::InstTag tag = decl.instructions[(sz)ref].tag;
	if (tag == ir::InstTag.CONSTANT || tag == ir::InstTag.SYMBOL) return true;
	if (tag == ir::InstTag.ARG) return cfg.block_of_ref[(sz)ref] == NONE_BLOCK;
	uint def_block = cfg.block_of_ref[(sz)ref];
	return def_block != NONE_BLOCK && cfg.dominates(def_block, block);
}

fn bool cfg_scalar_at(ir::Ir* graph, ir::Inst inst, ScalarExpr* key)
=> scalar_expression(graph, inst, key);

fn bool cfg_hoist_identical_leading(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		Uses* uses = analyses.get_uses();
		for (uint bi = 0; bi < cfg.blocks.len; bi++)
		{
			CfgBlock* branch_block = &cfg.blocks[(sz)bi];
			if (!cfg.reachable[(sz)bi]) continue;
			sz branch_pos = block_terminator_position(decl, branch_block);
			if (branch_pos >= branch_block.end) continue;
			ir::Ref branch_ref = decl.body[branch_pos];
			ir::Inst branch = decl.instructions[(sz)branch_ref];
			if (branch.tag != ir::InstTag.BRANCH || branch.data.branch.then_label == branch.data.branch.else_label) continue;
			uint then_index = cfg.block_of_ref[(sz)branch.data.branch.then_label];
			uint else_index = cfg.block_of_ref[(sz)branch.data.branch.else_label];
			if (then_index == NONE_BLOCK || else_index == NONE_BLOCK || then_index == else_index ||
				then_index == bi || else_index == bi) continue;
			CfgBlock* then_block = &cfg.blocks[(sz)then_index];
			CfgBlock* else_block = &cfg.blocks[(sz)else_index];
			if (!cfg.reachable[(sz)then_index] || !cfg.reachable[(sz)else_index] ||
				then_block.preds.len() != 1 || then_block.preds[0] != bi ||
				else_block.preds.len() != 1 || else_block.preds[0] != bi) continue;
			sz tp = then_block.start + 1;
			sz ep = else_block.start + 1;
			if (tp < then_block.end && decl.instructions[(sz)decl.body[tp]].tag == ir::InstTag.PHI) continue;
			if (ep < else_block.end && decl.instructions[(sz)decl.body[ep]].tag == ir::InstTag.PHI) continue;
			while (tp < then_block.end && ep < else_block.end)
			{
				ir::Ref tr = decl.body[tp];
				ir::Ref er = decl.body[ep];
				ir::Inst ti = decl.instructions[(sz)tr];
				ir::Inst ei = decl.instructions[(sz)er];
				if (ti.tag == ir::InstTag.PHI || ei.tag == ir::InstTag.PHI) break;
				if (is_terminator(ti.tag) || is_terminator(ei.tag)) break;
				ScalarExpr tk;
				ScalarExpr ek;
				if (!cfg_scalar_at(graph, ti, &tk) || !cfg_scalar_at(graph, ei, &ek) || !tk.equals(ek)) break;
				if (!cfg_motion_scalar_available(decl, cfg, tk.a, bi) ||
					(tk.b != ir::NONE && !cfg_motion_scalar_available(decl, cfg, tk.b, bi))) break;
				DeclEditor editor;
				editor.begin(decl);
				// The then reference is moved to just before the branch. The else
				// reference is replaced by it, and both arm placements are removed.
				editor.insert_body(branch_pos, tr);
				editor_replace_all_uses(&editor, er, tr);
				if (!ei.nsw) editor.insts.entries[(sz)tr].nsw = false;
				bool[] remove = alloc::new_array(mem, bool, decl.instructions.len);
				remove[..] = false;
				remove[(sz)er] = true;
				BodyRemovalContext context = { .remove = remove };
				// Remove the old then placement while retaining its new placement.
				// The old placement lies after the branch, so remove only its arm slot.
				for (sz p = branch_pos + 1; p < editor.body.len(); p++)
				{
					if (editor.body[p] == tr)
					{
						for (sz q = p; q + 1 < editor.body.len(); q++) editor.body.entries[q] = editor.body.entries[q + 1];
						editor.body.pop()!!;
						break;
					}
				}
				editor.remove_body_where(&body_ref_marked_for_removal, &context);
				alloc::free(mem, remove.ptr);
				editor.commit();
				return true;
			}
		}
		return false;
	};
}

fn sz cfg_last_nonterminator(ir::Decl* decl, CfgBlock* block)
{
	sz pos = block_terminator_position(decl, block);
	if (pos == block.end) pos = block.end;
	for (sz p = pos; p > block.start + 1;)
	{
		p--;
		ir::InstTag tag = decl.instructions[(sz)decl.body[p]].tag;
		if (tag != ir::InstTag.PHI) return p;
	}
	return block.start;
}

fn bool cfg_pred_ends_at(ir::Decl* decl, CfgBlock* pred, CfgBlock* join)
{
	sz term = block_terminator_position(decl, pred);
	if (term == pred.end) return true;
	ir::Inst inst = decl.instructions[(sz)decl.body[term]];
	return inst.tag == ir::InstTag.JMP && inst.data.ref == join.label;
}

fn bool cfg_sink_join_expression(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		Uses* uses = analyses.get_uses();
		for (uint ji = 0; ji < cfg.blocks.len; ji++)
		{
			CfgBlock* join = &cfg.blocks[(sz)ji];
			if (!cfg.reachable[(sz)ji] || join.preds.len() != 2) continue;
			uint ti = join.preds[0];
			uint fi = join.preds[1];
			if (ti == ji || fi == ji || ti == fi || !cfg.reachable[(sz)ti] || !cfg.reachable[(sz)fi]) continue;
			CfgBlock* tb = &cfg.blocks[(sz)ti];
			CfgBlock* fb = &cfg.blocks[(sz)fi];
			if (tb.succs.len() != 1 || tb.succs[0] != ji || fb.succs.len() != 1 || fb.succs[0] != ji ||
				!cfg_pred_ends_at(decl, tb, join) || !cfg_pred_ends_at(decl, fb, join)) continue;
			sz tp = cfg_last_nonterminator(decl, tb);
			sz fp = cfg_last_nonterminator(decl, fb);
			if (tp == tb.start || fp == fb.start) continue;
			ir::Ref tr = decl.body[tp];
			ir::Ref fr = decl.body[fp];
			ir::Inst tii = decl.instructions[(sz)tr];
			ir::Inst fii = decl.instructions[(sz)fr];
			ScalarExpr tk;
			ScalarExpr fk;
			if (tii.tag != fii.tag || tii.ty != fii.ty || !cfg_scalar_at(graph, tii, &tk) || !cfg_scalar_at(graph, fii, &fk)) continue;
			if (uses.of(tr).len != 1 || uses.of(fr).len != 1) continue;
			ir::Ref phi_ref = uses.of(tr)[0];
			if (phi_ref != uses.of(fr)[0] || decl.instructions[(sz)phi_ref].tag != ir::InstTag.PHI || cfg.block_of_ref[(sz)phi_ref] != ji) continue;
			ir::Inst phi = decl.instructions[(sz)phi_ref];
			bool has_t = false;
			bool has_f = false;
			for (usz k = 0; k < (usz)phi.data.phi.len; k++)
			{
				ir::PhiInput input = phi.data.phi[(sz)k];
				if (input.label == tb.label && input.value == tr) has_t = true;
				if (input.label == fb.label && input.value == fr) has_f = true;
			}
			if (!has_t || !has_f) continue;
			// Require identical expression structure except at most one operand.
			if (tk.tag != fk.tag || tk.ty != fk.ty) continue;
			bool unary = tk.b == ir::NONE;
			uint differing = 0;
			if (tk.a != fk.a) differing++;
			if (!unary && tk.b != fk.b) differing++;
			if (differing > 1) continue;
			// The differing operands become one PHI, so they must share a type:
			// `zext i8` and `zext i32` both produce i64 but cannot merge operands.
			if (tk.a != fk.a && decl.instructions[(sz)tk.a].ty != decl.instructions[(sz)fk.a].ty) continue;
			if (!unary && tk.b != fk.b && decl.instructions[(sz)tk.b].ty != decl.instructions[(sz)fk.b].ty) continue;
			ir::Ref merged_a = tk.a;
			ir::Ref merged_b = tk.b;
			if (tk.a != fk.a) { merged_a = ir::NONE; }
			if (!unary && tk.b != fk.b) { merged_b = ir::NONE; }
			DeclEditor editor;
			editor.begin(decl);
			// A unary expression has no rhs (tk.b is NONE): only a differing
			// operand needs a PHI (csmith seed 307 indexed instructions[NONE]).
			if (differing != 0)
			{
				ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, 2);
				inputs[0] = { .label = tb.label, .value = tk.a };
				inputs[1] = { .label = fb.label, .value = fk.a };
				// For a differing rhs, build its PHI separately.
				if (tk.a == fk.a)
				{
					inputs[0].value = tk.b;
					inputs[1].value = fk.b;
				}
				ir::Ref operand_phi = editor.append({ .tag = ir::InstTag.PHI, .ty = decl.instructions[(sz)(tk.a == fk.a ? tk.b : tk.a)].ty, .data.phi = inputs });
				sz phi_pos = join.start + 1;
				while (phi_pos < editor.body.len() && editor.insts.entries[(sz)editor.body[phi_pos]].tag == ir::InstTag.PHI) phi_pos++;
				editor.insert_body(phi_pos, operand_phi);
				if (tk.a != fk.a) { merged_a = operand_phi; } else { merged_b = operand_phi; }
			}
			ir::Inst moved = tii;
			moved.nsw = tii.nsw && fii.nsw;
			if (unary) { moved.data.ref = merged_a; } else { moved.data.bin = { .lhs = merged_a, .rhs = merged_b }; }
			ir::Ref moved_ref = editor.append(moved);
			sz phi_pos = join.start + 1;
			while (phi_pos < editor.body.len() && editor.insts.entries[(sz)editor.body[phi_pos]].tag == ir::InstTag.PHI) phi_pos++;
			// Insert after every PHI, including any operand PHI just appended.
			editor.insert_body(phi_pos, moved_ref);
			editor_replace_all_uses(&editor, phi_ref, moved_ref);
			bool[] remove = alloc::new_array(mem, bool, editor.insts.len());
			remove[..] = false; remove[(sz)tr] = true; remove[(sz)fr] = true; remove[(sz)phi_ref] = true;
			BodyRemovalContext context = { .remove = remove };
			editor.remove_body_where(&body_ref_marked_for_removal, &context);
			alloc::free(mem, remove.ptr);
			editor.commit();
			return true;
		}
		return false;
	};
}

fn bool cfg_hoist_sink(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, FunctionAnalyses* cached = null)
{
	@pool()
	{
		if (decl.kind != ir::DeclKind.FUNCTION || !cfg.blocks.len) return false;
		if (!cfg.idom.len) cfg.compute_dominators();
		if (cfg_hoist_identical_leading(graph, decl, cfg, cached)) return true;
		return cfg_sink_join_expression(graph, decl, cfg, cached);
	};
}
