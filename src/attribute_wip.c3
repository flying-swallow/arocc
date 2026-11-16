// Port of the temporary attribute parser state from Attribute/Wip.zig.
// Parsed attributes and their expression results are scoped by State so a
// parser can restore them after a failed or completed declarator.
module aro::attribute_wip;
import aro::primitive_value;
import aro::attribute, aro::attribute_map, aro::compilation, aro::diagnostics, aro::lang_opts;
import aro::parser, aro::parser_result, aro::target, aro::tokens, aro::tokenizer, aro::tree, aro::type_store, aro::value, aro::value_interner;
import std::collections::list;
import std::core::dstring, std::io;

struct Parsed
{
	attribute::Namespaced name;
	attribute::AttributeSyntax syntax;
	uint args_index;
	uint args_len;
	tokens::TokenIndex tok;
	bool used_as_type_attr;
}

struct State
{
	uint attrs;
	uint args;
	uint pending_calling_conventions;
	uint pending_calling_conventions_cursor;
	uint top;
}

<* Temporary parser state for uncommitted attributes and parsed arguments. *>
struct Wip
{
	Allocator gpa;
	List{Parsed} attrs;
	List{parser_result::Result} args;
	List{uint} pending_calling_conventions;
	uint pending_calling_conventions_cursor;
	List{attribute_map::AttrRef} applied;
	uint top;
}

fn void Wip.init(&self, Allocator gpa)
{
	*self = { .gpa = gpa };
	self.attrs.init(gpa);
	self.args.init(gpa);
	self.pending_calling_conventions.init(gpa);
	self.applied.init(gpa);
}

fn void Wip.free(&self)
{
	self.attrs.free();
	self.args.free();
	self.pending_calling_conventions.free();
	self.applied.free();
	*self = {};
}

<* Snapshot lengths and the pending queue cursor; move_top starts the next application at the current end. *>
fn State Wip.state(&self, bool move_top)
{
	State old = { .attrs = (uint)self.attrs.len(), .args = (uint)self.args.len(), .pending_calling_conventions = (uint)self.pending_calling_conventions.len(), .pending_calling_conventions_cursor = self.pending_calling_conventions_cursor, .top = self.top };
	if (move_top) self.top = old.attrs;
	return old;
}

<* Discard all temporary attributes and arguments added after `old`. *>
fn void Wip.restore(&self, State old)
{
	assert(old.attrs <= (uint)self.attrs.len() && old.args <= (uint)self.args.len() && old.pending_calling_conventions <= (uint)self.pending_calling_conventions.len() && old.pending_calling_conventions_cursor <= old.pending_calling_conventions);
	while ((uint)self.attrs.len() > old.attrs) self.attrs.pop()!!;
	while ((uint)self.args.len() > old.args) self.args.pop()!!;
	while ((uint)self.pending_calling_conventions.len() > old.pending_calling_conventions) self.pending_calling_conventions.pop()!!;
	self.pending_calling_conventions_cursor = old.pending_calling_conventions_cursor;
	self.top = old.top;
}

<* Entries before the cursor are consumed log history; the suffix is pending. *>
fn uint[] Wip.pending_calling_conventions_active(&self)
{
	uint[] log = self.pending_calling_conventions.array_view();
	return log[(sz)self.pending_calling_conventions_cursor..];
}

<* Append a parsed attribute. Argument nodes remain in parser-owned tree storage. *>
fn void Wip.add(&self, attribute::Namespaced name, attribute::AttributeSyntax syntax, tokens::TokenIndex tok, parser_result::Result[] args)
{
	uint arg_start = (uint)self.args.len();
	self.args.push_all(args);
	self.attrs.push({
		.name = name,
		.syntax = syntax,
		.args_index = arg_start,
		.args_len = (uint)args.len,
		.tok = tok,
		.used_as_type_attr = false,
	});
}

<* Add a keyword attribute using the shared token-to-name table in attribute.c3. *>
fn void Wip.add_keyword(&self, parser::Parser* p, tokens::TokenIndex tok, parser_result::Result[] args)
{
	assert((usz)tok < p.tree.tokens.len);
	self.add(attribute::namespaced_from_keyword(p.tree.tokens[(usz)tok].id), attribute::AttributeSyntax.KEYWORD, tok, args);
}

fn Parsed[] Wip.parsed(&self) => self.attrs.array_view();

<* Borrow the expression results belonging to one parsed attribute. *>
fn parser_result::Result[] Wip.parsed_args(&self, Parsed attr)
{
	parser_result::Result[] all = self.args.array_view();
	return all[(usz)attr.args_index : (usz)attr.args_len];
}

<* Render the attribute spelling used by Attribute/Diagnostic `{at}` placeholders. *>
fn String rendered_attribute_name(Parsed attr)
{
	String name = attr.name.name();
	DString rendered_name;
	rendered_name.init(tmem);
	if (attr.syntax == attribute::AttributeSyntax.STANDARD && attr.name.ns != attribute::AttrNamespace.STANDARD)
	{
		rendered_name.append_string(attr.name.ns.name);
		rendered_name.append_string("::");
		rendered_name.append_string(name);
	}
	else
	{
		rendered_name.append_string(name);
	}
	return rendered_name.str_view();
}

<* `%s` argument printing an attribute's quoted name, as Zig's `{at}`. *>
struct AttrName
{
	Parsed attr;
}

fn sz? AttrName.to_format(&self, Formatter* f) @dynamic => f.printf("'%s'", rendered_attribute_name(self.attr));

<* `fmt` with every `{at}` replaced by `attr`'s quoted name (names never contain '%'). *>
fn String at_fmt(Parsed attr, String fmt)
{
	if (!fmt.contains("{at}")) return fmt;
	DString out;
	out.init(tmem);
	String quoted = string::tformat("'%s'", rendered_attribute_name(attr));
	sz i = 0;
	while (i < fmt.len)
	{
		if (fmt[i..].starts_with("{at}"))
		{
			out.append_string(quoted);
			i += 4;
			continue;
		}
		out.append_char(fmt[i]);
		i++;
	}
	return out.str_view();
}

<*
 Report `$diag` for `attr` at its token. `{at}` in `$diag.fmt` becomes the
 attribute's quoted name; the varargs fill the printf placeholders and are
 checked against `$diag.fmt` at compile time.
*>
macro void? Wip.emit(&self, parser::Parser* p, Parsed attr, $diag, ...)
{
	return self.emit_at(p, attr, attr.tok, $diag, ...$vaarg);
}

