// Primary-expression grammar for the typed C3 parser. The owning expression
// engine supplies nested expression parsing, while compound literal
// initialization is an optional outer-grammar seam.
module aro::parser_primary;
import aro::parser, aro::parser_result, aro::parser_diagnostics, aro::tree;
import aro::tokens, aro::tokenizer, aro::type_store, aro::value, aro::value_interner;
import aro::number_value, aro::text_literal, aro::text_literal_semantics;
import aro::symbol_stack, aro::string_interner;
import aro::diagnostics, aro::parser_expression;
import aro::builtins, aro::builtin_properties, aro::lang_opts;
import std::collections::list;
import std::core::dstring;

excuse PARSING_FAILED;
excuse CANNOT_CONCAT;

struct PrimaryParser
{
	parser::Parser* parser;
	<* `parse_nested` (required for parenthesized and cast operands) and the
	   optional `parse_compound_literal`. *>
	parser::IExpressionParts parts;
}

fn parser_result::Result? PrimaryParser.nested(&self, tokens::Precedence min_prec, bool eval)
{
	parser::IExpressionParts g = self.parts;
	if (!g || !&g.parse_nested) { self.parser.grammar_unavailable()!; return PARSING_FAILED~; }
	return g.parse_nested(self.parser, min_prec, eval);
}

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
		case CHAR: case UNTERMINATED: return tree::CharLiteralKind.ASCII;
	}
}

fn void? emit_number_diags(parser::Parser* p, number_value::NumberValueDiags diags, tokens::TokenIndex tok)
{
	foreach (diag : diags.slice())
	{
		switch (diag)
		{
			case INT_LITERAL_TOO_BIG: p.err(parser_diagnostics::ParserDiag.INT_LITERAL_TOO_BIG, tok)!;
			case IMPLICITLY_UNSIGNED_LITERAL: p.err(parser_diagnostics::ParserDiag.IMPLICITLY_UNSIGNED_LITERAL, tok)!;
			case GNU_IMAGINARY_CONSTANT: p.err(parser_diagnostics::ParserDiag.GNU_IMAGINARY_CONSTANT, tok)!;
			case FLOAT_LITERAL_IN_EXPR: p.err(parser_diagnostics::ParserDiag.FLOAT_LITERAL_IN_EXPR, tok)!;
			case HEX_FLOAT_NO_SIGNIFICAND: p.err(parser_diagnostics::ParserDiag.HEX_FLOAT_NO_SIGNIFICAND, tok)!;
		}
	}
}

fn parser_result::Result? unavailable(parser::Parser* p, String message, tokens::TokenIndex tok)
{
	p.err(parser_diagnostics::ParserDiag.PRIMARY_UNAVAILABLE, tok, message)!;
	return PARSING_FAILED~;
}

fn parser_result::Result? expected_expression(parser::Parser* p)
{
	p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_EXPR, "expected expression", p.diag_index())!;
	return PARSING_FAILED~;
}

fn bool is_builtin_name(String name) => name.len >= 10 && name[0:10] == "__builtin_";

