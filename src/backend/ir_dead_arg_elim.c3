// Conservative interprocedural elimination of unused register parameters and
// ignored scalar return values in the index-based IR.
module aro::backend::ir_opt;
import aro::backend::ir, aro::code_gen_options, aro::value_interner;

struct DeadArgRemoval { bool[] refs; }

fn bool dead_arg_remove_placed(ir::Ref ref, void* context)
{
	DeadArgRemoval* removal = (DeadArgRemoval*)context;
	return (usz)ref < (usz)removal.refs.len && removal.refs[(sz)ref];
}

fn bool dead_return_has_user(ir::Decl* decl, ir::Ref value)
{
	foreach (ref : decl.body)
	{
		if ((usz)ref >= (usz)decl.instructions.len) continue;
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CALL_HI && inst.data.ref == value) return true;
		bool used = false;
		@each_value_operand(inst; ir::Ref* slot) { if (*slot == value) used = true; };
		if (used) return true;
	}
	return false;
}

<* Remove unused leading register ARG placements and their corresponding call
   operands. Calls with incomplete ABI metadata are left untouched. *>
fn bool eliminate_dead_arguments(ir::Ir* graph, bool closed, Allocator allocator)
{
	IpoFunctionUses uses = ipo_collect_function_uses(graph, allocator);
	defer uses.free();
	bool changed = false;
	foreach (callee_index, callee_value : graph.decls)
	{
		ir::Decl* callee = &graph.decls.entries[(sz)callee_index];
		// Unlike LLVM DeadArgumentElimination::surveyFunction, C3 allows fixed
		// variadic parameters to be pruned when calls have exact ABI argument metadata;
		// a call with extra varargs fails the exact-arity check below.
		if (callee.kind != ir::DeclKind.FUNCTION || callee.body.len == 0 || !ipo_is_internal(callee, closed) ||
			uses.address_taken[callee_index] || uses.call_sites[callee_index].len() == 0 || ipo_has_va_start(callee)) continue;
		usz argc = inline_arg_count(callee);
		if (argc == 0) continue;
		Uses arg_uses = compute_uses(callee, allocator);
		defer arg_uses.free();
		bool[] remove = alloc::new_array(allocator, bool, (sz)argc);
		defer alloc::free(allocator, remove.ptr);
		// Unlike LLVM DeadArgumentElimination::surveyUse and propagateLiveness,
		// C3 does not propagate deadness through argument forwarding edges. This
		// means cleanup can depend on declaration order.
		bool eligible = true;
		for (usz i = 0; i < argc; i++)
		{
			ir::Ref arg_ref = callee.body[(sz)i];
			ir::Inst arg = callee.instructions[(sz)arg_ref];
			remove[i] = arg_uses.users[(sz)arg_ref].len() == 0;
			if (arg.data.arg.stack_address || arg.data.arg.stack_size != 0 ||
				(arg.data.arg.location_kind != ir::ArgLocationKind.GP_REGISTER && arg.data.arg.location_kind != ir::ArgLocationKind.SSE_REGISTER))
			{
				eligible = false;
			}
		}
		bool has_removal = false;
		for (usz i = 0; i < argc; i++) if (remove[i]) has_removal = true;
		if (!eligible || !has_removal) continue;
		foreach (site : uses.call_sites[callee_index])
		{
			ir::Decl* caller = &graph.decls.entries[(sz)site.caller];
			ir::Inst* call = &caller.instructions[(sz)site.call];
			if (call.tag != ir::InstTag.CALL || (usz)call.data.call.args.len != argc ||
				(usz)call.data.call.stack_only.len != argc || (usz)call.data.call.memory_copy_bytes.len != argc)
				{ eligible = false; break; }
			for (usz i = 0; i < argc; i++)
			{
				if (call.data.call.stack_only[(sz)i] || call.data.call.memory_copy_bytes[(sz)i] != 0) eligible = false;
				if (callee.instructions[(sz)callee.body[(sz)i]].ty == value_interner::REF_F80) eligible = false;
			}
		}
		if (!eligible) continue;
		bool[] remove_refs = alloc::new_array(allocator, bool, callee.instructions.len);
		defer alloc::free(allocator, remove_refs.ptr);
		remove_refs[..] = false;
		for (usz i = 0; i < argc; i++)
		{
			if (remove[i]) remove_refs[(sz)callee.body[(sz)i]] = true;
		}
		DeadArgRemoval removal = { .refs = remove_refs };
		DeclEditor editor;
		editor.begin(callee, allocator);
		editor.remove_body_where(&dead_arg_remove_placed, (void*)&removal);
		for (usz i = 0; i < argc; i++)
		{
			if (remove[i]) editor.insts.entries[(sz)callee.body[(sz)i]].tag = ir::InstTag.ARG;
		}
		editor.commit();
		uint gp_index = 0;
		uint sse_index = 0;
		foreach (arg_ref : callee.body)
		{
			if ((usz)arg_ref >= (usz)callee.instructions.len) continue;
			ir::Inst* arg = &callee.instructions[(sz)arg_ref];
			if (arg.tag != ir::InstTag.ARG) break;
			if (arg.data.arg.location_kind == ir::ArgLocationKind.GP_REGISTER)
			{
				arg.data.arg.location = gp_index++;
			}
			else if (arg.data.arg.location_kind == ir::ArgLocationKind.SSE_REGISTER)
			{
				arg.data.arg.location = sse_index++;
			}
		}
		callee.attrs = {};
		foreach (site : uses.call_sites[callee_index])
		{
			ir::Decl* caller = &graph.decls.entries[(sz)site.caller];
			ir::Inst* call = &caller.instructions[(sz)site.call];
			usz kept = 0;
			for (usz i = 0; i < argc; i++) if (!remove[i]) kept++;
			ir::Ref[] args = alloc::new_array(&caller.arena, ir::Ref, (sz)kept);
			bool[] stack_only = alloc::new_array(&caller.arena, bool, (sz)kept);
			uint[] copy_bytes = alloc::new_array(&caller.arena, uint, (sz)kept);
			sz write = 0;
			for (usz i = 0; i < argc; i++) if (!remove[i])
			{
				args[write] = call.data.call.args[(sz)i];
				stack_only[write] = call.data.call.stack_only[(sz)i];
				copy_bytes[write] = call.data.call.memory_copy_bytes[(sz)i];
				write++;
			}
			call.data.call.args = args;
			call.data.call.stack_only = stack_only;
			call.data.call.memory_copy_bytes = copy_bytes;
			caller.attrs = {};
		}
		changed = true;
	}
	return changed;
}

