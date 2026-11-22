// Conservative interprocedural function property inference for the index IR.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;

const ulong ATTR_ALL_ARGS = ulong::max;

fn bool attrs_is_return(ir::InstTag tag)
{
	return tag == ir::InstTag.RET || tag == ir::InstTag.RET_PAIR;
}

fn usz attrs_arg_count(ir::Decl* decl)
{
	usz count = 0;
	foreach (ref : decl.body)
	{
		if ((usz)ref >= (usz)decl.instructions.len || decl.instructions[(sz)ref].tag != ir::InstTag.ARG) break;
		count++;
	}
	return count;
}

<* A stack allocation is private only if every transitive pointer use is an
   address use, or pointer ADD's left operand. This analysis sees volatility
   only on the allocation itself; it does not track per-access volatile
   qualifiers through casts. LLVM permits volatile accesses to have effects
   outside ordinary memory (LangRef: https://llvm.org/docs/LangRef.html#volatile-memory-accesses). *>
fn bool attrs_alloc_use_escapes(ir::Inst* inst, ir::Ref value)
{
	bool used = false;
	bool allowed = false;
	switch (inst.tag)
	{
		case LOAD: used = inst.data.ref == value; allowed = used;
		case STORE:
			used = inst.data.bin.lhs == value || inst.data.bin.rhs == value;
			allowed = inst.data.bin.lhs == value && inst.data.bin.rhs != value;
		case ADD:
			used = inst.data.bin.lhs == value || inst.data.bin.rhs == value;
			allowed = inst.ty == value_interner::REF_PTR && inst.data.bin.lhs == value;
		case RET: case LABEL_ADDR: case BIT_NOT: case NEGATE: case FNEG:
		case TRUNC: case ZEXT: case SEXT: case FPTOSI: case FPTOUI: case SITOFP:
		case UITOFP: case FPEXT: case FPTRUNC: case CLZ: case CTZ: case VA_START:
			used = inst.data.ref == value;
		case RET_PAIR: case CMP_EQ: case CMP_NE: case CMP_SLT: case CMP_SLTE: case CMP_SGT:
		case CMP_SGTE: case CMP_ULT: case CMP_ULTE: case CMP_UGT: case CMP_UGTE:
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT:
		case FCMP_OGE: case BIT_OR: case BIT_XOR: case BIT_AND: case BIT_SHL:
		case BIT_ASHR: case BIT_LSHR: case SUB: case MUL: case SDIV: case UDIV:
		case SREM: case UREM: case FADD: case FSUB: case FMUL: case FDIV:
			used = inst.data.bin.lhs == value || inst.data.bin.rhs == value;
		case SELECT:
			used = inst.data.branch.cond == value || inst.data.branch.then_label == value || inst.data.branch.else_label == value;
		case PHI:
			foreach (input : inst.data.phi) if (input.value == value) used = true;
		case CALL:
			if (inst.data.call.func == value) used = true;
			foreach (arg : inst.data.call.args) if (arg == value) used = true;
		case SWITCH: used = inst.data.switch_data.target == value;
		case BRANCH: used = inst.data.branch.cond == value;
		case JMP_VAL: used = inst.data.ref == value;
		default: break;
	}
	if (inst.tag == ir::InstTag.ATOMIC_LOAD || inst.tag == ir::InstTag.ATOMIC_STORE)
	{
		used = inst.data.atomic.ptr == value || inst.data.atomic.val == value;
	}
	return used && (!allowed || inst.is_volatile_access());
}

<* Sets `local[alloc]` for every non-volatile ALLOC that passes the rule above.
   A pointer derived through ADD has exactly one root ALLOC (its lhs chain), so
   every allocation is classified in one walk rather than one walk per ALLOC. *>
fn void attrs_mark_local_allocs(ir::Decl* decl, bool[] local, Allocator allocator)
{
	usz count = (usz)decl.instructions.len;
	if (!count) return;
	ir::Ref[] root = alloc::new_array(allocator, ir::Ref, (sz)count);
	defer alloc::free(allocator, root.ptr);
	for (usz i = 0; i < count; i++) root[i] = ir::NONE;
	foreach (ref : decl.body)
	{
		if ((usz)ref >= count) continue;
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.ALLOC && !inst.data.alloc.is_volatile)
		{
			root[(sz)ref] = ref;
			local[(sz)ref] = true;
		}
	}
	bool changed = true;
	while (changed)
	{
		changed = false;
		foreach (ref : decl.body)
		{
			if ((usz)ref >= count || root[(sz)ref] != ir::NONE) continue;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			if (inst.tag == ir::InstTag.ADD && inst.ty == value_interner::REF_PTR &&
				(usz)inst.data.bin.lhs < count && root[(sz)inst.data.bin.lhs] != ir::NONE)
			{
				root[(sz)ref] = root[(sz)inst.data.bin.lhs];
				changed = true;
			}
		}
	}
	foreach (ref : decl.body)
	{
		if ((usz)ref >= count) continue;
		ir::Inst* inst = &decl.instructions[(sz)ref];
		@each_value_operand(inst; ir::Ref* slot)
		{
			ir::Ref value = *slot;
			if ((usz)value < count && root[(sz)value] != ir::NONE && local[(sz)root[(sz)value]] &&
				attrs_alloc_use_escapes(inst, value))
			{
				local[(sz)root[(sz)value]] = false;
			}
		};
	}
}

