// Port of the data model and builder in src/backend/Ir.zig. This C3 IR is a
// stable, index-based representation; references remain valid when lists grow.
module aro::backend::ir;
import aro::value_interner, aro::primitive_value, std::collections::list, std::collections::map;

typedef Ref = uint;
const Ref NONE = (Ref)uint::max;

<*
 IR instructions with their dump spelling. Deviation from Zig Ir.zig: the
 operations whose meaning depends on signedness are split into signed and
 unsigned tags (IR integer types carry only a bit width), so a target can map
 each tag to one machine instruction.
*>
enum InstTag : char(String name)
{
	CONSTANT { "constant" },
	ARG { "arg" },
	SYMBOL { "symbol" },
	LABEL { "label" },
	LABEL_ADDR { "label_addr" },
	JMP { "jmp" },
	SWITCH { "switch" },
	BRANCH { "branch" },
	SELECT { "select" },
	JMP_VAL { "jmp_val" },
	CALL { "call" },
	<* High eightbyte (i64 or f64) of the immediately preceding CALL result. *>
	CALL_HI { "call_hi" },
	<* Initialize the SysV va_list using this variadic function's register save area. *>
	VA_START { "va_start" },
	ALLOC { "alloc" },
	<* Runtime-sized stack allocation (VLA); emitted in place, freed by STACK_RESTORE or function return. *>
	DYN_ALLOC { "dyn_alloc" },
	<* Current stack pointer, for a later STACK_RESTORE. *>
	STACK_SAVE { "stack_save" },
	<* Reset the stack pointer to a STACK_SAVE result, freeing DYN_ALLOCs made since. *>
	STACK_RESTORE { "stack_restore" },
	PHI { "phi" },
	STORE { "store" },
	BIT_OR { "bit_or" },
	BIT_XOR { "bit_xor" },
	BIT_AND { "bit_and" },
	BIT_SHL { "bit_shl" },
	<* Arithmetic (sign-filling) right shift. *>
	BIT_ASHR { "bit_ashr" },
	<* Logical (zero-filling) right shift. *>
	BIT_LSHR { "bit_lshr" },
	CMP_EQ { "cmp_eq" },
	CMP_NE { "cmp_ne" },
	CMP_SLT { "cmp_slt" },
	CMP_SLTE { "cmp_slte" },
	CMP_SGT { "cmp_sgt" },
	CMP_SGTE { "cmp_sgte" },
	CMP_ULT { "cmp_ult" },
	CMP_ULTE { "cmp_ulte" },
	CMP_UGT { "cmp_ugt" },
	CMP_UGTE { "cmp_ugte" },
	ADD { "add" },
	SUB { "sub" },
	MUL { "mul" },
	SDIV { "sdiv" },
	UDIV { "udiv" },
	SREM { "srem" },
	UREM { "urem" },
	FADD { "fadd" },
	FSUB { "fsub" },
	FMUL { "fmul" },
	FDIV { "fdiv" },
	FCMP_OEQ { "fcmp_oeq" },
	FCMP_UNE { "fcmp_une" },
	FCMP_OLT { "fcmp_olt" },
	FCMP_OLE { "fcmp_ole" },
	FCMP_OGT { "fcmp_ogt" },
	FCMP_OGE { "fcmp_oge" },
	RET { "ret" },
	<* Return two eightbytes, each i64 (RAX, then RDX) or f64 (XMM0, then XMM1). *>
	RET_PAIR { "ret_pair" },
	LOAD { "load" },
	BIT_NOT { "bit_not" },
	NEGATE { "negate" },
	FNEG { "fneg" },
	<* Floating-point absolute value: clears the sign bit (NaNs included). *>
	FABS { "fabs" },
	TRUNC { "trunc" },
	ZEXT { "zext" },
	SEXT { "sext" },
	FPTOSI { "fptosi" },
	FPTOUI { "fptoui" },
	SITOFP { "sitofp" },
	UITOFP { "uitofp" },
	FPEXT { "fpext" },
	FPTRUNC { "fptrunc" },
	<* Atomic load of `atomic.ptr`; `atomic.order` is a C `__ATOMIC_*` memory order. *>
	ATOMIC_LOAD { "atomic_load" },
	<* Atomic store of `atomic.val` to `atomic.ptr` with memory order `atomic.order`. *>
	ATOMIC_STORE { "atomic_store" },
	<* Thread fence with memory order `atomic.order`; `ptr`/`val` are NONE. *>
	FENCE { "fence" },
	<* Count leading zero bits of `ref`; undefined for zero (`__builtin_clz`). *>
	CLZ { "clz" },
	<* Count trailing zero bits of `ref`; undefined for zero (`__builtin_ctz`). *>
	CTZ { "ctz" },
	<* Vector (see `Ir.vector_shape`) with every lane set to scalar `ref`. *>
	VSPLAT { "vsplat" },
	<* Scalar lane `bin.rhs` (an integer CONSTANT) of vector `bin.lhs`. *>
	VEXTRACT { "vextract" },
	<* Wrapping sum of the lanes of integer vector `ref`, as the lane type. *>
	VREDUCE_ADD { "vreduce_add" },
	<* Lane `i` of the result is lane `shuffle.mask[i]` of the concatenation
	   `shuffle.lhs ++ shuffle.rhs` (both of type `ty`); `SHUFFLE_UNDEF` lanes are
	   unspecified. Only masks `sse2_shuffle_kind` accepts are valid. *>
	VSHUFFLE { "vshuffle" },
}

<* A `ShuffleData.mask` entry whose result lane is unspecified. *>
const char SHUFFLE_UNDEF = 0xFF;

<* `lhs` / `rhs` lead like `BinData`'s, so operand walkers read a VSHUFFLE's
   operands through `data.bin` like any binary instruction. *>
struct ShuffleData
{
	Ref lhs; Ref rhs;
	<* One entry per result lane (up to 16): an index below 2 * lanes, or SHUFFLE_UNDEF. *>
	char[16] mask;
}

