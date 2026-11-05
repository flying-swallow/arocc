// Port of src/aro/SymbolStack.zig: reusable lexical scopes with separate
// ordinary ("vars") and tag (struct/union/enum) namespaces, shadowing,
// lookup and the define/declare checks — plan 16 stage 1 agent 16.6
// `symbols`.
//
// Deviations from Zig:
//  - Zig passes the whole `*Parser`; here every operation that can report a
//    diagnostic takes a `SymbolContext*` (compilation, an error callback and
//    the tentative-definition hook), so the stack works without a Parser.
//  - Zig `!?T` (error or null) returns `bool?` with the value in an out
//    parameter (`find_typedef`, `find_tag`, `define_tag`), or `NodeOptIndex?`
//    with NODE_NULL for null (`define_typedef`, `define_symbol`,
//    `declare_symbol`). Zig `?Symbol` returns `Symbol?` (fault NOT_DEFINED).
//  - Scopes are kept after `pop_scope` and cleared (capacity retained) when
//    re-pushed, as in Zig (`active_len`).
//  - Hash maps are keyed by `(uint)StringId`.
//
// Full port of the lexical scope and declaration conflict behavior.
module aro::symbol_stack;
import aro::compilation, aro::lang_opts, aro::string_interner, aro::tokens, aro::tokenizer, aro::type_store, aro::value;
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

<* Zig `ScopeKind`. *>
enum ScopeKind : char
{
	<* structs, enums, unions *>
	TAGS,
	<* everything else *>
	VARS,
}

<* Zig `Scope`: one hash map per namespace, keyed by `(uint)StringId`. *>
struct Scope
{
	HashMap{uint, Symbol} vars;
	HashMap{uint, Symbol} tags;
}

<*
 The Parser diagnostics SymbolStack.zig emits (Parser/Diagnostic.zig names).
 Arguments: the callback receives the token; templates that print
 `p.tokSlice(tok)` take it from the token, REDEFINITION_OF_TYPEDEF also
 takes the two typedef base types (`qt_a` new, `qt_b` previous).
*>
enum SymbolDiag : char
{
	MUST_USE_STRUCT,
	MUST_USE_UNION,
	MUST_USE_ENUM,
	WRONG_TAG,
	PREVIOUS_DEFINITION,
	REDEFINITION_OF_TYPEDEF,
	REDEFINITION_DIFFERENT_SYM,
	REDEFINITION_INCOMPATIBLE,
	REDEFINITION,
	REDEFINITION_OF_PARAMETER,
}

<* Zig `p.err(tok, diag, args)`; may fail with compilation::FATAL_ERROR. *>
alias SymbolErrFn = fn void? (void* ctx, tokens::TokenIndex tok, SymbolDiag diag, QualType qt_a, QualType qt_b);
<* Zig `p.setTentativeDeclDefinition(decl, definition)`. *>
alias SymbolTentativeFn = fn void (void* ctx, NodeIndex decl, NodeIndex definition);

<* What SymbolStack.zig needs from the Parser. *>
struct SymbolContext
{
	Compilation* comp;
	void* ctx;
	SymbolErrFn err;
	SymbolTentativeFn set_tentative_decl_definition;
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
	foreach (&scope : self.scopes) { scope.vars.free(); scope.tags.free(); }
	self.scopes.free();
	*self = {};
}

