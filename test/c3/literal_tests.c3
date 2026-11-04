// Plan 11 acceptance target: //test/c3:literal_tests.
//
// Data-driven over test/c3/data/literals/*.txt (format, provenance and caveats
// in that directory's README.md). Every vector runs through the parser-free
// literal API only -- number_literal::NumberLiteralParser,
// number_value::number_value / pp_int_value, text_literal::TextLiteralParser /
// TextLiteralKind, text_literal_semantics::char_literal / pp_char_value /
// string_run / string_literal, Value.print -- with no token list and no AST
// (the "no-AST decode path" of the plan).
//
// Each vector's result is rendered in the vector syntax and compared as text,
// and its diagnostics are compared in emission order as `tok:col text` (exact
// text; the column is the expanded column of token `tok`'s location plus the
// vector's byte offset). The vectors list diagnostics before the
// effective-kind filter, so every Compilation here runs with -Weverything
// (`enable_all_warnings`): off-by-default templates are then emitted too.
// Diagnostics that the API returns instead of reporting (NumberValueDiag,
// TextSemanticsDiag) are appended after the reported ones at offset 0, which
// is where Zig reports them.
//
// Provenance: `fixture` / `fixture-ast` lines are copied from test/cases (the
// reference oracle); `zig-0.17.0-port[-dblround]` lines were computed by
// running a Zig 0.17.0 port of the Aro sources (not the pinned 0.18-dev
// binary). `kinds.txt` `target_info` lines are checked like any other vector,
// and before the literal files (FILES order), so a target-table difference
// shows up there first.
//
// `= unreachable` vectors are Zig safety panics (no reference behaviour). The
// port must not crash and must emit the listed diagnostics first; what it does
// instead is pinned in UNREACHABLE_RESULTS (29 vectors, 5 distinct results):
//   - plain char constant holding one character > 0xFF on a signed-char
//     target ('€', '😀'): Zig @intCast(u8) panics after char_too_large; the
//     port truncates the codepoint to 8 bits and sign-extends ('€' -> -0x54).
//   - backslash before a non-ASCII byte ('\é', "\é"): Zig Ascii.init
//     (@intCast to u7) panics; the port reports "unknown escape sequence
//     '\xc3'" and then decodes the remaining byte 0xA9 as improperly encoded
//     text (illegal character encoding warning; '\é' is then multichar).
//   - `0x.p1`: Zig's std.fmt.parseFloat fails after the syntax check accepted
//     it (`catch unreachable`); the port reports the C3-only error
//     "hexadecimal floating constant requires a significand" and uses +0.0.
//
// Two documented differences between the probe's model and the real
// (ported) value representation are normalised before comparing `number`
// results, and counted:
//   - STATIC_REF: Zig `Interner.Key.toRef` maps a float key equal to +0.0 or
//     1.0 to the static int refs `zero` / `one` (value_interner.c3 header), so
//     the interned value of `1.0f` *is* the int 1. The probe keeps Zig floats,
//     so its `f32:0x3f800000` becomes `0x1` here (and +0.0 becomes `0x0`).
//   - IMAG_FLOAT_NODE: for an imaginary float the probe's `literal_val` is the
//     parsed float; Zig never stores a value on that inner float_literal node
//     (parseFloat has no putValue; the oracle test/cases/ast/__float80.c prints
//     `float_literal: 'long double'` without a value), so NumberValue gives
//     `none`, as number_value.c3 documents.
//
// Files are read relative to the working directory (the Bazel runfiles root),
// or from $LITERAL_VECTORS_DIR when set.
module literal_tests;
import aro::number_literal, aro::number_value, aro::text_literal, aro::text_literal_semantics;
import aro::compilation, aro::diagnostics, aro::source, aro::target, aro::type_store, aro::lang_opts, aro::tokenizer;
import aro::value, aro::value_interner, aro::float_value, aro::bigint;
import std::io, std::os::env, std::core::mem::allocators, std::core::dstring;

const Host HOST = { X86_64, LINUX, GNU };
const usz MAX_REPORTED = 40;
const usz MAX_DIAGS = 16;

<*
 What the port produces for the `= unreachable` vectors (Zig safety panics),
 independent of the configuration: "<op> <input> => <port result><port
 diagnostics>". Every entry must be hit, and every such vector must match one.
*>
const String[] UNREACHABLE_RESULTS = {
	// parseFloat `catch unreachable`: C3-only error, value +0.0 (the static int zero).
	"number 0x.p1 => hex None 0x.p1 double 0x0 double 0x0 | 0:1 hexadecimal floating constant requires a significand",
	// @intCast to u8 after char_too_large: the codepoint truncated to 8 bits, sign-extended.
	"char '%E2%82%AC' => char int signed -0x54 | 0:1 character too large for enclosing character literal type",
	"char '%F0%9F%98%80' => char int signed 0x0 | 0:1 character too large for enclosing character literal type",
	// Ascii.init on a non-ASCII escaped byte: '\xNN' in the text, then the rest decodes normally.
	"char '\\%C3%A9' => char int unsigned 0xc3a9 | 0:2 unknown escape sequence '\\xc3' | 0:1 illegal character encoding in character literal | 0:1 multi-character character constant",
	"string \"\\%C3%A9\" => char 1 char[3] c3a900 | 0:2 unknown escape sequence '\\xc3' | 0:1 illegal character encoding in character literal",
};

// ---------------------------------------------------------------------------
// Diagnostics as compared

struct Diag
{
	uint tok;
	uint col;
	String text;
	<* Template facts (for fixture `[-W...]` checks). *>
	MessageKind kind;
	bool has_opt;
	Option opt;
	bool extension;
}

struct DiagList
{
	Diag[MAX_DIAGS] items;
	usz len;
}

fn void DiagList.push(&self, Diag d)
{
	assert(self.len < MAX_DIAGS, "too many diagnostics");
	self.items[self.len++] = d;
}

fn String DiagList.render(&self)
{
	DString s = dstring::temp();
	for (usz i = 0; i < self.len; i++)
	{
		Diag* d = &self.items[i];
		s.appendf(" | %d:%d %s", d.tok, d.col, d.text);
	}
	return s.str_view();
}

// ---------------------------------------------------------------------------
// One vector's compilation

