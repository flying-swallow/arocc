// Port of the type-relation part of src/aro/TypeStore.zig: signedness, ranks,
// integer/bitfield promotion, scalar kinds, (qualified) equality, decay,
// makeIntUnsigned, toReal/toComplex, arrayLen, intValueSuffix, formatModifier.
//
// Not here: the usual arithmetic conversions live on Parser.Result in Zig and
// are ported with the parser.
module aro::type_store;
import aro::compilation, aro::lang_opts, aro::target;

<* std.math.Order *>
enum Order : char
{
	LT,
	EQ,
	GT,
}

fn Order order_of(ulong a, ulong b) @inline => a < b ? LT : a > b ? GT : EQ;

<*
 Signedness of an integer, pointer or enum type (complex/atomic look through).
 @require !self.is_invalid()
*>
fn Signedness QualType.signedness(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	while (true)
	{
		switch (ty.tag)
		{
			case COMPLEX: ty = ty.complex.base(comp).ty;
			case ATOMIC: ty = ty.atomic.base(comp).ty;
			case BOOL: return UNSIGNED;
			case BIT_INT: return ty.bit_int.signedness;
			case INT:
				switch (ty.int_ty)
				{
					case CHAR: return char_signedness(comp);
					case SCHAR:
					case SHORT:
					case INT:
					case INT24:
					case LONG:
					case LONG_LONG:
					case INT128: return SIGNED;
					case UCHAR:
					case USHORT:
					case UINT:
					case UINT24:
					case ULONG:
					case ULONG_LONG:
					case UINT128: return UNSIGNED;
				}
			// Pointer values are signed.
			case POINTER:
			case NULLPTR_T:
			case BLOCK: return SIGNED;
			case ENUM: return SIGNED;
			default: unreachable("type has no signedness");
		}
	}
}

const uint DECIMAL_FLOAT_RANK = 90;

<* Rank for floating point conversions, ignoring domain (complex vs real). Asserts a floating type. *>
fn uint QualType.float_rank(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	while (true)
	{
		switch (ty.tag)
		{
			case FLOAT:
				switch (ty.float_ty)
				{
					case BF16: return 0;
					case FLOAT16: return 1;
					case FP16: return 2;
					case FLOAT: return 3;
					case FLOAT32: return 4;
					case FLOAT32X: return 5;
					case DOUBLE: return 6;
					case FLOAT64: return 7;
					case FLOAT64X: return 8;
					case LONG_DOUBLE: return 9;
					case FLOAT128: return 10;
					case FLOAT128X: unreachable("_Float128x is not supported");
					case DFLOAT32: return DECIMAL_FLOAT_RANK + 0;
					case DFLOAT64: return DECIMAL_FLOAT_RANK + 1;
					case DFLOAT64X: return DECIMAL_FLOAT_RANK + 2;
					case DFLOAT128: return DECIMAL_FLOAT_RANK + 3;
				}
			case COMPLEX: ty = ty.complex.base(comp).ty;
			case ATOMIC: ty = ty.atomic.base(comp).ty;
			default: unreachable("not a floating point type");
		}
	}
}

<* Rank for integer conversions, ignoring domain (complex vs real). Asserts an integer type. *>
fn ulong QualType.int_rank(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	while (true)
	{
		switch (ty.tag)
		{
			case BIT_INT: return (ulong)ty.bit_int.bits * 8;
			case BOOL: return 1 + BOOL.bit_sizeof(comp) * 8;
			case INT:
				ulong bits8 = (ulong)ty.int_ty.bits(comp) * 8;
				switch (ty.int_ty)
				{
					case CHAR:
					case SCHAR:
					case UCHAR: return 2 + bits8;
					case SHORT:
					case USHORT: return 3 + bits8;
					case INT:
					case UINT: return 4 + bits8;
					case INT24:
					case UINT24: return 5 + bits8;
					case LONG:
					case ULONG: return 6 + bits8;
					case LONG_LONG:
					case ULONG_LONG: return 7 + bits8;
					case INT128:
					case UINT128: return 8 + bits8;
				}
			case COMPLEX: ty = ty.complex.base(comp).ty;
			case ATOMIC: ty = ty.atomic.base(comp).ty;
			case ENUM:
				assert(ty.enum_ty.has_tag);
				ty = ty.enum_ty.tag.base(comp).ty;
			default: unreachable("not an integer type");
		}
	}
}

