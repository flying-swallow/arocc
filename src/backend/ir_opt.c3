// IR optimization passes, analyses, and verifier.
module aro::backend::ir_opt;
import aro::primitive_value;
import aro::backend::ir, aro::value_interner, aro::code_gen_options, std::collections::list, std::collections::map;

excuse VERIFY_FAIL;

struct OptOptions
{
	code_gen_options::OptimizationLevel level;
	bool whole_program;
	<* When true, root all external declarations even if main exists; defaults to false. *>
	bool keep_external_definitions;
	bool verify;
}

<* Operand callbacks used by the IR visitors below. *>
macro @each_value_operand(ir::Inst* inst; @body(ir::Ref* slot))
{
	switch (inst.tag)
	{
		case LOAD:
		case BIT_NOT:
		case NEGATE:
		case FNEG:
		case TRUNC:
		case ZEXT:
		case SEXT:
		case FPTOSI:
		case FPTOUI:
		case SITOFP:
		case UITOFP:
		case FPEXT:
		case FPTRUNC:
		case STACK_RESTORE:
		case VA_START:
		case CLZ:
		case CTZ:
			@body(&inst.data.ref);
		case ATOMIC_LOAD:
			@body(&inst.data.atomic.ptr);
		case ATOMIC_STORE:
			@body(&inst.data.atomic.ptr);
			@body(&inst.data.atomic.val);
		case DYN_ALLOC:
			@body(&inst.data.dyn_alloc.size);
		case RET:
			if (inst.data.ref != ir::NONE) @body(&inst.data.ref);
		case RET_PAIR:
			@body(&inst.data.bin.lhs);
			@body(&inst.data.bin.rhs);
		case STORE:
		case BIT_OR:
		case BIT_XOR:
		case BIT_AND:
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
		case ADD:
		case SUB:
		case MUL:
		case SDIV:
		case UDIV:
		case SREM:
		case UREM:
		case FADD:
		case FSUB:
		case FMUL:
		case FDIV:
		case FCMP_OEQ:
		case FCMP_UNE:
		case FCMP_OLT:
		case FCMP_OLE:
		case FCMP_OGT:
		case FCMP_OGE:
			@body(&inst.data.bin.lhs);
			@body(&inst.data.bin.rhs);
		case BRANCH:
			@body(&inst.data.branch.cond);
		case SELECT:
			@body(&inst.data.branch.cond);
			@body(&inst.data.branch.then_label);
			@body(&inst.data.branch.else_label);
		case SWITCH:
			@body(&inst.data.switch_data.target);
		case CALL:
			@body(&inst.data.call.func);
			foreach (i, arg : inst.data.call.args)
			{
				@body(&inst.data.call.args[i]);
			}
		case CALL_HI:
			@body(&inst.data.ref);
		case PHI:
			foreach (i, input : inst.data.phi)
			{
				@body(&inst.data.phi[i].value);
			}
		case CONSTANT:
		case ARG:
		case SYMBOL:
		case LABEL:
		case LABEL_ADDR:
		case JMP:
		case JMP_VAL:
		case ALLOC:
		case STACK_SAVE:
		case FENCE:
			break;
	}
}

macro @each_label_operand(ir::Inst* inst; @body(ir::Ref* slot))
{
	switch (inst.tag)
	{
		case JMP:
			@body(&inst.data.ref);
		case BRANCH:
			@body(&inst.data.branch.then_label);
			@body(&inst.data.branch.else_label);
		case SWITCH:
			foreach (i, label : inst.data.switch_data.labels)
			{
				@body(&inst.data.switch_data.labels[i]);
			}
			@body(&inst.data.switch_data.default_label);
		case PHI:
			foreach (i, input : inst.data.phi)
			{
				@body(&inst.data.phi[i].label);
			}
		case CONSTANT:
		case ARG:
		case SYMBOL:
		case LABEL:
		case LABEL_ADDR:
		case JMP_VAL:
		case CALL:
		case CALL_HI:
		case ALLOC:
		case STORE:
		case DYN_ALLOC:
		case STACK_SAVE:
		case STACK_RESTORE:
		case VA_START:
		case BIT_OR:
		case BIT_XOR:
		case BIT_AND:
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
		case ADD:
		case SUB:
		case MUL:
		case SDIV:
		case UDIV:
		case SREM:
		case UREM:
		case FADD:
		case FSUB:
		case FMUL:
		case FDIV:
		case FCMP_OEQ:
		case FCMP_UNE:
		case FCMP_OLT:
		case FCMP_OLE:
		case FCMP_OGT:
		case FCMP_OGE:
		case RET:
		case RET_PAIR:
		case LOAD:
		case BIT_NOT:
		case NEGATE:
		case FNEG:
		case TRUNC:
		case ZEXT:
		case SEXT:
		case FPTOSI:
		case FPTOUI:
		case SITOFP:
		case UITOFP:
		case FPEXT:
		case FPTRUNC:
		case SELECT:
		case ATOMIC_LOAD:
		case ATOMIC_STORE:
		case FENCE:
		case CLZ:
		case CTZ:
			break;
	}
}

fn bool is_terminator(ir::InstTag tag)
{
	switch (tag)
	{
		case ir::InstTag.JMP:
		case ir::InstTag.BRANCH:
		case ir::InstTag.SWITCH:
		case ir::InstTag.RET:
		case ir::InstTag.RET_PAIR:
		case ir::InstTag.JMP_VAL:
			return true;
		default: return false;
	}
}

fn bool is_value_tag(ir::InstTag tag)
{
	switch (tag)
	{
		case ir::InstTag.LABEL:
		case ir::InstTag.STORE:
		case ir::InstTag.JMP:
		case ir::InstTag.BRANCH:
		case ir::InstTag.SWITCH:
		case ir::InstTag.RET:
		case ir::InstTag.RET_PAIR:
		case ir::InstTag.JMP_VAL:
		case ir::InstTag.VA_START:
		case ir::InstTag.ATOMIC_STORE:
		case ir::InstTag.FENCE:
			return false;
		default: return true;
	}
}

struct CfgBlock
{
	ir::Ref label;
	<* Body indices [start, end), including the LABEL at start. *>
	sz start;
	sz end;
	list::List{uint} preds;
	list::List{uint} succs;
	list::List{uint} frontier;
	list::List{uint} dom_children;
}

struct Cfg
{
	Allocator allocator;
	ir::Decl* decl;
	CfgBlock[] blocks;
	<* Instruction ref -> block index; uint::max means unplaced or pre-entry ARG. *>
	uint[] block_of_ref;
	uint[] rpo;
	bool[] reachable;
	<* Immediate dominator; the entry block is its own idom, unreachable blocks are NONE_BLOCK. *>
	uint[] idom;
	uint[] rpo_position;
}

const uint NONE_BLOCK = 0xFFFF_FFFF;

fn void Cfg.free(&self)
{
	foreach (&block : self.blocks)
	{
		block.preds.free();
		block.succs.free();
		block.frontier.free();
		block.dom_children.free();
	}
	if (self.blocks.len) alloc::free(self.allocator, self.blocks.ptr);
	if (self.block_of_ref.len) alloc::free(self.allocator, self.block_of_ref.ptr);
	if (self.rpo.len) alloc::free(self.allocator, self.rpo.ptr);
	if (self.reachable.len) alloc::free(self.allocator, self.reachable.ptr);
	if (self.idom.len) alloc::free(self.allocator, self.idom.ptr);
	if (self.rpo_position.len) alloc::free(self.allocator, self.rpo_position.ptr);
	*self = {};
}

struct DfsFrame
{
	uint block; sz next_succ;
}

<* `edge_from[to] == from` marks an edge already added. build_cfg adds every edge
   of one source block before moving on, so one mark per target dedupes in O(1)
   (a switch with thousands of labels would otherwise rescan its successor list). *>
fn void cfg_append_edge(Cfg* cfg, uint[] edge_from, uint from, uint to)
{
	if (edge_from[(sz)to] == from) return;
	edge_from[(sz)to] = from;
	cfg.blocks[(sz)from].succs.push(to);
	cfg.blocks[(sz)to].preds.push(from);
}

<* Return the first terminator in a block, or block.end for implicit fallthrough. *>
fn sz block_terminator_position(ir::Decl* decl, CfgBlock* block)
{
	for (sz pos = block.start + 1; pos < block.end; pos++)
	{
		ir::Ref ref = decl.body[pos];
		if ((usz)ref >= (usz)decl.instructions.len) continue;
		if (is_terminator(decl.instructions[(sz)ref].tag)) return pos;
	}
	return block.end;
}

<* The exclusive end of executable instructions, including a terminator if present. *>
fn sz block_executable_end(ir::Decl* decl, CfgBlock* block)
{
	sz terminator = block_terminator_position(decl, block);
	return terminator < block.end ? terminator + 1 : block.end;
}

<* Build block ranges, control-flow edges, reachability and entry-rooted RPO. *>
fn Cfg build_cfg(ir::Decl* decl, Allocator allocator)
{
	Cfg cfg = { .allocator = allocator, .decl = decl };
	usz inst_count = decl.instructions.len;
	usz body_len = decl.body.len;
	cfg.block_of_ref = alloc::new_array(allocator, uint, (sz)inst_count);
	for (usz i = 0; i < inst_count; i++) cfg.block_of_ref[i] = NONE_BLOCK;
	usz arg_end = 0;
	while (arg_end < body_len)
	{
		ir::Ref ref = decl.body[arg_end];
		if ((usz)ref >= inst_count || decl.instructions[(sz)ref].tag != ir::InstTag.ARG) break;
		arg_end++;
	}
	usz block_count = 0;
	for (usz i = arg_end; i < body_len; i++)
	{
		ir::Ref ref = decl.body[i];
		if ((usz)ref < inst_count && decl.instructions[(sz)ref].tag == ir::InstTag.LABEL) block_count++;
	}
	cfg.blocks = alloc::new_array(allocator, CfgBlock, (sz)block_count);
	for (usz i = 0; i < block_count; i++)
	{
		cfg.blocks[i].preds.init(allocator);
		cfg.blocks[i].succs.init(allocator);
		cfg.blocks[i].frontier.init(allocator);
		cfg.blocks[i].dom_children.init(allocator);
	}
	usz block_index = 0;
	for (usz i = arg_end; i < body_len; i++)
	{
		ir::Ref ref = decl.body[i];
		if ((usz)ref >= inst_count) continue;
		if (decl.instructions[(sz)ref].tag == ir::InstTag.LABEL)
		{
			if (block_index > 0) cfg.blocks[block_index - 1].end = (sz)i;
			CfgBlock* block = &cfg.blocks[block_index];
			block.label = ref;
			block.start = (sz)i;
			block.end = (sz)body_len;
			cfg.block_of_ref[(sz)ref] = (uint)block_index;
			block_index++;
		}
		else if (block_index > 0)
		{
			cfg.block_of_ref[(sz)ref] = (uint)(block_index - 1);
		}
	}
	// Resolve control-flow edges only after all label refs are indexed. The first
	// terminator ends execution; later instructions in the same range are dead.
	uint[] edge_from = alloc::new_array(allocator, uint, (sz)block_count);
	defer if (block_count) alloc::free(allocator, edge_from.ptr);
	for (usz i = 0; i < block_count; i++) edge_from[i] = NONE_BLOCK;
	foreach (i, &block : cfg.blocks)
	{
		sz terminator_pos = block_terminator_position(decl, block);
		if (terminator_pos == block.end)
		{
			if (i + 1 < cfg.blocks.len) cfg_append_edge(&cfg, edge_from, (uint)i, (uint)(i + 1));
			continue;
		}
		ir::Ref terminator_ref = decl.body[terminator_pos];
		if ((usz)terminator_ref >= inst_count) continue;
		ir::Inst* inst = &decl.instructions[(sz)terminator_ref];
		switch (inst.tag)
		{
			case ir::InstTag.JMP:
				if ((usz)inst.data.ref < inst_count && cfg.block_of_ref[(sz)inst.data.ref] != NONE_BLOCK)
				{
					cfg_append_edge(&cfg, edge_from, (uint)i, cfg.block_of_ref[(sz)inst.data.ref]);
				}
			case ir::InstTag.BRANCH:
				ir::Ref then_ref = inst.data.branch.then_label;
				ir::Ref else_ref = inst.data.branch.else_label;
				if ((usz)then_ref < inst_count && cfg.block_of_ref[(sz)then_ref] != NONE_BLOCK)
				{
					cfg_append_edge(&cfg, edge_from, (uint)i, cfg.block_of_ref[(sz)then_ref]);
				}
				if ((usz)else_ref < inst_count && cfg.block_of_ref[(sz)else_ref] != NONE_BLOCK)
				{
					cfg_append_edge(&cfg, edge_from, (uint)i, cfg.block_of_ref[(sz)else_ref]);
				}
			case ir::InstTag.SWITCH:
				foreach (label : inst.data.switch_data.labels)
				{
					if ((usz)label < inst_count && cfg.block_of_ref[(sz)label] != NONE_BLOCK)
					{
						cfg_append_edge(&cfg, edge_from, (uint)i, cfg.block_of_ref[(sz)label]);
					}
				}
				ir::Ref default_ref = inst.data.switch_data.default_label;
				if ((usz)default_ref < inst_count && cfg.block_of_ref[(sz)default_ref] != NONE_BLOCK)
				{
					cfg_append_edge(&cfg, edge_from, (uint)i, cfg.block_of_ref[(sz)default_ref]);
				}
			default: break;
		}
	}
	cfg.reachable = alloc::new_array(allocator, bool, (sz)block_count);
	if (block_count)
	{
		bool[] visited = alloc::new_array(allocator, bool, (sz)block_count);
		defer alloc::free(allocator, visited.ptr);
		for (usz i = 0; i < block_count; i++)
		{
			visited[i] = false; cfg.reachable[i] = false;
		}
		list::List{DfsFrame} stack;
		stack.init(allocator);
		defer stack.free();
		list::List{uint} postorder;
		postorder.init(allocator);
		defer postorder.free();
		visited[0] = true;
		cfg.reachable[0] = true;
		stack.push(
		{
			.block = 0, .next_succ = 0
		}
		);
		while (stack.len())
		{
			DfsFrame* frame = &stack.entries[stack.len() - 1];
			list::List{uint} * succs = &cfg.blocks[(sz)frame.block].succs;
			if (frame.next_succ < succs.len())
			{
				uint child = succs.entries[frame.next_succ];
				frame.next_succ++;
				if (!visited[(sz)child])
				{
					visited[(sz)child] = true;
					cfg.reachable[(sz)child] = true;
					stack.push(
					{
						.block = child, .next_succ = 0
					}
					);
				}
				continue;
			}
			postorder.push(frame.block);
			stack.pop()!!;
		}
		cfg.rpo = alloc::new_array(allocator, uint, postorder.len());
		for (sz i = 0; i < postorder.len(); i++) cfg.rpo[i] = postorder.entries[postorder.len() - 1 - i];
	}
	else
	{
		cfg.rpo = alloc::new_array(allocator, uint, 0);
	}
	return cfg;
}

