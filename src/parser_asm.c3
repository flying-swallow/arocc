// GNU inline assembly statement grammar, separated from Parser's statement
// dispatcher. Expression and adjacent-string parsing remain caller supplied.
module aro::parser_asm;
import aro::parser, aro::parser_result, aro::parser_primary, aro::tokens, aro::tokenizer, aro::tree, aro::type_store, aro::parser_diagnostics, aro::value;
import std::collections::list;

excuse PARSING_FAILED;

alias Expression = fn parser_result::Result?(void* context, parser::Parser* p, bool eval);
// Parses adjacent ordinary string literals and returns their string-literal node.
alias AsmString = fn type_store::NodeIndex?(void* context, parser::Parser* p);

<* GNU asm statement grammar. Operand expressions and asm strings come from the
   owner's `expression` / `asm_string` callbacks. A null `expression` means
   operands are unavailable; a null `asm_string` uses `default_asm_string`.
   `parser` is set on each `parse_asm_statement` call. *>
struct AsmParser (parser::IAsmParser)
{
	parser::Parser* parser;
	void* context;
	Expression expression;
	AsmString asm_string;
}

fn type_store::NodeIndex? AsmParser.parse_asm_statement(&self, parser::Parser* p) @dynamic
{
	self.parser = p;
	return self.parse_statement();
}

fn type_store::NodeIndex? AsmParser.parse_string(&self)
{
	if (self.parser.at_eof())
	{
		self.parser.expected_token_diag(tokenizer::TokenId.STRING_LITERAL)!; return PARSING_FAILED~;
	}
	tokenizer::TokenId id = self.parser.tree.tokens[(usz)self.parser.tok_i].id;
	if (!parser_primary::is_string_token(id))
	{
		{
			self.parser.expected_token_diag(tokenizer::TokenId.STRING_LITERAL)!; return PARSING_FAILED~;
		}
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
	if (!self.asm_string) return default_asm_string(self.context, self.parser);
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
			{
				p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~;
			}
		}
		name = p.tok_i;
		p.advance();
		if (catch p.expect_closing(tokenizer::TokenId.R_BRACKET, name - 1)) return PARSING_FAILED~;
	}
	if (p.at_eof() || !parser_primary::is_string_token(p.tree.tokens[(usz)p.tok_i].id))
	{
		p.expected_token_diag(tokenizer::TokenId.STRING_LITERAL)!; return PARSING_FAILED~;
	}
	type_store::NodeIndex constraint = self.parse_string()!;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	tokens::TokenIndex lparen = p.tok_i - 1;
	if (!self.expression)
	{
		p.grammar_unavailable()!; return PARSING_FAILED~;
	}
	parser_result::Result result = self.expression(self.context, p, true)!;
	if (output && !p.tree.is_lval(result.node))
	{
		p.err(parser_diagnostics::ParserDiag.INVALID_ASM_OUTPUT, lparen + 1)!;
	}
	else if (!output)
	{
		result.lval_conversion(p);
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, lparen)) return PARSING_FAILED~;
	return { .name = name, .constraint = constraint, .expr = result.node };
}

<* Zig `assembly(kind)`'s context: which construct the asm keyword introduces. *>
enum AsmKind : char
{
	GLOBAL, DECL_LABEL, STMT
}

<*
 Zig `assembly` prefix: consume `asm`/`__asm`/`__asm__`, its qualifiers and the
 opening parenthesis. Qualifiers outside a statement are diagnosed as
 meaningless. Returns NOT_ASM (consuming nothing) when not at an asm keyword.
