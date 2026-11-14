// #pragma message handler for the shared compilation pragma registry.
module aro::pragmas::message;
import aro::pragma, aro::preprocessor, aro::tokens, aro::tokenizer, aro::diagnostics, aro::source;

<* Zig Pragma/message.zig diagnostics, emitted through the duck-typed `Preprocessor.err`. *>
enum MessageDiag : ushort (String fmt, diagnostics::MessageKind kind, diagnostics::DiagMeta meta)
{
	PRAGMA_MESSAGE { "#pragma message: %s", NOTE, {} },
	PRAGMA_REQUIRES_STRING_LITERAL { "pragma %s requires string literal", ERROR, {} },
}

<* Zig pragmas/message.zig. Stateless, so one shared instance serves every registry. *>
struct MessagePragma (pragma::IPragma)
{
	bool unused;
}

MessagePragma shared_handler @local;

fn MessagePragma* handler() => &shared_handler;

fn pragma::PragmaResult MessagePragma.preprocessor_handler(&self, preprocessor::Preprocessor* pp, tokens::TokenIndex start_idx) @dynamic
{
	if ((sz)start_idx >= pp.tokens.len()) return pragma::PragmaResult.UNKNOWN;
	TreeToken name_tok = pp.tokens[(sz)start_idx];
	TokenWithExpansionLocs diag_tok = { .id = name_tok.id, .loc = name_tok.loc };
	diag_tok.expansion_locs = tokens::borrowed_locs(pp.expansion_slice((TokenIndex)start_idx));
	if (name_tok.id != tokenizer::TokenId.IDENTIFIER || pp.expanded_slice(diag_tok) != "message") return pragma::PragmaResult.UNKNOWN;

	// Match Zig's pasteTokens: permit a run of opening parentheses, adjacent
	// ordinary string literals, then the matching closing parentheses.
	DString pasted;
	pasted.init(pp.comp.gpa);
	defer pasted.free();
	sz i = (sz)start_idx + 1;
	uint opens = 0;
	uint closes = 0;
	bool invalid = i >= pp.tokens.len() || pp.tokens[i].id == tokenizer::TokenId.NL;
	while (!invalid && i < pp.tokens.len() && pp.tokens[i].id != tokenizer::TokenId.NL)
	{
		TreeToken tok = pp.tokens[i];
		if (tok.id == tokenizer::TokenId.L_PAREN)
		{
			if ((sz)opens != i - ((sz)start_idx + 1)) { invalid = true; }
			else { opens++; }
		}
		else if (tok.id == tokenizer::TokenId.R_PAREN)
		{
			closes++;
		}
		else if (tok.id == tokenizer::TokenId.STRING_LITERAL)
		{
			if (closes != 0) { invalid = true; }
			else
			{
				TokenWithExpansionLocs literal_tok = { .id = tok.id, .loc = tok.loc, .expansion_locs = tokens::borrowed_locs(pp.expansion_slice((TokenIndex)i)) };
				String literal = pp.expanded_slice(literal_tok);
				if (literal.len < 2) { invalid = true; }
				else { pasted.append_string(literal[1 : literal.len - 2]); }
			}
		}
		else { invalid = true; }
		i++;
	}
	if (opens != closes) { invalid = true; }
	if (invalid)
	{
		if (catch pp.err(diag_tok, MessageDiag.PRAGMA_REQUIRES_STRING_LITERAL, "message")) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}

	source::Location loc = name_tok.loc;
	source::Location[] expansion_locs = pp.expansion_slice(start_idx);
	if (expansion_locs.len != 0) loc = expansion_locs[expansion_locs.len - 1];
	String text = string::tformat(MessageDiag.PRAGMA_MESSAGE.fmt, pasted.str_view());
	if (catch pp.diagnostics.add(diagnostics::@message_at(MessageDiag.PRAGMA_MESSAGE, text, loc.expand(pp.comp)))) return pragma::PragmaResult.FATAL;
	return pragma::PragmaResult.HANDLED;
}
