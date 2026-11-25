// Port of c3c src/compiler/sema_passes.c (revision 54bab366a): the module
// level analysis passes driven by sema_analyze_stage (semantic_analyser.c3).
//
// Deviations from c3c:
// - `goto` flows (NEXT / FOUND_MODULE / FOUND_ALIAS in the import pass,
//   CHECK_LINK / RELEASE_CONTEXT / FAIL_CONTEXT / RETRY / RETRY_INCLUDES in
//   the conditional-units pass) are restructured with flags, labelled loops
//   and `while (true)` loops with the same flow.
// - c3c's `vec_resize(decls, n)` on a vector passed by value shrinks the
//   owner's vector too. Slices do not share a length, so the static helpers
//   that do this take the owner's slice by reference: `register_global_decls`
//   and `sema_analyse_decls` take `Decl*[]*`.
// - DEBUG_LOG calls are dropped; `sema_interpret_expand` does not build the
//   unused ParseContext.
// - `sema_interpret_expand` formats the file name as "<path>.<row>" (c3c
//   passes an extra, unused `col` argument to the same format).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

<* The bytes of a const string / bytes expression as a String. *>
fn String const_bytes_str(Expr* expr) @inline => (String)expr.const_expr.bytes.ptr[:expr.const_expr.bytes.len];

// sema_passes.c:8
fn void parent_path(StringSlice* slice)
{
	for (int i = (int)slice.len - 1; i > 0; i--)
	{
		if ((*slice)[i] == ':')
		{
			*slice = (*slice)[:i - 1];
			return;
		}
	}
	*slice = (*slice)[:0];
}

// sema_passes.c:22
fn void sema_analyse_pass_module_hierarchy(Module* module_)
{
	String name = module_.name.module_name;

	StringSlice slice = slice_from_string(name);
	// foo::bar::baz -> foo::bar
	parent_path(&slice);
	// foo -> return, no parent
	if (!slice.len) return;

	foreach (checked : compiler.context.module_list)
	{
		ModulePath* checked_name = checked.name;
		if (checked_name.len != slice.len) continue;
		// Found the parent! We're done, we add this parent
		if (checked_name.module_name[:slice.len] == slice)
		{
			module_.parent_module = checked;
			return;
		}
	}
	// No match, so we create a synthetic module parent
	ModulePath* path = path_create_from_string(slice, (uint)slice.len, module_.name.loc);
	Module* parent_module = compiler_find_or_create_module(path);
	module_.parent_module = parent_module;
	sema_analyze_stage(parent_module, MODULE_HIERARCHY);
}

<* Clear every declaration of `unit` (and of its generic sections in `module_`). *>
fn void unit_clear_decls(Module* module_, CompilationUnit* unit) @local
{
	@vec_resize(&unit.global_decls, 0);
	@vec_resize(&unit.global_cond_decls, 0);
	foreach (decl : module_.generic_sections)
	{
		if (decl.unit == unit)
		{
			@vec_resize(&decl.generic_decl.conditional_decls, 0);
			@vec_resize(&decl.generic_decl.decls, 0);
		}
	}
	@vec_resize(&unit.ct_includes, 0);
}

// sema_passes.c:52
fn void sema_analyse_pass_remove_feat_conditionals(Module* module_)
{
	foreach (unit : module_.units)
	{
		if (unit.feat_attributes.len && sema_retain_conditional_feat(unit.feat_attributes) != BOOL_TRUE)
		{
			@vec_resize(&unit.module_aliases, 0);
			@vec_resize(&unit.imports, 0);
			unit_clear_decls(module_, unit);
		}
	}
}

