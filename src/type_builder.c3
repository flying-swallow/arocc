// Port of TypeStore.Builder from src/aro/TypeStore.zig.
module aro::type_store;
import aro::compilation, aro::parser, aro::lang_opts, aro::diagnostics, aro::tokens;
import std::core::dstring;


enum BuilderSpecifierTag : char
{
	NONE,
	VOID,
	AUTO_TYPE,
	C23_AUTO,
	NULLPTR_T,
	BOOL,
	CHAR,
	SCHAR,
	UCHAR,
	COMPLEX_CHAR,
	COMPLEX_SCHAR,
	COMPLEX_UCHAR,
	UNSIGNED,
	SIGNED,
	SHORT,
	SSHORT,
	USHORT,
	SHORT_INT,
	SSHORT_INT,
	USHORT_INT,
	INT,
	SINT,
	UINT,
	LONG,
	SLONG,
	ULONG,
	LONG_INT,
	SLONG_INT,
	ULONG_INT,
	LONG_LONG,
	SLONG_LONG,
	ULONG_LONG,
	LONG_LONG_INT,
	SLONG_LONG_INT,
	ULONG_LONG_INT,
	INT128,
	SINT128,
	UINT128,
	INT24,
	SINT24,
	UINT24,
	COMPLEX_UNSIGNED,
	COMPLEX_SIGNED,
	COMPLEX_SHORT,
	COMPLEX_SSHORT,
	COMPLEX_USHORT,
	COMPLEX_SHORT_INT,
	COMPLEX_SSHORT_INT,
	COMPLEX_USHORT_INT,
	COMPLEX_INT,
	COMPLEX_SINT,
	COMPLEX_UINT,
	COMPLEX_LONG,
	COMPLEX_SLONG,
	COMPLEX_ULONG,
	COMPLEX_LONG_INT,
	COMPLEX_SLONG_INT,
	COMPLEX_ULONG_INT,
	COMPLEX_LONG_LONG,
	COMPLEX_SLONG_LONG,
	COMPLEX_ULONG_LONG,
	COMPLEX_LONG_LONG_INT,
	COMPLEX_SLONG_LONG_INT,
	COMPLEX_ULONG_LONG_INT,
	COMPLEX_INT128,
	COMPLEX_SINT128,
	COMPLEX_UINT128,
	COMPLEX_INT24,
	COMPLEX_SINT24,
	COMPLEX_UINT24,
	BIT_INT,
	SBIT_INT,
	UBIT_INT,
	COMPLEX_BIT_INT,
	COMPLEX_SBIT_INT,
	COMPLEX_UBIT_INT,
	BF16,
	FP16,
	MFP8,
	FLOAT16,
	FLOAT,
	DOUBLE,
	LONG_DOUBLE,
	FLOAT128,
	FLOAT32,
	FLOAT64,
	FLOAT32X,
	FLOAT64X,
	FLOAT128X,
	DFLOAT32,
	DFLOAT64,
	DFLOAT128,
	DFLOAT64X,
	COMPLEX,
	COMPLEX_FLOAT16,
	COMPLEX_FLOAT,
	COMPLEX_DOUBLE,
	COMPLEX_LONG_DOUBLE,
	COMPLEX_FLOAT128,
	COMPLEX_FLOAT32,
	COMPLEX_FLOAT64,
	COMPLEX_FLOAT32X,
	COMPLEX_FLOAT64X,
	COMPLEX_FLOAT128X,
	OTHER,
}

enum BuilderNullability : char
{
	NO_NULLABILITY,
	NONNULL,
	NULLABLE,
	NULLABLE_RESULT,
	NULL_UNSPECIFIED,
}

<* Flattened C3 representation of Zig Builder.Specifier union(enum). *>
struct BuilderSpecifier
{
	BuilderSpecifierTag tag;
	ulong bits; // payload for bit-int specifiers
	QualType other;
}

struct Builder
{
	parser::Parser* parser;
	tokens::TokenIndex const_tok;
	tokens::TokenIndex atomic_tok;
	tokens::TokenIndex volatile_tok;
	tokens::TokenIndex restrict_tok;
	tokens::TokenIndex unaligned_tok;
	tokens::TokenIndex complex_tok;
	tokens::TokenIndex bit_int_tok;
	tokens::TokenIndex atomic_type_tok;
	tokens::TokenIndex nullability_tok;
	bool has_const;
	bool has_atomic;
	bool has_volatile;
	bool has_restrict;
	bool has_unaligned;
	bool has_complex_tok;
	bool has_bit_int_tok;
	bool has_atomic_type_tok;
	BuilderNullability nullability;
	bool is_typedef;
	bool is_typeof;
	bool error_on_invalid;
	BuilderSpecifier type;
}

<* A typedef can be adopted only before any explicit type specifier. *>
fn bool Builder.combine_typedef(&self, QualType typedef_qt)
{
	if (self.type.tag != NONE) return false;
	self.is_typedef = true;
	self.type = { .tag = OTHER, .other = typedef_qt };
	return true;
}

