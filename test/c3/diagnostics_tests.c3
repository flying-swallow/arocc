// Tests for aro::diagnostics (port of src/aro/Diagnostics.zig).
//
// Expected texts are hand-derived from the Zig source (Message.write,
// effectiveKind, addWithLocation, set) and, where a fixture exists, copied
// from test/cases/*.c manifests:
//   - "newline splicing.c"      : "newline splicing.c:31:14: warning: backslash and newline separated by space [-Wbackslash-newline-escape]"
//   - "macro backtrace limit.c" : the skipping note and "expanded from here" lines
// No Zig binary was run; every golden below marked "hand-derived" comes from
// reading the Zig code, the color escapes from std/Io/Terminal.zig.
module diagnostics_tests;
import aro::source, aro::compilation, aro::diagnostics;
import std::core::mem::allocators, std::collections::list, std::io;

macro check(left, right)
{
	$if $defined((long)left):
		test::eq((long)left, (long)right);
	$else
		test::eq(left, right);
	$endif
}

<* Sink writing into a growable buffer on a tracking allocator. *>
struct Sink
{
	TrackingAllocator ta;
	ByteWriter bw;
	Diagnostics diags;
}

fn void Sink.init(&self, ColorMode mode = NO_COLOR)
{
	self.ta.init(mem);
	self.bw.init(&self.ta);
	self.diags.init_writer(&self.bw, mode);
}

fn String Sink.out(&self) => self.bw.str_view();

fn void Sink.free(&self)
{
	self.diags.free();
	(void)self.bw.destroy();
	check(self.ta.allocation_count(), 0);
	self.ta.free();
}

fn Message warn(String text, Option opt) => { .kind = WARNING, .text = text, .has_opt = true, .opt = opt };

fn Location loc_at(Source src, uint offset, uint line) => { .id = src.id, .byte_offset = offset, .line = line };

// ---------------------------------------------------------------------------
// Rendering

fn void spliced_location_golden() @test
{
	// Fixture: test/cases/newline splicing.c line 31 "int trailing\ " -> 31:14.
	// Reduced to the same line at line 2; the source line text and caret are
	// hand-derived: Zig trims one byte off the partially normalized line
	// ("int trailing" -> "int trailin"), the line ends with a splice so "\ "
	// is appended, and the caret width is 12 + 1.
	Sink s;
	s.init();
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	comp.add_source_from_buffer("newline splicing.c", "x;\nint trailing\\ \nws = 1;\n")!!;
	check(s.out(),
		"newline splicing.c:2:14: warning: backslash and newline separated by space [-Wbackslash-newline-escape]\n"
		"int trailin\\ \n"
		"             ^\n");
	check(s.diags.warnings, 1);
	check(s.diags.total, 1);
	comp.free();
	s.free();
}

fn void unicode_location_golden() @test
{
	// hand-derived: columns count codepoints, caret width uses display width
	// (U+4E2D is double width, U+00E9 single width).
	Sink s;
	s.init();
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	Source src = comp.add_source_from_buffer("u.c", "int 中é = x;\n")!!;
	// bytes: "int " (4) + E4 B8 AD (3) + C3 A9 (2) + " = " (3) -> 'x' at offset 12
	Message m = warn("use of 'x'", UNUSED_VALUE);
	m.has_location = true;
	m.location = loc_at(src, 12, 1).expand(&comp);
	s.diags.add(m)!!;
	check(s.out(),
		"u.c:1:10: warning: use of 'x' [-Wunused-value]\n"
		"int 中é = x;\n"
		"          ^\n");
	comp.free();
	s.free();
}

fn void details_off_and_no_location() @test
{
	Sink s;
	s.init();
	s.diags.details = false;
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	Source src = comp.add_source_from_buffer("d.c", "int a;\n")!!;
	Message m = warn("w1", UNUSED_VALUE);
	m.has_location = true;
	m.location = loc_at(src, 4, 1).expand(&comp);
	s.diags.add(m)!!;
	s.diags.add({ .kind = ERROR, .text = "no location" })!!;
	s.diags.add({ .kind = NOTE, .text = "a note", .has_opt = true, .opt = UNUSED_VALUE })!!;
	check(s.out(),
		"d.c:1:5: warning: w1 [-Wunused-value]\n"
		"error: no location\n"
		"note: a note\n");
	check(s.diags.errors, 1);
	check(s.diags.warnings, 1);
	check(s.diags.total, 3);
	comp.free();
	s.free();
}

