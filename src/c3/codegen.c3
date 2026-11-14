// Port of the shared state and top-level lowering from src/aro/CodeGen.zig.
// AST node dispatch is implemented in the companion codegen_nodes.c3 file.
module aro::codegen;
import aro::backend::ir, aro::compilation, aro::diagnostics, aro::preprocessor;
import aro::tree, aro::type_store, aro::value, aro::value_interner, aro::string_interner;
import std::collections::list, std::collections::map;

<* An active switch statement's cases. *>
struct SwitchCase
{
	value_interner::InternerRef value;
	ir::Ref label;
}

<* Switch lowering state shared with statement dispatch. *>
struct WipSwitch
{
	List{SwitchCase} cases;
	bool has_default;
	ir::Ref default_label;
	ulong size;
}

struct Symbol
{
	string_interner::StringId name;
	ir::Ref value;
}

<* CodeGen's public fault is compilation::FATAL_ERROR; allocations panic on OOM. *>
struct CodeGen
{
	tree::Tree* tree;
	compilation::Compilation* comp;
	preprocessor::Preprocessor* pp;
	ir::Builder builder;
	WipSwitch* wip_switch;
	List{Symbol} symbols;
	List{ir::PhiInput} ret_nodes;
	List{ir::PhiInput} phi_nodes;
	List{value_interner::InternerRef} record_elem_buf;
	HashMap{uint, value_interner::InternerRef} record_cache;
	bool has_cond_dummy_ty;
	value_interner::InternerRef cond_dummy_ty;
	bool bool_invert;
	ir::Ref bool_end_label;
	ir::Ref cond_dummy_ref;
	ir::Ref continue_label;
	ir::Ref break_label;
	ir::Ref return_label;
	bool has_compound_assign_dummy;
	ir::Ref compound_assign_dummy;
}

<*
 Report a fatal lowering diagnostic. The text is borrowed for this call; the
 diagnostics sink copies it when it owns the output.
 @return? compilation::FATAL_ERROR
*>
fn void? CodeGen.fail(&self, String text)
{
	self.comp.diagnostics.add({ .kind = diagnostics::MessageKind.FATAL_ERROR, .text = text })!;
	return compilation::FATAL_ERROR~;
}

<*
 Lower every top-level function and variable declaration in `tree` to backend
 IR. Unsupported source constructs report the same fatal TODO diagnostics as
 the Zig implementation.
 @return? compilation::FATAL_ERROR
*>
fn ir::Ir? gen_ir(tree::Tree* tree, preprocessor::Preprocessor* pp)
{
	compilation::Compilation* comp = tree.comp;
	CodeGen c = { .tree = tree, .comp = comp, .pp = pp };
	c.builder.init(comp.gpa, &comp.interner);
	c.symbols.init(comp.gpa);
	c.ret_nodes.init(comp.gpa);
	c.phi_nodes.init(comp.gpa);
	c.record_elem_buf.init(comp.gpa);
	c.record_cache.init(comp.gpa);
	defer c.symbols.free();
	defer c.ret_nodes.free();
	defer c.phi_nodes.free();
	defer c.record_elem_buf.free();
	defer c.record_cache.free();
	defer c.builder.free();

	foreach (decl_index : tree.root_decls)
	{
		c.builder.arena.free();
		c.builder.arena.init(comp.gpa, 4096);
		Node decl = decl_index.get(tree);
		switch (decl.kind)
		{
			case EMPTY_DECL: case STATIC_ASSERT: case TYPEDEF:
			case STRUCT_DECL: case UNION_DECL: case ENUM_DECL:
			case STRUCT_FORWARD_DECL: case UNION_FORWARD_DECL: case ENUM_FORWARD_DECL:
				break;
			case FUNCTION:
				if (decl.function.body.is_null() || decl.function.is_inline) continue;
			c.gen_fn(decl.function)!;
			case VARIABLE:
				c.gen_var(decl.variable)!;
			case GLOBAL_ASM:
				c.fail("TODO global assembly")!;
				unreachable();
			default:
				unreachable("unexpected top-level node in CodeGen.gen_ir");
		}
	}
	return c.builder.finish();
}

<*
 Convert a C type to its backend IR type. Struct layouts are interned by
 unqualified type; unions, blocks, complex/atomic types, VLAs, bitfields and
 nullptr_t retain the source TODO diagnostics.
 @return? compilation::FATAL_ERROR