<* @require self.is_int(comp) && b.is_int(comp) *>
fn Order QualType.int_rank_order(self, QualType b, Compilation* comp)
{
	bool a_unsigned = self.signedness(comp) == UNSIGNED;
	bool b_unsigned = b.signedness(comp) == UNSIGNED;
	ulong a_rank = self.int_rank(comp);
	ulong b_rank = b.int_rank(comp);
	if (a_unsigned == b_unsigned) return order_of(a_rank, b_rank);
	if (a_unsigned) return a_rank >= b_rank ? GT : LT;
	return b_rank >= a_rank ? LT : GT;
}

<* True if `a` and `b` are integer types that differ only in sign. *>
fn bool QualType.same_rank_different_sign(self, QualType b, Compilation* comp)
{
	if (!self.is_int(comp) || !b.is_int(comp)) return false;
	if (self.has_incomplete_size(comp) || b.has_incomplete_size(comp)) return false;
	if (self.int_rank(comp) != b.int_rank(comp)) return false;
	return self.signedness(comp) != b.signedness(comp);
}

<* Integer promotion. Asserts an integer type. *>
fn QualType QualType.promote_int(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	while (true)
	{
		switch (ty.tag)
		{
			case BOOL: return INT;
			case ENUM:
				if (!ty.enum_ty.has_tag) return INT;
				ty = ty.enum_ty.tag.base(comp).ty;
			case BIT_INT: return self;
			case COMPLEX: return self; // Assume complex integer type
			case INT:
				switch (ty.int_ty)
				{
					case CHAR:
					case SCHAR:
					case UCHAR:
					case SHORT: return INT;
					case USHORT: return TypeInt.UCHAR.bits(comp) == TypeInt.INT.bits(comp) ? UINT : INT;
					default: return self;
				}
			case ATOMIC: ty = ty.atomic.base(comp).ty;
			default: unreachable("not an integer type");
		}
	}
}

<*
 Promote a bitfield of `width` bits: int if it can hold all values, else
 unsigned int. NO_PROMOTION if no promotion is necessary.
*>
fn QualType? QualType.promote_bitfield(self, Compilation* comp, uint width)
{
	ulong type_size_bits = self.bit_sizeof(comp);
	// Note: GCC and clang will promote `long: 3` to int even though the C standard does not allow this
	if (width < type_size_bits) return INT;
	if (width == type_size_bits) return self.signedness(comp) == UNSIGNED ? UINT : INT;
	return NO_PROMOTION~;
}

<* QualType.ScalarKind *>
enum ScalarKind : char
{
	ENUM,
	BOOL,
	INT,
	FLOAT,
	POINTER,
	NULLPTR_T,
	VOID_POINTER,
	COMPLEX_INT,
	COMPLEX_FLOAT,
	BLOCK_POINTER,
	NONE,
}

fn bool ScalarKind.is_int(self) => self == BOOL || self == ENUM || self == INT || self == COMPLEX_INT;
fn bool ScalarKind.is_float(self) => self == FLOAT || self == COMPLEX_FLOAT;
fn bool ScalarKind.is_real(self) => self != COMPLEX_INT && self != COMPLEX_FLOAT;
fn bool ScalarKind.is_pointer(self) => self == POINTER || self == VOID_POINTER || self == BLOCK_POINTER;
<* Equivalent to is_int() || is_float() *>
fn bool ScalarKind.is_arithmetic(self) => self.is_int() || self.is_float();

fn ScalarKind QualType.scalar_kind(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	while (true)
	{
		switch (ty.tag)
		{
			case BOOL: return BOOL;
			case INT:
			case BIT_INT: return INT;
			case FLOAT: return FLOAT;
			case NULLPTR_T: return NULLPTR_T;
			case POINTER: return ty.pointer.child.base(comp).ty.tag == VOID ? VOID_POINTER : POINTER;
			case ENUM: return ENUM;
			case COMPLEX:
				switch (ty.complex.base(comp).ty.tag)
				{
					case INT:
					case BIT_INT: return COMPLEX_INT;
					case FLOAT: return COMPLEX_FLOAT;
					default: unreachable("complex of a non-arithmetic type");
				}
			case ATOMIC: ty = ty.atomic.base(comp).ty;
			case BLOCK: return BLOCK_POINTER;
			default: return NONE;
		}
	}
}

fn bool QualType.is_int(self, Compilation* comp) => self.scalar_kind(comp).is_int();
fn bool QualType.is_real_int(self, Compilation* comp)
{
	ScalarKind sk = self.scalar_kind(comp);
	return sk.is_int() && sk.is_real();
}
fn bool QualType.is_float(self, Compilation* comp) => self.scalar_kind(comp).is_float();
fn bool QualType.is_pointer(self, Compilation* comp) => self.scalar_kind(comp).is_pointer();

