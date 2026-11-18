// IR -> x86_64 instruction lowering (C3 addition; arocc's Zig
// backend/Ir/x86/Renderer.zig is a stub that fails every function).
//
// Shape follows the Zig compiler's x86_64 backend: lowering produces a list of
// (mnemonic, operands) instructions that are checked against the ported
// `encodings.zon` table (`find`) and then emitted; see emit_text.c3. The same
// lowered rows are encoded into object bytes and relocations by emit_object.c3.
//
// Strategy (first milestone, correctness over speed):
// - every value-producing instruction owns an 8-byte stack slot below rbp, and
//   every ALLOC owns an area of its size and alignment;
// - operands are loaded into scratch registers (rax, rcx, rdx, r11) at the
//   value's width, the operation runs, and the result is stored back;
// - PHIs are resolved by copies on each incoming edge (through a temporary
//   area so PHIs feeding each other on one edge stay correct);
// - calls use the SysV integer argument registers (at most 6 arguments).
// Floating point, i128 and aggregates fail with a TODO, like the Zig Renderer.
module aro::backend::x86_64;
import aro::primitive_value;
import aro::backend::ir, aro::value_interner, std::collections::list, std::core::dstring;

<* One output line: an instruction or a label definition. *>
struct Line
{
	bool is_label;
	String label;
	Mnemonic mnemonic;
	Operand[3] ops;
	char op_count;
}

<* A string constant placed in .rodata. *>
struct RodataString
{
	value_interner::InternerRef constant;
	String label;
	char[] bytes;
}

<* State for lowering the functions of one Ir. *>
struct Lowering
{
	ir::Ir* ir;
	ir::ErrorList* errors;
	<* Rodata strings of all functions; labels and bytes live in tmem of the caller's pool. *>
	List{RodataString} strings;
	// Per-function state:
	ir::Decl* decl;
	List{Line} lines;
	<* rbp displacement (positive, meaning `rbp - x`) of each instruction's value slot; 0 = none. *>
	int[] slots;
	<* rbp displacement of each ALLOC's storage. *>
	int[] areas;
	<* Assembly label of each LABEL instruction. *>
	String[] labels;
	<* Body index just after each LABEL (where its PHIs start); 0 = not a body label. *>
	usz[] label_body_next;
	<* rbp displacement of the PHI copy area. *>
	int phi_area;
	int frame;
	<* Keep all values in their existing slots when requested by the caller. *>
	bool spill_all;
	<* Linear-scan allocation, indexed by instruction ref. *>
	Register[] value_regs;
	bool[] value_in_reg;
	<* Fixed frame slots for saving the callee-preserved registers we use. *>
	int[5] callee_save_slots;
	bool[5] used_callee_regs;
	uint edge_count;
	<* The LABEL that starts the block being lowered. *>
	ir::Ref current_label;
	<* The last lowered instruction ended the block (jmp, branch, switch or ret). *>
	bool block_terminated;
}

struct LiveInterval
{
	ir::Ref ref; uint start; uint end;
}

fn bool is_terminator(ir::InstTag tag)
{
	switch (tag)
	{
		case JMP:
		case BRANCH:
		case SWITCH:
		case RET:
		case JMP_VAL: return true;
		default: return false;
	}
}

fn bool is_allocatable_value(ir::Inst inst)
{
	if (is_void_type(inst.ty)) return false;
	switch (inst.tag)
	{
		// These values are materialized directly by load(), rather than by a
		// store() at a definition point.
		case CONSTANT:
		case SYMBOL:
		case ALLOC: return false;
		default: return true;
	}
}

fn bool bit_is_set(ulong[] bits, usz base, ir::Ref ref)
{
	uint id = (uint)ref;
	uint word = id >> 6;
	return (bits[base + (usz)word] & (1UL << (id & 63))) != 0;
}

fn void bit_set(ulong[] bits, usz base, ir::Ref ref)
{
	uint id = (uint)ref;
	uint word = id >> 6;
	bits[base + (usz)word] |= 1UL << (id & 63);
}

<* Record `message` for the current function and fail, like Zig `Renderer.fail`. *>
fn void? Lowering.fail(&self, String format, args...) @format(1)
{
	self.errors.put(self.decl.name, string::format(self.errors.allocator, format, ...args));
	return ir::LOWER_FAIL~;
}

fn ir::Inst Lowering.inst(&self, ir::Ref ref) => self.decl.instructions[(sz)ref];

fn bool is_void_type(value_interner::InternerRef ty) => ty == value_interner::REF_VOID || ty == value_interner::REF_NORETURN;

<* The operand width in bits (8, 16, 32 or 64) of a value of IR type `ty`. i1 is stored as a byte. *>
fn ushort? Lowering.bits(&self, value_interner::InternerRef ty)
{
	if (ty == value_interner::REF_PTR) return 64;
	primitive_value::PrimitiveValue key = self.ir.interner.get(ty);
	switch (key.tag)
	{
		case INT_TY:
			if (key.ty_bits <= 8) return 8;
			if (key.ty_bits <= 16) return 16;
			if (key.ty_bits <= 32) return 32;
			if (key.ty_bits <= 64) return 64;
			self.fail("TODO: %d-bit integers", key.ty_bits)!;
		case PTR_TY: return 64;
		case FLOAT_TY: self.fail("TODO: floating point lowering")!;
		default: self.fail("TODO: lowering values of aggregate type")!;
	}
	unreachable();
}

fn void Lowering.emit(&self, Mnemonic mnemonic, Operand a = {}, Operand b = {}, Operand c = {})
{
	Line line = { .mnemonic = mnemonic, .ops = { a, b, c } };
	foreach (op : line.ops)
	{
		if (op.kind != NONE) line.op_count++;
	}
	self.lines.push(line);
}

