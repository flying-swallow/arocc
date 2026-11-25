// Port of c3c src/compiler/sema_name_resolution.c (revision 54bab366a):
// symbol lookup (locals, unit, module, imports, global tables), ambiguity
// resolution, "did you mean" reporting, method lookup and local scopes.
//
// Deviations from c3c:
// - `damerau_levenshtein_distance` keeps its 256x256 score matrix in a
//   module-level buffer instead of on the stack (no giant stack frames) and
//   skips the memset: every cell read is written first.
// - The `goto IMPORT_CHECK` / `goto NOT_GENERIC` / `goto ADD_VAR` /
//   `goto RETRY` jumps are restructured with flags and loops.
// - A NULL path name is a String with a null `ptr`.
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

// sema_name_resolution.c:12
fn Decl* sema_find_generic_instance(SemaContext* context, Module* module_, Decl* generic, Decl* instance, String name)
{
	scratch_buffer_clear();
	scratch_buffer_append(name);
	scratch_buffer_append(instance.instance_decl.name_suffix);
	String full_name = scratch_buffer_interned();
	foreach (g : module_.generic_sections)
	{
		if (g.generic_decl.id == generic.generic_decl.id)
		{
			foreach (decl : instance.instance_decl.generated_decls)
			{
				if (decl.name.ptr != full_name.ptr) continue;
				if (decl.visibility == LOCAL && decl.unit != context.unit) continue;
				return decl;
			}
		}
	}
	return null;
}

// sema_name_resolution.c:33 (static)
fn bool matches_subpath(ModulePath* path_to_check, ModulePath* path_to_find)
{
	// This checks the full match.
	if (path_to_find.module_name.ptr == path_to_check.module_name.ptr) return true;

	// Let's check the offset on where to start comparing to start with
	// the submatch.
	long compare_start = (long)path_to_check.len - (long)path_to_find.len;

	// The smallest match is the situation a::foo::bar vs foo::bar
	// This means that the compare_start must be 3 or more.
	if (compare_start < 3) return false;

	// We also want to make sure that the preceding 2 characters are ::
	char* check = path_to_check.module_name.ptr;
	if (check[compare_start - 1] != ':' || check[compare_start - 2] != ':') return false;

	// Ok, now we know this is a subpath, so check:
	return (String)check[compare_start:path_to_find.len] == (String)path_to_find.module_name.ptr[:path_to_find.len];
}

// sema_name_resolution.c:53
fn Decl* sema_decl_stack_resolve_symbol(String symbol)
{
	Decl** current = compiler.context.decl_stack_top;
	Decl** end = compiler.context.decl_stack_bottom;
	while (current > end)
	{
		Decl* decl = *(--current);
		if (decl.name.ptr == symbol.ptr) return decl;
	}
	return null;
}

// sema_name_resolution.c:65
fn Decl** sema_decl_stack_store()
{
	Decl** current_bottom = compiler.context.decl_stack_bottom;
	compiler.context.decl_stack_bottom = compiler.context.decl_stack_top;
	return current_bottom;
}

// sema_name_resolution.c:72
fn void sema_decl_stack_restore(Decl** state)
{
	compiler.context.decl_stack_top = compiler.context.decl_stack_bottom;
	compiler.context.decl_stack_bottom = state;
}

// sema_name_resolution.c:78
fn void sema_decl_stack_push(Decl* decl)
{
	Decl** current = compiler.context.decl_stack_top;
	if (current == (Decl**)&compiler.context.decl_stack + MAX_GLOBAL_DECL_STACK)
	{
		@error_exit("Declaration stack exhausted.");
	}
	*(current++) = decl;
	compiler.context.decl_stack_top = current;
}

// sema_name_resolution.c:89 (static)
fn bool add_interface_to_decl_stack(SemaContext* context, Decl* decl)
{
	if (!sema_analyse_decl(context, decl)) return false;
	foreach (parent_interface : decl.interfaces)
	{
		assert(parent_interface.resolve_status == DONE);
		Decl* inf = parent_interface.type.decl;
		if (!sema_analyse_decl(context, inf)) return false;
		add_interface_to_decl_stack(context, inf);
	}
	foreach (interface_ : decl.interface_methods) sema_decl_stack_push(interface_);
	return true;
}

// sema_name_resolution.c:103 (static)
fn bool add_members_to_decl_stack(SemaContext* context, Decl* decl, FindMember find)
{
	Decl* original = decl;
	while (decl.decl_kind == TYPEDEF)
	{
		Type* type = decl.distinct.type.canonical;
		if (!type_is_user_defined(type)) break;
		decl = type.decl;
	}

	bool late_add = original != decl;
	if (find != FIELDS_ONLY && !late_add) sema_add_methods_to_decl_stack(context, original);

	if (decl.decl_kind == ENUM)
	{
		foreach (member : decl.enums.parameters) sema_decl_stack_push(member);
	}
	if (decl.decl_kind == INTERFACE && find != FIELDS_ONLY)
	{
		if (!add_interface_to_decl_stack(context, decl)) return false;
	}
	if (decl_has_members(decl))
	{
		foreach (member : decl.strukt.members)
		{
			if (member.name.ptr == null)
			{
				if (!add_members_to_decl_stack(context, member, find)) return false;
				continue;
			}
			sema_decl_stack_push(member);
		}
	}

	if (find != FIELDS_ONLY && late_add) sema_add_methods_to_decl_stack(context, original);

	return true;
}

// sema_name_resolution.c:142
fn Decl* sema_decl_stack_find_decl_member(SemaContext* context, Decl* decl_owner, String symbol, FindMember find)
{
	Decl** state = sema_decl_stack_store();
	if (!add_members_to_decl_stack(context, decl_owner, find)) return poisoned_decl;
	Decl* member = sema_decl_stack_resolve_symbol(symbol);
	sema_decl_stack_restore(state);
	if (member || find == FIELDS_ONLY) return member;
	if (find == METHODS_AND_FIELDS)
	{
		return sema_resolve_method_only(decl_owner, symbol);
	}
	return sema_resolve_method(decl_owner, symbol);
}

