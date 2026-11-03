// Port of the integer, byte and pointer parts of src/aro/Value.zig.
//
// OWNER: plan 09 stage 1 agent 09.3 `value-ops`. Stage 0 (contract) fixed `Value`
// and the signatures below; operations are stubs. Float/complex operations
// (floatToInt, intToFloat, floatCast, toFloat, imag, realPart/imaginaryPart,
// isInf/isNan/isInfSign, complexConj, the float branches of add/sub/mul/div/compare)
// and `print`/`printString` belong to plan 10 and later; until then the float
// branches of the operations below end in `unreachable("plan 10: ...")`.
//
// Invariants implementers must keep:
//   - none vs null vs zero are three different values: `value::NONE` (no constant
//     value known; Zig `Value{}` / `.none`), `value::NULL` (the nullptr constant,
//     REF_NULL) and `value::ZERO` (int 0, REF_ZERO). A zero-initialized `Value {}`
//     is NOT none (it is item index 0): always start from `value::NONE`.
//   - Every value is interned in `comp.interner`; equal values share one ref, so
//     `opt_ref` equality is value equality (Zig `shallowCompare`).
//   - Integer results are arbitrary-width (`_BitInt` up to 65535 bits) and computed
//     with aro::bigint into scratch limbs allocated from `comp.gpa` and freed before
//     returning (Zig's `defer gpa.free`). No host 64/128-bit shortcuts.
//   - Overflow is returned exactly as Zig does: add/sub via addWrap/subWrap, mul/shl
//     as "!fitsInTwosComp then truncate", div as "!fitsInTwosComp" on the
//     *untruncated* quotient (which is then interned untruncated), pointer
//     arithmetic as mul_overflow || add_overflow.
//   - Pointer constants are (node, byte offset) identities (`KeyPointer`), never
//     host addresses. Arithmetic on them scales by the element size and keeps the
//     node; differences of pointers with different nodes are NONE; ordering
//     comparisons across nodes are unknown (`compare_pointers` faults).
//   - Bytes values never take part in arithmetic: add/sub yield NONE.
//   - Running out of memory panics; Zig's `!Value` (OOM only) is plain `Value`.
module aro::value;
import aro::compilation, aro::value_interner, aro::bigint, aro::type_store, aro::lang_opts;

<* Zig `null` from toInt: none, not an int, or does not fit. *>
excuse NO_INT;
<* Zig `null` from comparePointers: the result is not known at compile time. *>
excuse NOT_COMPARABLE;

struct Value
{
	InternerOptRef opt_ref;
}

<* Zig `Value{}` / `.none`: no known constant value. *>
const Value NONE = { .opt_ref = value_interner::OPT_NONE };
const Value ZERO = { .opt_ref = value_interner::OPT_ZERO };
const Value ONE = { .opt_ref = value_interner::OPT_ONE };
<* Zig `Value.null`: the nullptr constant. *>
const Value NULL = { .opt_ref = value_interner::OPT_NULL };

fn bool Value.is_none(self) => self.opt_ref == value_interner::OPT_NONE;

<*
 Value.ref
 @require !self.is_none()
*>
fn InternerRef Value.ref(self) => self.opt_ref.unwrap();

<* Value.fromRef *>
fn Value from_ref(InternerRef r) => { .opt_ref = r.to_opt() };

<* Value.intern: put `k` in comp.interner. *>
fn Value intern(Compilation* comp, InternerKey k)
{
	unreachable("stage 0 stub: value::intern");
}

<* Value.int for unsigned / comptime_int arguments (`.u64` key). *>
fn Value int_u64(ulong i, Compilation* comp)
{
	unreachable("stage 0 stub: value::int_u64");
}

<* Value.int for signed arguments (`.i64` key). *>
fn Value int_i64(long i, Compilation* comp)
{
	unreachable("stage 0 stub: value::int_i64");
}

