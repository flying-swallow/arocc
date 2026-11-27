// GNU inline assembly grammar on Parser: `asm` statements
// (`parse_asm_statement`), file-scope `asm` (`parse_global_asm`) and
// declarator asm labels (`parse_asm_label`).
module aro::frontend::c::parser;
import aro::frontend::c::parser_result, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::diagnostics, aro::frontend::c::value;
import std::collections::list;

<* Zig `assembly(kind)`'s context: which construct the asm keyword introduces. *>
enum AsmKind : char
{
	GLOBAL, DECL_LABEL, STMT
}

fn tree::AsmOperand? Parser.parse_asm_operand(&self, bool output)
{
	tokens::TokenIndex name = 0;
	if (self.is_at(tokenizer::TokenId.L_BRACKET))
	{
		self.advance();
		if (!self.is_at(tokenizer::TokenId.IDENTIFIER) && !self.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
		{
			self.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~;
		}
		name = self.tok_i;
		self.advance();
		if (catch self.expect_closing(tokenizer::TokenId.R_BRACKET, name - 1)) return PARSING_FAILED~;
	}
	type_store::NodeIndex constraint = self.parse_asm_string()!.node;
	if (catch self.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	tokens::TokenIndex lparen = self.tok_i - 1;
	parser_result::Result result = self.expr(true)!;
	if (output && !self.tree.is_lval(result.node))
	{
		Diagnostic.INVALID_ASM_OUTPUT.@emit(self, lparen + 1)!;
	}
	else if (!output)
	{
		result.lval_conversion(self);
	}
	if (catch self.expect_closing(tokenizer::TokenId.R_PAREN, lparen)) return PARSING_FAILED~;
	return { .name = name, .constraint = constraint, .expr = result.node };
}

<*
 Zig `assembly` prefix: consume `asm`/`__asm`/`__asm__`, its qualifiers and the
 opening parenthesis. Qualifiers outside a statement are diagnosed as
 meaningless. Returns NOT_ASM (consuming nothing) when not at an asm keyword.
*>
fn tokens::TokenIndex? Parser.parse_asm_prefix(&self, AsmKind kind, tree::GnuAsmQualifiers* quals)
{
	if (self.at_eof()) return NOT_ASM~;
	if (!(self.tree.tokens[(usz)self.tok_i].id.canonical() == KEYWORD_ASM)) return NOT_ASM~;
	tokens::TokenIndex asm_tok = self.tok_i;
	if (self.tree.tokens[(usz)asm_tok].id == tokenizer::TokenId.KEYWORD_ASM)
	{
		Diagnostic.EXTENSION_TOKEN_USED.@emit(self, asm_tok)!;
	}
	self.advance();
	*quals = {};
	while (!self.at_eof())
	{
		tokenizer::TokenId id = self.tree.tokens[(usz)self.tok_i].id;
		String name;
		if (id.canonical() == KEYWORD_VOLATILE)
		{
			name = "volatile";
			if (quals.is_volatile) Diagnostic.DUPLICATE_ASM_QUAL.@emit(self, self.tok_i, name)!;
			quals.is_volatile = true;
		}
		else if (id.canonical() == KEYWORD_INLINE)
		{
			name = "inline";
			if (quals.is_inline) Diagnostic.DUPLICATE_ASM_QUAL.@emit(self, self.tok_i, name)!;
			quals.is_inline = true;
		}
		else if (id == tokenizer::TokenId.KEYWORD_GOTO)
		{
			name = "goto";
			if (quals.is_goto) Diagnostic.DUPLICATE_ASM_QUAL.@emit(self, self.tok_i, name)!;
			quals.is_goto = true;
		}
		else
		{
			break;
		}
		if (kind != AsmKind.STMT) Diagnostic.MEANINGLESS_ASM_QUAL.@emit(self, self.tok_i, name)!;
		self.advance();
	}
	if (!self.is_at(tokenizer::TokenId.L_PAREN))
	{
		// Parser.zig leaves MSVC asm as a TODO. Preserve that boundary here.
		self.expected_token_diag(tokenizer::TokenId.L_PAREN)!;
		return PARSING_FAILED~;
	}
	self.advance();
	return asm_tok;
}

<*
 Zig `asmStr`: one or more adjacent ordinary string literals; unicode and wide
 literals are rejected. Returns the string-literal result.
*>
fn parser_result::Result? Parser.parse_asm_string(&self)
{
	tokens::TokenIndex i = self.tok_i;
	for (; i < self.tok_end && is_string_token(self.tree.tokens[(usz)i].id); i++)
	{
		switch (self.tree.tokens[(usz)i].id)
		{
			case STRING_LITERAL_UTF_16:
			case STRING_LITERAL_UTF_8:
			case STRING_LITERAL_UTF_32:
				Diagnostic.INVALID_ASM_STR.@emit(self, self.tok_i, "unicode")!;
				return PARSING_FAILED~;
			case STRING_LITERAL_WIDE:
				Diagnostic.INVALID_ASM_STR.@emit(self, self.tok_i, "wide")!;
				return PARSING_FAILED~;
			default: {}
		}
	}
	if (i == self.tok_i)
	{
		Diagnostic.EXPECTED_STR_LITERAL_IN.@emit(self, self.tok_i, "asm")!;
		return PARSING_FAILED~;
	}
	return self.parse_string(self.tok_i);
}

<* Zig `checkAsmStr`: with GNU asm disabled only the empty string is allowed. *>
fn void? Parser.check_asm_str(&self, value::Value asm_str, tokens::TokenIndex tok)
{
	if (self.comp.langopts.gnu_asm) return;
	if (asm_str.to_bytes(self.comp).len > 1) Diagnostic.GNU_ASM_DISABLED.@emit(self, tok)!;
}

<*
 Zig `assembly(.global)`: `asm ( string ) ;` at file scope. Returns the
 GLOBAL_ASM node, or NOT_ASM (consuming nothing) when not at an asm keyword.
*>
fn type_store::NodeIndex? Parser.parse_global_asm(&self)
{
	tree::GnuAsmQualifiers quals;
	tokens::TokenIndex asm_tok = self.parse_asm_prefix(AsmKind.GLOBAL, &quals)!;
	tokens::TokenIndex l_paren = self.tok_i - 1;
	parser_result::Result asm_str = self.parse_asm_string()!;
	self.check_asm_str(asm_str.val, l_paren)!;
	type_store::NodeIndex node = self.tree.add_node(
		{
			.kind = tree::NodeKind.GLOBAL_ASM,
			.global_asm = { .asm_tok = asm_tok, .asm_str = asm_str.node }
		}
	);
	self.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)!;
	self.expect(tokenizer::TokenId.SEMICOLON)!;
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
fn AsmLabel? Parser.parse_asm_label(&self)
{
	tree::GnuAsmQualifiers quals;
	tokens::TokenIndex asm_tok = self.parse_asm_prefix(AsmKind.DECL_LABEL, &quals)!;
	tokens::TokenIndex l_paren = self.tok_i - 1;
	parser_result::Result label = self.parse_asm_string()!;
	self.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)!;
	return { .asm_tok = asm_tok, .label = label };
}

<* GNU asm statement at `tok_i`, consuming its trailing semicolon: the ASM_STMT
   node, or NOT_ASM (consuming nothing) when not at an asm keyword. *>
fn type_store::NodeIndex? Parser.parse_asm_statement(&self)
{
	tree::GnuAsmQualifiers quals;
	tokens::TokenIndex asm_tok = self.parse_asm_prefix(AsmKind.STMT, &quals)!;
	tokens::TokenIndex l_paren = self.tok_i - 1;
	parser_result::Result asm_str = self.parse_asm_string()!;
	self.check_asm_str(asm_str.val, l_paren)!;
	list::List{tree::AsmOperand} outputs;
	outputs.init(self.comp.gpa);
	defer outputs.free();
	list::List{tree::AsmOperand} inputs;
	inputs.init(self.comp.gpa);
	defer inputs.free();
	list::List{type_store::NodeIndex} clobbers;
	clobbers.init(self.comp.gpa);
	defer clobbers.free();
	list::List{type_store::NodeIndex} labels;
	labels.init(self.comp.gpa);
	defer labels.free();
	bool extra_colon = false;
	if (self.is_at(tokenizer::TokenId.R_PAREN))
	{
		if (quals.is_goto)
		{
			self.expected_token_diag(tokenizer::TokenId.COLON)!; return PARSING_FAILED~;
		}
		self.advance();
		if (catch self.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		return self.tree.add_node(
			{
				.kind = tree::NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = asm_tok, .asm_str = asm_str.node, .quals = quals }
			}
		);
	}
	if (self.is_at(tokenizer::TokenId.COLON) || self.is_at(tokenizer::TokenId.COLON_COLON))
	{
		extra_colon = self.is_at(tokenizer::TokenId.COLON_COLON);
		self.advance();
		if (!extra_colon && ((!self.at_eof() && is_string_token(self.tree.tokens[(usz)self.tok_i].id)) || self.is_at(tokenizer::TokenId.L_BRACKET)))
		{
			while (true)
			{
				tree::AsmOperand? maybe_op = self.parse_asm_operand(true);
				if (catch caught_fault = maybe_op) return caught_fault~;
				outputs.push(maybe_op);
				if (!@ok(self.eat(tokenizer::TokenId.COMMA))) break;
			}
		}
	}
	if (extra_colon || self.is_at(tokenizer::TokenId.COLON) || self.is_at(tokenizer::TokenId.COLON_COLON))
	{
		if (extra_colon)
		{
			extra_colon = false;
		}
		else
		{
			extra_colon = self.is_at(tokenizer::TokenId.COLON_COLON); self.advance();
		}
		if (!extra_colon && ((!self.at_eof() && is_string_token(self.tree.tokens[(usz)self.tok_i].id)) || self.is_at(tokenizer::TokenId.L_BRACKET)))
		{
			while (true)
			{
				tree::AsmOperand maybe_op = self.parse_asm_operand(false)!;
				inputs.push(maybe_op);
				if (!@ok(self.eat(tokenizer::TokenId.COMMA))) break;
			}
		}
	}
	if (extra_colon || self.is_at(tokenizer::TokenId.COLON) || self.is_at(tokenizer::TokenId.COLON_COLON))
	{
		if (extra_colon)
		{
			extra_colon = false;
		}
		else
		{
			extra_colon = self.is_at(tokenizer::TokenId.COLON_COLON); self.advance();
		}
		if (!extra_colon && !self.at_eof() && is_string_token(self.tree.tokens[(usz)self.tok_i].id))
		{
			while (true)
			{
				type_store::NodeIndex maybe_clobber = self.parse_asm_string()!.node;
				clobbers.push(maybe_clobber);
				if (!@ok(self.eat(tokenizer::TokenId.COMMA))) break;
			}
		}
	}
	if (!quals.is_goto && (!self.is_at(tokenizer::TokenId.R_PAREN) || extra_colon))
	{
		self.expected_token_diag(tokenizer::TokenId.R_PAREN)!; return PARSING_FAILED~;
	}
	if (extra_colon || self.is_at(tokenizer::TokenId.COLON))
	{
		if (!extra_colon) self.advance();
		while (true)
		{
			if (!self.is_at(tokenizer::TokenId.IDENTIFIER) && !self.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
			{
				self.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~;
			}
			tokens::TokenIndex label_tok = self.tok_i;
			labels.push(self.tree.add_node(
					{
						.kind = tree::NodeKind.ADDR_OF_LABEL, .addr_of_label = { .label_tok = label_tok, .qt = type_store::VOID_POINTER }
					}
				));
			self.advance();
			if (!@ok(self.eat(tokenizer::TokenId.COMMA))) break;
		}
	}
	else if (quals.is_goto)
	{
		self.expected_token_diag(tokenizer::TokenId.COLON)!; return PARSING_FAILED~;
	}
	if (catch self.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)) return PARSING_FAILED~;
	if (catch self.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	return self.tree.add_node(
		{
			.kind = tree::NodeKind.ASM_STMT, .asm_stmt = { .asm_tok = asm_tok, .asm_str = asm_str.node, .outputs = outputs.array_view(), .inputs = inputs.array_view(), .clobbers = clobbers.array_view(), .labels = labels.array_view(), .quals = quals }
	}
	);
}
