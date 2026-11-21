// Direct tests of the WIP attribute state and semantic application helpers.
// Expected behavior is derived from src/frontend/c/attribute_wip.c3; no Zig executable parity is claimed.
module attribute_wip_tests;
import aro::frontend::c::attribute, aro::frontend::c::attribute_map, aro::frontend::c::attribute_wip, aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::parser, aro::frontend::c::parser_result, aro::frontend::c::preprocessor, aro::source, aro::target, aro::frontend::c::tokens, aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner;
import std::core::mem::allocators;
import std::core::dstring;

fn void expect_diagnostic(diagnostics::Diagnostics* d, uint index, diagnostics::MessageKind kind, String text)
{
	assert(index < (uint)d.messages.len());
	assert(d.messages[(sz)index].kind == kind);
	assert(d.messages[(sz)index].text == text);
}

fn value::Value intern_c_string(compilation::Compilation* comp, String text)
{
	DString bytes;
	bytes.init(tmem);
	bytes.append_string(text);
	bytes.append_char('\0');
	return value::intern(comp, { .tag = BYTES, .bytes = bytes.str_view() });
}

fn void set_target(compilation::Compilation* comp, String triple)
{
	comp.target = target::from_triple(triple)!!;
	comp.langopts.set_target_options(&comp.target);
}

fn parser_result::Result string_attribute_arg(parser::Parser* p, compilation::Compilation* comp, String text)
{
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR, .char_literal = { .qt = type_store::CHAR } });
	return { .node = node, .qt = type_store::CHAR, .val = intern_c_string(comp, text) };
}

fn parser_result::Result int_attribute_arg(parser::Parser* p, compilation::Compilation* comp, long number)
{
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .qt = type_store::INT } });
	return { .node = node, .qt = type_store::INT, .val = value::int_i64(number, comp) };
}

fn type_store::NodeIndex function_decl(parser::Parser* p, type_store::QualType qt, bool is_inline = false, tokens::TokenIndex name_tok = 0)
{
	return p.tree.add_node({ .kind = tree::NodeKind.FUNCTION, .function = { .name_tok = name_tok, .qt = qt, .is_inline = is_inline } });
}

fn type_store::NodeIndex variable_decl(parser::Parser* p, type_store::QualType qt, tokens::TokenIndex name_tok = 0)
{
	return p.tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .name_tok = name_tok, .qt = qt } });
}

fn type_store::NodeIndex decl_ref(parser::Parser* p, type_store::NodeIndex decl, type_store::QualType qt, tokens::TokenIndex name_tok = 0)
{
	return p.tree.add_node({ .kind = tree::NodeKind.DECL_REF_EXPR, .decl_ref = { .name_tok = name_tok, .qt = qt, .decl = decl } });
}

fn tokens::TokenIndex find_token(parser::Parser* p, String spelling)
{
	for (uint i = 0; i < (uint)p.tree.tokens.len; i++)
	{
		tokens::TokenIndex tok = (tokens::TokenIndex)i;
		if (p.tree.tok_slice(tok) == spelling) return tok;
	}
	unreachable("test source token not found");
}

fn void state_add_and_restore_truncate_args_and_restore_top() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		attribute_wip::Wip wip;
		wip.init(&ta);
		attribute_wip::State initial = wip.state(false);
		parser_result::Result[2] args = {
			{ .node = (type_store::NodeIndex)10, .qt = type_store::INT, .val = value::NONE },
			{ .node = (type_store::NodeIndex)11, .qt = type_store::INT, .val = value::NONE },
		};
		attribute::Namespaced packed = { .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.PACKED };
		wip.add(packed, attribute::AttributeSyntax.GNU, 3, args[..]);
		assert(wip.parsed().len == 1);
		assert(wip.parsed_args(wip.parsed()[0]).len == 2);
		assert(wip.parsed_args(wip.parsed()[0])[1].node == (type_store::NodeIndex)11);
		attribute_wip::State application = wip.state(true);
		assert(wip.top == 1);
		parser_result::Result[] no_args = {};
		wip.add(packed, attribute::AttributeSyntax.GNU, 4, no_args);
		assert(wip.parsed().len == 2);
		wip.restore(application);
		assert(wip.parsed().len == 1 && wip.args.len() == 2);
		assert(wip.top == 0);
		wip.restore(initial);
		assert(wip.parsed().len == 0 && wip.args.len() == 0 && wip.top == 0);
		wip.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void packed_attribute_is_committed_to_constructed_tag_node() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.STRUCT_DECL, .container_decl = { .name_or_kind_tok = 0, .container_qt = type_store::VOID } });
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.PACKED }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] applied = p.tree.attr_map.attrs(decl.pack());
		assert(applied.len == 1);
		assert(p.tree.attr_map.get(applied[0]).args.tag == attribute::AttributeTag.PACKED);
		assert(d.messages.len() == 0);
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}

fn void packed_is_left_for_declaration_attribute_pass() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.PACKED }, attribute::AttributeSyntax.GNU, 0, no_args);
		type_store::QualType applied = wip.apply_type_attrs(&p, type_store::INT)!!;
		assert(applied.eql(type_store::INT, &comp));
		assert(d.messages.len() == 0);
		assert(!wip.parsed()[0].used_as_type_attr);
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}

fn void block_nullability_survives_type_store_round_trip_and_affects_equality() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		compilation::Compilation comp;
		comp.init(&ta);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		type_store::QualType plain_block = comp.type_store.put(type_store::type_block(function));
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.NULLABLE }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		type_store::QualType nullable_block = wip.apply_type_attrs(&p, plain_block)!!;
		type_store::Type stored = nullable_block.get_type(&comp);
		assert(stored.tag == type_store::TypeTag.BLOCK);
		assert(stored.block.nullability == type_store::Nullability.NULLABLE);
		assert(!nullable_block.eql(plain_block, &comp));
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void recognized_type_only_attribute_emits_unimplemented_warning() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.REGPARM }, attribute::AttributeSyntax.GNU, 0, no_args);
		type_store::QualType applied = wip.apply_type_attrs(&p, type_store::INT)!!;
		assert(applied.eql(type_store::INT, &comp));
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "TODO: implement 'regparm' attribute");
		assert(wip.parsed()[0].used_as_type_attr);
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}

