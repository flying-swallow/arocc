// Standalone port of src/aro/pragmas/gcc.zig.
//
// GccPragma implements pragma::IPragma. The parser handler receives the live
// parser so pragma replay uses its preprocessor tokens.
// The handler consumes already-expanded tokens through the terminating NL.
module aro::frontend::c::pragmas::gcc;
import aro::frontend::c::preprocessor, aro::frontend::c::tokens, aro::frontend::c::tokenizer, aro::frontend::c::diagnostics;
import aro::frontend::c::pragma, aro::frontend::c::compilation, aro::frontend::c::parser;
import std::collections::list, std::core::mem::allocators, std::core::mem::alloc;

enum Directive : char { WARNING, ERROR, DIAGNOSTIC, POISON }
enum DiagnosticAction : char { IGNORED, WARNING, ERROR, FATAL, PUSH, POP }

<* Zig pragmas/gcc.zig. Allocated by `make_handler` and freed by `deinit`. *>
struct GccPragma (pragma::IPragma)
{
	diagnostics::State original_state;
	List{diagnostics::State} state_stack;
	Allocator allocator;
}

fn void GccPragma.init(&self, Allocator allocator)
{
	*self = { .allocator = allocator };
	self.state_stack.init(allocator);
}

fn void GccPragma.free(&self)
{
	self.state_stack.free();
	*self = {};
}

// GCC pragmas are handled during preprocessing. They must not be expanded at
// parser time; this mirrors shouldExpandTokenAtIndex in the Zig module.
fn bool GccPragma.should_expand_token_at_index(&self, TokenIndex unused_index) @dynamic => false;

fn String text(preprocessor::Preprocessor* pp, TokenWithExpansionLocs tok) => pp.expanded_slice(tok);

fn bool is_nl(TokenWithExpansionLocs tok) => tok.id == NL || tok.id == EOF;

<* Zig Pragma.pasteTokens: join adjacent narrow string tokens, optionally parenthesized. *>
fn bool paste_strings(preprocessor::Preprocessor* pp, TokenWithExpansionLocs[] line, uint start, List{char}* out)
{
	uint left_parens = 0;
	uint right_parens = 0;
	uint count = 0;
	uint offset = 0;
	for (uint i = start; i < line.len && !is_nl(line[i]); i++)
	{
		TokenWithExpansionLocs tok = line[i];
		if (tok.id == L_PAREN)
		{
			if (left_parens != offset) return false;
			left_parens++;
		}
		else if (tok.id == R_PAREN)
		{
			right_parens++;
		}
		else if (tok.id == STRING_LITERAL)
		{
			if (right_parens != 0) return false;
			String value = text(pp, tok);
			if (value.len < 2 || value[0] != '"' || value[value.len - 1] != '"') return false;
			out.push_all(value[1 : value.len - 2]);
			count++;
		}
		else { return false; }
		offset++;
	}
	return count > 0 && left_parens == right_parens;
}

fn void? emit(preprocessor::Preprocessor* pp, TokenWithExpansionLocs tok, diagnostics::MessageKind kind, String message, bool pragma_warning = false)
{
	diagnostics::Message m = { .kind = kind, .text = message, .has_opt = pragma_warning, .opt = diagnostics::Option.PRAGMA_MESSAGES,
		.has_location = true, .location = tok.loc.expand(pp.comp) };
	return pp.diagnostics.add_with_location(pp.comp, m, tok.expansion_slice(), true);
}

fn void? emit_option(preprocessor::Preprocessor* pp, TokenWithExpansionLocs tok, diagnostics::MessageKind kind, String message, diagnostics::Option option, bool extension = false)
{
	diagnostics::Message m = { .kind = kind, .text = message, .has_opt = true, .opt = option, .extension = extension,
		.has_location = true, .location = tok.loc.expand(pp.comp) };
	return pp.diagnostics.add_with_location(pp.comp, m, tok.expansion_slice(), true);
}

