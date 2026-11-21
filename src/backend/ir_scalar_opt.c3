// Conservative scalar transforms for the index-based IR. No memory or FP
// operations are eliminated, speculated, or reassociated here.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, aro::primitive_value;
import std::collections::list, std::collections::map;

fn bool scalar_constant_bits(ir::Ir* graph, ir::Inst[] insts, ir::Ref ref, ulong* bits)
{
	if ((usz)ref >= (usz)insts.len || insts[(sz)ref].tag != ir::InstTag.CONSTANT) return false;
	ushort width;
	if (!const_prop_int_width(graph, insts[(sz)ref].ty, &width)) return false;
	PrimitiveValue key = graph.interner.get(insts[(sz)ref].data.constant);
	if (key.tag.kind != NumberKind.INT || !key.int_fits_64()) return false;
	*bits = key.int_low_u64() & const_prop_mask(width);
	return true;
}

fn ir::Ref scalar_constant(ir::Ir* graph, DeclEditor* editor, ushort width, ulong bits, value_interner::InternerRef ty)
{
	return editor.add_constant(graph.interner.put(primitive_value::int_key(const_prop_signed(bits, width))), ty);
}

fn bool scalar_commutative(ir::InstTag tag)
{
	switch (tag)
	{
		case ADD:
		case MUL:
		case BIT_AND:
		case BIT_OR:
		case BIT_XOR:
		case CMP_EQ:
		case CMP_NE: return true;
		default: return false;
	}
}

fn ir::Ref simplify_integer_inst(ir::Ir* graph, DeclEditor* editor, ir::Ref ref)
{
	// Copy before appending constants: growing the instruction list invalidates pointers.
	ir::Inst inst = editor.insts.entries[(sz)ref];
	ushort width;
	if (!const_prop_int_width(graph, inst.ty, &width)) return ir::NONE;
	switch (inst.tag)
	{
		case SELECT:
			if (inst.data.branch.then_label == inst.data.branch.else_label) return inst.data.branch.then_label;
			ulong condition;
			if (scalar_constant_bits(graph, editor.insts.array_view(), inst.data.branch.cond, &condition))
			{
				return condition != 0 ? inst.data.branch.then_label : inst.data.branch.else_label;
			}
			return ir::NONE;
		case TRUNC:
		case ZEXT:
		case SEXT:
			ir::Inst operand = editor.insts.entries[(sz)inst.data.ref];
			if (operand.ty == inst.ty) return inst.data.ref;
			if (inst.tag == ir::InstTag.TRUNC && (operand.tag == ir::InstTag.ZEXT || operand.tag == ir::InstTag.SEXT) &&
				editor.insts.entries[(sz)operand.data.ref].ty == inst.ty) return operand.data.ref;
			return ir::NONE;
		case BIT_NOT:
		case NEGATE:
			ir::Inst unary = editor.insts.entries[(sz)inst.data.ref];
			if (unary.tag == inst.tag && unary.ty == inst.ty) return unary.data.ref;
			return ir::NONE;
		case ADD:
		case SUB:
		case MUL:
		case BIT_AND:
		case BIT_OR:
		case BIT_XOR:
		case BIT_SHL:
		case BIT_ASHR:
		case BIT_LSHR:
		case SDIV:
		case UDIV:
		case SREM:
		case UREM:
		case CMP_EQ:
		case CMP_NE:
		case CMP_SLT:
		case CMP_SLTE:
		case CMP_SGT:
		case CMP_SGTE:
		case CMP_ULT:
		case CMP_ULTE:
		case CMP_UGT:
		case CMP_UGTE: break;
		default: return ir::NONE;
	}
	ir::Ref lhs = inst.data.bin.lhs;
	ir::Ref rhs = inst.data.bin.rhs;
	ushort operand_width;
	if (!const_prop_int_width(graph, editor.insts.entries[(sz)lhs].ty, &operand_width) ||
		editor.insts.entries[(sz)lhs].ty != editor.insts.entries[(sz)rhs].ty) return ir::NONE;
	ulong a, b;
	bool ca = scalar_constant_bits(graph, editor.insts.array_view(), lhs, &a);
	bool cb = scalar_constant_bits(graph, editor.insts.array_view(), rhs, &b);
	if (scalar_commutative(inst.tag) && ca && !cb)
	{
		editor.insts.entries[(sz)ref].data.bin = { rhs, lhs };
		lhs = rhs; rhs = inst.data.bin.lhs; cb = true; b = a;
	}
	switch (inst.tag)
	{
		case ADD:
		case BIT_OR:
		case BIT_XOR:
			if (cb && b == 0) return lhs;
		case SUB:
			if (cb && b == 0) return lhs;
		case MUL:
			if (cb && b == 1) return lhs;
			if (cb && b == 0) return rhs;
		case BIT_AND:
			if (cb && b == const_prop_mask(operand_width)) return lhs;
			if (cb && b == 0) return rhs;
		case BIT_SHL:
		case BIT_ASHR:
		case BIT_LSHR:
			if (cb && b == 0) return lhs;
		case SDIV:
			if (cb && b == 1 && operand_width > 1) return lhs;
		case UDIV:
			if (cb && b == 1) return lhs;
		case SREM:
			if (cb && b == 1 && operand_width > 1) return scalar_constant(graph, editor, width, 0, inst.ty);
		case UREM:
			if (cb && b == 1) return scalar_constant(graph, editor, width, 0, inst.ty);
		default: break;
	}
	if (lhs != rhs) return ir::NONE;
	switch (inst.tag)
	{
		case BIT_AND:
		case BIT_OR: return lhs;
		case SUB:
		case BIT_XOR:
		case CMP_NE:
		case CMP_SLT:
		case CMP_SGT:
		case CMP_ULT:
		case CMP_UGT: return scalar_constant(graph, editor, width, 0, inst.ty);
		case CMP_EQ:
		case CMP_SLTE:
		case CMP_SGTE:
		case CMP_ULTE:
		case CMP_UGTE: return scalar_constant(graph, editor, width, 1, inst.ty);
		default: return ir::NONE;
	}
}

