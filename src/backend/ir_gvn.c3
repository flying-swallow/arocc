// Optimistic global value numbering for scalar IR and tracked stack reads.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, aro::primitive_value;
import std::collections::list, std::collections::map;

const uint GVN_TOP = uint::max;
const uint GVN_MAX_ROOTS = 64;
const uint GVN_MAX_PASSES = 8;

struct GvnExpr
{
	ir::InstTag tag;
	value_interner::InternerRef ty;
	uint a;
	uint b;
	uint c;
	uint memory_version;
}

fn uint GvnExpr.hash(self)
{
	return (uint)self.tag * 0x9E3779B9 ^ (uint)self.ty * 0x85EBCA6B ^
		self.a * 0xC2B2AE35 ^ self.b * 0x27D4EB2F ^ self.c * 0x165667B1 ^
		self.memory_version * 0xD3A2646C;
}

fn bool GvnExpr.equals(self, GvnExpr other)
=> self.tag == other.tag && self.ty == other.ty && self.a == other.a &&
	self.b == other.b && self.c == other.c && self.memory_version == other.memory_version;

struct GvnPass
{
	ir::Ir* graph;
	ir::Decl* decl;
	Cfg* cfg;
	uint[] value_numbers;
	bool[] numbered;
	uint[] root_slot;
	ir::Ref[] roots;
	uint root_count;
	uint[] memory_in;
	uint[] memory_out;
	HashMap{GvnExpr, uint} values;
	bool changed;
	bool pessimistic;
}

fn sz gvn_memory_index(GvnPass* context, uint block, uint root)
=> (sz)((usz)block * (usz)context.root_count + (usz)root);

fn uint gvn_memory_phi(GvnPass* context, uint block, uint root)
{
	// Synthetic memory values live above the instruction-ref range and are
	// stable across passes. The root is part of the index, so roots never alias.
	ulong index = (ulong)context.decl.instructions.len + 1 +
		(ulong)block * (ulong)context.root_count + root;
	if (index >= (ulong)uint::max) return uint::max - 1;
	return (uint)index;
}

fn uint gvn_input_value(GvnPass* context, ir::Ref ref)
{
	if ((usz)ref >= (usz)context.value_numbers.len) return GVN_TOP;
	return context.value_numbers[(sz)ref];
}

fn bool gvn_is_pointer_type(ir::Ir* graph, value_interner::InternerRef ty)
=> graph.interner.get(ty).tag == primitive_value::PrimitiveType.PTR_TY;

fn bool gvn_is_float_type(ir::Ir* graph, value_interner::InternerRef ty)
=> graph.interner.get(ty).tag == primitive_value::PrimitiveType.FLOAT_TY;

fn bool gvn_integer_result(ir::Ir* graph, ir::Inst inst)
{
	ushort width;
	return const_prop_int_width(graph, inst.ty, &width);
}

fn bool gvn_commutative(ir::InstTag tag)
{
	switch (tag)
	{
		case ADD: case MUL: case BIT_AND: case BIT_OR: case BIT_XOR:
		case CMP_EQ: case CMP_NE: case FCMP_OEQ: case FCMP_UNE: return true;
		default: return false;
	}
}

