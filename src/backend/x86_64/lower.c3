// IR -> x86_64 instruction lowering (C3 addition; arocc's Zig
// backend/Ir/x86/Renderer.zig is a stub that fails every function).
//
// Shape follows the Zig compiler's x86_64 backend: lowering produces a list of
// (mnemonic, operands) instructions that are checked against the ported
// `encodings.zon` table (`find`) and then emitted; see emit_text.c3. The same
// lowered rows are encoded into object bytes and relocations by emit_object.c3.
//
// Strategy (first milestone, correctness over speed):
// - scalar values use stack slots (8 bytes for integers/F32/F64, 16 for F80),
//   and every ALLOC owns an area of its size and alignment;
// - operands are loaded into scratch registers (rax, rcx, rdx, r11) at the
//   value's width, the operation runs, and the result is stored back;
// - PHIs are resolved by copies on each incoming edge (through a temporary
//   area so PHIs feeding each other on one edge stay correct);
// - calls use the SysV GP/SSE argument registers and 16-byte-aligned stack
//   slots for overflow arguments; incoming stack arguments start at 16(%rbp).
// - variadic functions using va_start allocate a SysV varargs register save area.
// F32/F64 values use XMM scratch registers; F80 values live in 16-byte stack
// slots and use the x87 stack. Remaining TODOs: F16/F128, i128.
module aro::backend::x86_64;
import aro::primitive_value;
import aro::backend::ir, aro::bitset, aro::value_interner, std::collections::list, std::core::dstring;

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
	uint align;
	bool is_float;
}

