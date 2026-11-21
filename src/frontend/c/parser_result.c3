// Core expression-result conversions from Parser.zig's Result.
// Diagnostics and the full parser grammar are intentionally owned by the
// parser layer; these helpers preserve the typed AST and constant value.
module aro::frontend::c::parser_result;
import aro::primitive_value;
import aro::frontend::c::parser, aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner, aro::frontend::c::tokens, aro::frontend::c::diagnostics;
import aro::frontend::c::compilation;
import aro::frontend::c::lang_opts;
import aro::frontend::c::attribute, aro::frontend::c::builtins;
import std::core::dstring, std::io;

struct Result
{
	type_store::NodeIndex node;
	type_store::QualType qt;
	value::Value val;
}

<* The operation requesting a scalar coercion selects the wording for pointer diagnostics. *>
enum CoercionContext : char
{
	EXPRESSION, INITIALIZATION, ASSIGNMENT, RETURN, ARGUMENT
}

<* Write an attribute message using Zig's stringEscape formatting. *>
fn void? append_escaped(OutStream out, String text)
{
	foreach (c : text)
	{
		switch (c)
		{
			case '\n': out.write("\\n")!;
			case '\r': out.write("\\r")!;
			case '\t': out.write("\\t")!;
			case '\\': out.write("\\\\")!;
			case '"': out.write("\\\"")!;
			default:
				if (c >= ' ' && c <= '~')
				{
					out.write_byte(c)!;
				}
				else
				{
					io::fprintf(out, "\\x%02x", c)!;
				}
		}
	}
}

<* Diagnose a discarded expression result, following Parser.zig's operator and
 call-attribute exemptions. `prev_errors` suppresses a secondary warning when
 parsing the expression already produced an error. *>
fn void? diagnose_unused_value(parser::Parser* p, type_store::NodeIndex node, uint prev_errors)
{
	type_store::QualType qt = node.qt(&p.tree);
	if (qt.is(p.comp, type_store::TypeTag.VOID) || qt.is_invalid()) return;
	if (p.diagnostics.errors != prev_errors) return;

	type_store::NodeIndex cur_node = node;
	tree::Node cur = cur_node.get(&p.tree);
	while (true)
	{
		switch (cur.kind)
		{
			case tree::NodeKind.ASSIGN_EXPR:
			case tree::NodeKind.MUL_ASSIGN_EXPR:
			case tree::NodeKind.DIV_ASSIGN_EXPR:
			case tree::NodeKind.MOD_ASSIGN_EXPR:
			case tree::NodeKind.ADD_ASSIGN_EXPR:
			case tree::NodeKind.SUB_ASSIGN_EXPR:
			case tree::NodeKind.SHL_ASSIGN_EXPR:
			case tree::NodeKind.SHR_ASSIGN_EXPR:
			case tree::NodeKind.BIT_AND_ASSIGN_EXPR:
			case tree::NodeKind.BIT_XOR_ASSIGN_EXPR:
			case tree::NodeKind.BIT_OR_ASSIGN_EXPR:
			case tree::NodeKind.PRE_INC_EXPR:
			case tree::NodeKind.PRE_DEC_EXPR:
			case tree::NodeKind.POST_INC_EXPR:
			case tree::NodeKind.POST_DEC_EXPR:
				return;
			case tree::NodeKind.EQUAL_EXPR:
				return Diagnostic.UNUSED_COMPARISON.@emit(p, cur_node.tok(&p.tree), "equality");
			case tree::NodeKind.NOT_EQUAL_EXPR:
				return Diagnostic.UNUSED_COMPARISON.@emit(p, cur_node.tok(&p.tree), "inequality");
			case tree::NodeKind.LESS_THAN_EXPR:
			case tree::NodeKind.LESS_THAN_EQUAL_EXPR:
			case tree::NodeKind.GREATER_THAN_EXPR:
			case tree::NodeKind.GREATER_THAN_EQUAL_EXPR:
				return Diagnostic.UNUSED_COMPARISON.@emit(p, cur_node.tok(&p.tree), "relational");
			case tree::NodeKind.CALL_EXPR:
				{
					tree::CalledFunctionAttr? maybe_info = p.tree.called_function_attr(cur.call.callee, attribute::AttributeTag.WARN_UNUSED_RESULT);
					if (!@ok(maybe_info)) return;
					tree::CalledFunctionAttr info = maybe_info!;
					if (!info.has_attr) return;
					attribute::Attribute attr = info.attr;
					String attr_name = attr.name.name();
					bool namespaced = attr.syntax == attribute::AttributeSyntax.STANDARD && attr.name.ns != attribute::AttrNamespace.STANDARD;
					String spelling = namespaced ? string::tformat("'%s::%s'", attr.name.ns.name, attr_name) : string::tformat("'%s'", attr_name);
					bool has_msg = attr.args.warn_unused_result.has_msg;
					DString escaped;
					escaped.init(tmem);
					if (has_msg) append_escaped(&escaped, attr.args.warn_unused_result.msg)!;
					return Diagnostic.WARN_UNUSED_RESULT.@emit(p, cur.call.callee.tok(&p.tree), p.tree.tok_slice(info.tok), spelling,
					has_msg ? ": " : "", escaped.str_view());
				}
			case tree::NodeKind.BUILTIN_CALL_EXPR:
				{
					String name = p.tree.tok_slice(cur.builtin_call.builtin_tok);
					builtins::Expanded builtin = p.comp.builtins.lookup(name);
					if (builtin.attributes.pure)
					{
						Diagnostic.BUILTIN_UNUSED.@emit(p, cur.builtin_call.builtin_tok, "'pure'")!;
					}
					if (builtin.attributes.is_const)
					{
						Diagnostic.BUILTIN_UNUSED.@emit(p, cur.builtin_call.builtin_tok, "'const'")!;
					}
					return;
				}
			case tree::NodeKind.STMT_EXPR:
				{
					tree::Node body = cur.unary.operand.get(&p.tree);
					if (body.compound_stmt.body.len == 0) return;
					cur_node = body.compound_stmt.body[body.compound_stmt.body.len - 1];
					cur = cur_node.get(&p.tree);
				}
			case tree::NodeKind.COMMA_EXPR:
				cur_node = cur.binary.rhs;
				cur = cur_node.get(&p.tree);
			case tree::NodeKind.PAREN_EXPR:
				cur_node = cur.unary.operand;
				cur = cur_node.get(&p.tree);
			default:
				return Diagnostic.UNUSED_VALUE.@emit(p, cur_node.tok(&p.tree));
		}
	}
}

fn void? Result.explicit_cast_warnings(&self, parser::Parser* p, tokens::TokenIndex tok, type_store::QualType dest, type_store::QualType original)
{
	if (dest.is_qualified())
	{
		Diagnostic.QUAL_CAST.@emit(p, tok, p.fmt_qt(dest))!;
	}
	if (dest.is_int(p.comp) && original.is_pointer(p.comp) && dest.size_compare(original, p.comp) == type_store::TypeSizeOrder.LT)
	{
		Diagnostic.CAST_TO_SMALLER_INT.@emit(p, tok, p.fmt_qt(dest), p.fmt_qt(original))!;
	}
}

