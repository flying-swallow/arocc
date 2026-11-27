// Test suite runner for aro_cc/test/test_suite, structured after c3c's
// aro_cc/test/src/test_suite_runner.c3.
//
// Every case is one self-contained file: `.c` holds a single translation
// unit, `.ct` may also hold extra input files (`// #file: name`) and an
// expected stdout section (`// #expect: stdout`). Directives:
//
//   header (own line, removed from the written file):
//     // #kind: syntax | syntax_ignore_errors | expand | expand_partial | expand_error | run
//     // #opt: <args>          compiler arguments, split on spaces (repeatable)
//     // #env: K=V [K=V...]    child environment overrides (repeatable)
//     // #exit: N              expected exit status (compiler, or program for `run`)
//     // #skip: <reason>       known failure: not run (`-s` runs only these)
//     // #todo: <note>         informational, ignored by the runner
//     // #error: <text>        expected diagnostic anywhere (any file or none);
//     // #warning: / #note: / #fatal:   <text> is a substring of `loc: message`
//     // #file: <name>         .ct: start another input file (written, not passed;
//                              for `run`, extra `.c` files are compiled with the
//                              same flags and linked in as separate units)
//     // #expect: stdout       .ct: the rest of the section is the expected stdout
//
//   trailing (after code, removed from the written line):
//     <code> // #error: <message>        diagnostic on this line
//     <code> // #warning@12: <message>   ... at column 12
//
// Removing directives keeps the compiled source byte-identical to the case's
// code, so line, column and comment-preserving output are not disturbed.
// Diagnostics are matched as a set: each one must match a distinct
// expectation and every expectation must be matched. Expectations with a column
// are tried first, then column-less ones on the line, then header ones. A case
// that expects an error must also see a nonzero compiler exit (unless `#exit`).
// Every child process is killed after CHILD_TIMEOUT_MS on POSIX hosts.
module test_suite_runner;
import std::io, std::io::path, std::io::file, std::collections::list, std::sort;
import std::atomic, std::thread, std::os::env, std::time;
import aro_runner, aro_harness;

// ---------------------------------------------------------------------------
// Case model
// ---------------------------------------------------------------------------

enum CaseKind
{
	SYNTAX,
	SYNTAX_IGNORE_ERRORS,
	EXPAND,
	EXPAND_PARTIAL,
	EXPAND_ERROR,
	RUN,
}

const String[*] KIND_NAMES = { "syntax", "syntax_ignore_errors", "expand", "expand_partial", "expand_error", "run" };

fn String CaseKind.name(self) => KIND_NAMES[self.ordinal];

fn CaseKind? kind_from_name(String name)
{
	foreach (i, n : KIND_NAMES)
	{
		if (n == name) return (CaseKind)i;
	}
	return NOT_FOUND~;
}

<* One expected diagnostic. `line == 0` means anywhere (header form). *>
struct Expect
{
	String kind;    // "error", "warning", "note", "fatal error"
	int line;
	int col;        // 0: any column
	String text;
	bool found;
}

struct RunFile
{
	String name;
	DString content;
	List{Expect} diags;
	int line_no;    // line number of the next written line
}

struct CaseSpec
{
	CaseKind kind;
	List{String} opts;
	List{EnvPair} env;
	bool has_exit;
	int exit_code;
	bool skip;
	String skip_reason;
	List{RunFile*} files;   // files[0] is the translation unit
	List{Expect} anywhere;
	bool has_expect;
	DString expect_stdout;
}

fn bool CaseSpec.expects_errors(&self)
{
	foreach (e : self.anywhere)
	{
		if (e.kind == "error" || e.kind == "fatal error") return true;
	}
	foreach (f : self.files)
	{
		foreach (e : f.diags)
		{
			if (e.kind == "error" || e.kind == "fatal error") return true;
		}
	}
	return false;
}

fn String? diag_kind(String key)
{
	switch (key)
	{
		case "error": return "error";
		case "warning": return "warning";
		case "note": return "note";
		case "fatal": return "fatal error";
		default: return NOT_FOUND~;
	}
}

fn bool is_header_key(String key)
{
	switch (key)
	{
		case "kind":
		case "opt":
		case "env":
		case "exit":
		case "skip":
		case "todo":
		case "error":
		case "warning":
		case "note":
		case "fatal":
		case "file":
		case "expect":
			return true;
		default:
			return false;
	}
}

<*
 A directive body `key[@col]: value` (text after `// #`). Returns false when
 the text is not a well-formed directive with a known key.
*>
struct Directive
{
	String key;
	int col;
	String value;
}

