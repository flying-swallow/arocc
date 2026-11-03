// Owner: 12.1 def-parser.
// Parses the supported .def grammar (tools/builtins_schema.md, "Input grammar")
// into DefEntry records. Port of the parsing half of build/generate_def.zig,
// extended to parse the Zig-style property expressions explicitly instead of
// pasting them into generated source.
//
// Invariants:
// - Never evaluates or copies arbitrary text: anything outside the grammar is
//   a fault with `diag` filled in.
// - Output strings borrow `input` (see generate_def_schema.c3).
// - Rejects duplicate names, duplicate properties/attribute fields, unknown
//   properties/values, missing param_str, and `.features` in BuiltinBase groups.
// - Faults are reported in file order: the first offending line wins (a
//   missing param_str is detected when the builtin ends, i.e. at the next name
//   line or at EOF, and is reported at the builtin's name line).
module generate_def;
import std::collections::list, std::collections::map, aro::builtin_properties;

<* The five supported properties, in schema order. *>
enum DefProperty : char (String name)
{
	PARAM_STR  { "param_str" },
	ATTRIBUTES { "attributes" },
	HEADER     { "header" },
	LANGUAGE   { "language" },
	FEATURES   { "features" },
}

<* Tag indices are u16 (BuiltinTag.index). *>
const usz MAX_BUILTINS = 65535;

<*
 Parses `input` (the whole .def file) for `group`. On a fault, `diag` (when
 not null) holds the 1-based line and the offending text (the whole trimmed
 line for SYNTAX_ERROR / ORPHAN_PROPERTY, otherwise the offending token).
 The returned DefFile is owned by the caller (`free`); its strings borrow
 `input`. Nothing is allocated on a fault.
*>
fn DefFile? parse_def(Allocator a, String input, BuiltinGroup group, DefDiag* diag)
{
	DefFile file;
	file.init(a, group);
	DefParser p = { .file = &file, .diag = diag };
	p.names.init(a);
	defer p.names.free();
	if (catch f = p.run(input))
	{
		file.free();
		return f~;
	}
	return file;
}

struct DefParser
{
	DefFile* file;
	DefDiag* diag;
	<* Names seen so far -> line (duplicate detection; keys borrow the input). *>
	HashMap{String, uint} names;
	DefEntry cur;
	bool has_cur;
	<* Bit per DefProperty given on `cur`. *>
	uint seen_props;
	uint line;
}

<* Records the diagnostic and returns `f` for the caller to raise (`return self.fail(...)~;`). *>
fn fault DefParser.fail(&self, fault f, uint line, String detail)
{
	if (self.diag) *self.diag = { .line = line, .detail = detail };
	return f;
}

