// Port of src/aro/Preprocessor.zig (plan 13): the in-memory preprocessor.
//
// How the parts fit
// =================
// One module, `aro::frontend::c::preprocessor`, spread over files that each have a single
// owner (plan 13 "Parallel agent breakdown"); two helper modules sit beside it.
//
//   tokens.c3 (aro::frontend::c::tokens, stage 0, implemented)
//       TreeToken (Zig Tree.Token), Precedence, TokenWithExpansionLocs with
//       its flags and bounded expansion-location chains. Ownership rules for
//       expansion arrays are in that file's header and apply everywhere below.
//   hideset.c3 (aro::frontend::c::hideset, 13.1 `hideset`)
//       Hideset lists keyed by token location: get/put/prepend/union_of/
//       intersection/contains. Reset (clear_retaining_capacity) before every
//       top-level expansion.
//   preprocessor.c3 (this file, stage 0, implemented; integrator afterwards)
//       Preprocessor/Macro/MacroTable types, providers, init/free, error
//       reporting (err/err_raw/err_loc/fatal), the output token list
//       (add_token, expansion_entries), token slices (tok_slice,
//       expanded_slice), unescape_ucn, the shared ExpandBuf ownership helpers,
//       preprocess/preprocess_sources/tokenize wrappers and bounded plan-15
//       include/embed/pragma handling.
//   pp_diagnostics.c3 (stage 0, data)
//       Every Preprocessor/Diagnostic.zig record as DIAG_* constants.
//   pp_directives.c3 (13.5 `directives`)
//       preprocess_extra (the per-file main loop and directive dispatch),
//       #if/#ifdef/#elif.../#else/#endif with IfContext and `skip`, #define
//       and #undef dispatch, #line / GNU line markers, #error / #warning,
//       `expr` (collect + expand + evaluate an #if line), include-guard
//       tracking, unterminated-conditional and newline-eof diagnostics.
//   pp_expression.c3 (13.2 `pp-expr`)
//       Preprocessor/Parser.zig: the #if expression evaluator over an expanded
//       token slice with intmax_t (64-bit, signed/unsigned) arithmetic.
//   macro_expand.c3 (13.3 `expansion`)
//       #define / function-like #define parsing, macro redefinition checks,
//       argument collection, object/function macro expansion, __VA_ARGS__ /
//       __VA_OPT__ / GNU comma deletion, the exhaustive rescan loop with
//       hideset recursion blocking, expand_macro (top level) and
//       add_tokens_from_expand_buf. Builtin macros expand through
//       expand_builtin_obj / expand_builtin_func.
//   macro_paste.c3 (13.4 `stringify-paste`)
//       # stringify / destringify, ## paste_tokens with invalid-paste
//       diagnostics, make_generated_token(_extra) (all writes of generated
//       tokens into Compilation.generated_buf).
//   pp_print.c3 (13.6 `probe`)
//       prettyPrintTokens (-E output), macro dumps, line markers, C string
//       escaping. test/src/probes/pp_probe.c3 drives everything in memory.
//
// Data flow for one file: preprocess -> preprocess_extra reads raw tokens from
// a Tokenizer. Directives are handled in place; other tokens go to
// expand_macro, which puts the token into `top_expansion_buf`, runs
// expand_macro_exhaustive (pulling more raw tokens from the tokenizer when a
// function-like macro needs its arguments) and moves the result into `tokens`
// via add_tokens_from_expand_buf -> add_token. The eof token is returned and
// the caller (preprocess_sources / the probe) appends it.
//
// Providers. Builtin macros are expanded directly by Preprocessor methods
// (pp_builtin_macros.c3, pp_feature_queries.c3). FileProvider (plan 15)
// is injected for include/embed lookup and mtimes. Its
// default returns aro::UNSUPPORTED; nothing silently succeeds. Macro-expanded
// #include/#embed filenames and all standard #embed parameters use these hooks.
// Dependency recording requires a Compilation dependency sink.
//
// Faults: compilation::FATAL_ERROR (a fatal diagnostic), STOP_PREPROCESSING
// (Zig error.StopPreprocessing: only from includes/pragmas, plan 15) and
// aro::UNSUPPORTED (a provider or placeholder). Out of memory panics.
//
// Deviations from Zig:
//  - `defines` keys are copied (Zig borrows them; a UCN-unescaped name lives
//    in generated_buf, which moves when it grows in C3).
//  - Zig's `err(loc: anytype, ...)` is three functions: err (expanded token,
//    reports through its expansion locations), err_raw (tokenizer token) and
//    err_loc (plain location). Arguments are printf varargs checked by @format.
//  - C3 Compilation has no dependency-file field: an optional caller-owned
//    sink records the base source, resolved include paths, successful
//    `__has_include` results, and the filename spelling used by #embed.
//  - `?SourceEpoch` options are `has_source_epoch` + `source_epoch`; without
//    one, init calls source_epoch_from_environment.
module aro::frontend::c::preprocessor;
import aro::target;
import aro::source, aro::frontend::c::tokenizer, aro::frontend::c::tokens, aro::frontend::c::hideset, aro::frontend::c::compilation, aro::frontend::c::diagnostics;
import aro::frontend::c::lang_opts, aro::string_interner, aro::frontend::c::text_literal, aro::frontend::c::dep_file, aro::frontend::c::pragma;
import std::collections::list, std::collections::map, std::core::mem::allocators, std::io, std::hash::fnv32a;

// ---------------------------------------------------------------------------
// Faults

<* Zig error.StopPreprocessing: stop the current file (raised by includes/pragmas, plan 15). *>
excuse STOP_PREPROCESSING;
<* Zig collectMacroFuncArguments error.MissingLParen: the macro name is not followed by '('. *>
excuse MISSING_L_PAREN;
<* Zig collectMacroFuncArguments error.Unterminated: eof inside a macro argument list. *>
excuse UNTERMINATED;
<* A FileProvider lookup found nothing (Zig returns null). *>
excuse FILE_NOT_FOUND;
<* Zig error.InvalidInclude: the header name was diagnosed; #include returns without error. *>
excuse INVALID_INCLUDE;

<* Zig `max_include_depth`. *>
const MAX_INCLUDE_DEPTH = 200;

// ---------------------------------------------------------------------------
// Small types

<* Zig `Tokenizer.Token` as used by the preprocessor (`RawToken`). *>
alias RawToken = Token;

<*
 Zig `ExpandBuf` (ArrayList(TokenWithExpansionLocs)). Every element owns its
 expansion array: before `free()`-ing or truncating the list, free the
 dropped elements' arrays (free_buf_tokens) or move them elsewhere (add_token).
*>
alias ExpandBuf = List{TokenWithExpansionLocs};

<*
 Zig `MacroArguments` (ArrayList([]const TokenWithExpansionLocs)). Each slice
 is allocated from comp.gpa and owns its tokens' expansion arrays; release
 everything with `deinit_macro_arguments`.
*>
alias MacroArguments = List{TokenWithExpansionLocs[]};