<* Cooper-Harvey-Kennedy iterative immediate dominators in reverse postorder. *>
fn void Cfg.compute_dominators(&self)
{
	if (self.idom.len) alloc::free(self.allocator, self.idom.ptr);
	if (self.rpo_position.len) alloc::free(self.allocator, self.rpo_position.ptr);
	uint n = (uint)self.blocks.len;
	self.idom = alloc::new_array(self.allocator, uint, n);
	self.rpo_position = alloc::new_array(self.allocator, uint, n);
	for (uint i = 0; i < n; i++)
	{
		self.idom[(sz)i] = NONE_BLOCK;
		self.rpo_position[(sz)i] = NONE_BLOCK;
		self.blocks[(sz)i].frontier.clear();
		self.blocks[(sz)i].dom_children.clear();
	}
	if (!self.rpo.len) return;
	foreach (i, block : self.rpo) self.rpo_position[(sz)block] = (uint)i;
	uint entry = self.rpo[0];
	self.idom[(sz)entry] = entry;
	bool changed = true;
	while (changed)
	{
		changed = false;
		for (usz ri = 1; ri < self.rpo.len; ri++)
		{
			uint block_index = self.rpo[ri];
			CfgBlock* block = &self.blocks[(sz)block_index];
			uint new_idom = NONE_BLOCK;
			foreach (pred : block.preds)
			{
				if (!self.reachable[(sz)pred] || self.idom[(sz)pred] == NONE_BLOCK) continue;
				if (new_idom == NONE_BLOCK)
				{
					new_idom = pred;
				}
				else
				{
					new_idom = cfg_intersect(self, new_idom, pred);
				}
			}
			if (new_idom != NONE_BLOCK && self.idom[(sz)block_index] != new_idom)
			{
				self.idom[(sz)block_index] = new_idom;
				changed = true;
			}
		}
	}
	for (uint i = 0; i < n; i++)
	{
		if (!self.reachable[(sz)i] || i == entry) continue;
		uint parent = self.idom[(sz)i];
		if (parent != NONE_BLOCK) self.blocks[(sz)parent].dom_children.push(i);
	}
}

fn uint cfg_intersect(Cfg* cfg, uint a, uint b)
{
	while (a != b)
	{
		while (cfg.rpo_position[(sz)a] > cfg.rpo_position[(sz)b]) a = cfg.idom[(sz)a];
		while (cfg.rpo_position[(sz)b] > cfg.rpo_position[(sz)a]) b = cfg.idom[(sz)b];
	}
	return a;
}

fn bool Cfg.dominates(&self, uint a, uint b)
{
	if (a >= self.blocks.len || b >= self.blocks.len || !self.idom.len) return false;
	if (!self.reachable[(sz)a] || !self.reachable[(sz)b]) return false;
	uint cursor = b;
	while (true)
	{
		if (cursor == a) return true;
		uint parent = self.idom[(sz)cursor];
		if (parent == NONE_BLOCK || parent == cursor) return false;
		cursor = parent;
	}
}

<* Compute dominance frontiers from the idom tree and CFG edges. *>
fn void Cfg.compute_frontiers(&self)
{
	for (usz i = 0; i < self.blocks.len; i++) self.blocks[i].frontier.clear();
	if (!self.idom.len) self.compute_dominators();
	foreach (target_index, target : self.blocks)
	{
		if (!self.reachable[target_index]) continue;
		foreach (pred : target.preds)
		{
			if (!self.reachable[(sz)pred]) continue;
			uint runner = pred;
			while (true)
			{
				bool add = target_index == self.rpo[0] || runner != self.idom[target_index];
				if (add)
				{
					bool exists = false;
					foreach (old : self.blocks[(sz)runner].frontier) if (old == (uint)target_index) exists = true;
					if (!exists) self.blocks[(sz)runner].frontier.push((uint)target_index);
				}
				uint parent = self.idom[(sz)runner];
				if (parent == NONE_BLOCK || parent == runner) break;
				if (target_index != self.rpo[0] && runner == self.idom[target_index]) break;
				runner = parent;
			}
		}
	}
}

struct Uses
{
	Allocator allocator;
	list::List{ir::Ref}[] users;
}

fn void Uses.free(&self)
{
	foreach (&users : self.users) users.free();
	if (self.users.len) alloc::free(self.allocator, self.users.ptr);
	*self = {};
}

<* Build per-reference user lists over placed instructions (one entry per operand use). *>
fn Uses compute_uses(ir::Decl* decl, Allocator allocator)
{
	Uses uses = { .allocator = allocator };
	uses.users = alloc::new_array(allocator, list::List{ir::Ref}, decl.instructions.len);
	foreach (&user : uses.users) user.init(allocator);
	foreach (user_ref : decl.body)
	{
		if ((usz)user_ref >= (usz)decl.instructions.len) continue;
		ir::Inst* inst = &decl.instructions[(sz)user_ref];
		@each_value_operand(inst; ir::Ref* slot)
		{
			if (*slot != ir::NONE && (usz)*slot < (usz)decl.instructions.len)
			{
				uses.users[(sz)*slot].push(user_ref);
			}
		};
	}
	return uses;
}

<* Replace each value use in the body. Label slots are intentionally untouched. *>
fn void replace_all_uses(ir::Decl* decl, ir::Ref old, ir::Ref new)
{
	foreach (user_ref : decl.body)
	{
		if ((usz)user_ref >= (usz)decl.instructions.len) continue;
		ir::Inst* inst = &decl.instructions[(sz)user_ref];
		@each_value_operand(inst; ir::Ref* slot)
		{
			if (*slot == old) * slot = new;
		};
	}
}

alias BodyPredicate = fn bool(ir::Ref ref, void* context);

struct DeclEditor
{
	ir::Decl* decl;
	Allocator allocator;
	list::List{ir::Inst} insts;
	list::List{ir::Ref} body;
}

fn bool inline_body_uses_ref(DeclEditor* editor, ir::Ref ref)
{
	foreach (body_ref : editor.body)
	{
		if ((usz)body_ref >= (usz)editor.insts.len()) continue;
		ir::Inst* inst = &editor.insts.entries[(sz)body_ref];
		bool found = false;
		@each_value_operand(inst; ir::Ref* slot)
		{
			if (*slot == ref) found = true;
		};
		if (found) return true;
	}
	return false;
}

<* Retire a call-target symbol only after no live body instruction still uses it. *>
fn void inline_retire_unused_call_symbol(DeclEditor* editor, ir::Ref symbol_ref)
{
	if ((usz)symbol_ref >= (usz)editor.insts.len()) return;
	ir::Inst* symbol = &editor.insts.entries[(sz)symbol_ref];
	if (symbol.tag != ir::InstTag.SYMBOL || inline_body_uses_ref(editor, symbol_ref)) return;
	// Instructions stay indexed after inlining; ARG is a harmless unplaced tombstone.
	symbol.tag = ir::InstTag.ARG;
}

fn void DeclEditor.begin(&self, ir::Decl* decl, Allocator allocator)
{
	*self = { .decl = decl, .allocator = allocator };
	self.insts.init(allocator);
	self.insts.push_all(decl.instructions);
	self.body.init(allocator);
	self.body.push_all(decl.body);
}

fn void DeclEditor.free(&self)
{
	self.insts.free();
	self.body.free();
	*self = {};
}

fn ir::Inst copy_inst_payload(ir::Decl* decl, ir::Inst inst)
{
	switch (inst.tag)
	{
		case ir::InstTag.LABEL:
		case ir::InstTag.SYMBOL:
			inst.data.label = inst.data.label.copy(&decl.arena);
		case ir::InstTag.PHI:
			ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, inst.data.phi.len);
			inputs[..] = inst.data.phi[..];
			inst.data.phi = inputs;
		case ir::InstTag.CALL:
			ir::Ref[] args = alloc::new_array(&decl.arena, ir::Ref, inst.data.call.args.len);
			bool[] stack_only = alloc::new_array(&decl.arena, bool, inst.data.call.stack_only.len);
			uint[] memory_copy_bytes = alloc::new_array(&decl.arena, uint, inst.data.call.memory_copy_bytes.len);
			args[..] = inst.data.call.args[..];
			stack_only[..] = inst.data.call.stack_only[..];
			memory_copy_bytes[..] = inst.data.call.memory_copy_bytes[..];
			inst.data.call.args = args;
			inst.data.call.stack_only = stack_only;
			inst.data.call.memory_copy_bytes = memory_copy_bytes;
		case ir::InstTag.SWITCH:
			value_interner::InternerRef[] values = alloc::new_array(&decl.arena, value_interner::InternerRef, inst.data.switch_data.values.len);
			ir::Ref[] labels = alloc::new_array(&decl.arena, ir::Ref, inst.data.switch_data.labels.len);
			values[..] = inst.data.switch_data.values[..];
			labels[..] = inst.data.switch_data.labels[..];
			inst.data.switch_data.values = values;
			inst.data.switch_data.labels = labels;
		default: break;
	}
	return inst;
}

fn ir::Ref DeclEditor.append(&self, ir::Inst inst)
{
	ir::Ref ref = (ir::Ref)self.insts.len();
	self.insts.push(copy_inst_payload(self.decl, inst));
	return ref;
}

fn ir::Ref DeclEditor.add_constant(&self, value_interner::InternerRef value, value_interner::InternerRef ty)
=> self.append(
{
	.tag = ir::InstTag.CONSTANT, .data.constant = value, .ty = ty
}

);

fn void DeclEditor.insert_body(&self, sz at, ir::Ref ref)
{
	assert(at >= 0 && at <= self.body.len());
	self.body.push(ref);
	for (sz i = self.body.len() - 1; i > at; i--) self.body.entries[i] = self.body.entries[i - 1];
	self.body.entries[at] = ref;
}

<* Remove selected body placements; instructions remain as tombstones and refs stay stable. *>
fn void DeclEditor.remove_body_where(&self, BodyPredicate predicate, void* context)
{
	sz write = 0;
	for (sz read = 0; read < self.body.len(); read++)
	{
		ir::Ref ref = self.body.entries[read];
		if (predicate(ref, context)) continue;
		self.body.entries[write++] = ref;
	}
	while (self.body.len() > write)
	{
		self.body.pop()!!;
	}
}

fn ir::Ref DeclEditor.new_label(&self, String name)
=> self.append(
{
	.tag = ir::InstTag.LABEL, .data.label = name, .ty = value_interner::REF_VOID
}

);

fn void DeclEditor.commit(&self)
{
	ir::Inst[] instructions = alloc::new_array(self.decl.allocator, ir::Inst, self.insts.len());
	if (self.insts.len()) instructions[..] = self.insts.array_view()[..];
	ir::Ref[] body = alloc::new_array(self.decl.allocator, ir::Ref, self.body.len());
	if (self.body.len()) body[..] = self.body.array_view()[..];
	if (self.decl.instructions.len) alloc::free(self.decl.allocator, self.decl.instructions.ptr);
	if (self.decl.body.len) alloc::free(self.decl.allocator, self.decl.body.ptr);
	self.decl.instructions = instructions;
	self.decl.body = body;
	self.insts.free();
	self.body.free();
	self.decl = null;
}

fn void remove_decl(ir::Ir* graph, usz index)
{
	assert((sz)index < graph.decls.len());
	graph.decls.entries[(sz)index].free();
	graph.decls.remove_at((sz)index);
}

fn void mark_decl_symbol(HashMap{String, uint} * decl_indices, bool[] reachable,
	list::List{uint} * pending, String symbol)
{
	if (try index = decl_indices.get(symbol))
	{
		if (reachable[(sz)index]) return;
		reachable[(sz)index] = true;
		pending.push(index);
	}
}

<* Remove declarations not reachable from roots; retain all external declarations when they may be used outside this IR. *>
fn void eliminate_dead_declarations(ir::Ir* graph, bool whole_program, bool keep_external_definitions)
{
	usz decl_count = (usz)graph.decls.len();
	if (decl_count == 0) return;
	bool[] reachable = alloc::new_array(graph.allocator, bool, (sz)decl_count);
	defer alloc::free(graph.allocator, reachable.ptr);
	for (usz i = 0; i < decl_count; i++) reachable[i] = false;
	HashMap{String, uint} decl_indices;
	decl_indices.init(graph.allocator);
	defer decl_indices.free();
	foreach (i, decl : graph.decls)
	{
		decl_indices.set(decl.name, (uint)i);
	}
	list::List{uint} pending;
	pending.init(graph.allocator);
	defer pending.free();

	bool has_main = false;
	foreach (decl : graph.decls)
	{
		if (decl.kind == ir::DeclKind.FUNCTION && decl.name == "main") has_main = true;
	}
	if (whole_program && has_main && !keep_external_definitions)
	{
		mark_decl_symbol(&decl_indices, reachable, &pending, "main");
	}
	else
	{
		foreach (i, decl : graph.decls)
		{
			if (decl.linkage != ir::Linkage.EXTERNAL) continue;
			reachable[(sz)i] = true;
			pending.push((uint)i);
		}
	}

	// Follow references from each newly reached declaration.
	while (pending.len())
	{
		uint index = pending.pop()!!;
		ir::Decl* decl = &graph.decls.entries[(sz)index];
		if (decl.kind == ir::DeclKind.FUNCTION)
		{
			// Include all instructions, including unplaced tombstones.
			foreach (inst : decl.instructions)
			{
				if (inst.tag != ir::InstTag.SYMBOL) continue;
				mark_decl_symbol(&decl_indices, reachable, &pending, inst.data.label);
			}
		}
		else
		{
			foreach (reloc : decl.global.relocs)
			{
				mark_decl_symbol(&decl_indices, reachable, &pending, reloc.symbol);
			}
		}
	}

	for (usz i = (usz)graph.decls.len(); i > 0; i--)
	{
		usz index = i - 1;
		if (!reachable[index]) remove_decl(graph, index);
	}
}

fn void dead_function_elim(ir::Ir* graph, bool whole_program, bool keep_external_definitions)
=> eliminate_dead_declarations(graph, whole_program, keep_external_definitions);

struct BodyRemovalContext
{
	bool[] remove;
}

