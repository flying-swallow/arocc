// Tests for aro::hideset (port of src/aro/Hideset.zig, plan 13.1).
// Expected orders and contents are source-derived from Hideset.zig (no Zig
// executable was run): union walks `a` in order and pushes each element not
// in `b` onto the front of `b`; intersection keeps the order of `b`;
// identity is the (source id, byte offset) pair, not the spelling.
module hideset_tests;
import aro::hideset, aro::source, aro::compilation, aro::diagnostics;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

// Byte offsets into BUF: foo@0 bar@4 baz@8 qux@12 foo@16 abcd@20.
const String BUF = "foo bar baz qux foo abcd";

<* Run the body with a compilation that holds BUF as a source; checks for leaks. *>
macro @with_hs(; @body(Hideset* hs, SourceId id))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		Source src = comp.add_source_from_buffer("hs.c", BUF)!!;
		Hideset hs;
		hs.init(&comp);
		@body(&hs, src.id);
		hs.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn Location at(SourceId id, uint offset, uint line = 1) => { .id = id, .byte_offset = offset, .line = line };

<* The byte offsets of the items of `list`, in list order (temp-allocated). *>
fn uint[] offsets(Hideset* hs, HidesetIndex list)
{
	uint[] out = mem::temp_array(uint, (sz)hs.len(list));
	usz n = 0;
	for (HidesetIndex i = list; i != hideset::NONE; i = hs.linked_list[(sz)i].next)
	{
		out[n++] = hs.linked_list[(sz)i].identifier.byte_offset;
	}
	return out;
}

fn void expect(Hideset* hs, HidesetIndex list, uint[] want)
{
	uint[] got = offsets(hs, list);
	check(got.len, want.len);
	foreach (i, w : want) check(got[i], w);
}

<* Build a list whose items are `offs` in order (3 bytes long, 4 at offset 20). *>
fn HidesetIndex build(Hideset* hs, SourceId id, uint[] offs)
{
	HidesetIndex head = hideset::NONE;
	for (usz i = offs.len; i > 0; i--)
	{
		uint o = offs[i - 1];
		head = hs.prepend(at(id, o), o == 20 ? 4 : 3, head);
	}
	return head;
}

fn void empty_list() @test
{
	@with_hs(; Hideset* hs, SourceId id)
	{
		check(hs.len(hideset::NONE), 0);
		assert(!hs.contains(hideset::NONE, "foo"));
		check(hs.get(at(id, 0)), hideset::NONE);
		check(hs.union_of(hideset::NONE, hideset::NONE), hideset::NONE);
		check(hs.intersection(hideset::NONE, hideset::NONE), hideset::NONE);
	};
}

fn void put_get_keyed_by_id_and_offset() @test
{
	@with_hs(; Hideset* hs, SourceId id)
	{
		HidesetIndex l = hs.prepend(at(id, 4), 3, hideset::NONE);
		hs.put(at(id, 8), l);
		check(hs.get(at(id, 8)), l);
		// The line is not part of the key.
		check(hs.get(at(id, 8, 7)), l);
		check(hs.get(at(id, 9)), hideset::NONE);
		SourceId other = { .index = id.index + 1 };
		check(hs.get(at(other, 8)), hideset::NONE);
		// put replaces.
		HidesetIndex l2 = hs.prepend(at(id, 0), 3, l);
		hs.put(at(id, 8), l2);
		check(hs.get(at(id, 8)), l2);
		hs.put(at(id, 8), hideset::NONE);
		check(hs.get(at(id, 8)), hideset::NONE);
	};
}

fn void prepend_shares_tail() @test
{
	@with_hs(; Hideset* hs, SourceId id)
	{
		HidesetIndex a = hs.prepend(at(id, 0), 3, hideset::NONE);
		check(a, 0);
		HidesetIndex b = hs.prepend(at(id, 4), 3, a);
		HidesetIndex c = hs.prepend(at(id, 8), 3, a);
		check(b, 1);
		check(c, 2);
		expect(hs, b, { 4, 0 });
		expect(hs, c, { 8, 0 });
		expect(hs, a, { 0 });
		check(hs.linked_list.len(), 3);
		check(hs.len(b), 2);
	};
}

