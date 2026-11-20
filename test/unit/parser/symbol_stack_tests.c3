// Tests for reusable symbol scopes and declaration lookup.
// Expected behavior is source-derived from src/aro/SymbolStack.zig; no Zig
// executable parity is claimed.
module symbol_stack_tests;
import aro::symbol_stack, aro::compilation, aro::diagnostics, aro::type_store, aro::value, aro::tokens, aro::tokenizer, aro::string_interner;
import aro::parser, aro::preprocessor, aro::source;
import std::core::mem::allocators, std::io;

excuse WRITE_FAILURE;

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

const uint TOKEN_COUNT = 64;

<* Parser over TOKEN_COUNT identifier tokens `a` (token i at column 2*i+1) that SymbolStack reports through. *>
struct SymbolFixture
{
	Diagnostics d;
	Compilation comp;
	Preprocessor pp;
	Parser p;
	TentativeRecorder tentative;
}

struct TentativeRecorder (IParserHandler)
{
	NodeIndex[8] decl;
	NodeIndex[8] def;
	usz len;
}

fn void TentativeRecorder.handle_tentative_decl_definition(&self, Parser* p, NodeIndex decl, NodeIndex definition) @dynamic
{
	self.decl[self.len] = decl;
	self.def[self.len] = definition;
	self.len++;
}

struct RejectWriter (OutStream) { char unused; }
fn sz? RejectWriter.write(&self, char[] bytes) @dynamic => WRITE_FAILURE~;
fn void? RejectWriter.write_byte(&self, char byte) @dynamic => WRITE_FAILURE~;
fn void? RejectWriter.flush(&self) @dynamic => WRITE_FAILURE~;

fn void SymbolFixture.init(&self, Allocator a, OutStream writer = null)
{
	if (writer) { self.d.init_writer(writer, diagnostics::ColorMode.NO_COLOR); } else { self.d.init_list(a); }
	self.comp.init(a, null, &self.d);
	char[] buf = alloc::new_array(tmem, char, TOKEN_COUNT * 2);
	for (uint i = 0; i < TOKEN_COUNT; i++) { buf[i * 2] = 'a'; buf[i * 2 + 1] = ' '; }
	Source src = self.comp.add_source_from_buffer("symbols.c", (String)buf)!!;
	self.pp.init(&self.comp, preprocessor::TESTING)!!;
	for (uint i = 0; i < TOKEN_COUNT; i++)
	{
		self.pp.add_token({ .id = IDENTIFIER, .loc = { .id = src.id, .byte_offset = i * 2, .line = 1 } })!!;
	}
	self.pp.tokens.push({ .id = EOF, .loc = source::UNUSED_LOCATION });
	self.p.init(&self.pp, &self.tentative);
	self.p.bind_finalized_tokens();
}

fn void SymbolFixture.free(&self)
{
	self.p.free();
	self.pp.free();
	self.comp.free();
	self.d.free();
}

<* Message `i` has `text` and is reported at token `tok`. *>
fn void SymbolFixture.expect(&self, sz i, String text, uint tok)
{
	test::eq(self.d.messages[i].text, text);
	check(self.d.messages[i].location.col, tok * 2 + 1);
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
		assert(stack.lookup_tag(x)!!.kind == STRUCT);

		stack.push_scope();
		stack.define(symbol(x, DEF, type_store::LONG, 3, 21));
		assert(stack.get_var(x)!!.node == (NodeIndex)21);
		assert(stack.lookup_var(x)!!.node == (NodeIndex)21);
		stack.pop_scope();
		assert(stack.lookup_var(x)!!.node == (NodeIndex)11);
		assert(stack.lookup_tag(x)!!.node == (NodeIndex)12);

		stack.push_scope(); // Reuses the popped scope, with its old entries cleared.
		assert(!@ok(stack.get_var(x)));
		assert(!@ok(stack.get_tag(x)));
		stack.define(symbol(x, DEF, type_store::LONG, 4, 31));
		assert(stack.lookup_var(x)!!.node == (NodeIndex)31);
		stack.pop_scope();
		stack.push_scope(); // Reusing the same nested scope clears its latest entries too.
		assert(@catch(stack.get_var(x)) == symbol_stack::NOT_DEFINED);
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
		SymbolFixture f;
		f.init(&ta);
		Compilation* comp = &f.comp;
		SymbolStack stack;
		stack.init(&ta);
		parser::Parser* p = &f.p;
		StringId name = comp.intern_string("Item");
		stack.push_scope();
		stack.define(symbol(name, TYPEDEF, type_store::INT, 5, 50));
		Symbol found;
		assert(stack.find_typedef(p, name, 6, false, &found)!!);
		assert(found.kind == TYPEDEF && found.node == (NodeIndex)50);

		StringId struct_name = comp.intern_string("Record");
		stack.define(symbol(struct_name, STRUCT, type_store::INT, 7, 70));
		assert(!stack.find_typedef(p, struct_name, 8, true, &found)!!);
		check(f.d.messages.len(), 0);
		assert(stack.find_typedef(p, struct_name, 8, false, &found)!!);
		check(f.d.messages.len(), 1);
		f.expect(0, "must use 'struct' tag to refer to type 'a'", 8);

		StringId nested = comp.intern_string("Nested");
		stack.define(symbol(nested, STRUCT, type_store::INT, 9, 90));
		stack.push_scope();
		assert(!stack.find_tag(p, nested, KEYWORD_STRUCT, 10, SEMICOLON, &found)!!);
		assert(stack.find_tag(p, nested, KEYWORD_STRUCT, 10, IDENTIFIER, &found)!!);
		assert(found.node == (NodeIndex)90);
		stack.define(symbol(nested, UNION, type_store::INT, 11, 91));
		assert(!stack.find_tag(p, nested, KEYWORD_STRUCT, 12, IDENTIFIER, &found)!!);
		check(f.d.messages.len(), 3);
		f.expect(1, "use of 'a' with tag type that does not match previous definition", 12);
		f.expect(2, "previous definition is here", 11);

		StringId defined_tag = comp.intern_string("DefinedTag");
		assert(stack.define_tag(p, defined_tag, tokenizer::TokenId.KEYWORD_STRUCT, 13, &found)!! == false);
		stack.define(symbol(defined_tag, STRUCT, type_store::INT, 14, 140));
		assert(stack.define_tag(p, defined_tag, tokenizer::TokenId.KEYWORD_STRUCT, 15, &found)!!);
		assert(found.node == (NodeIndex)140);
		assert(stack.define_tag(p, defined_tag, tokenizer::TokenId.KEYWORD_UNION, 16, &found)!! == false);
		check(f.d.messages.len(), 5);
		f.expect(3, "use of 'a' with tag type that does not match previous definition", 16);
		f.expect(4, "previous definition is here", 14);
		stack.pop_scope();
		stack.pop_scope();
		stack.free();
		f.free();
	}
	check(ta.allocation_count(), 0);
}