fn bool parse_directive(String body, Directive* out)
{
	sz? colon = body.index_of_char(':');
	if (catch colon) return false;
	String key = body[:colon];
	int col = 0;
	if (try at = key.index_of_char('@'))
	{
		String digits = key[at + 1..];
		if (!digits.len) return false;
		foreach (c : digits) if (c < '0' || c > '9') return false;
		col = digits.to_int()!!;
		key = key[:at];
		if (@catch(diag_kind(key))) return false;
	}
	if (!is_header_key(key)) return false;
	*out = { .key = key, .col = col, .value = body[colon + 1..].trim() };
	return true;
}

<* Splits on `delimiter` keeping empty segments: "a\n" gives { "a", "" }. *>
fn String[] split_all(Allocator a, String buffer, char delimiter)
{
	List{String} out;
	out.init(a);
	LineSplitter it = aro_runner::split_scalar(buffer, delimiter);
	while (try part = it.next()) out.push(part);
	return out.array_view();
}

fn String strip_cr(String line) => line.len && line[^1] == '\r' ? line[:line.len - 1] : line;

<* `line` (without '\r') is a header directive. *>
fn bool header_directive(String line, Directive* out)
{
	if (!line.starts_with("// #")) return false;
	return parse_directive(line[4..], out);
}

<*
 Splits trailing directives off a code line. Returns the index where the
 directives start (the space before `// #`), or line.len when there are none.
*>
fn sz trailing_start(String line)
{
	sz from = 0;
	while (from < line.len)
	{
		sz? rel = line[from..].index_of(" // #");
		if (catch rel) return line.len;
		sz at = from + rel;
		Directive d;
		if (parse_directive(line[at + 5..], &d) && @ok(diag_kind(d.key))) return at;
		from = at + 1;
	}
	return line.len;
}

fn RunFile* new_run_file(Allocator a, String name)
{
	RunFile* f = alloc::new(a, RunFile);
	f.name = name;
	f.content.init(a);
	f.diags.init(a);
	f.line_no = 1;
	return f;
}

fn String default_file_name(String case_path)
{
	String base = aro_runner::basename(case_path);
	if (base.ends_with(".ct")) return base[:base.len - 3].tconcat(".c");
	return base;
}

<*
 Parses a case file. `name` is the case file's basename; diagnostics go to
 `log`. Returns false on a malformed case.
*>
fn bool parse_case(Allocator a, String name, String contents, CaseSpec* spec, DString* log)
{
	bool multi = name.ends_with(".ct");
	*spec = { .kind = SYNTAX };
	spec.opts.init(a);
	spec.env.init(a);
	spec.files.init(a);
	spec.anywhere.init(a);
	spec.expect_stdout.init(a);

	RunFile* current = new_run_file(a, default_file_name(name));
	spec.files.push(current);
	bool in_expect = false;

	String[] lines = split_all(a, contents, '\n');
	foreach (idx, raw : lines)
	{
		bool last = idx + 1 == lines.len;
		String line = strip_cr(raw);
		Directive d;
		bool header = header_directive(line, &d);
		if (in_expect)
		{
			if (header && (d.key == "file" || d.key == "expect"))
			{
				// fall through to the section switch below
			}
			else
			{
				spec.expect_stdout.append(raw);
				if (!last) spec.expect_stdout.append_char('\n');
				continue;
			}
		}
		if (header)
		{
			switch (d.key)
			{
				case "kind":
					CaseKind? k = kind_from_name(d.value);
					if (catch k)
					{
						log.appendf("FAILED - unknown kind '%s'\n", d.value);
						return false;
					}
					spec.kind = k;
				case "opt":
					foreach (arg : aro_runner::tokenize_scalar(a, d.value, ' '))
					{
						if (arg.len) spec.opts.push(arg);
					}
				case "env":
					foreach (kv : aro_runner::tokenize_scalar(a, d.value, ' '))
					{
						if (!kv.len) continue;
						sz? eq = kv.index_of_char('=');
						if (catch eq)
						{
							log.appendf("FAILED - invalid env entry '%s'\n", kv);
							return false;
						}
						spec.env.push({ .key = kv[:eq], .value = kv[eq + 1..] });
					}
				case "exit":
					int? code = d.value.to_int();
					if (catch code)
					{
						log.appendf("FAILED - invalid exit status '%s'\n", d.value);
						return false;
					}
					spec.has_exit = true;
					spec.exit_code = code;
				case "skip":
					spec.skip = true;
					spec.skip_reason = d.value;
				case "todo":
					break;
				case "error":
				case "warning":
				case "note":
				case "fatal":
					if (d.col)
					{
						log.appendf("FAILED - a column needs a trailing directive: '%s'\n", line);
						return false;
					}
					spec.anywhere.push({ .kind = diag_kind(d.key)!!, .text = d.value });
				case "file":
					if (!multi)
					{
						log.appendf("FAILED - 'file' directive only allowed in .ct cases\n");
						return false;
					}
					in_expect = false;
					current = new_run_file(a, d.value);
					spec.files.push(current);
				case "expect":
					if (!multi)
					{
						log.appendf("FAILED - 'expect' directive only allowed in .ct cases\n");
						return false;
					}
					if (d.value != "stdout")
					{
						log.appendf("FAILED - unsupported expect target '%s' (only 'stdout')\n", d.value);
						return false;
					}
					if (spec.has_expect)
					{
						log.appendf("FAILED - duplicate 'expect' section\n");
						return false;
					}
					spec.has_expect = true;
					in_expect = true;
				default:
					unreachable();
			}
			continue;
		}

		// Code line: split off trailing directives.
		sz cut = trailing_start(line);
		if (cut < line.len)
		{
			String rest = line[cut + 5..];
			while (true)
			{
				sz body_end = rest.len;
				String next_rest = "";
				sz from = 0;
				while (try rel = rest[from..].index_of(" // #"))
				{
					sz at = from + rel;
					Directive probe;
					if (parse_directive(rest[at + 5..], &probe) && @ok(diag_kind(probe.key)))
					{
						body_end = at;
						next_rest = rest[at + 5..];
						break;
					}
					from = at + 1;
				}
				Directive td;
				if (!parse_directive(rest[:body_end], &td))
				{
					log.appendf("FAILED - malformed trailing directive '%s'\n", rest[:body_end]);
					return false;
				}
				current.diags.push({ .kind = diag_kind(td.key)!!, .line = current.line_no, .col = td.col, .text = td.value });
				if (body_end == rest.len) break;
				rest = next_rest;
			}
			current.content.append(line[:cut]);
			if (raw.len != line.len) current.content.append_char('\r');
		}
		else
		{
			current.content.append(raw);
		}
		if (!last) current.content.append_char('\n');
		current.line_no++;
	}

	switch (spec.kind)
	{
		case EXPAND:
		case EXPAND_PARTIAL:
			if (!spec.has_expect)
			{
				log.appendf("FAILED - kind %s needs an '// #expect: stdout' section (use a .ct case)\n", spec.kind.name());
				return false;
			}
		case RUN:
			if (!spec.has_exit)
			{
				log.appendf("FAILED - kind run needs '// #exit: N'\n");
				return false;
			}
		default:
			break;
	}
	return true;
}

