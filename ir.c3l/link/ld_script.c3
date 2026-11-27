// Parser for the input-list subset of GNU ld scripts used by system libraries.
module aro::backend::link;
import aro::compiler::reporting;
import std::collections::list;

enum ScriptInputKind : char
{
	PATH,
	LIB,
}

<*
 A linker script input. Relative PATH names are resolved by the M2 resolver in
 the script's own directory first, then along the `-L` search path. This is
 GNU ld's rule for bare names inside GROUP.
*>
struct ScriptInput
{
	ScriptInputKind kind;
	String name;
	bool as_needed;
	bool in_group;
}

fn bool ScriptInput.is_absolute(self)
{
	return self.kind == ScriptInputKind.PATH && self.name.len > 0 && self.name[0] == '/';
}

struct LdScript
{
	String path;
	ScriptInput[] inputs;
	String output_format;
	bool has_output_format;
}

enum ScriptTokenKind : char
{
	END,
	WORD,
	LPAREN,
	RPAREN,
	COMMA,
}

struct ScriptToken
{
	ScriptTokenKind kind;
	String word;
	uint line;
}

<* @return? link::MALFORMED_SCRIPT *>
fn void? malformed_script(reporting::Sink d, String path, uint line, String reason)
{
	@link_err(d, LinkDiagnostic.MALFORMED_SCRIPT, path, (int)line, reason)!;
	return MALFORMED_SCRIPT~;
}

<* @return? link::UNSUPPORTED_SCRIPT *>
fn void? unsupported_script(reporting::Sink d, String path, String command)
{
	@link_err(d, LinkDiagnostic.UNSUPPORTED_SCRIPT, path, command)!;
	return UNSUPPORTED_SCRIPT~;
}

fn bool script_whitespace(char c)
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

<* Tokenize while borrowing word contents from the original script text. @return? link::MALFORMED_SCRIPT *>
fn ScriptToken[]? lex_ld_script(Allocator arena, reporting::Sink d, String path, String text)
{
	List{ScriptToken} tokens;
	tokens.init(arena);
	sz at = 0;
	uint line = 1;
	while (at < text.len)
	{
		char c = text[at];
		if (script_whitespace(c))
		{
			if (c == '\n') line++;
			at++;
			continue;
		}
		if (c == '/' && at + 1 < text.len && text[at + 1] == '*')
		{
			uint comment_line = line;
			at += 2;
			bool closed = false;
			while (at < text.len)
			{
				if (text[at] == '\n') line++;
				if (text[at] == '*' && at + 1 < text.len && text[at + 1] == '/')
				{
					at += 2;
					closed = true;
					break;
				}
				at++;
			}
			if (!closed) malformed_script(d, path, comment_line, "unterminated comment")!;
			continue;
		}
		if (c == '(' || c == ')' || c == ',')
		{
			ScriptTokenKind kind = c == '(' ? ScriptTokenKind.LPAREN :
				(c == ')' ? ScriptTokenKind.RPAREN : ScriptTokenKind.COMMA);
			tokens.push({ .kind = kind, .line = line });
			at++;
			continue;
		}
		if (c == '"')
		{
			uint word_line = line;
			at++;
			sz start = at;
			bool closed = false;
			while (at < text.len)
			{
				if (text[at] == '"')
				{
					closed = true;
					break;
				}
				if (text[at] == '\n') line++;
				at++;
			}
			if (!closed) malformed_script(d, path, word_line, "unterminated quoted word")!;
			String word = (String)text[start:at - start];
			tokens.push({ .kind = ScriptTokenKind.WORD, .word = word, .line = word_line });
			at++;
			continue;
		}

		uint word_line = line;
		sz start = at;
		while (at < text.len)
		{
			char word_char = text[at];
			if (script_whitespace(word_char) || word_char == '(' || word_char == ')' ||
				word_char == ',' || word_char == '"') break;
			// A comment delimiter separates adjacent tokens even without whitespace.
			if (word_char == '/' && at + 1 < text.len && text[at + 1] == '*') break;
			at++;
		}
		// The only possible zero-length word at this point is a comment, handled above.
		if (at == start) continue;
		String word = (String)text[start:at - start];
		tokens.push({ .kind = ScriptTokenKind.WORD, .word = word, .line = word_line });
	}
	tokens.push({ .kind = ScriptTokenKind.END, .line = line });
	return tokens.entries[0:tokens.len()];
}

struct ScriptParser
{
	reporting::Sink diagnostics;
	String path;
	ScriptToken[] tokens;
	sz at;
	List{ScriptInput} inputs;
	String output_format;
	bool has_output_format;
}

fn ScriptToken ScriptParser.peek(&self)
{
	return self.tokens[self.at];
}

fn ScriptToken ScriptParser.take(&self)
{
	ScriptToken token = self.peek();
	if (token.kind != ScriptTokenKind.END) self.at++;
	return token;
}

fn bool ScriptParser.accept(&self, ScriptTokenKind kind)
{
	if (self.peek().kind != kind) return false;
	self.take();
	return true;
}

fn void? ScriptParser.malformed(&self, uint line, String reason)
{
	malformed_script(self.diagnostics, self.path, line, reason)!;
	return;
}

fn void? ScriptParser.unsupported(&self, String command)
{
	unsupported_script(self.diagnostics, self.path, command)!;
	return;
}