<* C11 / GCC `__ATOMIC_*` memory orders, as stored in `AtomicData.order`. *>
enum AtomicOrder : char(String name)
{
	RELAXED { "relaxed" },
	CONSUME { "consume" },
	ACQUIRE { "acquire" },
	RELEASE { "release" },
	ACQ_REL { "acq_rel" },
	SEQ_CST { "seq_cst" },
}

<* The compare computing the logical negation of `tag`. FCMP_OEQ and FCMP_UNE
are exact inverses; ordered relations have no inverse in the IR because of NaN. *>
fn InstTag? inverse_compare(InstTag tag)
{
	switch (tag)
	{
		case CMP_EQ: return InstTag.CMP_NE;
		case CMP_NE: return InstTag.CMP_EQ;
		case CMP_SLT: return InstTag.CMP_SGTE;
		case CMP_SGTE: return InstTag.CMP_SLT;
		case CMP_SLTE: return InstTag.CMP_SGT;
		case CMP_SGT: return InstTag.CMP_SLTE;
		case CMP_ULT: return InstTag.CMP_UGTE;
		case CMP_UGTE: return InstTag.CMP_ULT;
		case CMP_ULTE: return InstTag.CMP_UGT;
		case CMP_UGT: return InstTag.CMP_ULTE;
		case FCMP_OEQ: return InstTag.FCMP_UNE;
		case FCMP_UNE: return InstTag.FCMP_OEQ;
		default: return NOT_FOUND~;
	}
}

struct BinData
{
	Ref lhs; Ref rhs;
}

// Keep existing values stable: SSE_REGISTER is appended after the original ABI locations.
enum ArgLocationKind : char
{
	ORDINAL, GP_REGISTER, STACK, SSE_REGISTER
}

struct ArgData
{
	ArgLocationKind location_kind; uint location; uint stack_size; bool stack_address;
}

struct AllocData
{
	uint size; uint align; bool is_volatile;
}

struct DynAllocData
{
	Ref size; uint align;
}

struct AtomicData
{
	Ref ptr; Ref val; AtomicOrder order;
}

struct BranchData
{
	Ref cond; Ref then_label; Ref else_label;
}

struct SwitchData
{
	Ref target; value_interner::InternerRef[] values; Ref[] labels; Ref default_label;
}

struct CallData
{
	Ref func; Ref[] args; bool[] stack_only; uint[] memory_copy_bytes;
}

<* Set in a `memory_copy_bytes` entry when the copied argument needs a 16-byte
   aligned stack slot (SysV: MEMORY-class aggregates aligned to 16). *>
const uint MEMORY_COPY_ALIGN16 = 1u << 31;

fn uint memory_copy_size(uint entry) => entry & ~MEMORY_COPY_ALIGN16;
fn bool memory_copy_align16(uint entry) => entry & MEMORY_COPY_ALIGN16 != 0;

struct PhiInput
{
	Ref label; 
	Ref value;
}

enum DeclKind : char
{
	FUNCTION,
	GLOBAL,
}

<* Inferred function properties for a function definition. Argument masks use bit
   i for ARG i (first 64). `readnone` means no memory reads or writes; `readonly`
   means no memory writes. Per-argument masks describe argument values that are
   not captured, read, or written; capture bits are cleared conservatively even
   for integer arguments because pointer/integer casts can reuse one IR value.
   `will_return` is set only when every reachable
   control-flow path terminates and every called function is known to return.
   Passes that change a function's parameters or memory effects must reset attrs
   to `{}` so downstream users stay conservative. *>
struct FnAttrs
{
	bitstruct : char
	{
		bool computed : 0;
		bool readnone : 1;
		bool readonly : 2;
		bool will_return : 3;
	}
	ulong arg_nocapture;
	ulong arg_noread;
	ulong arg_nowrite;
}

<* Linkage of a declaration; external definitions are strong by default downstream. *>
enum Linkage : char
{
	EXTERNAL,
	INTERNAL,
}

enum DataSection : char
{
	EXTERN,
	DATA,
	RODATA,
	BSS,
	COMMON,
}

struct DataReloc
{
	ulong offset;
	String symbol;
	long addend;
}

<* Serialized global bytes and the symbol references that must be relocated. *>
struct GlobalData
{
	ulong size;
	uint align;
	char[] bytes;
	DataReloc[] relocs;
	DataSection section;
	bool tentative;
	bool own_section;
	<* Some part of the object is volatile or atomic; global memory accesses stay observable. *>
	bool is_volatile;
}

struct InstData
{
	union
	{
		<* Zig `Inst.Data.none`, used by `ARG`. The byte is ignored; C3 unions cannot contain `void`. *>
		char none;
		ArgData arg;
		value_interner::InternerRef constant;
		Ref ref;
		AllocData alloc;
		DynAllocData dyn_alloc;
		AtomicData atomic;
		BinData bin;
		ShuffleData shuffle;
		BranchData branch;
		SwitchData switch_data;
		CallData call;
		PhiInput[] phi;
		String label;
	}
}

<* `is_volatile` marks a volatile LOAD/STORE (C volatile-qualified lvalue): the
   access is observable and must not be removed, merged, reordered with other
   volatile accesses, or promoted, whatever its address. Ignored on other tags.
   `nsw` ("no signed wrap") is valid only on integer ADD / SUB / MUL: when the
   exact signed result does not fit the type, the value is poison (any value may
   be substituted), not immediate UB, so speculation stays sound. The C frontend
   sets it on signed arithmetic at `int` rank or wider unless `-fwrapv`. A pass
   that rewrites the operation or merges two of them must clear it unless it
   proves the new form cannot overflow either (`and` the flags on a merge). *>
struct Inst
{
	InstTag tag;
	bool is_volatile;
	bool nsw;
	InstData data;
	value_interner::InternerRef ty;
}