<* Return the source spelling where the specifier has a simple spelling. *>
fn String? BuilderSpecifier.str(self, lang_opts::LangOpts* opts)
{
	switch (self.tag)
	{
		case BOOL: return opts.standard.at_least(C23) ? "bool" : "_Bool";
		case VOID: return "void";
		case AUTO_TYPE: return "__auto_type";
		case C23_AUTO: return "auto";
		case NULLPTR_T: return "nullptr_t";
		case CHAR: return "char";
		case SCHAR: return "signed char";
		case UCHAR: return "unsigned char";
		case UNSIGNED: return "unsigned";
		case SIGNED: return "signed";
		case SHORT: return "short";
		case USHORT: return "unsigned short";
		case SSHORT: return "signed short";
		case SHORT_INT: return "short int";
		case SSHORT_INT: return "signed short int";
		case USHORT_INT: return "unsigned short int";
		case INT: return "int";
		case SINT: return "signed int";
		case UINT: return "unsigned int";
		case LONG: return "long";
		case SLONG: return "signed long";
		case ULONG: return "unsigned long";
		case LONG_INT: return "long int";
		case SLONG_INT: return "signed long int";
		case ULONG_INT: return "unsigned long int";
		case LONG_LONG: return "long long";
		case SLONG_LONG: return "signed long long";
		case ULONG_LONG: return "unsigned long long";
		case LONG_LONG_INT: return "long long int";
		case SLONG_LONG_INT: return "signed long long int";
		case ULONG_LONG_INT: return "unsigned long long int";
		case INT128: return "__int128";
		case SINT128: return "signed __int128";
		case UINT128: return "unsigned __int128";
		case INT24: return "__int24";
		case SINT24: return "signed __int24";
		case UINT24: return "unsigned __int24";
		case COMPLEX_CHAR: return "_Complex char";
		case COMPLEX_SCHAR: return "_Complex signed char";
		case COMPLEX_UCHAR: return "_Complex unsigned char";
		case COMPLEX_UNSIGNED: return "_Complex unsigned";
		case COMPLEX_SIGNED: return "_Complex signed";
		case COMPLEX_SHORT: return "_Complex short";
		case COMPLEX_USHORT: return "_Complex unsigned short";
		case COMPLEX_SSHORT: return "_Complex signed short";
		case COMPLEX_SHORT_INT: return "_Complex short int";
		case COMPLEX_SSHORT_INT: return "_Complex signed short int";
		case COMPLEX_USHORT_INT: return "_Complex unsigned short int";
		case COMPLEX_INT: return "_Complex int";
		case COMPLEX_SINT: return "_Complex signed int";
		case COMPLEX_UINT: return "_Complex unsigned int";
		case COMPLEX_LONG: return "_Complex long";
		case COMPLEX_SLONG: return "_Complex signed long";
		case COMPLEX_ULONG: return "_Complex unsigned long";
		case COMPLEX_LONG_INT: return "_Complex long int";
		case COMPLEX_SLONG_INT: return "_Complex signed long int";
		case COMPLEX_ULONG_INT: return "_Complex unsigned long int";
		case COMPLEX_LONG_LONG: return "_Complex long long";
		case COMPLEX_SLONG_LONG: return "_Complex signed long long";
		case COMPLEX_ULONG_LONG: return "_Complex unsigned long long";
		case COMPLEX_LONG_LONG_INT: return "_Complex long long int";
		case COMPLEX_SLONG_LONG_INT: return "_Complex signed long long int";
		case COMPLEX_ULONG_LONG_INT: return "_Complex unsigned long long int";
		case COMPLEX_INT128: return "_Complex __int128";
		case COMPLEX_SINT128: return "_Complex signed __int128";
		case COMPLEX_UINT128: return "_Complex unsigned __int128";
		case COMPLEX_INT24: return "_Complex __int24";
		case COMPLEX_SINT24: return "_Complex signed __int24";
		case COMPLEX_UINT24: return "_Complex unsigned __int24";
		case BF16: return "__bf16";
		case FP16: return "__fp16";
		case MFP8: return "__mfp8";
		case FLOAT16: return "_Float16";
		case FLOAT: return "float";
		case DOUBLE: return "double";
		case LONG_DOUBLE: return "long double";
		case FLOAT128: return "__float128";
		case COMPLEX: return "_Complex";
		case COMPLEX_FLOAT16: return "_Complex _Float16";
		case COMPLEX_FLOAT: return "_Complex float";
		case COMPLEX_DOUBLE: return "_Complex double";
		case COMPLEX_LONG_DOUBLE: return "_Complex long double";
		case COMPLEX_FLOAT128: return "_Complex __float128";
		default: return NO_SPECIFIER_STR~;
	}
}

<* Map a concrete type back to declaration specifiers (used by _Atomic(type)). *>
fn BuilderSpecifier builder_from_type(Compilation* comp, QualType qt)
{
	Type ty = qt.base(comp).ty;
	switch (ty.tag)
	{
		case VOID: return { .tag = VOID };
		case NULLPTR_T: return { .tag = NULLPTR_T };
		case BOOL: return { .tag = BOOL };
		case INT: return builder_from_int_type(ty.int_ty);
		case FLOAT: return builder_from_float_type(ty.float_ty);
		case STORAGE_FLOAT: return { .tag = MFP8 };
		case BIT_INT:
			return { .tag = ty.bit_int.signedness == UNSIGNED ? UBIT_INT : BIT_INT, .bits = ty.bit_int.bits };
		case COMPLEX:
			BuilderSpecifier base = builder_from_type(comp, ty.complex);
			return builder_as_complex(base);
		default: return { .tag = OTHER, .other = qt };
	}
}

fn BuilderSpecifier builder_from_int_type(TypeInt ty) => { .tag = ty.builder };

fn BuilderSpecifier builder_from_float_type(TypeFloat ty) => { .tag = ty.builder };

<* Convert the supported scalar specifier to its `_Complex` spelling. *>
fn BuilderSpecifier builder_as_complex(BuilderSpecifier base)
{
	switch (base.tag)
	{
		case CHAR: return { .tag = COMPLEX_CHAR };
		case SCHAR: return { .tag = COMPLEX_SCHAR };
		case UCHAR: return { .tag = COMPLEX_UCHAR };
		case BIT_INT: return { .tag = COMPLEX_BIT_INT, .bits = base.bits };
		case SBIT_INT: return { .tag = COMPLEX_SBIT_INT, .bits = base.bits };
		case UBIT_INT: return { .tag = COMPLEX_UBIT_INT, .bits = base.bits };
		case UNSIGNED: return { .tag = COMPLEX_UNSIGNED };
		case UINT: return { .tag = COMPLEX_UINT };
		case SIGNED: return { .tag = COMPLEX_SIGNED };
		case INT: return { .tag = COMPLEX_INT };
		case SINT: return { .tag = COMPLEX_SINT };
		case SHORT: return { .tag = COMPLEX_SHORT };
		case SSHORT: return { .tag = COMPLEX_SSHORT };
		case USHORT: return { .tag = COMPLEX_USHORT };
		case LONG: return { .tag = COMPLEX_LONG };
		case SLONG: return { .tag = COMPLEX_SLONG };
		case ULONG: return { .tag = COMPLEX_ULONG };
		case LONG_LONG: return { .tag = COMPLEX_LONG_LONG };
		case SLONG_LONG: return { .tag = COMPLEX_SLONG_LONG };
		case ULONG_LONG: return { .tag = COMPLEX_ULONG_LONG };
		case INT128: return { .tag = COMPLEX_INT128 };
		case SINT128: return { .tag = COMPLEX_SINT128 };
		case UINT128: return { .tag = COMPLEX_UINT128 };
		case INT24: return { .tag = COMPLEX_INT24 };
		case SINT24: return { .tag = COMPLEX_SINT24 };
		case UINT24: return { .tag = COMPLEX_UINT24 };
		case FLOAT16: return { .tag = COMPLEX_FLOAT16 };
		case FLOAT: return { .tag = COMPLEX_FLOAT };
		case DOUBLE: return { .tag = COMPLEX_DOUBLE };
		case LONG_DOUBLE: return { .tag = COMPLEX_LONG_DOUBLE };
		case FLOAT128: return { .tag = COMPLEX_FLOAT128 };
		case FLOAT32: return { .tag = COMPLEX_FLOAT32 };
		case FLOAT64: return { .tag = COMPLEX_FLOAT64 };
		case FLOAT32X: return { .tag = COMPLEX_FLOAT32X };
		case FLOAT64X: return { .tag = COMPLEX_FLOAT64X };
		case FLOAT128X: return { .tag = COMPLEX_FLOAT128X };
		default: return { .tag = COMPLEX, .other = base.other };
	}
}

