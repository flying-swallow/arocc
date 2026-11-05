// Tests for reusable symbol scopes and declaration lookup.
// Expected behavior is source-derived from src/aro/SymbolStack.zig; no Zig
// executable parity is claimed.
module symbol_stack_tests;
import aro::symbol_stack, aro::compilation, aro::type_store, aro::value, aro::tokens, aro::tokenizer, aro::string_interner;
import std::core::mem::allocators;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

struct SymbolRecorder
{
	SymbolDiag[16] diags;
	tokens::TokenIndex[16] toks;
	QualType[16] qt_a;
	QualType[16] qt_b;
	usz diag_len;
	NodeIndex[8] tentative_decl;
	NodeIndex[8] tentative_def;
	usz tentative_len;
	bool fail_diagnostics;
}

fn void? record_symbol_error(void* ctx, tokens::TokenIndex tok, SymbolDiag diag, QualType qt_a, QualType qt_b)
{
	SymbolRecorder* r = (SymbolRecorder*)ctx;
	usz i = r.diag_len;
	r.diags[i] = diag;
	r.toks[i] = tok;
	r.qt_a[i] = qt_a;
	r.qt_b[i] = qt_b;
	r.diag_len++;
	if (r.fail_diagnostics) return compilation::FATAL_ERROR~;
}

fn void record_tentative_link(void* ctx, NodeIndex decl, NodeIndex definition)
{
	SymbolRecorder* r = (SymbolRecorder*)ctx;
	usz i = r.tentative_len;
	r.tentative_decl[i] = decl;
	r.tentative_def[i] = definition;
	r.tentative_len++;
}

fn SymbolContext symbol_context(Compilation* comp, SymbolRecorder* r)
{
	return { .comp = comp, .ctx = r, .err = &record_symbol_error, .set_tentative_decl_definition = &record_tentative_link };
}

fn Symbol symbol(StringId name, SymbolKind kind, QualType qt = type_store::INT, uint tok = 0, uint node = 0)
{
	return { .name = name, .kind = kind, .qt = qt, .tok = tok, .node = (NodeIndex)node, .val = value::NONE };
}

