// Numeric literal values: the conversion half of src/aro/Parser.zig
// parseNumberToken / parseInt / fixedSizeInt / bitInt / parseFloat (and the
// helper getMSVCIntSuffixType), extracted so it needs no Parser, token list or
// AST. See number_literal.c3 for how the plan 11 literal modules fit together.
//
// Implemented by plan 11 agent 11.2 `number-values`; the Suffix predicates
// (is_imaginary, is_signed_integer, ...) are number_literal's Suffix methods.
//
// Inputs: the NumberLiteralResult from number_literal (or its parts) and the
// Compilation (langopts.emulate, target.has_int128, type_store, interner).
// Outputs: NumberValue { qt, val, ... } with interned values (aro::value for
// integers, value::intern_big for _BitInt, value::intern for
// floats and complexes).
//
// Diagnostics: Zig reports these through `Parser.err(tok_i, ...)`, which
// first drops extension diagnostics inside `__extension__` and then reports at
// the token. So they are *returned* as NumberDiags flags, which
// NumberDiags.@each walks in Zig emission order; the caller (C parser, pragma handler, preprocessor) reports them (the
// enum carries its fmt/kind/meta, so it can be passed to any emit macro). The syntax diagnostics of number_literal are
// emitted by NumberLiteralParser itself, before any of these.
//
// Deviations from Zig:
// - AST nodes are not created. Zig builds `int_literal` / `float_literal`
//   with the real type and, for imaginary suffixes, wraps it in an
//   `imaginary_literal` unary node of the complex type; NumberValue reports
//   both types (`literal_qt`, `qt`) and `is_imaginary` so the parser can do so.
// - Zig's per-parser `strings` scratch buffer for stripping digit separators
//   becomes a temporary allocation from comp.gpa (none if there is no '\'').
// - Zig never stores a value on the inner `float_literal` of an imaginary
//   float (parseFloat has no putValue; the AST golden test/cases/ast/__float80.c
//   prints `float_literal: 'long double'` without a value), so `literal_val`
//   is value::NONE there. Imaginary integers keep the int_literal value
//   (fixedSizeInt / bitInt call putValue before the wrap).
module aro::number_value;
import aro::primitive_value;
import aro::compilation, aro::diagnostics, aro::source, aro::lang_opts, aro::type_store;
import aro::value, aro::value_interner, aro::bigint;
import aro::number_literal, aro::text_literal;

<* Diagnostics a numeric literal value can raise; reported in field order (= Zig emission order). *>
bitstruct NumberDiags : char
{
	bool int_literal_too_big : 0;
	bool implicitly_unsigned_literal : 1;
	bool hex_float_no_significand : 2;
	bool float_literal_in_expr : 3;
	bool gnu_imaginary_constant : 4;
	<* C90 typed an unsuffixed decimal above LONG_MAX as unsigned long (GCC c-lex). *>
	bool c90_unsigned_decimal : 5;
}

<* Run `@body` with each set flag's Diagnostic as a compile-time constant, in emission order. *>
macro void NumberDiags.@each(self; @body($diag))
{
	if (self.int_literal_too_big) @body(Diagnostic.INT_LITERAL_TOO_BIG);
	if (self.implicitly_unsigned_literal) @body(Diagnostic.IMPLICITLY_UNSIGNED_LITERAL);
	if (self.c90_unsigned_decimal) @body(Diagnostic.C90_UNSIGNED_DECIMAL);
	if (self.hex_float_no_significand) @body(Diagnostic.HEX_FLOAT_NO_SIGNIFICAND);
	if (self.float_literal_in_expr) @body(Diagnostic.FLOAT_LITERAL_IN_EXPR);
	if (self.gnu_imaginary_constant) @body(Diagnostic.GNU_IMAGINARY_CONSTANT);
}

// ---------------------------------------------------------------------------
// Results

<* The typed value of a numeric literal (Zig `Parser.Result` without the node). *>
struct NumberValue
{
	<* Type of the whole expression: the complex type for imaginary literals. *>
	QualType qt;
	<* Type of the real literal node (Zig int_literal / float_literal qt); equals qt unless imaginary. *>
	QualType literal_qt;
	<*
	 Interned value of the expression. Imaginary floats: complex {0, x}.
	 Imaginary integers: value::NONE (Zig `res.val = .{}`).
	*>
	Value val;
	<*
	 Interned value of the real literal node (Zig putValue on int_literal /
	 float_literal). value::NONE for imaginary floats (Zig stores none).
	*>
	Value literal_val;
	<* Zig wraps the literal in an `imaginary_literal` unary node. *>
	bool is_imaginary;
	NumberDiags diags;
}

