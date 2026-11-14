// Declarator grammar for the typed parser. Declaration specifiers and
// parameter declarations remain owner callbacks; this module composes the
// declarator operators around a caller-supplied base type.
module aro::parser_declarator;
import aro::bigint, aro::parser, aro::parser_diagnostics, aro::parser_result, aro::tokens, aro::tokenizer, aro::type_store, aro::value;
import aro::tree, aro::symbol_stack, aro::string_interner, aro::lang_opts;
import std::collections::list;

excuse PARSING_FAILED;

<* Callback used by the type-name bridge until declaration specifiers are
   exposed as reusable parser methods. *>
alias TypeName = fn type_store::QualType?(void* context, parser::Parser* p);

<*
 Parse exactly one parameter declaration, including its declaration
 specifiers and optional named/abstract declarator. The owner callback creates
 and retains the parameter AST node and any symbol binding, then returns those
 handles in FuncParam. It runs in the temporary prototype scope established by
 DeclaratorParser; this grammar does not duplicate declaration-specifier
 parsing.
*>
alias ParameterDeclaration = fn type_store::FuncParam?(void* context, parser::Parser* p);

struct DeclaratorParser
{
	parser::Parser* parser;
	void* context;
	TypeName type_name;
	ParameterDeclaration parameter_declaration;
	bool has_parameter_declaration;
}

<* A parsed declarator exposes token presence separately because token index
   zero is valid. The name spelling remains available through Parser.tree.
   `old_style_ident_tok` is the first pre-C23 identifier-list name, if any. *>
struct ParsedDeclarator
{
	type_store::QualType qt;
	bool has_name;
	tokens::TokenIndex name_tok;
	bool has_old_style_ident;
	tokens::TokenIndex old_style_ident_tok;
}

struct DeclaratorShape
{
	type_store::QualType qt;
	tokens::TokenIndex after_pointers_tok;
	bool has_name;
	tokens::TokenIndex name_tok;
	bool has_old_style_ident;
	tokens::TokenIndex old_style_ident_tok;
}

fn bool DeclaratorParser.at(self, tokenizer::TokenId id)
{
	return self.parser.is_at(id);
}

fn bool is_identifier(tokenizer::TokenId id)
{
	return id == tokenizer::TokenId.IDENTIFIER || id == tokenizer::TokenId.EXTENDED_IDENTIFIER;
}

fn bool is_group_start(DeclaratorParser* self, bool allow_abstract)
{
	if (!self.at(tokenizer::TokenId.L_PAREN)) return false;
	parser::TreeTokenOption maybe_next = self.parser.peek(1);
	if (!maybe_next.has_value) return false;
	tokenizer::TokenId next = maybe_next.value.id;
	if (next == tokenizer::TokenId.ASTERISK || next == tokenizer::TokenId.L_PAREN) return true;
	return !allow_abstract && is_identifier(next);
}

<* Consume the qualifiers that follow one pointer star. *>
fn void DeclaratorParser.pointer_qualifiers(&self, type_store::QualType* qt)
{
	parser::Parser* p = self.parser;
	while (!p.at_eof())
	{
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		switch (id)
		{
			case KEYWORD_CONST: case KEYWORD_CONST1: case KEYWORD_CONST2:
				qt.is_const = true;
				p.advance();
			case KEYWORD_VOLATILE: case KEYWORD_VOLATILE1: case KEYWORD_VOLATILE2:
				qt.is_volatile = true;
				p.advance();
			case KEYWORD_RESTRICT: case KEYWORD_RESTRICT1: case KEYWORD_RESTRICT2:
				qt.is_restrict = true;
				p.advance();
			case KEYWORD_ATOMIC:
				// In this position _Atomic is a type qualifier on the pointer.
				*qt = p.comp.type_store.put(type_store::type_atomic(*qt));
				p.advance();
			default: return;
		}
	}
}

<* Insert `replacement` wherever the declarator-combine marker occurs. The
   marker lets parenthesized declarators defer application of their outer
   suffixes until the inner pointer/function/array shape is known. *>
