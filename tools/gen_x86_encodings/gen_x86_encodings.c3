// Generate src/backend/x86_64/encoding_table.c3 from the Zig compiler's
// x86_64 backend (src/codegen/x86_64/Encoding.zig + encodings.zon).
//
//   bazel run //tools/gen_x86_encodings -- ZIG_X86_64_DIR OUT_C3 [ZIG_COMMIT]
//
// Relative paths are taken from the workspace root. Only the baseline
// instructions used by IR lowering, approved parity conditions, and selected
// legacy SSE/SSE2 and x87 rows are kept. Enum member order follows
// Encoding.zig; table row order follows encodings.zon, which `find` relies on
// for its "first shortest match" choice.
module gen_x86_encodings;
import std::io, std::collections::list, aro_harness;

const String[*] MNEMONICS = {
	"add", "and", "call", "cdq", "cmp", "cqo", "cwde", "div", "idiv", "imul",
	"jmp", "lea", "leave", "mov", "movsx", "movsxd", "movzx", "neg", "not",
	"or", "pop", "push", "ret", "sar", "shl", "shr", "sub", "test", "xor",
	"seta", "setae", "setb", "setbe", "sete", "setne", "setg", "setge", "setl", "setle",
	"ja", "jae", "jb", "jbe", "je", "jne", "jg", "jge", "jl", "jle",
};

const String[*] SSE_MNEMONICS = {
	"addss", "andps", "comiss", "cvtsi2ss", "cvttss2si", "divss", "movaps", "movss",
	"mulss", "subss", "ucomiss", "xorps",
};

const String[*] SSE2_MNEMONICS = {
	"addsd", "andpd", "comisd", "cvtsd2ss", "cvtsi2sd", "cvtss2sd", "cvttsd2si", "divsd",
	"movd", "movq", "movsd", "mulsd", "pxor", "subsd", "ucomisd", "xorpd",
};

const String[*] PARITY_MNEMONICS = { "jnp", "jp", "setnp", "setp" };

const String[*] X87_MNEMONICS = {
	"fadd", "faddp", "fchs", "fcomip", "fdiv", "fdivp", "fdivr", "fdivrp",
	"fild", "fist", "fistp", "fisttp", "fld", "fldcw", "fmul", "fmulp",
	"fnclex", "fninit", "fnstcw", "fnstsw", "fst", "fstcw", "fstp", "fsub", "fsubp",
	"fsubr", "fsubrp", "fucomip", "fxch",
};

faultdef BAD_INPUT;

fn bool in_list(String[] list, String s)
{
	foreach (x : list) if (x == s) return true;
	return false;
}

fn bool is_approved_mnemonic(String mnemonic)
{
	return in_list(&MNEMONICS, mnemonic) || in_list(&PARITY_MNEMONICS, mnemonic) ||
		in_list(&SSE_MNEMONICS, mnemonic) || in_list(&SSE2_MNEMONICS, mnemonic) ||
		in_list(&X87_MNEMONICS, mnemonic);
}

fn bool include_unfeatured_mnemonic(String mnemonic)
{
	// MOVSD also names the legacy string-move instruction, whose rows have no SSE feature.
	return in_list(&MNEMONICS, mnemonic) || in_list(&PARITY_MNEMONICS, mnemonic) || mnemonic == "movsd";
}

<* Baseline x86_64 rows, plus approved legacy SSE/SSE2 rows. *>
fn bool include_feature(String mnemonic, String feature)
{
	if (feature == "none" || feature == "64bit")
	{
		return include_unfeatured_mnemonic(mnemonic);
	}
	if (feature == "sse") return in_list(&SSE_MNEMONICS, mnemonic);
	if (feature == "sse2") return in_list(&SSE2_MNEMONICS, mnemonic);
	if (feature == "x87") return in_list(&X87_MNEMONICS, mnemonic);
	if (feature == "cmov x87") return mnemonic == "fcomip" || mnemonic == "fucomip";
	if (feature == "sse3 x87") return mnemonic == "fisttp";
	return false;
}

<* Python `\s` for ASCII text. *>
fn bool is_ws(char c) @local => c == ' ' || (c >= '\t' && c <= '\r') || (c >= 0x1c && c <= 0x1f);
fn bool is_word(char c) @local => c.is_alnum() || c == '_';
fn bool is_digit(char c) @local => c >= '0' && c <= '9';

<* Python str.strip() for ASCII text. *>
fn String py_strip(String s)
{
	sz b = 0;
	sz e = s.len;
	while (b < e && is_ws(s[b])) b++;
	while (e > b && is_ws(s[e - 1])) e--;
	return s[b:e - b];
}

