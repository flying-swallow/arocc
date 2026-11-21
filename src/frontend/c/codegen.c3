// Port of the shared state and top-level lowering from src/aro/CodeGen.zig.
// AST node dispatch is implemented in the companion codegen_nodes.c3 file.
module aro::frontend::c::codegen;
import aro::backend::ir, aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::preprocessor;
import aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner, aro::string_interner;
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

struct TodoReportEntry
{
	String kind;
	uint count;
	String first_fn;
}

struct TodoReportHit
{
	String kind;
	String definition;
}

<* Distinct unsupported codegen kinds and the definitions that hit them. *>
struct TodoReport
{
	Allocator allocator;
	List{TodoReportEntry} entries;
	List{TodoReportHit} hits;
	List{String} skipped_definitions;
	uint definitions_total;
}

fn void TodoReport.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.entries.init(allocator);
	self.hits.init(allocator);
	self.skipped_definitions.init(allocator);
}

fn void TodoReport.free(&self)
{
	foreach (entry : self.entries)
	{
		alloc::free(self.allocator, entry.kind.ptr);
		alloc::free(self.allocator, entry.first_fn.ptr);
	}
	foreach (hit : self.hits)
	{
		alloc::free(self.allocator, hit.kind.ptr);
		alloc::free(self.allocator, hit.definition.ptr);
	}
	foreach (definition : self.skipped_definitions) alloc::free(self.allocator, definition.ptr);
	self.entries.free();
	self.hits.free();
	self.skipped_definitions.free();
	*self = {};
}

<* Count a definition once even when it reaches the same unsupported path repeatedly. *>
fn void TodoReport.record(&self, String kind, String definition)
{
	foreach (hit : self.hits)
	{
		if (hit.kind == kind && hit.definition == definition) return;
	}
	self.hits.push(
	{
		.kind = kind.copy(self.allocator), .definition = definition.copy(self.allocator)
	}
	);

	bool first_definition_hit = true;
	foreach (existing : self.skipped_definitions)
	{
		if (existing == definition)
		{
			first_definition_hit = false;
			break;
		}
	}
	if (first_definition_hit) self.skipped_definitions.push(definition.copy(self.allocator));

	foreach (&entry : self.entries)
	{
		if (entry.kind == kind)
		{
			entry.count++;
			return;
		}
	}
	self.entries.push(
		{
			.kind = kind.copy(self.allocator), .count = 1, .first_fn = definition.copy(self.allocator),
	}
	);
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
	<* Flags per node index (`LINKAGE_*` bits), built once by `index_internal_linkage` so
	   `has_internal_linkage` and `is_root_declaration` avoid scanning `root_decls`. *>
	HashMap{uint, char} linkage_flags;
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
	<* Aggregate return storage for the function currently being lowered. *>
	bool aggregate_return;
	AggClass aggregate_return_class;
	ulong aggregate_return_size;
	ir::Ref aggregate_return_slot;
	ir::Ref sret_pointer;
	bool keep_going;
	TodoReport* todo_report;
}

<*
 Report a fatal lowering diagnostic. The text is borrowed for this call; the
 diagnostics sink copies it when it owns the output.
 @return? compilation::FATAL_ERROR
