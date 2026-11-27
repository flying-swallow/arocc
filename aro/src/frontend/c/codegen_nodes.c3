// Port of AST statement/expression lowering from src/aro/CodeGen.zig.
module aro::frontend::c::codegen;
import aro::primitive_value;
import aro::frontend::c::builtin_call;
import aro::backend::ir, aro::frontend::c::builtins, aro::frontend::c::builtin_properties, aro::frontend::c::builtin_defs::common, aro::frontend::c::compilation, aro::frontend::c::diagnostics;
import aro::bigint, aro::frontend::c::tokens;
import aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner, aro::frontend::c::lang_opts;
import aro::target;
import aro::string_interner;
import std::core::dstring, std::core::string, std::collections::list;

<* Struct and union expressions are represented by the address of their storage. *>
fn bool CodeGen.is_record_value(&self, type_store::QualType qt)
{
	// Vectors are memory values too (codegen_vector.c3).
	return @ok(qt.get_record(self.comp)) || qt.is(self.comp, type_store::TypeTag.VECTOR);
}

<* The IR type of an expression value; records use their storage address. *>
fn value_interner::InternerRef? CodeGen.value_type(&self, type_store::QualType qt)
{
	if (self.is_record_value(qt)) return value_interner::REF_PTR;
	return self.gen_type(qt);
}

struct MemberBase
{
	ir::Ref ptr;
	type_store::RecordField field;
	ulong record_size;
	<* The member access names a volatile object (volatile field or base). *>
	bool is_volatile;
}

struct BitfieldLval
{
	bool reverse_storage;
	ir::Ref unit_ptr;
	value_interner::InternerRef unit_ty;
	uint unit_bits;
	uint shift;
	uint width;
	type_store::QualType field_qt;
	bool is_volatile;
	<* When no single typed unit holds the field (a straddling or wide field),
	   `unit_ptr` is a 16-byte temporary: its first `spill_bytes` bytes mirror
	   the record bytes at `spill_src`, copied in before and back after access. *>
	ir::Ref spill_src;
	uint spill_bytes;
}

<* Parentheses do not change whether a member designates a bitfield. *>
fn bool CodeGen.is_bitfield_lvalue(&self, type_store::NodeIndex node_index)
{
	while (node_index.get(self.tree).kind == tree::NodeKind.PAREN_EXPR)
	{
		node_index = node_index.get(self.tree).unary.operand;
	}
	return self.tree.is_bitfield(node_index);
}

fn bool CodeGen.is_bitfield_compound_dummy(&self, type_store::NodeIndex node_index)
{
	tree::Node node = node_index.get(self.tree);
	if (node.kind != tree::NodeKind.COMPOUND_ASSIGN_DUMMY_EXPR) return false;
	return self.compound_dummy_is_value || self.is_bitfield_lvalue(node.unary.operand);
}

<* Resolve the base address and field for `.` or `->` member access. *>
fn MemberBase? CodeGen.gen_member_base(&self, type_store::NodeIndex node_index)
{
	while (node_index.get(self.tree).kind == tree::NodeKind.PAREN_EXPR)
	{
		node_index = node_index.get(self.tree).unary.operand;
	}
	tree::Node node = node_index.get(self.tree);
	assert(node.kind == tree::NodeKind.MEMBER_ACCESS_EXPR || node.kind == tree::NodeKind.MEMBER_ACCESS_PTR_EXPR);
	bool through_pointer = node.kind == tree::NodeKind.MEMBER_ACCESS_PTR_EXPR;
	type_store::QualType base_qt = node.member_access.base.qt(self.tree);
	if (through_pointer && base_qt.is_pointer(self.comp)) base_qt = base_qt.child_type(self.comp);
	type_store::Record? record = base_qt.get_record(self.comp);
	if (catch record)
	{
		self.fail(string::tformat("TODO CodeGen.genLval %s\n", node.kind.name))!;
		return compilation::FATAL_ERROR~;
	}
	if ((usz)node.member_access.member_index >= record.fields.len)
	{
		self.fail(string::tformat("TODO CodeGen.genLval %s\n", node.kind.name))!;
		return compilation::FATAL_ERROR~;
	}

	ir::Ref base_ptr;
	if (!through_pointer)
	{
		base_ptr = self.tree.is_lval(node.member_access.base) ?
			self.gen_lval(node.member_access.base)! : self.gen_expr(node.member_access.base)!;
	}
	else if (self.tree.is_lval(node.member_access.base))
	{
		// The parser keeps `p` in `p->f` as an lvalue: load the pointer.
		base_ptr = self.builder.add_load(self.gen_lval(node.member_access.base)!, value_interner::REF_PTR,
			self.access_is_volatile(node.member_access.base.qt(self.tree)));
	}
	else
	{
		base_ptr = self.gen_expr(node.member_access.base)!;
	}
	return
	{
		.ptr = base_ptr,
		.field = record.fields[node.member_access.member_index],
		.record_size = base_qt.sizeof(self.comp),
		.is_volatile = self.access_is_volatile(base_qt) || self.access_is_volatile(node_index.qt(self.tree)) ||
			self.access_is_volatile(record.fields[node.member_access.member_index].qt),
	};
}

fn value_interner::InternerRef CodeGen.bitfield_window_type(&self, uint byte_count)
{
	switch (byte_count)
	{
		case 1: return value_interner::REF_I8;
		case 2: return value_interner::REF_I16;
		case 4: return value_interner::REF_I32;
		case 8: return value_interner::REF_I64;
		default: unreachable("invalid bitfield storage window size");
	}
}

<* Resolve a bitfield to one typed storage unit, staying within its record. *>
fn BitfieldLval? CodeGen.bitfield_lval(&self, ir::Ref record_ptr, type_store::RecordField field, ulong record_size, bool is_volatile = false)
{
	assert(field.bit_width != type_store::BIT_WIDTH_NULL && field.bit_width != 0);
	assert(field.layout.offset_bits != type_store::FIELD_LAYOUT_INVALID);
	ulong offset_bits = field.layout.offset_bits;
	ulong record_bits = record_size * 8;
	assert(offset_bits <= record_bits, "bitfield starts beyond record storage");
	assert(field.bit_width <= record_bits - offset_bits, "bitfield extends beyond record storage");

	ulong declared_bits = field.qt.bit_sizeof(self.comp);
	// _Bool values use an i1 value type but occupy an addressable byte in memory.
	uint unit_bits = (uint)max((ulong)8, declared_bits);
	if (unit_bits <= 64 && field.bit_width <= unit_bits)
	{
		ulong unit_start_bits = (offset_bits / unit_bits) * unit_bits;
		ulong unit_bytes = ((ulong)unit_bits + 7) / 8;
		if (unit_start_bits % 8 == 0 && offset_bits - unit_start_bits + field.bit_width <= unit_bits &&
			unit_start_bits / 8 + unit_bytes <= record_size)
		{
			value_interner::InternerRef unit_ty = field.qt.is(self.comp, type_store::TypeTag.BOOL) ?
				value_interner::REF_I8 : self.gen_type(field.qt)!;
			return
			{
				.unit_ptr = self.ptr_at(record_ptr, unit_start_bits / 8),
				.unit_ty = unit_ty,
				.unit_bits = unit_bits,
				.reverse_storage = field.reverse_storage,
				.shift = field.reverse_storage ? unit_bits - (uint)(offset_bits - unit_start_bits) - field.bit_width : (uint)(offset_bits - unit_start_bits),
				.width = field.bit_width,
				.field_qt = field.qt,
				.is_volatile = is_volatile,
			};
		}
	}

	// Packed and straddling fields use the narrowest typed window that contains
	// their bits. Move the start back when that window would pass record sizeof.
	ulong offset_byte = offset_bits / 8;
	uint initial_shift = (uint)(offset_bits % 8);
	uint[4] window_sizes = { 1, 2, 4, 8 };
	foreach (byte_count : window_sizes)
	{
		uint window_bits = byte_count * 8;
		if (initial_shift + field.bit_width > window_bits || record_size < byte_count) continue;
		ulong start_byte = offset_byte;
		if (start_byte + byte_count > record_size) start_byte = record_size - byte_count;
		uint shift = (uint)(offset_bits - start_byte * 8);
		if (shift + field.bit_width > window_bits) continue;
		return
		{
			.unit_ptr = self.ptr_at(record_ptr, start_byte),
			.unit_ty = self.bitfield_window_type(byte_count),
			.unit_bits = window_bits,
			.reverse_storage = field.reverse_storage,
			.shift = field.reverse_storage ? window_bits - shift - field.bit_width : shift,
			.width = field.bit_width,
			.field_qt = field.qt,
			.is_volatile = is_volatile,
		};
	}
	// Straddling (e.g. a packed 64-bit field at bit 7) or wider than 64 bits:
	// access the field's bytes through a 128-bit window on a temporary copy.
	uint spill_bytes = (uint)((initial_shift + field.bit_width + 7) / 8);
	if (field.bit_width > 64 || field.reverse_storage)
	{
		self.fail("TODO lower struct bitfields")!;
		return compilation::FATAL_ERROR~;
	}
	ir::Ref temp = self.builder.add_alloc(16, 16);
	self.gen_zero_fill(temp, 16)!;
	return
	{
		.unit_ptr = temp,
		.unit_ty = value_interner::REF_I128,
		.unit_bits = 128,
		.shift = initial_shift,
		.width = field.bit_width,
		.field_qt = field.qt,
		.is_volatile = is_volatile,
		.spill_src = self.ptr_at(record_ptr, offset_byte),
		.spill_bytes = spill_bytes,
	};
}

fn ir::Ref CodeGen.unit_constant(&self, ulong value, value_interner::InternerRef unit_ty)
{
	return self.builder.add_constant(value::int_u64(value, self.comp).ref(), unit_ty);
}

<* Normalize the low `width` bits of a stored value to the declared field type. *>
fn ir::Ref? CodeGen.bitfield_store_result(&self, ir::Ref bits, BitfieldLval lval)
{
	ulong field_mask = lval.width == 64 ? ulong::max : ((ulong)1 << lval.width) - 1;
	if (lval.width < lval.unit_bits)
	{
		ir::Ref mask_ref = self.unit_constant(field_mask, lval.unit_ty);
		bits = self.builder.add_inst(ir::InstTag.BIT_AND,
			{ .bin = { .lhs = bits, .rhs = mask_ref } }, lval.unit_ty);
	}
	if (lval.field_qt.is(self.comp, type_store::TypeTag.BOOL))
	{
		ir::Ref zero = self.unit_constant(0, lval.unit_ty);
		return self.builder.add_inst(ir::InstTag.CMP_NE,
			{ .bin = { .lhs = bits, .rhs = zero } }, value_interner::REF_I1);
	}
	if (lval.field_qt.signedness(self.comp) == SIGNED && lval.width < lval.unit_bits)
	{
		ulong shift_count = (ulong)lval.unit_bits - lval.width;
		ir::Ref shift = self.unit_constant(shift_count, lval.unit_ty);
		bits = self.builder.add_inst(ir::InstTag.BIT_SHL,
			{ .bin = { .lhs = bits, .rhs = shift } }, lval.unit_ty);
		bits = self.builder.add_inst(ir::InstTag.BIT_ASHR,
			{ .bin = { .lhs = bits, .rhs = shift } }, lval.unit_ty);
	}
	ulong type_bits = lval.field_qt.bit_sizeof(self.comp);
	value_interner::InternerRef result_type = self.gen_type(lval.field_qt)!;
	if (type_bits < lval.unit_bits) return self.builder.add_inst(ir::InstTag.TRUNC, { .ref = bits }, result_type);
	if (type_bits > lval.unit_bits)
	{
		ir::InstTag extend = lval.field_qt.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT;
		return self.builder.add_inst(extend, { .ref = bits }, result_type);
	}
	return bits;
}

<* Convert an already extracted bitfield value to its declared field type. *>
fn ir::Ref? CodeGen.bitfield_read_result(&self, ir::Ref bits, BitfieldLval lval)
{
	if (lval.field_qt.is(self.comp, type_store::TypeTag.BOOL))
	{
		ir::Ref zero = self.unit_constant(0, lval.unit_ty);
		return self.builder.add_inst(ir::InstTag.CMP_NE,
			{ .bin = { .lhs = bits, .rhs = zero } }, value_interner::REF_I1);
	}
	ulong type_bits = lval.field_qt.bit_sizeof(self.comp);
	value_interner::InternerRef result_type = self.gen_type(lval.field_qt)!;
	if (type_bits < lval.unit_bits) return self.builder.add_inst(ir::InstTag.TRUNC, { .ref = bits }, result_type);
	if (type_bits > lval.unit_bits)
	{
		ir::InstTag extend = lval.field_qt.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT;
		return self.builder.add_inst(extend, { .ref = bits }, result_type);
	}
	return bits;
}

fn ir::Ref CodeGen.reverse_bitfield_unit(&self, ir::Ref operand, BitfieldLval lval)
{
	if (!lval.reverse_storage || lval.unit_bits == 8) return operand;
	ir::Ref result = ir::NONE;
	for (uint i = 0; i < lval.unit_bits / 8; i++)
	{
		ir::Ref byte = self.builder.add_inst(ir::InstTag.BIT_LSHR,
			{ .bin = { .lhs = operand, .rhs = self.unit_constant((ulong)i * 8, lval.unit_ty) } }, lval.unit_ty);
		byte = self.builder.add_inst(ir::InstTag.BIT_AND,
			{ .bin = { .lhs = byte, .rhs = self.unit_constant(255, lval.unit_ty) } }, lval.unit_ty);
		byte = self.builder.add_inst(ir::InstTag.BIT_SHL,
			{ .bin = { .lhs = byte, .rhs = self.unit_constant((ulong)(lval.unit_bits - 8 - i * 8), lval.unit_ty) } }, lval.unit_ty);
		result = result == ir::NONE ? byte : self.builder.add_inst(ir::InstTag.BIT_OR,
			{ .bin = { .lhs = result, .rhs = byte } }, lval.unit_ty);
	}
	return result;
}

<* Load and extract a bitfield using its typed storage unit. *>
fn ir::Ref? CodeGen.load_bitfield(&self, BitfieldLval lval)
{
	if (lval.spill_bytes != 0) self.gen_copy(lval.unit_ptr, lval.spill_src, lval.spill_bytes)!;
	ir::Ref unit = self.reverse_bitfield_unit(self.builder.add_load(lval.unit_ptr, lval.unit_ty, lval.is_volatile), lval);
	if (lval.field_qt.is(self.comp, type_store::TypeTag.BOOL))
	{
		if (lval.shift != 0)
		{
			ir::Ref shift = self.unit_constant(lval.shift, lval.unit_ty);
			unit = self.builder.add_inst(ir::InstTag.BIT_LSHR,
				{ .bin = { .lhs = unit, .rhs = shift } }, lval.unit_ty);
		}
		if (lval.shift + lval.width != lval.unit_bits)
		{
			ulong field_mask = lval.width >= 64 ? ulong::max : ((ulong)1 << lval.width) - 1;
			unit = self.builder.add_inst(ir::InstTag.BIT_AND,
				{ .bin = { .lhs = unit, .rhs = self.unit_constant(field_mask, lval.unit_ty) } }, lval.unit_ty);
		}
	}
	else if (lval.field_qt.signedness(self.comp) == SIGNED)
	{
		ulong left_count = (ulong)lval.unit_bits - lval.shift - lval.width;
		ir::Ref left = self.unit_constant(left_count, lval.unit_ty);
		unit = self.builder.add_inst(ir::InstTag.BIT_SHL,
			{ .bin = { .lhs = unit, .rhs = left } }, lval.unit_ty);
		ulong right_count = (ulong)lval.unit_bits - lval.width;
		ir::Ref right = self.unit_constant(right_count, lval.unit_ty);
		unit = self.builder.add_inst(ir::InstTag.BIT_ASHR,
			{ .bin = { .lhs = unit, .rhs = right } }, lval.unit_ty);
	}
	else
	{
		if (lval.shift != 0)
		{
			ir::Ref shift = self.unit_constant(lval.shift, lval.unit_ty);
			unit = self.builder.add_inst(ir::InstTag.BIT_LSHR,
				{ .bin = { .lhs = unit, .rhs = shift } }, lval.unit_ty);
		}
		if (lval.shift + lval.width != lval.unit_bits)
		{
			ulong field_mask = lval.width >= 64 ? ulong::max : ((ulong)1 << lval.width) - 1;
			unit = self.builder.add_inst(ir::InstTag.BIT_AND,
				{ .bin = { .lhs = unit, .rhs = self.unit_constant(field_mask, lval.unit_ty) } }, lval.unit_ty);
		}
	}
	return self.bitfield_read_result(unit, lval);
}

<* Merge one field into its typed storage unit and return the normalized value. *>
fn ir::Ref? CodeGen.store_bitfield(&self, BitfieldLval lval, ir::Ref value)
{
	ulong field_bits = lval.field_qt.bit_sizeof(self.comp);
	ir::Ref field_value = value;
	if (field_bits < lval.unit_bits)
	{
		ir::InstTag extend = lval.field_qt.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT;
		field_value = self.builder.add_inst(extend, { .ref = field_value }, lval.unit_ty);
	}
	else if (field_bits > lval.unit_bits)
	{
		field_value = self.builder.add_inst(ir::InstTag.TRUNC, { .ref = field_value }, lval.unit_ty);
	}
	ulong field_mask = lval.width == 64 ? ulong::max : ((ulong)1 << lval.width) - 1;
	if (lval.width < lval.unit_bits)
	{
		field_value = self.builder.add_inst(ir::InstTag.BIT_AND,
			{ .bin = { .lhs = field_value, .rhs = self.unit_constant(field_mask, lval.unit_ty) } }, lval.unit_ty);
	}
	ir::Ref normalized_value = field_value;
	ir::Ref field_mask_ref;
	if (lval.unit_bits > 64)
	{
		// The shifted mask may not fit in 64 bits: shift it in the unit type.
		field_mask_ref = self.unit_constant(field_mask, lval.unit_ty);
		if (lval.shift != 0)
		{
			field_mask_ref = self.builder.add_inst(ir::InstTag.BIT_SHL,
				{ .bin = { .lhs = field_mask_ref, .rhs = self.unit_constant(lval.shift, lval.unit_ty) } }, lval.unit_ty);
		}
	}
	else
	{
		field_mask_ref = self.unit_constant(field_mask << lval.shift, lval.unit_ty);
	}
	if (lval.spill_bytes != 0) self.gen_copy(lval.unit_ptr, lval.spill_src, lval.spill_bytes)!;
	ir::Ref outside_mask = self.builder.add_inst(ir::InstTag.BIT_NOT, { .ref = field_mask_ref }, lval.unit_ty);
	ir::Ref old_unit = self.reverse_bitfield_unit(self.builder.add_load(lval.unit_ptr, lval.unit_ty, lval.is_volatile), lval);
	ir::Ref outside = self.builder.add_inst(ir::InstTag.BIT_AND,
		{ .bin = { .lhs = old_unit, .rhs = outside_mask } }, lval.unit_ty);
	if (lval.shift != 0)
	{
		ir::Ref shift = self.unit_constant(lval.shift, lval.unit_ty);
		field_value = self.builder.add_inst(ir::InstTag.BIT_SHL,
			{ .bin = { .lhs = field_value, .rhs = shift } }, lval.unit_ty);
	}
	ir::Ref merged = self.builder.add_inst(ir::InstTag.BIT_OR,
		{ .bin = { .lhs = outside, .rhs = field_value } }, lval.unit_ty);
	self.builder.add_store(lval.unit_ptr, self.reverse_bitfield_unit(merged, lval), lval.is_volatile);
	if (lval.spill_bytes != 0) self.gen_copy(lval.spill_src, lval.unit_ptr, lval.spill_bytes)!;
	return self.bitfield_store_result(normalized_value, lval);
}

fn void? CodeGen.gen_stmt(&self, type_store::NodeIndex node)
{
	self.gen_expr(node)!;
}

fn ir::Ref? CodeGen.gen_expr(&self, type_store::NodeIndex node_index)
{
	if (self.has_cached_expr && node_index == self.cached_expr_node) return self.cached_expr_value;
	ir::Ref result = self.gen_expr_inner(node_index)!;
	type_store::QualType qt = node_index.qt(self.tree);
	if (try ty = qt.get(self.comp, type_store::TypeTag.BIT_INT))
	{
		if (ty.bit_int.bitfield_origin && ty.bit_int.bits < 64)
		{
			value_interner::InternerRef ir_ty = self.gen_type(qt)!;
			if (ty.bit_int.signedness == SIGNED)
			{
				ir::Ref shift = self.builder.add_constant(value::int_u64(64 - (ulong)ty.bit_int.bits, self.comp).ref(), ir_ty);
				result = self.add_bin(ir::InstTag.BIT_SHL, result, shift, qt)!;
				return self.add_bin(ir::InstTag.BIT_ASHR, result, shift, qt);
			}
			ir::Ref mask = self.builder.add_constant(value::int_u64(((ulong)1 << ty.bit_int.bits) - 1, self.comp).ref(), ir_ty);
			return self.add_bin(ir::InstTag.BIT_AND, result, mask, qt);
		}
	}
	return result;
}