fn void redeclarations_and_tentative_links() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		SymbolFixture f;
		f.init(&ta);
		Compilation* comp = &f.comp;
		SymbolStack stack;
		stack.init(&ta);
		parser::Parser* p = &f.p;
		StringId td = comp.intern_string("Alias");
		QualType alias_int = comp.type_store.put(type_store::type_typedef(type_store::INT, comp.intern_string("AliasInt"), (NodeIndex)0));
		stack.push_scope();
		assert(stack.define_typedef(p, td, alias_int, 20, (NodeIndex)200)!!.is_null());
		QualType compatible_alias_int = comp.type_store.put(type_store::type_typedef(type_store::INT, comp.intern_string("CompatibleAliasInt"), (NodeIndex)0));
		NodeOptIndex same = stack.define_typedef(p, td, compatible_alias_int, 21, (NodeIndex)201)!!;
		assert(!same.is_null() && same.unwrap() == (NodeIndex)200);
		QualType ptr_int = comp.type_store.put(type_store::type_pointer(type_store::INT));
		QualType alias_ptr_int = comp.type_store.put(type_store::type_typedef(ptr_int, comp.intern_string("AliasPtrInt"), (NodeIndex)0));
		stack.define_typedef(p, td, alias_ptr_int, 22, (NodeIndex)202)!!;
		check(f.d.messages.len(), 2);
		f.expect(0, "typedef redefinition with different types ('int *' vs 'int')", 22);
		f.expect(1, "previous definition is here", 21);

		StringId obj = comp.intern_string("object");
		stack.declare_symbol(p, obj, type_store::INT, 30, (NodeIndex)300)!!;
		NodeOptIndex old = stack.define_symbol(p, obj, type_store::INT, 31, (NodeIndex)301, value::NONE, false)!!;
		assert(!old.is_null() && old.unwrap() == (NodeIndex)300);
		check(f.tentative.len, 1);
		assert(f.tentative.decl[0] == (NodeIndex)300 && f.tentative.def[0] == (NodeIndex)301);

		stack.pop_scope();
		stack.free();
		f.free();
	}
	check(ta.allocation_count(), 0);
}

fn void fatal_diagnostic_callback_propagates() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		RejectWriter reject = {};
		SymbolFixture f;
		f.init(&ta, &reject);
		Compilation* comp = &f.comp;
		SymbolStack stack;
		stack.init(&ta);
		parser::Parser* p = &f.p;
		StringId name = comp.intern_string("x");
		stack.push_scope();
		stack.define(symbol(name, DEF, type_store::INT, 40, 400));
		fault failure = @catch(stack.define_symbol(p, name, type_store::INT, 41, (NodeIndex)401, value::NONE, false));
		assert(failure == compilation::FATAL_ERROR);
		assert(stack.get_var(name)!!.node == (NodeIndex)400);
		check(f.d.errors, 1);
		stack.pop_scope();
		stack.free();
		f.free();
	}
	check(ta.allocation_count(), 0);
}