fn void Lowering.emit_label(&self, String label) => self.lines.push(
	{
		.is_label = true, .label = label
	}

);

fn Operand Lowering.slot(&self, ir::Ref ref, ushort bits) => mem_op(RBP, -self.slots[(sz)ref], bits);

fn String Lowering.new_edge_label(&self) => string::tformat(".L%s.edge.%d", self.decl.name, self.edge_count++);

<* Load the value of `ref` into `reg` (any size; resized to the value's width). Returns that width. *>
fn ushort? Lowering.load(&self, ir::Ref ref, Register reg)
{
	ir::Inst inst = self.inst(ref);
	switch (inst.tag)
	{
		case SYMBOL:
			if (self.is_defined(inst.data.label))
			{
				self.emit(LEA, reg_op(reg.to_bits(64)), symbol_mem_op(inst.data.label));
			}
			else
			{
				self.emit(MOV, reg_op(reg.to_bits(64)), got_symbol_mem_op(inst.data.label));
			}
			return 64;
		case ALLOC:
			self.emit(LEA, reg_op(reg.to_bits(64)), mem_op(RBP, -self.areas[(sz)ref], 0));
			return 64;
		case CONSTANT:
			return self.load_constant(inst, reg);
		default:
			ushort w = self.bits(inst.ty)!;
			if (!self.spill_all && self.value_in_reg[(sz)ref])
			{
				Register source = self.value_regs[(sz)ref].to_bits(w);
				if (source.enc != reg.enc) self.emit(MOV, reg_op(reg.to_bits(w)), reg_op(source));
			}
			else
			{
				self.emit(MOV, reg_op(reg.to_bits(w)), self.slot(ref, w));
			}
			return w;
	}
}

fn ushort? Lowering.load_constant(&self, ir::Inst inst, Register reg)
{
	primitive_value::PrimitiveValue key = self.ir.interner.get(inst.data.constant);
	switch (key.tag)
	{
		case NULL:
			self.emit(XOR, reg_op(reg.to_bits(32)), reg_op(reg.to_bits(32)));
			return 64;
		case BYTES:
			String label = "";
			foreach (str : self.strings)
			{
				if (str.constant == inst.data.constant)
				{
					label = str.label; break;
				}
			}
			if (label.len == 0)
			{
				label = string::tformat(".L.str.%d", self.strings.len());
				self.strings.push(
					{
						.constant = inst.data.constant, .label = label, .bytes = key.bytes
					}
				);
			}
			self.emit(LEA, reg_op(reg.to_bits(64)), label_mem_op(label));
			return 64;
		case INT_POSITIVE:
		case INT_NEGATIVE:
			ushort w = self.bits(inst.ty)!;
			if (!key.int_fits_64()) self.fail("TODO: big integer constants")!;
			long value = (long)key.int_low_u64();
			// Truncate to the operand width, keeping the signed reading the assembler expects.
			switch (w)
			{
			case 8: value = (long)(ichar)value;
			case 16: value = (long)(short)value;
			case 32: value = (long)(int)value;
			default: break;
		}
		self.emit(MOV, reg_op(reg.to_bits(w)), imm_op(value));
		return w;
		case F16:
		case F32:
		case F64:
		case F80:
		case F128: self.fail("TODO: floating point constants")!;
		default: self.fail("TODO: constants of this kind")!;
	}
	unreachable();
}

<* Store `reg` (resized to the value's width) into `ref`'s slot. *>
fn void? Lowering.store(&self, ir::Ref ref, Register reg)
{
	ushort w = self.bits(self.inst(ref).ty)!;
	if (!self.spill_all && self.value_in_reg[(sz)ref])
	{
		Register target = self.value_regs[(sz)ref].to_bits(w);
		if (target.enc != reg.enc) self.emit(MOV, reg_op(target), reg_op(reg.to_bits(w)));
	}
	else
	{
		self.emit(MOV, self.slot(ref, w), reg_op(reg.to_bits(w)));
	}
}

<* Assign value slots, ALLOC areas, the PHI copy area and labels; returns the frame size. *>
fn void? Lowering.layout(&self)
{
	sz count = self.decl.instructions.len;
	self.slots = mem::temp_array(int, count);
	self.areas = mem::temp_array(int, count);
	self.labels = mem::temp_array(String, count);
	self.label_body_next = mem::temp_array(usz, count);
	for (sz i = 0; i < count; i++) self.label_body_next[i] = 0;
	int offset = 0;
	uint phis_in_block = 0;
	uint max_phis = 0;
	foreach (usz body_index, ref : self.decl.body)
	{
		ir::Inst inst = self.inst(ref);
		switch (inst.tag)
		{
			case LABEL:
				self.labels[(sz)ref] = string::tformat(".L%s.%s.%d", self.decl.name, inst.data.label, (uint)ref);
				if (self.label_body_next[(sz)ref] == 0) self.label_body_next[(sz)ref] = body_index + 1;
				phis_in_block = 0;
				continue;
			case ALLOC:
				uint align = inst.data.alloc.align > 0 ? inst.data.alloc.align : 1;
				offset += (int)inst.data.alloc.size;
				offset = (int)(((uint)offset + align - 1) / align * align);
				self.areas[(sz)ref] = offset;
				continue;
			case PHI:
				phis_in_block++;
				if (phis_in_block > max_phis) max_phis = phis_in_block;
			default: break;
		}
		if (is_void_type(inst.ty)) continue;
		offset = (offset + 7) / 8 * 8 + 8;
		self.slots[(sz)ref] = offset;
	}
	offset += (int)max_phis * 8;
	self.phi_area = offset;
	self.frame = (offset + 15) / 16 * 16;
}

fn void Lowering.note_interval(&self, ir::Ref ref, uint pos, bool[] candidates,
	uint[] starts, uint[] ends)
{
	if ((usz)ref >= candidates.len || !candidates[(sz)ref]) return;
	if (starts[(sz)ref] == uint::max || pos < starts[(sz)ref]) starts[(sz)ref] = pos;
	if (pos > ends[(sz)ref]) ends[(sz)ref] = pos;
}

fn void Lowering.mark_use(&self, ir::Ref ref, uint block, uint pos,
	bool[] candidates, ulong[] block_defs, ulong[] block_uses, usz words,
	uint[] starts, uint[] ends)
{
	if ((usz)ref >= candidates.len || !candidates[(sz)ref]) return;
	usz base = (usz)block * words;
	if (!bit_is_set(block_defs, base, ref)) bit_set(block_uses, base, ref);
	self.note_interval(ref, pos, candidates, starts, ends);
}

fn usz Lowering.terminator_position(&self, usz start, usz end)
{
	for (usz pos = start; pos < end; pos++)
	{
		if (is_terminator(self.inst(self.decl.body[pos]).tag)) return pos;
	}
	return end;
}

fn void Lowering.merge_live_edge(&self, uint from, uint to, usz[] block_starts,
	usz[] block_ends, ir::Ref[] block_labels, ulong[] live_in, ulong[] out,
	usz words, bool[] candidates)
{
	usz target_base = (usz)to * words;
	for (usz word = 0; word < words; word++) out[word] |= live_in[target_base + word];
	if (block_labels[(sz)from] == ir::NONE) return;
	usz pos = block_starts[(sz)to];
	usz end = block_ends[(sz)to];
	while (pos < end && self.inst(self.decl.body[pos]).tag != LABEL) pos++;
	if (pos < end) pos++;
	while (pos < end && self.inst(self.decl.body[pos]).tag == PHI)
	{
		ir::Ref phi = self.decl.body[pos++];
		foreach (input : self.inst(phi).data.phi)
		{
			if (input.label == block_labels[(sz)from] && (usz)input.value < candidates.len && candidates[(sz)input.value])
			{
				uint value_id = (uint)input.value;
				uint word = value_id >> 6;
				out[(usz)word] |= 1UL << (value_id & 63);
			}
		}
	}
}

fn void Lowering.merge_live_target(&self, uint from, ir::Ref target, uint[] block_of_ref,
	usz[] block_starts, usz[] block_ends, ir::Ref[] block_labels, ulong[] live_in,
	ulong[] out, usz words, bool[] candidates)
{
	if ((usz)target >= block_of_ref.len) return;
	uint to = block_of_ref[(sz)target];
	if (to == uint::max) return;
	self.merge_live_edge(from, to, block_starts, block_ends, block_labels, live_in, out, words, candidates);
}

fn void Lowering.merge_block_successors(&self, uint block, uint block_count,
	uint[] block_of_ref, usz[] block_starts, usz[] block_ends, ir::Ref[] block_labels,
	ulong[] live_in, ulong[] out, usz words, bool[] candidates)
{
	usz term_pos = self.terminator_position(block_starts[(sz)block], block_ends[(sz)block]);
	if (term_pos == block_ends[(sz)block])
	{
		if (block + 1 < block_count)
		{
			self.merge_live_edge(block, block + 1, block_starts, block_ends, block_labels, live_in, out, words, candidates);
		}
		return;
	}
	ir::Inst term = self.inst(self.decl.body[term_pos]);
	switch (term.tag)
	{
		case JMP:
			self.merge_live_target(block, term.data.ref, block_of_ref, block_starts, block_ends, block_labels, live_in, out, words, candidates);
		case BRANCH:
			self.merge_live_target(block, term.data.branch.then_label, block_of_ref, block_starts, block_ends, block_labels, live_in, out, words, candidates);
			self.merge_live_target(block, term.data.branch.else_label, block_of_ref, block_starts, block_ends, block_labels, live_in, out, words, candidates);
		case SWITCH:
			foreach (target : term.data.switch_data.labels)
			{
				self.merge_live_target(block, target, block_of_ref, block_starts, block_ends, block_labels, live_in, out, words, candidates);
			}
			self.merge_live_target(block, term.data.switch_data.default_label, block_of_ref, block_starts, block_ends, block_labels, live_in, out, words, candidates);
		default: break;
	}
}

fn void Lowering.note_phi_edge_intervals(&self, uint from, uint to,
	usz[] block_starts, usz[] block_ends, ir::Ref[] block_labels,
	bool[] candidates, uint[] starts, uint[] ends)
{
	if (block_labels[(sz)from] == ir::NONE) return;
	usz term_pos = self.terminator_position(block_starts[(sz)from], block_ends[(sz)from]);
	uint edge_pos = (uint)(term_pos < block_ends[(sz)from]? term_pos: block_ends[(sz)from]);
	usz pos = block_starts[(sz)to];
	usz end = block_ends[(sz)to];
	while (pos < end && self.inst(self.decl.body[pos]).tag != LABEL) pos++;
	if (pos < end) pos++;
	while (pos < end && self.inst(self.decl.body[pos]).tag == PHI)
	{
		ir::Ref phi = self.decl.body[pos++];
		foreach (input : self.inst(phi).data.phi)
		{
			if (input.label != block_labels[(sz)from]) continue;
			self.note_interval(input.value, edge_pos, candidates, starts, ends);
			self.note_interval(phi, edge_pos, candidates, starts, ends);
			break;
		}
	}
}

fn void Lowering.note_block_phi_edges(&self, uint block, uint block_count,
	uint[] block_of_ref, usz[] block_starts, usz[] block_ends, ir::Ref[] block_labels,
	bool[] candidates, uint[] starts, uint[] ends)
{
	usz term_pos = self.terminator_position(block_starts[(sz)block], block_ends[(sz)block]);
	if (term_pos == block_ends[(sz)block])
	{
		if (block + 1 < block_count) self.note_phi_edge_intervals(block, block + 1, block_starts, block_ends, block_labels, candidates, starts, ends);
		return;
	}
	ir::Inst term = self.inst(self.decl.body[term_pos]);
	switch (term.tag)
	{
		case JMP:
			if ((usz)term.data.ref < block_of_ref.len && block_of_ref[(sz)term.data.ref] != uint::max)
			{
				self.note_phi_edge_intervals(block, block_of_ref[(sz)term.data.ref], block_starts, block_ends, block_labels, candidates, starts, ends);
			}
		case BRANCH:
			ir::Ref then_ref = term.data.branch.then_label;
			ir::Ref else_ref = term.data.branch.else_label;
			if ((usz)then_ref < block_of_ref.len && block_of_ref[(sz)then_ref] != uint::max)
			{
				self.note_phi_edge_intervals(block, block_of_ref[(sz)then_ref], block_starts, block_ends, block_labels, candidates, starts, ends);
			}
			if ((usz)else_ref < block_of_ref.len && block_of_ref[(sz)else_ref] != uint::max)
			{
				self.note_phi_edge_intervals(block, block_of_ref[(sz)else_ref], block_starts, block_ends, block_labels, candidates, starts, ends);
			}
		case SWITCH:
			foreach (target : term.data.switch_data.labels)
			{
				if ((usz)target < block_of_ref.len && block_of_ref[(sz)target] != uint::max)
				{
					self.note_phi_edge_intervals(block, block_of_ref[(sz)target], block_starts, block_ends, block_labels, candidates, starts, ends);
				}
			}
			ir::Ref default_ref = term.data.switch_data.default_label;
			if ((usz)default_ref < block_of_ref.len && block_of_ref[(sz)default_ref] != uint::max)
			{
				self.note_phi_edge_intervals(block, block_of_ref[(sz)default_ref], block_starts, block_ends, block_labels, candidates, starts, ends);
			}
		default: break;
	}
}

<* Allocate live values to the SysV callee-preserved registers; old slots are spills. *>
fn void Lowering.allocate(&self)
{
	usz count = self.decl.instructions.len;
	self.value_regs = mem::temp_array(Register, (sz)count);
	self.value_in_reg = mem::temp_array(bool, (sz)count);
	for (usz ref = 0; ref < count; ref++) self.value_in_reg[(sz)ref] = false;
	for (usz reg = 0; reg < SYSV_CALLEE_PRESERVED_REGS.len; reg++)
	{
		self.used_callee_regs[reg] = false;
		self.callee_save_slots[reg] = 0;
	}
	if (self.spill_all || self.decl.body.len == 0 || count == 0) return;

	bool[] candidates = mem::temp_array(bool, (sz)count);
	uint[] block_of_ref = mem::temp_array(uint, (sz)count);
	uint[] starts = mem::temp_array(uint, (sz)count);
	uint[] ends = mem::temp_array(uint, (sz)count);
	for (usz ref = 0; ref < count; ref++)
	{
		candidates[(sz)ref] = false;
		block_of_ref[(sz)ref] = uint::max;
		starts[(sz)ref] = uint::max;
		ends[(sz)ref] = 0;
	}

	usz body_len = self.decl.body.len;
	usz[] block_starts = mem::temp_array(usz, (sz)body_len);
	usz[] block_ends = mem::temp_array(usz, (sz)body_len);
	ir::Ref[] block_labels = mem::temp_array(ir::Ref, (sz)body_len);
	uint block_count = 0;
	bool split_after = false;
	for (usz pos = 0; pos < body_len; pos++)
	{
		ir::Ref ref = self.decl.body[pos];
		ir::Inst inst = self.inst(ref);
		bool split_here = block_count == 0 || split_after;
		if (!split_here && inst.tag == LABEL && block_labels[(sz)(block_count - 1)] != ir::NONE) split_here = true;
		if (split_here)
		{
			if (block_count > 0) block_ends[(sz)(block_count - 1)] = pos;
			block_starts[(sz)block_count] = pos;
			block_ends[(sz)block_count] = body_len;
			block_labels[(sz)block_count] = ir::NONE;
			block_count++;
		}
		uint block = block_count - 1;
		if (inst.tag == LABEL && block_labels[(sz)block] == ir::NONE) block_labels[(sz)block] = ref;
		if ((usz)ref < count)
		{
			block_of_ref[(sz)ref] = block;
			candidates[(sz)ref] = is_allocatable_value(inst);
		}
		split_after = is_terminator(inst.tag);
	}
	block_ends[(sz)(block_count - 1)] = body_len;

	usz words = ((usz)count + 63) / 64;
	usz matrix_words = (usz)block_count * words;
	ulong[] block_defs = mem::temp_array(ulong, (sz)matrix_words);
	ulong[] block_uses = mem::temp_array(ulong, (sz)matrix_words);
	ulong[] live_in = mem::temp_array(ulong, (sz)matrix_words);
	ulong[] live_out = mem::temp_array(ulong, (sz)matrix_words);
	for (usz i = 0; i < matrix_words; i++)
	{
		block_defs[i] = 0;
		block_uses[i] = 0;
		live_in[i] = 0;
		live_out[i] = 0;
	}

	// Build per-block use/def sets and initial interval endpoints.
	for (usz pos = 0; pos < body_len; pos++)
	{
		ir::Ref ref = self.decl.body[pos];
		if ((usz)ref >= count) continue;
		ir::Inst inst = self.inst(ref);
		uint block = block_of_ref[(sz)ref];
		uint at = (uint)pos;
		usz base = (usz)block * words;
		switch (inst.tag)
		{
			case LOAD:
			case BIT_NOT:
			case NEGATE:
			case TRUNC:
			case ZEXT:
			case SEXT:
			case STACK_RESTORE:
				self.mark_use(inst.data.ref, block, at, candidates, block_defs, block_uses, words, starts, ends);
			case DYN_ALLOC:
				self.mark_use(inst.data.dyn_alloc.size, block, at, candidates, block_defs, block_uses, words, starts, ends);
			case RET:
				if (inst.data.ref != ir::NONE) self.mark_use(inst.data.ref, block, at, candidates, block_defs, block_uses, words, starts, ends);
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
				self.mark_use(inst.data.bin.lhs, block, at, candidates, block_defs, block_uses, words, starts, ends);
				self.mark_use(inst.data.bin.rhs, block, at, candidates, block_defs, block_uses, words, starts, ends);
			case BRANCH:
				self.mark_use(inst.data.branch.cond, block, at, candidates, block_defs, block_uses, words, starts, ends);
			case SELECT:
				self.mark_use(inst.data.branch.cond, block, at, candidates, block_defs, block_uses, words, starts, ends);
				self.mark_use(inst.data.branch.then_label, block, at, candidates, block_defs, block_uses, words, starts, ends);
				self.mark_use(inst.data.branch.else_label, block, at, candidates, block_defs, block_uses, words, starts, ends);
			case SWITCH:
				self.mark_use(inst.data.switch_data.target, block, at, candidates, block_defs, block_uses, words, starts, ends);
			case CALL:
				self.mark_use(inst.data.call.func, block, at, candidates, block_defs, block_uses, words, starts, ends);
				foreach (arg : inst.data.call.args) self.mark_use(arg, block, at, candidates, block_defs, block_uses, words, starts, ends);
			case CONSTANT:
			case ARG:
			case SYMBOL:
			case LABEL:
			case LABEL_ADDR:
			case JMP:
			case JMP_VAL:
			case ALLOC:
			case PHI:
			case STACK_SAVE:
				break;
		}
		if (candidates[(sz)ref])
		{
			bit_set(block_defs, base, ref);
			self.note_interval(ref, at, candidates, starts, ends);
		}
	}

	// Solve live-in/live-out to a fixed point. PHI values are uses on their
	// matching predecessor edges, not uses in the target block.
	ulong[] next_out = mem::temp_array(ulong, (sz)words);
	bool changed = true;
	while (changed)
	{
		changed = false;
		for (uint reverse = 0; reverse < block_count; reverse++)
		{
			uint block = block_count - 1 - reverse;
			for (usz word = 0; word < words; word++) next_out[word] = 0;
			self.merge_block_successors(block, block_count, block_of_ref, block_starts, block_ends,
				block_labels, live_in, next_out, words, candidates);
			usz base = (usz)block * words;
			for (usz word = 0; word < words; word++)
			{
				ulong next_in = block_uses[base + word] | (next_out[word] & ~block_defs[base + word]);
				if (live_out[base + word] != next_out[word]){ live_out[base + word] = next_out[word]; changed = true;
				}
				if (live_in[base + word] != next_in)
				{
					live_in[base + word] = next_in; changed = true;
				}
			}
		}
	}

	// Extend each interval through every block where it is live, then cover
	// the edge copies that define PHIs and consume their incoming values.
	for (uint block = 0; block < block_count; block++)
	{
		usz base = (usz)block * words;
		if (block_ends[(sz)block] > block_starts[(sz)block])
		{
			uint block_start = (uint)block_starts[(sz)block];
			uint block_end = (uint)(block_ends[(sz)block] - 1);
			// Visit only the set bits; scanning every ref per block is
			// O(blocks * refs) on huge functions (gcc 20001226-1.c).
			for (usz word = 0; word < words; word++)
			{
				ulong live = live_in[base + word] | live_out[base + word];
				while (live)
				{
					usz ref = word * 64 + (usz)live.ctz();
					live &= live - 1;
					if (ref >= count || !candidates[ref]) continue;
					ir::Ref value = (ir::Ref)ref;
					self.note_interval(value, block_start, candidates, starts, ends);
					self.note_interval(value, block_end, candidates, starts, ends);
				}
			}
		}
		self.note_block_phi_edges(block, block_count, block_of_ref, block_starts, block_ends,
			block_labels, candidates, starts, ends);
	}

	// Bucket by start position and run linear scan in body order. Values evicted
	// from a register use their pre-existing stack slot for their entire interval.
	LiveInterval[] intervals = mem::temp_array(LiveInterval, (sz)count);
	usz[] start_heads = mem::temp_array(usz, (sz)(body_len + 1));
	usz[] next_interval = mem::temp_array(usz, (sz)count);
	usz[] sorted_intervals = mem::temp_array(usz, (sz)count);
	for (usz pos = 0; pos <= body_len; pos++) start_heads[pos] = usz::max;
	usz interval_count = 0;
	for (usz ref = 0; ref < count; ref++)
	{
		if (!candidates[ref] || starts[ref] == uint::max) continue;
		LiveInterval item = { .ref = (ir::Ref)ref, .start = starts[ref], .end = ends[ref] };
		intervals[interval_count] = item;
		usz bucket = (usz)item.start;
		next_interval[interval_count] = start_heads[bucket];
		start_heads[bucket] = interval_count;
		interval_count++;
	}
	usz sorted_count = 0;
	for (usz pos = 0; pos <= body_len; pos++)
	{
		for (usz index = start_heads[pos]; index != usz::max; index = next_interval[index])
		{
			sorted_intervals[sorted_count++] = index;
		}
	}
	ir::Ref[5] active = { ir::NONE, ir::NONE, ir::NONE, ir::NONE, ir::NONE };
	for (usz i = 0; i < sorted_count; i++)
	{
		LiveInterval current = intervals[sorted_intervals[i]];
		for (usz reg = 0; reg < active.len; reg++)
		{
			if (active[reg] != ir::NONE && ends[(sz)active[reg]] < current.start) active[reg] = ir::NONE;
		}
		usz free_reg = active.len;
		for (usz reg = 0; reg < active.len; reg++)
		{
			if (active[reg] == ir::NONE)
			{
				free_reg = reg; break;
			}
		}
		if (free_reg < active.len)
		{
			active[free_reg] = current.ref;
			self.value_in_reg[(sz)current.ref] = true;
			self.value_regs[(sz)current.ref] = SYSV_CALLEE_PRESERVED_REGS[free_reg];
			continue;
		}
		usz victim = 0;
		for (usz reg = 1; reg < active.len; reg++)
		{
			if (ends[(sz)active[reg]] > ends[(sz)active[victim]]) victim = reg;
		}
		if (ends[(sz)active[victim]] > current.end)
		{
			self.value_in_reg[(sz)active[victim]] = false;
			active[victim] = current.ref;
			self.value_in_reg[(sz)current.ref] = true;
			self.value_regs[(sz)current.ref] = SYSV_CALLEE_PRESERVED_REGS[victim];
		}
	}

	int offset = self.frame;
	for (usz reg = 0; reg < SYSV_CALLEE_PRESERVED_REGS.len; reg++)
	{
		bool used = false;
		for (usz ref = 0; ref < count; ref++)
		{
			if (self.value_in_reg[ref] && self.value_regs[ref] == SYSV_CALLEE_PRESERVED_REGS[reg]){ used = true; break;
			}
		}
		if (!used) continue;
		self.used_callee_regs[reg] = true;
		offset += 8;
		self.callee_save_slots[reg] = offset;
	}
	self.frame = (offset + 15) / 16 * 16;
}

<* Copy the PHI inputs of block `target` that come from the current block into the PHI slots. *>
fn void? Lowering.edge_copies(&self, ir::Ref target)
{
	// Find target's PHIs: the instructions right after its LABEL in body order.
	if ((usz)target >= self.label_body_next.len) return;
	usz start = self.label_body_next[(sz)target];
	if (start == 0) return;
	// Phase 1: inputs into the copy area. Phase 2: copy area into the PHI slots.
	uint n = 0;
	for (usz i = start; i < self.decl.body.len && self.inst(self.decl.body[i]).tag == PHI; i++)
	{
		ir::Ref phi = self.decl.body[i];
		foreach (input : self.inst(phi).data.phi)
		{
			if (input.label != self.current_label) continue;
			ushort w = self.load(input.value, RAX)!;
			self.emit(MOV, mem_op(RBP, -(self.phi_area - (int)n * 8), w), reg_op(Register.RAX.to_bits(w)));
			n++;
			break;
		}
	}
	n = 0;
	for (usz i = start; i < self.decl.body.len && self.inst(self.decl.body[i]).tag == PHI; i++)
	{
		ir::Ref phi = self.decl.body[i];
		foreach (input : self.inst(phi).data.phi)
		{
			if (input.label != self.current_label) continue;
			ushort w = self.bits(self.inst(phi).ty)!;
			self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RBP, -(self.phi_area - (int)n * 8), w));
			self.store(phi, RAX)!;
			n++;
			break;
		}
	}
}

