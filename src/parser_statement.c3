// Bounded statement grammar port from Parser.zig. Local declaration
// recognition and active function metadata are supplied by the declaration
// owner because this module does not own those productions.
module aro::parser_statement;
import aro::attribute, aro::attribute_wip, aro::compilation, aro::parser, aro::parser_attribute, aro::parser_result, aro::tree, aro::tokens, aro::tokenizer, aro::diagnostics;
import aro::type_store, aro::lang_opts, aro::bigint, aro::attribute_map;
import aro::parser_declaration;
import aro::parser_builtin, aro::parser_declarator, aro::text_literal;
import std::collections::list, std::collections::map;
import std::core::dstring;
import std::core::mem;
import aro::value;

excuse PARSING_FAILED;

struct SwitchCaseEntry
{
	value::Value start; value::Value end; tokens::TokenIndex tok;
}

fn bool switch_case_ranges_overlap(SwitchCaseEntry previous, value::Value start, value::Value end, parser::Parser* p)
{
	return !value::compare(end, bigint::CompareOperator.LT, previous.start, p.comp) &&
	!value::compare(previous.end, bigint::CompareOperator.LT, start, p.comp);
}

<* Test-only replacement for the local declaration production; compiled out of
   non-test builds. Installed as StatementParser.local_declaration_probe. *>
interface ILocalDeclarationTestProbe @feat(TESTING)
{
	<* The declaration grammar owns recognition and construction. Return a complete
	   DECL_STMT node when recognized, tree::NULL_NODE when this token sequence is
	   not a local declaration (leaving parser state unchanged), and PARSING_FAILED
	   for a recognized malformed declaration. parser::HOOK_ABSENT means the
	   implementer provides no local declarations. *>
	fn type_store::NodeIndex? parse_local_declaration(parser::Parser* p);
}

<* Expression parsing is delegated to the active expression grammar. *>
struct StatementParser (parser::IAddressOfLabel)
{
	<* Expression productions; statements use `expression` and `integer_constant_expression`. *>
	parser::IExpressionGrammar expressions;
	<* Local declarations; null when statements contain only expressions. *>
	parser_declaration::DeclarationParser* local_declarations;
	<* Replaces `local_declarations` when set. *>
	ILocalDeclarationTestProbe local_declaration_probe @feat(TESTING);
	parser_attribute::AttributeBuffer* prefix_declaration_attributes;
	bool prefix_declaration_attributes_consumed;
	uint loop_depth;
	uint switch_depth;
	bool switch_has_default;
	tokens::TokenIndex switch_default_tok;
	type_store::QualType switch_qt;
	list::List{SwitchCaseEntry} switch_case_values;
	<* Single-value cases: interned value ref -> index in `switch_case_values`. Equal
	   integer values share one ref, so lookup replaces a linear overlap scan. *>
	HashMap{uint, uint} switch_case_singles;
	<* Indices of range cases (`start != end`) in `switch_case_values`. *>
	list::List{uint} switch_case_ranges;
	bool has_switch_case_values;
	bool function_has_address_of_label;
	tokens::TokenIndex computed_goto_tok;
	bool has_computed_goto;
	list::List{tokens::TokenIndex} labels;
	list::List{type_store::NodeIndex} label_nodes;
	list::List{tokens::TokenIndex} gotos;
	uint label_count;
	bool in_function;
	type_store::QualType function_return_qt;
	tokens::TokenIndex function_name_tok;
	bool has_function_context;
}

<* Zig `expr` through `expressions`. *>
fn parser_result::Result? StatementParser.expr(&self, parser::Parser* p, bool eval)
{
	parser::IExpressionGrammar g = self.expressions;
	if (!g || !& g.expression)
	{
		p.grammar_unavailable()!; return PARSING_FAILED~;
	}
	return g.expression(p, eval);
}

<* Whether a local declaration grammar (or test probe) is installed. *>
fn bool StatementParser.has_local_declarations(&self) @inline
{
	$if env::TESTING:
		if (self.local_declaration_probe) return true;
	$endif
	return self.local_declarations != null;
}

<* A local declaration at the cursor, or tree::NULL_NODE when there is none or no declaration grammar. *>
fn type_store::NodeIndex? StatementParser.local_declaration(&self, parser::Parser* p)
{
	type_store::NodeIndex? parsed;
	$if env::TESTING:
		if (self.local_declaration_probe)
		{
			parsed = self.local_declaration_probe.parse_local_declaration(p);
			if (catch f = parsed) return (f == parser::HOOK_ABSENT ? tree::NULL_NODE : f)~;
			return parsed;
		}
	$endif
	if (!self.local_declarations) return tree::NULL_NODE~;
	parsed = self.local_declarations.parse_local_declaration(p);
	if (catch f = parsed) return (f == parser::HOOK_ABSENT ? tree::NULL_NODE : f)~;
	return parsed;
}

fn parser_result::Result? StatementParser.integer_const_expr(&self, parser::Parser* p)
{
	tokens::TokenIndex start = p.tok_i;
	parser::ConstDeclFoldingMode previous_mode = p.const_decl_folding;
	p.const_decl_folding = parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION;
	defer p.const_decl_folding = previous_mode;
	// Prefer the integer-constant production; fall back to a full expression.
	parser_result::Result? maybe_result = parser::HOOK_ABSENT~;
	parser::IExpressionGrammar g = self.expressions;
	if (g)
	{
		maybe_result = g.integer_constant_expression(p, parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION, true);
	}
	if (catch absent = maybe_result)
	{
		if (absent == parser::HOOK_ABSENT) maybe_result = self.expr(p, true);
	}
	fault parse_fault = @catch(maybe_result);
	if (parse_fault) return (parse_fault == parser::NO_EXPRESSION ? PARSING_FAILED : parse_fault)~;
	if (!@ok(maybe_result)) return PARSING_FAILED~;
	parser_result::Result result = maybe_result!;
	if (!result.qt.is_invalid() && !result.qt.is_real_int(p.comp))
	{
		Diagnostic.EXPECTED_INTEGER_CONSTANT_EXPR.@emit(p, start)!;
		return PARSING_FAILED~;
	}
	return result;
}

fn bool same_token_text(parser::Parser* p, tokens::TokenIndex a, tokens::TokenIndex b)
{
	return p.tree.tok_slice(a) == p.tree.tok_slice(b);
}

<* Check a QualType handle before using relation helpers that decode it. Parser
 recovery can leave a zero-initialized result handle, which is neither the
 explicit INVALID sentinel nor necessarily a live TypeStore index. *>
fn bool has_decodable_type(type_store::QualType qt, parser::Parser* p)
{
	if (qt.is_invalid() || qt.is_auto() || qt.is_declarator_combine()) return false;
	return qt.builtin || (usz)qt.index < p.comp.type_store.len();
}

fn bool StatementParser.mark_label_used(&self, parser::Parser* p, tokens::TokenIndex name)
{
	for (uint i = 0; i < (uint)self.labels.len(); i++)
	{
		if (!same_token_text(p, self.labels[(sz)i], name)) continue;
		p.mark_used(self.label_nodes[(sz)i]);
		return true;
	}
	return false;
}

