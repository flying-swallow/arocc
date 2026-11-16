// Port of the shared state and top-level lowering from src/aro/CodeGen.zig.
// AST node dispatch is implemented in the companion codegen_nodes.c3 file.
module aro::codegen;
import aro::backend::ir, aro::compilation, aro::diagnostics, aro::preprocessor;
import aro::tree, aro::type_store, aro::value, aro::value_interner, aro::string_interner;
import std::collections::list, std::collections::map;
import std::core::dstring;

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

<* A compound statement that holds VLAs: the stack pointer saved before its first one. *>
struct VlaScope
{
	type_store::NodeIndex compound;
	ir::Ref saved;
}

<* A goto label: its IR block and, once defined, the VLA scopes live at it. *>
struct GotoLabel
{
	ir::Ref label;
	bool defined;
	<* Range in `CodeGen.vla_save_pool` of the saved stack pointers live at the label. *>
	sz saves_start;
	sz saves_len;
}

<* A goto out of VLA scopes whose stub block (restore, then jump) is emitted at function end. *>
struct PendingGoto
{
	ir::Ref stub;
	sz label_index;
	sz saves_start;
	sz saves_len;
}

struct Symbol
{
	string_interner::StringId name;
	ir::Ref value;
}

<* A file-scope name allocated for a block-scope static or implicit variable. *>
struct EmittedVariable
{
	type_store::NodeIndex node;
	String name;
}

<* CodeGen's public fault is compilation::FATAL_ERROR; allocations panic on OOM. *>
struct CodeGen
{
	tree::Tree* tree;
	compilation::Compilation* comp;
	preprocessor::Preprocessor* pp;
	int tu_id;
	String current_fn;
	uint static_counter;
	uint string_counter;
	ir::Builder builder;
	WipSwitch* wip_switch;
	List{Symbol} symbols;
	List{EmittedVariable} emitted_block_statics;
	List{EmittedVariable} implicit_vars;
	List{EmittedVariable} emitted_strings;
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
	<* `vla_scopes.len()` where the current break/continue target was entered. *>
	sz break_vla_depth;
	sz continue_vla_depth;
	type_store::NodeIndex current_compound;
	<* Runtime byte size (i64) of each VLA type, keyed by its unqualified base QualType. *>
	HashMap{uint, ir::Ref} vla_sizes;
	List{VlaScope} vla_scopes;
	List{ir::Ref} vla_save_pool;
	HashMap{uint, sz} goto_label_index;
	List{GotoLabel} goto_labels;
	List{PendingGoto} pending_gotos;
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
	self.comp.diagnostics.add(
		{
			.kind = diagnostics::MessageKind.FATAL_ERROR, .text = text
		}
	)!;
	return compilation::FATAL_ERROR~;
}

<*
 Lower every top-level function and variable declaration in `tree` to backend
 IR. Unsupported source constructs report the same fatal TODO diagnostics as
 the Zig implementation.
 @return? compilation::FATAL_ERROR
*>
fn ir::Ir? gen_ir(tree::Tree* tree, preprocessor::Preprocessor* pp, int tu_id = -1)
{
	compilation::Compilation* comp = tree.comp;
	CodeGen c = { .tree = tree, .comp = comp, .pp = pp, .tu_id = tu_id };
	c.builder.init(comp.gpa, &comp.interner);
	c.symbols.init(comp.gpa);
	c.emitted_block_statics.init(comp.gpa);
	c.implicit_vars.init(comp.gpa);
	c.emitted_strings.init(comp.gpa);
	c.ret_nodes.init(comp.gpa);
	c.phi_nodes.init(comp.gpa);
	c.record_elem_buf.init(comp.gpa);
	c.record_cache.init(comp.gpa);
	c.vla_sizes.init(comp.gpa);
	c.vla_scopes.init(comp.gpa);
	c.vla_save_pool.init(comp.gpa);
	c.goto_label_index.init(comp.gpa);
	c.goto_labels.init(comp.gpa);
	c.pending_gotos.init(comp.gpa);
	defer c.vla_sizes.free();
	defer c.vla_scopes.free();
	defer c.vla_save_pool.free();
	defer c.goto_label_index.free();
	defer c.goto_labels.free();
	defer c.pending_gotos.free();
	defer c.symbols.free();
	defer c.emitted_block_statics.free();
	defer c.implicit_vars.free();
	defer c.emitted_strings.free();
	defer c.ret_nodes.free();
	defer c.phi_nodes.free();
	defer c.record_elem_buf.free();
	defer c.record_cache.free();
	defer c.builder.free();

	foreach (decl_index : tree.root_decls)
	{
		// These caches store names in the per-root builder arena.
		c.emitted_block_statics.clear();
		c.implicit_vars.clear();
		c.emitted_strings.clear();
		c.builder.arena.free();
		c.builder.arena.init(comp.gpa, 4096);
		Node decl = decl_index.get(tree);
		switch (decl.kind)
		{
			case EMPTY_DECL:
			case STATIC_ASSERT:
			case TYPEDEF:
			case STRUCT_DECL:
			case UNION_DECL:
			case ENUM_DECL:
			case STRUCT_FORWARD_DECL:
			case UNION_FORWARD_DECL:
			case ENUM_FORWARD_DECL:
				break;
			case FUNCTION:
				if (decl.function.body.is_null() || decl.function.is_inline) continue;
				c.gen_fn(decl_index, decl.function)!;
			case VARIABLE:
				c.gen_var(decl.variable, decl_index)!;
			case GLOBAL_ASM:
				c.fail("TODO global assembly")!;
				unreachable();
			default:
				unreachable("unexpected top-level node in CodeGen.gen_ir");
		}
	}
	return c.builder.finish();
}

