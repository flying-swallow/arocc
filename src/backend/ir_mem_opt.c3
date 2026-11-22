// Conservative scalar replacement of non-escaping fixed-size stack allocations.
module aro::backend::ir_opt;
import aro::primitive_value;
import aro::backend::ir, aro::value_interner;
import std::collections::list;
import std::sort;

struct MemAddr { ir::Ref root; long offset; bool known_offset; }
<* Byte size for scalar integer, float, and pointer types. *>
fn bool mem_access_size(ir::Ir* graph, value_interner::InternerRef ty, uint* size)
{
	primitive_value::PrimitiveValue key = graph.interner.get(ty);
	switch (key.tag)
	{
		case primitive_value::PrimitiveType.INT_TY:
		case primitive_value::PrimitiveType.FLOAT_TY:
			if (key.ty_bits == 0) return false;
			*size = ((uint)key.ty_bits + 7) / 8;
			return true;
		case primitive_value::PrimitiveType.PTR_TY: *size = 8; return true;
		default: return false;
	}
}

<* Evaluate constant integer expressions used to form fixed pointer offsets. *>
fn bool sroa_constant_value(ir::Ir* graph, ir::Inst[] insts, ir::Ref ref, uint depth, long* value)
{
	if (depth == 32 || (usz)ref >= (usz)insts.len) return false;
	ir::Inst* inst = &insts[(sz)ref];
	ushort width;
	if (!const_prop_int_width(graph, inst.ty, &width)) return false;
	if (inst.tag == ir::InstTag.CONSTANT)
	{
		ulong bits;
		if (!scalar_constant_bits(graph, insts, ref, &bits)) return false;
		*value = const_prop_signed(bits, width);
		return true;
	}
	if (inst.tag == ir::InstTag.ZEXT || inst.tag == ir::InstTag.SEXT || inst.tag == ir::InstTag.TRUNC ||
		inst.tag == ir::InstTag.NEGATE)
	{
		long operand;
		if (!sroa_constant_value(graph, insts, inst.data.ref, depth + 1, &operand)) return false;
		ulong bits = (ulong)operand;
		if (inst.tag == ir::InstTag.ZEXT)
		{
			ushort source_width;
			if ((usz)inst.data.ref >= (usz)insts.len ||
				!const_prop_int_width(graph, insts[(sz)inst.data.ref].ty, &source_width)) return false;
			bits &= const_prop_mask(source_width);
		}
		if (inst.tag == ir::InstTag.NEGATE) bits = 0 - bits;
		*value = const_prop_signed(bits & const_prop_mask(width), width);
		return true;
	}
	if (inst.tag == ir::InstTag.ADD || inst.tag == ir::InstTag.SUB || inst.tag == ir::InstTag.MUL)
	{
		long lhs, rhs;
		if (!sroa_constant_value(graph, insts, inst.data.bin.lhs, depth + 1, &lhs) ||
			!sroa_constant_value(graph, insts, inst.data.bin.rhs, depth + 1, &rhs)) return false;
		ulong bits;
		if (inst.tag == ir::InstTag.ADD) { bits = (ulong)lhs + (ulong)rhs; }
		else if (inst.tag == ir::InstTag.SUB) { bits = (ulong)lhs - (ulong)rhs; }
		else { bits = (ulong)lhs * (ulong)rhs; }
		*value = const_prop_signed(bits & const_prop_mask(width), width);
		return true;
	}
	return false;
}

<* Resolve up to 64 pointer ADD nodes. A dynamic addend loses offset knowledge but not the root. *>
fn bool mem_decompose_address(ir::Ir* graph, ir::Inst[] insts, ir::Ref address, MemAddr* out)
{
	ir::Ref cursor = address;
	long total = 0;
	bool known = true;
	for (uint depth = 0; depth < 64; depth++)
	{
		if ((usz)cursor >= (usz)insts.len) break;
		ir::Inst* inst = &insts[(sz)cursor];
		if (inst.tag != ir::InstTag.ADD || inst.ty != value_interner::REF_PTR) break;
		long addend;
		if (!sroa_constant_value(graph, insts, inst.data.bin.rhs, 0, &addend))
		{
			known = false;
			total = 0;
		}
		else if (known)
		{
			if ((addend > 0 && total > long::max - addend) || (addend < 0 && total < long::min - addend))
			{
				known = false;
				total = 0;
			}
			else { total += addend; }
		}
		cursor = inst.data.bin.lhs;
	}
	if ((usz)cursor >= (usz)insts.len || insts[(sz)cursor].tag != ir::InstTag.ALLOC)
	{
		*out = { .root = ir::NONE };
		return false;
	}
	*out = { .root = cursor, .offset = total, .known_offset = known };
	return true;
}