*>
fn value_interner::InternerRef? CodeGen.gen_type(&self, type_store::QualType qt)
{
	type_store::BaseType base = qt.base(self.comp);
	switch (base.ty.tag)
	{
		case VOID: return value_interner::REF_VOID;
		case BOOL: return value_interner::REF_I1;
		case STRUCT:
			uint cache_key = (uint)base.qt.unqualified();
			if (try cached = self.record_cache.get(cache_key)) return cached;
			usz first_elem = (usz)self.record_elem_buf.len();
			foreach (field : base.ty.record.fields)
			{
				if (field.bit_width != type_store::BIT_WIDTH_NULL)
				{
					self.fail("TODO lower struct bitfields")!;
					unreachable();
				}
				value_interner::InternerRef field_type = self.gen_type(field.qt)!;
				self.record_elem_buf.push(field_type);
			}
			value_interner::InternerRef[] elems = self.record_elem_buf.array_view()[first_elem..];
			value_interner::InternerRef record_type = self.builder.interner.put({ .tag = RECORD_TY, .record_ty = elems });
			while ((usz)self.record_elem_buf.len() > first_elem) self.record_elem_buf.pop()!!;
			self.record_cache.set(cache_key, record_type);
			return record_type;
		case UNION:
			self.fail("TODO lower union types")!;
			unreachable();
		case POINTER: return value_interner::REF_PTR;
		case FUNC: return value_interner::REF_FUNC;
		case BLOCK:
			self.fail("TODO lower blocks")!;
			unreachable();
		case COMPLEX:
			self.fail("TODO lower complex types")!;
			unreachable();
		case ATOMIC:
			self.fail("TODO lower atomic types")!;
			unreachable();
		case ENUM:
			if (!base.ty.enum_ty.has_tag) unreachable("enum without a tag in CodeGen.gen_type");
			return self.gen_type(base.ty.enum_ty.tag);
		case INT:
			return self.builder.interner.put({ .tag = INT_TY, .bits = base.ty.int_ty.bits(self.comp) });
		case BIT_INT:
			return self.builder.interner.put({ .tag = INT_TY, .bits = base.ty.bit_int.bits });
		case FLOAT:
			return self.builder.interner.put({ .tag = FLOAT_TY, .bits = base.ty.float_ty.bits(self.comp) });
		case STORAGE_FLOAT:
			return self.builder.interner.put({ .tag = INT_TY, .bits = base.ty.storage_float.bits });
		case ARRAY:
			value_interner::InternerRef elem = self.gen_type(base.ty.array.elem)!;
			switch (base.ty.array.len.kind)
			{
				case FIXED: case STATIC:
					return self.builder.interner.put({ .tag = ARRAY_TY, .array_ty = { .len = base.ty.array.len.len, .child = elem } });
				case VARIABLE: case UNSPECIFIED_VARIABLE:
					self.fail("TODO VLAs")!;
					unreachable();
				case INCOMPLETE:
					unreachable("incomplete array type in CodeGen.gen_type");
			}
		case VECTOR:
			value_interner::InternerRef elem = self.gen_type(base.ty.vector.elem)!;
			return self.builder.interner.put({ .tag = VECTOR_TY, .vector_ty = { .len = base.ty.vector.len, .child = elem } });
		case NULLPTR_T:
			self.fail("TODO lower nullptr_t")!;
			unreachable();
		case TYPEOF: case TYPEDEF:
			unreachable("base() must strip typeof and typedef");
	}
}

<* Lower one function definition and assemble its return block. *>
fn void? CodeGen.gen_fn(&self, tree::NodeFunction function)
{
	String name = self.tree.tok_slice(function.name_tok);
	type_store::Func func_type = function.qt.base(self.comp).ty.func;
	self.ret_nodes.clear();
	self.builder.start_fn();
	foreach (param : func_type.params)
	{
		ir::Ref arg = self.builder.add_arg(self.gen_type(param.qt)!);
		uint size = (uint)param.qt.sizeof(self.comp);
		uint alignment = param.qt.alignof(self.comp);
		ir::Ref alloc = self.builder.add_alloc(size, alignment);
		self.builder.add_store(alloc, arg);
		self.symbols.push({ .name = param.name, .value = alloc });
	}

	self.return_label = self.builder.make_label("return");
	self.gen_stmt(function.body.unwrap())!;
	if (self.ret_nodes.len() == 0)
	{
		self.builder.add_inst(ir::InstTag.RET, { .none = 0 }, value_interner::REF_NORETURN);
	}
	else if (self.ret_nodes.len() == 1)
	{
		self.builder.body.remove_last()!!;
		self.builder.add_inst(ir::InstTag.RET, { .ref = self.ret_nodes[0].value }, value_interner::REF_NORETURN);
	}
	else
	{
		self.builder.start_block(self.return_label);
		ir::PhiInput[] inputs = self.ret_nodes.array_view();
		ir::Ref phi = self.builder.add_phi(inputs, self.gen_type(func_type.return_type)!);
		self.builder.add_inst(ir::InstTag.RET, { .ref = phi }, value_interner::REF_NORETURN);
	}
	self.builder.finish_fn(name);
}

<* Emit a unary instruction with the C type's corresponding IR result type. *>
fn ir::Ref? CodeGen.add_un(&self, ir::InstTag tag, ir::Ref operand, type_store::QualType qt)
{
	return self.builder.add_inst(tag, { .ref = operand }, self.gen_type(qt)!);
}

<* Emit a binary instruction with the C type's corresponding IR result type. *>
fn ir::Ref? CodeGen.add_bin(&self, ir::InstTag tag, ir::Ref lhs, ir::Ref rhs, type_store::QualType qt)
{
	return self.builder.add_inst(tag, { .bin = { .lhs = lhs, .rhs = rhs } }, self.gen_type(qt)!);
}

<* Emit a branch, collecting incoming values when a boolean expression ends here. *>
fn void? CodeGen.add_branch(&self, ir::Ref cond, ir::Ref true_label, ir::Ref false_label)
{
	if (true_label == self.bool_end_label)
	{
		if (false_label == self.bool_end_label)
		{
			self.phi_nodes.push({ .label = self.builder.current_label, .value = cond });
			return;
		}
		self.add_bool_phi(!self.bool_invert)!;
	}
	if (false_label == self.bool_end_label) self.add_bool_phi(self.bool_invert)!;
	self.builder.add_branch(cond, true_label, false_label);
}

<* Add one constant incoming boolean value for a short circuit branch. *>
fn void? CodeGen.add_bool_phi(&self, bool value)
{
	ir::Ref constant = self.builder.add_constant(value::from_bool(value).ref(), value_interner::REF_I1);
	self.phi_nodes.push({ .label = self.builder.current_label, .value = constant });
}