*>
fn void? CodeGen.fail(&self, String text)
{
	if (self.keep_going)
	{
		String kind = text;
		while (kind.ends_with("\n")) kind = kind[:kind.len - 1];
		String definition = self.current_fn.len == 0 ? "<file scope>" : self.current_fn;
		assert(self.todo_report != null, "keep-going CodeGen requires a TODO report");
		self.todo_report.record(kind, definition);
		return compilation::FATAL_ERROR~;
	}
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
fn ir::Ir? gen_ir(tree::Tree* tree, preprocessor::Preprocessor* pp, int tu_id = -1,
	bool keep_going = false, TodoReport* todo_report = null)
{
	compilation::Compilation* comp = tree.comp;
	CodeGen c = { .tree = tree, .comp = comp, .pp = pp, .tu_id = tu_id,
	.keep_going = keep_going, .todo_report = todo_report };
	if (keep_going) assert(todo_report != null, "keep-going CodeGen requires a TODO report");
	c.builder.init(comp.gpa, &comp.interner);
	c.symbols.init(comp.gpa);
	c.emitted_block_statics.init(comp.gpa);
	c.implicit_vars.init(comp.gpa);
	c.emitted_strings.init(comp.gpa);
	c.ret_nodes.init(comp.gpa);
	c.phi_nodes.init(comp.gpa);
	c.record_elem_buf.init(comp.gpa);
	c.record_cache.init(comp.gpa);
	c.linkage_flags.init(comp.gpa);
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
	defer c.linkage_flags.free();
	defer c.builder.free();
	c.index_internal_linkage();

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
				if (keep_going)
				{
					todo_report.definitions_total++;
					if (catch f = c.gen_fn(decl_index, decl.function))
					{
						if (f != compilation::FATAL_ERROR) return f~;
						c.builder.abort_fn();
						continue;
					}
				}
				else
				{
					c.gen_fn(decl_index, decl.function)!;
				}
			case VARIABLE:
				if (keep_going)
				{
					todo_report.definitions_total++;
					if (catch f = c.gen_root_var(decl.variable, decl_index))
					{
						if (f != compilation::FATAL_ERROR) return f~;
						continue;
					}
				}
				else
				{
					c.gen_var(decl.variable, decl_index)!;
				}
			case GLOBAL_ASM:
				if (keep_going)
				{
					todo_report.definitions_total++;
					todo_report.record("TODO global assembly", "<global assembly>");
					continue;
				}
				c.fail("TODO global assembly")!;
				unreachable();
			default:
				unreachable("unexpected top-level node in CodeGen.gen_ir");
		}
	}
	return c.builder.finish();
}

<* Set a useful report name while lowering a file-scope variable. *>
fn void? CodeGen.gen_root_var(&self, tree::NodeVariable variable, type_store::NodeIndex declaration)
{
	String old_current_fn = self.current_fn;
	String source_name = self.tree.tok_slice(variable.name_tok);
	self.current_fn = self.symbol_name(source_name, self.has_internal_linkage(declaration));
	defer self.current_fn = old_current_fn;
	return self.gen_var(variable, declaration);
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
	return (self.linkage_flag(declaration) & LINKAGE_ROOT) != 0;
}

const char LINKAGE_STATIC_FN_ROOT = 1;
const char LINKAGE_STATIC_VAR_ROOT = 2;
const char LINKAGE_STATIC_FN_TARGET = 4;
const char LINKAGE_STATIC_VAR_TARGET = 8;
const char LINKAGE_ROOT = 16;

<* Mark every file-scope node with `LINKAGE_ROOT`, and record, for every static file-scope
   function/variable, the root node itself and the definition it links to. *>
fn void CodeGen.index_internal_linkage(&self)
{
	foreach (root_decl : self.tree.root_decls)
	{
		self.add_linkage_flag(root_decl, LINKAGE_ROOT);
		tree::Node node = root_decl.get(self.tree);
		char root_bit;
		char target_bit;
		type_store::NodeOptIndex definition;
		switch (node.kind)
		{
			case FUNCTION:
				if (!node.function.is_static) continue;
				root_bit = LINKAGE_STATIC_FN_ROOT;
				target_bit = LINKAGE_STATIC_FN_TARGET;
				definition = node.function.definition;
			case VARIABLE:
				if (node.variable.storage_class != tree::VariableStorageClass.STATIC) continue;
				root_bit = LINKAGE_STATIC_VAR_ROOT;
				target_bit = LINKAGE_STATIC_VAR_TARGET;
				definition = node.variable.definition;
			default:
				continue;
		}
		self.add_linkage_flag(root_decl, root_bit);
		if (!definition.is_null()) self.add_linkage_flag(definition.unwrap(), target_bit);
	}
}

fn void CodeGen.add_linkage_flag(&self, type_store::NodeIndex index, char bit)
{
	char flags = self.linkage_flags.get((uint)index) ?? 0;
	self.linkage_flags.set((uint)index, flags | bit);
}

