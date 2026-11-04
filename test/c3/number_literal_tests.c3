// Tests for plan 11.1 `number-syntax`: src/c3/number_literal.c3 (port of
// src/aro/Tokenizer/number_literal.zig).
//
// Provenance of expected values:
// - [fixture] the literal and diagnostic text appear in a test/cases file
//   (numbers.c, c2y octal.c, __float80 clang.c, _BitInt.c, binary literal.c,
//   msvc integer suffixes.c, c23 digit separators.c), with the same
//   langopts the fixture's manifest selects.
// - [source] hand-derived from number_literal.zig; no Zig executable was run.
module number_literal_tests;
import aro::number_literal, aro::text_literal;
import aro::compilation, aro::diagnostics, aro::source, aro::target, aro::type_store, aro::lang_opts;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

struct Ctx
{
	Compilation* comp;
	Diagnostics* d;
	Location loc;
}

<* Run the body with a compilation for `triple` whose diagnostics go to a list. *>
macro @with_ctx(String triple; @body(Ctx* c))
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, null, &d);
		comp.target = target::parse_triple(triple, HOST)!!;
		comp.langopts.set_target_options(&comp.target);
		type_store::init_named_types(&comp);
		Source src = comp.add_source_from_buffer("lit.c", "x\n")!!;
		Ctx c = { .comp = &comp, .d = &d, .loc = { .id = src.id, .byte_offset = 0, .line = 1 } };
		@body(&c);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn NumberLiteralResult? Ctx.parse(&self, String lit)
{
	NumberLiteralParser p = { .comp = self.comp, .literal = lit, .loc = self.loc };
	return p.parse();
}

<* Parses without any diagnostic. *>
fn void Ctx.ok(&self, String lit, Prefix prefix, Suffix suffix, String bytes, bool is_float)
{
	sz before = self.d.messages.len();
	NumberLiteralResult r = self.parse(lit)!!;
	check(self.d.messages.len(), before);
	assert(r.prefix == prefix, "%s: prefix %s", lit, r.prefix);
	assert(r.suffix == suffix, "%s: suffix %s", lit, r.suffix);
	test::eq(r.bytes, bytes);
	assert(r.is_float == is_float, "%s: is_float", lit);
}

<* Fails with PARSING_FAILED after exactly one error `msg`. *>
fn void Ctx.fails(&self, String lit, String msg)
{
	sz before = self.d.messages.len();
	assert(@catch(self.parse(lit)) == text_literal::PARSING_FAILED, "%s should fail", lit);
	check(self.d.messages.len(), before + 1);
	test::eq(self.d.messages[before].text, msg);
	assert(self.d.messages[before].effective_kind == ERROR);
}

<* Succeeds with exactly one diagnostic `msg` of effective kind `kind`. *>
fn NumberLiteralResult Ctx.diag(&self, String lit, String msg, MessageKind kind)
{
	sz before = self.d.messages.len();
	NumberLiteralResult r = self.parse(lit)!!;
	check(self.d.messages.len(), before + 1);
	test::eq(self.d.messages[before].text, msg);
	assert(self.d.messages[before].effective_kind == kind, "%s: kind %s", lit, self.d.messages[before].effective_kind);
	return r;
}

fn void prefix_digit_allowed() @test
{
	// [source] Prefix.digitAllowed
	assert(Prefix.BINARY.digit_allowed('1') && !Prefix.BINARY.digit_allowed('2'));
	assert(Prefix.OCTAL.digit_allowed('7') && !Prefix.OCTAL.digit_allowed('8'));
	assert(Prefix.DECIMAL.digit_allowed('9') && !Prefix.DECIMAL.digit_allowed('a'));
	assert(Prefix.HEX.digit_allowed('F') && Prefix.HEX.digit_allowed('e') && !Prefix.HEX.digit_allowed('g'));
	assert(!Prefix.HEX.digit_allowed('\''));
	check(Prefix.HEX.base, 16);
}

fn void prefix_from_string_and_len() @test
{
	// [source] Prefix.fromString / stringLen
	assert(number_literal::prefix_from_string("0", false) == DECIMAL);
	assert(number_literal::prefix_from_string("0x", false) == DECIMAL);
	assert(number_literal::prefix_from_string("0x1", false) == HEX);
	assert(number_literal::prefix_from_string("0B1", false) == BINARY);
	assert(number_literal::prefix_from_string("0o7", false) == OCTAL);
	assert(number_literal::prefix_from_string("017", false) == OCTAL);
	assert(number_literal::prefix_from_string("019.5", false) == DECIMAL);
	assert(number_literal::prefix_from_string("0e1", false) == DECIMAL);
	assert(number_literal::prefix_from_string("0ull", false) == DECIMAL);
	assert(number_literal::prefix_from_string("0i8", false) == OCTAL);
	assert(number_literal::prefix_from_string("0i8", true) == DECIMAL);
	assert(number_literal::prefix_from_string(".5", false) == DECIMAL);
	check(Prefix.OCTAL.string_len("017"), 1);
	check(Prefix.OCTAL.string_len("0o17"), 2);
	check(Prefix.OCTAL.string_len("0'17"), 2);
	check(Prefix.OCTAL.string_len("0'"), 1);
	check(Prefix.BINARY.string_len("0b1"), 2);
	check(Prefix.HEX.string_len("0x1"), 2);
	check(Prefix.DECIMAL.string_len("12"), 0);
}

