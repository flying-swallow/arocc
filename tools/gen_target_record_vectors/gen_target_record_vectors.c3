// Regenerate the record-derived vectors in test/unit/types/target_tests.c3.
//
// Reads test/records/0013_test.c (auto-generated from mahkoh/repr-c), whose
// MAPPING groups assert sizeof/_Alignof of char, short, int, long, long long,
// void*, float and double for 109 `arch-cpu-os-abi` targets, and writes one
// RecordVector row per target between the BEGIN/END markers of
// test/unit/types/target_tests.c3. x86/arm Darwin targets are left out because
// test/record_runner.zig skips them as unsupported by aro.
//
//   bazel run //tools/gen_target_record_vectors [-- --check]
module gen_target_record_vectors;
import std::io, std::collections::list, aro_harness;

const String RECORDS_REL = "test/records/0013_test.c";
const String TESTS_REL = "test/unit/types/target_tests.c3";
const String BEGIN = "\t// BEGIN GENERATED RECORD VECTORS (//tools/gen_target_record_vectors)\n";
const String END = "\t// END GENERATED RECORD VECTORS\n";

<* typedef letter in 0013_test.c -> column order of RecordVector.values:
   char, short, int, long, long long, void*, float, double. *>
const String ORDER = "AEGIKLMN";

faultdef BAD_INPUT;

<* One `#if GROUP` block: sizeof ([0]) and _Alignof ([1]) per typedef letter A..N, as decimal strings. *>
struct Group
{
	String name;
	String[2][14] vals;
}

<* One `// MAPPING|NAME|target:compiler|...|END` line: the targets without the compiler suffix. *>
struct Mapping
{
	String name;
	String[] targets;
}

fn bool is_word(char c) @local => c.is_alnum() || c == '_';
fn bool is_digit(char c) @local => c >= '0' && c <= '9';

<* Python's universal-newline text read: \r\n and \r become \n. *>
fn String universal_newlines(Allocator a, String text)
{
	if (!text.contains("\r")) return text.copy(a);
	DString out;
	out.init(a);
	for (sz i = 0; i < text.len; i++)
	{
		char c = text[i];
		if (c == '\r')
		{
			out.append('\n');
			if (i + 1 < text.len && text[i + 1] == '\n') i++;
			continue;
		}
		out.append(c);
	}
	return out.str_view();
}

<* Length of the greedy \w+ run at `p` (0 when none). *>
fn sz word_len(String s, sz p) @local
{
	sz n = 0;
	while (p + n < s.len && is_word(s[p + n])) n++;
	return n;
}

<* re.match(r"// MAPPING\|(\w+)\|(.*)\|END", line). *>
fn bool match_mapping(String line, String* name, String* rest)
{
	const String HEAD = "// MAPPING|";
	if (!line.starts_with(HEAD)) return false;
	sz p = HEAD.len;
	sz n = word_len(line, p);
	if (!n) return false;
	*name = line[p:n];
	p += n;
	if (p >= line.len || line[p] != '|') return false;
	p++;
	// Greedy `.*` then `\|END`: the last `|END` at or after p.
	sz? last = line[p..].rindex_of("|END");
	if (catch last) return false;
	*rest = line[p:last];
	return true;
}

<* re.match(r"#(?:el)?if(?:def)? ?(?:defined\()?(\w+)\)?", line): group 1, tried in the regex's backtracking order. *>
fn bool match_if(String line, String* name)
{
	if (!line.len || line[0] != '#') return false;
	// Each optional piece is greedy: try taking it first, then skipping it.
	for (int el = 0; el < 2; el++)
	{
		sz p0 = 1;
		if (el == 0)
		{
			if (!line[p0..].starts_with("el")) continue;
			p0 += 2;
		}
		if (!line[p0..].starts_with("if")) continue;
		p0 += 2;
		for (int def = 0; def < 2; def++)
		{
			sz p1 = p0;
			if (def == 0)
			{
				if (!line[p1..].starts_with("def")) continue;
				p1 += 3;
			}
			for (int sp = 0; sp < 2; sp++)
			{
				sz p2 = p1;
				if (sp == 0)
				{
					if (p2 >= line.len || line[p2] != ' ') continue;
					p2++;
				}
				for (int dn = 0; dn < 2; dn++)
				{
					sz p3 = p2;
					if (dn == 0)
					{
						if (!line[p3..].starts_with("defined(")) continue;
						p3 += 8;
					}
					// Greedy \w+; the trailing `\)?` always succeeds.
					sz n = word_len(line, p3);
					if (!n) continue;
					*name = line[p3:n];
					return true;
				}
			}
		}
	}
	return false;
}

<* re.match(r"_Static_assert\((sizeof|_Alignof)\(([A-N])\) == (\d+)", line). *>
fn bool match_assert(String line, int* kind, int* letter, String* value)
{
	const String HEAD = "_Static_assert(";
	if (!line.starts_with(HEAD)) return false;
	sz p = HEAD.len;
	if (line[p..].starts_with("sizeof("))
	{
		*kind = 0;
		p += 7;
	}
	else if (line[p..].starts_with("_Alignof("))
	{
		*kind = 1;
		p += 9;
	}
	else
	{
		return false;
	}
	if (p >= line.len || line[p] < 'A' || line[p] > 'N') return false;
	*letter = line[p] - 'A';
	p++;
	if (!line[p..].starts_with(") == ")) return false;
	p += 5;
	sz n = 0;
	while (p + n < line.len && is_digit(line[p + n])) n++;
	if (!n) return false;
	*value = line[p:n];
	return true;
}

