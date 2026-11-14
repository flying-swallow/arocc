// Focused coverage for sparse conversion, initializer designators, and nested
// initializer grammar behavior.
module parser_initializer_tests;
import aro::compilation, aro::diagnostics, aro::init_list, aro::parser, aro::parser_result;
import aro::preprocessor, aro::source, aro::tokenizer, aro::tokens, aro::tree, aro::type_store, aro::value;
import aro::value_interner;

fn parser_result::Result? parse_initializer_test_integer(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	String spelling = p.pp.tree_token_slice(p.tree.tokens[(usz)tok]);
	long parsed_value = spelling == "999999" ? 999999 : spelling == "1" ? 1 : spelling == "2" ? 2 : spelling == "3" ? 3 : spelling == "4" ? 4 : 7;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL,
		.literal = { .literal_tok = tok, .qt = type_store::INT } });
	p.advance();
	return { .node = node, .qt = type_store::INT, .val = eval ? value::int_i64(parsed_value, p.comp) : value::NONE };
}

fn parser_result::Result? parse_initializer_test_ice(void* context, parser::Parser* p, parser::ConstDeclFoldingMode folding)
{
	return parse_initializer_test_integer(context, p, true);
}

struct StringInitializerContext
{
	type_store::QualType qt;
	tree::CharLiteralKind kind;
	value::Value val;
}

fn parser_result::Result? parse_initializer_test_string(void* context, parser::Parser* p, bool eval)
{
	if (p.at_eof()) return parser::PARSING_FAILED~;
	tokens::TokenIndex tok = p.tok_i;
	StringInitializerContext* literal = context;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.STRING_LITERAL_EXPR,
		.char_literal = { .literal_tok = tok, .qt = literal.qt, .kind = literal.kind } });
	p.advance();
	return { .node = node, .qt = literal.qt, .val = eval ? literal.val : value::NONE };
}

fn parser_result::Result? parse_initializer_test_mixed(void* context, parser::Parser* p, bool eval)
{
	if (p.is_at(tokenizer::TokenId.STRING_LITERAL) || p.is_at(tokenizer::TokenId.STRING_LITERAL_UTF_8) ||
		p.is_at(tokenizer::TokenId.STRING_LITERAL_UTF_16) || p.is_at(tokenizer::TokenId.STRING_LITERAL_UTF_32) ||
		p.is_at(tokenizer::TokenId.STRING_LITERAL_WIDE))
	{
		return parse_initializer_test_string(context, p, eval);
	}
	return parse_initializer_test_integer(context, p, eval);
}

