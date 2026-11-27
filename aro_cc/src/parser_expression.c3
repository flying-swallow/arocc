// Expression grammar on Parser, ported from Parser.zig's binaryExpr/unExpr:
// binary precedence and associativity (`parse_expr_prec`), unary prefix
// operators, AST construction and the constant operations that can be
// evaluated from the existing Value API. Operands come from the postfix
// grammar (parser_postfix.c3).
module aro::frontend::c::parser;
import aro::primitive_value;
import aro::frontend::c::parser_result, aro::frontend::c::tree, aro::frontend::c::tokens, aro::frontend::c::tokenizer;
import aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner, aro::frontend::c::compilation, aro::bigint, aro::frontend::c::diagnostics, aro::frontend::c::lang_opts;
import aro::frontend::c::attribute;
import std::core::dstring;

excuse NO_EXPRESSION;
excuse NOT_FOLDABLE;


fn bool is_assignment(tokenizer::TokenId op)
{
	return tokens::precedence(op) == tokens::Precedence.ASSIGN;
}

fn bool? validate_pointer_arithmetic(parser::Parser* p, type_store::QualType pointer_qt, tokens::TokenIndex tok)
{
	// `++`/`--`/`+=` on an `_Atomic` pointer object operate on its pointer value type.
	if (try atomic = pointer_qt.get(p.comp, type_store::TypeTag.ATOMIC)) pointer_qt = atomic.atomic;
	if (p.comp.langopts.bounds_safety == lang_opts::BoundsSafety.CLANG &&
		pointer_qt.get_type(p.comp).pointer.bounds == type_store::PointerBounds.SINGLE)
	{
		Diagnostic.POINTER_ARITH_SINGLE.@emit(p, tok)!;
		return false;
	}
	type_store::QualType pointee = pointer_qt.child_type(p.comp);
	if (pointee.is(p.comp, type_store::TypeTag.VOID))
	{
		Diagnostic.GNU_POINTER_ARITH.@emit(p, tok)!;
		return true;
	}
	if (pointee.is(p.comp, type_store::TypeTag.FUNC)) return false;
	if (pointee.has_incomplete_size(p.comp))
	{
		Diagnostic.PTR_ARITHMETIC_INCOMPLETE.@emit(p, tok, p.fmt_qt(pointee))!;
		return false;
	}
	return true;
}

// Pointer compatibility for the operators that require compatible pointee
// types ignores qualifiers on the pointed-to type itself.
fn bool compatible_pointees(type_store::QualType lhs, type_store::QualType rhs, compilation::Compilation* comp)
{
	return lhs.child_type(comp).unqualified().eql(rhs.child_type(comp).unqualified(), comp);
}

<*
 Zig Result.adjustTypes, vector part. Precondition: at least one operand is a
 vector and both are value-converted. Two vectors must match (or have equal size,
 in which case `b` is bitcast to `a`'s type); a scalar is splatted to the other
 operand's vector type. On incompatible vector types `a.qt` becomes INVALID after
 the diagnostic; a scalar that cannot become the element type is an invalid
 binary expression. Element types are not checked further, as in Zig.
*>
fn void? adjust_vector_operands(parser::Parser* p, parser_result::Result* a, parser_result::Result* b,
	bool boolean_logic, tokens::TokenIndex tok, type_store::QualType original_a, type_store::QualType original_b)
{
	type_store::Type? a_vec = a.qt.get(p.comp, type_store::TypeTag.VECTOR);
	type_store::Type? b_vec = b.qt.get(p.comp, type_store::TypeTag.VECTOR);
	if (try av = a_vec)
	{
		if (try bv = b_vec)
		{
			if (boolean_logic)
			{
				Diagnostic.INVALID_BIN_TYPES.@emit(p, tok, p.fmt_qt(original_a), p.fmt_qt(original_b))!; return PARSING_FAILED~;
			}
			if (av.vector.eql(bv.vector, p.comp, true) && av.vector.kind == type_store::VectorKind.GENERIC) return;
			if (a.qt.size_compare(b.qt, p.comp) == type_store::TypeSizeOrder.EQ)
			{
				b.qt = a.qt;
				b.node = p.tree.implicit_cast(b.node, b.qt, tree::CastKind.BITCAST);
				return;
			}
			Diagnostic.INCOMPATIBLE_VEC_TYPES.@emit(p, tok, p.fmt_qt(a.qt), p.fmt_qt(b.qt))!;
			a.val = value::NONE;
			b.val = value::NONE;
			a.qt = type_store::INVALID;
			return;
		}
		if (!(b.coerce_scalar(p, av.vector.elem, tok)!))
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, tok, p.fmt_qt(original_a), p.fmt_qt(original_b))!; return PARSING_FAILED~;
		}
		b.save_value(p);
		b.qt = a.qt;
		b.node = p.tree.implicit_cast(b.node, b.qt, tree::CastKind.VECTOR_SPLAT);
		return;
	}
	type_store::Type bv = b_vec!!;
	if (!(a.coerce_scalar(p, bv.vector.elem, tok)!))
	{
		Diagnostic.INVALID_BIN_TYPES.@emit(p, tok, p.fmt_qt(original_a), p.fmt_qt(original_b))!; return PARSING_FAILED~;
	}
	a.save_value(p);
	a.qt = b.qt;
	a.node = p.tree.implicit_cast(a.node, a.qt, tree::CastKind.VECTOR_SPLAT);
}

<* Zig Result.boolRes for vectors: comparisons yield a generic vector of signed
   integers as wide as the operand elements. *>
fn type_store::QualType vector_bool_result(parser::Parser* p, type_store::QualType qt)
{
	type_store::Vector vec = qt.get(p.comp, type_store::TypeTag.VECTOR)!!.vector;
	if (vec.elem.is_int(p.comp) && vec.kind == type_store::VectorKind.GENERIC) return qt;
	type_store::QualType elem = type_store::smallest_n_bit_int_target_independent(p.comp,
		vec.elem.bit_sizeof(p.comp), Signedness.SIGNED);
	return p.comp.type_store.put(type_store::type_vector(elem, vec.len));
}

fn void? warn_distinct_pointer_comparison(parser::Parser* p, type_store::QualType lhs, type_store::QualType rhs, tokens::TokenIndex tok)
{
	return Diagnostic.COMPARISON_DISTINCT_PTR.@emit(p, tok,
		p.fmt_qt(lhs), p.fmt_qt(rhs));
}

fn void? emit_integer_overflow(parser::Parser* p, value::Value result, type_store::QualType qt, tokens::TokenIndex tok)
{
	if (result.is_none()) return;
	return Diagnostic.OVERFLOW.@emit(p, tok, p.fmt_value(result, qt));
}

fn void? emit_pointer_overflow(parser::Parser* p, value::Value result, type_store::QualType qt, tokens::TokenIndex tok)
{
	ulong element_size = qt.child_type(p.comp).sizeof_or_null(p.comp) ?? 1;
	if (element_size == 0) element_size = 1;
	ulong max_elements = p.comp.max_array_bytes() / element_size;
	usz pointer_bits = p.comp.type_store.intptr.bit_sizeof(p.comp);
	return Diagnostic.ARRAY_OVERFLOW.@emit(p, tok, p.fmt_value(result, qt), (ulong)((ulong)pointer_bits), (ulong)(element_size * 8), (ulong)element_size, (ulong)max_elements);
}

fn bool? emit_shift_count_diag(parser::Parser* p, value::Value count, type_store::QualType lhs_qt, tokens::TokenIndex tok)
{
	if (value::compare(count, bigint::CompareOperator.LT, value::ZERO, p.comp))
	{
		Diagnostic.NEGATIVE_SHIFT_COUNT.@emit(p, tok)!;
		return false;
	}
	if (try shift = count.to_usz(p.comp))
	{
		if (shift >= (usz)lhs_qt.bit_sizeof(p.comp))
		{
			Diagnostic.TOO_BIG_SHIFT_COUNT.@emit(p, tok)!;
			return false;
		}
	}
	else
	{
		Diagnostic.TOO_BIG_SHIFT_COUNT.@emit(p, tok)!;
		return false;
	}
	return true;
}

// The result conversion helper handles complex floating operands here instead
// of sending an already-complex target back through QualType.to_complex.
fn void? convert_arithmetic_operands(parser_result::Result* lhs, parser_result::Result* rhs,
	parser::Parser* p, tokens::TokenIndex tok)
{
	bool lhs_complex = lhs.qt.is(p.comp, type_store::TypeTag.COMPLEX);
	bool rhs_complex = rhs.qt.is(p.comp, type_store::TypeTag.COMPLEX);
	if (lhs.qt.is_float(p.comp) && rhs.qt.is_float(p.comp) && (lhs_complex || rhs_complex))
	{
		type_store::QualType lhs_real = lhs.qt.to_real(p.comp);
		type_store::QualType rhs_real = rhs.qt.to_real(p.comp);
		type_store::QualType target = lhs_real.float_rank(p.comp) >= rhs_real.float_rank(p.comp) ? lhs_real : rhs_real;
		target = target.to_complex(p.comp);
		lhs.cast_to_float(p, target, tok)!;
		rhs.cast_to_float(p, target, tok)!;
		return;
	}
	return lhs.usual_arithmetic_conversion(rhs, p, tok);
}