fn bool gvn_make_expression(GvnPass* context, ir::Inst inst, GvnExpr* key, bool* operands_ready)
{
	*operands_ready = true;
	*key = { .tag = inst.tag, .ty = inst.ty, .a = GVN_TOP, .b = GVN_TOP,
		.c = GVN_TOP, .memory_version = 0 };
	switch (inst.tag)
	{
		case ir::InstTag.SELECT:
			key.a = gvn_input_value(context, inst.data.branch.cond);
			key.b = gvn_input_value(context, inst.data.branch.then_label);
			key.c = gvn_input_value(context, inst.data.branch.else_label);
			*operands_ready = key.a != GVN_TOP && key.b != GVN_TOP && key.c != GVN_TOP;
			return true;
		case ir::InstTag.BIT_NOT: case ir::InstTag.NEGATE:
		case ir::InstTag.TRUNC: case ir::InstTag.ZEXT: case ir::InstTag.SEXT:
		case ir::InstTag.FPTOSI: case ir::InstTag.FPTOUI: case ir::InstTag.SITOFP:
		case ir::InstTag.UITOFP: case ir::InstTag.FPEXT: case ir::InstTag.FPTRUNC:
		case ir::InstTag.FNEG: case ir::InstTag.CLZ: case ir::InstTag.CTZ:
			key.a = gvn_input_value(context, inst.data.ref);
			if ((inst.tag == ir::InstTag.CLZ || inst.tag == ir::InstTag.CTZ) &&
				!gvn_integer_result(context.graph, inst)) return false;
			*operands_ready = key.a != GVN_TOP;
			return true;
		case ir::InstTag.ADD: case ir::InstTag.SUB: case ir::InstTag.MUL:
		case ir::InstTag.SDIV: case ir::InstTag.UDIV: case ir::InstTag.SREM: case ir::InstTag.UREM:
		case ir::InstTag.BIT_AND: case ir::InstTag.BIT_OR: case ir::InstTag.BIT_XOR:
		case ir::InstTag.BIT_SHL: case ir::InstTag.BIT_ASHR: case ir::InstTag.BIT_LSHR:
		case ir::InstTag.CMP_EQ: case ir::InstTag.CMP_NE:
		case ir::InstTag.CMP_SLT: case ir::InstTag.CMP_SLTE: case ir::InstTag.CMP_SGT: case ir::InstTag.CMP_SGTE:
		case ir::InstTag.CMP_ULT: case ir::InstTag.CMP_ULTE: case ir::InstTag.CMP_UGT: case ir::InstTag.CMP_UGTE:
		case ir::InstTag.FADD: case ir::InstTag.FSUB: case ir::InstTag.FMUL: case ir::InstTag.FDIV:
		case ir::InstTag.FCMP_OEQ: case ir::InstTag.FCMP_UNE: case ir::InstTag.FCMP_OLT:
		case ir::InstTag.FCMP_OLE: case ir::InstTag.FCMP_OGT: case ir::InstTag.FCMP_OGE:
			if ((usz)inst.data.bin.lhs >= (usz)context.decl.instructions.len ||
				(usz)inst.data.bin.rhs >= (usz)context.decl.instructions.len) return false;
			value_interner::InternerRef lhs_ty = context.decl.instructions[(sz)inst.data.bin.lhs].ty;
			value_interner::InternerRef rhs_ty = context.decl.instructions[(sz)inst.data.bin.rhs].ty;
			bool pointer_arithmetic = (inst.tag == ir::InstTag.ADD || inst.tag == ir::InstTag.SUB) &&
				gvn_is_pointer_type(context.graph, inst.ty);
			ushort integer_operand_width;
			bool pointer_integer_operands = pointer_arithmetic &&
				((gvn_is_pointer_type(context.graph, lhs_ty) && const_prop_int_width(context.graph, rhs_ty, &integer_operand_width)) ||
					(inst.tag == ir::InstTag.ADD && gvn_is_pointer_type(context.graph, rhs_ty) &&
						const_prop_int_width(context.graph, lhs_ty, &integer_operand_width)));
			if (pointer_arithmetic ? !pointer_integer_operands : lhs_ty != rhs_ty) return false;
			bool float_op = inst.tag == ir::InstTag.FADD || inst.tag == ir::InstTag.FSUB ||
				inst.tag == ir::InstTag.FMUL || inst.tag == ir::InstTag.FDIV ||
				inst.tag == ir::InstTag.FCMP_OEQ || inst.tag == ir::InstTag.FCMP_UNE ||
				inst.tag == ir::InstTag.FCMP_OLT || inst.tag == ir::InstTag.FCMP_OLE ||
				inst.tag == ir::InstTag.FCMP_OGT || inst.tag == ir::InstTag.FCMP_OGE;
			if (float_op && !gvn_is_float_type(context.graph, lhs_ty)) return false;
			if (!float_op && !pointer_arithmetic && !gvn_integer_result(context.graph, inst)) return false;
			key.a = gvn_input_value(context, inst.data.bin.lhs);
			key.b = gvn_input_value(context, inst.data.bin.rhs);
			*operands_ready = key.a != GVN_TOP && key.b != GVN_TOP;
			if (!*operands_ready) return true;
			// Normalize exact commutative operations and swapped compare predicates.
			bool swapped_predicate = false;
			switch (inst.tag)
			{
				case CMP_SGT: key.tag = ir::InstTag.CMP_SLT; swapped_predicate = true;
				case CMP_SGTE: key.tag = ir::InstTag.CMP_SLTE; swapped_predicate = true;
				case CMP_UGT: key.tag = ir::InstTag.CMP_ULT; swapped_predicate = true;
				case CMP_UGTE: key.tag = ir::InstTag.CMP_ULTE; swapped_predicate = true;
				case FCMP_OGT: key.tag = ir::InstTag.FCMP_OLT; swapped_predicate = true;
				case FCMP_OGE: key.tag = ir::InstTag.FCMP_OLE; swapped_predicate = true;
				default: break;
			}
			if (swapped_predicate || (gvn_commutative(inst.tag) && key.a > key.b))
			{
				uint swap_value = key.a; key.a = key.b; key.b = swap_value;
			}
			// Float arithmetic keeps operand order: SSE NaN payloads can differ.
			return true;
		default: return false;
	}
}