fn void gnu_warning_and_error_keep_string_payloads_on_functions() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION, .function = { .qt = type_store::VOID } });
		type_store::NodeIndex string_node = p.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR, .char_literal = { .qt = type_store::CHAR } });
		value::Value warning_msg = value::intern(&comp, { .tag = BYTES, .bytes = "warn text\0" });
		value::Value error_msg = value::intern(&comp, { .tag = BYTES, .bytes = "error text\0" });
		parser_result::Result[1] warning_arg = { { .node = string_node, .qt = type_store::CHAR, .val = warning_msg } };
		parser_result::Result[1] error_arg = { { .node = string_node, .qt = type_store::CHAR, .val = error_msg } };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.WARNING }, attribute::AttributeSyntax.GNU, 0, warning_arg[..]);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ERROR }, attribute::AttributeSyntax.GNU, 0, error_arg[..]);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(decl.pack());
		assert(refs.len == 2);
		attribute::Attribute warning = p.tree.attr_map.get(refs[0]);
		attribute::Attribute error = p.tree.attr_map.get(refs[1]);
		assert(warning.args.tag == attribute::AttributeTag.WARNING && warning.args.warning == "warn text");
		assert(error.args.tag == attribute::AttributeTag.ERROR && error.args.error_msg == "error text");
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void weak_and_selectany_reject_internal_linkage() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.VARIABLE, .variable = { .qt = type_store::INT, .storage_class = tree::VariableStorageClass.STATIC } });
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.WEAK }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.SELECTANY }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(p.tree.attr_map.attrs(decl.pack()).len == 0);
		assert(d.messages.len() == 2);
		assert(d.messages[0].text == "'weak' cannot be applied to declarations with internal linkage");
		assert(d.messages[1].text == "'selectany' can only be applied to data items with external linkage");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void gnu_string_attribute_argument_and_hot_cold_diagnostics() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.FUNCTION, .function = { .qt = type_store::VOID } });
		type_store::NodeIndex int_node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .qt = type_store::INT } });
		parser_result::Result[1] bad_arg = { { .node = int_node, .qt = type_store::INT, .val = value::ONE } };
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.WARNING }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ERROR }, attribute::AttributeSyntax.GNU, 0, bad_arg[..]);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.HOT }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.COLD }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 4);
		assert(d.messages[0].text == "'warning' attribute takes one argument");
		assert(d.messages[1].text == "expected a string as argmuent of 'error' attribute but got an integer constant");
		assert(d.messages[2].text == "'cold' and 'hot' attributes are not compatible");
		expect_diagnostic(&d, 3, diagnostics::MessageKind.NOTE, "conflicting attribute is here");
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(decl.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.tag == attribute::AttributeTag.COLD);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void nonnull_checks_parameter_bounds_and_pointer_types() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("nonnull attribute errors.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::FuncParam[1] one_pointer = { type_store::func_param(type_store::INT_POINTER) };
		type_store::QualType one_pointer_fn = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, one_pointer[..]));
		type_store::NodeIndex int_node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .qt = type_store::INT } });
		parser_result::Result[1] zero_arg = { { .node = int_node, .qt = type_store::INT, .val = value::ZERO } };
		parser_result::Result[1] two_arg = { { .node = int_node, .qt = type_store::INT, .val = value::int_i64(2, &comp) } };
		type_store::NodeIndex low = function_decl(&p, one_pointer_fn);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.NONNULL }, attribute::AttributeSyntax.GNU, 0, zero_arg[..]);
		wip.apply_decl_attrs(&p, low, type_store::NODE_NULL)!!;
		wip.state(true);
		type_store::NodeIndex high = function_decl(&p, one_pointer_fn);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.NONNULL }, attribute::AttributeSyntax.GNU, 0, two_arg[..]);
		wip.apply_decl_attrs(&p, high, type_store::NODE_NULL)!!;
		wip.state(true);
		type_store::FuncParam[2] pointer_and_int = { type_store::func_param(type_store::INT_POINTER), type_store::func_param(type_store::INT) };
		type_store::QualType two_param_fn = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, pointer_and_int[..]));
		type_store::NodeIndex non_pointer = function_decl(&p, two_param_fn);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.NONNULL }, attribute::AttributeSyntax.GNU, 0, two_arg[..]);
		wip.apply_decl_attrs(&p, non_pointer, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 3);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "'nonnull' attribute parameter 1 is out of bounds");
		expect_diagnostic(&d, 1, diagnostics::MessageKind.ERROR, "'nonnull' attribute parameter 1 is out of bounds");
		expect_diagnostic(&d, 2, diagnostics::MessageKind.WARNING, "'nonnull' attribute only applies to pointer arguments");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void transparent_union_checks_tag_kind_fields_and_sizes() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("transparent_union.c", "struct S { int x; }; union Empty { }; union Mismatch { int a; double b; };")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		type_store::NodeIndex not_union = p.tree.add_node({ .kind = tree::NodeKind.STRUCT_DECL, .container_decl = { .name_or_kind_tok = find_token(&p, "S"), .container_qt = type_store::INT } });
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.TRANSPARENT_UNION }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, not_union, type_store::NODE_NULL)!!;
		wip.state(true);
		type_store::RecordField[] no_fields = {};
		type_store::RecordLayout empty_layout = { .required_alignment_bits = 8 };
		type_store::QualType empty_qt = comp.type_store.put(type_store::type_record(comp.intern_string("Empty"), no_fields, empty_layout, true));
		type_store::NodeIndex empty_union = p.tree.add_node({ .kind = tree::NodeKind.UNION_DECL, .container_decl = { .name_or_kind_tok = find_token(&p, "Empty"), .container_qt = empty_qt } });
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.TRANSPARENT_UNION }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, empty_union, type_store::NODE_NULL)!!;
		wip.state(true);
		tokens::TokenIndex a_tok = find_token(&p, "a");
		tokens::TokenIndex b_tok = find_token(&p, "b");
		type_store::RecordField[2] record_fields = {
			type_store::record_field(comp.intern_string("a"), type_store::INT),
			type_store::record_field(comp.intern_string("b"), type_store::DOUBLE),
		};
		record_fields[0].layout.size_bits = 32;
		record_fields[1].layout.size_bits = 64;
		type_store::RecordLayout layout = { .size_bits = 64, .field_alignment_bits = 64, .pointer_alignment_bits = 64, .required_alignment_bits = 8 };
		type_store::QualType mismatch_qt = comp.type_store.put(type_store::type_record(comp.intern_string("Mismatch"), record_fields[..], layout, true));
		type_store::NodeIndex field_a = p.tree.add_node({ .kind = tree::NodeKind.RECORD_FIELD, .record_field = { .name_or_first_tok = a_tok, .qt = type_store::INT } });
		type_store::NodeIndex field_b = p.tree.add_node({ .kind = tree::NodeKind.RECORD_FIELD, .record_field = { .name_or_first_tok = b_tok, .qt = type_store::DOUBLE } });
		type_store::NodeIndex[2] field_nodes = { field_a, field_b };
		type_store::NodeIndex mismatch = p.tree.add_node({ .kind = tree::NodeKind.UNION_DECL, .container_decl = { .name_or_kind_tok = find_token(&p, "Mismatch"), .container_qt = mismatch_qt, .fields = field_nodes[..] } });
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.TRANSPARENT_UNION }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, mismatch, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 4);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'transparent_union' attribute only applies to unions");
		expect_diagnostic(&d, 1, diagnostics::MessageKind.WARNING, "transparent union definition must contain at least one field; 'transparent_union' attribute ignored");
		expect_diagnostic(&d, 2, diagnostics::MessageKind.WARNING, "size of field 'b' (64 bits) does not match the size of the first field in transparent union; 'transparent_union' attribute ignored");
		expect_diagnostic(&d, 3, diagnostics::MessageKind.NOTE, "size of first field is 32");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void visibility_accepts_default_and_hidden_and_rejects_unknown_value() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("visibility.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex default_decl = variable_decl(&p, type_store::INT);
		parser_result::Result[1] default_arg = { string_attribute_arg(&p, &comp, "default") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.VISIBILITY }, attribute::AttributeSyntax.GNU, 0, default_arg[..]);
		wip.apply_decl_attrs(&p, default_decl, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(default_decl.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.visibility == attribute::Visibility.DEFAULT);
		wip.state(true);
		type_store::NodeIndex hidden_decl = variable_decl(&p, type_store::INT);
		parser_result::Result[1] hidden_arg = { string_attribute_arg(&p, &comp, "hidden") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.VISIBILITY }, attribute::AttributeSyntax.GNU, 0, hidden_arg[..]);
		wip.apply_decl_attrs(&p, hidden_decl, type_store::NODE_NULL)!!;
		refs = p.tree.attr_map.attrs(hidden_decl.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.visibility == attribute::Visibility.HIDDEN);
		wip.state(true);
		type_store::NodeIndex bad_decl = variable_decl(&p, type_store::INT);
		parser_result::Result[1] bad_arg = { string_attribute_arg(&p, &comp, "none") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.VISIBILITY }, attribute::AttributeSyntax.GNU, 0, bad_arg[..]);
		wip.apply_decl_attrs(&p, bad_decl, type_store::NODE_NULL)!!;
		assert(p.tree.attr_map.attrs(bad_decl.pack()).len == 0);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "unknown 'visibility' argument. Possible values are: \"hidden\", \"default\", \"internal\", and \"protected\"");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void cleanup_checks_function_reference_and_parameter_compatibility() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute errors.c", "int not_a_function; int target; void cleanup_fn(int *, int *); void cleanup_fn(double *);")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		p.set_function_context({ .active = true });
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex plain_value = variable_decl(&p, type_store::INT, find_token(&p, "not_a_function"));
		type_store::NodeIndex bad_reference = decl_ref(&p, plain_value, type_store::INT, find_token(&p, "not_a_function"));
		parser_result::Result[1] bad_arg = { { .node = bad_reference, .qt = type_store::INT, .val = value::NONE } };
		type_store::NodeIndex bad_target = variable_decl(&p, type_store::INT, find_token(&p, "target"));
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.CLEANUP }, attribute::AttributeSyntax.GNU, 0, bad_arg[..]);
		wip.apply_decl_attrs(&p, bad_target, type_store::NODE_NULL)!!;
		wip.state(true);
		type_store::QualType int_pointer = type_store::INT_POINTER;
		type_store::FuncParam[2] two_params = { type_store::func_param(int_pointer), type_store::func_param(int_pointer) };
		type_store::QualType two_param_fn = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, two_params[..]));
		type_store::NodeIndex two_param_decl = function_decl(&p, two_param_fn, false, find_token(&p, "cleanup_fn"));
		type_store::NodeIndex two_param_ref = decl_ref(&p, two_param_decl, two_param_fn, find_token(&p, "cleanup_fn"));
		parser_result::Result[1] two_param_arg = { { .node = two_param_ref, .qt = two_param_fn, .val = value::NONE } };
		type_store::NodeIndex arity_target = variable_decl(&p, type_store::INT, find_token(&p, "target"));
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.CLEANUP }, attribute::AttributeSyntax.GNU, 0, two_param_arg[..]);
		wip.apply_decl_attrs(&p, arity_target, type_store::NODE_NULL)!!;
		wip.state(true);
		type_store::QualType double_pointer = comp.type_store.put(type_store::type_pointer(type_store::DOUBLE));
		type_store::FuncParam[1] wrong_type_param = { type_store::func_param(double_pointer) };
		type_store::QualType wrong_type_fn = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, wrong_type_param[..]));
		type_store::NodeIndex wrong_type_decl = function_decl(&p, wrong_type_fn, false, find_token(&p, "cleanup_fn"));
		type_store::NodeIndex wrong_type_ref = decl_ref(&p, wrong_type_decl, wrong_type_fn, find_token(&p, "cleanup_fn"));
		parser_result::Result[1] wrong_type_arg = { { .node = wrong_type_ref, .qt = wrong_type_fn, .val = value::NONE } };
		type_store::NodeIndex wrong_type_target = variable_decl(&p, type_store::INT, find_token(&p, "target"));
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.CLEANUP }, attribute::AttributeSyntax.GNU, 0, wrong_type_arg[..]);
		wip.apply_decl_attrs(&p, wrong_type_target, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 3);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "'cleanup' argument 'not_a_function' is not a function");
		expect_diagnostic(&d, 1, diagnostics::MessageKind.ERROR, "'cleanup' function 'cleanup_fn' must take 1 parameter");
		expect_diagnostic(&d, 2, diagnostics::MessageKind.ERROR, "'cleanup' function 'cleanup_fn' parameter 'double *' is incompatible with 'int *'");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void section_conflict_in_same_pass_reports_warning_and_conflicting_attribute_note() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("section.c", "first second")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, {}));
		type_store::NodeIndex decl = function_decl(&p, function);
		tokens::TokenIndex first_tok = find_token(&p, "first");
		tokens::TokenIndex second_tok = find_token(&p, "second");
		parser_result::Result[1] first_arg = { string_attribute_arg(&p, &comp, "a") };
		parser_result::Result[1] second_arg = { string_attribute_arg(&p, &comp, "b") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.SECTION }, attribute::AttributeSyntax.GNU, first_tok, first_arg[..]);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.SECTION }, attribute::AttributeSyntax.GNU, second_tok, second_arg[..]);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 2);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'section' does not match previous declaration");
		expect_diagnostic(&d, 1, diagnostics::MessageKind.NOTE, "conflicting attribute is here");
		// Warning is on the conflicting (second) attribute; note is on the first (applied) one.
		source::ExpandedLocation second_loc = p.tree.tokens[(usz)second_tok].loc.expand(&comp);
		source::ExpandedLocation first_loc = p.tree.tokens[(usz)first_tok].loc.expand(&comp);
		assert(d.messages[0].has_location && d.messages[0].location.line_no == second_loc.line_no && d.messages[0].location.col == second_loc.col);
		assert(d.messages[1].has_location && d.messages[1].location.line_no == first_loc.line_no && d.messages[1].location.col == first_loc.col);
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(decl.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.tag == attribute::AttributeTag.SECTION);
		assert(p.tree.attr_map.get(refs[0]).args.section == "a");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void section_same_name_repeat_is_accepted_silently() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("section.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex decl = variable_decl(&p, type_store::INT);
		parser_result::Result[1] first_arg = { string_attribute_arg(&p, &comp, "a") };
		parser_result::Result[1] repeat_arg = { string_attribute_arg(&p, &comp, "a") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.SECTION }, attribute::AttributeSyntax.GNU, 0, first_arg[..]);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.SECTION }, attribute::AttributeSyntax.GNU, 0, repeat_arg[..]);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 0);
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(decl.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.tag == attribute::AttributeTag.SECTION);
		assert(p.tree.attr_map.get(refs[0]).args.section == "a");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void gnu_inline_requires_an_inline_function() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("gnu_inline.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, {}));
		type_store::NodeIndex decl = function_decl(&p, function);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.GNU_INLINE }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'gnu_inline' attribute requires function to be marked 'inline', attribute ignored");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void standard_noreturn_spelling_emits_deprecation_warning() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("standard attributes.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, {}));
		type_store::NodeIndex decl = function_decl(&p, function);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard._NORETURN }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "the '[[_Noreturn]]' attribute spelling is deprecated in C23; use '[[noreturn]]' instead");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void deprecated_and_nodiscard_keep_string_payloads() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attributes.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType int_function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.NORMAL, {}));
		type_store::NodeIndex deprecated_decl = function_decl(&p, int_function);
		parser_result::Result[2] deprecated_args = { string_attribute_arg(&p, &comp, "msg"), string_attribute_arg(&p, &comp, "repl") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.DEPRECATED }, attribute::AttributeSyntax.GNU, 0, deprecated_args[..]);
		wip.apply_decl_attrs(&p, deprecated_decl, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(deprecated_decl.pack());
		assert(refs.len == 1);
		attribute::Attribute deprecated = p.tree.attr_map.get(refs[0]);
		assert(deprecated.args.tag == attribute::AttributeTag.DEPRECATED);
		assert(deprecated.args.deprecated.has_msg && deprecated.args.deprecated.msg == "msg");
		assert(deprecated.args.deprecated.has_replacement && deprecated.args.deprecated.replacement == "repl");
		wip.state(true);
		type_store::NodeIndex nodiscard_decl = function_decl(&p, int_function);
		parser_result::Result[1] nodiscard_args = { string_attribute_arg(&p, &comp, "msg") };
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.NODISCARD }, attribute::AttributeSyntax.STANDARD, 0, nodiscard_args[..]);
		wip.apply_decl_attrs(&p, nodiscard_decl, type_store::NODE_NULL)!!;
		refs = p.tree.attr_map.attrs(nodiscard_decl.pack());
		assert(refs.len == 1);
		attribute::Attribute nodiscard = p.tree.attr_map.get(refs[0]);
		assert(nodiscard.args.tag == attribute::AttributeTag.WARN_UNUSED_RESULT);
		assert(nodiscard.args.warn_unused_result.has_msg && nodiscard.args.warn_unused_result.msg == "msg");
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void nodiscard_warns_on_void_function() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("standard attributes.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType void_function = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, {}));
		type_store::NodeIndex decl = function_decl(&p, void_function);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.NODISCARD }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "attribute 'nodiscard' cannot be applied to functions without return value");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void unsequenced_accepts_pointer_to_function_variable() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("c23 attributes.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function_type = comp.type_store.put(type_store::type_func(type_store::DOUBLE, type_store::FuncKind.NORMAL, {}));
		type_store::QualType pointer_to_function = comp.type_store.put(type_store::type_pointer(function_type));
		type_store::NodeIndex decl = variable_decl(&p, pointer_to_function);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.UNSEQUENCED }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(d.messages.len() == 0);
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(decl.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.tag == attribute::AttributeTag.UNSEQUENCED);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void standard_deprecated_limits_arguments_while_gnu_keeps_both_strings() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("deprecated arguments.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType int_function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.NORMAL, {}));
		parser_result::Result[2] args = { string_attribute_arg(&p, &comp, "a"), string_attribute_arg(&p, &comp, "b") };
		type_store::NodeIndex standard_decl = function_decl(&p, int_function);
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.DEPRECATED }, attribute::AttributeSyntax.STANDARD, 0, args[..]);
		wip.apply_decl_attrs(&p, standard_decl, type_store::NODE_NULL)!!;
		assert(p.tree.attr_map.attrs(standard_decl.pack()).len == 0);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "'deprecated' attribute takes at most 1 argument(s)");
		wip.state(true);
		type_store::NodeIndex gnu_decl = function_decl(&p, int_function);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.DEPRECATED }, attribute::AttributeSyntax.GNU, 0, args[..]);
		wip.apply_decl_attrs(&p, gnu_decl, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(gnu_decl.pack());
		assert(refs.len == 1);
		attribute::Attribute deprecated = p.tree.attr_map.get(refs[0]);
		assert(deprecated.args.tag == attribute::AttributeTag.DEPRECATED);
		assert(deprecated.args.deprecated.has_msg && deprecated.args.deprecated.msg == "a");
		assert(deprecated.args.deprecated.has_replacement && deprecated.args.deprecated.replacement == "b");
		assert(d.messages.len() == 1);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void nodiscard_rejects_nonfunction_and_accepts_function() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("nodiscard target.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		type_store::NodeIndex variable = variable_decl(&p, type_store::INT);
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.NODISCARD }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, variable, type_store::NODE_NULL)!!;
		assert(p.tree.attr_map.attrs(variable.pack()).len == 0);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'nodiscard' attribute only applies to functions and tag types");
		wip.state(true);
		type_store::QualType int_function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.NORMAL, {}));
		type_store::NodeIndex function = function_decl(&p, int_function);
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.NODISCARD }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, function, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(function.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.tag == attribute::AttributeTag.WARN_UNUSED_RESULT);
		assert(!p.tree.attr_map.get(refs[0]).args.warn_unused_result.has_msg);
		assert(d.messages.len() == 1);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void maybe_unused_accepts_struct_tag() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("maybe_unused tag.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex decl = p.tree.add_node({ .kind = tree::NodeKind.STRUCT_DECL, .container_decl = { .container_qt = type_store::VOID } });
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.MAYBE_UNUSED }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(decl.pack());
		assert(refs.len == 1 && p.tree.attr_map.get(refs[0]).args.tag == attribute::AttributeTag.UNUSED);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void gnu_selectany_function_reports_linkage_error_not_target_error() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("selectany function.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function_type = comp.type_store.put(type_store::type_func(type_store::VOID, type_store::FuncKind.NORMAL, {}));
		type_store::NodeIndex decl = function_decl(&p, function_type);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.SELECTANY }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(p.tree.attr_map.attrs(decl.pack()).len == 0);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "'selectany' can only be applied to data items with external linkage");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void clang_unavailable_keeps_optional_message_and_accepts_no_argument() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("unavailable.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex with_message = variable_decl(&p, type_store::INT);
		parser_result::Result[1] message_arg = { string_attribute_arg(&p, &comp, "not available") };
		wip.add({ .ns = attribute::AttrNamespace.CLANG, .clang = attribute::AttrClang.UNAVAILABLE }, attribute::AttributeSyntax.STANDARD, 0, message_arg[..]);
		wip.apply_decl_attrs(&p, with_message, type_store::NODE_NULL)!!;
		attribute_map::AttrRef[] refs = p.tree.attr_map.attrs(with_message.pack());
		assert(refs.len == 1);
		attribute::Attribute unavailable = p.tree.attr_map.get(refs[0]);
		assert(unavailable.args.tag == attribute::AttributeTag.UNAVAILABLE);
		assert(unavailable.args.unavailable.has_msg && unavailable.args.unavailable.msg == "not available");
		wip.state(true);
		type_store::NodeIndex without_message = variable_decl(&p, type_store::INT);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.CLANG, .clang = attribute::AttrClang.UNAVAILABLE }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, without_message, type_store::NODE_NULL)!!;
		refs = p.tree.attr_map.attrs(without_message.pack());
		assert(refs.len == 1);
		unavailable = p.tree.attr_map.get(refs[0]);
		assert(unavailable.args.tag == attribute::AttributeTag.UNAVAILABLE);
		assert(!unavailable.args.unavailable.has_msg);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void noreturn_rejects_variable_target() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("noreturn target.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex decl = variable_decl(&p, type_store::INT);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.STANDARD, .standard = attribute::AttrStandard.NORETURN }, attribute::AttributeSyntax.STANDARD, 0, no_args);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(p.tree.attr_map.attrs(decl.pack()).len == 0);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'noreturn' attribute only applies to functions");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void neon_vector_type_accepts_aarch64_double_only() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "aarch64-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("neon_vector_type.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[1] two = { int_attribute_arg(&p, &comp, 2) };
		wip.add({ .ns = attribute::AttrNamespace.CLANG, .clang = attribute::AttrClang.NEON_VECTOR_TYPE }, attribute::AttributeSyntax.GNU, 0, two[..]);
		type_store::QualType applied = wip.apply_type_attrs(&p, type_store::DOUBLE)!!;
		type_store::Type vector = applied.get_type(&comp);
		assert(vector.tag == type_store::TypeTag.VECTOR && vector.vector.kind == type_store::VectorKind.NEON);
		assert(d.messages.len() == 0);

		wip.state(true);
		set_target(&comp, "arm-linux-gnueabi");
		wip.add({ .ns = attribute::AttrNamespace.CLANG, .clang = attribute::AttrClang.NEON_VECTOR_TYPE }, attribute::AttributeSyntax.GNU, 0, two[..]);
		wip.apply_type_attrs(&p, type_store::DOUBLE)!!;
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "invalid vector element type 'double'");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void neon_vector_type_reports_invalid_vector_size() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "aarch64-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("neon_vector_size.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[1] size = { int_attribute_arg(&p, &comp, 128) };
		wip.add({ .ns = attribute::AttrNamespace.CLANG, .clang = attribute::AttrClang.NEON_VECTOR_TYPE }, attribute::AttributeSyntax.GNU, 0, size[..]);
		wip.apply_type_attrs(&p, type_store::ULONG)!!;
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "Neon vector size must be 64 or 128 bits");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void neon_polyvector_type_accepts_unsigned_long_and_rejects_long() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "aarch64-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("neon_polyvector_type.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[1] two = { int_attribute_arg(&p, &comp, 2) };
		wip.add({ .ns = attribute::AttrNamespace.CLANG, .clang = attribute::AttrClang.NEON_POLYVECTOR_TYPE }, attribute::AttributeSyntax.GNU, 0, two[..]);
		type_store::QualType applied = wip.apply_type_attrs(&p, type_store::ULONG)!!;
		type_store::Type vector = applied.get_type(&comp);
		assert(vector.tag == type_store::TypeTag.VECTOR && vector.vector.kind == type_store::VectorKind.NEON_POLY);
		assert(d.messages.len() == 0);

		wip.state(true);
		wip.add({ .ns = attribute::AttrNamespace.CLANG, .clang = attribute::AttrClang.NEON_POLYVECTOR_TYPE }, attribute::AttributeSyntax.GNU, 0, two[..]);
		wip.apply_type_attrs(&p, type_store::LONG)!!;
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "invalid vector element type 'long'");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void stdcall_is_not_supported_on_x86_64() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "x86_64-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("stdcall_x86_64.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		wip.apply_type_attrs(&p, function)!!;
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'__stdcall' calling convention is not supported for this target");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void stdcall_sets_calling_convention_on_i386_function_type() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("stdcall_i386.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		type_store::QualType applied = wip.apply_type_attrs(&p, function)!!;
		type_store::Type func_ty = applied.get_type(&comp);
		assert(func_ty.tag == type_store::TypeTag.FUNC);
		assert(func_ty.func.cc == type_store::CallingConvention.STDCALL);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void pcs_sets_aapcs_vfp_and_reports_unknown_enum_value() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "arm-linux-gnueabi");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("pcs.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		parser_result::Result[1] aapcs_vfp = { string_attribute_arg(&p, &comp, "aapcs-vfp") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.PCS }, attribute::AttributeSyntax.GNU, 0, aapcs_vfp[..]);
		type_store::QualType applied = wip.apply_type_attrs(&p, function)!!;
		type_store::Type func_ty = applied.get_type(&comp);
		assert(func_ty.tag == type_store::TypeTag.FUNC && func_ty.func.cc == type_store::CallingConvention.ARM_AAPCS_VFP);
		assert(d.messages.len() == 0);

		wip.state(true);
		parser_result::Result[1] bogus = { string_attribute_arg(&p, &comp, "bogus") };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.PCS }, attribute::AttributeSyntax.GNU, 0, bogus[..]);
		wip.apply_type_attrs(&p, function)!!;
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "unknown 'pcs' argument. Possible values are: \"aapcs\" and \"aapcs-vfp\"");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void stdcall_on_pointer_reports_non_function_type() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "x86_64-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("stdcall_pointer.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		wip.apply_calling_convention(&p, 0, type_store::INT_POINTER, true)!!;
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'__stdcall' only applies to function types; type here is 'int *'");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void stdcall_on_pointer_type_path_delays_without_diagnostic() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("stdcall_pointer_type_path.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		type_store::QualType applied = wip.apply_type_attrs(&p, type_store::INT_POINTER)!!;
		assert(applied.eql(type_store::INT_POINTER, &comp));
		assert(d.messages.len() == 0);
		// The delayed convention stays queued; used stays set so the decl path does not re-apply it.
		assert(wip.parsed()[0].used_as_type_attr);
		// Once the final declarator type exists, the pending convention lands on its function type.
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		wip.apply_pending_calling_conventions(&p, function)!!;
		type_store::Type func_ty = function.get_type(&comp);
		assert(func_ty.tag == type_store::TypeTag.FUNC);
		assert(func_ty.func.cc == type_store::CallingConvention.STDCALL);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void fallthrough_outside_switch_reports_diagnostic() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fallthrough_outside_switch.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex stmt = p.tree.add_node({ .kind = tree::NodeKind.NULL_STMT });
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.FALLTHROUGH }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_stmt_attrs(&p, stmt, false)!!;
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "'fallthrough' attribute outside a switch statement");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void fallthrough_not_before_switch_label_reports_diagnostic() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("fallthrough_not_before_case.c", "next_statement;")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		p.tok_i = find_token(&p, "next_statement");
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::NodeIndex stmt = p.tree.add_node({ .kind = tree::NodeKind.NULL_STMT });
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.FALLTHROUGH }, attribute::AttributeSyntax.GNU, 0, no_args);
		wip.apply_stmt_attrs(&p, stmt, true)!!;
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "'fallthrough' attribute not preceding a switch label");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void cold_and_hot_label_attributes_conflict() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("label_attributes.c", "label: ;")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp); p.bind_finalized_tokens();
		attribute_wip::Wip wip; wip.init(comp.gpa);
		tokens::TokenIndex label_tok = find_token(&p, "label");
		type_store::NodeIndex body = p.tree.add_node({ .kind = tree::NodeKind.NULL_STMT });
		type_store::NodeIndex label = p.tree.add_node({ .kind = tree::NodeKind.LABELED_STMT, .labeled_stmt = { .label_tok = label_tok, .body = body } });
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.COLD }, attribute::AttributeSyntax.GNU, label_tok, no_args);
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.HOT }, attribute::AttributeSyntax.GNU, label_tok, no_args);
		wip.apply_stmt_attrs(&p, label, false)!!;
		assert(d.messages.len() == 2);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "'hot' and 'cold' attributes are not compatible");
		expect_diagnostic(&d, 1, diagnostics::MessageKind.NOTE, "conflicting attribute is here");
		attribute_map::AttrRef[] applied = p.tree.attr_map.attrs(label.pack());
		assert(applied.len == 1 && p.tree.attr_map.get(applied[0]).args.tag == attribute::AttributeTag.HOT);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void vector_size_on_bool_reports_invalid_element_type() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("vector_size_bool.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[1] size = { int_attribute_arg(&p, &comp, 8) };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.VECTOR_SIZE }, attribute::AttributeSyntax.GNU, 0, size[..]);
		assert(@catch(wip.apply_type_attrs(&p, type_store::BOOL)) == parser::PARSING_FAILED);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.ERROR, "invalid vector element type '_Bool'");
		assert(!wip.parsed()[0].used_as_type_attr);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void vector_size_on_incomplete_enum_reports_invalid_element_type_without_panic() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("vector_size_incomplete_enum.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		type_store::QualType incomplete_enum = comp.type_store.put({ .tag = type_store::TypeTag.ENUM, .enum_ty = { .incomplete = true, .name = comp.intern_string("E") } });
		parser_result::Result[1] size = { int_attribute_arg(&p, &comp, 8) };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.VECTOR_SIZE }, attribute::AttributeSyntax.GNU, 0, size[..]);
		// Default emulation is not clang, so the incomplete enum is an invalid element, not a silent return and not a sizeof panic.
		assert(@catch(wip.apply_type_attrs(&p, incomplete_enum)) == parser::PARSING_FAILED);
		assert(d.messages.len() == 1);
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		assert(d.messages[0].text.starts_with("invalid vector element type"));
		assert(!wip.parsed()[0].used_as_type_attr);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void decl_calling_convention_on_non_function_reports_non_func_diagnostic() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("decl_callconv_non_func.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		// Applying a declaration attribute to a variable must diagnose immediately.
		type_store::NodeIndex decl = variable_decl(&p, type_store::INT);
		wip.apply_decl_attrs(&p, decl, type_store::NODE_NULL)!!;
		assert(p.tree.attr_map.attrs(decl.pack()).len == 0);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "'__stdcall' only applies to function types; type here is 'int'");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void type_position_calling_convention_on_declarator_combine_waits_for_final_type() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("pending_callconv_declarator.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		// Type position on the declarator placeholder: the convention stays queued and undiagnosed; used stays set so the decl path skips it.
		type_store::QualType placeholder = wip.apply_type_attrs(&p, type_store::DECLARATOR_COMBINE)!!;
		assert(placeholder.is_declarator_combine());
		assert(wip.parsed()[0].used_as_type_attr);
		assert(d.messages.len() == 0);

		// Once the final declarator type exists, the pending convention lands on its function type.
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		wip.apply_pending_calling_conventions(&p, function)!!;
		type_store::Type func_ty = function.get_type(&comp);
		assert(func_ty.tag == type_store::TypeTag.FUNC);
		assert(func_ty.func.cc == type_store::CallingConvention.STDCALL);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void declaration_path_calling_convention_marker_is_pending_and_retries_on_function() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("decl_callconv_declarator_marker.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		// Declaration path on the incomplete-declarator placeholder: queued and undiagnosed; used stays set so the decl pass skips it.
		type_store::QualType returned = wip.apply_calling_convention(&p, 0, type_store::DECLARATOR_COMBINE, true)!!;
		assert(returned.is_declarator_combine());
		assert(wip.parsed()[0].used_as_type_attr);
		assert(wip.pending_calling_conventions_active().len == 1);
		assert(wip.pending_calling_conventions_active()[0] == 0);
		assert(d.messages.len() == 0);
		// A repeated declaration-path delay for the same slot must not queue it twice.
		wip.apply_calling_convention(&p, 0, type_store::DECLARATOR_COMBINE, true)!!;
		assert(wip.pending_calling_conventions_active().len == 1);
		// Retrying an incomplete type consumes the old log entry and appends a fresh active entry.
		wip.apply_pending_calling_conventions(&p, type_store::DECLARATOR_COMBINE)!!;
		assert(wip.pending_calling_conventions_active().len == 1);
		assert(wip.pending_calling_conventions_active()[0] == 0);
		// The final declarator type exists: the pending convention lands on its function type and the queue drains.
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		wip.apply_pending_calling_conventions(&p, function)!!;
		type_store::Type func_ty = function.get_type(&comp);
		assert(func_ty.tag == type_store::TypeTag.FUNC);
		assert(func_ty.func.cc == type_store::CallingConvention.STDCALL);
		assert(wip.pending_calling_conventions_active().len == 0);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void declaration_path_calling_convention_marker_is_dropped_by_state_restore() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("decl_callconv_state_restore.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		attribute_wip::State initial = wip.state(false);
		assert(initial.pending_calling_conventions == 0);
		wip.apply_calling_convention(&p, 0, type_store::DECLARATOR_COMBINE, true)!!;
		assert(wip.pending_calling_conventions_active().len == 1);
		// Restore rolls back the queued marker; the attribute itself is older than the snapshot and stays.
		wip.restore(initial);
		assert(wip.pending_calling_conventions_active().len == 0);
		assert(wip.parsed().len == 1);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void declaration_path_calling_convention_marker_is_restored_after_consumption() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("decl_callconv_state_restore_consumed.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		wip.apply_calling_convention(&p, 0, type_store::DECLARATOR_COMBINE, true)!!;
		attribute_wip::State pending = wip.state(false);
		assert(wip.pending_calling_conventions_active().len == 1);

		// Draining a final function consumes the marker, but restoring the earlier snapshot revives it.
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}));
		wip.apply_pending_calling_conventions(&p, function)!!;
		assert(wip.pending_calling_conventions_active().len == 0);
		wip.restore(pending);
		assert(wip.pending_calling_conventions_active().len == 1);
		assert(wip.pending_calling_conventions_active()[0] == 0);
		assert(d.messages.len() == 0);
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

fn void incompatible_existing_calling_convention_keeps_type_and_reports_warning() @test
{
	TrackingAllocator ta; ta.init(mem); defer ta.free();
	diagnostics::Diagnostics d; d.init_list(&ta);
	{
		compilation::Compilation comp; comp.init(&ta, null, &d);
		set_target(&comp, "i386-linux-gnu");
		preprocessor::Preprocessor pp; pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("callconv_incompatible.c", "")!!; pp.preprocess_extra(src)!!;
		parser::Parser p; p.init(&pp);
		attribute_wip::Wip wip; wip.init(comp.gpa);
		// The function type already carries fastcall; a stdcall attribute must not overwrite it.
		type_store::QualType function = comp.type_store.put(type_store::type_func(type_store::INT, type_store::FuncKind.OLD_STYLE, {}, type_store::CallingConvention.FASTCALL));
		parser_result::Result[] no_args = {};
		wip.add({ .ns = attribute::AttrNamespace.KEYWORD, .keyword = attribute::AttrKeyword.__STDCALL }, attribute::AttributeSyntax.KEYWORD, 0, no_args);
		type_store::QualType applied = wip.apply_calling_convention(&p, 0, function, true)!!;
		assert(applied.eql(function, &comp));
		type_store::Type func_ty = applied.get_type(&comp);
		assert(func_ty.tag == type_store::TypeTag.FUNC);
		assert(func_ty.func.cc == type_store::CallingConvention.FASTCALL);
		assert(d.messages.len() == 1);
		expect_diagnostic(&d, 0, diagnostics::MessageKind.WARNING, "stdcall and fastcall attributes are not compatible");
		wip.free(); p.free(); pp.free(); comp.free();
	}
	d.free(); assert(ta.allocation_count() == 0);
}

// Builds a GNU aligned attribute carrying an ALIGNMENT payload and returns its ref.
fn attribute_map::AttrRef gnu_aligned_ref(parser::Parser* p, bool has_alignment, uint alignment)
{
	attribute::Attribute a = { .args = { .tag = attribute::AttributeTag.ALIGNMENT, .alignment = { .has_alignment = has_alignment, .alignment = alignment } }, .syntax = attribute::AttributeSyntax.GNU, .name = { .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ALIGNED }, .tok = 0 };
	return p.tree.attr_map.put(a);
}

// Fresh TYPEDEF declaration node. Its payload qt is INT; the requested-alignment key is the QualType from new_typedef_qt.
fn type_store::NodeIndex new_typedef_node(parser::Parser* p)
{
	return p.tree.add_node({ .kind = tree::NodeKind.TYPEDEF, .type_def = { .name_tok = 0, .qt = type_store::INT } });
}

fn type_store::QualType new_typedef_qt(compilation::Compilation* comp, type_store::NodeIndex decl)
{
	return comp.type_store.put(type_store::type_typedef(type_store::INT, comp.intern_string("TestTypedef"), decl));
}

// Inheriting ALIGNMENT from a function must not write a request onto a variable's type (Zig: only typedef/enum nodes record).
fn void inherited_function_alignment_does_not_reach_variable_type() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		type_store::NodeIndex prev = function_decl(&p, type_store::INT);
		p.tree.attr_map.set_decl_attrs(prev, { gnu_aligned_ref(&p, true, 16) });
		type_store::NodeIndex decl_var = variable_decl(&p, type_store::INT);
		wip.apply_decl_attrs_extra(&p, decl_var, type_store::INT, prev.pack())!!;
		assert(!@ok(comp.type_store.get_requested_alignment(type_store::INT)));
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}