fn bool body_ref_marked_for_removal(ir::Ref ref, void* context)
{
	BodyRemovalContext* removals = (BodyRemovalContext*)context;
	return (usz)ref < removals.remove.len && removals.remove[(sz)ref];
}

<* Remove unreachable block placements and simplify PHIs whose predecessors shrink. *>
fn bool remove_unreachable_blocks(ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
	Cfg cfg = build_cfg(decl, allocator);
	defer cfg.free();
	if (cfg.blocks.len == 0) return false;

	bool[] remove = alloc::new_array(allocator, bool, (sz)decl.instructions.len);
	defer alloc::free(allocator, remove.ptr);
	for (usz i = 0; i < (usz)decl.instructions.len; i++) remove[i] = false;
	bool changed = false;
	foreach (ref : decl.body)
	{
		if ((usz)ref >= (usz)cfg.block_of_ref.len) continue;
		uint block = cfg.block_of_ref[(sz)ref];
		if (block != NONE_BLOCK && !cfg.reachable[(sz)block])
		{
			remove[(sz)ref] = true;
			changed = true;
		}
	}
	foreach (block_index, block : cfg.blocks)
	{
		if (!cfg.reachable[block_index]) continue;
		sz terminator_pos = block_terminator_position(decl, &block);
		if (terminator_pos == block.end) continue;
		// Code generation can append a jump after a return, break, or continue.
		// Those placements are unreachable and must not affect use counts or CFG
		// analyses in later passes.
		for (sz pos = terminator_pos + 1; pos < block.end; pos++)
		{
			ir::Ref ref = decl.body[pos];
			if ((usz)ref >= (usz)remove.len || remove[(sz)ref]) continue;
			remove[(sz)ref] = true;
			changed = true;
		}
	}

	// Trim only PHIs in reachable blocks. Keep the builder's input slice intact
	// by replacing it with a fresh array owned by the declaration arena.
	foreach (block_index, block : cfg.blocks)
	{
		if (!cfg.reachable[block_index]) continue;
		sz executable_end = block_executable_end(decl, &block);
		for (sz pos = block.start + 1; pos < executable_end; pos++)
		{
			ir::Ref phi_ref = decl.body[pos];
			if ((usz)phi_ref >= (usz)decl.instructions.len) continue;
			ir::Inst* phi = &decl.instructions[(sz)phi_ref];
			if (phi.tag != ir::InstTag.PHI) continue;

			usz keep_count = 0;
			foreach (input : phi.data.phi)
			{
				if ((usz)input.label < (usz)cfg.block_of_ref.len)
				{
					uint pred = cfg.block_of_ref[(sz)input.label];
					if (pred != NONE_BLOCK && !cfg.reachable[(sz)pred]) continue;
				}
				keep_count++;
			}
			if (keep_count != (usz)phi.data.phi.len)
			{
				ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, (sz)keep_count);
				sz write = 0;
				foreach (input : phi.data.phi)
				{
					bool unreachable_pred = false;
					if ((usz)input.label < (usz)cfg.block_of_ref.len)
					{
						uint pred = cfg.block_of_ref[(sz)input.label];
						unreachable_pred = pred != NONE_BLOCK && !cfg.reachable[(sz)pred];
					}
					if (unreachable_pred) continue;
					inputs[write++] = input;
				}
				phi.data.phi = inputs;
				changed = true;
			}

			if (phi.data.phi.len == 1)
			{
				ir::Ref input = phi.data.phi[0].value;
				if (input != phi_ref)
				{
					replace_all_uses(decl, phi_ref, input);
					remove[(sz)phi_ref] = true;
					changed = true;
				}
			}
		}
	}

	if (!changed) return false;
	DeclEditor editor;
	editor.begin(decl, allocator);
	BodyRemovalContext context = { .remove = remove };
	editor.remove_body_where(&body_ref_marked_for_removal, (void*)&context);
	editor.commit();
	return true;
}

fn void editor_replace_all_uses(DeclEditor* editor, ir::Ref old, ir::Ref replacement)
{
	foreach (user_ref : editor.body)
	{
		if ((usz)user_ref >= (usz)editor.insts.len()) continue;
		ir::Inst* inst = &editor.insts.entries[(sz)user_ref];
		@each_value_operand(inst; ir::Ref* slot)
		{
			if (*slot == old) * slot = replacement;
		};
	}
}

struct Mem2RegRenameContext
{
	DeclEditor* editor;
	Cfg* cfg;
	ir::Ref alloc_ref;
	value_interner::InternerRef access_type;
	ir::Ref zero_ref;
	ir::Ref[] phi_for_block;
	bool[] remove;
}

<* Lazily materialize the zero value used for paths that read before a store. *>
fn ir::Ref mem2reg_initial_zero(Mem2RegRenameContext* context)
{
	if (context.zero_ref == ir::NONE)
	{
		context.zero_ref = context.editor.add_constant(value_interner::REF_ZERO, context.access_type);
	}
	return context.zero_ref;
}

fn bool mem2reg_fill_phi_input(Mem2RegRenameContext* context, uint successor, uint predecessor, ir::Ref value)
{
	ir::Ref phi_ref = context.phi_for_block[(sz)successor];
	if (phi_ref == ir::NONE) return true;
	if (value == ir::NONE) value = mem2reg_initial_zero(context);
	ir::Inst* phi = &context.editor.insts.entries[(sz)phi_ref];
	ir::Ref pred_label = context.cfg.blocks[(sz)predecessor].label;
	foreach (i, input : phi.data.phi)
	{
		if (input.label != pred_label) continue;
		phi.data.phi[i].value = value;
		return true;
	}
	return false;
}

<* Rename one variable down the dominator tree, carrying each block's current value. *>
fn bool mem2reg_rename_block(Mem2RegRenameContext* context, uint block_index, ir::Ref current)
{
	CfgBlock* block = &context.cfg.blocks[(sz)block_index];
	ir::Ref phi_ref = context.phi_for_block[(sz)block_index];
	if (phi_ref != ir::NONE) current = phi_ref;
	// CFG ranges refer to the original body; editor insertions only add PHIs.
	sz executable_end = block_executable_end(context.editor.decl, block);
	for (sz pos = block.start + 1; pos < executable_end; pos++)
	{
		ir::Ref ref = context.editor.decl.body[pos];
		if ((usz)ref >= (usz)context.editor.insts.len()) continue;
		ir::Inst* inst = &context.editor.insts.entries[(sz)ref];
		if (inst.tag == ir::InstTag.LOAD && inst.data.ref == context.alloc_ref)
		{
			if (current == ir::NONE) current = mem2reg_initial_zero(context);
			editor_replace_all_uses(context.editor, ref, current);
			context.remove[(sz)ref] = true;
		}
		else if (inst.tag == ir::InstTag.STORE && inst.data.bin.lhs == context.alloc_ref)
		{
			current = inst.data.bin.rhs;
			context.remove[(sz)ref] = true;
		}
	}
	foreach (successor : block.succs)
	{
		if (!mem2reg_fill_phi_input(context, successor, block_index, current)) return false;
	}
	foreach (child : block.dom_children)
	{
		if (!mem2reg_rename_block(context, child, current)) return false;
	}
	return true;
}

<* Collapse PHIs that have one distinct incoming value, ignoring self edges. *>
fn bool editor_cleanup_trivial_phis(DeclEditor* editor, bool[] remove)
{
	bool any_changed = false;
	bool changed = true;
	while (changed)
	{
		changed = false;
		foreach (ref : editor.body)
		{
			if ((usz)ref >= (usz)editor.insts.len() || remove[(sz)ref]) continue;
			ir::Inst* inst = &editor.insts.entries[(sz)ref];
			if (inst.tag != ir::InstTag.PHI) continue;
			ir::Ref candidate = ir::NONE;
			bool conflict = false;
			foreach (input : inst.data.phi)
			{
				if (input.value == ref) continue;
				if (candidate == ir::NONE)
				{
					candidate = input.value;
				}
				else if (candidate != input.value)
				{
					conflict = true;
					break;
				}
			}
			if (candidate == ir::NONE || conflict) continue;
			editor_replace_all_uses(editor, ref, candidate);
			remove[(sz)ref] = true;
			changed = true;
			any_changed = true;
		}
	}
	return any_changed;
}

<* Remove mem2reg PHIs that are not reachable from a non-mem2reg-PHI use. *>
fn bool editor_cleanup_unused_mem2reg_phis(DeclEditor* editor, ir::Ref[] phi_for_block, bool[] remove)
{
	bool[] is_mem2reg_phi = alloc::new_array(editor.allocator, bool, (sz)editor.insts.len());
	defer alloc::free(editor.allocator, is_mem2reg_phi.ptr);
	bool[] live = alloc::new_array(editor.allocator, bool, (sz)editor.insts.len());
	defer alloc::free(editor.allocator, live.ptr);
	for (sz i = 0; i < editor.insts.len(); i++)
	{
		is_mem2reg_phi[i] = false;
		live[i] = false;
	}
	foreach (phi_ref : phi_for_block)
	{
		if (phi_ref != ir::NONE && (usz)phi_ref < (usz)editor.insts.len() && !remove[(sz)phi_ref])
		{
			is_mem2reg_phi[(sz)phi_ref] = true;
		}
	}

	// A use outside this PHI set is a root: it is observable independently
	// of whether any of the inserted PHIs that feed it are themselves used.
	foreach (user_ref : editor.body)
	{
		if ((usz)user_ref >= (usz)editor.insts.len() || remove[(sz)user_ref] || is_mem2reg_phi[(sz)user_ref]) continue;
		ir::Inst* user = &editor.insts.entries[(sz)user_ref];
		@each_value_operand(user; ir::Ref* slot)
		{
			if (*slot != ir::NONE && (usz)*slot < (usz)editor.insts.len() &&
			is_mem2reg_phi[(sz)*slot] && !remove[(sz)*slot])
			{
				live[(sz)*slot] = true;
			}
		};
	}

	// Keep each PHI dependency of a live PHI. This fixed point preserves live
	// dependency cycles while leaving unrooted cycles dead.
	bool changed = true;
	while (changed)
	{
		changed = false;
		foreach (phi_ref : phi_for_block)
		{
			if (phi_ref == ir::NONE || (usz)phi_ref >= (usz)editor.insts.len() ||
			remove[(sz)phi_ref] || !live[(sz)phi_ref]) continue;
			ir::Inst* phi = &editor.insts.entries[(sz)phi_ref];
			@each_value_operand(phi; ir::Ref* slot)
			{
				if (*slot != ir::NONE && (usz)*slot < (usz)editor.insts.len() &&
				is_mem2reg_phi[(sz)*slot] && !remove[(sz)*slot] && !live[(sz)*slot])
				{
					live[(sz)*slot] = true;
					changed = true;
				}
			};
		}
	}

	bool any_changed = false;
	foreach (phi_ref : phi_for_block)
	{
		if (phi_ref == ir::NONE || (usz)phi_ref >= (usz)editor.insts.len() || remove[(sz)phi_ref] || live[(sz)phi_ref]) continue;
		remove[(sz)phi_ref] = true;
		any_changed = true;
	}
	return any_changed;
}