<* Zig `pushScope`: reuse (and clear) a retained scope, or append a new one. *>
fn void SymbolStack.push_scope(&self)
{
	if (self.active_len == self.scopes.len()) {
		Scope scope = {};
		scope.vars.init(self.gpa);
		scope.tags.init(self.gpa);
		self.scopes.push(scope);
	} else {
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
fn bool? SymbolStack.find_typedef(&self, SymbolContext* ctx, StringId name, tokens::TokenIndex name_tok, bool no_type_yet, Symbol* out)
{
	Symbol? found = self.lookup(name, VARS);
	if (!@ok(found)) found = self.lookup(name, TAGS);
	if (!@ok(found)) return false;
	Symbol prev = @unwrap(found);
	switch (prev.kind) {
		case TYPEDEF: *out = prev; return true;
		case STRUCT:
		case UNION:
		case ENUM:
			if (no_type_yet) return false;
			SymbolDiag d = prev.kind == STRUCT ? MUST_USE_STRUCT : prev.kind == UNION ? MUST_USE_UNION : MUST_USE_ENUM;
			ctx.err(ctx.ctx, name_tok, d, {}, {})!;
			*out = prev;
			return true;
		default: return false;
	}
}

<* Zig `findSymbol`: `lookup(name, VARS)`. *>
fn Symbol? SymbolStack.find_symbol(&self, StringId name)
{
	return self.lookup(name, VARS);
}

<*
 Zig `findTag`: `tag Name;` (next token SEMICOLON) only looks in the
 innermost scope, otherwise all scopes. A previous tag of the same keyword
 kind (KEYWORD_ENUM/STRUCT/UNION) is found; a mismatch in the innermost
 scope reports WRONG_TAG at `name_tok` and PREVIOUS_DEFINITION at the
 previous token; otherwise not found.
*>
fn bool? SymbolStack.find_tag(&self, SymbolContext* ctx, StringId name, TokenId kind, tokens::TokenIndex name_tok, TokenId next_tok_id, Symbol* out)
{
	Symbol? prev = next_tok_id == tokenizer::SEMICOLON ? self.get(name, TAGS) : self.lookup(name, TAGS);
	if (!@ok(prev)) return false;
	Symbol sym = @unwrap(prev);
	if ((sym.kind == ENUM && kind == tokenizer::KEYWORD_ENUM) || (sym.kind == STRUCT && kind == tokenizer::KEYWORD_STRUCT) || (sym.kind == UNION && kind == tokenizer::KEYWORD_UNION)) { *out = sym; return true; }
	if (!@ok(self.get(name, TAGS))) return false;
	ctx.err(ctx.ctx, name_tok, WRONG_TAG, {}, {})!;
	ctx.err(ctx.ctx, sym.tok, PREVIOUS_DEFINITION, {}, {})!;
	return false;
}

<* Zig `get`: `name` in the innermost scope's `kind` namespace. *>
fn Symbol? SymbolStack.get(&self, StringId name, ScopeKind kind)
{
	if (self.active_len == 0) return Symbol?;
	Scope* scope = &self.scopes[(sz)(self.active_len - 1)];
	return kind == VARS ? scope.vars.get((uint)name) : scope.tags.get((uint)name);
}

<* Zig `lookup`: `name` in the nearest active scope, starting at the innermost. *>
fn Symbol? SymbolStack.lookup(&self, StringId name, ScopeKind kind)
{
	usz i = self.active_len;
	while (i > 0) {
		i -= 1;
		Scope* scope = &self.scopes[(sz)i];
		Symbol? found = kind == VARS ? scope.vars.get((uint)name) : scope.tags.get((uint)name);
		if (@ok(found)) return found;
	}
	return Symbol?;
}

<*
 Zig `define`: put `symbol` in the innermost scope (CONSTEXPR/DEF/DECL/
 ENUMERATION/TYPEDEF in vars, STRUCT/UNION/ENUM in tags). No diagnostics.
*>
fn void SymbolStack.define(&self, Symbol symbol)
{
	assert(self.active_len > 0);
	Scope* scope = &self.scopes[(sz)(self.active_len - 1)];
	switch (symbol.kind) {
		case TYPEDEF:
		case ENUMERATION:
		case DECL:
		case DEF:
		case CONSTEXPR: scope.vars.put((uint)symbol.name, symbol);
		case STRUCT:
		case UNION:
		case ENUM: scope.tags.put((uint)symbol.name, symbol);
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
fn NodeOptIndex? SymbolStack.define_typedef(&self, SymbolContext* ctx, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node)
{
	NodeOptIndex old = type_store::NODE_NULL;
	if (try prev = self.get(name, VARS)) switch (prev.kind) {
		case TYPEDEF:
			if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, ctx.comp)) {
				if (qt.is_invalid()) return type_store::NODE_NULL;
				Type a = qt.get(ctx.comp, TYPEDEF)!;
				Type b = prev.qt.get(ctx.comp, TYPEDEF)!;
				ctx.err(ctx.ctx, tok, REDEFINITION_OF_TYPEDEF, a.type_def.base, b.type_def.base)!;
				if (prev.tok != 0) ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
			} else old = prev.node;
		case ENUMERATION:
		case DECL:
		case DEF:
		case CONSTEXPR:
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!;
			ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
		default: unreachable("invalid ordinary symbol kind");
	}
	self.define({ .kind = TYPEDEF, .name = name, .tok = tok, .qt = qt, .node = node, .val = {} });
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
fn NodeOptIndex? SymbolStack.define_symbol(&self, SymbolContext* ctx, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node, Value val, bool constexpr)
{
	NodeOptIndex old = type_store::NODE_NULL;
	if (try prev = self.get(name, VARS)) switch (prev.kind) {
		case ENUMERATION:
			if (qt.is_invalid()) return type_store::NODE_NULL;
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!;
			ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
		case DECL:
			if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, ctx.comp)) {
				if (qt.is_invalid()) return type_store::NODE_NULL;
				ctx.err(ctx.ctx, tok, REDEFINITION_INCOMPATIBLE, {}, {})!;
				ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
			} else { if (prev.node != type_store::NODE_NULL) ctx.set_tentative_decl_definition(ctx.ctx, prev.node, node); old = prev.node; }
		case DEF:
		case CONSTEXPR:
			if (!prev.qt.is_invalid()) { if (qt.is_invalid()) return type_store::NODE_NULL; ctx.err(ctx.ctx, tok, REDEFINITION, {}, {})!; ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!; }
		case TYPEDEF:
			if (qt.is_invalid()) return type_store::NODE_NULL;
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!;
			ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
	default: unreachable("invalid ordinary symbol kind");
	}
	self.define({ .kind = constexpr ? CONSTEXPR : DEF, .name = name, .tok = tok, .qt = qt, .node = node, .val = val });
	return old;
}

<* Zig `getPtr`: the named symbol in the innermost scope. @require the symbol exists *>
fn Symbol* SymbolStack.get_ptr(&self, StringId name, ScopeKind kind)
{
	Scope* scope = &self.scopes[(sz)(self.active_len - 1)];
	return kind == VARS ? scope.vars.get_ptr((uint)name)! : scope.tags.get_ptr((uint)name)!;
}

<*
 Zig `declareSymbol`: like define_symbol's checks but for a declaration
 (DECL: tentative link set_tentative_decl_definition(node, prev.node),
 returns prev.node; DEF/CONSTEXPR with compatible type: tentative link and
 returns NODE_NULL without defining). Defines a DECL symbol; for a function
 type declared in a nested scope before C23 also puts an `out_of_scope`
 copy in scope 0.
*>
fn NodeOptIndex? SymbolStack.declare_symbol(&self, SymbolContext* ctx, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node)
{
	NodeOptIndex old = type_store::NODE_NULL;
	if (try prev = self.get(name, VARS)) switch (prev.kind) {
		case ENUMERATION:
			if (qt.is_invalid()) return type_store::NODE_NULL;
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!;
			ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
		case DECL:
			if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, ctx.comp)) { if (qt.is_invalid()) return type_store::NODE_NULL; ctx.err(ctx.ctx, tok, REDEFINITION_INCOMPATIBLE, {}, {})!; ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!; }
			else { if (prev.node != type_store::NODE_NULL) ctx.set_tentative_decl_definition(ctx.ctx, node, prev.node); old = prev.node; }
		case DEF:
		case CONSTEXPR:
			if (!prev.qt.is_invalid() && !qt.eql_qualified(prev.qt, ctx.comp)) { if (qt.is_invalid()) return type_store::NODE_NULL; ctx.err(ctx.ctx, tok, REDEFINITION_INCOMPATIBLE, {}, {})!; ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!; }
			else { if (prev.node != type_store::NODE_NULL) ctx.set_tentative_decl_definition(ctx.ctx, node, prev.node); return type_store::NODE_NULL; }
		case TYPEDEF:
			if (qt.is_invalid()) return type_store::NODE_NULL;
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!;
			ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
	default: unreachable("invalid ordinary symbol kind");
	}
	self.define({ .kind = DECL, .name = name, .tok = tok, .qt = qt, .node = node, .val = {} });
	if (self.active_len > 1 && !ctx.comp.langopts.standard.at_least(C23) && qt.is(ctx.comp, FUNC))
		self.scopes[0].vars.put((uint)name, { .kind = DECL, .name = name, .tok = tok, .qt = qt, .node = node, .val = {}, .out_of_scope = true });
	return old;
}