<* A 128-bit SIMD vector IR type (`VECTOR_TY` key). Lane-wise ops on vector
   values reuse the scalar tags: LOAD / STORE (16 bytes, any alignment), ADD /
   SUB / MUL / BIT_AND / BIT_OR / BIT_XOR on integer lanes (wrapping, never
   nsw), FADD / FSUB / FMUL / FDIV on float lanes; plus VSPLAT, VEXTRACT,
   VREDUCE_ADD and VSHUFFLE. Only the shapes in `vector_shape` are valid, and
   only the operations `sse2_vector_op` / `sse2_vector_cast` /
   `sse2_shuffle_kind` accept: there is no legalization, so producers (the loop
   vectorizer, the C frontend for GNU vector-extension values) check first and
   fall back to scalar lanes otherwise.
   Integer CMP_* and FCMP_* on vectors yield a mask: an integer vector with the
   operand's lane count and width, each lane 0 or -1. A shift takes a VSPLAT
   count (SSE2 shifts every lane by one amount). *>
struct VectorShape
{
	uint lanes;
	value_interner::InternerRef elem;
	ushort elem_bits;
	bool is_float;
}

<* The lane layout of `ty` when it is a supported 128-bit vector type. *>
fn VectorShape? Ir.vector_shape(&self, value_interner::InternerRef ty) => vector_shape_of(self.interner, ty);