fn uint gvn_merge_memory(GvnPass* context, uint block_index, uint root)
{
	if (block_index == context.cfg.rpo[0]) return (uint)context.roots[(sz)root];
	uint candidate = GVN_TOP;
	bool differs = false;
	bool has_top = false;
	foreach (pred : context.cfg.blocks[(sz)block_index].preds)
	{
		if (!context.cfg.reachable[(sz)pred]) continue;
		uint value = context.memory_out[gvn_memory_index(context, pred, root)];
		if (value == GVN_TOP) { has_top = true; continue; }
		if (candidate == GVN_TOP)
		{
			candidate = value;
		}
		else if (candidate != value)
		{
			differs = true;
		}
	}
	if (context.pessimistic && has_top) return gvn_memory_phi(context, block_index, root);
	if (differs) return gvn_memory_phi(context, block_index, root);
	return candidate;
}

fn uint gvn_root_slot(GvnPass* context, ir::Ref root)
{
	if ((usz)root >= (usz)context.root_slot.len) return NONE_BLOCK;
	return context.root_slot[(sz)root];
}

fn bool gvn_tracked_address(GvnPass* context, ir::Ref address_ref, MemAddr* address, uint* slot)
{
	if (!mem_decompose_address(context.graph, context.decl.instructions, address_ref, address)) return false;
	uint root_index = gvn_root_slot(context, address.root);
	if (root_index == NONE_BLOCK) return false;
	*slot = root_index;
	return true;
}

fn void gvn_call_effects(GvnPass* context, ir::Inst call, ir::Ref call_ref, uint[] current_memory)
{
	ir::Decl* callee = mem_call_callee(context.graph, context.decl, &call);
	bool metadata_ok = callee != null &&
		(usz)call.data.call.memory_copy_bytes.len == (usz)call.data.call.args.len;
	foreach (i, arg : call.data.call.args)
	{
		MemAddr address;
		uint slot;
		if (!gvn_tracked_address(context, arg, &address, &slot)) continue;
		bool known_arg = metadata_ok && i < 64 &&
			(callee.attrs.arg_nocapture & ((ulong)1 << i)) != 0 &&
			call.data.call.memory_copy_bytes[(sz)i] == 0;
		// Honor the same per-argument read/write/capture summaries as mem_opt.
		// Either memory effect invalidates this root's existing load facts; an
		// unvalidated call argument is conservatively read/write.
		bool reads = !known_arg || (callee.attrs.arg_noread & ((ulong)1 << i)) == 0;
		bool writes = !known_arg || (callee.attrs.arg_nowrite & ((ulong)1 << i)) == 0;
		if (reads || writes) current_memory[(sz)slot] = (uint)call_ref;
	}
}