// sema_name_resolution.c:156 (static)
fn Decl* sema_find_decl_in_module(Module* module_, ModulePath* path, String symbol, Module** path_found_ref)
{
	if (!path) return module_find_symbol(module_, symbol);
	if (path.len > module_.name.len) return null;
	if (!matches_subpath(module_.name, path)) return null;
	*path_found_ref = module_;
	return module_find_symbol(module_, symbol);
}

// sema_name_resolution.c:165 (static)
fn bool sema_find_decl_in_imports(SemaContext* context, NameResolve* name_resolve)
{
	Decl* decl = null;
	// 1. Loop over imports.
	ModulePath* path = name_resolve.path;
	String symbol = name_resolve.symbol;

	foreach (imp : context.unit.imports)
	{
		bool is_private_import = imp.import_decl.import_private_as_public;
		if (!path && (decl || !is_private_import)) continue;
		// Is the decl in the import.
		Decl* found = sema_find_decl_in_module(imp.import_decl.mod, path, symbol, &name_resolve.path_found);

		if (!decl_ok(found)) return false;

		// No match, so continue
		if (!found) continue;
		assert(found.visibility != LOCAL);

		if (found.visibility != PUBLIC)
		{
			if (decl) continue;
			if (!is_private_import)
			{
				name_resolve.private_decl = found;
				continue;
			}
		}

		// Did we already have a match?
		if (decl)
		{
			if (!path)
			{
				if (!sema_resolve_ambiguity(context, &decl, found, &name_resolve.ambiguous_other_decl, false)) return false;
				continue;
			}
			// 11. Then set an ambiguous match.
			name_resolve.ambiguous_other_decl = found;
			continue;
		}

		// We've found a match.
		decl = found;
		name_resolve.private_decl = null;
	}
	name_resolve.found = decl;
	return true;
}

// sema_name_resolution.c:216 (static)
fn Module* sema_is_path_found(Module*[] modules, ModulePath* path)
{
	foreach (module_ : modules)
	{
		if (matches_subpath(module_.name, path)) return module_;
	}
	return null;
}

// sema_name_resolution.c:225
fn Decl* sema_find_decl_in_modules(Module*[] module_list, ModulePath* path, String interned_name)
{
	Module* path_found = null;
	foreach (module_ : module_list)
	{
		Decl* decl = sema_find_decl_in_module(module_, path, interned_name, &path_found);
		if (decl) return decl;
	}
	return null;
}

// sema_name_resolution.c:236 (static)
fn bool module_inclusion_match(Module* a, Module* b)
{
	// Quick check
	if (a.top_module != b.top_module) return false;
	if (a.name.len < b.name.len)
	{
		Module* temp = a;
		a = b;
		b = temp;
	}
	while (a.name.len > b.name.len) a = a.parent_module;
	return a == b;
}

// sema_name_resolution.c:250 (static)
fn bool decl_is_visible(CompilationUnit* unit, Decl* decl)
{
	Module* module_ = decl.unit.mod;
	// 1. Same module as unit -> ok
	if (module_ == unit.mod) return true;

	// 2. Skip to imports for private decls
	bool is_public = decl.visibility == PUBLIC;
	if (is_public)
	{
		// 3. Module inclusion: a is submodule of b or b of a.

		if (module_inclusion_match(module_, unit.mod)) return true;

		// 4. We want to check std::core
		Module* lookup = module_;
		while (lookup)
		{
			if (lookup.name.module_name.ptr == kw_std__core.ptr) return true;
			lookup = lookup.parent_module;
		}
	}
	// IMPORT_CHECK:
	foreach (imp : unit.imports)
	{
		if (!is_public && !imp.import_decl.import_private_as_public) continue;
		Module* import_module = imp.import_decl.mod;
		if (import_module == module_) return true;
		if (imp.import_decl.is_non_recurse) continue;
		if (module_inclusion_match(import_module, module_)) return true;
	}
	return false;
}

// sema_name_resolution.c:283 (static)
fn Type* sema_fold_weak(SemaContext* context, Decl* decl)
{
	if (decl.decl_kind != TYPE_ALIAS) return decl.type;
	while (decl.is_weak)
	{
		if (decl.resolve_status != DONE)
		{
			if (!sema_analyse_decl(context, decl)) return null;
		}
		if (decl.type_alias_decl.is_func)
		{
			decl = decl.type_alias_decl.decl;
			continue;
		}
		Expr* expr = decl.type_alias_decl.type_expr;
		Type* type = expr.expr_kind == TYPEINFO ? expr.type_expr.type : expr.const_expr.typeid_type;
		if (type.type_kind != ALIAS) return type;
		decl = type.decl;
	}
	return decl.type;
}

<*
 We want to prefer abc::Foo over bcd::Foo if:
 (1) abc::Foo is builtin and there's no path
 (2) abc::Foo is from a normal module and bcd::Foo is from a generic module.
 (3) Folding bcd::Foo to it's weak result gives the same as folding abc::Foo to its weak type.
*>
// sema_name_resolution.c:317 (static)
fn BoolErr sema_first_is_preferred(SemaContext* context, Decl* decl, Decl* decl2, bool has_path)
{
	if (has_path && !decl.is_autoimport && decl2.is_autoimport) return BOOL_TRUE;
	if (!has_path && decl.is_autoimport && !decl2.is_autoimport) return BOOL_TRUE;
	if ((decl2.is_template && !decl.is_template)) return BOOL_TRUE;
	if (str_start_with(decl2.unit.mod.name.module_name, kw_std__core))
	{
		if (!has_path && decl2.is_autoimport && !decl.is_autoimport) return BOOL_FALSE;
		return BOOL_TRUE;
	}

	// Now analyse common parents, we only check if this is a redef.

	if (decl2.decl_kind != TYPE_ALIAS || !decl2.is_weak) return BOOL_FALSE;

	Type* weak2 = sema_fold_weak(context, decl2);
	if (!weak2) return BOOL_ERR;

	// Fast path: do the types match?
	if (weak2 == decl.type) return BOOL_TRUE;

	// If we can't fold the decl then we're done.
	if (decl.decl_kind != TYPE_ALIAS || !decl.is_weak) return BOOL_FALSE;

	Type* weak = sema_fold_weak(context, decl);
	if (!weak) return BOOL_ERR;

	// Both fold to the same
	if (weak == weak2) return BOOL_TRUE;

	// Otherwise we fail.
	return BOOL_FALSE;
}

