// Specialized expression builtins (`__builtin_offsetof`, `__builtin_choose_expr`,
// `__builtin_va_arg`, ...). `unary_expr` tries `parse_builtin_primary` on every
// identifier; operands are parsed with the Parser's own expression grammar.
module aro::frontend::c::parser;
import aro::frontend::c::parser_result, aro::frontend::c::tree, aro::frontend::c::tokens, aro::frontend::c::tokenizer;
import aro::frontend::c::type_store, aro::frontend::c::value, aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::lang_opts;
import aro::frontend::c::builtins, aro::frontend::c::builtin_defs::common;
import aro::string_interner;
import aro::bigint;
import std::collections::list;
import std::core::dstring;

<* Builtin primary expression. It resolves the source spelling through the
   normal builtin cache, dispatches only the supported common tags, and returns
   NO_EXPRESSION for every other identifier so ordinary primary-expression
   parsing takes over. *>
fn parser_result::Result? Parser.parse_builtin_primary(&self, bool eval)
{
	parser::Parser* p = self;
	String spelling = p.tree.tok_slice(p.tok_i);
	builtins::Expanded? maybe_expanded = p.comp.builtins.get_or_create(p.comp, spelling);
	if (catch maybe_expanded) return parser::NO_EXPRESSION~;
	builtins::Expanded expanded = maybe_expanded;
	tokens::TokenIndex builtin_tok = p.tok_i;
	switch (expanded.tag)
	{
		case common::TAG___BUILTIN_BIT_CAST:
			p.advance();
			return p.builtin_bit_cast(builtin_tok, eval);
		case common::TAG___BUILTIN_SHUFFLEVECTOR:
			p.advance();
			return p.builtin_shufflevector(builtin_tok, eval);
		case common::TAG___BUILTIN_CONVERTVECTOR:
			p.advance();
			return p.builtin_convertvector(builtin_tok, eval);
		case common::TAG___BUILTIN_CHOOSE_EXPR:
			p.advance();
			return p.builtin_choose_expr(eval);
		case common::TAG___BUILTIN_VA_ARG:
			p.advance();
			return p.builtin_va_arg(builtin_tok, eval);
		case common::TAG___BUILTIN_VA_ARG_PACK:
			p.advance();
			return p.builtin_va_arg_pack(builtin_tok);
		case common::TAG___BUILTIN_VA_ARG_PACK_LEN:
			p.advance();
			return p.builtin_va_arg_pack_len(builtin_tok);
		case common::TAG___BUILTIN_OFFSETOF:
			p.advance();
			return p.builtin_offsetof(builtin_tok, false, eval);
		case common::TAG___BUILTIN_BITOFFSETOF:
			p.advance();
			return p.builtin_offsetof(builtin_tok, true, eval);
		case common::TAG___BUILTIN_TYPES_COMPATIBLE_P:
			p.advance();
			return p.builtin_types_compatible(builtin_tok);
		default:
			return parser::NO_EXPRESSION~;
	}
}

<* Recover an offsetof parse to the matching closing parenthesis. *>
fn void Parser.recover_offsetof(&self)
{
	parser::Parser* p = self;
	uint nesting = 0;
	while (!p.at_eof())
	{
		tokenizer::TokenId id = p.tree.tokens[(usz)p.tok_i].id;
		if (id == tokenizer::TokenId.R_PAREN)
		{
			if (nesting == 0)
			{
				p.advance(); return;
			}
			nesting--;
		}
		else if (id == tokenizer::TokenId.L_PAREN || id == tokenizer::TokenId.L_BRACE || id == tokenizer::TokenId.L_BRACKET)
		{
			nesting++;
		}
		else if ((id == tokenizer::TokenId.R_BRACE || id == tokenizer::TokenId.R_BRACKET) && nesting > 0)
		{
			nesting--;
		}
		p.advance();
	}
}

fn bool add_offset_bits(long* offset_bits, ulong delta) @local
{
	if (delta > (ulong)long::max) return false;
	int128 total = (int128)*offset_bits + (int128)delta;
	if (total < (int128)long::min || total > (int128)long::max) return false;
	*offset_bits = (long)total;
	return true;
}

