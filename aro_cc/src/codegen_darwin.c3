// Darwin ARM64 C ABI lowering. Explicit locations keep ABI policy out of the
// instruction selector. Aggregate expressions continue to be addresses in IR.
module aro::frontend::c::codegen;
import aro::backend::ir, aro::target, aro::frontend::c::type_store;
import aro::frontend::c::tree, aro::frontend::c::value, aro::value_interner;

fn bool CodeGen.is_darwin_arm64(&self)
	=> self.comp.target.cpu.arch == target::Arch.AARCH64 && self.comp.target.os.tag == target::OsTag.MACOS;

struct DarwinParams { uint gp; uint fp; uint stack; }

fn uint darwin_align(uint size, uint alignment) => (size + alignment - 1) / alignment * alignment;

fn ir::ArgData DarwinParams.stack_arg(&self, uint size, uint alignment)
{
	self.stack = darwin_align(self.stack, alignment);
	ir::ArgData result = { .location_kind = STACK, .location = self.stack, .stack_size = size };
	self.stack += size;
	return result;
}

fn ir::ArgData DarwinParams.scalar(&self, bool fp, uint size, uint alignment, bool variadic = false)
{
	if (!variadic && fp && self.fp < 8) return { .location_kind = SSE_REGISTER, .location = self.fp++ };
	if (!variadic && !fp && self.gp < 8) return { .location_kind = GP_REGISTER, .location = self.gp++ };
	if (variadic) { size = darwin_align(size, 8); alignment = alignment < 8 ? 8 : alignment; }
	return self.stack_arg(size, alignment);
}

// Recursively recognize homogeneous aggregates, including nested arrays and unions.
fn bool CodeGen.darwin_hfa(&self, type_store::QualType qt, uint* bits, uint* count)
{
	type_store::BaseType base = qt.base(self.comp);
	if (base.ty.tag == FLOAT)
	{
		uint width = (uint)qt.bit_sizeof(self.comp);
		if ((width != 32 && width != 64) || (*bits && *bits != width)) return false;
		*bits = width;
		*count += 1;
		return *count <= 4;
	}
	if (base.ty.tag == ARRAY)
	{
		if (base.ty.array.len.len > 4) return false;
		for (ulong i = 0; i < base.ty.array.len.len; i++)
		{
			if (!self.darwin_hfa(base.ty.array.elem, bits, count)) return false;
		}
		return true;
	}
	if (base.ty.tag != STRUCT && base.ty.tag != UNION) return false;
	uint maximum = 0;
	foreach (field : base.ty.record.fields)
	{
		if (field.bit_width != type_store::BIT_WIDTH_NULL) return false;
		uint members = base.ty.tag == UNION ? 0 : *count;
		if (!self.darwin_hfa(field.qt, bits, &members)) return false;
		if (base.ty.tag == UNION) { if (members > maximum) maximum = members; }
		else { *count = members; }
	}
	if (base.ty.tag == UNION) *count += maximum;
	return *count <= 4;
}

fn ir::DarwinAggregate? CodeGen.darwin_aggregate(&self, type_store::QualType qt)
{
	self.darwin_check_aggregate(qt)!;
	self.gen_type(qt)!;
	ir::DarwinAggregate result = { .size = (uint)qt.sizeof(self.comp) };
	uint bits = 0;
	uint count = 0;
	if (self.darwin_hfa(qt, &bits, &count) && count && result.size == count * bits / 8)
	{
		result.hfa_bits = bits;
		result.hfa_count = count;
	}
	return result;
}

fn ir::Ref CodeGen.darwin_incoming(&self, value_interner::InternerRef ty, ir::ArgData location)
	=> self.builder.add_arg_at(ty, location.location_kind, location.location, location.stack_size, location.stack_address);