fn parser_result::Result? StatementParser.handle_address_of_label(&self, parser::Parser* p) @dynamic
{
	tokens::TokenIndex op_tok = p.tok_i;
	p.advance();
	if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
	{
		p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!;
		return PARSING_FAILED~;
	}
	tokens::TokenIndex label_tok = p.tok_i;
	Diagnostic.GNU_LABEL_AS_VALUE.@emit(p, op_tok)!;
	if (self.in_function)
	{
		self.function_has_address_of_label = true;
		if (!self.mark_label_used(p, label_tok)) self.gotos.push(label_tok);
	}
	p.advance();
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.ADDR_OF_LABEL,
			.addr_of_label = { .label_tok = label_tok, .qt = type_store::VOID_POINTER }
		}
	);
	return { .node = node, .qt = type_store::VOID_POINTER, .val = value::NONE };
}

<* Adapter state for IParserHandler.handle_body. The parsed tree node remains
 caller-owned; `body` is cleared before each callback invocation. *>
struct StatementBodyBinding
{
	StatementParser* statements;
	type_store::NodeOptIndex body;
}

<* Parse a function body into `binding.body` (NODE_NULL on failure). *>
fn void? StatementBodyBinding.parse(&binding, parser::Parser* p)
{
	binding.body = type_store::NODE_NULL;
	type_store::NodeIndex? parsed = binding.statements.parse_body(p, true);
	if (catch __fault = parsed)
	{
		if (__fault == PARSING_FAILED) return parser::PARSING_FAILED~;
		return __fault~;
	}
	binding.body = parsed.pack();
}

<* Evaluate the borrowed token ranges for each attribute argument and append
 them to the temporary Wip state. The expression parser advances only inside
 the range selected by the attribute syntax reader; restore the statement
 cursor on both success and failure. *>
fn void? append_statement_attributes(parser::Parser* p,
	parser_attribute::AttributeBuffer* buffer, attribute_wip::Wip* wip)
{
	tokens::TokenIndex saved_tok_i = p.tok_i;
	tokens::TokenIndex saved_tok_end = p.tok_end;
	defer p.tok_i = saved_tok_i;
	defer p.tok_end = saved_tok_end;
	foreach (parsed : buffer.attributes)
	{
		if (!parsed.has_name) continue;
		list::List{parser_result::Result} args;
		args.init(p.comp.gpa);
		defer args.free();
		for (uint i = 0; i < parsed.args_len; i++)
		{
			parser_attribute::AttributeArgTokens range = buffer.arguments[(sz)(parsed.args_offset + i)];
			// Zig `Parser.attribute`: a lone identifier as the first argument of an
			// attribute that takes one (format/mode/access/spectre) is an
			// IDENTIFIER_ARG node, not an expression.
			if (i == 0 && parsed.name.has_identifier_arg() && range.end == range.start + 1)
			{
				tokenizer::TokenId id = p.tree.tokens[(usz)range.start].id;
				if (id == tokenizer::TokenId.IDENTIFIER || id == tokenizer::TokenId.EXTENDED_IDENTIFIER)
				{
					type_store::NodeIndex ident = p.tree.add_node(
						{
							.kind = tree::NodeKind.IDENTIFIER_ARG,
							.identifier_arg = { .identifier_tok = range.start }
						}
					);
					args.push(
						{
							.node = ident, .qt = type_store::INVALID, .val = value::NONE
						}
					);
					continue;
				}
			}
			p.tok_i = range.start;
			p.tok_end = range.end;
			parser_result::Result? maybe_arg = p.expr(true);
			fault arg_fault = @catch(maybe_arg);
			p.tok_end = saved_tok_end;
			if (arg_fault) return arg_fault~;
			if (p.tok_i != range.end)
			{
				if (p.at_eof())
				{
					Diagnostic.EXPECTED_EOF.@emit(p, p.diag_index(),
					"attribute argument expression")!;
				}
				else if (p.tree.tokens[(usz)p.tok_i].id == tokenizer::TokenId.INVALID)
				{
					Diagnostic.EXPECTED_INVALID.@emit(p, p.tok_i,
						"attribute argument expression")!;
				}
				else
				{
					Diagnostic.EXPECTED_TOKEN.@emit(p, p.tok_i,
						"attribute argument expression", p.tree.tokens[(usz)p.tok_i].id.symbol())!;
				}
				return PARSING_FAILED~;
			}
			parser_result::Result arg = maybe_arg!!;
			args.push(arg);
		}
		wip.add(parsed.name, parsed.syntax, parsed.tok, args.array_view());
	}
}

<* Apply argument-free prefix attributes to every declarator in a local declaration. *>
fn void? StatementParser.apply_prefix_declaration_attrs(&self, parser::Parser* p,
	parser_attribute::AttributeBuffer* buffer, attribute_wip::Wip* wip, type_store::NodeIndex stmt)
{
	append_statement_attributes(p, buffer, wip)!;
	tree::Node declaration_statement = stmt.get(&p.tree);
	foreach (decl : declaration_statement.decl_stmt.decls)
	{
		wip.apply_decl_attrs(p, decl, type_store::NODE_NULL)!;
	}
}

<* Parse one statement. `check_unused` is retained for parity with Parser.zig;
 the diagnostic policy is left to the expression/declaration owner. *>
fn type_store::NodeIndex? StatementParser.parse_statement(&self, parser::Parser* p, bool check_unused = true)
{
	attribute_wip::Wip wip;
	wip.init(p.comp.gpa);
	defer wip.free();
	attribute_wip::State state = wip.state(true);
	defer wip.restore(state);
	parser_attribute::AttributeBuffer buffer;
	buffer.init(p.comp.gpa);
	defer buffer.free();
	if (catch p.parse_attribute_specifiers(&buffer)) return PARSING_FAILED~;
	parser_attribute::AttributeBuffer* old_prefix_attributes = self.prefix_declaration_attributes;
	bool old_prefix_attributes_consumed = self.prefix_declaration_attributes_consumed;
	self.prefix_declaration_attributes = &buffer;
	self.prefix_declaration_attributes_consumed = false;
	defer
	{
		self.prefix_declaration_attributes = old_prefix_attributes;
		self.prefix_declaration_attributes_consumed = old_prefix_attributes_consumed;
	}
	type_store::NodeIndex stmt = self.parse_attributed_statement(p, check_unused)!;
	self.apply_statement_attributes(p, &buffer, &wip, stmt)!;
	return stmt;
}