<*
 Zig `defineParam`: previous ENUMERATION/DECL/DEF/CONSTEXPR with a valid
 type -> REDEFINITION_OF_PARAMETER and return without defining (unless the
 new type is invalid: return silently); TYPEDEF -> REDEFINITION_DIFFERENT_SYM
 (then still defines). Defines a DEF symbol.
*>
fn void? SymbolStack.define_param(&self, SymbolContext* ctx, StringId name, QualType qt, tokens::TokenIndex tok, NodeIndex node)
{
	if (try prev = self.get(name, VARS)) switch (prev.kind) {
		case ENUMERATION:
		case DECL:
		case DEF:
		case CONSTEXPR:
			if (!prev.qt.is_invalid()) { if (qt.is_invalid()) return; ctx.err(ctx.ctx, tok, REDEFINITION_OF_PARAMETER, {}, {})!; ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!; return; }
		case TYPEDEF:
			if (qt.is_invalid()) return;
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!;
			ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
		default: unreachable("invalid ordinary symbol kind");
	}
	self.define({ .kind = DEF, .name = name, .tok = tok, .qt = qt, .node = node, .val = {} });
}

<*
 Zig `defineTag`: a previous innermost tag of the same keyword kind is
 returned; a mismatch reports WRONG_TAG + PREVIOUS_DEFINITION and is not
 found; no previous tag is not found.
