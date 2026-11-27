// Port of c3c src/compiler/semantic_analyser.c (revision 54bab366a): scope
// and defer helpers, the analysis driver, panic / test / benchmark runner
// setup and inline-span notes.
//
// Deviations from c3c:
// - `sema_print_inline` spells the ternary note text as two format-checked
//   @sema_note_prev_at calls.
// - DEBUG_LOG calls are dropped.
// `sema_error_at` / `sema_warn_at` are the @sema_error_at / @sema_warn_at
// macros in diagnostics_inline.c3 (format-checked); no stubs here.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens, std::io;

<* c3c `swizzle` (used by sema_expr.c's swizzle checks): 1-based component index, 0x10 marks rgba. *>
char[256] swizzle = { ['x'] = 0x01, ['y'] = 0x02, ['z'] = 0x03, ['w'] = 0x04,
                      ['r'] = 0x11, ['g'] = 0x12, ['b'] = 0x13, ['a'] = 0x14 };

// semantic_analyser.c:11
fn void context_change_scope_with_flags(SemaContext* context, ScopeFlags flags, SourceLocId loc)
{
	int depth = context.active_scope.depth + 1;
	if (depth > MAX_SCOPE_DEPTH)
	{
		@sema_error_at(context, loc, "Resolution failed due to too deeply nested scopes (%d).", depth);
		exit_compiler(COMPILER_SUCCESS_EXIT);
	}

	bool scope_is_dead = context.active_scope.is_dead;
	bool scope_is_poisoned = context.active_scope.is_poisoned;
	Ast* previous_defer = context.active_scope.in_defer;
	AstId parent_defer = context.active_scope.defer_last;
	int last_local = context.active_scope.current_local;
	// Defer and expression blocks introduce their own return/break/continue
	// otherwise just merge with the old flags.
	if (flags & SCOPE_MACRO)
	{
		previous_defer = null;
		parent_defer = 0;
	}
	bool new_label_scope = (flags & SCOPE_MACRO) != 0;
	bool is_macro = (flags & SCOPE_MACRO) != 0;
	flags = context.active_scope.flags | flags;
	if (is_macro) flags &= ~(SCOPE_ENSURE | SCOPE_ENSURE_MACRO);

	int label_start = new_label_scope ? last_local : context.active_scope.label_start;
	DynamicScope new_scope = {
		.allow_dead_code = false,
		.is_dead = scope_is_dead,
		.is_poisoned = scope_is_poisoned,
		.depth = depth,
		.current_local = last_local,
		.label_start = label_start,
		.in_defer = previous_defer,
		.defer_last = parent_defer,
		.defer_start = parent_defer,
		.flags = flags,
	};
	context.active_scope = new_scope;
}

// semantic_analyser.c:53
fn String context_filename(SemaContext* context)
{
	CompilationUnit* unit = context.unit;
	if (!unit) return "<unknown unit>";
	SourceFile* file = unit.file;
	if (!file || !file.full_path.ptr) return "<unknown file>";
	return file.full_path;
}

// semantic_analyser.c:62
fn void context_change_scope_for_label(SemaContext* context, DeclId label_id, SourceLocId loc)
{
	context_change_scope_with_flags(context, SCOPE_NONE, loc);

	if (label_id)
	{
		Decl* label = declptr(label_id);
		label.label.defer_id = context.active_scope.defer_last;
		sema_add_local(context, label);
		label.label.scope_defer = context.active_scope.in_defer ? astid(context.active_scope.in_defer) : 0;
	}
}

// semantic_analyser.c:76
fn AstId context_get_defers(SemaContext* context, AstId defer_bottom, bool is_success)
{
	AstId defer_top = context.active_scope.defer_last;
	AstId first = 0;
	AstId* next = &first;
	while (defer_bottom != defer_top)
	{
		Ast* defer_ = astptr(defer_top);
		if ((is_success && defer_.defer_stmt.is_catch) || (!is_success && defer_.defer_stmt.is_try))
		{
			defer_top = defer_.defer_stmt.prev_defer;
			continue;
		}
		Ast* defer_body = copy_ast_defer(astptr(defer_.defer_stmt.body));
		*next = astid(defer_body);
		next = &defer_body.next;
		defer_top = defer_.defer_stmt.prev_defer;
	}
	return first;
}

// semantic_analyser.c:97
fn void context_pop_defers(SemaContext* context, AstId* next)
{
	AstId defer_start = context.active_scope.defer_start;
	if (next && !context.active_scope.end_jump.active)
	{
		AstId defer_current = context.active_scope.defer_last;
		while (defer_current != defer_start)
		{
			Ast* defer_ = astptr(defer_current);
			if (!defer_.defer_stmt.is_catch)
			{
				Ast* defer_body = copy_ast_defer(astptr(defer_.defer_stmt.body));
				*next = astid(defer_body);
				next = &defer_body.next;
			}
			defer_current = defer_.defer_stmt.prev_defer;
		}
	}
	context.active_scope.defer_last = defer_start;
}

// semantic_analyser.c:118
fn void sema_add_methods_to_decl_stack(SemaContext* context, Decl* decl)
{
	if (!decl.method_table) return;
	foreach (func : decl.method_table.methods)
	{
		switch (func.visibility)
		{
			case LOCAL:
				if (context.unit != func.unit) continue;
			case PRIVATE:
				if (context.unit.mod != func.unit.mod) continue;
			default:
				break;
		}
		sema_decl_stack_push(func);
	}
}

// semantic_analyser.c:140
fn void context_pop_defers_and_replace_ast(SemaContext* context, Ast* ast)
{
	AstId defer_first = 0;
	context_pop_defers(context, &defer_first);
	if (!defer_first) return;
	assert(ast.ast_kind != COMPOUND_STMT);
	Ast* replacement = ast_copy(ast);
	ast.ast_kind = COMPOUND_STMT;
	ast.compound_stmt = { .first_stmt = astid(replacement), .parent_defer = 0 };
	replacement.next = defer_first;
}

// semantic_analyser.c:152 (static), ported
fn void halt_on_error() @inline
{
	if (compiler.context.errors_found > 0)
	{
		if (compiler.build.lsp_output)
		{
			io::eprint("> ENDLSP-ERROR\n");
			exit_compiler(COMPILER_SUCCESS_EXIT);
		}
		exit_compiler(EXIT_FAILURE);
	}
}

// semantic_analyser.c:165 ported
fn void sema_analyze_stage(Module* module_, AnalysisStage stage)
{
	while (module_.stage < stage)
	{
		compiler.context.decl_stack_bottom = compiler.context.decl_stack_top = &compiler.context.decl_stack;
		module_.stage = AnalysisStage::values[module_.stage.ordinal + 1];
		switch (module_.stage)
		{
			case NOT_BEGUN:
				unreachable();
			case MODULE_HIERARCHY:
				sema_analyse_pass_module_hierarchy(module_);
			case REMOVE_FEATURE_CONDITIONALS:
				sema_analyse_pass_remove_feat_conditionals(module_);
			case IMPORTS:
				sema_analysis_pass_process_imports(module_);
			case REGISTER_GLOBAL_DECLARATIONS:
				sema_analysis_pass_register_global_declarations(module_);
			case INCLUDES:
				sema_analysis_pass_process_includes(module_);
			case REGISTER_CONDITIONAL_DECLARATIONS:
				sema_analysis_pass_register_conditional_units_and_decls(module_);
			case METHODS_REGISTER:
				sema_analysis_pass_process_methods(module_);
			case METHODS_REGISTER_GENERIC_SPECIALIZATION:
				if (!compiler.context.unregistered_method_specializations.len) break;
				sema_analysis_pass_process_method_specialization();
			case POST_REGISTER:
				break;
			case DECLS:
				sema_analysis_pass_decls(module_);
			case DECLS_CHECK_GENERICS:
				if (!compiler.context.unregistered_generic_decls.len) break;
				sema_analysis_pass_process_late_generics();
			case CT_ECHO:
				sema_analysis_pass_ct_echo(module_);
			case CT_ASSERT:
				sema_analysis_pass_ct_assert(module_);
			case FUNCTIONS:
				sema_analysis_pass_functions(module_);
			case INTERFACE:
				sema_analysis_pass_interface_and_weak_sym(module_);
			case FINALIZE:
				break;
		}
		if (compiler.context.errors_found) return;
	}
}

// semantic_analyser.c:228 (static), ported
fn void register_generic_decls(CompilationUnit* unit, Decl*[] decls)
{
	foreach (decl : decls)
	{
		decl.unit = unit;
		assert(decl.is_template && decl.generic_id);
		switch (decl.decl_kind)
		{
			case ALIAS_PATH:
			case CT_ASSERT:
			case CT_ECHO:
			case CT_EXEC:
			case CT_EXPAND:
			case CT_INCLUDE:
			case FNTYPE:
			case IMPORT:
			case POISONED:
				continue;
			case FAULT:
			case BODYPARAM:
			case DECLARRAY:
			case ENUM_CONSTANT:
			case ERASED:
			case GROUP:
			case GENERIC:
			case GENERIC_INSTANCE:
			case LABEL:
			case CONTRACT:
				unreachable();
			case ALIAS:
			case ATTRIBUTE:
			case BITSTRUCT:
			case CONSTSET:
			case TYPEDEF:
			case ENUM:
			case INTERFACE:
			case STRUCT:
			case TYPE_ALIAS:
			case UNION:
			case VAR:
				break;
			case MACRO:
			case FUNC:
				if (decl.func_decl.type_parent) continue;
		}
		Decl* old;
		if (decl.visibility < LOCAL)
		{
			if ((old = htable_set(&unit.mod.symbols, decl.name.ptr, decl)))
			{
				if (old.generic_id != decl.generic_id)
				{
					sema_shadow_error(null, decl, old);
					decl_poison(decl);
					decl_poison(old);
					continue;
				}
			}
		}
		if ((old = htable_set(&unit.local_symbols, decl.name.ptr, decl)))
		{
			if (old.generic_id != decl.generic_id)
			{
				sema_shadow_error(null, decl, old);
				decl_poison(decl);
				decl_poison(old);
				continue;
			}
		}

		if (decl.visibility == PUBLIC)
		{
			global_context_add_decl(decl);
		}
	}
}

// semantic_analyser.c:306 (static), ported
fn void analyze_generics(Module* module_)
{
	foreach (unit : module_.units)
	{
		bool remove = false;
		if (unit.feat_attributes.len && sema_retain_conditional_feat(unit.feat_attributes) != BOOL_TRUE)
		{
			remove = true;
		}

		foreach (section : unit.generic_decls)
		{
			if (remove)
			{
				section.generic_decl.decls = {};
				section.generic_decl.conditional_decls = {};
			}
			register_generic_decls(unit, section.generic_decl.decls);
			register_generic_decls(unit, section.generic_decl.conditional_decls);
		}
	}
}

// semantic_analyser.c:329 (static), ported
fn void sema_analyze_to_stage(AnalysisStage stage)
{
	foreach (module_ : compiler.context.module_list)
	{
		sema_analyze_stage(module_, stage);
	}
	halt_on_error();
}

// semantic_analyser.c:338 (static)
fn bool setup_main_runner(Decl* run_function)
{
	SemaContext context;
	sema_context_init(&context, run_function.unit);
	Decl* main = sema_create_runner_main(&context, run_function);
	if (!decl_ok(main)) return false;
	if (!sema_analyse_decl(&context, main)) return false;
	if (!sema_analyse_function_body(&context, main, 0)) return false;
	sema_context_destroy(&context);
	compiler.context.main = main;
	main.unit.main_function = main;
	main.no_strip = true;
	return true;
}

// semantic_analyser.c:352 (static)
fn Decl* find_panic_decl(String name)
{
	ModulePath* path;
	String ident;
	if (sema_splitpathref(name, (ArrayIndex)name.len, &path, &ident) != IDENT)
	{
		@error_exit("'%s' does not seem to be the name of a valid panic function.", name);
	}
	if (!ident.ptr)
	{
		@error_exit("The name of the panic function, '%s' does not match any identifier found.", name);
	}
	if (!path)
	{
		@error_exit("The name of the panic function '%s' seems to missing the full path, something like 'foo::bar::panic' was expected.", name);
	}
	Decl* decl = sema_find_decl_in_modules(compiler.context.module_list, path, ident);
	if (!decl)
	{
		@error_exit("Panic function '%s' could not be found.", name);
	}
	return decl;
}

// semantic_analyser.c:376 (static)
fn void check_panic_signature(Type* type)
{
	if (!type_func_match(type, type_void, 6, type_string, type_string, type_string, type_int, type_string, type_get_slice(type_any)))
	{
		@error_exit("Expected panic function to have the signature fn void(String, String, String, int, String, any[]).");
	}
}

// semantic_analyser.c:384
fn Decl* sema_panic_fn(SemaContext* context)
{
	if (compiler.context.panic_fn) return compiler.context.panic_fn;
	String name = compiler.build.panicfn;
	if (!name.ptr)
	{
		if (no_stdlib()) return null;
		name = "std::core::builtin::default_panic";
	}
	Decl* decl = find_panic_decl(name);
	if (decl.decl_kind != FUNC)
	{
		@error_exit("'%s' is not a function.", name);
	}
	if (!sema_analyse_decl(context, decl)) return null;
	check_panic_signature(type_get_func_ptr(decl.type));
	return compiler.context.panic_fn = decl;
}

// semantic_analyser.c:403 (static)
fn bool is_panic_function_name(String name)
{
	foreach (&desc : panic_fn_desc)
	{
		if (str_eq(name, desc.name)) return true;
	}
	return false;
}

// semantic_analyser.c:412 (static)
fn void check_panic_module_names(SemaContext* context, Decl*[] decls)
{
	foreach (decl : decls)
	{
		if (decl.visibility == LOCAL || !is_panic_function_name(decl.name)) continue;
		@sema_error_at(context, decl.loc, "'%s' is reserved in this module, it is the name of a generated panic function.", decl.name);
	}
}

// semantic_analyser.c:421 (static)
fn void check_panic_module()
{
	foreach (module_ : compiler.context.module_list)
	{
		if (!str_eq(module_.name.module_name, PANIC_MODULE_NAME)) continue;
		foreach (unit : module_.units)
		{
			SemaContext context;
			sema_context_init(&context, unit);
			check_panic_module_names(&context, unit.functions);
			check_panic_module_names(&context, unit.vars);
			sema_context_destroy(&context);
		}
	}
}

// semantic_analyser.c:437 (static)
fn void assign_panicfn()
{
	compiler.context.panic_var = null;
	if (no_panic()) return;
	if (no_stdlib())
	{
		compiler.context.panic_var = sema_panic_fn(null);
		return;
	}
	Decl* decl = find_panic_decl("std::core::builtin::panic");
	if (decl.decl_kind != VAR || !type_is_func_ptr(decl.type.canonical))
	{
		@error_exit("'std::core::builtin::panic' is not a function pointer.");
	}
	check_panic_signature(decl.type.canonical);
	compiler.context.panic_var = decl;
}

// semantic_analyser.c:455 (static)
fn void assign_testfn()
{
	if (!compiler.build.build_test) return;
	if (!compiler.build.testfn.ptr && no_stdlib())
	{
		@error_exit("No test function could be found.");
	}
	String testfn = compiler.build.testfn.ptr ? compiler.build.testfn : "std::core::runtime::default_test_runner";
	ModulePath* path;
	String ident;
	if (sema_splitpathref(testfn, (ArrayIndex)testfn.len, &path, &ident) != IDENT || path == null || !ident.ptr)
	{
		@error_exit("'%s' is not a valid test function.", testfn);
	}
	Decl* decl = sema_find_decl_in_modules(compiler.context.module_list, path, ident);
	if (!decl)
	{
		@error_exit("Test function '%s::%s' could not be found.", path.module_name, ident);
	}
	if (decl.decl_kind != FUNC)
	{
		@error_exit("'%s::%s' is not a function.", path.module_name, ident);
	}
	if (!type_func_match(type_get_func_ptr(decl.type.canonical), type_bool, 1, type_get_slice(type_string)))
	{
		@error_exit("Expected test runner to have the signature fn bool(String[]).");
	}
	decl.no_strip = true;
	if (compiler.build.type != TEST) return;

	if (!setup_main_runner(decl))
	{
		@error_exit("Failed to set up test runner.");
	}
}

// semantic_analyser.c:491 (static)
fn void assign_benchfn()
{
	if (!compiler.build.build_benchmark) return;
	if (!compiler.build.benchfn.ptr && no_stdlib())
	{
		return;
	}
	String testfn = compiler.build.benchfn.ptr ? compiler.build.benchfn : "std::core::runtime::default_benchmark_runner";
	ModulePath* path;
	String ident;
	if (sema_splitpathref(testfn, (ArrayIndex)testfn.len, &path, &ident) != IDENT || path == null || !ident.ptr)
	{
		@error_exit("'%s' is not a valid benchmark function.", testfn);
	}
	Decl* decl = sema_find_decl_in_modules(compiler.context.module_list, path, ident);
	if (!decl)
	{
		@error_exit("Benchmark function '%s::%s' could not be found.", path.module_name, ident);
	}
	if (decl.decl_kind != FUNC)
	{
		@error_exit("'%s::%s' is not a function.", path.module_name, ident);
	}
	if (!type_func_match(type_get_func_ptr(decl.type.canonical), type_bool, 1, type_get_slice(type_string)))
	{
		@error_exit("Expected benchmark function to have the signature fn bool(String[] args).");
	}
	decl.no_strip = true;
	if (!setup_main_runner(decl))
	{
		@error_exit("Failed to set up benchmark runner.");
	}
}

// semantic_analyser.c:528 ported
fn void sema_analysis_run()
{
	compiler_parse();

	// All global defines are added to the std module
	compiler.context.std_module_path = { .module_name = kw_std, .loc = 0, .len = (uint)kw_std.len };
	compiler.context.std_module = { .name = &compiler.context.std_module_path, .short_path = compiler.context.std_module_path.module_name };
	compiler.context.std_module.stage = ANALYSIS_LAST;
	compiler.context.locals_list = {};

	// Set a maximum of symbols in the std_module and test module
	htable_init(&compiler.context.std_module.symbols, 0x1000);

	// Set up the func prototype hash map
	type_func_prototype_init(0x10000);

	// Do we have zero modules?
	if (!compiler.context.module_list.len)
	{
		if (compiler.context.errors_found) exit_compiler(EXIT_FAILURE);
		@error_exit("No modules to compile.");
	}

	// We parse the generic modules, just by storing the decls.
	foreach (module_ : compiler.context.module_list)
	{
		analyze_generics(module_);
	}

	for (int stage = AnalysisStage.NOT_BEGUN.ordinal + 1; stage <= ANALYSIS_LAST.ordinal; stage++)
	{
		sema_analyze_to_stage(AnalysisStage::values[stage]);
	}

	// RESOLVE_LAMBDA
	while (true)
	{
		bool found_lambda = false;
		foreach (module_ : compiler.context.module_list)
		{
			if (module_.lambdas_to_evaluate.len)
			{
				sema_analysis_pass_lambda(module_);
				found_lambda = true;
			}
		}
		if (!found_lambda) break;
	}
	check_panic_module();
	halt_on_error();

	assign_panicfn();
	assign_testfn();
	assign_benchfn();

	foreach (module_ : compiler.context.module_list)
	{
		int unclaimed = 0;
		foreach (unit : module_.units)
		{
			foreach (var_ : unit.generated_globals)
			{
				if (!var_.name.ptr)
				{
					scratch_buffer_clear();
					scratch_buffer_append_module(module_, false);
					@scratch_buffer_printf(".$taddr%d", unclaimed++);
					var_.name = var_.extname = scratch_buffer_copy();
				}
				@vec_add(&unit.vars, var_);
			}
		}
	}
	sema_trace_liveness();
	BenchTime analysis_start = benchstart();
	sema_static_analysis();
	compiler.stats.static_analysis_time = benchmark(analysis_start);
	halt_on_error();
}

// semantic_analyser.c:606 ported
fn void sema_context_init(SemaContext* context, CompilationUnit* unit)
{
	*context = { .unit = unit, .compilation_unit = unit,
	             .ct_locals = global_context_acquire_locals_list(),
	             .locals = global_context_acquire_locals_list() };
}

// semantic_analyser.c:613 ported
fn void sema_context_pop_ct_stack(SemaContext* context, int old_state)
{
	@vec_resize(&context.ct_locals, (usz)old_state);
}

// semantic_analyser.c:618 ported
fn int sema_context_push_ct_stack(SemaContext* context)
{
	return (int)context.ct_locals.len;
}

// semantic_analyser.c:623 ported
fn void sema_context_destroy(SemaContext* context)
{
	if (!context.unit) return;
	generic_context_release_locals_list(context.locals);
	generic_context_release_locals_list(context.ct_locals);
}

// semantic_analyser.c:630 ported
fn Decl*[] global_context_acquire_locals_list()
{
	if (!compiler.context.locals_list.len)
	{
		// c3c VECNEW(Decl*, 64): a non-null empty vector. Code tests the
		// pointer (`context->ct_locals` truthiness), so keep `.ptr` non-null.
		Decl** storage = calloc_arena(64 * usz::size);
		return storage[:0];
	}
	Decl*[] result = @vec_pop(&compiler.context.locals_list);
	@vec_resize(&result, 0);
	return result;
}

// semantic_analyser.c:642 ported
fn void generic_context_release_locals_list(Decl*[] list)
{
	@vec_add(&compiler.context.locals_list, list);
}

// semantic_analyser.c:647
fn SemaContext* context_transform_for_eval(SemaContext* context, SemaContext* temp_context, CompilationUnit* eval_unit)
{
	if (eval_unit == context.unit)
	{
		temp_context.unit = null;
		return context;
	}
	sema_context_init(temp_context, eval_unit);
	temp_context.compilation_unit = context.compilation_unit;
	temp_context.call_env = context.call_env;
	temp_context.current_macro = context.current_macro;
	temp_context.is_temp = true;
	return temp_context;
}

// semantic_analyser.c:663 (static)
fn bool loc_inside_loc(SourceLoc* inner, SourceLoc* outer)
{
	if (!inner || !outer) return false;
	if (inner.offset < outer.offset) return false;
	if (inner.offset + inner.length > outer.offset + outer.length) return false;
	return true;
}

// semantic_analyser.c:671
fn void sema_print_inline(SemaContext* context, SourceLocId original)
{
	if (!context) return;
	InliningSpan* inlined_at = context.inlined_at;
	SourceLocId last_span = 0;
	SourceLoc* original_loc = sourcelocptrzero(original);
	Decl* instance = context.generic_instance;
	bool instance_in_span = false;
	while (inlined_at)
	{
		// A span for this instance already points at where it is instantiated.
		if (instance && inlined_at.instance == instance) instance_in_span = true;
		if (inlined_at.loc != original && inlined_at.loc != last_span)
		{
			SourceLoc* inlined_loc = sourcelocptrzero(inlined_at.loc);
			if (!loc_inside_loc(original_loc, inlined_loc))
			{
				if (inlined_at.instance)
				{
					@sema_note_prev_at(inlined_at.loc, "Instantiated here.");
				}
				else
				{
					@sema_note_prev_at(inlined_at.loc, "Inlined from here.");
				}
				last_span = inlined_at.loc;
			}
		}
		inlined_at = inlined_at.prev;
	}
	if (instance && !instance_in_span && instance.loc != original)
	{
		@sema_note_prev_at(instance.loc, "Instantiated here.");
	}
	InliningSpan span = context.compilation_unit.mod.inlined_at;
	if (!span.loc) return;
	inlined_at = &span;
	while (inlined_at)
	{
		if (inlined_at.loc != original)
		{
			@sema_note_prev_at(inlined_at.loc, "Inlined from here.");
		}
		inlined_at = inlined_at.prev;
	}
}