// ---------------------------------------------------------------------------
// Diagnostic matching
// ---------------------------------------------------------------------------

struct Diag
{
	String loc;     // "file:line:col" or "" when the diagnostic has no location
	String file;
	int line;
	int col;
	String kind;
	String msg;
	String text;    // the whole line
}

const String[*] DIAG_KINDS = { "fatal error", "error", "warning", "note" };

fn bool all_digits(String s)
{
	if (!s.len) return false;
	foreach (c : s) if (c < '0' || c > '9') return false;
	return true;
}

<* Parses one Aro diagnostic line `loc: kind: message` or `kind: message`. *>
fn bool parse_diag(String line, Diag* out)
{
	line = strip_cr(line);
	foreach (k : DIAG_KINDS)
	{
		String prefix = k.tconcat(": ");
		if (line.starts_with(prefix))
		{
			*out = { .kind = k, .msg = line[prefix.len..], .text = line };
			return true;
		}
	}
	// The earliest `: kind: ` separates the location from the message.
	sz best = line.len;
	String best_kind;
	foreach (k : DIAG_KINDS)
	{
		String sep = string::tformat(": %s: ", k);
		if (try at = line.index_of(sep))
		{
			if (at < best)
			{
				best = at;
				best_kind = k;
			}
		}
	}
	if (best == line.len) return false;
	String loc = line[:best];
	*out = { .loc = loc, .kind = best_kind, .msg = line[best + best_kind.len + 4..], .text = line };
	sz? c2 = loc.rindex_of_char(':');
	if (catch c2) return false;
	String col = loc[c2 + 1..];
	String rest = loc[:c2];
	sz? c1 = rest.rindex_of_char(':');
	if (catch c1) return false;
	String ln = rest[c1 + 1..];
	if (!all_digits(col) || !all_digits(ln)) return false;
	out.file = rest[:c1];
	out.line = ln.to_int()!!;
	out.col = col.to_int()!!;
	return true;
}

<*
 Matching pass: EXACT_COLUMN takes only `@col` line expectations, ANY_COLUMN
 only column-less ones, ANYWHERE the header (`line == 0`) expectations. Running
 the passes over all diagnostics in order keeps a column-less expectation from
 absorbing a diagnostic a more specific one on the same line needs.
*>
enum MatchPass
{
	EXACT_COLUMN,
	ANY_COLUMN,
	ANYWHERE,
}