fn bool mem_may_alias(MemAddr a, uint a_size, MemAddr b, uint b_size, bool[] non_escaping)
{
	bool a_safe = a.root != ir::NONE && (usz)a.root < (usz)non_escaping.len && non_escaping[(sz)a.root];
	bool b_safe = b.root != ir::NONE && (usz)b.root < (usz)non_escaping.len && non_escaping[(sz)b.root];
	if (a.root != b.root)
	{
		if (a.root != ir::NONE && b.root != ir::NONE && (a_safe || b_safe)) return false;
		if (a_safe != b_safe) return false;
		return true;
	}
	if (a.root == ir::NONE || !a.known_offset || !b.known_offset || a.offset < 0 || b.offset < 0) return true;
	ulong a_start = (ulong)a.offset;
	ulong b_start = (ulong)b.offset;
	if (a_start > ulong::max - a_size || b_start > ulong::max - b_size) return true;
	return a_start < b_start + b_size && b_start < a_start + a_size;
}

struct SroaSlot
{
	ulong offset;
	uint size;
	value_interner::InternerRef ty;
	uint align;
}

struct SroaAccess
{
	ir::Ref ref;
	uint slot;
}

fn bool sroa_constant_offset(ir::Ir* graph, ir::Decl* decl, ir::Ref ref, ulong* offset)
{
	long value;
	if (!sroa_constant_value(graph, decl.instructions, ref, 0, &value) || value < 0) return false;
	*offset = (ulong)value;
	return true;
}

<* Resolve an address made from an allocation plus nonnegative constant byte offsets. *>
fn bool sroa_pointer_offset(ir::Ir* graph, ir::Decl* decl, ir::Ref alloc_ref,
	ir::Ref ref, bool[] visiting, ulong* offset)
{
	MemAddr address;
	if (!mem_decompose_address(graph, decl.instructions, ref, &address) ||
		!address.known_offset || address.root != alloc_ref || address.offset < 0) return false;
	*offset = (ulong)address.offset;
	return true;
}

fn uint sroa_gcd(uint lhs, uint rhs)
{
	while (rhs != 0)
	{
		uint remainder = lhs % rhs;
		lhs = rhs;
		rhs = remainder;
	}
	return lhs;
}

macro @sroa_each_value_operand(ir::Inst* inst; @body(ir::Ref* slot))
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
		case CTZ: @body(&inst.data.ref);
		case ATOMIC_LOAD: @body(&inst.data.atomic.ptr);
		case ATOMIC_STORE:
			@body(&inst.data.atomic.ptr);
			@body(&inst.data.atomic.val);
		case DYN_ALLOC: @body(&inst.data.dyn_alloc.size);
		case RET: if (inst.data.ref != ir::NONE) @body(&inst.data.ref);
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
		case BRANCH: @body(&inst.data.branch.cond);
		case SELECT:
			@body(&inst.data.branch.cond);
			@body(&inst.data.branch.then_label);
			@body(&inst.data.branch.else_label);
		case SWITCH: @body(&inst.data.switch_data.target);
		case CALL:
			@body(&inst.data.call.func);
			foreach (i, arg : inst.data.call.args) @body(&inst.data.call.args[i]);
		case CALL_HI: @body(&inst.data.ref);
		case PHI:
			foreach (i, input : inst.data.phi) @body(&inst.data.phi[i].value);
		case CONSTANT:
		case ARG:
		case SYMBOL:
		case LABEL:
		case LABEL_ADDR:
		case JMP:
		case JMP_VAL:
		case ALLOC:
		case STACK_SAVE:
		case FENCE: break;
	}
}

fn bool[] mem_compute_non_escaping(ir::Ir* graph, ir::Decl* decl, Uses* uses, Allocator allocator)
{
	usz count = (usz)decl.instructions.len;
	bool[] result = alloc::new_array(allocator, bool, (sz)count);
	for (usz i = 0; i < count; i++) result[i] = false;
	// seen[ref] == stamp marks refs visited for the current root; no per-root reset.
	uint[] seen = alloc::new_array(allocator, uint, (sz)count);
	defer alloc::free(allocator, seen.ptr);
	for (usz i = 0; i < count; i++) seen[i] = 0;
	uint stamp = 0;
	list::List{ir::Ref} work;
	work.init(allocator);
	defer work.free();
	foreach (alloc_ref : decl.body)
	{
		if ((usz)alloc_ref >= count || decl.instructions[(sz)alloc_ref].tag != ir::InstTag.ALLOC ||
			decl.instructions[(sz)alloc_ref].data.alloc.is_volatile || result[(sz)alloc_ref]) continue;
		stamp++;
		work.clear();
		seen[(sz)alloc_ref] = stamp;
		work.push(alloc_ref);
		bool safe = true;
		while (work.len() && safe)
		{
			ir::Ref current = work.pop()!!;
			if ((usz)current >= (usz)uses.users.len) { safe = false; break; }
			foreach (user_ref : uses.users[(sz)current])
			{
				if ((usz)user_ref >= count) { safe = false; break; }
				ir::Inst* user = &decl.instructions[(sz)user_ref];
				bool allowed = false;
				bool derived = false;
				switch (user.tag)
				{
					// A volatile access keeps the whole root opaque to SROA,
					// forwarding and DSE.
					case ir::InstTag.LOAD:
						allowed = user.data.ref == current && !user.is_volatile;
						break;
					case ir::InstTag.STORE:
						allowed = user.data.bin.lhs == current && user.data.bin.rhs != current && !user.is_volatile;
						break;
					case ir::InstTag.ADD:
						allowed = user.ty == value_interner::REF_PTR && user.data.bin.lhs == current && user.data.bin.rhs != current;
						derived = allowed;
						break;
					default: break;
				}
				if (!allowed) { safe = false; break; }
				if (derived && seen[(sz)user_ref] != stamp)
				{
					seen[(sz)user_ref] = stamp;
					work.push(user_ref);
				}
			}
		}
		if (safe) result[(sz)alloc_ref] = true;
	}
	return result;
}


