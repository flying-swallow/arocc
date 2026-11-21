// Postfix expression grammar on Parser (`parse_postfix_expr`): calls,
// subscripts, member access, postfix `++`/`--`, compound literals and GNU
// statement expressions, whose compound body comes from the parser handler.
module aro::frontend::c::parser;
import aro::primitive_value;
import aro::frontend::c::parser_result, aro::frontend::c::tree, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::diagnostics;
import aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner, aro::frontend::c::compilation, aro::frontend::c::lang_opts;
import aro::string_interner, aro::bigint;
import aro::frontend::c::builtins, aro::frontend::c::builtin_call, aro::frontend::c::builtin_defs::common;
import std::collections::list;

<* `builtin_call::dispatch` does not recognize this callee and wants ordinary call handling. *>
excuse NO_BUILTIN_CALL;

<* Whether `callee` names a builtin whose variadic arguments must reach its custom check unpromoted
   (mirrors upstream `CallExpr.shouldPromoteVarArg`). *>
fn bool is_unpromoted_builtin_callee(parser::Parser* p, type_store::NodeIndex callee)
{
	tree::Node callee_node = callee.get(&p.tree);
	if (callee_node.kind != tree::NodeKind.BUILTIN_REF) return false;
	String name = p.tree.tok_slice(callee_node.builtin_ref.name_tok);
	if (try expanded = p.comp.builtins.find(name))
	{
		return expanded.tag == common::TAG___BUILTIN_ADD_OVERFLOW ||
		expanded.tag == common::TAG___BUILTIN_SUB_OVERFLOW ||
		expanded.tag == common::TAG___BUILTIN_MUL_OVERFLOW ||
		expanded.tag == common::TAG___BUILTIN_COMPLEX ||
		expanded.tag == common::TAG___BUILTIN_ISINF ||
		expanded.tag == common::TAG___BUILTIN_ISINF_SIGN ||
		expanded.tag == common::TAG___BUILTIN_ISNAN;
	}
	return false;
}

<* Parsed statement-expression compound. `qt` is the type of the final
   expression statement, or void when the compound has no final expression. *>
struct StatementExpressionBodyResult
{
	type_store::NodeIndex body;
	type_store::QualType qt;
}

struct AttributeDeclSpanCheckpoint
{
	uint node;
	uint index;
	uint len;
}

<* Compound literal initializer and node, after the `(type-name)` prefix has been
   parsed; the current token is the `{`. *>
fn parser_result::Result? Parser.parse_compound_literal(&self, tokens::TokenIndex l_paren, type_store::QualType qt,
	tree::CompoundLiteralStorageClass storage = tree::CompoundLiteralStorageClass.AUTO, bool thread_local = false, bool eval = true)
{
	parser::InitContext context = self.init_context;
	if (storage == tree::CompoundLiteralStorageClass.STATIC || thread_local || !self.function_context.active)
	{
		context = parser::InitContext.STATIC;
	}
	parser_result::Result initializer = self.parse_initializer_with_context(qt, context, eval)!;
	type_store::NodeIndex literal = self.compound_literal_node(l_paren, qt, initializer.node, storage, thread_local);
	// A scalar compound literal has its initializer's constant value: the braced
	// scalar keeps the value on its converted node. Array, record, complex and
	// vector literals never carry a scalar value.
	bool scalar = !qt.is(self.comp, type_store::TypeTag.ARRAY) && !qt.is(self.comp, type_store::TypeTag.VECTOR) &&
	!qt.is(self.comp, type_store::TypeTag.COMPLEX) && !@ok(qt.get_record(self.comp));
	if (scalar && !qt.is_variably_modified(self.comp))
	{
		if (try saved = self.tree.value_of(initializer.node))
		{
			// Same as the string-subscript rule: the literal node keeps the value and
			// the result carries it. save_value clears the result value, so restore it.
			parser_result::Result literal_result = { .node = literal, .qt = qt, .val = saved };
			literal_result.save_value(self);
			literal_result.val = saved;
			return literal_result;
		}
	}
	return { .node = literal, .qt = qt, .val = value::NONE };
}

<* Undo state that a failed compound callback may have left behind. Parsed
   declarations are abandoned with the malformed expression, so their tree
   attributes and attribute-map entries must be removed together. *>
fn void Parser.restore_statement_expression_state(&self, usz scope_depth, bool extension_suppressed,
	usz attribute_count, usz attribute_extra_count, list::List{AttributeDeclSpanCheckpoint} * saved_decl_attrs)
{
	parser::Parser* p = self;
	// SymbolStack retains popped scopes, so resetting active_len also
	// reactivates the original scopes without clearing their contents.
	p.symbols.active_len = scope_depth;
	p.extension_suppressed = extension_suppressed;
	while (p.tree.attr_map.attributes.len() > (sz)attribute_count) p.tree.attr_map.attributes.pop()!!;
	while (p.tree.attr_map.extra.len() > (sz)attribute_extra_count) p.tree.attr_map.extra.pop()!!;
	p.tree.attr_map.decl_attrs.clear();
	foreach (saved : *saved_decl_attrs)
	{
		p.tree.attr_map.decl_attrs.set(saved.node, { .index = saved.index, .len = saved.len });
	}
}

