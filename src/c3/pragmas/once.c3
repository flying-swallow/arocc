// #pragma once callbacks for the shared compilation pragma registry.
module aro::pragmas::once;
import aro::pragma, aro::preprocessor, aro::source, aro::tokens, aro::tokenizer, aro::compilation;
import std::collections::map;
import std::core::mem::alloc, std::core::mem::allocators;

struct Once
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
fn void Once.after_parse(&self) => self.sources.clear();
fn bool Once.before_include(&self, source::SourceId id) => self.sources.has_key((uint)id);

// Return true only when this source was already marked in a different
// preprocess pass, matching STOP_PREPROCESSING for repeated processing.
fn bool Once.mark(&self, source::SourceId id, uint current_preprocess_count)
{
	bool repeated = self.preprocess_count != current_preprocess_count && self.before_include(id);
	self.sources.set((uint)id, true);
	self.preprocess_count = current_preprocess_count;
	return repeated;
}

fn void destroy(void* ctx, compilation::Compilation* comp)
{
	Once* state = (Once*)ctx;
	Allocator allocator = state.allocator;
	state.free();
	alloc::free(allocator, state);
}

// Allocate the state so Registry.free can release it through destroy.
fn pragma::Handler handler(Allocator allocator)
{
	Once* state = (Once*)alloc::calloc(allocator, Once::size);
	state.init(allocator);
	return { .ctx = state, .preprocess = &preprocess, .before_include = &before_include, .after_parse = &after_parse, .destroy = &destroy, .preserve_tokens = &preserve_tokens };
}

fn pragma::PragmaResult preprocess(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx)
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
		if (catch pp.err(diag_tok, preprocessor::PpDiag.EXTRA_TOKENS_DIRECTIVE_END)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	if (pp.include_depth == 0)
	{
		if (catch pp.err(diag_tok, preprocessor::PpDiag.PRAGMA_ONCE_IN_MAIN_FILE)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	Once* state = (Once*)ctx;
	if (state.mark(name_tok.loc.id, pp.preprocess_count)) return pragma::PragmaResult.STOP_PREPROCESSING;
	return pragma::PragmaResult.HANDLED;
}

fn pragma::IncludePragmaResult before_include(void* ctx, preprocessor::Preprocessor* pp, source::Source src)
{
	Once* state = (Once*)ctx;
	if (state.before_include(src.id)) return pragma::IncludePragmaResult.SKIP_INCLUDE;
	return pragma::IncludePragmaResult.CONTINUE;
}

fn void after_parse(void* ctx, compilation::Compilation* comp)
{
	Once* state = (Once*)ctx;
	state.after_parse();
}

fn bool preserve_tokens(void* ctx, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) { return false; }
