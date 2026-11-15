// Focused tests for sparse initializer child storage in aro::init_list.
module init_list_tests;
import aro::init_list;

fn void sparse_children_are_sorted_and_reused() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		init_list::InitList root;
		root.init(&ta);
		init_list::InitList* high = root.find(1_000_000_000);
		high.tok = 17;
		init_list::InitList* low = root.find(3);
		low.tok = 11;
		init_list::InitList* middle = root.find(128);
		middle.tok = 14;

		assert(root.items.len() == 3, "sparse storage should contain only populated indexes");
		assert(root.items[0].index == 3 && root.items[1].index == 128 && root.items[2].index == 1_000_000_000,
			"out-of-order insertions should remain sorted");
		assert(root.find(128).tok == 14, "finding an existing child should preserve its data");
		assert(root.items.len() == 3, "finding an existing index must not duplicate it");
		root.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void nested_sparse_children_remain_independent() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		init_list::InitList root;
		root.init(&ta);
		root.find(7).find(4).tok = 21;
		root.find(7).find(99).tok = 22;
		root.find(100_000).find(2).tok = 23;

		assert(root.items.len() == 2);
		assert(root.items[0].index == 7 && root.items[1].index == 100_000);
		init_list::InitList* seven = root.find(7);
		assert(seven.items.len() == 2);
		assert(seven.items[0].index == 4 && seven.items[0].child.tok == 21);
		assert(seven.items[1].index == 99 && seven.items[1].child.tok == 22);
		assert(root.find(100_000).find(2).tok == 23);
		root.free();
	}
	assert(ta.allocation_count() == 0, "free should recursively release nested lists");
}

// Port of Zig test "basic usage": build the chain find(0)...find(4), then repeat
// the traversal. The Zig version reruns it with a failing allocator; here an
// unchanged allocation count shows the second pass allocated nothing.
fn void basic_usage_zig_test() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		init_list::InitList root;
		root.init(&ta);
		{
			init_list::InitList* item = root.find(0);
			for (ulong i = 1; i < 5; i++) item = item.find(i);
		}
		sz after_first = ta.allocation_count();
		assert(after_first > 0, "first traversal should allocate child storage");
		{
			init_list::InitList* item = root.find(0);
			for (ulong i = 1; i < 5; i++) item = item.find(i);
		}
		assert(ta.allocation_count() == after_first, "repeated traversal must reuse existing nodes without allocating");
		root.free();
	}
	assert(ta.allocation_count() == 0, "free should release every node of the basic usage chain");
}
