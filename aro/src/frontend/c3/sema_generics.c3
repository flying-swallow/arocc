// Port of c3c src/compiler/sema_generics.c (revision 54bab366a): generic
// module instantiation.
//
// Deviations from c3c:
// - The `goto FAIL` / `goto FOUND` jumps are restructured (a helper-free
//   flag / labelled break).
// - A C NULL `suffix` is a String with a null `ptr`; a NULL `params` vector
//   is an empty slice.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_generics.c:4 (static)
fn void mangle_type_param(Type* type, bool mangled)
{
	type = type.canonical;
	if (mangled)
	{
		type_mangle_introspect_name_to_buffer(type);
	}
	else
	{
		scratch_buffer_append(type.name);
	}
}

// sema_generics.c:16 (static)
fn void sema_generate_parameter_suffix_to_scratch(Expr*[] params, bool mangled)
{
	scratch_buffer_clear();
	scratch_buffer_append(mangled ? "$" : "{");
	foreach (j, param : params)
	{
		if (j != 0)
		{
			scratch_buffer_append(mangled ? "$" : ", ");
		}
		if (expr_is_const_typeid(param))
		{
			mangle_type_param(param.const_expr.typeid_type, mangled);
			continue;
		}
		Type* type = param.type.canonical;
		if (type.type_kind == TYPEDEF)
		{
			mangle_type_param(type, mangled);
			scratch_buffer_append(mangled ? "$" : ", ");
			type = type_flatten(type);
		}
		if (type == type_bool)
		{
			if (mangled)
			{
				scratch_buffer_append_char(param.const_expr.b ? 't' : 'f');
			}
			else
			{
				scratch_buffer_append(param.const_expr.b ? "true" : "false");
			}
		}
		else if (type.type_kind == ENUM)
		{
			Decl* enumm = param.const_expr.enum_val;
			type_mangle_introspect_name_to_buffer(enumm.type.canonical);
			scratch_buffer_append(mangled ? "_" : ":");
			scratch_buffer_append(enumm.name);
		}
		else if (type.type_kind == ANYFAULT)
		{
			Decl* fault_ = param.const_expr.fault_val;
			if (fault_)
			{
				type_mangle_introspect_name_to_buffer(fault_.type.canonical);
				scratch_buffer_append(mangled ? "_" : ":");
				scratch_buffer_append(fault_.name);
			}
			else
			{
				scratch_buffer_append("null");
			}
		}
		else
		{
			char* maybe_neg = scratch_buffer_end_ptr();
			if (type.type_kind == I128 || type.type_kind == U128)
			{
				String str = int_to_str(param.const_expr.ixx, 10, false);
				scratch_buffer_append(str);
			}
			else
			{
				if (type_is_signed(type))
				{
					scratch_buffer_append_signed_int((long)(ulong)param.const_expr.ixx.i);
				}
				else
				{
					scratch_buffer_append_unsigned_int((ulong)param.const_expr.ixx.i);
				}
			}
			if (mangled)
			{
				// Replace - with _
				if (maybe_neg[0] == '-') maybe_neg[0] = '_';
			}
		}
	}
	scratch_buffer_append(mangled ? "$" : "}");
}

// sema_generics.c:102 (static)
fn bool sema_analyse_generic_module_contracts(SemaContext* c, Module* module_, Decl* instance, Expr*[] contracts, SourceLocId param_loc, SourceLocId invocation_loc)
{
	assert(contracts.len);
	foreach (contract : contracts)
	{
		SemaContext temp_context;
		InliningSpan* old_span = c.inlined_at;
		InliningSpan new_span = { .prev = old_span, .loc = invocation_loc, .instance = instance };
		SemaContext* new_context = context_transform_for_eval(c, &temp_context, module_.units[0]);
		Decl* old_generic_instance = new_context.generic_instance;
		InliningSpan* old_inlined_at = new_context.inlined_at;
		new_context.generic_instance = instance;
		new_context.inlined_at = &new_span;

		foreach (expr : contract.contract_expr.decl_exprs.expression_list)
		{
			CondResult res = sema_check_comp_time_bool(new_context, expr);
			if (res == COND_TRUE) continue;
			if (res != COND_MISSING)
			{
				if (contract.contract_expr.comment.ptr)
				{
					@sema_error_at(c, param_loc,
					               "Parameter(s) would violate constraint: %s.",
					               contract_to_message(contract, false));
				}
				else
				{
					@sema_error_at(c, param_loc, "Parameter(s) failed validation: %s",
					               contract_to_message(contract, false));
				}
			}
			// FAIL:
			new_context.inlined_at = old_inlined_at;
			new_context.generic_instance = old_generic_instance;
			sema_context_destroy(&temp_context);
			return false;
		}
		new_context.inlined_at = old_inlined_at;
		new_context.generic_instance = old_generic_instance;
		sema_context_destroy(&temp_context);
	}
	return true;
}