fn bool find_and_mark(CaseSpec* spec, Diag* d, MatchPass pass)
{
	if (pass != ANYWHERE)
	{
		if (!d.line) return false;
		String base = aro_runner::basename(d.file);
		foreach (f : spec.files)
		{
			if (f.name != base && f.name != d.file) continue;
			foreach (&e : f.diags)
			{
				if (e.found || e.line != d.line || e.kind != d.kind) continue;
				if (pass == EXACT_COLUMN ? e.col != d.col : e.col != 0) continue;
				if (!d.msg.contains(e.text)) continue;
				e.found = true;
				return true;
			}
		}
		return false;
	}
	String full = d.loc.len ? string::tformat("%s: %s", d.loc, d.msg) : d.msg;
	foreach (&e : spec.anywhere)
	{
		if (e.found || e.kind != d.kind || !full.contains(e.text)) continue;
		e.found = true;
		return true;
	}
	return false;
}

fn void print_list(DString* out, String title, List{String}* items)
{
	if (items.is_empty()) return;
	out.appendf("\n %s:\n ------------------------------\n", title);
	foreach (s : *items) out.appendf("%s\n", s);
}

<* Checks stderr against the case's expectations; failures are written to `out`. *>
fn bool check_diagnostics(CaseSpec* spec, String stderr, DString* out)
{
	List{Diag} diags;
	diags.tinit();
	foreach (line : aro_runner::tokenize_scalar(tmem, stderr, '\n'))
	{
		Diag d;
		if (!parse_diag(line, &d)) continue;
		if (d.text == "note: --sysroot may be required when cross-compiling to Darwin targets") continue;
		diags.push(d);
	}
	List{bool} matched;
	matched.tinit();
	foreach (d : diags) matched.push(false);
	MatchPass[3] passes = { EXACT_COLUMN, ANY_COLUMN, ANYWHERE };
	foreach (pass : passes)
	{
		foreach (i, &d : diags)
		{
			if (!matched[i] && find_and_mark(spec, d, pass)) matched[i] = true;
		}
	}
	List{String} unexpected;
	unexpected.tinit();
	foreach (i, d : diags)
	{
		if (!matched[i]) unexpected.push(string::tformat(" - %s", d.text));
	}
	List{String} missed;
	missed.tinit();
	foreach (f : spec.files)
	{
		foreach (e : f.diags)
		{
			if (e.found) continue;
			if (e.col)
			{
				missed.push(string::tformat(" - %s:%d:%d: %s: %s", f.name, e.line, e.col, e.kind, e.text));
			}
			else
			{
				missed.push(string::tformat(" - %s:%d: %s: %s", f.name, e.line, e.kind, e.text));
			}
		}
	}
	foreach (e : spec.anywhere)
	{
		if (!e.found) missed.push(string::tformat(" - (anywhere) %s: %s", e.kind, e.text));
	}
	if (unexpected.is_empty() && missed.is_empty()) return true;
	out.append("FAILED - diagnostics differ\n");
	print_list(out, "Unexpected diagnostics", &unexpected);
	print_list(out, "Diagnostics that never occurred", &missed);
	out.append("\n [stderr]:\n");
	aro_runner::append_escaped(out, stderr);
	out.append("\n");
	return false;
}

// ---------------------------------------------------------------------------
// Runner context
// ---------------------------------------------------------------------------

struct TestRunnerContext
{
	String compiler_path;
	String cc_path;
	String support_dir;
	String opt_level;       // ARO_C3_OPT for `run` cases, default -O1
	String[] extra_flags;   // ARO_C3_FLAGS for `run` cases
	bool native_host;
	Atomic{int} current_task_index;
	Atomic{int} test_count;
	Atomic{int} skip_count;
	Atomic{int} success_count;
	Atomic{int} failure_count;
	Atomic{bool} should_quit;
	bool no_terminal;
	bool only_skipped;
	Mutex print_mutex;
	String[] files_to_test;
	String test_root;
	String failures_path;
	DString failures;
}

struct WorkerContext
{
	int worker_id;
	String test_dir;
}

TestRunnerContext context;

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

fn void? copy_tree(String from, String to)
{
	(void)path::mkdir(to.to_tpath()!, recursive: true);
	PathList entries = path::ls(tmem, from.to_tpath()!)!;
	foreach (e : entries)
	{
		String src = aro_runner::join_path(tmem, from, (String)e);
		String dst = aro_runner::join_path(tmem, to, (String)e);
		if (path::is_dir(src.to_tpath()!))
		{
			copy_tree(src, dst)!;
		}
		else
		{
			file::save(dst, file::load_temp(src)!)!;
		}
	}
}

fn void? collect_files(String dir, List{String}* files)
{
	PathList entries = path::ls(tmem, dir.to_tpath()!)!;
	foreach (e : entries)
	{
		String name = (String)e;
		String full = aro_runner::join_path(mem, dir, name);
		if (path::is_dir(full.to_tpath()!))
		{
			if (name.starts_with("_")) continue; // _support and friends
			collect_files(full, files)!;
			continue;
		}
		if (name.ends_with(".c") || name.ends_with(".ct")) files.push(full);
	}
}