<* `Wip.emit` at `tok_index` (an argument's token), falling back to `attr.tok` and then to no location. *>
macro void? Wip.emit_at(&self, parser::Parser* p, Parsed attr, tokens::TokenIndex tok_index, $diag, ...)
{
	if (!p.comp.diagnostics.@enabled($diag)) return;
	// Never runs: makes `string::tformat`'s @format check the varargs against the
	// constant fmt (`{at}` is plain text to it). The real format string below is
	// built at runtime, so it is not checked itself.
	if (false) (void)string::tformat($diag.fmt, ...$vaarg);
	@pool()
	{
		String text = string::tformat(at_fmt(attr, $diag.fmt), ...$vaarg);
		return self.add_message(p, attr, tok_index, diagnostics::@message($diag, text));
	};
}

<* Add `m` at `tok_index`, else at `attr.tok`, else without a location. *>
fn void? Wip.add_message(&self, parser::Parser* p, Parsed attr, tokens::TokenIndex tok_index, Message m)
{
	if ((usz)tok_index >= p.tree.tokens.len) tok_index = attr.tok;
	if ((usz)tok_index >= p.tree.tokens.len) return p.comp.diagnostics.add(m);
	tokens::TreeToken tok = p.tree.tokens[(usz)tok_index];
	m.has_location = true;
	m.location = tok.loc.expand(p.comp);
	return p.comp.diagnostics.add_with_location(p.comp, m, p.pp.expansion_slice(tok_index), true);
}

fn bool? Wip.arg_count(&self, parser::Parser* p, Parsed attr, uint count)
{
	if (attr.args_len == count) return false;
	switch (count)
	{
		case 0: self.emit(p, attr, Diagnostic.ARG_COUNT_ZERO)!;
		case 1: self.emit(p, attr, Diagnostic.ARG_COUNT_ONE)!;
		default: self.emit(p, attr, Diagnostic.ARG_COUNT, (long)count)!;
	}
	return true;
}

fn bool? Wip.arg_count_min_max(&self, parser::Parser* p, Parsed attr, uint min, uint max)
{
	if (attr.args_len < min)
	{
		self.emit(p, attr, Diagnostic.NOT_ENOUGH_ARGS, (long)min)!;
		return true;
	}
	if (attr.args_len > max)
	{
		self.emit(p, attr, Diagnostic.TOO_MANY_ARGS, (long)max)!;
		return true;
	}
	return false;
}

fn void Wip.add_applied(&self, parser::Parser* p, Parsed parsed, attribute::AttributeArgs args)
{
	attribute::Attribute attr = { .args = args, .syntax = parsed.syntax, .name = parsed.name, .tok = parsed.tok };
	self.applied.push(p.tree.attr_map.put(attr));
}

fn void Wip.commit(&self, parser::Parser* p, type_store::NodeIndex target)
{
	p.tree.attr_map.set_decl_attrs(target, self.applied.array_view());
}

fn void? Wip.invalid_target(&self, parser::Parser* p, Parsed attr, String targets)
{
	self.emit(p, attr, Diagnostic.INVALID_TARGET, targets)!;
}

fn tokens::TokenIndex argument_token(parser::Parser* p, Parsed attr, parser_result::Result arg)
{
	if ((usz)arg.node >= (usz)p.tree.nodes.len()) return attr.tok;
	tokens::TokenIndex tok = arg.node.tok(&p.tree);
	if ((usz)tok >= p.tree.tokens.len) return attr.tok;
	return tok;
}

fn void? Wip.emit_arg_type(&self, parser::Parser* p, Parsed attr, parser_result::Result arg, String expected, String actual)
{
	return self.emit_at(p, attr, argument_token(p, attr, arg), Diagnostic.ARG_TYPE, expected, actual);
}

<* Zig `Target` enum (Wip.zig): declaration kinds accepted by `check_target`; `text` is `Target.str`. *>
enum TargetKind : char (String text)
{
	FUNCTION { "functions" },
	FUNCTION_POINTER { "function pointers" },
	VARIABLE { "variables" },
	LOCAL_VARIABLE { "local variables" },
	GLOBAL_VARIABLE { "global variables" },
	LABEL { "labels" },
	PARAM { "parameters" },
	TAG { "tag types" },
	FIELD { "fields" },
	TYPEDEF { "typedefs" },
	FUNCTION_TYPE { "functions and function pointers" },
}

<* Zig `?[]const u8` argument: `has_value` is false when the argument is absent. *>
struct OptionalArgString
{
	bool has_value;
	String value;
}

<* Zig `Parser.Choices` separators: `a`, `b`, and `c`; two items join with ` and `. *>
fn void append_choice(DString* out, String choice, uint index, uint count, bool quoted)
{
	if (index != 0)
	{
		if (count > 2) out.append_char(',');
		out.append_char(' ');
		if (index == count - 1) out.append_string("and ");
	}
	if (quoted) out.append_char('"');
	out.append_string(choice);
	if (quoted) out.append_char('"');
}

fn String choice_list(String[] choices, bool quoted)
{
	DString out;
	out.init(tmem);
	for (uint i = 0; i < (uint)choices.len; i++) append_choice(&out, choices[(sz)i], i, (uint)choices.len, quoted);
	return out.str_view();
}

fn String target_list(TargetKind[] list)
{
	DString out;
	out.init(tmem);
	for (uint i = 0; i < (uint)list.len; i++) append_choice(&out, list[(sz)i].text, i, (uint)list.len, false);
	return out.str_view();
}

<* Integer constant text for DIAG_ARG_INT_OUT_OF_RANGE, including arbitrary-width values. *>
fn String int_value_text(parser::Parser* p, parser_result::Result arg)
{
	DString text;
	text.init(tmem);
	primitive_value::PrimitiveValue key = p.comp.interner.get(arg.val.ref());
	if (key.tag.kind != NumberKind.INT) return "";
	text.appendf("%s", key);
	return text.str_view();
}

<* Zig `a string` / `an identifier` "but got" text for an argument value. *>
fn String arg_actual_kind(parser::Parser* p, parser_result::Result arg)
{
	if (arg.val.is_none()) return "an expression";
	primitive_value::PrimitiveType tag = p.comp.interner.get(arg.val.ref()).tag;
	if (tag.kind == NumberKind.INT) return "an integer constant";
	if (tag == primitive_value::PrimitiveType.BYTES) return "a string";
	if (tag.kind == NumberKind.FLOAT) return "a floating point number";
	if (tag.kind == NumberKind.COMPLEX) return "a complex floating point number";
	if (tag == primitive_value::PrimitiveType.NULL) return "nullptr";
	return "an expression";
}

fn void? Wip.emit_requires_string(&self, parser::Parser* p, Parsed attr, parser_result::Result arg)
{
	return self.emit_at(p, attr, argument_token(p, attr, arg), Diagnostic.ARG_REQUIRES_STRING);
}

<* Zig `arg` for an unsigned integer constant. Returns false after emitting a diagnostic; callers pass an index below args_len. *>
fn bool? Wip.arg_u32(&self, parser::Parser* p, Parsed attr, usz index, uint* out)
{
	parser_result::Result arg = self.parsed_args(attr)[(sz)index];
	if (!arg.val.is_none())
	{
		if (try v = arg.val.to_u32(p.comp))
		{
			*out = v;
			return true;
		}
		if (arg.val.is_int(p.comp))
		{
			self.emit_at(p, attr, argument_token(p, attr, arg), Diagnostic.ARG_INT_OUT_OF_RANGE, int_value_text(p, arg))!;
			return false;
		}
	}
	self.emit_arg_type(p, attr, arg, "an integer constant", arg_actual_kind(p, arg))!;
	return false;
}

<* Zig `arg` for a narrow string literal. Returns false after emitting a diagnostic; callers pass an index below args_len. *>
fn bool? Wip.arg_string(&self, parser::Parser* p, Parsed attr, usz index, String* out)
{
	parser_result::Result arg = self.parsed_args(attr)[(sz)index];
	if (arg.val.is_none())
	{
		self.emit_requires_string(p, attr, arg)!;
		return false;
	}
	if (p.comp.interner.get(arg.val.ref()).tag != primitive_value::PrimitiveType.BYTES)
	{
		self.emit_arg_type(p, attr, arg, "a string", arg_actual_kind(p, arg))!;
		return false;
	}
	tree::Node arg_node = arg.node.get(&p.tree);
	if (arg_node.kind != tree::NodeKind.STRING_LITERAL_EXPR)
	{
		self.emit_requires_string(p, attr, arg)!;
		return false;
	}
	if (arg_node.char_literal.kind == tree::CharLiteralKind.WIDE || arg_node.char_literal.kind == tree::CharLiteralKind.UTF16 || arg_node.char_literal.kind == tree::CharLiteralKind.UTF32)
	{
		self.emit_requires_string(p, attr, arg)!;
		return false;
	}
	// Parsed string literals have array types. A few synthetic tree nodes use
	// the element type directly, so only unwrap when the type is an array.
	type_store::QualType elem_qt = arg_node.char_literal.qt;
	if (try string_ty = elem_qt.get(p.comp, type_store::TypeTag.ARRAY)) elem_qt = string_ty.array.elem;
	if (try elem = elem_qt.get(p.comp, type_store::TypeTag.INT))
	{
		if (elem.int_ty != type_store::TypeInt.CHAR && elem.int_ty != type_store::TypeInt.UCHAR && elem.int_ty != type_store::TypeInt.SCHAR)
		{
			self.emit_requires_string(p, attr, arg)!;
			return false;
		}
	}
	else
	{
		self.emit_requires_string(p, attr, arg)!;
		return false;
	}
	char[] bytes = arg.val.to_bytes(p.comp);
	*out = (String)bytes[0 : bytes.len - 1];
	return true;
}

<* Zig `?[]const u8` argument. Absent argument yields `has_value = false` without a diagnostic. *>
fn bool? Wip.arg_optional_string(&self, parser::Parser* p, Parsed attr, usz index, OptionalArgString* out)
{
	*out = {};
	if (index >= (usz)attr.args_len) return true;
	String value;
	if (!self.arg_string(p, attr, index, &value)!) return false;
	*out = { .has_value = true, .value = value };
	return true;
}

<* Zig `Tree.Node.DeclRef` argument: a bare identifier that names a declaration. *>
fn bool? Wip.arg_decl_ref(&self, parser::Parser* p, Parsed attr, usz index, tree::NodeDeclRef* out)
{
	parser_result::Result arg = self.parsed_args(attr)[(sz)index];
	tree::Node node = arg.node.get(&p.tree);
	if (arg.val.is_none() && node.kind == tree::NodeKind.DECL_REF_EXPR)
	{
		*out = node.decl_ref;
		return true;
	}
	self.emit_arg_type(p, attr, arg, "an identifier", arg_actual_kind(p, arg))!;
	return false;
}

<*
 Zig `arg` for a string-valued enum. `choices` lists the accepted spellings;
 `*out` receives the index of the match, and the caller maps it to its value.
*>
fn bool? Wip.arg_enum(&self, parser::Parser* p, Parsed attr, usz index, String[] choices, uint* out)
{
	parser_result::Result arg = self.parsed_args(attr)[(sz)index];
	if (arg.val.is_none() || p.comp.interner.get(arg.val.ref()).tag != primitive_value::PrimitiveType.BYTES)
	{
		self.emit_arg_type(p, attr, arg, "a string", arg_actual_kind(p, arg))!;
		return false;
	}
	char[] bytes = arg.val.to_bytes(p.comp);
	String str = (String)bytes[0 : bytes.len - 1];
	for (uint i = 0; i < (uint)choices.len; i++)
	{
		if (choices[(sz)i] == str)
		{
			*out = i;
			return true;
		}
	}
	self.emit_at(p, attr, argument_token(p, attr, arg), Diagnostic.UNKNOWN_ENUM, choice_list(choices, true))!;
	return false;
}

<* Zig `checkTarget` arm: whether a declaration node of type `qt` matches one target kind. *>
fn bool target_matches(parser::Parser* p, TargetKind target, tree::Node node, type_store::QualType qt)
{
	if (target == TargetKind.FUNCTION) return node.kind == tree::NodeKind.FUNCTION;
	if (target == TargetKind.VARIABLE) return node.kind == tree::NodeKind.VARIABLE;
	if (target == TargetKind.LABEL) return node.kind == tree::NodeKind.LABELED_STMT || node.kind == tree::NodeKind.DEFAULT_STMT || node.kind == tree::NodeKind.CASE_STMT;
	if (target == TargetKind.PARAM) return node.kind == tree::NodeKind.PARAM;
	if (target == TargetKind.TAG) return node.kind.props.tag_decl;
	if (target == TargetKind.FIELD) return node.kind.props.field_decl;
	if (target == TargetKind.TYPEDEF) return node.kind == tree::NodeKind.TYPEDEF;
	if (target == TargetKind.LOCAL_VARIABLE || target == TargetKind.GLOBAL_VARIABLE)
	{
		if (node.kind != tree::NodeKind.VARIABLE) return false;
		tree::VariableStorageClass storage = node.variable.storage_class;
		bool automatic = storage == tree::VariableStorageClass.AUTO || storage == tree::VariableStorageClass.REGISTER;
		if (target == TargetKind.LOCAL_VARIABLE) return automatic && p.function_context.active;
		return storage == tree::VariableStorageClass.EXTERN || (automatic && !p.function_context.active);
	}
	if (qt.is_invalid()) return false;
	type_store::BaseType base = qt.base(p.comp);
	if (target == TargetKind.FUNCTION_POINTER)
	{
		return base.ty.tag == type_store::TypeTag.POINTER && base.ty.pointer.child.base(p.comp).ty.tag == type_store::TypeTag.FUNC;
	}
	type_store::QualType func_qt = qt;
	if (base.ty.tag == type_store::TypeTag.POINTER) func_qt = base.ty.pointer.child;
	return func_qt.base(p.comp).ty.tag == type_store::TypeTag.FUNC;
}

<* Zig `checkTarget`: false when `decl` matches a kind in `list`; otherwise emit DIAG_INVALID_TARGET and return true. *>
fn bool? Wip.check_target(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt, TargetKind[] list)
{
	tree::Node node = decl.get(&p.tree);
	foreach (target : list) if (target_matches(p, target, node, qt)) return false;
	self.invalid_target(p, attr, target_list(list))!;
	return true;
}

<* Zig `incompatible`: report and drop each applied attribute with `opposing`; the caller then applies its own. *>
fn void? Wip.incompatible(&self, parser::Parser* p, Parsed attr, attribute::AttributeTag opposing)
{
	uint i = 0;
	while (i < (uint)self.applied.len())
	{
		attribute::Attribute prev = p.tree.attr_map.get(self.applied[(sz)i]);
		if (prev.args.tag != opposing)
		{
			i++;
			continue;
		}
		Parsed prior = { .name = prev.name, .syntax = prev.syntax, .tok = prev.tok };
		self.emit(p, attr, Diagnostic.INCOMPATIBLE_ATTR, (AttrName){ prior })!;
		self.emit(p, { .name = prev.name, .tok = prev.tok }, Diagnostic.CONFLICTING_ATTRIBUTE)!;
		self.applied.remove_at((sz)i);
	}
}

<* Apply declaration attributes currently represented by Attribute.Map. Uses the declaration's own type. *>
fn void? Wip.apply_decl_attrs(&self, parser::Parser* p, type_store::NodeIndex decl, type_store::NodeOptIndex previous)
{
	return self.apply_decl_attrs_extra(p, decl, decl.qt(&p.tree), previous);
}

<* Zig `applyDeclAttrsExtra`: apply declaration attributes against an explicit type `qt`. *>
fn void? Wip.apply_decl_attrs_extra(&self, parser::Parser* p, type_store::NodeIndex decl, type_store::QualType qt, type_store::NodeOptIndex previous)
{
	self.applied.clear();
	if (!previous.is_null())
	{
		foreach (ref : p.tree.attr_map.attrs(previous))
		{
			attribute::Attribute prior = p.tree.attr_map.get(ref);
			switch (prior.args.tag)
			{
				case PACKED: case HOT: case COLD: case CONST: case DEPRECATED: case UNAVAILABLE: case ERROR: case WARNING: case VISIBILITY: case NORETURN: case CLEANUP: case ALWAYS_INLINE: case GNU_INLINE:
					self.applied.push(ref);
				case ALIGNMENT:
					self.add_alignment_to_type_map(p, decl.get(&p.tree), qt, prior.args.alignment.has_alignment, prior.args.alignment.alignment);
					self.applied.push(ref);
				default: {}
			}
		}
	}
	for (uint i = self.top; i < (uint)self.attrs.len(); i++)
	{
		Parsed attr = self.attrs[(sz)i];
		if (attr.used_as_type_attr) continue;
		tree::Node node = decl.get(&p.tree);
		attribute::AttributeArgs value = { .tag = attribute::AttributeTag.PACKED };
		bool apply = false;
		switch (attr.name.ns)
		{
			case STANDARD:
				switch (attr.name.standard)
				{
					case DEPRECATED: self.apply_deprecated(p, attr)!; continue;
					case NODISCARD: self.apply_warn_unused_result(p, attr, decl, qt)!; continue;
					case NORETURN: case _NORETURN: self.apply_noreturn(p, attr, decl, qt)!; continue;
					case MAYBE_UNUSED: self.apply_unused(p, attr, decl, qt)!; continue;
					case UNSEQUENCED:
						if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION_TYPE })!) continue;
						if (self.arg_count(p, attr, 0)!) continue;
						value.tag = attribute::AttributeTag.UNSEQUENCED; apply = true;
					case REPRODUCIBLE:
						if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION_TYPE })!) continue;
						if (self.arg_count(p, attr, 0)!) continue;
						value.tag = attribute::AttributeTag.REPRODUCIBLE; apply = true;
					case FALLTHROUGH: self.emit(p, attr, Diagnostic.STMT_ATTR_ON_DECL)!;
				}
			case GNU:
				switch (attr.name.gnu)
				{
					case PACKED:
						if (self.check_target(p, attr, decl, qt, { TargetKind.TAG, TargetKind.FIELD })!) continue;
						value.tag = attribute::AttributeTag.PACKED; apply = !self.arg_count(p, attr, 0)!;
					case HOT: case COLD:
						if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION })!) continue;
						if (self.arg_count(p, attr, 0)!) continue;
						self.incompatible(p, attr, attr.name.gnu == attribute::AttrGnu.HOT ? attribute::AttributeTag.COLD : attribute::AttributeTag.HOT)!;
						value.tag = attr.name.gnu == attribute::AttrGnu.HOT ? attribute::AttributeTag.HOT : attribute::AttributeTag.COLD; apply = true;
					case CONST: case __CONST: value.tag = attribute::AttributeTag.CONST; apply = !self.arg_count(p, attr, 0)!;
					case DEPRECATED: self.apply_deprecated(p, attr)!; continue;
					case WARN_UNUSED_RESULT: self.apply_warn_unused_result(p, attr, decl, qt)!; continue;
					case NORETURN: self.apply_noreturn(p, attr, decl, qt)!; continue;
					case UNUSED: self.apply_unused(p, attr, decl, qt)!; continue;
					case FALLTHROUGH: self.emit(p, attr, Diagnostic.STMT_ATTR_ON_DECL)!;
					case WEAK:
						if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.VARIABLE })!) continue;
						value.tag = attribute::AttributeTag.WEAK; apply = !self.arg_count(p, attr, 0)!;
					case SELECTANY:
						value.tag = attribute::AttributeTag.SELECTANY; apply = !self.arg_count(p, attr, 0)!;
					case WARNING: case ERROR:
						{
							if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION })!) continue;
							if (self.arg_count(p, attr, 1)!) continue;
							String message;
							if (!self.arg_string(p, attr, 0, &message)!) continue;
							value.tag = attr.name.gnu == attribute::AttrGnu.WARNING ? attribute::AttributeTag.WARNING : attribute::AttributeTag.ERROR;
							if (value.tag == attribute::AttributeTag.WARNING) { value.warning = message; } else { value.error_msg = message; }
							apply = true;
						}
					case DESIGNATED_INIT:
						if (node.kind != tree::NodeKind.STRUCT_DECL) { self.emit(p, attr, Diagnostic.DESIGNATED_INIT_INVALID)!; continue; }
						if (self.arg_count(p, attr, 0)!) return;
						value.tag = attribute::AttributeTag.DESIGNATED_INIT; apply = true;
					case ALIGNED: self.apply_alignment(p, attr, qt, node, false)!;
					case CDECL: case FASTCALL: case MS_ABI: case REGCALL: case STDCALL: case SYSV_ABI: case THISCALL:
						self.attrs[(sz)i].used_as_type_attr = true;
						if (self.arg_count(p, attr, 0)!) continue;
						qt = self.apply_calling_convention(p, i, qt, true)!;
					case PCS:
						self.attrs[(sz)i].used_as_type_attr = true;
						if (self.arg_count(p, attr, 1)!) continue;
						qt = self.apply_calling_convention(p, i, qt, true)!;
					case CLEANUP: self.apply_cleanup(p, attr, decl, qt)!; continue;
					case NONNULL: self.apply_nonnull(p, attr, decl, qt)!; continue;
					case TRANSPARENT_UNION: self.apply_transparent_union(p, attr, decl, node, qt)!; continue;
					case SECTION: self.apply_section(p, attr, decl, qt)!; continue;
					case VISIBILITY: self.apply_visibility(p, attr, decl, qt)!; continue;
					case ALWAYS_INLINE: self.apply_always_inline(p, attr, decl, qt)!; continue;
					case GNU_INLINE: self.apply_gnu_inline(p, attr, decl, qt)!; continue;
					default: self.emit(p, attr, Diagnostic.UNIMPLEMENTED)!;
				}
			case CLANG:
				switch (attr.name.clang)
				{
					case UNAVAILABLE:
						{
							if (self.arg_count_min_max(p, attr, 0, 1)!) continue;
							OptionalArgString unavailable_msg;
							if (!self.arg_optional_string(p, attr, 0, &unavailable_msg)!) continue;
							value.tag = attribute::AttributeTag.UNAVAILABLE;
							value.unavailable = { .has_msg = unavailable_msg.has_value, .msg = unavailable_msg.value };
							apply = true;
						}
					case INTERNAL_LINKAGE:
						if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.VARIABLE })!) continue;
						if (self.arg_count(p, attr, 0)!) continue;
						value.tag = attribute::AttributeTag.INTERNAL_LINKAGE; apply = true;
					case AARCH64_SVE_PCS: case AARCH64_VECTOR_PCS: case RISCV_VECTOR_CC: case RISCV_VLS_CC: case VECTORCALL:
						self.attrs[(sz)i].used_as_type_attr = true;
						if (self.arg_count(p, attr, 0)!) continue;
						qt = self.apply_calling_convention(p, i, qt, true)!;
					case ALWAYS_INLINE: self.apply_always_inline(p, attr, decl, qt)!; continue;
					default: self.emit(p, attr, Diagnostic.UNIMPLEMENTED)!;
				}
			case DECLSPEC:
				switch (attr.name.declspec)
				{
					case ALIGN: self.apply_alignment(p, attr, qt, node, false)!;
					case DEPRECATED: self.apply_deprecated(p, attr)!; continue;
					case NORETURN: self.apply_noreturn(p, attr, decl, qt)!; continue;
					case ALLOCATE: self.apply_section(p, attr, decl, qt)!; continue;
					case SELECTANY:
						value.tag = attribute::AttributeTag.SELECTANY; apply = !self.arg_count(p, attr, 0)!;
					default: self.emit(p, attr, Diagnostic.UNIMPLEMENTED)!;
				}
			case KEYWORD:
				switch (attr.name.keyword)
				{
					case __CDECL: case _CDECL: case __FASTCALL: case _FASTCALL: case _REGCALL: case __STDCALL: case _STDCALL: case __THISCALL: case _THISCALL: case __VECTORCALL: case _VECTORCALL:
						self.attrs[(sz)i].used_as_type_attr = true;
						if (self.arg_count(p, attr, 0)!) continue;
						qt = self.apply_calling_convention(p, i, qt, true)!;
					case _ALIGNAS: case ALIGNAS: self.apply_alignment(p, attr, qt, node, true)!;
					case NORETURN: self.apply_noreturn(p, attr, decl, qt)!; continue;
					case __FORCEINLINE: case _FORCEINLINE: self.apply_always_inline(p, attr, decl, qt)!; continue;
					default: self.emit(p, attr, Diagnostic.UNIMPLEMENTED)!;
				}
			case RISCV:
				switch (attr.name.riscv)
				{
					case VECTOR_CC: case VLS_CC:
						self.attrs[(sz)i].used_as_type_attr = true;
						if (self.arg_count(p, attr, 0)!) continue;
						qt = self.apply_calling_convention(p, i, qt, true)!;
				}
			case ARO: case MSVC: self.emit(p, attr, Diagnostic.UNIMPLEMENTED)!;
		}
		if (apply) self.add_applied(p, attr, value);
	}
	self.check_linkage_attrs(p, decl)!;
	self.commit(p, decl);
}

