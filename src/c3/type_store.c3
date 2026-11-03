// Port of src/aro/TypeStore.zig: type representation (Repr/Index/QualType/Type)
// and the storage functions (put/putExtra/set/base/get/childType).
//
// `aro::type_store` is one module split over several files:
//   type_store.c3            types, handles and storage (this file)
//   type_store_relations.c3  equality, ranks, promotions, decay, scalar kinds
//   type_store_layout.c3     sizeof/alignof from explicit target data
//   type_print.c3            print/printNamed/printDesugared/dump
//   type_store_named.c3      initNamedTypes / generateVaListType
//
// Handles: a `QualType` is a 32-bit value (3 qualifier bits + a 29-bit index).
// Indices at or above `FIRST_BUILTIN_INDEX` name builtin types; smaller ones index
// `TypeStore.types`. Handles never hold pointers, so they stay valid when the
// store grows. Variable-length payloads (function params, record fields, enum
// fields) live in separate heap allocations owned by the store, so the slices a
// `Type` returned by value carries stay valid until `TypeStore.free`.
//
// Deferred to later plans: record layout computation (record_layout.zig; the
// computed `RecordLayout` is only stored here), the parser-coupled `Builder`
// (only `Builder.fromType(...).str()` is ported, for `should_desugar`), the
// attribute map (`getAttribute`/`hasAttribute`) and anonymous record names.
module aro::type_store;
import aro::compilation, aro::string_interner, aro::lang_opts, aro::target;
import std::collections::list, std::collections::map;

<* Zig `null` from QualType.get / getFunc / getRecord. *>
excuse NO_TYPE;
<* Zig `null` from sizeofOrNull / bitSizeofOrNull: the type has no (complete) size. *>
excuse NO_SIZE;
<* Zig `null` from requestedAlignment. *>
excuse NO_ALIGN;
<* Zig `null` from promoteBitfield: no promotion is necessary. *>
excuse NO_PROMOTION;
<* Zig `null` from arrayLen. *>
excuse NO_LEN;
<* Zig `null` from Builder.Specifier.str (the `other` specifier). *>
excuse NO_SPECIFIER_STR;

// ---------------------------------------------------------------------------
// Tree handles (Tree.zig is ported later; these keep Zig's u32 widths).
// ---------------------------------------------------------------------------

<* Tree.TokenIndex *>
typedef TokenIndex = uint;
<* Tree.Node.Index *>
typedef NodeIndex = uint;
<* Tree.Node.OptIndex; `NODE_NULL` is Zig's `.null`. *>
typedef NodeOptIndex = uint;
const NodeOptIndex NODE_NULL = (NodeOptIndex)0xFFFF_FFFF;

// ---------------------------------------------------------------------------
// Index (enum(u29)) and QualType (packed struct(u32))
// ---------------------------------------------------------------------------

const uint MAX_INDEX = 0x1FFF_FFFF; // std.math.maxInt(u29)

<* A NaN-like poison value. Can only be nested in function types. *>
const uint IDX_INVALID = MAX_INDEX - 0;
<* GNU auto type placeholder. Must not be nested. *>
const uint IDX_AUTO_TYPE = MAX_INDEX - 1;
<* C23 auto, behaves like auto_type. Must not be nested. *>
const uint IDX_C23_AUTO = MAX_INDEX - 2;
const uint IDX_VOID = MAX_INDEX - 3;
const uint IDX_BOOL = MAX_INDEX - 4;
const uint IDX_NULLPTR_T = MAX_INDEX - 5;
const uint IDX_INT_CHAR = MAX_INDEX - 6;
const uint IDX_INT_SCHAR = MAX_INDEX - 7;
const uint IDX_INT_UCHAR = MAX_INDEX - 8;
const uint IDX_INT_SHORT = MAX_INDEX - 9;
const uint IDX_INT_USHORT = MAX_INDEX - 10;
const uint IDX_INT_INT = MAX_INDEX - 11;
const uint IDX_INT_UINT = MAX_INDEX - 12;
const uint IDX_INT_LONG = MAX_INDEX - 13;
const uint IDX_INT_ULONG = MAX_INDEX - 14;
const uint IDX_INT_LONG_LONG = MAX_INDEX - 15;
const uint IDX_INT_ULONG_LONG = MAX_INDEX - 16;
const uint IDX_INT_INT128 = MAX_INDEX - 17;
const uint IDX_INT_UINT128 = MAX_INDEX - 18;
const uint IDX_FLOAT_FP16 = MAX_INDEX - 19;
const uint IDX_FLOAT_FLOAT16 = MAX_INDEX - 20;
const uint IDX_FLOAT_FLOAT = MAX_INDEX - 21;
const uint IDX_FLOAT_DOUBLE = MAX_INDEX - 22;
const uint IDX_FLOAT_LONG_DOUBLE = MAX_INDEX - 23;
const uint IDX_FLOAT_FLOAT128 = MAX_INDEX - 24;
const uint IDX_VOID_POINTER = MAX_INDEX - 25;
const uint IDX_CHAR_POINTER = MAX_INDEX - 26;
const uint IDX_INT_POINTER = MAX_INDEX - 27;
<* Special type used when combining declarators. *>
const uint IDX_DECLARATOR_COMBINE = MAX_INDEX - 28;
const uint IDX_FLOAT_BF16 = MAX_INDEX - 29;
const uint IDX_FLOAT_FLOAT32 = MAX_INDEX - 30;
const uint IDX_FLOAT_FLOAT64 = MAX_INDEX - 31;
const uint IDX_FLOAT_FLOAT32X = MAX_INDEX - 32;
const uint IDX_FLOAT_FLOAT64X = MAX_INDEX - 33;
const uint IDX_FLOAT_FLOAT128X = MAX_INDEX - 34;
const uint IDX_FLOAT_DFLOAT32 = MAX_INDEX - 35;
const uint IDX_FLOAT_DFLOAT64 = MAX_INDEX - 36;
const uint IDX_FLOAT_DFLOAT128 = MAX_INDEX - 37;
const uint IDX_FLOAT_DFLOAT64X = MAX_INDEX - 38;
const uint IDX_MFP8 = MAX_INDEX - 39;
const uint IDX_INT_INT24 = MAX_INDEX - 40;
const uint IDX_INT_UINT24 = MAX_INDEX - 41;
<* Indices at or above this name builtin types; below it they index `TypeStore.types`. *>
const uint FIRST_BUILTIN_INDEX = IDX_INT_UINT24;

