// Tests for src/c3/pp_builtin_macros.c3 (plan 14.4 `dynamic-macros`):
// Compilation.source_epoch, builtin_source_epoch, write_date_time_stamp and
// builtin_expand_obj (called directly; the object-macro expander is not used).
//
// Provenance of expected values (the pinned Zig 0.18-dev aro was NOT run):
//  [fixture X]  test/cases/X (manifest diagnostics or expanded/ golden).
//  [zig-std]    output of a scratch program run with the Zig 0.17.0 binary at
//               /home/user/tools/zig/ziglang/zig calling std.fmt.parseInt(u64, s, 10)
//               and the std.time.epoch code of Preprocessor.zig writeDateTimeStamp
//               (same format strings). Std only; aro itself was not built.
//  [source]     derived by reading Preprocessor.zig / Compilation.zig.
module pp_builtin_macros_tests;
import aro::preprocessor, aro::tokens, aro::tokenizer, aro::source, aro::compilation, aro::diagnostics;
import aro::lang_opts;
import std::io, std::core::mem::allocators, std::collections::list;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

alias Comp = Compilation;

<* Run the body with a compilation (diagnostics to a list) and a TESTING preprocessor; checks for leaks. *>
macro @with_pp(; @body(Compilation* comp, Diagnostics* d, Preprocessor* pp))
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
		@body(&comp, &d, &pp);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

<* A body token from `src` at byte 0 (Zig tokFromRaw of the macro body token). *>
fn TokenWithExpansionLocs body_tok(Source src)
{
	return { .id = MACRO_BUILTIN_OBJ, .loc = { .id = src.id, .byte_offset = 0, .line = 1 } };
}

<* Expand `kind` once and return the generated text (temp copy); frees the result token. *>
fn String expand(Preprocessor* pp, BuiltinObject kind, TokenWithExpansionLocs tok, TokenId expect_id = STRING_LITERAL)
{
	ExpandBuf buf;
	buf.init(pp.comp.gpa);
	sz start = pp.comp.generated_buf.len();
	preprocessor::builtin_expand_obj(null, pp, kind, tok, &buf)!!;
	check(buf.len(), 1);
	check(buf[0].id.ordinal, expect_id.ordinal);
	check(buf[0].loc.byte_offset, start);
	String text = ((String)pp.comp.generated_buf.array_view()[start..]).tcopy();
	preprocessor::free_expand_buf(pp.comp.gpa, &buf);
	return text;
}

<* write_date_time_stamp(kind, ts) as text. *>
fn String stamp(Preprocessor* pp, DateTimeStampKind kind, ulong ts)
{
	sz start = pp.comp.generated_buf.len();
	pp.write_date_time_stamp(kind, ts);
	return ((String)pp.comp.generated_buf.array_view()[start..]).tcopy();
}

<* Compilation.source_epoch with SOURCE_DATE_EPOCH = `text`. *>
fn SourceEpoch? epoch_from_env(String text)
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	comp.environment = { .has_source_date_epoch = true, .source_date_epoch = text };
	return comp.source_epoch();
}

<* Compilation.source_epoch with no SOURCE_DATE_EPOCH and a clock reading `secs`. *>
fn SourceEpoch? epoch_from_clock(long secs)
{
	Compilation comp;
	comp.init(mem);
	defer comp.free();
	comp.clock = compilation::fixed_clock(&secs);
	return comp.source_epoch();
}

struct ParseVec { String s; long v; }
struct StampVec { ulong ts; String date; String time; String stamp; }

fn long? failing_clock(void* ctx) => aro::UNSUPPORTED~;

// ---------------------------------------------------------------------------
// SOURCE_DATE_EPOCH parsing