fn bool gvn_phi_inputs_equal(GvnPass* context, ir::Inst left, ir::Ref left_ref,
	ir::Inst right, ir::Ref right_ref)
{
	if (left.ty != right.ty || left.data.phi.len != right.data.phi.len) return false;
	foreach (input : left.data.phi)
	{
		bool found = false;
		foreach (other : right.data.phi)
		{
			if (input.label != other.label) continue;
			uint left_value = input.value == left_ref ? GVN_TOP : gvn_input_value(context, input.value);
			uint right_value = other.value == right_ref ? GVN_TOP : gvn_input_value(context, other.value);
			if (left_value != right_value) return false;
			found = true;
			break;
		}
		if (!found) return false;
	}
	return true;
}

fn uint gvn_phi_number(GvnPass* context, ir::Inst inst, ir::Ref ref, CfgBlock* block, sz body_pos)
{
	if (context.pessimistic) return (uint)ref;
	bool have_value = false;
	bool all_same = true;
	uint common = GVN_TOP;
	foreach (input : inst.data.phi)
	{
		if (input.value == ref) continue;
		uint value = gvn_input_value(context, input.value);
		if (value == GVN_TOP) continue;
		if (!have_value)
		{
			common = value;
			have_value = true;
		}
		else if (common != value)
		{
			all_same = false;
		}
	}
	if (!have_value) return GVN_TOP;
	if (all_same) return common;
	for (sz pos = block.start + 1; pos < body_pos; pos++)
	{
		ir::Ref previous_ref = context.decl.body[pos];
		if ((usz)previous_ref >= (usz)context.decl.instructions.len) continue;
		ir::Inst previous = context.decl.instructions[(sz)previous_ref];
		if (previous.tag != ir::InstTag.PHI) continue;
		if (gvn_phi_inputs_equal(context, inst, ref, previous, previous_ref))
		{
			uint previous_vn = gvn_input_value(context, previous_ref);
			if (previous_vn != GVN_TOP) return previous_vn;
		}
	}
	return (uint)ref;
}