<* Analyses shared by every sroa_one call of one sroa run. Splitting one ALLOC
   only rewrites accesses rooted at that ALLOC and appends new instructions, so
   uses, escape facts and body order of the remaining candidates stay valid. *>
struct SroaShared
{
	Uses uses;
	bool[] non_escaping;
	uint[] body_position;
	uint[] derived_mark;
	uint[] user_mark;
	uint stamp;
	list::List{ir::Ref} derived;
	list::List{ulong} users;
}

fn bool sroa_one(ir::Ir* graph, ir::Decl* decl, ir::Ref alloc_ref, SroaShared* shared, Allocator allocator)
{
	if ((usz)alloc_ref >= (usz)shared.non_escaping.len || decl.instructions[(sz)alloc_ref].tag != ir::InstTag.ALLOC) return false;
	ir::AllocData original = decl.instructions[(sz)alloc_ref].data.alloc;
	if (original.is_volatile || original.size == 0 || decl.body.len == 0) return false;
	bool[] non_escaping = shared.non_escaping;
	if (!non_escaping[(sz)alloc_ref]) return false;
	usz instruction_count = (usz)decl.instructions.len;
	usz analysed_count = (usz)shared.non_escaping.len;
	bool[] visiting = {};

	// A non-escaping root's derived pointers are exactly its pointer-ADD lhs
	// chain; every instruction that sroa_pointer_offset can match uses one.
	uint stamp = ++shared.stamp;
	shared.derived.clear();
	shared.users.clear();
	shared.derived.push(alloc_ref);
	shared.derived_mark[(sz)alloc_ref] = stamp;
	for (sz i = 0; i < shared.derived.len(); i++)
	{
		ir::Ref current = shared.derived[i];
		foreach (user_ref : shared.uses.users[(sz)current])
		{
			if ((usz)user_ref >= analysed_count) continue;
			ir::Inst* user = &decl.instructions[(sz)user_ref];
			if (user.tag == ir::InstTag.ADD && user.ty == value_interner::REF_PTR && user.data.bin.lhs == current &&
				shared.derived_mark[(sz)user_ref] != stamp)
			{
				shared.derived_mark[(sz)user_ref] = stamp;
				shared.derived.push(user_ref);
			}
			if (shared.user_mark[(sz)user_ref] != stamp && shared.body_position[(sz)user_ref] != uint::max)
			{
				shared.user_mark[(sz)user_ref] = stamp;
				shared.users.push(((ulong)shared.body_position[(sz)user_ref] << 32) | (ulong)(uint)user_ref);
			}
		}
	}
	// Visit users in body order so slots and accesses match a full body walk.
	quicksort(shared.users.array_view());

	sz user_count = shared.users.len();
	SroaSlot[] slots = alloc::new_array(allocator, SroaSlot, user_count + 1);
	defer alloc::free(allocator, slots.ptr);
	SroaAccess[] accesses = alloc::new_array(allocator, SroaAccess, user_count + 1);
	defer alloc::free(allocator, accesses.ptr);
	uint slot_count = 0;
	uint access_count = 0;

	foreach (key : shared.users)
	{
		ir::Ref user_ref = (ir::Ref)(uint)(key & 0xFFFF_FFFF);
		ir::Inst* user = &decl.instructions[(sz)user_ref];
		uint derived_uses = 0;
		ulong use_offset = 0;
		@sroa_each_value_operand(user; ir::Ref* operand)
		{
			ulong operand_offset;
			if (sroa_pointer_offset(graph, decl, alloc_ref, *operand, visiting, &operand_offset))
			{
				derived_uses++;
				use_offset = operand_offset;
			}
		};
		if (derived_uses == 0) continue;
		if (derived_uses != 1) { return false; }
		value_interner::InternerRef access_type = value_interner::REF_VOID;
		uint access_size = 0;
		bool memory_access = false;
		switch (user.tag)
		{
			case ir::InstTag.LOAD:
				if (!sroa_pointer_offset(graph, decl, alloc_ref, user.data.ref, visiting, &use_offset)) { return false; }
				access_type = user.ty;
				memory_access = true;
				if (!mem_access_size(graph, user.ty, &access_size)) { return false; }
				break;
			case ir::InstTag.STORE:
				if (!sroa_pointer_offset(graph, decl, alloc_ref, user.data.bin.lhs, visiting, &use_offset)) { return false; }
				if ((usz)user.data.bin.rhs >= instruction_count) { return false; }
				access_type = decl.instructions[(sz)user.data.bin.rhs].ty;
				memory_access = true;
				if (!mem_access_size(graph, decl.instructions[(sz)user.data.bin.rhs].ty, &access_size)) { return false; }
				break;
			case ir::InstTag.ADD:
				ulong addend;
				if (user.ty != value_interner::REF_PTR ||
					!sroa_pointer_offset(graph, decl, alloc_ref, user.data.bin.lhs, visiting, &use_offset) ||
					!sroa_constant_offset(graph, decl, user.data.bin.rhs, &addend)) { return false; }
				break;
			default: { return false; }
		}
		if (!memory_access) continue;
		if (access_size == 0 || use_offset > original.size || access_size > original.size - (uint)use_offset) { return false; }

		uint slot_index = uint::max;
		for (uint i = 0; i < slot_count; i++)
		{
			if (slots[i].offset == use_offset && slots[i].size == access_size)
			{
				slot_index = i;
				break;
			}
			MemAddr existing = { .root = alloc_ref, .offset = (long)slots[i].offset, .known_offset = true };
			MemAddr candidate = { .root = alloc_ref, .offset = (long)use_offset, .known_offset = true };
			if (mem_may_alias(existing, slots[i].size, candidate, access_size, non_escaping)) { return false; }
		}
		if (slot_index == uint::max)
		{
			if (slot_count == 32) return false;
			uint alignment = original.align == 0 ? 1 : original.align;
			if (use_offset != 0) alignment = sroa_gcd(alignment, (uint)use_offset);
			if (alignment == 0) alignment = 1;
			slot_index = slot_count++;
			slots[slot_index] = { use_offset, access_size, access_type, alignment };
		}
		accesses[access_count++] = { user_ref, slot_index };
	}
	if (access_count == 0) return false;
	if (slot_count == 1 && slots[0].offset == 0 && slots[0].size == original.size) return false;

	// Append one independent stack object for each disjoint scalar byte range.
	DeclEditor editor;
	editor.begin(decl, allocator);
	for (uint i = 0; i < slot_count; i++)
	{
		editor.insts.push({
			.tag = ir::InstTag.ALLOC,
			.data.alloc = { .size = slots[i].size, .align = slots[i].align, .is_volatile = false },
			.ty = value_interner::REF_PTR,
		});
	}
	for (uint access_index = 0; access_index < access_count; access_index++)
	{
		SroaAccess access = accesses[(sz)access_index];
		ir::Inst* inst = &editor.insts.entries[(sz)access.ref];
		ir::Ref new_pointer = (ir::Ref)(instruction_count + access.slot);
		if (inst.tag == ir::InstTag.LOAD)
		{
			inst.data.ref = new_pointer;
		}
		else if (inst.tag == ir::InstTag.STORE)
		{
			inst.data.bin.lhs = new_pointer;
		}
		else
		{
			// The access table must contain only memory operations. Do not write
			// the bin union arm on another instruction: LABEL stores its name there.
			editor.free();
			return false;
		}
	}

	list::List{ir::Ref} new_body;
	new_body.init(allocator);
	foreach (ref : editor.body)
	{
		if (ref == alloc_ref) continue;
		ulong ignored_offset;
		if ((usz)ref < analysed_count && shared.derived_mark[(sz)ref] == stamp &&
			decl.instructions[(sz)ref].tag == ir::InstTag.ADD &&
			sroa_pointer_offset(graph, decl, alloc_ref, ref, visiting, &ignored_offset)) continue;
		new_body.push(ref);
	}
	editor.body.free();
	editor.body = new_body;
	sz alloc_pos = inline_entry_alloc_position(&editor);
	for (uint i = 0; i < slot_count; i++) editor.insert_body(alloc_pos++, (ir::Ref)(instruction_count + i));
	editor.commit();
	return true;
}