<* `ident` of the Python script: strip, drop a leading `.`, unwrap `@"..."`. *>
fn String ident(String tok)
{
	tok = py_strip(tok);
	if (tok.starts_with(".")) tok = tok[1..];
	if (tok.starts_with("@\"")) tok = tok.len >= 3 ? tok[2:tok.len - 3] : "";
	return tok;
}

<* Member tokens of `pub const NAME = enum[(...)] { ... }` in Zig source order (raw, before `ident`). *>
fn String[]? zig_enum(Allocator a, String src, String name)
{
	String head = string::tformat("pub const %s = enum", name);
	sz start = 0;
	bool found = false;
	for (sz i = 0; i + head.len <= src.len && !found; i++)
	{
		if (!src[i..].starts_with(head)) continue;
		sz p = i + head.len;
		// Optional `\([^)]*\)`, then ` {`; fall back to no argument list.
		if (p < src.len && src[p] == '(')
		{
			sz? close = src[p..].index_of_char(')');
			if (try close && src[p + close + 1..].starts_with(" {"))
			{
				start = p + close + 3;
				found = true;
				break;
			}
		}
		if (src[p..].starts_with(" {"))
		{
			start = p + 2;
			found = true;
		}
	}
	if (!found)
	{
		io::eprintfn("Encoding.zig: enum %s not found", name);
		return BAD_INPUT~;
	}
	sz end = sz::max;
	sz? e1 = src[start..].index_of("\n    pub fn ");
	if (try e1) end = start + e1;
	sz? e2 = src[start..].index_of("\n};");
	if (try e2 && start + e2 < end) end = start + e2;
	if (end == sz::max)
	{
		io::eprintfn("Encoding.zig: end of enum %s not found", name);
		return BAD_INPUT~;
	}
	String raw = src[start:end - start];
	// re.sub(r"//[^\n]*", "", body)
	DString body;
	body.init(tmem);
	for (sz i = 0; i < raw.len; i++)
	{
		if (raw[i] == '/' && i + 1 < raw.len && raw[i + 1] == '/')
		{
			while (i < raw.len && raw[i] != '\n') i++;
			if (i < raw.len) body.append('\n');
			continue;
		}
		body.append(raw[i]);
	}
	// re.findall(r'@"[^"]+"|[A-Za-z_][A-Za-z0-9_]*', body)
	String text = body.str_view();
	List{String} out;
	out.init(a);
	sz i = 0;
	while (i < text.len)
	{
		if (text[i] == '@' && i + 2 < text.len && text[i + 1] == '"' && text[i + 2] != '"')
		{
			sz? q = text[i + 2..].index_of_char('"');
			if (try q)
			{
				out.push(text[i:q + 3].copy(a));
				i += q + 3;
				continue;
			}
		}
		if (text[i].is_alpha() || text[i] == '_')
		{
			sz j = i + 1;
			while (j < text.len && is_word(text[j])) j++;
			out.push(text[i:j - i].copy(a));
			i = j;
			continue;
		}
		i++;
	}
	return out.array_view();
}

<* Captures of one encodings.zon row. *>
struct Row
{
	String mnemonic;
	String op_en;
	String ops;
	String opc;
	String ext;
	String mode;
	String feature;
}

fn sz skip_ws(String s, sz p) @local
{
	while (p < s.len && is_ws(s[p])) p++;
	return p;
}

fn bool lit(String s, sz* p, char c) @local
{
	if (*p >= s.len || s[*p] != c) return false;
	(*p)++;
	return true;
}

<* `\.[\w@"]+` (set = word chars plus extra) or `\.@"[^"]+"`; `alt` picks which. Returns the end or 0. *>
fn sz name_alt(String s, sz p, int alt, bool allow_at_quote) @local
{
	if (p >= s.len || s[p] != '.') return 0;
	p++;
	if (alt == 0)
	{
		sz q = p;
		while (q < s.len && (is_word(s[q]) || (allow_at_quote && (s[q] == '@' || s[q] == '"')))) q++;
		return q > p ? q : 0;
	}
	if (!s[p..].starts_with("@\"")) return 0;
	p += 2;
	sz q = p;
	while (q < s.len && s[q] != '"') q++;
	if (q == p || q >= s.len) return 0;
	return q + 1;
}

<* `\.\{([^}]*)\}` at p; returns the end or 0. *>
fn sz brace_list(String s, sz p, String* body) @local
{
	if (!s[p..].starts_with(".{")) return 0;
	p += 2;
	sz? close = s[p..].index_of_char('}');
	if (catch close) return 0;
	*body = s[p:close];
	return p + close + 1;
}