// Pointer Value arithmetic is handled here with byte offsets. Keeping these
// operations out of fold_integer avoids passing pointer values through its
// scalar arithmetic cases.
fn value::Value? fold_pointer_arithmetic(tree::NodeKind op, value::Value lhs, value::Value rhs,
	type_store::QualType pointer_qt, compilation::Compilation* comp, bool* overflowed)
{
	if (lhs.is_none() || rhs.is_none()) return NOT_FOLDABLE~;
	primitive_value::PrimitiveValue lhs_key = comp.interner.get(lhs.ref());
	primitive_value::PrimitiveValue rhs_key = comp.interner.get(rhs.ref());
	type_store::QualType ptrdiff = comp.type_store.ptrdiff;
	ulong elem_size = pointer_qt.child_type(comp).sizeof_or_null(comp) ?? 1;
	if (op == tree::NodeKind.ADD_EXPR)
	{
		bool lhs_pointer = lhs_key.tag == primitive_value::PrimitiveType.POINTER;
		bool rhs_pointer = rhs_key.tag == primitive_value::PrimitiveType.POINTER;
		if (lhs_pointer == rhs_pointer) return NOT_FOLDABLE~;
		primitive_value::KeyPointer pointer = lhs_pointer ? lhs_key.pointer : rhs_key.pointer;
		value::Value index = lhs_pointer ? rhs : lhs;
		if (!index.is_int(comp)) return NOT_FOLDABLE~;
		value::Value delta = value::NONE;
		bool multiply_overflow = delta.mul(value::int_u64(elem_size, comp), index, ptrdiff, comp);
		value::Value offset = value::from_ref(pointer.offset);
		bool add_overflow = delta.add(delta, offset, ptrdiff, comp);
		delta.int_cast(ptrdiff, comp);
		*overflowed = multiply_overflow || add_overflow;
		return value::pointer(
			{
				.node = pointer.node, .offset = delta.ref()
		}
		, comp);
	}
	if (op == tree::NodeKind.SUB_EXPR)
	{
		if (lhs_key.tag != primitive_value::PrimitiveType.POINTER) return NOT_FOLDABLE~;
		if (rhs_key.tag == primitive_value::PrimitiveType.POINTER)
		{
			if (lhs_key.pointer.node != rhs_key.pointer.node) return value::NONE;
			if (elem_size == 0) return NOT_FOLDABLE~;
			value::Value difference = value::NONE;
			*overflowed = difference.sub(value::from_ref(lhs_key.pointer.offset),
			value::from_ref(rhs_key.pointer.offset), ptrdiff, comp);
			difference.div(difference, value::int_u64(elem_size, comp), ptrdiff, comp);
			return difference;
		}
		if (!rhs.is_int(comp)) return NOT_FOLDABLE~;
		value::Value delta = value::NONE;
		bool multiply_overflow = delta.mul(value::int_u64(elem_size, comp), rhs, ptrdiff, comp);
		value::Value offset = value::from_ref(lhs_key.pointer.offset);
		bool subtract_overflow = delta.sub(offset, delta, ptrdiff, comp);
		delta.int_cast(ptrdiff, comp);
		*overflowed = multiply_overflow || subtract_overflow;
		return value::pointer(
			{
				.node = lhs_key.pointer.node, .offset = delta.ref()
		}
		, comp);
	}
	return NOT_FOLDABLE~;
}

// Value arithmetic reports overflow separately from whether it produced a
// value. The wrapped result remains foldable; conversions happen above.
fn value::Value? fold_integer(tree::NodeKind op, value::Value lhs, value::Value rhs, type_store::QualType qt, compilation::Compilation* comp, bool* overflowed)
{
	if (lhs.is_none() || rhs.is_none()) return NOT_FOLDABLE~;
	value::Value out = value::NONE;
	switch (op)
	{
		case ADD_EXPR: *overflowed = out.add(lhs, rhs, qt, comp);
		case SUB_EXPR: *overflowed = out.sub(lhs, rhs, qt, comp);
		case MUL_EXPR: *overflowed = out.mul(lhs, rhs, qt, comp);
		// Integer division by zero is invalid; IEEE floating and complex division
		// by zero still produces a constant (infinity/NaN as appropriate).
		case DIV_EXPR: if (qt.is_int(comp) && rhs.is_zero(comp)) return NOT_FOLDABLE~; *overflowed = out.div(lhs, rhs, qt, comp);
		case MOD_EXPR: if (rhs.is_zero(comp)) return NOT_FOLDABLE~; out = value::rem(lhs, rhs, qt, comp);
		case BIT_OR_EXPR: if (!qt.is_int(comp)) return NOT_FOLDABLE~; out = value::bit_or(lhs, rhs, comp);
		case BIT_XOR_EXPR: if (!qt.is_int(comp)) return NOT_FOLDABLE~; out = value::bit_xor(lhs, rhs, comp);
		case BIT_AND_EXPR: if (!qt.is_int(comp)) return NOT_FOLDABLE~; out = value::bit_and(lhs, rhs, comp);
		case SHL_EXPR: *overflowed = out.shl(lhs, rhs, qt, comp);
		case SHR_EXPR: out = value::shr(lhs, rhs, qt, comp);
		case BOOL_OR_EXPR: return value::from_bool(lhs.to_bool(comp) || rhs.to_bool(comp));
		case BOOL_AND_EXPR: return value::from_bool(lhs.to_bool(comp) && rhs.to_bool(comp));
		case EQUAL_EXPR: return value::from_bool(value::compare(lhs, bigint::CompareOperator.EQ, rhs, comp));
		case NOT_EQUAL_EXPR: return value::from_bool(value::compare(lhs, bigint::CompareOperator.NEQ, rhs, comp));
		case LESS_THAN_EXPR: return value::from_bool(value::compare(lhs, bigint::CompareOperator.LT, rhs, comp));
		case LESS_THAN_EQUAL_EXPR: return value::from_bool(value::compare(lhs, bigint::CompareOperator.LTE, rhs, comp));
		case GREATER_THAN_EXPR: return value::from_bool(value::compare(lhs, bigint::CompareOperator.GT, rhs, comp));
		case GREATER_THAN_EQUAL_EXPR: return value::from_bool(value::compare(lhs, bigint::CompareOperator.GTE, rhs, comp));
		default: return NOT_FOLDABLE~;
	}
	return out;
}

// Zig unExpr's recursive unary productions. Cast-vs-parenthesis
// disambiguation still requires the owning parser's typed type-name hook.
fn parser_result::Result? Parser.unary_expr(&self, bool eval)
{
	// Kept minimal: this frame is live across every nesting level. Operator
	// checks and node building happen out of line after the operand is parsed.
	parser::Parser* p = self;
	if (p.at_eof()) return NO_EXPRESSION~;
	tokens::TokenIndex op_tok = p.tok_i;
	tokenizer::TokenId op = p.tree.tokens[(usz)op_tok].id;
	switch (op)
	{
		case AMPERSAND_AMPERSAND:
			return self.parse_label_address(op_tok);
		case KEYWORD_EXTENSION:
			return self.parse_extension(eval);
		case KEYWORD_SIZEOF:
		case KEYWORD_ALIGNOF:
		case KEYWORD_C23_ALIGNOF:
		case KEYWORD_ALIGNOF1:
		case KEYWORD_ALIGNOF2:
			return self.parse_sizeof_alignof(op, op_tok);
		case AMPERSAND:
		case ASTERISK:
		case KEYWORD_IMAG1:
		case KEYWORD_IMAG2:
		case KEYWORD_REAL1:
		case KEYWORD_REAL2:
		case PLUS:
		case MINUS:
		case BANG:
		case TILDE:
		case PLUS_PLUS:
		case MINUS_MINUS:
			p.advance();
			parser_result::Result? maybe_operand = self.unary_expr(eval);
			if (catch f = maybe_operand) return (f == NO_EXPRESSION ? PARSING_FAILED : f)~;
			return finish_prefix(p, maybe_operand, op, op_tok, eval);
		default:
			break;
	}
	if (op.is_identifier())
	{
		parser_result::Result builtin;
		if (self.parse_builtin_primary_into(eval, &builtin)!) return builtin;
	}
	return self.parse_postfix_expr(eval);
}

<* Prefix operator `op` applied to its parsed operand. *>
fn parser_result::Result? finish_prefix(parser::Parser* p, parser_result::Result operand, tokenizer::TokenId op, tokens::TokenIndex op_tok, bool eval) @noinline
{
	switch (op)
	{
		case AMPERSAND: return finish_address_of(p, operand, op_tok);
		case ASTERISK: return finish_deref(p, operand, op_tok);
		case KEYWORD_IMAG1:
		case KEYWORD_IMAG2: return finish_real_imag(p, operand, op_tok, true, eval);
		case KEYWORD_REAL1:
		case KEYWORD_REAL2: return finish_real_imag(p, operand, op_tok, false, eval);
		default: return finish_prefix_arith(p, operand, op, op_tok, eval);
	}
}

<* `__extension__ unary-expr`: parse the operand with extension diagnostics suppressed. *>
fn parser_result::Result? Parser.parse_extension(&self, bool eval) @noinline
{
	parser::Parser* p = self;
	p.advance();
	bool saved_extension_suppressed = p.extension_suppressed;
	defer p.extension_suppressed = saved_extension_suppressed;
	p.extension_suppressed = true;
	return self.unary_expr(eval);
}

<* Builtin primary: false means "not a builtin", so `unary_expr` falls through. *>
fn bool? Parser.parse_builtin_primary_into(&self, bool eval, parser_result::Result* out) @noinline
{
	parser_result::Result? maybe_builtin = self.parse_builtin_primary(eval);
	if (catch builtin_fault = maybe_builtin)
	{
		if (builtin_fault != NO_EXPRESSION) return builtin_fault~;
		return false;
	}
	* out = maybe_builtin;
	return true;
}

<* `&&label` (GNU label address). Out of line so its locals do not enlarge every recursive
 `unary_expr` frame. *>
fn parser_result::Result? Parser.parse_label_address(&self, tokens::TokenIndex op_tok) @noinline
{
	parser::Parser* p = self;
	if (p.address_of_label)
	{
		return p.address_of_label.handle_address_of_label(p);
	}
	p.advance();
	if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
	{
		{
			p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~;
		}
	}
	tokens::TokenIndex label_tok = p.tok_i;
	Diagnostic.GNU_LABEL_AS_VALUE.@emit(p, op_tok)!;
	p.advance();
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.ADDR_OF_LABEL,
			.addr_of_label = { .label_tok = label_tok, .qt = type_store::VOID_POINTER }
		}
	);
	// An address constant (GCC accepts `static void *t[] = { &&l };`): the pointer
	// names this node, which CodeGen resolves to the label's block address.
	value::Value address = value::pointer({ .node = (uint)node, .offset = value::ZERO.ref() }, p.comp);
	return { .node = node, .qt = type_store::VOID_POINTER, .val = address };
}