<* Parse statement syntax after its leading attributes have been recorded. *>
fn type_store::NodeIndex? StatementParser.parse_attributed_statement(&self, parser::Parser* p, bool check_unused = true)
{
	// Kept minimal: this frame is live at every statement nesting level; each
	// statement kind is parsed out of line.
	if (p.is_at(tokenizer::TokenId.IDENTIFIER) && p.is_at(tokenizer::TokenId.COLON, 1))
	{
		return self.parse_label_statement(p, check_unused);
	}
	type_store::NodeIndex asm_node;
	if (parse_asm_statement_into(p, &asm_node)!) return asm_node;
	if (p.at_eof()) return self.parse_declaration_or_expression_statement(p, check_unused);
	switch (p.tree.tokens[(usz)p.tok_i].id)
	{
		case L_BRACE: return self.parse_body(p, false);
		case SEMICOLON: return parse_null_statement(p);
		case KEYWORD_IF: return self.parse_if_statement(p, check_unused);
		case KEYWORD_SWITCH: return self.parse_switch_statement(p, check_unused);
		case KEYWORD_CASE:
		case KEYWORD_DEFAULT: return self.parse_case_statement(p, check_unused);
		case KEYWORD_WHILE: return self.parse_while_statement(p, check_unused);
		case KEYWORD_DO: return self.parse_do_statement(p, check_unused);
		case KEYWORD_FOR: return self.parse_for_statement(p, check_unused);
		case KEYWORD_BREAK:
		case KEYWORD_CONTINUE: return self.parse_break_continue_statement(p, check_unused);
		case KEYWORD_GOTO: return self.parse_goto_statement(p, check_unused);
		case KEYWORD_RETURN: return self.parse_return_statement(p, check_unused);
		default: return self.parse_declaration_or_expression_statement(p, check_unused);
	}
}

<* GNU `asm` statement hook: false when the tokens are not an asm statement. *>
fn bool? parse_asm_statement_into(parser::Parser* p, type_store::NodeIndex* out) @noinline
{
	type_store::NodeIndex? maybe_asm = p.parse_asm_statement();
	if (catch __fault = maybe_asm)
	{
		// NOT_ASM: not an asm statement, continue with the other statement forms.
		if (__fault != parser::NOT_ASM) return __fault~;
		return false;
	}
	*out = maybe_asm;
	return true;
}

<* `;` *>
fn type_store::NodeIndex? parse_null_statement(parser::Parser* p) @noinline
{
	tokens::TokenIndex semi = p.tok_i;
	p.advance();
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.NULL_STMT, .null_stmt = { .semicolon_or_r_brace_tok = semi }
		}
	);
}

<* `label: statement`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_label_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex label_tok = p.tok_i;
	p.advance();
	p.advance();
	type_store::NodeIndex labeled = p.tree.add_node(
		{
			.kind = tree::NodeKind.LABELED_STMT,
			.labeled_stmt = { .label_tok = label_tok, .body = (type_store::NodeIndex)0 }
	}
	);
	attribute_wip::Wip label_wip;
	label_wip.init(p.comp.gpa);
	defer label_wip.free();
	attribute_wip::State label_state = label_wip.state(true);
	defer label_wip.restore(label_state);
	parser_attribute::AttributeBuffer label_buffer;
	label_buffer.init(p.comp.gpa);
	defer label_buffer.free();
	while (true)
	{
		bool? parsed = p.parse_gnu_attribute_specifier(&label_buffer);
		if (catch parsed) return PARSING_FAILED~;
		if (!parsed) break;
	}
	append_statement_attributes(p, &label_buffer, &label_wip)!;
	label_wip.apply_stmt_attrs(p, labeled, self.switch_depth > 0)!;
	p.add_maybe_unused(labeled)!;
	if (self.in_function)
	{
		self.label_count++;
		tokens::TokenIndex? previous = NO_MORE_ELEMENT~;
		foreach (label : self.labels) if (same_token_text(p, label, label_tok))
		{
			previous = label; break;
		}
		if (@ok(previous))
		{
			Diagnostic.DUPLICATE_LABEL.@emit(p, label_tok, p.tree.tok_slice(label_tok))!;
			Diagnostic.PREVIOUS_LABEL.@emit(p, previous!, p.tree.tok_slice(label_tok))!;
		}
		else
		{
			self.labels.push(label_tok);
			self.label_nodes.push(labeled);
		}
	}
	type_store::NodeIndex? maybe_body = self.parse_statement(p, true);
	if (catch __fault = maybe_body) return __fault~;
	p.tree.set_node(
		{
			.kind = tree::NodeKind.LABELED_STMT,
			.labeled_stmt = { .label_tok = label_tok, .body = maybe_body }
		}
		, (sz)labeled);
	return labeled;
}

<* `if (cond) stmt [else stmt]`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_if_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex kw = p.tok_i;
	p.advance();
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	parser_result::Result? maybe_cond = self.expr(p, true);
	if (catch __fault = maybe_cond) return __fault~;
	parser_result::Result cond = maybe_cond;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	cond.lval_conversion(p);
	if (catch cond.usual_unary_conversion(p, opener + 1)) return PARSING_FAILED~;
	cond.save_value(p);
	type_store::NodeIndex maybe_then = self.parse_statement(p, true)!;
	type_store::NodeIndex then_body;
	then_body = maybe_then;
	type_store::NodeOptIndex else_body = type_store::NODE_NULL;
	if (p.is_at(tokenizer::TokenId.KEYWORD_ELSE))
	{
		p.advance();
		type_store::NodeIndex maybe_else = self.parse_statement(p, true)!;
		else_body = maybe_else.pack();
	}
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.IF_STMT, .if_stmt = {
				.if_tok = kw, .init = type_store::NODE_NULL, .cond = cond.node,
				.then_body = then_body, .else_body = else_body,
			}
		}
	);
}

<* `switch (cond) stmt`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_switch_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex kw = p.tok_i;
	p.advance();
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	parser_result::Result? maybe_cond = self.expr(p, true);
	if (catch __fault = maybe_cond) return __fault~;
	parser_result::Result cond = maybe_cond;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	cond.lval_conversion(p);
	if (catch cond.usual_unary_conversion(p, opener + 1)) return PARSING_FAILED~;
	cond.save_value(p);
	bool old_default = self.switch_has_default;
	tokens::TokenIndex old_default_tok = self.switch_default_tok;
	type_store::QualType old_switch_qt = self.switch_qt;
	bool old_has_case_values = self.has_switch_case_values;
	list::List{SwitchCaseEntry} old_case_values = self.switch_case_values;
	HashMap{uint, uint} old_case_singles = self.switch_case_singles;
	list::List{uint} old_case_ranges = self.switch_case_ranges;
	self.switch_has_default = false;
	self.switch_default_tok = 0;
	self.switch_qt = cond.qt;
	self.switch_case_values = {};
	self.switch_case_values.init(p.comp.gpa);
	self.switch_case_singles = {};
	self.switch_case_singles.init(p.comp.gpa);
	self.switch_case_ranges = {};
	self.switch_case_ranges.init(p.comp.gpa);
	self.has_switch_case_values = true;
	defer
	{
		self.switch_case_values.free();
		self.switch_case_singles.free();
		self.switch_case_ranges.free();
		self.switch_case_values = old_case_values;
		self.switch_case_singles = old_case_singles;
		self.switch_case_ranges = old_case_ranges;
		self.has_switch_case_values = old_has_case_values;
		self.switch_has_default = old_default;
		self.switch_default_tok = old_default_tok;
		self.switch_qt = old_switch_qt;
	}
	self.switch_depth++;
	defer self.switch_depth--;
	type_store::NodeIndex? maybe_body = self.parse_statement(p, true);
	if (catch __fault = maybe_body) return __fault~;
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.SWITCH_STMT, .switch_stmt = { .switch_tok = kw, .init = type_store::NODE_NULL, .cond = cond.node, .body = maybe_body }
		}
	);
}