<*
 Split eligible fixed-size allocations into disjoint scalar objects before mem2reg.
 Variable indices, aggregate copies lowered to memcpy/memset calls, address-taken
 locals, and volatile locals bail. Small copy chunks that overlap field boundaries
 also bail; splitting those chunks is follow-up work.
*>
fn bool sroa(ir::Ir* graph, ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || decl.body.len == 0) return false;
	list::List{ir::Ref} candidates;
	candidates.init(allocator);
	defer candidates.free();
	foreach (ref : decl.body)
	{
		if ((usz)ref < (usz)decl.instructions.len && decl.instructions[(sz)ref].tag == ir::InstTag.ALLOC)
		{
			candidates.push(ref);
		}
	}
	if (!candidates.len()) return false;
	usz count = (usz)decl.instructions.len;
	SroaShared shared = { .uses = compute_uses(decl, allocator) };
	shared.non_escaping = mem_compute_non_escaping(graph, decl, &shared.uses, allocator);
	shared.body_position = alloc::new_array(allocator, uint, (sz)count);
	shared.derived_mark = alloc::new_array(allocator, uint, (sz)count);
	shared.user_mark = alloc::new_array(allocator, uint, (sz)count);
	shared.derived.init(allocator);
	shared.users.init(allocator);
	defer
	{
		shared.uses.free();
		alloc::free(allocator, shared.non_escaping.ptr);
		alloc::free(allocator, shared.body_position.ptr);
		alloc::free(allocator, shared.derived_mark.ptr);
		alloc::free(allocator, shared.user_mark.ptr);
		shared.derived.free();
		shared.users.free();
	}
	for (usz i = 0; i < count; i++)
	{
		shared.body_position[i] = uint::max; shared.derived_mark[i] = 0; shared.user_mark[i] = 0;
	}
	foreach (pos, ref : decl.body)
	{
		if ((usz)ref < count) shared.body_position[(sz)ref] = (uint)pos;
	}
	bool changed = false;
	foreach (ref : candidates) changed = sroa_one(graph, decl, ref, &shared, allocator) || changed;
	return changed;
}

