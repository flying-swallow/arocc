// Port of the token part of src/aro/Tree.zig: `Tree.Token` (here `TreeToken`),
// its operator precedence table, `TokenIndex` and `TokenWithExpansionLocs`
// with its bounded, sentinel-terminated expansion location chains. It is a
// shared module so the preprocessor does not depend on the AST.
//
// Ownership rules (Zig's, made explicit):
//  - A `TokenWithExpansionLocs` value OWNS its `expansion_locs` array (or holds
//    null). Copying the struct copies the pointer, not the array: exactly one
//    copy may be freed (`free_expansion_locs`) or handed on (to
//    `Preprocessor.add_token`, which moves it into `expansion_entries`).
//    Use `dupe` to get an independent copy.
//  - All arrays come from the allocator passed to `add_expansion_location`
//    (always `Compilation.gpa` in the preprocessor).
//  - Array layout (Zig, kept byte for byte): `cap` Locations; items first,
//    then at least one terminator whose `id.index` is `source::UNUSED_INDEX`
//    (all fields zero otherwise); the LAST element's `byte_offset` is 1, which
//    marks the capacity end. `expansion_slice` scans to the first terminator.
//  - At most `MAX_EXPANSION_LOCS` (64) locations are kept; locations of the
//    generated source are never recorded; WHITESPACE, MACRO_WS and
//    PLACEMARKER tokens never get any.
//  - A token whose `loc.id` is `source::GENERATED_ID` points into
//    `Compilation.generated_buf` (`loc.byte_offset` is an offset into it, so it
//    stays valid when the buffer grows) and has at least one expansion location.
//
// Deviations from Zig:
//  - The array is allocated with exactly the power-of-two size Zig asks for
//    (`ensureTotalCapacity` may round up further); the capacity-end marker
//    makes the difference unobservable.
//  - `Precedence` is a distinct `ichar` with PREC_* constants (Zig's
//    non-exhaustive `enum(i8)`); `precedence(id)` replaces the direct enum array.
module aro::tokens;
import aro::source, aro::tokenizer, aro::compilation, aro::diagnostics;

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
	switch (id)
	{
		case COMMA: return PREC_COMMA;
		case EQUAL:
		case ASTERISK_EQUAL:
		case SLASH_EQUAL:
		case PERCENT_EQUAL:
		case PLUS_EQUAL:
		case MINUS_EQUAL:
		case ANGLE_BRACKET_ANGLE_BRACKET_LEFT_EQUAL:
		case ANGLE_BRACKET_ANGLE_BRACKET_RIGHT_EQUAL:
		case AMPERSAND_EQUAL:
		case CARET_EQUAL:
		case PIPE_EQUAL: return PREC_ASSIGN;
		case QUESTION_MARK: return PREC_CONDITIONAL;
		case PIPE_PIPE: return PREC_BOOL_OR;
		case AMPERSAND_AMPERSAND: return PREC_BOOL_AND;
		case PIPE: return PREC_BIT_OR;
		case CARET: return PREC_BIT_XOR;
		case AMPERSAND: return PREC_BIT_AND;
		case EQUAL_EQUAL:
		case BANG_EQUAL: return PREC_EQUALITY;
		case ANGLE_BRACKET_RIGHT:
		case ANGLE_BRACKET_RIGHT_EQUAL:
		case ANGLE_BRACKET_LEFT:
		case ANGLE_BRACKET_LEFT_EQUAL: return PREC_COMPARISON;
		case ANGLE_BRACKET_ANGLE_BRACKET_RIGHT:
		case ANGLE_BRACKET_ANGLE_BRACKET_LEFT: return PREC_SHIFT;
		case PLUS:
		case MINUS: return PREC_ADDITIVE;
		case ASTERISK:
		case SLASH:
		case PERCENT: return PREC_MULTIPLICATIVE;
		default: return PREC_INVALID;
	}
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
	<* Owned, sentinel-terminated array (layout in the module comment), or null. *>
	Location* expansion_locs;
}

fn bool is_terminator(Location* l) @inline @local => l.id.index == source::UNUSED_INDEX;

