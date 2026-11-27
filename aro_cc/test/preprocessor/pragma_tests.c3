// Focused contract tests for the compilation-owned pragma registry.
module pragma_tests;
import aro::frontend::c::pragma;
import aro::frontend::c::preprocessor, aro::frontend::c::tokens, aro::frontend::c::compilation, aro::source;
import aro::frontend::c::diagnostics;
import aro::frontend::c::pragmas::pack;
import aro::frontend::c::pragmas::gcc;
import aro::frontend::c::pragmas::once;
import aro::frontend::c::pragmas::message;
import aro::frontend::c::tokenizer;
import aro::frontend::c::parser;
import aro::frontend::c::tree;
import aro::target;
import aro::frontend::c::type_store;
import std::core::mem::allocators;
const target::Host TEST_HOST = { target::Arch.X86_64, target::OsTag.LINUX, target::Abi.GNU };

macro check(left, right)
{
	test::eq((long)left, (long)right);
}

struct CallbackState
{
	uint preprocess_calls;
	uint lifecycle_calls;
	tokens::TokenIndex last_start;
	char order;
	bool skip_include;
	bool preserve;
	uint include_calls;
	uint parse_calls;
	uint after_parse_calls;
	uint destroy_calls;
	pragma::IncludePragmaResult include_result;
}

struct ResultState { pragma::PragmaResult result; }

fn pragma::PragmaResult selected_result(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx)
=> ((ResultState*)ctx).result;

fn pragma::PragmaResult unknown_preprocess(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx)
{
	CallbackState* state = (CallbackState*)ctx;
	state.preprocess_calls += 1;
	state.last_start = start_idx;
	return pragma::PragmaResult.UNKNOWN;
}

fn pragma::PragmaResult handled_preprocess(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx)
{
	CallbackState* state = (CallbackState*)ctx;
	state.preprocess_calls += 1;
	state.last_start = start_idx;
	return pragma::PragmaResult.HANDLED;
}

fn void before_preprocess(void* ctx, compilation::Compilation* comp)
{
	CallbackState* state = (CallbackState*)ctx;
	state.lifecycle_calls += 1;
	state.order = (char)(state.order * 10 + state.lifecycle_calls);
}

fn pragma::IncludePragmaResult before_include(void* ctx, preprocessor::Preprocessor* pp, source::Source src)
{
	CallbackState* state = (CallbackState*)ctx;
	state.include_calls++;
	if (state.include_result == pragma::IncludePragmaResult.FATAL) return pragma::IncludePragmaResult.FATAL;
	return state.skip_include ? pragma::IncludePragmaResult.SKIP_INCLUDE : state.include_result;
}

fn void before_parse(void* ctx, compilation::Compilation* comp)
{
	((CallbackState*)ctx).parse_calls++;
}

fn void after_parse(void* ctx, compilation::Compilation* comp)
{
	((CallbackState*)ctx).after_parse_calls++;
}

fn void destroy(void* ctx, compilation::Compilation* comp)
{
	((CallbackState*)ctx).destroy_calls++;
}

fn bool preserve_tokens(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx)
{
	return ((CallbackState*)ctx).preserve;
}

alias PreprocessFn = fn pragma::PragmaResult(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx);
alias LifecycleFn = fn void(void* ctx, compilation::Compilation* comp);
alias IncludeFn = fn pragma::IncludePragmaResult(void* ctx, preprocessor::Preprocessor* pp, source::Source src);
alias PreserveFn = fn bool(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx);

<* IPragma over the test callbacks; a null callback behaves like a missing method. *>
struct CallbackPragma (pragma::IPragma)
{
	void* ctx;
	PreprocessFn preprocess_fn;
	IncludeFn include_fn;
	LifecycleFn before_preprocess_fn;
	LifecycleFn before_parse_fn;
	LifecycleFn after_parse_fn;
	LifecycleFn destroy_fn;
	PreserveFn preserve_fn;
}