<* Remove weak/selectany attributes that conflict with this declaration's linkage. *>
fn void? Wip.apply_nonnull(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (qt.is_invalid()) return;
	if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.FUNCTION_POINTER, TargetKind.PARAM })!) return;
	tree::Node node = decl.get(&p.tree);
	if (node.kind == tree::NodeKind.PARAM)
	{
		if (attr.args_len != 0)
		{
			self.emit(p, attr, Diagnostic.NONNULL_PARAM_ARGS)!;
			return;
		}
		if (!qt.is_pointer(p.comp))
		{
			self.emit(p, attr, Diagnostic.NONNULL_POINTER_ONLY)!;
			return;
		}
		self.add_applied(p, attr, { .tag = attribute::AttributeTag.NONNULL, .nonnull = {} });
		return;
	}

	type_store::Func func = qt.get_func(p.comp)!!;
	Allocator payload_allocator = p.comp.arena;
	bool free_positions = payload_allocator == null;
	if (free_positions) payload_allocator = p.comp.gpa;
	uint[] positions = {};
	if (attr.args_len != 0) positions = alloc::new_array(payload_allocator, uint, attr.args_len);
	defer
	{
		if (free_positions && positions.len != 0) alloc::free(payload_allocator, positions.ptr);
	}
	uint positions_len = 0;
	parser_result::Result[] args = self.parsed_args(attr);
	for (uint i = 0; i < attr.args_len; i++)
	{
		uint position = 0;
		if (!self.arg_u32(p, attr, (usz)i, &position)!) return;
		tokens::TokenIndex arg_tok = args[(sz)i].node.tok(&p.tree);
		Parsed arg_attr = attr; arg_attr.tok = arg_tok;
		if (position == 0 || position > func.params.len)
		{
			self.emit(p, arg_attr, Diagnostic.PARAM_OUT_OF_BOUNDS, (long)(i + 1))!;
			return;
		}
		type_store::QualType arg_qt = func.params[(usz)(position - 1)].qt;
		if (arg_qt.is_invalid()) continue;
		if (!arg_qt.is_pointer(p.comp))
		{
			self.emit(p, arg_attr, Diagnostic.NONNULL_POINTER_ONLY)!;
			continue;
		}
		positions[(sz)positions_len] = position;
		positions_len++;
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.NONNULL, .nonnull = positions[:(sz)positions_len] });
}