fn void gvn_process_block(GvnPass* context, uint block_index, uint[] current_memory)
{
	CfgBlock* block = &context.cfg.blocks[(sz)block_index];
	for (uint root = 0; root < context.root_count; root++)
	{
		uint incoming = gvn_merge_memory(context, block_index, root);
		sz index = gvn_memory_index(context, block_index, root);
		if (context.memory_in[index] != incoming) { context.changed = true; context.memory_in[index] = incoming; }
		current_memory[(sz)root] = incoming;
	}
	sz end = block_executable_end(context.decl, block);
	for (sz pos = block.start + 1; pos < end; pos++)
	{
		ir::Ref ref = context.decl.body[pos];
		if ((usz)ref >= (usz)context.decl.instructions.len) continue;
		ir::Inst inst = context.decl.instructions[(sz)ref];
		uint next = (uint)ref;
		if (inst.tag == ir::InstTag.PHI)
		{
			next = gvn_phi_number(context, inst, ref, block, pos);
			context.numbered[(sz)ref] = next != GVN_TOP;
		}
		else if (inst.tag == ir::InstTag.STORE)
		{
			MemAddr address;
			uint slot;
			if (gvn_tracked_address(context, inst.data.bin.lhs, &address, &slot))
			{
				current_memory[(sz)slot] = (uint)ref;
				uint size;
				uint address_vn = gvn_input_value(context, inst.data.bin.lhs);
				uint value_vn = gvn_input_value(context, inst.data.bin.rhs);
				if (address.known_offset && address_vn != GVN_TOP && value_vn != GVN_TOP &&
					(usz)inst.data.bin.rhs < (usz)context.decl.instructions.len &&
					mem_access_size(context.graph, context.decl.instructions[(sz)inst.data.bin.rhs].ty, &size))
				{
					GvnExpr key = { .tag = ir::InstTag.LOAD,
						.ty = context.decl.instructions[(sz)inst.data.bin.rhs].ty,
						.a = address_vn, .b = GVN_TOP, .c = GVN_TOP,
						.memory_version = current_memory[(sz)slot] };
					context.values.set(key, value_vn);
				}
			}
		}
		else if (inst.tag == ir::InstTag.CALL)
		{
			gvn_call_effects(context, inst, ref, current_memory);
		}
		else if (inst.tag == ir::InstTag.ATOMIC_LOAD || inst.tag == ir::InstTag.ATOMIC_STORE)
		{
			MemAddr address;
			uint slot;
			if (gvn_tracked_address(context, inst.data.atomic.ptr, &address, &slot))
			{
				current_memory[(sz)slot] = (uint)ref;
			}
		}
		else if (inst.tag == ir::InstTag.VA_START)
		{
			MemAddr address;
			uint slot;
			if (gvn_tracked_address(context, inst.data.ref, &address, &slot))
			{
				current_memory[(sz)slot] = (uint)ref;
			}
		}
		else if (inst.tag == ir::InstTag.LOAD && !inst.is_volatile_access())
		{
			MemAddr address;
			uint slot, size;
			if (gvn_tracked_address(context, inst.data.ref, &address, &slot) && address.known_offset &&
				current_memory[(sz)slot] != GVN_TOP && mem_access_size(context.graph, inst.ty, &size))
			{
				uint address_vn = gvn_input_value(context, inst.data.ref);
				if (address_vn != GVN_TOP)
				{
					GvnExpr key = { .tag = ir::InstTag.LOAD, .ty = inst.ty,
						.a = address_vn, .b = GVN_TOP, .c = GVN_TOP,
						.memory_version = current_memory[(sz)slot] };
					if (try value = context.values.get(key))
					{
						next = value;
					}
					else
					{
						context.values.set(key, next);
					}
					context.numbered[(sz)ref] = next != GVN_TOP;
				}
			}
		}
		else
		{
			GvnExpr key;
			bool operands_ready;
			if (gvn_make_expression(context, inst, &key, &operands_ready))
			{
				if (!operands_ready)
				{
					next = GVN_TOP;
				}
				else
				{
					if (try value = context.values.get(key))
					{
						next = value;
					}
					else
					{
						context.values.set(key, next);
					}
					context.numbered[(sz)ref] = true;
				}
			}
		}
		if (context.value_numbers[(sz)ref] != next)
		{
			context.value_numbers[(sz)ref] = next;
			context.changed = true;
		}
	}
	for (uint root = 0; root < context.root_count; root++)
	{
		sz index = gvn_memory_index(context, block_index, root);
		if (context.memory_out[index] != current_memory[(sz)root])
		{
			context.memory_out[index] = current_memory[(sz)root];
			context.changed = true;
		}
	}
}

