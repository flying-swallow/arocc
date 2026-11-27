// Port of src/aro/SymbolStack.zig: reusable lexical scopes with separate
// ordinary ("vars") and tag (struct/union/enum) namespaces, shadowing,
// lookup and the define/declare checks — plan 16 stage 1 agent 16.6
// `symbols`.
//
// Deviations from Zig:
//  - Every operation that can report a diagnostic takes the `Parser*` (Zig
//    `p`); diagnostics go straight through `Diagnostic.@emit`, like Zig's
//    `p.err`.
//  - Zig `!?T` (error or null) returns `bool?` with the value in an out
//    parameter (`find_typedef`, `find_tag`, `define_tag`), or `NodeOptIndex?`
//    with NODE_NULL for null (`define_typedef`, `define_symbol`,
//    `declare_symbol`). Zig `?Symbol` returns `Symbol?` (fault NOT_DEFINED).
//  - Scopes are kept after `pop_scope` and cleared (capacity retained) when
//    re-pushed, as in Zig (`active_len`).
//  - Hash maps are keyed by `(uint)StringId`.
//
// Full port of the lexical scope and declaration conflict behavior.
module aro::frontend::c::symbol_stack;
import aro::frontend::c::diagnostics, aro::frontend::c::parser, aro::frontend::c::lang_opts, aro::string_interner, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::type_store, aro::frontend::c::value;
import std::collections::list, std::collections::map;

<* Zig `null` from `get` / `lookup` / `findSymbol`. *>
excuse NOT_DEFINED;

<* Zig `SymbolStack.Kind`. *>
enum SymbolKind : char
{
	TYPEDEF,
	STRUCT,
	UNION,
	ENUM,
	DECL,
	DEF,
	ENUMERATION,
	CONSTEXPR,
}

<* Zig `SymbolStack.Symbol`. Zig default: out_of_scope = false. *>
struct Symbol
{
	StringId name;
	QualType qt;
	tokens::TokenIndex tok;
	NodeIndex node;
	bool out_of_scope;
	SymbolKind kind;
	Value val;
}

<* Zig `Scope`: one hash map per namespace, keyed by `(uint)StringId`. *>
struct Scope
{
	HashMap{uint, Symbol} vars;
	HashMap{uint, Symbol} tags;
}

<* Zig `SymbolStack`. Create with `init`, release with `free`. *>
struct SymbolStack
{
	Allocator gpa;
	List{Scope} scopes;
	<* Scopes from nested levels are retained after popping; the number of active ones. *>
	usz active_len;
}

fn void SymbolStack.init(&self, Allocator gpa)
{
	*self = { .gpa = gpa };
	self.scopes.init(gpa);
}

<* Zig `deinit`. @require self.active_len == 0 : "all scopes should have been popped" *>
fn void SymbolStack.free(&self)
{
	assert(self.active_len == 0);
	foreach (&scope : self.scopes)
	{
		scope.vars.free(); scope.tags.free();
	}
	self.scopes.free();
	*self = {};
}

<* Zig `pushScope`: reuse (and clear) a retained scope, or append a new one. *>
fn void SymbolStack.push_scope(&self)
{
	if (self.active_len == (usz)self.scopes.len())
	{
		Scope scope = {};
		scope.vars.init(self.gpa);
		scope.tags.init(self.gpa);
		self.scopes.push(scope);
	} else
	{
		self.scopes[(sz)self.active_len].vars.clear();
		self.scopes[(sz)self.active_len].tags.clear();
	}
	self.active_len += 1;
}

<* Zig `popScope`. *>
fn void SymbolStack.pop_scope(&self)
{
	assert(self.active_len > 0);
	self.active_len -= 1;
}

<*
 Zig `findTypedef`: look `name` up in vars then tags. TYPEDEF -> found;
 STRUCT/UNION/ENUM -> not found if `no_type_yet`, else MUST_USE_STRUCT/
 UNION/ENUM at `name_tok` and found; anything else not found.
 Returns whether a symbol was found (stored in `*out`).
*>
fn bool? SymbolStack.find_typedef(&self, parser::Parser* p, StringId name, tokens::TokenIndex name_tok, bool no_type_yet, Symbol* out)
{
	Symbol? found = self.lookup_var(name);
	if (!@ok(found)) found = self.lookup_tag(name);
	if (!@ok(found)) return false;
	Symbol prev;
	if (try value = found)
	{
		prev = value;
	} else
	{
		return false;
	}
	switch (prev.kind)
	{
		case TYPEDEF: *out = prev; return true;
		case STRUCT:
		case UNION:
		case ENUM:
			if (no_type_yet) return false;
			switch (prev.kind)
			{
			case STRUCT: Diagnostic.MUST_USE_STRUCT.@emit(p, name_tok, p.tree.tok_slice(name_tok))!;
			case UNION: Diagnostic.MUST_USE_UNION.@emit(p, name_tok, p.tree.tok_slice(name_tok))!;
			default: Diagnostic.MUST_USE_ENUM.@emit(p, name_tok, p.tree.tok_slice(name_tok))!;
		}
		* out = prev;
		return true;
		default: return false;
	}
}

