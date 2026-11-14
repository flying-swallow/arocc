// Declaration grammar binding boundary. This module owns C declaration
// specifiers and binds them to the reusable declarator, initializer and
// statement productions.
module aro::parser_declaration;
import aro::parser, aro::parser_statement, aro::parser_result, aro::parser_declarator;
import aro::tree, aro::type_store, aro::tokens, aro::tokenizer, aro::symbol_stack;
import aro::string_interner, aro::value, aro::parser_diagnostics, aro::bigint;
import aro::lang_opts, aro::compilation, aro::value_interner;
import aro::attribute;
import aro::attribute_wip, aro::parser_attribute;
import aro::parser_primary, aro::text_literal_semantics;
import aro::source;
import std::collections::list;
import std::core::dstring;

excuse PARSING_FAILED;
excuse NO_DECL_SPEC;

alias Declaration = fn void?(void* context, parser::Parser* p);
alias TypeName = fn void?(void* context, parser::Parser* p);
alias TypedTypeName = fn type_store::QualType?(void* context, parser::Parser* p);
alias ImplicitTypedefs = fn void?(void* context, parser::Parser* p);
<* Builds a complete local declaration statement or returns null when the
   current token sequence is not a declaration. *>
alias LocalDeclarationStatement = fn type_store::NodeIndex?(void* context, parser::Parser* p);

enum StorageClass : char
{
	NONE,
	TYPEDEF,
	EXTERN,
	STATIC,
	AUTO,
	REGISTER,
}

<* The parts of declaration specifiers consumed before a declarator. *>
struct DeclSpec
{
	type_store::QualType qt;
	tokens::TokenIndex auto_tok;
	tokens::TokenIndex auto_type_tok;
	tokens::TokenIndex c23_auto_tok;
	StorageClass storage_class;
	bool thread_local;
	bool constexpr_decl;
	bool is_inline;
	bool recognized;
}

// Keeps mutually recursive declaration and statement productions together.
// A declaration callback may use `statements` for function bodies and local
// declarations; Parser.parse remains responsible for top-level recovery.
struct DeclarationParser (parser::IParserHandler)
{
	Declaration declaration;
	TypeName type_name;
	TypedTypeName typed_type_name;
	ImplicitTypedefs implicit_typedefs;
	LocalDeclarationStatement local_declaration_statement;
	void* context;
	parser_statement::StatementParser statements;
	parser_statement::StatementBodyBinding body_binding;
	parser::Parser* active_parser;
	type_store::QualType function_return_qt;
	tokens::TokenIndex function_name_tok;
	parser::FunctionContext function_context;
	uint record_member_depth;
	bool has_function_context;
	bool has_declaration;
	bool has_type_name;
	bool has_typed_type_name;
	bool has_implicit_typedefs;
	bool has_local_declaration_statement;
}

<* Format auto-declaration diagnostics before passing them to Parser.emit_parser_diag,
   whose text argument is already the final message rather than a format argument. *>
fn void? emit_deduced_type_not_allowed(parser::Parser* p, bool auto_type, String context, tokens::TokenIndex tok)
{
	DString message;
	message.init(tmem);
	String specifier = auto_type ? "'__auto_type'" : "'auto'";
	message.appendf("%s not allowed in %s", specifier, context);
	parser_diagnostics::ParserDiag diag = auto_type ?
		parser_diagnostics::ParserDiag.AUTO_TYPE_NOT_ALLOWED : parser_diagnostics::ParserDiag.C23_AUTO_NOT_ALLOWED;
	return p.emit_parser_diag(diag, message.str_view(), tok);
}

fn void? emit_deduced_type_array(parser::Parser* p, bool auto_type, String name, tokens::TokenIndex tok)
{
	DString message;
	message.init(tmem);
	String specifier = auto_type ? "'__auto_type'" : "'auto'";
	message.appendf("'%s' declared as array of %s", name, specifier);
	parser_diagnostics::ParserDiag diag = auto_type ?
		parser_diagnostics::ParserDiag.AUTO_TYPE_ARRAY : parser_diagnostics::ParserDiag.C23_AUTO_ARRAY;
	return p.emit_parser_diag(diag, message.str_view(), tok);
}

fn void? emit_deduced_type_requires_initializer(parser::Parser* p, bool auto_type, String name, tokens::TokenIndex tok)
{
	if (!auto_type)
	{
		return p.err(parser_diagnostics::ParserDiag.C23_AUTO_REQUIRES_INITIALIZER, tok);
	}
	DString message;
	message.init(tmem);
	message.appendf("declaration of variable '%s' with deduced type requires an initializer", name);
	return p.emit_parser_diag(parser_diagnostics::ParserDiag.AUTO_TYPE_REQUIRES_INITIALIZER, message.str_view(), tok);
}

<* Parse a declaration initializer with the value rule selected from its
   constexpr and storage-duration specifiers. constexpr takes precedence. *>
fn parser_result::Result? DeclarationParser.parse_variable_initializer(&self, parser::Parser* p,
	type_store::QualType target, bool constexpr_decl, bool static_duration, bool eval = true)
{
	p.bind_initializer_parser((void*)self, &initializer_assignment_expression, &initializer_integer_constant_expression);
	parser::InitContext context = constexpr_decl ? parser::InitContext.CONSTEXPR :
		static_duration ? parser::InitContext.STATIC : parser::InitContext.RUNTIME;
	return p.parse_initializer_with_context(target, context, eval);
}

<* Parse an inferred-type initializer in a temporary scope where its declared
   name shadows any earlier declaration. The invalid target lets the normal
   initializer grammar retain expression diagnostics without trying to coerce
   to the auto placeholder. *>
fn parser_result::Result? DeclarationParser.parse_auto_type_initializer(&self, parser::Parser* p,
	type_store::NodeIndex declaration, string_interner::StringId name, tokens::TokenIndex name_tok,
	bool auto_type, bool deduce, bool constexpr_decl, bool static_duration, bool eval = true)
{
	p.push_scope();
	defer p.pop_scope();
	p.define_symbol({ .kind = symbol_stack::SymbolKind.DEF, .name = name, .qt = type_store::INVALID,
		.tok = name_tok, .node = declaration, .val = value::NONE });
	p.bind_initializer_parser((void*)self, &initializer_assignment_expression, &initializer_integer_constant_expression);
	parser::AutoTypeDeclContext previous_auto_type_decl = p.auto_type_decl;
	if (deduce) p.auto_type_decl = { .active = true, .name = name, .node = declaration };
	defer p.auto_type_decl = previous_auto_type_decl;

	parser::InitContext context = constexpr_decl ? parser::InitContext.CONSTEXPR :
		static_duration ? parser::InitContext.STATIC : parser::InitContext.RUNTIME;
	if (!deduce) return p.parse_initializer_with_context(type_store::INVALID, context, eval);

	tokens::TokenIndex initializer_tok = p.tok_i;
	bool init_list = p.is_at(tokenizer::TokenId.L_BRACE);
	if (init_list)
	{
		parser_diagnostics::ParserDiag diag = auto_type ?
			parser_diagnostics::ParserDiag.AUTO_TYPE_WITH_INIT_LIST : parser_diagnostics::ParserDiag.C23_AUTO_WITH_INIT_LIST;
		p.err_dyn(diag, initializer_tok)!;
	}

	parser_result::Result? maybe_initializer = p.parse_initializer_with_context(type_store::INVALID, context, eval);
	if (catch f = maybe_initializer) return f~;
	parser_result::Result initializer = maybe_initializer;
	if (init_list) return initializer;
	if (p.tree.is_bitfield(initializer.node))
	{
		p.err(parser_diagnostics::ParserDiag.AUTO_TYPE_FROM_BITFIELD, initializer_tok)!;
	}
	initializer.lval_conversion(p);
	return initializer;
}

<* Recover an incomplete array's completed type from the initializer AST. Brace
   initializers carry the completed container type directly; compatible string
   literals carry their fixed array type in the expression result. *>
fn type_store::QualType DeclarationParser.completed_array_initializer_type(&self,
	parser::Parser* p, type_store::QualType target, parser_result::Result initializer)
{
	if (!target.is(p.comp, type_store::TypeTag.ARRAY)) return target;
	type_store::Array target_array = target.get(p.comp, type_store::TypeTag.ARRAY)!!.array;
	if (target_array.len.kind != type_store::ArrayLenKind.INCOMPLETE) return target;

	tree::Node initializer_node = initializer.node.get(&p.tree);
	type_store::QualType completed = target;
	if (initializer_node.kind == tree::NodeKind.ARRAY_INIT_EXPR)
	{
		completed = initializer_node.container_init.container_qt;
	}
	else if (initializer_node.kind == tree::NodeKind.STRING_LITERAL_EXPR &&
		initializer.qt.is(p.comp, type_store::TypeTag.ARRAY))
	{
		type_store::Array source_array = initializer.qt.get(p.comp, type_store::TypeTag.ARRAY)!!.array;
		bool compatible_element = target_array.elem.eql(source_array.elem, p.comp) ||
			(source_array.elem.eql(type_store::CHAR, p.comp) &&
				(target_array.elem.eql(type_store::UCHAR, p.comp) || target_array.elem.eql(type_store::SCHAR, p.comp))) ||
			(source_array.elem.eql(type_store::UCHAR, p.comp) &&
				(target_array.elem.eql(type_store::UCHAR, p.comp) || target_array.elem.eql(type_store::SCHAR, p.comp) ||
					target_array.elem.eql(type_store::CHAR, p.comp)));
		if (compatible_element && (source_array.len.kind == type_store::ArrayLenKind.FIXED ||
			source_array.len.kind == type_store::ArrayLenKind.STATIC))
		{
			completed = p.comp.type_store.put(type_store::type_array(target_array.elem,
				type_store::ArrayLenKind.FIXED, source_array.len.len));
		}
	}

	if (!completed.is(p.comp, type_store::TypeTag.ARRAY)) return target;
	type_store::Array completed_array = completed.get(p.comp, type_store::TypeTag.ARRAY)!!.array;
	if (completed_array.len.kind != type_store::ArrayLenKind.FIXED) return target;
	return completed.with_qualifiers(target);
}

fn void? DeclarationParser.handle_body(&self, parser::Parser* p) @dynamic
{
	uint old_loop_depth = self.statements.loop_depth;
	uint old_switch_depth = self.statements.switch_depth;
	type_store::QualType old_return_qt = self.statements.function_return_qt;
	tokens::TokenIndex old_function_name_tok = self.statements.function_name_tok;
	bool old_has_function_context = self.statements.has_function_context;
	void* old_local_declaration_context = self.statements.local_declaration_context;
	parser_statement::LocalDeclarationStatement old_local_declaration_statement = self.statements.local_declaration_statement;
	bool old_has_local_declaration_statement = self.statements.has_local_declaration_statement;
	parser_statement::StatementExpression old_expression = self.statements.expression;
	parser_statement::StatementIntegerConstantExpression old_integer_constant_expression = self.statements.integer_constant_expression;
	bool old_has_integer_constant_expression = self.statements.has_integer_constant_expression;
	parser::FunctionContext old_parser_function_context = p.function_context;
	self.statements.loop_depth = 0;
	self.statements.switch_depth = 0;
	self.statements.function_return_qt = self.function_return_qt;
	self.statements.function_name_tok = self.function_name_tok;
	self.statements.has_function_context = self.has_function_context;
	p.set_function_context(self.has_function_context ? self.function_context : (parser::FunctionContext){});
	self.statements.local_declaration_context = (void*)self;
	self.statements.local_declaration_statement = &local_declaration_statement_callback;
	self.statements.has_local_declaration_statement = true;
	if (!self.statements.expression) self.statements.expression = &declaration_statement_expression;
	if (!self.statements.has_integer_constant_expression)
	{
		self.statements.integer_constant_expression = &declaration_statement_integer_constant_expression;
		self.statements.has_integer_constant_expression = true;
	}
	defer
	{
		self.statements.loop_depth = old_loop_depth;
		self.statements.switch_depth = old_switch_depth;
		self.statements.function_return_qt = old_return_qt;
		self.statements.function_name_tok = old_function_name_tok;
		self.statements.has_function_context = old_has_function_context;
		self.statements.local_declaration_context = old_local_declaration_context;
		self.statements.local_declaration_statement = old_local_declaration_statement;
		self.statements.has_local_declaration_statement = old_has_local_declaration_statement;
		self.statements.expression = old_expression;
		self.statements.integer_constant_expression = old_integer_constant_expression;
		self.statements.has_integer_constant_expression = old_has_integer_constant_expression;
		p.set_function_context(old_parser_function_context);
	}
	self.body_binding.statements = &self.statements;
	return parser_statement::parse_body_callback((void*)&self.body_binding, p);
}

fn type_store::NodeIndex? local_declaration_statement_callback(void* context, parser::Parser* p)
{
	DeclarationParser* self = (DeclarationParser*)context;
	self.statements.parser = p;
	if (self.has_local_declaration_statement) return self.local_declaration_statement(self.context, p);
	return self.parse_local_declaration_statement(p);
}

fn void? DeclarationParser.handle_declaration(&self, parser::Parser* p) @dynamic
{
	self.statements.parser = p;
	self.active_parser = p;
	p.bind_initializer_parser((void*)self, &initializer_assignment_expression, &initializer_integer_constant_expression);
	if (self.has_declaration) return self.declaration(self.context, p);
	return self.parse_declaration(p);
}

fn void? DeclarationParser.handle_translation_unit_end(&self, parser::Parser* p) @dynamic
{
	self.finalize_tentative_arrays(p);
	return;
}

<* Share the full parser-fault classification with Parser.parse when this
   declaration parser is installed directly, without FrontendHandler. *>
fn bool? DeclarationParser.is_recoverable_parse_fault(&self, parser::Parser* p, fault parse_fault) @dynamic
	=> parser_statement::recoverable_statement_item_fault(parse_fault);

<* Only provided when an override is installed (has_type_name), matching the
   legacy callback table; otherwise Parser reports the grammar as unavailable. *>
fn void? DeclarationParser.handle_type_name(&self, parser::Parser* p) @dynamic
{
	if (!self.has_type_name) return parser::HOOK_ABSENT~;
	return self.type_name(self.context, p);
}

fn type_store::QualType? DeclarationParser.handle_typed_type_name(&self, parser::Parser* p) @dynamic
{
	if (self.has_typed_type_name) return self.typed_type_name(self.context, p);
	return self.parse_typed_type_name(p);
}

<* DeclaratorParser seam; forwards to the handler method. *>
fn type_store::QualType? typed_type_name_callback(void* context, parser::Parser* p)
{
	return ((DeclarationParser*)context).handle_typed_type_name(p);
}

fn parser::TypeNameProbe? DeclarationParser.handle_typed_type_name_probe(&self, parser::Parser* p) @dynamic
{
	return self.probe_typed_type_name(p);
}

struct TypeSpecifierToken
{
	bool matched;
	type_store::BuilderSpecifier specifier;
}