<* Promote one non-escaping scalar-like ALLOC; failed rename leaves the declaration untouched. *>
fn bool promote_alloca(ir::Ir* ir, ir::Decl* decl, ir::Ref alloc_ref, Allocator allocator)
{
	if ((usz)alloc_ref >= (usz)decl.instructions.len || decl.instructions[(sz)alloc_ref].tag != ir::InstTag.ALLOC) return false;
	if (decl.instructions[(sz)alloc_ref].data.alloc.is_volatile) return false;
	Cfg cfg = build_cfg(decl, allocator);
	defer cfg.free();
	if (cfg.blocks.len == 0 || cfg.block_of_ref[(sz)alloc_ref] == NONE_BLOCK) return false;
	cfg.compute_dominators();
	cfg.compute_frontiers();
	uint alloc_block = cfg.block_of_ref[(sz)alloc_ref];
	if (!cfg.reachable[(sz)alloc_block]) return false;

	Uses uses = compute_uses(decl, allocator);
	defer uses.free();
	bool has_load = false;
	bool has_store = false;
	bool has_access_type = false;
	value_interner::InternerRef access_type = value_interner::REF_VOID;
	foreach (user_ref : uses.users[(sz)alloc_ref])
	{
		if ((usz)user_ref >= (usz)decl.instructions.len) return false;
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		value_interner::InternerRef user_type;
		if (user.tag == ir::InstTag.LOAD && user.data.ref == alloc_ref)
		{
			has_load = true;
			user_type = user.ty;
		}
		else if (user.tag == ir::InstTag.STORE && user.data.bin.lhs == alloc_ref && user.data.bin.rhs != alloc_ref)
		{
			if (!valid_ref(decl, user.data.bin.rhs)) return false;
			has_store = true;
			user_type = decl.instructions[(sz)user.data.bin.rhs].ty;
		}
		else
		{
			// The address escapes or participates in an unsupported memory use.
			return false;
		}
		if (!has_access_type)
		{
			access_type = user_type;
			has_access_type = true;
		}
		else if (access_type != user_type)
		{
			return false;
		}
	}
	if (!has_access_type) return false;
	primitive_value::PrimitiveValue access_key = ir.interner.get(access_type);
	uint expected_size;
	switch (access_key.tag)
	{
		case primitive_value::PrimitiveType.INT_TY:
		case primitive_value::PrimitiveType.FLOAT_TY:
			if (access_key.ty_bits == 0) return false;
			expected_size = ((uint)access_key.ty_bits + 7) / 8;
		case primitive_value::PrimitiveType.PTR_TY:
			expected_size = 8;
		default:
			return false;
	}
	if (decl.instructions[(sz)alloc_ref].data.alloc.size != expected_size) return false;
	if (!has_load)
	{
		if (!has_store) return false;
		// Stores to an unobserved local allocation have no externally visible effect.
		DeclEditor editor;
		editor.begin(decl, allocator);
		bool[] remove = alloc::new_array(allocator, bool, (sz)editor.insts.len());
		defer alloc::free(allocator, remove.ptr);
		for (sz i = 0; i < editor.insts.len(); i++) remove[i] = false;
		remove[(sz)alloc_ref] = true;
		foreach (user_ref : uses.users[(sz)alloc_ref]) remove[(sz)user_ref] = true;
		BodyRemovalContext context = { .remove = remove };
		editor.remove_body_where(&body_ref_marked_for_removal, (void*)&context);
		editor.commit();
		return true;
	}

	bool[] def_blocks = alloc::new_array(allocator, bool, (sz)cfg.blocks.len);
	defer alloc::free(allocator, def_blocks.ptr);
	bool[] phi_sites = alloc::new_array(allocator, bool, (sz)cfg.blocks.len);
	defer alloc::free(allocator, phi_sites.ptr);
	for (usz i = 0; i < cfg.blocks.len; i++)
	{
		def_blocks[i] = false; phi_sites[i] = false;
	}
	foreach (user_ref : uses.users[(sz)alloc_ref])
	{
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		if (user.tag != ir::InstTag.STORE || user.data.bin.lhs != alloc_ref) continue;
		uint block = cfg.block_of_ref[(sz)user_ref];
		if (block == NONE_BLOCK || !cfg.reachable[(sz)block]) return false;
		def_blocks[(sz)block] = true;
	}
	list::List{uint} worklist;
	worklist.init(allocator);
	defer worklist.free();
	foreach (block : cfg.rpo) if (def_blocks[(sz)block]) worklist.push(block);
	while (worklist.len())
	{
		uint block = worklist.pop()!!;
		foreach (frontier : cfg.blocks[(sz)block].frontier)
		{
			if (phi_sites[(sz)frontier]) continue;
			// Only reachable predecessors participate after unreachable pruning.
			uint reachable_preds = 0;
			foreach (pred : cfg.blocks[(sz)frontier].preds) if (cfg.reachable[(sz)pred]) reachable_preds++;
			if (reachable_preds < 2) continue;
			phi_sites[(sz)frontier] = true;
			if (!def_blocks[(sz)frontier]) worklist.push(frontier);
		}
	}

	DeclEditor editor;
	editor.begin(decl, allocator);
	ir::Ref[] phi_for_block = alloc::new_array(allocator, ir::Ref, (sz)cfg.blocks.len);
	defer alloc::free(allocator, phi_for_block.ptr);
	for (usz i = 0; i < cfg.blocks.len; i++) phi_for_block[i] = ir::NONE;
	foreach (block_index, has_phi : phi_sites)
	{
		if (!has_phi) continue;
		usz input_count = 0;
		foreach (pred : cfg.blocks[block_index].preds) if (cfg.reachable[(sz)pred]) input_count++;
		ir::PhiInput[] inputs = alloc::new_array(allocator, ir::PhiInput, (sz)input_count);
		sz input_index = 0;
		foreach (pred : cfg.blocks[block_index].preds)
		{
			if (!cfg.reachable[(sz)pred]) continue;
			inputs[input_index++] = { .label = cfg.blocks[(sz)pred].label, .value = ir::NONE };
		}
		ir::Ref phi_ref = editor.append(
		{
			.tag = ir::InstTag.PHI, .data.phi = inputs, .ty = access_type
		}
		);
		alloc::free(allocator, inputs.ptr);
		phi_for_block[block_index] = phi_ref;
		sz label_pos = 0;
		while (label_pos < editor.body.len() && editor.body.entries[label_pos] != cfg.blocks[block_index].label) label_pos++;
		if (label_pos == editor.body.len())
		{
			editor.free();
			return false;
		}
		sz insert_at = label_pos + 1;
		while (insert_at < editor.body.len())
		{
			ir::Ref next = editor.body.entries[insert_at];
			if ((usz)next >= (usz)editor.insts.len() || editor.insts.entries[(sz)next].tag != ir::InstTag.PHI) break;
			insert_at++;
		}
		editor.insert_body(insert_at, phi_ref);
	}

	bool[] remove = alloc::new_array(allocator, bool, (sz)editor.insts.len());
	defer alloc::free(allocator, remove.ptr);
	for (sz i = 0; i < editor.insts.len(); i++) remove[i] = false;
	remove[(sz)alloc_ref] = true;
	Mem2RegRenameContext context = {
		.editor = &editor,
		.cfg = &cfg,
		.alloc_ref = alloc_ref,
		.access_type = access_type,
		.zero_ref = ir::NONE,
		.phi_for_block = phi_for_block,
		.remove = remove,
	};
	if (cfg.rpo.len == 0 || !mem2reg_rename_block(&context, cfg.rpo[0], ir::NONE))
	{
		editor.free();
		return false;
	}
	foreach (phi_ref : phi_for_block)
	{
		if (phi_ref == ir::NONE) continue;
		ir::Inst* phi = &editor.insts.entries[(sz)phi_ref];
		foreach (input : phi.data.phi) if (input.value == ir::NONE)
		{
			editor.free();
			return false;
		}
	}
	// Promoted loads and stores are now represented by SSA values.
	foreach (user_ref : uses.users[(sz)alloc_ref])
	{
		ir::Inst* user = &editor.insts.entries[(sz)user_ref];
		if (user.tag == ir::InstTag.LOAD || user.tag == ir::InstTag.STORE) remove[(sz)user_ref] = true;
	}
	editor_cleanup_trivial_phis(&editor, remove);
	editor_cleanup_unused_mem2reg_phis(&editor, phi_for_block, remove);
	BodyRemovalContext removal_context = { .remove = remove };
	editor.remove_body_where(&body_ref_marked_for_removal, (void*)&removal_context);
	editor.commit();
	return true;
}

<* Promote all eligible local allocations, rebuilding analyses after each edit. *>
fn bool mem2reg(ir::Ir* ir, ir::Decl* decl, Allocator a)
{
	if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
	list::List{ir::Ref} candidates;
	candidates.init(a);
	defer candidates.free();
	foreach (ref : decl.body)
	{
		if ((usz)ref < (usz)decl.instructions.len && decl.instructions[(sz)ref].tag == ir::InstTag.ALLOC) candidates.push(ref);
	}
	bool changed = false;
	foreach (alloc_ref : candidates) changed = promote_alloca(ir, decl, alloc_ref, a) || changed;
	return changed;
}

enum ConstPropTag : char
{
	TOP, CONSTANT, BOTTOM
}

struct ConstPropValue
{
	ConstPropTag tag;
	ulong bits;
}

fn ulong const_prop_mask(ushort width)
{
	if (width >= 64) return 0xFFFF_FFFF_FFFF_FFFF;
	return ((ulong)1 << width) - 1;
}

fn long const_prop_signed(ulong bits, ushort width)
{
	ulong mask = const_prop_mask(width);
	bits &= mask;
	if (width == 64) return (long)bits;
	ulong sign_bit = (ulong)1 << (width - 1);
	if ((bits & sign_bit) != 0) return (long)(bits | ~mask);
	return (long)bits;
}

fn bool const_prop_int_width(ir::Ir* graph, value_interner::InternerRef ty, ushort* width)
{
	primitive_value::PrimitiveValue key = graph.interner.get(ty);
	if (key.tag != primitive_value::PrimitiveType.INT_TY || key.ty_bits == 0 || key.ty_bits > 64) return false;
	*width = key.ty_bits;
	return true;
}

fn ConstPropValue const_prop_bottom() =>
{
	.tag = ConstPropTag.BOTTOM
};
fn ConstPropValue const_prop_top() =>
{
	.tag = ConstPropTag.TOP
};
fn ConstPropValue const_prop_constant(ushort width, ulong bits)
=>
{
	.tag = ConstPropTag.CONSTANT, .bits = bits & const_prop_mask(width)
};

<* Join two lattice values. TOP contributes no information; conflicting constants become BOTTOM. *>
fn ConstPropValue const_prop_join(ConstPropValue lhs, ConstPropValue rhs)
{
	if (lhs.tag == ConstPropTag.BOTTOM || rhs.tag == ConstPropTag.BOTTOM) return const_prop_bottom();
	if (lhs.tag == ConstPropTag.TOP) return rhs;
	if (rhs.tag == ConstPropTag.TOP) return lhs;
	if (lhs.bits == rhs.bits) return lhs;
	return const_prop_bottom();
}

fn ConstPropValue const_prop_ref(ConstPropValue[] values, ir::Decl* decl, ir::Ref ref)
{
	if ((usz)ref >= (usz)decl.instructions.len) return const_prop_bottom();
	return values[(sz)ref];
}

fn ConstPropValue const_prop_constant_inst(ir::Ir* graph, ir::Inst* inst)
{
	ushort width;
	if (!const_prop_int_width(graph, inst.ty, &width)) return const_prop_bottom();
	primitive_value::PrimitiveValue key = graph.interner.get(inst.data.constant);
	if (key.tag.kind != NumberKind.INT || !key.int_fits_64()) return const_prop_bottom();
	return const_prop_constant(width, key.int_low_u64());
}

fn ConstPropValue const_prop_binary(ir::Ir* graph, ir::Decl* decl, ir::Inst* inst, ConstPropValue[] values)
{
	ConstPropValue lhs = const_prop_ref(values, decl, inst.data.bin.lhs);
	ConstPropValue rhs = const_prop_ref(values, decl, inst.data.bin.rhs);
	if (lhs.tag == ConstPropTag.BOTTOM || rhs.tag == ConstPropTag.BOTTOM) return const_prop_bottom();
	if (lhs.tag == ConstPropTag.TOP || rhs.tag == ConstPropTag.TOP) return const_prop_top();
	ushort width;
	bool is_compare = inst.tag == ir::InstTag.CMP_EQ || inst.tag == ir::InstTag.CMP_NE ||
	inst.tag == ir::InstTag.CMP_SLT || inst.tag == ir::InstTag.CMP_SLTE ||
	inst.tag == ir::InstTag.CMP_SGT || inst.tag == ir::InstTag.CMP_SGTE ||
	inst.tag == ir::InstTag.CMP_ULT || inst.tag == ir::InstTag.CMP_ULTE ||
	inst.tag == ir::InstTag.CMP_UGT || inst.tag == ir::InstTag.CMP_UGTE;
	if (is_compare)
	{
		if ((usz)inst.data.bin.lhs >= (usz)decl.instructions.len ||
		!const_prop_int_width(graph, decl.instructions[(sz)inst.data.bin.lhs].ty, &width)) return const_prop_bottom();
	}
	else if (!const_prop_int_width(graph, inst.ty, &width))
	{
		return const_prop_bottom();
	}
	ulong mask = const_prop_mask(width);
	ulong a = lhs.bits & mask;
	ulong b = rhs.bits & mask;
	ulong shift_amount = rhs.bits;
	ulong result = 0;
	switch (inst.tag)
	{
		case ir::InstTag.ADD: result = a + b;
		case ir::InstTag.SUB: result = a - b;
		case ir::InstTag.MUL: result = a * b;
		case ir::InstTag.BIT_AND: result = a & b;
		case ir::InstTag.BIT_OR: result = a | b;
		case ir::InstTag.BIT_XOR: result = a ^ b;
		case ir::InstTag.BIT_SHL:
			if (shift_amount >= width) return const_prop_bottom();
			result = a << (uint)shift_amount;
		case ir::InstTag.BIT_LSHR:
			if (shift_amount >= width) return const_prop_bottom();
			result = a >> (uint)shift_amount;
		case ir::InstTag.BIT_ASHR:
			if (shift_amount >= width) return const_prop_bottom();
			if (shift_amount == 0)
			{
				result = a;
			}
			else
			{
				result = a >> (uint)shift_amount;
				if ((a & ((ulong)1 << (width - 1))) != 0)
				{
					ulong fill = mask ^ (((ulong)1 << (width - (uint)shift_amount)) - 1);
					result |= fill;
				}
			}
		case ir::InstTag.UDIV:
			if (b == 0) return const_prop_bottom();
			result = a / b;
		case ir::InstTag.UREM:
			if (b == 0) return const_prop_bottom();
			result = a % b;
		case ir::InstTag.SDIV:
		case ir::InstTag.SREM:
			if (b == 0) return const_prop_bottom();
			long signed_a = const_prop_signed(a, width);
			long signed_b = const_prop_signed(b, width);
			ulong signed_min = (ulong)1 << (width - 1);
			if (a == signed_min && b == mask) return const_prop_bottom();
			if (inst.tag == ir::InstTag.SDIV)
			{
				result = (ulong)(signed_a / signed_b);
			}
			else
			{
				result = (ulong)(signed_a % signed_b);
			}
		case ir::InstTag.CMP_EQ: return const_prop_constant(1, (ulong)(a == b ? 1 : 0));
		case ir::InstTag.CMP_NE: return const_prop_constant(1, (ulong)(a != b ? 1 : 0));
		case ir::InstTag.CMP_SLT: return const_prop_constant(1, (ulong)(const_prop_signed(a, width) < const_prop_signed(b, width) ? 1 : 0));
		case ir::InstTag.CMP_SLTE: return const_prop_constant(1, (ulong)(const_prop_signed(a, width) <= const_prop_signed(b, width) ? 1 : 0));
		case ir::InstTag.CMP_SGT: return const_prop_constant(1, (ulong)(const_prop_signed(a, width) > const_prop_signed(b, width) ? 1 : 0));
		case ir::InstTag.CMP_SGTE: return const_prop_constant(1, (ulong)(const_prop_signed(a, width) >= const_prop_signed(b, width) ? 1 : 0));
		case ir::InstTag.CMP_ULT: return const_prop_constant(1, (ulong)(a < b ? 1 : 0));
		case ir::InstTag.CMP_ULTE: return const_prop_constant(1, (ulong)(a <= b ? 1 : 0));
		case ir::InstTag.CMP_UGT: return const_prop_constant(1, (ulong)(a > b ? 1 : 0));
		case ir::InstTag.CMP_UGTE: return const_prop_constant(1, (ulong)(a >= b ? 1 : 0));
		default: return const_prop_bottom();
	}
	return const_prop_constant(width, result);
}

