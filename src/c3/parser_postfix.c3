// Primary and postfix expression productions for the typed C3 parser.
// Identifier resolution, generic selection, casts and compound literals remain
// callbacks because they depend on outer grammar state. GNU statement
// expressions use a separate callback for their compound-statement body.
module aro::parser_postfix;
import aro::parser, aro::parser_result, aro::tree, aro::tokens, aro::tokenizer, aro::parser_diagnostics;
import aro::type_store, aro::value, aro::value_interner, aro::compilation, aro::lang_opts;
import aro::string_interner;
import std::collections::list;

excuse PARSING_FAILED;
<* The optional builtin-call hook does not recognize this callee and wants ordinary call handling. *>
excuse NO_BUILTIN_CALL;

alias PrimaryExpression = fn parser_result::Result?(void* context, parser::Parser* p, bool eval);
alias NestedExpression = fn parser_result::Result?(void* context, parser::Parser* p, tokens::Precedence min_prec, bool eval);
alias BuiltinCallDispatcher = fn parser_result::Result?(void* context, parser::Parser* p,
	type_store::NodeIndex callee, tokens::TokenIndex l_paren, type_store::NodeIndex[] args, bool eval);

<* Parsed statement-expression compound. `qt` is the type of the final
   expression statement, or void when the compound has no final expression. *>
struct StatementExpressionBodyResult
{
	type_store::NodeIndex body;
	type_store::QualType qt;
}

<* Parse the compound statement starting at the current `{`. The callback
   owns statement grammar and returns its compound node plus final expression
   type; it must leave the parser at the token after the matching `}`. *>
alias StatementExpressionBodyParser = fn StatementExpressionBodyResult?(void* context, parser::Parser* p, bool eval);

struct AttributeDeclSpanCheckpoint
{
	uint node;
	uint index;
	uint len;
}

struct PostfixParser
{
	parser::Parser* parser;
	void* context;
	<* Optional context for nested expression callbacks; an unset value falls
	   back to the shared callback context. *>
	void* expression_context;
	PrimaryExpression primary;
	NestedExpression expression;
	void* statement_expression_context;
	StatementExpressionBodyParser statement_expression_body;
	bool has_statement_expression_body;
	void* builtin_call_context;
	BuiltinCallDispatcher builtin_call;
	bool has_builtin_call;
}

fn void* PostfixParser.nested_expression_context(&self)
{
	return self.expression_context != null ? self.expression_context : self.context;
}

<* Helper for a primary-expression callback after it has recognized and parsed
   the `(type-name)` prefix of a compound literal. *>
fn parser_result::Result? PostfixParser.parse_compound_literal(&self, tokens::TokenIndex l_paren, type_store::QualType qt,
	tree::CompoundLiteralStorageClass storage = tree::CompoundLiteralStorageClass.AUTO, bool thread_local = false, bool eval = true)
{
	parser::Parser* p = self.parser;
	parser::InitContext context = p.init_context;
	if (storage == tree::CompoundLiteralStorageClass.STATIC || thread_local || !p.function_context.active) { context = parser::InitContext.STATIC; }
	parser_result::Result? maybe_initializer = p.parse_initializer_with_context(qt, context, eval);
	if (catch caught_fault = maybe_initializer) return caught_fault~;
	parser_result::Result initializer = maybe_initializer;
	type_store::NodeIndex literal = p.compound_literal_node(l_paren, qt, initializer.node, storage, thread_local);
	// A scalar compound literal has its initializer's constant value: the braced
	// scalar keeps the value on its converted node. Array, record, complex and
	// vector literals never carry a scalar value.
	bool scalar = !qt.is(p.comp, type_store::TypeTag.ARRAY) && !qt.is(p.comp, type_store::TypeTag.VECTOR) &&
		!qt.is(p.comp, type_store::TypeTag.COMPLEX) && !@ok(qt.get_record(p.comp));
	if (scalar)
	{
		if (try saved = p.tree.value_of(initializer.node))
		{
			// Same as the string-subscript rule: the literal node keeps the value and
			// the result carries it. save_value clears the result value, so restore it.
			parser_result::Result literal_result = { .node = literal, .qt = qt, .val = saved };
			literal_result.save_value(p);
			literal_result.val = saved;
			return literal_result;
		}
	}
	return { .node = literal, .qt = qt, .val = value::NONE };
}

fn bool PostfixParser.at(self, tokenizer::TokenId id)
{
	parser::Parser* p = self.parser;
	return !p.at_eof() && p.tree.tokens[(usz)p.tok_i].id == id;
}

