// Tests for aro::source, aro::string_interner and the source storage in
// aro::compilation. The add_source_from_buffer / carriage-return / BOM cases
// are ported from the `test` blocks at src/aro/Compilation.zig:2899 onward
// (expected values copied verbatim from the Zig source).
module source_tests;
import aro::source, aro::string_interner, aro::compilation, aro::diagnostics;
import std::core::mem::allocators, std::collections::list;

<* test::eq for slices; numeric values are compared as long (test::eq rejects int vs uint). *>
macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

// Every test runs its compilation on a tracking allocator and asserts that
// `Compilation.free` releases every allocation.
macro @tracked(; @body(Compilation* comp))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		@body(&comp);
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void check_add(String str, String expected, uint warning_count, uint[] splices)
{
	@tracked(; Compilation* comp)
	{
		Source src = comp.add_source_from_buffer("path", str)!!;
		check(src.buf, expected);
		check(src.buf.ptr[src.buf.len], 0);
		check(comp.warning_count(), warning_count);
		check(src.splice_locs.len, splices.len);
		foreach (i, s : splices) check(src.splice_locs[i], s);
	};
}

fn void add_source_from_buffer() @test
{
	check_add("ab\\\nc", "abc", 0, { 2 });
	check_add("ab\\\rc", "abc", 0, { 2 });
	check_add("ab\\\r\nc", "abc", 0, { 2 });
	check_add("ab\\ \nc", "abc", 1, { 2 });
	check_add("ab\\\t\nc", "abc", 1, { 2 });
	check_add("ab\\                     \t\nc", "abc", 1, { 2 });
	check_add("ab\\\r \nc", "ab \nc", 0, { 2 });
	check_add("ab\\\\\nc", "ab\\c", 0, { 3 });
	check_add("ab\\   \r\nc", "abc", 1, { 2 });
	check_add("ab\\ \\\nc", "ab\\ c", 0, { 4 });
	check_add("ab\\\r\\\nc", "abc", 0, { 2, 2 });
	check_add("ab\\  \rc", "abc", 1, { 2 });
	check_add("ab\\", "ab\\", 0, {});
	check_add("ab\\\\", "ab\\\\", 0, {});
	check_add("ab\\ ", "ab\\ ", 0, {});
	check_add("ab\\\n", "ab", 0, { 2 });
	check_add("ab\\\r\n", "ab", 0, { 2 });
	check_add("ab\\\r", "ab", 0, { 2 });

	// carriage return normalization
	check_add("ab\r", "ab\n", 0, {});
	check_add("ab\r\r", "ab\n\n", 0, {});
	check_add("ab\r\r\n", "ab\n\n", 0, {});
	check_add("ab\r\r\n\r", "ab\n\n\n", 0, {});
	check_add("\r\\", "\n\\", 0, {});
	check_add("\\\r\\", "\\", 0, { 0 });

	// extra: repeated splices, empty input
	check_add("a\\\n\\\n\\\nb", "ab", 0, { 1, 1, 1 });
	check_add("", "", 0, {});
}

// Replaces Zig's checkAllAllocationFailures: in the C3 port allocation failure
// panics (see CONVENTIONS.md), so instead check that repeated create/destroy
// cycles release every allocation.
fn void repeated_create_destroy() @test
{
	for (int round = 0; round < 50; round++)
	{
		@tracked(; Compilation* comp)
		{
			comp.add_source_from_buffer("path", "spliced\\\nbuffer\n")!!;
			comp.add_source_from_buffer("path", "non-spliced buffer\n")!!;
			comp.add_source_from_buffer("warn", "x\\ \ny\n")!!;
			comp.add_source_alias({ .index = 0 }, "alias.h", SYSTEM);
			comp.intern_string("hello");
		};
	}
}

fn void exhaustive_carriage_return_elimination() @test
{
	char[5] alphabet = { '\r', '\n', ' ', '\\', 'a' };
	sz alen = alphabet.len;
	char[5] buf;
	foreach (&b : buf) *b = alphabet[0];

	@tracked(; Compilation* comp)
	{
		uint source_count = 0;
		while (true)
		{
			// path == contents, as in the Zig test; the path is copied so `buf` may change.
			Source src = comp.add_source_from_buffer((String)buf[..], buf[..])!!;
			source_count++;
			foreach (c : src.buf) assert(c != '\r');

			bool all_last = true;
			foreach (c : buf) if (c != alphabet[alen - 1]) all_last = false;
			if (all_last) break;

			sz idx = index_of(&alphabet, buf[buf.len - 1]);
			buf[buf.len - 1] = alphabet[(idx + 1) % alen];
			sz j = buf.len - 1;
			for (; j > 0; j--)
			{
				idx = index_of(&alphabet, buf[j - 1]);
				if (buf[j] == alphabet[0])
				{
					buf[j - 1] = alphabet[(idx + 1) % alen];
				}
				else
				{
					break;
				}
			}
		}
		check(source_count, 3125); // 5^5
		check(comp.sources.len(), 3125);
	};
}

