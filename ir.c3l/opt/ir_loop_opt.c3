// Natural loop discovery, loop preheaders, and conservative scalar LICM.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, std::collections::list;
import std::sort;

struct Loop
{
	uint header;
	uint parent;
	uint depth;
	list::List{uint} blocks;
	list::List{uint} latches;
	list::List{uint} exits;
	uint preheader;
}

struct LoopInfo
{
	Allocator allocator;
	list::List{Loop} loops;
	bool[] in_loop_scratch;
	uint[] innermost_of_block;
}

fn void LoopInfo.free(&self)
{
	foreach (&loop : self.loops)
	{
		loop.blocks.free(); loop.latches.free(); loop.exits.free();
	}
	self.loops.free();
	if (self.in_loop_scratch.len) alloc::free(self.allocator, self.in_loop_scratch.ptr);
	if (self.innermost_of_block.len) alloc::free(self.allocator, self.innermost_of_block.ptr);
	*self = {};
}

fn bool Loop.contains(&self, LoopInfo* info, uint block)
{
	if ((usz)block >= (usz)info.innermost_of_block.len) return false;
	// A loop is identified by its header (one loop per header), so walk the
	// enclosing chain of `block` instead of first searching `info.loops` for
	// `self`: that search made each call O(loops) and indvar_simplify quadratic.
	uint current = info.innermost_of_block[(sz)block];
	while (current != NONE_BLOCK)
	{
		if (current >= info.loops.len()) return false;
		Loop* loop = &info.loops.entries[(sz)current];
		if (loop.header == self.header) return true;
		current = loop.parent;
	}
	return false;
}

fn bool loop_body_contains(Loop* loop, uint block)
{
	// Loop bodies are sorted by block index after discovery.
	sz low = 0;
	sz high = loop.blocks.len();
	while (low < high)
	{
		sz mid = low + (high - low) / 2;
		uint member = loop.blocks.entries[mid];
		if (member == block) return true;
		if (member < block)
		{
			low = mid + 1;
		}
		else
		{
			high = mid;
		}
	}
	return false;
}

fn uint loop_existing_preheader(ir::Decl* decl, Cfg* cfg, LoopInfo* info, uint loop_index)
{
	if (loop_index >= info.loops.len()) return NONE_BLOCK;
	Loop* loop = &info.loops.entries[(sz)loop_index];
	uint pred = NONE_BLOCK;
	foreach (outside : cfg.blocks[(sz)loop.header].preds)
	{
		if (!cfg.reachable[(sz)outside] || loop_body_contains(loop, outside)) continue;
		if (pred != NONE_BLOCK) return NONE_BLOCK;
		pred = outside;
	}
	if (pred == NONE_BLOCK) return NONE_BLOCK;
	if (cfg.blocks[(sz)pred].succs.len() != 1) return NONE_BLOCK;
	sz term_pos = block_terminator_position(decl, &cfg.blocks[(sz)pred]);
	if (term_pos == cfg.blocks[(sz)pred].end) return pred;  // implicit fallthrough edge
	ir::Ref term = decl.body[term_pos];
	return decl.instructions[(sz)term].tag == ir::InstTag.JMP &&
	decl.instructions[(sz)term].data.ref == cfg.blocks[(sz)loop.header].label ? pred : NONE_BLOCK;
}