<* TypeStore.QualType: qualifiers plus a type index. Equality (`==`) is Zig's bitwise equality. *>
bitstruct QualType : uint
{
	bool is_const : 0;
	bool is_volatile : 1;
	bool is_restrict : 2;
	uint index : 3..31;
}

const QualType INVALID = { .index = IDX_INVALID };
const QualType AUTO_TYPE = { .index = IDX_AUTO_TYPE };
const QualType C23_AUTO = { .index = IDX_C23_AUTO };
const QualType VOID = { .index = IDX_VOID };
const QualType BOOL = { .index = IDX_BOOL };
const QualType NULLPTR_T = { .index = IDX_NULLPTR_T };
const QualType CHAR = { .index = IDX_INT_CHAR };
const QualType SCHAR = { .index = IDX_INT_SCHAR };
const QualType UCHAR = { .index = IDX_INT_UCHAR };
const QualType SHORT = { .index = IDX_INT_SHORT };
const QualType USHORT = { .index = IDX_INT_USHORT };
const QualType INT = { .index = IDX_INT_INT };
const QualType UINT = { .index = IDX_INT_UINT };
const QualType LONG = { .index = IDX_INT_LONG };
const QualType ULONG = { .index = IDX_INT_ULONG };
const QualType LONG_LONG = { .index = IDX_INT_LONG_LONG };
const QualType ULONG_LONG = { .index = IDX_INT_ULONG_LONG };
const QualType INT128 = { .index = IDX_INT_INT128 };
const QualType UINT128 = { .index = IDX_INT_UINT128 };
const QualType INT24 = { .index = IDX_INT_INT24 };
const QualType UINT24 = { .index = IDX_INT_UINT24 };
const QualType BF16 = { .index = IDX_FLOAT_BF16 };
const QualType FP16 = { .index = IDX_FLOAT_FP16 };
const QualType FLOAT16 = { .index = IDX_FLOAT_FLOAT16 };
const QualType FLOAT = { .index = IDX_FLOAT_FLOAT };
const QualType DOUBLE = { .index = IDX_FLOAT_DOUBLE };
const QualType LONG_DOUBLE = { .index = IDX_FLOAT_LONG_DOUBLE };
const QualType FLOAT128 = { .index = IDX_FLOAT_FLOAT128 };
const QualType FLOAT32 = { .index = IDX_FLOAT_FLOAT32 };
const QualType FLOAT64 = { .index = IDX_FLOAT_FLOAT64 };
const QualType FLOAT32X = { .index = IDX_FLOAT_FLOAT32X };
const QualType FLOAT64X = { .index = IDX_FLOAT_FLOAT64X };
const QualType FLOAT128X = { .index = IDX_FLOAT_FLOAT128X };
const QualType DFLOAT32 = { .index = IDX_FLOAT_DFLOAT32 };
const QualType DFLOAT64 = { .index = IDX_FLOAT_DFLOAT64 };
const QualType DFLOAT128 = { .index = IDX_FLOAT_DFLOAT128 };
const QualType DFLOAT64X = { .index = IDX_FLOAT_DFLOAT64X };
const QualType MFP8 = { .index = IDX_MFP8 };
const QualType VOID_POINTER = { .index = IDX_VOID_POINTER };
const QualType CHAR_POINTER = { .index = IDX_CHAR_POINTER };
const QualType INT_POINTER = { .index = IDX_INT_POINTER };
const QualType DECLARATOR_COMBINE = { .index = IDX_DECLARATOR_COMBINE };

// ---------------------------------------------------------------------------
// Type (union(enum)) and its payloads
// ---------------------------------------------------------------------------

enum TypeTag : char
{
	VOID,
	BOOL,
	<* C23 nullptr_t *>
	NULLPTR_T,
	INT,
	FLOAT,
	STORAGE_FLOAT,
	COMPLEX,
	BIT_INT,
	ATOMIC,
	BLOCK,
	FUNC,
	POINTER,
	ARRAY,
	VECTOR,
	STRUCT,
	UNION,
	ENUM,
	TYPEOF,
	TYPEDEF,
}

<* Type.Int *>
enum TypeInt : char
{
	CHAR,
	SCHAR,
	UCHAR,
	SHORT,
	USHORT,
	INT,
	UINT,
	LONG,
	ULONG,
	LONG_LONG,
	ULONG_LONG,
	INT128,
	UINT128,
	INT24,
	UINT24,
}

<* Type.Float *>
enum TypeFloat : char
{
	BF16,
	FP16,
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
}

<* Type.StorageFloat: non-arithmetic floats. *>
enum StorageFloat : char (ushort bits, uint alignment, String name)
{
	MFP8 { 8, 1, "__mfp8" },
}

<* Type.BitInt. `bits` must be >= 1 if unsigned and >= 2 if signed. *>
struct BitInt
{
	ushort bits;
	Signedness signedness;
}

<* Type.Pointer.Nullability; `str` is Zig's `Nullability.str` (DEFAULT has none). *>
enum Nullability : char (String str)
{
	DEFAULT { "" },
	NONNULL { "_Nonnull" },
	NULLABLE { "_Nullable" },
	NULLABLE_RESULT { "_Nullable_result" },
	UNSPECIFIED { "_Null_unspecified" },
}

<* Type.Block *>
struct Block
{
	QualType func;
	Nullability nullability;
}

<* Type.Func.Kind *>
enum FuncKind : char
{
	<* int foo(int bar, char baz) and int (void) *>
	NORMAL,
	<* int foo(int bar, char baz, ...) *>
	VARIADIC,
	<* int foo(bar, baz) and int foo() *>
	OLD_STYLE,
}

<* Type.Func.CallingConvention; `name` is Zig's tag name (printed with `{t}`). *>
enum CallingConvention : char (String name)
{
	DEFAULT { "default" },
	CDECL { "cdecl" },
	AARCH64_SVE_PCS { "aarch64_sve_pcs" },
	AARCH64_VECTOR_PCS { "aarch64_vector_pcs" },
	ARM_AAPCS_VFP { "arm_aapcs_vfp" },
	ARM_AAPCS { "arm_aapcs" },
	FASTCALL { "fastcall" },
	MS_ABI { "ms_abi" },
	REGCALL { "regcall" },
	RISCV_VECTOR_CC { "riscv_vector_cc" },
	RISCV_VLS_CC { "riscv_vls_cc" },
	STDCALL { "stdcall" },
	SYSV_ABI { "sysv_abi" },
	THISCALL { "thiscall" },
	VECTORCALL { "vectorcall" },
}