<* State for lowering the functions of one Ir. *>
struct Lowering
{
	ir::Ir* ir;
	ir::ErrorList* errors;
	<* Rodata strings of all functions; labels and bytes live in tmem of the caller's pool. *>
	List{RodataString} strings;
	uint float_constant_count;
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
	<* rbp displacement of the first byte in the SysV variadic register save area, or 0 if unused. *>
	int reg_save_area;
	<* Initial gp_offset for va_start, based on named GP arguments. *>
	uint gp_offset;
	<* Initial fp_offset for va_start, based on named SSE arguments. *>
	uint fp_offset;
	<* Incoming argument counters used to classify ordinal ARGs by ABI class. *>
	uint incoming_gp_arg_index;
	uint incoming_sse_arg_index;
	uint incoming_stack_arg_offset;
	<* Initial rbp displacement for va_start's overflow_arg_area. *>
	int overflow_arg_area_offset;
	<* 16-byte scratch area for x87 control words and discarded comparison values. *>
	int f80_scratch;
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
		case RET_PAIR:
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

<* Record `message` for the current function and fail, like Zig `Renderer.fail`. *>
fn void? Lowering.fail(&self, String format, args...) @format(1)
{
	self.errors.put(self.decl.name, string::format(self.errors.allocator, format, ...args));
	return ir::LOWER_FAIL~;
}

fn ir::Inst Lowering.inst(&self, ir::Ref ref) => self.decl.instructions[(sz)ref];

fn bool is_void_type(value_interner::InternerRef ty) => ty == value_interner::REF_VOID || ty == value_interner::REF_NORETURN;

fn bool Lowering.is_float_type(&self, value_interner::InternerRef ty)
{
	return self.ir.interner.get(ty).tag == primitive_value::PrimitiveType.FLOAT_TY;
}

fn bool Lowering.is_f80_type(&self, value_interner::InternerRef ty)
{
	primitive_value::PrimitiveValue key = self.ir.interner.get(ty);
	return key.tag == primitive_value::PrimitiveType.FLOAT_TY && key.ty_bits == 80;
}

fn uint Lowering.value_slot_bytes(&self, value_interner::InternerRef ty)
{
	if (self.is_f80_type(ty) || self.is_wide_int(ty)) return 16;
	return 8;
}

<* A 128-bit integer: kept in a 16-byte slot as little-endian lo/hi words, never in a register. *>
fn bool Lowering.is_wide_int(&self, value_interner::InternerRef ty)
{
	if (ty == value_interner::REF_PTR || is_void_type(ty)) return false;
	primitive_value::PrimitiveValue key = self.ir.interner.get(ty);
	return key.tag == primitive_value::PrimitiveType.INT_TY && key.ty_bits == 128;
}

fn ushort? Lowering.float_width(&self, value_interner::InternerRef ty)
{
	primitive_value::PrimitiveValue key = self.ir.interner.get(ty);
	if (key.tag != primitive_value::PrimitiveType.FLOAT_TY) return 0;
	switch (key.ty_bits)
	{
		case 32: return 32;
		case 64: return 64;
		case 16: self.fail("TODO: F16 floating point lowering")!;
		case 80: return 80;
		case 128: self.fail("TODO: F128 floating point lowering")!;
		default: self.fail("TODO: %d-bit floating point lowering", key.ty_bits)!;
	}
	unreachable();
}

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
		case FLOAT_TY: return self.float_width(ty)!;
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

fn Mnemonic Lowering.float_move_mnemonic(&self, ushort width) => width == 32 ? MOVSS : MOVSD;

fn String Lowering.intern_float_bytes(&self, char[] bytes, uint align)
{
	foreach (constant : self.strings)
	{
		if (!constant.is_float || constant.bytes.len != bytes.len) continue;
		bool equal = true;
		foreach (i, byte : bytes)
		{
			if (constant.bytes[i] != byte) { equal = false; break; }
		}
		if (equal) return constant.label;
	}
	String label = string::tformat(".L.flt.%d", self.float_constant_count++);
	self.strings.push({ .label = label, .bytes = bytes, .align = align, .is_float = true });
	return label;
}

fn String Lowering.float_bits_label(&self, ushort width, uint128 bits)
{
	uint byte_count = width == 80 ? 16 : (uint)(width / 8);
	char[] bytes = mem::temp_array(char, (sz)byte_count);
	for (uint i = 0; i < byte_count; i++) bytes[i] = 0;
	for (uint i = 0; i < width / 8; i++) bytes[i] = (char)(bits >> (i * 8));
	return self.intern_float_bytes(bytes, width == 80 ? 16 : width / 8);
}

fn String? Lowering.float_constant_label(&self, ir::Inst inst)
{
	ushort width = self.float_width(inst.ty)!;
	primitive_value::PrimitiveValue key = self.ir.interner.get(inst.data.constant);
	uint128 bits;
	if (inst.data.constant == value_interner::REF_ZERO)
	{
		bits = 0;
	}
	else if (inst.data.constant == value_interner::REF_ONE)
	{
		bits = width == 32 ? 0x3F80_0000 : width == 80 ? 0x3FFF_8000_0000_0000_0000 : 0x3FF0_0000_0000_0000;
	}
	else if (key.tag == primitive_value::PrimitiveType.F32 || key.tag == primitive_value::PrimitiveType.F64)
	{
		bits = key.float_bits();
	}
	else if (key.tag == primitive_value::PrimitiveType.F80)
	{
		bits = key.float_bits();
	}
	else
	{
		self.fail("TODO: unsupported floating point constant kind")!;
	}
	uint byte_count = width == 80 ? 16 : (uint)(width / 8);
	char[] bytes = mem::temp_array(char, (sz)byte_count);
	for (uint i = 0; i < byte_count; i++) bytes[i] = 0;
	for (uint i = 0; i < width / 8; i++) bytes[i] = (char)(bits >> (i * 8));
	return self.intern_float_bytes(bytes, width == 80 ? 16 : width / 8);
}

fn void? Lowering.load_float(&self, ir::Ref ref, Register xmm)
{
	ir::Inst inst = self.inst(ref);
	ushort width = self.float_width(inst.ty)!;
	Mnemonic mnemonic = self.float_move_mnemonic(width);
	if (inst.tag == CONSTANT)
	{
		String label = self.float_constant_label(inst)!;
		if (width == 80)
		{
			self.emit(FLD, label_mem_op(label, 80));
		}
		else
		{
			self.emit(mnemonic, reg_op(xmm), label_mem_op(label, width));
		}
		return;
	}
	if (!self.spill_all && self.value_in_reg[(sz)ref]) self.fail("floating point value was allocated to a GPR")!;
	if (width == 80)
	{
		self.emit(FLD, self.slot(ref, 80));
	}
	else
	{
		self.emit(mnemonic, reg_op(xmm), self.slot(ref, width));
	}
}

fn void? Lowering.load_x87_float(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ushort width = self.float_width(inst.ty)!;
	if (inst.tag == CONSTANT)
	{
		String label = self.float_constant_label(inst)!;
		self.emit(FLD, label_mem_op(label, width));
	}
	else
	{
		self.emit(FLD, self.slot(ref, width));
	}
}

fn void? Lowering.store_float(&self, ir::Ref ref, Register xmm)
{
	ushort width = self.float_width(self.inst(ref).ty)!;
	if (width == 80)
	{
		self.emit(FSTP, self.slot(ref, 80));
		int padding = -self.slots[(sz)ref] + 10;
		self.emit(MOV, mem_op(RBP, padding, 32), imm_op(0));
		self.emit(MOV, mem_op(RBP, padding + 4, 16), imm_op(0));
	}
	else
	{
		self.emit(self.float_move_mnemonic(width), self.slot(ref, width), reg_op(xmm));
	}
}

<* Load the value of `ref` into `reg` (any size; resized to the value's width). Returns that width. *>
fn ushort? Lowering.load(&self, ir::Ref ref, Register reg)
{
	ir::Inst inst = self.inst(ref);
	if (self.is_float_type(inst.ty))
	{
		self.float_width(inst.ty)!;
		self.fail("TODO: floating point value requested in a GPR")!;
	}
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
	if (self.is_float_type(inst.ty))
	{
		self.float_width(inst.ty)!;
		self.fail("TODO: floating point constant requested in a GPR")!;
	}
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
						.constant = inst.data.constant, .label = label, .bytes = key.bytes,
						.align = 1, .is_float = false
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
			self.fail("TODO: F16 floating point constants")!;
		case F32:
		case F64: self.fail("TODO: floating point constant requested in a GPR")!;
		case F80:
			self.fail("F80 constants must be loaded through the x87 stack")!;
		case F128: self.fail("TODO: F128 floating point constants")!;
		default: self.fail("TODO: constants of this kind")!;
	}
	unreachable();
}

<* Store `reg` (resized to the value's width) into `ref`'s slot. *>
fn void? Lowering.store(&self, ir::Ref ref, Register reg)
{
	if (self.is_float_type(self.inst(ref).ty))
	{
		self.float_width(self.inst(ref).ty)!;
		self.fail("TODO: floating point value stored from a GPR")!;
	}
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
	uint phi_bytes_in_block = 0;
	uint max_phi_bytes = 0;
	uint explicit_gp_count = 0;
	uint explicit_sse_count = 0;
	uint ordinal_gp_count = 0;
	uint ordinal_sse_count = 0;
	uint explicit_stack_end = 0;
	bool has_va_start = false;
	bool has_f80 = false;
	self.f80_scratch = 0;
	self.reg_save_area = 0;
	self.gp_offset = 0;
	self.fp_offset = 48;
	self.overflow_arg_area_offset = 16;
	foreach (usz body_index, ref : self.decl.body)
	{
		ir::Inst inst = self.inst(ref);
		if (self.is_f80_type(inst.ty)) has_f80 = true;
		switch (inst.tag)
		{
			case ARG:
				switch (inst.data.arg.location_kind)
				{
					case GP_REGISTER: explicit_gp_count++;
					case SSE_REGISTER: explicit_sse_count++;
					case STACK:
						uint stack_end = inst.data.arg.location + inst.data.arg.stack_size;
						if (stack_end > explicit_stack_end) explicit_stack_end = stack_end;
					case ORDINAL:
						if (self.is_f80_type(inst.ty))
						{
							// x87 long double is always memory-passed and consumes no register.
						}
						else if (self.is_float_type(inst.ty))
						{
							self.float_width(inst.ty)!;
							ordinal_sse_count++;
						}
						else
						{
							ordinal_gp_count++;
						}
				}
			case VA_START: has_va_start = true;
			case LABEL:
				self.labels[(sz)ref] = string::tformat(".L%s.%s.%d", self.decl.name, inst.data.label, (uint)ref);
				if (self.label_body_next[(sz)ref] == 0) self.label_body_next[(sz)ref] = body_index + 1;
				if (phi_bytes_in_block > max_phi_bytes) max_phi_bytes = phi_bytes_in_block;
				phi_bytes_in_block = 0;
				continue;
			case ALLOC:
				uint align = inst.data.alloc.align > 0 ? inst.data.alloc.align : 1;
				offset += (int)inst.data.alloc.size;
				offset = (int)(((uint)offset + align - 1) / align * align);
				self.areas[(sz)ref] = offset;
				continue;
			case PHI:
				phi_bytes_in_block += self.value_slot_bytes(inst.ty);
				if (phi_bytes_in_block > max_phi_bytes) max_phi_bytes = phi_bytes_in_block;
			default: break;
		}
		if (is_void_type(inst.ty)) continue;
		if (self.value_slot_bytes(inst.ty) == 16)
		{
			offset = (offset + 15) / 16 * 16 + 16;
		}
		else
		{
			offset = (offset + 7) / 8 * 8 + 8;
		}
		self.slots[(sz)ref] = offset;
	}
	if (phi_bytes_in_block > max_phi_bytes) max_phi_bytes = phi_bytes_in_block;
	offset += (int)max_phi_bytes;
	self.phi_area = offset;
	if (has_f80)
	{
		offset = (offset + 15) / 16 * 16 + 16;
		self.f80_scratch = offset;
	}
	uint named_gp_count = explicit_gp_count + ordinal_gp_count;
	uint gp_register_count = named_gp_count < (uint)SYSV_INT_PARAM_REGS.len ?
		named_gp_count : (uint)SYSV_INT_PARAM_REGS.len;
	self.gp_offset = gp_register_count * 8;
	uint named_sse_count = explicit_sse_count + ordinal_sse_count;
	uint sse_register_count = named_sse_count < (uint)SYSV_SSE_PARAM_REGS.len ?
		named_sse_count : (uint)SYSV_SSE_PARAM_REGS.len;
	self.fp_offset = 48 + sse_register_count * 16;
	// Compute the exact first unnamed stack byte in argument order. F80 values
	// are memory-class arguments with 16-byte slots and do not consume registers.
	uint ordinal_gp_index = explicit_gp_count;
	uint ordinal_sse_index = explicit_sse_count;
	uint overflow_bytes = explicit_stack_end;
	foreach (ref : self.decl.body)
	{
		ir::Inst inst = self.inst(ref);
		if (inst.tag != ARG || inst.data.arg.location_kind != ir::ArgLocationKind.ORDINAL) continue;
		if (self.is_f80_type(inst.ty))
		{
			overflow_bytes = (overflow_bytes + 15) / 16 * 16;
			overflow_bytes += 16;
		}
		else if (self.is_float_type(inst.ty))
		{
			if (ordinal_sse_index >= SYSV_SSE_PARAM_REGS.len) overflow_bytes += 8;
			ordinal_sse_index++;
		}
		else
		{
			if (ordinal_gp_index >= SYSV_INT_PARAM_REGS.len) overflow_bytes += 8;
			ordinal_gp_index++;
		}
	}
	self.overflow_arg_area_offset = 16 + (int)overflow_bytes;
	self.incoming_gp_arg_index = explicit_gp_count;
	self.incoming_sse_arg_index = explicit_sse_count;
	self.incoming_stack_arg_offset = explicit_stack_end;
	if (has_va_start)
	{
		// Keep the area base 16-byte aligned for MOVAPS. GP slots occupy bytes
		// 0..47; the eight 16-byte XMM slots follow at bytes 48..175.
		offset = (offset + 15) / 16 * 16;
		offset += 176;
		self.reg_save_area = offset;
	}
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
	bool[] candidates, uint[] live_index, bitset::BitMatrix block_defs, bitset::BitMatrix block_uses,
	uint[] starts, uint[] ends)
{
	if ((usz)ref >= candidates.len || !candidates[(sz)ref]) return;
	self.note_interval(ref, pos, candidates, starts, ends);
	uint index = live_index[(sz)ref];
	if (index == uint::max) return;
	if (!block_defs.row(block).get(index)) block_uses.row(block).set(index);
}

<* Run `body` for every operand `inst` reads as a value (not PHI inputs). *>
macro @each_value_use(ir::Inst inst; @body(ir::Ref used))
{
	switch (inst.tag)
	{
		case LOAD:
		case BIT_NOT:
		case NEGATE:
		case TRUNC:
		case ZEXT:
		case SEXT:
		case FNEG:
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
			@body(inst.data.ref);
		case ATOMIC_LOAD:
			@body(inst.data.atomic.ptr);
		case ATOMIC_STORE:
			@body(inst.data.atomic.ptr);
			@body(inst.data.atomic.val);
		case DYN_ALLOC:
			@body(inst.data.dyn_alloc.size);
		case RET:
			if (inst.data.ref != ir::NONE) @body(inst.data.ref);
		case RET_PAIR:
			@body(inst.data.bin.lhs);
			@body(inst.data.bin.rhs);
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
		case FCMP_OEQ:
		case FCMP_UNE:
		case FCMP_OLT:
		case FCMP_OLE:
		case FCMP_OGT:
		case FCMP_OGE:
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
			@body(inst.data.bin.lhs);
			@body(inst.data.bin.rhs);
		case BRANCH:
			@body(inst.data.branch.cond);
		case SELECT:
			@body(inst.data.branch.cond);
			@body(inst.data.branch.then_label);
			@body(inst.data.branch.else_label);
		case SWITCH:
			@body(inst.data.switch_data.target);
		case CALL:
			@body(inst.data.call.func);
			foreach (arg : inst.data.call.args) @body(arg);
		case CALL_HI:
			@body(inst.data.ref);
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
		case FENCE:
			break;
	}
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
	usz[] block_ends, ir::Ref[] block_labels, bitset::BitMatrix live_in, bitset::BitSet out,
	uint[] live_index)
{
	out.union_with(live_in.row(to));
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
			if (input.label == block_labels[(sz)from] && (usz)input.value < live_index.len && live_index[(sz)input.value] != uint::max)
			{
				out.set(live_index[(sz)input.value]);
			}
		}
	}
}

fn void Lowering.merge_live_target(&self, uint from, ir::Ref target, uint[] block_of_ref,
	usz[] block_starts, usz[] block_ends, ir::Ref[] block_labels, bitset::BitMatrix live_in,
	bitset::BitSet out, uint[] live_index)
{
	if ((usz)target >= block_of_ref.len) return;
	uint to = block_of_ref[(sz)target];
	if (to == uint::max) return;
	self.merge_live_edge(from, to, block_starts, block_ends, block_labels, live_in, out, live_index);
}