fn bool add_array_offset_bits(long* offset_bits, ulong stride_bits, long index) @local
{
	int128 delta = (int128)stride_bits * (int128)index;
	if (delta < (int128)long::min || delta > (int128)long::max) return false;
	int128 total = (int128)*offset_bits + delta;
	if (total < (int128)long::min || total > (int128)long::max) return false;
	*offset_bits = (long)total;
	return true;
}

fn String offsetof_index_text(parser_result::Result index, parser::Parser* p) @local
{
	DString text;
	text.init(tmem);
	(void)index.val.print(index.qt, p.comp, &text)!!;
	return text.str_view();
}

fn void? Parser.check_offsetof_array_bounds(&self, parser_result::Result index,
	type_store::QualType array_qt, type_store::NodeIndex array_node, tokens::TokenIndex bracket_tok)
{
	parser::Parser* p = self;
	if (!index.qt.is_real_int(p.comp) || index.val.is_none()) return;
	if (try len = array_qt.array_len(p.comp))
	{
		if (len == 0) return;
		if (len == 1)
		{
			tree::Node array_expr = array_node.get(&p.tree);
			if (array_expr.kind == tree::NodeKind.MEMBER_ACCESS_EXPR || array_expr.kind == tree::NodeKind.MEMBER_ACCESS_PTR_EXPR)
			{
				type_store::QualType base_qt = array_expr.member_access.base.qt(&p.tree);
				if (try pointer = base_qt.get(p.comp, type_store::TypeTag.POINTER)) base_qt = pointer.pointer.child;
				if (try record = base_qt.get_record(p.comp))
				{
					if ((usz)array_expr.member_access.member_index + 1 == record.fields.len)
					{
						if (!index.val.is_zero(p.comp))
						{
							Diagnostic.OLD_STYLE_FLEXIBLE_STRUCT.@emit(p, bracket_tok, offsetof_index_text(index, p))!;
						}
						return;
					}
				}
			}
		}
		ulong index_int = index.val.to_u64(p.comp) ?? ulong::max;
		if (index.qt.signedness(p.comp) == bigint::Signedness.UNSIGNED)
		{
			if (index_int >= len)
			{
				Diagnostic.ARRAY_AFTER.@emit(p, bracket_tok,
					p.fmt_value(index.val, index.qt))!;
			}
		}
		else if (value::compare(index.val, bigint::CompareOperator.LT, value::ZERO, p.comp))
		{
			Diagnostic.ARRAY_BEFORE.@emit(p, bracket_tok,
				p.fmt_value(index.val, index.qt))!;
		}
		else if (index_int >= len)
		{
			Diagnostic.ARRAY_AFTER.@emit(p, bracket_tok,
				p.fmt_value(index.val, index.qt))!;
		}
	}
}

<* Resolve a named field, including fields promoted through anonymous records.
   The returned access chain mirrors fieldAccessExtra in Parser.zig. *>
fn bool Parser.find_offsetof_field(&self, type_store::Record record,
	type_store::NodeIndex base, string_interner::StringId target_name, tokens::TokenIndex access_tok,
	type_store::NodeIndex* out_node, type_store::QualType* out_qt, ulong* out_offset_bits)
{
	parser::Parser* p = self;
	for (usz i = 0; i < record.fields.len; i++)
	{
		type_store::RecordField field = record.fields[i];
		if (field.name_tok == (type_store::TokenIndex)0)
		{
			if (try nested_record = field.qt.get_record(p.comp))
			{
				if (nested_record.has_field(p.comp, target_name))
				{
					type_store::NodeIndex anonymous_access = p.tree.add_node(
						{
							.kind = tree::NodeKind.MEMBER_ACCESS_EXPR,
							.member_access = { .qt = field.qt, .base = base, .access_tok = access_tok, .member_index = (uint)i }
					}
					);
					if (p.find_offsetof_field(nested_record, anonymous_access, target_name, access_tok,
							out_node, out_qt, out_offset_bits))
					{
						*out_offset_bits += field.layout.offset_bits;
						return true;
					}
				}
			}
		}
		if (field.name == target_name)
		{
			*out_node = p.tree.add_node(
				{
					.kind = tree::NodeKind.MEMBER_ACCESS_EXPR,
					.member_access = { .qt = field.qt, .base = base, .access_tok = access_tok, .member_index = (uint)i }
			}
			);
			*out_qt = field.qt;
			*out_offset_bits = field.layout.offset_bits;
			return true;
		}
	}
	return false;
}

