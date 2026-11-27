module darwin_sdk_syntax_tests;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::parser;
import aro::frontend::c::preprocessor, aro::frontend::c::tree, aro::frontend::c::type_store, aro::source;
import std::core::mem::allocators;

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

fn void availability_clauses_are_metadata_not_expressions() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("availability.c",
			"int f(void) __attribute__((availability(ios,introduced=8.0)));\n" +++
			"int g(void) __attribute__((__availability__(macosx,introduced=10.12,deprecated=12.0)));\n" +++
			"int h(void) __attribute__((availability(swift,unavailable,message=\"not available\")));\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p;
		p.init(&pp);
		tree::Tree result = p.parse()!!;
		assert(d.messages.len() == 0, "availability metadata must not become C expressions or emit TODO warnings");
		assert(result.root_decls.len() - first_user_root(&result) == 3);
		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void malformed_availability_clause_is_diagnosed() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("bad-availability.c",
			"int f(void) __attribute__((availability(ios,introduced=)));\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p;
		p.init(&pp);
		tree::Tree result = p.parse()!!;
		bool found = false;
		foreach (message : d.messages)
		{
			if (message.kind == diagnostics::MessageKind.ERROR && message.text.contains("malformed availability attribute")) found = true;
		}
		assert(found, "incomplete availability metadata must be diagnosed");
		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void pointer_nullability_survives_declarator_parsing() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("nullability.c",
			"int * _Nullable p; int (* _Nonnull cb)(void); " +++
			"int * _Nullable_result q; int * _Null_unspecified r;\n")!!;
		pp.add_token(pp.preprocess(src)!!)!!;
		parser::Parser p;
		p.init(&pp);
		tree::Tree result = p.parse()!!;
		assert(d.messages.len() == 0);
		sz first_user = first_user_root(&result);
		assert(result.root_decls.len() - first_user == 4);
		type_store::Nullability[4] expected = { NULLABLE, NONNULL, NULLABLE_RESULT, UNSPECIFIED };
		for (sz i = 0; i < 4; i++)
		{
			tree::Node decl = result.root_decls[first_user + i].get(&result);
			assert(decl.kind == tree::NodeKind.VARIABLE);
			type_store::Type pointer = decl.variable.qt.get(&comp, type_store::TypeTag.POINTER)!!;
			assert(pointer.pointer.nullability == expected[i]);
		}
		result.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