<* One `case expr[...expr]:` / `default:` label, parsed before its statement. *>
struct CaseLabel
{
	tokens::TokenIndex kw;
	bool is_default;
	type_store::NodeIndex value_node;
	type_store::NodeOptIndex end_node;
}

<* `case expr[...expr]: stmt` / `default: stmt`. Directly chained labels
   (`case 1: case 2: ... stmt`) are parsed in a loop and their nodes built
   inside-out afterwards, so label count does not grow the stack. Out of line so
   its locals only occupy the stack while this statement kind is being parsed. *>
fn type_store::NodeIndex? StatementParser.parse_case_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	CaseLabel first;
	self.parse_case_label(p, &first)!;
	if (!p.is_at(tokenizer::TokenId.KEYWORD_CASE) && !p.is_at(tokenizer::TokenId.KEYWORD_DEFAULT))
	{
		type_store::NodeIndex body = self.parse_statement(p, true)!;
		return self.finish_case_label(p, first, body);
	}
	list::List{CaseLabel} chain;
	chain.init(p.comp.gpa);
	defer chain.free();
	chain.push(first);
	while (p.is_at(tokenizer::TokenId.KEYWORD_CASE) || p.is_at(tokenizer::TokenId.KEYWORD_DEFAULT))
	{
		CaseLabel label;
		self.parse_case_label(p, &label)!;
		chain.push(label);
	}
	type_store::NodeIndex body = self.parse_statement(p, true)!;
	// Innermost label first: same node and diagnostic order as recursive parsing.
	for (sz i = chain.len(); i > 0; i--)
	{
		body = self.finish_case_label(p, chain[i - 1], body)!;
	}
	return body;
}

<* The first recorded case overlapping `[start, end]`, if any. *>
fn SwitchCaseEntry? StatementParser.overlapping_case(&self, parser::Parser* p, value::Value start, value::Value end)
{
	if (start.opt_ref == end.opt_ref)
	{
		if (try index = self.switch_case_singles.get((uint)start.opt_ref)) return self.switch_case_values[index];
		foreach (index : self.switch_case_ranges)
		{
			SwitchCaseEntry entry = self.switch_case_values[index];
			if (switch_case_ranges_overlap(entry, start, end, p)) return entry;
		}
		return NO_MORE_ELEMENT~;
	}
	foreach (entry : self.switch_case_values)
	{
		if (switch_case_ranges_overlap(entry, start, end, p)) return entry;
	}
	return NO_MORE_ELEMENT~;
}

fn void StatementParser.add_case_value(&self, SwitchCaseEntry entry)
{
	uint index = (uint)self.switch_case_values.len();
	self.switch_case_values.push(entry);
	if (entry.start.opt_ref == entry.end.opt_ref)
	{
		self.switch_case_singles.set((uint)entry.start.opt_ref, index);
	}
	else
	{
		self.switch_case_ranges.push(index);
	}
}

<* A case/default label up to and including its `:`, with value checks. *>
fn void? StatementParser.parse_case_label(&self, parser::Parser* p, CaseLabel* out) @noinline
{
	bool is_default = p.is_at(tokenizer::TokenId.KEYWORD_DEFAULT);
	tokens::TokenIndex kw = p.tok_i;
	p.advance();
	tokens::TokenIndex case_expr_tok = p.tok_i;
	type_store::NodeIndex value_node;
	type_store::NodeOptIndex end_node = type_store::NODE_NULL;
	value::Value case_value = value::NONE;
	value::Value case_end_value = value::NONE;
	type_store::QualType case_qt = type_store::INVALID;
	parser_result::Result? maybe_case_value;
	parser_result::Result? maybe_case_end = NO_MORE_ELEMENT~;
	tokens::TokenIndex ellipsis = 0;
	if (!is_default)
	{
		parser_result::Result maybe_value = self.integer_const_expr(p)!;
		maybe_case_value = maybe_value;
		if (p.is_at(tokenizer::TokenId.ELLIPSIS))
		{
			ellipsis = p.tok_i;
			p.advance();
			bool c2y = p.comp.langopts.standard.at_least(C2Y);
			if (c2y)
			{
				Diagnostic.PRE_C2Y_SWITCH_RANGE.@emit(p, ellipsis)!;
			}
			else
			{
				Diagnostic.C2Y_SWITCH_RANGE.@emit(p, ellipsis)!;
			}
			parser_result::Result maybe_end = self.integer_const_expr(p)!;
			maybe_case_end = maybe_end;
		}
	}
	if (catch p.expect(tokenizer::TokenId.COLON)) return PARSING_FAILED~;
	if (!is_default && self.switch_depth == 0)
	{
		Diagnostic.CASE_NOT_IN_SWITCH.@emit(p, kw, "case")!;
	}
	if (!is_default)
	{
		parser_result::Result case_result = maybe_case_value!;
		if (self.switch_depth > 0 && has_decodable_type(case_result.qt, p) && has_decodable_type(self.switch_qt, p) &&
		case_result.qt.is_int(p.comp) && self.switch_qt.is_int(p.comp))
		{
			case_result.cast_to_int(p, self.switch_qt, kw + 1)!;
		}
		case_value = case_result.val;
		case_qt = case_result.qt;
		value_node = case_result.node;
		case_result.save_value(p);
		case_end_value = case_value;
		if (@ok(maybe_case_end))
		{
			parser_result::Result case_end_result = maybe_case_end!;
			if (self.switch_depth > 0 && has_decodable_type(case_end_result.qt, p) && has_decodable_type(self.switch_qt, p) &&
			case_end_result.qt.is_int(p.comp) && self.switch_qt.is_int(p.comp))
			{
				case_end_result.cast_to_int(p, self.switch_qt, ellipsis + 1)!;
			}
			case_end_value = case_end_result.val;
			end_node = case_end_result.node.pack();
			case_end_result.save_value(p);
		}
	}
	if (!is_default && self.switch_depth > 0 && self.has_switch_case_values)
	{
		bool case_value_is_live = !case_value.is_none() &&
		(case_value.opt_ref == value::ZERO.opt_ref || case_value.opt_ref == value::ONE.opt_ref ||
			(usz)case_value.opt_ref < (usz)p.comp.interner.items.len());
		bool case_end_value_is_live = !case_end_value.is_none() &&
		(case_end_value.opt_ref == value::ZERO.opt_ref || case_end_value.opt_ref == value::ONE.opt_ref ||
			(usz)case_end_value.opt_ref < (usz)p.comp.interner.items.len());
		if (!case_value_is_live)
		{
			Diagnostic.CASE_VAL_UNAVAILABLE.@emit(p, kw + 1)!;
		}
		else if (!case_end_value_is_live)
		{
			Diagnostic.CASE_VAL_UNAVAILABLE.@emit(p, ellipsis + 1)!;
		}
		else if (value::compare(case_end_value, bigint::CompareOperator.LT, case_value, p.comp))
		{
			Diagnostic.EMPTY_CASE_RANGE.@emit(p, kw + 1)!;
		}
		else
		{
			SwitchCaseEntry? previous = self.overlapping_case(p, case_value, case_end_value);
			if (@ok(previous))
			{
				Diagnostic.DUPLICATE_SWITCH_CASE.@emit(p, kw + 1, p.fmt_value(case_value, case_qt))!;
				Diagnostic.PREVIOUS_CASE.@emit(p, previous!.tok)!;
			}
			else
			{
				self.add_case_value({ .start = case_value, .end = case_end_value, .tok = case_expr_tok });
			}
		}
	}
	*out = { .kw = kw, .is_default = is_default, .value_node = value_node, .end_node = end_node };
	return;
}

