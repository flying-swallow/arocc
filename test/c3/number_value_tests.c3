// Tests for aro::number_value (plan 11 agent 11.2). Inputs are constructed
// NumberLiteralResult / Prefix / Suffix values, so these tests do not need
// number_literal's syntax parser (11.1); the end-to-end path through
// NumberLiteralParser is in number_value_manual_tests.c3.
//
// Expected values are labelled with their origin:
//   [fixture X]  test/cases/X (types via _Static_assert/typeof, diagnostics
//                from the manifest, values from the AST golden test/cases/ast/X)
//   [source]     derived by hand from Parser.zig fixedSizeInt / bitInt /
//                parseFloat / getMSVCIntSuffixType and Preprocessor/Parser.zig
//                primaryExpr, plus IEEE-754 encodings. No Zig executable was run.
module number_value_tests;
import aro::number_value, aro::number_literal, aro::value, aro::value_interner, aro::float_value, aro::bigint;
import aro::compilation, aro::diagnostics, aro::target, aro::type_store, aro::lang_opts;
import std::io, std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const Host HOST = { X86_64, LINUX, GNU };

<* Run the body with a compilation for `triple` (emulation `emu`). *>
macro @with_comp(String triple, Compiler emu = NO; @body(Compilation* comp))
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
		comp.langopts.set_emulated_compiler(emu);
		type_store::init_named_types(&comp);
		@body(&comp);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn NumberValue int_lit(Compilation* comp, Prefix prefix, String bytes, Suffix suffix)
{
	return number_value::number_value(comp, { .bytes = bytes, .is_float = false, .prefix = prefix, .suffix = suffix });
}

fn NumberValue float_lit(Compilation* comp, String bytes, Suffix suffix)
{
	return number_value::number_value(comp, { .bytes = bytes, .is_float = true, .prefix = DECIMAL, .suffix = suffix });
}

fn void expect_diags(NumberValue v, NumberValueDiag[] want)
{
	check(v.diags.len, want.len);
	foreach (i, w : want) assert(v.diags.items[i] == w);
}

fn ulong u64_of(Compilation* comp, Value v) => v.to_u64(comp)!!;

fn KeyFloat float_of(Compilation* comp, Value v)
{
	InternerKey k = comp.interner.get(v.ref());
	assert(k.tag == FLOAT);
	return k.float_val;
}

fn KeyComplex complex_of(Compilation* comp, Value v)
{
	InternerKey k = comp.interner.get(v.ref());
	assert(k.tag == COMPLEX);
	return k.complex_val;
}

fn void expect_bit_int(Compilation* comp, QualType qt, uint bits, Signedness s)
{
	Type ty = qt.base(comp).ty;
	assert(ty.tag == BIT_INT);
	check(ty.bit_int.bits, bits);
	assert(ty.bit_int.signedness == s);
}

fn void expect_complex_of(Compilation* comp, QualType qt, QualType elem)
{
	Type ty = qt.base(comp).ty;
	assert(ty.tag == COMPLEX);
	assert(ty.complex == elem);
}

// ---------------------------------------------------------------------------
// Integer literal types

fn void implicitly_unsigned_promotion() @test
{
	// [fixture integer literal promotion warning clang.c]
	@with_comp("x86_64-linux-gnu", CLANG; Compilation* comp)
	{
		NumberValue v = int_lit(comp, DECIMAL, "18446744073709550592", NONE);
		expect_diags(v, { IMPLICITLY_UNSIGNED_LITERAL });
		assert(v.qt == type_store::ULONG_LONG && v.literal_qt == v.qt && !v.is_imaginary);
		check(u64_of(comp, v.val), 18446744073709550592UL);
		assert(v.literal_val.opt_ref == v.val.opt_ref);
	};
	// [fixture integer literal promotion warning gcc 64.c]
	@with_comp("x86_64-linux-gnu", GCC; Compilation* comp)
	{
		NumberValue v = int_lit(comp, DECIMAL, "18446744073709550592", NONE);
		expect_diags(v, { IMPLICITLY_UNSIGNED_LITERAL });
		assert(v.qt == type_store::INT128);
		check(u64_of(comp, v.val), 18446744073709550592UL);
	};
	// [fixture integer literal promotion warning gcc 32.c]
	@with_comp("riscv32-linux-gnu", GCC; Compilation* comp)
	{
		NumberValue v = int_lit(comp, DECIMAL, "18446744073709550592", NONE);
		expect_diags(v, { IMPLICITLY_UNSIGNED_LITERAL });
		assert(v.qt == type_store::LONG_LONG);
	};
}