<* The `#if` value of a pp-number (Zig Preprocessor/Parser.zig primaryExpr `.pp_num`). *>
struct PpNumberValue
{
	<* Float or imaginary literal: diags holds FLOAT_LITERAL_IN_EXPR and Zig's primaryExpr returns null. *>
	bool rejected;
	bool is_signed;
	<* valid when !is_signed *>
	ulong unsigned;
	<* valid when is_signed *>
	long signed;
	NumberDiags diags;
}

<* Zig's shared digit loop (fixedSizeInt and pp primaryExpr). *>
struct DigitsValue
{
	ulong val;
	bool overflow;
}

// ---------------------------------------------------------------------------
// Entry points

<*
 Zig `Parser.parseNumberToken` after the syntax step: is_float ->
 parse_float(bytes, suffix), else parse_int(prefix, bytes, suffix).
*>
fn NumberValue number_value(Compilation* comp, NumberLiteralResult parsed)
{
	if (parsed.is_float) return parse_float(comp, parsed.bytes, parsed.suffix);
	return parse_int(comp, parsed.prefix, parsed.bytes, parsed.suffix);
}

<*
 Zig `Parser.parseNumberToken` whole: NumberLiteralParser{comp, literal, loc,
 expansion_locs}.parse() (its diagnostics are reported there), then
 number_value. The returned `diags` still have to be reported by the caller.
 @return? text_literal::PARSING_FAILED, compilation::FATAL_ERROR
*>
fn NumberValue? parse_number_token(Compilation* comp, String literal, Location loc, Location[] expansion_locs)
{
	NumberLiteralParser p = { .comp = comp, .literal = literal, .loc = loc, .expansion_locs = expansion_locs };
	NumberLiteralResult parsed = p.parse()!;
	return number_value(comp, parsed);
}

<*
 Zig `Parser.parseInt`: base = prefix.base; bit_int if suffix.is_bit_int()
 else fixed_size_int. Then if imaginary: flag GNU_IMAGINARY_CONSTANT,
 qt = qt.to_complex(comp), val = value::NONE, is_imaginary = true.
*>
fn NumberValue parse_int(Compilation* comp, Prefix prefix, String bytes, Suffix suffix)
{
	char base = prefix.base;
	NumberValue res;
	if (suffix.is_bit_int())
	{
		res = bit_int(comp, base, bytes, suffix);
	}
	else
	{
		res = fixed_size_int(comp, base, bytes, suffix);
	}
	if (suffix.is_imaginary())
	{
		res.diags.gnu_imaginary_constant = true;
		res.qt = res.qt.to_complex(comp);
		res.val = value::NONE;
		res.is_imaginary = true;
	}
	return res;
}

<*
 Zig `Parser.fixedSizeInt`. accumulate_u64(bytes, base). Overflow: flag
 INT_LITERAL_TOO_BIG, qt = ULONG_LONG, val = the wrapped u64; done.
 Signed suffix and base 10 and val > max_int(type_store.intmax): flag
 IMPLICITLY_UNSIGNED_LITERAL. suffix_qt = int_suffix_type(suffix). MSVC
 suffix: qt = suffix_qt and val is int_cast to it (no diagnostic). Otherwise
 the first candidate (unsigned suffix: UINT, ULONG, ULONG_LONG; base 10: INT,
 LONG, LONG_LONG; else INT, UINT, LONG, ULONG, LONG_LONG, ULONG_LONG) whose
 rank is not below suffix_qt and whose max_int >= val; if none: emulate
 NO/GCC -> INT128 if target.has_int128() else LONG_LONG; MSVC/CLANG ->
 ULONG_LONG (the value is not truncated).
 @require base == 2 || base == 8 || base == 10 || base == 16
