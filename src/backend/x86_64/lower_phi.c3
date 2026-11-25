// PHI copies on a CFG edge as a parallel move: every PHI of the target block
// takes its input from the current block "at once". Instead of staging all
// inputs in a memory buffer, moves go straight from the input's location to the
// PHI's (register or slot); a move is emitted once no other pending move still
// reads its destination, and a cycle (`a, b = b, a`) is broken through a
// scratch register (R11 for integers, XMM1 for floats).
module aro::backend::x86_64;
import aro::backend::ir, aro::value_interner, std::collections::list;

enum PhiLocKind : char
{
	REG,
	SLOT,
	<* A constant, symbol or ALLOC: rematerialized, never a destination. *>
	VALUE,
	<* The cycle-breaking scratch register. *>
	SCRATCH,
}

struct PhiLoc
{
	PhiLocKind kind;
	Register reg;
	int offset;
	ir::Ref value;
}

struct PhiMove
{
	PhiLoc src;
	PhiLoc dst;
	<* Integer width in bits, or the float width when `is_float`. *>
	ushort width;
	bool is_float;
}

fn bool PhiLoc.same(self, PhiLoc other)
{
	if (self.kind != other.kind) return false;
	switch (self.kind)
	{
		case REG: return self.reg.enc == other.reg.enc && self.reg.class == other.reg.class;
		case SLOT: return self.offset == other.offset;
		case SCRATCH: return true;
		case VALUE: return self.value == other.value;
	}
}

<* Where the lowering keeps `ref`: register, slot, or a rematerializable value. *>
fn PhiLoc Lowering.phi_location(&self, ir::Ref ref)
{
	switch (self.inst(ref).tag)
	{
		case CONSTANT:
		case SYMBOL:
		case ALLOC:
			return { .kind = VALUE, .value = ref };
		default:
			break;
	}
	if (!self.spill_all && self.value_in_reg[(sz)ref]) return { .kind = REG, .reg = self.value_regs[(sz)ref], .value = ref };
	return { .kind = SLOT, .offset = -self.slots[(sz)ref], .value = ref };
}

<* PHIs of the block starting at body index `start` need the buffered copy:
   16-byte values (i128, f80) keep the memory path. *>
fn bool Lowering.phis_need_buffer(&self, usz start)
{
	for (usz i = start; i < self.decl.body.len && self.inst(self.decl.body[i]).tag == PHI; i++)
	{
		value_interner::InternerRef ty = self.inst(self.decl.body[i]).ty;
		// 128-bit vectors are plain XMM moves (MOVUPS/MOVAPS).
		if (self.value_slot_bytes(ty) == 16 && !self.ir.is_vector(ty)) return true;
	}
	return false;
}

<* The PHI copies for the edge from the current block to `target`. *>
fn void? Lowering.edge_copies(&self, ir::Ref target)
{
	// Find target's PHIs: the instructions right after its LABEL in body order.
	if ((usz)target >= self.label_body_next.len) return;
	usz start = self.label_body_next[(sz)target];
	if (start == 0) return;
	if (self.block_phi_area[(sz)target] != 0 || self.phis_need_buffer(start))
	{
		self.edge_copies_buffered(target, start)!;
		return;
	}
	List{PhiMove} moves;
	moves.init(tmem);
	for (usz i = start; i < self.decl.body.len && self.inst(self.decl.body[i]).tag == PHI; i++)
	{
		ir::Ref phi = self.decl.body[i];
		ir::Inst inst = self.inst(phi);
		foreach (input : inst.data.phi)
		{
			if (input.label != self.current_label) continue;
			PhiMove move = { .src = self.phi_location(input.value), .dst = self.phi_location(phi) };
			move.is_float = self.is_float_type(inst.ty);
			move.width = move.is_float ? self.float_width(inst.ty)! : self.bits(inst.ty)!;
			if (!move.src.same(move.dst)) moves.push(move);
			break;
		}
	}
	self.parallel_move(&moves)!;
}

<* Emit `moves` as one parallel assignment (sources all read before any
   destination is overwritten); cycles go through R11/XMM1. *>
