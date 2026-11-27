// GNU vector extension (`vector_size`) code generation.
//
// Vector values live in memory like records: an expression's IR value is the
// address of its bytes. For a 128-bit SSE2 shape (`native_vector_type`), an
// operation the x86_64 backend selects (`ir::sse2_vector_op` and friends) loads
// its operands as one IR vector value each, computes one vector instruction and
// stores the result into a fresh temporary; mem2reg/SROA then turn those
// whole-vector temporaries into SSA values. Everything else (other sizes, i8
// multiplies, division, non-uniform shifts, arbitrary shuffles, lane stores) is
// lowered lane by lane on the element type. Such vectors cross calls in one XMM
// register (codegen_abi.c3, AggClass.VECTOR128) typed `vector128_carrier`.
module aro::frontend::c::codegen;
import aro::bigint;
import aro::backend::ir, aro::frontend::c::compilation, aro::frontend::c::tree, aro::frontend::c::type_store;
import aro::frontend::c::value, aro::value_interner, aro::frontend::c::lang_opts;

<* gen_vector_expr: this node is not a vector operation it lowers. *>
faultdef NOT_VECTOR_OP;

fn bool CodeGen.is_vector(&self, type_store::QualType qt) => qt.is(self.comp, type_store::TypeTag.VECTOR);

fn type_store::QualType CodeGen.vector_elem(&self, type_store::QualType qt) => qt.base(self.comp).ty.vector.elem;

fn uint CodeGen.vector_len(&self, type_store::QualType qt) => qt.base(self.comp).ty.vector.len;

<* The IR vector type that holds `qt` as one value: a 128-bit SSE2 shape, unless
   `--scalar-vector-ext`. *>
fn value_interner::InternerRef? CodeGen.native_vector_type(&self, type_store::QualType qt)
{
	if (self.comp.langopts.scalar_vector_ext || !self.is_vector(qt)) return NOT_VECTOR_OP~;
	value_interner::InternerRef ty = self.gen_type(qt)!;
	if (catch ir::vector_shape_of(self.builder.interner, ty)) return NOT_VECTOR_OP~;
	return ty;
}

fn ir::VectorShape CodeGen.shape_of(&self, value_interner::InternerRef ty) => ir::vector_shape_of(self.builder.interner, ty)!!;

<* The IR type of a VECTOR128-class value in its XMM register: the vector type
   itself, or f128 bits (records of two SSE eightbytes, non-native vectors). *>
fn value_interner::InternerRef CodeGen.vector128_carrier(&self, type_store::QualType qt)
{
	return self.native_vector_type(qt) ?? value_interner::REF_F128;
}

<* Copy a `qt` value from `source` to `destination`: one vector LOAD / STORE for
   a native vector (so the slots stay promotable), else word by word. *>
fn void? CodeGen.gen_copy_value(&self, ir::Ref destination, ir::Ref source, type_store::QualType qt)
{
	if (try ty = self.native_vector_type(qt))
	{
		self.builder.add_store(destination, self.builder.add_load(source, ty, false));
		return;
	}
	self.gen_copy(destination, source, qt.sizeof(self.comp))!;
}

<* `value` (of vector type `qt`) stored in a fresh temporary, as an expression result. *>
fn ir::Ref CodeGen.vector_result(&self, ir::Ref value, type_store::QualType qt)
{
	ir::Ref result = self.vector_temp(qt);
	self.builder.add_store(result, value);
	return result;
}

<* A fresh temporary for a vector result. *>
fn ir::Ref CodeGen.vector_temp(&self, type_store::QualType qt)
{
	uint size = (uint)qt.sizeof(self.comp);
	uint align = qt.alignof(self.comp);
	return self.builder.add_alloc(size == 0 ? 1 : size, align == 0 ? 1 : align);
}

fn ir::Ref? CodeGen.vector_lane_ptr(&self, ir::Ref base, type_store::QualType vector_qt, uint lane)
{
	return self.ptr_at(base, (ulong)lane * self.vector_elem(vector_qt).sizeof(self.comp));
}

fn ir::Ref? CodeGen.load_lane(&self, ir::Ref base, type_store::QualType vector_qt, uint lane)
{
	type_store::QualType elem = self.vector_elem(vector_qt);
	return self.builder.add_inst(ir::InstTag.LOAD, { .ref = self.vector_lane_ptr(base, vector_qt, lane)! }, self.gen_type(elem)!);
}

