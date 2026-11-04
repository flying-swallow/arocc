// Data-driven tests: every vector in test/c3/data/float_values/*.txt (format and
// provenance in that directory's README.md) is checked against the plan 10 port
// (float_value.c3, float_soft_*.c3, float_print.c3, annex_g.c3) through the
// public Value API where one exists (value.c3's add/sub/mul/div/float_cast/
// int_to_float/float_to_int/print/complex_conj, float_value::compare), and
// through the KeyFloat primitives otherwise (from_u64/from_i64, bigIntToFloat,
// parse_f128 + cast, ilogb/scalbn/max/f128_mul_add, format_f64_decimal).
//
// The vectors were produced by running Zig 0.17.0 on test/migration/float_probe.zig
// (a copy of Value.zig's float logic and annex_g.zig); they are not differential
// evidence against the pinned Zig 0.18.0-dev.
//
// Every computed result is rendered in the vector syntax and compared as text.
// `zig-0.17.0-libbug` vectors: the vector's main field holds the model value;
// the `# lib-bug: zig-0.17.0 gave ...` comment before it holds what Zig 0.17.0
// actually produced. Plan 10 matches current reference behaviour, so the
// OBSERVED value is expected here. Library defects the port does not reproduce
// are listed in KNOWN_DIFFERENCES (a vector line there may match the model value
// instead); every entry must still be hit, so the list cannot go stale.
// Each file's `# end: N vectors` count is asserted.
//
// Files are read relative to the working directory (the Bazel runfiles root), or
// from $FLOAT_VECTORS_DIR when set.
module float_vector_tests;
import aro::float_value, aro::annex_g, aro::lang_opts, aro::value, aro::value_interner, aro::bigint, aro::type_store, aro::target, aro::compilation;
import std::io, std::os::env, std::core::mem::allocators, std::core::dstring;

const Host HOST = { X86_64, LINUX, GNU };
const usz MAX_REPORTED = 30;

<*
 Vector lines (exact text) whose observed Zig 0.17.0 library defect the port
 does not reproduce; the port must produce the vector's (model) value instead.
*>
const String[] KNOWN_DIFFERENCES = {
	// compiler-rt __multf3 (Zig 0.17.0): largest subnormal * max is 1 ulp low; the port rounds correctly.
	"mul f128 0x8000ffffffffffffffffffffffffffff 0x7ffeffffffffffffffffffffffffffff = 0xc000fffffffffffffffffffffffffffd zig-0.17.0-libbug",
	"mul f128 0x8000ffffffffffffffffffffffffffff 0xfffeffffffffffffffffffffffffffff = 0x4000fffffffffffffffffffffffffffd zig-0.17.0-libbug",
	"mul f128 0x7ffeffffffffffffffffffffffffffff 0x8000ffffffffffffffffffffffffffff = 0xc000fffffffffffffffffffffffffffd zig-0.17.0-libbug",
	"mul f128 0xfffeffffffffffffffffffffffffffff 0x8000ffffffffffffffffffffffffffff = 0x4000fffffffffffffffffffffffffffd zig-0.17.0-libbug",
	// compiler-rt __truncxfhf2 (Zig 0.17.0): f16 subnormal results are wrong; the port rounds correctly.
	"cast f80 f16 0x3fe68080000000000000 = 0x0001 zig-0.17.0-libbug",
	"cast f80 f16 0x3fe7c000000000000000 = 0x0002 zig-0.17.0-libbug",
	"cast f80 f16 0xbfe7c000000000000000 = 0x8002 zig-0.17.0-libbug",
	"cast f80 f16 0x3fe7c040000000000000 = 0x0002 zig-0.17.0-libbug",
	"cast f80 f16 0x3fe8a000000000000000 = 0x0002 zig-0.17.0-libbug",
	"cast f80 f16 0xbfe8a000000000000000 = 0x8002 zig-0.17.0-libbug",
	"cast f80 f16 0x3fe8a020000000000000 = 0x0003 zig-0.17.0-libbug",
	"cast f80 f16 0x3fe89fe0000000000000 = 0x0002 zig-0.17.0-libbug",
	"cast f80 f16 0x3fe8e000000000000000 = 0x0004 zig-0.17.0-libbug",
	"cast f80 f16 0xbfe8e000000000000000 = 0x8004 zig-0.17.0-libbug",
	"cast f80 f16 0x3fe8e020000000000000 = 0x0004 zig-0.17.0-libbug",
	"cast f80 f16 0x3fedc900000000000000 = 0x0064 zig-0.17.0-libbug",
	"cast f80 f16 0xbfedc900000000000000 = 0x8064 zig-0.17.0-libbug",
	"cast f80 f16 0x3fedc901000000000000 = 0x0065 zig-0.17.0-libbug",
	"cast f80 f16 0x3fedc8ff000000000000 = 0x0064 zig-0.17.0-libbug",
	"cast f80 f16 0x3fedcb00000000000000 = 0x0066 zig-0.17.0-libbug",
	"cast f80 f16 0xbfedcb00000000000000 = 0x8066 zig-0.17.0-libbug",
	"cast f80 f16 0x3fedcb01000000000000 = 0x0066 zig-0.17.0-libbug",
	"cast f80 f16 0x3fedcaff000000000000 = 0x0065 zig-0.17.0-libbug",
	"cast f80 f16 0x3ff0ffe0000000000000 = 0x0400 zig-0.17.0-libbug",
	"cast f80 f16 0xbff0ffe0000000000000 = 0x8400 zig-0.17.0-libbug",
	"cast f80 f16 0x3ff0ffe0200000000000 = 0x0400 zig-0.17.0-libbug",
	"cast f80 f16 0x3ff0ffe0000000000000 = 0x0400 zig-0.17.0-libbug",
};

