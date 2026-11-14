// Port of the data model and builder in src/backend/Ir.zig. This C3 IR is a
// stable, index-based representation; references remain valid when lists grow.
module aro::backend::ir;
import aro::value_interner, std::collections::list;

typedef Ref = uint;
const Ref NONE = (Ref)uint::max;

enum InstTag : char
{
	CONSTANT, ARG, SYMBOL, LABEL, LABEL_ADDR, JMP, SWITCH, BRANCH, SELECT,
	JMP_VAL, CALL, ALLOC, PHI, STORE, BIT_OR, BIT_XOR, BIT_AND, BIT_SHL,
	BIT_SHR, CMP_EQ, CMP_NE, CMP_LT, CMP_LTE, CMP_GT, CMP_GTE, ADD, SUB,
	MUL, DIV, MOD, RET, LOAD, BIT_NOT, NEGATE, TRUNC, ZEXT, SEXT,
}

struct BinData { Ref lhs; Ref rhs; }
struct AllocData { uint size; uint align; }
struct BranchData { Ref cond; Ref then_label; Ref else_label; }
struct SwitchData { Ref target; value_interner::InternerRef[] values; Ref[] labels; Ref default_label; }
struct CallData { Ref func; Ref[] args; }
struct PhiInput { Ref label; Ref value; }

struct InstData
{
	union
	{
		<* Zig `Inst.Data.none`, used by `ARG`. The byte is ignored; C3 unions cannot contain `void`. *>
		char none;
		value_interner::InternerRef constant;
		Ref ref;
		AllocData alloc;
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
	Inst[] instructions;
	Ref[] body;
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

<* Function builder. Each finished declaration owns stable instruction/body slices. *>
struct Builder
{
	Allocator allocator;
	value_interner::Interner* interner;
	DynamicArenaAllocator arena;
	List{Decl} decls;
	List{Inst} instructions;
	List{Ref} body;
	uint arg_count;
	uint alloc_count;
	Ref current_label;
}

fn void Builder.init(&self, Allocator allocator, value_interner::Interner* interner)
{
	*self = { .allocator = allocator, .interner = interner };
	self.decls.init(allocator);
	self.instructions.init(allocator);
	self.body.init(allocator);
	self.arena.init(allocator, 4096);
}

fn void Builder.free(&self)
{
	foreach (decl : self.decls) decl.free();
	self.decls.free();
	self.instructions.free(); self.body.free(); self.arena.free(); *self = {};
}

<* Transfer completed declarations from the builder into the finished IR. *>
fn Ir Builder.finish(&self)
{
	Ir ir = { .allocator = self.allocator, .interner = self.interner, .decls = self.decls };
	self.decls.init(self.allocator);
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

fn Ref Builder.add_alloc(&self, uint size, uint align)
{
	Ref ref = self.append({ .tag = ALLOC, .data.alloc = { size, align }, .ty = value_interner::REF_PTR });
	self.insert_body((sz)(self.arg_count + self.alloc_count + 1), ref);
	self.alloc_count++;
	return ref;
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
	self.body.push(label);
	self.current_label = label;
}

fn void Builder.add_jump(&self, Ref label)
{
	self.add_inst(JMP, { .ref = label }, value_interner::REF_NORETURN);
}

fn void Builder.add_branch(&self, Ref cond, Ref then_label, Ref else_label)
{
	self.add_inst(BRANCH, { .branch = { cond, then_label, else_label } }, value_interner::REF_NORETURN);
}

fn void Builder.add_store(&self, Ref ptr, Ref val)
{
	self.add_inst(STORE, { .bin = { ptr, val } }, value_interner::REF_VOID);
}

fn Ref Builder.add_constant(&self, value_interner::InternerRef val, value_interner::InternerRef ty)
	=> self.append({ .tag = CONSTANT, .data.constant = val, .ty = ty });

fn Ref Builder.add_symbol(&self, String name, value_interner::InternerRef ty)
	=> self.append({ .tag = SYMBOL, .data.label = name, .ty = ty });

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
	self.add_inst(RET, { .ref = value }, value_interner::REF_NORETURN);
}

fn void Builder.finish_fn(&self, String name)
{
	Inst[] instructions = alloc::new_array(self.allocator, Inst, self.instructions.len());
	instructions[..] = self.instructions.array_view()[..];
	Ref[] body = alloc::new_array(self.allocator, Ref, self.body.len());
	body[..] = self.body.array_view()[..];
	Decl decl = { .allocator = self.allocator, .arena = self.arena, .name = name, .instructions = instructions, .body = body };
	foreach (&existing : self.decls)
	{
		if (existing.name == name)
		{
			existing.free();
			*existing = decl;
			self.arena.init(self.allocator, 4096);
			self.instructions.clear(); self.body.clear(); self.arg_count = 0; self.alloc_count = 0;
			return;
		}
	}
	self.decls.push(decl);
	self.arena.init(self.allocator, 4096);
	self.instructions.clear(); self.body.clear(); self.arg_count = 0; self.alloc_count = 0;
}
