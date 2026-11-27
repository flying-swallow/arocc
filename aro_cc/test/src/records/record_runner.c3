// Port of aro_cc/test/record_runner.zig. This module keeps the record-layout
// inventory and diagnostic classification independent of executable-parity
// claims; callers supply the arocc executable to run.
module aro_record_runner;
import aro, aro::host_process, aro::target;
import std::collections::list, std::io, std::io::path, std::sort;
import std::core::string;

struct RecordCase
{
	String path;
	String define;
	String target;
}

struct ExpectedFailure
{
	bool parse;
	bool layout;
	bool extra;
	bool offset;
}

struct RecordReport
{
	uint selected;
	uint executed;
	uint passed;
	uint skipped;
	uint expected_failures;
	uint invalid_targets;
	uint crashes;
	uint failures;
	uint unexpected_passes;
	uint excluded;
}

// The source runner currently has an empty global exclusion set. Keeping the
// lookup here preserves its post-execution exclusion behavior if entries are
// added to the Zig source later.
const String[] GLOBAL_TEST_EXCLUDES = {};

<*
 Expand each // MAPPING| line in source order. The returned case array, every
 path and every mapping value are owned by `a`.
*>
fn RecordCase[]? parse_mapping_text(Allocator a, String path, String contents)
{
	List{RecordCase} cases;
	cases.init(a);
	const String MARKER = "// MAPPING|";
	sz search = 0;
	while (search < contents.len)
	{
		sz? marker_offset = contents[search..].index_of(MARKER);
		if (catch marker_offset) break;
		sz marker = search + marker_offset;
		sz line_end = marker;
		while (line_end < contents.len && contents[line_end] != '\n') line_end++;
		String line = contents[marker:line_end - marker];
		search = line_end < contents.len ? line_end + 1 : contents.len;

		Splitter fields = line.tokenize("|");
		String? marker_field = fields.next();
		if (catch marker_field) continue;
		String? define_opt = fields.next();
		if (catch define_opt) continue;
		String define = define_opt;
		while (true)
		{
			String? target_opt = fields.next();
			if (catch target_opt) break;
			String target_name = target_opt;
			if (target_name.starts_with("END")) break;
			cases.push({
				.path = path.copy(a),
				.define = define.copy(a),
				.target = target_name.copy(a),
			});
		}
	}
	return cases.array_view();
}

<* Classify each `: error: ` line with the source excerpt immediately after it. *>
fn ExpectedFailure classify_diagnostics(String stderr)
{
	ExpectedFailure actual;
	sz line_start = 0;
	while (line_start < stderr.len)
	{
		sz line_end = line_start;
		while (line_end < stderr.len && stderr[line_end] != '\n') line_end++;
		String line = stderr[line_start:line_end - line_start];
		sz next_start = line_end < stderr.len ? line_end + 1 : stderr.len;
		if (line.contains(": error: ") && next_start < stderr.len)
		{
			sz excerpt_end = next_start;
			while (excerpt_end < stderr.len && stderr[excerpt_end] != '\n') excerpt_end++;
			String excerpt = stderr[next_start:excerpt_end - next_start];
			if (contains_ignore_case(excerpt, "_Static_assert"))
			{
				if (contains_ignore_case(excerpt, "_extra_"))
				{
					actual.extra = true;
				}
				else if (contains_ignore_case(excerpt, "_bitoffsetof"))
				{
					actual.offset = true;
				}
				else if (contains_ignore_case(excerpt, "sizeof") || contains_ignore_case(excerpt, "_alignof"))
				{
					actual.layout = true;
				}
				else
				{
					unreachable("unexpected _Static_assert diagnostic pattern");
				}
			}
			else
			{
				actual.parse = true;
			}
			line_start = excerpt_end < stderr.len ? excerpt_end + 1 : stderr.len;
		}
		else
		{
			line_start = next_start;
		}
	}
	return actual;
}

fn bool contains_ignore_case(String haystack, String needle)
{
	if (needle.len > haystack.len) return false;
	for (sz i = 0; i + needle.len <= haystack.len; i++)
	{
		if (haystack[i:needle.len].compare_to_ignore_case(needle) == 0) return true;
	}
	return false;
}

fn bool ExpectedFailure.has_any(&self) => self.parse || self.layout || self.extra || self.offset;

fn bool ExpectedFailure.eql(&self, ExpectedFailure other)
{
	return self.parse == other.parse && self.layout == other.layout &&
		self.extra == other.extra && self.offset == other.offset;
}

