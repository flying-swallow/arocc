// Port of c3c src/compiler/context.c (compilation units, module naming,
// global symbol registration, imports) and src/compiler/module.c (module
// symbol lookup, path creation, module name mangling), plus `check_module_name`
// from compiler_internal.h.
//
// Not ported yet: context_is_macro (needs SemaContext).
//
// Deviations from c3c:
// - `goto SHADOW_LOCAL / WEAK_LOCAL / SHADOW_MODULE / WEAK_MODULE` in
//   `decl_register` become helper functions / flags with the same flow.
// - `unit_register_global_decl`'s `@feat` filtering calls sema
//   (`sema_retain_conditional_feat`), which is not ported: it aborts.
// - `error_exit` aborts. DEBUG_LOG calls are dropped. The local `import`
//   (a C3 keyword) is `imp`.
// - HTable keys are the interned name pointers (`name.ptr`).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens;

fn CompilationUnit* unit_create(SourceFile* file)
{
	CompilationUnit* unit = calloc_arena(CompilationUnit::size);
	unit.file = file;
	unit.is_interface_file = str_has_suffix(file.name, ".c3i");
	htable_init(&unit.local_symbols, 1024);
	return unit;
}

fn bool create_module_or_check_name(CompilationUnit* unit, ModulePath* module_name)
{
	Module* mod = unit.mod;
	if (!mod) mod = unit.mod = compiler_find_or_create_module(module_name);
	if (unit.mod.name.module_name.ptr != module_name.module_name.ptr)
	{
		@print_error_at(module_name.loc, "Module name here '%s' did not match actual module '%s'.", module_name.module_name, mod.name.module_name);
		return false;
	}
	@vec_add(&mod.units, unit);
	return true;
}

fn bool filename_to_module_in_buffer(String path)
{
	if (str_eq("<stdin>", path))
	{
		scratch_buffer_clear();
		scratch_buffer_append("stdin_file");
		return true;
	}
	int len = (int)path.len;
	int last_slash = 0;
	int last_dot = -1;
	for (int i = 0; i < len; i++)
	{
		if (path[i] == '/') last_slash = i;
		if (path[i] == '.') last_dot = i;
	}
	int name_len = last_dot - last_slash - 1;
	if (name_len < 1) return false;
	scratch_buffer_clear();
	bool last_was_underscore = true;
	for (int i = last_slash + 1; i < last_dot; i++)
	{
		char c = path[i];
		if (char_is_letter(c) || char_is_digit(c))
		{
			last_was_underscore = false;
			c = (char)(char_is_upper(c) ? c + 'a' - 'A' : c);
		}
		else
		{
			if (last_was_underscore) continue;
			c = '_';
			last_was_underscore = true;
		}
		scratch_buffer_append_char(c);
	}
	if (last_was_underscore && scratch_buffer_len()) scratch_buffer_delete(1);
	if (!scratch_buffer_len()) return false;
	return true;
}

fn bool context_set_module_from_filename(ParseContext* context)
{
	SourceFile* file = context.unit.file;
	if (!filename_to_module_in_buffer(file.full_path))
	{
		@error_exit("ERROR: The filename '%s' could not be converted to a valid module name, please rename it or use an explicit module name.", file.full_path);
	}

	TokenType type = IDENT;
	String module_name = scratch_buffer_interned_as(&type);
	if (type != IDENT)
	{
		@error_exit("ERROR: Generating a filename from the file '%s' resulted in a name that is a reserved keyword, please rename it or use an explicit module name.", file.full_path);
	}
	ModulePath* path = calloc_arena(ModulePath::size);
	path.loc = make_loc(context.span);
	path.module_name = module_name;
	path.len = (uint)scratch_buffer_len();
	return create_module_or_check_name(context.unit, path);
}

fn bool context_set_module(ParseContext* context, ModulePath* path)
{
	if (!check_module_name(path)) return false;
	return create_module_or_check_name(context.unit, path);
}