<*
 Zig `EvalContext`. The behavior of `defined` depends on whether we are in a
 preprocessor expression context (#if or #elif) or not.
*>
enum EvalContext : char
{
	<* #if / #elif: `defined` is an operator. *>
	EXPR,
	<* `defined` is just an identifier. *>
	NON_EXPR,
	<* Same as NON_EXPR but also prevents the _Pragma operator being evaluated. *>
	NO_PRAGMA,
}

<* Zig `Linemarkers`. Must be NONE unless in -E mode (the parser does not handle line markers). *>
enum Linemarkers : char
{
	<* No linemarker tokens. Required setting if the parser will run. *>
	NONE,
	<* #line <num> "filename" *>
	LINE_DIRECTIVES,
	<* # <num> "filename" flags *>
	NUMERIC_DIRECTIVES,
}

<* Zig `expandedSliceExtra` macro_ws_handling. *>
enum MacroWsHandling : char
{
	SINGLE_MACRO_WS,
	PRESERVE_MACRO_WS,
}

<* Zig `Compilation.WhichInclude`. API note: belongs in compilation.c3 (plan 15). *>
enum WhichInclude : char
{
	FIRST,
	NEXT,
}

<* Zig `Compilation.IncludeType`. API note: belongs in compilation.c3 (plan 15). *>
enum IncludeType : char
{
	QUOTES,
	ANGLE_BRACKETS,
	<* behaves like QUOTES but relative to the Driver cwd *>
	CLI,
}

<* Zig `Compilation.Environment.SourceEpoch` (union { system, provided }). *>
struct SourceEpoch
{
	<* false: `system` (time of invocation); true: `provided` (SOURCE_DATE_EPOCH). *>
	bool provided;
	ulong timestamp;
}

<* Zig `SourceEpoch.default` (.provided = 0). *>
const SourceEpoch DEFAULT_SOURCE_EPOCH = { .provided = true, .timestamp = 0 };

<* One `path_replacements` entry: a __FILE__ path prefix and its replacement (both borrowed). *>
struct PathReplacement
{
	String prefix;
	String replacement;
}

// ---------------------------------------------------------------------------
// Macros

<* Zig `Macro.Builtin.Object`. *>
enum BuiltinObject : char
{
	BASE_FILE,
	FILE,
	FILE_BASENAME,
	LINE,
	COUNTER,
	DATE,
	TIME,
	TIMESTAMP,
	INCLUDE_LEVEL,
}

<* Zig `Macro.Builtin.Func`. *>
enum BuiltinFunc : char
{
	HAS_ATTRIBUTE,
	HAS_C_ATTRIBUTE,
	HAS_DECLSPEC_ATTRIBUTE,
	HAS_WARNING,
	HAS_FEATURE,
	HAS_EXTENSION,
	HAS_BUILTIN,
	HAS_INCLUDE,
	HAS_INCLUDE_NEXT,
	HAS_EMBED,
	IS_IDENTIFIER,
	PRAGMA_OPERATOR,
	MS_IDENTIFIER,
	MS_PRAGMA,
	IS_TARGET_ARCH,
	IS_TARGET_VENDOR,
	IS_TARGET_OS,
	IS_TARGET_ENVIRONMENT,
	IS_TARGET_VARIANT_OS,
	IS_TARGET_VARIANT_ENVIRONMENT,
}

<* Zig `Func.shouldExpandArgs`. *>
fn bool BuiltinFunc.should_expand_args(self)
{
	switch (self)
	{
		case HAS_ATTRIBUTE:
		case HAS_C_ATTRIBUTE:
		case HAS_DECLSPEC_ATTRIBUTE:
		case HAS_WARNING:
		case HAS_INCLUDE:
		case HAS_INCLUDE_NEXT:
		case HAS_EMBED:
		case PRAGMA_OPERATOR:
		case MS_IDENTIFIER:
		case MS_PRAGMA:
			return true;
		default:
			return false;
	}
}

<* Zig `Macro.Builtin` (union(enum) { obj, func }). *>
struct MacroBuiltin
{
	bool is_func;
	<* valid when !is_func *>
	BuiltinObject obj;
	<* valid when is_func *>
	BuiltinFunc func;
}

fn MacroBuiltin builtin_obj(BuiltinObject o) => { .obj = o };
fn MacroBuiltin builtin_func(BuiltinFunc f) => { .is_func = true, .func = f };

<* Zig std.meta.eql on two builtin kinds. *>
fn bool MacroBuiltin.eql(self, MacroBuiltin other)
{
	if (self.is_func != other.is_func) return false;
	return self.is_func ? self.func == other.func : self.obj == other.obj;
}

// Zig `params_placeholder`, `func_tokens`, `obj_tokens` (static, never freed).
String[1] builtin_params_placeholder @private = { "X" };
RawToken[1] builtin_func_tokens @private = { { .id = MACRO_PARAM_BUILTIN_FUNC, .source = source::GENERATED_ID } };
RawToken[1] builtin_obj_tokens @private = { { .id = MACRO_BUILTIN_OBJ, .source = source::GENERATED_ID } };

fn String[] MacroBuiltin.params(self)
{
	if (self.is_func) return builtin_params_placeholder[..];
	return {};
}
fn RawToken[] MacroBuiltin.tokens(self)
{
	if (self.is_func) return builtin_func_tokens[..];
	return builtin_obj_tokens[..];
}

<*
 Zig `Macro`. `params` and `tokens` of user macros live in `Preprocessor.arena`
 (the param strings themselves are slices of source buffers); builtin macros
 point at static data. A function macro body uses MACRO_PARAM /
 MACRO_PARAM_NO_EXPAND / STRINGIFY_PARAM tokens whose `end` is the parameter
 index, KEYWORD_VA_ARGS / STRINGIFY_VA_ARGS for the variadic part and
 KEYWORD_VA_OPT whose start..end spans the __VA_OPT__ contents.
*>
struct Macro
{
	<* Parameters of the function type macro *>
	String[] params;
	<* Tokens constituting the macro body *>
	RawToken[] tokens;
	<* If the function type macro has variable number of arguments *>
	bool var_args;
	<* Is a function type macro *>
	bool is_func;
	<* false for user-defined macros (Zig `builtin_kind == null`) *>
	bool has_builtin_kind;
	MacroBuiltin builtin_kind;
	<* Location of macro in the source *>
	Location loc;
}

<* Zig `Macro.isBuiltin`. *>
fn bool Macro.is_builtin(&self) => self.has_builtin_kind;

<*
 Zig `Macro.shouldExpandArgs`: user macros expand their arguments; builtin
 function macros decide per kind.
 @require !self.has_builtin_kind || self.builtin_kind.is_func
*>
fn bool Macro.should_expand_args(&self)
{
	if (!self.has_builtin_kind) return true;
	return self.builtin_kind.func.should_expand_args();
}

<*
 Zig `DefineMap` (StringArrayHashMapUnmanaged(Macro)): an insertion-ordered
 name -> Macro map with ordered removal. Keys are copied (owned). Pointers
 returned by `get` / `get_or_put` are invalidated by the next insertion or
 removal.
*>
struct MacroTable
{
	Allocator allocator;
	List{String} keys;
	List{Macro} values;
	<* Open addressing: 0 = empty, otherwise index + 1. Length is 0 or a power of two. *>
	uint[] slots;
}

fn void MacroTable.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.keys.init(allocator);
	self.values.init(allocator);
}

fn void MacroTable.free(&self)
{
	foreach (k : self.keys) alloc::free(self.allocator, k.ptr);
	self.keys.free();
	self.values.free();
	if (self.slots.len) alloc::free(self.allocator, self.slots.ptr);
	*self = {};
}

fn sz MacroTable.len(&self) @inline => self.keys.len();
fn String MacroTable.key(&self, sz index) @inline => self.keys[index];
<* The macros in definition order (Zig `defines.values()`); invalidated by insert/remove. *>
fn Macro[] MacroTable.macros(&self) => self.values.array_view();

fn void MacroTable.rehash(&self, sz new_len)
{
	if (self.slots.len) alloc::free(self.allocator, self.slots.ptr);
	self.slots = alloc::new_array(self.allocator, uint, new_len);
	sz mask = new_len - 1;
	foreach (i, k : self.keys)
	{
		sz slot = fnv32a::hash(k) & mask;
		while (self.slots[slot]) slot = (slot + 1) & mask;
		self.slots[slot] = (uint)i + 1;
	}
}

<* Index of `name`, or string_interner::NOT_FOUND. *>
fn uint? MacroTable.find(&self, String name)
{
	if (!self.slots.len) return string_interner::NOT_FOUND~;
	sz mask = self.slots.len - 1;
	sz slot = fnv32a::hash(name) & mask;
	while (true)
	{
		uint entry = self.slots[slot];
		if (!entry) return string_interner::NOT_FOUND~;
		if (self.keys[(sz)entry - 1] == name) return entry - 1;
		slot = (slot + 1) & mask;
	}
}

<* Zig `defines.getPtr(name)`; null if undefined. *>
fn Macro* MacroTable.get(&self, String name)
{
	if (try idx = self.find(name)) return &self.values.entries[idx];
	return null;
}

<* Zig `defines.contains(name)`. *>
fn bool MacroTable.contains(&self, String name) => @ok(self.find(name));

<*
 Zig `defines.getOrPut(name)`: the existing entry, or a new zeroed entry
 appended at the end (key copied).
 @param [out] found_existing
*>
fn Macro* MacroTable.get_or_put(&self, String name, bool* found_existing)
{
	if (try idx = self.find(name))
	{
		*found_existing = true;
		return &self.values.entries[idx];
	}
	*found_existing = false;
	self.keys.push(name.copy(self.allocator));
	self.values.push({});
	if (self.keys.len() * 2 > self.slots.len)
	{
		self.rehash(self.slots.len ? self.slots.len * 2 : 16);
	}
	else
	{
		sz mask = self.slots.len - 1;
		sz slot = fnv32a::hash(name) & mask;
		while (self.slots[slot]) slot = (slot + 1) & mask;
		self.slots[slot] = (uint)self.keys.len();
	}
	return &self.values.entries[self.values.len() - 1];
}

<* Zig `defines.orderedRemove(name)`: remove keeping the order of the rest; false if absent. *>
fn bool MacroTable.ordered_remove(&self, String name)
{
	uint? idx = self.find(name);
	if (catch idx) return false;
	alloc::free(self.allocator, self.keys[idx].ptr);
	self.keys.remove_at(idx);
	self.values.remove_at(idx);
	self.rehash(self.slots.len);
	return true;
}

// ---------------------------------------------------------------------------
// Providers

<*
 Plan 15: Zig `Compilation.findInclude(filename, include_tok, include_type,
 which)`; FILE_NOT_FOUND where Zig returns null (the caller then reports
 fatal_not_found). Records the dependency (Zig dep_file) itself.
*>
alias FindIncludeFn = fn Source? (void* ctx, Preprocessor* pp, String filename, RawToken include_tok, IncludeType include_type, WhichInclude which);
<* Plan 15: Zig `Compilation.hasInclude(filename, includer, include_type, which, dep_file)`. *>
alias HasIncludeFn = fn bool? (void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType include_type, WhichInclude which);
<*
 Plan 15: Zig `Compilation.findEmbed`; FILE_NOT_FOUND for null. `limit` is
 EMBED_UNLIMITED or a byte count. The returned bytes are allocated from
 comp.gpa and owned by the caller.
*>
alias FindEmbedFn = fn char[]? (void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType include_type, ulong limit);
<* Plan 15: Zig `Compilation.getSourceMTimeUncached` (0 where Zig returns null). *>
alias SourceMTimeFn = fn ulong? (void* ctx, Preprocessor* pp, SourceId id);

<* `limit` value meaning Zig `std.Io.Limit.unlimited`. *>
const ulong EMBED_UNLIMITED = ulong::max;