struct MemFact
{
	MemAddr address;
	uint size;
	value_interner::InternerRef ty;
	ir::Ref value;
	bool from_store;
}

enum MemUndoKind : char
{
	VALID,
	ROOT_PUSH,
}

struct MemUndo
{
	MemUndoKind kind;
	bool old_valid;
	ir::Ref ref;
}

struct MemOptContext
{
	ir::Ir* graph;
	ir::Decl* decl;
	DeclEditor* editor;
	Cfg* cfg;
	bool[] non_escaping;
	bool[] remove;
	ir::Ref[] replacements;
	MemFact[] facts;
	// A fact is visible when `valid` and recorded at or after `floor`; raising the
	// floor hides every inherited fact in O(1) for a child that does not inherit.
	bool[] valid;
	uint[] seq;
	uint next_seq;
	uint floor;
	bool[] loaded_root;
	// Facts per non-escaping root, in recording order; may hold invalid entries.
	list::List{ir::Ref}[] root_facts;
	// Undo log restoring `valid` and `root_facts` after a dominator-tree child.
	list::List{MemUndo} undo;
	// Pending block-local stores per root (dead-store candidates) and their flags.
	list::List{ir::Ref}[] root_pending;
	list::List{ir::Ref} pending_roots;
	bool[] local_store;
}

fn bool mem_fact_visible(MemOptContext* context, ir::Ref ref) @inline
{
	return context.valid[(sz)ref] && context.seq[(sz)ref] >= context.floor;
}

fn void mem_invalidate(MemOptContext* context, ir::Ref ref) @inline
{
	if (!mem_fact_visible(context, ref)) return;
	context.undo.push({ .kind = MemUndoKind.VALID, .old_valid = true, .ref = ref });
	context.valid[(sz)ref] = false;
}

fn void mem_record_fact(MemOptContext* context, ir::Ref ref, MemFact fact)
{
	context.facts[(sz)ref] = fact;
	context.seq[(sz)ref] = context.next_seq++;
	context.undo.push({ .kind = MemUndoKind.VALID, .old_valid = context.valid[(sz)ref], .ref = ref });
	context.valid[(sz)ref] = true;
	context.root_facts[(sz)fact.address.root].push(ref);
	context.undo.push({ .kind = MemUndoKind.ROOT_PUSH, .ref = fact.address.root });
}

fn void mem_rollback(MemOptContext* context, sz mark)
{
	while (context.undo.len() > mark)
	{
		MemUndo entry = context.undo.pop()!!;
		switch (entry.kind)
		{
			case VALID: context.valid[(sz)entry.ref] = entry.old_valid;
			case ROOT_PUSH: (void)context.root_facts[(sz)entry.ref].pop();
		}
	}
}

fn void mem_invalidate_root(MemOptContext* context, ir::Ref root)
{
	foreach (ref : context.root_facts[(sz)root]) mem_invalidate(context, ref);
}

<* Drop pending dead-store candidates of `root`; a read observes them. *>
fn void mem_drop_pending_root(MemOptContext* context, ir::Ref root)
{
	foreach (ref : context.root_pending[(sz)root]) context.local_store[(sz)ref] = false;
}

fn void mem_push_pending(MemOptContext* context, ir::Ref root, ir::Ref ref)
{
	if (!context.root_pending[(sz)root].len()) context.pending_roots.push(root);
	context.root_pending[(sz)root].push(ref);
	context.local_store[(sz)ref] = true;
}

