// GNU inline assembly statement grammar, separated from Parser's statement
// dispatcher. Expression and adjacent-string parsing remain caller supplied.
module aro::parser_asm;
import aro::parser, aro::parser_result, aro::tokens, aro::tokenizer, aro::tree, aro::type_store, aro::parser_diagnostics;
import std::collections::list;

excuse PARSING_FAILED;
<* Not positioned at an asm keyword (Zig `null`). *>
excuse NOT_ASM;

alias Expression = fn parser_result::Result?(void* context, parser::Parser* p, bool eval);
// Parses adjacent ordinary string literals and returns their string-literal node.
alias AsmString = fn type_store::NodeIndex?(void* context, parser::Parser* p);

struct AsmParser
{
	parser::Parser* parser;
	void* context;
	Expression expression;
	AsmString asm_string;
	bool has_expression;
	bool has_asm_string;
}

fn bool is_asm_keyword(tokenizer::TokenId id)
{
	return id == tokenizer::TokenId.KEYWORD_ASM || id == tokenizer::TokenId.KEYWORD_ASM1 || id == tokenizer::TokenId.KEYWORD_ASM2;
}

fn bool is_volatile_keyword(tokenizer::TokenId id)
{
	return id == tokenizer::TokenId.KEYWORD_VOLATILE || id == tokenizer::TokenId.KEYWORD_VOLATILE1 || id == tokenizer::TokenId.KEYWORD_VOLATILE2;
}

fn bool is_inline_keyword(tokenizer::TokenId id)
{
	return id == tokenizer::TokenId.KEYWORD_INLINE || id == tokenizer::TokenId.KEYWORD_INLINE1 || id == tokenizer::TokenId.KEYWORD_INLINE2;
}

fn bool any_string_token(tokenizer::TokenId id)
{
	return id == tokenizer::TokenId.STRING_LITERAL || id == tokenizer::TokenId.UNTERMINATED_STRING_LITERAL ||
		id == tokenizer::TokenId.STRING_LITERAL_UTF_16 || id == tokenizer::TokenId.STRING_LITERAL_UTF_8 ||
		id == tokenizer::TokenId.STRING_LITERAL_UTF_32 || id == tokenizer::TokenId.STRING_LITERAL_WIDE;
}

fn type_store::NodeIndex? AsmParser.parse_string(&self)
{
	if (!self.has_asm_string)
	{
		{ self.parser.expected_token_diag(tokenizer::TokenId.STRING_LITERAL)!; return PARSING_FAILED~; }
	}
	if (self.parser.at_eof()) { self.parser.expected_token_diag(tokenizer::TokenId.STRING_LITERAL)!; return PARSING_FAILED~; }
	tokenizer::TokenId id = self.parser.tree.tokens[(usz)self.parser.tok_i].id;
	if (!any_string_token(id))
	{
		{ self.parser.expected_token_diag(tokenizer::TokenId.STRING_LITERAL)!; return PARSING_FAILED~; }
	}
	if (id == tokenizer::TokenId.STRING_LITERAL_UTF_16 || id == tokenizer::TokenId.STRING_LITERAL_UTF_8 || id == tokenizer::TokenId.STRING_LITERAL_UTF_32)
	{
		self.parser.err(parser_diagnostics::ParserDiag.INVALID_ASM_STR, self.parser.tok_i, "unicode")!;
		return PARSING_FAILED~;
	}
	if (id == tokenizer::TokenId.STRING_LITERAL_WIDE)
	{
		self.parser.err(parser_diagnostics::ParserDiag.INVALID_ASM_STR, self.parser.tok_i, "wide")!;
		return PARSING_FAILED~;
	}
	return self.asm_string(self.context, self.parser);
}