fn void union_order_and_dedup() @test
{
	@with_hs(; Hideset* hs, SourceId id)
	{
		HidesetIndex a = build(hs, id, { 0, 4, 8 });
		HidesetIndex b = build(hs, id, { 4, 12 });
		check(hs.union_of(hideset::NONE, b), b);
		check(hs.union_of(a, hideset::NONE), a);

		sz before = hs.linked_list.len();
		HidesetIndex u = hs.union_of(a, b);
		// a's elements not in b, reversed, then b itself (shared, not copied).
		expect(hs, u, { 8, 0, 4, 12 });
		check(hs.linked_list.len(), before + 2);
		check(hs.linked_list[(sz)hs.linked_list[(sz)u].next].next, b);
		// Inputs unchanged.
		expect(hs, a, { 0, 4, 8 });
		expect(hs, b, { 4, 12 });

		// a subset of b: nothing copied, result is b.
		HidesetIndex sub = build(hs, id, { 12 });
		before = hs.linked_list.len();
		check(hs.union_of(sub, b), b);
		check(hs.linked_list.len(), before);

		// Identity is the location: "foo"@16 is distinct from "foo"@0.
		HidesetIndex u2 = hs.union_of(build(hs, id, { 16 }), build(hs, id, { 0 }));
		expect(hs, u2, { 16, 0 });

		// Duplicates inside `a` are not removed (Zig only checks against b).
		HidesetIndex u3 = hs.union_of(build(hs, id, { 0, 0 }), build(hs, id, { 4 }));
		expect(hs, u3, { 0, 0, 4 });

		// Union with itself is itself.
		check(hs.union_of(a, a), a);
	};
}

fn void intersection_order() @test
{
	@with_hs(; Hideset* hs, SourceId id)
	{
		HidesetIndex a = build(hs, id, { 0, 4, 8 });
		HidesetIndex b = build(hs, id, { 8, 12, 0 });
		check(hs.intersection(hideset::NONE, b), hideset::NONE);
		check(hs.intersection(a, hideset::NONE), hideset::NONE);

		sz before = hs.linked_list.len();
		HidesetIndex x = hs.intersection(a, b);
		// Order of b, freshly allocated nodes.
		expect(hs, x, { 8, 0 });
		check(hs.linked_list.len(), before + 2);
		check(x, before);
		expect(hs, a, { 0, 4, 8 });
		expect(hs, b, { 8, 12, 0 });

		// Disjoint: NONE, no nodes created.
		HidesetIndex d = build(hs, id, { 12, 16 });
		before = hs.linked_list.len();
		check(hs.intersection(a, d), hideset::NONE);
		check(hs.linked_list.len(), before);

		// Same spelling at another location is not the same identifier.
		check(hs.intersection(build(hs, id, { 0 }), build(hs, id, { 16 })), hideset::NONE);

		// Duplicates in b are kept; lengths are copied.
		HidesetIndex y = hs.intersection(build(hs, id, { 20 }), build(hs, id, { 20, 4, 20 }));
		expect(hs, y, { 20, 20 });
		check(hs.linked_list[(sz)y].len, 4);
		assert(hs.contains(y, "abcd"));
	};
}

fn void contains_by_spelling() @test
{
	@with_hs(; Hideset* hs, SourceId id)
	{
		HidesetIndex l = build(hs, id, { 4, 16, 20 });
		assert(hs.contains(l, "bar"));
		assert(hs.contains(l, "foo"));
		assert(hs.contains(l, "abcd"));
		assert(!hs.contains(l, "baz"));
		assert(!hs.contains(l, "fo"));
		assert(!hs.contains(l, "abc"));
		assert(!hs.contains(l, ""));
	};
}

fn void clear_and_reuse() @test
{
	@with_hs(; Hideset* hs, SourceId id)
	{
		HidesetIndex a = build(hs, id, { 0, 4 });
		hs.put(at(id, 0), a);
		hs.union_of(a, build(hs, id, { 8 }));
		hs.clear_retaining_capacity();
		check(hs.linked_list.len(), 0);
		check(hs.get(at(id, 0)), hideset::NONE);
		HidesetIndex b = build(hs, id, { 12 });
		check(b, 0);
		hs.put(at(id, 12), b);

		hs.clear_and_free();
		check(hs.linked_list.len(), 0);
		check(hs.get(at(id, 12)), hideset::NONE);
		HidesetIndex c = hs.intersection(build(hs, id, { 0, 4 }), build(hs, id, { 4 }));
		expect(hs, c, { 4 });
		hs.put(at(id, 4), c);
		check(hs.get(at(id, 4)), c);
	};
}

fn void no_leaks_over_repeated_use() @test
{
	for (int round = 0; round < 8; round++)
	{
		@with_hs(; Hideset* hs, SourceId id)
		{
			// Grow past the initial list/map capacities.
			HidesetIndex acc = hideset::NONE;
			for (uint i = 0; i < 100; i++)
			{
				HidesetIndex one = hs.prepend(at(id, i % 24), 0, hideset::NONE);
				acc = hs.union_of(one, acc);
				hs.put(at(id, 1000 + i), acc);
				hs.intersection(acc, one);
				if (i == 50)
				{
					if (round % 2 == 0)
					{
						hs.clear_retaining_capacity();
					}
					else
					{
						hs.clear_and_free();
					}
					acc = hideset::NONE;
				}
			}
			// Offsets 51..99 mod 24 after the reset: 24 distinct identifiers.
			check(hs.len(acc), 24);
		};
	}
}