fn bool QualType.eql_qualified(self, QualType b, Compilation* comp)
{
	if (self.is_const != b.is_const) return false;
	if (self.is_volatile != b.is_volatile) return false;
	if (self.is_restrict != b.is_restrict) return false;
	return self.eql(b, comp);
}

<* Type equality ignoring top-level qualifiers (Zig QualType.eql). invalid equals nothing. *>
fn bool QualType.eql(self, QualType b_qt, Compilation* comp)
{
	if (self.is_invalid() || b_qt.is_invalid()) return false;
	if (self.index == b_qt.index) return true;

	BaseType a_base = self.base(comp);
	Type a_type = a_base.ty;
	BaseType b_base = b_qt.base(comp);
	Type b_type = b_base.ty;

	// Alignment check also guards against comparing incomplete enums to ints.
	if (a_base.qt.alignof(comp) != b_base.qt.alignof(comp)) return false;
	if (a_type.tag == ENUM && b_type.tag != ENUM)
	{
		return a_type.enum_ty.tag.eql(b_qt, comp);
	}
	else if (a_type.tag != ENUM && b_type.tag == ENUM)
	{
		return b_type.enum_ty.tag.eql(self, comp);
	}

	if (a_type.tag != b_type.tag) return false;
	switch (a_type.tag)
	{
		case VOID:
		case BOOL:
		case NULLPTR_T: return true;
		case STORAGE_FLOAT: return a_type.storage_float == b_type.storage_float;
		case INT: return a_type.int_ty == b_type.int_ty;
		case FLOAT: return a_type.float_ty == b_type.float_ty;
		// Complex child type cannot be qualified.
		case COMPLEX: return a_type.complex.eql(b_type.complex, comp);
		case BIT_INT:
			return a_type.bit_int.bits == b_type.bit_int.bits && a_type.bit_int.signedness == b_type.bit_int.signedness;
		// Atomic child type cannot be qualified.
		case ATOMIC: return a_type.atomic.eql(b_type.atomic, comp);
		case FUNC:
			Func a_func = a_type.func;
			Func b_func = b_type.func;
			// Function return type cannot be qualified.
			if (!a_func.return_type.eql(b_func.return_type, comp)) return false;
			if (a_func.params.len == 0 && b_func.params.len == 0)
			{
				return (a_func.kind == VARIADIC) == (b_func.kind == VARIADIC);
			}
			if (a_func.params.len != b_func.params.len)
			{
				if (a_func.kind == OLD_STYLE && b_func.kind == OLD_STYLE) return true;
				if (a_func.kind == OLD_STYLE || b_func.kind == OLD_STYLE)
				{
					Func maybe_has_params = a_func.kind == OLD_STYLE ? b_func : a_func;
					// Check if any args undergo default argument promotion.
					foreach (param : maybe_has_params.params)
					{
						Type pt = param.qt.base(comp).ty;
						switch (pt.tag)
						{
							case BOOL: return false;
							case INT:
								switch (pt.int_ty)
								{
									case CHAR:
									case UCHAR:
									case SCHAR: return false;
									default: break;
								}
							case FLOAT:
								if (pt.float_ty != DOUBLE) return false;
							case ENUM:
								if (comp.langopts.emulate == CLANG && pt.enum_ty.incomplete) return false;
							default: break;
						}
					}
					return true;
				}
				return false;
			}
			if ((a_func.kind == NORMAL) != (b_func.kind == NORMAL)) return false;
			foreach (i, a_param : a_func.params)
			{
				// Function parameters cannot be qualified.
				if (!a_param.qt.eql(b_func.params[i].qt, comp)) return false;
			}
			return true;
		case POINTER: return a_type.pointer.child.eql_qualified(b_type.pointer.child, comp);
		case ARRAY:
			ArrayLen a_len = a_type.array.len;
			ArrayLen b_len = b_type.array.len;
			if (a_len.is_sized() && b_len.is_sized()) return a_len.len == b_len.len;
			// Array element qualifiers are ignored.
			return a_type.array.elem.eql(b_type.array.elem, comp);
		case VECTOR: return a_type.vector.eql(b_type.vector, comp, false);
		case STRUCT:
		case UNION:
		case ENUM: return a_base.qt.index == b_base.qt.index;
		case BLOCK: return a_type.block.func.eql(b_type.block.func, comp);
		case TYPEOF:
		case TYPEDEF: unreachable("never returned from base()");
	}
}

fn bool Vector.eql(self, Vector b, Compilation* comp, bool check_kind)
{
	if (self.len != b.len) return false;
	if (!self.elem.eql_qualified(b.elem, comp)) return false;
	if (check_kind && self.kind != b.kind) return false;
	return true;
}