fn void parse_int_vectors() @test
{
	// [zig-std] std.fmt.parseInt(u64, s, 10); -1 marks an error.
	ParseVec[*] vecs = {
		{ "0", 0 }, { "+0", 0 }, { "-0", 0 }, { "-000", 0 }, { "-0_0", 0 },
		{ "-1", -1 }, { "+", -1 }, { "-", -1 }, { "", -1 }, { "abc", -1 },
		{ "1_000", 1000 }, { "1__0", 10 }, { "_1", -1 }, { "1_", -1 },
		{ " 1", -1 }, { "1 ", -1 }, { "0x10", -1 }, { "+-0", -1 },
		{ "253402300799", 253402300799 }, { "253402300800", 253402300800 },
		{ "00000000000000000000001", 1 }, { "1a", -1 }, { "+12", 12 },
		{ "-_0", -1 }, { "+_1", -1 }, { "18446744073709551616", -1 },
	};
	foreach (v : vecs)
	{
		ulong? r = preprocessor::parse_epoch_u64(v.s);
		if (v.v < 0)
		{
			if (try r) test::eq(v.s, "expected an error");
		}
		else
		{
			check(r!!, v.v);
		}
	}
	// [zig-std] u64 max parses; one more overflows (above).
	assert(preprocessor::parse_epoch_u64("18446744073709551615")!! == ulong::max);
}

fn void source_epoch_from_environment() @test
{
	// [fixture source epoch.c] SOURCE_DATE_EPOCH=0 -> provided 0.
	SourceEpoch e = epoch_from_env("0")!!;
	assert(e.provided);
	check(e.timestamp, 0);
	// [source] the maximum is accepted, one more is InvalidEpoch.
	e = epoch_from_env("253402300799")!!;
	assert(e.provided);
	check(e.timestamp, 253402300799);
	assert(@catch(epoch_from_env("253402300800")) == preprocessor::INVALID_EPOCH);
	// [fixture invalid epoch.c] SOURCE_DATE_EPOCH=abc.
	assert(@catch(epoch_from_env("abc")) == preprocessor::INVALID_EPOCH);
	assert(@catch(epoch_from_env("")) == preprocessor::INVALID_EPOCH);
	assert(@catch(epoch_from_env("-1")) == preprocessor::INVALID_EPOCH);
	// [zig-std] "-0" parses as 0.
	e = epoch_from_env("-0")!!;
	assert(e.provided && e.timestamp == 0);
}

fn void source_epoch_from_clock() @test
{
	// [source] no SOURCE_DATE_EPOCH: `system` = clock seconds, clamped to the maximum.
	SourceEpoch e = epoch_from_clock(1700000000)!!;
	assert(!e.provided);
	check(e.timestamp, 1700000000);
	e = epoch_from_clock(0)!!;
	assert(!e.provided && e.timestamp == 0);
	e = epoch_from_clock(300000000000)!!;
	assert(!e.provided);
	check(e.timestamp, 253402300799);
	// [source] a negative clock fails std.math.cast(u64) -> InvalidEpoch.
	assert(@catch(epoch_from_clock(-1)) == preprocessor::INVALID_EPOCH);

	Compilation comp;
	comp.init(mem);
	defer comp.free();
	comp.clock = { null, &failing_clock };
	assert(@catch(comp.source_epoch()) == preprocessor::INVALID_EPOCH);
}

fn void init_reports_invalid_epoch() @test
{
	// [fixture invalid epoch.c] the error has no location; the epoch falls back to provided 0.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.environment = { .has_source_date_epoch = true, .source_date_epoch = "abc" };
		InitOptions opts = preprocessor::TESTING;
		opts.has_source_epoch = false;
		Preprocessor pp;
		pp.init(&comp, opts, preprocessor::BUILTINS)!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "environment variable SOURCE_DATE_EPOCH must expand to a non-negative integer less than or equal to 253402300799");
		check(d.messages[0].effective_kind.ordinal, MessageKind.ERROR.ordinal);
		assert(!d.messages[0].has_location);
		assert(pp.source_epoch.provided);
		check(pp.source_epoch.timestamp, 0);
		pp.free();

		// [source] a valid environment value is taken without diagnostics.
		comp.environment.source_date_epoch = "86400";
		pp.init(&comp, opts, preprocessor::BUILTINS)!!;
		check(d.messages.len(), 1);
		assert(pp.source_epoch.provided);
		check(pp.source_epoch.timestamp, 86400);
		pp.free();

		// [source] without SOURCE_DATE_EPOCH the clock is used (`system`).
		long secs = 1234567890;
		comp.environment = {};
		comp.clock = compilation::fixed_clock(&secs);
		pp.init(&comp, opts, preprocessor::BUILTINS)!!;
		assert(!pp.source_epoch.provided);
		check(pp.source_epoch.timestamp, 1234567890);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