<* Declaration application can mark an attribute as type-only. Keep the
   specifier-prefix state intact when the same Wip is reused for comma-separated
   declarators. *>
struct AttributeUseSnapshot
{
	list::List{bool} used;
}

fn void AttributeUseSnapshot.init(&self, parser::Parser* p, attribute_wip::Wip* wip)
{
	self.used.init(p.comp.gpa);
	foreach (attr : wip.attrs) self.used.push(attr.used_as_type_attr);
}

fn void AttributeUseSnapshot.restore(&self, attribute_wip::Wip* wip)
{
	assert((usz)self.used.len() <= (usz)wip.attrs.len());
	for (usz i = 0; i < (usz)self.used.len(); i++) wip.attrs[(sz)i].used_as_type_attr = self.used[(sz)i];
}

fn void AttributeUseSnapshot.free(&self) { self.used.free(); }

<* The declaration grammar owns record members and enumerators. Parser's tag
   header creates the incomplete type and reserves its declaration node; this
   callback fills both in place so every earlier pointer keeps the same type
   identity. *>
fn type_store::QualType? record_body_callback(void* context, parser::Parser* p, parser::ContainerBodySeed seed)
{
	DeclarationParser* self = (DeclarationParser*)context;
	return self.parse_container_body(p, seed);
}

fn type_store::QualType? enum_underlying_callback(void* context, parser::Parser* p)
{
	DeclarationParser* self = (DeclarationParser*)context;
	return self.parse_enum_underlying(p);
}

struct TagAttributeContext
{
	DeclarationParser* declaration_parser;
	attribute_wip::Wip wip;
}

fn void? tag_attribute_callback(void* context, parser::Parser* p, parser::TagHeader header, parser::TagAttributeStage stage)
{
	TagAttributeContext* tag_context = (TagAttributeContext*)context;
	switch (stage)
	{
		case parser::TagAttributeStage.PARSE_HEADER:
			return tag_context.declaration_parser.append_attributes(p, &tag_context.wip);
		case parser::TagAttributeStage.APPLY_HEADER:
			return tag_context.wip.apply_decl_attrs_extra(p, header.decl_node, header.qt, type_store::NODE_NULL);
		case parser::TagAttributeStage.PARSE_BODY_END:
			tag_context.wip.top = (uint)tag_context.wip.attrs.len();
			return tag_context.declaration_parser.append_attributes(p, &tag_context.wip);
		case parser::TagAttributeStage.APPLY_BODY_END:
			return tag_context.wip.apply_decl_attrs_extra(p, header.decl_node, header.qt, header.decl_node.pack());
	}
}

fn void? DeclarationParser.apply_tag_body_end_attributes(&self, parser::Parser* p, parser::ContainerBodySeed seed)
{
	if (!seed.tag_attributes) return;
	parser::TagHeader tag_header = { .qt = seed.qt, .name = seed.name,
		.keyword_tok = seed.keyword_tok, .name_tok = seed.name_tok, .decl_node = seed.decl_node,
		.is_union = seed.is_union, .is_enum = seed.is_enum, .is_definition = true,
		.has_fixed = seed.has_fixed, .fixed_qt = seed.fixed_qt };
	seed.tag_attributes(seed.tag_attribute_context, p, tag_header, parser::TagAttributeStage.PARSE_BODY_END)!;
	seed.tag_attributes(seed.tag_attribute_context, p, tag_header, parser::TagAttributeStage.APPLY_BODY_END)!;
}

fn type_store::QualType? DeclarationParser.parse_record_specifier(&self, parser::Parser* p, bool is_enum)
{
	TagAttributeContext tag_context;
	tag_context.declaration_parser = (DeclarationParser*)self;
	tag_context.wip.init(p.comp.gpa);
	defer tag_context.wip.free();
	attribute_wip::State state = tag_context.wip.state(true);
	defer tag_context.wip.restore(state);
	return p.record_spec_with_body(&record_body_callback, (void*)self, is_enum,
		&enum_underlying_callback, (void*)self, &tag_attribute_callback, (void*)&tag_context);
}

fn type_store::QualType? DeclarationParser.parse_enum_underlying(&self, parser::Parser* p)
{
	attribute_wip::Wip wip;
	wip.init(p.comp.gpa);
	defer wip.free();
	attribute_wip::State state = wip.state(true);
	defer wip.restore(state);
	DeclSpec? maybe_spec = self.parse_decl_spec(p, &wip, false);
	fault f = @catch(maybe_spec);
	if (f)
	{
		if (f == NO_DECL_SPEC)
		{
			if (self.record_member_depth > 0) return parser::ENUM_UNDERLYING_NO_DECL_SPEC~;
			return type_store::INVALID;
		}
		return f~;
	}
	DeclSpec spec = maybe_spec!!;
	return spec.qt;
}

fn type_store::QualType? DeclarationParser.parse_container_body(&self, parser::Parser* p, parser::ContainerBodySeed seed)
{
	if (seed.is_enum) return self.parse_enum_body(p, seed);
	attribute_wip::Wip field_wip;
	field_wip.init(p.comp.gpa);
	defer field_wip.free();
	attribute_wip::State container_state = field_wip.state(true);
	defer field_wip.restore(container_state);
	list::List{type_store::RecordField} fields;
	list::List{type_store::NodeIndex} field_nodes;
	fields.init(p.comp.gpa);
	field_nodes.init(p.comp.gpa);
	defer { fields.free(); field_nodes.free(); }

	uint previous_record_member_depth = self.record_member_depth;
	self.record_member_depth = previous_record_member_depth + 1;
	defer self.record_member_depth = previous_record_member_depth;
	while (!p.at_eof() && !p.is_at(tokenizer::TokenId.R_BRACE))
	{
		// Zig recordDeclItem replays pragmas first.
		bool? replay_result = p.replay_pragma();
		fault pragma_fault = @catch(replay_result);
		if (pragma_fault) return pragma_fault~;
		if (try handled = replay_result)
		{
			if (handled) continue;
		}
		// Zig recordDeclItem: a static assertion is a member item, not a field. Its node
		// goes to root declarations, where Parser.zig's decl_buf also ends up.
		type_store::NodeIndex? maybe_member_assert = self.parse_static_assert(p);
		fault member_assert_fault = @catch(maybe_member_assert);
		if (member_assert_fault)
		{
			if (member_assert_fault != tree::NULL_NODE) return member_assert_fault~;
		}
		else
		{
			p.tree.root_decls.push(maybe_member_assert!!);
			continue;
		}
		tokens::TokenIndex member_start = p.tok_i;
		attribute_wip::State member_state = field_wip.state(true);
		DeclSpec? maybe_spec = self.parse_decl_spec(p, &field_wip);
		if (catch f = maybe_spec)
		{
			if (f != NO_DECL_SPEC) return f~;
			p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_RECORD_DECL,
				"expected record declaration", member_start)!;
			return PARSING_FAILED~;
		}
		DeclSpec spec = maybe_spec;
		attribute_wip::State declarator_state = field_wip.state(false);
		if (spec.storage_class != StorageClass.NONE || spec.thread_local || spec.constexpr_decl || spec.is_inline)
		{
			p.err(parser_diagnostics::ParserDiag.EXPECTED_RECORD_DECL, member_start)!;
		}
		if (spec.qt.is_auto())
		{
			String context = seed.is_union ? "union member" : "struct member";
			emit_deduced_type_not_allowed(p, spec.qt.is_auto_type(), context,
				spec.qt.is_auto_type() ? spec.auto_type_tok : spec.c23_auto_tok)!;
			// Keep the placeholder out of record layout and bit-field checks.
			spec.qt = type_store::INVALID;
		}
		if (p.is_at(tokenizer::TokenId.SEMICOLON))
		{
			// C23 anonymous aggregate members and the common compiler extension
			// spelling both have a type specifier followed directly by ';'.
			if (!spec.qt.is(p.comp, type_store::TypeTag.STRUCT) && !spec.qt.is(p.comp, type_store::TypeTag.UNION))
			{
				p.err(parser_diagnostics::ParserDiag.EXPECTED_RECORD_DECL, member_start)!;
				return PARSING_FAILED~;
			}
			type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.RECORD_FIELD,
				.record_field = { .name_or_first_tok = member_start, .qt = spec.qt,
					.bit_width = type_store::NODE_NULL } });
			field_wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
			fields.push({ .qt = spec.qt, .name = string_interner::EMPTY,
				.name_tok = (type_store::TokenIndex)0, .bit_width = type_store::BIT_WIDTH_NULL,
				.field_decl = node.pack() });
			field_nodes.push(node);
			p.advance();
			field_wip.restore(member_state);
			continue;
		}

		while (true)
		{
			// Only an unnamed bit-field (`int : 3;`) has an abstract member declarator.
			bool member_abstract = p.is_at(tokenizer::TokenId.COLON);
			parser_declarator::ParsedDeclarator? maybe_field = self.declarator_parser(p).parse_declarator(spec.qt, member_abstract);
			if (catch f = maybe_field) return f~;
			parser_declarator::ParsedDeclarator field_decl = maybe_field;
			self.append_attributes(p, &field_wip)!;
			type_store::QualType field_qt = field_wip.apply_type_attrs(p, field_decl.qt)!;
			AttributeUseSnapshot attribute_use_state;
			attribute_use_state.init(p, &field_wip);
			defer attribute_use_state.free();
			type_store::NodeOptIndex bit_width_node = type_store::NODE_NULL;
			uint bit_width = type_store::BIT_WIDTH_NULL;
			if (p.is_at(tokenizer::TokenId.COLON))
			{
				tokens::TokenIndex colon = p.tok_i;
				p.advance();
				tokens::TokenIndex width_tok = p.tok_i;
				parser_result::Result? maybe_width = p.integer_const_expr(true,
					parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION);
				if (catch f = maybe_width) return f~;
				parser_result::Result width_result = maybe_width;
				if (!field_qt.is_int(p.comp))
				{
					p.err(parser_diagnostics::ParserDiag.NON_INT_BITFIELD, field_decl.has_name ? field_decl.name_tok : colon,
						p.fmt_qt(field_qt))!;
					return PARSING_FAILED~;
				}
				if (width_result.val.is_none())
				{
					p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_INTEGER_CONSTANT_EXPR,
						"expression is not an integer constant expression", width_tok)!;
				}
				else
				{
					if (value::compare(width_result.val, bigint::CompareOperator.LT, value::ZERO, p.comp))
					{
						p.err(parser_diagnostics::ParserDiag.NEGATIVE_BITWIDTH, colon,
							p.fmt_value(width_result.val, width_result.qt))!;
						return PARSING_FAILED~;
					}
					ulong width_value = width_result.val.to_u64(p.comp) ?? ulong::max;
					if (width_value > field_qt.bit_sizeof(p.comp))
					{
						p.err(parser_diagnostics::ParserDiag.BITFIELD_TOO_BIG, colon)!;
						return PARSING_FAILED~;
					}
					bit_width = (uint)width_value;
					bit_width_node = width_result.node.pack();
					if (bit_width == 0 && field_decl.has_name)
					{
						p.err(parser_diagnostics::ParserDiag.ZERO_WIDTH_NAMED_FIELD, field_decl.name_tok)!;
						return PARSING_FAILED~;
					}
				}
			}
			else if (!field_decl.has_name)
			{
				p.err(parser_diagnostics::ParserDiag.EXPECTED_RECORD_DECL, p.tok_i)!;
				return PARSING_FAILED~;
			}

			if (field_qt.has_incomplete_size(p.comp))
			{
				p.err(parser_diagnostics::ParserDiag.FIELD_INCOMPLETE_TY, field_decl.has_name ? field_decl.name_tok : member_start, p.fmt_qt(field_qt))!;
				return PARSING_FAILED~;
			}
			string_interner::StringId field_name = field_decl.has_name ?
				p.comp.intern_string(p.tree.tok_slice(field_decl.name_tok)) : string_interner::EMPTY;
			tokens::TokenIndex field_tok = field_decl.has_name ? field_decl.name_tok : member_start;
			type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.RECORD_FIELD,
				.record_field = { .name_or_first_tok = field_tok, .qt = field_qt,
					.bit_width = bit_width_node } });
			field_wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
			fields.push({ .qt = field_qt, .name = field_name,
				.name_tok = field_decl.has_name ? (type_store::TokenIndex)field_decl.name_tok : (type_store::TokenIndex)0,
				.bit_width = bit_width, .field_decl = node.pack() });
			field_nodes.push(node);
			field_wip.restore(declarator_state);
			attribute_use_state.restore(&field_wip);

			if (!p.is_at(tokenizer::TokenId.COMMA)) break;
			p.advance();
		}
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		field_wip.restore(member_state);
	}
	self.record_member_depth = previous_record_member_depth;
	if (catch p.expect(tokenizer::TokenId.R_BRACE)) return PARSING_FAILED~;
	self.apply_tag_body_end_attributes(p, seed)!;

	type_store::RecordField[] record_fields = fields.array_view();
	type_store::RecordLayout? maybe_layout = type_store::compute(record_fields,
		seed.decl_node.pack(), seed.is_union, p.comp, &p.tree.attr_map, 0);
	if (catch f = maybe_layout) return f~;
	type_store::RecordLayout layout = maybe_layout;
	type_store::Type record_type = type_store::type_record(seed.name, record_fields,
		layout, seed.is_union, seed.decl_node.pack());
	p.comp.type_store.set(record_type, seed.qt.index);
	tree::NodeKind decl_kind = seed.is_union ? tree::NodeKind.UNION_DECL : tree::NodeKind.STRUCT_DECL;
	type_store::NodeIndex[] nodes = field_nodes.array_view();
	p.tree.set_node({ .kind = decl_kind, .container_decl = {
		.name_or_kind_tok = seed.name_tok != 0 ? seed.name_tok : seed.keyword_tok,
		.container_qt = seed.qt, .fields = nodes,
	} }, (sz)seed.decl_node);
	return seed.qt;
}
fn value::Value increment_enum_value(value::Value current, compilation::Compilation* comp)
{
	value_interner::BigIntSpace current_space;
	bigint::BigIntConst current_big = current.to_big_int(&current_space, comp);
	bigint::Limb[1] one_limbs;
	bigint::BigIntConst one = bigint::init_u64(one_limbs[..], 1).to_const();
	bigint::Limb[] result_limbs = alloc::new_array(tmem, bigint::Limb, (usz)(current_big.limbs.len + 1));
	bigint::BigIntMutable result = { .limbs = result_limbs, .len = 1, .positive = true };
	result.add(current_big, one);
	return value::intern_big(comp, result.to_const());
}

fn bool enum_value_fits(value::Value val, type_store::QualType qt, compilation::Compilation* comp)
{
	value_interner::BigIntSpace space;
	bigint::BigIntConst big = val.to_big_int(&space, comp);
	return big.fits_in_twos_comp(qt.signedness(comp), qt.bit_sizeof(comp));
}