<* __builtin_bit_cast(type-name, expression). *>
fn parser_result::Result? Parser.builtin_bit_cast(&self, tokens::TokenIndex builtin_tok, bool eval = true)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	type_store::QualType dest = p.parse_typed_type_name() ?? type_store::INVALID;
	if (dest.is_invalid()) return PARSING_FAILED~;
	if (catch p.expect(tokenizer::TokenId.COMMA)) return PARSING_FAILED~;
	parser_result::Result operand = p.assign_expr(eval)!;
	operand.lval_conversion(p);
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	operand.save_value(p);
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.CAST, .cast = {
				.l_paren = builtin_tok, .kind = tree::CastKind.BITCAST, .operand = operand.node,
				.qt = dest, .implicit = false,
			}
		}
	);
	return { .node = node, .qt = dest, .val = value::NONE };
}

<* __builtin_shufflevector(lhs, rhs, integer-constant-index...). *>
fn parser_result::Result? Parser.builtin_shufflevector(&self, tokens::TokenIndex builtin_tok, bool eval = true)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	tokens::TokenIndex lhs_tok = p.tok_i;
	parser_result::Result lhs = p.assign_expr(eval)!;
	lhs.value_conversion(p);
	if (catch p.expect(tokenizer::TokenId.COMMA)) return PARSING_FAILED~;
	tokens::TokenIndex rhs_tok = p.tok_i;
	parser_result::Result rhs = p.assign_expr(eval)!;
	rhs.value_conversion(p);
	value::Value negative_one = value::int_i64(-1, p.comp);
	List{type_store::NodeIndex} indexes;
	indexes.init(p.comp.gpa);
	defer indexes.free();
	while (p.is_at(tokenizer::TokenId.COMMA))
	{
		p.advance();
		tokens::TokenIndex index_tok = p.tok_i;
		parser_result::Result index = p.integer_const_expr(eval, parser::ConstDeclFoldingMode.GNU_FOLDING_EXTENSION)!;
		if (!index.qt.is_int(p.comp) || index.val.is_none())
		{
			Diagnostic.EXPECTED_INTEGER_CONSTANT_EXPR.@emit(p, index_tok)!;
			return PARSING_FAILED~;
		}
		if (value::compare(index.val, bigint::CompareOperator.LT, negative_one, p.comp))
		{
			Diagnostic.SHUFFLEVECTOR_NEGATIVE_INDEX.@emit(p, index_tok)!;
		}
		else if (try lhs_vec = lhs.qt.get(p.comp, type_store::TypeTag.VECTOR))
		{
			if (try rhs_vec = rhs.qt.get(p.comp, type_store::TypeTag.VECTOR))
			{
				ulong max_index = (ulong)lhs_vec.vector.len + (ulong)rhs_vec.vector.len;
				if (value::compare(index.val, bigint::CompareOperator.GTE, value::int_u64(max_index, p.comp), p.comp))
				{
					Diagnostic.SHUFFLEVECTOR_INDEX_TOO_BIG.@emit(p, index_tok)!;
				}
			}
		}
		indexes.push(index.node);
		index.save_value(p);
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	type_store::QualType result_qt = type_store::INVALID;
	if (!lhs.qt.is_invalid() && !lhs.qt.is(p.comp, type_store::TypeTag.VECTOR))
	{
		Diagnostic.SHUFFLEVECTOR_ARG.@emit(p, lhs_tok, "first")!;
	}
	else if (!rhs.qt.is_invalid() && !rhs.qt.is(p.comp, type_store::TypeTag.VECTOR))
	{
		Diagnostic.SHUFFLEVECTOR_ARG.@emit(p, rhs_tok, "second")!;
	}
	else if (!lhs.qt.is_invalid() && !rhs.qt.is_invalid() && !lhs.qt.eql(rhs.qt, p.comp))
	{
		Diagnostic.SHUFFLEVECTOR_SAME_TYPE.@emit(p, builtin_tok)!;
	}
	else if (indexes.len() == 0)
	{
		result_qt = lhs.qt;
	}
	else if (try vec = lhs.qt.get(p.comp, type_store::TypeTag.VECTOR))
	{
		result_qt = p.comp.type_store.put(type_store::type_vector(vec.vector.elem, (uint)indexes.len()));
	}
	lhs.save_value(p);
	rhs.save_value(p);
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_SHUFFLEVECTOR, .shufflevector = {
				.builtin_tok = builtin_tok, .qt = result_qt, .lhs = lhs.node, .rhs = rhs.node, .indexes = indexes.array_view(),
		}
	}
	);
	return { .node = node, .qt = result_qt, .val = value::NONE };
}