fn ir::Ref? CodeGen.gen_expr_inner(&self, type_store::NodeIndex node_index)
{
	tree::Node node = node_index.get(self.tree);
	if (node.kind == tree::NodeKind.CAST && !node.cast.implicit) self.gen_runtime_type(node.cast.qt)!;

	// C3 represents record expressions by address, including lvalues, so field
	// access and copies never require an unsupported IR RECORD_TY load.
	if (self.is_record_value(node_index.qt(self.tree)) && self.tree.is_lval(node_index))
	{
		return self.gen_lval(node_index);
	}
	ir::Ref? vector_result = self.gen_vector_expr(node_index, node);
	if (catch f = vector_result)
	{
		if (f != NOT_VECTOR_OP) return f~;
	}
	else
	{
		return vector_result;
	}
	// Array/function decay casts and saved pointer values lower through their operands,
	// not as IR constants.
	if (try val = self.tree.value_of(node_index))
	{
		bool decay_cast = node.kind == tree::NodeKind.CAST &&
		(node.cast.kind == tree::CastKind.ARRAY_TO_POINTER || node.cast.kind == tree::CastKind.FUNCTION_TO_POINTER);
		bool implicit_variable = node.kind == tree::NodeKind.VARIABLE && node.variable.implicit;
		if (node.kind == tree::NodeKind.DECL_REF_EXPR)
		{
			tree::Node referenced = node.decl_ref.decl.get(self.tree);
			implicit_variable = referenced.kind == tree::NodeKind.VARIABLE && referenced.variable.implicit;
		}
		if (!self.is_record_value(node_index.qt(self.tree)) && !decay_cast && !implicit_variable && !val.is_pointer(self.comp))
		{
			return self.builder.add_constant(val.ref(), self.gen_type(node_index.qt(self.tree))!);
		}
	}

	// Large cases are out of line: gen_expr recurses once per nesting level and
	// every local of every case would otherwise sit in each of its frames.
	switch (node.kind)
	{
		case ENUMERATION_REF:
		case BOOL_LITERAL:
		case INT_LITERAL:
		case CHAR_LITERAL:
		case FLOAT_LITERAL:
		case IMAGINARY_LITERAL:
		case STRING_LITERAL_EXPR:
			unreachable("constant expression missing value map entry");
		case SIZEOF_EXPR:
		case ALIGNOF_EXPR:
			return self.gen_type_info_constant(node_index, node);
		case EMPTY_DECL:
		case STATIC_ASSERT:
		case FUNCTION: return ir::NONE;
		case TYPEDEF:
			self.gen_runtime_type(node.type_def.qt.get_type(self.comp).type_def.base)!;
			return ir::NONE;
		case STRUCT_DECL:
		case UNION_DECL:
		case ENUM_DECL:
		case ENUM_FIELD:
		case RECORD_FIELD:
		case STRUCT_FORWARD_DECL:
		case UNION_FORWARD_DECL:
		case ENUM_FORWARD_DECL:
		case NULL_STMT:
			break;
		case VARIABLE:
			return self.gen_variable(node_index, node);
		case LABELED_STMT:
			return self.gen_labeled_stmt(node_index, node);
		case COMPOUND_STMT:
			return self.gen_compound_stmt(node_index, node);
		case IF_STMT:
			return self.gen_if_stmt(node_index, node);
		case SWITCH_STMT:
			return self.gen_switch_stmt(node_index, node);
		case CASE_STMT:
			return self.gen_case_stmt(node_index, node);
		case DEFAULT_STMT:
			return self.gen_default_stmt(node_index, node);
		case WHILE_STMT:
			return self.gen_while_stmt(node_index, node);
		case DO_WHILE_STMT:
			return self.gen_do_while_stmt(node_index, node);
		case FOR_STMT:
			return self.gen_for_stmt(node_index, node);
		case CONTINUE_STMT:
			self.restore_vla_depth(self.continue_vla_depth);
			self.builder.add_jump(self.continue_label);
		case BREAK_STMT:
			self.restore_vla_depth(self.break_vla_depth);
			self.builder.add_jump(self.break_label);
		case RETURN_STMT:
			return self.gen_return_stmt(node_index, node);
		case GOTO_STMT:
			self.gen_goto(self.goto_label(node.goto_stmt.label_tok));
			self.builder.start_block(self.builder.make_label("goto.after"));
		case ASM_STMT:
			if (self.is_darwin_arm64()) self.fail("ARM64: inline assembly is unsupported")!;
			// An operand-free empty template (`asm volatile ("" ::: "memory")`) is only a
			// compiler barrier; the IR keeps program order for memory, so emit nothing.
			if (self.is_empty_asm_barrier(node.asm_stmt)) return ir::NONE;
			return self.gen_asm(node.asm_stmt);
		case COMPUTED_GOTO_STMT:
			// GNU `goto *expr`: an indirect jump to a block whose address `&&label` took.
			ir::Ref target = self.gen_expr(node.computed_goto_stmt.expr)!;
			if (!self.builder.block_terminated())
			{
				self.builder.add_inst(ir::InstTag.JMP_VAL, { .ref = target }, value_interner::REF_VOID);
			}
			self.builder.start_block(self.builder.make_label("goto.after"));
		case NULLPTR_LITERAL:
			self.fail(string::tformat("TODO CodeGen.genStmt %s\n", node.kind.name))!;
			return ir::NONE;
		case DECL_STMT:
			foreach (decl : node.decl_stmt.decls) self.gen_stmt(decl)!;
		case COMMA_EXPR:
			self.gen_expr(node.binary.lhs)!;
			return self.gen_expr(node.binary.rhs);
		case ASSIGN_EXPR:
			if (self.is_record_value(node.binary.qt))
			{
				ir::Ref rhs_address = self.gen_expr(node.binary.rhs)!;
				ir::Ref lhs_address = self.gen_lval(node.binary.lhs)!;
				self.gen_copy_value(lhs_address, rhs_address, node.binary.qt)!;
				return lhs_address;
			}
			ir::Ref rhs = self.gen_expr(node.binary.rhs)!;
			if (self.is_bitfield_lvalue(node.binary.lhs))
			{
				MemberBase member = self.gen_member_base(node.binary.lhs)!;
				BitfieldLval lval = self.bitfield_lval(member.ptr, member.field, member.record_size, member.is_volatile)!;
				return self.store_bitfield(lval, rhs);
			}
			ir::Ref lhs = self.gen_lval(node.binary.lhs)!;
			self.store_assigned(lhs, rhs, node.binary.lhs.qt(self.tree));
			return rhs;
		case MUL_ASSIGN_EXPR:
		case DIV_ASSIGN_EXPR:
		case MOD_ASSIGN_EXPR:
		case ADD_ASSIGN_EXPR:
		case SUB_ASSIGN_EXPR:
		case SHL_ASSIGN_EXPR:
		case SHR_ASSIGN_EXPR:
		case BIT_AND_ASSIGN_EXPR:
		case BIT_XOR_ASSIGN_EXPR:
		case BIT_OR_ASSIGN_EXPR:
			return self.gen_compound_assign(node.binary);
		case BIT_OR_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_OR);
		case BIT_XOR_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_XOR);
		case BIT_AND_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_AND);
		case EQUAL_EXPR:
			if (node.binary.lhs.qt(self.tree).is(self.comp, type_store::TypeTag.FLOAT))
			{
				self.ensure_scalar_float_width(node.binary.lhs.qt(self.tree))!;
			}
			return self.add_un(ir::InstTag.ZEXT,
				self.gen_comparison(node.binary, self.compare_tag(node.kind, node.binary))!, node.binary.qt);
		case NOT_EQUAL_EXPR:
			if (node.binary.lhs.qt(self.tree).is(self.comp, type_store::TypeTag.FLOAT))
			{
				self.ensure_scalar_float_width(node.binary.lhs.qt(self.tree))!;
			}
			return self.add_un(ir::InstTag.ZEXT,
				self.gen_comparison(node.binary, self.compare_tag(node.kind, node.binary))!, node.binary.qt);
		case LESS_THAN_EXPR:
		case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR:
		case GREATER_THAN_EQUAL_EXPR:
			if (node.binary.lhs.qt(self.tree).is(self.comp, type_store::TypeTag.FLOAT))
			{
				self.ensure_scalar_float_width(node.binary.lhs.qt(self.tree))!;
			}
			return self.add_un(ir::InstTag.ZEXT,
				self.gen_comparison(node.binary, self.compare_tag(node.kind, node.binary))!, node.binary.qt);
		case SHL_EXPR: return self.gen_bin_op(node.binary, ir::InstTag.BIT_SHL);
		case SHR_EXPR: return self.gen_bin_op(node.binary, self.signed_tag(node.binary.qt, ir::InstTag.BIT_ASHR, ir::InstTag.BIT_LSHR));
		case ADD_EXPR:
			return self.gen_add_expr(node_index, node);
		case SUB_EXPR:
			return self.gen_sub_expr(node_index, node);
		case MUL_EXPR:
			if (node.binary.qt.is(self.comp, type_store::TypeTag.FLOAT)) self.ensure_scalar_float_width(node.binary.qt)!;
			return self.gen_bin_op(node.binary, node.binary.qt.is(self.comp, type_store::TypeTag.FLOAT) ?
				ir::InstTag.FMUL : ir::InstTag.MUL);
		case DIV_EXPR:
			if (node.binary.qt.is(self.comp, type_store::TypeTag.FLOAT))
			{
				self.ensure_scalar_float_width(node.binary.qt)!;
				return self.gen_bin_op(node.binary, ir::InstTag.FDIV);
			}
			return self.gen_bin_op(node.binary, self.signed_tag(node.binary.qt, ir::InstTag.SDIV, ir::InstTag.UDIV));
		case MOD_EXPR: return self.gen_bin_op(node.binary, self.signed_tag(node.binary.qt, ir::InstTag.SREM, ir::InstTag.UREM));
		case ADDR_OF_EXPR:
			if (self.is_bitfield_lvalue(node.unary.operand))
			{
				self.fail("TODO bitfield lvalue address")!;
				return ir::NONE;
			}
			return self.gen_lval(node.unary.operand);
		case DEREF_EXPR:
			return self.gen_deref_expr(node_index, node);
		case PLUS_EXPR: return self.gen_expr(node.unary.operand);
		case NEGATE_EXPR:
			if (node.unary.qt.is(self.comp, type_store::TypeTag.FLOAT))
			{
				self.ensure_scalar_float_width(node.unary.qt)!;
				return self.add_un(ir::InstTag.FNEG, self.gen_expr(node.unary.operand)!, node.unary.qt);
			}
			ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.unary.qt)!);
			return self.add_bin(ir::InstTag.SUB, zero, self.gen_expr(node.unary.operand)!, node.unary.qt);
		case BIT_NOT_EXPR: return self.add_un(ir::InstTag.BIT_NOT, self.gen_expr(node.unary.operand)!, node.unary.qt);
		case BOOL_NOT_EXPR:
			return self.gen_bool_not_expr(node_index, node);
		case PRE_INC_EXPR:
		case PRE_DEC_EXPR:
		case POST_INC_EXPR:
		case POST_DEC_EXPR:
			return self.gen_pre_inc_expr(node_index, node);
		case PAREN_EXPR: return self.gen_expr(node.unary.operand);
		case DECL_REF_EXPR:
			unreachable("declaration reference must be lowered as an lvalue");
		case CAST:
			return self.gen_cast(node_index, node);
		case BINARY_COND_EXPR:
			return self.gen_binary_cond_expr(node_index, node);
		case COND_DUMMY_EXPR:
			return self.cond_dummy_ref;
		case COND_EXPR:
			return self.gen_cond_expr(node_index, node);
		case CALL_EXPR:
			return self.gen_call(node.call);
		case BOOL_OR_EXPR:
			return self.gen_bool_or_expr(node_index, node);
		case BOOL_AND_EXPR:
			return self.gen_bool_and_expr(node_index, node);
		case BUILTIN_CHOOSE_EXPR:
			value::Value cond = self.tree.value_of(node.conditional.cond)!!;
			return self.gen_expr(cond.to_bool(self.comp) ? node.conditional.then_expr: node.conditional.else_expr);
		case GENERIC_EXPR:
			tree::Node chosen = node.generic.chosen.get(self.tree);
			if (chosen.kind == tree::NodeKind.GENERIC_ASSOCIATION_EXPR) return self.gen_expr(chosen.generic_association.expr);
			if (chosen.kind == tree::NodeKind.GENERIC_DEFAULT_EXPR) return self.gen_expr(chosen.generic_default.expr);
			unreachable("unexpected node selected by generic expression");
		case GENERIC_ASSOCIATION_EXPR:
		case GENERIC_DEFAULT_EXPR:
			unreachable("generic association/default is not directly evaluated");
		case STMT_EXPR:
			return self.gen_stmt_expr(node_index, node);
		case BUILTIN_CALL_EXPR:
			builtins::Expanded builtin = self.comp.builtins.lookup(self.tree.tok_slice(node.builtin_call.builtin_tok));
			return self.gen_builtin_call(builtin, node.builtin_call.args, node.builtin_call.qt);
		case ADDR_OF_LABEL:
			sz label_index = self.goto_label(node.addr_of_label.label_tok);
			return self.builder.add_inst(ir::InstTag.LABEL_ADDR, { .ref = self.goto_labels[label_index].label }, value_interner::REF_PTR);
		case IMAG_EXPR:
		case REAL_EXPR:
		case ARRAY_ACCESS_EXPR:  // only reached for an rvalue vector element
		case BUILTIN_CONVERTVECTOR:
		case BUILTIN_SHUFFLEVECTOR:
		case BUILTIN_VA_ARG_PACK:
		case BUILTIN_VA_ARG_PACK_LEN:
			self.fail(string::tformat("TODO CodeGen.genExpr %s\n", node.kind.name))!;
			return ir::NONE;
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR:
			MemberBase member = self.gen_member_base(node_index)!;
			if (member.field.bit_width != type_store::BIT_WIDTH_NULL)
			{
				BitfieldLval lval = self.bitfield_lval(member.ptr, member.field, member.record_size, member.is_volatile)!;
				return self.load_bitfield(lval);
			}
			ir::Ref member_address = self.ptr_at(member.ptr, member.field.layout.offset_bits / 8);
			if (self.is_record_value(node_index.qt(self.tree))) return member_address;
			return self.builder.add_load(member_address, self.value_type(node_index.qt(self.tree))!, member.is_volatile);
		case CODEGEN_DIAGNOSTIC:
			return self.gen_codegen_diagnostic(node_index, node);
		default:
			unreachable("non-expression node %s in CodeGen.gen_expr", node.kind.name);
	}
	return ir::NONE;
}

<*
 `sizeof`/`alignof` whose folded value was not saved in the value map (the parser
 only saves operand values when an enclosing expression fails to fold, so
 `(void) sizeof (x)` from glibc `assert` and comma operands reach here). The
 operand is never evaluated. `sizeof` a VLA has no folded value: its size is
 computed at run time (evaluating the length expression on first use of the type).
*>
fn ir::Ref? CodeGen.gen_type_info_constant(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	type_store::QualType operand_qt = node.type_info.operand_qt;
	if (node.kind == tree::NodeKind.SIZEOF_EXPR && !@ok(operand_qt.sizeof_or_null(self.comp)))
	{
		ir::Ref size = self.gen_type_size(operand_qt)!;
		type_store::QualType result_qt = node_index.qt(self.tree);
		if (result_qt.bit_sizeof(self.comp) == 64) return size;
		return self.builder.add_inst(ir::InstTag.TRUNC, { .ref = size }, self.value_type(result_qt)!);
	}
	ulong amount = node.kind == tree::NodeKind.SIZEOF_EXPR ? operand_qt.sizeof(self.comp) : (ulong)operand_qt.alignof(self.comp);
	return self.builder.add_constant(value::int_u64(amount, self.comp).ref(), self.gen_type(node_index.qt(self.tree))!);
}

<* `gen_expr` case VARIABLE. *>
fn ir::Ref? CodeGen.gen_variable(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	self.gen_runtime_type(node.variable.qt)!;
	if (node.variable.storage_class == tree::VariableStorageClass.EXTERN || node.variable.storage_class == tree::VariableStorageClass.STATIC)
	{
		self.gen_var(node.variable, node_index)!;
		return ir::NONE;
	}
	ulong? fixed_size = node.variable.qt.sizeof_or_null(self.comp);
	uint alignment = (uint)node.variable.qt.alignof(self.comp);
	ir::Ref alloc;
	if (catch fixed_size)
	{
		// VLA: allocate at runtime, freed when the enclosing compound statement ends.
		self.enter_vla_scope();
		ir::Ref vla_size = self.gen_type_size(node.variable.qt)!;
		alloc = self.builder.add_dyn_alloc(vla_size, alignment);
	}
	else
	{
		alloc = self.builder.add_alloc((uint)self.object_size(node.variable.qt), alignment,
			self.type_contains_volatile(node.variable.qt));
	}
	string_interner::StringId name = self.comp.intern_string(self.tree.tok_slice(node.variable.name_tok));
	self.symbols.push(
		{
			.name = name, .value = alloc
		}
	);
	if (!node.variable.initializer.is_null())
	{
		self.gen_initializer(alloc, node.variable.qt, node.variable.initializer.unwrap())!;
	}
	return ir::NONE;
}

<* `gen_expr` case LABELED_STMT. *>
fn ir::Ref? CodeGen.gen_labeled_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	sz label_index = self.goto_label(node.labeled_stmt.label_tok);
	GotoLabel* label = &self.goto_labels[label_index];
	label.defined = true;
	label.saves_start = self.snapshot_vla_saves();
	label.saves_len = self.vla_scopes.len();
	self.builder.start_block(label.label);
	self.gen_stmt(node.labeled_stmt.body)!;
	return ir::NONE;
}

<* `gen_expr` case COMPOUND_STMT. *>
fn ir::Ref? CodeGen.gen_compound_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	// Declarations of this block go out of scope at its end: symbols are found by
	// name, so a leftover inner `arg` would shadow an outer `arg` declared before
	// the block in later statements (chibicc preprocess.c `subst`).
	sz old_symbol_count = self.symbols.len();
	defer while (self.symbols.len() > old_symbol_count) self.symbols.pop()!!;
	type_store::NodeIndex old_compound = self.current_compound;
	defer self.current_compound = old_compound;
	self.current_compound = node_index;
	sz vla_depth = self.vla_scopes.len();
	foreach (stmt : node.compound_stmt.body) self.gen_stmt(stmt)!;
	if (self.vla_scopes.len() > vla_depth)
	{
		self.builder.add_stack_restore(self.vla_scopes[vla_depth].saved);
		while (self.vla_scopes.len() > vla_depth) self.vla_scopes.pop()!!;
	}
	return ir::NONE;
}

<* static_condition: the condition's value is only known at run time. *>
faultdef NOT_STATIC_CONDITION;

<*
 A condition whose truth is known at compile time: a folded constant, or an
 ordered compare no value satisfies (`x > +inf`, `+inf < x`, `x < -inf`,
 `-inf > x`) whose other operand has no side effects. gcc folds the latter
 (aro does not model FP exceptions); the tree keeps no value for it, so it is
 not an integer constant expression.
*>
fn bool? CodeGen.static_condition(&self, type_store::NodeIndex base)
{
	type_store::NodeIndex node = base;
	while (node.get(self.tree).kind == tree::NodeKind.PAREN_EXPR) node = node.get(self.tree).unary.operand;
	if (try folded = self.tree.value_of(node))
	{
		if (!folded.is_pointer(self.comp)) return folded.to_bool(self.comp);
		return NOT_STATIC_CONDITION~;
	}
	tree::Node n = node.get(self.tree);
	if (n.kind != tree::NodeKind.GREATER_THAN_EXPR && n.kind != tree::NodeKind.LESS_THAN_EXPR) return NOT_STATIC_CONDITION~;
	if (!n.binary.lhs.qt(self.tree).is(self.comp, type_store::TypeTag.FLOAT)) return NOT_STATIC_CONDITION~;
	value::IsInfKind lhs_inf = self.inf_kind(n.binary.lhs);
	value::IsInfKind rhs_inf = self.inf_kind(n.binary.rhs);
	bool greater = n.kind == tree::NodeKind.GREATER_THAN_EXPR;
	// `a > b` is never true when b is +inf or a is -inf; `a < b` mirrors that.
	value::IsInfKind never_rhs = greater ? value::IsInfKind.POSITIVE : value::IsInfKind.NEGATIVE;
	value::IsInfKind never_lhs = greater ? value::IsInfKind.NEGATIVE : value::IsInfKind.POSITIVE;
	if (rhs_inf == never_rhs && self.is_side_effect_free(n.binary.lhs)) return false;
	if (lhs_inf == never_lhs && self.is_side_effect_free(n.binary.rhs)) return false;
	return NOT_STATIC_CONDITION~;
}

<* Infinity sign of a constant operand (through casts), else UNKNOWN. *>
fn value::IsInfKind CodeGen.inf_kind(&self, type_store::NodeIndex node)
{
	if (try v = self.tree.value_of(node)) return v.is_inf_sign(self.comp);
	return value::IsInfKind.UNKNOWN;
}

<* A constant or a plain variable read, through parens and casts. *>
fn bool CodeGen.is_side_effect_free(&self, type_store::NodeIndex base)
{
	type_store::NodeIndex node = base;
	while (true)
	{
		if (@ok(self.tree.value_of(node))) return true;
		tree::Node n = node.get(self.tree);
		switch (n.kind)
		{
			case PAREN_EXPR: node = n.unary.operand;
			case CAST: node = n.cast.operand;
			case DECL_REF_EXPR: return !self.type_contains_volatile(n.decl_ref.qt);
			default: return false;
		}
	}
}

<* Whether a statement may define a label or a switch case, which keeps a
   dead branch reachable by goto or switch. Unknown statements answer true. *>
fn bool CodeGen.may_contain_label(&self, type_store::NodeIndex node_index)
{
	tree::Node n = node_index.get(self.tree);
	switch (n.kind)
	{
		case COMPOUND_STMT:
			foreach (stmt : n.compound_stmt.body) if (self.may_contain_label(stmt)) return true;
			return false;
		case IF_STMT:
			if (self.may_contain_label(n.if_stmt.then_body)) return true;
			return !n.if_stmt.else_body.is_null() && self.may_contain_label(n.if_stmt.else_body.unwrap());
		case WHILE_STMT: return self.may_contain_label(n.while_stmt.body);
		case DO_WHILE_STMT: return self.may_contain_label(n.do_while_stmt.body);
		case FOR_STMT: return self.may_contain_label(n.for_stmt.body);
		case LABELED_STMT:
		case CASE_STMT:
		case DEFAULT_STMT:
		case SWITCH_STMT:
			return true;
		default:
			// Expressions and simple statements (return, break, goto, ...). A
			// label inside a GNU statement expression cannot be jumped into.
			return false;
	}
}

<* `gen_expr` case IF_STMT. *>
fn ir::Ref? CodeGen.gen_if_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	// A branch that can never run is not generated when nothing can jump
	// into it (gcc and clang do this at -O0 too: `if (0) link_error();`).
	if (node.if_stmt.init.is_null())
	{
		if (try known = self.static_condition(node.if_stmt.cond))
		{
			type_store::NodeOptIndex dead = known ? node.if_stmt.else_body : (type_store::NodeOptIndex)node.if_stmt.then_body;
			if (dead.is_null() || !self.may_contain_label(dead.unwrap()))
			{
				if (known)
				{
					self.gen_stmt(node.if_stmt.then_body)!;
				}
				else if (!node.if_stmt.else_body.is_null())
				{
					self.gen_stmt(node.if_stmt.else_body.unwrap())!;
				}
				// Code after an arm that returned or jumped goes in a fresh
				// (unreachable) block, as after an ordinary if.
				if (self.builder.block_terminated()) self.builder.start_block(self.builder.make_label("if.end"));
				return ir::NONE;
			}
		}
	}
	ir::Ref then_label = self.builder.make_label("if.then");
	if (node.if_stmt.else_body.is_null())
	{
		ir::Ref end_label = self.builder.make_label("if.end");
		self.gen_cond_branch(node.if_stmt.cond, then_label, end_label)!;
		self.builder.start_block(then_label);
		self.gen_stmt(node.if_stmt.then_body)!;
		self.builder.start_block(end_label);
		return ir::NONE;
	}
	ir::Ref else_label = self.builder.make_label("if.else");
	ir::Ref end_label = self.builder.make_label("if.end");
	self.gen_cond_branch(node.if_stmt.cond, then_label, else_label)!;
	self.builder.start_block(then_label);
	self.gen_stmt(node.if_stmt.then_body)!;
	self.builder.add_jump(end_label);
	self.builder.start_block(else_label);
	self.gen_stmt(node.if_stmt.else_body.unwrap())!;
	self.builder.start_block(end_label);
	return ir::NONE;
}

<* `gen_expr` case SWITCH_STMT. *>
fn ir::Ref? CodeGen.gen_switch_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	WipSwitch wip_switch = {
		.cases = {},
		.size = node.switch_stmt.cond.qt(self.tree).sizeof(self.comp),
	};
	wip_switch.cases.init(self.comp.gpa);
	defer wip_switch.cases.free();
	WipSwitch* old_wip_switch = self.wip_switch;
	defer self.wip_switch = old_wip_switch;
	self.wip_switch = &wip_switch;
	ir::Ref old_break_label = self.break_label;
	defer self.break_label = old_break_label;
	sz old_break_vla_depth = self.break_vla_depth;
	defer self.break_vla_depth = old_break_vla_depth;
	self.break_vla_depth = self.vla_scopes.len();
	ir::Ref end_label = self.builder.make_label("switch.end");
	self.break_label = end_label;
	ir::Ref cond = self.gen_expr(node.switch_stmt.cond)!;
	ir::Ref switch_ref = self.builder.add_inst(ir::InstTag.SWITCH, { .none = 0 }, value_interner::REF_NORETURN);
	self.gen_stmt(node.switch_stmt.body)!;
	ir::Ref default_label = wip_switch.has_default ? wip_switch.default_label : end_label;
	self.builder.start_block(end_label);
	sz case_count = wip_switch.cases.len();
	value_interner::InternerRef[] case_values = alloc::new_array(&self.builder.arena, value_interner::InternerRef, case_count);
	ir::Ref[] case_labels = alloc::new_array(&self.builder.arena, ir::Ref, case_count);
	foreach (i, switch_case : wip_switch.cases)
	{
		case_values[i] = switch_case.value;
		case_labels[i] = switch_case.label;
	}
	ir::Inst* switch_inst = self.builder.instructions.get_ref((sz)switch_ref);
	switch_inst.data.switch_data = { .target = cond, .values = case_values, .labels = case_labels, .default_label = default_label };
	return ir::NONE;
}

<* `gen_expr` case CASE_STMT. *>
fn ir::Ref? CodeGen.gen_case_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
=> self.gen_case_labels(node);

<* `gen_expr` case DEFAULT_STMT. *>
fn ir::Ref? CodeGen.gen_default_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
=> self.gen_case_labels(node);

<* Chained `case`/`default` labels in a loop, then the innermost statement once,
   so label count does not grow the stack. *>
fn ir::Ref? CodeGen.gen_case_labels(&self, tree::Node node)
{
	while (true)
	{
		type_store::NodeIndex body;
		if (node.kind == tree::NodeKind.CASE_STMT)
		{
			if (!node.case_stmt.end.is_null())
			{
				self.fail("TODO CodeGen.genStmt case range\n")!;
				return ir::NONE;
			}
			value::Value case_value = self.tree.value_of(node.case_stmt.start)!!;
			ir::Ref case_label = self.builder.make_label("case");
			self.builder.start_block(case_label);
			self.wip_switch.cases.push(
				{
					.value = case_value.ref(), .label = case_label
			}
			);
			body = node.case_stmt.body;
		}
		else
		{
			ir::Ref default_label = self.builder.make_label("default");
			self.builder.start_block(default_label);
			self.wip_switch.has_default = true;
			self.wip_switch.default_label = default_label;
			body = node.default_stmt.body;
		}
		tree::Node next = body.get(self.tree);
		if (next.kind != tree::NodeKind.CASE_STMT && next.kind != tree::NodeKind.DEFAULT_STMT)
		{
			self.gen_stmt(body)!;
			return ir::NONE;
		}
		node = next;
	}
}

<* `gen_expr` case WHILE_STMT. *>
fn ir::Ref? CodeGen.gen_while_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	ir::Ref old_break_label = self.break_label;
	defer self.break_label = old_break_label;
	sz old_break_vla_depth = self.break_vla_depth;
	defer self.break_vla_depth = old_break_vla_depth;
	self.break_vla_depth = self.vla_scopes.len();
	ir::Ref old_continue_label = self.continue_label;
	defer self.continue_label = old_continue_label;
	sz old_continue_vla_depth = self.continue_vla_depth;
	defer self.continue_vla_depth = old_continue_vla_depth;
	self.continue_vla_depth = self.vla_scopes.len();
	ir::Ref cond_label = self.builder.make_label("while.cond");
	ir::Ref body_label = self.builder.make_label("while.then");
	ir::Ref end_label = self.builder.make_label("while.end");
	self.continue_label = cond_label;
	self.break_label = end_label;
	self.builder.start_block(cond_label);
	self.gen_cond_branch(node.while_stmt.cond, body_label, end_label)!;
	self.builder.start_block(body_label);
	self.gen_stmt(node.while_stmt.body)!;
	self.builder.add_jump(cond_label);
	self.builder.start_block(end_label);
	return ir::NONE;
}

<* `gen_expr` case DO_WHILE_STMT. *>
fn ir::Ref? CodeGen.gen_do_while_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	ir::Ref old_break_label = self.break_label;
	defer self.break_label = old_break_label;
	sz old_break_vla_depth = self.break_vla_depth;
	defer self.break_vla_depth = old_break_vla_depth;
	self.break_vla_depth = self.vla_scopes.len();
	ir::Ref old_continue_label = self.continue_label;
	defer self.continue_label = old_continue_label;
	sz old_continue_vla_depth = self.continue_vla_depth;
	defer self.continue_vla_depth = old_continue_vla_depth;
	self.continue_vla_depth = self.vla_scopes.len();
	ir::Ref body_label = self.builder.make_label("do.then");
	ir::Ref cond_label = self.builder.make_label("do.cond");
	ir::Ref end_label = self.builder.make_label("do.end");
	self.continue_label = cond_label;
	self.break_label = end_label;
	self.builder.start_block(body_label);
	self.gen_stmt(node.do_while_stmt.body)!;
	self.builder.start_block(cond_label);
	self.gen_cond_branch(node.do_while_stmt.cond, body_label, end_label)!;
	self.builder.start_block(end_label);
	return ir::NONE;
}

<* `gen_expr` case FOR_STMT. *>
fn ir::Ref? CodeGen.gen_for_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	ir::Ref old_break_label = self.break_label;
	defer self.break_label = old_break_label;
	sz old_break_vla_depth = self.break_vla_depth;
	defer self.break_vla_depth = old_break_vla_depth;
	self.break_vla_depth = self.vla_scopes.len();
	ir::Ref old_continue_label = self.continue_label;
	defer self.continue_label = old_continue_label;
	sz old_continue_vla_depth = self.continue_vla_depth;
	defer self.continue_vla_depth = old_continue_vla_depth;
	self.continue_vla_depth = self.vla_scopes.len();
	// `for (int i = ...)`: the declaration's scope ends with the loop.
	sz old_symbol_count = self.symbols.len();
	defer while (self.symbols.len() > old_symbol_count) self.symbols.pop()!!;
	if (!node.for_stmt.init.is_null()) self.gen_stmt(node.for_stmt.init.unwrap())!;
	if (node.for_stmt.cond.is_null())
	{
		ir::Ref body_label = self.builder.make_label("for.then");
		ir::Ref end_label = self.builder.make_label("for.end");
		// `continue` must still run the increment (Zig CodeGen jumps to for.then,
		// skipping it), so it targets a for.cont block when there is one.
		ir::Ref no_cond_continue = body_label;
		if (!node.for_stmt.incr.is_null()) no_cond_continue = self.builder.make_label("for.cont");
		self.continue_label = no_cond_continue;
		self.break_label = end_label;
		self.builder.start_block(body_label);
		self.gen_stmt(node.for_stmt.body)!;
		if (!node.for_stmt.incr.is_null())
		{
			self.builder.start_block(no_cond_continue);
			self.gen_expr(node.for_stmt.incr.unwrap())!;
		}
		self.builder.add_jump(body_label);
		self.builder.start_block(end_label);
		return ir::NONE;
	}
	ir::Ref body_label = self.builder.make_label("for.then");
	ir::Ref continue_label = self.builder.make_label("for.cont");
	ir::Ref end_label = self.builder.make_label("for.end");
	self.continue_label = continue_label;
	self.break_label = end_label;
	ir::Ref cond_label = self.builder.make_label("for.cond");
	self.builder.start_block(cond_label);
	self.gen_cond_branch(node.for_stmt.cond.unwrap(), body_label, end_label)!;
	self.builder.start_block(body_label);
	self.gen_stmt(node.for_stmt.body)!;
	// Zig CodeGen makes for.cont but never starts it, leaving `continue` jumping
	// to an undefined label; the increment lives in that block.
	self.builder.start_block(continue_label);
	if (!node.for_stmt.incr.is_null()) self.gen_expr(node.for_stmt.incr.unwrap())!;
	self.builder.add_jump(cond_label);
	self.builder.start_block(end_label);
	return ir::NONE;
}

<* `gen_expr` case RETURN_STMT. *>
fn ir::Ref? CodeGen.gen_return_stmt(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	if (self.aggregate_return)
	{
		switch (node.return_stmt.operand)
		{
			case EXPR:
				ir::Ref result = self.gen_expr(node.return_stmt.expr)!;
				if (self.aggregate_return_class == AggClass.MEMORY)
				{
					self.gen_copy(self.sret_pointer, result, self.aggregate_return_size)!;
				}
				else if (self.aggregate_return_class == AggClass.REGISTER || self.aggregate_return_class == AggClass.X87 ||
					self.aggregate_return_class == AggClass.VECTOR128)
				{
					self.gen_copy_value(self.aggregate_return_slot, result, self.aggregate_return_qt)!;
				}
			case NONE:
			case IMPLICIT:
				break;
		}
		self.builder.add_jump(self.return_label);
		return ir::NONE;
	}
	switch (node.return_stmt.operand)
	{
		case EXPR:
			ir::Ref result = self.gen_expr(node.return_stmt.expr)!;
			// Unreachable code after a terminator (`return f(); return 0;`) adds
			// no edge to the return block, so it must not add a PHI input either.
			if (!self.builder.block_terminated())
			{
				self.ret_nodes.push(
					{
						.value = result, .label = self.builder.current_label
					}
				);
			}
		case NONE:
			break;
		case IMPLICIT:
			if ((node.return_stmt.implicit_value || self.is_int_main(node.return_stmt.return_qt)) &&
				!self.builder.block_terminated())
			{
				ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.return_stmt.return_qt)!);
				self.ret_nodes.push(
					{
						.value = zero, .label = self.builder.current_label
					}
				);
			}
			return ir::NONE;
	}
	self.builder.add_jump(self.return_label);
	return ir::NONE;
}