fn ir::Ref simplify_phi(ir::Inst inst, ir::Ref ref)
{
	ir::Ref candidate = ir::NONE;
	foreach (input : inst.data.phi)
	{
		if (input.value == ref) continue;
		if (candidate != ir::NONE && candidate != input.value) return ir::NONE;
		candidate = input.value;
	}
	return candidate;
}

<* Worklist-driven integer identities and trivial PHIs; preserves CFG and effects. *>
fn bool integer_simplify(ir::Ir* graph, ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
	Uses uses = compute_uses(decl, allocator);
	defer uses.free();
	DeclEditor editor;
	editor.begin(decl, allocator);
	bool[] remove = alloc::new_array(allocator, bool, decl.instructions.len);
	defer alloc::free(allocator, remove.ptr);
	bool[] queued = alloc::new_array(allocator, bool, decl.instructions.len);
	defer alloc::free(allocator, queued.ptr);
	remove[..] = false;
	queued[..] = false;
	List{ir::Ref} worklist;
	worklist.init(allocator);
	defer worklist.free();
	// Seed in reverse order so the first sweep follows the original body.
	for (sz pos = decl.body.len; pos > 0; pos--)
	{
		ir::Ref ref = decl.body[pos - 1];
		worklist.push(ref);
		queued[(sz)ref] = true;
	}
	bool changed = false;
	while (worklist.len())
	{
		ir::Ref ref = worklist.pop()!!;
		queued[(sz)ref] = false;
		if (remove[(sz)ref]) continue;
		ir::Inst before = editor.insts.entries[(sz)ref];
		ir::Ref replacement;
		if (before.tag == ir::InstTag.PHI) { replacement = simplify_phi(before, ref); }
		else { replacement = simplify_integer_inst(graph, &editor, ref); }
		if (scalar_commutative(before.tag) && before.data.bin.lhs != editor.insts.entries[(sz)ref].data.bin.lhs)
		{
			changed = true;
		}
		if (replacement == ir::NONE || replacement == ref) continue;
		remove[(sz)ref] = true;
		changed = true;
		// Update actual users and transfer their use edges to the replacement.
		// A later simplification of the replacement must revisit these users too.
		foreach (user_ref : uses.users[(sz)ref])
		{
			if (remove[(sz)user_ref]) continue;
			bool replaced = false;
			@each_value_operand(&editor.insts.entries[(sz)user_ref]; ir::Ref* slot)
			{
				if (*slot == ref) { *slot = replacement; replaced = true; }
			};
			if (!replaced) continue;
			if ((usz)replacement < (usz)uses.users.len) uses.users[(sz)replacement].push(user_ref);
			if (!queued[(sz)user_ref])
			{
				worklist.push(user_ref);
				queued[(sz)user_ref] = true;
			}
		}
	}
	BodyRemovalContext context = { .remove = remove };
	editor.remove_body_where(&body_ref_marked_for_removal, &context);
	editor.commit();
	return changed;
}