<* Zig `Builder.Specifier` union tag spelling, as printed by `@tagName`. *>
fn String BuilderSpecifierTag.zig_name(self)
{
	switch (self)
	{
		case NONE: return "none";
		case VOID: return "void";
		case AUTO_TYPE: return "auto_type";
		case C23_AUTO: return "c23_auto";
		case NULLPTR_T: return "nullptr_t";
		case BOOL: return "bool";
		case CHAR: return "char";
		case SCHAR: return "schar";
		case UCHAR: return "uchar";
		case COMPLEX_CHAR: return "complex_char";
		case COMPLEX_SCHAR: return "complex_schar";
		case COMPLEX_UCHAR: return "complex_uchar";
		case UNSIGNED: return "unsigned";
		case SIGNED: return "signed";
		case SHORT: return "short";
		case SSHORT: return "sshort";
		case USHORT: return "ushort";
		case SHORT_INT: return "short_int";
		case SSHORT_INT: return "sshort_int";
		case USHORT_INT: return "ushort_int";
		case INT: return "int";
		case SINT: return "sint";
		case UINT: return "uint";
		case LONG: return "long";
		case SLONG: return "slong";
		case ULONG: return "ulong";
		case LONG_INT: return "long_int";
		case SLONG_INT: return "slong_int";
		case ULONG_INT: return "ulong_int";
		case LONG_LONG: return "long_long";
		case SLONG_LONG: return "slong_long";
		case ULONG_LONG: return "ulong_long";
		case LONG_LONG_INT: return "long_long_int";
		case SLONG_LONG_INT: return "slong_long_int";
		case ULONG_LONG_INT: return "ulong_long_int";
		case INT128: return "int128";
		case SINT128: return "sint128";
		case UINT128: return "uint128";
		case INT24: return "int24";
		case SINT24: return "sint24";
		case UINT24: return "uint24";
		case COMPLEX_UNSIGNED: return "complex_unsigned";
		case COMPLEX_SIGNED: return "complex_signed";
		case COMPLEX_SHORT: return "complex_short";
		case COMPLEX_SSHORT: return "complex_sshort";
		case COMPLEX_USHORT: return "complex_ushort";
		case COMPLEX_SHORT_INT: return "complex_short_int";
		case COMPLEX_SSHORT_INT: return "complex_sshort_int";
		case COMPLEX_USHORT_INT: return "complex_ushort_int";
		case COMPLEX_INT: return "complex_int";
		case COMPLEX_SINT: return "complex_sint";
		case COMPLEX_UINT: return "complex_uint";
		case COMPLEX_LONG: return "complex_long";
		case COMPLEX_SLONG: return "complex_slong";
		case COMPLEX_ULONG: return "complex_ulong";
		case COMPLEX_LONG_INT: return "complex_long_int";
		case COMPLEX_SLONG_INT: return "complex_slong_int";
		case COMPLEX_ULONG_INT: return "complex_ulong_int";
		case COMPLEX_LONG_LONG: return "complex_long_long";
		case COMPLEX_SLONG_LONG: return "complex_slong_long";
		case COMPLEX_ULONG_LONG: return "complex_ulong_long";
		case COMPLEX_LONG_LONG_INT: return "complex_long_long_int";
		case COMPLEX_SLONG_LONG_INT: return "complex_slong_long_int";
		case COMPLEX_ULONG_LONG_INT: return "complex_ulong_long_int";
		case COMPLEX_INT128: return "complex_int128";
		case COMPLEX_SINT128: return "complex_sint128";
		case COMPLEX_UINT128: return "complex_uint128";
		case COMPLEX_INT24: return "complex_int24";
		case COMPLEX_SINT24: return "complex_sint24";
		case COMPLEX_UINT24: return "complex_uint24";
		case BIT_INT: return "bit_int";
		case SBIT_INT: return "sbit_int";
		case UBIT_INT: return "ubit_int";
		case COMPLEX_BIT_INT: return "complex_bit_int";
		case COMPLEX_SBIT_INT: return "complex_sbit_int";
		case COMPLEX_UBIT_INT: return "complex_ubit_int";
		case BF16: return "bf16";
		case FP16: return "fp16";
		case MFP8: return "mfp8";
		case FLOAT16: return "float16";
		case FLOAT: return "float";
		case DOUBLE: return "double";
		case LONG_DOUBLE: return "long_double";
		case FLOAT128: return "float128";
		case FLOAT32: return "float32";
		case FLOAT64: return "float64";
		case FLOAT32X: return "float32x";
		case FLOAT64X: return "float64x";
		case FLOAT128X: return "float128x";
		case DFLOAT32: return "dfloat32";
		case DFLOAT64: return "dfloat64";
		case DFLOAT128: return "dfloat128";
		case DFLOAT64X: return "dfloat64x";
		case COMPLEX: return "complex";
		case COMPLEX_FLOAT16: return "complex_float16";
		case COMPLEX_FLOAT: return "complex_float";
		case COMPLEX_DOUBLE: return "complex_double";
		case COMPLEX_LONG_DOUBLE: return "complex_long_double";
		case COMPLEX_FLOAT128: return "complex_float128";
		case COMPLEX_FLOAT32: return "complex_float32";
		case COMPLEX_FLOAT64: return "complex_float64";
		case COMPLEX_FLOAT32X: return "complex_float32x";
		case COMPLEX_FLOAT64X: return "complex_float64x";
		case COMPLEX_FLOAT128X: return "complex_float128x";
		case OTHER: return "other";
	}
}