<* Type.Func.Param *>
struct FuncParam
{
	QualType qt;
	StringId name;
	TokenIndex name_tok;
	NodeOptIndex node;
}

<* Type.Func. `params` points at storage owned by the TypeStore (or the caller, for `put`). *>
struct Func
{
	QualType return_type;
	FuncKind kind;
	FuncParam[] params;
	CallingConvention cc;
}

<* Type.Pointer.Bounds *>
enum PointerBounds : char
{
	<* C pointer with no bounds attribute *>
	C,
	<* No pointer arithmetic or non-zero indexing *>
	SINGLE,
	<* Explicitly specified as a traditional C pointer *>
	UNSAFE_INDEXABLE,
}

<* Type.Pointer. Zig's `decayed: ?QualType` is `has_decayed` + `decayed`. *>
struct Pointer
{
	QualType child;
	bool has_decayed;
	QualType decayed;
	PointerBounds bounds;
	Nullability nullability;
}

enum ArrayLenKind : char
{
	INCOMPLETE,
	FIXED,
	STATIC,
	VARIABLE,
	UNSPECIFIED_VARIABLE,
}

<* Type.Array.len: `len` for FIXED/STATIC, `expr` for VARIABLE. *>
struct ArrayLen
{
	ArrayLenKind kind;
	ulong len;
	NodeIndex expr;
}

<* Type.Array *>
struct Array
{
	QualType elem;
	ArrayLen len;
}

<* Type.Vector.Kind *>
enum VectorKind : char
{
	GENERIC,
	NEON,
	NEON_POLY,
}

<* Type.Vector *>
struct Vector
{
	QualType elem;
	uint len;
	VectorKind kind;
}

<* Type.Record.Field.Layout. INVALID (both fields) only for unnamed bitfields. *>
struct FieldLayout
{
	ulong offset_bits;
	ulong size_bits;
}

const ulong FIELD_LAYOUT_INVALID = 0xFFFF_FFFF_FFFF_FFFF;
<* `RecordField.bit_width` when the field is not a bitfield (Zig `.null`). *>
const uint BIT_WIDTH_NULL = 0xFFFF_FFFF;

<* Type.Record.Field. Use `record_field` for Zig's defaults. *>
struct RecordField
{
	QualType qt;
	StringId name;
	<* zero for anonymous fields *>
	TokenIndex name_tok;
	<* BIT_WIDTH_NULL unless a bitfield *>
	uint bit_width;
	FieldLayout layout;
	NodeOptIndex field_decl;
}

<* Type.Record.Layout: the stored result of record layout computation. *>
struct RecordLayout
{
	<* sizeof in bits; a multiple of pointer_alignment_bits. *>
	ulong size_bits;
	<* Alignment in bits when used as a field (usually _Alignof). *>
	uint field_alignment_bits;
	<* Alignment in bits of valid pointers to this type. *>
	uint pointer_alignment_bits;
	<* Required alignment in bits (MSVC only; 8 elsewhere). *>
	uint required_alignment_bits;
}

<* Type.Record (struct and union). Zig's `layout: ?Layout` is `has_layout` + `layout`. *>
struct Record
{
	StringId name;
	NodeOptIndex decl_node;
	bool has_layout;
	RecordLayout layout;
	RecordField[] fields;
}

<* Type.Enum.Field *>
struct EnumField
{
	QualType qt;
	StringId name;
	TokenIndex name_tok;
}

<* Type.Enum. `has_tag` is false only if the enum is incomplete and not fixed. *>
struct EnumType
{
	bool has_tag;
	QualType tag;
	bool fixed;
	bool incomplete;
	StringId name;
	NodeIndex decl_node;
	EnumField[] fields;
}

<* Type.TypeOf. Zig's `expr: ?Node.Index` is `has_expr` + `expr`. *>
struct TypeOf
{
	QualType base;
	bool has_expr;
	NodeIndex expr;
}

<* Type.TypeDef *>
struct TypeDef
{
	QualType base;
	StringId name;
	NodeIndex decl_node;
}

<* TypeStore.Type: a tagged record; the active member is selected by `tag`. *>
struct Type
{
	TypeTag tag;
	union
	{
		TypeInt int_ty;
		TypeFloat float_ty;
		StorageFloat storage_float;
		QualType complex;
		BitInt bit_int;
		QualType atomic;
		Block block;
		Func func;
		Pointer pointer;
		Array array;
		Vector vector;
		<* STRUCT and UNION *>
		Record record;
		EnumType enum_ty;
		TypeOf type_of;
		TypeDef type_def;
	}
}

<* Return type of QualType.base: the first non-typeof/typedef type and its handle. *>
struct BaseType
{
	Type ty;
	QualType qt;
}

// ---------------------------------------------------------------------------
// Repr (internal storage) and the store
// ---------------------------------------------------------------------------

enum ReprTag : char
{
	COMPLEX,
	BIT_INT,
	ATOMIC,
	BLOCK,
	FUNC,
	FUNC_VARIADIC,
	FUNC_OLD_STYLE,
	FUNC_ATTRIBUTED,
	FUNC_ZERO,
	FUNC_VARIADIC_ZERO,
	FUNC_OLD_STYLE_ZERO,
	FUNC_ATTRIBUTED_ZERO,
	FUNC_ONE,
	FUNC_VARIADIC_ONE,
	FUNC_OLD_STYLE_ONE,
	FUNC_ATTRIBUTED_ONE,
	POINTER,
	POINTER_DECAYED,
	POINTER_DECAYED_ATTRIBUTED,
	ARRAY_INCOMPLETE,
	ARRAY_FIXED,
	ARRAY_STATIC,
	ARRAY_VARIABLE,
	ARRAY_UNSPECIFIED_VARIABLE,
	VECTOR,
	VECTOR_NEON,
	VECTOR_NEON_POLY,
	STRUCT,
	STRUCT_INCOMPLETE,
	UNION,
	UNION_INCOMPLETE,
	ENUM,
	ENUM_FIXED,
	ENUM_INCOMPLETE,
	ENUM_INCOMPLETE_FIXED,
	TYPEOF,
	TYPEOF_EXPR,
	TYPEDEF,
}