struct ScalarExpr
{
	ir::InstTag tag;
	value_interner::InternerRef ty;
	ir::Ref a;
	ir::Ref b;
}

fn uint ScalarExpr.hash(self)
{
	// Hash fields individually: struct padding is not part of an expression.
	return (uint)self.tag * 0x9E3779B9 ^ (uint)self.ty * 0x85EBCA6B ^
		(uint)self.a * 0xC2B2AE35 ^ (uint)self.b * 0x27D4EB2F;
}

fn bool ScalarExpr.equals(self, ScalarExpr other)
=> self.tag == other.tag && self.ty == other.ty && self.a == other.a && self.b == other.b;

fn bool scalar_expression(ir::Ir* graph, ir::Inst inst, ScalarExpr* key)
{
	ushort width;
	if (!const_prop_int_width(graph, inst.ty, &width)) return false;
	*key = { .tag = inst.tag, .ty = inst.ty };
	switch (inst.tag)
	{
		case ADD:
		case SUB:
		case MUL:
		case BIT_AND:
		case BIT_OR:
		case BIT_XOR:
		case BIT_SHL:
		case BIT_ASHR:
		case BIT_LSHR:
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
			key.a = inst.data.bin.lhs; key.b = inst.data.bin.rhs;
			if (scalar_commutative(inst.tag) && key.a > key.b)
			{
				ir::Ref swap = key.a; key.a = key.b; key.b = swap;
			}
			return true;
		case TRUNC:
		case ZEXT:
		case SEXT:
		case BIT_NOT:
		case NEGATE:
			key.a = inst.data.ref; key.b = ir::NONE;
			return true;
		default: return false;
	}
}

fn ir::Ref scalar_resolve(ir::Ref[] replacements, ir::Ref ref)
{
	while (replacements[(sz)ref] != ref) ref = replacements[(sz)ref];
	return ref;
}

struct CseContext
{
	ir::Ir* graph;
	DeclEditor* editor;
	Cfg* cfg;
	HashMap{ScalarExpr, ir::Ref} available;
	ir::Ref[] replacements;
	bool[] remove;
}

fn void cse_block(CseContext* context, uint block_index)
{
	List{ScalarExpr} inserted;
	inserted.init(context.cfg.allocator);
	defer inserted.free();
	CfgBlock* block = &context.cfg.blocks[(sz)block_index];
	sz end = block_executable_end(context.cfg.decl, block);
	for (sz pos = block.start + 1; pos < end; pos++)
	{
		ir::Ref ref = context.editor.body.entries[pos];
		ir::Inst* inst = &context.editor.insts.entries[(sz)ref];
		@each_value_operand(inst; ir::Ref* slot) { *slot = scalar_resolve(context.replacements, *slot); };
		ScalarExpr key;
		if (!scalar_expression(context.graph, *inst, &key)) continue;
		ir::Ref previous = context.available.get(key) ?? ir::NONE;
		if (previous != ir::NONE)
		{
			context.replacements[(sz)ref] = previous;
			context.remove[(sz)ref] = true;
		}
		else
		{
			context.available.set(key, ref);
			inserted.push(key);
		}
	}
	foreach (child : block.dom_children) cse_block(context, child);
	foreach (key : inserted) context.available.set(key, ir::NONE);
}

<* Dominator-scoped CSE of integer expressions, excluding loads, calls and division. *>
fn bool early_cse(ir::Ir* graph, ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
	Cfg cfg = build_cfg(decl, allocator);
	defer cfg.free();
	if (!cfg.blocks.len) return false;
	cfg.compute_dominators();
	DeclEditor editor;
	editor.begin(decl, allocator);
	CseContext context = { .graph = graph, .editor = &editor, .cfg = &cfg };
	context.available.init(allocator);
	defer context.available.free();
	context.replacements = alloc::new_array(allocator, ir::Ref, decl.instructions.len);
	defer alloc::free(allocator, context.replacements.ptr);
	context.remove = alloc::new_array(allocator, bool, decl.instructions.len);
	defer alloc::free(allocator, context.remove.ptr);
	context.remove[..] = false;
	foreach (i, inst : decl.instructions)
	{
		context.replacements[i] = (ir::Ref)i;
		if (inst.tag != ir::InstTag.CONSTANT) continue;
		ScalarExpr key = { .tag = inst.tag, .ty = inst.ty, .a = (ir::Ref)inst.data.constant };
		ir::Ref previous = context.available.get(key) ?? ir::NONE;
		if (previous == ir::NONE) { context.available.set(key, (ir::Ref)i); }
		else { context.replacements[i] = previous; }
	}
	cse_block(&context, 0);
	bool changed = false;
	foreach (ref : editor.body)
	{
		changed = changed || context.remove[(sz)ref];
		// Includes backedge PHI operands whose definitions were visited later.
		@each_value_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
		{
			*slot = scalar_resolve(context.replacements, *slot);
		};
	}
	BodyRemovalContext removal = { .remove = context.remove };
	editor.remove_body_where(&body_ref_marked_for_removal, &removal);
	editor.commit();
	return changed;
}