fn type_store::QualType next_larger_enum_int(type_store::QualType qt, compilation::Compilation* comp)
{
	type_store::QualType[5] signed_types = { type_store::SHORT, type_store::INT, type_store::INT24,
		type_store::LONG, type_store::LONG_LONG };
	type_store::QualType[5] unsigned_types = { type_store::USHORT, type_store::UINT, type_store::UINT24,
		type_store::ULONG, type_store::ULONG_LONG };
	type_store::QualType[] candidates = qt.signedness(comp) == lang_opts::Signedness.SIGNED ? signed_types[..] : unsigned_types[..];
	ulong bits = qt.bit_sizeof(comp);
	foreach (candidate : candidates)
	{
		if (!comp.langopts.has_int24 && candidate.eql(type_store::INT24, comp)) continue;
		if (!comp.langopts.has_int24 && candidate.eql(type_store::UINT24, comp)) continue;
		if (candidate.bit_sizeof(comp) > bits) return candidate;
	}
	return type_store::INVALID;
}

struct Enumerator
{
	value::Value val;
	type_store::QualType qt;
	usz num_positive_bits;
	usz num_negative_bits;
	bool fixed;
}

fn Enumerator enum_enumerator(parser::ContainerBodySeed seed)
{
	return {
		.val = value::NONE,
		.qt = seed.has_fixed ? seed.fixed_qt : type_store::INT,
		.fixed = seed.has_fixed,
	};
}

fn void? emit_enum_not_representable_fixed(parser::Parser* p, type_store::QualType qt, tokens::TokenIndex tok)
{
	return p.err(parser_diagnostics::ParserDiag.ENUM_NOT_REPRESENTABLE_FIXED, tok, p.fmt_qt(qt));
}

fn void? Enumerator.incr(&self, parser::Parser* p, tokens::TokenIndex tok)
{
	if (self.val.is_none())
	{
		self.val = value::ZERO;
		return;
	}

	value::Value old_val = self.val;
	value::Value next_val = value::NONE;
	bool overflow = next_val.add(old_val, value::ONE, self.qt, p.comp);
	if (!overflow)
	{
		self.val = next_val;
		return;
	}
	if (self.fixed)
	{
		emit_enum_not_representable_fixed(p, self.qt, tok)!;
		self.val = next_val;
		return;
	}

	type_store::QualType larger_qt = next_larger_enum_int(self.qt, p.comp);
	if (!larger_qt.is_invalid())
	{
		p.err(parser_diagnostics::ParserDiag.ENUMERATOR_OVERFLOW, tok)!;
		self.qt = larger_qt;
	}
	else
	{
		value::Value unbounded_next = increment_enum_value(old_val, p.comp);
		value_interner::BigIntSpace value_space;
		bigint::BigIntConst value_bigint = unbounded_next.to_big_int(&value_space, p.comp);
		String value_text = value_bigint.to_string_alloc(tmem, 10, false);
		p.err(parser_diagnostics::ParserDiag.ENUM_NOT_REPRESENTABLE, tok, value_text)!;
		// Keep the unbounded value in the diagnostic, but wrap the stored value at ULL width.
		self.qt = type_store::ULONG_LONG;
		self.val = value::NONE;
		self.val.add(old_val, value::ONE, self.qt, p.comp);
		return;
	}

	self.val = value::NONE;
	self.val.add(old_val, value::ONE, self.qt, p.comp);
}

fn void? Enumerator.set(&self, parser::Parser* p, parser_result::Result* result, tokens::TokenIndex tok)
{
	if (result.qt.is_invalid()) return;
	if (self.fixed)
	{
		if (!result.qt.eql(self.qt, p.comp))
		{
			if (!enum_value_fits(result.val, self.qt, p.comp))
			{
				emit_enum_not_representable_fixed(p, self.qt, tok)!;
				return PARSING_FAILED~;
			}
			result.qt = self.qt;
			result.implicit_cast(p, tree::CastKind.INT_CAST);
		}
		self.val = result.val;
		return;
	}

	result.cast_to_int(p, result.qt.promote_int(p.comp), tok, false)!;
	self.qt = result.qt;
	self.val = result.val;
}

fn void Enumerator.update_bits(&self, compilation::Compilation* comp)
{
	if (self.qt.signedness(comp) == lang_opts::Signedness.UNSIGNED ||
		value::compare(self.val, bigint::CompareOperator.GTE, value::ZERO, comp))
	{
		usz bits = (usz)self.val.min_unsigned_bits(comp);
		if (self.num_positive_bits < bits) self.num_positive_bits = bits;
	}
	else
	{
		usz bits = (usz)self.val.min_signed_bits(comp);
		if (self.num_negative_bits < bits) self.num_negative_bits = bits;
	}
}

fn bool enum_value_fits_type(value::Value val, type_store::QualType src_qt,
	type_store::QualType dest_qt, compilation::Compilation* comp)
{
	if (!value::compare(val, bigint::CompareOperator.LTE, value::max_int(dest_qt, comp), comp)) return false;
	return src_qt.signedness(comp) == lang_opts::Signedness.UNSIGNED ||
		value::compare(val, bigint::CompareOperator.GTE, value::min_int(dest_qt, comp), comp);
}

fn type_store::QualType? Enumerator.get_type_specifier(&self, parser::Parser* p, bool is_packed, tokens::TokenIndex tok)
{
	usz char_width = (usz)type_store::SCHAR.bit_sizeof(p.comp);
	usz short_width = (usz)type_store::SHORT.bit_sizeof(p.comp);
	usz int_width = (usz)type_store::INT.bit_sizeof(p.comp);
	if (self.num_negative_bits > 0)
	{
		if (is_packed && self.num_negative_bits <= char_width && self.num_positive_bits < char_width) return type_store::SCHAR;
		if (is_packed && self.num_negative_bits <= short_width && self.num_positive_bits < short_width) return type_store::SHORT;
		if (self.num_negative_bits <= int_width && self.num_positive_bits < int_width) return type_store::INT;
		if (self.num_negative_bits == 24 && self.num_positive_bits < 24 && p.comp.langopts.has_int24) return type_store::INT24;
		usz long_width = (usz)type_store::LONG.bit_sizeof(p.comp);
		if (self.num_negative_bits <= long_width && self.num_positive_bits < long_width) return type_store::LONG;
		usz long_long_width = (usz)type_store::LONG_LONG.bit_sizeof(p.comp);
		if (self.num_negative_bits > long_long_width || self.num_positive_bits >= long_long_width)
		{
			p.err(parser_diagnostics::ParserDiag.ENUM_TOO_LARGE, tok)!;
		}
		return type_store::LONG_LONG;
	}
	if (is_packed && self.num_positive_bits <= char_width) return type_store::UCHAR;
	if (is_packed && self.num_positive_bits <= short_width) return type_store::USHORT;
	if (self.num_positive_bits <= int_width) return type_store::UINT;
	if (self.num_positive_bits == 24 && p.comp.langopts.has_int24) return type_store::UINT24;
	if (self.num_positive_bits <= (usz)type_store::LONG.bit_sizeof(p.comp)) return type_store::ULONG;
	return type_store::ULONG_LONG;
}

<* Zig Parser.skipTo(.r_brace): skip to the enum's closing brace at zero paren
   depth and consume it, so a failed body leaves the following ';' to the
   root recovery exactly as Zig does. *>
fn void skip_to_enum_close(parser::Parser* p)
{
	uint parens = 0;
	while (!p.at_eof())
	{
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		if (id == tokenizer::TokenId.R_BRACE && parens == 0)
		{
			p.advance();
			return;
		}
		if (id == tokenizer::TokenId.L_PAREN || id == tokenizer::TokenId.L_BRACE || id == tokenizer::TokenId.L_BRACKET)
		{
			parens++;
		}
		else if ((id == tokenizer::TokenId.R_PAREN || id == tokenizer::TokenId.R_BRACE || id == tokenizer::TokenId.R_BRACKET) && parens > 0)
		{
			parens--;
		}
		p.advance();
	}
}

fn type_store::QualType? DeclarationParser.parse_enum_body(&self, parser::Parser* p, parser::ContainerBodySeed seed)
{
	attribute_wip::Wip enum_wip;
	enum_wip.init(p.comp.gpa);
	defer enum_wip.free();
	attribute_wip::State enum_state = enum_wip.state(true);
	defer enum_wip.restore(enum_state);
	list::List{type_store::EnumField} enum_fields;
	list::List{type_store::NodeIndex} field_nodes;
	enum_fields.init(p.comp.gpa);
	field_nodes.init(p.comp.gpa);
	defer { enum_fields.free(); field_nodes.free(); }
	// Zig: errdefer if (!done) p.skipTo(.r_brace);
	bool done = false;
	defer
	{
		if (!done) skip_to_enum_close(p);
	}
	Enumerator enumerator = enum_enumerator(seed);

	while (!p.at_eof() && !p.is_at(tokenizer::TokenId.R_BRACE))
	{
		// Zig enumerator replays pragmas before each enumerator.
		bool? replay_result = p.replay_pragma();
		fault pragma_fault = @catch(replay_result);
		if (pragma_fault) return pragma_fault~;
		if (try handled = replay_result)
		{
			if (handled) continue;
		}
		if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
		{
			p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!;
			return PARSING_FAILED~;
		}
		tokens::TokenIndex name_tok = p.tok_i;
		string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
		p.advance();
		attribute_wip::State member_state = enum_wip.state(true);
		self.append_attributes(p, &enum_wip)!;
		uint prev_total = p.diagnostics.total;
		type_store::NodeOptIndex init = type_store::NODE_NULL;
		if (p.is_at(tokenizer::TokenId.EQUAL))
		{
			p.advance();
			parser_result::Result? maybe_value = p.integer_const_expr(true,
				parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION);
			if (catch f = maybe_value) return f~;
			parser_result::Result value_result = maybe_value;
			if (value_result.val.is_none())
			{
				p.err(parser_diagnostics::ParserDiag.ENUM_VAL_UNAVAILABLE, name_tok + 2)!;
				enumerator.incr(p, name_tok)!;
			}
			else
			{
				if (catch enumerator.set(p, &value_result, name_tok)) return PARSING_FAILED~;
				init = value_result.node.pack();
			}
		}
		else
		{
			enumerator.incr(p, name_tok)!;
		}
		if (enumerator.val.is_none()) enumerator.val = value::ZERO;
		enumerator.update_bits(p.comp);

		if (prev_total == p.diagnostics.total)
		{
			if (value::compare(enumerator.val, bigint::CompareOperator.LT, value::ZERO, p.comp))
			{
				if (value::compare(enumerator.val, bigint::CompareOperator.LT,
					value::min_int(type_store::INT, p.comp), p.comp))
				{
					p.err(parser_diagnostics::ParserDiag.ENUMERATOR_TOO_SMALL, name_tok,
						p.fmt_value(enumerator.val, enumerator.qt))!;
				}
			}
			else if (value::compare(enumerator.val, bigint::CompareOperator.GT,
				value::max_int(type_store::INT, p.comp), p.comp))
			{
				p.err(parser_diagnostics::ParserDiag.ENUMERATOR_TOO_LARGE, name_tok,
					p.fmt_value(enumerator.val, enumerator.qt))!;
			}
		}

		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.ENUM_FIELD,
			.enum_field = { .name_tok = name_tok, .qt = enumerator.qt, .init = init } });
		enum_wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
		p.tree.set_value(node, enumerator.val);
		symbol_stack::SymbolContext sym_ctx = self.symbol_context(p);
		p.symbols.define_enumeration(&sym_ctx, name, enumerator.qt, name_tok, enumerator.val, node)!;
		enum_fields.push({ .qt = enumerator.qt, .name = name, .name_tok = (type_store::TokenIndex)name_tok });
		field_nodes.push(node);
		enum_wip.restore(member_state);
		if (p.is_at(tokenizer::TokenId.COMMA))
		{
			p.advance();
			if (p.is_at(tokenizer::TokenId.R_BRACE)) break;
		}
		else { break; }
	}
	if (catch p.expect(tokenizer::TokenId.R_BRACE)) return PARSING_FAILED~;
	done = true;
	self.apply_tag_body_end_attributes(p, seed)!;

	type_store::EnumField[] fields = enum_fields.array_view();
	type_store::NodeIndex[] fixup_nodes = field_nodes.array_view();
	type_store::QualType tag_qt = seed.has_fixed ? seed.fixed_qt : type_store::INVALID;
	if (!seed.has_fixed)
	{
		bool is_packed = p.comp.langopts.short_enums || p.comp.target.pack_all_enums() ||
			seed.qt.has_attribute(&p.tree, attribute::AttributeTag.PACKED);
		// Zig: maybe_ident orelse enum_tok.
		tag_qt = enumerator.get_type_specifier(p, is_packed, seed.name_tok != 0 ? seed.name_tok : seed.keyword_tok)!;

		bool keep_int = enumerator.num_positive_bits < (usz)type_store::INT.bit_sizeof(p.comp);
		for (usz i = 0; i < fields.len; i++)
		{
			type_store::EnumField* field = &fields[i];
			symbol_stack::Symbol* symbol = p.symbols.get_ptr(field.name, symbol_stack::ScopeKind.VARS);
			if (symbol.kind != symbol_stack::SymbolKind.ENUMERATION) continue;
			type_store::QualType dest_qt = tag_qt;
			if (keep_int && enum_value_fits_type(symbol.val, field.qt, type_store::INT, p.comp)) dest_qt = type_store::INT;
			if (field.qt.eql(dest_qt, p.comp)) continue;

			symbol.val.int_cast(dest_qt, p.comp);
			p.tree.set_value(fixup_nodes[i], symbol.val);
			symbol.qt = dest_qt;
			field.qt = dest_qt;
			tree::Node field_node = fixup_nodes[i].get(&p.tree);
			field_node.enum_field.qt = dest_qt;
			if (!field_node.enum_field.init.is_null())
			{
				parser_result::Result result;
				result.init(field_node.enum_field.init.unwrap(), dest_qt, symbol.val);
				result.implicit_cast(p, tree::CastKind.INT_CAST);
				field_node.enum_field.init = result.node.pack();
			}
			p.tree.set_node(field_node, (sz)fixup_nodes[i]);
		}
	}
	p.comp.type_store.set({ .tag = type_store::TypeTag.ENUM, .enum_ty = {
		.has_tag = true, .tag = tag_qt,
		.fixed = seed.has_fixed, .incomplete = false,
		.name = seed.name, .decl_node = seed.decl_node, .fields = fields,
	} }, seed.qt.index);
	type_store::NodeIndex[] nodes = field_nodes.array_view();
	p.tree.set_node({ .kind = tree::NodeKind.ENUM_DECL, .container_decl = {
		.name_or_kind_tok = seed.name_tok != 0 ? seed.name_tok : seed.keyword_tok,
		.container_qt = seed.qt, .fields = nodes,
	} }, (sz)seed.decl_node);
	return seed.qt;
}