<* Repr: if a Type has a child type it is stored in data[0]. *>
struct Repr
{
	ReprTag tag;
	uint[2] data;
}

<* Repr.FuncAttrs (packed struct(u32)): kind in bits 0..1, cc in bits 2..5. *>
bitstruct FuncAttrs : uint
{
	char kind : 0..1;
	char cc : 2..5;
}

<* Repr.PointerAttrs (packed struct(u32)): bounds in bits 0..1, nullability in bits 2..4. *>
bitstruct PointerAttrs : uint
{
	char bounds : 0..1;
	char nullability : 2..4;
}

<* Out-of-line function payload (FUNC_ONE..FUNC_ATTRIBUTED); `params` is owned by the store. *>
struct FuncData
{
	FuncParam[] params;
	FuncAttrs attrs;
}

<* Out-of-line complete record payload; `fields` is owned by the store. *>
struct RecordData
{
	NodeOptIndex decl_node;
	RecordLayout layout;
	RecordField[] fields;
}

<* Out-of-line complete enum payload; `fields` is owned by the store. *>
struct EnumData
{
	StringId name;
	NodeIndex decl_node;
	EnumField[] fields;
}

struct TypeStore
{
	Allocator gpa;
	List{Repr} types;
	<* Fixed-size side data (Zig `extra`): array lengths, typedef/enum names, pointer attrs. *>
	List{uint} extra;
	List{FuncData} funcs;
	List{RecordData} records;
	List{EnumData} enums;
	<*
	 Alignment is a decl attribute in C but since it matters for sizeof
	 calculations it is additionally stored here. Key: the QualType's raw bits.
	*>
	HashMap{uint, uint} requested_aligns;

	QualType wchar;
	QualType wint;
	QualType uint_least16_t;
	QualType uint_least32_t;
	QualType ptrdiff;
	QualType size;
	QualType va_list;
	QualType pid_t;
	QualType ns_constant_string;
	QualType file;
	QualType jmp_buf;
	QualType sigjmp_buf;
	QualType ucontext_t;
	QualType intmax;
	QualType intptr;
	QualType int16;
	QualType int64;
}

// ---------------------------------------------------------------------------
// Construction helpers (Zig default-initialized literals)
// ---------------------------------------------------------------------------

fn Type type_int(TypeInt k) => { .tag = INT, .int_ty = k };
fn Type type_float(TypeFloat k) => { .tag = FLOAT, .float_ty = k };
fn Type type_pointer(QualType child) => { .tag = POINTER, .pointer = { .child = child } };
fn Type type_decayed_pointer(QualType child, QualType decayed) => { .tag = POINTER, .pointer = { .child = child, .has_decayed = true, .decayed = decayed } };
fn Type type_array(QualType elem, ArrayLenKind kind, ulong len = 0) => { .tag = ARRAY, .array = { .elem = elem, .len = { .kind = kind, .len = len } } };
fn Type type_vla(QualType elem, NodeIndex expr) => { .tag = ARRAY, .array = { .elem = elem, .len = { .kind = VARIABLE, .expr = expr } } };
fn Type type_func(QualType ret, FuncKind kind, FuncParam[] params, CallingConvention cc = DEFAULT) => { .tag = FUNC, .func = { .return_type = ret, .kind = kind, .params = params, .cc = cc } };
fn Type type_bit_int(ushort bits, Signedness s) => { .tag = BIT_INT, .bit_int = { .bits = bits, .signedness = s } };
fn Type type_complex(QualType child) => { .tag = COMPLEX, .complex = child };
fn Type type_atomic(QualType child) => { .tag = ATOMIC, .atomic = child };
fn Type type_vector(QualType elem, uint len, VectorKind kind = GENERIC) => { .tag = VECTOR, .vector = { .elem = elem, .len = len, .kind = kind } };
fn Type type_typedef(QualType base, StringId name, NodeIndex decl_node) => { .tag = TYPEDEF, .type_def = { .base = base, .name = name, .decl_node = decl_node } };
fn Type type_typeof(QualType base) => { .tag = TYPEOF, .type_of = { .base = base } };
fn Type type_typeof_expr(QualType base, NodeIndex expr) => { .tag = TYPEOF, .type_of = { .base = base, .has_expr = true, .expr = expr } };
fn Type type_block(QualType func) => { .tag = BLOCK, .block = { .func = func } };
<* An incomplete struct (or union, with `is_union`) forward declaration. *>
fn Type type_record_incomplete(StringId name, bool is_union = false, NodeOptIndex decl_node = NODE_NULL)
	=> { .tag = is_union ? UNION : STRUCT, .record = { .name = name, .decl_node = decl_node } };
fn Type type_record(StringId name, RecordField[] fields, RecordLayout layout, bool is_union = false, NodeOptIndex decl_node = NODE_NULL)
	=> { .tag = is_union ? UNION : STRUCT, .record = { .name = name, .decl_node = decl_node, .has_layout = true, .layout = layout, .fields = fields } };

<* A record field with Zig's defaults (no name token, not a bitfield, zero layout, no decl). *>
fn RecordField record_field(StringId name, QualType qt)
	=> { .qt = qt, .name = name, .bit_width = BIT_WIDTH_NULL, .field_decl = NODE_NULL };

fn FuncParam func_param(QualType qt, StringId name = string_interner::EMPTY)
	=> { .qt = qt, .name = name, .node = NODE_NULL };

// ---------------------------------------------------------------------------
// QualType basics
// ---------------------------------------------------------------------------

fn QualType qual(uint index) @inline => { .index = index };

fn bool QualType.is_invalid(self) => self.index == IDX_INVALID;
fn bool QualType.is_auto_type(self) => self.index == IDX_AUTO_TYPE;
fn bool QualType.is_c23_auto(self) => self.index == IDX_C23_AUTO;
fn bool QualType.is_auto(self) => self.index == IDX_AUTO_TYPE || self.index == IDX_C23_AUTO;
fn bool QualType.is_qualified(self) => self.is_const || self.is_volatile || self.is_restrict;
fn QualType QualType.unqualified(self) => { .index = self.index };