// sema_name_resolution.c:351 (static)
fn bool sema_resolve_ambiguity(SemaContext* context, Decl** current, Decl* candidate, Decl** ambiguous, bool has_path)
{
	Decl* original = *current;
	if (!original)
	{
		*current = candidate;
		return true;
	}
	// The candidate is preferred
	BoolErr preferred = sema_first_is_preferred(context, candidate, original, has_path);
	if (preferred == BOOL_ERR) return false;
	if (preferred == BOOL_TRUE)
	{
		// Clear any ambiguity
		*ambiguous = null;
		*current = candidate;
		return true;
	}
	// We already have something ambiguous, so keep that.
	if (*ambiguous) return true;
	// If the original is preferred over the candidate, then we just
	// keep the original and there is no ambiguity:
	switch (sema_first_is_preferred(context, original, candidate, has_path))
	{
		case BOOL_FALSE:
			// Otherwise we have an ambiguity
			*ambiguous = candidate;
			return true;
		case BOOL_TRUE:
			return true;
		case BOOL_ERR:
			return false;
	}
	unreachable();
}

// sema_name_resolution.c:387 (static)
fn Decl* sema_find_decl_by_short_path(ModulePath* path, String name)
{
	return pathtable_get(&compiler.context.path_symbols, path.module_name, name);
}

// sema_name_resolution.c:392 (static)
fn bool sema_find_decl_in_global(SemaContext* context, DeclTable* table, Module*[] module_list, NameResolve* name_resolve)
{
	String symbol = name_resolve.symbol;
	ModulePath* path = name_resolve.path;
	DeclId decl_ids = decltable_get(table, symbol);
	Decl* maybe_decl = null;
	// We might have no match at all.
	if (!decl_ids)
	{
		// Update the path found
		if (path && !name_resolve.path_found) name_resolve.path_found = sema_is_path_found(module_list, path);
		name_resolve.found = null;
		return true;
	}

	Decl* decls = declptr(decl_ids);
	// There might just be a single match.
	if (decls.decl_kind != DECLARRAY)
	{
		if (path && !matches_subpath(decls.unit.mod.name, path)) return true;
		if (!decl_is_visible(context.unit, decls))
		{
			if (decls.visibility == PRIVATE)
			{
				name_resolve.private_decl = decls;
			}
			else
			{
				name_resolve.maybe_decl = decls;
			}
		}
		else
		{
			name_resolve.private_decl = null;
			name_resolve.found = decls;
		}
		return true;
	}

	// Else go through the list
	Decl* ambiguous = null;
	Decl* decl = null;
	foreach (candidate : decls.decl_list)
	{
		if (path && !matches_subpath(candidate.unit.mod.name, path)) continue;
		if (!decl_is_visible(context.unit, candidate))
		{
			maybe_decl = candidate;
			continue;
		}
		if (!sema_resolve_ambiguity(context, &decl, candidate, &ambiguous, path != null)) return false;
	}
	name_resolve.ambiguous_other_decl = ambiguous;
	name_resolve.found = decl;
	if (maybe_decl && maybe_decl.visibility == PRIVATE)
	{
		name_resolve.private_decl = maybe_decl;
		name_resolve.maybe_decl = null;
	}
	else
	{
		name_resolve.private_decl = null;
		name_resolve.maybe_decl = maybe_decl;
	}
	return true;
}

// sema_name_resolution.c:459 (static)
fn bool sema_resolve_path_symbol(SemaContext* context, NameResolve* name_resolve)
{
	ModulePath* path = name_resolve.path;
	assert(path, "Expected path.");
	name_resolve.ambiguous_other_decl = null;
	name_resolve.path_found = null;
	name_resolve.found = null;

	foreach (decl_alias : context.unit.module_aliases)
	{
		if (path.module_name.ptr == decl_alias.name.ptr)
		{
			// c3c: assert(decl_alias.resolve_status == DONE); -- C assert, compiled out in c3c release builds
			name_resolve.path_found = decl_alias.module_alias_decl.mod;
			name_resolve.path = name_resolve.path_found.name;
			break;
		}
	}

	String symbol = name_resolve.symbol;
	CompilationUnit* unit = context.unit;

	// 1. Do we match our own path?
	if (matches_subpath(unit.mod.name, path))
	{
		// 2. If so try to locally get the symbol.
		if ((name_resolve.found = module_find_symbol(unit.mod, symbol))) return true;
		name_resolve.path_found = unit.mod;
	}

	Decl* decl = sema_find_decl_by_short_path(name_resolve.path, symbol);
	if (decl && decl_ok(decl) && decl_is_visible(context.unit, decl))
	{
		name_resolve.found = decl;
		return true;
	}
	// 3. Loop over imports.
	if (!sema_find_decl_in_imports(context, name_resolve)) return false;

	// 4. Go to global search
	if (name_resolve.found) return true;
	return sema_find_decl_in_global(context, &compiler.context.symbols, compiler.context.module_list, name_resolve);
}

// sema_name_resolution.c:503 (static)
fn Decl* sema_find_ct_local(SemaContext* context, String symbol)
{
	Decl*[] locals = context.ct_locals;
	foreach (cur : locals)
	{
		if (cur.name.ptr == symbol.ptr) return cur;
	}
	return null;
}

// sema_name_resolution.c:513
fn Decl* sema_find_local(SemaContext* context, String symbol)
{
	if (symbol[0] == '$') return sema_find_ct_local(context, symbol);
	Decl*[] locals = context.locals;
	if (!locals.len || !context.active_scope.current_local) return null;
	long first = 0;
	long current = (long)context.active_scope.current_local - 1;
	while (current >= first)
	{
		Decl* cur = locals[current];
		if (cur.name.ptr == symbol.ptr)
		{
			// We patch special behaviour here.
			if (cur.decl_kind == VAR)
			{
				VarDeclKind kind = cur.var_decl.kind;

				// In this case, we erase the value from parent scopes, so it isn't visible here.
				if (kind == ERASE) return null;
				if (kind == REWRAPPED) return cur.var_decl.alias_decl;
			}
			return cur;
		}
		current--;
	}
	return null;
}