<* Build the CASE_STMT / DEFAULT_STMT node for `label` around its parsed body. *>
fn type_store::NodeIndex? StatementParser.finish_case_label(&self, parser::Parser* p, CaseLabel label, type_store::NodeIndex body)
{
	tokens::TokenIndex kw = label.kw;
	if (label.is_default)
	{
		if (self.switch_depth == 0)
		{
			Diagnostic.CASE_NOT_IN_SWITCH.@emit(p, kw, "default")!;
		}
		else if (self.has_switch_case_values && self.switch_has_default)
		{
			Diagnostic.MULTIPLE_DEFAULT.@emit(p, kw)!;
			Diagnostic.PREVIOUS_CASE.@emit(p, self.switch_default_tok)!;
		}
		else if (self.has_switch_case_values)
		{
			self.switch_has_default = true; self.switch_default_tok = kw;
		}
		return p.tree.add_node(
			{
				.kind = tree::NodeKind.DEFAULT_STMT, .default_stmt = { .default_tok = kw, .body = body }
			}
		);
	}
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.CASE_STMT, .case_stmt = { .case_tok = kw, .start = label.value_node, .end = label.end_node, .body = body }
		}
	);
}

<* `while (cond) stmt`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_while_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex kw = p.tok_i;
	p.advance();
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	parser_result::Result? maybe_cond = self.expr(p, true);
	if (catch __fault = maybe_cond) return __fault~;
	parser_result::Result cond = maybe_cond;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	cond.lval_conversion(p);
	if (catch cond.usual_unary_conversion(p, opener + 1)) return PARSING_FAILED~;
	cond.save_value(p);
	self.loop_depth++;
	defer self.loop_depth--;
	type_store::NodeIndex? maybe_body = self.parse_statement(p, true);
	if (catch __fault = maybe_body) return __fault~;
	type_store::NodeIndex body;
	body = maybe_body;
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.WHILE_STMT, .while_stmt = { .while_tok = kw, .cond = cond.node, .body = body }
		}
	);
}

<* `do stmt while (cond);`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_do_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex kw = p.tok_i;
	p.advance();
	self.loop_depth++;
	defer self.loop_depth--;
	type_store::NodeIndex? maybe_body = self.parse_statement(p, true);
	if (catch __fault = maybe_body) return __fault~;
	type_store::NodeIndex body = maybe_body;
	if (catch p.expect(tokenizer::TokenId.KEYWORD_WHILE)) return PARSING_FAILED~;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	parser_result::Result? maybe_cond = self.expr(p, true);
	if (catch __fault = maybe_cond) return __fault~;
	parser_result::Result cond = maybe_cond;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	cond.lval_conversion(p);
	if (catch cond.usual_unary_conversion(p, opener + 1)) return PARSING_FAILED~;
	cond.save_value(p);
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.DO_WHILE_STMT, .do_while_stmt = { .do_tok = kw, .cond = cond.node, .body = body }
		}
	);
}

<* `for (init; cond; incr) stmt`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_for_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex kw = p.tok_i;
	p.advance();
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	p.push_scope();
	defer p.pop_scope();
	self.loop_depth++;
	defer self.loop_depth--;
	// Zig Parser.forStmt: a declaration (which consumes its own ';') or an
	// optional expression followed by ';'.
	type_store::NodeOptIndex init = type_store::NODE_NULL;
	bool init_is_decl = false;
	if (self.has_local_declarations())
	{
		type_store::NodeIndex? maybe_decl;
		{
			parser_attribute::AttributeBuffer* saved_prefix_attributes = self.prefix_declaration_attributes;
			bool saved_prefix_consumed = self.prefix_declaration_attributes_consumed;
			self.prefix_declaration_attributes = null;
			self.prefix_declaration_attributes_consumed = false;
			defer
			{
				self.prefix_declaration_attributes = saved_prefix_attributes;
				self.prefix_declaration_attributes_consumed = saved_prefix_consumed;
			}
			maybe_decl = self.local_declaration(p);
		}
		if (catch __fault = maybe_decl)
		{
			if (__fault != tree::NULL_NODE) return __fault~;
		}
		else
		{
			init = maybe_decl.pack();
			init_is_decl = true;
		}
	}
	if (!init_is_decl)
	{
		uint init_prev_errors = p.diagnostics.errors;
		parser_result::Result? maybe_init = self.expr(p, true);
		if (catch __fault = maybe_init)
		{
			if (__fault != parser::NO_EXPRESSION) return __fault~;
		}
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		if (@ok(maybe_init))
		{
			parser_result::Result init_expr = maybe_init!;
			parser_result::diagnose_unused_value(p, init_expr.node, init_prev_errors)!;
			init_expr.lval_conversion(p);
			init_expr.save_value(p);
			init = init_expr.node.pack();
		}
	}
	parser_result::Result? maybe_cond = self.expr(p, true);
	if (catch __fault = maybe_cond)
	{
		if (__fault != parser::NO_EXPRESSION) return __fault~;
	}
	if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	type_store::NodeOptIndex cond_node = type_store::NODE_NULL;
	if (@ok(maybe_cond))
	{
		parser_result::Result cond = maybe_cond!;
		cond.lval_conversion(p);
		if (catch cond.usual_unary_conversion(p, opener + 1)) return PARSING_FAILED~;
		cond.save_value(p);
		cond_node = cond.node.pack();
	}
	uint incr_prev_errors = p.diagnostics.errors;
	parser_result::Result? maybe_incr = self.expr(p, true);
	if (catch __fault = maybe_incr)
	{
		if (__fault != parser::NO_EXPRESSION) return __fault~;
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	type_store::NodeOptIndex incr = type_store::NODE_NULL;
	if (@ok(maybe_incr))
	{
		parser_result::Result incr_expr = maybe_incr!;
		parser_result::diagnose_unused_value(p, incr_expr.node, incr_prev_errors)!;
		incr_expr.lval_conversion(p);
		incr_expr.save_value(p);
		incr = incr_expr.node.pack();
	}
	type_store::NodeIndex maybe_body = self.parse_statement(p, check_unused)!;
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.FOR_STMT, .for_stmt = { .for_tok = kw, .init = init, .cond = cond_node, .incr = incr, .body = maybe_body }
		}
	);
}

<* `break;` / `continue;`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_break_continue_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	bool is_break = p.is_at(tokenizer::TokenId.KEYWORD_BREAK);
	tokens::TokenIndex kw = p.tok_i;
	if (is_break && self.loop_depth == 0 && self.switch_depth == 0)
	{
		Diagnostic.BREAK_NOT_IN_LOOP_OR_SWITCH.@emit(p, kw)!;
	}
	if (!is_break && self.loop_depth == 0)
	{
		Diagnostic.CONTINUE_NOT_IN_LOOP.@emit(p, kw)!;
	}
	p.advance();
	if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	if (is_break) return p.tree.add_node(
		{
			.kind = tree::NodeKind.BREAK_STMT, .break_stmt = { .break_tok = kw }
		}
	);
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.CONTINUE_STMT, .continue_stmt = { .continue_tok = kw }
		}
	);
}