fn void? Wip.apply_transparent_union(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, tree::Node node, type_store::QualType qt)
{
	if (qt.is_invalid()) return;
	if (node.kind == tree::NodeKind.UNION_FORWARD_DECL)
	{
		self.emit(p, attr, Diagnostic.TRANSPARENT_UNION_FORWARD_DECL)!;
		return;
	}
	if (node.kind != tree::NodeKind.UNION_DECL)
	{
		self.emit(p, attr, Diagnostic.TRANSPARENT_UNION_WRONG_TYPE)!;
		return;
	}
	if (self.arg_count(p, attr, 0)!) return;
	type_store::NodeIndex[] fields = node.container_decl.fields;
	if (fields.len == 0)
	{
		self.emit(p, attr, Diagnostic.TRANSPARENT_UNION_ONE_FIELD)!;
		return;
	}
	bool has_first_size = false;
	ulong first_size = 0;
	for (uint i = 0; i < (uint)fields.len; i++)
	{
		type_store::NodeIndex field = fields[(sz)i];
		if (try size_bytes = field.qt(&p.tree).sizeof_or_null(p.comp))
		{
			ulong field_size = size_bytes * 8;
			if (!has_first_size)
			{
				has_first_size = true;
				first_size = field_size;
				continue;
			}
			if (field_size == first_size) continue;

			tokens::TokenIndex field_tok = field.tok(&p.tree);
			Parsed field_attr = attr; field_attr.tok = field_tok;
			self.emit(p, field_attr, Diagnostic.TRANSPARENT_UNION_SIZE, p.tree.tok_slice(field_tok), (ulong)field_size)!;
			self.emit(p, { .name = attr.name, .tok = fields[0].tok(&p.tree) }, Diagnostic.TRANSPARENT_UNION_SIZE_NOTE, (ulong)first_size)!;
			return;
		}
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.TRANSPARENT_UNION });
}

fn void? Wip.apply_visibility(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.GLOBAL_VARIABLE })!) return;
	if (self.arg_count(p, attr, 1)!) return;
	String[4] choices = { "hidden", "default", "internal", "protected" };
	uint choice = 0;
	if (!self.arg_enum(p, attr, 0, choices[..], &choice)!) return;
	attribute::Visibility kind = choice == 0 || choice == 2 ? attribute::Visibility.HIDDEN : choice == 1 ? attribute::Visibility.DEFAULT : attribute::Visibility.PROTECTED;
	if (kind == attribute::Visibility.PROTECTED && !p.comp.target.has_protected_visibility())
	{
		self.emit(p, attr, Diagnostic.VISIBILITY_PROTECTED_INVALID)!;
		kind = attribute::Visibility.DEFAULT;
	}
	for (uint i = 0; i < (uint)self.applied.len(); i++)
	{
		attribute_map::AttrRef ref = self.applied[(sz)i];
		attribute::Attribute prev = p.tree.attr_map.get(ref);
		if (prev.args.tag != attribute::AttributeTag.VISIBILITY) continue;
		if (prev.args.visibility == kind)
		{
			self.applied.remove_at((sz)i);
			break;
		}
		self.emit(p, attr, Diagnostic.INCOMPATIBLE_VISIBILITY)!;
		self.emit(p, { .name = prev.name, .tok = prev.tok }, Diagnostic.PREVIOUS_ATTRIBUTE)!;
		return;
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.VISIBILITY, .visibility = kind });
}

