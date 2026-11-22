// Small interprocedural constant propagation for the index-based IR.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, aro::primitive_value;
import std::collections::list, std::collections::map;

fn bool ipo_closed_world(ir::Ir* graph, OptOptions opts)
{
	if (!opts.whole_program || opts.keep_external_definitions) return false;
	foreach (decl : graph.decls)
	if (decl.kind == ir::DeclKind.FUNCTION && decl.name == "main") return true;
	return false;
}

<* Every caller and the final definition are visible. A weak definition may be
   replaced at link time, so it never qualifies, even in a closed world. *>
fn bool ipo_is_internal(ir::Decl* decl, bool closed_world)
=> decl.name != "main" && !decl.is_weak && !decl.is_external_root() &&
	(decl.linkage == ir::Linkage.INTERNAL || closed_world);

struct IpoCallSite
{
	uint caller; ir::Ref call;
}

struct IpoFunctionUses
{
	Allocator allocator;
	HashMap{String, usz} decl_indices;
	bool[] address_taken;
	list::List{IpoCallSite}[] call_sites;
}

fn void IpoFunctionUses.free(&self)
{
	foreach (&sites : self.call_sites) sites.free();
	if (self.call_sites.len) alloc::free(self.allocator, self.call_sites.ptr);
	if (self.address_taken.len) alloc::free(self.allocator, self.address_taken.ptr);
	self.decl_indices.free();
	*self = {};
}

fn uint ipo_function_index(IpoFunctionUses* uses, ir::Ir* graph, String name)
{
	if (try index = uses.decl_indices.get(name))
	{
		if (graph.decls.entries[(sz)index].kind == ir::DeclKind.FUNCTION) return (uint)index;
	}
	return uint::max;
}

fn IpoFunctionUses ipo_collect_function_uses(ir::Ir* graph, Allocator allocator)
{
	usz count = (usz)graph.decls.len();
	IpoFunctionUses uses = { .allocator = allocator };
	uses.decl_indices.init(allocator);
	uses.address_taken = alloc::new_array(allocator, bool, (sz)count);
	uses.call_sites = alloc::new_array(allocator, list::List{IpoCallSite}, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		uses.address_taken[i] = false;
		uses.call_sites[i].init(allocator);
	}
	foreach (i, decl : graph.decls) uses.decl_indices.set(decl.name, (usz)i);

	foreach (caller_index, caller : graph.decls)
	{
		if (caller.kind != ir::DeclKind.FUNCTION || caller.body.len == 0) continue;
		foreach (ref : caller.body)
		{
			if ((usz)ref >= (usz)caller.instructions.len) continue;
			ir::Inst* inst = &caller.instructions[(sz)ref];
			if (inst.tag == ir::InstTag.CALL)
			{
				if ((usz)inst.data.call.func < (usz)caller.instructions.len)
				{
					ir::Inst* func = &caller.instructions[(sz)inst.data.call.func];
					if (func.tag == ir::InstTag.SYMBOL)
					{
						uint callee = ipo_function_index(&uses, graph, func.data.label);
						if (callee != uint::max) uses.call_sites[(sz)callee].push(
						{
							(uint)caller_index, ref
						}
						);
					}
				}
				foreach (arg : inst.data.call.args)
				{
					if ((usz)arg >= (usz)caller.instructions.len) continue;
					ir::Inst* operand = &caller.instructions[(sz)arg];
					if (operand.tag != ir::InstTag.SYMBOL) continue;
					uint target = ipo_function_index(&uses, graph, operand.data.label);
					if (target != uint::max) uses.address_taken[(sz)target] = true;
				}
			}
			else
			{
				@each_value_operand(inst; ir::Ref* slot)
				{
					// This callback is expanded inline; `continue` here would skip the
					// rest of the instruction's operands in the caller-body loop.
					if ((usz)*slot < (usz)caller.instructions.len)
					{
						ir::Inst* operand = &caller.instructions[(sz)*slot];
						if (operand.tag == ir::InstTag.SYMBOL)
						{
							uint target = ipo_function_index(&uses, graph, operand.data.label);
							if (target != uint::max) uses.address_taken[(sz)target] = true;
						}
					}
				};
			}
		}
	}
	foreach (decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.GLOBAL) continue;
		foreach (reloc : decl.global.relocs)
		{
			uint target = ipo_function_index(&uses, graph, reloc.symbol);
			if (target != uint::max) uses.address_taken[(sz)target] = true;
		}
	}
	return uses;
}

