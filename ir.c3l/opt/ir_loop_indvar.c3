// Basic scalar induction-variable recognition and bounded constant-trip simulation.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;
import std::collections::list;

const ulong INDVAR_MAX_SIMULATED_TRIPS = 1 << 16;

struct BasicIndVar
{
	ir::Ref phi;
	ir::Ref next;
	ir::Ref init;
	ulong step_bits;
	ushort width;
	value_interner::InternerRef ty;
}

struct LoopTripCount
{
	bool known;
	ulong backedge_taken;
	uint preheader;
	uint latch;
	uint exiting_block;
	uint exit_block;
	ir::Ref exit_branch;
	ir::Ref control_phi;
}

fn ulong indvar_value_at(BasicIndVar* iv, ulong init_bits, ulong iterations)
=> (init_bits + iv.step_bits * iterations) & const_prop_mask(iv.width);

fn uint indvar_block_for_label(Cfg* cfg, ir::Ref label)
{
	foreach (i, block : cfg.blocks) if (block.label == label) return (uint)i;
	return NONE_BLOCK;
}

fn bool indvar_compare_tag(ir::InstTag tag)
=> tag == ir::InstTag.CMP_EQ || tag == ir::InstTag.CMP_NE ||
tag == ir::InstTag.CMP_SLT || tag == ir::InstTag.CMP_SLTE ||
tag == ir::InstTag.CMP_SGT || tag == ir::InstTag.CMP_SGTE ||
tag == ir::InstTag.CMP_ULT || tag == ir::InstTag.CMP_ULTE ||
tag == ir::InstTag.CMP_UGT || tag == ir::InstTag.CMP_UGTE;

fn ir::InstTag indvar_swap_compare(ir::InstTag tag)
{
	switch (tag)
	{
		case CMP_SLT: return CMP_SGT;
		case CMP_SLTE: return CMP_SGTE;
		case CMP_SGT: return CMP_SLT;
		case CMP_SGTE: return CMP_SLTE;
		case CMP_ULT: return CMP_UGT;
		case CMP_ULTE: return CMP_UGTE;
		case CMP_UGT: return CMP_ULT;
		case CMP_UGTE: return CMP_ULTE;
		default: return tag;
	}
}

fn void loop_basic_ivs(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, LoopInfo* info,
	uint loop_index, uint preheader, uint latch, list::List{BasicIndVar} * out)
{
	if (loop_index >= info.loops.len()) return;
	Loop* loop = &info.loops.entries[(sz)loop_index];
	if ((usz)loop.header >= (usz)cfg.blocks.len || (usz)preheader >= (usz)cfg.blocks.len ||
	(usz)latch >= (usz)cfg.blocks.len || !loop_body_contains(loop, latch)) return;
	for (sz pos = cfg.blocks[(sz)loop.header].start + 1; pos < cfg.blocks[(sz)loop.header].end; pos++)
	{
		ir::Ref phi_ref = decl.body[pos];
		if ((usz)phi_ref >= (usz)decl.instructions.len) break;
		ir::Inst phi = decl.instructions[(sz)phi_ref];
		if (phi.tag != ir::InstTag.PHI) break;
		ushort width;
		if (!const_prop_int_width(graph, phi.ty, &width)) continue;
		ir::Ref init = ir::NONE;
		ir::Ref next = ir::NONE;
		bool bad = false;
		sz input_count = 0;
		foreach (input : phi.data.phi)
		{
			input_count++;
			if (input.label == cfg.blocks[(sz)preheader].label)
			{
				if (init != ir::NONE)
				{
					bad = true; break;
				}
				init = input.value;
			}
			else if (input.label == cfg.blocks[(sz)latch].label)
			{
				if (next != ir::NONE)
				{
					bad = true; break;
				}
				next = input.value;
			}
			else
			{
				bad = true; break;
			}
		}
		if (bad || input_count != 2 || init == ir::NONE || next == ir::NONE ||
			(usz)next >= (usz)decl.instructions.len) continue;
		ir::Inst update = decl.instructions[(sz)next];
		if ((update.tag != ir::InstTag.ADD && update.tag != ir::InstTag.SUB) || update.ty != phi.ty) continue;
		ir::Ref step_ref = ir::NONE;
		if (update.data.bin.lhs == phi_ref)
		{
			step_ref = update.data.bin.rhs;
		}
		else if (update.tag == ir::InstTag.ADD && update.data.bin.rhs == phi_ref)
		{
			step_ref = update.data.bin.lhs;
		}
		if (step_ref == ir::NONE || (usz)step_ref >= (usz)decl.instructions.len || decl.instructions[(sz)step_ref].ty != phi.ty) continue;
		ulong step_bits;
		if (!scalar_constant_bits(graph, decl.instructions, step_ref, &step_bits)) continue;
		if (update.tag == ir::InstTag.SUB) step_bits = (0 - step_bits) & const_prop_mask(width);
		out.push(
		{
			.phi = phi_ref, .next = next, .init = init, .step_bits = step_bits, .width = width, .ty = phi.ty
		}
		);
	}
}