<* C99 5.1.2.2.3: reaching the `}` of `int main` returns 0. The parser sets
   `implicit_value` only when the last statement plainly falls through; after a
   trailing loop, switch or goto the end can still be reached. *>
fn bool CodeGen.is_int_main(&self, type_store::QualType return_qt)
{
	if (self.current_fn != "main") return false;
	type_store::Type? maybe_int = return_qt.get(self.comp, type_store::TypeTag.INT);
	if (try int_type = maybe_int) return int_type.int_ty == type_store::TypeInt.INT;
	return false;
}

<* `gen_expr` case ADD_EXPR. *>
fn ir::Ref? CodeGen.gen_add_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	if (node.binary.qt.is(self.comp, type_store::TypeTag.POINTER))
	{
		type_store::QualType lhs_type = node.binary.lhs.qt(self.tree);
		if (lhs_type.is(self.comp, type_store::TypeTag.POINTER))
		{
			return self.gen_ptr_arithmetic(self.gen_expr(node.binary.lhs)!, self.gen_expr(node.binary.rhs)!, node.binary.rhs.qt(self.tree), node.binary.qt, false);
		}
		ir::Ref offset = self.gen_expr(node.binary.lhs)!;
		ir::Ref ptr = self.gen_expr(node.binary.rhs)!;
		return self.gen_ptr_arithmetic(ptr, offset, lhs_type, node.binary.qt, false);
	}
	if (node.binary.qt.is(self.comp, type_store::TypeTag.FLOAT))
	{
		self.ensure_scalar_float_width(node.binary.qt)!;
		return self.gen_bin_op(node.binary, ir::InstTag.FADD);
	}
	return self.gen_bin_op(node.binary, ir::InstTag.ADD);
}

<* `gen_expr` case SUB_EXPR. *>
fn ir::Ref? CodeGen.gen_sub_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	{
		type_store::QualType lhs_type = node.binary.lhs.qt(self.tree);
		type_store::QualType rhs_type = node.binary.rhs.qt(self.tree);
		if (lhs_type.is_pointer(self.comp) && rhs_type.is_pointer(self.comp))
		{
			return self.gen_ptr_difference(self.gen_expr(node.binary.lhs)!, self.gen_expr(node.binary.rhs)!, lhs_type, node.binary.qt);
		}
		if (lhs_type.is_pointer(self.comp))
		{
			return self.gen_ptr_arithmetic(self.gen_expr(node.binary.lhs)!, self.gen_expr(node.binary.rhs)!, rhs_type, lhs_type, true);
		}
	}
	if (node.binary.qt.is(self.comp, type_store::TypeTag.FLOAT))
	{
		self.ensure_scalar_float_width(node.binary.qt)!;
		return self.gen_bin_op(node.binary, ir::InstTag.FSUB);
	}
	return self.gen_bin_op(node.binary, ir::InstTag.SUB);
}

<* `gen_expr` case DEREF_EXPR. *>
fn ir::Ref? CodeGen.gen_deref_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	tree::Node operand_node = node.unary.operand.get(self.tree);
	if (operand_node.kind == tree::NodeKind.CAST && operand_node.cast.kind == tree::CastKind.FUNCTION_TO_POINTER)
	{
		return self.gen_expr(node.unary.operand);
	}
	if (self.is_record_value(node.unary.qt)) return self.gen_lval(node_index);
	return self.builder.add_load(self.gen_lval(node.unary.operand)!, self.gen_type(node.unary.qt)!,
		self.access_is_volatile(node.unary.qt));
}

<* `gen_expr` case BOOL_NOT_EXPR. *>
fn ir::Ref? CodeGen.gen_bool_not_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	// Keep logical-not as an i1 equality comparison; Zig's `cmp_ne 0, x` form
	// has the wrong operand order for this IR and inverts the result.
	ir::Ref operand = self.gen_expr(node.unary.operand)!;
	type_store::QualType operand_type = node.unary.operand.qt(self.tree);
	if (operand_type.is(self.comp, type_store::TypeTag.FLOAT)) self.ensure_scalar_float_width(operand_type)!;
	ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(operand_type)!);
	ir::InstTag compare = operand_type.is(self.comp, type_store::TypeTag.FLOAT) ? ir::InstTag.FCMP_OEQ : ir::InstTag.CMP_EQ;
	ir::Ref is_zero = self.builder.add_inst(compare, { .bin = { .lhs = operand, .rhs = zero } }, value_interner::REF_I1);
	return self.add_un(ir::InstTag.ZEXT, is_zero, node.unary.qt);
}

<* `gen_expr` case PRE_INC_EXPR, PRE_DEC_EXPR, POST_INC_EXPR, POST_DEC_EXPR. *>
fn ir::Ref? CodeGen.gen_pre_inc_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	if (self.is_bitfield_lvalue(node.unary.operand))
	{
		MemberBase member = self.gen_member_base(node.unary.operand)!;
		BitfieldLval lval = self.bitfield_lval(member.ptr, member.field, member.record_size, member.is_volatile)!;
		ir::Ref old_value = self.load_bitfield(lval)!;
		ir::Ref one = self.builder.add_constant(value::ONE.ref(), self.gen_type(node.unary.qt)!);
		bool decrement = node.kind == tree::NodeKind.PRE_DEC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR;
		ir::Ref updated = self.add_bin(decrement ? ir::InstTag.SUB : ir::InstTag.ADD, old_value, one, node.unary.qt)!;
		ir::Ref stored = self.store_bitfield(lval, updated)!;
		return (node.kind == tree::NodeKind.POST_INC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR) ? old_value : stored;
	}
	bool is_float = node.unary.qt.is(self.comp, type_store::TypeTag.FLOAT);
	if (is_float) self.ensure_scalar_float_width(node.unary.qt)!;
	if (try atomic = self.gen_atomic_inc_dec(node)) return atomic;
	ir::Ref addr = self.gen_lval(node.unary.operand)!;
	bool access_volatile = self.access_is_volatile(node.unary.operand.qt(self.tree));
	ir::Ref val = self.builder.add_load(addr, self.gen_type(node.unary.qt)!, access_volatile);
	bool decrement = node.kind == tree::NodeKind.PRE_DEC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR;
	bool is_post = node.kind == tree::NodeKind.POST_INC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR;
	if (node.unary.qt.is_pointer(self.comp))
	{
		// Pointer step is one element, not one byte.
		ir::Ref step = self.builder.add_constant(value::ONE.ref(), value_interner::REF_I64);
		ir::Ref moved = self.gen_ptr_arithmetic(val, step, type_store::LONG, node.unary.qt, decrement)!;
		self.builder.add_store(addr, moved, access_volatile);
		return is_post ? val : moved;
	}
	ir::Ref one = self.builder.add_constant(value::ONE.ref(), self.gen_type(node.unary.qt)!);
	ir::InstTag update = is_float ? (decrement ? ir::InstTag.FSUB : ir::InstTag.FADD) :
		(decrement ? ir::InstTag.SUB : ir::InstTag.ADD);
	ir::Ref updated = self.add_bin(update, val, one, node.unary.qt)!;
	self.builder.add_store(addr, updated, access_volatile);
	return is_post ? val : updated;
}

<* `++`/`--` on an `_Atomic` integer or pointer: one `lock xadd`. *>
fn ir::Ref? CodeGen.gen_atomic_inc_dec(&self, tree::Node node)
{
	type_store::QualType operand_qt = node.unary.operand.qt(self.tree);
	if (!operand_qt.is(self.comp, type_store::TypeTag.ATOMIC)) return NOT_ATOMIC_COMPOUND~;
	type_store::QualType value_qt = operand_qt.non_atomic(self.comp).unqualified();
	bool is_pointer = value_qt.is_pointer(self.comp);
	if (!value_qt.is_int(self.comp) && !is_pointer) return NOT_ATOMIC_COMPOUND~;
	uint bits = (uint)value_qt.bit_sizeof(self.comp);
	if (bits != 8 && bits != 16 && bits != 32 && bits != 64) return NOT_ATOMIC_COMPOUND~;
	value_interner::InternerRef value_ty = self.gen_type(value_qt)!;
	if (value_ty == value_interner::REF_I1) return NOT_ATOMIC_COMPOUND~;
	value_interner::InternerRef op_ty = is_pointer ? value_interner::REF_I64 : value_ty;
	ulong step = 1;
	if (is_pointer)
	{
		if (try size = value_qt.child_type(self.comp).sizeof_or_null(self.comp)) step = size;
	}
	bool decrement = node.kind == tree::NodeKind.PRE_DEC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR;
	bool is_post = node.kind == tree::NodeKind.POST_INC_EXPR || node.kind == tree::NodeKind.POST_DEC_EXPR;
	ir::Ref ptr = self.gen_lval(node.unary.operand)!;
	ir::Ref delta = self.builder.add_constant(value::int_u64(step, self.comp).ref(), op_ty);
	ir::Ref old = self.atomic_intrinsic_call(decrement ? "sub" : "add", bits, { ptr, delta }, op_ty);
	ir::Ref result = old;
	if (!is_post) result = self.builder.add_inst(decrement ? ir::InstTag.SUB : ir::InstTag.ADD, { .bin = { .lhs = old, .rhs = delta } }, op_ty);
	if (is_pointer) result = self.builder.add_inst(ir::InstTag.ZEXT, { .ref = result }, value_interner::REF_PTR);
	return result;
}

<* The text of a string-literal node (asm template, constraint, clobber). *>
fn String? CodeGen.asm_string(&self, type_store::NodeIndex node)
{
	value::Value? val = self.tree.value_of(node);
	if (catch val)
	{
		self.fail("TODO CodeGen inline asm: string operand has no value\n")!;
		return compilation::FATAL_ERROR~;
	}
	if (!val.is(primitive_value::PrimitiveType.BYTES, self.comp))
	{
		self.fail("TODO CodeGen inline asm: operand is not a string literal\n")!;
		return compilation::FATAL_ERROR~;
	}
	String bytes = (String)val.to_bytes(self.comp);
	if (bytes.len > 0 && bytes[^1] == 0) bytes = bytes[:bytes.len - 1];
	return bytes.copy(&self.builder.arena);
}

<* GNU inline asm: a CALL to the reserved symbol of an ir::AsmBlock that holds
   the template and constraints. Inputs are passed by value (by address for
   memory-only constraints), outputs by the address of their lvalue. *>
fn ir::Ref? CodeGen.gen_asm(&self, tree::NodeAsmStmt asm_stmt)
{
	if (asm_stmt.labels.len != 0)
	{
		self.fail("TODO CodeGen inline asm goto\n")!;
		return ir::NONE;
	}
	String template = self.asm_string(asm_stmt.asm_str)!;
	List{ir::Ref} args;
	args.init(&self.builder.arena);
	List{ir::AsmOperand} operands;
	operands.init(&self.builder.arena);
	foreach (out : asm_stmt.outputs)
	{
		String raw = self.asm_string(out.constraint)!;
		type_store::QualType qt = out.expr.qt(self.tree);
		ir::AsmOperand op = {
			.constraint = asm_constraint_letters(raw),
			.name = out.name == 0 ? "" : self.tree.tok_slice(out.name),
			.arg = (uint)args.len(),
			.is_output = true,
			.read_write = raw.contains("+"),
			.by_address = true,
			.size = (uint)(qt.sizeof_or_null(self.comp) ?? 8),
			.is_float = qt.is(self.comp, type_store::TypeTag.FLOAT),
		};
		args.push(self.gen_lval(out.expr)!);
		operands.push(op);
	}
	foreach (input : asm_stmt.inputs)
	{
		String raw = self.asm_string(input.constraint)!;
		String letters = asm_constraint_letters(raw);
		type_store::QualType qt = input.expr.qt(self.tree);
		bool memory_only = false;
		foreach (c : letters) if (c == 'm' || c == 'o' || c == 'V' || c == 'p') memory_only = true;
		foreach (c : letters) if (c == 'r' || c == 'g' || c == 'q' || c == 'x' || (c >= '0' && c <= '9')) memory_only = false;
		ir::AsmOperand op = {
			.constraint = letters,
			.name = input.name == 0 ? "" : self.tree.tok_slice(input.name),
			.arg = (uint)args.len(),
			.by_address = memory_only,
			.size = (uint)(qt.sizeof_or_null(self.comp) ?? 8),
			.is_float = qt.is(self.comp, type_store::TypeTag.FLOAT),
		};
		ir::Ref arg;
		if (memory_only && self.tree.is_lval(input.expr))
		{
			arg = self.gen_lval(input.expr)!;
		}
		else if (memory_only)
		{
			ir::Ref value = self.gen_expr(input.expr)!;
			arg = self.builder.add_alloc(op.size, qt.alignof(self.comp));
			self.builder.add_store(arg, value);
		}
		else
		{
			arg = self.gen_expr(input.expr)!;
		}
		args.push(arg);
		operands.push(op);
	}
	List{String} clobbers;
	clobbers.init(&self.builder.arena);
	foreach (clobber : asm_stmt.clobbers) clobbers.push(self.asm_string(clobber)!);
	bool basic = asm_stmt.outputs.len == 0 && asm_stmt.inputs.len == 0 && asm_stmt.clobbers.len == 0;
	DString name;
	name.init(&self.builder.arena);
	name.appendf("__aro.asm.%s.%d", self.current_fn, self.builder.asm_blocks.len());
	if (self.tu_id >= 0) name.appendf(".tu%d", self.tu_id);
	self.builder.add_asm_block({
		.name = name.str_view(),
		.template = template,
		.operands = operands.array_view(),
		.clobbers = clobbers.array_view(),
		.basic = basic,
	});
	ir::Ref callee = self.builder.add_symbol(name.str_view(), value_interner::REF_PTR);
	self.builder.add_call(callee, args.array_view(), value_interner::REF_VOID);
	return ir::NONE;
}

<* Constraint letters without the `=`, `+`, `&`, `%` and `*` modifiers. *>
fn String asm_constraint_letters(String raw)
{
	DString out;
	out.init(tmem);
	foreach (c : raw)
	{
		if (c == '=' || c == '+' || c == '&' || c == '%' || c == '*' || c == ' ') continue;
		out.append_char(c);
	}
	return out.copy_str(tmem);
}

<* `gen_expr` case CAST. *>
fn ir::Ref? CodeGen.gen_cast(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	switch (node.cast.kind)
	{
		case NO_OP: return self.gen_expr(node.cast.operand);
		case BITCAST:
			if (node.cast.operand.qt(self.tree).is_pointer(self.comp) && node.cast.qt.is_pointer(self.comp))
			{
				return self.gen_expr(node.cast.operand);
			}
			self.fail("TODO CodeGen gen CastKind bitcast\n")!;
			return ir::NONE;
		case TO_VOID:
			self.gen_expr(node.cast.operand)!;
			return ir::NONE;
		case LVAL_TO_RVAL:
			if (self.is_record_value(node.cast.qt)) return self.gen_expr(node.cast.operand);
			if (self.is_bitfield_compound_dummy(node.cast.operand)) return self.compound_assign_dummy;
			if (self.is_bitfield_lvalue(node.cast.operand)) return self.gen_expr(node.cast.operand);
			return self.builder.add_load(self.gen_lval(node.cast.operand)!, self.gen_type(node.cast.qt)!,
				self.access_is_volatile(node.cast.operand.qt(self.tree)));
		case FUNCTION_TO_POINTER:
		case ARRAY_TO_POINTER: return self.gen_lval(node.cast.operand);
		case INT_CAST:
			ir::Ref operand = self.gen_expr(node.cast.operand)!;
			type_store::QualType src_type = node.cast.operand.qt(self.tree);
			ulong src_bits = src_type.bit_sizeof(self.comp);
			ulong dest_bits = node.cast.qt.bit_sizeof(self.comp);
			if (src_bits == dest_bits) return operand;
			if (src_bits < dest_bits)
			{
				return self.add_un(src_type.signedness(self.comp) == bigint::Signedness.UNSIGNED ? ir::InstTag.ZEXT : ir::InstTag.SEXT, operand, node.cast.qt);
			}
			return self.add_un(ir::InstTag.TRUNC, operand, node.cast.qt);
		case BOOL_TO_INT: return self.add_un(ir::InstTag.ZEXT, self.gen_expr(node.cast.operand)!, node.cast.qt);
		case POINTER_TO_BOOL:
		case INT_TO_BOOL:
		case FLOAT_TO_BOOL:
			type_store::QualType bool_source_type = node.cast.operand.qt(self.tree);
			bool float_to_bool = bool_source_type.is(self.comp, type_store::TypeTag.FLOAT);
			if (float_to_bool) self.ensure_scalar_float_width(bool_source_type)!;
			ir::Ref lhs = self.gen_expr(node.cast.operand)!;
			ir::Ref rhs = self.builder.add_constant(value::ZERO.ref(), self.gen_type(bool_source_type)!);
			ir::InstTag bool_compare = float_to_bool ? ir::InstTag.FCMP_UNE : ir::InstTag.CMP_NE;
			return self.builder.add_inst(bool_compare, { .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I1);
		case POINTER_TO_INT:
			// Pointers are 64-bit integers on x86_64, but the IR keeps `ptr` and
			// `i64` distinct (a PHI's inputs must match its type), so a full-width
			// cast is a same-width ZEXT (a plain move when lowered); narrower
			// targets truncate (`(int)(intptr_t)p`).
			ir::Ref pointer = self.gen_expr(node.cast.operand)!;
			if (node.cast.qt.bit_sizeof(self.comp) >= 64) return self.add_un(ir::InstTag.ZEXT, pointer, node.cast.qt);
			return self.add_un(ir::InstTag.TRUNC, pointer, node.cast.qt);
		case INT_TO_POINTER:
			// The result is `ptr`-typed (see POINTER_TO_INT): extend straight to it.
			ir::Ref integer = self.gen_expr(node.cast.operand)!;
			type_store::QualType int_type = node.cast.operand.qt(self.tree);
			ir::InstTag widen = int_type.bit_sizeof(self.comp) >= 64 ||
				int_type.signedness(self.comp) == bigint::Signedness.UNSIGNED ? ir::InstTag.ZEXT : ir::InstTag.SEXT;
			return self.builder.add_inst(widen, { .ref = integer }, value_interner::REF_PTR);
		case NULL_TO_POINTER:
			if (!node.cast.operand.qt(self.tree).is_pointer(self.comp)) self.gen_expr(node.cast.operand)!;
			return self.builder.add_constant(value::ZERO.ref(), value_interner::REF_PTR);
		case BOOL_TO_FLOAT:
			self.ensure_scalar_float_width(node.cast.qt)!;
			ir::Ref bool_as_int = self.add_un(ir::InstTag.ZEXT,
				self.gen_expr(node.cast.operand)!, type_store::INT)!;
			return self.add_un(ir::InstTag.SITOFP, bool_as_int, node.cast.qt);
		case BOOL_TO_POINTER:
			self.fail(string::tformat("TODO CodeGen gen CastKind %s\n", node.cast.kind.name))!;
			return ir::NONE;
		case INT_TO_FLOAT:
			self.ensure_scalar_float_width(node.cast.qt)!;
			ir::Ref int_to_float_operand = self.gen_expr(node.cast.operand)!;
			ir::InstTag int_to_float_tag = node.cast.operand.qt(self.tree).signedness(self.comp) == SIGNED ?
				ir::InstTag.SITOFP : ir::InstTag.UITOFP;
			return self.add_un(int_to_float_tag, int_to_float_operand, node.cast.qt);
		case COMPLEX_INT_TO_COMPLEX_FLOAT:
			self.fail(string::tformat("TODO CodeGen gen CastKind %s\n", node.cast.kind.name))!;
			return ir::NONE;
		case FLOAT_TO_INT:
			type_store::QualType float_to_int_source_type = node.cast.operand.qt(self.tree);
			self.ensure_scalar_float_width(float_to_int_source_type)!;
			ir::Ref float_to_int_operand = self.gen_expr(node.cast.operand)!;
			if (node.cast.qt.is(self.comp, type_store::TypeTag.BOOL))
			{
				ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(float_to_int_source_type)!);
				return self.builder.add_inst(ir::InstTag.FCMP_UNE,
					{ .bin = { .lhs = float_to_int_operand, .rhs = zero } }, value_interner::REF_I1);
			}
			ir::InstTag float_to_int_tag = node.cast.qt.signedness(self.comp) == SIGNED ?
				ir::InstTag.FPTOSI : ir::InstTag.FPTOUI;
			return self.add_un(float_to_int_tag, float_to_int_operand, node.cast.qt);
		case COMPLEX_FLOAT_TO_COMPLEX_INT:
		case COMPLEX_INT_CAST:
		case COMPLEX_INT_TO_REAL:
		case REAL_TO_COMPLEX_INT:
			self.fail(string::tformat("TODO CodeGen gen CastKind %s\n", node.cast.kind.name))!;
			return ir::NONE;
		case FLOAT_CAST:
			type_store::QualType float_cast_source_type = node.cast.operand.qt(self.tree);
			self.ensure_scalar_float_width(float_cast_source_type)!;
			self.ensure_scalar_float_width(node.cast.qt)!;
			ir::Ref float_cast_operand = self.gen_expr(node.cast.operand)!;
			ulong src_float_bits = float_cast_source_type.bit_sizeof(self.comp);
			ulong dest_float_bits = node.cast.qt.bit_sizeof(self.comp);
			if (src_float_bits == dest_float_bits) return float_cast_operand;
			return self.add_un(src_float_bits < dest_float_bits ? ir::InstTag.FPEXT : ir::InstTag.FPTRUNC,
				float_cast_operand, node.cast.qt);
		case COMPLEX_FLOAT_CAST:
		case COMPLEX_FLOAT_TO_REAL:
		case REAL_TO_COMPLEX_FLOAT:
		case UNION_CAST:
		case VECTOR_SPLAT:
			self.fail(string::tformat("TODO CodeGen gen CastKind %s\n", node.cast.kind.name))!;
			return ir::NONE;
		case ATOMIC_TO_NON_ATOMIC:
			// Reading an `_Atomic` object (C11 6.2.6.1p9/7.17.7.2): a seq_cst load.
			tree::Node atomic_operand = node.cast.operand.get(self.tree);
			if (atomic_operand.kind == tree::NodeKind.CAST && atomic_operand.cast.kind == tree::CastKind.LVAL_TO_RVAL &&
				self.is_bitfield_compound_dummy(atomic_operand.cast.operand))
			{
				return self.compound_assign_dummy;
			}
			if (atomic_operand.kind == tree::NodeKind.CAST && atomic_operand.cast.kind == tree::CastKind.LVAL_TO_RVAL &&
				!self.is_record_value(node.cast.qt))
			{
				ir::Ref atomic_ptr = self.gen_lval(atomic_operand.cast.operand)!;
				return self.builder.add_atomic_load(atomic_ptr, ir::AtomicOrder.SEQ_CST, self.gen_type(node.cast.qt)!);
			}
			return self.gen_expr(node.cast.operand);
		case NON_ATOMIC_TO_ATOMIC:
			// The representation is unchanged; stores through the object are atomic.
			return self.gen_expr(node.cast.operand);
	}
}

<* `gen_expr` case BINARY_COND_EXPR. *>
fn ir::Ref? CodeGen.gen_binary_cond_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	if (try cond = self.tree.value_of(node.conditional.cond))
	{
		if (cond.to_bool(self.comp))
		{
			self.cond_dummy_ref = self.gen_expr(node.conditional.cond)!;
			return self.gen_expr(node.conditional.then_expr);
		}
		return self.gen_expr(node.conditional.else_expr);
	}
	ir::Ref then_label = self.builder.make_label("ternary.then");
	ir::Ref else_label = self.builder.make_label("ternary.else");
	ir::Ref end_label = self.builder.make_label("ternary.end");
	// `c ?: e` yields c's own value, so evaluate it once as a value and branch on it.
	type_store::QualType cond_type = node.conditional.cond.qt(self.tree);
	ir::Ref cond_value = self.gen_expr(node.conditional.cond)!;
	ir::Ref truth = self.gen_truth_compare(cond_value, cond_type, false)!;
	self.add_branch(truth, then_label, else_label)!;
	self.builder.start_block(then_label);
	self.cond_dummy_ref = cond_value;
	ir::Ref then_val = self.gen_expr(node.conditional.then_expr)!;
	self.builder.add_jump(end_label);
	ir::Ref then_exit = self.builder.current_label;
	self.builder.start_block(else_label);
	ir::Ref else_val = self.gen_expr(node.conditional.else_expr)!;
	ir::Ref else_exit = self.builder.current_label;
	self.builder.start_block(end_label);
	// A void conditional has no value to merge (arms may be `(void)0`).
	if (node.conditional.qt.is(self.comp, type_store::TypeTag.VOID)) return ir::NONE;
	ir::PhiInput[2] conditional_inputs = {
		{
			.value = then_val, .label = then_exit
		}
		, { .value = else_val, .label = else_exit },
	};
	return self.builder.add_phi(conditional_inputs[..], self.value_type(node.conditional.qt)!);
}

<* `gen_expr` case COND_EXPR. *>
fn ir::Ref? CodeGen.gen_cond_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	if (try cond = self.tree.value_of(node.conditional.cond))
	{
		return self.gen_expr(cond.to_bool(self.comp) ? node.conditional.then_expr: node.conditional.else_expr);
	}
	ir::Ref then_label = self.builder.make_label("ternary.then");
	ir::Ref else_label = self.builder.make_label("ternary.else");
	ir::Ref end_label = self.builder.make_label("ternary.end");
	self.gen_cond_branch(node.conditional.cond, then_label, else_label)!;
	self.builder.start_block(then_label);
	ir::Ref then_val = self.gen_expr(node.conditional.then_expr)!;
	self.builder.add_jump(end_label);
	ir::Ref then_exit = self.builder.current_label;
	self.builder.start_block(else_label);
	ir::Ref else_val = self.gen_expr(node.conditional.else_expr)!;
	ir::Ref else_exit = self.builder.current_label;
	self.builder.start_block(end_label);
	// A void conditional has no value to merge (arms may be `(void)0`).
	if (node.conditional.qt.is(self.comp, type_store::TypeTag.VOID)) return ir::NONE;
	ir::PhiInput[2] conditional_inputs = {
		{
			.value = then_val, .label = then_exit
		}
		, { .value = else_val, .label = else_exit },
	};
	return self.builder.add_phi(conditional_inputs[..], self.value_type(node.conditional.qt)!);
}