fn void? Builder.cannot_combine_with_typeof(&self, BuilderSpecifierTag tag, tokens::TokenIndex tok)
{
	return self.err(Diagnostic.CANNOT_COMBINE_WITH_TYPEOF, tok, tag.zig_name());
}

macro void? Builder.err(&self, Diagnostic $diag, tokens::TokenIndex tok, ...)
{
	return $diag.@emit(self.parser, tok, ...$vaarg);
}

fn parser::QtArg Builder.fmt_qt(&self, type_store::QualType qt) => self.parser.fmt_qt(qt);

fn void? Builder.cannot_combine(&self, tokens::TokenIndex tok)
{
	if (try value = self.type.str(&self.parser.comp.langopts))
	{
		return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, value);
	}
	QualType qt = self.finish_quals(self.type.other)!;
	// Zig's QualType.print reaches `unreachable` on the invalid index (TypeStore.zig
	// `.invalid => unreachable` in Type lookup), so there is no Zig output to match.
	// Emit the literal `invalid` here instead of trapping in C3's printer.
	if (qt.is_invalid()) return Diagnostic.CANNOT_COMBINE_SPEC_QT.@emit(self.parser, tok, "'invalid'");
	return self.err(Diagnostic.CANNOT_COMBINE_SPEC_QT, tok, self.fmt_qt(qt));
}

fn void? Builder.duplicate_spec(&self, tokens::TokenIndex tok, String spelling)
{
	if (self.parser.comp.langopts.emulate == GCC) return self.cannot_combine(tok);
	return Diagnostic.DUPLICATE_DECL_SPEC.@emit(self.parser, self.parser.tok_i, spelling);
}

<* Combine one declaration specifier using TypeStore.Builder's source-derived
 integer, floating, complex, and modifier productions. *>