<*
 Zig `errValueChanged`: `{s}` is "non-zero " when the converted value is zero, so a
 truncation to zero reads "changes non-zero value". `old_val` has type `src`; the
 converted value (`self.val`) has type `dest`.
*>
macro void? Result.value_changed_err(&self, parser::Parser* p, tokens::TokenIndex tok, Diagnostic $diag, type_store::QualType src, type_store::QualType dest, value::Value old_val)
{
	String zero_str = self.val.is_zero(p.comp) ? "non-zero " : "";
	return $diag.@emit(p, tok, p.fmt_qt(src), p.fmt_qt(dest), zero_str, p.fmt_value(old_val, src), p.fmt_value(self.val, dest));
}

fn void Result.init(&self, type_store::NodeIndex node, type_store::QualType qt, value::Value val = value::NONE)
{
	*self = { .node = node, .qt = qt, .val = val };
}

<*
 Result.checkInvalidUn: an operand of invalid type short-circuits a prefix unary
 operator. The value is dropped and the operand is wrapped in the operator's node
 (qt stays invalid), so later type queries never see the placeholder.
*>
fn bool Result.check_invalid_un(&self, parser::Parser* p, tree::NodeKind kind, tokens::TokenIndex tok)
{
	if (!self.qt.is_invalid()) return false;
	self.val = value::NONE;
	self.node = p.tree.add_node(
		{
			.kind = kind, .unary = { .qt = self.qt, .operand = self.node, .op_tok = tok }
		}
	);
	return true;
}

<* Add an implicit cast node and update the result type, matching Result.implicitCast. *>
fn void Result.implicit_cast(&self, parser::Parser* p, tree::CastKind kind)
{
	tokens::TokenIndex tok = self.node.tok(&p.tree);
	self.node = p.tree.add_node(
		{
			.kind = tree::NodeKind.CAST, .cast = {
				.l_paren = tok,
				.kind = kind,
				.operand = self.node,
				.qt = self.qt,
				.implicit = true,
			}
		}
	);
}

<* Get the pointer constant carried by array/function decay when the node supports it. *>
fn value::Value pointer_value(parser::Parser* p, type_store::NodeIndex node, value::Value offset)
{
	tree::Node n = node.get(&p.tree);
	switch (n.kind)
	{
		case tree::NodeKind.DECL_REF_EXPR:
			// Zig looks up this name as a symbol, but predefined function-name identifiers are
			// not declared symbols. Use the declaration stored on the reference instead (option B:
			// keep the 'not a compile-time constant' check; make values fold instead).
			return value::pointer(
				{
					.node = (uint)n.decl_ref.decl, .offset = offset.ref()
			}
			, p.comp);
		case tree::NodeKind.STRING_LITERAL_EXPR:
			if (try saved = p.tree.value_of(node))
			{
				return saved;
			}
			else
			{
				return value::NONE;
			}
		default: return value::NONE;
	}
}

<* Add a byte offset only when both values fit ptrdiff_t; leave the accumulator unchanged on failure. *>
fn bool add_offset_checked(value::Value* offset_so_far, value::Value delta, compilation::Compilation* comp)
{
	if (offset_so_far.is_none() || delta.is_none() ||
	!offset_so_far.is_int(comp) ||
	!delta.is_int(comp)) return false;
	value::Value updated = value::NONE;
	if (updated.add(*offset_so_far, delta, comp.type_store.ptrdiff, comp)) return false;
	*offset_so_far = updated;
	return true;
}

<* Resolve a saved pointer expression only when its value is a symbolic address. *>
fn value::Value compute_saved_pointer_offset(parser::Parser* p, type_store::NodeIndex node, value::Value offset)
{
	if (offset.is_none() || !offset.is_int(p.comp)) return value::NONE;
	if (try saved = p.tree.value_of(node))
	{
		if (!saved.is(primitive_value::PrimitiveType.POINTER, p.comp)) return value::NONE;
		primitive_value::PrimitiveValue key = p.comp.interner.get(saved.ref());
		value::Value base_offset = value::from_ref(key.pointer.offset);
		value::Value combined = value::NONE;
		if (!base_offset.is_int(p.comp) ||
		combined.add(base_offset, offset, p.comp.type_store.ptrdiff, p.comp)) return value::NONE;
		return value::pointer(
			{
				.node = key.pointer.node, .offset = combined.ref()
		}
		, p.comp);
	}
	return value::NONE;
}

<* Walk supported lvalue paths from a declaration or saved symbolic pointer. *>
fn value::Value compute_offset_extra(parser::Parser* p, type_store::NodeIndex node, value::Value* offset_so_far)
{
	tree::Node n = node.get(&p.tree);
	switch (n.kind)
	{
		case tree::NodeKind.CAST:
			{
				value::Value saved_pointer = compute_saved_pointer_offset(p, node, *offset_so_far);
				if (!saved_pointer.is_none()) return saved_pointer;
				// Array decay preserves the address of the array lvalue. Other casts
				// need a saved symbolic pointer before they can serve as an address base.
				if (n.cast.kind == tree::CastKind.ARRAY_TO_POINTER)
				{
					return compute_offset_extra(p, n.cast.operand, offset_so_far);
				}
				return value::NONE;
			}
		case tree::NodeKind.PAREN_EXPR:
			return compute_offset_extra(p, n.unary.operand, offset_so_far);
		case tree::NodeKind.DECL_REF_EXPR:
			return pointer_value(p, node, *offset_so_far);
		case tree::NodeKind.DEREF_EXPR:
			return compute_saved_pointer_offset(p, n.unary.operand, *offset_so_far);
		case tree::NodeKind.ARRAY_ACCESS_EXPR:
			{
				if (try index_val = p.tree.value_of(n.array_access.index))
				{
					if (!index_val.is_int(p.comp)) return value::NONE;
					if (try elem_size = n.array_access.qt.sizeof_or_null(p.comp))
					{
						value::Value delta = value::NONE;
						if (delta.mul(value::int_u64(elem_size, p.comp), index_val, p.comp.type_store.ptrdiff, p.comp)) return value::NONE;
						if (!add_offset_checked(offset_so_far, delta, p.comp)) return value::NONE;

						type_store::QualType base_qt = n.array_access.base.qt(&p.tree);
						if (base_qt.is_pointer(p.comp))
						{
							tree::Node base = n.array_access.base.get(&p.tree);
							if (base.kind == tree::NodeKind.CAST && base.cast.kind == tree::CastKind.ARRAY_TO_POINTER)
							{
								return compute_offset_extra(p, n.array_access.base, offset_so_far);
							}
							return compute_saved_pointer_offset(p, n.array_access.base, *offset_so_far);
						}
						return compute_offset_extra(p, n.array_access.base, offset_so_far);
					}
				}
				return value::NONE;
			}
		case tree::NodeKind.MEMBER_ACCESS_EXPR:
			{
				type_store::QualType ty = n.member_access.base.qt(&p.tree).non_atomic(p.comp);
				if (try record_ty = ty.get_record(p.comp))
				{
					if (n.member_access.member_index >= record_ty.fields.len) return value::NONE;
					ulong field_offset_bits = record_ty.fields[n.member_access.member_index].layout.offset_bits;
					if (field_offset_bits % 8 != 0) return value::NONE;
					ulong field_offset_bytes = field_offset_bits / 8;
					value::Value field_offset = value::int_u64(field_offset_bytes, p.comp);
					if (!add_offset_checked(offset_so_far, field_offset, p.comp)) return value::NONE;
					return compute_offset_extra(p, n.member_access.base, offset_so_far);
				}
				return value::NONE;
			}
		case tree::NodeKind.MEMBER_ACCESS_PTR_EXPR:
			{
				type_store::QualType ty = n.member_access.base.qt(&p.tree).non_atomic(p.comp);
				if (try pointer = ty.get(p.comp, type_store::TypeTag.POINTER)) ty = pointer.pointer.child;
				ty = ty.non_atomic(p.comp);
				if (try record_ty = ty.get_record(p.comp))
				{
					if (n.member_access.member_index >= record_ty.fields.len) return value::NONE;
					ulong field_offset_bits = record_ty.fields[n.member_access.member_index].layout.offset_bits;
					if (field_offset_bits % 8 != 0) return value::NONE;
					ulong field_offset_bytes = field_offset_bits / 8;
					value::Value field_offset = value::int_u64(field_offset_bytes, p.comp);
					if (!add_offset_checked(offset_so_far, field_offset, p.comp)) return value::NONE;
					return compute_saved_pointer_offset(p, n.member_access.base, *offset_so_far);
				}
				return value::NONE;
			}
		default: return value::NONE;
	}
}

