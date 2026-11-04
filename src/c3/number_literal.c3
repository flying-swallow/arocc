// Port of src/aro/Tokenizer/number_literal.zig: Prefix/Suffix classification
// and the pp-number syntax splitter (Parser.parse).
//
// How the plan 11 literal modules fit together
// --------------------------------------------
//   number_literal.c3  (11.1 `number-syntax`)
//       Bytes of one pp-number token -> NumberLiteralResult { bytes, is_float,
//       prefix, suffix }. Validates digits, separators, exponent and suffix
//       against LangOpts (C23 binary/_BitInt, C2y octal, MSVC fixed-size
//       suffixes) and reports syntax diagnostics itself (DIAG_* below) at the
//       token's Location + expansion locations.
//   number_value.c3    (11.2 `number-values`)
//       NumberLiteralResult -> NumberValue { qt, val, ... }: Parser.zig
//       parseNumberToken/parseInt/fixedSizeInt/bitInt/parseFloat without the
//       parser. Floats go through float_value::parse_f128 and KeyFloat.cast;
//       integers through value (u64) / bigint (_BitInt). Parser-level
//       diagnostics (int_literal_too_big, ...) are *returned* as
//       NumberValueDiag ids, because the C parser filters them
//       (extension_suppressed) before reporting at the token.
//   text_literal.c3    (11.3 `text-decoding`)
//       TextLiteralKind (classify/concat/types/widths), the TextLiteralParser
//       escape/UCN/encoding decoder (`next`) and character constants
//       (`parse`). Reports its own diagnostics. Also holds the shared
//       diagnostic plumbing (Ascii, LiteralArg, emit_literal_diagnostic) and
//       PARSING_FAILED.
//   text_literal_semantics.c3  (11.4 `char-string`)
//       Parser.zig charLiteral/stringLiteral without the parser: a char token
//       -> CharLiteral { qt, val }; a run of adjacent string tokens ->
//       StringLiteral { kind, qt, val (interned bytes) }, with concatenation
//       restrictions returned as TextSemanticsDiag ids.
//
// None of these needs a token list or AST: inputs are token bytes, TokenId,
// Location and expansion locations plus the Compilation (langopts, target,
// type_store, interner, diagnostics). The preprocessor (plan 13: `#if`
// pp-numbers and char constants, unescapeUcn) uses NumberLiteralParser,
// number_value::pp_int_value, TextLiteralParser and
// text_literal_semantics::pp_char_value directly.
//
// Stage 0 (plan 11 contract): types, diagnostic templates and signatures.
// `float80_type` and the parser's `err` are implemented; everything else is
// `unreachable("stage 0 stub")` until 11.1 lands.
//
// Deviations from Zig:
// - Suffix.fromString returning null is the INVALID_SUFFIX fault.
// - `Prefix` carries its base as an associated value (`prefix.base`, Zig
//   @backingInt(prefix)).
// - Suffix tags F32x/F64x/IF32x/IF64x/D64x become F32X/F64X/IF32X/IF64X/D64X.
// - Zig `Compilation.float80Type` (?QualType) is `float80_type`, NO_FLOAT80
//   for null (API note: belongs in compilation.c3).
module aro::number_literal;
import aro::compilation, aro::diagnostics, aro::source, aro::lang_opts, aro::type_store, aro::text_literal;

<* Zig `Suffix.fromString` returned null: not a valid suffix of that kind. *>
excuse INVALID_SUFFIX;
<* Zig `Compilation.float80Type` returned null: no __float80 for this target/emulation. *>
excuse NO_FLOAT80;

// ---------------------------------------------------------------------------
// Zig `number_literal.Parser.Diagnostic` constants (exact Zig text).

