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
// Stage 1 (11.1 `number-syntax`): every function is implemented.
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
	switch (c)
	{
		case '0'..'1': return true;
		case '2'..'7': return self != BINARY;
		case '8'..'9': return self == DECIMAL || self == HEX;
		case 'a'..'f':
		case 'A'..'F': return self == HEX;
		default: return false;
	}
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
	if (buf.len == 1) return DECIMAL;
	// tokenizer enforces that first byte is a decimal digit or period
	switch (buf[0])
	{
		case '.':
		case '1'..'9': return DECIMAL;
		case '0': break;
		default: unreachable("pp-number starts with a digit or period");
	}
	switch (buf[1])
	{
		case 'x':
		case 'X': return buf.len == 2 ? DECIMAL : HEX;
		case 'b':
		case 'B': return buf.len == 2 ? DECIMAL : BINARY;
		case 'o':
		case 'O': return buf.len == 2 ? DECIMAL : OCTAL;
		default:
			// A decimal floating point number that happens to start with zero.
			if (find_any(buf, "eE.")) return DECIMAL;
			// `0` with a valid suffix.
			if (try suffix_from_string(buf[1..], INT, allow_msvc_extensions)) return DECIMAL;
			return OCTAL;
	}
}

<*
 Zig `Prefix.stringLen`: BINARY 2; HEX 2; DECIMAL 0; OCTAL 2 if len > 2 and
 buf[1] is 'o', 'O' or '\'' (the digit separator counts as prefix so the next
 char is a digit), else 1.
*>
fn sz Prefix.string_len(self, String buf)
{
	switch (self)
	{
		case BINARY: return 2;
		// Includes digit separator `'` in the prefix so that the first
		// character after the prefix is a digit.
		case OCTAL: return buf.len > 2 && (buf[1] == 'o' || buf[1] == 'O' || buf[1] == '\'') ? 2 : 1;
		case DECIMAL: return 0;
		case HEX: return 2;
	}
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

<* One row of Zig's `Suffix.IntSuffixes` / `FloatSuffixes` (`Tuple`): `count` upper-case parts. *>
struct SuffixCandidate
{
	Suffix tag;
	String[3] parts;
	char count;
}

const SuffixCandidate[*] INT_SUFFIXES = {
	{ U, { "U", "", "" }, 1 },
	{ L, { "L", "", "" }, 1 },
	{ WB, { "WB", "", "" }, 1 },
	{ UL, { "U", "L", "" }, 2 },
	{ UWB, { "U", "WB", "" }, 2 },
	{ LL, { "LL", "", "" }, 1 },
	{ ULL, { "U", "LL", "" }, 2 },

	{ I8, { "I8", "", "" }, 1 },
	{ UI8, { "UI8", "", "" }, 1 },
	{ I16, { "I16", "", "" }, 1 },
	{ UI16, { "UI16", "", "" }, 1 },
	{ I32, { "I32", "", "" }, 1 },
	{ UI32, { "UI32", "", "" }, 1 },
	{ I64, { "I64", "", "" }, 1 },
	{ UI64, { "UI64", "", "" }, 1 },

	{ I, { "I", "", "" }, 1 },

	{ IWB, { "I", "WB", "" }, 2 },
	{ IU, { "I", "U", "" }, 2 },
	{ IL, { "I", "L", "" }, 2 },
	{ IUL, { "I", "U", "L" }, 3 },
	{ IUWB, { "I", "U", "WB" }, 3 },
	{ ILL, { "I", "LL", "" }, 2 },
	{ IULL, { "I", "U", "LL" }, 3 },
};

const SuffixCandidate[*] FLOAT_SUFFIXES = {
	{ F16, { "F16", "", "" }, 1 },
	{ F, { "F", "", "" }, 1 },
	{ L, { "L", "", "" }, 1 },
	{ W, { "W", "", "" }, 1 },
	{ F128, { "F128", "", "" }, 1 },
	{ Q, { "Q", "", "" }, 1 },
	{ BF16, { "BF16", "", "" }, 1 },
	{ F32, { "F32", "", "" }, 1 },
	{ F64, { "F64", "", "" }, 1 },
	{ F32X, { "F32x", "", "" }, 1 },
	{ F64X, { "F64x", "", "" }, 1 },
	{ D32, { "D32", "", "" }, 1 },
	{ D64, { "D64", "", "" }, 1 },
	{ D128, { "D128", "", "" }, 1 },
	{ D64X, { "D64x", "", "" }, 1 },

	{ I, { "I", "", "" }, 1 },
	{ IL, { "I", "L", "" }, 2 },
	{ IF16, { "I", "F16", "" }, 2 },
	{ IF, { "I", "F", "" }, 2 },
	{ IW, { "I", "W", "" }, 2 },
	{ IF128, { "I", "F128", "" }, 2 },
	{ IQ, { "I", "Q", "" }, 2 },
	{ IF32, { "I", "F32", "" }, 2 },
	{ IF64, { "I", "F64", "" }, 2 },
	{ IF32X, { "I", "F32x", "" }, 2 },
	{ IF64X, { "I", "F64x", "" }, 2 },
};

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
	if (buf.len == 0) return NONE;

	SuffixCandidate[] candidates = kind == FLOAT ? &FLOAT_SUFFIXES : &INT_SUFFIXES;
	char[4] scratch;
	foreach CANDIDATES: (&candidate : candidates)
	{
		sz len = 0;
		for (sz i = 0; i < candidate.count; i++) len += candidate.parts[i].len;
		if (len != buf.len) continue;

		for (sz i = 0; i < candidate.count; i++)
		{
			String part = candidate.parts[i];
			foreach (j, c : part) scratch[j] = c.to_lower();
			String lower = (String)scratch[:part.len];
			if (!contains(buf, part) && !contains(buf, lower)) continue CANDIDATES;
		}
		if (candidate.tag.is_msvc_extension() && !allow_msvc_extensions) continue;
		return candidate.tag;
	}
	return INVALID_SUFFIX~;
}