<* Compute a result's symbolic address from its declaration or saved pointer base, if supported. *>
fn value::Value compute_offset(parser::Parser* p, Result res)
{
	// This is an address offset, not the value stored in the lvalue.
	value::Value offset = value::ZERO;
	return compute_offset_extra(p, res.node, &offset);
}

<* Convert an lvalue or decay an array/function designator to a pointer. *>
fn void Result.lval_conversion(&self, parser::Parser* p)
{
	if (self.qt.is_invalid()) return;
	if (self.qt.is(p.comp, type_store::TypeTag.FUNC))
	{
		// Folding a function designator to its symbol pointer makes `f == 0`, `if (f)`, and _Bool
		// conversion constant. An undefined weak function may resolve to null at runtime, so these
		// folds can disagree with the runtime value. Kept as-is for Zig parity.
		self.val = pointer_value(p, self.node, value::ZERO);
		self.qt = self.qt.decay(p.comp);
		self.implicit_cast(p, tree::CastKind.FUNCTION_TO_POINTER);
	}
	else if (self.qt.is(p.comp, type_store::TypeTag.ARRAY))
	{
		self.val = pointer_value(p, self.node, value::ZERO);
		self.qt = self.qt.decay(p.comp);
		self.implicit_cast(p, tree::CastKind.ARRAY_TO_POINTER);
	}
	else if (p.tree.is_lval(self.node))
	{
		self.qt = self.qt.unqualified();
		self.implicit_cast(p, tree::CastKind.LVAL_TO_RVAL);
		self.atomic_to_non_atomic(p);
	}
}

<* Perform lvalue conversion and remove atomic qualification from rvalues. *>
fn void Result.value_conversion(&self, parser::Parser* p)
{
	self.lval_conversion(p);
	self.atomic_to_non_atomic(p);
}

fn void Result.atomic_to_non_atomic(&self, parser::Parser* p)
{
	if (try inner = self.qt.get(p.comp, type_store::TypeTag.ATOMIC))
	{
		self.qt = inner.atomic.unqualified();
		self.implicit_cast(p, tree::CastKind.ATOMIC_TO_NON_ATOMIC);
	}
}

<* Apply C integer promotion and the configured excess-precision evaluation type. *>
fn void? Result.usual_unary_conversion(&self, parser::Parser* p, tokens::TokenIndex tok = 0)
{
	if (self.qt.is_invalid()) return;
	self.atomic_to_non_atomic(p);
	if (self.qt.is_int(p.comp))
	{
		type_store::QualType promoted = self.qt.promote_int(p.comp);
		if (!self.qt.is(p.comp, type_store::TypeTag.BIT_INT))
		{
			if (try width = p.tree.bitfield_width(self.node, true))
			{
				if (try field_promotion = self.qt.promote_bitfield(p.comp, width)) { promoted = field_promotion; }
				else if (p.comp.langopts.emulate == lang_opts::Compiler.GCC && width < self.qt.bit_sizeof(p.comp) && !self.qt.is(p.comp, type_store::TypeTag.BIT_INT))
				{
					type_store::Type precise = type_store::type_bit_int((ushort)width, self.qt.signedness(p.comp));
					precise.bit_int.bitfield_origin = true;
					promoted = p.comp.type_store.put(precise);
				}
			}
		}
		if (!promoted.eql(self.qt, p.comp)) self.cast_to_int(p, promoted, tok)!;
	}
}

fn void? Result.int_conversion_warning(&self, parser::Parser* p, tokens::TokenIndex tok, type_store::QualType src, type_store::QualType dest, value::Value old_val, value::IntCastChangeKind change_kind)
{
	switch (change_kind)
	{
		case value::IntCastChangeKind.TRUNCATED: return self.value_changed_err(p, tok, Diagnostic.INT_VALUE_CHANGED, src, dest, old_val);
		case value::IntCastChangeKind.SIGN_CHANGED:
			{
				return Diagnostic.SIGN_CONVERSION.@emit(p, tok, p.fmt_qt(src), p.fmt_qt(dest));
			}
		case value::IntCastChangeKind.NONE: return;
	}
}

fn void? Result.float_to_int_warning(&self, parser::Parser* p, tokens::TokenIndex tok, type_store::QualType src, type_store::QualType dest, value::Value old_val, value::FloatToIntChangeKind change_kind)
{
	switch (change_kind)
	{
		case value::FloatToIntChangeKind.NONE:
			{
				return Diagnostic.FLOAT_TO_INT.@emit(p, tok, p.fmt_qt(src), p.fmt_qt(dest));
			}
		case value::FloatToIntChangeKind.OUT_OF_RANGE:
			{
				return Diagnostic.FLOAT_OUT_OF_RANGE.@emit(p, tok, p.fmt_qt(src), p.fmt_qt(dest));
			}
		case value::FloatToIntChangeKind.OVERFLOW:
			{
				return Diagnostic.FLOAT_OVERFLOW_CONVERSION.@emit(p, tok, p.fmt_qt(src), p.fmt_qt(dest));
			}
		case value::FloatToIntChangeKind.NONZERO_TO_ZERO: return self.value_changed_err(p, tok, Diagnostic.FLOAT_ZERO_CONVERSION, src, dest, old_val);
		case value::FloatToIntChangeKind.VALUE_CHANGED: return self.value_changed_err(p, tok, Diagnostic.FLOAT_VALUE_CHANGED, src, dest, old_val);
	}
}