fn bool ipo_has_va_start(ir::Decl* decl)
{
	foreach (ref : decl.body)
	if ((usz)ref < (usz)decl.instructions.len && decl.instructions[(sz)ref].tag == ir::InstTag.VA_START) return true;
	return false;
}

fn ir::Decl* ipo_find_function(ir::Ir* graph, String name)
{
	foreach (i, decl : graph.decls)
	if (decl.kind == ir::DeclKind.FUNCTION && decl.name == name && decl.body.len > 0)
	{
		return &graph.decls.entries[(sz)i];
	}
	return null;
}

struct IpoReturnConstant
{
	bool known;
	value_interner::InternerRef value;
	value_interner::InternerRef ty;
}

fn IpoReturnConstant ipo_return_constant(ir::Decl* decl)
{
	// Like LLVM's return tracking, this pass is conservative about multiple returns;
	// unlike LLVM's solver it counts every placed RET without executable-edge filtering.
	IpoReturnConstant result;
	bool saw_return = false;
	foreach (ref : decl.body)
	{
		if ((usz)ref >= (usz)decl.instructions.len) continue;
		ir::Inst* inst = &decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.RET_PAIR) return result;
		if (inst.tag != ir::InstTag.RET) continue;
		saw_return = true;
		if (inst.data.ref == ir::NONE || (usz)inst.data.ref >= (usz)decl.instructions.len) return result;
		ir::Inst* value = &decl.instructions[(sz)inst.data.ref];
		if (value.tag != ir::InstTag.CONSTANT) return result;
		if (!result.known)
		{
			result.known = true;
			result.value = value.data.constant;
			result.ty = value.ty;
		}
		else if (result.value != value.data.constant || result.ty != value.ty)
		{
			return { .known = false };
		}
	}
	if (!saw_return) result.known = false;
	return result;
}

<* One declaration-order sweep: specialize internal arguments only when every
   direct call site has matching arity and passes the same literal for that
   argument, then propagate identical constant returns to direct callers.
   Address escapes and any callsite that cannot prove a particular argument
   constant (including recursive or dead placed callsites) conservatively block
   that argument's specialization. A callee can only use caller facts already
   visible in this sweep; there is no fixpoint iteration. *>