<* Zig primaryExpr's builtin lookup and implicit function declaration path. *>
fn parser_result::Result? PrimaryParser.parse_unresolved_identifier(&self,
	tokens::TokenIndex tok, string_interner::StringId name_id, String name)
{
	parser::Parser* p = self.parser;
	builtins::Expanded? maybe_builtin = p.comp.builtins.get_or_create(p.comp, name);
	if (try expanded = maybe_builtin)
	{
		usz lookahead = 1;
		while (p.is_at(tokenizer::TokenId.R_PAREN, lookahead)) lookahead++;
		if (!p.is_at(tokenizer::TokenId.L_PAREN, lookahead))
		{
			p.err(parser_diagnostics::ParserDiag.BUILTIN_MUST_BE_CALLED, tok)!;
			return PARSING_FAILED~;
		}
		if (expanded.header != builtin_properties::Header.NONE)
		{
			p.err(parser_diagnostics::ParserDiag.IMPLICIT_BUILTIN, tok,
				name)!;
			p.err(parser_diagnostics::ParserDiag.IMPLICIT_BUILTIN_HEADER_NOTE, tok,
				expanded.header.name, name)!;
		}
		p.advance();
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.BUILTIN_REF,
			.builtin_ref = { .name_tok = tok, .qt = expanded.qt } });
		return { .node = node, .qt = expanded.qt, .val = value::NONE };
	}

	bool direct_call = p.is_at(tokenizer::TokenId.L_PAREN, 1);
	if (direct_call && !p.comp.langopts.standard.at_least(lang_opts::Standard.C23))
	{
		if (is_builtin_name(name))
		{
			p.err(parser_diagnostics::ParserDiag.UNKNOWN_BUILTIN, tok, name)!;
		}
		else
		{
			p.err(parser_diagnostics::ParserDiag.IMPLICIT_FUNC_DECL, tok, name)!;
		}
		type_store::QualType function_qt = p.comp.type_store.put(type_store::type_func(
			type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		type_store::NodeIndex function_node = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION,
			.function = { .name_tok = tok, .qt = function_qt, .is_static = false,
				.is_inline = false, .body = type_store::NODE_NULL, .definition = type_store::NODE_NULL } });
		p.tree.root_decls.push(function_node);
		symbol_stack::SymbolContext sym_ctx = p.symbol_context();
		p.symbols.declare_symbol(&sym_ctx, name_id, function_qt, tok, function_node)!;
		p.advance();
		type_store::NodeIndex ref_node = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
			.decl_ref = { .name_tok = tok, .qt = function_qt, .decl = function_node } });
		return { .node = ref_node, .qt = function_qt, .val = value::NONE };
	}

	p.err(parser_diagnostics::ParserDiag.UNDECLARED_IDENTIFIER, tok, name)!;
	return PARSING_FAILED~;
}

<* Create a static const character array backing a predefined function-name identifier. *>
fn type_store::NodeIndex PrimaryParser.make_predefined_identifier(&self, tokens::TokenIndex tok,
	String contents)
{
	parser::Parser* p = self.parser;
	DString bytes;
	bytes.init(tmem);
	bytes.append_string(contents);
	bytes.append_char('\0');
	char[] data = (char[])bytes.str_view();
	value::Value val = value::intern(p.comp, { .tag = value_interner::InternerKeyTag.BYTES,
		.bytes = data });
	type_store::QualType char_qt = type_store::CHAR;
	char_qt.is_const = true;
	type_store::QualType array_qt = p.comp.type_store.put(type_store::type_array(char_qt,
		type_store::ArrayLenKind.FIXED, (ulong)data.len));
	type_store::NodeIndex string_node = p.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .literal_tok = tok, .qt = array_qt, .kind = tree::CharLiteralKind.ASCII } });
	p.tree.set_value(string_node, val);
	return p.tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = {
		.name_tok = tok, .qt = array_qt, .storage_class = tree::VariableStorageClass.STATIC,
		.thread_local = false, .implicit = true, .initializer = string_node.pack(),
		.definition = type_store::NODE_NULL } });
}

fn parser_result::Result? PrimaryParser.parse_predefined_identifier(&self,
	tokens::TokenIndex tok, bool pretty)
{
	parser::Parser* p = self.parser;
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
				p.function_context.function_qt.print_named(function_name, p.comp, &contents);
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
	if (!in_function) p.err(parser_diagnostics::ParserDiag.PREDEFINED_TOP_LEVEL, tok)!;
	p.advance();
	type_store::NodeIndex declaration = ident.unwrap();
	tree::Node variable = declaration.get(&p.tree);
	tokens::TokenIndex name_tok = pretty ? tok : variable.variable.name_tok;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR,
		.decl_ref = { .name_tok = name_tok, .qt = variable.variable.qt, .decl = declaration } });
	return { .node = node, .qt = variable.variable.qt, .val = value::NONE };
}

