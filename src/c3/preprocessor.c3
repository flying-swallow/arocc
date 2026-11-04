// Port of src/aro/Preprocessor.zig (plan 13): the in-memory preprocessor.
//
// How the parts fit
// =================
// One module, `aro::preprocessor`, spread over files that each have a single
// owner (plan 13 "Parallel agent breakdown"); two helper modules sit beside it.
//
//   tokens.c3 (aro::tokens, stage 0, implemented)
//       TreeToken (Zig Tree.Token), Precedence, TokenWithExpansionLocs with
//       its flags and bounded expansion-location chains. Ownership rules for
//       expansion arrays are in that file's header and apply everywhere below.
//   hideset.c3 (aro::hideset, 13.1 `hideset`)
//       Hideset lists keyed by token location: get/put/prepend/union_of/
//       intersection/contains. Reset (clear_retaining_capacity) before every
//       top-level expansion.
//   preprocessor.c3 (this file, stage 0, implemented; integrator afterwards)
//       Preprocessor/Macro/MacroTable types, providers, init/free, error
//       reporting (err/err_raw/err_loc/fatal), the output token list
//       (add_token, expansion_entries), token slices (tok_slice,
//       expanded_slice), unescape_ucn, the shared ExpandBuf ownership helpers,
//       preprocess/preprocess_sources/tokenize wrappers and the plan-15
//       placeholders (include/embed/pragma -> aro::UNSUPPORTED).
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
//       add_tokens_from_expand_buf. Builtin macros are dispatched to the
//       BuiltinProvider.
//   macro_paste.c3 (13.4 `stringify-paste`)
//       # stringify / destringify, ## paste_tokens with invalid-paste
//       diagnostics, make_generated_token(_extra) (all writes of generated
//       tokens into Compilation.generated_buf).
//   pp_print.c3 (13.6 `probe`)
//       prettyPrintTokens (-E output), macro dumps, line markers, C string
//       escaping. test/migration/pp_probe.c3 drives everything in memory.
//
// Data flow for one file: preprocess -> preprocess_extra reads raw tokens from
// a Tokenizer. Directives are handled in place; other tokens go to
// expand_macro, which puts the token into `top_expansion_buf`, runs
// expand_macro_exhaustive (pulling more raw tokens from the tokenizer when a
// function-like macro needs its arguments) and moves the result into `tokens`
// via add_tokens_from_expand_buf -> add_token. The eof token is returned and
// the caller (preprocess_sources / the probe) appends it.
//
// Providers. Things later plans implement are reached only through
// `BuiltinProvider` (plan 14: source epoch, builtin object macros such as
// __FILE__/__LINE__, builtin function macros such as __has_include / _Pragma)
// and `FileProvider` (plan 15: include/embed lookup, mtimes). Their defaults
// return aro::UNSUPPORTED; nothing silently succeeds. #include, #include_next,
// #embed and #pragma also return aro::UNSUPPORTED until plan 15.
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
//    err_loc (plain location). Arguments are diagnostics::DiagArg values.
//  - Zig's `dep_file` and `comp.getPragma` are behind FileProvider / plan 15.
//  - `?SourceEpoch` options are `has_source_epoch` + `source_epoch`; without
//    one, init asks the BuiltinProvider (unsupported until plan 14).
module aro::preprocessor;
import aro::source, aro::tokenizer, aro::tokens, aro::hideset, aro::compilation, aro::diagnostics;
import aro::lang_opts, aro::string_interner, aro::text_literal;
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
 Plan 14: Zig `comp.environment.sourceEpoch(io)` including the
 DIAG_INVALID_SOURCE_EPOCH fallback to DEFAULT_SOURCE_EPOCH. Called by init
 when InitOptions has no source epoch.
*>
alias SourceEpochFn = fn SourceEpoch? (void* ctx, Preprocessor* pp);

<*
 Plan 14: Zig expandObjMacro's `.macro_builtin_obj` arm. Append the expansion
 of builtin object macro `kind` to `buf` (normally one generated token made
 with make_generated_token from `tok`, the tokFromRaw of the body token;
 location info comes from pp.expansion_source_loc). The caller already
 reserved one slot.