<* __builtin_va_arg(list, type-name). *>
fn parser_result::Result? Parser.builtin_va_arg(&self, tokens::TokenIndex builtin_tok, bool eval = true)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	tokens::TokenIndex list_tok = p.tok_i;
	parser_result::Result va_list = p.assign_expr(eval)!;
	va_list.lval_conversion(p);
	if (catch p.expect(tokenizer::TokenId.COMMA)) return PARSING_FAILED~;
	type_store::QualType result_qt = p.parse_typed_type_name() ?? type_store::INVALID;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	if (!va_list.qt.eql(p.comp.type_store.va_list, p.comp))
	{
		Diagnostic.INCOMPATIBLE_VA_ARG.@emit(p, list_tok, p.fmt_qt(va_list.qt))!;
		return PARSING_FAILED~;
	}
	va_list.save_value(p);
	type_store::NodeIndex[1] args = { va_list.node };
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_CALL_EXPR, .builtin_call = {
				.builtin_tok = builtin_tok, .qt = result_qt, .args = args[0 : 1],
			}
		}
	);
	return { .node = node, .qt = result_qt, .val = value::NONE };
}

<* __builtin_va_arg_pack() and __builtin_va_arg_pack_len(). *>
fn parser_result::Result? Parser.builtin_va_arg_pack(&self, tokens::TokenIndex builtin_tok)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	bool valid_function = p.check_va_pack_function(builtin_tok, "__builtin_va_arg_pack")!;
	type_store::QualType result_qt = type_store::INVALID;
	if (valid_function)
	{
		parser::VaArgPackCallContext call = p.va_arg_pack_call_context();
		if (!call.active)
		{
			Diagnostic.VA_PACK_NON_CALL.@emit(p, builtin_tok)!;
		}
		else if (!call.variadic)
		{
			Diagnostic.VA_PACK_NON_VARIADIC_CALL.@emit(p, builtin_tok)!;
		}
		else if (call.typed)
		{
			Diagnostic.VA_PACK_NON_VARIADIC_ARG.@emit(p, builtin_tok)!;
		}
		else
		{
			result_qt = type_store::VOID;
		}
	}
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_VA_ARG_PACK, .va_arg_pack = { .builtin_tok = builtin_tok }
		}
	);
	return { .node = node, .qt = result_qt, .val = value::NONE };
}

fn parser_result::Result? Parser.builtin_va_arg_pack_len(&self, tokens::TokenIndex builtin_tok)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	p.check_va_pack_function(builtin_tok, "__builtin_va_arg_pack_len")!;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_VA_ARG_PACK_LEN, .va_arg_pack = { .builtin_tok = builtin_tok }
		}
	);
	return { .node = node, .qt = type_store::INT, .val = value::NONE };
}

