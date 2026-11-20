// Primary-expression grammar on Parser (`parse_primary_expr`).
module aro::parser;
import aro::primitive_value;
import aro::parser_result, aro::tree;
import aro::tokens, aro::tokenizer, aro::type_store, aro::value, aro::value_interner;
import aro::number_literal, aro::number_value, aro::text_literal, aro::text_literal_semantics;
import aro::symbol_stack, aro::string_interner;
import aro::diagnostics;
import aro::builtins, aro::builtin_properties, aro::lang_opts;
import std::collections::list;
import std::core::dstring;

excuse CANNOT_CONCAT;

<*
 Primary-expression grammar (C23 6.5.1 plus GNU/Clang extensions), the
 leaves of the expression tree. `Parser.parse_primary_expr` reads one of:
  - `( expr )`                        -> PAREN_EXPR, `expr` via `parse_expr_prec`
  - `( type-name ) cast-expr`         -> cast, operand via `parse_expr_prec` at unary precedence
  - `( type-name ) { init-list }`     -> compound literal (`parse_compound_literal`)
  - identifier                        -> DECL_REF_EXPR / ENUMERATION_REF; unresolved
                                         names try builtins, then (called, pre-C23)
                                         an implicit function declaration
  - number (`PP_NUM`, `#embed` byte), character and (adjacent, concatenated)
    string literals
  - `true`, `false`, `nullptr`
  - `_Generic ( expr , assoc-list )`
  - `__func__`, `__FUNCTION__`, `__PRETTY_FUNCTION__`
 Anything else is `NO_EXPRESSION`. `({ ... })` statement expressions are not
 handled here (`parse_postfix_expr` intercepts them); reaching one reports it
 as unavailable. Postfix operators (calls, `[]`, `.`, `->`, `++`/`--`) belong to
 parser_postfix.c3.
*>

struct GenericTypeEntry
{
	type_store::QualType qt;
	tokens::TokenIndex tok;
}

struct GenericDefaultEntry
{
	bool present;
	type_store::NodeIndex node;
	tokens::TokenIndex tok;
	tokens::TokenIndex expression_start;
	type_store::QualType qt;
	value::Value val;
}

fn bool is_string_token(tokenizer::TokenId id)
{
	return id.is_string_literal() || id == tokenizer::TokenId.UNTERMINATED_STRING_LITERAL;
}

fn tree::CharLiteralKind char_kind(text_literal::TextLiteralKind kind)
{
	switch (kind)
	{
		case WIDE: return tree::CharLiteralKind.WIDE;
		case UTF_8: return tree::CharLiteralKind.UTF8;
		case UTF_16: return tree::CharLiteralKind.UTF16;
		case UTF_32: return tree::CharLiteralKind.UTF32;
		case CHAR:
		case UNTERMINATED: return tree::CharLiteralKind.ASCII;
	}
}

fn void? emit_number_diags(parser::Parser* p, number_value::NumberDiags diags, tokens::TokenIndex tok)
{
	diags.@each(; $diag) { $diag.@emit(p, tok)!; };
}

fn parser_result::Result? unavailable(parser::Parser* p, String message, tokens::TokenIndex tok)
{
	Diagnostic.PRIMARY_UNAVAILABLE.@emit(p, tok, message)!;
	return PARSING_FAILED~;
}

fn parser_result::Result? expected_expression(parser::Parser* p)
{
	Diagnostic.EXPECTED_EXPR.@emit(p, p.diag_index())!;
	return PARSING_FAILED~;
}

fn bool is_builtin_name(String name) => name.len >= 10 && name[0 : 10] == "__builtin_";