<* The compilation of one vector: one source per input token (`t<i>.c`). *>
struct Ctx
{
	Compilation comp;
	Diagnostics diags;
	SourceId[8] srcs;
	usz src_count;
	<* Diagnostics returned (not reported) by the API, in order. *>
	DiagList returned;
}

fn bool? Ctx.init(&self, Allocator a, String cfg)
{
	String[6] buf;
	String[] parts = cfg.split_to_buffer("/", buf[..])!;
	if (parts.len < 3) return false;
	self.diags.init_list(a);
	self.diags.state.enable_all_warnings = true;
	self.comp.init(a, null, &self.diags);
	self.comp.target = target::parse_triple(parts[0], HOST)!;
	self.comp.langopts.set_target_options(&self.comp.target);
	switch (parts[2])
	{
		case "gcc": self.comp.langopts.emulate = GCC;
		case "clang": self.comp.langopts.emulate = CLANG;
		case "msvc": self.comp.langopts.emulate = MSVC;
		case "no": self.comp.langopts.emulate = NO;
		default: return false;
	}
	if (parts[1] == "default")
	{
		self.comp.langopts.standard = DEFAULT;
	}
	else
	{
		self.comp.langopts.standard = lang_opts::standard_from_name(parts[1])!;
	}
	foreach (opt : parts[3..])
	{
		switch (opt)
		{
			case "ms": self.comp.langopts.set_ms_extensions(true);
			case "uchar": self.comp.langopts.set_char_signedness(UNSIGNED);
			case "schar": self.comp.langopts.set_char_signedness(SIGNED);
			default: return false;
		}
	}
	type_store::init_named_types(&self.comp);
	return true;
}

fn void Ctx.free(&self)
{
	self.comp.free();
	self.diags.free();
}

<* Add token `text` as source `t<i>.c`; its location is byte 0, line 1. *>
fn Location Ctx.add_token(&self, String text)
{
	String path = string::tformat("t%d.c", self.src_count);
	Source src = self.comp.add_source_from_buffer(path, text)!!;
	self.srcs[self.src_count++] = src.id;
	return { .id = src.id, .byte_offset = 0, .line = 1 };
}

<* Expanded column of byte `offset` of token `tok`. *>
fn uint Ctx.col(&self, uint tok, uint offset)
{
	Location loc = { .id = self.srcs[tok], .byte_offset = offset, .line = 1 };
	return loc.expand(&self.comp).col;
}

fn void Ctx.add_returned(&self, uint tok, DiagnosticTemplate t)
{
	self.returned.push({ .tok = tok, .col = self.col(tok, 0), .text = t.fmt, .kind = t.kind, .has_opt = t.has_opt, .opt = t.opt, .extension = t.extension });
}

<* Reported messages (by token source) followed by the returned diagnostics. *>
fn DiagList Ctx.produced(&self)
{
	DiagList out;
	foreach (&m : self.diags.messages)
	{
		uint tok = 0;
		if (m.has_location)
		{
			String p = m.location.path;
			assert(p.starts_with("t") && p.ends_with(".c"));
			tok = (uint)p[1:p.len - 3].to_long()!!;
		}
		out.push({ .tok = tok, .col = m.has_location ? m.location.col : 0, .text = m.text.tcopy(),
			.kind = m.kind, .has_opt = m.has_opt, .opt = m.opt, .extension = m.extension });
	}
	for (usz i = 0; i < self.returned.len; i++) out.push(self.returned.items[i]);
	return out;
}

// ---------------------------------------------------------------------------
// Encoding and rendering

fn int hex_digit(char c)
{
	switch (c)
	{
		case '0'..'9': return c - '0';
		case 'a'..'f': return c - 'a' + 10;
		case 'A'..'F': return c - 'A' + 10;
		default: return -1;
	}
}

<* README "Encoding": %XX -> byte. *>
fn String unpct(String s)
{
	DString out = dstring::temp();
	for (usz i = 0; i < s.len; i++)
	{
		if (s[i] == '%' && i + 2 < s.len + 0 && hex_digit(s[i + 1]) >= 0 && hex_digit(s[i + 2]) >= 0)
		{
			out.append_char((char)(hex_digit(s[i + 1]) * 16 + hex_digit(s[i + 2])));
			i += 2;
		}
		else
		{
			out.append_char(s[i]);
		}
	}
	return out.str_view();
}

fn String pct(String s)
{
	DString out = dstring::temp();
	foreach (b : s)
	{
		if (b >= 0x21 && b <= 0x7E && b != '%' && b != '|')
		{
			out.append_char(b);
		}
		else
		{
			out.appendf("%%%02X", b);
		}
	}
	return out.str_view();
}

fn String hex_bytes(char[] s)
{
	if (s.len == 0) return "-";
	DString out = dstring::temp();
	foreach (b : s) out.appendf("%02x", b);
	return out.str_view();
}

fn String hex_signed(long v)
{
	if (v < 0) return string::tformat("-0x%x", (ulong)-(int128)v);
	return string::tformat("0x%x", v);
}

fn String type_name(Compilation* comp, QualType qt)
{
	Type t = qt.get_type(comp);
	switch (t.tag)
	{
		case COMPLEX: return string::tformat("complex_%s", type_name(comp, t.complex));
		case BIT_INT: return string::tformat("bitint_%s%d", t.bit_int.signedness == SIGNED ? "s" : "u", t.bit_int.bits);
		case ARRAY: return string::tformat("%s[%d]", type_name(comp, t.array.elem), t.array.len.len);
		default: break;
	}
	QualType[*] qts = {
		type_store::CHAR, type_store::SCHAR, type_store::UCHAR, type_store::SHORT, type_store::USHORT,
		type_store::INT, type_store::UINT, type_store::LONG, type_store::ULONG, type_store::LONG_LONG,
		type_store::ULONG_LONG, type_store::INT128, type_store::UINT128, type_store::INT24, type_store::UINT24,
		type_store::BF16, type_store::FLOAT16, type_store::FLOAT, type_store::DOUBLE, type_store::LONG_DOUBLE,
		type_store::FLOAT128, type_store::FLOAT32, type_store::FLOAT64, type_store::FLOAT32X, type_store::FLOAT64X,
		type_store::DFLOAT32, type_store::DFLOAT64, type_store::DFLOAT128, type_store::DFLOAT64X,
	};
	String[*] names = {
		"char", "schar", "uchar", "short", "ushort", "int", "uint", "long", "ulong", "long_long",
		"ulong_long", "int128", "uint128", "int24", "uint24",
		"bf16", "float16", "float", "double", "long_double",
		"float128", "float32", "float64", "float32x", "float64x",
		"dfloat32", "dfloat64", "dfloat128", "dfloat64x",
	};
	foreach (i, q : qts)
	{
		if (q == qt) return names[i];
	}
	return string::tformat("<type %s>", t.tag);
}

