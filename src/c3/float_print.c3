// Float comparisons, Value-level NaN/Inf predicates and float/complex printing:
// port of Value.zig compare (float/complex branches), isInf, isNan, isInfSign and
// the .float / .complex arms of Value.print.
//
// OWNER: plan 10 stage 1 agent 10.4 `compare-print`. Stage 0 fixed the signatures.
// (The bit-level predicates KeyFloat.is_nan/is_inf/... are stage-0 code in
// float_value.c3 so every agent can use them; this file owns everything that
// reads a Value or produces text.)
//
// Contract:
//   - No native floats (only float_soft_narrow.c3 may use them): work on KeyFloat
//     bits and the dispatching KeyFloat.mul/div/cast.
//   - Output is appended to a DString, like type_print.c3.
module aro::float_value;
import aro::value_interner, aro::value, aro::compilation, aro::bigint, std::core::dstring;

<* Zig Value.IsInfKind (enum(i32)) *>
enum IsInfKind : int (int value)
{
	NEGATIVE { -1 },
	FINITE { 0 },
	POSITIVE { 1 },
	UNKNOWN { 0x7FFF_FFFF },
}

<*
 std.math.compare(a, op, b) for two floats of the same width: IEEE ordering,
 -0 == +0, any comparison with a NaN is false except NEQ, which is true.
 @require self.tag == rhs.tag : "operands must have the same width"
*>
fn bool KeyFloat.compare(self, CompareOperator op, KeyFloat rhs)
{
	unreachable("stage 0 stub");
}

<*
 Float/complex branch of Value.compare, called after shallowCompare gave no
 answer and when at least one key is FLOAT or COMPLEX:
   either FLOAT: compare to_float(lhs, F128) with to_float(rhs, F128) using `op`.
   else either COMPLEX: assert(op == NEQ); return !(re equal) || !(im equal),
   comparing to_float(.., F128) and imag(.., F128) with EQ (so NaN parts make
   the values unequal).
*>
fn bool compare(Value lhs, CompareOperator op, Value rhs, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Value.isInf: none -> false; float -> isInf; complex -> either part isInf; else false. *>
fn bool is_inf(Value v, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Value.isNan: none -> false; float -> isNan; complex -> either part isNan; else false. *>
fn bool is_nan(Value v, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.isInfSign: none -> UNKNOWN; float -> POSITIVE / NEGATIVE / FINITE (NaN is
 FINITE); any other key (int included, e.g. a float 0.0 interned as REF_ZERO)
 -> UNKNOWN.
*>
fn IsInfKind is_inf_sign(Value v, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Zig `w.print("{d}", .{x})` for an f64 bit pattern (Zig 0.17.0
 std.fmt.float.render, mode .decimal, no precision): the shortest round-trip
 digits from binaryToDecimal (Ryu, Backend64 tables; the "small" and "full"
 tables give the same digits), written without an exponent ("0.000001234",
 "123456000", "12345.6789", "1", "-0"). Specials: "inf", "-inf", "nan", "-nan"
 (the NaN sign bit is printed). Appends to `w`.
*>
fn void format_f64_decimal(ulong bits, DString w)
{
	unreachable("stage 0 stub");
}

<*
 The .float arm of Value.print:
   f16: x = (f64)h; print @round(x * 1000) / 1000;
   f32: x = (f64)f; print @round(x * 1000000) / 1000000;
   f64/f80/f128: print (f64)x (@floatCast: may overflow to inf).
 The scaling is f64 arithmetic (KeyFloat.mul / KeyFloat.div at F64, each
 rounded); Zig @round rounds to an integer, halfway cases away from zero (a
 bit-level helper in this file). Printing goes through format_f64_decimal.
*>
fn void print_float(KeyFloat f, DString w)
{
	unreachable("stage 0 stub");
}

<*
 The .complex arm of Value.print: "{d} + {d}i" of the two parts (a negative
 imaginary part prints as "1 + -2i"). cf32 parts are rounded like f32 above;
 every other width (cf16 included - no 1000 scaling) is plain (f64)x.
*>
fn void print_complex(KeyComplex c, DString w)
{
	unreachable("stage 0 stub");
}