fn void Lowering.merge_block_successors(&self, uint block, uint block_count,
	uint[] block_of_ref, usz[] block_starts, usz[] block_ends, ir::Ref[] block_labels,
	bitset::BitMatrix live_in, bitset::BitSet out, uint[] live_index)
{
	usz term_pos = self.terminator_position(block_starts[(sz)block], block_ends[(sz)block]);
	if (term_pos == block_ends[(sz)block])
	{
		if (block + 1 < block_count)
		{
			self.merge_live_edge(block, block + 1, block_starts, block_ends, block_labels, live_in, out, live_index);
		}
		return;
	}
	ir::Inst term = self.inst(self.decl.body[term_pos]);
	switch (term.tag)
	{
		case JMP:
			self.merge_live_target(block, term.data.ref, block_of_ref, block_starts, block_ends, block_labels, live_in, out, live_index);
		case BRANCH:
			self.merge_live_target(block, term.data.branch.then_label, block_of_ref, block_starts, block_ends, block_labels, live_in, out, live_index);
			self.merge_live_target(block, term.data.branch.else_label, block_of_ref, block_starts, block_ends, block_labels, live_in, out, live_index);
		case SWITCH:
			foreach (target : term.data.switch_data.labels)
			{
				self.merge_live_target(block, target, block_of_ref, block_starts, block_ends, block_labels, live_in, out, live_index);
			}
			self.merge_live_target(block, term.data.switch_data.default_label, block_of_ref, block_starts, block_ends, block_labels, live_in, out, live_index);
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
			candidates[(sz)ref] = is_allocatable_value(inst) && !self.is_float_type(inst.ty) && !self.is_wide_int(inst.ty);
		}
		split_after = is_terminator(inst.tag);
	}
	block_ends[(sz)(block_count - 1)] = body_len;

	// Only values used outside their defining block (or feeding a PHI) can be
	// live across a block boundary; block-local values get no liveness bit.
	// Indexing bits by all refs made the four block x value matrices quadratic
	// (100k case labels: ~10 GB, gcc limits-caselabels.c).
	uint[] live_index = mem::temp_array(uint, (sz)count);
	for (usz ref = 0; ref < count; ref++) live_index[(sz)ref] = uint::max;
	uint live_count = 0;
	for (usz pos = 0; pos < body_len; pos++)
	{
		ir::Ref ref = self.decl.body[pos];
		if ((usz)ref >= count) continue;
		ir::Inst inst = self.inst(ref);
		uint block = block_of_ref[(sz)ref];
		if (inst.tag == PHI)
		{
			foreach (input : inst.data.phi)
			{
				if ((usz)input.value >= count || !candidates[(sz)input.value] || live_index[(sz)input.value] != uint::max) continue;
				live_index[(sz)input.value] = live_count++;
			}
			continue;
		}
		@each_value_use(inst; ir::Ref used)
		{
			if ((usz)used < count && candidates[(sz)used] && live_index[(sz)used] == uint::max &&
				block_of_ref[(sz)used] != block)
			{
				live_index[(sz)used] = live_count++;
			}
		};
	}
	ir::Ref[] live_refs = mem::temp_array(ir::Ref, (sz)live_count + 1);
	for (usz ref = 0; ref < count; ref++)
	{
		if (live_index[(sz)ref] != uint::max) live_refs[(sz)live_index[(sz)ref]] = (ir::Ref)ref;
	}

	bitset::BitMatrix block_defs = bitset::temp_matrix(block_count, live_count);
	bitset::BitMatrix block_uses = bitset::temp_matrix(block_count, live_count);
	bitset::BitMatrix live_in = bitset::temp_matrix(block_count, live_count);
	bitset::BitMatrix live_out = bitset::temp_matrix(block_count, live_count);

	// Build per-block use/def sets and initial interval endpoints.
	for (usz pos = 0; pos < body_len; pos++)
	{
		ir::Ref ref = self.decl.body[pos];
		if ((usz)ref >= count) continue;
		ir::Inst inst = self.inst(ref);
		uint block = block_of_ref[(sz)ref];
		uint at = (uint)pos;
		@each_value_use(inst; ir::Ref used)
		{
			self.mark_use(used, block, at, candidates, live_index, block_defs, block_uses, starts, ends);
		};
		if (candidates[(sz)ref])
		{
			if (live_index[(sz)ref] != uint::max) block_defs.row(block).set(live_index[(sz)ref]);
			self.note_interval(ref, at, candidates, starts, ends);
		}
	}

	// Solve live-in/live-out to a fixed point. PHI values are uses on their
	// matching predecessor edges, not uses in the target block.
	bitset::BitSet next_out = bitset::temp(live_count);
	bool changed = true;
	while (changed)
	{
		changed = false;
		for (uint reverse = 0; reverse < block_count; reverse++)
		{
			uint block = block_count - 1 - reverse;
			next_out.clear_all();
			self.merge_block_successors(block, block_count, block_of_ref, block_starts, block_ends,
				block_labels, live_in, next_out, live_index);
			if (live_out.row(block).assign(next_out)) changed = true;
			// live_in = uses | (live_out & ~defs)
			ulong[] uses = block_uses.row(block).words;
			ulong[] defs = block_defs.row(block).words;
			ulong[] ins = live_in.row(block).words;
			foreach (word, out_word : next_out.words)
			{
				ulong next_in = uses[word] | (out_word & ~defs[word]);
				if (ins[word] != next_in)
				{
					ins[word] = next_in; changed = true;
				}
			}
		}
	}

	// Extend each interval through every block where it is live, then cover
	// the edge copies that define PHIs and consume their incoming values.
	for (uint block = 0; block < block_count; block++)
	{
		if (block_ends[(sz)block] > block_starts[(sz)block])
		{
			uint block_start = (uint)block_starts[(sz)block];
			uint block_end = (uint)(block_ends[(sz)block] - 1);
			// Visit only the set bits; scanning every ref per block is
			// O(blocks * refs) on huge functions (gcc 20001226-1.c).
			next_out.assign(live_in.row(block));
			next_out.union_with(live_out.row(block));
			next_out.@each_set(; usz index)
			{
				ir::Ref value = live_refs[(sz)index];
				self.note_interval(value, block_start, candidates, starts, ends);
				self.note_interval(value, block_end, candidates, starts, ends);
			};
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
	uint phi_offset = 0;
	for (usz i = start; i < self.decl.body.len && self.inst(self.decl.body[i]).tag == PHI; i++)
	{
		ir::Ref phi = self.decl.body[i];
		foreach (input : self.inst(phi).data.phi)
		{
			if (input.label != self.current_label) continue;
			if (self.is_wide_int(self.inst(phi).ty))
			{
				int destination = -(self.phi_area - (int)phi_offset);
				self.load_pair(input.value, RAX, RDX)!;
				self.emit(MOV, mem_op(RBP, destination, 64), reg_op(RAX));
				self.emit(MOV, mem_op(RBP, destination + 8, 64), reg_op(RDX));
			}
			else if (self.is_f80_type(self.inst(phi).ty))
			{
				ir::Inst source = self.inst(input.value);
				if (source.tag == CONSTANT)
				{
					String label = self.float_constant_label(source)!;
					self.emit(LEA, reg_op(R11), label_mem_op(label));
				}
				else
				{
					self.emit(LEA, reg_op(R11), mem_op(RBP, -self.slots[(sz)input.value], 0));
				}
				int destination = -(self.phi_area - (int)phi_offset);
				self.emit(MOV, reg_op(RAX), mem_op(R11, 0, 64));
				self.emit(MOV, mem_op(RBP, destination, 64), reg_op(RAX));
				self.emit(MOV, reg_op(RAX), mem_op(R11, 8, 64));
				self.emit(MOV, mem_op(RBP, destination + 8, 64), reg_op(RAX));
			}
			else if (self.is_float_type(self.inst(phi).ty))
			{
				ushort w = self.float_width(self.inst(phi).ty)!;
				self.load_float(input.value, XMM0)!;
				self.emit(self.float_move_mnemonic(w),
					mem_op(RBP, -(self.phi_area - (int)phi_offset), w), reg_op(XMM0));
			}
			else
			{
				ushort w = self.load(input.value, RAX)!;
				self.emit(MOV, mem_op(RBP, -(self.phi_area - (int)phi_offset), w), reg_op(Register.RAX.to_bits(w)));
			}
			break;
		}
		phi_offset += self.value_slot_bytes(self.inst(phi).ty);
	}
	phi_offset = 0;
	for (usz i = start; i < self.decl.body.len && self.inst(self.decl.body[i]).tag == PHI; i++)
	{
		ir::Ref phi = self.decl.body[i];
		foreach (input : self.inst(phi).data.phi)
		{
			if (input.label != self.current_label) continue;
			if (self.value_slot_bytes(self.inst(phi).ty) == 16)
			{
				int source = -(self.phi_area - (int)phi_offset);
				int destination = -self.slots[(sz)phi];
				self.emit(MOV, reg_op(RAX), mem_op(RBP, source, 64));
				self.emit(MOV, mem_op(RBP, destination, 64), reg_op(RAX));
				self.emit(MOV, reg_op(RAX), mem_op(RBP, source + 8, 64));
				self.emit(MOV, mem_op(RBP, destination + 8, 64), reg_op(RAX));
			}
			else if (self.is_float_type(self.inst(phi).ty))
			{
				ushort w = self.float_width(self.inst(phi).ty)!;
				self.emit(self.float_move_mnemonic(w), reg_op(XMM0),
					mem_op(RBP, -(self.phi_area - (int)phi_offset), w));
				self.store_float(phi, XMM0)!;
			}
			else
			{
				ushort w = self.bits(self.inst(phi).ty)!;
				self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RBP, -(self.phi_area - (int)phi_offset), w));
				self.store(phi, RAX)!;
			}
			break;
		}
		phi_offset += self.value_slot_bytes(self.inst(phi).ty);
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

<* Apply one scalar SSE arithmetic operation using the matching F32/F64 mnemonic. *>
fn void? Lowering.float_alu(&self, ir::Ref ref, Mnemonic f32_mnemonic, Mnemonic f64_mnemonic)
{
	ir::Inst inst = self.inst(ref);
	ushort width = self.float_width(inst.ty)!;
	if (width == 80)
	{
		self.load_float(inst.data.bin.lhs, ST0)!;
		self.load_float(inst.data.bin.rhs, ST0)!;
		Mnemonic operation;
		switch (inst.tag)
		{
			case FADD: operation = FADDP;
			case FSUB: operation = FSUBP;
			case FMUL: operation = FMULP;
			case FDIV: operation = FDIVP;
			default: self.fail("invalid F80 arithmetic operation")!;
		}
		self.emit(operation, reg_op(ST1), reg_op(ST0));
		self.store_float(ref, ST0)!;
		return;
	}
	self.load_float(inst.data.bin.lhs, XMM0)!;
	self.load_float(inst.data.bin.rhs, XMM1)!;
	self.emit(width == 32 ? f32_mnemonic : f64_mnemonic, reg_op(XMM0), reg_op(XMM1));
	self.store_float(ref, XMM0)!;
}

<* Flip only the IEEE sign bit, preserving every other bit including NaN payloads. *>
fn void? Lowering.float_negate(&self, ir::Ref ref)
{
	ushort width = self.float_width(self.inst(ref).ty)!;
	if (width == 80)
	{
		self.load_float(self.inst(ref).data.ref, ST0)!;
		self.emit(FCHS);
		self.store_float(ref, ST0)!;
		return;
	}
	char[] mask = mem::temp_array(char, 16);
	for (uint i = 0; i < 16; i++) mask[i] = 0;
	mask[(sz)(width / 8 - 1)] = (char)0x80;
	String label = self.intern_float_bytes(mask, 16);
	self.load_float(self.inst(ref).data.ref, XMM0)!;
	self.emit(width == 32 ? XORPS : XORPD, reg_op(XMM0), label_mem_op(label, 128));
	self.store_float(ref, XMM0)!;
}

<*
 C comparisons are ordered except `!=`: UCOMI sets ZF/PF/CF for unordered, so
 equality and the less-than relations must also test parity, while greater-than
 and greater-or-equal already reject unordered via CF.
*>
fn void? Lowering.float_compare(&self, ir::Ref ref, Condition cc)
{
	ir::Inst inst = self.inst(ref);
	ushort width = self.float_width(self.inst(inst.data.bin.lhs).ty)!;
	if (width == 80)
	{
		self.load_float(inst.data.bin.rhs, ST0)!;
		self.load_float(inst.data.bin.lhs, ST0)!;
		self.emit(FUCOMIP, reg_op(ST0), reg_op(ST1));
		// FUCOMIP pops the left operand. Pop the remaining right operand without
		// changing the integer condition flags before SETcc consumes them.
		self.emit(FSTP, reg_op(ST0));
		self.emit(cc.set, reg_op(AL));
		switch (cc)
		{
			case E:
				self.emit(SETNP, reg_op(CL));
				self.emit(AND, reg_op(AL), reg_op(CL));
			case NE:
				self.emit(SETP, reg_op(CL));
				self.emit(OR, reg_op(AL), reg_op(CL));
			case B:
			case BE:
				self.emit(SETNP, reg_op(CL));
				self.emit(AND, reg_op(AL), reg_op(CL));
			default: break;
		}
		self.store(ref, RAX)!;
		return;
	}
	self.load_float(inst.data.bin.lhs, XMM0)!;
	self.load_float(inst.data.bin.rhs, XMM1)!;
	self.emit(width == 32 ? UCOMISS : UCOMISD, reg_op(XMM0), reg_op(XMM1));
	self.emit(cc.set, reg_op(AL));
	switch (cc)
	{
		case E:
			self.emit(SETNP, reg_op(CL));
			self.emit(AND, reg_op(AL), reg_op(CL));
		case NE:
			self.emit(SETP, reg_op(CL));
			self.emit(OR, reg_op(AL), reg_op(CL));
		case B:
			self.emit(SETNP, reg_op(CL));
			self.emit(AND, reg_op(AL), reg_op(CL));
		case BE:
			self.emit(SETNP, reg_op(CL));
			self.emit(AND, reg_op(AL), reg_op(CL));
		default: break;
	}
	self.store(ref, RAX)!;
}

<* Convert an integer to F80, including the full unsigned 64-bit range. *>
fn void? Lowering.int_to_f80(&self, ir::Ref ref, bool signed)
{
	ir::Inst inst = self.inst(ref);
	ushort source_width = self.bits(self.inst(inst.data.ref).ty)!;
	int slot_offset = -self.slots[(sz)ref];
	if (!signed && source_width == 64)
	{
		String direct = self.new_edge_label();
		String done = self.new_edge_label();
		self.load(inst.data.ref, RAX)!;
		self.emit(TEST, reg_op(RAX), reg_op(RAX));
		self.emit(JGE, target_op(direct));
		// Convert floor(x / 2) and add the low bit after doubling. This keeps
		// every uint64 exact with x87's 64-bit significand precision.
		self.emit(MOV, reg_op(RCX), reg_op(RAX));
		self.emit(AND, reg_op(EAX), imm_op(1));
		self.emit(MOV, mem_op(RBP, -self.f80_scratch + 8, 64), reg_op(RAX));
		self.emit(SHR, reg_op(RCX), imm_op(1));
		self.emit(MOV, mem_op(RBP, slot_offset, 64), reg_op(RCX));
		self.emit(FILD, mem_op(RBP, slot_offset, 64));
		self.emit(FLD, reg_op(ST0));
		self.emit(FADDP, reg_op(ST1), reg_op(ST0));
		self.emit(FILD, mem_op(RBP, -self.f80_scratch + 8, 64));
		self.emit(FADDP, reg_op(ST1), reg_op(ST0));
		self.emit(JMP, target_op(done));
		self.emit_label(direct);
		self.emit(MOV, mem_op(RBP, slot_offset, 64), reg_op(RAX));
		self.emit(FILD, mem_op(RBP, slot_offset, 64));
		self.emit_label(done);
	}
	else
	{
		self.load(inst.data.ref, RAX)!;
		if (signed && source_width < 64)
		{
			if (source_width < 32)
			{
				self.emit(MOVSX, reg_op(EAX), reg_op(Register.RAX.to_bits(source_width)));
			}
			self.emit(MOVSXD, reg_op(RAX), reg_op(EAX));
		}
		else if (!signed && source_width < 32)
		{
			self.emit(MOVZX, reg_op(EAX), reg_op(Register.RAX.to_bits(source_width)));
		}
		else if (!signed && source_width == 32)
		{
			self.emit(MOV, reg_op(EAX), reg_op(EAX));
		}
		self.emit(MOV, mem_op(RBP, slot_offset, 64), reg_op(RAX));
		self.emit(FILD, mem_op(RBP, slot_offset, 64));
	}
	self.store_float(ref, ST0)!;
}

fn void Lowering.x87_prepare_truncate(&self)
{
	int base = -self.f80_scratch;
	self.emit(FNSTCW, mem_op(RBP, base, 16));
	self.emit(MOV, reg_op(AX), mem_op(RBP, base, 16));
	self.emit(OR, reg_op(AX), imm_op(0x0C00));
	self.emit(MOV, mem_op(RBP, base + 2, 16), reg_op(AX));
	self.emit(FLDCW, mem_op(RBP, base + 2, 16));
}

fn void Lowering.x87_restore_control_word(&self)
{
	self.emit(FLDCW, mem_op(RBP, -self.f80_scratch, 16));
}

fn void? Lowering.f80_to_int(&self, ir::Ref ref, bool signed)
{
	ir::Inst inst = self.inst(ref);
	int scratch = -self.f80_scratch;
	if (!signed && self.bits(inst.ty)! == 64)
	{
		uint128 threshold_bits = 0x403E_8000_0000_0000_0000;
		String threshold = self.float_bits_label(80, threshold_bits);
		String direct = self.new_edge_label();
		String done = self.new_edge_label();
		self.emit(FLD, label_mem_op(threshold, 80));
		self.load_x87_float(inst.data.ref)!;
		self.emit(FUCOMIP, reg_op(ST0), reg_op(ST1));
		self.emit(FSTP, reg_op(ST0));
		self.emit(JB, target_op(direct));

		self.x87_prepare_truncate();
		self.load_x87_float(inst.data.ref)!;
		self.emit(FLD, label_mem_op(threshold, 80));
		self.emit(FSUBP, reg_op(ST1), reg_op(ST0));
		self.emit(FISTP, mem_op(RBP, scratch + 8, 64));
		self.x87_restore_control_word();
		self.emit(MOV, reg_op(RAX), mem_op(RBP, scratch + 8, 64));
		self.emit(MOV, reg_op(RCX), imm_op(1));
		self.emit(SHL, reg_op(RCX), imm_op(63));
		self.emit(OR, reg_op(RAX), reg_op(RCX));
		self.emit(JMP, target_op(done));

		self.emit_label(direct);
		self.x87_prepare_truncate();
		self.load_x87_float(inst.data.ref)!;
		self.emit(FISTP, mem_op(RBP, scratch + 8, 64));
		self.x87_restore_control_word();
		self.emit(MOV, reg_op(RAX), mem_op(RBP, scratch + 8, 64));
		self.emit_label(done);
	}
	else
	{
		self.x87_prepare_truncate();
		self.load_x87_float(inst.data.ref)!;
		self.emit(FISTP, mem_op(RBP, scratch + 8, 64));
		self.x87_restore_control_word();
		self.emit(MOV, reg_op(RAX), mem_op(RBP, scratch + 8, 64));
	}
	self.store(ref, RAX)!;
}

<* Convert an integer to F32/F64/F80, including the full unsigned 64-bit range. *>
fn void? Lowering.int_to_float(&self, ir::Ref ref, bool signed)
{
	ir::Inst inst = self.inst(ref);
	ushort width = self.float_width(inst.ty)!;
	if (width == 80)
	{
		self.int_to_f80(ref, signed)!;
		return;
	}
	ushort source_width = self.bits(self.inst(inst.data.ref).ty)!;
	Mnemonic convert = width == 32 ? CVTSI2SS : CVTSI2SD;
	Mnemonic add = width == 32 ? ADDSS : ADDSD;
	if (!signed && source_width == 64)
	{
		String direct = self.new_edge_label();
		String done = self.new_edge_label();
		self.load(inst.data.ref, RAX)!;
		self.emit(TEST, reg_op(RAX), reg_op(RAX));
		self.emit(JGE, target_op(direct));
		// Convert ceil(value / 2) as a signed integer, then double the result.
		// The low bit adjustment preserves round-to-nearest at halfway cases.
		self.emit(MOV, reg_op(RCX), reg_op(RAX));
		self.emit(AND, reg_op(EAX), imm_op(1));
		self.emit(SHR, reg_op(RCX), imm_op(1));
		self.emit(OR, reg_op(RCX), reg_op(RAX));
		self.emit(convert, reg_op(XMM0), reg_op(RCX));
		self.emit(add, reg_op(XMM0), reg_op(XMM0));
		self.emit(JMP, target_op(done));
		self.emit_label(direct);
		self.emit(convert, reg_op(XMM0), reg_op(RAX));
		self.emit_label(done);
	}
	else
	{
		ushort loaded = self.load_extended(inst.data.ref, RAX, signed)!;
		// CVTSI2S* interprets a 32-bit operand as signed. A uint32 therefore
		// uses the already-zero-extended 64-bit RAX form.
		Register source = !signed && source_width == 32 ? RAX : Register.RAX.to_bits(loaded);
		self.emit(convert, reg_op(XMM0), reg_op(source));
	}
	self.store_float(ref, XMM0)!;
}

<* Convert F32/F64 to an integer with C truncation semantics and full uint64 range. *>
fn void? Lowering.float_to_int(&self, ir::Ref ref, bool signed)
{
	ir::Inst inst = self.inst(ref);
	ushort source_width = self.float_width(self.inst(inst.data.ref).ty)!;
	if (source_width == 80)
	{
		self.f80_to_int(ref, signed)!;
		return;
	}
	ushort destination_width = self.bits(inst.ty)!;
	Mnemonic convert = source_width == 32 ? CVTTSS2SI : CVTTSD2SI;
	if (!signed && destination_width == 64)
	{
		uint128 threshold_bits = source_width == 32 ? 0x5F00_0000 : 0x43E0_0000_0000_0000;
		String threshold = self.float_bits_label(source_width, threshold_bits);
		String direct = self.new_edge_label();
		String done = self.new_edge_label();
		self.load_float(inst.data.ref, XMM0)!;
		self.emit(source_width == 32 ? UCOMISS : UCOMISD,
			reg_op(XMM0), label_mem_op(threshold, source_width));
		self.emit(JB, target_op(direct));
		self.emit(source_width == 32 ? SUBSS : SUBSD,
			reg_op(XMM0), label_mem_op(threshold, source_width));
		self.emit(convert, reg_op(RAX), reg_op(XMM0));
		self.emit(MOV, reg_op(RCX), imm_op(1));
		self.emit(SHL, reg_op(RCX), imm_op(63));
		self.emit(OR, reg_op(RAX), reg_op(RCX));
		self.emit(JMP, target_op(done));
		self.emit_label(direct);
		self.emit(convert, reg_op(RAX), reg_op(XMM0));
		self.emit_label(done);
	}
	else
	{
		self.load_float(inst.data.ref, XMM0)!;
		// Every supported narrow signed/unsigned destination fits the signed
		// 64-bit conversion instruction's range, then store() truncates it.
		self.emit(convert, reg_op(RAX), reg_op(XMM0));
	}
	self.store(ref, RAX)!;
}

<* Convert between the only directly supported scalar formats, F32 and F64. *>
fn void? Lowering.float_convert(&self, ir::Ref ref, bool extend)
{
	ir::Inst inst = self.inst(ref);
	ushort from = self.float_width(self.inst(inst.data.ref).ty)!;
	ushort to = self.float_width(inst.ty)!;
	if (from == 80 || to == 80)
	{
		if (extend && (to != 80 || (from != 32 && from != 64))) self.fail("FPEXT expects F32/F64 to F80")!;
		if (!extend && (from != 80 || (to != 32 && to != 64))) self.fail("FPTRUNC expects F80 to F32/F64")!;
		self.load_x87_float(inst.data.ref)!;
		self.emit(FSTP, self.slot(ref, to));
		if (to == 80)
		{
			int padding = -self.slots[(sz)ref] + 10;
			self.emit(MOV, mem_op(RBP, padding, 32), imm_op(0));
			self.emit(MOV, mem_op(RBP, padding + 4, 16), imm_op(0));
		}
		return;
	}
	if (extend && (from != 32 || to != 64)) self.fail("FPEXT expects F32 to F64")!;
	if (!extend && (from != 64 || to != 32)) self.fail("FPTRUNC expects F64 to F32")!;
	self.load_float(inst.data.ref, XMM0)!;
	self.emit(extend ? CVTSS2SD : CVTSD2SS, reg_op(XMM0), reg_op(XMM0));
	self.store_float(ref, XMM0)!;
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

fn bool Lowering.call_stack_only(&self, ir::Inst inst, usz index)
{
	if (index >= inst.data.call.stack_only.len) return false;
	return inst.data.call.stack_only[(sz)index];
}

fn uint Lowering.call_memory_copy_bytes(&self, ir::Inst inst, usz index)
{
	if (index >= inst.data.call.memory_copy_bytes.len) return 0;
	return inst.data.call.memory_copy_bytes[(sz)index];
}

<* Copy exactly size bytes from source into the outgoing stack argument area. *>
fn void? Lowering.copy_stack_argument(&self, ir::Ref source, uint destination, uint size)
{
	self.load(source, R11)!;
	self.copy_stack_argument_from(R11, destination, size);
}

fn void Lowering.copy_stack_argument_from(&self, Register source, uint destination, uint size)
{
	uint copied = 0;
	while (copied < size)
	{
		uint remaining = size - copied;
		ushort width = remaining >= 8 ? 64 : remaining >= 4 ? 32 : remaining >= 2 ? 16 : 8;
		self.emit(MOV, reg_op(Register.RAX.to_bits(width)), mem_op(source, (int)copied, width));
		self.emit(MOV, mem_op(RSP, (int)(destination + copied), width), reg_op(Register.RAX.to_bits(width)));
		copied += (uint)(width / 8);
	}
}

<* Copy a memory-class x87 argument into its 16-byte outgoing slot. *>
fn void? Lowering.copy_f80_argument(&self, ir::Ref source, uint destination)
{
	ir::Inst inst = self.inst(source);
	if (inst.tag == CONSTANT)
	{
		String label = self.float_constant_label(inst)!;
		self.emit(LEA, reg_op(R11), label_mem_op(label));
	}
	else
	{
		if (self.slots[(sz)source] == 0) self.fail("F80 argument has no memory-backed value slot")!;
		self.emit(LEA, reg_op(R11), mem_op(RBP, -self.slots[(sz)source], 0));
	}
	self.copy_stack_argument_from(R11, destination, 16);
}

fn void? Lowering.call(&self, ir::Ref ref, ir::Ref call_hi_ref = ir::NONE)
{
	ir::Inst inst = self.inst(ref);
	if (self.is_float_type(inst.ty))
	{
		self.float_width(inst.ty)!;
	}
	ir::Ref[] args = inst.data.call.args;
	uint stack_bytes = 0;
	uint gp_arg_count = 0;
	uint sse_arg_count = 0;
	foreach (i, arg : args)
	{
		uint copy_bytes = self.call_memory_copy_bytes(inst, (usz)i);
		// CodeGen passes __int128 as two i64 words, like a two-eightbyte INTEGER struct.
		if (self.is_wide_int(self.inst(arg).ty)) self.fail("TODO: unsplit 128-bit integer call argument")!;
		if (self.is_f80_type(self.inst(arg).ty))
		{
			stack_bytes = (stack_bytes + 15) / 16 * 16 + 16;
			continue;
		}
		if (copy_bytes > 0)
		{
			stack_bytes += (copy_bytes + 7) / 8 * 8;
			continue;
		}
		if (self.call_stack_only(inst, (usz)i))
		{
			stack_bytes += 8;
			continue;
		}
		if (self.is_float_type(self.inst(arg).ty))
		{
			self.float_width(self.inst(arg).ty)!;
			if (sse_arg_count >= SYSV_SSE_PARAM_REGS.len) stack_bytes += 8;
			sse_arg_count++;
		}
		else
		{
			if (gp_arg_count >= SYSV_INT_PARAM_REGS.len) stack_bytes += 8;
			gp_arg_count++;
		}
	}
	uint sse_register_count = sse_arg_count < (uint)SYSV_SSE_PARAM_REGS.len ?
		sse_arg_count : (uint)SYSV_SSE_PARAM_REGS.len;
	long stack_size = (long)((stack_bytes + SYSV_STACK_ALIGN - 1) / SYSV_STACK_ALIGN * SYSV_STACK_ALIGN);
	if (stack_size > 0) self.emit(SUB, reg_op(RSP), imm_op(stack_size));
	uint stack_offset = 0;
	gp_arg_count = 0;
	sse_arg_count = 0;
	foreach (i, arg : args)
	{
		uint copy_bytes = self.call_memory_copy_bytes(inst, (usz)i);
		if (self.is_f80_type(self.inst(arg).ty))
		{
			stack_offset = (stack_offset + 15) / 16 * 16;
			self.copy_f80_argument(arg, stack_offset)!;
			stack_offset += 16;
		}
		else if (copy_bytes > 0)
		{
			self.copy_stack_argument(arg, stack_offset, copy_bytes)!;
			stack_offset += (copy_bytes + 7) / 8 * 8;
		}
		else if (self.call_stack_only(inst, (usz)i))
		{
			if (self.is_float_type(self.inst(arg).ty))
			{
				ushort width = self.float_width(self.inst(arg).ty)!;
				self.load_float(arg, XMM0)!;
				self.emit(self.float_move_mnemonic(width), mem_op(RSP, (int)stack_offset, width), reg_op(XMM0));
			}
			else
			{
				self.load(arg, RAX)!;
				self.emit(MOV, mem_op(RSP, (int)stack_offset, 64), reg_op(RAX));
			}
			stack_offset += 8;
		}
		else if (self.is_float_type(self.inst(arg).ty))
		{
			self.float_width(self.inst(arg).ty)!;
			if (sse_arg_count >= SYSV_SSE_PARAM_REGS.len)
			{
				ushort width = self.float_width(self.inst(arg).ty)!;
				self.load_float(arg, XMM0)!;
				self.emit(self.float_move_mnemonic(width), mem_op(RSP, (int)stack_offset, width), reg_op(XMM0));
				stack_offset += 8;
			}
			sse_arg_count++;
		}
		else
		{
			if (gp_arg_count >= SYSV_INT_PARAM_REGS.len)
			{
				self.load(arg, RAX)!;
				self.emit(MOV, mem_op(RSP, (int)stack_offset, 64), reg_op(RAX));
				stack_offset += 8;
			}
			gp_arg_count++;
		}
	}
	uint gp_register_index = 0;
	uint sse_register_index = 0;
	foreach (i, arg : args)
	{
		if (self.is_f80_type(self.inst(arg).ty) || self.call_memory_copy_bytes(inst, (usz)i) > 0 || self.call_stack_only(inst, (usz)i)) continue;
		if (self.is_float_type(self.inst(arg).ty))
		{
			if (sse_register_index < SYSV_SSE_PARAM_REGS.len)
			{
				self.load_float(arg, SYSV_SSE_PARAM_REGS[sse_register_index])!;
			}
			sse_register_index++;
		}
		else
		{
			if (gp_register_index < SYSV_INT_PARAM_REGS.len)
			{
				self.load(arg, SYSV_INT_PARAM_REGS[gp_register_index])!;
			}
			gp_register_index++;
		}
	}
	ir::Inst callee = self.inst(inst.data.call.func);
	// SysV variadic callees use al as an upper bound on the vector registers used.
	self.emit(MOV, reg_op(EAX), imm_op((long)sse_register_count));
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
	if (stack_size > 0) self.emit(ADD, reg_op(RSP), imm_op(stack_size));
	if (!is_void_type(inst.ty))
	{
		if (self.is_float_type(inst.ty))
		{
			self.store_float(ref, SYSV_SSE_RETURN_REGS[0])!;
		}
		else if (self.is_wide_int(inst.ty))
		{
			// SysV returns __int128 in RDX:RAX.
			self.store_pair(ref, RAX, RDX)!;
		}
		else
		{
			self.store(ref, RAX)!;
		}
	}
	if (call_hi_ref != ir::NONE && self.inst(call_hi_ref).tag == CALL_HI && self.inst(call_hi_ref).data.ref == ref)
	{
		self.store(call_hi_ref, RDX)!;
	}
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
	if (self.is_float_type(self.inst(ref).ty))
	{
		self.load_float(select.then_label, XMM0)!;
		self.store_float(ref, XMM0)!;
	}
	else
	{
		self.load(select.then_label, RAX)!;
		self.store(ref, RAX)!;
	}
	self.emit(JMP, target_op(done_label));
	self.emit_label(else_label);
	if (self.is_float_type(self.inst(ref).ty))
	{
		self.load_float(select.else_label, XMM0)!;
		self.store_float(ref, XMM0)!;
	}
	else
	{
		self.load(select.else_label, RAX)!;
		self.store(ref, RAX)!;
	}
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

fn void Lowering.return_epilogue(&self)
{
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

fn void? Lowering.ret(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	if (inst.data.ref != ir::NONE && !is_void_type(self.inst(inst.data.ref).ty))
	{
		if (self.is_float_type(self.inst(inst.data.ref).ty))
		{
			self.load_float(inst.data.ref, SYSV_SSE_RETURN_REGS[0])!;
		}
		else if (self.is_wide_int(self.inst(inst.data.ref).ty))
		{
			self.load_pair(inst.data.ref, RAX, RDX)!;
		}
		else
		{
			self.load(inst.data.ref, RAX)!;
		}
	}
	self.return_epilogue();
}

fn void? Lowering.ret_pair(&self, ir::Ref ref)
{
	ir::BinData pair = self.inst(ref).data.bin;
	self.load(pair.rhs, RDX)!;
	self.load(pair.lhs, RAX)!;
	self.return_epilogue();
}

<* Save incoming SysV variadic argument registers into the layout used by va_list. *>
fn void Lowering.save_varargs(&self)
{
	if (self.reg_save_area == 0) return;
	String skip = self.new_edge_label();
	self.emit(TEST, reg_op(AL), reg_op(AL));
	self.emit(JE, target_op(skip));
	foreach (i, reg : SYSV_SSE_PARAM_REGS)
	{
		self.emit(MOVAPS, mem_op(RBP, -self.reg_save_area + 48 + (int)i * 16, 128), reg_op(reg));
	}
	self.emit_label(skip);
	foreach (i, reg : SYSV_INT_PARAM_REGS)
	{
		self.emit(MOV, mem_op(RBP, -self.reg_save_area + (int)i * 8, 64), reg_op(reg));
	}
}

<* Initialize the four fields of the SysV x86-64 va_list structure. *>
fn void? Lowering.va_start(&self, ir::Ref ref)
{
	if (self.reg_save_area == 0) self.fail("va_start has no register save area")!;
	self.load(self.inst(ref).data.ref, RCX)!;
	self.emit(MOV, mem_op(RCX, 0, 32), imm_op((long)self.gp_offset));
	self.emit(MOV, mem_op(RCX, 4, 32), imm_op((long)self.fp_offset));
	self.emit(LEA, reg_op(RAX), mem_op(RBP, self.overflow_arg_area_offset, 0));
	self.emit(MOV, mem_op(RCX, 8, 64), reg_op(RAX));
	self.emit(LEA, reg_op(RAX), mem_op(RBP, -self.reg_save_area, 0));
	self.emit(MOV, mem_op(RCX, 16, 64), reg_op(RAX));
}

fn void Lowering.copy_f80_into_slot(&self, ir::Ref destination, int source_offset)
{
	int target_offset = -self.slots[(sz)destination];
	self.emit(MOV, reg_op(RAX), mem_op(RBP, source_offset, 64));
	self.emit(MOV, mem_op(RBP, target_offset, 64), reg_op(RAX));
	self.emit(MOV, reg_op(RAX), mem_op(RBP, source_offset + 8, 64));
	self.emit(MOV, mem_op(RBP, target_offset + 8, 64), reg_op(RAX));
}

<* Lower one instruction of the body. *>
// ---------------------------------------------------------------------------
// 128-bit integers: each value lives in a 16-byte slot (lo word at the slot,
// hi word 8 bytes above) and is computed in register pairs, scratch only.
// ---------------------------------------------------------------------------

fn Operand Lowering.slot_hi(&self, ir::Ref ref) => mem_op(RBP, -self.slots[(sz)ref] + 8, 64);

<* Load 128-bit `ref` into `lo`:`hi`. *>
fn void? Lowering.load_pair(&self, ir::Ref ref, Register lo, Register hi)
{
	ir::Inst inst = self.inst(ref);
	if (!self.is_wide_int(inst.ty)) self.fail("128-bit operation on a narrower value")!;
	if (inst.tag == CONSTANT)
	{
		primitive_value::PrimitiveValue key = self.ir.interner.get(inst.data.constant);
		if (key.tag != primitive_value::PrimitiveType.INT_POSITIVE && key.tag != primitive_value::PrimitiveType.INT_NEGATIVE)
		{
			self.fail("TODO: 128-bit constants of this kind")!;
		}
		uint128 bits = key.int_low_u128();
		self.emit(MOV, reg_op(lo), imm_op((long)(ulong)bits));
		self.emit(MOV, reg_op(hi), imm_op((long)(ulong)(bits >> 64)));
		return;
	}
	self.emit(MOV, reg_op(lo), self.slot(ref, 64));
	self.emit(MOV, reg_op(hi), self.slot_hi(ref));
}

fn void? Lowering.store_pair(&self, ir::Ref ref, Register lo, Register hi)
{
	if (!self.is_wide_int(self.inst(ref).ty)) self.fail("128-bit result stored into a narrower value")!;
	self.emit(MOV, self.slot(ref, 64), reg_op(lo));
	self.emit(MOV, self.slot_hi(ref), reg_op(hi));
}

<* Load a (possibly narrower) integer operand into the 64-bit `reg`, zero- or sign-extended. *>
fn void? Lowering.load_extended_64(&self, ir::Ref ref, Register reg, bool signed)
{
	ushort from = self.load(ref, reg)!;
	if (from == 64) return;
	if (from == 32)
	{
		if (signed)
		{
			self.emit(MOVSXD, reg_op(reg), reg_op(reg.to_bits(32)));
		}
		else
		{
			self.emit(MOV, reg_op(reg.to_bits(32)), reg_op(reg.to_bits(32)));
		}
		return;
	}
	self.emit(signed ? MOVSX : MOVZX, reg_op(reg), reg_op(reg.to_bits(from)));
}

<* The low 64 bits of a shift count, whatever its width. *>
fn void? Lowering.load_shift_count(&self, ir::Ref ref)
{
	if (self.is_wide_int(self.inst(ref).ty))
	{
		self.load_pair(ref, RCX, R11)!;
		return;
	}
	self.load_extended_64(ref, RCX, false)!;
}

<* Whether `ref` reads or produces a 128-bit integer; such instructions are lowered here. *>
fn bool? Lowering.lower_wide_int(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	switch (inst.tag)
	{
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
			if (!self.is_wide_int(self.inst(inst.data.bin.lhs).ty)) return false;
			self.wide_compare(ref)!;
			return true;
		case STORE:
			if (!self.is_wide_int(self.inst(inst.data.bin.rhs).ty)) return false;
			self.load_pair(inst.data.bin.rhs, RAX, RDX)!;
			self.load(inst.data.bin.lhs, RCX)!;
			self.emit(MOV, mem_op(RCX, 0, 64), reg_op(RAX));
			self.emit(MOV, mem_op(RCX, 8, 64), reg_op(RDX));
			return true;
		case TRUNC:
			if (!self.is_wide_int(self.inst(inst.data.ref).ty)) return false;
			if (self.is_wide_int(inst.ty))
			{
				self.load_pair(inst.data.ref, RAX, RDX)!;
				self.store_pair(ref, RAX, RDX)!;
				return true;
			}
			self.load_pair(inst.data.ref, RAX, RDX)!;
			self.store(ref, RAX)!;
			return true;
		case ATOMIC_STORE:
			if (self.is_wide_int(self.inst(inst.data.atomic.val).ty)) self.fail("TODO: 128-bit atomic store")!;
			return false;
		case SWITCH:
			if (self.is_wide_int(self.inst(inst.data.switch_data.target).ty)) self.fail("TODO: switch on a 128-bit integer")!;
			return false;
		case SITOFP:
		case UITOFP:
			if (self.is_wide_int(self.inst(inst.data.ref).ty)) self.fail("TODO: 128-bit integer to floating point conversion")!;
			return false;
		case BIT_SHL:
		case BIT_LSHR:
		case BIT_ASHR:
			if (!self.is_wide_int(inst.ty)) return false;
			self.wide_shift(ref)!;
			return true;
		default:
			break;
	}
	if (!self.is_wide_int(inst.ty)) return false;
	switch (inst.tag)
	{
		case ADD:
		case SUB:
		case BIT_AND:
		case BIT_OR:
		case BIT_XOR:
			Mnemonic lo_op;
			Mnemonic hi_op;
			switch (inst.tag)
			{
				case ADD: lo_op = ADD; hi_op = ADC;
				case SUB: lo_op = SUB; hi_op = SBB;
				case BIT_AND: lo_op = AND; hi_op = AND;
				case BIT_OR: lo_op = OR; hi_op = OR;
				default: lo_op = XOR; hi_op = XOR;
			}
			self.load_pair(inst.data.bin.lhs, RAX, RDX)!;
			self.load_pair(inst.data.bin.rhs, RCX, R11)!;
			self.emit(lo_op, reg_op(RAX), reg_op(RCX));
			self.emit(hi_op, reg_op(RDX), reg_op(R11));
			self.store_pair(ref, RAX, RDX)!;
		case MUL:
			// (ah:al) * (bh:bl) mod 2^128 = al*bl + ((al*bh + ah*bl) << 64).
			self.load_pair(inst.data.bin.lhs, RAX, RDX)!;
			self.load_pair(inst.data.bin.rhs, RCX, R11)!;
			self.emit(IMUL, reg_op(RDX), reg_op(RCX));
			self.emit(IMUL, reg_op(R11), reg_op(RAX));
			self.emit(ADD, reg_op(R11), reg_op(RDX));
			self.emit(MUL, reg_op(RCX));
			self.emit(ADD, reg_op(RDX), reg_op(R11));
			self.store_pair(ref, RAX, RDX)!;
		case BIT_NOT:
			self.load_pair(inst.data.ref, RAX, RDX)!;
			self.emit(NOT, reg_op(RAX));
			self.emit(NOT, reg_op(RDX));
			self.store_pair(ref, RAX, RDX)!;
		case NEGATE:
			// -(hi:lo) = (-(hi + carry(lo != 0))):(-lo).
			self.load_pair(inst.data.ref, RAX, RDX)!;
			self.emit(NEG, reg_op(RAX));
			self.emit(ADC, reg_op(RDX), imm_op(0));
			self.emit(NEG, reg_op(RDX));
			self.store_pair(ref, RAX, RDX)!;
		case ZEXT:
		case SEXT:
			if (self.is_wide_int(self.inst(inst.data.ref).ty))
			{
				self.load_pair(inst.data.ref, RAX, RDX)!;
				self.store_pair(ref, RAX, RDX)!;
				return true;
			}
			bool signed = inst.tag == SEXT;
			self.load_extended_64(inst.data.ref, RAX, signed)!;
			if (signed)
			{
				self.emit(MOV, reg_op(RDX), reg_op(RAX));
				self.emit(SAR, reg_op(RDX), imm_op(63));
			}
			else
			{
				self.emit(XOR, reg_op(EDX), reg_op(EDX));
			}
			self.store_pair(ref, RAX, RDX)!;
		case LOAD:
			self.load(inst.data.ref, RCX)!;
			self.emit(MOV, reg_op(RAX), mem_op(RCX, 0, 64));
			self.emit(MOV, reg_op(RDX), mem_op(RCX, 8, 64));
			self.store_pair(ref, RAX, RDX)!;
		case SELECT:
			ir::BranchData select = inst.data.branch;
			self.load(select.cond, RAX)!;
			self.emit(TEST, reg_op(AL), reg_op(AL));
			String else_label = self.new_edge_label();
			String done_label = self.new_edge_label();
			self.emit(JE, target_op(else_label));
			self.load_pair(select.then_label, RAX, RDX)!;
			self.emit(JMP, target_op(done_label));
			self.emit_label(else_label);
			self.load_pair(select.else_label, RAX, RDX)!;
			self.emit_label(done_label);
			self.store_pair(ref, RAX, RDX)!;
		case CALL:
		case PHI:
		case CONSTANT:
			return false;
		case SDIV:
		case UDIV:
		case SREM:
		case UREM:
			self.fail("TODO: 128-bit integer division")!;
		case FPTOSI:
		case FPTOUI:
			self.fail("TODO: floating point to 128-bit integer conversion")!;
		default:
			self.fail("TODO: 128-bit integer %s", inst.tag.name)!;
	}
	return true;
}

<* Shift a 128-bit value by a count in [0, 127] held in CL. SHLD/SHRD and the
   single-word shifts use the count mod 64; bit 6 selects a whole-word move. *>
fn void? Lowering.wide_shift(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	self.load_shift_count(inst.data.bin.rhs)!;
	self.load_pair(inst.data.bin.lhs, RAX, RDX)!;
	String done_label = self.new_edge_label();
	switch (inst.tag)
	{
		case BIT_SHL:
			self.emit(SHLD, reg_op(RDX), reg_op(RAX), reg_op(CL));
			self.emit(SHL, reg_op(RAX), reg_op(CL));
			self.emit(TEST, reg_op(CL), imm_op(64));
			self.emit(JE, target_op(done_label));
			self.emit(MOV, reg_op(RDX), reg_op(RAX));
			self.emit(XOR, reg_op(EAX), reg_op(EAX));
		case BIT_LSHR:
			self.emit(SHRD, reg_op(RAX), reg_op(RDX), reg_op(CL));
			self.emit(SHR, reg_op(RDX), reg_op(CL));
			self.emit(TEST, reg_op(CL), imm_op(64));
			self.emit(JE, target_op(done_label));
			self.emit(MOV, reg_op(RAX), reg_op(RDX));
			self.emit(XOR, reg_op(EDX), reg_op(EDX));
		default:
			self.emit(SHRD, reg_op(RAX), reg_op(RDX), reg_op(CL));
			self.emit(SAR, reg_op(RDX), reg_op(CL));
			self.emit(TEST, reg_op(CL), imm_op(64));
			self.emit(JE, target_op(done_label));
			self.emit(MOV, reg_op(RAX), reg_op(RDX));
			self.emit(SAR, reg_op(RDX), imm_op(63));
	}
	self.emit_label(done_label);
	self.store_pair(ref, RAX, RDX)!;
}

<* Compare two 128-bit values. Ordered compares subtract with borrow (`cmp lo;
   sbb hi`), which sets SF/OF/CF like a full 128-bit compare; `>` and `<=` swap
   the operands so only the flags valid after SBB (L/GE/B/AE) are read. *>
fn void? Lowering.wide_compare(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::Ref lhs = inst.data.bin.lhs;
	ir::Ref rhs = inst.data.bin.rhs;
	if (inst.tag == CMP_EQ || inst.tag == CMP_NE)
	{
		self.load_pair(lhs, RAX, RDX)!;
		self.load_pair(rhs, RCX, R11)!;
		self.emit(XOR, reg_op(RAX), reg_op(RCX));
		self.emit(XOR, reg_op(RDX), reg_op(R11));
		self.emit(OR, reg_op(RAX), reg_op(RDX));
		self.emit(inst.tag == CMP_EQ ? Mnemonic.SETE : Mnemonic.SETNE, reg_op(AL));
		self.store(ref, RAX)!;
		return;
	}
	Condition cc;
	bool swap = false;
	switch (inst.tag)
	{
		case CMP_SLT: cc = L;
		case CMP_SGTE: cc = GE;
		case CMP_SGT: cc = L; swap = true;
		case CMP_SLTE: cc = GE; swap = true;
		case CMP_ULT: cc = B;
		case CMP_UGTE: cc = AE;
		case CMP_UGT: cc = B; swap = true;
		default: cc = AE; swap = true;
	}
	if (swap)
	{
		ir::Ref swapped = lhs;
		lhs = rhs;
		rhs = swapped;
	}
	self.load_pair(lhs, RAX, RDX)!;
	self.load_pair(rhs, RCX, R11)!;
	self.emit(CMP, reg_op(RAX), reg_op(RCX));
	self.emit(SBB, reg_op(RDX), reg_op(R11));
	self.emit(cc.set, reg_op(AL));
	self.store(ref, RAX)!;
}

fn void? Lowering.lower_inst(&self, ir::Ref ref, ir::Ref call_hi_ref = ir::NONE)
{
	if (self.lower_wide_int(ref)!) return;
	ir::Inst inst = self.inst(ref);
	switch (inst.tag)
	{
		case ARG:
			if (inst.data.arg.location_kind == ir::ArgLocationKind.SSE_REGISTER)
			{
				if (!self.is_float_type(inst.ty)) self.fail("SSE_REGISTER ARG requires a float type")!;
				if (self.is_f80_type(inst.ty)) self.fail("F80 arguments are passed in memory by the SysV ABI")!;
				self.float_width(inst.ty)!;
				if (inst.data.arg.location >= SYSV_SSE_PARAM_REGS.len) self.fail("ARG SSE register index %d is out of range", inst.data.arg.location)!;
				self.store_float(ref, SYSV_SSE_PARAM_REGS[inst.data.arg.location])!;
			}
			else if (inst.data.arg.location_kind == ir::ArgLocationKind.GP_REGISTER)
			{
				if (self.is_float_type(inst.ty)) self.fail("GP_REGISTER ARG cannot carry a float type")!;
				if (inst.data.arg.location >= SYSV_INT_PARAM_REGS.len) self.fail("ARG GP register index %d is out of range", inst.data.arg.location)!;
				self.store(ref, SYSV_INT_PARAM_REGS[inst.data.arg.location])!;
			}
			else if (inst.data.arg.location_kind == ir::ArgLocationKind.STACK)
			{
				int offset = 16 + (int)inst.data.arg.location;
				if (inst.data.arg.stack_address)
				{
					self.emit(LEA, reg_op(RAX), mem_op(RBP, offset, 0));
					self.store(ref, RAX)!;
				}
				else if (self.is_float_type(inst.ty))
				{
					ushort w = self.float_width(inst.ty)!;
					if (w == 80)
					{
						self.copy_f80_into_slot(ref, offset);
					}
					else
					{
						self.emit(self.float_move_mnemonic(w), reg_op(XMM0), mem_op(RBP, offset, w));
						self.store_float(ref, XMM0)!;
					}
				}
				else
				{
					ushort w = self.bits(inst.ty)!;
					self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RBP, offset, w));
					self.store(ref, RAX)!;
				}
			}
			else if (inst.data.arg.location_kind == ir::ArgLocationKind.ORDINAL)
			{
				if (self.is_f80_type(inst.ty))
				{
					self.incoming_stack_arg_offset = (self.incoming_stack_arg_offset + 15) / 16 * 16;
					int offset = 16 + (int)self.incoming_stack_arg_offset;
					self.copy_f80_into_slot(ref, offset);
					self.incoming_stack_arg_offset += 16;
				}
				else if (self.is_float_type(inst.ty))
				{
					ushort w = self.float_width(inst.ty)!;
					uint index = self.incoming_sse_arg_index++;
					if (index < SYSV_SSE_PARAM_REGS.len)
					{
						self.store_float(ref, SYSV_SSE_PARAM_REGS[index])!;
					}
					else
					{
						int offset = 16 + (int)self.incoming_stack_arg_offset;
						self.emit(self.float_move_mnemonic(w), reg_op(XMM0), mem_op(RBP, offset, w));
						self.store_float(ref, XMM0)!;
						self.incoming_stack_arg_offset += 8;
					}
				}
				else
				{
					uint index = self.incoming_gp_arg_index++;
					if (index < SYSV_INT_PARAM_REGS.len)
					{
						self.store(ref, SYSV_INT_PARAM_REGS[index])!;
					}
					else
					{
						ushort w = self.bits(inst.ty)!;
						int offset = 16 + (int)self.incoming_stack_arg_offset;
						self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RBP, offset, w));
						self.store(ref, RAX)!;
						self.incoming_stack_arg_offset += 8;
					}
				}
			}
			else
			{
				self.fail("invalid ARG location kind")!;
			}
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
		case RET_PAIR: self.ret_pair(ref)!;
		case CALL: self.call(ref, call_hi_ref)!;
		case CALL_HI: break;
		case VA_START: self.va_start(ref)!;
		case STORE:
			if (self.is_float_type(self.inst(inst.data.bin.rhs).ty))
			{
				ushort w = self.float_width(self.inst(inst.data.bin.rhs).ty)!;
				self.load(inst.data.bin.lhs, RCX)!;
				if (w == 80)
				{
					self.load_float(inst.data.bin.rhs, ST0)!;
					self.emit(FSTP, mem_op(RCX, 0, 80));
				}
				else
				{
					self.load_float(inst.data.bin.rhs, XMM0)!;
					self.emit(self.float_move_mnemonic(w), mem_op(RCX, 0, w), reg_op(XMM0));
				}
				break;
			}
			ushort w = self.load(inst.data.bin.rhs, RAX)!;
			self.load(inst.data.bin.lhs, RCX)!;
			self.emit(MOV, mem_op(RCX, 0, w), reg_op(Register.RAX.to_bits(w)));
		case LOAD:
			if (self.is_float_type(inst.ty))
			{
				ushort w = self.float_width(inst.ty)!;
				self.load(inst.data.ref, RCX)!;
				if (w == 80)
				{
					self.emit(FLD, mem_op(RCX, 0, 80));
					self.store_float(ref, ST0)!;
				}
				else
				{
					self.emit(self.float_move_mnemonic(w), reg_op(XMM0), mem_op(RCX, 0, w));
					self.store_float(ref, XMM0)!;
				}
				break;
			}
			ushort w = self.bits(inst.ty)!;
			self.load(inst.data.ref, RCX)!;
			self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RCX, 0, w));
			self.store(ref, RAX)!;
		// x86-64 is TSO: every aligned load is an acquire load and every plain store
		// a release store, so only seq_cst stores and fences need a full barrier.
		case ATOMIC_LOAD:
			if (self.is_float_type(inst.ty)) self.fail("TODO: floating point atomic load")!;
			ushort w = self.bits(inst.ty)!;
			self.load(inst.data.atomic.ptr, RCX)!;
			self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RCX, 0, w));
			self.store(ref, RAX)!;
		case ATOMIC_STORE:
			if (self.is_float_type(self.inst(inst.data.atomic.val).ty)) self.fail("TODO: floating point atomic store")!;
			ushort w = self.load(inst.data.atomic.val, RAX)!;
			self.load(inst.data.atomic.ptr, RCX)!;
			// XCHG with a memory operand is implicitly locked: a full barrier.
			Mnemonic op = inst.data.atomic.order == ir::AtomicOrder.SEQ_CST ? Mnemonic.XCHG : Mnemonic.MOV;
			self.emit(op, mem_op(RCX, 0, w), reg_op(Register.RAX.to_bits(w)));
		case FENCE:
			if (inst.data.atomic.order == ir::AtomicOrder.SEQ_CST) self.emit(MFENCE);
		case CLZ:
		case CTZ:
			// CLZ/CTZ results have the operand's type; size from it, since a folded
			// constant operand may come back wider.
			ushort operand_bits = self.bits(inst.ty)!;
			self.load(inst.data.ref, RAX)!;
			ushort w = operand_bits;
			if (w < 32)
			{
				self.emit(MOVZX, reg_op(EAX), reg_op(Register.RAX.to_bits(w)));
				w = 32;
			}
			Register wide = Register.RAX.to_bits(w);
			if (inst.tag == CTZ)
			{
				self.emit(BSF, reg_op(wide), reg_op(wide));
			}
			else
			{
				// BSR yields the index of the highest set bit; clz = (bits - 1) - index.
				self.emit(BSR, reg_op(wide), reg_op(wide));
				// The index is below the (power-of-two) operand width, so XOR subtracts.
				self.emit(XOR, reg_op(wide), imm_op((long)operand_bits - 1));
			}
			self.store(ref, RAX)!;
		case ADD: self.alu(ref, ADD)!;
		case SUB: self.alu(ref, SUB)!;
		case MUL: self.alu(ref, IMUL)!;
		case FADD: self.float_alu(ref, ADDSS, ADDSD)!;
		case FSUB: self.float_alu(ref, SUBSS, SUBSD)!;
		case FMUL: self.float_alu(ref, MULSS, MULSD)!;
		case FDIV: self.float_alu(ref, DIVSS, DIVSD)!;
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
		case FCMP_OEQ: self.float_compare(ref, E)!;
		case FCMP_UNE: self.float_compare(ref, NE)!;
		case FCMP_OLT: self.float_compare(ref, B)!;
		case FCMP_OLE: self.float_compare(ref, BE)!;
		case FCMP_OGT: self.float_compare(ref, A)!;
		case FCMP_OGE: self.float_compare(ref, AE)!;
		case BIT_NOT:
		case NEGATE:
			ushort w = self.load(inst.data.ref, RAX)!;
			self.emit(inst.tag == BIT_NOT ? Mnemonic.NOT : Mnemonic.NEG, reg_op(Register.RAX.to_bits(w)));
			self.store(ref, RAX)!;
		case FNEG: self.float_negate(ref)!;
		case FPTOSI: self.float_to_int(ref, true)!;
		case FPTOUI: self.float_to_int(ref, false)!;
		case SITOFP: self.int_to_float(ref, true)!;
		case UITOFP: self.int_to_float(ref, false)!;
		case FPEXT: self.float_convert(ref, true)!;
		case FPTRUNC: self.float_convert(ref, false)!;
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
	self.save_varargs();
	foreach (usz body_index, ref : decl.body)
	{
		ir::Inst inst = self.inst(ref);
		ir::Ref call_hi_ref = ir::NONE;
		if (inst.tag == CALL && body_index + 1 < (usz)decl.body.len)
		{
			ir::Ref next_ref = decl.body[(sz)(body_index + 1)];
			ir::Inst next_inst = self.inst(next_ref);
			if (next_inst.tag == CALL_HI && next_inst.data.ref == ref) call_hi_ref = next_ref;
		}
		self.lower_inst(ref, call_hi_ref)!;
		switch (inst.tag)
		{
			case JMP:
			case BRANCH:
			case SWITCH:
			case RET:
			case RET_PAIR:
			case JMP_VAL: self.block_terminated = true;
			case LABEL: self.block_terminated = false;
			default: break;
		}
	}
}
