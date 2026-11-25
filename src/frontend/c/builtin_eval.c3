// Constant evaluation for the builtin cases implemented by src/aro/Builtins/eval.zig,
// plus C3-only bswap folding. Bswap folding extends eval.zig as required by option B:
// keep C3's “not a compile-time constant” check by folding these values instead.
module aro::frontend::c::builtin_eval;
import aro::primitive_value;
import aro::frontend::c::builtins, aro::frontend::c::builtin_defs::common, aro::frontend::c::builtin_properties;
import aro::frontend::c::compilation, aro::frontend::c::parser, aro::frontend::c::tree, aro::frontend::c::type_store, aro::frontend::c::value, aro::value_interner;

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
fn primitive_value::PrimitiveValue nan_with_payload(ulong bits, char[] payload)
{
	primitive_value::PrimitiveType tag = primitive_value::float_tag_of_width(bits);
	uint payload_width = tag.format.frac_bits;
	if (tag == primitive_value::PrimitiveType.F80) payload_width = 63;
	uint128 parsed = parse_nan_payload(payload, (uint)bits);
	uint128 payload_mask = ((uint128)1 << payload_width) - 1;
	return primitive_value::float_key(tag, primitive_value::std_nan(tag).float_bits() | (parsed & payload_mask));
}

<* Construct a signaling NaN: quiet bit clear, payload below it, forced nonzero so the
   result stays a NaN (GCC's __builtin_nans). *>
fn primitive_value::PrimitiveValue snan_with_payload(ulong bits, char[] payload)
{
	primitive_value::PrimitiveType tag = primitive_value::float_tag_of_width(bits);
	uint128 quiet_bit = (uint128)1 << (tag.format.frac_bits - 1);
	uint128 parsed = parse_nan_payload(payload, (uint)bits) & (quiet_bit - 1);
	if (parsed == 0) parsed = quiet_bit >> 1;
	return primitive_value::float_key(tag, (primitive_value::std_nan(tag).float_bits() & ~quiet_bit) | parsed);
}

faultdef NOT_NAN_BUILTIN; // also: not an inf builtin

struct NanBuiltin
{
	type_store::QualType qt;
	bool signaling;
}

<* The `__builtin_nan*` / `__builtin_nans*` family: result type and whether it is signaling. *>
fn NanBuiltin? nan_builtin(builtin_properties::BuiltinTag tag)
{
	switch (tag)
	{
		case common::TAG___BUILTIN_NANF16: return { type_store::FLOAT16, false };
		case common::TAG___BUILTIN_NANF:
		case common::TAG___BUILTIN_NANF32: return { type_store::FLOAT, false };
		case common::TAG___BUILTIN_NAN:
		case common::TAG___BUILTIN_NANF64:
		case common::TAG___BUILTIN_NANF32X: return { type_store::DOUBLE, false };
		case common::TAG___BUILTIN_NANL: return { type_store::LONG_DOUBLE, false };
		case common::TAG___BUILTIN_NANF64X:
		case common::TAG___BUILTIN_NANF128: return { type_store::FLOAT128, false };
		case common::TAG___BUILTIN_NANSF16: return { type_store::FLOAT16, true };
		case common::TAG___BUILTIN_NANSF:
		case common::TAG___BUILTIN_NANSF32: return { type_store::FLOAT, true };
		case common::TAG___BUILTIN_NANS:
		case common::TAG___BUILTIN_NANSF64:
		case common::TAG___BUILTIN_NANSF32X: return { type_store::DOUBLE, true };
		case common::TAG___BUILTIN_NANSL: return { type_store::LONG_DOUBLE, true };
		case common::TAG___BUILTIN_NANSF64X:
		case common::TAG___BUILTIN_NANSF128: return { type_store::FLOAT128, true };
		default: return NOT_NAN_BUILTIN~;
	}
}

<* Result type of the `__builtin_inf*` / `__builtin_huge_val*` families (IEEE: both are +inf). *>
fn type_store::QualType? inf_builtin_type(builtin_properties::BuiltinTag tag)
{
	switch (tag)
	{
		case common::TAG___BUILTIN_INFF16:
		case common::TAG___BUILTIN_HUGE_VALF16: return type_store::FLOAT16;
		case common::TAG___BUILTIN_INFF:
		case common::TAG___BUILTIN_HUGE_VALF:
		case common::TAG___BUILTIN_INFF32: return type_store::FLOAT;
		case common::TAG___BUILTIN_INF:
		case common::TAG___BUILTIN_HUGE_VAL:
		case common::TAG___BUILTIN_INFF64:
		case common::TAG___BUILTIN_INFF32X: return type_store::DOUBLE;
		case common::TAG___BUILTIN_INFL:
		case common::TAG___BUILTIN_HUGE_VALL: return type_store::LONG_DOUBLE;
		// _Float64x is binary128 here (type_store.c3), not GCC's x87 long double.
		case common::TAG___BUILTIN_HUGE_VALF128:
		case common::TAG___BUILTIN_INFF64X:
		case common::TAG___BUILTIN_INFF128: return type_store::FLOAT128;
		default: return NOT_NAN_BUILTIN~;
	}
}

fn ulong swap_bytes(ulong v, uint bytes)
{
	ulong swapped = 0;
	for (uint i = 0; i < bytes; i++)
	{
		swapped = (swapped << 8) | (v & 0xFF);
		v >>= 8;
	}
	return swapped;
}

<*
 Port of Builtins.eval. Call after builtin type checking with the resolved builtin
 and its argument node indexes. NONE means that this evaluator has no result.
*>
fn value::Value eval(builtins::Expanded expanded, parser::Parser* p, type_store::NodeIndex[] args)
{
	if (!expanded.attributes.const_evaluable) return value::NONE;
	compilation::Compilation* comp = p.comp;
	if (try qt = inf_builtin_type(expanded.tag))
	{
		return value::intern(comp, primitive_value::inf(primitive_value::float_tag_of_width(qt.bit_sizeof(comp))));
	}
	if (expanded.tag == common::TAG___BUILTIN_ISINF || expanded.tag == common::TAG___BUILTIN_ISINF_SIGN || expanded.tag == common::TAG___BUILTIN_ISNAN)
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = p.tree.value_of(args[0]);
		if (catch maybe) return value::NONE;
		value::Value val = maybe;
		if (expanded.tag == common::TAG___BUILTIN_ISINF) return value::from_bool(val.is_inf(comp));
		if (expanded.tag == common::TAG___BUILTIN_ISNAN) return value::from_bool(val.is_nan(comp));
		switch (val.is_inf_sign(comp))
		{
			case UNKNOWN: return value::NONE;
			case FINITE: return value::ZERO;
			case POSITIVE: return value::ONE;
			case NEGATIVE: return value::int_i64(-1, comp);
		}
	}
	if (try nan = nan_builtin(expanded.tag))
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = decayed_string(p, args[0]);
		if (catch maybe) return value::NONE;
		value::Value str = maybe;
		if (!str.is(primitive_value::PrimitiveType.BYTES, comp)) return value::NONE;
		ulong bits = nan.qt.bit_sizeof(comp);
		char[] payload = str.to_bytes(comp);
		return value::intern(comp, nan.signaling ? snan_with_payload(bits, payload) : nan_with_payload(bits, payload));
	}
	if (expanded.tag == common::TAG___BUILTIN_ISSIGNALING)
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = p.tree.value_of(args[0]);
		if (catch maybe) return value::NONE;
		return value::from_bool(maybe.is_signaling(comp));
	}
	if (expanded.tag == common::TAG___BUILTIN_CONSTANT_P)
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = p.tree.value_of(args[0]);
		if (catch maybe) return value::from_bool(is_address_of_string_literal(p, args[0]));
		return value::from_bool(!maybe.is_pointer(comp));
	}
	if (expanded.tag == common::TAG___BUILTIN_BSWAP16 || expanded.tag == common::TAG___BUILTIN_BSWAP32 ||
		expanded.tag == common::TAG___BUILTIN_BSWAP64)
	{
		if (args.len != 1) return value::NONE;
		value::Value? maybe = p.tree.value_of(args[0]);
		if (catch maybe) return value::NONE;
		ulong? maybe_u64 = maybe.to_u64(comp);
		if (catch maybe_u64) return value::NONE;
		uint bytes = expanded.tag == common::TAG___BUILTIN_BSWAP16 ? 2 :
			expanded.tag == common::TAG___BUILTIN_BSWAP32 ? 4 : 8;
		return value::int_u64(swap_bytes(maybe_u64, bytes), comp);
	}
	return value::NONE;
}