<* Zig primaryExpr's builtin lookup and implicit function declaration path. *>
fn parser_result::Result? Parser.parse_unresolved_identifier(&self,
	tokens::TokenIndex tok, string_interner::StringId name_id, String name)
{
	parser::Parser* p = self;
	builtins::Expanded? maybe_builtin = p.comp.builtins.get_or_create(p.comp, name);
	if (try expanded = maybe_builtin)
	{
		usz lookahead = 1;
		while (p.is_at(tokenizer::TokenId.R_PAREN, lookahead)) lookahead++;
		if (!p.is_at(tokenizer::TokenId.L_PAREN, lookahead))
		{
			Diagnostic.BUILTIN_MUST_BE_CALLED.@emit(p, tok)!;
			return PARSING_FAILED~;
		}
		if (expanded.header != builtin_properties::Header.NONE)
		{
			Diagnostic.IMPLICIT_BUILTIN.@emit(p, tok,
				name)!;
			Diagnostic.IMPLICIT_BUILTIN_HEADER_NOTE.@emit(p, tok,
				expanded.header.name, name)!;
		}
		p.advance();
		type_store::NodeIndex node = p.tree.add_node(
			{
				.kind = tree::NodeKind.BUILTIN_REF,
				.builtin_ref = { .name_tok = tok, .qt = expanded.qt }
			}
		);
		return { .node = node, .qt = expanded.qt, .val = value::NONE };
	}

	bool direct_call = p.is_at(tokenizer::TokenId.L_PAREN, 1);
	if (direct_call && !p.comp.langopts.standard.at_least(lang_opts::Standard.C23))
	{
		if (is_builtin_name(name))
		{
			Diagnostic.UNKNOWN_BUILTIN.@emit(p, tok, name)!;
		}
		else
		{
			Diagnostic.IMPLICIT_FUNC_DECL.@emit(p, tok, name)!;
		}
		type_store::QualType function_qt = p.comp.type_store.put(type_store::type_func(
				type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		type_store::NodeIndex function_node = p.tree.add_node(
			{
				.kind = tree::NodeKind.FUNCTION,
				.function = { .name_tok = tok, .qt = function_qt, .is_static = false,
				.is_inline = false, .body = type_store::NODE_NULL, .definition = type_store::NODE_NULL }
			}
		);
		p.tree.root_decls.push(function_node);
		p.symbols.declare_symbol(p, name_id, function_qt, tok, function_node)!;
		p.advance();
		type_store::NodeIndex ref_node = p.tree.add_node(
			{
				.kind = tree::NodeKind.DECL_REF_EXPR,
				.decl_ref = { .name_tok = tok, .qt = function_qt, .decl = function_node }
			}
		);
		return { .node = ref_node, .qt = function_qt, .val = value::NONE };
	}

	Diagnostic.UNDECLARED_IDENTIFIER.@emit(p, tok, name)!;
	return PARSING_FAILED~;
}

<* Create a static const character array backing a predefined function-name identifier. *>
fn type_store::NodeIndex Parser.make_predefined_identifier(&self, tokens::TokenIndex tok,
	String contents)
{
	parser::Parser* p = self;
	DString bytes;
	bytes.init(tmem);
	bytes.append_string(contents);
	bytes.append_char('\0');
	char[] data = (char[])bytes.str_view();
	value::Value val = value::intern(p.comp, { .tag = primitive_value::PrimitiveType.BYTES,
		.bytes = data });
	type_store::QualType char_qt = type_store::CHAR;
	char_qt.is_const = true;
	type_store::QualType array_qt = p.comp.type_store.put(type_store::type_array(char_qt,
			type_store::ArrayLenKind.FIXED, (ulong)data.len));
	type_store::NodeIndex string_node = p.tree.add_node(
		{
			.kind = tree::NodeKind.STRING_LITERAL_EXPR,
			.char_literal = { .literal_tok = tok, .qt = array_qt, .kind = tree::CharLiteralKind.ASCII }
		}
	);
	p.tree.set_value(string_node, val);
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.VARIABLE, .variable = {
				.name_tok = tok, .qt = array_qt, .storage_class = tree::VariableStorageClass.STATIC,
				.thread_local = false, .implicit = true, .initializer = string_node.pack(),
			.definition = type_store::NODE_NULL
		}
	}
	);
}