<* `goto label;` / `goto *expr;`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_goto_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex goto_tok = p.tok_i;
	p.advance();
	if (p.is_at(tokenizer::TokenId.ASTERISK))
	{
		p.advance();
		parser_result::Result? maybe_expr = self.expr(p, true);
		if (catch __fault = maybe_expr) return __fault~;
		parser_result::Result expr = maybe_expr;
		expr.lval_conversion(p);
		expr.save_value(p);
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		if (self.in_function && !self.has_computed_goto)
		{
			self.has_computed_goto = true; self.computed_goto_tok = goto_tok;
		}
		return p.tree.add_node(
			{
				.kind = tree::NodeKind.COMPUTED_GOTO_STMT, .computed_goto_stmt = { .goto_tok = goto_tok, .expr = expr.node }
			}
		);
	}
	if (!p.is_at(tokenizer::TokenId.IDENTIFIER))
	{
		p.expected_token_diag(tokenizer::TokenId.IDENTIFIER)!; return PARSING_FAILED~;
	}
	tokens::TokenIndex label_tok = p.tok_i;
	p.advance();
	if (self.in_function && !self.mark_label_used(p, label_tok)) self.gotos.push(label_tok);
	if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.GOTO_STMT, .goto_stmt = { .label_tok = label_tok }
		}
	);
}

<* `return [expr];`. Out of line so its locals only occupy the stack while this
 statement kind is being parsed, not at every nesting level. *>
fn type_store::NodeIndex? StatementParser.parse_return_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	tokens::TokenIndex kw = p.tok_i;
	p.advance();
	tokens::TokenIndex expr_tok = p.tok_i;
	parser_result::Result? maybe_expr = self.expr(p, true);
	if (catch __fault = maybe_expr)
	{
		if (__fault != parser::NO_EXPRESSION) return __fault~;
	}
	if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
	type_store::QualType ret_qt = self.has_function_context ? self.function_return_qt : type_store::INVALID;
	String function_name = self.has_function_context ? p.tree.tok_slice(self.function_name_tok) : "<unknown>";
	if (p.function_context.active && p.tree.attr_map.has_attribute(p.function_context.declaration, attribute::AttributeTag.NORETURN))
	{
		Diagnostic.INVALID_NORETURN.@emit(p, expr_tok, function_name)!;
	}
	bool ret_void = !ret_qt.is_invalid() && ret_qt.is(p.comp, type_store::TypeTag.VOID);
	if (@ok(maybe_expr))
	{
		parser_result::Result expr = maybe_expr!;
		if (self.has_function_context && !ret_qt.is_invalid())
		{
			if (ret_void)
			{
				if (!expr.qt.is(p.comp, type_store::TypeTag.VOID))
				{
					Diagnostic.VOID_FUNC_RETURNS_VALUE.@emit(p, expr_tok, function_name)!;
				}
			}
			else
			{
				type_store::QualType original_qt = expr.qt;
				if (expr.coerce_scalar(p, ret_qt, expr_tok, parser_result::CoercionContext.RETURN)!)
				{
					expr.save_value(p);
				}
				else
				{
					Diagnostic.INCOMPATIBLE_RETURN.@emit(p, expr_tok, p.fmt_qt(original_qt), p.fmt_qt(ret_qt))!;
				}
			}
		}
		return p.tree.add_node(
			{
				.kind = tree::NodeKind.RETURN_STMT, .return_stmt = {
					.return_tok = kw, .return_qt = ret_qt, .operand = tree::ReturnOperandKind.EXPR, .expr = expr.node,
				}
			}
		);
	}
	if (self.has_function_context && !ret_qt.is_invalid() && !ret_void)
	{
		Diagnostic.FUNC_SHOULD_RETURN.@emit(p, kw, function_name)!;
	}
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.RETURN_STMT, .return_stmt = {
				.return_tok = kw, .return_qt = ret_qt, .operand = tree::ReturnOperandKind.NONE,
			}
		}
	);
}

enum NoreturnKind : char
{
	NO, YES, COMPLEX
}

fn NoreturnKind StatementParser.node_is_noreturn(&self, parser::Parser* p, type_store::NodeIndex index)
{
	tree::Node node = index.get(&p.tree);
	switch (node.kind)
	{
		case tree::NodeKind.BREAK_STMT:
		case tree::NodeKind.CONTINUE_STMT:
		case tree::NodeKind.RETURN_STMT:
			return NoreturnKind.YES;
		case tree::NodeKind.IF_STMT:
			{
				NoreturnKind then_kind = self.node_is_noreturn(p, node.if_stmt.then_body);
				NoreturnKind else_kind = node.if_stmt.else_body.is_null() ? NoreturnKind.NO : self.node_is_noreturn(p, node.if_stmt.else_body.unwrap());
				if (then_kind == NoreturnKind.COMPLEX || else_kind == NoreturnKind.COMPLEX) return NoreturnKind.COMPLEX;
				if (then_kind == NoreturnKind.YES && else_kind == NoreturnKind.YES) return NoreturnKind.YES;
				return NoreturnKind.NO;
			}
		case tree::NodeKind.COMPOUND_STMT:
			{
				foreach (body_stmt : node.compound_stmt.body)
				{
					NoreturnKind kind = self.node_is_noreturn(p, body_stmt);
					if (kind != NoreturnKind.NO) return kind;
				}
				return NoreturnKind.NO;
			}
		case tree::NodeKind.LABELED_STMT:
			return self.node_is_noreturn(p, node.labeled_stmt.body);
		case tree::NodeKind.DEFAULT_STMT:
			return self.node_is_noreturn(p, node.default_stmt.body);
		case tree::NodeKind.WHILE_STMT:
		case tree::NodeKind.DO_WHILE_STMT:
		case tree::NodeKind.FOR_STMT:
		case tree::NodeKind.SWITCH_STMT:
		case tree::NodeKind.GOTO_STMT:
		case tree::NodeKind.COMPUTED_GOTO_STMT:
			return NoreturnKind.COMPLEX;
		default: return NoreturnKind.NO;
	}
}

<* Only parser grammar failures can be recovered at a
 compound-item boundary. Fatal diagnostics, allocation failures and absent hooks
 propagate. *>
fn bool recoverable_statement_item_fault(fault f)
{
	if (f == compilation::FATAL_ERROR || f == mem::OUT_OF_MEMORY || f == parser::HOOK_ABSENT) return false;
	return f == parser::PARSING_FAILED || f == parser_builtin::PARSING_FAILED ||
	f == parser_declaration::PARSING_FAILED || f == parser_declarator::PARSING_FAILED ||
	f == PARSING_FAILED || f == text_literal::PARSING_FAILED ||
	f == parser::NO_EXPRESSION;
}

<* Skip a failed compound item from the parser's failure position. A true
 result means an unmatched closing brace was consumed and closes this block. *>