fn parser_result::Result? PrimaryParser.parse_number(&self, tokens::TokenIndex tok)
{
	parser::Parser* p = self.parser;
	tokens::TreeToken token = p.tree.tokens[(usz)tok];
	number_value::NumberValue number = number_value::parse_number_token(p.comp,
		p.tree.tok_slice(tok), token.loc, p.pp.expansion_slice(tok))!;
	p.advance();
	emit_number_diags(p, number.diags, tok)!;
	tree::NodeKind literal_kind = number.literal_qt.is_int(p.comp) ? tree::NodeKind.INT_LITERAL : tree::NodeKind.FLOAT_LITERAL;
	type_store::NodeIndex literal = p.tree.add_node({ .kind = literal_kind, .literal = {
		.literal_tok = tok, .qt = number.literal_qt,
	} });
	if (!number.literal_val.is_none()) p.tree.set_value(literal, number.literal_val);
	type_store::NodeIndex node = literal;
	if (number.is_imaginary)
	{
		node = p.tree.add_node({ .kind = tree::NodeKind.IMAGINARY_LITERAL, .unary = {
			.qt = number.qt, .operand = literal, .op_tok = tok,
		} });
	}
	return { .node = node, .qt = number.qt, .val = number.val };
}

fn parser_result::Result? PrimaryParser.parse_char(&self, tokens::TokenIndex tok)
{
	parser::Parser* p = self.parser;
	tokens::TreeToken token = p.tree.tokens[(usz)tok];
	text_literal_semantics::CharLiteral literal = text_literal_semantics::char_literal(p.comp,
		token.id, p.tree.tok_slice(tok), token.loc, p.pp.expansion_slice(tok))!;
	p.advance();
	if (literal.has_diag)
	{
		switch (literal.diag)
		{
			case UNSUPPORTED_STR_CAT: p.err(parser_diagnostics::ParserDiag.UNSUPPORTED_STR_CAT, tok)!;
			case EMPTY_CHAR_LITERAL_ERROR: p.err(parser_diagnostics::ParserDiag.EMPTY_CHAR_LITERAL_ERROR, tok)!;
			case UNTERMINATED_CHAR_LITERAL_ERROR: p.err(parser_diagnostics::ParserDiag.UNTERMINATED_CHAR_LITERAL_ERROR, tok)!;
		}
	}
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.CHAR_LITERAL, .char_literal = {
		.literal_tok = tok, .qt = literal.qt, .kind = char_kind(literal.kind),
	} });
	p.tree.set_value(node, literal.val);
	return { .node = node, .qt = literal.qt, .val = literal.val };
}

fn parser_result::Result? PrimaryParser.parse_string(&self, tokens::TokenIndex start)
{
	parser::Parser* p = self.parser;
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
		pieces.push({ .id = token.id, .bytes = p.tree.tok_slice(end), .loc = token.loc,
			.expansion_locs = p.pp.expansion_slice(end) });
		end++;
	}
	sz error_index = 0;
	text_literal_semantics::StringRun? maybe_run = text_literal_semantics::string_run(ids.array_view(), &error_index);
	if (catch run_fault = maybe_run)
	{
		if (run_fault == text_literal::CANNOT_CONCAT)
		{
			p.emit_parser_diag(parser_diagnostics::ParserDiag.UNSUPPORTED_STR_CAT,
				"unsupported string literal concatenation", start + (uint)error_index)!;
		}
		p.tok_i = start + (uint)error_index + 1;
		return PARSING_FAILED~;
	}
	text_literal_semantics::StringRun run = maybe_run;
	text_literal_semantics::StringLiteral literal = text_literal_semantics::string_literal(p.comp,
		pieces.array_view()[:run.len], run.kind)!;
	p.tok_i = start + (uint)run.len;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR, .char_literal = {
		.literal_tok = start, .qt = literal.qt, .kind = char_kind(literal.kind),
	} });
	p.tree.set_value(node, literal.val);
	return { .node = node, .qt = literal.qt, .val = literal.val };
}