<* Value.float_to_int leaves an out-of-range result untruncated (Zig parity,
pinned by the float_to_int vectors). The folded constant must fit its type, so
saturate it to dest's min/max as GCC's fold does (PR 9325,
gcc.c-torture/execute/20031003-1.c). Negative-to-unsigned is already zero. *>
fn void saturate_float_to_int(value::Value* v, type_store::QualType dest, value::FloatToIntChangeKind change_kind, Compilation* comp)
{
	if (change_kind != value::FloatToIntChangeKind.OUT_OF_RANGE || v.is_zero(comp)) return;
	if (!dest.scalar_kind(comp).is_real) return;
	bool negative = value::compare(*v, LT, value::ZERO, comp);
	*v = negative ? value::min_int(dest, comp) : value::max_int(dest, comp);
}

<* Implicit conversions use the clang-style float_to_int_warning set. An explicit
cast is silent except when the constant is out of range: that is undefined
(C23 6.3.1.4p1), and the folded value is the saturated one. *>
fn void? Result.float_to_int_diagnostic(&self, parser::Parser* p, tokens::TokenIndex tok, type_store::QualType src,
	type_store::QualType dest, type_store::QualType folded_qt, value::Value old_val, value::FloatToIntChangeKind change_kind, bool implicit)
{
	if (implicit) return self.float_to_int_warning(p, tok, src, dest, old_val, change_kind);
	if (change_kind != value::FloatToIntChangeKind.OUT_OF_RANGE) return;
	return Diagnostic.FLOAT_CAST_OUT_OF_RANGE.@emit(p, tok, p.fmt_qt(src), p.fmt_qt(dest), p.fmt_value(self.val, folded_qt));
}

fn void? Result.cast_to_int(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex tok = 0, bool implicit = true)
{
	if (self.qt.is_invalid() || self.qt.eql(dest, p.comp)) return;
	type_store::QualType original = self.qt;
	type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
	type_store::ScalarKind dst = dest.scalar_kind(p.comp);
	if (src == type_store::ScalarKind.BOOL)
	{
		self.qt = dest.to_real(p.comp);
		self.implicit_cast(p, tree::CastKind.BOOL_TO_INT);
		if (!dst.is_real)
		{
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
	}
	else if (self.qt.is_float(p.comp))
	{
		value::Value old_val = self.val;
		if (src.is_real && !dst.is_real)
		{
			type_store::QualType real_dest = dest.to_real(p.comp);
			value::FloatToIntChangeKind change_kind = self.val.float_to_int(real_dest, p.comp);
			saturate_float_to_int(&self.val, real_dest, change_kind, p.comp);
			self.float_to_int_diagnostic(p, tok, original, dest, real_dest, old_val, change_kind, implicit)!;
			self.qt = real_dest;
			self.implicit_cast(p, tree::CastKind.FLOAT_TO_INT);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
		else if (!src.is_real && dst.is_real)
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_FLOAT_TO_REAL);
			value::FloatToIntChangeKind change_kind = self.val.float_to_int(dest, p.comp);
			saturate_float_to_int(&self.val, dest, change_kind, p.comp);
			self.float_to_int_diagnostic(p, tok, original, dest, dest, old_val, change_kind, implicit)!;
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.FLOAT_TO_INT);
		}
		else
		{
			value::FloatToIntChangeKind change_kind = self.val.float_to_int(dest, p.comp);
			saturate_float_to_int(&self.val, dest, change_kind, p.comp);
			self.float_to_int_diagnostic(p, tok, original, dest, dest, old_val, change_kind, implicit)!;
			self.qt = dest;
			self.implicit_cast(p, src.is_real ? tree::CastKind.FLOAT_TO_INT : tree::CastKind.COMPLEX_FLOAT_TO_COMPLEX_INT);
		}
	}
	else if (src.is_pointer)
	{
		// Pointer representations are target-defined; Value has no safe
		// pointer-to-integer evaluator, so retain the AST conversion only.
		self.val = value::NONE;
		if (implicit)
		{
			Diagnostic.IMPLICIT_PTR_TO_INT.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
		}
		self.qt = dest.to_real(p.comp);
		self.implicit_cast(p, tree::CastKind.POINTER_TO_INT);
		if (!dst.is_real)
		{
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
	}
	else
	{
		value::Value old_val = self.val;
		type_store::QualType value_dest = dst.is_real ? dest : dest.to_real(p.comp);
		value::IntCastChangeKind change_kind = self.val.int_cast(value_dest, p.comp);
		if (implicit) self.int_conversion_warning(p, tok, original, dest, old_val, change_kind)!;
		if (src.is_real && !dst.is_real)
		{
			type_store::QualType real_dest = dest.to_real(p.comp);
			self.qt = real_dest;
			self.implicit_cast(p, tree::CastKind.INT_CAST);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
		else if (!src.is_real && dst.is_real)
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_INT_TO_REAL);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.INT_CAST);
		}
		else
		{
			self.qt = dest;
			self.implicit_cast(p, src.is_real ? tree::CastKind.INT_CAST : tree::CastKind.COMPLEX_INT_CAST);
		}
	}
}