fn void? PostfixParser.expect(&self, tokenizer::TokenId id)
{
	return self.parser.expect(id);
}

<* Undo state that a failed compound callback may have left behind. Parsed
   declarations are abandoned with the malformed expression, so their tree
   attributes and attribute-map entries must be removed together. *>
fn void PostfixParser.restore_statement_expression_state(&self, usz scope_depth, bool extension_suppressed,
	usz attribute_count, usz attribute_extra_count, list::List{AttributeDeclSpanCheckpoint}* saved_decl_attrs)
{
	parser::Parser* p = self.parser;
	if (p.symbols_initialized)
	{
		// SymbolStack retains popped scopes, so resetting active_len also
		// reactivates the original scopes without clearing their contents.
		p.symbols.active_len = scope_depth;
	}
	p.extension_suppressed = extension_suppressed;
	while (p.tree.attr_map.attributes.len() > (sz)attribute_count) p.tree.attr_map.attributes.pop()!!;
	while (p.tree.attr_map.extra.len() > (sz)attribute_extra_count) p.tree.attr_map.extra.pop()!!;
	p.tree.attr_map.decl_attrs.clear();
	foreach (saved : *saved_decl_attrs)
	{
		p.tree.attr_map.decl_attrs.set(saved.node, { .index = saved.index, .len = saved.len });
	}
}

<* Parse the GNU `({ ... })` primary form when its statement-body owner is
   bound. The callback returns the compound and its final expression type;
   this layer owns the surrounding parentheses, diagnostics, and STMT_EXPR. *>
fn parser_result::Result? PostfixParser.parse_statement_expression(&self, tokens::TokenIndex l_paren,
	tokens::TokenIndex l_brace, bool eval)
{
	parser::Parser* p = self.parser;
	p.err(parser_diagnostics::ParserDiag.GNU_STATEMENT_EXPRESSION, l_brace)!;
	if (!p.function_context.active)
	{
		p.emit_parser_diag(parser_diagnostics::ParserDiag.STMT_EXPR_NOT_ALLOWED_FILE_SCOPE,
			"statement expression not allowed at file scope", l_brace)!;
		return PARSING_FAILED~;
	}

	usz saved_scope_depth = p.symbols_initialized ? p.symbols.active_len : 0;
	bool saved_extension_suppressed = p.extension_suppressed;
	usz saved_attribute_count = (usz)p.tree.attr_map.attributes.len();
	usz saved_attribute_extra_count = (usz)p.tree.attr_map.extra.len();
	list::List{AttributeDeclSpanCheckpoint} saved_decl_attrs;
	saved_decl_attrs.init(p.comp.gpa);
	defer saved_decl_attrs.free();
	foreach (entry : p.tree.attr_map.decl_attrs.iter())
	{
		saved_decl_attrs.push({ .node = entry.key, .index = entry.value.index, .len = entry.value.len });
	}
	bool completed = false;
	defer if (!completed) self.restore_statement_expression_state(saved_scope_depth,
		saved_extension_suppressed, saved_attribute_count, saved_attribute_extra_count, &saved_decl_attrs);

	StatementExpressionBodyResult? maybe_body = self.statement_expression_body(self.statement_expression_context, p, eval);
	if (catch f = maybe_body) return f~;
	StatementExpressionBodyResult body = maybe_body;
	if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
	completed = true;

	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.STMT_EXPR, .unary = {
		.qt = body.qt, .operand = body.body, .op_tok = l_brace,
	} });
	return { .node = node, .qt = body.qt, .val = value::NONE };
}

<* Parser.zig enables va_arg_pack call context only when the argument starts
   with the builtin, optionally wrapped in parentheses. *>