// sema_passes.c:75
fn void sema_analysis_pass_process_imports(Module* module_)
{
	Module* parent = module_;
	while (parent.parent_module) parent = parent.parent_module;
	module_.top_module = parent;

	int total_import_count = 0;
	foreach (unit : module_.units)
	{
		// 1. Loop through each context in the module.

		// 2. Loop through imports
		Decl*[] imports = unit.imports;
		int import_count = (int)imports.len;

		for IMPORTS: (int i = 0; i < import_count; i++)
		{
			// 3. Begin analysis
			Decl* imp = imports[i];
			assert(imp.resolve_status == NOT_DONE);
			imp.resolve_status = RUNNING;
			// 4. Find the module.
			ModulePath* path = imp.import_decl.path;

			for (int j = 0; j < i; j++)
			{
				if (imports[j].import_decl.path.module_name.ptr == path.module_name.ptr)
				{
					@print_error_at(imp.loc, "Module '%s' imported more than once, please remove one.", path.module_name);
					@sema_note_prev_at(imports[j].loc, "The previous one was here.");
					decl_poison(imp);
					continue IMPORTS;
				}
			}

			Module* import_module = global_context_find_module(path.module_name);

			// 5. Do we find it?
			if (!import_module)
			{
				if (!unit.if_attr)
				{
					@print_error_at(imp.loc, "No module named '%s' could be found, did you type the name right?", path.module_name);
					decl_poison(imp);
					continue;
				}
				unit.error_import = imp;
				import_module = compiler_find_or_create_module(path);
			}
			else if (import_module == module_)
			{
				// 6. Importing itself is not allowed.
				@print_error_at(imp.loc, "Importing the current module is not allowed, you need to remove it.");
				decl_poison(imp);
				continue;
			}

			// FOUND_MODULE:
			// 7. Assign the module.
			imp.import_decl.mod = import_module;
		}
		foreach (idx, alias_module : unit.module_aliases)
		{
			ModulePath* path = alias_module.module_alias_decl.alias_path;
			Module* import_module = global_context_find_module(path.module_name);

			// 5. Do we find it?
			if (!import_module)
			{
				if (!unit.if_attr)
				{
					@print_error_at(path.loc, "No module named '%s' could be found, did you type the name right?", path.module_name);
					continue;
				}
				unit.error_import = alias_module;
				import_module = compiler_find_or_create_module(path);
			}
			// FOUND_ALIAS:
			alias_module.module_alias_decl.mod = import_module;
			alias_module.resolve_status = DONE;
			for (int i = 0; i < idx; i++)
			{
				if (unit.module_aliases[i].name.ptr == alias_module.name.ptr)
				{
					@print_error_at(alias_module.loc, "The module alias must be unique.");
					break;
				}
			}
			if (alias_module.attributes.len)
			{
				@print_error_at(alias_module.attributes[0].loc, "Module aliases cannot have attributes.");
				break;
			}
		}
		total_import_count += import_count;
	}
}

// sema_passes.c:185 (static)
fn bool sema_check_if_implicit_generic(SemaContext* context, Decl* decl)
{
	if (!decl.func_decl.type_parent) return false;
	TypeInfo* typedecl = decl_find_method_target(decl);
	if (typedecl.resolve_status == DONE)
	{
		CanonicalType* type = typedecl.type.canonical;
		return type_is_user_defined(type) && type.decl.is_template;
	}
	if (typedecl.kind == INFO_IDENTIFIER && typedecl.subtype == TYPE_COMPRESSED_NONE)
	{
		Decl* d = sema_resolve_maybe_parameterized_symbol(context, typedecl.unresolved.name, typedecl.unresolved.path, typedecl.loc);
		return d && d.is_template;
	}
	return false;
}

// sema_passes.c:202
fn void unit_register_optional_global_decl(CompilationUnit* unit, Decl* decl)
{
	SemaContext context;
	sema_context_init(&context, unit);
	if (decl.is_templated) context.generic_instance = declptr(decl.instance_id);
	if (!decl.is_templated && decl_is_fn_macro(decl))
	{
		if (sema_check_if_implicit_generic(&context, decl))
		{
			unit_register_global_decl(unit, decl);
			sema_context_destroy(&context);
			return;
		}
	}
	if (sema_decl_if_cond(&context, decl))
	{
		unit_register_global_decl(unit, decl);
	}
	else
	{
		decl.decl_kind = ERASED;
	}
	sema_context_destroy(&context);
}

// sema_passes.c:227 (static)
<* Takes the owner's slice by reference (c3c's vec_resize shrinks the shared vector). *>
fn void register_global_decls(CompilationUnit* unit, Decl*[]* decls)
{
	foreach (decl : *decls)
	{
		unit_register_global_decl(unit, decl);
	}
	@vec_resize(decls, 0);
}