<* Leave the current block for `target`: PHI copies, then the jump. *>
fn void? Lowering.jump_to(&self, ir::Ref target)
{
	self.edge_copies(target)!;
	self.emit(JMP, target_op(self.labels[(sz)target]));
}

fn bool Lowering.is_defined(&self, String name)
{
	foreach (&decl : self.ir.decls)
	{
		if (decl.name == name && decl.is_definition()) return true;
	}
	return false;
}

<* Lower a two-operand ALU instruction (add, sub, imul, and, or, xor). *>
fn void? Lowering.alu(&self, ir::Ref ref, Mnemonic mnemonic)
{
	ir::Inst inst = self.inst(ref);
	ushort w = self.load(inst.data.bin.lhs, RAX)!;
	self.load(inst.data.bin.rhs, RCX)!;
	// 8/16-bit operations run on the 32-bit registers (imul has no 8-bit
	// two-operand form); the low bits of the result are the same.
	ushort op_w = w < 32 ? 32 : w;
	self.emit(mnemonic, reg_op(Register.RAX.to_bits(op_w)), reg_op(Register.RCX.to_bits(op_w)));
	self.store(ref, RAX)!;
}

<* Load `ref` into `reg`, sign- or zero-extended to at least 32 bits. Returns the operation width. *>
fn ushort? Lowering.load_extended(&self, ir::Ref ref, Register reg, bool signed)
{
	ushort w = self.load(ref, reg)!;
	if (w >= 32) return w;
	self.emit(signed ? MOVSX : MOVZX, reg_op(reg.to_bits(32)), reg_op(reg.to_bits(w)));
	return 32;
}