fn bool ipsccp(ir::Ir* graph, OptOptions opts, Allocator allocator)
{
	IpoFunctionUses uses = ipo_collect_function_uses(graph, allocator);
	defer uses.free();
	bool changed = false;
	bool closed = ipo_closed_world(graph, opts);

	foreach (callee_index, callee_value : graph.decls)
	{
		ir::Decl* callee = &graph.decls.entries[(sz)callee_index];
		if (callee.kind != ir::DeclKind.FUNCTION || callee.body.len == 0 ||
			!ipo_is_internal(callee, closed) || uses.address_taken[callee_index] ||
		uses.call_sites[callee_index].len() == 0 || ipo_has_va_start(callee)) continue;
		usz arg_count = inline_arg_count(callee);
		bool arities_match = true;
		foreach (site : uses.call_sites[callee_index])
		{
			if ((usz)site.caller >= (usz)graph.decls.len())
			{
				arities_match = false; continue;
			}
			ir::Decl* caller = &graph.decls.entries[(sz)site.caller];
			if ((usz)site.call >= (usz)caller.instructions.len)
			{
				arities_match = false; continue;
			}
			ir::Inst* call = &caller.instructions[(sz)site.call];
			if (call.tag != ir::InstTag.CALL || call.data.call.args.len != arg_count) arities_match = false;
		}
		if (!arities_match) continue;
		DeclEditor editor;
		editor.begin(callee, allocator);
		bool callee_changed = false;
		for (usz i = 0; i < arg_count; i++)
		{
			if (i >= (usz)callee.body.len) continue;
			ir::Ref arg_ref = callee.body[(sz)i];
			if ((usz)arg_ref >= (usz)editor.insts.len()) continue;
			ir::Inst arg = editor.insts.entries[(sz)arg_ref];
			if (arg.tag != ir::InstTag.ARG || arg.data.arg.stack_address) continue;
			// This is stricter than LLVM's byval rule: all memory-copy args are excluded,
			// and stack-address ARGs were skipped above regardless of callee read effects.
			bool agreed = true;
			value_interner::InternerRef constant_value = (value_interner::InternerRef)0;
			bool first = true;
			foreach (site : uses.call_sites[callee_index])
			{
				if ((usz)site.caller >= (usz)graph.decls.len())
				{
					agreed = false; break;
				}
				ir::Decl* caller = &graph.decls.entries[(sz)site.caller];
				if ((usz)site.call >= (usz)caller.instructions.len)
				{
					agreed = false; break;
				}
				ir::Inst* call = &caller.instructions[(sz)site.call];
				if (call.tag != ir::InstTag.CALL)
				{
					agreed = false; break;
				}
				if (i >= (usz)call.data.call.memory_copy_bytes.len || call.data.call.memory_copy_bytes[(sz)i] != 0)
				{
					agreed = false; break;
				}
				// stack_only describes ABI placement; it does not change whether the argument is constant.
				if (i >= (usz)call.data.call.args.len)
				{
					agreed = false; break;
				}
				ir::Ref passed = call.data.call.args[(sz)i];
				if ((usz)passed >= (usz)caller.instructions.len)
				{
					agreed = false; break;
				}
				ir::Inst* value = &caller.instructions[(sz)passed];
				if (value.tag != ir::InstTag.CONSTANT || value.ty != arg.ty)
				{
					agreed = false; break;
				}
				if (first)
				{
					constant_value = value.data.constant; first = false;
				}
				else if (constant_value != value.data.constant)
				{
					agreed = false; break;
				}
			}
			if (!agreed || first) continue;
			ir::Ref constant_ref = editor.add_constant(constant_value, arg.ty);
			editor_replace_all_uses(&editor, arg_ref, constant_ref);
			callee_changed = true;
		}
		if (callee_changed)
		{
			editor.commit();
			callee.attrs = {};
			changed = true;
		}
		else
		{
			editor.free();
		}
	}

	foreach (callee_index, callee : graph.decls)
	{
		// A weak body may be overridden by a strong definition at link time.
		if (callee.kind != ir::DeclKind.FUNCTION || callee.body.len == 0 || callee.is_weak) continue;
		IpoReturnConstant result = ipo_return_constant(&callee);
		if (!result.known) continue;
		foreach (site : uses.call_sites[callee_index])
		{
			ir::Decl* caller = &graph.decls.entries[(sz)site.caller];
			if ((usz)site.call >= (usz)caller.instructions.len) continue;
			ir::Inst* call = &caller.instructions[(sz)site.call];
			if (call.tag != ir::InstTag.CALL || call.ty != result.ty) continue;
			Uses call_uses = compute_uses(caller, allocator);
			bool has_call_hi = false;
			foreach (user : call_uses.users[(sz)site.call])
			if (caller.instructions[(sz)user].tag == ir::InstTag.CALL_HI) has_call_hi = true;
			call_uses.free();
			if (has_call_hi) continue;
			DeclEditor editor;
			editor.begin(caller, allocator);
			ir::Ref constant_ref = editor.add_constant(result.value, result.ty);
			// LLVM's findReturnsToZap can replace tracked callee RETs with undef; C3
			// leaves the callee's RETs and the CALL itself in place for ABI preservation.
			editor_replace_all_uses(&editor, site.call, constant_ref);
			editor.commit();
			changed = true;
		}
	}
	return changed;
}
