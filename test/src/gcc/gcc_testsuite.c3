// C3 port of the old gcc_testsuite.py: run the GCC C testsuite (the copy in
// test/gcc) against aro_c3, treating GCC's expectations as golden.
//
//   compile  gcc.c-torture/compile/*.c        must compile cleanly
//   execute  gcc.c-torture/execute/*.c        must compile, link and exit 0
//   ieee     gcc.c-torture/execute/ieee/*.c   as execute
//   dg       gcc.dg/*.c                       dg-do action + dg-error/-warning/-bogus lines
//   asm      gcc.dg/*.c with scan-assembler   compile with -S, then the dg-final
//                                             scan-assembler / -not / -times checks
//
// Checks per case: crash sweep (signals, timeouts, aro panics), golden
// expectations (error/warning on the lines GCC lists, no errors otherwise;
// diagnostic text is not compared because GCC wording differs), execution, and
// optionally a differential run against a Zig arocc binary (--zig-arocc;
// informational, GCC stays golden).
//
// Results go to <out>/results.jsonl (one std::encoding::json record per line)
// and <out>/summary.md. The exit status is non-zero when any case is FAIL,
// CRASH or TIMEOUT; SKIP, UNSUPPORTED (check the harness cannot evaluate) and
// DIFF (informational Zig differential) do not fail the run.
// Not part of `bazel test //...` (targets are tagged manual): it is a worklist
// for migrating cases into the main unit tests, not a gate.
//
// asm suite: patterns are Tcl regexps (GCC's scanasm.exp runs `regexp` on the
// whole .s file, so `.` matches newline and ^/$ anchor the file). They are
// translated to POSIX ERE for std::encoding::experimental::regex; non-greedy
// quantifiers, (?...) groups and backreferences make the case UNSUPPORTED.
// aro_c3 emits Intel syntax and GCC's patterns often assume AT&T mnemonics and
// GCC's optimizer, so failures of checks guarded by an x86 target selector are
// reported under the separate category "x86-insn", and failures of cases that
// depend on a dropped flag (anything but -O levels) under "dropped-option".
//
// Text is handled as UTF-8 bytes after the same decoding Python applies
// (errors="replace" plus universal newlines); whitespace, splitlines and the
// 100/200-character truncations follow Python's str semantics.
module gcc_testsuite;
import std::io, std::io::path, std::io::file, std::collections::list, std::collections::map;
import std::sort, std::time, std::thread, std::encoding::json, std::collections::object, libc, aro_harness;
import std::encoding::experimental::regex;

const String TRIPLET = "x86_64-pc-linux-gnu";
const String TRIPLET_ALT = "x86_64-unknown-linux-gnu";

struct SuiteInfo
{
	String name;
	String rel;
	String action;
	<* Case file name glob. *>
	String glob;
}

const SuiteInfo[*] SUITES = {
	{ "compile", "gcc.c-torture/compile", "compile", "*.c" },
	{ "execute", "gcc.c-torture/execute", "run", "*.c" },
	{ "ieee", "gcc.c-torture/execute/ieee", "run", "*.c" },
	{ "dg", "gcc.dg", "compile", "*.c" },
	{ "asm", "gcc.dg", "compile", "*.c" },
	// gcc.target/x86_64/abi/abi-x86_64.exp: c-torture-execute of test_*.c linked
	// with asm-support.S (assembled by the host cc, see abi_support_object).
	{ "abi", "gcc.target/x86_64/abi", "run", "test_*.c" },
};

// abi-x86_64.exp additional_flags.
const String[*] ABI_FLAGS = { "-W", "-Wall", "-Wno-abi" };
const String ABI_SUPPORT_SOURCE = "asm-support.S";

// gcc.dg/dg.exp DEFAULT_CFLAGS (used when a test has no dg-options).
const String[*] DG_DEFAULT_FLAGS = { "-ansi", "-pedantic-errors" };
const String[*] TORTURE_FLAGS = { "-w" };

struct NamedBool
{
	String name;
	bool value;
}

// Effective targets for x86_64-linux lp64. Unknown keywords make the case SKIP
// (reason recorded) so the table can be grown deliberately.
const NamedBool[*] EFFECTIVE_TARGETS = {
	{
		"lp64", true
	}
	, { "ilp32", false }, { "llp64", false }, { "int32plus", true }, { "int32", true },
	{ "int16", false }, { "ptr32plus", true }, { "size32plus", true }, { "size20plus", true },
	{ "x86", true }, { "x86_64", true }, { "ia32", false }, { "nonpic", true }, { "fpic", true },
	{ "pie", true }, { "pthread", true }, { "sync_int_long", true }, { "sync_char_short", true },
	{ "int128", true }, { "double64", true }, { "double64plus", true }, { "large_double", true },
	{ "longdouble128", false }, { "large_long_double", true }, { "stdint_types", true },
	{ "wchar", true }, { "c99_runtime", true }, { "alloca", true }, { "trampolines", true },
	{ "nonlocal_goto", true }, { "indirect_jumps", true }, { "label_values", true },
	{ "signal", true }, { "untyped_assembly", true }, { "inttypes_types", true },
	{ "lto", false }, { "profiling", false }, { "dfp", false }, { "dfprt", false }, { "dll", false },
	{ "fixed_point", false }, { "freorder", true }, { "section_anchors", false },
	{ "tls", true }, { "tls_native", true }, { "tls_runtime", true }, { "mmap", true },
	{ "clock", true }, { "wchar_t_char32_compatible", true }, { "global_constructor", true },
	{ "named_sections", true }, { "weak_undefined", true }, { "alias", true }, { "ucn", true },
	{ "vect_int", true }, { "sse", true }, { "sse2", true }, { "avx", false }, { "avx2", false },
	{ "avx512f", false }, { "float16", true }, { "float32", true }, { "float64", true },
	{ "float128", true }, { "float32x", true }, { "float64x", true }, { "float128x", false },
	{ "float16_runtime", true }, { "float32_runtime", true }, { "float64_runtime", true },
	{ "float128_runtime", true }, { "float32x_runtime", true }, { "float64x_runtime", true },
	{ "bitint", true }, { "bitint128", true }, { "bitint575", true }, { "bitint65535", true },
	{ "struct_musttail", true }, { "musttail", true }, { "stack_size", true },
	{ "hard_float", true }, { "non_strict_align", true }, { "cas_int", true },
	{ "unwrapped", true }, { "nonstatic_storage", true }, { "init_priority", true },
	{ "builtin_eh_return", true }, { "rdynamic", true }, { "exceptions", true },
	// The driver assembles with the system GNU as.
	{ "gas", true }, { "elf", true }, { "glibc", true },
};

const NamedBool[*] REQUIRE_DIRECTIVES = {
	{
		"dg-require-alias", true
	}
	, { "dg-require-weak", true }, { "dg-require-visibility", true },
	{ "dg-require-named-sections", true }, { "dg-require-ascii-locale", true },
	{ "dg-require-stack-size", true }, { "dg-require-profiling", false }, { "dg-require-dll", false },
	{ "dg-require-ifunc", true }, { "dg-require-weak-override", true },
	{ "dg-require-linker-plugin", false }, { "dg-require-dot", false },
	{ "dg-require-iconv", true }, { "dg-require-host-local", true },
};

// Options from dg-options passed through to aro (prefix match); others are dropped.
const String[*] KEPT_OPTION_PREFIXES = {
	"-std=", "-D", "-U", "-I", "-w", "-W", "-pedantic",
	"-fsigned-char", "-funsigned-char", "-fno-signed-char",
	"-fno-unsigned-char", "-fms-extensions", "-fdollars-in-identifiers",
	"-fno-dollars-in-identifiers", "-ffreestanding", "-fhosted",
	"-fdeclspec", "-fgnuc-version=",
};

const String[*] STATUSES = { "PASS", "FAIL", "CRASH", "TIMEOUT", "UNSUPPORTED", "DIFF", "SKIP" };

faultdef UNKNOWN_TARGET, BAD_EXPRESSION, UNRESOLVED, UNSUPPORTED_REGEX;

// ---------------------------------------------------------------------------
// Python str semantics on UTF-8 text
// ---------------------------------------------------------------------------

<* Byte length of the Python whitespace character (str.isspace, regex \s) at s[i], or 0. *>
fn sz ws_len(String s, sz i)
{
	char c = s[i];
	if (c == ' ' || (c >= '\t' && c <= '\r') || (c >= 0x1c && c <= 0x1f)) return 1;
	if (c < 0x80) return 0;
	if (c == 0xc2) return i + 1 < s.len && (s[i + 1] == 0x85 || s[i + 1] == 0xa0) ? 2 : 0;
	if (i + 2 >= s.len) return 0;
	char c1 = s[i + 1];
	char c2 = s[i + 2];
	if (c == 0xe1 && c1 == 0x9a && c2 == 0x80) return 3;
	if (c == 0xe2 && c1 == 0x80 && ((c2 >= 0x80 && c2 <= 0x8a) || c2 == 0xa8 || c2 == 0xa9 || c2 == 0xaf)) return 3;
	if (c == 0xe2 && c1 == 0x81 && c2 == 0x9f) return 3;
	if (c == 0xe3 && c1 == 0x80 && c2 == 0x80) return 3;
	return 0;
}

<* str.strip() *>
fn String py_strip(String s)
{
	sz b = 0;
	sz e = s.len;
	while (b < e)
	{
		sz w = ws_len(s, b);
		if (!w) break;
		b += w;
	}
	while (e > b)
	{
		sz k = 0;
		for (sz n = 1; n <= 3 && n <= e - b; n++)
		{
			if (ws_len(s[:e], e - n) == n)
			{
				k = n; break;
			}
		}
		if (!k) break;
		e -= k;
	}
	return s[b : e - b];
}

<* str.split() with no separator. *>
fn String[] py_split(Allocator a, String s)
{
	List{String} out;
	out.init(a);
	sz i = 0;
	while (i < s.len)
	{
		sz w = ws_len(s, i);
		if (w)
		{
			i += w; continue;
		}
		sz start = i;
		while (i < s.len && !ws_len(s, i)) i++;
		out.push(s[start : i - start]);
	}
	return out.array_view();
}

<* str.split(sep) for a one-byte separator. *>
fn String[] split_char(Allocator a, String s, char sep)
{
	List{String} out;
	out.init(a);
	sz start = 0;
	for (sz i = 0; i < s.len; i++)
	{
		if (s[i] != sep) continue;
		out.push(s[start : i - start]);
		start = i + 1;
	}
	out.push(s[start..]);
	return out.array_view();
}

<* Byte length of the line break at s[i] for str.splitlines(), or 0. *>
fn sz line_break_len(String s, sz i)
{
	char c = s[i];
	if (c == '\r') return i + 1 < s.len && s[i + 1] == '\n' ? 2 : 1;
	if (c == '\n' || c == 0x0b || c == 0x0c || c == 0x1c || c == 0x1d || c == 0x1e) return 1;
	if (c == 0xc2 && i + 1 < s.len && s[i + 1] == 0x85) return 2;
	if (c == 0xe2 && i + 2 < s.len && s[i + 1] == 0x80 && (s[i + 2] == 0xa8 || s[i + 2] == 0xa9)) return 3;
	return 0;
}