fn QualType QualType.with_qualifiers(self, QualType quals_from)
	=> { .index = self.index, .is_const = quals_from.is_const, .is_volatile = quals_from.is_volatile, .is_restrict = quals_from.is_restrict };

fn bool Pointer.any_attrs(self) => self.bounds != C || self.nullability != DEFAULT;

fn bool ArrayLen.is_sized(self) => self.kind == FIXED || self.kind == STATIC;


// ---------------------------------------------------------------------------
// Store lifecycle
// ---------------------------------------------------------------------------

fn void TypeStore.init(&self, Allocator gpa)
{
	*self = { .gpa = gpa };
	self.types.init(gpa);
	self.extra.init(gpa);
	self.funcs.init(gpa);
	self.records.init(gpa);
	self.enums.init(gpa);
	self.requested_aligns.init(gpa);
	self.wchar = INVALID;
	self.wint = INVALID;
	self.uint_least16_t = INVALID;
	self.uint_least32_t = INVALID;
	self.ptrdiff = INVALID;
	self.size = INVALID;
	self.va_list = INVALID;
	self.pid_t = INVALID;
	self.ns_constant_string = INVALID;
	self.file = INVALID;
	self.jmp_buf = INVALID;
	self.sigjmp_buf = INVALID;
	self.ucontext_t = INVALID;
	self.intmax = INVALID;
	self.intptr = INVALID;
	self.int16 = INVALID;
	self.int64 = INVALID;
}

fn void TypeStore.free(&self)
{
	Allocator gpa = self.gpa;
	foreach (&f : self.funcs) if (f.params.len) alloc::free(gpa, f.params.ptr);
	foreach (&r : self.records) if (r.fields.len) alloc::free(gpa, r.fields.ptr);
	foreach (&e : self.enums) if (e.fields.len) alloc::free(gpa, e.fields.ptr);
	self.types.free();
	self.extra.free();
	self.funcs.free();
	self.records.free();
	self.enums.free();
	self.requested_aligns.free();
	*self = {};
}

<* Number of non-builtin types stored (handle indices 0..len-1). *>
fn usz TypeStore.len(&self) => (usz)self.types.len();

macro copy_slice(Allocator gpa, slice) @local
{
	if (!slice.len) return slice[:0];
	var copy = alloc::new_array(gpa, $Typeof(slice[0]), slice.len);
	copy[..] = slice[..];
	return copy;
}

// ---------------------------------------------------------------------------
// put / putExtra / set
// ---------------------------------------------------------------------------

fn QualType TypeStore.put(&self, Type ty) => { .index = self.put_extra(ty) };

fn uint int_index(TypeInt k)
{
	switch (k)
	{
		case CHAR: return IDX_INT_CHAR;
		case SCHAR: return IDX_INT_SCHAR;
		case UCHAR: return IDX_INT_UCHAR;
		case SHORT: return IDX_INT_SHORT;
		case USHORT: return IDX_INT_USHORT;
		case INT: return IDX_INT_INT;
		case UINT: return IDX_INT_UINT;
		case LONG: return IDX_INT_LONG;
		case ULONG: return IDX_INT_ULONG;
		case LONG_LONG: return IDX_INT_LONG_LONG;
		case ULONG_LONG: return IDX_INT_ULONG_LONG;
		case INT128: return IDX_INT_INT128;
		case UINT128: return IDX_INT_UINT128;
		case INT24: return IDX_INT_INT24;
		case UINT24: return IDX_INT_UINT24;
	}
}

fn uint float_index(TypeFloat k)
{
	switch (k)
	{
		case BF16: return IDX_FLOAT_BF16;
		case FP16: return IDX_FLOAT_FP16;
		case FLOAT16: return IDX_FLOAT_FLOAT16;
		case FLOAT: return IDX_FLOAT_FLOAT;
		case DOUBLE: return IDX_FLOAT_DOUBLE;
		case LONG_DOUBLE: return IDX_FLOAT_LONG_DOUBLE;
		case FLOAT128: return IDX_FLOAT_FLOAT128;
		case FLOAT32: return IDX_FLOAT_FLOAT32;
		case FLOAT64: return IDX_FLOAT_FLOAT64;
		case FLOAT32X: return IDX_FLOAT_FLOAT32X;
		case FLOAT64X: return IDX_FLOAT_FLOAT64X;
		case FLOAT128X: return IDX_FLOAT_FLOAT128X;
		case DFLOAT32: return IDX_FLOAT_DFLOAT32;
		case DFLOAT64: return IDX_FLOAT_DFLOAT64;
		case DFLOAT128: return IDX_FLOAT_DFLOAT128;
		case DFLOAT64X: return IDX_FLOAT_DFLOAT64X;
	}
}

<* Builtin types map to fixed indices; everything else gets a new slot. *>
fn uint TypeStore.put_extra(&self, Type ty)
{
	switch (ty.tag)
	{
		case VOID: return IDX_VOID;
		case BOOL: return IDX_BOOL;
		case NULLPTR_T: return IDX_NULLPTR_T;
		case INT: return int_index(ty.int_ty);
		case FLOAT: return float_index(ty.float_ty);
		case STORAGE_FLOAT: return IDX_MFP8;
		default: break;
	}
	uint index = self.add_one();
	self.set(ty, index);
	return index;
}

<* Reserve an index for a type that `set` fills in later (Zig `types.addOne`). *>
fn uint TypeStore.add_one(&self)
{
	usz index = self.len();
	assert(index < FIRST_BUILTIN_INDEX, "type store index space (u29) exhausted");
	self.types.push({});
	return (uint)index;
}

<*
 Store `ty` at `index`, replacing what was there. Used by `put_extra` and to
 complete forward-declared records and enums in place, keeping their handle.
 @require index < self.len() : "index must come from add_one/put_extra"
