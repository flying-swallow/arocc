// Independent port of src/aro/pragmas/pack.zig.
//
// The pragma parser is deliberately supplied by the host. In particular,
// this module does not approximate C integer literal semantics: parse_integer
// must invoke the host parser's normal pp-number parser and return its value.
module aro::pragmas::pack;
import aro::tokenizer;
import aro::pragma, aro::parser, aro::tokens, aro::compilation, aro::number_value, aro::diagnostics;
import std::core::mem::alloc, std::core::string;
import std::collections::list;

enum PackDiag : char
{
	LPAREN,
	RPAREN,
	UNKNOWN_ACTION,
	SHOW,
	INTEGER,
	INTEGER_OR_IDENTIFIER,
	UNDEFINED_POP,
	EMPTY_STACK,
}

<*
 Test-only replacement for TreeParserAdapter's token access and reporting;
 compiled out of non-test builds. Indices address the expanded token stream;
 strings returned by `token_text` are borrowed.
*>
interface IPackParserTestProbe @feat(TESTING)
{
	<* Tokens at indices >= token_count() are past the directive. *>
	fn uint token_count();
	fn tokenizer::TokenId token_id(uint index);
	fn String token_text(uint index);
	<* Use the compiler's ordinary pp-number parser. Return false only after it
	   has emitted its number-token diagnostic. *>
	fn bool parse_integer(uint index, ulong* value);
	fn void diagnose(uint index, PackDiag kind, ulong value);
}

<* A natural alignment is represented by `has_value == false`. *>
struct PackValue
{
	bool has_value;
	char value;
}

struct StackEntry
{
	String label;
	PackValue value;
}

<* Pack pragma state and its pragma::IPragma handler (Zig pragmas/pack.zig).
   Allocated by `make_handler` and freed by `deinit`. *>
struct PackState (pragma::IPragma)
{
	PackValue current;
	List{StackEntry} stack;
	Allocator allocator;
}

struct HandleResult
{
	bool ok;
	uint next_index;
}

fn void PackState.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.stack.init(allocator);
}

fn void PackState.free(&self)
{
	self.stack.free();
	*self = {};
}

<* The current value consumed by parser and layout code; false means natural alignment. *>
fn PackValue PackState.current_value(self) => self.current;

fn void PackState.reset(&self)
{
	self.current = {};
	self.stack.clear();
}

fn void PackState.push(&self, String label)
{
	self.stack.push({ .label = label, .value = self.current });
}

<* Pop the nearest matching named entry, discarding it and entries above it. *>
fn bool PackState.pop_named(&self, String label)
{
	for (sz i = self.stack.len(); i > 0; i--)
	{
		if (self.stack[i - 1].label == label)
		{
			self.current = self.stack[i - 1].value;
			while (self.stack.len() > i - 1) self.stack.pop()!!;
			return true;
		}
	}
	return false;
}

<* Pop the top entry. An empty stack follows Aro's fallback of pack(2). *>
fn bool PackState.pop(&self)
{
	if (self.stack.len() == 0)
	{
		self.current = { .has_value = true, .value = 2 };
		return false;
	}
	self.current = self.stack.pop()!!.value;
	return true;
}

fn bool TreeParserAdapter.is_token(&self, uint index, tokenizer::TokenId id)
	=> index < self.token_count() && self.token_id(index) == id;

fn void TreeParserAdapter.report(&self, uint index, PackDiag kind, ulong value = 0)
{
	self.diagnose(index, kind, value);
}