fn sz index_of(char[5]* alphabet, char c)
{
	foreach (i, a : *alphabet) if (a == c) return i;
	unreachable();
}

const String BOM = "\xEF\xBB\xBF";

fn void check_bom(String buf)
{
	@tracked(; Compilation* comp)
	{
		Source src = comp.add_source_from_buffer("file.c", buf)!!;
		String expected = buf.starts_with(BOM) ? buf[BOM.len..] : buf;
		check(src.buf, expected);
		check(src.buf.ptr[src.buf.len], 0);
	};
}

fn void ignore_bom_at_beginning_of_file() @test
{
	check_bom(BOM);
	check_bom(BOM +++ "x");
	check_bom("x" +++ BOM);
	check_bom(BOM +++ " ");
	check_bom(BOM +++ "\n");
	check_bom(BOM +++ "\\");

	check_bom("\xEF" +++ "x");
	check_bom("\xEF\xBB" +++ "x");
	check_bom("\xBB\xBF" +++ "x");
	check_bom("\xBF" +++ "x");
}

fn void bom_prefix_then_newline_truncates() @test
{
	// Zig: a partial BOM followed by \r, \n or whitespace stops normalization ("invalid utf-8").
	@tracked(; Compilation* comp)
	{
		check(comp.add_source_from_buffer("a", "\xEF\nrest")!!.buf, "\xEF");
		check(comp.add_source_from_buffer("b", "\xEF\xBB rest")!!.buf, "\xEF\xBB");
	};
}

fn void same_path_returns_existing_source() @test
{
	@tracked(; Compilation* comp)
	{
		Source a = comp.add_source_from_buffer("p.c", "one")!!;
		Source b = comp.add_source_from_buffer("p.c", "two")!!;
		check(a.id.index, b.id.index);
		check(b.buf, "one");
		check(comp.sources.len(), 1);
	};
}

fn void owned_buffer_is_adopted() @test
{
	@tracked(; Compilation* comp)
	{
		String raw = "a\r\nb";
		char* p = alloc::malloc(comp.gpa, raw.len + 1);
		mem::copy(p, raw.ptr, raw.len);
		p[raw.len] = 0;
		Source src = comp.add_source_from_owned_buffer("own.c", p[:raw.len], SYSTEM)!!;
		check(src.buf, "a\nb");
		check(src.buf.ptr[src.buf.len], 0);
		assert(src.kind == SYSTEM);
		// caller keeps ownership of path: path bytes are a copy
		check(src.path, "own.c");
	};
}

fn void stable_ids_and_no_dangling_after_growth() @test
{
	@tracked(; Compilation* comp)
	{
		Source first = comp.add_source_from_buffer("first.c", "int x;\\\n int y;\n")!!;
		check(first.id.index, 0);
		assert(!first.id.is_alias);
		char* buf_ptr = first.buf.ptr;
		char* path_ptr = first.path.ptr;
		uint* splice_ptr = first.splice_locs.ptr;

		// Grow sources, path table and interner well past their initial capacity.
		for (int i = 0; i < 2000; i++)
		{
			String path = string::tformat("gen_%d.c", i);
			Source s = comp.add_source_from_buffer(path, "void f(void);\n")!!;
			check(s.id.index, (uint)i + 1);
		}

		Source again = comp.get_source(first.id);
		assert(again.buf.ptr == buf_ptr);
		assert(again.path.ptr == path_ptr);
		assert(again.splice_locs.ptr == splice_ptr);
		// The value captured before growth still reads valid memory.
		check(first.buf, "int x; int y;\n");
		check(first.path, "first.c");
		check(first.splice_locs[0], 6);

		Source found = comp.find_source("gen_1234.c")!!;
		check(found.id.index, 1235);
		assert(@catch(comp.find_source("missing.c")) == string_interner::NOT_FOUND);
	};
}