fn void cfg_redirect_target(ir::Inst* inst, ir::Ref old, ir::Ref replacement)
{
	switch (inst.tag)
	{
		case JMP: if (inst.data.ref == old) inst.data.ref = replacement;
		case BRANCH:
			if (inst.data.branch.then_label == old) inst.data.branch.then_label = replacement;
			if (inst.data.branch.else_label == old) inst.data.branch.else_label = replacement;
		case SWITCH:
			foreach (&label : inst.data.switch_data.labels) if (*label == old) *label = replacement;
			if (inst.data.switch_data.default_label == old) inst.data.switch_data.default_label = replacement;
		default: break;
	}
}

fn bool cfg_bypass_empty(ir::Decl* decl, Cfg* cfg, uint index, Allocator allocator)
{
	CfgBlock* block = &cfg.blocks[(sz)index];
	if (index == 0 || block.preds.len() == 0 || block.end != block.start + 2) return false;
	ir::Inst jump = decl.instructions[(sz)decl.body[block.start + 1]];
	if (jump.tag != ir::InstTag.JMP || jump.data.ref == block.label) return false;
	uint target_index = cfg.block_of_ref[(sz)jump.data.ref];
	CfgBlock* target = &cfg.blocks[(sz)target_index];
	// Redirecting P->B->T when P already has P->T would combine two PHI
	// inputs. Only do so when their values agree.
	for (sz pos = target.start + 1; pos < target.end; pos++)
	{
		ir::Inst phi = decl.instructions[(sz)decl.body[pos]];
		if (phi.tag != ir::InstTag.PHI) break;
		ir::Ref value = ir::NONE;
		foreach (input : phi.data.phi) if (input.label == block.label) value = input.value;
		if (value == ir::NONE) return false;
		foreach (input : phi.data.phi)
		{
			foreach (pred : block.preds)
			{
				if (input.label == cfg.blocks[(sz)pred].label && input.value != value) return false;
			}
		}
	}
	DeclEditor editor;
	editor.begin(decl, allocator);
	for (sz pos = target.start + 1; pos < target.end; pos++)
	{
		ir::Inst* phi = &editor.insts.entries[(sz)decl.body[pos]];
		if (phi.tag != ir::InstTag.PHI) break;
		List{ir::PhiInput} inputs;
		inputs.init(allocator);
		ir::Ref value = ir::NONE;
		foreach (input : phi.data.phi)
		{
			if (input.label == block.label) { value = input.value; }
			else { inputs.push(input); }
		}
		foreach (pred : block.preds)
		{
			ir::Ref label = cfg.blocks[(sz)pred].label;
			bool exists = false;
			foreach (input : inputs) if (input.label == label) exists = true;
			if (!exists) inputs.push({ .label = label, .value = value });
		}
		phi.data.phi = alloc::new_array(&decl.arena, ir::PhiInput, inputs.len());
		phi.data.phi[..] = inputs.array_view()[..];
		inputs.free();
	}
	editor.body.clear();
	foreach (i, &other : cfg.blocks)
	{
		if (i == 0) editor.body.push_all(decl.body[:other.start]);
		if (i == index) continue;
		editor.body.push_all(decl.body[other.start:other.end - other.start]);
		if (block_terminator_position(decl, other) == other.end && i + 1 == index)
		{
			ir::Ref explicit_jump = editor.append({ .tag = ir::InstTag.JMP, .data.ref = jump.data.ref, .ty = value_interner::REF_VOID });
			editor.body.push(explicit_jump);
		}
	}
	foreach (ref : editor.body) cfg_redirect_target(&editor.insts.entries[(sz)ref], block.label, jump.data.ref);
	editor.commit();
	return true;
}

