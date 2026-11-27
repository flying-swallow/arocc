// Port of the interning half of c3c src/compiler/symtab.c (`symtab_init`'s
// keyword registration and `symtab_add`). Every identifier the lexer sees is
// interned once; a keyword's stored token type wins over the caller's guess,
// which is how c3c turns `fn`, `int`, `$if` ... into keyword tokens.
//
// Deviations from c3c:
// - Uses string_interner::StringTable (borrowed keys) plus an owned copy of
//   each new spelling instead of c3c's FNV bucket table; the returned String is
//   stable until `free`.
// - The builtin-define / kw_* identifier tables and `symtab_init` live in the
//   compiler module (compiler::symtab_init in symtab_globals.c3), on a global
//   Symtab, so this module stays standalone.
module aro::frontend::c3::symtab;
import aro::frontend::c3::tokens, aro::string_interner, std::collections::list, std::core::mem::alloc;

struct Symtab
{
	Allocator allocator;
	StringTable table;
	<* Token type per table index. *>
	List{TokenType} types;
}

fn void Symtab.init(&self, Allocator a)
{
	*self = { .allocator = a };
	self.table.init(a);
	self.types.init(a);
	for (usz i = (usz)tokens::FIRST_KEYWORD.ordinal; i <= (usz)tokens::LAST_KEYWORD.ordinal; i++)
	{
		TokenType kw = TokenType::values[i];
		TokenType type = kw;
		self.add(kw.text, &type);
		assert(type == kw);
	}
}

fn void Symtab.free(&self)
{
	foreach (key : self.table.key_slice()) alloc::free(self.allocator, key.ptr);
	self.table.free();
	self.types.free();
	*self = {};
}

<*
 c3c `symtab_add`: intern `name`. If it is already known, `*type` is replaced
 by the stored type (keywords); otherwise `*type` is stored with it.
*>
fn String Symtab.add(&self, String name, TokenType* type)
{
	if (try index = self.table.find(name))
	{
		*type = self.types[index];
		return self.table.key(index);
	}
	String copy = name.copy(self.allocator);
	uint index = self.table.get_or_put(copy);
	assert(index == self.types.len());
	self.types.push(*type);
	return copy;
}

<*
 c3c `symtab_find`: the interned spelling of `name` (and its stored type in
 `*type`), or an empty String with a null `ptr` when it was never added.
*>
fn String Symtab.find(&self, String name, TokenType* type)
{
	if (try index = self.table.find(name))
	{
		*type = self.types[index];
		return self.table.key(index);
	}
	return {};
}

<* Token type of an interned keyword, or `fallback` when `name` is not one. *>
fn TokenType Symtab.keyword(&self, String name, TokenType fallback)
{
	if (try index = self.table.find(name))
	{
		TokenType t = self.types[index];
		if (t.is_keyword()) return t;
	}
	return fallback;
}