fn void? Builder.combine(&self, BuilderSpecifier incoming, tokens::TokenIndex tok)
{
	if (self.is_typeof) return self.cannot_combine_with_typeof(incoming.tag, tok);
	if (self.has_atomic_type_tok) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "_Atomic");
	if (self.is_typedef) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "type-name");
	if (self.type.tag == OTHER && self.type.other.is_invalid()) return;
	if (incoming.tag == COMPLEX) { self.complex_tok = tok; self.has_complex_tok = true; }
	if (incoming.tag == BIT_INT) { self.bit_int_tok = tok; self.has_bit_int_tok = true; }
	if (incoming.tag == INT128 && !self.parser.comp.target.has_int128()) Diagnostic.TYPE_NOT_SUPPORTED_ON_TARGET.@emit(self.parser, tok, "__int128")!;

	BuilderSpecifierTag old = self.type.tag;
	BuilderSpecifierTag next = NONE;
	bool valid = true;
	if (old == NONE) { next = incoming.tag; }
	else
	{
	switch (incoming.tag)
	{
		case SIGNED:
			switch (old)
			{
				case CHAR: next = SCHAR; case SHORT: next = SSHORT; case SHORT_INT: next = SSHORT_INT;
				case INT: next = SINT; case LONG: next = SLONG; case LONG_INT: next = SLONG_INT;
				case LONG_LONG: next = SLONG_LONG; case LONG_LONG_INT: next = SLONG_LONG_INT;
				case INT128: next = SINT128; case INT24: next = SINT24; case BIT_INT: next = SBIT_INT;
				case COMPLEX: next = COMPLEX_SIGNED; case COMPLEX_CHAR: next = COMPLEX_SCHAR;
				case COMPLEX_SHORT: next = COMPLEX_SSHORT; case COMPLEX_SHORT_INT: next = COMPLEX_SSHORT_INT;
				case COMPLEX_INT: next = COMPLEX_SINT; case COMPLEX_LONG: next = COMPLEX_SLONG;
				case COMPLEX_LONG_INT: next = COMPLEX_SLONG_INT; case COMPLEX_LONG_LONG: next = COMPLEX_SLONG_LONG;
				case COMPLEX_LONG_LONG_INT: next = COMPLEX_SLONG_LONG_INT; case COMPLEX_INT128: next = SINT128; // TypeStore.zig returns .sint128 here.
				case COMPLEX_INT24: next = COMPLEX_SINT24; case COMPLEX_BIT_INT: next = COMPLEX_SBIT_INT;
				case SIGNED: case SSHORT: case SSHORT_INT: case SINT: case SLONG: case SLONG_INT: case SLONG_LONG: case SLONG_LONG_INT: case SINT128: case SINT24: case SBIT_INT: case COMPLEX_SCHAR: case COMPLEX_SIGNED: case COMPLEX_SSHORT: case COMPLEX_SSHORT_INT: case COMPLEX_SINT: case COMPLEX_SLONG: case COMPLEX_SLONG_INT: case COMPLEX_SLONG_LONG: case COMPLEX_SLONG_LONG_INT: case COMPLEX_SINT128: case COMPLEX_SINT24: case COMPLEX_SBIT_INT:
					self.duplicate_spec(tok, "signed")!; return;
				default: valid = false;
			}
		case UNSIGNED:
			switch (old)
			{
				case CHAR: next = UCHAR; case SHORT: next = USHORT; case SHORT_INT: next = USHORT_INT;
				case INT: next = UINT; case LONG: next = ULONG; case LONG_INT: next = ULONG_INT;
				case LONG_LONG: next = ULONG_LONG; case LONG_LONG_INT: next = ULONG_LONG_INT;
				case INT128: next = UINT128; case INT24: next = UINT24; case BIT_INT: next = UBIT_INT;
				case COMPLEX: next = COMPLEX_UNSIGNED; case COMPLEX_CHAR: next = COMPLEX_UCHAR;
				case COMPLEX_SHORT: next = COMPLEX_USHORT; case COMPLEX_SHORT_INT: next = COMPLEX_USHORT_INT;
				case COMPLEX_INT: next = COMPLEX_UINT; case COMPLEX_LONG: next = COMPLEX_ULONG;
				case COMPLEX_LONG_INT: next = COMPLEX_ULONG_INT; case COMPLEX_LONG_LONG: next = COMPLEX_ULONG_LONG;
				case COMPLEX_LONG_LONG_INT: next = COMPLEX_ULONG_LONG_INT; case COMPLEX_INT128: next = COMPLEX_UINT128;
				case COMPLEX_INT24: next = COMPLEX_UINT24; case COMPLEX_BIT_INT: next = COMPLEX_UBIT_INT;
				case UNSIGNED: case USHORT: case USHORT_INT: case UINT: case ULONG: case ULONG_INT: case ULONG_LONG: case ULONG_LONG_INT: case UINT128: case UINT24: case UBIT_INT: case COMPLEX_UCHAR: case COMPLEX_UNSIGNED: case COMPLEX_USHORT: case COMPLEX_USHORT_INT: case COMPLEX_UINT: case COMPLEX_ULONG: case COMPLEX_ULONG_INT: case COMPLEX_ULONG_LONG: case COMPLEX_ULONG_LONG_INT: case COMPLEX_UINT128: case COMPLEX_UINT24: case COMPLEX_UBIT_INT:
					self.duplicate_spec(tok, "unsigned")!; return;
				default: valid = false;
			}
		case CHAR:
			switch (old) { case SIGNED: next = SCHAR; case UNSIGNED: next = UCHAR; case COMPLEX: next = COMPLEX_CHAR; case COMPLEX_SIGNED: next = SCHAR; case COMPLEX_UNSIGNED: next = UCHAR; default: valid = false; }
		case SHORT:
			switch (old) { case SIGNED: next = SSHORT; case UNSIGNED: next = USHORT; case INT: next = SHORT_INT; case SINT: next = SSHORT_INT; case UINT: next = USHORT_INT; case COMPLEX: next = COMPLEX_SHORT; case COMPLEX_SIGNED: next = SSHORT; case COMPLEX_UNSIGNED: next = USHORT; default: valid = false; }
		case INT:
			switch (old)
			{
				case SIGNED: next = SINT; case UNSIGNED: next = UINT; case SHORT: next = SHORT_INT; case SSHORT: next = SSHORT_INT; case USHORT: next = USHORT_INT;
				case LONG: next = LONG_INT; case SLONG: next = SLONG_INT; case ULONG: next = ULONG_INT;
				case LONG_LONG: next = LONG_LONG_INT; case SLONG_LONG: next = SLONG_LONG_INT; case ULONG_LONG: next = ULONG_LONG_INT;
				case COMPLEX: next = COMPLEX_INT; case COMPLEX_SIGNED: next = COMPLEX_SINT; case COMPLEX_UNSIGNED: next = COMPLEX_UINT;
				case COMPLEX_SHORT: next = COMPLEX_SHORT_INT; case COMPLEX_SSHORT: next = COMPLEX_SSHORT_INT; case COMPLEX_USHORT: next = COMPLEX_USHORT_INT;
				case COMPLEX_LONG: next = COMPLEX_LONG_INT; case COMPLEX_SLONG: next = COMPLEX_SLONG_INT; case COMPLEX_ULONG: next = COMPLEX_ULONG_INT;
				case COMPLEX_LONG_LONG: next = COMPLEX_LONG_LONG_INT; case COMPLEX_SLONG_LONG: next = COMPLEX_SLONG_LONG_INT; case COMPLEX_ULONG_LONG: next = COMPLEX_ULONG_LONG_INT;
				default: valid = false;
			}
		case LONG:
			switch (old)
			{
				case SIGNED: next = SLONG; case UNSIGNED: next = ULONG; case INT: next = LONG_INT; case SINT: next = SLONG_INT; case UINT: next = ULONG_INT;
				case LONG: next = LONG_LONG; case SLONG: next = SLONG_LONG; case ULONG: next = ULONG_LONG;
				case LONG_INT: next = LONG_LONG_INT; case SLONG_INT: next = SLONG_LONG_INT; case ULONG_INT: next = ULONG_LONG_INT;
				case DOUBLE: next = LONG_DOUBLE; case COMPLEX: next = COMPLEX_LONG; case COMPLEX_SIGNED: next = COMPLEX_SLONG; case COMPLEX_UNSIGNED: next = COMPLEX_ULONG;
				case COMPLEX_LONG: next = COMPLEX_LONG_LONG; case COMPLEX_SLONG: next = COMPLEX_SLONG_LONG; case COMPLEX_ULONG: next = COMPLEX_ULONG_LONG;
				case COMPLEX_DOUBLE: next = COMPLEX_LONG_DOUBLE;
				default: valid = false;
			}
		case LONG_LONG:
			switch (old)
			{
				case SIGNED: next = SLONG_LONG; case UNSIGNED: next = ULONG_LONG;
				case INT: next = LONG_LONG_INT; case SINT: next = SLONG_LONG_INT;
				case LONG: next = LONG_LONG; case SLONG: next = SLONG_LONG; case ULONG: next = ULONG_LONG;
				case COMPLEX: next = COMPLEX_LONG; // TypeStore.zig maps complex + long long to complex_long.
				case COMPLEX_SIGNED: next = COMPLEX_SLONG_LONG; case COMPLEX_UNSIGNED: next = COMPLEX_ULONG_LONG;
				case COMPLEX_LONG: next = COMPLEX_LONG_LONG; case COMPLEX_SLONG: next = COMPLEX_SLONG_LONG; case COMPLEX_ULONG: next = COMPLEX_ULONG_LONG;
				case LONG_LONG: case ULONG_LONG: case ULONG_LONG_INT: case COMPLEX_LONG_LONG: case COMPLEX_ULONG_LONG: case COMPLEX_ULONG_LONG_INT:
					self.duplicate_spec(tok, "long")!; return;
				default: valid = false;
			}
		case INT128: switch (old) { case SIGNED: next = SINT128; case UNSIGNED: next = UINT128; case COMPLEX: next = COMPLEX_INT128; case COMPLEX_SIGNED: next = COMPLEX_SINT128; case COMPLEX_UNSIGNED: next = COMPLEX_UINT128; default: valid = false; }
		case INT24: switch (old) { case SIGNED: next = SINT24; case UNSIGNED: next = UINT24; case COMPLEX: next = COMPLEX_INT24; case COMPLEX_SIGNED: next = COMPLEX_SINT24; case COMPLEX_UNSIGNED: next = COMPLEX_UINT24; default: valid = false; }
		case BIT_INT:
			switch (old) { case SIGNED: next = SBIT_INT; case UNSIGNED: next = UBIT_INT; case COMPLEX: next = COMPLEX_BIT_INT; case COMPLEX_SIGNED: next = COMPLEX_SBIT_INT; case COMPLEX_UNSIGNED: next = COMPLEX_UBIT_INT; default: valid = false; }
		case FLOAT16: switch (old) { case COMPLEX: next = COMPLEX_FLOAT16; default: valid = false; }
		case FLOAT: switch (old) { case COMPLEX: next = COMPLEX_FLOAT; default: valid = false; }
		case DOUBLE: switch (old) { case LONG: next = LONG_DOUBLE; case COMPLEX: next = COMPLEX_DOUBLE; case COMPLEX_LONG: next = COMPLEX_LONG_DOUBLE; default: valid = false; }
		case FLOAT128: switch (old) { case COMPLEX: next = COMPLEX_FLOAT128; default: valid = false; }
		case FLOAT32: switch (old) { case COMPLEX: next = COMPLEX_FLOAT32; default: valid = false; }
		case FLOAT64: switch (old) { case COMPLEX: next = COMPLEX_FLOAT64; default: valid = false; }
		case FLOAT32X: switch (old) { case COMPLEX: next = COMPLEX_FLOAT32X; default: valid = false; }
		case FLOAT64X: switch (old) { case COMPLEX: next = COMPLEX_FLOAT64X; default: valid = false; }
		case FLOAT128X: switch (old) { case COMPLEX: next = COMPLEX_FLOAT128X; default: valid = false; }
		case COMPLEX:
			switch (old)
			{
				case SIGNED: next = COMPLEX_SIGNED; case UNSIGNED: next = COMPLEX_UNSIGNED;
				case CHAR: next = COMPLEX_CHAR; case SCHAR: next = COMPLEX_SCHAR; case UCHAR: next = COMPLEX_UCHAR;
				case SHORT: next = COMPLEX_SHORT; case SSHORT: next = COMPLEX_SSHORT; case USHORT: next = COMPLEX_USHORT;
				case SHORT_INT: next = COMPLEX_SHORT_INT; case SSHORT_INT: next = COMPLEX_SSHORT_INT; case USHORT_INT: next = COMPLEX_USHORT_INT;
				case INT: next = COMPLEX_INT; case SINT: next = COMPLEX_SINT; case UINT: next = COMPLEX_UINT;
				case LONG: next = COMPLEX_LONG; case SLONG: next = COMPLEX_SLONG; case ULONG: next = COMPLEX_ULONG;
				case LONG_INT: next = COMPLEX_LONG_INT; case SLONG_INT: next = COMPLEX_SLONG_INT; case ULONG_INT: next = COMPLEX_ULONG_INT;
				case LONG_LONG: next = COMPLEX_LONG_LONG; case SLONG_LONG: next = COMPLEX_SLONG_LONG; case ULONG_LONG: next = COMPLEX_ULONG_LONG;
				case LONG_LONG_INT: next = COMPLEX_LONG_LONG_INT; case SLONG_LONG_INT: next = COMPLEX_SLONG_LONG_INT; case ULONG_LONG_INT: next = COMPLEX_ULONG_LONG_INT;
				case INT128: next = COMPLEX_INT128; case SINT128: next = COMPLEX_SINT128; case UINT128: next = COMPLEX_UINT128;
				case INT24: next = COMPLEX_INT24; case SINT24: next = COMPLEX_SINT24; case UINT24: next = COMPLEX_UINT24;
				case BIT_INT: next = COMPLEX_BIT_INT; case SBIT_INT: next = COMPLEX_SBIT_INT; case UBIT_INT: next = COMPLEX_UBIT_INT;
				case FLOAT16: next = COMPLEX_FLOAT16; case FLOAT: next = COMPLEX_FLOAT; case DOUBLE: next = COMPLEX_DOUBLE; case LONG_DOUBLE: next = COMPLEX_LONG_DOUBLE;
				case FLOAT128: next = COMPLEX_FLOAT128; case FLOAT32: next = COMPLEX_FLOAT32; case FLOAT64: next = COMPLEX_FLOAT64;
				case FLOAT32X: next = COMPLEX_FLOAT32X; case FLOAT64X: next = COMPLEX_FLOAT64X; case FLOAT128X: next = COMPLEX_FLOAT128X;
				case COMPLEX: case COMPLEX_CHAR: case COMPLEX_SCHAR: case COMPLEX_UCHAR: case COMPLEX_SIGNED: case COMPLEX_UNSIGNED: case COMPLEX_SHORT: case COMPLEX_SSHORT: case COMPLEX_USHORT: case COMPLEX_INT: case COMPLEX_SINT: case COMPLEX_UINT: case COMPLEX_SHORT_INT: case COMPLEX_SSHORT_INT: case COMPLEX_USHORT_INT: case COMPLEX_LONG: case COMPLEX_SLONG: case COMPLEX_ULONG: case COMPLEX_LONG_INT: case COMPLEX_SLONG_INT: case COMPLEX_ULONG_INT: case COMPLEX_LONG_LONG: case COMPLEX_SLONG_LONG: case COMPLEX_ULONG_LONG: case COMPLEX_LONG_LONG_INT: case COMPLEX_SLONG_LONG_INT: case COMPLEX_ULONG_LONG_INT: case COMPLEX_INT128: case COMPLEX_SINT128: case COMPLEX_UINT128: case COMPLEX_INT24: case COMPLEX_SINT24: case COMPLEX_UINT24: case COMPLEX_BIT_INT: case COMPLEX_SBIT_INT: case COMPLEX_UBIT_INT: case COMPLEX_FLOAT: case COMPLEX_DOUBLE: case COMPLEX_LONG_DOUBLE: case COMPLEX_FLOAT128: case COMPLEX_FLOAT32: case COMPLEX_FLOAT64: case COMPLEX_FLOAT32X: case COMPLEX_FLOAT64X: case COMPLEX_FLOAT128X:
					self.duplicate_spec(tok, "_Complex")!; return;
				default: valid = false;
			}
		default: valid = false;
	}
	}
	if (!valid) return self.cannot_combine(tok);
	self.type.tag = next;
	if (incoming.tag == BIT_INT || next == SBIT_INT || next == UBIT_INT || next == COMPLEX_BIT_INT || next == COMPLEX_SBIT_INT || next == COMPLEX_UBIT_INT) self.type.bits = incoming.bits != 0 ? incoming.bits : self.type.bits;
	if (next == OTHER) self.type.other = incoming.other;
}