<* The row regex of the Python script anchored at `start`; returns the end of the match or 0. Only the
   two name alternations can backtrack; every other piece is deterministic. *>
fn sz match_row(String s, sz start, Row* r)
{
	sz p = start;
	if (!s[p..].starts_with(".{")) return 0;
	p = skip_ws(s, p + 2);
	for (int alt1 = 0; alt1 < 2; alt1++)
	{
		sz e1 = name_alt(s, p, alt1, true);
		if (!e1) continue;
		r.mnemonic = s[p:e1 - p];
		sz q = skip_ws(s, e1);
		if (!lit(s, &q, ',')) continue;
		q = skip_ws(s, q);
		if (!lit(s, &q, '.')) continue;
		sz w = q;
		while (q < s.len && is_word(s[q])) q++;
		if (q == w) continue;
		r.op_en = s[w:q - w];
		q = skip_ws(s, q);
		if (!lit(s, &q, ',')) continue;
		q = skip_ws(s, q);
		q = brace_list(s, q, &r.ops);
		if (!q) continue;
		q = skip_ws(s, q);
		if (!lit(s, &q, ',')) continue;
		q = skip_ws(s, q);
		q = brace_list(s, q, &r.opc);
		if (!q) continue;
		q = skip_ws(s, q);
		if (!lit(s, &q, ',')) continue;
		q = skip_ws(s, q);
		w = q;
		while (q < s.len && is_digit(s[q])) q++;
		if (q == w) continue;
		r.ext = s[w:q - w];
		q = skip_ws(s, q);
		if (!lit(s, &q, ',')) continue;
		q = skip_ws(s, q);
		if (!lit(s, &q, '.')) continue;
		w = q;
		while (q < s.len && is_word(s[q])) q++;
		if (q == w) continue;
		r.mode = s[w:q - w];
		q = skip_ws(s, q);
		if (!lit(s, &q, ',')) continue;
		q = skip_ws(s, q);
		for (int alt7 = 0; alt7 < 2; alt7++)
		{
			sz e7 = name_alt(s, q, alt7, false);
			if (!e7) continue;
			sz t = skip_ws(s, e7);
			if (!lit(s, &t, '}')) continue;
			r.feature = s[q:e7 - q];
			return t;
		}
	}
	return 0;
}

<* row_re.finditer: non-overlapping matches, left to right. *>
fn Row[] find_rows(Allocator a, String zon)
{
	List{Row} out;
	out.init(a);
	sz i = 0;
	while (i < zon.len)
	{
		Row r;
		sz end = match_row(zon, i, &r);
		if (end)
		{
			out.push(r);
			i = end;
			continue;
		}
		i++;
	}
	return out.array_view();
}

<* `[t.strip() for t in s.split(",") if t.strip()]`, optionally through `ident`. *>
fn String[] split_items(Allocator a, String s, bool as_ident) @local
{
	List{String} out;
	out.init(a);
	foreach (t : s.split(a, ","))
	{
		if (!py_strip(t).len) continue;
		out.push(as_ident ? ident(t) : py_strip(t));
	}
	return out.array_view();
}

<* Keep only valid x86_64 rows. SSE opcodes use the 0F map, optionally preceded by a mandatory prefix. *>
fn bool include_row(Row row)
{
	String mnemonic = ident(row.mnemonic);
	String feature = ident(row.feature);
	String mode = ident(row.mode);
	if (!is_approved_mnemonic(mnemonic) || mode.starts_with("vex_")) return false;
	if (!include_feature(mnemonic, feature)) return false;
	if (feature == "none" || feature == "64bit") return true;
	if (in_list(&X87_MNEMONICS, mnemonic)) return mode == "none" || mode == "wait";
	if (mode != "none" && mode != "long") return false;
	String[] opcode = split_items(tmem, row.opc, false);
	if (opcode.len < 2 || opcode.len > 3) return false;
	sz map_index = 0;
	if (opcode[0] == "0x66" || opcode[0] == "0xf2" || opcode[0] == "0xf3") map_index = 1;
	if (opcode.len != map_index + 2 || opcode[map_index] != "0x0f") return false;
	// 0F 38, 0F 3A and 0F 0F select other opcode maps, not legacy SSE/SSE2's 0F map.
	String opcode_byte = opcode[map_index + 1];
	return opcode_byte != "0x38" && opcode_byte != "0x3a" && opcode_byte != "0x0f";
}