fn LoopInfo compute_loops(Cfg* cfg, Allocator allocator)
{
	LoopInfo info = { .allocator = allocator };
	info.loops.init(allocator);
	info.in_loop_scratch = alloc::new_array(allocator, bool, (sz)cfg.blocks.len);
	info.innermost_of_block = alloc::new_array(allocator, uint, (sz)cfg.blocks.len);
	for (usz i = 0; i < cfg.blocks.len; i++)
	{
		info.in_loop_scratch[i] = false;
		info.innermost_of_block[i] = NONE_BLOCK;
	}
	// A header is discovered once; all reachable dominated incoming edges are latches.
	for (usz header = 0; header < cfg.blocks.len; header++)
	{
		if (!cfg.reachable[header]) continue;
		Loop loop = { .header = (uint)header, .parent = NONE_BLOCK, .depth = 1, .preheader = NONE_BLOCK };
		loop.blocks.init(allocator); loop.latches.init(allocator); loop.exits.init(allocator);
		foreach (pred : cfg.blocks[header].preds)
		{
			if (cfg.reachable[(sz)pred] && cfg.dominates((uint)header, pred)) loop.latches.push(pred);
		}
		if (!loop.latches.len())
		{
			loop.blocks.free(); loop.latches.free(); loop.exits.free(); continue;
		}
		loop.blocks.push((uint)header);
		info.in_loop_scratch[header] = true;
		foreach (latch : loop.latches)
		{
			if (info.in_loop_scratch[(sz)latch]) continue;
			info.in_loop_scratch[(sz)latch] = true;
			loop.blocks.push(latch);
		}
		for (sz work = 1; work < loop.blocks.len(); work++)
		{
			uint block = loop.blocks.entries[work];
			foreach (pred : cfg.blocks[(sz)block].preds)
			{
				if (!cfg.reachable[(sz)pred] || info.in_loop_scratch[(sz)pred]) continue;
				info.in_loop_scratch[(sz)pred] = true;
				loop.blocks.push(pred);
			}
		}
		quicksort(loop.blocks.array_view());
		foreach (member : loop.blocks) info.in_loop_scratch[(sz)member] = false;
		info.loops.push(loop);
	}
	// Sort by ascending body size in O(n log n). Packing the original index into the
	// low bits gives deterministic ordering for equal-sized loops.
	ulong[] loop_keys = alloc::new_array(allocator, ulong, info.loops.len());
	defer if (loop_keys.len) alloc::free(allocator, loop_keys.ptr);
	Loop[] sorted_loops = alloc::new_array(allocator, Loop, info.loops.len());
	defer if (sorted_loops.len) alloc::free(allocator, sorted_loops.ptr);
	uint[] exit_marks = alloc::new_array(allocator, uint, (sz)cfg.blocks.len);
	defer if (exit_marks.len) alloc::free(allocator, exit_marks.ptr);
	for (usz i = 0; i < cfg.blocks.len; i++) exit_marks[i] = 0;
	foreach (i, loop : info.loops) loop_keys[i] = ((ulong)(uint)loop.blocks.len() << 32) | (ulong)(uint)i;
	quicksort(loop_keys[..]);
	foreach (i, key : loop_keys) sorted_loops[i] = info.loops.entries[(sz)(uint)key];
	if (info.loops.len()) info.loops.entries[:info.loops.len()] = sorted_loops[:info.loops.len()];
	// Bodies are nested for reducible loops. Loops are visited in ascending
	// size order, so inner loops come first: a block's first owner is its
	// innermost loop, and the first larger loop to contain an inner loop's
	// blocks is that inner loop's direct parent. (Reading the header's owner
	// here instead would always see the loop itself or nothing.)
	foreach (&loop : info.loops) loop.parent = NONE_BLOCK;
	foreach (i, &loop : info.loops)
	{
		uint stamp = (uint)i + 1;
		foreach (block : loop.blocks)
		{
			uint owner = info.innermost_of_block[(sz)block];
			if (owner == NONE_BLOCK)
			{
				info.innermost_of_block[(sz)block] = (uint)i;
				continue;
			}
			while (info.loops.entries[(sz)owner].parent != NONE_BLOCK) owner = info.loops.entries[(sz)owner].parent;
			if (owner != (uint)i) info.loops.entries[(sz)owner].parent = (uint)i;
		}
		foreach (block : loop.blocks) info.in_loop_scratch[(sz)block] = true;
		foreach (block : loop.blocks)
		{
			foreach (succ : cfg.blocks[(sz)block].succs)
			{
				if (info.in_loop_scratch[(sz)succ]) continue;
				if (exit_marks[(sz)succ] == stamp) continue;
				exit_marks[(sz)succ] = stamp;
				loop.exits.push(succ);
			}
		}
		foreach (block : loop.blocks) info.in_loop_scratch[(sz)block] = false;
	}
	foreach (&loop : info.loops)
	{
		loop.depth = 1;
		uint cursor = loop.parent;
		while (cursor != NONE_BLOCK && cursor < info.loops.len())
		{
			loop.depth++;
			cursor = info.loops.entries[(sz)cursor].parent;
		}
	}
	return info;
}