fn void? Result.cast_to_float(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex tok = 0, bool implicit = true)
{
	if (self.qt.is_invalid() || self.qt.eql(dest, p.comp)) return;
	type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
	type_store::ScalarKind dst = dest.scalar_kind(p.comp);
	if (src == type_store::ScalarKind.BOOL)
	{
		type_store::QualType real_dest = dest.to_real(p.comp);
		self.val.int_to_float(real_dest, p.comp);
		self.qt = real_dest;
		self.implicit_cast(p, tree::CastKind.BOOL_TO_FLOAT);
		if (!dst.is_real)
		{
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_FLOAT);
		}
	}
	else if (src.is_int)
	{
		if (src.is_real && !dst.is_real)
		{
			type_store::QualType real_dest = dest.to_real(p.comp);
			self.val.int_to_float(real_dest, p.comp);
			self.qt = real_dest;
			self.implicit_cast(p, tree::CastKind.INT_TO_FLOAT);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_FLOAT);
		}
		else
		{
			self.val.int_to_float(dest, p.comp);
			self.qt = dest;
			self.implicit_cast(p, !src.is_real && dst.is_real ? tree::CastKind.COMPLEX_INT_TO_REAL :
				(!src.is_real ? tree::CastKind.COMPLEX_INT_TO_COMPLEX_FLOAT : tree::CastKind.INT_TO_FLOAT));
		}
	}
	else if (src.is_real && !dst.is_real)
	{
		type_store::QualType real_dest = dest.to_real(p.comp);
		if (self.qt.float_rank(p.comp) != real_dest.float_rank(p.comp))
		{
			self.val.float_cast(real_dest, p.comp);
			self.qt = real_dest;
			self.implicit_cast(p, tree::CastKind.FLOAT_CAST);
		}
		self.val.float_cast(dest, p.comp);
		self.qt = dest;
		self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_FLOAT);
	}
	else if (!src.is_real && dst.is_real)
	{
		type_store::QualType real_src = self.qt.to_real(p.comp);
		self.qt = real_src;
		self.val = self.val.real_part(p.comp);
		self.implicit_cast(p, tree::CastKind.COMPLEX_FLOAT_TO_REAL);
		if (self.qt.float_rank(p.comp) != dest.float_rank(p.comp))
		{
			self.val.float_cast(dest, p.comp);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.FLOAT_CAST);
		}
	}
	else
	{
		self.val.float_cast(dest, p.comp);
		self.qt = dest;
		self.implicit_cast(p, !src.is_real ? tree::CastKind.COMPLEX_FLOAT_CAST : tree::CastKind.FLOAT_CAST);
	}
}

<* C 6.6p6 integer constant expression, judged from the AST: integer, character
   and enumeration constants, sizeof/_Alignof, and unary, binary and conditional
   operators over them; casts only to integer types, and a floating constant only
   as the immediate operand of such a cast. A folded value alone is not enough:
   `static const int ZERO` reads an object, and `(int)+0.0` folds but is not an ICE
   (gcc.dg/c90-const-expr-3.c). *>
fn bool is_integer_constant_expr(parser::Parser* p, type_store::NodeIndex index, bool float_ok = false)
{
	tree::Node n = index.get(&p.tree);
	switch (n.kind)
	{
		case INT_LITERAL:
		case CHAR_LITERAL:
		case BOOL_LITERAL:
		case ENUMERATION_REF:
		case ALIGNOF_EXPR:
			return true;
		case SIZEOF_EXPR:
			// sizeof a variable length array is evaluated at run time.
			return @ok(n.type_info.operand_qt.sizeof_or_null(p.comp));
		case FLOAT_LITERAL:
			return float_ok;
		case PAREN_EXPR:
			return is_integer_constant_expr(p, n.unary.operand, float_ok);
		case PLUS_EXPR:
		case NEGATE_EXPR:
		case BIT_NOT_EXPR:
		case BOOL_NOT_EXPR:
			return is_integer_constant_expr(p, n.unary.operand);
		case BOOL_OR_EXPR:
		case BOOL_AND_EXPR:
		case BIT_OR_EXPR:
		case BIT_XOR_EXPR:
		case BIT_AND_EXPR:
		case EQUAL_EXPR:
		case NOT_EQUAL_EXPR:
		case LESS_THAN_EXPR:
		case LESS_THAN_EQUAL_EXPR:
		case GREATER_THAN_EXPR:
		case GREATER_THAN_EQUAL_EXPR:
		case SHL_EXPR:
		case SHR_EXPR:
		case ADD_EXPR:
		case SUB_EXPR:
		case MUL_EXPR:
		case DIV_EXPR:
		case MOD_EXPR:
			return is_integer_constant_expr(p, n.binary.lhs) && is_integer_constant_expr(p, n.binary.rhs);
		case COND_EXPR:
			if (!is_integer_constant_expr(p, n.conditional.cond)) return false;
			// C99 6.6p3: operators like `,` are allowed in an arm that is not
			// evaluated (gcc.dg/c99-const-expr-2.c); C90 requires both arms.
			if (p.comp.langopts.standard.at_least(C99))
			{
				if (try cond = p.tree.value_of(n.conditional.cond))
				{
					return is_integer_constant_expr(p, cond.to_bool(p.comp) ? n.conditional.then_expr: n.conditional.else_expr);
				}
			}
			return is_integer_constant_expr(p, n.conditional.then_expr) &&
			is_integer_constant_expr(p, n.conditional.else_expr);
		case CAST:
			if (n.cast.kind == tree::CastKind.LVAL_TO_RVAL || !n.cast.qt.is_int(p.comp)) return false;
			// An explicit cast to an integer type may take a floating constant
			// directly; implicit conversions under it keep that permission.
			return is_integer_constant_expr(p, n.cast.operand, n.cast.implicit ? float_ok: true);
		default:
			return false;
	}
}

<* C 6.3.2.3p3: an integer constant expression with value 0, or such an
   expression cast to `void *` (unqualified void). *>
fn bool Result.is_null_pointer_constant(&self, parser::Parser* p)
{
	if (self.val.is_none()) return false;
	if (self.qt.is_int(p.comp)) return self.val.is_zero(p.comp);
	if (!self.qt.is_pointer(p.comp)) return false;
	type_store::QualType child = self.qt.child_type(p.comp);
	if (!child.is(p.comp, type_store::TypeTag.VOID) || child.is_const || child.is_volatile || child.is_restrict) return false;
	if (self.val.opt_ref != value::NULL.opt_ref && !self.val.is_zero(p.comp)) return false;
	// Only an integer constant expression cast directly to `void *`: not
	// `(void *)(void *)0` or `(void *)(char *)0` (gcc.dg/c90-const-expr-2.c).
	tree::Node n = self.node.get(&p.tree);
	while (n.kind == tree::NodeKind.PAREN_EXPR) n = n.unary.operand.get(&p.tree);
	if (n.kind != tree::NodeKind.CAST || n.cast.implicit) return false;
	type_store::NodeIndex inner = n.cast.operand;
	while (true)
	{
		tree::Node in = inner.get(&p.tree);
		if (in.kind != tree::NodeKind.CAST || !in.cast.implicit || in.cast.qt.is_int(p.comp)) break;
		inner = in.cast.operand;
	}
	return inner.qt(&p.tree).is_int(p.comp) && is_integer_constant_expr(p, inner);
}

fn void Result.null_to_pointer(&self, parser::Parser* p, type_store::QualType dest)
{
	if (!self.qt.is(p.comp, type_store::TypeTag.NULLPTR_T) && !self.val.is_zero(p.comp)) return;
	self.val = value::NULL;
	self.qt = dest;
	self.implicit_cast(p, tree::CastKind.NULL_TO_POINTER);
}