*>
alias ExpandBuiltinObjFn = fn void? (void* ctx, Preprocessor* pp, BuiltinObject kind, TokenWithExpansionLocs tok, ExpandBuf* buf);

<*
 Plan 14 (and 15 for _Pragma / __pragma): Zig expandFuncMacro's
 `.macro_param_builtin_func` arm for `kind`. `macro_tok` is the macro name
 token, `raw` the body token (MACRO_PARAM_BUILTIN_FUNC), `expanded_args` the
 (possibly unexpanded, see should_expand_args) arguments. Append results to `buf`.
*>
alias ExpandBuiltinFuncFn = fn void? (void* ctx, Preprocessor* pp, BuiltinFunc kind, TokenWithExpansionLocs macro_tok, RawToken raw, MacroArguments* expanded_args, EvalContext eval_ctx, ExpandBuf* buf);

<* Builtin macro services (plan 14). The default returns aro::UNSUPPORTED from every hook. *>
struct BuiltinProvider
{
	void* ctx;
	SourceEpochFn source_epoch;
	ExpandBuiltinObjFn expand_obj;
	ExpandBuiltinFuncFn expand_func;
}

fn SourceEpoch? unsupported_source_epoch(void* ctx, Preprocessor* pp) => aro::UNSUPPORTED~;
fn void? unsupported_expand_obj(void* ctx, Preprocessor* pp, BuiltinObject kind, TokenWithExpansionLocs tok, ExpandBuf* buf) => aro::UNSUPPORTED~;
fn void? unsupported_expand_func(void* ctx, Preprocessor* pp, BuiltinFunc kind, TokenWithExpansionLocs macro_tok, RawToken raw, MacroArguments* expanded_args, EvalContext eval_ctx, ExpandBuf* buf) => aro::UNSUPPORTED~;

const BuiltinProvider UNSUPPORTED_BUILTINS = { null, &unsupported_source_epoch, &unsupported_expand_obj, &unsupported_expand_func };

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
	Location* locs;
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
	char include_depth;
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

	BuiltinProvider builtins;
	FileProvider files;
}

<*
 Zig `Preprocessor.init`. Takes the source epoch from `options` or asks
 `builtins.source_epoch`; registers the builtin macros when
 options.add_builtin_macros. Zig's `comp.pragmaEvent(.before_preprocess)`
 belongs to plan 15 and is not called. On failure everything is released.
 @return? compilation::FATAL_ERROR, aro::UNSUPPORTED
*>
fn void? Preprocessor.init(&self, Compilation* comp, InitOptions options, BuiltinProvider builtins = UNSUPPORTED_BUILTINS, FileProvider files = UNSUPPORTED_FILES)
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
		.builtins = builtins,
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
	defer catch self.free();

	if (!options.has_source_epoch)
	{
		self.source_epoch = self.builtins.source_epoch(self.builtins.ctx, self)!;
	}
	if (options.add_builtin_macros) self.add_builtin_macros();
}

<*
 Zig `deinit`: frees every owned buffer, all expansion arrays in
 `expansion_entries` and the arena (not the elements of top_expansion_buf).