<* Value.pointer *>
fn Value pointer(KeyPointer r, Compilation* comp)
{
	unreachable("stage 0 stub: value::pointer");
}

<* Value.is: false for none, else whether the key has `tag`. *>
fn bool Value.is(self, InternerKeyTag tag, Compilation* comp)
{
	unreachable("stage 0 stub: Value.is");
}

<* Value.isArithmetic: int, float or complex. *>
fn bool Value.is_arithmetic(self, Compilation* comp)
{
	unreachable("stage 0 stub: Value.is_arithmetic");
}

<* Value.isPointer *>
fn bool Value.is_pointer(self, Compilation* comp)
{
	unreachable("stage 0 stub: Value.is_pointer");
}

<*
 Value.minUnsignedBits: bits needed to hold the value (0 -> 0, 255 -> 8).
 @require !self.is_none()
*>
fn usz Value.min_unsigned_bits(self, Compilation* comp)
{
	unreachable("stage 0 stub: Value.min_unsigned_bits");
}

<*
 Value.minSignedBits: two's-complement bits of a negative value (-1 -> 1, -128 -> 8).
 Asserts the value is negative.
*>
fn usz Value.min_signed_bits(self, Compilation* comp)
{
	unreachable("stage 0 stub: Value.min_signed_bits");
}

<* Value.toBigInt: the int value as a BigIntConst (small values live in `space`). *>
fn BigIntConst Value.to_big_int(self, BigIntSpace* space, Compilation* comp)
{
	unreachable("stage 0 stub: Value.to_big_int");
}

<* Value.IntCastChangeKind *>
enum IntCastChangeKind : char
{
	<* value did not change *>
	NONE,
	<* truncation occurred (e.g. i32 to i16) *>
	TRUNCATED,
	<* sign conversion occurred (e.g. i32 to u32) *>
	SIGN_CHANGED,
}

<*
 Value.intCast: truncate or extend to `dest_ty`'s bit size and signedness.
 None, pointer and bytes values are left unchanged (returns NONE).
*>
fn IntCastChangeKind Value.int_cast(&self, QualType dest_ty, Compilation* comp)
{
	unreachable("stage 0 stub: Value.int_cast");
}

<* Value.isZero: false for none; REF_NULL is zero iff the target's null repr is 0. *>
fn bool Value.is_zero(self, Compilation* comp)
{
	unreachable("stage 0 stub: Value.is_zero");
}

<* Value.boolCast: becomes ZERO or ONE; none stays none. *>
fn void Value.bool_cast(&self, Compilation* comp)
{
	unreachable("stage 0 stub: Value.bool_cast");
}

<* Value.fromBool *>
fn Value from_bool(bool b) => b ? ONE : ZERO;

<* Value.toBool: !is_zero. *>
fn bool Value.to_bool(self, Compilation* comp) => !self.is_zero(comp);

<*
 Value.toInt(u64)
 @return? NO_INT