fn void sentinels() @test
{
	check(source::UNUSED_ID.index, 0x7FFF_FFFF);
	check(source::GENERATED_ID.index, 0x7FFF_FFFE);
	check((uint)source::UNUSED_ID, 0x7FFF_FFFF);
	check((uint)source::GENERATED_ID, 0x7FFF_FFFE);
	assert(source::UNUSED_ID.is_unused());
	assert(source::GENERATED_ID.is_generated());
	SourceId alias_id = { .index = 0x7FFF_FFFF, .is_alias = true };
	assert(!alias_id.is_unused());
	check((uint)alias_id, 0xFFFF_FFFF);
	check((uint)string_interner::EMPTY, uint::max);
	// c3c 0.8.5 segfaults on `source::UNUSED_LOCATION.id == ...` (bitstruct member of a
	// constant struct in a comparison); copying to a local first works.
	Location unused_loc = source::UNUSED_LOCATION;
	assert(unused_loc.id == source::UNUSED_ID);
	assert(source::UNUSED_LOCATION.eql({ .id = source::UNUSED_ID }));
	assert(!source::UNUSED_LOCATION.eql({ .id = source::UNUSED_ID, .line = 1 }));

	@tracked(; Compilation* comp)
	{
		comp.generated_buf.push_all("abc");
		Source gen = comp.get_source(source::GENERATED_ID);
		check(gen.path, "<scratch space>");
		check(gen.buf, "abc");
		assert(gen.id.is_generated());
		assert(gen.kind == USER);
		assert(comp.ms_cwd_source_id.is_unused());
	};
}

fn void source_aliases() @test
{
	@tracked(; Compilation* comp)
	{
		Source orig = comp.add_source_from_buffer("orig.c", "a\\\nb\n")!!;
		char[] tmp_path = "line_marker.h".copy(tmem);
		SourceId alias_id = comp.add_source_alias(orig.id, (String)tmp_path, EXTERN_C_SYSTEM);
		tmp_path[0] = 'X'; // alias path is copied, not borrowed
		assert(alias_id.is_alias);
		check(alias_id.index, 0);

		Source a = comp.get_source(alias_id);
		check(a.path, "line_marker.h");
		assert(a.kind == EXTERN_C_SYSTEM);
		assert(a.id == alias_id);
		assert(a.buf.ptr == orig.buf.ptr);
		assert(a.splice_locs.ptr == orig.splice_locs.ptr);

		// alias of an alias
		SourceId alias2 = comp.add_source_alias(alias_id, "second.h", USER);
		check(alias2.index, 1);
		Source b = comp.get_source(alias2);
		check(b.path, "second.h");
		assert(b.buf.ptr == orig.buf.ptr);

		// locations in an alias expand with the alias path and kind
		Location aloc = { .id = alias_id, .byte_offset = 1, .line = 1 };
		ExpandedLocation loc = aloc.expand(comp);
		check(loc.path, "line_marker.h");
		assert(loc.kind == EXTERN_C_SYSTEM);
		// buf is "ab\n" with a splice at 1, so the line ends at the splice
		check(loc.line, "a");
		assert(loc.end_with_splice);
		// original unaffected
		check(comp.get_source(orig.id).path, "orig.c");
	};
}

fn void intern_stability() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		StringInterner si;
		si.init(&ta);
		check((uint)si.intern(""), (uint)string_interner::EMPTY);
		check(string_interner::EMPTY.lookup_extra(&si), "");

		String hello = "hello";
		StringId h = si.intern(hello);
		check((uint)h, 0);
		StringId w = si.intern("world");
		check((uint)w, 1);
		// a different slice with the same bytes interns to the same id
		char[] other = "hello".copy(tmem);
		check((uint)si.intern((String)other), (uint)h);

		List{String} owned;
		owned.init(&ta);
		for (int i = 0; i < 1000; i++) owned.push(string::format(&ta, "s%d", i));
		foreach (i, s : owned) check((uint)si.intern(s), (uint)i + 2);
		// ids stay stable and keys stay borrowed after growth
		foreach (i, s : owned)
		{
			StringId id = si.intern(s);
			check((uint)id, (uint)i + 2);
			assert(id.lookup_extra(&si).ptr == s.ptr);
		}
		assert(h.lookup_extra(&si).ptr == hello.ptr);
		check(w.lookup_extra(&si), "world");
		check(si.table.len(), 1002);

		si.free();
		foreach (s : owned) alloc::free(&ta, s.ptr);
		owned.free();
	}
	check(ta.allocation_count(), 0);

	@tracked(; Compilation* comp)
	{
		StringId a = comp.intern_string("abc");
		check(a.lookup(comp), "abc");
		check(string_interner::EMPTY.lookup(comp), "");
	};
}

fn Source tmp_source(String buf, uint[] splices)
{
	return { .path = "t.c", .buf = buf, .id = { .index = 0 }, .splice_locs = splices, .kind = USER };
}

fn ExpandedLocation at(Source* s, uint offset, uint line = 1)
{
	return s.line_col({ .id = { .index = 0 }, .byte_offset = offset, .line = line });
}