<* Convert the completed specifier sequence to a QualType and validate its
 qualifiers. Auto specifiers remain sentinels for declaration-level deduction. *>
fn QualType? Builder.finish(&self)
{
	QualType qt = INVALID;
	switch (self.type.tag)
	{
		case NONE:
			if (self.parser.comp.langopts.standard.at_least(C23))
			{
				Diagnostic.MISSING_TYPE_SPECIFIER_C23.@emit(self.parser, self.parser.tok_i)!;
			}
			else
			{
				Diagnostic.MISSING_TYPE_SPECIFIER.@emit(self.parser, self.parser.tok_i)!;
			}
			qt = INT;
		case OTHER: qt = self.type.other;
		case VOID: qt = VOID; case BOOL: qt = BOOL; case NULLPTR_T: qt = NULLPTR_T;
		case CHAR: qt = CHAR; case SCHAR: qt = SCHAR; case UCHAR: qt = UCHAR;
		case SHORT: case SSHORT: case SHORT_INT: case SSHORT_INT: qt = SHORT;
		case USHORT: case USHORT_INT: qt = USHORT;
		case SIGNED: case INT: case SINT: qt = INT; case UNSIGNED: case UINT: qt = UINT;
		case LONG: case SLONG: case LONG_INT: case SLONG_INT: qt = LONG; case ULONG: case ULONG_INT: qt = ULONG;
		case LONG_LONG: case SLONG_LONG: case LONG_LONG_INT: case SLONG_LONG_INT: qt = LONG_LONG; case ULONG_LONG: case ULONG_LONG_INT: qt = ULONG_LONG;
		case INT128: case SINT128: qt = INT128; case UINT128: qt = UINT128;
		case INT24: case SINT24: qt = INT24; case UINT24: qt = UINT24;
		case BF16: qt = BF16; case FP16: qt = FP16; case MFP8: qt = MFP8; case FLOAT16: qt = FLOAT16;
		case FLOAT: qt = FLOAT; case DOUBLE: qt = DOUBLE; case LONG_DOUBLE: qt = LONG_DOUBLE; case FLOAT128: qt = FLOAT128;
		case FLOAT32: qt = FLOAT32; case FLOAT64: qt = FLOAT64; case FLOAT32X: qt = FLOAT32X; case FLOAT64X: qt = FLOAT64X; case FLOAT128X: qt = FLOAT128X;
		case DFLOAT32: qt = DFLOAT32; case DFLOAT64: qt = DFLOAT64; case DFLOAT128: qt = DFLOAT128; case DFLOAT64X: qt = DFLOAT64X;
		case AUTO_TYPE: qt = AUTO_TYPE;
		case C23_AUTO: qt = C23_AUTO;
		case BIT_INT: case SBIT_INT: case UBIT_INT:
			bool uns = self.type.tag == UBIT_INT;
			if (self.type.bits < (uns ? 1UL : 2UL) || self.type.bits > 65535)
			{
				tokens::TokenIndex bit_tok = self.has_bit_int_tok ? self.bit_int_tok : self.parser.tok_i;
				if (self.type.bits > 65535)
				{
					if (uns) { Diagnostic.UNSIGNED_BIT_INT_TOO_BIG.@emit(self.parser, bit_tok, "")!; } else { Diagnostic.SIGNED_BIT_INT_TOO_BIG.@emit(self.parser, bit_tok)!; }
				}
				else
				{
					if (uns) { Diagnostic.UNSIGNED_BIT_INT_TOO_SMALL.@emit(self.parser, bit_tok)!; } else { Diagnostic.SIGNED_BIT_INT_TOO_SMALL.@emit(self.parser, bit_tok)!; }
				}
				return INVALID;
			}
			qt = self.parser.comp.type_store.put(type_bit_int((ushort)self.type.bits, uns ? UNSIGNED : SIGNED));
		case COMPLEX_CHAR: case COMPLEX_SCHAR: case COMPLEX_UCHAR: case COMPLEX_SIGNED: case COMPLEX_UNSIGNED: case COMPLEX_SHORT: case COMPLEX_SSHORT: case COMPLEX_USHORT: case COMPLEX_SHORT_INT: case COMPLEX_SSHORT_INT: case COMPLEX_USHORT_INT: case COMPLEX_INT: case COMPLEX_SINT: case COMPLEX_UINT: case COMPLEX_LONG: case COMPLEX_SLONG: case COMPLEX_ULONG: case COMPLEX_LONG_INT: case COMPLEX_SLONG_INT: case COMPLEX_ULONG_INT: case COMPLEX_LONG_LONG: case COMPLEX_SLONG_LONG: case COMPLEX_ULONG_LONG: case COMPLEX_LONG_LONG_INT: case COMPLEX_SLONG_LONG_INT: case COMPLEX_ULONG_LONG_INT: case COMPLEX_INT128: case COMPLEX_SINT128: case COMPLEX_UINT128: case COMPLEX_INT24: case COMPLEX_SINT24: case COMPLEX_UINT24:
			QualType base = self.complex_integer_base();
			if (self.has_complex_tok) Diagnostic.COMPLEX_INT.@emit(self.parser, self.complex_tok)!;
			qt = base.to_complex(self.parser.comp);
		case COMPLEX_FLOAT16: qt = FLOAT16.to_complex(self.parser.comp);
		case COMPLEX_FLOAT: qt = FLOAT.to_complex(self.parser.comp);
		case COMPLEX_DOUBLE: case COMPLEX: qt = DOUBLE.to_complex(self.parser.comp);
		case COMPLEX_LONG_DOUBLE: qt = LONG_DOUBLE.to_complex(self.parser.comp);
		case COMPLEX_FLOAT128: qt = FLOAT128.to_complex(self.parser.comp);
		case COMPLEX_FLOAT32: qt = FLOAT32.to_complex(self.parser.comp);
		case COMPLEX_FLOAT64: qt = FLOAT64.to_complex(self.parser.comp);
		case COMPLEX_FLOAT32X: qt = FLOAT32X.to_complex(self.parser.comp);
		case COMPLEX_FLOAT64X: qt = FLOAT64X.to_complex(self.parser.comp);
		case COMPLEX_FLOAT128X: qt = FLOAT128X.to_complex(self.parser.comp);
		case COMPLEX_BIT_INT: case COMPLEX_SBIT_INT: case COMPLEX_UBIT_INT:
			Diagnostic.COMPLEX_BIT_INT.@emit(self.parser, self.has_complex_tok ? self.complex_tok : self.parser.tok_i)!;
			return INVALID;
		default: return INVALID;
	}
	return self.finish_quals(qt);
}

