// Sema contract stubs for c3c src/compiler/semantic_analyser.c (revision 54bab366a): every function
// of the C file not ported yet, with its final C3 signature and an
// `unreachable` body, in c3c order. Port each body in place (see
// PORTING.md "Sema contract"); the `// file:line` comment points at the
// c3c definition and marks static functions.
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
	unreachable("sema stub: context_change_scope_with_flags");
}

// semantic_analyser.c:53
fn String context_filename(SemaContext* context)
{
	unreachable("sema stub: context_filename");
}

// semantic_analyser.c:62
fn void context_change_scope_for_label(SemaContext* context, DeclId label_id, SourceLocId loc)
{
	unreachable("sema stub: context_change_scope_for_label");
}

// semantic_analyser.c:76
fn AstId context_get_defers(SemaContext* context, AstId defer_bottom, bool is_success)
{
	unreachable("sema stub: context_get_defers");
}

// semantic_analyser.c:97
fn void context_pop_defers(SemaContext* context, AstId* next)
{
	unreachable("sema stub: context_pop_defers");
}

// semantic_analyser.c:118
fn void sema_add_methods_to_decl_stack(SemaContext* context, Decl* decl)
{
	unreachable("sema stub: sema_add_methods_to_decl_stack");
}

// semantic_analyser.c:140
fn void context_pop_defers_and_replace_ast(SemaContext* context, Ast* ast)
{
	unreachable("sema stub: context_pop_defers_and_replace_ast");
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
	unreachable("sema stub: setup_main_runner");
}

// semantic_analyser.c:352 (static)
fn Decl* find_panic_decl(String name)
{
	unreachable("sema stub: find_panic_decl");
}

// semantic_analyser.c:376 (static)
fn void check_panic_signature(Type* type)
{
	unreachable("sema stub: check_panic_signature");
}

// semantic_analyser.c:384
fn Decl* sema_panic_fn(SemaContext* context)
{
	unreachable("sema stub: sema_panic_fn");
}

// semantic_analyser.c:403 (static)
fn bool is_panic_function_name(String name)
{
	unreachable("sema stub: is_panic_function_name");
}

// semantic_analyser.c:412 (static)
fn void check_panic_module_names(SemaContext* context, Decl*[] decls)
{
	unreachable("sema stub: check_panic_module_names");
}

// semantic_analyser.c:421 (static)
fn void check_panic_module()
{
	unreachable("sema stub: check_panic_module");
}

// semantic_analyser.c:437 (static)
fn void assign_panicfn()
{
	unreachable("sema stub: assign_panicfn");
}

// semantic_analyser.c:455 (static)
fn void assign_testfn()
{
	unreachable("sema stub: assign_testfn");
}

// semantic_analyser.c:491 (static)
fn void assign_benchfn()
{
	unreachable("sema stub: assign_benchfn");
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
		return {};
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
	unreachable("sema stub: context_transform_for_eval");
}

// semantic_analyser.c:663 (static)
fn bool loc_inside_loc(SourceLoc* inner, SourceLoc* outer)
{
	unreachable("sema stub: loc_inside_loc");
}

// semantic_analyser.c:671
fn void sema_print_inline(SemaContext* context, SourceLocId original)
{
	unreachable("sema stub: sema_print_inline");
}
