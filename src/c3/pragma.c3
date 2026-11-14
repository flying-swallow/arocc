// Compilation-owned pragma callback contracts, ported from src/aro/Pragma.zig.
module aro::pragma;
import aro::compilation, aro::preprocessor, aro::source, aro::tokens;
import std::collections::list;
import aro::string_interner;

excuse NOT_FOUND;

// Unknown pragmas preserve their original tokens; stop applies only to the
// current included file. Fatal means a diagnostic has already been emitted.
enum PragmaResult : char { HANDLED, UNKNOWN, STOP_PREPROCESSING, FATAL }
enum IncludePragmaResult : char { CONTINUE, SKIP_INCLUDE, FATAL }

alias PragmaPreprocessFn = fn PragmaResult(void* ctx, Preprocessor* pp, TokenIndex start_idx);
alias PragmaParserFn = fn PragmaResult(void* ctx, void* parser, TokenIndex start_idx);
alias PragmaBeforeIncludeFn = fn IncludePragmaResult(void* ctx, Preprocessor* pp, Source source);
alias PragmaLifecycleFn = fn void(void* ctx, Compilation* comp);
alias PragmaPreserveFn = fn bool(void* ctx, Preprocessor* pp, TokenIndex start_idx);
alias PragmaExpandFn = fn bool(void* ctx, TokenIndex index);

// Callback implementations own ctx. Compilation invokes destroy exactly once.
struct Handler {
	void* ctx;
	PragmaPreprocessFn preprocess;
	PragmaParserFn parser;
	PragmaBeforeIncludeFn before_include;
	PragmaLifecycleFn before_preprocess;
	PragmaLifecycleFn before_parse;
	PragmaLifecycleFn after_parse;
	PragmaLifecycleFn destroy;
	PragmaPreserveFn preserve_tokens;
	PragmaExpandFn should_expand;
}

struct Registry {
	Allocator gpa;
	<* Names are borrowed by StringTable; registration callers must keep them alive. *>
	StringTable names;
	List{Handler} handlers;
}

fn void Registry.init(&self, Allocator gpa)
{
	self.gpa = gpa;
	self.names.init(gpa);
	self.handlers.init(gpa);
}

<*
 Register a named handler. Returns false if the name is already registered.
 The name's bytes remain borrowed until `free`; callback state is owned by
 the registry and its destroy callback runs once during `free`.
*>
fn bool Registry.add(&self, String name, Handler handler)
{
	bool found_existing = false;
	self.names.get_or_put(name, &found_existing);
	if (found_existing) return false;
	self.handlers.push(handler);
	return true;
}

<* Return a handler by its registered name, or NOT_FOUND when absent. *>
fn Handler? Registry.get(&self, String name)
{
	if (try index = self.names.find(name)) return self.handlers[index];
	return NOT_FOUND~;
}

fn void Registry.before_preprocess(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (h.before_preprocess) h.before_preprocess(h.ctx, comp);
}

fn void Registry.before_parse(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (h.before_parse) h.before_parse(h.ctx, comp);
}

fn void Registry.after_parse(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (h.after_parse) h.after_parse(h.ctx, comp);
}

fn void Registry.free(&self, Compilation* comp)
{
	foreach (h : self.handlers) if (h.destroy) h.destroy(h.ctx, comp);
	self.names.free();
	self.handlers.free();
	*self = {};
}

fn PragmaResult Registry.preprocess(&self, Preprocessor* pp, TokenIndex start_idx)
{
	foreach (h : self.handlers)
	{
		if (!h.preprocess) continue;
		PragmaResult r = h.preprocess(h.ctx, pp, start_idx);
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
		if (!h.before_include) continue;
		IncludePragmaResult r = h.before_include(h.ctx, pp, src);
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
		if (h.preserve_tokens) return h.preserve_tokens(h.ctx, pp, start_idx);
	}
	return true;
}

fn bool Registry.should_expand(&self, String name, TokenIndex index)
{
	if (try h = self.get(name))
	{
		if (h.should_expand) return h.should_expand(h.ctx, index);
	}
	return true;
}
