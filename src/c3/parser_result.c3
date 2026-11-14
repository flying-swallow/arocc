// Core expression-result conversions from Parser.zig's Result.
// Diagnostics and the full parser grammar are intentionally owned by the
// parser layer; these helpers preserve the typed AST and constant value.
module aro::parser_result;
import aro::parser, aro::tree, aro::type_store, aro::value, aro::value_interner, aro::tokens, aro::parser_diagnostics, aro::float_value;
import aro::compilation;
import aro::lang_opts;
import aro::attribute, aro::builtins;
import std::core::dstring;

struct Result
{
	type_store::NodeIndex node;
	type_store::QualType qt;
	value::Value val;
}

<* Append an attribute message using Zig's stringEscape formatting. *>
fn void append_escaped(DString* buf, String text)
{
	foreach (c : text)
	{
		switch (c)
		{
			case '\n': buf.append_string("\\n");
			case '\r': buf.append_string("\\r");
			case '\t': buf.append_string("\\t");
			case '\\': buf.append_string("\\\\");
			case '"': buf.append_string("\\\"");
			default:
				if (c >= ' ' && c <= '~') { buf.append_char(c); }
				else { buf.appendf("\\x%02x", c); }
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
			case tree::NodeKind.ASSIGN_EXPR: case tree::NodeKind.MUL_ASSIGN_EXPR:
			case tree::NodeKind.DIV_ASSIGN_EXPR: case tree::NodeKind.MOD_ASSIGN_EXPR:
			case tree::NodeKind.ADD_ASSIGN_EXPR: case tree::NodeKind.SUB_ASSIGN_EXPR:
			case tree::NodeKind.SHL_ASSIGN_EXPR: case tree::NodeKind.SHR_ASSIGN_EXPR:
			case tree::NodeKind.BIT_AND_ASSIGN_EXPR: case tree::NodeKind.BIT_XOR_ASSIGN_EXPR:
			case tree::NodeKind.BIT_OR_ASSIGN_EXPR: case tree::NodeKind.PRE_INC_EXPR:
			case tree::NodeKind.PRE_DEC_EXPR: case tree::NodeKind.POST_INC_EXPR:
			case tree::NodeKind.POST_DEC_EXPR:
				return;
			case tree::NodeKind.EQUAL_EXPR:
				return p.emit_parser_diag(parser_diagnostics::ParserDiag.UNUSED_COMPARISON, "equality comparison result unused", cur_node.tok(&p.tree));
			case tree::NodeKind.NOT_EQUAL_EXPR:
				return p.emit_parser_diag(parser_diagnostics::ParserDiag.UNUSED_COMPARISON, "inequality comparison result unused", cur_node.tok(&p.tree));
			case tree::NodeKind.LESS_THAN_EXPR: case tree::NodeKind.LESS_THAN_EQUAL_EXPR:
			case tree::NodeKind.GREATER_THAN_EXPR: case tree::NodeKind.GREATER_THAN_EQUAL_EXPR:
				return p.emit_parser_diag(parser_diagnostics::ParserDiag.UNUSED_COMPARISON, "relational comparison result unused", cur_node.tok(&p.tree));
			case tree::NodeKind.CALL_EXPR:
			{
				tree::CalledFunctionAttr? maybe_info = p.tree.called_function_attr(cur.call.callee, attribute::AttributeTag.WARN_UNUSED_RESULT);
				if (!@ok(maybe_info)) return;
				tree::CalledFunctionAttr info = maybe_info!;
				if (!info.has_attr) return;
				attribute::Attribute attr = info.attr;
				String attr_name = attr.name.name();
				DString message;
				message.init(tmem);
				message.appendf("ignoring return value of '%s', declared with '", p.tree.tok_slice(info.tok));
				if (attr.syntax == attribute::AttributeSyntax.STANDARD && attr.name.ns != attribute::AttrNamespace.STANDARD)
				{
					message.append_string(attr.name.ns.name);
					message.append_string("::");
				}
				message.append_string(attr_name);
				message.append_char('\'');
				message.append_string(" attribute");
				if (attr.args.warn_unused_result.has_msg)
				{
					message.append_string(": ");
					append_escaped(&message, attr.args.warn_unused_result.msg);
				}
				return p.emit_parser_diag(parser_diagnostics::ParserDiag.WARN_UNUSED_RESULT, message.str_view(), cur.call.callee.tok(&p.tree));
			}
			case tree::NodeKind.BUILTIN_CALL_EXPR:
			{
				String name = p.tree.tok_slice(cur.builtin_call.builtin_tok);
				builtins::Expanded builtin = p.comp.builtins.lookup(name);
				if (builtin.attributes.pure)
				{
					p.emit_parser_diag(parser_diagnostics::ParserDiag.BUILTIN_UNUSED,
						"ignoring return value of function declared with 'pure' attribute", cur.builtin_call.builtin_tok)!;
				}
				if (builtin.attributes.is_const)
				{
					p.emit_parser_diag(parser_diagnostics::ParserDiag.BUILTIN_UNUSED,
						"ignoring return value of function declared with 'const' attribute", cur.builtin_call.builtin_tok)!;
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
				return p.emit_parser_diag(parser_diagnostics::ParserDiag.UNUSED_VALUE, "expression result unused", cur_node.tok(&p.tree));
		}
	}
}

<* Report a Result conversion diagnostic at `tok` through `Parser.err`, which formats the args. *>
macro void? Result.conversion_err(&self, parser::Parser* p, tokens::TokenIndex tok, parser_diagnostics::ParserDiag $diag, ...)
{
	return p.err($diag, tok, ...$vaarg);
}

fn void? Result.explicit_cast_warnings(&self, parser::Parser* p, tokens::TokenIndex tok, type_store::QualType dest, type_store::QualType original)
{
	if (dest.is_qualified())
	{
		self.conversion_err(p, tok, parser_diagnostics::ParserDiag.QUAL_CAST, p.fmt_qt(dest))!;
	}
	if (dest.is_int(p.comp) && original.is_pointer(p.comp) && dest.size_compare(original, p.comp) == type_store::TypeSizeOrder.LT)
	{
		self.conversion_err(p, tok, parser_diagnostics::ParserDiag.CAST_TO_SMALLER_INT, p.fmt_qt(dest), p.fmt_qt(original))!;
	}
}

<*
 Zig `errValueChanged`: `{s}` is "non-zero " when the converted value is zero, so a
 truncation to zero reads "changes non-zero value". `old_val` has type `src`; the
 converted value (`self.val`) has type `dest`.
*>
macro void? Result.value_changed_err(&self, parser::Parser* p, tokens::TokenIndex tok, parser_diagnostics::ParserDiag $diag, type_store::QualType src, type_store::QualType dest, value::Value old_val)
{
	String zero_str = self.val.is_zero(p.comp) ? "non-zero " : "";
	return p.err($diag, tok, p.fmt_qt(src), p.fmt_qt(dest), zero_str, p.fmt_value(old_val, src), p.fmt_value(self.val, dest));
}

fn void Result.init(&self, type_store::NodeIndex node, type_store::QualType qt, value::Value val = value::NONE)
{
	*self = { .node = node, .qt = qt, .val = val };
}

<* Add an implicit cast node and update the result type, matching Result.implicitCast. *>
fn void Result.implicit_cast(&self, parser::Parser* p, tree::CastKind kind)
{
	tokens::TokenIndex tok = self.node.tok(&p.tree);
	self.node = p.tree.add_node({ .kind = tree::NodeKind.CAST, .cast = {
		.l_paren = tok,
		.kind = kind,
		.operand = self.node,
		.qt = self.qt,
		.implicit = true,
	} });
}

<* Convert an lvalue or decay an array/function designator to a pointer. *>
fn void Result.lval_conversion(&self, parser::Parser* p)
{
	if (self.qt.is_invalid()) return;
	if (self.qt.is(p.comp, type_store::TypeTag.FUNC))
	{
		self.qt = self.qt.decay(p.comp);
		self.implicit_cast(p, tree::CastKind.FUNCTION_TO_POINTER);
	}
	else if (self.qt.is(p.comp, type_store::TypeTag.ARRAY))
	{
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
		if (!promoted.eql(self.qt, p.comp)) self.cast_to_int(p, promoted, tok)!;
	}
}

fn void? Result.int_conversion_warning(&self, parser::Parser* p, tokens::TokenIndex tok, type_store::QualType src, type_store::QualType dest, value::Value old_val, value::IntCastChangeKind change_kind)
{
	switch (change_kind)
	{
		case value::IntCastChangeKind.TRUNCATED: return self.value_changed_err(p, tok, parser_diagnostics::ParserDiag.INT_VALUE_CHANGED, src, dest, old_val);
		case value::IntCastChangeKind.SIGN_CHANGED:
		{
			return self.conversion_err(p, tok, parser_diagnostics::ParserDiag.SIGN_CONVERSION, p.fmt_qt(src), p.fmt_qt(dest));
		}
		case value::IntCastChangeKind.NONE: return;
	}
}

fn void? Result.float_to_int_warning(&self, parser::Parser* p, tokens::TokenIndex tok, type_store::QualType src, type_store::QualType dest, value::Value old_val, float_value::FloatToIntChangeKind change_kind)
{
	switch (change_kind)
	{
		case float_value::FloatToIntChangeKind.NONE:
		{
			return self.conversion_err(p, tok, parser_diagnostics::ParserDiag.FLOAT_TO_INT, p.fmt_qt(src), p.fmt_qt(dest));
		}
		case float_value::FloatToIntChangeKind.OUT_OF_RANGE:
		{
			return self.conversion_err(p, tok, parser_diagnostics::ParserDiag.FLOAT_OUT_OF_RANGE, p.fmt_qt(src), p.fmt_qt(dest));
		}
		case float_value::FloatToIntChangeKind.OVERFLOW:
		{
			return self.conversion_err(p, tok, parser_diagnostics::ParserDiag.FLOAT_OVERFLOW_CONVERSION, p.fmt_qt(src), p.fmt_qt(dest));
		}
		case float_value::FloatToIntChangeKind.NONZERO_TO_ZERO: return self.value_changed_err(p, tok, parser_diagnostics::ParserDiag.FLOAT_ZERO_CONVERSION, src, dest, old_val);
		case float_value::FloatToIntChangeKind.VALUE_CHANGED: return self.value_changed_err(p, tok, parser_diagnostics::ParserDiag.FLOAT_VALUE_CHANGED, src, dest, old_val);
	}
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
		if (!dst.is_real())
		{
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
	}
	else if (self.qt.is_float(p.comp))
	{
		value::Value old_val = self.val;
		if (src.is_real() && !dst.is_real())
		{
			type_store::QualType real_dest = dest.to_real(p.comp);
			float_value::FloatToIntChangeKind change_kind = self.val.float_to_int(real_dest, p.comp);
			if (implicit) self.float_to_int_warning(p, tok, original, dest, old_val, change_kind)!;
			self.qt = real_dest;
			self.implicit_cast(p, tree::CastKind.FLOAT_TO_INT);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
		else if (!src.is_real() && dst.is_real())
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_FLOAT_TO_REAL);
			float_value::FloatToIntChangeKind change_kind = self.val.float_to_int(dest, p.comp);
			if (implicit) self.float_to_int_warning(p, tok, original, dest, old_val, change_kind)!;
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.FLOAT_TO_INT);
		}
		else
		{
			float_value::FloatToIntChangeKind change_kind = self.val.float_to_int(dest, p.comp);
			if (implicit) self.float_to_int_warning(p, tok, original, dest, old_val, change_kind)!;
			self.qt = dest;
			self.implicit_cast(p, src.is_real() ? tree::CastKind.FLOAT_TO_INT : tree::CastKind.COMPLEX_FLOAT_TO_COMPLEX_INT);
		}
	}
	else if (src.is_pointer())
	{
		// Pointer representations are target-defined; Value has no safe
		// pointer-to-integer evaluator, so retain the AST conversion only.
		self.val = value::NONE;
		if (implicit)
		{
			self.conversion_err(p, tok, parser_diagnostics::ParserDiag.IMPLICIT_PTR_TO_INT, p.fmt_qt(original), p.fmt_qt(dest))!;
		}
		self.qt = dest.to_real(p.comp);
		self.implicit_cast(p, tree::CastKind.POINTER_TO_INT);
		if (!dst.is_real())
		{
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
	}
	else
	{
		value::Value old_val = self.val;
		type_store::QualType value_dest = dst.is_real() ? dest : dest.to_real(p.comp);
		value::IntCastChangeKind change_kind = self.val.int_cast(value_dest, p.comp);
		if (implicit) self.int_conversion_warning(p, tok, original, dest, old_val, change_kind)!;
		if (src.is_real() && !dst.is_real())
		{
			type_store::QualType real_dest = dest.to_real(p.comp);
			self.qt = real_dest;
			self.implicit_cast(p, tree::CastKind.INT_CAST);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_INT);
		}
		else if (!src.is_real() && dst.is_real())
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_INT_TO_REAL);
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.INT_CAST);
		}
		else
		{
			self.qt = dest;
			self.implicit_cast(p, src.is_real() ? tree::CastKind.INT_CAST : tree::CastKind.COMPLEX_INT_CAST);
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
		if (!dst.is_real())
		{
			self.qt = dest;
			self.implicit_cast(p, tree::CastKind.REAL_TO_COMPLEX_FLOAT);
		}
	}
	else if (src.is_int())
	{
		if (src.is_real() && !dst.is_real())
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
			self.implicit_cast(p, !src.is_real() && dst.is_real() ? tree::CastKind.COMPLEX_INT_TO_REAL :
				(!src.is_real() ? tree::CastKind.COMPLEX_INT_TO_COMPLEX_FLOAT : tree::CastKind.INT_TO_FLOAT));
		}
	}
	else if (src.is_real() && !dst.is_real())
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
	else if (!src.is_real() && dst.is_real())
	{
		type_store::QualType real_src = self.qt.to_real(p.comp);
		self.qt = real_src;
		self.val = float_value::real_part(self.val, p.comp);
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
		self.implicit_cast(p, !src.is_real() ? tree::CastKind.COMPLEX_FLOAT_CAST : tree::CastKind.FLOAT_CAST);
	}
}