fn void implicitly_unsigned_literal_fixture() @test
{
	// [fixture implicitly unsigned literal.c] (emulate clang)
	@with_comp("x86_64-linux-gnu", CLANG; Compilation* comp)
	{
		NumberValue v = int_lit(comp, DECIMAL, "9223372036854775808", LL);
		expect_diags(v, { IMPLICITLY_UNSIGNED_LITERAL });
		assert(v.qt == type_store::ULONG_LONG); // "lhs should be unsigned"
		// Hex literals never warn: 0xFFFFFFFFFFFFFFFF is unsigned long on LP64 [source].
		v = int_lit(comp, HEX, "FFFFFFFFFFFFFFFF", NONE);
		expect_diags(v, {});
		assert(v.qt == type_store::ULONG);
		check(u64_of(comp, v.val), ulong::max);
		v = int_lit(comp, HEX, "FFFFFFFFFFFFFFFE", NONE);
		assert(v.qt == type_store::ULONG);
	};
}

fn void decimal_and_hex_candidates() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		// [fixture enum sizes linux.c, AST golden] int_literal: 'long' (value: 2147483648)
		NumberValue v = int_lit(comp, DECIMAL, "2147483648", NONE);
		assert(v.qt == type_store::LONG);
		check(u64_of(comp, v.val), 2147483648);
		// [fixture enum sizes linux.c, AST golden] int_literal: 'long' (value: 4294967295)
		v = int_lit(comp, DECIMAL, "4294967295", NONE);
		assert(v.qt == type_store::LONG);
		// [fixture enum sizes linux.c, AST golden] 'unsigned long long' (value: 18446744073709551615)
		v = int_lit(comp, DECIMAL, "18446744073709551615", ULL);
		expect_diags(v, {});
		assert(v.qt == type_store::ULONG_LONG);
		check(u64_of(comp, v.val), ulong::max);
		// [fixture fixed size integer constants x86_64-linux-gnu.c] 4294967295U is unsigned
		v = int_lit(comp, DECIMAL, "4294967295", U);
		assert(v.qt == type_store::UINT);
		v = int_lit(comp, DECIMAL, "9223372036854775807", LL);
		assert(v.qt == type_store::LONG_LONG);
		expect_diags(v, {});
		// [source] hex/octal/binary walk int, uint, long, ulong, ...
		v = int_lit(comp, HEX, "7FFFFFFF", NONE);
		assert(v.qt == type_store::INT);
		v = int_lit(comp, HEX, "80000000", NONE);
		assert(v.qt == type_store::UINT);
		v = int_lit(comp, HEX, "100000000", NONE);
		assert(v.qt == type_store::LONG);
		v = int_lit(comp, OCTAL, "777", NONE);
		assert(v.qt == type_store::INT);
		check(u64_of(comp, v.val), 511);
		v = int_lit(comp, HEX, "ff", UL);
		assert(v.qt == type_store::ULONG);
		check(u64_of(comp, v.val), 255);
		// L suffix skips int even for small values
		v = int_lit(comp, DECIMAL, "1", L);
		assert(v.qt == type_store::LONG);
		// [fixture c23 digit separators.c] 0b1001'0110 == 150
		v = int_lit(comp, BINARY, "1001'0110", NONE);
		assert(v.qt == type_store::INT);
		check(u64_of(comp, v.val), 150);
	};
	// [source] LLP64: decimal 2147483648 skips 32-bit long.
	@with_comp("x86_64-windows-msvc", MSVC; Compilation* comp)
	{
		NumberValue v = int_lit(comp, DECIMAL, "2147483648", NONE);
		assert(v.qt == type_store::LONG_LONG);
		v = int_lit(comp, HEX, "80000000", NONE);
		assert(v.qt == type_store::UINT);
		v = int_lit(comp, HEX, "100000000", NONE);
		assert(v.qt == type_store::LONG_LONG);
	};
}