fn QualType Builder.complex_integer_base(&self)
{
	switch (self.type.tag)
	{
		case COMPLEX_CHAR: return CHAR; case COMPLEX_SCHAR: return SCHAR; case COMPLEX_UCHAR: return UCHAR;
		case COMPLEX_UNSIGNED: case COMPLEX_UINT: return UINT; case COMPLEX_SIGNED: case COMPLEX_INT: case COMPLEX_SINT: return INT;
		case COMPLEX_SHORT: case COMPLEX_SSHORT: case COMPLEX_SHORT_INT: case COMPLEX_SSHORT_INT: return SHORT;
		case COMPLEX_USHORT: case COMPLEX_USHORT_INT: return USHORT;
		case COMPLEX_LONG: case COMPLEX_SLONG: case COMPLEX_LONG_INT: case COMPLEX_SLONG_INT: return LONG;
		case COMPLEX_ULONG: case COMPLEX_ULONG_INT: return ULONG;
		case COMPLEX_LONG_LONG: case COMPLEX_SLONG_LONG: case COMPLEX_LONG_LONG_INT: case COMPLEX_SLONG_LONG_INT: return LONG_LONG;
		case COMPLEX_ULONG_LONG: case COMPLEX_ULONG_LONG_INT: return ULONG_LONG;
		case COMPLEX_INT128: case COMPLEX_SINT128: return INT128; case COMPLEX_UINT128: return UINT128;
		case COMPLEX_INT24: case COMPLEX_SINT24: return INT24; case COMPLEX_UINT24: return UINT24;
		default: return INVALID;
	}
}

