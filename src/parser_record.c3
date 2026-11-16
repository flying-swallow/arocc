// Tagged record and enum specifiers for the callback based parser.
// This module owns tag lookup, incomplete type creation, and forward-declaration
// nodes; the declaration grammar supplies record-member and enumerator parsing.
module aro::parser;
import aro::tokens, aro::tokenizer, aro::tree, aro::type_store, aro::symbol_stack, aro::string_interner, aro::diagnostics;
import aro::pragmas::pack;

excuse ENUM_UNDERLYING_NO_DECL_SPEC;

struct TagHeader
{
	type_store::QualType qt;
	string_interner::StringId name;
	tokens::TokenIndex keyword_tok;
	tokens::TokenIndex name_tok;
	type_store::NodeIndex decl_node;
	bool is_union;
	bool is_enum;
	bool is_definition;
	bool has_fixed;
	type_store::QualType fixed_qt;
}

enum TagAttributeStage : char
{
	PARSE_HEADER, APPLY_HEADER, PARSE_BODY_END, APPLY_BODY_END
}

<* The declaration grammar owns attribute parsing and application. Header stages
   run around the tag name; body-end stages run after `}` but before layout. *>
alias TagAttributeCallback = fn void?(void* context, Parser* p, TagHeader header, TagAttributeStage stage);

struct ContainerBodySeed
{
	type_store::QualType qt;
	string_interner::StringId name;
	tokens::TokenIndex keyword_tok;
	tokens::TokenIndex name_tok;
	type_store::NodeIndex decl_node;
	bool is_union;
	bool is_enum;
	bool has_fixed;
	type_store::QualType fixed_qt;
	pack::PackValue pack_value;
	TagAttributeCallback tag_attributes;
	void* tag_attribute_context;
}

<* Called just after the opening brace. The declaration grammar must consume
   through the matching closing brace, construct the declaration node, and
   update the incomplete tag's TypeStore entry while preserving seed.qt. *>
alias ContainerBodyCallback = fn type_store::QualType?(void* context, Parser* p, ContainerBodySeed seed);

<* Parses the declaration-specifier list after an enum's ':'. Returns INVALID when
   no type specifier starts at the current token, and emits no diagnostic then.
   The implementer rejects storage-class specifiers. Returns PARSING_FAILED on a
   hard parse error. *>
alias FixedUnderlyingCallback = fn type_store::QualType?(void* context, Parser* p);

fn string_interner::StringId Parser.anonymous_container_name(&self, tokens::TokenIndex keyword_tok, bool is_union, bool is_enum)
{
	tokens::TreeToken token = self.tree.tokens[(usz)keyword_tok];
	String kind = is_enum ? "enum" : is_union ? "union" : "struct";
	return self.comp.intern_string(string::tformat("(anonymous %s at %d:%d token %d)", kind, token.loc.id.index, token.loc.byte_offset, keyword_tok));
}

<* Zig enumSpec underlying-type check. `parsed` is INVALID when no type specifier
   starts at the current token: report DIAG_EXPECTED_TYPE and fall back to int.
   Otherwise only an integer base type is accepted (enum and bool are not), looking
   through _Atomic. Returns the unqualified integer type. *>
fn type_store::QualType? Parser.enum_fixed_type(&self, type_store::QualType parsed, tokens::TokenIndex colon_tok, tokens::TokenIndex ty_start)
{
	if (parsed.is_invalid())
	{
		Diagnostic.EXPECTED_TYPE.@emit(self, self.diag_index())!;
		Diagnostic.ENUM_FIXED.@emit(self, colon_tok)!;
		return type_store::INT;
	}
	type_store::QualType underlying = parsed;
	while (true)
	{
		type_store::BaseType bt = underlying.base(self.comp);
		switch (bt.ty.tag)
		{
			case type_store::TypeTag.INT:
				Diagnostic.ENUM_FIXED.@emit(self, colon_tok)!;
				if (underlying.is_qualified()) Diagnostic.ENUM_QUALIFIERS_IGNORED.@emit(self, ty_start)!;
				return underlying.unqualified();
			case type_store::TypeTag.ATOMIC:
				Diagnostic.ENUM_ATOMIC_IGNORED.@emit(self, ty_start)!;
				underlying = bt.ty.atomic.with_qualifiers(underlying);
			default:
				Diagnostic.ENUM_INVALID_UNDERLYING_TYPE.@emit(self, ty_start, self.fmt_qt(parsed))!;
				return type_store::INT;
		}
	}
}

<* Zig `checkEnumFixedTy`: a forward declaration or redefinition must match the
   previous enum's fixed-ness, and its underlying type when fixed. *>