fn void literal_overflow() @test
{
	// [source] fixedSizeInt: overflow -> int_literal_too_big, unsigned long long,
	// u64 wraparound value, no implicitly-unsigned warning.
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		NumberValue v = int_lit(comp, DECIMAL, "18446744073709551616", NONE);
		expect_diags(v, { INT_LITERAL_TOO_BIG });
		assert(v.qt == type_store::ULONG_LONG);
		check(u64_of(comp, v.val), 0);
		v = int_lit(comp, DECIMAL, "99999999999999999999", NONE);
		expect_diags(v, { INT_LITERAL_TOO_BIG });
		check(u64_of(comp, v.val), 7766279631452241919);
		v = int_lit(comp, HEX, "1'0000'0000'0000'0000", U);
		expect_diags(v, { INT_LITERAL_TOO_BIG });
		check(u64_of(comp, v.val), 0);
		test::eq(NumberValueDiag.INT_LITERAL_TOO_BIG.template().fmt,
			"integer literal is too large to be represented in any integer type");
		test::eq(NumberValueDiag.IMPLICITLY_UNSIGNED_LITERAL.template().fmt,
			"integer literal is too large to be represented in a signed integer type, interpreting as unsigned");
	};
}

fn void digit_loop() @test
{
	// [source] accumulate_u64
	DigitsValue d = number_value::accumulate_u64("1'2", 10);
	check(d.val, 12);
	assert(!d.overflow);
	d = number_value::accumulate_u64("FFFFFFFFFFFFFFFF", 16);
	assert(d.val == ulong::max && !d.overflow);
	d = number_value::accumulate_u64("18446744073709551615", 10);
	assert(d.val == ulong::max && !d.overflow);
	d = number_value::accumulate_u64("18446744073709551616", 10);
	assert(d.val == 0 && d.overflow);
	d = number_value::accumulate_u64("", 10);
	assert(d.val == 0 && !d.overflow);
	d = number_value::accumulate_u64("aBc", 16);
	check(d.val, 0xABC);
}

// ---------------------------------------------------------------------------
// MSVC fixed-size suffixes

fn void msvc_suffixes() @test
{
	// [fixture clang integer suffixes x86_64-linux-gnu.c]
	@with_comp("x86_64-linux-gnu", CLANG; Compilation* comp)
	{
		assert(int_lit(comp, DECIMAL, "0", I8).qt == type_store::CHAR);
		assert(int_lit(comp, DECIMAL, "1", UI8).qt == type_store::UCHAR);
		assert(int_lit(comp, DECIMAL, "2", I16).qt == type_store::SHORT);
		assert(int_lit(comp, DECIMAL, "3", UI16).qt == type_store::USHORT);
		assert(int_lit(comp, DECIMAL, "4", I32).qt == type_store::INT);
		assert(int_lit(comp, DECIMAL, "5", UI32).qt == type_store::UINT);
		assert(int_lit(comp, DECIMAL, "6", I64).qt == type_store::LONG);
		assert(int_lit(comp, DECIMAL, "7", UI64).qt == type_store::ULONG);
		// [source] no promotion, value cast without diagnostic: 300 -> (char)44, 255 -> (char)-1.
		NumberValue v = int_lit(comp, DECIMAL, "300", I8);
		expect_diags(v, {});
		assert(v.qt == type_store::CHAR);
		check(v.val.to_i64(comp)!!, 44);
		v = int_lit(comp, HEX, "FF", I8);
		check(v.val.to_i64(comp)!!, -1);
	};
	// [fixture clang integer suffixes i386-linux-gnu.c]
	@with_comp("i386-linux-gnu", CLANG; Compilation* comp)
	{
		assert(int_lit(comp, DECIMAL, "6", I64).qt == type_store::LONG_LONG);
		assert(int_lit(comp, DECIMAL, "7", UI64).qt == type_store::ULONG_LONG);
		assert(int_lit(comp, DECIMAL, "4", I32).qt == type_store::INT);
	};
	// [fixture clang integer suffixes arm64-apple-darwin.c]: 64 uses the target-independent
	// smallest type (long), not int_least64_t (long long on Darwin).
	@with_comp("arm64-apple-darwin", CLANG; Compilation* comp)
	{
		assert(int_lit(comp, DECIMAL, "6", I64).qt == type_store::LONG);
		assert(int_lit(comp, DECIMAL, "7", UI64).qt == type_store::ULONG);
		assert(int_lit(comp, DECIMAL, "2", I16).qt == type_store::SHORT);
	};
	// [source] getMSVCIntSuffixType: emulate msvc -> long long for 64.
	@with_comp("x86_64-linux-gnu", MSVC; Compilation* comp)
	{
		assert(int_lit(comp, DECIMAL, "6", I64).qt == type_store::LONG_LONG);
		assert(int_lit(comp, DECIMAL, "7", UI64).qt == type_store::ULONG_LONG);
	};
}