<* File services (plan 15). The default returns aro::UNSUPPORTED from every hook. *>
struct FileProvider
{
	void* ctx;
	FindIncludeFn find_include;
	HasIncludeFn has_include;
	FindEmbedFn find_embed;
	SourceMTimeFn source_mtime;
}

fn Source? unsupported_find_include(void* ctx, Preprocessor* pp, String filename, RawToken include_tok, IncludeType include_type, WhichInclude which) => aro::UNSUPPORTED~;
fn bool? unsupported_has_include(void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType include_type, WhichInclude which) => aro::UNSUPPORTED~;
fn char[]? unsupported_find_embed(void* ctx, Preprocessor* pp, String filename, SourceId includer, IncludeType include_type, ulong limit) => aro::UNSUPPORTED~;
fn ulong? unsupported_source_mtime(void* ctx, Preprocessor* pp, SourceId id) => aro::UNSUPPORTED~;

const FileProvider UNSUPPORTED_FILES = { null, &unsupported_find_include, &unsupported_has_include, &unsupported_find_embed, &unsupported_source_mtime };

// ---------------------------------------------------------------------------
// Preprocessor

<* Zig `ExpansionEntry`: the expansion array of output token `idx` (owned). *>
struct ExpansionEntry
{
	TokenIndex idx;
	List{Location} locs;
}

<* Zig `TokenCount` / `TokenState`. *>
struct TokenCount
{
	sz tokens_len;
	sz expansion_entries_len;
}

<* Zig `InitOptions`. *>
struct InitOptions
{
	<* File used for the __BASE_FILE__ macro. *>
	SourceId base_file;
	bool has_source_epoch;
	SourceEpoch source_epoch;
	bool add_builtin_macros;
	<* Path prefixes to replace when expanding __FILE__ (borrowed). *>
	PathReplacement[] path_replacements;
	<* Optional Make/NMake dependency sink; the caller owns it. *>
	dep_file::DepFile* dependencies;
}

<* Zig `InitOptions.testing` (base_file is Zig `undefined`; here the unused id). *>
const InitOptions TESTING = {
	.base_file = source::UNUSED_ID,
	.has_source_epoch = true,
	.source_epoch = DEFAULT_SOURCE_EPOCH,
	.add_builtin_macros = false,
};

<*
 Zig `Preprocessor`. Set up with `init` and release with `free`. The value
 must not be copied while in use (the arena and hideset are held by value;
 nothing stores their address, but copies would double-free).
*>
struct Preprocessor
{
	Compilation* comp;
	Diagnostics* diagnostics;

