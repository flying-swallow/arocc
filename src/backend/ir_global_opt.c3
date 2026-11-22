// Conservative interprocedural optimization of internal global data.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, aro::primitive_value;
import std::collections::map;

struct GlobalOptFacts
{
	bool escaped;
	bool read;
	bool written;
}

fn bool global_opt_remove_none(ir::Ref ref, void* context) => ref == ir::NONE;

fn bool global_opt_candidate(ir::Decl* decl, bool closed)
=> decl.kind == ir::DeclKind.GLOBAL && ipo_is_internal(decl, closed) && !decl.global.own_section &&
	(decl.global.section == ir::DataSection.DATA || decl.global.section == ir::DataSection.BSS || decl.global.section == ir::DataSection.RODATA);

fn uint global_opt_find_global(HashMap{String, uint}* indices, ir::Ir* graph, String name)
{
	if (try index = indices.get(name))
	{
		if (graph.decls.entries[(sz)index].kind == ir::DeclKind.GLOBAL) return (uint)index;
	}
	return uint::max;
}

fn bool global_opt_bytes_equal(char[] a, char[] b)
{
	if (a.len != b.len) return false;
	for (sz i = 0; i < a.len; i++) if (a[i] != b[i]) return false;
	return true;
}

fn bool global_opt_same_rodata(ir::GlobalData* a, ir::GlobalData* b)
=> a.size == b.size && a.own_section == b.own_section && a.relocs.len == 0 && b.relocs.len == 0 && global_opt_bytes_equal(a.bytes, b.bytes);

fn bool global_opt_pointer(ir::Inst[] insts, ir::Ref ref, ir::Ir* graph, HashMap{String, uint}* indices, uint* target, ulong* offset)
{
	if ((usz)ref >= (usz)insts.len) return false;
	ir::Inst inst = insts[(sz)ref];
	if (inst.tag == ir::InstTag.SYMBOL)
	{
		uint found = global_opt_find_global(indices, graph, inst.data.label);
		if (found == uint::max) return false;
		*target = found; *offset = 0; return true;
	}
	if (inst.tag != ir::InstTag.ADD || inst.ty != value_interner::REF_PTR) return false;
	ir::Ref delta = inst.data.bin.rhs;
	if ((usz)delta >= (usz)insts.len || insts[(sz)delta].tag != ir::InstTag.CONSTANT) return false;
	primitive_value::PrimitiveValue value = graph.interner.get(insts[(sz)delta].data.constant);
	if (value.tag != primitive_value::PrimitiveType.INT_POSITIVE || value.limbs.len > 1) return false;
	ulong addend = value.limbs.len == 0 ? 0 : (ulong)value.limbs[0];
	if (!global_opt_pointer(insts, inst.data.bin.lhs, graph, indices, target, offset)) return false;
	if (*offset > ulong::max - addend) return false;
	*offset += addend; return true;
}

fn ir::Ref global_opt_constant(ir::Ir* graph, DeclEditor* editor, ir::Inst load, ir::GlobalData* global, ulong base_offset)
{
	primitive_value::PrimitiveValue key = graph.interner.get(load.ty);
	if (key.tag != primitive_value::PrimitiveType.INT_TY) return ir::NONE;
	uint bytes = ((uint)key.ty_bits + 7) / 8;
	if (bytes == 0 || bytes > 16 || base_offset > global.size || (ulong)bytes > global.size - base_offset) return ir::NONE;
	uint128 offset = 0;
	// Relocation-bearing bytes cannot form an integer scalar constant.
	ulong load_end = base_offset + (ulong)bytes;
	foreach (reloc : global.relocs)
	{
		if (reloc.offset < load_end &&
			(reloc.offset > ulong::max - ulong::size || reloc.offset + ulong::size > base_offset)) return ir::NONE;
	}
	for (uint i = 0; i < bytes; i++)
	{
		ulong at = base_offset + (ulong)i;
		char byte_value = at < (ulong)global.bytes.len ? global.bytes[(sz)at] : 0;
		// Initializer bytes are stored in target order; byte i has weight i
		// (little-endian) or bytes - 1 - i (big-endian).
		uint shift = graph.big_endian ? (bytes - 1 - i) * 8 : i * 8;
		offset |= (uint128)((uint)byte_value & 0xFF) << shift;
	}
	if (key.ty_bits > 64) return ir::NONE;
	ulong bits = (ulong)offset;
	ulong mask = key.ty_bits == 64 ? ulong::max : (((ulong)1 << key.ty_bits) - 1);
	return editor.add_constant(graph.interner.put(primitive_value::int_key(const_prop_signed(bits & mask, key.ty_bits))), load.ty);
}

<* Replace loads from immutable initial values, erase stores to unread internal
   globals, merge equivalent internal RODATA, and tombstone unused symbols. *>