<* Expected diagnostics keyed to aro_cc/test/record_runner.zig's source compErr map. *>
fn ExpectedFailure expected_failure(String target_name, String test_name)
{
	if (target_name == "x86_64-x86_64-windows-gnu:Gcc" && test_name == "0068")
	{
		return { .layout = true, .extra = true };
	}
	if (target_name == "x86_64-x86_64-windows-gnu:Gcc" && test_name == "0082")
	{
		return { .layout = true, .extra = true };
	}
	return {};
}

fn bool is_globally_excluded(String test_name)
{
	foreach (exclude : GLOBAL_TEST_EXCLUDES) if (exclude == test_name) return true;
	return false;
}

fn int compare_strings(String lhs, String rhs) => lhs.compare_to(rhs);

fn String join_path(Allocator a, String dir, String name)
{
	if (!dir.len) return name.copy(a);
	if (dir[^1] == '/' || dir[^1] == '\\') return string::format(a, "%s%s", dir, name);
	return string::format(a, "%s/%s", dir, name);
}

fn String basename(String path)
{
	for (sz i = path.len; i > 0; i--)
	{
		if (path[i - 1] == '/' || path[i - 1] == '\\') return path[i..];
	}
	return path;
}

fn String record_test_name(String path)
{
	String name = basename(path);
	sz? underscore = name.index_of_char('_');
	if (catch underscore) return name;
	return name[:underscore];
}

fn void free_record_cases(Allocator a, RecordCase[] cases)
{
	foreach (c : cases)
	{
		alloc::free(a, c.path.ptr);
		alloc::free(a, c.define.ptr);
		alloc::free(a, c.target.ptr);
	}
	if (cases.ptr) alloc::free(a, cases.ptr);
}

fn void free_process_result(Allocator a, ProcessResult result)
{
	if (result.stdout.ptr) alloc::free(a, result.stdout.ptr);
	if (result.stderr.ptr) alloc::free(a, result.stderr.ptr);
}

fn void run_record_case(Allocator a, RecordCase c, String exe, OutStream out, RecordReport* report)
{
	sz? compiler_sep = c.target.index_of_char(':');
	if (catch compiler_sep)
	{
		(void)io::fprintfn(out, "case %s failed: missing compiler in target %s", c.path, c.target);
		report.failures++;
		return;
	}
	String target_part = c.target[:compiler_sep];
	String compiler = c.target[compiler_sep + 1..];
	String[4] pieces;
	sz piece_count = 0;
	sz cursor = 0;
	while (cursor < target_part.len && piece_count < 4)
	{
		while (cursor < target_part.len && target_part[cursor] == '-') cursor++;
		if (cursor == target_part.len) break;
		sz start = cursor;
		while (cursor < target_part.len && target_part[cursor] != '-') cursor++;
		pieces[piece_count++] = target_part[start:cursor - start];
	}
	if (piece_count < 4)
	{
		(void)io::fprintfn(out, "can't parse target %s", c.target);
		report.failures++;
		return;
	}

	String query = string::format(a, "%s-%s-%s", pieces[0], pieces[2], pieces[3]);
	defer alloc::free(a, query.ptr);
	target::Host? host_opt = target::host();
	if (catch host_opt)
	{
		(void)io::fprintfn(out, "can't parse %s %s: unsupported host target", query, pieces[1]);
		report.failures++;
		return;
	}
	target::Host host = host_opt;
	target::Target? target_opt = target::parse_triple(query, host, pieces[1]);
	if (catch target_opt)
	{
		(void)io::fprintfn(out, "can't parse %s %s", c.target, pieces[1]);
		report.failures++;
		return;
	}
	target::Target resolved = target_opt;
	if ((resolved.os.tag == target::OsTag.IOS || resolved.os.tag == target::OsTag.MACOS) &&
		(resolved.cpu.arch == target::Arch.X86 || resolved.cpu.arch == target::Arch.ARM))
	{
		report.invalid_targets++;
		return;
	}

	String emulate;
	if (compiler == "Clang")
	{
		emulate = "--emulate=clang";
	}
	else if (compiler == "Gcc")
	{
		emulate = "--emulate=gcc";
	}
	else if (compiler == "Msvc")
	{
		emulate = "--emulate=msvc";
	}
	else
	{
		(void)io::fprintfn(out, "case %s failed: invalid compiler %s", c.path, compiler);
		report.failures++;
		return;
	}

	List{String} argv;
	argv.init(a);
	defer argv.free();
	argv.push_all({
		exe, c.path, "-fsyntax-only", "-fno-color-diagnostics", "-target", query,
		"-mcpu", pieces[1], "--verbose-ast", "-D", c.define,
	});
	argv.push(emulate);
	if (resolved.abi == target::Abi.MSVC && compiler == "Clang") argv.push("-fms-extensions");
	if (resolved.abi == target::Abi.MSVC) argv.push("-DMSVC");

	ProcessResult result = host_process::SERVICE.run(host_process::SERVICE.ctx, a, argv.array_view());
	defer free_process_result(a, result);
	if (!result.started)
	{
		(void)io::fprintfn(out, "case %s failed: unable to start arocc", c.path);
		report.failures++;
		return;
	}
	report.executed++;
	if (!result.exited || result.exit_code < 0)
	{
		String command = string::join(a, argv.array_view(), " ");
		(void)io::fprintfn(out, "arocc command crashed:\n%s", command);
		alloc::free(a, command.ptr);
		report.crashes++;
		report.failures++;
		return;
	}

	String test_name = record_test_name(c.path);
	if (is_globally_excluded(test_name))
	{
		report.excluded++;
		report.skipped++;
		return;
	}

	ExpectedFailure expected = expected_failure(c.target, test_name);
	if (result.exit_code == 0 && expected.has_any())
	{
		(void)io::fprintfn(out, "Test Passed when failures expected: %s|%s", c.target, test_name);
		report.unexpected_passes++;
		report.failures++;
		return;
	}
	ExpectedFailure actual = classify_diagnostics(result.stderr);
	if (!expected.eql(actual))
	{
		(void)io::fprintfn(out, "in case %s|%s: expected parse=%d layout=%d extra=%d offset=%d; got parse=%d layout=%d extra=%d offset=%d",
			c.target, test_name, expected.parse, expected.layout, expected.extra, expected.offset,
			actual.parse, actual.layout, actual.extra, actual.offset);
		(void)io::fprint(out, result.stderr);
		report.failures++;
	}
	else if (actual.has_any())
	{
		report.expected_failures++;
		report.skipped++;
	}
	else
	{
		report.passed++;
	}
}