// sema_passes.c:236 (static)
fn SourceFile* sema_load_file(CompilationUnit* unit, Expr* filename)
{
	if (!expr_is_const_string(filename))
	{
		@print_error_at(filename.loc, "A compile time string was expected.");
		return null;
	}
	String string = const_bytes_str(filename);
	bool loaded;
	String error;
	String path;
	String name;
	if (file_namesplit(unit.file.full_path, &name, &path))
	{
		string = file_append_path(path, string);
	}
	SourceFile* file = source_file_load(string, &loaded, &error);
	if (!file)
	{
		@print_error_at(filename.loc, "Failed to load file '%s': %s.", const_bytes_str(filename), error);
		return null;
	}
	if (compiler.context.errors_found) return null;
	return file;
}

// sema_passes.c:261 (static)
fn Decl*[] sema_load_include(CompilationUnit* unit, Decl* decl)
{
	if (compiler.build.trust_level < TrustLevel.INCLUDE)
	{
		@print_error_at(decl.loc, "'$include' not permitted, trust level must be set to '--trust=include' or '--trust=full' to permit it.");
		return {};
	}
	foreach (attr : decl.attributes)
	{
		if (attr.attr_kind != IF && attr.attr_kind != FEAT)
		{
			@print_error_at(attr.loc, "Invalid attribute for '$include'.");
			return {};
		}
	}
	SemaContext context;
	sema_context_init(&context, unit);
	bool success = sema_analyse_ct_expr(&context, decl.include.filename);
	sema_context_destroy(&context);
	if (!success) return {};
	SourceFile* file = sema_load_file(unit, decl.include.filename);
	if (!file) return {};
	if (compiler.context.includes_used++ > MAX_INCLUDE_DIRECTIVES)
	{
		@print_error_at(decl.loc, "This $include would cause the maximum number of includes (%d) to be exceeded.", MAX_INCLUDE_DIRECTIVES);
		return {};
	}
	return parse_include_file(file, unit);
}

// sema_passes.c:288 (static)
fn bool exec_arg_append_to_scratch(Expr* arg)
{
	assert(expr_is_const(arg));
	switch (arg.const_expr.const_kind)
	{
		case FLOAT:
			scratch_buffer_append_double(arg.const_expr.fxx.f);
			return true;
		case INTEGER:
			scratch_buffer_append(int_to_str(arg.const_expr.ixx, 10, false));
			return true;
		case BOOL:
			scratch_buffer_append(arg.const_expr.b ? "true" : "false");
			return true;
		case REF:
			scratch_buffer_append(arg.const_expr.global_ref.name);
			return true;
		case FAULT:
			scratch_buffer_append(arg.const_expr.fault_val ? arg.const_expr.fault_val.name : "null");
			return true;
		case ENUM:
			scratch_buffer_append(arg.const_expr.enum_val.name);
			return true;
		case TYPEID:
			if (!arg.const_expr.typeid_type.name.ptr)
			{
				@print_error_at(arg.loc, "The type '%s' has no trivial name.",
				                type_quoted_error_string(arg.const_expr.typeid_type));
				return false;
			}
			scratch_buffer_append(arg.const_expr.typeid_type.name);
			return true;
		case STRING:
			scratch_buffer_append(const_bytes_str(arg));
			return true;
		case POINTER:
			scratch_buffer_append_unsigned_int(arg.const_expr.ptr);
			return true;
		case BYTES:
		case INITIALIZER:
		case SLICE:
		case UNTYPED_LIST:
		case MEMBER:
		case REFLECTION:
			return false;
	}
	unreachable();
}