<* str.splitlines() *>
fn String[] py_splitlines(Allocator a, String s, sz limit = 1L << 40)
{
	List{String} out;
	out.init(a);
	sz start = 0;
	sz i = 0;
	while (i < s.len && out.len() < limit)
	{
		sz k = line_break_len(s, i);
		if (!k)
		{
			i++; continue;
		}
		out.push(s[start : i - start]);
		i += k;
		start = i;
	}
	if (start < s.len && out.len() < limit) out.push(s[start..]);
	return out.array_view();
}

fn sz utf8_seq_len(char c) @inline => c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;

<* s[:n] in characters (s is valid UTF-8). *>
fn String cp_prefix(String s, sz n)
{
	sz i = 0;
	for (sz count = 0; i < s.len && count < n; count++) i += utf8_seq_len(s[i]);
	return s[:i > s.len ? s.len : i];
}

<* bytes.decode("utf-8", errors="replace"), optionally with universal-newline translation (\r\n, \r -> \n). *>
fn String py_decode(Allocator a, char[] raw, bool translate_newlines)
{
	DString out;
	out.init(a, raw.len + 16);
	sz i = 0;
	sz n = raw.len;
	while (i < n)
	{
		char c = raw[i];
		if (c < 0x80)
		{
			if (translate_newlines && c == '\r')
			{
				out.append_char('\n');
				i += i + 1 < n && raw[i + 1] == '\n' ? 2 : 1;
				continue;
			}
			out.append_char(c);
			i++;
			continue;
		}
		sz need;
		char lo = 0x80;
		char hi = 0xbf;
		switch
		{
			case c >= 0xc2 && c <= 0xdf: need = 1;
			case c == 0xe0: need = 2; lo = 0xa0;
			case c == 0xed: need = 2; hi = 0x9f;
			case c >= 0xe1 && c <= 0xef: need = 2;
			case c == 0xf0: need = 3; lo = 0x90;
			case c == 0xf4: need = 3; hi = 0x8f;
			case c >= 0xf1 && c <= 0xf3: need = 3;
			default: need = 0;
		}
		if (!need)
		{
			out.append("\xef\xbf\xbd");
			i++;
			continue;
		}
		sz j = i + 1;
		bool ok = true;
		for (sz k = 0; k < need; k++)
		{
			char lo_k = k == 0 ? lo : 0x80;
			char hi_k = k == 0 ? hi : 0xbf;
			if (j >= n || raw[j] < lo_k || raw[j] > hi_k)
			{
				ok = false; break;
			}
			j++;
		}
		if (ok)
		{
			out.append((String)raw[i : j - i]);
		}
		else
		{
			out.append("\xef\xbf\xbd");
		}
		i = j;
	}
	return out.str_view();
}

<* repr(str) *>
fn String py_repr(Allocator a, String s)
{
	char q = s.contains("'") && !s.contains("\"") ? '"' : '\'';
	DString out;
	out.init(a);
	out.append_char(q);
	sz i = 0;
	while (i < s.len)
	{
		char c = s[i];
		if (c == q || c == '\\')
		{
			out.append_char('\\'); out.append_char(c); i++; continue;
		}
		if (c == '\n')
		{
			out.append("\\n"); i++; continue;
		}
		if (c == '\r')
		{
			out.append("\\r"); i++; continue;
		}
		if (c == '\t')
		{
			out.append("\\t"); i++; continue;
		}
		if (c < 0x20 || c == 0x7f)
		{
			out.appendf("\\x%02x", c); i++; continue;
		}
		// Non-printable Latin-1 code points (C1 controls, NBSP, soft hyphen).
		if (c == 0xc2 && i + 1 < s.len && ((s[i + 1] >= 0x80 && s[i + 1] <= 0xa0) || s[i + 1] == 0xad))
		{
			out.appendf("\\x%02x", s[i + 1]);
			i += 2;
			continue;
		}
		out.append_char(c);
		i++;
	}
	out.append_char(q);
	return out.str_view();
}

<* pathlib's normalisation of a path string (collapses '//' and '.' parts). *>
fn String py_path(Allocator a, String p)
{
	bool abs = p.starts_with("/");
	DString out;
	out.init(a);
	if (abs) out.append_char('/');
	bool first = true;
	@pool()
	{
		foreach (part : split_char(tmem, p, '/'))
		{
			if (!part.len || part == ".") continue;
			if (!first) out.append_char('/');
			out.append(part);
			first = false;
		}
	};
	if (!out.len()) return ".".copy(a);
	return out.str_view();
}

<* str(Path(p).absolute()) *>
fn String py_absolute(Allocator a, String p)
{
	String n = py_path(tmem, p);
	if (n.starts_with("/")) return n.copy(a);
	Path? cwd = path::cwd(tmem);
	if (catch cwd) return n.copy(a);
	if (n == ".") return ((String)cwd).copy(a);
	return string::format(a, "%s/%s", (String)cwd, n);
}

<* str(Path(dir) / name) *>
fn String py_join(Allocator a, String dir, String name)
{
	if (name.starts_with("/")) return py_path(a, name);
	return py_path(a, string::tformat("%s/%s", dir, name));
}

// ---------------------------------------------------------------------------
// Directive parsing
// ---------------------------------------------------------------------------

<*
 Split a Tcl-ish argument string into words: bare, "quoted", {braced}. Words are
 slices of `text`. When `quoted` is given, it gets one entry per word: whether
 the word was "quoted" (and so still needs tcl_subst).
*>
fn String[] tcl_words(Allocator a, String text, List{bool}* quoted = null)
{
	List{String} words;
	words.init(a);
	sz i = 0;
	sz n = text.len;
	while (i < n)
	{
		sz w = ws_len(text, i);
		if (w)
		{
			i += w;
			continue;
		}
		char c = text[i];
		if (c == '"')
		{
			// Escapes are kept verbatim, so the word is the raw text up to the closing quote.
			sz j = i + 1;
			while (j < n && text[j] != '"') j += text[j] == '\\' && j + 1 < n ? 2 : 1;
			words.push(text[i + 1 : j - i - 1]);
			if (quoted) quoted.push(true);
			i = j + 1;
		}
		else if (c == '{')
		{
			int depth = 1;
			sz j = i + 1;
			while (j < n && depth)
			{
				if (text[j] == '\\')
				{
					j += 2;
					continue;
				}
				if (text[j] == '{')
				{
					depth++;
				}
				else if (text[j] == '}')
				{
					depth--;
				}
				j++;
			}
			sz start = i + 1;
			sz end = j - 1 > n ? n : j - 1;
			words.push(end > start ? py_strip(text[start : end - start]) : "");
			if (quoted) quoted.push(false);
			i = j;
		}
		else
		{
			sz j = i;
			while (j < n && !ws_len(text, j)) j++;
			words.push(text[i : j - i]);
			if (quoted) quoted.push(false);
			i = j;
		}
	}
	return words.array_view();
}

fn int hex_digit(char c) @local
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	return -1;
}

<*
 Tcl backslash substitution of a "quoted" word: \a \b \f \n \r \t \v, \xHH,
 \ooo (octal) and \<newline><space> (one space); any other \c is c itself, so
 "\[ \t\]" becomes "[ <tab>]" and "\." becomes "." (GCC tests write "\\." for a
 literal dot).
*>
fn String tcl_subst(Allocator a, String s)
{
	DString out;
	out.init(a);
	sz n = s.len;
	for (sz i = 0; i < n; i++)
	{
		char c = s[i];
		if (c != '\\' || i + 1 >= n)
		{
			out.append_char(c);
			continue;
		}
		char e = s[++i];
		switch (e)
		{
			case 'a': out.append_char(0x07);
			case 'b': out.append_char(0x08);
			case 'f': out.append_char(0x0c);
			case 'n': out.append_char('\n');
			case 'r': out.append_char('\r');
			case 't': out.append_char('\t');
			case 'v': out.append_char(0x0b);
			case '\n':
				while (i + 1 < n && (s[i + 1] == ' ' || s[i + 1] == '\t')) i++;
				out.append_char(' ');
			case 'x':
				int v = 0;
				sz digits = 0;
				while (digits < 2 && i + 1 < n && hex_digit(s[i + 1]) >= 0)
				{
					v = v * 16 + hex_digit(s[++i]);
					digits++;
				}
				out.append_char(digits ? (char)v : 'x');
			case '0'..'7':
				int v = e - '0';
				for (sz k = 0; k < 2 && i + 1 < n && s[i + 1] >= '0' && s[i + 1] <= '7'; k++) v = v * 8 + (s[++i] - '0');
				out.append_char((char)v);
			default:
				out.append_char(e);
		}
	}
	return out.str_view();
}