// sema_name_resolution.c:541 (static)
fn bool sema_resolve_no_path_symbol(SemaContext* context, NameResolve* name_resolve)
{
	String symbol = name_resolve.symbol;
	assert(name_resolve.path == null);

	Decl* decl;

	if ((decl = sema_find_local(context, symbol)))
	{
		name_resolve.found = decl;
		return true;
	}

	CompilationUnit* unit = context.unit;

	// Search in file scope.
	if ((decl = (Decl*)htable_get(&unit.local_symbols, symbol.ptr)))
	{
		name_resolve.found = decl;
		return true;
	}

	// Search in the module.
	if ((decl = module_find_symbol(unit.mod, symbol)))
	{
		name_resolve.found = decl;
		return true;
	}

	if (!sema_find_decl_in_imports(context, name_resolve)) return false;
	if (name_resolve.found) return true;

	return sema_find_decl_in_global(context, &compiler.context.symbols, {}, name_resolve);
}

const int MAX_TEST = 256;
int[MAX_TEST][MAX_TEST] damerau_score @private;

// sema_name_resolution.c:578
fn int damerau_levenshtein_distance(String a, int a_len, String b, int b_len)
{
	if (!a_len) return b_len;
	if (!b_len) return a_len;
	if (a_len >= MAX_TEST || b_len >= MAX_TEST) return MAX_TEST;
	int[MAX_TEST][MAX_TEST]* score = &damerau_score;
	for (int i = 0; i <= a_len; i++) (*score)[i][0] = i;
	for (int i = 0; i <= b_len; i++) (*score)[0][i] = i;
	for (int i = 0; i < a_len; i++)
	{
		for (int j = 0; j < b_len; j++)
		{
			int cost = a[i] == b[j] ? 0 : 1;
			int del = (*score)[i][j + 1] + 1;
			int insert = (*score)[i + 1][j] + 1;
			int substitute = (*score)[i][j] + cost;
			int min = del < insert ? del : insert;
			(*score)[i + 1][j + 1] = min < substitute ? min : substitute;
			if (i > 0 && j > 0 && a[i] == b[j - 1] && a[i - 1] == b[j])
			{
				int comp = (*score)[i - 1][j - 1] + 1;
				if (comp < (*score)[i + 1][j + 1]) (*score)[i + 1][j + 1] = comp;
			}
		}
	}
	return (*score)[a_len][b_len];
}

// sema_name_resolution.c:608 (static)
fn void find_closest(String name, int name_len, Decl*[] decls, int* count_ref, Decl** matches, int* best_distance_ref)
{
	int best_distance = *best_distance_ref;
	int count = *count_ref;
	bool starts_at = name[0] == '@';
	Decl* at_match = null;
	foreach (decl : decls)
	{
		if (decl.visibility != PUBLIC || decl.decl_kind == ERASED) continue;
		String decl_name = decl.name;
		if (!starts_at && decl_name[0] == '@' && str_eq(decl_name[1..], name))
		{
			at_match = decl;
			continue;
		}
		int dist = damerau_levenshtein_distance(name, name_len, decl_name, (int)decl_name.len);
		if (dist < best_distance)
		{
			matches[0] = decl;
			best_distance = dist;
			count = 1;
			continue;
		}
		if (dist == best_distance && count < 3)
		{
			matches[count++] = decl;
		}
	}
	if (at_match)
	{
		if (count == 3)
		{
			matches[0] = at_match;
		}
		else
		{
			matches[count++] = at_match;
		}
	}
	*count_ref = count;
	*best_distance_ref = best_distance;
}

// sema_name_resolution.c:650 (static)
fn int module_closest_ident_names(Module* module_, String name, Decl** matches)
{
	matches[0] = matches[1] = matches[2] = null;

	int count = 0;
	int len = (int)name.len;
	int distance = max(1, (int)(len / 3));
	foreach (unit : module_.units)
	{
		find_closest(name, len, unit.functions, &count, matches, &distance);
		find_closest(name, len, unit.macros, &count, matches, &distance);
		find_closest(name, len, unit.vars, &count, matches, &distance);
	}
	return count;
}