// sema_passes.c:336 (static)
fn Decl*[] sema_run_exec(CompilationUnit* unit, Decl* decl)
{
	double bench = bench_mark();
	if (compiler.build.trust_level < TrustLevel.FULL)
	{
		@print_error_at(decl.loc, "'$exec' not permitted, trust level must be set to '--trust=full' to permit it.");
		return {};
	}
	foreach (attr : decl.attributes)
	{
		if (attr.attr_kind != IF && attr.attr_kind != FEAT)
		{
			@print_error_at(attr.loc, "Invalid attribute for '$exec'.");
			return {};
		}
	}
	SemaContext context;
	sema_context_init(&context, unit);
	Expr* filename = decl.exec_decl.filename;
	bool success = sema_analyse_ct_expr(&context, filename);
	foreach (arg : decl.exec_decl.args) success &= sema_analyse_ct_expr(&context, arg);
	Expr* stdin_expr = decl.exec_decl.stdin_string;
	if (stdin_expr) success &= sema_analyse_ct_expr(&context, stdin_expr);
	sema_context_destroy(&context);
	if (!success) return {};
	if (!expr_is_const_string(filename))
	{
		@print_error_at(filename.loc, "A filename was expected as the first argument to '$exec'.");
		return {};
	}
	String stdin_string = {};
	if (stdin_expr)
	{
		if (!expr_is_const_string(stdin_expr))
		{
			@print_error_at(stdin_expr.loc, "Expected the stdin parameter to be a compile time string.");
			return {};
		}
		stdin_string = const_bytes_str(stdin_expr);
	}
	scratch_buffer_clear();
	String file_str = const_bytes_str(filename);
	bool c3_script = str_has_suffix(file_str, ".c3");
	String old_dir;
	String script_dir;
	String exec_dir;

	setup_exec_paths(&old_dir, &script_dir, &exec_dir);
	if (!c3_script)
	{
		scratch_buffer_append(file_str);
		scratch_buffer_append(" ");
	}
	foreach (i, arg : decl.exec_decl.args)
	{
		if (i) scratch_buffer_append(" ");
		assert(expr_is_const(arg));
		if (!exec_arg_append_to_scratch(arg))
		{
			@print_error_at(arg.loc, "Bytes, initializers and member references may not be used as arguments.");
			return {};
		}
	}
	SourceFile* file;
	if (c3_script)
	{
		String args = scratch_buffer_copy();
		if (!str_eq(script_dir, exec_dir))
		{
			scratch_buffer_clear();
			scratch_buffer_append(script_dir);
			scratch_buffer_append("/");
			scratch_buffer_append(file_str);
			file_str = scratch_buffer_copy();
		}
		dir_change(exec_dir);
		file = compile_and_invoke(file_str, args, stdin_string, 0);
	}
	else
	{
		dir_change(exec_dir);
		String output = execute_cmd(scratch_buffer_str(), false, stdin_string, 0);
		file = source_file_text_load(scratch_buffer_str(), output);
	}
	success = dir_change(old_dir);
	if (!success)
	{
		@print_error_at(decl.loc, "Failed to return to the original directory after changing to exec dir '%s'", compiler.build.exec_dir);
		return {};
	}
	if (compiler.context.includes_used++ > MAX_INCLUDE_DIRECTIVES)
	{
		@print_error_at(decl.loc, "This $include would cause the maximum number of includes (%d) to be exceeded.", MAX_INCLUDE_DIRECTIVES);
		return {};
	}
	compiler.exec_time += bench_mark() - bench;
	return parse_include_file(file, unit);
}

// sema_passes.c:426 (static)
fn Decl*[] sema_interpret_expand(CompilationUnit* unit, Decl* decl)
{
	foreach (attr : decl.attributes)
	{
		if (attr.attr_kind != IF && attr.attr_kind != FEAT)
		{
			@print_error_at(attr.loc, "Invalid attribute for '$expand'.");
			return {};
		}
	}
	SemaContext context;
	sema_context_init(&context, unit);
	Expr* string = decl.expand_decl;
	bool success = sema_analyse_ct_expr(&context, string);
	sema_context_destroy(&context);
	if (!success) return {};
	if (!expr_is_const_string(string))
	{
		@print_error_at(string.loc, "Expected a constant string for '$expand'.");
		return {};
	}
	scratch_buffer_clear();
	SourceLoc* loc = sourcelocptr(string.loc);
	@scratch_buffer_printf("%s.%d", unit.file.full_path, loc.row);
	SourceFile* file = source_file_text_load(scratch_buffer_str(), str_copy(const_bytes_str(string)));
	return parse_include_file(file, unit);
}

// sema_passes.c:455 (static)
fn void register_includes(CompilationUnit* unit, Decl*[] decls)
{
	foreach (include : decls)
	{
		Decl*[] include_decls;
		switch (include.decl_kind)
		{
			case CT_EXEC:
				include_decls = sema_run_exec(unit, include);
			case CT_INCLUDE:
				include_decls = sema_load_include(unit, include);
			case CT_EXPAND:
				include_decls = sema_interpret_expand(unit, include);
			default:
				unreachable();
		}
		foreach (decl : include_decls)
		{
			if (decl.is_cond)
			{
				@vec_add(&unit.global_cond_decls, decl);
			}
			else
			{
				unit_register_global_decl(unit, decl);
			}
		}
	}
}