<* Zig `tokFromRaw`: convert a tokenizer token (no flags, no expansion locations). *>
fn TokenWithExpansionLocs from_raw(Token raw)
{
	return { .id = raw.id, .loc = { .id = raw.source, .byte_offset = raw.start, .line = raw.line } };
}

<* The token's location as a raw-token-style triple (used by diagnostics on raw tokens). *>
fn Location raw_location(Token raw) => { .id = raw.source, .byte_offset = raw.start, .line = raw.line };

<* Zig `expansionSlice`: the recorded locations (borrowed from the token; empty if none). *>
fn Location[] TokenWithExpansionLocs.expansion_slice(self)
{
	Location* locs = self.expansion_locs;
	if (!locs) return {};
	sz i = 0;
	while (!is_terminator(&locs[i])) i++;
	return locs[:i];
}

<* Same as `expansion_slice` for a bare array pointer (Zig: `pp.expansionSlice` on an entry). *>
fn Location[] expansion_locs_slice(Location* locs)
{
	if (!locs) return {};
	sz i = 0;
	while (!is_terminator(&locs[i])) i++;
	return locs[:i];
}

<* Smallest power of two >= n (n >= 1). *>
fn sz ceil_power_of_two(sz n) @local
{
	sz p = 1;
	while (p < n) p <<= 1;
	return p;
}

<*
 Zig `addExpansionLocation`: append the non-generated locations of `new` up
 to the 64-location bound. Does nothing for WHITESPACE / MACRO_WS /
 PLACEMARKER tokens or an empty `new`. Grows the array to
 ceilPowerOfTwo(max(len + added + 1, 4)) when needed.
 @param [&inout] gpa : "Allocator that owns (or will own) the array"
*>
fn void TokenWithExpansionLocs.add_expansion_location(&self, Allocator gpa, Location[] new)
{
	if (new.len == 0 || self.id == WHITESPACE || self.id == MACRO_WS || self.id == PLACEMARKER) return;

	Location* locs = self.expansion_locs;
	sz len = 0;
	sz cap = 0;
	if (locs)
	{
		while (!is_terminator(&locs[len])) len++;
		sz i = len;
		while (locs[i].byte_offset != 1) i++;
		cap = i + 1;
	}
	if (len >= MAX_EXPANSION_LOCS) return;

	sz new_len = 0;
	foreach (l : new)
	{
		if (l.id.index != source::GENERATED_INDEX) new_len++;
	}
	if (new_len > MAX_EXPANSION_LOCS - len) new_len = MAX_EXPANSION_LOCS - len;
	if (new_len == 0) return;

	sz min_len = len + new_len + 1;
	if (min_len < 4) min_len = 4;
	sz wanted = ceil_power_of_two(min_len);
	if (cap < wanted)
	{
		Location* grown = alloc::new_array(gpa, Location, wanted).ptr;
		if (len) mem::copy(grown, locs, len * Location::size);
		if (locs) alloc::free(gpa, locs);
		locs = grown;
		cap = wanted;
	}

	foreach (l : new)
	{
		if (l.id.index == source::GENERATED_INDEX) continue;
		if (len >= MAX_EXPANSION_LOCS) break;
		locs[len++] = l;
	}
	// Terminators (Zig memsets to `.{}`: unused id, offset 0, line 0) and the capacity marker.
	for (sz i = len; i < cap; i++) locs[i] = { .id = source::UNUSED_ID };
	locs[cap - 1].byte_offset = 1;
	self.expansion_locs = locs;
}

<* Zig `TokenWithExpansionLocs.free`: release an expansion array (null is fine). *>
fn void free_expansion_locs(Allocator gpa, Location* locs)
{
	if (locs) alloc::free(gpa, locs);
}

<* Zig `dupe`: a copy with its own expansion array. *>
fn TokenWithExpansionLocs TokenWithExpansionLocs.dupe(self, Allocator gpa)
{
	TokenWithExpansionLocs copy = self;
	copy.expansion_locs = null;
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
		DiagnosticTemplate d = compilation::DIAG_CTRL_Z_EOF;
		ExpandedLocation loc = src.line_col({ .id = src.id, .byte_offset = self.loc.byte_offset, .line = self.loc.line });
		comp.diagnostics.add(d.message_at(d.fmt, loc))!;
	}
}