<* __builtin_offsetof / __builtin_bitoffsetof with member and array designators. *>
fn parser_result::Result? Parser.builtin_offsetof(&self, tokens::TokenIndex builtin_tok, bool bits = false, bool eval = true)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	tokens::TokenIndex type_tok = p.tok_i;
	type_store::QualType base_qt = p.parse_typed_type_name() ?? type_store::INVALID;
	if (base_qt.is_invalid())
	{
		p.recover_offsetof(); return PARSING_FAILED~;
	}
	type_store::Record record;
	if (try found_record = base_qt.get_record(p.comp))
	{
		record = found_record;
	}
	else
	{
		Diagnostic.OFFSETOF_TY.@emit(p, type_tok, p.fmt_qt(base_qt))!;
		p.recover_offsetof();
		return PARSING_FAILED~;
	}
	if (!record.has_layout)
	{
		Diagnostic.OFFSETOF_INCOMPLETE.@emit(p, type_tok, p.fmt_qt(base_qt))!;
		p.recover_offsetof();
		return PARSING_FAILED~;
	}
	if (catch p.expect(tokenizer::TokenId.COMMA))
	{
		p.recover_offsetof(); return PARSING_FAILED~;
	}
	if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
	{
		Diagnostic.EXPECTED_IDENTIFIER.@emit(p, p.tok_i)!;
		p.recover_offsetof();
		return PARSING_FAILED~;
	}
	tokens::TokenIndex initial_name_tok = p.tok_i;
	string_interner::StringId initial_name = p.comp.intern_string(p.tree.tok_slice(initial_name_tok));
	p.advance();
	type_store::NodeIndex access = p.tree.add_node(
		{
			.kind = tree::NodeKind.DEFAULT_INIT_EXPR, .default_init = { .last_tok = p.tok_i, .qt = base_qt }
		}
	);
	type_store::NodeIndex initial_field_access;
	type_store::QualType initial_field_qt;
	ulong initial_field_offset_bits;
	if (!p.find_offsetof_field(record, access, initial_name, builtin_tok,
			&initial_field_access, &initial_field_qt, &initial_field_offset_bits))
	{
		Diagnostic.NO_SUCH_MEMBER.@emit(p, initial_name_tok,
			p.tree.tok_slice(initial_name_tok), p.fmt_qt(base_qt))!;
		p.recover_offsetof();
		return PARSING_FAILED~;
	}
	type_store::QualType current_qt = base_qt;
	long offset_bits = 0;
	bool offset_known = true;
	if (!add_offset_bits(&offset_bits, initial_field_offset_bits)) offset_known = false;
	access = initial_field_access;
	current_qt = initial_field_qt;
	tokens::TokenIndex access_tok = builtin_tok;
	while (p.is_at(tokenizer::TokenId.PERIOD) || p.is_at(tokenizer::TokenId.L_BRACKET))
	{
		if (p.is_at(tokenizer::TokenId.PERIOD))
		{
			access_tok = p.tok_i;
			p.advance();
			if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
			{
				Diagnostic.EXPECTED_IDENTIFIER.@emit(p, p.tok_i)!;
				p.recover_offsetof();
				return PARSING_FAILED~;
			}
			if (try found_record = current_qt.get_record(p.comp))
			{
				record = found_record;
			}
			else
			{
				if (current_qt.is_invalid())
				{
					p.recover_offsetof(); return PARSING_FAILED~;
				}
				Diagnostic.OFFSETOF_TY.@emit(p, p.tok_i, p.fmt_qt(current_qt))!;
				p.recover_offsetof();
				return PARSING_FAILED~;
			}
			if (!record.has_layout)
			{
				Diagnostic.OFFSETOF_INCOMPLETE.@emit(p, p.tok_i, p.fmt_qt(current_qt))!;
				p.recover_offsetof();
				return PARSING_FAILED~;
			}
		}
		if (p.is_at(tokenizer::TokenId.L_BRACKET))
		{
			tokens::TokenIndex bracket_tok = p.tok_i;
			p.advance();
			parser_result::Result? maybe_index = p.assign_expr(eval);
			if (catch caught_fault = maybe_index)
			{
				p.recover_offsetof(); return caught_fault~;
			}
			parser_result::Result index = maybe_index;
			if (catch p.expect(tokenizer::TokenId.R_BRACKET))
			{
				p.recover_offsetof(); return PARSING_FAILED~;
			}
			type_store::Type array_type;
			if (try found_array = current_qt.get(p.comp, type_store::TypeTag.ARRAY))
			{
				array_type = found_array;
			}
			else
			{
				// An invalid member type was already diagnosed (Zig: invalid -> ParsingFailed).
				if (current_qt.is_invalid())
				{
					p.recover_offsetof(); return PARSING_FAILED~;
				}
				Diagnostic.OFFSETOF_ARRAY.@emit(p, bracket_tok, p.fmt_qt(current_qt))!;
				p.recover_offsetof();
				return PARSING_FAILED~;
			}
			index.value_conversion(p);
			if (!index.qt.is_invalid() && !index.qt.is_real_int(p.comp))
			{
				Diagnostic.INVALID_INDEX.@emit(p, bracket_tok)!;
			}
			p.check_offsetof_array_bounds(index, current_qt, access, bracket_tok)!;
			if (try index_value = index.val.to_i64(p.comp))
			{
				if (!add_array_offset_bits(&offset_bits, array_type.array.elem.bit_sizeof(p.comp), index_value)) offset_known = false;
			}
			else
			{
				offset_known = false;
			}
			index.save_value(p);
			parser_result::Result array_base = { .node = access, .qt = current_qt, .val = value::NONE };
			array_base.lval_conversion(p);
			access = p.tree.add_node(
				{
					.kind = tree::NodeKind.ARRAY_ACCESS_EXPR, .array_access = {
						.l_bracket_tok = bracket_tok, .base = array_base.node, .index = index.node, .qt = array_type.array.elem,
					}
				}
			);
			current_qt = array_type.array.elem;
			continue;
		}
		if (!p.is_at(tokenizer::TokenId.IDENTIFIER) && !p.is_at(tokenizer::TokenId.EXTENDED_IDENTIFIER))
		{
			p.recover_offsetof();
			return PARSING_FAILED~;
		}
		tokens::TokenIndex name_tok = p.tok_i;
		String name = p.tree.tok_slice(name_tok);
		string_interner::StringId field_name = p.comp.intern_string(name);
		type_store::NodeIndex field_access;
		type_store::QualType field_qt;
		ulong field_offset_bits;
		if (!p.find_offsetof_field(record, access, field_name, access_tok,
				&field_access, &field_qt, &field_offset_bits))
		{
			Diagnostic.NO_SUCH_MEMBER.@emit(p, name_tok, name, p.fmt_qt(base_qt))!;
			p.recover_offsetof();
			return PARSING_FAILED~;
		}
		p.advance();
		if (!add_offset_bits(&offset_bits, field_offset_bits)) offset_known = false;
		access = field_access;
		current_qt = field_qt;
	}
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener))
	{
		p.recover_offsetof(); return PARSING_FAILED~;
	}
	long offset = bits ? offset_bits : offset_bits / 8;
	value::Value result_value = offset_known ? value::int_i64(offset, p.comp) : value::NONE;
	type_store::NodeIndex[1] args = { access };
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_CALL_EXPR, .builtin_call = {
				.builtin_tok = builtin_tok, .qt = p.comp.type_store.size, .args = args[0 : 1],
			}
		}
	);
	if (!result_value.is_none()) p.tree.set_value(node, result_value);
	return { .node = node, .qt = p.comp.type_store.size, .val = result_value };
}