<* Return a previously allocated name for a block-scope static, if any. *>
fn String CodeGen.find_emitted_static(&self, type_store::NodeIndex node)
{
	foreach (emitted : self.emitted_block_statics)
	{
		if (emitted.node == node) return emitted.name;
	}
	return "";
}

<* Allocate a TU-unique symbol name for a block-scope static. *>
fn String CodeGen.block_static_name(&self, type_store::NodeIndex node, String variable_name)
{
	String existing = self.find_emitted_static(node);
	if (existing.len != 0) return existing;
	DString renamed;
	renamed.init(&self.builder.arena);
	renamed.appendf("%s.%s.%d", self.current_fn, variable_name, self.static_counter);
	self.static_counter++;
	String name = self.symbol_name(renamed.str_view(), true);
	self.emitted_block_statics.push(
		{
			.node = node, .name = name
		}
	);
	return name;
}

<* Return a previously allocated name for an implicit function-name variable. *>
fn String CodeGen.find_implicit_var(&self, type_store::NodeIndex node)
{
	foreach (emitted : self.implicit_vars)
	{
		if (emitted.node == node) return emitted.name;
	}
	return "";
}

<* Allocate a stable internal symbol name for __func__ and its aliases. *>
fn String CodeGen.implicit_var_name(&self, type_store::NodeIndex node)
{
	String existing = self.find_implicit_var(node);
	if (existing.len != 0) return existing;
	DString renamed;
	renamed.init(&self.builder.arena);
	renamed.appendf("__func__.%s", self.current_fn);
	String name = renamed.str_view();
	self.implicit_vars.push(
		{
			.node = node, .name = name
		}
	);
	return name;
}

fn String CodeGen.find_emitted_string(&self, type_store::NodeIndex node)
{
	foreach (emitted : self.emitted_strings)
	{
		if (emitted.node == node) return emitted.name;
	}
	return "";
}

<* Whether a node is one of the translation unit's file-scope declarations. *>
fn bool CodeGen.is_root_declaration(&self, type_store::NodeIndex declaration)
{
	foreach (root_decl : self.tree.root_decls) if (root_decl == declaration) return true;
	return false;
}

<* Whether a declaration has internal linkage, following parser redeclaration links. *>
fn bool CodeGen.has_internal_linkage(&self, type_store::NodeIndex declaration)
{
	tree::Node node = declaration.get(self.tree);
	switch (node.kind)
	{
		case FUNCTION:
			if (node.function.is_static) return true;
			if (!node.function.definition.is_null())
			{
				tree::Node definition = node.function.definition.unwrap().get(self.tree);
				if (definition.kind == tree::NodeKind.FUNCTION && definition.function.is_static) return true;
			}
			foreach (root_decl : self.tree.root_decls)
			{
				tree::Node prior = root_decl.get(self.tree);
				if (prior.kind != tree::NodeKind.FUNCTION || !prior.function.is_static) continue;
				if (root_decl == declaration) return true;
				if (!prior.function.definition.is_null() && prior.function.definition.unwrap() == declaration) return true;
			}
			return false;
		case VARIABLE:
			if (!node.variable.definition.is_null())
			{
				tree::Node definition = node.variable.definition.unwrap().get(self.tree);
				if (definition.kind == tree::NodeKind.VARIABLE && definition.variable.storage_class == tree::VariableStorageClass.STATIC)
				{
					foreach (root_decl : self.tree.root_decls) if (root_decl == node.variable.definition.unwrap()) return true;
				}
			}
			foreach (root_decl : self.tree.root_decls)
			{
				tree::Node prior = root_decl.get(self.tree);
				if (prior.kind != tree::NodeKind.VARIABLE || prior.variable.storage_class != tree::VariableStorageClass.STATIC) continue;
				if (root_decl == declaration) return true;
				if (!prior.variable.definition.is_null() && prior.variable.definition.unwrap() == declaration) return true;
			}
			return false;
		default: return false;
	}
}

