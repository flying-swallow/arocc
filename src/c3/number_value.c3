// Numeric literal values: the conversion half of src/aro/Parser.zig
// parseNumberToken / parseInt / fixedSizeInt / bitInt / parseFloat (and the
// helper getMSVCIntSuffixType), extracted so it needs no Parser, token list or
// AST. See number_literal.c3 for how the plan 11 literal modules fit together.
//
// Stage 0 (plan 11 contract): types, diagnostic ids and signatures; bodies are
// `unreachable("stage 0 stub")` until 11.2 `number-values` lands.
//
// Inputs: the NumberLiteralResult from number_literal (or its parts) and the
// Compilation (langopts.emulate, target.has_int128, type_store, interner).
// Outputs: NumberValue { qt, val, ... } with interned values (aro::value for
// integers, value::intern_big for _BitInt, float_value::intern_float /
// intern_complex for floats).
//
// Diagnostics: Zig reports these through `Parser.err(tok_i, ...)`, which
// first drops extension diagnostics inside `__extension__` and then reports at
// the token. So they are *returned* in Zig emission order as NumberValueDiag
// ids; the caller (C parser, pragma handler, preprocessor) reports them with
// `NumberValueDiag.template()`. The syntax diagnostics of number_literal are
// emitted by NumberLiteralParser itself, before any of these.
//
// Deviations from Zig:
// - AST nodes are not created. Zig builds `int_literal` / `float_literal`
//   with the real type and, for imaginary suffixes, wraps it in an
//   `imaginary_literal` unary node of the complex type; NumberValue reports
//   both types (`literal_qt`, `qt`) and `is_imaginary` so the parser can do so.
// - Zig's per-parser `strings` scratch buffer for stripping digit separators
//   becomes a temporary allocation from comp.gpa (or a stack buffer).
module aro::number_value;
import aro::compilation, aro::diagnostics, aro::source, aro::lang_opts, aro::type_store;
import aro::value, aro::value_interner, aro::float_value, aro::bigint;
import aro::number_literal, aro::text_literal;

// ---------------------------------------------------------------------------
// Zig `Parser.Diagnostic` / `Preprocessor.Diagnostic` constants used by
// numeric literals (identical text in both Zig tables).