// sema_name_resolution.c:666 (static)
fn void sema_report_error_on_decl(SemaContext* context, NameResolve* name_resolve)
{
	assert(!name_resolve.suppress_error);
	String symbol = name_resolve.symbol;
	SourceLocId loc = name_resolve.loc;
	Decl* found = name_resolve.found;
	String path_name = name_resolve.path ? name_resolve.path.module_name : (String){};
	if (!found && name_resolve.private_decl)
	{
		String private_name = decl_to_name(name_resolve.private_decl);
		if (path_name.ptr)
		{
			@sema_error_at(context, loc, "The %s '%s::%s' is '@private' and not visible from other modules.",
			               private_name, path_name,
			               symbol);
			return;
		}
		@sema_error_at(context, loc, "The %s '%s' in %s is '@private' and not visible from other modules.",
		               private_name, symbol, name_resolve.private_decl.unit.mod.name.module_name);
		return;
	}
	if (!found && name_resolve.maybe_decl)
	{
		Decl* decl = name_resolve.maybe_decl;
		Module* module_ = decl.unit.mod;
		String maybe_name = decl_to_name(decl);
		String module_name = module_.name.module_name;
		if (decl_is_visible(context.unit, decl) && decl.is_template && !name_resolve.is_parameterized)
		{
			@sema_error_at(context, loc, "Did you mean the %s generic '%s' in module %s? If so, use '%s{...}' instead.",
			               maybe_name, symbol, module_name, symbol);
			return;
		}
		if (path_name.ptr)
		{
			@sema_error_at(context, loc, "Did you mean the %s '%s::%s' in module %s? If so please add 'import %s'.",
			               maybe_name, module_name, symbol, module_name, module_name);
			return;
		}
		@sema_error_at(context, loc, "Did you mean the %s '%s' in module %s? If so please add 'import %s'.",
		               maybe_name, symbol, module_name, module_name);
		return;
	}

	if (name_resolve.ambiguous_other_decl)
	{
		assert(found);
		String symbol_type = decl_to_name(found);
		String found_path = found.unit.mod.name.module_name;
		String other_path = name_resolve.ambiguous_other_decl.unit.mod.name.module_name;
		if (path_name.ptr)
		{
			@sema_error_at(context, loc,
			               "The %s '%s::%s' is defined in both '%s' and '%s', "
			               "please use either %s::%s or %s::%s to resolve the ambiguity.",
			               symbol_type, path_name, symbol, found_path, other_path,
			               found_path, symbol, other_path, symbol);
		}
		else
		{
			if (decl_needs_prefix(found))
			{
				@sema_error_at(context, loc, "The %s needs a path prefix (e.g. '%s::%s').", symbol_type, found_path,
				               symbol);
				return;
			}
			@sema_error_at(context, loc,
			               "The %s '%s' is defined in both '%s' and '%s', please use either "
			               "%s::%s or %s::%s to resolve the ambiguity.",
			               symbol_type, symbol, found_path, other_path,
			               found_path, symbol, other_path, symbol);
		}
		return;
	}
	assert(!found);
	if (path_name.ptr)
	{
		// A common mistake is to type println and printfln
		if (name_resolve.path_found)
		{
			Decl*[3] closest;
			int matches = module_closest_ident_names(name_resolve.path_found, symbol, &closest);
			switch (matches)
			{
				case 1:
					@sema_error_at(context, loc, "'%s::%s' could not be found, did you perhaps want '%s::%s'?",
					               path_name, symbol, path_name, closest[0].name);
					return;
				case 2:
					@sema_error_at(context, loc, "'%s::%s' could not be found, did you perhaps want '%s::%s' or '%s::%s'?",
					               path_name, symbol, path_name, closest[0].name, path_name, closest[1].name);
					return;
				case 3:
					@sema_error_at(context, loc, "'%s::%s' could not be found, did you perhaps want '%s::%s', '%s::%s' or '%s::%s'?",
					               path_name, symbol, path_name, closest[0].name, path_name, closest[1].name,
					               path_name, closest[2].name);
					return;
				default:
					break;
			}
		}
		@sema_error_at(context, loc, "'%s::%s' could not be found, did you spell it right?", path_name, symbol);
		return;
	}
	if (!str_is_type(name_resolve.symbol))
	{
		Decl*[3] closest;
		int matches = module_closest_ident_names(context.unit.mod, symbol, &closest);
		switch (matches)
		{
			case 1:
				@sema_error_at(context, loc, "'%s' could not be found, did you perhaps want '%s'?", symbol, closest[0].name);
				return;
			case 2:
				@sema_error_at(context, loc, "'%s' could not be found, did you perhaps want '%s' or '%s'?",
				               symbol, closest[0].name, closest[1].name);
				return;
			case 3:
				@sema_error_at(context, loc, "'%s' could not be found, did you perhaps want '%s', '%s' or '%s'?",
				               symbol, closest[0].name, closest[1].name,
				               closest[2].name);
				return;
			default:
				break;
		}
	}
	@sema_error_at(context, loc, "'%s' could not be found, did you spell it right?", symbol);
}

// sema_name_resolution.c:795 (static)
fn Module* sema_module_matches_path(SemaContext* context, Module* module_, ModulePath* path)
{
	if (matches_subpath(module_.name, path))
	{
		foreach (imp : context.unit.imports)
		{
			Module* mod = module_;
			while (mod)
			{
				if (imp.import_decl.mod == mod)
				{
					return module_;
				}
				mod = mod.parent_module;
			}
		}
	}
	return null;
}

// sema_name_resolution.c:815 (static)
fn Module* sema_find_module_for_path(SemaContext* context, ModulePath* path)
{
	foreach (module_ : compiler.context.module_list)
	{
		Module* module_match = sema_module_matches_path(context, module_, path);
		if (module_match) return module_match;
	}
	return null;
}

// sema_name_resolution.c:825 (static)
fn bool sema_has_matching_generic_params(Decl* generic_instance, Decl* generic)
{
	assert(generic_instance.instance_decl.id != generic.generic_decl.id);
	GenericInstanceDecl* gen_instance_decl = &generic_instance.instance_decl;
	GenericDecl* gen_decl = &generic.generic_decl;
	if (gen_instance_decl.params.len != gen_decl.parameters.len) return false;
	foreach (i, param : gen_instance_decl.params)
	{
		String param_name = gen_decl.parameters[i];
		String param_name_other = param.name;
		bool is_constant_a = str_is_valid_constant(param_name);
		bool is_constant_b = str_is_valid_constant(param_name_other);
		if (is_constant_a != is_constant_b) return false;
	}
	return true;
}