struct VectorRun
{
	Compilation* comp;
	String file;
	usz line_no;
	usz vectors;
	usz failures;
	usz libbug_vectors;
	usz libbug_observed;
	usz known_hit;
	<* Observed results from the preceding `# lib-bug:` comment ("" when none). *>
	String libbug;
}

fn String vectors_dir()
{
	if (try d = env::get_var(tmem, "FLOAT_VECTORS_DIR")) return d;
	return "test/c3/data/float_values";
}

fn void VectorRun.fail(&self, String line, String msg)
{
	self.failures++;
	if (self.failures <= MAX_REPORTED) io::eprintfn("%s:%d: %s\n    %s", self.file, self.line_no, msg, line);
}

// ---------------------------------------------------------------------------
// Field parsing and rendering
// ---------------------------------------------------------------------------

fn KeyFloatTag? parse_width(String s)
{
	switch (s)
	{
		case "f16": return F16;
		case "f32": return F32;
		case "f64": return F64;
		case "f80": return F80;
		case "f128": return F128;
		default: return value::NO_INT~;
	}
}

fn QualType real_type(KeyFloatTag t)
{
	switch (t)
	{
		case F16: return type_store::FLOAT16;
		case F32: return type_store::FLOAT;
		case F64: return type_store::DOUBLE;
		case F80: return type_store::LONG_DOUBLE;
		case F128: return type_store::FLOAT128;
	}
}

fn QualType complex_type(Compilation* comp, KeyFloatTag t) => comp.type_store.put(type_store::type_complex(real_type(t)));

fn uint128? parse_hex128(String s)
{
	if (!s.starts_with("0x") || s.len < 3 || s.len > 34) return value::NO_INT~;
	uint128 r = 0;
	foreach (c : s[2..])
	{
		uint128 d;
		switch
		{
			case c >= '0' && c <= '9': d = (uint128)(c - '0');
			case c >= 'a' && c <= 'f': d = (uint128)(c - 'a' + 10);
			default: return value::NO_INT~;
		}
		r = r << 4 | d;
	}
	return r;
}

fn KeyFloat? parse_float(KeyFloatTag t, String s) => float_value::from_raw(t, parse_hex128(s)!);

fn String show_float(KeyFloat f)
{
	switch (f.tag)
	{
		case F16: return string::tformat("0x%04x", f.raw());
		case F32: return string::tformat("0x%08x", f.raw());
		case F64: return string::tformat("0x%016x", f.raw());
		case F80: return string::tformat("0x%020x", f.raw());
		case F128: return string::tformat("0x%032x", f.raw());
	}
}

fn String show_big(BigIntConst big)
{
	String hex = big.to_string_alloc(tmem, 16, false);
	if (!big.positive) return string::tformat("-0x%s", hex[1..]);
	return string::tformat("0x%s", hex);
}

<* Parse `[-]0x<hex>` (any size) into a BigIntConst over temp memory. *>
fn BigIntConst? parse_big(String s)
{
	bool negative = s.starts_with("-");
	String digits = negative ? s[1..] : s;
	if (!digits.starts_with("0x") || digits.len < 3) return value::NO_INT~;
	digits = digits[2..];
	Limb[] limbs = mem::temp_array(Limb, (usz)bigint::calc_set_string_limb_count(16, digits.len));
	BigIntMutable m = { .limbs = limbs, .len = 1, .positive = true };
	m.set_string(16, digits, {})!;
	if (negative) m.positive = m.to_const().eql_zero();
	return m.to_const();
}

