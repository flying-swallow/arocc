// Token-level attribute syntax reader. Expression parsing and semantic
// application stay with the declaration grammar/Attribute.Wip layer; this
// module records borrowed token ranges for each argument without consuming
// their meaning prematurely.
module aro::frontend::c::parser_attribute;
import aro::frontend::c::attribute, aro::frontend::c::parser, aro::frontend::c::diagnostics, aro::frontend::c::tokenizer, aro::frontend::c::tokens;
import std::collections::list;
import std::core::dstring;

<* Half-open token range for one attribute argument. *>
struct AttributeArgTokens
{
	tokens::TokenIndex start;
	tokens::TokenIndex end;
}

<*
 One syntactically parsed attribute. `name` is meaningful when `has_name` is
 true. Argument ranges index the Parser's Tree token storage, so the Parser
 must outlive this record.
*>
struct ParsedAttribute
{
	attribute::AttributeSyntax syntax;
	attribute::Namespaced name;
	tokens::TokenIndex tok;
	uint args_offset;
	uint args_len;
	bool has_name;
}

<* Reusable result storage. The caller initializes it with the compilation allocator. *>
struct AttributeBuffer
{
	List{ParsedAttribute} attributes;
	List{AttributeArgTokens} arguments;
}

fn void AttributeBuffer.init(&self, Allocator allocator)
{
	self.attributes.init(allocator);
	self.arguments.init(allocator);
}

fn void AttributeBuffer.free(&self)
{
	self.attributes.free();
	self.arguments.free();
	*self = {};
}

<* Restore a saved logical end after an abandoned attribute parse. *>
fn void AttributeBuffer.truncate(&self, uint attributes_len, uint arguments_len)
{
	while (self.attributes.len() > (sz)attributes_len) self.attributes.pop()!!;
	while (self.arguments.len() > (sz)arguments_len) self.arguments.pop()!!;
}

<*
 Record a keyword attribute recognized by the declaration/type grammar. The
 grammar supplies any parsed argument token ranges (for example `_Alignas`).
*>
fn void AttributeBuffer.add_keyword(&self, tokenizer::TokenId id, tokens::TokenIndex tok, uint args_offset = 0, uint args_len = 0)
{
	self.attributes.push(
		{
			.syntax = attribute::AttributeSyntax.KEYWORD,
			.has_name = true,
			.name = attribute::namespaced_from_keyword(id),
		.tok = tok,
		.args_offset = args_offset,
		.args_len = args_len,
	}
	);
}

fn String parser::Parser.attribute_token_text(&self, tokens::TokenIndex index)
{
	return self.tree.tok_slice(index);
}

<* Parse a plain identifier-or-keyword token at the current cursor. *>
fn tokens::TokenIndex? parser::Parser.parse_attribute_identifier(&self)
{
	if (self.at_eof() || !self.tree.tokens[(usz)self.tok_i].id.is_macro_identifier())
	{
		self.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!;
		return parser::PARSING_FAILED~;
	}
	tokens::TokenIndex result = self.tok_i;
	self.advance();
	return result;
}

<*
 Consume the current attribute name, optional C23 namespace, and optional
 parenthesized argument list. Arguments are divided only at top-level commas;
 nested calls, subscripts, and compound literals remain within one range.