fn void scope_shadowing_and_reuse() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		SymbolStack stack;
		stack.init(&ta);
		StringId x = comp.intern_string("x");
		stack.push_scope();
		stack.define(symbol(x, DEF, type_store::INT, 1, 11));
		stack.define(symbol(x, STRUCT, type_store::INT, 2, 12));
		assert(stack.find_symbol(x)!!.node == (NodeIndex)11);
		assert(stack.lookup(x, TAGS)!!.kind == STRUCT);

		stack.push_scope();
		stack.define(symbol(x, DEF, type_store::LONG, 3, 21));
		assert(stack.get(x, VARS)!!.node == (NodeIndex)21);
		assert(stack.lookup(x, VARS)!!.node == (NodeIndex)21);
		stack.pop_scope();
		assert(stack.lookup(x, VARS)!!.node == (NodeIndex)11);
		assert(stack.lookup(x, TAGS)!!.node == (NodeIndex)12);

		stack.push_scope(); // Reuses the popped scope, with its old entries cleared.
		assert(!@ok(stack.get(x, VARS)));
		assert(!@ok(stack.get(x, TAGS)));
		stack.define(symbol(x, DEF, type_store::LONG, 4, 31));
		assert(stack.lookup(x, VARS)!!.node == (NodeIndex)31);
		stack.pop_scope();
		stack.push_scope(); // Reusing the same nested scope clears its latest entries too.
		assert(stack.get(x, VARS) == NOT_DEFINED~);
		stack.pop_scope();
		stack.pop_scope();
		stack.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void typedef_and_tag_lookup() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		SymbolStack stack;
		stack.init(&ta);
		SymbolRecorder rec = {};
		SymbolContext ctx = symbol_context(&comp, &rec);
		StringId name = comp.intern_string("Item");
		stack.push_scope();
		stack.define(symbol(name, TYPEDEF, type_store::INT, 5, 50));
		Symbol found;
		assert(stack.find_typedef(&ctx, name, 6, false, &found)!!);
		assert(found.kind == TYPEDEF && found.node == (NodeIndex)50);

		StringId struct_name = comp.intern_string("Record");
		stack.define(symbol(struct_name, STRUCT, type_store::INT, 7, 70));
		assert(!stack.find_typedef(&ctx, struct_name, 8, true, &found)!!);
		assert(rec.diag_len == 0);
		assert(stack.find_typedef(&ctx, struct_name, 8, false, &found)!!);
		check(rec.diag_len, 1);
		assert(rec.diags[0] == MUST_USE_STRUCT && rec.toks[0] == 8);

		StringId nested = comp.intern_string("Nested");
		stack.define(symbol(nested, STRUCT, type_store::INT, 9, 90));
		stack.push_scope();
		assert(!stack.find_tag(&ctx, nested, KEYWORD_STRUCT, 10, SEMICOLON, &found)!!);
		assert(stack.find_tag(&ctx, nested, KEYWORD_STRUCT, 10, IDENTIFIER, &found)!!);
		assert(found.node == (NodeIndex)90);
		stack.define(symbol(nested, UNION, type_store::INT, 11, 91));
		assert(!stack.find_tag(&ctx, nested, KEYWORD_STRUCT, 12, IDENTIFIER, &found)!!);
		check(rec.diag_len, 3);
		assert(rec.diags[1] == WRONG_TAG && rec.toks[1] == 12);
		assert(rec.diags[2] == PREVIOUS_DEFINITION && rec.toks[2] == 11);

		StringId defined_tag = comp.intern_string("DefinedTag");
		assert(stack.define_tag(&ctx, defined_tag, tokenizer::KEYWORD_STRUCT, 13, &found) == false);
		stack.define(symbol(defined_tag, STRUCT, type_store::INT, 14, 140));
		assert(stack.define_tag(&ctx, defined_tag, tokenizer::KEYWORD_STRUCT, 15, &found)!!);
		assert(found.node == (NodeIndex)140);
		assert(stack.define_tag(&ctx, defined_tag, tokenizer::KEYWORD_UNION, 16, &found) == false);
		check(rec.diag_len, 5);
		assert(rec.diags[3] == WRONG_TAG && rec.toks[3] == 16);
		assert(rec.diags[4] == PREVIOUS_DEFINITION && rec.toks[4] == 14);
		stack.pop_scope();
		stack.pop_scope();
		stack.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void redeclarations_and_tentative_links() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		SymbolStack stack;
		stack.init(&ta);
		SymbolRecorder rec = {};
		SymbolContext ctx = symbol_context(&comp, &rec);
		StringId td = comp.intern_string("Alias");
		QualType alias_int = comp.type_store.put(type_store::type_typedef(type_store::INT, comp.intern_string("AliasInt"), (NodeIndex)0));
		stack.push_scope();
		assert(stack.define_typedef(&ctx, td, alias_int, 20, (NodeIndex)200)!!.is_null());
		QualType compatible_alias_int = comp.type_store.put(type_store::type_typedef(type_store::INT, comp.intern_string("CompatibleAliasInt"), (NodeIndex)0));
		NodeOptIndex same = stack.define_typedef(&ctx, td, compatible_alias_int, 21, (NodeIndex)201)!!;
		assert(!same.is_null() && same.unwrap() == (NodeIndex)200);
		QualType ptr_int = comp.type_store.put(type_store::type_pointer(type_store::INT));
		QualType alias_ptr_int = comp.type_store.put(type_store::type_typedef(ptr_int, comp.intern_string("AliasPtrInt"), (NodeIndex)0));
		stack.define_typedef(&ctx, td, alias_ptr_int, 22, (NodeIndex)202)!!;
		check(rec.diag_len, 2);
		assert(rec.diags[0] == REDEFINITION_OF_TYPEDEF && rec.toks[0] == 22);
		assert(rec.diags[1] == PREVIOUS_DEFINITION && rec.toks[1] == 21);
		assert(rec.qt_a[0] == ptr_int && rec.qt_b[0] == type_store::INT);

		StringId obj = comp.intern_string("object");
		stack.declare_symbol(&ctx, obj, type_store::INT, 30, (NodeIndex)300)!!;
		NodeOptIndex old = stack.define_symbol(&ctx, obj, type_store::INT, 31, (NodeIndex)301, value::NONE, false)!!;
		assert(!old.is_null() && old.unwrap() == (NodeIndex)300);
		check(rec.tentative_len, 1);
		assert(rec.tentative_decl[0] == (NodeIndex)300 && rec.tentative_def[0] == (NodeIndex)301);

		stack.pop_scope();
		stack.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void fatal_diagnostic_callback_propagates() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta);
		SymbolStack stack;
		stack.init(&ta);
		SymbolRecorder rec = { .fail_diagnostics = true };
		SymbolContext ctx = symbol_context(&comp, &rec);
		StringId name = comp.intern_string("x");
		stack.push_scope();
		stack.define(symbol(name, DEF, type_store::INT, 40, 400));
		fault failure = @catch(stack.define_symbol(&ctx, name, type_store::INT, 41, (NodeIndex)401, value::NONE, false));
		assert(failure == compilation::FATAL_ERROR);
		assert(stack.get(name, VARS)!!.node == (NodeIndex)400);
		check(rec.diag_len, 1);
		assert(rec.diags[0] == REDEFINITION && rec.toks[0] == 41);
		stack.pop_scope();
		stack.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
}