enum IndvarExtension : char
{
	NONE,
	ZEXT,
	SEXT,
}

<* `operand` as the IV's PHI or next value, possibly through one ZEXT/SEXT.
   Returns the underlying IV ref (or NONE) and the compare width. *>
fn ir::Ref indvar_compare_operand(ir::Ir* graph, ir::Decl* decl, BasicIndVar* iv, ir::Ref operand,
	IndvarExtension* extension, ushort* cmp_width)
{
	if (operand == iv.phi || operand == iv.next)
	{
		*extension = NONE;
		*cmp_width = iv.width;
		return operand;
	}
	if ((usz)operand >= (usz)decl.instructions.len) return ir::NONE;
	ir::Inst* inst = &decl.instructions[(sz)operand];
	if (inst.tag != ir::InstTag.ZEXT && inst.tag != ir::InstTag.SEXT) return ir::NONE;
	if (inst.data.ref != iv.phi && inst.data.ref != iv.next) return ir::NONE;
	ushort width;
	if (!const_prop_int_width(graph, inst.ty, &width) || width < iv.width) return ir::NONE;
	*extension = inst.tag == ir::InstTag.ZEXT ? ZEXT : SEXT;
	*cmp_width = width;
	return inst.data.ref;
}

fn bool loop_constant_trip_count(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, LoopInfo* info,
	uint loop_index, LoopTripCount* out)
{
	*out = { .known = false };
	if (loop_index >= info.loops.len()) return false;
	Loop* loop = &info.loops.entries[(sz)loop_index];
	if (loop.header == 0 || loop.latches.len() != 1 || loop.exits.len() != 1) return false;
	uint preheader = loop_existing_preheader(decl, cfg, info, loop_index);
	if (preheader == NONE_BLOCK) return false;
	uint latch = loop.latches.entries[0];
	uint exit_block = loop.exits.entries[0];
	uint exiting = NONE_BLOCK;
	foreach (block_index : loop.blocks)
	{
		uint outside_count = 0;
		uint outside_block = NONE_BLOCK;
		foreach (succ : cfg.blocks[(sz)block_index].succs)
		if (!loop_body_contains(loop, succ))
		{
			outside_count++; outside_block = succ;
		}
		if (!outside_count) continue;
		if (outside_count != 1 || outside_block != exit_block || exiting != NONE_BLOCK) return false;
		exiting = block_index;
	}
	if (exiting == NONE_BLOCK) return false;
	list::List{BasicIndVar} ivs; ivs.init(cfg.allocator); defer ivs.free();
	loop_basic_ivs(graph, decl, cfg, info, loop_index, preheader, latch, &ivs);
	foreach (iv : ivs)
	{
		ulong init_bits;
		if (!scalar_constant_bits(graph, decl.instructions, iv.init, &init_bits)) continue;
		if (exiting == NONE_BLOCK || (exiting != loop.header && exiting != latch)) continue;
		CfgBlock* block = &cfg.blocks[(sz)exiting];
		sz term_pos = block_terminator_position(decl, block);
		if (term_pos == block.end) continue;
		ir::Ref branch_ref = decl.body[term_pos];
		if ((usz)branch_ref >= (usz)decl.instructions.len) continue;
		ir::Inst branch = decl.instructions[(sz)branch_ref];
		if (branch.tag != ir::InstTag.BRANCH || (usz)branch.data.branch.cond >= (usz)decl.instructions.len) continue;
		uint then_block = indvar_block_for_label(cfg, branch.data.branch.then_label);
		uint else_block = indvar_block_for_label(cfg, branch.data.branch.else_label);
		bool then_exit = then_block == exit_block;
		bool else_exit = else_block == exit_block;
		if (then_block == NONE_BLOCK || else_block == NONE_BLOCK || then_block == else_block ||
			then_exit == else_exit || (then_exit && !loop_body_contains(loop, else_block)) ||
		(else_exit && !loop_body_contains(loop, then_block))) continue;
		ir::Inst cmp = decl.instructions[(sz)branch.data.branch.cond];
		if (!indvar_compare_tag(cmp.tag)) continue;
		// The compare may see the IV through an integer promotion (C compares an
		// unsigned char counter as ZEXT to int), as SCEV looks through zext/sext.
		ir::Ref control_ref = ir::NONE;
		ir::Ref bound_ref = ir::NONE;
		bool control_is_rhs = false;
		IndvarExtension extension = NONE;
		ushort cmp_width = iv.width;
		control_ref = indvar_compare_operand(graph, decl, &iv, cmp.data.bin.lhs, &extension, &cmp_width);
		if (control_ref != ir::NONE)
		{
			bound_ref = cmp.data.bin.rhs;
		}
		else
		{
			control_ref = indvar_compare_operand(graph, decl, &iv, cmp.data.bin.rhs, &extension, &cmp_width);
			bound_ref = cmp.data.bin.lhs;
			control_is_rhs = true;
		}
		if (control_ref == ir::NONE || (usz)bound_ref >= (usz)decl.instructions.len) continue;
		ulong bound;
		if (!scalar_constant_bits(graph, decl.instructions, bound_ref, &bound)) continue;
		bound &= const_prop_mask(cmp_width);
		ir::InstTag cmp_tag = cmp.tag;
		if (control_is_rhs) cmp_tag = indvar_swap_compare(cmp_tag);
		bool exit_on_true = then_exit;
		ulong next_iteration = control_ref == iv.next ? 1 : 0;
		for (ulong backedges = 0; backedges < INDVAR_MAX_SIMULATED_TRIPS; backedges++)
		{
			ulong value = indvar_value_at(&iv, init_bits, backedges + next_iteration);
			// ZEXT: the IV-width value is already zero-extended by the mask.
			if (extension == SEXT) value = (ulong)const_prop_signed(value, iv.width) & const_prop_mask(cmp_width);
			bool comparison;
			if (!const_prop_compare_bits(cmp_tag, cmp_width, value, bound, &comparison)) break;
			if (comparison == exit_on_true)
			{
				*out = { .known = true, .backedge_taken = backedges, .preheader = preheader,
				.latch = latch, .exiting_block = exiting, .exit_block = exit_block,
				.exit_branch = branch_ref, .control_phi = iv.phi };
				return true;
			}
		}
	}
	return false;
}