fn void? Lowering.divide(&self, ir::Ref ref, bool signed, bool remainder)
{
	ir::Inst inst = self.inst(ref);
	ushort w = self.load_extended(inst.data.bin.lhs, RAX, signed)!;
	self.load_extended(inst.data.bin.rhs, RCX, signed)!;
	if (signed)
	{
		self.emit(w == 64 ? CQO : CDQ);
		self.emit(IDIV, reg_op(Register.RCX.to_bits(w)));
	}
	else
	{
		self.emit(XOR, reg_op(EDX), reg_op(EDX));
		self.emit(DIV, reg_op(Register.RCX.to_bits(w)));
	}
	self.store(ref, remainder ? RDX : RAX)!;
}

fn void? Lowering.shift(&self, ir::Ref ref, Mnemonic mnemonic, bool signed)
{
	ir::Inst inst = self.inst(ref);
	ushort w = self.load_extended(inst.data.bin.lhs, RAX, signed)!;
	self.load(inst.data.bin.rhs, RCX)!;
	self.emit(mnemonic, reg_op(Register.RAX.to_bits(w)), reg_op(CL));
	self.store(ref, RAX)!;
}

fn void? Lowering.compare(&self, ir::Ref ref, Condition cc)
{
	ir::Inst inst = self.inst(ref);
	ushort w = self.load(inst.data.bin.lhs, RAX)!;
	self.load(inst.data.bin.rhs, RCX)!;
	self.emit(CMP, reg_op(Register.RAX.to_bits(w)), reg_op(Register.RCX.to_bits(w)));
	self.emit(cc.set, reg_op(AL));
	self.store(ref, RAX)!;
}