fn type_store::QualType DeclaratorParser.splice(&self, type_store::QualType partial, type_store::QualType replacement)
{
	if (partial.index == type_store::IDX_DECLARATOR_COMBINE)
	{
		// The marker contributes no qualifiers; keep those on the replacement type.
		return replacement;
	}

	if (try pointer = partial.get(self.parser.comp, type_store::TypeTag.POINTER))
	{
		type_store::QualType child = self.splice(pointer.pointer.child, replacement);
		type_store::Type rebuilt = {
			.tag = type_store::TypeTag.POINTER,
			.pointer = {
				.child = child,
				.has_decayed = pointer.pointer.has_decayed,
				.decayed = pointer.pointer.decayed,
				.bounds = pointer.pointer.bounds,
				.nullability = pointer.pointer.nullability,
			},
		};
		return self.parser.comp.type_store.put(rebuilt).with_qualifiers(partial);
	}
	if (try array = partial.get(self.parser.comp, type_store::TypeTag.ARRAY))
	{
		type_store::QualType child = self.splice(array.array.elem, replacement);
		type_store::Type rebuilt = { .tag = type_store::TypeTag.ARRAY,
			.array = { .elem = child, .len = array.array.len } };
		return self.parser.comp.type_store.put(rebuilt).with_qualifiers(partial);
	}
	if (try func = partial.get(self.parser.comp, type_store::TypeTag.FUNC))
	{
		type_store::QualType ret = self.splice(func.func.return_type, replacement);
		type_store::Type rebuilt = { .tag = type_store::TypeTag.FUNC,
			.func = { .return_type = ret, .kind = func.func.kind,
				.params = func.func.params, .cc = func.func.cc } };
		return self.parser.comp.type_store.put(rebuilt).with_qualifiers(partial);
	}
	if (try atomic = partial.get(self.parser.comp, type_store::TypeTag.ATOMIC))
	{
		type_store::QualType child = self.splice(atomic.atomic, replacement);
		return self.parser.comp.type_store.put(type_store::type_atomic(child)).with_qualifiers(partial);
	}
	return partial;
}

<* Parse one array suffix and return its metadata through an already-parsed
   assignment-expression bound. Empty brackets and `[*]` keep their distinct
   incomplete and unspecified-VLA type forms. *>
fn type_store::QualType? DeclaratorParser.array_suffix(&self, type_store::QualType elem)
{
	parser::Parser* p = self.parser;
	tokens::TokenIndex opener = p.tok_i;
	p.advance(); // '['
	// C99 permits `static` before the bound of an array parameter. Keep it
	// as part of the parsed array metadata so parameter decay retains the
	// minimum-bound contract for later checks and diagnostics.
	tokens::TokenIndex static_tok = p.tok_i;
	bool has_static_bound = p.is_at(tokenizer::TokenId.KEYWORD_STATIC);
	if (has_static_bound) p.advance();
	if (self.at(tokenizer::TokenId.R_BRACKET))
	{
		if (has_static_bound)
		{
			p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_EXPR, "expected expression", p.tok_i)!;
			return PARSING_FAILED~;
		}
		p.advance();
		return p.comp.type_store.put(type_store::type_array(elem, type_store::ArrayLenKind.INCOMPLETE));
	}
	if (self.at(tokenizer::TokenId.ASTERISK))
	{
		if (has_static_bound)
		{
			p.err(parser_diagnostics::ParserDiag.INVALID_STATIC_STAR, static_tok)!;
		}
		p.advance();
		if (catch p.expect_closing(tokenizer::TokenId.R_BRACKET, opener)) return PARSING_FAILED~;
		return p.comp.type_store.put(type_store::type_array(elem, type_store::ArrayLenKind.UNSPECIFIED_VARIABLE));
	}

	tokens::TokenIndex bound_tok = p.tok_i;
	parser_result::Result? maybe_bound = p.assign_expr();
	if (catch f = maybe_bound) return f~;
	parser_result::Result bound = maybe_bound;
	if (!bound.qt.is_invalid() && !bound.qt.is_real_int(p.comp))
	{
		p.err(parser_diagnostics::ParserDiag.ARRAY_SIZE_NON_INT, bound_tok, p.fmt_qt(bound.qt))!;
		return PARSING_FAILED~;
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_BRACKET, opener)) return PARSING_FAILED~;

	if (bound.val.is_none())
	{
		p.err(parser_diagnostics::ParserDiag.VLA, opener)!;
		return p.comp.type_store.put(type_store::type_vla(elem, bound.node));
	}
	if (value::compare(bound.val, bigint::CompareOperator.LT, value::ZERO, p.comp))
	{
		p.err(parser_diagnostics::ParserDiag.NEGATIVE_ARRAY_SIZE, opener)!;
		return PARSING_FAILED~;
	}
	ulong len = bound.val.to_u64(p.comp) ?? ulong::max;
	type_store::ArrayLenKind len_kind = type_store::ArrayLenKind.FIXED;
	if (has_static_bound) len_kind = type_store::ArrayLenKind.STATIC;
	return p.comp.type_store.put(type_store::type_array(elem, len_kind, len));
}