fn parser_result::Result? Parser.parse_predefined_identifier(&self,
	tokens::TokenIndex tok, bool pretty)
{
	parser::Parser* p = self;
	bool in_function = p.function_context.active;
	type_store::NodeOptIndex ident = pretty ? p.function_context.pretty_ident : p.function_context.func_ident;
	if (ident.is_null())
	{
		DString contents;
		contents.init(tmem);
		if (in_function)
		{
			String function_name = p.tree.tok_slice(p.function_context.function_name_tok);
			if (pretty)
			{
				p.function_context.function_qt.print_named(function_name, p.comp, &contents)!;
			}
			else
			{
				contents.append_string(function_name);
			}
		}
		else if (pretty)
		{
			contents.append_string("top level");
		}
		type_store::NodeIndex generated = self.make_predefined_identifier(tok, contents.str_view());
		ident = generated.pack();
		if (pretty)
		{
			p.function_context.pretty_ident = ident;
		}
		else
		{
			p.function_context.func_ident = ident;
		}
		if (!in_function) p.tree.root_decls.push(generated);
	}
	if (!in_function) Diagnostic.PREDEFINED_TOP_LEVEL.@emit(p, tok)!;
	p.advance();
	type_store::NodeIndex declaration = ident.unwrap();
	tree::Node variable = declaration.get(&p.tree);
	tokens::TokenIndex name_tok = pretty ? tok : variable.variable.name_tok;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .name_tok = name_tok, .qt = variable.variable.qt, .decl = declaration }
		}
	);
	return { .node = node, .qt = variable.variable.qt, .val = value::NONE };
}

fn parser_result::Result? Parser.parse_number(&self, tokens::TokenIndex tok)
{
	parser::Parser* p = self;
	tokens::TreeToken token = p.tree.tokens[(usz)tok];
	number_value::NumberValue number = number_value::parse(p.comp, p.tree.tok_slice(tok), token.loc, p.pp.expansion_slice(tok))!;
	p.advance();
	emit_number_diags(p, number.diags, tok)!;
	tree::NodeKind literal_kind = number.literal_qt.is_int(p.comp) ? tree::NodeKind.INT_LITERAL : tree::NodeKind.FLOAT_LITERAL;
	type_store::NodeIndex literal = p.tree.add_node(
		{
			.kind = literal_kind, .literal = {
				.literal_tok = tok, .qt = number.literal_qt,
			}
		}
	);
	if (!number.literal_val.is_none()) p.tree.set_value(literal, number.literal_val);
	type_store::NodeIndex node = literal;
	if (number.is_imaginary)
	{
		node = p.tree.add_node(
			{
				.kind = tree::NodeKind.IMAGINARY_LITERAL, .unary = {
					.qt = number.qt, .operand = literal, .op_tok = tok,
				}
			}
		);
	}
	return { .node = node, .qt = number.qt, .val = number.val };
}

fn parser_result::Result? Parser.parse_char(&self, tokens::TokenIndex tok)
{
	parser::Parser* p = self;
	tokens::TreeToken token = p.tree.tokens[(usz)tok];
	text_literal_semantics::CharLiteral literal = text_literal_semantics::char_literal(p.comp,
		token.id, p.tree.tok_slice(tok), token.loc, p.pp.expansion_slice(tok))!;
	p.advance();
	if (literal.has_diag)
	{
		switch (literal.diag)
		{
			case EMPTY_CHAR_LITERAL_ERROR: Diagnostic.EMPTY_CHAR_LITERAL_ERROR.@emit(p, tok)!;
			case UNTERMINATED_CHAR_LITERAL_ERROR: Diagnostic.UNTERMINATED_CHAR_LITERAL_ERROR.@emit(p, tok)!;
			default: unreachable("unexpected char literal diagnostic");
		}
	}
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.CHAR_LITERAL, .char_literal = {
				.literal_tok = tok, .qt = literal.qt, .kind = char_kind(literal.kind),
		}
	}
	);
	p.tree.set_value(node, literal.val);
	return { .node = node, .qt = literal.qt, .val = literal.val };
}