<*
 Translate a Tcl ARE (as used by GCC's scan-assembler) to the POSIX ERE that
 std::encoding::experimental::regex accepts: \m \M \y \Y become \< \> \b \B;
 escapes inside a bracket expression (POSIX takes them literally) become the
 character or a [:class:]. Non-greedy quantifiers, (?...) groups, \A \Z and
 backreferences have no ERE equivalent: UNSUPPORTED_REGEX.
*>
fn String? tcl_regex_to_ere(Allocator a, String pat)
{
	DString out;
	out.init(a);
	sz n = pat.len;
	sz i = 0;
	while (i < n)
	{
		char c = pat[i];
		switch (c)
		{
			case '\\':
				if (i + 1 >= n) return UNSUPPORTED_REGEX~;
				char e = pat[i + 1];
				switch (e)
				{
					case 'm': out.append(`\<`);
					case 'M': out.append(`\>`);
					case 'y': out.append(`\b`);
					case 'Y': out.append(`\B`);
					case 'v': out.append_char(0x0b);
					case 'A':
					case 'Z':
					case '0'..'9':
						return UNSUPPORTED_REGEX~;
					default:
						out.append_char('\\');
						out.append_char(e);
				}
				i += 2;
			case '(':
				if (i + 1 < n && pat[i + 1] == '?') return UNSUPPORTED_REGEX~;
				out.append_char(c);
				i++;
			case '*':
			case '+':
			case '?':
			case '}':
				// A quantifier followed by `?` is non-greedy in ARE.
				if (i + 1 < n && pat[i + 1] == '?') return UNSUPPORTED_REGEX~;
				out.append_char(c);
				i++;
			case '[':
				out.append_char('[');
				i++;
				if (i < n && pat[i] == '^')
				{
					out.append_char('^');
					i++;
				}
				// A leading ']' is a literal member.
				if (i < n && pat[i] == ']')
				{
					out.append_char(']');
					i++;
				}
				bool closed = false;
				while (i < n)
				{
					char b = pat[i];
					if (b == ']')
					{
						out.append_char(']');
						i++;
						closed = true;
						break;
					}
					if (b == '[' && i + 1 < n && (pat[i + 1] == ':' || pat[i + 1] == '.' || pat[i + 1] == '='))
					{
						// [:class:] (and the collating forms, which the engine rejects itself).
						char kind = pat[i + 1];
						sz j = i + 2;
						while (j + 1 < n && !(pat[j] == kind && pat[j + 1] == ']')) j++;
						if (j + 1 >= n) return UNSUPPORTED_REGEX~;
						out.append(pat[i : j + 2 - i]);
						i = j + 2;
						continue;
					}
					if (b == '\\' && i + 1 < n)
					{
						char e = pat[i + 1];
						i += 2;
						switch (e)
						{
							case 't': out.append_char('\t');
							case 'n': out.append_char('\n');
							case 'r': out.append_char('\r');
							case 'f': out.append_char(0x0c);
							case 'v': out.append_char(0x0b);
							case 'd': out.append("[:digit:]");
							case 's': out.append("[:space:]");
							case 'w': out.append("[:alnum:]_");
							// A literal ']' is only expressible first in POSIX.
							case ']':
							case 'D':
							case 'S':
							case 'W':
								return UNSUPPORTED_REGEX~;
							default: out.append_char(e);
						}
						continue;
					}
					out.append_char(b);
					i++;
				}
				if (!closed) return UNSUPPORTED_REGEX~;
			default:
				out.append_char(c);
				i++;
		}
	}
	return out.str_view();
}

struct Directive
{
	String name;
	String[] args;
	long line;
}

fn bool is_dg_name_char(char c) @inline => (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';

<* Every `{ dg-name args }` in `source`, as (name, args, line). *>
fn Directive[] find_directives(Allocator a, String source)
{
	List{Directive} out;
	out.init(a);
	sz n = source.len;
	sz pos = 0;
	sz counted = 0;
	long line = 1;
	while (pos < n)
	{
		if (source[pos] != '{')
		{
			pos++;
			continue;
		}
		// Match \{\s*(dg-[a-z0-9-]+) at pos.
		sz k = pos + 1;
		while (k < n)
		{
			sz w = ws_len(source, k);
			if (!w) break;
			k += w;
		}
		if (!(k + 3 < n && source[k : 3] == "dg-" && is_dg_name_char(source[k + 3])))
		{
			pos++;
			continue;
		}
		sz name_end = k + 4;
		while (name_end < n && is_dg_name_char(source[name_end])) name_end++;
		int depth = 1;
		sz j = pos + 1;
		while (j < n && depth)
		{
			char c = source[j];
			if (c == '\\')
			{
				j += 2;
				continue;
			}
			if (c == '"')
			{
				j++;
				while (j < n && source[j] != '"' && source[j] != '\n') j += source[j] == '\\' ? 2 : 1;
			}
			else if (c == '{')
			{
				depth++;
			}
			else if (c == '}')
			{
				depth--;
			}
			j++;
		}
		sz body_end = j - 1 > n ? n : j - 1;
		String body = body_end > name_end ? source[name_end : body_end - name_end] : "";
		for (; counted < pos; counted++) if (source[counted] == '\n') line++;
		out.push(
			{
				.name = source[k : name_end - k], .args = tcl_words(a, body), .line = line
		}
		);
		pos = name_end;
	}
	return out.array_view();
}

<* The keyword that made the last eval_expr fail with UNKNOWN_TARGET. *>
tlocal String unknown_word;

struct Token @local
{
	char op;
	bool value;
}

fn bool is_op(String w) @inline => w == "!" || w == "&&" || w == "||";

<* Evaluate an effective-target expression: keywords, triplet globs, !, &&, ||. *>
fn bool? eval_expr(Allocator a, String[] words)
{
	List{Token} tokens;
	tokens.init(a);
	bool has_op = false;
	foreach (w : words)
	{
		if (is_op(w))
		{
			tokens.push(
				{
					.op = w[0]
				}
			);
			has_op = true;
		}
		else if (w.contains(" ") || w.starts_with("!"))
		{
			String inner = w;
			if (w.starts_with("!") && !w.starts_with("! ")) inner = string::format(a, " ! %s", w[1..]);
			tokens.push(
				{
					.value = eval_expr(a, tcl_words(a, inner))!
			}
			);
		}
		else
		{
			tokens.push(
				{
					.value = atom(w)!
			}
			);
		}
	}
	Token[] t = tokens.array_view();
	// A plain list (no operators) matches if any element does: `{ target a-*-* b-*-* }`.
	if (!has_op)
	{
		foreach (tok : t) if (tok.value) return true;
		return false;
	}
	// Left-to-right with ! binding tightest, && before ||.
	sz pos = 0;
	bool v = conj(t, &pos)!;
	while (pos < t.len && t[pos].op == '|')
	{
		pos++;
		bool r = conj(t, &pos)!;
		v = v || r;
	}
	return v;
}

fn bool? unary(Token[] t, sz* pos) @local
{
	// Python indexes past the end here (IndexError).
	if (*pos >= t.len) return BAD_EXPRESSION~;
	Token tok = t[*pos];
	(*pos)++;
	if (tok.op == '!') return !unary(t, pos)!;
	// bool() of an operator string is True.
	return tok.op ? true : tok.value;
}

fn bool? conj(Token[] t, sz* pos) @local
{
	bool v = unary(t, pos)!;
	while (*pos < t.len && t[*pos].op == '&')
	{
		(*pos)++;
		bool r = unary(t, pos)!;
		v = v && r;
	}
	return v;
}

fn bool? atom(String word)
{
	if (word == "*" || word == "*-*-*") return true;
	if (word.contains("-") && (word.contains("*") || word.count("-") >= 2))
	{
		return aro_harness::glob_match(word, TRIPLET) || aro_harness::glob_match(word, TRIPLET_ALT);
	}
	foreach (e : EFFECTIVE_TARGETS) if (e.name == word) return e.value;
	unknown_word = word;
	return UNKNOWN_TARGET~;
}

<* `target ...` / `xfail ...` selector: returns the value, `*xfail` tells the kind. *>
fn bool? eval_selector(Allocator a, String text, bool* xfail)
{
	*xfail = false;
	String[] words = tcl_words(a, text);
	if (!words.len) return true;
	String kind = words[0];
	if (kind != "target" && kind != "xfail") return eval_expr(a, words);
	*xfail = kind == "xfail";
	String[] rest = words[1..];
	if (rest.len == 1 && rest[0].contains(" ")) rest = tcl_words(a, rest[0]);
	return rest.len ? eval_expr(a, rest) : true;
}

fn bool all_digits(String s) @local
{
	if (!s.len) return false;
	foreach (c : s) if (c < '0' || c > '9') return false;
	return true;
}

fn bool is_word_char(char c) @local => c == '_' || c >= 0x80 || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');

<* `[+-]\d+` as a number. *>
fn long? signed_number(String s) @local
{
	if (s.len < 2 || (s[0] != '+' && s[0] != '-') || !all_digits(s[1..])) return UNRESOLVED~;
	long v = s[1..].to_long() ?? 0;
	return s[0] == '-' ? -v : v;
}

struct Label
{
	String name;
	long line;
}

fn long? resolve_line(String spec, long here, Label[] labels)
{
	if (spec == "" || spec == ".") return here;
	if (spec == "0") return 0;
	if (spec[0] == '.')
	{
		long? off = signed_number(spec[1..]);
		if (try off) return here + off;
	}
	if (all_digits(spec)) return spec.to_long() ?? 0;
	char c0 = spec[0];
	if (c0 == '_' || (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z'))
	{
		sz e = 1;
		while (e < spec.len && is_word_char(spec[e])) e++;
		String name = spec[:e];
		long off = 0;
		if (e < spec.len)
		{
			if (spec[e] != '.') return UNRESOLVED~;
			off = signed_number(spec[e + 1..])!;
		}
		for (sz i = labels.len; i > 0; i--)
		{
			if (labels[i - 1].name == name) return labels[i - 1].line + off;
		}
	}
	return UNRESOLVED~;
}

enum ExpectKind : char
{
	ERROR,
	WARNING,
	MESSAGE,
	BOGUS,
	NOTE,
}

struct Expect
{
	ExpectKind kind;
	long line;
	bool xfail;
}

<* dg-final scan-assembler (PRESENT), scan-assembler-not (ABSENT), scan-assembler-times (TIMES). *>
enum AsmKind : char (String name)
{
	PRESENT { "scan-assembler" },
	ABSENT { "scan-assembler-not" },
	TIMES { "scan-assembler-times" },
}

struct AsmCheck
{
	AsmKind kind;
	<* The Tcl regexp, after Tcl substitution of a "quoted" word. *>
	String pattern;
	<* TIMES only. *>
	long times;
	long line;
	bool xfail;
	<* Guarded by an x86 target selector: likely an AT&T / GCC-codegen check. *>
	bool x86;
}

struct Case
{
	String suite;
	<* Absolute path of the source file. *>
	String path;
	<* Path relative to the testsuite root. *>
	String rel;
	String name;
	String dir;
	String action;
	bool has_options;
	String[] options;
	String[] extra_options;
	String[] sources;
	Expect[] expect;
	<* SKIP reason, or "". *>
	String skip;
	<* The source mentions scan-assembler (selects the case for the asm suite). *>
	bool has_asm_scan;
	AsmCheck[] asm_checks;
	<* Other dg-final scan-assembler-* forms (dem, symbol-section, bound, ...), which are not checked. *>
	String[] asm_other;
}

fn String[] copy_strings(Allocator a, String[] items) @local
{
	String[] out = alloc::new_array(a, String, items.len);
	foreach (i, s : items) out[i] = s.copy(a);
	return out;
}

fn String[] concat_strings(Allocator a, String[] x, String[] y) @local
{
	String[] out = alloc::new_array(a, String, x.len + y.len);
	foreach (i, s : x) out[i] = s;
	foreach (i, s : y) out[x.len + i] = s;
	return out;
}

<* Parse `path` (absolute; `rel` relative to the testsuite root) into a Case allocated with `a`. *>
fn Case* parse_case(Allocator a, String suite, String path, String rel, String default_action)
{
	Case* c = alloc::new(a, Case);
	c.suite = suite.copy(a);
	c.path = path.copy(a);
	c.rel = rel.copy(a);
	c.name = aro_harness::basename_of(c.path);
	c.dir = aro_harness::dirname_of(c.path);
	c.action = default_action.copy(a);
	@pool()
	{
		char[]? raw = file::load_temp(path);
		if (catch raw)
		{
			int err = aro_harness::dir_exists(path) ? 21 : (int)libc::errno();
			if (!err) err = 2;
			c.skip = string::format(a, "unreadable: [Errno %d] %s: %s", err,
				((ZString)libc::strerror(err)).str_view(), py_repr(tmem, path));
			return c;
		}
		String source = py_decode(tmem, raw, true);
		c.has_asm_scan = source.contains("scan-assembler");
		Directive[] directives = find_directives(tmem, source);
		List{Label} labels;
		labels.init(tmem);
		foreach (d : directives)
		{
			if (d.name == "dg-line" && d.args.len) labels.push(
				{
					d.args[0], d.line
				}
			);
		}
		String action = c.action;
		String skip = "";
		bool has_options = false;
		String[] options;
		List{String} extra;
		extra.init(tmem);
		List{String} sources;
		sources.init(tmem);
		List{Expect} expect;
		expect.init(tmem);
		List{AsmCheck} asm_checks;
		asm_checks.init(tmem);
		List{String} asm_other;
		asm_other.init(tmem);
		fault f = @catch(apply_directives(directives, labels.array_view(), &action, &skip, &has_options, &options, &extra, &sources, &expect, &asm_checks, &asm_other));
		if (f == UNKNOWN_TARGET)
		{
			skip = string::tformat("unknown effective target %s", unknown_word);
		}
		else if (f)
		{
			io::eprintfn("%s: IndexError while evaluating an effective-target expression", path);
			libc::exit(1);
		}
		c.action = action.copy(a);
		c.skip = skip.copy(a);
		c.has_options = has_options;
		c.options = copy_strings(a, options);
		c.extra_options = copy_strings(a, extra.array_view());
		c.sources = copy_strings(a, sources.array_view());
		c.expect = alloc::new_array(a, Expect, expect.len());
		foreach (i, e : expect) c.expect[i] = e;
		c.asm_checks = alloc::new_array(a, AsmCheck, asm_checks.len());
		foreach (i, k : asm_checks)
		{
			k.pattern = k.pattern.copy(a);
			c.asm_checks[i] = k;
		}
		c.asm_other = copy_strings(a, asm_other.array_view());
	};
	return c;
}

fn bool? selector_applies(String[] args, usz index) @local
{
	if (args.len <= index) return true;
	bool xfail;
	return eval_selector(tmem, args[index], &xfail);
}

fn void? apply_directives(Directive[] directives, Label[] labels, String* action, String* skip, bool* has_options,
	String[] * options, List{String} * extra, List{String} * sources, List{Expect} * expect,
	List{AsmCheck} * asm_checks, List{String} * asm_other) @local
{
	foreach (d : directives)
	{
		String name = d.name;
		String[] args = d.args;
		if (name == "dg-final" && args.len)
		{
			parse_asm_check(args[0], d.line, asm_checks, asm_other)!;
		}
		else if (name == "dg-do" && args.len)
		{
			*action = args[0];
			if (args.len > 1)
			{
				bool xfail;
				bool ok = eval_selector(tmem, args[1], &xfail)!;
				if (!xfail && !ok)
				{
					*skip = string::tformat("dg-do target: %s", args[1]);
				}
			}
		}
		else if (name == "dg-options" && args.len)
		{
			if (selector_applies(args, 1)!)
			{
				*has_options = true;
				*options = py_split(tmem, args[0]);
			}
		}
		else if (name == "dg-additional-options" && args.len)
		{
			if (selector_applies(args, 1)!) extra.push_all(py_split(tmem, args[0]));
		}
		else if (name == "dg-additional-sources" && args.len)
		{
			sources.push_all(py_split(tmem, args[0]));
		}
		else if (name == "dg-require-effective-target" && args.len)
		{
			bool applies = selector_applies(args, 1)!;
			if (applies && !eval_expr(tmem, args[:1])!) * skip = string::tformat("effective target %s", args[0]);
		}
		else if (name == "dg-skip-if" && args.len >= 2)
		{
			bool xfail;
			if (eval_selector(tmem, args[1], &xfail)!)
			{
				String[] include = args.len > 2 ? py_split(tmem, args[2]) : { "*" };
				if (!include.len || (include.len == 1 && include[0] == "*"))
				{
					*skip = string::tformat("dg-skip-if %s", py_repr(tmem, args[0]));
				}
			}
		}
		else if (name.starts_with("dg-require-"))
		{
			foreach (r : REQUIRE_DIRECTIVES)
			{
				if (r.name == name && !r.value) * skip = name;
			}
		}
		else
		{
			ExpectKind kind;
			switch (name)
			{
				case "dg-error": kind = ERROR;
				case "dg-warning": kind = WARNING;
				case "dg-message": kind = MESSAGE;
				case "dg-bogus": kind = BOGUS;
				case "dg-note": kind = NOTE;
				default: continue;
			}
			bool xfail = false;
			if (args.len >= 3 && args[2].len)
			{
				bool is_xfail;
				bool ok = eval_selector(tmem, args[2], &is_xfail)!;
				if (!is_xfail && !ok) continue;
				xfail = is_xfail && ok;
			}
			long? target_line = resolve_line(args.len >= 4 ? args[3] : ".", d.line, labels);
			if (catch target_line) continue;
			expect.push(
				{
					kind, target_line, xfail
				}
			);
		}
	}
}

<*
 One dg-final body, e.g. ` scan-assembler-times "foo\t" 2 { target x86_64-*-* } `.
 Forms other than scan-assembler / -not / -times that start with scan-assembler
 go to `asm_other`; everything else (scan-tree-dump, ...) is ignored. A check
 whose target selector is false is dropped, as GCC's dg-process-target "N".
*>
fn void? parse_asm_check(String body, long line, List{AsmCheck} * asm_checks, List{String} * asm_other) @local
{
	List{bool} quoted;
	quoted.init(tmem);
	String[] w = tcl_words(tmem, body, &quoted);
	if (!w.len || !w[0].starts_with("scan-assembler")) return;
	AsmKind kind;
	switch (w[0])
	{
		case "scan-assembler": kind = PRESENT;
		case "scan-assembler-not": kind = ABSENT;
		case "scan-assembler-times": kind = TIMES;
		default:
			asm_other.push(w[0]);
			return;
	}
	if (w.len < 2) return;
	usz selector_index = kind == TIMES ? 3 : 2;
	AsmCheck k = { .kind = kind, .line = line };
	k.pattern = quoted[1] ? tcl_subst(tmem, w[1]) : w[1];
	if (kind == TIMES)
	{
		if (w.len < 3) return;
		k.times = w[2].to_long() ?? -1;
	}
	if (w.len > selector_index)
	{
		bool is_xfail;
		bool ok = eval_selector(tmem, w[selector_index], &is_xfail)!;
		if (!is_xfail && !ok) return;
		k.xfail = is_xfail && ok;
		String sel = w[selector_index];
		k.x86 = !is_xfail && (sel.contains("86-") || sel.contains("x86_64"));
	}
	asm_checks.push(k);
}

<* aro flags for the case, plus the dg-options that were dropped. *>
fn String[] aro_flags(Allocator a, Case* c, String[] * dropped_out)
{
	List{String} flags;
	flags.init(a);
	List{String} dropped;
	dropped.init(a);
	String[] given;
	if (c.suite == "compile" || c.suite == "execute" || c.suite == "ieee")
	{
		foreach (f : TORTURE_FLAGS) flags.push(f);
		given = c.options;
	}
	else if (c.suite == "abi")
	{
		foreach (f : ABI_FLAGS) flags.push(f);
		given = c.options;
	}
	else
	{
		given = c.has_options ? c.options : DG_DEFAULT_FLAGS[..];
	}
	foreach (opt : concat_strings(tmem, given, c.extra_options))
	{
		if (opt == "-ansi")
		{
			flags.push("-std=c89");
			continue;
		}
		bool kept = false;
		foreach (p : KEPT_OPTION_PREFIXES)
		{
			if (opt.starts_with(p))
			{
				kept = true; break;
			}
		}
		if (kept)
		{
			flags.push(opt);
		}
		else
		{
			dropped.push(opt);
		}
	}
	* dropped_out = dropped.array_view();
	return flags.array_view();
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

struct Diag
{
	long line;
	<* "error", "warning" or "note". *>
	String sev;
	String msg;
}

fn sz digits_end(String s, sz i) @local
{
	while (i < s.len && s[i] >= '0' && s[i] <= '9') i++;
	return i;
}

<* `(error|warning|note|fatal error): ` at s[i:]; returns the severity and the message start. *>
fn String severity_at(String s, sz i, sz* msg_start, bool with_warning_note) @local
{
	String rest = s[i..];
	if (rest.starts_with("error: "))
	{
		*msg_start = i + 7; return "error";
	}
	if (with_warning_note && rest.starts_with("warning: "))
	{
		*msg_start = i + 9; return "warning";
	}
	if (with_warning_note && rest.starts_with("note: "))
	{
		*msg_start = i + 6; return "note";
	}
	if (rest.starts_with("fatal error: "))
	{
		*msg_start = i + 13; return "error";
	}
	return "";
}

<* (line, severity, message) for the case's own files; unlocated errors get line -1. *>
fn Diag[] parse_diags(Allocator a, String output, String[] names)
{
	List{Diag} diags;
	diags.init(a);
	foreach (l : py_splitlines(tmem, output))
	{
		// ^([^:\n]+):(\d+):(\d+): (error|warning|note|fatal error): (.*)$
		sz? colon = l.index_of_char(':');
		if (try colon && colon > 0)
		{
			sz p = colon + 1;
			sz q = digits_end(l, p);
			if (q > p && q < l.len && l[q] == ':')
			{
				sz r = digits_end(l, q + 1);
				if (r > q + 1 && r + 1 < l.len && l[r] == ':' && l[r + 1] == ' ')
				{
					sz msg;
					String sev = severity_at(l, r + 2, &msg, true);
					if (sev.len)
					{
						String file = l[:colon];
						String base = aro_harness::basename_of(file);
						foreach (nm : names)
						{
							if (nm == base)
							{
								diags.push(
									{
										l[p : q - p].to_long() ?? 0, sev, l[msg..]
								}
								);
								break;
							}
						}
						continue;
					}
				}
			}
		}
		// ^(?:\S+: )?(error|fatal error): (.*)$
		sz ws = 0;
		while (ws < l.len && !ws_len(l, ws)) ws++;
		sz msg;
		if (ws >= 2 && ws < l.len && l[ws - 1] == ':' && l[ws] == ' ')
		{
			if (severity_at(l, ws + 1, &msg, false).len)
			{
				diags.push(
					{
						-1, "error", l[msg..]
					}
				);
				continue;
			}
		}
		if (severity_at(l, 0, &msg, false).len) diags.push(
			{
				-1, "error", l[msg..]
			}
		);
	}
	return diags.array_view();
}

<* Start of the first match of the PANIC pattern in `out`, or -1. *>
fn long panic_search(String out)
{
	for (sz p = 0; p < out.len; p++)
	{
		String rest = out[p..];
		bool bol = p == 0 || out[p - 1] == '\n';
		if (bol && rest.starts_with("ERROR: '")) return p;
		if (rest.starts_with("in unreachable (")) return p;
		if (rest.starts_with("@require "))
		{
			sz e = p + 9;
			sz line_end = e;
			while (line_end < out.len && out[line_end] != '\n') line_end++;
			if (out[e : line_end - e].contains(" violated")) return p;
		}
		if (bol && rest.starts_with("panic")) return p;
		if (rest.starts_with("Segmentation fault")) return p;
		if (rest.starts_with("Assertion failed")) return p;
	}
	return -1;
}

struct Check
{
	String status;
	String category;
	String detail;
}

const String[*] PROBLEM_NAMES = {
	"unexpected-error", "missing-error", "bogus-diagnostic", "missing-warning", "missing-message", "nonzero-exit"
};

struct Problem @local
{
	int kind;
	long line;
}

const int SEV_ERROR = 1;
const int SEV_WARNING = 2;
const int SEV_NOTE = 4;

fn int sev_bit(String sev) @local => sev == "error" ? SEV_ERROR : sev == "warning" ? SEV_WARNING : SEV_NOTE;

<* Golden diagnostic checks -> (status, category, detail). *>
fn Check check_expectations(Allocator a, Case* c, Diag[] diags, int rc)
{
	HashMap{long, int} by_line;
	by_line.init(tmem);
	int any_sev = 0;
	foreach (d : diags)
	{
		int* m = by_line.get_or_create_ref(d.line);
		*m |= sev_bit(d.sev);
		any_sev |= sev_bit(d.sev);
	}
	HashMap{long, bool} expected_error_lines;
	expected_error_lines.init(tmem);
	List{Problem} problems;
	problems.init(tmem);
	foreach (e : c.expect)
	{
		if (e.xfail) continue;
		int sevs = e.line == 0 ? any_sev : by_line.get(e.line) ?? 0;
		switch (e.kind)
		{
			case ERROR:
				expected_error_lines.set(e.line, true);
				if (!(sevs & SEV_ERROR)) problems.push(
					{
						1, e.line
					}
				);
			case WARNING:
				if (!(sevs & (SEV_WARNING | SEV_ERROR))) problems.push(
					{
						3, e.line
					}
				);
			case MESSAGE:
			case NOTE:
				if (!sevs) problems.push(
					{
						4, e.line
					}
				);
			case BOGUS:
				if (sevs) problems.push(
					{
						2, e.line
					}
				);
		}
	}
	bool has_unexpected = false;
	long first_unexpected = 0;
	foreach (d : diags)
	{
		if (d.sev != "error" || expected_error_lines.has_key(d.line)) continue;
		if (!has_unexpected || d.line < first_unexpected) first_unexpected = d.line;
		has_unexpected = true;
	}
	if (has_unexpected && !expected_error_lines.has_key(0)) problems.push(
		{
			0, first_unexpected
		}
	);
	if (!c.expect.len && rc != 0 && !has_unexpected) problems.push(
		{
			5, 0
		}
	);
	if (!problems.len()) return { "PASS", "", "" };
	// Stable sort by problem kind.
	List{Problem} ordered;
	ordered.init(tmem);
	for (int k = 0; k < PROBLEM_NAMES.len; k++)
	{
		foreach (p : problems) if (p.kind == k) ordered.push(p);
	}
	DString detail;
	detail.init(a);
	foreach (i, p : ordered)
	{
		if (i >= 8) break;
		if (i) detail.append("; ");
		detail.appendf("%s@%d", PROBLEM_NAMES[p.kind], p.line);
	}
	return { "FAIL", PROBLEM_NAMES[ordered[0].kind], detail.str_view() };
}

struct Options
{
	String gcc_testsuite;
	String aro;
	String zig_arocc;
	String suite;
	String filter;
	int jobs;
	double timeout;
	String out;
	String resource_dir;
	<* -isystem dir with the abi suite's <xmmintrin.h> stand-in. *>
	String abi_include;
	<* asm-support.o for the abi suite (built before the run). *>
	String abi_support;
	bool selftest;
}

struct Captured
{
	int rc;
	String out;
	bool timed_out;
	bool spawned;
}

<* Python's run(): (returncode, stdout + stderr decoded, timed out). *>
fn Captured run_captured(Allocator a, String[] cmd, String cwd, double timeout)
{
	RunResult r = aro_harness::run(tmem, cmd, { .cwd = cwd, .timeout_ms = (long)(timeout * 1000.0) });
	String raw = string::tformat("%s%s", r.stdout, r.stderr);
	// A timed-out child's partial output is decoded without newline translation.
	return { r.returncode(), py_decode(a, raw, !r.timed_out), r.timed_out, r.spawned };
}

fn Object* str_array(Allocator a, String[] items) @local
{
	Object* arr = object::new_array(a);
	foreach (s : items) arr.push(s);
	return arr;
}

<* String member `key` of a result record, or "". *>
fn String field(Object* o, String key) @local => o.get_string(key) ?? "";

struct LineSev @local
{
	long line;
	String sev;
}

fn int line_sev_cmp(LineSev x, LineSev y) @local
{
	if (x.line != y.line) return x.line < y.line ? -1 : 1;
	return x.sev.compare_to(y.sev);
}

fn LineSev[] line_sevs(Diag[] diags) @local
{
	List{LineSev} out;
	out.init(tmem);
	foreach (d : diags)
	{
		bool seen = false;
		foreach (x : out) if (x.line == d.line && x.sev == d.sev)
		{
			seen = true; break;
		}
		if (!seen) out.push(
			{
				d.line, d.sev
			}
		);
	}
	LineSev[] arr = out.array_view();
	sort::quicksort(arr, &line_sev_cmp);
	return arr;
}

fn bool contains_ls(LineSev[] set, LineSev v) @local
{
	foreach (x : set) if (x.line == v.line && x.sev == v.sev) return true;
	return false;
}

fn Object* line_sev_diff(Allocator a, LineSev[] x, LineSev[] y) @local
{
	Object* arr = object::new_array(a);
	sz n = 0;
	foreach (v : x)
	{
		if (contains_ls(y, v)) continue;
		if (n++ >= 10) break;
		Object* pair = object::new_array(a);
		pair.push(v.line);
		pair.push(v.sev);
		arr.push(pair);
	}
	return arr;
}

<* Run one case and return its result record (allocated with `a`). *>
fn Object* run_case(Allocator a, Case* c, Options* args)
{
	Object* rec = object::new_obj(a);
	rec.set("suite", c.suite);
	rec.set("path", c.rel);
	rec.set("action", c.action);
	rec.set("status", "");
	rec.set("category", "");
	rec.set("detail", "");
	if (c.skip.len)
	{
		rec.set("status", "SKIP");
		rec.set("category", c.skip);
		return rec;
	}
	bool is_asm = c.suite == "asm";
	if (is_asm && !c.asm_checks.len && !c.asm_other.len)
	{
		rec.set("status", "SKIP");
		rec.set("category", "no scan-assembler check for this target");
		return rec;
	}
	@pool()
	{
		String[] dropped;
		String[] flags = aro_flags(tmem, c, &dropped);
		rec.set("flags", str_array(a, flags));
		rec.set("dropped", str_array(a, dropped));
		List{String} names;
		names.init(tmem);
		names.push(c.name);
		foreach (s : c.sources) names.push(aro_harness::basename_of(s));
		String tmp = aro_harness::make_temp_dir(tmem, "gcc-ts-") ?? "";
		if (!tmp.len)
		{
			io::eprintfn("cannot create a temporary directory");
			libc::exit(1);
		}
		defer aro_harness::remove_tree(tmp);
		String[] cmd = compile_cmd(tmem, args, c, flags, is_asm ? "asm" : c.action, tmp);
		rec.set("cmd", string::tjoin(cmd, " "));
		Captured res = run_captured(tmem, cmd, c.dir, args.timeout);
		if (!res.spawned)
		{
			io::eprintfn("cannot run %s", cmd[0]);
			libc::exit(1);
		}
		rec.set("output", str_array(a, py_splitlines(tmem, res.out, 20)));
		if (res.timed_out)
		{
			rec.set("status", "TIMEOUT");
			rec.set("category", "compile");
			return rec;
		}
		long m = panic_search(res.out);
		if (res.rc < 0 || m >= 0)
		{
			rec.set("status", "CRASH");
			rec.set("category", res.rc < 0 ? string::tformat("signal %d", -res.rc) : "panic");
			String detail = "";
			if (m >= 0)
			{
				String[] lines = py_splitlines(tmem, cp_prefix(res.out[(sz)m..], 200), 1);
				detail = lines.len ? lines[0] : "";
			}
			rec.set("detail", detail);
			return rec;
		}
		Diag[] diags = parse_diags(tmem, res.out, names.array_view());
		rec.set("diags", (long)diags.len);
		Check chk = check_expectations(tmem, c, diags, res.rc);
		if (chk.status != "PASS")
		{
			String first_error = "";
			foreach (d : diags)
			{
				if (d.sev == "error")
				{
					first_error = d.msg; break;
				}
			}
			if (first_error.contains("TODO"))
			{
				chk.status = "UNSUPPORTED";
				chk.category = "backend-todo";
			}
			rec.set("status", chk.status);
			rec.set("category", chk.category);
			rec.set("detail", chk.detail);
			rec.set("first_error", first_error);
		}
		else if (is_asm)
		{
			String asm_path = string::tformat("%s/a.s", tmp);
			char[]? raw = file::load_temp(asm_path);
			if (catch raw)
			{
				rec.set("status", "FAIL");
				rec.set("category", "no-assembly");
				return rec;
			}
			Check chk_asm = check_asm(tmem, c, (String)raw);
			rec.set("asm_checks", (long)c.asm_checks.len);
			// A failure in a case that relies on a dropped flag (other than -O levels,
			// e.g. -fdata-sections or -g3) is not a codegen bug: group it apart.
			if (chk_asm.status == "FAIL" && chk_asm.category != "x86-insn")
			{
				foreach (opt : dropped)
				{
					if (opt.starts_with("-O")) continue;
					chk_asm.category = "dropped-option";
					chk_asm.detail = string::tformat("needs %s: %s", opt, chk_asm.detail);
					break;
				}
			}
			rec.set("status", chk_asm.status);
			rec.set("category", chk_asm.category);
			rec.set("detail", chk_asm.detail);
		}
		else if (c.action == "run")
		{
			String exe = string::tformat("%s/a.out", tmp);
			if (!aro_harness::any_exists(exe))
			{
				rec.set("status", "FAIL");
				rec.set("category", "no-executable");
				return rec;
			}
			Captured run = run_captured(tmem, { exe }, tmp, args.timeout);
			if (run.timed_out)
			{
				rec.set("status", "TIMEOUT");
				rec.set("category", "run");
			}
			else if (!run.spawned)
			{
				// Python raises OSError here (e.g. ENOEXEC) and aborts the whole run.
				rec.set("status", "FAIL");
				rec.set("category", "run-spawn-failed");
			}
			else if (run.rc != 0)
			{
				rec.set("status", "FAIL");
				rec.set("category", string::tformat("run-exit %d", run.rc));
				rec.set("detail", cp_prefix(run.out, 200));
			}
			else
			{
				rec.set("status", "PASS");
			}
		}
		else
		{
			rec.set("status", "PASS");
		}
		String status = field(rec, "status");
		if (args.zig_arocc.len && !is_asm && (status == "PASS" || status == "FAIL"))
		{
			String[] zcmd = concat_strings(tmem, { args.zig_arocc }, cmd[1..]);
			Captured z = run_captured(tmem, zcmd, c.dir, args.timeout);
			if (!z.timed_out)
			{
				LineSev[] ours = line_sevs(diags);
				LineSev[] theirs = line_sevs(parse_diags(tmem, z.out, names.array_view()));
				bool same = ours.len == theirs.len;
				foreach (v : ours) if (!contains_ls(theirs, v)) same = false;
				if ((z.rc == 0) != (res.rc == 0) || !same)
				{
					Object* diff = object::new_obj(a);
					diff.set("zig_rc", (long)z.rc);
					diff.set("only_aro_c3", line_sev_diff(a, ours, theirs));
					diff.set("only_zig", line_sev_diff(a, theirs, ours));
					rec.set("diff", diff);
					if (status == "PASS")
					{
						rec.set("status", "DIFF");
						rec.set("category", "zig-arocc");
					}
				}
			}
		}
	};
	return rec;
}

<* `pattern` with tabs and newlines escaped, cut to 60 bytes, for a result detail. *>
fn String printable_pattern(Allocator a, String pattern) @local
{
	DString out;
	out.init(a);
	foreach (ch : pattern)
	{
		if (out.len() >= 60)
		{
			out.append("...");
			break;
		}
		switch (ch)
		{
			case '\t': out.append(`\t`);
			case '\n': out.append(`\n`);
			default: out.append_char(ch);
		}
	}
	return out.str_view();
}

<*
 Evaluate the case's scan-assembler checks on the assembly `text` (GCC's
 dg-scan / scan-assembler-times: `regexp` / `regexp -all` on the whole file).
 FAIL when a non-xfail check fails: category "x86-insn" when every failing check
 is guarded by an x86 target selector, else the first failing directive's name.
 Patterns the ERE engine cannot express are not evaluated; when nothing could be
 evaluated the case is UNSUPPORTED ("regex", or the first unchecked form).
*>
fn Check check_asm(Allocator a, Case* c, String text)
{
	DString detail;
	detail.init(a);
	sz failures = 0;
	sz evaluated = 0;
	sz unsupported = 0;
	String category = "";
	bool all_x86 = true;
	foreach (k : c.asm_checks)
	{
		String? ere = tcl_regex_to_ere(tmem, k.pattern);
		if (catch ere)
		{
			unsupported++;
			continue;
		}
		Regex? re = regex::compile(tmem, ere, EXTENDED);
		if (catch re)
		{
			unsupported++;
			continue;
		}
		evaluated++;
		long got;
		bool ok;
		switch (k.kind)
		{
			case PRESENT:
				ok = re.matches(text);
				got = ok ? 1 : 0;
			case ABSENT:
				got = re.matches(text) ? 1 : 0;
				ok = got == 0;
			case TIMES:
				got = (re.tfind_all(text) ?? {}).len;
				ok = got == k.times;
		}
		if (ok || k.xfail) continue;
		if (!k.x86) all_x86 = false;
		if (!category.len && !k.x86) category = k.kind.name;
		if (failures < 8)
		{
			if (failures) detail.append("; ");
			detail.appendf("%s@%d /%s/", k.kind.name, k.line, printable_pattern(tmem, k.pattern));
			if (k.kind == TIMES) detail.appendf(" got %d want %d", got, k.times);
		}
		failures++;
	}
	if (failures) return { "FAIL", all_x86 ? "x86-insn" : category, detail.str_view() };
	if (!evaluated)
	{
		if (unsupported) return { "UNSUPPORTED", "regex", "" };
		return { "UNSUPPORTED", c.asm_other.len ? c.asm_other[0] : "no-checks", "" };
	}
	if (unsupported) return { "PASS", "", string::format(a, "%d pattern(s) not evaluated", unsupported) };
	return { "PASS", "", "" };
}

<* Assemble the abi suite's asm-support.S (the register `snapshot` routine) with
   the host cc, as GCC's harness does for test scaffolding. It is not code under
   test; aro's driver does not take .S inputs yet. *>
fn String? abi_support_object(Allocator a, Options* args, String dir, String out_dir)
{
	String obj = string::format(a, "%s/asm-support.o", out_dir);
	String src = py_join(tmem, dir, ABI_SUPPORT_SOURCE);
	RunResult r = aro_harness::run(tmem, { "cc", "-c", "-o", obj, src },
		{ .cwd = dir, .timeout_ms = (long)(args.timeout * 1000.0), .search_path = true, .merge_stderr = true });
	if (!r.spawned || r.timed_out || r.returncode() != 0)
	{
		io::eprintfn("cannot assemble %s with the host cc (spawned=%s rc=%d):\n%s", src, r.spawned, r.returncode(), r.stdout);
		return io::FILE_NOT_FOUND~;
	}
	return obj;
}

fn String[] compile_cmd(Allocator a, Options* args, Case* c, String[] flags, String action, String workdir)
{
	List{String} cmd;
	cmd.init(a);
	cmd.push(args.aro);
	cmd.push("-resource-dir");
	cmd.push(args.resource_dir);
	cmd.push("-fno-color-diagnostics");
	cmd.push_all(flags);
	if (c.suite == "abi")
	{
		cmd.push("-isystem");
		cmd.push(args.abi_include);
	}
	List{String} srcs;
	srcs.init(a);
	srcs.push(c.path);
	foreach (s : c.sources) srcs.push(py_join(a, c.dir, s));
	if (action == "run" || action == "link")
	{
		cmd.push("-o");
		cmd.push(string::format(a, "%s/a.out", workdir));
		cmd.push_all(srcs.array_view());
		if (c.suite == "abi") cmd.push(args.abi_support);
		cmd.push("-lm");
	}
	else if (action == "asm")
	{
		// GCC scans the .s of the main source only.
		cmd.push("-S");
		cmd.push("-o");
		cmd.push(string::format(a, "%s/a.s", workdir));
		cmd.push(c.path);
	}
	else if (action == "assemble")
	{
		cmd.push("-c");
		cmd.push("-o");
		cmd.push(string::format(a, "%s/a.o", workdir));
		cmd.push_all(srcs.array_view());
	}
	else if (action == "preprocess")
	{
		cmd.push("-E");
		cmd.push("-o");
		cmd.push(string::format(a, "%s/a.i", workdir));
		cmd.push_all(srcs.array_view());
	}
	else
	{
		cmd.push("-fsyntax-only");
		cmd.push_all(srcs.array_view());
	}
	return cmd.array_view();
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

<* re.sub(r"'[^']*'", "'X'", msg), then \d+ -> N, first 100 characters. *>
fn String normalize(Allocator a, String msg)
{
	DString q;
	q.init(tmem);
	sz i = 0;
	while (i < msg.len)
	{
		if (msg[i] == '\'')
		{
			sz? close = msg[i + 1..].index_of_char('\'');
			if (try close)
			{
				q.append("'X'");
				i += close + 2;
				continue;
			}
		}
		q.append_char(msg[i]);
		i++;
	}
	String s = q.str_view();
	DString out;
	out.init(a);
	i = 0;
	while (i < s.len)
	{
		if (s[i] >= '0' && s[i] <= '9')
		{
			out.append_char('N');
			i = digits_end(s, i);
			continue;
		}
		out.append_char(s[i]);
		i++;
	}
	return cp_prefix(out.str_view(), 100);
}

struct Group @local
{
	String key;
	String label;
	List{String} paths;
}

struct GroupOrder @local
{
	sz count;
	sz index;
}

fn int group_order_cmp(GroupOrder x, GroupOrder y) @local
{
	if (x.count != y.count) return x.count > y.count ? -1 : 1;
	return x.index < y.index ? -1 : x.index > y.index ? 1 : 0;
}

<* Groups in descending size, ties in first-seen order (Python's stable sort on -len). *>
fn GroupOrder[] order_groups(List{Group} * groups) @local
{
	GroupOrder[] order = mem::talloc_array(GroupOrder, groups.len());
	foreach (i, g : *groups) order[i] = { g.paths.len(), i };
	sort::quicksort(order, &group_order_cmp);
	return order;
}

fn void add_to_group(List{Group} * groups, HashMap{String, sz} * index, String key, String label, String path) @local
{
	sz at = index.get(key) ?? -1;
	if (at < 0)
	{
		Group g = { .key = key, .label = label };
		g.paths.init(tmem);
		at = groups.len();
		groups.push(g);
		index.set(key, at);
	}
	groups.get_ref(at).paths.push(path);
}

fn String join_first(List{String} * items, sz n) @local
{
	DString out;
	out.init(tmem);
	foreach (i, s : *items)
	{
		if (i >= n) break;
		if (i) out.append(", ");
		out.append(s);
	}
	return out.str_view();
}

fn String summary_text(Allocator a, Object*[] results)
{
	DString o;
	o.init(a);
	@pool()
	{
		List{String} suites;
		suites.init(tmem);
		foreach (r : results)
		{
			String s = field(r, "suite");
			bool seen = false;
			foreach (x : suites) if (x == s)
			{
				seen = true; break;
			}
			if (!seen) suites.push(s);
		}
		String[] sorted_suites = suites.array_view();
		sort::quicksort(sorted_suites, fn int(String x, String y) => x.compare_to(y));
		o.append("# GCC testsuite results\n\n| suite |");
		foreach (st : STATUSES) o.appendf(" %s |", st);
		o.append("\n|---|");
		foreach (st : STATUSES) o.append("---|");
		o.append("\n");
		foreach (s : sorted_suites)
		{
			o.appendf("| %s |", s);
			foreach (st : STATUSES)
			{
				sz n = 0;
				foreach (r : results) if (field(r, "suite") == s && field(r, "status") == st) n++;
				o.appendf(" %d", n);
				o.append(" |");
			}
			o.append("\n");
		}
		List{Group} crashes;
		crashes.init(tmem);
		HashMap{String, sz} crash_index;
		crash_index.init(tmem);
		foreach (r : results)
		{
			if (field(r, "status") != "CRASH") continue;
			String detail = field(r, "detail");
			add_to_group(&crashes, &crash_index, detail, detail, field(r, "path"));
		}
		if (crashes.len())
		{
			o.append("\n## Crashes (fix first)\n\n");
			foreach (g : order_groups(&crashes))
			{
				Group* grp = crashes.get_ref(g.index);
				o.appendf("- %d × `%s` e.g. %s\n", grp.paths.len(), grp.label, join_first(&grp.paths, 3));
			}
		}
		o.append("\n## Top failure categories\n\n");
		List{Group} cats;
		cats.init(tmem);
		HashMap{String, sz} cat_index;
		cat_index.init(tmem);
		foreach (r : results)
		{
			String st = field(r, "status");
			if (st != "FAIL" && st != "UNSUPPORTED" && st != "TIMEOUT") continue;
			String err = normalize(tmem, field(r, "first_error"));
			String key = string::tformat("%s\x00%s\x00%s", st, field(r, "category"), err);
			String label = string::tformat("%s %s%s", st, field(r, "category"), err.len ? string::tformat(" — `%s`", err) : "");
			add_to_group(&cats, &cat_index, key, label, field(r, "path"));
		}
		foreach (i, g : order_groups(&cats))
		{
			if (i >= 60) break;
			Group* grp = cats.get_ref(g.index);
			o.appendf("- %d × %s e.g. %s\n", grp.paths.len(), grp.label, join_first(&grp.paths, 3));
		}
	};
	// "\n".join(lines) + "\n": the section lists above end every line with "\n"
	// and an empty trailing list leaves exactly one blank line, as Python does.
	return o.str_view();
}

// ---------------------------------------------------------------------------
// Self test (gcc_testsuite.py --selftest)
// ---------------------------------------------------------------------------

macro bool @expect(bool #cond, String what) @local
{
	if (!#cond)
	{
		io::eprintfn("selftest failed: %s", what);
		return false;
	}
	return true;
}

fn Case* parse_text(String dir, String text) @local
{
	String p = string::tformat("%s/t.c", dir);
	(void)file::save(p, text);
	return parse_case(tmem, "dg", p, "t.c", "compile");
}

fn bool expect_eq(Expect[] got, Expect[] want) @local
{
	if (got.len != want.len) return false;
	foreach (i, e : got) if (e.kind != want[i].kind || e.line != want[i].line || e.xfail != want[i].xfail) return false;
	return true;
}

fn bool selftest()
{
	@pool()
	{
		String[] w = tcl_words(tmem, `"a b" {c {d}} e`);
		if (!@expect(w.len == 3 && w[0] == "a b" && w[1] == "c {d}" && w[2] == "e", "tcl_words")) return false;
		String src = "int x; /* { dg-error \"bad \\\"q\\\"\" \"\" { target *-*-* } .+1 } */\n"
		"int y;\n"
		"/* { dg-warning \"w\" \"\" { target { ! lp64 } } 1 } */\n"
		"/* { dg-error \"e\" \"\" { xfail *-*-* } } */\n"
		"/* { dg-do run { target { x86_64-*-* && lp64 } } } */\n"
		"/* { dg-require-effective-target int32plus } */\n";
		String tmp = aro_harness::make_temp_dir(tmem, "gcc-ts-selftest-")!!;
		defer aro_harness::remove_tree(tmp);
		Case* c = parse_text(tmp, src);
		if (!@expect(c.skip == "", "no skip")) return false;
		if (!@expect(c.action == "run", "dg-do run")) return false;
		if (!@expect(expect_eq(c.expect, {
						{
							ERROR, 2, false
						}
						, { ERROR, 4, true }
					}), "expectations")) return false;
		if (!@expect(parse_text(tmp, "/* { dg-do compile { target avr-*-* } } */\n").skip.len > 0, "dg-do target skip")) return false;
		if (!@expect(parse_text(tmp, "/* { dg-require-effective-target made_up_target } */\n").skip.contains("unknown"), "unknown target")) return false;
		if (!@expect(expect_eq(parse_text(tmp, "/* { dg-error \"x\" \"\" { target *-*-* } 0 } */\n").expect, {
					{
						ERROR, 0, false
					}
				}), "line 0")) return false;
		if (!@expect(expect_eq(parse_text(tmp, "int a; /* { dg-line l1 } */\n/* { dg-error \"x\" \"\" { target *-*-* } l1 } */\n").expect, {
					{
						ERROR, 1, false
					}
				}), "dg-line")) return false;
		if (!@expect((eval_expr(tmem, { "!", "ilp32" }) ?? false) && !(eval_expr(tmem, { "ilp32", "||", "ia32" }) ?? true), "eval_expr ops")) return false;
		if (!@expect(eval_expr(tmem, { "i?86-*-* x86_64-*-*" }) ?? false, "eval_expr list")) return false;
		Case k = { .suite = "dg", .path = "t.c", .name = "t.c", .action = "compile" };
		k.expect = {
			{
				ERROR, 3, false
			}
		};
		if (!@expect(check_expectations(tmem, &k, {
						{
							3, "error", "m"
						}
					}, 1).status == "PASS", "check pass")) return false;
		if (!@expect(check_expectations(tmem, &k, {
						{
							4, "error", "m"
						}
					}, 1).category == "unexpected-error", "check unexpected")) return false;
		if (!@expect(check_expectations(tmem, &k, {}, 0).category == "missing-error", "check missing")) return false;
		Case ac = { .suite = "abi", .path = "/s/test_x.c", .name = "test_x.c", .dir = "/s", .action = "run" };
		String[] dropped;
		String[] af = aro_flags(tmem, &ac, &dropped);
		if (!@expect(af.len == 3 && af[0] == "-W" && af[2] == "-Wno-abi" && !dropped.len, "abi flags")) return false;
		Options ao = { .aro = "aro", .abi_include = "/inc", .abi_support = "/o/asm-support.o" };
		String acmd = string::tjoin(compile_cmd(tmem, &ao, &ac, af, "run", "/w"), " ");
		if (!@expect(acmd.contains("-isystem /inc") && acmd.contains("/s/test_x.c /o/asm-support.o -lm"), "abi cmd")) return false;
	};
	io::printn("selftest ok");
	return true;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const String USAGE = `usage: gcc_testsuite [-h] [--gcc-testsuite GCC_TESTSUITE] [--aro ARO] [--zig-arocc ZIG_AROCC] [--suite SUITE]
                     [--filter FILTER] [--jobs JOBS] [--timeout TIMEOUT] [--out OUT]
                     [--resource-dir RESOURCE_DIR] [--abi-include ABI_INCLUDE] [--selftest]

Run the GCC C testsuite against aro_c3, treating GCC's expectations as golden.

options:
  -h, --help            show this help message and exit
  --gcc-testsuite GCC_TESTSUITE
                        testsuite root (default: the copy in test/gcc, see test/gcc/SOURCE)
  --aro ARO
  --zig-arocc ZIG_AROCC
                        Zig arocc binary for the differential check (build: zig build -p <dir> with a matching zig)
  --suite SUITE
  --filter FILTER       glob on the file name
  --jobs JOBS
  --timeout TIMEOUT     seconds per compile/run
  --out OUT
  --resource-dir RESOURCE_DIR
                        aro -resource-dir (builtin headers)
  --abi-include ABI_INCLUDE
                        dir with the abi suite's xmmintrin.h stand-in (default: test/src/gcc/abi_include)
  --selftest

Under "bazel run" (BUILD_WORKSPACE_DIRECTORY set) the default testsuite root is the workspace's test/gcc.
`;

const String[*] VALUE_OPTIONS = {
	"--gcc-testsuite", "--aro", "--zig-arocc", "--suite", "--filter", "--jobs", "--timeout", "--out",
	"--resource-dir", "--abi-include",
};
const String[*] FLAG_OPTIONS = { "--selftest", "--help" };

<* The repository root as the Python script saw it: TEST_SRCDIR/TEST_WORKSPACE under `bazel test`, else the current directory. *>
fn String root_dir(Allocator a)
{
	String src = aro_harness::getenv(tmem, "TEST_SRCDIR");
	if (src.len)
	{
		String ws = aro_harness::getenv(tmem, "TEST_WORKSPACE");
		return py_path(a, string::tformat("%s/%s", src, ws.len ? ws: "_main"));
	}
	return py_absolute(a, ".");
}

fn int usage_error(String msg) @local
{
	io::eprintf("%s", USAGE[:USAGE.index_of("\n\n") ?? USAGE.len]);
	io::eprintfn("\ngcc_testsuite: error: %s", msg);
	return 2;
}

fn int fatal(String msg) @local
{
	io::eprintn(msg);
	return 1;
}

<* Resolve an argparse-style long option, allowing unique prefixes. *>
fn String match_option(String name) @local
{
	String found = "";
	int matches = 0;
	foreach (o : VALUE_OPTIONS)
	{
		if (o == name) return o;
		if (o.starts_with(name))
		{
			found = o; matches++;
		}
	}
	foreach (o : FLAG_OPTIONS)
	{
		if (o == name) return o;
		if (o.starts_with(name))
		{
			found = o; matches++;
		}
	}
	return matches == 1 ? found : "";
}

struct RunCtx @local
{
	Case*[] cases;
	Object*[] results;
	Options* args;
	Mutex lock;
	sz done;
	Clock start;
}

fn void run_one(void* p, sz i) @local
{
	RunCtx* ctx = p;
	Clock case_start = clock::now();
	Object* r = run_case(mem, ctx.cases[i], ctx.args);
	ctx.results[i] = r;
	double secs = (double)case_start.to_now() / 1e9;
	// First line of the detail, truncated, so each case stays on one log line.
	String detail = field(r, "detail");
	sz? nl = detail.index_of_char('\n');
	if (try nl) detail = detail[:nl];
	detail = detail.trim();
	if (detail.len > 160) detail = detail[:160];
	String category = field(r, "category");
	ctx.lock.lock();
	defer ctx.lock.unlock();
	sz n = ++ctx.done;
	io::printfn("[%5d/%d] %-11s %s:%s%s%s%s%s (%.2fs)", n, ctx.cases.len, field(r, "status"),
		field(r, "suite"), field(r, "path"),
		category.len ? "  " : "", category,
		detail.len ? " — " : "", detail, secs);
}

fn void sort_strings(String[] items) @local
{
	sort::quicksort(items, fn int(String x, String y) => x.compare_to(y));
}

fn int main(String[] argv)
{
	Options args;
	String root = root_dir(mem);
	args.gcc_testsuite = string::format(mem, "%s/test/gcc", root);
	args.aro = string::format(mem, "%s/bazel-bin/aro_c3", root);
	args.suite = "compile,execute,ieee,dg,asm,abi";
	args.filter = "*";
	args.jobs = aro_harness::cpu_count();
	args.timeout = 60.0;
	String out_env = aro_harness::getenv(mem, "TEST_UNDECLARED_OUTPUTS_DIR");
	args.out = out_env.len ? out_env : string::format(mem, "%s/aro-gcc-testsuite", aro_harness::temp_root(tmem));
	args.resource_dir = root;
	args.abi_include = string::format(mem, "%s/test/src/gcc/abi_include", root);
	String ws = aro_harness::workspace_dir(mem);
	if (ws.len)
	{
		args.gcc_testsuite = string::format(mem, "%s/test/gcc", ws);
		args.abi_include = string::format(mem, "%s/test/src/gcc/abi_include", ws);
	}

	for (sz i = 1; i < argv.len; i++)
	{
		String arg = argv[i];
		if (arg == "-h") arg = "--help";
		if (!arg.starts_with("--") || arg.len == 2) return usage_error(string::tformat("unrecognized arguments: %s", arg));
		String value;
		bool has_value = false;
		String name = arg;
		sz? eq = arg.index_of_char('=');
		if (try eq)
		{
			name = arg[:eq];
			value = arg[eq + 1..];
			has_value = true;
		}
		String opt = match_option(name);
		if (!opt.len) return usage_error(string::tformat("unrecognized arguments: %s", arg));
		bool takes_value = false;
		foreach (o : VALUE_OPTIONS) if (o == opt) takes_value = true;
		if (takes_value && !has_value)
		{
			if (i + 1 >= argv.len) return usage_error(string::tformat("argument %s: expected one argument", opt));
			value = argv[++i];
		}
		else if (!takes_value && has_value)
		{
			return usage_error(string::tformat("argument %s: ignored explicit argument '%s'", opt, value));
		}
		switch (opt)
		{
			case "--help":
				io::print(USAGE);
				return 0;
			case "--gcc-testsuite": args.gcc_testsuite = value;
			case "--aro": args.aro = value;
			case "--zig-arocc": args.zig_arocc = value;
			case "--suite": args.suite = value;
			case "--filter": args.filter = value;
			case "--jobs":
				int? j = value.to_int();
				if (catch j) return usage_error(string::tformat("argument --jobs: invalid int value: '%s'", value));
				args.jobs = j;
			case "--timeout":
				double? t = value.to_double();
				if (catch t) return usage_error(string::tformat("argument --timeout: invalid float value: '%s'", value));
				args.timeout = t;
			case "--out": args.out = value;
			case "--resource-dir": args.resource_dir = value;
			case "--abi-include": args.abi_include = value;
			case "--selftest": args.selftest = true;
		}
	}
	if (args.selftest) return selftest() ? 0 : 1;
	args.gcc_testsuite = py_absolute(mem, args.gcc_testsuite);
	// Compiles run from each case's directory, so binaries must be absolute.
	args.aro = py_absolute(mem, args.aro);
	if (args.zig_arocc.len) args.zig_arocc = py_absolute(mem, args.zig_arocc);
	args.abi_include = py_absolute(mem, args.abi_include);
	if (!aro_harness::any_exists(args.aro)) return fatal(string::tformat("aro binary not found: %s (bazel build //:aro_c3)", args.aro));
	if (args.zig_arocc.len && !aro_harness::any_exists(args.zig_arocc))
	{
		return fatal(string::tformat("zig arocc not found: %s; build it with `zig build -p <dir>` in %s", args.zig_arocc, root));
	}
	if (args.jobs < 1) return fatal("ValueError: max_workers must be greater than 0");
	String out_dir = py_path(mem, args.out);

	List{Case*} cases;
	cases.init(mem);
	foreach (name : split_char(mem, args.suite, ','))
	{
		SuiteInfo* info = null;
		foreach (&s : SUITES) if (s.name == name) info = s;
		if (!info) return fatal(string::tformat("unknown suite %s; choose from compile, execute, ieee, dg, asm, abi", py_repr(tmem, name)));
		String dir = py_join(mem, args.gcc_testsuite, info.rel);
		String[]? names = aro_harness::list_sorted(mem, dir);
		if (catch names) continue;
		foreach (n : names)
		{
			if (!aro_harness::glob_match(info.glob, n) || !aro_harness::glob_match(args.filter, n)) continue;
			String p = string::format(mem, "%s/%s", dir, n);
			String rel = string::format(mem, "%s/%s", info.rel, n);
			Case* c = parse_case(mem, name, p, rel, info.action);
			if (name == "asm" && !c.has_asm_scan) continue;
			cases.push(c);
		}
	}
	// Bazel test sharding: take every Nth case.
	Case*[] selected = cases.array_view();
	int[2] shard = aro_harness::shard_info();
	if (shard[1] > 1)
	{
		List{Case*} mine;
		mine.init(mem);
		for (sz i = shard[0]; i < selected.len; i += shard[1]) mine.push(selected[i]);
		selected = mine.array_view();
	}
	if (catch aro_harness::mkdir_p(out_dir)) return fatal(string::tformat("cannot create %s", out_dir));
	foreach (c : selected)
	{
		if (c.suite != "abi") continue;
		String? obj = abi_support_object(mem, &args, c.dir, out_dir);
		if (catch obj) return 1;
		args.abi_support = obj;
		break;
	}
	RunCtx ctx = { .cases = selected, .args = &args, .start = clock::now() };
	ctx.results = mem::new_array(Object*, selected.len);
	ctx.lock.init()!!;
	aro_harness::parallel_for(args.jobs, selected.len, &run_one, &ctx);
	Object*[] results = ctx.results;

	DString jsonl;
	jsonl.init(mem);
	foreach (r : results)
	{
		jsonl.append(json::marshal(tmem, r));
		jsonl.append_char('\n');
	}
	if (catch file::save(string::tformat("%s/results.jsonl", out_dir), jsonl.str_view()))
	{
		return fatal("cannot write results.jsonl");
	}

	String summary = summary_text(mem, results);
	if (catch file::save(string::tformat("%s/summary.md", out_dir), summary)) return fatal("cannot write summary.md");

	List{String} status_names;
	status_names.init(mem);
	foreach (r : results)
	{
		String st = field(r, "status");
		bool seen = false;
		foreach (x : status_names) if (x == st)
		{
			seen = true; break;
		}
		if (!seen) status_names.push(st);
	}
	sort_strings(status_names.array_view());
	DString counts;
	counts.init(mem);
	sz failures = 0;
	foreach (i, st : status_names)
	{
		sz n = 0;
		foreach (r : results) if (field(r, "status") == st) n++;
		if (st == "FAIL" || st == "CRASH" || st == "TIMEOUT") failures += n;
		if (i) counts.append(", ");
		counts.appendf("%s %d", st, n);
	}
	io::printfn("%d cases in %.0fs: %s", results.len, (double)ctx.start.to_now() / 1e9, counts.str_view());
	io::printfn("results: %s/results.jsonl\nsummary: %s/summary.md", out_dir, out_dir);
	return failures ? 1 : 0;
}

// ---- Unit tests: the Python script's selftest() plus the Python string
// semantics the byte-identical outputs depend on.

fn void selftest_passes() @test
{
	assert(selftest());
}

fn void tcl_words_forms() @test
{
	String[] w = tcl_words(tmem, `"a b" {c {d}} e`);
	test::eq(w.len, 3);
	test::eq(w[0], "a b");
	test::eq(w[1], "c {d}");
	test::eq(w[2], "e");
	w = tcl_words(tmem, `"x\"y" { pad }{abc`);
	test::eq(w.len, 3);
	test::eq(w[0], `x\"y`);
	test::eq(w[1], "pad");
	// An unterminated brace word loses its last character, as in Python.
	test::eq(w[2], "ab");
}

fn void selectors() @test
{
	bool xfail;
	assert(eval_selector(tmem, "target { ! ilp32 }", &xfail)!!);
	assert(!xfail);
	assert(eval_selector(tmem, "xfail *-*-*", &xfail)!!);
	assert(xfail);
	assert(!eval_selector(tmem, "target avr-*-* arm*-*-*", &xfail)!!);
	assert(eval_selector(tmem, "target { lp64 && { ! ia32 } }", &xfail)!!);
	assert(eval_selector(tmem, "", &xfail)!!);
	assert(!eval_expr(tmem, { "!lp64" })!!);
	assert(@catch(eval_expr(tmem, { "no_such_target" })) == UNKNOWN_TARGET);
	test::eq(unknown_word, "no_such_target");
}

fn void lines_and_labels() @test
{
	Label[] labels = {
		{
			"l1", 7
		}
	};
	test::eq(resolve_line(".", 3, labels)!!, 3);
	test::eq(resolve_line(".-2", 3, labels)!!, 1);
	test::eq(resolve_line("12", 3, labels)!!, 12);
	test::eq(resolve_line("l1.+1", 3, labels)!!, 8);
	assert(@catch(resolve_line("l2", 3, labels)));
	assert(@catch(resolve_line("l1.x", 3, labels)));
}

fn void python_text() @test
{
	test::eq(py_decode(tmem, "a\r\nb\rc\xff\xe0\x80", true), "a\nb\nc\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd");
	String[] l = py_splitlines(tmem, "a\nb\x0cc\xe2\x80\xa8d\n");
	test::eq(l.len, 4);
	test::eq(l[3], "d");
	test::eq(py_split(tmem, " -O2\x1c-g ").len, 2);
	test::eq(py_repr(tmem, "it's"), `"it's"`);
	test::eq(py_repr(tmem, "a\\b"), `'a\\b'`);
	test::eq(normalize(tmem, "use of 'x' at 12, '3"), "use of 'X' at N, 'N");
	test::eq(cp_prefix("ééé", 2), "éé");
	test::eq(py_path(tmem, "/a//b/./c/"), "/a/b/c");
	test::eq(py_path(tmem, "./x/../y"), "x/../y");
}

fn void diagnostics() @test
{
	String out = "/d/t.c:3:5: error: bad\nother.h:1:1: warning: w\naro: error: no input\nfatal error: gone\nt.c:9:1: note: n\n";
	Diag[] d = parse_diags(tmem, out, { "t.c" });
	test::eq(d.len, 4);
	test::eq(d[0].line, 3);
	test::eq(d[0].msg, "bad");
	test::eq(d[1].line, -1);
	test::eq(d[1].msg, "no input");
	test::eq(d[2].msg, "gone");
	test::eq(d[3].sev, "note");
	test::eq(panic_search("x\nERROR: 'a'"), 2);
	test::eq(panic_search("@require \"x\" violated."), 0);
	test::eq(panic_search("@require x\n violated"), -1);
	test::eq(panic_search("a panic"), -1);
}

fn void tcl_substitution() @test
{
	test::eq(tcl_subst(tmem, `\[ \t\]+foo\\.x\.y`), "[ \t]+foo\\.x.y");
	test::eq(tcl_subst(tmem, `a\x41\101\n`), "aAA\n");
	test::eq(tcl_subst(tmem, `q\"`), `q"`);
}

fn void tcl_regex_translation() @test
{
	test::eq(tcl_regex_to_ere(tmem, `\mpow\M`)!!, `\<pow\>`);
	test::eq(tcl_regex_to_ere(tmem, `[\t ]+\.globl[^\n]*x`)!!, "[\t ]+\\.globl[^\n]*x");
	test::eq(tcl_regex_to_ere(tmem, `[\d\w-]`)!!, "[[:digit:][:alnum:]_-]");
	test::eq(tcl_regex_to_ere(tmem, `[]a][[:space:]]`)!!, "[]a][[:space:]]");
	assert(@catch(tcl_regex_to_ere(tmem, `a+?`)) == UNSUPPORTED_REGEX);
	assert(@catch(tcl_regex_to_ere(tmem, `(?:a)`)) == UNSUPPORTED_REGEX);
	assert(@catch(tcl_regex_to_ere(tmem, `(a)\1`)) == UNSUPPORTED_REGEX);
	assert(@catch(tcl_regex_to_ere(tmem, `[ab`)) == UNSUPPORTED_REGEX);
}

fn void asm_checks_parse_and_evaluate() @test
{
	String tmp = aro_harness::make_temp_dir(tmem, "gcc-ts-asm-")!!;
	defer aro_harness::remove_tree(tmp);
	String src = "/* { dg-final { scan-assembler \"call\\[ \\t\\]+bar\" } } */\n"
		"/* { dg-final { scan-assembler-not {\\mbaz\\M} } } */\n"
		"/* { dg-final { scan-assembler-times \"foo\" 3 { target x86_64-*-* } } } */\n"
		"/* { dg-final { scan-assembler \"never\" { target avr-*-* } } } */\n"
		"/* { dg-final { scan-assembler \"never\" { xfail *-*-* } } } */\n"
		"/* { dg-final { scan-assembler-dem \"x\" } } */\n"
		"/* { dg-final { scan-tree-dump \"x\" \"optimized\" } } */\n";
	Case* c = parse_text(tmp, src);
	assert(c.has_asm_scan);
	test::eq(c.asm_checks.len, 4);
	test::eq(c.asm_checks[0].pattern, "call[ \t]+bar");
	test::eq(c.asm_checks[1].kind.ordinal, AsmKind.ABSENT.ordinal);
	test::eq(c.asm_checks[1].pattern, `\mbaz\M`);
	test::eq(c.asm_checks[2].times, 3);
	assert(c.asm_checks[2].x86);
	assert(c.asm_checks[3].xfail);
	test::eq(c.asm_other.len, 1);
	test::eq(c.asm_other[0], "scan-assembler-dem");

	String good = "\t.globl foo\nfoo:\n\tcall\tbar\n\tjmp foo\n";
	test::eq(check_asm(tmem, c, good).status, "PASS");
	Check bad = check_asm(tmem, c, "\tcall bar\n\tbaz\n");
	test::eq(bad.status, "FAIL");
	test::eq(bad.category, "scan-assembler-not");
	assert(bad.detail.contains("got 0 want 3"));
	// Only the x86-guarded check fails: reported separately.
	test::eq(check_asm(tmem, c, "\tcall bar\n").category, "x86-insn");
}