fn void? GccPragma.set_diagnostic(&self, preprocessor::Preprocessor* pp, TokenWithExpansionLocs[] line, uint action_index)
{
	if (action_index >= line.len || is_nl(line[action_index])) return;
	String action_name = text(pp, line[action_index]);
	DiagnosticAction action;
	if (action_name == "ignored") { action = IGNORED; }
	else if (action_name == "warning") { action = WARNING; }
	else if (action_name == "error") { action = ERROR; }
	else if (action_name == "fatal") { action = FATAL; }
	else if (action_name == "push") { action = PUSH; }
	else if (action_name == "pop") { action = POP; }
	else { return; }

	switch (action)
	{
		case PUSH: self.state_stack.push(pp.diagnostics.state); return;
		case POP:
			if (self.state_stack.len() > 0) { pp.diagnostics.state = self.state_stack.pop()!!; }
			else { pp.diagnostics.state = self.original_state; }
			return;
		default:
			break;
	}

	uint i = action_index + 1;
	List{char} pasted;
	pasted.init(pp.comp.gpa);
	defer pasted.free();
	if (!paste_strings(pp, line, i, &pasted))
	{
		emit(pp, line[action_index], diagnostics::MessageKind.ERROR, "pragma GCC diagnostic requires string literal")!;
		return;
	}
	String warning_flag = (String)pasted.array_view();
	if (warning_flag.len < 2 || warning_flag[0:2] != "-W")
	{
		emit_option(pp, line[i], diagnostics::MessageKind.WARNING, "GCC diagnostic expected option name (e.g. \"-Wundef\")", diagnostics::Option.MALFORMED_WARNING_CHECK, true)!;
		return;
	}
	diagnostics::MessageKind kind = WARNING;
	switch (action)
	{
		case IGNORED: kind = diagnostics::MessageKind.OFF;
		case WARNING: kind = diagnostics::MessageKind.WARNING;
		case ERROR: kind = diagnostics::MessageKind.ERROR;
		case FATAL: kind = diagnostics::MessageKind.FATAL_ERROR;
		default: unreachable("invalid diagnostic action");
	}
	pp.diagnostics.set(warning_flag[2..], kind)!;
}

fn void? GccPragma.handle_preprocessor(&self, preprocessor::Preprocessor* pp, TokenWithExpansionLocs[] line, uint pragma_index)
{
	uint gcc_index = pragma_index + 1;
	if (gcc_index >= line.len || is_nl(line[gcc_index]) || text(pp, line[gcc_index]) != "GCC") return;
	uint command_index = gcc_index + 1;
	if (command_index >= line.len || is_nl(line[command_index])) return;
	String command = text(pp, line[command_index]);
	if (command == "diagnostic") return self.set_diagnostic(pp, line, command_index + 1);
	if (command == "warning" || command == "error")
	{
		// The standard spelling takes a string literal; concatenate adjacent
		// literal tokens, preserving the common single-literal behavior.
		uint i = command_index + 1;
		List{char} pasted;
		pasted.init(pp.comp.gpa);
		defer pasted.free();
		if (!paste_strings(pp, line, i, &pasted))
		{
			if (command == "warning") { emit(pp, line[command_index], diagnostics::MessageKind.ERROR, "pragma warning requires string literal")!; }
			else { emit(pp, line[command_index], diagnostics::MessageKind.ERROR, "pragma error requires string literal")!; }
			return;
		}
		String msg = (String)pasted.array_view();
		emit(pp, line[command_index], command == "warning" ? diagnostics::MessageKind.WARNING : diagnostics::MessageKind.ERROR, msg, command == "warning")!;
		return;
	}
	if (command == "poison")
	{
		for (uint i = command_index + 1; i < line.len && !is_nl(line[i]); i++)
		{
			TokenWithExpansionLocs tok = line[i];
			if (!tok.id.is_macro_identifier())
			{
				return emit(pp, tok, diagnostics::MessageKind.ERROR, "can only poison identifier tokens");
			}
			String name = text(pp, tok);
			if (pp.defines.get(name) != null)
			{
				emit(pp, tok, diagnostics::MessageKind.WARNING, "poisoning existing macro")!;
			}
			pp.poisoned_identifiers.get_or_put(name);
		}
	}
}

// Replay only diagnostic state changes after before_parse restored the initial
// state. warning/error messages and poison are emitted/applied in preprocessing.
fn void? GccPragma.handle_parser(&self, preprocessor::Preprocessor* pp, TokenWithExpansionLocs[] line, uint pragma_index)
{
	uint gcc_index = pragma_index + 1;
	if (gcc_index >= line.len || is_nl(line[gcc_index]) || text(pp, line[gcc_index]) != "GCC") return;
	uint command_index = gcc_index + 1;
	if (command_index >= line.len || is_nl(line[command_index]) || text(pp, line[command_index]) != "diagnostic") return;
	return self.set_diagnostic(pp, line, command_index + 1);
}

fn TokenWithExpansionLocs token_at(preprocessor::Preprocessor* pp, uint index)
{
	tokens::TreeToken tok = pp.tokens[index];
	return { .id = tok.id, .loc = tok.loc, .expansion_locs = tokens::borrowed_locs(pp.expansion_slice(index)) };
}