fn void? Parser.check_enum_fixed_ty(&self, bool has_fixed, type_store::QualType fixed_qt, tokens::TokenIndex ident_tok, symbol_stack::Symbol prev)
{
	type_store::EnumType prev_enum = prev.qt.get_type(self.comp).enum_ty;
	if (has_fixed)
	{
		if (!prev_enum.fixed)
		{
			Diagnostic.ENUM_PREV_NONFIXED.@emit(self, ident_tok)!;
			Diagnostic.PREVIOUS_DEFINITION.@emit(self, prev.tok)!;
			return PARSING_FAILED~;
		}
		if (!prev_enum.tag.eql(fixed_qt, self.comp))
		{
			Diagnostic.ENUM_DIFFERENT_EXPLICIT_TY.@emit(self, ident_tok, self.fmt_qt(fixed_qt), self.fmt_qt(prev_enum.tag))!;
			Diagnostic.PREVIOUS_DEFINITION.@emit(self, prev.tok)!;
			return PARSING_FAILED~;
		}
	}
	else if (prev_enum.fixed)
	{
		Diagnostic.ENUM_PREV_FIXED.@emit(self, ident_tok)!;
		Diagnostic.PREVIOUS_DEFINITION.@emit(self, prev.tok)!;
		return PARSING_FAILED~;
	}
}