fn void? CodeGen.store_lane(&self, ir::Ref base, type_store::QualType vector_qt, uint lane, ir::Ref value)
{
	self.builder.add_store(self.vector_lane_ptr(base, vector_qt, lane)!, value);
}

<* Arithmetic conversion of one scalar between integer and floating types. *>
fn ir::Ref? CodeGen.convert_lane(&self, ir::Ref value, type_store::QualType from, type_store::QualType to)
{
	bool from_float = from.is_float(self.comp);
	bool to_float = to.is_float(self.comp);
	ulong from_bits = from.bit_sizeof(self.comp);
	ulong to_bits = to.bit_sizeof(self.comp);
	if (from_float && to_float)
	{
		if (from_bits == to_bits) return value;
		return self.add_un(from_bits < to_bits ? ir::InstTag.FPEXT : ir::InstTag.FPTRUNC, value, to);
	}
	if (from_float)
	{
		return self.add_un(to.signedness(self.comp) == bigint::Signedness.UNSIGNED ? ir::InstTag.FPTOUI : ir::InstTag.FPTOSI, value, to);
	}
	if (to_float)
	{
		return self.add_un(from.signedness(self.comp) == bigint::Signedness.UNSIGNED ? ir::InstTag.UITOFP : ir::InstTag.SITOFP, value, to);
	}
	if (from_bits == to_bits) return value;
	if (from_bits > to_bits) return self.add_un(ir::InstTag.TRUNC, value, to);
	return self.add_un(from.signedness(self.comp) == bigint::Signedness.UNSIGNED ? ir::InstTag.ZEXT : ir::InstTag.SEXT, value, to);
}

<* The IR operation of binary `kind` on lanes of `elem`. *>
fn ir::InstTag? CodeGen.vector_lane_op(&self, tree::NodeKind kind, type_store::QualType elem)
{
	bool is_float = elem.is_float(self.comp);
	switch (kind)
	{
		case ADD_EXPR: case ADD_ASSIGN_EXPR: return is_float ? ir::InstTag.FADD : ir::InstTag.ADD;
		case SUB_EXPR: case SUB_ASSIGN_EXPR: return is_float ? ir::InstTag.FSUB : ir::InstTag.SUB;
		case MUL_EXPR: case MUL_ASSIGN_EXPR: return is_float ? ir::InstTag.FMUL : ir::InstTag.MUL;
		case DIV_EXPR: case DIV_ASSIGN_EXPR: return is_float ? ir::InstTag.FDIV : self.signed_tag(elem, ir::InstTag.SDIV, ir::InstTag.UDIV);
		case MOD_EXPR: case MOD_ASSIGN_EXPR: return self.signed_tag(elem, ir::InstTag.SREM, ir::InstTag.UREM);
		case BIT_AND_EXPR: case BIT_AND_ASSIGN_EXPR: return ir::InstTag.BIT_AND;
		case BIT_OR_EXPR: case BIT_OR_ASSIGN_EXPR: return ir::InstTag.BIT_OR;
		case BIT_XOR_EXPR: case BIT_XOR_ASSIGN_EXPR: return ir::InstTag.BIT_XOR;
		case SHL_EXPR: case SHL_ASSIGN_EXPR: return ir::InstTag.BIT_SHL;
		case SHR_EXPR: case SHR_ASSIGN_EXPR: return self.signed_tag(elem, ir::InstTag.BIT_ASHR, ir::InstTag.BIT_LSHR);
		case EQUAL_EXPR: return is_float ? ir::InstTag.FCMP_OEQ : ir::InstTag.CMP_EQ;
		case NOT_EQUAL_EXPR: return is_float ? ir::InstTag.FCMP_UNE : ir::InstTag.CMP_NE;
		case LESS_THAN_EXPR: return is_float ? ir::InstTag.FCMP_OLT : self.signed_tag(elem, ir::InstTag.CMP_SLT, ir::InstTag.CMP_ULT);
		case LESS_THAN_EQUAL_EXPR: return is_float ? ir::InstTag.FCMP_OLE : self.signed_tag(elem, ir::InstTag.CMP_SLTE, ir::InstTag.CMP_ULTE);
		case GREATER_THAN_EXPR: return is_float ? ir::InstTag.FCMP_OGT : self.signed_tag(elem, ir::InstTag.CMP_SGT, ir::InstTag.CMP_UGT);
		case GREATER_THAN_EQUAL_EXPR: return is_float ? ir::InstTag.FCMP_OGE : self.signed_tag(elem, ir::InstTag.CMP_SGTE, ir::InstTag.CMP_UGTE);
		default: return NOT_VECTOR_OP~;
	}
}