<* Parse the compound statement starting at the current `{` through the handler's
   statement grammar, and type it by its final expression statement (void when
   none). Leaves the parser at the token after the matching `}`. *>
fn StatementExpressionBodyResult? Parser.parse_statement_expression_body(&self, bool eval) @noinline
{
	type_store::NodeIndex body = self.handler.handle_statement_expression_body(self, eval)!;
	tree::Node compound = body.get(&self.tree);
	if (compound.kind != tree::NodeKind.COMPOUND_STMT) return PARSING_FAILED~;
	type_store::QualType result_qt = type_store::VOID;
	if (compound.compound_stmt.body.len != 0)
	{
		type_store::NodeIndex last = compound.compound_stmt.body[compound.compound_stmt.body.len - 1];
		if (last.get(&self.tree).kind.family == tree::NodeFamily.EXPR) result_qt = last.qt(&self.tree);
	}
	return { .body = body, .qt = result_qt };
}

<* Parse the GNU `({ ... })` primary form when the handler provides statement
   bodies. The handler parses the compound; this layer owns the surrounding
   parentheses, diagnostics, scope/attribute rollback and STMT_EXPR. *>
fn parser_result::Result? Parser.parse_statement_expression(&self, tokens::TokenIndex l_paren,
	tokens::TokenIndex l_brace, bool eval)
{
	parser::Parser* p = self;
	Diagnostic.GNU_STATEMENT_EXPRESSION.@emit(p, l_brace)!;
	if (!p.function_context.active)
	{
		Diagnostic.STMT_EXPR_NOT_ALLOWED_FILE_SCOPE.@emit(p, l_brace)!;
		return PARSING_FAILED~;
	}

	usz saved_scope_depth = p.symbols.active_len;
	bool saved_extension_suppressed = p.extension_suppressed;
	usz saved_attribute_count = (usz)p.tree.attr_map.attributes.len();
	usz saved_attribute_extra_count = (usz)p.tree.attr_map.extra.len();
	list::List{AttributeDeclSpanCheckpoint} saved_decl_attrs;
	saved_decl_attrs.init(p.comp.gpa);
	defer saved_decl_attrs.free();
	foreach (entry : p.tree.attr_map.decl_attrs.iter())
	{
		saved_decl_attrs.push(
			{
				.node = entry.key, .index = entry.value.index, .len = entry.value.len
			}
		);
	}
	bool completed = false;
	defer if (!completed) self.restore_statement_expression_state(saved_scope_depth,
		saved_extension_suppressed, saved_attribute_count, saved_attribute_extra_count, &saved_decl_attrs);

	StatementExpressionBodyResult body = self.parse_statement_expression_body(eval)!;
	if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
	completed = true;

	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.STMT_EXPR, .unary = {
				.qt = body.qt, .operand = body.body, .op_tok = l_brace,
			}
		}
	);
	return { .node = node, .qt = body.qt, .val = value::NONE };
}

<* Parser.zig enables va_arg_pack call context only when the argument starts
   with the builtin, optionally wrapped in parentheses. *>
fn bool starts_va_arg_pack_argument(parser::Parser* p)
{
	usz lookahead = 0;
	while (p.is_at(tokenizer::TokenId.L_PAREN, lookahead)) lookahead++;
	tokens::TokenIndex? index = p.peek_index(lookahead);
	if (catch index) return false;
	tokens::TreeToken token = p.tree.tokens[(usz)index];
	return token.id == tokenizer::TokenId.IDENTIFIER && p.tree.tok_slice(index) == "__builtin_va_arg_pack";
}

<* C default argument promotions for variadic and old-style calls. *>
fn void? promote_call_argument(parser_result::Result* arg, parser::Parser* p, tokens::TokenIndex tok)
{
	if (arg.qt.is_invalid()) return;
	if (arg.qt.is_int(p.comp))
	{
		type_store::QualType promoted = arg.qt.promote_int(p.comp);
		if (!promoted.eql(arg.qt, p.comp)) arg.cast_to_int(p, promoted, tok)!;
	}
	else if (arg.qt.scalar_kind(p.comp) == type_store::ScalarKind.FLOAT &&
	arg.qt.float_rank(p.comp) < type_store::DOUBLE.float_rank(p.comp))
	{
		arg.cast_to_float(p, type_store::DOUBLE, tok)!;
	}
}

<*
 Constant value of `base[index]` when `base` is a string literal node, its
 element is one byte wide, and `index` is an in-bounds integer constant. Every
 other form yields value::NONE. Emits no diagnostics.
*>
fn value::Value string_subscript_value(parser::Parser* p, parser_result::Result base, parser_result::Result index)
{
	if (base.val.is_none() || !base.val.is(primitive_value::PrimitiveType.BYTES, p.comp)) return value::NONE;
	if (base.node.get(&p.tree).kind != tree::NodeKind.STRING_LITERAL_EXPR) return value::NONE;
	if (index.val.is_none() || !index.val.is_int(p.comp)) return value::NONE;
	if (try arr = base.qt.get(p.comp, type_store::TypeTag.ARRAY))
	{
		type_store::QualType elem = arr.array.elem;
		if (elem.bit_sizeof(p.comp) != 8) return value::NONE;
		uint? maybe_index = index.val.to_u32(p.comp);
		if (catch maybe_index) return value::NONE;
		uint index_int = maybe_index;
		char[] bytes = base.val.to_bytes(p.comp);
		if ((usz)index_int >= bytes.len) return value::NONE;
		char unit = bytes[index_int];
		if (elem.signedness(p.comp) == lang_opts::Signedness.UNSIGNED) return value::int_u64((ulong)unit, p.comp);
		return value::int_i64((long)(ichar)unit, p.comp);
	}
	return value::NONE;
}