<* AST-dump spelling of a string element type (fixture_ast `[N]elem`). *>
fn String ast_elem_name(String n)
{
	switch (n)
	{
		case "uchar": return "unsigned char";
		case "ushort": return "unsigned short";
		case "uint": return "unsigned int";
		default: return n;
	}
}

fn String width_name(KeyFloatTag t)
{
	switch (t)
	{
		case F16: return "f16";
		case F32: return "f32";
		case F64: return "f64";
		case F80: return "f80";
		case F128: return "f128";
	}
}

fn String float_bits(KeyFloat f)
{
	switch (f.tag)
	{
		case F16: return string::tformat("%04x", f.raw());
		case F32: return string::tformat("%08x", f.raw());
		case F64: return string::tformat("%016x", f.raw());
		case F80: return string::tformat("%020x", f.raw());
		case F128: return string::tformat("%032x", f.raw());
	}
}

fn String show_value(Compilation* comp, Value v)
{
	if (v.is_none()) return "none";
	InternerKey key = comp.interner.get(v.ref());
	switch (key.tag)
	{
		case INT:
			BigIntSpace space;
			BigIntConst big = key.to_big_int(&space);
			String hex = big.to_string_alloc(tmem, 16, false);
			if (!big.positive) return string::tformat("-0x%s", hex[1..]);
			return string::tformat("0x%s", hex);
		case FLOAT:
			return string::tformat("%s:0x%s", width_name(key.float_val.tag), float_bits(key.float_val));
		case COMPLEX:
			KeyFloatTag t = key.complex_val.tag.scalar();
			KeyFloat re = float_value::to_float(v, t, comp);
			KeyFloat im = float_value::imag(v, t, comp);
			return string::tformat("c%s:0x%s:0x%s", width_name(t), float_bits(re), float_bits(im));
		default:
			return string::tformat("<key %s>", key.tag);
	}
}

fn String printed(Compilation* comp, Value v, QualType qt)
{
	DString w = dstring::temp();
	bool nested = v.print(qt, comp, w);
	assert(!nested);
	return w.str_view();
}

fn String kind_name(TextLiteralKind k)
{
	switch (k)
	{
		case CHAR: return "char";
		case WIDE: return "wide";
		case UTF_8: return "utf_8";
		case UTF_16: return "utf_16";
		case UTF_32: return "utf_32";
		case UNTERMINATED: return "unterminated";
	}
}

fn TextLiteralKind? kind_from_name(String s)
{
	foreach (k : TextLiteralKind::values)
	{
		if (kind_name(k) == s) return k;
	}
	return value::NO_INT~;
}

fn String prefix_name(Prefix p)
{
	switch (p)
	{
		case BINARY: return "binary";
		case OCTAL: return "octal";
		case DECIMAL: return "decimal";
		case HEX: return "hex";
	}
}

<* Zig spelling of a Suffix tag (`None`, `ULL`, `IF32x`, `D64x`). *>
fn String suffix_name(Suffix s)
{
	if (s == NONE) return "None";
	String n = string::tformat("%s", s);
	if (n.ends_with("X")) return string::tformat("%sx", n[:n.len - 1]);
	return n;
}

fn Suffix? suffix_from_name(String s)
{
	foreach (x : Suffix::values)
	{
		if (suffix_name(x) == s) return x;
	}
	return value::NO_INT~;
}