<* Enumerate and run every record mapping in lexicographic file order. *>
fn RecordReport run_suite(Allocator a, String records_dir, String exe, OutStream out)
{
	RecordReport report;
	PathList? entries_opt = path::ls(a, (path::Path)records_dir, true);
	if (catch entries_opt)
	{
		(void)io::fprintfn(out, "unable to open records directory: %s", records_dir);
		report.failures++;
		print_report(out, report);
		return report;
	}
	PathList entries = entries_opt;
	defer entries.free();
	List{String} files;
	files.init(a);
	defer files.free();
	foreach (entry : entries)
	{
		String name = (String)entry;
		if (!contains_ignore_case(name, "_test.c")) continue;
		String full = join_path(a, records_dir, name);
		bool is_file = file::is_file(full);
		alloc::free(a, full.ptr);
		if (is_file) files.push(name);
	}
	String[] ordered_files = files.array_view();
	quicksort(ordered_files, &compare_strings);

	foreach (name : ordered_files)
	{
		String full_path = join_path(a, records_dir, name);
		char[]? contents_opt = file::load(a, full_path);
		if (catch contents_opt)
		{
			(void)io::fprintfn(out, "case file could not be read: %s", full_path);
			report.failures++;
			alloc::free(a, full_path.ptr);
			continue;
		}
		char[] contents = contents_opt;
		RecordCase[] cases = parse_mapping_text(a, full_path, (String)contents)!!;
		alloc::free(a, full_path.ptr);
		if (cases.len > 0) report.selected += (uint)cases.len;
		foreach (c : cases) run_record_case(a, c, exe, out, &report);
		free_record_cases(a, cases);
		alloc::free(a, contents.ptr);
	}
	print_report(out, report);
	return report;
}

fn void print_report(OutStream out, RecordReport report)
{
	(void)io::fprintfn(out, "selected: %d", report.selected);
	(void)io::fprintfn(out, "executed: %d", report.executed);
	(void)io::fprintfn(out, "passed: %d", report.passed);
	(void)io::fprintfn(out, "skipped: %d", report.skipped);
	(void)io::fprintfn(out, "expected failures: %d", report.expected_failures);
	(void)io::fprintfn(out, "invalid targets: %d", report.invalid_targets);
	(void)io::fprintfn(out, "crashes: %d", report.crashes);
	(void)io::fprintfn(out, "failures: %d", report.failures);
	(void)io::fprintfn(out, "unexpected passes: %d", report.unexpected_passes);
	(void)io::fprintfn(out, "excluded: %d", report.excluded);
}