<* The PHI-free case of cfg_bypass_empty, applied to every such block in one body
   rewrite. Removing jump-only blocks one per CFG rebuild is quadratic: a switch
   with 20000 case labels lowers to that many empty blocks. A block qualifies
   when its jump target starts with no PHI, so no incoming edge needs rewriting;
   chains of such blocks resolve to their final non-forwarded target. *>
fn bool cfg_bypass_empty_phi_free(ir::Decl* decl, Cfg* cfg, Allocator allocator)
{
	sz block_count = cfg.blocks.len;
	if (block_count < 2) return false;
	// forward[i]: the block i jumps to when i is removable, else NONE_BLOCK.
	uint[] forward = alloc::new_array(allocator, uint, block_count);
	defer alloc::free(allocator, forward.ptr);
	bool found = false;
	foreach (i, &block : cfg.blocks)
	{
		forward[i] = NONE_BLOCK;
		if (i == 0 || block.preds.len() == 0 || block.end != block.start + 2) continue;
		ir::Inst jump = decl.instructions[(sz)decl.body[block.start + 1]];
		if (jump.tag != ir::InstTag.JMP || jump.data.ref == block.label) continue;
		uint target_index = cfg.block_of_ref[(sz)jump.data.ref];
		if (target_index == NONE_BLOCK) continue;
		CfgBlock* target = &cfg.blocks[(sz)target_index];
		if (target.start + 1 < target.end &&
			decl.instructions[(sz)decl.body[target.start + 1]].tag == ir::InstTag.PHI) continue;
		forward[i] = target_index;
		found = true;
	}
	if (!found) return false;
	// final_target[i]: where control from removed block i lands. A cycle of empty
	// blocks keeps the block that closes it (it becomes the loop's only block).
	uint[] final_target = alloc::new_array(allocator, uint, block_count);
	defer alloc::free(allocator, final_target.ptr);
	char[] state = alloc::new_array(allocator, char, block_count); // 0 new, 1 walking, 2 done
	defer alloc::free(allocator, state.ptr);
	for (sz i = 0; i < block_count; i++) { final_target[i] = (uint)i; state[i] = 0; }
	list::List{uint} path;
	path.init(allocator);
	defer path.free();
	for (sz start = 0; start < block_count; start++)
	{
		if (state[start] != 0) continue;
		path.clear();
		uint cur = (uint)start;
		while (state[(sz)cur] == 0 && forward[(sz)cur] != NONE_BLOCK)
		{
			state[(sz)cur] = 1;
			path.push(cur);
			cur = forward[(sz)cur];
		}
		if (state[(sz)cur] == 1)
		{
			// `cur` closes a cycle: keep it as a real block.
			forward[(sz)cur] = NONE_BLOCK;
		}
		uint landing = final_target[(sz)cur];
		state[(sz)cur] = 2;
		foreach (block : path)
		{
			if (block == cur) continue;
			final_target[(sz)block] = landing;
			state[(sz)block] = 2;
		}
	}
	found = false;
	for (sz i = 0; i < block_count; i++) if (forward[i] != NONE_BLOCK) found = true;
	if (!found) return false;
	DeclEditor editor;
	editor.begin(decl, allocator);
	editor.body.clear();
	foreach (i, &other : cfg.blocks)
	{
		if (i == 0) editor.body.push_all(decl.body[:other.start]);
		if (forward[i] != NONE_BLOCK) continue;
		editor.body.push_all(decl.body[other.start:other.end - other.start]);
		// An implicit fallthrough into a removed block now needs an explicit jump.
		if (i + 1 < block_count && forward[i + 1] != NONE_BLOCK &&
			block_terminator_position(decl, other) == other.end)
		{
			ir::Ref landing = cfg.blocks[(sz)final_target[i + 1]].label;
			editor.body.push(editor.append({ .tag = ir::InstTag.JMP, .data.ref = landing, .ty = value_interner::REF_VOID }));
		}
	}
	foreach (ref : editor.body)
	{
		@each_label_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
		{
			uint target_block = (usz)*slot < (usz)decl.instructions.len ? cfg.block_of_ref[(sz)*slot] : NONE_BLOCK;
			if (target_block != NONE_BLOCK && forward[(sz)target_block] != NONE_BLOCK &&
				cfg.blocks[(sz)target_block].label == *slot)
			{
				*slot = cfg.blocks[(sz)final_target[(sz)target_block]].label;
			}
		};
	}
	editor.commit();
	return true;
}