// sema_name_resolution.c:841 (static)
fn bool sema_resolve_symbol_common(SemaContext* context, NameResolve* name_resolve)
{
	name_resolve.ambiguous_other_decl = null;
	name_resolve.private_decl = null;
	name_resolve.path_found = null;
	Decl* found = null;
	bool not_generic = false;
	if (name_resolve.path)
	{
		if (!sema_resolve_path_symbol(context, name_resolve)) return false;
		if (!name_resolve.found && !name_resolve.maybe_decl && !name_resolve.private_decl && !name_resolve.path_found)
		{
			if (name_resolve.suppress_error) return true;
			Module* module_with_path = sema_find_module_for_path(context, name_resolve.path);
			if (module_with_path)
			{
				return @sema_error_at(context, name_resolve.loc, "'%s' could not be found in %s.", name_resolve.symbol, module_with_path.name.module_name);
			}
			return @sema_error_at(context, name_resolve.loc, "'%s' could not be found, try importing the '%s' module.", name_resolve.symbol, name_resolve.path.module_name[:name_resolve.path.len]);
		}
	}
	else
	{
		// In a generic context, match parameters first of all.
		if (context.generic_instance)
		{
			foreach (param : context.generic_instance.instance_decl.params)
			{
				if (param.name.ptr == name_resolve.symbol.ptr)
				{
					found = name_resolve.found = param;
					if (name_resolve.is_parameterized)
					{
						not_generic = true;
						break;
					}
					return true;
				}
			}
		}
		if (!not_generic && !sema_resolve_no_path_symbol(context, name_resolve)) return false;
	}

	if (!not_generic)
	{
		found = name_resolve.found;
		if (!found || name_resolve.ambiguous_other_decl)
		{
			if (name_resolve.suppress_error)
			{
				name_resolve.found = null;
				return true;
			}
			sema_report_error_on_decl(context, name_resolve);
			return false;
		}
		if (found.is_if && context.call_env.in_if_resolution)
		{
			@sema_error_at(context, context.call_env.in_if_resolution, "This @if expression is dependent on '%s' which is also conditional.", found.name);
			@sema_note_prev_at(found.loc, "'%s' is defined here.", found.name);
			return false;
		}
		if (found.is_template)
		{
			if (name_resolve.is_parameterized) return true;
			Decl* generic = declptr(found.generic_id);
			if (context.generic_instance)
			{
				if (generic.generic_decl.id == context.generic_instance.instance_decl.id)
				{
					Decl* candidate = sema_find_generic_instance(context, found.unit.mod, generic, context.generic_instance, found.name);
					if (candidate)
					{
						name_resolve.found = candidate;
						return true;
					}
				}
			}
			else if (context.generic_infer)
			{
				if (context.generic_infer.instance_decl.id != generic.generic_decl.id)
				{
					if (!sema_has_matching_generic_params(context.generic_infer, generic))
					{
						if (name_resolve.suppress_error)
						{
							name_resolve.found = null;
							return true;
						}
						scratch_buffer_clear();
						foreach (name : generic.generic_decl.parameters)
						{
							@scratch_buffer_printf("%s, ", name);
						}
						scratch_buffer_delete(2);
						return @sema_error_at(context, name_resolve.loc, "Found '%s' in the module '%s', but it lacks parameters. Inferring parameter values does not work, since the inferred parameter list '%s' doesn't match parameter list '%s' which %s expects.", found.name, found.unit.mod.name.module_name, context.generic_infer.instance_decl.name_suffix, scratch_buffer_str(), found.name);
					}
					Decl* decl = sema_generate_parameterized_identifier(context, generic, found, {}, context.generic_infer.instance_decl.params,
						context.generic_infer.instance_decl.name_suffix, context.generic_infer.instance_decl.cname_suffix, name_resolve.loc, name_resolve.loc);
					if (!decl_ok(decl)) return false;
					assert(decl);
					name_resolve.found = decl;
					return true;
				}
				Decl* candidate = sema_find_generic_instance(context, found.unit.mod, generic, context.generic_infer, found.name);
				if (candidate)
				{
					name_resolve.found = candidate;
					return true;
				}
			}
			if (name_resolve.suppress_error)
			{
				name_resolve.found = null;
				return true;
			}
			if (context.generic_instance)
			{
				return @sema_error_at(context, name_resolve.loc, "'%s' is a generic %s. It was initialized in a generic context that didn't match its definition, so explicit parameters are needed.", found.name, decl_to_name(found));
			}
			return @sema_error_at(context, name_resolve.loc, "'%s' is a generic %s, did you forget the parameters '{ ... }'?", found.name, decl_to_name(found));
		}
		if (!name_resolve.is_parameterized) return true;
		if (name_resolve.suppress_error)
		{
			name_resolve.found = null;
			return true;
		}
	}
	// NOT_GENERIC:
	if (decl_is_user_defined_type(found)
		|| (found.decl_kind == VAR && (found.var_decl.kind == PARAM_CT_TYPE || found.var_decl.kind == LOCAL_CT_TYPE)))
	{
		if (name_resolve.is_generic_parent)
		{
			return @sema_error_at(context, name_resolve.loc, "'%s' is not a generic type.", name_resolve.symbol);
		}
		return @sema_error_at(context, name_resolve.loc, "'%s' is not a generic type. Did you want an initializer "
		                      "but forgot () around the type? That is, you typed '%s { ... }' but intended '(%s) { ... }'?",
		                      name_resolve.symbol, name_resolve.symbol, name_resolve.symbol);
	}
	if (name_resolve.is_generic_parent)
	{
		return @sema_error_at(context, name_resolve.loc, "'%s' is not a generic symbol.", name_resolve.symbol);
	}
	return @sema_error_at(context, name_resolve.loc, "Found '%s', but it is not generic so the { ... } after looks like a mistake?", found.name);
}

// sema_name_resolution.c:957
fn Decl* sema_find_extension_method_in_list(Decl*[] extensions, Type* type, String method_name)
{
	assert(type == type.canonical);
	foreach (extension : extensions)
	{
		if (extension.name.ptr != method_name.ptr) continue;
		if (decl_find_method_target(extension).type.canonical == type) return extension;
	}
	return null;
}

// sema_name_resolution.c:968
fn Decl* sema_resolve_method_only(Decl* type, String method_name)
{
	Methods* methods = type.method_table;
	Decl* found = null;
	if (methods)
	{
		found = declptrzero(decltable_get(&methods.method_table, method_name));
	}
	return found;
}

// sema_name_resolution.c:979
fn Decl* sema_resolve_method(Decl* type, String method_name)
{
	// Interface, prefer interface methods.
	bool is_interface = type.decl_kind == INTERFACE;
	if (is_interface)
	{
		foreach (method : type.interface_methods)
		{
			if (method_name.ptr == method.name.ptr) return method;
		}
	}

	Methods* methods = type.method_table;
	Decl* found = null;
	if (methods)
	{
		found = declptrzero(decltable_get(&methods.method_table, method_name));
	}
	return found;
}

// sema_name_resolution.c:1000
fn bool sema_check_type_variable_array(SemaContext* context, TypeInfo* type_info)
{
	if (!type_info_ok(type_info)) return false;
	Type* type = type_info.type;

	while (true)
	{
		type = type_flatten(type);
		switch (type.type_kind)
		{
			case POINTER:
				type = type.pointer;
				continue;
			case SLICE:
			case ARRAY:
			case FLEXIBLE_ARRAY:
			case INFERRED_ARRAY:
				type = type.array.base;
				continue;
			case STRUCT:
				break;
			default:
				unreachable();
		}
		break;
	}
	assert(type.type_kind == STRUCT);
	if (type.decl.has_variable_array)
	{
		@sema_error_at(context, type_info.loc, "Arrays of structs with flexible array members is not allowed.");
		return type_info_poison(type_info);
	}
	return true;
}

