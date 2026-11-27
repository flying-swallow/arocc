// Primitive constants: PrimitiveValue (Zig Interner.Key, a tag plus payload)
// and its tag PrimitiveType (std.meta.Tag(Interner.Key) with the
// int/float/complex payload tags flattened in), float storage formats and the
// pure bit-level helpers on them, and the constructors / accessors of keys
// (int_key, float_key, complex_key, float_bits, re / im, to_big_int).
// Key hashing, equality and the static-ref mapping (Key.hash / eql / toRef)
// live here too. Storage lives in value_interner.c3,
// float semantics in primitive_float.c3, Value-level operations in aro::frontend::c::value.
module aro::primitive_value;
import aro::value_interner, aro::bigint, std::io, std::hash::metro64;

<*
 IEEE / x87 storage format of one PrimitiveType. `frac_bits` counts the stored
 fraction bits (for f80 *excluding* the explicit integer bit); `explicit_int`
 is true only for f80, whose bit 63 holds the integer bit.
*>
struct FloatFormat
{
	<* Total width: 16, 32, 64, 80, 128 (0 for FORMAT_NONE). *>
	char total_bits;
	char exp_bits;
	char frac_bits;
	bool explicit_int;
	<* Exponent bias: 2^(exp_bits-1) - 1. *>
	int bias;
}

<* Placeholder format of non-float tags. *>
const FloatFormat FORMAT_NONE = { 0, 0, 0, false, 0 };
const FloatFormat FORMAT_F16 = { 16, 5, 10, false, 15 };
const FloatFormat FORMAT_F32 = { 32, 8, 23, false, 127 };
const FloatFormat FORMAT_F64 = { 64, 11, 52, false, 1023 };
const FloatFormat FORMAT_F80 = { 80, 15, 63, true, 16383 };
const FloatFormat FORMAT_F128 = { 128, 15, 112, false, 16383 };

<* All ones in the low `total_bits` bits (f128: all 128). *>
fn uint128 FloatFormat.mask(self) => self.total_bits >= 128 ? ~(uint128)0 : ((uint128)1 << self.total_bits) - 1;

// Float bit views. Both are uint128-backed bitstructs, so neither has internal
// padding (c3c can drop padding bytes when it copies an aggregate by value).

<* f80 bits: `lo` = bits 0..63 (explicit-integer-bit mantissa), `hi` = bits 64..79 (sign + exponent); 80..127 zero. *>
bitstruct F80Bits : uint128
{
	ulong lo : 0..63;
	ushort hi : 64..79;
}

<* f128 bits: `lo` = bits 0..63, `hi` = bits 64..127. *>
bitstruct F128Bits : uint128
{
	ulong lo : 0..63;
	ulong hi : 64..127;
}

<* Coarse class of a key tag, for switches that only care about int / float / complex. *>
enum NumberKind : char
{
	NOT_NUMBER,
	INT,
	FLOAT,
	COMPLEX,
}

<*
 std.meta.Tag(Interner.Key) with the int/float/complex payload tags flattened in.
 kind: number class of the payload (NOT_NUMBER for types, null, bytes, pointers).
 width: bit width of a float, or of one complex component; 0 otherwise.
 format: storage format of a float, or of one complex component; FORMAT_NONE otherwise.