fn bool check_module_name(ModulePath* path)
{
	if (!str_is_valid_module_name(path.module_name))
	{
		@print_error_at(path.loc, "A module name may not have any uppercase characters, trailing, leading or double '_'");
		return false;
	}
	return true;
}

fn void weak_visibility_mismatch(Decl* weak_symbol, Decl* other_symbol)
{
	@print_error_at(weak_symbol.loc, "The weak symbol '%s' has another definition with a different, visibility.", weak_symbol.name);
	@sema_note_prev_at(other_symbol.loc, "The other definition was here.");
}

fn bool decl_old_should_be_removed(Decl* old, Decl* decl) => old.is_weak && !decl.is_weak;

fn void decl_register(CompilationUnit* unit, Decl* decl)
{
	if (decl.is_templated)
	{
		Decl* instance = declptr(decl.instance_id);
		foreach (other : instance.instance_decl.generated_decls)
		{
			if (other.name.ptr != decl.name.ptr) continue;
			if (other.visibility == LOCAL && decl.visibility == LOCAL && decl.unit != other.unit) continue;
			sema_shadow_error(null, decl, other);
			decl_poison(decl);
			decl_poison(other);
			return;
		}
		@vec_add(&declptr(decl.instance_id).instance_decl.generated_decls, decl);
		return;
	}

	Decl* old;
	Decl* replaced_symbol = null;
	old = htable_set(&unit.local_symbols, decl.name.ptr, decl);
	if (old)
	{
		bool shadow_local = old.decl_kind != decl.decl_kind;
		if (!shadow_local)
		{
			// If we have a weak symbol we can replace it
			if (decl_old_should_be_removed(old, decl))
			{
				// Visibility must match
				if (old.visibility != decl.visibility)
				{
					weak_visibility_mismatch(old, decl);
					return;
				}
				replaced_symbol = old;
				old.replacement = decl;
				@vec_add(&unit.weak_symbols_skipped, old);
			}
			else if (decl.is_weak)
			{
				// If the current is weak, but the other isn't we just ignore it.
				// But we must verify visibility matching.
				if (old.visibility != decl.visibility)
				{
					weak_visibility_mismatch(old, decl);
					return;
				}
				// We restore the old one
				htable_set(&unit.local_symbols, decl.name.ptr, old);
				decl.replacement = old;
				@vec_add(&unit.weak_symbols_skipped, decl);
				return;
			}
			else
			{
				shadow_local = true;
			}
		}
		if (shadow_local)
		{
			sema_shadow_error(null, decl, old);
			decl_poison(decl);
			decl_poison(old);
			return;
		}
	}
	// WEAK_LOCAL:
	old = htable_set(&unit.mod.symbols, decl.name.ptr, decl);
	if (old)
	{
		if (old.visibility == LOCAL && decl.visibility == LOCAL) return;
		bool shadow_module = old.decl_kind != decl.decl_kind;
		if (!shadow_module)
		{
			// If we have a weak symbol we can replace it
			if (decl_old_should_be_removed(old, decl))
			{
				// Visibility must match
				if (old.visibility != decl.visibility)
				{
					weak_visibility_mismatch(old, decl);
					return;
				}
				// If we already replaced a weak symbol, it must be the same one!
				if (replaced_symbol) assert(replaced_symbol == old);
				if (!replaced_symbol) @vec_add(&old.unit.weak_symbols_skipped, old);
				replaced_symbol = old;
				old.replacement = decl;
				if (unit != old.unit)
				{
					// We need to pretend the weak symbol is this symbol in the local scope.
					htable_set(&old.unit.local_symbols, old.name.ptr, decl);
				}
			}
			else if (decl.is_weak)
			{
				// If the current is weak, but the other isn't we just ignore it.
				// But we must verify visibility matching.
				if (old.visibility != decl.visibility)
				{
					weak_visibility_mismatch(old, decl);
					return;
				}
				// We restore the old one
				decl.replacement = old;
				@vec_add(&unit.weak_symbols_skipped, decl);
				htable_set(&unit.mod.symbols, decl.name.ptr, old);
				// Pretend the old is this in the local symbol scope
				htable_set(&unit.local_symbols, decl.name.ptr, old);
				return;
			}
			else
			{
				shadow_module = true;
			}
		}
		if (shadow_module)
		{
			if (old.visibility == LOCAL)
			{
				sema_shadow_error(null, old, decl);
			}
			else
			{
				sema_shadow_error(null, decl, old);
			}
			decl_poison(decl);
			decl_poison(old);
			return;
		}
	}
	// WEAK_MODULE:
	if (decl.visibility < LOCAL)
	{
		switch (decl.decl_kind)
		{
			case ERASED:
			case ALIAS_PATH:
			case BODYPARAM:
			case CT_ASSERT:
			case CT_ECHO:
			case CT_EXEC:
			case CT_EXPAND:
			case CT_INCLUDE:
			case DECLARRAY:
			case ENUM_CONSTANT:
			case GROUP:
			case GENERIC:
			case GENERIC_INSTANCE:
			case IMPORT:
			case LABEL:
			case POISONED:
			case CONTRACT:
				unreachable();
			case ATTRIBUTE:
			case BITSTRUCT:
			case TYPEDEF:
			case ENUM:
			case CONSTSET:
			case STRUCT:
			case TYPE_ALIAS:
			case UNION:
			case ALIAS:
			case FUNC:
			case MACRO:
			case VAR:
			case FNTYPE:
			case INTERFACE:
			case FAULT:
				if (replaced_symbol)
				{
					global_context_replace_decl(replaced_symbol, decl);
					break;
				}
				global_context_add_decl(decl);
		}
	}
}