fn void sort_strings(String[] list)
{
	sort::quicksort(list, fn int(String a, String b) => a.compare_to(b));
}

// ---------------------------------------------------------------------------
// Core test logic
// ---------------------------------------------------------------------------

enum TestResult
{
	PASSED,
	FAILED,
	SKIPPED,
}

fn String[] child_env(CaseSpec* spec) => aro_runner::child_environment(tmem, spec.env.array_view());

<* Per child process (compiler, extra unit, link, `run` program). *>
const long CHILD_TIMEOUT_MS = 120_000;

struct CaseChild
{
	inline ChildResult result;
	bool timed_out;
}

<* Runs one child with CHILD_TIMEOUT_MS on POSIX (killing its process group). *>
fn CaseChild run_case_child(String[] argv, String cwd, String[] environment)
{
	$if env::POSIX:
		RunResult r = aro_harness::run(tmem, argv, { .cwd = cwd, .env = environment, .timeout_ms = CHILD_TIMEOUT_MS });
		return {
			.result = { .spawned = r.spawned, .exited = r.exited && !r.timed_out, .exit_code = r.exit_code,
				.signal = r.signal, .stdout = r.stdout, .stderr = r.stderr, .max_rss_kib = -1 },
			.timed_out = r.timed_out,
		};
	$else
		return { .result = aro_runner::run_child(tmem, argv, cwd, environment) };
	$endif
}

fn bool report_timeout(CaseChild* c, String what, DString* out)
{
	if (!c.timed_out) return false;
	out.appendf("FAILED - %s timed out after %ds\n", what, CHILD_TIMEOUT_MS / 1000);
	return true;
}