fn void? Lowering.extend(&self, ir::Ref ref, bool signed)
{
	ir::Inst inst = self.inst(ref);
	ushort from = self.load(inst.data.ref, RAX)!;
	ushort to = self.bits(inst.ty)!;
	if (from < to)
	{
		if (from == 32)
		{
			if (signed)
			{
				self.emit(MOVSXD, reg_op(RAX), reg_op(EAX));
			}
			else
			{
				self.emit(MOV, reg_op(EAX), reg_op(EAX));
			}
		}
		else
		{
			self.emit(signed ? MOVSX : MOVZX, reg_op(Register.RAX.to_bits(to < 32 ? 32 : to)), reg_op(Register.RAX.to_bits(from)));
		}
	}
	self.store(ref, RAX)!;
}

fn void? Lowering.call(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::Ref[] args = inst.data.call.args;
	if (args.len > SYSV_INT_PARAM_REGS.len) self.fail("TODO: calls with more than %d arguments", SYSV_INT_PARAM_REGS.len)!;
	foreach (i, arg : args) self.load(arg, SYSV_INT_PARAM_REGS[i])!;
	ir::Inst callee = self.inst(inst.data.call.func);
	// al = 0: no vector registers used, as variadic callees require.
	self.emit(XOR, reg_op(EAX), reg_op(EAX));
	if (callee.tag == SYMBOL)
	{
		String name = callee.data.label;
		self.emit(CALL, target_op(name, !self.is_defined(name)));
	}
	else
	{
		self.load(inst.data.call.func, R11)!;
		self.emit(CALL, reg_op(R11));
	}
	if (!is_void_type(inst.ty)) self.store(ref, RAX)!;
}