<* Zig `findSymbol`: `lookup_var(name)`. *>
fn Symbol? SymbolStack.find_symbol(&self, StringId name)
{
	return self.lookup_var(name);
}

<*
 Zig `findTag`: `tag Name;` (next token SEMICOLON) only looks in the
 innermost scope, otherwise all scopes. A previous tag of the same keyword
 kind (KEYWORD_ENUM/STRUCT/UNION) is found; a mismatch in the innermost
 scope reports WRONG_TAG at `name_tok` and PREVIOUS_DEFINITION at the
 previous token; otherwise not found.
*>
fn bool? SymbolStack.find_tag(&self, parser::Parser* p, StringId name, tokenizer::TokenId kind, tokens::TokenIndex name_tok, tokenizer::TokenId next_tok_id, Symbol* out)
{
	Symbol? prev = next_tok_id == tokenizer::TokenId.SEMICOLON ? self.get_tag(name) : self.lookup_tag(name);
	if (!@ok(prev)) return false;
	Symbol sym;
	if (try value = prev)
	{
		sym = value;
	} else
	{
		return false;
	}
	if ((sym.kind == ENUM && kind == tokenizer::TokenId.KEYWORD_ENUM) || (sym.kind == STRUCT && kind == tokenizer::TokenId.KEYWORD_STRUCT) || (sym.kind == UNION && kind == tokenizer::TokenId.KEYWORD_UNION))
	{
		*out = sym; return true;
	}
	if (!@ok(self.get_tag(name))) return false;
	Diagnostic.WRONG_TAG.@emit(p, name_tok, p.tree.tok_slice(name_tok))!;
	Diagnostic.PREVIOUS_DEFINITION.@emit(p, sym.tok)!;
	return false;
}

<* Zig `get(name, .vars)`: `name` in the innermost scope's ordinary namespace. *>
fn Symbol? SymbolStack.get_var(&self, StringId name)
{
	if (self.active_len == 0) return NOT_DEFINED~;
	if (try value = self.scopes[(sz)(self.active_len - 1)].vars.get((uint)name)) return value;
	return NOT_DEFINED~;
}

<* Zig `get(name, .tags)`: `name` in the innermost scope's tag namespace. *>
fn Symbol? SymbolStack.get_tag(&self, StringId name)
{
	if (self.active_len == 0) return NOT_DEFINED~;
	if (try value = self.scopes[(sz)(self.active_len - 1)].tags.get((uint)name)) return value;
	return NOT_DEFINED~;
}

<* Zig `lookup(name, .vars)`: `name` in the nearest active scope's ordinary namespace. *>
fn Symbol? SymbolStack.lookup_var(&self, StringId name)
{
	for (usz i = self.active_len; i > 0; i--)
	{
		if (try value = self.scopes[(sz)(i - 1)].vars.get((uint)name)) return value;
	}
	return NOT_DEFINED~;
}

<* Zig `lookup(name, .tags)`: `name` in the nearest active scope's tag namespace. *>
fn Symbol? SymbolStack.lookup_tag(&self, StringId name)
{
	for (usz i = self.active_len; i > 0; i--)
	{
		if (try value = self.scopes[(sz)(i - 1)].tags.get((uint)name)) return value;
	}
	return NOT_DEFINED~;
}

<*
 Zig `define`: put `symbol` in the innermost scope (CONSTEXPR/DEF/DECL/
 ENUMERATION/TYPEDEF in vars, STRUCT/UNION/ENUM in tags). No diagnostics.
*>
fn void SymbolStack.define(&self, Symbol symbol)
{
	assert(self.active_len > 0);
	Scope* scope = &self.scopes[(sz)(self.active_len - 1)];
	switch (symbol.kind)
	{
		case TYPEDEF:
		case ENUMERATION:
		case DECL:
		case DEF:
		case CONSTEXPR: scope.vars.set((uint)symbol.name, symbol);
		case STRUCT:
		case UNION:
		case ENUM: scope.tags.set((uint)symbol.name, symbol);
	}
}

<*
 Zig `defineTypedef`: against a previous innermost var: TYPEDEF with a
 different valid type -> (NODE_NULL if the new type is invalid)
 REDEFINITION_OF_TYPEDEF(new base, previous base) + PREVIOUS_DEFINITION
 (only if prev.tok != 0), same type -> returns prev.node;
 ENUMERATION/DECL/DEF/CONSTEXPR -> REDEFINITION_DIFFERENT_SYM +
 PREVIOUS_DEFINITION. Then defines the TYPEDEF symbol (val NONE).