<* cfg_bypass_empty for jump-only blocks whose target starts with PHIs, batched per
   target: a return block's PHI gathers one input per `return` arm, so bypassing
   them one per CFG rebuild is quadratic. Each candidate is checked against the
   target's PHIs as already rewritten by earlier candidates. Run only after
   cfg_bypass_empty_phi_free finds nothing, so no candidate's predecessor is
   itself being removed. *>
alias PhiInputList = list::List{ir::PhiInput};

fn bool cfg_bypass_empty_into_phis(ir::Decl* decl, Cfg* cfg, Allocator allocator)
{
	sz block_count = cfg.blocks.len;
	if (block_count < 2) return false;
	// forward[i]: the block removed block i jumped to, else NONE_BLOCK.
	uint[] forward = alloc::new_array(allocator, uint, block_count);
	defer alloc::free(allocator, forward.ptr);
	for (sz i = 0; i < block_count; i++) forward[i] = NONE_BLOCK;
	bool found = false;
	DeclEditor editor;
	editor.begin(decl, allocator);
	list::List{PhiInputList} working;
	working.init(allocator);
	defer
	{
		foreach (&inputs : working) inputs.free();
		working.free();
	}
	foreach (t, &target : cfg.blocks)
	{
		sz phi_end = target.start + 1;
		while (phi_end < target.end && decl.instructions[(sz)decl.body[phi_end]].tag == ir::InstTag.PHI) phi_end++;
		sz phi_count = phi_end - (target.start + 1);
		if (phi_count == 0) continue;
		foreach (&inputs : working) inputs.free();
		working.clear();
		for (sz k = 0; k < phi_count; k++)
		{
			PhiInputList inputs;
			inputs.init(allocator);
			inputs.push_all(decl.instructions[(sz)decl.body[target.start + 1 + k]].data.phi);
			working.push(inputs);
		}
		bool target_changed = false;
		foreach (b : target.preds)
		{
			CfgBlock* block = &cfg.blocks[(sz)b];
			if (b == 0 || b == (uint)t || block.preds.len() == 0 || block.end != block.start + 2) continue;
			ir::Inst jump = decl.instructions[(sz)decl.body[block.start + 1]];
			if (jump.tag != ir::InstTag.JMP || jump.data.ref != target.label) continue;
			bool feasible = true;
			foreach (&inputs : working)
			{
				ir::Ref value = ir::NONE;
				foreach (input : *inputs) if (input.label == block.label) value = input.value;
				if (value == ir::NONE) { feasible = false; break; }
				foreach (input : *inputs)
				{
					foreach (pred : block.preds)
					{
						if (input.label == cfg.blocks[(sz)pred].label && input.value != value) feasible = false;
					}
				}
				if (!feasible) break;
			}
			if (!feasible) continue;
			foreach (&inputs : working)
			{
				ir::Ref value = ir::NONE;
				sz write = 0;
				for (sz read = 0; read < inputs.len(); read++)
				{
					ir::PhiInput input = inputs.entries[read];
					if (input.label == block.label) { value = input.value; continue; }
					inputs.entries[write++] = input;
				}
				while (inputs.len() > write) inputs.pop()!!;
				foreach (pred : block.preds)
				{
					ir::Ref label = cfg.blocks[(sz)pred].label;
					bool exists = false;
					foreach (input : *inputs) if (input.label == label) exists = true;
					if (!exists) inputs.push({ .label = label, .value = value });
				}
			}
			forward[(sz)b] = (uint)t;
			target_changed = true;
			found = true;
		}
		if (!target_changed) continue;
		for (sz k = 0; k < phi_count; k++)
		{
			ir::Inst* phi = &editor.insts.entries[(sz)decl.body[target.start + 1 + k]];
			phi.data.phi = alloc::new_array(&decl.arena, ir::PhiInput, working[k].len());
			phi.data.phi[..] = working[k].array_view()[..];
		}
	}
	if (!found)
	{
		editor.free();
		return false;
	}
	editor.body.clear();
	foreach (i, &other : cfg.blocks)
	{
		if (i == 0) editor.body.push_all(decl.body[:other.start]);
		if (forward[i] != NONE_BLOCK) continue;
		editor.body.push_all(decl.body[other.start:other.end - other.start]);
		// An implicit fallthrough into a removed block now needs an explicit jump.
		if (i + 1 < block_count && forward[i + 1] != NONE_BLOCK &&
			block_terminator_position(decl, other) == other.end)
		{
			ir::Ref landing = cfg.blocks[(sz)forward[i + 1]].label;
			editor.body.push(editor.append({ .tag = ir::InstTag.JMP, .data.ref = landing, .ty = value_interner::REF_VOID }));
		}
	}
	foreach (ref : editor.body)
	{
		ir::Inst* inst = &editor.insts.entries[(sz)ref];
		if (inst.tag == ir::InstTag.PHI) continue;
		@each_label_operand(inst; ir::Ref* slot)
		{
			uint target_block = (usz)*slot < (usz)decl.instructions.len ? cfg.block_of_ref[(sz)*slot] : NONE_BLOCK;
			if (target_block != NONE_BLOCK && forward[(sz)target_block] != NONE_BLOCK &&
				cfg.blocks[(sz)target_block].label == *slot)
			{
				*slot = cfg.blocks[(sz)forward[(sz)target_block]].label;
			}
		};
	}
	editor.commit();
	return true;
}