fn void? Lowering.branch(&self, ir::Ref ref)
{
	ir::BranchData b = self.inst(ref).data.branch;
	self.load(b.cond, RAX)!;
	self.emit(TEST, reg_op(AL), reg_op(AL));
	String else_edge = self.new_edge_label();
	self.emit(JE, target_op(else_edge));
	self.jump_to(b.then_label)!;
	self.emit_label(else_edge);
	self.jump_to(b.else_label)!;
}

fn void? Lowering.select(&self, ir::Ref ref)
{
	ir::BranchData select = self.inst(ref).data.branch;
	self.load(select.cond, RAX)!;
	self.emit(TEST, reg_op(AL), reg_op(AL));
	String else_label = self.new_edge_label();
	String done_label = self.new_edge_label();
	self.emit(JE, target_op(else_label));
	self.load(select.then_label, RAX)!;
	self.store(ref, RAX)!;
	self.emit(JMP, target_op(done_label));
	self.emit_label(else_label);
	self.load(select.else_label, RAX)!;
	self.store(ref, RAX)!;
	self.emit_label(done_label);
}

fn void? Lowering.switch_inst(&self, ir::Ref ref)
{
	ir::SwitchData s = self.inst(ref).data.switch_data;
	ushort w = self.load(s.target, RAX)!;
	foreach (i, value : s.values)
	{
		ir::Inst case_value = { .tag = CONSTANT, .data = { .constant = value }, .ty = self.inst(s.target).ty };
		self.load_constant(case_value, RCX)!;
		self.emit(CMP, reg_op(Register.RAX.to_bits(w)), reg_op(Register.RCX.to_bits(w)));
		String next = self.new_edge_label();
		self.emit(JNE, target_op(next));
		self.jump_to(s.labels[i])!;
		self.emit_label(next);
		// The case's copies clobber rax; reload the switch operand.
		if (i + 1 < s.values.len) self.load(s.target, RAX)!;
	}
	self.jump_to(s.default_label)!;
}