*>
fn void? parser::Parser.parse_attribute(&self, attribute::AttributeSyntax syntax, AttributeBuffer* out)
{
	uint saved_attributes = (uint)out.attributes.len();
	uint saved_arguments = (uint)out.arguments.len();
	bool committed = false;
	defer
	{
		if (!committed) out.truncate(saved_attributes, saved_arguments);
	}
	tokens::TokenIndex first_tok = self.tok_i;
	tokens::TokenIndex name_tok = self.parse_attribute_identifier()!;
	String spelling = self.attribute_token_text(name_tok);
	bool has_vendor = false;
	String vendor = "";
	String name_text = spelling;
	if (syntax == attribute::AttributeSyntax.STANDARD && @ok(self.eat(tokenizer::TokenId.COLON_COLON)))
	{
		has_vendor = true;
		vendor = spelling;
		tokens::TokenIndex qualified_tok = self.parse_attribute_identifier()!;
		name_text = self.attribute_token_text(qualified_tok);
	}

	ParsedAttribute parsed = {
		.syntax = syntax,
		.tok = first_tok,
	};
	if (try found = attribute::namespaced_from_string(syntax, has_vendor, vendor, name_text))
	{
		parsed.has_name = true;
		parsed.name = found;
	}
	else if (syntax == attribute::AttributeSyntax.DECLSPEC)
	{
		Diagnostic.DECLSPEC_ATTR_NOT_SUPPORTED.@emit(self, first_tok, name_text)!;
	}
	else if (has_vendor)
	{
		Diagnostic.UNKNOWN_NAMESPACED_ATTRIBUTE.@emit(self, first_tok, vendor, name_text)!;
	}
	else
	{
		Diagnostic.UNKNOWN_ATTRIBUTE.@emit(self, first_tok, name_text)!;
	}

	if (@ok(self.eat(tokenizer::TokenId.L_PAREN)))
	{
		tokens::TokenIndex arg_opener = self.tok_i - 1;
		parsed.args_offset = (uint)out.arguments.len();
		if (!self.is_at(tokenizer::TokenId.R_PAREN))
		{
			tokens::TokenIndex arg_start = self.tok_i;
			uint parens = 0;
			uint brackets = 0;
			uint braces = 0;
			while (!self.at_eof())
			{
				tokenizer::TokenId id = self.tree.tokens[(usz)self.tok_i].id;
				if (id == tokenizer::TokenId.R_PAREN && parens == 0 && brackets == 0 && braces == 0)
				{
					out.arguments.push(
					{
						.start = arg_start, .end = self.tok_i
					}
					);
					break;
				}
				if (id == tokenizer::TokenId.COMMA && parens == 0 && brackets == 0 && braces == 0)
				{
					out.arguments.push(
					{
						.start = arg_start, .end = self.tok_i
					}
					);
					self.advance();
					arg_start = self.tok_i;
					continue;
				}
				switch (id)
				{
					case L_PAREN: parens++;
					case R_PAREN: if (parens > 0) parens--;
					case L_BRACKET: brackets++;
					case R_BRACKET: if (brackets > 0) brackets--;
					case L_BRACE: braces++;
					case R_BRACE: if (braces > 0) braces--;
					default: {}
				}
				self.advance();
			}
			if (self.at_eof())
			{
				return self.expect_closing(tokenizer::TokenId.R_PAREN, arg_opener);
			}
		}
		self.expect_closing(tokenizer::TokenId.R_PAREN, arg_opener)!;
		parsed.args_len = (uint)(out.arguments.len() - (sz)parsed.args_offset);
	}
	out.attributes.push(parsed);
	committed = true;
}

<* Parse a comma-tolerant attribute list up to the given closing token. *>
fn void? parser::Parser.parse_attribute_list(&self, attribute::AttributeSyntax syntax, tokenizer::TokenId closing, tokens::TokenIndex opener, AttributeBuffer* out)
{
	uint saved_attributes = (uint)out.attributes.len();
	uint saved_arguments = (uint)out.arguments.len();
	bool committed = false;
	defer
	{
		if (!committed) out.truncate(saved_attributes, saved_arguments);
	}
	while (!self.is_at(closing))
	{
		if (self.at_eof()) return self.expect_closing(closing, opener);
		if (@ok(self.eat(tokenizer::TokenId.COMMA))) continue;
		self.parse_attribute(syntax, out)!;
	}
	self.expect_closing(closing, opener)!;
	committed = true;
}

<* Parse `__attribute__((...))`; false means the current token was not GNU syntax. *>
fn bool? parser::Parser.parse_gnu_attribute_specifier(&self, AttributeBuffer* out)
{
	if (!self.is_at(tokenizer::TokenId.KEYWORD_ATTRIBUTE1) && !self.is_at(tokenizer::TokenId.KEYWORD_ATTRIBUTE2)) return false;
	uint saved_attributes = (uint)out.attributes.len();
	uint saved_arguments = (uint)out.arguments.len();
	bool committed = false;
	defer
	{
		if (!committed) out.truncate(saved_attributes, saved_arguments);
	}
	self.advance();
	tokens::TokenIndex outer = self.tok_i;
	self.expect(tokenizer::TokenId.L_PAREN)!;
	tokens::TokenIndex inner = self.tok_i;
	self.expect(tokenizer::TokenId.L_PAREN)!;
	self.parse_attribute_list(attribute::AttributeSyntax.GNU, tokenizer::TokenId.R_PAREN, inner, out)!;
	self.expect_closing(tokenizer::TokenId.R_PAREN, outer)!;
	committed = true;
	return true;
}

