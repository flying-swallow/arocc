// #pragma push_macro("NAME") / #pragma pop_macro("NAME") (GCC, Clang, MSVC):
// save the current definition of a macro (or its absence) on a per-name stack and
// restore it later.
module aro::frontend::c::pragmas::push_macro;
import aro::frontend::c::pragma, aro::frontend::c::preprocessor, aro::frontend::c::tokens, aro::frontend::c::tokenizer;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics;
import std::collections::map, std::collections::list;
import std::core::mem::alloc;

<* One saved state: the definition, or none when the macro was undefined. *>
struct Saved
{
	bool defined;
	preprocessor::Macro definition;
}

alias SavedStack = List{Saved};

<* Registered twice (`push_macro`, `pop_macro`) sharing one state; Registry.free calls
   `deinit` for each registration, so the state counts its owners. *>
struct PushMacro (pragma::IPragma)
{
	Allocator allocator;
	HashMap{String, SavedStack} stacks;
	uint owners;
}

fn PushMacro* handler(Allocator allocator)
{
	PushMacro* state = (PushMacro*)alloc::calloc(allocator, PushMacro::size);
	state.allocator = allocator;
	state.stacks.init(allocator);
	return state;
}

fn void PushMacro.deinit(&self, compilation::Compilation* comp) @dynamic
{
	if (self.owners > 1)
	{
		self.owners--;
		return;
	}
	self.stacks.@each(; String key, SavedStack stack)
	{
		stack.free();
	};
	self.stacks.free();
	alloc::free(self.allocator, self);
}

<* The pragma's string operand must not be macro-expanded (it is a string anyway). *>
fn bool PushMacro.should_expand_token_at_index(&self, tokens::TokenIndex index) @dynamic => false;

fn pragma::PragmaResult PushMacro.preprocessor_handler(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic
{
	if ((sz)start_idx >= pp.tokens.len()) return pragma::PragmaResult.UNKNOWN;
	TreeToken name_tok = pp.tokens[(sz)start_idx];
	TokenWithExpansionLocs diag_tok = { .id = name_tok.id, .loc = name_tok.loc };
	diag_tok.expansion_locs = tokens::borrowed_locs(pp.expansion_slice((TokenIndex)start_idx));
	if (name_tok.id != tokenizer::TokenId.IDENTIFIER) return pragma::PragmaResult.UNKNOWN;
	String pragma_name = pp.expanded_slice(diag_tok);
	bool push;
	switch (pragma_name)
	{
		case "push_macro": push = true;
		case "pop_macro": push = false;
		default: return pragma::PragmaResult.UNKNOWN;
	}

	// `( "NAME" )`
	sz i = (sz)start_idx + 1;
	bool ok = i + 2 < pp.tokens.len() &&
		pp.tokens[i].id == tokenizer::TokenId.L_PAREN &&
		pp.tokens[i + 1].id == tokenizer::TokenId.STRING_LITERAL &&
		pp.tokens[i + 2].id == tokenizer::TokenId.R_PAREN;
	if (!ok)
	{
		if (catch pp.err(diag_tok, Diagnostic.PRAGMA_REQUIRES_STRING_LITERAL, pragma_name)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	String literal = pp.tree_token_slice(pp.tokens[i + 1]);
	if (literal.len < 2 || literal[0] != '"' || literal[^1] != '"')
	{
		if (catch pp.err(diag_tok, Diagnostic.PRAGMA_REQUIRES_STRING_LITERAL, pragma_name)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	String macro_name = literal[1:literal.len - 2];

	if (push)
	{
		Saved saved;
		if (preprocessor::Macro* m = pp.defines.get(macro_name))
		{
			saved = { .defined = true, .definition = *m };
		}
		if (!self.stacks.has_key(macro_name))
		{
			SavedStack fresh;
			fresh.init(self.allocator);
			self.stacks.set(macro_name, fresh); // the map copies String keys
		}
		SavedStack* stack = self.stacks.get_ref(macro_name)!!;
		stack.push(saved);
		return pragma::PragmaResult.HANDLED;
	}

	// pop: with nothing pushed, GCC and Clang leave the macro alone.
	SavedStack*? stack = self.stacks.get_ref(macro_name);
	if (catch stack) return pragma::PragmaResult.HANDLED;
	Saved? top = stack.pop();
	if (catch top) return pragma::PragmaResult.HANDLED;
	if (top.defined)
	{
		bool existed;
		preprocessor::Macro* slot = pp.defines.get_or_put(macro_name, &existed);
		*slot = top.definition;
	}
	else
	{
		pp.defines.ordered_remove(macro_name);
	}
	return pragma::PragmaResult.HANDLED;
}