<* Change an ignored scalar result to void when every direct call result is dead. *>
fn bool eliminate_dead_return_values(ir::Ir* graph, bool closed, Allocator allocator)
{
	IpoFunctionUses uses = ipo_collect_function_uses(graph, allocator);
	defer uses.free();
	bool changed = false;
	foreach (callee_index, callee_value : graph.decls)
	{
		ir::Decl* callee = &graph.decls.entries[(sz)callee_index];
		if (callee.kind != ir::DeclKind.FUNCTION || callee.body.len == 0 || !ipo_is_internal(callee, closed) ||
			uses.address_taken[callee_index] || uses.call_sites[callee_index].len() == 0 || ipo_has_va_start(callee)) continue;
		bool saw_ret = false;
		bool valued_ret = false;
		bool allowed = true;
		// LLVM DeadArgumentElimination::surveyFunction tracks aggregate return
		// elements separately; C3 only drops scalar RET results when every direct
		// call result is unused, and keeps RET_PAIR intact.
		foreach (ref : callee.body)
		{
			if ((usz)ref >= (usz)callee.instructions.len) continue;
			ir::Inst* inst = &callee.instructions[(sz)ref];
			if (inst.tag == ir::InstTag.RET_PAIR) allowed = false;
			if (inst.tag == ir::InstTag.RET)
			{
				saw_ret = true;
				if (inst.data.ref != ir::NONE) valued_ret = true;
			}
		}
		if (!allowed || !saw_ret || !valued_ret) continue;
		foreach (site : uses.call_sites[callee_index])
		{
			ir::Decl* caller = &graph.decls.entries[(sz)site.caller];
			ir::Inst* call = &caller.instructions[(sz)site.call];
			if (call.tag != ir::InstTag.CALL || dead_return_has_user(caller, site.call)) { allowed = false; break; }
		}
		if (!allowed) continue;
		foreach (ref : callee.body)
		{
			if ((usz)ref < (usz)callee.instructions.len && callee.instructions[(sz)ref].tag == ir::InstTag.RET)
			{
				callee.instructions[(sz)ref].data.ref = ir::NONE;
			}
		}
		callee.attrs = {};
		foreach (site : uses.call_sites[callee_index])
		{
			ir::Decl* caller = &graph.decls.entries[(sz)site.caller];
			caller.instructions[(sz)site.call].ty = value_interner::REF_VOID;
			caller.attrs = {};
		}
		changed = true;
	}
	return changed;
}

fn bool dead_arg_elim(ir::Ir* graph, OptOptions opts, Allocator allocator)
{
	if (opts.level != code_gen_options::OptimizationLevel.O2 && opts.level != code_gen_options::OptimizationLevel.O3 &&
		opts.level != code_gen_options::OptimizationLevel.FAST) return false;
	bool closed = ipo_closed_world(graph, opts);
	bool changed = eliminate_dead_arguments(graph, closed, allocator);
	changed = eliminate_dead_return_values(graph, closed, allocator) || changed;
	return changed;
}