fn bool global_opt(ir::Ir* graph, OptOptions opts, Allocator allocator,
	HashMap{String, bool}* relocation_escapes, DynamicArenaAllocator* relocation_escape_arena)
{
	bool closed = ipo_closed_world(graph, opts);
	usz count = (usz)graph.decls.len();
	HashMap{String, uint} decl_indices;
	decl_indices.init(allocator);
	defer decl_indices.free();
	foreach (i, decl : graph.decls) decl_indices.set(decl.name, (uint)i);

	GlobalOptFacts[] facts = alloc::new_array(allocator, GlobalOptFacts, (sz)count);
	defer alloc::free(allocator, facts.ptr);
	for (usz i = 0; i < count; i++)
	{
		facts[i] = {};
		if (graph.decls.entries[(sz)i].kind == ir::DeclKind.GLOBAL &&
			relocation_escapes.get(graph.decls.entries[(sz)i].name) ?? false) facts[i].escaped = true;
	}

	// Record escapes and memory effects through constant pointer-add chains.
	foreach (decl : graph.decls)
	{
		if (decl.kind == ir::DeclKind.GLOBAL)
		{
			foreach (reloc : decl.global.relocs)
			{
				uint target = global_opt_find_global(&decl_indices, graph, reloc.symbol);
				relocation_escapes.set(reloc.symbol.copy(relocation_escape_arena), true);
				if (target != uint::max) facts[(sz)target].escaped = true;
			}
			continue;
		}
		// Track which candidate global each placed pointer value originates from.
		usz inst_count = (usz)decl.instructions.len;
		uint[] origins = alloc::new_array(allocator, uint, (sz)inst_count);
		defer alloc::free(allocator, origins.ptr);
		for (usz i = 0; i < inst_count; i++) origins[i] = uint::max;
		for (usz i = 0; i < inst_count; i++)
		{
			ir::Inst* inst = &decl.instructions[(sz)i];
			if (inst.tag != ir::InstTag.SYMBOL) continue;
			uint target = global_opt_find_global(&decl_indices, graph, inst.data.label);
			if (target != uint::max && global_opt_candidate(&graph.decls.entries[(sz)target], closed)) origins[i] = target;
		}
		bool derived = true;
		while (derived)
		{
			derived = false;
			foreach (ref : decl.body)
			{
				if ((usz)ref >= inst_count || origins[(sz)ref] != uint::max) continue;
				ir::Inst* inst = &decl.instructions[(sz)ref];
				if (inst.tag != ir::InstTag.ADD || inst.ty != value_interner::REF_PTR || (usz)inst.data.bin.lhs >= inst_count) continue;
				uint target = origins[(sz)inst.data.bin.lhs];
				if (target != uint::max) { origins[(sz)ref] = target; derived = true; }
			}
		}
		foreach (ref : decl.body)
		{
			if ((usz)ref >= inst_count) continue;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			@each_value_operand(inst; ir::Ref* slot)
			{
				if ((usz)*slot >= inst_count) continue;
				uint target = origins[(sz)*slot];
				if (target == uint::max) continue;
				bool allowed = false;
				switch (inst.tag)
				{
					case LOAD: allowed = slot == &inst.data.ref;
					case STORE: allowed = slot == &inst.data.bin.lhs && inst.data.bin.rhs != *slot;
					case ADD: allowed = slot == &inst.data.bin.lhs && inst.ty == value_interner::REF_PTR && inst.data.bin.rhs != *slot;
					default: break;
				}
				// A volatile access may observe or change the object outside
				// the program's view, like an escape.
				if (!allowed || inst.is_volatile_access()) { facts[(sz)target].escaped = true; }
				else if (inst.tag == ir::InstTag.LOAD) { facts[(sz)target].read = true; }
				else if (inst.tag == ir::InstTag.STORE) { facts[(sz)target].written = true; }
			};
		}
		foreach (ref : decl.body)
		{
			if ((usz)ref >= (usz)decl.instructions.len) continue;
			ir::Inst* inst = &decl.instructions[(sz)ref];
			ir::Ref direct = ir::NONE;
			bool is_load = inst.tag == ir::InstTag.LOAD;
			bool is_store = inst.tag == ir::InstTag.STORE;
			if (is_load) direct = inst.data.ref;
			if (is_store) direct = inst.data.bin.lhs;
			uint target = uint::max; ulong pointer_offset = 0;
			bool recognized = direct != ir::NONE && global_opt_pointer(decl.instructions, direct, graph, &decl_indices, &target, &pointer_offset);
			if (recognized && global_opt_candidate(&graph.decls.entries[(sz)target], closed))
			{
				if (inst.is_volatile_access()) facts[(sz)target].escaped = true;
				if (is_load) { facts[(sz)target].read = true; }
				else { facts[(sz)target].written = true; }
			}
		}
	}

	bool changed = false;
	// Analyze and edit each function with stable refs through DeclEditor.
	foreach (&decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) continue;
		DeclEditor editor;
		editor.begin(decl, allocator);
		bool function_changed = false;
		for (sz bi = 0; bi < editor.body.len(); bi++)
		{
			ir::Ref ref = editor.body.entries[bi];
			if ((usz)ref >= (usz)editor.insts.len()) continue;
			ir::Inst inst = editor.insts.entries[(sz)ref];
			ir::Ref global_symbol_ref = ir::NONE;
			bool is_load = inst.tag == ir::InstTag.LOAD;
			bool is_store = inst.tag == ir::InstTag.STORE;
			if (is_load) global_symbol_ref = inst.data.ref;
			if (is_store) global_symbol_ref = inst.data.bin.lhs;
			uint target = uint::max; ulong pointer_offset = 0;
			if (global_symbol_ref == ir::NONE || !global_opt_pointer(editor.insts.array_view(), global_symbol_ref, graph, &decl_indices, &target, &pointer_offset)) continue;
			ir::Decl* global_decl = &graph.decls.entries[(sz)target];
			if (global_decl.global.is_volatile || !global_opt_candidate(global_decl, closed) || facts[(sz)target].escaped) continue;
			if (is_load && !facts[(sz)target].written)
			{
				ir::Ref constant = global_opt_constant(graph, &editor, inst, &global_decl.global, pointer_offset);
				if (constant != ir::NONE)
				{
					editor_replace_all_uses(&editor, ref, constant);
					// Make the old load a harmless tombstone and unplace it.
					editor.insts.entries[(sz)ref].tag = ir::InstTag.ARG;
					for (sz k = 0; k < editor.body.len(); k++) if (editor.body.entries[k] == ref) editor.body.entries[k] = ir::NONE;
					function_changed = true;
				}
			}
			else if (is_store && !facts[(sz)target].read)
			{
				editor.insts.entries[(sz)ref].tag = ir::InstTag.ARG;
				for (sz k = 0; k < editor.body.len(); k++) if (editor.body.entries[k] == ref) editor.body.entries[k] = ir::NONE;
				function_changed = true;
			}
		}
		// Remove marker placements introduced above and tombstone dead symbol refs.
		if (function_changed)
		{
			editor.remove_body_where(&global_opt_remove_none, null);
			for (usz i = 0; i < (usz)editor.insts.len(); i++)
			{
				ir::Inst* inst = &editor.insts.entries[(sz)i];
				if (inst.tag != ir::InstTag.SYMBOL) continue;
				bool used = false;
				foreach (user_ref : editor.body)
				{
					if ((usz)user_ref >= (usz)editor.insts.len()) continue;
					@each_value_operand(&editor.insts.entries[(sz)user_ref]; ir::Ref* slot) { if (*slot == (ir::Ref)i) used = true; };
				}
				if (!used) inst.tag = ir::InstTag.ARG;
			}
			editor.commit();
			changed = true;
		}
		else
		{
			editor.free();
		}
	}

	// Merge identical internal RODATA declarations after index-based analyses
	// finish. Only relocation-free payloads are safe to merge here.
	count = (usz)graph.decls.len();
	for (usz i = 0; i < count; i++)
	{
		ir::Decl* a = &graph.decls.entries[(sz)i];
		if (a.kind != ir::DeclKind.GLOBAL || !ipo_is_internal(a, closed) || a.global.section != ir::DataSection.RODATA || a.global.is_volatile || a.global.relocs.len != 0) continue;
		for (usz j = count; j > i + 1;)
		{
			j--;
			ir::Decl* b = &graph.decls.entries[(sz)j];
			if (b.kind != ir::DeclKind.GLOBAL || !ipo_is_internal(b, closed) || b.global.section != ir::DataSection.RODATA || b.global.is_volatile || b.global.relocs.len != 0 || !global_opt_same_rodata(&a.global, &b.global)) continue;
			if (b.global.align > a.global.align) a.global.align = b.global.align;
			String old_name = b.name;
			String canonical_name = a.name;
			foreach (&decl : graph.decls)
			{
				if (decl.kind != ir::DeclKind.FUNCTION) continue;
				foreach (&inst : decl.instructions)
					if (inst.tag == ir::InstTag.SYMBOL && inst.data.label == old_name) inst.data.label = canonical_name.copy(&decl.arena);
			}
			foreach (&decl : graph.decls)
			{
				if (decl.kind != ir::DeclKind.GLOBAL) continue;
				foreach (&reloc : decl.global.relocs)
				{
					if (reloc.symbol == old_name) reloc.symbol = canonical_name.copy(&decl.arena);
				}
			}
			remove_decl(graph, j);
			count--;
			changed = true;
		}
	}

	// Symbols are value-producing instructions but do not emit code on their own.
	// Retire any symbol with no operand users, even when this pass made no other
	// change in its containing function.
	foreach (&decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) continue;
		Uses uses = compute_uses(decl, allocator);
		for (usz i = 0; i < (usz)decl.instructions.len; i++)
		{
			ir::Inst* inst = &decl.instructions[(sz)i];
			if (inst.tag == ir::InstTag.SYMBOL && uses.users[(sz)i].len() == 0)
			{
				inst.tag = ir::InstTag.ARG;
				changed = true;
			}
		}
		uses.free();
	}
	return changed;
}