fn ConstPropValue const_prop_eval(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, bool[] executable_edges,
	ir::Ref ref, ir::Inst* inst, ConstPropValue[] values)
{
	switch (inst.tag)
	{
		case ir::InstTag.CONSTANT: return const_prop_constant_inst(graph, inst);
		case ir::InstTag.PHI:
			ConstPropValue result = const_prop_top();
			uint block_index = cfg.block_of_ref[(sz)ref];
			foreach (input : inst.data.phi)
			{
				if ((usz)input.label >= (usz)decl.instructions.len) continue;
				uint pred = cfg.block_of_ref[(sz)input.label];
				if (pred == NONE_BLOCK || block_index == NONE_BLOCK ||
					!executable_edges[(sz)pred * (sz)cfg.blocks.len + (sz)block_index]) continue;
				ConstPropValue value = const_prop_ref(values, decl, input.value);
				result = const_prop_join(result, value);
			}
			return result;
		case ir::InstTag.SELECT:
			ConstPropValue cond = const_prop_ref(values, decl, inst.data.branch.cond);
			ConstPropValue then_value = const_prop_ref(values, decl, inst.data.branch.then_label);
			ConstPropValue else_value = const_prop_ref(values, decl, inst.data.branch.else_label);
			if (cond.tag == ConstPropTag.CONSTANT)
			{
				return cond.bits != 0 ? then_value : else_value;
			}
			return const_prop_join(then_value, else_value);
		case ir::InstTag.BIT_NOT:
		case ir::InstTag.NEGATE:
			ConstPropValue operand = const_prop_ref(values, decl, inst.data.ref);
			if (operand.tag != ConstPropTag.CONSTANT) return operand;
			ushort width;
			if (!const_prop_int_width(graph, inst.ty, &width)) return const_prop_bottom();
			if (inst.tag == ir::InstTag.BIT_NOT) return const_prop_constant(width, ~operand.bits);
			return const_prop_constant(width, 0 - operand.bits);
		case ir::InstTag.TRUNC:
		case ir::InstTag.ZEXT:
		case ir::InstTag.SEXT:
			ConstPropValue cast_operand = const_prop_ref(values, decl, inst.data.ref);
			if (cast_operand.tag != ConstPropTag.CONSTANT) return cast_operand;
			ushort src_width;
			ushort dst_width;
			if (!const_prop_int_width(graph, decl.instructions[(sz)inst.data.ref].ty, &src_width) ||
			!const_prop_int_width(graph, inst.ty, &dst_width)) return const_prop_bottom();
			ulong cast_bits = cast_operand.bits & const_prop_mask(src_width);
			if (inst.tag == ir::InstTag.SEXT) cast_bits = (ulong)const_prop_signed(cast_bits, src_width);
			return const_prop_constant(dst_width, cast_bits);
		// Keep this evaluator's arithmetic cases integer-only. Float ops use
		// distinct tags and must not be rewritten with integer bit semantics.
		case ir::InstTag.ADD:
		case ir::InstTag.SUB:
		case ir::InstTag.MUL:
		case ir::InstTag.BIT_AND:
		case ir::InstTag.BIT_OR:
		case ir::InstTag.BIT_XOR:
		case ir::InstTag.BIT_SHL:
		case ir::InstTag.BIT_ASHR:
		case ir::InstTag.BIT_LSHR:
		case ir::InstTag.SDIV:
		case ir::InstTag.UDIV:
		case ir::InstTag.SREM:
		case ir::InstTag.UREM:
		case ir::InstTag.CMP_EQ:
		case ir::InstTag.CMP_NE:
		case ir::InstTag.CMP_SLT:
		case ir::InstTag.CMP_SLTE:
		case ir::InstTag.CMP_SGT:
		case ir::InstTag.CMP_SGTE:
		case ir::InstTag.CMP_ULT:
		case ir::InstTag.CMP_ULTE:
		case ir::InstTag.CMP_UGT:
		case ir::InstTag.CMP_UGTE:
			return const_prop_binary(graph, decl, inst, values);
		default: return const_prop_bottom();
	}
}

fn bool const_prop_update(ConstPropValue[] values, ir::Ref ref, ConstPropValue incoming)
{
	ConstPropValue joined = const_prop_join(values[(sz)ref], incoming);
	if (joined.tag == values[(sz)ref].tag && joined.bits == values[(sz)ref].bits) return false;
	values[(sz)ref] = joined;
	return true;
}

fn void const_prop_enqueue_inst(list::List{ir::Ref} * worklist, bool[] queued, ir::Ref ref)
{
	if ((usz)ref >= (usz)queued.len || queued[(sz)ref]) return;
	queued[(sz)ref] = true;
	worklist.push(ref);
}

fn void const_prop_enqueue_block(ir::Decl* decl, Cfg* cfg, uint block_index,
	list::List{ir::Ref} * worklist, bool[] queued)
{
	CfgBlock* block = &cfg.blocks[(sz)block_index];
	for (sz pos = block.start + 1; pos < block_executable_end(decl, block); pos++)
	{
		const_prop_enqueue_inst(worklist, queued, decl.body[pos]);
	}
}

fn bool const_prop_mark_edge(Cfg* cfg, bool[] executable_edges, bool[] executable_blocks,
	uint from, ir::Ref label, list::List{ir::Ref} * worklist, bool[] queued)
{
	if ((usz)label >= (usz)cfg.block_of_ref.len) return false;
	uint to = cfg.block_of_ref[(sz)label];
	if (to == NONE_BLOCK || (usz)to >= (usz)cfg.blocks.len) return false;
	sz block_count = (sz)cfg.blocks.len;
	sz edge_index = (sz)from * block_count + (sz)to;
	if (executable_edges[edge_index]) return false;
	executable_edges[edge_index] = true;
	if (!executable_blocks[(sz)to])
	{
		executable_blocks[(sz)to] = true;
		const_prop_enqueue_block(cfg.decl, cfg, to, worklist, queued);
		CfgBlock* target = &cfg.blocks[(sz)to];
		if (block_terminator_position(cfg.decl, target) == target.end)
		{
			foreach (succ : target.succs)
			{
				const_prop_mark_edge(cfg, executable_edges, executable_blocks, to,
					cfg.blocks[(sz)succ].label, worklist, queued);
			}
		}
	}
	else
	{
		CfgBlock* target = &cfg.blocks[(sz)to];
		for (sz pos = target.start + 1; pos < block_executable_end(cfg.decl, target); pos++)
		{
			ir::Ref ref = cfg.decl.body[pos];
			if ((usz)ref < (usz)cfg.decl.instructions.len && cfg.decl.instructions[(sz)ref].tag == ir::InstTag.PHI)
			{
				const_prop_enqueue_inst(worklist, queued, ref);
			}
			else
			{
				break;
			}
		}
	}
	return true;
}

fn bool const_prop_switch_value(ir::Ir* graph, value_interner::InternerRef ref, ushort width, ulong* bits)
{
	primitive_value::PrimitiveValue key = graph.interner.get(ref);
	if (key.tag.kind != NumberKind.INT) return false;
	*bits = key.int_low_u64() & const_prop_mask(width);
	return true;
}

<* Wegman-Zadeck sparse conditional constant propagation over mem2reg SSA. *>
fn bool const_prop(ir::Ir* graph, ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
	Cfg cfg = build_cfg(decl, allocator);
	defer cfg.free();
	if (cfg.blocks.len == 0) return false;
	ConstPropValue[] values = alloc::new_array(allocator, ConstPropValue, (sz)decl.instructions.len);
	defer alloc::free(allocator, values.ptr);
	bool[] executable_blocks = alloc::new_array(allocator, bool, (sz)cfg.blocks.len);
	defer alloc::free(allocator, executable_blocks.ptr);
	for (usz i = 0; i < (usz)cfg.blocks.len; i++) executable_blocks[i] = false;
	sz edge_count = (sz)cfg.blocks.len * (sz)cfg.blocks.len;
	bool[] executable_edges = alloc::new_array(allocator, bool, edge_count);
	defer alloc::free(allocator, executable_edges.ptr);
	for (sz i = 0; i < edge_count; i++) executable_edges[i] = false;
	for (usz i = 0; i < (usz)decl.instructions.len; i++)
	{
		values[i] = const_prop_top();
		ir::Inst* inst = &decl.instructions[(sz)i];
		if (inst.tag == ir::InstTag.CONSTANT)
		{
			values[i] = const_prop_constant_inst(graph, inst);
		}
		else if (inst.tag == ir::InstTag.ARG || inst.tag == ir::InstTag.LOAD || inst.tag == ir::InstTag.CALL ||
			inst.tag == ir::InstTag.ALLOC || inst.tag == ir::InstTag.SYMBOL || inst.tag == ir::InstTag.DYN_ALLOC ||
			inst.tag == ir::InstTag.STACK_SAVE || inst.tag == ir::InstTag.ATOMIC_LOAD ||
			inst.tag == ir::InstTag.CLZ || inst.tag == ir::InstTag.CTZ)
		{
			values[i] = const_prop_bottom();
		}
	}
	Uses uses = compute_uses(decl, allocator);
	defer uses.free();
	list::List{ir::Ref} worklist;
	worklist.init(allocator);
	defer worklist.free();
	bool[] queued = alloc::new_array(allocator, bool, (sz)decl.instructions.len);
	defer alloc::free(allocator, queued.ptr);
	for (usz i = 0; i < (usz)decl.instructions.len; i++) queued[i] = false;
	executable_blocks[0] = true;
	const_prop_enqueue_block(decl, &cfg, 0, &worklist, queued);
	CfgBlock* entry = &cfg.blocks[0];
	if (block_terminator_position(decl, entry) == entry.end)
	{
		foreach (succ : entry.succs)
		{
			const_prop_mark_edge(&cfg, executable_edges, executable_blocks, 0,
				cfg.blocks[(sz)succ].label, &worklist, queued);
		}
	}
	while (worklist.len() > 0)
	{
		ir::Ref ref = worklist.pop()!!;
		queued[(sz)ref] = false;
		if ((usz)ref >= (usz)decl.instructions.len) continue;
		uint block_index = cfg.block_of_ref[(sz)ref];
		if (block_index == NONE_BLOCK || !executable_blocks[(sz)block_index]) continue;
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (is_value_tag(inst.tag) && inst.tag != ir::InstTag.CONSTANT)
		{
			ConstPropValue evaluated = const_prop_eval(graph, decl, &cfg, executable_edges, ref, inst, values);
			if (const_prop_update(values, ref, evaluated))
			{
				foreach (user_ref : uses.users[(sz)ref]) const_prop_enqueue_inst(&worklist, queued, user_ref);
			}
		}
		if (inst.tag == ir::InstTag.JMP)
		{
			const_prop_mark_edge(&cfg, executable_edges, executable_blocks, block_index,
				inst.data.ref, &worklist, queued);
		}
		else if (inst.tag == ir::InstTag.BRANCH)
		{
			ConstPropValue cond = const_prop_ref(values, decl, inst.data.branch.cond);
			if (cond.tag == ConstPropTag.CONSTANT)
			{
				ir::Ref target = cond.bits != 0 ? inst.data.branch.then_label : inst.data.branch.else_label;
				const_prop_mark_edge(&cfg, executable_edges, executable_blocks, block_index, target, &worklist, queued);
			}
			else if (cond.tag == ConstPropTag.BOTTOM)
			{
				const_prop_mark_edge(&cfg, executable_edges, executable_blocks, block_index,
					inst.data.branch.then_label, &worklist, queued);
				const_prop_mark_edge(&cfg, executable_edges, executable_blocks, block_index,
					inst.data.branch.else_label, &worklist, queued);
			}
		}
		else if (inst.tag == ir::InstTag.SWITCH)
		{
			ConstPropValue target = const_prop_ref(values, decl, inst.data.switch_data.target);
			if (target.tag == ConstPropTag.CONSTANT)
			{
				ushort width;
				ir::Ref label = inst.data.switch_data.default_label;
				if (const_prop_int_width(graph, decl.instructions[(sz)inst.data.switch_data.target].ty, &width))
				{
					foreach (i, value : inst.data.switch_data.values)
					{
						ulong case_bits;
						if (const_prop_switch_value(graph, value, width, &case_bits) && case_bits == target.bits)
						{
							label = inst.data.switch_data.labels[i];
							break;
						}
					}
				}
				const_prop_mark_edge(&cfg, executable_edges, executable_blocks, block_index, label, &worklist, queued);
			}
			else if (target.tag == ConstPropTag.BOTTOM)
			{
				foreach (label : inst.data.switch_data.labels)
				const_prop_mark_edge(&cfg, executable_edges, executable_blocks, block_index, label, &worklist, queued);
				const_prop_mark_edge(&cfg, executable_edges, executable_blocks, block_index,
					inst.data.switch_data.default_label, &worklist, queued);
			}
		}
	}

	DeclEditor editor;
	editor.begin(decl, allocator);
	bool changed = false;
	for (sz pos = 0; pos < editor.body.len(); pos++)
	{
		ir::Ref ref = editor.body.entries[pos];
		if ((usz)ref >= (usz)editor.insts.len()) continue;
		ir::Inst* inst = &editor.insts.entries[(sz)ref];
		if (inst.tag == ir::InstTag.BRANCH)
		{
			ConstPropValue cond = values[(sz)inst.data.branch.cond];
			if (cond.tag != ConstPropTag.CONSTANT) continue;
			ir::Ref target = cond.bits != 0 ? inst.data.branch.then_label : inst.data.branch.else_label;
			inst.tag = ir::InstTag.JMP;
			inst.data.ref = target;
			changed = true;
		}
		else if (inst.tag == ir::InstTag.SWITCH)
		{
			ConstPropValue target_value = values[(sz)inst.data.switch_data.target];
			if (target_value.tag != ConstPropTag.CONSTANT) continue;
			ushort width;
			ir::Ref target_label = inst.data.switch_data.default_label;
			if (const_prop_int_width(graph, decl.instructions[(sz)inst.data.switch_data.target].ty, &width))
			{
				foreach (i, value : inst.data.switch_data.values)
				{
					ulong case_bits;
					if (const_prop_switch_value(graph, value, width, &case_bits) && case_bits == target_value.bits)
					{
						target_label = inst.data.switch_data.labels[i];
						break;
					}
				}
			}
			inst.tag = ir::InstTag.JMP;
			inst.data.ref = target_label;
			changed = true;
		}
	}
	for (sz pos = 0; pos < editor.body.len(); pos++)
	{
		ir::Ref ref = editor.body.entries[pos];
		if ((usz)ref >= (usz)editor.insts.len()) continue;
		ir::Inst* inst = &editor.insts.entries[(sz)ref];
		uint block_index = cfg.block_of_ref[(sz)ref];
		if (inst.tag == ir::InstTag.PHI)
		{
			usz kept = 0;
			for (usz i = 0; i < (usz)inst.data.phi.len; i++)
			{
				ir::PhiInput input = inst.data.phi[(sz)i];
				if ((usz)input.label >= (usz)cfg.block_of_ref.len) continue;
				uint pred = cfg.block_of_ref[(sz)input.label];
				if (pred == NONE_BLOCK || block_index == NONE_BLOCK ||
					!executable_edges[(sz)pred * (sz)cfg.blocks.len + (sz)block_index]) continue;
				inst.data.phi[(sz)kept++] = input;
			}
			if (kept != (usz)inst.data.phi.len)
			{
				ir::PhiInput[] filtered = alloc::new_array(&decl.arena, ir::PhiInput, (sz)kept);
				if (kept) filtered[..] = inst.data.phi[:(sz)kept];
				inst.data.phi = filtered;
				changed = true;
			}
		}
		ConstPropValue value = values[(sz)ref];
		if (value.tag != ConstPropTag.CONSTANT || inst.tag == ir::InstTag.CONSTANT ||
			inst.tag == ir::InstTag.LABEL || inst.tag == ir::InstTag.SYMBOL || inst.tag == ir::InstTag.ARG) continue;
		ushort width;
		if (!const_prop_int_width(graph, inst.ty, &width)) continue;
		value_interner::InternerRef constant_ref;
		if (width == 1)
		{
			constant_ref = value.bits == 0 ? value_interner::REF_ZERO : value_interner::REF_ONE;
		}
		else
		{
			constant_ref = graph.interner.put(primitive_value::int_key(const_prop_signed(value.bits, width)));
		}
		ir::Ref constant_inst = editor.add_constant(constant_ref, inst.ty);
		editor_replace_all_uses(&editor, ref, constant_inst);
		changed = true;
	}
	if (changed)
	{
		editor.commit();
	}
	else
	{
		editor.free();
	}
	return changed;
}