<* __builtin_convertvector(expression, vector-type). *>
fn parser_result::Result? Parser.builtin_convertvector(&self, tokens::TokenIndex builtin_tok, bool eval = true)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	parser_result::Result operand = p.assign_expr(eval)!;
	operand.value_conversion(p);
	if (catch p.expect(tokenizer::TokenId.COMMA)) return PARSING_FAILED~;
	type_store::QualType dest = p.parse_typed_type_name() ?? type_store::INVALID;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	if (operand.qt.is_invalid() || dest.is_invalid())
	{
		dest = type_store::INVALID;
	}
	else
	{
		if (try operand_vec = operand.qt.get(p.comp, type_store::TypeTag.VECTOR))
		{
			if (try dest_vec = dest.get(p.comp, type_store::TypeTag.VECTOR))
			{
				if (operand_vec.vector.len != dest_vec.vector.len)
				{
					Diagnostic.CONVERTVECTOR_SIZE.@emit(p, builtin_tok)!;
				}
			}
			else
			{
				Diagnostic.CONVERTVECTOR_ARG.@emit(p, builtin_tok, "second")!;
			}
		}
		else
		{
			Diagnostic.CONVERTVECTOR_ARG.@emit(p, builtin_tok, "first")!;
		}
	}
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_CONVERTVECTOR, .convertvector = {
				.builtin_tok = builtin_tok, .dest_qt = dest, .operand = operand.node,
			}
		}
	);
	return { .node = node, .qt = dest, .val = value::NONE };
}