fn bool ensure_preheaders(ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.blocks.len) return false;
		if (!cfg.idom.len) cfg.compute_dominators();
		LoopInfo* loops = analyses.get_loops();
		DeclEditor editor; editor.begin(decl);
		bool changed = false;
		ir::Ref[] ph_labels = alloc::new_array(tmem, ir::Ref, cfg.blocks.len);
		list::List{ir::Ref}[] preheader_phis = alloc::new_array(mem, list::List{ir::Ref}, cfg.blocks.len);
		uint[] fallthrough_fixups = alloc::new_array(tmem, uint, cfg.blocks.len);
		for (usz i = 0; i < cfg.blocks.len; i++)
		{
			ph_labels[i] = ir::NONE; fallthrough_fixups[i] = NONE_BLOCK;
			preheader_phis[i].init(mem);
		}
		defer
		{
			foreach (&phis : preheader_phis) phis.free(); alloc::free(mem, preheader_phis.ptr);
		}
		foreach (loop_index, &loop : loops.loops)
		{
			uint header = loop.header;
			if (header == 0) continue;
			list::List{uint} outside; outside.init(mem); defer outside.free();
			foreach (pred : cfg.blocks[(sz)header].preds)
			{
				if (!cfg.reachable[(sz)pred] || loop_body_contains(loop, pred)) continue;
				outside.push(pred);
			}
			if (!outside.len()) continue;
			uint existing_preheader = loop_existing_preheader(decl, cfg, loops, (uint)loop_index);
			if (existing_preheader != NONE_BLOCK)
			{
				loop.preheader = existing_preheader; continue;
			}
			String label_name = string::tformat("loop.ph.%s.%d", decl.name, cfg.blocks[(sz)header].label);
			ir::Ref ph_label = editor.new_label(label_name);
			loop.preheader = (uint)(cfg.blocks.len + header); ph_labels[(sz)header] = ph_label;
			// Redirect explicit outside edges. An implicit predecessor immediately before the
			// header naturally falls through into the inserted preheader.
			foreach (pred : outside)
			{
				sz term_pos = block_terminator_position(decl, &cfg.blocks[(sz)pred]);
				if (term_pos < cfg.blocks[(sz)pred].end)
				{
					ir::Ref term_ref = decl.body[term_pos];
					cfg_redirect_target(&editor.insts.entries[(sz)term_ref], cfg.blocks[(sz)header].label, ph_label);
				}
			}
			// Split each leading header PHI's incoming edges.
			for (sz pos = cfg.blocks[(sz)header].start + 1; pos < cfg.blocks[(sz)header].end; pos++)
			{
				ir::Ref phi_ref = decl.body[pos];
				ir::Inst* phi = &editor.insts.entries[(sz)phi_ref];
				if (phi.tag != ir::InstTag.PHI) break;
				value_interner::InternerRef phi_ty = phi.ty;
				list::List{ir::PhiInput} outside_inputs; outside_inputs.init(mem); defer outside_inputs.free();
				list::List{ir::PhiInput} remaining; remaining.init(mem); defer remaining.free();
				foreach (input : phi.data.phi)
				{
					bool is_outside = false;
					foreach (pred : outside) if (input.label == cfg.blocks[(sz)pred].label) is_outside = true;
					if (is_outside)
					{
						outside_inputs.push(input);
					}
					else
					{
						remaining.push(input);
					}
				}
				if (!outside_inputs.len()) continue;
				ir::Ref incoming = outside_inputs.entries[0].value;
				bool same = true;
				foreach (input : outside_inputs) if (input.value != incoming) same = false;
				if (!same)
				{
					ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, outside_inputs.len());
					inputs[..] = outside_inputs.array_view()[..];
					ir::Ref new_phi = editor.append(
					{
						.tag = ir::InstTag.PHI, .data.phi = inputs, .ty = phi_ty
					}
					);
					preheader_phis[(sz)header].push(new_phi); incoming = new_phi;
				}
				remaining.push(
				{
					.label = ph_label, .value = incoming
				}
				);
				phi = &editor.insts.entries[(sz)phi_ref];
				phi.data.phi = alloc::new_array(&decl.arena, ir::PhiInput, remaining.len());
				phi.data.phi[..] = remaining.array_view()[..];
			}
			// A body-order fallthrough from an in-loop block must keep targeting the header.
			if (cfg.blocks[(sz)header].start > 0)
			{
				uint previous = NONE_BLOCK;
				foreach (b, block : cfg.blocks) if (block.end == cfg.blocks[(sz)header].start) previous = (uint)b;
				// Inserting a label before the header changes the physical fallthrough
				// even for an unreachable predecessor, which is not in the reachable
				// outside-edge set above. Preserve its original edge as well.
				if (previous != NONE_BLOCK &&
					(loop_body_contains(loop, previous) || !cfg.reachable[(sz)previous]) &&
				block_terminator_position(decl, &cfg.blocks[(sz)previous]) == cfg.blocks[(sz)previous].end)
				{
					fallthrough_fixups[(sz)previous] = (uint)editor.append(
					{
						.tag = ir::InstTag.JMP, .data.ref = cfg.blocks[(sz)header].label, .ty = value_interner::REF_VOID
					}
					);
				}
			}
			changed = true;
		}
		if (!changed)
		{
			editor.free(); return false;
		}
		editor.body.clear();
		// Keep leading ARGs before all basic blocks.
		usz arg_end = 0;
		while (arg_end < decl.body.len && decl.instructions[(sz)decl.body[arg_end]].tag == ir::InstTag.ARG) arg_end++;
		editor.body.push_all(decl.body[:(sz)arg_end]);
		foreach (b, &block : cfg.blocks)
		{
			if (ph_labels[b] != ir::NONE)
			{
				editor.body.push(ph_labels[b]);
				editor.body.push_all(preheader_phis[b].array_view());
				editor.body.push(editor.append(
				{
					.tag = ir::InstTag.JMP, .data.ref = block.label, .ty = value_interner::REF_VOID
				}
				));
			}
			editor.body.push_all(decl.body[block.start : block.end - block.start]);
			if (fallthrough_fixups[b] != NONE_BLOCK) editor.body.push((ir::Ref)fallthrough_fixups[b]);
		}
		editor.commit();
		analyses.mark_dirty();
		return true;
	};
}