fn void? Wip.apply_noreturn(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION })!) return;
	if (self.arg_count(p, attr, 0)!) return;
	if (attr.name.ns == attribute::AttrNamespace.STANDARD && attr.name.standard == attribute::AttrStandard._NORETURN)
	{
		self.emit(p, attr, Diagnostic.DEPRECATED_NORETURN)!;
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.NORETURN });
}

fn void? Wip.apply_cleanup(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (qt.is_invalid()) return;
	if (self.check_target(p, attr, decl, qt, { TargetKind.LOCAL_VARIABLE })!) return;
	if (self.arg_count(p, attr, 1)!) return;
	tree::NodeDeclRef decl_ref;
	if (!self.arg_decl_ref(p, attr, 0, &decl_ref)!) return;
	tree::Node decl_node = decl_ref.decl.get(&p.tree);
	String function_name = p.tree.tok_slice(decl_ref.name_tok);
	if (decl_node.kind != tree::NodeKind.FUNCTION)
	{
		self.emit(p, attr, Diagnostic.CLEANUP_NON_FUNCTION, function_name)!;
		return;
	}
	type_store::Func func = decl_node.function.qt.get_func(p.comp)!!;
	if (func.params.len != 1)
	{
		self.emit(p, attr, Diagnostic.CLEANUP_ONE_ARG, function_name)!;
		return;
	}
	type_store::QualType expected_qt = p.comp.type_store.put(type_store::type_pointer(qt));
	type_store::QualType actual_qt = func.params[0].qt;
	if (!actual_qt.eql(expected_qt, p.comp))
	{
		self.emit(p, attr, Diagnostic.CLEANUP_ARG_TY, function_name, p.fmt_qt(actual_qt), p.fmt_qt(expected_qt))!;
		return;
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.CLEANUP, .cleanup = { .function = decl_ref.decl } });
}

fn void? Wip.apply_always_inline(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION })!) return;
	if (self.arg_count(p, attr, 0)!) return;
	foreach (ref : self.applied.array_view())
	{
		attribute::Attribute prev = p.tree.attr_map.get(ref);
		if (prev.args.tag == attribute::AttributeTag.OPTNONE)
		{
			self.emit(p, attr, Diagnostic.IGNORED_ATTRIBUTE)!;
			self.emit(p, { .name = prev.name, .tok = prev.tok }, Diagnostic.CONFLICTING_ATTRIBUTE)!;
			return;
		}
		if (prev.args.tag == attribute::AttributeTag.ALWAYS_INLINE) return;
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.ALWAYS_INLINE });
}

fn void? Wip.apply_gnu_inline(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION })!) return;
	if (self.arg_count(p, attr, 0)!) return;
	if (!decl.get(&p.tree).function.is_inline)
	{
		self.emit(p, attr, Diagnostic.GNU_INLINE_NON_INLINE)!;
		return;
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.GNU_INLINE });
}

fn void? Wip.apply_section(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.GLOBAL_VARIABLE })!) return;
	if (self.arg_count(p, attr, 1)!) return;
	String section_name;
	if (!self.arg_string(p, attr, 0, &section_name)!) return;
	foreach (ref : self.applied.array_view())
	{
		attribute::Attribute prev = p.tree.attr_map.get(ref);
		if (prev.args.tag != attribute::AttributeTag.SECTION) continue;
		if (prev.args.section == section_name) return;
		self.emit(p, attr, Diagnostic.CONFLICTING_SECTION_NAME)!;
		self.emit(p, { .name = prev.name, .tok = prev.tok }, Diagnostic.CONFLICTING_ATTRIBUTE)!;
		return;
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.SECTION, .section = section_name });
}

<* Zig `applyDeprecated`: GNU takes up to two arguments (message, replacement); standard and declspec take up to one. *>
fn void? Wip.apply_deprecated(&self, parser::Parser* p, Parsed attr)
{
	uint max_args = attr.syntax == attribute::AttributeSyntax.GNU ? 2 : 1;
	if (self.arg_count_min_max(p, attr, 0, max_args)!) return;
	OptionalArgString msg;
	if (!self.arg_optional_string(p, attr, 0, &msg)!) return;
	OptionalArgString replacement;
	if (!self.arg_optional_string(p, attr, 1, &replacement)!) return;
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.DEPRECATED, .deprecated = { .has_msg = msg.has_value, .msg = msg.value, .has_replacement = replacement.has_value, .replacement = replacement.value } });
}

<* Zig `applyWarnUnusedResult` for standard `nodiscard` (0-1 args) and GNU `warn_unused_result` (0 args). *>
fn void? Wip.apply_warn_unused_result(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	bool standard = attr.syntax == attribute::AttributeSyntax.STANDARD;
	if (standard)
	{
		if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.TAG })!) return;
	}
	else
	{
		if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.TAG, TargetKind.FUNCTION_POINTER, TargetKind.TYPEDEF })!) return;
	}
	uint max_args = standard ? 1 : 0;
	if (self.arg_count_min_max(p, attr, 0, max_args)!) return;
	OptionalArgString msg;
	if (!self.arg_optional_string(p, attr, 0, &msg)!) return;
	if (try func = qt.get_func(p.comp))
	{
		if (func.return_type.is(p.comp, type_store::TypeTag.VOID))
		{
			self.emit(p, attr, Diagnostic.WARN_UNUSED_RESULT_VOID)!;
			return;
		}
	}
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.WARN_UNUSED_RESULT, .warn_unused_result = { .has_msg = msg.has_value, .msg = msg.value } });
}

<* Zig `applyUnused` for `unused` and `maybe_unused`. *>
fn void? Wip.apply_unused(&self, parser::Parser* p, Parsed attr, type_store::NodeIndex decl, type_store::QualType qt)
{
	if (self.check_target(p, attr, decl, qt, { TargetKind.FUNCTION, TargetKind.VARIABLE, TargetKind.PARAM, TargetKind.TYPEDEF, TargetKind.TAG, TargetKind.FIELD, TargetKind.LABEL })!) return;
	if (self.arg_count(p, attr, 0)!) return;
	self.add_applied(p, attr, { .tag = attribute::AttributeTag.UNUSED });
}

fn void? Wip.check_linkage_attrs(&self, parser::Parser* p, type_store::NodeIndex decl)
{
	tree::Node node = decl.get(&p.tree);
	bool internal_linkage = false;
	foreach (ref : self.applied.array_view()) if (p.tree.attr_map.get(ref).args.tag == attribute::AttributeTag.INTERNAL_LINKAGE) { internal_linkage = true; break; }
	if (node.kind == tree::NodeKind.FUNCTION) internal_linkage = internal_linkage || node.function.is_static;
	if (node.kind == tree::NodeKind.VARIABLE) internal_linkage = internal_linkage || node.variable.storage_class == tree::VariableStorageClass.STATIC || (node.variable.storage_class != tree::VariableStorageClass.EXTERN && p.function_context.active);
	bool bad_weak = false;
	bool bad_selectany = false;
	uint kept = 0;
	for (uint i = 0; i < (uint)self.applied.len(); i++)
	{
		attribute_map::AttrRef ref = self.applied[(sz)i];
		attribute::Attribute attr = p.tree.attr_map.get(ref);
		bool invalid_weak = attr.args.tag == attribute::AttributeTag.WEAK && internal_linkage;
		bool invalid_selectany = attr.args.tag == attribute::AttributeTag.SELECTANY && (internal_linkage || node.kind == tree::NodeKind.FUNCTION);
		if (invalid_weak) { if (!bad_weak) self.emit(p, { .name = attr.name, .syntax = attr.syntax, .tok = attr.tok }, Diagnostic.INVALID_WEAK)!; bad_weak = true; continue; }
		if (invalid_selectany) { if (!bad_selectany) self.emit(p, { .name = attr.name, .syntax = attr.syntax, .tok = attr.tok }, Diagnostic.INVALID_SELECTANY)!; bad_selectany = true; continue; }
		self.applied[(sz)kept] = ref;
		kept++;
	}
	while ((uint)self.applied.len() > kept) self.applied.pop()!!;
}

<* Zig `addAlignmentToTypeMap`: record a requested alignment for typedef and enum nodes only. A missing value counts as `p.comp.target.default_alignment()`. Max-merges with an existing request. *>
fn void Wip.add_alignment_to_type_map(&self, parser::Parser* p, tree::Node node, type_store::QualType qt, bool has_alignment, uint alignment)
{
	if (node.kind != tree::NodeKind.TYPEDEF && node.kind != tree::NodeKind.ENUM_FORWARD_DECL && node.kind != tree::NodeKind.ENUM_DECL) return;
	uint wanted = has_alignment ? alignment : p.comp.target.default_alignment();
	uint? existing = p.comp.type_store.get_requested_alignment(qt);
	if (try e = existing) wanted = max(e, wanted);
	p.comp.type_store.set_requested_alignment(qt, wanted);
}