<* `gen_expr` case BOOL_OR_EXPR. *>
fn ir::Ref? CodeGen.gen_bool_or_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	if (try lhs = self.tree.value_of(node.binary.lhs))
	{
		// `1 || x` is 1; `0 || x` is `x != 0`, built below (the folded lhs jumps).
		if (lhs.to_bool(self.comp)) return self.builder.add_constant(value::ONE.ref(), self.gen_type(node.binary.qt)!);
	}
	ir::Ref false_label = self.builder.make_label("bool_false");
	ir::Ref bool_exit_label = self.builder.make_label("bool_exit");
	ir::Ref old_bool_end_label = self.bool_end_label;
	defer self.bool_end_label = old_bool_end_label;
	self.bool_end_label = bool_exit_label;
	sz phi_top = self.phi_nodes.len();
	defer
	{
		while (self.phi_nodes.len() > phi_top) self.phi_nodes.pop()!!;
	}
	self.gen_bool_expr(node.binary.lhs, true_target(bool_exit_label), false_target(false_label))!;
	self.builder.start_block(false_label);
	self.gen_bool_expr(node.binary.rhs, true_target(bool_exit_label), false_target(bool_exit_label))!;
	self.builder.start_block(bool_exit_label);
	ir::PhiInput[] phi_inputs = self.phi_nodes.array_view()[phi_top..];
	ir::Ref phi = self.builder.add_phi(phi_inputs, value_interner::REF_I1);
	return self.add_un(ir::InstTag.ZEXT, phi, node.binary.qt);
}

<* `gen_expr` case BOOL_AND_EXPR. *>
fn ir::Ref? CodeGen.gen_bool_and_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	if (try lhs = self.tree.value_of(node.binary.lhs))
	{
		// `0 && x` is 0; `1 && x` is `x != 0`, built below (the folded lhs jumps).
		if (!lhs.to_bool(self.comp)) return self.builder.add_constant(value::ZERO.ref(), self.gen_type(node.binary.qt)!);
	}
	ir::Ref true_label = self.builder.make_label("bool_true");
	ir::Ref bool_exit_label = self.builder.make_label("bool_exit");
	ir::Ref old_bool_end_label = self.bool_end_label;
	defer self.bool_end_label = old_bool_end_label;
	self.bool_end_label = bool_exit_label;
	sz phi_top = self.phi_nodes.len();
	defer
	{
		while (self.phi_nodes.len() > phi_top) self.phi_nodes.pop()!!;
	}
	self.gen_bool_expr(node.binary.lhs, true_target(true_label), false_target(bool_exit_label))!;
	self.builder.start_block(true_label);
	self.gen_bool_expr(node.binary.rhs, true_target(bool_exit_label), false_target(bool_exit_label))!;
	self.builder.start_block(bool_exit_label);
	ir::PhiInput[] phi_inputs = self.phi_nodes.array_view()[phi_top..];
	ir::Ref phi = self.builder.add_phi(phi_inputs, value_interner::REF_I1);
	return self.add_un(ir::InstTag.ZEXT, phi, node.binary.qt);
}

<* `gen_expr` case STMT_EXPR. *>
fn ir::Ref? CodeGen.gen_stmt_expr(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	tree::Node compound = node.unary.operand.get(self.tree);
	sz old_symbol_count = self.symbols.len();
	defer
	{
		// The statement expression's block scope ends here.
		while (self.symbols.len() > old_symbol_count) self.symbols.pop()!!;
	}
	type_store::NodeIndex[] body = compound.compound_stmt.body;
	// `({})` is a void expression.
	if (body.len == 0) return ir::NONE;
	for (usz i = 0; i + 1 < body.len; i++) self.gen_stmt(body[i])!;
	return self.gen_expr(body[^1]);
}

<* `gen_expr` case CODEGEN_DIAGNOSTIC. *>
fn ir::Ref? CodeGen.gen_codegen_diagnostic(&self, type_store::NodeIndex node_index, tree::Node node) @noinline
{
	String diagnostic_text = words_as_string(node.codegen_diagnostic.text);
	self.comp.diagnostics.add_with_location(self.comp, {
			.kind = node.codegen_diagnostic.kind,
			.text = diagnostic_text,
			.has_opt = node.codegen_diagnostic.has_opt,
			.opt = node.codegen_diagnostic.opt,
			.has_location = true,
			.location = node_index.loc(self.tree).expand(self.comp),
	}, self.pp.expansion_slice(node.codegen_diagnostic.tok), true)!;
	return ir::NONE;
}

fn String words_as_string(uint[] words)
{
	char* bytes = (char*)words.ptr;
	usz length = 0;
	while (bytes[length] != 0) length++;
	return (String)bytes[:length];
}

fn ir::Ref? CodeGen.gen_lval(&self, type_store::NodeIndex node_index)
{
	tree::Node node = node_index.get(self.tree);
	bool rvalue_member = node.kind == tree::NodeKind.MEMBER_ACCESS_EXPR && !self.tree.is_lval(node_index);
	assert(self.tree.is_lval(node_index) || rvalue_member);
	switch (node.kind)
	{
		case STRING_LITERAL_EXPR:
			value::Value val = self.tree.value_of(node_index)!!;
			return self.builder.add_constant(val.ref(), value_interner::REF_PTR);
		case PAREN_EXPR:
			return self.gen_lval(node.unary.operand);
		case DECL_REF_EXPR:
			String name_text = self.tree.tok_slice(node.decl_ref.name_tok);
			tree::Node declaration = node.decl_ref.decl.get(self.tree);
			if (declaration.kind == tree::NodeKind.VARIABLE && declaration.variable.implicit)
			{
				self.gen_var(declaration.variable, node.decl_ref.decl)!;
				return self.builder.add_symbol(self.implicit_var_name(node.decl_ref.decl), value_interner::REF_PTR);
			}
			string_interner::StringId name = self.comp.intern_string(name_text);
			sz i = self.symbols.len();
			while (i > 0)
			{
				i--;
				if (self.symbols[i].name == name) return self.symbols[i].value;
			}
			return self.builder.add_symbol(self.symbol_name(name_text, self.has_internal_linkage(node.decl_ref.decl)), value_interner::REF_PTR);
		case DEREF_EXPR:
			return self.gen_expr(node.unary.operand);
		case COMPOUND_LITERAL_EXPR:
			if (node.compound_literal.thread_local)
			{
				self.fail("TODO CodeGen.compound_literal_expr thread_local\n")!;
				return ir::NONE;
			}
			if (node.compound_literal.storage_class == tree::CompoundLiteralStorageClass.STATIC)
			{
				return self.builder.add_symbol(self.compound_literal_global(node_index)!, value_interner::REF_PTR);
			}
			// `(int[]){4, 5, 6}`: the completed type is the initializer's.
			type_store::QualType literal_qt = node.compound_literal.qt;
			self.gen_runtime_type(literal_qt)!;
			if (!@ok(literal_qt.sizeof_or_null(self.comp))) literal_qt = node.compound_literal.initializer.qt(self.tree);
			uint size = (uint)self.object_size(literal_qt);
			uint alignment = (uint)literal_qt.alignof(self.comp);
			ir::Ref alloc = self.builder.add_alloc(size, alignment, self.type_contains_volatile(literal_qt));
			self.gen_initializer(alloc, literal_qt, node.compound_literal.initializer)!;
			return alloc;
		case BUILTIN_CHOOSE_EXPR:
			value::Value cond = self.tree.value_of(node.conditional.cond)!!;
			return self.gen_lval(cond.to_bool(self.comp) ? node.conditional.then_expr: node.conditional.else_expr);
		case GENERIC_EXPR:
			return self.gen_lval(self.tree.generic_result(node_index));
		case COMPOUND_ASSIGN_DUMMY_EXPR:
			return self.compound_assign_dummy;
		case ARRAY_ACCESS_EXPR:
			type_store::NodeIndex base = node.array_access.base;
			type_store::NodeIndex index = node.array_access.index;
			if (base.qt(self.tree).is(self.comp, type_store::TypeTag.VECTOR) || index.qt(self.tree).is(self.comp, type_store::TypeTag.VECTOR))
			{
				return self.gen_vector_element_address(node.array_access);
			}
			// `i[p]` is `p[i]`.
			if (!base.qt(self.tree).is_pointer(self.comp)) @swap(base, index);
			ir::Ref base_ptr = self.gen_expr(base)!;
			ir::Ref offset = self.gen_expr(index)!;
			return self.gen_ptr_arithmetic(base_ptr, offset, index.qt(self.tree), base.qt(self.tree), false);
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR:
			MemberBase member = self.gen_member_base(node_index)!;
			if (member.field.bit_width != type_store::BIT_WIDTH_NULL)
			{
				self.fail("TODO bitfield lvalue address")!;
				return ir::NONE;
			}
			return self.ptr_at(member.ptr, member.field.layout.offset_bits / 8);
		default:
			unreachable("non-lvalue node in CodeGen.gen_lval");
	}
}

<* Statement/ternary condition: branch to `then_label` when `node` is true. *>
fn void? CodeGen.gen_cond_branch(&self, type_store::NodeIndex node, ir::Ref then_label, ir::Ref else_label)
{
	return self.gen_bool_expr(node, true_target(then_label), false_target(else_label));
}

<* Lower `node` as control flow: exit through `on_true` when the condition holds,
`on_false` otherwise. `negate` is a pending `!`, pushed down to the leaves by
De Morgan (`!(a && b)` = `!a || !b`, `!(a || b)` = `!a && !b`); the targets keep
their meaning, so no inversion state lives on CodeGen. *>
fn void? CodeGen.gen_bool_expr(&self, type_store::NodeIndex base, BoolTarget on_true, BoolTarget on_false, bool negate = false)
{
	type_store::NodeIndex node = base;
	while (node.get(self.tree).kind == tree::NodeKind.PAREN_EXPR) node = node.get(self.tree).unary.operand;
	// Zig genBoolExpr: a folded condition jumps straight to its target without
	// lowering operands (which may have no IR form, e.g. alignof).
	if (try known = self.static_condition(node))
	{
		return self.jump_to(known != negate ? on_true : on_false);
	}
	tree::Node n = node.get(self.tree);
	switch (n.kind)
	{
		case BOOL_NOT_EXPR:
			return self.gen_bool_expr(n.unary.operand, on_true, on_false, !negate);
		case BOOL_OR_EXPR:
		case BOOL_AND_EXPR:
			bool and_like = (n.kind == tree::NodeKind.BOOL_AND_EXPR) != negate;
			if (try lhs = self.tree.value_of(n.binary.lhs))
			{
				bool lhs_truth = lhs.to_bool(self.comp) != negate;
				if (and_like && !lhs_truth) return self.jump_to(on_false);
				if (!and_like && lhs_truth) return self.jump_to(on_true);
				return self.gen_bool_expr(n.binary.rhs, on_true, on_false, negate);
			}
			if (and_like)
			{
				ir::Ref rhs_label = self.builder.make_label("bool_true");
				self.gen_bool_expr(n.binary.lhs, true_target(rhs_label), on_false, negate)!;
				self.builder.start_block(rhs_label);
			}
			else
			{
				ir::Ref rhs_label = self.builder.make_label("bool_false");
				self.gen_bool_expr(n.binary.lhs, on_true, false_target(rhs_label), negate)!;
				self.builder.start_block(rhs_label);
			}
			return self.gen_bool_expr(n.binary.rhs, on_true, on_false, negate);
		case EQUAL_EXPR:
		case NOT_EQUAL_EXPR:
		case LESS_THAN_EXPR:
		case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR:
		case GREATER_THAN_EQUAL_EXPR:
			if (n.binary.lhs.qt(self.tree).is(self.comp, type_store::TypeTag.FLOAT))
			{
				self.ensure_scalar_float_width(n.binary.lhs.qt(self.tree))!;
			}
			ir::InstTag tag = self.compare_tag(n.kind, n.binary);
			if (negate)
			{
				if (try inverse = ir::inverse_compare(tag))
				{
					tag = inverse;
					negate = false;
				}
			}
			ir::Ref cmp = self.gen_comparison(n.binary, tag)!;
			return self.branch_to(cmp, on_true, on_false, negate);
		case CAST:
			if (n.cast.kind == tree::CastKind.BOOL_TO_INT)
			{
				ir::Ref operand = self.gen_expr(n.cast.operand)!;
				return self.branch_to(operand, on_true, on_false, negate);
			}
		case BINARY_COND_EXPR:
			// `c ?: e`: c true means the value is c itself (truthy).
			if (try cond = self.tree.value_of(n.conditional.cond))
			{
				return self.gen_bool_expr(cond.to_bool(self.comp) ? n.conditional.cond : n.conditional.else_expr, on_true, on_false, negate);
			}
			ir::Ref else_label = self.builder.make_label("ternary.else");
			self.gen_bool_expr(n.conditional.cond, negate ? on_false : on_true, false_target(else_label))!;
			self.builder.start_block(else_label);
			return self.gen_bool_expr(n.conditional.else_expr, on_true, on_false, negate);
		case COND_EXPR:
			if (try cond = self.tree.value_of(n.conditional.cond))
			{
				return self.gen_bool_expr(cond.to_bool(self.comp) ? n.conditional.then_expr : n.conditional.else_expr, on_true, on_false, negate);
			}
			ir::Ref then_label = self.builder.make_label("ternary.then");
			ir::Ref else_label = self.builder.make_label("ternary.else");
			self.gen_cond_branch(n.conditional.cond, then_label, else_label)!;
			self.builder.start_block(then_label);
			self.gen_bool_expr(n.conditional.then_expr, on_true, on_false, negate)!;
			self.builder.start_block(else_label);
			return self.gen_bool_expr(n.conditional.else_expr, on_true, on_false, negate);
		default:
			break;
	}
	type_store::QualType condition_type = node.qt(self.tree);
	ir::Ref cmp = self.gen_truth_compare(self.gen_expr(node)!, condition_type, negate)!;
	return self.branch_to(cmp, on_true, on_false, false);
}

<* `value != 0` as i1, or `value == 0` when `negate` (exact for NaN: !(x != 0) is x == 0). *>
fn ir::Ref? CodeGen.gen_truth_compare(&self, ir::Ref value, type_store::QualType qt, bool negate)
{
	bool is_float = qt.is(self.comp, type_store::TypeTag.FLOAT);
	if (is_float) self.ensure_scalar_float_width(qt)!;
	ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(qt)!);
	ir::InstTag tag;
	if (is_float)
	{
		tag = negate ? ir::InstTag.FCMP_OEQ : ir::InstTag.FCMP_UNE;
	}
	else
	{
		tag = negate ? ir::InstTag.CMP_EQ : ir::InstTag.CMP_NE;
	}
	return self.builder.add_inst(tag, { .bin = { .lhs = value, .rhs = zero } }, value_interner::REF_I1);
}

<*
 Lower a builtin call. Upstream Zig leaves this a TODO; the C3 port lowers the
 integer/libc subset and SysV integer/pointer varargs that the native backend
 can express: va_arg, atomic load/store/fences and read-modify-write, clz/ctz;
 alloca and setjmp remain TODO.
*>
fn ir::Ref? CodeGen.gen_builtin_call(&self, builtins::Expanded builtin, type_store::NodeIndex[] arg_nodes, type_store::QualType qt)
{
	builtin_properties::BuiltinTag tag = builtin.tag;
	if (tag == common::TAG___BUILTIN_ABS || tag == common::TAG___BUILTIN_LABS || tag == common::TAG___BUILTIN_LLABS)
	{
		return self.gen_integer_abs(arg_nodes[0], qt);
	}

	if (tag == common::TAG___BUILTIN_EXPECT || tag == common::TAG___BUILTIN_EXPECT_WITH_PROBABILITY)
	{
		ir::Ref result = self.gen_expr(arg_nodes[0])!;
		foreach (arg : arg_nodes[1..]) self.gen_expr(arg)!;
		return result;
	}
	if (tag == common::TAG___BUILTIN_PREFETCH)
	{
		foreach (arg : arg_nodes) self.gen_expr(arg)!;
		return ir::NONE;
	}
	if (tag == common::TAG___BUILTIN_TRAP || tag == common::TAG___BUILTIN_UNREACHABLE)
	{
		ir::Ref abort_fn = self.builder.add_symbol("abort", value_interner::REF_PTR);
		self.builder.add_call(abort_fn, {}, value_interner::REF_VOID);
		return ir::NONE;
	}
	if (tag == common::TAG___BUILTIN_OBJECT_SIZE || tag == common::TAG___BUILTIN_DYNAMIC_OBJECT_SIZE)
	{
		// Not folded by the parser: GCC's "unknown" answer. The object operand is
		// not evaluated (eval_args = false).
		long kind = 0;
		if (try kind_val = self.tree.value_of(arg_nodes[1]))
		{
			if (try k = kind_val.to_i64(self.comp)) kind = k;
		}
		ulong bits = qt.bit_sizeof(self.comp);
		ulong unknown = kind & 2 ? 0 : (bits >= 64 ? ~(ulong)0 : (1UL << bits) - 1);
		return self.builder.add_constant(value::int_u64(unknown, self.comp).ref(), self.gen_type(qt)!);
	}
	if ((tag == common::TAG___BUILTIN_FABS || tag == common::TAG___BUILTIN_FABSF || tag == common::TAG___BUILTIN_FABSL) &&
		arg_nodes.len == 1 && qt.is(self.comp, type_store::TypeTag.FLOAT))
	{
		self.ensure_scalar_float_width(qt)!;
		return self.add_un(ir::InstTag.FABS, self.convert_scalar(self.gen_expr(arg_nodes[0])!, arg_nodes[0].qt(self.tree), qt)!, qt);
	}
	if (tag == common::TAG___BUILTIN_ISSIGNALING)
	{
		return self.gen_issignaling(arg_nodes[0], qt);
	}
	if (builtin_call::is_overflow_builtin(tag))
	{
		return self.gen_overflow_builtin(tag, arg_nodes);
	}
	if (tag == common::TAG___ATOMIC_LOAD_N || tag == common::TAG___C11_ATOMIC_LOAD)
	{
		ir::Ref ptr = self.gen_expr(arg_nodes[0])!;
		ir::AtomicOrder order = self.atomic_order_arg(arg_nodes[1])!;
		return self.builder.add_atomic_load(ptr, order, self.gen_type(qt)!);
	}
	if (tag == common::TAG___ATOMIC_STORE_N || tag == common::TAG___C11_ATOMIC_STORE)
	{
		type_store::QualType pointee = self.atomic_pointee(arg_nodes[0]);
		ir::Ref ptr = self.gen_expr(arg_nodes[0])!;
		ir::Ref val = self.convert_scalar(self.gen_expr(arg_nodes[1])!, arg_nodes[1].qt(self.tree), pointee)!;
		ir::AtomicOrder order = self.atomic_order_arg(arg_nodes[2])!;
		self.builder.add_atomic_store(ptr, val, order);
		return ir::NONE;
	}
	if (try handled = self.gen_atomic_rmw_builtin(tag, arg_nodes, qt)) return handled;
	if (tag == common::TAG___ATOMIC_THREAD_FENCE || tag == common::TAG___C11_ATOMIC_THREAD_FENCE)
	{
		self.builder.add_fence(self.atomic_order_arg(arg_nodes[0])!);
		return ir::NONE;
	}
	if (tag == common::TAG___SYNC_SYNCHRONIZE)
	{
		self.builder.add_fence(ir::AtomicOrder.SEQ_CST);
		return ir::NONE;
	}
	if (tag == common::TAG___ATOMIC_SIGNAL_FENCE || tag == common::TAG___C11_ATOMIC_SIGNAL_FENCE)
	{
		// A compiler-only barrier; IR passes never move memory operations.
		self.atomic_order_arg(arg_nodes[0])!;
		return ir::NONE;
	}
	if (tag == common::TAG___BUILTIN_CLZ || tag == common::TAG___BUILTIN_CLZL || tag == common::TAG___BUILTIN_CLZLL ||
		tag == common::TAG___BUILTIN_CLZS || tag == common::TAG___BUILTIN_CTZ || tag == common::TAG___BUILTIN_CTZL ||
		tag == common::TAG___BUILTIN_CTZLL || tag == common::TAG___BUILTIN_CTZS)
	{
		bool leading = tag == common::TAG___BUILTIN_CLZ || tag == common::TAG___BUILTIN_CLZL ||
			tag == common::TAG___BUILTIN_CLZLL || tag == common::TAG___BUILTIN_CLZS;
		type_store::QualType operand_qt = arg_nodes[0].qt(self.tree);
		ir::Ref count = self.add_un(leading ? ir::InstTag.CLZ : ir::InstTag.CTZ, self.gen_expr(arg_nodes[0])!, operand_qt)!;
		return self.convert_scalar(count, operand_qt, qt);
	}
	if (tag == common::TAG___BUILTIN_BSWAP16 || tag == common::TAG___BUILTIN_BSWAP32 || tag == common::TAG___BUILTIN_BSWAP64)
	{
		return self.gen_bswap(self.gen_expr(arg_nodes[0])!, qt);
	}
	if (builtin_call::is_va_start_builtin(tag))
	{
		self.builder.add_va_start(self.is_darwin_arm64() ? self.darwin_va_address(arg_nodes[0])! : self.gen_expr(arg_nodes[0])!);
		return ir::NONE;
	}
	if (builtin_properties::is_va_end_tag(tag))
	{
		self.gen_expr(arg_nodes[0])!;
		return ir::NONE;
	}
	if (builtin_properties::is_va_copy_tag(tag))
	{
		ir::Ref destination = self.is_darwin_arm64() ? self.darwin_va_address(arg_nodes[0])! : self.gen_expr(arg_nodes[0])!;
		ir::Ref source = self.gen_expr(arg_nodes[1])!;
		if (self.is_darwin_arm64())
		{
			self.builder.add_store(destination, source);
			return ir::NONE;
		}
		for (ulong offset = 0; offset < 24; offset += 8)
		{
			ir::Ref field = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = self.ptr_at(source, offset) }, value_interner::REF_I64);
			self.builder.add_store(self.ptr_at(destination, offset), field);
		}
		return ir::NONE;
	}
	if (tag == common::TAG___BUILTIN_VA_ARG)
	{
		if (self.is_darwin_arm64()) return self.darwin_va_arg(arg_nodes[0], qt);
		bool float_value = qt.is(self.comp, type_store::TypeTag.FLOAT);
		bool supported = qt.is_int(self.comp) || qt.is_pointer(self.comp) || qt.base(self.comp).ty.tag == type_store::TypeTag.ENUM;
		ulong? result_size = qt.sizeof_or_null(self.comp);
		if (float_value && qt.bit_sizeof(self.comp) == 80)
		{
			self.ensure_scalar_float_width(qt)!;
			ir::Ref list = self.gen_expr(arg_nodes[0])!;
			ir::Ref overflow_field = self.ptr_at(list, 8);
			ir::Ref overflow_address = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = overflow_field }, value_interner::REF_PTR);
			ir::Ref alignment_bias = self.builder.add_constant(value::int_u64(15, self.comp).ref(), value_interner::REF_I64);
			ir::Ref unaligned_address = self.builder.add_inst(ir::InstTag.ADD,
				{ .bin = { .lhs = overflow_address, .rhs = alignment_bias } }, value_interner::REF_PTR);
			ir::Ref alignment_mask = self.builder.add_constant(value::int_u64(~(ulong)15, self.comp).ref(), value_interner::REF_PTR);
			ir::Ref aligned_address = self.builder.add_inst(ir::InstTag.BIT_AND,
				{ .bin = { .lhs = unaligned_address, .rhs = alignment_mask } }, value_interner::REF_PTR);
			self.builder.add_store(overflow_field, self.ptr_at(aligned_address, 16));
			return self.builder.add_inst(ir::InstTag.LOAD, { .ref = aligned_address }, self.gen_type(qt)!);
		}
		if (float_value && @ok(result_size) && result_size! <= 8)
		{
			self.ensure_scalar_float_width(qt)!;
			ir::Ref list = self.gen_expr(arg_nodes[0])!;
			ir::Ref fp_offset = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = self.ptr_at(list, 4) }, value_interner::REF_I32);
			// The eight XMM save slots occupy offsets 48..175. The final slot
			// starts at 160, so fp_offset values through 160 are register-backed.
			ir::Ref fp_limit = self.builder.add_constant(value::int_u64(161, self.comp).ref(), value_interner::REF_I32);
			ir::Ref in_register_save_area = self.builder.add_inst(ir::InstTag.CMP_ULT,
				{ .bin = { .lhs = fp_offset, .rhs = fp_limit } }, value_interner::REF_I1);
			ir::Ref register_label = self.builder.make_label("va_arg.fp_reg");
			ir::Ref overflow_label = self.builder.make_label("va_arg.fp_mem");
			ir::Ref join_label = self.builder.make_label("va_arg.fp_join");
			self.add_branch(in_register_save_area, register_label, overflow_label)!;

			self.builder.start_block(register_label);
			ir::Ref register_save_area = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = self.ptr_at(list, 16) }, value_interner::REF_PTR);
			ir::Ref wide_fp_offset = self.builder.add_inst(ir::InstTag.ZEXT,
				{ .ref = fp_offset }, value_interner::REF_I64);
			ir::Ref register_address = self.builder.add_inst(ir::InstTag.ADD,
				{ .bin = { .lhs = register_save_area, .rhs = wide_fp_offset } }, value_interner::REF_PTR);
			ir::Ref fp_step = self.builder.add_constant(value::int_i64(16, self.comp).ref(), value_interner::REF_I32);
			ir::Ref next_fp_offset = self.builder.add_inst(ir::InstTag.ADD,
				{ .bin = { .lhs = fp_offset, .rhs = fp_step } }, value_interner::REF_I32);
			self.builder.add_store(self.ptr_at(list, 4), next_fp_offset);
			ir::Ref register_predecessor = self.builder.current_label;
			self.builder.add_jump(join_label);

			self.builder.start_block(overflow_label);
			ir::Ref overflow_field = self.ptr_at(list, 8);
			ir::Ref overflow_address = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = overflow_field }, value_interner::REF_PTR);
			self.builder.add_store(overflow_field, self.ptr_at(overflow_address, 8));
			ir::Ref overflow_predecessor = self.builder.current_label;
			self.builder.add_jump(join_label);

			self.builder.start_block(join_label);
			ir::PhiInput[2] incoming = {
				{ .label = register_predecessor, .value = register_address },
				{ .label = overflow_predecessor, .value = overflow_address },
			};
			ir::Ref address = self.builder.add_phi(incoming[..], value_interner::REF_PTR);
			return self.builder.add_inst(ir::InstTag.LOAD, { .ref = address }, self.gen_type(qt)!);
		}
		if (supported && @ok(result_size) && result_size! <= 8)
		{
			ir::Ref list = self.gen_expr(arg_nodes[0])!;
			ir::Ref gp_offset = self.builder.add_inst(ir::InstTag.LOAD, { .ref = list }, value_interner::REF_I32);
			ir::Ref gp_limit = self.builder.add_constant(value::int_u64(48, self.comp).ref(), value_interner::REF_I32);
			ir::Ref in_register_save_area = self.builder.add_inst(ir::InstTag.CMP_ULT,
				{ .bin = { .lhs = gp_offset, .rhs = gp_limit } }, value_interner::REF_I1);
			ir::Ref register_label = self.builder.make_label("va_arg.reg");
			ir::Ref overflow_label = self.builder.make_label("va_arg.mem");
			ir::Ref join_label = self.builder.make_label("va_arg.join");
			self.add_branch(in_register_save_area, register_label, overflow_label)!;

			self.builder.start_block(register_label);
			ir::Ref register_save_area = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = self.ptr_at(list, 16) }, value_interner::REF_PTR);
			ir::Ref wide_gp_offset = self.builder.add_inst(ir::InstTag.ZEXT,
				{ .ref = gp_offset }, value_interner::REF_I64);
			ir::Ref register_address = self.builder.add_inst(ir::InstTag.ADD,
				{ .bin = { .lhs = register_save_area, .rhs = wide_gp_offset } }, value_interner::REF_PTR);
			ir::Ref gp_step = self.builder.add_constant(value::int_i64(8, self.comp).ref(), value_interner::REF_I32);
			ir::Ref next_gp_offset = self.builder.add_inst(ir::InstTag.ADD,
				{ .bin = { .lhs = gp_offset, .rhs = gp_step } }, value_interner::REF_I32);
			self.builder.add_store(list, next_gp_offset);
			ir::Ref register_predecessor = self.builder.current_label;
			self.builder.add_jump(join_label);

			self.builder.start_block(overflow_label);
			ir::Ref overflow_field = self.ptr_at(list, 8);
			ir::Ref overflow_address = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = overflow_field }, value_interner::REF_PTR);
			self.builder.add_store(overflow_field, self.ptr_at(overflow_address, 8));
			ir::Ref overflow_predecessor = self.builder.current_label;
			self.builder.add_jump(join_label);

			self.builder.start_block(join_label);
			ir::PhiInput[2] incoming = {
				{ .label = register_predecessor, .value = register_address },
				{ .label = overflow_predecessor, .value = overflow_address },
			};
			ir::Ref address = self.builder.add_phi(incoming[..], value_interner::REF_PTR);
			return self.builder.add_inst(ir::InstTag.LOAD, { .ref = address }, self.gen_type(qt)!);
		}
		if (self.is_record_value(qt)) return self.gen_va_arg_record(arg_nodes[0], qt);
		self.fail("TODO CodeGen.genBuiltinCall __builtin_va_arg <type>\n")!;
		return ir::NONE;
	}
	bool is_lib = builtin.attributes.lib_function_with_builtin_prefix || builtin.attributes.lib_function_without_prefix;
	bool excluded = builtin.attributes.custom_typecheck || builtin.attributes.returns_twice ||
	tag == common::TAG___BUILTIN_ALLOCA || tag == common::TAG___BUILTIN_ALLOCA_UNINITIALIZED ||
	tag == common::TAG___BUILTIN_ALLOCA_WITH_ALIGN || tag == common::TAG___BUILTIN_ALLOCA_WITH_ALIGN_UNINITIALIZED ||
	tag == common::TAG___BUILTIN_LONGJMP;
	if (is_lib && !excluded)
	{
		// Forward to the library function: `__builtin_memcpy` calls `memcpy`.
		String name = builtins::name_from_tag(tag);
		if (name.starts_with("__builtin_")) name = name["__builtin_".len..];
		ir::Ref fn_ref = self.builder.add_symbol(name, value_interner::REF_PTR);
		ir::Ref[] args = alloc::new_array(&self.builder.arena, ir::Ref, arg_nodes.len);
		foreach (i, arg_node : arg_nodes) args[i] = self.gen_expr(arg_node)!;
		return self.builder.add_call(fn_ref, args, self.gen_type(qt)!);
	}
	self.fail(string::tformat("TODO CodeGen.genBuiltinCall %s\n", builtins::name_from_tag(tag)))!;
	return ir::NONE;
}