<* str(int(digits)). *>
fn String int_str(String digits) @local
{
	sz i = 0;
	while (i + 1 < digits.len && digits[i] == '0') i++;
	return digits[i..];
}

<* The RecordVector rows for the records file `text` (already newline-normalised). *>
fn String? rows(Allocator a, String text)
{
	List{Group} groups;
	groups.init(tmem);
	List{Mapping} targets;
	targets.init(tmem);
	long cur = -1;
	foreach (line : text.tsplit("\n"))
	{
		String name;
		String rest;
		if (match_mapping(line, &name, &rest))
		{
			List{String} ts;
			ts.init(tmem);
			foreach (t : rest.tsplit("|"))
			{
				sz colon = t.index_of_char(':') ?? t.len;
				ts.push(t[:colon]);
			}
			Mapping m = { name, ts.array_view() };
			bool replaced = false;
			foreach (&old : targets)
			{
				if (old.name != name) continue;
				*old = m;
				replaced = true;
				break;
			}
			if (!replaced) targets.push(m);
			continue;
		}
		if (match_if(line, &name))
		{
			bool known = false;
			foreach (m : targets) if (m.name == name) known = true;
			if (known)
			{
				// groups[cur] = {}: a repeated group keeps its position but restarts empty.
				cur = -1;
				foreach (i, &g : groups)
				{
					if (g.name != name) continue;
					*g = { .name = name };
					cur = i;
					break;
				}
				if (cur < 0)
				{
					groups.push({ .name = name });
					cur = groups.len() - 1;
				}
				continue;
			}
		}
		int kind;
		int letter;
		String value;
		if (cur >= 0 && match_assert(line, &kind, &letter, &value))
		{
			groups[cur].vals[letter][kind] = int_str(value);
		}
	}

	DString out;
	out.init(a);
	List{String} seen;
	seen.init(tmem);
	foreach (g : groups)
	{
		DString nums;
		nums.init(tmem);
		foreach (k : ORDER)
		{
			for (int kind = 0; kind < 2; kind++)
			{
				String v = g.vals[k - 'A'][kind];
				if (!v.len)
				{
					io::eprintfn("group %s: no %s(%c) assertion", g.name, kind ? "_Alignof" : "sizeof", k);
					return BAD_INPUT~;
				}
				if (nums.len()) nums.append(", ");
				nums.append(v);
			}
		}
		String[] ts;
		foreach (m : targets) if (m.name == g.name) ts = m.targets;
		foreach (t : ts)
		{
			bool dup = false;
			foreach (s : seen) if (s == t) dup = true;
			if (dup) continue;
			seen.push(t);
			String[] parts = t.tsplit("-");
			if (parts.len != 4)
			{
				io::eprintfn("target '%s' is not arch-cpu-os-abi", t);
				return BAD_INPUT~;
			}
			String arch = parts[0];
			String cpu = parts[1];
			String os = parts[2];
			String abi = parts[3];
			if ((os == "ios" || os == "macos") && (arch == "x86" || arch == "arm")) continue;
			out.appendf("\t{ \"%s-%s-%s\", \"%s\", { %s } }, // group %s\n", arch, os, abi, cpu, nums.str_view(), g.name);
		}
	}
	return out.str_view();
}

<* `tests` with the region between BEGIN and END replaced by the rows for `records`. *>
fn String? rewrite(Allocator a, String tests, String records)
{
	foreach (c : records)
	{
		if (c >= 0x80)
		{
			io::eprintfn("%s: non-ASCII input is not supported", RECORDS_REL);
			return BAD_INPUT~;
		}
	}
	sz? begin = tests.index_of(BEGIN);
	sz? end = tests.index_of(END);
	if (catch begin)
	{
		io::eprintfn("%s: BEGIN marker not found: %s", TESTS_REL, BEGIN[..^2]);
		return BAD_INPUT~;
	}
	if (catch end)
	{
		io::eprintfn("%s: END marker not found", TESTS_REL);
		return BAD_INPUT~;
	}
	sz start = begin + BEGIN.len;
	@pool()
	{
		String body = rows(tmem, records)!;
		return string::format(a, "%s%s%s", tests[:start], body, tests[end..]);
	};
}

fn int main(String[] args)
{
	bool check = false;
	foreach (arg : args[1..])
	{
		if (arg == "--check") check = true;
	}
	String root = aro_harness::repo_root(mem);
	String records_path = string::format(mem, "%s/%s", root, RECORDS_REL);
	String tests_path = string::format(mem, "%s/%s", root, TESTS_REL);
	char[]? records = file::load(mem, records_path);
	if (catch err = records)
	{
		io::eprintfn("unable to read %s: %s", records_path, err);
		return 1;
	}
	char[]? tests = file::load(mem, tests_path);
	if (catch err = tests)
	{
		io::eprintfn("unable to read %s: %s", tests_path, err);
		return 1;
	}
	String text = universal_newlines(mem, (String)tests);
	String? updated = rewrite(mem, text, universal_newlines(mem, (String)records));
	if (catch updated) return 1;
	if (check)
	{
		if (updated != text)
		{
			io::printn("target_tests.c3 record vectors are stale; rerun bazel run //tools/gen_target_record_vectors");
			return 1;
		}
		return 0;
	}
	if (catch err = file::save(tests_path, updated))
	{
		io::eprintfn("unable to write %s: %s", tests_path, err);
		return 1;
	}
	return 0;
}