fn String show_value_int(Compilation* comp, Value v)
{
	if (v.is_none()) return "none";
	InternerKey key = comp.interner.get(v.ref());
	if (key.tag != INT) return string::tformat("<key tag %s>", key.tag);
	BigIntSpace space;
	return show_big(key.to_big_int(&space));
}

fn String change_kind_text(FloatToIntChangeKind k)
{
	switch (k)
	{
		case NONE: return "none";
		case OUT_OF_RANGE: return "out_of_range";
		case OVERFLOW: return "overflow";
		case NONZERO_TO_ZERO: return "nonzero_to_zero";
		case VALUE_CHANGED: return "value_changed";
	}
}

fn String show_class(KeyFloat f)
{
	String class;
	switch (f.classify())
	{
		case NAN: class = "nan";
		case INFINITE: class = "inf";
		case ZERO: class = "zero";
		case NORMAL: class = "normal";
		case SUBNORMAL: class = "subnormal";
	}
	return string::tformat("%s %s", class, f.signbit() ? "neg" : "pos");
}

fn Value fv(Compilation* comp, KeyFloat f) => value::intern(comp, value_interner::key_float(f));
fn Value cv(Compilation* comp, KeyFloat re, KeyFloat im) => value::intern(comp, value_interner::key_complex(float_value::make_complex(re, im)));

fn String show_complex_value(Compilation* comp, Value v, KeyFloatTag t)
{
	return string::tformat("%s %s", show_float(float_value::to_float(v, t, comp)), show_float(float_value::imag(v, t, comp)));
}

fn String print_value(Compilation* comp, Value v, QualType qt)
{
	DString w = dstring::temp();
	bool nested = v.print(qt, comp, w);
	assert(!nested);
	return string::tformat("\"%s\"", w.str_view());
}

fn bool is_known_difference(String line)
{
	foreach (k : KNOWN_DIFFERENCES)
	{
		if (k == line) return true;
	}
	return false;
}

// ---------------------------------------------------------------------------
// One vector
// ---------------------------------------------------------------------------

faultdef BAD_VECTOR;

