// #pragma once handler for the shared compilation pragma registry.
module aro::pragmas::once;
import aro::pragma, aro::preprocessor, aro::source, aro::tokens, aro::tokenizer, aro::compilation, aro::diagnostics;
import std::collections::map;
import std::core::mem::alloc, std::core::mem::allocators;

<* Zig pragmas/once.zig. Allocated by `handler` and freed by `deinit`. *>
struct Once (pragma::IPragma)
{
	HashMap{uint, bool} sources;
	uint preprocess_count;
	Allocator allocator;
}

fn void Once.init(&self, Allocator allocator)
{
	self.allocator = allocator;
	self.sources.init(allocator);
	self.preprocess_count = 0;
}
fn void Once.free(&self)
{
	self.sources.free();
	*self = {};
}
fn void Once.clear(&self) => self.sources.clear();
fn bool Once.seen(&self, source::SourceId id) => self.sources.has_key((uint)id);

// Return true only when this source was already marked in a different
// preprocess pass, matching STOP_PREPROCESSING for repeated processing.
fn bool Once.mark(&self, source::SourceId id, uint current_preprocess_count)
{
	bool repeated = self.preprocess_count != current_preprocess_count && self.seen(id);
	self.sources.set((uint)id, true);
	self.preprocess_count = current_preprocess_count;
	return repeated;
}

fn void Once.deinit(&self, compilation::Compilation* comp) @dynamic
{
	Allocator allocator = self.allocator;
	self.free();
	alloc::free(allocator, self);
}

<* Allocate the handler; Registry.free releases it through `deinit`. *>
fn Once* handler(Allocator allocator)
{
	Once* state = (Once*)alloc::calloc(allocator, Once::size);
	state.init(allocator);
	return state;
}

fn pragma::PragmaResult Once.preprocessor_handler(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic
{
	if ((sz)start_idx >= pp.tokens.len()) return pragma::PragmaResult.UNKNOWN;
	TreeToken name_tok = pp.tokens[(sz)start_idx];
	TokenWithExpansionLocs diag_tok = { .id = name_tok.id, .loc = name_tok.loc };
	diag_tok.expansion_locs = tokens::borrowed_locs(pp.expansion_slice((TokenIndex)start_idx));
	if (name_tok.id != tokenizer::TokenId.IDENTIFIER || pp.expanded_slice(diag_tok) != "once") return pragma::PragmaResult.UNKNOWN;

	// Match Zig's once handler: reject trailing tokens and a main-file use with
	// their dedicated diagnostics, then scope the source mark to the parse cycle.
	if ((sz)start_idx + 1 >= pp.tokens.len() || pp.tokens[(sz)start_idx + 1].id != tokenizer::TokenId.NL)
	{
		if (catch pp.err(diag_tok, Diagnostic.EXTRA_TOKENS_DIRECTIVE_END)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	if (pp.include_depth == 0)
	{
		if (catch pp.err(diag_tok, Diagnostic.PRAGMA_ONCE_IN_MAIN_FILE)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	if (self.mark(name_tok.loc.id, pp.preprocess_count)) return pragma::PragmaResult.STOP_PREPROCESSING;
	return pragma::PragmaResult.HANDLED;
}

fn pragma::IncludePragmaResult Once.before_include(&self, preprocessor::Preprocessor* pp, source::Source src) @dynamic
{
	if (self.seen(src.id)) return pragma::IncludePragmaResult.SKIP_INCLUDE;
	return pragma::IncludePragmaResult.CONTINUE;
}

fn void Once.after_parse(&self, compilation::Compilation* comp) @dynamic => self.clear();

fn bool Once.preserve_tokens(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic => false;