<* __builtin_types_compatible_p(type-name, type-name). *>
fn parser_result::Result? Parser.builtin_types_compatible(&self, tokens::TokenIndex builtin_tok)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	type_store::QualType lhs = p.parse_typed_type_name() ?? type_store::INVALID;
	if (catch p.expect(tokenizer::TokenId.COMMA)) return PARSING_FAILED~;
	type_store::QualType rhs = p.parse_typed_type_name() ?? type_store::INVALID;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	bool invalid = lhs.is_invalid() || rhs.is_invalid();
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_TYPES_COMPATIBLE_P, .types_compatible = {
				.builtin_tok = builtin_tok, .lhs = lhs, .rhs = rhs,
			}
		}
	);
	parser_result::Result result = { .node = node, .qt = invalid ? type_store::INVALID : type_store::INT, .val = value::NONE };
	if (!invalid)
	{
		result.val = value::from_bool(lhs.eql(rhs, p.comp));
		p.tree.set_value(node, result.val);
	}
	return result;
}

<* __builtin_choose_expr(constant, then-expression, else-expression). The
   unselected expression is still parsed with eval=false so it is type checked
   and represented in the tree without folding side effects. *>
fn parser_result::Result? Parser.builtin_choose_expr(&self, bool eval = true)
{
	parser::Parser* p = self;
	tokens::TokenIndex opener = p.tok_i;
	if (catch p.expect(tokenizer::TokenId.L_PAREN)) return PARSING_FAILED~;
	tokens::TokenIndex cond_tok = p.tok_i;
	parser_result::Result cond = p.integer_const_expr(eval, parser::ConstDeclFoldingMode.NO_CONST_DECL_FOLDING)!;
	if (cond.val.is_none())
	{
		Diagnostic.BUILTIN_CHOOSE_COND.@emit(p, cond_tok)!;
		return PARSING_FAILED~;
	}
	bool select_then = cond.val.to_bool(p.comp);
	if (catch p.expect(tokenizer::TokenId.COMMA)) return PARSING_FAILED~;
	parser_result::Result then_expr = p.assign_expr(eval && select_then)!;
	if (catch p.expect(tokenizer::TokenId.COMMA)) return PARSING_FAILED~;
	parser_result::Result else_expr = p.assign_expr(eval && !select_then)!;
	if (catch p.expect_closing(tokenizer::TokenId.R_PAREN, opener)) return PARSING_FAILED~;
	parser_result::Result selected = select_then ? then_expr : else_expr;
	type_store::NodeIndex node = p.tree.add_node(
		{
			.kind = tree::NodeKind.BUILTIN_CHOOSE_EXPR, .conditional = {
				.cond_tok = cond_tok, .qt = selected.qt, .cond = cond.node,
				.then_expr = then_expr.node, .else_expr = else_expr.node,
			}
		}
	);
	selected.node = node;
	if (!selected.val.is_none()) p.tree.set_value(node, selected.val);
	return selected;
}