<* `Ir.vector_shape` for callers that hold only the interner (the C frontend's builder). *>
fn VectorShape? vector_shape_of(value_interner::Interner* interner, value_interner::InternerRef ty)
{
	if (ty == value_interner::REF_PTR || ty == value_interner::REF_VOID || ty == value_interner::REF_NORETURN) return NOT_FOUND~;
	primitive_value::PrimitiveValue key = interner.get(ty);
	if (key.tag != primitive_value::PrimitiveType.VECTOR_TY) return NOT_FOUND~;
	value_interner::InternerRef elem = key.vector_ty.child;
	if (elem == value_interner::REF_PTR) return NOT_FOUND~;
	primitive_value::PrimitiveValue lane = interner.get(elem);
	bool is_float = lane.tag == primitive_value::PrimitiveType.FLOAT_TY;
	if (!is_float && lane.tag != primitive_value::PrimitiveType.INT_TY) return NOT_FOUND~;
	ushort bits = lane.ty_bits;
	if (is_float ? (bits != 32 && bits != 64) : (bits != 8 && bits != 16 && bits != 32 && bits != 64)) return NOT_FOUND~;
	if ((ulong)key.vector_ty.len * bits != 128) return NOT_FOUND~;
	return { .lanes = key.vector_ty.len, .elem = elem, .elem_bits = bits, .is_float = is_float };
}

fn bool Ir.is_vector(&self, value_interner::InternerRef ty) => @ok(self.vector_shape(ty));

<* The 128-bit vector type with `elem` lanes (i8/i16/i32/i64/f32/f64). *>
fn value_interner::InternerRef Ir.vector_type(&self, value_interner::InternerRef elem)
{
	primitive_value::PrimitiveValue lane = self.interner.get(elem);
	uint lanes = 128 / lane.ty_bits;
	return self.interner.put({ .tag = VECTOR_TY, .vector_ty = { .len = lanes, .child = elem } });
}

<* Whether the x86_64 backend selects lane-wise `tag` on `shape` operands with
   SSE2 alone (no SSE4.1). Compares are keyed by the operand shape. Shifts also
   need a VSPLAT count (`BIT_*` shift tags). *>
fn bool sse2_vector_op(InstTag tag, VectorShape shape)
{
	ushort bits = shape.elem_bits;
	switch (tag)
	{
		case ADD: case SUB: case BIT_AND: case BIT_OR: case BIT_XOR: case NEGATE: case BIT_NOT:
			return !shape.is_float;
		case MUL:
			return !shape.is_float && (bits == 16 || bits == 32);
		case BIT_SHL: case BIT_LSHR:
			return !shape.is_float && bits != 8;
		case BIT_ASHR:
			return !shape.is_float && (bits == 16 || bits == 32);
		case CMP_EQ: case CMP_NE: case CMP_SLT: case CMP_SLTE: case CMP_SGT: case CMP_SGTE:
		case CMP_ULT: case CMP_ULTE: case CMP_UGT: case CMP_UGTE:
			return !shape.is_float && bits != 64;
		case FADD: case FSUB: case FMUL: case FDIV: case FNEG: case FABS:
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
			return shape.is_float;
		case VSPLAT: case VEXTRACT:
			return true;
		default:
			return false;
	}
}

<* Whether the x86_64 backend selects lane conversion `tag` from `from` to `to` with SSE2. *>
fn bool sse2_vector_cast(InstTag tag, VectorShape from, VectorShape to)
{
	if (from.lanes != 4 || to.lanes != 4 || from.elem_bits != 32 || to.elem_bits != 32) return false;
	switch (tag)
	{
		case SITOFP: return !from.is_float && to.is_float;
		case FPTOSI: return from.is_float && !to.is_float;
		default: return false;
	}
}

<* How lowering selects a VSHUFFLE; NONE: not selectable. *>
enum ShuffleKind : char
{
	NONE,
	<* Lanes all come from one operand (`ShuffleSelect.swap`: rhs); 32/64-bit lanes: PSHUFD. *>
	PERMUTE,
	<* 32-bit lanes: result lanes 0-1 from the first source, 2-3 from the second (SHUFPS);
	   64-bit lanes: lane 0 from the first, lane 1 from the second (SHUFPD). *>
	SHUFFLE_PAIRS,
	<* Interleave the low halves: result 2k = first[k], 2k+1 = second[k] (PUNPCKL*). *>
	UNPACK_LO,
	<* Interleave the high halves (PUNPCKH*). *>
	UNPACK_HI,
}

struct ShuffleSelect
{
	ShuffleKind kind;
	<* The first source is `rhs` (and the second `lhs`). *>
	bool swap;
}

<* Mask entry `i` names lane `lane` of the first source (`swap`: of rhs), or is undefined. *>
fn bool shuffle_lane_is(char[] mask, usz i, uint lanes, uint lane, bool second, bool swap) @local
{
	if (mask[i] == SHUFFLE_UNDEF) return true;
	bool from_rhs = second != swap;
	return (uint)mask[i] == (from_rhs ? lanes + lane : lane);
}

<* Whether every defined entry of `mask[from..to)` reads the rhs (`rhs`) or the lhs. *>
fn bool shuffle_range_from(char[] mask, usz from, usz to, uint lanes, bool rhs) @local
{
	for (usz i = from; i < to; i++)
	{
		if (mask[i] == SHUFFLE_UNDEF) continue;
		if (((uint)mask[i] >= lanes) != rhs) return false;
	}
	return true;
}

<* The SSE2 selection for a VSHUFFLE of `shape` with `mask` (one entry per lane). *>
fn ShuffleSelect sse2_shuffle_kind(VectorShape shape, char[] mask)
{
	uint lanes = shape.lanes;
	if (mask.len != lanes) return { .kind = NONE };
	foreach (m : mask) if (m != SHUFFLE_UNDEF && (uint)m >= 2 * lanes) return { .kind = NONE };
	foreach (swap : (bool[2]){ false, true })
	{
		bool lo = true;
		bool hi = true;
		for (uint k = 0; k < lanes / 2; k++)
		{
			usz even = (usz)k * 2;
			lo = lo && shuffle_lane_is(mask, even, lanes, k, false, swap) && shuffle_lane_is(mask, even + 1, lanes, k, true, swap);
			hi = hi && shuffle_lane_is(mask, even, lanes, lanes / 2 + k, false, swap)
				&& shuffle_lane_is(mask, even + 1, lanes, lanes / 2 + k, true, swap);
		}
		if (lo) return { .kind = UNPACK_LO, .swap = swap };
		if (hi) return { .kind = UNPACK_HI, .swap = swap };
	}
	if (shape.elem_bits != 32 && shape.elem_bits != 64) return { .kind = NONE };
	if (shuffle_range_from(mask, 0, lanes, lanes, false)) return { .kind = PERMUTE };
	if (shuffle_range_from(mask, 0, lanes, lanes, true)) return { .kind = PERMUTE, .swap = true };
	foreach (swap : (bool[2]){ false, true })
	{
		if (shuffle_range_from(mask, 0, lanes / 2, lanes, swap) && shuffle_range_from(mask, lanes / 2, lanes, lanes, !swap))
		{
			return { .kind = SHUFFLE_PAIRS, .swap = swap };
		}
	}
	return { .kind = NONE };
}

<* `nsw` may appear on this tag. *>
fn bool InstTag.allows_nsw(self) => self == ADD || self == SUB || self == MUL;

<* A volatile LOAD or STORE. *>
fn bool Inst.is_volatile_access(&self) => self.is_volatile && (self.tag == InstTag.LOAD || self.tag == InstTag.STORE);

<* Source-level inlining request for a function definition (C `noinline` /
   `always_inline`). The inliner honors it; other IPO passes ignore it, as in LLVM. *>
enum InlineHint : char
{
	NONE,
	NEVER,
	ALWAYS,
}

<* Whether the C runtime calls a function before `main` or at exit, through
   `.init_array` / `.fini_array` (C `constructor` / `destructor`). *>
enum StaticInit : char
{
	NONE,
	CONSTRUCTOR,
	DESTRUCTOR,
}

<* `.init_array`/`.fini_array` priority meaning "no priority" (GCC default). *>
const ushort DEFAULT_INIT_PRIORITY = 65535;

struct Decl
{
	Allocator allocator;
	DynamicArenaAllocator arena;
	String name;
	bitstruct : uint
	{
		ushort init_priority : 0..15;
		DeclKind kind : 16..16;
		Linkage linkage : 17..17;
		<* A weak symbol (C `__attribute__((weak))`): another object may provide the
		   definition the program uses, so optimizations must not rely on this body.
		   Only meaningful with EXTERNAL linkage. *>
		bool is_weak : 18;
		<* C `used`: referenced from outside the IR (e.g. inline asm), so the symbol is
		   kept and emitted even when internal and otherwise unreferenced. *>
		bool retain : 19;
		StaticInit static_init : 20..21;
		InlineHint inline_hint : 22..23;
	}
	<* Conservatively inferred properties for a function definition. *>
	FnAttrs attrs;
	<* FUNCTION: requested code alignment in bytes (GNU `aligned`); 0 = target default. *>
	uint code_align;
	Inst[] instructions;
	Ref[] body;
	GlobalData global;
}

<* ELF section (without the leading dot) holding this decl's constructor or
   destructor pointer; prioritized entries get the `.NNNNN` suffix GNU ld sorts. *>
fn String Decl.static_init_section(&self, Allocator allocator)
{
	String base = self.static_init == StaticInit.CONSTRUCTOR ? "init_array" : "fini_array";
	if (self.init_priority == DEFAULT_INIT_PRIORITY) return base.copy(allocator);
	return string::format(allocator, "%s.%05d", base, self.init_priority);
}

<* Referenced from outside the IR: a `used` symbol or a constructor/destructor. *>
fn bool Decl.is_external_root(&self) => self.retain || self.static_init != StaticInit.NONE;

fn bool Decl.is_definition(&self)
{
	switch (self.kind)
	{
		case FUNCTION: return true;
		case GLOBAL: return self.global.section != DataSection.EXTERN;
	}
}

<* One GNU inline-asm operand of an AsmBlock. The matching CALL argument is
   the operand's value (input), or the address of its lvalue (output, and any
   memory operand). *>