fn void? Wip.apply_alignment(&self, parser::Parser* p, Parsed attr, type_store::QualType qt, tree::Node node, bool alignas)
{
	if (self.arg_count_min_max(p, attr, 0, 1)!) return;
	bool has_alignment = false;
	uint alignment = 0;
	if (attr.args_len != 0)
	{
		parser_result::Result arg = self.parsed_args(attr)[0];
		tree::Node arg_node = arg.node.get(&p.tree);
		if (alignas && arg_node.kind == tree::NodeKind.ALIGNAS_TYPE)
		{
			alignment = arg_node.alignas_type.qt.alignof(p.comp);
			has_alignment = true;
		}
		else
		{
			uint v = 0;
			if (!self.arg_u32(p, attr, 0, &v)!) return;
			if (v == 0 || (v & (v - 1)) != 0)
			{
				self.emit(p, attr, Diagnostic.NON_POW2_ALIGN)!;
				return;
			}
			alignment = v;
			has_alignment = true;
		}
	}
	if (alignas)
	{
		if (node.kind == tree::NodeKind.PARAM) { self.emit(p, attr, Diagnostic.ALIGNAS_ON_PARAM)!; return; }
		if (node.kind == tree::NodeKind.VARIABLE && node.variable.storage_class == tree::VariableStorageClass.REGISTER) { self.emit(p, attr, Diagnostic.ALIGNAS_ON_REGISTER)!; return; }
		if (node.kind == tree::NodeKind.RECORD_FIELD && !node.record_field.bit_width.is_null()) { self.emit(p, attr, Diagnostic.ALIGNAS_BITFIELD)!; return; }
		if (node.kind != tree::NodeKind.VARIABLE && node.kind != tree::NodeKind.RECORD_FIELD && !node.kind.props.tag_decl) { self.emit(p, attr, Diagnostic.ALIGNAS_ON_FUNC)!; return; }
	}
	else if (node.kind != tree::NodeKind.VARIABLE && node.kind != tree::NodeKind.TYPEDEF && !node.kind.props.tag_decl && !node.kind.props.field_decl && node.kind != tree::NodeKind.PARAM)
	{
		self.invalid_target(p, attr, "functions, variables, typedefs, tags, parameters, and fields")!;
		return;
	}
	if (has_alignment && alignas && alignment < qt.alignof(p.comp))
	{
		self.emit(p, attr, Diagnostic.MINIMUM_ALIGNMENT, (long)qt.alignof(p.comp))!;
	}
	if (p.comp.langopts.emulate == MSVC && (node.kind == tree::NodeKind.ENUM_DECL || node.kind == tree::NodeKind.ENUM_FORWARD_DECL))
	{
		self.emit(p, attr, Diagnostic.MSVC_ENUM_ALIGN_IGNORED)!;
		return;
	}
	self.add_alignment_to_type_map(p, node, qt, has_alignment, alignment);
	attribute::AttributeArgs payload = { .tag = attribute::AttributeTag.ALIGNMENT, .alignment = { .has_alignment = has_alignment, .alignment = alignment } };
	self.add_applied(p, attr, payload);
}

<* Zig `applyTypeAttrs`: apply GNU vector_size, NEON vector, calling-convention, nullability and keyword type attributes to the current type; other recognized type attributes are diagnosed as unimplemented. *>
fn type_store::QualType? Wip.apply_type_attrs(&self, parser::Parser* p, type_store::QualType qt)
{
	type_store::QualType result = qt;
	for (uint i = self.top; i < (uint)self.attrs.len(); i++)
	{
		Parsed attr = self.attrs[(sz)i];
		if (attr.used_as_type_attr) continue;
		if (attr.name.ns == attribute::AttrNamespace.KEYWORD && (attr.name.keyword == attribute::AttrKeyword.NONNULL || attr.name.keyword == attribute::AttrKeyword.NULLABLE || attr.name.keyword == attribute::AttrKeyword.NULLABLE_RESULT || attr.name.keyword == attribute::AttrKeyword.NULL_UNSPECIFIED))
		{
			self.attrs[(sz)i].used_as_type_attr = true;
			if (result.is_invalid()) continue;
			type_store::Nullability new_nullability = type_store::Nullability.DEFAULT;
			switch (attr.name.keyword)
			{
				case NONNULL: new_nullability = type_store::Nullability.NONNULL;
				case NULLABLE: new_nullability = type_store::Nullability.NULLABLE;
				case NULLABLE_RESULT: new_nullability = type_store::Nullability.NULLABLE_RESULT;
				case NULL_UNSPECIFIED: new_nullability = type_store::Nullability.UNSPECIFIED;
				default: unreachable();
			}
			type_store::BaseType base = result.base(p.comp);
			type_store::Type updated = base.ty;
			switch (updated.tag)
			{
				case POINTER:
					if (updated.pointer.nullability != type_store::Nullability.DEFAULT && updated.pointer.nullability != new_nullability)
					{
						self.emit(p, attr, Diagnostic.CONFLICTING_NULLABILITY, new_nullability.str, updated.pointer.nullability.str)!;
						continue;
					}
					updated.pointer.nullability = new_nullability;
				case BLOCK:
					if (updated.block.nullability != type_store::Nullability.DEFAULT && updated.block.nullability != new_nullability)
					{
						self.emit(p, attr, Diagnostic.CONFLICTING_NULLABILITY, new_nullability.str, updated.block.nullability.str)!;
						continue;
					}
					updated.block.nullability = new_nullability;
				default:
					// Zig applyNullability: an array in the type path is not an error; the attribute waits for its declarator.
					if (result.is(p.comp, type_store::TypeTag.ARRAY))
					{
						self.attrs[(sz)i].used_as_type_attr = false;
						continue;
					}
					self.emit(p, attr, Diagnostic.INVALID_NULLABILITY, p.fmt_qt(result))!;
					continue;
			}
			result = p.comp.type_store.put(updated);
		}
		else if (attr.name.ns == attribute::AttrNamespace.GNU && attr.name.gnu == attribute::AttrGnu.VECTOR_SIZE)
		{
			// Zig applyVectorSize sets used only on a normal return. Argument-count, invalid-type and size errors return normally; the ParsingFailed exits below reset the flag so the attribute stays unused.
			self.attrs[(sz)i].used_as_type_attr = true;
			if (result.is_invalid()) continue;
			if (self.arg_count(p, attr, 1)!) continue;
			if (result.is_auto())
			{
				self.attrs[(sz)i].used_as_type_attr = false;
				self.emit(p, attr, Diagnostic.INVALID_VEC_ELEM_TY, p.fmt_qt(result))!;
				return parser::PARSING_FAILED~;
			}
			// Zig requires scalar kind int or float exactly: BOOL, ENUM and complex kinds are rejected. Clang silently ignores vector_size on an incomplete enum (normal return, attribute stays used).
			type_store::ScalarKind scalar_kind = result.scalar_kind(p.comp);
			if (scalar_kind != type_store::ScalarKind.INT && scalar_kind != type_store::ScalarKind.FLOAT)
			{
				if (try enum_ty = result.get(p.comp, type_store::TypeTag.ENUM))
				{
					if (p.comp.langopts.emulate == lang_opts::Compiler.CLANG && enum_ty.enum_ty.incomplete) continue;
				}
				self.attrs[(sz)i].used_as_type_attr = false;
				self.emit(p, attr, Diagnostic.INVALID_VEC_ELEM_TY, p.fmt_qt(result))!;
				return parser::PARSING_FAILED~;
			}
			if (try bit_int_ty = result.get(p.comp, type_store::TypeTag.BIT_INT))
			{
				ulong bits = (ulong)bit_int_ty.bit_int.bits;
				if (bits < 8)
				{
					self.attrs[(sz)i].used_as_type_attr = false;
					self.emit(p, attr, Diagnostic.BIT_INT_VEC_TOO_SMALL)!;
					return parser::PARSING_FAILED~;
				}
				if ((bits & (bits - 1)) != 0)
				{
					self.attrs[(sz)i].used_as_type_attr = false;
					self.emit(p, attr, Diagnostic.BIT_INT_VEC_NOT_POW2)!;
					return parser::PARSING_FAILED~;
				}
			}
			uint bytes = 0;
			if (!self.arg_u32(p, attr, 0, &bytes)!) continue;
			uint elem_size = (uint)result.sizeof(p.comp);
			if (bytes == 0 || elem_size == 0 || bytes % elem_size != 0)
			{
				self.emit(p, attr, Diagnostic.VEC_SIZE_NOT_MULTIPLE)!;
				continue;
			}
			result = p.comp.type_store.put(type_store::type_vector(result, bytes / elem_size));
		}
		else if (attr.name.ns == attribute::AttrNamespace.CLANG && (attr.name.clang == attribute::AttrClang.NEON_VECTOR_TYPE || attr.name.clang == attribute::AttrClang.NEON_POLYVECTOR_TYPE))
		{
			type_store::VectorKind kind = attr.name.clang == attribute::AttrClang.NEON_POLYVECTOR_TYPE ? type_store::VectorKind.NEON_POLY : type_store::VectorKind.NEON;
			result = self.apply_neon_vector(p, attr, result, kind)!;
			self.attrs[(sz)i].used_as_type_attr = true;
		}
		else if (attr.name.ns == attribute::AttrNamespace.GNU && (attr.name.gnu == attribute::AttrGnu.CDECL || attr.name.gnu == attribute::AttrGnu.FASTCALL || attr.name.gnu == attribute::AttrGnu.STDCALL || attr.name.gnu == attribute::AttrGnu.THISCALL || attr.name.gnu == attribute::AttrGnu.SYSV_ABI || attr.name.gnu == attribute::AttrGnu.MS_ABI || attr.name.gnu == attribute::AttrGnu.REGCALL))
		{
			result = self.apply_type_calling_convention(p, i, 0, result)!;
		}
		else if (attr.name.ns == attribute::AttrNamespace.GNU && attr.name.gnu == attribute::AttrGnu.PCS)
		{
			result = self.apply_type_calling_convention(p, i, 1, result)!;
		}
		else if ((attr.name.ns == attribute::AttrNamespace.GNU && (attr.name.gnu == attribute::AttrGnu.REGPARM || attr.name.gnu == attribute::AttrGnu.RISCV_RVV_VECTOR_BITS)) || (attr.name.ns == attribute::AttrNamespace.CLANG && (attr.name.clang == attribute::AttrClang.ADDRESS_SPACE || attr.name.clang == attribute::AttrClang.ARM_SVE_VECTOR_BITS || attr.name.clang == attribute::AttrClang.EXT_VECTOR_TYPE || attr.name.clang == attribute::AttrClang.MATRIX_TYPE || attr.name.clang == attribute::AttrClang.NODEREF) || (attr.name.ns == attribute::AttrNamespace.KEYWORD && (attr.name.keyword == attribute::AttrKeyword.PTR32 || attr.name.keyword == attribute::AttrKeyword.PTR64 || attr.name.keyword == attribute::AttrKeyword.SPTR || attr.name.keyword == attribute::AttrKeyword.UPTR))))
		{
			self.emit(p, attr, Diagnostic.UNIMPLEMENTED)!;
			self.attrs[(sz)i].used_as_type_attr = true;
		}
		else if ((attr.name.ns == attribute::AttrNamespace.CLANG && (attr.name.clang == attribute::AttrClang.AARCH64_SVE_PCS || attr.name.clang == attribute::AttrClang.AARCH64_VECTOR_PCS || attr.name.clang == attribute::AttrClang.RISCV_VECTOR_CC || attr.name.clang == attribute::AttrClang.RISCV_VLS_CC || attr.name.clang == attribute::AttrClang.VECTORCALL)) || (attr.name.ns == attribute::AttrNamespace.RISCV && (attr.name.riscv == attribute::AttrRiscv.VECTOR_CC || attr.name.riscv == attribute::AttrRiscv.VLS_CC)))
		{
			result = self.apply_type_calling_convention(p, i, 0, result)!;
		}
		else if (attr.name.ns == attribute::AttrNamespace.KEYWORD && (attr.name.keyword == attribute::AttrKeyword.__CDECL || attr.name.keyword == attribute::AttrKeyword._CDECL || attr.name.keyword == attribute::AttrKeyword.__FASTCALL || attr.name.keyword == attribute::AttrKeyword._FASTCALL || attr.name.keyword == attribute::AttrKeyword._REGCALL || attr.name.keyword == attribute::AttrKeyword.__STDCALL || attr.name.keyword == attribute::AttrKeyword._STDCALL || attr.name.keyword == attribute::AttrKeyword.__THISCALL || attr.name.keyword == attribute::AttrKeyword._THISCALL || attr.name.keyword == attribute::AttrKeyword.__VECTORCALL || attr.name.keyword == attribute::AttrKeyword._VECTORCALL))
		{
			result = self.apply_type_calling_convention(p, i, 0, result)!;
		}
	}
	return result;
}