<* Zig `Suffix.isImaginary`: I, IL, IF, IU, IUL, ILL, IULL, IWB, IUWB, IF128, IQ, IW, IF16, IF32, IF64, IF32X, IF64X. *>
fn bool Suffix.is_imaginary(self)
{
	switch (self)
	{
		case I: case IL: case IF: case IU: case IUL: case ILL: case IULL: case IWB: case IUWB:
		case IF128: case IQ: case IW: case IF16: case IF32: case IF64: case IF32X: case IF64X:
			return true;
		default:
			return false;
	}
}

<*
 Zig `Suffix.isSignedInteger`: true for NONE, L, LL, I, IL, ILL, WB, IWB, I8,
 I16, I32, I64; false for the U* integer suffixes.
 @require !self.is_float_only() : "float suffixes are unreachable in Zig"
*>
fn bool Suffix.is_signed_integer(self)
{
	switch (self)
	{
		case NONE: case L: case LL: case I: case IL: case ILL: case WB: case IWB: case I8: case I16: case I32: case I64:
			return true;
		case U: case UL: case ULL: case IU: case IUL: case IULL: case UWB: case IUWB: case UI8: case UI16: case UI32: case UI64:
			return false;
		default:
			unreachable("float suffix has no integer signedness");
	}
}

<* Zig `Suffix.signedness`: SIGNED iff is_signed_integer. *>
fn Signedness Suffix.signedness(self)
{
	return self.is_signed_integer() ? SIGNED : UNSIGNED;
}

<* Zig `Suffix.isBitInt`: WB, UWB, IWB, IUWB. *>
fn bool Suffix.is_bit_int(self)
{
	switch (self)
	{
		case WB: case UWB: case IWB: case IUWB: return true;
		default: return false;
	}
}

<* Zig `Suffix.isFloat80`: W or IW. *>
fn bool Suffix.is_float80(self)
{
	return self == W || self == IW;
}

<* Zig `Suffix.isMSVCExtension`: I8, UI8, I16, UI16, I32, UI32, I64, UI64. *>
fn bool Suffix.is_msvc_extension(self)
{
	switch (self)
	{
		case I8: case UI8: case I16: case UI16: case I32: case UI32: case I64: case UI64: return true;
		default: return false;
	}
}

<*
 Helper (no Zig counterpart): the suffixes on which Zig isSignedInteger is
 unreachable: F, IF, F16, F128, IF128, Q, IQ, W, IW, IF16, F32, IF32, F64,
 IF64, F32X, IF32X, F64X, IF64X, D32, D64, D128, D64X, BF16.
