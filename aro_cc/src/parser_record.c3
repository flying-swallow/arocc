// Tagged record and enum specifiers for the callback based parser.
// This module owns tag lookup, incomplete type creation, and forward-declaration
// nodes; the declaration grammar supplies record-member and enumerator parsing.
module aro::frontend::c::parser;
import aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::symbol_stack, aro::string_interner, aro::frontend::c::diagnostics;
import aro::frontend::c::pragmas::pack;
import aro::frontend::c::attribute_wip, aro::frontend::c::parser_declaration;

excuse ENUM_UNDERLYING_NO_DECL_SPEC;

<* What `record_header` resolves for a tag specifier. Kind (struct/union/enum),
   name and fixed underlying type live on the tag type `qt` itself. *>
struct TagHeader
{
	type_store::QualType qt;
	type_store::NodeIndex decl_node;
	tokens::TokenIndex keyword_tok;
	tokens::TokenIndex name_tok;  // 0 for an anonymous tag
	bool is_definition;
}

<* Tag attributes parsed around the tag name and after `}` (before layout), plus
   the declaration grammar that parses them and the enum fixed underlying type. *>
struct TagAttributes
{
	parser_declaration::DeclarationParser* decls;
	attribute_wip::Wip* wip;
	// The specifier begins a struct/union member, so `enum E : width` may be a bit-field.
	bool record_member;
}

fn void? TagAttributes.parse(&self, Parser* p)
{
	self.decls.append_attributes(p, self.wip)!;
}

fn void? TagAttributes.apply(&self, Parser* p, type_store::QualType qt, type_store::NodeIndex decl_node)
{
	type_store::QualType type_qt = self.wip.apply_type_attrs(p, qt)!;
	assert(type_qt.eql(qt, p.comp), "type attributes on a tag must preserve its qualified type");
	self.wip.apply_decl_attrs_extra(p, decl_node, qt, decl_node.pack())!;
	self.wip.top = (uint)self.wip.attrs.len();
}

<* Attributes after the closing brace: `struct S { ... } __attribute__((packed))`. *>
fn void? TagAttributes.apply_body_end(&self, Parser* p, type_store::QualType qt, type_store::NodeIndex decl_node)
{
	self.wip.top = (uint)self.wip.attrs.len();
	self.parse(p)!;
	self.apply(p, qt, decl_node)!;
}

<* Input to the declaration grammar's body parser: the tag header plus the
   state captured before the header was parsed. *>
struct ContainerBodySeed
{
	inline TagHeader header;
	pack::PackValue pack_value;
	TagAttributes* tags;
}

fn type_store::Type ContainerBodySeed.tag_type(&self, Parser* p) => self.qt.get_type(p.comp);
fn bool ContainerBodySeed.is_enum(&self, Parser* p) => self.tag_type(p).tag == type_store::TypeTag.ENUM;
fn bool ContainerBodySeed.is_union(&self, Parser* p) => self.tag_type(p).tag == type_store::TypeTag.UNION;
<* The enum's fixed underlying type, or INVALID when it has none. *>
fn type_store::QualType ContainerBodySeed.enum_fixed_qt(&self, Parser* p)
{
	type_store::EnumType enum_ty = self.tag_type(p).enum_ty;
	return enum_ty.fixed ? enum_ty.tag : type_store::INVALID;
}
<* The tag name; a synthesized `(anonymous ...)` name for an anonymous tag. *>
fn string_interner::StringId ContainerBodySeed.name(&self, Parser* p)
{
	type_store::Type ty = self.tag_type(p);
	return ty.tag == type_store::TypeTag.ENUM ? ty.enum_ty.name : ty.record.name;
}

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