<* Whether an asm statement has no operands or labels and a blank template. *>
fn bool CodeGen.is_empty_asm_barrier(&self, tree::NodeAsmStmt asm_node)
{
	if (asm_node.outputs.len != 0 || asm_node.inputs.len != 0 || asm_node.labels.len != 0) return false;
	value::Value? text = self.tree.value_of(asm_node.asm_str);
	if (catch text) return false;
	if (!text.is(primitive_value::PrimitiveType.BYTES, self.comp)) return false;
	foreach (c : text.to_bytes(self.comp))
	{
		if (c != 0 && c != ' ' && c != '\t' && c != '\n') return false;
	}
	return true;
}

<*
 `__builtin_issignaling(x)`: the IR has no bitcast, so spill `x` to a stack slot and
 reload its storage as integer words, then test the encoding as glibc does: exponent
 all ones, quiet bit (top stored fraction bit) clear, fraction nonzero. For x87
 long double the explicit integer bit must also be set (pseudo-NaNs are not signaling).
*>
fn ir::Ref? CodeGen.gen_issignaling(&self, type_store::NodeIndex arg_node, type_store::QualType qt) @noinline
{
	type_store::QualType arg_qt = arg_node.qt(self.tree);
	type_store::ScalarKind arg_kind = arg_qt.scalar_kind(self.comp);
	if (!arg_kind.is_float || !arg_kind.is_real)
	{
		self.fail("TODO CodeGen.genBuiltinCall __builtin_issignaling <non-real-floating>\n")!;
		return ir::NONE;
	}
	ulong bits = arg_qt.bit_sizeof(self.comp);
	primitive_value::PrimitiveType ftag = primitive_value::float_tag_of_width(bits);
	ir::Ref value = self.gen_expr(arg_node)!;
	uint size = (uint)arg_qt.sizeof(self.comp);
	ir::Ref slot = self.builder.add_alloc(size, (uint)arg_qt.alignof(self.comp));
	self.builder.add_store(slot, value);

	ir::Ref is_snan;
	switch (ftag)
	{
		case F16:
		case F32:
		case F64:
			// glibc: ((w ^ quiet) & ~sign) > (exp_mask | quiet), unsigned.
			value_interner::InternerRef ity = bits == 16 ? value_interner::REF_I16 : bits == 32 ? value_interner::REF_I32 : value_interner::REF_I64;
			uint frac_bits = ftag.format.frac_bits;
			ulong quiet = 1UL << (frac_bits - 1);
			ulong sign = 1UL << (bits - 1);
			ulong exp_mask = (sign - 1) & ~((1UL << frac_bits) - 1);
			ir::Ref w = self.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, ity);
			ir::Ref flipped = self.int_binop(ir::InstTag.BIT_XOR, w, quiet, ity);
			ir::Ref magnitude = self.int_binop(ir::InstTag.BIT_AND, flipped, sign - 1, ity);
			is_snan = self.int_cmp(ir::InstTag.CMP_UGT, magnitude, exp_mask | quiet, ity);
		case F80:
			// Mantissa (with explicit integer bit 63) at offset 0, sign+exponent at 8.
			ir::Ref mant = self.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
			ir::Ref se = self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.ptr_at(slot, 8) }, value_interner::REF_I16);
			ir::Ref exp = self.int_binop(ir::InstTag.BIT_AND, se, 0x7FFF, value_interner::REF_I16);
			ir::Ref exp_max = self.int_cmp(ir::InstTag.CMP_EQ, exp, 0x7FFF, value_interner::REF_I16);
			// Top two mantissa bits == 0b10: integer bit set, quiet bit clear.
			ir::Ref top = self.int_binop(ir::InstTag.BIT_LSHR, mant, 62, value_interner::REF_I64);
			ir::Ref int_not_quiet = self.int_cmp(ir::InstTag.CMP_EQ, top, 2, value_interner::REF_I64);
			ir::Ref payload = self.int_binop(ir::InstTag.BIT_AND, mant, (1UL << 62) - 1, value_interner::REF_I64);
			ir::Ref nonzero = self.int_cmp(ir::InstTag.CMP_NE, payload, 0, value_interner::REF_I64);
			is_snan = self.bool_and(self.bool_and(exp_max, int_not_quiet), nonzero);
		case F128:
			// Little-endian halves: fraction low 64 bits at 0; sign, exponent and top 48 fraction bits at 8.
			ir::Ref lo = self.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_interner::REF_I64);
			ir::Ref hi = self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.ptr_at(slot, 8) }, value_interner::REF_I64);
			ulong exp_hi = 0x7FFF_0000_0000_0000UL;
			ulong quiet_hi = 1UL << 47;
			ir::Ref exp = self.int_binop(ir::InstTag.BIT_AND, hi, exp_hi, value_interner::REF_I64);
			ir::Ref exp_max = self.int_cmp(ir::InstTag.CMP_EQ, exp, exp_hi, value_interner::REF_I64);
			ir::Ref quiet = self.int_binop(ir::InstTag.BIT_AND, hi, quiet_hi, value_interner::REF_I64);
			ir::Ref not_quiet = self.int_cmp(ir::InstTag.CMP_EQ, quiet, 0, value_interner::REF_I64);
			ir::Ref frac_hi = self.int_binop(ir::InstTag.BIT_AND, hi, quiet_hi - 1, value_interner::REF_I64);
			ir::Ref frac = self.builder.add_inst(ir::InstTag.BIT_OR, { .bin = { .lhs = frac_hi, .rhs = lo } }, value_interner::REF_I64);
			ir::Ref nonzero = self.int_cmp(ir::InstTag.CMP_NE, frac, 0, value_interner::REF_I64);
			is_snan = self.bool_and(self.bool_and(exp_max, not_quiet), nonzero);
		default:
			unreachable("not a float tag");
	}
	return self.builder.add_inst(ir::InstTag.ZEXT, { .ref = is_snan }, self.gen_type(qt)!);
}

<* `lhs <op> constant` on an integer of type `ty`. *>
fn ir::Ref CodeGen.int_binop(&self, ir::InstTag op, ir::Ref lhs, ulong rhs, value_interner::InternerRef ty)
{
	ir::Ref constant = self.builder.add_constant(value::int_u64(rhs, self.comp).ref(), ty);
	return self.builder.add_inst(op, { .bin = { .lhs = lhs, .rhs = constant } }, ty);
}

<* `lhs <cmp> constant` on an integer of type `ty`, yielding i1. *>
fn ir::Ref CodeGen.int_cmp(&self, ir::InstTag op, ir::Ref lhs, ulong rhs, value_interner::InternerRef ty)
{
	ir::Ref constant = self.builder.add_constant(value::int_u64(rhs, self.comp).ref(), ty);
	return self.builder.add_inst(op, { .bin = { .lhs = lhs, .rhs = constant } }, value_interner::REF_I1);
}

<* Branch-free `a && b` on i1 values. *>
fn ir::Ref CodeGen.bool_and(&self, ir::Ref a, ir::Ref b)
{
	return self.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { .lhs = a, .rhs = b } }, value_interner::REF_I1);
}

<*
 `__builtin_{add,sub,mul}_overflow(a, b, res)`: compute in i128, which is exact
 for operands of at most 64 bits, store the result truncated to `*res`'s type,
 and report whether truncation changed the value.
*>
fn ir::Ref? CodeGen.gen_overflow_builtin(&self, builtin_properties::BuiltinTag tag, type_store::NodeIndex[] arg_nodes) @noinline
{
	type_store::QualType result_qt = self.atomic_pointee(arg_nodes[2]);
	type_store::QualType lhs_qt = arg_nodes[0].qt(self.tree);
	type_store::QualType rhs_qt = arg_nodes[1].qt(self.tree);
	if (lhs_qt.bit_sizeof(self.comp) > 64 || rhs_qt.bit_sizeof(self.comp) > 64 || result_qt.bit_sizeof(self.comp) > 64)
	{
		self.fail("TODO: __builtin_*_overflow on integers wider than 64 bits\n")!;
	}
	type_store::QualType wide_qt = type_store::INT128;
	ir::Ref lhs = self.convert_scalar(self.gen_expr(arg_nodes[0])!, lhs_qt, wide_qt)!;
	ir::Ref rhs = self.convert_scalar(self.gen_expr(arg_nodes[1])!, rhs_qt, wide_qt)!;
	ir::Ref result_ptr = self.gen_expr(arg_nodes[2])!;
	ir::InstTag op = tag == common::TAG___BUILTIN_ADD_OVERFLOW ? ir::InstTag.ADD :
		(tag == common::TAG___BUILTIN_SUB_OVERFLOW ? ir::InstTag.SUB : ir::InstTag.MUL);
	ir::Ref exact = self.add_bin(op, lhs, rhs, wide_qt)!;
	ir::Ref truncated = self.convert_scalar(exact, wide_qt, result_qt)!;
	self.builder.add_store(result_ptr, truncated);
	ir::Ref round_trip = self.convert_scalar(truncated, result_qt, wide_qt)!;
	return self.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { .lhs = round_trip, .rhs = exact } }, value_interner::REF_I1);
}

<* The non-atomic, unqualified object type an `__atomic_*`/`__c11_atomic_*` pointer argument points to. *>
fn type_store::QualType CodeGen.atomic_pointee(&self, type_store::NodeIndex pointer_arg)
{
	type_store::QualType pointer_qt = pointer_arg.qt(self.tree);
	type_store::Type pointer = pointer_qt.get(self.comp, type_store::TypeTag.POINTER)!!;
	return pointer.pointer.child.non_atomic(self.comp).unqualified();
}

<* gen_atomic_rmw_builtin: the builtin is not an atomic read-modify-write. *>
faultdef NOT_ATOMIC_RMW;

<* An atomic read-modify-write builtin's operation (`add`, `cmpxchg`, ...),
   whether it returns the new value, and its argument shape. *>
enum AtomicRmwShape : char
{
	NONE,
	FETCH_OP, // (ptr, value, ...) -> old
	OP_FETCH, // (ptr, value, ...) -> new
	EXCHANGE, // (ptr, value, ...) -> old
	C11_CMPXCHG, // (ptr, expected_ptr, desired, ...) -> bool
	GENERIC_CMPXCHG, // (ptr, expected_ptr, desired_ptr, ...) -> bool
	SYNC_BOOL_CAS, // (ptr, old, new) -> bool
	SYNC_VAL_CAS, // (ptr, old, new) -> previous value
	TEST_AND_SET, // (ptr, order) -> bool
	CLEAR, // (ptr, ...) store 0
}

fn AtomicRmwShape atomic_rmw_shape(builtin_properties::BuiltinTag tag, String* op, bool* scale_pointer)
{
	*scale_pointer = false;
	switch (tag)
	{
		case common::TAG___C11_ATOMIC_FETCH_ADD: *op = "add"; *scale_pointer = true; return FETCH_OP;
		case common::TAG___C11_ATOMIC_FETCH_SUB: *op = "sub"; *scale_pointer = true; return FETCH_OP;
		case common::TAG___C11_ATOMIC_FETCH_AND: *op = "and"; return FETCH_OP;
		case common::TAG___C11_ATOMIC_FETCH_OR: *op = "or"; return FETCH_OP;
		case common::TAG___C11_ATOMIC_FETCH_XOR: *op = "xor"; return FETCH_OP;
		case common::TAG___C11_ATOMIC_FETCH_NAND: *op = "nand"; return FETCH_OP;
		case common::TAG___ATOMIC_FETCH_ADD: case common::TAG___SYNC_FETCH_AND_ADD: *op = "add"; return FETCH_OP;
		case common::TAG___ATOMIC_FETCH_SUB: case common::TAG___SYNC_FETCH_AND_SUB: *op = "sub"; return FETCH_OP;
		case common::TAG___ATOMIC_FETCH_AND: case common::TAG___SYNC_FETCH_AND_AND: *op = "and"; return FETCH_OP;
		case common::TAG___ATOMIC_FETCH_OR: case common::TAG___SYNC_FETCH_AND_OR: *op = "or"; return FETCH_OP;
		case common::TAG___ATOMIC_FETCH_XOR: case common::TAG___SYNC_FETCH_AND_XOR: *op = "xor"; return FETCH_OP;
		case common::TAG___ATOMIC_FETCH_NAND: case common::TAG___SYNC_FETCH_AND_NAND: *op = "nand"; return FETCH_OP;
		case common::TAG___ATOMIC_ADD_FETCH: case common::TAG___SYNC_ADD_AND_FETCH: *op = "add"; return OP_FETCH;
		case common::TAG___ATOMIC_SUB_FETCH: case common::TAG___SYNC_SUB_AND_FETCH: *op = "sub"; return OP_FETCH;
		case common::TAG___ATOMIC_AND_FETCH: case common::TAG___SYNC_AND_AND_FETCH: *op = "and"; return OP_FETCH;
		case common::TAG___ATOMIC_OR_FETCH: case common::TAG___SYNC_OR_AND_FETCH: *op = "or"; return OP_FETCH;
		case common::TAG___ATOMIC_XOR_FETCH: case common::TAG___SYNC_XOR_AND_FETCH: *op = "xor"; return OP_FETCH;
		case common::TAG___ATOMIC_NAND_FETCH: case common::TAG___SYNC_NAND_AND_FETCH: *op = "nand"; return OP_FETCH;
		case common::TAG___C11_ATOMIC_EXCHANGE: case common::TAG___ATOMIC_EXCHANGE_N:
		case common::TAG___SYNC_LOCK_TEST_AND_SET:
		case common::TAG___SYNC_SWAP:
			*op = "xchg"; return EXCHANGE;
		case common::TAG___C11_ATOMIC_COMPARE_EXCHANGE_STRONG: case common::TAG___C11_ATOMIC_COMPARE_EXCHANGE_WEAK:
		case common::TAG___ATOMIC_COMPARE_EXCHANGE_N:
			*op = "cmpxchg"; return C11_CMPXCHG;
		case common::TAG___ATOMIC_COMPARE_EXCHANGE: *op = "cmpxchg"; return GENERIC_CMPXCHG;
		case common::TAG___SYNC_BOOL_COMPARE_AND_SWAP: *op = "cmpxchg"; return SYNC_BOOL_CAS;
		case common::TAG___SYNC_VAL_COMPARE_AND_SWAP: *op = "cmpxchg"; return SYNC_VAL_CAS;
		case common::TAG___ATOMIC_TEST_AND_SET: *op = "xchg"; return TEST_AND_SET;
		case common::TAG___ATOMIC_CLEAR: case common::TAG___SYNC_LOCK_RELEASE: return CLEAR;
		default: return NONE;
	}
}

<* A call of the lowering's inline atomic intrinsic `__aro.atomic.<op>.<bits>`. *>
fn ir::Ref CodeGen.atomic_intrinsic_call(&self, String op, uint bits, ir::Ref[] args, value_interner::InternerRef ty)
{
	String name = string::format(&self.builder.arena, "__aro.atomic.%s.%d", op, bits);
	ir::Ref callee = self.builder.add_symbol(name, value_interner::REF_PTR);
	return self.builder.add_call(callee, args, ty);
}

<* `__c11_atomic_*`, `__atomic_*` and `__sync_*` read-modify-write builtins
   (always sequentially consistent: every lowering uses a locked instruction).
   Faults with NOT_ATOMIC_RMW for other builtins. *>
fn ir::Ref? CodeGen.gen_atomic_rmw_builtin(&self, builtin_properties::BuiltinTag tag, type_store::NodeIndex[] arg_nodes, type_store::QualType qt)
{
	String op;
	bool scale_pointer;
	AtomicRmwShape shape = atomic_rmw_shape(tag, &op, &scale_pointer);
	if (shape == AtomicRmwShape.NONE) return NOT_ATOMIC_RMW~;
	type_store::QualType pointee = self.atomic_pointee(arg_nodes[0]);
	ir::Ref ptr = self.gen_expr(arg_nodes[0])!;
	if (shape == AtomicRmwShape.CLEAR)
	{
		value_interner::InternerRef clear_ty = pointee.is(self.comp, type_store::TypeTag.VOID) ? value_interner::REF_I8 : self.gen_type(pointee)!;
		if (clear_ty == value_interner::REF_I1) clear_ty = value_interner::REF_I8;
		self.builder.add_atomic_store(ptr, self.builder.add_constant(value_interner::REF_ZERO, clear_ty), ir::AtomicOrder.SEQ_CST);
		foreach (extra : arg_nodes[1..]) self.gen_expr(extra)!;
		return ir::NONE;
	}
	if (shape == AtomicRmwShape.TEST_AND_SET)
	{
		ir::Ref one = self.builder.add_constant(value::int_u64(1, self.comp).ref(), value_interner::REF_I8);
		ir::Ref old = self.atomic_intrinsic_call("xchg", 8, { ptr, one }, value_interner::REF_I8);
		ir::Ref zero = self.builder.add_constant(value_interner::REF_ZERO, value_interner::REF_I8);
		return self.builder.add_inst(ir::InstTag.CMP_NE, { .bin = { .lhs = old, .rhs = zero } }, value_interner::REF_I1);
	}
	value_interner::InternerRef value_ty = self.gen_type(pointee)!;
	bool is_bool = value_ty == value_interner::REF_I1;
	value_interner::InternerRef op_ty = is_bool ? value_interner::REF_I8 : value_ty;
	uint bits = (uint)pointee.bit_sizeof(self.comp);
	if (is_bool) bits = 8;
	if (bits != 8 && bits != 16 && bits != 32 && bits != 64)
	{
		self.fail(string::tformat("TODO CodeGen.genBuiltinCall atomic read-modify-write of a %d-bit object\n", bits))!;
		return ir::NONE;
	}
	switch (shape)
	{
		case C11_CMPXCHG:
		case GENERIC_CMPXCHG:
			ir::Ref expected = self.gen_expr(arg_nodes[1])!;
			ir::Ref desired;
			if (shape == AtomicRmwShape.GENERIC_CMPXCHG)
			{
				desired = self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.gen_expr(arg_nodes[2])! }, op_ty);
			}
			else
			{
				desired = self.convert_scalar(self.gen_expr(arg_nodes[2])!, arg_nodes[2].qt(self.tree), pointee)!;
				if (is_bool) desired = self.builder.add_inst(ir::InstTag.ZEXT, { .ref = desired }, value_interner::REF_I8);
			}
			foreach (extra : arg_nodes[3..]) self.gen_expr(extra)!;
			return self.atomic_intrinsic_call(op, bits, { ptr, expected, desired }, value_interner::REF_I1);
		case SYNC_BOOL_CAS:
		case SYNC_VAL_CAS:
			ir::Ref old_value = self.convert_scalar(self.gen_expr(arg_nodes[1])!, arg_nodes[1].qt(self.tree), pointee)!;
			ir::Ref new_value = self.convert_scalar(self.gen_expr(arg_nodes[2])!, arg_nodes[2].qt(self.tree), pointee)!;
			if (is_bool)
			{
				old_value = self.builder.add_inst(ir::InstTag.ZEXT, { .ref = old_value }, value_interner::REF_I8);
				new_value = self.builder.add_inst(ir::InstTag.ZEXT, { .ref = new_value }, value_interner::REF_I8);
			}
			ir::Ref slot = self.builder.add_alloc(bits / 8, bits / 8);
			self.builder.add_store(slot, old_value);
			ir::Ref swapped = self.atomic_intrinsic_call(op, bits, { ptr, slot, new_value }, value_interner::REF_I1);
			if (shape == AtomicRmwShape.SYNC_BOOL_CAS) return swapped;
			ir::Ref previous = self.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, op_ty);
			return is_bool ? self.builder.add_inst(ir::InstTag.TRUNC, { .ref = previous }, value_interner::REF_I1) : previous;
		default:
			break;
	}
	ir::Ref operand = self.convert_scalar(self.gen_expr(arg_nodes[1])!, arg_nodes[1].qt(self.tree),
		pointee.is_pointer(self.comp) ? self.comp.type_store.ptrdiff : pointee)!;
	if (is_bool) operand = self.builder.add_inst(ir::InstTag.ZEXT, { .ref = operand }, value_interner::REF_I8);
	if (pointee.is_pointer(self.comp) && scale_pointer)
	{
		ulong? elem_size = pointee.child_type(self.comp).sizeof_or_null(self.comp);
		if (try size = elem_size)
		{
			ir::Ref scale = self.builder.add_constant(value::int_u64(size, self.comp).ref(), value_interner::REF_I64);
			operand = self.builder.add_inst(ir::InstTag.MUL, { .bin = { .lhs = operand, .rhs = scale } }, value_interner::REF_I64);
		}
	}
	foreach (extra : arg_nodes[2..]) self.gen_expr(extra)!;
	value_interner::InternerRef call_ty = pointee.is_pointer(self.comp) ? value_interner::REF_I64 : op_ty;
	ir::Ref old = self.atomic_intrinsic_call(op, bits, { ptr, operand }, call_ty);
	ir::Ref result = old;
	if (shape == AtomicRmwShape.OP_FETCH)
	{
		ir::InstTag combine;
		switch (op)
		{
			case "add": combine = ir::InstTag.ADD;
			case "sub": combine = ir::InstTag.SUB;
			case "and": combine = ir::InstTag.BIT_AND;
			case "or": combine = ir::InstTag.BIT_OR;
			case "xor": combine = ir::InstTag.BIT_XOR;
			default: combine = ir::InstTag.BIT_AND; // nand: ~(old & value)
		}
		result = self.builder.add_inst(combine, { .bin = { .lhs = old, .rhs = operand } }, call_ty);
		if (op == "nand") result = self.builder.add_inst(ir::InstTag.BIT_NOT, { .ref = result }, call_ty);
	}
	// Pointers stay ptr-typed in the IR; a same-width ZEXT converts (see INT_TO_POINTER).
	if (pointee.is_pointer(self.comp)) return self.builder.add_inst(ir::InstTag.ZEXT, { .ref = result }, value_interner::REF_PTR);
	if (is_bool) return self.builder.add_inst(ir::InstTag.TRUNC, { .ref = result }, value_interner::REF_I1);
	return result;
}

<* A `__ATOMIC_*` memory-order argument. A non-constant order is evaluated and treated as seq_cst. *>
fn ir::AtomicOrder? CodeGen.atomic_order_arg(&self, type_store::NodeIndex order_arg)
{
	if (try order_val = self.tree.value_of(order_arg))
	{
		if (try order = order_val.to_i64(self.comp))
		{
			if (order >= 0 && order <= (long)ir::AtomicOrder.SEQ_CST) return (ir::AtomicOrder)order;
		}
	}
	else
	{
		self.gen_expr(order_arg)!;
	}
	return ir::AtomicOrder.SEQ_CST;
}

<* Integer/pointer value conversion between scalar types of possibly different widths. *>
fn ir::Ref? CodeGen.convert_scalar(&self, ir::Ref value, type_store::QualType from, type_store::QualType to)
{
	ulong from_bits = from.bit_sizeof(self.comp);
	ulong to_bits = to.bit_sizeof(self.comp);
	if (from_bits == to_bits) return value;
	if (from_bits > to_bits) return self.add_un(ir::InstTag.TRUNC, value, to);
	bool unsigned_source = from.is_pointer(self.comp) || from.signedness(self.comp) == bigint::Signedness.UNSIGNED;
	return self.add_un(unsigned_source ? ir::InstTag.ZEXT : ir::InstTag.SEXT, value, to);
}

<* Byte-reverse `operand` (16, 32 or 64 bits wide, per `qt`) with shifts and masks. *>
fn ir::Ref? CodeGen.gen_bswap(&self, ir::Ref operand, type_store::QualType qt)
{
	uint bytes = (uint)qt.sizeof(self.comp);
	value_interner::InternerRef ty = self.gen_type(qt)!;
	ir::Ref result = ir::NONE;
	for (uint i = 0; i < bytes; i++)
	{
		// Byte i (from the low end) moves to byte bytes-1-i.
		uint src_shift = i * 8;
		uint dst_shift = (bytes - 1 - i) * 8;
		ir::Ref byte = operand;
		if (src_shift) byte = self.add_bin(ir::InstTag.BIT_LSHR, byte, self.builder.add_constant(value::int_u64(src_shift, self.comp).ref(), ty), qt)!;
		byte = self.add_bin(ir::InstTag.BIT_AND, byte, self.builder.add_constant(value::int_u64(0xff, self.comp).ref(), ty), qt)!;
		if (dst_shift) byte = self.add_bin(ir::InstTag.BIT_SHL, byte, self.builder.add_constant(value::int_u64(dst_shift, self.comp).ref(), ty), qt)!;
		result = result == ir::NONE ? byte : self.add_bin(ir::InstTag.BIT_OR, result, byte, qt)!;
	}
	return result;
}

<* Evaluate the operand once. The minimum signed value has undefined abs in C. *>
fn ir::Ref? CodeGen.gen_integer_abs(&self, type_store::NodeIndex operand, type_store::QualType qt)
{
	ir::Ref input = self.gen_expr(operand)!;
	value_interner::InternerRef ty = self.gen_type(qt)!;
	ir::Ref shift = self.builder.add_constant(value::int_u64(qt.bit_sizeof(self.comp) - 1, self.comp).ref(), ty);
	ir::Ref sign = self.add_bin(ir::InstTag.BIT_ASHR, input, shift, qt)!;
	ir::Ref flipped = self.add_bin(ir::InstTag.BIT_XOR, input, sign, qt)!;
	return self.add_bin(ir::InstTag.SUB, flipped, sign, qt);
}