	<* Zig `arena`: Macro.tokens / Macro.params arrays of user macros. Use `&self.arena` at the point of use. *>
	DynamicArenaAllocator arena;
	MacroTable defines;
	<*
	 The output. Do not directly mutate this; use add_token /
	 add_token_assume_capacity / ensure_total_token_capacity /
	 ensure_unused_token_capacity / set_token_count.
	*>
	List{TreeToken} tokens;
	<* Sorted by idx; owns every `locs` array. Must be kept in sync with `tokens`. *>
	List{ExpansionEntry} expansion_entries;
	<* Scratch for #define bodies (safe: only one directive at a time). *>
	List{RawToken} token_buf;
	<* Scratch for stringify and string pasting; callers restore its length. *>
	List{char} char_buf;
	<* Counter that is incremented each time preprocess() is called *>
	uint preprocess_count;
	<* Line number given to the next generated token (starts at 1). *>
	uint generated_line;
	<* Newlines consumed while collecting macro arguments, re-emitted with preserve_whitespace. *>
	uint add_expansion_nl;
	uint include_depth;
	<* __COUNTER__ *>
	uint counter;
	<* Location of the token whose expansion is in progress (Zig `undefined` until set). *>
	Location expansion_source_loc;
	<* Zig `poisoned_identifiers` (#pragma GCC poison, plan 15). Keys borrowed. *>
	StringTable poisoned_identifiers;
	<* Map from SourceId (as uint) to the macro name in the `#ifndef` guarding that source. Names borrowed from the source buffer. *>
	HashMap{uint, String} include_guards;

	<*
	 Store KEYWORD_DEFINE and KEYWORD_UNDEF tokens (preprocessor debug dump
	 options). Must be false unless in -E mode (the parser does not handle them).
	*>
	bool store_macro_tokens;
	<*
	 Memory is retained to avoid allocation on every single token. After
	 add_tokens_from_expand_buf its elements alias arrays now owned by the
	 output, so users reset its length before use (Zig `items.len = 0`) and
	 free/free_buf_tokens never walks it.
	*>
	ExpandBuf top_expansion_buf;
	<* Dump current state to stderr. *>
	bool verbose;
	bool preserve_whitespace;
	<* linemarker tokens. Must be NONE unless in -E mode *>
	Linemarkers linemarkers;
	Hideset hideset;
	<* Epoch used for __DATE__, __TIME__, and possibly __TIMESTAMP__ *>
	SourceEpoch source_epoch;
	<* Zig `m_times` cache (plan 14/15), keyed by SourceId as uint. *>
	HashMap{uint, ulong} m_times;
	<* Path prefixes to replace when expanding __FILE__ (borrowed). *>
	PathReplacement[] path_replacements;
	<* File used for __BASE_FILE__ macro. *>
	SourceId base_file;
	<* Optional caller-owned dependency sink. *>
	dep_file::DepFile* dependencies;

	FileProvider files;
}

<*
 Zig `Preprocessor.init`. Takes the source epoch from `options` or asks
 `source_epoch_from_environment`; registers the builtin macros when
 options.add_builtin_macros. Zig's `comp.pragmaEvent(.before_preprocess)`
 is called for registered handlers. On failure everything is released.
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn void? Preprocessor.init(&self, Compilation* comp, InitOptions options, FileProvider files = UNSUPPORTED_FILES)
{
	Allocator gpa = comp.gpa;
	*self = {
		.comp = comp,
		.diagnostics = comp.diagnostics,
		.generated_line = 1,
		.expansion_source_loc = source::UNUSED_LOCATION,
		.source_epoch = options.source_epoch,
		.base_file = options.base_file,
		.path_replacements = options.path_replacements,
		.dependencies = options.dependencies,
		.files = files,
	};
	self.arena.init(gpa, 4096);
	self.defines.init(gpa);
	self.tokens.init(gpa);
	self.expansion_entries.init(gpa);
	self.token_buf.init(gpa);
	self.char_buf.init(gpa);
	self.poisoned_identifiers.init(gpa);
	self.include_guards.init(gpa);
	self.top_expansion_buf.init(gpa);
	self.hideset.init(comp);
	self.m_times.init(gpa);
	comp.pragmas.before_preprocess(comp);

	if (!options.has_source_epoch)
	{
		SourceEpoch? epoch = self.source_epoch_from_environment();
		if (catch epoch_fault = epoch)
		{
			self.free();
			return epoch_fault~;
		}
		else
		{
			self.source_epoch = epoch;
		}
	}
	if (options.add_builtin_macros) self.add_builtin_macros();
}

<*
 Zig `deinit`: frees every owned buffer, all expansion arrays in
 `expansion_entries` and the arena (not the elements of top_expansion_buf).
*>
fn void Preprocessor.free(&self)
{
	// Idempotent: the driver releases the preprocessor early, before its defer runs.
	if (!self.comp) return;
	Allocator gpa = self.comp.gpa;
	self.defines.free();
	self.tokens.free();
	self.arena.free();
	self.token_buf.free();
	self.char_buf.free();
	self.poisoned_identifiers.free();
	self.include_guards.free();
	self.top_expansion_buf.free(); // elements may alias arrays already moved to `tokens`
	self.hideset.free();
	foreach (&e : self.expansion_entries) e.locs.free();
	self.expansion_entries.free();
	self.m_times.free();
	*self = {};
}

<*
 Zig `clearBuffers`: free buffers that are not needed after preprocessing
 (token_buf, char_buf, top_expansion_buf, hideset). The preprocessor stays usable.
*>
fn void Preprocessor.clear_buffers(&self)
{
	Allocator gpa = self.comp.gpa;
	self.token_buf.free();
	self.token_buf.init(gpa);
	self.char_buf.free();
	self.char_buf.init(gpa);
	self.top_expansion_buf.free();
	self.top_expansion_buf.init(gpa);
	self.hideset.clear_and_free();
}

<* Zig `addBuiltinMacro` (putNoClobber). *>
fn void Preprocessor.add_builtin_macro(&self, String name, MacroBuiltin kind)
{
	bool found;
	Macro* m = self.defines.get_or_put(name, &found);
	assert(!found, "builtin macro defined twice");
	*m = {
		.params = kind.params(),
		.tokens = kind.tokens(),
		.var_args = false,
		.is_func = kind.is_func,
		.loc = { .id = source::GENERATED_ID },
		.has_builtin_kind = true,
		.builtin_kind = kind,
	};
}

<* Zig `addBuiltinMacros`: registers the builtin macro names (their expansion is expand_builtin_obj / expand_builtin_func). *>
fn void Preprocessor.add_builtin_macros(&self)
{
	self.add_builtin_macro("__has_attribute", builtin_func(HAS_ATTRIBUTE));
	self.add_builtin_macro("__has_c_attribute", builtin_func(HAS_C_ATTRIBUTE));
	self.add_builtin_macro("__has_declspec_attribute", builtin_func(HAS_DECLSPEC_ATTRIBUTE));
	self.add_builtin_macro("__has_warning", builtin_func(HAS_WARNING));
	self.add_builtin_macro("__has_feature", builtin_func(HAS_FEATURE));
	self.add_builtin_macro("__has_extension", builtin_func(HAS_EXTENSION));
	self.add_builtin_macro("__has_builtin", builtin_func(HAS_BUILTIN));
	self.add_builtin_macro("__has_include", builtin_func(HAS_INCLUDE));
	self.add_builtin_macro("__has_include_next", builtin_func(HAS_INCLUDE_NEXT));
	self.add_builtin_macro("__has_embed", builtin_func(HAS_EMBED));
	self.add_builtin_macro("__is_identifier", builtin_func(IS_IDENTIFIER));
	self.add_builtin_macro("_Pragma", builtin_func(PRAGMA_OPERATOR));

	Compiler emulate = self.comp.langopts.emulate;
	if (emulate == NO || emulate == CLANG)
	{
		self.add_builtin_macro("__is_target_arch", builtin_func(IS_TARGET_ARCH));
		self.add_builtin_macro("__is_target_vendor", builtin_func(IS_TARGET_VENDOR));
		self.add_builtin_macro("__is_target_os", builtin_func(IS_TARGET_OS));
		self.add_builtin_macro("__is_target_environment", builtin_func(IS_TARGET_ENVIRONMENT));
		self.add_builtin_macro("__is_target_variant_os", builtin_func(IS_TARGET_VARIANT_OS));
		self.add_builtin_macro("__is_target_variant_environment", builtin_func(IS_TARGET_VARIANT_ENVIRONMENT));
	}

	if (self.comp.langopts.ms_extensions)
	{
		self.add_builtin_macro("__identifier", builtin_func(MS_IDENTIFIER));
		self.add_builtin_macro("__pragma", builtin_func(MS_PRAGMA));
	}

	self.add_builtin_macro("__FILE__", builtin_obj(FILE));
	self.add_builtin_macro("__LINE__", builtin_obj(LINE));
	self.add_builtin_macro("__COUNTER__", builtin_obj(COUNTER));
	self.add_builtin_macro("__DATE__", builtin_obj(DATE));
	self.add_builtin_macro("__TIME__", builtin_obj(TIME));
	self.add_builtin_macro("__TIMESTAMP__", builtin_obj(TIMESTAMP));

	if (emulate == NO || emulate == CLANG)
	{
		self.add_builtin_macro("__BASE_FILE__", builtin_obj(BASE_FILE));
		self.add_builtin_macro("__FILE_NAME__", builtin_obj(FILE_BASENAME));
		self.add_builtin_macro("__INCLUDE_LEVEL__", builtin_obj(INCLUDE_LEVEL));
	}
}

<*
 Zig `mTime`: cached source modification time via files.source_mtime.
 @return? aro::UNSUPPORTED
*>
fn ulong? Preprocessor.m_time(&self, SourceId id)
{
	uint key = (uint)id;
	if (try t = self.m_times.get(key)) return t;
	ulong t = self.files.source_mtime(self.files.ctx, self, id)!;
	self.m_times.set(key, t);
	return t;
}

// ---------------------------------------------------------------------------
// Token text

<*
 Zig `tokSlice`: raw token source string (the fixed lexeme, else the source
 bytes start..end). Invalidated when generated_buf grows if the token is generated.
*>
fn String Preprocessor.tok_slice(&self, RawToken token)
{
	if (try lex = token.id.lexeme()) return lex;
	Source src = self.comp.get_source(token.source);
	return src.buf[token.start:token.end - token.start];
}

<*
 Zig `expandedSliceExtra` for a token `id` at `loc`: the fixed lexeme unless
 the id allows digraphs (or is MACRO_WS with PRESERVE_MACRO_WS); otherwise
 re-tokenize the source of `loc` at its byte offset. MACRO_STRING spans up
 to and including the next '>'. Invalidated when generated_buf grows.
*>
fn String Preprocessor.expanded_slice_at(&self, TokenId id, Location loc, MacroWsHandling handling)
{
	if (try lex = id.lexeme())
	{
		if (!id.allows_digraphs(self.comp.langopts) && !(id == MACRO_WS && handling == PRESERVE_MACRO_WS)) return lex;
	}
	String buf = self.comp.get_source(loc.id).buf;
	if (id == MACRO_STRING)
	{
		uint i = loc.byte_offset;
		while (buf[i] != '>') i++;
		return buf[loc.byte_offset..i];
	}
	Tokenizer tmp;
	tmp.init(buf, source::GENERATED_ID, self.comp.langopts, &self.comp.target);
	tmp.index = loc.byte_offset;
	RawToken res = tmp.next();
	return buf[res.start:res.end - res.start];
}

<* Zig `expandedSliceExtra`. *>
fn String Preprocessor.expanded_slice_extra(&self, TokenWithExpansionLocs tok, MacroWsHandling handling) => self.expanded_slice_at(tok.id, tok.loc, handling);

<* Zig `expandedSlice`: get expanded token source string. *>
fn String Preprocessor.expanded_slice(&self, TokenWithExpansionLocs tok) => self.expanded_slice_at(tok.id, tok.loc, SINGLE_MACRO_WS);

<* Zig `expandedSlice` on an output token (`pp.tokens.get(i)`). *>
fn String Preprocessor.tree_token_slice(&self, TreeToken tok) => self.expanded_slice_at(tok.id, tok.loc, SINGLE_MACRO_WS);

// ---------------------------------------------------------------------------
// Diagnostics

<*
 Zig `err` core: skip if `$diag`'s effective kind is OFF; otherwise format
 `$diag.fmt` with the varargs (checked by `@format` at compile time),
 temporarily stop suppressing system-header warnings for entries with
 `meta.show_in_system_headers`, and add at `loc` with the macro backtrace of
 `expansion_locs` (note_msg_loc = true). `$diag` is any diagnostic enum value
 (Diagnostic, Diagnostic, a pragma's own enum, ...).
 @return? compilation::FATAL_ERROR
*>
macro void? Preprocessor.err_at(&self, Location loc, Location[] expansion_locs, $diag, ...)
{
	if (!self.diagnostics.@enabled($diag)) return;
	@pool()
	{
		String text = string::tformat($diag.fmt, ...$vaarg);
		return self.add_diag(diagnostics::@message_at($diag, text, loc.expand(self.comp)), expansion_locs, $diag.meta.show_in_system_headers);
	};
}

<* Add a formatted pp message, honouring show_in_system_headers. *>
fn void? Preprocessor.add_diag(&self, Message m, Location[] expansion_locs, bool show_in_system_headers)
{
	bool old_suppress = self.diagnostics.state.suppress_system_headers;
	defer self.diagnostics.state.suppress_system_headers = old_suppress;
	if (show_in_system_headers) self.diagnostics.state.suppress_system_headers = false;
	return self.diagnostics.add_with_location(self.comp, m, expansion_locs, true);
}

<*
 Zig `err` with a TokenWithExpansionLocs: report at `tok.loc` through its expansion locations.
 @return? compilation::FATAL_ERROR
*>
macro void? Preprocessor.err(&self, TokenWithExpansionLocs tok, $diag, ...)
{
	return self.err_at(tok.loc, tok.expansion_slice(), $diag, ...$vaarg);
}

<*
 Zig `err` with a RawToken: report at (source, start, line), no backtrace.
 @return? compilation::FATAL_ERROR
*>
macro void? Preprocessor.err_raw(&self, RawToken raw, $diag, ...)
{
	return self.err_at(tokens::raw_location(raw), {}, $diag, ...$vaarg);
}

<*
 Zig `err` with a Source.Location: report at `loc`, no backtrace.
 @return? compilation::FATAL_ERROR
*>
macro void? Preprocessor.err_loc(&self, Location loc, $diag, ...)
{
	return self.err_at(loc, {}, $diag, ...$vaarg);
}

<*
 Zig `fatal`: report `text` as a fatal error at `raw`. Always fails.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.fatal(&self, RawToken raw, String text)
{
	self.diagnostics.add({
		.kind = FATAL_ERROR,
		.text = text,
		.has_location = true,
		.location = tokens::raw_location(raw).expand(self.comp),
	})!;
	return compilation::FATAL_ERROR~;
}

<*
 Zig `fatalNotFound`: "'<filename>' not found" as a fatal error at `tok`
 through its expansion locations (with fatal_errors temporarily on). Always fails.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.fatal_not_found(&self, TokenWithExpansionLocs tok, String filename)
{
	bool old = self.diagnostics.state.fatal_errors;
	self.diagnostics.state.fatal_errors = true;
	defer self.diagnostics.state.fatal_errors = old;

	DString text;
	text.init(self.comp.gpa);
	defer text.free();
	text.appendf("'%s' not found", filename);
	self.diagnostics.add_with_location(self.comp, {
		.kind = FATAL_ERROR,
		.text = text.str_view(),
		.has_location = true,
		.location = tok.loc.expand(self.comp),
	}, tok.expansion_slice(), true)!;
	return compilation::FATAL_ERROR~;
}

<* Zig `verboseLog`: "<path>:<line>:<col>: <msg>\n<source line>\n" to stderr; write errors are ignored. *>
fn void Preprocessor.verbose_log(&self, RawToken raw, String msg)
{
	Source src = self.comp.get_source(raw.source);
	ExpandedLocation lc = src.line_col(tokens::raw_location(raw));
	io::eprintf("%s:%d:%d: %s\n%s\n", src.path, lc.line_no, lc.col, msg, lc.line);
}

// ---------------------------------------------------------------------------
// Output token list

<*
 Zig `addToken`: unescape UCNs, then append; the token's expansion array (if
 any) moves into expansion_entries (the caller must not free it).
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.add_token(&self, TokenWithExpansionLocs tok_arg)
{
	TokenWithExpansionLocs tok = self.unescape_ucn(tok_arg)!;
	if (tok.expansion_locs.len())
	{
		self.expansion_entries.push({ .idx = (TokenIndex)self.tokens.len(), .locs = tok.expansion_locs });
	}
	self.tokens.push({ .id = tok.id, .loc = tok.loc });
}

<* Zig `addTokenAssumeCapacity` (no UCN unescaping; growth is still allowed in C3). *>
fn void Preprocessor.add_token_assume_capacity(&self, TokenWithExpansionLocs tok)
{
	if (tok.expansion_locs.len())
	{
		self.expansion_entries.push({ .idx = (TokenIndex)self.tokens.len(), .locs = tok.expansion_locs });
	}
	self.tokens.push({ .id = tok.id, .loc = tok.loc });
}

<* Zig `ensureTotalTokenCapacity`. *>
fn void Preprocessor.ensure_total_token_capacity(&self, sz capacity)
{
	if (capacity > self.tokens.len()) self.tokens.reserve(capacity - self.tokens.len());
	if (capacity > self.expansion_entries.len()) self.expansion_entries.reserve(capacity - self.expansion_entries.len());
}

<* Zig `ensureUnusedTokenCapacity`. *>
fn void Preprocessor.ensure_unused_token_capacity(&self, sz capacity)
{
	self.tokens.reserve(capacity);
	self.expansion_entries.reserve(capacity);
}

<* Zig `expansionSlice(tok)`: binary search expansion_entries for output token `tok`; empty if none. *>
fn Location[] Preprocessor.expansion_slice(&self, TokenIndex tok)
{
	sz lo = 0;
	sz hi = self.expansion_entries.len();
	while (lo < hi)
	{
		sz mid = lo + (hi - lo) / 2;
		TokenIndex idx = self.expansion_entries[mid].idx;
		if (idx == tok) return self.expansion_entries[mid].locs.array_view();
		if (idx < tok)
		{
			lo = mid + 1;
		}
		else
		{
			hi = mid;
		}
	}
	return {};
}

<* Zig `getTokenCount` / `getTokenState`. *>
fn TokenCount Preprocessor.get_token_count(&self)
{
	return { .tokens_len = self.tokens.len(), .expansion_entries_len = self.expansion_entries.len() };
}

<*
 Zig `setTokenCount`: shrink the output to `count`, freeing dropped expansion arrays.
 @require self.tokens.len() >= count.tokens_len : "cannot grow the token list"
*>
fn void Preprocessor.set_token_count(&self, TokenCount count)
{
	foreach (e : self.expansion_entries.array_view()[count.expansion_entries_len..]) e.locs.free();
	self.tokens.size = count.tokens_len;
	self.expansion_entries.size = count.expansion_entries_len;
}

<* Zig `restoreTokenState`: like set_token_count but does NOT free the dropped arrays (the caller did). *>
fn void Preprocessor.restore_token_state(&self, TokenCount state)
{
	self.tokens.size = state.tokens_len;
	self.expansion_entries.size = state.expansion_entries_len;
}

<* Zig `addIncludeStart`: an INCLUDE_START marker (offset maxInt(u32), line 1) unless linemarkers are off. *>
fn void? Preprocessor.add_include_start(&self, SourceId src)
{
	if (self.linemarkers == NONE) return;
	self.add_token({ .id = INCLUDE_START, .loc = { .id = src, .byte_offset = 0xFFFF_FFFF, .line = 1 } })!;
}

<* Zig `addIncludeResume`. *>
fn void? Preprocessor.add_include_resume(&self, SourceId src, uint offset, uint line)
{
	if (self.linemarkers == NONE) return;
	self.add_token({ .id = INCLUDE_RESUME, .loc = { .id = src, .byte_offset = offset, .line = line } })!;
}

// ---------------------------------------------------------------------------
// Entry points

<* Zig `preprocessSources` argument struct. *>
struct PreprocessSources
{
	Source main;
	Source builtin;
	bool has_command_line;
	Source command_line;
	Source[] imacros;
	Source[] implicit_includes;
}

<*
 Zig `preprocessSources`: preprocess a compilation unit (builtin source,
 command line, -imacros, -include, then main) into `tokens`, append the eof
 token and clear the buffers.
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn void? Preprocessor.preprocess_sources(&self, PreprocessSources sources)
{
	self.add_include_start(sources.main.id)!;

	self.include_depth = 1;
	self.add_include_start(sources.builtin.id)!;
	self.preprocess(sources.builtin)!;

	if (sources.has_command_line)
	{
		self.add_include_start(sources.command_line.id)!;
		self.preprocess(sources.command_line)!;

		foreach (imacro : sources.imacros)
		{
			self.add_include_start(imacro.id)!;
			TokenCount token_count = self.get_token_count();
			self.preprocess(imacro)!;
			assert(self.include_depth == 1);
			self.set_token_count(token_count);
			self.add_include_resume(sources.command_line.id, 0, 1)!;
		}

		foreach (header : sources.implicit_includes)
		{
			self.add_include_start(header.id)!;
			self.preprocess(header)!;
			self.add_include_resume(sources.command_line.id, 0, 1)!;
			assert(self.include_depth == 1);
		}
	}
	else
	{
		assert(sources.imacros.len == 0);
		assert(sources.implicit_includes.len == 0);
	}
	self.include_depth = 0;

	self.add_include_resume(sources.main.id, 0, 1)!;
	TokenWithExpansionLocs eof = self.preprocess(sources.main)!;
	self.add_token(eof)!;
	self.clear_buffers();
}

<*
 Zig `preprocess`: preprocess one source, returning its eof token (not yet
 added). STOP_PREPROCESSING cannot escape here (Zig `unreachable`).
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn TokenWithExpansionLocs? Preprocessor.preprocess(&self, Source src)
{
	if (self.dependencies && src.id == self.base_file) self.dependencies.add_dependency(src.path);
	TokenWithExpansionLocs? eof = self.preprocess_extra(src);
	if (catch f = eof)
	{
		if (f == STOP_PREPROCESSING) unreachable("StopPreprocessing escaped from the main file");
		return f~;
	}
	eof.check_ms_eof(src, self.comp)!;
	return eof;
}

<*
 Zig `tokenize`: tokenize a file without any preprocessing, appending every
 token (not the eof) and returning the eof token.
 @require self.linemarkers == NONE && !self.preserve_whitespace
 @return? compilation::FATAL_ERROR
*>
fn TreeToken? Preprocessor.tokenize(&self, Source src)
{
	Tokenizer tokenizer;
	tokenizer.init(src.buf, src.id, self.comp.langopts, &self.comp.target, src.splice_locs);
	self.ensure_total_token_capacity(self.tokens.len() + src.buf.len / 8);
	while (true)
	{
		RawToken tok = tokenizer.next();
		TokenWithExpansionLocs t = tokens::from_raw(tok);
		if (tok.id == EOF) return { .id = t.id, .loc = t.loc };
		self.add_token(t)!;
	}
}

// ---------------------------------------------------------------------------
// UCN unescaping

fn sz encode_utf8(uint c, char[4]* out)
{
	if (c < 0x80)
	{
		(*out)[0] = (char)c;
		return 1;
	}
	if (c < 0x800)
	{
		(*out)[0] = (char)(0xC0 | (c >> 6));
		(*out)[1] = (char)(0x80 | (c & 0x3F));
		return 2;
	}
	if (c < 0x10000)
	{
		(*out)[0] = (char)(0xE0 | (c >> 12));
		(*out)[1] = (char)(0x80 | ((c >> 6) & 0x3F));
		(*out)[2] = (char)(0x80 | (c & 0x3F));
		return 3;
	}
	(*out)[0] = (char)(0xF0 | (c >> 18));
	(*out)[1] = (char)(0x80 | ((c >> 12) & 0x3F));
	(*out)[2] = (char)(0x80 | ((c >> 6) & 0x3F));
	(*out)[3] = (char)(0x80 | (c & 0x3F));
	return 4;
}

<*
 Zig `unescapeUcn`. INCOMPLETE_UCN: warn Diagnostic.INCOMPLETE_UCN, keep the token.
 EXTENDED_IDENTIFIER containing '\': decode it (UTF-8 kind, max 0x10FFFF, no
 encoding diagnostics) into generated_buf followed by '\n' and return a
 generated EXTENDED_IDENTIFIER made by make_generated_token from `tok`; the
 input's expansion array is freed. Any other token is returned unchanged.
 @return? compilation::FATAL_ERROR