<* Check the operand rules shared by postfix increment and decrement. *>
fn bool? check_postfix_update_operand(parser::Parser* p, parser_result::Result operand, tokens::TokenIndex op_tok)
{
	if (operand.qt.is_invalid()) return true;
	type_store::ScalarKind scalar_kind = operand.qt.scalar_kind(p.comp);
	if (scalar_kind == type_store::ScalarKind.VOID_POINTER)
	{
		Diagnostic.GNU_POINTER_ARITH.@emit(p, op_tok)!;
	}
	if (scalar_kind == type_store::ScalarKind.NONE)
	{
		Diagnostic.INVALID_ARGUMENT_UN.@emit(p, op_tok, p.fmt_qt(operand.qt))!;
	}
	if (!scalar_kind.is_real)
	{
		Diagnostic.COMPLEX_PREFIX_POSTFIX_OP.@emit(p, op_tok, p.fmt_qt(operand.qt))!;
	}

	bool is_const;
	if (!p.tree.is_lval_extra(operand.node, &is_const) || is_const || operand.qt.is_const)
	{
		Diagnostic.NOT_ASSIGNABLE.@emit(p, op_tok)!;
		return false;
	}

	type_store::QualType value_qt = operand.qt.non_atomic(p.comp);
	if (try pointer = value_qt.get(p.comp, type_store::TypeTag.POINTER))
	{
		if (p.comp.langopts.bounds_safety == lang_opts::BoundsSafety.CLANG &&
			pointer.pointer.bounds == type_store::PointerBounds.SINGLE)
		{
			Diagnostic.POINTER_ARITH_SINGLE.@emit(p, op_tok)!;
			return false;
		}

		type_store::QualType pointee = pointer.pointer.child;
		if (pointee.is(p.comp, type_store::TypeTag.VOID)) return true;
		if (pointee.is(p.comp, type_store::TypeTag.FUNC))
		{
			Diagnostic.INVALID_ARGUMENT_UN.@emit(p, op_tok, p.fmt_qt(operand.qt))!;
			return false;
		}
		if (pointee.has_incomplete_size(p.comp))
		{
			Diagnostic.PTR_ARITHMETIC_INCOMPLETE.@emit(p, op_tok, p.fmt_qt(pointee))!;
			return false;
		}
		return true;
	}

	// Parser.zig reports invalid/complex operand diagnostics above but still builds the
	// postfix node for a modifiable lvalue, preserving recovery and the original value.
	return true;
}

<* Build a postfix update node while retaining the operand's prior value on its node. *>
fn void make_postfix_update(parser::Parser* p, parser_result::Result* operand,
	tree::NodeKind kind, tokens::TokenIndex op_tok)
{
	operand.save_value(p);
	operand.qt = operand.qt.non_atomic(p.comp).unqualified();
	operand.node = p.tree.add_node(
		{
			.kind = kind, .unary = {
				.qt = operand.qt, .operand = operand.node, .op_tok = op_tok,
			}
		}
	);
}

<*
 Zig `checkArrayBounds`: diagnose a constant `index` outside a fixed-length `array`
 (or an array a pointer decayed from). `array` and `index` are the operands before
 conversion, so the array type and node survive decay. Clang `__single` pointer rules
 are separate (check_single_subscript).
*>
fn void? check_subscript_bounds(parser::Parser* p, parser_result::Result index, parser_result::Result array,
	tokens::TokenIndex bracket)
{
	if (index.val.is_none()) return;
	if (try len = array.qt.array_len(p.comp))
	{
		if (len == 0) return;
		if (len == 1)
		{
			// A trailing one-element member acts as an old-style flexible array member.
			tree::Node array_expr = array.node.get(&p.tree);
			if (array_expr.kind == tree::NodeKind.MEMBER_ACCESS_EXPR || array_expr.kind == tree::NodeKind.MEMBER_ACCESS_PTR_EXPR)
			{
				type_store::QualType base_qt = array_expr.member_access.base.qt(&p.tree);
				if (try base_ptr = base_qt.get(p.comp, type_store::TypeTag.POINTER)) base_qt = base_ptr.pointer.child;
				if (try record = base_qt.get_record(p.comp))
				{
					if ((usz)array_expr.member_access.member_index + 1 == record.fields.len)
					{
						if (!index.val.is_zero(p.comp))
						{
							Diagnostic.OLD_STYLE_FLEXIBLE_STRUCT.@emit(p, bracket, p.fmt_value(index.val, index.qt))!;
						}
						return;
					}
				}
			}
		}
		ulong index_int = index.val.to_u64(p.comp) ?? ulong::max;
		if (index.qt.signedness(p.comp) == lang_opts::Signedness.UNSIGNED)
		{
			if (index_int >= len)
			{
				Diagnostic.ARRAY_AFTER.@emit(p, bracket, p.fmt_value(index.val, index.qt))!;
			}
		}
		else if (value::compare(index.val, bigint::CompareOperator.LT, value::ZERO, p.comp))
		{
			Diagnostic.ARRAY_BEFORE.@emit(p, bracket, p.fmt_value(index.val, index.qt))!;
		}
		else if (index_int >= len)
		{
			Diagnostic.ARRAY_AFTER.@emit(p, bracket, p.fmt_value(index.val, index.qt))!;
		}
	}
}