<* Convert a scalar integer, bool, nullptr or pointer to a pointer type. *>
fn void? Result.cast_to_pointer(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex tok = 0, bool implicit = true, CoercionContext context = CoercionContext.EXPRESSION)
{
	type_store::QualType original = self.qt;
	type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
	if (src == type_store::ScalarKind.BOOL)
	{
		self.qt = dest;
		self.implicit_cast(p, tree::CastKind.BOOL_TO_POINTER);
	}
	else if (src.is_int && self.val.is_zero(p.comp) && is_integer_constant_expr(p, self.node))
	{
		// A zero integer constant converts to the null pointer (Zig/clang keep the
		// value), so `(void *)0` stays a null pointer constant (C 6.3.2.3p3).
		self.null_to_pointer(p, dest);
	}
	else if (src.is_int)
	{
		if (implicit)
		{
			Diagnostic.IMPLICIT_INT_TO_PTR.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
		}
		// Keep the folded integer on its operand so static-initializer checks can
		// recognize the address constant. The pointer result itself stays unknown:
		// its representation depends on the target.
		self.save_value(p);
		self.qt = dest;
		self.implicit_cast(p, tree::CastKind.INT_TO_POINTER);
	}
	else if (src == type_store::ScalarKind.NULLPTR_T)
	{
		self.null_to_pointer(p, dest);
	}
	else if (src.is_pointer && !self.qt.eql(dest, p.comp))
	{
		type_store::QualType from_child = self.qt.child_type(p.comp);
		type_store::QualType to_child = dest.child_type(p.comp);
		if (implicit && !from_child.is(p.comp, type_store::TypeTag.VOID) && !to_child.is(p.comp, type_store::TypeTag.VOID))
		{
			bool discards_qualifiers = (from_child.is_const && !to_child.is_const) ||
			(from_child.is_volatile && !to_child.is_volatile) ||
			(from_child.is_restrict && !to_child.is_restrict);
			if (from_child.eql(to_child, p.comp) && discards_qualifiers)
			{
				switch (context)
				{
					case INITIALIZATION:
						Diagnostic.PTR_INIT_DISCARDS_QUALS.@emit(p, tok, p.fmt_qt(dest), p.fmt_qt(original))!;
					case ASSIGNMENT:
					case EXPRESSION:
						Diagnostic.PTR_ASSIGN_DISCARDS_QUALS.@emit(p, tok, p.fmt_qt(dest), p.fmt_qt(original))!;
					case RETURN:
						Diagnostic.PTR_RET_DISCARDS_QUALS.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
					case ARGUMENT:
						Diagnostic.PTR_ARG_DISCARDS_QUALS.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
				}
			}
			else if (!from_child.eql(to_child, p.comp))
			{
				bool sign_only = from_child.same_rank_different_sign(to_child, p.comp);
				switch (context)
				{
					case INITIALIZATION:
						if (sign_only)
						{
							Diagnostic.INCOMPATIBLE_PTR_INIT_SIGN.@emit(p, tok, p.fmt_qt(dest), p.fmt_qt(original))!;
						}
						else
						{
							Diagnostic.INCOMPATIBLE_PTR_INIT.@emit(p, tok, p.fmt_qt(dest), p.fmt_qt(original))!;
						}
					case ASSIGNMENT:
					case EXPRESSION:
						if (sign_only)
						{
							Diagnostic.INCOMPATIBLE_PTR_ASSIGN_SIGN.@emit(p, tok, p.fmt_qt(dest), p.fmt_qt(original))!;
						}
						else
						{
							Diagnostic.INCOMPATIBLE_PTR_ASSIGN.@emit(p, tok, p.fmt_qt(dest), p.fmt_qt(original))!;
						}
					case RETURN:
						if (sign_only)
						{
							Diagnostic.INCOMPATIBLE_RETURN_SIGN.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
						}
						else
						{
							Diagnostic.INCOMPATIBLE_RETURN.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
						}
					case ARGUMENT:
						if (sign_only)
						{
							Diagnostic.INCOMPATIBLE_PTR_ARG_SIGN.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
						}
						else
						{
							Diagnostic.INCOMPATIBLE_PTR_ARG.@emit(p, tok, p.fmt_qt(original), p.fmt_qt(dest))!;
						}
				}
			}
		}
		self.qt = dest;
		bool adds_qualifiers = (!from_child.is_const || to_child.is_const) &&
		(!from_child.is_volatile || to_child.is_volatile) &&
		(!from_child.is_restrict || to_child.is_restrict);
		self.implicit_cast(p, from_child.eql(to_child, p.comp) && adds_qualifiers ? tree::CastKind.NO_OP : tree::CastKind.BITCAST);
	}
}

<* Convert an integer, floating, pointer or array value to bool. *>
fn void? Result.cast_to_bool(&self, parser::Parser* p, tokens::TokenIndex tok = 0, bool implicit = true)
{
	type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
	if (src == type_store::ScalarKind.BOOL) return;
	if (src.is_pointer)
	{
		self.val.bool_cast(p.comp);
		self.qt = type_store::BOOL;
		self.implicit_cast(p, tree::CastKind.POINTER_TO_BOOL);
	}
	else if (src.is_int)
	{
		self.val.bool_cast(p.comp);
		if (!src.is_real)
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_INT_TO_REAL);
		}
		self.qt = type_store::BOOL;
		self.implicit_cast(p, tree::CastKind.INT_TO_BOOL);
	}
	else if (src.is_float)
	{
		if (!src.is_real)
		{
			// A complex value is true when either component is nonzero. The
			// float-to-int evaluator intentionally converts only its real part.
			self.val.bool_cast(p.comp);
		}
		else
		{
			value::Value old_val = self.val;
			value::FloatToIntChangeKind change_kind = self.val.float_to_int(type_store::BOOL, p.comp);
			if (implicit) self.float_to_int_warning(p, tok, self.qt, type_store::BOOL, old_val, change_kind)!;
		}
		if (!src.is_real)
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_FLOAT_TO_REAL);
		}
		self.qt = type_store::BOOL;
		self.implicit_cast(p, tree::CastKind.FLOAT_TO_BOOL);
	}
}

