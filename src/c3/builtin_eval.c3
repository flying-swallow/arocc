// Constant evaluation for the builtin cases implemented by src/aro/Builtins/eval.zig.
// The dispatcher intentionally returns Value.NONE for every unsupported case:
// this means “not folded”, including const_evaluable builtins that Zig's eval
// switch does not yet handle.
module aro::builtin_eval;
import aro::builtins, aro::builtin_defs::common;
import aro::compilation, aro::parser, aro::tree, aro::type_store, aro::value, aro::value_interner;
import aro::float_value;

<* Recognized string literal after Zig's paren/no-op/bitcast/array-to-pointer peeling. *>
fn value::Value? decayed_string(parser::Parser* p, type_store::NodeIndex index)
{
	while (true)
	{
		tree::Node n = p.tree.decode_expr_stmt(index);
		switch (n.kind)
		{
			case tree::NodeKind.PAREN_EXPR: index = n.unary.operand;
			case tree::NodeKind.STRING_LITERAL_EXPR: return p.tree.value_of(index);
			case tree::NodeKind.CAST:
				switch (n.cast.kind)
				{
					case tree::CastKind.NO_OP:
					case tree::CastKind.BITCAST:
					case tree::CastKind.ARRAY_TO_POINTER: index = n.cast.operand;
					default: return value::NONE;
				}
			default: return value::NONE;
		}
	}
}

<* Zig Parser.isAddressOfStringLiteral (outer parens are skipped by getNode). *>
fn bool is_address_of_string_literal(parser::Parser* p, type_store::NodeIndex index)
{
	tree::Node n;
	while (true)
	{
		n = p.tree.decode_expr_stmt(index);
		if (n.kind != tree::NodeKind.PAREN_EXPR) break;
		index = n.unary.operand;
	}
	if (n.kind != tree::NodeKind.ADDR_OF_EXPR) return false;
	index = n.unary.operand;
	while (true)
	{
		tree::Node operand = p.tree.decode_expr_stmt(index);
		if (operand.kind != tree::NodeKind.PAREN_EXPR) return operand.kind == tree::NodeKind.STRING_LITERAL_EXPR;
		index = operand.unary.operand;
	}
}

<* Parse an unsigned base-0 payload, returning zero on malformed/overflow input as std.fmt.parseUnsigned does here. *>
fn uint128 parse_nan_payload(char[] bytes, uint width)
{
	usz end = bytes.len;
	if (end != 0 && bytes[end - 1] == 0) end--;
	usz i = 0;
	uint base = 10;
	if (end >= 2 && bytes[0] == '0' && (bytes[1] == 'x' || bytes[1] == 'X')) { base = 16; i = 2; }
	else if (end >= 2 && bytes[0] == '0' && (bytes[1] == 'b' || bytes[1] == 'B')) { base = 2; i = 2; }
	else if (end > 1 && bytes[0] == '0') { base = 8; i = 1; }
	uint128 limit = width == 128 ? ~((uint128)0) : (((uint128)1 << width) - 1);
	uint128 result = 0;
	for (; i < end; i++)
	{
		char c = bytes[i];
		uint digit;
		if (c >= '0' && c <= '9') { digit = (uint)(c - '0'); }
		else if (c >= 'a' && c <= 'f') { digit = (uint)(c - 'a') + 10; }
		else if (c >= 'A' && c <= 'F') { digit = (uint)(c - 'A') + 10; }
		else { return 0; }
		if (digit >= base || result > (limit - digit) / base) return 0;
		result = result * base + digit;
	}
	return result;
}

<* Construct std.math.nan(T) with the parsed payload, matching eval.zig's bitwise OR. *>
fn value_interner::KeyFloat nan_with_payload(ulong bits, char[] payload)
{
	value_interner::KeyFloatTag tag = float_value::tag_for_bits(bits);
	uint payload_width = float_value::format_of(tag).frac_bits;
	if (tag == value_interner::KeyFloatTag.F80) payload_width = 63;
	uint128 parsed = parse_nan_payload(payload, (uint)bits);
	uint128 payload_mask = ((uint128)1 << payload_width) - 1;
	return float_value::from_raw(tag, float_value::std_nan(tag).raw() | (parsed & payload_mask));
}

<*
 Port of Builtins.eval. Call after builtin type checking with the resolved builtin
 and its argument node indexes. NONE means that this evaluator has no result.
*>
fn value::Value eval(builtins::Expanded expanded, parser::Parser* p, type_store::NodeIndex[] args)
{
	if (!expanded.attributes.const_evaluable) return value::NONE;
	compilation::Compilation* comp = p.comp;
	if (expanded.tag == common::TAG___BUILTIN_INFF || expanded.tag == common::TAG___BUILTIN_INF || expanded.tag == common::TAG___BUILTIN_INFL)
	{
		type_store::QualType qt = expanded.tag == common::TAG___BUILTIN_INFF ? type_store::FLOAT :
			expanded.tag == common::TAG___BUILTIN_INF ? type_store::DOUBLE : type_store::LONG_DOUBLE;
		return float_value::intern_float(float_value::inf(float_value::tag_for_bits(qt.bit_sizeof(comp))), comp);
	}
	if (expanded.tag == common::TAG___BUILTIN_ISINF || expanded.tag == common::TAG___BUILTIN_ISINF_SIGN || expanded.tag == common::TAG___BUILTIN_ISNAN)
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = p.tree.value_of(args[0]);
		if (catch maybe) return value::NONE;
		value::Value val = maybe;
		if (expanded.tag == common::TAG___BUILTIN_ISINF) return value::from_bool(float_value::is_inf(val, comp));
		if (expanded.tag == common::TAG___BUILTIN_ISNAN) return value::from_bool(float_value::is_nan(val, comp));
		switch (float_value::is_inf_sign(val, comp))
		{
			case UNKNOWN: return value::NONE;
			case FINITE: return value::ZERO;
			case POSITIVE: return value::ONE;
			case NEGATIVE: return value::int_i64(-1, comp);
		}
	}
	if (expanded.tag == common::TAG___BUILTIN_NAN)
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = decayed_string(p, args[0]);
		if (catch maybe) return value::NONE;
		value::Value str = maybe;
		if (!str.is(value_interner::InternerKeyTag.BYTES, comp)) return value::NONE;
		return float_value::intern_float(nan_with_payload(type_store::DOUBLE.bit_sizeof(comp), str.to_bytes(comp)), comp);
	}
	if (expanded.tag == common::TAG___BUILTIN_CONSTANT_P)
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = p.tree.value_of(args[0]);
		if (catch maybe) return value::from_bool(is_address_of_string_literal(p, args[0]));
		return value::from_bool(!maybe.is_pointer(comp));
	}
	return value::NONE;
}