<*
 Clang bounds-safety: subscripting a `__single` pointer is in bounds only at a constant
 index of 0. `base` is the raw pointer operand and `index` the raw integer operand, both
 before decay and promotion. The check keys on the raw pointer type, so a fixed array
 (which only decays to a pointer) is never treated as `__single`. Any other index,
 constant or not, reports SINGLE_REQUIRES_ZERO_INDEX at `bracket`.
*>
fn void? check_single_subscript(parser::Parser* p, parser_result::Result base, parser_result::Result index,
	tokens::TokenIndex bracket)
{
	if (p.comp.langopts.bounds_safety != lang_opts::BoundsSafety.CLANG) return;
	if (try pointer = base.qt.get(p.comp, type_store::TypeTag.POINTER))
	{
		if (pointer.pointer.bounds != type_store::PointerBounds.SINGLE) return;
		if (index.val.is_zero(p.comp)) return;
		Diagnostic.SINGLE_REQUIRES_ZERO_INDEX.@emit(p, bracket)!;
	}
}

<*
 Zig `suffixExpr` `.l_bracket` after the closing `]` is consumed. Decays both operands,
 then takes the pointer, array or vector side as base in either order (integer index).
 Invalid roles are reported at `bracket` and the access node is still built, as in
 Parser.zig. Element types with no size are rejected; `void` keeps the GNU extension.
 A valid integer index gets C integer promotion once the roles are known. Clang
 `__single` bases are checked against the raw operands (check_single_subscript).
*>
fn parser_result::Result? Parser.array_subscript(&self, parser_result::Result array_before,
	parser_result::Result index_before, tokens::TokenIndex bracket)
{
	parser::Parser* p = self;
	parser_result::Result ptr = array_before;
	parser_result::Result index = index_before;
	ptr.value_conversion(p);
	index.value_conversion(p);

	bool swapped = false;
	bool has_element = false;
	if (try ptr_ty = ptr.qt.get(p.comp, type_store::TypeTag.POINTER))
	{
		ptr.qt = ptr_ty.pointer.child;
		has_element = true;
		if (index.qt.is_real_int(p.comp))
		{
			check_subscript_bounds(p, index_before, array_before, bracket)!;
			check_single_subscript(p, array_before, index_before, bracket)!;
		}
		else
		{
			Diagnostic.INVALID_INDEX.@emit(p, bracket)!;
		}
	}
	else if (try index_ty = index.qt.get(p.comp, type_store::TypeTag.POINTER))
	{
		index.qt = index_ty.pointer.child;
		has_element = true;
		if (ptr.qt.is_real_int(p.comp))
		{
			check_subscript_bounds(p, array_before, index_before, bracket)!;
			check_single_subscript(p, index_before, array_before, bracket)!;
		}
		else
		{
			Diagnostic.INVALID_INDEX.@emit(p, bracket)!;
		}
		// Integer on the left, pointer on the right: the pointer becomes the base.
		parser_result::Result swap_tmp = ptr;
		ptr = index;
		index = swap_tmp;
		swapped = true;
	}
	else if (try vec_ty = ptr.qt.get(p.comp, type_store::TypeTag.VECTOR))
	{
		// Vector elements are addressed from the unconverted vector operand.
		ptr = array_before;
		ptr.qt = vec_ty.vector.elem;
		has_element = true;
		if (!index.qt.is_real_int(p.comp))
		{
			Diagnostic.INVALID_INDEX.@emit(p, bracket)!;
		}
	}
	else if (!index.qt.is_invalid() && !ptr.qt.is_invalid())
	{
		Diagnostic.INVALID_SUBSCRIPT.@emit(p, bracket)!;
	}

	// C integer promotion of a valid integer index, after roles are known so both operand
	// orders and vector bases get it. Raw operands above still feed folding and bounds checks.
	if (has_element && index.qt.is_real_int(p.comp)) index.usual_unary_conversion(p, bracket)!;

	if (has_element && !ptr.qt.is_invalid() && !ptr.qt.is(p.comp, type_store::TypeTag.VOID) &&
	ptr.qt.has_incomplete_size(p.comp))
	{
		Diagnostic.PTR_ARITHMETIC_INCOMPLETE.@emit(p, bracket, p.fmt_qt(ptr.qt))!;
		ptr.qt = type_store::INVALID;
	}

	// Fold `"literal"[k]` from the operands before decay (string_subscript_value).
	value::Value subscript_val = swapped ? string_subscript_value(p, index_before, array_before)
	: string_subscript_value(p, array_before, index_before);

	ptr.save_value(p);
	index.save_value(p);
	ptr.node = p.tree.add_node(
		{
			.kind = tree::NodeKind.ARRAY_ACCESS_EXPR, .array_access = {
				.l_bracket_tok = bracket, .qt = ptr.qt, .base = ptr.node, .index = index.node,
			}
		}
	);
	ptr.val = subscript_val;
	if (!subscript_val.is_none()) p.tree.set_value(ptr.node, subscript_val);
	return ptr;
}

