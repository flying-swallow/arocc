// Focused tests for declaration helpers, source-derived integration, and parser recovery.
module parser_declaration_tests;
import aro::parser, aro::preprocessor, aro::tokens, aro::tokenizer, aro::tree;
import aro::compilation, aro::diagnostics, aro::source, aro::type_store, aro::symbol_stack, aro::string_interner, aro::value;
import aro::parser_declaration;
import aro::lang_opts, aro::target;
import aro::pragma;
import aro::attribute;

<* Full-frontend trees begin with the implicit typedef prelude, whose size depends on the target. *>
fn sz first_user_root(tree::Tree* result)
{
	sz i = 0;
	while (i < result.root_decls.len())
	{
		tree::Node node = result.root_decls[i].get(result);
		if (node.kind != tree::NodeKind.TYPEDEF || !node.type_def.implicit) break;
		i++;
	}
	return i;
}

struct RecoveryState (parser_declaration::IDeclarationTestProbe)
{
	uint initial_scopes;
	bool saw_following_declaration;
}

struct FrontendFaultRecoveryState (parser_declaration::IDeclarationTestProbe)
{
	parser_declaration::DeclarationParser* frontend;
	bool returned_declaration_module_fault;
}

struct InferredArrayCapture (parser_declaration::IDeclarationTestProbe)
{
	parser_declaration::DeclarationParser declarations;
	type_store::QualType items_qt;
	type_store::QualType text_qt;
	type_store::NodeIndex items_node;
	type_store::NodeIndex text_node;
	uint declaration_count;
}

struct InferredTypeCapture (parser_declaration::IDeclarationTestProbe)
{
	parser_declaration::DeclarationParser declarations;
	string_interner::StringId first_name;
	string_interner::StringId second_name;
	type_store::QualType first_qt;
	type_store::QualType second_qt;
	type_store::NodeIndex first_node;
	type_store::NodeIndex second_node;
	uint declaration_count;
}

fn void? InferredArrayCapture.declaration(&capture, parser::Parser* p) @dynamic
{
	capture.declarations.parse_declaration(p)!;
	if (capture.declaration_count == 0)
	{
		symbol_stack::Symbol* symbol = p.symbols.get_var_ptr(p.comp.intern_string("items"));
		capture.items_qt = symbol.qt;
		capture.items_node = symbol.node;
	}
	else if (capture.declaration_count == 1)
	{
		symbol_stack::Symbol* symbol = p.symbols.get_var_ptr(p.comp.intern_string("text"));
		capture.text_qt = symbol.qt;
		capture.text_node = symbol.node;
	}
	capture.declaration_count++;
}

fn void? InferredTypeCapture.declaration(&capture, parser::Parser* p) @dynamic
{
	capture.declarations.parse_declaration(p)!;
	if (capture.declaration_count == 0)
	{
		if (try symbol = p.symbols.find_symbol(capture.first_name))
		{
			capture.first_qt = symbol.qt;
			capture.first_node = symbol.node;
		}
	}
	else if (capture.declaration_count == 1 && capture.second_name != string_interner::EMPTY)
	{
		if (try symbol = p.symbols.find_symbol(capture.second_name))
		{
			capture.second_qt = symbol.qt;
			capture.second_node = symbol.node;
		}
	}
	capture.declaration_count++;
}

fn void? RecoveryState.declaration(&state, parser::Parser* p) @dynamic
{
	if (p.is_at(tokenizer::TokenId.IDENTIFIER))
	{
		// Model a function-body parse that entered its scope before discovering
		// malformed syntax. The declaration callback owns unwinding that scope.
		p.advance();
		p.push_scope();
		p.pop_scope();
		return parser::PARSING_FAILED~;
	}
	if (p.is_at(tokenizer::TokenId.KEYWORD_INT))
	{
		assert(p.symbols.active_len == state.initial_scopes,
			"following declaration must not inherit the malformed function scope");
		state.saw_following_declaration = true;
		while (!p.at_eof() && !p.is_at(tokenizer::TokenId.SEMICOLON)) p.advance();
		if (!p.at_eof()) p.advance();
		return;
	}
	return parser::PARSING_FAILED~;
}

<* Adapt the real declaration parser's diagnosed syntax failure to its own
 module fault so DeclarationParser's classifier is exercised at translation-unit
 scope. *>
fn void? FrontendFaultRecoveryState.declaration(&state, parser::Parser* p) @dynamic
{
	fault parse_fault = @catch(state.frontend.parse_declaration(p));
	if (parse_fault && !state.returned_declaration_module_fault)
	{
		state.returned_declaration_module_fault = true;
		return parser_declaration::PARSING_FAILED~;
	}
	if (parse_fault) return parse_fault~;
	return;
}

fn source::Location declaration_loc(source::Source src, uint offset) => {
	.id = src.id,
	.byte_offset = offset,
	.line = 1,
};

fn void parser_record_spec_creates_and_reuses_forward_tag() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("record.c", "struct Node")!!;
		pp.add_token({ .id = tokenizer::TokenId.KEYWORD_STRUCT, .loc = declaration_loc(src, 0) })!!;
		pp.add_token({ .id = tokenizer::TokenId.IDENTIFIER, .loc = declaration_loc(src, 7) })!!;
		pp.tokens.push({ .id = tokenizer::TokenId.EOF, .loc = declaration_loc(src, 11) });

		parser::Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		type_store::QualType first = p.record_spec()!!;
		assert(first.get_record(&comp)!!.has_layout == false);
		symbol_stack::Symbol tag;
		bool found = p.find_tag(comp.intern_string("Node"), tokenizer::TokenId.KEYWORD_STRUCT, 1, tokenizer::TokenId.EOF, &tag)!!;
		assert(found && tag.qt.eql(first, &comp));

		p.tok_i = 0;
		type_store::QualType second = p.record_spec()!!;
		assert(second.eql(first, &comp), "repeated forward tag must preserve its type identity");
		assert(p.tree.nodes.len() == 1, "a repeated tag reference should not add a second forward declaration");

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void malformed_function_recovery_preserves_following_translation_unit_state() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("recovery.c", "broken() { } int good;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		RecoveryState state = { .saw_following_declaration = false };
		parser::Parser p;
		parser_declaration::DeclarationParser recovery = { .test_probe = &state };
		p.init(&pp, &recovery);
		state.initial_scopes = (uint)p.symbols.active_len;
		tree::Tree result = p.parse()!!;
		assert(state.saw_following_declaration, "recovery must continue to the following declaration");
		assert(p.symbols.active_len == state.initial_scopes,
			"recovery must unwind to the translation-unit scope");
		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void frontend_recovers_declaration_module_fault_and_keeps_following_node() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("module_recovery.c", "int broken = ; int good = 2;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p;
		p.init(&pp);
		parser_declaration::DeclarationParser frontend;
		frontend.bind(&p);
		FrontendFaultRecoveryState state = { .frontend = &frontend };
		frontend.test_probe = &state;
		tree::Tree result = p.parse()!!;

		assert(state.returned_declaration_module_fault,
			"the malformed declaration should return parser_declaration.PARSING_FAILED after diagnosing");
		assert(d.messages.len() > 0, "the malformed declaration should be diagnosed");
		bool found_good = false;
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind != tree::NodeKind.VARIABLE || result.tok_slice(node.variable.name_tok) != "good") continue;
			found_good = true;
			assert(!node.variable.initializer.is_null(), "the following declaration should retain its initializer");
		}
		assert(found_good, "recovery should preserve the valid declaration node after a non-parser fault");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: declaration parsing records typedef types in the ordinary
// symbol namespace, and later declaration specifiers reuse that type in file,
// parameter, and block scope.
fn void source_derived_default_declaration_callbacks_build_typed_translation_unit() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("declarations.c",
			"typedef int Word; Word object = 7; int sum(Word parameter) { Word local = parameter; return local; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 3, "all three declarations should become translation-unit roots");
		tree::Node typedef_node = result.root_decls[0].get(&result);
		tree::Node object_node = result.root_decls[1].get(&result);
		tree::Node function_node = result.root_decls[2].get(&result);
		assert(typedef_node.kind == tree::NodeKind.TYPEDEF);
		assert(object_node.kind == tree::NodeKind.VARIABLE);
		assert(function_node.kind == tree::NodeKind.FUNCTION);

		// The alias type on later declarations is evidence that the declaration
		// grammar resolved Word through the typedef-sensitive ordinary lookup.
		type_store::QualType word_qt = typedef_node.type_def.qt;
		type_store::Type word_type = word_qt.get_type(&comp);
		assert(word_type.tag == type_store::TypeTag.TYPEDEF);
		assert(word_type.type_def.name == comp.intern_string("Word"));
		assert(object_node.variable.qt.eql(word_qt, &comp));
		assert(!object_node.variable.initializer.is_null(), "the global object should keep its initializer");

		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 1);
		assert(function_type.params[0].qt.eql(word_qt, &comp));
		assert(!function_type.params[0].node.is_null());
		tree::Node parameter_node = function_type.params[0].node.unwrap().get(&result);
		assert(parameter_node.kind == tree::NodeKind.PARAM);
		assert(parameter_node.param.qt.eql(word_qt, &comp));

		assert(!function_node.function.body.is_null(), "sum should be a function definition");
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		assert(body_node.kind == tree::NodeKind.COMPOUND_STMT);
		assert(body_node.compound_stmt.body.len == 2);
		tree::Node declaration_statement = body_node.compound_stmt.body[0].get(&result);
		assert(declaration_statement.kind == tree::NodeKind.DECL_STMT);
		assert(declaration_statement.decl_stmt.decls.len == 1);
		tree::Node local_node = declaration_statement.decl_stmt.decls[0].get(&result);
		assert(local_node.kind == tree::NodeKind.VARIABLE);
		assert(local_node.variable.qt.eql(word_qt, &comp));
		assert(!local_node.variable.initializer.is_null(), "the local declaration should keep its initializer");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: incomplete arrays take their completed bound from the