*>
fn NodeOptIndex? SymbolStack.define_typedef(&self, parser::Parser* p, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node)
{
	NodeOptIndex old = type_store::NODE_NULL;
	if (try prev = self.get_var(name))
	{
		switch (prev.kind)
		{
			case TYPEDEF:
				if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, p.comp))
				{
					if (qt.is_invalid()) return type_store::NODE_NULL;
					Type a = qt.get_type(p.comp);
					Type b = prev.qt.get_type(p.comp);
					Diagnostic.REDEFINITION_OF_TYPEDEF.@emit(p, tok, p.fmt_qt(a.type_def.base), p.fmt_qt(b.type_def.base))!;
					if (prev.tok != 0) Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
				} else
				{
					old = (NodeOptIndex)prev.node;
				}
			case ENUMERATION:
			case DECL:
			case DEF:
			case CONSTEXPR:
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!;
				Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
			default: unreachable("invalid ordinary symbol kind");
		}
	}
	self.define(
		{
			.kind = TYPEDEF, .name = name, .tok = tok, .qt = qt, .node = node, .val = {}
		}
	);
	return old;
}

<*
 Zig `defineSymbol`: checks against a previous innermost var (see
 SymbolStack.zig: ENUMERATION/TYPEDEF -> REDEFINITION_DIFFERENT_SYM, DECL
 with incompatible type -> REDEFINITION_INCOMPATIBLE else
 set_tentative_decl_definition(prev.node, node) and return prev.node,
 DEF/CONSTEXPR with valid type -> REDEFINITION; an invalid new type returns
 NODE_NULL early), then defines a DEF or CONSTEXPR symbol with `val`.
*>
fn NodeOptIndex? SymbolStack.define_symbol(&self, parser::Parser* p, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node, Value val, bool constexpr)
{
	NodeOptIndex old = type_store::NODE_NULL;
	if (try prev = self.get_var(name))
	{
		switch (prev.kind)
		{
			case ENUMERATION:
				if (qt.is_invalid()) return type_store::NODE_NULL;
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!;
				Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
			case DECL:
				if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, p.comp))
				{
					if (qt.is_invalid()) return type_store::NODE_NULL;
					Diagnostic.REDEFINITION_INCOMPATIBLE.@emit(p, tok, p.tree.tok_slice(tok))!;
					Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
				} else
				{
					if ((NodeOptIndex)prev.node != type_store::NODE_NULL) p.declarations.set_tentative_definition(p, prev.node, node); old = (NodeOptIndex)prev.node;
				}
			case DEF:
			case CONSTEXPR:
				if (!prev.qt.is_invalid())
				{
					if (qt.is_invalid()) return type_store::NODE_NULL; Diagnostic.REDEFINITION.@emit(p, tok, p.tree.tok_slice(tok))!; Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
				}
			case TYPEDEF:
				if (qt.is_invalid()) return type_store::NODE_NULL;
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!;
				Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
			default: unreachable("invalid ordinary symbol kind");
		}
	}
	self.define(
		{
			.kind = constexpr ? CONSTEXPR : DEF, .name = name, .tok = tok, .qt = qt, .node = node, .val = val
		}
	);
	return old;
}

<* Zig `getPtr(name, .vars)`: the named ordinary symbol in the innermost scope. @require the symbol exists *>
fn Symbol* SymbolStack.get_var_ptr(&self, StringId name)
{
	return self.scopes[(sz)(self.active_len - 1)].vars.get_ref((uint)name)!!;
}

<*
 Zig `declareSymbol`: like define_symbol's checks but for a declaration
 (DECL: tentative link set_tentative_decl_definition(node, prev.node),
 returns prev.node; DEF/CONSTEXPR with compatible type: tentative link and
 returns NODE_NULL without defining). Defines a DECL symbol; for a function
 type declared in a nested scope before C23 also puts an `out_of_scope`
 copy in scope 0.