*>
enum PrimitiveType : char (NumberKind kind, ushort width, FloatFormat format)
{
	INT_TY       { NOT_NUMBER, 0, FORMAT_NONE },
	FLOAT_TY     { NOT_NUMBER, 0, FORMAT_NONE },
	COMPLEX_TY   { NOT_NUMBER, 0, FORMAT_NONE },
	PTR_TY       { NOT_NUMBER, 0, FORMAT_NONE },
	NORETURN_TY  { NOT_NUMBER, 0, FORMAT_NONE },
	VOID_TY      { NOT_NUMBER, 0, FORMAT_NONE },
	FUNC_TY      { NOT_NUMBER, 0, FORMAT_NONE },
	ARRAY_TY     { NOT_NUMBER, 0, FORMAT_NONE },
	VECTOR_TY    { NOT_NUMBER, 0, FORMAT_NONE },
	RECORD_TY    { NOT_NUMBER, 0, FORMAT_NONE },
	<* Zig `.null`: the nullptr constant (may not be zero). *>
	NULL         { NOT_NUMBER, 0, FORMAT_NONE },
	<* Integer >= 0; `limbs` is the normalized magnitude. *>
	INT_POSITIVE { INT, 0, FORMAT_NONE },
	<* Integer < 0; `limbs` is the normalized magnitude. *>
	INT_NEGATIVE { INT, 0, FORMAT_NONE },
	F16          { FLOAT, 16, FORMAT_F16 },
	F32          { FLOAT, 32, FORMAT_F32 },
	F64          { FLOAT, 64, FORMAT_F64 },
	F80          { FLOAT, 80, FORMAT_F80 },
	F128         { FLOAT, 128, FORMAT_F128 },
	CF16         { COMPLEX, 16, FORMAT_F16 },
	CF32         { COMPLEX, 32, FORMAT_F32 },
	CF64         { COMPLEX, 64, FORMAT_F64 },
	CF80         { COMPLEX, 80, FORMAT_F80 },
	CF128        { COMPLEX, 128, FORMAT_F128 },
	BYTES        { NOT_NUMBER, 0, FORMAT_NONE },
	POINTER      { NOT_NUMBER, 0, FORMAT_NONE },
}

<* Every float tag, narrowest first (the old KeyFloatTag::values). *>
const PrimitiveType[5] FLOAT_TAGS = { F16, F32, F64, F80, F128 };

<*
 The scalar float tag of a float or complex tag (CF64 -> F64, F64 -> F64).
 @require self.kind == FLOAT || self.kind == COMPLEX
*>
fn PrimitiveType PrimitiveType.scalar(self) => self.kind == COMPLEX ? float_tag_of_width(self.width) : self;

<*
 The complex tag over float tag `self` (F64 -> CF64).
 @require self.kind == FLOAT
*>
fn PrimitiveType PrimitiveType.complex(self)
{
	switch (self)
	{
		case F16: return CF16;
		case F32: return CF32;
		case F64: return CF64;
		case F80: return CF80;
		case F128: return CF128;
		default: unreachable("not a float tag");
	}
}

<*
 Limbs per float (or per complex component).
 @require self.kind == FLOAT || self.kind == COMPLEX
*>
fn sz PrimitiveType.float_limbs(self) => self.width <= 64 ? 1 : 2;

<*
 Bits 0..width-1 set (f80: 80 bits, f128: all 128).
 @require self.kind == FLOAT || self.kind == COMPLEX
*>
fn uint128 PrimitiveType.mask(self) => self.format.mask();

<*
 Sign bit of one float (or complex component) of this width.
 @require self.kind == FLOAT || self.kind == COMPLEX
*>
fn uint128 PrimitiveType.sign_mask(self) => (uint128)1 << (self.format.total_bits - 1);

<*
 Whether `bits` (one float of this width) is a NaN: exponent all ones and a
 nonzero stored fraction. For f80 the explicit integer bit (bit 63) is not part
 of the fraction. Bits above the width are ignored.
 @require self.kind == FLOAT || self.kind == COMPLEX
*>
fn bool PrimitiveType.bits_are_nan(self, uint128 bits)
{
	FloatFormat fmt = self.format;
	uint exp_shift = (uint)fmt.frac_bits + (fmt.explicit_int ? 1 : 0);
	uint128 exp_ones = ((uint128)1 << fmt.exp_bits) - 1;
	if (((bits >> exp_shift) & exp_ones) != exp_ones) return false;
	return (bits & (((uint128)1 << fmt.frac_bits) - 1)) != 0;
}