fn tree::AsmOperand? AsmParser.parse_operand(&self, bool output)
{
	parser::Parser* p = self.parser;
	tokens::TokenIndex name = 0;
	if (p.is_at(tokenizer::TokenId.L_BRACKET))
	{
		p.advance();
		if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
		{
			{ p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~; }
		}
		name = p.tok_i;
		p.advance();
		if (catch p.expect_closing(tokenizer::TokenId.R_BRACKET, name - 1)) return PARSING_FAILED~;
	}
	if (p.at_eof() || !any_string_token(p.tree.tokens[(usz)p.tok_i].id)) { p.expected_token_diag(tokenizer::TokenId.STRING_LITERAL)!; return PARSING_FAILED~; }
	type_store::NodeIndex? maybe_constraint = self.parse_string();
	if (catch caught_fault = maybe_constraint) return caught_fault~;
	type_store::NodeIndex constraint = maybe_constraint;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	tokens::TokenIndex lparen = p.tok_i - 1;
	if (!self.has_expression) { p.grammar_unavailable()!; return PARSING_FAILED~; }
	parser_result::Result? maybe_result = self.expression(self.context, p, true);
	if (catch caught_fault = maybe_result) return caught_fault~;
	parser_result::Result result = maybe_result;
	if (output && !p.tree.is_lval(result.node))
	{
		p.err(parser_diagnostics::ParserDiag.INVALID_ASM_OUTPUT, lparen + 1)!;
	}
	else if (!output) { result.lval_conversion(p); }
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, lparen)) return PARSING_FAILED~;
	return { .name = name, .constraint = constraint, .expr = result.node };
}