*>
fn ulong? Value.to_u64(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.toInt(i64)
 @return? NO_INT
*>
fn long? Value.to_i64(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.toInt(u32) (used by `elem`)
 @return? NO_INT
*>
fn uint? Value.to_u32(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.toInt(usize) (used by shl/shr)
 @return? NO_INT
*>
fn usz? Value.to_usz(self, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<*
 Value.toBytes. The slice stays valid until the interner is freed.
 @require !self.is_none()
*>
fn char[] Value.to_bytes(self, Compilation* comp)
{
	unreachable("stage 0 stub: Value.to_bytes");
}

// ---------------------------------------------------------------------------
// Arithmetic. `res` may be the same Value as an operand. Bool results report
// overflow of the C operation in type `qt`.
// ---------------------------------------------------------------------------

<*
 Value.add: res = lhs + rhs in `qt`. Pointer + int scales the int by the pointee
 size (1 when unsized) in ptrdiff_t and keeps the node. Bytes operands give NONE.
*>
fn bool Value.add(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: Value.add");
}

<* Value.negate: res = 0 - val. *>
fn bool Value.negate(&res, Value val, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: Value.negate");
}

<* Value.decrement: res = val - 1. *>
fn bool Value.decrement(&res, Value val, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: Value.decrement");
}

<*
 Value.sub: res = lhs - rhs in `qt`. `elem_size` is only used for pointer - pointer
 (the byte difference is divided by it; Zig passes `undefined` otherwise) and for
 pointer - int scaling. Pointers with different nodes give NONE. Parameter order
 deviates from Zig (`elem_size` last, defaulted) so non-pointer callers omit it.
*>
fn bool Value.sub(&res, Value lhs, Value rhs, QualType qt, Compilation* comp, ulong elem_size = 0)
{
	unreachable("stage 0 stub: Value.sub");
}

<* Value.mul: exact product; overflow = !fits; result truncated when it overflows. *>
fn bool Value.mul(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: Value.mul");
}

<*
 Value.div: truncating division. Returns !fits for the quotient, which is interned
 untruncated (e.g. INT_MIN / -1). Caller guarantees rhs != 0.
*>
fn bool Value.div(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: Value.div");
}

<*
 Value.rem: C `%` (sign of lhs). Signed INT_MIN % -1 gives NONE. Caller guarantees
 rhs != 0.
*>
fn Value rem(Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: value::rem");
}

<* Value.bitOr (infinite two's complement). *>
fn Value bit_or(Value lhs, Value rhs, Compilation* comp)
{
	unreachable("stage 0 stub: value::bit_or");
}

<* Value.bitXor *>
fn Value bit_xor(Value lhs, Value rhs, Compilation* comp)
{
	unreachable("stage 0 stub: value::bit_xor");
}

<* Value.bitAnd *>
fn Value bit_and(Value lhs, Value rhs, Compilation* comp)
{
	unreachable("stage 0 stub: value::bit_and");
}

<* Value.bitNot: ~val wrapped to `qt`. *>
fn Value bit_not(Value val, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: value::bit_not");
}

<*
 Value.shl: res = lhs << rhs. A shift that is not a usz or exceeds the bit size
 gives max_int (lhs >= 0) / min_int (lhs < 0) and overflow. Otherwise overflow =
 !fits, truncating when it overflows.
*>
fn bool Value.shl(&res, Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: Value.shl");
}

<*
 Value.shr: arithmetic shift right (floor). A shift that is not a usz gives ZERO;
 shifting out every limb gives ZERO or -1 by sign.
*>
fn Value shr(Value lhs, Value rhs, QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: value::shr");
}

// ---------------------------------------------------------------------------
// Comparison and limits
// ---------------------------------------------------------------------------

<* Value.compare (int part; float/complex branches are plan 10). *>
fn bool compare(Value lhs, CompareOperator op, Value rhs, Compilation* comp)
{
	unreachable("stage 0 stub: value::compare");
}

<*
 Value.comparePointers: equal refs compare by `op` on EQ; same node compares the
 offsets; different nodes are false for EQ, true for NEQ, and unknown otherwise.
 @return? NOT_COMPARABLE
*>
fn bool? compare_pointers(Value lhs, CompareOperator op, Value rhs, Compilation* comp)
{
	unreachable("stage 0 stub");
}

<* Value.minInt: smallest value of integer type `qt` (ZERO for unsigned). *>
fn Value min_int(QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: value::min_int");
}

<* Value.maxInt: largest value of integer type `qt`. *>
fn Value max_int(QualType qt, Compilation* comp)
{
	unreachable("stage 0 stub: value::max_int");
}

<*
 Value.elem: element `index` of a bytes value as an int (NONE when out of range,
 not bytes, or the index is not a u32). Keeps Zig's `index > len` bound check.
*>
fn Value elem(Value arr, Value index, Compilation* comp)
{
	unreachable("stage 0 stub: value::elem");
}