fn void? Lowering.parallel_move(&self, List{PhiMove}* list)
{
	List{PhiMove} moves = *list;
	while (moves.len() > 0)
	{
		bool emitted = false;
		for (sz i = 0; i < moves.len(); i++)
		{
			if (self.phi_move_blocked(&moves, (usz)i)) continue;
			self.emit_phi_move(moves[i])!;
			moves.remove_at(i);
			emitted = true;
			break;
		}
		if (emitted) continue;
		// Every remaining destination is still read: a cycle. Park the first
		// move's destination value in the scratch register and redirect its readers.
		PhiLoc parked = moves[0].dst;
		bool is_float = moves[0].is_float;
		PhiMove save = { .src = parked, .dst = { .kind = SCRATCH }, .width = moves[0].width, .is_float = is_float };
		// The parked value's width is that of the moves reading it.
		foreach (move : moves)
		{
			if (move.src.same(parked)) { save.width = move.width; break; }
		}
		self.emit_phi_move(save)!;
		foreach (&move : moves)
		{
			if (move.src.same(parked)) move.src = { .kind = SCRATCH };
		}
	}
}

<* Move `index` writes a location another pending move still reads. *>
fn bool Lowering.phi_move_blocked(&self, List{PhiMove}* moves, usz index)
{
	PhiLoc dst = (*moves)[(sz)index].dst;
	foreach (i, move : *moves)
	{
		if ((usz)i != index && move.src.same(dst)) return true;
	}
	return false;
}

fn void? Lowering.emit_phi_move(&self, PhiMove move)
{
	if (move.is_float)
	{
		self.emit_phi_float_move(move)!;
		return;
	}
	ushort w = move.width;
	// Whole-register moves between registers copy every bit the value has.
	ushort reg_w = w < 32 ? 32 : w;
	PhiLoc src = move.src;
	PhiLoc dst = move.dst;
	Register scratch = R11;
	switch (dst.kind)
	{
		case REG:
		case SCRATCH:
			Register target = dst.kind == SCRATCH ? scratch : dst.reg;
			switch (src.kind)
			{
				case REG: self.emit(MOV, reg_op(target.to_bits(reg_w)), reg_op(src.reg.to_bits(reg_w)));
				case SCRATCH: self.emit(MOV, reg_op(target.to_bits(reg_w)), reg_op(scratch.to_bits(reg_w)));
				case SLOT: self.emit(MOV, reg_op(target.to_bits(w)), mem_op(RBP, src.offset, w));
				case VALUE: self.load(src.value, target)!;
			}
		case SLOT:
			Operand destination = mem_op(RBP, dst.offset, w);
			switch (src.kind)
			{
				case REG: self.emit(MOV, destination, reg_op(src.reg.to_bits(w)));
				case SCRATCH: self.emit(MOV, destination, reg_op(scratch.to_bits(w)));
				case SLOT:
					self.emit(MOV, reg_op(Register.RAX.to_bits(w)), mem_op(RBP, src.offset, w));
					self.emit(MOV, destination, reg_op(Register.RAX.to_bits(w)));
				case VALUE:
					long imm;
					if (self.int_immediate(src.value, w, &imm))
					{
						self.emit(MOV, destination, imm_op(imm));
					}
					else
					{
						ushort loaded = self.load(src.value, RAX)!;
						self.emit(MOV, mem_op(RBP, dst.offset, loaded), reg_op(Register.RAX.to_bits(loaded)));
					}
			}
		case VALUE:
			unreachable("a PHI is never a constant");
	}
}

fn void? Lowering.emit_phi_float_move(&self, PhiMove move)
{
	ushort w = move.width;
	Mnemonic mov = self.float_move_mnemonic(w);
	PhiLoc src = move.src;
	PhiLoc dst = move.dst;
	Register scratch = XMM1;
	// The source, in an XMM register (XMM0 when it has to be loaded).
	Register from;
	switch (src.kind)
	{
		case REG: from = src.reg;
		case SCRATCH: from = scratch;
		case SLOT:
		case VALUE:
			from = dst.kind == REG ? dst.reg : dst.kind == SCRATCH ? scratch : XMM0;
			if (src.kind == SLOT)
			{
				self.emit(mov, reg_op(from), mem_op(RBP, src.offset, w));
			}
			else
			{
				self.load_float(src.value, from)!;
			}
	}
	switch (dst.kind)
	{
		case REG: if (from != dst.reg) self.emit(MOVAPS, reg_op(dst.reg), reg_op(from));
		case SCRATCH: if (from != scratch) self.emit(MOVAPS, reg_op(scratch), reg_op(from));
		case SLOT: self.emit(mov, mem_op(RBP, dst.offset, w), reg_op(from));
		case VALUE: unreachable("a PHI is never a constant");
	}
}