fn void? ScriptParser.append_input(&self, ScriptToken token, bool as_needed, bool in_group)
{
	String name = token.word;
	ScriptInputKind kind = ScriptInputKind.PATH;
	if (name.len >= 2 && name[0] == '-' && name[1] == 'l')
	{
		if (name.len == 2) self.malformed(token.line, "-l must be followed by a library name")!;
		kind = ScriptInputKind.LIB;
		name = (String)name[2:name.len - 2];
	}
	self.inputs.push({ .kind = kind, .name = name, .as_needed = as_needed, .in_group = in_group });
	return;
}

<* Parse a GROUP/INPUT list, with AS_NEEDED accepted only one level below it. @return? link::MALFORMED_SCRIPT, link::UNSUPPORTED_SCRIPT *>
fn void? ScriptParser.parse_input_items(&self, bool in_group, bool as_needed, bool allow_as_needed)
{
	ScriptToken first = self.peek();
	if (first.kind == ScriptTokenKind.RPAREN)
	{
		self.take();
		if (in_group) self.malformed(first.line, "GROUP must contain at least one input")!;
		return;
	}
	while (true)
	{
		ScriptToken token = self.peek();
		if (token.kind == ScriptTokenKind.END)
		{
			self.malformed(token.line, "expected ')' before end of script")!;
		}
		if (token.kind == ScriptTokenKind.RPAREN)
		{
			self.take();
			return;
		}
		if (token.kind == ScriptTokenKind.COMMA)
		{
			self.take();
			continue;
		}
		if (token.kind != ScriptTokenKind.WORD)
		{
			self.malformed(token.line, "expected an input word or ')'")!;
		}
		self.take();
		if (token.word == "AS_NEEDED" && self.peek().kind == ScriptTokenKind.LPAREN)
		{
			if (!allow_as_needed) self.unsupported("AS_NEEDED")!;
			self.take();
			self.parse_input_items(in_group, true, false)!;
			continue;
		}
		self.append_input(token, as_needed, in_group)!;
	}
}

<* Parse the one-name or three-name OUTPUT_FORMAT form. @return? link::MALFORMED_SCRIPT *>
fn void? ScriptParser.parse_output_format(&self)
{
	if (!self.accept(ScriptTokenKind.LPAREN))
	{
		self.malformed(self.peek().line, "expected '(' after OUTPUT_FORMAT")!;
	}
	ScriptToken first = self.take();
	if (first.kind != ScriptTokenKind.WORD) self.malformed(first.line, "OUTPUT_FORMAT expects a format name")!;
	self.output_format = first.word;
	self.has_output_format = true;
	if (self.accept(ScriptTokenKind.COMMA))
	{
		ScriptToken second = self.take();
		if (second.kind != ScriptTokenKind.WORD) self.malformed(second.line, "OUTPUT_FORMAT expects three format names")!;
		if (!self.accept(ScriptTokenKind.COMMA)) self.malformed(self.peek().line, "OUTPUT_FORMAT expects three format names")!;
		ScriptToken third = self.take();
		if (third.kind != ScriptTokenKind.WORD) self.malformed(third.line, "OUTPUT_FORMAT expects three format names")!;
	}
	if (!self.accept(ScriptTokenKind.RPAREN))
	{
		self.malformed(self.peek().line, "expected ')' after OUTPUT_FORMAT")!;
	}
}

<* @return? link::MALFORMED_SCRIPT, link::UNSUPPORTED_SCRIPT *>
fn LdScript? parse_ld_script(Allocator arena, reporting::Sink d, String path, String text)
{
	ScriptToken[]? token_result = lex_ld_script(arena, d, path, text);
	if (catch token_result) return MALFORMED_SCRIPT~;
	ScriptToken[] tokens = token_result;
	ScriptParser parser = {
		.diagnostics = d,
		.path = path,
		.tokens = tokens,
		.inputs = {},
	};
	parser.inputs.init(arena);
	while (parser.peek().kind != ScriptTokenKind.END)
	{
		ScriptToken command = parser.take();
		if (command.kind != ScriptTokenKind.WORD)
		{
			parser.malformed(command.line, "expected a linker script command")!;
		}
		if (command.word == "GROUP" || command.word == "INPUT")
		{
			bool in_group = command.word == "GROUP";
			if (!parser.accept(ScriptTokenKind.LPAREN))
			{
				parser.malformed(parser.peek().line, "expected '(' after input command")!;
			}
			parser.parse_input_items(in_group, false, true)!;
		}
		else if (command.word == "OUTPUT_FORMAT")
		{
			parser.parse_output_format()!;
		}
		else
		{
			parser.unsupported(command.word)!;
		}
	}
	return {
		.path = path,
		.inputs = parser.inputs.entries[0:parser.inputs.len()],
		.output_format = parser.output_format,
		.has_output_format = parser.has_output_format,
	};
}

<* True for non-ELF, non-ar text with no NUL byte in the first 512 bytes. *>
fn bool looks_like_script(char[] bytes)
{
	if (bytes.len >= 4 && bytes[0] == (char)0x7f && bytes[1] == 'E' && bytes[2] == 'L' && bytes[3] == 'F') return false;
	if (bytes.len >= 8 && bytes[0] == '!' && bytes[1] == '<' && bytes[2] == 'a' && bytes[3] == 'r' &&
		bytes[4] == 'c' && bytes[5] == 'h' && bytes[6] == '>' && bytes[7] == '\n') return false;
	if (bytes.len >= 8 && bytes[0] == '!' && bytes[1] == '<' && bytes[2] == 't' && bytes[3] == 'h' &&
		bytes[4] == 'i' && bytes[5] == 'n' && bytes[6] == '>' && bytes[7] == '\n') return false;
	sz limit = bytes.len < 512 ? bytes.len : 512;
	for (sz i = 0; i < limit; i++) if (bytes[i] == 0) return false;
	return true;
}