*>
fn void TypeStore.set(&self, Type ty, uint index)
{
	Repr repr;
	switch (ty.tag)
	{
		case VOID:
		case BOOL:
		case NULLPTR_T:
		case INT:
		case FLOAT:
		case STORAGE_FLOAT:
			unreachable("builtin types have fixed indices");
		case COMPLEX:
			repr.tag = COMPLEX;
			repr.data[0] = (uint)ty.complex;
		case BIT_INT:
			repr.tag = BIT_INT;
			repr.data[0] = ty.bit_int.bits;
			repr.data[1] = ty.bit_int.signedness.ordinal;
		case ATOMIC:
			repr.tag = ATOMIC;
			assert(!ty.atomic.is_const && !ty.atomic.is_volatile);
			repr.data[0] = (uint)ty.atomic;
		case BLOCK:
			repr.tag = BLOCK;
			repr.data[0] = (uint)ty.block.func;
		case FUNC:
			Func func = ty.func;
			repr.data[0] = (uint)func.return_type;
			FuncAttrs attr = { .kind = (char)func.kind.ordinal, .cc = (char)func.cc.ordinal };
			usz n = func.params.len;
			if (n == 0)
			{
				switch (func.kind)
				{
					case NORMAL: repr.tag = FUNC_ZERO;
					case VARIADIC: repr.tag = FUNC_VARIADIC_ZERO;
					case OLD_STYLE: repr.tag = FUNC_OLD_STYLE_ZERO;
				}
				if (func.cc != DEFAULT)
				{
					repr.tag = FUNC_ATTRIBUTED_ZERO;
					repr.data[1] = (uint)attr;
				}
			}
			else
			{
				repr.data[1] = (uint)self.funcs.len();
				self.funcs.push({ .params = copy_slice(self.gpa, func.params), .attrs = attr });
				switch (func.kind)
				{
					case NORMAL: repr.tag = n == 1 ? FUNC_ONE : FUNC;
					case VARIADIC: repr.tag = n == 1 ? FUNC_VARIADIC_ONE : FUNC_VARIADIC;
					case OLD_STYLE: repr.tag = n == 1 ? FUNC_OLD_STYLE_ONE : FUNC_OLD_STYLE;
				}
				if (func.cc != DEFAULT) repr.tag = n == 1 ? FUNC_ATTRIBUTED_ONE : FUNC_ATTRIBUTED;
			}
		case POINTER:
			Pointer p = ty.pointer;
			repr.data[0] = (uint)p.child;
			PointerAttrs attr = { .bounds = (char)p.bounds.ordinal, .nullability = (char)p.nullability.ordinal };
			if (p.has_decayed)
			{
				if (p.any_attrs())
				{
					repr.tag = POINTER_DECAYED_ATTRIBUTED;
					repr.data[1] = (uint)self.extra.len();
					self.extra.push((uint)p.decayed);
					self.extra.push((uint)attr);
				}
				else
				{
					repr.tag = POINTER_DECAYED;
					repr.data[1] = (uint)p.decayed;
				}
			}
			else
			{
				repr.tag = POINTER;
				repr.data[1] = (uint)attr;
			}
		case ARRAY:
			Array a = ty.array;
			repr.data[0] = (uint)a.elem;
			switch (a.len.kind)
			{
				case INCOMPLETE:
					repr.tag = ARRAY_INCOMPLETE;
				case FIXED:
				case STATIC:
					repr.tag = a.len.kind == FIXED ? ARRAY_FIXED : ARRAY_STATIC;
					repr.data[1] = (uint)self.extra.len();
					self.extra.push((uint)(a.len.len & 0xFFFF_FFFF));
					self.extra.push((uint)(a.len.len >> 32));
				case VARIABLE:
					repr.tag = ARRAY_VARIABLE;
					repr.data[1] = (uint)a.len.expr;
				case UNSPECIFIED_VARIABLE:
					repr.tag = ARRAY_UNSPECIFIED_VARIABLE;
			}
		case VECTOR:
			switch (ty.vector.kind)
			{
				case GENERIC: repr.tag = VECTOR;
				case NEON: repr.tag = VECTOR_NEON;
				case NEON_POLY: repr.tag = VECTOR_NEON_POLY;
			}
			repr.data[0] = (uint)ty.vector.elem;
			repr.data[1] = ty.vector.len;
		case STRUCT:
		case UNION:
			Record r = ty.record;
			bool is_union = ty.tag == UNION;
			repr.data[0] = (uint)r.name;
			if (!r.has_layout)
			{
				assert(r.fields.len == 0);
				repr.tag = is_union ? UNION_INCOMPLETE : STRUCT_INCOMPLETE;
				repr.data[1] = (uint)r.decl_node;
				break;
			}
			repr.tag = is_union ? UNION : STRUCT;
			repr.data[1] = (uint)self.records.len();
			self.records.push({ .decl_node = r.decl_node, .layout = r.layout, .fields = copy_slice(self.gpa, r.fields) });
		case ENUM:
			EnumType e = ty.enum_ty;
			if (e.incomplete)
			{
				assert(e.fields.len == 0);
				if (e.fixed)
				{
					assert(e.has_tag);
					repr.tag = ENUM_INCOMPLETE_FIXED;
					repr.data[0] = (uint)e.tag;
					repr.data[1] = (uint)self.extra.len();
					self.extra.push((uint)e.name);
					self.extra.push((uint)e.decl_node);
				}
				else
				{
					repr.tag = ENUM_INCOMPLETE;
					repr.data[0] = (uint)e.name;
					repr.data[1] = (uint)e.decl_node;
				}
				break;
			}
			assert(e.has_tag);
			repr.tag = e.fixed ? ENUM_FIXED : ENUM;
			repr.data[0] = (uint)e.tag;
			repr.data[1] = (uint)self.enums.len();
			self.enums.push({ .name = e.name, .decl_node = e.decl_node, .fields = copy_slice(self.gpa, e.fields) });
		case TYPEOF:
			repr.data[0] = (uint)ty.type_of.base;
			if (ty.type_of.has_expr)
			{
				repr.tag = TYPEOF_EXPR;
				repr.data[1] = (uint)ty.type_of.expr;
			}
			else
			{
				repr.tag = TYPEOF;
			}
		case TYPEDEF:
			repr.tag = TYPEDEF;
			repr.data[0] = (uint)ty.type_def.base;
			repr.data[1] = (uint)self.extra.len();
			self.extra.push((uint)ty.type_def.name);
			self.extra.push((uint)ty.type_def.decl_node);
	}
	self.types[index] = repr;
}

fn bool ReprTag.is_func(self)
{
	switch (self)
	{
		case FUNC..FUNC_ATTRIBUTED_ONE: return true;
		default: return false;
	}
}

<* @require !func_qt.is_invalid() && func_qt.index < self.len() *>
fn void TypeStore.set_func_return_type(&self, QualType func_qt, QualType return_qt)
{
	Repr* repr = &self.types[func_qt.index];
	assert(repr.tag.is_func());
	repr.data[0] = (uint)return_qt;
}