fn bool starts_va_arg_pack_argument(parser::Parser* p)
{
	usz lookahead = 0;
	while (p.is_at(tokenizer::TokenId.L_PAREN, lookahead)) lookahead++;
	parser::TokenIndexOption maybe_index = p.peek_index(lookahead);
	if (!maybe_index.has_value) return false;
	tokens::TreeToken token = p.tree.tokens[(usz)maybe_index.value];
	return token.id == tokenizer::TokenId.IDENTIFIER && p.tree.tok_slice(maybe_index.value) == "__builtin_va_arg_pack";
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
	if (base.val.is_none() || !base.val.is(value_interner::InternerKeyTag.BYTES, p.comp)) return value::NONE;
	if (base.node.get(&p.tree).kind != tree::NodeKind.STRING_LITERAL_EXPR) return value::NONE;
	if (index.val.is_none() || !index.val.is(value_interner::InternerKeyTag.INT, p.comp)) return value::NONE;
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
 Zig `fieldAccessExtra`: find `ctx.target_name` in `record`, descending into
 anonymous struct/union members that contain it. Each anonymous level is its own
 member access; `is_arrow` applies only to the outermost one because inner levels
 are reached through the value. A miss at the top level reports NO_SUCH_MEMBER.
*>
fn parser_result::Result? field_access_extra(parser::Parser* p, type_store::NodeIndex base,
	type_store::Record record, bool is_arrow, MemberLookup* ctx)
{
	for (usz i = 0; i < record.fields.len; i++)
	{
		type_store::RecordField field = record.fields[i];
		if (field.name_tok == (type_store::TokenIndex)0)
		{
			if (try nested_record = field.qt.get_record(p.comp))
			{
				if (!nested_record.has_field(p.comp, ctx.target_name)) continue;
				type_store::NodeIndex inner = p.tree.add_node({ .kind = is_arrow ? tree::NodeKind.MEMBER_ACCESS_PTR_EXPR : tree::NodeKind.MEMBER_ACCESS_EXPR,
					.member_access = { .qt = field.qt, .base = base, .access_tok = ctx.access_tok, .member_index = (uint)i } });
				return field_access_extra(p, inner, nested_record, false, ctx);
			}
		}
		if (ctx.target_name == field.name)
		{
			type_store::NodeIndex node = p.tree.add_node({ .kind = is_arrow ? tree::NodeKind.MEMBER_ACCESS_PTR_EXPR : tree::NodeKind.MEMBER_ACCESS_EXPR,
				.member_access = { .qt = field.qt, .base = base, .access_tok = ctx.access_tok, .member_index = (uint)i } });
			return { .node = node, .qt = field.qt, .val = value::NONE };
		}
	}
	p.err(parser_diagnostics::ParserDiag.NO_SUCH_MEMBER, ctx.name_tok, p.tree.tok_slice(ctx.name_tok), p.fmt_qt(ctx.base_qt))!;
	return PARSING_FAILED~;
}

<* Zig `expectIdentifier`: consume an identifier token, or report the expected-token diagnostic and fail. *>
fn tokens::TokenIndex? PostfixParser.expect_identifier(&self)
{
	parser::Parser* p = self.parser;
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
fn parser_result::Result? PostfixParser.field_access(&self, parser_result::Result lhs,
	tokens::TokenIndex name_tok, bool is_arrow, tokens::TokenIndex access_tok)
{
	parser::Parser* p = self.parser;
	if (lhs.qt.is_invalid())
	{
		type_store::NodeIndex node = p.tree.add_node({ .kind = is_arrow ? tree::NodeKind.MEMBER_ACCESS_PTR_EXPR : tree::NodeKind.MEMBER_ACCESS_EXPR,
			.member_access = { .qt = type_store::INVALID, .base = lhs.node, .access_tok = access_tok, .member_index = 0xFFFF_FFFF } });
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
		p.err(parser_diagnostics::ParserDiag.EXPECTED_RECORD_TY, name_tok, p.fmt_qt(expr_qt))!;
		return PARSING_FAILED~;
	}
	if (!record.has_layout)
	{
		// Invalid use of an incomplete type is reported where the type was named.
		if (!is_ptr) return PARSING_FAILED~;
		p.err(parser_diagnostics::ParserDiag.DEREF_INCOMPLETE_TY_PTR, name_tok - 2, p.fmt_qt(expr_base_qt))!;
		return PARSING_FAILED~;
	}
	if (expr_qt != lhs.qt)
	{
		p.err(parser_diagnostics::ParserDiag.MEMBER_EXPR_ATOMIC, name_tok, p.fmt_qt(lhs.qt))!;
	}
	if (expr_base_qt != record_qt)
	{
		p.err(parser_diagnostics::ParserDiag.MEMBER_EXPR_ATOMIC, name_tok, p.fmt_qt(expr_base_qt))!;
	}
	if (is_arrow && !is_ptr)
	{
		p.err(parser_diagnostics::ParserDiag.MEMBER_EXPR_NOT_PTR, name_tok, p.fmt_qt(expr_qt))!;
	}
	if (!is_arrow && is_ptr)
	{
		p.err(parser_diagnostics::ParserDiag.MEMBER_EXPR_PTR, name_tok, p.fmt_qt(expr_qt))!;
	}

	MemberLookup ctx = {
		.base_qt = record_qt,
		.target_name = p.comp.intern_string(p.tree.tok_slice(name_tok)),
		.access_tok = access_tok,
		.name_tok = name_tok,
	};
	parser_result::Result? maybe_member = field_access_extra(p, lhs.node, record, is_arrow, &ctx);
	if (catch member_fault = maybe_member) return member_fault~;
	lhs.save_value(p);
	return maybe_member;
}

<*
 Parse a primary expression and all supported postfix suffixes. The primary
   callback owns identifier/literal resolution, generic selection and the
   parenthesized/type-name/compound-literal ambiguities. In particular it
   should call Parser.parse_type_name and Parser.parse_body rather than
   treating those forms as ordinary expressions. When bound, this parser
   recognizes `({ ... })` before invoking the primary callback.
*>
fn parser_result::Result? PostfixParser.parse(&self, bool eval = true)
{
	parser::Parser* p = self.parser;
	parser_result::Result? maybe_lhs;
	if (self.has_statement_expression_body && p.is_at(tokenizer::TokenId.L_PAREN) && p.is_at(tokenizer::TokenId.L_BRACE, 1))
	{
		tokens::TokenIndex l_paren = p.tok_i;
		p.advance();
		tokens::TokenIndex l_brace = p.tok_i;
		maybe_lhs = self.parse_statement_expression(l_paren, l_brace, eval);
	}
	else
	{
		maybe_lhs = self.primary(self.context, p, eval);
	}
	if (catch f = maybe_lhs) return f~;
	parser_result::Result lhs = maybe_lhs;
	while (!p.at_eof())
	{
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		if (id == tokenizer::TokenId.PLUS_PLUS || id == tokenizer::TokenId.MINUS_MINUS)
		{
			tokens::TokenIndex op_tok = p.tok_i;
			bool is_const;
			if (!p.tree.is_lval_extra(lhs.node, &is_const) || is_const) return PARSING_FAILED~;
			p.advance();
			lhs.save_value(p);
			tree::NodeKind kind = id == tokenizer::TokenId.PLUS_PLUS ? tree::NodeKind.POST_INC_EXPR : tree::NodeKind.POST_DEC_EXPR;
			lhs.node = p.tree.add_node({ .kind = kind, .unary = { .qt = lhs.qt, .operand = lhs.node, .op_tok = op_tok } });
			continue;
		}
		if (id == tokenizer::TokenId.L_BRACKET)
		{
			tokens::TokenIndex bracket = p.tok_i;
			p.advance();
			parser_result::Result? maybe_index = self.expression(self.nested_expression_context(), p, tokens::PREC_ANY, eval);
			if (catch f = maybe_index) return f~;
			parser_result::Result index = maybe_index;
			if (catch f = self.expect(tokenizer::TokenId.R_BRACKET)) return f~;
			value::Value subscript_val = string_subscript_value(p, lhs, index);
			lhs.value_conversion(p);
			index.value_conversion(p);
			type_store::QualType elem;
			if (try ptr = lhs.qt.get(p.comp, type_store::TypeTag.POINTER))
			{
				elem = ptr.pointer.child;
			}
			else if (try arr = lhs.qt.get(p.comp, type_store::TypeTag.ARRAY))
			{
				elem = arr.array.elem;
			}
			else if (try vec = lhs.qt.get(p.comp, type_store::TypeTag.VECTOR))
			{
				elem = vec.vector.elem;
			}
			else
			{
				return PARSING_FAILED~;
			}
			lhs.save_value(p);
			index.save_value(p);
			lhs.node = p.tree.add_node({ .kind = tree::NodeKind.ARRAY_ACCESS_EXPR, .array_access = {
				.l_bracket_tok = bracket, .qt = elem, .base = lhs.node, .index = index.node,
			} });
			lhs.qt = elem;
			lhs.val = subscript_val;
			if (!subscript_val.is_none()) p.tree.set_value(lhs.node, subscript_val);
			continue;
		}
		if (id == tokenizer::TokenId.L_PAREN)
		{
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
			if (!function_qt.is_invalid())
			{
				if (!function_qt.is(p.comp, type_store::TypeTag.FUNC))
				{
					p.err(parser_diagnostics::ParserDiag.NOT_CALLABLE, l_paren, p.fmt_qt(lhs.qt))!;
					return PARSING_FAILED~;
				}
				if (try resolved_fn = function_qt.get_func(p.comp)) { call_fn = resolved_fn; }
				else { return PARSING_FAILED~; }
				typed_params_len = (uint)call_fn.params.len;
				func_kind = call_fn.kind;
			}

			List{type_store::NodeIndex} args;
			args.init(p.comp.gpa);
			defer args.free();
			if (!self.at(tokenizer::TokenId.R_PAREN))
			{
				uint arg_index = 0;
				tokens::TokenIndex first_after = l_paren;
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
						} : {};
						defer p.va_arg_pack_call = old_pack_context;
						maybe_arg = self.expression(self.nested_expression_context(), p, tokens::PREC_ASSIGN, eval);
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

					if (!is_va_arg_pack && !function_qt.is_invalid() && arg_index < typed_params_len)
					{
						// Re-read the function type after parsing the expression; type-store
						// growth may move its parameter slice.
						type_store::Func current_fn = function_qt.get_func(p.comp)!;
						type_store::FuncParam param = current_fn.params[(usz)arg_index];
						if (param.qt.is_invalid())
						{
							arg.qt = type_store::INVALID;
						}
						else if (!arg.coerce_scalar(p, param.qt, param_tok)!)
						{
							p.err(parser_diagnostics::ParserDiag.INCOMPATIBLE_ARG, param_tok,
								p.fmt_qt(arg.qt), p.fmt_qt(param.qt))!;
							if (param.name_tok != 0) p.err(parser_diagnostics::ParserDiag.PARAMETER_HERE, param.name_tok)!;
						}
					}
					else if (!is_va_arg_pack && !function_qt.is_invalid())
					{
						promote_call_argument(&arg, p, param_tok)!;
					}

					arg.save_value(p);
					args.push(arg.node);
					if (!self.at(tokenizer::TokenId.COMMA)) break;
					if (is_va_arg_pack) p.err(parser_diagnostics::ParserDiag.VA_PACK_NON_FINAL_ARG, pack_tok)!;
					p.advance();
					arg_index++;
				}
			}
			tokens::TokenIndex r_paren = p.tok_i;
			if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
			if (self.has_builtin_call)
			{
				parser_result::Result? maybe_builtin = self.builtin_call(self.builtin_call_context, p,
					lhs.node, l_paren, args.array_view(), eval);
				if (catch builtin_fault = maybe_builtin)
				{
					if (builtin_fault != NO_BUILTIN_CALL) return builtin_fault~;
				}
				else
				{
					lhs = maybe_builtin;
					continue;
				}
			}

			bool args_ok = true;
			if (!function_qt.is_invalid())
			{
				if (func_kind == type_store::FuncKind.NORMAL && args.len != (usz)typed_params_len)
				{
					tokens::TokenIndex tok = args.len < (usz)typed_params_len ? r_paren : first_after;
					p.err(parser_diagnostics::ParserDiag.EXPECTED_ARGUMENTS, tok,
						typed_params_len, (uint)args.len)!;
					args_ok = false;
				}
				else if (func_kind == type_store::FuncKind.VARIADIC && args.len < (usz)typed_params_len)
				{
					p.err(parser_diagnostics::ParserDiag.EXPECTED_AT_LEAST_ARGUMENTS, r_paren,
						typed_params_len, (uint)args.len)!;
				}
				else if (func_kind == type_store::FuncKind.OLD_STYLE && args.len != (usz)typed_params_len)
				{
					if (typed_params_len == 0)
					{
						p.err(parser_diagnostics::ParserDiag.PASSING_ARGS_TO_KR, first_after)!;
					}
					else
					{
						p.err(parser_diagnostics::ParserDiag.EXPECTED_ARGUMENTS_OLD, first_after,
							typed_params_len, (uint)args.len)!;
					}
				}
			}

			func.save_value(p);
			type_store::QualType return_qt = !function_qt.is_invalid() && args_ok ? call_fn.return_type : type_store::INVALID;
			type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.CALL_EXPR, .call = {
				.l_paren_tok = l_paren, .qt = return_qt, .callee = func.node, .args = args.array_view(),
			} });
			lhs.init(node, return_qt);
			continue;
		}
		if (id == tokenizer::TokenId.PERIOD || id == tokenizer::TokenId.ARROW)
		{
			bool is_arrow = id == tokenizer::TokenId.ARROW;
			tokens::TokenIndex access_tok = p.tok_i;
			p.advance();
			tokens::TokenIndex name_tok = self.expect_identifier()!;
			// Zig converts only atomic and array bases before `->`; other lvalues keep their node.
			if (is_arrow && !lhs.qt.is_invalid() && (lhs.qt.is(p.comp, type_store::TypeTag.ATOMIC) || lhs.qt.is(p.comp, type_store::TypeTag.ARRAY)))
			{
				lhs.value_conversion(p);
			}
			parser_result::Result? maybe_member = self.field_access(lhs, name_tok, is_arrow, access_tok);
			if (catch member_fault = maybe_member) return member_fault~;
			lhs = maybe_member;
			continue;
		}
		break;
	}
	return lhs;
}
