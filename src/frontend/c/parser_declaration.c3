// Declaration grammar binding boundary. This module owns C declaration
// specifiers and binds them to the reusable declarator, initializer and
// statement productions.
module aro::frontend::c::parser_declaration;
import aro::frontend::c::parser, aro::frontend::c::parser_statement, aro::frontend::c::parser_result;
import aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::symbol_stack;
import aro::string_interner, aro::frontend::c::value, aro::frontend::c::diagnostics, aro::bigint;
import aro::frontend::c::lang_opts, aro::frontend::c::compilation, aro::value_interner;
import aro::frontend::c::attribute;
import aro::frontend::c::attribute_wip, aro::frontend::c::parser_attribute;
import aro::frontend::c::text_literal_semantics;
import aro::source;
import aro::frontend::c::pragmas::pack;
import std::collections::list;
import std::core::dstring;

excuse PARSING_FAILED;
excuse NO_DECL_SPEC;

<* Test-only overrides of the declaration grammar; compiled out of non-test builds.
   Every method is optional: a null probe or a missing method selects the built-in
   production, or parser::HOOK_ABSENT for type_name / implicit_typedefs, which have none.
   An installed probe replaces the implicit typedef prelude. *>
interface IDeclarationTestProbe @feat(TESTING)
{
	<* Replaces the top-level declaration production. *>
	fn void? declaration(parser::Parser* p) @optional;
	<* Untyped type-name production. *>
	fn void? type_name(parser::Parser* p) @optional;
	<* Replaces the typed type-name production. *>
	fn type_store::QualType? typed_type_name(parser::Parser* p) @optional;
	<* Seeds implicit typedefs before the first declaration. *>
	fn void? implicit_typedefs(parser::Parser* p) @optional;
	<* Builds a complete local declaration statement, or returns null when the
	   current token sequence is not a declaration. *>
	fn type_store::NodeIndex? local_declaration_statement(parser::Parser* p) @optional;
}

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
	type_store::NodeIndex tag_decl_node;
	bool has_tag_decl_node;
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
struct DeclarationParser (parser::IExpressionGrammar)
{
	IDeclarationTestProbe test_probe @feat(TESTING);
	parser_statement::StatementParser statements;
	type_store::QualType function_return_qt;
	tokens::TokenIndex function_name_tok;
	parser::FunctionContext function_context;
	bool has_function_context;
}

<* Parse a declaration initializer with the value rule selected from its
   constexpr and storage-duration specifiers. constexpr takes precedence.
   When a declaration node is supplied, its name is visible to the initializer
   through a temporary scope, as in parse_auto_type_initializer; the caller
   binds the declaration only after the initializer succeeds. *>
fn parser_result::Result? DeclarationParser.parse_variable_initializer(&self, parser::Parser* p,
	type_store::QualType target, bool constexpr_decl, bool static_duration, bool eval = true,
	type_store::NodeOptIndex declaration = type_store::NODE_NULL, string_interner::StringId name = string_interner::EMPTY,
	tokens::TokenIndex name_tok = 0)
{
	parser::InitContext context = constexpr_decl ? parser::InitContext.CONSTEXPR :
		static_duration ? parser::InitContext.STATIC : parser::InitContext.RUNTIME;
	if (declaration.is_null()) return p.parse_initializer_with_context(target, context, eval);
	p.push_scope();
	defer p.pop_scope();
	p.define_symbol({ .kind = symbol_stack::SymbolKind.DEF, .name = name, .qt = target,
		.tok = name_tok, .node = declaration.unwrap(), .val = value::NONE });
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
	// While deducing, the binding keeps the auto placeholder type: parse_identifier
	// reports any reference to it as self-initialization.
	type_store::QualType binding_qt = !deduce ? type_store::INVALID : auto_type ? type_store::AUTO_TYPE : type_store::C23_AUTO;
	p.define_symbol({ .kind = symbol_stack::SymbolKind.DEF, .name = name, .qt = binding_qt,
		.tok = name_tok, .node = declaration, .val = value::NONE });

	parser::InitContext context = constexpr_decl ? parser::InitContext.CONSTEXPR :
		static_duration ? parser::InitContext.STATIC : parser::InitContext.RUNTIME;
	if (!deduce) return p.parse_initializer_with_context(type_store::INVALID, context, eval);

	tokens::TokenIndex initializer_tok = p.tok_i;
	bool init_list = p.is_at(tokenizer::TokenId.L_BRACE);
	if (init_list)
	{
		if (auto_type)
		{
			Diagnostic.AUTO_TYPE_WITH_INIT_LIST.@emit(p, initializer_tok)!;
		}
		else
		{
			Diagnostic.C23_AUTO_WITH_INIT_LIST.@emit(p, initializer_tok)!;
		}
	}

	parser_result::Result initializer = p.parse_initializer_with_context(type_store::INVALID, context, eval)!;
	if (init_list) return initializer;
	if (p.tree.is_bitfield(initializer.node))
	{
		Diagnostic.AUTO_TYPE_FROM_BITFIELD.@emit(p, initializer_tok)!;
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

<* Compound statement inside a GNU statement expression. *>
fn type_store::NodeIndex? DeclarationParser.handle_statement_expression_body(&self, parser::Parser* p, bool eval) @dynamic
{
	if (!self.statements.expressions) self.statements.expressions = self;
	return self.statements.parse_body(p, false);
}

fn type_store::NodeIndex? DeclarationParser.handle_body(&self, parser::Parser* p) @dynamic
{
	uint old_loop_depth = self.statements.loop_depth;
	uint old_switch_depth = self.statements.switch_depth;
	type_store::QualType old_return_qt = self.statements.function_return_qt;
	tokens::TokenIndex old_function_name_tok = self.statements.function_name_tok;
	bool old_has_function_context = self.statements.has_function_context;
	DeclarationParser* old_local_declarations = self.statements.local_declarations;
	parser::IExpressionGrammar old_expressions = self.statements.expressions;
	parser::FunctionContext old_parser_function_context = p.function_context;
	self.statements.loop_depth = 0;
	self.statements.switch_depth = 0;
	self.statements.function_return_qt = self.function_return_qt;
	self.statements.function_name_tok = self.function_name_tok;
	self.statements.has_function_context = self.has_function_context;
	p.set_function_context(self.has_function_context ? self.function_context : (parser::FunctionContext){});
	self.statements.local_declarations = self;
	if (!self.statements.expressions) self.statements.expressions = self;
	defer
	{
		self.statements.loop_depth = old_loop_depth;
		self.statements.switch_depth = old_switch_depth;
		self.statements.function_return_qt = old_return_qt;
		self.statements.function_name_tok = old_function_name_tok;
		self.statements.has_function_context = old_has_function_context;
		self.statements.local_declarations = old_local_declarations;
		self.statements.expressions = old_expressions;
		p.set_function_context(old_parser_function_context);
	}
	type_store::NodeIndex? body = self.statements.parse_body(p, true);
	if (catch f = body)
	{
		if (f == parser_statement::PARSING_FAILED) return parser::PARSING_FAILED~;
		return f~;
	}
	return body;
}

<* Local declaration production for the statement grammar. *>
fn type_store::NodeIndex? DeclarationParser.parse_local_declaration(&self, parser::Parser* p)
{
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.local_declaration_statement) return self.test_probe.local_declaration_statement(p);
	$endif
	type_store::NodeIndex? parsed = self.parse_local_declaration_statement(p,
		self.statements.prefix_declaration_attributes);
	if (@ok(parsed) && parsed!!.get(&p.tree).kind == tree::NodeKind.DECL_STMT)
	{
		self.statements.prefix_declaration_attributes_consumed = true;
	}
	return parsed;
}

fn void? parser::Parser.handle_declaration(&self)
{
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.handle_declaration)
		{
			fault f = @catch(self.test_probe.handle_declaration(self));
			if (f != parser::HOOK_ABSENT)
			{
				if (f) return f~;
				return;
			}
		}
	$endif
	return self.declarations.handle_declaration(self);
}

fn void? DeclarationParser.handle_declaration(&self, parser::Parser* p)
{
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.declaration) return self.test_probe.declaration(p);
	$endif
	return self.parse_declaration(p);
}

fn void? DeclarationParser.handle_translation_unit_end(&self, parser::Parser* p) @dynamic
{
	self.finalize_tentative_arrays(p);
	return;
}

<* Share the full parser-fault classification with Parser.parse. *>
fn bool? DeclarationParser.is_recoverable_parse_fault(&self, parser::Parser* p, fault parse_fault) @dynamic
	=> parser_statement::recoverable_statement_item_fault(parse_fault);

<* Only provided when a test probe implements type_name, matching the
   legacy callback table; otherwise Parser reports the grammar as unavailable. *>
fn void? DeclarationParser.handle_type_name(&self, parser::Parser* p) @dynamic
{
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.type_name) return self.test_probe.type_name(p);
	$endif
	return parser::HOOK_ABSENT~;
}