fn TypeSpecifierToken type_specifier_token(tokenizer::TokenId id)
{
	type_store::BuilderSpecifierTag tag = type_store::BuilderSpecifierTag.NONE;
	switch (id)
	{
		case KEYWORD_VOID: tag = type_store::BuilderSpecifierTag.VOID;
		case KEYWORD_BOOL: case KEYWORD_C23_BOOL: tag = type_store::BuilderSpecifierTag.BOOL;
		case KEYWORD_NULLPTR: tag = type_store::BuilderSpecifierTag.NULLPTR_T;
		case KEYWORD_CHAR: tag = type_store::BuilderSpecifierTag.CHAR;
		case KEYWORD_INT8: case KEYWORD_INT8_2: tag = type_store::BuilderSpecifierTag.CHAR;
		case KEYWORD_SIGNED: case KEYWORD_SIGNED1: case KEYWORD_SIGNED2: tag = type_store::BuilderSpecifierTag.SIGNED;
		case KEYWORD_UNSIGNED: tag = type_store::BuilderSpecifierTag.UNSIGNED;
		case KEYWORD_INT16: case KEYWORD_INT16_2: tag = type_store::BuilderSpecifierTag.SHORT;
		case KEYWORD_SHORT: tag = type_store::BuilderSpecifierTag.SHORT;
		case KEYWORD_INT32: case KEYWORD_INT32_2: tag = type_store::BuilderSpecifierTag.INT;
		case KEYWORD_INT: tag = type_store::BuilderSpecifierTag.INT;
		case KEYWORD_LONG: tag = type_store::BuilderSpecifierTag.LONG;
		case KEYWORD_INT64: case KEYWORD_INT64_2: tag = type_store::BuilderSpecifierTag.LONG_LONG;
		case KEYWORD_FLOAT: tag = type_store::BuilderSpecifierTag.FLOAT;
		case KEYWORD_DOUBLE: tag = type_store::BuilderSpecifierTag.DOUBLE;
		case KEYWORD_COMPLEX: tag = type_store::BuilderSpecifierTag.COMPLEX;
		case KEYWORD_FLOAT16: tag = type_store::BuilderSpecifierTag.FLOAT16;
		case KEYWORD_FLOAT32: tag = type_store::BuilderSpecifierTag.FLOAT32;
		case KEYWORD_FLOAT64: tag = type_store::BuilderSpecifierTag.FLOAT64;
		case KEYWORD_FLOAT128: case KEYWORD_FLOAT128_1: tag = type_store::BuilderSpecifierTag.FLOAT128;
		case KEYWORD_FLOAT32X: tag = type_store::BuilderSpecifierTag.FLOAT32X;
		case KEYWORD_FLOAT64X: tag = type_store::BuilderSpecifierTag.FLOAT64X;
		case KEYWORD_FLOAT128X: tag = type_store::BuilderSpecifierTag.FLOAT128X;
		case KEYWORD_DFLOAT32: tag = type_store::BuilderSpecifierTag.DFLOAT32;
		case KEYWORD_DFLOAT64: tag = type_store::BuilderSpecifierTag.DFLOAT64;
		case KEYWORD_DFLOAT128: tag = type_store::BuilderSpecifierTag.DFLOAT128;
		case KEYWORD_DFLOAT64X: tag = type_store::BuilderSpecifierTag.DFLOAT64X;
		case KEYWORD_FP16: tag = type_store::BuilderSpecifierTag.FP16;
		case KEYWORD_BF16: tag = type_store::BuilderSpecifierTag.BF16;
		case KEYWORD_INT128: tag = type_store::BuilderSpecifierTag.INT128;
		case KEYWORD_INT24: tag = type_store::BuilderSpecifierTag.INT24;
		default: return {};
	}
	return { .matched = true, .specifier = { .tag = tag } };
}

fn bool is_typeof_token(tokenizer::TokenId id)
{
	switch (id)
	{
		case KEYWORD_TYPEOF: case KEYWORD_TYPEOF1: case KEYWORD_TYPEOF2: case KEYWORD_TYPEOF_UNQUAL:
			return true;
		default: return false;
	}
}

fn bool is_const_token(tokenizer::TokenId id) => id == KEYWORD_CONST || id == KEYWORD_CONST1 || id == KEYWORD_CONST2;
fn bool is_volatile_token(tokenizer::TokenId id) => id == KEYWORD_VOLATILE || id == KEYWORD_VOLATILE1 || id == KEYWORD_VOLATILE2;
fn bool is_restrict_token(tokenizer::TokenId id) => id == KEYWORD_RESTRICT || id == KEYWORD_RESTRICT1 || id == KEYWORD_RESTRICT2;

fn bool DeclarationParser.starts_decl_specifier(&self, parser::Parser* p)
{
	if (p.at_eof()) return false;
	tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
	if (type_specifier_token(id).matched || is_const_token(id) || is_volatile_token(id) || is_restrict_token(id)) return true;
	switch (id)
	{
		case KEYWORD_BIT_INT: case KEYWORD_TYPEOF: case KEYWORD_TYPEOF1: case KEYWORD_TYPEOF2: case KEYWORD_TYPEOF_UNQUAL:
		case KEYWORD_AUTO: case KEYWORD_AUTO_TYPE: case KEYWORD_TYPEDEF: case KEYWORD_EXTERN:
		case KEYWORD_STATIC: case KEYWORD_REGISTER: case KEYWORD_THREAD_LOCAL: case KEYWORD_THREAD:
		case KEYWORD_CONSTEXPR: case KEYWORD_INLINE: case KEYWORD_INLINE1: case KEYWORD_INLINE2:
	case KEYWORD_ATOMIC: case KEYWORD_STRUCT: case KEYWORD_UNION: case KEYWORD_ENUM:
	case KEYWORD_ATTRIBUTE1: case KEYWORD_ATTRIBUTE2: case KEYWORD_DECLSPEC:
			return true;
		case IDENTIFIER: case EXTENDED_IDENTIFIER:
			symbol_stack::Symbol sym;
			string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(p.tok_i));
			return p.find_typedef(name, p.tok_i, true, &sym) ?? false;
		default: return false;
	}
}

<* Parse declaration specifiers while preserving the parser's cursor on a
   non-match. Typedef names share ordinary identifier lookup with expressions. *>
fn DeclSpec? DeclarationParser.parse_decl_spec(&self, parser::Parser* p, attribute_wip::Wip* wip, bool allow_storage = true)
{
	tokens::TokenIndex start_tok = p.tok_i;
	attribute_wip::State saved_wip = wip.state(false);
	bool committed = false;
	defer
	{
		if (!committed)
		{
			wip.restore(saved_wip);
			p.tok_i = start_tok;
		}
	}
	DeclSpec result = {};
	type_store::Builder builder = { .parser = p };
	bool consumed = false;
	while (!p.at_eof())
	{
		uint attr_count = self.append_attributes(p, wip)!;
		if (attr_count > 0) continue;
		tokens::TokenIndex tok = p.tok_i;
		tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
		TypeSpecifierToken specifier = type_specifier_token(id);
		if (is_typeof_token(id))
		{
			type_store::QualType? typeof_type = self.parse_typeof_specifier(p, id);
			if (catch typeof_type) return PARSING_FAILED~;
			if (catch builder.combine_from_typeof(typeof_type, tok)) return PARSING_FAILED~;
			consumed = true; result.recognized = true; continue;
		}
		if (id == KEYWORD_BIT_INT)
		{
			p.err(parser_diagnostics::ParserDiag.BIT_INT, tok)!;
			p.advance();
			tokens::TokenIndex opener = p.tok_i;
			if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
			parser_result::Result? maybe_width = p.integer_const_expr();
			if (catch maybe_width) return PARSING_FAILED~;
			parser_result::Result width = maybe_width;
			if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
			if (width.val.is_none())
			{
				p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_INTEGER_CONSTANT_EXPR,
					"expression is not an integer constant expression", width.node.tok(&p.tree))!;
				return PARSING_FAILED~;
			}
			ulong bits = 0;
			if (!value::compare(width.val, bigint::CompareOperator.LTE, value::ZERO, p.comp))
			{
				bits = width.val.to_u64(p.comp) ?? ulong::max;
			}
			if (catch builder.combine({ .tag = type_store::BuilderSpecifierTag.BIT_INT, .bits = bits }, tok)) return PARSING_FAILED~;
			consumed = true; result.recognized = true; continue;
		}
		if (specifier.matched)
		{
			if (catch builder.combine(specifier.specifier, tok)) return PARSING_FAILED~;
			p.advance(); consumed = true; result.recognized = true; continue;
		}
		if (is_const_token(id)) { builder.has_const = true; builder.const_tok = tok; p.advance(); consumed = true; result.recognized = true; continue; }
		if (is_volatile_token(id)) { builder.has_volatile = true; builder.volatile_tok = tok; p.advance(); consumed = true; result.recognized = true; continue; }
		if (is_restrict_token(id)) { builder.has_restrict = true; builder.restrict_tok = tok; p.advance(); consumed = true; result.recognized = true; continue; }
		if (id == KEYWORD_AUTO_TYPE)
		{
			p.err(parser_diagnostics::ParserDiag.AUTO_TYPE_EXTENSION, tok)!;
			if (catch builder.combine({ .tag = type_store::BuilderSpecifierTag.AUTO_TYPE }, tok)) return PARSING_FAILED~;
			result.auto_type_tok = tok;
			p.advance(); consumed = true; result.recognized = true; continue;
		}
		if (id == KEYWORD_AUTO && p.comp.langopts.standard.at_least(C23))
		{
			if (catch builder.combine({ .tag = type_store::BuilderSpecifierTag.C23_AUTO }, tok)) return PARSING_FAILED~;
			result.c23_auto_tok = tok;
			p.advance(); consumed = true; result.recognized = true; continue;
		}
		if (id == KEYWORD_ATOMIC)
		{
			p.advance(); consumed = true; result.recognized = true;
			if (p.is_at(tokenizer::TokenId.L_PAREN))
			{
				tokens::TokenIndex opener = p.tok_i;
				p.advance();
				type_store::QualType? atomic_type = self.parse_typed_type_name(p);
				if (catch atomic_type) return PARSING_FAILED~;
				if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
				if (catch builder.combine_atomic(atomic_type, tok)) return PARSING_FAILED~;
			}
			else { builder.has_atomic = true; builder.atomic_tok = tok; }
			continue;
		}
		if (id == KEYWORD_STRUCT || id == KEYWORD_UNION || id == KEYWORD_ENUM)
		{
			type_store::QualType? record_type = self.parse_record_specifier(p, id == KEYWORD_ENUM);
			if (catch record_type) return PARSING_FAILED~;
			if (catch builder.combine({ .tag = type_store::BuilderSpecifierTag.OTHER, .other = record_type }, tok)) return PARSING_FAILED~;
			consumed = true; result.recognized = true; continue;
		}
		if (allow_storage)
		{
			switch (id)
			{
				case KEYWORD_TYPEDEF: result.storage_class = TYPEDEF;
				case KEYWORD_EXTERN: result.storage_class = EXTERN;
				case KEYWORD_STATIC: result.storage_class = STATIC;
				case KEYWORD_AUTO: result.storage_class = AUTO; result.auto_tok = tok;
				case KEYWORD_REGISTER: result.storage_class = REGISTER;
				case KEYWORD_THREAD_LOCAL: case KEYWORD_THREAD: result.thread_local = true;
				case KEYWORD_CONSTEXPR: result.constexpr_decl = true;
				case KEYWORD_INLINE: case KEYWORD_INLINE1: case KEYWORD_INLINE2: result.is_inline = true;
				default: break;
			}
			if (id == KEYWORD_TYPEDEF || id == KEYWORD_EXTERN || id == KEYWORD_STATIC || id == KEYWORD_AUTO || id == KEYWORD_REGISTER ||
				id == KEYWORD_THREAD_LOCAL || id == KEYWORD_THREAD || id == KEYWORD_CONSTEXPR || id == KEYWORD_INLINE || id == KEYWORD_INLINE1 || id == KEYWORD_INLINE2)
			{
				p.advance(); consumed = true; result.recognized = true; continue;
			}
		}
		if (id == IDENTIFIER || id == EXTENDED_IDENTIFIER)
		{
			if (builder.type.tag != type_store::BuilderSpecifierTag.NONE) break;
			symbol_stack::Symbol typedef_symbol;
			string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(tok));
			if (p.find_typedef(name, tok, true, &typedef_symbol)!)
			{
				p.mark_used(typedef_symbol.node);
				if (!builder.combine_typedef(typedef_symbol.qt)) break;
				p.advance(); consumed = true; result.recognized = true; continue;
			}
		}
		break;
	}
	if (!consumed) return NO_DECL_SPEC~;
	result.qt = builder.finish()!;
	result.qt = wip.apply_type_attrs(p, result.qt)!;
	committed = true;
	return result;
}

fn type_store::QualType? DeclarationParser.parse_typeof_specifier(&self, parser::Parser* p, tokenizer::TokenId id)
{
	bool unqual = id == tokenizer::TokenId.KEYWORD_TYPEOF_UNQUAL;
	p.advance();
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;

	parser::TypeNameProbe? maybe_type_name = p.probe_typed_type_name();
	if (catch maybe_type_name) return PARSING_FAILED~;
	parser::TypeNameProbe type_name = maybe_type_name;
	if (type_name.matched)
	{
		if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
		if (type_name.qt.is_invalid()) return type_store::INVALID;
		type_store::QualType operand_type = unqual ? type_name.qt.base(p.comp).qt.unqualified() : type_name.qt;
		type_store::QualType result = p.comp.type_store.put(type_store::type_typeof(operand_type));
		if (!unqual) result = result.with_qualifiers(type_name.qt);
		return result;
	}

	parser_result::Result? maybe_expr = p.expr(false);
	if (catch maybe_expr) return PARSING_FAILED~;
	parser_result::Result expr = maybe_expr;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	if (expr.qt.is_invalid()) return type_store::INVALID;
	type_store::QualType operand_type = unqual ? expr.qt.base(p.comp).qt.unqualified() : expr.qt;
	type_store::QualType result = p.comp.type_store.put(type_store::type_typeof_expr(operand_type, expr.node));
	if (!unqual) result = result.with_qualifiers(expr.qt);
	return result;
}

fn type_store::QualType? DeclarationParser.parse_typed_type_name(&self, parser::Parser* p)
{
	attribute_wip::Wip wip;
	wip.init(p.comp.gpa);
	defer wip.free();
	attribute_wip::State state = wip.state(true);
	defer wip.restore(state);
	DeclSpec? spec = self.parse_decl_spec(p, &wip, false);
	if (catch spec) return PARSING_FAILED~;
	if (spec.qt.is_auto())
	{
		emit_deduced_type_not_allowed(p, spec.qt.is_auto_type(), "type name",
			spec.qt.is_auto_type() ? spec.auto_type_tok : spec.c23_auto_tok)!;
		spec.qt = type_store::INVALID;
	}
	parser_declarator::DeclaratorParser declarator = {
		.parser = p,
		.type_name = &typed_type_name_callback,
		.parameter_declaration = &parameter_declaration_callback,
		.has_parameter_declaration = true,
		.context = (void*)self,
	};
	type_store::QualType? maybe_qt = declarator.abstract_declarator(spec.qt);
	if (catch f = maybe_qt) return f~;
	type_store::QualType qt = maybe_qt;
	self.append_attributes(p, &wip)!;
	return wip.apply_type_attrs(p, qt);
}