fn void? Lowering.ret(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	if (inst.data.ref != ir::NONE && !is_void_type(self.inst(inst.data.ref).ty)) self.load(inst.data.ref, RAX)!;
	if (!self.spill_all)
	{
		foreach (i, used : self.used_callee_regs)
		{
			if (used) self.emit(MOV, reg_op(SYSV_CALLEE_PRESERVED_REGS[i]), mem_op(RBP, -self.callee_save_slots[i], 64));
		}
	}
	self.emit(LEAVE);
	self.emit(RET);
}

<* Lower one instruction of the body. *>
fn void? Lowering.lower_inst(&self, ir::Ref ref, usz arg_index)
{
	ir::Inst inst = self.inst(ref);
	switch (inst.tag)
	{
		case ARG:
			if (arg_index >= SYSV_INT_PARAM_REGS.len) self.fail("TODO: functions with more than %d parameters", SYSV_INT_PARAM_REGS.len)!;
			self.store(ref, SYSV_INT_PARAM_REGS[arg_index])!;
		case LABEL:
			// A block can fall through into the next one without a jump: the
			// fallthrough edge still needs the next block's PHI copies.
			if (self.current_label != ir::NONE && !self.block_terminated) self.edge_copies(ref)!;
			self.current_label = ref;
			self.emit_label(self.labels[(sz)ref]);
		case ALLOC:
		case PHI: break;
		case CONSTANT:
		case SYMBOL: break;
		case JMP: self.jump_to(inst.data.ref)!;
		case BRANCH: self.branch(ref)!;
		case SWITCH: self.switch_inst(ref)!;
		case RET: self.ret(ref)!;
		case CALL: self.call(ref)!;
		case STORE:
			ushort w = self.load(inst.data.bin.rhs, RAX)!;
			self.load(inst.data.bin.lhs, RCX)!;
			self.emit(MOV, mem_op(RCX, 0, w), reg_op(Register.RAX.to_bits(w)));
		case LOAD:
			ushort w = self.bits(inst.ty)!;
			self.load(inst.data.ref, RCX)!;
			self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RCX, 0, w));
			self.store(ref, RAX)!;
		case ADD: self.alu(ref, ADD)!;
		case SUB: self.alu(ref, SUB)!;
		case MUL: self.alu(ref, IMUL)!;
		case BIT_AND: self.alu(ref, AND)!;
		case BIT_OR: self.alu(ref, OR)!;
		case BIT_XOR: self.alu(ref, XOR)!;
		case SDIV: self.divide(ref, true, false)!;
		case UDIV: self.divide(ref, false, false)!;
		case SREM: self.divide(ref, true, true)!;
		case UREM: self.divide(ref, false, true)!;
		case BIT_SHL: self.shift(ref, SHL, false)!;
		case BIT_ASHR: self.shift(ref, SAR, true)!;
		case BIT_LSHR: self.shift(ref, SHR, false)!;
		case CMP_EQ: self.compare(ref, E)!;
		case CMP_NE: self.compare(ref, NE)!;
		case CMP_SLT: self.compare(ref, L)!;
		case CMP_SLTE: self.compare(ref, LE)!;
		case CMP_SGT: self.compare(ref, G)!;
		case CMP_SGTE: self.compare(ref, GE)!;
		case CMP_ULT: self.compare(ref, B)!;
		case CMP_ULTE: self.compare(ref, BE)!;
		case CMP_UGT: self.compare(ref, A)!;
		case CMP_UGTE: self.compare(ref, AE)!;
		case BIT_NOT:
		case NEGATE:
			ushort w = self.load(inst.data.ref, RAX)!;
			self.emit(inst.tag == BIT_NOT ? Mnemonic.NOT : Mnemonic.NEG, reg_op(Register.RAX.to_bits(w)));
			self.store(ref, RAX)!;
		case TRUNC:
			self.load(inst.data.ref, RAX)!;
			self.store(ref, RAX)!;
		case ZEXT: self.extend(ref, false)!;
		case SEXT: self.extend(ref, true)!;
		case SELECT: self.select(ref)!;
		case DYN_ALLOC:
			// Every frame slot is rbp-relative and the epilogue is `leave`, so rsp may
			// move at runtime. Round to 16 bytes to keep calls aligned.
			long align = inst.data.dyn_alloc.align > 16 ? (long)inst.data.dyn_alloc.align : 16;
			self.load(inst.data.dyn_alloc.size, RAX)!;
			self.emit(ADD, reg_op(RAX), imm_op(align - 1));
			self.emit(AND, reg_op(RAX), imm_op(-align));
			self.emit(SUB, reg_op(RSP), reg_op(RAX));
			if (align > 16) self.emit(AND, reg_op(RSP), imm_op(-align));
			self.emit(MOV, reg_op(RAX), reg_op(RSP));
			self.store(ref, RAX)!;
		case STACK_SAVE:
			self.emit(MOV, reg_op(RAX), reg_op(RSP));
			self.store(ref, RAX)!;
		case STACK_RESTORE:
			self.load(inst.data.ref, RAX)!;
			self.emit(MOV, reg_op(RSP), reg_op(RAX));
		case LABEL_ADDR:
		case JMP_VAL: self.fail("TODO: lowering computed goto")!;
	}
}