<* Array-to-pointer and function-to-pointer decay; other types are returned unchanged. *>
fn QualType QualType.decay(self, Compilation* comp)
{
	if (self.is_invalid()) return INVALID;
	Type ty = self.base(comp).ty;
	switch (ty.tag)
	{
		case ARRAY:
			// Copy const and volatile to the element
			QualType elem_qt = ty.array.elem;
			elem_qt.is_const = self.is_const || elem_qt.is_const;
			elem_qt.is_volatile = self.is_volatile || elem_qt.is_volatile;
			QualType pointer_qt = comp.type_store.put(type_decayed_pointer(elem_qt, self));
			// .. and restrict to the pointer.
			pointer_qt.is_restrict = self.is_restrict || ty.array.elem.is_restrict;
			return pointer_qt;
		case FUNC:
			if (ty.func.return_type.is_invalid()) return INVALID;
			foreach (param : ty.func.params)
			{
				if (param.qt.is_invalid()) return INVALID;
			}
			return comp.type_store.put(type_pointer(self));
		default: return self;
	}
}

<*
 Make a real int type unsigned. Discards attributes.
 @require self.is(comp, INT) || self.is(comp, BIT_INT)
*>
fn QualType QualType.make_int_unsigned(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	switch (ty.tag)
	{
		case INT:
			switch (ty.int_ty)
			{
				case CHAR:
				case SCHAR:
				case UCHAR: return UCHAR;
				case SHORT:
				case USHORT: return USHORT;
				case INT:
				case UINT: return UINT;
				case LONG:
				case ULONG: return ULONG;
				case LONG_LONG:
				case ULONG_LONG: return ULONG_LONG;
				case INT128:
				case UINT128: return UINT128;
				case INT24:
				case UINT24: return UINT24;
			}
		case BIT_INT:
			return comp.type_store.put(type_bit_int(ty.bit_int.bits, UNSIGNED));
		default: unreachable("not a real integer type");
	}
}

fn QualType QualType.to_real(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	if (ty.tag == COMPLEX) return ty.complex;
	return self;
}

<* @require !self.is(comp, COMPLEX) : "already complex" *>
fn QualType QualType.to_complex(self, Compilation* comp)
{
	$if env::COMPILER_SAFE_MODE:
		Type ty = self.base(comp).ty;
		switch (ty.tag)
		{
			case FLOAT: assert(ty.float_ty != FP16);
			case INT:
			case BIT_INT: break;
			default: unreachable("not an arithmetic real type");
		}
	$endif
	return comp.type_store.put(type_complex(self));
}

<* Length of a fixed/static array, or of the array a pointer decayed from. *>
fn ulong? QualType.array_len(self, Compilation* comp)
{
	Type ty = self.base(comp).ty;
	Array array;
	switch (ty.tag)
	{
		case ARRAY: array = ty.array;
		case POINTER:
			if (!ty.pointer.has_decayed) return NO_LEN~;
			Type? decayed = ty.pointer.decayed.get(comp, ARRAY);
			if (catch decayed) return NO_LEN~;
			array = decayed.array;
		default: return NO_LEN~;
	}
	if (array.len.is_sized()) return array.len.len;
	return NO_LEN~;
}

<* Suffix for integer values of this type. @require self.is(comp, INT) *>
fn String QualType.int_value_suffix(self, Compilation* comp)
{
	Type ty = self.get(comp, INT)!!;
	switch (ty.int_ty)
	{
		case SHORT:
		case INT: return "";
		case LONG: return "L";
		case LONG_LONG: return "LL";
		case SCHAR:
		case UCHAR:
		case CHAR:
			// Only 8-bit char supported currently
			assert(self.bit_sizeof(comp) == 8);
			return "";
		case USHORT:
			if (self.sizeof(comp) < INT.sizeof(comp)) return "";
			return "U";
		case UINT: return "U";
		case ULONG: return "UL";
		case ULONG_LONG: return "ULL";
		default: unreachable("TODO");
	}
}

<* printf format modifier. @require self.is(comp, INT) *>
fn String QualType.format_modifier(self, Compilation* comp)
{
	Type ty = self.get(comp, INT)!!;
	switch (ty.int_ty)
	{
		case SCHAR:
		case UCHAR: return "hh";
		case SHORT:
		case USHORT: return "h";
		case INT:
		case UINT: return "";
		case LONG:
		case ULONG: return "l";
		case LONG_LONG:
		case ULONG_LONG: return "ll";
		default: unreachable("TODO");
	}
}