fn void Result.null_to_pointer(&self, parser::Parser* p, type_store::QualType dest)
{
	if (!self.qt.is(p.comp, type_store::TypeTag.NULLPTR_T) && !self.val.is_zero(p.comp)) return;
	self.val = value::NULL;
	self.qt = dest;
	self.implicit_cast(p, tree::CastKind.NULL_TO_POINTER);
}

<* Convert a scalar integer, bool, nullptr or pointer to a pointer type. *>
fn void? Result.cast_to_pointer(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex tok = 0, bool implicit = true)
{
	type_store::QualType original = self.qt;
	type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
	if (src == type_store::ScalarKind.BOOL)
	{
		self.qt = dest;
		self.implicit_cast(p, tree::CastKind.BOOL_TO_POINTER);
	}
	else if (src.is_int())
	{
		if (implicit && !self.val.is_zero(p.comp))
		{
			self.conversion_err(p, tok, parser_diagnostics::ParserDiag.IMPLICIT_INT_TO_PTR, p.fmt_qt(original), p.fmt_qt(dest))!;
		}
		// Integer and pointer representations depend on the target. Keep even
		// integer-to-pointer constant values unavailable rather than guessing.
		self.val = value::NONE;
		self.qt = dest;
		self.implicit_cast(p, tree::CastKind.INT_TO_POINTER);
	}
	else if (src == type_store::ScalarKind.NULLPTR_T)
	{
		self.null_to_pointer(p, dest);
	}
	else if (src.is_pointer() && !self.qt.eql(dest, p.comp))
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
				self.conversion_err(p, tok, parser_diagnostics::ParserDiag.PTR_ASSIGN_DISCARDS_QUALS, p.fmt_qt(dest), p.fmt_qt(original))!;
			}
			else if (!from_child.eql(to_child, p.comp))
			{
				bool sign_only = from_child.same_rank_different_sign(to_child, p.comp);
				if (sign_only)
				{
					self.conversion_err(p, tok, parser_diagnostics::ParserDiag.INCOMPATIBLE_PTR_ASSIGN_SIGN, p.fmt_qt(dest), p.fmt_qt(original))!;
				}
				else
				{
					self.conversion_err(p, tok, parser_diagnostics::ParserDiag.INCOMPATIBLE_PTR_ASSIGN, p.fmt_qt(dest), p.fmt_qt(original))!;
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
	if (src.is_pointer())
	{
		self.val.bool_cast(p.comp);
		self.qt = type_store::BOOL;
		self.implicit_cast(p, tree::CastKind.POINTER_TO_BOOL);
	}
	else if (src.is_int())
	{
		self.val.bool_cast(p.comp);
		if (!src.is_real())
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_INT_TO_REAL);
		}
		self.qt = type_store::BOOL;
		self.implicit_cast(p, tree::CastKind.INT_TO_BOOL);
	}
	else if (src.is_float())
	{
		if (!src.is_real())
		{
			// A complex value is true when either component is nonzero. The
			// float-to-int evaluator intentionally converts only its real part.
			self.val.bool_cast(p.comp);
		}
		else
		{
			value::Value old_val = self.val;
			float_value::FloatToIntChangeKind change_kind = self.val.float_to_int(type_store::BOOL, p.comp);
			if (implicit) self.float_to_int_warning(p, tok, self.qt, type_store::BOOL, old_val, change_kind)!;
		}
		if (!src.is_real())
		{
			self.qt = self.qt.to_real(p.comp);
			self.implicit_cast(p, tree::CastKind.COMPLEX_FLOAT_TO_REAL);
		}
		self.qt = type_store::BOOL;
		self.implicit_cast(p, tree::CastKind.FLOAT_TO_BOOL);
	}
}