fn void suffix_from_string() @test
{
	// [source] Suffix.fromString: parts match in either case, in any order.
	assert(number_literal::suffix_from_string("", INT, false)!! == NONE);
	assert(number_literal::suffix_from_string("u", INT, false)!! == U);
	assert(number_literal::suffix_from_string("lu", INT, false)!! == UL);
	assert(number_literal::suffix_from_string("Ul", INT, false)!! == UL);
	assert(number_literal::suffix_from_string("uL", INT, false)!! == UL);
	assert(number_literal::suffix_from_string("LLu", INT, false)!! == ULL);
	assert(number_literal::suffix_from_string("ull", INT, false)!! == ULL);
	assert(@catch(number_literal::suffix_from_string("lL", INT, false)) == number_literal::INVALID_SUFFIX);
	assert(number_literal::suffix_from_string("wb", INT, false)!! == WB);
	assert(number_literal::suffix_from_string("uwb", INT, false)!! == UWB);
	assert(number_literal::suffix_from_string("iull", INT, false)!! == IULL);
	assert(number_literal::suffix_from_string("i", INT, false)!! == I);
	assert(@catch(number_literal::suffix_from_string("i8", INT, false)) == number_literal::INVALID_SUFFIX);
	assert(number_literal::suffix_from_string("i8", INT, true)!! == I8);
	assert(number_literal::suffix_from_string("ui64", INT, true)!! == UI64);
	assert(@catch(number_literal::suffix_from_string("f", INT, false)) == number_literal::INVALID_SUFFIX);

	assert(number_literal::suffix_from_string("f", FLOAT, false)!! == F);
	assert(number_literal::suffix_from_string("F16", FLOAT, false)!! == F16);
	assert(number_literal::suffix_from_string("bf16", FLOAT, false)!! == BF16);
	assert(number_literal::suffix_from_string("f32x", FLOAT, false)!! == F32X);
	assert(number_literal::suffix_from_string("F32x", FLOAT, false)!! == F32X);
	// "F32X" contains neither "F32x" nor "f32x".
	assert(@catch(number_literal::suffix_from_string("F32X", FLOAT, false)) == number_literal::INVALID_SUFFIX);
	assert(number_literal::suffix_from_string("fi", FLOAT, false)!! == IF);
	assert(number_literal::suffix_from_string("if", FLOAT, false)!! == IF);
	assert(number_literal::suffix_from_string("iw", FLOAT, false)!! == IW);
	assert(number_literal::suffix_from_string("q", FLOAT, false)!! == Q);
	assert(@catch(number_literal::suffix_from_string("df", FLOAT, false)) == number_literal::INVALID_SUFFIX);
	assert(@catch(number_literal::suffix_from_string("dd", FLOAT, false)) == number_literal::INVALID_SUFFIX);
	assert(number_literal::suffix_from_string("D64x", FLOAT, false)!! == D64X);
	assert(@catch(number_literal::suffix_from_string("u", FLOAT, false)) == number_literal::INVALID_SUFFIX);
}

fn void suffix_predicates() @test
{
	// [source] isImaginary / isSignedInteger / signedness / isBitInt / isFloat80 / isMSVCExtension
	foreach (s : Suffix::values)
	{
		bool imag = s.is_imaginary();
		switch (s)
		{
			case I: case IL: case IF: case IU: case IUL: case ILL: case IULL: case IWB: case IUWB:
			case IF128: case IQ: case IW: case IF16: case IF32: case IF64: case IF32X: case IF64X:
				assert(imag);
			default:
				assert(!imag, "%s", s);
		}
	}
	assert(Suffix.NONE.is_signed_integer() && Suffix.IWB.is_signed_integer() && Suffix.I64.is_signed_integer());
	assert(!Suffix.UI8.is_signed_integer() && !Suffix.IUWB.is_signed_integer());
	assert(Suffix.ULL.signedness() == UNSIGNED && Suffix.LL.signedness() == SIGNED);
	assert(Suffix.WB.is_bit_int() && Suffix.IUWB.is_bit_int() && !Suffix.L.is_bit_int());
	assert(Suffix.W.is_float80() && Suffix.IW.is_float80() && !Suffix.F.is_float80());
	assert(Suffix.UI32.is_msvc_extension() && !Suffix.I.is_msvc_extension());
	assert(Suffix.BF16.is_float_only() && Suffix.D64X.is_float_only() && !Suffix.I.is_float_only() && !Suffix.UWB.is_float_only());
	// is_float_only is exactly the complement of the integer suffix set.
	int float_only = 0;
	foreach (s : Suffix::values) if (s.is_float_only()) float_only++;
	check(float_only, Suffix::len - 24);
}