fn parser_result::Result? PrimaryParser.parse_identifier(&self, tokens::TokenIndex tok, bool eval)
{
	parser::Parser* p = self.parser;
	String name = p.tree.tok_slice(tok);
	string_interner::StringId name_id = p.comp.intern_string(name);
	symbol_stack::Symbol? maybe_symbol = p.find_symbol(name_id);
	if (catch maybe_symbol)
	{
		return self.parse_unresolved_identifier(tok, name_id, name);
	}
	symbol_stack::Symbol symbol = maybe_symbol;
	if (p.auto_type_decl.active && name_id == p.auto_type_decl.name &&
		symbol.node == p.auto_type_decl.node)
	{
		p.advance();
		DString message;
		message.init(tmem);
		message.appendf("variable '%s' declared with deduced type '__auto_type' cannot appear in its own initializer", name);
		p.emit_parser_diag(parser_diagnostics::ParserDiag.AUTO_TYPE_SELF_INITIALIZED, message.str_view(), tok)!;
		return PARSING_FAILED~;
	}
	p.advance();
	if (symbol.kind == symbol_stack::SymbolKind.TYPEDEF)
	{
		String message = string::tformat("unexpected type name '%s': expected expression", name);
		p.emit_parser_diag(parser_diagnostics::ParserDiag.UNEXPECTED_TYPE_NAME, message, tok)!;
		return PARSING_FAILED~;
	}
	p.mark_used(symbol.node);
	tree::NodeKind kind = symbol.kind == symbol_stack::SymbolKind.ENUMERATION ?
		tree::NodeKind.ENUMERATION_REF : tree::NodeKind.DECL_REF_EXPR;
	type_store::NodeIndex node = p.tree.add_node({ .kind = kind, .decl_ref = {
		.name_tok = tok, .qt = symbol.qt, .decl = symbol.node,
	} });
	value::Value val = value::NONE;
	if (symbol.kind == symbol_stack::SymbolKind.ENUMERATION)
	{
		val = p.referenced_integer_constant(symbol.val,
			symbol.val.is(value_interner::InternerKeyTag.INT, p.comp), true, tok);
	}
	else if (symbol.kind == symbol_stack::SymbolKind.CONSTEXPR)
	{
		val = symbol.val;
	}
	else if (symbol.kind == symbol_stack::SymbolKind.DEF && symbol.qt.is_const &&
		!symbol.val.is_none())
	{
		val = p.referenced_integer_constant(symbol.val,
			symbol.val.is(value_interner::InternerKeyTag.INT, p.comp), false, tok);
	}
	if (!val.is_none()) p.tree.set_value(node, val);
	return { .node = node, .qt = symbol.qt, .val = val };
}

fn parser_result::Result? PrimaryParser.parse_group_or_cast(&self, tokens::TokenIndex l_paren, bool eval)
{
	parser::Parser* p = self.parser;
	p.advance();
	parser::TypeNameProbe probe = p.probe_typed_type_name()!;
	if (probe.matched)
	{
		if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
		if (p.is_at(tokenizer::TokenId.L_BRACE))
		{
			parser::IExpressionParts g = self.parts;
			if (g && &g.parse_compound_literal)
			{
				parser_result::Result? literal = g.parse_compound_literal(p, l_paren, probe.qt, eval);
				if (catch f = literal) { if (f != parser::HOOK_ABSENT) return f~; } else { return literal; }
			}
			return unavailable(p, "compound literal expressions are unavailable in this parser composition", l_paren);
		}
		// A cast-expression is a unary expression or another cast-expression.
		tokens::Precedence unary_only = (tokens::Precedence)((ichar)tokens::PREC_MULTIPLICATIVE + 1);
		parser_result::Result? maybe_operand = self.nested(unary_only, eval);
		if (catch f = maybe_operand)
		{
			if (f == parser_expression::NO_EXPRESSION) return expected_expression(p);
			return f~;
		}
		parser_result::Result operand = maybe_operand;
		type_store::QualType source_qt = operand.qt;
		bool maybe_cast = operand.explicit_cast(p, probe.qt, l_paren)!;
		if (!maybe_cast)
		{
			parser_diagnostics::ParserDiag diag;
			type_store::QualType diag_qt = source_qt;
			if (probe.qt.is_pointer(p.comp))
			{
				diag = parser_diagnostics::ParserDiag.INVALID_CAST_TO_POINTER;
			}
			else if (source_qt.is_pointer(p.comp) && probe.qt.is_float(p.comp))
			{
				diag = parser_diagnostics::ParserDiag.INVALID_CAST_TO_FLOAT;
				diag_qt = probe.qt;
			}
			else if (probe.qt.is_int(p.comp) || probe.qt.is_float(p.comp))
			{
				diag = parser_diagnostics::ParserDiag.INVALID_CAST_OPERAND_TYPE;
			}
			else
			{
				diag = parser_diagnostics::ParserDiag.INVALID_CAST_TYPE;
				diag_qt = probe.qt;
			}
			p.err_dyn(diag, l_paren, p.fmt_qt(diag_qt))!;
			return PARSING_FAILED~;
		}
		return operand;
	}
	if (p.is_at(tokenizer::TokenId.L_BRACE)) { return unavailable(p, "statement expressions are unavailable in this parser composition", l_paren); }
	parser_result::Result? maybe_inside = self.nested(tokens::PREC_ANY, eval);
	if (catch f = maybe_inside)
	{
		if (f == parser_expression::NO_EXPRESSION) return expected_expression(p);
		return f~;
	}
	parser_result::Result inside = maybe_inside;
	if (catch f = p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return f~;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.PAREN_EXPR, .unary = {
		.qt = inside.qt, .operand = inside.node, .op_tok = l_paren,
	} });
	return { .node = node, .qt = inside.qt, .val = inside.val };
}