// sema_passes.c:488
fn void sema_process_includes(CompilationUnit* unit)
{
	while (true)
	{
		Decl*[] includes = unit.ct_includes;
		if (!includes.ptr) break;
		unit.ct_includes = {};
		register_includes(unit, includes);
	}
}

// sema_passes.c:500
fn void sema_analysis_pass_register_global_declarations(Module* module_)
{
	foreach (unit : module_.units)
	{
		if (unit.if_attr) continue;
		assert(!unit.ct_includes.len);
		unit.mod = module_;
		register_global_decls(unit, &unit.global_decls);
	}
}

// sema_passes.c:514
fn void sema_analysis_pass_process_includes(Module* module_)
{
	foreach (unit : module_.units)
	{
		// Process all includes
		sema_process_includes(unit);
		assert(unit.ct_includes.len == 0);
	}
}

// sema_passes.c:528
fn void sema_analysis_pass_process_methods(Module* module_)
{
	foreach (unit : module_.units)
	{
		SemaContext context;
		sema_context_init(&context, unit);
		usz size_before = unit.methods_to_register.len;
		foreach (method : unit.methods_to_register)
		{
			TypeInfo* parent_type_info = decl_find_method_target(method);
			if (sema_unresolved_type_is_generic(&context, parent_type_info))
			{
				@vec_add(&compiler.context.unregistered_method_specializations, method);
				continue;
			}
			if (sema_analyse_method_register(&context, method))
			{
				if (method.decl_kind == MACRO)
				{
					@vec_add(&unit.macro_methods, method);
				}
				else
				{
					@vec_add(&unit.methods, method);
				}
			}
		}
		sema_context_destroy(&context);
		assert(size_before == unit.methods_to_register.len);
		@vec_resize(&unit.methods_to_register, 0);
	}
}

// sema_passes.c:569
<*
 A specialization is a generic method like:
 fn int Foo{int}.bar(&self) { ... }
 That is, the method parent is a generic instantiation.
*>
fn void sema_analysis_pass_process_method_specialization()
{
	SemaContext context;
	CompilationUnit* unit = null;
	foreach (method : compiler.context.unregistered_method_specializations)
	{
		CompilationUnit* method_unit = method.unit;
		if (method_unit != unit)
		{
			if (unit) sema_context_destroy(&context);
			unit = method_unit;
			sema_context_init(&context, unit);
		}
		if (sema_analyse_method_register(&context, method))
		{
			if (method.decl_kind == MACRO)
			{
				@vec_add(&unit.macro_methods, method);
			}
			else
			{
				@vec_add(&unit.methods, method);
			}
		}
	}
	if (unit) sema_context_destroy(&context);
	@vec_resize(&compiler.context.unregistered_method_specializations, 0);
}

// sema_passes.c:603
<* Late generic declarations are processed here. *>
fn void sema_analysis_pass_process_late_generics()
{
	SemaContext context;
	CompilationUnit* unit = null;
	Decl*[] late_generics;
	while ((late_generics = compiler.context.unregistered_generic_decls).ptr != null)
	{
		compiler.context.unregistered_generic_decls = {};
		foreach (generic : late_generics)
		{
			if (generic.resolve_status == DONE) continue;
			CompilationUnit* generic_unit = generic.unit;
			if (generic_unit != unit)
			{
				if (unit) sema_context_destroy(&context);
				unit = generic_unit;
				sema_context_init(&context, unit);
			}
			sema_analyse_decl(&context, generic);
		}
	}
	if (unit) sema_context_destroy(&context);
}