fn parser::TypeNameProbe? DeclarationParser.probe_typed_type_name(&self, parser::Parser* p)
{
	// Auto specifiers describe declarations, not type names. Leave a leading
	// auto token to the expression parser so casts such as `(__auto_type)5`
	// produce the expected-expression diagnostic.
	if (p.is_at(tokenizer::TokenId.KEYWORD_AUTO_TYPE) ||
		(p.comp.langopts.standard.at_least(C23) && p.is_at(tokenizer::TokenId.KEYWORD_AUTO)))
	{
		return { .matched = false };
	}
	if (!self.starts_decl_specifier(p)) return { .matched = false };
	type_store::QualType? qt = self.parse_typed_type_name(p);
	if (catch qt) return PARSING_FAILED~;
	return { .matched = true, .qt = qt };
}

fn void? DeclarationParser.handle_implicit_typedefs(&self, parser::Parser* p) @dynamic
{
	if (!self.has_implicit_typedefs) return parser::HOOK_ABSENT~;
	return self.implicit_typedefs(self.context, p);
}

<* Zig `Parser.parse` expected_implicit_typedef_max: the token capacity reserved for
   the generated identifiers, and the bound on how many implicit typedefs the prelude adds. *>
const usz EXPECTED_IMPLICIT_TYPEDEF_MAX = 7;

<* Zig `Parser.addImplicitTypedef`. `name` plus '\n' goes to comp.generated_buf, and its
   identifier token is a GENERATED_ID token at that offset. The implicit TYPEDEF node
   becomes the next translation-unit root, and the typedef type and symbol are defined in
   the outer scope. *>
fn void? add_implicit_typedef(parser::Parser* p, String name, type_store::QualType qt)
{
	sz start = p.comp.generated_buf.len();
	p.comp.generated_buf.push_all((char[])name);
	p.comp.generated_buf.push('\n');

	tokens::TokenIndex name_tok = (tokens::TokenIndex)p.pp.tokens.len();
	p.pp.tokens.push({ .id = tokenizer::TokenId.IDENTIFIER, .loc = {
		.id = source::GENERATED_ID, .byte_offset = (uint)start, .line = p.pp.generated_line,
	} });
	p.pp.generated_line++;

	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.TYPEDEF, .type_def = {
		.name_tok = name_tok, .qt = qt, .implicit = true,
	} });
	string_interner::StringId interned_name = p.comp.intern_string(name);
	type_store::QualType typedef_qt = p.comp.type_store.put(type_store::type_typedef(qt, interned_name, node)).with_qualifiers(qt);
	symbol_stack::SymbolContext sym_ctx = p.symbol_context();
	type_store::NodeOptIndex previous = p.symbols.define_typedef(&sym_ctx, interned_name, typedef_qt, name_tok, node)!;
	assert(previous == type_store::NODE_NULL, "implicit typedef names should be unique in the outer scope");
	p.tree.root_decls.push(node);
}

<* Zig `Parser.parse` implicit typedef prelude, in Zig's order. char8_t, __int24 and
   __mfp8 follow LangOpts and Target; __float80 follows the emulated compiler. The
   callback runs before any declaration, so every entry is a leading root. *>
fn void? implicit_typedef_prelude(void* context, parser::Parser* p)
{
	p.pp.ensure_unused_token_capacity(EXPECTED_IMPLICIT_TYPEDEF_MAX);
	if (p.comp.langopts.has_char8_t()) add_implicit_typedef(p, "char8_t", type_store::UCHAR)!;
	add_implicit_typedef(p, "__int128_t", type_store::INT128)!;
	add_implicit_typedef(p, "__uint128_t", type_store::UINT128)!;
	if (p.comp.langopts.has_int24)
	{
		add_implicit_typedef(p, "__int24__", type_store::INT24)!;
		add_implicit_typedef(p, "__uint24", type_store::UINT24)!;
	}
	add_implicit_typedef(p, "__builtin_ms_va_list", type_store::CHAR_POINTER)!;

	// Zig decays va_list only after its typedef is added, so the typedef keeps the array type.
	type_store::QualType va_list_qt = p.comp.type_store.va_list;
	add_implicit_typedef(p, "__builtin_va_list", va_list_qt)!;
	p.comp.type_store.va_list = va_list_qt.decay(p.comp);

	add_implicit_typedef(p, "__NSConstantString", p.comp.type_store.ns_constant_string)!;
	if (try float80_ty = p.comp.float80_type()) add_implicit_typedef(p, "__float80", float80_ty)!;
	if (p.comp.target.has_aarch64_acle_types()) add_implicit_typedef(p, "__mfp8", type_store::MFP8)!;

	assert((usz)p.tree.root_decls.len() <= EXPECTED_IMPLICIT_TYPEDEF_MAX);
}

<* Adapter callbacks keep initializer grammar on Parser's composed
   assignment-expression and integer-constant-expression entry points. *>
fn parser_result::Result? initializer_assignment_expression(void* context, parser::Parser* p, bool eval)
{
	return p.assign_expr(eval);
}

fn parser_result::Result? initializer_integer_constant_expression(void* context, parser::Parser* p,
	parser::ConstDeclFoldingMode folding_mode)
{
	return p.integer_const_expr(true, folding_mode);
}

<* The default statement binding must use the same parser-owned expression
   composition as declarations and initializers. *>
fn parser_result::Result? declaration_statement_expression(void* context, parser::Parser* p, bool eval)
{
	return p.expr(eval);
}

fn parser_result::Result? declaration_statement_integer_constant_expression(void* context,
	parser::Parser* p, parser::ConstDeclFoldingMode folding_mode, bool eval)
{
	return p.integer_const_expr(eval, folding_mode);
}

fn symbol_stack::SymbolContext DeclarationParser.symbol_context(&self, parser::Parser* p)
{
	return p.symbol_context();
}

<* Parse the adjacent GNU, C23, or declspec attributes into the current Wip,
 evaluating each borrowed argument range through Parser's composed expression
 entry point. *>
fn uint? DeclarationParser.append_attributes(&self, parser::Parser* p, attribute_wip::Wip* wip)
{
	parser_attribute::AttributeBuffer buffer;
	buffer.init(p.comp.gpa);
	defer buffer.free();
	uint count = p.parse_attribute_specifiers(&buffer)!;
	if (count > 0) parser_statement::append_statement_attributes(p, &buffer, wip)!;
	return count;
}

fn parser_declarator::DeclaratorParser DeclarationParser.declarator_parser(&self, parser::Parser* p)
{
	return {
		.parser = p,
		.context = (void*)self,
		.type_name = &typed_type_name_callback,
		.parameter_declaration = &parameter_declaration_callback,
		.has_parameter_declaration = true,
	};
}

<* Parse one parameter declaration in DeclaratorParser's temporary prototype
   scope. Named parameters get their own typed AST nodes and ordinary symbols;
   unnamed parameters remain available as type-only FuncParam entries. *>
fn type_store::FuncParam? DeclarationParser.parse_parameter_declaration(&self, parser::Parser* p)
{
	attribute_wip::Wip wip;
	wip.init(p.comp.gpa);
	defer wip.free();
	attribute_wip::State wip_state = wip.state(true);
	defer wip.restore(wip_state);
	tokens::TokenIndex first_tok = p.tok_i;
	DeclSpec? maybe_spec = self.parse_decl_spec(p, &wip);
	fault spec_fault = @catch(maybe_spec);
	DeclSpec spec;
	if (spec_fault)
	{
		if (spec_fault != NO_DECL_SPEC) return spec_fault~;
		if (p.comp.langopts.standard.at_least(C23) &&
			(p.is_at(tokenizer::TokenId.IDENTIFIER) || p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER)))
		{
			p.err(parser_diagnostics::ParserDiag.UNKNOWN_TYPE_NAME, first_tok,
				p.tree.tok_slice(first_tok))!;
			p.advance();
			// C23 diagnoses the old-style identifier as an unknown type name,
			// but retain it as the parameter name for subsequent definition
			// recovery. This matches the parser's C23 paramDecls fallback.
			return {
				.qt = type_store::INT,
				.name = p.comp.intern_string(p.tree.tok_slice(first_tok)),
				.name_tok = (type_store::TokenIndex)first_tok,
				.node = type_store::NODE_NULL,
			};
		}
		else
		{
			p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_TOKEN, "expected parameter declaration", first_tok)!;
			return PARSING_FAILED~;
		}
	}
	else
	{
		if (try parsed_spec = maybe_spec)
		{
			spec = parsed_spec;
		}
		else
		{
			return NO_DECL_SPEC~;
		}
	}
	if (spec.storage_class != StorageClass.NONE && spec.storage_class != StorageClass.REGISTER)
	{
		p.emit_parser_diag(parser_diagnostics::ParserDiag.INVALID_STORAGE_ON_PARAM,
			"invalid storage class on function parameter", first_tok)!;
	}
	if (spec.qt.is_auto())
	{
		emit_deduced_type_not_allowed(p, spec.qt.is_auto_type(), "function prototype",
			spec.qt.is_auto_type() ? spec.auto_type_tok : spec.c23_auto_tok)!;
		spec.qt = type_store::INVALID;
	}

	parser_declarator::DeclaratorParser declarator = self.declarator_parser(p);
	bool allow_abstract = !parameter_declarator_has_name(p);
	parser_declarator::ParsedDeclarator? maybe_parsed = declarator.parse_declarator(spec.qt, allow_abstract);
	if (catch f = maybe_parsed) return f~;
	parser_declarator::ParsedDeclarator parsed = maybe_parsed;
	type_store::QualType qt = parsed.qt;
	self.append_attributes(p, &wip)!;
	qt = wip.apply_type_attrs(p, qt)!;
	if (qt.is(p.comp, type_store::TypeTag.ARRAY) || qt.is(p.comp, type_store::TypeTag.FUNC))
	{
		qt = qt.decay(p.comp);
	}

	type_store::NodeOptIndex param_node = type_store::NODE_NULL;
	string_interner::StringId name = string_interner::EMPTY;
	tokens::TokenIndex name_tok = first_tok;
	if (parsed.has_name)
	{
		name_tok = parsed.name_tok;
		name = p.comp.intern_string(p.tree.tok_slice(name_tok));
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.PARAM, .param = {
			.name_tok = name_tok,
			.qt = qt,
			.storage_class = spec.storage_class == StorageClass.REGISTER ? tree::ParamStorageClass.REGISTER : tree::ParamStorageClass.AUTO,
		} });
		wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
		param_node = node.pack();
		symbol_stack::SymbolContext sym_ctx = self.symbol_context(p);
		p.symbols.define_param(&sym_ctx, name, qt, name_tok, node)!;
		p.add_maybe_unused(node)!;
	}
	return { .qt = qt, .name = name, .name_tok = (type_store::TokenIndex)name_tok, .node = param_node };
}

fn type_store::FuncParam? parameter_declaration_callback(void* context, parser::Parser* p)
{
	DeclarationParser* self = (DeclarationParser*)context;
	return self.parse_parameter_declaration(p);
}

<* Decide whether an optional parameter declarator carries an identifier.
   The declarator parser owns the grammar itself; this small lookahead only
   selects its named or abstract entry mode. *>
fn bool parameter_declarator_group_has_name(parser::Parser* p, tokens::TokenIndex open)
{
	if ((usz)open + 1 >= (usz)p.tok_end) return false;
	tokenizer::TokenId first = p.tree.tokens[(usz)open + 1].id;
	if (first == IDENTIFIER || first == EXTENDED_IDENTIFIER) return true;
	if (first != ASTERISK && first != L_PAREN) return false;
	uint parens = 0;
	uint brackets = 0;
	for (usz i = (usz)open + 1; i < (usz)p.tok_end; i++)
	{
		tokenizer::TokenId id = p.tree.tokens[i].id;
		switch (id)
		{
			case L_BRACKET: brackets++;
			case R_BRACKET: if (brackets > 0) brackets--;
			case L_PAREN: parens++;
			case R_PAREN:
				if (parens == 0) return false;
				parens--;
			case IDENTIFIER: case EXTENDED_IDENTIFIER:
				if (brackets == 0) return true;
			default: break;
		}
	}
	return false;
}

fn bool parameter_declarator_has_name(parser::Parser* p)
{
	if (p.at_eof()) return false;
	usz i = (usz)p.tok_i;
	tokenizer::TokenId id = p.tree.tokens[i].id;
	if (id == IDENTIFIER || id == EXTENDED_IDENTIFIER) return true;
	if (id == L_PAREN) return parameter_declarator_group_has_name(p, p.tok_i);
	if (id != ASTERISK) return false;
	while (i < (usz)p.tok_end)
	{
		id = p.tree.tokens[i].id;
		if (id == ASTERISK)
		{
			i++;
			while (i < (usz)p.tok_end && (is_const_token(p.tree.tokens[i].id) ||
				is_volatile_token(p.tree.tokens[i].id) || is_restrict_token(p.tree.tokens[i].id))) i++;
			continue;
		}
		if (id == IDENTIFIER || id == EXTENDED_IDENTIFIER) return true;
		if (id == L_PAREN) return parameter_declarator_group_has_name(p, (tokens::TokenIndex)i);
		return false;
	}
	return false;
}

<* Parse a named declarator with this declaration grammar's parameter rule
   installed for any nested function suffixes. *>
fn parser_declarator::ParsedDeclarator? DeclarationParser.parse_named_declarator(&self,
	parser::Parser* p, type_store::QualType base)
{
	parser_declarator::DeclaratorParser declarator = self.declarator_parser(p);
	return declarator.parse_declarator(base);
}

fn tree::VariableStorageClass variable_storage_class(StorageClass storage)
{
	switch (storage)
	{
		case STATIC: return tree::VariableStorageClass.STATIC;
		case EXTERN: return tree::VariableStorageClass.EXTERN;
		case REGISTER: return tree::VariableStorageClass.REGISTER;
		case NONE: case TYPEDEF: case AUTO: return tree::VariableStorageClass.AUTO;
	}
}

fn type_store::NodeIndex DeclarationParser.add_empty_declaration(&self, parser::Parser* p, tokens::TokenIndex semicolon)
{
	return p.tree.add_node({ .kind = tree::NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = semicolon } });
}

<* Bind one declaration's symbol according to whether it is a declaration,
   definition, typedef, or parameter. *>