// sema_generics.c:145 (static)
fn Decl* generate_parameterized_identifier(SemaContext* context, Decl* generic, Decl* alias_, Expr*[] params, Decl*[] param_decls, String suffix, String csuffix, SourceLocId invocation_loc, SourceLocId loc)
{
	Module* module_ = alias_.unit.mod;
	Decl* instance = null;
	int id = generic.generic_decl.id;
	foreach FOUND: (g : alias_.unit.mod.generic_sections)
	{
		if (g.generic_decl.id != id) continue;
		foreach (candidate : g.generic_decl.instances)
		{
			if (candidate.name.ptr == csuffix.ptr)
			{
				instance = candidate;
				break FOUND;
			}
		}
	}
	if (!instance)
	{
		if (compiler.context.errors_found) return poisoned_decl;
		instance = decl_new(GENERIC_INSTANCE, csuffix, invocation_loc);
		Decl* root = context.generic_instance;
		if (root && root.decl_kind != GENERIC_INSTANCE) root = null;
		if (root)
		{
			if (root.instance_decl.spawn_root) root = declptr(root.instance_decl.spawn_root);
			if (++root.instance_decl.spawn_count > (int)compiler.build.max_generic_instances)
			{
				@sema_error_at(context, invocation_loc, "This generic instantiation would create more than %d instances, it is probably recursive. You can change this limit using '--max-generic-instances'.", compiler.build.max_generic_instances);
				return poisoned_decl;
			}
			instance.instance_decl.spawn_root = declid(root);
		}
		foreach (i, param_name : generic.generic_decl.parameters)
		{
			Decl* decl;
			Expr* param = params.len ? params[i] : copy_expr_single(param_decls[i].var_decl.init_expr);
			assert(param.expr_kind == CONST);
			if (expr_is_const_typeid(param))
			{
				decl = decl_new_var(param_name, param.loc, null, PARAM_CT_TYPE);
			}
			else
			{
				assert(param.expr_kind == CONST);
				decl = decl_new_var(param_name, param.loc, null, CONST);
			}
			decl.var_decl.init_expr = param;
			decl.unit = alias_.unit;
			decl.resolve_status = DONE;
			decl.type = param.type;
			@vec_add(&instance.instance_decl.params, decl);
		}
		instance.unit = alias_.unit;
		Decl*[] copied = {};
		Decl*[] copied_cond = {};
		if (!suffix.ptr)
		{
			sema_generate_parameter_suffix_to_scratch(params, false);
			suffix = scratch_buffer_interned();
		}
		instance.instance_decl.name_suffix = suffix;
		instance.instance_decl.cname_suffix = csuffix;
		instance.instance_decl.id = id;
		foreach (g : module_.generic_sections)
		{
			if (g.generic_decl.id == generic.generic_decl.id)
			{
				@vec_add(&instance.instance_decl.templates, g);
				Decl*[] decls = g.generic_decl.decls;
				Decl*[] cond_decls = g.generic_decl.conditional_decls;
				decls = decls.len ? copy_decl_list_single_for_generic(decls, instance) : {};
				cond_decls = cond_decls.len ? copy_decl_list_single_for_generic(cond_decls, instance) : {};
				foreach (d : decls) @vec_add(&copied, d);
				foreach (d : cond_decls) @vec_add(&copied_cond, d);
			}
		}
		@vec_add(&generic.generic_decl.instances, instance);
		AnalysisStage stage = module_.stage;
		assert(stage > AnalysisStage.IMPORTS);
		if (compiler.context.errors_found) return poisoned_decl;

		// Check contracts
		foreach (decl : module_.generic_sections)
		{
			if (decl.generic_decl.id == generic.generic_decl.id)
			{
				Expr*[] requires = decl.generic_decl.requires;
				if (!requires.len) continue;
				copy_begin();
				Expr*[] contract = copy_exprlist_macro(requires);
				copy_end();
				SourceLoc param_loc = params.len
					? extend_loc_with_token(sourcelocptr(params[0].loc), sourcelocptr(params[^1].loc))
					: extend_loc_with_token(sourcelocptr(param_decls[0].loc), sourcelocptr(param_decls[^1].loc));
				if (!sema_analyse_generic_module_contracts(context, module_, instance, contract, make_loc(param_loc), invocation_loc))
				{
					decl_poison(instance);
					decl_poison(alias_);
					return alias_;
				}
			}
		}

		// Add all the normal top level declarations
		foreach (decl : copied) unit_register_global_decl(decl.unit, decl);
		// Add all the conditional declarations
		foreach (decl : copied_cond)
		{
			unit_register_optional_global_decl(decl.unit, decl);
			if (decl.decl_kind != ERASED) @vec_add(&copied, decl);
		}

		foreach (decl : copied)
		{
			if (decl.unit.mod.stage < AnalysisStage.METHODS_REGISTER) continue;
			if (!decl_is_fn_macro(decl)) continue;
			if (!decl.func_decl.type_parent) continue;
			SemaContext gen_context;
			sema_context_init(&gen_context, decl.unit);
			gen_context.generic_instance = instance;
			if (sema_analyse_method_register(&gen_context, decl) && decl.decl_kind != ERASED)
			{
				if (decl.decl_kind == MACRO)
				{
					@vec_add(&decl.unit.macro_methods, decl);
				}
				else
				{
					@vec_add(&decl.unit.methods, decl);
				}
			}
		}
		foreach (decl : copied)
		{
			if (!decl_ok(decl)) continue;
			if (decl.unit.mod.stage < AnalysisStage.DECLS) continue;
			if (decl.unit.mod.stage <= AnalysisStage.DECLS_CHECK_GENERICS)
			{
				@vec_add(&compiler.context.unregistered_generic_decls, decl);
				continue;
			}
			SemaContext context_gen;
			sema_context_init(&context_gen, decl.unit);
			context_gen.active_scope = { .depth = 0 };
			if (sema_analyse_decl(&context_gen, decl))
			{
				context_gen.generic_instance = instance;
				sema_analyse_inner_func_ptr(&context_gen, decl);
				if (!decl_ok(decl)) continue;
				foreach (info : decl.unit.check_type_variable_array)
				{
					if (!sema_check_type_variable_array(&context_gen, info)) break;
				}
			}
			sema_context_destroy(&context_gen);
		}
		if (compiler.context.errors_found) return poisoned_decl;
		foreach (decl : copied)
		{
			if (!decl_ok(decl)) continue;
			if (decl.unit.mod.stage < AnalysisStage.FUNCTIONS) continue;
			SemaContext context_gen;
			switch (decl.decl_kind)
			{
				case FUNC:
					sema_context_init(&context_gen, decl.unit);
					analyse_func_body(&context_gen, decl);
					sema_context_destroy(&context_gen);
				default:
					break;
			}
		}
		if (compiler.context.errors_found) return poisoned_decl;
		foreach (decl : copied)
		{
			if (decl.unit.mod.stage < AnalysisStage.INTERFACE) continue;
			SemaContext context_gen;
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
				sema_context_init(&context_gen, decl.unit);
				sema_check_interfaces(&context_gen, decl);
				sema_context_destroy(&context_gen);
			}
		}
		if (compiler.context.errors_found) return poisoned_decl;
	}
	Decl* symbol = sema_find_generic_instance(context, module_, generic, instance, alias_.name);
	if (!symbol)
	{
		@sema_error_at(context, loc, "The generic '%s' does not exist for this parameterization.", alias_.name);
		return poisoned_decl;
	}

	CompilationUnit* unit = symbol.unit;
	if (unit.mod.stage < AnalysisStage.POST_REGISTER)
	{
		@vec_add(&unit.global_decls, symbol);
	}
	else
	{
		if (unit.mod.stage > AnalysisStage.DECLS_CHECK_GENERICS)
		{
			if (!sema_analyse_decl(context, symbol)) return poisoned_decl;
		}
	}
	return symbol;
}