*>
fn TokenWithExpansionLocs? Preprocessor.unescape_ucn(&self, TokenWithExpansionLocs tok)
{
	switch (tok.id)
	{
		case INCOMPLETE_UCN:
			self.err(tok, Diagnostic.INCOMPLETE_UCN)!;
		case EXTENDED_IDENTIFIER:
			String identifier = self.expanded_slice(tok);
			if (!@ok(identifier.index_of_char('\\'))) break;
			sz start = self.comp.generated_buf.len();
			self.comp.generated_buf.reserve(identifier.len + 1);
			// Re-expand: the reservation may have moved generated_buf.
			TextLiteralParser p = text_literal::text_parser(self.comp, self.expanded_slice(tok), UTF_8, 0x10FFFF, tok.loc, tok.expansion_slice());
			p.diagnose_incorrect_encoding = false;
			TextLiteralItem item;
			while (p.next(&item)!)
			{
				switch (item.tag)
				{
					case VALUE: unreachable("validated by tokenizer");
					case CODEPOINT:
						char[4] enc;
						sz n = encode_utf8(item.value, &enc);
						self.comp.generated_buf.push_all(enc[:n]);
					case IMPROPERLY_ENCODED:
					case UTF8_TEXT:
						self.comp.generated_buf.push_all((char[])item.bytes);
				}
			}
			self.comp.generated_buf.push('\n');
			self.comp.generated_buf.push(0);
			self.comp.generated_buf.size -= 1; // keep the tokenizer's NUL in spare capacity
			defer tok.expansion_locs.free();
			return self.make_generated_token(start, EXTENDED_IDENTIFIER, tok);
		default:
			break;
	}
	return tok;
}