*>
fn NumberValue fixed_size_int(Compilation* comp, char base, String bytes, Suffix suffix)
{
	NumberValue res = { .val = value::NONE, .literal_val = value::NONE };
	DigitsValue digits = accumulate_u64(bytes, base);
	Value val = value::int_u64(digits.val, comp);
	if (digits.overflow)
	{
		res.diags.int_literal_too_big = true;
		res.qt = type_store::ULONG_LONG;
		res.literal_qt = res.qt;
		res.val = val;
		res.literal_val = val;
		return res;
	}
	bool is_signed = suffix.is_signed_integer();
	// C90 6.1.3.2: unsuffixed and `l` decimals try int, long, unsigned long; being
	// unsigned there is standard, not the C99 "implicitly unsigned" extension.
	bool c90_decimal = is_signed && base == 10 && !comp.langopts.standard.at_least(C99);
	if (is_signed && base == 10 && !c90_decimal)
	{
		// Normal driver setup initializes named types while generating builtin
		// macros. Raw parser clients can skip that step, so match Zig's intmax
		// when available and derive the target's equivalent builtin type otherwise.
		QualType intmax = comp.type_store.intmax;
		if (intmax.is_invalid()) intmax = type_store::int_kind_qt(comp.target.int_max_type());
		Value max_intmax = value::max_int(intmax, comp);
		if (value::compare(val, GT, max_intmax, comp)) res.diags.implicitly_unsigned_literal = true;
	}

	QualType suffix_qt = int_suffix_type(comp, suffix);
	if (suffix.is_msvc_extension())
	{
		// No type promotion and no diagnostic for truncation or sign change (Zig).
		res.qt = suffix_qt;
		val.int_cast(suffix_qt, comp);
	}
	else
	{
		QualType[3] unsigned_qts = { type_store::UINT, type_store::ULONG, type_store::ULONG_LONG };
		QualType[3] decimal_qts = { type_store::INT, type_store::LONG, type_store::LONG_LONG };
		QualType[4] c90_decimal_qts = { type_store::INT, type_store::LONG, type_store::ULONG, type_store::LONG_LONG };
		QualType[6] other_qts = {
			type_store::INT, type_store::UINT, type_store::LONG,
			type_store::ULONG, type_store::LONG_LONG, type_store::ULONG_LONG,
		};
		QualType[] qts;
		if (!is_signed)
		{
			qts = &unsigned_qts;
		}
		else if (c90_decimal)
		{
			qts = &c90_decimal_qts;
		}
		else if (base == 10)
		{
			qts = &decimal_qts;
		}
		else
		{
			qts = &other_qts;
		}
		bool found = false;
		foreach (qt : qts)
		{
			if (qt.int_rank_order(suffix_qt, comp) == LT) continue;
			if (value::compare(val, LTE, value::max_int(qt, comp), comp))
			{
				res.qt = qt;
				found = true;
				if (c90_decimal && qt == type_store::ULONG) res.diags.c90_unsigned_decimal = true;
				break;
			}
		}
		if (!found)
		{
			switch (comp.langopts.emulate)
			{
				case NO:
				case GCC:
					res.qt = comp.target.has_int128() ? type_store::INT128 : type_store::LONG_LONG;
				case MSVC:
				case CLANG:
					res.qt = type_store::ULONG_LONG;
			}
		}
	}
	res.literal_qt = res.qt;
	res.val = val;
	res.literal_val = val;
	return res;
}

<*
 Zig `Parser.bitInt`. Digits are accumulated directly, skipping '\'' separators
 (bigint::set_string only skips '_', so no stripped copy is needed). bits =
 max(1, bitCountTwosComp) + 1 for signed suffixes: wb always reserves a sign
 bit, even for hex/octal. Zig narrows bits with @intCast (bit_int_max_bits =
 65535); a longer literal is a safety panic there and an assert here.
 @require base == 2 || base == 8 || base == 10 || base == 16
*>
fn NumberValue bit_int(Compilation* comp, char base, String bytes, Suffix suffix)
{
	Limb[] limbs = alloc::new_array(tmem, Limb, (usz)(bigint::calc_set_string_limb_count(base, bytes.len)));
	BigIntMutable m = value::mutable_over(limbs); // zeroed, len = 1
	foreach (ch : bytes)
	{
		if (ch == '\'') continue;
		// Digits were validated by number_literal.
		m.mul_add_small(base, (Limb)bigint::digit_value(ch, base)!!);
	}
	BigIntConst c = m.to_const();

	usz bits = max(c.bit_count_twos_comp(), (usz)1) + (usz)(suffix.is_signed_integer() ? 1 : 0);
	assert(bits <= 65535, "_BitInt literal wider than bit_int_max_bits");

	QualType qt = comp.type_store.put(type_store::type_bit_int((ushort)bits, suffix.signedness()));
	Value val = value::intern_big(comp, c);
	return { .qt = qt, .literal_qt = qt, .val = val, .literal_val = val };
}