<* `&operand` once the operand is parsed. Out of line so its locals do not enlarge every recursive
 `unary_expr` frame. *>
fn parser_result::Result? finish_address_of(parser::Parser* p, parser_result::Result operand, tokens::TokenIndex op_tok) @noinline
{
	// Zig: an invalid operand is not checked as an lvalue and gets no pointer type.
	if (operand.check_invalid_un(p, tree::NodeKind.ADDR_OF_EXPR, op_tok)) return operand;
	bool is_const;
	if (!p.tree.is_lval_extra(operand.node, &is_const) && !operand.qt.is(p.comp, type_store::TypeTag.FUNC))
	{
		Diagnostic.ADDR_OF_RVALUE.@emit(p, op_tok)!;
		return PARSING_FAILED~;
	}
	if (p.tree.is_bitfield(operand.node))
	{
		Diagnostic.ADDR_OF_BITFIELD.@emit(p, op_tok)!;
		return PARSING_FAILED~;
	}
	type_store::QualType pointer_qt = p.comp.type_store.put(type_store::type_pointer(operand.qt));
	value::Value address_val = parser_result::compute_offset(p, operand);
	operand.node = p.tree.add_node(
		{
			.kind = tree::NodeKind.ADDR_OF_EXPR, .unary = { .qt = pointer_qt, .operand = operand.node, .op_tok = op_tok }
		}
	);
	operand.qt = pointer_qt;
	operand.val = address_val;
	return operand;
}

<* `*operand` once the operand is parsed. Out of line so its locals do not enlarge every recursive
 `unary_expr` frame. *>
fn parser_result::Result? finish_deref(parser::Parser* p, parser_result::Result operand, tokens::TokenIndex op_tok) @noinline
{
	if (operand.check_invalid_un(p, tree::NodeKind.DEREF_EXPR, op_tok)) return operand;
	operand.value_conversion(p);
	if (!operand.qt.is_pointer(p.comp))
	{
		Diagnostic.INDIRECTION_PTR.@emit(p, op_tok)!;
		return PARSING_FAILED~;
	}
	type_store::QualType pointee = operand.qt.child_type(p.comp);
	if (pointee.has_incomplete_size(p.comp) && !pointee.is(p.comp, type_store::TypeTag.FUNC))
	{
		if (pointee.is(p.comp, type_store::TypeTag.VOID))
		{
			operand.node = p.tree.add_node(
				{
					.kind = tree::NodeKind.DEREF_EXPR, .unary = { .qt = pointee, .operand = operand.node, .op_tok = op_tok }
				}
			);
			operand.qt = pointee;
			operand.val = value::NONE;
			return operand;
		}
		Diagnostic.DEREF_INCOMPLETE_TY_PTR.@emit(p, op_tok, p.fmt_qt(pointee))!;
		return PARSING_FAILED~;
	}
	operand.node = p.tree.add_node(
		{
			.kind = tree::NodeKind.DEREF_EXPR, .unary = { .qt = pointee, .operand = operand.node, .op_tok = op_tok }
		}
	);
	operand.qt = pointee;
	operand.val = value::NONE;
	return operand;
}

<* `sizeof`/`_Alignof` after the keyword token. Out of line so its locals do not enlarge every recursive
 `unary_expr` frame. *>
fn parser_result::Result? Parser.parse_sizeof_alignof(&self, tokenizer::TokenId op, tokens::TokenIndex op_tok) @noinline
{
	parser::Parser* p = self;
	p.advance();
	// A leading parenthesis can introduce either a type-name or an
	// expression. Only an explicit probe non-match falls back to expression
	// parsing; a matched type-name or probe fault stays committed.
	bool has_expression_operand = true;
	type_store::QualType operand_qt;
	type_store::NodeOptIndex expr = type_store::NODE_NULL;
	if (!p.at_eof() && p.tree.tokens[(usz)p.tok_i].id == tokenizer::TokenId.L_PAREN)
	{
		tokens::TokenIndex paren_tok = p.tok_i;
		p.advance();
		parser::TypeNameProbe probe = p.probe_typed_type_name()!;
		if (!probe.matched)
		{
			p.tok_i = paren_tok;
		}
		else if (!p.at_eof() && p.tree.tokens[(usz)p.tok_i].id == tokenizer::TokenId.R_PAREN)
		{
			operand_qt = probe.qt;
			p.advance();
			has_expression_operand = false;
		}
		else
		{
			p.expected_token_diag(tokenizer::TokenId.R_PAREN)!;
			return PARSING_FAILED~;
		}
	}
	if (has_expression_operand)
	{
		// sizeof and alignof suppress value evaluation while retaining
		// operand type checking.
		parser_result::Result? maybe_operand = self.unary_expr(false);
		if (catch f = maybe_operand) return (f == NO_EXPRESSION ? PARSING_FAILED : f)~;
		parser_result::Result operand = maybe_operand;
		operand_qt = operand.qt;
		expr = (type_store::NodeOptIndex)operand.node;
	}
	bool is_sizeof_op = op == tokenizer::TokenId.KEYWORD_SIZEOF;
	if (operand_qt.is_invalid())
	{
		// Zig: an invalid operand yields an invalid result with no value.
		tree::NodeKind invalid_kind = is_sizeof_op ? tree::NodeKind.SIZEOF_EXPR : tree::NodeKind.ALIGNOF_EXPR;
		type_store::NodeIndex invalid_node = p.tree.add_node(
			{
				.kind = invalid_kind, .type_info = {
					.qt = type_store::INVALID, .op_tok = op_tok, .expr = expr, .operand_qt = operand_qt
				}
			}
		);
		return { .node = invalid_node, .qt = type_store::INVALID, .val = value::NONE };
	}
	if (operand_qt.is(p.comp, type_store::TypeTag.VOID))
	{
		String operation = op == tokenizer::TokenId.KEYWORD_SIZEOF ? "sizeof" : "alignof";
		Diagnostic.POINTER_ARITH_VOID.@emit(p, op_tok, operation)!;
		return PARSING_FAILED~;
	}
	ulong? size_opt = operand_qt.sizeof_or_null(p.comp);
	if (catch f = size_opt)
	{
		if (is_sizeof_op && !operand_qt.has_incomplete_size(p.comp))
		{
			// Zig: sizeof a variable length array is a runtime size_t with no value.
			type_store::QualType size_qt = p.comp.type_store.size;
			type_store::NodeIndex vla_node = p.tree.add_node(
				{
					.kind = tree::NodeKind.SIZEOF_EXPR, .type_info = {
						.qt = size_qt, .op_tok = op_tok, .expr = expr, .operand_qt = operand_qt
					}
				}
			);
			return { .node = vla_node, .qt = size_qt, .val = value::NONE };
		}
		if (op == tokenizer::TokenId.KEYWORD_SIZEOF)
		{
			Diagnostic.INVALID_SIZEOF.@emit(p, op_tok, p.fmt_qt(operand_qt))!;
		}
		else
		{
			Diagnostic.INVALID_ALIGNOF.@emit(p, op_tok, p.fmt_qt(operand_qt))!;
		}
		return PARSING_FAILED~;
	}
	ulong size = size_opt;
	bool is_sizeof = op == tokenizer::TokenId.KEYWORD_SIZEOF;
	// Only the standard spellings warn: __alignof/__alignof__ are themselves GNU and accept expressions.
	if (has_expression_operand && (op == tokenizer::TokenId.KEYWORD_ALIGNOF || op == tokenizer::TokenId.KEYWORD_C23_ALIGNOF))
	{
		String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)op_tok]);
		Diagnostic.GNU_ALIGNOF_EXPR.@emit(p, op_tok, spelling)!;
	}
	type_store::QualType result_qt = p.comp.type_store.size;
	ulong alignment = has_expression_operand ? p.expr_declared_alignment(expr.unwrap(), operand_qt) : operand_qt.alignof(p.comp);
	value::Value result_val = value::int_u64(is_sizeof ? size: alignment, p.comp);
	tree::NodeKind kind = is_sizeof ? tree::NodeKind.SIZEOF_EXPR : tree::NodeKind.ALIGNOF_EXPR;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = kind, .type_info = { .qt = result_qt, .op_tok = op_tok, .expr = expr, .operand_qt = operand_qt }
		}
	);
	return { .node = node, .qt = result_qt, .val = result_val };
}

<* `__alignof__ expr` (GCC, Clang): a variable or member named by the operand
   contributes its own `aligned` attribute on top of the type's alignment. *>
fn uint Parser.expr_declared_alignment(&self, type_store::NodeIndex node, type_store::QualType qt)
{
	uint alignment = qt.alignof(self.comp);
	type_store::NodeIndex current = node;
	while (current.get(&self.tree).kind == tree::NodeKind.PAREN_EXPR) current = current.get(&self.tree).unary.operand;
	tree::Node n = current.get(&self.tree);
	type_store::NodeOptIndex decl = type_store::NODE_NULL;
	switch (n.kind)
	{
		case MEMBER_ACCESS_EXPR:
		case MEMBER_ACCESS_PTR_EXPR:
			type_store::QualType base_qt = n.member_access.base.qt(&self.tree);
			if (n.kind == tree::NodeKind.MEMBER_ACCESS_PTR_EXPR && base_qt.is_pointer(self.comp)) base_qt = base_qt.child_type(self.comp);
			type_store::Record? record = base_qt.get_record(self.comp);
			if (catch record) return alignment;
			if ((usz)n.member_access.member_index >= record.fields.len) return alignment;
			decl = record.fields[n.member_access.member_index].field_decl;
			// A packed member (or a member of a packed record) is byte-aligned
			// unless it also has its own `aligned`.
			if (self.tree.attr_map.has_attribute(decl, attribute::AttributeTag.PACKED) ||
				self.tree.attr_map.has_attribute(record.decl_node, attribute::AttributeTag.PACKED))
			{
				alignment = 1;
			}
		case DECL_REF_EXPR:
			decl = (type_store::NodeOptIndex)n.decl_ref.decl;
		default:
			return alignment;
	}
	if (decl.is_null()) return alignment;
	if (try requested = self.tree.attr_map.requested_alignment(decl, self.comp))
	{
		alignment = alignment == 1 ? requested : max(alignment, requested);
	}
	return alignment;
}