fn void mem_clear_pending(MemOptContext* context)
{
	foreach (root : context.pending_roots)
	{
		foreach (ref : context.root_pending[(sz)root]) context.local_store[(sz)ref] = false;
		context.root_pending[(sz)root].clear();
	}
	context.pending_roots.clear();
}

fn bool mem_access(ir::Ir* graph, ir::Inst[] insts, ir::Inst* inst, MemAddr* address,
	uint* size, value_interner::InternerRef* ty, ir::Ref* value, bool* is_load)
{
	if (inst.tag == ir::InstTag.LOAD)
	{
		*ty = inst.ty;
		*value = ir::NONE;
		*is_load = true;
		if (!mem_access_size(graph, inst.ty, size)) return false;
		return mem_decompose_address(graph, insts, inst.data.ref, address);
	}
	if (inst.tag == ir::InstTag.STORE)
	{
		if ((usz)inst.data.bin.rhs >= (usz)insts.len) return false;
		*ty = insts[(sz)inst.data.bin.rhs].ty;
		*value = inst.data.bin.rhs;
		*is_load = false;
		if (!mem_access_size(graph, *ty, size)) return false;
		return mem_decompose_address(graph, insts, inst.data.bin.lhs, address);
	}
	return false;
}

fn ir::Ref mem_resolve(ir::Ref[] replacements, ir::Ref ref)
{
	if (ref == ir::NONE || (usz)ref >= (usz)replacements.len) return ref;
	while (replacements[(sz)ref] != ref) ref = replacements[(sz)ref];
	return ref;
}

fn bool mem_same_slot(MemFact old, MemFact newer)
{
	if (old.address.root != newer.address.root || !old.address.known_offset || !newer.address.known_offset ||
		old.address.offset < 0 || newer.address.offset < 0) return false;
	return old.address.offset == newer.address.offset && old.size == newer.size;
}

fn ir::Ref mem_clear_root(MemOptContext* context, ir::Inst[] insts, ir::Ref address_ref)
{
	MemAddr address;
	if (!mem_decompose_address(context.graph, insts, address_ref, &address) || address.root == ir::NONE ||
		(usz)address.root >= (usz)context.non_escaping.len || !context.non_escaping[(sz)address.root]) return ir::NONE;
	mem_invalidate_root(context, address.root);
	// Atomic and varargs operations are not expected to reach a non-escaping
	// alloca. If malformed or future IR does so, conservatively treat it as a
	// read/write so neither forwarding nor never-loaded-root DSE can use it.
	context.loaded_root[(sz)address.root] = true;
	return address.root;
}

<* Walk the dominator tree with a private memory-fact scope per child.
   Facts and pending stores belong to non-escaping roots, and distinct
   non-escaping roots never alias, so every query is per root. *>