// ---------------------------------------------------------------------------
// _BitInt literals

fn void bit_int_literals() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		// [fixture _BitInt.c] `_BitInt(5) g = 2wb;` -> _BitInt(3) (2 bits + sign) [source width]
		NumberValue v = int_lit(comp, DECIMAL, "2", WB);
		expect_bit_int(comp, v.qt, 3, SIGNED);
		check(u64_of(comp, v.val), 2);
		expect_diags(v, {});
		// [fixture _BitInt.c] 3Uwb -> unsigned _BitInt(2)
		v = int_lit(comp, DECIMAL, "3", UWB);
		expect_bit_int(comp, v.qt, 2, UNSIGNED);
		// [fixture _BitInt.c] 0wb / 0uwb: zero needs one bit
		v = int_lit(comp, DECIMAL, "0", WB);
		expect_bit_int(comp, v.qt, 2, SIGNED);
		check(u64_of(comp, v.val), 0);
		v = int_lit(comp, DECIMAL, "0", UWB);
		expect_bit_int(comp, v.qt, 1, UNSIGNED);
		// [fixture _BitInt.c] 18446744073709551616WB = 2^64 -> 65 bits + sign
		v = int_lit(comp, DECIMAL, "18446744073709551616", WB);
		expect_bit_int(comp, v.qt, 66, SIGNED);
		expect_diags(v, {});
		BigIntSpace space;
		BigIntConst big = v.val.to_big_int(&space, comp);
		check(big.bit_count_abs(), 65);
		assert(big.positive);
		// [fixture c23 digit separators.c] 1'2wb == 12 -> _BitInt(5)
		v = int_lit(comp, DECIMAL, "1'2", WB);
		expect_bit_int(comp, v.qt, 5, SIGNED);
		check(u64_of(comp, v.val), 12);
		// [source] the sign bit is reserved for hex too: 0xFFwb -> _BitInt(9)
		v = int_lit(comp, HEX, "FF", WB);
		expect_bit_int(comp, v.qt, 9, SIGNED);
		check(u64_of(comp, v.val), 255);
		v = int_lit(comp, HEX, "FF", UWB);
		expect_bit_int(comp, v.qt, 8, UNSIGNED);
		v = int_lit(comp, OCTAL, "17", WB);
		expect_bit_int(comp, v.qt, 5, SIGNED);
		v = int_lit(comp, BINARY, "101", UWB);
		expect_bit_int(comp, v.qt, 3, UNSIGNED);
		// [source] imaginary _BitInt: complex of the bit-int type, value none
		v = int_lit(comp, DECIMAL, "5", IWB);
		assert(v.is_imaginary);
		expect_diags(v, { GNU_IMAGINARY_CONSTANT });
		expect_bit_int(comp, v.literal_qt, 4, SIGNED);
		expect_complex_of(comp, v.qt, v.literal_qt);
		assert(v.val.is_none());
		check(u64_of(comp, v.literal_val), 5);
		// [source] a 200-digit literal (bigger than u64) is exact
		v = int_lit(comp, HEX, "1'00000000'00000000'00000000'00000000", UWB);
		expect_bit_int(comp, v.qt, 129, UNSIGNED);
	};
}

// ---------------------------------------------------------------------------
// Imaginary integers

fn void imaginary_integers() @test
{
	// [fixture imaginary constants.c] `int _Complex ci = 1i;`, `1uli`
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		NumberValue v = int_lit(comp, DECIMAL, "1", I);
		assert(v.is_imaginary);
		expect_diags(v, { GNU_IMAGINARY_CONSTANT });
		assert(v.literal_qt == type_store::INT);
		expect_complex_of(comp, v.qt, type_store::INT);
		assert(v.val.is_none());
		check(u64_of(comp, v.literal_val), 1);
		v = int_lit(comp, DECIMAL, "1", IUL);
		assert(v.literal_qt == type_store::ULONG);
		expect_complex_of(comp, v.qt, type_store::ULONG);
		// [source] order: value diagnostic first, then the GNU extension.
		v = int_lit(comp, DECIMAL, "9223372036854775808", I);
		expect_diags(v, { IMPLICITLY_UNSIGNED_LITERAL, GNU_IMAGINARY_CONSTANT });
		assert(v.literal_qt == type_store::INT128);
		test::eq(NumberValueDiag.GNU_IMAGINARY_CONSTANT.template().fmt, "imaginary constants are a GNU extension");
	};
}