<* Assignment-style scalar/vector coercion. Returns false when no supported conversion exists. *>
fn bool? Result.coerce_scalar(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex tok = 0, CoercionContext context = CoercionContext.EXPRESSION)
{
	// Zig Result.coerce: an invalid destination makes the result invalid.
	if (dest.is_invalid())
	{
		self.qt = type_store::INVALID;
		return true;
	}
	// Coercing into an _Atomic object converts to its unqualified value type.
	if (try atomic_dest = dest.get(p.comp, type_store::TypeTag.ATOMIC)) dest = atomic_dest.atomic.unqualified();
	self.lval_conversion(p);
	if (self.qt.is_invalid()) return true;
	self.atomic_to_non_atomic(p);
	type_store::Type? dest_vec = dest.get(p.comp, type_store::TypeTag.VECTOR);
	type_store::Type? src_vec = self.qt.get(p.comp, type_store::TypeTag.VECTOR);
	if (try dv = dest_vec)
	{
		if (try sv = src_vec)
		{
			if (self.qt.eql(dest, p.comp)) return true;
			if (dest.size_compare(self.qt, p.comp) == type_store::TypeSizeOrder.EQ)
			{
				self.qt = dest;
				self.implicit_cast(p, tree::CastKind.BITCAST);
				return true;
			}
			return false;
		}
		type_store::QualType elem = dv.vector.elem;
		if (!(self.coerce_scalar(p, elem, tok, context)!)) return false;
		self.save_value(p);
		self.qt = dest.unqualified();
		self.implicit_cast(p, tree::CastKind.VECTOR_SPLAT);
		return true;
	}
	type_store::ScalarKind dst = dest.scalar_kind(p.comp);
	type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
	if (dst == type_store::ScalarKind.BOOL && src != type_store::ScalarKind.NONE && src != type_store::ScalarKind.NULLPTR_T)
	{
		self.cast_to_bool(p, tok)!;
		return true;
	}
	if (dst.is_int && (src.is_int || src.is_float))
	{
		self.cast_to_int(p, dest.unqualified(), tok)!;
		return true;
	}
	if (dst.is_int && src.is_pointer && src != type_store::ScalarKind.BLOCK_POINTER)
	{
		self.cast_to_int(p, dest.unqualified(), tok)!;
		return true;
	}
	if (dst.is_float && (src.is_int || src.is_float))
	{
		self.cast_to_float(p, dest.unqualified(), tok)!;
		return true;
	}
	if (dst.is_pointer && (src == type_store::ScalarKind.NULLPTR_T || self.val.is_zero(p.comp)))
	{
		self.null_to_pointer(p, dest.unqualified());
		return true;
	}
	if (dst.is_pointer && src.is_int)
	{
		self.cast_to_pointer(p, dest.unqualified(), tok, true, context)!;
		return true;
	}
	if (dst.is_pointer && src.is_pointer)
	{
		self.cast_to_pointer(p, dest.unqualified(), tok, true, context)!;
		return true;
	}
	return dest.eql(self.qt, p.comp);
}

<* Apply a supported explicit scalar or equal-size vector cast. *>
fn bool? Result.explicit_cast(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex l_paren)
{
	// An invalid operand or type name was already diagnosed; no "invalid cast" follow-up.
	if (self.qt.is_invalid() || dest.is_invalid())
	{
		self.qt = type_store::INVALID;
		self.val = value::NONE;
		return true;
	}
	self.value_conversion(p);
	self.atomic_to_non_atomic(p);
	type_store::QualType original = self.qt;
	if (dest.is(p.comp, type_store::TypeTag.VOID))
	{
		self.explicit_cast_warnings(p, l_paren, dest, original)!;
		self.val = value::NONE;
		self.qt = dest;
		self.node = p.tree.add_node(
			{
				.kind = tree::NodeKind.CAST, .cast = {
					.l_paren = l_paren, .kind = tree::CastKind.TO_VOID, .operand = self.node,
					.qt = dest, .implicit = false,
				}
			}
		);
		return true;
	}
	if (dest.has_incomplete_size(p.comp))
	{
		Diagnostic.CAST_TO_INCOMPLETE_TYPE.@emit(p, l_paren, p.fmt_qt(dest))!;
		self.qt = type_store::INVALID;
		self.val = value::NONE;
		return true;
	}
	type_store::Type? dst_vec = dest.get(p.comp, type_store::TypeTag.VECTOR);
	type_store::Type? src_vec = self.qt.get(p.comp, type_store::TypeTag.VECTOR);
	if (try dv = dst_vec)
	{
		if (try sv = src_vec)
		{
			if (dest.size_compare(self.qt, p.comp) != type_store::TypeSizeOrder.EQ) return false;
			self.explicit_cast_warnings(p, l_paren, dest, original)!;
			self.val = value::NONE;
			self.qt = dest.unqualified();
			self.node = p.tree.add_node(
				{
					.kind = tree::NodeKind.CAST, .cast = {
						.l_paren = l_paren, .kind = tree::CastKind.BITCAST, .operand = self.node,
						.qt = self.qt, .implicit = false,
					}
				}
			);
			return true;
		}
		if (!self.qt.is_int(p.comp) || dest.size_compare(self.qt, p.comp) != type_store::TypeSizeOrder.EQ) return false;
		self.val = value::NONE;
		self.qt = dest.unqualified();
	}
	else
	{
		if (try sv = src_vec)
		{
			if (!dest.is_int(p.comp) || dest.size_compare(self.qt, p.comp) != type_store::TypeSizeOrder.EQ) return false;
			self.explicit_cast_warnings(p, l_paren, dest, original)!;
			self.val = value::NONE;
			self.qt = dest.unqualified();
			self.node = p.tree.add_node(
				{
					.kind = tree::NodeKind.CAST, .cast = {
						.l_paren = l_paren, .kind = tree::CastKind.BITCAST, .operand = self.node,
						.qt = self.qt, .implicit = false,
					}
				}
			);
			return true;
		}
		type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
		type_store::ScalarKind dst = dest.scalar_kind(p.comp);
		if (dst == type_store::ScalarKind.BOOL)
		{
			self.cast_to_bool(p, l_paren, false)!;
		}
		else if (dst.is_int && (src.is_int || src.is_float || src.is_pointer))
		{
			self.cast_to_int(p, dest.unqualified(), l_paren, false)!;
		}
		else if (dst.is_float && (src.is_int || src.is_float))
		{
			self.cast_to_float(p, dest.unqualified(), l_paren, false)!;
		}
		else if (dst.is_pointer && (src.is_int || src.is_pointer || src == type_store::ScalarKind.NULLPTR_T))
		{
			if (src.is_int && !src.is_real) return false;
			self.cast_to_pointer(p, dest.unqualified(), l_paren, false)!;
		}
		else
		{
			return false;
		}
	}
	self.explicit_cast_warnings(p, l_paren, dest, original)!;
	self.node = p.tree.add_node(
		{
			.kind = tree::NodeKind.CAST, .cast = {
				.l_paren = l_paren, .kind = tree::CastKind.NO_OP, .operand = self.node,
				.qt = self.qt, .implicit = false,
			}
		}
	);
	return true;
}