<* Infer summaries in the call graph's bottom-up SCC order. *>
fn void infer_function_attrs(ir::Ir* graph, Allocator allocator)
{
	InlineCallGraph calls = build_inline_call_graph(graph, allocator);
	defer calls.free();
	foreach (&decl : graph.decls) decl.attrs = {};

	foreach (decl_index : calls.bottom_up)
	{
		ir::Decl* decl = &graph.decls.entries[(sz)decl_index];
		// A weak body may not be the one that runs; leave it uncomputed so calls
		// to it stay unknown.
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0 || decl.is_weak) continue;

		usz count = (usz)decl.instructions.len;
		ulong[] roots = alloc::new_array(allocator, ulong, (sz)count);
		bool[] local_roots = alloc::new_array(allocator, bool, (sz)count);
		defer alloc::free(allocator, roots.ptr);
		defer alloc::free(allocator, local_roots.ptr);
		for (usz i = 0; i < count; i++) { roots[(sz)i] = 0; local_roots[(sz)i] = false; }
		uint arg_index = 0;
		foreach (ref : decl.body)
		{
			if ((usz)ref >= count) continue;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			if (inst.tag == ir::InstTag.ARG)
			{
				if (arg_index < 64) roots[(sz)ref] = (ulong)1 << arg_index;
				arg_index++;
			}
		}
		attrs_mark_local_allocs(decl, local_roots, allocator);
		// Propagate argument provenance through value transformations that can
		// reconstruct or merge pointers, including integer pointer arithmetic.
		for (usz pass = 0; pass < count; pass++)
		{
			bool changed = false;
			foreach (ref : decl.body)
			{
				if ((usz)ref >= count) continue;
				ir::Inst* inst = &decl.instructions[(sz)ref];
				bool propagates = inst.tag == ir::InstTag.ADD || inst.tag == ir::InstTag.BIT_AND ||
					inst.tag == ir::InstTag.BIT_OR || inst.tag == ir::InstTag.BIT_XOR ||
					inst.tag == ir::InstTag.BIT_SHL || inst.tag == ir::InstTag.BIT_ASHR ||
					inst.tag == ir::InstTag.BIT_LSHR || inst.tag == ir::InstTag.PHI ||
					inst.tag == ir::InstTag.SELECT || inst.tag == ir::InstTag.TRUNC ||
					inst.tag == ir::InstTag.ZEXT || inst.tag == ir::InstTag.SEXT;
				if (!propagates) continue;
				ulong new_roots = roots[(sz)ref];
				bool new_local = local_roots[(sz)ref];
				@each_value_operand(inst; ir::Ref* slot)
				{
					if ((usz)*slot < count)
					{
						new_roots |= roots[(sz)*slot];
						new_local |= local_roots[(sz)*slot];
					}
				};
				if (new_roots != roots[(sz)ref] || new_local != local_roots[(sz)ref]) changed = true;
				roots[(sz)ref] = new_roots; local_roots[(sz)ref] = new_local;
			}
			if (!changed) break;
		}

		ir::FnAttrs attrs = { .computed = true, .arg_nocapture = ATTR_ALL_ARGS,
			.arg_noread = ATTR_ALL_ARGS, .arg_nowrite = ATTR_ALL_ARGS };
		bool has_cycle = false;
		Cfg cfg = build_cfg(decl, allocator);
		defer cfg.free();
		cfg.compute_dominators();
		// Like LLVM's functionWillReturn, this summary promises termination on defined
		// paths. C3 approximates that with a conservative check: any reachable CFG
		// backedge may not terminate; it does not analyze LLVM's UB-only paths.
		foreach (from, block : cfg.blocks)
		{
			if (!cfg.reachable[from]) continue;
			foreach (to : block.succs)
				if (cfg.rpo_position[from] >= cfg.rpo_position[to]) has_cycle = true;
		}
		bool saw_ret = false;
		bool computed_jump = false;
		bool saw_read = false;
		bool saw_write = false;
		bool call_may_not_return = false;
		// Find argument effects, captures, and ordinary memory effects.
		foreach (ref : decl.body)
		{
			if ((usz)ref >= count) continue;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			ulong ptr_args = 0;
			bool ptr_local = false;
			ir::Ref ptr = ir::NONE;
			switch (inst.tag)
			{
				case LOAD: ptr = inst.data.ref;
				case STORE: ptr = inst.data.bin.lhs;
				case ATOMIC_LOAD: ptr = inst.data.atomic.ptr;
				case ATOMIC_STORE: ptr = inst.data.atomic.ptr;
				default: break;
			}
			if (ptr != ir::NONE && (usz)ptr < count) { ptr_args = roots[(sz)ptr]; ptr_local = local_roots[(sz)ptr]; }
			// A volatile access is an observable side effect on memory, wherever it
			// points (LLVM treats volatile as read+write of inaccessible memory).
			if (inst.is_volatile_access())
			{
				saw_read = true;
				saw_write = true;
				attrs.arg_noread &= ~ptr_args;
				attrs.arg_nowrite &= ~ptr_args;
			}
			if (inst.tag == ir::InstTag.LOAD || inst.tag == ir::InstTag.ATOMIC_LOAD)
			{
				if (!ptr_local || ptr_args != 0) saw_read = true;
				if (inst.tag == ir::InstTag.ATOMIC_LOAD) saw_write = true;
				attrs.arg_noread &= ~ptr_args;
			}
			if (inst.tag == ir::InstTag.STORE || inst.tag == ir::InstTag.ATOMIC_STORE)
			{
				if (!ptr_local || ptr_args != 0) saw_write = true;
				if (inst.tag == ir::InstTag.ATOMIC_STORE) saw_read = true;
				attrs.arg_nowrite &= ~ptr_args;
			}
			if (inst.tag == ir::InstTag.FENCE || inst.tag == ir::InstTag.VA_START) { saw_read = true; saw_write = true; }
			if (inst.tag == ir::InstTag.VA_START && (usz)inst.data.ref < count)
			{
				attrs.arg_noread &= ~roots[(sz)inst.data.ref];
				attrs.arg_nowrite &= ~roots[(sz)inst.data.ref];
			}
			if (inst.tag == ir::InstTag.DYN_ALLOC || inst.tag == ir::InstTag.STACK_SAVE ||
				inst.tag == ir::InstTag.STACK_RESTORE)
			{
				saw_read = true;
				saw_write = true;
			}
			if (attrs_is_return(inst.tag))
			{
				saw_ret = true;
			}
			if (inst.tag == ir::InstTag.JMP_VAL || inst.tag == ir::InstTag.LABEL_ADDR) computed_jump = true;
			// Every value use is conservatively treated as a capture, except uses
			// that are known to be address-only or summarized separately. This also
			// rejects integer arithmetic on pointers.
			@each_value_operand(inst; ir::Ref* slot)
			{
				// CALL func is never treated as captured here; its arguments are
				// summarized against the callee below.
				if (inst.tag != ir::InstTag.CALL)
				{
					ir::Ref value = *slot;
					if ((usz)value < count)
					{
						bool address_only =
							(inst.tag == ir::InstTag.LOAD && slot == &inst.data.ref) ||
							(inst.tag == ir::InstTag.STORE && slot == &inst.data.bin.lhs) ||
							((inst.tag == ir::InstTag.ATOMIC_LOAD || inst.tag == ir::InstTag.ATOMIC_STORE) &&
							 slot == &inst.data.atomic.ptr) ||
							(inst.tag == ir::InstTag.ADD && inst.ty == value_interner::REF_PTR &&
							 slot == &inst.data.bin.lhs);
						if (!address_only) attrs.arg_nocapture &= ~roots[(sz)value];
					}
				}
			};
			if (inst.tag != ir::InstTag.CALL) continue;
			uint callee_index = uint::max;
			if ((usz)inst.data.call.func < count)
			{
				ir::Inst* function_value = &decl.instructions[(sz)inst.data.call.func];
				if (function_value.tag == ir::InstTag.SYMBOL) callee_index = inline_decl_index(&calls.decl_indices, function_value.data.label);
			}
			// LLVM's checkFunctionMemoryAccess handles call effects during attribute
			// inference. C3 does not solve recursive SCC summaries to a fixed point, so
			// same-SCC calls are treated as unknown and keep effects conservative.
			bool known = callee_index != uint::max && graph.decls.entries[(sz)callee_index].kind == ir::DeclKind.FUNCTION &&
				graph.decls.entries[(sz)callee_index].attrs.computed && calls.scc[(sz)callee_index] != calls.scc[(sz)decl_index];
			if (known && attrs_arg_count(&graph.decls.entries[(sz)callee_index]) != (usz)inst.data.call.args.len) known = false;
			ir::FnAttrs callee_attrs = {};
			if (known) { callee_attrs = graph.decls.entries[(sz)callee_index].attrs; }
			else { saw_read = true; saw_write = true; call_may_not_return = true; }
			if (known)
			{
				if (!callee_attrs.readnone) saw_read = true;
				if (!callee_attrs.readonly) saw_write = true;
				if (!callee_attrs.will_return) call_may_not_return = true;
			}
			foreach (i, arg : inst.data.call.args)
			{
				if ((usz)arg >= count) continue;
				ulong arg_roots = roots[(sz)arg];
				uint copy_bytes = i < inst.data.call.memory_copy_bytes.len ? inst.data.call.memory_copy_bytes[(sz)i] : 0;
				if (copy_bytes != 0)
				{
					saw_read = true;
					attrs.arg_noread &= ~arg_roots;
				}
				if (!known)
				{
					attrs.arg_noread &= ~arg_roots;
					attrs.arg_nowrite &= ~arg_roots;
					attrs.arg_nocapture &= ~arg_roots;
					continue;
				}
				if (i >= 64 || (callee_attrs.arg_noread & ((ulong)1 << i)) == 0 || copy_bytes != 0) attrs.arg_noread &= ~arg_roots;
				if (i >= 64 || (callee_attrs.arg_nowrite & ((ulong)1 << i)) == 0) attrs.arg_nowrite &= ~arg_roots;
				if (i >= 64 || (callee_attrs.arg_nocapture & ((ulong)1 << i)) == 0) attrs.arg_nocapture &= ~arg_roots;
			}
		}
		attrs.readnone = !saw_read && !saw_write;
		attrs.readonly = !saw_write;
		// Per-argument memory guarantees are meaningful only when the pointer
		// cannot escape to code outside this summary.
		attrs.arg_noread &= attrs.arg_nocapture;
		attrs.arg_nowrite &= attrs.arg_nocapture;
		attrs.will_return = saw_ret && !has_cycle && !computed_jump && !call_may_not_return;
		// Recursive SCCs are conservatively unable to promise termination.
		foreach (callee_index : calls.edges[(sz)decl_index])
			if (calls.scc[(sz)callee_index] == calls.scc[(sz)decl_index]) attrs.will_return = false;
		decl.attrs = attrs;
	}
}