// sema_name_resolution.c:1035
fn bool sema_resolve_type_decl(SemaContext* context, Type* type)
{
	switch (type.type_kind)
	{
		case POISONED:
			return false;
		case WILDCARD:
		case VOID:
		case BOOL:
		case I8: case I16: case I32: case I64: case I128:
		case U8: case U16: case U32: case U64: case U128:
		case BF16: case F16: case F32: case F64: case F128:
		case VECTOR: case INFERRED_VECTOR: case SIMD_VECTOR:
		case ANYFAULT:
		case TYPEID:
		case POINTER:
		case FUNC_PTR:
		case TYPEINFO: case MEMBER: case REFLECTION:
		case SLICE:
		case ANY:
		case INTERFACE:
		case UNTYPEDLIST:
			return true;
		case OPTIONAL:
			return sema_resolve_type_decl(context, type.optional);
		case ALIAS:
			if (!sema_analyse_decl(context, type.decl)) return false;
			return sema_resolve_type_decl(context, type.canonical);
		case TYPEDEF:
			if (!sema_analyse_decl(context, type.decl)) return false;
			return sema_resolve_type_decl(context, type.decl.distinct.type);
		case FUNC_RAW:
			if (!type.function.prototype && type.function.decl.decl_kind == FNTYPE) return sema_analyse_decl(context, type.function.decl);
			return decl_ok(type.function.decl);
		case ENUM:
		case CONSTSET:
		case STRUCT:
		case UNION:
		case BITSTRUCT:
			return sema_analyse_decl(context, type.decl);
		case ARRAY:
		case FLEXIBLE_ARRAY:
		case INFERRED_ARRAY:
			return sema_resolve_type_decl(context, type.array.base);
	}
	unreachable();
}

// sema_name_resolution.c:1082
fn Decl* sema_resolve_type_method(SemaContext* context, CanonicalType* type, String method_name)
{
	while (true) // RETRY:
	{
		if (!type_is_user_defined(type))
		{
			Decl* found = declptrzero(methodtable_get(&compiler.context.method_extensions, type, method_name));
			if (found) return found;
			switch (type.type_kind)
			{
				case ARRAY:
					return declptrzero(methodtable_get(&compiler.context.method_extensions, type_get_inferred_array(type.array.base), method_name));
				case VECTOR:
				case SIMD_VECTOR:
					return declptrzero(methodtable_get(&compiler.context.method_extensions, type_get_inferred_vector(type.array.base), method_name));
				default:
					return null;
			}
		}
		if (!type_may_have_method(type)) return null;
		Decl* type_decl = type.decl;
		if (!decl_ok(type_decl)) return poisoned_decl;
		Methods* methods = type_decl.method_table;
		Decl* found = methods ? declptrzero(decltable_get(&methods.method_table, method_name)) : null;
		if (found) return found;
		if (type.type_kind == INTERFACE)
		{
			foreach (m : type_decl.interface_methods)
			{
				if (m.name.ptr == method_name.ptr) return m;
			}
		}
		if (!type_decl.is_substruct) return null;
		if (!sema_analyse_decl(context, type_decl)) return poisoned_decl;
		switch (type.type_kind)
		{
			case STRUCT:
				type = type_decl.strukt.members[0].type.canonical;
				continue;
			case TYPEDEF:
				type = type_decl.distinct.type.canonical;
				continue;
			case ENUM:
			case CONSTSET:
				type = enum_inner_type(type).canonical;
				continue;
			default:
				unreachable();
		}
	}
}

// sema_name_resolution.c:1131
fn Decl* sema_find_template_symbol(SemaContext* context, String symbol, ModulePath* path)
{
	NameResolve resolve = {
		.suppress_error = true,
		.symbol = symbol,
		.is_parameterized = true,
		.path = path,
	};
	if (!sema_resolve_symbol_common(context, &resolve)) return poisoned_decl;
	return resolve.found;
}

<* Silently find a symbol, will return NULL, Poison or the value *>
// sema_name_resolution.c:1145
fn Decl* sema_find_symbol(SemaContext* context, String symbol)
{
	NameResolve resolve = {
		.suppress_error = true,
		.symbol = symbol,
	};
	if (!sema_resolve_symbol_common(context, &resolve)) return poisoned_decl;
	return resolve.found;
}

// sema_name_resolution.c:1155
fn Decl* sema_find_label_symbol(SemaContext* context, String symbol)
{
	Decl*[] locals = context.locals;
	if (!locals.len || !context.active_scope.current_local) return null;
	long first = context.active_scope.label_start;
	long current = (long)context.active_scope.current_local - 1;
	while (current >= first)
	{
		Decl* cur = locals[current--];
		if (cur.name.ptr == symbol.ptr) return cur;
	}
	return null;
}

// sema_name_resolution.c:1169
fn Decl* sema_find_label_symbol_anywhere(SemaContext* context, String symbol)
{
	Decl*[] locals = context.locals;
	if (!locals.len || !context.active_scope.current_local) return null;
	long first = 0;
	long current = (long)context.active_scope.current_local - 1;
	while (current >= first)
	{
		Decl* cur = locals[current--];
		if (cur.name.ptr == symbol.ptr) return cur;
	}
	return null;
}

// sema_name_resolution.c:1183
fn BoolErr sema_symbol_is_defined_in_scope(SemaContext* c, String symbol)
{
	NameResolve resolve = {
		.suppress_error = true,
		.symbol = symbol,
	};
	if (!sema_resolve_symbol_common(c, &resolve)) return BOOL_ERR;
	// Unknown symbol => not defined
	Decl* found = resolve.found;
	if (!found) return BOOL_FALSE;
	// Defined in the same module => defined
	if (found.unit.mod == c.unit.mod) return BOOL_TRUE;
	// Not a variable or function => defined
	if (found.decl_kind != VAR && found.decl_kind != FUNC) return BOOL_TRUE;
	// Otherwise defined only if autoimport.
	return found.is_autoimport ? BOOL_TRUE : BOOL_FALSE;
}