// sema_generics.c:369
fn Decl* sema_analyse_parameterized_identifier(SemaContext* context, ModulePath* decl_path, String name, SourceLocId loc, Expr*[] params, SourceLocId invocation_loc)
{
	Decl* alias_ = sema_resolve_parameterized_symbol(context, name, decl_path, loc);
	if (!alias_) return poisoned_decl;
	assert(alias_.is_template && alias_.generic_id);
	Decl* generic = declptr(alias_.generic_id);
	int parameter_count = (int)generic.generic_decl.parameters.len;
	assert(parameter_count > 0);
	int count = (int)params.len;
	if (parameter_count != count)
	{
		if (!count)
		{
			@sema_error_at(context, invocation_loc,
			               "'%s' requires generic arguments inside the '{}', did you forget them?", name);
		}
		else
		{
			// 'Foo' expects 2 generic arguments, but you supplied 1, did you make a mistake?
			SourceLoc l = extend_loc_with_token(sourcelocptr(params[0].loc), sourcelocptr(params[^1].loc));
			@sema_error_at(context, make_loc(l),
			               "'%s' expects %d %s, but you supplied %d, did you make a mistake?",
			               name,
			               parameter_count,
			               parameter_count == 1 ? "argument" : "arguments",
			               params.len);
		}
		return poisoned_decl;
	}
	// First resolve
	foreach (i, param : params)
	{
		if (!sema_analyse_expr_rvalue(context, param)) return poisoned_decl;
		String param_name = generic.generic_decl.parameters[i];
		bool is_type = str_is_type(param_name);
		if (expr_is_const_typeid(param))
		{
			if (!is_type)
			{
				@sema_error_at(context, param.loc, "Expected a value, not a type, for parameter '%s'.", param_name);
				return poisoned_decl;
			}
			Type* type = param.const_expr.typeid_type;
			if (type_is_optional(type))
			{
				@sema_error_at(context, param.loc, "The generic type can never be an optional, please use only non-optional types.");
				return poisoned_decl;
			}
			if (type_is_func_ptr(type))
			{
				if (!sema_resolve_type_decl(context, type.pointer)) return poisoned_decl;
			}
		}
		else
		{
			if (is_type)
			{
				@sema_error_at(context, param.loc, "Expected a type, not a value, for parameter '%s'.", param_name);
				return poisoned_decl;
			}
			if (!sema_analyse_ct_expr(context, param)) return poisoned_decl;
			Type* type = param.type.canonical;
			if (type.type_kind == TYPEDEF || type.type_kind == CONSTSET) type = type_flatten(type);
			if (@is_optional(param))
			{
				@sema_error_at(context, param.loc, "The parameter may never be an optional value.");
				return poisoned_decl;
			}

			bool is_enum_or_fault = type_kind_is_enum_or_fault(type.type_kind);
			if (!type_is_integer_or_bool_kind(type) && !is_enum_or_fault)
			{
				@sema_error_at(context, param.loc, "Only integer, bool, fault and enum values may be generic arguments.");
				return poisoned_decl;
			}
			assert(expr_is_const(param));
		}
	}
	sema_generate_parameter_suffix_to_scratch(params, true);
	if (scratch_buffer_len() > MAX_GENERIC_SUFFIX)
	{
		@sema_error_at(context, invocation_loc, "The generic declaration is too deeply nested and is possibly recursive.");
		return poisoned_decl;
	}
	String suffix = scratch_buffer_interned();
	return sema_generate_parameterized_identifier(context, generic, alias_, params, {}, {}, suffix, invocation_loc, loc);
}

// sema_generics.c:455
fn Decl* sema_generate_parameterized_identifier(SemaContext* context, Decl* generic, Decl* alias_, Expr*[] params, Decl*[] param_decls, String suffix, String csuffix, SourceLocId invocation_loc, SourceLocId loc)
{
	// Only time the outermost instantiation, the nested ones are part of it.
	if (!compiler.build.collect_stats || compiler.stats.generic_depth)
	{
		return generate_parameterized_identifier(context, generic, alias_, params, param_decls, suffix, csuffix, invocation_loc, loc);
	}
	compiler.stats.generic_depth++;
	BenchTime start = benchstart();
	Decl* decl = generate_parameterized_identifier(context, generic, alias_, params, param_decls, suffix, csuffix, invocation_loc, loc);
	compiler.stats.generic_time += benchmark(start);
	compiler.stats.generic_depth--;
	return decl;
}