// ---------------------------------------------------------------------------
// Floating literals

fn void float_literal_types() @test
{
	// [fixture float types.c, AST golden test/cases/ast/float types.c]: every literal
	// has (value: 1). Like Zig's interner, a float 1.0 interns as the shared `one` ref.
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		NumberValue v = float_lit(comp, "1.0", BF16);
		assert(v.qt == type_store::BF16 && is_one(v.val));
		v = float_lit(comp, "1.0", NONE);
		assert(v.qt == type_store::DOUBLE && is_one(v.val));
		assert(v.literal_val.opt_ref == v.val.opt_ref && !v.is_imaginary);
		expect_diags(v, {});
		v = float_lit(comp, "1.0", F);
		assert(v.qt == type_store::FLOAT && is_one(v.val));
		v = float_lit(comp, "1.0", L);
		assert(v.qt == type_store::LONG_DOUBLE && is_one(v.val));
		assert(float_lit(comp, "1.0", F32).qt == type_store::FLOAT32);
		assert(float_lit(comp, "1.0", F64).qt == type_store::FLOAT64);
		assert(float_lit(comp, "1.0", F128).qt == type_store::FLOAT128);
		assert(float_lit(comp, "1.0", Q).qt == type_store::FLOAT128);
		assert(float_lit(comp, "1.0", F32X).qt == type_store::FLOAT32X);
		assert(float_lit(comp, "1.0", F64X).qt == type_store::FLOAT64X);
		assert(float_lit(comp, "1.0", D32).qt == type_store::DFLOAT32);
		assert(float_lit(comp, "1.0", D64).qt == type_store::DFLOAT64);
		assert(float_lit(comp, "1.0", D128).qt == type_store::DFLOAT128);
		assert(float_lit(comp, "1.0", D64X).qt == type_store::DFLOAT64X);
		assert(float_lit(comp, "1.0", F16).qt == type_store::FLOAT16);
		// [fixture __float80.c, AST golden] 1.0w -> float_literal: 'long double' (value: 1)
		v = float_lit(comp, "1.0", W);
		assert(v.qt == type_store::LONG_DOUBLE && is_one(v.val));

		// [source] storage width = bitSizeof of the type; 1.5 avoids the shared `one` ref.
		KeyFloat f = float_of(comp, float_lit(comp, "1.5", BF16).val);
		assert(f.tag == F16); // Zig stores __bf16 values as f16
		check(f.f16, 0x3E00);
		f = float_of(comp, float_lit(comp, "1.5", F16).val);
		assert(f.tag == F16);
		check(f.f16, 0x3E00);
		f = float_of(comp, float_lit(comp, "1.5", F).val);
		assert(f.tag == F32);
		check(f.f32, 0x3FC0_0000);
		f = float_of(comp, float_lit(comp, "1.5", NONE).val);
		assert(f.tag == F64);
		check(f.f64, 0x3FF8_0000_0000_0000);
		f = float_of(comp, float_lit(comp, "1.5", L).val);
		assert(f.tag == F80);
		check(f.f80.hi, 0x3FFF);
		check(f.f80.lo, (long)0xC000_0000_0000_0000);
		assert(float_of(comp, float_lit(comp, "1.5", W).val).tag == F80);
		f = float_of(comp, float_lit(comp, "1.5", F128).val);
		assert(f.tag == F128);
		check(f.f128.hi, 0x3FFF_8000_0000_0000);
		check(f.f128.lo, 0);
		f = float_of(comp, float_lit(comp, "1.5", D32).val);
		assert(f.tag == F32); // decimal floats use the binary width, as in Zig
		check(f.f32, 0x3FC0_0000);
		assert(float_of(comp, float_lit(comp, "1.5", D64).val).tag == F64);
		assert(float_of(comp, float_lit(comp, "1.5", D128).val).tag == F128);
		assert(float_of(comp, float_lit(comp, "1.5", F32X).val).tag == F64);
		assert(float_of(comp, float_lit(comp, "1.5", F64X).val).tag == F128); // TypeStore Float.bits: 64 * 2
	};
	// [source] aarch64-linux long double is binary128.
	@with_comp("aarch64-linux-gnu"; Compilation* comp)
	{
		assert(float_of(comp, float_lit(comp, "1.5", L).val).tag == F128);
	};
}