fn ir::Ref? CodeGen.gen_call(&self, tree::NodeCall call)
{
	ir::Ref fn_ref;
	bool knr_callee = false;
	tree::Node callee = call.callee.get(self.tree);
	if (callee.kind != tree::NodeKind.CAST || callee.cast.kind != tree::CastKind.FUNCTION_TO_POINTER)
	{
		fn_ref = self.gen_expr(call.callee)!;
	}
	else
	{
		type_store::NodeIndex cur = callee.cast.operand;
		bool direct = false;
		while (true)
		{
			tree::Node current = cur.get(self.tree);
			switch (current.kind)
			{
				case PAREN_EXPR:
				case ADDR_OF_EXPR:
				case DEREF_EXPR:
					cur = current.unary.operand;
				case CAST:
					if (current.cast.kind != tree::CastKind.FUNCTION_TO_POINTER)
					{
						fn_ref = self.gen_expr(call.callee)!;
						direct = true;
						break;
					}
					cur = current.cast.operand;
				case DECL_REF_EXPR:
					String name_text = self.tree.tok_slice(current.decl_ref.name_tok);
					string_interner::StringId name = self.comp.intern_string(name_text);
					knr_callee = self.is_knr_function(name);
					bool local = false;
					for (sz i = self.symbols.len(); i > 0; i--)
					{
						if (self.symbols[i - 1].name == name)
						{
							local = true; break;
						}
					}
					if (local)
					{
						fn_ref = self.gen_expr(call.callee)!;
					}
					else
					{
						// Hosted standard-library abs functions have builtin semantics even
						// when a translation unit supplies an out-of-line definition.
						if (self.comp.target.os.tag != target::OsTag.FREESTANDING &&
							!self.has_internal_linkage(current.decl_ref.decl) && call.args.len == 1 &&
							(name_text == "fabs" || name_text == "fabsf" || name_text == "fabsl"))
						{
							type_store::QualType expected = name_text == "fabs" ? type_store::DOUBLE :
								(name_text == "fabsf" ? type_store::FLOAT : type_store::LONG_DOUBLE);
							type_store::Func function = call.callee.qt(self.tree).get_func(self.comp)!;
							if (call.qt.eql(expected, self.comp) && function.params.len == 1 &&
								function.kind != type_store::FuncKind.VARIADIC && function.params[0].qt.eql(expected, self.comp))
							{
								self.ensure_scalar_float_width(expected)!;
								// The parser already converted the argument to the parameter type.
								return self.add_un(ir::InstTag.FABS, self.gen_expr(call.args[0])!, expected);
							}
						}
						if (self.comp.target.os.tag != target::OsTag.FREESTANDING &&
							!self.has_internal_linkage(current.decl_ref.decl) && call.args.len == 1 &&
							(name_text == "abs" || name_text == "labs" || name_text == "llabs"))
						{
							type_store::QualType expected = name_text == "abs" ? type_store::INT :
								(name_text == "labs" ? type_store::LONG : type_store::LONG_LONG);
							type_store::Func function = call.callee.qt(self.tree).get_func(self.comp)!;
							if (call.qt.eql(expected, self.comp) && function.params.len == 1 &&
								function.kind != type_store::FuncKind.VARIADIC && function.params[0].qt.eql(expected, self.comp))
							{
								return self.gen_integer_abs(call.args[0], call.qt);
							}
						}
						fn_ref = self.builder.add_symbol(self.symbol_name(name_text, self.has_internal_linkage(current.decl_ref.decl)), value_interner::REF_PTR);
					}
					direct = true;
					break;
				default:
					fn_ref = self.gen_expr(call.callee)!;
					direct = true;
					break;
			}
			if (direct) break;
		}
	}

	if (self.is_darwin_arm64()) return self.darwin_call(fn_ref, call);

	bool aggregate_result = self.is_record_value(call.qt);
	AggClassResult result_class = { .kind = AggClass.IGNORE, .eightbyte_count = 0 };
	ulong result_size = 0;
	ir::Ref result_slot = ir::NONE;
	if (aggregate_result)
	{
		result_class = self.classify_record(call.qt)!;
		self.gen_type(call.qt)!;
		result_size = call.qt.sizeof(self.comp);
		uint slot_size = (uint)((result_size + 7) / 8 * 8);
		result_slot = self.builder.add_alloc(slot_size, call.qt.alignof(self.comp),
			self.type_contains_volatile(call.qt));
	}

	// An aggregate contributes at most two INTEGER words, one MEMORY copy, or
	// no argument for the empty/ignored case. Reserve a compact arena buffer.
	usz capacity = call.args.len * 2 + 1;
	ir::Ref[] args = alloc::new_array(&self.builder.arena, ir::Ref, (sz)capacity);
	bool[] stack_only = alloc::new_array(&self.builder.arena, bool, (sz)capacity);
	uint[] memory_copy_bytes = alloc::new_array(&self.builder.arena, uint, (sz)capacity);
	usz arg_count = 0;
	uint gp_index = 0;
	uint sse_index = 0;
	if (aggregate_result && result_class.kind == AggClass.MEMORY)
	{
		args[arg_count] = result_slot;
		stack_only[arg_count] = false;
		memory_copy_bytes[arg_count] = 0;
		arg_count++;
		gp_index++;
	}

	type_store::Func func_type = call.callee.qt(self.tree).get_func(self.comp)!;
	foreach (i, arg_node : call.args)
	{
		// Named parameters use their declared type; variadic arguments use the
		// promoted expression type that the parser attached to the call.
		bool fixed_parameter = i < func_type.params.len;
		type_store::QualType arg_type = fixed_parameter ? func_type.params[i].qt : arg_node.qt(self.tree);
		if (self.is_record_value(arg_type))
		{
			AggClassResult class = self.classify_record(arg_type)!;
			self.gen_type(arg_type)!;
			if (class.kind == AggClass.IGNORE)
			{
				self.gen_expr(arg_node)!; // Preserve side effects of an empty-aggregate expression.
				continue;
			}
			ir::Ref source = self.gen_expr(arg_node)!;
			if (class.kind == AggClass.VECTOR128 && sse_index < 8)
			{
				args[arg_count] = self.builder.add_inst(ir::InstTag.LOAD, { .ref = source }, self.vector128_carrier(arg_type));
				stack_only[arg_count] = false;
				memory_copy_bytes[arg_count] = 0;
				arg_count++;
				sse_index++;
				continue;
			}
			if (class.kind == AggClass.MEMORY || class.kind == AggClass.X87 || class.kind == AggClass.VECTOR128)
			{
				args[arg_count] = source;
				stack_only[arg_count] = false;
				memory_copy_bytes[arg_count] = (uint)arg_type.sizeof(self.comp);
				if (arg_type.alignof(self.comp) > 8) memory_copy_bytes[arg_count] |= ir::MEMORY_COPY_ALIGN16;
				arg_count++;
				continue;
			}

			uint words = (uint)class.eightbyte_count;
			uint padded_size = words * 8;
			ir::Ref padded = self.builder.add_alloc(padded_size, arg_type.alignof(self.comp) < 8 ? 8 : arg_type.alignof(self.comp));
			self.gen_zero_fill(padded, padded_size)!;
			self.gen_copy(padded, source, arg_type.sizeof(self.comp))!;
			// All eightbytes go in registers, or the whole aggregate goes on the stack.
			bool in_registers = gp_index + class.gp_words() <= 6 && sse_index + class.sse_words() <= 8;
			for (uint word = 0; word < words; word++)
			{
				if (in_registers && class.words[word] == WordClass.NONE) continue;
				// On the stack the words are plain bytes; keep them integer.
				value_interner::InternerRef word_type = in_registers ? word_value_type(class.words[word]) : value_interner::REF_I64;
				args[arg_count] = self.builder.add_inst(ir::InstTag.LOAD,
					{ .ref = self.ptr_at(padded, (ulong)word * 8) }, word_type);
				stack_only[arg_count] = !in_registers;
				memory_copy_bytes[arg_count] = 0;
				arg_count++;
			}
			if (in_registers)
			{
				gp_index += class.gp_words();
				sse_index += class.sse_words();
			}
			continue;
		}

		ir::Ref scalar_arg = self.gen_expr(arg_node)!;
		if (fixed_parameter && (self.is_knr_float_param(func_type, arg_type) ||
			(knr_callee && arg_type.is(self.comp, type_store::TypeTag.FLOAT) && arg_type.bit_sizeof(self.comp) == 32)))
		{
			// A K&R definition is not a prototype: its `float` parameters
			// arrive as the default-promoted double (gcc and clang ABI).
			scalar_arg = self.builder.add_inst(ir::InstTag.FPEXT, { .ref = scalar_arg }, value_interner::REF_F64);
			arg_type = type_store::DOUBLE;
		}
		if (self.is_int128(arg_type))
		{
			// Two i64 words in consecutive GPRs, matching the callee side in gen_fn.
			if (gp_index + 2 > 6) self.fail("TODO: __int128 argument passed on the stack\n")!;
			ir::Ref shift = self.builder.add_constant(value::int_u64(64, self.comp).ref(), self.gen_type(arg_type)!);
			ir::Ref high_wide = self.builder.add_inst(ir::InstTag.BIT_LSHR, { .bin = { .lhs = scalar_arg, .rhs = shift } }, self.gen_type(arg_type)!);
			args[arg_count] = self.builder.add_inst(ir::InstTag.TRUNC, { .ref = scalar_arg }, value_interner::REF_I64);
			stack_only[arg_count] = false;
			memory_copy_bytes[arg_count] = 0;
			arg_count++;
			args[arg_count] = self.builder.add_inst(ir::InstTag.TRUNC, { .ref = high_wide }, value_interner::REF_I64);
			stack_only[arg_count] = false;
			memory_copy_bytes[arg_count] = 0;
			arg_count++;
			gp_index += 2;
			continue;
		}
		if (fixed_parameter && arg_type.is_real_int(self.comp) && arg_type.bit_sizeof(self.comp) < 32)
		{
			ir::InstTag extend = arg_type.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT;
			scalar_arg = self.builder.add_inst(extend, { .ref = scalar_arg }, value_interner::REF_I32);
		}
		args[arg_count] = scalar_arg;
		if (arg_type.is(self.comp, type_store::TypeTag.FLOAT))
		{
			self.ensure_scalar_float_width(arg_type)!;
			if (arg_type.bit_sizeof(self.comp) == 80)
			{
				// SysV x86_64 passes x87 long double in a 16-byte memory slot.
				stack_only[arg_count] = true;
			}
			else
			{
				stack_only[arg_count] = sse_index >= 8;
				if (sse_index < 8) sse_index++;
			}
		}
		else
		{
			stack_only[arg_count] = gp_index >= 6;
			if (gp_index < 6) gp_index++;
		}
		memory_copy_bytes[arg_count] = 0;
		arg_count++;
	}

	value_interner::InternerRef call_type;
	if (aggregate_result && result_class.kind == AggClass.REGISTER)
	{
		uint[2] active;
		result_class.active_words(&active);
		call_type = word_value_type(result_class.words[active[0]]);
	}
	else if (aggregate_result && result_class.kind == AggClass.X87)
	{
		call_type = value_interner::REF_F80;
	}
	else if (aggregate_result && result_class.kind == AggClass.VECTOR128)
	{
		call_type = self.vector128_carrier(call.qt);
	}
	else if (aggregate_result)
	{
		call_type = value_interner::REF_VOID;
	}
	else
	{
		call_type = self.gen_type(call.qt)!;
	}
	ir::Ref[] call_args;
	bool[] call_stack_only;
	uint[] call_memory_copy_bytes;
	if (arg_count == 0)
	{
		call_args = args[1..0];
		call_stack_only = stack_only[1..0];
		call_memory_copy_bytes = memory_copy_bytes[1..0];
	}
	else
	{
		call_args = args[..arg_count - 1];
		call_stack_only = stack_only[..arg_count - 1];
		call_memory_copy_bytes = memory_copy_bytes[..arg_count - 1];
	}
	ir::Ref result = self.builder.add_call_abi(fn_ref, call_args, call_stack_only,
		call_memory_copy_bytes, call_type);
	if (aggregate_result && (result_class.kind == AggClass.REGISTER || result_class.kind == AggClass.X87 ||
		result_class.kind == AggClass.VECTOR128))
	{
		uint[2] active;
		uint active_count = result_class.kind == AggClass.REGISTER ? result_class.active_words(&active) : 1;
		if (active_count > 1)
		{
			ir::Ref high = self.builder.add_call_hi(result, word_value_type(result_class.words[active[1]]));
			self.builder.add_store(self.ptr_at(result_slot, (ulong)active[1] * 8), high);
		}
		self.builder.add_store(self.ptr_at(result_slot, (ulong)active[0] * 8), result);
		return result_slot;
	}
	if (aggregate_result) return result_slot;
	return result;
}

<* A `float` parameter of an old-style (K&R) function type, which is passed
   as the default-promoted double. *>
fn bool CodeGen.is_knr_float_param(&self, type_store::Func func_type, type_store::QualType param_qt)
{
	return func_type.kind == type_store::FuncKind.OLD_STYLE && param_qt.is(self.comp, type_store::TypeTag.FLOAT) &&
		param_qt.bit_sizeof(self.comp) == 32;
}

<* `pointer + offset` for an i32 va_list offset field. *>
fn ir::Ref CodeGen.va_offset_address(&self, ir::Ref base, ir::Ref offset32)
{
	ir::Ref wide = self.builder.add_inst(ir::InstTag.ZEXT, { .ref = offset32 }, value_interner::REF_I64);
	return self.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = base, .rhs = wide } }, value_interner::REF_PTR);
}

<*
 SysV `va_arg(list, struct/union)`: a register-class aggregate comes from the
 register save area when all its eightbytes still fit (INTEGER words from
 gp_offset, SSE words from fp_offset), otherwise from the overflow area like a
 MEMORY-class one. The value is copied into a fresh temporary, whose address is
 the record value.
*>
fn ir::Ref? CodeGen.gen_va_arg_record(&self, type_store::NodeIndex list_node, type_store::QualType qt)
{
	AggClassResult class = self.classify_record(qt)!;
	self.gen_type(qt)!;
	ulong size = qt.sizeof(self.comp);
	uint alignment = qt.alignof(self.comp);
	uint padded_size = (uint)((size + 7) / 8 * 8);
	ir::Ref result = self.builder.add_alloc(padded_size == 0 ? 1 : padded_size, alignment < 8 ? 8 : alignment);
	ir::Ref list = self.gen_expr(list_node)!;
	if (class.kind == AggClass.IGNORE) return result;

	ir::Ref overflow_label = self.builder.make_label("va_arg.agg_mem");
	ir::Ref join_label = self.builder.make_label("va_arg.agg_join");
	if (class.kind == AggClass.VECTOR128)
	{
		// One whole XMM save slot (16 bytes at fp_offset).
		ir::Ref fp_offset = self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.ptr_at(list, 4) }, value_interner::REF_I32);
		ir::Ref fp_limit = self.builder.add_constant(value::int_u64(161, self.comp).ref(), value_interner::REF_I32);
		ir::Ref fits = self.builder.add_inst(ir::InstTag.CMP_ULT, { .bin = { .lhs = fp_offset, .rhs = fp_limit } }, value_interner::REF_I1);
		ir::Ref register_label = self.builder.make_label("va_arg.vec_reg");
		self.add_branch(fits, register_label, overflow_label)!;
		self.builder.start_block(register_label);
		ir::Ref save_area = self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.ptr_at(list, 16) }, value_interner::REF_PTR);
		self.gen_copy(result, self.va_offset_address(save_area, fp_offset), 16)!;
		ir::Ref step = self.builder.add_constant(value::int_u64(16, self.comp).ref(), value_interner::REF_I32);
		self.builder.add_store(self.ptr_at(list, 4), self.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = fp_offset, .rhs = step } }, value_interner::REF_I32));
		self.builder.add_jump(join_label);
	}
	else if (class.kind == AggClass.REGISTER)
	{
		uint gp_words = class.gp_words();
		uint sse_words = class.sse_words();
		ir::Ref gp_offset = self.builder.add_inst(ir::InstTag.LOAD, { .ref = list }, value_interner::REF_I32);
		ir::Ref fp_offset = self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.ptr_at(list, 4) }, value_interner::REF_I32);
		// gp_offset <= 48 - 8 * gp_words and fp_offset <= 176 - 16 * sse_words.
		ir::Ref gp_limit = self.builder.add_constant(value::int_u64((ulong)(48 - 8 * gp_words + 1), self.comp).ref(), value_interner::REF_I32);
		ir::Ref fp_limit = self.builder.add_constant(value::int_u64((ulong)(176 - 16 * sse_words + 1), self.comp).ref(), value_interner::REF_I32);
		ir::Ref gp_fits = self.builder.add_inst(ir::InstTag.CMP_ULT, { .bin = { .lhs = gp_offset, .rhs = gp_limit } }, value_interner::REF_I1);
		ir::Ref fp_fits = self.builder.add_inst(ir::InstTag.CMP_ULT, { .bin = { .lhs = fp_offset, .rhs = fp_limit } }, value_interner::REF_I1);
		ir::Ref fits = self.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { .lhs = gp_fits, .rhs = fp_fits } }, value_interner::REF_I1);
		ir::Ref register_label = self.builder.make_label("va_arg.agg_reg");
		self.add_branch(fits, register_label, overflow_label)!;

		self.builder.start_block(register_label);
		ir::Ref save_area = self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.ptr_at(list, 16) }, value_interner::REF_PTR);
		ir::Ref gp_address = self.va_offset_address(save_area, gp_offset);
		ir::Ref fp_address = self.va_offset_address(save_area, fp_offset);
		uint gp_used;
		uint sse_used;
		for (uint word = 0; word < (uint)class.eightbyte_count; word++)
		{
			ir::Ref source;
			if (class.words[word] == WordClass.NONE) continue;
			if (class.is_sse(word))
			{
				source = self.ptr_at(fp_address, (ulong)sse_used++ * 16);
			}
			else
			{
				source = self.ptr_at(gp_address, (ulong)gp_used++ * 8);
			}
			ir::Ref value = self.builder.add_inst(ir::InstTag.LOAD, { .ref = source }, value_interner::REF_I64);
			self.builder.add_store(self.ptr_at(result, (ulong)word * 8), value);
		}
		if (gp_words != 0)
		{
			ir::Ref step = self.builder.add_constant(value::int_u64((ulong)(8 * gp_words), self.comp).ref(), value_interner::REF_I32);
			self.builder.add_store(list, self.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = gp_offset, .rhs = step } }, value_interner::REF_I32));
		}
		if (sse_words != 0)
		{
			ir::Ref step = self.builder.add_constant(value::int_u64((ulong)(16 * sse_words), self.comp).ref(), value_interner::REF_I32);
			self.builder.add_store(self.ptr_at(list, 4), self.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = fp_offset, .rhs = step } }, value_interner::REF_I32));
		}
		self.builder.add_jump(join_label);
	}
	else
	{
		self.builder.add_jump(overflow_label);
	}

	self.builder.start_block(overflow_label);
	ir::Ref overflow_field = self.ptr_at(list, 8);
	ir::Ref overflow_address = self.builder.add_inst(ir::InstTag.LOAD, { .ref = overflow_field }, value_interner::REF_PTR);
	if (alignment > 8)
	{
		ir::Ref bias = self.builder.add_constant(value::int_u64((ulong)alignment - 1, self.comp).ref(), value_interner::REF_I64);
		ir::Ref mask = self.builder.add_constant(value::int_u64(~((ulong)alignment - 1), self.comp).ref(), value_interner::REF_PTR);
		ir::Ref biased = self.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = overflow_address, .rhs = bias } }, value_interner::REF_PTR);
		overflow_address = self.builder.add_inst(ir::InstTag.BIT_AND, { .bin = { .lhs = biased, .rhs = mask } }, value_interner::REF_PTR);
	}
	self.gen_copy(result, overflow_address, size)!;
	self.builder.add_store(overflow_field, self.ptr_at(overflow_address, padded_size));
	self.builder.add_jump(join_label);

	self.builder.start_block(join_label);
	return result;
}

<* The right operand of the calculation `CAST*(op(CAST*(<dummy>), operand))`
   that a compound assignment's rhs holds, if it has that shape. *>
fn bool CodeGen.compound_assign_operand(&self, tree::NodeBinary bin, type_store::NodeIndex* operand)
{
	type_store::NodeIndex calc = bin.rhs;
	while (calc.get(self.tree).kind == tree::NodeKind.CAST) calc = calc.get(self.tree).cast.operand;
	tree::Node calc_node = calc.get(self.tree);
	switch (calc_node.kind)
	{
		case ADD_EXPR:
		case SUB_EXPR:
		case MUL_EXPR:
		case DIV_EXPR:
		case MOD_EXPR:
		case SHL_EXPR:
		case SHR_EXPR:
		case BIT_AND_EXPR:
		case BIT_OR_EXPR:
		case BIT_XOR_EXPR:
			break;
		default:
			return false;
	}
	type_store::NodeIndex dummy = calc_node.binary.lhs;
	while (dummy.get(self.tree).kind == tree::NodeKind.CAST) dummy = dummy.get(self.tree).cast.operand;
	if (dummy.get(self.tree).kind != tree::NodeKind.COMPOUND_ASSIGN_DUMMY_EXPR) return false;
	*operand = calc_node.binary.rhs;
	return true;
}

<*
 `x op= y`. As gcc does (PR c/58943), `y` is evaluated before `x` is read, so
 `x |= f()` sees f's own writes to x. The precomputed operand is served from
 the expression cache when the calculation is generated.
*>
fn ir::Ref? CodeGen.gen_compound_assign(&self, tree::NodeBinary bin)
{
	bool old_cached = self.has_cached_expr;
	type_store::NodeIndex old_cached_node = self.cached_expr_node;
	ir::Ref old_cached_value = self.cached_expr_value;
	defer
	{
		self.has_cached_expr = old_cached; self.cached_expr_node = old_cached_node; self.cached_expr_value = old_cached_value;
	}
	if (self.is_bitfield_lvalue(bin.lhs))
	{
		MemberBase member = self.gen_member_base(bin.lhs)!;
		BitfieldLval lval = self.bitfield_lval(member.ptr, member.field, member.record_size, member.is_volatile)!;
		self.precompute_compound_operand(bin)!;
		ir::Ref old_value = self.load_bitfield(lval)!;
		bool old_has_dummy = self.has_compound_assign_dummy;
		ir::Ref old_dummy = self.compound_assign_dummy;
		defer
		{
			self.has_compound_assign_dummy = old_has_dummy;
			self.compound_assign_dummy = old_dummy;
		}
		self.has_compound_assign_dummy = true;
		self.compound_assign_dummy = old_value;
		ir::Ref rhs = self.gen_expr(bin.rhs)!;
		return self.store_bitfield(lval, rhs);
	}
	if (try atomic = self.gen_atomic_compound_assign(bin)) return atomic;
	ir::Ref lhs = self.gen_lval(bin.lhs)!;
	self.precompute_compound_operand(bin)!;
	bool old_has_dummy = self.has_compound_assign_dummy;
	ir::Ref old_dummy = self.compound_assign_dummy;
	defer
	{
		self.has_compound_assign_dummy = old_has_dummy; self.compound_assign_dummy = old_dummy;
	}
	self.has_compound_assign_dummy = true;
	self.compound_assign_dummy = lhs;
	ir::Ref rhs = self.gen_expr(bin.rhs)!;
	if (!self.store_vector_assigned(lhs, rhs, bin.lhs.qt(self.tree))) self.store_assigned(lhs, rhs, bin.lhs.qt(self.tree));
	return rhs;
}

<* Evaluate a compound assignment's right operand now and cache it (the
   caller restores the cache). Vector operands keep the generic order. *>
fn void? CodeGen.precompute_compound_operand(&self, tree::NodeBinary bin)
{
	type_store::NodeIndex operand;
	if (!self.compound_assign_operand(bin, &operand)) return;
	if (self.is_vector(operand.qt(self.tree)) || self.is_vector(bin.lhs.qt(self.tree))) return;
	ir::Ref value = self.gen_expr(operand)!;
	self.has_cached_expr = true;
	self.cached_expr_node = operand;
	self.cached_expr_value = value;
}

<* gen_atomic_compound_assign: not an `_Atomic` integer or pointer lhs. *>
faultdef NOT_ATOMIC_COMPOUND;

<* `x op= y` on an `_Atomic` integer or pointer object as one atomic
   read-modify-write: evaluate `y` once, then load x, compute, and
   compare-exchange, retrying with the value found until it succeeds. *>
fn ir::Ref? CodeGen.gen_atomic_compound_assign(&self, tree::NodeBinary bin)
{
	type_store::QualType lhs_qt = bin.lhs.qt(self.tree);
	if (!lhs_qt.is(self.comp, type_store::TypeTag.ATOMIC)) return NOT_ATOMIC_COMPOUND~;
	type_store::QualType value_qt = lhs_qt.non_atomic(self.comp).unqualified();
	if (!value_qt.is_int(self.comp) && !value_qt.is_pointer(self.comp)) return NOT_ATOMIC_COMPOUND~;
	uint bits = (uint)value_qt.bit_sizeof(self.comp);
	if (bits != 8 && bits != 16 && bits != 32 && bits != 64) return NOT_ATOMIC_COMPOUND~;
	value_interner::InternerRef value_ty = self.gen_type(value_qt)!;
	if (value_ty == value_interner::REF_I1) return NOT_ATOMIC_COMPOUND~;
	// The calculation is `op(<dummy>, y)` under implicit conversions.
	type_store::NodeIndex calc = bin.rhs;
	while (calc.get(self.tree).kind == tree::NodeKind.CAST) calc = calc.get(self.tree).cast.operand;
	tree::Node calc_node = calc.get(self.tree);
	type_store::NodeIndex operand = calc_node.binary.rhs;

	ir::Ref ptr = self.gen_lval(bin.lhs)!;
	ir::Ref operand_value = self.gen_expr(operand)!;
	bool old_cached = self.has_cached_expr;
	type_store::NodeIndex old_cached_node = self.cached_expr_node;
	ir::Ref old_cached_value = self.cached_expr_value;
	bool old_has_dummy = self.has_compound_assign_dummy;
	bool old_dummy_is_value = self.compound_dummy_is_value;
	ir::Ref old_dummy = self.compound_assign_dummy;
	defer
	{
		self.has_cached_expr = old_cached; self.cached_expr_node = old_cached_node; self.cached_expr_value = old_cached_value;
		self.has_compound_assign_dummy = old_has_dummy; self.compound_dummy_is_value = old_dummy_is_value;
		self.compound_assign_dummy = old_dummy;
	}
	self.has_cached_expr = true;
	self.cached_expr_node = operand;
	self.cached_expr_value = operand_value;

	ir::Ref slot = self.builder.add_alloc(bits / 8, bits / 8);
	self.builder.add_store(slot, self.builder.add_atomic_load(ptr, ir::AtomicOrder.SEQ_CST, value_ty));
	ir::Ref retry = self.builder.make_label("atomic.retry");
	ir::Ref done = self.builder.make_label("atomic.done");
	self.builder.add_jump(retry);
	self.builder.start_block(retry);
	ir::Ref current = self.builder.add_inst(ir::InstTag.LOAD, { .ref = slot }, value_ty);
	self.has_compound_assign_dummy = true;
	self.compound_dummy_is_value = true;
	self.compound_assign_dummy = current;
	ir::Ref updated = self.gen_expr(bin.rhs)!;
	ir::Ref swapped = self.atomic_intrinsic_call("cmpxchg", bits, { ptr, slot, updated }, value_interner::REF_I1);
	self.add_branch(swapped, done, retry)!;
	self.builder.start_block(done);
	return updated;
}

