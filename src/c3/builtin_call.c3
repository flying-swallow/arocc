// Generic builtin call validation and constant evaluation, based on the
// generated signatures and Parser.zig's CallExpr path.
module aro::builtin_call;
import aro::builtin_defs::common, aro::builtin_eval, aro::builtins, aro::builtin_properties;
import aro::parser, aro::parser_diagnostics, aro::parser_postfix, aro::parser_result;
import aro::tree, aro::tokens, aro::type_store, aro::value;
import std::core::dstring;


fn bool is_overflow_builtin(builtin_properties::BuiltinTag tag)
{
	return tag == common::TAG___BUILTIN_ADD_OVERFLOW || tag == common::TAG___BUILTIN_SUB_OVERFLOW ||
		tag == common::TAG___BUILTIN_MUL_OVERFLOW;
}

fn bool has_single_custom_arg(builtin_properties::BuiltinTag tag)
{
	return tag == common::TAG___BUILTIN_CONSTANT_P || tag == common::TAG___BUILTIN_ISINF ||
		tag == common::TAG___BUILTIN_ISINF_SIGN || tag == common::TAG___BUILTIN_ISNAN;
}

fn parser_result::Result? arity_error(parser::Parser* p, type_store::NodeIndex[] args,
	tokens::TokenIndex l_paren, uint expected, bool variadic)
{
	tokens::TokenIndex tok = args.len < expected ? (p.tok_i > 0 ? p.tok_i - 1 : l_paren) : args[(usz)expected].tok(&p.tree);
	DString message;
	message.init(tmem);
	if (variadic) { message.appendf("expected at least %d argument(s) got %d", expected, args.len); }
	else { message.appendf("expected %d argument(s) got %d", expected, args.len); }
	p.emit_parser_diag(variadic ? parser_diagnostics::ParserDiag.EXPECTED_AT_LEAST_ARGUMENTS :
		parser_diagnostics::ParserDiag.EXPECTED_ARGUMENTS, message.str_view(), tok)!;
	return parser::PARSING_FAILED~;
}

fn void? check_overflow_arg_type(parser::Parser* p, type_store::NodeIndex[] args, uint index)
{
	type_store::QualType qt = args[(usz)index].qt(&p.tree);
	tokens::TokenIndex tok = args[(usz)index].tok(&p.tree);
	if (index < 2)
	{
		if (!qt.is_real_int(p.comp))
		{
			p.err(parser_diagnostics::ParserDiag.OVERFLOW_BUILTIN_REQUIRES_INT, tok,
				p.fmt_qt(qt))!;
			return parser::PARSING_FAILED~;
		}
		return;
	}
	type_store::QualType child = type_store::INVALID;
	if (try ptr = qt.get(p.comp, type_store::TypeTag.POINTER)) child = ptr.pointer.child;
	if (child.is_invalid() || !child.is_real_int(p.comp) || child.is_const)
	{
		p.err(parser_diagnostics::ParserDiag.OVERFLOW_RESULT_REQUIRES_PTR, tok,
			p.fmt_qt(qt))!;
		return parser::PARSING_FAILED~;
	}
	return;
}

fn parser_result::Result? builtin_argument_type_error(parser::Parser* p, type_store::NodeIndex arg, type_store::QualType expected)
{
	p.err(parser_diagnostics::ParserDiag.INCOMPATIBLE_ARG, arg.tok(&p.tree), p.fmt_qt(arg.qt(&p.tree)), p.fmt_qt(expected))!;
	return parser::PARSING_FAILED~;
}

<* Validate calls for known builtins. Unknown names and custom-typecheck builtins
   without a ported call rule return NO_BUILTIN_CALL so the ordinary call path
   retains its existing behavior. *>
fn parser_result::Result? dispatch(void* context, parser::Parser* p,
	type_store::NodeIndex callee, tokens::TokenIndex l_paren, type_store::NodeIndex[] args, bool eval)
{
	tree::Node callee_node = callee.get(&p.tree);
	if (callee_node.kind != tree::NodeKind.BUILTIN_REF) return parser_postfix::NO_BUILTIN_CALL~;
	tokens::TokenIndex builtin_tok = callee_node.builtin_ref.name_tok;
	String name = p.tree.tok_slice(builtin_tok);
	builtins::Expanded? maybe_expanded = p.comp.builtins.get_or_create(p.comp, name);
	if (catch maybe_expanded) return parser_postfix::NO_BUILTIN_CALL~;
	builtins::Expanded expanded = maybe_expanded;
	type_store::Func? maybe_fn = expanded.qt.get_func(p.comp);
	if (catch maybe_fn) return parser_postfix::NO_BUILTIN_CALL~;
	type_store::Func fn_ty = maybe_fn;
	bool custom = expanded.attributes.custom_typecheck;
	uint expected = 0;
	bool has_expected = false;
	bool variadic = false;

	if (custom)
	{
		if (is_overflow_builtin(expanded.tag)) { expected = 3; has_expected = true; }
		else if (has_single_custom_arg(expanded.tag)) { expected = 1; has_expected = true; }
		else { return parser_postfix::NO_BUILTIN_CALL~; }
	}
	else
	{
		expected = (uint)fn_ty.params.len;
		has_expected = true;
		variadic = fn_ty.kind == type_store::FuncKind.VARIADIC;
	}

	if (has_expected && ((variadic && args.len < (usz)expected) || (!variadic && args.len != (usz)expected))) { return arity_error(p, args, l_paren, expected, variadic); }

	if (is_overflow_builtin(expanded.tag))
	{
		for (uint i = 0; i < 3; i++)
		{
			if (catch check_overflow_arg_type(p, args, (uint)i)) return parser::PARSING_FAILED~;
		}
	}
	else if (!custom)
	{
		for (uint i = 0; i < expected; i++)
		{
			parser_result::Result arg = { .node = args[(usz)i],
				.qt = args[(usz)i].qt(&p.tree), .val = value::NONE };
			if (try val = p.tree.value_of(args[(usz)i])) arg.val = val;
			if (!arg.coerce_scalar(p, fn_ty.params[(usz)i].qt, args[(usz)i].tok(&p.tree))!) { return builtin_argument_type_error(p, args[(usz)i], fn_ty.params[(usz)i].qt); }
			args[(usz)i] = arg.node;
			arg.save_value(p);
		}
	}

	type_store::QualType result_qt = fn_ty.return_type;
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = builtin_tok, .qt = result_qt, .args = args } });
	value::Value result = eval ? builtin_eval::eval(expanded, p, args) : value::NONE;
	return { .node = node, .qt = result_qt, .val = result };
}
