// Direct AST storage tests for initializer nodes. These exercise the tree
// representation used after parsing; they do not claim that declaration
// initializer grammar is wired into the C3 parser yet.
module initializer_tree_tests;
import aro::compilation, aro::tree, aro::type_store;

fn void sparse_array_initializer_round_trip() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			tree::Tree tree;
			tree.init(&comp, {});
			type_store::NodeIndex first = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			type_store::NodeIndex last = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .literal_tok = 2, .qt = type_store::INT } });
			type_store::NodeIndex filler = tree.add_node({ .kind = tree::NodeKind.ARRAY_FILLER_EXPR, .array_filler = { .last_tok = 8, .qt = type_store::INT, .count = 0x1_0000_0003 } });
			type_store::NodeIndex[] items = { first, filler, last };
			type_store::NodeIndex init = tree.add_node({ .kind = tree::NodeKind.ARRAY_INIT_EXPR, .container_init = { .l_brace_tok = 3, .container_qt = type_store::INT, .items = items[..] } });
			assert(init.tag(&tree) == tree::NodeTag.ARRAY_INIT_EXPR, "three initializer entries use the extended representation");
			tree::Node got = init.get(&tree);
			assert(got.container_init.items.len == 3);
			assert(got.container_init.items[0] == first && got.container_init.items[1] == filler && got.container_init.items[2] == last);
			assert(filler.get(&tree).array_filler.count == 0x1_0000_0003, "filler count preserves high and low words");
			tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void omitted_record_field_default_round_trip() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			tree::Tree tree;
			tree.init(&comp, {});
			type_store::NodeIndex value = tree.add_node({ .kind = tree::NodeKind.INT_LITERAL, .literal = { .literal_tok = 1, .qt = type_store::INT } });
			type_store::NodeIndex omitted = tree.add_node({ .kind = tree::NodeKind.DEFAULT_INIT_EXPR, .default_init = { .last_tok = 9, .qt = type_store::INT } });
			assert(omitted.get(&tree).is_implicit());
			type_store::NodeIndex[] fields = { value, omitted };
			type_store::NodeIndex init = tree.add_node({ .kind = tree::NodeKind.STRUCT_INIT_EXPR, .container_init = { .l_brace_tok = 3, .container_qt = type_store::VOID, .items = fields[..] } });
			tree::Node got = init.get(&tree);
			assert(got.container_init.items.len == 2);
			assert(got.container_init.items[1] == omitted);
			tree::Node default_node = got.container_init.items[1].get(&tree);
			assert(default_node.kind == tree::NodeKind.DEFAULT_INIT_EXPR);
			assert(default_node.default_init.last_tok == 9);
			assert(default_node.default_init.qt == type_store::INT);
			tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}