<* `__real__`/`__imag__` once the operand is parsed. Out of line so its locals do not enlarge every recursive
 `unary_expr` frame. *>
fn parser_result::Result? finish_real_imag(parser::Parser* p, parser_result::Result operand, tokens::TokenIndex op_tok, bool is_imag, bool eval) @noinline
{
	if (operand.check_invalid_un(p, is_imag ? tree::NodeKind.IMAG_EXPR : tree::NodeKind.REAL_EXPR, op_tok)) return operand;
	operand.value_conversion(p);
	type_store::ScalarKind scalar_kind = operand.qt.scalar_kind(p.comp);
	if (!scalar_kind.is_arithmetic)
	{
		if (is_imag)
		{
			Diagnostic.INVALID_IMAG.@emit(p, op_tok, p.fmt_qt(operand.qt))!;
		}
		else
		{
			Diagnostic.INVALID_REAL.@emit(p, op_tok, p.fmt_qt(operand.qt))!;
		}
		return PARSING_FAILED~;
	}
	if (eval)
	{
		if (is_imag)
		{
			operand.val = operand.val.imaginary_part(p.comp);
		}
		else
		{
			operand.val = operand.val.real_part(p.comp);
		}
	}
	else
	{
		operand.val = value::NONE;
	}
	operand.qt = operand.qt.to_real(p.comp);
	operand.node = p.tree.add_node(
		{
			.kind = is_imag ? tree::NodeKind.IMAG_EXPR : tree::NodeKind.REAL_EXPR,
			.unary = { .qt = operand.qt, .operand = operand.node, .op_tok = op_tok }
		}
	);
	return operand;
}

<* Prefix `+ - ! ~ ++ --` once the operand is parsed. Out of line so its locals do not enlarge every recursive
 `unary_expr` frame. *>
fn parser_result::Result? finish_prefix_arith(parser::Parser* p, parser_result::Result result, tokenizer::TokenId op, tokens::TokenIndex op_tok, bool eval) @noinline
{
	tree::NodeKind kind;
	switch (op)
	{
		case PLUS: kind = tree::NodeKind.PLUS_EXPR;
		case MINUS: kind = tree::NodeKind.NEGATE_EXPR;
		case BANG: kind = tree::NodeKind.BOOL_NOT_EXPR;
		case TILDE: kind = tree::NodeKind.BIT_NOT_EXPR;
		case PLUS_PLUS: kind = tree::NodeKind.PRE_INC_EXPR;
		case MINUS_MINUS: kind = tree::NodeKind.PRE_DEC_EXPR;
		default: unreachable();
	}
	// Zig: unary plus returns an invalid operand as-is; the others wrap it (checkInvalidUn).
	if (kind == tree::NodeKind.PLUS_EXPR && result.qt.is_invalid()) return result;
	if (result.check_invalid_un(p, kind, op_tok)) return result;
	if (kind == tree::NodeKind.PLUS_EXPR || kind == tree::NodeKind.NEGATE_EXPR || kind == tree::NodeKind.BIT_NOT_EXPR)
	{
		result.value_conversion(p);
		result.usual_unary_conversion(p, op_tok)!;
		type_store::QualType scalar_qt = result.qt;
		if (try vec = result.qt.get(p.comp, type_store::TypeTag.VECTOR)) scalar_qt = vec.vector.elem;
		if (kind == tree::NodeKind.BIT_NOT_EXPR && !scalar_qt.is_int(p.comp) && scalar_qt.scalar_kind(p.comp) != type_store::ScalarKind.COMPLEX_FLOAT)
		{
			Diagnostic.INVALID_ARGUMENT_UN.@emit(p, op_tok, p.fmt_qt(result.qt))!; return PARSING_FAILED~;
		}
		if (kind != tree::NodeKind.BIT_NOT_EXPR && !scalar_qt.is_int(p.comp) && !scalar_qt.is_float(p.comp))
		{
			Diagnostic.INVALID_ARGUMENT_UN.@emit(p, op_tok, p.fmt_qt(result.qt))!; return PARSING_FAILED~;
		}
		if (kind == tree::NodeKind.BIT_NOT_EXPR && scalar_qt.scalar_kind(p.comp) == type_store::ScalarKind.COMPLEX_FLOAT)
		{
			Diagnostic.COMPLEX_CONJ.@emit(p, op_tok, p.fmt_qt(result.qt))!;
		}
	}
	if (kind == tree::NodeKind.BOOL_NOT_EXPR)
	{
		result.value_conversion(p);
		if (result.qt.scalar_kind(p.comp) == type_store::ScalarKind.NONE)
		{
			Diagnostic.INVALID_ARGUMENT_UN.@emit(p, op_tok, p.fmt_qt(result.qt))!; return PARSING_FAILED~;
		}
		result.usual_unary_conversion(p, op_tok)!;
		result.qt = type_store::INT;
	}
	// Constant values fold even when unevaluated (sizeof/typeof operands, untaken
	// ?: and &&/|| arms): C constant expressions do not depend on evaluation, e.g.
	// `(void *)(!1)` is a null pointer constant inside __typeof__. `eval` only gates
	// diagnostics.
	if (!result.val.is_none() && !result.qt.is(p.comp, type_store::TypeTag.VECTOR))
	{
		switch (kind)
		{
			case NEGATE_EXPR: { value::Value folded; folded.negate(result.val, result.qt, p.comp); result.val = folded;
			}
			case BIT_NOT_EXPR:
				if (result.qt.scalar_kind(p.comp) == type_store::ScalarKind.COMPLEX_FLOAT)
				{
					result.val = value::complex_conj(result.val, result.qt, p.comp);
				}
				else
				{
					result.val = value::bit_not(result.val, result.qt, p.comp);
				}
			case BOOL_NOT_EXPR: result.val = value::from_bool(!result.val.to_bool(p.comp));
			default: break;
		}
	}
	else if (!result.val.is_none() && result.qt.is(p.comp, type_store::TypeTag.VECTOR) && kind != tree::NodeKind.PLUS_EXPR)
	{
		result.val = value::NONE;
	}
	if (kind == tree::NodeKind.PRE_INC_EXPR || kind == tree::NodeKind.PRE_DEC_EXPR)
	{
		type_store::ScalarKind scalar_kind = result.qt.scalar_kind(p.comp);
		if (scalar_kind == type_store::ScalarKind.COMPLEX_FLOAT)
		{
			Diagnostic.COMPLEX_PREFIX_POSTFIX_OP.@emit(p, op_tok, p.fmt_qt(result.qt))!;
		}
		bool is_const;
		if (!p.tree.is_lval_extra(result.node, &is_const) || is_const)
		{
			Diagnostic.NOT_ASSIGNABLE.@emit(p, op_tok)!;
			return PARSING_FAILED~;
		}
		if (!result.qt.is_int(p.comp) && !result.qt.is_float(p.comp) && !result.qt.is_pointer(p.comp))
		{
			Diagnostic.INVALID_ARGUMENT_UN.@emit(p, op_tok, p.fmt_qt(result.qt))!; return PARSING_FAILED~;
		}
		if (result.qt.is_pointer(p.comp) && !(validate_pointer_arithmetic(p, result.qt, op_tok)!)) return PARSING_FAILED~;
		if (!eval || !result.val.is_int(p.comp) || !result.qt.is_int(p.comp))
		{
			result.val = value::NONE;
		}
		else
		{
			value::Value folded;
			bool overflowed;
			if (kind == tree::NodeKind.PRE_INC_EXPR)
			{
				overflowed = folded.add(result.val, value::ONE, result.qt, p.comp);
			}
			else
			{
				overflowed = folded.decrement(result.val, result.qt, p.comp);
			}
			result.val = folded;
			if (overflowed) emit_integer_overflow(p, result.val, result.qt, op_tok)!;
		}
	}
	result.node = p.tree.add_node(
		{
			.kind = kind, .unary = { .qt = result.qt, .operand = result.node, .op_tok = op_tok }
		}
	);
	return result;
}

<* Zig `binaryExpr`: left associative operators recurse at next precedence;
   assignment recurses at its own precedence and is therefore right associative. *>
fn parser_result::Result? Parser.parse_expr_prec(&self, tokens::Precedence min_prec = tokens::Precedence.ANY, bool eval = true)
{
	parser::Parser* p = self;
	uint prev_errors = p.diagnostics.errors;
	parser_result::Result lhs = self.unary_expr(eval)!;
	while (!p.at_eof())
	{
		tokenizer::TokenId op = p.tree.tokens[(usz)p.tok_i].id;
		tokens::Precedence prec = tokens::precedence(op);
		if (prec == tokens::Precedence.INVALID || prec.lt(min_prec)) break;
		tokens::TokenIndex op_tok = p.tok_i;
		p.advance();
		if (op == tokenizer::TokenId.QUESTION_MARK)
		{
			lhs = self.parse_conditional(lhs, op_tok, eval)!;
			continue;
		}
		tokens::Precedence rhs_prec = is_assignment(op) ? tokens::Precedence.ASSIGN : (tokens::Precedence)((ichar)prec + 1);
		bool eval_rhs = eval;
		if (op == tokenizer::TokenId.AMPERSAND_AMPERSAND && !lhs.val.is_none()) eval_rhs = eval && lhs.val.to_bool(p.comp);
		if (op == tokenizer::TokenId.PIPE_PIPE && !lhs.val.is_none()) eval_rhs = eval && !lhs.val.to_bool(p.comp);
		parser_result::Result? maybe_rhs = self.parse_expr_prec(rhs_prec, eval_rhs);
		if (catch f = maybe_rhs) return rhs_fault(p, f);
		lhs = self.combine_binary(lhs, maybe_rhs, op, op_tok, eval, &prev_errors)!;
	}
	return lhs;
}

fn parser_result::Result? rhs_fault(parser::Parser* p, fault f) @noinline
{
	if (f != NO_EXPRESSION) return f~;
	Diagnostic.EXPECTED_EXPR.@emit(p, p.diag_index())!;
	return PARSING_FAILED~;
}