fn pragma::PragmaResult CallbackPragma.preprocessor_handler(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic
	=> self.preprocess_fn ? self.preprocess_fn(self.ctx, pp, start_idx) : pragma::PragmaResult.UNKNOWN;
fn pragma::IncludePragmaResult CallbackPragma.before_include(&self, preprocessor::Preprocessor* pp, source::Source src) @dynamic
	=> self.include_fn ? self.include_fn(self.ctx, pp, src) : pragma::IncludePragmaResult.CONTINUE;
fn void CallbackPragma.before_preprocess(&self, compilation::Compilation* comp) @dynamic
{
	if (self.before_preprocess_fn) self.before_preprocess_fn(self.ctx, comp);
}
fn void CallbackPragma.before_parse(&self, compilation::Compilation* comp) @dynamic
{
	if (self.before_parse_fn) self.before_parse_fn(self.ctx, comp);
}
fn void CallbackPragma.after_parse(&self, compilation::Compilation* comp) @dynamic
{
	if (self.after_parse_fn) self.after_parse_fn(self.ctx, comp);
}
fn void CallbackPragma.deinit(&self, compilation::Compilation* comp) @dynamic
{
	if (self.destroy_fn) self.destroy_fn(self.ctx, comp);
}
fn bool CallbackPragma.preserve_tokens(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic
	=> self.preserve_fn ? self.preserve_fn(self.ctx, pp, start_idx) : true;

fn CallbackPragma handler(void* state, PreprocessFn preprocess_fn, LifecycleFn lifecycle_fn = null)
	=> { .ctx = state, .preprocess_fn = preprocess_fn, .before_preprocess_fn = lifecycle_fn };

fn void registration_dispatch_and_handled_lookup() @test
{
	Registry registry;
	registry.init(mem);
	CallbackState first = {};
	CallbackState second = {};
	CallbackState third = {};
	CallbackPragma first_handler = handler(&first, &unknown_preprocess);
	CallbackPragma second_handler = handler(&second, &handled_preprocess);
	CallbackPragma third_handler = handler(&third, &handled_preprocess);
	bool added_first = registry.add("first", &first_handler);
	assert(added_first);
	bool added_second = registry.add("second", &second_handler);
	assert(added_second);
	bool duplicate_added = registry.add("first", &third_handler);
	assert(!duplicate_added);
	assert(@ok(registry.get("first")));
	assert(!@ok(registry.get("missing")));

	IPragma registered = registry.get("second")!!;
	PragmaResult result = registered.preprocessor_handler(null, 37);
	check(result, PragmaResult.HANDLED);
	check(second.preprocess_calls, 1);
	check(second.last_start, 37);
	check(first.preprocess_calls, 0);

	bool added_third = registry.add("third", &third_handler);
	assert(added_third);
	registered = registry.get("third")!!;
	result = registered.preprocessor_handler(null, 41);
	check(result, PragmaResult.HANDLED);
	check(first.preprocess_calls, 0);
	check(second.preprocess_calls, 1);
	check(third.preprocess_calls, 1);
	check(third.last_start, 41);
	registry.free(null);
}

fn void compilation_registry_repeats_parse_callbacks_and_destroys_once() @test
{
	Compilation comp;
	comp.init(mem, compilation::native_definition());
	CallbackState state = {};
	CallbackPragma h = handler(&state, null);
	h.before_parse_fn = &before_parse;
	h.after_parse_fn = &after_parse;
	h.destroy_fn = &destroy;
	bool added_lifecycle = comp.pragmas.add("lifecycle", &h);
	assert(added_lifecycle);

	// The parser module is not ported yet; exercise the Compilation-owned
	// lifecycle dispatch contract and registry-owned destruction directly.
	comp.pragmas.before_parse(&comp);
	comp.pragmas.after_parse(&comp);
	comp.pragmas.before_parse(&comp);
	comp.pragmas.after_parse(&comp);
	check(state.parse_calls, 2);
	check(state.after_parse_calls, 2);
	comp.free();
	check(state.destroy_calls, 1);
}

fn void gcc_diagnostic_state_resets_and_replays_per_parse() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		comp.target = target::parse_triple("x86_64-linux-gnu", TEST_HOST)!!;
		type_store::init_named_types(&comp.type_store, &comp.target, &comp.string_interner);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		Source src = comp.add_source_from_buffer("gcc.c", "#pragma GCC diagnostic ignored \"-Wundef\"\n")!!;
		gcc::GccPragma* gcc_handler = gcc::make_handler(&ta);
		bool added_gcc = comp.pragmas.add("GCC", gcc_handler);
		assert(added_gcc);

		// Exercise the registered Compilation callbacks: preprocessing captures
		// command-line state, then parser callback replay reapplies the pragma.
		d.set("undef", diagnostics::MessageKind.WARNING)!!;
		d.state.error_warnings = true;
		comp.pragmas.before_preprocess(&comp);
		pp.preprocess_extra(src)!!;
		assert(d.severity(diagnostics::Option.UNDEF) == diagnostics::MessageKind.OFF);
		comp.pragmas.before_parse(&comp);
		assert(d.severity(diagnostics::Option.UNDEF) == diagnostics::MessageKind.WARNING);
		assert(gcc_handler.original_state.error_warnings);
		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		assert(p.replay_pragma()!!);
		assert(d.severity(diagnostics::Option.UNDEF) == diagnostics::MessageKind.OFF);
		comp.pragmas.after_parse(&comp);
		assert(d.severity(diagnostics::Option.UNDEF) == diagnostics::MessageKind.WARNING);
		p.tok_i = 0;
		Tree parsed = p.parse()!!;
		parsed.free();
		p.free();
		assert(d.severity(diagnostics::Option.UNDEF) == diagnostics::MessageKind.WARNING);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void before_preprocess_visits_registered_handlers_in_order() @test
{
	Compilation comp;
	comp.init(mem, compilation::native_definition());
	CallbackState first = {};
	CallbackState second = {};
	CallbackPragma first_handler = handler(&first, null, &before_preprocess);
	CallbackPragma second_handler = handler(&second, null, &before_preprocess);
	bool added_first = comp.pragmas.add("first", &first_handler);
	assert(added_first);
	bool added_second = comp.pragmas.add("second", &second_handler);
	assert(added_second);
	Preprocessor pp;
	pp.init(&comp, preprocessor::TESTING)!!;
	check(first.lifecycle_calls, 1);
	check(second.lifecycle_calls, 1);
	check(first.order, 1);
	check(second.order, 1);
	pp.free();
	comp.free();
}

fn void registry_include_and_preserve_callback_contracts() @test
{
	Registry registry;
	registry.init(mem);
	CallbackState state = { .skip_include = true, .preserve = false };
	CallbackPragma h = handler(&state, null);
	h.include_fn = &before_include;
	h.preserve_fn = &preserve_tokens;
	bool added_test = registry.add("test", &h);
	assert(added_test);
	check(registry.before_include(null, {}), IncludePragmaResult.SKIP_INCLUDE);
	check(state.include_calls, 1);
	assert(!registry.preserve_tokens("test", null, 3));
	state.skip_include = false;
	state.preserve = true;
	check(registry.before_include(null, {}), IncludePragmaResult.CONTINUE);
	assert(registry.preserve_tokens("test", null, 3));
	assert(registry.preserve_tokens("unregistered", null, 3));
	check(state.include_calls, 2);
	registry.free(null);
}

fn void include_callback_continue_skip_and_fatal_contract() @test
{
	Registry registry;
	registry.init(mem);
	CallbackState first = { .include_result = IncludePragmaResult.CONTINUE };
	CallbackState skip = { .include_result = IncludePragmaResult.SKIP_INCLUDE };
	CallbackState last = {};
	CallbackPragma first_handler = { .ctx = &first, .include_fn = &before_include };
	CallbackPragma skip_handler = { .ctx = &skip, .include_fn = &before_include };
	CallbackPragma last_handler = { .ctx = &last, .include_fn = &before_include };
	bool added_continue = registry.add("continue", &first_handler);
	assert(added_continue);
	bool added_skip = registry.add("skip", &skip_handler);
	assert(added_skip);
	bool added_last = registry.add("last", &last_handler);
	assert(added_last);
	check(registry.before_include(null, {}), IncludePragmaResult.SKIP_INCLUDE);
	check(first.include_calls, 1);
	check(skip.include_calls, 1);
	check(last.include_calls, 0);
	registry.free(null);
}

fn pragma::IncludePragmaResult fatal_include(void* ctx, preprocessor::Preprocessor* pp, source::Source src)
{
	CallbackState* state = (CallbackState*)ctx;
	state.include_calls++;
	return pragma::IncludePragmaResult.FATAL;
}

fn void include_fatal_stops_callback_chain() @test
{
	Registry registry;
	registry.init(mem);
	CallbackState first = { .include_result = pragma::IncludePragmaResult.CONTINUE };
	CallbackState fatal = {};
	CallbackState last = {};
	CallbackPragma first_handler = { .ctx = &first, .include_fn = &before_include };
	CallbackPragma fatal_handler = { .ctx = &fatal, .include_fn = &fatal_include };
	CallbackPragma last_handler = { .ctx = &last, .include_fn = &before_include };
	bool added_continue = registry.add("continue", &first_handler);
	assert(added_continue);
	bool added_fatal = registry.add("fatal", &fatal_handler);
	assert(added_fatal);
	bool added_last = registry.add("last", &last_handler);
	assert(added_last);
	check(registry.before_include(null, {}), pragma::IncludePragmaResult.FATAL);
	check(first.include_calls, 1);
	check(fatal.include_calls, 1);
	check(last.include_calls, 0);
	registry.free(null);
}

struct PackFixture (pack::IPackParserTestProbe)
{
	uint count;
	tokenizer::TokenId[] ids;
	String[] texts;
	ulong integer;
	bool integer_ok;
	uint diagnostics;
	pack::PackDiag last_diagnostic;
}

fn uint PackFixture.token_count(&self) @dynamic => self.count;
fn tokenizer::TokenId PackFixture.token_id(&self, uint index) @dynamic => self.ids[index];
fn String PackFixture.token_text(&self, uint index) @dynamic => self.texts[index];
fn bool PackFixture.parse_integer(&self, uint index, ulong* value) @dynamic
{
	if (!self.integer_ok) return false;
	*value = self.integer;
	return true;
}
fn void PackFixture.diagnose(&self, uint index, pack::PackDiag kind, ulong value) @dynamic
{
	self.diagnostics++;
	self.last_diagnostic = kind;
}

fn void pack_state_uses_explicit_parser_adapter() @test
{
	pack::PackState state;
	state.init(mem);
	PackFixture fixture = {
		.ids = { tokenizer::TokenId.L_PAREN, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.COMMA, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.COMMA, tokenizer::TokenId.PP_NUM, tokenizer::TokenId.R_PAREN },
		.texts = { "(", "push", ",", "outer", ",", "4", ")" },
		.integer = 4,
		.integer_ok = true,
	};
	fixture.count = 7;
	pack::TreeParserAdapter adapter = { .probe = &fixture };
	pack::HandleResult result = state.handle(&adapter, 0);
	assert(result.ok);
	check(result.next_index, 7);
	assert(state.current.has_value);
	check(state.current.value, 4);
	check(state.stack.len(), 1);
	assert(state.stack[0].label == "outer");
	fixture.ids = { tokenizer::TokenId.L_PAREN, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.COMMA, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.R_PAREN };
	fixture.texts = { "(", "pop", ",", "outer", ")" };
	fixture.count = 5;
	result = state.handle(&adapter, 0);
	assert(result.ok);
	assert(!state.current.has_value);
	check(state.stack.len(), 0);
	state.reset();
	assert(!state.current.has_value);
	assert(state.pop() == false);
	assert(state.current.has_value);
	check(state.current.value, 2);
	state.free();
}

fn void pack_adapter_validates_alignments_and_named_pop_state() @test
{
	pack::PackState state;
	state.init(mem);
	PackFixture fixture = {
		.ids = { tokenizer::TokenId.L_PAREN, tokenizer::TokenId.PP_NUM, tokenizer::TokenId.R_PAREN },
		.texts = { "(", "3", ")" },
		.integer = 3,
		.integer_ok = true,
	};
	fixture.count = 3;
	pack::TreeParserAdapter adapter = { .probe = &fixture };
	pack::HandleResult result = state.handle(&adapter, 0);
	assert(!result.ok);
	check(fixture.last_diagnostic, pack::PackDiag.INTEGER);
	check(fixture.diagnostics, 1);

	fixture.ids = { tokenizer::TokenId.L_PAREN, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.COMMA, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.COMMA, tokenizer::TokenId.PP_NUM, tokenizer::TokenId.R_PAREN };
	fixture.texts = { "(", "push", ",", "outer", ",", "4", ")" };
	fixture.integer = 4;
	fixture.count = 7;
	result = state.handle(&adapter, 0);
	assert(result.ok);
	check(state.current.value, 4);
	check(state.stack.len(), 1);

	// Source-derived from pack.zig: pop restores the saved value, emits the
	// undefined warning, then applies the supplied value.
	fixture.ids = { tokenizer::TokenId.L_PAREN, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.COMMA, tokenizer::TokenId.IDENTIFIER, tokenizer::TokenId.COMMA, tokenizer::TokenId.PP_NUM, tokenizer::TokenId.R_PAREN };
	fixture.texts = { "(", "pop", ",", "outer", ",", "8", ")" };
	fixture.integer = 8;
	result = state.handle(&adapter, 0);
	assert(!result.ok);
	check(fixture.last_diagnostic, pack::PackDiag.UNDEFINED_POP);
	check(fixture.diagnostics, 2);
	check(state.stack.len(), 0);
	assert(state.current.has_value);
	check(state.current.value, 8);
	state.free();
}

fn void parser_replays_pack_push_pop_and_alignment() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Compilation comp;
		comp.init(&ta, compilation::native_definition());
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		Source src = comp.add_source_from_buffer("pack-replay.c", "#pragma pack(push, outer, 4)\n#pragma pack(pop, outer)\n#pragma pack(2)\n")!!;
		bool added_pack = comp.pragmas.add("pack", pack::make_handler(&ta));
		assert(added_pack);
		pp.preprocess_extra(src)!!;
		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		comp.pragmas.before_parse(&comp);
		pack::PackState* state = (pack::PackState*)comp.pragmas.get("pack")!!.ptr;
		p.tok_i = 0;
		assert(p.replay_pragma()!!);
		assert(state.current_value().has_value);
		check(state.current_value().value, 2);
		check(state.stack.len(), 0);
		assert(p.at_eof());
		p.free();
		pp.free();
		comp.free();
	}
	check(ta.allocation_count(), 0);
}