fn void initializer_grammar_keeps_high_designators_sparse() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("initializer.c", "{ [999999] = 7 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.bind_initializer_parser(null, &parse_initializer_test_integer, &parse_initializer_test_ice);
		type_store::QualType incomplete = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.INCOMPLETE));
		parser_result::Result parsed = p.parse_initializer(incomplete)!!;
		tree::Node init = parsed.node.get(&p.tree);
		assert(init.kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(init.container_init.items.len == 2, "a sparse high index uses a value and one filler node");
		assert(init.container_init.container_qt.base(&comp).ty.array.len.len == 1000000);
		assert(init.container_init.items[0].get(&p.tree).array_filler.count == 999999);
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void initializer_grammar_parses_nested_designator_paths() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("nested-initializer.c", "{ .items[1].value = 7 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.bind_initializer_parser(null, &parse_initializer_test_integer, &parse_initializer_test_ice);

		type_store::RecordField[1] leaf_fields = { type_store::record_field(comp.intern_string("value"), type_store::INT) };
		type_store::RecordLayout layout = { .size_bits = 32, .field_alignment_bits = 32, .pointer_alignment_bits = 32, .required_alignment_bits = 8 };
		type_store::QualType leaf = comp.type_store.put(type_store::type_record(comp.intern_string("Leaf"), leaf_fields[..], layout, false));
		type_store::QualType leaves = comp.type_store.put(type_store::type_array(leaf, type_store::ArrayLenKind.FIXED, 2));
		type_store::RecordField[1] root_fields = { type_store::record_field(comp.intern_string("items"), leaves) };
		type_store::QualType root = comp.type_store.put(type_store::type_record(comp.intern_string("Root"), root_fields[..], layout, false));
		tree::Node parsed = p.parse_initializer(root)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.STRUCT_INIT_EXPR);
		tree::Node array = parsed.container_init.items[0].get(&p.tree);
		assert(array.kind == tree::NodeKind.ARRAY_INIT_EXPR && array.container_init.items.len == 2);
		tree::Node item = array.container_init.items[1].get(&p.tree);
		assert(item.kind == tree::NodeKind.STRUCT_INIT_EXPR);
		tree::Node value_node = item.container_init.items[0].get(&p.tree);
		assert(value_node.kind == tree::NodeKind.INT_LITERAL);
		assert(p.tree.tok_slice(value_node.literal.literal_tok) == "7");
		assert(d.messages.len() == 0);

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void initializer_grammar_elides_braces_across_nested_arrays() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("elided-array-initializer.c", "{ 1, 2, 3, 4 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.bind_initializer_parser(null, &parse_initializer_test_integer, &parse_initializer_test_ice);
		type_store::QualType row = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 2));
		type_store::QualType matrix = comp.type_store.put(type_store::type_array(row, type_store::ArrayLenKind.FIXED, 2));

		tree::Node parsed = p.parse_initializer(matrix)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.ARRAY_INIT_EXPR && parsed.container_init.items.len == 2);
		for (usz i = 0; i < 2; i++)
		{
			tree::Node parsed_row = parsed.container_init.items[i].get(&p.tree);
			assert(parsed_row.kind == tree::NodeKind.ARRAY_INIT_EXPR && parsed_row.container_init.items.len == 2);
			for (usz j = 0; j < 2; j++)
			{
				tree::Node leaf = parsed_row.container_init.items[j].get(&p.tree);
				assert(leaf.kind == tree::NodeKind.INT_LITERAL);
				String expected = i == 0 ? (j == 0 ? "1" : "2") : (j == 0 ? "3" : "4");
				assert(p.tree.tok_slice(leaf.literal.literal_tok) == expected);
			}
		}
		assert(d.messages.len() == 0);

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void initializer_grammar_elided_scalar_override_diagnostic_order() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("elided-override-initializer.c", "{ 1, .pair.first = 3 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.bind_initializer_parser(null, &parse_initializer_test_integer, &parse_initializer_test_ice);

		type_store::RecordField[2] pair_fields = {
			type_store::record_field(comp.intern_string("first"), type_store::INT),
			type_store::record_field(comp.intern_string("second"), type_store::INT),
		};
		type_store::RecordLayout layout = { .size_bits = 64, .field_alignment_bits = 32, .pointer_alignment_bits = 32, .required_alignment_bits = 8 };
		type_store::QualType pair = comp.type_store.put(type_store::type_record(comp.intern_string("Pair"), pair_fields[..], layout, false));
		type_store::RecordField[2] root_fields = {
			type_store::record_field(comp.intern_string("pair"), pair),
			type_store::record_field(comp.intern_string("tail"), type_store::INT),
		};
		type_store::QualType root = comp.type_store.put(type_store::type_record(comp.intern_string("Root"), root_fields[..], layout, false));

		tree::Node parsed = p.parse_initializer(root)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.STRUCT_INIT_EXPR && parsed.container_init.items.len == 2);
		tree::Node parsed_pair = parsed.container_init.items[0].get(&p.tree);
		tree::Node first = parsed_pair.container_init.items[0].get(&p.tree);
		assert(first.kind == tree::NodeKind.INT_LITERAL && p.tree.tok_slice(first.literal.literal_tok) == "3");
		assert(d.messages.len() == 2);
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[0].text == "initializer overrides previous initialization");
		assert(d.messages[1].kind == diagnostics::MessageKind.NOTE);
		assert(d.messages[1].text == "previous initialization");

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void initializer_grammar_range_and_duplicate_override_semantics() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("range-initializer.c", "{ [1 ... 3] = 7, [1 ... 3] = 999999 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.bind_initializer_parser(null, &parse_initializer_test_integer, &parse_initializer_test_ice);
		type_store::QualType array_type = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 5));
		tree::Node parsed = p.parse_initializer(array_type)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(parsed.container_init.items.len == 5, "the range fills each selected element in order");
		assert(parsed.container_init.items[0].get(&p.tree).kind == tree::NodeKind.ARRAY_FILLER_EXPR);
		assert(parsed.container_init.items[0].get(&p.tree).array_filler.count == 1);
		for (usz i = 1; i <= 3; i++)
		{
			tree::Node selected = parsed.container_init.items[i].get(&p.tree);
			assert(selected.kind == tree::NodeKind.INT_LITERAL);
			assert(p.tree.tok_slice(selected.literal.literal_tok) == "999999");
		}
		assert(parsed.container_init.items[4].get(&p.tree).kind == tree::NodeKind.ARRAY_FILLER_EXPR);
		assert(parsed.container_init.items[4].get(&p.tree).array_filler.count == 1);
		assert(d.messages.len() == 2, "overrides emit the new-initializer warning and previous-initializer note");

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void sparse_init_list_is_sorted_and_nested() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		init_list::InitList il;
		il.init(&ta);
		il.tok = 11;

		// Insert out of order, then revisit an existing index. find() must keep
		// the list sorted and return the same child without duplicating it.
		il.find(9).node = ((NodeIndex)90).pack();
		il.find(2).node = ((NodeIndex)20).pack();
		il.find(5).find(3).node = ((NodeIndex)53).pack();
		il.find(2).node = ((NodeIndex)21).pack();

		assert(il.items.len() == 3);
		assert(il.items[0].index == 2 && il.items[0].child.node.unwrap() == (NodeIndex)21);
		assert(il.items[1].index == 5 && il.items[1].child.items.len() == 1);
		assert(il.items[1].child.items[0].index == 3);
		assert(il.items[1].child.items[0].child.node.unwrap() == (NodeIndex)53);
		assert(il.items[2].index == 9 && il.items[2].child.node.unwrap() == (NodeIndex)90);

		il.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void inferred_array_length_and_sparse_fillers() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.tok_i = 9;

		type_store::QualType incomplete = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.INCOMPLETE));
		init_list::InitList il;
		il.init(&ta);
		il.tok = 3;
		NodeIndex first = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .literal_tok = 4, .qt = type_store::INT } });
		NodeIndex last = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .literal_tok = 8, .qt = type_store::INT } });
		il.find(0).node = first.pack();
		il.find(4).node = last.pack();

		NodeIndex converted = p.convert_init_list(il, incomplete);
		tree::Node node = converted.get(&p.tree);
		assert(node.kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(node.container_init.items.len == 3, "two values and one gap filler are emitted");
		assert(node.container_init.container_qt.base(&comp).ty.array.len.kind == type_store::ArrayLenKind.FIXED);
		assert(node.container_init.container_qt.base(&comp).ty.array.len.len == 5, "incomplete array length follows the greatest populated index");
		assert(node.container_init.items[0] == first);
		tree::Node filler = node.container_init.items[1].get(&p.tree);
		assert(filler.kind == tree::NodeKind.ARRAY_FILLER_EXPR);
		assert(filler.array_filler.count == 3 && filler.array_filler.last_tok == 8);
		assert(node.container_init.items[2] == last);

		type_store::QualType fixed = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 8));
		tree::Node fixed_init = p.convert_init_list(il, fixed).get(&p.tree);
		assert(fixed_init.container_init.items.len == 4);
		assert(fixed_init.container_init.items[0] == first && fixed_init.container_init.items[2] == last);
		assert(fixed_init.container_init.items[1].get(&p.tree).array_filler.count == 3);
		assert(fixed_init.container_init.items[3].get(&p.tree).array_filler.count == 3, "fixed array trailing elements are represented by a filler");

		// A populated index beyond a fixed bound is ignored when converting,
		// while the gap before an in-range sparse value is still filled.
		init_list::InitList bounded;
		bounded.init(&ta);
		bounded.find(7).node = last.pack();
		bounded.find(8).node = first.pack();
		tree::Node bounded_init = p.convert_init_list(bounded, fixed).get(&p.tree);
		assert(bounded_init.container_init.items.len == 2);
		assert(bounded_init.container_init.items[0].get(&p.tree).array_filler.count == 7);
		assert(bounded_init.container_init.items[1] == last);

		// Empty sparse input completes an incomplete array to length zero.
		init_list::InitList empty;
		empty.init(&ta);
		tree::Node empty_init = p.convert_init_list(empty, incomplete).get(&p.tree);
		assert(empty_init.container_init.items.len == 0);
		assert(empty_init.container_init.container_qt.base(&comp).ty.array.len.kind == type_store::ArrayLenKind.FIXED);
		assert(empty_init.container_init.container_qt.base(&comp).ty.array.len.len == 0);

		il.free();
		bounded.free();
		empty.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void union_active_member_and_compound_literal_fields() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		parser::Parser p;
		p.init(&pp, {});

		type_store::RecordField[2] fields = {
			type_store::record_field(comp.intern_string("small"), type_store::INT),
			type_store::record_field(comp.intern_string("large"), type_store::LONG),
		};
		type_store::RecordLayout layout = { .size_bits = 64, .field_alignment_bits = 64, .pointer_alignment_bits = 64, .required_alignment_bits = 8 };
		type_store::QualType union_qt = comp.type_store.put(type_store::type_record(comp.intern_string("Choice"), fields[..], layout, true));
		NodeIndex value = p.tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .literal_tok = 6, .qt = type_store::LONG } });
		init_list::InitList il;
		il.init(&ta);
		il.tok = 5;
		il.find(1).node = value.pack();

		NodeIndex union_node = p.convert_init_list(il, union_qt);
		tree::Node union_init = union_node.get(&p.tree);
		assert(union_init.kind == tree::NodeKind.UNION_INIT_EXPR);
		assert(union_init.union_init.field_index == 1);
		assert(union_init.union_init.initializer.unwrap() == value);

		NodeIndex literal = p.compound_literal_node(2, union_qt, union_node, tree::CompoundLiteralStorageClass.STATIC, true);
		tree::Node compound = literal.get(&p.tree);
		assert(compound.kind == tree::NodeKind.COMPOUND_LITERAL_EXPR);
		assert(compound.compound_literal.l_paren_tok == 2);
		assert(compound.compound_literal.qt == union_qt);
		assert(compound.compound_literal.initializer == union_node);
		assert(compound.compound_literal.storage_class == tree::CompoundLiteralStorageClass.STATIC);
		assert(compound.compound_literal.thread_local);

		il.free();
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void brace_elision_fills_nested_array_fields_in_order() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("brace-elision.c", "{ 1, 3, 7, 999999 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		p.bind_initializer_parser(null, &parse_initializer_test_integer, &parse_initializer_test_ice);

		type_store::QualType pair_array = comp.type_store.put(type_store::type_array(type_store::INT, type_store::ArrayLenKind.FIXED, 2));
		type_store::RecordField[2] fields = {
			type_store::record_field(comp.intern_string("values"), pair_array),
			type_store::record_field(comp.intern_string("tail"), type_store::INT),
		};
		type_store::RecordLayout layout = { .size_bits = 96, .field_alignment_bits = 32, .pointer_alignment_bits = 32, .required_alignment_bits = 8 };
		type_store::QualType record = comp.type_store.put(type_store::type_record(comp.intern_string("Nested"), fields[..], layout, false));

		tree::Node parsed = p.parse_initializer(record)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.STRUCT_INIT_EXPR);
		assert(parsed.container_init.items.len == 2);
		tree::Node values = parsed.container_init.items[0].get(&p.tree);
		assert(values.kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(values.container_init.items.len == 2, "the first two expressions fill the array field");
		assert(p.tree.tok_slice(values.container_init.items[0].get(&p.tree).literal.literal_tok) == "1");
		assert(p.tree.tok_slice(values.container_init.items[1].get(&p.tree).literal.literal_tok) == "3");
		tree::Node tail = parsed.container_init.items[1].get(&p.tree);
		assert(tail.kind == tree::NodeKind.INT_LITERAL);
		assert(p.tree.tok_slice(tail.literal.literal_tok) == "7", "brace elision advances to the following record field after the array is full");
		assert(d.messages.len() == 1, "only the first excess expression is diagnosed");
		assert(d.messages[0].text == "excess elements in struct initializer");

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void direct_string_initializer_preserves_inferred_bound_and_null_rules() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		type_store::QualType literal_qt = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
		StringInitializerContext literal = { .qt = literal_qt, .kind = tree::CharLiteralKind.ASCII,
			.val = value::intern(&comp, { .tag = BYTES, .bytes = "abc\0" }) };
		type_store::QualType incomplete = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.INCOMPLETE));
		Source inferred_src = comp.add_source_from_buffer("inferred-string-initializer.c", "\"abc\"")!!;
		Preprocessor inferred_pp;
		inferred_pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs inferred_eof = inferred_pp.preprocess(inferred_src)!!;
		inferred_pp.add_token(inferred_eof)!!;
		parser::Parser inferred_parser;
		inferred_parser.init(&inferred_pp, {});
		inferred_parser.bind_finalized_tokens();
		inferred_parser.bind_initializer_parser(&literal, &parse_initializer_test_string, &parse_initializer_test_ice);
		parser_result::Result inferred = inferred_parser.parse_initializer(incomplete)!!;
		assert(inferred.qt.get(&comp, type_store::TypeTag.ARRAY)!!.array.len.len == 4,
			"the inferred array bound includes its terminating null code unit");
		assert(inferred.node.get(&inferred_parser.tree).kind == tree::NodeKind.STRING_LITERAL_EXPR);
		assert(inferred_parser.tree.value_of(inferred.node)!!.opt_ref == literal.val.opt_ref);
		assert(d.messages.len() == 0);
		inferred_parser.free();
		inferred_pp.free();

		type_store::QualType exact = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 3));
		Source exact_src = comp.add_source_from_buffer("exact-string-initializer.c", "\"abc\"")!!;
		Preprocessor exact_pp;
		exact_pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs exact_eof = exact_pp.preprocess(exact_src)!!;
		exact_pp.add_token(exact_eof)!!;
		parser::Parser exact_parser;
		exact_parser.init(&exact_pp, {});
		exact_parser.bind_finalized_tokens();
		exact_parser.bind_initializer_parser(&literal, &parse_initializer_test_string, &parse_initializer_test_ice);
		exact_parser.parse_initializer(exact)!!;
		assert(d.messages.len() == 0, "the target may omit only the final null code unit");
		exact_parser.free();
		exact_pp.free();

		type_store::QualType too_short = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 2));
		Source short_src = comp.add_source_from_buffer("short-string-initializer.c", "\"abc\"")!!;
		Preprocessor short_pp;
		short_pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs short_eof = short_pp.preprocess(short_src)!!;
		short_pp.add_token(short_eof)!!;
		parser::Parser short_parser;
		short_parser.init(&short_pp, {});
		short_parser.bind_finalized_tokens();
		short_parser.bind_initializer_parser(&literal, &parse_initializer_test_string, &parse_initializer_test_ice);
		short_parser.parse_initializer(too_short)!!;
		assert(d.messages.len() == 1);
		assert(d.messages[0].text == "initializer-string for char array is too long");
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		short_parser.free();
		short_pp.free();

		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void string_initializer_preserves_utf16_and_rejects_incompatible_encoding() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		type_store::init_named_types(&comp);
		type_store::QualType u16 = comp.type_store.uint_least16_t;
		type_store::QualType literal_qt = comp.type_store.put(type_store::type_array(u16, type_store::ArrayLenKind.FIXED, 3));
		StringInitializerContext literal = { .qt = literal_qt, .kind = tree::CharLiteralKind.UTF16,
			.val = value::intern(&comp, { .tag = BYTES, .bytes = (char[]){ 'a', 0, 'b', 0, 0, 0 } }) };
		type_store::QualType target = comp.type_store.put(type_store::type_array(u16, type_store::ArrayLenKind.FIXED, 2));
		Source compatible_src = comp.add_source_from_buffer("utf16-string-initializer.c", "u\"ab\"")!!;
		Preprocessor compatible_pp;
		compatible_pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs compatible_eof = compatible_pp.preprocess(compatible_src)!!;
		compatible_pp.add_token(compatible_eof)!!;
		parser::Parser compatible_parser;
		compatible_parser.init(&compatible_pp, {});
		compatible_parser.bind_finalized_tokens();
		compatible_parser.bind_initializer_parser(&literal, &parse_initializer_test_string, &parse_initializer_test_ice);
		parser_result::Result compatible = compatible_parser.parse_initializer(target)!!;
		tree::Node compatible_node = compatible.node.get(&compatible_parser.tree);
		assert(compatible_node.kind == tree::NodeKind.STRING_LITERAL_EXPR);
		assert(compatible_node.char_literal.kind == tree::CharLiteralKind.UTF16);
		assert(compatible.qt.eql(literal_qt, &comp), "the source encoding and its null-terminated bound are retained");
		assert(d.messages.len() == 0);
		compatible_parser.free();
		compatible_pp.free();

		type_store::QualType char_array = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 2));
		Source incompatible_src = comp.add_source_from_buffer("incompatible-string-initializer.c", "u\"ab\"")!!;
		Preprocessor incompatible_pp;
		incompatible_pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs incompatible_eof = incompatible_pp.preprocess(incompatible_src)!!;
		incompatible_pp.add_token(incompatible_eof)!!;
		parser::Parser incompatible_parser;
		incompatible_parser.init(&incompatible_pp, {});
		incompatible_parser.bind_finalized_tokens();
		incompatible_parser.bind_initializer_parser(&literal, &parse_initializer_test_string, &parse_initializer_test_ice);
		incompatible_parser.parse_initializer(char_array)!!;
		assert(d.messages.len() == 1);
		assert(d.messages[0].text.starts_with("cannot initialize array of type"));
		assert(d.messages[0].kind == diagnostics::MessageKind.ERROR);
		incompatible_parser.free();
		incompatible_pp.free();

		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void brace_elision_accepts_string_array_subobject() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("elided-string-initializer.c", "{ \"abc\", 7 }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		type_store::QualType string_qt = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
		StringInitializerContext literal = { .qt = string_qt, .kind = tree::CharLiteralKind.ASCII,
			.val = value::intern(&comp, { .tag = BYTES, .bytes = "abc\0" }) };
		p.bind_initializer_parser(&literal, &parse_initializer_test_mixed, &parse_initializer_test_ice);
		type_store::QualType chars = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 3));
		type_store::RecordField[2] fields = {
			type_store::record_field(comp.intern_string("text"), chars),
			type_store::record_field(comp.intern_string("tail"), type_store::INT),
		};
		type_store::RecordLayout layout = { .size_bits = 128, .field_alignment_bits = 32, .pointer_alignment_bits = 32, .required_alignment_bits = 8 };
		type_store::QualType record = comp.type_store.put(type_store::type_record(comp.intern_string("TextAndTail"), fields[..], layout, false));
		tree::Node parsed = p.parse_initializer(record)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.STRUCT_INIT_EXPR && parsed.container_init.items.len == 2);
		tree::Node text = parsed.container_init.items[0].get(&p.tree);
		assert(text.kind == tree::NodeKind.STRING_LITERAL_EXPR);
		assert(text.char_literal.kind == tree::CharLiteralKind.ASCII);
		tree::Node tail = parsed.container_init.items[1].get(&p.tree);
		assert(tail.kind == tree::NodeKind.INT_LITERAL && p.tree.tok_slice(tail.literal.literal_tok) == "7");
		assert(d.messages.len() == 0);

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void brace_elision_does_not_replace_array_elements_with_later_string() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("elided-string-after-element.c", "{ 1, \"abc\" }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		type_store::QualType string_qt = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
		StringInitializerContext literal = { .qt = string_qt, .kind = tree::CharLiteralKind.ASCII,
			.val = value::intern(&comp, { .tag = BYTES, .bytes = "abc\0" }) };
		p.bind_initializer_parser(&literal, &parse_initializer_test_mixed, &parse_initializer_test_ice);
		type_store::QualType target = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));

		tree::Node parsed = p.parse_initializer(target)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.ARRAY_INIT_EXPR);
		assert(parsed.container_init.items.len == 3, "the initialized elements remain before the omitted-element filler");
		tree::Node first = parsed.container_init.items[0].get(&p.tree);
		assert(first.kind == tree::NodeKind.CAST);
		tree::Node first_value = first.cast.operand.get(&p.tree);
		assert(first_value.kind == tree::NodeKind.INT_LITERAL);
		assert(p.tree.tok_slice(first_value.literal.literal_tok) == "1", "the earlier brace-elided element is retained");
		tree::Node second = parsed.container_init.items[1].get(&p.tree);
		assert(second.kind == tree::NodeKind.CAST);
		assert(second.cast.kind == tree::CastKind.POINTER_TO_INT, "the later string is treated as the next scalar element");
		assert(d.messages.len() == 1);
		assert(d.messages[0].text.starts_with("implicit pointer to integer conversion"));

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void brace_elision_does_not_replace_initialized_char_array_with_string() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("elided-char-array-override.c", "{ 1, \"bc\" }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		type_store::QualType string_qt = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 3));
		StringInitializerContext literal = { .qt = string_qt, .kind = tree::CharLiteralKind.ASCII,
			.val = value::intern(&comp, { .tag = BYTES, .bytes = "bc\0" }) };
		p.bind_initializer_parser(&literal, &parse_initializer_test_mixed, &parse_initializer_test_ice);
		type_store::QualType chars = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 1));

		tree::Node parsed = p.parse_initializer(chars)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.ARRAY_INIT_EXPR && parsed.container_init.items.len == 1);
		tree::Node first = parsed.container_init.items[0].get(&p.tree);
		assert(first.kind == tree::NodeKind.CAST);
		tree::Node first_value = first.cast.operand.get(&p.tree);
		assert(first_value.kind == tree::NodeKind.INT_LITERAL && p.tree.tok_slice(first_value.literal.literal_tok) == "1");
		assert(d.messages.len() == 1);
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[0].text == "excess elements in array initializer");

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void brace_elision_replaces_equal_nested_array_subobject_in_order() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("nested-array-override.c", "{ 1, \"abc\" }")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING, preprocessor::BUILTINS)!!;
		TokenWithExpansionLocs eof = pp.preprocess(src)!!;
		pp.add_token(eof)!!;
		parser::Parser p;
		p.init(&pp, {});
		p.bind_finalized_tokens();
		type_store::QualType chars = comp.type_store.put(type_store::type_array(type_store::CHAR, type_store::ArrayLenKind.FIXED, 4));
		StringInitializerContext literal = { .qt = chars, .kind = tree::CharLiteralKind.ASCII,
			.val = value::intern(&comp, { .tag = BYTES, .bytes = "abc\0" }) };
		p.bind_initializer_parser(&literal, &parse_initializer_test_mixed, &parse_initializer_test_ice);
		type_store::RecordField[1] fields = { type_store::record_field(comp.intern_string("text"), chars) };
		type_store::RecordLayout layout = { .size_bits = 128, .field_alignment_bits = 32, .pointer_alignment_bits = 32, .required_alignment_bits = 8 };
		type_store::QualType record = comp.type_store.put(type_store::type_record(comp.intern_string("Text"), fields[..], layout, false));

		tree::Node parsed = p.parse_initializer(record)!!.node.get(&p.tree);
		assert(parsed.kind == tree::NodeKind.STRUCT_INIT_EXPR && parsed.container_init.items.len == 1);
		tree::Node text = parsed.container_init.items[0].get(&p.tree);
		assert(text.kind == tree::NodeKind.STRING_LITERAL_EXPR, "an exact array expression initializes the selected nested array field");
		assert(text.char_literal.kind == tree::CharLiteralKind.ASCII);
		assert(d.messages.len() == 2, "replacing the nested field reports the override and its previous location");
		assert(d.messages[0].text == "initializer overrides previous initialization");
		assert(d.messages[1].text == "previous initialization");

		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	assert(ta.allocation_count() == 0);
}