fn bool is_compare_kind(tree::NodeKind kind)
{
	switch (kind)
	{
		case EQUAL_EXPR: case NOT_EQUAL_EXPR: case LESS_THAN_EXPR: case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR: case GREATER_THAN_EQUAL_EXPR: return true;
		default: return false;
	}
}

<* `a op b` lane by lane into a new temporary. Comparisons produce 0/-1 lanes of
   the (integer) result vector type. *>
fn ir::Ref? CodeGen.gen_vector_binary(&self, tree::NodeKind kind, ir::Ref lhs, ir::Ref rhs, type_store::QualType operand_qt,
	type_store::QualType result_qt)
{
	type_store::QualType elem = self.vector_elem(operand_qt);
	type_store::QualType result_elem = self.vector_elem(result_qt);
	ir::InstTag tag = self.vector_lane_op(kind, elem)!;
	ir::Ref result = self.vector_temp(result_qt);
	for (uint lane = 0; lane < self.vector_len(result_qt); lane++)
	{
		ir::Ref a = self.load_lane(lhs, operand_qt, lane)!;
		ir::Ref b = self.load_lane(rhs, operand_qt, lane)!;
		ir::Ref value;
		if (is_compare_kind(kind))
		{
			ir::Ref truth = self.builder.add_inst(tag, { .bin = { .lhs = a, .rhs = b } }, value_interner::REF_I1);
			value = self.builder.add_inst(ir::InstTag.SEXT, { .ref = truth }, self.gen_type(result_elem)!);
		}
		else
		{
			value = self.add_bin(tag, a, b, elem)!;
		}
		self.store_lane(result, result_qt, lane, value)!;
	}
	return result;
}

fn bool CodeGen.is_splat_cast(&self, type_store::NodeIndex index)
{
	tree::Node node = index.get(self.tree);
	return node.kind == tree::NodeKind.CAST && node.cast.kind == tree::CastKind.VECTOR_SPLAT;
}

fn bool is_shift_tag(ir::InstTag tag) => tag == ir::InstTag.BIT_SHL || tag == ir::InstTag.BIT_ASHR || tag == ir::InstTag.BIT_LSHR;

<* Whether binary `kind` of `operand_qt` vectors (giving `result_qt`) is one SSE2
   vector instruction. A shift needs a uniform count (`rhs` a splat). *>
fn bool CodeGen.native_vector_binary_ok(&self, tree::NodeKind kind, type_store::NodeIndex rhs, type_store::QualType operand_qt,
	type_store::QualType result_qt)
{
	value_interner::InternerRef? ty = self.native_vector_type(operand_qt);
	if (catch ty) return false;
	value_interner::InternerRef? result_ty = self.native_vector_type(result_qt);
	if (catch result_ty) return false;
	ir::InstTag? tag = self.vector_lane_op(kind, self.vector_elem(operand_qt));
	if (catch tag) return false;
	ir::VectorShape shape = self.shape_of(ty);
	if (is_compare_kind(kind))
	{
		ir::VectorShape mask = self.shape_of(result_ty);
		if (mask.is_float || mask.lanes != shape.lanes || mask.elem_bits != shape.elem_bits) return false;
	}
	else if (result_ty != ty)
	{
		return false;
	}
	if (is_shift_tag(tag) && !self.is_splat_cast(rhs)) return false;
	return ir::sse2_vector_op(tag, shape);
}

<* VSPLAT of the scalar operand of splat cast `cast` to the native vector type `qt`. *>
fn ir::Ref? CodeGen.gen_native_splat(&self, tree::NodeCast cast, type_store::QualType qt)
{
	value_interner::InternerRef ty = self.native_vector_type(qt)!;
	ir::Ref scalar = self.convert_lane(self.gen_expr(cast.operand)!, cast.operand.qt(self.tree), self.vector_elem(qt))!;
	return self.builder.add_inst(ir::InstTag.VSPLAT, { .ref = scalar }, ty);
}