fn void color_escape_codes_and_reset() @test
{
	// hand-derived from Message.write and std.Io.Terminal.setColor
	Sink s;
	s.init(ESCAPE_CODES);
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	Source src = comp.add_source_from_buffer("c.c", "ab\n")!!;
	Message m = warn("w", UNUSED_VALUE);
	m.has_location = true;
	m.location = loc_at(src, 1, 1).expand(&comp);
	s.diags.add(m)!!;
	s.diags.add({ .kind = ERROR, .text = "e" })!!;
	s.diags.add({ .kind = NOTE, .text = "n" })!!;
	check(s.out(),
		"\e[1mc.c:1:2: \e[95mwarning: \e[37mw [-Wunused-value]\e[0m\nab\n \e[1m\e[92m^\n\e[0m"
		"\e[1m\e[91merror: \e[37me\n\e[0m"
		"\e[1m\e[96mnote: \e[37mn\n\e[0m");
	// every message leaves the terminal reset
	assert(s.out().ends_with("\e[0m"));
	comp.free();
	s.free();
}

fn void color_override() @test
{
	// -fno-color-diagnostics on an escape-code terminal
	Sink s;
	s.init(ESCAPE_CODES);
	s.diags.color = FORCE_OFF;
	fault r = @catch(s.diags.add({ .kind = FATAL_ERROR, .text = "boom" }));
	assert(r == compilation::FATAL_ERROR);
	check(s.out(), "fatal error: boom\n");
	s.free();

	// -fcolor-diagnostics on a plain terminal
	Sink t;
	t.init(NO_COLOR);
	t.diags.color = FORCE_ON;
	t.diags.add({ .kind = ERROR, .text = "e" })!!;
	check(t.out(), "\e[1m\e[91merror: \e[37me\n\e[0m");
	t.free();
}

// ---------------------------------------------------------------------------
// Option state / effective kind

fn void warnings_disabled_then_promoted() @test
{
	Sink s;
	s.init();
	Diagnostics* d = &s.diags;

	// disabled: the warning and its attached note are dropped
	d.set("unused-value", OFF)!!;
	d.add(warn("hidden", UNUSED_VALUE))!!;
	d.add({ .kind = NOTE, .text = "hidden note" })!!;
	check(d.total, 0);

	// re-enabled as warning, then -Werror promotes it
	d.set("unused-value", WARNING)!!;
	d.add(warn("visible", UNUSED_VALUE))!!;
	d.add({ .kind = NOTE, .text = "shown note" })!!;
	d.state.error_warnings = true;
	d.add(warn("promoted", UNUSED_VALUE))!!;
	// -Werror=<name> style: explicit ERROR on a warning
	d.state.error_warnings = false;
	d.set("unused-value", ERROR)!!;
	d.add(warn("explicit", UNUSED_VALUE))!!;
	// an error that is natively an error gets no -Werror prefix
	d.add({ .kind = ERROR, .text = "native", .has_opt = true, .opt = UNUSED_VALUE })!!;
	check(s.out(),
		"warning: visible [-Wunused-value]\n"
		"note: shown note\n"
		"error: promoted [-Werror,-Wunused-value]\n"
		"error: explicit [-Werror,-Wunused-value]\n"
		"error: native [-Wunused-value]\n");
	check(d.warnings, 1);
	check(d.errors, 3);
	check(d.total, 5);
	s.free();
}

