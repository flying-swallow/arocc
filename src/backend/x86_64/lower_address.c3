// Address matching and folded-use tracking for x86-64 lowering.
module aro::backend::x86_64;
import aro::backend::ir, aro::primitive_value, aro::value_interner;

struct AddrMode
{
	ir::Ref base;
	ir::Ref index;
	char scale;
	long disp;
	bool base_is_alloc;
	bool base_is_symbol;
}

fn bool Lowering.constant_i64(&self, ir::Ref ref, long* value)
{
	ir::Inst inst = self.inst(ref);
	if (inst.tag != CONSTANT || inst.ty != value_interner::REF_I64) return false;
	primitive_value::PrimitiveValue key = self.ir.interner.get(inst.data.constant);
	if ((key.tag != primitive_value::PrimitiveType.INT_POSITIVE && key.tag != primitive_value::PrimitiveType.INT_NEGATIVE) || !key.int_fits_64()) return false;
	*value = (long)key.int_low_u64();
	return true;
}

fn bool Lowering.address_scale(&self, ir::Ref ref, AddrMode* mode)
{
	ir::Inst inst = self.inst(ref);
	if (inst.tag == MUL)
	{
		long scale;
		if (!self.constant_i64(inst.data.bin.rhs, &scale)) return false;
		if (scale != 1 && scale != 2 && scale != 4 && scale != 8) return false;
		if (self.inst(inst.data.bin.lhs).ty != value_interner::REF_I64) return false;
		mode.index = inst.data.bin.lhs;
		mode.scale = (char)scale;
		return true;
	}
	if (inst.tag == BIT_SHL)
	{
		long shift;
		if (!self.constant_i64(inst.data.bin.rhs, &shift) || shift < 0 || shift > 3) return false;
		if (self.inst(inst.data.bin.lhs).ty != value_interner::REF_I64) return false;
		mode.index = inst.data.bin.lhs;
		mode.scale = (char)(1 << shift);
		return true;
	}
	if (inst.ty != value_interner::REF_I64) return false;
	mode.index = ref;
	mode.scale = 1;
	return true;
}

<* Match up to two pointer additions. The root pointer itself is not absorbed. *>
fn bool Lowering.match_address(&self, ir::Ref ptr, AddrMode* out)
{
	AddrMode mode = { .base = ptr, .index = ir::NONE, .scale = 1 };
	long disp = 0;
	ir::Ref cursor = ptr;
	bool found_index = false;
	for (uint depth = 0; depth < 2; depth++)
	{
		ir::Inst add = self.inst(cursor);
		if (add.tag != ADD || add.ty != value_interner::REF_PTR || self.inst(add.data.bin.lhs).ty != value_interner::REF_PTR || self.inst(add.data.bin.rhs).ty != value_interner::REF_I64) break;
		long offset;
		if (self.constant_i64(add.data.bin.rhs, &offset))
		{
			disp += offset;
			cursor = add.data.bin.lhs;
			continue;
		}
		if (found_index || !self.address_scale(add.data.bin.rhs, &mode)) break;
		found_index = true;
		mode.index = self.inst(add.data.bin.rhs).tag == MUL || self.inst(add.data.bin.rhs).tag == BIT_SHL ? mode.index : add.data.bin.rhs;
		cursor = add.data.bin.lhs;
	}
	mode.base = cursor;
	mode.disp = disp;
	ir::Inst base_inst = self.inst(cursor);
	if (base_inst.tag == ALLOC)
	{
		if (base_inst.data.alloc.is_volatile) return false;
		mode.base_is_alloc = true;
	}
	else if (base_inst.tag == SYMBOL)
	{
		mode.base_is_symbol = true;
		if (mode.index != ir::NONE || !self.is_defined(base_inst.data.label)) mode.base_is_symbol = false;
	}
	if (mode.disp < int::min || mode.disp > int::max) return false;
	if (mode.base == ptr && mode.index == ir::NONE && mode.disp == 0) return false;
	*out = mode;
	return true;
}