fn void gvn_run_pass(GvnPass* context)
{
	context.values.clear();
	context.changed = false;
	for (usz i = 0; i < context.numbered.len; i++) context.numbered[i] = false;
	// Seed values that precede the CFG labels and otherwise are not visited by
	// the RPO block walk. Also do this in the pessimistic fallback pass.
	foreach (i, inst : context.decl.instructions)
	{
		if (inst.tag != ir::InstTag.ARG && inst.tag != ir::InstTag.SYMBOL && inst.tag != ir::InstTag.ALLOC) continue;
		if (context.value_numbers[i] != (uint)i)
		{
			context.value_numbers[i] = (uint)i;
			context.changed = true;
		}
	}
	// Constants are global values and may be referenced from any reachable block.
	foreach (i, inst : context.decl.instructions)
	{
		if (inst.tag != ir::InstTag.CONSTANT) continue;
		GvnExpr key = { .tag = ir::InstTag.CONSTANT, .ty = inst.ty,
			.a = (uint)inst.data.constant, .b = 0, .c = 0, .memory_version = 0 };
		uint next = (uint)i;
		if (try value = context.values.get(key))
		{
			next = value;
		}
		else
		{
			context.values.set(key, next);
		}
		context.numbered[i] = true;
		if (context.value_numbers[i] != next)
		{
			context.value_numbers[i] = next;
			context.changed = true;
		}
	}
	uint[] current_memory = alloc::new_array(tmem, uint, (sz)context.root_count);
	foreach (block : context.cfg.rpo) gvn_process_block(context, block, current_memory);
}

fn ir::Ref gvn_resolve(ir::Ref[] replacements, ir::Ref ref)
{
	if (ref == ir::NONE || (usz)ref >= (usz)replacements.len) return ref;
	while (replacements[(sz)ref] != ref) ref = replacements[(sz)ref];
	return ref;
}

fn bool gvn_is_global_leaf(ir::Inst inst)
=> inst.tag == ir::InstTag.CONSTANT || inst.tag == ir::InstTag.ARG || inst.tag == ir::InstTag.ALLOC;

<* The lowest-index CONSTANT/ARG/ALLOC with value number `vn`, from the table
   built once per run (value numbers are instruction indices and are fixed
   during elimination); scanning every instruction per query was quadratic. *>
fn ir::Ref gvn_find_leaf(GvnElim* context, uint vn)
{
	if (vn == GVN_TOP || (usz)vn >= (usz)context.leaf_of_vn.len) return ir::NONE;
	return context.leaf_of_vn[(sz)vn];
}

struct GvnElim
{
	ir::Ir* graph;
	ir::Decl* decl;
	Cfg* cfg;
	uint[] value_numbers;
	bool[] numbered;
	ir::Ref[] replacements;
	bool[] remove;
	ir::Ref[] leaf_of_vn;
	HashMap{uint, ir::Ref} available;
	list::List{uint} inserted;
}

fn bool gvn_ref_dominates_phi(GvnElim* context, ir::Ref leader, ir::Ref phi)
{
	if ((usz)leader >= (usz)context.decl.instructions.len || (usz)phi >= (usz)context.decl.instructions.len) return false;
	if (gvn_is_global_leaf(context.decl.instructions[(sz)leader])) return true;
	uint leader_block = context.cfg.block_of_ref[(sz)leader];
	uint phi_block = context.cfg.block_of_ref[(sz)phi];
	if (leader_block == NONE_BLOCK || phi_block == NONE_BLOCK) return false;
	if (leader_block != phi_block) return context.cfg.dominates(leader_block, phi_block);
	if (context.decl.instructions[(sz)leader].tag != ir::InstTag.PHI) return false;
	CfgBlock* block = &context.cfg.blocks[(sz)phi_block];
	for (sz pos = block.start + 1; pos < block.end; pos++)
	{
		if (context.decl.body[pos] == phi) return false;
		if (context.decl.body[pos] == leader) return true;
	}
	return false;
}

fn ir::Ref gvn_phi_leader(GvnElim* context, ir::Inst phi, ir::Ref phi_ref)
{
	uint vn = context.value_numbers[(sz)phi_ref];
	ir::Ref leaf = gvn_find_leaf(context, vn);
	if (leaf != ir::NONE) return leaf;
	foreach (input : phi.data.phi)
	{
		if (input.value == phi_ref || gvn_resolve(context.replacements, input.value) == phi_ref ||
			(usz)input.value >= (usz)context.value_numbers.len ||
			context.value_numbers[(sz)input.value] != vn) continue;
		ir::Ref leader = gvn_resolve(context.replacements, input.value);
		if (leader != phi_ref && gvn_ref_dominates_phi(context, leader, phi_ref)) return leader;
	}
	if (try leader = context.available.get(vn))
	{
		return leader;
	}
	return ir::NONE;
}