fn void ignore_warnings_wins() @test
{
	Sink s;
	s.init();
	Diagnostics* d = &s.diags;
	d.state.ignore_warnings = true;
	d.state.error_warnings = true;
	d.set("unused-value", ERROR)!!;
	// -w disregards explicit kinds and hides the notes
	d.add(warn("w", UNUSED_VALUE))!!;
	d.add({ .kind = NOTE, .text = "n" })!!;
	// errors are unaffected; notes become visible again after it
	d.add({ .kind = ERROR, .text = "e" })!!;
	d.add({ .kind = NOTE, .text = "n2" })!!;
	check(s.out(), "error: e\nnote: n2\n");
	s.free();
}

fn void pedantic_and_everything() @test
{
	Sink s;
	s.init();
	Diagnostics* d = &s.diags;
	Message ext = { .kind = OFF, .text = "ext", .extension = true };
	d.add(ext)!!;
	check(d.total, 0);
	d.set("pedantic", WARNING)!!;
	d.add(ext)!!;
	d.set("pedantic", ERROR)!!;
	d.add(ext)!!;
	// an explicit -W<opt> setting beats -pedantic
	Message ext_opt = { .kind = OFF, .text = "ext-opt", .extension = true, .has_opt = true, .opt = GNU_CASE_RANGE };
	d.set("gnu", WARNING)!!;
	d.add(ext_opt)!!;
	// extension warnings stay warnings unless -pedantic is higher
	Message ext_warn = { .kind = WARNING, .text = "ext-warn", .extension = true };
	d.set("pedantic", OFF)!!;
	d.add(ext_warn)!!;
	// -Weverything turns off-by-default diagnostics into warnings
	d.state.enable_all_warnings = true;
	d.add({ .kind = OFF, .text = "everything", .has_opt = true, .opt = VLA })!!;
	check(s.out(),
		"warning: ext [-Wpedantic]\n"
		"error: ext [-Werror,-Wpedantic]\n"
		"warning: ext-opt [-Wgnu-case-range]\n"
		"warning: ext-warn\n"
		"warning: everything [-Wvla]\n");
	s.free();
}

fn void fatal_errors() @test
{
	Sink s;
	s.init();
	Diagnostics* d = &s.diags;
	d.state.fatal_errors = true;
	d.state.error_warnings = true;
	fault r = @catch(d.add(warn("w", UNUSED_VALUE)));
	assert(r == compilation::FATAL_ERROR);
	check(s.out(), "fatal error: w [-Wunused-value]\n");
	check(d.errors, 1);
	// a fatal error from the Driver path
	d.state = diagnostics::DEFAULT_STATE;
	r = @catch(d.add({ .kind = FATAL_ERROR, .text = "f" }));
	assert(r == compilation::FATAL_ERROR);
	check(d.errors, 2);
	s.free();
}

fn void system_header_suppression() @test
{
	Sink s;
	s.init();
	s.diags.details = false;
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	Source src = comp.add_source_from_buffer("sys.h", "int a;\n")!!;
	SourceId sys_id = comp.add_source_alias(src.id, "sys.h", SYSTEM);
	Location loc = { .id = sys_id, .byte_offset = 0, .line = 1 };
	Message w = warn("w", UNUSED_VALUE);
	w.has_location = true;
	w.location = loc.expand(&comp);
	Message e = { .kind = ERROR, .text = "e", .has_location = true, .location = w.location };
	s.diags.add(w)!!;
	s.diags.add(e)!!;
	s.diags.state.suppress_system_headers = false;
	s.diags.add(w)!!;
	check(s.out(), "sys.h:1:1: error: e\nsys.h:1:1: warning: w [-Wunused-value]\n");
	comp.free();
	s.free();
}

fn void unknown_options() @test
{
	Sink s;
	s.init();
	Diagnostics* d = &s.diags;
	d.set("no-such-warning", WARNING)!!;
	d.state.error_warnings = true;
	d.set("other", OFF)!!;
	check(s.out(),
		"warning: unknown warning 'no-such-warning' [-Wunknown-warning-option]\n"
		"error: unknown warning 'other' [-Werror,-Wunknown-warning-option]\n");
	// -Wno-unknown-warning-option silences it
	d.state.error_warnings = false;
	d.set("unknown-warning-option", OFF)!!;
	d.set("still-unknown", WARNING)!!;
	check(d.total, 2);
	s.free();

	// texts longer than Zig's 256-byte buffer are cut
	Diagnostics l;
	l.init_list(mem);
	char[300] name;
	name[..] = 'a';
	l.set((String)name[..], WARNING)!!;
	check(l.messages[0].text.len, 256);
	assert(l.messages[0].text.starts_with("unknown warning 'aaa"));
	l.free();
}

