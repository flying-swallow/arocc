// IR optimization passes, analyses, and verifier.
module aro::backend::ir_opt;
import std::sort;
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
	<* `-fno-tree-vectorize` / `-fno-vectorize`: skip `loop_vectorize`. *>
	bool no_vectorize;
	<* Explicit native ABI calls are not yet eligible for signature rewriting. *>
	bool no_ipo;
	<* Compact sparse functions between passes (see `compact`). This renumbers
	   instructions, invalidating every Ref held outside the IR, so only callers
	   that keep no Refs across `run` (the driver) set it. *>
	bool compact;
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
		case FABS:
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
		case VSPLAT:
		case VREDUCE_ADD:
		case JMP_VAL: // the indirect jump target address
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
		case VEXTRACT:
		case VSHUFFLE:
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
		case LABEL_ADDR: // names the block whose address it takes (LLVM blockaddress)
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
		case VSPLAT:
		case VEXTRACT:
		case VSHUFFLE:
		case VREDUCE_ADD:
		case CONSTANT:
		case ARG:
		case SYMBOL:
		case LABEL:
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
		case FABS:
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
	<* Dominator-tree DFS entry/exit numbers: a dominates b iff b's interval nests
	   in a's. Makes `dominates` O(1) instead of an idom-chain walk. *>
	uint[] dom_pre;
	uint[] dom_post;
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
	if (self.dom_pre.len) alloc::free(self.allocator, self.dom_pre.ptr);
	if (self.dom_post.len) alloc::free(self.allocator, self.dom_post.ptr);
	*self = {};
}