fn QualType? Builder.finish_quals(&self, QualType input)
{
	if (input.is_invalid()) return INVALID;
	QualType qt = input;
	bool inner_const;
	bool inner_volatile;
	if (self.has_atomic_type_tok || self.has_atomic)
	{
		tokens::TokenIndex atok = self.has_atomic_type_tok ? self.atomic_type_tok : self.atomic_tok;
		if (qt.is_auto_type()) { Diagnostic.TODO.@emit(self.parser, atok, "_Atomic __auto_type")!; return INVALID; }
		if (qt.is_c23_auto()) { self.err(Diagnostic.ATOMIC_AUTO, atok)!; return INVALID; }
		if (qt.has_incomplete_size(self.parser.comp)) { self.err(Diagnostic.ATOMIC_INCOMPLETE, atok, self.fmt_qt(qt))!; return INVALID; }
		Type t = qt.base(self.parser.comp).ty;
		if (t.tag == ARRAY) { self.err(Diagnostic.ATOMIC_ARRAY, atok, self.fmt_qt(qt))!; return INVALID; }
		if (t.tag == FUNC) { self.err(Diagnostic.ATOMIC_FUNC, atok, self.fmt_qt(qt))!; return INVALID; }
		if (t.tag == ATOMIC) { self.err(Diagnostic.ATOMIC_ATOMIC, atok, self.fmt_qt(qt))!; return INVALID; }
		if (t.tag == COMPLEX) { self.err(Diagnostic.ATOMIC_COMPLEX, atok, self.fmt_qt(qt))!; return INVALID; }
		if (t.tag == BIT_INT) { self.err(Diagnostic.ATOMIC_BIT_INT, atok, self.fmt_qt(qt))!; return INVALID; }
		if (qt.is_const || qt.is_volatile)
		{
			// `_Atomic(const T)` is invalid; the `_Atomic` qualifier on a qualified
			// type (typedef, typeof) combines with its qualifiers, which stay on the
			// outer type since the atomic payload is unqualified.
			if (self.has_atomic_type_tok) { self.err(Diagnostic.ATOMIC_QUALIFIED, atok, self.fmt_qt(qt))!; return INVALID; }
			inner_const = qt.is_const;
			inner_volatile = qt.is_volatile;
			qt.is_const = false;
			qt.is_volatile = false;
		}
		qt = self.parser.comp.type_store.put(type_atomic(qt));
	}
	if (self.has_const || inner_const) qt.is_const = true;
	if (self.has_volatile || inner_volatile) qt.is_volatile = true;
	// Source TypeStore.Builder leaves `unaligned` unmodeled (its attributed-type
	// construction is commented out); preserve that unsupported form explicitly.
	if (self.has_restrict)
	{
		if (input.is_auto_type())
		{
			Diagnostic.TODO.@emit(self.parser, self.parser.tok_i, "restrict __auto_type")!;
			return parser::PARSING_FAILED~;
		}
		if (input.is_c23_auto())
		{
			self.err(Diagnostic.RESTRICT_NON_POINTER, self.restrict_tok, self.fmt_qt(input))!;
			return qt;
		}
		TypeTag tag = input.base(self.parser.comp).ty.tag;
		if (tag == ARRAY || tag == POINTER) { qt.is_restrict = true; }
		else { self.err(Diagnostic.RESTRICT_NON_POINTER, self.restrict_tok, self.fmt_qt(input))!; }
	}
	return qt;
}

<* Adopt the result type from typeof after enforcing its exclusive combination rules. *>
fn void? Builder.combine_from_typeof(&self, QualType source_type, tokens::TokenIndex tok)
{
	if (self.has_atomic_type_tok) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "_Atomic");
	if (self.is_typedef) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "type-name");
	if (self.is_typeof) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "typeof");
	if (self.type.tag != NONE) return self.cannot_combine_with_typeof(self.type.tag, tok);
	self.is_typeof = true;
	self.type = { .tag = OTHER, .other = source_type };
}

<* Combine the operand type of `_Atomic(type-name)` through the same specifier
 mapping used by TypeStore.Builder, then remember the source token for finish. *>
fn void? Builder.combine_atomic(&self, QualType base_qt, tokens::TokenIndex tok)
{
	if (self.has_atomic_type_tok) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "_Atomic");
	if (self.is_typedef) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "type-name");
	if (self.is_typeof) return Diagnostic.CANNOT_COMBINE_SPEC.@emit(self.parser, tok, "typeof");
	// C11 6.7.2.4p3: the type name in `_Atomic(type-name)` shall not be qualified.
	if (base_qt.is_const || base_qt.is_volatile || base_qt.is_restrict)
	{
		Diagnostic.ATOMIC_QUALIFIED.@emit(self.parser, tok, self.fmt_qt(base_qt))!;
		base_qt = base_qt.unqualified();
	}
	BuilderSpecifier spec = builder_from_type(self.parser.comp, base_qt);
	self.combine(spec, tok)!;
	self.has_atomic_type_tok = true;
	self.atomic_type_tok = tok;
}