fn bool removable_if_unused(ir::Decl* decl, ir::Inst* inst)
{
	switch (inst.tag)
	{
		case ir::InstTag.BIT_OR:
		case ir::InstTag.BIT_XOR:
		case ir::InstTag.BIT_AND:
		case ir::InstTag.BIT_SHL:
		case ir::InstTag.BIT_ASHR:
		case ir::InstTag.BIT_LSHR:
		case ir::InstTag.CMP_EQ:
		case ir::InstTag.CMP_NE:
		case ir::InstTag.CMP_SLT:
		case ir::InstTag.CMP_SLTE:
		case ir::InstTag.CMP_SGT:
		case ir::InstTag.CMP_SGTE:
		case ir::InstTag.CMP_ULT:
		case ir::InstTag.CMP_ULTE:
		case ir::InstTag.CMP_UGT:
		case ir::InstTag.CMP_UGTE:
		case ir::InstTag.ADD:
		case ir::InstTag.SUB:
		case ir::InstTag.MUL:
		case ir::InstTag.TRUNC:
		case ir::InstTag.ZEXT:
		case ir::InstTag.SEXT:
		case ir::InstTag.BIT_NOT:
		case ir::InstTag.NEGATE:
		case ir::InstTag.SELECT:
		case ir::InstTag.PHI:
		case ir::InstTag.CALL_HI:
		case ir::InstTag.CLZ:
		case ir::InstTag.CTZ:
			return true;
		case ir::InstTag.LOAD:
			if ((usz)inst.data.ref >= (usz)decl.instructions.len) return false;
			if (decl.instructions[(sz)inst.data.ref].tag != ir::InstTag.ALLOC) return false;
			return !decl.instructions[(sz)inst.data.ref].data.alloc.is_volatile;
		case ir::InstTag.SDIV:
		case ir::InstTag.UDIV:
		case ir::InstTag.SREM:
		case ir::InstTag.UREM:
			if ((usz)inst.data.bin.rhs >= (usz)decl.instructions.len) return false;
			ir::Inst* divisor = &decl.instructions[(sz)inst.data.bin.rhs];
			// Integer zero is canonicalized by the interner to REF_ZERO. These
			// operations have integer operands, so any other constant is nonzero.
			return divisor.tag == ir::InstTag.CONSTANT && divisor.data.constant != value_interner::REF_ZERO;
		default: return false;
	}
}

<* Remove dead pure instructions and unobserved local allocations to a fixpoint. *>
fn bool dead_instruction_elim(ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
	bool[] remove = alloc::new_array(allocator, bool, (sz)decl.instructions.len);
	defer alloc::free(allocator, remove.ptr);
	bool any_changed = false;
	while (true)
	{
		for (usz i = 0; i < (usz)decl.instructions.len; i++) remove[i] = false;
		Uses uses = compute_uses(decl, allocator);
		bool changed = false;
		foreach (ref : decl.body)
		{
			if ((usz)ref >= (usz)decl.instructions.len) continue;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			list::List{ir::Ref} * users = &uses.users[(sz)ref];
			if (inst.tag == ir::InstTag.ALLOC)
			{
				if (inst.data.alloc.is_volatile) continue;
				if (users.len() == 0)
				{
					remove[(sz)ref] = true;
					changed = true;
					continue;
				}
				bool stores_only = true;
				foreach (user_ref : *users)
				{
					if ((usz)user_ref >= (usz)decl.instructions.len)
					{
						stores_only = false;
						break;
					}
					ir::Inst* user = &decl.instructions[(sz)user_ref];
					// A self-store contributes a second use of the allocation as
					// its value. Keep it conservatively instead of misclassifying it.
					if (user.tag != ir::InstTag.STORE || user.data.bin.lhs != ref || user.data.bin.rhs == ref)
					{
						stores_only = false;
						break;
					}
				}
				if (stores_only)
				{
					remove[(sz)ref] = true;
					foreach (user_ref : *users) remove[(sz)user_ref] = true;
					changed = true;
				}
				continue;
			}
			if (inst.tag == ir::InstTag.STORE && (usz)inst.data.bin.lhs < (usz)decl.instructions.len)
			{
				ir::Inst* destination = &decl.instructions[(sz)inst.data.bin.lhs];
				if (destination.tag == ir::InstTag.ALLOC && destination.data.alloc.is_volatile) continue;
			}
			if (users.len() == 0 && removable_if_unused(decl, inst))
			{
				remove[(sz)ref] = true;
				changed = true;
			}
		}
		uses.free();
		if (!changed) break;
		any_changed = true;

		DeclEditor editor;
		editor.begin(decl, allocator);
		BodyRemovalContext context = { .remove = remove };
		editor.remove_body_where(&body_ref_marked_for_removal, (void*)&context);
		editor.commit();
	}
	return any_changed;
}

struct InlineCallGraph
{
	Allocator allocator;
	usz decl_count;
	HashMap{String, usz} decl_indices;
	list::List{uint}[] edges;
	list::List{uint}[] reverse_edges;
	uint[] scc;
	uint[] bottom_up;
	uint[] call_count;
}

fn void InlineCallGraph.free(&self)
{
	foreach (&edges : self.edges) edges.free();
	foreach (&edges : self.reverse_edges) edges.free();
	if (self.edges.len) alloc::free(self.allocator, self.edges.ptr);
	if (self.reverse_edges.len) alloc::free(self.allocator, self.reverse_edges.ptr);
	if (self.scc.len) alloc::free(self.allocator, self.scc.ptr);
	if (self.bottom_up.len) alloc::free(self.allocator, self.bottom_up.ptr);
	if (self.call_count.len) alloc::free(self.allocator, self.call_count.ptr);
	self.decl_indices.free();
	*self = {};
}

fn uint inline_decl_index(HashMap{String, usz} * decl_indices, String name)
{
	if (try index = decl_indices.get(name)) return (uint)index;
	return NONE_BLOCK;
}

fn InlineCallGraph build_inline_call_graph(ir::Ir* graph, Allocator allocator)
{
	InlineCallGraph calls = { .allocator = allocator, .decl_count = (usz)graph.decls.len() };
	uint n = (uint)calls.decl_count;
	calls.decl_indices.init(allocator);
	foreach (i, decl : graph.decls) calls.decl_indices.set(decl.name, (usz)i);
	calls.edges = alloc::new_array(allocator, list::List{uint}, (sz)n);
	calls.reverse_edges = alloc::new_array(allocator, list::List{uint}, (sz)n);
	calls.scc = alloc::new_array(allocator, uint, (sz)n);
	calls.bottom_up = alloc::new_array(allocator, uint, (sz)n);
	calls.call_count = alloc::new_array(allocator, uint, (sz)n);
	for (uint i = 0; i < n; i++)
	{
		calls.edges[i].init(allocator);
		calls.reverse_edges[i].init(allocator);
		calls.scc[i] = NONE_BLOCK;
		calls.call_count[i] = 0;
	}
	foreach (caller_index, caller : graph.decls)
	{
		if (caller.kind != ir::DeclKind.FUNCTION || caller.body.len == 0) continue;
		foreach (ref : caller.body)
		{
			if ((usz)ref >= (usz)caller.instructions.len) continue;
			ir::Inst* inst = &caller.instructions[(sz)ref];
			if (inst.tag != ir::InstTag.CALL || (usz)inst.data.call.func >= (usz)caller.instructions.len) continue;
			ir::Inst* func = &caller.instructions[(sz)inst.data.call.func];
			if (func.tag != ir::InstTag.SYMBOL) continue;
			uint callee_index = inline_decl_index(&calls.decl_indices, func.data.label);
			if (callee_index == NONE_BLOCK || graph.decls.entries[(sz)callee_index].kind != ir::DeclKind.FUNCTION) continue;
			bool has_edge = false;
			foreach (existing : calls.edges[(sz)caller_index]) if (existing == callee_index) has_edge = true;
			if (!has_edge)
			{
				calls.edges[(sz)caller_index].push(callee_index);
				calls.reverse_edges[(sz)callee_index].push((uint)caller_index);
			}
			calls.call_count[(sz)callee_index]++;
		}
	}

	// Kosaraju SCC assignment. Recursive calls and mutual recursion share one
	// component and are excluded as inline candidates below.
	bool[] visited = alloc::new_array(allocator, bool, (sz)n);
	defer alloc::free(allocator, visited.ptr);
	for (uint i = 0; i < n; i++) visited[(sz)i] = false;
	list::List{uint} postorder;
	postorder.init(allocator);
	defer postorder.free();
	list::List{DfsFrame} dfs;
	dfs.init(allocator);
	defer dfs.free();
	for (uint root = 0; root < n; root++)
	{
		if (visited[(sz)root]) continue;
		visited[(sz)root] = true;
		dfs.push(
		{
			.block = root, .next_succ = 0
		}
		);
		while (dfs.len())
		{
			DfsFrame* frame = &dfs.entries[dfs.len() - 1];
			list::List{uint} * successors = &calls.edges[(sz)frame.block];
			if (frame.next_succ < successors.len())
			{
				uint child = successors.entries[frame.next_succ++];
				if (!visited[(sz)child])
				{
					visited[(sz)child] = true;
					dfs.push(
					{
						.block = child, .next_succ = 0
					}
					);
				}
				continue;
			}
			postorder.push(frame.block);
			dfs.pop()!!;
		}
	}
	uint component_count = 0;
	list::List{uint} pending;
	pending.init(allocator);
	defer pending.free();
	for (sz p = postorder.len(); p > 0; p--)
	{
		uint root = postorder.entries[p - 1];
		if (calls.scc[(sz)root] != NONE_BLOCK) continue;
		calls.scc[(sz)root] = component_count;
		pending.push(root);
		while (pending.len())
		{
			uint node = pending.pop()!!;
			foreach (predecessor : calls.reverse_edges[(sz)node])
			{
				if (calls.scc[(sz)predecessor] != NONE_BLOCK) continue;
				calls.scc[(sz)predecessor] = component_count;
				pending.push(predecessor);
			}
		}
		component_count++;
	}
	// SCC identifiers increase from callers to callees, so descending component
	// order visits every acyclic callee before its callers.
	usz write = 0;
	for (uint component = component_count; component > 0; component--)
	{
		for (uint i = 0; i < n; i++) if (calls.scc[(sz)i] == component - 1) calls.bottom_up[write++] = i;
	}
	return calls;
}

fn usz inline_arg_count(ir::Decl* decl)
{
	usz count = 0;
	while (count < (usz)decl.body.len)
	{
		ir::Ref ref = decl.body[(sz)count];
		if ((usz)ref >= (usz)decl.instructions.len || decl.instructions[(sz)ref].tag != ir::InstTag.ARG) break;
		count++;
	}
	return count;
}

fn usz inline_body_cost(ir::Decl* decl)
{
	return (usz)decl.body.len;
}

fn bool inline_unsupported_control(ir::Decl* decl)
{
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.RET_PAIR) return true;
		if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return true;
		// Dynamic stack allocation lives until the callee returns; inlining would leak it into the caller's frame.
		if (inst.tag == ir::InstTag.DYN_ALLOC || inst.tag == ir::InstTag.STACK_SAVE) return true;
		// va_start refers to the callee's variadic argument state and cannot move into a caller.
		if (inst.tag == ir::InstTag.VA_START) return true;
	}
	return false;
}

fn bool inline_body_contains(ir::Decl* decl, ir::Ref ref)
{
	foreach (body_ref : decl.body) if (body_ref == ref) return true;
	return false;
}

fn void inline_mark_target(bool[] targets, ir::Ref ref)
{
	if ((usz)ref < (usz)targets.len) targets[(sz)ref] = true;
}

fn void inline_mark_terminator_targets(ir::Inst* inst, bool[] targets)
{
	switch (inst.tag)
	{
		case ir::InstTag.JMP: inline_mark_target(targets, inst.data.ref);
		case ir::InstTag.BRANCH:
			inline_mark_target(targets, inst.data.branch.then_label);
			inline_mark_target(targets, inst.data.branch.else_label);
		case ir::InstTag.SWITCH:
			foreach (label : inst.data.switch_data.labels) inline_mark_target(targets, label);
			inline_mark_target(targets, inst.data.switch_data.default_label);
		default: break;
	}
}

fn sz inline_entry_alloc_position(DeclEditor* editor)
{
	sz pos = 0;
	while (pos < editor.body.len() && (usz)editor.body.entries[pos] < (usz)editor.insts.len() &&
	editor.insts.entries[(sz)editor.body.entries[pos]].tag == ir::InstTag.ARG) pos++;
	if (pos >= editor.body.len()) return pos;
	if (editor.insts.entries[(sz)editor.body.entries[pos]].tag != ir::InstTag.LABEL) return pos;
	pos++;
	while (pos < editor.body.len())
	{
		ir::Ref ref = editor.body.entries[pos];
		if ((usz)ref >= (usz)editor.insts.len()) break;
		ir::InstTag tag = editor.insts.entries[(sz)ref].tag;
		if (tag != ir::InstTag.PHI && tag != ir::InstTag.ALLOC) break;
		pos++;
	}
	return pos;
}

fn ir::Ref inline_mapped_ref(ir::Ref[] mapping, ir::Ref ref)
{
	if (ref == ir::NONE || (usz)ref >= (usz)mapping.len || mapping[(sz)ref] == ir::NONE) return ref;
	return mapping[(sz)ref];
}

fn bool inline_is_block_terminator(ir::Decl* decl, Cfg* cfg, ir::Ref ref, sz body_pos)
{
	if ((usz)ref >= (usz)cfg.block_of_ref.len) return false;
	uint block_index = cfg.block_of_ref[(sz)ref];
	if (block_index == NONE_BLOCK || block_index >= cfg.blocks.len) return false;
	return block_terminator_position(decl, &cfg.blocks[(sz)block_index]) == body_pos;
}