struct DfsFrame
{
	uint block; sz next_succ;
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

<* Leading ARG run: blocks start after it. *>
fn usz cfg_arg_end(ir::Decl* decl)
{
	usz inst_count = decl.instructions.len;
	usz arg_end = 0;
	while (arg_end < decl.body.len)
	{
		ir::Ref ref = decl.body[arg_end];
		if ((usz)ref >= inst_count || decl.instructions[(sz)ref].tag != ir::InstTag.ARG) break;
		arg_end++;
	}
	return arg_end;
}

fn usz cfg_count_blocks(ir::Decl* decl, usz arg_end)
{
	usz inst_count = decl.instructions.len;
	usz block_count = 0;
	for (usz i = arg_end; i < decl.body.len; i++)
	{
		ir::Ref ref = decl.body[i];
		if ((usz)ref < inst_count && decl.instructions[(sz)ref].tag == ir::InstTag.LABEL) block_count++;
	}
	return block_count;
}

<* Fill block ranges and `block_of_ref` (sized to the instruction count and
   reset to NONE_BLOCK by the caller). With `check`, the blocks keep their
   labels and the call fails when the body's label sequence differs. *>
fn bool cfg_assign_layout(Cfg* cfg, ir::Decl* decl, usz arg_end, bool check)
{
	usz inst_count = decl.instructions.len;
	usz body_len = decl.body.len;
	usz block_index = 0;
	for (usz i = arg_end; i < body_len; i++)
	{
		ir::Ref ref = decl.body[i];
		if ((usz)ref >= inst_count) continue;
		if (decl.instructions[(sz)ref].tag == ir::InstTag.LABEL)
		{
			if (block_index > 0) cfg.blocks[block_index - 1].end = (sz)i;
			CfgBlock* block = &cfg.blocks[block_index];
			if (check && block.label != ref) return false;
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
	return true;
}

<* Visit each distinct control-flow edge in build order: per source block, in
   terminator operand order (fallthrough when the block has no terminator).
   Needs the block layout. `edge_from[to] == from` dedupes in O(1) because every
   edge of one source is produced before the next source (a switch with
   thousands of labels would otherwise rescan its successor list). *>
macro @cfg_each_edge(Cfg* cfg; @body(uint from, uint to))
{
	@pool()
	{
		ir::Decl* decl = cfg.decl;
		Allocator allocator = cfg.allocator;
		usz inst_count = decl.instructions.len;
		usz block_count = cfg.blocks.len;
		uint[] edge_from = alloc::new_array(tmem, uint, (sz)block_count);
		for (usz i = 0; i < block_count; i++) edge_from[i] = NONE_BLOCK;
		// Like LLVM indirectbr, a computed goto may reach any block whose address the
		// function takes (LABEL_ADDR); C forbids jumping into another function.
		list::List{uint} address_taken;
		address_taken.init(allocator, 0);
		defer address_taken.free();
		for (usz i = 0; i < decl.body.len; i++)
		{
			ir::Ref ref = decl.body[i];
			if ((usz)ref >= inst_count || decl.instructions[(sz)ref].tag != ir::InstTag.LABEL_ADDR) continue;
			ir::Ref label = decl.instructions[(sz)ref].data.ref;
			if ((usz)label >= inst_count || cfg.block_of_ref[(sz)label] == NONE_BLOCK) continue;
			uint target = cfg.block_of_ref[(sz)label];
			bool seen = false;
			foreach (old : address_taken) if (old == target) seen = true;
			if (!seen) address_taken.push(target);
		}
		foreach (i, &block : cfg.blocks)
		{
			uint from = (uint)i;
			sz terminator_pos = block_terminator_position(decl, block);
			if (terminator_pos == block.end)
			{
				if (i + 1 < cfg.blocks.len)
				{
					uint to = (uint)(i + 1);
					if (edge_from[(sz)to] != from) { edge_from[(sz)to] = from; @body(from, to); }
				}
				continue;
			}
			ir::Ref terminator_ref = decl.body[terminator_pos];
			if ((usz)terminator_ref >= inst_count) continue;
			ir::Inst* inst = &decl.instructions[(sz)terminator_ref];
			if (inst.tag == ir::InstTag.JMP_VAL)
			{
				foreach (to : address_taken)
				{
					if (edge_from[(sz)to] != from) { edge_from[(sz)to] = from; @body(from, to); }
				}
				continue;
			}
			if (inst.tag != ir::InstTag.JMP && inst.tag != ir::InstTag.BRANCH && inst.tag != ir::InstTag.SWITCH) continue;
			// JMP, BRANCH (then, else) and SWITCH (cases, default) list their
			// targets in that order as label operands.
			@each_label_operand(inst; ir::Ref* slot)
			{
				ir::Ref label = *slot;
				if ((usz)label < inst_count && cfg.block_of_ref[(sz)label] != NONE_BLOCK)
				{
					uint to = cfg.block_of_ref[(sz)label];
					if (edge_from[(sz)to] != from) { edge_from[(sz)to] = from; @body(from, to); }
				}
			};
		}
	};
}

<* Build block ranges, control-flow edges, reachability and entry-rooted RPO. *>
fn Cfg build_cfg(ir::Decl* decl, Allocator allocator)
{
	@pool()
	{
		Cfg cfg = { .allocator = allocator, .decl = decl };
		usz inst_count = decl.instructions.len;
		cfg.block_of_ref = alloc::new_array(allocator, uint, (sz)inst_count);
		for (usz i = 0; i < inst_count; i++) cfg.block_of_ref[i] = NONE_BLOCK;
		usz arg_end = cfg_arg_end(decl);
		usz block_count = cfg_count_blocks(decl, arg_end);
		cfg.blocks = alloc::new_array(allocator, CfgBlock, (sz)block_count);
		for (usz i = 0; i < block_count; i++)
		{
			cfg.blocks[i].preds.init(allocator);
			cfg.blocks[i].succs.init(allocator);
			cfg.blocks[i].frontier.init(allocator);
			cfg.blocks[i].dom_children.init(allocator);
		}
		cfg_assign_layout(&cfg, decl, arg_end, false);
		@cfg_each_edge(&cfg; uint from, uint to)
		{
			cfg.blocks[(sz)from].succs.push(to);
			cfg.blocks[(sz)to].preds.push(from);
		};
		cfg.reachable = alloc::new_array(allocator, bool, (sz)block_count);
		if (block_count)
		{
			bool[] visited = alloc::new_array(tmem, bool, (sz)block_count);
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
	};
}

<* After an edit, refresh the layout (block ranges, `block_of_ref`) in place
   and report whether the block-indexed shape still holds: same label sequence
   and the exact same successor lists. When true, preds, RPO, reachability,
   dominators, frontiers and loops computed from this CFG remain valid. When
   false the layout is half-updated and the CFG must be rebuilt. *>
fn bool Cfg.revalidate(&self)
{
	@pool()
	{
		ir::Decl* decl = self.decl;
		usz arg_end = cfg_arg_end(decl);
		if (cfg_count_blocks(decl, arg_end) != self.blocks.len) return false;
		usz inst_count = decl.instructions.len;
		if (self.block_of_ref.len != inst_count)
		{
			if (self.block_of_ref.len) alloc::free(self.allocator, self.block_of_ref.ptr);
			self.block_of_ref = alloc::new_array(self.allocator, uint, (sz)inst_count);
		}
		for (usz i = 0; i < inst_count; i++) self.block_of_ref[i] = NONE_BLOCK;
		if (!cfg_assign_layout(self, decl, arg_end, true)) return false;
		usz block_count = self.blocks.len;
		if (!block_count) return true;
		uint[] cursor = alloc::new_array(tmem, uint, (sz)block_count);
		cursor[..] = 0;
		bool same = true;
		@cfg_each_edge(self; uint from, uint to)
		{
			list::List{uint}* succs = &self.blocks[(sz)from].succs;
			uint at = cursor[(sz)from]++;
			if ((sz)at >= succs.len() || succs.entries[(sz)at] != to) same = false;
		};
		if (!same) return false;
		foreach (i, &block : self.blocks)
		{
			if ((sz)cursor[i] != block.succs.len()) return false;
		}
		return true;
	};
}

<* Cooper-Harvey-Kennedy iterative immediate dominators in reverse postorder. *>
fn void Cfg.compute_dominators(&self)
{
	if (self.idom.len) alloc::free(self.allocator, self.idom.ptr);
	if (self.rpo_position.len) alloc::free(self.allocator, self.rpo_position.ptr);
	if (self.dom_pre.len) alloc::free(self.allocator, self.dom_pre.ptr);
	if (self.dom_post.len) alloc::free(self.allocator, self.dom_post.ptr);
	self.dom_pre = {};
	self.dom_post = {};
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
	// Number the dominator tree with an explicit stack (trees can be thousands deep).
	self.dom_pre = alloc::new_array(self.allocator, uint, n);
	self.dom_post = alloc::new_array(self.allocator, uint, n);
	for (uint i = 0; i < n; i++) { self.dom_pre[(sz)i] = NONE_BLOCK; self.dom_post[(sz)i] = NONE_BLOCK; }
	list::List{ulong} stack;
	stack.init(self.allocator, 0);
	defer stack.free();
	uint clock = 0;
	stack.push((ulong)entry << 32);
	while (stack.len())
	{
		ulong frame = stack.pop()!!;
		uint block_index = (uint)(frame >> 32);
		uint child = (uint)frame;
		if (child == 0) self.dom_pre[(sz)block_index] = clock++;
		list::List{uint}* children = &self.blocks[(sz)block_index].dom_children;
		if (child < children.len())
		{
			stack.push(((ulong)block_index << 32) | (ulong)(child + 1));
			stack.push((ulong)children.entries[(sz)child] << 32);
			continue;
		}
		self.dom_post[(sz)block_index] = clock++;
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
	if (self.dom_pre.len)
	{
		if (self.dom_pre[(sz)a] == NONE_BLOCK || self.dom_pre[(sz)b] == NONE_BLOCK) return false;
		return self.dom_pre[(sz)a] <= self.dom_pre[(sz)b] && self.dom_post[(sz)b] <= self.dom_post[(sz)a];
	}
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

<* Immutable def-use snapshot in compressed (CSR) form: the users of ref `r` are
   `flat[offsets[r]:offsets[r + 1] - offsets[r]]`, in body order, one entry per
   operand use. Two allocations regardless of function size. Passes that add
   use edges while iterating keep their own overflow (see `UseOverflow`). *>
struct Uses
{
	Allocator allocator;
	<* `count() + 1` entries; empty when the decl has no instructions. *>
	uint[] offsets;
	ir::Ref[] flat;
}

fn void Uses.free(&self)
{
	if (self.offsets.len) alloc::free(self.allocator, self.offsets.ptr);
	if (self.flat.len) alloc::free(self.allocator, self.flat.ptr);
	*self = {};
}

<* Number of refs covered (the decl's instruction count when computed). *>
fn usz Uses.count(&self) @inline => self.offsets.len ? self.offsets.len - 1 : 0;

<* Users of `ref`, in body order; empty for refs outside the snapshot. *>
fn ir::Ref[] Uses.of(&self, ir::Ref ref) @inline
{
	if ((usz)ref >= self.count()) return {};
	uint start = self.offsets[(sz)ref];
	return self.flat[(sz)start:(sz)(self.offsets[(sz)ref + 1] - start)];
}

<* Build per-reference user lists over placed instructions (one entry per operand use). *>
fn Uses compute_uses(ir::Decl* decl, Allocator allocator)
{
	Uses uses = { .allocator = allocator };
	usz n = (usz)decl.instructions.len;
	if (!n) return uses;
	uses.offsets = alloc::new_array(allocator, uint, (sz)n + 1);
	uses.offsets[..] = 0;
	// Pass 1: count uses per ref into offsets[ref + 1].
	foreach (user_ref : decl.body)
	{
		if ((usz)user_ref >= n) continue;
		@each_value_operand(&decl.instructions[(sz)user_ref]; ir::Ref* slot)
		{
			if (*slot != ir::NONE && (usz)*slot < n) uses.offsets[(sz)*slot + 1]++;
		};
	}
	for (usz i = 1; i <= n; i++) uses.offsets[i] += uses.offsets[i - 1];
	uint total = uses.offsets[n];
	if (!total) return uses;
	uses.flat = alloc::new_array(allocator, ir::Ref, total);
	// Pass 2: fill, using offsets[ref] as the write cursor; afterwards each
	// cursor sits at its ref's end, so shift back by one slot to restore starts.
	foreach (user_ref : decl.body)
	{
		if ((usz)user_ref >= n) continue;
		@each_value_operand(&decl.instructions[(sz)user_ref]; ir::Ref* slot)
		{
			if (*slot != ir::NONE && (usz)*slot < n) uses.flat[(sz)uses.offsets[(sz)*slot]++] = user_ref;
		};
	}
	for (usz i = n; i > 0; i--) uses.offsets[i] = uses.offsets[i - 1];
	uses.offsets[0] = 0;
	return uses;
}

struct UseLink
{
	ir::Ref user;
	uint next;
}

<* Use edges added after a `Uses` snapshot, as per-ref singly linked chains in
   one pool (tail-appended, so iteration follows insertion order). *>
struct UseOverflow
{
	Allocator allocator;
	uint[] head;
	uint[] tail;
	list::List{UseLink} links;
}

const uint USE_LINK_END = uint::max;

fn void UseOverflow.init(&self, usz count, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.links.init(allocator, 0);
	if (!count) return;
	self.head = alloc::new_array(allocator, uint, (sz)count);
	self.tail = alloc::new_array(allocator, uint, (sz)count);
	self.head[..] = USE_LINK_END;
	self.tail[..] = USE_LINK_END;
}

fn void UseOverflow.free(&self)
{
	if (self.head.len) alloc::free(self.allocator, self.head.ptr);
	if (self.tail.len) alloc::free(self.allocator, self.tail.ptr);
	self.links.free();
	*self = {};
}

fn void UseOverflow.push(&self, ir::Ref ref, ir::Ref user)
{
	if ((usz)ref >= (usz)self.head.len) return;
	uint index = (uint)self.links.len();
	self.links.push({ .user = user, .next = USE_LINK_END });
	if (self.tail[(sz)ref] == USE_LINK_END) { self.head[(sz)ref] = index; }
	else { self.links.entries[(sz)self.tail[(sz)ref]].next = index; }
	self.tail[(sz)ref] = index;
}

<* Visit the snapshot users of `ref`, then the overflow users added since. *>
macro @each_user(Uses* uses, UseOverflow* extra, ir::Ref ref; @body(ir::Ref user))
{
	foreach (u : uses.of(ref)) @body(u);
	if ((usz)ref < (usz)extra.head.len)
	{
		for (uint link = extra.head[(sz)ref]; link != USE_LINK_END; link = extra.links.entries[(sz)link].next)
		{
			@body(extra.links.entries[(sz)link].user);
		}
	}
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

fn void DeclEditor.begin(&self, ir::Decl* decl)
{
	// The edited lists live on the declaration's allocator so `commit` can
	// adopt their storage without another copy.
	*self = { .decl = decl };
	// Small headroom: most passes append a few instructions, and doubling on the
	// first append would leave up to 2x slack in the adopted storage.
	self.insts.init(decl.allocator, decl.instructions.len + decl.instructions.len / 8 + 8);
	self.insts.push_all(decl.instructions);
	self.body.init(decl.allocator, decl.body.len + decl.body.len / 8 + 8);
	self.body.push_all(decl.body);
}

fn void DeclEditor.free(&self)
{
	self.insts.free();
	self.body.free();
	*self = {};
}

<* Copy `inst`'s out-of-line payload (label name, PHI inputs, call arguments,
   switch tables) into `arena`. *>
fn ir::Inst copy_inst_payload_into(Allocator arena, ir::Inst inst)
{
	switch (inst.tag)
	{
		case ir::InstTag.LABEL:
		case ir::InstTag.SYMBOL:
			inst.data.label = inst.data.label.copy(arena);
		case ir::InstTag.PHI:
			ir::PhiInput[] inputs = alloc::new_array(arena, ir::PhiInput, inst.data.phi.len);
			inputs[..] = inst.data.phi[..];
			inst.data.phi = inputs;
		case ir::InstTag.CALL:
			ir::Ref[] args = alloc::new_array(arena, ir::Ref, inst.data.call.args.len);
			bool[] stack_only = alloc::new_array(arena, bool, inst.data.call.stack_only.len);
			uint[] memory_copy_bytes = alloc::new_array(arena, uint, inst.data.call.memory_copy_bytes.len);
			args[..] = inst.data.call.args[..];
			stack_only[..] = inst.data.call.stack_only[..];
			memory_copy_bytes[..] = inst.data.call.memory_copy_bytes[..];
			ir::ArgData[] locations = alloc::new_array(arena, ir::ArgData, inst.data.call.locations.len);
			locations[..] = inst.data.call.locations[..];
			inst.data.call.locations = locations;
			inst.data.call.args = args;
			inst.data.call.stack_only = stack_only;
			inst.data.call.memory_copy_bytes = memory_copy_bytes;
		case ir::InstTag.SWITCH:
			value_interner::InternerRef[] values = alloc::new_array(arena, value_interner::InternerRef, inst.data.switch_data.values.len);
			ir::Ref[] labels = alloc::new_array(arena, ir::Ref, inst.data.switch_data.labels.len);
			values[..] = inst.data.switch_data.values[..];
			labels[..] = inst.data.switch_data.labels[..];
			inst.data.switch_data.values = values;
			inst.data.switch_data.labels = labels;
		default: break;
	}
	return inst;
}

fn ir::Inst copy_inst_payload(ir::Decl* decl, ir::Inst inst) => copy_inst_payload_into(&decl.arena, inst);

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

<* Move a list's entries into an owned slice on the list's allocator and empty
   the list. Any slack is trimmed with a realloc shrink: the slice lives as long
   as the decl, so headroom left here is resident until the next compaction. *>
fn ir::Inst[] adopt_inst_storage(list::List{ir::Inst}* list)
{
	sz len = list.len();
	if (!len)
	{
		list.free();
		return (ir::Inst[]){};
	}
	ir::Inst* entries = list.entries;
	if (list.capacity != len) entries = alloc::realloc(list.allocator, entries, ir::Inst::size * len);
	*list = {};
	return entries[:len];
}

fn ir::Ref[] adopt_ref_storage(list::List{ir::Ref}* list)
{
	sz len = list.len();
	if (!len)
	{
		list.free();
		return (ir::Ref[]){};
	}
	ir::Ref* entries = list.entries;
	if (list.capacity != len) entries = alloc::realloc(list.allocator, entries, ir::Ref::size * len);
	*list = {};
	return entries[:len];
}

fn void DeclEditor.commit(&self)
{
	if (self.decl.instructions.len) alloc::free(self.decl.allocator, self.decl.instructions.ptr);
	if (self.decl.body.len) alloc::free(self.decl.allocator, self.decl.body.ptr);
	self.decl.instructions = adopt_inst_storage(&self.insts);
	self.decl.body = adopt_ref_storage(&self.body);
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
	@pool()
	{
		usz decl_count = (usz)graph.decls.len();
		if (decl_count == 0) return;
		bool[] reachable = alloc::new_array(tmem, bool, (sz)decl_count);
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
			// Decl.is_definition() treats every FUNCTION as a definition; declarations have no body.
			if (decl.kind == ir::DeclKind.FUNCTION && decl.name == "main" && decl.body.len != 0) has_main = true;
		}
		// Like LLVM GlobalDCE's llvm.used / llvm.global_ctors roots, `used` symbols and
		// constructors/destructors are always live, even internal ones.
		if (whole_program && has_main && !keep_external_definitions)
		{
			mark_decl_symbol(&decl_indices, reachable, &pending, "main");
		}
		foreach (i, decl : graph.decls)
		{
			bool root = decl.is_external_root() ||
				(!(whole_program && has_main && !keep_external_definitions) && decl.linkage == ir::Linkage.EXTERNAL);
			if (!root || reachable[(sz)i]) continue;
			reachable[(sz)i] = true;
			pending.push((uint)i);
		}

		// Follow references from each newly reached declaration.
		while (pending.len())
		{
			uint index = pending.pop()!!;
			ir::Decl* decl = &graph.decls.entries[(sz)index];
			if (decl.kind == ir::DeclKind.FUNCTION)
			{
				// Include unplaced tombstones too. LLVM removes dead constant users before
				// GlobalDCE, so its dependency walk can be more precise than this one.
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
	};
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
fn bool remove_unreachable_blocks(ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
		Cfg* cfg = analyses.get_cfg();
		if (cfg.blocks.len == 0) return false;

		bool[] remove = alloc::new_array(mem, bool, (sz)decl.instructions.len);
		defer alloc::free(mem, remove.ptr);
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
		// An address-taken block can be unreachable when no reachable computed goto
		// exists. Its address can then only be compared, never jumped to; replace it
		// with null so no LABEL_ADDR names a removed block (LLVM substitutes a
		// constant for such blockaddress uses too).
		foreach (ref : decl.body)
		{
			if ((usz)ref >= (usz)decl.instructions.len || remove[(sz)ref]) continue;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			if (inst.tag != ir::InstTag.LABEL_ADDR || (usz)inst.data.ref >= (usz)cfg.block_of_ref.len) continue;
			uint target = cfg.block_of_ref[(sz)inst.data.ref];
			if (target != NONE_BLOCK && cfg.reachable[(sz)target]) continue;
			// Constants are unplaced: rewrite in place and drop it from the body, so
			// its users now read the null constant.
			*inst = { .tag = ir::InstTag.CONSTANT, .data.constant = value_interner::REF_NULL, .ty = inst.ty };
			remove[(sz)ref] = true;
			changed = true;
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
					if ((usz)input.label >= (usz)cfg.block_of_ref.len) continue;
					uint pred = cfg.block_of_ref[(sz)input.label];
					if (pred == NONE_BLOCK || !cfg.reachable[(sz)pred]) continue;
					keep_count++;
				}
				if (keep_count != (usz)phi.data.phi.len)
				{
					ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, (sz)keep_count);
					sz write = 0;
					foreach (input : phi.data.phi)
					{
						if ((usz)input.label >= (usz)cfg.block_of_ref.len) continue;
						uint pred = cfg.block_of_ref[(sz)input.label];
						if (pred == NONE_BLOCK || !cfg.reachable[(sz)pred]) continue;
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
		editor.begin(decl);
		BodyRemovalContext context = { .remove = remove };
		editor.remove_body_where(&body_ref_marked_for_removal, (void*)&context);
		editor.commit();
		return true;
	};
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
	// Deferred load replacements, applied in one body walk after renaming.
	ir::Ref[] replacements;
}

fn ir::Ref mem2reg_resolve(ir::Ref[] replacements, ir::Ref ref)
{
	while ((usz)ref < (usz)replacements.len && replacements[(sz)ref] != ir::NONE) ref = replacements[(sz)ref];
	return ref;
}

fn void mem2reg_apply_replacements(DeclEditor* editor, ir::Ref[] replacements)
{
	foreach (user_ref : editor.body)
	{
		if ((usz)user_ref >= (usz)editor.insts.len()) continue;
		ir::Inst* inst = &editor.insts.entries[(sz)user_ref];
		@each_value_operand(inst; ir::Ref* slot) { *slot = mem2reg_resolve(replacements, *slot); };
	}
}

<* Lazily materialize the zero value used for paths that read before a store. *>
fn ir::Ref mem2reg_initial_zero(Mem2RegRenameContext* context)
{
	// LLVM seeds these reads with undef; C3 deliberately uses typed zero instead.
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
			context.replacements[(sz)ref] = current;
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
fn bool editor_cleanup_trivial_phis(DeclEditor* editor, bool[] remove, ir::Ref[] replacements)
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
				ir::Ref value = mem2reg_resolve(replacements, input.value);
				if (value == ref) continue;
				if (candidate == ir::NONE)
				{
					candidate = value;
				}
				else if (candidate != value)
				{
					conflict = true;
					break;
				}
			}
			if (candidate == ir::NONE || conflict) continue;
			replacements[(sz)ref] = candidate;
			remove[(sz)ref] = true;
			changed = true;
			any_changed = true;
		}
	}
	if (any_changed) mem2reg_apply_replacements(editor, replacements);
	return any_changed;
}

<* Remove mem2reg PHIs that are not reachable from a non-mem2reg-PHI use. *>
fn bool editor_cleanup_unused_mem2reg_phis(DeclEditor* editor, ir::Ref[] phi_for_block, bool[] remove)
{
	bool[] is_mem2reg_phi = alloc::new_array(tmem, bool, (sz)editor.insts.len());
	bool[] live = alloc::new_array(tmem, bool, (sz)editor.insts.len());
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
fn bool promote_alloca(ir::Ir* ir, ir::Decl* decl, ir::Ref alloc_ref)
{
	@pool()
	{
		if ((usz)alloc_ref >= (usz)decl.instructions.len || decl.instructions[(sz)alloc_ref].tag != ir::InstTag.ALLOC) return false;
		// Volatility is tracked per allocated object here, not per LOAD/STORE access.
		if (decl.instructions[(sz)alloc_ref].data.alloc.is_volatile) return false;
		Cfg cfg = build_cfg(decl, mem);
		defer cfg.free();
		if (cfg.blocks.len == 0 || cfg.block_of_ref[(sz)alloc_ref] == NONE_BLOCK) return false;
		uint[] body_position = alloc::new_array(tmem, uint, (sz)decl.instructions.len);
		for (usz i = 0; i < (usz)decl.instructions.len; i++) body_position[i] = NONE_BLOCK;
		foreach (pos, ref : decl.body)
		{
			if ((usz)ref < (usz)decl.instructions.len) body_position[(sz)ref] = (uint)pos;
		}
		cfg.compute_dominators();
		cfg.compute_frontiers();
		uint alloc_block = cfg.block_of_ref[(sz)alloc_ref];
		if (!cfg.reachable[(sz)alloc_block]) return false;

		Uses uses = compute_uses(decl, tmem);
		bool has_load = false;
		bool has_store = false;
		bool has_access_type = false;
		value_interner::InternerRef access_type = value_interner::REF_VOID;
		foreach (user_ref : uses.of(alloc_ref))
		{
			if ((usz)user_ref >= (usz)decl.instructions.len) return false;
			ir::Inst* user = &decl.instructions[(sz)user_ref];
			// Like LLVM's isAllocaPromotable, a volatile access pins the slot in memory.
			if (user.is_volatile_access()) return false;
			// LLVM leaves unvisited loads in place and resolves leftover alloca uses
			// with poison. Decline promotion while any load is outside executable code.
			if (user.tag == ir::InstTag.LOAD)
			{
				uint block = cfg.block_of_ref[(sz)user_ref];
				if (block == NONE_BLOCK || !cfg.reachable[(sz)block] || body_position[(sz)user_ref] == NONE_BLOCK) return false;
				if (body_position[(sz)user_ref] >= (uint)block_terminator_position(decl, &cfg.blocks[(sz)block])) return false;
			}
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
		if (!has_load)
		{
			// With no executable loads, the allocation and its direct accesses are unobserved.
			DeclEditor editor;
			editor.begin(decl);
			bool[] remove = alloc::new_array(mem, bool, (sz)editor.insts.len());
			defer alloc::free(mem, remove.ptr);
			for (sz i = 0; i < editor.insts.len(); i++) remove[i] = false;
			remove[(sz)alloc_ref] = true;
			foreach (user_ref : uses.of(alloc_ref)) remove[(sz)user_ref] = true;
			BodyRemovalContext context = { .remove = remove };
			editor.remove_body_where(&body_ref_marked_for_removal, (void*)&context);
			editor.commit();
			return true;
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
		uint allocation_size = decl.instructions[(sz)alloc_ref].data.alloc.size;
		// F80 has an 80-bit IR value stored in a padded 16-byte ABI object slot.
		// Promote direct scalar accesses to that slot like other scalars.
		bool padded_f80 = access_key.tag == primitive_value::PrimitiveType.FLOAT_TY &&
			access_key.ty_bits == 80 && allocation_size == 16;
		if (allocation_size != expected_size && !padded_f80) return false;
		bool[] def_blocks = alloc::new_array(tmem, bool, (sz)cfg.blocks.len);
		bool[] phi_sites = alloc::new_array(tmem, bool, (sz)cfg.blocks.len);
		for (usz i = 0; i < cfg.blocks.len; i++)
		{
			def_blocks[i] = false; phi_sites[i] = false;
		}
		foreach (user_ref : uses.of(alloc_ref))
		{
			ir::Inst* user = &decl.instructions[(sz)user_ref];
			if (user.tag != ir::InstTag.STORE || user.data.bin.lhs != alloc_ref) continue;
			uint block = cfg.block_of_ref[(sz)user_ref];
			if (block == NONE_BLOCK || !cfg.reachable[(sz)block]) return false;
			def_blocks[(sz)block] = true;
		}
		list::List{uint} worklist;
		worklist.init(mem);
		defer worklist.free();
		foreach (block : cfg.rpo) if (def_blocks[(sz)block]) worklist.push(block);
		while (worklist.len())
		{
			uint block = worklist.pop()!!;
			// LLVM prunes the IDF by live-in blocks; C3 builds the full IDF and
			// removes unused inserted PHIs after renaming.
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
		editor.begin(decl);
		ir::Ref[] phi_for_block = alloc::new_array(mem, ir::Ref, (sz)cfg.blocks.len);
		defer alloc::free(mem, phi_for_block.ptr);
		for (usz i = 0; i < cfg.blocks.len; i++) phi_for_block[i] = ir::NONE;
		foreach (block_index, has_phi : phi_sites)
		{
			if (!has_phi) continue;
			usz input_count = 0;
			foreach (pred : cfg.blocks[block_index].preds) if (cfg.reachable[(sz)pred]) input_count++;
			ir::PhiInput[] inputs = alloc::new_array(mem, ir::PhiInput, (sz)input_count);
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
			alloc::free(mem, inputs.ptr);
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

		bool[] remove = alloc::new_array(mem, bool, (sz)editor.insts.len());
		defer alloc::free(mem, remove.ptr);
		for (sz i = 0; i < editor.insts.len(); i++) remove[i] = false;
		remove[(sz)alloc_ref] = true;
		ir::Ref[] replacements = alloc::new_array(mem, ir::Ref, (sz)editor.insts.len());
		defer alloc::free(mem, replacements.ptr);
		for (sz i = 0; i < editor.insts.len(); i++) replacements[i] = ir::NONE;
		Mem2RegRenameContext context = {
			.editor = &editor,
			.cfg = &cfg,
			.alloc_ref = alloc_ref,
			.access_type = access_type,
			.zero_ref = ir::NONE,
			.phi_for_block = phi_for_block,
			.remove = remove,
			.replacements = replacements,
		};
		if (cfg.rpo.len == 0 || !mem2reg_rename_block(&context, cfg.rpo[0], ir::NONE))
		{
			editor.free();
			return false;
		}
		mem2reg_apply_replacements(&editor, replacements);
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
		foreach (user_ref : uses.of(alloc_ref))
		{
			ir::Inst* user = &editor.insts.entries[(sz)user_ref];
			if (user.tag == ir::InstTag.LOAD || user.tag == ir::InstTag.STORE) remove[(sz)user_ref] = true;
		}
		editor_cleanup_trivial_phis(&editor, remove, replacements);
		editor_cleanup_unused_mem2reg_phis(&editor, phi_for_block, remove);
		BodyRemovalContext removal_context = { .remove = remove };
		editor.remove_body_where(&body_ref_marked_for_removal, (void*)&removal_context);
		editor.commit();
		return true;
	};
}

enum Mem2RegClass : char
{
	REJECT,
	// No executable load: the slot and its stores are unobserved.
	REMOVE,
	PROMOTE,
	// Its address is stored into another slot; promoting that slot can change
	// this one's users, so decide after the batch commits.
	DEFER,
}

<* The exact acceptance checks of promote_alloca, against analyses shared by one
   batch (all built from the unedited body). *>
fn Mem2RegClass mem2reg_classify(ir::Ir* ir, ir::Decl* decl, Cfg* cfg, Uses* uses, uint[] body_position,
	sz[] terminator_position, ir::Ref alloc_ref, value_interner::InternerRef* out_type)
{
	if ((usz)alloc_ref >= uses.count() || decl.instructions[(sz)alloc_ref].tag != ir::InstTag.ALLOC) return REJECT;
	if (decl.instructions[(sz)alloc_ref].data.alloc.is_volatile) return REJECT;
	if (cfg.block_of_ref[(sz)alloc_ref] == NONE_BLOCK) return REJECT;
	if (!cfg.reachable[(sz)cfg.block_of_ref[(sz)alloc_ref]]) return REJECT;
	foreach (user_ref : uses.of(alloc_ref))
	{
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		if (user.tag == ir::InstTag.STORE && user.data.bin.rhs == alloc_ref) return DEFER;
	}
	bool has_load = false;
	bool has_access_type = false;
	value_interner::InternerRef access_type = value_interner::REF_VOID;
	foreach (user_ref : uses.of(alloc_ref))
	{
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		if (user.is_volatile_access()) return REJECT;
		if (user.tag == ir::InstTag.LOAD)
		{
			uint block = cfg.block_of_ref[(sz)user_ref];
			if (block == NONE_BLOCK || !cfg.reachable[(sz)block] || body_position[(sz)user_ref] == NONE_BLOCK) return REJECT;
			if ((sz)body_position[(sz)user_ref] >= terminator_position[(sz)block]) return REJECT;
		}
		value_interner::InternerRef user_type;
		if (user.tag == ir::InstTag.LOAD && user.data.ref == alloc_ref)
		{
			has_load = true;
			user_type = user.ty;
		}
		else if (user.tag == ir::InstTag.STORE && user.data.bin.lhs == alloc_ref && user.data.bin.rhs != alloc_ref)
		{
			if (!valid_ref(decl, user.data.bin.rhs)) return REJECT;
			user_type = decl.instructions[(sz)user.data.bin.rhs].ty;
		}
		else
		{
			return REJECT;
		}
		if (!has_access_type)
		{
			access_type = user_type;
			has_access_type = true;
		}
		else if (access_type != user_type)
		{
			return REJECT;
		}
	}
	if (!has_load) return REMOVE;
	primitive_value::PrimitiveValue access_key = ir.interner.get(access_type);
	uint expected_size;
	switch (access_key.tag)
	{
		case primitive_value::PrimitiveType.INT_TY:
		case primitive_value::PrimitiveType.FLOAT_TY:
			if (access_key.ty_bits == 0) return REJECT;
			expected_size = ((uint)access_key.ty_bits + 7) / 8;
		case primitive_value::PrimitiveType.PTR_TY:
			expected_size = 8;
		default:
			return REJECT;
	}
	uint allocation_size = decl.instructions[(sz)alloc_ref].data.alloc.size;
	bool padded_f80 = access_key.tag == primitive_value::PrimitiveType.FLOAT_TY &&
		access_key.ty_bits == 80 && allocation_size == 16;
	if (allocation_size != expected_size && !padded_f80) return REJECT;
	foreach (user_ref : uses.of(alloc_ref))
	{
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		if (user.tag != ir::InstTag.STORE || user.data.bin.lhs != alloc_ref) continue;
		uint block = cfg.block_of_ref[(sz)user_ref];
		if (block == NONE_BLOCK || !cfg.reachable[(sz)block]) return REJECT;
	}
	*out_type = access_type;
	return PROMOTE;
}

struct Mem2RegPhi
{
	uint slot;
	ir::Ref phi;
}

struct Mem2RegUndo
{
	uint slot;
	ir::Ref old;
}

struct Mem2RegBatch
{
	DeclEditor* editor;
	Cfg* cfg;
	ir::Decl* decl;
	<* Original ref -> promoted slot index, or uint::max. *>
	uint[] slot_of;
	value_interner::InternerRef[] slot_type;
	ir::Ref[] slot_zero;
	ir::Ref[] current;
	list::List{Mem2RegPhi}[] block_phis;
	list::List{Mem2RegUndo} undo;
	sz[] executable_end;
	bool[] remove;
	ir::Ref[] replacements;
}

fn ir::Ref mem2reg_batch_value(Mem2RegBatch* batch, uint slot)
{
	if (batch.current[(sz)slot] != ir::NONE) return batch.current[(sz)slot];
	// LLVM seeds these reads with undef; C3 deliberately uses typed zero instead.
	if (batch.slot_zero[(sz)slot] == ir::NONE)
	{
		batch.slot_zero[(sz)slot] = batch.editor.add_constant(value_interner::REF_ZERO, batch.slot_type[(sz)slot]);
	}
	return batch.slot_zero[(sz)slot];
}

fn void mem2reg_batch_set(Mem2RegBatch* batch, uint slot, ir::Ref value) @inline
{
	batch.undo.push({ slot, batch.current[(sz)slot] });
	batch.current[(sz)slot] = value;
}

fn uint mem2reg_batch_slot(Mem2RegBatch* batch, ir::Ref ref) @inline
{
	return (usz)ref < (usz)batch.slot_of.len ? batch.slot_of[(sz)ref] : uint::max;
}

<* Rename every promoted slot down the dominator tree at once; each child starts
   from this block's exit values. *>
fn bool mem2reg_batch_rename(Mem2RegBatch* batch, uint block_index)
{
	CfgBlock* block = &batch.cfg.blocks[(sz)block_index];
	foreach (entry : batch.block_phis[(sz)block_index]) mem2reg_batch_set(batch, entry.slot, entry.phi);
	// CFG ranges refer to the original body; PHIs are placed after renaming.
	for (sz pos = block.start + 1; pos < batch.executable_end[(sz)block_index]; pos++)
	{
		ir::Ref ref = batch.decl.body[pos];
		if ((usz)ref >= (usz)batch.slot_of.len) continue;
		ir::Inst* inst = &batch.editor.insts.entries[(sz)ref];
		if (inst.tag == ir::InstTag.LOAD)
		{
			uint slot = mem2reg_batch_slot(batch, inst.data.ref);
			if (slot == uint::max) continue;
			batch.replacements[(sz)ref] = mem2reg_batch_value(batch, slot);
			batch.remove[(sz)ref] = true;
		}
		else if (inst.tag == ir::InstTag.STORE)
		{
			uint slot = mem2reg_batch_slot(batch, inst.data.bin.lhs);
			if (slot == uint::max) continue;
			mem2reg_batch_set(batch, slot, inst.data.bin.rhs);
			batch.remove[(sz)ref] = true;
		}
	}
	ir::Ref pred_label = block.label;
	foreach (successor : block.succs)
	{
		foreach (entry : batch.block_phis[(sz)successor])
		{
			ir::Ref value = mem2reg_batch_value(batch, entry.slot);
			ir::Inst* phi = &batch.editor.insts.entries[(sz)entry.phi];
			bool filled = false;
			foreach (i, input : phi.data.phi)
			{
				if (input.label != pred_label) continue;
				phi.data.phi[i].value = value;
				filled = true;
				break;
			}
			if (!filled) return false;
		}
	}
	sz mark = batch.undo.len();
	foreach (child : block.dom_children)
	{
		if (!mem2reg_batch_rename(batch, child)) return false;
		while (batch.undo.len() > mark)
		{
			Mem2RegUndo entry = batch.undo.pop()!!;
			batch.current[(sz)entry.slot] = entry.old;
		}
	}
	return true;
}

<* Promote every PROMOTE/REMOVE slot of one function with one CFG, one rename
   walk and one commit. Returns false, leaving `decl` untouched, when renaming
   fails; the caller then falls back to one-at-a-time promotion. *>
fn bool mem2reg_batch(ir::Ir* ir, ir::Decl* decl, Cfg* cfg, Uses* uses, ir::Ref[] promote,
	value_interner::InternerRef[] promote_type, ir::Ref[] removed, sz[] executable_end)
{
	usz count = (usz)decl.instructions.len;
	DeclEditor editor;
	editor.begin(decl);
	uint[] slot_of = alloc::new_array(mem, uint, (sz)count);
	defer alloc::free(mem, slot_of.ptr);
	for (usz i = 0; i < count; i++) slot_of[i] = uint::max;
	foreach (slot, alloc_ref : promote) slot_of[(sz)alloc_ref] = (uint)slot;
	usz block_count = cfg.blocks.len;
	list::List{Mem2RegPhi}[] block_phis = alloc::new_array(mem, list::List{Mem2RegPhi}, (sz)block_count);
	for (usz i = 0; i < block_count; i++) block_phis[i].init(mem, 0);
	defer
	{
		for (usz i = 0; i < block_count; i++) block_phis[i].free();
		alloc::free(mem, block_phis.ptr);
	}
	list::List{ir::Ref} new_phis;
	new_phis.init(mem);
	defer new_phis.free();

	// Place PHIs at each slot's iterated dominance frontier (LLVM prunes by
	// live-in blocks; C3 builds the full IDF and removes unused PHIs later).
	uint[] def_mark = alloc::new_array(tmem, uint, (sz)block_count);
	uint[] phi_mark = alloc::new_array(tmem, uint, (sz)block_count);
	for (usz i = 0; i < block_count; i++) { def_mark[i] = 0; phi_mark[i] = 0; }
	list::List{uint} worklist;
	worklist.init(mem);
	defer worklist.free();
	list::List{uint} sites;
	sites.init(mem);
	defer sites.free();
	foreach (slot, alloc_ref : promote)
	{
		uint stamp = (uint)slot + 1;
		worklist.clear();
		sites.clear();
		foreach (user_ref : uses.of(alloc_ref))
		{
			ir::Inst* user = &decl.instructions[(sz)user_ref];
			if (user.tag != ir::InstTag.STORE || user.data.bin.lhs != alloc_ref) continue;
			def_mark[(sz)cfg.block_of_ref[(sz)user_ref]] = stamp;
		}
		foreach (block : cfg.rpo) if (def_mark[(sz)block] == stamp) worklist.push(block);
		while (worklist.len())
		{
			uint block = worklist.pop()!!;
			foreach (frontier : cfg.blocks[(sz)block].frontier)
			{
				if (phi_mark[(sz)frontier] == stamp) continue;
				// Only reachable predecessors participate after unreachable pruning.
				uint reachable_preds = 0;
				foreach (pred : cfg.blocks[(sz)frontier].preds) if (cfg.reachable[(sz)pred]) reachable_preds++;
				if (reachable_preds < 2) continue;
				phi_mark[(sz)frontier] = stamp;
				sites.push(frontier);
				if (def_mark[(sz)frontier] != stamp) worklist.push(frontier);
			}
		}
		// Create this slot's PHIs in block-index order.
		quicksort(sites.array_view());
		foreach (block_index : sites)
		{
			usz input_count = 0;
			foreach (pred : cfg.blocks[(sz)block_index].preds) if (cfg.reachable[(sz)pred]) input_count++;
			ir::PhiInput[] inputs = alloc::new_array(mem, ir::PhiInput, (sz)input_count);
			sz input_index = 0;
			foreach (pred : cfg.blocks[(sz)block_index].preds)
			{
				if (!cfg.reachable[(sz)pred]) continue;
				inputs[input_index++] = { .label = cfg.blocks[(sz)pred].label, .value = ir::NONE };
			}
			ir::Ref phi_ref = editor.append({ .tag = ir::InstTag.PHI, .data.phi = inputs, .ty = promote_type[slot] });
			alloc::free(mem, inputs.ptr);
			block_phis[(sz)block_index].push({ (uint)slot, phi_ref });
			new_phis.push(phi_ref);
		}
	}

	usz edited_count = (usz)editor.insts.len();
	bool[] remove = alloc::new_array(mem, bool, (sz)edited_count);
	defer alloc::free(mem, remove.ptr);
	ir::Ref[] replacements = alloc::new_array(mem, ir::Ref, (sz)edited_count);
	defer alloc::free(mem, replacements.ptr);
	for (usz i = 0; i < edited_count; i++) { remove[i] = false; replacements[i] = ir::NONE; }
	ir::Ref[] current = alloc::new_array(mem, ir::Ref, promote.len + 1);
	defer alloc::free(mem, current.ptr);
	ir::Ref[] slot_zero = alloc::new_array(mem, ir::Ref, promote.len + 1);
	defer alloc::free(mem, slot_zero.ptr);
	for (usz i = 0; i < promote.len; i++) { current[i] = ir::NONE; slot_zero[i] = ir::NONE; }
	Mem2RegBatch batch = {
		.editor = &editor, .cfg = cfg, .decl = decl, .slot_of = slot_of, .slot_type = promote_type,
		.slot_zero = slot_zero, .current = current, .block_phis = block_phis,
		.executable_end = executable_end, .remove = remove, .replacements = replacements,
	};
	batch.undo.init(mem);
	defer batch.undo.free();
	if (cfg.rpo.len == 0 || !mem2reg_batch_rename(&batch, cfg.rpo[0]))
	{
		editor.free();
		return false;
	}
	foreach (phi_ref : new_phis)
	{
		foreach (input : editor.insts.entries[(sz)phi_ref].data.phi) if (input.value == ir::NONE)
		{
			editor.free();
			return false;
		}
	}

	// Place each block's new PHIs after its label and existing PHIs, in slot order.
	ir::Ref[] label_block = alloc::new_array(tmem, ir::Ref, (sz)count);
	for (usz i = 0; i < count; i++) label_block[i] = (ir::Ref)NONE_BLOCK;
	foreach (block_index, block : cfg.blocks)
	{
		if ((usz)block.label < count) label_block[(sz)block.label] = (ir::Ref)block_index;
	}
	list::List{ir::Ref} new_body;
	new_body.init(editor.decl.allocator, editor.body.len() + new_phis.len());
	sz pos = 0;
	while (pos < editor.body.len())
	{
		ir::Ref ref = editor.body.entries[pos++];
		new_body.push(ref);
		if ((usz)ref >= count || label_block[(sz)ref] == (ir::Ref)NONE_BLOCK) continue;
		uint block_index = (uint)label_block[(sz)ref];
		if (!block_phis[(sz)block_index].len()) continue;
		while (pos < editor.body.len())
		{
			ir::Ref next = editor.body.entries[pos];
			if ((usz)next >= (usz)editor.insts.len() || editor.insts.entries[(sz)next].tag != ir::InstTag.PHI) break;
			new_body.push(next);
			pos++;
		}
		foreach (entry : block_phis[(sz)block_index]) new_body.push(entry.phi);
	}
	editor.body.free();
	editor.body = new_body;

	mem2reg_apply_replacements(&editor, replacements);
	foreach (alloc_ref : promote)
	{
		remove[(sz)alloc_ref] = true;
		// Promoted loads and stores are now represented by SSA values.
		foreach (user_ref : uses.of(alloc_ref))
		{
			ir::Inst* user = &editor.insts.entries[(sz)user_ref];
			if (user.tag == ir::InstTag.LOAD || user.tag == ir::InstTag.STORE) remove[(sz)user_ref] = true;
		}
	}
	foreach (alloc_ref : removed)
	{
		remove[(sz)alloc_ref] = true;
		foreach (user_ref : uses.of(alloc_ref)) remove[(sz)user_ref] = true;
	}
	editor_cleanup_trivial_phis(&editor, remove, replacements);
	editor_cleanup_unused_mem2reg_phis(&editor, new_phis.array_view(), remove);
	BodyRemovalContext removal_context = { .remove = remove };
	editor.remove_body_where(&body_ref_marked_for_removal, (void*)&removal_context);
	editor.commit();
	return true;
}

<* Promote all eligible local allocations. Slots are classified against one set
   of analyses and promoted together; slots whose eligibility can depend on
   another promotion, and every slot when batch renaming fails, go through
   promote_alloca one at a time afterwards. *>
fn bool mem2reg(ir::Ir* ir, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
		list::List{ir::Ref} candidates;
		candidates.init(mem);
		defer candidates.free();
		foreach (ref : decl.body)
		{
			// LLVM also has dedicated single-store and single-block rewrites; C3
			// uses the general SSA algorithm for every fixed-size ALLOC. VLAs use
			// DYN_ALLOC and are deliberately outside this promotion pass.
			if ((usz)ref < (usz)decl.instructions.len && decl.instructions[(sz)ref].tag == ir::InstTag.ALLOC) candidates.push(ref);
		}
		if (!candidates.len()) return false;
		usz count = (usz)decl.instructions.len;
		list::List{ir::Ref} promote;
		promote.init(mem);
		defer promote.free();
		list::List{value_interner::InternerRef} promote_type;
		promote_type.init(mem);
		defer promote_type.free();
		list::List{ir::Ref} removed;
		removed.init(mem);
		defer removed.free();
		list::List{ir::Ref} deferred;
		deferred.init(mem);
		defer deferred.free();
		bool batched = false;
		@pool()
		{
			Cfg* cfg = analyses.get_cfg(frontiers: true);
			if (cfg.blocks.len == 0) return false;
			Uses* uses = analyses.get_uses();
			uint[] body_position = alloc::new_array(tmem, uint, (sz)count);
			for (usz i = 0; i < count; i++) body_position[i] = NONE_BLOCK;
			foreach (pos, ref : decl.body)
			{
				if ((usz)ref < count) body_position[(sz)ref] = (uint)pos;
			}
			sz[] terminator_position = alloc::new_array(tmem, sz, (sz)cfg.blocks.len);
			sz[] executable_end = alloc::new_array(tmem, sz, (sz)cfg.blocks.len);
			foreach (block_index, &block : cfg.blocks)
			{
				terminator_position[block_index] = block_terminator_position(decl, block);
				executable_end[block_index] = block_executable_end(decl, block);
			}
			foreach (alloc_ref : candidates)
			{
				value_interner::InternerRef access_type;
				switch (mem2reg_classify(ir, decl, cfg, uses, body_position, terminator_position, alloc_ref, &access_type))
				{
					case REJECT: break;
					case REMOVE: removed.push(alloc_ref);
					case PROMOTE: promote.push(alloc_ref); promote_type.push(access_type);
					case DEFER: deferred.push(alloc_ref);
				}
			}
			if (!promote.len() && !removed.len() && !deferred.len()) return false;
			if (!promote.len() && !removed.len()) { batched = true; }
			else
			{
				batched = mem2reg_batch(ir, decl, cfg, uses, promote.array_view(), promote_type.array_view(),
					removed.array_view(), executable_end);
			}
		};
		bool changed = batched && (promote.len() || removed.len());
		if (!batched)
		{
			deferred.clear();
			deferred.push_all(candidates.array_view());
		}
		if (!deferred.len()) return changed;
		// promote_alloca edits between candidates; keep this pass-local snapshot.
		analyses.mark_dirty();
		Uses uses = compute_uses(decl, tmem);
		foreach (alloc_ref : deferred)
		{
			if (!mem2reg_may_promote(ir, decl, &uses, alloc_ref)) continue;
			changed = promote_alloca(ir, decl, alloc_ref) || changed;
		}
		return changed;
	};
}

<* False only when promote_alloca must reject `alloc_ref` whatever else this
   run promotes. Promoting another slot B only rewrites B's loads, stores and
   inserted PHIs, so the users of `alloc_ref` can change only when its address
   is itself stored (`STORE B, alloc_ref`); that case is left to promote_alloca.
   The CFG-dependent load checks are also left to promote_alloca. *>
fn bool mem2reg_may_promote(ir::Ir* ir, ir::Decl* decl, Uses* uses, ir::Ref alloc_ref)
{
	if ((usz)alloc_ref >= uses.count()) return true;
	ir::Inst* alloc_inst = &decl.instructions[(sz)alloc_ref];
	if (alloc_inst.tag != ir::InstTag.ALLOC || alloc_inst.data.alloc.is_volatile) return false;
	foreach (user_ref : uses.of(alloc_ref))
	{
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		if (user.tag == ir::InstTag.STORE && user.data.bin.rhs == alloc_ref) return true;
	}
	bool has_load = false;
	bool has_access_type = false;
	value_interner::InternerRef access_type = value_interner::REF_VOID;
	foreach (user_ref : uses.of(alloc_ref))
	{
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		if (user.is_volatile_access()) return false;
		value_interner::InternerRef user_type;
		if (user.tag == ir::InstTag.LOAD && user.data.ref == alloc_ref)
		{
			has_load = true;
			user_type = user.ty;
		}
		else if (user.tag == ir::InstTag.STORE && user.data.bin.lhs == alloc_ref)
		{
			if (!valid_ref(decl, user.data.bin.rhs)) return false;
			user_type = decl.instructions[(sz)user.data.bin.rhs].ty;
		}
		else
		{
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
	if (!has_load) return true;
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
	uint allocation_size = alloc_inst.data.alloc.size;
	bool padded_f80 = access_key.tag == primitive_value::PrimitiveType.FLOAT_TY &&
		access_key.ty_bits == 80 && allocation_size == 16;
	return allocation_size == expected_size || padded_f80;
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

fn bool const_prop_compare_bits(ir::InstTag tag, ushort width, ulong a, ulong b, bool* result)
{
	switch (tag)
	{
		case ir::InstTag.CMP_EQ: *result = a == b;
		case ir::InstTag.CMP_NE: *result = a != b;
		case ir::InstTag.CMP_SLT: *result = const_prop_signed(a, width) < const_prop_signed(b, width);
		case ir::InstTag.CMP_SLTE: *result = const_prop_signed(a, width) <= const_prop_signed(b, width);
		case ir::InstTag.CMP_SGT: *result = const_prop_signed(a, width) > const_prop_signed(b, width);
		case ir::InstTag.CMP_SGTE: *result = const_prop_signed(a, width) >= const_prop_signed(b, width);
		case ir::InstTag.CMP_ULT: *result = a < b;
		case ir::InstTag.CMP_ULTE: *result = a <= b;
		case ir::InstTag.CMP_UGT: *result = a > b;
		case ir::InstTag.CMP_UGTE: *result = a >= b;
		default: return false;
	}
	return true;
}

fn ConstPropValue const_prop_binary(ir::Ir* graph, ir::Decl* decl, ir::Inst* inst, ConstPropValue[] values)
{
	ConstPropValue lhs = const_prop_ref(values, decl, inst.data.bin.lhs);
	ConstPropValue rhs = const_prop_ref(values, decl, inst.data.bin.rhs);
	// Unlike LLVM's ConstantFold poison results, keep UB-producing constants unfolded to preserve
	// the existing x86 runtime behavior.
	// This also deliberately skips absorbing folds such as x & 0; inst_simplify handles those.
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
	if (is_compare)
	{
		bool result;
		if (!const_prop_compare_bits(inst.tag, width, a, b, &result)) return const_prop_bottom();
		return const_prop_constant(1, (ulong)(result ? 1 : 0));
	}
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
		default: return const_prop_bottom();
	}
	return const_prop_constant(width, result);
}

<* Executable CFG edges for SCCP, keyed `(from << 32) | to`. Sized by the
   edges actually marked, not blocks x blocks: inlining makes single functions
   with thousands of blocks, where a dense matrix costs megabytes per pass. *>
struct EdgeSet
{
	HashMap{ulong, bool} edges;
}

fn void EdgeSet.init(&self, Allocator allocator) => self.edges.init(allocator);
fn void EdgeSet.free(&self) => self.edges.free();
fn bool EdgeSet.has(&self, uint from, uint to) => self.edges.has_key((ulong)from << 32 | to);

<* Mark `from -> to`; false when it was already executable. *>
fn bool EdgeSet.add(&self, uint from, uint to)
{
	ulong key = (ulong)from << 32 | to;
	if (self.edges.has_key(key)) return false;
	self.edges.set(key, true);
	return true;
}

fn ConstPropValue const_prop_eval(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, EdgeSet* executable_edges,
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
					!executable_edges.has(pred, block_index)) continue;
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
			if (cond.tag == ConstPropTag.TOP) return const_prop_top();
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

fn bool const_prop_mark_edge(Cfg* cfg, EdgeSet* executable_edges, bool[] executable_blocks,
	uint from, ir::Ref label, list::List{ir::Ref} * worklist, bool[] queued)
{
	if ((usz)label >= (usz)cfg.block_of_ref.len) return false;
	uint to = cfg.block_of_ref[(sz)label];
	if (to == NONE_BLOCK || (usz)to >= (usz)cfg.blocks.len) return false;
	if (!executable_edges.add(from, to)) return false;
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
fn bool const_prop(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
		// build_cfg has no JMP_VAL successors, so SCCP cannot safely reason about computed goto.
		foreach (inst : decl.instructions)
		{
			if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;
		}
		Cfg* cfg = analyses.get_cfg();
		if (cfg.blocks.len == 0) return false;
		ConstPropValue[] values = alloc::new_array(tmem, ConstPropValue, (sz)decl.instructions.len);
		bool[] executable_blocks = alloc::new_array(tmem, bool, (sz)cfg.blocks.len);
		for (usz i = 0; i < (usz)cfg.blocks.len; i++) executable_blocks[i] = false;
		EdgeSet edge_set;
		edge_set.init(mem);
		defer edge_set.free();
		EdgeSet* executable_edges = &edge_set;
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
		Uses* uses = analyses.get_uses();
		list::List{ir::Ref} worklist;
		worklist.init(mem);
		defer worklist.free();
		bool[] queued = alloc::new_array(tmem, bool, (sz)decl.instructions.len);
		for (usz i = 0; i < (usz)decl.instructions.len; i++) queued[i] = false;
		executable_blocks[0] = true;
		const_prop_enqueue_block(decl, cfg, 0, &worklist, queued);
		CfgBlock* entry = &cfg.blocks[0];
		if (block_terminator_position(decl, entry) == entry.end)
		{
			foreach (succ : entry.succs)
			{
				const_prop_mark_edge(cfg, executable_edges, executable_blocks, 0,
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
			// A TOP branch condition or switch target is transient while its defining
			// instruction is queued; updates re-enqueue the terminator. In verified IR,
			// executable blocks have feasible incoming edges and mem2reg zero-fills
			// uninitialized slots, so these terminators cannot retain TOP.
			if (is_value_tag(inst.tag) && inst.tag != ir::InstTag.CONSTANT)
			{
				ConstPropValue evaluated = const_prop_eval(graph, decl, cfg, executable_edges, ref, inst, values);
				if (const_prop_update(values, ref, evaluated))
				{
					foreach (user_ref : uses.of(ref)) const_prop_enqueue_inst(&worklist, queued, user_ref);
				}
			}
			if (inst.tag == ir::InstTag.JMP)
			{
				const_prop_mark_edge(cfg, executable_edges, executable_blocks, block_index,
					inst.data.ref, &worklist, queued);
			}
			else if (inst.tag == ir::InstTag.BRANCH)
			{
				ConstPropValue cond = const_prop_ref(values, decl, inst.data.branch.cond);
				if (cond.tag == ConstPropTag.CONSTANT)
				{
					ir::Ref target = cond.bits != 0 ? inst.data.branch.then_label : inst.data.branch.else_label;
					const_prop_mark_edge(cfg, executable_edges, executable_blocks, block_index, target, &worklist, queued);
				}
				else if (cond.tag == ConstPropTag.BOTTOM)
				{
					const_prop_mark_edge(cfg, executable_edges, executable_blocks, block_index,
						inst.data.branch.then_label, &worklist, queued);
					const_prop_mark_edge(cfg, executable_edges, executable_blocks, block_index,
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
					const_prop_mark_edge(cfg, executable_edges, executable_blocks, block_index, label, &worklist, queued);
				}
				else if (target.tag == ConstPropTag.BOTTOM)
				{
					foreach (label : inst.data.switch_data.labels)
					const_prop_mark_edge(cfg, executable_edges, executable_blocks, block_index, label, &worklist, queued);
					const_prop_mark_edge(cfg, executable_edges, executable_blocks, block_index,
						inst.data.switch_data.default_label, &worklist, queued);
				}
			}
		}

		DeclEditor editor;
		editor.begin(decl);
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
						!executable_edges.has(pred, block_index)) continue;
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
	};
}

fn bool removable_if_unused(ir::Decl* decl, ir::Inst* inst, ir::Ir* graph = null)
{
	switch (inst.tag)
	{
		case ir::InstTag.CALL:
			// LLVM also drops will-return calls without side effects (including readonly+nounwind
			// calls); this conservative rule requires readnone and a known matching body.
			if (graph == null || (usz)inst.data.call.func >= (usz)decl.instructions.len) return false;
			ir::Inst* func = &decl.instructions[(sz)inst.data.call.func];
			if (func.tag != ir::InstTag.SYMBOL) return false;
			// Match build_inline_call_graph's last-declaration-wins name lookup.
			ir::Decl* callee = find_decl_by_name(graph, func.data.label, last: true);
			return callee && callee.kind == ir::DeclKind.FUNCTION && callee.body.len != 0 &&
				callee.attrs.computed && callee.attrs.readnone && callee.attrs.will_return &&
				(usz)inst.data.call.args.len == inline_arg_count(callee);
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
			if (inst.is_volatile) return false;
			if ((usz)inst.data.ref >= (usz)decl.instructions.len) return false;
			if (decl.instructions[(sz)inst.data.ref].tag != ir::InstTag.ALLOC) return false;
			return !decl.instructions[(sz)inst.data.ref].data.alloc.is_volatile;
		case ir::InstTag.SDIV:
		case ir::InstTag.UDIV:
		case ir::InstTag.SREM:
		case ir::InstTag.UREM:
			// LLVM's wouldInstructionBeTriviallyDead can drop unused division even with
			// an unknown/zero divisor. C3's simpler rule only drops it for a known
			// constant nonzero divisor, preserving possible divide-by-zero behavior.
			if ((usz)inst.data.bin.rhs >= (usz)decl.instructions.len) return false;
			ir::Inst* divisor = &decl.instructions[(sz)inst.data.bin.rhs];
			// Integer zero is canonicalized by the interner to REF_ZERO. These
			// operations have integer operands, so any other constant is nonzero.
			return divisor.tag == ir::InstTag.CONSTANT && divisor.data.constant != value_interner::REF_ZERO;
		// LLVM can delete an unused stacksave; this conservative fallback retains it.
		default: return false;
	}
}

<* Remove dead pure instructions and unobserved local allocations to a fixpoint. *>
fn bool dead_instruction_elim(ir::Decl* decl, ir::Ir* graph = null, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
		bool[] remove = alloc::new_array(mem, bool, (sz)decl.instructions.len);
		defer alloc::free(mem, remove.ptr);
		bool any_changed = false;
		while (true)
		{
			for (usz i = 0; i < (usz)decl.instructions.len; i++) remove[i] = false;
			Uses* uses = analyses.get_uses();
			bool changed = false;
			foreach (ref : decl.body)
			{
				if ((usz)ref >= (usz)decl.instructions.len) continue;
				ir::Inst* inst = &decl.instructions[(sz)ref];
				ir::Ref[] users = uses.of(ref);
				if (inst.tag == ir::InstTag.ALLOC)
				{
					if (inst.data.alloc.is_volatile) continue;
					if (users.len == 0)
					{
						remove[(sz)ref] = true;
						changed = true;
						continue;
					}
					bool stores_only = true;
					foreach (user_ref : users)
					{
						if ((usz)user_ref >= (usz)decl.instructions.len)
						{
							stores_only = false;
							break;
						}
						ir::Inst* user = &decl.instructions[(sz)user_ref];
						// A self-store contributes a second use of the allocation as
						// its value. Keep it conservatively instead of misclassifying it.
						if (user.tag != ir::InstTag.STORE || user.is_volatile || user.data.bin.lhs != ref || user.data.bin.rhs == ref)
						{
							stores_only = false;
							break;
						}
					}
					if (stores_only)
					{
						remove[(sz)ref] = true;
						foreach (user_ref : users) remove[(sz)user_ref] = true;
						changed = true;
					}
					continue;
				}
				if (inst.tag == ir::InstTag.STORE && (usz)inst.data.bin.lhs < (usz)decl.instructions.len)
				{
					ir::Inst* destination = &decl.instructions[(sz)inst.data.bin.lhs];
					if (destination.tag == ir::InstTag.ALLOC && destination.data.alloc.is_volatile) continue;
				}
				if (users.len == 0 && removable_if_unused(decl, inst, graph))
				{
					remove[(sz)ref] = true;
					changed = true;
				}
			}
			if (!changed) break;
			any_changed = true;

			DeclEditor editor;
			editor.begin(decl);
			BodyRemovalContext context = { .remove = remove };
			editor.remove_body_where(&body_ref_marked_for_removal, (void*)&context);
			editor.commit();
			// Removed calls can leave an unplaced SYMBOL behind. Retire it only
			// after checking uses in the committed body, as the inliner does. The
			// retag below adds no operands, so the next round reuses these uses.
			analyses.mark_dirty();
			Uses* committed_uses = analyses.get_uses();
			for (usz i = 0; i < (usz)decl.instructions.len; i++)
			{
				if (!remove[i]) continue;
				ir::Inst* removed = &decl.instructions[(sz)i];
				if (removed.tag != ir::InstTag.CALL || (usz)removed.data.call.func >= (usz)decl.instructions.len) continue;
				ir::Ref func_ref = removed.data.call.func;
				if (committed_uses.of(func_ref).len != 0) continue;
				ir::Inst* func = &decl.instructions[(sz)func_ref];
				if (func.tag == ir::InstTag.SYMBOL) func.tag = ir::InstTag.ARG;
			}
		}
		return any_changed;
	};
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

fn InlineCallGraph build_inline_call_graph(ir::Ir* graph)
{
	InlineCallGraph calls = { .allocator = mem, .decl_count = (usz)graph.decls.len() };
	uint n = (uint)calls.decl_count;
	calls.decl_indices.init(mem);
	foreach (i, decl : graph.decls) calls.decl_indices.set(decl.name, (usz)i);
	calls.edges = alloc::new_array(mem, list::List{uint}, (sz)n);
	calls.reverse_edges = alloc::new_array(mem, list::List{uint}, (sz)n);
	calls.scc = alloc::new_array(mem, uint, (sz)n);
	calls.bottom_up = alloc::new_array(mem, uint, (sz)n);
	calls.call_count = alloc::new_array(mem, uint, (sz)n);
	for (uint i = 0; i < n; i++)
	{
		calls.edges[i].init(mem);
		calls.reverse_edges[i].init(mem);
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
	bool[] visited = alloc::new_array(tmem, bool, (sz)n);
	for (uint i = 0; i < n; i++) visited[(sz)i] = false;
	list::List{uint} postorder;
	postorder.init(mem);
	defer postorder.free();
	list::List{DfsFrame} dfs;
	dfs.init(mem);
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
	pending.init(mem);
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

fn uint inline_alloca_bytes(ir::Decl* decl)
{
	uint total = 0;
	foreach (ref : decl.body)
	{
		if ((usz)ref >= (usz)decl.instructions.len) continue;
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag != ir::InstTag.ALLOC) continue;
		if (inst.data.alloc.size > uint::max - total) return uint::max;
		total += inst.data.alloc.size;
	}
	return total;
}

fn bool inline_unsupported_control(ir::Decl* decl)
{
	foreach (inst : decl.instructions)
	{
		if (inst.tag == ir::InstTag.RET_PAIR) return true;
		if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return true;
		// Dynamic stack allocation lives until the callee returns; inlining would leak it into the caller's frame.
		if (inst.tag == ir::InstTag.DYN_ALLOC || inst.tag == ir::InstTag.STACK_SAVE || inst.tag == ir::InstTag.STACK_RESTORE) return true;
		// va_start refers to the callee's variadic argument state and cannot move into a caller.
		if (inst.tag == ir::InstTag.VA_START) return true;
		// Unlike LLVM's isInlineViable, C3 has no returns_twice/setjmp model; the run test
		// covers the current behavior when a helper longjmps into the inlined frame.
	}
	return false;
}

<* Every fixed allocation is used only as a direct LOAD/STORE address. Tail-call
   elimination needs this because it reuses one frame across iterations, so an
   escaped address from one iteration would alias the next. Inlining does not:
   escaping callee allocas are hoisted to the caller entry. *>
fn bool inline_allocations_do_not_escape(ir::Decl* decl)
{
	foreach (alloc_ref : decl.body)
	{
		if ((usz)alloc_ref >= (usz)decl.instructions.len || decl.instructions[(sz)alloc_ref].tag != ir::InstTag.ALLOC) continue;
		foreach (user_ref : decl.body)
		{
			if ((usz)user_ref >= (usz)decl.instructions.len) continue;
			ir::Inst* user = &decl.instructions[(sz)user_ref];
			bool used = false;
			@each_value_operand(user; ir::Ref* slot) { if (*slot == alloc_ref) used = true; };
			if (!used) continue;
			if (user.tag == ir::InstTag.LOAD && user.data.ref == alloc_ref) continue;
			if (user.tag == ir::InstTag.STORE && user.data.bin.lhs == alloc_ref && user.data.bin.rhs != alloc_ref) continue;
			return false;
		}
	}
	return true;
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

<* Operand-use counts and CALL_HI presence per ref, over placed instructions. *>
struct InlineUseInfo
{
	uint[] count;
	bool[] has_call_hi;
}

fn void InlineUseInfo.compute(&self, ir::Decl* caller)
{
	usz len = (usz)self.count.len;
	for (usz i = 0; i < len; i++) { self.count[i] = 0; self.has_call_hi[i] = false; }
	foreach (user_ref : caller.body)
	{
		if ((usz)user_ref >= (usz)caller.instructions.len) continue;
		ir::Inst* inst = &caller.instructions[(sz)user_ref];
		@each_value_operand(inst; ir::Ref* slot)
		{
			if (*slot != ir::NONE && (usz)*slot < len) self.count[(sz)*slot]++;
		};
		if (inst.tag == ir::InstTag.CALL_HI && (usz)inst.data.ref < len) self.has_call_hi[(sz)inst.data.ref] = true;
	}
}

<* `call_ref` must be placed in `caller`'s body; `uses` must describe the
   caller's current body. A CALL_HI of the call, adjacent or not, is rejected
   through `uses` below. *>
fn bool inline_one_call(ir::Ir* graph, ir::Decl* caller, ir::Decl* callee, ir::Ref call_ref, InlineUseInfo* uses)
{
	@pool()
	{
		if ((usz)call_ref >= (usz)caller.instructions.len || (usz)call_ref >= (usz)uses.count.len) return false;
		ir::Inst* call = &caller.instructions[(sz)call_ref];
		if (call.tag != ir::InstTag.CALL || (usz)call.data.call.func >= (usz)caller.instructions.len) return false;
		// LLVM materializes a byval copy here; C3 keeps MEMORY-class by-value calls out of inlining.
		foreach (copy_bytes : call.data.call.memory_copy_bytes) if (copy_bytes != 0) return false;
		ir::Ref call_func_ref = call.data.call.func;
		if (caller.instructions[(sz)call_func_ref].tag != ir::InstTag.SYMBOL) return false;
		usz callee_arg_count = inline_arg_count(callee);
		if (callee_arg_count != (usz)call.data.call.args.len) return false;
		Cfg callee_cfg = build_cfg(callee, mem);
		defer callee_cfg.free();
		if (callee_cfg.blocks.len == 0 || callee_cfg.rpo.len == 0 || callee_cfg.blocks[0].preds.len() != 0) return false;

		// Do not construct an invalid continuation PHI for malformed or unused
		// value-return behavior. Normal C functions have consistent return types.
		bool call_is_used = uses.count[(sz)call_ref] != 0;
		if (uses.has_call_hi[(sz)call_ref]) return false;
		usz return_count = 0;
		bool returns_value = false;
		bool returns_void = false;
		bool falls_through = false;
		foreach (block : callee_cfg.blocks)
		{
			sz term_pos = block_terminator_position(callee, &block);
			if (term_pos >= block.end)
			{
				// A final unterminated block returns implicitly. Non-final blocks are
				// ordinary fallthrough edges and are preserved when the body is cloned.
				if (block.end == callee.body.len) falls_through = true;
				continue;
			}
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
		if (returns_value && (returns_void || falls_through)) return false;
		if (call_is_used && (!returns_value || return_count == 0)) return false;
		if (call_is_used && falls_through) return false;
		// Reject malformed IR where the call's declared result differs from its returns.
		if (call_is_used)
		{
			foreach (block : callee_cfg.blocks)
			{
				sz term_pos = block_terminator_position(callee, &block);
				if (term_pos >= block.end) continue;
				ir::Ref term_ref = callee.body[term_pos];
				if ((usz)term_ref >= (usz)callee.instructions.len) continue;
				ir::Inst* term = &callee.instructions[(sz)term_ref];
				if (term.tag != ir::InstTag.RET || term.data.ref == ir::NONE) continue;
				if ((usz)term.data.ref >= (usz)callee.instructions.len ||
					callee.instructions[(sz)term.data.ref].ty != call.ty) return false;
			}
		}

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
		editor.begin(caller);
		bool[] successor_targets = alloc::new_array(tmem, bool, (sz)caller.instructions.len);
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

		String continuation_name = string::tformat("inl.%s.%d.cont", caller.name, call_ref);
		ir::Ref continuation_label = editor.new_label(continuation_name);
		ir::Ref[] mapping = alloc::new_array(tmem, ir::Ref, (sz)callee.instructions.len);
		for (usz i = 0; i < (usz)mapping.len; i++) mapping[i] = ir::NONE;
		// The caller passes sub-int integers widened to i32 (SysV promotion); the
		// callee's ARG keeps the declared narrow type. Narrow them back in the
		// inlined entry block so stores and arithmetic keep the callee's width.
		list::List{ir::Ref} arg_truncs;
		arg_truncs.init(mem);
		defer arg_truncs.free();
		usz arg_index = 0;
		for (usz pos = 0; pos < (usz)callee.body.len && arg_index < callee_arg_count; pos++)
		{
			ir::Ref ref = callee.body[(sz)pos];
			if ((usz)ref >= (usz)callee.instructions.len || callee.instructions[(sz)ref].tag != ir::InstTag.ARG) break;
			ir::Ref passed = call.data.call.args[(sz)arg_index++];
			if ((usz)passed >= (usz)editor.insts.len()) { editor.free(); return false; }
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
				String label_name = string::format(mem, "inl.%s.%d.%d", caller.name, call_ref, (uint)i);
				cloned.data.label = label_name;
				mapping[i] = editor.append(cloned);  // copies the label into the decl arena
				alloc::free(mem, label_name.ptr);
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
		cloned_body.init(mem);
		defer cloned_body.free();
		list::List{ir::Ref} cloned_allocs;
		cloned_allocs.init(mem);
		defer cloned_allocs.free();
		list::List{ir::PhiInput} return_inputs;
		return_inputs.init(mem);
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
		if (call_is_used && returns_value && return_inputs.len() > 1)
		{
			ir::PhiInput[] inputs = alloc::new_array(mem, ir::PhiInput, return_inputs.len());
			defer alloc::free(mem, inputs.ptr);
			inputs[..] = return_inputs.array_view()[..];
			result_phi = editor.append(
			{
				.tag = ir::InstTag.PHI, .data.phi = inputs, .ty = call.ty
			}
			);
		}
		else if (call_is_used && returns_value && return_inputs.len() == 1)
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
		new_body.init(editor.decl.allocator);  // becomes editor.body, adopted by commit
		for (sz i = 0; i < call_pos; i++) new_body.push(editor.body.entries[i]);
		new_body.push(caller_jump);
		new_body.push_all(cloned_body.array_view());
		new_body.push(continuation_label);
		if (call_is_used && returns_value && return_inputs.len() > 1) new_body.push(result_phi);
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
	};
}

struct TailCallSite
{
	ir::Ref block_label;
	ir::Ref call_ref;
	ir::Ref ret_ref;
	ir::Ref return_phi;
	ir::Ref symbol_ref;
	bool needs_jump;
	<* `return f(...) op x` (op = integer ADD or MUL): the op instruction and
	   x, folded into an accumulator instead (gcc's tail recursion with
	   accumulator). NONE for a plain tail call. *>
	ir::Ref accum;
	ir::Ref accum_operand;
}

<* Convert direct self calls returned by RET into backedges to a loop header.
   The entry block remains a preheader, so the parameter PHIs have a real
   initial incoming value as well as one incoming value per tail-call block. *>
fn bool tail_call_elim(ir::Decl* decl, value_interner::Interner* interner)
{
	@pool()
	{
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0 || decl.is_weak) return false;
		if (inline_unsupported_control(decl) || !inline_allocations_do_not_escape(decl)) return false;
		usz arg_count = inline_arg_count(decl);
		// These constructs carry per-invocation state that cannot be carried around
		// the generated loop header without changing semantics.
		foreach (ref : decl.body)
		{
			if ((usz)ref >= (usz)decl.instructions.len) return false;
			if (decl.instructions[(sz)ref].tag == ir::InstTag.ARG && decl.instructions[(sz)ref].data.arg.stack_address) return false;
			switch (decl.instructions[(sz)ref].tag)
			{
				case ir::InstTag.VA_START:
				case ir::InstTag.DYN_ALLOC:
				case ir::InstTag.STACK_SAVE:
				case ir::InstTag.STACK_RESTORE:
					return false;
				default: break;
			}
		}
		Cfg cfg = build_cfg(decl, mem);
		defer cfg.free();
		if (cfg.blocks.len == 0 || cfg.blocks[0].preds.len() != 0) return false;
		list::List{TailCallSite} sites;
		sites.init(mem);
		defer sites.free();
		InlineUseInfo uses = {
			.count = alloc::new_array(mem, uint, (sz)decl.instructions.len),
			.has_call_hi = alloc::new_array(mem, bool, (sz)decl.instructions.len),
		};
		defer { alloc::free(mem, uses.count.ptr); alloc::free(mem, uses.has_call_hi.ptr); }
		uses.compute(decl);
		for (usz bi = 0; bi < (usz)cfg.blocks.len; bi++)
		{
			CfgBlock* block = &cfg.blocks[(sz)bi];
			sz term_pos = block_terminator_position(decl, block);
			bool needs_jump = term_pos == block.end;
			if ((!needs_jump && term_pos >= block.end) || term_pos <= block.start + 1) continue;
			if (needs_jump && bi + 1 >= (usz)cfg.blocks.len) continue;
			ir::Ref ret_ref = needs_jump ? ir::NONE : decl.body[term_pos];
			ir::Inst* ret = needs_jump ? null : &decl.instructions[(sz)ret_ref];
			ir::Ref call_ref = decl.body[term_pos - 1];
			if ((usz)call_ref >= (usz)decl.instructions.len) continue;
			// `call; v = call op x; <return v>` accumulates x instead.
			ir::Ref accum_ref = ir::NONE;
			ir::Ref accum_operand = ir::NONE;
			{
				ir::Inst* last = &decl.instructions[(sz)call_ref];
				if ((last.tag == ir::InstTag.ADD || last.tag == ir::InstTag.MUL) && last.ty != value_interner::REF_PTR &&
					term_pos >= block.start + 3)
				{
					ir::Ref before = decl.body[term_pos - 2];
					if ((usz)before < (usz)decl.instructions.len && decl.instructions[(sz)before].tag == ir::InstTag.CALL &&
						(last.data.bin.lhs == before) != (last.data.bin.rhs == before) &&
						interner.get(last.ty).tag == primitive_value::PrimitiveType.INT_TY)
					{
						accum_ref = call_ref;
						accum_operand = last.data.bin.lhs == before ? last.data.bin.rhs : last.data.bin.lhs;
						call_ref = before;
					}
				}
			}
			ir::Ref value_ref = accum_ref != ir::NONE ? accum_ref : call_ref;
			ir::Inst* call = &decl.instructions[(sz)call_ref];
			ir::Ref return_phi = ir::NONE;
			if (needs_jump || ret.tag == ir::InstTag.JMP)
			{
				ir::Ref target_label = needs_jump ? cfg.blocks[(sz)(bi + 1)].label : ret.data.ref;
				if ((usz)target_label >= (usz)cfg.block_of_ref.len) continue;
				uint target_block_index = cfg.block_of_ref[(sz)target_label];
				if (target_block_index == NONE_BLOCK || target_block_index >= cfg.blocks.len) continue;
				CfgBlock* target_block = &cfg.blocks[(sz)target_block_index];
				if (needs_jump && (target_block_index != bi + 1 || target_block.start != block.end)) continue;
				sz target_term_pos = block_terminator_position(decl, target_block);
				if (target_term_pos >= target_block.end || target_block.start >= target_block.end ||
					target_block.label != target_label) continue;
				ir::Ref target_term_ref = decl.body[target_term_pos];
				if ((usz)target_term_ref >= (usz)decl.instructions.len || decl.instructions[(sz)target_term_ref].tag != ir::InstTag.RET) continue;
				ret = &decl.instructions[(sz)target_term_ref];
				if (ret.data.ref != ir::NONE)
				{
					if (target_term_pos != target_block.start + 2 || target_term_pos + 1 != target_block.end) continue;
					ir::Ref phi_ref = decl.body[target_block.start + 1];
					if ((usz)phi_ref >= (usz)decl.instructions.len || decl.instructions[(sz)phi_ref].tag != ir::InstTag.PHI ||
						phi_ref != ret.data.ref || uses.count[(sz)phi_ref] != 1) continue;
					foreach (input : decl.instructions[(sz)phi_ref].data.phi)
						if (input.label == block.label && input.value == value_ref) return_phi = phi_ref;
					if (return_phi == ir::NONE) continue;
				}
				else if (target_term_pos != target_block.start + 1 || target_term_pos + 1 != target_block.end ||
					uses.count[(sz)call_ref] != 0 || accum_ref != ir::NONE)
				{
					continue;
				}
			}
			else if (ret.tag != ir::InstTag.RET)
			{
				continue;
			}
			bool has_return_value = ret.data.ref != ir::NONE;
			if (accum_ref != ir::NONE && (!has_return_value || uses.count[(sz)accum_ref] != 1)) continue;
			if (call.tag != ir::InstTag.CALL || (has_return_value && return_phi == ir::NONE && value_ref != ret.data.ref) ||
				uses.count[(sz)call_ref] != (has_return_value ? 1 : 0) || uses.has_call_hi[(sz)call_ref]) continue;
			if ((usz)call.data.call.func >= (usz)decl.instructions.len || call.data.call.args.len != arg_count) continue;
			ir::Inst* target = &decl.instructions[(sz)call.data.call.func];
			if (target.tag != ir::InstTag.SYMBOL || target.data.label != decl.name) continue;
			if (call.data.call.stack_only.len != arg_count || call.data.call.memory_copy_bytes.len != arg_count) continue;
			bool unsupported_abi = false;
			for (usz i = 0; i < arg_count; i++)
			{
				if (call.data.call.stack_only[(sz)i] || call.data.call.memory_copy_bytes[(sz)i] != 0) unsupported_abi = true;
				if ((usz)call.data.call.args[(sz)i] >= (usz)decl.instructions.len) { unsupported_abi = true; continue; }
				value_interner::InternerRef param_ty = decl.instructions[(sz)decl.body[(sz)i]].ty;
				value_interner::InternerRef passed_ty = decl.instructions[(sz)call.data.call.args[(sz)i]].ty;
				if (param_ty != passed_ty)
				{
					primitive_value::PrimitiveValue param_key = interner.get(param_ty);
					primitive_value::PrimitiveValue passed_key = interner.get(passed_ty);
					if (param_key.tag != primitive_value::PrimitiveType.INT_TY || passed_key.tag != primitive_value::PrimitiveType.INT_TY ||
						param_key.ty_bits >= passed_key.ty_bits) unsupported_abi = true;
				}
			}
			if (unsupported_abi) continue;
			sites.push({ .block_label = block.label, .call_ref = call_ref, .ret_ref = ret_ref,
				.return_phi = return_phi, .symbol_ref = call.data.call.func, .needs_jump = needs_jump,
				.accum = accum_ref, .accum_operand = accum_operand });
		}
		if (!sites.len()) return false;
		// Accumulator sites must agree on the operation and type; then every
		// other return must carry a value to combine with the accumulator.
		ir::InstTag accum_tag = ir::InstTag.CONSTANT;
		value_interner::InternerRef accum_ty;
		foreach (site : sites)
		{
			if (site.accum == ir::NONE) continue;
			ir::Inst op = decl.instructions[(sz)site.accum];
			if (accum_tag == ir::InstTag.CONSTANT)
			{
				accum_tag = op.tag;
				accum_ty = op.ty;
			}
			else if (op.tag != accum_tag || op.ty != accum_ty)
			{
				return false;
			}
		}
		bool accumulate = accum_tag != ir::InstTag.CONSTANT;
		if (accumulate)
		{
			foreach (ref : decl.body)
			{
				ir::Inst inst = decl.instructions[(sz)ref];
				if (inst.tag == ir::InstTag.RET_PAIR) return false;
				if (inst.tag == ir::InstTag.RET && (inst.data.ref == ir::NONE || decl.instructions[(sz)inst.data.ref].ty != accum_ty)) return false;
			}
		}
		// The parameter ARGs must be the conventional leading ARG placements.
		ir::Ref[] args = alloc::new_array(mem, ir::Ref, (sz)arg_count);
		defer alloc::free(mem, args.ptr);
		for (usz i = 0; i < arg_count; i++) args[(sz)i] = decl.body[(sz)i];
		sz entry_label_pos = (sz)arg_count;
		if (entry_label_pos >= decl.body.len || decl.instructions[(sz)decl.body[entry_label_pos]].tag != ir::InstTag.LABEL) return false;
		ir::Ref entry_label = decl.body[entry_label_pos];
		DeclEditor editor;
		editor.begin(decl);
		// Replace old parameter uses before adding the PHIs, preserving their
		// initial incoming operands. Tail-call operands then refer to current values.
		ir::Ref[] phis = alloc::new_array(tmem, ir::Ref, (sz)arg_count);
		for (usz i = 0; i < arg_count; i++) phis[(sz)i] = editor.append({ .tag = ir::InstTag.ARG, .ty = editor.insts.entries[(sz)args[(sz)i]].ty });
		// The editor copy is rewritten in place; do not mutate the declaration until
		// the complete transaction is ready to commit.
		sz entry_loop_start = entry_label_pos + 1;
		while (entry_loop_start < editor.body.len())
		{
			ir::Ref entry_ref = editor.body.entries[entry_loop_start];
			ir::InstTag tag = editor.insts.entries[(sz)entry_ref].tag;
			if (tag != ir::InstTag.PHI && tag != ir::InstTag.ALLOC) break;
			entry_loop_start++;
		}
		for (usz i = 0; i < arg_count; i++)
		{
			for (sz body_pos = entry_loop_start; body_pos < editor.body.len(); body_pos++)
			{
				ir::Ref ref = editor.body.entries[body_pos];
				if ((usz)ref >= (usz)editor.insts.len()) continue;
				ir::Inst* inst = &editor.insts.entries[(sz)ref];
				@each_value_operand(inst; ir::Ref* slot) { if (*slot == args[(sz)i]) *slot = phis[(sz)i]; };
			}
		}
		String loop_name = string::tformat("tail.%s.loop.header", decl.name);
		ir::Ref loop_label = editor.new_label(loop_name);
		// The original entry block is now split: its leading PHIs and allocations
		// remain in the preheader, while its former control flow belongs to the loop
		// header. Update successor PHIs to name that new predecessor.
		foreach (ref : editor.body)
		{
			ir::Inst* inst = &editor.insts.entries[(sz)ref];
			if (inst.tag != ir::InstTag.PHI) continue;
			foreach (&input : inst.data.phi) if (input.label == entry_label) input.label = loop_label;
		}
		// Backedge PHI values use each call's argument tuple.
		for (usz i = 0; i < arg_count; i++)
		{
			ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, (sz)(sites.len() + 1));
			inputs[0] = { .label = entry_label, .value = args[(sz)i] };
			foreach (site_index, site : sites)
			{
				ir::Inst* call = &editor.insts.entries[(sz)site.call_ref];
				ir::Ref pred_label = site.block_label == entry_label ? loop_label : site.block_label;
				ir::Ref arg_value = call.data.call.args[(sz)i];
				if (editor.insts.entries[(sz)arg_value].ty != editor.insts.entries[(sz)args[(sz)i]].ty)
				{
					ir::Ref truncated = editor.append({ .tag = ir::InstTag.TRUNC, .data.ref = arg_value, .ty = editor.insts.entries[(sz)args[(sz)i]].ty });
					// Place the narrowing conversion in the tail predecessor before its call.
					sz call_body_pos = -1;
					for (sz p = 0; p < editor.body.len(); p++) if (editor.body.entries[p] == site.call_ref) { call_body_pos = p; break; }
					if (call_body_pos < 0) { editor.free(); return false; }
					editor.insert_body(call_body_pos, truncated);
					arg_value = truncated;
				}
				inputs[(sz)site_index + 1] = { .label = pred_label, .value = arg_value };
			}
			editor.insts.entries[(sz)phis[(sz)i]] = { .tag = ir::InstTag.PHI, .data.phi = inputs, .ty = editor.insts.entries[(sz)args[(sz)i]].ty };
		}
		// Keep the original entry allocations and PHIs in the preheader, then
		// jump into the loop header and place the loop-carried PHIs there.
		sz header_pos = entry_label_pos + 1;
		while (header_pos < editor.body.len())
		{
			ir::Ref entry_ref = editor.body.entries[header_pos];
			ir::InstTag tag = editor.insts.entries[(sz)entry_ref].tag;
			if (tag != ir::InstTag.PHI && tag != ir::InstTag.ALLOC) break;
			header_pos++;
		}
		ir::Ref preheader_jump = editor.append({ .tag = ir::InstTag.JMP, .data.ref = loop_label, .ty = value_interner::REF_NORETURN });
		// The accumulator: identity on entry, `acc op x` from accumulating
		// sites, unchanged from plain ones; returns yield `acc op value`.
		ir::Ref acc = ir::NONE;
		ir::Ref identity = ir::NONE;
		if (accumulate)
		{
			identity = editor.append({ .tag = ir::InstTag.CONSTANT,
				.data.constant = accum_tag == ir::InstTag.ADD ? value_interner::REF_ZERO : value_interner::REF_ONE, .ty = accum_ty });
			acc = editor.append({ .tag = ir::InstTag.PHI, .ty = accum_ty });
		}
		editor.insert_body(header_pos, preheader_jump);
		editor.insert_body(header_pos + 1, loop_label);
		for (usz i = 0; i < arg_count; i++) editor.insert_body(header_pos + 2 + (sz)i, phis[(sz)i]);
		if (accumulate)
		{
			editor.insert_body(header_pos + 2 + (sz)arg_count, acc);
			ir::PhiInput[] acc_inputs = alloc::new_array(&decl.arena, ir::PhiInput, (sz)(sites.len() + 1));
			acc_inputs[0] = { .label = entry_label, .value = identity };
			foreach (site_index, site : sites)
			{
				ir::Ref pred_label = site.block_label == entry_label ? loop_label : site.block_label;
				ir::Ref next = acc;
				if (site.accum != ir::NONE)
				{
					// Parameter uses were redirected to the loop PHIs above; the
					// operand must be too.
					ir::Ref operand = site.accum_operand;
					for (usz i = 0; i < arg_count; i++) if (operand == args[(sz)i]) operand = phis[(sz)i];
					next = editor.append({ .tag = accum_tag, .data.bin = { .lhs = acc, .rhs = operand }, .ty = accum_ty });
					sz call_pos = -1;
					for (sz p = 0; p < editor.body.len(); p++) if (editor.body.entries[p] == site.call_ref) { call_pos = p; break; }
					if (call_pos < 0) { editor.free(); return false; }
					editor.insert_body(call_pos, next);
				}
				acc_inputs[(sz)site_index + 1] = { .label = pred_label, .value = next };
			}
			editor.insts.entries[(sz)acc].data.phi = acc_inputs;
		}
		foreach (site : sites)
		{
			if (site.needs_jump)
			{
				ir::Ref jump_ref = editor.append({ .tag = ir::InstTag.JMP, .data.ref = loop_label, .ty = value_interner::REF_NORETURN });
				sz call_pos = -1;
				for (sz p = 0; p < editor.body.len(); p++) if (editor.body.entries[p] == site.call_ref) { call_pos = p; break; }
				if (call_pos < 0) { editor.free(); return false; }
				editor.insert_body(call_pos, jump_ref);
			}
			else
			{
				editor.insts.entries[(sz)site.ret_ref] = { .tag = ir::InstTag.JMP, .data.ref = loop_label, .ty = value_interner::REF_NORETURN };
			}
			editor.insts.entries[(sz)site.call_ref].tag = ir::InstTag.ARG;
			editor.insts.entries[(sz)site.call_ref].data = {};
			if (site.return_phi != ir::NONE)
			{
				ir::Inst* phi = &editor.insts.entries[(sz)site.return_phi];
				ir::Ref removed_pred = site.block_label == entry_label ? loop_label : site.block_label;
				usz keep_count = 0;
				foreach (input : phi.data.phi) if (input.label != removed_pred) keep_count++;
				ir::PhiInput[] kept = alloc::new_array(&decl.arena, ir::PhiInput, (sz)keep_count);
				usz write_input = 0;
				foreach (input : phi.data.phi) if (input.label != removed_pred) kept[(sz)write_input++] = input;
				phi.data.phi = kept;
			}
		}
		// The call value has become a tombstone and must no longer be body-placed,
		// nor the `call op x` that combined it.
		sz write = 0;
		for (sz read = 0; read < editor.body.len(); read++)
		{
			ir::Ref ref = editor.body.entries[read];
			bool is_tail_call = false;
			foreach (site : sites) if (site.call_ref == ref || (site.accum != ir::NONE && site.accum == ref)) is_tail_call = true;
			if (is_tail_call) continue;
			editor.body.entries[write++] = ref;
		}
		while (editor.body.len() > write) editor.body.pop()!!;
		foreach (site : sites)
		{
			if (site.accum == ir::NONE) continue;
			editor.insts.entries[(sz)site.accum].tag = ir::InstTag.ARG;
			editor.insts.entries[(sz)site.accum].data = {};
		}
		if (accumulate)
		{
			// Every remaining return combines its value with the accumulator.
			for (sz pos = 0; pos < editor.body.len(); pos++)
			{
				ir::Ref ref = editor.body.entries[pos];
				if (editor.insts.entries[(sz)ref].tag != ir::InstTag.RET) continue;
				ir::Ref value = editor.insts.entries[(sz)ref].data.ref;
				ir::Ref combined = editor.append({ .tag = accum_tag, .data.bin = { .lhs = acc, .rhs = value }, .ty = accum_ty });
				editor.insert_body(pos, combined);
				editor.insts.entries[(sz)ref].data.ref = combined;
				pos++;
			}
		}
		foreach (site : sites) inline_retire_unused_call_symbol(&editor, site.symbol_ref);
		editor.commit();
		return true;
	};
}

fn bool tail_call_elim_all(ir::Ir* graph)
{
	@pool()
	{
		bool changed = false;
		foreach (&decl : graph.decls) changed = tail_call_elim(decl, graph.interner) || changed;
		return changed;
	};
}

<* Inline direct same-IR calls after callees have been processed. *>
fn bool inline_calls(ir::Ir* graph, OptOptions opts)
{
	@pool()
	{
		usz threshold;
		switch (opts.level)
		{
			case code_gen_options::OptimizationLevel.O2: threshold = 40;
			case code_gen_options::OptimizationLevel.O3:
			case code_gen_options::OptimizationLevel.FAST: threshold = 120;
			default: return false;
		}
		InlineCallGraph calls = build_inline_call_graph(graph);
		defer calls.free();
		bool changed = false;
		foreach (decl_index : calls.bottom_up)
		{
			@pool()
			{
				ir::Decl* caller = &graph.decls.entries[(sz)decl_index];
				if (caller.kind != ir::DeclKind.FUNCTION || caller.body.len == 0) continue;
				// This inline pass avoids recursive expansion by treating a whole SCC as one unit.
				bool recursive_caller = false;
				foreach (callee_index : calls.edges[(sz)decl_index])
				{
					if (calls.scc[(sz)callee_index] == calls.scc[(sz)decl_index]) recursive_caller = true;
				}
				list::List{ir::Ref} worklist;
				worklist.init(mem);
				foreach (ref : caller.body)
				{
					if ((usz)ref < (usz)caller.instructions.len && caller.instructions[(sz)ref].tag == ir::InstTag.CALL) worklist.push(ref);
				}
				if (!worklist.len())
				{
					worklist.free();
					continue;
				}
				// Only inlining removes a worklist call from the body, and it removes just
				// that call. Its uses are recomputed after each successful inline.
				usz original_count = (usz)caller.instructions.len;
				bool[] inlined = alloc::new_array(tmem, bool, (sz)original_count);
				for (usz i = 0; i < original_count; i++) inlined[i] = false;
				InlineUseInfo uses = {
					.count = alloc::new_array(mem, uint, (sz)original_count),
					.has_call_hi = alloc::new_array(mem, bool, (sz)original_count),
				};
				bool uses_valid = false;
				foreach (call_ref : worklist)
				{
					if ((usz)call_ref >= (usz)caller.instructions.len || inlined[(sz)call_ref]) continue;
					ir::Inst* call = &caller.instructions[(sz)call_ref];
					if (call.tag != ir::InstTag.CALL || (usz)call.data.call.func >= (usz)caller.instructions.len) continue;
					ir::Inst* func = &caller.instructions[(sz)call.data.call.func];
					if (func.tag != ir::InstTag.SYMBOL) continue;
					// Calls to external symbols (including C99 external `inline` definitions,
					// which gen_ir does not emit) stay unresolved SYMBOLs.
					uint callee_index = inline_decl_index(&calls.decl_indices, func.data.label);
					// LLVM rejects self-recursive callees; C3 also skips every same-SCC call,
					// which keeps mutual recursion bounded without CGSCC inline history.
					if (callee_index == NONE_BLOCK || calls.scc[(sz)callee_index] == calls.scc[(sz)decl_index]) continue;
					ir::Decl* callee = &graph.decls.entries[(sz)callee_index];
					// Escaping callee allocas are fine: they are hoisted to the caller entry
					// (inline_entry_alloc_position), as LLVM's InlineFunction hoists static
					// allocas. See test/test_suite/run/inline_escaping_alloca_loop.c.
					if (callee.kind != ir::DeclKind.FUNCTION || callee.body.len == 0 || inline_unsupported_control(callee)) continue;
					// Never inline a weak body: the linker may pick another definition.
					if (callee.inline_hint == ir::InlineHint.NEVER || callee.is_weak) continue;
					if (inline_arg_count(callee) != (usz)call.data.call.args.len) continue;
					// Recursive callers get a modest stack-growth cap for inlined fixed allocas.
					// always_inline does not override it (nor the SCC and control checks above),
					// mirroring LLVM, which reports such always_inline calls as not inlinable.
					if (recursive_caller && inline_alloca_bytes(callee) > 1024) continue;
					usz cost = inline_body_cost(callee);
					// Unlike LLVM's hasOneLiveUse bonus, this count ignores address-taken uses.
					bool one_call_internal = callee.linkage == ir::Linkage.INTERNAL && calls.call_count[(sz)callee_index] == 1;
					// always_inline skips only the cost threshold. There is no inliner below
					// O2, so the attribute has no effect at O0/O1 (GCC inlines it at O0).
					if (cost > threshold && !one_call_internal && callee.inline_hint != ir::InlineHint.ALWAYS) continue;
					if (!uses_valid)
					{
						uses.compute(caller);
						uses_valid = true;
					}
					if (inline_one_call(graph, caller, callee, call_ref, &uses))
					{
						changed = true;
						inlined[(sz)call_ref] = true;
						uses_valid = false;
					}
				}
				alloc::free(mem, uses.count.ptr);
				alloc::free(mem, uses.has_call_hi.ptr);
				worklist.free();
			};
		}
		return changed;
	};
}

fn bool verify_error(ir::ErrorList* errors, String name, String message)
{
	errors.put(name, string::format(errors.allocator, "verify: %s", message));
	return false;
}

fn bool valid_ref(ir::Decl* decl, ir::Ref ref) => ref != ir::NONE && (usz)ref < (usz)decl.instructions.len;

fn bool verify_decl(ir::Decl* decl, ir::ErrorList* errors)
{
	@pool()
	{
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return true;
		usz inst_count = decl.instructions.len;
		usz body_len = decl.body.len;
		bool[] placed = alloc::new_array(tmem, bool, (sz)inst_count);
		uint[] body_position = alloc::new_array(tmem, uint, (sz)inst_count);
		for (usz i = 0; i < inst_count; i++)
		{
			placed[i] = false; body_position[i] = NONE_BLOCK;
		}
		for (usz i = 0; i < body_len; i++)
		{
			ir::Ref ref = decl.body[i];
			if (!valid_ref(decl, ref)) return verify_error(errors, decl.name, "body contains an invalid instruction ref");
			if (placed[(sz)ref]) return verify_error(errors, decl.name,
				string::tformat("body places instruction %d (%s) more than once", ref, decl.instructions[(sz)ref].tag.name));
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
			if (arg.data.arg.location_kind == ir::ArgLocationKind.GP_REGISTER && arg.data.arg.location >= (decl.darwin ? 9 : 6))
			{
				return verify_error(errors, decl.name, "ARG GP register index is out of range");
			}
			if (arg.data.arg.location_kind == ir::ArgLocationKind.SSE_REGISTER && arg.data.arg.location >= 8)
			{
				return verify_error(errors, decl.name, "ARG SSE register index is out of range");
			}
			if (arg.data.arg.location_kind == ir::ArgLocationKind.STACK &&
				((!decl.darwin && (arg.data.arg.location % 8 != 0 || arg.data.arg.stack_size < 8 || arg.data.arg.stack_size % 8 != 0)) || arg.data.arg.stack_size == 0 || arg.data.arg.stack_size > (uint)(int::max - 16) ||
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
		bool[] label_seen = alloc::new_array(tmem, bool, (sz)inst_count);
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
			if (inst.tag == ir::InstTag.CALL && inst.data.call.darwin)
			{
				ir::CallData call = inst.data.call;
				if (call.locations.len != call.args.len || !call.result.valid()) return verify_error(errors, decl.name, "invalid Darwin CALL ABI metadata");
				if (call.result.size && (!call.args.len || !valid_ref(decl, call.args[0]) || decl.instructions[(sz)call.args[0]].ty != value_interner::REF_PTR)) return verify_error(errors, decl.name, "Darwin aggregate CALL needs result storage as its first argument");
				foreach (index, location : call.locations)
				{
					bool valid = false;
					switch (location.location_kind)
					{
						case GP_REGISTER: valid = location.stack_size == 0 && (location.location < 8 || (location.location == 8 && index == 0 && call.result.size));
						case SSE_REGISTER: valid = location.stack_size == 0 && location.location < 8;
						case STACK: valid = (location.stack_size == 1 || location.stack_size == 2 || location.stack_size == 4 || location.stack_size == 8) && location.location <= (uint)(int::max - 16) - location.stack_size;
						default: break;
					}
					if (!valid) return verify_error(errors, decl.name, "invalid Darwin CALL argument location");
				}
			}
			if (inst.nsw && (!inst.tag.allows_nsw() || inst.ty == value_interner::REF_PTR))
			{
				return verify_error(errors, decl.name,
					string::tformat("nsw on %s %d, which is not an integer ADD/SUB/MUL", inst.tag.name, ref));
			}
			if (inst.tag == ir::InstTag.CALL_HI)
			{
				if (i == 0 || inst.data.ref != decl.body[i - 1] ||
					(usz)inst.data.ref >= inst_count || decl.instructions[(sz)inst.data.ref].tag != ir::InstTag.CALL)
				{
					return verify_error(errors, decl.name, "CALL_HI must immediately follow its referenced CALL");
				}
				if (inst.ty != value_interner::REF_I64 && inst.ty != value_interner::REF_F64)
				{
					return verify_error(errors, decl.name, "CALL_HI result must be i64 or f64");
				}
			}
			if (inst.tag == ir::InstTag.RET_PAIR)
			{
				if ((usz)inst.data.bin.lhs >= inst_count || (usz)inst.data.bin.rhs >= inst_count ||
					!is_eightbyte_type(decl.instructions[(sz)inst.data.bin.lhs].ty) ||
					!is_eightbyte_type(decl.instructions[(sz)inst.data.bin.rhs].ty))
				{
					return verify_error(errors, decl.name, "RET_PAIR operands must be i64 or f64");
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
		Cfg cfg = build_cfg(decl, mem);
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
	};
}

<* Verify function IR invariants; non-function declarations are skipped. *>
fn bool verify(ir::Ir* graph, ir::ErrorList* errors)
{
	foreach (&decl : graph.decls)
	{
		if (!verify_decl(decl, errors)) return false;
	}
	return true;
}

<* Drop instructions no longer placed in a function body and renumber the rest.
   Passes leave replaced instructions behind as unplaced tombstones (refs stay
   stable while optimizing), and edits copy payloads into the decl arena
   without freeing old ones; after -O2 most of `instructions` is dead.
   Kept: every body ref plus anything a kept instruction references, in their
   original relative order. Payloads and the name move to a fresh arena.
   Invalidates every Ref held outside the decl, so it runs after `run`. *>
fn void compact(ir::Ir* graph)
{
	foreach (&decl : graph.decls)
	{
		if (decl.kind == ir::DeclKind.FUNCTION) compact_decl(decl);
	}
}

<* Compact only functions whose instruction array is mostly tombstones, so
   the per-pass cost stays proportional to the garbage it frees. *>
fn void compact_sparse(ir::Ir* graph)
{
	foreach (&decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.FUNCTION) continue;
		if (decl.instructions.len < decl.body.len * 2) continue;
		compact_decl(decl);
	}
}

<* After each pass: optionally reclaim tombstones, then optionally verify. *>
fn bool pass_checkpoint(ir::Ir* graph, OptOptions* opts, ir::ErrorList* errors)
{
	if (opts.compact) compact_sparse(graph);
	return !opts.verify || verify(graph, errors);
}

<* Page size for a compacted decl arena: the kept payload bytes (plus per-chunk
   overhead), clamped to [512, 4096]. Most functions carry well under 4 KiB of
   labels/PHIs/call args, and a fixed 4 KiB page per function adds up across a
   whole translation unit. Larger payloads keep 4 KiB pages for later growth. *>
fn usz compact_arena_page_size(ir::Decl* decl, bool[] keep)
{
	const usz CHUNK_OVERHEAD = 32;
	usz need = decl.name.len + CHUNK_OVERHEAD;
	foreach (i, &inst : decl.instructions)
	{
		if (!keep[i]) continue;
		switch (inst.tag)
		{
			case ir::InstTag.LABEL:
			case ir::InstTag.SYMBOL:
				need += inst.data.label.len + CHUNK_OVERHEAD;
			case ir::InstTag.PHI:
				need += inst.data.phi.len * ir::PhiInput::size + CHUNK_OVERHEAD;
			case ir::InstTag.CALL:
				usz args = inst.data.call.args.len;
				need += args * (ir::Ref::size + bool::size + uint::size) + 3 * CHUNK_OVERHEAD;
			case ir::InstTag.SWITCH:
				usz cases = inst.data.switch_data.values.len;
				need += cases * (value_interner::InternerRef::size + ir::Ref::size) + 2 * CHUNK_OVERHEAD;
			default: break;
		}
	}
	return min(max(need, (usz)512), (usz)4096);
}

fn void compact_decl(ir::Decl* decl)
{
	@pool()
	{
		usz count = decl.instructions.len;
		if (!count) return;
		bool[] keep = alloc::new_array(tmem, bool, (sz)count);
		list::List{ir::Ref} pending;
		pending.init(mem, 0);
		defer pending.free();
		foreach (ref : decl.body)
		{
			if ((usz)ref >= count || keep[(sz)ref]) continue;
			keep[(sz)ref] = true;
			pending.push(ref);
		}
		while (pending.len())
		{
			ir::Ref ref = pending.pop()!!;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			@each_value_operand(inst; ir::Ref* slot)
			{
				if ((usz)*slot < count && !keep[(sz)*slot])
				{
					keep[(sz)*slot] = true;
					pending.push(*slot);
				}
			};
			@each_label_operand(inst; ir::Ref* slot)
			{
				if ((usz)*slot < count && !keep[(sz)*slot])
				{
					keep[(sz)*slot] = true;
					pending.push(*slot);
				}
			};
		}
		ir::Ref[] remap = alloc::new_array(tmem, ir::Ref, (sz)count);
		usz kept = 0;
		for (usz i = 0; i < count; i++) remap[i] = keep[i] ? (ir::Ref)kept++ : ir::NONE;
		DynamicArenaAllocator fresh;
		fresh.init(decl.allocator, (sz)compact_arena_page_size(decl, keep));
		ir::Inst[] instructions = alloc::new_array(decl.allocator, ir::Inst, (sz)kept);
		for (usz i = 0; i < count; i++)
		{
			if (!keep[i]) continue;
			ir::Inst inst = copy_inst_payload_into(&fresh, decl.instructions[i]);
			@each_value_operand(&inst; ir::Ref* slot)
			{
				if ((usz)*slot < count) *slot = remap[(sz)*slot];
			};
			@each_label_operand(&inst; ir::Ref* slot)
			{
				if ((usz)*slot < count) *slot = remap[(sz)*slot];
			};
			instructions[(sz)remap[i]] = inst;
		}
		foreach (&ref : decl.body) *ref = remap[(sz)*ref];
		String name = decl.name.copy(&fresh);
		alloc::free(decl.allocator, decl.instructions.ptr);
		decl.arena.free();
		decl.instructions = instructions;
		decl.arena = fresh;
		decl.name = name;
	};
}

alias FunctionPassFn = fn bool(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* analyses);

struct FunctionPass
{
	String name;
	FunctionPassFn run;
	// Loop restructuring passes only run in the post-IPO (O2+) group.
	bool loop_restructure;
}

fn bool fp_remove_unreachable_blocks(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> remove_unreachable_blocks(decl, fa);
fn bool fp_sroa(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa) => sroa(graph, decl, fa);
fn bool fp_mem2reg(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa) => mem2reg(graph, decl, fa);
fn bool fp_inst_simplify(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> inst_simplify(graph, decl, fa);
fn bool fp_gvn(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa) => gvn(graph, decl, fa);
fn bool fp_licm(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> loop_invariant_code_motion(graph, decl, fa);
fn bool fp_indvar_simplify(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> indvar_simplify(graph, decl, fa);
fn bool fp_narrow_truncated_arith(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> narrow_truncated_arith(graph, decl, fa);
fn bool fp_indvar_widen(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> indvar_widen(graph, decl, fa);
fn bool fp_loop_strength_reduce(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> loop_strength_reduce(graph, decl, fa);
fn bool fp_loop_vectorize(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> !opts.no_vectorize && loop_vectorize(graph, decl, fa);
fn bool fp_lftr(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> linear_function_test_replace(graph, decl, fa);
fn bool fp_loop_deletion(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> loop_deletion(graph, decl, fa);
fn bool fp_loop_full_unroll(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> loop_full_unroll(graph, decl, opts.level == code_gen_options::OptimizationLevel.O2 ? 128 : 256, fa);
fn bool fp_mem_opt(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa) => mem_opt(graph, decl, fa);
fn bool fp_correlated_value_prop(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> correlated_value_prop(graph, decl, fa);
fn bool fp_jump_thread(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa) => jump_thread(graph, decl, fa);
fn bool fp_const_prop(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa) => const_prop(graph, decl, fa);
fn bool fp_simplify_cfg(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa) => simplify_cfg(graph, decl, fa);
fn bool fp_dead_instruction_elim(ir::Ir* graph, ir::Decl* decl, OptOptions* opts, FunctionAnalyses* fa)
	=> dead_instruction_elim(decl, graph, fa);

<* Run a group of function passes one function at a time, so analyses built by
   one pass survive into the next until a pass reports a change. Function
   passes never add, remove or reorder declarations (module passes are the
   barriers between groups), so the decl name lookup stays valid too.
   Compaction and verification happen per function after each pass. *>
fn bool run_function_passes(ir::Ir* graph, FunctionPass[] passes, OptOptions* opts, ir::ErrorList* errors,
	bool loop_restructure)
{
	DeclLookup lookup;
	lookup.init(graph);
	defer lookup.free();
	graph.decl_lookup = &lookup;
	defer graph.decl_lookup = null;
	foreach (&decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) continue;
		FunctionAnalyses analyses;
		analyses.init(decl, graph.allocator);
		defer analyses.free();
		foreach (pass : passes)
		{
			if (pass.loop_restructure && !loop_restructure) continue;
			if (pass.run(graph, decl, opts, &analyses)) analyses.mark_dirty();
			// Catches a pass that edits but reports no change, and stale
			// shape kept by `Cfg.revalidate`.
			if (opts.verify && !analyses.matches_fresh())
			{
				return verify_error(errors, decl.name, string::tformat("analyses out of sync after %s", pass.name));
			}
			if (opts.compact && decl.instructions.len >= decl.body.len * 2)
			{
				compact_decl(decl);
				analyses.mark_dirty();
			}
			if (opts.verify && !verify_decl(decl, errors)) return false;
		}
	}
	return true;
}

<* Fixed pass pipeline entry point. *>
fn void? run(ir::Ir* graph, OptOptions opts, ir::ErrorList* errors)
{
	foreach (decl : graph.decls)
	{
		if (decl.darwin) { opts.no_ipo = true; opts.no_vectorize = true; }
	}
	if (opts.verify && !verify(graph, errors)) return VERIFY_FAIL~;
	// Relocation-owning globals can disappear at declaration DCE, before the
	// later O2 global pass. Keep their target names alive for the whole pipeline.
	HashMap{String, bool} relocation_escapes;
	relocation_escapes.init(graph.allocator);
	defer relocation_escapes.free();
	DynamicArenaAllocator relocation_escape_arena;
	relocation_escape_arena.init(graph.allocator, 1024);
	defer relocation_escape_arena.free();
	// The scalar pipeline shared by the O1 run and the post-IPO O2+ run; the
	// loop restructuring entries only run in the latter. inst_simplify is the
	// combined integer/float/instcombine peephole worklist. GVN handles
	// cross-block scalar and stable local-load CSE; mem_opt follows it for
	// precise store forwarding and dead-store elimination (both use the same
	// tracked-root model). SCCP leaves dead blocks for simplify_cfg, which
	// removes unreachable blocks itself.
	FunctionPass[*] scalar_passes = {
		{ "remove_unreachable_blocks", &fp_remove_unreachable_blocks, false },
		{ "sroa", &fp_sroa, false },
		{ "mem2reg", &fp_mem2reg, false },
		{ "inst_simplify", &fp_inst_simplify, false },
		{ "gvn", &fp_gvn, false },
		{ "loop_invariant_code_motion", &fp_licm, false },
		{ "indvar_simplify", &fp_indvar_simplify, true },
		{ "loop_deletion", &fp_loop_deletion, true },
		{ "loop_full_unroll", &fp_loop_full_unroll, true },
		{ "indvar_widen", &fp_indvar_widen, true },
		{ "narrow_truncated_arith", &fp_narrow_truncated_arith, false },
		{ "loop_vectorize", &fp_loop_vectorize, true },
		{ "loop_strength_reduce", &fp_loop_strength_reduce, true },
		{ "mem_opt", &fp_mem_opt, false },
		{ "correlated_value_prop", &fp_correlated_value_prop, false },
		{ "jump_thread", &fp_jump_thread, false },
		{ "const_prop", &fp_const_prop, false },
		{ "simplify_cfg", &fp_simplify_cfg, false },
		{ "inst_simplify", &fp_inst_simplify, false },
		{ "dead_instruction_elim", &fp_dead_instruction_elim, false },
		// Last: it needs the dead index arithmetic strength reduction left behind gone.
		{ "linear_function_test_replace", &fp_lftr, true },
	};
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
			bool ipo = !opts.no_ipo && (opts.level == code_gen_options::OptimizationLevel.O2 ||
				opts.level == code_gen_options::OptimizationLevel.O3 ||
				opts.level == code_gen_options::OptimizationLevel.FAST);
			// Inspect global relocations before declaration DCE can discard an
			// otherwise-unused pointer global. Its target still has to be treated
			// as escaped by the global optimizer's conservative memory analysis.
			if (ipo)
			{
				global_opt(graph, opts, &relocation_escapes, &relocation_escape_arena);
				if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			}
			eliminate_dead_declarations(graph, opts.whole_program, opts.keep_external_definitions);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			if (!run_function_passes(graph, &scalar_passes, &opts, errors, false)) return VERIFY_FAIL~;
			// Declaration DCE ran before instruction DCE. LLVM pipelines may rerun
			// GlobalDCE here; C3 keeps definitions made unused at O1 and reruns only at O2+.
			if (!ipo)
			{
				if (opts.no_ipo && !run_function_passes(graph, &scalar_passes, &opts, errors, true)) return VERIFY_FAIL~;
				return;
			}
			tail_call_elim_all(graph);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			inline_calls(graph, opts);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			ipsccp(graph, opts);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			dead_arg_elim(graph, opts);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			global_opt(graph, opts, &relocation_escapes, &relocation_escape_arena);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			infer_function_attrs(graph);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
			if (!run_function_passes(graph, &scalar_passes, &opts, errors, true)) return VERIFY_FAIL~;
			dead_function_elim(graph, opts.whole_program, opts.keep_external_definitions);
			if (!pass_checkpoint(graph, &opts, errors)) return VERIFY_FAIL~;
	}
}

<* RET_PAIR / CALL_HI carry one SysV eightbyte: INTEGER as i64, SSE as f64. *>
fn bool is_eightbyte_type(value_interner::InternerRef ty) => ty == value_interner::REF_I64 || ty == value_interner::REF_F64;