<* Zig `applyCallingConvention` delay checks: true when the attribute should wait for a later declarator. `can_delay` needs a non-standard spelling and no declarator target (Zig `wip.current.target == null`), so the decl path (`has_decl_target` true) never waits on an auto type or a non-function. The incomplete-declarator placeholder waits either way, as Zig does. *>
fn bool calling_convention_delayed(parser::Parser* p, Parsed attr, type_store::QualType qt, bool has_decl_target)
{
	bool can_delay = !has_decl_target && attr.syntax != attribute::AttributeSyntax.STANDARD;
	type_store::QualType cur = qt;
	while (true)
	{
		if (cur.is_invalid()) return false;
		if (cur.is_auto()) return can_delay;
		if (cur.index == type_store::IDX_DECLARATOR_COMBINE) return true;
		type_store::BaseType base = cur.base(p.comp);
		if (base.ty.tag == type_store::TypeTag.FUNC) return false;
		if (base.ty.tag != type_store::TypeTag.POINTER) return can_delay;
		cur = base.ty.pointer.child;
	}
}

<* Apply queued type-position calling conventions once declarator combination has produced its final type. *>
fn type_store::QualType? Wip.apply_pending_calling_conventions(&self, parser::Parser* p, type_store::QualType final_qt)
{
	type_store::QualType result = final_qt;
	uint pending_count = (uint)self.pending_calling_conventions.len();
	uint i = self.pending_calling_conventions_cursor;
	while (i < pending_count)
	{
		uint attr_index = self.pending_calling_conventions[(sz)i];
		i++;
		if (attr_index >= (uint)self.attrs.len()) continue;
		Parsed attr = self.attrs[(sz)attr_index];
		// Keep an incomplete declarator queued; the retry helper is called again
		// after its placeholder has been combined into a concrete type.
		if (calling_convention_delayed(p, attr, result, true))
		{
			self.pending_calling_conventions.push(attr_index);
			continue;
		}
		result = self.apply_calling_convention(p, attr_index, result, true)!;
	}
	self.pending_calling_conventions_cursor = pending_count;
	return result;
}

<* Zig `applyTypeAttrs` calling-convention arm: the attribute counts as used first, then checks its argument count, then waits for a later declarator when `calling_convention_delayed` says so. *>
fn type_store::QualType? Wip.apply_type_calling_convention(&self, parser::Parser* p, uint index, uint arg_total, type_store::QualType qt)
{
	Parsed attr = self.attrs[(sz)index];
	self.attrs[(sz)index].used_as_type_attr = true;
	if (qt.is_invalid()) return qt;
	if (self.arg_count(p, attr, arg_total)!) return qt;
	return self.apply_calling_convention(p, index, qt, false);
}

<* Zig `applyNeonVector`: element type and 64/128-bit size rules for `neon_vector_type` and `neon_polyvector_type`. A bad element type or size is diagnosed and `qt` is returned unchanged; an auto type fails the attribute list. *>
fn type_store::QualType? Wip.apply_neon_vector(&self, parser::Parser* p, Parsed attr, type_store::QualType qt, type_store::VectorKind kind)
{
	if (qt.is_invalid()) return qt;
	if (self.arg_count(p, attr, 1)!) return qt;
	if (qt.is_auto())
	{
		self.emit(p, attr, Diagnostic.INVALID_VEC_ELEM_TY, p.fmt_qt(qt))!;
		return parser::PARSING_FAILED~;
	}
	bool is_aarch64 = p.comp.target.cpu.arch.is_aarch64();
	bool valid_elem_ty = false;
	if (kind == type_store::VectorKind.NEON_POLY)
	{
		if (try poly_ty = qt.get(p.comp, type_store::TypeTag.INT))
		{
			if (is_aarch64)
			{
				valid_elem_ty = poly_ty.int_ty == type_store::TypeInt.UCHAR || poly_ty.int_ty == type_store::TypeInt.USHORT || poly_ty.int_ty == type_store::TypeInt.ULONG || poly_ty.int_ty == type_store::TypeInt.ULONG_LONG;
			}
			else
			{
				valid_elem_ty = poly_ty.int_ty == type_store::TypeInt.SCHAR || poly_ty.int_ty == type_store::TypeInt.SHORT || poly_ty.int_ty == type_store::TypeInt.LONG_LONG;
			}
		}
	}
	else
	{
		type_store::BaseType base = qt.base(p.comp);
		switch (base.ty.tag)
		{
			case INT:
				switch (base.ty.int_ty)
				{
					case SCHAR: case UCHAR: case SHORT: case USHORT: case INT: case UINT: case LONG: case ULONG: case LONG_LONG: case ULONG_LONG: valid_elem_ty = true;
					default: {}
				}
			case FLOAT:
				switch (base.ty.float_ty)
				{
					case FLOAT: case FP16: case BF16: valid_elem_ty = true;
					case DOUBLE: valid_elem_ty = is_aarch64;
					default: {}
				}
			case STORAGE_FLOAT: valid_elem_ty = true;
			default: {}
		}
	}
	if (!valid_elem_ty)
	{
		self.emit(p, attr, Diagnostic.INVALID_VEC_ELEM_TY, p.fmt_qt(qt))!;
		return qt;
	}
	uint vec_len = 0;
	if (!self.arg_u32(p, attr, 0, &vec_len)!) return qt;
	ulong vec_bits = qt.bit_sizeof(p.comp) * (ulong)vec_len;
	if (vec_bits != 64 && vec_bits != 128)
	{
		self.emit(p, attr, Diagnostic.INVALID_NEON_VEC_SIZE)!;
		return qt;
	}
	return p.comp.type_store.put(type_store::type_vector(qt, vec_len, kind));
}

<* Zig `applyCallingConvention` `supported` switch: whether `cc` is usable on the compilation target. *>
fn bool calling_convention_supported(target::Target* t, type_store::CallingConvention cc)
{
	target::Arch arch = t.cpu.arch;
	bool ms_abi = t.os.tag == target::OsTag.WINDOWS || t.os.tag == target::OsTag.UEFI;
	bool cdecl_supported = !(arch.is_arm() && t.os.tag != target::OsTag.WINDOWS) && arch != target::Arch.POWERPC64 && arch != target::Arch.POWERPC64LE && !arch.is_spirv();
	switch (cc)
	{
		case CDECL: return cdecl_supported;
		case AARCH64_SVE_PCS: case AARCH64_VECTOR_PCS: return arch.is_aarch64();
		case ARM_AAPCS_VFP: case ARM_AAPCS: return arch.is_arm();
		case RISCV_VECTOR_CC: case RISCV_VLS_CC: return arch.is_riscv();
		case MS_ABI:
			if (ms_abi) return cdecl_supported;
			return arch == target::Arch.X86_64 || arch.is_aarch64();
		case SYSV_ABI:
			if (ms_abi) return arch == target::Arch.X86_64;
			return cdecl_supported;
		case FASTCALL: case REGCALL: case STDCALL: case THISCALL: return arch == target::Arch.X86;
		case VECTORCALL: return arch == target::Arch.X86 || arch == target::Arch.X86_64 || arch.is_aarch64();
		default: return true;
	}
}