fn void groups_and_lookup() @test
{
	Diagnostics d;
	d.init_ignore();
	d.set("gnu", ERROR)!!;
	assert(d.severity(GNU_CASE_RANGE) == ERROR);
	assert(d.severity(ZERO_LENGTH_ARRAY) == ERROR);
	assert(d.severity(VLA) == OFF);
	d.set("all", WARNING)!!;
	assert(d.severity(MALFORMED_WARNING_CHECK) == WARNING);
	assert(d.severity(UNUSED_LABEL) == WARNING);
	assert(d.severity(UNUSED_PARAMETER) == OFF);
	assert(d.severity(IMPLICIT_INT) == WARNING);
	check(d.total, 0);

	assert(diagnostics::warning_exists("pedantic"));
	assert(diagnostics::warning_exists("most"));
	assert(diagnostics::warning_exists("#warnings"));
	assert(diagnostics::warning_exists("c++-compat"));
	assert(diagnostics::warning_exists("unused-value"));
	assert(!diagnostics::warning_exists("Wunused-value"));
	assert(!diagnostics::warning_exists("nope"));
	assert(diagnostics::option_from_flag("#pragma-messages")!! == PRAGMA_MESSAGES);
	check(Option.CXX_COMPAT.flag, "c++-compat");
	check(Option::len, 145);

	// State is a value: pragma push/pop saves and restores it wholesale.
	State saved = d.state;
	d.set("vla", ERROR)!!;
	d.state.error_warnings = true;
	d.state = saved;
	assert(d.severity(VLA) == OFF);
	assert(!d.state.error_warnings);
	assert(d.state.suppress_system_headers);
	d.free();
}

// ---------------------------------------------------------------------------
// Macro backtraces

<* Source "a\nb\nc\n..." with one letter per line: letter k at offset 2k, line k+1. *>
fn Location[] letter_locs(Compilation* comp, Location[] out)
{
	char[64] text;
	for (usz k = 0; k < out.len; k++)
	{
		text[2 * k] = (char)('a' + k);
		text[2 * k + 1] = '\n';
	}
	Source src = comp.add_source_from_buffer("m.c", text[:out.len * 2])!!;
	foreach (k, &l : out) *l = loc_at(src, (uint)k * 2, (uint)k + 1);
	return out;
}

fn void macro_backtrace_fixture() @test
{
	// test/cases/macro backtrace limit.c with -fmacro-backtrace-limit=1:
	//   macro backtrace limit.c:2:1: error: expected external declaration
	//   note: (skipping 1 expansions in backtrace; use -fmacro-backtrace-limit=0 to see all)
	//   macro backtrace limit.c:2:5: note: expanded from here
	Sink s;
	s.init();
	s.diags.details = false;
	s.diags.macro_backtrace_limit = 1;
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	Source src = comp.add_source_from_buffer("macro backtrace limit.c", "#define FOO(X) X\nFOO(2)\n")!!;
	Location tok = loc_at(src, 21, 2);  // the '2' argument
	Location call = loc_at(src, 17, 2); // FOO
	Message m = { .kind = ERROR, .text = "expected external declaration", .has_location = true, .location = tok.expand(&comp) };
	s.diags.add_with_location(&comp, m, { tok, call }, true)!!;
	check(s.out(),
		"macro backtrace limit.c:2:1: error: expected external declaration\n"
		"note: (skipping 1 expansions in backtrace; use -fmacro-backtrace-limit=0 to see all)\n"
		"macro backtrace limit.c:2:5: note: expanded from here\n");
	check(s.diags.total, 3);
	check(s.diags.errors, 1);
	comp.free();
	s.free();
}