fn uint? CodeGen.darwin_parameters(&self, type_store::Func function)
{
	DarwinParams state;
	if (self.aggregate_return)
	{
		ir::DarwinAggregate result = self.darwin_aggregate(function.return_type)!;
		self.sret_pointer = result.indirect() ?
			self.builder.add_arg_at(value_interner::REF_PTR, ir::ArgLocationKind.GP_REGISTER, 8, 0) :
			self.builder.add_alloc(darwin_align(result.size ? result.size : 1, 8), function.return_type.alignof(self.comp));
	}
	foreach (param : function.params)
	{
		uint size = (uint)param.qt.sizeof(self.comp);
		uint alignment = param.qt.alignof(self.comp);
		ir::Ref slot = self.builder.add_alloc(darwin_align(size ? size : 1, 8), alignment, self.type_contains_volatile(param.qt));
		if (self.is_record_value(param.qt))
		{
			ir::DarwinAggregate aggregate = self.darwin_aggregate(param.qt)!;
			if (aggregate.indirect())
			{
				ir::Ref ptr = self.darwin_incoming(value_interner::REF_PTR, state.scalar(false, 8, 8));
				self.gen_copy(slot, ptr, size)!;
			}
			else if (size)
			{
				uint pieces = aggregate.hfa_count ? aggregate.hfa_count : darwin_align(size, 8) / 8;
				bool fp = aggregate.hfa_count != 0;
				bool registers = fp ? state.fp + pieces <= 8 : state.gp + pieces <= 8;
				if (!registers)
				{
					if (fp) { state.fp = 8; } else { state.gp = 8; }
					uint stack_alignment = fp ? alignment : (alignment < 8 ? 8 : alignment);
					uint stack_size = fp ? size : darwin_align(size, 8);
					ir::ArgData location = state.stack_arg(stack_size, stack_alignment);
					location.stack_address = true;
					ir::Ref ptr = self.darwin_incoming(value_interner::REF_PTR, location);
					self.gen_copy(slot, ptr, size)!;
				}
				else
				{
					uint stride = fp ? aggregate.hfa_bits / 8 : 8;
					value_interner::InternerRef ty = fp ? (stride == 4 ? value_interner::REF_F32 : value_interner::REF_F64) : value_interner::REF_I64;
					for (uint i = 0; i < pieces; i++) self.builder.add_store(self.ptr_at(slot, (ulong)i * stride), self.darwin_incoming(ty, state.scalar(fp, stride, stride)));
				}
			}
		}
		else
		{
			if (size > 8) self.fail("ARM64: scalar parameters wider than 64 bits are unsupported")!;
			bool fp = param.qt.is(self.comp, type_store::TypeTag.FLOAT);
			value_interner::InternerRef ty = self.gen_type(param.qt)!;
			bool promoted = self.is_knr_float_param(function, param.qt);
			if (promoted) { ty = value_interner::REF_F64; size = 8; alignment = 8; }
			ir::Ref arg = self.darwin_incoming(ty, state.scalar(fp, size, alignment));
			if (promoted) arg = self.builder.add_inst(ir::InstTag.FPTRUNC, { .ref = arg }, value_interner::REF_F32);
			self.builder.add_store(slot, arg);
		}
		self.symbols.push({ .name = param.name, .value = slot });
	}
	return darwin_align(state.stack, 8);
}

fn ir::Ref? CodeGen.darwin_call(&self, ir::Ref callee, tree::NodeCall call)
{
	type_store::Func function = call.callee.qt(self.tree).get_func(self.comp)!;
	usz capacity = call.args.len * 4 + 1;
	ir::Ref[] args = alloc::new_array(&self.builder.arena, ir::Ref, (sz)capacity);
	ir::ArgData[] locations = alloc::new_array(&self.builder.arena, ir::ArgData, (sz)capacity);
	usz count = 0;
	DarwinParams state;
	ir::DarwinAggregate result;
	ir::Ref result_slot = ir::NONE;
	if (self.is_record_value(call.qt))
	{
		result = self.darwin_aggregate(call.qt)!;
		result_slot = self.builder.add_alloc(darwin_align(result.size ? result.size : 1, 8), call.qt.alignof(self.comp));
		if (result.size)
		{
			args[count] = result_slot;
			locations[count++] = { .location_kind = GP_REGISTER, .location = 8 };
		}
	}
	foreach (i, node : call.args)
	{
		bool fixed = i < function.params.len;
		bool variadic = !fixed && function.kind == type_store::FuncKind.VARIADIC;
		type_store::QualType qt = fixed ? function.params[i].qt : node.qt(self.tree);
		ir::Ref source = self.gen_expr(node)!;
		uint size = (uint)qt.sizeof(self.comp);
		uint alignment = qt.alignof(self.comp);
		if (self.is_record_value(qt))
		{
			ir::DarwinAggregate aggregate = self.darwin_aggregate(qt)!;
			if (!size) continue;
			ir::Ref copy = self.builder.add_alloc(darwin_align(size, 8), alignment);
			self.gen_zero_fill(copy, darwin_align(size, 8))!;
			self.gen_copy(copy, source, size)!;
			if (aggregate.indirect())
			{
				args[count] = copy;
				locations[count++] = state.scalar(false, 8, 8, variadic);
				continue;
			}
			uint pieces = aggregate.hfa_count ? aggregate.hfa_count : darwin_align(size, 8) / 8;
			bool fp = aggregate.hfa_count != 0;
			bool registers = !variadic && (fp ? state.fp + pieces <= 8 : state.gp + pieces <= 8);
			uint stride = fp ? aggregate.hfa_bits / 8 : 8;
			if (!registers)
			{
				if (!variadic) { if (fp) { state.fp = 8; } else { state.gp = 8; } }
				uint stack_alignment = variadic || !fp ? (alignment < 8 ? 8 : alignment) : alignment;
				state.stack = darwin_align(state.stack, stack_alignment);
			}
			value_interner::InternerRef ty = fp ? (stride == 4 ? value_interner::REF_F32 : value_interner::REF_F64) : value_interner::REF_I64;
			for (uint piece = 0; piece < pieces; piece++)
			{
				args[count] = self.builder.add_load(self.ptr_at(copy, (ulong)piece * stride), ty);
				locations[count++] = registers ? state.scalar(fp, stride, stride) : state.stack_arg(stride, 1);
			}
			continue;
		}
		if (size > 8) self.fail("ARM64: scalar arguments wider than 64 bits are unsupported")!;
		bool fp = qt.is(self.comp, type_store::TypeTag.FLOAT);
		if (fp) self.ensure_scalar_float_width(qt)!;
		if (fixed && self.is_knr_float_param(function, qt))
		{
			source = self.builder.add_inst(ir::InstTag.FPEXT, { .ref = source }, value_interner::REF_F64);
			size = 8; alignment = 8;
		}
		if (fixed && qt.is_real_int(self.comp) && size < 4) source = self.builder.add_inst(qt.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT, { .ref = source }, value_interner::REF_I32);
		args[count] = source;
		locations[count++] = state.scalar(fp, size, alignment, variadic);
	}
	bool[] stack_only = alloc::new_array(&self.builder.arena, bool, (sz)count);
	uint[] copies = alloc::new_array(&self.builder.arena, uint, (sz)count);
	for (usz i = 0; i < count; i++) { stack_only[i] = locations[i].location_kind == STACK; copies[i] = 0; }
	value_interner::InternerRef ty = self.is_record_value(call.qt) ? value_interner::REF_VOID : self.gen_type(call.qt)!;
	ir::Ref ref = self.builder.add_call_abi(callee, args[:count], stack_only, copies, ty);
	self.builder.instructions[(sz)ref].data.call.darwin = true;
	self.builder.instructions[(sz)ref].data.call.locations = locations[:count];
	self.builder.instructions[(sz)ref].data.call.result = result;
	return self.is_record_value(call.qt) ? result_slot : ref;
}