fn void? DeclarationParser.bind_declaration_symbol(&self, parser::Parser* p,
	string_interner::StringId name, type_store::QualType qt, tokens::TokenIndex name_tok,
	type_store::NodeIndex node, bool is_typedef, bool is_definition, bool constexpr_decl,
	type_store::NodeOptIndex* previous)
{
	symbol_stack::SymbolContext sym_ctx = self.symbol_context(p);
	if (is_typedef)
	{
		*previous = p.symbols.define_typedef(&sym_ctx, name, qt, name_tok, node)!;
		return;
	}
	if (is_definition)
	{
		*previous = p.symbols.define_symbol(&sym_ctx, name, qt, name_tok, node, value::NONE, constexpr_decl)!;
		return;
	}
	*previous = p.symbols.declare_symbol(&sym_ctx, name, qt, name_tok, node)!;
}

<* Set a declaration's actual definition and propagate the link through
   prior declarations of the same symbol. Self-links are terminal. *>
fn void DeclarationParser.handle_tentative_decl_definition(&self, parser::Parser* p,
	type_store::NodeIndex declaration, type_store::NodeIndex definition) @dynamic
{
	self.set_tentative_definition(p, declaration, definition);
}

fn void DeclarationParser.set_tentative_definition(&self, parser::Parser* p,
	type_store::NodeIndex declaration, type_store::NodeIndex definition)
{
	tree::Node node = declaration.get(&p.tree);
	type_store::NodeOptIndex previous = type_store::NODE_NULL;
	switch (node.kind)
	{
		case FUNCTION:
			previous = node.function.definition;
			node.function.definition = definition.pack();
		case VARIABLE:
			previous = node.variable.definition;
			node.variable.definition = definition.pack();
		default: return;
	}
	p.tree.set_node(node, (sz)declaration);
	if (!previous.is_null() && previous.unwrap() != declaration && previous.unwrap() != definition)
	{
		self.set_tentative_definition(p, previous.unwrap(), definition);
	}
	if (p.symbols.active_len == 1)
	{
		self.link_top_level_declarations(p, node, definition);
	}
}

<* Top-level declaration chains can terminate at a tentative self-link before
   a later definition arrives. Update matching file-scope nodes directly so
   every declaration points at the final definition even across that link. *>
fn void DeclarationParser.link_top_level_declarations(&self, parser::Parser* p,
	tree::Node declaration, type_store::NodeIndex definition)
{
	tokens::TokenIndex name_tok;
	if (declaration.kind == tree::NodeKind.FUNCTION) { name_tok = declaration.function.name_tok; }
	else if (declaration.kind == tree::NodeKind.VARIABLE) { name_tok = declaration.variable.name_tok; }
	else { return; }
	string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
	tree::NodeKind declaration_kind = declaration.kind;
	foreach (root_decl : p.tree.root_decls)
	{
		tree::Node prior = root_decl.get(&p.tree);
		if (prior.kind != declaration_kind) continue;
		tokens::TokenIndex prior_name_tok;
		if (prior.kind == tree::NodeKind.FUNCTION) { prior_name_tok = prior.function.name_tok; }
		else { prior_name_tok = prior.variable.name_tok; }
		if (p.comp.intern_string(p.tree.tok_slice(prior_name_tok)) != name) continue;
		if (prior.kind == tree::NodeKind.FUNCTION) { prior.function.definition = definition.pack(); }
		else { prior.variable.definition = definition.pack(); }
		p.tree.set_node(prior, (sz)root_decl);
	}
}

<* Give a file-scope tentative definition of an incomplete array its C-mandated
   one-element type, and keep all file-scope declarations linked to it. *>
fn void DeclarationParser.finalize_tentative_arrays(&self, parser::Parser* p)
{
	foreach (root_decl : p.tree.root_decls)
	{
		tree::Node node = root_decl.get(&p.tree);
		if (node.kind != tree::NodeKind.VARIABLE) continue;
		tree::NodeVariable variable = node.variable;
		if (variable.storage_class == tree::VariableStorageClass.EXTERN ||
		!variable.initializer.is_null() || variable.definition.is_null() ||
		variable.definition.unwrap() != root_decl) continue;
		if (!variable.qt.is(p.comp, type_store::TypeTag.ARRAY)) continue;
		type_store::Array array = variable.qt.get(p.comp, type_store::TypeTag.ARRAY)!!.array;
		if (array.len.kind != type_store::ArrayLenKind.INCOMPLETE) continue;

		type_store::QualType completed_qt = p.comp.type_store.put(type_store::type_array(
			array.elem, type_store::ArrayLenKind.FIXED, 1)).with_qualifiers(variable.qt);
		node.variable.qt = completed_qt;
		p.tree.set_node(node, (sz)root_decl);

		string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(variable.name_tok));
		symbol_stack::Symbol? maybe_symbol = p.symbols.find_symbol(name);
		if (try symbol = maybe_symbol)
		{
			if (symbol.node == root_decl)
			{
				symbol_stack::Symbol* symbol_ptr = p.symbols.get_ptr(name, symbol_stack::ScopeKind.VARS);
				symbol_ptr.qt = completed_qt;
			}
		}
		self.link_top_level_declarations(p, node, root_decl);
	}
}

struct KAndRParameter
{
	type_store::FuncParam param;
}

<* Parse the declaration list between an old-style function declarator and
   its body. Identifier-list parameters start as int and declarations update
   those entries in place. *>
fn type_store::QualType? DeclarationParser.parse_kr_definition_parameters(&self,
	parser::Parser* p, type_store::Func function, list::List{type_store::FuncParam}* extra_params)
{
	list::List{KAndRParameter} params;
	params.init(p.comp.gpa);
	defer params.free();
	list::List{bool} declared;
	declared.init(p.comp.gpa);
	defer declared.free();
	foreach (param : function.params)
	{
		params.push({ .param = param });
		declared.push(false);
	}

	// The declaration list has function-parameter scope. Publish the default
	// int parameters first so earlier parameters can appear in VLA bounds.
	p.push_scope();
	defer p.pop_scope();
	symbol_stack::SymbolContext sym_ctx = self.symbol_context(p);
	KAndRParameter[] param_entries = params.array_view();
	for (usz i = 0; i < param_entries.len; i++)
	{
		type_store::FuncParam param = param_entries[i].param;
		if (param.name == string_interner::EMPTY || param.node.is_null()) continue;
		bool duplicate_name = false;
		for (usz previous = 0; previous < i; previous++)
		{
			if (param_entries[previous].param.name == param.name) { duplicate_name = true; break; }
		}
		if (duplicate_name) continue;
		p.symbols.define_param(&sym_ctx, param.name, param.qt,
			(tokens::TokenIndex)param.name_tok, param.node.unwrap())!;
	}

	bool[] was_declared = declared.array_view();
	attribute_wip::Wip wip;
	wip.init(p.comp.gpa);
	defer wip.free();
	attribute_wip::State outer_wip_state = wip.state(true);
	defer wip.restore(outer_wip_state);
	while (self.starts_decl_specifier(p))
	{
		attribute_wip::State declaration_state = wip.state(true);
		tokens::TokenIndex spec_tok = p.tok_i;
		DeclSpec? maybe_spec = self.parse_decl_spec(p, &wip);
		if (catch f = maybe_spec) return f~;
		DeclSpec spec = maybe_spec;
		if (spec.storage_class != StorageClass.NONE && spec.storage_class != StorageClass.REGISTER)
		{
			p.emit_parser_diag(parser_diagnostics::ParserDiag.INVALID_STORAGE_ON_PARAM,
				"invalid storage class on function parameter", spec_tok)!;
		}
		while (true)
		{
			parser_declarator::ParsedDeclarator? maybe_parsed = self.parse_named_declarator(p, spec.qt);
			if (catch f = maybe_parsed) return f~;
			parser_declarator::ParsedDeclarator parsed = maybe_parsed;
			attribute_wip::State declarator_state = wip.state(false);
			self.append_attributes(p, &wip)!;
			type_store::QualType parsed_qt = wip.apply_type_attrs(p, parsed.qt)!;
			AttributeUseSnapshot attribute_use_state;
			attribute_use_state.init(p, &wip);
			defer attribute_use_state.free();
			if (!parsed.has_name)
			{
				p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!;
				return PARSING_FAILED~;
			}
			tokens::TokenIndex name_tok = parsed.name_tok;
			string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
			type_store::QualType qt = parsed_qt;
			if (qt.is(p.comp, type_store::TypeTag.ARRAY) || qt.is(p.comp, type_store::TypeTag.FUNC))
			{
				qt = qt.decay(p.comp);
			}

			usz match = param_entries.len;
			for (usz i = 0; i < param_entries.len; i++)
			{
				if (param_entries[i].param.name == name) { match = i; break; }
			}
			if (match == param_entries.len)
			{
				p.err(parser_diagnostics::ParserDiag.PARAMETER_MISSING, name_tok,
					p.tree.tok_slice(name_tok))!;
				type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.PARAM, .param = {
					.name_tok = name_tok,
					.qt = qt,
					.storage_class = spec.storage_class == StorageClass.REGISTER ?
						tree::ParamStorageClass.REGISTER : tree::ParamStorageClass.AUTO,
				} });
				wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
				p.symbols.define_param(&sym_ctx, name, qt, name_tok, node)!;
				bool already_recorded = false;
				foreach (extra : *extra_params)
				{
					if (extra.name == name) { already_recorded = true; break; }
				}
				if (!already_recorded)
				{
					extra_params.push({ .qt = qt, .name = name,
						.name_tok = (type_store::TokenIndex)name_tok, .node = node.pack() });
				}
			}
			else if (was_declared[match])
			{
				type_store::FuncParam previous = param_entries[match].param;
				if (!previous.node.is_null())
				{
					p.symbols.define_param(&sym_ctx, name, qt, name_tok, previous.node.unwrap())!;
				}
			}
			else
			{
				was_declared[match] = true;
				type_store::FuncParam* param = &param_entries[match].param;
				param.qt = qt;
				if (!param.node.is_null())
				{
					tree::Node node = param.node.unwrap().get(&p.tree);
					node.param.qt = qt;
					if (spec.storage_class == StorageClass.REGISTER)
					{
						node.param.storage_class = tree::ParamStorageClass.REGISTER;
					}
					p.tree.set_node(node, (sz)param.node.unwrap());
						wip.apply_decl_attrs(p, param.node.unwrap(), param.node)!;
					symbol_stack::Symbol* symbol = p.symbols.get_ptr(name, symbol_stack::ScopeKind.VARS);
					symbol.qt = qt;
				}
			}
			wip.restore(declarator_state);
			attribute_use_state.restore(&wip);

			if (!p.is_at(tokenizer::TokenId.COMMA)) break;
			p.advance();
		}
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		wip.restore(declaration_state);
	}

	for (usz i = 0; i < param_entries.len; i++)
	{
		if (was_declared[i]) continue;
		type_store::FuncParam param = param_entries[i].param;
		if (param.name == string_interner::EMPTY) continue;
		p.err(parser_diagnostics::ParserDiag.PARAM_NOT_DECLARED, (tokens::TokenIndex)param.name_tok,
			p.tree.tok_slice((tokens::TokenIndex)param.name_tok))!;
	}

	list::List{type_store::FuncParam} final_params;
	final_params.init(p.comp.gpa);
	defer final_params.free();
	foreach (entry : param_entries) final_params.push(entry.param);
	return p.comp.type_store.put(type_store::type_func(function.return_type,
		type_store::FuncKind.NORMAL, final_params.array_view(), function.cc));
}

fn bool is_unbound_vla_parameter(parser::Parser* p, type_store::QualType qt)
{
	if (try pointer = qt.get(p.comp, type_store::TypeTag.POINTER))
	{
		if (!pointer.pointer.has_decayed || !pointer.pointer.decayed.is(p.comp, type_store::TypeTag.ARRAY)) return false;
		type_store::Type array = pointer.pointer.decayed.get(p.comp, type_store::TypeTag.ARRAY)!!;
		return array.array.len.kind == type_store::ArrayLenKind.UNSPECIFIED_VARIABLE;
	}
	return false;
}

<* Report a missing body immediately after the last declarator or parameter
   declaration token, matching the insertion point for the expected `{`. *>
fn void? emit_expected_fn_body_after(parser::Parser* p, tokens::TokenIndex tok)
{
	source::Location loc = p.tree.tokens[(usz)tok].loc;
	loc.byte_offset++;
	return parser_diagnostics::ParserDiag.EXPECTED_FN_BODY.emit(p.comp, &p.comp.langopts,
		p.extension_suppressed, parser_diagnostics::ParserDiag.EXPECTED_FN_BODY.fmt,
		loc.expand(p.comp), p.pp.expansion_slice(tok));
}

<* Definition-only checks apply after parameter declarators have been adjusted
   to their function parameter types. `(void)` is the no-parameter spelling. *>
fn void? DeclarationParser.validate_definition_parameters(&self, parser::Parser* p,
	type_store::Func function)
{
	bool void_sentinel = function.params.len == 1 &&
		function.params[0].name == string_interner::EMPTY && function.params[0].qt.eql(type_store::VOID, p.comp);
	if (void_sentinel) return;
	foreach (param : function.params)
	{
		if (param.name == string_interner::EMPTY)
		{
			p.err(parser_diagnostics::ParserDiag.OMITTING_PARAMETER_NAME,
				(tokens::TokenIndex)param.name_tok)!;
		}
		if (is_unbound_vla_parameter(p, param.qt))
		{
			p.err(parser_diagnostics::ParserDiag.UNBOUND_VLA,
				(tokens::TokenIndex)param.name_tok)!;
		}
		if (param.qt.has_incomplete_size(p.comp))
		{
			p.err(parser_diagnostics::ParserDiag.PARAMETER_INCOMPLETE_TY,
				(tokens::TokenIndex)param.name_tok, p.fmt_qt(param.qt))!;
		}
	}
}

<* Zig `StaticAsssertMessage` range: byte offsets of the condition text inside the
   message buffer, so the evaluation note can be compared with the requirement. *>
struct StaticAssertRequirement
{
	usz req_start;
	usz req_end;
}

<* Zig `staticAssertMessage`: appends " due to requirement '<cond>'" to `w`, plus
   ": <message>" (bare) when the message literal is non-empty. Returns where the
   condition text sits in `w`. `w` is a pointer: a DString passed by value loses
   its buffer when an append grows it, so the caller would read a stale string. *>
fn StaticAssertRequirement static_assert_message(parser::Parser* p, type_store::NodeIndex cond,
	bool has_message, parser_result::Result message, DString* w)
{
	w.append_string(" due to requirement '");
	usz start = w.str_view().len;
	p.tree.write(cond, w);
	usz end = w.str_view().len;
	w.append_char('\'');
	if (has_message)
	{
		char[] bytes = p.comp.interner.get(message.val.ref()).bytes;
		ulong size = message.qt.child_type(p.comp).sizeof(p.comp);
		if (bytes.len > (usz)size)
		{
			w.append_string(": ");
			text_literal_semantics::print_string(bytes, message.qt, p.comp, w,
				text_literal_semantics::PrintStringStyle.BARE);
		}
	}
	return { .req_start = start, .req_end = end };
}

