// Token-level coverage for attribute syntax. Declaration grammar is still
// callback-only, so these tests cover syntax spans, not semantic AST attachment.
module parser_attribute_tests;
import aro::attribute, aro::compilation, aro::diagnostics, aro::parser, aro::parser_attribute;
import aro::preprocessor, aro::source, aro::tokenizer;

fn void check_attribute_specifier(String input, uint kind)
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		diagnostics::Diagnostics d;
		d.init_list(&ta);
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		if (kind == 2) comp.langopts.declspec_attrs = true;
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute.c", input)!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		parser_attribute::AttributeBuffer out;
		out.init(comp.gpa);
		uint count = p.parse_attribute_specifiers(&out)!!;
		assert(p.at_eof());
		if (kind == 0)
		{
			assert(count == 1 && out.attributes.len() == 2);
			assert(out.attributes[0].syntax == attribute::AttributeSyntax.GNU);
			assert(out.attributes[0].name.name() == "aligned");
			assert(out.attributes[0].has_arg_list && out.attributes[0].args_len == 1);
			parser_attribute::AttributeArgTokens arg = out.arguments[(usz)out.attributes[0].args_offset];
			assert(p.tree.tok_slice(arg.start) == "8" && p.tree.tok_slice(arg.end - 1) == "8");
			assert(out.attributes[1].name.name() == "cold" && !out.attributes[1].has_arg_list);
		}
		else if (kind == 1)
		{
			assert(count == 1 && out.attributes.len() == 2);
			assert(out.attributes[0].syntax == attribute::AttributeSyntax.STANDARD);
			assert(out.attributes[0].has_vendor && out.attributes[0].vendor == "gnu");
			assert(out.attributes[0].name.name() == "aligned");
			assert(out.attributes[0].args_len == 1 && out.arguments.len() == 2);
			parser_attribute::AttributeArgTokens arg = out.arguments[1];
			assert(p.tree.tok_slice(arg.start) == "\"reason\"");
			assert(out.attributes[1].name.name() == "nodiscard");
		}
		else
		{
			assert(count == 1 && out.attributes.len() == 1);
			assert(out.attributes[0].syntax == attribute::AttributeSyntax.DECLSPEC);
			assert(out.attributes[0].name.name() == "noinline");
			assert(!out.attributes[0].has_arg_list);
		}
		out.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void gnu_attribute_records_nested_argument_spans_and_cursor() @test
{
	check_attribute_specifier("__attribute__((aligned(8), cold))", 0);
}

fn void c23_attribute_records_namespace_and_argument_spans() @test
{
	check_attribute_specifier("[[gnu::aligned(16), nodiscard(\"reason\")]]", 1);
}

fn void declspec_attribute_records_name_and_cursor() @test
{
	check_attribute_specifier("__declspec(noinline)", 2);
}

fn void unknown_attribute_emits_unknown_name_diagnostic() @test
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
		source::Source src = comp.add_source_from_buffer("unknown-attribute.c", "[[vendor::mystery]]")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		parser_attribute::AttributeBuffer out;
		out.init(comp.gpa);
		p.parse_attribute_specifiers(&out)!!;
		assert(out.attributes.len() == 1 && !out.attributes[0].has_name);
		assert(d.messages.len() == 1);
		assert(d.messages[0].has_opt && d.messages[0].opt == diagnostics::Option.UNKNOWN_ATTRIBUTES);
		assert(d.messages[0].text == "unknown attribute 'vendor::mystery' ignored");
		out.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void malformed_attribute_rolls_back_buffer_state() @test
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
		source::Source src = comp.add_source_from_buffer("malformed-attribute.c", "__attribute__((aligned(8)")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		parser_attribute::AttributeBuffer out;
		out.init(comp.gpa);
		out.add_keyword(tokenizer::TokenId.KEYWORD_ALIGNAS, 0);
		fault parse_error = @catch(p.parse_attribute_specifiers(&out));
		assert(parse_error == parser::PARSING_FAILED);
		assert(out.attributes.len() == 1 && out.arguments.len() == 0);
		assert(out.attributes[0].syntax == attribute::AttributeSyntax.KEYWORD);
		assert(d.messages.len() > 0);
		out.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