// ---------------------------------------------------------------------------
// __DATE__ / __TIME__ / __TIMESTAMP__ text

fn void date_time_stamp_vectors() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture source epoch.c] epoch 0.
		test::eq(stamp(pp, DATE, 0), "\"Jan  1 1970\"");
		test::eq(stamp(pp, TIME, 0), "\"00:00:00\"");
		test::eq(stamp(pp, TIMESTAMP, 0), "\"Thu Jan  1 00:00:00 1970\"");
		// [zig-std] { ts, DATE, TIME, TIMESTAMP }
		StampVec[*] vecs = {
			{ 1, "\"Jan  1 1970\"", "\"00:00:01\"", "\"Thu Jan  1 00:00:01 1970\"" },
			{ 59, "\"Jan  1 1970\"", "\"00:00:59\"", "\"Thu Jan  1 00:00:59 1970\"" },
			{ 86399, "\"Jan  1 1970\"", "\"23:59:59\"", "\"Thu Jan  1 23:59:59 1970\"" },
			{ 86400, "\"Jan  2 1970\"", "\"00:00:00\"", "\"Fri Jan  2 00:00:00 1970\"" },
			{ 68169600, "\"Feb 29 1972\"", "\"00:00:00\"", "\"Tue Feb 29 00:00:00 1972\"" },
			{ 946684800, "\"Jan  1 2000\"", "\"00:00:00\"", "\"Sat Jan  1 00:00:00 2000\"" },
			{ 951782400, "\"Feb 29 2000\"", "\"00:00:00\"", "\"Tue Feb 29 00:00:00 2000\"" },
			{ 951868799, "\"Feb 29 2000\"", "\"23:59:59\"", "\"Tue Feb 29 23:59:59 2000\"" },
			{ 1234567890, "\"Feb 13 2009\"", "\"23:31:30\"", "\"Fri Feb 13 23:31:30 2009\"" },
			{ 1700000000, "\"Nov 14 2023\"", "\"22:13:20\"", "\"Tue Nov 14 22:13:20 2023\"" },
			{ 1709251199, "\"Feb 29 2024\"", "\"23:59:59\"", "\"Thu Feb 29 23:59:59 2024\"" },
			{ 4102444800, "\"Jan  1 2100\"", "\"00:00:00\"", "\"Fri Jan  1 00:00:00 2100\"" },
			{ 253402300799, "\"Dec 31 9999\"", "\"23:59:59\"", "\"Fri Dec 31 23:59:59 9999\"" },
		};
		foreach (v : vecs)
		{
			test::eq(stamp(pp, DATE, v.ts), v.date);
			test::eq(stamp(pp, TIME, v.ts), v.time);
			test::eq(stamp(pp, TIMESTAMP, v.ts), v.stamp);
		}
		check(d.messages.len(), 0);
	};
}