// Inheriting ALIGNMENT(16) onto a typedef node records 16 on the typedef's QualType.
fn void inherited_alignment_records_typedef_request() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		type_store::NodeIndex prev = function_decl(&p, type_store::INT);
		p.tree.attr_map.set_decl_attrs(prev, { gnu_aligned_ref(&p, true, 16) });
		type_store::NodeIndex td = new_typedef_node(&p);
		type_store::QualType td_qt = new_typedef_qt(&comp, td);
		wip.apply_decl_attrs_extra(&p, td, td_qt, prev.pack())!!;
		assert(comp.type_store.get_requested_alignment(td_qt)!! == 16);
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}

// Repeated typedef inheritance max-merges: 16, then 32, then 8 leaves 32 on the same typedef QualType.
fn void inherited_alignment_max_merges_typedef_request() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		type_store::QualType td_qt = new_typedef_qt(&comp, new_typedef_node(&p));
		uint[3] values = { 16, 32, 8 };
		foreach (v : values)
		{
			type_store::NodeIndex prev = function_decl(&p, type_store::INT);
			p.tree.attr_map.set_decl_attrs(prev, { gnu_aligned_ref(&p, true, v) });
			type_store::NodeIndex td = new_typedef_node(&p);
			wip.apply_decl_attrs_extra(&p, td, td_qt, prev.pack())!!;
		}
		assert(comp.type_store.get_requested_alignment(td_qt)!! == 32);
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}