<* `a op b` as one vector instruction (`native_vector_binary_ok` holds). *>
fn ir::Ref? CodeGen.gen_native_vector_binary(&self, tree::NodeKind kind, tree::NodeBinary bin, type_store::QualType operand_qt,
	type_store::QualType result_qt)
{
	value_interner::InternerRef ty = self.native_vector_type(operand_qt)!;
	value_interner::InternerRef result_ty = self.native_vector_type(result_qt)!;
	ir::InstTag tag = self.vector_lane_op(kind, self.vector_elem(operand_qt))!;
	ir::Ref lhs = self.gen_expr(bin.lhs)!;
	if (is_shift_tag(tag))
	{
		ir::Ref a = self.builder.add_load(lhs, ty, false);
		ir::Ref count = self.gen_native_splat(bin.rhs.get(self.tree).cast, operand_qt)!;
		return self.vector_result(self.builder.add_inst(tag, { .bin = { .lhs = a, .rhs = count } }, ty), result_qt);
	}
	ir::Ref rhs = self.gen_expr(bin.rhs)!;
	ir::Ref a = self.builder.add_load(lhs, ty, false);
	ir::Ref b = self.builder.add_load(rhs, ty, false);
	return self.vector_result(self.builder.add_inst(tag, { .bin = { .lhs = a, .rhs = b } }, result_ty), result_qt);
}

<* A constant `__builtin_shufflevector` index (-1: undefined lane). *>
fn long CodeGen.shuffle_index(&self, type_store::NodeIndex index_node)
{
	value::Value? index_val = self.tree.value_of(index_node);
	if (try v = index_val) return v.to_i64(self.comp) ?? -1;
	return -1;
}

<* The address of lane `index` of a vector lvalue or value (`v[i]`). *>
fn ir::Ref? CodeGen.gen_vector_element_address(&self, tree::NodeArrayAccess access)
{
	type_store::NodeIndex vector_node = access.base;
	type_store::NodeIndex index_node = access.index;
	if (!self.is_vector(vector_node.qt(self.tree)))
	{
		vector_node = access.index;
		index_node = access.base;
	}
	type_store::QualType vector_qt = vector_node.qt(self.tree);
	ir::Ref base = self.tree.is_lval(vector_node) ? self.gen_lval(vector_node)! : self.gen_expr(vector_node)!;
	ir::Ref index = self.widen_to_i64(self.gen_expr(index_node)!, index_node.qt(self.tree));
	ir::Ref size = self.builder.add_constant(value::int_u64(self.vector_elem(vector_qt).sizeof(self.comp), self.comp).ref(), value_interner::REF_I64);
	ir::Ref offset = self.builder.add_inst(ir::InstTag.MUL, { .bin = { .lhs = index, .rhs = size } }, value_interner::REF_I64);
	return self.builder.add_inst(ir::InstTag.ADD, { .bin = { .lhs = base, .rhs = offset } }, value_interner::REF_PTR);
}