// ---------------------------------------------------------------------------
// ExpandBuf / MacroArguments ownership helpers (shared by 13.3, 13.4, 13.5)

<* Free the expansion arrays of `toks` (not the slice itself). *>
fn void free_buf_tokens(Allocator gpa, TokenWithExpansionLocs[] toks)
{
	foreach (t : toks) t.expansion_locs.free();
}

<* Free every token's expansion array and the list itself. *>
fn void free_expand_buf(Allocator gpa, ExpandBuf* buf)
{
	free_buf_tokens(gpa, buf.array_view());
	buf.free();
}

<* Zig `removePlacemarkers`: drop (and free) every PLACEMARKER, keeping the order of the rest. *>
fn void remove_placemarkers(Allocator gpa, ExpandBuf* buf)
{
	sz out = 0;
	for (sz i = 0; i < buf.len(); i++)
	{
		TokenWithExpansionLocs t = buf.entries[i];
		if (t.id == PLACEMARKER)
		{
			t.expansion_locs.free();
			continue;
		}
		buf.entries[out++] = t;
	}
	buf.size = out;
}

<* Zig `deinitMacroArguments`: free every argument's tokens' arrays, the slices and the list. *>
fn void deinit_macro_arguments(Allocator gpa, MacroArguments* args)
{
	foreach (item : args.array_view())
	{
		free_buf_tokens(gpa, item);
		if (item.len) alloc::free(gpa, item.ptr);
	}
	args.free();
}

<* Zig `bufCopyTokens`: append a dupe of each of `toks` to `buf`, each with `src` added as expansion locations. *>
fn void buf_copy_tokens(Allocator gpa, ExpandBuf* buf, TokenWithExpansionLocs[] toks, Location[] src)
{
	buf.reserve(toks.len);
	foreach (tok : toks)
	{
		TokenWithExpansionLocs copy = tok.dupe(gpa);
		copy.add_expansion_location(gpa, src);
		buf.push(copy);
	}
}

TokenWithExpansionLocs[1] paste_placemarker @private = { { .id = PLACEMARKER, .loc = { .id = source::GENERATED_ID } } };

<*
 Zig `getPasteArgs`: treat whitespace-only paste arguments as empty, i.e.
 return a single static PLACEMARKER (generated, offset 0, line 0; no
 expansion array, never freed) instead of `args`.
*>
fn TokenWithExpansionLocs[] get_paste_args(TokenWithExpansionLocs[] args)
{
	foreach (tok : args)
	{
		if (tok.id != MACRO_WS) return args;
	}
	return paste_placemarker[..];
}

// ---------------------------------------------------------------------------
// Plan-15 directive support: #include and its header-name helpers, ported from
// Zig findIncludeFilenameToken, findIncludeSource and include.