*>
fn NodeOptIndex? SymbolStack.declare_symbol(&self, parser::Parser* p, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node)
{
	NodeOptIndex old = type_store::NODE_NULL;
	if (try prev = self.get_var(name))
	{
		switch (prev.kind)
		{
			case ENUMERATION:
				if (qt.is_invalid()) return type_store::NODE_NULL;
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!;
				Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
			case DECL:
				if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, p.comp))
				{
					if (qt.is_invalid()) return type_store::NODE_NULL; Diagnostic.REDEFINITION_INCOMPATIBLE.@emit(p, tok, p.tree.tok_slice(tok))!; Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
				}
				else
				{
					if ((NodeOptIndex)prev.node != type_store::NODE_NULL) p.declarations.set_tentative_definition(p, node, prev.node); old = (NodeOptIndex)prev.node;
				}
			case DEF:
			case CONSTEXPR:
				if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, p.comp))
				{
					if (qt.is_invalid()) return type_store::NODE_NULL; Diagnostic.REDEFINITION_INCOMPATIBLE.@emit(p, tok, p.tree.tok_slice(tok))!; Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
				}
				else
				{
					if ((NodeOptIndex)prev.node != type_store::NODE_NULL) p.declarations.set_tentative_definition(p, node, prev.node); return type_store::NODE_NULL;
				}
			case TYPEDEF:
				if (qt.is_invalid()) return type_store::NODE_NULL;
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!;
				Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
			default: unreachable("invalid ordinary symbol kind");
		}
	}
	self.define(
		{
			.kind = DECL, .name = name, .tok = tok, .qt = qt, .node = node, .val = {}
		}
	);
	if (self.active_len > 1 && !p.comp.langopts.standard.at_least(C23) && qt.is(p.comp, FUNC))
	{
		self.scopes[0].vars.set((uint)name, { .kind = DECL, .name = name, .tok = tok, .qt = qt, .node = node, .val = {}, .out_of_scope = true });
	}
	return old;
}

<*
 Zig `defineParam`: previous ENUMERATION/DECL/DEF/CONSTEXPR with a valid
 type -> REDEFINITION_OF_PARAMETER and return without defining (unless the
 new type is invalid: return silently); TYPEDEF -> REDEFINITION_DIFFERENT_SYM
 (then still defines). Defines a DEF symbol.
*>
fn void? SymbolStack.define_param(&self, parser::Parser* p, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node)
{
	if (try prev = self.get_var(name))
	{
		switch (prev.kind)
		{
			case ENUMERATION:
			case DECL:
			case DEF:
			case CONSTEXPR:
				if (!prev.qt.is_invalid())
				{
					if (qt.is_invalid()) return; Diagnostic.REDEFINITION_OF_PARAMETER.@emit(p, tok, p.tree.tok_slice(tok))!; Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!; return;
				}
			case TYPEDEF:
				if (qt.is_invalid()) return;
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!;
				Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
			default: unreachable("invalid ordinary symbol kind");
		}
	}
	self.define(
		{
			.kind = DEF, .name = name, .tok = tok, .qt = qt, .node = node, .val = {}
		}
	);
}

<*
 Zig `defineTag`: a previous innermost tag of the same keyword kind is
 returned; a mismatch reports WRONG_TAG + PREVIOUS_DEFINITION and is not
 found; no previous tag is not found.
*>
fn bool? SymbolStack.define_tag(&self, parser::Parser* p, StringId name, tokenizer::TokenId kind, tokens::TokenIndex tok, Symbol* out)
{
	Symbol? got = self.get_tag(name);
	if (!@ok(got)) return false;
	Symbol prev;
	if (try value = got)
	{
		prev = value;
	} else
	{
		return false;
	}
	if ((prev.kind == ENUM && kind == tokenizer::TokenId.KEYWORD_ENUM) || (prev.kind == STRUCT && kind == tokenizer::TokenId.KEYWORD_STRUCT) || (prev.kind == UNION && kind == tokenizer::TokenId.KEYWORD_UNION))
	{
		*out = prev; return true;
	}
	Diagnostic.WRONG_TAG.@emit(p, tok, p.tree.tok_slice(tok))!;
	Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
	return false;
}

<*
 Zig `defineEnumeration`: previous ENUMERATION with valid type ->
 REDEFINITION (return); DECL/DEF/CONSTEXPR -> REDEFINITION_DIFFERENT_SYM
 (return); TYPEDEF -> REDEFINITION_DIFFERENT_SYM (still defines); an invalid
 new type returns silently. Defines an ENUMERATION symbol with `val`.
*>
fn void? SymbolStack.define_enumeration(&self, parser::Parser* p, StringId name, QualType qt, tokens::TokenIndex tok, Value val, NodeIndex node)
{
	if (try prev = self.get_var(name))
	{
		switch (prev.kind)
		{
			case ENUMERATION:
				if (!prev.qt.is_invalid())
				{
					if (qt.is_invalid()) return; Diagnostic.REDEFINITION.@emit(p, tok, p.tree.tok_slice(tok))!; Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!; return;
				}
			case DECL:
			case DEF:
			case CONSTEXPR:
				if (qt.is_invalid()) return;
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!; Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!; return;
			case TYPEDEF:
				if (qt.is_invalid()) return;
				Diagnostic.REDEFINITION_DIFFERENT_SYM.@emit(p, tok, p.tree.tok_slice(tok))!; Diagnostic.PREVIOUS_DEFINITION.@emit(p, prev.tok)!;
			default: unreachable("invalid ordinary symbol kind");
		}
	}
	self.define(
		{
			.kind = ENUMERATION, .name = name, .tok = tok, .qt = qt, .node = node, .val = val
		}
	);
}