*>
fn tokens::TokenIndex? parse_asm_prefix(parser::Parser* p, AsmKind kind, tree::GnuAsmQualifiers* quals)
{
	if (p.at_eof()) return parser::NOT_ASM~;
	if (!(p.tree.tokens[(usz)p.tok_i].id.canonical() == KEYWORD_ASM)) return parser::NOT_ASM~;
	tokens::TokenIndex asm_tok = p.tok_i;
	if (p.tree.tokens[(usz)asm_tok].id == tokenizer::TokenId.KEYWORD_ASM)
	{
		p.err(parser_diagnostics::ParserDiag.EXTENSION_TOKEN_USED, asm_tok)!;
	}
	p.advance();
	*quals = {};
	while (!p.at_eof())
	{
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		String name;
		if (id.canonical() == KEYWORD_VOLATILE)
		{
			name = "volatile";
			if (quals.is_volatile) p.err(parser_diagnostics::ParserDiag.DUPLICATE_ASM_QUAL, p.tok_i, name)!;
			quals.is_volatile = true;
		}
		else if (id.canonical() == KEYWORD_INLINE)
		{
			name = "inline";
			if (quals.is_inline) p.err(parser_diagnostics::ParserDiag.DUPLICATE_ASM_QUAL, p.tok_i, name)!;
			quals.is_inline = true;
		}
		else if (id == tokenizer::TokenId.KEYWORD_GOTO)
		{
			name = "goto";
			if (quals.is_goto) p.err(parser_diagnostics::ParserDiag.DUPLICATE_ASM_QUAL, p.tok_i, name)!;
			quals.is_goto = true;
		}
		else
		{
			break;
		}
		if (kind != AsmKind.STMT) p.err(parser_diagnostics::ParserDiag.MEANINGLESS_ASM_QUAL, p.tok_i, name)!;
		p.advance();
	}
	if (!p.is_at(tokenizer::TokenId.L_PAREN))
	{
		// Parser.zig leaves MSVC asm as a TODO. Preserve that boundary here.
		p.expected_token_diag(tokenizer::TokenId.L_PAREN)!;
		return PARSING_FAILED~;
	}
	p.advance();
	return asm_tok;
}

<*
 Zig `asmStr`: one or more adjacent ordinary string literals; unicode and wide
 literals are rejected. Returns the string-literal result.
*>
fn parser_result::Result? parse_asm_string(parser::Parser* p)
{
	tokens::TokenIndex i = p.tok_i;
	for (; i < p.tok_end && parser_primary::is_string_token(p.tree.tokens[(usz)i].id); i++)
	{
		switch (p.tree.tokens[(usz)i].id)
		{
			case STRING_LITERAL_UTF_16:
			case STRING_LITERAL_UTF_8:
			case STRING_LITERAL_UTF_32:
				p.err(parser_diagnostics::ParserDiag.INVALID_ASM_STR, p.tok_i, "unicode")!;
				return PARSING_FAILED~;
			case STRING_LITERAL_WIDE:
				p.err(parser_diagnostics::ParserDiag.INVALID_ASM_STR, p.tok_i, "wide")!;
				return PARSING_FAILED~;
			default: {}
		}
	}
	if (i == p.tok_i)
	{
		p.err(parser_diagnostics::ParserDiag.EXPECTED_STR_LITERAL_IN, p.tok_i, "asm")!;
		return PARSING_FAILED~;
	}
	parser_primary::PrimaryParser primary = { .parser = p };
	return primary.parse_string(p.tok_i);
}

<* `parse_asm_string` adapted to the AsmString callback shape (the default when none is installed). *>
fn type_store::NodeIndex? default_asm_string(void* context, parser::Parser* p)
{
	return parse_asm_string(p)!.node;
}

<* Zig `checkAsmStr`: with GNU asm disabled only the empty string is allowed. *>
fn void? check_asm_str(parser::Parser* p, value::Value asm_str, tokens::TokenIndex tok)
{
	if (p.comp.langopts.gnu_asm) return;
	if (asm_str.to_bytes(p.comp).len > 1) p.err(parser_diagnostics::ParserDiag.GNU_ASM_DISABLED, tok)!;
}

<*
 Zig `assembly(.global)`: `asm ( string ) ;` at file scope. Returns the
 GLOBAL_ASM node, or NOT_ASM (consuming nothing) when not at an asm keyword.
*>
fn type_store::NodeIndex? parse_global_asm(parser::Parser* p)
{
	tree::GnuAsmQualifiers quals;
	tokens::TokenIndex asm_tok = parse_asm_prefix(p, AsmKind.GLOBAL, &quals)!;
	tokens::TokenIndex l_paren = p.tok_i - 1;
	parser_result::Result asm_str = parse_asm_string(p)!;
	check_asm_str(p, asm_str.val, l_paren)!;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.GLOBAL_ASM,
			.global_asm = { .asm_tok = asm_tok, .asm_str = asm_str.node }
		}
	);
	p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)!;
	p.expect(tokenizer::TokenId.SEMICOLON)!;
	return node;
}

<* Zig `assembly(.decl_label)` result: the asm keyword and the label string. *>
struct AsmLabel
{
	tokens::TokenIndex asm_tok;
	parser_result::Result label;
}

<*
 Zig `assembly(.decl_label)`: `asm ( string )` after a declarator, without a
 trailing semicolon. The caller records it as the ASM_LABEL keyword attribute.
 Returns NOT_ASM (consuming nothing) when not at an asm keyword.