<* C usual arithmetic conversions for integer and floating scalar operands. *>
fn void? Result.usual_arithmetic_conversion(&self, Result* rhs, parser::Parser* p, tokens::TokenIndex tok = 0)
{
	self.usual_unary_conversion(p, tok)!;
	rhs.usual_unary_conversion(p, tok)!;
	type_store::Type? a_vec = self.qt.get(p.comp, type_store::TypeTag.VECTOR);
	type_store::Type? b_vec = rhs.qt.get(p.comp, type_store::TypeTag.VECTOR);
	if (try av = a_vec)
	{
		if (try bv = b_vec)
		{
			if (av.vector.eql(bv.vector, p.comp, true)) return;
			if (self.qt.size_compare(rhs.qt, p.comp) == type_store::TypeSizeOrder.EQ)
			{
				rhs.qt = self.qt;
				rhs.implicit_cast(p, tree::CastKind.BITCAST);
				return;
			}
			self.qt = type_store::INVALID;
			self.val = value::NONE;
			rhs.val = value::NONE;
			return;
		}
		if (rhs.coerce_scalar(p, self.qt, tok, CoercionContext.EXPRESSION)!) return;
		self.qt = type_store::INVALID;
		self.val = value::NONE;
		rhs.val = value::NONE;
		return;
	}
	if (try bv = b_vec)
	{
		assert(bv.tag == type_store::TypeTag.VECTOR);
		if (self.coerce_scalar(p, rhs.qt, tok, CoercionContext.EXPRESSION)!) return;
		self.qt = type_store::INVALID;
		self.val = value::NONE;
		rhs.val = value::NONE;
		return;
	}
	bool af = self.qt.is_float(p.comp);
	bool bf = rhs.qt.is_float(p.comp);
	if (af && bf)
	{
		type_store::QualType target = self.qt.float_rank(p.comp) >= rhs.qt.float_rank(p.comp) ? self.qt : rhs.qt;
		if (self.qt.is(p.comp, type_store::TypeTag.COMPLEX) || rhs.qt.is(p.comp, type_store::TypeTag.COMPLEX)) target = target.to_complex(p.comp);
		self.cast_to_float(p, target, tok)!;
		rhs.cast_to_float(p, target, tok)!;
		return;
	}
	if (af)
	{
		rhs.cast_to_float(p, self.qt, tok)!; return;
	}
	if (bf)
	{
		self.cast_to_float(p, rhs.qt, tok)!; return;
	}
	if (!self.qt.is_int(p.comp) || !rhs.qt.is_int(p.comp)) return;
	type_store::QualType a = self.qt.to_real(p.comp);
	type_store::QualType b = rhs.qt.to_real(p.comp);
	type_store::Order order = self.qt.int_rank_order(rhs.qt, p.comp);
	bool as = self.qt.signedness(p.comp) == lang_opts::Signedness.SIGNED;
	bool bs = rhs.qt.signedness(p.comp) == lang_opts::Signedness.SIGNED;
	type_store::QualType target;
	if (as == bs)
	{
		target = order == type_store::Order.LT ? b : a;
	}
	else if (order != (as ? type_store::Order.GT : type_store::Order.LT))
	{
		target = bs ? a : b;
	}
	else if (a.bit_sizeof(p.comp) != b.bit_sizeof(p.comp))
	{
		target = as ? a : b;
	}
	else
	{
		target = as ? a.make_int_unsigned(p.comp) : b.make_int_unsigned(p.comp);
	}
	if (self.qt.is(p.comp, type_store::TypeTag.COMPLEX) || rhs.qt.is(p.comp, type_store::TypeTag.COMPLEX))
	{
		target = target.to_complex(p.comp);
		self.save_value(p);
		rhs.save_value(p);
	}
	self.cast_to_int(p, target, tok)!;
	rhs.cast_to_int(p, target, tok)!;
}

<* Store a known value on its AST node and mark the result unavailable. *>
fn void Result.save_value(&self, parser::Parser* p)
{
	if (!self.val.is_none() && self.val.opt_ref != value_interner::OPT_NULL)
	{
		p.tree.set_value(self.node, self.val);
	}
	self.val = value::NONE;
}

<* Restore a saved expression value when the initializer must keep it available
   to constexpr or const-declaration processing. *>
fn void Result.restore_saved_value(&self, parser::Parser* p)
{
	if (try saved = p.tree.value_of(self.node)) self.val = saved;
}

<* `first_missing_value`: every initializer expression has a saved value. *>
excuse NO_MISSING_VALUE;

<* Token of the first initializer expression without a saved value, or
   NO_MISSING_VALUE. Omitted aggregate elements are zero and never missing. *>
fn tokens::TokenIndex? first_missing_value(parser::Parser* p, type_store::NodeIndex node_index)
{
	tree::Node node = node_index.get(&p.tree);
	switch (node.kind)
	{
		case tree::NodeKind.ARRAY_INIT_EXPR:
		case tree::NodeKind.STRUCT_INIT_EXPR:
			{
				foreach (item : node.container_init.items)
				{
					if (try tok = first_missing_value(p, item)) return tok;
				}
				return NO_MISSING_VALUE~;
			}
		case tree::NodeKind.UNION_INIT_EXPR:
			if (node.union_init.initializer.is_null()) return NO_MISSING_VALUE~;
			return first_missing_value(p, node.union_init.initializer.unwrap());
		case tree::NodeKind.DEFAULT_INIT_EXPR:
		case tree::NodeKind.ARRAY_FILLER_EXPR:
		case tree::NodeKind.STRING_LITERAL_EXPR:
		case tree::NodeKind.NULLPTR_LITERAL:
			return NO_MISSING_VALUE~;
		case tree::NodeKind.CAST:
			// NULL is represented by a dedicated interner sentinel and save_value
			// intentionally does not put it in the tree's ordinary value map.
			if (node.cast.kind == tree::CastKind.NULL_TO_POINTER) return NO_MISSING_VALUE~;
			if (try saved = p.tree.value_of(node_index))
			{
				if (!saved.is_none()) return NO_MISSING_VALUE~;
			}
			return first_missing_value(p, node.cast.operand);
		case tree::NodeKind.PAREN_EXPR:
			// Parentheses are transparent: `(void *)(2)` (sqlite SQLITE_INT_TO_PTR).
			if (try saved = p.tree.value_of(node_index))
			{
				if (!saved.is_none()) return NO_MISSING_VALUE~;
			}
			return first_missing_value(p, node.unary.operand);
		default:
			if (try saved = p.tree.value_of(node_index))
			{
				if (!saved.is_none()) return NO_MISSING_VALUE~;
			}
			return node_index.tok(&p.tree);
	}
}

<* Require a saved constant for constexpr and static-duration initializers.
   The runtime context accepts expressions whose value is unavailable. *>
fn bool? Result.require_initializer_value(&self, parser::Parser* p, parser::InitContext context,
	tokens::TokenIndex tok)
{
	if (context == parser::InitContext.RUNTIME || !self.val.is_none()) return true;
	tokens::TokenIndex? missing_tok = first_missing_value(p, self.node);
	if (catch missing_tok) return true;
	// The top-level token is a fallback for synthetic nodes without a usable
	// token index; ordinary aggregate failures point at the first missing child.
	tokens::TokenIndex diagnostic_tok = (usz)missing_tok < p.tree.tokens.len ? missing_tok : tok;
	switch (context)
	{
		case RUNTIME: return true;
		case CONSTEXPR:
			Diagnostic.NON_CONSTANT_INITIALIZER.@emit(p, diagnostic_tok)!;
		case STATIC:
			Diagnostic.STATIC_NON_CONSTANT_INITIALIZER.@emit(p, diagnostic_tok)!;
	}
	return false;
}