struct LicmMemWrite
{
	MemAddr address;
	uint size;
	bool known_size;
}

struct LicmContext
{
	ir::Ir* graph;
	ir::Decl* decl;
	Loop* loop;
	Cfg* cfg;
	bool[] non_escaping;
	list::List{LicmMemWrite} writes;
	uint loop_index;
	uint writes_loop;
}

<* Lazily summarize writes in one loop. Stores retain their address and byte
   size; unknown roots go through mem_may_alias, whose escape rule proves they
   cannot reach a non-escaping allocation, while unknown sizes invalidate their
   known root. Atomic operations and VA_START invalidate their entire allocation
   root. Calls clobber any passed allocation unless the callee summary proves
   both non-capture and no writes through that argument. Fences add no writes. *>
fn void licm_collect_writes(LicmContext* context)
{
	if (context.writes_loop == context.loop_index) return;
	context.writes.clear();
	context.writes_loop = context.loop_index;
	ir::Decl* decl = context.decl;
	foreach (block_index : context.loop.blocks)
	{
		CfgBlock* block = &context.cfg.blocks[(sz)block_index];
		sz end = block_executable_end(decl, block);
		for (sz pos = block.start + 1; pos < end; pos++)
		{
			ir::Ref ref = decl.body[pos];
			ir::Inst* effect = &decl.instructions[(sz)ref];
			if (effect.tag == ir::InstTag.STORE)
			{
				MemAddr address = { .root = ir::NONE };
				bool known_address = mem_decompose_address(context.graph, decl.instructions, effect.data.bin.lhs, &address) &&
				address.root != ir::NONE;
				uint store_size = 0;
				bool known_size = (usz)effect.data.bin.rhs < (usz)decl.instructions.len &&
				mem_access_size(context.graph, decl.instructions[(sz)effect.data.bin.rhs].ty, &store_size);
				if (!known_address) address.root = ir::NONE;
				context.writes.push(
				{
					.address = address, .size = known_size ? store_size: 0, .known_size = known_size
				}
				);
			}
			else if (effect.tag == ir::InstTag.CALL)
			{
				ir::Decl* callee = mem_call_callee(context.graph, decl, effect);
				foreach (i, arg : effect.data.call.args)
				{
					MemAddr address = { .root = ir::NONE };
					if (!mem_decompose_address(context.graph, decl.instructions, arg, &address) || address.root == ir::NONE) continue;
					bool known_arg = callee != null && i < 64 &&
					(callee.attrs.arg_nocapture & ((ulong)1 << i)) != 0 &&
					(usz)i < (usz)effect.data.call.memory_copy_bytes.len &&
					effect.data.call.memory_copy_bytes[(sz)i] == 0;
					bool writes = !known_arg || (callee.attrs.arg_nowrite & ((ulong)1 << i)) == 0;
					if (writes) context.writes.push(
					{
						.address = address, .size = 0, .known_size = false
					}
					);
				}
			}
			else if (effect.tag == ir::InstTag.ATOMIC_LOAD || effect.tag == ir::InstTag.ATOMIC_STORE ||
				effect.tag == ir::InstTag.VA_START)
			{
				MemAddr address = { .root = ir::NONE };
				ir::Ref address_ref = effect.tag == ir::InstTag.VA_START ? effect.data.ref : effect.data.atomic.ptr;
				mem_decompose_address(context.graph, decl.instructions, address_ref, &address);
				context.writes.push(
				{
					.address = address, .size = 0, .known_size = false
				}
				);
			}
		}
	}
}

