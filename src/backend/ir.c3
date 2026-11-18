// Port of the data model and builder in src/backend/Ir.zig. This C3 IR is a
// stable, index-based representation; references remain valid when lists grow.
module aro::backend::ir;
import aro::value_interner, std::collections::list, std::collections::map;

typedef Ref = uint;
const Ref NONE = (Ref)uint::max;

<*
 IR instructions with their dump spelling. Deviation from Zig Ir.zig: the
 operations whose meaning depends on signedness are split into signed and
 unsigned tags (IR integer types carry only a bit width), so a target can map
 each tag to one machine instruction.
*>
enum InstTag : char (String name)
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
	RET { "ret" },
	LOAD { "load" },
	BIT_NOT { "bit_not" },
	NEGATE { "negate" },
	TRUNC { "trunc" },
	ZEXT { "zext" },
	SEXT { "sext" },
}

struct BinData { Ref lhs; Ref rhs; }
struct AllocData { uint size; uint align; bool is_volatile; }
struct DynAllocData { Ref size; uint align; }
struct BranchData { Ref cond; Ref then_label; Ref else_label; }
struct SwitchData { Ref target; value_interner::InternerRef[] values; Ref[] labels; Ref default_label; }
struct CallData { Ref func; Ref[] args; }
struct PhiInput { Ref label; Ref value; }

enum DeclKind : char
{
	FUNCTION,
	GLOBAL,
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
}

struct InstData
{
	union
	{
		<* Zig `Inst.Data.none`, used by `ARG`. The byte is ignored; C3 unions cannot contain `void`. *>
		char none;
		value_interner::InternerRef constant;
		Ref ref;
		AllocData alloc;
		DynAllocData dyn_alloc;
		BinData bin;
		BranchData branch;
		SwitchData switch_data;
		CallData call;
		PhiInput[] phi;
		String label;
	}
}

struct Inst { InstTag tag; InstData data; value_interner::InternerRef ty; }

struct Decl
{
	Allocator allocator;
	DynamicArenaAllocator arena;
	String name;
	DeclKind kind;
	Linkage linkage;
	Inst[] instructions;
	Ref[] body;
	GlobalData global;
}

fn bool Decl.is_definition(&self)
{
	switch (self.kind)
	{
		case FUNCTION: return true;
		case GLOBAL: return self.global.section != DataSection.EXTERN;
	}
}

struct Ir
{
	Allocator allocator;
	value_interner::Interner* interner;
	List{Decl} decls;
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
	*self = {};
}

<* Transfer declarations from another IR into this one and empty its list. *>
fn void Ir.take_decls(&self, Ir* other)
{
	self.decls.push_all(other.decls.array_view());
	other.decls.clear();
}

<* Function builder. Each finished declaration owns stable instruction/body slices. *>
struct Builder
{
	Allocator allocator;
	value_interner::Interner* interner;
	DynamicArenaAllocator arena;
	List{Decl} decls;
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
		case JMP: case BRANCH: case SWITCH: case RET: case JMP_VAL: return true;
		default: return false;
	}
}

fn void Builder.init(&self, Allocator allocator, value_interner::Interner* interner)
{
	*self = { .allocator = allocator, .interner = interner };
	self.decls.init(allocator);
	self.decl_index.init(allocator);
	self.instructions.init(allocator);
	self.body.init(allocator);
	self.arena.init(allocator, 4096);
}

fn void Builder.free(&self)
{
	foreach (decl : self.decls) decl.free();
	self.decls.free();
	self.decl_index.free();
	self.instructions.free(); self.body.free(); self.arena.free(); *self = {};
}

<* Transfer completed declarations from the builder into the finished IR. *>
fn Ir Builder.finish(&self)
{
	Ir ir = { .allocator = self.allocator, .interner = self.interner, .decls = self.decls };
	self.decls.init(self.allocator);
	self.decl_index.clear();
	return ir;
}

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
	Ref ref = self.append({ .tag = ARG, .data.none = 0, .ty = ty });
	self.insert_body((sz)self.arg_count, ref);
	self.arg_count++;
	return ref;
}