<* Zig `staticAssertEvaluationNote`: when the condition, looked through casts and
   parentheses, is a comparison whose operands both have values, report `lhs op rhs`
   as a note on the operator. Silent when that text reads the same as the requirement. *>
fn void? static_assert_evaluation_note(parser::Parser* p, type_store::NodeIndex node, String requirement)
{
	type_store::NodeIndex current = node;
	tree::Node n = current.get(&p.tree);
	while (n.kind == tree::NodeKind.CAST || n.kind == tree::NodeKind.PAREN_EXPR)
	{
		if (n.kind == tree::NodeKind.CAST) { current = n.cast.operand; }
		else { current = n.unary.operand; }
		n = current.get(&p.tree);
	}
	if (n.kind != tree::NodeKind.EQUAL_EXPR && n.kind != tree::NodeKind.NOT_EQUAL_EXPR &&
		n.kind != tree::NodeKind.LESS_THAN_EXPR && n.kind != tree::NodeKind.LESS_THAN_EQUAL_EXPR &&
		n.kind != tree::NodeKind.GREATER_THAN_EXPR && n.kind != tree::NodeKind.GREATER_THAN_EQUAL_EXPR)
	{
		return;
	}
	value::Value lhs_val = p.tree.value_of(n.binary.lhs) ?? value::NONE;
	value::Value rhs_val = p.tree.value_of(n.binary.rhs) ?? value::NONE;
	if (lhs_val.is_none() || rhs_val.is_none()) return;
	DString note;
	note.init(tmem);
	value::NestedPrint lhs_nested;
	if (lhs_val.print(n.binary.lhs.qt(&p.tree), p.comp, &note, &lhs_nested)) return;
	note.appendf(" %s ", p.tree.tok_slice(n.binary.op_tok));
	value::NestedPrint rhs_nested;
	if (rhs_val.print(n.binary.rhs.qt(&p.tree), p.comp, &note, &rhs_nested)) return;
	String eval_text = note.str_view();
	if (eval_text == requirement) return;
	// emit_parser_diag takes the final text, so wrap the template's {s} here.
	DString message;
	message.init(tmem);
	message.append_string("expression evaluates to '");
	message.append_string(eval_text);
	message.append_char('\'');
	p.emit_parser_diag(parser_diagnostics::ParserDiag.STATIC_ASSERT_EXPRESSION_EVALUATES_TO, message.str_view(), n.binary.op_tok)!;
}

<* Final text for a `'{s}' <tail>` diagnostic template: `spelling` in single quotes, then `tail`. *>
fn String keyword_diag_text(String spelling, String tail)
{
	DString buf;
	buf.init(tmem);
	buf.appendf("'%s' %s", spelling, tail);
	return buf.str_view();
}

<* Parse `_Static_assert` or C23 `static_assert`, at file, block or record-member scope:
     keyword '(' integer-constant-expression (',' string-literal)? ')' ';'
   Returns the STATIC_ASSERT node. Returns the NULL_NODE fault, consuming nothing, when
   the cursor is not on either keyword, so the caller parses its own item. Mirrors
   Parser.zig staticAssert. *>
fn type_store::NodeIndex? DeclarationParser.parse_static_assert(&self, parser::Parser* p)
{
	if (p.at_eof()) return tree::NULL_NODE~;
	bool is_c11 = p.is_at(tokenizer::TokenId.KEYWORD_STATIC_ASSERT);
	bool is_c23 = p.is_at(tokenizer::TokenId.KEYWORD_C23_STATIC_ASSERT);
	if (!is_c11 && !is_c23) return tree::NULL_NODE~;
	tokens::TokenIndex static_assert_tok = p.tok_i;
	String spelling = p.tree.tok_slice(static_assert_tok);
	// Zig diagnoseC23Keyword / diagnoseC11Keyword.
	if (is_c23)
	{
		if (p.comp.langopts.standard.at_least(C23))
		{
			p.emit_parser_diag(parser_diagnostics::ParserDiag.PRE_C23_COMPAT,
				keyword_diag_text(spelling, "is incompatible with C standards before C23"), static_assert_tok)!;
		}
	}
	else if (p.comp.langopts.standard.at_least(C11))
	{
		p.emit_parser_diag(parser_diagnostics::ParserDiag.PRE_C11_COMPAT,
			keyword_diag_text(spelling, "is incompatible with C standards before C11"), static_assert_tok)!;
	}
	else
	{
		p.emit_parser_diag(parser_diagnostics::ParserDiag.C11_EXTENSION,
			keyword_diag_text(spelling, "is a C11 extension"), static_assert_tok)!;
	}
	p.advance();
	tokens::TokenIndex l_paren = p.tok_i;
	p.expect(tokenizer::TokenId.L_PAREN)!;
	// Zig: the condition is folded with record_static_assert_eval_note set, restored on exit.
	tokens::TokenIndex res_token = p.tok_i;
	bool old_eval_note = p.record_static_assert_eval_note;
	p.record_static_assert_eval_note = true;
	defer p.record_static_assert_eval_note = old_eval_note;

	parser_result::Result? maybe_cond = p.const_expr(true, parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION);
	if (catch cond_fault = maybe_cond) return cond_fault~;
	parser_result::Result res = maybe_cond;

	bool has_message = false;
	parser_result::Result message = {};
	if (p.is_at(tokenizer::TokenId.COMMA))
	{
		p.advance();
		if (p.at_eof() || !parser_primary::is_string_token(p.tree.tokens[(usz)p.tok_i].id))
		{
			p.err(parser_diagnostics::ParserDiag.EXPECTED_STR_LITERAL, p.tok_i)!;
			return PARSING_FAILED~;
		}
		parser_primary::PrimaryParser primary = { .parser = p };
		parser_result::Result? maybe_message = primary.parse_string(p.tok_i);
		if (catch message_fault = maybe_message) return message_fault~;
		message = maybe_message;
		has_message = true;
	}
	p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)!;
	p.expect(tokenizer::TokenId.SEMICOLON)!;
	if (!has_message)
	{
		if (p.comp.langopts.standard.at_least(C23))
		{
			p.err(parser_diagnostics::ParserDiag.STATIC_ASSERT_MISSING_MESSAGE_COMPAT, static_assert_tok)!;
		}
		else
		{
			p.err(parser_diagnostics::ParserDiag.STATIC_ASSERT_MISSING_MESSAGE, static_assert_tok)!;
		}
	}

	// Zig: a non-integer condition has no constant value; then cast to bool.
	bool is_int_expr = res.qt.is_invalid() || res.qt.is_int(p.comp);
	if (!res.qt.is_invalid()) res.cast_to_bool(p, res_token)!;
	if (!is_int_expr) res.val = value::NONE;
	if (res.val.is_none())
	{
		if (!res.qt.is_invalid()) p.err(parser_diagnostics::ParserDiag.STATIC_ASSERT_NOT_CONSTANT, res_token)!;
	}
	else if (!res.val.to_bool(p.comp))
	{
		// full is the whole text "static assertion failed due to requirement ..." so the requirement offsets index into it. The template supplies the prefix, so the diagnostic gets only the suffix.
		const String STATIC_ASSERT_PREFIX = "static assertion failed";
		DString full;
		full.init(tmem);
		full.append_string(STATIC_ASSERT_PREFIX);
		StaticAssertRequirement requirement = static_assert_message(p, res.node, has_message, message, &full);
		String full_text = full.str_view();
		p.err(parser_diagnostics::ParserDiag.STATIC_ASSERT_FAILURE_MESSAGE, res_token, full_text[STATIC_ASSERT_PREFIX.len:full_text.len - STATIC_ASSERT_PREFIX.len])!;
		// C3 `x[start:len]` takes a length, not an end index.
		String requirement_text = full_text[requirement.req_start:requirement.req_end - requirement.req_start];
		static_assert_evaluation_note(p, res.node, requirement_text)!;
	}

	type_store::NodeOptIndex message_node = type_store::NODE_NULL;
	if (has_message) message_node = (type_store::NodeOptIndex)message.node;
	return p.tree.add_node({ .kind = tree::NodeKind.STATIC_ASSERT,
		.static_assert = { .assert_tok = static_assert_tok, .cond = res.node, .message = message_node } });
}

<* Parse a complete declaration and append its declaration nodes to a local
   DECL_STMT or to Tree.root_decls. *>