fn bool indvar_definition_dominates_exit(Cfg* cfg, ir::Decl* decl, ir::Ref def, uint exit_block)
{
	if ((usz)def >= (usz)cfg.block_of_ref.len) return false;
	uint def_block = cfg.block_of_ref[(sz)def];
	if (def_block == NONE_BLOCK || !cfg.dominates(def_block, exit_block)) return false;
	if (def_block == exit_block)
	{
		sz def_pos = -1;
		sz term_pos = block_terminator_position(decl, &cfg.blocks[(sz)exit_block]);
		foreach (pos, ref : decl.body) if (ref == def)
		{
			def_pos = pos; break;
		}
		if (def_pos < 0 || def_pos >= term_pos) return false;
	}
	return true;
}

fn bool indvar_simplify(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
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
		bool preheaders_changed = ensure_preheaders(decl, analyses);
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.blocks.len) return false;
		if (!cfg.idom.len) cfg.compute_dominators();
		LoopInfo* loops = analyses.get_loops();
		DeclEditor editor; editor.begin(decl); bool changed = false;
		foreach (loop_index, loop : loops.loops)
		{
			if (loop.header == 0 || loop.latches.len() != 1) continue;
			uint preheader = loop_existing_preheader(decl, cfg, loops, (uint)loop_index);
			if (preheader == NONE_BLOCK) continue;
			uint latch = loop.latches.entries[0];
			list::List{BasicIndVar} ivs; ivs.init(mem); defer ivs.free();
			loop_basic_ivs(graph, decl, cfg, loops, (uint)loop_index, preheader, latch, &ivs);
			foreach (iv : ivs)
			{
				LoopTripCount trip;
				if (!loop_constant_trip_count(graph, decl, cfg, loops, (uint)loop_index, &trip) || !trip.known) continue;
				ulong init_bits;
				if (!scalar_constant_bits(graph, decl.instructions, iv.init, &init_bits)) continue;
				ir::Ref phi_constant = scalar_constant(graph, &editor, iv.width,
					indvar_value_at(&iv, init_bits, trip.backedge_taken), iv.ty);
				bool replace_next = indvar_definition_dominates_exit(cfg, decl, iv.next, trip.exiting_block);
				ir::Ref next_constant = ir::NONE;
				if (replace_next) next_constant = scalar_constant(graph, &editor, iv.width,
					indvar_value_at(&iv, init_bits, trip.backedge_taken + 1), iv.ty);
				foreach (body_ref : decl.body)
				{
					if ((usz)body_ref >= (usz)editor.insts.len()) continue;
					ir::Inst* user = &editor.insts.entries[(sz)body_ref];
					uint home = cfg.block_of_ref[(sz)body_ref];
					if (user.tag == ir::InstTag.PHI)
					{
						if (home == NONE_BLOCK || loop.contains(loops, home)) continue;
						foreach (&input : user.data.phi)
						{
							if (input.label != cfg.blocks[(sz)trip.exiting_block].label) continue;
							if (input.value == iv.phi)
							{
								input.value = phi_constant; changed = true;
							}
							if (replace_next && input.value == iv.next)
							{
								input.value = next_constant; changed = true;
							}
						}
						continue;
					}
					if (home == NONE_BLOCK || loop.contains(loops, home)) continue;
					@each_value_operand(user; ir::Ref* operand)
					{
						if (*operand == iv.phi)
						{
							*operand = phi_constant; changed = true;
						}
						if (replace_next && *operand == iv.next)
						{
							*operand = next_constant; changed = true;
						}
					};
				}
			}
		}
		if (!changed)
		{
			editor.free(); return preheaders_changed;
		}
		editor.commit(); return true;
	};
}