fn void mem_opt_block(MemOptContext* context, uint block_index)
{
	CfgBlock* block = &context.cfg.blocks[(sz)block_index];
	sz end = block_executable_end(context.decl, block);
	usz count = context.decl.instructions.len;
	for (sz pos = block.start + 1; pos < end; pos++)
	{
		ir::Ref ref = context.editor.body.entries[pos];
		if ((usz)ref >= count) continue;
		ir::Inst* inst = &context.editor.insts.entries[(sz)ref];
		@each_value_operand(inst; ir::Ref* slot) { *slot = mem_resolve(context.replacements, *slot); };
		if (inst.tag == ir::InstTag.ATOMIC_LOAD || inst.tag == ir::InstTag.ATOMIC_STORE || inst.tag == ir::InstTag.VA_START)
		{
			ir::Ref address_ref = inst.tag == ir::InstTag.VA_START ? inst.data.ref : inst.data.atomic.ptr;
			ir::Ref root = mem_clear_root(context, context.editor.insts.array_view(), address_ref);
			if (root != ir::NONE) mem_drop_pending_root(context, root);
			continue;
		}
		if (inst.tag != ir::InstTag.LOAD && inst.tag != ir::InstTag.STORE) continue;
		MemAddr address;
		uint size = 0;
		value_interner::InternerRef ty;
		ir::Ref value;
		bool is_load;
		if (!mem_access(context.graph, context.editor.insts.array_view(), inst, &address, &size, &ty, &value, &is_load))
		{
			// A type with no known scalar size cannot be tracked for forwarding,
			// but an access to a tracked alloca still observes or clobbers its facts.
			ir::Ref address_ref = inst.tag == ir::InstTag.LOAD ? inst.data.ref : inst.data.bin.lhs;
			if (!mem_decompose_address(context.graph, context.editor.insts.array_view(), address_ref, &address) ||
				address.root == ir::NONE || (usz)address.root >= (usz)context.non_escaping.len ||
				!context.non_escaping[(sz)address.root]) continue;
			if (inst.tag == ir::InstTag.LOAD)
			{
				context.loaded_root[(sz)address.root] = true;
			}
			else
			{
				mem_invalidate_root(context, address.root);
			}
			mem_drop_pending_root(context, address.root);
			continue;
		}
		if (address.root == ir::NONE || (usz)address.root >= (usz)context.non_escaping.len ||
			!context.non_escaping[(sz)address.root]) continue;
		MemFact current = { .address = address, .size = size, .ty = ty,
			.value = is_load ? ref : mem_resolve(context.replacements, value), .from_store = !is_load };
		list::List{ir::Ref}* root_facts = &context.root_facts[(sz)address.root];
		list::List{ir::Ref}* pending = &context.root_pending[(sz)address.root];
		if (is_load)
		{
			if (address.known_offset)
			{
				// Use the lowest-numbered matching fact, as a full scan in ref order would.
				ir::Ref best = ir::NONE;
				foreach (old_ref : *root_facts)
				{
					if (!mem_fact_visible(context, old_ref) || (best != ir::NONE && (usz)old_ref >= (usz)best)) continue;
					MemFact old = context.facts[(sz)old_ref];
					if (old.ty != ty || old.size != size || !old.address.known_offset || old.address.offset != address.offset) continue;
					if (old.from_store || old.value != ref) best = old_ref;
				}
				if (best != ir::NONE)
				{
					context.replacements[(sz)ref] = context.facts[(sz)best].value;
					context.remove[(sz)ref] = true;
				}
			}
			// A forwarded load is removed and no longer observes this root.
			if (!context.remove[(sz)ref]) context.loaded_root[(sz)address.root] = true;
			foreach (store_ref : *pending)
			{
				if (context.local_store[(sz)store_ref] &&
					mem_may_alias(context.facts[(sz)store_ref].address, context.facts[(sz)store_ref].size, address, size, context.non_escaping))
				{
					context.local_store[(sz)store_ref] = false;
				}
			}
			if (!address.known_offset) continue;
			// Keep the load as a reusable value, even if it was itself forwarded.
			current.value = mem_resolve(context.replacements, ref);
			mem_record_fact(context, ref, current);
		}
		else
		{
			// Stores to a dynamic offset may change any byte in their root, so
			// pending local stores to that same root are no longer candidates.
			if (!address.known_offset) mem_drop_pending_root(context, address.root);
			foreach (old_ref : *root_facts)
			{
				if (mem_fact_visible(context, old_ref) &&
					mem_may_alias(context.facts[(sz)old_ref].address, context.facts[(sz)old_ref].size, address, size, context.non_escaping))
				{
					mem_invalidate(context, old_ref);
				}
			}
			if (!address.known_offset) continue;
			// Calls, atomics, fences, and other memory operations do not invalidate
			// non-escaping alloca facts: escape analysis rejects an alloca passed to
			// a call/atomic/va_start. Atomics and va_start are also guarded above.
			// Store-to-load forwarding facts remain live until an aliasing write.
			mem_record_fact(context, ref, current);
			foreach (old_ref : *pending)
			{
				if (!context.local_store[(sz)old_ref]) continue;
				if (mem_same_slot(context.facts[(sz)old_ref], current))
				{
					context.remove[(sz)old_ref] = true;
					context.local_store[(sz)old_ref] = false;
				}
			}
			mem_push_pending(context, address.root, ref);
		}
	}
	mem_clear_pending(context);
	// A child inherits only when every reachable path into it passes through this
	// block. At a join (including a loop header), sibling stores may otherwise be
	// absent from the inherited state. Each child gets a private scope.
	foreach (child : block.dom_children)
	{
		uint reachable_pred = NONE_BLOCK;
		uint reachable_pred_count = 0;
		foreach (pred : context.cfg.blocks[(sz)child].preds)
		{
			if (!context.cfg.reachable[(sz)pred]) continue;
			reachable_pred = pred;
			reachable_pred_count++;
		}
		bool inherits = reachable_pred_count == 1 && reachable_pred == block_index;
		sz mark = context.undo.len();
		uint saved_floor = context.floor;
		if (!inherits) context.floor = context.next_seq;
		mem_opt_block(context, child);
		context.floor = saved_floor;
		mem_rollback(context, mark);
	}
}

<* Dominator-scoped load forwarding and conservative dead-store elimination for
   fixed-size, non-escaping stack objects. *>