fn parser_result::Result? PrimaryParser.parse_generic(&self, tokens::TokenIndex generic_tok, bool eval)
{
	parser::Parser* p = self.parser;
	if (catch f = p.expect(tokenizer::TokenId.L_PAREN)) return f~;
	parser_result::Result? maybe_control = self.nested(tokens::PREC_CONDITIONAL, false);
	if (catch f = maybe_control)
	{
		if (f == parser_expression::NO_EXPRESSION) return expected_expression(p);
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
				p.emit_parser_diag(parser_diagnostics::ParserDiag.GENERIC_DUPLICATE_DEFAULT,
					"duplicate default generic association", association_tok)!;
				p.emit_parser_diag(parser_diagnostics::ParserDiag.PREVIOUS_CASE,
					"previous default generic association is here", default_entry.tok)!;
			}
		}
		else
		{
			association_tok = p.tok_i;
			parser::TypeNameProbe probe = p.probe_typed_type_name()!;
			if (!probe.matched)
			{
				// Match Parser.zig: a missing association before any arm is parsed is "expected a type".
				if (associations.len() == 0)
				{
					p.err(parser_diagnostics::ParserDiag.EXPECTED_TYPE, p.diag_index())!;
				}
				else
				{
					p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_EXPR,
						"expected a type-name or 'default' in generic association", p.diag_index())!;
				}
				return PARSING_FAILED~;
			}
			association_qt = probe.qt;
			if (association_qt.is_qualified()) {
				p.err(parser_diagnostics::ParserDiag.GENERIC_QUAL_TYPE, association_tok)!;
			}
			if (association_qt.is(p.comp, type_store::TypeTag.ARRAY)) {
				p.err(parser_diagnostics::ParserDiag.GENERIC_ARRAY_TYPE, association_tok)!;
			}
			if (association_qt.is(p.comp, type_store::TypeTag.FUNC)) {
				p.err(parser_diagnostics::ParserDiag.GENERIC_FUNC_TYPE, association_tok)!;
			}
			foreach (previous : types)
			{
				if (association_qt.eql(previous.qt, p.comp))
				{
					p.err(parser_diagnostics::ParserDiag.GENERIC_DUPLICATE, association_tok,
						p.fmt_qt(association_qt))!;
					p.err(parser_diagnostics::ParserDiag.GENERIC_DUPLICATE_HERE, previous.tok,
						p.fmt_qt(previous.qt))!;
					break;
				}
			}
			types.push({ .qt = association_qt, .tok = association_tok });
		}
		if (catch f = p.expect(tokenizer::TokenId.COLON)) return f~;
		tokens::TokenIndex colon_tok = p.tok_i - 1;
		tokens::TokenIndex expression_start = p.tok_i;
		bool is_match = !is_default && !has_match && association_qt.eql(control.qt, p.comp);
		bool evaluate_arm = is_match && eval;
		parser_result::Result? maybe_arm = self.nested(tokens::PREC_ASSIGN, evaluate_arm);
		if (catch f = maybe_arm)
		{
			if (f == parser_expression::NO_EXPRESSION) return expected_expression(p);
			return f~;
		}
		parser_result::Result arm = maybe_arm;
		tokens::TokenIndex expression_end = p.tok_i;
		type_store::NodeIndex association_node;
		if (is_default)
		{
			association_node = p.tree.add_node({ .kind = tree::NodeKind.GENERIC_DEFAULT_EXPR,
				.generic_default = { .default_tok = association_tok, .expr = arm.node } });
			if (!default_entry.present)
			{
				default_entry = { .present = true, .node = association_node, .tok = association_tok,
					.expression_start = expression_start,
					.qt = arm.qt, .val = arm.val };
			}
		}
		else
		{
			association_node = p.tree.add_node({ .kind = tree::NodeKind.GENERIC_ASSOCIATION_EXPR,
				.generic_association = { .colon_tok = colon_tok,
					.association_qt = association_qt, .expr = arm.node } });
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
			parser_result::Result maybe_selected = self.nested(tokens::PREC_ASSIGN, true)!;
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
		p.err(parser_diagnostics::ParserDiag.GENERIC_NO_MATCH, generic_tok, p.fmt_qt(control.qt))!;
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
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.GENERIC_EXPR, .generic = {
		.generic_tok = generic_tok, .qt = selected.qt, .controlling = control.node,
		.chosen = chosen, .rest = rest.array_view(),
	} });
	return { .node = node, .qt = selected.qt, .val = selected.val };
}