<* Member-name lookup state shared by the direct and anonymous-record searches. `base_qt` is
   the record named in NO_SUCH_MEMBER even when the search descends into an anonymous member. *>
struct MemberLookup
{
	type_store::QualType base_qt;
	string_interner::StringId target_name;
	tokens::TokenIndex access_tok;
	tokens::TokenIndex name_tok;
}

<*
 Number of members named `target_name` reachable from `record`: direct fields plus the
 matches inside each anonymous struct/union member, at every level. More than one is
 ambiguous; zero is a missing member.
*>
fn usz member_match_count(compilation::Compilation* comp, type_store::Record record, string_interner::StringId target_name)
{
	usz count = 0;
	foreach (field : record.fields)
	{
		if (field.name_tok == (type_store::TokenIndex)0)
		{
			if (try nested_record = field.qt.get_record(comp))
			{
				count += member_match_count(comp, nested_record, target_name);
				continue;
			}
		}
		if (target_name == field.name) count++;
	}
	return count;
}

<* Add the const/volatile/restrict qualifiers of `parent` to `qt`; `qt` keeps its own. *>
fn type_store::QualType inherit_qualifiers(type_store::QualType qt, type_store::QualType parent)
{
	qt.is_const = qt.is_const || parent.is_const;
	qt.is_volatile = qt.is_volatile || parent.is_volatile;
	qt.is_restrict = qt.is_restrict || parent.is_restrict;
	return qt;
}

<*
 Zig `fieldAccessExtra`: find `ctx.target_name` in `record`, descending into
 anonymous struct/union members that contain it. Each anonymous level is its own
 member access; `is_arrow` applies only to the outermost one because inner levels
 are reached through the value. `record_qt` is the qualified record the member is read
 through: every member type inherits its qualifiers, and each anonymous level passes its
 qualified type down. The caller rejects ambiguous names first, so at most one path
 matches. A miss at the top level reports NO_SUCH_MEMBER.
*>
fn parser_result::Result? field_access_extra(parser::Parser* p, type_store::NodeIndex base,
	type_store::Record record, type_store::QualType record_qt, bool is_arrow, MemberLookup* ctx)
{
	for (usz i = 0; i < record.fields.len; i++)
	{
		type_store::RecordField field = record.fields[i];
		type_store::QualType field_qt = inherit_qualifiers(field.qt, record_qt);
		if (field.name_tok == (type_store::TokenIndex)0)
		{
			if (try nested_record = field.qt.get_record(p.comp))
			{
				if (!nested_record.has_field(p.comp, ctx.target_name)) continue;
				type_store::NodeIndex inner = p.tree.add_node(
					{
						.kind = is_arrow ? tree::NodeKind.MEMBER_ACCESS_PTR_EXPR : tree::NodeKind.MEMBER_ACCESS_EXPR,
						.member_access = { .qt = field_qt, .base = base, .access_tok = ctx.access_tok, .member_index = (uint)i }
				}
				);
				return field_access_extra(p, inner, nested_record, field_qt, false, ctx);
			}
		}
		if (ctx.target_name == field.name)
		{
			type_store::NodeIndex node = p.tree.add_node(
				{
					.kind = is_arrow ? tree::NodeKind.MEMBER_ACCESS_PTR_EXPR : tree::NodeKind.MEMBER_ACCESS_EXPR,
					.member_access = { .qt = field_qt, .base = base, .access_tok = ctx.access_tok, .member_index = (uint)i }
			}
			);
			return { .node = node, .qt = field_qt, .val = value::NONE };
		}
	}
	Diagnostic.NO_SUCH_MEMBER.@emit(p, ctx.name_tok, p.tree.tok_slice(ctx.name_tok), p.fmt_qt(ctx.base_qt))!;
	return PARSING_FAILED~;
}

<* Zig `expectIdentifier`: consume an identifier token, or report the expected-token diagnostic and fail. *>
fn tokens::TokenIndex? Parser.expect_identifier(&self)
{
	parser::Parser* p = self;
	if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
	{
		p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!;
		return PARSING_FAILED~;
	}
	tokens::TokenIndex name_tok = p.tok_i;
	p.advance();
	return name_tok;
}

<*
 Zig `fieldAccess` for `.` and `->`, called after the member name is consumed.
 Wrong-record, pointer-vs-arrow and atomic-member mismatches are reported and
 lookup continues on the unwrapped type. A non-record base, or an incomplete
 pointed-to record, stops the suffix. An invalid base yields an invalid member
 access without lookup.
