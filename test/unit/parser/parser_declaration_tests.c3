// Focused tests for declaration helpers, source-derived integration, and parser recovery.
module parser_declaration_tests;
import aro::frontend::c::parser, aro::frontend::c::preprocessor, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::tree;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::source, aro::frontend::c::type_store, aro::frontend::c::symbol_stack;
import aro::target;
import aro::frontend::c::pragma;

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