fn void parser_reports_pack_pop_underflow() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		d.set("ignored-pragmas", diagnostics::MessageKind.WARNING)!!;
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		Source src = comp.add_source_from_buffer("pack-underflow.c", "#pragma pack(pop)\n")!!;
		bool added_pack = comp.pragmas.add("pack", pack::make_handler(&ta));
		assert(added_pack);
		pp.preprocess_extra(src)!!;
		Parser p;
		p.init(&pp);
		p.bind_finalized_tokens();
		bool found_pragma = false;
		for (uint i = 0; (usz)i < p.tree.tokens.len; i++)
		{
			if (p.tree.tokens[(usz)i].id == tokenizer::TokenId.KEYWORD_PRAGMA)
			{
				p.tok_i = i;
				found_pragma = true;
				break;
			}
		}
		assert(found_pragma);
		assert(p.replay_pragma()!!);
		assert(d.messages.len() == 1);
		assert(d.messages[0].kind == diagnostics::MessageKind.WARNING);
		assert(d.messages[0].text == "#pragma pack(pop, ...) failed: stack empty");
		p.free();
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void pragma_operator_and_eof_dispatch() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		CallbackState state = {};
		CallbackPragma probe = handler(&state, &handled_preprocess);
		bool added_probe = comp.pragmas.add("probe", &probe);
		assert(added_probe);
		Source src = comp.add_source_from_buffer("pragma.c", "_Pragma(\"probe\")\n#pragma probe")!!;
		Preprocessor pp;
		InitOptions opts = preprocessor::TESTING;
		opts.add_builtin_macros = true;
		pp.init(&comp, opts)!!;
		pp.preprocess_extra(src)!!;
		pp.free();
		check(state.preprocess_calls, 2);
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void ms_pragma_operator_dispatches_registered_handler() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		comp.langopts.set_ms_extensions(true);
		bool added_message = comp.pragmas.add("message", message::handler());
		assert(added_message);
		Source src = comp.add_source_from_buffer("ms-pragma.c", "__pragma(message(\"from __pragma\"))\n")!!;
		Preprocessor pp;
		InitOptions opts = preprocessor::TESTING;
		opts.add_builtin_macros = true;
		pp.init(&comp, opts)!!;
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "#pragma message: from __pragma");
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void pragma_macro_arguments_expand_by_default() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("macro.c", "#define TEXT \"expanded\"\n#pragma message TEXT\n")!!;
		bool added_message = comp.pragmas.add("message", message::handler());
		assert(added_message);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "#pragma message: expanded");
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void gcc_pragma_arguments_follow_should_expand_policy() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("gcc-macro.c", "#define COMMAND warning\n#pragma GCC COMMAND \"kept\"\n")!!;
		bool added_gcc = comp.pragmas.add("GCC", gcc::make_handler(&ta));
		assert(added_gcc);
		d.set("unknown-pragmas", WARNING)!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "pragma GCC expected 'error', 'warning', 'diagnostic', 'poison'");
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void unknown_pragma_preserves_original_tokens() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		d.set("unknown-pragmas", WARNING)!!;
		Source src = comp.add_source_from_buffer("unknown.c", "#pragma unregistered kept_token\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.preprocess_extra(src)!!;
		uint kept = 0;
		for (uint i = 0; i < pp.tokens.len(); i++) if (pp.tree_token_slice(pp.tokens[i]) == "kept_token") kept++;
		check(kept, 1);
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "unknown pragma ignored");
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void unknown_stop_and_fatal_results_dispatch_distinctly() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		d.set("unknown-pragmas", WARNING)!!;
		ResultState state = { .result = PragmaResult.UNKNOWN };
		CallbackPragma route_handler = { .ctx = &state, .preprocess_fn = &selected_result };
		bool added_route = comp.pragmas.add("route", &route_handler);
		assert(added_route);

		Preprocessor unknown_pp;
		unknown_pp.init(&comp, preprocessor::TESTING)!!;
		Source unknown_src = comp.add_source_from_buffer("unknown-result.c", "#pragma route\n")!!;
		unknown_pp.preprocess_extra(unknown_src)!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "unknown pragma ignored");
		unknown_pp.free();

		state.result = PragmaResult.STOP_PREPROCESSING;
		Preprocessor stop_pp;
		stop_pp.init(&comp, preprocessor::TESTING)!!;
		Source stop_src = comp.add_source_from_buffer("stop-result.c", "#pragma route\n")!!;
		fault stop = @catch(stop_pp.preprocess_extra(stop_src));
		assert(stop == preprocessor::STOP_PREPROCESSING);
		stop_pp.free();

		state.result = PragmaResult.FATAL;
		Preprocessor fatal_pp;
		fatal_pp.init(&comp, preprocessor::TESTING)!!;
		Source fatal_src = comp.add_source_from_buffer("fatal-result.c", "#pragma route\n")!!;
		fault fatal = @catch(fatal_pp.preprocess_extra(fatal_src));
		assert(fatal == compilation::FATAL_ERROR);
		fatal_pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void nested_pragma_macro_expansion_uses_generated_location() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("nested.c", "#define INNER _Pragma(\"message \\\"nested\\\"\")\n#define OUTER INNER\nOUTER\n")!!;
		bool added_message = comp.pragmas.add("message", message::handler());
		assert(added_message);
		Preprocessor pp;
		InitOptions opts = preprocessor::TESTING;
		opts.add_builtin_macros = true;
		pp.init(&comp, opts)!!;
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 1);
		test::eq(d.messages[0].text, "#pragma message: nested");
		// The generated pragma expands through the macro call location, as Zig does.
		test::eq(d.messages[0].location.path, "nested.c");
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void once_provider_state_and_after_parse_reset() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("once.h", "#pragma once\n")!!;
		once::Once* h = once::handler(&ta);
		bool added_once = comp.pragmas.add("once", h);
		assert(added_once);
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		// Invoke the real once handler in include context, then call the provider
		// state callback directly; include dispatch remains deferred.
		pp.include_depth = 1;
		pp.preprocess_extra(src)!!;
		check(h.before_include(&pp, src), IncludePragmaResult.SKIP_INCLUDE);
		comp.pragmas.after_parse(&comp);
		check(h.before_include(&pp, src), IncludePragmaResult.CONTINUE);
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void malformed_then_repeated_valid_translation_units_clean_pragma_state() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		once::Once* once_handler = once::handler(&ta);
		bool added_once = comp.pragmas.add("once", once_handler);
		assert(added_once);
		bool added_message = comp.pragmas.add("message", message::handler());
		assert(added_message);
		Source malformed = comp.add_source_from_buffer("malformed.c", "_Pragma(1)\n")!!;
		Source valid = comp.add_source_from_buffer("valid.c", "#pragma once\n#pragma message \"valid\"\n")!!;

		// Reuse the Compilation across a malformed unit and repeated valid units.
		// The parser is not ported, so drive its lifecycle notifications directly.
		Preprocessor bad_pp;
		bad_pp.init(&comp, preprocessor::TESTING)!!;
		bad_pp.include_depth = 1;
		bad_pp.preprocess_extra(malformed)!!;
		comp.pragmas.before_parse(&comp);
		comp.pragmas.after_parse(&comp);
		bad_pp.free();

		for (uint i = 0; i < 2; i++)
		{
			Preprocessor pp;
			pp.init(&comp, preprocessor::TESTING)!!;
			pp.include_depth = 1;
			check(once_handler.before_include(&pp, valid), IncludePragmaResult.CONTINUE);
			pp.preprocess_extra(valid)!!;
			check(once_handler.before_include(&pp, valid), IncludePragmaResult.SKIP_INCLUDE);
			comp.pragmas.before_parse(&comp);
			comp.pragmas.after_parse(&comp);
			pp.free();
		}
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void pragma_operator_malformed_string_recovers_to_later_pragma() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		Source src = comp.add_source_from_buffer("bad.c", "_Pragma(1)\n#pragma message \"recovered\"\n")!!;
		bool added_message = comp.pragmas.add("message", message::handler());
		assert(added_message);
		Preprocessor pp;
		InitOptions opts = preprocessor::TESTING;
		opts.add_builtin_macros = true;
		pp.init(&comp, opts)!!;
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 2);
		test::eq(d.messages[0].text, "_Pragma requires exactly one string literal token");
		test::eq(d.messages[1].text, "#pragma message: recovered");
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}

fn void malformed_message_pragma_recovers_to_later_message() @test
{
	TrackingAllocator ta;
	ta.init(mem);
	defer ta.free();
	{
		Diagnostics d;
		d.init_list(&ta);
		Compilation comp;
		comp.init(&ta, compilation::native_definition(), null, &d);
		bool added_message = comp.pragmas.add("message", message::handler());
		assert(added_message);
		Source src = comp.add_source_from_buffer("message.c", "#pragma message 1\n#pragma message \"recovered\"\n")!!;
		Preprocessor pp;
		pp.init(&comp, preprocessor::TESTING)!!;
		pp.preprocess_extra(src)!!;
		check(d.messages.len(), 2);
		test::eq(d.messages[0].text, "pragma message requires string literal");
		test::eq(d.messages[1].text, "#pragma message: recovered");
		pp.free();
		comp.free();
		d.free();
	}
	check(ta.allocation_count(), 0);
}