fn bool cfg_merge_successor(ir::Decl* decl, Cfg* cfg, uint index, Allocator allocator)
{
	CfgBlock* block = &cfg.blocks[(sz)index];
	if (block.succs.len() != 1) return false;
	uint next_index = block.succs.entries[0];
	if (next_index == 0 || next_index == index) return false;
	CfgBlock* next = &cfg.blocks[(sz)next_index];
	if (next.preds.len() != 1) return false;
	sz term = block_terminator_position(decl, block);
	if (term < block.end && decl.instructions[(sz)decl.body[term]].tag != ir::InstTag.JMP) return false;
	DeclEditor editor;
	editor.begin(decl, allocator);
	sz first = next.start + 1;
	while (first < next.end)
	{
		ir::Ref ref = decl.body[first];
		ir::Inst phi = editor.insts.entries[(sz)ref];
		if (phi.tag != ir::InstTag.PHI) break;
		if (phi.data.phi.len != 1 || phi.data.phi[0].value == ref)
		{
			editor.free();
			return false;
		}
		editor_replace_all_uses(&editor, ref, phi.data.phi[0].value);
		first++;
	}
	editor.body.clear();
	foreach (i, &other : cfg.blocks)
	{
		if (i == 0) editor.body.push_all(decl.body[:other.start]);
		if (i == next_index) continue;
		if (i != index) { editor.body.push_all(decl.body[other.start:other.end - other.start]); continue; }
		editor.body.push_all(decl.body[block.start:term - block.start]);
		editor.body.push_all(decl.body[first:next.end - first]);
		// Preserve the moved block's original implicit fallthrough destination.
		if (block_terminator_position(decl, next) == next.end && (sz)next_index + 1 < cfg.blocks.len)
		{
			ir::Ref jump = editor.append({ .tag = ir::InstTag.JMP,
				.data.ref = cfg.blocks[(sz)next_index + 1].label, .ty = value_interner::REF_VOID });
			editor.body.push(jump);
		}
	}
	foreach (ref : editor.body)
	{
		@each_label_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
		{
			if (*slot == next.label) *slot = block.label;
		};
	}
	editor.commit();
	return true;
}

<* The PHI-free case of cfg_merge_successor, applied to whole chains in one body
   rewrite: B -> S where B has one successor, S has one predecessor and starts
   with no PHI. Reachable chains are acyclic (entry is never absorbed and a
   reachable cycle needs a second predecessor), so each chain has one head. *>