const DiagnosticTemplate DIAG_INT_LITERAL_TOO_BIG = {
	.fmt = "integer literal is too large to be represented in any integer type",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_IMPLICITLY_UNSIGNED_LITERAL = {
	.fmt = "integer literal is too large to be represented in a signed integer type, interpreting as unsigned",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.IMPLICITLY_UNSIGNED_LITERAL,
	.extension = true,
};

const DiagnosticTemplate DIAG_GNU_IMAGINARY_CONSTANT = {
	.fmt = "imaginary constants are a GNU extension",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.GNU_IMAGINARY_CONSTANT,
	.extension = true,
};

<* Zig `Preprocessor.Diagnostic.float_literal_in_expr` (pp `#if` only). *>
const DiagnosticTemplate DIAG_FLOAT_LITERAL_IN_EXPR = {
	.fmt = "floating point literal in preprocessor expression",
	.kind = ERROR,
};

<* A diagnostic produced by value conversion, reported by the caller at the literal token. None takes arguments. *>
enum NumberValueDiag : char
{
	INT_LITERAL_TOO_BIG,
	IMPLICITLY_UNSIGNED_LITERAL,
	GNU_IMAGINARY_CONSTANT,
	FLOAT_LITERAL_IN_EXPR,
}

<* The DiagnosticTemplate of a NumberValueDiag (its `fmt` is the final text). *>
fn DiagnosticTemplate NumberValueDiag.template(self)
{
	switch (self)
	{
		case INT_LITERAL_TOO_BIG: return DIAG_INT_LITERAL_TOO_BIG;
		case IMPLICITLY_UNSIGNED_LITERAL: return DIAG_IMPLICITLY_UNSIGNED_LITERAL;
		case GNU_IMAGINARY_CONSTANT: return DIAG_GNU_IMAGINARY_CONSTANT;
		case FLOAT_LITERAL_IN_EXPR: return DIAG_FLOAT_LITERAL_IN_EXPR;
	}
}

<* Up to two diagnostics in Zig emission order (a value diagnostic, then GNU_IMAGINARY_CONSTANT). *>
struct NumberValueDiags
{
	NumberValueDiag[2] items;
	uint len;
}

<* Append `d`. *>
fn void NumberValueDiags.push(&self, NumberValueDiag d)
{
	assert(self.len < 2);
	self.items[self.len++] = d;
}

<* The recorded diagnostics. *>
fn NumberValueDiag[] NumberValueDiags.slice(&self) => self.items[:self.len];

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
	<* Interned value of the real literal node (Zig putValue on int_literal / float_literal). *>
	Value literal_val;
	<* Zig wraps the literal in an `imaginary_literal` unary node. *>
	bool is_imaginary;
	NumberValueDiags diags;
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
	NumberValueDiags diags;
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
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.parseNumberToken` whole: NumberLiteralParser{comp, literal, loc,
 expansion_locs}.parse() (its diagnostics are reported there), then
 number_value. The returned `diags` still have to be reported by the caller.
 @return? text_literal::PARSING_FAILED, compilation::FATAL_ERROR
*>
fn NumberValue? parse_number_token(Compilation* comp, String literal, Location loc, Location[] expansion_locs)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.parseInt`: base = prefix.base; bit_int if suffix.is_bit_int()
 else fixed_size_int. Then if imaginary: push GNU_IMAGINARY_CONSTANT,
 qt = qt.to_complex(comp), val = value::NONE, is_imaginary = true.
*>
fn NumberValue parse_int(Compilation* comp, Prefix prefix, String bytes, Suffix suffix)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.fixedSizeInt`. accumulate_u64(bytes, base). Overflow: push
 INT_LITERAL_TOO_BIG, qt = ULONG_LONG, val = the wrapped u64; done.
 Signed suffix and base 10 and val > max_int(type_store.intmax): push
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
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.bitInt`: strip '\'' separators, big-int setString(base); bits =
 max(1, bitCountTwosComp) + (signed suffix ? 1 : 0) (the wb suffix always
 reserves a sign bit, even for hex/octal); qt = type_store.put(bit_int(bits,
 suffix.signedness())); val = value::intern_big.
 @require base == 2 || base == 8 || base == 10 || base == 16
*>
fn NumberValue bit_int(Compilation* comp, char base, String bytes, Suffix suffix)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.parseFloat`: qt = float_suffix_type(suffix); strip '\''
 separators; float_value::parse_f128 (cannot fail: syntax already checked);
 cast to the KeyFloatTag of qt.bit_sizeof (16 -> F16 — also for __bf16, as in
 Zig —, 32, 64, 80, 128; decimal floats use the binary width too); intern.
 Imaginary: push GNU_IMAGINARY_CONSTANT, qt = to_complex, val = complex
 {+0.0, x} at the same width, is_imaginary = true.
*>
fn NumberValue parse_float(Compilation* comp, String bytes, Suffix suffix)
{
	unreachable("stage 0 stub");
}

// ---------------------------------------------------------------------------
// Helpers

<*
 The type switch of Zig `parseFloat`: NONE/I -> DOUBLE; F/IF -> FLOAT;
 F16/IF16 -> FLOAT16; BF16 -> BF16; L/IL -> LONG_DOUBLE; W/IW ->
 float80_type (must exist: checked by number_literal); Q/IQ/F128/IF128 ->
 FLOAT128; F32/IF32 -> FLOAT32; F64/IF64 -> FLOAT64; F32X/IF32X -> FLOAT32X;
 F64X/IF64X -> FLOAT64X; D32/D64/D128/D64X -> DFLOAT32/64/128/64X; other
 suffixes unreachable.
*>
fn QualType float_suffix_type(Compilation* comp, Suffix suffix)
{
	unreachable("stage 0 stub");
}

<*
 The `suffix_qt` switch of Zig `fixedSizeInt`: NONE/I -> INT; U/IU -> UINT;
 UL/IUL -> ULONG; ULL/IULL -> ULONG_LONG; L/IL -> LONG; LL/ILL -> LONG_LONG;
 I8..UI64 -> msvc_int_suffix_type; other suffixes unreachable.
*>
fn QualType int_suffix_type(Compilation* comp, Suffix suffix)
{
	unreachable("stage 0 stub");
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
	unreachable("stage 0 stub");
}

<*
 The digit loop of Zig `fixedSizeInt` / pp primaryExpr: skip '\'', digit =
 c - '0' / 'A' + 10 / 'a' + 10; if val != 0, val *= base with u64 wraparound
 (overflow flagged); val += digit with wraparound (overflow flagged).
*>
fn DigitsValue accumulate_u64(String bytes, char base)
{
	unreachable("stage 0 stub");
}

<*
 Zig Preprocessor/Parser.zig primaryExpr `.pp_num` after a successful
 NumberLiteralParser.parse. Float or imaginary: FLOAT_LITERAL_IN_EXPR and
 `rejected` (the caller reports it and returns null, Zig). Otherwise accumulate_u64(bytes, prefix.base); overflow -> push
 INT_LITERAL_TOO_BIG; val > i64 max -> (signed suffix and base 10 -> push
 IMPLICITLY_UNSIGNED_LITERAL) and unsigned val; else signed if the suffix is
 a signed integer suffix, unsigned otherwise.
*>
fn PpNumberValue pp_int_value(NumberLiteralResult parsed)
{
	unreachable("stage 0 stub");
}