fn bool is_one(Value v) => v.opt_ref == value::ONE.opt_ref;

fn void float_literal_values() @test
{
	// [fixture numbers.c] accepted literals; values are IEEE-754 encodings [source]
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		check(float_of(comp, float_lit(comp, "12e+2", F).val).f32, 0x4496_0000); // 1200
		check(float_of(comp, float_lit(comp, "12E-2", F).val).f32, 0x3DF5_C28F); // 0.12
		check(float_of(comp, float_lit(comp, "0x12P+2", NONE).val).f64, 0x4052_0000_0000_0000); // 72
		check(float_of(comp, float_lit(comp, "0x12p-2", NONE).val).f64, 0x4012_0000_0000_0000); // 4.5
		check(float_of(comp, float_lit(comp, "0x1.ep-1", NONE).val).f64, 0x3FEE_0000_0000_0000); // 0.9375
		// 0.1 at each width: f128 parse, then one rounding to the target width [source]
		check(float_of(comp, float_lit(comp, "0.1", F).val).f32, 0x3DCC_CCCD);
		check(float_of(comp, float_lit(comp, "0.1", NONE).val).f64, 0x3FB9_9999_9999_999A);
		KeyFloat f = float_of(comp, float_lit(comp, "0.1", L).val);
		check(f.f80.hi, 0x3FFB);
		check(f.f80.lo, (long)0xCCCC_CCCC_CCCC_CCCD);
		f = float_of(comp, float_lit(comp, "0.1", Q).val);
		check(f.f128.hi, 0x3FFB_9999_9999_9999);
		check(f.f128.lo, (long)0x9999_9999_9999_999A);
		check(float_of(comp, float_lit(comp, "0.1", F16).val).f16, 0x2E66);
		// digit separators are stripped (C23) [source]
		check(float_of(comp, float_lit(comp, "1'0.5", NONE).val).f64, 0x4025_0000_0000_0000); // 10.5
		// out of range: double inf, long double (f80) still finite [source]
		check(float_of(comp, float_lit(comp, "1e400", NONE).val).f64, 0x7FF0_0000_0000_0000);
		f = float_of(comp, float_lit(comp, "1e400", L).val);
		assert(f.is_finite());
		check(float_of(comp, float_lit(comp, ".5", NONE).val).f64, 0x3FE0_0000_0000_0000);
		check(float_of(comp, float_lit(comp, "2.", NONE).val).f64, 0x4000_0000_0000_0000);
	};
}

fn void imaginary_floats() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		// [fixture imaginary constants.c] 2.0i (double), 2.0if (float), 2.0il (long double)
		NumberValue v = float_lit(comp, "2.0", I);
		assert(v.is_imaginary);
		expect_diags(v, { GNU_IMAGINARY_CONSTANT });
		assert(v.literal_qt == type_store::DOUBLE);
		expect_complex_of(comp, v.qt, type_store::DOUBLE);
		KeyComplex c = complex_of(comp, v.val);
		assert(c.tag == CF64);
		check(c.cf64[0], 0);
		check(c.cf64[1], 0x4000_0000_0000_0000);
		// AST golden: the inner float_literal of an imaginary literal carries no value.
		assert(v.literal_val.is_none());
		v = float_lit(comp, "2.0", IF);
		expect_complex_of(comp, v.qt, type_store::FLOAT);
		c = complex_of(comp, v.val);
		assert(c.tag == CF32);
		check(c.cf32[0], 0);
		check(c.cf32[1], 0x4000_0000);
		v = float_lit(comp, "2.0", IL);
		expect_complex_of(comp, v.qt, type_store::LONG_DOUBLE);
		assert(complex_of(comp, v.val).tag == CF80);
		// [fixture __float80.c, AST golden] 1.0iW -> imaginary_literal: '_Complex long double' (value: 0 + 1i)
		v = float_lit(comp, "1.0", IW);
		expect_complex_of(comp, v.qt, type_store::LONG_DOUBLE);
		assert(v.literal_qt == type_store::LONG_DOUBLE);
		c = complex_of(comp, v.val);
		assert(c.tag == CF80);
		check(c.cf80[0].hi, 0);
		check(c.cf80[0].lo, 0);
		check(c.cf80[1].hi, 0x3FFF);
		check(c.cf80[1].lo, (long)0x8000_0000_0000_0000);
		assert(v.literal_val.is_none());
		// [source] _Float16 / __float128 imaginary
		v = float_lit(comp, "1.5", IF16);
		c = complex_of(comp, v.val);
		assert(c.tag == CF16);
		check(c.cf16[1], 0x3E00);
		v = float_lit(comp, "1.0", IQ);
		expect_complex_of(comp, v.qt, type_store::FLOAT128);
		assert(complex_of(comp, v.val).tag == CF128);
	};
}