<*
 Zig `findIncludeFilenameToken`: the header name of an #include. A '<' first
 token is re-read up to '>' on the same line (MACRO_STRING). A STRING_LITERAL or
 MACRO_STRING is taken as is; with null embed_args a non-newline token after it
 is Diagnostic.EXTRA_TOKENS_DIRECTIVE_END. Anything else is read to the end of the
 line, macro-expanded and rebuilt by reconstruct_include_string into a generated
 token. #include passes null embed_args; a non-null slice receives the trailing
 tokens and keeps top_expansion_buf alive (the #embed port).
 Diagnosed header-name errors yield INVALID_INCLUDE.
 @return? INVALID_INCLUDE, compilation::FATAL_ERROR
*>
fn TokenWithExpansionLocs? Preprocessor.find_include_filename_token(&self, RawToken first, Tokenizer* tokenizer, TokenWithExpansionLocs[]* embed_args)
{
	Allocator gpa = self.comp.gpa;
	if (first.id == ANGLE_BRACKET_LEFT)
	{
		// The tokenizer does not handle <foo> include strings so do it here.
		sz index = (sz)tokenizer.index;
		while (index < tokenizer.buf.len)
		{
			char c = tokenizer.buf[index];
			if (c == '>')
			{
				tokenizer.index = (uint)index + 1;
				first.end = tokenizer.index;
				first.id = MACRO_STRING;
				break;
			}
			if (c == '\n') break;
			index++;
		}
	}

	TokenWithExpansionLocs source_tok = tokens::from_raw(first);
	bool source_str = source_tok.id == STRING_LITERAL || source_tok.id == MACRO_STRING;

	self.top_expansion_buf.clear();
	defer {
		if (embed_args == null) free_buf_tokens(gpa, self.top_expansion_buf.array_view());
	}
	if (!source_str || embed_args != null)
	{
		if (!source_str) self.top_expansion_buf.push(source_tok);
		self.expansion_source_loc = source_tok.loc;

		while (true)
		{
			RawToken tok = tokenizer.next();
			if (tok.id == WHITESPACE)
			{
				tok.id = MACRO_WS;
			}
			else if (tok.id == NL)
			{
				tok.id = EOF;
			}
			else if (tok.id == UNTERMINATED_STRING_LITERAL || tok.id == UNTERMINATED_CHAR_LITERAL || tok.id == EMPTY_CHAR_LITERAL)
			{
				self.err_invalid_token(tok)!;
			}
			else if (tok.id == UNTERMINATED_COMMENT)
			{
				self.err_raw(tok, Diagnostic.UNTERMINATED_COMMENT)!;
			}
			else if (self.is_poisoned(tok))
			{
				self.err_raw(tok, Diagnostic.POISONED_IDENTIFIER)!;
			}
			self.top_expansion_buf.push(tokens::from_raw(tok));
			if (tok.id == EOF) break;
		}
		self.expand_macro_exhaustive(null, &self.top_expansion_buf, 0, self.top_expansion_buf.len(), NO_PRAGMA)!;
		remove_placemarkers(gpa, &self.top_expansion_buf);
	}

	if (source_str)
	{
		// Happy path, no macro expansion needed. We just check to ensure
		// that there's no trailing tokens, and we're done.
		if (embed_args != null)
		{
			*embed_args = self.top_expansion_buf.array_view();
		}
		else
		{
			// Error on extra tokens.
			RawToken nl = tokenizer.next_no_ws();
			if (nl.id != NL && nl.id != EOF)
			{
				skip_to_nl(tokenizer);
				self.err_raw(nl, Diagnostic.EXTRA_TOKENS_DIRECTIVE_END)!;
			}
		}
		return source_tok;
	}

	// Our include argument is a macro, so we need to try and expand it.
	TokenWithExpansionLocs[] dummy_trailing_toks = {};
	TokenWithExpansionLocs[]* trailing_out = &dummy_trailing_toks;
	if (embed_args != null) trailing_out = embed_args;
	// Diagnosed failures come back as "" (Zig null); a valid header name is at least 3 bytes.
	String include_str = self.reconstruct_include_string(self.top_expansion_buf.array_view(), trailing_out, source_tok)!;
	if (include_str.len == 0) return INVALID_INCLUDE~;
	TokenId id = include_str[0] == '<' ? MACRO_STRING : STRING_LITERAL;
	sz start = self.comp.generated_buf.len();
	self.gen_text(include_str);

	// Check for trailing tokens
	foreach (tok : dummy_trailing_toks)
	{
		if (tok.id == MACRO_WS || tok.id == WHITESPACE || tok.id == EOF) continue;
		self.err(tok, Diagnostic.EXTRA_TOKENS_DIRECTIVE_END)!;
		break;
	}

	return self.make_generated_token(start, id, self.top_expansion_buf[0]);
}

<*
 Zig `findIncludeSource`: the file that #include names. The filename token's
 expansion locations are freed on every exit.
 An empty filename is diagnosed and yields INVALID_INCLUDE.
 @return? INVALID_INCLUDE, compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn Source? Preprocessor.find_include_source(&self, RawToken first, Tokenizer* tokenizer, WhichInclude which)
{
	Allocator gpa = self.comp.gpa;
	TokenWithExpansionLocs filename_tok = self.find_include_filename_token(first, tokenizer, null)!;
	defer filename_tok.expansion_locs.free();

	// Check for empty filename.
	String tok_slice = self.expanded_slice_extra(filename_tok, SINGLE_MACRO_WS);
	if (tok_slice.len < 3)
	{
		self.err_raw(first, Diagnostic.EMPTY_FILENAME)!;
		return INVALID_INCLUDE~;
	}

	// Find the file. Only string literals and macro strings reach here.
	String filename = tok_slice[1 : tok_slice.len - 2];
	IncludeType include_type = filename_tok.id == STRING_LITERAL ? QUOTES : ANGLE_BRACKETS;

	Source? found = self.files.find_include(self.files.ctx, self, filename, first, include_type, which);
	if (catch f = found)
	{
		if (f == FILE_NOT_FOUND) self.fatal_not_found(filename_tok, filename)!;
		return f~;
	}
	Source src = found;
	return src;
}

<*
 Zig `include(tokenizer, which)`: #include / #include_next. A header name that
 was diagnosed (INVALID_INCLUDE) drops the directive without an error.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED
*>
fn void? Preprocessor.include(&self, Tokenizer* tokenizer, WhichInclude which)
{
	RawToken first = tokenizer.next_no_ws();
	Source? found_source = self.find_include_source(first, tokenizer, which);
	if (catch f = found_source)
	{
		if (f == INVALID_INCLUDE) return;
		return f~;
	}
	Source new_source = found_source;

	// Prevent stack overflow
	self.include_depth++;
	defer self.include_depth--;
	if (self.include_depth > MAX_INCLUDE_DEPTH)
	{
		self.err_raw(first, Diagnostic.TOO_MANY_INCLUDES)!;
		return STOP_PREPROCESSING~;
	}

	if (try guard = self.include_guards.get((uint)new_source.id))
	{
		if (self.defines.get(guard) != null) return;
	}

	// Run any before_include pragma hooks. The skipping handler's name is logged.
	String skipper_name = "";
	pragma::IncludePragmaResult include_result = self.comp.pragmas.before_include_named(self, new_source, &skipper_name);
	if (include_result == pragma::IncludePragmaResult.SKIP_INCLUDE)
	{
		if (self.verbose) self.verbose_log(first, string::tformat("skipping include file %s under direction of \"%s\" pragma", new_source.path, skipper_name));
		return;
	}
	if (include_result == pragma::IncludePragmaResult.FATAL) return compilation::FATAL_ERROR~;

	if (self.dependencies) self.dependencies.add_dependency(new_source.path);
	if (self.verbose) self.verbose_log(first, string::tformat("include file %s", new_source.path));

	TokenCount token_state = self.get_token_count();
	self.add_include_start(new_source.id)!;
	TokenWithExpansionLocs? eof = self.preprocess_extra(new_source);
	if (catch f = eof)
	{
		// A depth-limit error stops the current included file only. Drop all
		// tokens emitted by it, as Zig does before returning to its includer.
		if (f == STOP_PREPROCESSING)
		{
			self.set_token_count(token_state);
			return;
		}
		return f~;
	}
	eof.check_ms_eof(new_source, self.comp)!;
	if (self.preserve_whitespace && (self.tokens.len() == 0 || self.tokens[self.tokens.len() - 1].id != NL))
	{
		self.add_token({ .id = NL, .loc = { .id = tokenizer.source, .line = tokenizer.line } })!;
	}
	if (self.linemarkers == NONE) return;
	RawToken next = first;
	while (true)
	{
		Tokenizer tmp = *tokenizer;
		next = tmp.next_no_ws();
		if (next.id != NL) break;
		*tokenizer = tmp;
	}
	self.add_include_resume(next.source, next.end, next.line)!;
}

<*
 Zig `EmbedArgIterator.Range`.
*>
struct EmbedArgRange
{
	TokenWithExpansionLocs tok;
	sz start;
	sz end;
}

<* Zig `EmbedArgIterator.Param.unknown`. *>
struct EmbedUnknownParam
{
	bool has_vendor;
	TokenWithExpansionLocs vendor;
	TokenWithExpansionLocs name;
}

<* Zig `EmbedArgIterator.Param` tag. *>
enum EmbedParamTag : char
{
	PREFIX,
	IF_EMPTY,
	SUFFIX,
	LIMIT,
	UNKNOWN,
	INVALID,
}

<* Zig `EmbedArgIterator.Param` (tag plus its active payload). *>
struct EmbedParam
{
	EmbedParamTag tag;
	union
	{
		EmbedArgRange prefix;
		EmbedArgRange if_empty;
		EmbedArgRange suffix;
		EmbedArgRange limit;
		EmbedUnknownParam unknown;
	}
}

<*
 Zig `EmbedArgIterator`: parse #embed parameters from expanded tokens and
 preserve their expansion locations when adding prefix/if_empty/suffix.
*>
struct EmbedArgIterator
{
	sz i;
	TokenWithExpansionLocs[] toks;
	TokenWithExpansionLocs eof;
	Preprocessor* pp;
}

<* Zig `EmbedArgIterator.next`: skip whitespace, comments and MACRO_WS. *>
fn TokenWithExpansionLocs EmbedArgIterator.next(&self)
{
	while (self.i < self.toks.len)
	{
		TokenWithExpansionLocs tok = self.toks[self.i++];
		if (tok.id == WHITESPACE || tok.id == COMMENT || tok.id == MACRO_WS) continue;
		return tok;
	}
	return self.eof;
}

<* Zig `EmbedArgIterator.peek`: skip whitespace, comments and MACRO_WS. *>
fn TokenWithExpansionLocs EmbedArgIterator.peek(&self)
{
	while (self.i < self.toks.len)
	{
		TokenWithExpansionLocs tok = self.toks[self.i];
		if (tok.id == WHITESPACE || tok.id == COMMENT || tok.id == MACRO_WS)
		{
			self.i++;
			continue;
		}
		return tok;
	}
	return self.eof;
}

<* Zig `EmbedArgIterator.param`; false ends parameter iteration. @return? compilation::FATAL_ERROR *>
fn bool? EmbedArgIterator.param(&self, EmbedParam* out)
{
	TokenWithExpansionLocs first = self.next();
	if (first.id == EOF) return false;
	if (first.id != IDENTIFIER)
	{
		self.pp.err(first, Diagnostic.EMBED_PARAM_IDENTIFIER)!;
		*out = { .tag = INVALID };
		return true;
	}

	bool has_vendor = false;
	TokenWithExpansionLocs vendor;
	TokenWithExpansionLocs name = first;
	if (self.peek().id == COLON_COLON)
	{
		has_vendor = true;
		vendor = first;
		self.next(); // ::
		name = self.next();
		if (name.id != IDENTIFIER)
		{
			self.pp.err(name, Diagnostic.EMBED_PARAM_IDENTIFIER)!;
			*out = { .tag = INVALID };
			return true;
		}
	}

	bool has_args = false;
	EmbedArgRange args;
	if (self.peek().id == L_PAREN)
	{
		TokenWithExpansionLocs l_paren = self.next();
		sz start = self.i;
		sz parens = 0;
		while (true)
		{
			TokenWithExpansionLocs tok = self.next();
			if (tok.id == L_PAREN) parens++;
			if (tok.id == R_PAREN)
			{
				if (parens == 0) break;
				parens--;
			}
			if (tok.id == EOF)
			{
				self.pp.err(tok, Diagnostic.CLOSING_PAREN)!;
				self.pp.err(l_paren, Diagnostic.TO_MATCH_PAREN)!;
				*out = { .tag = INVALID };
				return true;
			}
		}
		args = { .tok = name, .start = start, .end = self.i - 1 };
		has_args = true;
	}

	if (has_vendor)
	{
		*out = { .tag = UNKNOWN, .unknown = { .has_vendor = true, .vendor = vendor, .name = name } };
		return true;
	}
	if (!has_args)
	{
		self.pp.err(name, Diagnostic.EMBED_PARAM_ARGS)!;
		return false;
	}

	String param_name = attribute_normalize(self.pp.expanded_slice(name));
	if (param_name == "limit")
	{
		*out = { .tag = LIMIT, .limit = args };
	}
	else if (param_name == "prefix")
	{
		*out = { .tag = PREFIX, .prefix = args };
	}
	else if (param_name == "suffix")
	{
		*out = { .tag = SUFFIX, .suffix = args };
	}
	else if (param_name == "if_empty")
	{
		*out = { .tag = IF_EMPTY, .if_empty = args };
	}
	else
	{
		*out = { .tag = UNKNOWN, .unknown = { .has_vendor = false, .name = name } };
	}
	return true;
}

<* Zig `EmbedArgIterator.addTokens`; range indices are half-open. @return? compilation::FATAL_ERROR, STOP_PREPROCESSING, aro::UNSUPPORTED *>
fn void? EmbedArgIterator.add_tokens(&self, EmbedArgRange range)
{
	self.pp.add_tokens_from_expand_buf(self.toks[range.start : range.end - range.start], self.eof)!;
	// The output list now owns expansion locations for this range.
	for (sz i = range.start; i < range.end; i++) self.toks[i].expansion_locs = {};
}

<*
 Zig `embed`: macro-expanded filename and EmbedArgIterator parameters.
 @return? compilation::FATAL_ERROR, FILE_NOT_FOUND
*>
fn void? Preprocessor.embed(&self, Tokenizer* tokenizer)
{
	Allocator gpa = self.comp.gpa;
	self.top_expansion_buf.clear();
	defer free_buf_tokens(gpa, self.top_expansion_buf.array_view());
	RawToken first = tokenizer.next_no_ws();
	TokenWithExpansionLocs[] embed_args = {};
	TokenWithExpansionLocs? filename_result = self.find_include_filename_token(first, tokenizer, &embed_args);
	if (catch f = filename_result)
	{
		if (f == INVALID_INCLUDE) return;
		return f~;
	}
	TokenWithExpansionLocs filename_tok = filename_result;
	defer filename_tok.expansion_locs.free();

	String tok_slice = self.expanded_slice_extra(filename_tok, SINGLE_MACRO_WS);
	if (tok_slice.len < 3)
	{
		self.err_raw(first, Diagnostic.EMPTY_FILENAME)!;
		return;
	}
	String filename = tok_slice[1 : tok_slice.len - 2];
	IncludeType include_type = filename_tok.id == STRING_LITERAL ? QUOTES : ANGLE_BRACKETS;

	TokenWithExpansionLocs eof = embed_args[embed_args.len - 1];
	embed_args = embed_args[0 : embed_args.len - 1];
	EmbedArgIterator it = { .toks = embed_args, .eof = eof, .pp = self };
	ulong limit = EMBED_UNLIMITED;
	bool seen_limit = false;
	bool has_prefix = false;
	EmbedArgRange prefix;
	bool has_if_empty = false;
	EmbedArgRange if_empty;
	bool has_suffix = false;
	EmbedArgRange suffix;

	EmbedParam param;
	while (it.param(&param)!)
	{
		switch (param.tag)
		{
			case LIMIT:
			{
				EmbedArgRange range = param.limit;
				if (seen_limit) self.err(range.tok, Diagnostic.DUPLICATE_EMBED_PARAM, "limit")!;
				seen_limit = true;
				PpExprParser parser = {
					.pp = self,
					.tokens = it.toks[range.start : range.end - range.start],
					.eof = it.toks[it.i - 1],
				};
				PpValue? value = parser.parse();
				if (catch f = value)
				{
					if (f == EXPR_FAILED) return;
					return f~;
				}
				ulong? parsed_limit = value.to_u64();
				if (catch f = parsed_limit)
				{
					if (f != NOT_REPRESENTABLE) return f~;
					self.err(range.tok, Diagnostic.INVALID_EMBED_LIMIT)!;
					return;
				}
				limit = parsed_limit;
			}
			case PREFIX:
			{
				EmbedArgRange range = param.prefix;
				if (has_prefix) self.err(range.tok, Diagnostic.DUPLICATE_EMBED_PARAM, "prefix")!;
				has_prefix = true;
				prefix = range;
			}
			case IF_EMPTY:
			{
				EmbedArgRange range = param.if_empty;
				if (has_if_empty) self.err(range.tok, Diagnostic.DUPLICATE_EMBED_PARAM, "if_empty")!;
				has_if_empty = true;
				if_empty = range;
			}
			case SUFFIX:
			{
				EmbedArgRange range = param.suffix;
				if (has_suffix) self.err(range.tok, Diagnostic.DUPLICATE_EMBED_PARAM, "suffix")!;
				has_suffix = true;
				suffix = range;
			}
			case UNKNOWN:
			{
				EmbedUnknownParam unknown = param.unknown;
				String name_str = self.expanded_slice(unknown.name);
				String unknown_name = name_str;
				if (unknown.has_vendor)
				{
					String vendor_str = self.expanded_slice(unknown.vendor);
					unknown_name = string::tformat("%s::%s", vendor_str, name_str);
				}
				self.err(unknown.name, Diagnostic.UNKNOWN_EMBED_PARAM, unknown_name)!;
				return;
			}
			case INVALID: return;
		}
	}

	char[]? found = self.files.find_embed(self.files.ctx, self, filename, first.source, include_type, limit);
	if (catch f = found)
	{
		if (f == FILE_NOT_FOUND) self.fatal_not_found(filename_tok, filename)!;
		return f~;
	}
	char[] bytes = found;
	defer if (bytes.ptr) alloc::free(gpa, bytes.ptr);

	if (has_prefix) it.add_tokens(prefix)!;
	if (bytes.len == 0)
	{
		if (has_if_empty) it.add_tokens(if_empty)!;
		if (has_suffix) it.add_tokens(suffix)!;
		return;
	}

	self.ensure_unused_token_capacity(2 * bytes.len - 1);
	uint start = (uint)self.comp.generated_buf.len();
	self.gen_text(string::tformat("%d", (uint)bytes[0] & 0xFF));
	self.add_token_assume_capacity(self.make_generated_token(start, EMBED_BYTE, filename_tok));
	foreach (byte : bytes[1..])
	{
		uint comma_at = (uint)self.comp.generated_buf.len();
		self.gen_text(string::tformat(",%d", (uint)byte & 0xFF));
		self.add_token_assume_capacity({ .id = COMMA, .loc = { .id = source::GENERATED_ID, .byte_offset = comma_at } });
		self.add_token_assume_capacity(self.make_generated_token((sz)(comma_at + 1), EMBED_BYTE, filename_tok));
	}
	self.gen_text("\n");
	if (has_suffix) it.add_tokens(suffix)!;
}

<*
 Collect a #pragma line for addTokensFromExpandBuf / eval_pragma using the
 Compilation-owned callback registry.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.pragma(&self, Tokenizer* tokenizer, TokenWithExpansionLocs pragma_tok, ExpandBuf* expand_buf)
{
	RawToken name = tokenizer.next_no_ws();
	if (name.id == NL || name.id == EOF) return;
	expand_buf.push(pragma_tok);
	expand_buf.push(tokens::from_raw(name));
	String handler_name = self.tok_slice(name);
	pragma::IPragma? handler = self.comp.pragmas.get(handler_name);
	uint expansion_index = 0;
	while (true)
	{
		RawToken tok = tokenizer.next();
		if (tok.id == WHITESPACE) continue;
		if (tok.id == EOF)
		{
			expand_buf.push({ .id = NL, .loc = { .id = source::GENERATED_ID } });
			break;
		}
		sz token_index = expand_buf.len();
		expand_buf.push(tokens::from_raw(tok));
		bool should_expand = true;
		if (try h = handler)
		{
			if (&h.should_expand_token_at_index) should_expand = h.should_expand_token_at_index(expansion_index);
		}
		if (should_expand) self.expand_macro_exhaustive(tokenizer, expand_buf, token_index, token_index + 1, NO_PRAGMA)!;
		expansion_index++;
		if (tok.id == NL) break;
	}
}

<* Zig Preprocessor.pragmaOperator: destringify an _Pragma literal and collect it as a pragma directive. *>
fn void? Preprocessor.pragma_operator(&self, TokenWithExpansionLocs string_tok, ExpandBuf* expand_buf)
{
	String spelling = self.expanded_slice(string_tok);
	if (spelling.len < 2) return;
	self.char_buf.clear();
	self.char_buf.push_all("#pragma ");
	self.destringify(spelling[1 : spelling.len - 2]);
	self.char_buf.push('\n');
	uint start = (uint)self.comp.generated_buf.len();
	self.gen_text((String)self.char_buf.array_view());
	Tokenizer generated;
	generated.init((String)self.comp.generated_buf.array_view(), source::GENERATED_ID, self.comp.langopts, &self.comp.target);
	generated.index = start;
	generated.line = self.generated_line;
	self.generated_line++;
	RawToken hash = generated.next();
	assert(hash.id == HASH);
	RawToken directive = generated.next();
	assert(directive.id == KEYWORD_PRAGMA);
	TokenWithExpansionLocs pragma_tok = tokens::from_raw(directive);
	pragma_tok.flags.pragma_directive = true;
	self.pragma(&generated, pragma_tok, expand_buf)!;
}

<* Zig Preprocessor.msPragmaOperator: append a generated pragma to the token list and dispatch its handler immediately.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING
*>
fn void? Preprocessor.ms_pragma_operator(&self, TokenWithExpansionLocs macro_tok, TokenWithExpansionLocs[] args, ExpandBuf* buf)
{
	TokenWithExpansionLocs pragma_tok = macro_tok.dupe(self.comp.gpa);
	pragma_tok.id = KEYWORD_PRAGMA;
	TokenIndex kw_idx = (TokenIndex)self.tokens.len();
	self.add_token(pragma_tok)!;
	TokenWithExpansionLocs name_tok = macro_tok;
	bool has_name = false;
	foreach (tok : args)
	{
		if (tok.id == MACRO_WS || tok.id == COMMENT) continue;
		if (!has_name)
		{
			name_tok = tok;
			has_name = true;
		}
		self.add_token(tok.dupe(self.comp.gpa))!;
	}
	self.add_token({ .id = NL, .loc = { .id = source::GENERATED_ID } })!;
	self.eval_pragma(name_tok, kw_idx)!;
}

<*
 Dispatch a registered handler. Unknown pragmas remain in the token stream,
 matching Zig's default handler.
 @return? compilation::FATAL_ERROR, STOP_PREPROCESSING
*>
fn void? Preprocessor.eval_pragma(&self, TokenWithExpansionLocs name_tok, TokenIndex pragma_start)
{
	TokenIndex name_idx = pragma_start + 1;
	String name = self.tree_token_slice(self.tokens[name_idx]);
	if (try handler = self.comp.pragmas.get(name))
	{
		if (!&handler.preprocessor_handler) return;
		switch (handler.preprocessor_handler(self, name_idx))
		{
			case HANDLED: return;
			case UNKNOWN: break;
			case STOP_PREPROCESSING: return STOP_PREPROCESSING~;
			case FATAL: return compilation::FATAL_ERROR~;
		}
	}
	self.err(name_tok, Diagnostic.UNKNOWN_PRAGMA)!;
}