<*
 Zig `Parser.parseFloat`: qt = float_suffix_type(suffix); strip '\''
 separators; primitive_value::parse_f128; on failure (only `0x.p1`-style hex
 floats without significand digits, where Zig's `catch unreachable` panics)
 flag the C3-only HEX_FLOAT_NO_SIGNIFICAND error and use +0.0;
 cast to the PrimitiveType of qt.bit_sizeof (16 -> F16 — also for __bf16, as in
 Zig —, 32, 64, 80, 128; decimal floats use the binary width too); intern.
 Imaginary: flag GNU_IMAGINARY_CONSTANT, qt = to_complex, val = complex
 {+0.0, x} at the same width, is_imaginary = true, literal_val = NONE (see
 the file header).
*>
fn NumberValue parse_float(Compilation* comp, String bytes, Suffix suffix)
{
	QualType qt = float_suffix_type(comp, suffix);
	String digits = strip_separators(comp, bytes);
	F128Bits? parsed = primitive_value::parse_f128(digits);
	free_stripped(comp, bytes, digits);
	NumberValue res;
	F128Bits bits;
	if (try parsed)
	{
		bits = parsed;
	}
	else
	{
		// Zig: `catch unreachable` (safety panic). Defined result instead.
		res.diags.hex_float_no_significand = true;
	}

	PrimitiveType tag = value::width_of(qt, comp);
	PrimitiveValue f = primitive_value::f128_value(bits).cast(tag);
	Value val = value::intern(comp, f);

	res.qt = qt;
	res.literal_qt = qt;
	res.val = val;
	res.literal_val = val;
	if (suffix.is_imaginary())
	{
		res.diags.gnu_imaginary_constant = true;
		res.qt = qt.to_complex(comp);
		PrimitiveValue re = primitive_value::zero(tag);
		res.val = value::intern(comp, primitive_value::complex_key(re, f));
		res.literal_val = value::NONE;
		res.is_imaginary = true;
	}
	return res;
}

// ---------------------------------------------------------------------------
// Helpers

<*
 The type switch of Zig `parseFloat`: NONE/I -> DOUBLE; F/IF -> FLOAT;
 F16/IF16 -> FLOAT16; BF16 -> BF16; L/IL -> LONG_DOUBLE; W/IW ->
 float80_type (must exist: checked by number_literal); Q/IQ/F128/IF128 ->
 FLOAT128; F32/IF32 -> FLOAT32; F64/IF64 -> FLOAT64; F32X/IF32X ->
 FLOAT32X; F64X/IF64X -> FLOAT64X; D32/D64/D128/D64X -> DFLOAT32/64/128/64X; other
 suffixes unreachable.
*>
fn QualType float_suffix_type(Compilation* comp, Suffix suffix)
{
	switch (suffix)
	{
		case NONE:
		case I: return type_store::DOUBLE;
		case F:
		case IF: return type_store::FLOAT;
		case F16:
		case IF16: return type_store::FLOAT16;
		case BF16: return type_store::BF16;
		case L:
		case IL: return type_store::LONG_DOUBLE;
		case W:
		case IW: return comp.float80_type()!!;
		case Q:
		case IQ:
		case F128:
		case IF128: return type_store::FLOAT128;
		case F32:
		case IF32: return type_store::FLOAT32;
		case F64:
		case IF64: return type_store::FLOAT64;
		case F32X:
		case IF32X: return type_store::FLOAT32X;
		case F64X:
		case IF64X: return type_store::FLOAT64X;
		case D32: return type_store::DFLOAT32;
		case D64: return type_store::DFLOAT64;
		case D128: return type_store::DFLOAT128;
		case D64X: return type_store::DFLOAT64X;
		default: unreachable("not a floating suffix");
	}
}

<*
 The `suffix_qt` switch of Zig `fixedSizeInt`: NONE/I -> INT; U/IU -> UINT;
 UL/IUL -> ULONG; ULL/IULL -> ULONG_LONG; L/IL -> LONG; LL/ILL -> LONG_LONG;
 I8..UI64 -> msvc_int_suffix_type; other suffixes unreachable.
*>
fn QualType int_suffix_type(Compilation* comp, Suffix suffix)
{
	switch (suffix)
	{
		case NONE:
		case I: return type_store::INT;
		case U:
		case IU: return type_store::UINT;
		case UL:
		case IUL: return type_store::ULONG;
		case ULL:
		case IULL: return type_store::ULONG_LONG;
		case L:
		case IL: return type_store::LONG;
		case LL:
		case ILL: return type_store::LONG_LONG;
		case I8: return msvc_int_suffix_type(comp, 8, SIGNED);
		case UI8: return msvc_int_suffix_type(comp, 8, UNSIGNED);
		case I16: return msvc_int_suffix_type(comp, 16, SIGNED);
		case UI16: return msvc_int_suffix_type(comp, 16, UNSIGNED);
		case I32: return msvc_int_suffix_type(comp, 32, SIGNED);
		case UI32: return msvc_int_suffix_type(comp, 32, UNSIGNED);
		case I64: return msvc_int_suffix_type(comp, 64, SIGNED);
		case UI64: return msvc_int_suffix_type(comp, 64, UNSIGNED);
		default: unreachable("not a fixed-size integer suffix");
	}
}

<*
 Zig `Parser.getMSVCIntSuffixType`: 8 -> CHAR (signed) / UCHAR; 16, 32 ->
 type_store::int_least_n(comp, bits, signedness); 64 -> emulate != MSVC ?
 smallest_n_bit_int_target_independent(comp, 64, signedness) : LONG_LONG /
 ULONG_LONG.
 @require bits == 8 || bits == 16 || bits == 32 || bits == 64
*>
fn QualType msvc_int_suffix_type(Compilation* comp, uint bits, Signedness signedness)
{
	switch (bits)
	{
		case 8:
			return signedness == SIGNED ? type_store::CHAR : type_store::UCHAR;
		case 16:
		case 32:
			return type_store::int_least_n(comp, bits, signedness);
		default:
			if (comp.langopts.emulate != MSVC) return type_store::smallest_n_bit_int_target_independent(comp, 64, signedness);
			return signedness == SIGNED ? type_store::LONG_LONG : type_store::ULONG_LONG;
	}
}

<*
 The digit loop of Zig `fixedSizeInt` / pp primaryExpr: skip '\'', digit =
 c - '0' / 'A' + 10 / 'a' + 10; if val != 0, val *= base with u64 wraparound
 (overflow flagged); val += digit with wraparound (overflow flagged).
*>
fn DigitsValue accumulate_u64(String bytes, char base)
{
	DigitsValue res;
	foreach (c : bytes)
	{
		ulong digit;
		switch (c)
		{
			case '0'..'9': digit = (ulong)(c - '0');
			case 'A'..'Z': digit = (ulong)(c - 'A' + 10);
			case 'a'..'z': digit = (ulong)(c - 'a' + 10);
			case '\'': continue;
			default: unreachable("digits validated by number_literal");
		}
		if (res.val != 0)
		{
			uint128 product = (uint128)res.val * (uint128)base;
			if (product > (uint128)ulong::max) res.overflow = true;
			res.val = (ulong)product;
		}
		ulong sum = res.val + digit;
		if (sum < res.val) res.overflow = true;
		res.val = sum;
	}
	return res;
}

<*
 Zig Preprocessor/Parser.zig primaryExpr `.pp_num` after a successful
 NumberLiteralParser.parse. Float or imaginary: FLOAT_LITERAL_IN_EXPR and
 `rejected` (the caller reports it and returns null, Zig). Otherwise accumulate_u64(bytes, prefix.base); overflow -> flag
 INT_LITERAL_TOO_BIG; val > i64 max -> (signed suffix and base 10 -> flag
 IMPLICITLY_UNSIGNED_LITERAL) and unsigned val; else signed if the suffix is
 a signed integer suffix, unsigned otherwise.
*>
fn PpNumberValue pp_int_value(NumberLiteralResult parsed)
{
	PpNumberValue res;
	if (parsed.is_float || parsed.suffix.is_imaginary())
	{
		res.diags.float_literal_in_expr = true;
		res.rejected = true;
		return res;
	}
	char base = parsed.prefix.base;
	DigitsValue digits = accumulate_u64(parsed.bytes, base);
	if (digits.overflow) res.diags.int_literal_too_big = true;
	bool is_signed = parsed.suffix.is_signed_integer();
	if (digits.val > (ulong)long::max)
	{
		if (is_signed && base == 10) res.diags.implicitly_unsigned_literal = true;
		res.unsigned = digits.val;
		return res;
	}
	if (is_signed)
	{
		res.is_signed = true;
		res.signed = (long)digits.val;
	}
	else
	{
		res.unsigned = digits.val;
	}
	return res;
}

// ---------------------------------------------------------------------------
// Separators

<* `bytes` without '\'' digit separators: `bytes` itself if it has none, else a comp.gpa copy (release with free_stripped). *>
fn String strip_separators(Compilation* comp, String bytes)
{
	sz n = 0;
	foreach (c : bytes)
	{
		if (c != '\'') n++;
	}
	if (n == bytes.len) return bytes;
	if (n == 0) return "";
	char[] out = alloc::new_array(comp.gpa, char, (usz)n);
	sz j = 0;
	foreach (c : bytes)
	{
		if (c != '\'') out[j++] = c;
	}
	return (String)out;
}

<* Release a strip_separators result. *>
fn void free_stripped(Compilation* comp, String bytes, String stripped)
{
	if (stripped.len > 0 && stripped.ptr != bytes.ptr) alloc::free(comp.gpa, stripped.ptr);
}