fn bool StatementParser.recover_compound_item(&self, parser::Parser* p, tokens::TokenIndex item_start)
{
	uint parens = 0;
	uint braces = 0;
	uint brackets = 0;
	for (usz i = (usz)item_start; i < (usz)p.tok_i; i++)
	{
		tokenizer::TokenId id = p.tree.tokens[i].id;
		switch (id)
		{
			case tokenizer::TokenId.L_PAREN: parens++;
			case tokenizer::TokenId.R_PAREN: if (parens > 0) parens--;
			case tokenizer::TokenId.L_BRACE: braces++;
			case tokenizer::TokenId.R_BRACE: if (braces > 0) braces--;
			case tokenizer::TokenId.L_BRACKET: brackets++;
			case tokenizer::TokenId.R_BRACKET: if (brackets > 0) brackets--;
			default: {}
		}
	}
	// A failed item can consume its own terminating ';' at depth zero (for
	// example a declaration hook). The cursor is then already at the next item,
	// so stop instead of discarding that item.
	if (p.tok_i > item_start && parens == 0 && braces == 0 && brackets == 0 &&
		p.tree.tokens[(usz)(p.tok_i - 1)].id == tokenizer::TokenId.SEMICOLON) return false;
	while (!p.at_eof())
	{
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		bool at_item_boundary = parens == 0 && braces == 0 && brackets == 0;
		if (at_item_boundary && p.tok_i != item_start && id.starts_compound_item()) return false;
		if (id == tokenizer::TokenId.R_BRACE && parens == 0 && braces == 0 && brackets == 0)
		{
			p.advance();
			return true;
		}
		// Leave pragmas for parse_body's between-item replay, matching Zig's
		// skipToPragmaSentinel followed by `p.pragma()`.
		if (id == tokenizer::TokenId.KEYWORD_PRAGMA) return false;
		p.advance();
		switch (id)
		{
			case tokenizer::TokenId.L_PAREN: parens++;
			case tokenizer::TokenId.R_PAREN: if (parens > 0) parens--;
			case tokenizer::TokenId.L_BRACE: braces++;
			case tokenizer::TokenId.R_BRACE: if (braces > 0) braces--;
			case tokenizer::TokenId.L_BRACKET: brackets++;
			case tokenizer::TokenId.R_BRACKET: if (brackets > 0) brackets--;
			case tokenizer::TokenId.SEMICOLON:
				if (parens == 0 && braces == 0 && brackets == 0) return false;
			default: {}
		}
	}
	return false;
}

<* Parse a compound statement, returning null when the next token is not `{`.
 Non-function compounds push exactly one lexical scope, and defer guarantees
 it is popped on both successful parsing and error unwinding. *>
fn type_store::NodeIndex? StatementParser.parse_body(&self, parser::Parser* p, bool is_fn_body = false)
{
	if (!p.is_at(tokenizer::TokenId.L_BRACE)) return tree::NULL_NODE~;
	// In the frontend callback, GNU statement expressions enter the body at
	// the '{' immediately following their opening '('. Their final top-level
	// expression is the value of the statement expression, so defer checks for
	// earlier items until the next item begins.
	bool is_statement_expression = !is_fn_body && p.tok_i > 0 &&
	p.tree.tokens[(usz)(p.tok_i - 1)].id == tokenizer::TokenId.L_PAREN;
	bool body_parsed = false;
	parser::IAddressOfLabel old_address_of_label = p.address_of_label;
	uint old_label_count = self.label_count;
	if (is_fn_body) self.begin_fn_body(p);
	// Keep function-state validation and cleanup in parse_body's scope. A defer
	// nested in the initialization branch would run before the body is parsed.
	defer if (is_fn_body) self.end_fn_body(p, old_address_of_label, old_label_count, body_parsed);
	tokens::TokenIndex opener = p.tok_i;
	p.advance();
	if (!is_fn_body) p.push_scope();
	defer if (!is_fn_body) p.pop_scope();
	list::List{type_store::NodeIndex} body;
	body.init(p.comp.gpa);
	defer body.free();
	bool has_noreturn = false;
	tokens::TokenIndex noreturn_tok;
	uint noreturn_label_count = 0;
	type_store::NodeOptIndex previous_stmt = type_store::NODE_NULL;
	uint previous_stmt_errors = p.diagnostics.errors;
	bool recovered_closing_brace = false;
	while (!p.at_eof() && !p.is_at(tokenizer::TokenId.R_BRACE))
	{
		bool? replay_result = p.replay_pragma();
		fault pragma_fault = @catch(replay_result);
		if (pragma_fault) return pragma_fault~;
		if (try handled = replay_result)
		{
			if (handled) continue;
		}
		if (is_statement_expression && !previous_stmt.is_null())
		{
			parser_result::diagnose_unused_value(p, previous_stmt.unwrap(), previous_stmt_errors)!;
			previous_stmt = type_store::NODE_NULL;
		}
		previous_stmt_errors = p.diagnostics.errors;
		tokens::TokenIndex item_start = p.tok_i;
		type_store::NodeIndex? maybe_stmt = self.parse_statement(p, !is_statement_expression);
		if (catch __fault = maybe_stmt)
		{
			previous_stmt = type_store::NODE_NULL;
			if (self.recover_body_item(p, __fault, previous_stmt_errors, item_start)!)
			{
				recovered_closing_brace = true;
				break;
			}
			continue;
		}
		if (is_statement_expression) previous_stmt = maybe_stmt.pack();
		body.push(maybe_stmt);
		self.track_noreturn(p, maybe_stmt, &has_noreturn, &noreturn_tok, &noreturn_label_count);
	}
	self.finish_body(p, &body, opener, recovered_closing_brace, has_noreturn, noreturn_tok, noreturn_label_count, is_fn_body)!;
	if (is_fn_body) body_parsed = true;
	return p.tree.add_node(
		{
			.kind = tree::NodeKind.COMPOUND_STMT, .compound_stmt = {
				.l_brace_tok = opener, .body = body.array_view(),
		}
	}
	);
}

<* Function-body state set up by `parse_body`. The `parse_body` helpers are out
 of line so `parse_body`, live at every block nesting level, stays small. *>
fn void StatementParser.begin_fn_body(&self, parser::Parser* p) @noinline
{
	p.address_of_label = self;
	self.in_function = true;
	self.label_count = 0;
	self.function_has_address_of_label = false;
	self.has_computed_goto = false;
	self.computed_goto_tok = 0;
	self.labels.init(p.comp.gpa);
	self.label_nodes.init(p.comp.gpa);
	self.gotos.init(p.comp.gpa);
}

<* Function-body validation and cleanup, run by `parse_body`'s defer. *>
fn void StatementParser.end_fn_body(&self, parser::Parser* p, parser::IAddressOfLabel old_address_of_label, uint old_label_count, bool body_parsed) @noinline
{
	p.address_of_label = old_address_of_label;
	self.label_count = old_label_count;
	foreach (goto_tok : self.gotos)
	{
		if (!self.mark_label_used(p, goto_tok))
		{
			(void)Diagnostic.UNDECLARED_LABEL.@emit(p, goto_tok, p.tree.tok_slice(goto_tok));
		}
	}
	if (body_parsed && self.has_computed_goto && !self.function_has_address_of_label)
	{
		(void)Diagnostic.INVALID_COMPUTED_GOTO.@emit(p, self.computed_goto_tok);
	}
	self.labels.free();
	self.label_nodes.free();
	self.gotos.free();
	self.in_function = false;
	self.has_computed_goto = false;
	self.function_has_address_of_label = false;
}