<* Lower `decl` into `self.lines` (cleared first). Allocations use tmem. *>
fn void? Lowering.lower_decl(&self, ir::Decl* decl)
{
	self.decl = decl;
	self.lines.clear();
	self.edge_count = 0;
	self.current_label = ir::NONE;
	self.block_terminated = false;
	self.layout()!;
	self.allocate();
	self.emit(PUSH, reg_op(RBP));
	self.emit(MOV, reg_op(RBP), reg_op(RSP));
	if (self.frame > 0) self.emit(SUB, reg_op(RSP), imm_op(self.frame));
	if (!self.spill_all)
	{
		foreach (i, used : self.used_callee_regs)
		{
			if (used) self.emit(MOV, mem_op(RBP, -self.callee_save_slots[i], 64), reg_op(SYSV_CALLEE_PRESERVED_REGS[i]));
		}
	}
	usz arg_index = 0;
	foreach (ref : decl.body)
	{
		ir::Inst inst = self.inst(ref);
		self.lower_inst(ref, arg_index)!;
		if (inst.tag == ARG) arg_index++;
		switch (inst.tag)
		{
			case JMP:
			case BRANCH:
			case SWITCH:
			case RET:
			case JMP_VAL: self.block_terminated = true;
			case LABEL: self.block_terminated = false;
			default: break;
		}
	}
}
