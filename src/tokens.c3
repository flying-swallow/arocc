// Port of the token part of src/aro/Tree.zig: `Tree.Token` (here `TreeToken`),
// its operator precedence table, `TokenIndex` and `TokenWithExpansionLocs`
// with its bounded, sentinel-terminated expansion location chains. It is a
// shared module so the preprocessor does not depend on the AST.
//
// Ownership rules (Zig's, made explicit):
//  - A `TokenWithExpansionLocs` value OWNS its `expansion_locs` list (or holds
//    an empty, unallocated one). Copying the struct copies the List header,
//    not the backing array: exactly one copy may be freed
//    (`expansion_locs.free()`) or handed on (to `Preprocessor.add_token`, which
//    moves it into `expansion_entries`). Use `dupe` to get an independent copy.
//  - Lists are allocated with the allocator passed to `add_expansion_location`
//    (always `Compilation.gpa` in the preprocessor).
//  - `borrowed_locs` wraps a slice owned elsewhere in a List with no
//    allocator; `free()` on it is a no-op, so it must never be grown.
//  - At most `MAX_EXPANSION_LOCS` (64) locations are kept; locations of the
//    generated source are never recorded; WHITESPACE, MACRO_WS and
//    PLACEMARKER tokens never get any.
//  - A token whose `loc.id` is `source::GENERATED_ID` points into
//    `Compilation.generated_buf` (`loc.byte_offset` is an offset into it, so it
//    stays valid when the buffer grows) and has at least one expansion location.
//
// Deviations from Zig:
//  - Zig stores a sentinel-terminated array (terminator entries plus a
//    capacity-end marker); C3 uses `List{Location}`, which tracks length and
//    capacity itself.
//  - `Precedence` is a distinct `ichar` with PREC_* constants (Zig's
//    non-exhaustive `enum(i8)`); `precedence(id)` replaces the direct enum array.
module aro::tokens;
import aro::source, aro::tokenizer, aro::compilation, aro::diagnostics;
import std::collections::list;

<* Zig `Tree.TokenIndex`. *>
alias TokenIndex = uint;

<* Maximum number of expansion locations kept per token (Zig `max_expansion_locs`). *>
const sz MAX_EXPANSION_LOCS = 64;

<* Zig `Tree.Token`: a token as stored in the final token list. *>
struct TreeToken
{
	TokenId id;
	Location loc;
}

// ---------------------------------------------------------------------------
// Zig `Tree.Token.Precedence`

typedef Precedence = ichar;

const Precedence PREC_INVALID = (Precedence)-1;
const Precedence PREC_ANY = (Precedence)0;
const Precedence PREC_COMMA = (Precedence)1;
const Precedence PREC_ASSIGN = (Precedence)2;
const Precedence PREC_BINARY_CONDITIONAL = (Precedence)3;
const Precedence PREC_CONDITIONAL = (Precedence)4;
const Precedence PREC_BOOL_OR = (Precedence)5;
const Precedence PREC_BOOL_AND = (Precedence)6;
const Precedence PREC_BIT_OR = (Precedence)7;
const Precedence PREC_BIT_XOR = (Precedence)8;
const Precedence PREC_BIT_AND = (Precedence)9;
const Precedence PREC_EQUALITY = (Precedence)10;
const Precedence PREC_COMPARISON = (Precedence)11;
const Precedence PREC_SHIFT = (Precedence)12;
const Precedence PREC_ADDITIVE = (Precedence)13;
const Precedence PREC_MULTIPLICATIVE = (Precedence)14;

<* Zig `Precedence.next`: ASSIGN and CONDITIONAL are right associative. *>
fn Precedence Precedence.next(self, Precedence min)
{
	if (self == PREC_ASSIGN) return PREC_ASSIGN;
	if (self == PREC_CONDITIONAL) return min;
	return (Precedence)((ichar)self + 1);
}

<* Zig `Precedence.lt`. *>
fn bool Precedence.lt(self, Precedence b) => (ichar)self < (ichar)b;

<* Zig `Tree.Token.precedence[id]`: PREC_INVALID for non-operators. *>
fn Precedence precedence(TokenId id)
{
	if (!id.props.binary_prec) return PREC_INVALID;
	return (Precedence)id.props.binary_prec;
}

// ---------------------------------------------------------------------------
// Zig `Tree.TokenWithExpansionLocs`