fn TestResult test_file(String file_path, String test_dir, DString* out)
{
	char[]? bytes = file::load_temp(file_path);
	if (catch bytes)
	{
		out.appendf("FAILED - unable to read '%s'\n", file_path);
		return FAILED;
	}
	CaseSpec spec;
	if (!parse_case(tmem, aro_runner::basename(file_path), (String)bytes, &spec, out)) return FAILED;

	if (spec.skip != context.only_skipped) return SKIPPED;
	if (spec.kind == RUN && (!context.native_host || !context.cc_path.len)) return SKIPPED;

	foreach (f : spec.files)
	{
		String dest = aro_runner::join_path(tmem, test_dir, f.name);
		String parent = aro_runner::dirname(dest);
		if (parent != test_dir) (void)path::mkdir(parent.to_tpath()!!, recursive: true);
		if (catch file::save(dest, f.content.str_view()))
		{
			out.appendf("FAILED - unable to write '%s'\n", dest);
			return FAILED;
		}
	}
	defer
	{
		foreach (f : spec.files) (void)file::delete(aro_runner::join_path(tmem, test_dir, f.name));
	}

	String main_name = spec.files[0].name;
	List{String} cmd;
	cmd.tinit();
	cmd.push(context.compiler_path);
	String object_name = string::tformat("%s.o", main_name);
	switch (spec.kind)
	{
		case SYNTAX:
		case SYNTAX_IGNORE_ERRORS:
			cmd.push_all({ "-fno-color-diagnostics", main_name, "-fsyntax-only", "--verbose-ast" });
		case EXPAND:
		case EXPAND_PARTIAL:
		case EXPAND_ERROR:
			cmd.push_all({ "-fno-color-diagnostics", main_name, "-E", "-P" });
		case RUN:
			cmd.push("-fno-color-diagnostics");
			cmd.push_all(context.extra_flags);
			cmd.push_all({ context.opt_level, "-c", main_name, "-o", object_name });
	}
	cmd.push_all(spec.opts.array_view());

	if (context.should_quit.load()) return FAILED;
	CaseChild r = run_case_child(cmd.array_view(), test_dir, child_env(&spec));
	String command = string::join(tmem, cmd.array_view(), " ");
	if (report_timeout(&r, string::tformat("compiler (%s)", command), out)) return FAILED;
	if (!r.spawned)
	{
		out.appendf("FAILED - unable to spawn: %s\n", command);
		return FAILED;
	}
	if (!r.exited)
	{
		out.appendf("FAILED - compiler crashed (signal %d): %s\n [stderr]:\n", r.signal, command);
		aro_runner::append_escaped(out, r.stderr);
		out.append("\n");
		return FAILED;
	}

	if (spec.kind != SYNTAX_IGNORE_ERRORS)
	{
		if (!check_diagnostics(&spec, r.stderr, out))
		{
			out.appendf(" command: %s\n", command);
			return FAILED;
		}
	}

	if (spec.kind == RUN)
	{
		defer (void)file::delete(aro_runner::join_path(tmem, test_dir, object_name));
		if (r.exit_code != 0)
		{
			out.appendf("FAILED - compile exited with %d: %s\n", r.exit_code, command);
			aro_runner::append_escaped(out, r.stderr);
			return FAILED;
		}
		List{String} link_cmd;
		link_cmd.tinit();
		link_cmd.push_all({ context.cc_path, object_name });
		defer
		{
			foreach (i, arg : link_cmd)
			{
				if (i >= 2 && arg.ends_with(".c.o")) (void)file::delete(aro_runner::join_path(tmem, test_dir, arg));
			}
		}
		// Extra `.c` inputs are separate translation units (e.g. weak overrides).
		foreach (i, f : spec.files)
		{
			if (i == 0 || !f.name.ends_with(".c")) continue;
			String unit_object = string::tformat("%s.o", f.name);
			List{String} unit_cmd;
			unit_cmd.tinit();
			unit_cmd.push_all({ context.compiler_path, "-fno-color-diagnostics" });
			unit_cmd.push_all(context.extra_flags);
			unit_cmd.push_all({ context.opt_level, "-c", f.name, "-o", unit_object });
			unit_cmd.push_all(spec.opts.array_view());
			CaseChild unit = run_case_child(unit_cmd.array_view(), test_dir, child_env(&spec));
			link_cmd.push(unit_object);
			if (report_timeout(&unit, "extra unit", out)) return FAILED;
			if (!unit.spawned || !unit.exited || unit.exit_code != 0 || unit.stderr.len)
			{
				out.appendf("FAILED - extra unit failed: %s\n", string::join(tmem, unit_cmd.array_view(), " "));
				aro_runner::append_escaped(out, unit.stderr);
				return FAILED;
			}
		}
		String exe_name = string::tformat("%s.exe", main_name);
		defer (void)file::delete(aro_runner::join_path(tmem, test_dir, exe_name));
		link_cmd.push_all({ "-o", exe_name });
		CaseChild link = run_case_child(link_cmd.array_view(), test_dir, child_env(&spec));
		if (report_timeout(&link, "link", out)) return FAILED;
		if (!link.spawned || !link.exited || link.exit_code != 0)
		{
			out.appendf("FAILED - link failed:\n");
			aro_runner::append_escaped(out, link.stderr);
			return FAILED;
		}
		CaseChild prog = run_case_child({ aro_runner::join_path(tmem, test_dir, exe_name) }, test_dir, child_env(&spec));
		if (report_timeout(&prog, "program", out)) return FAILED;
		int status = !prog.spawned ? 127 : prog.exited ? prog.exit_code : 128 + prog.signal;
		if (status != spec.exit_code)
		{
			out.appendf("FAILED - program exit status %d, expected %d\n", status, spec.exit_code);
			return FAILED;
		}
		if (spec.has_expect && prog.stdout != spec.expect_stdout.str_view())
		{
			aro_runner::report_strings_mismatch(out, spec.expect_stdout.str_view(), prog.stdout);
			return FAILED;
		}
		return PASSED;
	}

	if (spec.has_exit)
	{
		if (r.exit_code != spec.exit_code)
		{
			out.appendf("FAILED - compiler exited with %d, expected %d: %s\n", r.exit_code, spec.exit_code, command);
			return FAILED;
		}
	}
	else if (r.exit_code != 0 && r.exit_code != 1)
	{
		out.appendf("FAILED - compiler exited with %d: %s\n", r.exit_code, command);
		return FAILED;
	}
	else if (r.exit_code != 0 && spec.kind != SYNTAX_IGNORE_ERRORS && !spec.expects_errors())
	{
		out.appendf("FAILED - compiler exited with %d but no errors were expected: %s\n", r.exit_code, command);
		return FAILED;
	}
	else if (r.exit_code == 0 && spec.kind != SYNTAX_IGNORE_ERRORS && spec.expects_errors())
	{
		out.appendf("FAILED - compiler reported the expected errors but exited with 0: %s\n", command);
		return FAILED;
	}

	if (spec.has_expect)
	{
		String expected = spec.expect_stdout.str_view();
		bool ok = spec.kind == EXPAND_PARTIAL ? r.stdout.ends_with(expected) : r.stdout == expected;
		if (!ok)
		{
			out.append(spec.kind == EXPAND_PARTIAL ? "FAILED - stdout does not end with the expected output\n" : "FAILED - stdout differs\n");
			aro_runner::report_strings_mismatch(out, expected, r.stdout);
			out.appendf(" command: %s\n", command);
			return FAILED;
		}
	}
	return PASSED;
}

// ---------------------------------------------------------------------------
// Status / progress
// ---------------------------------------------------------------------------