fn void expand_date_time() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		Source src = comp.add_source_from_buffer("date expansion.c", "char *foo = __DATE__;\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 12, .line = 1 };
		// [source] DIAG_DATE_TIME is off by default.
		test::eq(expand(pp, DATE, body_tok(src)), "\"Jan  1 1970\"");
		check(d.messages.len(), 0);
		// [fixture date expansion.c] -Wdate-time: warning at the expansion location (1:13).
		d.set("date-time", WARNING)!!;
		test::eq(expand(pp, TIME, body_tok(src)), "\"00:00:00\"");
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "expansion of date or time macro is not reproducible");
		check(d.messages[0].location.line_no, 1);
		check(d.messages[0].location.col, 13);
		// [source] provided epoch is used for __TIMESTAMP__ too.
		pp.source_epoch = { .provided = true, .timestamp = 1700000000 };
		test::eq(expand(pp, TIMESTAMP, body_tok(src)), "\"Tue Nov 14 22:13:20 2023\"");
		test::eq(expand(pp, DATE, body_tok(src)), "\"Nov 14 2023\"");
		check(d.messages.len(), 3);
	};
}

ulong mtime_value = 1709251199;
int mtime_calls;
fn ulong? fixed_mtime(void* ctx, Preprocessor* pp, SourceId id)
{
	mtime_calls++;
	return mtime_value;
}

fn void expand_timestamp_system_epoch() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		Source src = comp.add_source_from_buffer("t.c", "__TIMESTAMP__ __DATE__\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 0, .line = 1 };
		pp.source_epoch = { .provided = false, .timestamp = 0 };
		// [source] `system` epoch: __DATE__ uses the epoch, __TIMESTAMP__ the file mtime.
		test::eq(expand(pp, DATE, body_tok(src)), "\"Jan  1 1970\"");
		// Without a file provider the mtime is unsupported (plan 15).
		ExpandBuf buf;
		buf.init(comp.gpa);
		assert(@catch(preprocessor::builtin_expand_obj(null, pp, TIMESTAMP, body_tok(src), &buf)) == aro::UNSUPPORTED);
		check(buf.len(), 0);
		buf.free();
		pp.files.source_mtime = &fixed_mtime;
		mtime_calls = 0;
		test::eq(expand(pp, TIMESTAMP, body_tok(src)), "\"Thu Feb 29 23:59:59 2024\"");
		test::eq(expand(pp, TIMESTAMP, body_tok(src)), "\"Thu Feb 29 23:59:59 2024\"");
		check(mtime_calls, 1); // [source] cached in m_times
	};
}

// ---------------------------------------------------------------------------
// __FILE__ / __BASE_FILE__ / __FILE_NAME__

fn void expand_file() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture __line__.c] after `#line 100 "foo.c"`: "foo.c" (here the source path itself).
		Source src = comp.add_source_from_buffer("foo.c", "__FILE__\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 0, .line = 1 };
		test::eq(expand(pp, FILE, body_tok(src)), "\"foo.c\"\n");
		// [source] fmtEscapes: '\\', '"', control and non-ASCII bytes.
		Source odd = comp.add_source_from_buffer("dir\\a\"b\t\xff.c", "__FILE__\n")!!;
		pp.expansion_source_loc = { .id = odd.id, .byte_offset = 0, .line = 1 };
		test::eq(expand(pp, FILE, body_tok(odd)), "\"dir\\\\a\\\"b\\t\\xff.c\"\n");
		check(d.messages.len(), 0);
	};
}

fn void expand_file_prefix_replacement() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		Source src = comp.add_source_from_buffer("/home/u/proj/src/a.c", "__FILE__\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 0, .line = 1 };
		// [source] first matching prefix wins; result has no trailing newline.
		PathReplacement[*] reps = {
			{ "/other/", "X/" },
			{ "/home/u/proj/", "./" },
			{ "/home/u/", "never/" },
		};
		pp.path_replacements = &reps;
		test::eq(expand(pp, FILE, body_tok(src)), "\"./src/a.c\"");
		// [source] the replacement and the rest are both escaped.
		PathReplacement[*] reps2 = { { "/home/u/", "C:\\x\"" } };
		pp.path_replacements = &reps2;
		test::eq(expand(pp, FILE, body_tok(src)), "\"C:\\\\x\\\"proj/src/a.c\"");
		// [source] no match: unreplaced, with newline.
		PathReplacement[*] reps3 = { { "/nope", "" } };
		pp.path_replacements = &reps3;
		test::eq(expand(pp, FILE, body_tok(src)), "\"/home/u/proj/src/a.c\"\n");
		// [source] exact-path prefix leaves an empty rest.
		PathReplacement[*] reps4 = { { "/home/u/proj/src/a.c", "R" } };
		pp.path_replacements = &reps4;
		test::eq(expand(pp, FILE, body_tok(src)), "\"R\"");
	};
}