<* Compute the result text of the vector with operand fields `f` (op first). *>
fn String? VectorRun.compute(&self, String[] f)
{
	Compilation* comp = self.comp;
	String op = f[0];
	switch (op)
	{
		case "add":
		case "sub":
		case "mul":
		case "div":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			Value lhs = fv(comp, parse_float(t, f[2])!);
			Value rhs = fv(comp, parse_float(t, f[3])!);
			Value res = value::NONE;
			bool o;
			switch (op)
			{
				case "add": o = res.add(lhs, rhs, real_type(t), comp);
				case "sub": o = res.sub(lhs, rhs, real_type(t), comp);
				case "mul": o = res.mul(lhs, rhs, real_type(t), comp);
				default: o = res.div(lhs, rhs, real_type(t), comp);
			}
			assert(!o);
			return show_float(res.to_float(t, comp));
		case "cast":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloatTag s = parse_width(f[1])!;
			KeyFloatTag d = parse_width(f[2])!;
			Value v = fv(comp, parse_float(s, f[3])!);
			v.float_cast(real_type(d), comp);
			return show_float(v.to_float(d, comp));
		case "from_u64":
		case "from_i64":
			if (f.len != 3) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			BigIntConst x = parse_big(f[2])!;
			if (op == "from_u64") return show_float(float_value::from_u64(x.to_u64()!, t));
			return show_float(float_value::from_i64(x.to_i64()!, t));
		case "big_to_f128":
			if (f.len != 2) return BAD_VECTOR~;
			return show_float(float_value::f128_value(float_value::big_int_to_f128(parse_big(f[1])!)));
		case "int_to_float":
			if (f.len != 3) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			Value v = value::intern_big(comp, parse_big(f[2])!);
			v.int_to_float(real_type(t), comp);
			return show_float(v.to_float(t, comp));
		case "float_to_int":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			QualType dest;
			if (f[2] == "bool")
			{
				dest = type_store::BOOL;
			}
			else
			{
				Signedness sign = f[2][0] == 's' ? SIGNED : UNSIGNED;
				dest = comp.type_store.put(type_store::type_bit_int((ushort)f[2][1..].to_int()!, sign));
			}
			Value v = fv(comp, parse_float(t, f[3])!);
			FloatToIntChangeKind kind = v.float_to_int(dest, comp);
			return string::tformat("%s %s", show_value_int(comp, v), change_kind_text(kind));
		case "compare":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			KeyFloat a = parse_float(t, f[2])!;
			KeyFloat b = parse_float(t, f[3])!;
			Value va = fv(comp, a);
			Value vb = fv(comp, b);
			bool via_value = va.is(FLOAT, comp) || vb.is(FLOAT, comp);
			DString w = dstring::temp();
			foreach (cop : (CompareOperator[]) { EQ, NEQ, LT, LTE, GT, GTE })
			{
				// float_value::compare is Value.compare's float branch (no shallowCompare).
				bool r;
				if (via_value)
				{
					r = float_value::compare(va, cop, vb, comp);
				}
				else
				{
					r = a.cast(F128).compare(cop, b.cast(F128)); // both interned as int 0/1
				}
				w.append_char(r ? '1' : '0');
			}
			return w.str_view();
		case "compare_complex":
			if (f.len != 6) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			Value l = cv(comp, parse_float(t, f[2])!, parse_float(t, f[3])!);
			Value r = cv(comp, parse_float(t, f[4])!, parse_float(t, f[5])!);
			return float_value::compare(l, NEQ, r, comp) ? "1" : "0";
		case "classify":
			if (f.len != 3) return BAD_VECTOR~;
			return show_class(parse_float(parse_width(f[1])!, f[2])!);
		case "format_f64":
			if (f.len != 2) return BAD_VECTOR~;
			DString w = dstring::temp();
			float_value::format_f64_decimal((ulong)parse_hex128(f[1])!, w);
			return string::tformat("\"%s\"", w.str_view());
		case "print":
			if (f.len != 3) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			return print_value(comp, fv(comp, parse_float(t, f[2])!), real_type(t));
		case "print_complex":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			return print_value(comp, cv(comp, parse_float(t, f[2])!, parse_float(t, f[3])!), complex_type(comp, t));
		case "parse":
			if (f.len != 3) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			F128Bits p = float_value::parse_f128(f[2])!;
			return show_float(float_value::f128_value(p).cast(t));
		case "cadd":
		case "csub":
		case "cmul":
		case "cdiv":
			if (f.len != 6) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			QualType ct = complex_type(comp, t);
			Value l = cv(comp, parse_float(t, f[2])!, parse_float(t, f[3])!);
			Value r = cv(comp, parse_float(t, f[4])!, parse_float(t, f[5])!);
			Value res = value::NONE;
			switch (op)
			{
				case "cadd": res.add(l, r, ct, comp);
				case "csub": res.sub(l, r, ct, comp);
				case "cmul": res.mul(l, r, ct, comp);
				default: res.div(l, r, ct, comp);
			}
			return show_complex_value(comp, res, t);
		case "conj":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			Value v = cv(comp, parse_float(t, f[2])!, parse_float(t, f[3])!);
			return show_complex_value(comp, value::complex_conj(v, complex_type(comp, t), comp), t);
		case "ilogb":
			if (f.len != 3) return BAD_VECTOR~;
			return string::tformat("%d", parse_float(parse_width(f[1])!, f[2])!.ilogb());
		case "scalbn":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloat a = parse_float(parse_width(f[1])!, f[2])!;
			return show_float(a.scalbn(f[3].to_int()!));
		case "fmax":
			if (f.len != 4) return BAD_VECTOR~;
			KeyFloatTag t = parse_width(f[1])!;
			return show_float(parse_float(t, f[2])!.max(parse_float(t, f[3])!));
		case "mul_add":
			if (f.len != 5) return BAD_VECTOR~;
			if (f[1] != "f128") return BAD_VECTOR~;
			KeyFloat a = parse_float(F128, f[2])!;
			KeyFloat b = parse_float(F128, f[3])!;
			KeyFloat c = parse_float(F128, f[4])!;
			return show_float(float_value::f128_value(float_value::f128_mul_add(a.f128, b.f128, c.f128)));
		default:
			return BAD_VECTOR~;
	}
}