<* Zig's packed `flags` struct (bit 0 first). *>
bitstruct TokenFlags : char
{
	bool expansion_disabled : 0;
	bool is_macro_arg : 1;
	bool pragma_directive : 2;
}

<*
 A preprocessor token plus the chain of macro expansion locations it came
 through (innermost first). See the module comment for ownership. A zeroed
 value with `id` and `loc` set is valid (no flags, no locations).
*>
struct TokenWithExpansionLocs
{
	TokenId id;
	TokenFlags flags;
	<*
	 This location contains the actual token slice which might be generated.
	 If it is generated then there is guaranteed to be at least one expansion location.
	*>
	Location loc;
	<* Owned list of expansion locations (empty when none); see the module comment. *>
	List{Location} expansion_locs;
}

<* Zig `tokFromRaw`: convert a tokenizer token (no flags, no expansion locations). *>
fn TokenWithExpansionLocs from_raw(Token raw)
{
	return { .id = raw.id, .loc = { .id = raw.source, .byte_offset = raw.start, .line = raw.line } };
}

<* The token's location as a raw-token-style triple (used by diagnostics on raw tokens). *>
fn Location raw_location(Token raw) => { .id = raw.source, .byte_offset = raw.start, .line = raw.line };

<* Zig `expansionSlice`: the recorded locations (borrowed from the token; empty if none). *>
fn Location[] TokenWithExpansionLocs.expansion_slice(self) => self.expansion_locs.array_view();

<*
 Wrap `locs` (owned elsewhere, e.g. by `Preprocessor.expansion_entries`) in a
 List without an allocator so it can sit in a borrowed token. `free()` on the
 result is a no-op; never push to it.
*>
fn List{Location} borrowed_locs(Location[] locs)
{
	return { .entries = locs.ptr, .size = locs.len, .capacity = locs.len };
}

<*
 Zig `addExpansionLocation`: append the non-generated locations of `new` up
 to the 64-location bound. Does nothing for WHITESPACE / MACRO_WS /
 PLACEMARKER tokens or an empty `new`.
 @param [&inout] gpa : "Allocator that owns (or will own) the list"
*>
fn void TokenWithExpansionLocs.add_expansion_location(&self, Allocator gpa, Location[] new)
{
	if (new.len == 0 || self.id == WHITESPACE || self.id == MACRO_WS || self.id == PLACEMARKER) return;

	sz len = self.expansion_locs.len();
	if (len >= MAX_EXPANSION_LOCS) return;

	sz new_len = 0;
	foreach (l : new)
	{
		if (l.id.index != source::GENERATED_INDEX) new_len++;
	}
	if (new_len > MAX_EXPANSION_LOCS - len) new_len = MAX_EXPANSION_LOCS - len;
	if (new_len == 0) return;

	if (!self.expansion_locs.is_initialized()) self.expansion_locs.init(gpa, 4);
	self.expansion_locs.reserve(new_len);
	foreach (l : new)
	{
		if (l.id.index == source::GENERATED_INDEX) continue;
		if (self.expansion_locs.len() >= MAX_EXPANSION_LOCS) break;
		self.expansion_locs.push(l);
	}
}

<* Zig `dupe`: a copy with its own expansion array. *>
fn TokenWithExpansionLocs TokenWithExpansionLocs.dupe(self, Allocator gpa)
{
	TokenWithExpansionLocs copy = self;
	copy.expansion_locs = {};
	copy.add_expansion_location(gpa, self.expansion_slice());
	return copy;
}

<* True when the token text lives in `Compilation.generated_buf`. *>
fn bool TokenWithExpansionLocs.is_generated(self) => self.loc.id.is_generated();

<*
 Zig `checkMsEof`: warn (DIAG_CTRL_Z_EOF) when the eof token sits on a 0x1A byte.
 @require self.id == EOF
 @return? compilation::FATAL_ERROR
*>
fn void? TokenWithExpansionLocs.check_ms_eof(self, Source src, Compilation* comp)
{
	if (src.buf.len > self.loc.byte_offset && src.buf[self.loc.byte_offset] == 0x1A)
	{
		ExpandedLocation loc = src.line_col({ .id = src.id, .byte_offset = self.loc.byte_offset, .line = self.loc.line });
		comp.diagnostics.add(diagnostics::@message_at(compilation::CompDiag.CTRL_Z_EOF, compilation::CompDiag.CTRL_Z_EOF.fmt, loc))!;
	}
}