<* Add the TU suffix only to internal-linkage symbols when whole-program mode supplied an ID. *>
fn String CodeGen.symbol_name(&self, String name, bool internal)
{
	if (self.tu_id < 0 || !internal) return name;
	DString renamed;
	renamed.init(&self.builder.arena);
	renamed.appendf("%s.tu%d", name, self.tu_id);
	return renamed.str_view();
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
			value_interner::InternerRef record_type = self.builder.interner.put(
				{
					.tag = RECORD_TY, .record_ty = elems
				}
			);
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
			return self.builder.interner.put(
				{
					.tag = INT_TY, .ty_bits = base.ty.int_ty.bits(self.comp)
			}
			);
		case BIT_INT:
			return self.builder.interner.put(
				{
					.tag = INT_TY, .ty_bits = base.ty.bit_int.bits
				}
			);
		case FLOAT:
			return self.builder.interner.put(
				{
					.tag = FLOAT_TY, .ty_bits = base.ty.float_ty.bits(self.comp)
			}
			);
		case STORAGE_FLOAT:
			return self.builder.interner.put(
				{
					.tag = INT_TY, .ty_bits = base.ty.storage_float.bits
				}
			);
		case ARRAY:
			value_interner::InternerRef elem = self.gen_type(base.ty.array.elem)!;
			switch (base.ty.array.len.kind)
			{
			case FIXED:
			case STATIC:
				return self.builder.interner.put(
					{
						.tag = ARRAY_TY, .array_ty = { .len = base.ty.array.len.len, .child = elem }
					}
				);
			case VARIABLE:
			case UNSPECIFIED_VARIABLE:
				self.fail("TODO VLAs")!;
				unreachable();
			case INCOMPLETE:
				unreachable("incomplete array type in CodeGen.gen_type");
		}
		case VECTOR:
			value_interner::InternerRef elem = self.gen_type(base.ty.vector.elem)!;
			return self.builder.interner.put(
				{
					.tag = VECTOR_TY, .vector_ty = { .len = base.ty.vector.len, .child = elem }
				}
			);
		case NULLPTR_T:
			self.fail("TODO lower nullptr_t")!;
			unreachable();
		case TYPEOF:
		case TYPEDEF:
			unreachable("base() must strip typeof and typedef");
	}
}

<* Lower one function definition and assemble its return block. *>
fn void? CodeGen.gen_fn(&self, type_store::NodeIndex declaration, tree::NodeFunction function)
{
	String name = self.symbol_name(self.tree.tok_slice(function.name_tok), self.has_internal_linkage(declaration));
	String old_current_fn = self.current_fn;
	uint old_static_counter = self.static_counter;
	defer self.current_fn = old_current_fn;
	defer self.static_counter = old_static_counter;
	self.current_fn = name;
	self.static_counter = 0;
	type_store::Func func_type = function.qt.base(self.comp).ty.func;
	self.ret_nodes.clear();
	// C3 deviation: Zig never clears `symbols`, so a name could resolve to an
	// earlier function's ALLOC. Locals are per function.
	self.symbols.clear();
	self.vla_sizes.clear();
	self.vla_scopes.clear();
	self.vla_save_pool.clear();
	self.goto_label_index.clear();
	self.goto_labels.clear();
	self.pending_gotos.clear();
	self.break_vla_depth = 0;
	self.continue_vla_depth = 0;
	self.current_compound = (type_store::NodeIndex)type_store::NODE_NULL;
	self.builder.start_fn();
	foreach (param : func_type.params)
	{
		ir::Ref arg = self.builder.add_arg(self.gen_type(param.qt)!);
		uint size = (uint)param.qt.sizeof(self.comp);
		uint alignment = param.qt.alignof(self.comp);
		ir::Ref alloc = self.builder.add_alloc(size, alignment, param.qt.is_volatile);
		self.builder.add_store(alloc, arg);
		self.symbols.push(
			{
				.name = param.name, .value = alloc
			}
		);
	}

	self.return_label = self.builder.make_label("return");
	self.gen_stmt(function.body.unwrap())!;
	// C3 deviations from Zig genFn: a void RET carries NONE (not ref 0), `return;`
	// jumps reach a placed `return` block, and the single-return shortcut only
	// replaces the body's final jump when that jump really is the return jump.
	if (self.ret_nodes.len() == 0)
	{
		if (!self.builder.block_terminated()) self.builder.add_jump(self.return_label);
		self.builder.start_block(self.return_label);
		self.builder.add_inst(ir::InstTag.RET, { .ref = ir::NONE }, value_interner::REF_NORETURN);
	}
	else if (self.ret_nodes.len() == 1 && self.is_final_return_jump())
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
	self.emit_pending_gotos();
	ir::Linkage linkage = self.has_internal_linkage(declaration) ? ir::Linkage.INTERNAL : ir::Linkage.EXTERNAL;
	self.builder.finish_fn(name, linkage);
}

<* The function body's last instruction is the jump to the return block. *>
fn bool CodeGen.is_final_return_jump(&self)
{
	if (self.builder.body.len() == 0) return false;
	ir::Inst last = self.builder.instructions[(sz)self.builder.body[self.builder.body.len() - 1]];
	return last.tag == ir::InstTag.JMP && last.data.ref == self.return_label;
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
			self.phi_nodes.push(
				{
					.label = self.builder.current_label, .value = cond
				}
			);
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
	self.phi_nodes.push(
		{
			.label = self.builder.current_label, .value = constant
		}
	);
}