fn bool is_ident_start(char c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
fn bool is_ident_char(char c) => is_ident_start(c) || (c >= '0' && c <= '9');
fn bool is_ws(char c) => c == ' ' || c == '\t';

fn bool is_ident(String s)
{
	if (s.len == 0 || !is_ident_start(s[0])) return false;
	foreach (c : s) if (!is_ident_char(c)) return false;
	return true;
}

fn String trim_ws(String s)
{
	sz start = 0;
	sz end = s.len;
	while (start < end && is_ws(s[start])) start++;
	while (end > start && is_ws(s[end - 1])) end--;
	return s[start:end - start];
}

fn void? DefParser.run(&self, String input)
{
	sz i = 0;
	uint line = 1;
	while (i < input.len)
	{
		sz start = i;
		while (i < input.len && input[i] != '\n' && input[i] != '\r') i++;
		String raw = input[start:i - start];
		self.line = line;
		self.handle_line(trim_ws(raw))!;
		// One line break: "\r\n", "\n" or a lone "\r" (Zig splits on both).
		if (i < input.len)
		{
			if (input[i] == '\r' && i + 1 < input.len && input[i + 1] == '\n') i++;
			i++;
			line++;
		}
	}
	self.finish_entry()!;
}

fn void? DefParser.handle_line(&self, String line)
{
	if (line.len == 0 || line[0] == '#') return;
	if (line.starts_with("const ") || line.starts_with("pub const "))
	{
		// Zig pastes these through as headers; the port refuses arbitrary text.
		return self.fail(SYNTAX_ERROR, self.line, line)~;
	}
	if (line[0] == '.')
	{
		if (!self.has_cur) return self.fail(ORPHAN_PROPERTY, self.line, line)~;
		return self.parse_property(line);
	}
	if (!is_ident(line)) return self.fail(SYNTAX_ERROR, self.line, line)~;

	self.finish_entry()!;
	if (self.names.has_key(line)) return self.fail(DUPLICATE_NAME, self.line, line)~;
	if ((usz)self.file.entries.len() >= MAX_BUILTINS) return self.fail(TOO_MANY_BUILTINS, self.line, line)~;
	self.names.set(line, self.line);
	self.cur = { .name = line, .record = builtin_properties::RECORD_DEFAULT, .line = self.line };
	self.has_cur = true;
	self.seen_props = 0;
}

fn void? DefParser.finish_entry(&self)
{
	if (!self.has_cur) return;
	if (!(self.seen_props & (1u << DefProperty.PARAM_STR.ordinal)))
	{
		return self.fail(MISSING_PARAM_STR, self.cur.line, self.cur.name)~;
	}
	self.file.entries.push(self.cur);
	self.has_cur = false;
}

<* Cursor over one trimmed line. *>
struct LineCursor
{
	String s;
	sz pos;
}

fn bool LineCursor.at_end(&self) => self.pos >= self.s.len;
fn char LineCursor.peek(&self) => self.pos < self.s.len ? self.s[self.pos] : 0;
fn void LineCursor.skip_ws(&self)
{
	while (self.pos < self.s.len && is_ws(self.s[self.pos])) self.pos++;
}
<* Consumes `c` if it is next. *>
fn bool LineCursor.eat(&self, char c)
{
	if (self.peek() != c) return false;
	self.pos++;
	return true;
}
<* Consumes [A-Za-z0-9_]* and returns it (may be empty). *>
fn String LineCursor.word(&self)
{
	sz start = self.pos;
	while (self.pos < self.s.len && is_ident_char(self.s[self.pos])) self.pos++;
	return self.s[start:self.pos - start];
}
<* Consumes an identifier; "" if none starts here. *>
fn String LineCursor.ident(&self)
{
	if (!is_ident_start(self.peek())) return "";
	return self.word();
}

fn void? DefParser.parse_property(&self, String line)
{
	LineCursor c = { .s = line, .pos = 1 };
	String pname = c.ident();
	if (pname.len == 0) return self.fail(SYNTAX_ERROR, self.line, line)~;
	DefProperty prop;
	bool found;
	foreach (p : DefProperty::values)
	{
		if (p.name == pname)
		{
			prop = p;
			found = true;
			break;
		}
	}
	if (!found) return self.fail(UNKNOWN_PROPERTY, self.line, pname)~;
	if (prop == FEATURES && !self.file.group.has_features) return self.fail(FEATURES_NOT_ALLOWED, self.line, pname)~;
	uint bit = 1u << prop.ordinal;
	if (self.seen_props & bit) return self.fail(DUPLICATE_PROPERTY, self.line, pname)~;
	self.seen_props |= bit;

	c.skip_ws();
	if (!c.eat('=')) return self.fail(SYNTAX_ERROR, self.line, line)~;
	c.skip_ws();

	switch (prop)
	{
		case PARAM_STR:
		case FEATURES:
			String v = self.parse_string_value(&c, line)!;
			if (prop == PARAM_STR)
			{
				self.cur.record.param_str = v;
			}
			else
			{
				// "" means "no features" in BuiltinRecord, so an explicit empty
				// expression cannot be represented.
				if (v.len == 0) return self.fail(UNKNOWN_VALUE, self.line, line)~;
				self.cur.record.features = v;
			}
		case HEADER:
		case LANGUAGE:
			String v = self.parse_enum_value(&c, line)!;
			if (prop == HEADER)
			{
				if (catch builtin_properties::header_from_name(v)) return self.fail(UNKNOWN_VALUE, self.line, v)~;
				self.cur.record.header = builtin_properties::header_from_name(v)!!;
			}
			else
			{
				if (catch builtin_properties::language_from_name(v)) return self.fail(UNKNOWN_VALUE, self.line, v)~;
				self.cur.record.language = builtin_properties::language_from_name(v)!!;
			}
		case ATTRIBUTES:
			self.cur.record.attributes = self.parse_attributes(&c, line)!;
	}
	c.skip_ws();
	if (!c.at_end()) return self.fail(SYNTAX_ERROR, self.line, line)~;
}

<*
 Classifies the value at the cursor without consuming it: '"' string,
 '.{' struct, '.' ident enum, [A-Za-z0-9_] word. Anything else is a
 SYNTAX_ERROR. Used to tell "wrong kind" (UNKNOWN_VALUE) from garbage.
*>
enum ValueShape : char { STRING, STRUCT, ENUM, WORD }

fn ValueShape? DefParser.value_shape(&self, LineCursor* c, String line)
{
	char ch = c.peek();
	if (ch == '"') return STRING;
	if (is_ident_char(ch)) return WORD;
	if (ch == '.' && c.pos + 1 < c.s.len)
	{
		char next = c.s[c.pos + 1];
		if (next == '{') return STRUCT;
		if (is_ident_start(next)) return ENUM;
	}
	return self.fail(SYNTAX_ERROR, self.line, line)~;
}

<* string := '"' [^"\\ and control chars]* '"'. Returns the contents. *>
fn String? DefParser.parse_string_value(&self, LineCursor* c, String line)
{
	ValueShape shape = self.value_shape(c, line)!;
	if (shape != STRING) return self.fail(UNKNOWN_VALUE, self.line, line)~;
	c.pos++;
	sz start = c.pos;
	while (true)
	{
		if (c.at_end()) return self.fail(SYNTAX_ERROR, self.line, line)~;
		char ch = c.s[c.pos];
		if (ch == '"') break;
		if (ch == '\\' || ch < 0x20 || ch == 0x7f) return self.fail(SYNTAX_ERROR, self.line, line)~;
		c.pos++;
	}
	String v = c.s[start:c.pos - start];
	c.pos++;
	return v;
}

<* '.' ident. Returns the ident. *>
fn String? DefParser.parse_enum_value(&self, LineCursor* c, String line)
{
	ValueShape shape = self.value_shape(c, line)!;
	if (shape != ENUM) return self.fail(UNKNOWN_VALUE, self.line, line)~;
	c.pos++;
	return c.ident();
}

<*
 '.{' ws? (field (ws? ',' ws? field)* ws? ','?)? ws? '}', applied on top of
 ATTRIBUTES_DEFAULT (Zig struct-literal defaults).
*>
fn Attributes? DefParser.parse_attributes(&self, LineCursor* c, String line)
{
	ValueShape shape = self.value_shape(c, line)!;
	if (shape != STRUCT) return self.fail(UNKNOWN_VALUE, self.line, line)~;
	c.pos += 2;
	Attributes attrs = builtin_properties::ATTRIBUTES_DEFAULT;
	uint seen_fields = 0;
	c.skip_ws();
	if (c.eat('}')) return attrs;
	while (true)
	{
		if (!c.eat('.')) return self.fail(SYNTAX_ERROR, self.line, line)~;
		String fname;
		if (c.eat('@'))
		{
			if (!c.eat('"')) return self.fail(SYNTAX_ERROR, self.line, line)~;
			fname = c.ident();
			if (fname.len == 0 || !c.eat('"')) return self.fail(SYNTAX_ERROR, self.line, line)~;
		}
		else
		{
			fname = c.ident();
			if (fname.len == 0) return self.fail(SYNTAX_ERROR, self.line, line)~;
		}
		if (catch builtin_properties::attribute_field_from_name(fname)) return self.fail(UNKNOWN_VALUE, self.line, fname)~;
		AttributeField field = builtin_properties::attribute_field_from_name(fname)!!;
		uint bit = 1u << field.ordinal;
		if (seen_fields & bit) return self.fail(DUPLICATE_PROPERTY, self.line, fname)~;
		seen_fields |= bit;

		c.skip_ws();
		if (!c.eat('=')) return self.fail(SYNTAX_ERROR, self.line, line)~;
		c.skip_ws();
		uint value = self.parse_field_value(c, line, field)!;
		attrs = attrs.with_field(field, value);

		c.skip_ws();
		if (c.eat(','))
		{
			c.skip_ws();
			if (c.eat('}')) return attrs;
			continue;
		}
		if (c.eat('}')) return attrs;
		return self.fail(SYNTAX_ERROR, self.line, line)~;
	}
}

<* fvalue: 'true'/'false' (BOOL), '.' FormatKind name (FORMAT_KIND), 0..31 (POSITION). *>
fn uint? DefParser.parse_field_value(&self, LineCursor* c, String line, AttributeField field)
{
	ValueShape shape = self.value_shape(c, line)!;
	switch (field.kind)
	{
		case BOOL:
			if (shape != WORD) return self.fail(UNKNOWN_VALUE, self.line, line)~;
			String w = c.word();
			if (w == "true") return 1;
			if (w == "false") return 0;
			return self.fail(UNKNOWN_VALUE, self.line, w)~;
		case FORMAT_KIND:
			if (shape != ENUM) return self.fail(UNKNOWN_VALUE, self.line, line)~;
			c.pos++;
			String name = c.ident();
			if (catch builtin_properties::format_kind_from_name(name)) return self.fail(UNKNOWN_VALUE, self.line, name)~;
			return (uint)builtin_properties::format_kind_from_name(name)!!.ordinal;
		case POSITION:
			if (shape != WORD) return self.fail(UNKNOWN_VALUE, self.line, line)~;
			String w = c.word();
			uint v = 0;
			foreach (ch : w)
			{
				if (ch < '0' || ch > '9') return self.fail(UNKNOWN_VALUE, self.line, w)~;
				if (v <= 31) v = v * 10 + (ch - '0'); // saturates above 31 without overflow
			}
			if (v > 31) return self.fail(UNKNOWN_VALUE, self.line, w)~;
			return v;
	}
}