fn bool is_ascii(String s) @local
{
	foreach (c : s) if (c >= 0x80) return false;
	return true;
}

<* The generated C3 source and the "N mnemonics, M rows" summary. *>
fn String? generate(Allocator a, String enc_src, String zon, String commit, String* summary)
{
	if (!is_ascii(enc_src) || !is_ascii(zon))
	{
		io::eprintn("non-ASCII Encoding.zig/encodings.zon input is not supported");
		return BAD_INPUT~;
	}
	@pool()
	{
		List{String} mnemonics;
		mnemonics.init(tmem);
		foreach (t : zig_enum(tmem, enc_src, "Mnemonic")!)
		{
			String m = ident(t);
			if (is_approved_mnemonic(m)) mnemonics.push(m);
		}
		foreach (m : MNEMONICS)
		{
			if (!in_list(mnemonics.array_view(), m))
			{
				io::eprintfn("AssertionError: mnemonic %s missing from Encoding.zig", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : PARITY_MNEMONICS)
		{
			if (!in_list(mnemonics.array_view(), m))
			{
				io::eprintfn("AssertionError: mnemonic %s missing from Encoding.zig", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : SSE_MNEMONICS)
		{
			if (!in_list(mnemonics.array_view(), m))
			{
				io::eprintfn("AssertionError: mnemonic %s missing from Encoding.zig", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : SSE2_MNEMONICS)
		{
			if (!in_list(mnemonics.array_view(), m))
			{
				io::eprintfn("AssertionError: mnemonic %s missing from Encoding.zig", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : X87_MNEMONICS)
		{
			if (!in_list(mnemonics.array_view(), m))
			{
				io::eprintfn("AssertionError: mnemonic %s missing from Encoding.zig", m);
				return BAD_INPUT~;
			}
		}
		List{String} op_ens;
		op_ens.init(tmem);
		foreach (t : zig_enum(tmem, enc_src, "OpEn")!) op_ens.push(ident(t));
		List{String} modes;
		modes.init(tmem);
		foreach (t : zig_enum(tmem, enc_src, "Mode")!) modes.push(ident(t));
		List{String} ops;
		ops.init(tmem);
		foreach (t : zig_enum(tmem, enc_src, "Op")!) ops.push(ident(t));

		List{Row} rows;
		rows.init(tmem);
		foreach (r : find_rows(tmem, zon))
		{
			if (!include_row(r)) continue;
			String mn = ident(r.mnemonic);
			String[] row_ops = split_items(tmem, r.ops, true);
			String[] opc = split_items(tmem, r.opc, false);
			if (row_ops.len > 4 || opc.len < 1 || opc.len > 3)
			{
				io::eprintfn("AssertionError: bad row for %s (%d operands, %d opcode bytes)", mn, row_ops.len, opc.len);
				return BAD_INPUT~;
			}
			foreach (o : row_ops)
			{
				if (!in_list(ops.array_view(), o))
				{
					io::eprintfn("AssertionError: unknown operand %s", o);
					return BAD_INPUT~;
				}
			}
			rows.push({ .mnemonic = mn, .op_en = r.op_en, .ops = r.ops, .opc = r.opc, .ext = r.ext, .mode = r.mode });
		}
		foreach (m : MNEMONICS)
		{
			bool has_row = false;
			foreach (r : rows) if (r.mnemonic == m) has_row = true;
			if (!has_row)
			{
				io::eprintfn("AssertionError: no x86_64 rows for %s", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : PARITY_MNEMONICS)
		{
			bool has_row = false;
			foreach (r : rows) if (r.mnemonic == m) has_row = true;
			if (!has_row)
			{
				io::eprintfn("AssertionError: no x86_64 rows for %s", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : SSE_MNEMONICS)
		{
			bool has_row = false;
			foreach (r : rows) if (r.mnemonic == m) has_row = true;
			if (!has_row)
			{
				io::eprintfn("AssertionError: no legacy SSE rows for %s", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : SSE2_MNEMONICS)
		{
			bool has_row = false;
			foreach (r : rows) if (r.mnemonic == m) has_row = true;
			if (!has_row)
			{
				io::eprintfn("AssertionError: no legacy SSE2 rows for %s", m);
				return BAD_INPUT~;
			}
		}
		foreach (m : X87_MNEMONICS)
		{
			bool has_row = false;
			foreach (r : rows) if (r.mnemonic == m) has_row = true;
			if (!has_row)
			{
				io::eprintfn("AssertionError: no x87 rows for %s", m);
				return BAD_INPUT~;
			}
		}

		DString o;
		o.init(a);
		o.append("// GENERATED by //tools/gen_x86_encodings from the Zig compiler's\n");
		o.appendf("// src/codegen/x86_64/Encoding.zig and encodings.zon (zig %s).\n", commit);
		o.append("// Do not edit by hand; regenerate instead.\n");
		o.append("module aro::backend::x86_64;\n");
		o.append("\n");
		o.append("<* Zig `Encoding.Mnemonic`, restricted to the instructions supported by this backend. *>\n");
		o.append("enum Mnemonic : char (String name)\n");
		o.append("{\n");
		foreach (mn : mnemonics) o.appendf("\t%s { \"%s\" },\n", mn.to_upper_tcopy(), mn);
		o.append("}\n");
		o.append("\n");
		o.append("<* Zig `Encoding.OpEn`: how operands are encoded. *>\n");
		o.append("enum OpEn : char\n");
		o.append("{\n");
		o.appendf("\t%s,\n", upper_join(op_ens.array_view(), "", ", "));
		o.append("}\n");
		o.append("\n");
		o.append("<* Zig `Encoding.Mode`: operand-size / REX / VEX prefix requirements. *>\n");
		o.append("enum Mode : char\n");
		o.append("{\n");
		o.appendf("\t%s,\n", upper_join(modes.array_view(), "", ", "));
		o.append("}\n");
		o.append("\n");
		o.append("<* Zig `encodings.zon` rows for the mnemonics above (x86_64, approved legacy SSE/SSE2, and selected x87), in table order. *>\n");
		o.append("const Entry[*] ENCODINGS = {\n");
		foreach (r : rows)
		{
			List{String} ops4;
			ops4.init(tmem);
			ops4.push_all(split_items(tmem, r.ops, true));
			while (ops4.len() < 4) ops4.push("none");
			String[] opc = split_items(tmem, r.opc, false);
			List{String} opcs;
			opcs.init(tmem);
			opcs.push_all(opc);
			while (opcs.len() < 3) opcs.push("0");
			o.appendf("\t{ Mnemonic.%s, OpEn.%s, { %s }, { %s }, %d, %s, Mode.%s },\n",
				r.mnemonic.to_upper_tcopy(), r.op_en.to_upper_tcopy(),
				upper_join(ops4.array_view(), "Op.", ", "),
				string::tjoin(opcs.array_view(), ", "), opc.len, r.ext, r.mode.to_upper_tcopy());
		}
		o.append("};\n");
		*summary = string::format(a, "%d mnemonics, %d rows", mnemonics.len(), rows.len());
		return o.str_view();
	};
}

<* `sep.join(prefix + x.upper() for x in items)`. *>
fn String upper_join(String[] items, String prefix, String sep) @local
{
	DString d;
	d.init(tmem);
	foreach (i, x : items)
	{
		if (i) d.append(sep);
		d.append(prefix);
		d.append(x.to_upper_tcopy());
	}
	return d.str_view();
}

<* A user-supplied path: relative ones are taken from the workspace root (where the Python tool ran). *>
fn String user_path(Allocator a, String p)
{
	if (p.starts_with("/")) return p.copy(a);
	String ws = aro_harness::workspace_dir(tmem);
	if (!ws.len) return aro_harness::absolute(a, p);
	return string::format(a, "%s/%s", ws, p);
}

fn int main(String[] args)
{
	if (args.len < 3)
	{
		io::eprintn("usage: bazel run //tools/gen_x86_encodings -- ZIG_X86_64_DIR OUT_C3 [ZIG_COMMIT]");
		return 2;
	}
	String zig_dir = user_path(mem, args[1]);
	String out = user_path(mem, args[2]);
	String commit = args.len > 3 ? args[3] : "unknown";
	String enc_path = string::format(mem, "%s/Encoding.zig", zig_dir);
	String zon_path = string::format(mem, "%s/encodings.zon", zig_dir);
	char[]? enc_src = file::load(mem, enc_path);
	if (catch err = enc_src)
	{
		io::eprintfn("unable to read %s: %s", enc_path, err);
		return 1;
	}
	char[]? zon = file::load(mem, zon_path);
	if (catch err = zon)
	{
		io::eprintfn("unable to read %s: %s", zon_path, err);
		return 1;
	}
	String summary;
	String? content = generate(mem, (String)enc_src, (String)zon, commit, &summary);
	if (catch content) return 1;
	if (catch err = file::save(out, content))
	{
		io::eprintfn("unable to write %s: %s", out, err);
		return 1;
	}
	io::printn(summary);
	return 0;
}