fn void unit_register_global_decl(CompilationUnit* unit, Decl* decl)
{
	assert(!decl.is_template);
	assert(!decl.unit || decl.is_templated);
	if (decl.is_feat_cond)
	{
		// c3c: switch (sema_retain_conditional_feat(decl->attributes)) -- sema, not ported yet.
		unreachable("sema_retain_conditional_feat is not ported yet");
	}
	decl.unit = unit;
	switch (decl.decl_kind)
	{
		case ERASED:
			return;
		case POISONED:
			break;
		case MACRO:
			assert(decl.name.ptr != null);
			TypeInfo* parent = decl_find_target_if_method(decl);
			if (parent)
			{
				@vec_add(&unit.methods_to_register, decl);
				return;
			}
			@vec_add(&unit.macros, decl);
			decl_register(unit, decl);
			return;
		case FUNC:
			assert(decl.name.ptr != null);
			if (decl.func_decl.type_parent)
			{
				@vec_add(&unit.methods_to_register, decl);
				return;
			}
			@vec_add(&unit.functions, decl);
			decl_register(unit, decl);
			return;
		case VAR:
			assert(decl.name.ptr != null);
			@vec_add(&unit.vars, decl);
			decl_register(unit, decl);
			return;
		case INTERFACE:
		case TYPEDEF:
		case STRUCT:
		case UNION:
		case TYPE_ALIAS:
		case BITSTRUCT:
			assert(decl.name.ptr != null);
			@vec_add(&unit.types, decl);
			decl_register(unit, decl);
			return;
		case FAULT:
			assert(decl.name.ptr != null);
			@vec_add(&unit.faults, decl);
			decl_register(unit, decl);
			return;
		case ALIAS:
			assert(decl.name.ptr != null);
			@vec_add(&unit.aliases, decl);
			decl_register(unit, decl);
			return;
		case CONSTSET:
		case ENUM:
			assert(decl.name.ptr != null);
			@vec_add(&unit.enums, decl);
			decl_register(unit, decl);
			return;
		case ATTRIBUTE:
			@vec_add(&unit.attributes, decl);
			decl_register(unit, decl);
			return;
		case ALIAS_PATH:
		case BODYPARAM:
		case DECLARRAY:
		case ENUM_CONSTANT:
		case FNTYPE:
		case GROUP:
		case GENERIC:
		case GENERIC_INSTANCE:
		case IMPORT:
		case LABEL:
		case CONTRACT:
			unreachable();
		case CT_EXEC:
		case CT_INCLUDE:
		case CT_EXPAND:
			@vec_add(&unit.ct_includes, decl);
			return;
		case CT_ECHO:
			@vec_add(&unit.ct_echos, decl);
			return;
		case CT_ASSERT:
			@vec_add(&unit.ct_asserts, decl);
			return;
	}
}