<* Assignment-style scalar/vector coercion. Returns false when no supported conversion exists. *>
fn bool? Result.coerce_scalar(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex tok = 0)
{
	self.value_conversion(p);
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
		if (!(self.coerce_scalar(p, elem, tok)!)) return false;
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
	if (dst.is_int() && (src.is_int() || src.is_float()))
	{
		self.cast_to_int(p, dest.unqualified(), tok)!;
		return true;
	}
	if (dst.is_int() && src.is_pointer() && src != type_store::ScalarKind.BLOCK_POINTER)
	{
		self.cast_to_int(p, dest.unqualified(), tok)!;
		return true;
	}
	if (dst.is_float() && (src.is_int() || src.is_float()))
	{
		self.cast_to_float(p, dest.unqualified(), tok)!;
		return true;
	}
	if (dst.is_pointer() && (src == type_store::ScalarKind.NULLPTR_T || self.val.is_zero(p.comp)))
	{
		self.null_to_pointer(p, dest.unqualified());
		return true;
	}
	if (dst.is_pointer() && src.is_int())
	{
		self.cast_to_pointer(p, dest.unqualified(), tok)!;
		return true;
	}
	if (dst.is_pointer() && src.is_pointer())
	{
		self.cast_to_pointer(p, dest.unqualified(), tok)!;
		return true;
	}
	return dest.eql(self.qt, p.comp);
}