fn void macro_backtrace_truncation() @test
{
	// hand-derived from addWithLocation: 8 expansions, default limit 6.
	// primary at [7]; notes [6] [5] [4]; skip 8 - 6 = 2; notes [1] [0]; message location.
	Sink s;
	s.init();
	s.diags.details = false;
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	Location[8] locs;
	letter_locs(&comp, &locs);
	Source other = comp.add_source_from_buffer("o.c", "zz\n")!!;
	Message m = warn("w", UNUSED_VALUE);
	m.has_location = true;
	m.location = loc_at(other, 1, 1).expand(&comp);
	s.diags.add_with_location(&comp, m, &locs, true)!!;
	check(s.out(),
		"m.c:8:1: warning: w [-Wunused-value]\n"
		"m.c:7:1: note: expanded from here\n"
		"m.c:6:1: note: expanded from here\n"
		"m.c:5:1: note: expanded from here\n"
		"note: (skipping 2 expansions in backtrace; use -fmacro-backtrace-limit=0 to see all)\n"
		"m.c:2:1: note: expanded from here\n"
		"m.c:1:1: note: expanded from here\n"
		"o.c:1:2: note: expanded from here\n");
	check(s.diags.warnings, 1);
	check(s.diags.total, 8);
	comp.free();
	s.free();
}

fn void macro_backtrace_unlimited_and_hidden() @test
{
	Sink s;
	s.init();
	s.diags.details = false;
	s.diags.macro_backtrace_limit = uint::max; // -fmacro-backtrace-limit=0
	Compilation comp;
	comp.init(&s.ta, diagnostics: &s.diags);
	Location[3] locs;
	letter_locs(&comp, &locs);
	Message m = warn("w", UNUSED_VALUE);
	s.diags.add_with_location(&comp, m, &locs, false)!!;
	check(s.out(),
		"m.c:3:1: warning: w [-Wunused-value]\n"
		"m.c:2:1: note: expanded from here\n"
		"m.c:1:1: note: expanded from here\n");
	// a disabled message drops its whole backtrace
	s.diags.set("unused-value", OFF)!!;
	uint before = s.diags.total;
	s.diags.add_with_location(&comp, m, &locs, false)!!;
	check(s.diags.total, before);
	// Zig quirk preserved: -Wfatal-errors promotion on this path does not fail
	s.diags.state.fatal_errors = true;
	s.diags.add_with_location(&comp, { .kind = ERROR, .text = "e" }, &locs, false)!!;
	fault r = @catch(s.diags.add_with_location(&comp, { .kind = FATAL_ERROR, .text = "f" }, {}, false));
	assert(r == compilation::FATAL_ERROR);
	comp.free();
	s.free();
}

// ---------------------------------------------------------------------------
// Output kinds, ownership and failures

fn void list_output_owns_copies() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Diagnostics d;
	d.init_list(&ta);
	char[] text = "temporary".copy(mem);
	ExpandedLocation loc = { .path = "p.c", .line = "line", .line_no = 3, .col = 2, .width = 1 };
	d.add({ .kind = ERROR, .text = (String)text, .has_location = true, .location = loc })!!;
	text[0] = 'X';
	alloc::free(mem, text.ptr);
	d.add({ .kind = NOTE, .text = "" })!!;
	check(d.messages.len(), 2);
	check(d.messages[0].text, "temporary");
	check(d.messages[0].location.path, "p.c");
	check(d.messages[0].location.line, "line");
	assert(d.messages[0].effective_kind == ERROR);
	assert(!d.messages[1].has_location);
	d.free();
	check(ta.allocation_count(), 0);
}

fn void ignore_output_counts() @test
{
	Diagnostics d;
	d.init_ignore();
	d.add(warn("w", UNUSED_VALUE))!!;
	d.add({ .kind = ERROR, .text = "e" })!!;
	check(d.warnings, 1);
	check(d.errors, 1);
	check(d.total, 2);
	d.free();
}