fn TagHeader? Parser.record_header(&self, bool is_enum, FixedUnderlyingCallback parse_fixed, void* fixed_context,
	TagAttributeCallback tag_attributes, void* tag_attribute_context)
{
	if (self.at_eof()) return PARSING_FAILED~;
	tokens::TokenIndex keyword_tok = self.tok_i;
	tokenizer::TokenId keyword = self.tree.tokens[(usz)self.tok_i].id;
	if (is_enum)
	{
		if (keyword != tokenizer::TokenId.KEYWORD_ENUM) return PARSING_FAILED~;
	}
	else if (keyword != tokenizer::TokenId.KEYWORD_STRUCT && keyword != tokenizer::TokenId.KEYWORD_UNION)
	{
		return PARSING_FAILED~;
	}
	self.advance();
	bool is_union = keyword == tokenizer::TokenId.KEYWORD_UNION;
	if (tag_attributes) tag_attributes(tag_attribute_context, self, {}, TagAttributeStage.PARSE_HEADER)!;

	tokens::TokenIndex name_tok = 0;
	string_interner::StringId name = string_interner::EMPTY;
	if (!self.at_eof() && self.tree.tokens[(usz)self.tok_i].id.is_identifier())
	{
		name_tok = self.tok_i;
		name = self.comp.intern_string(self.tree.tok_slice(name_tok));
		self.advance();
	}

	// Zig enumSpec: an enum's optional fixed underlying type follows the tag name.
	bool has_fixed = false;
	type_store::QualType fixed_qt = type_store::INVALID;
	if (is_enum && self.is_at(tokenizer::TokenId.COLON))
	{
		tokens::TokenIndex colon_tok = self.tok_i;
		self.advance();
		if (parse_fixed == null)
		{
			self.grammar_unavailable()!;
			return PARSING_FAILED~;
		}
		tokens::TokenIndex ty_start = self.tok_i;
		type_store::QualType? maybe_parsed_fixed = parse_fixed(fixed_context, self);
		fault fixed_fault = @catch(maybe_parsed_fixed);
		if (fixed_fault == ENUM_UNDERLYING_NO_DECL_SPEC)
		{
			// In a record member, `enum E : width` can be a bit-field declarator.
			// Leave the colon for the member declarator parser to consume.
			self.tok_i = colon_tok;
		}
		else if (fixed_fault)
		{
			return fixed_fault~;
		}
		else
		{
			type_store::QualType parsed_fixed = maybe_parsed_fixed!!;
			fixed_qt = self.enum_fixed_type(parsed_fixed, colon_tok, ty_start)!;
			has_fixed = true;
		}
	}
	if (tag_attributes) tag_attributes(tag_attribute_context, self, {}, TagAttributeStage.PARSE_HEADER)!;

	bool is_definition = self.is_at(tokenizer::TokenId.L_BRACE);
	if (name_tok != 0 && !is_definition)
	{
		symbol_stack::Symbol prev;
		bool found = self.find_tag(name, keyword, name_tok, self.is_at(tokenizer::TokenId.SEMICOLON) ? tokenizer::TokenId.SEMICOLON : self.tree.tokens[(usz)self.tok_i].id, &prev)!;
		if (found)
		{
			// Zig checks the fixed type only on a forward declaration (`enum E;`), not on other references.
			if (is_enum && self.is_at(tokenizer::TokenId.SEMICOLON))
			{
				self.check_enum_fixed_ty(has_fixed, fixed_qt, name_tok, prev)!;
			}
			TagHeader header = { .qt = prev.qt, .name = name, .keyword_tok = keyword_tok, .name_tok = name_tok,
			.decl_node = prev.node, .is_union = is_union, .is_enum = is_enum, .is_definition = false,
			.has_fixed = has_fixed, .fixed_qt = fixed_qt };
			if (tag_attributes) tag_attributes(tag_attribute_context, self, header, TagAttributeStage.APPLY_HEADER)!;
			return header;
		}
	}

	if (name_tok == 0 && !is_definition)
	{
		Diagnostic.IDENT_OR_L_BRACE.@emit(self, self.diag_index())!;
		return PARSING_FAILED~;
	}

	// Like Parser.zig, keep an index reserved for each syntactic occurrence.
	// A definition's callback replaces this provisional forward-decl node.
	type_store::NodeIndex node = self.tree.add_node(
		{
			.kind = is_enum ? tree::NodeKind.ENUM_FORWARD_DECL : is_union ? tree::NodeKind.UNION_FORWARD_DECL : tree::NodeKind.STRUCT_FORWARD_DECL,
			.container_forward_decl = { .name_or_kind_tok = name_tok, .container_qt = type_store::INVALID, .definition = type_store::NODE_NULL },
		}
	);

	bool reused_previous = false;
	symbol_stack::Symbol previous_symbol;
	if (is_definition && name_tok != 0)
	{
		symbol_stack::SymbolContext sym_ctx = self.symbol_context();
		bool had_previous = self.symbols.define_tag(&sym_ctx, name, keyword, name_tok, &previous_symbol)!;
		if (had_previous)
		{
			type_store::Type previous_type = previous_symbol.qt.get_type(self.comp);
			bool incomplete = is_enum ? previous_type.enum_ty.incomplete : !previous_type.record.has_layout;
			if (incomplete)
			{
				if (is_enum)
				{
					self.check_enum_fixed_ty(has_fixed, fixed_qt, name_tok, previous_symbol)!;
				}
				reused_previous = true;
			}
			else
			{
				Diagnostic.REDEFINITION.@emit(self, name_tok, self.tree.tok_slice(name_tok))!;
				Diagnostic.PREVIOUS_DEFINITION.@emit(self, previous_symbol.tok)!;
			}
		}
	}

	type_store::QualType qt;
	if (reused_previous)
	{
		qt = previous_symbol.qt;
	}
	else if (is_enum)
	{
		string_interner::StringId enum_name = name_tok != 0 ? name : self.anonymous_container_name(keyword_tok, false, true);
		qt = self.comp.type_store.put(
			{
				.tag = type_store::TypeTag.ENUM, .enum_ty = {
					.has_tag = has_fixed, .tag = has_fixed ? fixed_qt: type_store::INVALID, .fixed = has_fixed,
					.incomplete = true, .name = enum_name, .decl_node = node,
				}
			}
		);
	}
	else
	{
		string_interner::StringId record_name = name_tok != 0 ? name : self.anonymous_container_name(keyword_tok, is_union, false);
		qt = self.comp.type_store.put(type_store::type_record_incomplete(record_name, is_union, (type_store::NodeOptIndex)node));
	}

	if (is_enum && !is_definition && name_tok != 0 && !has_fixed)
	{
		Diagnostic.ENUM_FORWARD_DECLARATION.@emit(self, name_tok)!;
	}

	if (name_tok != 0 && !reused_previous)
	{
		symbol_stack::SymbolKind symbol_kind = is_enum ? symbol_stack::SymbolKind.ENUM : is_union ? symbol_stack::SymbolKind.UNION : symbol_stack::SymbolKind.STRUCT;
		self.define_symbol(
		{
			.kind = symbol_kind, .name = name, .tok = name_tok, .qt = qt, .node = node
		}
		);
	}
	if (!is_definition)
	{
		self.tree.set_node(
			{
				.kind = is_enum ? tree::NodeKind.ENUM_FORWARD_DECL : is_union ? tree::NodeKind.UNION_FORWARD_DECL : tree::NodeKind.STRUCT_FORWARD_DECL,
				.container_forward_decl = { .name_or_kind_tok = name_tok, .container_qt = qt, .definition = type_store::NODE_NULL },
			}
			, (sz)node);
	}
	else
	{
		// The provisional node is visible to tag attributes before the body is
		// parsed, so layout-affecting attributes can be applied in time.
		self.tree.set_node(
			{
				.kind = is_enum ? tree::NodeKind.ENUM_FORWARD_DECL : is_union ? tree::NodeKind.UNION_FORWARD_DECL : tree::NodeKind.STRUCT_FORWARD_DECL,
				.container_forward_decl = { .name_or_kind_tok = name_tok, .container_qt = qt, .definition = type_store::NODE_NULL },
			}
			, (sz)node);
	}
	TagHeader header = { .qt = qt, .name = name, .keyword_tok = keyword_tok, .name_tok = name_tok,
	.decl_node = node, .is_union = is_union, .is_enum = is_enum, .is_definition = is_definition,
	.has_fixed = has_fixed, .fixed_qt = fixed_qt };
	if (tag_attributes) tag_attributes(tag_attribute_context, self, header, TagAttributeStage.APPLY_HEADER)!;
	return header;
}