// sema_passes.c:629
fn void sema_analysis_pass_register_conditional_units_and_decls(Module* module_)
{
	foreach (unit : module_.units)
	{
		// All ct_includes should already be registered.
		assert(!unit.ct_includes.len);

		Attr* if_attr = unit.if_attr;
		if (!if_attr && !unit.attr_links.len) continue;

		SemaContext context;
		sema_context_init(&context, unit);
		if (if_attr)
		{
			@sema_deprecated(if_attr.loc, "Top declaration '@if' is deprecated, please use '@feat' instead.");
			if (if_attr.exprs.len != 1)
			{
				@print_error_at(if_attr.loc, "Expected one parameter.");
				// FAIL_CONTEXT
				sema_context_destroy(&context);
				break;
			}
			Expr* expr = if_attr.exprs[0];
			if (!sema_analyse_ct_expr(&context, expr))
			{
				sema_context_destroy(&context);
				break;
			}
			if (!sema_cast_const(expr) || expr.type.canonical != type_bool)
			{
				@print_error_at(expr.loc, "Expected a constant boolean expression.");
				sema_context_destroy(&context);
				break;
			}
			if (!expr.const_expr.b)
			{
				unit_clear_decls(module_, unit);
				sema_context_destroy(&context);
				continue;
			}
		}
		// CHECK_LINK:
		bool fail_context = false;
		foreach LINKS: (attr : unit.attr_links)
		{
			Expr*[] exprs = attr.exprs;
			int args = (int)exprs.len;
			assert(args > 0, "Should already have been checked.");
			Expr* cond = args > 1 ? attr.exprs[0] : null;
			if (cond && !sema_analyse_expr_rvalue(&context, cond))
			{
				fail_context = true;
				break;
			}
			bool start = cond && expr_is_const_bool(cond) ? true : false;
			bool add = !start ? true : cond.const_expr.b;
			for (int i = (int)start; i < args; i++)
			{
				Expr* string = attr.exprs[i];
				if (!sema_analyse_expr_rvalue(&context, string))
				{
					fail_context = true;
					break LINKS;
				}
				if (!expr_is_const_string(string))
				{
					@print_error_at(string.loc, "Expected a constant string here, usage is: "
					                            "'@link([cond1, ]link1, link2, ...)'.");
					fail_context = true;
					break LINKS;
				}
				if (add)
				{
					@vec_add(&unit.links, const_bytes_str(string));
				}
			}
		}
		if (fail_context)
		{
			// FAIL_CONTEXT:
			sema_context_destroy(&context);
			break;
		}
		// RELEASE_CONTEXT:
		sema_context_destroy(&context);
		if (unit.error_import)
		{
			Decl* imp = unit.error_import;
			switch (imp.decl_kind)
			{
				case IMPORT:
					@print_error_at(imp.loc, "No module named '%s' could be found, did you type the name right?", imp.import_decl.path.module_name);
					continue;
				case ALIAS_PATH:
					@print_error_at(imp.module_alias_decl.alias_path.loc, "No module named '%s' could be found, did you type the name right?", imp.module_alias_decl.alias_path.module_name);
					continue;
				default:
					unreachable();
			}
		}
		register_global_decls(unit, &unit.global_decls);
		// There may be includes, add those.
		sema_process_includes(unit);
	}
	foreach (unit : module_.units)
	{
		unit.mod = module_;
		while (true)
		{
			// RETRY:
			Decl*[] decls = unit.global_cond_decls;
			foreach (decl : decls)
			{
				unit_register_optional_global_decl(unit, decl);
			}
			@vec_resize(&unit.global_cond_decls, 0);
			// RETRY_INCLUDES:
			do
			{
				decls = unit.ct_includes;
				unit.ct_includes = {};
				register_includes(unit, decls);
			}
			while (unit.ct_includes.ptr != null);

			// We might have gotten more declarations.
			if (unit.global_cond_decls.len > 0) continue;
			break;
		}
	}
}

// sema_passes.c:748
fn void sema_analysis_pass_ct_assert(Module* module_)
{
	foreach (unit : module_.units)
	{
		SemaContext context;
		sema_context_init(&context, unit);
		bool success = true;
		foreach (ct_assert : context.unit.ct_asserts)
		{
			if (!sema_analyse_ct_assert_stmt(&context, ct_assert.ct_assert_decl))
			{
				success = false;
				break;
			}
		}
		sema_context_destroy(&context);
		if (!success) break;
	}
}

// sema_passes.c:770
fn void sema_analysis_pass_ct_echo(Module* module_)
{
	foreach (unit : module_.units)
	{
		SemaContext context;
		sema_context_init(&context, unit);
		bool success = true;
		foreach (echo : context.unit.ct_echos)
		{
			if (!sema_analyse_ct_echo_stmt(&context, echo.ct_echo_decl))
			{
				success = false;
				break;
			}
		}
		sema_context_destroy(&context);
		if (!success) break;
	}
}