<* Vector-typed expressions (and vector bit casts to scalars). *>
fn ir::Ref? CodeGen.gen_vector_expr(&self, type_store::NodeIndex node_index, tree::Node node)
{
	type_store::QualType qt = node_index.qt(self.tree);
	switch (node.kind)
	{
		case ADD_EXPR: case SUB_EXPR: case MUL_EXPR: case DIV_EXPR: case MOD_EXPR:
		case BIT_AND_EXPR: case BIT_OR_EXPR: case BIT_XOR_EXPR: case SHL_EXPR: case SHR_EXPR:
		case EQUAL_EXPR: case NOT_EQUAL_EXPR: case LESS_THAN_EXPR: case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR: case GREATER_THAN_EQUAL_EXPR:
			if (!self.is_vector(qt)) return NOT_VECTOR_OP~;
			type_store::QualType operand_qt = node.binary.lhs.qt(self.tree);
			if (!self.is_vector(operand_qt)) return NOT_VECTOR_OP~;
			if (self.native_vector_binary_ok(node.kind, node.binary.rhs, operand_qt, qt))
			{
				return self.gen_native_vector_binary(node.kind, node.binary, operand_qt, qt);
			}
			ir::Ref lhs = self.gen_expr(node.binary.lhs)!;
			ir::Ref rhs = self.gen_expr(node.binary.rhs)!;
			return self.gen_vector_binary(node.kind, lhs, rhs, operand_qt, qt);
		case NEGATE_EXPR:
		case BIT_NOT_EXPR:
			if (!self.is_vector(qt)) return NOT_VECTOR_OP~;
			type_store::QualType elem = self.vector_elem(qt);
			ir::InstTag unary_tag = node.kind == tree::NodeKind.BIT_NOT_EXPR ? ir::InstTag.BIT_NOT
				: elem.is_float(self.comp) ? ir::InstTag.FNEG : ir::InstTag.NEGATE;
			if (try ty = self.native_vector_type(qt))
			{
				if (ir::sse2_vector_op(unary_tag, self.shape_of(ty)))
				{
					ir::Ref operand = self.builder.add_load(self.gen_expr(node.unary.operand)!, ty, false);
					return self.vector_result(self.builder.add_inst(unary_tag, { .ref = operand }, ty), qt);
				}
			}
			ir::Ref operand = self.gen_expr(node.unary.operand)!;
			ir::Ref result = self.vector_temp(qt);
			for (uint lane = 0; lane < self.vector_len(qt); lane++)
			{
				ir::Ref value = self.load_lane(operand, qt, lane)!;
				if (node.kind == tree::NodeKind.BIT_NOT_EXPR)
				{
					value = self.add_un(ir::InstTag.BIT_NOT, value, elem)!;
				}
				else if (elem.is_float(self.comp))
				{
					value = self.add_un(ir::InstTag.FNEG, value, elem)!;
				}
				else
				{
					ir::Ref zero = self.builder.add_constant(value::ZERO.ref(), self.gen_type(elem)!);
					value = self.add_bin(ir::InstTag.SUB, zero, value, elem)!;
				}
				self.store_lane(result, qt, lane, value)!;
			}
			return result;
		case CAST:
			type_store::QualType from = node.cast.operand.qt(self.tree);
			switch (node.cast.kind)
			{
				case VECTOR_SPLAT:
					if (!self.is_vector(qt)) return NOT_VECTOR_OP~;
					if (@ok(self.native_vector_type(qt))) return self.vector_result(self.gen_native_splat(node.cast, qt)!, qt);
					type_store::QualType elem = self.vector_elem(qt);
					ir::Ref scalar = self.convert_lane(self.gen_expr(node.cast.operand)!, from, elem)!;
					ir::Ref result = self.vector_temp(qt);
					for (uint lane = 0; lane < self.vector_len(qt); lane++) self.store_lane(result, qt, lane, scalar)!;
					return result;
				case BITCAST:
				case NO_OP:
					bool to_vector = self.is_vector(qt);
					bool from_vector = self.is_vector(from);
					if (to_vector && from_vector) return self.gen_expr(node.cast.operand);
					if (to_vector)
					{
						// Scalar bits reinterpreted as a vector (`(__m64)long long`).
						ir::Ref result = self.vector_temp(qt);
						self.builder.add_store(result, self.gen_expr(node.cast.operand)!);
						return result;
					}
					if (from_vector)
					{
						ir::Ref bytes = self.gen_expr(node.cast.operand)!;
						return self.builder.add_inst(ir::InstTag.LOAD, { .ref = bytes }, self.gen_type(qt)!);
					}
					return NOT_VECTOR_OP~;
				default:
					return NOT_VECTOR_OP~;
			}
		case BUILTIN_SHUFFLEVECTOR:
			type_store::QualType lhs_qt = node.shufflevector.lhs.qt(self.tree);
			uint lhs_len = self.vector_len(lhs_qt);
			if (try shuffle_ty = self.native_vector_type(qt))
			{
				value_interner::InternerRef? source_ty = self.native_vector_type(lhs_qt);
				if (try source_ty && source_ty == shuffle_ty && node.shufflevector.indexes.len == lhs_len)
				{
					char[16] mask;
					foreach (lane, index_node : node.shufflevector.indexes)
					{
						long index = self.shuffle_index(index_node);
						mask[lane] = index < 0 || index >= 2 * (long)lhs_len ? ir::SHUFFLE_UNDEF : (char)index;
					}
					if (ir::sse2_shuffle_kind(self.shape_of(shuffle_ty), mask[:lhs_len]).kind != ir::ShuffleKind.NONE)
					{
						ir::Ref lhs = self.gen_expr(node.shufflevector.lhs)!;
						ir::Ref rhs = self.gen_expr(node.shufflevector.rhs)!;
						ir::Ref a = self.builder.add_load(lhs, shuffle_ty, false);
						ir::Ref b = self.builder.add_load(rhs, shuffle_ty, false);
						return self.vector_result(self.builder.add_shuffle(a, b, mask[:lhs_len], shuffle_ty), qt);
					}
				}
			}
			ir::Ref lhs = self.gen_expr(node.shufflevector.lhs)!;
			ir::Ref rhs = self.gen_expr(node.shufflevector.rhs)!;
			ir::Ref result = self.vector_temp(qt);
			foreach (lane, index_node : node.shufflevector.indexes)
			{
				long index = self.shuffle_index(index_node);
				if (index < 0) continue; // `-1`: an undefined lane, left as is.
				ir::Ref source = index < (long)lhs_len ? self.load_lane(lhs, lhs_qt, (uint)index)!
					: self.load_lane(rhs, lhs_qt, (uint)(index - (long)lhs_len))!;
				self.store_lane(result, qt, (uint)lane, source)!;
			}
			return result;
		case BUILTIN_CONVERTVECTOR:
			type_store::QualType from = node.convertvector.operand.qt(self.tree);
			type_store::QualType to = node.convertvector.dest_qt;
			value_interner::InternerRef? from_ty = self.native_vector_type(from);
			value_interner::InternerRef? to_ty = self.native_vector_type(to);
			if (try from_ty && try to_ty)
			{
				type_store::QualType from_elem = self.vector_elem(from);
				type_store::QualType to_elem = self.vector_elem(to);
				bool from_signed = !from_elem.is_float(self.comp) && from_elem.signedness(self.comp) == bigint::Signedness.SIGNED;
				bool to_signed = !to_elem.is_float(self.comp) && to_elem.signedness(self.comp) == bigint::Signedness.SIGNED;
				ir::InstTag cast_tag = from_signed ? ir::InstTag.SITOFP : ir::InstTag.FPTOSI;
				if ((from_signed || to_signed) && ir::sse2_vector_cast(cast_tag, self.shape_of(from_ty), self.shape_of(to_ty)))
				{
					ir::Ref operand = self.builder.add_load(self.gen_expr(node.convertvector.operand)!, from_ty, false);
					return self.vector_result(self.builder.add_inst(cast_tag, { .ref = operand }, to_ty), to);
				}
			}
			ir::Ref source = self.gen_expr(node.convertvector.operand)!;
			ir::Ref result = self.vector_temp(to);
			for (uint lane = 0; lane < self.vector_len(to); lane++)
			{
				ir::Ref value = self.convert_lane(self.load_lane(source, from, lane)!, self.vector_elem(from), self.vector_elem(to))!;
				self.store_lane(result, to, lane, value)!;
			}
			return result;
		case ARRAY_ACCESS_EXPR:
			if (!self.is_vector(node.array_access.base.qt(self.tree)) && !self.is_vector(node.array_access.index.qt(self.tree))) return NOT_VECTOR_OP~;
			if (try extract = self.gen_native_extract(node.array_access, qt)) return extract;
			ir::Ref address = self.gen_vector_element_address(node.array_access)!;
			return self.builder.add_load(address, self.gen_type(qt)!, false);
		default:
			return NOT_VECTOR_OP~;
	}
}