fn void gvn_eliminate_block(GvnElim* context, uint block_index)
{
	sz mark = context.inserted.len();
	CfgBlock* block = &context.cfg.blocks[(sz)block_index];
	sz end = block_executable_end(context.decl, block);
	for (sz pos = block.start + 1; pos < end; pos++)
	{
		ir::Ref ref = context.decl.body[pos];
		if ((usz)ref >= (usz)context.value_numbers.len || !context.numbered[(sz)ref]) continue;
		ir::Inst inst = context.decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.CONSTANT) continue;
		uint vn = context.value_numbers[(sz)ref];
		if (vn == GVN_TOP) continue;
		ir::Ref leader = ir::NONE;
		if (inst.tag == ir::InstTag.PHI) leader = gvn_phi_leader(context, inst, ref);
		if (leader == ir::NONE) leader = gvn_find_leaf(context, vn);
		if (leader == ir::NONE)
		{
			if (try previous = context.available.get(vn))
			{
				leader = previous;
			}
		}
		if (leader != ir::NONE && leader != ref)
		{
			context.replacements[(sz)ref] = leader;
			context.remove[(sz)ref] = true;
			continue;
		}
		context.available.set(vn, ref);
		context.inserted.push(vn);
	}
	foreach (child : block.dom_children) gvn_eliminate_block(context, child);
	while (context.inserted.len() > mark)
	{
		uint vn = context.inserted.pop()!!;
		context.available.remove(vn);
	}
}

<* Optimistic RPO GVN with per-root memory versions for nonescaping stack loads.
   Every store bumps its whole root version, even for a disjoint offset; this
   deliberately coarse rule is sound and leaves disjoint-slice precision to
   mem_opt. Calls honor the same validated nocapture/read/write summaries as
   mem_opt. Atomic and VA_START pointers are checked defensively. *>