fn char CodeGen.linkage_flag(&self, type_store::NodeIndex index)
{
	return self.linkage_flags.get((uint)index) ?? 0;
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
			return (self.linkage_flag(declaration) & (LINKAGE_STATIC_FN_ROOT | LINKAGE_STATIC_FN_TARGET)) != 0;
		case VARIABLE:
			if (!node.variable.definition.is_null())
			{
				type_store::NodeIndex definition = node.variable.definition.unwrap();
				if (self.linkage_flag(definition) & LINKAGE_STATIC_VAR_ROOT) return true;
			}
			return (self.linkage_flag(declaration) & (LINKAGE_STATIC_VAR_ROOT | LINKAGE_STATIC_VAR_TARGET)) != 0;
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
 Convert a C type to its backend IR type. Struct layouts and opaque union byte
 arrays are interned by unqualified type. Struct bitfields remain a type-
representation TODO for aggregate IR values; their member accesses lower
independently through typed storage units. Blocks, complex/atomic types, VLAs
and nullptr_t are also unsupported.
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
			uint cache_key = (uint)base.qt.unqualified();
			if (try cached = self.record_cache.get(cache_key)) return cached;
			value_interner::InternerRef union_type = self.builder.interner.put(
				{
					.tag = ARRAY_TY,
					.array_ty = { .len = base.qt.sizeof(self.comp), .child = value_interner::REF_I8 }
			}
			);
			self.record_cache.set(cache_key, union_type);
			return union_type;
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
	self.aggregate_return = self.is_record_value(func_type.return_type);
	self.aggregate_return_class = AggClass.IGNORE;
	self.aggregate_return_size = 0;
	self.aggregate_return_slot = ir::NONE;
	self.sret_pointer = ir::NONE;
	if (self.aggregate_return)
	{
		AggClassResult return_class = self.classify_record(func_type.return_type)!;
		// Preserve gen_type's existing diagnostic for records with unsupported
		// bitfield layouts; ordinary aggregates use address-based expression values.
		self.gen_type(func_type.return_type)!;
		self.aggregate_return_class = return_class.kind;
		self.aggregate_return_size = func_type.return_type.sizeof(self.comp);
	}
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
	uint gp_index = 0;
	uint sse_index = 0;
	uint stack_offset = 0;
	if (self.aggregate_return && self.aggregate_return_class == AggClass.MEMORY)
	{
		self.sret_pointer = self.builder.add_arg_at(value_interner::REF_PTR,
			ir::ArgLocationKind.GP_REGISTER, gp_index, 0);
		gp_index++;
	}
	if (self.aggregate_return && self.aggregate_return_class == AggClass.INTEGER)
	{
		uint padded_size = (uint)((self.aggregate_return_size + 7) / 8 * 8);
		self.aggregate_return_slot = self.builder.add_alloc(padded_size, 8);
		self.gen_zero_fill(self.aggregate_return_slot, padded_size)!;
	}
	foreach (param : func_type.params)
	{
		ir::Ref alloc;
		uint size = (uint)param.qt.sizeof(self.comp);
		uint alignment = param.qt.alignof(self.comp);
		bool is_f80 = param.qt.is(self.comp, type_store::TypeTag.FLOAT) && param.qt.bit_sizeof(self.comp) == 80;
		if (is_f80)
		{
			// x87 long double occupies a padded 16-byte object slot, even on
			// targets where its C type alignment is smaller.
			size = 16;
			alignment = 16;
		}
		if (self.is_record_value(param.qt))
		{
			AggClassResult class = self.classify_record(param.qt)!;
			self.gen_type(param.qt)!;
			uint words = class.kind == AggClass.INTEGER ? (uint)class.eightbyte_count : 0;
			uint allocation_size = size;
			if (class.kind == AggClass.INTEGER && words * 8 > allocation_size) allocation_size = words * 8;
			alloc = self.builder.add_alloc(allocation_size, alignment, param.qt.is_volatile);
			if (class.kind == AggClass.INTEGER)
			{
				bool in_registers = gp_index + words <= 6;
				for (uint word = 0; word < words; word++)
				{
					ir::Ref arg;
					if (in_registers)
					{
						arg = self.builder.add_arg_at(value_interner::REF_I64,
							ir::ArgLocationKind.GP_REGISTER, gp_index++, 0);
					}
					else
					{
						arg = self.builder.add_arg_at(value_interner::REF_I64,
							ir::ArgLocationKind.STACK, stack_offset, 8);
						stack_offset += 8;
					}
					self.builder.add_store(self.ptr_at(alloc, (ulong)word * 8), arg);
				}
			}
			else if (class.kind == AggClass.MEMORY)
			{
				uint rounded_size = (uint)((size + 7) / 8 * 8);
				ir::Ref arg = self.builder.add_arg_at(value_interner::REF_PTR,
					ir::ArgLocationKind.STACK, stack_offset, rounded_size, true);
				stack_offset += rounded_size;
				self.gen_copy(alloc, arg, size)!;
			}
		}
		else
		{
			ir::Ref arg;
			if (is_f80)
			{
				// The incoming stack area starts at rbp+16, which is 16-byte
				// aligned. Keep this argument aligned after any preceding spills.
				stack_offset = (stack_offset + 15) / 16 * 16;
				arg = self.builder.add_arg_at(self.gen_type(param.qt)!,
				ir::ArgLocationKind.STACK, stack_offset, 16);
				stack_offset += 16;
			}
			else if (param.qt.is(self.comp, type_store::TypeTag.FLOAT))
			{
				self.ensure_scalar_float_width(param.qt)!;
				if (sse_index < 8)
				{
					arg = self.builder.add_arg_at(self.gen_type(param.qt)!, ir::ArgLocationKind.SSE_REGISTER, sse_index++, 0);
				}
				else
				{
					arg = self.builder.add_arg_at(self.gen_type(param.qt)!, ir::ArgLocationKind.STACK, stack_offset, 8);
					stack_offset += 8;
				}
			}
			else if (gp_index < 6)
			{
				arg = self.builder.add_arg_at(self.gen_type(param.qt)!, ir::ArgLocationKind.GP_REGISTER, gp_index++, 0);
			}
			else
			{
				arg = self.builder.add_arg_at(self.gen_type(param.qt)!, ir::ArgLocationKind.STACK, stack_offset, 8);
				stack_offset += 8;
			}
			alloc = self.builder.add_alloc(size, alignment, param.qt.is_volatile);
			self.builder.add_store(alloc, arg);
		}
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
	if (self.aggregate_return)
	{
		if (!self.builder.block_terminated()) self.builder.add_jump(self.return_label);
		self.builder.start_block(self.return_label);
		if (self.aggregate_return_class == AggClass.INTEGER)
		{
			ir::Ref low = self.builder.add_inst(ir::InstTag.LOAD,
				{ .ref = self.aggregate_return_slot }, value_interner::REF_I64);
			if (self.aggregate_return_size > 8)
			{
				ir::Ref high = self.builder.add_inst(ir::InstTag.LOAD,
					{ .ref = self.ptr_at(self.aggregate_return_slot, 8) }, value_interner::REF_I64);
				self.builder.add_return_pair(low, high);
			}
			else
			{
				self.builder.add_return(low);
			}
		}
		else
		{
			self.builder.add_return(self.aggregate_return_class == AggClass.MEMORY ? self.sret_pointer: ir::NONE);
		}
	}
	else if (self.ret_nodes.len() == 0)
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

<* A short-circuit exit. `value` is the whole condition's truth on this edge;
it is only read when `label` is the enclosing `&&`/`||` exit (`bool_end_label`),
where it becomes the phi input. *>
struct BoolTarget
{
	ir::Ref label;
	bool value;
}

fn BoolTarget true_target(ir::Ref label) => { .label = label, .value = true };
fn BoolTarget false_target(ir::Ref label) => { .label = label, .value = false };

<* Unconditional exit to `target`, recording its truth when it is the phi block. *>
fn void? CodeGen.jump_to(&self, BoolTarget target)
{
	if (target.label == self.bool_end_label) self.add_bool_phi(target.value)!;
	self.builder.add_jump(target.label);
}

<* Branch on the i1 `cond` (logically inverted when `negate`), recording phi
inputs for edges that reach the enclosing `&&`/`||` exit. *>
fn void? CodeGen.branch_to(&self, ir::Ref cond, BoolTarget on_true, BoolTarget on_false, bool negate)
{
	if (negate) @swap(on_true, on_false);
	bool true_ends = on_true.label == self.bool_end_label;
	bool false_ends = on_false.label == self.bool_end_label;
	if (true_ends && false_ends)
	{
		// Both edges merge: the condition itself is the phi input.
		if (on_true.value == on_false.value) return self.add_bool_phi(on_true.value);
		ir::Ref value = cond;
		if (!on_true.value)
		{
			ir::Ref zero = self.builder.add_constant(value::from_bool(false).ref(), value_interner::REF_I1);
			value = self.builder.add_inst(ir::InstTag.CMP_EQ, { .bin = { .lhs = cond, .rhs = zero } }, value_interner::REF_I1);
		}
		self.phi_nodes.push({ .label = self.builder.current_label, .value = value });
		return;
	}
	if (true_ends) self.add_bool_phi(on_true.value)!;
	if (false_ends) self.add_bool_phi(on_false.value)!;
	self.builder.add_branch(cond, on_true.label, on_false.label);
}

<* Plain conditional branch between two labels (no short-circuit phi). *>
fn void? CodeGen.add_branch(&self, ir::Ref cond, ir::Ref true_label, ir::Ref false_label)
{
	return self.branch_to(cond, true_target(true_label), false_target(false_label), false);
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