fn Ref Builder.add_alloc(&self, uint size, uint align, bool is_volatile = false)
{
	Ref ref = self.append({ .tag = ALLOC, .data.alloc = { .size = size, .align = align, .is_volatile = is_volatile }, .ty = value_interner::REF_PTR });
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

fn Ref Builder.add_inst(&self, InstTag tag, InstData data, value_interner::InternerRef ty)
{
	Ref ref = self.append({ .tag = tag, .data = data, .ty = ty });
	self.body.push(ref);
	return ref;
}

fn Ref Builder.make_label(&self, String name)
	=> self.append({ .tag = LABEL, .data.label = name, .ty = value_interner::REF_VOID });

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

fn void Builder.add_store(&self, Ref ptr, Ref val)
{
	self.add_inst(STORE, { .bin = { ptr, val } }, value_interner::REF_VOID);
}

fn Ref Builder.add_constant(&self, value_interner::InternerRef val, value_interner::InternerRef ty)
	=> self.append({ .tag = CONSTANT, .data.constant = val, .ty = ty });

fn Ref Builder.add_symbol(&self, String name, value_interner::InternerRef ty)
	=> self.append({ .tag = SYMBOL, .data.label = name.copy(&self.arena), .ty = ty });

fn Ref Builder.add_phi(&self, PhiInput[] inputs, value_interner::InternerRef ty)
{
	PhiInput[] owned_inputs = alloc::new_array(&self.arena, PhiInput, inputs.len);
	owned_inputs[..] = inputs[..];
	return self.add_inst(PHI, { .phi = owned_inputs }, ty);
}

fn Ref Builder.add_call(&self, Ref func, Ref[] args, value_interner::InternerRef ty)
{
	Ref[] owned_args = alloc::new_array(&self.arena, Ref, args.len);
	owned_args[..] = args[..];
	return self.add_inst(CALL, { .call = { func, owned_args } }, ty);
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
		bool keep_existing = false;
		if (existing.kind == DeclKind.FUNCTION && decl.kind == DeclKind.FUNCTION)
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
			// A discarded function declaration owns copies of its instruction,
			// body, and name data. Free the copied arena too; finish_fn resets its
			// builder arena immediately after this merge.
			decl.free();
			return;
		}

		existing.free();
		decl.linkage = merged_linkage;
		*existing = decl;
		return;
	}
	self.decl_index.set(decl.name, (usz)self.decls.len());
	self.decls.push(decl);
}

<* Finish the current function. Linkage defaults to external, including declarations without a body. *>
fn void Builder.finish_fn(&self, String name, Linkage linkage = Linkage.EXTERNAL)
{
	Inst[] instructions = alloc::new_array(self.allocator, Inst, self.instructions.len());
	instructions[..] = self.instructions.array_view()[..];
	Ref[] body = alloc::new_array(self.allocator, Ref, self.body.len());
	body[..] = self.body.array_view()[..];
	String owned_name = name.copy(&self.arena);
	Decl decl = { .allocator = self.allocator, .arena = self.arena, .name = owned_name, .kind = DeclKind.FUNCTION, .linkage = linkage, .instructions = instructions, .body = body };
	self.merge_global(decl);
	self.arena.init(self.allocator, 4096);
	self.instructions.clear(); self.body.clear(); self.arg_count = 0; self.alloc_count = 0;
}

<*
 Add a global declaration, copying its data and relocation symbols into an owned arena.
 The input slices and strings may be changed or freed after this call.
*>
fn void Builder.add_global(&self, String name, Linkage linkage, GlobalData global)
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
	Decl decl = { .allocator = self.allocator, .arena = arena, .name = owned_name, .kind = DeclKind.GLOBAL, .linkage = linkage, .global = owned_global };
	self.merge_global(decl);
}
