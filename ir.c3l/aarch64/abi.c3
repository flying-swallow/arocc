// ARM64 backend, organized like the sibling x86_64 backend.
module aro::backend::aarch64;
import aro::backend::ir, aro::primitive_value, aro::value_interner, aro::target;
import std::core::dstring, std::core::string, std::collections::list;

fn void Lowering.adjust_sp(&self, uint bytes, bool subtract)
{
	if (!bytes) return;
	self.immediate(15, bytes);
	self.emit(subtract ? SUB : ADD, reg_op(SP), reg_op(SP), reg_op(X15));
}

fn void? Lowering.aggregate_result(&self, ir::DarwinAggregate aggregate, bool returning)
{
	uint count = aggregate.hfa_count ? aggregate.hfa_count : aligned(aggregate.size, 8) / 8;
	uint stride = aggregate.hfa_count ? aggregate.hfa_bits / 8 : 8;
	for (uint i = 0; i < count; i++)
	{
		if (aggregate.hfa_count)
		{
			self.emit(returning ? LDR : STR, reg_op(fp(i, aggregate.hfa_bits)), mem_op(X14, (long)(i * stride)));
		}
		else
		{
			// The last GP piece may contain padding beyond the C object's end.
			// Transfer bytes individually so a Clang sret destination need not be padded.
			if (returning) self.immediate(i, 0);
			for (uint byte = 0; byte < stride && i * stride + byte < aggregate.size; byte++)
			{
				if (returning)
				{
					self.emit(LDRB, reg_op(W12), mem_op(X14, (long)(i * stride + byte)));
					self.emit(ORR, reg_op(gp(i)), reg_op(gp(i)), reg_op(X12), shift_op(byte * 8));
				}
				else
				{
					self.emit(LSR, reg_op(X12), reg_op(gp(i)), imm_op((long)(byte * 8)));
					self.emit(STRB, reg_op(W12), mem_op(X14, (long)(i * stride + byte)));
				}
			}
		}
	}
}

fn void? Lowering.call(&self, ir::Ref ref)
{
	ir::Inst inst = self.inst(ref);
	ir::CallData call = inst.data.call;
	if (!call.darwin)
	{
		// Target-neutral runtime helpers (memcpy/memset and legalization calls)
		// have fixed scalar signatures, unlike source-level variadic calls.
		call.locations = mem::temp_array(ir::ArgData, call.args.len);
		uint gp_index = 0;
		uint fp_index = 0;
		uint stack_offset = 0;
		foreach (i, arg : call.args)
		{
			if (call.memory_copy_bytes[i]) self.fail("ARM64: runtime helper has unsupported aggregate arguments")!;
			bool floating = self.is_float(self.inst(arg).ty);
			uint size = (self.bits(self.inst(arg).ty)! + 7) / 8;
			if (floating && fp_index < 8) { call.locations[i] = { .location_kind = SSE_REGISTER, .location = fp_index++ }; }
			else if (!floating && gp_index < 8) { call.locations[i] = { .location_kind = GP_REGISTER, .location = gp_index++ }; }
			else
			{
				stack_offset = aligned(stack_offset, size);
				call.locations[i] = { .location_kind = STACK, .location = stack_offset, .stack_size = size };
				stack_offset += size;
			}
		}
	}
	if (call.locations.len != call.args.len) self.fail("ARM64: call placement count does not match arguments")!;
	uint stack = 0;
	foreach (location : call.locations)
	{
		if (location.location_kind == STACK && location.location + location.stack_size > stack) stack = location.location + location.stack_size;
	}
	stack = aligned(stack, 16);
	self.adjust_sp(stack, true);
	foreach (i, arg : call.args)
	{
		ir::ArgData location = call.locations[i];
		self.load(arg)!;
		switch (location.location_kind)
		{
			case GP_REGISTER: self.emit(MOV, reg_op(gp(location.location)), reg_op(X9));
			case SSE_REGISTER:
				uint width = self.bits(self.inst(arg).ty)!;
				self.emit(FMOV, reg_op(fp(location.location, width)), reg_op(gp(9, width)));
			case STACK:
				self.immediate(15, location.location);
				self.emit(ADD, reg_op(X15), reg_op(SP), reg_op(X15));
				uint width = location.stack_size * 8;
				self.emit(store_op(width), reg_op(gp(9, width)), mem_op(X15));
			default: self.fail("ARM64: unsupported argument location")!;
		}
	}
	ir::Inst callee = self.inst(call.func);
	if (callee.tag == SYMBOL) { self.emit(BL, target_op(symbol(callee.data.label))); }
	else { self.load(call.func, 16)!; self.emit(BLR, reg_op(X16)); }
	self.adjust_sp(stack, false);
	if (call.result.size)
	{
		if (!call.result.indirect())
		{
			self.load(call.args[0], 14)!;
			self.aggregate_result(call.result, false)!;
		}
	}
	else if (inst.ty != value_interner::REF_VOID)
	{
		if (self.is_float(inst.ty)) { self.save_fp(ref, 0)!; }
		else { self.emit(MOV, reg_op(X9), reg_op(X0)); self.save(ref)!; }
	}
}

