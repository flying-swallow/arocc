module parser_reference_tests;
import aro::compilation, aro::diagnostics, aro::parser, aro::parser_declaration;
import aro::predefined_macros, aro::preprocessor, aro::source, aro::tokens, aro::tree, aro::type_store;

// Verbatim port of src/aro/Parser.zig:11591 test "Node locations"
fn void parser_zig_node_locations() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		source::Source file = comp.add_source_from_buffer("file.c",
			"int foo = 5;\nint bar = 10;\nint main(void) {}\n")!!;

		source::Source builtin_macros = predefined_macros::generate_builtin_macros(&comp,
			predefined_macros::SystemDefinesMode.NO_SYSTEM_DEFINES)!!;

		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.add_builtin_macros();
		pp.preprocess(builtin_macros)!!;
		tokens::TokenWithExpansionLocs eof = pp.preprocess(file)!!;
		pp.add_token(eof)!!;

		parser::Parser p;
		p.init(&pp);
		parser_declaration::DeclarationParser handler;
		handler.bind(&p);
		tree::Tree parsed = p.parse()!!;
		assert(parsed.root_decls.len() >= 3);

		sz first = parsed.root_decls.len() - 3;
		for (sz i = 0; i < 3; i++)
		{
			type_store::NodeIndex node = parsed.root_decls[first + i];
			String expected_slice;
			switch (i)
			{
				case 0: expected_slice = "foo";
				case 1: expected_slice = "bar";
				case 2: expected_slice = "main";
				default: unreachable();
			}
			assert(parsed.tok_slice(node.tok(&parsed)) == expected_slice);

			source::ExpandedLocation loc = node.loc(&parsed).expand(&comp);
			assert(loc.col == 5);
			assert(loc.line_no == (uint)i + 1);
			assert(loc.path == "file.c");
			assert(loc.kind == source::SourceKind.USER);
		}

		parsed.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