fn bool inline_one_call(ir::Ir* graph, ir::Decl* caller, ir::Decl* callee, ir::Ref call_ref, Allocator allocator)
{
	if ((usz)call_ref >= (usz)caller.instructions.len || !inline_body_contains(caller, call_ref)) return false;
	ir::Inst* call = &caller.instructions[(sz)call_ref];
	if (call.tag != ir::InstTag.CALL || (usz)call.data.call.func >= (usz)caller.instructions.len) return false;
	foreach (copy_bytes : call.data.call.memory_copy_bytes) if (copy_bytes != 0) return false;
	for (usz pos = 0; pos + 1 < (usz)caller.body.len; pos++)
	{
		if (caller.body[(sz)pos] != call_ref) continue;
		ir::Ref next = caller.body[(sz)(pos + 1)];
		if ((usz)next < (usz)caller.instructions.len)
		{
			ir::Inst next_inst = caller.instructions[(sz)next];
			if (next_inst.tag == ir::InstTag.CALL_HI && next_inst.data.ref == call_ref) return false;
		}
		break;
	}
	ir::Ref call_func_ref = call.data.call.func;
	if (caller.instructions[(sz)call_func_ref].tag != ir::InstTag.SYMBOL) return false;
	usz callee_arg_count = inline_arg_count(callee);
	if (callee_arg_count != (usz)call.data.call.args.len) return false;
	Cfg callee_cfg = build_cfg(callee, allocator);
	defer callee_cfg.free();
	if (callee_cfg.blocks.len == 0 || callee_cfg.rpo.len == 0) return false;

	// Do not construct an invalid continuation PHI for malformed or unused
	// value-return behavior. Normal C functions have consistent return types.
	Uses uses = compute_uses(caller, allocator);
	bool call_is_used = uses.users[(sz)call_ref].len() != 0;
	bool has_call_hi_user = false;
	foreach (user_ref : uses.users[(sz)call_ref])
	{
		if ((usz)user_ref < (usz)caller.instructions.len && caller.instructions[(sz)user_ref].tag == ir::InstTag.CALL_HI)
		{
			has_call_hi_user = true;
			break;
		}
	}
	uses.free();
	if (has_call_hi_user) return false;
	usz return_count = 0;
	bool returns_value = false;
	bool returns_void = false;
	foreach (block : callee_cfg.blocks)
	{
		sz term_pos = block_terminator_position(callee, &block);
		if (term_pos >= block.end) continue;
		ir::Ref term_ref = callee.body[term_pos];
		if ((usz)term_ref >= (usz)callee.instructions.len || callee.instructions[(sz)term_ref].tag != ir::InstTag.RET) continue;
		return_count++;
		if (callee.instructions[(sz)term_ref].data.ref == ir::NONE)
		{
			returns_void = true;
		} else
		{
			returns_value = true;
		}
	}
	if (returns_value && returns_void) return false;
	if (call_is_used && (!returns_value || return_count == 0)) return false;

	sz call_pos = -1;
	for (sz i = 0; i < caller.body.len; i++) if (caller.body[i] == call_ref)
	{
		call_pos = i; break;
	}
	if (call_pos < 0) return false;
	ir::Ref caller_block_label = ir::NONE;
	for (sz i = call_pos; i >= 0; i--)
	{
		ir::Ref ref = caller.body[i];
		if ((usz)ref < (usz)caller.instructions.len && caller.instructions[(sz)ref].tag == ir::InstTag.LABEL)
		{
			caller_block_label = ref;
			break;
		}
	}
	if (caller_block_label == ir::NONE) return false;

	DeclEditor editor;
	editor.begin(caller, allocator);
	bool[] successor_targets = alloc::new_array(allocator, bool, (sz)caller.instructions.len);
	defer alloc::free(allocator, successor_targets.ptr);
	for (usz i = 0; i < (usz)successor_targets.len; i++) successor_targets[i] = false;
	for (sz pos = call_pos + 1; pos < editor.body.len(); pos++)
	{
		ir::Ref ref = editor.body.entries[pos];
		if ((usz)ref >= (usz)editor.insts.len()) continue;
		ir::Inst* inst = &editor.insts.entries[(sz)ref];
		if (inst.tag == ir::InstTag.LABEL)
		{
			inline_mark_target(successor_targets, ref);
			break;
		}
		if (is_terminator(inst.tag))
		{
			inline_mark_terminator_targets(inst, successor_targets);
			break;
		}
	}

	String continuation_name = string::format(allocator, "inl.%s.%d.cont", caller.name, call_ref);
	ir::Ref continuation_label = editor.new_label(continuation_name);
	alloc::free(allocator, continuation_name.ptr);  // new_label copied it into the decl arena
	ir::Ref[] mapping = alloc::new_array(allocator, ir::Ref, (sz)callee.instructions.len);
	defer alloc::free(allocator, mapping.ptr);
	for (usz i = 0; i < (usz)mapping.len; i++) mapping[i] = ir::NONE;
	// The caller passes sub-int integers widened to i32 (SysV promotion); the
	// callee's ARG keeps the declared narrow type. Narrow them back in the
	// inlined entry block so stores and arithmetic keep the callee's width.
	list::List{ir::Ref} arg_truncs;
	arg_truncs.init(allocator);
	defer arg_truncs.free();
	usz arg_index = 0;
	for (usz pos = 0; pos < (usz)callee.body.len && arg_index < callee_arg_count; pos++)
	{
		ir::Ref ref = callee.body[(sz)pos];
		if ((usz)ref >= (usz)callee.instructions.len || callee.instructions[(sz)ref].tag != ir::InstTag.ARG) break;
		ir::Ref passed = call.data.call.args[(sz)arg_index++];
		value_interner::InternerRef param_ty = callee.instructions[(sz)ref].ty;
		value_interner::InternerRef passed_ty = editor.insts.entries[(sz)passed].ty;
		if (param_ty != passed_ty)
		{
			primitive_value::PrimitiveValue param_key = graph.interner.get(param_ty);
			primitive_value::PrimitiveValue passed_key = graph.interner.get(passed_ty);
			if (param_key.tag != primitive_value::PrimitiveType.INT_TY || passed_key.tag != primitive_value::PrimitiveType.INT_TY ||
				param_key.ty_bits >= passed_key.ty_bits)
			{
				editor.free(); return false;
			}
			passed = editor.append({ .tag = ir::InstTag.TRUNC, .data.ref = passed, .ty = param_ty });
			arg_truncs.push(passed);
		}
		mapping[(sz)ref] = passed;
	}
	if (arg_index != callee_arg_count)
	{
		editor.free(); return false;
	}
	foreach (i, source_inst : callee.instructions)
	{
		if (source_inst.tag == ir::InstTag.ARG) continue;
		ir::Inst cloned = source_inst;
		if (cloned.tag == ir::InstTag.LABEL)
		{
			String label_name = string::format(allocator, "inl.%s.%d.%d", caller.name, call_ref, (uint)i);
			cloned.data.label = label_name;
			mapping[i] = editor.append(cloned);  // copies the label into the decl arena
			alloc::free(allocator, label_name.ptr);
			continue;
		}
		mapping[i] = editor.append(cloned);
	}
	foreach (i, source_inst : callee.instructions)
	{
		if (source_inst.tag == ir::InstTag.ARG || mapping[i] == ir::NONE) continue;
		ir::Inst* cloned = &editor.insts.entries[(sz)mapping[i]];
		@each_value_operand(cloned; ir::Ref* slot)
		{
			*slot = inline_mapped_ref(mapping, *slot);
		};
		@each_label_operand(cloned; ir::Ref* slot)
		{
			*slot = inline_mapped_ref(mapping, *slot);
		};
	}

	list::List{ir::Ref} cloned_body;
	cloned_body.init(allocator);
	defer cloned_body.free();
	list::List{ir::Ref} cloned_allocs;
	cloned_allocs.init(allocator);
	defer cloned_allocs.free();
	list::List{ir::PhiInput} return_inputs;
	return_inputs.init(allocator);
	defer return_inputs.free();
	ir::Ref callee_entry = ir::NONE;
	ir::Ref active_callee_label = ir::NONE;
	for (sz pos = 0; pos < callee.body.len; pos++)
	{
		ir::Ref source_ref = callee.body[pos];
		if ((usz)source_ref >= (usz)callee.instructions.len || callee.instructions[(sz)source_ref].tag == ir::InstTag.ARG) continue;
		ir::Inst* source = &callee.instructions[(sz)source_ref];
		ir::Ref cloned_ref = mapping[(sz)source_ref];
		bool entry_label = false;
		if (source.tag == ir::InstTag.LABEL)
		{
			active_callee_label = cloned_ref;
			if (callee_entry == ir::NONE)
			{
				callee_entry = cloned_ref;
				entry_label = true;
			}
		}
		if (source.tag == ir::InstTag.ALLOC)
		{
			cloned_allocs.push(cloned_ref);
			continue;
		}
		if (entry_label)
		{
			cloned_body.push(cloned_ref);
			foreach (trunc : arg_truncs) cloned_body.push(trunc);
			continue;
		}
		if (source.tag == ir::InstTag.RET)
		{
			if (inline_is_block_terminator(callee, &callee_cfg, source_ref, pos))
			{
				if (active_callee_label == ir::NONE)
				{
					editor.free(); return false;
				}
				ir::Ref ret_value = source.data.ref == ir::NONE ? ir::NONE : inline_mapped_ref(mapping, source.data.ref);
				if (ret_value != ir::NONE) return_inputs.push(
				{
					.label = active_callee_label, .value = ret_value
				}
				);
			}
			ir::Inst* cloned = &editor.insts.entries[(sz)cloned_ref];
			cloned.tag = ir::InstTag.JMP;
			cloned.data.ref = continuation_label;
			cloned.ty = value_interner::REF_NORETURN;
		}
		cloned_body.push(cloned_ref);
	}
	if (callee_entry == ir::NONE)
	{
		editor.free(); return false;
	}

	ir::Ref result_phi = ir::NONE;
	if (returns_value && return_inputs.len() > 1)
	{
		ir::PhiInput[] inputs = alloc::new_array(allocator, ir::PhiInput, return_inputs.len());
		defer alloc::free(allocator, inputs.ptr);
		inputs[..] = return_inputs.array_view()[..];
		result_phi = editor.append(
		{
			.tag = ir::InstTag.PHI, .data.phi = inputs, .ty = call.ty
		}
		);
	}
	else if (returns_value && return_inputs.len() == 1)
	{
		result_phi = return_inputs.entries[0].value;
	}
	else if (call_is_used)
	{
		editor.free();
		return false;
	}

	ir::Ref caller_jump = editor.append(
	{
		.tag = ir::InstTag.JMP, .data.ref = callee_entry, .ty = value_interner::REF_NORETURN
	}
	);
	list::List{ir::Ref} new_body;
	new_body.init(allocator);
	for (sz i = 0; i < call_pos; i++) new_body.push(editor.body.entries[i]);
	new_body.push(caller_jump);
	new_body.push_all(cloned_body.array_view());
	new_body.push(continuation_label);
	if (returns_value && return_inputs.len() > 1) new_body.push(result_phi);
	for (sz i = call_pos + 1; i < editor.body.len(); i++) new_body.push(editor.body.entries[i]);
	editor.body.free();
	editor.body = new_body;
	sz alloc_pos = inline_entry_alloc_position(&editor);
	for (usz i = 0; i < (usz)cloned_allocs.len(); i++) editor.insert_body(alloc_pos++, cloned_allocs.entries[(sz)i]);

	// The old block's suffix now starts at the continuation, so PHIs in its
	// former successors must name the continuation as their predecessor.
	ir::Ref block_label = ir::NONE;
	foreach (ref : editor.body)
	{
		if ((usz)ref >= (usz)editor.insts.len()) continue;
		ir::Inst* inst = &editor.insts.entries[(sz)ref];
		if (inst.tag == ir::InstTag.LABEL) block_label = ref;
		if (inst.tag != ir::InstTag.PHI || block_label == ir::NONE || (usz)block_label >= (usz)successor_targets.len || !successor_targets[(sz)block_label]) continue;
		foreach (i, input : inst.data.phi)
		{
			if (input.label == caller_block_label) inst.data.phi[(sz)i].label = continuation_label;
		}
	}
	if (result_phi != ir::NONE) editor_replace_all_uses(&editor, call_ref, result_phi);
	inline_retire_unused_call_symbol(&editor, call_func_ref);
	editor.commit();
	return true;
}

<* Inline direct same-IR calls after callees have been processed. *>
fn bool inline_calls(ir::Ir* graph, OptOptions opts, Allocator allocator)
{
	usz threshold;
	switch (opts.level)
	{
		case code_gen_options::OptimizationLevel.O2: threshold = 40;
		case code_gen_options::OptimizationLevel.O3:
		case code_gen_options::OptimizationLevel.FAST: threshold = 120;
		default: return false;
	}
	InlineCallGraph calls = build_inline_call_graph(graph, allocator);
	defer calls.free();
	bool changed = false;
	foreach (decl_index : calls.bottom_up)
	{
		ir::Decl* caller = &graph.decls.entries[(sz)decl_index];
		if (caller.kind != ir::DeclKind.FUNCTION || caller.body.len == 0) continue;
		list::List{ir::Ref} worklist;
		worklist.init(allocator);
		foreach (ref : caller.body)
		{
			if ((usz)ref < (usz)caller.instructions.len && caller.instructions[(sz)ref].tag == ir::InstTag.CALL) worklist.push(ref);
		}
		foreach (call_ref : worklist)
		{
			if ((usz)call_ref >= (usz)caller.instructions.len || !inline_body_contains(caller, call_ref)) continue;
			ir::Inst* call = &caller.instructions[(sz)call_ref];
			if (call.tag != ir::InstTag.CALL || (usz)call.data.call.func >= (usz)caller.instructions.len) continue;
			ir::Inst* func = &caller.instructions[(sz)call.data.call.func];
			if (func.tag != ir::InstTag.SYMBOL) continue;
			// Calls to external symbols (including C99 external `inline` definitions,
			// which gen_ir does not emit) stay unresolved SYMBOLs.
			uint callee_index = inline_decl_index(&calls.decl_indices, func.data.label);
			if (callee_index == NONE_BLOCK || calls.scc[(sz)callee_index] == calls.scc[(sz)decl_index]) continue;
			ir::Decl* callee = &graph.decls.entries[(sz)callee_index];
			if (callee.kind != ir::DeclKind.FUNCTION || callee.body.len == 0 || inline_unsupported_control(callee)) continue;
			if (inline_arg_count(callee) != (usz)call.data.call.args.len) continue;
			usz cost = inline_body_cost(callee);
			bool one_call_internal = callee.linkage == ir::Linkage.INTERNAL && calls.call_count[(sz)callee_index] == 1;
			if (cost > threshold && !one_call_internal) continue;
			changed = inline_one_call(graph, caller, callee, call_ref, allocator) || changed;
		}
		worklist.free();
	}
	return changed;
}

