// Tests for aro::attribute_map (src/c3/attribute_map.c3).
// Expected payloads and compact layouts are source-derived from
// src/aro/Attribute/Map.zig; no Zig runtime parity is claimed.
module attribute_map_tests;
import aro::attribute, aro::attribute_map, aro::compilation, aro::target, aro::tokens, aro::tree, aro::type_store;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

fn Attribute attr(AttributeArgs args)
{
	return { .args = args, .syntax = GNU, .name = { .ns = GNU, .gnu = PACKED }, .tok = (tokens::TokenIndex)17 };
}

fn void compact_payload_round_trips() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		AttributeMap map;
		map.init(&ta);
		Attribute packed = attr({ .tag = PACKED });
		Attribute hot = attr({ .tag = HOT });
		AttrRef packed_ref = map.put(packed);
		AttrRef hot_ref = map.put(hot);
		assert(map.get(packed_ref).args.tag == PACKED);
		assert(map.get(hot_ref).args.tag == HOT);

		Attribute alignment = attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = true, .alignment = 32 } });
		AttrRef align_ref = map.put(alignment);
		Attribute decoded = map.get(align_ref);
		assert(decoded.args.tag == ALIGNMENT && decoded.args.alignment.has_alignment);
		check(decoded.args.alignment.alignment, 32);
		Attribute no_alignment = attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = false } });
		decoded = map.get(map.put(no_alignment));
		assert(decoded.args.tag == ALIGNMENT && !decoded.args.alignment.has_alignment);

		Attribute deprecated = attr({ .tag = DEPRECATED, .deprecated = { .has_msg = true, .msg = "old", .has_replacement = true, .replacement = "new" } });
		decoded = map.get(map.put(deprecated));
		assert(decoded.args.tag == DEPRECATED);
		assert(decoded.args.deprecated.has_msg && decoded.args.deprecated.msg == "old");
		assert(decoded.args.deprecated.has_replacement && decoded.args.deprecated.replacement == "new");
		Attribute deprecated_reason = attr({ .tag = DEPRECATED, .deprecated = { .has_msg = true, .msg = "legacy" } });
		assert(map.get(map.put(deprecated_reason)).args.deprecated.msg == "legacy");
		Attribute unavailable = attr({ .tag = UNAVAILABLE, .unavailable = { .has_msg = true, .msg = "unsupported" } });
		assert(map.get(map.put(unavailable)).args.unavailable.msg == "unsupported");
		Attribute warning = attr({ .tag = WARNING, .warning = "warn" });
		assert(map.get(map.put(warning)).args.warning == "warn");
		Attribute error = attr({ .tag = ERROR, .error_msg = "error" });
		assert(map.get(map.put(error)).args.error_msg == "error");
		Attribute warn_result = attr({ .tag = WARN_UNUSED_RESULT, .warn_unused_result = { .has_msg = true, .msg = "check" } });
		assert(map.get(map.put(warn_result)).args.warn_unused_result.msg == "check");

		Attribute nn = attr({ .tag = NONNULL, .nonnull = { (uint)2, (uint)5, (uint)9 } });
		AttrRef nn_ref = map.put(nn);
		decoded = map.get(nn_ref);
		check(decoded.args.nonnull.len, 3);
		check(decoded.args.nonnull[0], 2);
		check(decoded.args.nonnull[2], 9);
		Attribute nn_zero = attr({ .tag = NONNULL, .nonnull = {} });
		assert(map.get(map.put(nn_zero)).args.nonnull.len == 0);
		Attribute nn_one = attr({ .tag = NONNULL, .nonnull = { (uint)7 } });
		check(map.get(map.put(nn_one)).args.nonnull[0], 7);
		Attribute hidden = attr({ .tag = VISIBILITY, .visibility = HIDDEN });
		assert(map.get(map.put(hidden)).args.visibility == HIDDEN);
		Attribute cleanup = attr({ .tag = CLEANUP, .cleanup = { .function = (NodeIndex)23 } });
		check(map.get(map.put(cleanup)).args.cleanup.function, 23);

		Attribute section = attr({ .tag = SECTION, .section = "abcde" });
		AttrRef section_ref = map.put(section);
		decoded = map.get(section_ref);
		assert(decoded.args.tag == SECTION);
		assert(decoded.args.section == "abcde");
		// putString stores length followed by ceil(len / sizeof(uint)) words.
		uint section_data = map.attributes[(uint)section_ref].data;
		check(map.extra[section_data + 1], 5);
		check(map.extra.len() - section_data, 4); // token, length, two padded data words
		map.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn void declaration_queries_and_replacement() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		AttributeMap map;
		map.init(&ta);
		Attribute a = attr({ .tag = COLD });
		Attribute b = attr({ .tag = HOT });
		Attribute c = attr({ .tag = COLD });
		AttrRef[3] refs = { map.put(a), map.put(b), map.put(c) };
		NodeIndex node = (NodeIndex)4;
		map.set_decl_attrs(node, refs[..]);
		NodeOptIndex opt = node.pack();
		assert(map.has_attribute(opt, COLD));
		assert(map.has_attribute(opt, HOT));
		assert(!map.has_attribute(opt, PACKED));
		Attribute? last = map.get_attribute(opt, COLD);
		assert(@ok(last));
		assert(last!!.args.tag == COLD);
		assert(!@ok(map.get_attribute(opt, PACKED)));
		check(map.attrs(opt).len, 3);
		map.set_decl_attrs(node, refs[1..2]);
		check(map.attrs(opt).len, 1);
		assert(map.has_attribute(opt, HOT) && !map.has_attribute(opt, COLD));
		check(map.attrs(type_store::NODE_NULL).len, 0);
		map.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn void alignment_defaults_and_nested_typedefs() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		Compilation comp;
		comp.init(&ta);
		Target? parsed = target::parse_triple("x86_64-linux-gnu", target::host()!!);
		comp.target = parsed!!;
		// Tree node encode/decode is not part of this ticket. These hand-built
		// records exercise the type/map lookup against declaration indices.
		Tree tree = { .comp = &comp };
		tree.attr_map.init(&ta);
		AttributeMap* map = &tree.attr_map;
		NodeIndex inner_decl = (NodeIndex)1;
		NodeIndex outer_decl = (NodeIndex)2;
		NodeIndex default_decl = (NodeIndex)3;
		Attribute explicit_align = attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = true, .alignment = 16 } });
		Attribute default_align = attr({ .tag = ALIGNMENT, .alignment = { .has_alignment = false } });
		AttrRef[2] refs = { map.put(explicit_align), map.put(default_align) };
		map.set_decl_attrs(inner_decl, refs[..]);
		check(map.requested_alignment(inner_decl.pack(), &comp)!!, 16);
		AttrRef default_ref = map.put(default_align);
		map.set_decl_attrs(default_decl, { default_ref });
		check(map.requested_alignment(default_decl.pack(), &comp)!!, comp.target.default_alignment());

		QualType base = comp.type_store.put(type_store::type_typedef(type_store::INT, comp.intern_string("Inner"), inner_decl));
		QualType outer = comp.type_store.put(type_store::type_typedef(base, comp.intern_string("Outer"), outer_decl));
		assert(outer.get_attribute(&tree, ALIGNMENT)!!.args.tag == ALIGNMENT);
		assert(outer.has_attribute(&tree, ALIGNMENT));
		tree.attr_map.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
	ta.free();
}

fn void repeated_growth_and_destruction() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	{
		for (uint cycle = 0; cycle < 2; cycle++)
		{
			AttributeMap map;
			map.init(&ta);
			for (uint i = 0; i < 512; i++)
			{
				Attribute msg = attr({ .tag = WARNING, .warning = "a message that forces extra storage to grow repeatedly" });
				AttrRef ref = map.put(msg);
				assert(map.get(ref).args.warning == msg.args.warning);
				map.set_decl_attrs((NodeIndex)i, { ref });
			}
			check(map.attrs(((NodeIndex)511).pack()).len, 1);
			map.free();
		}
	}
	check(ta.allocation_count(), 0);
	ta.free();
}