<* An identifier that cannot begin a declaration specifier because it does
   not name a typedef. In C23 the parameter parser diagnoses this as an
   unknown type name; before C23 it starts an identifier list. *>
fn bool DeclaratorParser.at_non_typedef_identifier(&self)
{
	parser::Parser* p = self.parser;
	if (p.at_eof()) return false;
	if (!is_identifier(p.tree.tokens[(usz)p.tok_i].id)) return false;
	string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(p.tok_i));
	symbol_stack::Symbol sym;
	return !(p.find_typedef(name, p.tok_i, true, &sym) ?? false);
}

<* A pre-C23 identifier-list entry is an identifier, at the start of a
   parameter, that does not name a typedef. *>
fn bool DeclaratorParser.at_identifier_list_entry(&self)
{
	return !self.parser.comp.langopts.standard.at_least(C23) && self.at_non_typedef_identifier();
}

<* Parse one identifier-list entry. It becomes an int PARAM node and an
   ordinary symbol in the temporary prototype scope. *>
fn type_store::FuncParam? DeclaratorParser.parse_identifier_list_param(&self)
{
	parser::Parser* p = self.parser;
	tokens::TokenIndex name_tok = p.tok_i;
	string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
	p.advance();
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.PARAM, .param = {
		.name_tok = name_tok,
		.qt = type_store::INT,
		.storage_class = tree::ParamStorageClass.AUTO,
	} });
	symbol_stack::SymbolContext sym_ctx = p.symbol_context();
	p.symbols.define_param(&sym_ctx, name, type_store::INT, name_tok, node)!;
	return { .qt = type_store::INT, .name = name, .name_tok = (type_store::TokenIndex)name_tok, .node = node.pack() };
}

<* Parse a function suffix. Parameter declarations are delegated to the
   owner callback, which receives this parser's temporary prototype scope.
   Pre-C23 identifier lists are handled here; the first identifier is
   recorded in `shape` when no earlier suffix already recorded one. Mixing
   identifier-list entries with typed or variadic entries is rejected. *>