fn bool unit_add_import(CompilationUnit* unit, ModulePath* path, bool private_import, bool is_non_recursive)
{
	if (!check_module_name(path)) return false;

	Decl* imp = decl_calloc();
	imp.loc = path.loc;
	imp.decl_kind = IMPORT;
	imp.import_decl.path = path;
	imp.import_decl.import_private_as_public = private_import;
	imp.import_decl.is_non_recurse = is_non_recursive;
	@vec_add(&unit.imports, imp);
	if (private_import) @vec_add(&unit.public_imports, imp);
	return true;
}

fn bool unit_add_alias(CompilationUnit* unit, Decl* alias_)
{
	if (!check_module_name(alias_.module_alias_decl.alias_path)) return false;
	@vec_add(&unit.module_aliases, alias_);
	return true;
}

// ---------------------------------------------------------------------------
// module.c

fn Decl* module_find_symbol(Module* mod, String symbol)
{
	Decl* decl = htable_get(&mod.symbols, symbol.ptr);
	return decl && decl.visibility != LOCAL ? decl : null;
}

fn Decl* module_find_symbol_in_unit(Module* mod, CompilationUnit* unit, String symbol)
{
	Decl* decl = htable_get(&unit.local_symbols, symbol.ptr);
	if (decl) return decl;
	return module_find_symbol(mod, symbol);
}

fn void scratch_buffer_append_module(Module* mod, bool is_export)
{
	if (mod.extname.ptr)
	{
		scratch_buffer_append(mod.extname);
		return;
	}
	String name = mod.name.module_name;
	usz i = 0;
	while (i < name.len)
	{
		char c = name[i++];
		switch (c)
		{
			case ':':
				assert(name[i] == ':');
				scratch_buffer_append_char(is_export ? '_' : '.');
				i++;
			case '.':
				if (is_export)
				{
					scratch_buffer_append_char('_');
					break;
				}
				scratch_buffer_append_char(c);
			default:
				scratch_buffer_append_char(c);
		}
	}
}

fn String module_create_object_file_name(Module* mod)
{
	scratch_buffer_clear();
	String name = mod.name.module_name;
	usz i = 0;
	while (i < name.len)
	{
		char c = name[i++];
		switch (c)
		{
			case '$':
				if (i < name.len && name[i] == '$') i++;
				if (i < name.len) scratch_buffer_append_char('.');
			case ':':
				if (i < name.len && name[i] == ':') i++;
				if (i < name.len) scratch_buffer_append_char('.');
			default:
				scratch_buffer_append_char(c);
		}
	}
	if (scratch_buffer_len() > 128)
	{
		scratch_buffer_set_len(128);
		@scratch_buffer_printf("@%X", (uptr)mod);
	}
	return scratch_buffer_str();
}

fn ModulePath* path_create_from_string(String string, uint len, SourceLocId loc)
{
	assert(string.ptr != null);
	ModulePath* path = calloc_arena(ModulePath::size);
	path.loc = loc;
	TokenType type = IDENT;
	path.module_name = symtab_add(string[:len], &type);
	path.len = len;
	if (type != IDENT)
	{
		@print_error_at(path.loc, "A module name was expected here.");
		return null;
	}
	return path;
}