fn bool cfg_merge_successors_phi_free(ir::Decl* decl, Cfg* cfg, Allocator allocator)
{
	sz block_count = cfg.blocks.len;
	if (block_count < 2) return false;
	uint[] next_of = alloc::new_array(allocator, uint, block_count);
	defer alloc::free(allocator, next_of.ptr);
	bool[] absorbed = alloc::new_array(allocator, bool, block_count);
	defer alloc::free(allocator, absorbed.ptr);
	for (sz i = 0; i < block_count; i++) { next_of[i] = NONE_BLOCK; absorbed[i] = false; }
	bool found = false;
	foreach (i, &block : cfg.blocks)
	{
		if (!cfg.reachable[i] || block.succs.len() != 1) continue;
		uint next_index = block.succs.entries[0];
		if (next_index == 0 || next_index == (uint)i || !cfg.reachable[(sz)next_index]) continue;
		CfgBlock* next = &cfg.blocks[(sz)next_index];
		if (next.preds.len() != 1) continue;
		sz term = block_terminator_position(decl, block);
		if (term < block.end && decl.instructions[(sz)decl.body[term]].tag != ir::InstTag.JMP) continue;
		if (next.start + 1 < next.end &&
			decl.instructions[(sz)decl.body[next.start + 1]].tag == ir::InstTag.PHI) continue;
		next_of[i] = next_index;
		absorbed[(sz)next_index] = true;
		found = true;
	}
	if (!found) return false;
	uint[] head_of = alloc::new_array(allocator, uint, block_count);
	defer alloc::free(allocator, head_of.ptr);
	for (sz i = 0; i < block_count; i++) head_of[i] = (uint)i;
	DeclEditor editor;
	editor.begin(decl, allocator);
	editor.body.clear();
	foreach (i, &other : cfg.blocks)
	{
		if (i == 0) editor.body.push_all(decl.body[:other.start]);
		if (absorbed[i]) continue;
		if (next_of[i] == NONE_BLOCK)
		{
			editor.body.push_all(decl.body[other.start:other.end - other.start]);
			continue;
		}
		// Head and inner members contribute everything before their JMP (or
		// implicit fallthrough); the last member keeps its own terminator.
		uint cur = (uint)i;
		while (true)
		{
			CfgBlock* block = &cfg.blocks[(sz)cur];
			sz first = cur == (uint)i ? block.start : block.start + 1;
			head_of[(sz)cur] = (uint)i;
			if (next_of[(sz)cur] == NONE_BLOCK)
			{
				editor.body.push_all(decl.body[first:block.end - first]);
				// Preserve the last member's original implicit fallthrough destination.
				if (block_terminator_position(decl, block) == block.end && (sz)cur + 1 < block_count)
				{
					editor.body.push(editor.append({ .tag = ir::InstTag.JMP,
						.data.ref = cfg.blocks[(sz)cur + 1].label, .ty = value_interner::REF_VOID }));
				}
				break;
			}
			sz term = block_terminator_position(decl, block);
			editor.body.push_all(decl.body[first:term - first]);
			cur = next_of[(sz)cur];
		}
	}
	foreach (ref : editor.body)
	{
		@each_label_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
		{
			uint target_block = (usz)*slot < (usz)decl.instructions.len ? cfg.block_of_ref[(sz)*slot] : NONE_BLOCK;
			if (target_block != NONE_BLOCK && absorbed[(sz)target_block] &&
				cfg.blocks[(sz)target_block].label == *slot)
			{
				*slot = cfg.blocks[(sz)head_of[(sz)target_block]].label;
			}
		};
	}
	editor.commit();
	return true;
}

fn bool cfg_fold_terminators(ir::Decl* decl)
{
	bool changed = false;
	foreach (ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)ref];
		ir::Ref target = ir::NONE;
		if (inst.tag == ir::InstTag.BRANCH && inst.data.branch.then_label == inst.data.branch.else_label)
		{
			target = inst.data.branch.then_label;
		}
		if (inst.tag == ir::InstTag.SWITCH)
		{
			target = inst.data.switch_data.default_label;
			foreach (label : inst.data.switch_data.labels) if (label != target) { target = ir::NONE; break; }
		}
		if (target == ir::NONE) continue;
		*inst = { .tag = ir::InstTag.JMP, .data.ref = target, .ty = value_interner::REF_VOID };
		changed = true;
	}
	return changed;
}

<* Delete jump-only blocks and merge single-predecessor successors to a fixpoint. *>
fn bool simplify_cfg(ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
	// Address-taken labels and computed jumps require an extended CFG model.
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;
	}
	bool changed = false;
	while (true)
	{
		changed = cfg_fold_terminators(decl) || changed;
		Cfg cfg = build_cfg(decl, allocator);
		bool edited = cfg_bypass_empty_phi_free(decl, &cfg, allocator) ||
			cfg_bypass_empty_into_phis(decl, &cfg, allocator) ||
			cfg_merge_successors_phi_free(decl, &cfg, allocator);
		if (!edited) foreach (i, block : cfg.blocks)
		{
			if (!cfg.reachable[i]) continue;
			if (cfg_bypass_empty(decl, &cfg, (uint)i, allocator) || cfg_merge_successor(decl, &cfg, (uint)i, allocator))
			{
				edited = true;
				break;
			}
		}
		cfg.free();
		if (!edited) break;
		changed = true;
	}
	return changed;
}