fn ir::Ref? CodeGen.darwin_va_arg(&self, type_store::NodeIndex node, type_store::QualType qt)
{
	ir::Ref list = self.darwin_va_address(node)!;
	ir::Ref cursor = self.builder.add_load(list, value_interner::REF_PTR);
	uint alignment = qt.alignof(self.comp);
	if (alignment > 8)
	{
		ir::Ref bias = self.builder.add_constant(value::int_u64((ulong)(alignment - 1), self.comp).ref(), value_interner::REF_I64);
		ir::Ref mask = self.builder.add_constant(value::int_u64(~(ulong)(alignment - 1), self.comp).ref(), value_interner::REF_I64);
		cursor = self.builder.add_inst(ir::InstTag.ADD, { .bin = { cursor, bias } }, value_interner::REF_PTR);
		cursor = self.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { cursor, mask } }, value_interner::REF_PTR);
	}
	uint size = (uint)qt.sizeof(self.comp);
	bool record = self.is_record_value(qt);
	bool indirect = false;
	if (record) indirect = (self.darwin_aggregate(qt)!).indirect();
	uint step = indirect ? 8 : darwin_align(size, 8);
	ir::Ref next = self.ptr_at(cursor, step);
	self.builder.add_store(list, next);
	if (indirect) cursor = self.builder.add_load(cursor, value_interner::REF_PTR);
	return record ? cursor : self.builder.add_load(cursor, self.gen_type(qt)!);
}

// The parser applies lvalue conversion to pointer-based Darwin va_list.
// These builtins mutate the list itself, so recover its storage address.
fn ir::Ref? CodeGen.darwin_va_address(&self, type_store::NodeIndex index)
{
	tree::Node node = index.get(self.tree);
	if (node.kind == CAST && node.cast.kind == LVAL_TO_RVAL) return self.gen_lval(node.cast.operand);
	return self.gen_lval(index);
}

fn void? CodeGen.darwin_check_aggregate(&self, type_store::QualType qt)
{
	type_store::BaseType base = qt.base(self.comp);
	if (base.ty.tag == VECTOR) self.fail("ARM64: vector arguments and results are unsupported")!;
	if (base.ty.tag == ARRAY) return self.darwin_check_aggregate(base.ty.array.elem);
	if (base.ty.tag == STRUCT || base.ty.tag == UNION)
	{
		foreach (field : base.ty.record.fields) self.darwin_check_aggregate(field.qt)!;
	}
}