fn void VectorRun.run_line(&self, String line)
{
	String libbug = self.libbug;
	self.libbug = "";
	self.vectors++;
	sz? eq = line.index_of(" = ");
	if (catch eq)
	{
		self.fail(line, "no ' = ' separator");
		return;
	}
	String rest = line[eq + 3..];
	sz? last_space = rest.rindex_of_char(' ');
	if (catch last_space)
	{
		self.fail(line, "no provenance field");
		return;
	}
	String want_model = rest[:last_space];
	String provenance = rest[last_space + 1..];

	String[8] buf;
	String[]? fields = line[:eq].split_to_buffer(" ", buf[..]);
	if (catch fields)
	{
		self.fail(line, "too many operand fields");
		return;
	}
	String? got_opt = self.compute(fields);
	if (catch got_opt)
	{
		self.fail(line, "cannot compute (bad vector or unknown op)");
		return;
	}
	String got = got_opt;

	String want = want_model;
	if (provenance == "zig-0.17.0-libbug")
	{
		if (libbug == "")
		{
			self.fail(line, "libbug vector without a '# lib-bug:' comment");
			return;
		}
		self.libbug_vectors++;
		want = libbug;
		if (got == libbug) self.libbug_observed++;
	}
	else if (libbug != "")
	{
		self.fail(line, "'# lib-bug:' comment before a non-libbug vector");
		return;
	}
	if (got == want) return;
	if (is_known_difference(line))
	{
		if (got == want_model)
		{
			self.known_hit++;
			return;
		}
		self.fail(line, string::tformat("known difference: got %s, want observed %s or model %s", got, want, want_model));
		return;
	}
	self.fail(line, string::tformat("got %s, want %s", got, want));
}

struct FileTotals
{
	usz libbug_vectors;
	usz libbug_observed;
	usz known_hit;
	usz failures;
}

<* Run every vector of `name`; asserts the end count; returns the totals (failures included). *>
fn FileTotals run_file(String name)
{
	FileTotals totals;
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		comp.target = target::parse_triple("x86_64-linux-gnu", HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);

		String path = string::format(mem, "%s/%s", vectors_dir(), name);
		defer free(path);
		char[] data = file::load(mem, path)!!;
		defer free(data);

		VectorRun run = { .comp = &comp, .file = name, .libbug = "" };
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
				else if (line.starts_with("# lib-bug: zig-0.17.0 gave "))
				{
					String observed = line["# lib-bug: zig-0.17.0 gave ".len..];
					sz? semi = observed.index_of(";");
					assert(@ok(semi), "%s:%d: malformed lib-bug comment", name, run.line_no);
					run.libbug = observed[:semi!!];
				}
				continue;
			}
			@pool()
			{
				run.run_line(line);
			};
		}
		comp.free();

		io::printfn("%s: %d vectors, %d failures, %d lib-bug vectors (%d match the observed Zig 0.17.0 output), %d known differences (end marker %d)",
			name, run.vectors, run.failures, run.libbug_vectors, run.libbug_observed, run.known_hit, end_count);
		if (run.failures > MAX_REPORTED) io::eprintfn("%s: %d further failures not shown", name, run.failures - MAX_REPORTED);
		assert(end_count >= 0, "%s: missing '# end: N vectors' line", name);
		assert(run.vectors == (usz)end_count, "%s: read %d vectors, end marker says %d", name, run.vectors, end_count);
		totals = { run.libbug_vectors, run.libbug_observed, run.known_hit, run.failures };
	}
	assert(ta.allocation_count() == 0, "%s: leaked %d allocations", name, ta.allocation_count());
	return totals;
}

const String[] FILES = {
	"arith.txt", "nan.txt", "cast.txt", "int_float.txt", "float_to_int.txt",
	"compare.txt", "print.txt", "parse.txt", "complex.txt", "annex_helpers.txt",
};

<* One test over all files, so the KNOWN_DIFFERENCES coverage check sees every hit. *>
fn void all_vector_files() @test
{
	FileTotals sum;
	foreach (name : FILES)
	{
		FileTotals t = run_file(name);
		sum.libbug_vectors += t.libbug_vectors;
		sum.libbug_observed += t.libbug_observed;
		sum.known_hit += t.known_hit;
		sum.failures += t.failures;
	}
	io::printfn("total: %d lib-bug vectors, %d reproduce Zig 0.17.0's observed output, %d are known differences",
		sum.libbug_vectors, sum.libbug_observed, sum.known_hit);
	assert(sum.failures == 0, "%d failing vectors", sum.failures);
	assert(sum.libbug_vectors == 97, "expected 97 lib-bug vectors, read %d", sum.libbug_vectors);
	assert(sum.known_hit == KNOWN_DIFFERENCES.len, "%d known differences listed, %d hit", KNOWN_DIFFERENCES.len, sum.known_hit);
}