fn void float_suffix_type_table() @test
{
	@with_comp("x86_64-linux-gnu"; Compilation* comp)
	{
		assert(number_value::float_suffix_type(comp, IF128) == type_store::FLOAT128);
		assert(number_value::float_suffix_type(comp, IF32X) == type_store::FLOAT32X);
		assert(number_value::float_suffix_type(comp, IF64) == type_store::FLOAT64);
		assert(number_value::int_suffix_type(comp, ILL) == type_store::LONG_LONG);
		assert(number_value::int_suffix_type(comp, IULL) == type_store::ULONG_LONG);
		assert(number_value::int_suffix_type(comp, I) == type_store::INT);
	};
}

// ---------------------------------------------------------------------------
// Preprocessor #if values

fn PpNumberValue pp(Prefix prefix, String bytes, Suffix suffix, bool is_float = false)
{
	return number_value::pp_int_value({ .bytes = bytes, .is_float = is_float, .prefix = prefix, .suffix = suffix });
}

fn void pp_values() @test
{
	// [fixture preprocessor binary operators.c:68] `#if -9223372036854775808 / -1`
	// warns implicitly-unsigned and the operand is unsigned.
	PpNumberValue p = pp(DECIMAL, "9223372036854775808", NONE);
	assert(!p.rejected && !p.is_signed);
	check(p.diags.len, 1);
	assert(p.diags.items[0] == IMPLICITLY_UNSIGNED_LITERAL);
	assert(p.unsigned == 9223372036854775808UL);
	// [fixture preprocessor binary operators.c:74] 9223372036854775807L is signed, no diagnostic
	p = pp(DECIMAL, "9223372036854775807", L);
	assert(p.is_signed && p.diags.len == 0);
	check(p.signed, long::max);
	// [fixture imaginary constants.c:18] `#if 1.0i` -> float_literal_in_expr
	p = pp(DECIMAL, "1.0", I, true);
	assert(p.rejected);
	check(p.diags.len, 1);
	assert(p.diags.items[0] == FLOAT_LITERAL_IN_EXPR);
	test::eq(NumberValueDiag.FLOAT_LITERAL_IN_EXPR.template().fmt, "floating point literal in preprocessor expression");
	// [source] imaginary integer is rejected too; unsigned suffix stays unsigned
	p = pp(DECIMAL, "1", I);
	assert(p.rejected);
	p = pp(DECIMAL, "4", U);
	assert(!p.is_signed && p.unsigned == 4);
	// [source] hex above i64 max: unsigned, no warning
	p = pp(HEX, "FFFFFFFFFFFFFFFF", NONE);
	assert(!p.is_signed && p.unsigned == ulong::max && p.diags.len == 0);
	// [source] overflow wraps; overflow + implicitly unsigned may both appear
	p = pp(DECIMAL, "18446744073709551616", NONE);
	check(p.diags.len, 1);
	assert(p.diags.items[0] == INT_LITERAL_TOO_BIG);
	assert(p.is_signed && p.signed == 0);
	p = pp(DECIMAL, "36893488147419103231", NONE); // 2^65 - 1 -> wraps to u64 max
	check(p.diags.len, 2);
	assert(p.diags.items[0] == INT_LITERAL_TOO_BIG && p.diags.items[1] == IMPLICITLY_UNSIGNED_LITERAL);
	assert(!p.is_signed && p.unsigned == ulong::max);
	// [source] digit separators and binary
	p = pp(BINARY, "1001'0110", NONE);
	assert(p.is_signed && p.signed == 150);
}