// Parse a GNU asm statement beginning at asm/__asm/__asm__. On success the
// returned node is the ASM_STMT node, and the trailing semicolon is consumed.
fn type_store::NodeIndex? AsmParser.parse_statement(&self)
{
	parser::Parser* p = self.parser;
	if (p.at_eof()) return NOT_ASM~;
	if (!is_asm_keyword(p.tree.tokens[(usz)p.tok_i].id)) return NOT_ASM~;
	tokens::TokenIndex asm_tok = p.tok_i;
	if (p.tree.tokens[(usz)asm_tok].id == tokenizer::TokenId.KEYWORD_ASM)
	{
		p.err(parser_diagnostics::ParserDiag.EXTENSION_TOKEN_USED, asm_tok)!;
	}
	p.advance();
	tree::GnuAsmQualifiers quals = {};
	while (true)
	{
		if (p.at_eof()) break;
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		if (is_volatile_keyword(id))
		{
			if (quals.is_volatile) p.err(parser_diagnostics::ParserDiag.DUPLICATE_ASM_QUAL, p.tok_i, "volatile")!;
			quals.is_volatile = true;
			p.advance();
		}
		else if (is_inline_keyword(id))
		{
			if (quals.is_inline) p.err(parser_diagnostics::ParserDiag.DUPLICATE_ASM_QUAL, p.tok_i, "inline")!;
			quals.is_inline = true;
			p.advance();
		}
		else if (id == tokenizer::TokenId.KEYWORD_GOTO)
		{
			if (quals.is_goto) p.err(parser_diagnostics::ParserDiag.DUPLICATE_ASM_QUAL, p.tok_i, "goto")!;
			quals.is_goto = true;
			p.advance();
		}
		else { break; }
	}
	if (!p.is_at(tokenizer::TokenId.L_PAREN))
	{
		// Parser.zig leaves MSVC asm as a TODO. Preserve that boundary here.
		{ p.expected_token_diag(tokenizer::TokenId.L_PAREN)!; return PARSING_FAILED~; }
	}
	p.advance();
	type_store::NodeIndex? maybe_asm_str = self.parse_string();
	if (catch caught_fault = maybe_asm_str) return caught_fault~;
	type_store::NodeIndex asm_str = maybe_asm_str;
	list::List{tree::AsmOperand} outputs;
	outputs.init(p.comp.gpa);
	defer outputs.free();
	list::List{tree::AsmOperand} inputs;
	inputs.init(p.comp.gpa);
	defer inputs.free();
	list::List{type_store::NodeIndex} clobbers;
	clobbers.init(p.comp.gpa);
	defer clobbers.free();
	list::List{type_store::NodeIndex} labels;
	labels.init(p.comp.gpa);
	defer labels.free();
	bool extra_colon = false;
	if (p.is_at(tokenizer::TokenId.R_PAREN))
	{
		if (quals.is_goto) { p.expected_token_diag(tokenizer::TokenId.COLON)!; return PARSING_FAILED~; }
		p.advance();
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		return p.tree.add_node({ .kind = tree::NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = asm_tok, .asm_str = asm_str, .quals = quals } });
	}
	if (p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.COLON_COLON))
	{
		extra_colon = p.is_at(tokenizer::TokenId.COLON_COLON);
		p.advance();
		if (!extra_colon && ((!p.at_eof() && any_string_token(p.tree.tokens[(usz)p.tok_i].id)) || p.is_at(tokenizer::TokenId.L_BRACKET)))
		{
			while (true)
			{
				tree::AsmOperand? maybe_op = self.parse_operand(true);
				if (catch caught_fault = maybe_op) return caught_fault~;
				outputs.push(maybe_op);
				if (!p.eat(tokenizer::TokenId.COMMA).has_value) break;
			}
		}
	}
	if (extra_colon || p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.COLON_COLON))
	{
		if (extra_colon) { extra_colon = false; }
		else { extra_colon = p.is_at(tokenizer::TokenId.COLON_COLON); p.advance(); }
		if (!extra_colon && ((!p.at_eof() && any_string_token(p.tree.tokens[(usz)p.tok_i].id)) || p.is_at(tokenizer::TokenId.L_BRACKET)))
		{
			while (true)
			{
				tree::AsmOperand? maybe_op = self.parse_operand(false);
				if (catch caught_fault = maybe_op) return caught_fault~;
				inputs.push(maybe_op);
				if (!p.eat(tokenizer::TokenId.COMMA).has_value) break;
			}
		}
	}
	if (extra_colon || p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.COLON_COLON))
	{
		if (extra_colon) { extra_colon = false; }
		else { extra_colon = p.is_at(tokenizer::TokenId.COLON_COLON); p.advance(); }
		if (!extra_colon && !p.at_eof() && any_string_token(p.tree.tokens[(usz)p.tok_i].id))
		{
			while (true)
			{
				type_store::NodeIndex? maybe_clobber = self.parse_string();
				if (catch caught_fault = maybe_clobber) return caught_fault~;
				clobbers.push(maybe_clobber);
				if (!p.eat(tokenizer::TokenId.COMMA).has_value) break;
			}
		}
	}
	if (!quals.is_goto && (!p.is_at(tokenizer::TokenId.R_PAREN) || extra_colon)) { p.expected_token_diag(tokenizer::TokenId.R_PAREN)!; return PARSING_FAILED~; }
	if (extra_colon || p.is_at(tokenizer::TokenId.COLON))
	{
		if (!extra_colon) p.advance();
		while (true)
		{
			if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER)) { p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~; }
			tokens::TokenIndex label_tok = p.tok_i;
			labels.push(p.tree.add_node({ .kind = tree::NodeKind.ADDR_OF_LABEL, .addr_of_label = { .label_tok = label_tok, .qt = type_store::VOID_POINTER } }));
			p.advance();
			if (!p.eat(tokenizer::TokenId.COMMA).has_value) break;
		}
	}
	else if (quals.is_goto) { { p.expected_token_diag(tokenizer::TokenId.COLON)!; return PARSING_FAILED~; } }
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, asm_tok + 1)) return PARSING_FAILED~;
	if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	return p.tree.add_node({ .kind = tree::NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = asm_tok, .asm_str = asm_str, .outputs = outputs.array_view(), .inputs = inputs.array_view(), .clobbers = clobbers.array_view(), .labels = labels.array_view(), .quals = quals } });
}
