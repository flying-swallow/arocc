// Conservative integer diamond and triangle if-conversion.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, std::collections::list;

<*
 x86 integer SELECT lowering evaluates both arms before choosing a result.
 Each SELECT arm must therefore be an SSA value already available at the
 source block, which dominates the emitted SELECT. Every moved operation must
 be pure and safe to execute speculatively: division, loads, calls, CLZ/CTZ,
 stores, and floating-point operations are excluded. Shifts are allowed by
 this IR's non-trapping lowering.
*>
fn bool cfg_if_convert_safe_integer(ir::InstTag tag)
{
	switch (tag)
	{
		case ir::InstTag.BIT_NOT: case ir::InstTag.NEGATE:
		case ir::InstTag.TRUNC: case ir::InstTag.ZEXT: case ir::InstTag.SEXT:
		case ir::InstTag.ADD: case ir::InstTag.SUB: case ir::InstTag.MUL:
		case ir::InstTag.BIT_AND: case ir::InstTag.BIT_OR: case ir::InstTag.BIT_XOR:
		case ir::InstTag.BIT_SHL: case ir::InstTag.BIT_ASHR: case ir::InstTag.BIT_LSHR:
		case ir::InstTag.SELECT:
		case ir::InstTag.CMP_EQ: case ir::InstTag.CMP_NE:
		case ir::InstTag.CMP_SLT: case ir::InstTag.CMP_SLTE:
		case ir::InstTag.CMP_SGT: case ir::InstTag.CMP_SGTE:
		case ir::InstTag.CMP_ULT: case ir::InstTag.CMP_ULTE:
		case ir::InstTag.CMP_UGT: case ir::InstTag.CMP_UGTE:
			return true;
		default: return false;
	}
}

fn bool cfg_if_convert_integer_type(ir::Ir* graph, value_interner::InternerRef ty)
{
	if (ty == value_interner::REF_PTR) return true;
	ushort width;
	return const_prop_int_width(graph, ty, &width);
}

fn bool cfg_if_convert_value_available(ir::Decl* decl, Cfg* cfg, ir::Ref ref, uint block)
{
	if ((usz)ref >= (usz)decl.instructions.len) return false;
	uint def_block = cfg.block_of_ref[(sz)ref];
	if (def_block == NONE_BLOCK)
	{
		ir::InstTag tag = decl.instructions[(sz)ref].tag;
		return tag == ir::InstTag.CONSTANT || tag == ir::InstTag.SYMBOL || tag == ir::InstTag.ARG;
	}
	if (def_block == block)
	{
		CfgBlock* bb = &cfg.blocks[(sz)block];
		sz term = block_terminator_position(decl, bb);
		for (sz pos = bb.start + 1; pos < term; pos++) if (decl.body[pos] == ref) return true;
		return false;
	}
	return cfg.dominates(def_block, block);
}

fn bool cfg_if_convert_operand_available(ir::Decl* decl, Cfg* cfg, ir::Ref ref, uint block,
		ir::Ref[] arm_ops, sz prior_count)
{
	for (sz i = 0; i < prior_count; i++) if (arm_ops[i] == ref) return true;
	return cfg_if_convert_value_available(decl, cfg, ref, block);
}

fn bool cfg_if_convert_inst_operands_available(ir::Decl* decl, Cfg* cfg, ir::Ref ref, uint block,
		ir::Ref[] arm_ops, sz prior_count)
{
	bool available = true;
	ir::Inst* inst = &decl.instructions[(sz)ref];
	@each_value_operand(inst; ir::Ref* slot)
	{
		if (!cfg_if_convert_operand_available(decl, cfg, *slot, block, arm_ops, prior_count)) available = false;
	};
	return available;
}

fn bool cfg_if_convert_arm(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, CfgBlock* block, uint source,
		ir::Ref join_label, sz join_start, ir::Ref[] ops, sz* op_count)
{
	if (block.preds.len() != 1 || block.preds[0] != source || block.succs.len() != 1) return false;
	sz term = block_terminator_position(decl, block);
	if (term < block.end)
	{
		ir::Inst terminator = decl.instructions[(sz)decl.body[term]];
		if (terminator.tag != ir::InstTag.JMP || terminator.data.ref != join_label) return false;
	}
	else if (block.end != join_start) { return false; }
	*op_count = 0;
	sz exec_end = term < block.end ? term : block.end;
	for (sz p = block.start + 1; p < exec_end; p++)
	{
		ir::Ref ref = decl.body[p];
		ir::Inst inst = decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.PHI || *op_count == 2 || !cfg_if_convert_safe_integer(inst.tag) ||
			!cfg_if_convert_integer_type(graph, inst.ty) ||
			!cfg_if_convert_inst_operands_available(decl, cfg, ref, source, ops, *op_count)) return false;
		ops[*op_count] = ref;
		(*op_count)++;
	}
	return true;
}