<* Parse a `pack(...)` body. `lparen_index` points at the opening parenthesis. *>
fn HandleResult PackState.handle(&self, TreeParserAdapter* parser, uint lparen_index)
{
	if (!parser.is_token(lparen_index, tokenizer::TokenId.L_PAREN))
	{
		parser.report(lparen_index, PackDiag.LPAREN);
		return { .ok = false, .next_index = lparen_index };
	}

	uint index = lparen_index + 1;
	if (index >= parser.token_count())
	{
		parser.report(index, PackDiag.RPAREN);
		return { .ok = false, .next_index = index };
	}

	tokenizer::TokenId id = parser.token_id(index);
	if (id == tokenizer::TokenId.IDENTIFIER)
	{
		String action = parser.token_text(index);
		uint action_index = index;
		index++;
		if (action == "show")
		{
			ulong value = self.current.has_value ? self.current.value : 8;
			parser.report(action_index, PackDiag.SHOW, value);
			return { .ok = true, .next_index = index };
		}
		if (action != "push" && action != "pop")
		{
			parser.report(action_index, PackDiag.UNKNOWN_ACTION);
			return { .ok = false, .next_index = action_index };
		}

		String label = "";
		bool has_label = false;
		bool has_new_value = false;
		char new_value = 0;
		if (parser.is_token(index, tokenizer::TokenId.COMMA))
		{
			index++;
			if (index >= parser.token_count())
			{
				parser.report(index, PackDiag.INTEGER_OR_IDENTIFIER);
				return { .ok = false, .next_index = index };
			}
			id = parser.token_id(index);
			if (id == tokenizer::TokenId.PP_NUM)
			{
				if (!parser.read_pack_value(index, &new_value)) return { .ok = false, .next_index = index };
				has_new_value = true;
				index++;
			}
			else if (id == tokenizer::TokenId.IDENTIFIER)
			{
				label = parser.token_text(index);
				has_label = true;
				index++;
				if (parser.is_token(index, tokenizer::TokenId.COMMA))
				{
					index++;
					if (!parser.is_token(index, tokenizer::TokenId.PP_NUM))
					{
						parser.report(index, PackDiag.INTEGER_OR_IDENTIFIER);
						return { .ok = false, .next_index = index };
					}
					if (!parser.read_pack_value(index, &new_value)) return { .ok = false, .next_index = index };
					has_new_value = true;
					index++;
				}
			}
			else
			{
				parser.report(index, PackDiag.INTEGER_OR_IDENTIFIER);
				return { .ok = false, .next_index = index };
			}
		}

		if (action == "push")
		{
			self.push(has_label ? label : "");
		}
		else
		{
			bool popped = has_label ? self.pop_named(label) : self.pop();
			if (has_new_value)
			{
				parser.report(action_index, PackDiag.UNDEFINED_POP);
			}
			else if (!popped)
			{
				parser.report(action_index, PackDiag.EMPTY_STACK);
				return { .ok = false, .next_index = index };
			}
		}
		if (has_new_value) self.current = { .has_value = true, .value = new_value };
		if (action == "pop" && has_new_value) return { .ok = false, .next_index = index };
		return parser.finish(index);
	}

	if (id == tokenizer::TokenId.R_PAREN)
	{
		self.current = {};
		return { .ok = true, .next_index = index + 1 };
	}
	if (id == tokenizer::TokenId.PP_NUM)
	{
		char value = 0;
		if (!parser.read_pack_value(index, &value)) return { .ok = false, .next_index = index };
		self.current = { .has_value = true, .value = value };
		return parser.finish(index + 1);
	}
	return parser.finish(index);
}

fn HandleResult TreeParserAdapter.finish(&self, uint index)
{
	if (!self.is_token(index, tokenizer::TokenId.R_PAREN))
	{
		self.report(index, PackDiag.RPAREN);
		return { .ok = false, .next_index = index };
	}
	return { .ok = true, .next_index = index + 1 };
}

fn bool TreeParserAdapter.read_pack_value(&self, uint index, char* out)
{
	ulong value = 0;
	if (!self.parse_integer(index, &value)) return false;
	if (value != 1 && value != 2 && value != 4 && value != 8 && value != 16)
	{
		self.report(index, PackDiag.INTEGER);
		return false;
	}
	*out = (char)value;
	return true;
}

<* Pack grammar token access over the parser's expanded token tree, ending at the
   directive's newline. Test builds may route token access through `probe`
   (then `p` may be null). *>
struct TreeParserAdapter
{
	parser::Parser* p;
	uint end;
	IPackParserTestProbe probe @feat(TESTING);
}

fn uint TreeParserAdapter.token_count(&self)
{
	$if env::TESTING:
		if (self.probe) return self.probe.token_count();
	$endif
	return self.end;
}

fn tokenizer::TokenId TreeParserAdapter.token_id(&self, uint index)
{
	$if env::TESTING:
		if (self.probe) return self.probe.token_id(index);
	$endif
	return self.p.tree.tokens[(usz)index].id;
}

