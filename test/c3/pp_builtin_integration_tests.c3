// Integration coverage for the real builtin provider through the ordinary
// preprocessing path. Expected values are source-derived from
// pp_builtin_macros.c3, pp_feature_queries.c3 and preprocessor.c3; no Zig
// differential run is claimed.
module pp_builtin_integration_tests;
import aro::preprocessor, aro::source, aro::compilation, aro::diagnostics;
import std::core::mem::allocators, std::core::dstring;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn void default_provider_expands_builtin_macros_and_attribute_features() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("builtin-integration.c",
			"int line = __LINE__;\n"
			"#if __has_feature(attribute_deprecated_with_message)\n"
			"int feature = 1;\n"
			"#else\n"
			"int feature = 0;\n"
			"#endif\n"
			"#if __has_extension(__attribute_deprecated_with_message__)\n"
			"int extension = 1;\n"
			"#else\n"
			"int extension = 0;\n"
			"#endif\n"
			"#if __has_attribute(deprecated)\n"
			"int attribute = 1;\n"
			"#else\n"
			"int attribute = 0;\n"
			"#endif\n"
			"#if __has_feature(not_an_attribute_feature)\n"
			"int unknown = 1;\n"
			"#else\n"
			"int unknown = 0;\n"
			"#endif\n")!!;
		InitOptions opts = preprocessor::TESTING;
		opts.base_file = src.id;
		opts.add_builtin_macros = true;
		Preprocessor pp;
		pp.init(&comp, opts)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!;

		DString output;
		output.init(tmem);
		pp.pretty_print_tokens(&output, preprocessor::RESULT_ONLY)!!;
		// [source-derived] __LINE__ expands to the source line; builtin function
		// queries use the shared attribute tables, and unknown features are false.
		test::eq(output.str_view(), "int line = 1;\nint feature = 1;\nint extension = 1;\nint attribute = 1;\nint unknown = 0;\n");
		check(d.messages.len(), 0);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}
