// Delete finite innermost loops whose computations have no observable uses.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;

fn bool loop_deletion(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		foreach (ref : decl.body)
		{
			if ((usz)ref >= (usz)decl.instructions.len) continue;
			ir::InstTag tag = decl.instructions[(sz)ref].tag;
			if (tag == ir::InstTag.LABEL_ADDR || tag == ir::InstTag.JMP_VAL) return false;
		}

		bool changed = false;
		while (true)
		{
			changed = ensure_preheaders(decl, analyses) || changed;
			Cfg* cfg = analyses.get_cfg();
			if (!cfg.blocks.len) return changed;
			if (!cfg.idom.len) cfg.compute_dominators();
			LoopInfo* loops = analyses.get_loops();
			Uses* uses = analyses.get_uses();
			uint selected = NONE_BLOCK;
			LoopTripCount selected_trip;

			foreach (loop_index, loop : loops.loops)
			{
				bool has_child = false;
				foreach (child : loops.loops) if (child.parent == loop_index) { has_child = true; break; }
				if (has_child) continue;

				LoopTripCount trip;
				if (!loop_constant_trip_count(graph, decl, cfg, loops, (uint)loop_index, &trip) || !trip.known) continue;

				bool safe = true;
				foreach (block_index : loop.blocks)
				{
					CfgBlock* block = &cfg.blocks[(sz)block_index];
					for (sz pos = block.start + 1; pos < block_executable_end(decl, block); pos++)
					{
						ir::Ref ref = decl.body[pos];
						if ((usz)ref >= (usz)decl.instructions.len) { safe = false; break; }
						ir::Inst* inst = &decl.instructions[(sz)ref];
						if (inst.tag == ir::InstTag.LABEL || inst.tag == ir::InstTag.PHI ||
							inst.tag == ir::InstTag.JMP || inst.tag == ir::InstTag.BRANCH) continue;
						if (!removable_if_unused(decl, inst)) { safe = false; break; }
					}
					if (!safe) break;
				}
				if (!safe) continue;

				foreach (block_index : loop.blocks)
				{
					CfgBlock* block = &cfg.blocks[(sz)block_index];
					for (sz pos = block.start + 1; pos < block_executable_end(decl, block); pos++)
					{
						ir::Ref ref = decl.body[pos];
						foreach (user_ref : uses.of(ref))
						{
							if ((usz)user_ref >= (usz)decl.instructions.len) { safe = false; break; }
							uint user_block = cfg.block_of_ref[(sz)user_ref];
							if (user_block != NONE_BLOCK && loop.contains(loops, user_block)) continue;

							bool exit_phi_use = false;
							if (user_block == trip.exit_block &&
								decl.instructions[(sz)user_ref].tag == ir::InstTag.PHI)
							{
								foreach (input : decl.instructions[(sz)user_ref].data.phi)
								{
									if (input.label != cfg.blocks[(sz)trip.exiting_block].label || input.value != ref) continue;
									if ((usz)input.value >= (usz)decl.instructions.len) continue;
									ir::InstTag value_tag = decl.instructions[(sz)input.value].tag;
									uint value_block = cfg.block_of_ref[(sz)input.value];
									exit_phi_use = value_tag == ir::InstTag.CONSTANT || value_tag == ir::InstTag.ARG ||
										value_tag == ir::InstTag.SYMBOL || value_block == NONE_BLOCK ||
										!loop.contains(loops, value_block);
									break;
								}
							}
							if (!exit_phi_use) { safe = false; break; }
						}
						if (!safe) break;
					}
					if (!safe) break;
				}
				if (!safe) continue;
				selected = (uint)loop_index;
				selected_trip = trip;
				break;
			}

			if (selected == NONE_BLOCK) return changed;
			Loop* loop = &loops.loops.entries[(sz)selected];
			LoopTripCount trip = selected_trip;
			CfgBlock* preheader = &cfg.blocks[(sz)trip.preheader];
			CfgBlock* header = &cfg.blocks[(sz)loop.header];
			CfgBlock* exiting = &cfg.blocks[(sz)trip.exiting_block];
			CfgBlock* exit_block = &cfg.blocks[(sz)trip.exit_block];
			DeclEditor editor; editor.begin(decl);
			sz term_pos = block_terminator_position(decl, preheader);
			if (term_pos < preheader.end)
			{
				ir::Ref term_ref = decl.body[term_pos];
				if ((usz)term_ref >= (usz)editor.insts.len() || editor.insts.entries[(sz)term_ref].tag != ir::InstTag.JMP ||
					editor.insts.entries[(sz)term_ref].data.ref != header.label)
				{
					editor.free();
					return changed;
				}
				cfg_redirect_target(&editor.insts.entries[(sz)term_ref], header.label, exit_block.label);
			}
			else
			{
				ir::Ref jump = editor.append({ .tag = ir::InstTag.JMP, .data.ref = exit_block.label,
					.ty = value_interner::REF_NORETURN });
				editor.insert_body(preheader.end, jump);
			}

			for (sz pos = exit_block.start + 1; pos < exit_block.end; pos++)
			{
				ir::Ref phi_ref = decl.body[pos];
				if ((usz)phi_ref >= (usz)editor.insts.len() || editor.insts.entries[(sz)phi_ref].tag != ir::InstTag.PHI) break;
				ir::Inst* phi = &editor.insts.entries[(sz)phi_ref];
				bool found = false;
				foreach (input : phi.data.phi) if (input.label == exiting.label) found = true;
				if (!found) continue;
				ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, (sz)phi.data.phi.len);
				inputs[..] = phi.data.phi[..];
				foreach (&input : inputs) if (input.label == exiting.label) input.label = preheader.label;
				phi.data.phi = inputs;
			}
			editor.commit();
			analyses.mark_dirty();
			remove_unreachable_blocks(decl);
			changed = true;
		}
	};
}