<* Store an assigned scalar: a seq_cst atomic store for an `_Atomic` object
   (C11 7.17.1p6; integer/pointer compound assignment is gen_atomic_compound_assign),
   otherwise an ordinary (possibly volatile) store. *>
fn void CodeGen.store_assigned(&self, ir::Ref ptr, ir::Ref value, type_store::QualType lhs_qt)
{
	if (lhs_qt.is(self.comp, type_store::TypeTag.ATOMIC))
	{
		self.builder.add_atomic_store(ptr, value, ir::AtomicOrder.SEQ_CST);
		return;
	}
	self.builder.add_store(ptr, value, self.access_is_volatile(lhs_qt));
}

<* `signed_tag` for a signed integer `qt`, else `unsigned_tag` (pointers compare unsigned). *>
fn ir::InstTag CodeGen.signed_tag(&self, type_store::QualType qt, ir::InstTag signed_tag, ir::InstTag unsigned_tag)
{
	if (qt.is_pointer(self.comp)) return unsigned_tag;
	if (!qt.is_int(self.comp)) return signed_tag;
	return qt.signedness(self.comp) == SIGNED ? signed_tag : unsigned_tag;
}

<* The signed or unsigned CMP_* tag for an ordered comparison, from its (converted) operand type. *>
fn ir::InstTag CodeGen.ordered_compare_tag(&self, tree::NodeKind kind, tree::NodeBinary bin)
{
	type_store::QualType qt = bin.lhs.qt(self.tree);
	switch (kind)
	{
		case LESS_THAN_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SLT, ir::InstTag.CMP_ULT);
		case LESS_THAN_EQUAL_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SLTE, ir::InstTag.CMP_ULTE);
		case GREATER_THAN_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SGT, ir::InstTag.CMP_UGT);
		case GREATER_THAN_EQUAL_EXPR: return self.signed_tag(qt, ir::InstTag.CMP_SGTE, ir::InstTag.CMP_UGTE);
		default: unreachable("not an ordered comparison");
	}
}

<* Keep unsupported float widths at the existing boundary; x86_64 also lowers scalar F80. *>
fn void? CodeGen.ensure_scalar_float_width(&self, type_store::QualType qt)
{
	ulong bits = qt.bit_sizeof(self.comp);
	if (bits == 32 || bits == 64) return;
	if (bits == 80 && self.comp.target.cpu.arch == target::Arch.X86_64) return;
	// `__float128`: arithmetic becomes libgcc calls (ir_soft_float.c3).
	if (bits == 128 && self.comp.target.cpu.arch == target::Arch.X86_64) return;
	// `_Float16`: computed in float through libgcc conversions (ir_soft_float.c3).
	if (bits == 16 && self.comp.target.cpu.arch == target::Arch.X86_64) return;
	self.fail("TODO lower non-f32/f64 floating point\n")!;
}

<* Select C scalar comparison semantics from the converted left operand type. *>
fn ir::InstTag CodeGen.compare_tag(&self, tree::NodeKind kind, tree::NodeBinary bin)
{
	if (bin.lhs.qt(self.tree).is(self.comp, type_store::TypeTag.FLOAT))
	{
		switch (kind)
		{
			case EQUAL_EXPR: return ir::InstTag.FCMP_OEQ;
			case NOT_EQUAL_EXPR: return ir::InstTag.FCMP_UNE;
			case LESS_THAN_EXPR: return ir::InstTag.FCMP_OLT;
			case LESS_THAN_EQUAL_EXPR: return ir::InstTag.FCMP_OLE;
			case GREATER_THAN_EXPR: return ir::InstTag.FCMP_OGT;
			case GREATER_THAN_EQUAL_EXPR: return ir::InstTag.FCMP_OGE;
			default: unreachable("not a comparison expression");
		}
	}
	switch (kind)
	{
		case EQUAL_EXPR: return ir::InstTag.CMP_EQ;
		case NOT_EQUAL_EXPR: return ir::InstTag.CMP_NE;
		case LESS_THAN_EXPR:
		case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR:
		case GREATER_THAN_EQUAL_EXPR: return self.ordered_compare_tag(kind, bin);
		default: unreachable("not a comparison expression");
	}
}

fn ir::Ref? CodeGen.gen_bin_op(&self, tree::NodeBinary bin, ir::InstTag tag)
{
	ir::Ref lhs = self.gen_expr(bin.lhs)!;
	ir::Ref rhs = self.gen_expr(bin.rhs)!;
	return self.add_bin(tag, lhs, rhs, bin.qt);
}

fn ir::Ref? CodeGen.gen_comparison(&self, tree::NodeBinary bin, ir::InstTag tag)
{
	ir::Ref lhs = self.gen_expr(bin.lhs)!;
	ir::Ref rhs = self.gen_expr(bin.rhs)!;
	return self.builder.add_inst(tag, { .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I1);
}

fn ir::Ref? CodeGen.gen_ptr_arithmetic(&self, ir::Ref ptr, ir::Ref offset, type_store::QualType offset_type,
	type_store::QualType pointer_type, bool subtract)
{
	type_store::QualType child = pointer_type.child_type(self.comp);
	ulong? child_size = child.sizeof_or_null(self.comp);
	ulong size = child_size ?? 1;
	if (catch child_size)
	{
		if (self.is_vla(child)) size = 0;
	}
	else
	{
		size = self.object_size(child);
	}
	ulong offset_bits = offset_type.bit_sizeof(self.comp);
	ir::Ref wide_offset = offset;
	if (offset_bits < 64)
	{
		ir::InstTag extend = offset_type.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT;
		wide_offset = self.builder.add_inst(extend, { .ref = offset }, value_interner::REF_I64);
	}
	else if (offset_bits > 64)
	{
		wide_offset = self.builder.add_inst(ir::InstTag.TRUNC, { .ref = offset }, value_interner::REF_I64);
	}
	if (subtract) wide_offset = self.builder.add_inst(ir::InstTag.NEGATE, { .ref = wide_offset }, value_interner::REF_I64);
	if (size != 1)
	{
		// size 0 marks a VLA element: its byte size is only known at runtime.
		ir::Ref size_inst = size == 0 ? self.gen_type_size(child)! : self.builder.add_constant(value::int_u64(size, self.comp).ref(), value_interner::REF_I64);
		wide_offset = self.builder.add_inst(ir::InstTag.MUL,
			{ .bin = { .lhs = wide_offset, .rhs = size_inst } }, value_interner::REF_I64);
	}
	return self.builder.add_inst(ir::InstTag.ADD,
		{ .bin = { .lhs = ptr, .rhs = wide_offset } }, value_interner::REF_PTR);
}

<* Object storage uses the ABI's padded size for x87 long double values. *>
fn ulong CodeGen.object_size(&self, type_store::QualType qt)
{
	if (qt.is(self.comp, type_store::TypeTag.FLOAT) && qt.bit_sizeof(self.comp) == 80) return 16;
	if (qt.is(self.comp, type_store::TypeTag.ARRAY))
	{
		if (try count = qt.array_len(self.comp))
		{
			ulong size = self.object_size(qt.child_type(self.comp)) * count;
			ulong alignment = qt.alignof(self.comp);
			return ((size + alignment - 1) / alignment) * alignment;
		}
	}
	return qt.sizeof(self.comp);
}

fn ir::Ref? CodeGen.gen_ptr_difference(&self, ir::Ref lhs, ir::Ref rhs, type_store::QualType pointer_type,
	type_store::QualType result_type)
{
	type_store::QualType child = pointer_type.child_type(self.comp);
	ulong? child_size = child.sizeof_or_null(self.comp);
	ulong size = child_size ?? 1;
	if (catch child_size)
	{
		if (self.is_vla(child)) size = 0;
	}
	else
	{
		size = self.object_size(child);
	}
	ir::Ref difference = self.builder.add_inst(ir::InstTag.SUB,
		{ .bin = { .lhs = lhs, .rhs = rhs } }, value_interner::REF_I64);
	if (size != 1)
	{
		ir::Ref size_inst = size == 0 ? self.gen_type_size(child)! : self.builder.add_constant(value::int_u64(size, self.comp).ref(), value_interner::REF_I64);
		difference = self.builder.add_inst(ir::InstTag.SDIV,
			{ .bin = { .lhs = difference, .rhs = size_inst } }, value_interner::REF_I64);
	}
	value_interner::InternerRef result_ir_type = self.gen_type(result_type)!;
	if (result_ir_type == value_interner::REF_I64) return difference;
	if (result_type.bit_sizeof(self.comp) < 64)
	{
		return self.builder.add_inst(ir::InstTag.TRUNC, { .ref = difference }, result_ir_type);
	}
	return self.builder.add_inst(ir::InstTag.SEXT, { .ref = difference }, result_ir_type);
}

fn void? CodeGen.gen_initializer(&self, ir::Ref ptr, type_store::QualType dest_type, type_store::NodeIndex initializer)
{
	tree::Node node = initializer.get(self.tree);
	bool aggregate = self.is_array_like(dest_type) || @ok(dest_type.get_record(self.comp));
	switch (node.kind)
	{
		case ARRAY_INIT_EXPR:
		case STRUCT_INIT_EXPR:
		case UNION_INIT_EXPR:
		case ARRAY_FILLER_EXPR:
		case DEFAULT_INIT_EXPR:
		case COMPOUND_LITERAL_EXPR:
		case STRING_LITERAL_EXPR:
			if (!aggregate && node.kind == tree::NodeKind.DEFAULT_INIT_EXPR)
			{
				// `int x = {}`: the scalar's zero value.
				self.builder.add_store(ptr, self.builder.add_constant(value::ZERO.ref(), self.gen_type(dest_type)!));
				return;
			}
			if (!aggregate)
			{
				if (node.kind == tree::NodeKind.STRING_LITERAL_EXPR || node.kind == tree::NodeKind.COMPOUND_LITERAL_EXPR) break;
				return self.fail(string::tformat("TODO CodeGen.genInitializer %s\n", node.kind.name));
			}
			// Aggregates: zero the whole object, then store each explicit element
			// (implicit elements, fillers and padding stay zero, C 6.7.9p10/p21).
			ulong? size = dest_type.sizeof_or_null(self.comp);
			if (catch size) return self.fail("TODO CodeGen.genInitializer variably sized aggregate\n");
			self.gen_zero_fill(ptr, self.object_size(dest_type))!;
			return self.gen_init_elements(ptr, dest_type, initializer);
		default:
			break;
	}
	if (aggregate)
	{
		if (self.is_record_value(dest_type) && self.is_record_value(initializer.qt(self.tree)))
		{
			ir::Ref source = self.gen_expr(initializer)!;
			return self.gen_copy_value(ptr, source, dest_type);
		}
		return self.fail(string::tformat("TODO CodeGen.genInitializer aggregate %s\n", node.kind.name));
	}
	ir::Ref result = self.gen_expr(initializer)!;
	self.builder.add_store(ptr, result);
}

<* `base + offset` bytes. *>
fn ir::Ref CodeGen.ptr_at(&self, ir::Ref base, ulong offset)
{
	if (offset == 0) return base;
	ir::Ref off = self.builder.add_constant(value::int_u64(offset, self.comp).ref(), value_interner::REF_I64);
	return self.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = base, .rhs = off } }, value_interner::REF_PTR);
}

<* Call the C library `name(args...)` returning a pointer (memset/memcpy). *>
fn void CodeGen.call_lib(&self, String name, ir::Ref[] args)
{
	ir::Ref fn_ref = self.builder.add_symbol(name, value_interner::REF_PTR);
	self.builder.add_call(fn_ref, args, value_interner::REF_PTR);
}

<* Copy an aggregate object by bytes, using typed chunks for small objects. *>
fn void? CodeGen.gen_copy(&self, ir::Ref destination, ir::Ref source, ulong size)
{
	if (size > 64)
	{
		ir::Ref count = self.builder.add_constant(value::int_u64(size, self.comp).ref(), value_interner::REF_I64);
		self.call_lib("memcpy", { destination, source, count });
		return;
	}
	ulong offset = 0;
	while (offset < size)
	{
		ulong remaining = size - offset;
		value_interner::InternerRef chunk_type = remaining >= 8 ? value_interner::REF_I64 :
			remaining >= 4 ? value_interner::REF_I32 : remaining >= 2 ? value_interner::REF_I16 : value_interner::REF_I8;
		ulong chunk_size = remaining >= 8 ? 8 : remaining >= 4 ? 4 : remaining >= 2 ? 2 : 1;
		ir::Ref value = self.builder.add_inst(ir::InstTag.LOAD,
			{ .ref = self.ptr_at(source, offset) }, chunk_type);
		self.builder.add_store(self.ptr_at(destination, offset), value);
		offset += chunk_size;
	}
}

<* Zero `size` bytes at `ptr`: inline 8/4/2/1-byte stores for small objects, memset otherwise. *>
fn void? CodeGen.gen_zero_fill(&self, ir::Ref ptr, ulong size)
{
	if (size > 64)
	{
		ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), value_interner::REF_I32);
		ir::Ref count = self.builder.add_constant(value::int_u64(size, self.comp).ref(), value_interner::REF_I64);
		self.call_lib("memset", { ptr, zero, count });
		return;
	}
	ulong at = 0;
	while (at < size)
	{
		ulong left = size - at;
		value_interner::InternerRef ty = left >= 8 ? value_interner::REF_I64 : left >= 4 ? value_interner::REF_I32 :
			left >= 2 ? value_interner::REF_I16 : value_interner::REF_I8;
		ulong width = left >= 8 ? 8 : left >= 4 ? 4 : left >= 2 ? 2 : 1;
		self.builder.add_store(self.ptr_at(ptr, at), self.builder.add_constant(value::ZERO.ref(), ty));
		at += width;
	}
}

<* Store the explicit elements of `initializer` into zeroed storage at `ptr` of type `qt`. *>
fn void? CodeGen.gen_init_elements(&self, ir::Ref ptr, type_store::QualType qt, type_store::NodeIndex initializer)
{
	tree::Node node = initializer.get(self.tree);
	switch (node.kind)
	{
		case DEFAULT_INIT_EXPR:
		case ARRAY_FILLER_EXPR:
			return;
		case PAREN_EXPR:
			return self.gen_init_elements(ptr, qt, node.unary.operand);
		case COMPOUND_LITERAL_EXPR:
			if (self.is_array_like(qt) || @ok(qt.get_record(self.comp)))
			{
				return self.gen_init_elements(ptr, qt, node.compound_literal.initializer);
			}
		case ARRAY_INIT_EXPR:
			if (!self.is_array_like(qt)) break;
			type_store::QualType elem = self.is_vector(qt) ? self.vector_elem(qt) : qt.child_type(self.comp);
			ulong elem_size = self.object_size(elem);
			ulong index = 0;
			foreach (item : node.container_init.items)
			{
				tree::Node item_node = item.get(self.tree);
				if (item_node.kind == tree::NodeKind.ARRAY_FILLER_EXPR)
				{
					index += item_node.array_filler.count;
					continue;
				}
				self.gen_init_elements(self.ptr_at(ptr, index * elem_size), elem, item)!;
				index++;
			}
			return;
		case STRUCT_INIT_EXPR:
			type_store::Record? record = qt.get_record(self.comp);
			if (catch record) break;
			foreach (i, item : node.container_init.items)
			{
				if (i >= record.fields.len) break;
				self.gen_field_init(ptr, record.fields[i], item, qt.sizeof(self.comp))!;
			}
			return;
		case UNION_INIT_EXPR:
			type_store::Record? record = qt.get_record(self.comp);
			if (catch record) break;
			if (node.union_init.initializer.is_null()) return;
			if ((usz)node.union_init.field_index >= record.fields.len) break;
			return self.gen_field_init(ptr, record.fields[node.union_init.field_index],
				node.union_init.initializer.unwrap(), qt.sizeof(self.comp));
		case STRING_LITERAL_EXPR:
			if (!qt.is(self.comp, type_store::TypeTag.ARRAY)) break;
			value::Value val = self.tree.value_of(initializer)!!;
			ulong size = qt.sizeof(self.comp);
			ulong count = (ulong)val.to_bytes(self.comp).len;
			if (count > size) count = size; // `char s[3] = "abc"` drops the NUL
			ir::Ref string_ptr = self.builder.add_constant(val.ref(), value_interner::REF_PTR);
			ir::Ref count_ref = self.builder.add_constant(value::int_u64(count, self.comp).ref(), value_interner::REF_I64);
			self.call_lib("memcpy", { ptr, string_ptr, count_ref });
			return;
		default:
			break;
	}
	if (self.is_array_like(qt) || @ok(qt.get_record(self.comp)))
	{
		if (self.is_record_value(qt) && self.is_record_value(initializer.qt(self.tree)))
		{
			ir::Ref source = self.gen_expr(initializer)!;
			return self.gen_copy_value(ptr, source, qt);
		}
		return self.fail(string::tformat("TODO CodeGen.genInitializer aggregate element %s\n", node.kind.name));
	}
	// Integer and pointer zeros are already in place (not -0.0: its sign bit is set).
	if (try val = self.tree.value_of(initializer))
	{
		if (!val.is_pointer(self.comp) && val.is_zero(self.comp) && !qt.is_float(self.comp)) return;
	}
	self.builder.add_store(ptr, self.gen_expr(initializer)!);
}

<* One record member of a local aggregate initializer. *>
fn void? CodeGen.gen_field_init(&self, ir::Ref ptr, type_store::RecordField field, type_store::NodeIndex item,
	ulong record_size)
{
	if (item.get(self.tree).kind == tree::NodeKind.DEFAULT_INIT_EXPR) return;
	if (field.bit_width != type_store::BIT_WIDTH_NULL)
	{
		if (field.bit_width == 0 || field.name_tok == (type_store::TokenIndex)0) return;
		BitfieldLval lval = self.bitfield_lval(ptr, field, record_size)!;
		self.store_bitfield(lval, self.gen_expr(item)!)!;
		return;
	}
	return self.gen_init_elements(self.ptr_at(ptr, field.layout.offset_bits / 8), field.qt, item);
}

<* A scalar access through an lvalue of type `qt` is volatile: `volatile` on the
   type or on any typedef/typeof layer naming it. *>
fn bool CodeGen.access_is_volatile(&self, type_store::QualType qt)
{
	type_store::QualType cur = qt;
	while (true)
	{
		if (cur.is_volatile) return true;
		type_store::Type ty = cur.get_type(self.comp);
		switch (ty.tag)
		{
			case TYPEOF: cur = ty.type_of.base;
			case TYPEDEF: cur = ty.type_def.base;
			default: return false;
		}
	}
}

<* Whether an object or one of its by-value aggregate members is volatile or atomic. *>
fn bool CodeGen.type_contains_volatile(&self, type_store::QualType qt)
{
	if (qt.is_volatile) return true;
	type_store::Type ty = qt.base(self.comp).ty;
	switch (ty.tag)
	{
		// Marking atomics volatile also prevents ordinary aggregate memory
		// promotion; scalar atomics still use dedicated atomic IR operations.
		case ATOMIC: return true;
		case ARRAY: return self.type_contains_volatile(ty.array.elem);
		case STRUCT:
		case UNION:
			foreach (field : ty.record.fields)
			{
				if (self.type_contains_volatile(field.qt)) return true;
			}
		default: return false;
	}
	return false;
}

fn void? CodeGen.gen_var(&self, tree::NodeVariable decl, type_store::NodeIndex declaration = type_store::NODE_NULL)
{
	if (decl.thread_local) return self.fail("TODO CodeGen.genVar thread_local\n");

	bool has_declaration = ((type_store::NodeOptIndex)declaration) != type_store::NODE_NULL;
	bool file_scope = has_declaration && self.is_root_declaration(declaration);
	bool block_static = !file_scope && decl.storage_class == tree::VariableStorageClass.STATIC && !decl.implicit;
	bool block_extern = !file_scope && decl.storage_class == tree::VariableStorageClass.EXTERN && decl.initializer.is_null();
	bool implicit_var = decl.implicit;
	bool has_initializer = !decl.initializer.is_null();
	bool extern_declaration = decl.storage_class == tree::VariableStorageClass.EXTERN && !has_initializer;
	bool tentative = file_scope && !has_initializer && !extern_declaration;

	String source_name = self.tree.tok_slice(decl.name_tok);
	String name;
	bool already_emitted = false;
	if (implicit_var)
	{
		already_emitted = self.find_implicit_var(declaration).len != 0;
		name = self.implicit_var_name(declaration);
	}
	else if (block_static)
	{
		already_emitted = self.find_emitted_static(declaration).len != 0;
		name = self.block_static_name(declaration, source_name);
	}
	else if (block_extern && has_declaration)
	{
		name = self.symbol_name(source_name, self.has_internal_linkage(declaration));
	}
	else if (has_declaration)
	{
		name = self.symbol_name(source_name, self.has_internal_linkage(declaration));
	}
	else
	{
		name = source_name;
	}

	// __func__ is requested at each lvalue use, but denotes one function-local
	// static object. Static block declarations likewise emit once per AST node.
	if (already_emitted)
	{
		if (block_static)
		{
			string_interner::StringId local_name = self.comp.intern_string(source_name);
			self.symbols.push(
				{
					.name = local_name, .value = self.builder.add_symbol(name, value_interner::REF_PTR)
			}
			);
		}
		return;
	}

	ulong size = 0;
	uint alignment = 0;
	if (!extern_declaration)
	{
		if (try decl.qt.sizeof_or_null(self.comp))
		{
			size = self.object_size(decl.qt);
		}
		else if (tentative && decl.qt.is(self.comp, type_store::TypeTag.ARRAY))
		{
			size = self.object_size(decl.qt.child_type(self.comp));
		}
		else
		{
			return self.fail("TODO CodeGen.genVar incomplete object type\n");
		}
		// GNU: a static initializer for a flexible array member extends the object.
		if (has_initializer) size = max(size, self.flexible_init_size(decl.qt, decl.initializer.unwrap()));
		alignment = (uint)decl.qt.alignof(self.comp);
		if (decl.qt.is(self.comp, type_store::TypeTag.ARRAY) && size >= 16 && alignment < 16) alignment = 16;
	}

	bool common = tentative && !decl.implicit && decl.storage_class != tree::VariableStorageClass.STATIC &&
	self.comp.code_gen_options.common;
	ir::DataSection section = extern_declaration ? ir::DataSection.EXTERN :
	common ? ir::DataSection.COMMON :
	!has_initializer ? ir::DataSection.BSS : ir::DataSection.DATA;
	char[] data;
	if (section == ir::DataSection.DATA)
	{
		data = alloc::new_array(&self.builder.arena, char, (sz)size);
		for (usz i = 0; i < data.len; i++) data[i] = 0;
	}
	else
	{
		data = alloc::new_array(&self.builder.arena, char, 0);
	}

	List{ir::DataReloc} relocations;
	relocations.init(&self.builder.arena);
	if (has_initializer)
	{
		self.write_global_initializer(decl.qt, decl.initializer.unwrap(), data, &relocations)!;
	}
	ir::DataReloc[] used_relocations = relocations.array_view();
	ir::GlobalData global = {
		.size = size,
		.align = alignment,
		.bytes = data,
		.relocs = used_relocations,
		.section = section,
		.tentative = tentative,
		.own_section = self.comp.code_gen_options.data_sections,
		.is_volatile = self.type_contains_volatile(decl.qt),
	};
	ir::Linkage linkage = (block_static || implicit_var ||
		(has_declaration && self.has_internal_linkage(declaration))) ?
	ir::Linkage.INTERNAL : ir::Linkage.EXTERNAL;
	self.builder.add_global(name, linkage, global, has_declaration && self.is_weak(declaration, linkage));
	if (has_declaration) self.apply_retention(name, declaration);

	if (block_static || block_extern)
	{
		string_interner::StringId local_name = self.comp.intern_string(source_name);
		self.symbols.push(
			{
				.name = local_name, .value = self.builder.add_symbol(name, value_interner::REF_PTR)
		}
		);
	}
}

<* Write an unsigned machine value into target-endian bytes, zero extending. *>
fn void CodeGen.write_unsigned_bytes(&self, char[] data, usz start, usz count, ulong value)
{
	bool big_endian = self.comp.target.cpu.arch.big;
	for (usz i = 0; i < count; i++)
	{
		usz source_byte = big_endian ? count - 1 - i : i;
		data[start + i] = source_byte < ulong::size ? (char)(value >> (source_byte * 8)) : 0;
	}
}

<* Serialize an integer's low `bit_count` bits into target-endian storage. *>
fn void CodeGen.write_integer_bytes(&self, char[] data, usz start, usz byte_count, usz bit_count, value::Value val)
{
	char[] little = alloc::new_array(&self.builder.arena, char, (sz)byte_count);
	for (usz i = 0; i < little.len; i++) little[i] = 0;
	if (!val.is_zero(self.comp))
	{
		bigint::BigIntConst integer = val.to_big_int(self.comp);
		for (usz i = 0; i < byte_count; i++)
		{
			usz limb_index = i / 8;
			if (limb_index >= integer.limbs.len) break;
			little[i] = (char)(integer.limbs[limb_index] >> ((i % 8) * 8));
		}
		if (!integer.positive)
		{
			for (usz i = 0; i < byte_count; i++) little[i] = ~little[i];
			usz i = 0;
			while (i < byte_count)
			{
				uint sum = ((uint)(char)little[i] & 0xFF) + 1;
				little[i] = (char)sum;
				if (sum <= 0xFF) break;
				i++;
			}
		}
	}
	if (bit_count % 8 != 0 && byte_count > 0)
	{
		little[byte_count - 1] &= (char)((1 << (bit_count % 8)) - 1);
	}
	bool big_endian = self.comp.target.cpu.arch.big;
	for (usz i = 0; i < byte_count; i++)
	{
		usz dest_byte = big_endian ? byte_count - 1 - i : i;
		data[start + i] = little[dest_byte];
	}
}

<* Serialize a floating constant's raw target-format bits, including ABI padding. *>
fn void CodeGen.write_float_bytes(&self, char[] data, usz start, usz byte_count, ulong bit_count, value::Value val)
{
	primitive_value::PrimitiveType tag;
	switch (bit_count)
	{
		case 16: tag = primitive_value::PrimitiveType.F16;
		case 32: tag = primitive_value::PrimitiveType.F32;
		case 64: tag = primitive_value::PrimitiveType.F64;
		case 80: tag = primitive_value::PrimitiveType.F80;
		case 128: tag = primitive_value::PrimitiveType.F128;
		default: unreachable("unsupported floating storage width");
	}
	uint128 bits = val.to_float(tag, self.comp).float_bits();
	ulong low = (ulong)bits;
	ulong high = (ulong)(bits >> 64);
	usz repr_bytes = (usz)((bit_count + 7) / 8);
	assert(repr_bytes <= byte_count);
	usz padding = byte_count - repr_bytes;
	bool big_endian = self.comp.target.cpu.arch.big;
	usz bits_start = big_endian ? start + padding : start;
	for (usz i = 0; i < repr_bytes; i++)
	{
		usz source_byte = big_endian ? repr_bytes - 1 - i : i;
		ulong word = source_byte < 8 ? low : high;
		usz shift = (source_byte < 8 ? source_byte: source_byte - 8) * 8;
		data[bits_start + i] = (char)(word >> shift);
	}
}