// sema_passes.c:792
fn bool analyse_func_body(SemaContext* context, Decl* decl)
{
	if (!decl.func_decl.body) return true;
	if (decl.is_extern)
	{
		@sema_error_at(context, decl.loc, "'extern' functions should never have a body.");
		return decl_poison(decl);
	}

	// Don't analyse functions that are tests / benchmarks if not included
	if (decl_skip_benchtest_function(decl)) return true;

	if (!compiler.build.collect_stats)
	{
		if (!sema_analyse_function_body(context, decl, 0)) return decl_poison(decl);
		return true;
	}
	// Bodies of new generic instances are analysed while analysing the body that uses them,
	// so subtract the time spent in nested bodies to get the time for this body alone.
	double outer_nested_time = compiler.stats.nested_analysis_time;
	compiler.stats.nested_analysis_time = 0;
	// Analysing a generic function body is part of the generic instantiation time.
	bool is_generic = decl.is_templated && !compiler.stats.generic_depth;
	if (is_generic) compiler.stats.generic_depth++;
	BenchTime start = benchstart();
	bool success = sema_analyse_function_body(context, decl, 0);
	double elapsed = benchmark(start);
	if (is_generic)
	{
		compiler.stats.generic_depth--;
		compiler.stats.generic_time += elapsed;
	}
	if (compiler.build.collect_stats_lists)
	{
		@vec_add(&compiler.stats.function_analysis_times, (FunctionAnalysisTime) { .decl = decl, .time = elapsed - compiler.stats.nested_analysis_time });
	}
	compiler.stats.nested_analysis_time = outer_nested_time + elapsed;
	if (!success) return decl_poison(decl);
	return true;
}

// sema_passes.c:833
fn void sema_analyse_inner_func_ptr(SemaContext* c, Decl* decl)
{
	Type* inner;
	switch (decl.decl_kind)
	{
		case TYPEDEF:
			inner = decl.distinct.type;
		case TYPE_ALIAS:
			inner = decl.type.canonical;
		default:
			return;
	}
	if (inner.type_kind != FUNC_PTR) return;
	Type* func = inner.pointer;
	assert(func.type_kind == FUNC_RAW);
	if (!sema_resolve_type_decl(c, func)) decl_poison(decl);
}

// sema_passes.c:853 (static)
fn void sema_analyse_weak_decls(SemaContext* context, Decl*[] decls)
{
	foreach (decl : decls)
	{
		assert(decl.resolve_status == NOT_DONE);
		Decl* replacement = decl.replacement;
		while (replacement && replacement.replacement) replacement = replacement.replacement;
		if (!replacement || !decl_ok(replacement)) continue;
		// If the replacement is not in an interface or not weak
		// then everything is fine, otherwise we get ambiguous resolution
		if (replacement.is_weak && !replacement.unit.is_interface_file)
		{
			@sema_error_at(context, replacement.loc, "The symbol '%s' matches multiple @weak declarations. Remove @weak from one of them to disambiguate.", replacement.name);
			@sema_note_prev_at(decl.loc, "The other declaration was here.");
			return;
		}
		if (!sema_analyse_decl(context, decl)) continue;
		decl.replacement = null;
		sema_compare_weak_decl(context, decl, replacement);
		decl.decl_kind = ERASED;
	}
}

// sema_passes.c:876 (static)
<* Takes the owner's slice by reference (c3c's vec_resize shrinks the shared vector). *>
fn void sema_analyse_decls(SemaContext* context, Decl*[]* decls)
{
	int count = (int)decls.len;
	for (int i = 0; i < count; i++)
	{
		Decl* decl = (*decls)[i];
		if (decl.replacement)
		{
			count--;
			(*decls)[i] = (*decls)[count];
			@vec_resize(decls, (usz)count);
			i--;
			continue;
		}
		sema_analyse_decl(context, decl);
	}
}

// sema_passes.c:894
fn void sema_analysis_pass_decls(Module* module_)
{
	foreach (unit : module_.units)
	{
		SemaContext context;
		sema_context_init(&context, unit);
		context.active_scope = {
					.depth = 0,
					.label_start = 0,
					.current_local = 0, };
		sema_analyse_decls(&context, &unit.attributes);
		sema_analyse_decls(&context, &unit.enums);
		foreach (decl : unit.types)
		{
			if (decl.replacement) continue;
			sema_analyse_decl(&context, decl);
			sema_analyse_inner_func_ptr(&context, decl);
		}
		sema_analyse_decls(&context, &unit.macros);
		sema_analyse_decls(&context, &unit.methods);
		sema_analyse_decls(&context, &unit.macro_methods);
		sema_analyse_decls(&context, &unit.vars);
		sema_analyse_decls(&context, &unit.functions);
		if (unit.main_function && unit.main_function.is_synthetic)
		{
			sema_analyse_decl(&context, unit.main_function);
		}
		sema_analyse_decls(&context, &unit.aliases);
		foreach (info : unit.check_type_variable_array)
		{
			sema_check_type_variable_array(&context, info);
		}
		sema_context_destroy(&context);
	}
}