*>
fn AsmLabel? parse_asm_label(parser::Parser* p)
{
	tree::GnuAsmQualifiers quals;
	tokens::TokenIndex asm_tok = parse_asm_prefix(p, AsmKind.DECL_LABEL, &quals)!;
	tokens::TokenIndex l_paren = p.tok_i - 1;
	parser_result::Result label = parse_asm_string(p)!;
	p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)!;
	return { .asm_tok = asm_tok, .label = label };
}

// Parse a GNU asm statement beginning at asm/__asm/__asm__. On success the
// returned node is the ASM_STMT node, and the trailing semicolon is consumed.
fn type_store::NodeIndex? AsmParser.parse_statement(&self)
{
	parser::Parser* p = self.parser;
	tree::GnuAsmQualifiers quals;
	tokens::TokenIndex asm_tok = parse_asm_prefix(p, AsmKind.STMT, &quals)!;
	type_store::NodeIndex asm_str = self.parse_string()!;
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
		if (quals.is_goto)
		{
			p.expected_token_diag(tokenizer::TokenId.COLON)!; return PARSING_FAILED~;
		}
		p.advance();
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		return p.tree.add_node(
			{
				.kind = tree::NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = asm_tok, .asm_str = asm_str, .quals = quals }
			}
		);
	}
	if (p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.COLON_COLON))
	{
		extra_colon = p.is_at(tokenizer::TokenId.COLON_COLON);
		p.advance();
		if (!extra_colon && ((!p.at_eof() && parser_primary::is_string_token(p.tree.tokens[(usz)p.tok_i].id)) || p.is_at(tokenizer::TokenId.L_BRACKET)))
		{
			while (true)
			{
				tree::AsmOperand? maybe_op = self.parse_operand(true);
				if (catch caught_fault = maybe_op) return caught_fault~;
				outputs.push(maybe_op);
				if (!@ok(p.eat(tokenizer::TokenId.COMMA))) break;
			}
		}
	}
	if (extra_colon || p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.COLON_COLON))
	{
		if (extra_colon)
		{
			extra_colon = false;
		}
		else
		{
			extra_colon = p.is_at(tokenizer::TokenId.COLON_COLON); p.advance();
		}
		if (!extra_colon && ((!p.at_eof() && parser_primary::is_string_token(p.tree.tokens[(usz)p.tok_i].id)) || p.is_at(tokenizer::TokenId.L_BRACKET)))
		{
			while (true)
			{
				tree::AsmOperand maybe_op = self.parse_operand(false)!;
				inputs.push(maybe_op);
				if (!@ok(p.eat(tokenizer::TokenId.COMMA))) break;
			}
		}
	}
	if (extra_colon || p.is_at(tokenizer::TokenId.COLON) || p.is_at(tokenizer::TokenId.COLON_COLON))
	{
		if (extra_colon)
		{
			extra_colon = false;
		}
		else
		{
			extra_colon = p.is_at(tokenizer::TokenId.COLON_COLON); p.advance();
		}
		if (!extra_colon && !p.at_eof() && parser_primary::is_string_token(p.tree.tokens[(usz)p.tok_i].id))
		{
			while (true)
			{
				type_store::NodeIndex maybe_clobber = self.parse_string()!;
				clobbers.push(maybe_clobber);
				if (!@ok(p.eat(tokenizer::TokenId.COMMA))) break;
			}
		}
	}
	if (!quals.is_goto && (!p.is_at(tokenizer::TokenId.R_PAREN) || extra_colon))
	{
		p.expected_token_diag(tokenizer::TokenId.R_PAREN)!; return PARSING_FAILED~;
	}
	if (extra_colon || p.is_at(tokenizer::TokenId.COLON))
	{
		if (!extra_colon) p.advance();
		while (true)
		{
			if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
			{
				p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~;
			}
			tokens::TokenIndex label_tok = p.tok_i;
			labels.push(p.tree.add_node(
					{
						.kind = tree::NodeKind.ADDR_OF_LABEL, .addr_of_label = { .label_tok = label_tok, .qt = type_store::VOID_POINTER }
					}
				));
			p.advance();
			if (!@ok(p.eat(tokenizer::TokenId.COMMA))) break;
		}
	}
	else if (quals.is_goto)
	{
		{
			p.expected_token_diag(tokenizer::TokenId.COLON)!; return PARSING_FAILED~;
		}
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, asm_tok + 1)) return PARSING_FAILED~;
	if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = asm_tok, .asm_str = asm_str, .outputs = outputs.array_view(), .inputs = inputs.array_view(), .clobbers = clobbers.array_view(), .labels = labels.array_view(), .quals = quals }
	}
	);
}
