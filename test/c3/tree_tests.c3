// Storage and handle checks for aro::tree. Expected tag and node values are
// source-derived from src/aro/Tree.zig; no Zig executable was run.
module tree_tests;
import aro::compilation, aro::tree, aro::type_store;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn void empty_decl_round_trip_and_growth() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		{
			Tree tree;
			tree.init(&comp, {});
			NodeIndex first = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = 0 } });
			check(first, 0);
			check(first.tag(&tree), NodeTag.EMPTY_DECL);
			Node got = first.get(&tree);
			check(got.kind, NodeKind.EMPTY_DECL);
			check(got.empty_decl.semicolon, 0);
			NodeIndex[2] compact_fields = { first, first };
			NodeIndex compact = tree.add_node({ .kind = NodeKind.STRUCT_DECL, .container_decl = { .name_or_kind_tok = 0, .container_qt = type_store::VOID, .fields = compact_fields[..] } });
			check(compact.tag(&tree), NodeTag.STRUCT_DECL_TWO);
			check(compact.get(&tree).container_decl.fields.len, 2);
			NodeIndex[3] long_fields = { first, first, first };
			NodeIndex extended = tree.add_node({ .kind = NodeKind.STRUCT_DECL, .container_decl = { .name_or_kind_tok = 0, .container_qt = type_store::VOID, .fields = long_fields[..] } });
			check(extended.tag(&tree), NodeTag.STRUCT_DECL);
			for (uint i = 0; i < 256; i++)
			{
				NodeIndex added = tree.add_node({ .kind = NodeKind.EMPTY_DECL, .empty_decl = { .semicolon = i } });
				check(added, i + 1);
			}
			check(first.get(&tree).kind, NodeKind.EMPTY_DECL);
			check(first.get(&tree).empty_decl.semicolon, 0);
			Node decoded = extended.get(&tree);
			check(decoded.container_decl.fields.len, 3);
			check(decoded.container_decl.fields[2], first);
			tree.free();
		}
		comp.free();
	}
	check(ta.allocation_count(), 0);
}