fn bool verify_error(ir::ErrorList* errors, String name, String message)
{
	errors.put(name, string::format(errors.allocator, "verify: %s", message));
	return false;
}

fn bool valid_ref(ir::Decl* decl, ir::Ref ref) => ref != ir::NONE && (usz)ref < (usz)decl.instructions.len;

fn bool verify_decl(ir::Decl* decl, Allocator allocator, ir::ErrorList* errors)
{
	if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return true;
	usz inst_count = decl.instructions.len;
	usz body_len = decl.body.len;
	bool[] placed = alloc::new_array(allocator, bool, (sz)inst_count);
	defer alloc::free(allocator, placed.ptr);
	uint[] body_position = alloc::new_array(allocator, uint, (sz)inst_count);
	defer alloc::free(allocator, body_position.ptr);
	for (usz i = 0; i < inst_count; i++)
	{
		placed[i] = false; body_position[i] = NONE_BLOCK;
	}
	for (usz i = 0; i < body_len; i++)
	{
		ir::Ref ref = decl.body[i];
		if (!valid_ref(decl, ref)) return verify_error(errors, decl.name, "body contains an invalid instruction ref");
		if (placed[(sz)ref]) return verify_error(errors, decl.name, "body places an instruction more than once");
		placed[(sz)ref] = true;
		body_position[(sz)ref] = (uint)i;
	}
	usz arg_end = 0;
	while (arg_end < body_len && decl.instructions[(sz)decl.body[arg_end]].tag == ir::InstTag.ARG) arg_end++;
	if (arg_end == body_len || decl.instructions[(sz)decl.body[arg_end]].tag != ir::InstTag.LABEL)
	{
		return verify_error(errors, decl.name, "function body must place ARG instructions before its entry LABEL");
	}
	for (usz i = 0; i < arg_end; i++)
	{
		ir::Inst arg = decl.instructions[(sz)decl.body[i]];
		if (arg.data.arg.location_kind == ir::ArgLocationKind.GP_REGISTER && arg.data.arg.location >= 6)
		{
			return verify_error(errors, decl.name, "ARG GP register index is out of range");
		}
		if (arg.data.arg.location_kind == ir::ArgLocationKind.SSE_REGISTER && arg.data.arg.location >= 8)
		{
			return verify_error(errors, decl.name, "ARG SSE register index is out of range");
		}
		if (arg.data.arg.location_kind == ir::ArgLocationKind.STACK &&
			(arg.data.arg.location % 8 != 0 || arg.data.arg.stack_size < 8 ||
			arg.data.arg.stack_size % 8 != 0 || arg.data.arg.stack_size > (uint)(int::max - 16) ||
			arg.data.arg.location > (uint)(int::max - 16) - arg.data.arg.stack_size))
		{
			return verify_error(errors, decl.name, "ARG stack location or size is invalid");
		}
		if (arg.data.arg.location_kind != ir::ArgLocationKind.ORDINAL &&
			arg.data.arg.location_kind != ir::ArgLocationKind.GP_REGISTER &&
			arg.data.arg.location_kind != ir::ArgLocationKind.SSE_REGISTER &&
			arg.data.arg.location_kind != ir::ArgLocationKind.STACK)
		{
			return verify_error(errors, decl.name, "ARG location kind is invalid");
		}
		if (arg.data.arg.stack_address && arg.data.arg.location_kind != ir::ArgLocationKind.STACK)
		{
			return verify_error(errors, decl.name, "ARG stack_address requires an incoming stack location");
		}
		if (arg.data.arg.location_kind != ir::ArgLocationKind.STACK && arg.data.arg.stack_size != 0)
		{
			return verify_error(errors, decl.name, "ARG stack_size requires an incoming stack location");
		}
	}
	bool[] label_seen = alloc::new_array(allocator, bool, (sz)inst_count);
	defer alloc::free(allocator, label_seen.ptr);
	for (usz i = 0; i < inst_count; i++) label_seen[i] = false;
	usz block_start = arg_end;
	bool has_non_phi = false;
	bool block_terminated = false;
	for (usz i = arg_end; i < body_len; i++)
	{
		ir::Ref ref = decl.body[i];
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL &&
			(inst.data.call.stack_only.len != inst.data.call.args.len ||
			inst.data.call.memory_copy_bytes.len != inst.data.call.args.len))
		{
			return verify_error(errors, decl.name, "CALL argument metadata must match the argument count");
		}
		if (inst.tag == ir::InstTag.CALL_HI)
		{
			if (i == 0 || inst.data.ref != decl.body[i - 1] ||
				(usz)inst.data.ref >= inst_count || decl.instructions[(sz)inst.data.ref].tag != ir::InstTag.CALL)
			{
				return verify_error(errors, decl.name, "CALL_HI must immediately follow its referenced CALL");
			}
			if (inst.ty != value_interner::REF_I64)
			{
				return verify_error(errors, decl.name, "CALL_HI result must be i64");
			}
		}
		if (inst.tag == ir::InstTag.RET_PAIR)
		{
			if ((usz)inst.data.bin.lhs >= inst_count || (usz)inst.data.bin.rhs >= inst_count ||
				decl.instructions[(sz)inst.data.bin.lhs].ty != value_interner::REF_I64 ||
				decl.instructions[(sz)inst.data.bin.rhs].ty != value_interner::REF_I64)
			{
				return verify_error(errors, decl.name, "RET_PAIR operands must be i64");
			}
		}
		if (i == arg_end && inst.tag != ir::InstTag.LABEL)
		{
			return verify_error(errors, decl.name, "entry block must begin with a LABEL");
		}
		if (inst.tag == ir::InstTag.LABEL)
		{
			if (label_seen[(sz)ref]) return verify_error(errors, decl.name, "LABEL ref is placed more than once");
			label_seen[(sz)ref] = true;
			block_start = i;
			has_non_phi = false;
			block_terminated = false;
			continue;
		}
		if (inst.tag == ir::InstTag.ARG || inst.tag == ir::InstTag.CONSTANT || inst.tag == ir::InstTag.SYMBOL)
		{
			return verify_error(errors, decl.name, "ARG, CONSTANT, and SYMBOL instructions cannot appear in a block body");
		}
		// Instructions after a terminator are dead placements. The optimizer will
		// discard them; they do not change the block's PHI ordering or control flow.
		if (block_terminated) continue;
		if (inst.tag == ir::InstTag.PHI)
		{
			if (has_non_phi) return verify_error(errors, decl.name, "PHI appears after a non-PHI instruction");
		}
		else
		{
			has_non_phi = true;
		}
		if (is_terminator(inst.tag)) block_terminated = true;
	}
	bool final_block_terminated = false;
	for (usz i = block_start + 1; i < body_len; i++)
	{
		ir::Ref ref = decl.body[i];
		if (is_terminator(decl.instructions[(sz)ref].tag))
		{
			final_block_terminated = true;
			break;
		}
	}
	if (!final_block_terminated) return verify_error(errors, decl.name, "final basic block does not end in a terminator");
	Cfg cfg = build_cfg(decl, allocator);
	defer cfg.free();
	cfg.compute_dominators();
	foreach (user_ref : decl.body)
	{
		ir::Inst* inst = &decl.instructions[(sz)user_ref];
		bool bad_label = false;
		@each_label_operand(inst; ir::Ref* slot)
		{
			if (!valid_ref(decl, *slot) || decl.instructions[(sz)*slot].tag != ir::InstTag.LABEL || !label_seen[(sz)*slot]) bad_label = true;
		};
		if (bad_label) return verify_error(errors, decl.name, "label operand does not name a placed LABEL");
		bool bad_value = false;
		@each_value_operand(inst; ir::Ref* slot)
		{
			if (!valid_ref(decl, *slot) || !is_value_tag(decl.instructions[(sz)*slot].tag)) bad_value = true;
		};
		if (bad_value) return verify_error(errors, decl.name, "value operand is invalid or refers to a non-value instruction");
	}
	for (usz block_index = 0; block_index < cfg.blocks.len; block_index++)
	{
		CfgBlock* block = &cfg.blocks[block_index];
		sz executable_end = block_executable_end(decl, block);
		for (sz i = block.start + 1; i < executable_end; i++)
		{
			ir::Ref ref = decl.body[i];
			ir::Inst* inst = &decl.instructions[(sz)ref];
			if (inst.tag != ir::InstTag.PHI) continue;
			// Unreachable blocks need not have complete PHIs. SCCP also removes
			// inputs on non-executable edges before unreachable blocks are pruned.
			if (cfg.reachable[block_index])
			{
				foreach (pred : block.preds)
				{
					if (!cfg.reachable[(sz)pred]) continue;
					bool present = false;
					foreach (input : inst.data.phi) if (input.label == cfg.blocks[(sz)pred].label) present = true;
					if (!present) return verify_error(errors, decl.name, "PHI is missing a reachable predecessor input");
				}
			}
			foreach (input_index, input : inst.data.phi)
			{
				for (sz prior = 0; prior < input_index; prior++)
				{
					if (inst.data.phi[prior].label == input.label) return verify_error(errors, decl.name, "PHI has duplicate predecessor inputs");
				}
				if (decl.instructions[(sz)input.value].ty != inst.ty) return verify_error(errors, decl.name, "PHI input type does not match its result type");
				uint pred = cfg.block_of_ref[(sz)input.label];
				bool found = false;
				foreach (candidate : block.preds) if (candidate == pred) found = true;
				if (!found) return verify_error(errors, decl.name, "PHI input label is not a predecessor of its block");
			}
		}
	}
	for (usz block_index = 0; block_index < cfg.blocks.len; block_index++)
	{
		if (!cfg.reachable[block_index]) continue;
		CfgBlock* block = &cfg.blocks[block_index];
		sz executable_end = block_executable_end(decl, block);
		for (sz i = block.start + 1; i < executable_end; i++)
		{
			ir::Ref user_ref = decl.body[i];
			ir::Inst* inst = &decl.instructions[(sz)user_ref];
			if (inst.tag == ir::InstTag.PHI)
			{
				foreach (input : inst.data.phi)
				{
					ir::Ref value_ref = input.value;
					ir::InstTag def_tag = decl.instructions[(sz)value_ref].tag;
					if (def_tag == ir::InstTag.CONSTANT || def_tag == ir::InstTag.SYMBOL) continue;
					if (def_tag == ir::InstTag.ARG)
					{
						if (!placed[(sz)value_ref] || body_position[(sz)value_ref] >= (uint)arg_end)
						{
							return verify_error(errors, decl.name, "PHI operand refers to an unplaced ARG");
						}
						continue;
					}
					uint pred = cfg.block_of_ref[(sz)input.label];
					uint def_block = cfg.block_of_ref[(sz)value_ref];
					if (!cfg.reachable[(sz)pred]) continue;
					if (def_block == NONE_BLOCK || !cfg.dominates(def_block, pred))
					{
						return verify_error(errors, decl.name, "PHI value definition does not dominate the end of its predecessor block");
					}
					if (def_block == pred && body_position[(sz)value_ref] >= (uint)block_terminator_position(decl, &cfg.blocks[(sz)pred]))
					{
						return verify_error(errors, decl.name, "PHI value definition appears after its predecessor terminator");
					}
				}
				continue;
			}
			bool bad_dom = false;
			@each_value_operand(inst; ir::Ref* slot)
			{
				ir::Ref value_ref = *slot;
				ir::InstTag def_tag = decl.instructions[(sz)value_ref].tag;
				if (def_tag == ir::InstTag.CONSTANT || def_tag == ir::InstTag.SYMBOL)
				{
					// Constants and symbols are globally available.
				}
				else if (def_tag == ir::InstTag.ARG)
				{
					if (!placed[(sz)value_ref] || body_position[(sz)value_ref] >= arg_end) bad_dom = true;
				}
				else
				{
					uint def_block = cfg.block_of_ref[(sz)value_ref];
					if (def_block == NONE_BLOCK || !cfg.dominates(def_block, (uint)block_index))
					{
						bad_dom = true;
					}
					else if (def_block == block_index && body_position[(sz)value_ref] >= (uint)i)
					{
						bad_dom = true;
					}
				}
			};
			if (bad_dom) return verify_error(errors, decl.name, "value definition does not dominate its use");
		}
	}
	return true;
}

<* Verify function IR invariants; non-function declarations are skipped. *>
fn bool verify(ir::Ir* graph, ir::ErrorList* errors)
{
	foreach (&decl : graph.decls)
	{
		if (!verify_decl(decl, graph.allocator, errors)) return false;
	}
	return true;
}

<* Fixed pass pipeline entry point. *>
fn void? run(ir::Ir* graph, OptOptions opts, ir::ErrorList* errors)
{
	if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
	switch (opts.level)
	{
		case code_gen_options::OptimizationLevel.O0: return;
		case code_gen_options::OptimizationLevel.O1:
		case code_gen_options::OptimizationLevel.O2:
		case code_gen_options::OptimizationLevel.O3:
		case code_gen_options::OptimizationLevel.S:
		case code_gen_options::OptimizationLevel.FAST:
		case code_gen_options::OptimizationLevel.G:
		case code_gen_options::OptimizationLevel.Z:
			eliminate_dead_declarations(graph, opts.whole_program, opts.keep_external_definitions);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) remove_unreachable_blocks(decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) mem2reg(graph, decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) integer_simplify(graph, decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) early_cse(graph, decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) const_prop(graph, decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) remove_unreachable_blocks(decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) simplify_cfg(decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) integer_simplify(graph, decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			foreach (&decl : graph.decls) dead_instruction_elim(decl, graph.allocator);
			if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			if (opts.level == code_gen_options::OptimizationLevel.O2 ||
				opts.level == code_gen_options::OptimizationLevel.O3 ||
				opts.level == code_gen_options::OptimizationLevel.FAST)
			{
				inline_calls(graph, opts, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) remove_unreachable_blocks(decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) mem2reg(graph, decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) integer_simplify(graph, decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) early_cse(graph, decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) const_prop(graph, decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) remove_unreachable_blocks(decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) simplify_cfg(decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) integer_simplify(graph, decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				foreach (&decl : graph.decls) dead_instruction_elim(decl, graph.allocator);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
				dead_function_elim(graph, opts.whole_program, opts.keep_external_definitions);
				if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
			}
	}
}
