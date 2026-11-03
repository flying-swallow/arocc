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
// Store lifecycle and storage (stage 0 stubs)
// ---------------------------------------------------------------------------

fn void TypeStore.init(&self, Allocator gpa)
{
	unreachable("type_store: stage 0 stub");
}

fn void TypeStore.free(&self)
{
	unreachable("type_store: stage 0 stub");
}

fn QualType TypeStore.put(&self, Type ty)
{
	unreachable("type_store: stage 0 stub");
}

fn uint TypeStore.put_extra(&self, Type ty)
{
	unreachable("type_store: stage 0 stub");
}

<* Reserve an index for a type that `set` will fill in later. *>
fn uint TypeStore.add_one(&self)
{
	unreachable("type_store: stage 0 stub");
}

fn void TypeStore.set(&self, Type ty, uint index)
{
	unreachable("type_store: stage 0 stub");
}

fn void TypeStore.set_func_return_type(&self, QualType func_qt, QualType return_qt)
{
	unreachable("type_store: stage 0 stub");
}

fn void TypeStore.set_requested_alignment(&self, QualType qt, uint alignment)
{
	unreachable("type_store: stage 0 stub");
}

fn Type QualType.get_type(self, Compilation* comp)
{
	unreachable("type_store: stage 0 stub");
}

fn BaseType QualType.base(self, Compilation* comp)
{
	unreachable("type_store: stage 0 stub");
}

fn Type? QualType.get(self, Compilation* comp, TypeTag tag) => aro::UNSUPPORTED~;
fn bool QualType.is(self, Compilation* comp, TypeTag tag) => false;
fn Func? QualType.get_func(self, Compilation* comp) => aro::UNSUPPORTED~;
fn Record? QualType.get_record(self, Compilation* comp) => aro::UNSUPPORTED~;
fn QualType QualType.non_atomic(self, Compilation* comp) => self;
fn QualType QualType.child_type(self, Compilation* comp)
{
	unreachable("type_store: stage 0 stub");
}