<* `lhs ? then : else` (and GNU `lhs ?: else`) after the `?` token. Out of line so its
 locals do not enlarge the frame of every recursive `parse` level. *>
fn parser_result::Result? Parser.parse_conditional(&self, parser_result::Result lhs, tokens::TokenIndex op_tok, bool eval) @noinline
{
	parser::Parser* p = self;
	lhs.value_conversion(p);
	if (lhs.qt.scalar_kind(p.comp) == type_store::ScalarKind.NONE)
	{
		Diagnostic.COND_EXPR_TYPE.@emit(p, op_tok, p.fmt_qt(lhs.qt))!;
		return PARSING_FAILED~;
	}
	bool cond_known = !lhs.val.is_none();
	bool cond_true = cond_known && lhs.val.to_bool(p.comp);
	NodeIndex condition_node = lhs.node;
	bool binary_conditional = !p.at_eof() && p.tree.tokens[(usz)p.tok_i].id == tokenizer::TokenId.COLON;
	parser_result::Result then_expr = { .val = value::NONE };
	if (binary_conditional)
	{
		then_expr = lhs;
		then_expr.node = p.tree.add_node(
			{
				.kind = tree::NodeKind.COND_DUMMY_EXPR, .unary = { .qt = lhs.qt, .operand = condition_node, .op_tok = op_tok }
			}
		);
	}
	else
	{
		parser_result::Result? maybe_then = self.parse_expr_prec(tokens::Precedence.ANY, eval && (!cond_known || cond_true));
		if (catch f = maybe_then)
		{
			if (f == NO_EXPRESSION)
			{
				Diagnostic.EXPECTED_EXPR.@emit(p, p.diag_index())!;
				return PARSING_FAILED~;
			}
			return f~;
		}
		then_expr = maybe_then;
		then_expr.value_conversion(p);
	}
	if (p.at_eof() || p.tree.tokens[(usz)p.tok_i].id != tokenizer::TokenId.COLON)
	{
		p.expected_token_diag(tokenizer::TokenId.COLON)!;
		return PARSING_FAILED~;
	}
	p.advance();
	parser_result::Result? maybe_else = self.parse_expr_prec(tokens::Precedence.CONDITIONAL, eval && (!cond_known || !cond_true));
	if (catch f = maybe_else)
	{
		if (f == NO_EXPRESSION)
		{
			Diagnostic.EXPECTED_EXPR.@emit(p, p.diag_index())!;
			return PARSING_FAILED~;
		}
		return f~;
	}
	parser_result::Result else_expr = maybe_else;
	else_expr.value_conversion(p);
	// Select the conditional type from the two value arms, independently
	// of which arm happened to be evaluated.
	// Zig adjustTypes(.conditional): an invalid arm makes the result invalid.
	if (then_expr.qt.is_invalid() || else_expr.qt.is_invalid())
	{
		then_expr.qt = type_store::INVALID;
		then_expr.val = value::NONE;
		else_expr.val = value::NONE;
	}
	else if (then_expr.qt.is(p.comp, type_store::TypeTag.VOID) || else_expr.qt.is(p.comp, type_store::TypeTag.VOID))
	{
		if (!then_expr.qt.is(p.comp, type_store::TypeTag.VOID))
		{
			then_expr.val = value::NONE;
			then_expr.qt = type_store::VOID;
			then_expr.node = p.tree.add_node(
				{
					.kind = tree::NodeKind.CAST, .cast = { .l_paren = then_expr.node.tok(&p.tree), .kind = tree::CastKind.TO_VOID, .operand = then_expr.node, .qt = type_store::VOID, .implicit = true }
			}
			);
		}
		if (!else_expr.qt.is(p.comp, type_store::TypeTag.VOID))
		{
			else_expr.val = value::NONE;
			else_expr.qt = type_store::VOID;
			else_expr.node = p.tree.add_node(
				{
					.kind = tree::NodeKind.CAST, .cast = { .l_paren = else_expr.node.tok(&p.tree), .kind = tree::CastKind.TO_VOID, .operand = else_expr.node, .qt = type_store::VOID, .implicit = true }
			}
			);
		}
	}
	else if (then_expr.qt.is_pointer(p.comp) && else_expr.qt.is_pointer(p.comp) &&
	then_expr.is_null_pointer_constant(p) != else_expr.is_null_pointer_constant(p))
	{
		// C 6.5.15p6: a null pointer constant arm takes the other arm's type.
		if (then_expr.is_null_pointer_constant(p))
		{
			if (!then_expr.qt.eql(else_expr.qt, p.comp))
			{
				then_expr.val = value::NULL;
				then_expr.qt = else_expr.qt;
				then_expr.node = p.tree.implicit_cast(then_expr.node, then_expr.qt, tree::CastKind.BITCAST);
			}
		}
		else if (!else_expr.qt.eql(then_expr.qt, p.comp))
		{
			else_expr.val = value::NULL;
			else_expr.qt = then_expr.qt;
			else_expr.node = p.tree.implicit_cast(else_expr.node, else_expr.qt, tree::CastKind.BITCAST);
		}
	}
	else if (then_expr.qt.is_pointer(p.comp) && else_expr.qt.is_pointer(p.comp))
	{
		type_store::QualType a_child = then_expr.qt.child_type(p.comp);
		type_store::QualType b_child = else_expr.qt.child_type(p.comp);
		bool compatible_children = a_child.unqualified().eql(b_child.unqualified(), p.comp);
		bool has_void_pointer_branch = a_child.is(p.comp, type_store::TypeTag.VOID) || b_child.is(p.comp, type_store::TypeTag.VOID);
		type_store::QualType common_child = a_child;
		if (!compatible_children && !has_void_pointer_branch)
		{
			Diagnostic.POINTER_MISMATCH.@emit(p, op_tok,
				p.fmt_qt(then_expr.qt), p.fmt_qt(else_expr.qt))!;
			common_child = type_store::VOID;
		}
		else
		{
			if (has_void_pointer_branch) common_child = type_store::VOID;
			common_child.is_const = a_child.is_const || b_child.is_const;
			common_child.is_volatile = a_child.is_volatile || b_child.is_volatile;
			common_child.is_restrict = a_child.is_restrict || b_child.is_restrict;
		}
		type_store::QualType common_pointer = p.comp.type_store.put(type_store::type_pointer(common_child));
		if (!compatible_children && !has_void_pointer_branch)
		{
			then_expr.qt = common_pointer;
			then_expr.node = p.tree.implicit_cast(then_expr.node, then_expr.qt, tree::CastKind.BITCAST);
			else_expr.qt = common_pointer;
			else_expr.node = p.tree.implicit_cast(else_expr.node, else_expr.qt, tree::CastKind.BITCAST);
		}
		else
		{
			bool then_ok = then_expr.coerce_scalar(p, common_pointer, op_tok, parser_result::CoercionContext.EXPRESSION)!;
			bool else_ok = else_expr.coerce_scalar(p, common_pointer, op_tok, parser_result::CoercionContext.EXPRESSION)!;
			if (!then_ok || !else_ok) return PARSING_FAILED~;
		}
	}
	else if (then_expr.qt.is_pointer(p.comp) && else_expr.qt.is_int(p.comp))
	{
		if (!(else_expr.coerce_scalar(p, then_expr.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!))
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(then_expr.qt), p.fmt_qt(else_expr.qt))!; return PARSING_FAILED~;
		}
	}
	else if (else_expr.qt.is_pointer(p.comp) && then_expr.qt.is_int(p.comp))
	{
		if (!(then_expr.coerce_scalar(p, else_expr.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!))
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(then_expr.qt), p.fmt_qt(else_expr.qt))!; return PARSING_FAILED~;
		}
	}
	else if (then_expr.qt.is_pointer(p.comp) && else_expr.qt.is(p.comp, type_store::TypeTag.NULLPTR_T))
	{
		else_expr.coerce_scalar(p, then_expr.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!;
	}
	else if (else_expr.qt.is_pointer(p.comp) && then_expr.qt.is(p.comp, type_store::TypeTag.NULLPTR_T))
	{
		then_expr.coerce_scalar(p, else_expr.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!;
	}
	else if ((then_expr.qt.is_int(p.comp) || then_expr.qt.is_float(p.comp)) && (else_expr.qt.is_int(p.comp) || else_expr.qt.is_float(p.comp)))
	{
		convert_arithmetic_operands(&then_expr, &else_expr, p, op_tok)!;
	}
	else if (!then_expr.qt.eql(else_expr.qt, p.comp))
	{
		Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(then_expr.qt), p.fmt_qt(else_expr.qt))!;
		return PARSING_FAILED~;
	}
	// Both arms determine the conditional type, even when the condition
	// is known and one arm was parsed with evaluation suppressed.
	type_store::QualType conditional_qt = then_expr.qt;
	value::Value conditional_val = value::NONE;
	if (cond_known)
	{
		conditional_val = cond_true ? then_expr.val : else_expr.val;
	}
	lhs.node = p.tree.add_node(
		{
			.kind = binary_conditional ? tree::NodeKind.BINARY_COND_EXPR : tree::NodeKind.COND_EXPR, .conditional = {
				.cond_tok = op_tok, .qt = conditional_qt, .cond = condition_node,
				.then_expr = then_expr.node, .else_expr = else_expr.node,
			}
		}
	);
	lhs.qt = conditional_qt;
	lhs.val = conditional_val;
	return lhs;
}

<* Type-check, fold and build the node for `lhs op rhs` once both operands are
 parsed. Out of line so its many locals and diagnostics do not enlarge the frame
 of every recursive `parse` level (deep nesting would overflow the stack). *>