<* Parse one primary-expression production. *>
fn parser_result::Result? PrimaryParser.parse(&self, bool eval = true)
{
	parser::Parser* p = self.parser;
	if (p.at_eof()) return parser_expression::NO_EXPRESSION~;
	tokens::TokenIndex tok = p.tok_i;
	tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
	if (id == tokenizer::TokenId.PP_NUM || id == tokenizer::TokenId.EMBED_BYTE) { return self.parse_number(tok); }
	if (id.is_char_literal()) return self.parse_char(tok);
	if (is_string_token(id)) return self.parse_string(tok);
	if (id == tokenizer::TokenId.KEYWORD_TRUE || id == tokenizer::TokenId.KEYWORD_FALSE)
	{
		p.advance();
		bool truth = id == tokenizer::TokenId.KEYWORD_TRUE;
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.BOOL_LITERAL,
			.literal = { .literal_tok = tok, .qt = type_store::BOOL } });
		value::Value val = truth ? value::ONE : value::ZERO;
		p.tree.set_value(node, val);
		return { .node = node, .qt = type_store::BOOL, .val = val };
	}
	if (id == tokenizer::TokenId.KEYWORD_NULLPTR)
	{
		p.advance();
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.NULLPTR_LITERAL,
			.literal = { .literal_tok = tok, .qt = type_store::NULLPTR_T } });
		p.tree.set_value(node, value::NULL);
		return { .node = node, .qt = type_store::NULLPTR_T, .val = value::NULL };
	}
	if (id.is_identifier())
	{
		return self.parse_identifier(tok, eval);
	}
	if (id == tokenizer::TokenId.KEYWORD_GENERIC) { p.advance(); return self.parse_generic(tok, eval); }
	if (id == tokenizer::TokenId.L_PAREN) return self.parse_group_or_cast(tok, eval);
	if (id == tokenizer::TokenId.MACRO_FUNC || id == tokenizer::TokenId.MACRO_FUNCTION)
	{
		return self.parse_predefined_identifier(tok, false);
	}
	if (id == tokenizer::TokenId.MACRO_PRETTY_FUNC) return self.parse_predefined_identifier(tok, true);
	return parser_expression::NO_EXPRESSION~;
}