const String CLEAR_LINE = "\e[2K";
const String MOVETO_COLUMN_ONE = "\r";
const String RED = "\e[31m";
const String GREEN = "\e[32m";
const String RESET = "\e[0m";

fn void update_status(String filename)
{
	if (context.no_terminal) return;
	context.print_mutex.lock();
	defer context.print_mutex.unlock();
	const String[8] PARTS = { " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };
	int width = 25;
	sz total = context.files_to_test.len;
	sz finished = context.test_count.load();
	double fraction = total > 0 ? finished / (double)total : 0;
	int full = (int)(fraction * width);
	int remainder = (int)(8 * (fraction * width - full));
	io::printf("%s%s%sTest progress: [", RESET, CLEAR_LINE, MOVETO_COLUMN_ONE);
	int failed = context.failure_count.load();
	io::print(failed ? RED : GREEN);
	for (int i = 0; i < full; i++) io::print("█");
	if (full != width) io::print(PARTS[remainder]);
	for (int i = full + 1; i < width; i++) io::print(" ");
	io::printf("%s] %.1f%% complete (%d failed)", RESET, fraction * 100.0, failed);
	if (filename.len) io::printf(" - Testing: %s", aro_runner::basename(filename));
	(void)io::stdout().flush();
}

fn void print_failure(String file_path, String output, int failure_count)
{
	context.print_mutex.lock();
	defer context.print_mutex.unlock();
	if (context.no_terminal)
	{
		io::printf("- %d %s: %s", failure_count, file_path, output);
		if (!output.ends_with("\n")) io::printn();
		return;
	}
	io::printfn("%s%s%s", RESET, CLEAR_LINE, MOVETO_COLUMN_ONE);
	io::print(RED);
	io::print("╭");
	for (int i = 2; i < 80; i++) io::print("─");
	io::printn("╮" +++ RESET);
	io::printf("- %d %s: %s", failure_count, file_path, output);
	if (!output.ends_with("\n")) io::printn();
	io::print(RED);
	io::print("╰");
	for (int i = 2; i < 80; i++) io::print("─");
	io::printn("╯" +++ RESET);
}

fn void record_failure(String file_path, String output)
{
	if (!context.failures_path.len) return;
	String first = output;
	if (try nl = output.index_of_char('\n')) first = output[:nl];
	context.print_mutex.lock();
	defer context.print_mutex.unlock();
	context.failures.appendf("%s\t%s\n", file_path, first);
}

fn void run_single_test(String file_path, String test_dir)
{
	if (context.should_quit.load()) return;
	@pool()
	{
		update_status(file_path);
		DString out;
		out.tinit();
		TestResult result = test_file(file_path, test_dir, &out);
		context.test_count.add(1);
		switch (result)
		{
			case PASSED:
				context.success_count.add(1);
			case SKIPPED:
				context.skip_count.add(1);
			case FAILED:
				int n = context.failure_count.add(1) + 1;
				print_failure(file_path, out.str_view(), n);
				record_failure(file_path, out.str_view());
		}
		update_status("");
	};
}

fn int worker_thread_main(void* arg)
{
	WorkerContext* w = arg;
	@pool_init(mem, 1 << 20)
	{
		if (catch copy_tree(context.support_dir, w.test_dir))
		{
			if (!path::is_dir(w.test_dir.to_tpath()!!)) (void)path::mkdir(w.test_dir.to_tpath()!!, recursive: true);
		}
	};
	while (!context.should_quit.load())
	{
		int idx = context.current_task_index.add(1);
		if (idx >= context.files_to_test.len) break;
		@pool_init(mem, 1 << 20)
		{
			run_single_test(context.files_to_test[idx], w.test_dir);
		};
	}
	return 0;
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

fn void usage(String appname) @noreturn
{
	io::printfn("Usage: %s <aro_cc path> <file/dir> [options]", appname);
	io::printn();
	io::printn("Options:");
	io::printn(" -s, --skipped       only run skipped tests");
	io::printn(" --no-terminal       disable color and dynamic status line");
	io::printn(" --support <dir>     shared include trees (default: nearest _support)");
	io::printn(" --cc <path>         C compiler used to link `run` cases");
	io::printn(" --threads <N>       worker threads (default: CPU count)");
	io::printn(" --failures <file>   write `<path>\\t<reason>` for each failed case");
	io::printn();
	io::printn("Environment: ARO_C3_OPT (default -O1) and ARO_C3_FLAGS apply to `run` cases.");
	os::exit(2);
}

fn String find_support(String start)
{
	String dir = start;
	for (int i = 0; i < 4; i++)
	{
		String candidate = aro_runner::join_path(mem, dir, "_support");
		if (path::is_dir(candidate.to_tpath()!!)) return candidate;
		String parent = aro_runner::dirname(dir);
		if (parent == dir || !parent.len) break;
		dir = parent;
	}
	return "";
}

fn int run_main(String[] args)
{
	String appname = args[0];
	if (args.len < 3) usage(appname);

	context.no_terminal = !io::stdout().isatty();
	context.print_mutex.init()!!;
	context.failures.init(mem);
	context.compiler_path = aro_runner::absolute_from_cwd(mem, args[1]);
	if (!path::is_file(context.compiler_path.to_tpath()!!))
	{
		io::eprintfn("Error: invalid path to compiler: %s", context.compiler_path);
		return 2;
	}
	String target = aro_runner::absolute_from_cwd(mem, args[2]);
	int threads = 0;
	for (int i = 3; i < args.len; i++)
	{
		String arg = args[i];
		switch (arg)
		{
			case "--no-terminal":
				context.no_terminal = true;
			case "-s":
			case "--skipped":
				context.only_skipped = true;
			case "--support":
			case "--cc":
			case "--threads":
			case "--failures":
				if (i + 1 >= (int)args.len) usage(appname);
				String value = args[++i];
				if (arg == "--support") context.support_dir = aro_runner::absolute_from_cwd(mem, value);
				if (arg == "--cc") context.cc_path = aro_runner::absolute_from_cwd(mem, value);
				if (arg == "--threads") threads = value.to_int() ?? 0;
				if (arg == "--failures") context.failures_path = aro_runner::absolute_from_cwd(mem, value);
			default:
				io::eprintfn("Unknown option '%s'.", arg);
				usage(appname);
		}
	}

	context.native_host = env::LINUX && env::X86_64;
	String opt = env::tget_var("ARO_C3_OPT") ?? "";
	context.opt_level = opt.len ? opt.copy(mem) : "-O1";
	String flags = env::tget_var("ARO_C3_FLAGS") ?? "";
	List{String} flag_list;
	flag_list.init(mem);
	foreach (f : aro_runner::tokenize_scalar(mem, flags, ' ')) if (f.len) flag_list.push(f);
	context.extra_flags = flag_list.array_view();
	if (context.cc_path.len && env::POSIX)
	{
		// aro_cc finds `as` next to the declared cc through PATH.
		String old_path = env::tget_var("PATH") ?? "";
		env::set_var("PATH", string::tformat("%s:%s", aro_runner::dirname(context.cc_path), old_path));
	}

	List{String} collected;
	collected.init(mem);
	if (path::is_file(target.to_tpath()!!))
	{
		collected.push(target);
		if (!context.support_dir.len) context.support_dir = find_support(aro_runner::dirname(target));
	}
	else if (path::is_dir(target.to_tpath()!!))
	{
		if (catch collect_files(target, &collected))
		{
			io::eprintfn("Error: cannot read %s", target);
			return 2;
		}
		if (!context.support_dir.len) context.support_dir = find_support(target);
	}
	else
	{
		io::eprintfn("Error: path wasn't to directory or file: %s", target);
		return 2;
	}
	sort_strings(collected.array_view());
	context.files_to_test = collected.array_view();

	Path? tmp = path::temp_directory(mem);
	String tmp_root = env::tget_var("TEST_TMPDIR") ?? "";
	if (!tmp_root.len) tmp_root = (String)(tmp ?? (Path)"/tmp");
	context.test_root = string::format(mem, "%s/aro_test_suite_%d", tmp_root, (long)time::now());

	if (threads <= 0) threads = (int)os::num_cpu();
	if (threads > context.files_to_test.len) threads = (int)context.files_to_test.len;
	if (threads < 1) threads = 1;

	WorkerContext[] workers = mem::new_array(WorkerContext, threads);
	Thread[] handles = mem::new_array(Thread, threads);
	for (int i = 0; i < threads; i++)
	{
		workers[i] = { .worker_id = i, .test_dir = string::format(mem, "%s/worker_%d", context.test_root, i) };
		handles[i].create(&worker_thread_main, &workers[i])!!;
	}
	for (int i = 0; i < threads; i++) (void)handles[i].join();
	(void)path::rmtree(context.test_root.to_tpath()!!);
	if (context.failures_path.len) (void)file::save(context.failures_path, context.failures.str_view());

	int total = context.test_count.load();
	int success = context.success_count.load();
	int skipped = context.skip_count.load();
	int failed = context.failure_count.load();
	int run = total - skipped;
	bool all_ok = failed == 0 && success == run;
	if (!context.no_terminal) io::print(all_ok ? GREEN : RED);
	io::printfn("\nFound %d tests: %.1f%% (%d / %d) passed (%d skipped, %d failed).",
		total, 100.0 * success / (run > 0 ? run : 1), success, run, skipped, failed);
	if (!context.no_terminal) io::print(RESET);
	return all_ok ? 0 : 1;
}