fn void numbers_fixture() @test
{
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		// [fixture] test/cases/numbers.c (default standard, no extra flags).
		c.fails("0b", "invalid suffix 'b' on integer constant");
		c.fails("0x", "invalid suffix 'x' on integer constant");
		c.fails("0b12", "invalid digit '2' in binary constant");
		c.fails("0b1.2", "invalid suffix '.2' on integer constant");
		c.ok("019.5", DECIMAL, NONE, "019.5", true);
		c.fails("0x12.e", "hexadecimal floating constant requires an exponent");
		c.fails("0128", "invalid digit '8' in octal constant");
		c.ok("0iull", DECIMAL, IULL, "0", false);
		c.fails("1e", "exponent has no digits");
		c.fails("0x1p", "exponent has no digits");
		c.fails("123LLuf", "invalid suffix 'LLuf' on integer constant");
		c.ok("12e+2f", DECIMAL, F, "12e+2", true);
		c.ok("12E-2f", DECIMAL, F, "12E-2", true);
		c.ok("0x12P+2", HEX, NONE, "0x12P+2", true);
		c.ok("0x12p-2", HEX, NONE, "0x12p-2", true);
		c.fails("0xE+0xC", "invalid suffix '+0xC' on integer constant");
		c.ok("0xE", HEX, NONE, "E", false);
		c.ok("0x1.ep-1", HEX, NONE, "0x1.ep-1", true);
		c.ok("0x1.eP-1", HEX, NONE, "0x1.eP-1", true);
		c.ok("0x1.Ep-1", HEX, NONE, "0x1.Ep-1", true);
		c.ok("0x1.EP-1", HEX, NONE, "0x1.EP-1", true);
		c.fails("1.ep-1", "exponent has no digits");
		c.fails("1.pp-1", "invalid suffix 'pp-1' on floating constant");
	};
}

fn void more_syntax() @test
{
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		// [source] integer forms
		c.ok("0", DECIMAL, NONE, "0", false);
		c.ok("0u", DECIMAL, U, "0", false);
		c.ok("123", DECIMAL, NONE, "123", false);
		c.ok("42ul", DECIMAL, UL, "42", false);
		c.ok("017", OCTAL, NONE, "17", false);
		c.ok("0x1e5", HEX, NONE, "1e5", false);
		c.ok("0XdeadBEEFull", HEX, ULL, "deadBEEF", false);
		c.ok("0b101", BINARY, NONE, "101", false); // c23_binary is OFF without -Wpedantic
		c.ok("1'000'000", DECIMAL, NONE, "1'000'000", false);
		c.ok("0x1'f", HEX, NONE, "1'f", false);
		c.fails("08", "invalid digit '8' in octal constant");
		c.fails("0b2", "invalid digit '2' in binary constant");
		c.fails("0be", "invalid digit 'e' in binary constant");
		c.fails("0b1e", "invalid digit 'e' in binary constant");
		c.fails("07e", "exponent has no digits"); // "eE." in buf -> DECIMAL prefix
		c.fails("0b1p3", "invalid suffix 'p3' on integer constant");
		c.fails("12p3", "invalid suffix 'p3' on integer constant");
		c.fails("0xg", "invalid suffix 'g' on integer constant");
		c.fails("0x1g", "invalid suffix 'g' on integer constant");
		c.fails("12a", "invalid suffix 'a' on integer constant");
		c.fails("0'", "invalid digit ''' in octal constant");
		c.fails("1i8", "invalid suffix 'i8' on integer constant"); // MSVC suffixes need ms extensions
		c.fails("0i8", "invalid digit 'i' in octal constant");
		c.fails("0o8", "invalid digit '8' in octal constant");
		c.fails("017.5e", "exponent has no digits");

		// [source] floating forms
		c.ok(".5", DECIMAL, NONE, ".5", true);
		c.ok("1.", DECIMAL, NONE, "1.", true);
		c.ok("1e10", DECIMAL, NONE, "1e10", true);
		c.ok("1'0.2'5e1'0L", DECIMAL, L, "1'0.2'5e1'0", true);
		c.ok("1.0f16", DECIMAL, F16, "1.0", true);
		c.ok("1.0bf16", DECIMAL, BF16, "1.0", true);
		c.ok("1.0F128", DECIMAL, F128, "1.0", true);
		c.ok("1.0f32x", DECIMAL, F32X, "1.0", true);
		c.ok("1.0if", DECIMAL, IF, "1.0", true);
		c.ok("2.0fi", DECIMAL, IF, "2.0", true);
		c.fails("1.0dd", "invalid suffix 'dd' on floating constant");
		c.ok("0x1.8p3f16", HEX, F16, "0x1.8p3", true);
		c.ok("1.0w", DECIMAL, W, "1.0", true); // x86_64 GNU has __float80
		c.ok("2.0iw", DECIMAL, IW, "2.0", true);
		c.fails("1.0F32X", "invalid suffix 'F32X' on floating constant");
		c.fails("1.0u", "invalid suffix 'u' on floating constant");
		c.fails("1e+", "exponent has no digits");
		c.fails("1e'", "exponent has no digits");
		c.fails("0x1.8", "hexadecimal floating constant requires an exponent");
	};
}