*>
fn parser_result::Result? Parser.field_access(&self, parser_result::Result lhs,
	tokens::TokenIndex name_tok, bool is_arrow, tokens::TokenIndex access_tok)
{
	parser::Parser* p = self;
	if (lhs.qt.is_invalid())
	{
		type_store::NodeIndex node = p.tree.add_node(
			{
				.kind = is_arrow ? tree::NodeKind.MEMBER_ACCESS_PTR_EXPR : tree::NodeKind.MEMBER_ACCESS_EXPR,
				.member_access = { .qt = type_store::INVALID, .base = lhs.node, .access_tok = access_tok, .member_index = 0xFFFF_FFFF }
			}
		);
		return { .node = node, .qt = type_store::INVALID, .val = value::NONE };
	}

	type_store::QualType expr_qt = lhs.qt.non_atomic(p.comp);
	bool is_ptr = expr_qt.is_pointer(p.comp);
	type_store::QualType expr_base_qt = is_ptr ? expr_qt.child_type(p.comp) : expr_qt;
	type_store::QualType record_qt = expr_base_qt.non_atomic(p.comp);
	type_store::Record record;
	if (try found_record = record_qt.get_record(p.comp))
	{
		record = found_record;
	}
	else
	{
		Diagnostic.EXPECTED_RECORD_TY.@emit(p, name_tok, p.fmt_qt(expr_qt))!;
		return PARSING_FAILED~;
	}
	if (!record.has_layout)
	{
		// Invalid use of an incomplete type is reported where the type was named.
		if (!is_ptr) return PARSING_FAILED~;
		Diagnostic.DEREF_INCOMPLETE_TY_PTR.@emit(p, name_tok - 2, p.fmt_qt(expr_base_qt))!;
		return PARSING_FAILED~;
	}
	if (expr_qt != lhs.qt)
	{
		Diagnostic.MEMBER_EXPR_ATOMIC.@emit(p, name_tok, p.fmt_qt(lhs.qt))!;
	}
	if (expr_base_qt != record_qt)
	{
		Diagnostic.MEMBER_EXPR_ATOMIC.@emit(p, name_tok, p.fmt_qt(expr_base_qt))!;
	}
	if (is_arrow && !is_ptr)
	{
		Diagnostic.MEMBER_EXPR_NOT_PTR.@emit(p, name_tok, p.fmt_qt(expr_qt))!;
	}
	if (!is_arrow && is_ptr)
	{
		Diagnostic.MEMBER_EXPR_PTR.@emit(p, name_tok, p.fmt_qt(expr_qt))!;
	}

	MemberLookup ctx = {
		.base_qt = record_qt,
		.target_name = p.comp.intern_string(p.tree.tok_slice(name_tok)),
		.access_tok = access_tok,
		.name_tok = name_tok,
	};
	if (member_match_count(p.comp, record, ctx.target_name) > 1)
	{
		Diagnostic.AMBIGUOUS_MEMBER.@emit(p, name_tok, p.tree.tok_slice(name_tok))!;
		return PARSING_FAILED~;
	}
	parser_result::Result maybe_member = field_access_extra(p, lhs.node, record, record_qt, is_arrow, &ctx)!;
	lhs.save_value(p);
	return maybe_member;
}

<*
 Parse a primary expression (`parse_primary_expr`) and all postfix suffixes.
 When the handler provides statement bodies, `({ ... })` is recognized here
 before the primary grammar runs.
*>
fn parser_result::Result? Parser.parse_postfix_expr(&self, bool eval = true)
{
	// Kept minimal: this frame is live across every nested primary expression;
	// the postfix operators are applied out of line.
	parser::Parser* p = self;
	parser_result::Result? maybe_lhs;
	if (self.handler && &self.handler.handle_statement_expression_body && p.is_at(tokenizer::TokenId.L_PAREN) && p.is_at(tokenizer::TokenId.L_BRACE, 1))
	{
		maybe_lhs = self.parse_statement_expression_at_paren(eval);
	}
	else
	{
		maybe_lhs = self.parse_primary_expr(eval);
	}
	if (catch f = maybe_lhs) return f~;
	return self.parse_postfix_operators(maybe_lhs, eval);
}

<* Apply `++ -- [] () . ->` to a parsed primary expression. *>
fn parser_result::Result? Parser.parse_postfix_operators(&self, parser_result::Result lhs, bool eval) @noinline
{
	parser::Parser* p = self;
	while (!p.at_eof())
	{
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		switch (id)
		{
			case PLUS_PLUS:
			case MINUS_MINUS: lhs = parse_postfix_update(p, lhs, id)!;
			case L_BRACKET: lhs = self.parse_subscript(lhs, eval)!;
			case L_PAREN: lhs = self.parse_call(lhs, eval)!;
			case PERIOD:
			case ARROW: lhs = self.parse_member_access(lhs, id)!;
			default: return lhs;
		}
	}
	return lhs;
}

fn parser_result::Result? Parser.parse_statement_expression_at_paren(&self, bool eval) @noinline
{
	parser::Parser* p = self;
	tokens::TokenIndex l_paren = p.tok_i;
	p.advance();
	tokens::TokenIndex l_brace = p.tok_i;
	return self.parse_statement_expression(l_paren, l_brace, eval);
}