<* Parse a struct/union/enum tag reference or incomplete declaration. Use the
   body callback variants when the declaration grammar is available. *>
fn type_store::QualType? Parser.record_spec(&self, bool is_enum = false, FixedUnderlyingCallback parse_fixed = null, void* fixed_context = null)
{
	// Do not mutate the tag table until a body parser has been supplied.
	tokens::TokenIndex start = self.tok_i;
	if (!self.at_eof())
	{
		tokenizer::TokenId keyword = self.tree.tokens[(usz)self.tok_i].id;
		if ((is_enum && keyword == tokenizer::TokenId.KEYWORD_ENUM) ||
		(!is_enum && (keyword == tokenizer::TokenId.KEYWORD_STRUCT || keyword == tokenizer::TokenId.KEYWORD_UNION)))
		{
			usz lookahead = 1;
			if ((usz)start + lookahead < self.tree.tokens.len && self.tree.tokens[(usz)start + lookahead].id.is_identifier()) lookahead++;
			if ((usz)start + lookahead < self.tree.tokens.len && self.tree.tokens[(usz)start + lookahead].id == tokenizer::TokenId.L_BRACE)
			{
				self.grammar_unavailable()!;
				return PARSING_FAILED~;
			}
		}
	}
	TagHeader? parsed = self.record_header(is_enum, parse_fixed, fixed_context, null, null);
	if (catch parsed) return PARSING_FAILED~;
	TagHeader header = parsed;
	assert(!header.is_definition && self.tok_i >= start);
	return header.qt;
}

<* Parse a struct/union definition using the declaration grammar callback. The
   callback receives the incomplete tag and opening brace, and returns the
   completed type handle (which must preserve the original handle). *>
fn type_store::QualType? Parser.record_spec_with_body(&self, ContainerBodyCallback parse_body, void* context, bool is_enum = false, FixedUnderlyingCallback parse_fixed = null, void* fixed_context = null,
	TagAttributeCallback tag_attributes = null, void* tag_attribute_context = null)
{
	pack::PackValue pack_value = {};
	if (try pack_handler = self.comp.pragmas.get("pack"))
	{
		pack::PackState* pack_state = (pack::PackState*)pack_handler.ptr;
		pack_value = pack_state.current_value();
	}
	TagHeader? parsed = self.record_header(is_enum, parse_fixed, fixed_context, tag_attributes, tag_attribute_context);
	if (catch parsed) return PARSING_FAILED~;
	TagHeader header = parsed;
	if (!header.is_definition) return header.qt;
	self.advance();  // opening brace
	type_store::QualType completed = parse_body(context, self, {
			.qt = header.qt, .name = header.name, .keyword_tok = header.keyword_tok,
			.name_tok = header.name_tok, .decl_node = header.decl_node,
			.is_union = header.is_union, .is_enum = header.is_enum,
			.has_fixed = header.has_fixed, .fixed_qt = header.fixed_qt,
			.pack_value = pack_value,
			.tag_attributes = tag_attributes, .tag_attribute_context = tag_attribute_context,
		})!;
	assert(completed.unqualified() == header.qt.unqualified(), "container body callback must preserve tag identity");
	return completed;
}

fn type_store::QualType? Parser.enum_spec(&self, FixedUnderlyingCallback parse_fixed = null, void* fixed_context = null)
{
	return self.record_spec(true, parse_fixed, fixed_context);
}

fn type_store::QualType? Parser.enum_spec_with_body(&self, ContainerBodyCallback parse_body, void* context, FixedUnderlyingCallback parse_fixed = null, void* fixed_context = null)
{
	return self.record_spec_with_body(parse_body, context, true, parse_fixed, fixed_context);
}