fn type_store::QualType? DeclarationParser.handle_typed_type_name(&self, parser::Parser* p) @dynamic
{
	$if env::TESTING:
		if (self.test_probe && &self.test_probe.typed_type_name) return self.test_probe.typed_type_name(p);
	$endif
	return self.parse_typed_type_name(p);
}

fn parser::TypeNameProbe? DeclarationParser.handle_typed_type_name_probe(&self, parser::Parser* p) @dynamic
{
	return self.probe_typed_type_name(p);
}

<* `type_specifier_token`: the token is not a plain type-specifier keyword. *>
excuse NOT_TYPE_SPECIFIER;

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
	TagAttributeContext* tag_context = (TagAttributeContext*)context;
	return tag_context.declaration_parser.parse_enum_underlying(p, tag_context.record_member);
}

struct TagAttributeContext
{
	DeclarationParser* declaration_parser;
	attribute_wip::Wip* wip;
	type_store::NodeIndex* tag_decl_node_out;
	bool* has_tag_decl_node_out;
	// The specifier begins a struct/union member, so `enum E : width` may be a bit-field.
	bool record_member;
}

fn void? tag_attribute_callback(void* context, parser::Parser* p, parser::TagHeader header, parser::TagAttributeStage stage)
{
	TagAttributeContext* tag_context = (TagAttributeContext*)context;
	switch (stage)
	{
		case parser::TagAttributeStage.PARSE_HEADER:
			tag_context.declaration_parser.append_attributes(p, tag_context.wip)!;
			return;
		case parser::TagAttributeStage.APPLY_HEADER:
			type_store::QualType type_qt = tag_context.wip.apply_type_attrs(p, header.qt)!;
			assert(type_qt.eql(header.qt, p.comp), "type attributes on a tag must preserve its qualified type");
			tag_context.wip.apply_decl_attrs_extra(p, header.decl_node, header.qt, header.decl_node.pack())!;
			tag_context.wip.top = (uint)tag_context.wip.attrs.len();
			*tag_context.tag_decl_node_out = header.decl_node;
			*tag_context.has_tag_decl_node_out = true;
			return;
		case parser::TagAttributeStage.PARSE_BODY_END:
			tag_context.wip.top = (uint)tag_context.wip.attrs.len();
			tag_context.declaration_parser.append_attributes(p, tag_context.wip)!;
			return;
		case parser::TagAttributeStage.APPLY_BODY_END:
			type_store::QualType type_qt = tag_context.wip.apply_type_attrs(p, header.qt)!;
			assert(type_qt.eql(header.qt, p.comp), "type attributes on a tag must preserve its qualified type");
			tag_context.wip.apply_decl_attrs_extra(p, header.decl_node, header.qt, header.decl_node.pack())!;
			tag_context.wip.top = (uint)tag_context.wip.attrs.len();
			return;
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

fn type_store::QualType? DeclarationParser.parse_record_specifier(&self, parser::Parser* p, bool is_enum,
	attribute_wip::Wip* declaration_wip, type_store::NodeIndex* tag_decl_node_out,
	bool* has_tag_decl_node_out, bool record_member)
{
	*has_tag_decl_node_out = false;
	// Zig recordSpec/enumSpec: `state(true)` so attributes parsed before the
	// tag keyword (e.g. `__declspec(align(8)) typedef enum {...} A;`) belong
	// to the declaration, not the tag.
	attribute_wip::State tag_state = declaration_wip.state(true);
	defer declaration_wip.restore(tag_state);
	TagAttributeContext tag_context = { .declaration_parser = (DeclarationParser*)self, .wip = declaration_wip,
		.tag_decl_node_out = tag_decl_node_out, .has_tag_decl_node_out = has_tag_decl_node_out,
		.record_member = record_member };
	return p.record_spec_with_body(&record_body_callback, (void*)self, is_enum,
		&enum_underlying_callback, (void*)&tag_context, &tag_attribute_callback, (void*)&tag_context);
}

fn type_store::QualType? DeclarationParser.parse_enum_underlying(&self, parser::Parser* p, bool record_member)
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
			if (record_member) return parser::ENUM_UNDERLYING_NO_DECL_SPEC~;
			return type_store::INVALID;
		}
		return f~;
	}
	DeclSpec spec = maybe_spec!!;
	return wip.apply_pending_calling_conventions(p, spec.qt);
}


<* The comma-separated declarators of one struct/union member declaration.
 Out of line so its locals are not on the stack while nested record bodies
 (parsed by the member's specifiers) recurse. *>
fn void? DeclarationParser.parse_field_declarators(&self, parser::Parser* p, parser::ContainerBodySeed seed, DeclSpec spec,
	attribute_wip::Wip* field_wip, attribute_wip::State declarator_state, tokens::TokenIndex member_start,
	list::List{type_store::RecordField}* fields, list::List{type_store::NodeIndex}* field_nodes,
	bool* has_flexible_field, tokens::TokenIndex* flexible_field_tok) @noinline
{
	while (true)
	{
		// Only an unnamed bit-field (`int : 3;`) has an abstract member declarator.
		bool member_abstract = p.is_at(tokenizer::TokenId.COLON);
		// Snapshot before the declarator: attributes after `*` belong to this
		// declarator only and are dropped by `restore(declarator_state)` below.
		AttributeUseSnapshot attribute_use_state;
		attribute_use_state.init(p, field_wip);
		defer attribute_use_state.free();
		parser::ParsedDeclarator field_decl = p.parse_declarator(self, field_wip, spec.qt,
			member_abstract ? parser::DeclaratorKind.ABSTRACT : parser::DeclaratorKind.NORMAL)!;
		self.append_attributes(p, field_wip)!;
		type_store::QualType field_qt = field_wip.apply_type_attrs(p, field_decl.qt)!;
		field_qt = field_wip.apply_pending_calling_conventions(p, field_qt)!;
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
				Diagnostic.NON_INT_BITFIELD.@emit(p, field_decl.name_tok.has_value ? field_decl.name_tok.value : colon,
					p.fmt_qt(field_qt))!;
				return PARSING_FAILED~;
			}
			if (width_result.val.is_none())
			{
				Diagnostic.EXPECTED_INTEGER_CONSTANT_EXPR.@emit(p, width_tok)!;
			}
			else
			{
				if (value::compare(width_result.val, bigint::CompareOperator.LT, value::ZERO, p.comp))
				{
					Diagnostic.NEGATIVE_BITWIDTH.@emit(p, colon,
						p.fmt_value(width_result.val, width_result.qt))!;
					return PARSING_FAILED~;
				}
				if (field_qt.has_incomplete_size(p.comp))
				{
					Diagnostic.FIELD_INCOMPLETE_TY.@emit(p, field_decl.name_tok.has_value ? field_decl.name_tok.value : colon,
						p.fmt_qt(field_qt))!;
					return PARSING_FAILED~;
				}
				ulong width_value = width_result.val.to_u64(p.comp) ?? ulong::max;
				if (width_value > field_qt.bit_sizeof(p.comp))
				{
					Diagnostic.BITFIELD_TOO_BIG.@emit(p, colon)!;
					return PARSING_FAILED~;
				}
				bit_width = (uint)width_value;
				bit_width_node = width_result.node.pack();
				if (bit_width == 0 && field_decl.name_tok.has_value)
				{
					Diagnostic.ZERO_WIDTH_NAMED_FIELD.@emit(p, field_decl.name_tok.value)!;
					return PARSING_FAILED~;
				}
			}
		}
		else if (!field_decl.name_tok.has_value)
		{
			Diagnostic.EXPECTED_RECORD_DECL.@emit(p, p.tok_i)!;
			return PARSING_FAILED~;
		}
		// Attributes may also follow the bit-field width (`int i : 1 __attribute__((aligned(8)));`);
		// like Zig's second `attributeSpecifier`, they reach the field through `apply_decl_attrs` below.
		self.append_attributes(p, field_wip)!;

		// Zig recordDeclarator field-type checks: function fields, VLA fields and
		// flexible array members (an incomplete array is allowed as a field).
		if (!field_qt.is_invalid())
		{
			tokens::TokenIndex first_tok = field_decl.name_tok.has_value ? field_decl.name_tok.value : member_start;
			type_store::Type field_ty = field_qt.base(p.comp).ty;
			switch (field_ty.tag)
			{
				case FUNC:
					Diagnostic.FUNC_FIELD.@emit(p, first_tok)!;
					field_qt = type_store::INVALID;
				case ARRAY:
					switch (field_ty.array.len.kind)
					{
						case VARIABLE:
							Diagnostic.VLA_FIELD.@emit(p, first_tok)!;
							field_qt = type_store::INVALID;
						case INCOMPLETE:
							if (seed.is_union)
							{
								if (p.comp.langopts.emulate == lang_opts::Compiler.MSVC)
								{
									Diagnostic.FLEXIBLE_IN_UNION_MSVC.@emit(p, first_tok)!;
								}
								else
								{
									Diagnostic.FLEXIBLE_IN_UNION.@emit(p, first_tok)!;
									field_qt = type_store::INVALID;
								}
							}
							if (*has_flexible_field && !seed.is_union)
							{
								Diagnostic.FLEXIBLE_NON_FINAL.@emit(p, *flexible_field_tok)!;
							}
							*has_flexible_field = true;
							*flexible_field_tok = first_tok;
						default: break;
					}
				default:
					if (field_qt.has_incomplete_size(p.comp))
					{
						Diagnostic.FIELD_INCOMPLETE_TY.@emit(p, first_tok, p.fmt_qt(field_qt))!;
						return PARSING_FAILED~;
					}
					if (*has_flexible_field && !seed.is_union)
					{
						Diagnostic.FLEXIBLE_NON_FINAL.@emit(p, *flexible_field_tok)!;
					}
			}
		}
		string_interner::StringId field_name = field_decl.name_tok.has_value ?
			p.comp.intern_string(p.tree.tok_slice(field_decl.name_tok.value)) : string_interner::EMPTY;
		tokens::TokenIndex field_tok = field_decl.name_tok.has_value ? field_decl.name_tok.value : member_start;
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.RECORD_FIELD,
			.record_field = { .name_or_first_tok = field_tok, .qt = field_qt,
				.bit_width = bit_width_node } });
		field_wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
		fields.push({ .qt = field_qt, .name = field_name,
			.name_tok = field_decl.name_tok.has_value ? (type_store::TokenIndex)field_decl.name_tok.value : (type_store::TokenIndex)0,
			.bit_width = bit_width, .field_decl = node.pack() });
		field_nodes.push(node);
		field_wip.restore(declarator_state);
		attribute_use_state.restore(field_wip);

		if (!p.is_at(tokenizer::TokenId.COMMA)) break;
		p.advance();
	}
}