struct AsmOperand
{
	<* Constraint letters without the `=`/`+`/`&` modifiers. *>
	String constraint;
	<* `[name]` or "". *>
	String name;
	<* Index of the CALL argument. *>
	uint arg;
	bool is_output;
	<* `+`: the output also reads the lvalue's value. *>
	bool read_write;
	<* The argument is an address (`m` operand, or any output). *>
	bool by_address;
	<* Size in bytes of the operand's C type. *>
	uint size;
	bool is_float;
}

<* A GNU inline-asm statement, referenced by a CALL to the symbol `name`
   (`__aro.asm.*`): every pass already treats a call as an opaque side effect. *>
struct AsmBlock
{
	String name;
	<* AT&T template, operand references still unexpanded. *>
	String template;
	AsmOperand[] operands;
	String[] clobbers;
	<* Basic asm (no operand list): `%` is not special. *>
	bool basic;
}

fn AsmBlock AsmBlock.copy(&self, Allocator a)
{
	AsmBlock out = { .name = self.name.copy(a), .template = self.template.copy(a), .basic = self.basic };
	out.operands = alloc::new_array(a, AsmOperand, self.operands.len);
	foreach (i, op : self.operands)
	{
		out.operands[i] = op;
		out.operands[i].constraint = op.constraint.copy(a);
		out.operands[i].name = op.name.copy(a);
	}
	out.clobbers = alloc::new_array(a, String, self.clobbers.len);
	foreach (i, c : self.clobbers) out.clobbers[i] = c.copy(a);
	return out;
}

fn void AsmBlock.free(&self, Allocator a)
{
	alloc::free(a, self.name.ptr);
	alloc::free(a, self.template.ptr);
	foreach (op : self.operands) { alloc::free(a, op.constraint.ptr); alloc::free(a, op.name.ptr); }
	alloc::free(a, self.operands.ptr);
	foreach (c : self.clobbers) alloc::free(a, c.ptr);
	alloc::free(a, self.clobbers.ptr);
}