<* Build a borrowed view of the pragma and following tokens through NL/EOF. *>
fn TokenWithExpansionLocs[] pragma_line(preprocessor::Preprocessor* pp, uint start_idx, List{TokenWithExpansionLocs}* storage)
{
	for (uint i = start_idx; i < pp.tokens.len(); i++)
	{
		TokenWithExpansionLocs tok = token_at(pp, i);
		storage.push(tok);
		if (is_nl(tok)) break;
	}
	return storage.array_view();
}

fn pragma::PragmaResult GccPragma.preprocessor_handler(&self, preprocessor::Preprocessor* pp, TokenIndex start_idx) @dynamic
{
	List{TokenWithExpansionLocs} line;
	line.init(pp.comp.gpa);
	defer line.free();
	if (start_idx == 0) return pragma::PragmaResult.UNKNOWN;
	TokenWithExpansionLocs[] view = pragma_line(pp, start_idx - 1, &line);
	if (view.len < 2 || text(pp, view[1]) != "GCC") return pragma::PragmaResult.UNKNOWN;
	if (view.len <= 2 || is_nl(view[2]))
	{
		if (catch emit_option(pp, view[1], diagnostics::MessageKind.OFF, "pragma GCC expected 'error', 'warning', 'diagnostic', 'poison'", diagnostics::Option.UNKNOWN_PRAGMAS)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	String command = text(pp, view[2]);
	if (command != "warning" && command != "error" && command != "diagnostic" && command != "poison")
	{
		if (catch emit_option(pp, view[2], diagnostics::MessageKind.OFF, "pragma GCC expected 'error', 'warning', 'diagnostic', 'poison'", diagnostics::Option.UNKNOWN_PRAGMAS)) return pragma::PragmaResult.FATAL;
		return pragma::PragmaResult.HANDLED;
	}
	if (command == "diagnostic" && view.len > 3 && !is_nl(view[3]))
	{
		String action = text(pp, view[3]);
		if (action != "ignored" && action != "warning" && action != "error" && action != "fatal" && action != "push" && action != "pop")
		{
			if (catch emit_option(pp, view[3], diagnostics::MessageKind.WARNING, "pragma GCC diagnostic expected 'error', 'warning', 'ignored', 'fatal', 'push', or 'pop'", diagnostics::Option.UNKNOWN_PRAGMAS, true)) return pragma::PragmaResult.FATAL;
			return pragma::PragmaResult.HANDLED;
		}
	}
	if (catch self.handle_preprocessor(pp, view, 0)) return pragma::PragmaResult.FATAL;
	return pragma::PragmaResult.HANDLED;
}

fn pragma::PragmaResult GccPragma.parser_handler(&self, parser::Parser* p, TokenIndex start_idx) @dynamic
{
	preprocessor::Preprocessor* pp = p.pp;
	List{TokenWithExpansionLocs} line;
	line.init(pp.comp.gpa);
	defer line.free();
	if (start_idx == 0) return pragma::PragmaResult.UNKNOWN;
	TokenWithExpansionLocs[] view = pragma_line(pp, start_idx - 1, &line);
	if (view.len < 2 || text(pp, view[1]) != "GCC") return pragma::PragmaResult.UNKNOWN;
	if (catch self.handle_parser(pp, view, 0)) return pragma::PragmaResult.FATAL;
	return pragma::PragmaResult.HANDLED;
}

fn void GccPragma.before_preprocess(&self, compilation::Compilation* comp) @dynamic
{
	self.original_state = comp.diagnostics.state;
}

fn void GccPragma.before_parse(&self, compilation::Compilation* comp) @dynamic
{
	comp.diagnostics.state = self.original_state;
	self.state_stack.clear();
}

fn void GccPragma.after_parse(&self, compilation::Compilation* comp) @dynamic
{
	comp.diagnostics.state = self.original_state;
	self.state_stack.clear();
}

fn bool GccPragma.preserve_tokens(&self, preprocessor::Preprocessor* pp, TokenIndex start_idx) @dynamic
{
	if ((sz)(start_idx + 1) >= pp.tokens.len()) return true;
	TokenWithExpansionLocs next = token_at(pp, start_idx + 1);
	return next.id == NL || text(pp, next) != "poison";
}

fn void GccPragma.deinit(&self, compilation::Compilation* comp) @dynamic
{
	Allocator allocator = self.allocator;
	self.free();
	alloc::free(allocator, self);
}

<* Allocate the GCC pragma handler; Registry.free releases it through `deinit`. *>
fn GccPragma* make_handler(Allocator allocator)
{
	GccPragma* state = (GccPragma*)alloc::calloc(allocator, GccPragma::size);
	state.init(allocator);
	return state;
}