fn parser_result::Result? Parser.parse_string(&self, tokens::TokenIndex start)
{
	parser::Parser* p = self;
	list::List{tokenizer::TokenId} ids;
	ids.init(p.comp.gpa);
	defer ids.free();
	list::List{text_literal_semantics::StringPiece} pieces;
	pieces.init(p.comp.gpa);
	defer pieces.free();
	tokens::TokenIndex end = start;
	while (end < p.tok_end && is_string_token(p.tree.tokens[(usz)end].id))
	{
		tokens::TreeToken token = p.tree.tokens[(usz)end];
		ids.push(token.id);
		pieces.push(
			{
				.id = token.id, .bytes = p.tree.tok_slice(end), .loc = token.loc,
			.expansion_locs = p.pp.expansion_slice(end)
		}
		);
		end++;
	}
	sz error_index = 0;
	text_literal_semantics::StringRun? maybe_run = text_literal_semantics::string_run(ids.array_view(), &error_index);
	if (catch run_fault = maybe_run)
	{
		if (run_fault == text_literal::CANNOT_CONCAT)
		{
			Diagnostic.UNSUPPORTED_STR_CAT.@emit(p, start + (uint)error_index)!;
		}
		p.tok_i = start + (uint)error_index + 1;
		return PARSING_FAILED~;
	}
	text_literal_semantics::StringRun run = maybe_run;
	text_literal_semantics::StringLiteral literal = text_literal_semantics::string_literal(p.comp,
		pieces.array_view()[:run.len], run.kind)!;
	p.tok_i = start + (uint)run.len;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.STRING_LITERAL_EXPR, .char_literal = {
				.literal_tok = start, .qt = literal.qt, .kind = char_kind(literal.kind),
		}
	}
	);
	p.tree.set_value(node, literal.val);
	return { .node = node, .qt = literal.qt, .val = literal.val };
}

fn parser_result::Result? Parser.parse_identifier(&self, tokens::TokenIndex tok, bool eval)
{
	parser::Parser* p = self;
	String name = p.tree.tok_slice(tok);
	string_interner::StringId name_id = p.comp.intern_string(name);
	symbol_stack::Symbol? maybe_symbol = p.find_symbol(name_id);
	if (catch maybe_symbol)
	{
		return self.parse_unresolved_identifier(tok, name_id, name);
	}
	symbol_stack::Symbol symbol = maybe_symbol;
	// Only an auto declaration's own initializer sees its binding with the placeholder type.
	if (symbol.qt.is_auto())
	{
		p.advance();
		Diagnostic.AUTO_TYPE_SELF_INITIALIZED.@emit(p, tok, name)!;
		return PARSING_FAILED~;
	}
	p.advance();
	if (symbol.kind == symbol_stack::SymbolKind.TYPEDEF)
	{
		Diagnostic.UNEXPECTED_TYPE_NAME.@emit(p, tok, name)!;
		return PARSING_FAILED~;
	}
	p.mark_used(symbol.node);
	tree::NodeKind kind = symbol.kind == symbol_stack::SymbolKind.ENUMERATION ?
	tree::NodeKind.ENUMERATION_REF : tree::NodeKind.DECL_REF_EXPR;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = kind, .decl_ref = {
				.name_tok = tok, .qt = symbol.qt, .decl = symbol.node,
			}
		}
	);
	value::Value val = value::NONE;
	if (symbol.kind == symbol_stack::SymbolKind.ENUMERATION)
	{
		val = p.referenced_integer_constant(symbol.val,
			symbol.val.is_int(p.comp), true, tok);
	}
	else if (symbol.kind == symbol_stack::SymbolKind.CONSTEXPR)
	{
		val = symbol.val;
	}
	else if (symbol.kind == symbol_stack::SymbolKind.DEF && symbol.qt.is_const &&
		!symbol.val.is_none())
	{
		val = p.referenced_integer_constant(symbol.val,
			symbol.val.is_int(p.comp), false, tok);
	}
	if (!val.is_none()) p.tree.set_value(node, val);
	return { .node = node, .qt = symbol.qt, .val = val };
}

fn parser_result::Result? Parser.parse_group_or_cast(&self, tokens::TokenIndex l_paren, bool eval)
{
	// Kept minimal: this frame is live across every nested parenthesis level.
	parser::Parser* p = self;
	p.advance();
	parser::TypeNameProbe probe = p.probe_typed_type_name()!;
	if (probe.matched) return self.parse_cast(l_paren, probe.qt, eval);
	if (p.is_at(tokenizer::TokenId.L_BRACE))
	{
		return unavailable(p, "statement expressions are unavailable in this parser composition", l_paren);
	}
	parser_result::Result? maybe_inside = self.parse_expr_prec(tokens::Precedence.ANY, eval);
	if (catch f = maybe_inside) return nested_fault(p, f);
	return finish_paren(p, maybe_inside, l_paren);
}

