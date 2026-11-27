// Conservative full unrolling of small constant-trip natural loops.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;
import std::collections::list;

<* The block `label` starts, via `block_of_ref` (a scan of every block per lookup
   was quadratic). Labels appended since the CFG was built are in no block. *>
fn uint unroll_block_for_label(Cfg* cfg, ir::Ref label)
{
	if ((usz)label >= (usz)cfg.block_of_ref.len) return NONE_BLOCK;
	uint block = cfg.block_of_ref[(sz)label];
	if (block == NONE_BLOCK || (usz)block >= (usz)cfg.blocks.len || cfg.blocks[(sz)block].label != label) return NONE_BLOCK;
	return block;
}

fn bool unroll_loop_once(ir::Ir* graph, ir::Decl* decl, usz threshold, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		// Match simplify_cfg: computed jumps and address-taken labels need a richer CFG.
		foreach (inst : decl.instructions)
			if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;

		Cfg* cfg = analyses.get_cfg();
		if (!cfg.blocks.len) return false;
		if (!cfg.idom.len) cfg.compute_dominators();
		LoopInfo* loops = analyses.get_loops();
		uint selected = NONE_BLOCK;
		LoopTripCount selected_trip;
		foreach (loop_index, loop : loops.loops)
		{
			bool has_child = false;
			foreach (child : loops.loops) if (child.parent == loop_index) { has_child = true; break; }
			if (has_child) continue;
			LoopTripCount trip;
			if (!loop_constant_trip_count(graph, decl, cfg, loops, (uint)loop_index, &trip) ||
				!trip.known || trip.backedge_taken < 1 || trip.backedge_taken + 1 > 32) continue;
			usz copies = (usz)trip.backedge_taken + 1;
			usz body_size = 0;
			bool unsafe = false;
			foreach (block_index : loop.blocks)
			{
				CfgBlock* block = &cfg.blocks[(sz)block_index];
				for (sz pos = block.start + 1; pos < block_executable_end(decl, block); pos++)
				{
					ir::Ref ref = decl.body[pos];
					if ((usz)ref >= (usz)decl.instructions.len) { unsafe = true; break; }
					ir::InstTag tag = decl.instructions[(sz)ref].tag;
					if (tag == ir::InstTag.ALLOC || tag == ir::InstTag.DYN_ALLOC ||
						tag == ir::InstTag.STACK_SAVE || tag == ir::InstTag.STACK_RESTORE ||
						tag == ir::InstTag.VA_START) unsafe = true;
					if (tag != ir::InstTag.LABEL && tag != ir::InstTag.PHI) body_size++;
				}
				if (unsafe) break;
			}
			if (unsafe || body_size > threshold / copies) continue;
			// Header PHIs must have exactly the preheader and latch inputs.
			bool bad_phi = false;
			CfgBlock* header = &cfg.blocks[(sz)loop.header];
			for (sz pos = header.start + 1; pos < header.end; pos++)
			{
				ir::Ref ref = decl.body[pos];
				if ((usz)ref >= (usz)decl.instructions.len || decl.instructions[(sz)ref].tag != ir::InstTag.PHI) break;
				uint pre_count = 0;
				uint latch_count = 0;
				uint other_count = 0;
				foreach (input : decl.instructions[(sz)ref].data.phi)
				{
					if (input.label == cfg.blocks[(sz)trip.preheader].label) { pre_count++; }
					else if (input.label == cfg.blocks[(sz)trip.latch].label) { latch_count++; }
					else { other_count++; }
				}
				if (pre_count != 1 || latch_count != 1 || other_count != 0) bad_phi = true;
			}
			if (bad_phi) continue;
			selected = (uint)loop_index;
			selected_trip = trip;
			break;
		}
		if (selected == NONE_BLOCK) return false;

		Loop* loop = &loops.loops.entries[(sz)selected];
		LoopTripCount trip = selected_trip;
		usz copies = (usz)trip.backedge_taken;
		usz inst_count = decl.instructions.len;
		usz block_count = cfg.blocks.len;
		if (inst_count == 0 || copies > usz::max / inst_count) return false;
		DeclEditor editor; editor.begin(decl);

		// The clones are copies 0..N-1; the original loop remains copy N.
		ir::Ref[][] label_of = alloc::new_array(mem, ir::Ref[], (sz)copies);
		defer alloc::free(mem, label_of.ptr);
		for (usz k = 0; k < copies; k++)
		{
			label_of[k] = alloc::new_array(mem, ir::Ref, (sz)block_count);
			for (usz b = 0; b < block_count; b++) label_of[k][b] = ir::NONE;
			foreach (block_index : loop.blocks)
			{
				ir::Ref block_label = cfg.blocks[(sz)block_index].label;
				String name = string::tformat("unroll.%s.%d.%d.%d", decl.name,
					cfg.blocks[(sz)loop.header].label, k, block_label);
				label_of[k][(sz)block_index] = editor.new_label(name);
			}
		}
		defer { foreach (labels : label_of) alloc::free(mem, labels.ptr); }

		ir::Ref[] prev = alloc::new_array(mem, ir::Ref, (sz)editor.insts.len());
		ir::Ref[] cur = alloc::new_array(mem, ir::Ref, (sz)editor.insts.len());
		defer alloc::free(mem, prev.ptr);
		defer alloc::free(mem, cur.ptr);
		for (usz i = 0; i < (usz)prev.len; i++) { prev[i] = ir::NONE; cur[i] = ir::NONE; }
		list::List{ir::Ref} clone_body; clone_body.init(mem); defer clone_body.free();
		for (usz k = 0; k < copies; k++)
		{
			for (usz i = 0; i < (usz)cur.len; i++) cur[i] = ir::NONE;
			foreach (block_index : loop.blocks)
				cur[(sz)cfg.blocks[(sz)block_index].label] = label_of[k][(sz)block_index];

			// Compute all header-PHI values before setting any mappings, preserving swaps.
			list::List{ir::Ref} phi_refs; phi_refs.init(mem); defer phi_refs.free();
			list::List{ir::Ref} phi_values; phi_values.init(mem); defer phi_values.free();
			CfgBlock* header = &cfg.blocks[(sz)loop.header];
			for (sz pos = header.start + 1; pos < header.end; pos++)
			{
				ir::Ref phi_ref = decl.body[pos];
				if ((usz)phi_ref >= (usz)inst_count || decl.instructions[(sz)phi_ref].tag != ir::InstTag.PHI) break;
				ir::PhiInput initial = {};
				ir::PhiInput latch_input = {};
				foreach (input : decl.instructions[(sz)phi_ref].data.phi)
				{
					if (input.label == cfg.blocks[(sz)trip.preheader].label) initial = input;
					if (input.label == cfg.blocks[(sz)trip.latch].label) latch_input = input;
				}
				ir::Ref value = k == 0 ? initial.value : inline_mapped_ref(prev, latch_input.value);
				phi_refs.push(phi_ref); phi_values.push(value);
			}
			for (usz i = 0; i < (usz)phi_refs.len(); i++) cur[(sz)phi_refs[(sz)i]] = phi_values[(sz)i];

			// First create all copies, so forward references map just like backward ones.
			foreach (block_index : loop.blocks)
			{
				CfgBlock* block = &cfg.blocks[(sz)block_index];
				for (sz pos = block.start + 1; pos < block_executable_end(decl, block); pos++)
				{
					ir::Ref old = decl.body[pos];
					if ((usz)old >= (usz)inst_count) { editor.free(); return false; }
					ir::Inst source = decl.instructions[(sz)old];
					if (source.tag == ir::InstTag.PHI && block_index == loop.header) continue;
					cur[(sz)old] = editor.append(source);
				}
			}
			foreach (block_index : loop.blocks)
			{
				CfgBlock* block = &cfg.blocks[(sz)block_index];
				clone_body.push(label_of[k][(sz)block_index]);
				for (sz pos = block.start + 1; pos < block_executable_end(decl, block); pos++)
				{
					ir::Ref old = decl.body[pos];
					if ((usz)old >= (usz)inst_count) continue;
					ir::Inst* original = &decl.instructions[(sz)old];
					if (original.tag == ir::InstTag.PHI && block_index == loop.header) continue;
					ir::Ref copy_ref = cur[(sz)old];
					clone_body.push(copy_ref);
					ir::Inst* copy = &editor.insts.entries[(sz)copy_ref];
					if (copy.tag == ir::InstTag.BRANCH && block_index == trip.exiting_block)
					{
						uint then_block = unroll_block_for_label(cfg, copy.data.branch.then_label);
						uint else_block = unroll_block_for_label(cfg, copy.data.branch.else_label);
						uint target = then_block == trip.exit_block ? else_block : then_block;
						if (target == NONE_BLOCK || !loop_body_contains(loop, target)) { editor.free(); return false; }
						ir::Ref target_label = target == loop.header && k + 1 == copies ?
							cfg.blocks[(sz)loop.header].label : label_of[target == loop.header ? k + 1 : k][(sz)target];
						*copy = { .tag = ir::InstTag.JMP, .data.ref = target_label, .ty = value_interner::REF_NORETURN };
						continue;
					}
					@each_value_operand(copy; ir::Ref* slot) { *slot = inline_mapped_ref(cur, *slot); };
					@each_label_operand(copy; ir::Ref* slot)
					{
						// No `continue` here: inside a trailing-body macro it would leave
						// the enclosing loop iteration and skip the remaining operands.
						uint target = unroll_block_for_label(cfg, *slot);
						if (target != NONE_BLOCK && loop_body_contains(loop, target))
						{
							if (copy.tag == ir::InstTag.PHI) { *slot = label_of[k][(sz)target]; }
							else if (target == loop.header)
							{
								*slot = k + 1 < copies ? label_of[k + 1][(sz)target] : cfg.blocks[(sz)target].label;
							}
							else { *slot = label_of[k][(sz)target]; }
						}
					};
				}
				if (block_terminator_position(decl, block) == block.end)
				{
					if (block.succs.len() != 1) { editor.free(); return false; }
					uint target = block.succs.entries[0];
					ir::Ref target_label = cfg.blocks[(sz)target].label;
					if (loop_body_contains(loop, target))
					{
						target_label = target == loop.header && k + 1 == copies ? cfg.blocks[(sz)target].label : label_of[target == loop.header ? k + 1 : k][(sz)target];
					}
					clone_body.push(editor.append({ .tag = ir::InstTag.JMP, .data.ref = target_label, .ty = value_interner::REF_NORETURN }));
				}
			}
			ir::Ref[] swap = prev; prev = cur; cur = swap;
		}

		// Replace final-copy PHI references in the original body and remove header PHIs.
		bool[] remove = alloc::new_array(mem, bool, (sz)editor.insts.len());
		defer alloc::free(mem, remove.ptr);
		for (usz i = 0; i < (usz)remove.len; i++) remove[i] = false;
		CfgBlock* header = &cfg.blocks[(sz)loop.header];
		for (sz pos = header.start + 1; pos < header.end; pos++)
		{
			ir::Ref phi_ref = decl.body[pos];
			if ((usz)phi_ref >= (usz)inst_count || decl.instructions[(sz)phi_ref].tag != ir::InstTag.PHI) break;
			ir::Ref latch_value = ir::NONE;
			foreach (input : decl.instructions[(sz)phi_ref].data.phi)
				if (input.label == cfg.blocks[(sz)trip.latch].label) latch_value = input.value;
			if (latch_value == ir::NONE) { editor.free(); return false; }
			editor_replace_all_uses(&editor, phi_ref, inline_mapped_ref(prev, latch_value));
			remove[(sz)phi_ref] = true;
		}
		BodyRemovalContext removal_context = { .remove = remove };
		editor.remove_body_where(&body_ref_marked_for_removal, (void*)&removal_context);

		// The retained final iteration exits from the original exiting block.
		CfgBlock* exiting = &cfg.blocks[(sz)trip.exiting_block];
		sz exit_term_pos = block_terminator_position(decl, exiting);
		if (exit_term_pos == exiting.end) { editor.free(); return false; }
		ir::Ref exit_term_ref = decl.body[exit_term_pos];
		if ((usz)exit_term_ref >= (usz)editor.insts.len() || editor.insts.entries[(sz)exit_term_ref].tag != ir::InstTag.BRANCH) { editor.free(); return false; }
		editor.insts.entries[(sz)exit_term_ref] = { .tag = ir::InstTag.JMP,
			.data.ref = cfg.blocks[(sz)trip.exit_block].label, .ty = value_interner::REF_NORETURN };

		// Redirect the preheader into copy zero, making fallthrough explicit when needed.
		CfgBlock* preheader = &cfg.blocks[(sz)trip.preheader];
		sz pre_term_pos = block_terminator_position(decl, preheader);
		if (pre_term_pos < preheader.end)
		{
			ir::Ref term_ref = decl.body[pre_term_pos];
			cfg_redirect_target(&editor.insts.entries[(sz)term_ref], cfg.blocks[(sz)loop.header].label, label_of[0][(sz)loop.header]);
		}

		// Rebuild placement, inserting copies before the original header. Clone blocks
		// are emitted in loop block order, and all clone fallthroughs are explicit.
		list::List{ir::Ref} body; body.init(mem); defer body.free();
		// Keep the leading ARGs, which build_cfg places before every basic block.
		if (cfg.blocks.len) body.push_all(decl.body[:cfg.blocks[0].start]);
		foreach (block_index, block : cfg.blocks)
		{
			if (block_index == loop.header)
			{
				foreach (ref : clone_body) body.push(ref);
			}
			for (sz pos = block.start; pos < block.end; pos++)
			{
				ir::Ref ref = decl.body[pos];
				if ((usz)ref < (usz)remove.len && remove[(sz)ref]) continue;
				body.push(ref);
			}
			if (block_index == trip.preheader && pre_term_pos == preheader.end)
			{
				body.push(editor.append({ .tag = ir::InstTag.JMP, .data.ref = label_of[0][(sz)loop.header], .ty = value_interner::REF_NORETURN }));
			}
		}
		editor.body.clear();
		editor.body.push_all(body.array_view());
		editor.commit();
		analyses.mark_dirty();
		return true;
	};
}

<* Apply one unroll per CFG rebuild to a fixpoint, then clean unreachable blocks. *>
fn bool loop_full_unroll(ir::Ir* graph, ir::Decl* decl, usz threshold, FunctionAnalyses* cached = null)
{
	@pool()
	{
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		foreach (inst : decl.instructions)
			if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;
		bool changed = false;
		while (unroll_loop_once(graph, decl, threshold, cached)) changed = true;
		if (changed) remove_unreachable_blocks(decl);
		return changed;
	};
}