// A missing ALIGNMENT value on inherit records target default_alignment on the typedef, not 0.
fn void inherited_null_alignment_records_target_default_on_typedef() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		type_store::NodeIndex prev = function_decl(&p, type_store::INT);
		p.tree.attr_map.set_decl_attrs(prev, { gnu_aligned_ref(&p, false, 0) });
		type_store::NodeIndex td = new_typedef_node(&p);
		type_store::QualType td_qt = new_typedef_qt(&comp, td);
		wip.apply_decl_attrs_extra(&p, td, td_qt, prev.pack())!!;
		assert(comp.type_store.get_requested_alignment(td_qt)!! == comp.target.default_alignment());
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}

// GNU aligned on a variable must not write the type request; aligned on typedefs max-merges (8 kept over 4).
fn void aligned_on_variable_does_not_set_type_request() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	diagnostics::Diagnostics d;
	d.init_list(&ta);
	{
		compilation::Compilation comp;
		comp.init(&ta, null, &d);
		preprocessor::Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		source::Source src = comp.add_source_from_buffer("attribute-wip.c", "")!!;
		pp.preprocess_extra(src)!!;
		parser::Parser p;
		p.init(&pp);
		attribute_wip::Wip wip;
		wip.init(comp.gpa);
		attribute_wip::State initial = wip.state(false);
		type_store::NodeIndex decl_var = variable_decl(&p, type_store::INT);
		parser_result::Result[1] arg16 = { int_attribute_arg(&p, &comp, 16) };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ALIGNED }, attribute::AttributeSyntax.GNU, 0, arg16[..]);
		wip.apply_decl_attrs(&p, decl_var, type_store::NODE_NULL)!!;
		assert(!@ok(comp.type_store.get_requested_alignment(type_store::INT)));
		wip.restore(initial);
		type_store::QualType td_qt = new_typedef_qt(&comp, new_typedef_node(&p));
		type_store::NodeIndex td8 = new_typedef_node(&p);
		parser_result::Result[1] arg8 = { int_attribute_arg(&p, &comp, 8) };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ALIGNED }, attribute::AttributeSyntax.GNU, 0, arg8[..]);
		wip.apply_decl_attrs_extra(&p, td8, td_qt, type_store::NODE_NULL)!!;
		wip.restore(initial);
		type_store::NodeIndex td4 = new_typedef_node(&p);
		parser_result::Result[1] arg4 = { int_attribute_arg(&p, &comp, 4) };
		wip.add({ .ns = attribute::AttrNamespace.GNU, .gnu = attribute::AttrGnu.ALIGNED }, attribute::AttributeSyntax.GNU, 0, arg4[..]);
		wip.apply_decl_attrs_extra(&p, td4, td_qt, type_store::NODE_NULL)!!;
		wip.restore(initial);
		assert(comp.type_store.get_requested_alignment(td_qt)!! == 8);
		wip.free();
		p.free();
		pp.free();
		comp.free();
	}
	d.free();
	assert(ta.allocation_count() == 0);
}
