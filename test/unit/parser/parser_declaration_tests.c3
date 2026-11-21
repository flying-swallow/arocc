// Focused tests for declaration helpers, source-derived integration, and parser recovery.
module parser_declaration_tests;
import aro::frontend::c::parser, aro::frontend::c::preprocessor, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::source, aro::frontend::c::type_store, aro::frontend::c::symbol_stack, aro::string_interner, aro::frontend::c::value;
import aro::frontend::c::parser_declaration;
import aro::frontend::c::lang_opts, aro::target;
import aro::frontend::c::pragma;
import aro::frontend::c::attribute;

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
	type_store::QualType items_qt;
	type_store::QualType text_qt;
	type_store::NodeIndex items_node;
	type_store::NodeIndex text_node;
	uint declaration_count;
}

struct InferredTypeCapture (parser_declaration::IDeclarationTestProbe)
{
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
	p.declarations.parse_declaration(p)!;
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
	p.declarations.parse_declaration(p)!;
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
		p.init(&pp); p.declarations.test_probe = &state;
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
		FrontendFaultRecoveryState state = { .frontend = &p.declarations };
		p.declarations.test_probe = &state;
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
		parser::Parser p;
		p.init(&pp); p.declarations.test_probe = &capture;
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
		parser::Parser p;
		p.init(&pp); p.declarations.test_probe = &capture;
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
		parser::Parser p;
		p.init(&pp); p.declarations.test_probe = &capture;
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

// Helpers for the _BitInt and typeof declaration-specifier tests below.
fn type_store::QualType bit_int_qt(compilation::Compilation* comp, ushort bits, lang_opts::Signedness s) =>
	comp.type_store.put(type_store::type_bit_int(bits, s));

fn type_store::QualType with_quals(type_store::QualType qt, bool want_const, bool want_volatile)
{
	qt.is_const = want_const;
	qt.is_volatile = want_volatile;
	return qt;
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
		parser::Parser p;
		p.init(&pp); p.declarations.test_probe = &capture;
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