<* Layout and node of a struct/union whose member list has been parsed. *>
fn type_store::QualType? DeclarationParser.finish_record_body(&self, parser::Parser* p, parser::ContainerBodySeed seed,
	list::List{type_store::RecordField}* fields, list::List{type_store::NodeIndex}* field_nodes) @noinline
{
	if (catch p.expect(tokenizer::TokenId.R_BRACE)) return PARSING_FAILED~;
	attribute::Attribute? header_storage = p.tree.attr_map.get_attribute(seed.decl_node.pack(), attribute::AttributeTag.SCALAR_STORAGE_ORDER);
	self.apply_tag_body_end_attributes(p, seed)!;

	type_store::RecordField[] record_fields = fields.array_view();
	if (try storage = p.tree.attr_map.get_attribute(seed.decl_node.pack(), attribute::AttributeTag.SCALAR_STORAGE_ORDER) ?? header_storage)
	{
		bool reverse = (storage.args.scalar_storage_order == attribute::ScalarStorageOrder.BIG_ENDIAN) != p.comp.target.cpu.arch.big;
		foreach (&field : record_fields)
		{
			field.reverse_storage = reverse;
			if (reverse && field.bit_width == type_store::BIT_WIDTH_NULL)
			{
				diagnostics::Diagnostic.UNIMPLEMENTED.report(p, "TODO: implement 'scalar_storage_order' for non-bitfield members", storage.tok)!;
				break;
			}
		}
	}

	pack::PackValue current_pack = seed.pack_value;
	if (p.comp.langopts.emulate == lang_opts::Compiler.GCC || p.comp.langopts.emulate == lang_opts::Compiler.MSVC)
	{
		current_pack = {};
		if (try pack_handler = p.comp.pragmas.get("pack"))
		{
			pack::PackState* pack_state = (pack::PackState*)pack_handler.ptr;
			current_pack = pack_state.current_value();
		}
	}
	uint pragma_pack = current_pack.has_value ? (uint)current_pack.value : 0;
	type_store::RecordLayout? maybe_layout = type_store::compute(record_fields,
		seed.decl_node.pack(), seed.is_union, p.comp, &p.tree.attr_map, pragma_pack);
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

	// Zig `p.record.flexible_field`: the first flexible array member seen so far.
	bool has_flexible_field = false;
	tokens::TokenIndex flexible_field_tok;
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
		// Zig recordDeclItem: `__extension__ recordDecl` suppresses extension diagnostics
		// for this member (glibc: `__extension__ unsigned long long int __value64;`).
		bool saved_member_extension = p.extension_suppressed;
		defer p.extension_suppressed = saved_member_extension;
		if (p.is_at(tokenizer::TokenId.KEYWORD_EXTENSION))
		{
			p.advance();
			p.extension_suppressed = true;
		}
		tokens::TokenIndex member_start = p.tok_i;
		attribute_wip::State member_state = field_wip.state(true);
		DeclSpec? maybe_spec = self.parse_decl_spec(p, &field_wip, record_member: true);
		if (catch f = maybe_spec)
		{
			if (f != NO_DECL_SPEC) return f~;
			Diagnostic.EXPECTED_RECORD_DECL.@emit(p, member_start)!;
			return PARSING_FAILED~;
		}
		DeclSpec spec = maybe_spec;
		attribute_wip::State declarator_state = field_wip.state(false);
		if (spec.storage_class != StorageClass.NONE || spec.thread_local || spec.constexpr_decl || spec.is_inline)
		{
			Diagnostic.EXPECTED_RECORD_DECL.@emit(p, member_start)!;
		}
		if (spec.qt.is_auto())
		{
			String context = seed.is_union ? "union member" : "struct member";
			if (spec.qt.is_auto_type())
			{
				Diagnostic.AUTO_TYPE_NOT_ALLOWED.@emit(p, spec.auto_type_tok, context)!;
			}
			else
			{
				Diagnostic.C23_AUTO_NOT_ALLOWED.@emit(p, spec.c23_auto_tok, context)!;
			}
			// Keep the placeholder out of record layout and bit-field checks.
			spec.qt = type_store::INVALID;
		}
		if (p.is_at(tokenizer::TokenId.SEMICOLON))
		{
			field_wip.apply_pending_calling_conventions(p, spec.qt)!;
			// C23 anonymous aggregate members and the common compiler extension
			// spelling both have a type specifier followed directly by ';'.
			if (!spec.qt.is(p.comp, type_store::TypeTag.STRUCT) && !spec.qt.is(p.comp, type_store::TypeTag.UNION))
			{
				Diagnostic.EXPECTED_RECORD_DECL.@emit(p, member_start)!;
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

		self.parse_field_declarators(p, seed, spec, &field_wip, declarator_state, member_start, &fields, &field_nodes, &has_flexible_field, &flexible_field_tok)!;
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		field_wip.restore(member_state);
	}
	return self.finish_record_body(p, seed, &fields, &field_nodes);
}
fn value::Value increment_enum_value(value::Value current, compilation::Compilation* comp)
{
	bigint::BigIntConst current_big = current.to_big_int(comp);
	bigint::Limb[1] one_limbs;
	bigint::BigIntConst one = bigint::init_u64(one_limbs[..], 1).to_const();
	bigint::Limb[] result_limbs = alloc::new_array(tmem, bigint::Limb, (usz)(current_big.limbs.len + 1));
	bigint::BigIntMutable result = { .limbs = result_limbs, .len = 1, .positive = true };
	result.add(current_big, one);
	return value::intern_big(comp, result.to_const());
}

fn bool enum_value_fits(value::Value val, type_store::QualType qt, compilation::Compilation* comp)
{
	bigint::BigIntConst big = val.to_big_int(comp);
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
	return Diagnostic.ENUM_NOT_REPRESENTABLE_FIXED.@emit(p, tok, p.fmt_qt(qt));
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
		Diagnostic.ENUMERATOR_OVERFLOW.@emit(p, tok)!;
		self.qt = larger_qt;
	}
	else
	{
		value::Value unbounded_next = increment_enum_value(old_val, p.comp);
		bigint::BigIntConst value_bigint = unbounded_next.to_big_int(p.comp);
		String value_text = value_bigint.to_string_alloc(tmem, 10, false);
		Diagnostic.ENUM_NOT_REPRESENTABLE.@emit(p, tok, value_text)!;
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
	if (p.comp.fixed_enum_tag_is_int()) return type_store::INT;
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
			Diagnostic.ENUM_TOO_LARGE.@emit(p, tok)!;
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
				Diagnostic.ENUM_VAL_UNAVAILABLE.@emit(p, name_tok + 2)!;
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
					Diagnostic.ENUMERATOR_TOO_SMALL.@emit(p, name_tok,
						p.fmt_value(enumerator.val, enumerator.qt))!;
				}
			}
			else if (value::compare(enumerator.val, bigint::CompareOperator.GT,
				value::max_int(type_store::INT, p.comp), p.comp))
			{
				Diagnostic.ENUMERATOR_TOO_LARGE.@emit(p, name_tok,
					p.fmt_value(enumerator.val, enumerator.qt))!;
			}
		}

		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.ENUM_FIELD,
			.enum_field = { .name_tok = name_tok, .qt = enumerator.qt, .init = init } });
		enum_wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
		p.tree.set_value(node, enumerator.val);
		p.symbols.define_enumeration(p, name, enumerator.qt, name_tok, enumerator.val, node)!;
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
			symbol_stack::Symbol* symbol = p.symbols.get_var_ptr(field.name);
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
				parser_result::Result result = { .val = value::NONE };
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

