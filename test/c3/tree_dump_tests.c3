// AST dump smoke checks. Format expectations are source-derived from
// src/aro/Tree.zig; no Zig executable was run.
module tree_dump_tests;
import aro::compilation, aro::tree, aro::diagnostics;
import std::core::mem::allocators, std::core::dstring;

fn void empty_tree_dump_is_empty() @test
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
			DString output;
			output.init(ta);
			Terminal term = { .writer = &output, .mode = diagnostics::NO_COLOR };
		tree.dump(term)!!;
			assert(output.str_view().len == 0);
			output.free();
			tree.free();
		}
		comp.free();
	}
	assert(ta.allocation_count() == 0);
}