<* Parse `[[...]]`; false means the current token was not a C23 attribute opener. *>
fn bool? parser::Parser.parse_c23_attribute_specifier(&self, AttributeBuffer* out)
{
	if (!self.is_at(tokenizer::TokenId.L_BRACKET) || !self.is_at(tokenizer::TokenId.L_BRACKET, 1)) return false;
	uint saved_attributes = (uint)out.attributes.len();
	uint saved_arguments = (uint)out.arguments.len();
	bool committed = false;
	defer
	{
		if (!committed) out.truncate(saved_attributes, saved_arguments);
	}
	tokens::TokenIndex outer = self.tok_i;
	self.advance();
	tokens::TokenIndex inner = self.tok_i;
	self.advance();
	Diagnostic.C23_ATTRIBUTE.@emit(self, outer)!;
	self.parse_attribute_list(attribute::AttributeSyntax.STANDARD, tokenizer::TokenId.R_BRACKET, inner, out)!;
	self.expect_closing(tokenizer::TokenId.R_BRACKET, outer)!;
	committed = true;
	return true;
}

<* Parse `__declspec(...)`; false means the current token was not declspec syntax. *>
fn bool? parser::Parser.parse_declspec_attribute_specifier(&self, AttributeBuffer* out)
{
	if (!self.is_at(tokenizer::TokenId.KEYWORD_DECLSPEC)) return false;
	uint saved_attributes = (uint)out.attributes.len();
	uint saved_arguments = (uint)out.arguments.len();
	bool committed = false;
	defer
	{
		if (!committed) out.truncate(saved_attributes, saved_arguments);
	}
	self.advance();
	tokens::TokenIndex opener = self.tok_i;
	self.expect(tokenizer::TokenId.L_PAREN)!;
	self.parse_attribute_list(attribute::AttributeSyntax.DECLSPEC, tokenizer::TokenId.R_PAREN, opener, out)!;
	committed = true;
	return true;
}

<*
 Parse every immediately adjacent calling-convention keyword, GNU, C23, or
 declspec attribute specifier. The caller can use the returned count/ranges to
 mark grammar-specific storage state and restore it around each declarator or
 error path.
*>
fn uint? parser::Parser.parse_attribute_specifiers(&self, AttributeBuffer* out)
{
	uint saved_attributes = (uint)out.attributes.len();
	uint saved_arguments = (uint)out.arguments.len();
	bool committed = false;
	defer
	{
		if (!committed) out.truncate(saved_attributes, saved_arguments);
	}
	uint count = 0;
	while (true)
	{
		tokenizer::TokenId id = self.at_eof() ? tokenizer::TokenId.EOF : self.tree.tokens[(usz)self.tok_i].id;
		if (id == tokenizer::TokenId.KEYWORD_CDECL || id == tokenizer::TokenId.KEYWORD_CDECL2 ||
			id == tokenizer::TokenId.KEYWORD_FASTCALL || id == tokenizer::TokenId.KEYWORD_FASTCALL2 ||
			id == tokenizer::TokenId.KEYWORD_REGCALL ||
			id == tokenizer::TokenId.KEYWORD_STDCALL || id == tokenizer::TokenId.KEYWORD_STDCALL2 ||
			id == tokenizer::TokenId.KEYWORD_THISCALL || id == tokenizer::TokenId.KEYWORD_THISCALL2 ||
			id == tokenizer::TokenId.KEYWORD_VECTORCALL || id == tokenizer::TokenId.KEYWORD_VECTORCALL2)
		{
			out.add_keyword(id, self.tok_i);
			self.advance();
			count++;
			continue;
		}
		if (self.parse_gnu_attribute_specifier(out)!)
		{
			count++; continue;
		}
		if (self.parse_c23_attribute_specifier(out)!)
		{
			count++; continue;
		}
		if (self.parse_declspec_attribute_specifier(out)!)
		{
			count++; continue;
		}
		break;
	}
	committed = true;
	return count;
}