fn type_store::BuilderSpecifier? type_specifier_token(tokenizer::TokenId id)
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
		default: return NOT_TYPE_SPECIFIER~;
	}
	return { .tag = tag };
}

fn bool DeclarationParser.starts_decl_specifier(&self, parser::Parser* p)
{
	if (p.at_eof()) return false;
	tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
	if (@ok(type_specifier_token(id)) || (id.canonical() == KEYWORD_CONST) || (id.canonical() == KEYWORD_VOLATILE) || (id.canonical() == KEYWORD_RESTRICT)) return true;
	switch (id)
	{
		case KEYWORD_BIT_INT: case KEYWORD_TYPEOF: case KEYWORD_TYPEOF1: case KEYWORD_TYPEOF2: case KEYWORD_TYPEOF_UNQUAL:
		case KEYWORD_AUTO: case KEYWORD_AUTO_TYPE: case KEYWORD_TYPEDEF: case KEYWORD_EXTERN:
		case KEYWORD_STATIC: case KEYWORD_REGISTER: case KEYWORD_THREAD_LOCAL: case KEYWORD_THREAD:
		case KEYWORD_CONSTEXPR: case KEYWORD_INLINE: case KEYWORD_INLINE1: case KEYWORD_INLINE2:
		case KEYWORD_ALIGNAS: case KEYWORD_C23_ALIGNAS:
		case KEYWORD_ATOMIC: case KEYWORD_STRUCT: case KEYWORD_UNION: case KEYWORD_ENUM:
		case KEYWORD_CDECL: case KEYWORD_CDECL2:
		case KEYWORD_FASTCALL: case KEYWORD_FASTCALL2: case KEYWORD_REGCALL:
		case KEYWORD_STDCALL: case KEYWORD_STDCALL2:
		case KEYWORD_THISCALL: case KEYWORD_THISCALL2:
		case KEYWORD_VECTORCALL: case KEYWORD_VECTORCALL2:
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
fn DeclSpec? DeclarationParser.parse_decl_spec(&self, parser::Parser* p, attribute_wip::Wip* wip, bool allow_storage = true,
	bool record_member = false)
{
	tokens::TokenIndex start_tok = p.tok_i;
	attribute_wip::State saved_wip = wip.state(false);
	AttributeUseSnapshot saved_attribute_use;
	saved_attribute_use.init(p, wip);
	defer saved_attribute_use.free();
	DeclSpec result = {};
	bool committed = false;
	defer
	{
		if (!committed)
		{
			wip.restore(saved_wip);
			saved_attribute_use.restore(wip);
			if (!result.recognized) p.tok_i = start_tok;
		}
	}
	type_store::Builder builder = { .parser = p };
	bool consumed = false;
	while (!p.at_eof())
	{
		uint attr_count = self.append_attributes(p, wip)!;
		if (attr_count > 0) continue;
		tokens::TokenIndex tok = p.tok_i;
		tokenizer::TokenId id = p.tree.tokens[(usz)tok].id;
		type_store::BuilderSpecifier? specifier = type_specifier_token(id);
		if ((id.canonical() == KEYWORD_TYPEOF || id == KEYWORD_TYPEOF_UNQUAL))
		{
			result.recognized = true;
			type_store::QualType? typeof_type = self.parse_typeof_specifier(p, id);
			if (catch typeof_type) return PARSING_FAILED~;
			if (catch builder.combine_from_typeof(typeof_type, tok)) return PARSING_FAILED~;
			consumed = true; result.recognized = true; continue;
		}
		if (id == KEYWORD_ALIGNAS || id == KEYWORD_C23_ALIGNAS)
		{
			result.recognized = true;
			self.parse_alignas_specifier(p, wip, tok, id)!;
			consumed = true; continue;
		}
		if (id == KEYWORD_BIT_INT)
		{
			result.recognized = true;
			parse_bit_int_specifier(p, &builder, tok)!;
			consumed = true; continue;
		}
		if (try specifier)
		{
			result.recognized = true;
			if (catch builder.combine(specifier, tok)) return PARSING_FAILED~;
			p.advance(); consumed = true; result.recognized = true; continue;
		}
		if ((id.canonical() == KEYWORD_CONST)) { builder.has_const = true; builder.const_tok = tok; p.advance(); consumed = true; result.recognized = true; continue; }
		if ((id.canonical() == KEYWORD_VOLATILE)) { builder.has_volatile = true; builder.volatile_tok = tok; p.advance(); consumed = true; result.recognized = true; continue; }
		if ((id.canonical() == KEYWORD_RESTRICT)) { builder.has_restrict = true; builder.restrict_tok = tok; p.advance(); consumed = true; result.recognized = true; continue; }
		if (id == KEYWORD_AUTO_TYPE)
		{
			result.recognized = true;
			Diagnostic.AUTO_TYPE_EXTENSION.@emit(p, tok)!;
			if (catch builder.combine({ .tag = type_store::BuilderSpecifierTag.AUTO_TYPE }, tok)) return PARSING_FAILED~;
			result.auto_type_tok = tok;
			p.advance(); consumed = true; result.recognized = true; continue;
		}
		if (id == KEYWORD_AUTO && p.comp.langopts.standard.at_least(C23))
		{
			result.recognized = true;
			if (catch builder.combine({ .tag = type_store::BuilderSpecifierTag.C23_AUTO }, tok)) return PARSING_FAILED~;
			result.c23_auto_tok = tok;
			p.advance(); consumed = true; result.recognized = true; continue;
		}
		if (id == KEYWORD_ATOMIC)
		{
			result.recognized = true;
			p.advance(); consumed = true;
			self.parse_atomic_specifier(p, &builder, tok)!;
			continue;
		}
		if (id == KEYWORD_STRUCT || id == KEYWORD_UNION || id == KEYWORD_ENUM)
		{
			result.recognized = true;
			type_store::QualType? record_type = self.parse_record_specifier(p, id == KEYWORD_ENUM, wip,
				&result.tag_decl_node, &result.has_tag_decl_node, record_member);
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
		if (id.is_identifier())
		{
			if (builder.type.tag != type_store::BuilderSpecifierTag.NONE) break;
			symbol_stack::Symbol typedef_symbol;
			string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(tok));
			if (p.find_typedef(name, tok, true, &typedef_symbol)!)
			{
				result.recognized = true;
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

<* `_Alignas(type-name)` / `alignas(expr)`, recorded as a keyword attribute.
 The `parse_decl_spec` helpers are out of line so `parse_decl_spec`, live
 while nested struct bodies are parsed, stays small. *>
fn void? DeclarationParser.parse_alignas_specifier(&self, parser::Parser* p, attribute_wip::Wip* wip, tokens::TokenIndex tok, tokenizer::TokenId id) @noinline
{
	String spelling = p.tree.tok_slice(tok);
	if (id == KEYWORD_C23_ALIGNAS)
	{
		if (p.comp.langopts.standard.at_least(C23))
		{
			Diagnostic.PRE_C23_COMPAT.@emit(p, tok, spelling)!;
		}
	}
	else if (p.comp.langopts.standard.at_least(C11))
	{
		Diagnostic.PRE_C11_COMPAT.@emit(p, tok, spelling)!;
	}
	else
	{
		Diagnostic.C11_EXTENSION.@emit(p, tok, spelling)!;
	}
	p.advance();
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	parser_result::Result arg = { .val = value::NONE };
	parser::TypeNameProbe? maybe_type_name = p.probe_typed_type_name();
	if (catch maybe_type_name) return PARSING_FAILED~;
	parser::TypeNameProbe type_name = maybe_type_name;
	if (type_name.matched)
	{
		type_store::QualType qt = type_name.qt;
		if (!qt.alignable(p.comp))
		{
			Diagnostic.INVALID_ALIGNOF.@emit(p, tok, p.fmt_qt(qt))!;
		}
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.ALIGNAS_TYPE,
			.alignas_type = { .alignas_tok = tok, .qt = qt } });
		arg = { .node = node, .qt = qt, .val = value::NONE };
	}
	else
	{
		parser_result::Result? maybe_expr = p.integer_const_expr(true,
			parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING);
		if (catch maybe_expr) return PARSING_FAILED~;
		arg = maybe_expr;
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	parser_result::Result[1] args = { arg };
	wip.add_keyword(p, tok, args[..]);
}

<* `_BitInt(N)` *>
fn void? parse_bit_int_specifier(parser::Parser* p, type_store::Builder* builder, tokens::TokenIndex tok) @noinline
{
	Diagnostic.BIT_INT.@emit(p, tok)!;
	p.advance();
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	parser_result::Result? maybe_width = p.integer_const_expr(true, parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION);
	if (catch maybe_width) return PARSING_FAILED~;
	parser_result::Result width = maybe_width;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	if (width.val.is_none())
	{
		Diagnostic.EXPECTED_INTEGER_CONSTANT_EXPR.@emit(p, width.node.tok(&p.tree))!;
		return PARSING_FAILED~;
	}
	ulong bits = 0;
	if (!value::compare(width.val, bigint::CompareOperator.LTE, value::ZERO, p.comp))
	{
		bits = width.val.to_u64(p.comp) ?? ulong::max;
	}
	if (catch builder.combine({ .tag = type_store::BuilderSpecifierTag.BIT_INT, .bits = bits }, tok)) return PARSING_FAILED~;
}

<* `_Atomic` qualifier or `_Atomic(type-name)` specifier, after the keyword. *>
fn void? DeclarationParser.parse_atomic_specifier(&self, parser::Parser* p, type_store::Builder* builder, tokens::TokenIndex tok) @noinline
{
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
		if (spec.qt.is_auto_type())
		{
			Diagnostic.AUTO_TYPE_NOT_ALLOWED.@emit(p, spec.auto_type_tok, "type name")!;
		}
		else
		{
			Diagnostic.C23_AUTO_NOT_ALLOWED.@emit(p, spec.c23_auto_tok, "type name")!;
		}
		spec.qt = type_store::INVALID;
	}
	type_store::QualType qt = p.abstract_declarator(self, &wip, spec.qt)!;
	self.append_attributes(p, &wip)!;
	qt = wip.apply_type_attrs(p, qt)!;
	return wip.apply_pending_calling_conventions(p, qt);
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
	$if env::TESTING:
		if (self.test_probe)
		{
			if (&self.test_probe.implicit_typedefs) return self.test_probe.implicit_typedefs(p);
			return parser::HOOK_ABSENT~;
		}
	$endif
	return implicit_typedef_prelude(p);
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
	type_store::NodeOptIndex previous = p.symbols.define_typedef(p, interned_name, typedef_qt, name_tok, node)!;
	assert(previous == type_store::NODE_NULL, "implicit typedef names should be unique in the outer scope");
	p.tree.root_decls.push(node);
}

<* Zig `Parser.parse` implicit typedef prelude, in Zig's order. char8_t, __int24 and
   __mfp8 follow LangOpts and Target; __float80 follows the emulated compiler. The
   callback runs before any declaration, so every entry is a leading root. *>
fn void? implicit_typedef_prelude(parser::Parser* p)
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

<* IExpressionGrammar: initializer grammar uses Parser's composed
   assignment-expression and integer-constant-expression entry points. *>
fn parser_result::Result? DeclarationParser.assignment_expression(&self, parser::Parser* p, bool eval) @dynamic
	=> p.assign_expr(eval);

fn parser_result::Result? DeclarationParser.integer_constant_expression(&self, parser::Parser* p,
	parser::ConstDeclFoldingMode folding_mode, bool eval) @dynamic
	=> p.integer_const_expr(eval, folding_mode);

<* The default statement binding must use the same parser-owned expression
   composition as declarations and initializers. *>
fn parser_result::Result? DeclarationParser.expression(&self, parser::Parser* p, bool eval) @dynamic
	=> p.expr(eval);

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

<* Parse one parameter declaration in Parser.function_suffix's temporary prototype
   scope. Named parameters get their own typed AST nodes and ordinary symbols;
   unnamed parameters remain available as type-only FuncParam entries. *>
fn type_store::FuncParam? DeclarationParser.parse_parameter_declaration(&self, parser::Parser* p,
	attribute_wip::Wip* wip)
{
	attribute_wip::State wip_state = wip.state(true);
	// Outer declarators may already have conventions queued while waiting for
	// their completed type. Parameter parsing sees only conventions added in
	// this parameter's Wip scope; restore reinstates the outer cursor afterward.
	wip.pending_calling_conventions_cursor = (uint)wip.pending_calling_conventions.len();
	defer wip.restore(wip_state);
	tokens::TokenIndex first_tok = p.tok_i;
	DeclSpec? maybe_spec = self.parse_decl_spec(p, wip);
	fault spec_fault = @catch(maybe_spec);
	DeclSpec spec;
	if (spec_fault)
	{
		if (spec_fault != NO_DECL_SPEC) return spec_fault~;
		if (p.comp.langopts.standard.at_least(C23) &&
			(p.is_at(tokenizer::TokenId.IDENTIFIER) || p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER)))
		{
			Diagnostic.UNKNOWN_TYPE_NAME.@emit(p, first_tok,
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
			if (p.at_eof())
			{
				Diagnostic.EXPECTED_EOF.@emit(p, p.diag_index(), "parameter declaration")!;
			}
			else if (p.tree.tokens[(usz)first_tok].id == tokenizer::TokenId.INVALID)
			{
				Diagnostic.EXPECTED_INVALID.@emit(p, first_tok, "parameter declaration")!;
			}
			else
			{
				Diagnostic.EXPECTED_TOKEN.@emit(p, first_tok,
					"parameter declaration", p.tree.tokens[(usz)first_tok].id.symbol())!;
			}
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
		Diagnostic.INVALID_STORAGE_ON_PARAM.@emit(p, first_tok)!;
	}
	if (spec.qt.is_auto())
	{
		if (spec.qt.is_auto_type())
		{
			Diagnostic.AUTO_TYPE_NOT_ALLOWED.@emit(p, spec.auto_type_tok, "function prototype")!;
		}
		else
		{
			Diagnostic.C23_AUTO_NOT_ALLOWED.@emit(p, spec.c23_auto_tok, "function prototype")!;
		}
		spec.qt = type_store::INVALID;
	}

	parser::ParsedDeclarator parsed = p.parse_declarator(self, wip, spec.qt, parser::DeclaratorKind.PARAM)!;
	type_store::QualType qt = parsed.qt;
	self.append_attributes(p, wip)!;
	qt = wip.apply_type_attrs(p, qt)!;
	qt = wip.apply_pending_calling_conventions(p, qt)!;
	// Zig QualType.decay returns invalid for invalid; validate may have produced it.
	if (!qt.is_invalid() && (qt.is(p.comp, type_store::TypeTag.ARRAY) || qt.is(p.comp, type_store::TypeTag.FUNC)))
	{
		qt = qt.decay(p.comp);
	}

	type_store::NodeOptIndex param_node = type_store::NODE_NULL;
	string_interner::StringId name = string_interner::EMPTY;
	tokens::TokenIndex name_tok = first_tok;
	if (parsed.name_tok.has_value)
	{
		name_tok = parsed.name_tok.value;
		name = p.comp.intern_string(p.tree.tok_slice(name_tok));
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.PARAM, .param = {
			.name_tok = name_tok,
			.qt = qt,
			.storage_class = spec.storage_class == StorageClass.REGISTER ? tree::ParamStorageClass.REGISTER : tree::ParamStorageClass.AUTO,
		} });
		wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
		param_node = node.pack();
		p.symbols.define_param(p, name, qt, name_tok, node)!;
		p.add_maybe_unused(node)!;
	}
	return { .qt = qt, .name = name, .name_tok = (type_store::TokenIndex)name_tok, .node = param_node };
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
	if (is_typedef)
	{
		*previous = p.symbols.define_typedef(p, name, qt, name_tok, node)!;
		return;
	}
	if (is_definition)
	{
		*previous = p.symbols.define_symbol(p, name, qt, name_tok, node, value::NONE, constexpr_decl)!;
		return;
	}
	*previous = p.symbols.declare_symbol(p, name, qt, name_tok, node)!;
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
	self.index_file_scope_decls(p);
	string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
	tree::NodeKind declaration_kind = declaration.kind;
	uint entry = p.file_scope_decl_head.get((uint)name) ?? 0;
	while (entry != 0)
	{
		parser::FileScopeDeclEntry decl = p.file_scope_decls[(sz)entry - 1];
		entry = decl.prev;
		tree::Node prior = decl.node.get(&p.tree);
		if (prior.kind != declaration_kind) continue;
		if (prior.kind == tree::NodeKind.FUNCTION) { prior.function.definition = definition.pack(); }
		else { prior.variable.definition = definition.pack(); }
		p.tree.set_node(prior, (sz)decl.node);
	}
}

<* Extend the name index over `root_decls` pushed since the last call, so
   `link_top_level_declarations` only visits same-name declarations. *>
fn void DeclarationParser.index_file_scope_decls(&self, parser::Parser* p)
{
	sz len = p.tree.root_decls.len();
	for (sz i = (sz)p.file_scope_decls_indexed; i < len; i++)
	{
		type_store::NodeIndex root_decl = p.tree.root_decls[i];
		tree::Node node = root_decl.get(&p.tree);
		tokens::TokenIndex name_tok;
		if (node.kind == tree::NodeKind.FUNCTION) { name_tok = node.function.name_tok; }
		else if (node.kind == tree::NodeKind.VARIABLE) { name_tok = node.variable.name_tok; }
		else { continue; }
		string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
		uint prev = p.file_scope_decl_head.get((uint)name) ?? 0;
		p.file_scope_decls.push({ .node = root_decl, .prev = prev });
		p.file_scope_decl_head.set((uint)name, (uint)p.file_scope_decls.len());
	}
	p.file_scope_decls_indexed = (usz)len;
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
				symbol_stack::Symbol* symbol_ptr = p.symbols.get_var_ptr(name);
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
		p.symbols.define_param(p, param.name, param.qt,
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
		DeclSpec spec = self.parse_decl_spec(p, &wip)!;
		if (spec.storage_class != StorageClass.NONE && spec.storage_class != StorageClass.REGISTER)
		{
			Diagnostic.INVALID_STORAGE_ON_PARAM.@emit(p, spec_tok)!;
		}
		while (true)
		{
			// Zig: per-declarator attribute state is taken before the declarator,
			// so attributes after `*` do not leak into the next declarator.
			attribute_wip::State declarator_state = wip.state(false);
			AttributeUseSnapshot attribute_use_state;
			attribute_use_state.init(p, &wip);
			defer attribute_use_state.free();
			parser::ParsedDeclarator parsed = p.parse_declarator(self, &wip, spec.qt)!;
			self.append_attributes(p, &wip)!;
			type_store::QualType parsed_qt = wip.apply_type_attrs(p, parsed.qt)!;
			parsed_qt = wip.apply_pending_calling_conventions(p, parsed_qt)!;
			if (!parsed.name_tok.has_value)
			{
				p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!;
				return PARSING_FAILED~;
			}
			tokens::TokenIndex name_tok = parsed.name_tok.value;
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
				Diagnostic.PARAMETER_MISSING.@emit(p, name_tok,
					p.tree.tok_slice(name_tok))!;
				type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.PARAM, .param = {
					.name_tok = name_tok,
					.qt = qt,
					.storage_class = spec.storage_class == StorageClass.REGISTER ?
						tree::ParamStorageClass.REGISTER : tree::ParamStorageClass.AUTO,
				} });
				wip.apply_decl_attrs(p, node, type_store::NODE_NULL)!;
				p.symbols.define_param(p, name, qt, name_tok, node)!;
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
					p.symbols.define_param(p, name, qt, name_tok, previous.node.unwrap())!;
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
					symbol_stack::Symbol* symbol = p.symbols.get_var_ptr(name);
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
		Diagnostic.PARAM_NOT_DECLARED.@emit(p, (tokens::TokenIndex)param.name_tok,
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
	return Diagnostic.EXPECTED_FN_BODY.@emit_at(p, loc.expand(p.comp), p.pp.expansion_slice(tok));
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
			Diagnostic.OMITTING_PARAMETER_NAME.@emit(p, (tokens::TokenIndex)param.name_tok)!;
		}
		if (is_unbound_vla_parameter(p, param.qt))
		{
			Diagnostic.UNBOUND_VLA.@emit(p, (tokens::TokenIndex)param.name_tok)!;
		}
		if (param.qt.has_incomplete_size(p.comp))
		{
			Diagnostic.PARAMETER_INCOMPLETE_TY.@emit(p, (tokens::TokenIndex)param.name_tok, p.fmt_qt(param.qt))!;
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
				text_literal_semantics::PrintStringStyle.BARE)!!;
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
	if (lhs_val.print(n.binary.lhs.qt(&p.tree), p.comp, &note, &lhs_nested)!) return;
	note.appendf(" %s ", p.tree.tok_slice(n.binary.op_tok));
	value::NestedPrint rhs_nested;
	if (rhs_val.print(n.binary.rhs.qt(&p.tree), p.comp, &note, &rhs_nested)!) return;
	String eval_text = note.str_view();
	if (eval_text == requirement) return;
	Diagnostic.STATIC_ASSERT_EXPRESSION_EVALUATES_TO.@emit(p, n.binary.op_tok, eval_text)!;
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
			Diagnostic.PRE_C23_COMPAT.@emit(p, static_assert_tok, spelling)!;
		}
	}
	else if (p.comp.langopts.standard.at_least(C11))
	{
		Diagnostic.PRE_C11_COMPAT.@emit(p, static_assert_tok, spelling)!;
	}
	else
	{
		Diagnostic.C11_EXTENSION.@emit(p, static_assert_tok, spelling)!;
	}
	p.advance();
	tokens::TokenIndex l_paren = p.tok_i;
	p.expect(tokenizer::TokenId.L_PAREN)!;
	// Zig: the condition is folded with record_static_assert_eval_note set, restored on exit.
	tokens::TokenIndex res_token = p.tok_i;
	bool old_eval_note = p.record_static_assert_eval_note;
	p.record_static_assert_eval_note = true;
	defer p.record_static_assert_eval_note = old_eval_note;

	parser_result::Result res = p.const_expr(true, parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION)!;

	bool has_message = false;
	parser_result::Result message = {};
	if (p.is_at(tokenizer::TokenId.COMMA))
	{
		p.advance();
		if (p.at_eof() || !parser::is_string_token(p.tree.tokens[(usz)p.tok_i].id))
		{
			Diagnostic.EXPECTED_STR_LITERAL.@emit(p, p.tok_i)!;
			return PARSING_FAILED~;
		}
		parser_result::Result maybe_message = p.parse_string(p.tok_i)!;
		message = maybe_message;
		has_message = true;
	}
	p.expect_closing(tokenizer::TokenId.R_PAREN, l_paren)!;
	p.expect(tokenizer::TokenId.SEMICOLON)!;
	if (!has_message)
	{
		if (p.comp.langopts.standard.at_least(C23))
		{
			Diagnostic.STATIC_ASSERT_MISSING_MESSAGE_COMPAT.@emit(p, static_assert_tok)!;
		}
		else
		{
			Diagnostic.STATIC_ASSERT_MISSING_MESSAGE.@emit(p, static_assert_tok)!;
		}
	}

	// Zig: a non-integer condition has no constant value; then cast to bool.
	bool is_int_expr = res.qt.is_invalid() || res.qt.is_int(p.comp);
	if (!res.qt.is_invalid()) res.cast_to_bool(p, res_token)!;
	if (!is_int_expr) res.val = value::NONE;
	if (res.val.is_none())
	{
		if (!res.qt.is_invalid()) Diagnostic.STATIC_ASSERT_NOT_CONSTANT.@emit(p, res_token)!;
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
		Diagnostic.STATIC_ASSERT_FAILURE_MESSAGE.@emit(p, res_token, full_text[STATIC_ASSERT_PREFIX.len:full_text.len - STATIC_ASSERT_PREFIX.len])!;
		// C3 `x[start:len]` takes a length, not an end index.
		String requirement_text = full_text[requirement.req_start:requirement.req_end - requirement.req_start];
		static_assert_evaluation_note(p, res.node, requirement_text)!;
	}

	type_store::NodeOptIndex message_node = type_store::NODE_NULL;
	if (has_message) message_node = (type_store::NodeOptIndex)message.node;
	return p.tree.add_node({ .kind = tree::NodeKind.STATIC_ASSERT,
		.static_assert = { .assert_tok = static_assert_tok, .cond = res.node, .message = message_node } });
}

<* Zig `Parser.decl`: a file-scope declaration without declaration specifiers
   (`foo (a) { ... }`, `*p;`, `(f)(void);`) is implicit int; `Builder.finish`
   reports the missing specifier for the selected standard. `name name` is an
   unknown type name instead. NO_DECL_SPEC when the tokens cannot start a declarator. *>
fn DeclSpec? DeclarationParser.implicit_int_decl_spec(&self, parser::Parser* p)
{
	tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
	if (id != tokenizer::TokenId.ASTERISK && id != tokenizer::TokenId.L_PAREN)
	{
		if (!id.is_identifier()) return NO_DECL_SPEC~;
		if (p.tree.tokens[(usz)p.tok_i + 1].id.is_identifier())
		{
			Diagnostic.UNKNOWN_TYPE_NAME.@emit(p, p.tok_i, p.tree.tok_slice(p.tok_i))!;
			p.advance();
			return { .qt = type_store::INVALID, .recognized = true };
		}
	}
	type_store::Builder builder = { .parser = p };
	return { .qt = builder.finish()!, .recognized = true };
}

<* Parse a complete declaration and append its declaration nodes to a local
   DECL_STMT or to Tree.root_decls. *>
fn type_store::NodeIndex? DeclarationParser.parse_declaration_impl(&self, parser::Parser* p, bool local = false,
	parser_attribute::AttributeBuffer* prefix_attributes = null)
{
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
		return self.parse_declaration_impl(p, local, prefix_attributes);
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
	// Zig rootItem / compoundStmtItem: `__extension__ decl` parses the declaration
	// with extension diagnostics suppressed (glibc: `__extension__ typedef struct`).
	if (p.is_at(tokenizer::TokenId.KEYWORD_EXTENSION))
	{
		tokens::TokenIndex ext_tok = p.tok_i;
		p.advance();
		bool saved_extension = p.extension_suppressed;
		defer p.extension_suppressed = saved_extension;
		p.extension_suppressed = true;
		// Zig rootItem: a bare `__extension__;` is consumed without a diagnostic.
		if (!local && p.is_at(tokenizer::TokenId.SEMICOLON))
		{
			p.advance();
			return (type_store::NodeIndex)0;
		}
		type_store::NodeIndex? ext_decl = self.parse_declaration_impl(p, local, prefix_attributes);
		// Block scope: not a declaration, so rewind and let the statement parser read
		// `__extension__` as a unary expression operator.
		if (local && @catch(ext_decl) == tree::NULL_NODE) p.tok_i = ext_tok;
		return ext_decl;
	}
	if (local && prefix_attributes != null)
	{
		// Prefix statement attributes are parsed by StatementParser before it
		// knows whether this is a declaration. Avoid evaluating them if the
		// declaration probe is going to fall back to an expression statement.
		if (!self.starts_decl_specifier(p)) return tree::NULL_NODE~;
		parser_statement::append_statement_attributes(p, prefix_attributes, &wip)!;
	}
	tokens::TokenIndex first_tok = p.tok_i;
	usz first_spec_node = (usz)p.tree.nodes.len();
	DeclSpec? maybe_spec = self.parse_decl_spec(p, &wip);
	fault spec_fault = @catch(maybe_spec);
	DeclSpec implicit_spec = {};
	bool reported_no_type = false;
	if (spec_fault)
	{
		if (spec_fault != NO_DECL_SPEC) return spec_fault~;
		if (local) return tree::NULL_NODE~; // not a declaration: the statement parser tries an expression
		// Zig `externalDeclaration`: file-scope `asm("...");`.
		type_store::NodeIndex? global_asm = p.parse_global_asm();
		if (catch asm_fault = global_asm)
		{
			if (asm_fault != parser::NOT_ASM) return asm_fault~;
		}
		else
		{
			p.tree.root_decls.push(global_asm);
			return (type_store::NodeIndex)0;
		}
		// Zig `externalDeclaration`: a stray file-scope ';' is an empty declaration.
		if (p.is_at(tokenizer::TokenId.SEMICOLON))
		{
			tokens::TokenIndex semicolon = p.tok_i;
			Diagnostic.EXTRA_SEMI.@emit(p, semicolon)!;
			p.advance();
			p.tree.root_decls.push(self.add_empty_declaration(p, semicolon));
			return (type_store::NodeIndex)0;
		}
		// Only when no specifier tokens were consumed (a failed `__typeof (f)` leaves the
		// cursor mid-declaration; Zig takes this path only at the declaration start).
		DeclSpec? maybe_implicit = NO_DECL_SPEC~;
		if (p.tok_i == first_tok) maybe_implicit = self.implicit_int_decl_spec(p);
		if (catch implicit_fault = maybe_implicit)
		{
			if (implicit_fault != NO_DECL_SPEC) return implicit_fault~;
			Diagnostic.EXPECTED_EXTERNAL_DECL.@emit(p, p.diag_index())!;
			// At file scope an unexpected compound statement is one malformed item.
			// Skip its balanced body so each token inside it does not produce another
			// expected-external-declaration diagnostic.
			if (p.is_at(tokenizer::TokenId.L_BRACE)) p.recover();
			return PARSING_FAILED~;
		}
		implicit_spec = maybe_implicit;
	}
	DeclSpec spec = spec_fault ? implicit_spec : maybe_spec!!;
	list::List{type_store::NodeIndex} declarations;
	declarations.init(p.comp.gpa);
	defer declarations.free();
	bool has_tag_declaration = false;
	// A record definition can create additional tag nodes while its body is
	// parsed. Only the tag reached by this declaration's type specifier belongs
	// beside the resulting declarator; nested anonymous/member tags stay inside
	// the record tree.
	if (spec.has_tag_decl_node && (usz)spec.tag_decl_node >= first_spec_node &&
		(usz)spec.tag_decl_node < (usz)p.tree.nodes.len())
	{
		type_store::NodeIndex spec_node_index = spec.tag_decl_node;
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
		wip.apply_pending_calling_conventions(p, spec.qt)!;
		tokens::TokenIndex semi = p.tok_i;
		p.advance();
		if (!has_tag_declaration) declarations.push(self.add_empty_declaration(p, semi));
	}
	else
	{
		bool warned_auto_single_declarator = false;
		while (true)
		{
			// Zig `declarator_attr_state`: taken before the declarator, so attributes
			// after `*` do not leak into the next declarator.
			attribute_wip::State declarator_wip_state = wip.state(false);
			AttributeUseSnapshot attribute_use_state;
			attribute_use_state.init(p, &wip);
			defer attribute_use_state.free();
			parser::ParsedDeclarator parsed = p.parse_declarator(self, &wip, spec.qt)!;
			// Zig `initDeclarator`: attributes, optional asm label, attributes.
			self.append_attributes(p, &wip)!;
			parser::AsmLabel? asm_label = p.parse_asm_label();
			if (catch label_fault = asm_label)
			{
				if (label_fault != parser::NOT_ASM) return label_fault~;
			}
			else
			{
				parser_result::Result[1] label_args = { asm_label.label };
				wip.add_keyword(p, asm_label.asm_tok, label_args[..]);
				self.append_attributes(p, &wip)!;
			}
			tokens::TokenIndex name_tok = parsed.name_tok.value;
			string_interner::StringId name = p.comp.intern_string(p.tree.tok_slice(name_tok));
			type_store::QualType qt = wip.apply_type_attrs(p, parsed.qt)!;
			qt = wip.apply_pending_calling_conventions(p, qt)!;
			bool has_auto_type = spec.qt.is_auto();
			if (!local && spec.storage_class == StorageClass.AUTO)
			{
				Diagnostic.AUTO_ON_GLOBAL.@emit(p, spec.auto_tok)!;
			}
			bool has_initializer = p.is_at(tokenizer::TokenId.EQUAL);
			bool function_type = qt.is(p.comp, type_store::TypeTag.FUNC);
			type_store::Func fn_type = {};
			if (function_type) fn_type = qt.get(p.comp, type_store::TypeTag.FUNC)!.func;
			bool old_style_function = function_type && fn_type.kind == type_store::FuncKind.OLD_STYLE;
			bool deduced_type = has_auto_type;
			if (has_auto_type)
			{
				// Zig switches on declarator_type: validate may already have made qt invalid.
				parser::DeclaratorType declarator_type = parsed.declarator_type;
				if (declarator_type == parser::DeclaratorType.FUNC || declarator_type == parser::DeclaratorType.BLOCK)
				{
					String context = declarator_type == parser::DeclaratorType.BLOCK ? "block return type" : "function return type";
					if (spec.qt.is_auto_type())
					{
						Diagnostic.AUTO_TYPE_NOT_ALLOWED.@emit(p, spec.auto_type_tok, context)!;
					}
					else
					{
						Diagnostic.C23_AUTO_NOT_ALLOWED.@emit(p, spec.c23_auto_tok, context)!;
					}
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (declarator_type == parser::DeclaratorType.ARRAY)
				{
					if (spec.qt.is_auto_type())
					{
						Diagnostic.AUTO_TYPE_ARRAY.@emit(p, name_tok, p.tree.tok_slice(name_tok))!;
					}
					else
					{
						Diagnostic.C23_AUTO_ARRAY.@emit(p, name_tok, p.tree.tok_slice(name_tok))!;
					}
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (declarator_type == parser::DeclaratorType.POINTER)
				{
					Diagnostic.AUTO_TYPE_REQUIRES_PLAIN_DECLARATOR.@emit(p, name_tok)!;
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (spec.storage_class == StorageClass.TYPEDEF)
				{
					if (spec.qt.is_auto_type())
					{
						Diagnostic.AUTO_TYPE_NOT_ALLOWED.@emit(p, spec.auto_type_tok, "typedef")!;
					}
					else
					{
						Diagnostic.C23_AUTO_NOT_ALLOWED.@emit(p, spec.c23_auto_tok, "typedef")!;
					}
					qt = type_store::INVALID;
					deduced_type = false;
				}
				else if (!has_initializer)
				{
					if (spec.qt.is_auto_type())
					{
						Diagnostic.AUTO_TYPE_REQUIRES_INITIALIZER.@emit(p, name_tok,
							p.tree.tok_slice(name_tok))!;
					}
					else
				{
						Diagnostic.C23_AUTO_REQUIRES_INITIALIZER.@emit(p, name_tok)!;
					}
					qt = type_store::INVALID;
					deduced_type = false;
				}
			}

			bool function_body_follows = p.is_at(tokenizer::TokenId.L_BRACE);
			bool old_style_declaration_list_follows = old_style_function && parsed.old_style_ident_tok.has_value &&
				self.starts_decl_specifier(p);
			bool old_style_definition_context = old_style_function && parsed.old_style_ident_tok.has_value && !has_initializer &&
				!p.is_at(tokenizer::TokenId.SEMICOLON) && !p.is_at(tokenizer::TokenId.COMMA);
			bool c23_old_style_declaration_list_follows = p.comp.langopts.standard.at_least(C23) &&
				function_type && parsed.old_style_ident_tok.has_value && !has_initializer && !function_body_follows &&
				!p.is_at(tokenizer::TokenId.SEMICOLON) && !p.is_at(tokenizer::TokenId.COMMA) &&
				self.starts_decl_specifier(p);
			if (c23_old_style_declaration_list_follows)
			{
				// C23's parameter grammar has already diagnosed each old-style
				// identifier as an unknown type name. The following declarations
				// are still parsed at file scope; the function itself is missing
				// its body at the closing parenthesis. Match Zig's non-K&R
				// function-definition recovery: locate the diagnostic on `)`.
				if (p.tok_i > 0) { Diagnostic.EXPECTED_FN_BODY.@emit(p, p.tok_i - 1)!; }
				else { Diagnostic.EXPECTED_FN_BODY.@emit(p, p.diag_index())!; }
				return PARSING_FAILED~;
			}
			bool is_function_definition = function_type && (function_body_follows || old_style_declaration_list_follows || old_style_definition_context);
			// GCC pedwarn: C90 implicit int is fine for a function definition, but a
			// declaration with neither type nor storage class is not (gcc.dg/decl-nospec-*.c).
			// From C99 the missing type specifier itself is already diagnosed.
			if (spec_fault && !is_function_definition && !reported_no_type && !p.comp.langopts.standard.at_least(C99))
			{
				reported_no_type = true;
				Diagnostic.DATA_DEFINITION_NO_TYPE.@emit(p, first_tok)!;
			}
			if (is_function_definition)
			{
				list::List{type_store::FuncParam} extra_kr_params;
				extra_kr_params.init(p.comp.gpa);
				defer extra_kr_params.free();
				if (local || has_initializer || spec.storage_class == StorageClass.TYPEDEF)
				{
					Diagnostic.ILLEGAL_STORAGE_ON_FUNC.@emit(p, name_tok)!;
					return PARSING_FAILED~;
				}
				if (spec.storage_class == StorageClass.AUTO || spec.storage_class == StorageClass.REGISTER)
				{
					Diagnostic.ILLEGAL_STORAGE_ON_FUNC.@emit(p, name_tok)!;
				}
				if (old_style_function && parsed.old_style_ident_tok.has_value)
				{
					Diagnostic.DEF_NO_PROTO_DEPRECATED.@emit(p, name_tok)!;
					qt = self.parse_kr_definition_parameters(p, fn_type, &extra_kr_params)!;
					fn_type = qt.get(p.comp, type_store::TypeTag.FUNC)!.func;
					if (!p.is_at(tokenizer::TokenId.L_BRACE))
					{
						if (p.tok_i > 0)
						{
							emit_expected_fn_body_after(p, p.tok_i - 1)!;
						}
						else
						{
							Diagnostic.EXPECTED_FN_BODY.@emit(p, p.diag_index())!;
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
						Diagnostic.MAIN_RETURN_TYPE.@emit(p, name_tok)!;
					}
				}
							type_store::QualType old_function_return_qt = self.function_return_qt;
				tokens::TokenIndex old_function_name_tok = self.function_name_tok;
				parser::FunctionContext old_function_context = self.function_context;
				bool old_has_function_context = self.has_function_context;
				self.function_return_qt = qt.is_invalid() || fn_type.return_type.is(p.comp, type_store::TypeTag.FUNC) ||
					fn_type.return_type.is(p.comp, type_store::TypeTag.ARRAY) ? type_store::INVALID : fn_type.return_type;
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
				type_store::NodeIndex? body = p.parse_body();
				if (catch body_fault = body)
				{
					p.diagnose_unused_locals()!;
					return body_fault~;
				}
				p.diagnose_unused_locals()!;
				tree::Node completed = function_node.get(&p.tree);
				completed.function.body = body.pack();
				p.tree.set_node(completed, (sz)function_node);
				declarations.push(function_node);
				if (!local) p.tree.root_decls.push(function_node);
				return function_node;
			}
			if (old_style_function && parsed.old_style_ident_tok.has_value &&
				(p.is_at(tokenizer::TokenId.SEMICOLON) || p.is_at(tokenizer::TokenId.COMMA)))
			{
				Diagnostic.INVALID_OLD_STYLE_PARAMS.@emit(p, parsed.old_style_ident_tok.value)!;
			}
			else if (old_style_function && !has_initializer &&
				!p.is_at(tokenizer::TokenId.SEMICOLON) && !p.is_at(tokenizer::TokenId.COMMA))
			{
				Diagnostic.EXPECTED_FN_BODY.@emit(p, p.tok_i > 0 ? p.tok_i - 1 : p.diag_index())!;
				return PARSING_FAILED~;
			}

			if (spec.storage_class == StorageClass.TYPEDEF)
			{
				type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.TYPEDEF, .type_def = {
					.name_tok = name_tok, .qt = qt, .implicit = false,
				} });
				// Zig: an invalid declarator type is not wrapped, so the typedef stays invalid.
				type_store::QualType typedef_qt = qt.is_invalid() ? qt :
					p.comp.type_store.put(type_store::type_typedef(qt, name, node)).with_qualifiers(qt);
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
					Diagnostic.ILLEGAL_INITIALIZER.@emit(p, p.tok_i)!;
					p.advance(); // Consume '=' before reporting the malformed initializer.
					parser_result::Result ignored_initializer = self.parse_variable_initializer(p, qt, false, false)!;
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
				if (has_initializer) p.advance();
				type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = {
					.name_tok = name_tok, .qt = qt,
					.storage_class = variable_storage_class(
						spec.storage_class == StorageClass.EXTERN && has_initializer ? StorageClass.NONE : spec.storage_class),
					.thread_local = spec.thread_local, .implicit = false,
					.initializer = type_store::NODE_NULL, .definition = type_store::NODE_NULL,
				} });
				type_store::NodeOptIndex previous = type_store::NODE_NULL;
				bool static_duration = !local || spec.storage_class == StorageClass.STATIC ||
					spec.storage_class == StorageClass.EXTERN || spec.thread_local;
				if (!has_auto_type && !has_initializer)
				{
					self.bind_declaration_symbol(p, name, qt, name_tok, node, false,
						local ? spec.storage_class != StorageClass.EXTERN : has_initializer,
						spec.constexpr_decl, &previous)!;
				}
				if (has_initializer)
				{
					if (spec.storage_class == StorageClass.EXTERN)
					{
						Diagnostic.EXTERN_INITIALIZER.@emit(p, name_tok)!;
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
							spec.constexpr_decl, static_duration, true, node.pack(), name, name_tok);
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
					self.bind_declaration_symbol(p, name, completed_qt, name_tok, node, false,
						local ? spec.storage_class != StorageClass.EXTERN : has_initializer,
						spec.constexpr_decl, &previous)!;
					symbol_stack::Symbol* symbol = p.symbols.get_var_ptr(name);
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
							local ? spec.storage_class != StorageClass.EXTERN : has_initializer,
							spec.constexpr_decl, &previous)!;
					}
				}
				if (!has_initializer && !has_auto_type && !local && spec.storage_class != StorageClass.EXTERN)
				{
					symbol_stack::Symbol* symbol = p.symbols.get_var_ptr(name);
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
					Diagnostic.AUTO_TYPE_REQUIRES_SINGLE_DECLARATOR.@emit(p, spec.auto_type_tok)!;
				}
				else
				{
					Diagnostic.C23_AUTO_SINGLE_DECLARATOR.@emit(p, spec.c23_auto_tok)!;
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
	type_store::NodeIndex parsed = self.parse_declaration_impl(p, false)!;
	return;
}

fn type_store::NodeIndex? DeclarationParser.parse_local_declaration_statement(&self, parser::Parser* p,
	parser_attribute::AttributeBuffer* prefix_attributes = null)
{
	return self.parse_declaration_impl(p, true, prefix_attributes);
}