*>
fn bool Suffix.is_float_only(self)
{
	switch (self)
	{
		case F: case IF: case F16: case F128: case IF128: case Q: case IQ: case W: case IW: case IF16:
		case F32: case IF32: case F64: case IF64: case F32X: case IF32X: case F64X: case IF64X:
		case D32: case D64: case D128: case D64X: case BF16:
			return true;
		default:
			return false;
	}
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
	String buf = self.literal;
	bool allow_fixed_size_int_suffixes = self.comp.langopts.allow_fixed_sized_int_suffixes();
	Prefix prefix = prefix_from_string(buf, allow_fixed_size_int_suffixes);
	sz prefix_len = prefix.string_len(buf);
	String after_prefix = buf[prefix_len..];

	String int_part = self.get_integer_part(after_prefix, prefix)!;
	String after_int = after_prefix[int_part.len..];

	String frac = self.get_frac_part(after_int, prefix)!;
	String after_frac = after_int[frac.len..];

	String exponent = self.get_exponent(after_frac, prefix)!;
	String suffix_str = after_frac[exponent.len..];

	bool is_float = exponent.len > 0 || frac.len > 0;
	Suffix? suffix = suffix_from_string(suffix_str, is_float ? FLOAT : INT, allow_fixed_size_int_suffixes);
	if (catch suffix)
	{
		self.err(is_float ? DIAG_INVALID_FLOAT_SUFFIX : DIAG_INVALID_INT_SUFFIX, text_literal::arg_str(suffix_str))!;
		return text_literal::PARSING_FAILED~;
	}
	if (suffix.is_float80() && @catch(float80_type(self.comp)))
	{
		self.err(DIAG_INVALID_FLOAT_SUFFIX, text_literal::arg_str(suffix_str))!;
		return text_literal::PARSING_FAILED~;
	}

	if (is_float)
	{
		assert(prefix == HEX || prefix == DECIMAL);
		if (prefix == HEX && exponent.len == 0)
		{
			self.err(DIAG_HEX_FLOATING_CONSTANT_REQUIRES_EXPONENT)!;
			return text_literal::PARSING_FAILED~;
		}
		return { .bytes = buf[:buf.len - suffix_str.len], .is_float = true, .prefix = prefix, .suffix = suffix };
	}

	bool c23 = self.comp.langopts.standard.at_least(C23);
	// Zig: `if (prefix == .binary and !c23) err(if (c23) pre_c23_binary else c23_binary)`.
	if (prefix == BINARY && !c23) self.err(DIAG_C23_BINARY)!;
	if (suffix.is_bit_int()) self.err(c23 ? DIAG_PRE_C23_BITINT : DIAG_BITINT_SUFFIX)!;
	if (prefix == OCTAL)
	{
		bool c2y = self.comp.langopts.standard.at_least(C2Y);
		if (prefix_len == 2 && buf[1] != '\'')
		{
			self.err(c2y ? DIAG_PRE_C2Y_OCTAL : DIAG_C2Y_OCTAL)!;
		}
		else if (c2y)
		{
			self.err(DIAG_C2Y_DEPRECATED_OCTAL)!;
		}
	}
	return { .bytes = int_part, .is_float = false, .prefix = prefix, .suffix = suffix };
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

<*
 Zig `Parser.getIntegerPart`.
 @require buf.len > 0
 @return? text_literal::PARSING_FAILED, compilation::FATAL_ERROR
*>
fn String? NumberLiteralParser.get_integer_part(&self, String buf, Prefix prefix)
{
	if (buf[0] == '.') return "";

	if (!prefix.digit_allowed(buf[0]))
	{
		switch (prefix)
		{
			case BINARY: self.err(DIAG_INVALID_BINARY_DIGIT, text_literal::arg_ascii(text_literal::ascii(buf[0])))!;
			case OCTAL: self.err(DIAG_INVALID_OCTAL_DIGIT, text_literal::arg_ascii(text_literal::ascii(buf[0])))!;
			case HEX: self.err(DIAG_INVALID_INT_SUFFIX, text_literal::arg_str(buf))!;
			case DECIMAL: unreachable("decimal literal starts with a digit");
		}
		return text_literal::PARSING_FAILED~;
	}

	for (sz idx = 1; idx < buf.len; idx++)
	{
		char c = buf[idx];
		switch (c)
		{
			case '.':
				return buf[:idx];
			case 'p':
			case 'P':
				if (prefix == HEX) return buf[:idx];
				self.err(DIAG_INVALID_INT_SUFFIX, text_literal::arg_str(buf[idx..]))!;
				return text_literal::PARSING_FAILED~;
			case 'e':
			case 'E':
				switch (prefix)
				{
					case HEX: continue;
					case DECIMAL: return buf[:idx];
					case BINARY: self.err(DIAG_INVALID_BINARY_DIGIT, text_literal::arg_ascii(text_literal::ascii(c)))!;
					case OCTAL: self.err(DIAG_INVALID_OCTAL_DIGIT, text_literal::arg_ascii(text_literal::ascii(c)))!;
				}
				return text_literal::PARSING_FAILED~;
			case '0'..'9':
			case 'a'..'d':
			case 'A'..'D':
			case 'f':
			case 'F':
				if (!prefix.digit_allowed(c))
				{
					switch (prefix)
					{
						case BINARY: self.err(DIAG_INVALID_BINARY_DIGIT, text_literal::arg_ascii(text_literal::ascii(c)))!;
						case OCTAL: self.err(DIAG_INVALID_OCTAL_DIGIT, text_literal::arg_ascii(text_literal::ascii(c)))!;
						case DECIMAL:
						case HEX: self.err(DIAG_INVALID_INT_SUFFIX, text_literal::arg_str(buf[idx..]))!;
					}
					return text_literal::PARSING_FAILED~;
				}
			case '\'':
				break;
			default:
				return buf[:idx];
		}
	}
	return buf;
}

<*
 Zig `Parser.getFracPart`.
 @return? text_literal::PARSING_FAILED, compilation::FATAL_ERROR
*>
fn String? NumberLiteralParser.get_frac_part(&self, String buf, Prefix prefix)
{
	if (buf.len == 0 || buf[0] != '.') return "";
	if (prefix == BINARY || prefix == OCTAL)
	{
		self.err(DIAG_INVALID_INT_SUFFIX, text_literal::arg_str(buf))!;
		return text_literal::PARSING_FAILED~;
	}
	for (sz idx = 1; idx < buf.len; idx++)
	{
		char c = buf[idx];
		if (c == '\'') continue;
		if (!prefix.digit_allowed(c)) return buf[:idx];
	}
	return buf;
}

<*
 Zig `Parser.getExponent`.
 @return? text_literal::PARSING_FAILED, compilation::FATAL_ERROR
*>
fn String? NumberLiteralParser.get_exponent(&self, String buf, Prefix prefix)
{
	if (buf.len == 0) return "";

	switch (buf[0])
	{
		case 'e':
		case 'E':
			assert(prefix == DECIMAL);
		case 'p':
		case 'P':
			if (prefix != HEX)
			{
				self.err(DIAG_INVALID_FLOAT_SUFFIX, text_literal::arg_str(buf))!;
				return text_literal::PARSING_FAILED~;
			}
		default:
			return "";
	}
	sz end = buf.len;
	for (sz idx = 1; idx < buf.len; idx++)
	{
		char c = buf[idx];
		if (idx == 1 && (c == '+' || c == '-')) continue;
		if (c == '\'' || (c >= '0' && c <= '9')) continue;
		end = idx;
		break;
	}
	String exponent = buf[:end];
	if (!find_any(exponent, "0123456789"))
	{
		self.err(DIAG_EXPONENT_HAS_NO_DIGITS)!;
		return text_literal::PARSING_FAILED~;
	}
	return exponent;
}

// ---------------------------------------------------------------------------
// Helpers (Zig std.mem)

<* Zig `mem.findAny(u8, buf, set) != null`. *>
fn bool find_any(String buf, String set)
{
	foreach (c : buf)
	{
		foreach (s : set) if (c == s) return true;
	}
	return false;
}

<* Zig `mem.find(u8, haystack, needle) != null`. *>
fn bool contains(String haystack, String needle)
{
	if (needle.len > haystack.len) return false;
	for (sz i = 0; i + needle.len <= haystack.len; i++)
	{
		if (haystack[i:needle.len] == needle) return true;
	}
	return false;
}