// sema_passes.c:933
fn void sema_analysis_pass_lambda(Module* module_)
{
	while (module_.lambdas_to_evaluate.len)
	{
		Decl* lambda = @veclast(module_.lambdas_to_evaluate);
		CompilationUnit* unit = lambda.unit;
		SemaContext context;
		sema_context_init(&context, unit);
		@vec_pop(&module_.lambdas_to_evaluate);
		if (analyse_func_body(&context, lambda))
		{
			@vec_add(&unit.lambdas, lambda);
		}
		sema_context_destroy(&context);
	}
}

// sema_passes.c:954 (static)
fn bool sema_check_interface(SemaContext* context, Decl* decl, TypeInfo* interface_type, TypeInfo* original_type)
{
	Decl* interface_ = interface_type.type.decl;
	foreach (method : interface_.interface_methods)
	{
		Decl* matching_method = sema_decl_stack_resolve_symbol(method.name);
		if (!matching_method)
		{
			if (method.func_decl.attr_optional) continue;
			if (interface_type != original_type)
			{
				return @sema_error_at(context, original_type.loc,
				                      "'%s' was not fully implemented, the required method '%s' of interface '%s' needs to be implemented, did you forget it?",
				                      original_type.type.decl.name, method.name, interface_.name);
			}
			return @sema_error_at(context, original_type.loc,
			                      "'%s' was not fully implemented, the required method '%s' needs to be implemented, did you forget it?",
			                      interface_.name, method.name);
		}
		if (matching_method.decl_kind != FUNC)
		{
			if (method.func_decl.attr_optional) continue;
			return @sema_error_at(context, matching_method.loc, "'%s' was not fully implemented, it requires '%s' to be a function marked '@dynamic'.",
			                      interface_.name, method.name);
		}
		if (!matching_method.func_decl.attr_dynamic)
		{
			@sema_error_at(context, matching_method.loc, "'%s(...)' must be marked '@dynamic' as it matches the method '%s' in interface '%s'.",
			               method.name, method.name, interface_.name);
			@sema_note_prev_at(method.loc, "Here is the interface method to implement.");
			return false;
		}
	}
	foreach (parent_interface : interface_.interfaces)
	{
		if (!sema_check_interface(context, decl, parent_interface, original_type)) return false;
	}
	return true;
}

// sema_passes.c:993
fn bool sema_check_interfaces(SemaContext* context, Decl* decl)
{
	Decl** store = sema_decl_stack_store();
	sema_add_methods_to_decl_stack(context, decl);
	foreach (interface_type : decl.interfaces)
	{
		if (!sema_check_interface(context, decl, interface_type, interface_type))
		{
			sema_decl_stack_restore(store);
			return false;
		}
	}
	sema_decl_stack_restore(store);
	return true;
}

// sema_passes.c:1009
fn void sema_analysis_pass_interface_and_weak_sym(Module* module_)
{
	foreach (unit : module_.units)
	{
		SemaContext context;
		sema_context_init(&context, unit);
		foreach (decl : unit.types)
		{
			switch (decl.decl_kind)
			{
				case TYPEDEF:
				case STRUCT:
				case UNION:
				case ENUM:
				case BITSTRUCT:
					break;
				default:
					continue;
			}
			if (decl.interfaces.len)
			{
				sema_check_interfaces(&context, decl);
			}
		}
		sema_analyse_weak_decls(&context, unit.weak_symbols_skipped);
		@vec_resize(&unit.weak_symbols_skipped, 0);
		sema_context_destroy(&context);
	}
}

// sema_passes.c:1043
fn void sema_analysis_pass_functions(Module* module_)
{
	foreach (unit : module_.units)
	{
		SemaContext context;
		sema_context_init(&context, unit);
		foreach (method : unit.methods)
		{
			analyse_func_body(&context, method);
		}
		foreach (func : unit.functions)
		{
			analyse_func_body(&context, func);
		}
		if (unit.main_function && unit.main_function.is_synthetic) analyse_func_body(&context, unit.main_function);
		sema_context_destroy(&context);
	}
}