<* Hoist a LOAD only when its type has a known size, its pointer decomposes to
   a non-volatile ALLOC marked non-escaping, and its constant offset proves the
   full access lies within that allocation. Unknown offsets are rejected because
   an invariant variable index may be out of bounds. Then require that no STORE,
   atomic access, or VA_START write in the loop can alias those bytes. A CALL
   clobbers a passed root unless its summary proves no writes through that arg;
   calls with no such pointer and FENCEs add no writes.
   Pointers rooted in ARGs, SYMBOLs, or loaded pointers are never hoisted because
   the IR cannot prove that they do not refer to volatile MMIO. The caller
   also requires every value operand (including the address) to be loop invariant.
   With no loop write able to change the bytes, the preheader read has the same
   value as the load on every iteration; the in-bounds proof makes speculation
   safe even when the load's original block executes conditionally. *>
fn bool licm_load_invariant(LicmContext* context, ir::Inst inst)
{
	if (inst.is_volatile) return false;
	MemAddr load_address;
	uint load_size;
	if (!mem_access_size(context.graph, inst.ty, &load_size) ||
	!mem_decompose_address(context.graph, context.decl.instructions, inst.data.ref, &load_address) ||
	load_address.root == ir::NONE || !load_address.known_offset || load_address.offset < 0 ||
	(usz)load_address.root >= (usz)context.non_escaping.len ||
	!context.non_escaping[(sz)load_address.root] ||
	context.decl.instructions[(sz)load_address.root].tag != ir::InstTag.ALLOC) return false;
	ulong allocation_size = (ulong)context.decl.instructions[(sz)load_address.root].data.alloc.size;
	ulong offset = (ulong)load_address.offset;
	if (offset > allocation_size || load_size > allocation_size - offset) return false;
	licm_collect_writes(context);
	foreach (write : context.writes)
	{
		if ((!write.known_size && write.address.root == load_address.root) ||
		mem_may_alias(load_address, load_size, write.address, write.size, context.non_escaping)) return false;
	}
	return true;
}

fn bool licm_hoistable(ir::Ir* graph, LicmContext* context, ir::Inst inst)
{
	ScalarExpr key;
	if (scalar_expression(graph, inst, &key)) return true;
	if (inst.tag == ir::InstTag.LOAD) return licm_load_invariant(context, inst);
	switch (inst.tag)
	{
		case ir::InstTag.SDIV:
		case ir::InstTag.UDIV:
		case ir::InstTag.SREM:
		case ir::InstTag.UREM:
			ushort width;
			if (!const_prop_int_width(graph, inst.ty, &width) || width > 64) return false;
			ulong divisor;
			if (!scalar_constant_bits(graph, context.cfg.decl.instructions, inst.data.bin.rhs, &divisor) || divisor == 0) return false;
			if ((inst.tag == ir::InstTag.SDIV || inst.tag == ir::InstTag.SREM) && divisor == const_prop_mask(width)) return false;
			return true;
		default: return false;
	}
}

<* Emit a preheader's hoisted refs in hoist order, skipping refs a later
   (outer) loop moved further out. *>
fn void licm_emit_tail(DeclEditor* editor, list::List{ir::Ref} tail, uint[] home, uint block)
{
	foreach (ref : tail)
	{
		if (home[(sz)ref] == block) editor.body.push(ref);
	}
}