<* Convert one strict integer diamond or triangle. The CFG is rebuilt by its caller. *>
fn bool cfg_if_convert(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || cfg.blocks.len == 0) return false;
		foreach (inst : decl.instructions)
		{
			if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;
		}
		if (!cfg.idom.len) if (!cfg.idom.len) cfg.compute_dominators();
		for (uint bi = 0; bi < cfg.blocks.len; bi++)
		{
			CfgBlock* source = &cfg.blocks[(sz)bi];
			if (!cfg.reachable[(sz)bi]) continue;
			sz branch_pos = block_terminator_position(decl, source);
			if (branch_pos >= source.end) continue;
			ir::Ref branch_ref = decl.body[branch_pos];
			ir::Inst branch = decl.instructions[(sz)branch_ref];
			if (branch.tag != ir::InstTag.BRANCH || branch.data.branch.then_label == branch.data.branch.else_label ||
				!cfg_if_convert_value_available(decl, cfg, branch.data.branch.cond, bi)) continue;
			uint then_index = cfg.block_of_ref[(sz)branch.data.branch.then_label];
			uint else_index = cfg.block_of_ref[(sz)branch.data.branch.else_label];
			if (then_index == NONE_BLOCK || else_index == NONE_BLOCK || then_index == else_index ||
				then_index == bi || else_index == bi || !cfg.reachable[(sz)then_index] || !cfg.reachable[(sz)else_index]) continue;
			CfgBlock* then_block = &cfg.blocks[(sz)then_index];
			CfgBlock* else_block = &cfg.blocks[(sz)else_index];
			uint join_index = NONE_BLOCK;
			bool then_direct = false;
			bool else_direct = false;
			// Diamond: both arms have one edge to the same join.
			if (then_block.succs.len() == 1 && else_block.succs.len() == 1 &&
				then_block.succs[0] == else_block.succs[0])
			{
				join_index = then_block.succs[0];
			}
			// Triangle: one branch target is also the other arm's join.
			else if (then_block.preds.len() >= 1 && else_block.succs.len() == 1 && else_block.succs[0] == then_index)
			{
				join_index = then_index; then_direct = true;
			}
			else if (else_block.preds.len() >= 1 && then_block.succs.len() == 1 && then_block.succs[0] == else_index)
			{
				join_index = else_index; else_direct = true;
			}
			if (join_index == NONE_BLOCK || join_index == bi || !cfg.reachable[(sz)join_index]) continue;
			CfgBlock* join = &cfg.blocks[(sz)join_index];
			ir::Ref[2] then_ops; ir::Ref[2] else_ops;
			sz then_count = 0; sz else_count = 0;
			if (!then_direct && !cfg_if_convert_arm(graph, decl, cfg, then_block, bi, join.label, join.start, then_ops[..], &then_count)) continue;
			if (!else_direct && !cfg_if_convert_arm(graph, decl, cfg, else_block, bi, join.label, join.start, else_ops[..], &else_count)) continue;
			if (then_direct)
			{
				bool source_pred = false; bool arm_pred = false;
				foreach (pred : then_block.preds) { if (pred == bi) source_pred = true; if (pred == else_index) arm_pred = true; }
				if (!source_pred || !arm_pred) continue;
			}
			if (else_direct)
			{
				bool source_pred = false; bool arm_pred = false;
				foreach (pred : else_block.preds) { if (pred == bi) source_pred = true; if (pred == then_index) arm_pred = true; }
				if (!source_pred || !arm_pred) continue;
			}

			// Accept at most four leading join PHIs. Their inputs from the two branch
			// edges are replaced by a single source-block input below.
			ir::Ref[4] phi_refs; sz phi_count = 0;
			for (sz p = join.start + 1; p < join.end; p++)
			{
				ir::Ref ref = decl.body[p];
				ir::Inst inst = decl.instructions[(sz)ref];
				if (inst.tag != ir::InstTag.PHI) break;
				if (phi_count == 4 || !cfg_if_convert_integer_type(graph, inst.ty)) { phi_count = 0; break; }
				phi_refs[phi_count++] = ref;
			}
			if (!phi_count) continue;
			bool valid = true;
			for (sz pi = 0; pi < phi_count && valid; pi++)
			{
				ir::Ref phi_ref = phi_refs[pi];
				ir::Inst phi = decl.instructions[(sz)phi_ref];
				ir::Ref then_value = ir::NONE; ir::Ref else_value = ir::NONE;
				bool has_then = false; bool has_else = false;
				for (usz k = 0; k < (usz)phi.data.phi.len; k++)
				{
					ir::PhiInput input = phi.data.phi[(sz)k];
					if (input.label == (then_direct ? source.label : then_block.label)) { then_value = input.value; has_then = true; }
					if (input.label == (else_direct ? source.label : else_block.label)) { else_value = input.value; has_else = true; }
				}
				if (!has_then || !has_else || (then_count && then_value != then_ops[then_count - 1]) ||
					(else_count && else_value != else_ops[else_count - 1]) ||
					(!then_count && !cfg_if_convert_value_available(decl, cfg, then_value, bi)) ||
					(!else_count && !cfg_if_convert_value_available(decl, cfg, else_value, bi)) ||
					(usz)then_value >= (usz)decl.instructions.len || (usz)else_value >= (usz)decl.instructions.len ||
					decl.instructions[(sz)then_value].ty != phi.ty || decl.instructions[(sz)else_value].ty != phi.ty) { valid = false; break; }
			}
			if (!valid) continue;
			// Moved arm results may only feed another moved op or one of these PHIs.
			Uses* uses = analyses.get_uses();
			for (sz oi = 0; oi < then_count + else_count && valid; oi++)
			{
				ir::Ref op = oi < then_count ? then_ops[oi] : else_ops[oi - then_count];
				foreach (user : uses.of(op))
				{
					bool allowed = false;
					for (sz j = 0; j < then_count; j++) if (then_ops[j] == user && j > oi) allowed = true;
					for (sz j = 0; j < else_count; j++) if (else_ops[j] == user && (then_count + j) > oi) allowed = true;
					for (sz j = 0; j < phi_count; j++) if (phi_refs[j] == user) allowed = true;
					if (!allowed) valid = false;
				}
			}
			if (!valid) continue;

			DeclEditor editor;
			editor.begin(decl);
			ir::Ref[4] new_ops; sz new_count = 0;
			for (sz i = 0; i < then_count; i++) new_ops[new_count++] = then_ops[i];
			for (sz i = 0; i < else_count; i++) new_ops[new_count++] = else_ops[i];
			// Remove complete arm blocks, including labels and explicit jumps. Keep
			// implicit fallthroughs into a removed block pointed at the removed arm's
			// successor by making that edge explicit before the block disappears.
			bool[] removed_block = alloc::new_array(tmem, bool, cfg.blocks.len);
			removed_block[..] = false;
			if (!then_direct) removed_block[(sz)then_index] = true;
			if (!else_direct) removed_block[(sz)else_index] = true;
			list::List{ir::Ref} rebuilt_body;
			rebuilt_body.init(decl.allocator, editor.body.len() + 2);
			for (sz p = 0; p < cfg.blocks[0].start; p++) rebuilt_body.push(editor.body[p]);
			for (usz block_index = 0; block_index < cfg.blocks.len; block_index++)
			{
				CfgBlock* block = &cfg.blocks[(sz)block_index];
				if (!removed_block[(sz)block_index])
				{
					for (sz p = block.start; p < block.end; p++) rebuilt_body.push(editor.body[p]);
					if (block_index + 1 < cfg.blocks.len && removed_block[(sz)(block_index + 1)] &&
						block_terminator_position(decl, block) == block.end)
					{
						ir::Ref jump = editor.append({ .tag = ir::InstTag.JMP, .ty = value_interner::REF_VOID,
							.data.ref = join.label });
						rebuilt_body.push(jump);
					}
				}
			}
			editor.body.free();
			editor.body = rebuilt_body;
			sz edited_branch_pos = -1;
			for (sz p = 0; p < editor.body.len(); p++) if (editor.body[p] == branch_ref) { edited_branch_pos = p; break; }
			assert(edited_branch_pos >= 0);
			for (sz i = 0; i < new_count; i++) editor.insert_body(edited_branch_pos + i, new_ops[i]);
			ir::Ref[4] select_refs;
			for (sz pi = 0; pi < phi_count; pi++)
			{
				ir::Inst phi = decl.instructions[(sz)phi_refs[pi]];
				ir::Ref tv = ir::NONE; ir::Ref ev = ir::NONE;
				foreach (input : phi.data.phi)
				{
					if (input.label == (then_direct ? source.label : then_block.label)) tv = input.value;
					if (input.label == (else_direct ? source.label : else_block.label)) ev = input.value;
				}
				select_refs[pi] = editor.append({ .tag = ir::InstTag.SELECT, .ty = phi.ty,
					.data.branch = { .cond = branch.data.branch.cond, .then_label = tv, .else_label = ev } });
				sz pos = edited_branch_pos + new_count + pi;
				editor.insert_body(pos, select_refs[pi]);
				// Rebuild the PHI with one source input and retain all unrelated predecessors.
				list::List{ir::PhiInput} inputs; inputs.init(mem);
				foreach (input : phi.data.phi)
				{
					if (input.label == (then_direct ? source.label : then_block.label) ||
						input.label == (else_direct ? source.label : else_block.label)) continue;
					inputs.push(input);
				}
				inputs.push({ .label = source.label, .value = select_refs[pi] });
				ir::PhiInput[] owned = alloc::new_array(&decl.arena, ir::PhiInput, inputs.len());
				owned[..] = inputs.array_view()[..];
				inputs.free();
				editor.insts.entries[(sz)phi_refs[pi]].data.phi = owned;
			}
			ir::Inst* edited_branch = &editor.insts.entries[(sz)branch_ref];
			edited_branch.tag = ir::InstTag.JMP;
			edited_branch.data.ref = join.label;
			// Repair any surviving label-valued operands that named removed blocks.
			foreach (ref : editor.body)
			{
				@each_label_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
				{
					if ((!then_direct && *slot == then_block.label) || (!else_direct && *slot == else_block.label)) *slot = join.label;
				};
			}
			editor.commit();
			return true;
		}
		return false;
	};
}