fn type_store::NodeIndex? DeclarationParser.parse_declaration_impl(&self, parser::Parser* p, bool local = false)
{
	self.active_parser = p;
	attribute_wip::Wip wip;
	wip.init(p.comp.gpa);
	defer wip.free();
	attribute_wip::State declaration_wip_state = wip.state(true);
	defer wip.restore(declaration_wip_state);
	usz maybe_unused_checkpoint = (usz)p.maybe_unused_order.len();
	bool retain_parameter_warnings = false;
	defer
	{
		if (!retain_parameter_warnings)
		{
			for (usz i = maybe_unused_checkpoint; i < (usz)p.maybe_unused_order.len(); i++)
			{
				type_store::NodeIndex decl_node = p.maybe_unused_order.array_view()[i];
				if (decl_node.get(&p.tree).kind == tree::NodeKind.PARAM) p.mark_used(decl_node);
			}
		}
	}
	// Zig decl replays pragmas first; current callers already replay, so this only guards
	// other entry points. Recursion terminates because replay_pragma consumes all consecutive
	// pragma lines.
	if (p.is_at(tokenizer::TokenId.KEYWORD_PRAGMA))
	{
		bool? consumed = p.replay_pragma();
		fault pragma_fault = @catch(consumed);
		if (pragma_fault) return pragma_fault~;
		return self.parse_declaration_impl(p, local);
	}
	// Zig rootItem and compoundStmtItem try staticAssert before declarations.
	type_store::NodeIndex? maybe_static_assert = self.parse_static_assert(p);
	fault static_assert_fault = @catch(maybe_static_assert);
	if (static_assert_fault)
	{
		if (static_assert_fault != tree::NULL_NODE) return static_assert_fault~;
	}
	else
	{
		// Block items return the node into the statement list; file scope keeps it in root declarations.
		type_store::NodeIndex static_assert_node = maybe_static_assert!!;
		if (local) return static_assert_node;
		p.tree.root_decls.push(static_assert_node);
		return (type_store::NodeIndex)0;
	}
	tokens::TokenIndex first_tok = p.tok_i;
	usz first_spec_node = (usz)p.tree.nodes.len();
	DeclSpec? maybe_spec = self.parse_decl_spec(p, &wip);
	fault spec_fault = @catch(maybe_spec);
	if (spec_fault)
	{
		if (spec_fault != NO_DECL_SPEC) return spec_fault~;
		if (local) return tree::NULL_NODE~; // not a declaration: the statement parser tries an expression
		p.emit_parser_diag(parser_diagnostics::ParserDiag.EXPECTED_EXTERNAL_DECL,
			"expected external declaration", p.diag_index())!;
		// At file scope an unexpected compound statement is one malformed item.
		// Skip its balanced body so each token inside it does not produce another
		// expected-external-declaration diagnostic.
		if (p.is_at(tokenizer::TokenId.L_BRACE)) p.recover();
		return PARSING_FAILED~;
	}
	DeclSpec spec = maybe_spec!!;
	list::List{type_store::NodeIndex} declarations;
	declarations.init(p.comp.gpa);
	defer declarations.free();
	bool has_tag_declaration = false;
	// Parser.zig appends tag declarations to decl_buf while parsing the type
	// specifier. The callback parser reserves and completes those nodes in the
	// Tree, so collect them here before appending this declaration's declarators.
	for (usz i = first_spec_node; i < (usz)p.tree.nodes.len(); i++)
	{
		type_store::NodeIndex spec_node_index = (type_store::NodeIndex)i;
		tree::Node spec_node = spec_node_index.get(&p.tree);
		if (spec_node.kind == tree::NodeKind.STRUCT_DECL || spec_node.kind == tree::NodeKind.UNION_DECL ||
			spec_node.kind == tree::NodeKind.ENUM_DECL || spec_node.kind == tree::NodeKind.STRUCT_FORWARD_DECL ||
			spec_node.kind == tree::NodeKind.UNION_FORWARD_DECL || spec_node.kind == tree::NodeKind.ENUM_FORWARD_DECL)
		{
			has_tag_declaration = true;
			if (local)
			{
				declarations.push(spec_node_index);
			}
			else
			{
				p.tree.root_decls.push(spec_node_index);
			}
		}
	}
	if (p.is_at(tokenizer::TokenId.SEMICOLON))
	{
		tokens::TokenIndex semi = p.tok_i;
		p.advance();
		if (!has_tag_declaration) declarations.push(self.add_empty_declaration(p, semi));
	}
	else
	{
		bool warned_auto_single_declarator = false;
		while (true)
		{
			parser_declarator::ParsedDeclarator? maybe_parsed = self.parse_named_declarator(p, spec.qt);
			if (catch f = maybe_parsed) return f~;
			parser_declarator::ParsedDeclarator parsed = maybe_parsed;
			attribute_wip::State declarator_wip_state = wip.state(false);
			self.append_attributes(p, &wip)!;
			tokens::TokenIndex name_tok = parsed.name_tok;
			string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
			type_store::QualType qt = wip.apply_type_attrs(p, parsed.qt)!;
			AttributeUseSnapshot attribute_use_state;
			attribute_use_state.init(p, &wip);
			defer attribute_use_state.free();
			bool has_auto_type = spec.qt.is_auto();
			if (!local && spec.storage_class == StorageClass.AUTO)
			{
				p.err(parser_diagnostics::ParserDiag.AUTO_ON_GLOBAL, spec.auto_tok)!;
			}
			bool has_initializer = p.is_at(tokenizer::TokenId.EQUAL);
			bool function_type = qt.is(p.comp, type_store::TypeTag.FUNC);
			type_store::Func fn_type = {};
			if (function_type) fn_type = qt.get(p.comp, type_store::TypeTag.FUNC)!.func;
			bool old_style_function = function_type && fn_type.kind == type_store::FuncKind.OLD_STYLE;
			bool deduced_type = has_auto_type;
			if (has_auto_type)
			{
				if (qt.is(p.comp, type_store::TypeTag.FUNC) || qt.is(p.comp, type_store::TypeTag.BLOCK))
				{
					String context = qt.is(p.comp, type_store::TypeTag.BLOCK) ? "block return type" : "function return type";
					emit_deduced_type_not_allowed(p, spec.qt.is_auto_type(), context,
						spec.qt.is_auto_type() ? spec.auto_type_tok : spec.c23_auto_tok)!;
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (qt.is(p.comp, type_store::TypeTag.ARRAY))
				{
					emit_deduced_type_array(p, spec.qt.is_auto_type(), p.tree.tok_slice(name_tok), name_tok)!;
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (qt.is(p.comp, type_store::TypeTag.POINTER))
				{
					p.err(parser_diagnostics::ParserDiag.AUTO_TYPE_REQUIRES_PLAIN_DECLARATOR, name_tok)!;
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (spec.storage_class == StorageClass.TYPEDEF)
				{
					emit_deduced_type_not_allowed(p, spec.qt.is_auto_type(), "typedef",
						spec.qt.is_auto_type() ? spec.auto_type_tok : spec.c23_auto_tok)!;
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (!has_initializer)
				{
					emit_deduced_type_requires_initializer(p, spec.qt.is_auto_type(),
						p.tree.tok_slice(name_tok), name_tok)!;
					qt = type_store::INVALID;
					deduced_type = false;
				}
			}

			bool function_body_follows = p.is_at(tokenizer::TokenId.L_BRACE);
			bool old_style_declaration_list_follows = old_style_function && parsed.has_old_style_ident &&
				self.starts_decl_specifier(p);
			bool old_style_definition_context = old_style_function && parsed.has_old_style_ident && !has_initializer &&
				!p.is_at(tokenizer::TokenId.SEMICOLON) && !p.is_at(tokenizer::TokenId.COMMA);
			bool c23_old_style_declaration_list_follows = p.comp.langopts.standard.at_least(C23) &&
				function_type && parsed.has_old_style_ident && !has_initializer && !function_body_follows &&
				!p.is_at(tokenizer::TokenId.SEMICOLON) && !p.is_at(tokenizer::TokenId.COMMA) &&
				self.starts_decl_specifier(p);
			if (c23_old_style_declaration_list_follows)
			{
				// C23's parameter grammar has already diagnosed each old-style
				// identifier as an unknown type name. The following declarations
				// are still parsed at file scope; the function itself is missing
				// its body at the closing parenthesis. Match Zig's non-K&R
				// function-definition recovery: locate the diagnostic on `)`.
				if (p.tok_i > 0) { p.err(parser_diagnostics::ParserDiag.EXPECTED_FN_BODY, p.tok_i - 1)!; }
				else { p.err(parser_diagnostics::ParserDiag.EXPECTED_FN_BODY, p.diag_index())!; }
				return PARSING_FAILED~;
			}
			if (function_type && (function_body_follows || old_style_declaration_list_follows || old_style_definition_context))
			{
				list::List{type_store::FuncParam} extra_kr_params;
				extra_kr_params.init(p.comp.gpa);
				defer extra_kr_params.free();
				if (local || has_initializer || spec.storage_class == StorageClass.TYPEDEF)
				{
					p.emit_parser_diag(parser_diagnostics::ParserDiag.ILLEGAL_STORAGE_ON_FUNC,
						"illegal storage class on function", name_tok)!;
					return PARSING_FAILED~;
				}
				if (spec.storage_class == StorageClass.AUTO || spec.storage_class == StorageClass.REGISTER)
				{
					p.emit_parser_diag(parser_diagnostics::ParserDiag.ILLEGAL_STORAGE_ON_FUNC,
						"illegal storage class on function", name_tok)!;
				}
				if (old_style_function && parsed.has_old_style_ident)
				{
					p.err(parser_diagnostics::ParserDiag.DEF_NO_PROTO_DEPRECATED, name_tok)!;
					qt = self.parse_kr_definition_parameters(p, fn_type, &extra_kr_params)!!;
					fn_type = qt.get(p.comp, type_store::TypeTag.FUNC)!.func;
					if (!p.is_at(tokenizer::TokenId.L_BRACE))
					{
						if (p.tok_i > 0)
						{
							emit_expected_fn_body_after(p, p.tok_i - 1)!;
						}
						else
						{
							p.err(parser_diagnostics::ParserDiag.EXPECTED_FN_BODY, p.diag_index())!;
						}
						return PARSING_FAILED~;
					}
				}
				self.validate_definition_parameters(p, fn_type)!;
				type_store::NodeIndex function_node = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION, .function = {
					.name_tok = name_tok,
					.qt = qt,
					.is_static = spec.storage_class == StorageClass.STATIC,
					.is_inline = spec.is_inline,
					.body = type_store::NODE_NULL,
					.definition = type_store::NODE_NULL,
				} });
				type_store::NodeOptIndex previous = type_store::NODE_NULL;
				self.bind_declaration_symbol(p, name, qt, name_tok, function_node,
					false, true, false, &previous)!;
				wip.apply_decl_attrs(p, function_node, previous)!;
				if (name == p.comp.intern_string("main") && !qt.is_invalid())
				{
					type_store::Func main_func = qt.get(p.comp, type_store::TypeTag.FUNC)!.func;
					bool main_return_is_int = false;
					if (try main_return_int = main_func.return_type.get(p.comp, type_store::TypeTag.INT))
					{
						main_return_is_int = main_return_int.int_ty == type_store::TypeInt.INT;
					}
					if (!main_return_is_int)
					{
						p.emit_parser_diag(parser_diagnostics::ParserDiag.MAIN_RETURN_TYPE,
							"return type of 'main' is not 'int'", name_tok)!;
					}
				}
				self.active_parser = p;
				type_store::QualType old_function_return_qt = self.function_return_qt;
				tokens::TokenIndex old_function_name_tok = self.function_name_tok;
				parser::FunctionContext old_function_context = self.function_context;
				bool old_has_function_context = self.has_function_context;
				self.function_return_qt = qt.is_invalid() ? type_store::INVALID : fn_type.return_type;
				self.function_name_tok = name_tok;
				self.function_context = { .active = true, .declaration = function_node.pack(),
					.function_name_tok = name_tok, .function_qt = qt,
					.func_ident = type_store::NODE_NULL, .pretty_ident = type_store::NODE_NULL };
				self.function_context.variadic = fn_type.kind == type_store::FuncKind.VARIADIC;
				foreach (param : fn_type.params) if (param.name != string_interner::EMPTY) self.function_context.named_param_count++;
				self.has_function_context = true;
				p.push_scope();
				defer
				{
					p.pop_scope();
					self.function_return_qt = old_function_return_qt;
					self.function_name_tok = old_function_name_tok;
					self.function_context = old_function_context;
					self.has_function_context = old_has_function_context;
				}
				foreach (param : fn_type.params)
				{
					if (param.name == string_interner::EMPTY || param.node.is_null()) continue;
					p.define_symbol({ .kind = symbol_stack::SymbolKind.DEF, .name = param.name,
						.tok = (tokens::TokenIndex)param.name_tok, .qt = param.qt, .node = param.node.unwrap(),
						.val = value::NONE });
				}
				foreach (param : extra_kr_params)
				{
					p.define_symbol({ .kind = symbol_stack::SymbolKind.DEF, .name = param.name,
						.tok = (tokens::TokenIndex)param.name_tok, .qt = param.qt, .node = param.node.unwrap(),
						.val = value::NONE });
				}
				p.local_unused_err_count = p.diagnostics.errors;
				retain_parameter_warnings = true;
				fault body_fault = @catch(p.parse_body());
				if (body_fault)
				{
					p.diagnose_unused_locals()!;
					return body_fault~;
				}
				p.diagnose_unused_locals()!;
				if (self.body_binding.body.is_null()) return PARSING_FAILED~;
				tree::Node completed = function_node.get(&p.tree);
				completed.function.body = self.body_binding.body;
				p.tree.set_node(completed, (sz)function_node);
				declarations.push(function_node);
				if (!local) p.tree.root_decls.push(function_node);
				return function_node;
			}
			if (old_style_function && parsed.has_old_style_ident &&
				(p.is_at(tokenizer::TokenId.SEMICOLON) || p.is_at(tokenizer::TokenId.COMMA)))
			{
				p.err(parser_diagnostics::ParserDiag.INVALID_OLD_STYLE_PARAMS,
				parsed.old_style_ident_tok)!;
			}
			else if (old_style_function && !has_initializer &&
				!p.is_at(tokenizer::TokenId.SEMICOLON) && !p.is_at(tokenizer::TokenId.COMMA))
			{
				p.err(parser_diagnostics::ParserDiag.EXPECTED_FN_BODY,
					p.tok_i > 0 ? p.tok_i - 1 : p.diag_index())!;
				return PARSING_FAILED~;
			}

			if (spec.storage_class == StorageClass.TYPEDEF)
			{
				type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.TYPEDEF, .type_def = {
					.name_tok = name_tok, .qt = qt, .implicit = false,
				} });
				type_store::QualType typedef_qt = p.comp.type_store.put(type_store::type_typedef(qt, name, node)).with_qualifiers(qt);
				tree::Node typedef_node = node.get(&p.tree);
				typedef_node.type_def.qt = typedef_qt;
				p.tree.set_node(typedef_node, (sz)node);
				type_store::NodeOptIndex previous = type_store::NODE_NULL;
				self.bind_declaration_symbol(p, name, typedef_qt, name_tok, node, true, false, false, &previous)!;
				wip.apply_decl_attrs(p, node, previous)!;
				declarations.push(node);
				if (local) p.add_maybe_unused(node)!;
				if (!local) p.tree.root_decls.push(node);
			}
			else if (function_type)
			{
				if (has_initializer)
				{
					p.emit_parser_diag(parser_diagnostics::ParserDiag.ILLEGAL_INITIALIZER,
						"illegal initializer (only variables can be initialized)", p.tok_i)!;
					p.advance(); // Consume '=' before reporting the malformed initializer.
					parser_result::Result? ignored_initializer = self.parse_variable_initializer(p, qt, false, false);
					if (catch f = ignored_initializer) return f~;
				}
				type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION, .function = {
					.name_tok = name_tok, .qt = qt,
					.is_static = spec.storage_class == StorageClass.STATIC,
					.is_inline = spec.is_inline,
					.body = type_store::NODE_NULL, .definition = type_store::NODE_NULL,
				} });
				type_store::NodeOptIndex previous = type_store::NODE_NULL;
				self.bind_declaration_symbol(p, name, qt, name_tok, node, false, false, false, &previous)!;
				wip.apply_decl_attrs(p, node, previous)!;
				declarations.push(node);
				if (!local) p.tree.root_decls.push(node);
			}
			else
			{
				bool initializer_present = has_initializer;
				if (initializer_present) p.advance();
				type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = {
					.name_tok = name_tok, .qt = qt,
					.storage_class = variable_storage_class(
						spec.storage_class == StorageClass.EXTERN && initializer_present ? StorageClass.NONE : spec.storage_class),
					.thread_local = spec.thread_local, .implicit = false,
					.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL,
				} });
				type_store::NodeOptIndex previous = type_store::NODE_NULL;
				bool static_duration = !local || spec.storage_class == StorageClass.STATIC ||
					spec.storage_class == StorageClass.EXTERN || spec.thread_local;
				if (!has_auto_type)
				{
					self.bind_declaration_symbol(p, name, qt, name_tok, node, false,
						local ? spec.storage_class != StorageClass.EXTERN : initializer_present,
						spec.constexpr_decl, &previous)!;
				}
				if (initializer_present)
				{
					if (spec.storage_class == StorageClass.EXTERN)
					{
						p.emit_parser_diag(parser_diagnostics::ParserDiag.EXTERN_INITIALIZER,
							"extern variable has initializer", name_tok)!;
					}
					parser_result::Result? maybe_initializer;
					if (has_auto_type)
					{
						maybe_initializer = self.parse_auto_type_initializer(p, node, name, name_tok,
							spec.qt.is_auto_type(), deduced_type, spec.constexpr_decl, static_duration);
					}
					else
					{
						maybe_initializer = self.parse_variable_initializer(p, qt,
							spec.constexpr_decl, static_duration);
					}
					if (catch f = maybe_initializer) return f~;
					parser_result::Result initializer = maybe_initializer;
					type_store::QualType completed_qt = qt;
					if (has_auto_type && deduced_type)
					{
						completed_qt = initializer.qt.with_qualifiers(qt);
					}
					else if (!has_auto_type)
					{
						completed_qt = self.completed_array_initializer_type(p, qt, initializer);
					}
					qt = completed_qt;
					tree::Node initialized = node.get(&p.tree);
					initialized.variable.initializer = initializer.node.pack();
					initialized.variable.qt = completed_qt;
					p.tree.set_node(initialized, (sz)node);
					if (has_auto_type)
					{
						self.bind_declaration_symbol(p, name, completed_qt, name_tok, node, false,
							local ? spec.storage_class != StorageClass.EXTERN : initializer_present,
							spec.constexpr_decl, &previous)!;
					}
					symbol_stack::Symbol* symbol = p.symbols.get_ptr(name, symbol_stack::ScopeKind.VARS);
					if (symbol.node == node)
					{
						symbol.qt = completed_qt;
						if (!initializer.val.is_none() && (symbol.kind == symbol_stack::SymbolKind.DEF ||
							symbol.kind == symbol_stack::SymbolKind.CONSTEXPR)) symbol.val = initializer.val;
					}
				}
				else
				{
					if (has_auto_type)
					{
						self.bind_declaration_symbol(p, name, qt, name_tok, node, false,
							local ? spec.storage_class != StorageClass.EXTERN : initializer_present,
							spec.constexpr_decl, &previous)!;
					}
				}
				if (!initializer_present && !has_auto_type && !local && spec.storage_class != StorageClass.EXTERN)
				{
					symbol_stack::Symbol* symbol = p.symbols.get_ptr(name, symbol_stack::ScopeKind.VARS);
					if (symbol.node == node && symbol.kind == symbol_stack::SymbolKind.DECL)
					{
						self.set_tentative_definition(p, node, node);
					}
				}
				wip.apply_decl_attrs(p, node, previous)!;
				declarations.push(node);
				if (local) p.add_maybe_unused(node)!;
				if (!local) p.tree.root_decls.push(node);
			}

			wip.restore(declarator_wip_state);
			attribute_use_state.restore(&wip);
			if (!p.is_at(tokenizer::TokenId.COMMA)) break;
			if (has_auto_type && !warned_auto_single_declarator)
			{
				if (spec.qt.is_auto_type())
				{
					p.err(parser_diagnostics::ParserDiag.AUTO_TYPE_REQUIRES_SINGLE_DECLARATOR, spec.auto_type_tok)!;
				}
				else
				{
					p.err(parser_diagnostics::ParserDiag.C23_AUTO_SINGLE_DECLARATOR, spec.c23_auto_tok)!;
				}
				warned_auto_single_declarator = true;
			}
			p.advance();
		}
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	}
	// Top-level callers discard the node; only local declarations build DECL_STMT.
	if (!local) return (type_store::NodeIndex)0;
	return p.tree.add_node({ .kind = tree::NodeKind.DECL_STMT,
		.decl_stmt = { .decls = declarations.array_view(), .first_tok = first_tok } });
}

<* The external declaration callback is void because Parser.parse owns root
   iteration and recovery. *>
fn void? DeclarationParser.parse_declaration(&self, parser::Parser* p)
{
	type_store::NodeIndex? parsed = self.parse_declaration_impl(p, false);
	if (catch f = parsed) return f~;
	return;
}

fn type_store::NodeIndex? DeclarationParser.parse_local_declaration_statement(&self, parser::Parser* p)
{
	return self.parse_declaration_impl(p, true);
}