<* `v[c]` read with a constant in-range `c` from a native vector: VEXTRACT. *>
fn ir::Ref? CodeGen.gen_native_extract(&self, tree::NodeArrayAccess access, type_store::QualType elem_qt)
{
	type_store::NodeIndex vector_node = access.base;
	type_store::NodeIndex index_node = access.index;
	if (!self.is_vector(vector_node.qt(self.tree)))
	{
		vector_node = access.index;
		index_node = access.base;
	}
	type_store::QualType vector_qt = vector_node.qt(self.tree);
	value_interner::InternerRef ty = self.native_vector_type(vector_qt)!;
	value::Value? index_val = self.tree.value_of(index_node);
	if (catch index_val) return NOT_VECTOR_OP~;
	long lane = index_val.to_i64(self.comp) ?? -1;
	if (lane < 0 || lane >= (long)self.vector_len(vector_qt)) return NOT_VECTOR_OP~;
	ir::Ref base = self.tree.is_lval(vector_node) ? self.gen_lval(vector_node)! : self.gen_expr(vector_node)!;
	ir::Ref vector = self.builder.add_load(base, ty, false);
	ir::Ref lane_ref = self.builder.add_constant(value::int_u64((ulong)lane, self.comp).ref(), value_interner::REF_I32);
	return self.builder.add_inst(ir::InstTag.VEXTRACT, { .bin = { .lhs = vector, .rhs = lane_ref } }, self.gen_type(elem_qt)!);
}

<* `v op= x` on a vector lvalue: the result temporary is copied back. *>
fn bool CodeGen.store_vector_assigned(&self, ir::Ref ptr, ir::Ref value, type_store::QualType lhs_qt)
{
	if (!self.is_vector(lhs_qt)) return false;
	(void)self.gen_copy_value(ptr, value, lhs_qt);
	return true;
}

fn bool CodeGen.is_array_like(&self, type_store::QualType qt) => qt.is(self.comp, type_store::TypeTag.ARRAY) || self.is_vector(qt);