<* Apply a supported explicit scalar or equal-size vector cast. *>
fn bool? Result.explicit_cast(&self, parser::Parser* p, type_store::QualType dest, tokens::TokenIndex l_paren)
{
	if (self.qt.is_invalid() || dest.is_invalid()) return false;
	self.value_conversion(p);
	self.atomic_to_non_atomic(p);
	type_store::QualType original = self.qt;
	if (dest.is(p.comp, type_store::TypeTag.VOID))
	{
		self.explicit_cast_warnings(p, l_paren, dest, original)!;
		self.val = value::NONE;
		self.qt = dest;
		self.node = p.tree.add_node({ .kind = tree::NodeKind.CAST, .cast = {
			.l_paren = l_paren, .kind = tree::CastKind.TO_VOID, .operand = self.node,
			.qt = dest, .implicit = false,
		} });
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
			self.node = p.tree.add_node({ .kind = tree::NodeKind.CAST, .cast = {
				.l_paren = l_paren, .kind = tree::CastKind.BITCAST, .operand = self.node,
				.qt = self.qt, .implicit = false,
			} });
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
			self.node = p.tree.add_node({ .kind = tree::NodeKind.CAST, .cast = {
				.l_paren = l_paren, .kind = tree::CastKind.BITCAST, .operand = self.node,
				.qt = self.qt, .implicit = false,
			} });
			return true;
		}
		type_store::ScalarKind src = self.qt.scalar_kind(p.comp);
		type_store::ScalarKind dst = dest.scalar_kind(p.comp);
		if (dst == type_store::ScalarKind.BOOL)
		{
			self.cast_to_bool(p, l_paren, false)!;
		}
		else if (dst.is_int() && (src.is_int() || src.is_float() || src.is_pointer()))
		{
			self.cast_to_int(p, dest.unqualified(), l_paren, false)!;
		}
		else if (dst.is_float() && (src.is_int() || src.is_float()))
		{
			self.cast_to_float(p, dest.unqualified(), l_paren, false)!;
		}
		else if (dst.is_pointer() && (src.is_int() || src.is_pointer() || src == type_store::ScalarKind.NULLPTR_T))
		{
			if (src.is_int() && !src.is_real()) return false;
			self.cast_to_pointer(p, dest.unqualified(), l_paren, false)!;
		}
		else { return false; }
	}
	self.explicit_cast_warnings(p, l_paren, dest, original)!;
	self.node = p.tree.add_node({ .kind = tree::NodeKind.CAST, .cast = {
		.l_paren = l_paren, .kind = tree::CastKind.NO_OP, .operand = self.node,
		.qt = self.qt, .implicit = false,
	} });
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
		if (rhs.coerce_scalar(p, self.qt, tok)!) return;
		self.qt = type_store::INVALID;
		self.val = value::NONE;
		rhs.val = value::NONE;
		return;
	}
	if (try bv = b_vec)
	{
		assert(bv.tag == type_store::TypeTag.VECTOR);
		if (self.coerce_scalar(p, rhs.qt, tok)!) return;
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
	if (af) { rhs.cast_to_float(p, self.qt, tok)!; return; }
	if (bf) { self.cast_to_float(p, rhs.qt, tok)!; return; }
	if (!self.qt.is_int(p.comp) || !rhs.qt.is_int(p.comp)) return;
	type_store::QualType a = self.qt.to_real(p.comp);
	type_store::QualType b = rhs.qt.to_real(p.comp);
	type_store::Order order = self.qt.int_rank_order(rhs.qt, p.comp);
	bool as = self.qt.signedness(p.comp) == lang_opts::Signedness.SIGNED;
	bool bs = rhs.qt.signedness(p.comp) == lang_opts::Signedness.SIGNED;
	type_store::QualType target;
	if (as == bs)
	{
		target = order == type_store::Order.LT ? rhs.qt : a;
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

struct InitializerValueIssue
{
	bool found;
	tokens::TokenIndex tok;
}

<* Find the first initializer expression without a saved value. Omitted
   aggregate elements are zero and therefore do not produce an issue. *>
fn InitializerValueIssue initializer_value_issue(parser::Parser* p, type_store::NodeIndex node_index)
{
	tree::Node node = node_index.get(&p.tree);
	switch (node.kind)
	{
		case tree::NodeKind.ARRAY_INIT_EXPR:
		case tree::NodeKind.STRUCT_INIT_EXPR:
		{
			foreach (item : node.container_init.items)
			{
				InitializerValueIssue issue = initializer_value_issue(p, item);
				if (issue.found) return issue;
			}
			return {};
		}
		case tree::NodeKind.UNION_INIT_EXPR:
			if (node.union_init.initializer.is_null()) return {};
			return initializer_value_issue(p, node.union_init.initializer.unwrap());
		case tree::NodeKind.DEFAULT_INIT_EXPR:
		case tree::NodeKind.ARRAY_FILLER_EXPR:
		case tree::NodeKind.STRING_LITERAL_EXPR:
		case tree::NodeKind.NULLPTR_LITERAL:
			return {};
		case tree::NodeKind.CAST:
			// NULL is represented by a dedicated interner sentinel and save_value
			// intentionally does not put it in the tree's ordinary value map.
			if (node.cast.kind == tree::CastKind.NULL_TO_POINTER) return {};
			if (try saved = p.tree.value_of(node_index))
			{
				if (!saved.is_none()) return {};
			}
			return initializer_value_issue(p, node.cast.operand);
		default:
			if (try saved = p.tree.value_of(node_index))
			{
				if (!saved.is_none()) return {};
			}
			return { .found = true, .tok = node_index.tok(&p.tree) };
	}
}

<* Require a saved constant for constexpr and static-duration initializers.
   The runtime context accepts expressions whose value is unavailable. *>
fn bool? Result.require_initializer_value(&self, parser::Parser* p, parser::InitContext context,
	tokens::TokenIndex tok)
{
	if (context == parser::InitContext.RUNTIME || !self.val.is_none()) return true;
	InitializerValueIssue issue = initializer_value_issue(p, self.node);
	if (!issue.found) return true;
	// The top-level token is a fallback for synthetic nodes without a usable
	// token index; ordinary aggregate failures point at the first missing child.
	tokens::TokenIndex diagnostic_tok = (usz)issue.tok < p.tree.tokens.len ? issue.tok : tok;
	switch (context)
	{
		case RUNTIME: return true;
		case CONSTEXPR:
			p.err(parser_diagnostics::ParserDiag.NON_CONSTANT_INITIALIZER, diagnostic_tok)!;
		case STATIC:
			p.err(parser_diagnostics::ParserDiag.STATIC_NON_CONSTANT_INITIALIZER, diagnostic_tok)!;
	}
	return false;
}