struct Ir
{
	Allocator allocator;
	value_interner::Interner* interner;
	List{Decl} decls;
	<* Inline-asm statements and file-scope `asm("...")` text; their presence makes
	   the driver go through the system assembler. Strings live in the builder arena
	   of the translation unit (alive while the Ir is). *>
	List{AsmBlock} asm_blocks;
	List{String} global_asm;
	<* Byte order of `GlobalData.bytes` (the target's). Hand-built IR defaults to little-endian. *>
	bool big_endian;
	<* Optional `ir_opt::DeclLookup*` installed by the optimizer while the decl list is stable. *>
	void* decl_lookup;
}

fn void Ir.init(&self, Allocator allocator, value_interner::Interner* interner)
{
	*self = { .allocator = allocator, .interner = interner };
	self.decls.init(allocator);
}

fn void Decl.free(&self)
{
	if (self.instructions.len) alloc::free(self.allocator, self.instructions.ptr);
	if (self.body.len) alloc::free(self.allocator, self.body.ptr);
	self.arena.free();
	*self = {};
}

fn void Ir.free(&self)
{
	foreach (decl : self.decls) decl.free();
	self.decls.free();
	foreach (&block : self.asm_blocks) block.free(self.allocator);
	self.asm_blocks.free();
	foreach (text : self.global_asm) alloc::free(self.allocator, text.ptr);
	self.global_asm.free();
	*self = {};
}

<* Transfer declarations from another IR into this one and empty its list. *>
fn void Ir.take_decls(&self, Ir* other)
{
	self.decls.push_all(other.decls.array_view());
	other.decls.clear();
	if (!self.asm_blocks.allocator) self.asm_blocks.init(self.allocator);
	if (!self.global_asm.allocator) self.global_asm.init(self.allocator);
	self.asm_blocks.push_all(other.asm_blocks.array_view());
	other.asm_blocks.clear();
	self.global_asm.push_all(other.global_asm.array_view());
	other.global_asm.clear();
}

fn bool Ir.has_asm(&self) => self.asm_blocks.len() != 0 || self.global_asm.len() != 0;

fn AsmBlock* Ir.find_asm(&self, String name)
{
	foreach (&block : self.asm_blocks) if (block.name == name) return block;
	return null;
}

<* Function builder. Each finished declaration owns stable instruction/body slices. *>
struct Builder
{
	Allocator allocator;
	value_interner::Interner* interner;
	DynamicArenaAllocator arena;
	List{Decl} decls;
	List{AsmBlock} asm_blocks;
	List{String} global_asm;
	<* Name to index in `decls`, so `merge_global` finds redeclarations without a scan. Keys are copied. *>
	HashMap{String, usz} decl_index;
	List{Inst} instructions;
	List{Ref} body;
	uint arg_count;
	uint alloc_count;
	Ref current_label;
}

<* True when the current block already ends in a terminator (jmp, branch, switch or ret). *>
fn bool Builder.block_terminated(&self)
{
	if (self.body.len() == 0) return false;
	switch (self.instructions[(sz)self.body[self.body.len() - 1]].tag)
	{
		case JMP:
		case BRANCH:
		case SWITCH:
		case RET:
		case RET_PAIR:
		case JMP_VAL: return true;
		default: return false;
	}
}

fn void Builder.init(&self, Allocator allocator, value_interner::Interner* interner)
{
	*self = { .allocator = allocator, .interner = interner };
	self.decls.init(allocator);
	self.asm_blocks.init(allocator);
	self.global_asm.init(allocator);
	self.decl_index.init(allocator);
	self.instructions.init(allocator);
	self.body.init(allocator);
	self.arena.init(allocator, 4096);
}

fn void Builder.free(&self)
{
	foreach (decl : self.decls) decl.free();
	self.decls.free();
	foreach (&block : self.asm_blocks) block.free(self.allocator);
	self.asm_blocks.free();
	foreach (text : self.global_asm) alloc::free(self.allocator, text.ptr);
	self.global_asm.free();
	self.decl_index.free();
	self.instructions.free(); self.body.free(); self.arena.free(); *self = {};
}

<* Transfer completed declarations from the builder into the finished IR. *>
fn Ir Builder.finish(&self)
{
	// Asm blocks are already owned by `allocator` (add_asm_block / add_global_asm).
	Ir ir = { .allocator = self.allocator, .interner = self.interner, .decls = self.decls,
		.asm_blocks = self.asm_blocks, .global_asm = self.global_asm };
	self.asm_blocks.init(self.allocator);
	self.global_asm.init(self.allocator);
	self.decls.init(self.allocator);
	self.decl_index.clear();
	return ir;
}

<* Record an inline-asm statement; its strings may live in the per-function
   arena, so the builder keeps a copy in its allocator. *>
fn void Builder.add_asm_block(&self, AsmBlock block) => self.asm_blocks.push(block.copy(self.allocator));

fn void Builder.add_global_asm(&self, String text) => self.global_asm.push(text.copy(self.allocator));

fn Ref Builder.append(&self, Inst inst)
{
	Ref ref = (Ref)self.instructions.len();
	self.instructions.push(inst);
	return ref;
}

fn void Builder.insert_body(&self, sz at, Ref ref)
{
	self.body.push(ref);
	Ref[] items = self.body.array_view();
	for (sz i = items.len - 1; i > at; i--) items[i] = items[i - 1];
	items[at] = ref;
}

fn Ref Builder.add_arg(&self, value_interner::InternerRef ty)
{
	Ref ref = self.append(
	{
		.tag = ARG, .data.arg = { .location_kind = ArgLocationKind.ORDINAL }, .ty = ty
	}
	);
	self.insert_body((sz)self.arg_count, ref);
	self.arg_count++;
	return ref;
}

<* Add a parameter at a specific SysV integer/SSE register or incoming stack offset.
   Stack offsets are measured from the first stack byte at rbp+16; stack_size is
   the rounded byte footprint. stack_address returns the whole argument's address. *>
fn Ref Builder.add_arg_at(&self, value_interner::InternerRef ty, ArgLocationKind location_kind,
	uint location, uint stack_size, bool stack_address = false)
{
	assert(location_kind != ArgLocationKind.ORDINAL);
	assert(location_kind == ArgLocationKind.GP_REGISTER || location_kind == ArgLocationKind.SSE_REGISTER ||
		location_kind == ArgLocationKind.STACK);
	assert(location_kind != ArgLocationKind.GP_REGISTER || location < 6);
	assert(location_kind != ArgLocationKind.SSE_REGISTER || location < 8);
	assert((location_kind != ArgLocationKind.GP_REGISTER && location_kind != ArgLocationKind.SSE_REGISTER) || stack_size == 0);
	assert(location_kind != ArgLocationKind.STACK || (stack_size >= 8 && stack_size % 8 == 0));
	assert(location_kind != ArgLocationKind.STACK || location % 8 == 0);
	assert(location_kind != ArgLocationKind.STACK || stack_size <= (uint)(int::max - 16));
	assert(location_kind != ArgLocationKind.STACK || location <= (uint)(int::max - 16) - stack_size);
	assert(!stack_address || location_kind == ArgLocationKind.STACK);
	Ref ref = self.append(
	{
		.tag = ARG, .data.arg = { location_kind, location, stack_size, stack_address }, .ty = ty
	}
	);
	self.insert_body((sz)self.arg_count, ref);
	self.arg_count++;
	return ref;
}

fn Ref Builder.add_alloc(&self, uint size, uint align, bool is_volatile = false)
{
	Ref ref = self.append(
	{
		.tag = ALLOC, .data.alloc = { .size = size, .align = align, .is_volatile = is_volatile }, .ty = value_interner::REF_PTR
	}
	);
	self.insert_body((sz)(self.arg_count + self.alloc_count + 1), ref);
	self.alloc_count++;
	return ref;
}

<* `size` is an i64 byte count; the result is emitted at the current position, not hoisted. *>
fn Ref Builder.add_dyn_alloc(&self, Ref size, uint align)
=> self.add_inst(DYN_ALLOC, { .dyn_alloc = { .size = size, .align = align } }, value_interner::REF_PTR);

fn Ref Builder.add_stack_save(&self)
=> self.add_inst(STACK_SAVE, { .none = 0 }, value_interner::REF_PTR);

fn void Builder.add_stack_restore(&self, Ref saved)
{
	if (self.block_terminated()) return;
	self.add_inst(STACK_RESTORE, { .ref = saved }, value_interner::REF_VOID);
}

fn Ref Builder.add_atomic_load(&self, Ref ptr, AtomicOrder order, value_interner::InternerRef ty)
=> self.add_inst(ATOMIC_LOAD, { .atomic = { .ptr = ptr, .val = NONE, .order = order } }, ty);

fn void Builder.add_atomic_store(&self, Ref ptr, Ref val, AtomicOrder order)
{
	if (self.block_terminated()) return;
	self.add_inst(ATOMIC_STORE, { .atomic = { .ptr = ptr, .val = val, .order = order } }, value_interner::REF_VOID);
}

fn void Builder.add_fence(&self, AtomicOrder order)
{
	if (self.block_terminated()) return;
	self.add_inst(FENCE, { .atomic = { .ptr = NONE, .val = NONE, .order = order } }, value_interner::REF_VOID);
}

fn Ref Builder.add_shuffle(&self, Ref lhs, Ref rhs, char[] mask, value_interner::InternerRef ty)
{
	ShuffleData data = { .lhs = lhs, .rhs = rhs };
	data.mask[..] = SHUFFLE_UNDEF;
	foreach (i, m : mask) data.mask[i] = m;
	return self.add_inst(VSHUFFLE, { .shuffle = data }, ty);
}

fn Ref Builder.add_inst(&self, InstTag tag, InstData data, value_interner::InternerRef ty, bool nsw = false)
{
	Ref ref = self.append(
	{
		.tag = tag, .nsw = nsw, .data = data, .ty = ty
	}
	);
	self.body.push(ref);
	return ref;
}

fn Ref Builder.make_label(&self, String name)
=> self.append(
{
	.tag = LABEL, .data.label = name, .ty = value_interner::REF_VOID
}

);

fn void Builder.start_fn(&self)
{
	self.current_label = self.make_label("entry");
	self.body.push(self.current_label);
}

fn void Builder.start_block(&self, Ref label)
{
	if (self.body.len() != 0 && !self.block_terminated()) self.add_jump(label);
	self.body.push(label);
	self.current_label = label;
}

fn void Builder.add_jump(&self, Ref label)
{
	if (self.block_terminated()) return;
	self.add_inst(JMP, { .ref = label }, value_interner::REF_NORETURN);
}

fn void Builder.add_branch(&self, Ref cond, Ref then_label, Ref else_label)
{
	if (self.block_terminated()) return;
	self.add_inst(BRANCH, { .branch = { cond, then_label, else_label } }, value_interner::REF_NORETURN);
}

fn void Builder.add_store(&self, Ref ptr, Ref val, bool is_volatile = false)
{
	Ref ref = self.append(
	{
		.tag = STORE, .is_volatile = is_volatile, .data.bin = { ptr, val }, .ty = value_interner::REF_VOID
	}
	);
	self.body.push(ref);
}

fn Ref Builder.add_load(&self, Ref ptr, value_interner::InternerRef ty, bool is_volatile = false)
{
	Ref ref = self.append(
	{
		.tag = LOAD, .is_volatile = is_volatile, .data.ref = ptr, .ty = ty
	}
	);
	self.body.push(ref);
	return ref;
}

fn Ref Builder.add_constant(&self, value_interner::InternerRef val, value_interner::InternerRef ty)
=> self.append(
{
	.tag = CONSTANT, .data.constant = val, .ty = ty
}

);

fn Ref Builder.add_symbol(&self, String name, value_interner::InternerRef ty)
=> self.append(
{
	.tag = SYMBOL, .data.label = name.copy(&self.arena), .ty = ty
}

);

fn Ref Builder.add_phi(&self, PhiInput[] inputs, value_interner::InternerRef ty)
{
	PhiInput[] owned_inputs = alloc::new_array(&self.arena, PhiInput, inputs.len);
	owned_inputs[..] = inputs[..];
	return self.add_inst(PHI, { .phi = owned_inputs }, ty);
}

fn Ref Builder.add_call(&self, Ref func, Ref[] args, value_interner::InternerRef ty)
{
	bool[] stack_only = alloc::new_array(&self.arena, bool, args.len);
	uint[] memory_copy_bytes = alloc::new_array(&self.arena, uint, args.len);
	for (usz i = 0; i < args.len; i++)
	{
		stack_only[i] = false; memory_copy_bytes[i] = 0;
	}
	return self.add_call_abi(func, args, stack_only, memory_copy_bytes, ty);
}

<* Add a call with per-argument SysV placement and by-value memory-copy metadata. *>
fn Ref Builder.add_call_abi(&self, Ref func, Ref[] args, bool[] stack_only,
	uint[] memory_copy_bytes, value_interner::InternerRef ty)
{
	assert(args.len == stack_only.len && args.len == memory_copy_bytes.len);
	Ref[] owned_args = alloc::new_array(&self.arena, Ref, args.len);
	bool[] owned_stack_only = alloc::new_array(&self.arena, bool, args.len);
	uint[] owned_memory_copy_bytes = alloc::new_array(&self.arena, uint, args.len);
	owned_args[..] = args[..];
	owned_stack_only[..] = stack_only[..];
	owned_memory_copy_bytes[..] = memory_copy_bytes[..];
	return self.add_inst(CALL, { .call = { func, owned_args, owned_stack_only, owned_memory_copy_bytes } }, ty);
}

<* Add the high eightbyte (i64 or f64) of the result of the immediately preceding CALL. *>
fn Ref Builder.add_call_hi(&self, Ref call, value_interner::InternerRef ty = value_interner::REF_I64)
{
	assert((usz)call < (usz)self.instructions.len(), "CALL_HI must reference an existing instruction");
	assert(self.instructions[(sz)call].tag == CALL, "CALL_HI must reference a CALL");
	assert(self.body.len() != 0 && self.body[(sz)(self.body.len() - 1)] == call,
	"CALL_HI must be added immediately after its CALL");
	assert(ty == value_interner::REF_I64 || ty == value_interner::REF_F64, "CALL_HI must be i64 or f64");
	return self.add_inst(CALL_HI, { .ref = call }, ty);
}

fn void Builder.add_va_start(&self, Ref va_list)
{
	if (self.block_terminated()) return;
	self.add_inst(VA_START, { .ref = va_list }, value_interner::REF_VOID);
}

fn void Builder.add_switch(&self, Ref target, value_interner::InternerRef[] values, Ref[] labels, Ref default_label)
{
	if (self.block_terminated()) return;
	assert(values.len == labels.len);
	value_interner::InternerRef[] owned_values = alloc::new_array(&self.arena, value_interner::InternerRef, values.len);
	Ref[] owned_labels = alloc::new_array(&self.arena, Ref, labels.len);
	owned_values[..] = values[..];
	owned_labels[..] = labels[..];
	self.add_inst(SWITCH, { .switch_data = { target, owned_values, owned_labels, default_label } }, value_interner::REF_NORETURN);
}

fn Ref Builder.add_select(&self, Ref cond, Ref then_value, Ref else_value, value_interner::InternerRef ty)
=> self.add_inst(SELECT, { .branch = { cond, then_value, else_value } }, ty);

fn void Builder.add_return(&self, Ref value)
{
	if (self.block_terminated()) return;
	self.add_inst(RET, { .ref = value }, value_interner::REF_NORETURN);
}

fn void Builder.add_return_pair(&self, Ref lo, Ref hi)
{
	if (self.block_terminated()) return;
	self.add_inst(RET_PAIR, { .bin = { lo, hi } }, value_interner::REF_NORETURN);
}

<*
 Merge a named function or global into the builder. Globals follow C's
 tentative-definition rules: a strong definition replaces a tentative one,
 two tentative definitions keep one, and two strong definitions conflict.
*>
fn void Builder.merge_global(&self, Decl decl)
{
	if (try index = self.decl_index.get(decl.name))
	{
		Decl* existing = &self.decls.entries[(sz)index];

		Linkage merged_linkage = (existing.linkage == Linkage.INTERNAL || decl.linkage == Linkage.INTERNAL) ?
		Linkage.INTERNAL : Linkage.EXTERNAL;
		// Weak on any declaration makes the symbol weak (GCC semantics).
		bool merged_weak = existing.is_weak || decl.is_weak;
		bool merged_retain = existing.retain || decl.retain;
		bool keep_existing = false;
		if (existing.kind != decl.kind)
		{
			// An undefined weak function reference is carried as an EXTERN global
			// placeholder; a real definition of either kind replaces it.
			keep_existing = !decl.is_definition();
		}
		else if (existing.kind == DeclKind.FUNCTION && decl.kind == DeclKind.FUNCTION)
		{
			// Function prototypes have no body in the IR; preserve a definition
			// when a later prototype of the same name is merged.
			keep_existing = existing.body.len != 0 && decl.body.len == 0;
		}
		else if (existing.kind == DeclKind.GLOBAL && decl.kind == DeclKind.GLOBAL)
		{
			bool existing_definition = existing.is_definition();
			bool incoming_definition = decl.is_definition();
			if (existing_definition && incoming_definition)
			{
				bool existing_strong = !existing.global.tentative;
				bool incoming_strong = !decl.global.tentative;
				if (existing_strong && incoming_strong)
				{
					unreachable("multiple strong global definitions");
				}
				keep_existing = existing_strong || !incoming_strong;
			}
			else
			{
				keep_existing = existing_definition || !incoming_definition;
			}
		}

		if (keep_existing)
		{
			existing.linkage = merged_linkage;
			existing.is_weak = merged_weak;
			existing.retain = merged_retain;
			// A discarded function declaration owns copies of its instruction,
			// body, and name data. Free the copied arena too; finish_fn resets its
			// builder arena immediately after this merge.
			decl.free();
			return;
		}

		existing.free();
		decl.linkage = merged_linkage;
		decl.is_weak = merged_weak;
		decl.retain = merged_retain;
		*existing = decl;
		return;
	}
	self.decl_index.set(decl.name, (usz)self.decls.len());
	self.decls.push(decl);
}

<* Finish the current function. Linkage defaults to external, including declarations without a body. *>
fn void Builder.finish_fn(&self, String name, Linkage linkage = Linkage.EXTERNAL, InlineHint inline_hint = InlineHint.NONE, bool is_weak = false)
{
	Inst[] instructions = alloc::new_array(self.allocator, Inst, self.instructions.len());
	instructions[..] = self.instructions.array_view()[..];
	Ref[] body = alloc::new_array(self.allocator, Ref, self.body.len());
	body[..] = self.body.array_view()[..];
	String owned_name = name.copy(&self.arena);
	Decl decl = { .allocator = self.allocator, .arena = self.arena, .name = owned_name, .kind = DeclKind.FUNCTION, .linkage = linkage, .is_weak = is_weak, .inline_hint = inline_hint, .instructions = instructions, .body = body };
	self.merge_global(decl);
	self.arena.init(self.allocator, 4096);
	self.instructions.clear(); self.body.clear(); self.arg_count = 0; self.alloc_count = 0;
	self.current_label = NONE;
}

<* The merged declaration named `name`, or null. *>
fn Decl* Builder.find_decl(&self, String name)
{
	if (try index = self.decl_index.get(name)) return &self.decls.entries[(sz)index];
	return null;
}

<* Discard the current function and reset the builder's temporary storage. *>
fn void Builder.abort_fn(&self)
{
	self.arena.free();
	self.arena.init(self.allocator, 4096);
	self.instructions.clear(); self.body.clear(); self.arg_count = 0; self.alloc_count = 0;
	self.current_label = NONE;
}

<*
 Add a global declaration, copying its data and relocation symbols into an owned arena.
 The input slices and strings may be changed or freed after this call.
*>
fn void Builder.add_global(&self, String name, Linkage linkage, GlobalData global, bool is_weak = false)
{
	if (global.section == DataSection.DATA || global.section == DataSection.RODATA)
	{
		assert((ulong)global.bytes.len == global.size, "initialized global bytes must match the declared size");
	}
	else
	{
		assert(global.bytes.len == 0, "uninitialized globals must not carry byte data");
	}
	for (sz i = 1; i < global.relocs.len; i++)
	{
		assert(global.relocs[i - 1].offset <= global.relocs[i].offset, "global relocations must be sorted by offset");
	}

	DynamicArenaAllocator arena;
	arena.init(self.allocator, 1024);
	String owned_name = name.copy(&arena);
	char[] owned_bytes = alloc::new_array(&arena, char, global.bytes.len);
	owned_bytes[..] = global.bytes[..];
	DataReloc[] owned_relocs = alloc::new_array(&arena, DataReloc, global.relocs.len);
	foreach (i, relocation : global.relocs)
	{
		owned_relocs[(sz)i] = {
			.offset = relocation.offset,
			.symbol = relocation.symbol.copy(&arena),
			.addend = relocation.addend,
		};
	}
	GlobalData owned_global = global;
	owned_global.bytes = owned_bytes;
	owned_global.relocs = owned_relocs;
	Decl decl = { .allocator = self.allocator, .arena = arena, .name = owned_name, .kind = DeclKind.GLOBAL, .linkage = linkage, .is_weak = is_weak, .global = owned_global };
	self.merge_global(decl);
}