const DiagnosticTemplate DIAG_INVALID_BINARY_DIGIT = {
	.fmt = "invalid digit '{c}' in binary constant",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_INVALID_OCTAL_DIGIT = {
	.fmt = "invalid digit '{c}' in octal constant",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_INVALID_INT_SUFFIX = {
	.fmt = "invalid suffix '{s}' on integer constant",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_INVALID_FLOAT_SUFFIX = {
	.fmt = "invalid suffix '{s}' on floating constant",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_HEX_FLOATING_CONSTANT_REQUIRES_EXPONENT = {
	.fmt = "hexadecimal floating constant requires an exponent",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_EXPONENT_HAS_NO_DIGITS = {
	.fmt = "exponent has no digits",
	.kind = ERROR,
};

const DiagnosticTemplate DIAG_C23_BINARY = {
	.fmt = "binary integer literals are a C23 extension",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.C23_EXTENSIONS,
	.extension = true,
};

<* Zig text says "octal" although this is the binary-literal compat warning; kept verbatim. *>
const DiagnosticTemplate DIAG_PRE_C23_BINARY = {
	.fmt = "octal integer literals are incompatible with C standards before C23",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.PRE_C23_COMPAT,
};

const DiagnosticTemplate DIAG_BITINT_SUFFIX = {
	.fmt = "'_BitInt' suffix for literals is a C23 extension",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.C23_EXTENSIONS,
	.extension = true,
};

const DiagnosticTemplate DIAG_PRE_C23_BITINT = {
	.fmt = "'_BitInt' suffix for literals is incompatible with C standards before C23",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.PRE_C23_COMPAT,
};

const DiagnosticTemplate DIAG_C2Y_OCTAL = {
	.fmt = "octal integer literals are a C2y extension",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.C2Y_EXTENSIONS,
	.extension = true,
};

const DiagnosticTemplate DIAG_PRE_C2Y_OCTAL = {
	.fmt = "octal integer literals are incompatible with C standards before C2y",
	.kind = OFF,
	.has_opt = true,
	.opt = Option.PRE_C2Y_COMPAT,
};

const DiagnosticTemplate DIAG_C2Y_DEPRECATED_OCTAL = {
	.fmt = "octal literals without a '0o' prefix are deprecated",
	.kind = WARNING,
	.has_opt = true,
	.opt = Option.DEPRECATED_OCTAL_LITERALS,
};

// ---------------------------------------------------------------------------
// Compilation helper

<*
 Zig `Compilation.float80Type`: emulate NO/GCC -> Target.float80Type (LONG_DOUBLE
 on x86/x86_64, else none); MSVC/CLANG -> none.
 @return? NO_FLOAT80
*>
fn QualType? float80_type(Compilation* comp)
{
	switch (comp.langopts.emulate)
	{
		case NO:
		case GCC:
			if (comp.target.has_float80_type()) return type_store::LONG_DOUBLE;
			return NO_FLOAT80~;
		case MSVC:
		case CLANG:
			return NO_FLOAT80~;
	}
}

// ---------------------------------------------------------------------------
// Prefix

<* Zig `number_literal.Prefix` (enum(u8) with the base as tag value). *>
enum Prefix : char (char base)
{
	BINARY { 2 },
	OCTAL { 8 },
	DECIMAL { 10 },
	HEX { 16 },
}

<*
 Zig `Prefix.digitAllowed`: '0','1' always; '2'..'7' unless BINARY;
 '8','9' for DECIMAL/HEX; 'a'..'f','A'..'F' for HEX only; else false.
*>
fn bool Prefix.digit_allowed(self, char c)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Prefix.fromString`. len 1 -> DECIMAL; first byte '.' or '1'..'9' ->
 DECIMAL ('0' continues, anything else unreachable: the tokenizer guarantees a
 digit or period); second byte x/X -> HEX, b/B -> BINARY, o/O -> OCTAL (each
 DECIMAL if the literal is exactly 2 bytes); otherwise DECIMAL if any of
 "eE." occurs, DECIMAL if buf[1..] is a valid INT suffix (`0` with a suffix),
 else OCTAL.
 @require buf.len > 0
*>
fn Prefix prefix_from_string(String buf, bool allow_msvc_extensions)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Prefix.stringLen`: BINARY 2; HEX 2; DECIMAL 0; OCTAL 2 if len > 2 and
 buf[1] is 'o', 'O' or '\'' (the digit separator counts as prefix so the next
 char is a digit), else 1.
*>
fn sz Prefix.string_len(self, String buf)
{
	unreachable("stage 0 stub");
}

// ---------------------------------------------------------------------------
// Suffix

<* Zig `number_literal.Suffix`, in Zig declaration order. *>
enum Suffix : char
{
	NONE, I,             // int and imaginary int
	U, UL, ULL,          // unsigned real integers
	IU, IUL, IULL,       // unsigned imaginary integers
	L, IL,               // long or long double, real and imaginary
	LL, ILL,             // long long and imaginary long long
	F, IF,               // float and imaginary float
	F16, IF16,           // _Float16 and imaginary _Float16
	W,                   // __float80
	IW,                  // imaginary __float80
	Q, F128,             // _Float128
	IQ, IF128,           // imaginary _Float128
	IWB, IUWB,           // imaginary _BitInt
	WB, UWB,             // _BitInt
	BF16,                // __bf16
	F32, IF32,           // _Float32 and imaginary _Float32
	F64, IF64,           // _Float64 and imaginary _Float64
	F32X, IF32X,         // _Float32x and imaginary _Float32x
	F64X, IF64X,         // _Float64x and imaginary _Float64x
	D32,                 // _Decimal32
	D64,                 // _Decimal64
	D128,                // _Decimal128
	D64X,                // _Decimal64x
	I8, UI8, I16, UI16, I32, UI32, I64, UI64, // MSVC extensions
}

<* Zig `Suffix.fromString` `suffix_kind` parameter. *>
enum SuffixKind : char
{
	INT,
	FLOAT,
}

<*
 Zig `Suffix.fromString`. Empty -> NONE. Otherwise try the IntSuffixes or
 FloatSuffixes table in Zig order; a candidate (a list of upper-case parts,
 e.g. IUL = {"I","U","L"}) matches when the parts' total length equals
 buf.len and every part occurs in buf in its upper- or all-lower-case
 spelling (mem.find, order-free: "lu", "Ul" and "uL" all match UL); MSVC
 suffixes are skipped unless allowed. No match: INVALID_SUFFIX.
 @return? INVALID_SUFFIX
*>
fn Suffix? suffix_from_string(String buf, SuffixKind kind, bool allow_msvc_extensions)
{
	unreachable("stage 0 stub");
}

<* Zig `Suffix.isImaginary`: I, IL, IF, IU, IUL, ILL, IULL, IWB, IUWB, IF128, IQ, IW, IF16, IF32, IF64, IF32X, IF64X. *>
fn bool Suffix.is_imaginary(self)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Suffix.isSignedInteger`: true for NONE, L, LL, I, IL, ILL, WB, IWB, I8,
 I16, I32, I64; false for the U* integer suffixes.
 @require !self.is_float_only() : "float suffixes are unreachable in Zig"
*>
fn bool Suffix.is_signed_integer(self)
{
	unreachable("stage 0 stub");
}

<* Zig `Suffix.signedness`: SIGNED iff is_signed_integer. *>
fn Signedness Suffix.signedness(self)
{
	unreachable("stage 0 stub");
}

<* Zig `Suffix.isBitInt`: WB, UWB, IWB, IUWB. *>
fn bool Suffix.is_bit_int(self)
{
	unreachable("stage 0 stub");
}

<* Zig `Suffix.isFloat80`: W or IW. *>
fn bool Suffix.is_float80(self)
{
	unreachable("stage 0 stub");
}

<* Zig `Suffix.isMSVCExtension`: I8, UI8, I16, UI16, I32, UI32, I64, UI64. *>
fn bool Suffix.is_msvc_extension(self)
{
	unreachable("stage 0 stub");
}

<*
 Helper (no Zig counterpart): the suffixes on which Zig isSignedInteger is
 unreachable: F, IF, F16, F128, IF128, Q, IQ, W, IW, IF16, F32, IF32, F64,
 IF64, F32X, IF32X, F64X, IF64X, D32, D64, D128, D64X, BF16.
*>
fn bool Suffix.is_float_only(self)
{
	unreachable("stage 0 stub");
}

// ---------------------------------------------------------------------------
// Parser

<* Zig `number_literal.Parser.Result`. *>
struct NumberLiteralResult
{
	<*
	 Float: the literal without its suffix (prefix included, separators kept).
	 Integer: the integer digits after the prefix (separators kept).
	*>
	String bytes;
	bool is_float;
	Prefix prefix;
	Suffix suffix;
}

<*
 Zig `number_literal.Parser`: splits one pp-number token. Diagnostics are
 reported at `loc` through `expansion_locs` (Zig `err`).
*>
struct NumberLiteralParser
{
	Compilation* comp;
	String literal;
	Location loc;
	Location[] expansion_locs;
}

<*
 Zig `Parser.parse`. allow = langopts.allow_fixed_sized_int_suffixes();
 prefix = prefix_from_string(buf, allow); then getIntegerPart, getFracPart,
 getExponent; is_float = frac or exponent present; the rest must be a suffix
 of that kind (else DIAG_INVALID_FLOAT_SUFFIX / DIAG_INVALID_INT_SUFFIX with
 the suffix text); W/IW without float80_type -> DIAG_INVALID_FLOAT_SUFFIX.
 Float: HEX without exponent -> DIAG_HEX_FLOATING_CONSTANT_REQUIRES_EXPONENT;
 bytes = buf minus suffix. Integer: BINARY before C23 -> DIAG_C23_BINARY
 (Zig `if (c23) pre_c23_binary else c23_binary` inside `!c23`, so always
 C23_BINARY); bit-int suffix -> C23 ? DIAG_PRE_C23_BITINT : DIAG_BITINT_SUFFIX;
 OCTAL: prefix_len 2 and buf[1] != '\'' -> C2y ? DIAG_PRE_C2Y_OCTAL :
 DIAG_C2Y_OCTAL, else if C2y -> DIAG_C2Y_DEPRECATED_OCTAL; bytes = int part.
 getIntegerPart: '.' first -> ""; first digit not allowed -> BINARY/OCTAL
 invalid-digit (Ascii) or HEX invalid int suffix (whole rest); scan: '.'
 ends; p/P ends for HEX else invalid int suffix (from p); e/E: HEX continue,
 DECIMAL ends, BINARY/OCTAL invalid digit; 0-9 a-d A-D f F not allowed ->
 invalid digit (BINARY/OCTAL) or invalid int suffix from there; '\'' skips;
 anything else ends. getFracPart: BINARY/OCTAL with '.' -> invalid int
 suffix; else '.' then digits/separators. getExponent: e/E (DECIMAL) or p/P
 (non-HEX -> invalid float suffix), optional sign at index 1, digits and
 separators; no digit -> DIAG_EXPONENT_HAS_NO_DIGITS.
 Every error returns text_literal::PARSING_FAILED after reporting.
 @return? text_literal::PARSING_FAILED, compilation::FATAL_ERROR
*>
fn NumberLiteralResult? NumberLiteralParser.parse(&self)
{
	unreachable("stage 0 stub");
}

<*
 Zig `Parser.err`: emit_literal_diagnostic at `loc` / `expansion_locs`
 (skipped when the effective kind is OFF).
 @return? compilation::FATAL_ERROR
*>
fn void? NumberLiteralParser.err(&self, DiagnosticTemplate d, LiteralArg arg = { .kind = NONE })
{
	text_literal::emit_literal_diagnostic(self.comp, d, arg, self.loc, self.expansion_locs)!;
}