fn void float80_suffix() @test
{
	// [fixture] test/cases/__float80 clang.c (--emulate=clang)
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		c.comp.langopts.emulate = CLANG;
		c.fails("1.0w", "invalid suffix 'w' on floating constant");
		c.fails("2.0iw", "invalid suffix 'iw' on floating constant");
	};
	// [source] no __float80 on aarch64
	@with_ctx("aarch64-linux-gnu"; Ctx* c)
	{
		c.fails("1.0W", "invalid suffix 'W' on floating constant");
	};
}

fn void binary_and_bitint_gates() @test
{
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		// [fixture] binary literal.c (-Wpedantic -std=c17)
		c.comp.langopts.standard = C17;
		c.d.set("pedantic", WARNING)!!;
		c.diag("0b11", "binary integer literals are a C23 extension", WARNING);
		// [fixture] _BitInt.c (-std=c17 -Wpedantic)
		NumberLiteralResult r = c.diag("2wb", "'_BitInt' suffix for literals is a C23 extension", WARNING);
		assert(r.suffix == WB);
		r = c.diag("3Uwb", "'_BitInt' suffix for literals is a C23 extension", WARNING);
		assert(r.suffix == UWB);
		// [source] C23: binary is silent, the bitint compat warning is OFF.
		c.comp.langopts.standard = C23;
		c.ok("0b11", BINARY, NONE, "11", false);
		c.ok("0wb", DECIMAL, WB, "0", false);
		c.d.set("pre-c23-compat", WARNING)!!;
		c.diag("0uwb", "'_BitInt' suffix for literals is incompatible with C standards before C23", WARNING);
		// [fixture] c23 digit separators.c
		c.ok("0b1001'0110", BINARY, NONE, "1001'0110", false);
	};
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		// [source] bitint_suffix is a WARNING (C23 extension) even without -Wpedantic.
		c.comp.langopts.standard = C17;
		c.diag("1wb", "'_BitInt' suffix for literals is a C23 extension", WARNING);
	};
}

fn void octal_gates() @test
{
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		// [fixture] c2y octal.c (-std=c2y -Wpre-c2y-compat)
		c.comp.langopts.standard = C2Y;
		c.d.set("pre-c2y-compat", WARNING)!!;
		NumberLiteralResult r = c.diag("0o77", "octal integer literals are incompatible with C standards before C2y", WARNING);
		assert(r.prefix == OCTAL);
		test::eq(r.bytes, "77");
		r = c.diag("0'77", "octal literals without a '0o' prefix are deprecated", WARNING);
		assert(r.prefix == OCTAL);
		test::eq(r.bytes, "77");
		// [source] plain octal in C2y is deprecated too
		c.diag("017", "octal literals without a '0o' prefix are deprecated", WARNING);
	};
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		// [source] before C2y: 0o is a C2y extension (OFF unless -Wpedantic)
		c.ok("0o17", OCTAL, NONE, "17", false);
		c.ok("017", OCTAL, NONE, "17", false);
		c.d.set("pedantic", WARNING)!!;
		c.diag("0O17", "octal integer literals are a C2y extension", WARNING);
	};
}

fn void msvc_suffixes() @test
{
	@with_ctx("x86_64-linux-gnu"; Ctx* c)
	{
		// [fixture] msvc integer suffixes.c (--emulate=msvc)
		c.comp.langopts.emulate = MSVC;
		c.ok("0i8", DECIMAL, I8, "0", false);
		c.ok("2ui8", DECIMAL, UI8, "2", false);
		c.ok("3i16", DECIMAL, I16, "3", false);
		c.ok("4ui16", DECIMAL, UI16, "4", false);
		c.ok("5i32", DECIMAL, I32, "5", false);
		c.ok("6ui32", DECIMAL, UI32, "6", false);
		c.ok("7i64", DECIMAL, I64, "7", false);
		c.ok("8ui64", DECIMAL, UI64, "8", false);
		c.ok("256ui8", DECIMAL, UI8, "256", false);
	};
}