<* `tags` is null when no declaration grammar is available (`record_spec`). *>
fn TagHeader? Parser.record_header(&self, bool is_enum, TagAttributes* tags)
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
	if (tags) tags.parse(self)!;

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
		if (!tags)
		{
			self.grammar_unavailable()!;
			return PARSING_FAILED~;
		}
		tokens::TokenIndex ty_start = self.tok_i;
		type_store::QualType? maybe_parsed_fixed = tags.decls.parse_enum_underlying(self, tags.record_member);
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
	// Attributes after the tag name belong to the tag only when a body follows
	// (`struct S __attribute__((packed)) {...}`). In a reference such as the member
	// `enum E __attribute__((aligned(8))) c;` they belong to the declaration (GCC),
	// so rewind and let the declaration specifiers parse them; applying them to the
	// tag changed `enum E` everywhere.
	if (tags)
	{
		tokens::TokenIndex after_name = self.tok_i;
		attribute_wip::State before_attrs = tags.wip.state(false);
		tags.parse(self)!;
		// `struct S __attribute__((x));` (no declarator) still targets the tag.
		if (self.tok_i != after_name && !self.is_at(tokenizer::TokenId.L_BRACE) && !self.is_at(tokenizer::TokenId.SEMICOLON))
		{
			tags.wip.restore(before_attrs);
			self.tok_i = after_name;
		}
	}

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
			// A use of the tag (not a redeclaration `struct S;`) reports deprecated/unavailable tags, as clang does.
			if (!self.is_at(tokenizer::TokenId.SEMICOLON)) self.check_deprecated_unavailable((type_store::NodeOptIndex)prev.node, name_tok)!;
			TagHeader header = { .qt = prev.qt, .decl_node = prev.node, .keyword_tok = keyword_tok,
				.name_tok = name_tok, .is_definition = false };
			if (tags) tags.apply(self, header.qt, header.decl_node)!;
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
		bool had_previous = self.symbols.define_tag(self, name, keyword, name_tok, &previous_symbol)!;
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
	TagHeader header = { .qt = qt, .decl_node = node, .keyword_tok = keyword_tok,
		.name_tok = name_tok, .is_definition = is_definition };
	if (tags) tags.apply(self, header.qt, header.decl_node)!;
	return header;
}

<* Parse a struct/union/enum tag reference or incomplete declaration. Use
   record_spec_with_body when the declaration grammar is available. *>
fn type_store::QualType? Parser.record_spec(&self, bool is_enum = false)
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
	TagHeader? parsed = self.record_header(is_enum, null);
	if (catch parsed) return PARSING_FAILED~;
	TagHeader header = parsed;
	assert(!header.is_definition && self.tok_i >= start);
	return header.qt;
}

<* Parse a struct/union/enum specifier with its body. Attributes around the tag
   name and after `}` are parsed into `wip` and applied to the tag; the tag's
   declaration node is reported through `tag_decl_node_out`. The declaration
   grammar parses members/enumerators and the fixed enum underlying type, and
   must return a completed type preserving the original tag handle. *>
fn type_store::QualType? Parser.record_spec_with_body(&self, parser_declaration::DeclarationParser* decls, bool is_enum,
	attribute_wip::Wip* wip, type_store::NodeIndex* tag_decl_node_out, bool* has_tag_decl_node_out, bool record_member)
{
	*has_tag_decl_node_out = false;
	// Zig recordSpec/enumSpec: `state(true)` so attributes parsed before the
	// tag keyword (e.g. `__declspec(align(8)) typedef enum {...} A;`) belong
	// to the declaration, not the tag.
	attribute_wip::State tag_state = wip.state(true);
	defer wip.restore(tag_state);
	TagAttributes tags = { .decls = decls, .wip = wip, .record_member = record_member };

	pack::PackValue pack_value = {};
	if (try pack_handler = self.comp.pragmas.get("pack"))
	{
		pack::PackState* pack_state = (pack::PackState*)pack_handler.ptr;
		pack_value = pack_state.current_value();
	}
	TagHeader? parsed = self.record_header(is_enum, &tags);
	if (catch parsed) return PARSING_FAILED~;
	TagHeader header = parsed;
	*tag_decl_node_out = header.decl_node;
	*has_tag_decl_node_out = true;
	if (!header.is_definition) return header.qt;
	self.advance();  // opening brace
	type_store::QualType completed = decls.parse_container_body(self, { .header = header, .pack_value = pack_value, .tags = &tags })!;
	assert(completed.unqualified() == header.qt.unqualified(), "container body must preserve tag identity");
	return completed;
}

fn type_store::QualType? Parser.enum_spec(&self)
{
	return self.record_spec(true);
}