fn parser_result::Result? nested_fault(parser::Parser* p, fault f) @noinline
{
	if (f == NO_EXPRESSION) return expected_expression(p);
	return f~;
}

<* `( expr )` once `expr` is parsed. *>
fn parser_result::Result? finish_paren(parser::Parser* p, parser_result::Result inside, tokens::TokenIndex l_paren) @noinline
{
	if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.PAREN_EXPR, .unary = {
				.qt = inside.qt, .operand = inside.node, .op_tok = l_paren,
			}
		}
	);
	return { .node = node, .qt = inside.qt, .val = inside.val };
}

<* `( type-name )` followed by a cast operand or a compound literal. *>
fn parser_result::Result? Parser.parse_cast(&self, tokens::TokenIndex l_paren, type_store::QualType qt, bool eval) @noinline
{
	parser::Parser* p = self;
	if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
	if (p.is_at(tokenizer::TokenId.L_BRACE)) return self.parse_compound_literal(l_paren, qt, eval: eval);
	// A cast-expression is a unary expression or another cast-expression.
	tokens::Precedence unary_only = tokens::Precedence.UNARY;
	parser_result::Result? maybe_operand = self.parse_expr_prec(unary_only, eval);
	if (catch f = maybe_operand) return nested_fault(p, f);
	return finish_cast(p, maybe_operand, qt, l_paren);
}


<* Apply and diagnose the explicit cast of a parsed operand to `qt`. *>
fn parser_result::Result? finish_cast(parser::Parser* p, parser_result::Result operand, type_store::QualType qt, tokens::TokenIndex l_paren) @noinline
{
	type_store::QualType source_qt = operand.qt;
	bool maybe_cast = operand.explicit_cast(p, qt, l_paren)!;
	if (!maybe_cast)
	{
		if (qt.is_pointer(p.comp))
		{
			Diagnostic.INVALID_CAST_TO_POINTER.@emit(p, l_paren, p.fmt_qt(source_qt))!;
		}
		else if (source_qt.is_pointer(p.comp) && qt.is_float(p.comp))
		{
			Diagnostic.INVALID_CAST_TO_FLOAT.@emit(p, l_paren, p.fmt_qt(qt))!;
		}
		else if (qt.is_int(p.comp) || qt.is_float(p.comp))
		{
			Diagnostic.INVALID_CAST_OPERAND_TYPE.@emit(p, l_paren, p.fmt_qt(source_qt))!;
		}
		else
		{
			Diagnostic.INVALID_CAST_TYPE.@emit(p, l_paren, p.fmt_qt(qt))!;
		}
		return PARSING_FAILED~;
	}
	return operand;
}