fn bool loop_invariant_code_motion(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		foreach (ref : decl.body)
		{
			ir::InstTag tag = decl.instructions[(sz)ref].tag;
			if (tag == ir::InstTag.LABEL_ADDR || tag == ir::InstTag.JMP_VAL) return false;
		}
		bool changed = ensure_preheaders(decl, analyses);
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.blocks.len) return changed;
		if (!cfg.idom.len) cfg.compute_dominators();
		LoopInfo* loops = analyses.get_loops();
		Uses* uses = analyses.get_uses();
		bool[] non_escaping = mem_compute_non_escaping(graph, decl, uses);
		defer if (non_escaping.len) alloc::free(mem, non_escaping.ptr);
		uint[] home = alloc::new_array(tmem, uint, decl.instructions.len);
		for (usz i = 0; i < decl.instructions.len; i++) home[i] = cfg.block_of_ref[i];
		list::List{ir::Ref}[] hoisted_tail = alloc::new_array(mem, list::List{ir::Ref}, cfg.blocks.len);
		for (usz i = 0; i < cfg.blocks.len; i++) hoisted_tail[i].init(mem);
		defer
		{
			foreach (&tail : hoisted_tail) tail.free(); alloc::free(mem, hoisted_tail.ptr);
		}
		// Visit loops in descending depth. Sorting packed keys avoids quadratic
		// insertion sorting when a function contains many short loops.
		uint[] loop_order = alloc::new_array(tmem, uint, (sz)loops.loops.len());
		ulong[] ordered_loops = alloc::new_array(tmem, ulong, (sz)loops.loops.len());
		ulong[] ordered_blocks = alloc::new_array(tmem, ulong, cfg.blocks.len);
		foreach (i, loop : loops.loops) ordered_loops[i] = ((ulong)(uint::max - loop.depth) << 32) | (ulong)(uint)i;
		quicksort(ordered_loops[..]);
		foreach (i, key : ordered_loops) loop_order[i] = (uint)key;
		foreach (selected : loop_order)
		{
			Loop* loop = &loops.loops.entries[(sz)selected];
			uint preheader = loop_existing_preheader(decl, cfg, loops, selected);
			if (preheader == NONE_BLOCK) continue;
			loop.preheader = preheader;
			LicmContext context = { .graph = graph, .decl = decl, .loop = loop, .cfg = cfg,
			.non_escaping = non_escaping, .loop_index = selected, .writes_loop = NONE_BLOCK };
			context.writes.init(mem);
			defer context.writes.free();
			// Visit only this loop's blocks, ordered by CFG RPO. Scanning the whole
			// function once for every loop made many small loops quadratic.
			foreach (i, block_index : loop.blocks)
			ordered_blocks[i] = ((ulong)cfg.rpo_position[(sz)block_index] << 32) | (ulong)block_index;
			quicksort(ordered_blocks[:(sz)loop.blocks.len()]);
			foreach (block_key : ordered_blocks[:(sz)loop.blocks.len()])
			{
				uint block_index = (uint)block_key;
				CfgBlock* block = &cfg.blocks[(sz)block_index];
				sz end = block_executable_end(decl, block);
				for (sz pos = block.start + 1; pos < end; pos++)
				{
					ir::Ref ref = decl.body[pos];
					ir::Inst inst = decl.instructions[(sz)ref];
					if (inst.tag == ir::InstTag.PHI || is_terminator(inst.tag) || !licm_hoistable(graph, &context, inst)) continue;
					bool invariant = true;
					@each_value_operand(&inst; ir::Ref* slot)
					{
						if ((usz)*slot >= (usz)decl.instructions.len)
						{
							invariant = false;
						}
						else if (home[(sz)*slot] != NONE_BLOCK && loop_body_contains(loop, home[(sz)*slot]))
						{
							invariant = false;
						}
					};
					if (!invariant) continue;
					if (home[(sz)ref] == preheader) continue;
					// A nested preheader's tail may still list this ref. That entry goes
					// stale (home no longer matches) and is skipped at emission, so the
					// surviving tail entries keep their def-before-use order.
					home[(sz)ref] = preheader;
					hoisted_tail[(sz)preheader].push(ref);
					changed = true;
				}
			}
		}
		if (!changed) return false;
		DeclEditor editor; editor.begin(decl);
		editor.body.clear();
		usz arg_end = 0;
		while (arg_end < decl.body.len && decl.instructions[(sz)decl.body[arg_end]].tag == ir::InstTag.ARG) arg_end++;
		editor.body.push_all(decl.body[:(sz)arg_end]);
		foreach (b, block : cfg.blocks)
		{
			sz term_pos = block_terminator_position(decl, &block);
			for (sz pos = block.start; pos < block.end; pos++)
			{
				if (pos == term_pos) licm_emit_tail(&editor, hoisted_tail[b], home, (uint)b);
				ir::Ref ref = decl.body[pos];
				if ((usz)ref < (usz)home.len && home[(sz)ref] != b) continue;
				editor.body.push(ref);
			}
			if (term_pos == block.end) licm_emit_tail(&editor, hoisted_tail[b], home, (uint)b);
		}
		editor.commit();
		return true;
	};
}