<* Record an alignment request for exactly this (qualified) handle. *>
fn void TypeStore.set_requested_alignment(&self, QualType qt, uint alignment)
{
	self.requested_aligns.set((uint)qt, alignment);
}

<* Zig `requested_aligns.get(qt)` *>
fn uint? TypeStore.get_requested_alignment(&self, QualType qt)
{
	return self.requested_aligns.get((uint)qt) ?? NO_ALIGN~;
}

// ---------------------------------------------------------------------------
// Decoding: type / base / get / childType
// ---------------------------------------------------------------------------

fn QualType qt_from(uint raw) @inline => (QualType)raw;

<*
 Decode a handle into its Type (Zig `QualType.type`).
 @require !self.is_invalid() && !self.is_auto() && self.index != IDX_DECLARATOR_COMBINE : "placeholder types have no Type"
*>
fn Type QualType.get_type(self, Compilation* comp)
{
	switch (self.index)
	{
		case IDX_VOID: return { .tag = VOID };
		case IDX_BOOL: return { .tag = BOOL };
		case IDX_NULLPTR_T: return { .tag = NULLPTR_T };
		case IDX_INT_CHAR: return type_int(CHAR);
		case IDX_INT_SCHAR: return type_int(SCHAR);
		case IDX_INT_UCHAR: return type_int(UCHAR);
		case IDX_INT_SHORT: return type_int(SHORT);
		case IDX_INT_USHORT: return type_int(USHORT);
		case IDX_INT_INT: return type_int(INT);
		case IDX_INT_UINT: return type_int(UINT);
		case IDX_INT_LONG: return type_int(LONG);
		case IDX_INT_ULONG: return type_int(ULONG);
		case IDX_INT_LONG_LONG: return type_int(LONG_LONG);
		case IDX_INT_ULONG_LONG: return type_int(ULONG_LONG);
		case IDX_INT_INT128: return type_int(INT128);
		case IDX_INT_UINT128: return type_int(UINT128);
		case IDX_INT_INT24: return type_int(INT24);
		case IDX_INT_UINT24: return type_int(UINT24);
		case IDX_FLOAT_BF16: return type_float(BF16);
		case IDX_FLOAT_FP16: return type_float(FP16);
		case IDX_FLOAT_FLOAT16: return type_float(FLOAT16);
		case IDX_FLOAT_FLOAT: return type_float(FLOAT);
		case IDX_FLOAT_DOUBLE: return type_float(DOUBLE);
		case IDX_FLOAT_LONG_DOUBLE: return type_float(LONG_DOUBLE);
		case IDX_FLOAT_FLOAT128: return type_float(FLOAT128);
		case IDX_FLOAT_FLOAT32: return type_float(FLOAT32);
		case IDX_FLOAT_FLOAT64: return type_float(FLOAT64);
		case IDX_FLOAT_FLOAT32X: return type_float(FLOAT32X);
		case IDX_FLOAT_FLOAT64X: return type_float(FLOAT64X);
		case IDX_FLOAT_FLOAT128X: return type_float(FLOAT128X);
		case IDX_FLOAT_DFLOAT32: return type_float(DFLOAT32);
		case IDX_FLOAT_DFLOAT64: return type_float(DFLOAT64);
		case IDX_FLOAT_DFLOAT128: return type_float(DFLOAT128);
		case IDX_FLOAT_DFLOAT64X: return type_float(DFLOAT64X);
		case IDX_MFP8: return { .tag = STORAGE_FLOAT, .storage_float = MFP8 };
		case IDX_VOID_POINTER: return type_pointer(VOID);
		case IDX_CHAR_POINTER: return type_pointer(CHAR);
		case IDX_INT_POINTER: return type_pointer(INT);
		case IDX_INVALID:
		case IDX_AUTO_TYPE:
		case IDX_C23_AUTO:
		case IDX_DECLARATOR_COMBINE:
			unreachable("placeholder type has no Type");
		default: break;
	}

	TypeStore* ts = &comp.type_store;
	Repr repr = ts.types[self.index];
	uint d0 = repr.data[0];
	uint d1 = repr.data[1];
	switch (repr.tag)
	{
		case COMPLEX: return type_complex(qt_from(d0));
		case ATOMIC: return type_atomic(qt_from(d0));
		case BIT_INT: return type_bit_int((ushort)d0, Signedness::from_ordinal(d1));
		case BLOCK: return type_block(qt_from(d0));
		case FUNC_ZERO: return type_func(qt_from(d0), NORMAL, {});
		case FUNC_VARIADIC_ZERO: return type_func(qt_from(d0), VARIADIC, {});
		case FUNC_OLD_STYLE_ZERO: return type_func(qt_from(d0), OLD_STYLE, {});
		case FUNC_ATTRIBUTED_ZERO:
			FuncAttrs attr = (FuncAttrs)d1;
			return type_func(qt_from(d0), FuncKind::from_ordinal(attr.kind), {}, CallingConvention::from_ordinal(attr.cc));
		case FUNC_ONE:
		case FUNC:
			return type_func(qt_from(d0), NORMAL, ts.funcs[d1].params);
		case FUNC_VARIADIC_ONE:
		case FUNC_VARIADIC:
			return type_func(qt_from(d0), VARIADIC, ts.funcs[d1].params);
		case FUNC_OLD_STYLE_ONE:
		case FUNC_OLD_STYLE:
			return type_func(qt_from(d0), OLD_STYLE, ts.funcs[d1].params);
		case FUNC_ATTRIBUTED_ONE:
		case FUNC_ATTRIBUTED:
			FuncData fd = ts.funcs[d1];
			return type_func(qt_from(d0), FuncKind::from_ordinal(fd.attrs.kind), fd.params, CallingConvention::from_ordinal(fd.attrs.cc));
		case POINTER:
			PointerAttrs attr = (PointerAttrs)d1;
			Type t = type_pointer(qt_from(d0));
			t.pointer.bounds = PointerBounds::from_ordinal(attr.bounds);
			t.pointer.nullability = Nullability::from_ordinal(attr.nullability);
			return t;
		case POINTER_DECAYED:
			return type_decayed_pointer(qt_from(d0), qt_from(d1));
		case POINTER_DECAYED_ATTRIBUTED:
			PointerAttrs attr = (PointerAttrs)ts.extra[(sz)d1 + 1];
			Type t = type_decayed_pointer(qt_from(d0), qt_from(ts.extra[d1]));
			t.pointer.bounds = PointerBounds::from_ordinal(attr.bounds);
			t.pointer.nullability = Nullability::from_ordinal(attr.nullability);
			return t;
		case ARRAY_INCOMPLETE: return type_array(qt_from(d0), INCOMPLETE);
		case ARRAY_FIXED:
		case ARRAY_STATIC:
			ulong len = (ulong)ts.extra[d1] | ((ulong)ts.extra[(sz)d1 + 1] << 32);
			return type_array(qt_from(d0), repr.tag == ARRAY_FIXED ? FIXED : STATIC, len);
		case ARRAY_VARIABLE: return type_vla(qt_from(d0), (NodeIndex)d1);
		case ARRAY_UNSPECIFIED_VARIABLE: return type_array(qt_from(d0), UNSPECIFIED_VARIABLE);
		case VECTOR: return type_vector(qt_from(d0), d1, GENERIC);
		case VECTOR_NEON: return type_vector(qt_from(d0), d1, NEON);
		case VECTOR_NEON_POLY: return type_vector(qt_from(d0), d1, NEON_POLY);
		case STRUCT:
		case UNION:
			RecordData rd = ts.records[d1];
			return type_record((StringId)d0, rd.fields, rd.layout, repr.tag == UNION, rd.decl_node);
		case STRUCT_INCOMPLETE: return type_record_incomplete((StringId)d0, false, (NodeOptIndex)d1);
		case UNION_INCOMPLETE: return type_record_incomplete((StringId)d0, true, (NodeOptIndex)d1);
		case ENUM:
		case ENUM_FIXED:
			EnumData ed = ts.enums[d1];
			return { .tag = ENUM, .enum_ty = {
				.has_tag = true, .tag = qt_from(d0), .fixed = repr.tag == ENUM_FIXED, .incomplete = false,
				.name = ed.name, .decl_node = ed.decl_node, .fields = ed.fields } };
		case ENUM_INCOMPLETE:
			return { .tag = ENUM, .enum_ty = {
				.incomplete = true, .name = (StringId)d0, .decl_node = (NodeIndex)d1 } };
		case ENUM_INCOMPLETE_FIXED:
			return { .tag = ENUM, .enum_ty = {
				.has_tag = true, .tag = qt_from(d0), .fixed = true, .incomplete = true,
				.name = (StringId)ts.extra[d1], .decl_node = (NodeIndex)ts.extra[(sz)d1 + 1] } };
		case TYPEOF: return type_typeof(qt_from(d0));
		case TYPEOF_EXPR: return type_typeof_expr(qt_from(d0), (NodeIndex)d1);
		case TYPEDEF: return type_typedef(qt_from(d0), (StringId)ts.extra[d1], (NodeIndex)ts.extra[(sz)d1 + 1]);
	}
}