fn String TreeParserAdapter.token_text(&self, uint index)
{
	$if env::TESTING:
		if (self.probe) return self.probe.token_text(index);
	$endif
	return self.p.tree.tok_slice((tokens::TokenIndex)index);
}

fn bool TreeParserAdapter.parse_integer(&self, uint index, ulong* out)
{
	$if env::TESTING:
		if (self.probe) return self.probe.parse_integer(index, out);
	$endif
	parser::Parser* p = self.p;
	tokens::TreeToken tok = p.tree.tokens[(usz)index];
	number_value::PpNumberValue? value = number_value::pp_parse(p.comp,
		p.tree.tok_slice((tokens::TokenIndex)index), tok.loc, p.pp.expansion_slice((tokens::TokenIndex)index));
	if (catch value) return false;
	*out = value.rejected ? ulong::max : value.is_signed ? (ulong)value.signed : value.unsigned;
	return true;
}

fn void TreeParserAdapter.diagnose(&self, uint index, PackDiag kind, ulong value)
{
	$if env::TESTING:
		if (self.probe) { self.probe.diagnose(index, kind, value); return; };
	$endif
	parser::Parser* p = self.p;
	String message = "invalid #pragma pack directive";
	diagnostics::Option opt = diagnostics::Option.IGNORED_PRAGMAS;
	switch (kind)
	{
		case LPAREN: message = "missing '(' after '#pragma pack' - ignoring";
		case RPAREN: message = "missing ')' after '#pragma pack' - ignoring";
		case UNKNOWN_ACTION: message = "unknown action for '#pragma pack' - ignoring";
		case SHOW: message = string::tformat("value of #pragma pack(show) == %d", value); opt = diagnostics::Option.UNSUPPORTED_PRAGMA;
		case INTEGER: message = "expected #pragma pack parameter to be '1', '2', '4', '8', or '16'";
		case INTEGER_OR_IDENTIFIER: message = "expected integer or identifier in '#pragma pack' - ignored";
		case UNDEFINED_POP: message = "specifying both a name and alignment to 'pop' is undefined"; opt = diagnostics::Option.UNSUPPORTED_PRAGMA;
		case EMPTY_STACK: message = "#pragma pack(pop, ...) failed: stack empty";
	}
	if ((usz)index >= p.tree.tokens.len) return;
	bool has_opt = kind != PackDiag.SHOW && kind != PackDiag.UNDEFINED_POP;
	diagnostics::Message msg = { .kind = WARNING, .text = message, .has_opt = has_opt, .opt = opt,
		.has_location = true, .location = p.tree.tokens[(usz)index].loc.expand(p.comp) };
	if (catch p.diagnostics.add_with_location(p.comp, msg, p.pp.expansion_slice((tokens::TokenIndex)index), true)) return;
}

fn pragma::PragmaResult PackState.parser_handler(&self, parser::Parser* p, tokens::TokenIndex start_idx) @dynamic
{
	uint begin = start_idx + 1;
	uint end = begin;
	while ((usz)end < p.tree.tokens.len && p.tree.tokens[(usz)end].id != tokenizer::TokenId.NL && p.tree.tokens[(usz)end].id != tokenizer::TokenId.EOF) end++;
	TreeParserAdapter adapter = { .p = p, .end = end };
	// A malformed pack pragma emits a warning and is ignored; it does not make
	// the translation unit fail. The parser consumes the rest of the directive.
	self.handle(&adapter, begin);
	return pragma::PragmaResult.HANDLED;
}

<* Each parse starts from natural alignment with an empty stack. *>
fn void PackState.before_parse(&self, compilation::Compilation* comp) @dynamic => self.reset();

fn void PackState.deinit(&self, compilation::Compilation* comp) @dynamic
{
	Allocator allocator = self.allocator;
	self.free();
	alloc::free(allocator, self);
}

<* Allocate the pack handler; Registry.free releases it through `deinit`. *>
fn PackState* make_handler(Allocator allocator)
{
	PackState* state = (PackState*)alloc::calloc(allocator, PackState::size);
	state.init(allocator);
	return state;
}