<* Error recovery for a failed compound-statement item. Returns true when
 recovery consumed the closing brace. *>
fn bool? StatementParser.recover_body_item(&self, parser::Parser* p, fault item_fault, uint previous_stmt_errors, tokens::TokenIndex item_start) @noinline
{
	if (!recoverable_statement_item_fault(item_fault)) return item_fault~;
	// A parser callback can reject an item without producing a diagnostic
	// (for example, when a required statement is missing before `}`).
	// Match Zig's stmt diagnostic while keeping existing, more specific
	// errors from being duplicated.
	if (p.diagnostics.errors == previous_stmt_errors)
	{
		Diagnostic.EXPECTED_STMT.@emit(p, p.diag_index())!;
	}
	return self.recover_compound_item(p, item_start);
}

<* Track the first noreturn statement for the unreachable-code warning. *>
fn void StatementParser.track_noreturn(&self, parser::Parser* p, type_store::NodeIndex stmt_index, bool* has_noreturn, tokens::TokenIndex* noreturn_tok, uint* noreturn_label_count) @noinline
{
	tree::Node stmt = stmt_index.get(&p.tree);
	if (!*has_noreturn && self.node_is_noreturn(p, stmt_index) == NoreturnKind.YES)
	{
		*has_noreturn = true;
		*noreturn_tok = p.tok_i;
		*noreturn_label_count = self.label_count;
	}
	switch (stmt.kind)
	{
		case tree::NodeKind.CASE_STMT:
		case tree::NodeKind.DEFAULT_STMT:
		case tree::NodeKind.LABELED_STMT:
			*has_noreturn = false;
		default: {}
	}
}

<* Closing brace, unreachable-code warning and the implicit return of a function body. *>
fn void? StatementParser.finish_body(&self, parser::Parser* p, list::List{type_store::NodeIndex}* body, tokens::TokenIndex opener,
	bool recovered_closing_brace, bool has_noreturn, tokens::TokenIndex noreturn_tok, uint noreturn_label_count, bool is_fn_body) @noinline
{
	tokens::TokenIndex r_brace = recovered_closing_brace ? p.tok_i - 1 : p.tok_i;
	if (!recovered_closing_brace)
	{
		if (catch p.expect_closing(tokenizer::TokenId.R_BRACE, opener)) return PARSING_FAILED~;
	}
	if (has_noreturn && noreturn_tok != r_brace && noreturn_label_count == self.label_count)
	{
		Diagnostic.UNREACHABLE_CODE.@emit(p, noreturn_tok)!;
	}
	if (is_fn_body)
	{
		NoreturnKind last_noreturn = body.len() == 0 ? NoreturnKind.NO : self.node_is_noreturn(p, (*body)[body.len() - 1]);
		type_store::QualType ret_qt = self.has_function_context ? self.function_return_qt : type_store::INVALID;
		if (last_noreturn != NoreturnKind.YES && !ret_qt.is_invalid())
		{
			bool return_zero = false;
			if (last_noreturn == NoreturnKind.NO && !ret_qt.is(p.comp, type_store::TypeTag.VOID) &&
			!ret_qt.is(p.comp, type_store::TypeTag.FUNC) && !ret_qt.is(p.comp, type_store::TypeTag.ARRAY))
			{
				if (p.tree.tok_slice(self.function_name_tok) == "main")
				{
					type_store::Type? maybe_int = ret_qt.get(p.comp, type_store::TypeTag.INT);
					if (@ok(maybe_int) && maybe_int!.int_ty == type_store::TypeInt.INT) return_zero = true;
				}
				if (!return_zero)
				{
					Diagnostic.FUNC_DOES_NOT_RETURN.@emit(p, r_brace,
						p.tree.tok_slice(self.function_name_tok))!;
				}
			}
			body.push(p.tree.add_node(
					{
						.kind = tree::NodeKind.RETURN_STMT, .return_stmt = {
							.return_tok = r_brace, .return_qt = ret_qt,
							.operand = tree::ReturnOperandKind.IMPLICIT, .implicit_value = return_zero,
						}
					}
				));
		}
	}
}

<* A local declaration or an expression statement. *>
fn type_store::NodeIndex? StatementParser.parse_declaration_or_expression_statement(&self, parser::Parser* p, bool check_unused) @noinline
{
	if (self.has_local_declarations())
	{
		type_store::NodeIndex? maybe_decl = self.local_declaration(p);
		if (catch __fault = maybe_decl)
		{
			// NULL_NODE: no declaration specifier here, so parse an expression statement.
			if (__fault != tree::NULL_NODE) return __fault~;
		}
		else
		{
			return maybe_decl;
		}
	}
	uint expr_prev_errors = p.diagnostics.errors;
	parser_result::Result? maybe_expr = self.expr(p, true);
	if (catch __fault = maybe_expr)
	{
		if (__fault != parser::NO_EXPRESSION) return __fault~;
	}
	if (@ok(maybe_expr))
	{
		if (catch p.expect(tokenizer::TokenId.SEMICOLON)) return PARSING_FAILED~;
		parser_result::Result expr = maybe_expr!;
		if (check_unused) parser_result::diagnose_unused_value(p, expr.node, expr_prev_errors)!;
		expr.lval_conversion(p);
		expr.save_value(p);
		return expr.node;
	}
	Diagnostic.EXPECTED_STMT.@emit(p, p.diag_index())!;
	return PARSING_FAILED~;
}

<* Commit the leading attributes of a parsed statement (declarators for a
 declaration statement, the statement node otherwise). *>
fn void? StatementParser.apply_statement_attributes(&self, parser::Parser* p, parser_attribute::AttributeBuffer* buffer, attribute_wip::Wip* wip, type_store::NodeIndex stmt) @noinline
{
	tree::Node stmt_node = stmt.get(&p.tree);
	if (stmt_node.kind == tree::NodeKind.DECL_STMT)
	{
		// Leading attributes on a declaration statement belong to each
		// declarator, not to the DECL_STMT wrapper. The declaration grammar
		// consumes them before it builds the declarators; custom declaration
		// callbacks retain the older post-parse bridge.
		if (!self.prefix_declaration_attributes_consumed)
		{
			self.apply_prefix_declaration_attrs(p, buffer, wip, stmt)!;
		}
	}
	else
	{
		append_statement_attributes(p, buffer, wip)!;
		// A label can carry GNU attributes between its colon and body. Preserve
		// those refs while the leading statement attributes are committed here.
		list::List{attribute_map::AttrRef} previous_attrs;
		previous_attrs.init(p.comp.gpa);
		defer previous_attrs.free();
		foreach (ref : p.tree.attr_map.attrs(stmt.pack())) previous_attrs.push(ref);
		wip.apply_stmt_attrs(p, stmt, self.switch_depth > 0)!;
		if (previous_attrs.len() > 0)
		{
			list::List{attribute_map::AttrRef} combined;
			combined.init(p.comp.gpa);
			defer combined.free();
			combined.push_all(wip.applied.array_view());
			combined.push_all(previous_attrs.array_view());
			p.tree.attr_map.set_decl_attrs(stmt, combined.array_view());
		}
	}
}