<* Postfix `++`/`--` applied to `lhs`. *>
fn parser_result::Result? parse_postfix_update(parser::Parser* p, parser_result::Result lhs, tokenizer::TokenId id) @noinline
{
	tokens::TokenIndex op_tok = p.tok_i;
	p.advance();
	tree::NodeKind kind = id == tokenizer::TokenId.PLUS_PLUS ? tree::NodeKind.POST_INC_EXPR : tree::NodeKind.POST_DEC_EXPR;
	if (lhs.qt.is_invalid())
	{
		lhs.val = value::NONE;
		lhs.node = p.tree.add_node(
			{
				.kind = kind, .unary = { .qt = lhs.qt, .operand = lhs.node, .op_tok = op_tok }
			}
		);
		return lhs;
	}
	if (!(check_postfix_update_operand(p, lhs, op_tok)!)) return PARSING_FAILED~;
	make_postfix_update(p, &lhs, kind, op_tok);
	return lhs;
}

<* `lhs[index]`. *>
fn parser_result::Result? Parser.parse_subscript(&self, parser_result::Result lhs, bool eval) @noinline
{
	parser::Parser* p = self;
	tokens::TokenIndex bracket = p.tok_i;
	p.advance();
	parser_result::Result index = self.parse_expr_prec(tokens::Precedence.ANY, eval)!;
	if (catch f = p.expect_closing(tokenizer::TokenId.R_BRACKET, bracket)) return f~;
	return self.array_subscript(lhs, index, bracket);
}

<* `lhs.name` / `lhs->name`. *>
fn parser_result::Result? Parser.parse_member_access(&self, parser_result::Result lhs, tokenizer::TokenId id) @noinline
{
	parser::Parser* p = self;
	bool is_arrow = id == tokenizer::TokenId.ARROW;
	tokens::TokenIndex access_tok = p.tok_i;
	p.advance();
	tokens::TokenIndex name_tok = self.expect_identifier()!;
	// Zig converts only atomic and array bases before `->`; other lvalues keep their node.
	if (is_arrow && !lhs.qt.is_invalid() && (lhs.qt.is(p.comp, type_store::TypeTag.ATOMIC) || lhs.qt.is(p.comp, type_store::TypeTag.ARRAY)))
	{
		lhs.value_conversion(p);
	}
	return self.field_access(lhs, name_tok, is_arrow, access_tok);
}

<* A call `lhs(args...)` after `lhs` has been parsed. Out of line so the
  call-checking locals do not enlarge every recursive `parse_postfix_expr` frame. *>
