// Compilation-owned pragma callback contracts, ported from src/aro/Pragma.zig.
module aro::frontend::c::pragma;
import aro::frontend::c::compilation, aro::frontend::c::preprocessor, aro::source, aro::frontend::c::tokens, aro::frontend::c::parser;
import std::collections::list;
import aro::string_interner;

excuse NOT_FOUND;

// Unknown pragmas preserve their original tokens; stop applies only to the
// current included file. Fatal means a diagnostic has already been emitted.
enum PragmaResult : char { HANDLED, UNKNOWN, STOP_PREPROCESSING, FATAL }
enum IncludePragmaResult : char { CONTINUE, SKIP_INCLUDE, FATAL }

<*
 Zig `Pragma`: a named pragma handler registered on the Compilation. Every
 method is optional; a missing method behaves as described on it. The
 implementing value is borrowed by the Registry, which calls `deinit` exactly
 once when it is freed, so the implementation owns (and may free) itself there.
*>
interface IPragma
{
	<* `#pragma name ...` during preprocessing. Missing: UNKNOWN (unknown-pragma warning). *>
	fn PragmaResult preprocessor_handler(Preprocessor* pp, TokenIndex start_idx) @optional;
	<* A preserved pragma replayed by the parser. Missing: ignored. *>
	fn PragmaResult parser_handler(Parser* p, TokenIndex start_idx) @optional;
	<* Before an #include enters `source`. Missing: CONTINUE. *>
	fn IncludePragmaResult before_include(Preprocessor* pp, Source source) @optional;
	fn void before_preprocess(Compilation* comp) @optional;
	fn void before_parse(Compilation* comp) @optional;
	fn void after_parse(Compilation* comp) @optional;
	<* Release the handler; called once by Registry.free. *>
	fn void deinit(Compilation* comp) @optional;
	<* Keep this pragma's tokens in -E output. Missing: true. *>
	fn bool preserve_tokens(Preprocessor* pp, TokenIndex start_idx) @optional;
	<* Macro-expand the pragma token at `index` (counted from the name). Missing: true. *>
	fn bool should_expand_token_at_index(TokenIndex index) @optional;
}

struct Registry {
	Allocator gpa;
	<* Names are borrowed by StringTable; registration callers must keep them alive. *>
	StringTable names;
	List{IPragma} handlers;
}

fn void Registry.init(&self, Allocator gpa)
{
	self.gpa = gpa;
	self.names.init(gpa);
	self.handlers.init(gpa);
}

<*
 Register a named handler. Returns false if the name is already registered.
 The name's bytes and the handler remain borrowed until `free`, which calls
 the handler's `deinit` once.
*>
fn bool Registry.add(&self, String name, IPragma handler)
{
	bool found_existing = false;
	self.names.get_or_put(name, &found_existing);
	if (found_existing) return false;
	self.handlers.push(handler);
	return true;
}

<* Return a handler by its registered name, or NOT_FOUND when absent. *>
fn IPragma? Registry.get(&self, String name)
{
	if (try index = self.names.find(name)) return self.handlers[index];
	return NOT_FOUND~;
}

fn void Registry.before_preprocess(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (&h.before_preprocess) h.before_preprocess(comp);
}

fn void Registry.before_parse(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (&h.before_parse) h.before_parse(comp);
}

fn void Registry.after_parse(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (&h.after_parse) h.after_parse(comp);
}

fn void Registry.free(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (&h.deinit) h.deinit(comp);
	self.names.free();
	self.handlers.free();
	*self = {};
}

fn PragmaResult Registry.preprocess(&self, Preprocessor* pp, TokenIndex start_idx)
{
	foreach (h : self.handlers)
	{
		if (!&h.preprocessor_handler) continue;
		PragmaResult r = h.preprocessor_handler(pp, start_idx);
		if (r != UNKNOWN) return r;
	}
	return UNKNOWN;
}

<*
 Same as before_include. On SKIP_INCLUDE, `skipper_name` (when non-null) receives
 the registered name of the handler that skipped (Zig `handler_pragma_name`).
 handlers and names grow together in add, so names.key(i) is handler i's name.
*>
fn IncludePragmaResult Registry.before_include_named(&self, Preprocessor* pp, Source src, String* skipper_name)
{
	foreach (i, h : self.handlers)
	{
		if (!&h.before_include) continue;
		IncludePragmaResult r = h.before_include(pp, src);
		if (r != CONTINUE)
		{
			if (r == SKIP_INCLUDE && skipper_name != null) *skipper_name = self.names.key((uint)i);
			return r;
		}
	}
	return CONTINUE;
}

fn IncludePragmaResult Registry.before_include(&self, Preprocessor* pp, Source src)
{
	return self.before_include_named(pp, src, null);
}

fn bool Registry.preserve_tokens(&self, String name, Preprocessor* pp, TokenIndex start_idx)
{
	if (try h = self.get(name))
	{
		if (&h.preserve_tokens) return h.preserve_tokens(pp, start_idx);
	}
	return true;
}

fn bool Registry.should_expand(&self, String name, TokenIndex index)
{
	if (try h = self.get(name))
	{
		if (&h.should_expand_token_at_index) return h.should_expand_token_at_index(index);
	}
	return true;
}