fn void expand_base_file() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		Source main_src = comp.add_source_from_buffer("clang __BASE_FILE__.c", "#include <base_file_redirect.h>\n")!!;
		Source hdr = comp.add_source_from_buffer("base_file_redirect.h", "static const char *base_file = __BASE_FILE__;\n")!!;
		pp.base_file = main_src.id;
		pp.expansion_source_loc = { .id = hdr.id, .byte_offset = 31, .line = 1 };
		d.state.extensions = WARNING; // -Wpedantic
		// [fixture clang __BASE_FILE__.c] "clang __BASE_FILE__.c", warning at base_file_redirect.h:1:32.
		test::eq(expand(pp, BASE_FILE, body_tok(hdr)), "\"clang __BASE_FILE__.c\"");
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "__BASE_FILE__ is a clang extension");
		check(d.messages[0].location.line_no, 1);
		check(d.messages[0].location.col, 32);
		test::eq(d.messages[0].location.path, "base_file_redirect.h");

		// [source] Zig quirk: the replacement loop never breaks and its `else` always
		// runs, so every matching prefix writes a literal and the unreplaced one follows.
		PathReplacement[*] reps = { { "clang ", "A/" }, { "x", "B" }, { "clang __", "C" } };
		pp.path_replacements = &reps;
		test::eq(expand(pp, BASE_FILE, body_tok(hdr)), "\"A/__BASE_FILE__.c\"\"CBASE_FILE__.c\"\"clang __BASE_FILE__.c\"");
		check(d.messages.len(), 2);
	};
}

fn void expand_file_basename() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] std.fs.path.basename (posix) of the expansion source, escaped, no newline.
		Source src = comp.add_source_from_buffer("/a/b/c d\".h", "x\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 0, .line = 1 };
		test::eq(expand(pp, FILE_BASENAME, body_tok(src)), "\"c d\\\".h\"");
		check(d.messages.len(), 0); // off by default
		d.state.extensions = WARNING;
		Source plain = comp.add_source_from_buffer("plain.c", "x\n")!!;
		pp.expansion_source_loc = { .id = plain.id, .byte_offset = 0, .line = 1 };
		test::eq(expand(pp, FILE_BASENAME, body_tok(plain)), "\"plain.c\"");
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "__FILE_NAME__ is a clang extension");
		// [zig-std test basename] posix cases.
		test::eq(preprocessor::path_basename(""), "");
		test::eq(preprocessor::path_basename("/"), "");
		test::eq(preprocessor::path_basename("/dir/basename.ext"), "basename.ext");
		test::eq(preprocessor::path_basename("basename.ext//"), "basename.ext");
		test::eq(preprocessor::path_basename("/aaa/"), "aaa");
		test::eq(preprocessor::path_basename("//a"), "a");
		test::eq(preprocessor::path_basename("\\dir\\basename.ext"), "\\dir\\basename.ext");
	};
}

// ---------------------------------------------------------------------------
// __LINE__ / __COUNTER__ / __INCLUDE_LEVEL__

fn void expand_line_and_counter() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture line counter.c] `FOO` / `FOO FOO` with FOO = __LINE__ __COUNTER__
		// expand to "2 0" and "3 1 3 2".
		Source src = comp.add_source_from_buffer("line counter.c", "#define FOO __LINE__ __COUNTER__\nFOO\nFOO FOO\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 33, .line = 2 };
		test::eq(expand(pp, LINE, body_tok(src), PP_NUM), "2\n");
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "0\n");
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 37, .line = 3 };
		test::eq(expand(pp, LINE, body_tok(src), PP_NUM), "3\n");
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "1\n");
		test::eq(expand(pp, LINE, body_tok(src), PP_NUM), "3\n");
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "2\n");
		check(pp.counter, 3);
		check(d.messages.len(), 0);
	};
}