*>
fn void Preprocessor.free(&self)
{
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
	foreach (e : self.expansion_entries) tokens::free_expansion_locs(gpa, e.locs);
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

<* Zig `addBuiltinMacros`: registers the builtin macro names (their expansion is plan 14's BuiltinProvider). *>
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
	tmp.init(buf, source::GENERATED_ID, self.comp.langopts);
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
 Zig `err` core: skip if the record's effective kind is OFF; otherwise format
 `d.fmt` with `args`, temporarily stop suppressing system-header warnings for
 records with show_in_system_headers, and add at `loc` with the macro
 backtrace of `expansion_locs` (note_msg_loc = true).
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.err_at(&self, Location loc, Location[] expansion_locs, PpDiagnostic d, DiagArg[] args)
{
	Message probe = d.message(d.fmt);
	if (self.diagnostics.effective_kind(&probe) == OFF) return;
	bool old_suppress = self.diagnostics.state.suppress_system_headers;
	defer self.diagnostics.state.suppress_system_headers = old_suppress;
	if (d.show_in_system_headers) self.diagnostics.state.suppress_system_headers = false;

	DString text;
	text.init(self.comp.gpa);
	defer text.free();
	if (catch diagnostics::format_args(&text, d.fmt, args)) unreachable("formatting into a DString failed");
	self.diagnostics.add_with_location(self.comp, d.message_at(text.str_view(), loc.expand(self.comp)), expansion_locs, true)!;
}

<*
 Zig `err` with a TokenWithExpansionLocs: report at `tok.loc` through its expansion locations.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.err(&self, TokenWithExpansionLocs tok, PpDiagnostic d, DiagArg[] args = {})
{
	return self.err_at(tok.loc, tok.expansion_slice(), d, args);
}

<*
 Zig `err` with a RawToken: report at (source, start, line), no backtrace.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.err_raw(&self, RawToken raw, PpDiagnostic d, DiagArg[] args = {})
{
	return self.err_at(tokens::raw_location(raw), {}, d, args);
}

<*
 Zig `err` with a Source.Location: report at `loc`, no backtrace.
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.err_loc(&self, Location loc, PpDiagnostic d, DiagArg[] args = {})
{
	return self.err_at(loc, {}, d, args);
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
	if (tok.expansion_locs)
	{
		self.expansion_entries.push({ .idx = (TokenIndex)self.tokens.len(), .locs = tok.expansion_locs });
	}
	self.tokens.push({ .id = tok.id, .loc = tok.loc });
}

<* Zig `addTokenAssumeCapacity` (no UCN unescaping; growth is still allowed in C3). *>
fn void Preprocessor.add_token_assume_capacity(&self, TokenWithExpansionLocs tok)
{
	if (tok.expansion_locs)
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
		if (idx == tok) return tokens::expansion_locs_slice(self.expansion_entries[mid].locs);
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
	foreach (e : self.expansion_entries.array_view()[count.expansion_entries_len..]) tokens::free_expansion_locs(self.comp.gpa, e.locs);
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
	tokenizer.init(src.buf, src.id, self.comp.langopts, src.splice_locs);
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
 Zig `unescapeUcn`. INCOMPLETE_UCN: warn DIAG_INCOMPLETE_UCN, keep the token.
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
			self.err(tok, DIAG_INCOMPLETE_UCN)!;
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
			defer tokens::free_expansion_locs(self.comp.gpa, tok.expansion_locs);
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
	foreach (t : toks) tokens::free_expansion_locs(gpa, t.expansion_locs);
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
			tokens::free_expansion_locs(gpa, t.expansion_locs);
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
// Plan 15 placeholders (include / embed / pragma). They consume nothing and
// return aro::UNSUPPORTED so callers stop explicitly.

<*
 Zig `include(tokenizer, which)`: #include / #include_next. Plan 15.
 @return? aro::UNSUPPORTED
*>
fn void? Preprocessor.include(&self, Tokenizer* tokenizer, WhichInclude which) => aro::UNSUPPORTED~;

<*
 Zig `embed(tokenizer)`: #embed. Plan 15.
 @return? aro::UNSUPPORTED
*>
fn void? Preprocessor.embed(&self, Tokenizer* tokenizer) => aro::UNSUPPORTED~;

<*
 Zig `pragma(tokenizer, pragma_tok, expand_buf)` (#pragma line collection)
 followed by addTokensFromExpandBuf / evalPragma. Plan 15.
 @return? aro::UNSUPPORTED
*>
fn void? Preprocessor.pragma(&self, Tokenizer* tokenizer, TokenWithExpansionLocs pragma_tok, ExpandBuf* expand_buf) => aro::UNSUPPORTED~;

<*
 Zig `evalPragma(name_tok, pragma_start)`: run a pragma's preprocessor callback. Plan 15.
 @return? aro::UNSUPPORTED
*>
fn void? Preprocessor.eval_pragma(&self, TokenWithExpansionLocs name_tok, TokenIndex pragma_start) => aro::UNSUPPORTED~;