<* Strip typeof/typedef wrappers. *>
fn BaseType QualType.base(self, Compilation* comp)
{
	QualType cur = self;
	while (true)
	{
		Type ty = cur.get_type(comp);
		switch (ty.tag)
		{
			case TYPEOF: cur = ty.type_of.base;
			case TYPEDEF: cur = ty.type_def.base;
			default: return { .ty = ty, .qt = cur };
		}
	}
}

<*
 The base type if its tag is `tag` (Zig `QualType.get`), else NO_TYPE.
 STRUCT and UNION are distinct tags.
 @require tag != TYPEOF && tag != TYPEDEF : "base() never returns typeof/typedef"
*>
fn Type? QualType.get(self, Compilation* comp, TypeTag tag)
{
	if (self.is_invalid() || self.is_auto()) return NO_TYPE~;
	Type base_type = self.base(comp).ty;
	if (base_type.tag == tag) return base_type;
	return NO_TYPE~;
}

fn bool QualType.is(self, Compilation* comp, TypeTag tag) => @ok(self.get(comp, tag));

<* Function or function pointer. *>
fn Func? QualType.get_func(self, Compilation* comp)
{
	QualType base_qt = self;
	if (try p = self.get(comp, POINTER)) base_qt = p.pointer.child;
	Type t = base_qt.get(comp, FUNC)!;
	return t.func;
}

fn Record? QualType.get_record(self, Compilation* comp)
{
	if (self.is_invalid() || self.is_auto()) return NO_TYPE~;
	Type t = self.base(comp).ty;
	if (t.tag == STRUCT || t.tag == UNION) return t.record;
	return NO_TYPE~;
}

<* The underlying value type of an atomic type, or the original type otherwise. *>
fn QualType QualType.non_atomic(self, Compilation* comp)
{
	if (try t = self.get(comp, ATOMIC)) return t.atomic;
	return self;
}

<* @require self.is_invalid() || self.is(comp, COMPLEX) || self.is(comp, POINTER) || self.is(comp, ARRAY) || self.is(comp, VECTOR) || self.is(comp, BLOCK) *>
fn QualType QualType.child_type(self, Compilation* comp)
{
	if (self.is_invalid()) return INVALID;
	BaseType b = self.base(comp);
	switch (b.ty.tag)
	{
		case COMPLEX: return b.ty.complex;
		case POINTER: return b.ty.pointer.child;
		case ARRAY: return b.ty.array.elem;
		case VECTOR: return b.ty.vector.elem;
		case BLOCK: return b.qt; // special case: block's childType is always itself
		default: unreachable("type has no child type");
	}
}

// ---------------------------------------------------------------------------
// Record helpers
// ---------------------------------------------------------------------------

<* Anonymous records are named "(anonymous TAG at path:line:col)". *>
fn bool Record.is_anonymous(self, Compilation* comp) => self.name.lookup(comp)[0] == '(';
fn bool EnumType.is_anonymous(self, Compilation* comp) => self.name.lookup(comp)[0] == '(';

<* @require self.has_layout && name != string_interner::EMPTY *>
fn bool Record.has_field(self, Compilation* comp, StringId name)
{
	foreach (field : self.fields)
	{
		if (name == field.name) return true;
		if (field.name_tok == (TokenIndex)0)
		{
			if (try rec = field.qt.get_record(comp))
			{
				if (rec.has_field(comp, name)) return true;
			}
		}
	}
	return false;
}