<* Materialize a string literal as an internal byte global and return its symbol. *>
fn String? CodeGen.string_global(&self, type_store::NodeIndex node)
{
	String existing = self.find_emitted_string(node);
	if (existing.len != 0) return existing;
	value::Value val;
	if (try found = self.tree.value_of(node))
	{
		val = found;
	}
	else
	{
		self.fail("TODO CodeGen.genVar string value\n")!;
		return compilation::FATAL_ERROR~;
	}
	primitive_value::PrimitiveValue key = self.comp.interner.get(val.ref());
	if (key.tag != primitive_value::PrimitiveType.BYTES)
	{
		self.fail("TODO CodeGen.genVar string value\n")!;
		return compilation::FATAL_ERROR~;
	}
	String bytes = (String)val.to_bytes(self.comp);
	DString generated;
	generated.init(&self.builder.arena);
	generated.appendf(".str.%s.%d", self.current_fn, self.string_counter);
	self.string_counter++;
	if (self.tu_id >= 0) generated.appendf(".tu%d", self.tu_id);
	String name = generated.str_view();
	ir::GlobalData global = {
		.size = (ulong)bytes.len,
		.align = 1,
		.bytes = (char[])bytes,
		.relocs = alloc::new_array(&self.builder.arena, ir::DataReloc, 0),
		.section = ir::DataSection.RODATA,
		.tentative = false,
		.own_section = false,
		.is_volatile = false,
	};
	self.builder.add_global(name, ir::Linkage.INTERNAL, global);
	self.emitted_strings.push(
		{
			.node = node, .name = name
		}
	);
	return name;
}

<* The internal global holding a compound literal with static storage duration
   (file scope, or C23 `static`), emitted once per literal. *>
fn String? CodeGen.compound_literal_global(&self, type_store::NodeIndex node)
{
	String existing = self.find_emitted_string(node);
	if (existing.len != 0) return existing;
	tree::Node literal = node.get(self.tree);
	type_store::QualType qt = literal.compound_literal.qt;
	if (!@ok(qt.sizeof_or_null(self.comp))) qt = literal.compound_literal.initializer.qt(self.tree);
	ulong size = self.object_size(qt);
	char[] data = alloc::new_array(&self.builder.arena, char, (sz)size);
	for (usz i = 0; i < data.len; i++) data[i] = 0;
	List{ir::DataReloc} relocations;
	relocations.init(&self.builder.arena);
	self.write_global_initializer(qt, literal.compound_literal.initializer, data, &relocations)!;
	DString generated;
	generated.init(&self.builder.arena);
	generated.appendf(".compoundliteral.%s.%d", self.current_fn, self.string_counter);
	self.string_counter++;
	if (self.tu_id >= 0) generated.appendf(".tu%d", self.tu_id);
	String name = generated.str_view();
	ir::GlobalData global = {
		.size = size,
		.align = qt.alignof(self.comp),
		.bytes = data,
		.relocs = relocations.array_view(),
		.section = ir::DataSection.DATA,
		.tentative = false,
		.own_section = false,
		.is_volatile = self.type_contains_volatile(qt),
	};
	self.builder.add_global(name, ir::Linkage.INTERNAL, global);
	self.emitted_strings.push({ .node = node, .name = name });
	return name;
}

<* The constant value of an initializer expression: its saved value, else the
   value under parentheses and value-preserving casts (the parser saves values
   on the innermost operand only, e.g. `(void *)(long)(2)`). *>
fn value::Value? CodeGen.const_init_value(&self, type_store::NodeIndex node_index)
{
	if (try found = self.tree.value_of(node_index)) return found;
	tree::Node node = node_index.get(self.tree);
	switch (node.kind)
	{
		case PAREN_EXPR:
			return self.const_init_value(node.unary.operand);
		case CAST:
			switch (node.cast.kind)
			{
				case NO_OP:
				case BITCAST:
				case INT_CAST:
				case INT_TO_POINTER:
				case POINTER_TO_INT:
				case FUNCTION_TO_POINTER:
					return self.const_init_value(node.cast.operand);
				default:
					return compilation::FATAL_ERROR~;
			}
		default:
			return compilation::FATAL_ERROR~;
	}
}

<* Bytes needed by a record initializer that fills its trailing flexible array
   member (the item's completed array type, from its field offset); 0 if none. *>
fn ulong CodeGen.flexible_init_size(&self, type_store::QualType qt, type_store::NodeIndex initializer)
{
	tree::Node init_node = initializer.get(self.tree);
	switch (init_node.kind)
	{
		case PAREN_EXPR: return self.flexible_init_size(qt, init_node.unary.operand);
		case COMPOUND_LITERAL_EXPR: return self.flexible_init_size(qt, init_node.compound_literal.initializer);
		case STRUCT_INIT_EXPR: break;
		default: return 0;
	}
	type_store::Record? record = qt.get_record(self.comp);
	if (catch record) return 0;
	usz count = record.fields.len;
	if (!count || init_node.container_init.items.len < count) return 0;
	type_store::RecordField last = record.fields[count - 1];
	if (!last.qt.is(self.comp, type_store::TypeTag.ARRAY) || !last.qt.has_incomplete_size(self.comp)) return 0;
	type_store::NodeIndex item = init_node.container_init.items[count - 1];
	if (item.get(self.tree).kind == tree::NodeKind.DEFAULT_INIT_EXPR) return 0;
	ulong item_size = item.qt(self.tree).sizeof_or_null(self.comp) ?? 0;
	return last.layout.offset_bits / 8 + item_size;
}

<* Serialize a constant initializer for a global object of type `qt` into
   `data` (already zeroed, at least `qt`'s size), appending address relocations. *>
fn void? CodeGen.write_global_initializer(&self, type_store::QualType qt, type_store::NodeIndex initializer,
	char[] data, List{ir::DataReloc}* relocs)
{
	assert((self.comp.target.cpu.arch == target::Arch.X86_64 || self.is_darwin_arm64()) && !self.comp.target.cpu.arch.big,
		"global initializer serialization requires a supported little-endian target");
	return self.write_initializer_at(qt, initializer, data, 0, relocs);
}

<* Serialize `initializer` for an object of type `qt` at byte `offset` of `data`. *>
fn void? CodeGen.write_initializer_at(&self, type_store::QualType qt, type_store::NodeIndex initializer,
	char[] data, ulong offset, List{ir::DataReloc}* relocs)
{
	tree::Node init_node = initializer.get(self.tree);
	switch (init_node.kind)
	{
		case DEFAULT_INIT_EXPR:
		case ARRAY_FILLER_EXPR:
			return; // zero bytes, already in place
		case PAREN_EXPR:
			if (qt.is(self.comp, type_store::TypeTag.ARRAY) || @ok(qt.get_record(self.comp)))
			{
				return self.write_initializer_at(qt, init_node.unary.operand, data, offset, relocs);
			}
		case CAST:
			// `static struct S s = ((struct S){...});`: the aggregate rvalue reaches
			// here through a value-preserving cast around the literal.
			if ((init_node.cast.kind == tree::CastKind.LVAL_TO_RVAL || init_node.cast.kind == tree::CastKind.NO_OP) &&
				(qt.is(self.comp, type_store::TypeTag.ARRAY) || @ok(qt.get_record(self.comp))))
			{
				return self.write_initializer_at(qt, init_node.cast.operand, data, offset, relocs);
			}
		case COMPOUND_LITERAL_EXPR:
			// `(struct S){...}` at file scope: its initializer list is the value.
			if (!qt.is_pointer(self.comp))
			{
				return self.write_initializer_at(qt, init_node.compound_literal.initializer, data, offset, relocs);
			}
		case ARRAY_INIT_EXPR:
			if (!qt.is(self.comp, type_store::TypeTag.ARRAY)) break;
			type_store::QualType elem = qt.child_type(self.comp);
			ulong elem_size = self.object_size(elem);
			ulong index = 0;
			foreach (item : init_node.container_init.items)
			{
				tree::Node item_node = item.get(self.tree);
				if (item_node.kind == tree::NodeKind.ARRAY_FILLER_EXPR)
				{
					index += item_node.array_filler.count;
					continue;
				}
				ulong at = offset + index * elem_size;
				if (at + elem_size > data.len) break; // tentative / flexible tail
				self.write_initializer_at(elem, item, data, at, relocs)!;
				index++;
			}
			return;
		case STRUCT_INIT_EXPR:
			type_store::Record? record = qt.get_record(self.comp);
			if (catch record) break;
			foreach (i, item : init_node.container_init.items)
			{
				if (i >= record.fields.len) break;
				self.write_field_initializer(record.fields[i], item, data, offset, relocs)!;
			}
			return;
		case UNION_INIT_EXPR:
			type_store::Record? record = qt.get_record(self.comp);
			if (catch record) break;
			if (init_node.union_init.initializer.is_null()) return;
			if ((usz)init_node.union_init.field_index >= record.fields.len) break;
			return self.write_field_initializer(record.fields[init_node.union_init.field_index],
				init_node.union_init.initializer.unwrap(), data, offset, relocs);
		default:
			break;
	}
	ulong size = qt.sizeof_or_null(self.comp) ?? ((ulong)data.len - offset);
	if (offset + size > data.len) size = (ulong)data.len - offset;
	return self.write_scalar_initializer(qt, initializer, data[(usz)offset:(usz)size], offset, relocs);
}

<* Bit `b` of `v` in two's complement, for bit-fields wider than one limb
   (`__int128 y : 66`). Negative: ~|v| + 1, the carry reaching limb b/64 only
   while every lower limb of |v| is zero. *>
fn bool twos_complement_bit(bigint::BigIntConst v, uint b)
{
	usz index = b / bigint::LIMB_BITS;
	bigint::Limb limb = index < v.limbs.len ? v.limbs[index] : 0;
	if (!v.positive)
	{
		bool carry = true;
		for (usz i = 0; i < index && i < v.limbs.len; i++)
		{
			if (v.limbs[i] != 0) { carry = false; break; }
		}
		limb = ~limb + (carry ? 1UL : 0UL);
	}
	return (limb >> (b % bigint::LIMB_BITS)) & 1 != 0;
}

<* One record member: a byte-aligned field recurses; a bitfield is merged into
   its storage bits (little-endian). *>
fn void? CodeGen.write_field_initializer(&self, type_store::RecordField field, type_store::NodeIndex item,
	char[] data, ulong offset, List{ir::DataReloc}* relocs)
{
	tree::Node item_node = item.get(self.tree);
	if (item_node.kind == tree::NodeKind.DEFAULT_INIT_EXPR) return;
	if (field.bit_width == type_store::BIT_WIDTH_NULL)
	{
		// A flexible array member takes its length from the initializer's completed type.
		type_store::QualType field_qt = field.qt;
		if (field_qt.is(self.comp, type_store::TypeTag.ARRAY) && field_qt.has_incomplete_size(self.comp))
		{
			type_store::QualType item_qt = item.qt(self.tree);
			if (item_qt.is(self.comp, type_store::TypeTag.ARRAY) && !item_qt.has_incomplete_size(self.comp)) field_qt = item_qt;
		}
		return self.write_initializer_at(field_qt, item, data, offset + field.layout.offset_bits / 8, relocs);
	}
	if (field.bit_width == 0) return;
	value::Value? val = self.const_init_value(item);
	if (catch val) return self.fail("TODO CodeGen.genVar bitfield initializer\n");
	bigint::BigIntConst integer = val.to_big_int(self.comp);
	ulong start_bit = offset * 8 + field.layout.offset_bits;
	for (uint b = 0; b < field.bit_width; b++)
	{
		ulong pos = start_bit + b;
		if (field.reverse_storage)
		{
			pos = start_bit + field.bit_width - 1 - b;
			pos = (pos / 8) * 8 + 7 - pos % 8;
		}
		usz byte = (usz)(pos / 8);
		if (byte >= data.len) break;
		char mask = (char)(1 << (pos % 8));
		if (twos_complement_bit(integer, b))
		{
			data[byte] |= mask;
		}
		else
		{
			data[byte] &= ~mask;
		}
	}
}

<* Serialize a scalar (or string-initialized char array) into `data`, the
   object's own bytes; `slot_offset` is their offset within the global. *>
fn void? CodeGen.write_scalar_initializer(&self, type_store::QualType qt, type_store::NodeIndex initializer,
	char[] data, ulong slot_offset, List{ir::DataReloc}* relocs)
{
	tree::Node init_node = initializer.get(self.tree);
	if (qt.scalar_kind(self.comp) == type_store::ScalarKind.COMPLEX_INT ||
	qt.scalar_kind(self.comp) == type_store::ScalarKind.COMPLEX_FLOAT)
	{
		return self.fail("TODO CodeGen.genVar complex initializer\n");
	}

	if (qt.is(self.comp, type_store::TypeTag.ARRAY))
	{
		value::Value val;
		if (try found = self.const_init_value(initializer))
		{
			val = found;
		}
		else
		{
			return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
		}
		primitive_value::PrimitiveValue key = self.comp.interner.get(val.ref());
		if (key.tag != primitive_value::PrimitiveType.BYTES)
		{
			return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
		}
		char[] bytes = val.to_bytes(self.comp);
		usz copy_count = bytes.len < data.len ? bytes.len : data.len;
		data[:copy_count] = bytes[:copy_count];
		return;
	}
	if (@ok(qt.get_record(self.comp)))
	{
		return self.fail(string::tformat("TODO CodeGen.genVar record initializer %s\n", init_node.kind.name));
	}
	type_store::NodeIndex string_node = initializer;
	while (true)
	{
		tree::Node string_expr = string_node.get(self.tree);
		if (string_expr.kind == tree::NodeKind.CAST && ((string_expr.cast.kind == tree::CastKind.ARRAY_TO_POINTER && string_expr.cast.implicit) ||
			string_expr.cast.kind == tree::CastKind.NO_OP || string_expr.cast.kind == tree::CastKind.BITCAST))
		{
			string_node = string_expr.cast.operand;
			continue;
		}
		if (string_expr.kind == tree::NodeKind.PAREN_EXPR)
		{
			string_node = string_expr.unary.operand;
			continue;
		}
		break;
	}
	value::Value val;
	if (try found = self.const_init_value(initializer))
	{
		val = found;
	}
	else if (init_node.kind == tree::NodeKind.CAST && init_node.cast.kind == tree::CastKind.NULL_TO_POINTER)
	{
		// The parser keeps NULL out of the tree value map (see first_missing_value).
		val = value::NULL;
	}
	else if (qt.is(self.comp, type_store::TypeTag.POINTER) && string_node.get(self.tree).kind == tree::NodeKind.STRING_LITERAL_EXPR)
	{
		if (try string_value = self.tree.value_of(string_node))
		{
			val = string_value;
		}
		else
		{
			return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
		}
	}
	else
	{
		return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
	}
	if (data.len == 0) return self.fail("TODO CodeGen.genVar zero-sized initializer\n");
	primitive_value::PrimitiveValue key = self.comp.interner.get(val.ref());

	if (qt.is(self.comp, type_store::TypeTag.POINTER))
	{
		if (key.tag == primitive_value::PrimitiveType.BYTES)
		{
			if (string_node.get(self.tree).kind != tree::NodeKind.STRING_LITERAL_EXPR)
			{
				return self.fail("TODO CodeGen.genVar bytes pointer initializer\n");
			}
			relocs.push({ .offset = slot_offset, .symbol = self.string_global(string_node)!, .addend = 0 });
			return;
		}
		if (key.tag == primitive_value::PrimitiveType.NULL ||
			(key.tag.kind == NumberKind.INT && val.is_zero(self.comp)))
		{
			self.write_unsigned_bytes(data, 0, data.len, self.comp.target.null_repr());
			return;
		}
		if (key.tag.kind == NumberKind.INT)
		{
			// Integer constant converted to a pointer: `(void *)(intptr_t)2`.
			if (!key.int_fits_64()) return self.fail("TODO CodeGen.genVar big integer pointer initializer\n");
			self.write_integer_bytes(data, 0, data.len, data.len * 8, val);
			return;
		}
		if (key.tag != primitive_value::PrimitiveType.POINTER)
		{
			return self.fail("TODO CodeGen.genVar pointer initializer\n");
		}
		type_store::NodeIndex target_node = (type_store::NodeIndex)key.pointer.node;
		tree::Node target = target_node.get(self.tree);
		String symbol;
		switch (target.kind)
		{
			case VARIABLE:
				if (target.variable.implicit)
				{
					symbol = self.find_implicit_var(target_node);
					if (symbol.len == 0) return self.fail("TODO CodeGen.genVar address of implicit variable\n");
				}
				else if (self.find_emitted_static(target_node).len != 0)
				{
					symbol = self.find_emitted_static(target_node);
				}
				else if (!self.is_root_declaration(target_node) &&
				target.variable.storage_class != tree::VariableStorageClass.EXTERN)
				{
					return self.fail("TODO CodeGen.genVar address of block static\n");
				}
				else
				{
					symbol = self.symbol_name(self.tree.tok_slice(target.variable.name_tok), self.has_internal_linkage(target_node));
				}
			case FUNCTION:
				symbol = self.symbol_name(self.tree.tok_slice(target.function.name_tok), self.has_internal_linkage(target_node));
			case STRING_LITERAL_EXPR:
				symbol = self.string_global(target_node)!;
			case ADDR_OF_LABEL:
				symbol = self.static_label_address(target.addr_of_label.label_tok)!;
			case COMPOUND_LITERAL_EXPR:
				symbol = self.compound_literal_global(target_node)!;
			default:
				return self.fail("TODO CodeGen.genVar address initializer target\n");
		}
		value::Value offset_value = value::from_ref(key.pointer.offset);
		long addend;
		if (try resolved_offset = offset_value.to_i64(self.comp))
		{
			addend = resolved_offset;
		}
		else
		{
			return self.fail("TODO CodeGen.genVar address initializer offset\n");
		}
		relocs.push({ .offset = slot_offset, .symbol = symbol, .addend = addend });
		return;
	}

	type_store::ScalarKind scalar = qt.scalar_kind(self.comp);
	if (scalar == type_store::ScalarKind.BOOL || scalar == type_store::ScalarKind.ENUM ||
		scalar == type_store::ScalarKind.INT)
	{
		if (key.tag.kind == NumberKind.INT && !key.int_fits_64())
		{
			return self.fail("TODO CodeGen.genVar big integer initializer\n");
		}
		if (qt.is(self.comp, type_store::TypeTag.BOOL))
		{
			self.write_unsigned_bytes(data, 0, data.len, val.is_zero(self.comp) ? 0 : 1);
		}
		else
		{
			usz bit_count = (usz)qt.bit_sizeof(self.comp);
			usz byte_count = (bit_count + 7) / 8;
			if (byte_count > data.len) return self.fail("TODO CodeGen.genVar integer storage size\n");
			self.write_integer_bytes(data, 0, byte_count, bit_count, val);
		}
		return;
	}
	if (scalar == type_store::ScalarKind.FLOAT)
	{
		ulong bit_count = qt.bit_sizeof(self.comp);
		if (bit_count != 16 && bit_count != 32 && bit_count != 64 && bit_count != 80 && bit_count != 128)
		{
			return self.fail("TODO CodeGen.genVar unsupported float width\n");
		}
		usz repr_bytes = (usz)((bit_count + 7) / 8);
		if (repr_bytes > data.len) return self.fail("TODO CodeGen.genVar float storage size\n");
		usz start = self.comp.target.cpu.arch.big ? data.len - repr_bytes : 0;
		self.write_float_bytes(data, start, data.len - start, bit_count, val);
		return;
	}
	return self.fail(string::tformat("TODO CodeGen.genVar initializer %s\n", init_node.kind.name));
}

// ---------------------------------------------------------------------------
// VLAs and goto (C3 extension: Zig CodeGen has neither)
// ---------------------------------------------------------------------------

<* Widen an integer value of type `qt` to i64 (sign- or zero-extending, or truncating). *>
fn ir::Ref CodeGen.widen_to_i64(&self, ir::Ref value, type_store::QualType qt)
{
	ulong bits = qt.bit_sizeof(self.comp);
	if (bits < 64)
	{
		ir::InstTag extend = qt.signedness(self.comp) == SIGNED ? ir::InstTag.SEXT : ir::InstTag.ZEXT;
		return self.builder.add_inst(extend, { .ref = value }, value_interner::REF_I64);
	}
	if (bits > 64) return self.builder.add_inst(ir::InstTag.TRUNC, { .ref = value }, value_interner::REF_I64);
	return value;
}

<*
 Byte size of `qt` as an i64 value. A VLA's length expression is evaluated the
 first time its type is sized (its declaration) and the result is reused.
*>
fn ir::Ref? CodeGen.gen_type_size(&self, type_store::QualType qt)
{
	if (@ok(qt.sizeof_or_null(self.comp)))
	{
		return self.builder.add_constant(value::int_u64(self.object_size(qt), self.comp).ref(), value_interner::REF_I64);
	}
	type_store::BaseType base = qt.base(self.comp);
	if (base.ty.tag == ARRAY && (base.ty.array.len.kind == FIXED || base.ty.array.len.kind == STATIC))
	{
		// A fixed number of runtime-sized elements: `char[2][n]`.
		ir::Ref count = self.builder.add_constant(value::int_u64(base.ty.array.len.len, self.comp).ref(), value_interner::REF_I64);
		return self.builder.add_inst(ir::InstTag.MUL, { .bin = { .lhs = count, .rhs = self.gen_type_size(base.ty.array.elem)! } }, value_interner::REF_I64);
	}
	if (base.ty.tag != ARRAY || base.ty.array.len.kind != VARIABLE)
	{
		self.fail("TODO VLAs")!;
		unreachable();
	}
	uint key = (uint)base.qt.unqualified();
	if (try cached = self.vla_sizes.get(key)) return cached;
	type_store::NodeIndex len_expr = base.ty.array.len.expr;
	// The parser keeps the bound as written (Zig parity), so a bare `n` is still an lvalue.
	type_store::QualType len_qt = len_expr.qt(self.tree);
	ir::Ref len_value = self.tree.is_lval(len_expr)
	? self.add_un(ir::InstTag.LOAD, self.gen_lval(len_expr)!, len_qt)!
	: self.gen_expr(len_expr)!;
	ir::Ref len = self.widen_to_i64(len_value, len_qt);
	ir::Ref elem_size = self.gen_type_size(base.ty.array.elem)!;
	ir::Ref total = self.builder.add_inst(ir::InstTag.MUL, { .bin = { .lhs = len, .rhs = elem_size } }, value_interner::REF_I64);
	self.vla_sizes.set(key, total);
	return total;
}

<* A runtime-length array type (possibly of runtime-length arrays). *>
fn bool CodeGen.is_vla(&self, type_store::QualType qt)
{
	type_store::BaseType base = qt.base(self.comp);
	return base.ty.tag == ARRAY && base.ty.array.len.kind == VARIABLE;
}

<* Save the stack pointer before the first VLA of the current compound statement. *>
fn void CodeGen.enter_vla_scope(&self)
{
	if (self.vla_scopes.len() > 0 && self.vla_scopes[self.vla_scopes.len() - 1].compound == self.current_compound) return;
	self.vla_scopes.push(
	{
		.compound = self.current_compound, .saved = self.builder.add_stack_save()
	}
	);
}

<* Free the VLAs of scopes opened past `depth` before jumping out of them. *>
fn void CodeGen.restore_vla_depth(&self, sz depth)
{
	if (self.vla_scopes.len() > depth) self.builder.add_stack_restore(self.vla_scopes[depth].saved);
}

<* Copy the live VLA saves into the pool; returns the start of the copy. *>
fn sz CodeGen.snapshot_vla_saves(&self)
{
	sz start = self.vla_save_pool.len();
	foreach (scope : self.vla_scopes) self.vla_save_pool.push(scope.saved);
	return start;
}

<* The label named by `tok`, created on first use (goto before label). *>
fn sz CodeGen.goto_label(&self, tokens::TokenIndex tok)
{
	string_interner::StringId name = self.comp.intern_string(self.tree.tok_slice(tok));
	if (try index = self.goto_label_index.get((uint)name)) return index;
	sz index = self.goto_labels.len();
	// `user.<name>`: lowering gives address-taken C labels a stable symbol.
	self.goto_labels.push(
	{
		.label = self.builder.make_label(string::format(&self.builder.arena, "user.%s", self.tree.tok_slice(tok)))
	}
	);
	self.goto_label_index.set((uint)name, index);
	return index;
}

<* The data symbol for `&&label` in a static initializer of the current
   function. The lowering names the block `.Lblockaddr.<fn>.<label>` while some
   LABEL_ADDR takes its address; a volatile store keeps that LABEL_ADDR (and so
   the block) alive however the optimizer treats the table. *>
fn String? CodeGen.static_label_address(&self, tokens::TokenIndex label_tok)
{
	if (self.current_fn.len == 0)
	{
		self.fail("TODO CodeGen.genVar label address outside a function\n")!;
		return compilation::FATAL_ERROR~;
	}
	sz index = self.goto_label(label_tok);
	ir::Ref address = self.builder.add_inst(ir::InstTag.LABEL_ADDR, { .ref = self.goto_labels[index].label }, value_interner::REF_PTR);
	ir::Ref keep = self.builder.add_alloc(8, 8, true);
	self.builder.add_store(keep, address, true);
	return string::format(&self.builder.arena, ".Lblockaddr.%s.%s", self.current_fn, self.tree.tok_slice(label_tok));
}

<* The first of `saves` that is not live at the target, i.e. the outermost scope the jump leaves. *>
fn ir::Ref CodeGen.first_left_save(&self, sz saves_start, sz saves_len, GotoLabel* target)
{
	for (sz i = 0; i < saves_len; i++)
	{
		ir::Ref save = self.vla_save_pool[saves_start + i];
		bool live = false;
		for (sz j = 0; j < target.saves_len; j++)
		{
			if (self.vla_save_pool[target.saves_start + j] == save)
			{
				live = true; break;
			}
		}
		if (!live) return save;
	}
	return ir::NONE;
}

fn void CodeGen.gen_goto(&self, sz label_index)
{
	GotoLabel* target = &self.goto_labels[label_index];
	if (self.vla_scopes.len() == 0)
	{
		self.builder.add_jump(target.label);
		return;
	}
	sz saves_start = self.snapshot_vla_saves();
	sz saves_len = self.vla_scopes.len();
	if (target.defined)
	{
		ir::Ref save = self.first_left_save(saves_start, saves_len, target);
		if (save != ir::NONE) self.builder.add_stack_restore(save);
		self.builder.add_jump(target.label);
		return;
	}
	// Forward goto: which scopes it leaves is known once the label is defined.
	ir::Ref stub = self.builder.make_label("goto.vla");
	self.pending_gotos.push(
	{
		.stub = stub, .label_index = label_index, .saves_start = saves_start, .saves_len = saves_len
	}
	);
	self.builder.add_jump(stub);
}

<* Emit the restore-then-jump stub of each forward goto out of VLA scopes. *>
fn void CodeGen.emit_pending_gotos(&self)
{
	foreach (pending : self.pending_gotos)
	{
		self.builder.start_block(pending.stub);
		GotoLabel* target = &self.goto_labels[pending.label_index];
		ir::Ref save = self.first_left_save(pending.saves_start, pending.saves_len, target);
		if (save != ir::NONE) self.builder.add_stack_restore(save);
		self.builder.add_jump(target.label);
	}
}

<* Evaluate fresh type syntax; a typedef reference reuses its captured bounds. *>
fn void? CodeGen.gen_runtime_type(&self, type_store::QualType qt)
{
 type_store::Type ty = qt.get_type(self.comp);
 switch (ty.tag)
 {
  case TYPEOF:
   if (!ty.type_of.base.is_variably_modified(self.comp)) return;
   // A variably modified typeof operand is evaluated (for its side effects);
   // an lvalue operand (`typeof(vla)`) is evaluated as an address.
   if (ty.type_of.has_expr)
   {
    if (self.tree.is_lval(ty.type_of.expr)) { self.gen_lval(ty.type_of.expr)!; } else { self.gen_expr(ty.type_of.expr)!; }
   }
   self.gen_runtime_type(ty.type_of.base)!;
  case POINTER: self.gen_runtime_type(ty.pointer.child)!;
  case ARRAY:
   if (ty.array.len.kind == type_store::ArrayLenKind.VARIABLE) { self.gen_type_size(qt)!; }
   else { self.gen_runtime_type(ty.array.elem)!; }
  default: break;
 }
}