fn void location_expansion() @test
{
	Source s = tmp_source("int x;\n  y = 1;\n", {});
	ExpandedLocation e = at(&s, 9, 2);
	check(e.line, "  y = 1;");
	check(e.col, 3);
	check(e.width, 2);
	check(e.line_no, 2);
	check(e.path, "t.c");
	assert(!e.end_with_splice);

	e = at(&s, 0);
	check(e.line, "int x;");
	check(e.col, 1);
	check(e.width, 0);

	// Line without trailing newline ends at EOF.
	s = tmp_source("a\nlast", {});
	e = at(&s, 4, 2);
	check(e.line, "last");
	check(e.col, 3);
}

fn void location_with_splices() @test
{
	@tracked(; Compilation* comp)
	{
		Source s = comp.add_source_from_buffer("s.c", "ab\\\ncd\nef")!!;
		check(s.buf, "abcd\nef");
		ExpandedLocation e = at(&s, 3);
		check(e.line, "cd");
		check(e.col, 2);
		assert(!e.end_with_splice);

		e = at(&s, 1);
		check(e.line, "ab");
		check(e.col, 2);
		assert(e.end_with_splice);

		e = at(&s, 6, 2);
		check(e.line, "ef");
		check(e.col, 2);

		// repeated splices at the same offset
		Source r = comp.add_source_from_buffer("r.c", "x\\\n\\\nyz")!!;
		check(r.buf, "xyz");
		check(r.splice_locs.len, 2);
		e = at(&r, 2);
		check(e.line, "yz");
		check(e.col, 2);
	};
}

fn void unicode_display_width() @test
{
	// 日本 = two wide codepoints, 3 bytes each.
	Source s = tmp_source("日本 x", {});
	ExpandedLocation e = at(&s, 7);
	check(e.col, 4);
	check(e.width, 5);

	// emoji (4-byte, wide range 0x1F300..0x1F5FF), then ascii
	s = tmp_source("\xF0\x9F\x98\x80a", {}); // 0x1F600 is NOT in the wide ranges
	e = at(&s, 5);
	check(e.col, 3);
	check(e.width, 2);
	s = tmp_source("\xF0\x9F\x8C\x80a", {});
	e = at(&s, 5);
	check(e.width, 3);

	check(source::codepoint_width('a'), 1);
	check(source::codepoint_width(0x1100), 2);
	check(source::codepoint_width(0x115F), 2);
	check(source::codepoint_width(0x1160), 1);
	check(source::codepoint_width(0x2329), 2);
	check(source::codepoint_width(0xAC00), 2);
	check(source::codepoint_width(0x3FFFD), 2);
	check(source::codepoint_width(0x3FFFE), 1);
}

fn void invalid_utf8_columns() @test
{
	// invalid start byte: skipped, but still advances the column
	Source s = tmp_source("\xFFa b", {});
	ExpandedLocation e = at(&s, 3);
	check(e.col, 4);
	check(e.width, 2);

	// bad continuation byte
	s = tmp_source("\xC3(x", {});
	e = at(&s, 2);
	check(e.col, 3);
	check(e.width, 1);

	// overlong 2-byte encoding of '/'
	s = tmp_source("\xC0\xAFx", {});
	e = at(&s, 2);
	check(e.col, 3);
	check(e.width, 0);

	// UTF-16 surrogate encoded in UTF-8 is rejected
	s = tmp_source("\xED\xA0\x80x", {});
	e = at(&s, 3);
	check(e.col, 4);
	check(e.width, 0);

	// truncated sequence at end of buffer stops the scan
	s = tmp_source("a\xE6", {});
	e = at(&s, 2);
	check(e.col, 2);
	check(e.width, 1);
}

fn void newline_escape_diagnostic() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics diags;
		diags.init_list(&ta);
		Compilation comp;
		comp.init(&ta, diagnostics: &diags);
		comp.add_source_from_buffer("path", "ab\\ \nc")!!;
		check(diags.messages.len(), 1);
		Message d = diags.messages[0];
		assert(d.kind == WARNING && d.effective_kind == WARNING);
		check(d.text, "backslash and newline separated by space");
		assert(d.has_opt && d.opt == BACKSLASH_NEWLINE_ESCAPE);
		check(d.location.path, "path");
		check(d.location.line, "a");
		check(d.location.line_no, 1);
		check(d.location.col, 4);
		check(d.location.width, 3);

		// test/cases/newline splicing.c expects 31:14 for this line.
		comp.add_source_from_buffer("ns.c", "x;\nint trailing\\ \nws = 1;\n")!!;
		check(diags.messages.len(), 2);
		d = diags.messages[1];
		check(d.location.line_no, 2);
		check(d.location.col, 14);
		check(d.location.path, "ns.c");
		check(comp.warning_count(), 2);
		comp.free();
		diags.free();
	}
	check(ta.allocation_count(), 0);
}