fn parser_result::Result? Parser.parse_call(&self, parser_result::Result lhs, bool eval) @noinline
{
	parser::Parser* p = self;
	tokens::TokenIndex l_paren = p.tok_i;
	p.advance();
	parser_result::Result func = lhs;
	func.value_conversion(p);
	type_store::QualType function_qt = func.qt;
	if (try pointer = function_qt.get(p.comp, type_store::TypeTag.POINTER))
	{
		function_qt = pointer.pointer.child;
	}
	else if (try block = function_qt.get(p.comp, type_store::TypeTag.BLOCK))
	{
		function_qt = block.block.func;
	}

	type_store::Func call_fn;
	uint typed_params_len = 0xFFFF_FFFF;
	type_store::FuncKind func_kind = type_store::FuncKind.NORMAL;
	bool preserve_builtin_args = is_unpromoted_builtin_callee(p, lhs.node);
	if (!function_qt.is_invalid())
	{
		if (!function_qt.is(p.comp, type_store::TypeTag.FUNC))
		{
			Diagnostic.NOT_CALLABLE.@emit(p, l_paren, p.fmt_qt(lhs.qt))!;
			return PARSING_FAILED~;
		}
		if (try resolved_fn = function_qt.get_func(p.comp))
		{
			call_fn = resolved_fn;
		}
		else
		{
			return PARSING_FAILED~;
		}
		typed_params_len = (uint)call_fn.params.len;
		func_kind = call_fn.kind;
	}

	List{type_store::NodeIndex} args;
	args.init(p.comp.gpa);
	defer args.free();
	tokens::TokenIndex first_after = l_paren;
	if (!self.is_at(tokenizer::TokenId.R_PAREN))
	{
		uint arg_index = 0;
		while (true)
		{
			tokens::TokenIndex param_tok = p.tok_i;
			if (arg_index == typed_params_len) first_after = param_tok;
			bool is_va_pack_start = starts_va_arg_pack_argument(p);
			parser_result::Result? maybe_arg;
			{
				parser::VaArgPackCallContext old_pack_context = p.va_arg_pack_call;
				p.va_arg_pack_call = is_va_pack_start ? (parser::VaArgPackCallContext){
					.active = true,
					.variadic = func_kind != type_store::FuncKind.NORMAL,
					.typed = arg_index < typed_params_len,
				}: {};
				defer p.va_arg_pack_call = old_pack_context;
				maybe_arg = self.parse_expr_prec(tokens::Precedence.ASSIGN, eval);
			}
			if (catch f = maybe_arg) return f~;
			parser_result::Result arg = maybe_arg;
			type_store::NodeIndex arg_root = arg.node;
			tree::Node arg_node = arg_root.get(&p.tree);
			while (arg_node.kind == tree::NodeKind.PAREN_EXPR)
			{
				arg_root = arg_node.unary.operand;
				arg_node = arg_root.get(&p.tree);
			}
			bool is_va_arg_pack = arg_node.kind == tree::NodeKind.BUILTIN_VA_ARG_PACK;
			tokens::TokenIndex pack_tok = is_va_arg_pack ? arg_node.va_arg_pack.builtin_tok : 0;
			if (!is_va_arg_pack) arg.value_conversion(p);
			if (!is_va_arg_pack && (arg.qt.is_invalid() ||
				(arg.qt.has_incomplete_size(p.comp) && !arg.qt.is(p.comp, type_store::TypeTag.VOID))))
			{
				return PARSING_FAILED~;
			}

			if (!is_va_arg_pack && !preserve_builtin_args && !function_qt.is_invalid() && arg_index < typed_params_len)
			{
				// Re-read the function type after parsing the expression; type-store
				// growth may move its parameter slice.
				type_store::Func current_fn = function_qt.get_func(p.comp)!;
				type_store::FuncParam param = current_fn.params[(usz)arg_index];
				// An incomplete parameter type was diagnosed at the declaration.
				if (param.qt.is_invalid() || param.qt.has_incomplete_size(p.comp))
				{
					arg.qt = type_store::INVALID;
				}
				else if (!arg.coerce_scalar(p, param.qt, param_tok, parser_result::CoercionContext.ARGUMENT)!)
				{
					Diagnostic.INCOMPATIBLE_ARG.@emit(p, param_tok,
						p.fmt_qt(arg.qt), p.fmt_qt(param.qt))!;
					if (param.name_tok != (type_store::TokenIndex)0) Diagnostic.PARAMETER_HERE.@emit(p, (tokens::TokenIndex)param.name_tok)!;
				}
			}
			else if (!is_va_arg_pack && !preserve_builtin_args && !function_qt.is_invalid())
			{
				promote_call_argument(&arg, p, param_tok)!;
			}

			arg.save_value(p);
			args.push(arg.node);
			if (!self.is_at(tokenizer::TokenId.COMMA)) break;
			if (is_va_arg_pack) Diagnostic.VA_PACK_NON_FINAL_ARG.@emit(p, pack_tok)!;
			p.advance();
			arg_index++;
		}
	}
	tokens::TokenIndex r_paren = p.tok_i;
	if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
	parser_result::Result? maybe_builtin = builtin_call::dispatch(null, p,
		lhs.node, l_paren, args.array_view(), eval);
	if (catch builtin_fault = maybe_builtin)
	{
		if (builtin_fault != NO_BUILTIN_CALL) return builtin_fault~;
	}
	else
	{
		return maybe_builtin;
	}

	bool args_ok = true;
	if (!function_qt.is_invalid())
	{
		if (func_kind == type_store::FuncKind.NORMAL && (usz)args.len() != (usz)typed_params_len)
		{
			tokens::TokenIndex tok = (usz)args.len() < (usz)typed_params_len ? r_paren : first_after;
			Diagnostic.EXPECTED_ARGUMENTS.@emit(p, tok,
				typed_params_len, (uint)args.len())!;
			args_ok = false;
		}
		else if (func_kind == type_store::FuncKind.VARIADIC && (usz)args.len() < (usz)typed_params_len)
		{
			Diagnostic.EXPECTED_AT_LEAST_ARGUMENTS.@emit(p, r_paren,
				typed_params_len, (uint)args.len())!;
			args_ok = false;
		}
		else if (func_kind == type_store::FuncKind.OLD_STYLE && (usz)args.len() != (usz)typed_params_len)
		{
			if (typed_params_len == 0)
			{
				Diagnostic.PASSING_ARGS_TO_KR.@emit(p, first_after)!;
			}
			else
			{
				Diagnostic.EXPECTED_ARGUMENTS_OLD.@emit(p, first_after,
					typed_params_len, (uint)args.len())!;
			}
		}
	}

	func.save_value(p);
	type_store::QualType return_qt = !function_qt.is_invalid() && args_ok ? call_fn.return_type : type_store::INVALID;
	// Zig CallExpr.init/finish: a call whose callee is a builtin_ref (through
	// parens) is always a builtin_call_expr, never a call_expr; codegen has
	// no lvalue for a builtin_ref.
	type_store::NodeIndex builtin_cur = lhs.node;
	tree::Node builtin_node = builtin_cur.get(&p.tree);
	while (builtin_node.kind == tree::NodeKind.PAREN_EXPR)
	{
		builtin_cur = builtin_node.unary.operand;
		builtin_node = builtin_cur.get(&p.tree);
	}
	if (builtin_node.kind == tree::NodeKind.BUILTIN_REF)
	{
		type_store::NodeIndex builtin_call_node = p.tree.add_node(
			{
				.kind = tree::NodeKind.BUILTIN_CALL_EXPR, .builtin_call = {
					.builtin_tok = builtin_node.builtin_ref.name_tok, .qt = return_qt, .args = args.array_view(),
			}
		}
		);
		lhs.init(builtin_call_node, return_qt);
		return lhs;
	}
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.CALL_EXPR, .call = {
				.l_paren_tok = l_paren, .qt = return_qt, .callee = func.node, .args = args.array_view(),
		}
	}
	);
	lhs.init(node, return_qt);
	return lhs;
}