// sema_name_resolution.c:1201
fn Decl* sema_find_path_symbol(SemaContext* context, String symbol, ModulePath* path)
{
	NameResolve resolve = {
		.suppress_error = true,
		.symbol = symbol,
		.path = path
	};
	if (!sema_resolve_symbol_common(context, &resolve)) return poisoned_decl;
	return resolve.found;
}

<* Resolves a symbol, return NULL if an error was found (and signalled), otherwise the decl. *>
// sema_name_resolution.c:1216
fn Decl* sema_resolve_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	NameResolve resolve = {
		.symbol = symbol,
		.path = path,
		.loc = loc
	};
	if (!sema_resolve_symbol_common(context, &resolve)) return null;
	Decl* found = resolve.found;
	assert(found);
	if (!decl_ok(found)) return null;
	return resolve.found;
}

<* Resolves a symbol, return NULL if an error was found (and signaled), otherwise the decl. *>
// sema_name_resolution.c:1234
fn Decl* sema_resolve_parameterized_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	NameResolve resolve = {
		.path = path,
		.loc = loc,
		.symbol = symbol,
		.is_parameterized = true
	};
	if (!sema_resolve_symbol_common(context, &resolve)) return null;
	Decl* found = resolve.found;
	assert(found);
	if (!decl_ok(found)) return null;
	return resolve.found;
}

<* Resolves a generic symbol, return NULL if an error was found (and signaled), otherwise the decl. *>
// sema_name_resolution.c:1253
fn Decl* sema_resolve_generic_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	NameResolve resolve = {
		.path = path,
		.loc = loc,
		.symbol = symbol,
		.is_parameterized = true,
		.is_generic_parent = true
	};
	if (!sema_resolve_symbol_common(context, &resolve)) return null;
	Decl* found = resolve.found;
	assert(found);
	if (!decl_ok(found)) return null;
	return resolve.found;
}

// sema_name_resolution.c:1269
fn Decl* sema_resolve_maybe_parameterized_symbol(SemaContext* context, String symbol, ModulePath* path, SourceLocId loc)
{
	NameResolve resolve = {
		.path = path,
		.loc = loc,
		.symbol = symbol,
		.is_parameterized = true,
		.suppress_error = true
	};
	if (!sema_resolve_symbol_common(context, &resolve)) return null;
	Decl* found = resolve.found;
	if (!decl_ok(found)) return null;
	return resolve.found;
}

// sema_name_resolution.c:1284
fn bool sema_parameterized_type_is_found(SemaContext* context, ModulePath* decl_path, String name, SourceLocId loc)
{
	NameResolve name_resolve = {
		.path = decl_path,
		.loc = loc,
		.symbol = name,
		.suppress_error = true,
		.is_parameterized = true
	};
	return sema_resolve_symbol_common(context, &name_resolve) && name_resolve.found;
}

// sema_name_resolution.c:1296 (static)
fn void sema_append_local(SemaContext* context, Decl* decl)
{
	assert(!decl_is_ct_var(decl));
	Decl*[]* locals = &context.locals;
	usz locals_size = (*locals).len;
	usz current_local = (usz)context.active_scope.current_local;
	if (locals_size <= current_local)
	{
		while (locals_size <= current_local)
		{
			@vec_add(locals, decl);
			locals_size++;
		}
	}
	else
	{
		(*locals)[current_local] = decl;
	}
	context.active_scope.current_local++;
}

// sema_name_resolution.c:1317 (static)
fn bool sema_add_ct_local(SemaContext* context, Decl* decl)
{
	assert(decl_is_ct_var(decl));

	Decl* other = sema_find_ct_local(context, decl.name);
	if (other && !(other.var_decl.defaulted && !other.var_decl.init_expr))
	{
		sema_shadow_error(context, decl, other);
		decl_poison(decl);
		decl_poison(other);
		return false;
	}
	decl.resolve_status = DONE;
	@vec_add(&context.ct_locals, decl);
	return true;
}

// sema_name_resolution.c:1334
fn bool sema_add_local(SemaContext* context, Decl* decl)
{
	CompilationUnit* current_unit = decl.unit = context.unit;

	// Ignore synthetic locals.
	if (!decl.name.ptr) return true;
	bool is_var = decl.decl_kind == VAR;
	if (is_var && decl_var_kind_is_ct(decl.var_decl.kind)) return sema_add_ct_local(context, decl);
	if (!(is_var && decl.var_decl.shadow))
	{
		Decl* other = sema_find_local(context, decl.name);
		if (other && (other.unit.mod == current_unit.mod || other.is_autoimport) && !decl_is_defaulted_var(other))
		{
			sema_shadow_error(context, decl, other);
			decl_poison(decl);
			decl_poison(other);
			return false;
		}
	}
	// ADD_VAR:
	if (decl.type || decl.decl_kind != VAR) decl.resolve_status = DONE;
	sema_append_local(context, decl);
	return true;
}

// sema_name_resolution.c:1359
fn void sema_unwrap_var(SemaContext* context, Decl* decl)
{
	Decl* alias_ = decl_copy(decl);
	alias_.var_decl.kind = UNWRAPPED;
	alias_.var_decl.alias_decl = decl;
	alias_.type = alias_.type.optional;
	alias_.resolve_status = DONE;
	sema_append_local(context, alias_);
}

// sema_name_resolution.c:1369
fn void sema_rewrap_var(SemaContext* context, Decl* decl)
{
	assert(decl.decl_kind == VAR && decl.var_decl.kind == UNWRAPPED && decl.var_decl.alias_decl.type.type_kind == OPTIONAL);
	sema_append_local(context, decl.var_decl.alias_decl);
}

// sema_name_resolution.c:1375
fn void sema_erase_var(SemaContext* context, Decl* decl)
{
	Decl* erased = decl_copy(decl);
	erased.var_decl.kind = ERASE;
	erased.resolve_status = DONE;
	sema_append_local(context, erased);
}

// sema_name_resolution.c:1384
fn void sema_erase_unwrapped(SemaContext* context, Decl* decl)
{
	assert(@is_optional(decl));
	Decl* rewrapped = decl_copy(decl);
	rewrapped.var_decl.kind = REWRAPPED;
	rewrapped.var_decl.alias_decl = decl;
	rewrapped.type = decl.type;
	rewrapped.resolve_status = DONE;
	sema_append_local(context, rewrapped);
}