fn void Lowering.adjust_address_modes(&self)
{
	foreach (i, present : self.has_addr)
	{
		if (!present) continue;
		AddrMode mode = self.addr_of[i];
		if (!mode.base_is_alloc) continue;
		mode.disp -= self.areas[(sz)mode.base];
		self.addr_of[i] = mode;
	}
}

<* The operands match_address walks through when it passes `ref`: the pointer
   lhs, and a MUL/SHL rhs consumed as the scaled index. False if `ref` is not
   a walkable pointer ADD. *>
fn bool Lowering.address_pass_through(&self, ir::Ref ref, ir::Ref* lhs, ir::Ref* scaled)
{
	ir::Inst add = self.inst(ref);
	if (add.tag != ADD || add.ty != value_interner::REF_PTR || self.inst(add.data.bin.lhs).ty != value_interner::REF_PTR ||
		self.inst(add.data.bin.rhs).ty != value_interner::REF_I64) return false;
	*lhs = add.data.bin.lhs;
	*scaled = ir::NONE;
	long offset;
	if (self.constant_i64(add.data.bin.rhs, &offset)) return true;
	AddrMode scaled_mode;
	if (!self.address_scale(add.data.bin.rhs, &scaled_mode)) return false;
	ir::InstTag rhs_tag = self.inst(add.data.bin.rhs).tag;
	if (rhs_tag == MUL || rhs_tag == BIT_SHL) *scaled = add.data.bin.rhs;
	return true;
}