// initializer AST and publish it on both the variable node and bound symbol.
fn void source_derived_declarations_complete_inferred_array_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("inferred_array_declarations.c",
			"int items[] = {1, 2}; char text[] = \"abc\";")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		InferredArrayCapture capture = {};
		capture.declarations.test_probe = &capture;
		parser::Parser p;
		p.init(&pp, &capture.declarations);
		tree::Tree result = p.parse()!!;

		assert(capture.declaration_count == 2);
		assert(result.root_decls.len() == 2);
		tree::Node items_node = result.root_decls[0].get(&result);
		tree::Node text_node = result.root_decls[1].get(&result);
		assert(items_node.kind == tree::NodeKind.VARIABLE && items_node.variable.qt.eql(capture.items_qt, &comp));
		assert(text_node.kind == tree::NodeKind.VARIABLE && text_node.variable.qt.eql(capture.text_qt, &comp));
		assert(capture.items_node == result.root_decls[0] && capture.text_node == result.root_decls[1]);

		type_store::Type items_type = items_node.variable.qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		type_store::Type items_symbol_type = capture.items_qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(items_type.array.len.kind == type_store::ArrayLenKind.FIXED && items_type.array.len.len == 2);
		assert(items_symbol_type.array.len.kind == type_store::ArrayLenKind.FIXED && items_symbol_type.array.len.len == 2);
		tree::Node items_initializer = items_node.variable.initializer.unwrap().get(&result);
		assert(items_initializer.kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(items_initializer.container_init.container_qt.eql(items_node.variable.qt, &comp));
		assert(items_initializer.container_init.items.len == 2);
		assert(result.tok_slice(items_initializer.container_init.items[0].get(&result).literal.literal_tok) == "1");
		assert(result.tok_slice(items_initializer.container_init.items[1].get(&result).literal.literal_tok) == "2");
		assert(result.value_of(items_initializer.container_init.items[0])!!.to_i64(&comp)!! == 1);
		assert(result.value_of(items_initializer.container_init.items[1])!!.to_i64(&comp)!! == 2);

		type_store::Type text_type = text_node.variable.qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		type_store::Type text_symbol_type = capture.text_qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(text_type.array.len.kind == type_store::ArrayLenKind.FIXED && text_type.array.len.len == 4);
		assert(text_symbol_type.array.len.kind == type_store::ArrayLenKind.FIXED && text_symbol_type.array.len.len == 4);
		tree::Node text_initializer = text_node.variable.initializer.unwrap().get(&result);
		assert(text_initializer.kind == tree::NodeKind.STRING_LITERAL_EXPR);
		type_store::Type text_literal_type = text_initializer.char_literal.qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(text_literal_type.array.len.kind == type_store::ArrayLenKind.FIXED && text_literal_type.array.len.len == 4);
		value::Value text_value = result.value_of(text_node.variable.initializer.unwrap())!!;
		assert(!text_value.is_none());
		assert(d.messages.len() == 0, "valid inferred array initializers should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: GNU __auto_type deduces from an initializer and publishes
// the result before a later initializer looks the variable up by identifier.
fn void source_derived_gnu_auto_type_deduces_and_updates_symbol_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("gnu_auto_type.c",
			"__auto_type source = (long)1; __auto_type copy = source;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		InferredTypeCapture capture = {
			.first_name = comp.intern_string("source"),
			.second_name = comp.intern_string("copy"),
		};
		capture.declarations.test_probe = &capture;
		parser::Parser p;
		p.init(&pp, &capture.declarations);
		tree::Tree result = p.parse()!!;

		assert(capture.declaration_count == 2);
		assert(result.root_decls.len() == 2);
		tree::Node source_node = result.root_decls[0].get(&result);
		tree::Node copy_node = result.root_decls[1].get(&result);
		assert(source_node.kind == tree::NodeKind.VARIABLE);
		assert(copy_node.kind == tree::NodeKind.VARIABLE);
		assert(capture.first_node == result.root_decls[0] && capture.second_node == result.root_decls[1]);
		assert(source_node.variable.qt.eql(type_store::LONG, &comp));
		assert(copy_node.variable.qt.eql(type_store::LONG, &comp));
		assert(capture.first_qt.eql(source_node.variable.qt, &comp));
		assert(capture.second_qt.eql(copy_node.variable.qt, &comp));
		assert(d.messages.len() == 0, "valid __auto_type declarations should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: C23 auto uses initializer deduction when C23 is selected.
fn void source_derived_c23_auto_deduces_initializer_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("c23_auto.c", "auto inferred = 42;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		InferredTypeCapture capture = {
			.first_name = comp.intern_string("inferred"),
		};
		capture.declarations.test_probe = &capture;
		parser::Parser p;
		p.init(&pp, &capture.declarations);
		tree::Tree result = p.parse()!!;

		assert(capture.declaration_count == 1);
		assert(result.root_decls.len() == 1);
		tree::Node inferred_node = result.root_decls[0].get(&result);
		assert(inferred_node.kind == tree::NodeKind.VARIABLE);
		assert(inferred_node.variable.qt.eql(type_store::INT, &comp));
		assert(capture.first_node == result.root_decls[0]);
		assert(capture.first_qt.eql(inferred_node.variable.qt, &comp));
		assert(d.messages.len() == 0, "valid C23 auto inference should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: declaration-only auto specifiers do not start cast type names.
fn void source_derived_auto_specifier_in_cast_reports_expected_expression() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("auto_type_cast.c",
			"int value = (__auto_type)5; int good = 7;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 1, "a bare auto specifier in a cast should be parsed as a missing expression");
		assert(d.messages[0].text == "expected expression");
		assert(result.root_decls.len() == 1, "recovery should retain the declaration after the invalid cast");
		tree::Node good = result.root_decls[0].get(&result);
		assert(good.kind == tree::NodeKind.VARIABLE);
		assert(result.tok_slice(good.variable.name_tok) == "good");
		assert(good.variable.qt.eql(type_store::INT, &comp));

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: in C17, auto is a storage class and int remains the type.
fn void source_derived_c17_auto_is_a_storage_class() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C17;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("c17_auto.c", "void foo(void) { auto int legacy = 1; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the function should be retained");
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		tree::Node declaration_statement = body_node.compound_stmt.body[0].get(&result);
		assert(declaration_statement.kind == tree::NodeKind.DECL_STMT);
		tree::Node legacy_node = declaration_statement.decl_stmt.decls[0].get(&result);
		assert(legacy_node.kind == tree::NodeKind.VARIABLE);
		assert(legacy_node.variable.qt.eql(type_store::INT, &comp));
		assert(legacy_node.variable.storage_class == tree::VariableStorageClass.AUTO);
		assert(!legacy_node.variable.initializer.is_null(), "the initializer should be retained");
		assert(d.messages.len() == 0, "valid C17 auto storage class should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: missing inferred initializers are diagnosed and parsing
// resumes at the following complete declaration.
fn void source_derived_auto_type_missing_initializer_recovers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("auto_type_recovery.c",
			"__auto_type missing; int good = 7;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() > 0, "an inferred declaration without an initializer should be diagnosed");
		bool found_good = false;
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind != tree::NodeKind.VARIABLE || result.tok_slice(node.variable.name_tok) != "good") continue;
			found_good = true;
			assert(node.variable.qt.eql(type_store::INT, &comp));
			assert(!node.variable.initializer.is_null());
		}
		assert(found_good, "recovery should preserve the declaration following missing auto initializer");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an invalid pointer declarator cannot infer its declared
// type from a valid initializer, and parsing continues with the next variable.
fn void source_derived_auto_type_rejected_pointer_keeps_invalid_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("invalid_auto_pointer.c",
			"__auto_type *rejected = 1; int good = 3;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() > 0, "a pointer declarator with inferred auto should be diagnosed");
		assert(result.root_decls.len() == 2, "parsing should retain both declarations");
		tree::Node rejected = result.root_decls[0].get(&result);
		assert(rejected.kind == tree::NodeKind.VARIABLE);
		assert(result.tok_slice(rejected.variable.name_tok) == "rejected");
		assert(rejected.variable.qt.is_invalid(), "the rejected declarator type should remain invalid");
		assert(!rejected.variable.initializer.is_null(), "the valid initializer should remain in the AST");
		tree::Node initializer = rejected.variable.initializer.unwrap().get(&result);
		assert(initializer.kind == tree::NodeKind.INT_LITERAL);
		assert(initializer.literal.qt.eql(type_store::INT, &comp));

		tree::Node good = result.root_decls[1].get(&result);
		assert(good.kind == tree::NodeKind.VARIABLE);
		assert(result.tok_slice(good.variable.name_tok) == "good");
		assert(good.variable.qt.eql(type_store::INT, &comp));

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: GNU inferred declarations reject multiple declarators and
// retain the following valid declaration. Local self-reference is tested below.
fn void source_derived_gnu_auto_type_invalid_forms_are_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("invalid_auto_type.c",
			"__auto_type first = 1, second = first; int good = 3;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() > 0, "invalid __auto_type declarators should be diagnosed");
		bool found_good = false;
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind != tree::NodeKind.VARIABLE || result.tok_slice(node.variable.name_tok) != "good") continue;
			found_good = true;
			assert(node.variable.qt.eql(type_store::INT, &comp));
		}
		assert(found_good, "recovery should preserve a declaration after invalid auto forms");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: local declarations using __auto_type and C23 auto diagnose
// self-initialization and preserve the valid declaration that follows.
fn void source_derived_local_deduced_type_self_initialization_is_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("auto_type_self_init.c",
			"void foo(void) { int x; __auto_type x = x; __auto_type y = (y); auto z = z + 1; int good = 3; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 3, "each local deduced-type self-initializer should produce one diagnostic");
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "variable 'x' declared with deduced type '__auto_type' cannot appear in its own initializer");
		assert(d.messages[1].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[1].text == "variable 'y' declared with deduced type '__auto_type' cannot appear in its own initializer");
		assert(d.messages[2].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[2].text == "variable 'z' declared with deduced type '__auto_type' cannot appear in its own initializer");

		assert(result.root_decls.len() == 1);
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		assert(!function_node.function.body.is_null());
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		assert(body_node.kind == tree::NodeKind.COMPOUND_STMT);
		bool found_good = false;
		foreach (statement : body_node.compound_stmt.body)
		{
			tree::Node statement_node = statement.get(&result);
			if (statement_node.kind != tree::NodeKind.DECL_STMT) continue;
			foreach (decl : statement_node.decl_stmt.decls)
			{
				tree::Node node = decl.get(&result);
				if (node.kind != tree::NodeKind.VARIABLE || result.tok_slice(node.variable.name_tok) != "good") continue;
				found_good = true;
				assert(node.variable.qt.eql(type_store::INT, &comp));
				assert(!node.variable.initializer.is_null(), "the following valid declaration should retain its initializer");
			}
		}
		assert(found_good, "parsing should retain the valid declaration after the self-initializers");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: the production frontend routes compound literals through
// the inferred initializer parser, where a nested self-reference is diagnosed
// and parsing resumes at the following local declaration.
fn void source_derived_compound_literal_deduced_type_self_initialization_recovers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("auto_type_compound_self_init.c",
			"void foo(void) { __auto_type y = (int []){1, y}; int good = 3; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p;
		p.init(&pp);
		parser_declaration::DeclarationParser frontend;
		frontend.bind(&p);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 1, "the nested self-reference should produce one diagnostic");
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "variable 'y' declared with deduced type '__auto_type' cannot appear in its own initializer");
		sz first_user = first_user_root(&result);
		assert(result.root_decls.len() - first_user == 1, "the function should be retained");
		tree::Node function_node = result.root_decls[first_user].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		assert(body_node.kind == tree::NodeKind.COMPOUND_STMT);
		bool found_good = false;
		foreach (statement : body_node.compound_stmt.body)
		{
			tree::Node statement_node = statement.get(&result);
			if (statement_node.kind != tree::NodeKind.DECL_STMT) continue;
			foreach (decl : statement_node.decl_stmt.decls)
			{
				tree::Node node = decl.get(&result);
				if (node.kind != tree::NodeKind.VARIABLE || result.tok_slice(node.variable.name_tok) != "good") continue;
				found_good = true;
				assert(node.variable.qt.eql(type_store::INT, &comp));
				assert(!node.variable.initializer.is_null(), "the following declaration should retain its initializer");
			}
		}
		assert(found_good, "recovery should preserve the declaration after the nested self-initializer");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: Parser.parse recovers to the declaration boundary after a
// malformed initializer, then continues dispatching the next top-level item.
fn void source_derived_default_declaration_callbacks_recover_to_next_declaration() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("declaration_recovery.c",
			"int broken = ; int good = 2;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() > 0, "the malformed initializer should be diagnosed");
		bool found_good = false;
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind != tree::NodeKind.VARIABLE || result.tok_slice(node.variable.name_tok) != "good") continue;
			found_good = true;
			assert(!node.variable.initializer.is_null(), "the valid declaration should be fully parsed");
		}
		assert(found_good, "recovery should leave the following valid declaration in the AST");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an invalid deduced type in a prototype is diagnosed without
// stopping parsing of its initializer use or a later declaration.
fn void source_derived_invalid_auto_type_prototype_recovers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("invalid_auto_prototype_recovery.c",
			"void invalid_func(__auto_type); int invalid_int = invalid_func; int good = 7;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		bool found_invalid_prototype = false;
		foreach (message : d.messages)
		{
			if (message.kind == diagnostics::MessageKind.ERROR &&
				message.text == "'__auto_type' not allowed in function prototype")
			{
				found_invalid_prototype = true;
			}
		}
		assert(found_invalid_prototype, "the invalid prototype parameter should be diagnosed");
		assert(d.messages.len() == 1, "invalid-type initializer recovery should not add diagnostics");

		bool found_invalid_int = false;
		bool found_good = false;
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind != tree::NodeKind.VARIABLE) continue;
			String name = result.tok_slice(node.variable.name_tok);
			if (name == "invalid_int")
			{
				found_invalid_int = true;
				assert(!node.variable.initializer.is_null(),
					"the initializer referencing the invalid prototype should be retained");
			}
			else if (name == "good")
			{
				found_good = true;
				assert(!node.variable.initializer.is_null(), "the later valid initializer should be retained");
			}
		}
		assert(found_invalid_int, "the declaration initialized from the invalid prototype should be retained");
		assert(found_good, "recovery should preserve the later valid declaration");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a file-scope initializer whose __builtin_offsetof fails does not
// bind its name, so the repeated declaration is not a redefinition.
fn void source_derived_failed_file_scope_initializers_do_not_redefine() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		type_store::init_named_types(&comp);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("failed_offsetof_redefinition.c",
			"struct Incomplete; struct Complete { int a; }; int b = __builtin_offsetof(struct Incomplete, x); int b = __builtin_offsetof(struct Complete, missing);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p;
		p.init(&pp);
		parser_declaration::DeclarationParser frontend;
		frontend.bind(&p);
		tree::Tree result = p.parse()!!;

		bool found_incomplete = false;
		bool found_missing_member = false;
		bool found_redefinition = false;
		for (sz i = 0; i < d.messages.len(); i++)
		{
			if (d.messages[i].text.contains("offsetof of incomplete type")) found_incomplete = true;
			if (d.messages[i].text.contains("no member named 'missing'")) found_missing_member = true;
			if (d.messages[i].text.contains("redefinition of 'b'")) found_redefinition = true;
		}
		assert(found_incomplete, "the incomplete struct offsetof should be diagnosed");
		assert(found_missing_member, "the missing member offsetof should be diagnosed");
		assert(!found_redefinition, "a failed offsetof initializer should not leave b defined for the next declaration");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an extern file-scope variable with an initializer emits
// EXTERN_INITIALIZER exactly once.
fn void source_derived_extern_initializer_emits_one_diagnostic() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		d.set("extern-initializer", diagnostics::MessageKind.WARNING)!!;
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("extern_initializer.c", "extern int x = 1;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		sz extern_count = 0;
		for (sz i = 0; i < d.messages.len(); i++)
		{
			if (d.messages[i].text == "extern variable has initializer") extern_count++;
		}
		assert(extern_count == 1, "extern initializer should emit exactly one EXTERN_INITIALIZER diagnostic, got %d", extern_count);

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a file-scope initializer sees the name it declares, so
// sizeof(x) in `int x = sizeof(x);` resolves x without a diagnostic.
fn void source_derived_initializer_sees_its_own_declaration() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		type_store::init_named_types(&comp);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("self_initializer.c", "int x = sizeof(x);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "sizeof of the declared name should resolve without a diagnostic");
		assert(result.root_decls.len() == 1);
		tree::Node node = result.root_decls[0].get(&result);
		assert(node.kind == tree::NodeKind.VARIABLE);
		assert(node.variable.qt.eql(type_store::INT, &comp));
		assert(!node.variable.initializer.is_null(), "the initializer should be retained");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a successful file-scope definition still makes a later
// definition of the same name a redefinition.
fn void source_derived_successful_file_scope_definition_still_redefines() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("successful_redefinition.c", "int y = 1; int y = 2;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() > 0, "the second definition should be diagnosed");
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "redefinition of 'y'", "a successful definition should still be redefined by a later one");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: declaration specifiers retain storage and type qualifiers,
// while named parameter declarators compose pointer, array, and function
// forms with the precedence expressed by their parentheses.
fn void source_derived_declaration_specifiers_and_named_parameter_declarators() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("declarator_forms.c",
			"static const volatile int * restrict shared; int dispatch(register int (*matrix)[3], int (*callback)(const int *arg));")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2, "the source should produce one object and one function declaration");
		tree::Node shared_node = result.root_decls[0].get(&result);
		tree::Node dispatch_node = result.root_decls[1].get(&result);
		assert(shared_node.kind == tree::NodeKind.VARIABLE);
		assert(shared_node.variable.storage_class == tree::VariableStorageClass.STATIC,
			"static storage class should survive declaration specifier parsing");
		assert(shared_node.variable.qt.is_restrict, "restrict after '*' qualifies the pointer declarator");
		type_store::Type shared_pointer = shared_node.variable.qt.get(&comp, type_store::TypeTag.POINTER)!!;
		assert(shared_pointer.pointer.child.is_const && shared_pointer.pointer.child.is_volatile,
			"const and volatile declaration specifiers should qualify the pointed-to type");

		assert(dispatch_node.kind == tree::NodeKind.FUNCTION);
		type_store::Func dispatch_type = dispatch_node.function.qt.get_func(&comp)!!;
		assert(dispatch_type.params.len == 2, "both named parameters should be retained");
		tree::Node matrix_node = dispatch_type.params[0].node.unwrap().get(&result);
		tree::Node callback_node = dispatch_type.params[1].node.unwrap().get(&result);
		assert(matrix_node.kind == tree::NodeKind.PARAM && result.tok_slice(matrix_node.param.name_tok) == "matrix");
		assert(matrix_node.param.storage_class == tree::ParamStorageClass.REGISTER,
			"register storage class should survive parameter declaration parsing");
		assert(callback_node.kind == tree::NodeKind.PARAM && result.tok_slice(callback_node.param.name_tok) == "callback");

		type_store::Type matrix_pointer = dispatch_type.params[0].qt.get(&comp, type_store::TypeTag.POINTER)!!;
		type_store::Type matrix_array = matrix_pointer.pointer.child.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(matrix_array.array.len.kind == type_store::ArrayLenKind.FIXED && matrix_array.array.len.len == 3,
			"(*matrix)[3] should parse as a pointer to a three-element array");

		type_store::Type callback_pointer = dispatch_type.params[1].qt.get(&comp, type_store::TypeTag.POINTER)!!;
		type_store::Func callback_type = callback_pointer.pointer.child.get_func(&comp)!!;
		assert(callback_type.return_type.eql(type_store::INT, &comp));
		assert(callback_type.params.len == 1);
		type_store::Type callback_arg_pointer = callback_type.params[0].qt.get(&comp, type_store::TypeTag.POINTER)!!;
		assert(callback_arg_pointer.pointer.child.is_const,
			"the named function parameter's const-qualified pointer argument should be retained");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: K&R identifier-list definitions rebuild their function
// type from the declarations that follow the parameter list.
fn void source_derived_knr_definition_rebuilds_normal_function_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C89;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("knr_definition.c",
			"void blend(first, second) long first; unsigned short second; { }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.kind == type_store::FuncKind.NORMAL,
			"the identifier-list definition should rebuild to a normal function type");
		assert(function_type.params.len == 2);
		assert(function_type.params[0].name == comp.intern_string("first"));
		assert(function_type.params[0].qt.eql(type_store::LONG, &comp));
		assert(function_type.params[1].name == comp.intern_string("second"));
		assert(function_type.params[1].qt.eql(type_store::USHORT, &comp));
		assert(d.messages.len() == 1, "a K&R definition should only add the deprecated-definition warning");
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[0].text ==
			"a function definition without a prototype is deprecated in all versions of C and is not supported in C23");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a static minimum bound in a K&R parameter declaration is
// parsed as an array bound and remains available after parameter decay.
fn void source_derived_knr_static_array_parameter_retains_bound() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C99;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("knr_static_array_parameter.c",
			"void static_array_parameter(x) int x[static 5]; { }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 1);
		type_store::Type pointer_type = function_type.params[0].qt.get(&comp, type_store::TypeTag.POINTER)!!;
		assert(pointer_type.pointer.has_decayed,
			"an array parameter should retain its source array type when it decays");
		type_store::Type array_type = pointer_type.pointer.decayed.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(array_type.array.len.kind == type_store::ArrayLenKind.STATIC && array_type.array.len.len == 5,
			"the static minimum bound should survive parameter decay");
		assert(d.messages.len() == 1 && d.messages[0].text ==
			"a function definition without a prototype is deprecated in all versions of C and is not supported in C23");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an identifier-list parameter with no declaration defaults
// to int and reports DIAG_PARAM_NOT_DECLARED in C99 and later.
fn void source_derived_knr_definition_diagnoses_undeclared_parameter() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C99;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("knr_undeclared_parameter.c",
			"void partial(kept, omitted) long kept; { }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2,
			"a K&R definition should report deprecation and the undeclared parameter");
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[1].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[1].text ==
			"parameter 'omitted' was not declared, defaults to 'int'; ISO C99 and later do not support implicit int");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an empty old-style parameter list has no K&R identifier
// list to declare and remains compatible with an earlier `(void)` prototype.
fn void source_derived_empty_old_style_definition_preserves_compatibility() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C17;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("empty_old_style_definition.c",
			"void f(void); void f() { }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0,
			"an empty old-style definition should not run K&R declaration-list diagnostics");
		bool found_definition = false;
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind != tree::NodeKind.FUNCTION || result.tok_slice(node.function.name_tok) != "f") continue;
			if (node.function.body.is_null()) continue;
			found_definition = true;
			type_store::Func function_type = node.function.qt.get_func(&comp)!!;
			assert(function_type.kind == type_store::FuncKind.OLD_STYLE,
				"an empty old-style definition should retain its zero-parameter function type");
			assert(function_type.params.len == 0);
		}
		assert(found_definition, "the empty old-style definition should be parsed");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: C23 reports an identifier in a parameter declaration as
// an unknown type name, but retains the spelling as the recovered parameter
// name so a function definition does not look like it omitted that name.
fn void source_derived_c23_unknown_parameter_keeps_its_identifier() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("c23_kr_parameter.c", "void invalid(param) { }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(has_diagnostic_fragment(&d, "unknown type name 'param'"),
			"a C23 K&R identifier should retain the unknown-type-name diagnostic");
		assert(!has_diagnostic_fragment(&d, "omitting the parameter name"),
			"a recovered K&R identifier is not an omitted parameter name");
		assert(result.root_decls.len() == 1);
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(!function_node.function.body.is_null(), "the function body should be parsed for recovery");
		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 1);
		assert(function_type.params[0].name == comp.intern_string("param"));
		assert(function_type.params[0].qt.eql(type_store::INT, &comp));

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: under C23 an identifier-list spelling is diagnosed as an
// unknown parameter type, and following K&R declarations remain file-scope
// declarations. The orphaned compound body is diagnosed once and skipped so
// the next function is still parsed.
fn void source_derived_c23_knr_declaration_list_recovers_to_next_function() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("c23_kr_recovery.c",
			"int foo(a, int b, char c, d)\nint a; short d;\n{\nreturn a;\n}\nint baz(void) { return 0; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		uint expected_body_count = 0;
		uint expected_external_count = 0;
		bool found_baz = false;
		foreach (msg : d.messages)
		{
			if (msg.text.contains("expected function body after function declaration"))
			{
				expected_body_count++;
				assert(msg.has_location && msg.location.line_no == 1 && msg.location.col == 28,
					"the missing-body diagnostic should point at the closing parenthesis");
			}
			if (msg.text.contains("expected external declaration"))
			{
				expected_external_count++;
				assert(msg.has_location && msg.location.line_no == 3 && msg.location.col == 1,
					"the orphaned compound body should be diagnosed at its opening brace");
			}
		}
		assert(expected_body_count == 1, "the malformed C23 K&R declarator should have one missing-body diagnostic");
		assert(expected_external_count == 1, "the orphaned body should produce one external-declaration diagnostic");
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind == tree::NodeKind.FUNCTION && result.tok_slice(node.function.name_tok) == "baz")
			{
				found_baz = true;
				assert(!node.function.body.is_null(), "recovery should parse baz's body");
			}
		}
		assert(found_baz, "recovery should continue at the following function definition");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a K&R declaration not present in the identifier list is