fn void output_failure_is_fatal() @test
{
	char[8] small;
	ByteWriter bw;
	bw.init_with_buffer(&small);
	Diagnostics d;
	d.init_writer(&bw, NO_COLOR);
	fault r = @catch(d.add(warn("this does not fit", UNUSED_VALUE)));
	assert(r == compilation::FATAL_ERROR);
	// counted before the write, like Zig
	check(d.warnings, 1);
	d.free();
}

fn void fatal_source_diagnostic_cleans_up() @test
{
	// -Werror -Wfatal-errors: the normalization warning aborts add_source_from_buffer
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	for (int round = 0; round < 3; round++)
	{
		Diagnostics d;
		d.init_list(&ta);
		d.state.error_warnings = true;
		d.state.fatal_errors = true;
		Compilation comp;
		comp.init(&ta, diagnostics: &d);
		Source? r = comp.add_source_from_buffer("f.c", "a\\ \nb\n");
		assert(@catch(r) == compilation::FATAL_ERROR);
		check(comp.sources.len(), 0);
		check(d.messages.len(), 1);
		assert(d.messages[0].effective_kind == FATAL_ERROR);
		check(d.messages[0].location.path, "f.c");
		// a later source still works after the failure is cleared
		d.state = diagnostics::DEFAULT_STATE;
		comp.add_source_from_buffer("g.c", "ok\n")!!;
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);

	// writer output failure during normalization, owned buffer stays with the caller
	TrackingAllocator ta2;
	ta2.init(mem);
	defer ta2.free();
	char[4] small;
	ByteWriter bw;
	bw.init_with_buffer(&small);
	Diagnostics d;
	d.init_writer(&bw, NO_COLOR);
	Compilation comp;
	comp.init(&ta2, diagnostics: &d);
	String raw = "a\\ \nb";
	char* p = alloc::malloc(&ta2, raw.len + 1);
	mem::copy(p, raw.ptr, raw.len);
	p[raw.len] = 0;
	Source? r = comp.add_source_from_owned_buffer("h.c", p[:raw.len], USER);
	assert(@catch(r) == compilation::FATAL_ERROR);
	alloc::free(&ta2, p);
	comp.free();
	d.free();
	check(ta2.allocation_count(), 0);
}

fn void owned_default_diagnostics() @test
{
	// Compilation without a diagnostics sink owns an IGNORE one that still counts.
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	Compilation comp;
	comp.init(&ta);
	comp.add_source_from_buffer("x.c", "a\\ \nb")!!;
	check(comp.warning_count(), 1);
	assert(comp.diagnostics.output == IGNORE);
	comp.free();
	check(ta.allocation_count(), 0);
}

// ---------------------------------------------------------------------------
// Templates

fn String fmt_to(ByteWriter* bw, String fmt, DiagArg[] args)
{
	bw.index = 0;
	diagnostics::format_args(bw, fmt, args)!!;
	return bw.str_view();
}

fn void templates() @test
{
	ByteWriter bw;
	bw.init(mem);
	defer (void)bw.destroy();
	check(fmt_to(&bw, compilation::DIAG_MS_SEARCH_RULE.fmt, { diagnostics::arg_str("dir/a.h") }),
		"#include resolved using non-portable Microsoft search rules as: dir/a.h");
	check(fmt_to(&bw, "{s} has {d} of {d} bits", { diagnostics::arg_str("x"), diagnostics::arg_int(-3), diagnostics::arg_uint(ulong::max) }),
		"x has -3 of 18446744073709551615 bits");
	check(fmt_to(&bw, "no args", {}), "no args");
	check(fmt_to(&bw, "{d}", { diagnostics::arg_str("s") }),
		"template `{s}` not found in format string `{d}` (this is a bug in arocc)s{d}");
	// a template from a phase-specific table is used like Zig's Diagnostic constants
	Message m = compilation::DIAG_CTRL_Z_EOF.message(compilation::DIAG_CTRL_Z_EOF.fmt);
	assert(m.extension && m.kind == OFF && m.opt == MICROSOFT_END_OF_FILE);
}