fn void counter_diagnostics_and_overflow() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		Source src = comp.add_source_from_buffer("c.c", "__COUNTER__\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 0, .line = 1 };
		// [source] before C2y: c2y_counter (extension) at the body token.
		d.state.extensions = WARNING;
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "0\n");
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "'__COUNTER__' is a C2y extension");
		// [source] C2y: pre_c2y_counter (off unless -Wpre-c2y-compat).
		comp.langopts.standard = C2Y;
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "1\n");
		check(d.messages.len(), 1);
		d.set("pre-c2y-compat", WARNING)!!;
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "2\n");
		check(d.messages.len(), 2);
		test::eq(d.messages[1].text, "'__COUNTER__' is incompatible with C standards before C2y");
		d.set("pre-c2y-compat", OFF)!!;

		// [source] maxInt(i32) is fine; above it counter_overflow (error); u32 wraps.
		pp.counter = 0x7FFF_FFFF;
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "2147483647\n");
		check(d.messages.len(), 2);
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "2147483648\n");
		check(d.messages.len(), 3);
		test::eq(d.messages[2].text, "'__COUNTER__' value cannot exceed 2'147'483'647");
		check(d.messages[2].effective_kind.ordinal, MessageKind.ERROR.ordinal);
		pp.counter = 0xFFFF_FFFF;
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "4294967295\n");
		check(pp.counter, 0);
		test::eq(expand(pp, COUNTER, body_tok(src), PP_NUM), "0\n");
	};
}

fn void expand_include_level() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [fixture clang __INCLUDE_LEVEL__.c] levels 0 and 2; warning at 1:33 with -Wpedantic.
		Source src = comp.add_source_from_buffer("clang __INCLUDE_LEVEL__.c", "static int main_include_level = __INCLUDE_LEVEL__;\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 32, .line = 1 };
		test::eq(expand(pp, INCLUDE_LEVEL, body_tok(src), PP_NUM), "0\n");
		check(d.messages.len(), 0);
		d.state.extensions = WARNING;
		pp.include_depth = 2;
		test::eq(expand(pp, INCLUDE_LEVEL, body_tok(src), PP_NUM), "2\n");
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "__INCLUDE_LEVEL__ is a clang extension");
		check(d.messages[0].location.col, 33);
	};
}

fn void generated_token_locations() @test
{
	@with_pp(; Comp* comp, Diagnostics* d, Preprocessor* pp)
	{
		// [source] makeGeneratedToken: generated source, increasing generated_line,
		// expansion location = the body token's location.
		Source src = comp.add_source_from_buffer("g.c", "__LINE__\n")!!;
		pp.expansion_source_loc = { .id = src.id, .byte_offset = 0, .line = 1 };
		uint line0 = pp.generated_line;
		ExpandBuf buf;
		buf.init(comp.gpa);
		preprocessor::builtin_expand_obj(null, pp, LINE, body_tok(src), &buf)!!;
		preprocessor::builtin_expand_obj(null, pp, FILE, body_tok(src), &buf)!!;
		check(buf.len(), 2);
		SourceId gen = source::GENERATED_ID;
		assert(buf[0].loc.id == gen);
		check(buf[0].loc.line, line0);
		check(buf[1].loc.line, line0 + 1);
		Location[] locs = buf[0].expansion_slice();
		check(locs.len, 1);
		assert(locs[0].id == src.id);
		test::eq(pp.expanded_slice(buf[1]), "\"g.c\"");
		test::eq(pp.expanded_slice(buf[0]), "1");
		preprocessor::free_expand_buf(comp.gpa, &buf);
	};
}