*>
fn bool? SymbolStack.define_tag(&self, SymbolContext* ctx, StringId name, TokenId kind, tokens::TokenIndex tok, Symbol* out)
{
	Symbol? got = self.get(name, TAGS);
	if (!@ok(got)) return false;
	Symbol prev = @unwrap(got);
	if ((prev.kind == ENUM && kind == tokenizer::KEYWORD_ENUM) || (prev.kind == STRUCT && kind == tokenizer::KEYWORD_STRUCT) || (prev.kind == UNION && kind == tokenizer::KEYWORD_UNION)) { *out = prev; return true; }
	ctx.err(ctx.ctx, tok, WRONG_TAG, {}, {})!;
	ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
	return false;
}

<*
 Zig `defineEnumeration`: previous ENUMERATION with valid type ->
 REDEFINITION (return); DECL/DEF/CONSTEXPR -> REDEFINITION_DIFFERENT_SYM
 (return); TYPEDEF -> REDEFINITION_DIFFERENT_SYM (still defines); an invalid
 new type returns silently. Defines an ENUMERATION symbol with `val`.
*>
fn void? SymbolStack.define_enumeration(&self, SymbolContext* ctx, StringId name, QualType qt, tokens::TokenIndex tok, Value val, NodeIndex node)
{
	if (try prev = self.get(name, VARS)) switch (prev.kind) {
		case ENUMERATION:
			if (!prev.qt.is_invalid()) { if (qt.is_invalid()) return; ctx.err(ctx.ctx, tok, REDEFINITION, {}, {})!; ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!; return; }
		case DECL:
		case DEF:
		case CONSTEXPR:
			if (qt.is_invalid()) return;
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!; ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!; return;
		case TYPEDEF:
			if (qt.is_invalid()) return;
			ctx.err(ctx.ctx, tok, REDEFINITION_DIFFERENT_SYM, {}, {})!; ctx.err(ctx.ctx, prev.tok, PREVIOUS_DEFINITION, {}, {})!;
		default: unreachable("invalid ordinary symbol kind");
	}
	self.define({ .kind = ENUMERATION, .name = name, .tok = tok, .qt = qt, .node = node, .val = val });
}