fn parser_result::Result? Parser.combine_binary(&self, parser_result::Result lhs, parser_result::Result rhs,
	tokenizer::TokenId op, tokens::TokenIndex op_tok, bool eval, uint* prev_errors) @noinline
{
	parser::Parser* p = self;
	tree::NodeKind kind = op.binary_kind();
	if (kind == tree::NodeKind.COMMA_EXPR)
	{
		parser_result::diagnose_unused_value(p, lhs.node, *prev_errors)!;
		*prev_errors = p.diagnostics.errors;
	}
	type_store::QualType original_lhs_qt = lhs.qt;
	type_store::QualType original_rhs_qt = rhs.qt;
	// Zig adjustTypes / coerce: an invalid operand makes the whole expression
	// invalid without further type checks (the operand was already diagnosed).
	if (kind != tree::NodeKind.COMMA_EXPR && (lhs.qt.is_invalid() || rhs.qt.is_invalid()))
	{
		lhs.node = p.tree.add_node(
			{
				.kind = kind, .binary = { .qt = type_store::INVALID, .lhs = lhs.node, .op_tok = op_tok, .rhs = rhs.node }
			}
		);
		lhs.qt = type_store::INVALID;
		lhs.val = value::NONE;
		return lhs;
	}
	if (!is_assignment(op))
	{
		lhs.value_conversion(p);
		rhs.value_conversion(p);
	}
	if (kind != tree::NodeKind.COMMA_EXPR && !is_assignment(op) &&
	(lhs.qt.is(p.comp, type_store::TypeTag.VECTOR) || rhs.qt.is(p.comp, type_store::TypeTag.VECTOR)))
	{
		bool boolean_logic = kind == tree::NodeKind.BOOL_AND_EXPR || kind == tree::NodeKind.BOOL_OR_EXPR;
		adjust_vector_operands(p, &lhs, &rhs, boolean_logic, op_tok, original_lhs_qt, original_rhs_qt)!;
		type_store::QualType vector_qt = lhs.qt;
		if (!vector_qt.is_invalid() && kind.props.bool_result) vector_qt = vector_bool_result(p, vector_qt);
		lhs.node = p.tree.add_node(
			{
				.kind = kind, .binary = { .qt = vector_qt, .lhs = lhs.node, .op_tok = op_tok, .rhs = rhs.node }
			}
		);
		lhs.qt = vector_qt;
		lhs.val = value::NONE;
		return lhs;
	}
	if (is_assignment(op))
	{
		bool is_const;
		if (!p.tree.is_lval_extra(lhs.node, &is_const) || is_const)
		{
			Diagnostic.NOT_ASSIGNABLE.@emit(p, op_tok)!;
			return PARSING_FAILED~;
		}
		if (lhs.qt.is(p.comp, type_store::TypeTag.ARRAY) || lhs.qt.is(p.comp, type_store::TypeTag.FUNC))
		{
			Diagnostic.NOT_ASSIGNABLE.@emit(p, op_tok)!;
			return PARSING_FAILED~;
		}
		if (kind == tree::NodeKind.ASSIGN_EXPR)
		{
			if (!(rhs.coerce_scalar(p, lhs.qt, op_tok, parser_result::CoercionContext.ASSIGNMENT)!))
			{
				Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(lhs.qt), p.fmt_qt(rhs.qt))!; return PARSING_FAILED~;
			}
		}
		else
		{
			// Compound assignment evaluates lhs once. Type-check the implicit
			// calculation using the tree's dummy node, then coerce its result.
			parser_result::Result calc_lhs = lhs;
			calc_lhs.node = p.tree.add_node(
				{
					.kind = tree::NodeKind.COMPOUND_ASSIGN_DUMMY_EXPR, .unary = { .qt = lhs.qt.unqualified(), .operand = lhs.node, .op_tok = op_tok }
			}
			);
			calc_lhs.qt = lhs.qt.unqualified();
			calc_lhs.val = value::NONE;
			if (calc_lhs.qt.is(p.comp, type_store::TypeTag.VECTOR) || rhs.qt.is(p.comp, type_store::TypeTag.VECTOR))
			{
				calc_lhs.value_conversion(p);
				rhs.value_conversion(p);
				adjust_vector_operands(p, &calc_lhs, &rhs, false, op_tok, original_lhs_qt, original_rhs_qt)!;
				if (calc_lhs.qt.is_invalid())
				{
					lhs.node = p.tree.add_node(
						{
							.kind = kind, .binary = { .qt = type_store::INVALID, .lhs = lhs.node, .op_tok = op_tok, .rhs = rhs.node }
						}
					);
					lhs.qt = type_store::INVALID;
					lhs.val = value::NONE;
					return lhs;
				}
			}
			else if (kind == tree::NodeKind.SHL_ASSIGN_EXPR || kind == tree::NodeKind.SHR_ASSIGN_EXPR || kind == tree::NodeKind.BIT_AND_ASSIGN_EXPR || kind == tree::NodeKind.BIT_XOR_ASSIGN_EXPR || kind == tree::NodeKind.BIT_OR_ASSIGN_EXPR || kind == tree::NodeKind.MOD_ASSIGN_EXPR)
			{
				calc_lhs.value_conversion(p); rhs.value_conversion(p);
				calc_lhs.usual_unary_conversion(p, op_tok)!;
				rhs.usual_unary_conversion(p, op_tok)!;
				if (!calc_lhs.qt.is_int(p.comp) || !rhs.qt.is_int(p.comp))
				{
					if (kind == tree::NodeKind.BIT_AND_ASSIGN_EXPR || kind == tree::NodeKind.BIT_XOR_ASSIGN_EXPR || kind == tree::NodeKind.BIT_OR_ASSIGN_EXPR || kind == tree::NodeKind.MOD_ASSIGN_EXPR)
					{
						Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!;
						return PARSING_FAILED~;
					}
					Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!;
					return PARSING_FAILED~;
				}
				if ((kind == tree::NodeKind.SHL_ASSIGN_EXPR || kind == tree::NodeKind.SHR_ASSIGN_EXPR) && eval && !rhs.val.is_none())
				{
					emit_shift_count_diag(p, rhs.val, calc_lhs.qt, op_tok)!;
				}
				// `%=`, `&=`, `^=`, `|=` compute in the common type of both operands
				// (`u64 |= i32` sign-extends the right side); shifts keep the lhs type.
				if (kind != tree::NodeKind.SHL_ASSIGN_EXPR && kind != tree::NodeKind.SHR_ASSIGN_EXPR)
				{
					convert_arithmetic_operands(&calc_lhs, &rhs, p, op_tok)!;
				}
			}
			else if (kind == tree::NodeKind.ADD_ASSIGN_EXPR && calc_lhs.qt.is_pointer(p.comp))
			{
				if (!(validate_pointer_arithmetic(p, calc_lhs.qt, op_tok)!)) return PARSING_FAILED~;
				calc_lhs.value_conversion(p);
				rhs.value_conversion(p);
				rhs.usual_unary_conversion(p, op_tok)!;
				if (!rhs.qt.is_int(p.comp))
				{
					Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
				}
			}
			else if (kind == tree::NodeKind.SUB_ASSIGN_EXPR && calc_lhs.qt.is_pointer(p.comp))
			{
				if (!(validate_pointer_arithmetic(p, calc_lhs.qt, op_tok)!)) return PARSING_FAILED~;
				calc_lhs.value_conversion(p);
				rhs.value_conversion(p);
				rhs.usual_unary_conversion(p, op_tok)!;
				if (!rhs.qt.is_int(p.comp))
				{
					Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
				}
			}
			else
			{
				calc_lhs.value_conversion(p);
				rhs.value_conversion(p);
				if ((!calc_lhs.qt.is_int(p.comp) && !calc_lhs.qt.is_float(p.comp)) || (!rhs.qt.is_int(p.comp) && !rhs.qt.is_float(p.comp)))
				{
					Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
				}
				convert_arithmetic_operands(&calc_lhs, &rhs, p, op_tok)!;
				if (!calc_lhs.qt.is_int(p.comp) && !calc_lhs.qt.is_float(p.comp))
				{
					Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
				}
			}
			if ((kind == tree::NodeKind.DIV_ASSIGN_EXPR || kind == tree::NodeKind.MOD_ASSIGN_EXPR) && eval && calc_lhs.qt.is_int(p.comp) && !rhs.val.is_none() && rhs.val.is_zero(p.comp))
			{
				String operation = kind == tree::NodeKind.DIV_ASSIGN_EXPR ? "division" : "remainder";
				Diagnostic.DIVISION_BY_ZERO.@emit(p, op_tok, operation)!;
			}
			tree::NodeKind calc_kind;
			switch (kind)
			{
				case MUL_ASSIGN_EXPR: calc_kind = tree::NodeKind.MUL_EXPR;
				case DIV_ASSIGN_EXPR: calc_kind = tree::NodeKind.DIV_EXPR;
				case MOD_ASSIGN_EXPR: calc_kind = tree::NodeKind.MOD_EXPR;
				case ADD_ASSIGN_EXPR: calc_kind = tree::NodeKind.ADD_EXPR;
				case SUB_ASSIGN_EXPR: calc_kind = tree::NodeKind.SUB_EXPR;
				case SHL_ASSIGN_EXPR: calc_kind = tree::NodeKind.SHL_EXPR;
				case SHR_ASSIGN_EXPR: calc_kind = tree::NodeKind.SHR_EXPR;
				case BIT_AND_ASSIGN_EXPR: calc_kind = tree::NodeKind.BIT_AND_EXPR;
				case BIT_XOR_ASSIGN_EXPR: calc_kind = tree::NodeKind.BIT_XOR_EXPR;
				case BIT_OR_ASSIGN_EXPR: calc_kind = tree::NodeKind.BIT_OR_EXPR;
				default: unreachable();
			}
			type_store::QualType calc_qt = calc_lhs.qt;
			if (calc_kind == tree::NodeKind.SUB_EXPR && calc_lhs.qt.is_pointer(p.comp) && rhs.qt.is_pointer(p.comp)) calc_qt = p.comp.type_store.ptrdiff;
			calc_lhs.node = p.tree.add_node(
				{
					.kind = calc_kind, .binary = { .qt = calc_qt, .lhs = calc_lhs.node, .op_tok = op_tok, .rhs = rhs.node }
				}
			);
			calc_lhs.qt = calc_qt;
			calc_lhs.val = value::NONE;
			if (!(calc_lhs.coerce_scalar(p, lhs.qt.unqualified(), op_tok, parser_result::CoercionContext.ASSIGNMENT)!))
			{
				Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(lhs.qt), p.fmt_qt(calc_lhs.qt))!; return PARSING_FAILED~;
			}
			lhs.node = p.tree.add_node(
				{
					.kind = kind, .binary = { .qt = lhs.qt.unqualified(), .lhs = lhs.node, .op_tok = op_tok, .rhs = calc_lhs.node }
			}
			);
			lhs.qt = lhs.qt.unqualified();
			lhs.val = value::NONE;
			return lhs;
		}
	}
	else if (kind == tree::NodeKind.BOOL_AND_EXPR || kind == tree::NodeKind.BOOL_OR_EXPR)
	{
		lhs.value_conversion(p);
		rhs.value_conversion(p);
		if (lhs.qt.scalar_kind(p.comp) == type_store::ScalarKind.NONE || rhs.qt.scalar_kind(p.comp) == type_store::ScalarKind.NONE)
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
		}
	}
	else if (kind == tree::NodeKind.SHL_EXPR || kind == tree::NodeKind.SHR_EXPR)
	{
		lhs.value_conversion(p); rhs.value_conversion(p);
		lhs.usual_unary_conversion(p, op_tok)!;
		rhs.usual_unary_conversion(p, op_tok)!;
		if (!lhs.qt.is_int(p.comp) || !rhs.qt.is_int(p.comp))
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
		}
	}
	else if (kind == tree::NodeKind.ADD_EXPR && ((lhs.qt.is_pointer(p.comp) && rhs.qt.is_int(p.comp)) || (rhs.qt.is_pointer(p.comp) && lhs.qt.is_int(p.comp))))
	{
		if (lhs.qt.is_pointer(p.comp))
		{
			if (!(validate_pointer_arithmetic(p, lhs.qt, op_tok)!)) return PARSING_FAILED~; rhs.usual_unary_conversion(p, op_tok)!;
		}
		else
		{
			if (!(validate_pointer_arithmetic(p, rhs.qt, op_tok)!)) return PARSING_FAILED~; lhs.usual_unary_conversion(p, op_tok)!;
		}
	}
	else if (kind == tree::NodeKind.SUB_EXPR && lhs.qt.is_pointer(p.comp) && (rhs.qt.is_int(p.comp) || rhs.qt.is_pointer(p.comp)))
	{
		if (!(validate_pointer_arithmetic(p, lhs.qt, op_tok)!)) return PARSING_FAILED~;
		if (rhs.qt.is_int(p.comp))
		{
			rhs.usual_unary_conversion(p, op_tok)!;
		}
		else
		{
			if (!rhs.qt.child_type(p.comp).is(p.comp, type_store::TypeTag.VOID) && !(validate_pointer_arithmetic(p, rhs.qt, op_tok)!)) return PARSING_FAILED~;
			if (!compatible_pointees(lhs.qt, rhs.qt, p.comp))
			{
				Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
			}
		}
	}
	else if (kind == tree::NodeKind.BIT_AND_EXPR || kind == tree::NodeKind.BIT_OR_EXPR || kind == tree::NodeKind.BIT_XOR_EXPR || kind == tree::NodeKind.MOD_EXPR)
	{
		lhs.value_conversion(p); rhs.value_conversion(p);
		convert_arithmetic_operands(&lhs, &rhs, p, op_tok)!;
		if (!lhs.qt.is_int(p.comp) || !rhs.qt.is_int(p.comp))
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
		}
	}
	else if (kind == tree::NodeKind.LESS_THAN_EXPR || kind == tree::NodeKind.LESS_THAN_EQUAL_EXPR || kind == tree::NodeKind.GREATER_THAN_EXPR || kind == tree::NodeKind.GREATER_THAN_EQUAL_EXPR)
	{
		if ((lhs.qt.is_int(p.comp) || lhs.qt.is_float(p.comp)) && (rhs.qt.is_int(p.comp) || rhs.qt.is_float(p.comp)))
		{
			lhs.value_conversion(p); rhs.value_conversion(p);
			convert_arithmetic_operands(&lhs, &rhs, p, op_tok)!;
			if (!lhs.qt.is_int(p.comp) && !lhs.qt.is_float(p.comp))
			{
				Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
			}
			if (!lhs.qt.scalar_kind(p.comp).is_real)
			{
				Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
			}
		}
		else if (lhs.qt.is_pointer(p.comp) && rhs.qt.is_pointer(p.comp))
		{
			type_store::QualType lhs_child = lhs.qt.child_type(p.comp);
			type_store::QualType rhs_child = rhs.qt.child_type(p.comp);
			bool distinct_non_void_pointees = !compatible_pointees(lhs.qt, rhs.qt, p.comp) && !lhs_child.is(p.comp, type_store::TypeTag.VOID) && !rhs_child.is(p.comp, type_store::TypeTag.VOID);
			lhs.value_conversion(p); rhs.value_conversion(p);
			if (distinct_non_void_pointees)
			{
				warn_distinct_pointer_comparison(p, lhs.qt, rhs.qt, op_tok)!;
				rhs.cast_to_pointer(p, lhs.qt, op_tok, false)!;
			}
			else
			{
				type_store::QualType common_child = lhs_child;
				if (lhs_child.is(p.comp, type_store::TypeTag.VOID) || rhs_child.is(p.comp, type_store::TypeTag.VOID)) common_child = type_store::VOID;
				common_child.is_const = lhs_child.is_const || rhs_child.is_const;
				common_child.is_volatile = lhs_child.is_volatile || rhs_child.is_volatile;
				common_child.is_restrict = lhs_child.is_restrict || rhs_child.is_restrict;
				type_store::QualType common_pointer = p.comp.type_store.put(type_store::type_pointer(common_child));
				if (!lhs.coerce_scalar(p, common_pointer, op_tok, parser_result::CoercionContext.EXPRESSION)! || !rhs.coerce_scalar(p, common_pointer, op_tok, parser_result::CoercionContext.EXPRESSION)!)
				{
					Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
				}
			}
		}
		else
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!;
			return PARSING_FAILED~;
		}
	}
	else if (kind == tree::NodeKind.EQUAL_EXPR || kind == tree::NodeKind.NOT_EQUAL_EXPR)
	{
		if ((lhs.qt.is_int(p.comp) || lhs.qt.is_float(p.comp)) && (rhs.qt.is_int(p.comp) || rhs.qt.is_float(p.comp)))
		{
			lhs.value_conversion(p); rhs.value_conversion(p);
			convert_arithmetic_operands(&lhs, &rhs, p, op_tok)!;
		}
		else if (lhs.qt.is_pointer(p.comp) && rhs.qt.is_pointer(p.comp))
		{
			type_store::QualType lhs_child = lhs.qt.child_type(p.comp);
			type_store::QualType rhs_child = rhs.qt.child_type(p.comp);
			bool distinct_non_void_pointees = !compatible_pointees(lhs.qt, rhs.qt, p.comp) && !lhs_child.is(p.comp, type_store::TypeTag.VOID) && !rhs_child.is(p.comp, type_store::TypeTag.VOID);
			lhs.value_conversion(p); rhs.value_conversion(p);
			if (distinct_non_void_pointees)
			{
				warn_distinct_pointer_comparison(p, lhs.qt, rhs.qt, op_tok)!;
				rhs.cast_to_pointer(p, lhs.qt, op_tok, false)!;
			}
			else
			{
				type_store::QualType common_child = lhs_child;
				if (lhs_child.is(p.comp, type_store::TypeTag.VOID) || rhs_child.is(p.comp, type_store::TypeTag.VOID)) common_child = type_store::VOID;
				common_child.is_const = lhs_child.is_const || rhs_child.is_const;
				common_child.is_volatile = lhs_child.is_volatile || rhs_child.is_volatile;
				common_child.is_restrict = lhs_child.is_restrict || rhs_child.is_restrict;
				type_store::QualType common_pointer = p.comp.type_store.put(type_store::type_pointer(common_child));
				if (!lhs.coerce_scalar(p, common_pointer, op_tok, parser_result::CoercionContext.EXPRESSION)! || !rhs.coerce_scalar(p, common_pointer, op_tok, parser_result::CoercionContext.EXPRESSION)!)
				{
					Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
				}
			}
		}
		else if (lhs.qt.is_pointer(p.comp) && rhs.qt.is_int(p.comp) && rhs.val.is_zero(p.comp))
		{
			rhs.coerce_scalar(p, lhs.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!;
		}
		else if (rhs.qt.is_pointer(p.comp) && lhs.qt.is_int(p.comp) && lhs.val.is_zero(p.comp))
		{
			lhs.coerce_scalar(p, rhs.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!;
		}
		else if (lhs.qt.is_pointer(p.comp) && rhs.qt.is(p.comp, type_store::TypeTag.NULLPTR_T))
		{
			rhs.coerce_scalar(p, lhs.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!;
		}
		else if (rhs.qt.is_pointer(p.comp) && lhs.qt.is(p.comp, type_store::TypeTag.NULLPTR_T))
		{
			lhs.coerce_scalar(p, rhs.qt, op_tok, parser_result::CoercionContext.EXPRESSION)!;
		}
		else
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!;
			return PARSING_FAILED~;
		}
	}
	else if (kind != tree::NodeKind.COMMA_EXPR)
	{
		lhs.value_conversion(p); rhs.value_conversion(p);
		if ((!lhs.qt.is_int(p.comp) && !lhs.qt.is_float(p.comp)) || (!rhs.qt.is_int(p.comp) && !rhs.qt.is_float(p.comp)))
		{
			Diagnostic.INVALID_BIN_TYPES.@emit(p, op_tok, p.fmt_qt(original_lhs_qt), p.fmt_qt(original_rhs_qt))!; return PARSING_FAILED~;
		}
		convert_arithmetic_operands(&lhs, &rhs, p, op_tok)!;
	}
	else
	{
		lhs.value_conversion(p); rhs.value_conversion(p);
	}
	// The result type follows the converted left operand except for comma
	// and the integer-typed comparison/logical operators.
	type_store::QualType result_qt = lhs.qt;
	if (op == COMMA) result_qt = rhs.qt;
	if (is_assignment(op)) result_qt = lhs.qt.unqualified();
	if (kind == tree::NodeKind.SUB_EXPR && lhs.qt.is_pointer(p.comp) && rhs.qt.is_pointer(p.comp)) result_qt = p.comp.type_store.ptrdiff;
	if (kind == tree::NodeKind.BOOL_OR_EXPR || kind == tree::NodeKind.BOOL_AND_EXPR ||
		kind == tree::NodeKind.EQUAL_EXPR || kind == tree::NodeKind.NOT_EQUAL_EXPR ||
		kind == tree::NodeKind.LESS_THAN_EXPR || kind == tree::NodeKind.LESS_THAN_EQUAL_EXPR ||
		kind == tree::NodeKind.GREATER_THAN_EXPR || kind == tree::NodeKind.GREATER_THAN_EQUAL_EXPR)
	{
		result_qt = type_store::INT;
	}
	if (kind == tree::NodeKind.ADD_EXPR && rhs.qt.is_pointer(p.comp)) result_qt = rhs.qt;
	bool division_by_zero = eval && (kind == tree::NodeKind.DIV_EXPR || kind == tree::NodeKind.MOD_EXPR) && lhs.qt.is_int(p.comp) && !rhs.val.is_none() && rhs.val.is_zero(p.comp);
	if (division_by_zero)
	{
		String operation = kind == tree::NodeKind.DIV_EXPR ? "division" : "remainder";
		Diagnostic.DIVISION_BY_ZERO.@emit(p, op_tok, operation)!;
	}
	if ((kind == tree::NodeKind.SHL_EXPR || kind == tree::NodeKind.SHR_EXPR) && eval && !lhs.val.is_none() && !rhs.val.is_none()) emit_shift_count_diag(p, rhs.val, lhs.qt, op_tok)!;
	value::Value folded = value::NONE;
	bool overflowed = false;
	// A comma folds only when its left operand folded too: `(f(), 3)` must keep
	// the call, and codegen emits any value-mapped node as a bare constant.
	if (kind == tree::NodeKind.COMMA_EXPR && eval && !lhs.val.is_none()) folded = rhs.val;
	// Fold regardless of `eval` (see unary_expr); diagnostics stay gated on it.
	if (!is_assignment(op))
	{
		if ((kind == tree::NodeKind.BOOL_AND_EXPR && !lhs.val.is_none() && !lhs.val.to_bool(p.comp)) ||
		(kind == tree::NodeKind.BOOL_OR_EXPR && !lhs.val.is_none() && lhs.val.to_bool(p.comp)))
		{
			folded = value::from_bool(kind == tree::NodeKind.BOOL_OR_EXPR);
		}
		else if (!division_by_zero)
		{
			if (kind == tree::NodeKind.SUB_EXPR && lhs.qt.is_pointer(p.comp))
			{
				ulong elem_size = 1;
				if (try size = lhs.qt.child_type(p.comp).sizeof_or_null(p.comp))
				{
					elem_size = size;
				}
				if (elem_size == 0 && rhs.qt.is_pointer(p.comp))
				{
					type_store::QualType pointee = lhs.qt.child_type(p.comp);
					if (eval) Diagnostic.SUBTRACT_POINTERS_ZERO_ELEM_SIZE.@emit(p, op_tok,
						p.fmt_qt(pointee))!;
				}
				else
				{
					if (try pointer_fold = fold_pointer_arithmetic(kind, lhs.val, rhs.val, lhs.qt, p.comp, &overflowed))
					{
						folded = pointer_fold;
					}
				}
			}
			else if (kind == tree::NodeKind.EQUAL_EXPR || kind == tree::NodeKind.NOT_EQUAL_EXPR || kind == tree::NodeKind.LESS_THAN_EXPR || kind == tree::NodeKind.LESS_THAN_EQUAL_EXPR || kind == tree::NodeKind.GREATER_THAN_EXPR || kind == tree::NodeKind.GREATER_THAN_EQUAL_EXPR)
			{
				bigint::CompareOperator cmp;
				switch (kind)
				{
					case EQUAL_EXPR: cmp = EQ;
					case NOT_EQUAL_EXPR: cmp = NEQ;
					case LESS_THAN_EXPR: cmp = LT;
					case LESS_THAN_EQUAL_EXPR: cmp = LTE;
					case GREATER_THAN_EXPR: cmp = GT;
					case GREATER_THAN_EQUAL_EXPR: cmp = GTE;
					default: unreachable();
				}
				if (lhs.qt.is_pointer(p.comp))
				{
					bool lhs_null = lhs.val.opt_ref == value::NULL.opt_ref;
					bool rhs_null = rhs.val.opt_ref == value::NULL.opt_ref;
					if ((kind == tree::NodeKind.EQUAL_EXPR || kind == tree::NodeKind.NOT_EQUAL_EXPR) && lhs_null && rhs_null)
					{
						folded = value::from_bool(kind == tree::NodeKind.EQUAL_EXPR);
					}
					else if ((kind == tree::NodeKind.EQUAL_EXPR || kind == tree::NodeKind.NOT_EQUAL_EXPR) && ((lhs_null && !rhs.val.is_none()) || (rhs_null && !lhs.val.is_none())))
					{
						folded = value::from_bool(kind == tree::NodeKind.NOT_EQUAL_EXPR);
					}
					else if (try ptr_cmp = value::compare_pointers(lhs.val, cmp, rhs.val, p.comp))
					{
						folded = value::from_bool(ptr_cmp);
					}
				}
				else if (try fold = fold_integer(kind, lhs.val, rhs.val, result_qt, p.comp, &overflowed))
				{
					folded = fold;
				}
				if (p.record_static_assert_eval_note && !folded.is_none() && folded.is_zero(p.comp))
				{
					if (!lhs.val.is_none() && lhs.val.opt_ref != value_interner::OPT_NULL)
					{
						p.tree.set_value(lhs.node, lhs.val);
					}
					if (!rhs.val.is_none() && rhs.val.opt_ref != value_interner::OPT_NULL)
					{
						p.tree.set_value(rhs.node, rhs.val);
					}
				}
			}
			else
			{
				if (kind == tree::NodeKind.ADD_EXPR && result_qt.is_pointer(p.comp))
				{
					if (try pointer_fold = fold_pointer_arithmetic(kind, lhs.val, rhs.val, result_qt, p.comp, &overflowed))
					{
						folded = pointer_fold;
					}
				}
				else if (try fold = fold_integer(kind, lhs.val, rhs.val, result_qt, p.comp, &overflowed))
				{
					folded = fold;
				}
			}
			if (!eval)
			{
				// Unevaluated: no overflow diagnostics.
			}
			else if (overflowed && kind == tree::NodeKind.ADD_EXPR && result_qt.is_pointer(p.comp))
			{
				emit_pointer_overflow(p, folded, result_qt, op_tok)!;
			}
			else if (overflowed && result_qt.is_int(p.comp) && result_qt.signedness(p.comp) != bigint::Signedness.UNSIGNED)
			{
				emit_integer_overflow(p, folded, result_qt, op_tok)!;
			}
		}
	}
	// Zig Result.shouldEval: when the whole expression does not fold, keep each
	// constant operand's value in the tree so codegen can emit it as a constant
	// (`sizeof(int) * n`: sizeof_expr has no other codegen).
	if (folded.is_none())
	{
		lhs.save_value(p);
		rhs.save_value(p);
	}
	lhs.node = p.tree.add_node(
		{
			.kind = kind, .binary = { .qt = result_qt, .lhs = lhs.node, .op_tok = op_tok, .rhs = rhs.node }
		}
	);
	lhs.qt = result_qt;
	lhs.val = folded;
	return lhs;
}

<* Parser.zig expression entry points over the binary precedence engine. *>
fn parser_result::Result? parser::Parser.expr(&self, bool eval = true)
{
	return self.parse_expr_prec(tokens::Precedence.ANY, eval);
}

fn parser_result::Result? parser::Parser.assign_expr(&self, bool eval = true)
{
	return self.parse_expr_prec(tokens::Precedence.ASSIGN, eval);
}

<* Parse an assignment expression with `folding_mode` active for constant
   declaration references. The previous mode is restored on success and on
   parse failure, the same way const_expr restores it. *>
fn parser_result::Result? parser::Parser.assign_expr_with_folding(&self, bool eval, parser::ConstDeclFoldingMode folding_mode)
{
	parser::ConstDeclFoldingMode previous_mode = self.const_decl_folding;
	defer self.const_decl_folding = previous_mode;
	self.const_decl_folding = folding_mode;
	return self.parse_expr_prec(tokens::Precedence.ASSIGN, eval);
}

fn parser_result::Result? parser::Parser.const_expr(&self, bool eval = true,
	parser::ConstDeclFoldingMode folding_mode = parser::ConstDeclFoldingMode.FOLD_CONST_DECLS)
{
	parser::ConstDeclFoldingMode previous_mode = self.const_decl_folding;
	defer self.const_decl_folding = previous_mode;
	self.const_decl_folding = folding_mode;
	parser_result::Result? parsed = self.parse_expr_prec(tokens::Precedence.CONDITIONAL, eval);
	if (catch f = parsed) return (f == NO_EXPRESSION ? PARSING_FAILED : f)~;
	parser_result::Result result = parsed;
	if (!eval || result.qt.is_invalid() || result.val.is_none()) return result;
	self.tree.set_value(result.node, result.val);
	return result;
}

fn parser_result::Result? parser::Parser.integer_const_expr(&self, bool eval = true,
	parser::ConstDeclFoldingMode folding_mode = parser::ConstDeclFoldingMode.FOLD_CONST_DECLS)
{
	parser_result::Result? parsed = self.const_expr(eval, folding_mode);
	if (catch parsed_fault = parsed) return (parsed_fault == NO_EXPRESSION ? PARSING_FAILED : parsed_fault)~;
	parser_result::Result result = parsed;
	if (!result.qt.is_invalid() && !result.qt.is_real_int(self.comp))
	{
		Diagnostic.EXPECTED_INTEGER_CONSTANT_EXPR.@emit(self, result.node.tok(&self.tree))!;
		return PARSING_FAILED~;
	}
	return result;
}