<* Token id from the spelling (README "Token ids", the probe's TokId.of). *>
fn TokenId token_id(String tok)
{
	usz plen = 0;
	char k = 'c';
	if (tok.starts_with("u8"))
	{
		plen = 2;
		k = '8';
	}
	else if (tok[0] == 'u' || tok[0] == 'U' || tok[0] == 'L')
	{
		plen = 1;
		k = tok[0];
	}
	char q = tok[plen];
	String body = tok[plen + 1..];
	bool terminated = false;
	for (usz i = 0; i < body.len; i++)
	{
		if (body[i] == '\\')
		{
			i++;
			continue;
		}
		if (body[i] == q)
		{
			terminated = i == body.len - 1;
			break;
		}
	}
	if (q == '"')
	{
		if (!terminated) return UNTERMINATED_STRING_LITERAL;
		switch (k)
		{
			case '8': return STRING_LITERAL_UTF_8;
			case 'u': return STRING_LITERAL_UTF_16;
			case 'U': return STRING_LITERAL_UTF_32;
			case 'L': return STRING_LITERAL_WIDE;
			default: return STRING_LITERAL;
		}
	}
	if (!terminated) return UNTERMINATED_CHAR_LITERAL;
	if (body.len == 1) return EMPTY_CHAR_LITERAL;
	switch (k)
	{
		case '8': return CHAR_LITERAL_UTF_8;
		case 'u': return CHAR_LITERAL_UTF_16;
		case 'U': return CHAR_LITERAL_UTF_32;
		case 'L': return CHAR_LITERAL_WIDE;
		default: return CHAR_LITERAL;
	}
}

// ---------------------------------------------------------------------------
// Ops. Each returns the result text; `values` (when not null) receives the
// expression type and value for the fixture ops.

struct Typed
{
	bool ok;
	QualType qt;
	Value val;
}

<* number: parse + number_value. *>
fn String op_number(Ctx* c, String lit, Typed* typed = null)
{
	Location loc = c.add_token(lit);
	NumberLiteralParser p = { .comp = &c.comp, .literal = lit, .loc = loc };
	NumberLiteralResult? parsed = p.parse();
	if (catch f = parsed)
	{
		assert(f == text_literal::PARSING_FAILED);
		return "fail";
	}
	NumberValue v = number_value::number_value(&c.comp, parsed);
	foreach (d : v.diags.slice()) c.add_returned(0, d.template());
	if (typed) *typed = { true, v.qt, v.val };
	Compilation* comp = &c.comp;
	return string::tformat("%s %s %s %s %s %s %s", prefix_name(parsed.prefix), suffix_name(parsed.suffix), pct(parsed.bytes),
		type_name(comp, v.qt), show_value(comp, v.val), type_name(comp, v.literal_qt), show_value(comp, v.literal_val));
}

fn String op_pp_number(Ctx* c, String lit)
{
	Location loc = c.add_token(lit);
	NumberLiteralParser p = { .comp = &c.comp, .literal = lit, .loc = loc };
	NumberLiteralResult? parsed = p.parse();
	if (catch f = parsed) return "fail";
	PpNumberValue v = number_value::pp_int_value(parsed);
	foreach (d : v.diags.slice()) c.add_returned(0, d.template());
	if (v.rejected) return "rejected";
	if (v.is_signed) return string::tformat("signed %s", hex_signed(v.signed));
	return string::tformat("unsigned 0x%x", v.unsigned);
}

fn String op_pp_char(Ctx* c, String tok)
{
	Location loc = c.add_token(tok);
	PpCharValue v = text_literal_semantics::pp_char_value(&c.comp, token_id(tok), tok, loc, {})!!;
	if (v.is_signed) return string::tformat("signed %s", hex_signed(v.signed));
	return string::tformat("unsigned 0x%x", v.unsigned);
}

<*
 char: Parser.charLiteral. The vector's signed/unsigned is the decoder's
 CharLiteralValue; char_literal (the public API) is run as well, with its
 diagnostics ignored, and must produce the same type and value.
*>
fn String op_char(Ctx* c, String tok, Typed* typed = null)
{
	Compilation* comp = &c.comp;
	Location loc = c.add_token(tok);
	TokenId id = token_id(tok);
	if (id == EMPTY_CHAR_LITERAL || id == UNTERMINATED_CHAR_LITERAL)
	{
		CharLiteral r = text_literal_semantics::char_literal(comp, id, tok, loc, {})!!;
		assert(r.has_diag);
		c.add_returned(0, r.diag.template());
		if (typed) *typed = { true, r.qt, r.val };
		return string::tformat("char %s unsigned 0x0", type_name(comp, r.qt));
	}
	TextLiteralKind kind = text_literal::classify(id, CHAR_LITERAL)!!;
	TextLiteralParser p = text_literal::text_parser(comp, kind.content_slice(tok), kind, kind.max_codepoint(comp), loc, {});
	CharLiteralValue r = p.parse()!!;
	QualType qt = kind.char_literal_type(comp);

	// Public API, diagnostics ignored.
	Diagnostics ignore;
	ignore.init_ignore();
	Diagnostics* saved = comp.diagnostics;
	comp.diagnostics = &ignore;
	CharLiteral api = text_literal_semantics::char_literal(comp, id, tok, loc, {})!!;
	comp.diagnostics = saved;
	ignore.free();
	assert(api.qt == qt && api.kind == kind && !api.has_diag);
	long want = r.is_signed ? (long)r.signed : (long)r.unsigned;
	assert(api.val.to_i64(comp)!! == want, "char_literal value differs from the decoder for %s", tok);
	if (typed) *typed = { true, api.qt, api.val };

	String v = r.is_signed ? string::tformat("signed %s", hex_signed(r.signed)) : string::tformat("unsigned 0x%x", r.unsigned);
	return string::tformat("%s %s %s", kind_name(kind), type_name(comp, qt), v);
}

fn String op_string(Ctx* c, String[] toks, Typed* typed = null)
{
	Compilation* comp = &c.comp;
	StringPiece[8] pieces;
	TokenId[8] ids;
	foreach (i, t : toks)
	{
		Location loc = c.add_token(t);
		ids[i] = token_id(t);
		pieces[i] = { .id = ids[i], .bytes = t, .loc = loc };
	}
	sz idx = -1;
	StringRun? run = text_literal_semantics::string_run(ids[:toks.len], &idx);
	if (catch f = run)
	{
		if (f == text_literal::CANNOT_CONCAT)
		{
			c.add_returned((uint)idx, TextSemanticsDiag.UNSUPPORTED_STR_CAT.template());
			return string::tformat("cannot_concat %d", idx);
		}
		assert(f == text_literal::PARSING_FAILED);
		return string::tformat("unterminated %d", idx);
	}
	assert(run.len == toks.len);
	StringLiteral? s = text_literal_semantics::string_literal(comp, pieces[:toks.len], run.kind);
	if (catch f = s)
	{
		assert(f == text_literal::PARSING_FAILED);
		return "fail";
	}
	if (typed) *typed = { true, s.qt, s.val };
	return string::tformat("%s %d %s %s", kind_name(s.kind), s.char_width.size, type_name(comp, s.qt), hex_bytes(s.val.to_bytes(comp)));
}

<* Preprocessor.unescapeUcn's decoding loop (Zig: UTF_8 kind, max 0x10FFFF, no encoding diagnostics). *>
fn String op_ucn_ident(Ctx* c, String ident)
{
	Location loc = c.add_token(ident);
	TextLiteralParser p = text_literal::text_parser(&c.comp, ident, UTF_8, 0x10FFFF, loc, {});
	p.diagnose_incorrect_encoding = false;
	DString out = dstring::temp();
	TextLiteralItem item;
	while (p.next(&item)!!)
	{
		switch (item.tag)
		{
			case VALUE: unreachable("validated by tokenizer");
			case CODEPOINT:
				char[4] enc;
				usz n = 0;
				uint cp = item.value;
				if (cp < 0x80)
				{
					enc[0] = (char)cp;
					n = 1;
				}
				else if (cp < 0x800)
				{
					enc[0] = (char)(0xC0 | (cp >> 6));
					enc[1] = (char)(0x80 | (cp & 0x3F));
					n = 2;
				}
				else if (cp < 0x10000)
				{
					enc[0] = (char)(0xE0 | (cp >> 12));
					enc[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
					enc[2] = (char)(0x80 | (cp & 0x3F));
					n = 3;
				}
				else
				{
					enc[0] = (char)(0xF0 | (cp >> 18));
					enc[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
					enc[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
					enc[3] = (char)(0x80 | (cp & 0x3F));
					n = 4;
				}
				out.append_bytes(enc[:n]);
			case IMPROPERLY_ENCODED:
			case UTF8_TEXT:
				out.append_bytes(item.bytes);
		}
	}
	return hex_bytes(out.str_view());
}

fn String op_kind_info(Ctx* c, String kind_text)
{
	Compilation* comp = &c.comp;
	TextLiteralKind k = kind_from_name(kind_text)!!;
	return string::tformat("0x%x 0x%x %s %s %d %d 0x%x", k.max_codepoint(comp), k.max_int(comp),
		type_name(comp, k.char_literal_type(comp)), type_name(comp, k.element_type(comp)),
		k.char_unit_size(comp).size, k.internal_storage_alignment(comp), comp.wchar_max());
}

fn String op_target_info(Ctx* c)
{
	Compilation* comp = &c.comp;
	String f80 = "none";
	if (try t = comp.float80_type()) f80 = type_name(comp, t);
	return string::tformat("%s %s %s %s %s %d %d %d %d %d %d %s",
		type_store::char_signedness(comp) == SIGNED ? "schar" : "uchar",
		type_name(comp, comp.type_store.wchar), type_name(comp, comp.type_store.intmax),
		type_name(comp, comp.type_store.uint_least16_t), type_name(comp, comp.type_store.uint_least32_t),
		type_store::INT.bit_sizeof(comp), type_store::LONG.bit_sizeof(comp), type_store::LONG_LONG.bit_sizeof(comp),
		type_store::DOUBLE.bit_sizeof(comp), type_store::LONG_DOUBLE.bit_sizeof(comp),
		comp.target.has_int128() ? 1 : 0, f80);
}

fn String bit(bool b) => b ? "1" : "0";

<*
 Run `op` on `inputs` (config first for config ops). Returns the result text
 or null-ish "" with *bad set for a malformed line.
*>
fn String? run_op(Ctx* c, Allocator a, String op, String[] inputs, bool* has_ctx, Typed* typed = null)
{
	switch (op)
	{
		case "prefix":
			Prefix p = number_literal::prefix_from_string(unpct(inputs[1]), inputs[0] == "1");
			return string::tformat("%s %d", prefix_name(p), p.string_len(unpct(inputs[1])));
		case "suffix":
			String buf = inputs[2] == "-" ? "" : unpct(inputs[2]);
			Suffix? s = number_literal::suffix_from_string(buf, inputs[0] == "float" ? FLOAT : INT, inputs[1] == "1");
			if (catch s) return "invalid";
			return suffix_name(s);
		case "suffix_props":
			Suffix s = suffix_from_name(inputs[0])!;
			String signed = s.is_float_only() ? "-" : bit(s.is_signed_integer());
			return string::tformat("%s %s %s %s %s", bit(s.is_imaginary()), signed, bit(s.is_bit_int()), bit(s.is_float80()), bit(s.is_msvc_extension()));
		case "concat":
			TextLiteralKind a1 = kind_from_name(inputs[0])!;
			TextLiteralKind b1 = kind_from_name(inputs[1])!;
			TextLiteralKind? r = a1.concat(b1);
			if (catch r) return "cannot_concat";
			return kind_name(r);
		default:
			break;
	}
	if (!c.init(a, inputs[0])!) return value::NO_INT~;
	*has_ctx = true;
	switch (op)
	{
		case "number": return op_number(c, unpct(inputs[1]), typed);
		case "pp_number": return op_pp_number(c, unpct(inputs[1]));
		case "pp_char": return op_pp_char(c, unpct(inputs[1]));
		case "char": return op_char(c, unpct(inputs[1]), typed);
		case "string":
			long n = inputs[1].to_long()!;
			if (n != inputs.len - 2 || n > 8) return value::NO_INT~;
			String[8] toks;
			foreach (i, t : inputs[2..]) toks[i] = unpct(t);
			return op_string(c, toks[:n], typed);
		case "ucn_ident": return op_ucn_ident(c, unpct(inputs[1]));
		case "kind_info": return op_kind_info(c, inputs[1]);
		case "target_info": return op_target_info(c);
		default: return value::NO_INT~;
	}
}

// ---------------------------------------------------------------------------
// Vector runner

<* A `f<N>:<bits>` field that Zig interns as the static int zero / one, or "". *>
fn String static_ref_of(String field)
{
	switch (field)
	{
		case "f16:0x0000":
		case "f32:0x00000000":
		case "f64:0x0000000000000000":
		case "f80:0x00000000000000000000":
		case "f128:0x00000000000000000000000000000000":
			return "0x0";
		case "f16:0x3c00":
		case "f32:0x3f800000":
		case "f64:0x3ff0000000000000":
		case "f80:0x3fff8000000000000000":
		case "f128:0x3fff0000000000000000000000000000":
			return "0x1";
		default:
			return "";
	}
}

struct VectorRun
{
	String file;
	usz line_no;
	usz vectors;
	usz failures;
	usz dblround;
	usz unreachable_hit;
	ulong unreachable_mask;
	usz fixture_vectors;
	usz static_ref;
	usz imag_float_node;
	String comment; // preceding `# zig-unreachable:` comment, or ""
}

fn void VectorRun.fail(&self, String line, String msg)
{
	self.failures++;
	if (self.failures <= MAX_REPORTED) io::eprintfn("%s:%d: %s\n    %s", self.file, self.line_no, msg, line);
}

struct ExpectedDiag
{
	uint tok;
	uint offset;
	String text;
}

fn ExpectedDiag[]? parse_diags(String[] segs)
{
	ExpectedDiag[] out = mem::temp_array(ExpectedDiag, segs.len);
	foreach (i, seg : segs)
	{
		String[3] buf;
		String[] f = seg.split_to_buffer(" ", buf[..], 3)!;
		if (f.len < 3) return value::NO_INT~;
		String[2] pbuf;
		String[] pos = f[1].split_to_buffer(":", pbuf[..])!;
		if (pos.len != 2) return value::NO_INT~;
		out[i] = { (uint)pos[0].to_long()!, (uint)pos[1].to_long()!, unpct(f[2]) };
	}
	return out;
}

fn String render_expected(Ctx* c, ExpectedDiag[] ds)
{
	DString s = dstring::temp();
	foreach (d : ds) s.appendf(" | %d:%d %s", d.tok, c.col(d.tok, d.offset), d.text);
	return s.str_view();
}

fn int unreachable_index(String entry)
{
	foreach (i, k : UNREACHABLE_RESULTS) if (k == entry) return (int)i;
	return -1;
}

fn void VectorRun.run_line(&self, Allocator a, String line)
{
	String[] segs = line.tsplit(" | ");
	String[] f = segs[0].tsplit(" ");
	sz eq = -1;
	foreach (i, x : f)
	{
		if (x == "=")
		{
			eq = i;
			break;
		}
	}
	if (eq < 1 || f.len < eq + 2)
	{
		self.fail(line, "malformed vector line");
		return;
	}
	self.vectors++;
	String op = f[0];
	String prov = f[^1];
	String[] results = f[eq + 1:f.len - eq - 2];
	if (prov == "zig-0.17.0-port-dblround") self.dblround++;
	if (op.starts_with("fixture_"))
	{
		self.fixture_vectors++;
		self.run_fixture(a, line, f, eq, segs);
		return;
	}
	String[] inputs = f[1:eq - 1];
	ExpectedDiag[]? want_diags = parse_diags(segs[1..]);
	if (catch want_diags)
	{
		self.fail(line, "malformed diagnostics");
		return;
	}

	Ctx c;
	bool has_ctx;
	String? got = run_op(&c, a, op, inputs, &has_ctx);
	defer if (has_ctx) c.free();
	if (catch got)
	{
		self.fail(line, "malformed vector or unknown configuration");
		return;
	}
	DiagList produced = has_ctx ? c.produced() : {};
	String got_diags = produced.render();
	String want_diag_text = has_ctx ? render_expected(&c, want_diags) : "";
	if (!has_ctx && want_diags.len)
	{
		self.fail(line, "diagnostics on a config-free op");
		return;
	}

	String want = string::join(tmem, results, " ");
	if (op == "number" && results.len == 7)
	{
		// See the file header: STATIC_REF and IMAG_FLOAT_NODE.
		String[7] norm;
		bool changed_static = false;
		foreach (i, r : results)
		{
			norm[i] = r;
			if (i == 4 || i == 6)
			{
				String z = static_ref_of(r);
				if (z.len)
				{
					norm[i] = z;
					changed_static = true;
				}
			}
		}
		bool imag_float = results[3].starts_with("complex_") && is_float_type(results[5]);
		if (imag_float) norm[6] = "none";
		String normalised = string::join(tmem, norm[:7], " ");
		if (normalised != want)
		{
			if (changed_static) self.static_ref++;
			if (imag_float) self.imag_float_node++;
			want = normalised;
		}
	}
	if (want == "unreachable")
	{
		// Reference panic: the port must give the listed diagnostics first.
		if (!got_diags.starts_with(want_diag_text))
		{
			self.fail(line, string::tformat("unreachable vector: diagnostics%s do not start with%s", got_diags, want_diag_text));
			return;
		}
		// op and input without the configuration (string: without the count)
		String input = op == "string" ? string::join(tmem, inputs[2..], " ") : string::join(tmem, inputs[1..], " ");
		String entry = string::tformat("%s %s => %s%s", op, input, got, got_diags);
		int at = unreachable_index(entry);
		if (at < 0)
		{
			self.fail(line, string::tformat("reference panic with an unpinned port result: %s", entry));
			return;
		}
		self.unreachable_hit++;
		self.unreachable_mask |= (ulong)1 << at;
		return;
	}
	if (got != want)
	{
		self.fail(line, string::tformat("result: got '%s', want '%s'", got, want));
		return;
	}
	if (got_diags != want_diag_text)
	{
		self.fail(line, string::tformat("diagnostics: got '%s', want '%s'", got_diags, want_diag_text));
	}
}

fn bool is_float_type(String n)
{
	switch (n)
	{
		case "bf16": case "float16": case "float": case "double": case "long_double": case "float128":
		case "float32": case "float64": case "float32x": case "float64x":
			return true;
		default:
			return false;
	}
}

<* Parse `[-]0x<hex>` into an int128. *>
fn int128? parse_hex(String s)
{
	bool neg = s.starts_with("-");
	String d = neg ? s[1..] : s;
	if (!d.starts_with("0x")) return value::NO_INT~;
	int128 v = 0;
	foreach (ch : d[2..])
	{
		int x = hex_digit(ch);
		if (x < 0) return value::NO_INT~;
		v = v * 16 + x;
	}
	return neg ? -v : v;
}

<*
 fixture_diag  case line:col config op input... = tok:offset kind fixture | message
 fixture_type  case line config op literal = type fixture
 fixture_eq    case line config op literal = int fixture
 fixture_ast   case config op input... = type value fixture-ast
*>
fn void VectorRun.run_fixture(&self, Allocator a, String line, String[] f, sz eq, String[] segs)
{
	String kind = f[0];
	sz cfg_at = kind == "fixture_ast" ? 2 : 3;
	if (eq <= cfg_at + 2)
	{
		self.fail(line, "malformed fixture line");
		return;
	}
	String op = f[cfg_at + 1];
	String[] inputs = mem::temp_array(String, (usz)(eq - cfg_at - 1));
	inputs[0] = f[cfg_at];
	foreach (i, x : f[cfg_at + 2:eq - cfg_at - 2]) inputs[i + 1] = x;

	Ctx c;
	bool has_ctx;
	Typed typed;
	String? got = run_op(&c, a, op, inputs, &has_ctx, &typed);
	defer if (has_ctx) c.free();
	if (catch got)
	{
		self.fail(line, "malformed fixture vector or unknown configuration");
		return;
	}
	Compilation* comp = &c.comp;
	switch (kind)
	{
		case "fixture_diag":
			if (segs.len != 2)
			{
				self.fail(line, "fixture_diag needs one message");
				return;
			}
			String[2] pbuf;
			String[]? pos = f[eq + 1].split_to_buffer(":", pbuf[..]);
			if (catch pos) return self.fail(line, "bad tok:offset");
			uint tok = (uint)pos[0].to_long()!!;
			uint col = c.col(tok, (uint)pos[1].to_long()!!);
			String message = unpct(segs[1]);
			String text = message;
			String flag = "";
			if (try at = message.index_of(" [-W"))
			{
				if (message.ends_with("]"))
				{
					text = message[:at];
					flag = message[at + 4:message.len - at - 5];
				}
			}
			DiagList produced = c.produced();
			for (usz i = 0; i < produced.len; i++)
			{
				Diag* d = &produced.items[i];
				if (d.tok != tok || d.col != col || d.text != text) continue;
				if (f[eq + 2] == "error" && d.kind != ERROR && d.kind != WARNING && d.kind != OFF)
				{
					return self.fail(line, "kind mismatch");
				}
				if (d.kind == ERROR && f[eq + 2] != "error") return self.fail(line, "an error template shown as a warning");
				if (flag.len)
				{
					if (flag.starts_with("Werror,")) flag = flag[7..];
					bool flag_ok = (d.has_opt && d.opt.flag == flag) || (flag == "pedantic" && d.extension && !d.has_opt);
					if (!flag_ok) return self.fail(line, string::tformat("option [-W%s] does not match the template", flag));
				}
				return;
			}
			self.fail(line, string::tformat("message not produced; got%s", produced.render()));
		case "fixture_type":
			if (!typed.ok) return self.fail(line, string::tformat("no typed result (%s)", got));
			String tn = type_name(comp, typed.qt);
			if (tn != f[eq + 1]) self.fail(line, string::tformat("type: got %s", tn));
		case "fixture_eq":
			if (!typed.ok) return self.fail(line, string::tformat("no typed result (%s)", got));
			int128 want = parse_hex(f[eq + 1])!!;
			InternerKey key = comp.interner.get(typed.val.ref());
			if (key.tag != INT) return self.fail(line, "not an integer value");
			int128 have = parse_hex(show_value(comp, typed.val))!!;
			if (have == want) return;
			// usual arithmetic conversions: a negative N against an unsigned literal
			ulong bits = typed.qt.bit_sizeof(comp);
			if (want < 0 && typed.qt.signedness(comp) == UNSIGNED && bits < 127 && have == want + ((int128)1 << bits)) return;
			self.fail(line, string::tformat("value: got %s", show_value(comp, typed.val)));
		case "fixture_ast":
			if (!typed.ok) return self.fail(line, string::tformat("no typed result (%s)", got));
			String tn = type_name(comp, typed.qt);
			Type t = typed.qt.get_type(comp);
			if (t.tag == ARRAY) tn = string::tformat("[%d]%s", t.array.len.len, ast_elem_name(type_name(comp, t.array.elem)));
			String pv = printed(comp, typed.val, typed.qt);
			String want_v = unpct(f[eq + 2]);
			if (tn != f[eq + 1] || pv != want_v) self.fail(line, string::tformat("ast: got %s %s", tn, pv));
		default:
			self.fail(line, "unknown fixture op");
	}
}

struct FileTotals
{
	usz vectors;
	usz dblround;
	usz unreachable_hit;
	ulong unreachable_mask;
	usz fixture_vectors;
	usz static_ref;
	usz imag_float_node;
	usz failures;
}

fn String vectors_dir()
{
	if (try d = env::get_var(tmem, "LITERAL_VECTORS_DIR")) return d;
	return "test/c3/data/literals";
}

fn FileTotals run_file(String name)
{
	FileTotals totals;
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		String path = string::format(mem, "%s/%s", vectors_dir(), name);
		defer free(path);
		char[] data = file::load(mem, path)!!;
		defer free(data);

		VectorRun run = { .file = name, .comment = "" };
		long end_count = -1;
		String text = (String)data;
		usz start = 0;
		while (start < text.len)
		{
			usz end = start;
			while (end < text.len && text[end] != '\n') end++;
			String line = text[start:end - start];
			start = end + 1;
			run.line_no++;
			if (line.len == 0) continue;
			if (line[0] == '#')
			{
				if (line.starts_with("# end: "))
				{
					String[2] buf;
					String[] parts = line[7..].split_to_buffer(" ", buf[..], 2)!!;
					end_count = parts[0].to_long()!!;
				}
				continue;
			}
			@pool()
			{
				run.run_line(&ta, line);
			};
		}
		io::printfn("%s: %d vectors (%d fixture, %d dblround, %d known reference panics, %d STATIC_REF, %d IMAG_FLOAT_NODE), %d failures (end marker %d)",
			name, run.vectors, run.fixture_vectors, run.dblround, run.unreachable_hit, run.static_ref, run.imag_float_node, run.failures, end_count);
		if (run.failures > MAX_REPORTED) io::eprintfn("%s: %d further failures not shown", name, run.failures - MAX_REPORTED);
		assert(end_count >= 0, "%s: missing '# end: N vectors' line", name);
		assert(run.vectors == (usz)end_count, "%s: read %d vectors, end marker says %d", name, run.vectors, end_count);
		totals = { run.vectors, run.dblround, run.unreachable_hit, run.unreachable_mask, run.fixture_vectors, run.static_ref, run.imag_float_node, run.failures };
	}
	assert(ta.allocation_count() == 0, "%s: leaked %d allocations", name, ta.allocation_count());
	return totals;
}

<* target_info first (kinds.txt), so target-table differences surface before literal ones. *>
const String[] FILES = {
	"kinds.txt", "suffix.txt", "number.txt", "pp.txt", "char.txt", "string.txt", "fixtures.txt",
};

fn void all_literal_vectors() @test
{
	FileTotals sum;
	foreach (name : FILES)
	{
		FileTotals t = run_file(name);
		sum.vectors += t.vectors;
		sum.dblround += t.dblround;
		sum.unreachable_hit += t.unreachable_hit;
		sum.unreachable_mask |= t.unreachable_mask;
		sum.fixture_vectors += t.fixture_vectors;
		sum.static_ref += t.static_ref;
		sum.imag_float_node += t.imag_float_node;
		sum.failures += t.failures;
	}
	io::printfn("total: %d vectors, %d fixture-derived, %d dblround, %d STATIC_REF, %d IMAG_FLOAT_NODE, %d failures",
		sum.vectors, sum.fixture_vectors, sum.dblround, sum.static_ref, sum.imag_float_node, sum.failures);
	assert(sum.failures == 0, "%d failing vectors", sum.failures);
	assert(sum.dblround == 29, "expected 29 dblround vectors, read %d", sum.dblround);
	assert(sum.fixture_vectors == 273, "expected 273 fixture vectors, read %d", sum.fixture_vectors);
	assert(sum.unreachable_hit == 29, "expected 29 reference-panic vectors, read %d", sum.unreachable_hit);
	assert(sum.unreachable_mask == ((ulong)1 << UNREACHABLE_RESULTS.len) - 1, "not every pinned reference-panic result was hit");
	assert(sum.static_ref == 397 && sum.imag_float_node == 99, "normalisation counts changed: %d STATIC_REF, %d IMAG_FLOAT_NODE", sum.static_ref, sum.imag_float_node);
}

// ---------------------------------------------------------------------------
// Explicit acceptance cases (plan 11): the rendered diagnostic line, exactly
// as the C3 Diagnostics prints it, for each acceptance category. Values are
// source-derived and agree with the vectors above.

<* Render all messages of `c` as `path:line:col: kind: text [-Wopt]` lines. *>
fn String rendered(Ctx* c)
{
	DString s = dstring::temp();
	foreach (&m : c.diags.messages)
	{
		Message copy = *m;
		copy.write({ .writer = &s, .mode = NO_COLOR }, false)!!;
	}
	return s.str_view();
}

macro @with_ctx(String cfg; @body(Ctx* c))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Ctx c;
		assert(c.init(&ta, cfg)!!);
		c.diags.state.enable_all_warnings = false; // the default visibility
		@body(&c);
		c.free();
	}
	assert(ta.allocation_count() == 0);
}

fn void acceptance_diagnostic_text() @test
{
	// Malformed suffixes ([fixture __float80 clang.c]).
	@with_ctx("x86_64-linux-gnu/default/clang"; Ctx* c)
	{
		test::eq(op_number(c, "1.0w"), "fail");
		test::eq(op_number(c, "2.0iw"), "fail");
		test::eq(rendered(c), "t0.c:1:1: error: invalid suffix 'w' on floating constant\nt1.c:1:1: error: invalid suffix 'iw' on floating constant\n");
	};
	// Overflowing integers: returned diagnostics, reported by the caller.
	@with_ctx("x86_64-linux-gnu/default/gcc"; Ctx* c)
	{
		test::eq(op_number(c, "18446744073709551616"), "decimal None 18446744073709551616 ulong_long 0x0 ulong_long 0x0");
		test::eq(c.returned.render(), " | 0:1 integer literal is too large to be represented in any integer type");
		test::eq(op_number(c, "18446744073709551615"), "decimal None 18446744073709551615 int128 0xffffffffffffffff int128 0xffffffffffffffff");
	};
	// f80 / f128 rounding of 0.1 (f128 parse, then one rounding).
	@with_ctx("x86_64-linux-gnu/default/gcc"; Ctx* c)
	{
		test::eq(op_number(c, "0.1L"), "decimal L 0.1 long_double f80:0x3ffbcccccccccccccccd long_double f80:0x3ffbcccccccccccccccd");
		test::eq(op_number(c, "0.1q"), "decimal Q 0.1 float128 f128:0x3ffb999999999999999999999999999a float128 f128:0x3ffb999999999999999999999999999a");
	};
	// Surrogate and UCN boundaries ([fixture strings.c] lines 4, 9).
	@with_ctx("x86_64-linux-gnu/default/no"; Ctx* c)
	{
		test::eq(op_string(c, { "\"\\U00110000\"" }), "char 1 char[1] 00");
		test::eq(op_string(c, { "\"\\uD800\"" }), "char 1 char[1] 00");
		test::eq(rendered(c), "t0.c:1:1: error: invalid universal character\nt1.c:1:1: error: invalid universal character\n");
	};
	// u"\U0001F917": string literals decode with max_codepoint 0x10FFFF -> surrogate pair.
	@with_ctx("x86_64-linux-gnu/default/gcc"; Ctx* c)
	{
		test::eq(op_string(c, { "u\"\\U0001F917\"" }), "utf_16 2 ushort[3] 3ed817dd0000");
		test::eq(rendered(c), "");
	};
	// Multichar constants ([fixture wide character constants.c] lines 9, 13 with -Wfour-char-constants).
	@with_ctx("x86_64-linux-gnu/default/gcc"; Ctx* c)
	{
		c.diags.set("four-char-constants", WARNING)!!;
		test::eq(op_char(c, "L'ab'"), "wide int unsigned 0x62");
		test::eq(op_char(c, "'\\1\\2\\3\\4'"), "char int unsigned 0x1020304");
		test::eq(rendered(c), "t0.c:1:1: error: wide character literals may not contain multiple characters\nt1.c:1:1: warning: multi-character character constant [-Wfour-char-constants]\n");
	};
	// Mixed encodings ([fixture wide strings.c] line 24, [fixture concat improperly encoded strings.c]).
	@with_ctx("x86_64-linux-gnu/c23/no"; Ctx* c)
	{
		test::eq(op_string(c, { "u\"a\"", "U\"b\"" }), "cannot_concat 1");
		test::eq(c.returned.render(), " | 1:1 unsupported string literal concatenation");
	};
	@with_ctx("x86_64-linux-gnu/default/no"; Ctx* c)
	{
		test::eq(op_string(c, { "L\"\"", "\"\xFF\"" }), "fail");
		test::eq(rendered(c), "t1.c:1:1: error: illegal character encoding in character literal\n");
	};
	// Value.print of a bytes value (printString hookup).
	@with_ctx("x86_64-linux-gnu/default/gcc"; Ctx* c)
	{
		Typed t;
		op_string(c, { "\"a\\n\"" }, &t);
		test::eq(printed(&c.comp, t.val, t.qt), "\"a\\n\"");
		op_string(c, { "U\"\\U0001F917\"" }, &t);
		test::eq(printed(&c.comp, t.val, t.qt), "\"\U0001F917\"");
	};
}