// diagnosed, but remains bound for references in the recovered function body.
fn void source_derived_knr_missing_list_parameter_remains_visible_in_body() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C99;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("knr_extra_parameter.c",
			"void partial(kept) int kept; int extra; { (void)extra; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(has_diagnostic_fragment(&d, "parameter named 'extra' is missing"),
			"a declaration absent from the identifier list should be diagnosed");
		assert(!has_diagnostic_fragment(&d, "use of undeclared identifier 'extra'"),
			"the extra declaration should remain bound inside the function body");
		assert(result.root_decls.len() == 1);
		tree::Node function_node = result.root_decls[0].get(&result);
		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 1,
			"an extra declaration should not be appended to the function type");
		assert(function_type.params[0].name == comp.intern_string("kept"));

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: declaration specifiers map tokenizer spellings supported by
// TypeStore.Builder to their completed QualTypes, including composable types.
fn void source_derived_extended_type_specifiers_build_qualified_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("extended_types.c",
			"bool flag; nullptr null_pointer; __fp16 fp16_value; __bf16 bf16_value; " +++
			"_Decimal32 decimal32_value; _Decimal64 decimal64_value; " +++
			"_Decimal128 decimal128_value; _Decimal64x decimal64x_value; " +++
			"_Complex _Float32 complex_float32_value;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		type_store::QualType[*] expected = {
			type_store::BOOL,
			type_store::NULLPTR_T,
			type_store::FP16,
			type_store::BF16,
			type_store::DFLOAT32,
			type_store::DFLOAT64,
			type_store::DFLOAT128,
			type_store::DFLOAT64X,
			type_store::FLOAT32.to_complex(&comp),
		};
		assert(result.root_decls.len() == expected.len,
			"every supported extended type spelling should produce a declaration");
		foreach (i, expected_qt : expected)
		{
			tree::Node declaration = result.root_decls[i].get(&result);
			assert(declaration.kind == tree::NodeKind.VARIABLE,
				"each specifier should build a variable declaration");
			assert(declaration.variable.qt.eql(expected_qt, &comp),
				"the mapped specifier combination should produce its TypeStore QualType");
		}

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: both MSVC spellings for each fixed-width integer keyword
// build the corresponding declaration type through TypeStore.Builder.
fn void source_derived_msvc_fixed_width_integer_specifiers_build_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.set_emulated_compiler(lang_opts::Compiler.MSVC);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("msvc_fixed_types.c",
			"__int8 signed_char_width; _int8 underscored_char_width; " +++
			"__int16 short_width; _int16 underscored_short_width; " +++
			"__int32 int_width; _int32 underscored_int_width; " +++
			"__int64 long_long_width; _int64 underscored_long_long_width;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		type_store::QualType[*] expected = {
			type_store::CHAR, type_store::CHAR,
			type_store::SHORT, type_store::SHORT,
			type_store::INT, type_store::INT,
			type_store::LONG_LONG, type_store::LONG_LONG,
		};
		assert(result.root_decls.len() == expected.len,
			"both spellings for each MSVC fixed-width integer should parse as declarations");
		foreach (i, expected_qt : expected)
		{
			tree::Node declaration = result.root_decls[i].get(&result);
			assert(declaration.kind == tree::NodeKind.VARIABLE,
				"each fixed-width integer specifier should build a variable declaration");
			assert(declaration.variable.qt.eql(expected_qt, &comp),
				"the fixed-width integer spelling should resolve to its Builder type");
		}

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a file-scope tentative array with no bound is completed to
// one element when the translation unit ends, and is its own definition.
fn void source_derived_tentative_incomplete_array_completes_at_translation_unit_end() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("tentative_array.c", "int items[];")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		type_store::NodeIndex items_index = result.root_decls[0];
		tree::Node items = items_index.get(&result);
		assert(items.kind == tree::NodeKind.VARIABLE);
		type_store::Type items_type = items.variable.qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(items_type.array.len.kind == type_store::ArrayLenKind.FIXED && items_type.array.len.len == 1,
			"an incomplete tentative array should have a one-element bound at translation-unit end");
		assert(!items.variable.definition.is_null() && items.variable.definition.unwrap() == items_index,
			"the completed tentative array should link to its own definition");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an extern-only incomplete array is a declaration, so it
// remains unbounded and has no definition after parsing the translation unit.
fn void source_derived_extern_only_incomplete_array_stays_incomplete() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("extern_incomplete_array.c", "extern int items[];")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node items = result.root_decls[0].get(&result);
		assert(items.kind == tree::NodeKind.VARIABLE);
		type_store::Type items_type = items.variable.qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(items_type.array.len.kind == type_store::ArrayLenKind.INCOMPLETE,
			"an extern-only array declaration should retain its incomplete bound");
		assert(items.variable.definition.is_null(), "an extern-only declaration should have no definition link");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: earlier file-scope declarations in a tentative-definition