fn parser_result::Result? Parser.parse_generic(&self, tokens::TokenIndex generic_tok, bool eval)
{
	parser::Parser* p = self;
	if (catch f = p.expect(tokenizer::TokenId.L_PAREN)) return f~;
	parser_result::Result? maybe_control = self.parse_expr_prec(tokens::Precedence.CONDITIONAL, false);
	if (catch f = maybe_control)
	{
		if (f == NO_EXPRESSION) return expected_expression(p);
		return f~;
	}
	parser_result::Result control = maybe_control;
	control.value_conversion(p);
	control.val = value::NONE;
	if (catch f = p.expect(tokenizer::TokenId.COMMA)) return f~;

	list::List{type_store::NodeIndex} associations;
	associations.init(p.comp.gpa);
	defer associations.free();
	list::List{GenericTypeEntry} types;
	types.init(p.comp.gpa);
	defer types.free();
	GenericDefaultEntry default_entry = { .val = value::NONE };
	bool has_match = false;
	parser_result::Result selected = {};
	uint selected_association = 0;
	bool has_selected = false;

	while (true)
	{
		bool is_default = p.is_at(tokenizer::TokenId.KEYWORD_DEFAULT);
		tokens::TokenIndex association_tok;
		type_store::QualType association_qt = type_store::INVALID;
		if (is_default)
		{
			association_tok = p.tok_i;
			p.advance();
			if (default_entry.present)
			{
				Diagnostic.GENERIC_DUPLICATE_DEFAULT.@emit(p, association_tok)!;
				Diagnostic.PREVIOUS_CASE.@emit(p, default_entry.tok)!;
			}
		}
		else
		{
			association_tok = p.tok_i;
			parser::TypeNameProbe probe = p.probe_typed_type_name()!;
			if (!probe.matched)
			{
				// Zig reports `expected_type` for a missing association type.
				Diagnostic.EXPECTED_TYPE.@emit(p, p.diag_index())!;
				return PARSING_FAILED~;
			}
			association_qt = probe.qt;
			if (association_qt.is_qualified())
			{
				Diagnostic.GENERIC_QUAL_TYPE.@emit(p, association_tok)!;
			}
			if (association_qt.is(p.comp, type_store::TypeTag.ARRAY))
			{
				Diagnostic.GENERIC_ARRAY_TYPE.@emit(p, association_tok)!;
			}
			if (association_qt.is(p.comp, type_store::TypeTag.FUNC))
			{
				Diagnostic.GENERIC_FUNC_TYPE.@emit(p, association_tok)!;
			}
			foreach (previous : types)
			{
				if (association_qt.eql(previous.qt, p.comp))
				{
					Diagnostic.GENERIC_DUPLICATE.@emit(p, association_tok,
						p.fmt_qt(association_qt))!;
					Diagnostic.GENERIC_DUPLICATE_HERE.@emit(p, previous.tok,
						p.fmt_qt(previous.qt))!;
					break;
				}
			}
			types.push(
			{
				.qt = association_qt, .tok = association_tok
			}
			);
		}
		if (catch f = p.expect(tokenizer::TokenId.COLON)) return f~;
		tokens::TokenIndex colon_tok = p.tok_i - 1;
		tokens::TokenIndex expression_start = p.tok_i;
		bool is_match = !is_default && !has_match && association_qt.eql(control.qt, p.comp);
		bool evaluate_arm = is_match && eval;
		parser_result::Result? maybe_arm = self.parse_expr_prec(tokens::Precedence.ASSIGN, evaluate_arm);
		if (catch f = maybe_arm)
		{
			if (f == NO_EXPRESSION) return expected_expression(p);
			return f~;
		}
		parser_result::Result arm = maybe_arm;
		tokens::TokenIndex expression_end = p.tok_i;
		type_store::NodeIndex association_node;
		if (is_default)
		{
			association_node = p.tree.add_node(
				{
					.kind = tree::NodeKind.GENERIC_DEFAULT_EXPR,
					.generic_default = { .default_tok = association_tok, .expr = arm.node }
				}
			);
			if (!default_entry.present)
			{
				default_entry = { .present = true, .node = association_node, .tok = association_tok,
				.expression_start = expression_start,
				.qt = arm.qt, .val = arm.val };
			}
		}
		else
		{
			association_node = p.tree.add_node(
				{
					.kind = tree::NodeKind.GENERIC_ASSOCIATION_EXPR,
					.generic_association = { .colon_tok = colon_tok,
					.association_qt = association_qt, .expr = arm.node }
				}
			);
			// The colon is immediately before the assignment-expression.
			if (is_match)
			{
				has_match = true;
				selected = arm;
				selected_association = (uint)associations.len();
				has_selected = true;
			}
		}
		associations.push(association_node);
		if (!p.is_at(tokenizer::TokenId.COMMA)) break;
		p.advance();
	}
	if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, generic_tok)) return f~;

	if (!has_selected && default_entry.present)
	{
		// The default arm can only be known to be selected after all typed arms
		// have been read. Reparse it with eval enabled so its value is available.
		if (eval)
		{
			tokens::TokenIndex after_expression = p.tok_i;
			p.tok_i = default_entry.expression_start;
			parser_result::Result maybe_selected = self.parse_expr_prec(tokens::Precedence.ASSIGN, true)!;
			selected = maybe_selected;
			p.tok_i = after_expression;
			tree::Node default_node = default_entry.node.get(&p.tree);
			default_node.generic_default.expr = selected.node;
			p.tree.set_node(default_node, (sz)default_entry.node);
		}
		else
		{
			selected = { .node = default_entry.node, .qt = default_entry.qt, .val = default_entry.val };
		}
		selected_association = 0;
		foreach (i, association : associations)
		{
			if (association == default_entry.node) selected_association = (uint)i;
		}
		has_selected = true;
	}
	if (!has_selected)
	{
		// Deviation: Zig prints the invalid type (unreachable); it was already diagnosed.
		if (control.qt.is_invalid()) return PARSING_FAILED~;
		Diagnostic.GENERIC_NO_MATCH.@emit(p, generic_tok, p.fmt_qt(control.qt))!;
		return PARSING_FAILED~;
	}
	list::List{type_store::NodeIndex} rest;
	rest.init(p.comp.gpa);
	defer rest.free();
	foreach (i, association : associations)
	{
		if ((uint)i != selected_association) rest.push(association);
	}
	type_store::NodeIndex chosen = associations[(usz)selected_association];
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.GENERIC_EXPR, .generic = {
				.generic_tok = generic_tok, .qt = selected.qt, .controlling = control.node,
				.chosen = chosen, .rest = rest.array_view(),
		}
	}
	);
	return { .node = node, .qt = selected.qt, .val = selected.val };
}