<* Queue `attr_index` for apply_pending_calling_conventions. A slot already queued is not added again. *>
fn void Wip.queue_pending_calling_convention(&self, uint attr_index)
{
	foreach (pending_index : self.pending_calling_conventions_active()) if (pending_index == attr_index) return;
	self.pending_calling_conventions.push(attr_index);
}

<* Apply the calling convention for the slot `attr_index` in self.attrs. Any delay queues the slot and leaves its used flag set so the decl pass skips it until apply_pending_calling_conventions retries. On the decl path (`has_decl_target`) the only delay is the incomplete-declarator placeholder; auto and non-function types diagnose immediately. *>
fn type_store::QualType? Wip.apply_calling_convention(&self, parser::Parser* p, uint attr_index, type_store::QualType qt, bool has_decl_target)
{
	Parsed attr = self.attrs[(sz)attr_index];
	self.attrs[(sz)attr_index].used_as_type_attr = true;
	if (qt.is_invalid()) return qt;
	if (calling_convention_delayed(p, attr, qt, has_decl_target))
	{
		// Only the incomplete-declarator placeholder reaches here on the decl path; the used flag stays set so the decl pass skips the slot until the retry.
		self.queue_pending_calling_convention(attr_index);
		return qt;
	}
	// Zig loops through pointer children to the function type.
	type_store::QualType cur = qt;
	type_store::BaseType base;
	while (true)
	{
		if (cur.is_invalid()) return qt;
		if (cur.is_auto())
		{
			self.emit(p, attr, Diagnostic.CALLCONV_NON_FUNC, p.fmt_qt(qt))!;
			return qt;
		}
		if (cur.index == type_store::IDX_DECLARATOR_COMBINE)
		{
			// Unreachable after calling_convention_delayed; kept so base() is never called on the placeholder.
			return qt;
		}
		base = cur.base(p.comp);
		if (base.ty.tag != type_store::TypeTag.POINTER) break;
		cur = base.ty.pointer.child;
	}
	type_store::QualType func_qt = base.qt;
	if (base.ty.tag != type_store::TypeTag.FUNC)
	{
		self.emit(p, attr, Diagnostic.CALLCONV_NON_FUNC, p.fmt_qt(qt))!;
		return qt;
	}
	type_store::CallingConvention cc = type_store::CallingConvention.DEFAULT;
	switch (attr.name.ns)
	{
		case GNU:
			switch (attr.name.gnu)
			{
				case CDECL: cc = type_store::CallingConvention.CDECL;
				case FASTCALL: cc = type_store::CallingConvention.FASTCALL;
				case STDCALL: cc = type_store::CallingConvention.STDCALL;
				case THISCALL: cc = type_store::CallingConvention.THISCALL;
				case SYSV_ABI: cc = type_store::CallingConvention.SYSV_ABI;
				case MS_ABI: cc = type_store::CallingConvention.MS_ABI;
				case REGCALL: cc = type_store::CallingConvention.REGCALL;
				case PCS:
				{
					String[] pcs_names = { "aapcs", "aapcs-vfp" };
					uint pcs_index = 0;
					if (!self.arg_enum(p, attr, 0, pcs_names, &pcs_index)!) return qt;
					cc = pcs_index == 0 ? type_store::CallingConvention.ARM_AAPCS : type_store::CallingConvention.ARM_AAPCS_VFP;
				}
				default: {}
			}
		case CLANG:
			switch (attr.name.clang)
			{
				case AARCH64_SVE_PCS: cc = type_store::CallingConvention.AARCH64_SVE_PCS;
				case AARCH64_VECTOR_PCS: cc = type_store::CallingConvention.AARCH64_VECTOR_PCS;
				case RISCV_VECTOR_CC: cc = type_store::CallingConvention.RISCV_VECTOR_CC;
				case RISCV_VLS_CC: cc = type_store::CallingConvention.RISCV_VLS_CC;
				case VECTORCALL: cc = type_store::CallingConvention.VECTORCALL;
				default: {}
			}
		case KEYWORD:
			switch (attr.name.keyword)
			{
				case __CDECL: case _CDECL: cc = type_store::CallingConvention.CDECL;
				case __FASTCALL: case _FASTCALL: cc = type_store::CallingConvention.FASTCALL;
				case _REGCALL: cc = type_store::CallingConvention.REGCALL;
				case __STDCALL: case _STDCALL: cc = type_store::CallingConvention.STDCALL;
				case __THISCALL: case _THISCALL: cc = type_store::CallingConvention.THISCALL;
				case __VECTORCALL: case _VECTORCALL: cc = type_store::CallingConvention.VECTORCALL;
				default: {}
			}
		case RISCV:
			switch (attr.name.riscv)
			{
				case VECTOR_CC: cc = type_store::CallingConvention.RISCV_VECTOR_CC;
				case VLS_CC: cc = type_store::CallingConvention.RISCV_VLS_CC;
			}
		default: {}
	}
	if (!calling_convention_supported(&p.comp.target, cc))
	{
		self.emit(p, attr, Diagnostic.CALLCONV_NOT_SUPPORTED)!;
		return qt;
	}
	type_store::Type func_ty = base.ty;
	if (func_ty.func.cc != type_store::CallingConvention.DEFAULT && func_ty.func.cc != cc)
	{
		self.emit(p, attr, Diagnostic.CALLCONV_INCOMPATIBLE, cc.name, func_ty.func.cc.name)!;
		return qt;
	}
	func_ty.func.cc = cc;
	p.comp.type_store.set(func_ty, func_qt.index);
	return qt;
}

<* Apply the supported statement-only subset using the surrounding statement parser's switch context. *>
fn void? Wip.apply_stmt_attrs(&self, parser::Parser* p, type_store::NodeIndex stmt, bool in_switch)
{
	self.applied.clear();
	tree::Node node = stmt.get(&p.tree);
	for (uint i = self.top; i < (uint)self.attrs.len(); i++)
	{
		Parsed attr = self.attrs[(sz)i];
		bool fallthrough = attr.name.ns == attribute::AttrNamespace.STANDARD && attr.name.standard == attribute::AttrStandard.FALLTHROUGH || attr.name.ns == attribute::AttrNamespace.GNU && attr.name.gnu == attribute::AttrGnu.FALLTHROUGH;
		bool hot = attr.name.ns == attribute::AttrNamespace.GNU && attr.name.gnu == attribute::AttrGnu.HOT;
		bool cold = attr.name.ns == attribute::AttrNamespace.GNU && attr.name.gnu == attribute::AttrGnu.COLD;
		bool unused = attr.name.ns == attribute::AttrNamespace.GNU && attr.name.gnu == attribute::AttrGnu.UNUSED;
		if (fallthrough)
		{
			if (self.arg_count(p, attr, 0)!) continue;
			if (node.kind != tree::NodeKind.NULL_STMT) { self.emit(p, attr, Diagnostic.FALLTHROUGH_NON_EMPTY)!; continue; }
			if (!in_switch) { self.emit(p, attr, Diagnostic.FALLTHROUGH_OUTSIDE_SWITCH)!; continue; }
			for (usz token_i = (usz)p.tok_i; token_i < p.tree.tokens.len; token_i++)
			{
				tokenizer::TokenId id = p.tree.tokens[token_i].id;
				if (id == tokenizer::TokenId.KEYWORD_CASE || id == tokenizer::TokenId.KEYWORD_DEFAULT || id == tokenizer::TokenId.EOF) break;
				if (id == tokenizer::TokenId.R_BRACE || id == tokenizer::TokenId.SEMICOLON) continue;
				self.emit(p, attr, Diagnostic.FALLTHROUGH_NOT_BEFORE_CASE)!;
				break;
			}
			self.add_applied(p, attr, { .tag = attribute::AttributeTag.FALLTHROUGH });
		}
		else if (hot || cold)
		{
			if (self.check_target(p, attr, stmt, type_store::INVALID, { TargetKind.LABEL })!) continue;
			if (self.arg_count(p, attr, 0)!) continue;
			self.incompatible(p, attr, hot ? attribute::AttributeTag.COLD : attribute::AttributeTag.HOT)!;
			self.add_applied(p, attr, { .tag = hot ? attribute::AttributeTag.HOT : attribute::AttributeTag.COLD });
		}
		else if (unused)
		{
			if (self.check_target(p, attr, stmt, type_store::INVALID, { TargetKind.FUNCTION, TargetKind.VARIABLE, TargetKind.PARAM, TargetKind.TYPEDEF, TargetKind.TAG, TargetKind.FIELD, TargetKind.LABEL })!) continue;
			if (self.arg_count(p, attr, 0)!) continue;
			self.add_applied(p, attr, { .tag = attribute::AttributeTag.UNUSED });
		}
		else { self.emit(p, attr, Diagnostic.INVALID_STMT_ATTR)!; }
	}
	self.commit(p, stmt);
}