fn type_store::QualType? DeclaratorParser.function_suffix(&self, type_store::QualType ret, DeclaratorShape* shape)
{
	parser::Parser* p = self.parser;
	tokens::TokenIndex opener = p.tok_i;
	p.advance(); // '('
	list::List{type_store::FuncParam} params;
	params.init(p.comp.gpa);
	defer params.free();
	if (self.at(tokenizer::TokenId.R_PAREN))
	{
		p.advance();
		// C23 `()` is a prototype with no parameters; earlier standards keep it old-style.
		type_store::FuncKind empty_kind = p.comp.langopts.standard.at_least(C23) ? type_store::FuncKind.NORMAL : type_store::FuncKind.OLD_STYLE;
		return p.comp.type_store.put(type_store::type_func(ret, empty_kind, {}));
	}
	if (self.at(tokenizer::TokenId.ELLIPSIS))
	{
		tokens::TokenIndex ellipsis = p.tok_i;
		p.err(parser_diagnostics::ParserDiag.PARAM_BEFORE_VAR_ARGS, ellipsis)!;
		p.advance();
		if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
		return p.comp.type_store.put(type_store::type_func(ret, type_store::FuncKind.VARIADIC, {}));
	}
	if (!self.has_parameter_declaration)
	{
		p.grammar_unavailable()!;
		return PARSING_FAILED~;
	}

	p.push_scope();
	defer p.pop_scope();
	bool variadic = false;
	bool identifier_list = false;
	bool typed_param = false;
	while (true)
	{
		tokens::TokenIndex param_start = p.tok_i;
		if (self.at_identifier_list_entry())
		{
			// An identifier-list entry cannot follow a typed parameter in the same list.
			if (typed_param)
			{
				p.err(parser_diagnostics::ParserDiag.EXPECTED_PARAM_DECL, param_start)!;
				return PARSING_FAILED~;
			}
			identifier_list = true;
			if (!shape.has_old_style_ident)
			{
				shape.has_old_style_ident = true;
				shape.old_style_ident_tok = p.tok_i;
			}
			type_store::FuncParam? maybe_ident = self.parse_identifier_list_param();
			if (catch f = maybe_ident) return f~;
			type_store::FuncParam ident = maybe_ident;
			params.push(ident);
		}
		else
		{
			// A typed parameter cannot follow identifier-list entries.
			if (identifier_list)
			{
				p.err(parser_diagnostics::ParserDiag.EXPECTED_IDENTIFIER, param_start)!;
				return PARSING_FAILED~;
			}
			// Preserve C23's deprecated K&R spelling as metadata while letting
			// the parameter callback issue the normal unknown-type-name error.
			// The declaration parser uses this to recover at a following
			// declaration list instead of treating it as a malformed prototype.
			if (p.comp.langopts.standard.at_least(C23) && self.at_non_typedef_identifier() &&
				!shape.has_old_style_ident)
			{
				shape.has_old_style_ident = true;
				shape.old_style_ident_tok = p.tok_i;
			}
			typed_param = true;
			type_store::FuncParam? maybe_param = self.parameter_declaration(self.context, p);
			if (catch f = maybe_param) return f~;
			type_store::FuncParam param = maybe_param;
			if (p.tok_i == param_start) return PARSING_FAILED~;
			if (param.qt.is(p.comp, type_store::TypeTag.VOID))
			{
				if (params.len() == 0)
				{
					if (self.at(tokenizer::TokenId.R_PAREN))
					{
						p.advance();
						return p.comp.type_store.put(type_store::type_func(ret, type_store::FuncKind.NORMAL, {}));
					}
					if (!self.at(tokenizer::TokenId.R_PAREN))
					{
						p.err(parser_diagnostics::ParserDiag.VOID_ONLY_PARAM, p.tok_i)!;
					}
					if (param.qt.is_qualified())
					{
						p.err(parser_diagnostics::ParserDiag.VOID_PARAM_QUALIFIED, p.tok_i)!;
					}
				}
				else
				{
					p.err(parser_diagnostics::ParserDiag.VOID_MUST_BE_FIRST_PARAM, p.tok_i)!;
				}
				return PARSING_FAILED~;
			}
			params.push(param);
		}

		if (!self.at(tokenizer::TokenId.COMMA)) break;
		p.advance();
		if (self.at(tokenizer::TokenId.ELLIPSIS))
		{
			if (identifier_list)
			{
				p.err(parser_diagnostics::ParserDiag.EXPECTED_IDENTIFIER, p.tok_i)!;
				return PARSING_FAILED~;
			}
			variadic = true;
			p.advance();
			break;
		}
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	type_store::FuncKind kind = type_store::FuncKind.NORMAL;
	if (identifier_list)
	{
		kind = type_store::FuncKind.OLD_STYLE;
	}
	else if (variadic)
	{
		kind = type_store::FuncKind.VARIADIC;
	}
	return p.comp.type_store.put(type_store::type_func(ret, kind, params.array_view()));
}

<* Suffixes are parsed in source order and composed from the inside out: in
   `f[3](int)`, the function suffix is the direct child of the array suffix. *>
fn type_store::QualType? DeclaratorParser.suffixes(&self, type_store::QualType base, DeclaratorShape* shape)
{
	parser::Parser* p = self.parser;
	if (self.at(tokenizer::TokenId.L_BRACKET))
	{
		type_store::QualType? maybe_suffix = self.array_suffix(base);
		if (catch f = maybe_suffix) return f~;
		type_store::QualType suffix = maybe_suffix;
		type_store::QualType? maybe_inner = self.suffixes(base, shape);
		if (catch f = maybe_inner) return f~;
		type_store::QualType inner = maybe_inner;
		// Reuse the parsed array descriptor while replacing its element with
		// the remaining suffix chain.
		type_store::Type arr = suffix.get(p.comp, type_store::TypeTag.ARRAY)!;
		arr.array.elem = inner;
		return p.comp.type_store.put(arr).with_qualifiers(suffix);
	}
	if (self.at(tokenizer::TokenId.L_PAREN))
	{
		type_store::QualType? maybe_suffix = self.function_suffix(base, shape);
		if (catch f = maybe_suffix) return f~;
		type_store::QualType suffix = maybe_suffix;
		type_store::QualType? maybe_inner = self.suffixes(base, shape);
		if (catch f = maybe_inner) return f~;
		type_store::QualType inner = maybe_inner;
		type_store::Type func = suffix.get(p.comp, type_store::TypeTag.FUNC)!;
		func.func.return_type = inner;
		return p.comp.type_store.put(func).with_qualifiers(suffix);
	}
	return base;
}

<* Parse pointer prefixes, an optional name/group, and all direct suffixes.
   A group parses against its own combine marker; the outer prefix and suffix
   chain is then spliced into that marker to preserve C precedence. *>
fn DeclaratorShape? DeclaratorParser.parse_shape(&self, type_store::QualType base, bool allow_abstract)
{
	parser::Parser* p = self.parser;
	type_store::QualType prefix = base;
	while (self.at(tokenizer::TokenId.ASTERISK))
	{
		p.advance();
		prefix = p.comp.type_store.put(type_store::type_pointer(prefix));
		self.pointer_qualifiers(&prefix);
	}

	tokens::TokenIndex after_pointers_tok = p.tok_i;
	DeclaratorShape shape = { .qt = prefix, .after_pointers_tok = after_pointers_tok };
	if (!allow_abstract && !p.at_eof() && is_identifier(p.tree.tokens[(usz)p.tok_i].id))
	{
		shape.has_name = true;
		shape.name_tok = p.tok_i;
		p.advance();
	}
	else if (is_group_start(self, allow_abstract))
	{
		tokens::TokenIndex opener = p.tok_i;
		p.advance();
		type_store::QualType marker = type_store::DECLARATOR_COMBINE;
		DeclaratorShape? maybe_inner = self.parse_shape(marker, allow_abstract);
		if (catch f = maybe_inner) return f~;
		DeclaratorShape inner = maybe_inner;
		if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
		// The group precedes the outer suffixes, so its old-style record wins.
		shape.has_old_style_ident = inner.has_old_style_ident;
		shape.old_style_ident_tok = inner.old_style_ident_tok;
		type_store::QualType? maybe_outer = self.suffixes(prefix, &shape);
		if (catch f = maybe_outer) return f~;
		shape.qt = self.splice(inner.qt, maybe_outer);
		shape.has_name = inner.has_name;
		shape.name_tok = inner.name_tok;
		return shape;
	}

	type_store::QualType? maybe_suffixes = self.suffixes(prefix, &shape);
	if (catch f = maybe_suffixes) return f~;
	shape.qt = maybe_suffixes;
	return shape;
}

<* Parse a named or abstract declarator around `base`. Pass
   `allow_abstract=true` for type names and unnamed parameters. *>
fn ParsedDeclarator? DeclaratorParser.parse_declarator(&self, type_store::QualType base, bool allow_abstract = false)
{
	type_store::QualType marker = type_store::DECLARATOR_COMBINE;
	DeclaratorShape? maybe_shape = self.parse_shape(marker, allow_abstract);
	if (catch f = maybe_shape) return f~;
	DeclaratorShape shape = maybe_shape;
	if (!allow_abstract && !shape.has_name)
	{
		self.parser.err(parser_diagnostics::ParserDiag.EXPECTED_IDENT_OR_L_PAREN, shape.after_pointers_tok)!;
		return PARSING_FAILED~;
	}
	return {
		.qt = self.splice(shape.qt, base),
		.has_name = shape.has_name,
		.name_tok = shape.name_tok,
		.has_old_style_ident = shape.has_old_style_ident,
		.old_style_ident_tok = shape.old_style_ident_tok,
	};
}

<* Preserve the historical abstract-declarator entry point used by current
   parser clients; it now accepts the full reusable declarator grammar. *>
fn type_store::QualType? DeclaratorParser.abstract_declarator(&self, type_store::QualType base)
{
	ParsedDeclarator? maybe_parsed = self.parse_declarator(base, true);
	if (catch f = maybe_parsed) return f~;
	ParsedDeclarator parsed = maybe_parsed;
	return parsed.qt;
}

<* Parse a typed type-name through the callback contract exposed by
   IParserHandler. This leaves declaration specifiers with their owner. *>
fn type_store::QualType? DeclaratorParser.parse_type_name(&self)
{
	return self.type_name(self.context, self.parser);
}