fn void Lowering.compute_address_folds(&self)
{
	usz count = self.decl.instructions.len;
	self.addr_of = alloc::new_array(&self.scratch, AddrMode, (sz)count);
	self.has_addr = alloc::new_array(&self.scratch, bool, (sz)count);
	self.folded_away = alloc::new_array(&self.scratch, bool, (sz)count);
	uint[] total_uses = alloc::new_array(&self.scratch, uint, (sz)count);
	uint[] absorbed_uses = alloc::new_array(&self.scratch, uint, (sz)count);
	uint[] block_of_ref = alloc::new_array(&self.scratch, uint, (sz)count);
	bool[] used_outside_block = alloc::new_array(&self.scratch, bool, (sz)count);
	for (usz i = 0; i < count; i++)
	{
		used_outside_block[i] = false;
		self.has_addr[i] = false;
		self.folded_away[i] = false;
		total_uses[i] = 0;
		absorbed_uses[i] = 0;
		block_of_ref[i] = uint::max;
	}
	uint block = 0;
	foreach (ref : self.decl.body)
	{
		if (self.inst(ref).tag == LABEL) block++;
		block_of_ref[(sz)ref] = block;
		ir::Inst inst = self.inst(ref);
		if (inst.tag == PHI)
		{
			foreach (input : inst.data.phi)
			{
				if ((usz)input.value >= count) continue;
				total_uses[(sz)input.value]++;
				used_outside_block[(sz)input.value] = true;
			}
		}
		else
		{
			@each_value_use(inst; ir::Ref used)
			{
				if ((usz)used < count)
				{
					total_uses[(sz)used]++;
					// A def later in body order (back edge) is unassigned here: also outside.
					if (block_of_ref[(sz)used] != block) used_outside_block[(sz)used] = true;
				}
			};
		}
	}
	foreach (ref : self.decl.body)
	{
		ir::Inst inst = self.inst(ref);
		ir::Ref ptr;
		if (inst.tag == ADD && inst.ty == value_interner::REF_PTR)
		{
			// A pointer ADD lowered as one LEA reads the matched base and index
			// directly, skipping the nested ADD/MUL it looks through. Record the
			// mode so @each_lowered_use reports those reads and the register
			// allocator keeps them live up to the LEA. The nested nodes are not
			// absorbed: they stay materialized for their other users.
			AddrMode lea_mode;
			if (self.match_address(ref, &lea_mode) && (lea_mode.index != ir::NONE || lea_mode.base_is_alloc))
			{
				self.addr_of[(sz)ref] = lea_mode;
				self.has_addr[(sz)ref] = true;
			}
			continue;
		}
		if (inst.tag == LOAD)
		{
			// Wide integers use a dedicated lowering path that reads the original
			// pointer twice and does not consume this address mode.
			if (self.is_wide_int(inst.ty)) continue;
			ptr = inst.data.ref;
		}
		else if (inst.tag == STORE)
		{
			if (self.is_wide_int(self.inst(inst.data.bin.rhs).ty)) continue;
			ptr = inst.data.bin.lhs;
		}
		else { continue; }
		if (inst.is_volatile_access()) continue;
		AddrMode mode;
		if (!self.match_address(ptr, &mode)) continue;
		self.addr_of[(sz)ref] = mode;
		self.has_addr[(sz)ref] = true;
		// This memory op's own use of its pointer is absorbed into the mode.
		// Uses one level further in belong to the pointer node and are only
		// absorbed if that node is folded away too (resolved below).
		if ((usz)ptr < count) absorbed_uses[(sz)ptr]++;
	}
	// A mode's base and index are read as values (match_address looks through
	// at most two nodes, so a base can itself be a pointer ADD): never fold
	// those away, or their slot or register is read without being written.
	bool[] mode_operand = alloc::new_array(&self.scratch, bool, (sz)count);
	for (usz i = 0; i < count; i++) mode_operand[i] = false;
	foreach (owner : self.decl.body)
	{
		if (!self.has_addr[(sz)owner]) continue;
		AddrMode mode = self.addr_of[(sz)owner];
		if (mode.base != ir::NONE && (usz)mode.base < count) mode_operand[(sz)mode.base] = true;
		if (mode.index != ir::NONE && (usz)mode.index < count) mode_operand[(sz)mode.index] = true;
	}
	// Fold a node away only when every real use of it disappears: uses by
	// memory ops through their pointer, or the pass-through uses of a node that
	// is itself folded. Folding a parent absorbs its uses of the nodes its mode
	// walk passes through, so iterate to a fixpoint. Each real use is counted
	// once; counting one per memory-op walk folded nodes still read elsewhere.
	bool progress = true;
	while (progress)
	{
		progress = false;
		for (usz pos = self.decl.body.len; pos > 0; pos--)
		{
			ir::Ref ref = self.decl.body[pos - 1];
			if ((usz)ref >= count || self.folded_away[(sz)ref]) continue;
			ir::Inst inst = self.inst(ref);
			if (inst.tag != ADD && inst.tag != MUL && inst.tag != BIT_SHL) continue;
			if (mode_operand[(sz)ref] || used_outside_block[(sz)ref]) continue;
			if (total_uses[(sz)ref] == 0 || absorbed_uses[(sz)ref] != total_uses[(sz)ref]) continue;
			self.folded_away[(sz)ref] = true;
			progress = true;
			ir::Ref lhs;
			ir::Ref scaled;
			if (self.address_pass_through(ref, &lhs, &scaled))
			{
				if ((usz)lhs < count) absorbed_uses[(sz)lhs]++;
				if (scaled != ir::NONE && (usz)scaled < count) absorbed_uses[(sz)scaled]++;
			}
		}
	}
	self.fold_dead_values();
	self.compute_compare_fusions(total_uses);
}

<* Pure integer operations nothing reads once lowered (`@each_lowered_use`,
   PHI inputs included) are not emitted: e.g. the scaled index MUL and pointer
   ADD whose address every LOAD/STORE re-forms in its own addressing mode.
   Folding one drops its operand uses, so repeat to a fixpoint. *>
fn void Lowering.fold_dead_values(&self)
{
	usz count = self.decl.instructions.len;
	uint[] lowered_uses = alloc::new_array(&self.scratch, uint, (sz)count);
	bool progress = true;
	while (progress)
	{
		progress = false;
		for (usz i = 0; i < count; i++) lowered_uses[i] = 0;
		foreach (ref : self.decl.body)
		{
			if ((usz)ref >= count) continue;
			ir::Inst inst = self.inst(ref);
			if (inst.tag == PHI)
			{
				foreach (input : inst.data.phi) if ((usz)input.value < count) lowered_uses[(sz)input.value]++;
				continue;
			}
			@each_lowered_use(self, inst, ref; ir::Ref used)
			{
				if ((usz)used < count) lowered_uses[(sz)used]++;
			};
		}
		foreach (ref : self.decl.body)
		{
			if ((usz)ref >= count || self.folded_away[(sz)ref] || lowered_uses[(sz)ref] != 0) continue;
			ir::Inst inst = self.inst(ref);
			// VSPLAT is the one pure vector op dropped: a constant shift count leaves it unused.
			if (inst.tag != VSPLAT && (!is_pure_integer_op(inst.tag) || self.is_wide_int(inst.ty) || self.is_float_type(inst.ty))) continue;
			self.folded_away[(sz)ref] = true;
			progress = true;
		}
	}
}