<* The float tag of bit width `bits` (16/32/64/80/128); Zig `switch (bitSizeof(T))`. *>
fn PrimitiveType float_tag_of_width(ulong bits)
{
	switch (bits)
	{
		case 16: return F16;
		case 32: return F32;
		case 64: return F64;
		case 80: return F80;
		case 128: return F128;
		default: unreachable("unsupported float width");
	}
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

struct KeyArrayTy
{
	ulong len;
	InternerRef child;
}

struct KeyVectorTy
{
	uint len;
	InternerRef child;
}

<* Key.Pointer: an address constant is a declaration/compound-literal node plus a byte offset, never a host address. *>
struct KeyPointer
{
	<* NodeIndex of the decl or compound literal whose address we are offsetting from. *>
	uint node;
	<* Offset in bytes (an interned integer). *>
	InternerRef offset;
}

<* Interner.Key: a tag plus its payload; ints use `limbs`, floats `fbits`, complexes `cbits`. *>
struct PrimitiveValue (Printable)
{
	PrimitiveType tag;
	union
	{
		<* INT_TY / FLOAT_TY / COMPLEX_TY: bit width. *>
		ushort ty_bits;
		KeyArrayTy array_ty;
		KeyVectorTy vector_ty;
		InternerRef[] record_ty;
		char[] bytes;
		KeyPointer pointer;
		<* INT_*: see the module header for the layout. *>
		Limb[] limbs;
		<* F*: the IEEE/x87 bit pattern, zero above the width (F80Bits / F128Bits fit). *>
		uint128 fbits;
		<* CF*: { real, imaginary } bit patterns, zero above the component width. *>
		uint128[2] cbits;
	}
}

// ---------------------------------------------------------------------------
// Constructors and accessors
// ---------------------------------------------------------------------------

// Shared limbs for the static int refs (never written).
Limb[1] zero_limbs = { 0 };
Limb[1] one_limbs = { 1 };

// Integer keys.

<* An integer key for `v` (limbs in tmem; zero and one use static limbs). *>
fn PrimitiveValue int_key(int128 v)
{
	if (v == 0) return { .tag = INT_POSITIVE, .limbs = zero_limbs[..] };
	if (v == 1) return { .tag = INT_POSITIVE, .limbs = one_limbs[..] };
	bool negative = v < 0;
	// Two's-complement negation in uint128 handles int128::min.
	uint128 mag = negative ? (uint128)0 - (uint128)v : (uint128)v;
	return mag_key(negative, mag);
}

<* An integer key for unsigned `v` (limbs in tmem). *>
fn PrimitiveValue uint_key(uint128 v)
{
	if (v == 0) return { .tag = INT_POSITIVE, .limbs = zero_limbs[..] };
	return mag_key(false, v);
}

fn PrimitiveValue mag_key(bool negative, uint128 mag) @local
{
	sz n = mag >> 64 != 0 ? 2 : 1;
	Limb[] limbs = alloc::new_array(tmem, Limb, n);
	limbs[0] = (Limb)mag;
	if (n == 2) limbs[1] = (Limb)(mag >> 64);
	return { .tag = negative ? INT_NEGATIVE : INT_POSITIVE, .limbs = limbs };
}

<* An integer key viewing `big`'s limbs (no copy; leading zero limbs are dropped). *>
fn PrimitiveValue big_int_key(BigIntConst big)
{
	BigIntConst c = normalized_int(big);
	return { .tag = c.positive ? INT_POSITIVE : INT_NEGATIVE, .limbs = c.limbs };
}

<*
 Key.toBigInt: a view of the key's limbs (no copy).
 @require self.tag.kind == INT
*>
fn BigIntConst PrimitiveValue.to_big_int(self) => { .limbs = self.limbs, .positive = self.tag == INT_POSITIVE };

<* @require self.tag.kind == INT *>
fn bool PrimitiveValue.int_is_zero(self) => canonical_int(self.to_big_int()).limbs.len == 0;

<*
 Whether the integer fits in 64 bits as either u64 or i64 (the old `.u64` / `.i64` key forms).
 @require self.tag.kind == INT
*>
fn bool PrimitiveValue.int_fits_64(self)
{
	BigIntConst c = canonical_int(self.to_big_int());
	if (c.limbs.len == 0) return true;
	if (c.limbs.len > 1) return false;
	return c.positive || c.limbs[0] <= 0x8000_0000_0000_0000;
}

<*
 The low 64 bits of the integer in two's complement (wraps when wider).
 @require self.tag.kind == INT
*>
fn ulong PrimitiveValue.int_low_u64(self)
{
	BigIntConst c = canonical_int(self.to_big_int());
	ulong low = c.limbs.len > 0 ? c.limbs[0] : 0;
	return c.positive ? low : 0 - low;
}

<*
 The low 128 bits of the integer in two's complement (wraps when wider).
 @require self.tag.kind == INT
*>
fn uint128 PrimitiveValue.int_low_u128(self)
{
	BigIntConst c = canonical_int(self.to_big_int());
	uint128 low = c.limbs.len > 0 ? (uint128)c.limbs[0] : 0;
	if (c.limbs.len > 1) low |= (uint128)c.limbs[1] << 64;
	return c.positive ? low : 0 - low;
}

// Float and complex keys.

<*
 A float key holding bit pattern `bits` (inline, no allocation; bits above the width are dropped).
 @require tag.kind == FLOAT
*>
fn PrimitiveValue float_key(PrimitiveType tag, uint128 bits) => { .tag = tag, .fbits = bits & tag.mask() };

<*
 The float's bit pattern, zero-extended to 128 bits.
 @require self.tag.kind == FLOAT
*>
fn uint128 PrimitiveValue.float_bits(self) => self.fbits;

fn ushort PrimitiveValue.f16(self) => (ushort)self.float_bits();
fn uint PrimitiveValue.f32(self) => (uint)self.float_bits();
fn ulong PrimitiveValue.f64(self) => (ulong)self.float_bits();
fn F80Bits PrimitiveValue.f80(self) => (F80Bits)self.float_bits();
fn F128Bits PrimitiveValue.f128(self) => (F128Bits)self.float_bits();

fn PrimitiveValue f16_value(ushort bits) => float_key(F16, bits);
fn PrimitiveValue f32_value(uint bits) => float_key(F32, bits);
fn PrimitiveValue f64_value(ulong bits) => float_key(F64, bits);
fn PrimitiveValue f80_value(F80Bits bits) => float_key(F80, (uint128)bits);
fn PrimitiveValue f128_value(F128Bits bits) => float_key(F128, (uint128)bits);

<*
 A complex key from two floats of the same width (inline, no allocation).
 @require re.tag.kind == FLOAT && re.tag == im.tag
*>
fn PrimitiveValue complex_key(PrimitiveValue re, PrimitiveValue im)
{
	return { .tag = re.tag.complex(), .cbits = { re.fbits & re.tag.mask(), im.fbits & re.tag.mask() } };
}

<* @require self.tag.kind == COMPLEX *>
fn PrimitiveValue PrimitiveValue.re(self) => { .tag = self.tag.scalar(), .fbits = self.cbits[0] };

<* @require self.tag.kind == COMPLEX *>
fn PrimitiveValue PrimitiveValue.im(self) => { .tag = self.tag.scalar(), .fbits = self.cbits[1] };

<* Integers print in decimal; other keys print their tag. *>
fn sz? PrimitiveValue.to_format(&self, Formatter* f) @dynamic
{
	if (self.tag.kind == INT) return f.print(self.to_big_int().to_string_alloc(tmem, 10, false));
	return f.printf("%s", self.tag);
}

// Integer helpers. These read limbs directly instead of calling bigint queries so
// keys and the interner do not depend on the bigint implementation.

<* Canonical view of `big`: no leading zero limbs, zero has no limbs and is positive. *>
fn BigIntConst canonical_int(BigIntConst big)
{
	sz n = big.limbs.len;
	while (n > 0 && big.limbs[n - 1] == 0) n--;
	return { .limbs = big.limbs[:n], .positive = n == 0 || big.positive };
}

<* Zig-normalized view of `big`: as canonical_int, but zero is `[0]`. *>
fn BigIntConst normalized_int(BigIntConst big)
{
	BigIntConst c = canonical_int(big);
	if (c.limbs.len == 0) return { .limbs = zero_limbs[..], .positive = true };
	return c;
}

fn bool canonical_int_eql(BigIntConst a, BigIntConst b)
{
	if (a.positive != b.positive || a.limbs.len != b.limbs.len) return false;
	foreach (i, l : a.limbs) if (l != b.limbs[i]) return false;
	return true;
}

<* Components of a complex constant: [0] real, [1] imaginary. *>
fn PrimitiveValue[2] PrimitiveValue.parts(self) => { self.re(), self.im() };

// ---------------------------------------------------------------------------
// Hashing, equality, static refs
// ---------------------------------------------------------------------------

<* std.meta.eql on one float: equal bits, never equal when NaN. *>
fn bool float_bits_eql(PrimitiveType tag, uint128 a, uint128 b) @local
{
	uint128 x = a & tag.mask();
	return x == (b & tag.mask()) && !tag.bits_are_nan(x);
}

<* Key.hash (32-bit, folded MetroHash64). Need not match Zig's Wyhash bit-for-bit (ref numbering does not depend on it), but must be consistent with `eql`. Fields are fed one at a time so union and struct padding never reach the hash. *>
fn uint PrimitiveValue.hash(self)
{
	MetroHash64 hs;
	hs.init(0x243F_6A88_85A3_08D3);
	if (self.tag.kind == INT)
	{
		// The sign comes from the canonical value so negative zero hashes as zero.
		BigIntConst big = canonical_int(self.to_big_int());
		PrimitiveType int_tag = INT_POSITIVE;
		hs.update(@as_char_view(int_tag));
		hs.update(@as_char_view(big.positive));
		hs.update(((char*)big.limbs.ptr)[:big.limbs.len * @sizeof(big.limbs[0])]);
		return (uint)hs.final();
	}
	hs.update(@as_char_view(self.tag));
	switch (self.tag)
	{
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			hs.update(@as_char_view(self.ty_bits));
		case PTR_TY:
		case NORETURN_TY:
		case VOID_TY:
		case FUNC_TY:
		case NULL:
			break;
		case ARRAY_TY:
			hs.update(@as_char_view(self.array_ty.len));
			hs.update(@as_char_view(self.array_ty.child));
		case VECTOR_TY:
			hs.update(@as_char_view(self.vector_ty.len));
			hs.update(@as_char_view(self.vector_ty.child));
		case RECORD_TY:
			InternerRef[] fields = self.record_ty;
			sz fields_len = fields.len;
			hs.update(@as_char_view(fields_len));
			hs.update(((char*)fields.ptr)[:fields_len * @sizeof(fields[0])]);
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			uint128 b = self.float_bits() & self.tag.mask();
			hs.update(@as_char_view(b));
		case CF16:
		case CF32:
		case CF64:
		case CF80:
		case CF128:
			PrimitiveType s = self.tag.scalar();
			uint128 r = self.re().float_bits() & s.mask();
			uint128 i = self.im().float_bits() & s.mask();
			hs.update(@as_char_view(r));
			hs.update(@as_char_view(i));
		case BYTES:
			char[] bytes = self.bytes;
			sz bytes_len = bytes.len;
			hs.update(@as_char_view(bytes_len));
			hs.update(bytes);
		case POINTER:
			hs.update(@as_char_view(self.pointer.node));
			hs.update(@as_char_view(self.pointer.offset));
		case INT_POSITIVE:
		case INT_NEGATIVE:
			unreachable();
	}
	return (uint)hs.final();
}

<*
 Key.eql. Ints compare by mathematical value; floats and complexes compare their
 bit patterns, and a NaN component never compares equal (Zig `std.meta.eql` uses
 `==` on float payloads).
*>
fn bool PrimitiveValue.eql(a, PrimitiveValue b)
{
	if (a.tag.kind == INT && b.tag.kind == INT)
	{
		return canonical_int_eql(canonical_int(a.to_big_int()), canonical_int(b.to_big_int()));
	}
	if (a.tag != b.tag) return false;
	switch (a.tag)
	{
		case INT_TY:
		case FLOAT_TY:
		case COMPLEX_TY:
			return a.ty_bits == b.ty_bits;
		case PTR_TY:
		case NORETURN_TY:
		case VOID_TY:
		case FUNC_TY:
		case NULL:
			return true;
		case ARRAY_TY:
			return a.array_ty.len == b.array_ty.len && a.array_ty.child == b.array_ty.child;
		case VECTOR_TY:
			return a.vector_ty.len == b.vector_ty.len && a.vector_ty.child == b.vector_ty.child;
		case RECORD_TY:
			if (a.record_ty.len != b.record_ty.len) return false;
			foreach (i, e : a.record_ty) if (e != b.record_ty[i]) return false;
			return true;
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			return float_bits_eql(a.tag, a.fbits, b.fbits);
		case CF16:
		case CF32:
		case CF64:
		case CF80:
		case CF128:
			PrimitiveType s = a.tag.scalar();
			return float_bits_eql(s, a.cbits[0], b.cbits[0]) && float_bits_eql(s, a.cbits[1], b.cbits[1]);
		case BYTES:
			if (a.bytes.len != b.bytes.len) return false;
			foreach (i, c : a.bytes) if (c != b.bytes[i]) return false;
			return true;
		case POINTER:
			return a.pointer.node == b.pointer.node && a.pointer.offset == b.pointer.offset;
		case INT_POSITIVE:
		case INT_NEGATIVE:
			unreachable();
	}
}

<* Key.toRef: the static ref for keys that have one; NO_STATIC_REF otherwise. *>
excuse NO_STATIC_REF;
fn InternerRef? PrimitiveValue.to_ref(self)
{
	switch (self.tag)
	{
		case INT_TY:
			switch (self.ty_bits)
			{
				case 1: return value_interner::REF_I1;
				case 8: return value_interner::REF_I8;
				case 16: return value_interner::REF_I16;
				case 32: return value_interner::REF_I32;
				case 64: return value_interner::REF_I64;
				case 128: return value_interner::REF_I128;
			}
		case FLOAT_TY:
			switch (self.ty_bits)
			{
				case 16: return value_interner::REF_F16;
				case 32: return value_interner::REF_F32;
				case 64: return value_interner::REF_F64;
				case 80: return value_interner::REF_F80;
				case 128: return value_interner::REF_F128;
				default: unreachable("float_ty with unsupported bit width");
			}
		case COMPLEX_TY:
			switch (self.ty_bits)
			{
				case 16: return value_interner::REF_CF16;
				case 32: return value_interner::REF_CF32;
				case 64: return value_interner::REF_CF64;
				case 80: return value_interner::REF_CF80;
				case 128: return value_interner::REF_CF128;
				default: unreachable("complex_ty with unsupported bit width");
			}
		case PTR_TY: return value_interner::REF_PTR;
		case FUNC_TY: return value_interner::REF_FUNC;
		case NORETURN_TY: return value_interner::REF_NORETURN;
		case VOID_TY: return value_interner::REF_VOID;
		case NULL: return value_interner::REF_NULL;
		case INT_POSITIVE:
		case INT_NEGATIVE:
			BigIntConst big = canonical_int(self.to_big_int());
			if (big.limbs.len == 0) return value_interner::REF_ZERO;
			if (big.positive && big.limbs.len == 1 && big.limbs[0] == 1) return value_interner::REF_ONE;
		case F16:
		case F32:
		case F64:
		case F80:
		case F128:
			// isPositiveZero(x) -> zero; x == 1 -> one (compared as the bit pattern of 1.0).
			uint128 b = self.float_bits() & self.tag.mask();
			if (b == 0) return value_interner::REF_ZERO;
			uint128 one;
			switch (self.tag)
			{
				case F16: one = 0x3C00;
				case F32: one = 0x3F80_0000;
				case F64: one = 0x3FF0_0000_0000_0000;
				case F80: one = 0x3FFF_8000_0000_0000_0000;
				default: one = 0x3FFF_0000_0000_0000_0000_0000_0000_0000;
			}
			if (b == one) return value_interner::REF_ONE;
		default:
			break;
	}
	return NO_STATIC_REF~;
}