// chain all point to the final initialized definition.
fn void source_derived_array_redeclarations_link_to_final_definition() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("array_redeclarations.c",
			"extern int items[]; int items[]; int items[3] = {1, 2, 3};")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 3);
		type_store::NodeIndex final_definition = result.root_decls[2];
		tree::Node final_node = final_definition.get(&result);
		assert(final_node.kind == tree::NodeKind.VARIABLE);
		assert(!final_node.variable.initializer.is_null());
		type_store::Type final_type = final_node.variable.qt.get(&comp, type_store::TypeTag.ARRAY)!!;
		assert(final_type.array.len.kind == type_store::ArrayLenKind.FIXED && final_type.array.len.len == 3,
			"the final initialized definition should retain its three-element bound");
		for (usz i = 0; i < 2; i++)
		{
			type_store::NodeIndex declaration_index = result.root_decls[(sz)i];
			tree::Node declaration = declaration_index.get(&result);
			assert(declaration.kind == tree::NodeKind.VARIABLE);
			assert(!declaration.variable.definition.is_null() &&
				declaration.variable.definition.unwrap() == final_definition,
				"each redeclaration should link directly to the final definition");
		}

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: diagnostics with format substitutions carry their complete
// message through the parser's already-formatted diagnostic API.
fn void source_derived_auto_function_return_diagnostic_keeps_context() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("auto_return_type.c",
			"__auto_type foo(void); auto bar(void); int good = 1;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2);
		assert(d.messages[0].text == "'__auto_type' not allowed in function return type");
		assert(d.messages[1].text == "'auto' not allowed in function return type");
		assert(result.root_decls.len() == 3, "the following valid declaration should be retained");
		tree::Node good = result.root_decls[2].get(&result);
		assert(good.kind == tree::NodeKind.VARIABLE);
		assert(result.tok_slice(good.variable.name_tok) == "good");
		assert(good.variable.qt.eql(type_store::INT, &comp));

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: fixed enum definitions retain their underlying type on both
// the enum tag and each enumerator constant.
fn void source_derived_fixed_enum_definitions_keep_underlying_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_definitions.c",
			"enum E: int { A = 1, B }; enum U: unsigned char { X = 3 };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2);
		tree::Node e_decl = result.root_decls[0].get(&result);
		tree::Node u_decl = result.root_decls[1].get(&result);
		assert(e_decl.kind == tree::NodeKind.ENUM_DECL && u_decl.kind == tree::NodeKind.ENUM_DECL);
		type_store::Type e_type = e_decl.container_decl.container_qt.get_type(&comp);
		type_store::Type u_type = u_decl.container_decl.container_qt.get_type(&comp);
		assert(e_type.enum_ty.fixed && e_type.enum_ty.tag.eql(type_store::INT, &comp));
		assert(u_type.enum_ty.fixed && u_type.enum_ty.tag.eql(type_store::UCHAR, &comp));
		assert(e_decl.container_decl.fields.len == 2 && u_decl.container_decl.fields.len == 1);
		tree::Node a = e_decl.container_decl.fields[0].get(&result);
		tree::Node b = e_decl.container_decl.fields[1].get(&result);
		assert(a.enum_field.qt.eql(type_store::INT, &comp));
		assert(b.enum_field.qt.eql(type_store::INT, &comp));
		tree::Node x = u_decl.container_decl.fields[0].get(&result);
		assert(x.enum_field.qt.eql(type_store::UCHAR, &comp));
		for (sz i = 0; i < d.messages.len(); i++)
		{
			assert(d.messages[i].kind != diagnostics::MessageKind.ERROR);
		}

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a fixed forward declaration can be completed by a matching
// fixed definition without the nonfixed-enum forward-reference diagnostic.
fn void source_derived_fixed_enum_forward_declaration_matches_definition() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_forward.c",
			"enum F: int; enum F: int { A };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2);
		tree::Node definition = result.root_decls[1].get(&result);
		assert(definition.kind == tree::NodeKind.ENUM_DECL);
		type_store::Type enum_type = definition.container_decl.container_qt.get_type(&comp);
		assert(enum_type.enum_ty.fixed && enum_type.enum_ty.tag.eql(type_store::INT, &comp));
		for (sz i = 0; i < d.messages.len(); i++)
		{
			assert(d.messages[i].text != "ISO C forbids forward references to 'enum' types");
			assert(d.messages[i].kind != diagnostics::MessageKind.ERROR);
		}

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: adding a fixed underlying type after a nonfixed forward
// declaration diagnoses the redeclaration and points back to the first tag.
fn void source_derived_nonfixed_enum_then_fixed_forward_declaration_is_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_redeclaration.c",
			"enum G;\nenum G: int;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2);
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "enumeration previously declared with nonfixed underlying type");
		assert(d.messages[0].location.line_no == 2 && d.messages[0].location.col == 6);
		assert(d.messages[1].kind == diagnostics::MessageKind.NOTE);
		assert(d.messages[1].text == "previous definition is here");
		assert(d.messages[1].location.line_no == 1 && d.messages[1].location.col == 6);

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a nonfixed redeclaration after a fixed forward declaration
// reports both the offending tag and the earlier fixed declaration.
fn void source_derived_fixed_enum_then_nonfixed_forward_declaration_is_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_redeclaration.c",
			"enum H: int;\nenum H;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2);
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "enumeration previously declared with fixed underlying type");
		assert(d.messages[0].location.line_no == 2 && d.messages[0].location.col == 6);
		assert(d.messages[1].kind == diagnostics::MessageKind.NOTE);
		assert(d.messages[1].text == "previous definition is here");
		assert(d.messages[1].location.line_no == 1 && d.messages[1].location.col == 6);

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: conflicting fixed underlying types retain the exact types
// in the diagnostic and identify the second tag.
fn void source_derived_fixed_enum_mismatched_underlying_type_is_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_redeclaration.c",
			"enum K: char;\nenum K: int;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2);
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "enumeration redeclared with different underlying type 'int' (was 'char')");
		assert(d.messages[0].location.line_no == 2 && d.messages[0].location.col == 6);
		assert(d.messages[1].kind == diagnostics::MessageKind.NOTE);
		assert(d.messages[1].text == "previous definition is here");
		assert(d.messages[1].location.line_no == 1 && d.messages[1].location.col == 6);

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a typedef name for a struct is rejected as the underlying
// type, while parsing continues with the integer fallback and enumerator.
fn void source_derived_fixed_enum_nonintegral_underlying_type_uses_int_fallback() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_invalid_type.c",
			"typedef struct BackingStruct { int x; } BackingStruct;\n" +++
			"enum Bad1: BackingStruct { B1 };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 1);
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text ==
			"non-integral type 'BackingStruct' (aka 'struct BackingStruct') is an invalid underlying type");
		assert(d.messages[0].location.line_no == 2 && d.messages[0].location.col == 12);
		bool found_bad1 = false;
		type_store::NodeIndex bad1_decl_index;
		foreach (root_decl : result.root_decls)
		{
			tree::Node declaration = root_decl.get(&result);
			if (declaration.kind == tree::NodeKind.ENUM_DECL)
			{
				found_bad1 = true;
				bad1_decl_index = root_decl;
			}
		}
		assert(found_bad1, "the invalid underlying type should still leave a parsed enum definition");
		tree::Node enum_decl = bad1_decl_index.get(&result);
		assert(enum_decl.kind == tree::NodeKind.ENUM_DECL);
		type_store::Type enum_type = enum_decl.container_decl.container_qt.get_type(&comp);
		assert(enum_type.enum_ty.tag.eql(type_store::INT, &comp));
		assert(enum_decl.container_decl.fields.len == 1);
		type_store::NodeIndex b1_index = enum_decl.container_decl.fields[0];
		tree::Node b1 = b1_index.get(&result);
		assert(result.tok_slice(b1.enum_field.name_tok) == "B1");
		assert(b1.enum_field.qt.eql(type_store::INT, &comp));
		assert(result.value_of(b1_index)!!.to_i64(&comp)!! == 0);

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: fixed enum values that overflow an unsigned or signed
// underlying type are diagnosed at the enumerator that cannot be represented.
fn void source_derived_fixed_enum_unrepresentable_enumerators_are_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_overflow.c",
			"enum E3: unsigned char {\n A = 255,\n B,\n};\n" +++
			"enum E4: char {\n A = 256,\n};")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2);
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "enumerator value is not representable in the underlying type 'unsigned char'");
		assert(d.messages[0].location.line_no == 3 && d.messages[0].location.col == 2);
		assert(d.messages[1].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[1].text == "enumerator value is not representable in the underlying type 'char'");
		assert(d.messages[1].location.line_no == 6 && d.messages[1].location.col == 2);

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a large positive value widens a nonfixed enum tag according
// to Enumerator.getTypeSpecifier's positive-bit thresholds.
fn void source_derived_nonfixed_enum_tag_widens_for_large_value() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("wide_enum.c",
			"enum W { A = 4294967296LL, B };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node enum_decl = result.root_decls[0].get(&result);
		assert(enum_decl.kind == tree::NodeKind.ENUM_DECL);
		type_store::Type enum_type = enum_decl.container_decl.container_qt.get_type(&comp);
		// Zig getTypeSpecifier sees 33 positive bits: beyond int it chooses
		// unsigned long when that width suffices, then unsigned long long.
		ulong positive_bits = 33;
		type_store::QualType expected_tag;
		if (positive_bits <= type_store::INT.bit_sizeof(&comp))
		{
			expected_tag = type_store::UINT;
		}
		else if (positive_bits <= type_store::LONG.bit_sizeof(&comp))
		{
			expected_tag = type_store::ULONG;
		}
		else
		{
			expected_tag = type_store::ULONG_LONG;
		}
		assert(!enum_type.enum_ty.tag.eql(type_store::INT, &comp));
		assert(enum_type.enum_ty.tag.eql(expected_tag, &comp));

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: malformed fixed underlying-type syntax does not prevent a
// later valid file-scope declaration from being retained in the tree.
fn void source_derived_fixed_enum_malformed_underlying_type_recovers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fixed_enum_recovery.c",
			"enum R: * { A }; int after_recovery = 7;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		bool found_after_recovery = false;
		foreach (root_decl : result.root_decls)
		{
			tree::Node declaration = root_decl.get(&result);
			if (declaration.kind == tree::NodeKind.VARIABLE &&
				result.tok_slice(declaration.variable.name_tok) == "after_recovery")
			{
				found_after_recovery = true;
				assert(!declaration.variable.initializer.is_null());
			}
		}
		assert(found_after_recovery,
			"the valid declaration after a malformed enum underlying type should be retained");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Helpers for the _BitInt and typeof declaration-specifier tests below.
fn type_store::QualType bit_int_qt(compilation::Compilation* comp, ushort bits, lang_opts::Signedness s) =>
	comp.type_store.put(type_store::type_bit_int(bits, s));

fn type_store::QualType with_quals(type_store::QualType qt, bool want_const, bool want_volatile)
{
	qt.is_const = want_const;
	qt.is_volatile = want_volatile;
	return qt;
}

fn bool has_diagnostic_fragment(diagnostics::Diagnostics* d, String fragment)
{
	foreach (msg : d.messages)
	{
		if (msg.text.contains(fragment)) return true;
	}
	return false;
}

fn bool find_variable(tree::Tree* result, String name, tree::Node* out)
{
	foreach (decl : result.root_decls)
	{
		tree::Node node = decl.get(result);
		if (node.kind == tree::NodeKind.VARIABLE && result.tok_slice(node.variable.name_tok) == name)
		{
			*out = node;
			return true;
		}
	}
	return false;
}

fn void assert_variable_qt(tree::Tree* result, compilation::Compilation* comp, String name, type_store::QualType expected)
{
	tree::Node node;
	bool found = find_variable(result, name, &node);
	assert(found, "declaration '%s' should be retained in the AST", name);
	assert(node.variable.qt.eql_qualified(expected, comp), "declaration '%s' has the wrong qualified type", name);
}

// The declared object must be a top-level-unqualified pointer (except for
// `restrict`) whose pointee has type `child`, including its qualifiers.
fn void assert_pointer_variable(tree::Tree* result, compilation::Compilation* comp, String name,
	type_store::QualType child, bool want_restrict)
{
	tree::Node node;
	bool found = find_variable(result, name, &node);
	assert(found, "pointer declaration '%s' should be retained in the AST", name);
	assert(!node.variable.qt.is_const && !node.variable.qt.is_volatile && node.variable.qt.is_restrict == want_restrict,
		"pointer declaration '%s' has the wrong top-level qualifiers", name);
	type_store::Type ptr_type = node.variable.qt.get(comp, type_store::TypeTag.POINTER)!!;
	assert(ptr_type.pointer.child.eql_qualified(child, comp), "pointer declaration '%s' has the wrong pointee type", name);
}

// source-derived: _BitInt(N) and unsigned _BitInt(N) accept the TypeBuilder
// width range (signed 2..65535, unsigned 1..65535) and constant-expression
// widths; signed/unsigned may appear before or after the _BitInt keyword.
fn void source_derived_bit_int_widths_build_signed_and_unsigned_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("bit_int_widths.c",
			"_BitInt(2) default_min; signed _BitInt(8) explicit_signed; _BitInt(9) signed signed_after_width; " +++
			"unsigned _BitInt(1) unsigned_min; _BitInt(16) unsigned unsigned_after_width; " +++
			"unsigned _BitInt(65535) unsigned_max; _BitInt(65535) signed_max; _BitInt(4 * 2) expression_width;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "valid _BitInt width spellings should not add diagnostics");
		assert(result.root_decls.len() == 8, "every _BitInt width spelling should produce a declaration");
		assert_variable_qt(&result, &comp, "default_min", bit_int_qt(&comp, 2, lang_opts::Signedness.SIGNED));
		assert_variable_qt(&result, &comp, "explicit_signed", bit_int_qt(&comp, 8, lang_opts::Signedness.SIGNED));
		assert_variable_qt(&result, &comp, "signed_after_width", bit_int_qt(&comp, 9, lang_opts::Signedness.SIGNED));
		assert_variable_qt(&result, &comp, "unsigned_min", bit_int_qt(&comp, 1, lang_opts::Signedness.UNSIGNED));
		assert_variable_qt(&result, &comp, "unsigned_after_width", bit_int_qt(&comp, 16, lang_opts::Signedness.UNSIGNED));
		assert_variable_qt(&result, &comp, "unsigned_max", bit_int_qt(&comp, 65535, lang_opts::Signedness.UNSIGNED));
		assert_variable_qt(&result, &comp, "signed_max", bit_int_qt(&comp, 65535, lang_opts::Signedness.SIGNED));
		assert_variable_qt(&result, &comp, "expression_width", bit_int_qt(&comp, 8, lang_opts::Signedness.SIGNED));

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: _BitInt declarators combine const/volatile specifiers in any
// position, and restrict on a declarator qualifies only that pointer.
fn void source_derived_bit_int_qualifier_combinations_build_qualified_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("bit_int_qualifiers.c",
			"const _BitInt(8) const_signed; volatile unsigned _BitInt(9) volatile_unsigned; " +++
			"const volatile _BitInt(10) cv_signed; unsigned _BitInt(11) const volatile cv_unsigned; " +++
			"unsigned _BitInt(12) *restrict bit_pointer;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "valid qualified _BitInt declarations should not add diagnostics");
		assert(result.root_decls.len() == 5, "every qualified _BitInt declaration should produce a declaration");
		assert_variable_qt(&result, &comp, "const_signed",
			with_quals(bit_int_qt(&comp, 8, lang_opts::Signedness.SIGNED), true, false));
		assert_variable_qt(&result, &comp, "volatile_unsigned",
			with_quals(bit_int_qt(&comp, 9, lang_opts::Signedness.UNSIGNED), false, true));
		assert_variable_qt(&result, &comp, "cv_signed",
			with_quals(bit_int_qt(&comp, 10, lang_opts::Signedness.SIGNED), true, true));
		assert_variable_qt(&result, &comp, "cv_unsigned",
			with_quals(bit_int_qt(&comp, 11, lang_opts::Signedness.UNSIGNED), true, true));
		assert_pointer_variable(&result, &comp, "bit_pointer",
			bit_int_qt(&comp, 12, lang_opts::Signedness.UNSIGNED), true);

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: typeof(type-name) adopts the operand type, including its
// qualifiers, and a leading qualifier on the specifier list is applied on top.
fn void source_derived_typeof_type_name_operands_build_types() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("typeof_type_names.c",
			"typeof(int) plain_int; typeof(const int) const_int; const typeof(int) const_outer; " +++
			"typeof(unsigned _BitInt(8)) typed_width; typeof(long double) long_double_value; " +++
			"typeof(int *) pointer_value; typeof(unsigned _BitInt(12)) *bit_pointer;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "valid typeof type-name declarations should not add diagnostics");
		assert(result.root_decls.len() == 7, "every typeof type-name declaration should produce a declaration");
		assert_variable_qt(&result, &comp, "plain_int", type_store::INT);
		assert_variable_qt(&result, &comp, "const_int", with_quals(type_store::INT, true, false));
		assert_variable_qt(&result, &comp, "const_outer", with_quals(type_store::INT, true, false));
		assert_variable_qt(&result, &comp, "typed_width", bit_int_qt(&comp, 8, lang_opts::Signedness.UNSIGNED));
		assert_variable_qt(&result, &comp, "long_double_value", type_store::LONG_DOUBLE);
		assert_pointer_variable(&result, &comp, "pointer_value", type_store::INT, false);
		assert_pointer_variable(&result, &comp, "bit_pointer",
			bit_int_qt(&comp, 12, lang_opts::Signedness.UNSIGNED), false);

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: typeof(expression) takes the expression's type and keeps
// its qualifiers (C23 6.7.3.6), while typeof with a literal or cast operand
// yields that operand's type.
fn void source_derived_typeof_expression_operands_use_expression_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("typeof_expressions.c",
			"const long source_long = 3; int base = 1; " +++
			"typeof(base) copy_base; typeof(source_long) copy_long; typeof(1L) literal_long; " +++
			"typeof((unsigned char)1) cast_uchar; const typeof(base) const_copy;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "valid typeof expression declarations should not add diagnostics");
		assert(result.root_decls.len() == 7, "every typeof expression declaration should produce a declaration");
		assert_variable_qt(&result, &comp, "copy_base", type_store::INT);
		assert_variable_qt(&result, &comp, "copy_long", with_quals(type_store::LONG, true, false));
		assert_variable_qt(&result, &comp, "literal_long", type_store::LONG);
		assert_variable_qt(&result, &comp, "cast_uchar", type_store::UCHAR);
		assert_variable_qt(&result, &comp, "const_copy", with_quals(type_store::INT, true, false));

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: typeof_unqual removes top-level qualifiers only; qualifiers
// on the pointee survive, and a later const on the specifier list is re-applied.
fn void source_derived_typeof_unqual_drops_top_level_qualifiers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("typeof_unqual_quals.c",
			"const volatile int source_cv = 1; typeof_unqual(source_cv) plain_copy; " +++
			"typeof_unqual(const volatile int) plain_type; const typeof_unqual(source_cv) const_copy; " +++
			"typeof_unqual(const int *) pointer_copy; typeof_unqual(typeof(const int)) nested_type;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "valid typeof_unqual declarations should not add diagnostics");
		assert(result.root_decls.len() == 6, "every typeof_unqual declaration should produce a declaration");
		assert_variable_qt(&result, &comp, "plain_copy", type_store::INT);
		assert_variable_qt(&result, &comp, "plain_type", type_store::INT);
		assert_variable_qt(&result, &comp, "const_copy", with_quals(type_store::INT, true, false));
		assert_pointer_variable(&result, &comp, "pointer_copy", with_quals(type_store::INT, true, false), false);
		assert_variable_qt(&result, &comp, "nested_type", type_store::INT);

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: symbols created by typeof_unqual(name) carry the same
// QualType as their AST declaration, and the source symbol keeps its qualifiers.
fn void source_derived_typeof_unqual_symbol_matches_declaration_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("typeof_unqual_symbol.c",
			"const unsigned _BitInt(12) width_source = 1; typeof_unqual(width_source) width_copy = 2;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		InferredTypeCapture capture = {
			.first_name = comp.intern_string("width_source"),
			.second_name = comp.intern_string("width_copy"),
		};
		capture.declarations.test_probe = &capture;
		parser::Parser p;
		p.init(&pp, &capture.declarations);
		tree::Tree result = p.parse()!!;

		assert(capture.declaration_count == 2);
		assert(result.root_decls.len() == 2);
		assert(capture.first_node == result.root_decls[0] && capture.second_node == result.root_decls[1],
			"each symbol should refer to its own declaration node");
		type_store::QualType source_qt = with_quals(bit_int_qt(&comp, 12, lang_opts::Signedness.UNSIGNED), true, false);
		type_store::QualType copy_qt = bit_int_qt(&comp, 12, lang_opts::Signedness.UNSIGNED);
		tree::Node copy_node = result.root_decls[1].get(&result);
		assert(capture.first_qt.eql_qualified(source_qt, &comp), "the source symbol should keep its const qualifier");
		assert(capture.second_qt.eql_qualified(copy_qt, &comp), "typeof_unqual should drop the const qualifier in the symbol");
		assert(copy_node.variable.qt.eql_qualified(capture.second_qt, &comp),
			"the typeof_unqual symbol should match its AST declaration");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an out-of-range _BitInt width is diagnosed at the _BitInt
// keyword (TypeBuilder.finish). The declarator keeps an invalid type and the
// following declarations are retained.
fn void source_derived_bit_int_width_range_errors_keep_following_declarations() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("bit_int_width_range.c",
			"_BitInt(1) one_bit; int after_one = 1; " +++
			"unsigned _BitInt(0) zero_unsigned; int after_zero = 2; " +++
			"_BitInt(65536) too_wide; int after_wide = 3;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(has_diagnostic_fragment(&d, "signed _BitInt must have a bit size of at least 2"),
			"a signed _BitInt width of 1 should be diagnosed");
		assert(has_diagnostic_fragment(&d, "unsigned _BitInt must have a bit size of at least 1"),
			"an unsigned _BitInt width of 0 should be diagnosed");
		assert(has_diagnostic_fragment(&d, "greater than 65535 not supported"),
			"a _BitInt width above 65535 should be diagnosed");
		assert(d.messages[0].has_location && d.messages[0].location.line_no == 1 && d.messages[0].location.col == 1,
			"the first width diagnostic should be located at the _BitInt keyword");

		tree::Node one_bit;
		tree::Node zero_unsigned;
		tree::Node too_wide;
		bool found_one = find_variable(&result, "one_bit", &one_bit);
		bool found_zero = find_variable(&result, "zero_unsigned", &zero_unsigned);
		bool found_wide = find_variable(&result, "too_wide", &too_wide);
		assert(found_one && one_bit.variable.qt.is_invalid(),
			"an out-of-range signed _BitInt declarator should keep an invalid type");
		assert(found_zero && zero_unsigned.variable.qt.is_invalid(),
			"an out-of-range unsigned _BitInt declarator should keep an invalid type");
		assert(found_wide && too_wide.variable.qt.is_invalid(),
			"an oversized _BitInt declarator should keep an invalid type");
		assert_variable_qt(&result, &comp, "after_one", type_store::INT);
		assert_variable_qt(&result, &comp, "after_zero", type_store::INT);
		assert_variable_qt(&result, &comp, "after_wide", type_store::INT);

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: malformed _BitInt widths and typeof operands (empty or
// incomplete operands, a non-constant width, a missing closing parenthesis,
// and a typeof combined with another specifier) fail their own declaration
// and leave the following valid declaration in the AST.
fn void source_derived_bit_int_and_typeof_malformed_operands_recover() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("bit_int_typeof_recovery.c",
			"int runtime_width = 8; _BitInt() empty_width; int after_empty = 1; " +++
			"_BitInt(runtime_width) runtime_width_decl; int after_runtime = 2; " +++
			"_BitInt(8 unclosed_width; int after_unclosed = 3; " +++
			"typeof() empty_operand; int after_empty_typeof = 4; " +++
			"typeof(1 +) incomplete_operand; int after_incomplete = 5; " +++
			"typeof(int) long conflicting; int after_conflict = 6;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() > 0, "malformed _BitInt widths and typeof operands should be diagnosed");
		for (sz i = 0; i < d.messages.len(); i++)
		{
			assert(d.messages[i].has_location,
				"every malformed _BitInt width or typeof operand diagnostic should have a source location");
		}
		assert_variable_qt(&result, &comp, "runtime_width", type_store::INT);
		assert_variable_qt(&result, &comp, "after_empty", type_store::INT);
		assert_variable_qt(&result, &comp, "after_runtime", type_store::INT);
		assert_variable_qt(&result, &comp, "after_unclosed", type_store::INT);
		assert_variable_qt(&result, &comp, "after_empty_typeof", type_store::INT);
		assert_variable_qt(&result, &comp, "after_incomplete", type_store::INT);
		assert_variable_qt(&result, &comp, "after_conflict", type_store::INT);

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: _Static_assert builds a STATIC_ASSERT node at file scope (a
// root declaration), at block scope (a statement in the compound body) and at
// record-member scope (also a root declaration). C23 static_assert takes the
// same path. A false condition is diagnosed as "static assertion failed" and
// still yields a node.
fn void source_derived_static_assert_nodes_at_file_block_and_record_scope() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("file_scope_static_assert.c",
			"_Static_assert(1 == 1, \"ok\"); _Static_assert(0, \"x\");")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2, "both file-scope static assertions should become root declarations");
		tree::Node ok_node = result.root_decls[0].get(&result);
		tree::Node fail_node = result.root_decls[1].get(&result);
		assert(ok_node.kind == tree::NodeKind.STATIC_ASSERT);
		assert(fail_node.kind == tree::NodeKind.STATIC_ASSERT);
		// The condition is cast to bool (implicit int_to_bool), as in the AST golden for
		// `_Static_assert(sizeof(enum Small) == 1, ...)`: the cast wraps the EQUAL_EXPR.
		tree::Node ok_cond = ok_node.static_assert.cond.get(&result);
		assert(ok_cond.kind == tree::NodeKind.CAST, "the static assertion condition should be cast to bool");
		assert(ok_cond.cast.implicit, "the bool cast of a static assertion condition should be implicit");
		assert(ok_cond.cast.operand.get(&result).kind == tree::NodeKind.EQUAL_EXPR,
			"the bool cast should wrap the expression node");
		assert(!ok_node.static_assert.message.is_null(), "the static assertion should keep its message");
		assert(!fail_node.static_assert.message.is_null(), "a failing static assertion should keep its message");
		assert(has_diagnostic_fragment(&d, "static assertion failed"), "a false static assertion should be diagnosed");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("block_scope_static_assert.c",
			"int f(void) { _Static_assert(1, \"b\"); return 0; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the function should be the only root declaration");
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		assert(!function_node.function.body.is_null(), "f should be a function definition");
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		assert(body_node.kind == tree::NodeKind.COMPOUND_STMT);
		assert(body_node.compound_stmt.body.len == 2,
			"the block-scope static assertion should be a statement in the compound body");
		tree::Node assert_node = body_node.compound_stmt.body[0].get(&result);
		assert(assert_node.kind == tree::NodeKind.STATIC_ASSERT, "block-scope _Static_assert should build a STATIC_ASSERT node");
		assert(!assert_node.static_assert.message.is_null(), "the block-scope static assertion should keep its message");
		assert(body_node.compound_stmt.body[1].get(&result).kind == tree::NodeKind.RETURN_STMT);

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("record_scope_static_assert.c",
			"struct S { int a; _Static_assert(1, \"m\"); };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		uint member_asserts = 0;
		foreach (decl : result.root_decls)
		{
			tree::Node node = decl.get(&result);
			if (node.kind != tree::NodeKind.STATIC_ASSERT) continue;
			member_asserts++;
			assert(!node.static_assert.message.is_null(), "the record-member static assertion should keep its message");
		}
		assert(member_asserts == 1, "a record-member static assertion should be a root declaration");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("c23_static_assert.c", "static_assert(1, \"c23\");")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the C23 static_assert should be a root declaration");
		tree::Node node = result.root_decls[0].get(&result);
		assert(node.kind == tree::NodeKind.STATIC_ASSERT, "C23 static_assert should build a STATIC_ASSERT node");
		assert(!node.static_assert.message.is_null(), "the C23 static_assert should keep its message");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: the full C front end seeds the x86_64-linux implicit typedef prelude
// before user declarations. Each prelude entry is an implicit TYPEDEF root whose name is
// a generated token, and the ordinary typedef symbol resolves a later declaration to
// that same node.
const target::Host X86_64_LINUX_HOST = { target::Arch.X86_64, target::OsTag.LINUX, target::Abi.GNU };

fn void implicit_typedef_prelude_seeds_x86_64_linux_roots_and_symbols() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", X86_64_LINUX_HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("implicit_typedef_prelude.c",
			"__int128_t big; int f(void);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p;
		p.init(&pp);
		parser_declaration::DeclarationParser frontend;
		frontend.bind(&p);
		tree::Tree result = p.parse()!!;

		// x86_64-linux, default standard and emulation: no char8_t, __int24 or __mfp8.
		// __float80 is present because the target has an 80-bit long double.
		String[6] expected = { "__int128_t", "__uint128_t", "__builtin_ms_va_list",
			"__builtin_va_list", "__NSConstantString", "__float80" };
		sz expected_count = (sz)expected.len;
		assert(d.messages.len() == 0, "the prelude and the typedef use should not diagnose");
		assert(result.root_decls.len() == expected_count + 2, "the prelude should precede the user declarations");
		foreach (i, name : expected)
		{
			tree::Node node = result.root_decls[i].get(&result);
			assert(node.kind == tree::NodeKind.TYPEDEF, "each prelude root should be a TYPEDEF node");
			assert(node.type_def.implicit, "prelude typedefs should be marked implicit");
			assert(result.tok_slice(node.type_def.name_tok) == name, "prelude typedef names should follow Zig's order");
			assert(result.tokens[(usz)node.type_def.name_tok].loc.id.is_generated(),
				"prelude typedef names should live in generated tokens");
		}

		tree::Node object_node = result.root_decls[expected_count].get(&result);
		assert(object_node.kind == tree::NodeKind.VARIABLE, "the user declaration should follow the prelude");
		type_store::Type big_type = object_node.variable.qt.get_type(&comp);
		assert(big_type.tag == type_store::TypeTag.TYPEDEF);
		assert(big_type.type_def.decl_node == result.root_decls[0],
			"__int128_t should resolve through the ordinary typedef symbol to its implicit node");

		tree::Node function_node = result.root_decls[expected_count + 1].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 0, "int f(void) should have no function parameters");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Probe for pragma replay inside record and enum bodies. Preprocessing reports
// HANDLED so no unknown-pragma note is emitted; the token stream keeps the pragma
// line for the parser callback to replay.
<* Pragma handler counting parser replays; preprocessing just accepts the pragma. *>
struct PragmaBodyProbe (pragma::IPragma)
{
	uint parse_calls;
}

fn pragma::PragmaResult PragmaBodyProbe.preprocessor_handler(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic
	=> pragma::PragmaResult.HANDLED;

fn pragma::PragmaResult PragmaBodyProbe.parser_handler(&self, parser::Parser* p, tokens::TokenIndex start_idx) @dynamic
{
	self.parse_calls++;
	return pragma::PragmaResult.HANDLED;
}

// A `#pragma` line inside struct and enum bodies replays its parser callback once
// per line, and the surrounding declarations stay intact without diagnostics.
fn void parser_replays_pragma_inside_struct_and_enum_bodies() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		PragmaBodyProbe probe = {};
		bool added_probe = comp.pragmas.add("probe", &probe);
		assert(added_probe);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("pragma_bodies.c",
			"struct S { int a;\n#pragma probe\nint b; };\nenum E { A,\n#pragma probe\nB };\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser::Parser p; p.init(&pp);
		parser_declaration::DeclarationParser frontend;
		frontend.bind(&p);
		tree::Tree result = p.parse()!!;

		assert(probe.parse_calls == 2, "each #pragma inside a struct or enum body should replay once");
		assert(d.messages.len() == 0, "replayed body pragmas should not add diagnostics");
		sz first = first_user_root(&result);
		assert(result.root_decls.len() == first + 2, "struct S and enum E should both remain root declarations");

		tree::Node s = result.root_decls[first].get(&result);
		assert(s.kind == tree::NodeKind.STRUCT_DECL && result.tok_slice(s.container_decl.name_or_kind_tok) == "S");
		assert(s.container_decl.fields.len == 2, "struct S should keep fields a and b");
		tree::Node field_a = s.container_decl.fields[0].get(&result);
		tree::Node field_b = s.container_decl.fields[1].get(&result);
		assert(field_a.kind == tree::NodeKind.RECORD_FIELD && result.tok_slice(field_a.record_field.name_or_first_tok) == "a");
		assert(field_b.kind == tree::NodeKind.RECORD_FIELD && result.tok_slice(field_b.record_field.name_or_first_tok) == "b");

		tree::Node e = result.root_decls[first + 1].get(&result);
		assert(e.kind == tree::NodeKind.ENUM_DECL && result.tok_slice(e.container_decl.name_or_kind_tok) == "E");
		assert(e.container_decl.fields.len == 2, "enum E should keep enumerators A and B");
		tree::Node enum_a = e.container_decl.fields[0].get(&result);
		tree::Node enum_b = e.container_decl.fields[1].get(&result);
		assert(enum_a.kind == tree::NodeKind.ENUM_FIELD && result.tok_slice(enum_a.enum_field.name_tok) == "A");
		assert(enum_b.kind == tree::NodeKind.ENUM_FIELD && result.tok_slice(enum_b.enum_field.name_tok) == "B");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a previously declared enum used as an unnamed bit-field
// (`enum E : 3;`) builds a RECORD_FIELD with bit width 3 and no diagnostics.
fn void source_derived_previously_declared_enum_unnamed_bitfield_has_width() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("enum_unnamed_bitfield.c",
			"enum E { A, B }; struct S { enum E : 3; };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 0, "an unnamed enum bit-field should not add diagnostics");
		assert(result.root_decls.len() == 2);
		tree::Node e_decl = result.root_decls[0].get(&result);
		tree::Node struct_decl = result.root_decls[1].get(&result);
		assert(e_decl.kind == tree::NodeKind.ENUM_DECL);
		assert(struct_decl.kind == tree::NodeKind.STRUCT_DECL);
		assert(struct_decl.container_decl.fields.len == 1, "struct S should keep the single unnamed bit-field");

		tree::Node field = struct_decl.container_decl.fields[0].get(&result);
		assert(field.kind == tree::NodeKind.RECORD_FIELD);
		assert(!field.record_field.bit_width.is_null(), "the unnamed enum member should keep its bit-width expression");
		assert(field.record_field.qt.is(&comp, type_store::TypeTag.ENUM), "the bit-field should have the previously declared enum type");

		type_store::Type struct_type = struct_decl.container_decl.container_qt.get(&comp, type_store::TypeTag.STRUCT)!!;
		assert(struct_type.record.fields.len == 1);
		assert(struct_type.record.fields[0].bit_width == 3, "the unnamed enum bit-field should have width 3");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

// Attribute integration helpers. Attribute.Map answers are read through the
// parsed Tree; type-level attributes are read from the constructed QualTypes.
fn uint attr_tag_count(tree::Tree* result, type_store::NodeIndex node, attribute::AttributeTag tag)
{
	uint count = 0;
	foreach (ref : result.attr_map.attrs(node.pack()))
	{
		if (result.attr_map.get(ref).args.tag == tag) count++;
	}
	return count;
}

fn bool attr_has_tag(tree::Tree* result, type_store::NodeIndex node, attribute::AttributeTag tag)
{
	return attr_tag_count(result, node, tag) > 0;
}

<* Byte value of the explicit ALIGNMENT attribute recorded on `node`; 0 when none. *>
fn uint attr_alignment(tree::Tree* result, type_store::NodeIndex node)
{
	foreach (ref : result.attr_map.attrs(node.pack()))
	{
		attribute::Attribute a = result.attr_map.get(ref);
		if (a.args.tag == attribute::AttributeTag.ALIGNMENT && a.args.alignment.has_alignment) return a.args.alignment.alignment;
	}
	return 0;
}

fn void source_derived_alignas_declaration_specifiers_reach_declarations_fields_and_locals() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("alignas_decl_spec.c",
			"typedef int Int; " +++
			"_Alignas(16) int expr_aligned; _Alignas(int) int type_aligned; " +++
			"alignas(8) int c23_expr_aligned; alignas(Int) int c23_type_aligned; " +++
			"struct Fields { _Alignas(16) int member; }; " +++
			"int local_fn(void) { _Alignas(int) int local; return 0; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 7, "the typedef, aligned objects, record, and function should be retained");
		assert(attr_alignment(&result, result.root_decls[1]) == 16, "_Alignas expression should attach to the variable");
		assert(attr_alignment(&result, result.root_decls[2]) == type_store::INT.alignof(&comp),
			"_Alignas type-name should use the type's alignment");
		assert(attr_alignment(&result, result.root_decls[3]) == 8, "C23 alignas expression should attach to the variable");
		assert(attr_alignment(&result, result.root_decls[4]) == type_store::INT.alignof(&comp),
			"C23 alignas should accept a typedef-name type argument");

		tree::Node record = result.root_decls[5].get(&result);
		assert(record.kind == tree::NodeKind.STRUCT_DECL && record.container_decl.fields.len == 1);
		type_store::NodeIndex field_index = record.container_decl.fields[0];
		assert(attr_alignment(&result, field_index) == 16, "_Alignas should reach record-field construction");

		tree::Node function = result.root_decls[6].get(&result);
		type_store::NodeIndex body_index = function.function.body.unwrap();
		tree::Node body = body_index.get(&result);
		tree::Node local_stmt = body.compound_stmt.body[0].get(&result);
		assert(local_stmt.kind == tree::NodeKind.DECL_STMT);
		assert(attr_alignment(&result, local_stmt.decl_stmt.decls[0]) == type_store::INT.alignof(&comp),
			"_Alignas type-name should be recognized on a local declaration");
		assert(d.messages.len() == 0, "valid alignment declaration specifiers should not diagnose");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void source_derived_alignas_typedef_uses_typedef_attribute_diagnostics() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d; d.init_list(&ta);
		compilation::Compilation comp; comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("alignas_typedef.c", "_Alignas(16) typedef int AlignedInt;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p; p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node typedef_node = result.root_decls[0].get(&result);
		assert(typedef_node.kind == tree::NodeKind.TYPEDEF);
		bool found_invalid_target = false;
		for (sz i = 0; i < d.messages.len(); i++)
		{
			if (d.messages[i].text == "'_Alignas' attribute only applies to variables and fields") found_invalid_target = true;
		}
		assert(found_invalid_target, "alignment on a typedef should use the typedef attribute diagnostic");

		result.free(); p.free(); pp.free(); comp.free(); d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn ulong attr_field_offset(compilation::Compilation* comp, type_store::QualType record_qt, uint index)
{
	type_store::Type record = record_qt.get(comp, type_store::TypeTag.STRUCT)!!;
	return record.record.fields[index].layout.offset_bits;
}

fn void use_aarch64_target(compilation::Compilation* comp)
{
	comp.target = target::from_triple("aarch64-linux-gnu")!!;
	comp.langopts.set_target_options(&comp.target);
}

// source-derived: tag type attributes are consumed as type attributes, while
// declaration attributes on enum/record tags attach before enum sizing/layout.
fn void source_derived_gnu_enum_tag_and_trailing_attrs_apply_before_layout() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.set_emulated_compiler(lang_opts::Compiler.CLANG);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_enum_tag_gnu.c",
			"enum __attribute__((vector_size(8))) HeaderVector { HV }; enum TailVector { TV } __attribute__((aligned(8))); enum __attribute__((aligned(8))) HeaderAligned { HA }; enum TailPacked { TP = 255 } __attribute__((packed)); struct TailPackedRecord { char c; int i; } __attribute__((packed)); struct TailAlignedRecord { char c; int i; } __attribute__((aligned(8))); ")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 6, "all attributed tag definitions should be retained");
		type_store::NodeIndex header_vector_index = result.root_decls[0];
		type_store::NodeIndex tail_vector_index = result.root_decls[1];
		tree::Node header_vector = header_vector_index.get(&result);
		tree::Node tail_vector = tail_vector_index.get(&result);
		assert(header_vector.kind == tree::NodeKind.ENUM_DECL && tail_vector.kind == tree::NodeKind.ENUM_DECL);
		assert(header_vector.container_decl.container_qt.is(&comp, type_store::TypeTag.ENUM));
		assert(tail_vector.container_decl.container_qt.is(&comp, type_store::TypeTag.ENUM));
		assert(attr_tag_count(&result, header_vector_index, attribute::AttributeTag.PACKED) == 0);
		assert(attr_alignment(&result, tail_vector_index) == 8, "a closing-brace enum alignment should attach to the tag");
		assert(tail_vector.container_decl.container_qt.alignof(&comp) == 8,
			"closing-brace enum alignment should affect the enum type");
		assert(d.messages.len() == 0, "vector_size on an incomplete enum tag should be handled as a type attribute");

		type_store::NodeIndex header_aligned_index = result.root_decls[2];
		tree::Node header_aligned = header_aligned_index.get(&result);
		type_store::QualType header_aligned_qt = header_aligned.container_decl.container_qt;
		assert(attr_alignment(&result, header_aligned_index) == 8, "header aligned should attach to the enum tag node");
		assert(attr_tag_count(&result, header_aligned_index, attribute::AttributeTag.ALIGNMENT) == 1,
			"header aligned should be applied exactly once");
		assert(header_aligned_qt.alignof(&comp) == 8, "header aligned should be effective on the enum type");

		type_store::NodeIndex tail_packed_index = result.root_decls[3];
		tree::Node tail_packed = tail_packed_index.get(&result);
		type_store::Type packed_enum = tail_packed.container_decl.container_qt.get(&comp, type_store::TypeTag.ENUM)!!;
		assert(attr_has_tag(&result, tail_packed_index, attribute::AttributeTag.PACKED), "packed after the enum closing brace should attach to its tag");
		assert(packed_enum.enum_ty.tag.eql(type_store::UCHAR, &comp), "closing-brace packed should size the enum before choosing its tag type");

		type_store::NodeIndex tail_packed_record_index = result.root_decls[4];
		tree::Node tail_packed_record = tail_packed_record_index.get(&result);
		assert(attr_has_tag(&result, tail_packed_record_index, attribute::AttributeTag.PACKED));
		assert(attr_field_offset(&comp, tail_packed_record.container_decl.container_qt, 1) == 8,
			"packed after the record closing brace should affect field layout");

		tree::Node tail_aligned_record = result.root_decls[5].get(&result);
		type_store::Type aligned_record = tail_aligned_record.container_decl.container_qt.get(&comp, type_store::TypeTag.STRUCT)!!;
		assert(attr_alignment(&result, result.root_decls[5]) == 8, "aligned after the record closing brace should attach to its tag");
		assert(attr_tag_count(&result, result.root_decls[5], attribute::AttributeTag.ALIGNMENT) == 1,
			"closing-brace aligned should be applied exactly once");
		assert(aligned_record.record.layout.pointer_alignment_bits == 64,
			"closing-brace aligned should affect record layout");
		assert(d.messages.len() == 0, "valid enum and record tag attributes should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a GNU block-scope declaration whose attribute list mixes an
// argument-bearing attribute with an argument-free one records each exactly once.
fn void source_derived_gnu_block_declaration_attrs_apply_once() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_block_decl.c",
			"void f(void) { __attribute__((aligned(8), unused)) int x; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the function should be retained");
		tree::Node function_node = result.root_decls[0].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		tree::Node declaration_statement = body_node.compound_stmt.body[0].get(&result);
		assert(declaration_statement.kind == tree::NodeKind.DECL_STMT);
		type_store::NodeIndex local_index = declaration_statement.decl_stmt.decls[0];
		tree::Node local = local_index.get(&result);
		assert(local.kind == tree::NodeKind.VARIABLE && result.tok_slice(local.variable.name_tok) == "x");
		assert(attr_alignment(&result, local_index) == 8,
			"the argument-bearing aligned attribute should reach the block-scope declaration");
		assert(attr_tag_count(&result, local_index, attribute::AttributeTag.ALIGNMENT) == 1,
			"the aligned attribute should be applied exactly once");
		assert(attr_tag_count(&result, local_index, attribute::AttributeTag.UNUSED) == 1,
			"the unused attribute should be applied exactly once");
		assert(d.messages.len() == 0, "valid block-scope declaration attributes should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a GNU neon_vector_type on a block-scope declaration builds the
// local's type as a NEON vector of two int lanes on an AArch64 target.
fn void source_derived_gnu_block_neon_vector_type_builds_local_vector() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		use_aarch64_target(&comp);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_block_neon.c",
			"void f(void) { __attribute__((neon_vector_type(2))) int v; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the function should be retained");
		tree::Node function_node = result.root_decls[0].get(&result);
		tree::Node body_node = function_node.function.body.unwrap().get(&result);
		tree::Node declaration_statement = body_node.compound_stmt.body[0].get(&result);
		assert(declaration_statement.kind == tree::NodeKind.DECL_STMT);
		tree::Node local = declaration_statement.decl_stmt.decls[0].get(&result);
		assert(local.kind == tree::NodeKind.VARIABLE && result.tok_slice(local.variable.name_tok) == "v");
		type_store::Type vector = local.variable.qt.get(&comp, type_store::TypeTag.VECTOR)!!;
		assert(vector.vector.kind == type_store::VectorKind.NEON, "neon_vector_type should produce a NEON vector");
		assert(vector.vector.len == 2, "neon_vector_type(2) should produce two lanes");
		assert(vector.vector.elem.eql(type_store::INT, &comp), "the element type should remain int");
		assert(d.messages.len() == 0, "a valid neon vector on AArch64 should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a GNU neon_vector_type on a file-scope typedef is applied to
// the aliased type, not left on the typedef declaration.
fn void source_derived_gnu_file_typedef_neon_vector_type_builds_alias_vector() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		use_aarch64_target(&comp);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_typedef_neon.c",
			"typedef __attribute__((neon_vector_type(2))) int int32x2_t;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1, "the typedef should be retained");
		tree::Node typedef_node = result.root_decls[0].get(&result);
		assert(typedef_node.kind == tree::NodeKind.TYPEDEF);
		type_store::Type alias_type = typedef_node.type_def.qt.get_type(&comp);
		assert(alias_type.tag == type_store::TypeTag.TYPEDEF);
		type_store::Type vector = alias_type.type_def.base.get(&comp, type_store::TypeTag.VECTOR)!!;
		assert(vector.vector.kind == type_store::VectorKind.NEON && vector.vector.len == 2,
			"the aliased type should be a two-lane NEON vector");
		assert(d.messages.len() == 0, "a valid neon typedef should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: comma-separated file-scope declarators receive the leading
// declaration attribute each, while a declarator-position attribute stays on
// its own declarator.
fn void source_derived_gnu_comma_declarators_scope_attributes() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_comma_declarators.c",
			"__attribute__((unused)) int x, y __attribute__((aligned(4))), z;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 3, "x, y and z should each become a declaration");
		type_store::NodeIndex x = result.root_decls[0];
		type_store::NodeIndex y = result.root_decls[1];
		type_store::NodeIndex z = result.root_decls[2];
		assert(result.tok_slice(x.get(&result).variable.name_tok) == "x");
		assert(result.tok_slice(y.get(&result).variable.name_tok) == "y");
		assert(result.tok_slice(z.get(&result).variable.name_tok) == "z");

		assert(attr_has_tag(&result, x, attribute::AttributeTag.UNUSED), "the leading attribute should apply to x");
		assert(attr_has_tag(&result, y, attribute::AttributeTag.UNUSED), "the leading attribute should apply to y");
		assert(attr_has_tag(&result, z, attribute::AttributeTag.UNUSED), "the leading attribute should apply to z");
		assert(attr_alignment(&result, y) == 4, "the declarator attribute should apply to y");
		assert(attr_alignment(&result, x) == 0, "y's declarator attribute must not leak onto x");
		assert(attr_alignment(&result, z) == 0, "y's declarator attribute must not leak onto z");
		assert(d.messages.len() == 0, "valid comma-separated declarator attributes should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: declspec attributes (when -fdeclspec is enabled) reach the
// function and variable declarations they precede.
fn void source_derived_declspec_declaration_attrs_when_enabled() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.declspec_attrs = true;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_declspec.c",
			"__declspec(noreturn) void fail(void); __declspec(align(8)) int slot;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2, "fail and slot should both be retained");
		type_store::NodeIndex fail_index = result.root_decls[0];
		type_store::NodeIndex slot_index = result.root_decls[1];
		assert(fail_index.get(&result).kind == tree::NodeKind.FUNCTION);
		assert(slot_index.get(&result).kind == tree::NodeKind.VARIABLE);
		assert(attr_has_tag(&result, fail_index, attribute::AttributeTag.NORETURN), "__declspec(noreturn) should attach to the function");
		assert(attr_alignment(&result, slot_index) == 8, "__declspec(align(8)) should attach to the variable with its argument");
		assert(d.messages.len() == 0, "valid declspec attributes should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: C23 standard attributes on a file-scope declaration and on a
// parameter declaration attach to that declaration and parameter.
fn void source_derived_c23_standard_decl_and_param_attrs_attach() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_c23_decl.c",
			"[[gnu::unused]] int c23_slot; void c23_param([[gnu::unused]] int p);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2, "the variable and the function should be retained");
		type_store::NodeIndex slot_index = result.root_decls[0];
		assert(slot_index.get(&result).kind == tree::NodeKind.VARIABLE);
		assert(attr_has_tag(&result, slot_index, attribute::AttributeTag.UNUSED), "[[gnu::unused]] should attach to the variable");

		tree::Node function_node = result.root_decls[1].get(&result);
		assert(function_node.kind == tree::NodeKind.FUNCTION);
		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 1);
		type_store::NodeIndex param_index = function_type.params[0].node.unwrap();
		assert(param_index.get(&result).kind == tree::NodeKind.PARAM);
		assert(attr_has_tag(&result, param_index, attribute::AttributeTag.UNUSED), "[[gnu::unused]] should attach to the parameter");
		assert(d.messages.len() == 0, "valid C23 standard attributes should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a GNU attribute on a parameter declaration attaches to that
// parameter only.
fn void source_derived_gnu_parameter_attr_attaches_to_its_parameter() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_gnu_param.c",
			"int h(int __attribute__((unused)) p, int q);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node function_node = result.root_decls[0].get(&result);
		type_store::Func function_type = function_node.function.qt.get_func(&comp)!!;
		assert(function_type.params.len == 2);
		type_store::NodeIndex p_index = function_type.params[0].node.unwrap();
		type_store::NodeIndex q_index = function_type.params[1].node.unwrap();
		assert(attr_has_tag(&result, p_index, attribute::AttributeTag.UNUSED), "__attribute__((unused)) should attach to p");
		assert(attr_tag_count(&result, q_index, attribute::AttributeTag.UNUSED) == 0, "p's attribute must not leak onto q");
		assert(d.messages.len() == 0, "a valid parameter attribute should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: GNU tag attributes after the struct keyword (packed) and after
// the tag identifier (aligned) attach to the tag; packed changes the field offset.
fn void source_derived_gnu_tag_attrs_attach_to_record_declarations() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_tag_gnu.c",
			"struct __attribute__((packed)) P { char c; int i; }; struct Q __attribute__((aligned(8))) { int x; };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2, "both tag declarations should be retained");
		type_store::NodeIndex packed_index = result.root_decls[0];
		tree::Node packed_node = packed_index.get(&result);
		assert(packed_node.kind == tree::NodeKind.STRUCT_DECL);
		assert(attr_has_tag(&result, packed_index, attribute::AttributeTag.PACKED), "packed after the struct keyword should attach to P");
		assert(attr_field_offset(&comp, packed_node.container_decl.container_qt, 1) == 8, "packed should remove the padding before int i");

		type_store::NodeIndex aligned_index = result.root_decls[1];
		assert(aligned_index.get(&result).kind == tree::NodeKind.STRUCT_DECL);
		assert(attr_alignment(&result, aligned_index) == 8, "aligned after the tag identifier should attach to Q");
		assert(attr_tag_count(&result, packed_index, attribute::AttributeTag.ALIGNMENT) == 0, "Q's alignment must not leak onto P");
		assert(d.messages.len() == 0, "valid tag attributes should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// A declaration attribute on a later reference to an existing tag merges with
// the attributes already attached to that tag declaration.
fn void source_derived_tag_reference_attributes_preserve_prior_attributes() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_tag_reference.c",
			"struct __attribute__((packed)) Existing { char c; int i; }; " +++
			"struct Existing __attribute__((aligned(8))); ")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1,
			"a tag reference should update the existing tag without adding another root declaration");
		type_store::NodeIndex tag_index = result.root_decls[0];
		tree::Node tag = tag_index.get(&result);
		assert(tag.kind == tree::NodeKind.STRUCT_DECL);
		assert(attr_has_tag(&result, tag_index, attribute::AttributeTag.PACKED),
			"a later aligned tag reference should preserve the original packed attribute");
		assert(attr_alignment(&result, tag_index) == 8,
			"the aligned attribute on the tag reference should be merged onto the tag");
		assert(d.messages.len() == 0, "valid attributes on a tag reference should not diagnose");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a C23 standard attribute after the struct keyword attaches to
// the tag with the same effect as the GNU spelling.
fn void source_derived_c23_standard_tag_attr_attaches_to_record() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_tag_c23.c",
			"struct [[gnu::packed]] C23Packed { char c; int i; };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		type_store::NodeIndex record_index = result.root_decls[0];
		tree::Node record_node = record_index.get(&result);
		assert(record_node.kind == tree::NodeKind.STRUCT_DECL);
		assert(attr_has_tag(&result, record_index, attribute::AttributeTag.PACKED), "[[gnu::packed]] should attach to the tag");
		assert(attr_field_offset(&comp, record_node.container_decl.container_qt, 1) == 8, "packed should remove the padding before int i");
		assert(d.messages.len() == 0, "a valid C23 tag attribute should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: GNU and C23 field attributes attach to the field declaration
// and alignment moves the field's offset.
fn void source_derived_field_attrs_attach_and_move_field_offsets() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_field.c",
			"struct F { char c; int i __attribute__((aligned(8))); }; struct G { char c; [[gnu::aligned(8)]] int i; };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2, "both structs should be retained");
		for (sz s = 0; s < 2; s++)
		{
			tree::Node record_node = result.root_decls[s].get(&result);
			assert(record_node.kind == tree::NodeKind.STRUCT_DECL && record_node.container_decl.fields.len == 2);
			type_store::NodeIndex c_field = record_node.container_decl.fields[0];
			type_store::NodeIndex i_field = record_node.container_decl.fields[1];
			assert(attr_tag_count(&result, c_field, attribute::AttributeTag.ALIGNMENT) == 0, "char c has no alignment attribute");
			assert(attr_alignment(&result, i_field) == 8, "the field-level aligned attribute should reach int i");
			assert(attr_field_offset(&comp, record_node.container_decl.container_qt, 1) == 64,
				"aligning int i to 8 bytes should move its offset to 64 bits");
		}
		assert(d.messages.len() == 0, "valid field attributes should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an anonymous aggregate member carrying a tag attribute keeps
// that attribute on its own record, and the attribute moves the outer offset.
fn void source_derived_anonymous_aggregate_tag_attr_affects_outer_layout() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attr_anonymous.c",
			"struct Outer { char a; struct __attribute__((aligned(8))) { int b; }; };")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node outer = result.root_decls[0].get(&result);
		assert(outer.kind == tree::NodeKind.STRUCT_DECL);
		type_store::Type outer_type = outer.container_decl.container_qt.get(&comp, type_store::TypeTag.STRUCT)!!;
		assert(outer_type.record.fields.len == 2, "the anonymous member should be a field of Outer");
		assert(outer_type.record.fields[1].layout.offset_bits == 64,
			"the 8-byte aligned anonymous aggregate should start at offset 64");
		type_store::Type anonymous_type = outer_type.record.fields[1].qt.get(&comp, type_store::TypeTag.STRUCT)!!;
		assert(attr_alignment(&result, anonymous_type.record.decl_node.unwrap()) == 8,
			"the aligned attribute should attach to the anonymous aggregate's own declaration");
		assert(d.messages.len() == 0, "a valid anonymous aggregate attribute should not add diagnostics");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a type-position calling convention before a parenthesized
// function declarator reaches the function type inside the declared pointer.
fn void source_derived_type_position_calling_convention_reaches_function_declarator() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::from_triple("i386-linux-gnu")!!;
		comp.langopts.set_target_options(&comp.target);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("callconv_parenthesized_declarator.c",
			"__attribute__((stdcall)) int (*callback)(void);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node callback = result.root_decls[0].get(&result);
		assert(callback.kind == tree::NodeKind.VARIABLE);
		type_store::Type callback_pointer = callback.variable.qt.get(&comp, type_store::TypeTag.POINTER)!!;
		type_store::Func callback_type = callback_pointer.pointer.child.get_func(&comp)!!;
		assert(callback_type.return_type.eql(type_store::INT, &comp));
		assert(callback_type.cc == type_store::CallingConvention.STDCALL,
			"the leading type attribute should reach the function behind the parenthesized pointer declarator");
		assert(d.messages.len() == 0, "a supported convention on a function pointer type should not diagnose");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: a type-position calling convention is checked against the
// completed declaration type and emits one non-function diagnostic.
fn void source_derived_type_position_calling_convention_rejects_final_non_function() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::from_triple("i386-linux-gnu")!!;
		comp.langopts.set_target_options(&comp.target);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("callconv_non_function_final_type.c",
			"__attribute__((stdcall)) int object;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 1);
		tree::Node object = result.root_decls[0].get(&result);
		assert(object.kind == tree::NodeKind.VARIABLE);
		assert(object.variable.qt.eql(type_store::INT, &comp));
		assert(d.messages.len() == 1, "the completed non-function type should emit exactly one diagnostic");
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[0].text == "'stdcall' only applies to function types; type here is 'int'");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: applying a conflicting type-position convention to a
// typedef's function type diagnoses and preserves the existing convention.
fn void source_derived_type_position_calling_convention_preserves_existing_convention() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::from_triple("i386-linux-gnu")!!;
		comp.langopts.set_target_options(&comp.target);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("callconv_incompatible_existing_type.c",
			"typedef __attribute__((fastcall)) int ExistingFn(void); " +++
			"__attribute__((stdcall)) ExistingFn existing;")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 2);
		tree::Node function_type = result.root_decls[0].get(&result);
		assert(function_type.kind == tree::NodeKind.TYPEDEF);
		type_store::Func original_type = function_type.type_def.qt.get_func(&comp)!!;
		assert(original_type.cc == type_store::CallingConvention.FASTCALL,
			"the typedef should retain the convention established by its type attribute");

		tree::Node existing = result.root_decls[1].get(&result);
		assert(existing.kind == tree::NodeKind.FUNCTION);
		type_store::Func existing_type = existing.function.qt.get_func(&comp)!!;
		assert(existing_type.cc == type_store::CallingConvention.FASTCALL,
			"the incompatible stdcall attribute must not replace the existing fastcall convention");
		assert(d.messages.len() == 1, "the incompatible conventions should emit exactly one diagnostic");
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[0].text == "stdcall and fastcall attributes are not compatible");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: the Microsoft vectorcall keyword is applied to the completed
// function declaration type on an x86_64 Windows target.
fn void source_derived_vectorcall_keyword_sets_completed_function_calling_convention() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::from_triple("x86_64-windows-msvc")!!;
		comp.langopts.set_target_options(&comp.target);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("vectorcall_keyword.c",
			"void __attribute__((vectorcall)) gnu_vectorcall(void); " +++
			"void __vectorcall keyword_vectorcall(void); " +++
			"__vectorcall void (*callback)(void);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(result.root_decls.len() == 3);
		tree::Node gnu_function = result.root_decls[0].get(&result);
		assert(gnu_function.kind == tree::NodeKind.FUNCTION);
		type_store::Func gnu_function_type = gnu_function.function.qt.get_func(&comp)!!;
		assert(gnu_function_type.cc == type_store::CallingConvention.VECTORCALL,
			"the GNU vectorcall spelling should set the function type's convention");
		tree::Node keyword_function = result.root_decls[1].get(&result);
		assert(keyword_function.kind == tree::NodeKind.FUNCTION);
		type_store::Func keyword_function_type = keyword_function.function.qt.get_func(&comp)!!;
		assert(keyword_function_type.cc == type_store::CallingConvention.VECTORCALL,
			"the fixture's void __vectorcall spelling should set the function type's convention");
		tree::Node callback = result.root_decls[2].get(&result);
		assert(callback.kind == tree::NodeKind.VARIABLE);
		type_store::Type callback_pointer = callback.variable.qt.get(&comp, type_store::TypeTag.POINTER)!!;
		type_store::Func callback_type = callback_pointer.pointer.child.get_func(&comp)!!;
		assert(callback_type.cc == type_store::CallingConvention.VECTORCALL,
			"a leading keyword should reach the function behind a parenthesized pointer declarator");
		assert(d.messages.len() == 0, "a supported vectorcall declaration should not diagnose");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: functions returning a function or array are diagnosed at
// the function suffix opener; returning a pointer to a function remains valid.
fn void source_derived_function_return_type_diagnostics_point_at_suffix() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("function_return_types.c",
			"int *return_func(void)(void);\n" +++
			"int g(void)[3];\n" +++
			"int (*h(void))(void);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 2, "only the function and array return types should be diagnosed");
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "function cannot return a function");
		assert(d.messages[0].has_location && d.messages[0].location.line_no == 1 && d.messages[0].location.col == 17,
			"the function return diagnostic should point at return_func's first function suffix opener");
		assert(d.messages[1].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[1].text == "function cannot return an array");
		assert(d.messages[1].has_location && d.messages[1].location.line_no == 2 && d.messages[1].location.col == 6,
			"the array return diagnostic should point at g's function suffix opener");

		assert(result.root_decls.len() == 3, "the pointer-to-function return control should be retained");
		tree::Node control = result.root_decls[2].get(&result);
		assert(control.kind == tree::NodeKind.FUNCTION);
		assert(result.tok_slice(control.function.name_tok) == "h");
		type_store::Func control_type = control.function.qt.get_func(&comp)!!;
		type_store::Type returned_pointer = control_type.return_type.get(&comp, type_store::TypeTag.POINTER)!!;
		assert(returned_pointer.pointer.child.is(&comp, type_store::TypeTag.FUNC),
			"a function may return a pointer to a function");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

// source-derived: an invalid function return type in a definition diagnoses at
// its suffix without also checking the body's return expression against it.
fn void source_derived_function_definition_invalid_return_type_has_one_diagnostic() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("function_return_definition.c",
			"int *return_func(void)(void) { return 0; }")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;

		assert(d.messages.len() == 1,
			"the invalid function return type should be the only diagnostic, with no incompatible return from the body");
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text == "function cannot return a function");
		assert(d.messages[0].has_location && d.messages[0].location.line_no == 1 && d.messages[0].location.col == 17,
			"the function return diagnostic should point at return_func's function suffix opener");

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

<* Parse `source` as a translation unit and report whether `expected` was diagnosed. *>
fn bool declaration_diagnoses(String source, String expected,
	lang_opts::Standard standard = lang_opts::Standard.C17, String enable = "")
{
	uint errors;
	return parse_declarations(source, expected, standard, enable, &errors);
}

<* Number of errors `source` produces as a translation unit. *>
fn uint declaration_error_count(String source, lang_opts::Standard standard = lang_opts::Standard.C17)
{
	uint errors;
	parse_declarations(source, "", standard, "", &errors);
	return errors;
}

fn bool parse_declarations(String source, String expected, lang_opts::Standard standard,
	String enable, uint* errors)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	bool found;
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = standard;
		if (enable.len) d.set(enable, diagnostics::MessageKind.WARNING)!!;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("validate.c", source)!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;
		foreach (message : d.messages) if (message.text == expected) found = true;
		*errors = d.errors;

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
	return found;
}

fn void declarator_validate_reports_zig_validate_extra_diagnostics() @test
{
	// Zig Declarator.validateExtra: checks run on the composed declarator type.
	assert(declaration_diagnoses("struct S; struct S a[2];", "array has incomplete element type 'struct S'"));
	assert(declaration_diagnoses("int f[2](void);", "arrays cannot have functions as their element type"));
	assert(declaration_diagnoses("int g(void)[2];", "function cannot return an array"));
	assert(declaration_diagnoses("int h(void)(void);", "function cannot return a function"));
	assert(declaration_diagnoses("void p(int x[2][static 3]);", "'static' used in non-outermost array type"));
	assert(declaration_diagnoses("char huge[0x7fffffffffffffff][16];", "array is too large"));
	assert(!declaration_diagnoses("int ok[2][3];", "array is too large"));
}

fn void parameter_name_follows_pointer_attributes_and_qualifiers() @test
{
	// GNU attributes and _Atomic after `*` must not hide the parameter name from
	// the named/abstract lookahead (glibc `char *__attribute__((...)) p`).
	assert(declaration_error_count("void f(char *__attribute__((unused)) p) { (void)p; }") == 0);
	assert(declaration_error_count("void f(char *const __attribute__((unused)) *_Atomic p) { (void)p; }") == 0);
	assert(declaration_error_count("void f(int (*__attribute__((unused)) fp)(int)) { (void)fp; }") == 0);
	// Abstract forms: the attribute argument is not a declarator name.
	assert(declaration_error_count("void f(char *__attribute__((unused)));") == 0);
	assert(declaration_error_count("void f(int (*__attribute__((unused)))(int));") == 0);
	// Named and unnamed parenthesized/pointer shapes share the optional-name mode.
	assert(declaration_error_count("void f(int (*)(int), int (*fp)(int), char *(p), int (x)[3], int *[2], int (int));") == 0);
	assert(declaration_error_count("int g(a) int a; { return a; }") == 0);
}

fn void c23_function_type_returns_unqualified_non_atomic_type() @test
{
	// C23 6.7.7.4p4 (Zig validateExtra setFuncReturnType): `const int f(void)` returns `int`.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		comp.langopts.standard = lang_opts::Standard.C23;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("c23_return.c", "const int f(void);")!!;
		pp.add_token(pp.preprocess(src)!!)!!;

		parser_declaration::DeclarationParser declarations = {};
		parser::Parser p;
		p.init(&pp, &declarations);
		tree::Tree result = p.parse()!!;
		assert(result.root_decls.len() == 1);
		tree::Node decl = result.root_decls[0].get(&result);
		type_store::Type func = decl.function.qt.get(&comp, type_store::TypeTag.FUNC)!!;
		assert(!func.func.return_type.is_const, "C23 drops qualifiers from a function's return type");
		assert(func.func.return_type.eql(type_store::INT, &comp));

		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void declarator_validate_reports_alignment_and_return_qualifier_diagnostics() @test
{
	assert(declaration_diagnoses(
		"typedef struct S5 { char c[3]; } T5 __attribute__((aligned(4))); T5 arr[2];",
		"size of array element of type 'T5' (aka 'struct S5') (3 bytes) isn't a multiple of its alignment (4 bytes)"));
	assert(declaration_diagnoses("const int f(void);", "'const' type qualifier on return type has no effect",
		lang_opts::Standard.C17, "ignored-qualifiers"));
	assert(!declaration_diagnoses("const int f(void);", "'const' type qualifier on return type has no effect"),
		"-Wignored-qualifiers is off by default");
}

fn void vector_binary_operators_follow_zig_adjust_types() @test
{
	String prelude = "typedef int __attribute__((vector_size(16))) v4si;"
		"typedef int __attribute__((vector_size(8))) v2si;"
		"typedef float __attribute__((vector_size(16))) v4sf;"
		"v4si a, b; v2si c; v4sf f;";
	String[*] valid = {
		"void t(void) { a = a + b; }",
		"void t(void) { a = a % b; }",
		"void t(void) { a %= b; }",
		"void t(void) { a <<= b; }",
		"void t(void) { a = a + 1; }",
		"void t(void) { a = 2 * a; }",
		"void t(void) { a = a == b; }",
		"void t(void) { a = f < f; }",
	};
	foreach (body : valid)
	{
		String source = string::tformat("%s%s", prelude, body);
		assert(declaration_error_count(source) == 0, "vector operation must be accepted: %s", body);
	}
	assert(declaration_diagnoses(string::tformat("%s%s", prelude, "void t(void) { a = a + c; }"),
		"cannot convert between vector type 'v4si' (vector of 4 'int' values) and vector type 'v2si' (vector of 2 'int' values) as implicit conversion would cause truncation"));
	assert(declaration_diagnoses(string::tformat("%s%s", prelude, "void t(void) { a = a && b; }"),
		"invalid operands to binary expression ('v4si' (vector of 4 'int' values) and 'v4si' (vector of 4 'int' values))"));
}