<* Integer operations without side effects or traps (no division). *>
fn bool is_pure_integer_op(ir::InstTag tag)
{
	switch (tag)
	{
		case ADD:
		case SUB:
		case MUL:
		case BIT_AND:
		case BIT_OR:
		case BIT_XOR:
		case BIT_SHL:
		case BIT_ASHR:
		case BIT_LSHR:
		case BIT_NOT:
		case NEGATE:
		case SEXT:
		case ZEXT:
		case TRUNC:
			return true;
		default:
			return false;
	}
}

macro @each_lowered_use(Lowering* self, ir::Inst inst, ir::Ref ref; @body(ir::Ref used))
{
	if (self.folded_away[(sz)ref]) {}
	else if (self.has_addr[(sz)ref])
	{
		AddrMode mode = self.addr_of[(sz)ref];
		if (mode.base != ir::NONE) @body(mode.base);
		if (mode.index != ir::NONE) @body(mode.index);
		if (inst.tag == STORE) @body(inst.data.bin.rhs);
	}
	else
	{
		// A vector shift by a constant count never reads its VSPLAT (see vector_shift_immediate).
		long shift_imm;
		bool skip_count = self.vector_shift_immediate(inst, &shift_imm) && inst.data.bin.lhs != inst.data.bin.rhs;
		@each_value_use(inst; ir::Ref value)
		{
			// A compare fused into this BRANCH/SELECT reads its operands here.
			if (skip_count && value == inst.data.bin.rhs) {}
			else if ((usz)value < self.folded_away.len && self.folded_away[(sz)value])
			{
				ir::Inst compare = self.inst(value);
				@body(compare.data.bin.lhs);
				@body(compare.data.bin.rhs);
			}
			else
			{
				@body(value);
			}
		};
	}
}

fn Operand? Lowering.address_operand(&self, ir::Ref ref, Register base_reg, Register index_reg, ushort bits)
{
	AddrMode mode;
	bool saved_mode = (usz)ref < self.has_addr.len && self.has_addr[(sz)ref];
	// Only modes recorded by compute_address_folds are used: the register
	// allocator sees their base/index reads through @each_lowered_use, while a
	// mode matched here on the fly would read values it may already have reused.
	bool matched = saved_mode;
	if (matched) mode = self.addr_of[(sz)ref];
	if (matched)
	{
		if (mode.base_is_symbol)
		{
			Operand symbol = symbol_mem_op(self.inst(mode.base).data.label, bits);
			symbol.mem.disp = (int)mode.disp;
			return symbol;
		}
		if (mode.base_is_alloc)
		{
			if (!saved_mode) mode.disp -= self.areas[(sz)mode.base];
			if (mode.index != ir::NONE)
			{
				Register index = self.address_reg(mode.index, index_reg)!;
				return sib_mem_op(RBP, index, mode.scale, (int)mode.disp, bits);
			}
			return mem_op(RBP, (int)mode.disp, bits);
		}
		// Allocated base/index registers are used in place.
		Register base = self.address_reg(mode.base, base_reg)!;
		if (mode.index != ir::NONE)
		{
			Register index = self.address_reg(mode.index, index_reg)!;
			return sib_mem_op(base, index, mode.scale, (int)mode.disp, bits);
		}
		return mem_op(base, (int)mode.disp, bits);
	}
	ir::Inst inst = self.inst(ref);
	ir::Ref ptr = inst.tag == LOAD ? inst.data.ref : inst.data.bin.lhs;
	Register base = self.address_reg(ptr, base_reg)!;
	return mem_op(base, 0, bits);
}