fn bool mem_opt(ir::Ir* graph, ir::Decl* decl, Allocator allocator)
{
	if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
	Uses uses = compute_uses(decl, allocator);
	defer uses.free();
	bool[] non_escaping = mem_compute_non_escaping(graph, decl, &uses, allocator);
	defer alloc::free(allocator, non_escaping.ptr);
	usz count = decl.instructions.len;
	bool[] remove = alloc::new_array(allocator, bool, (sz)count);
	defer alloc::free(allocator, remove.ptr);
	bool[] loaded_root = alloc::new_array(allocator, bool, (sz)count);
	defer alloc::free(allocator, loaded_root.ptr);
	ir::Ref[] replacements = alloc::new_array(allocator, ir::Ref, (sz)count);
	defer alloc::free(allocator, replacements.ptr);
	MemFact[] facts = alloc::new_array(allocator, MemFact, (sz)count);
	defer alloc::free(allocator, facts.ptr);
	bool[] valid = alloc::new_array(allocator, bool, (sz)count);
	defer alloc::free(allocator, valid.ptr);
	for (usz i = 0; i < count; i++)
	{
		remove[i] = false; loaded_root[i] = false; valid[i] = false;
		replacements[i] = (ir::Ref)i;
	}
	Cfg cfg = build_cfg(decl, allocator);
	defer cfg.free();
	if (cfg.blocks.len)
	{
		cfg.compute_dominators();
		// Loads outside the executable portion of reachable blocks, and loads
		// in unreachable blocks, are not visited by CSE. Conservatively keep
		// their roots live because this pass does not rewrite that code.
		foreach (block_index, block : cfg.blocks)
		{
			sz executable_end = block_executable_end(decl, &block);
			for (sz pos = block.start + 1; pos < block.end; pos++)
			{
				if (cfg.reachable[(sz)block_index] && pos < executable_end) continue;
				ir::Ref ref = decl.body[(sz)pos];
				if ((usz)ref >= count || decl.instructions[(sz)ref].tag != ir::InstTag.LOAD) continue;
				MemAddr address;
				if (!mem_decompose_address(graph, decl.instructions, decl.instructions[(sz)ref].data.ref, &address)) continue;
				if (address.root != ir::NONE && (usz)address.root < (usz)non_escaping.len && non_escaping[(sz)address.root])
				{
					loaded_root[(sz)address.root] = true;
				}
			}
		}
		DeclEditor editor;
		editor.begin(decl, allocator);
		uint[] seq = alloc::new_array(allocator, uint, (sz)count);
		defer alloc::free(allocator, seq.ptr);
		bool[] local_store = alloc::new_array(allocator, bool, (sz)count);
		defer alloc::free(allocator, local_store.ptr);
		list::List{ir::Ref}[] root_facts = alloc::new_array(allocator, list::List{ir::Ref}, (sz)count);
		list::List{ir::Ref}[] root_pending = alloc::new_array(allocator, list::List{ir::Ref}, (sz)count);
		for (usz i = 0; i < count; i++)
		{
			seq[i] = 0; local_store[i] = false;
			root_facts[i].init(allocator, 0);
			root_pending[i].init(allocator, 0);
		}
		defer
		{
			for (usz i = 0; i < count; i++) { root_facts[i].free(); root_pending[i].free(); }
			alloc::free(allocator, root_facts.ptr);
			alloc::free(allocator, root_pending.ptr);
		}
		MemOptContext context = { .graph = graph, .decl = decl, .editor = &editor, .cfg = &cfg,
			.non_escaping = non_escaping, .remove = remove, .replacements = replacements,
			.facts = facts, .valid = valid, .seq = seq, .loaded_root = loaded_root,
			.root_facts = root_facts, .root_pending = root_pending, .local_store = local_store };
		context.undo.init(allocator);
		context.pending_roots.init(allocator);
		defer { context.undo.free(); context.pending_roots.free(); }
		mem_opt_block(&context, cfg.rpo[0]);
		// Remove stores and pointer arithmetic for internal roots that no load in
		// reachable or unreachable code reads. These ADDs only form addresses for
		// the removed stores, so removing them also makes the ALLOC dead here.
		foreach (ref : editor.body)
		{
			if ((usz)ref >= count) continue;
			ir::Inst* inst = &editor.insts.entries[(sz)ref];
			if (inst.tag == ir::InstTag.ALLOC)
			{
				if ((usz)ref < (usz)non_escaping.len && non_escaping[(sz)ref] && !loaded_root[(sz)ref])
				{
					remove[(sz)ref] = true;
				}
				continue;
			}
			ir::Ref address_ref;
			if (inst.tag == ir::InstTag.STORE)
			{
				address_ref = inst.data.bin.lhs;
			}
			else if (inst.tag == ir::InstTag.ADD && inst.ty == value_interner::REF_PTR)
			{
				address_ref = ref;
			}
			else
			{
				continue;
			}
			MemAddr address;
			if (!mem_decompose_address(graph, editor.insts.array_view(), address_ref, &address)) continue;
			if (address.root != ir::NONE && (usz)address.root < (usz)non_escaping.len &&
				non_escaping[(sz)address.root] && !loaded_root[(sz)address.root]) remove[(sz)ref] = true;
		}
		bool changed = false;
		foreach (ref : editor.body)
		{
			if ((usz)ref >= count) continue;
			changed = changed || remove[(sz)ref];
			@each_value_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot) { *slot = mem_resolve(replacements, *slot); };
		}
		BodyRemovalContext removal_context = { .remove = remove };
		editor.remove_body_where(&body_ref_marked_for_removal, (void*)&removal_context);
		editor.commit();
		return changed;
	}
	return false;
}