fn bool gvn(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		foreach (inst : decl.instructions)
		{
			if (inst.tag == ir::InstTag.LABEL_ADDR || inst.tag == ir::InstTag.JMP_VAL) return false;
		}
		Uses* uses = analyses.get_uses();
		bool[] non_escaping = mem_compute_non_escaping(graph, decl, uses);
		defer if (non_escaping.len) alloc::free(mem, non_escaping.ptr);
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.rpo.len) return false;
		if (!cfg.idom.len) cfg.compute_dominators();
		usz count = decl.instructions.len;
		uint[] root_slot = alloc::new_array(mem, uint, (sz)count);
		defer if (count) alloc::free(mem, root_slot.ptr);
		for (usz i = 0; i < count; i++) root_slot[i] = NONE_BLOCK;
		ir::Ref[] roots = alloc::new_array(mem, ir::Ref, GVN_MAX_ROOTS);
		defer alloc::free(mem, roots.ptr);
		uint root_count = 0;
		foreach (i, inst : decl.instructions)
		{
			if (root_count == GVN_MAX_ROOTS) break;
			if (inst.tag != ir::InstTag.ALLOC || !non_escaping[i]) continue;
			root_slot[i] = root_count;
			roots[(sz)root_count++] = (ir::Ref)i;
		}
		usz memory_count = (usz)cfg.blocks.len * (usz)root_count;
		uint[] memory_in = alloc::new_array(mem, uint, (sz)memory_count);
		defer if (memory_count) alloc::free(mem, memory_in.ptr);
		uint[] memory_out = alloc::new_array(mem, uint, (sz)memory_count);
		defer if (memory_count) alloc::free(mem, memory_out.ptr);
		for (usz i = 0; i < memory_count; i++) { memory_in[i] = GVN_TOP; memory_out[i] = GVN_TOP; }
		uint[] value_numbers = alloc::new_array(mem, uint, (sz)count);
		defer if (count) alloc::free(mem, value_numbers.ptr);
		bool[] numbered = alloc::new_array(mem, bool, (sz)count);
		defer if (count) alloc::free(mem, numbered.ptr);
		for (usz i = 0; i < count; i++) { value_numbers[i] = GVN_TOP; numbered[i] = false; }
		GvnPass pass = { .graph = graph, .decl = decl, .cfg = cfg,
			.value_numbers = value_numbers, .numbered = numbered, .root_slot = root_slot,
			.roots = roots, .root_count = root_count, .memory_in = memory_in,
			.memory_out = memory_out };
		pass.values.init(mem);
		defer pass.values.free();
		bool converged = false;
		for (uint iteration = 0; iteration < GVN_MAX_PASSES; iteration++)
		{
			gvn_run_pass(&pass);
			if (!pass.changed) { converged = true; break; }
		}
		if (!converged)
		{
			// Cyclic value propagation exceeded the bounded optimistic budget. Reset
			// to unique instruction values and use conservative memory joins once.
			for (usz i = 0; i < count; i++)
			{
				value_numbers[i] = GVN_TOP;
				numbered[i] = false;
			}
			for (usz i = 0; i < memory_count; i++) { memory_in[i] = GVN_TOP; memory_out[i] = GVN_TOP; }
			pass.pessimistic = true;
			gvn_run_pass(&pass);
		}
		GvnElim elimination = { .graph = graph, .decl = decl, .cfg = cfg,
			.value_numbers = value_numbers, .numbered = numbered };
		elimination.available.init(mem);
		defer elimination.available.free();
		elimination.inserted.init(mem);
		defer elimination.inserted.free();
		elimination.replacements = alloc::new_array(mem, ir::Ref, (sz)count);
		defer if (count) alloc::free(mem, elimination.replacements.ptr);
		elimination.remove = alloc::new_array(mem, bool, (sz)count);
		defer if (count) alloc::free(mem, elimination.remove.ptr);
		elimination.leaf_of_vn = alloc::new_array(mem, ir::Ref, (sz)count);
		defer if (count) alloc::free(mem, elimination.leaf_of_vn.ptr);
		for (usz i = 0; i < count; i++) elimination.leaf_of_vn[i] = ir::NONE;
		for (usz i = 0; i < count; i++)
		{
			uint vn = value_numbers[i];
			if (vn == GVN_TOP || (usz)vn >= count || !gvn_is_global_leaf(decl.instructions[i])) continue;
			if (elimination.leaf_of_vn[(sz)vn] == ir::NONE) elimination.leaf_of_vn[(sz)vn] = (ir::Ref)i;
		}
		for (usz i = 0; i < count; i++)
		{
			elimination.replacements[i] = (ir::Ref)i;
			elimination.remove[i] = false;
			if (decl.instructions[i].tag == ir::InstTag.CONSTANT && value_numbers[i] != GVN_TOP)
			{
				elimination.replacements[i] = (ir::Ref)value_numbers[i];
			}
		}
		gvn_eliminate_block(&elimination, cfg.rpo[0]);
		DeclEditor editor;
		editor.begin(decl);
		bool changed = false;
		foreach (ref : editor.body) {
			if ((usz)ref >= (usz)count) continue;
			changed = changed || elimination.remove[(sz)ref];
			@each_value_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
			{
				ir::Ref resolved = gvn_resolve(elimination.replacements, *slot);
				if (resolved != *slot) changed = true;
				*slot = resolved;
			};
		}
		BodyRemovalContext removal = { .remove = elimination.remove };
		editor.remove_body_where(&body_ref_marked_for_removal, &removal);
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