<* `true`, `false` and `nullptr`. Out of line to keep `parse_primary_expr`, which
 is live across every nesting level, small. *>
fn parser_result::Result? parse_keyword_constant(parser::Parser* p, tokens::TokenIndex tok, tokenizer::TokenId id) @noinline
{
	if (id == tokenizer::TokenId.KEYWORD_TRUE || id == tokenizer::TokenId.KEYWORD_FALSE)
	{
		p.advance();
		bool truth = id == tokenizer::TokenId.KEYWORD_TRUE;
		type_store::NodeIndex node = p.tree.add_node(
			{
				.kind = tree::NodeKind.BOOL_LITERAL,
				.literal = { .literal_tok = tok, .qt = type_store::BOOL }
			}
		);
		value::Value val = truth ? value::ONE : value::ZERO;
		p.tree.set_value(node, val);
		return { .node = node, .qt = type_store::BOOL, .val = val };
	}
	if (id == tokenizer::TokenId.KEYWORD_NULLPTR)
	{
		p.advance();
		type_store::NodeIndex node = p.tree.add_node(
			{
				.kind = tree::NodeKind.NULLPTR_LITERAL,
				.literal = { .literal_tok = tok, .qt = type_store::NULLPTR_T }
			}
		);
		p.tree.set_value(node, value::NULL);
		return { .node = node, .qt = type_store::NULLPTR_T, .val = value::NULL };
	}
	unreachable();
}

<* Parse one primary-expression production. *>
fn parser_result::Result? Parser.parse_primary_expr(&self, bool eval = true)
{
	// Only `(` recurses; keep this frame minimal and parse the leaf forms out of line.
	parser::Parser* p = self;
	if (p.at_eof()) return NO_EXPRESSION~;
	tokens::TokenIndex tok = p.tok_i;
	if (p.tree.tokens[(usz)tok].id == tokenizer::TokenId.L_PAREN) return self.parse_group_or_cast(tok, eval);
	return self.parse_leaf(tok, eval);
}

<* Primary expressions other than parenthesized ones. *>
fn parser_result::Result? Parser.parse_leaf(&self, tokens::TokenIndex tok, bool eval) @noinline
{
	parser::Parser* p = self;
	tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
	if (id == tokenizer::TokenId.PP_NUM || id == tokenizer::TokenId.EMBED_BYTE)
	{
		return self.parse_number(tok);
	}
	if (id.is_char_literal()) return self.parse_char(tok);
	if (is_string_token(id)) return self.parse_string(tok);
	if (id == tokenizer::TokenId.KEYWORD_TRUE || id == tokenizer::TokenId.KEYWORD_FALSE || id == tokenizer::TokenId.KEYWORD_NULLPTR)
	{
		return parse_keyword_constant(p, tok, id);
	}
	if (id.is_identifier())
	{
		return self.parse_identifier(tok, eval);
	}
	if (id == tokenizer::TokenId.KEYWORD_GENERIC)
	{
		p.advance(); return self.parse_generic(tok, eval);
	}
	if (id == tokenizer::TokenId.MACRO_FUNC || id == tokenizer::TokenId.MACRO_FUNCTION)
	{
		return self.parse_predefined_identifier(tok, false);
	}
	if (id == tokenizer::TokenId.MACRO_PRETTY_FUNC) return self.parse_predefined_identifier(tok, true);
	return NO_EXPRESSION~;
}
