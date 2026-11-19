// Generic builtin call validation and constant evaluation, based on the
// generated signatures and Parser.zig's CallExpr path.
module aro::builtin_call;
import aro::builtin_defs::aarch64, aro::builtin_defs::arm, aro::builtin_defs::common;
import aro::builtin_eval, aro::builtins, aro::builtin_properties;
import aro::lang_opts;
import aro::parser, aro::diagnostics, aro::parser_result;
import aro::tree, aro::tokens, aro::type_store, aro::value;
import std::core::dstring;

excuse NO_PARAM_COUNT;


fn bool is_overflow_builtin(builtin_properties::BuiltinTag tag)
{
	return tag == common::TAG___BUILTIN_ADD_OVERFLOW || tag == common::TAG___BUILTIN_SUB_OVERFLOW ||
		tag == common::TAG___BUILTIN_MUL_OVERFLOW;
}

fn bool is_va_start_builtin(builtin_properties::BuiltinTag tag)
{
	return tag == common::TAG___BUILTIN_VA_START || tag == common::TAG___VA_START || tag == common::TAG_VA_START;
}

fn uint? param_count_override(builtins::Expanded expanded)
{
	switch (expanded.tag)
	{
		case common::TAG___C11_ATOMIC_THREAD_FENCE:
		case common::TAG___ATOMIC_THREAD_FENCE:
		case common::TAG___C11_ATOMIC_SIGNAL_FENCE:
		case common::TAG___ATOMIC_SIGNAL_FENCE:
		case common::TAG___C11_ATOMIC_IS_LOCK_FREE:
		case common::TAG___BUILTIN_ISINF:
		case common::TAG___BUILTIN_ISINF_SIGN:
		case common::TAG___BUILTIN_ISNAN:
		case common::TAG___BUILTIN_ELEMENTWISE_ABS:
		case common::TAG___BUILTIN_ELEMENTWISE_BITREVERSE:
		case common::TAG___BUILTIN_ELEMENTWISE_CANONICALIZE:
		case common::TAG___BUILTIN_ELEMENTWISE_CEIL:
		case common::TAG___BUILTIN_ELEMENTWISE_COS:
		case common::TAG___BUILTIN_ELEMENTWISE_EXP:
		case common::TAG___BUILTIN_ELEMENTWISE_EXP2:
		case common::TAG___BUILTIN_ELEMENTWISE_FLOOR:
		case common::TAG___BUILTIN_ELEMENTWISE_LOG:
		case common::TAG___BUILTIN_ELEMENTWISE_LOG10:
		case common::TAG___BUILTIN_ELEMENTWISE_LOG2:
		case common::TAG___BUILTIN_ELEMENTWISE_NEARBYINT:
		case common::TAG___BUILTIN_ELEMENTWISE_RINT:
		case common::TAG___BUILTIN_ELEMENTWISE_ROUND:
		case common::TAG___BUILTIN_ELEMENTWISE_ROUNDEVEN:
		case common::TAG___BUILTIN_ELEMENTWISE_SIN:
		case common::TAG___BUILTIN_ELEMENTWISE_SQRT:
		case common::TAG___BUILTIN_ELEMENTWISE_TRUNC:
		case common::TAG___BUILTIN_ELEMENTWISE_POPCOUNT:
		case common::TAG___BUILTIN_NONTEMPORAL_LOAD:
		case common::TAG___BUILTIN_NONDETERMINISTIC_VALUE:
		case common::TAG___BUILTIN_REDUCE_ADD:
		case common::TAG___BUILTIN_REDUCE_MUL:
		case common::TAG___BUILTIN_REDUCE_AND:
		case common::TAG___BUILTIN_REDUCE_OR:
		case common::TAG___BUILTIN_REDUCE_XOR:
		case common::TAG___BUILTIN_REDUCE_MAX:
		case common::TAG___BUILTIN_REDUCE_MIN:
		case common::TAG___BUILTIN_CONSTANT_P: return 1;
		case common::TAG___BUILTIN_COMPLEX:
		case common::TAG___C11_ATOMIC_LOAD:
		case common::TAG___ATOMIC_LOAD_N:
		case common::TAG___C11_ATOMIC_INIT:
		case common::TAG___BUILTIN_ELEMENTWISE_ADD_SAT:
		case common::TAG___BUILTIN_ELEMENTWISE_COPYSIGN:
		case common::TAG___BUILTIN_ELEMENTWISE_MAX:
		case common::TAG___BUILTIN_ELEMENTWISE_MIN:
		case common::TAG___BUILTIN_ELEMENTWISE_POW:
		case common::TAG___BUILTIN_ELEMENTWISE_SUB_SAT:
		case common::TAG___BUILTIN_NONTEMPORAL_STORE:
		case common::TAG___BUILTIN_ELEMENTWISE_LDEXP:
		case common::TAG___BUILTIN_ELEMENTWISE_MAXIMUMNUM:
		case common::TAG___BUILTIN_ELEMENTWISE_MINIMUMNUM: return 2;
		case common::TAG___C11_ATOMIC_STORE:
		case common::TAG___ATOMIC_STORE:
		case common::TAG___ATOMIC_STORE_N:
		case common::TAG___ATOMIC_LOAD:
		case common::TAG___C11_ATOMIC_EXCHANGE:
		case common::TAG___C11_ATOMIC_FETCH_ADD:
		case common::TAG___C11_ATOMIC_FETCH_SUB:
		case common::TAG___C11_ATOMIC_FETCH_OR:
		case common::TAG___C11_ATOMIC_FETCH_XOR:
		case common::TAG___C11_ATOMIC_FETCH_AND:
		case common::TAG___C11_ATOMIC_FETCH_NAND:
		case common::TAG___ATOMIC_FETCH_ADD:
		case common::TAG___ATOMIC_FETCH_SUB:
		case common::TAG___ATOMIC_FETCH_AND:
		case common::TAG___ATOMIC_FETCH_XOR:
		case common::TAG___ATOMIC_FETCH_OR:
		case common::TAG___ATOMIC_FETCH_NAND:
		case common::TAG___ATOMIC_ADD_FETCH:
		case common::TAG___ATOMIC_SUB_FETCH:
		case common::TAG___ATOMIC_AND_FETCH:
		case common::TAG___ATOMIC_XOR_FETCH:
		case common::TAG___ATOMIC_OR_FETCH:
		case common::TAG___ATOMIC_NAND_FETCH:
		case common::TAG___BUILTIN_ADD_OVERFLOW:
		case common::TAG___BUILTIN_SUB_OVERFLOW:
		case common::TAG___BUILTIN_MUL_OVERFLOW:
		case common::TAG___BUILTIN_ELEMENTWISE_FMA:
		case common::TAG___ATOMIC_EXCHANGE_N:
		case common::TAG___BUILTIN_ELEMENTWISE_FSHL:
		case common::TAG___BUILTIN_ELEMENTWISE_FSHR: return 3;
		case common::TAG___ATOMIC_EXCHANGE: return 4;
		case common::TAG___C11_ATOMIC_COMPARE_EXCHANGE_STRONG:
		case common::TAG___C11_ATOMIC_COMPARE_EXCHANGE_WEAK: return 5;
		case common::TAG___ATOMIC_COMPARE_EXCHANGE:
		case common::TAG___ATOMIC_COMPARE_EXCHANGE_N: return 6;
		case aarch64::TAG___BUILTIN_ARM_LDREX:
		case aarch64::TAG___BUILTIN_ARM_LDAEX:
		case arm::TAG___BUILTIN_ARM_LDREX:
		case arm::TAG___BUILTIN_ARM_LDREXD:
		case arm::TAG___BUILTIN_ARM_LDAEX: return 1;
		case aarch64::TAG___BUILTIN_ARM_STREX:
		case aarch64::TAG___BUILTIN_ARM_STLEX:
		case arm::TAG___BUILTIN_ARM_STREX:
		case arm::TAG___BUILTIN_ARM_STREXD:
		case arm::TAG___BUILTIN_ARM_STLEX: return 2;
		default: return NO_PARAM_COUNT~;
	}
}

fn type_store::QualType return_type(parser::Parser* p, builtins::Expanded expanded,
	type_store::NodeIndex[] args, type_store::Func fn_ty)
{
	switch (expanded.tag)
	{
		case common::TAG___BUILTIN_ADD_OVERFLOW:
		case common::TAG___BUILTIN_SUB_OVERFLOW:
		case common::TAG___BUILTIN_MUL_OVERFLOW: return type_store::BOOL;
		case common::TAG___ATOMIC_FETCH_ADD:
		case common::TAG___ATOMIC_ADD_FETCH:
		case common::TAG___C11_ATOMIC_FETCH_ADD:
		case common::TAG___ATOMIC_FETCH_SUB:
		case common::TAG___ATOMIC_SUB_FETCH:
		case common::TAG___C11_ATOMIC_FETCH_SUB:
		case common::TAG___ATOMIC_FETCH_AND:
		case common::TAG___ATOMIC_AND_FETCH:
		case common::TAG___C11_ATOMIC_FETCH_AND:
		case common::TAG___ATOMIC_FETCH_XOR:
		case common::TAG___ATOMIC_XOR_FETCH:
		case common::TAG___C11_ATOMIC_FETCH_XOR:
		case common::TAG___ATOMIC_FETCH_OR:
		case common::TAG___ATOMIC_OR_FETCH:
		case common::TAG___C11_ATOMIC_FETCH_OR:
		case common::TAG___ATOMIC_FETCH_NAND:
		case common::TAG___ATOMIC_NAND_FETCH:
		case common::TAG___C11_ATOMIC_FETCH_NAND:
		case common::TAG___ATOMIC_EXCHANGE_N:
		case common::TAG___C11_ATOMIC_EXCHANGE:
		case common::TAG___ATOMIC_LOAD_N:
		{
			type_store::QualType first_param = args[0].qt(&p.tree);
			if (try pointer = first_param.get(p.comp, type_store::TypeTag.POINTER))
			{
				return pointer.pointer.child.non_atomic(p.comp).unqualified();
			}
			return type_store::INVALID;
		}
		case common::TAG___C11_ATOMIC_LOAD:
		{
			if (try pointer = args[0].qt(&p.tree).get(p.comp, type_store::TypeTag.POINTER))
			{
				if (try atomic = pointer.pointer.child.get(p.comp, type_store::TypeTag.ATOMIC))
				{
					return atomic.atomic.unqualified();
				}
			}
			return type_store::INVALID;
		}
		case common::TAG___SYNC_FETCH_AND_ADD:
		case common::TAG___SYNC_FETCH_AND_AND:
		case common::TAG___SYNC_FETCH_AND_NAND:
		case common::TAG___SYNC_FETCH_AND_OR:
		case common::TAG___SYNC_FETCH_AND_SUB:
		case common::TAG___SYNC_FETCH_AND_XOR:
		case common::TAG___SYNC_ADD_AND_FETCH:
		case common::TAG___SYNC_AND_AND_FETCH:
		case common::TAG___SYNC_NAND_AND_FETCH:
		case common::TAG___SYNC_OR_AND_FETCH:
		case common::TAG___SYNC_SUB_AND_FETCH:
		case common::TAG___SYNC_XOR_AND_FETCH:
		case common::TAG___SYNC_SWAP:
		case common::TAG___SYNC_LOCK_TEST_AND_SET:
		case common::TAG___SYNC_VAL_COMPARE_AND_SWAP:
		{
			if (args.len < 2) return type_store::INVALID;
			return args[1].qt(&p.tree);
		}
		case common::TAG___BUILTIN_COMPLEX:
		{
			if (args.len == 0) return type_store::INVALID;
			type_store::QualType last_param = args[args.len - 1].qt(&p.tree);
			if (!last_param.is(p.comp, type_store::TypeTag.FLOAT)) return type_store::INVALID;
			return last_param.to_complex(p.comp);
		}
		case common::TAG___ATOMIC_COMPARE_EXCHANGE:
		case common::TAG___ATOMIC_COMPARE_EXCHANGE_N:
		case common::TAG___C11_ATOMIC_COMPARE_EXCHANGE_STRONG:
		case common::TAG___C11_ATOMIC_COMPARE_EXCHANGE_WEAK:
		case common::TAG___C11_ATOMIC_IS_LOCK_FREE:
		case common::TAG___SYNC_BOOL_COMPARE_AND_SWAP: return type_store::BOOL;
		case common::TAG___BUILTIN_ELEMENTWISE_ABS:
		case common::TAG___BUILTIN_ELEMENTWISE_BITREVERSE:
		case common::TAG___BUILTIN_ELEMENTWISE_CANONICALIZE:
		case common::TAG___BUILTIN_ELEMENTWISE_CEIL:
		case common::TAG___BUILTIN_ELEMENTWISE_COS:
		case common::TAG___BUILTIN_ELEMENTWISE_EXP:
		case common::TAG___BUILTIN_ELEMENTWISE_EXP2:
		case common::TAG___BUILTIN_ELEMENTWISE_FLOOR:
		case common::TAG___BUILTIN_ELEMENTWISE_LOG:
		case common::TAG___BUILTIN_ELEMENTWISE_LOG10:
		case common::TAG___BUILTIN_ELEMENTWISE_LOG2:
		case common::TAG___BUILTIN_ELEMENTWISE_NEARBYINT:
		case common::TAG___BUILTIN_ELEMENTWISE_RINT:
		case common::TAG___BUILTIN_ELEMENTWISE_ROUND:
		case common::TAG___BUILTIN_ELEMENTWISE_ROUNDEVEN:
		case common::TAG___BUILTIN_ELEMENTWISE_SIN:
		case common::TAG___BUILTIN_ELEMENTWISE_SQRT:
		case common::TAG___BUILTIN_ELEMENTWISE_TRUNC:
		case common::TAG___BUILTIN_ELEMENTWISE_ADD_SAT:
		case common::TAG___BUILTIN_ELEMENTWISE_COPYSIGN:
		case common::TAG___BUILTIN_ELEMENTWISE_MAX:
		case common::TAG___BUILTIN_ELEMENTWISE_MIN:
		case common::TAG___BUILTIN_ELEMENTWISE_POW:
		case common::TAG___BUILTIN_ELEMENTWISE_SUB_SAT:
		case common::TAG___BUILTIN_ELEMENTWISE_FMA:
		case common::TAG___BUILTIN_ELEMENTWISE_POPCOUNT:
		case common::TAG___BUILTIN_ELEMENTWISE_FSHL:
		case common::TAG___BUILTIN_ELEMENTWISE_FSHR:
		case common::TAG___BUILTIN_ELEMENTWISE_LDEXP:
		case common::TAG___BUILTIN_ELEMENTWISE_MAXIMUMNUM:
		case common::TAG___BUILTIN_ELEMENTWISE_MINIMUMNUM:
		case common::TAG___BUILTIN_NONDETERMINISTIC_VALUE: return args[0].qt(&p.tree);
		case common::TAG___BUILTIN_ELEMENTWISE_CLZG:
		case common::TAG___BUILTIN_ELEMENTWISE_CTZG:
		{
			if (args.len < 1) return type_store::INVALID;
			return args[0].qt(&p.tree);
		}
		case common::TAG___BUILTIN_REDUCE_ADD:
		case common::TAG___BUILTIN_REDUCE_MUL:
		case common::TAG___BUILTIN_REDUCE_AND:
		case common::TAG___BUILTIN_REDUCE_OR:
		case common::TAG___BUILTIN_REDUCE_XOR:
		case common::TAG___BUILTIN_REDUCE_MAX:
		case common::TAG___BUILTIN_REDUCE_MIN:
		{
			type_store::QualType first_param = args[0].qt(&p.tree);
			if (first_param.is_invalid()) return type_store::INVALID;
			if (try vector = first_param.get(p.comp, type_store::TypeTag.VECTOR)) return vector.vector.elem;
			return type_store::INVALID;
		}
		case common::TAG___BUILTIN_NONTEMPORAL_LOAD:
		{
			type_store::QualType first_param = args[0].qt(&p.tree);
			if (first_param.is_invalid()) return type_store::INVALID;
			if (!first_param.is(p.comp, type_store::TypeTag.POINTER)) return type_store::INVALID;
			return first_param.child_type(p.comp);
		}
		case aarch64::TAG___BUILTIN_ARM_LDREX:
		case aarch64::TAG___BUILTIN_ARM_LDAEX:
		case arm::TAG___BUILTIN_ARM_LDREX:
		case arm::TAG___BUILTIN_ARM_LDREXD:
		case arm::TAG___BUILTIN_ARM_LDAEX:
		{
			type_store::QualType first_param = args[0].qt(&p.tree);
			if (!first_param.is(p.comp, type_store::TypeTag.POINTER)) return type_store::INVALID;
			return first_param.child_type(p.comp);
		}
		case aarch64::TAG___BUILTIN_ARM_STREX:
		case aarch64::TAG___BUILTIN_ARM_STLEX:
		case arm::TAG___BUILTIN_ARM_STREX:
		case arm::TAG___BUILTIN_ARM_STREXD:
		case arm::TAG___BUILTIN_ARM_STLEX: return type_store::INT;
		default: return fn_ty.return_type;
	}
}

fn void? check_overflow_arg_type(parser::Parser* p, type_store::NodeIndex[] args, uint index)
{
	type_store::QualType qt = args[(usz)index].qt(&p.tree);
	tokens::TokenIndex tok = args[(usz)index].tok(&p.tree);
	if (index < 2)
	{
		if (!qt.is_real_int(p.comp))
		{
			Diagnostic.OVERFLOW_BUILTIN_REQUIRES_INT.@emit(p, tok,
				p.fmt_qt(qt))!;
			return;
		}
		return;
	}
	type_store::QualType child = type_store::INVALID;
	if (try ptr = qt.get(p.comp, type_store::TypeTag.POINTER)) child = ptr.pointer.child;
	if (child.is_invalid() || child.scalar_kind(p.comp) != type_store::ScalarKind.INT || child.is_const)
	{
		Diagnostic.OVERFLOW_RESULT_REQUIRES_PTR.@emit(p, tok,
			p.fmt_qt(qt))!;
		return;
	}
	return;
}

fn void? check_arm_exclusive(parser::Parser* p, builtin_properties::BuiltinTag tag,
	tokens::TokenIndex builtin_tok, type_store::NodeIndex[] args, usz index)
{
	bool is_load = false;
	switch (tag)
	{
		case aarch64::TAG___BUILTIN_ARM_LDREX:
		case aarch64::TAG___BUILTIN_ARM_LDAEX:
		case arm::TAG___BUILTIN_ARM_LDREX:
		case arm::TAG___BUILTIN_ARM_LDREXD:
		case arm::TAG___BUILTIN_ARM_LDAEX: is_load = true;
		default: break;
	}
	bool is_store = false;
	switch (tag)
	{
		case aarch64::TAG___BUILTIN_ARM_STREX:
		case aarch64::TAG___BUILTIN_ARM_STLEX:
		case arm::TAG___BUILTIN_ARM_STREX:
		case arm::TAG___BUILTIN_ARM_STREXD:
		case arm::TAG___BUILTIN_ARM_STLEX: is_store = true;
		default: break;
	}
	if (!is_load && !is_store) return;
	if (is_load ? index != 0 : index != 1) return;

	String name = p.tree.tok_slice(builtin_tok);
	type_store::NodeIndex pointer_node = args[index];
	type_store::QualType original_pointer = pointer_node.qt(&p.tree);
	type_store::Type? maybe_pointer = original_pointer.get(p.comp, type_store::TypeTag.POINTER);
	if (catch maybe_pointer)
	{
		Diagnostic.BUILTIN_ARM_LDREX_STREX_INVALID_PTR_TYPE.@emit(p, pointer_node.tok(&p.tree), name, p.fmt_qt(original_pointer))!;
		return;
	}
	type_store::Type pointer = maybe_pointer;
	type_store::QualType child = pointer.pointer.child;
	type_store::QualType qualified_child = child.unqualified();
	if (is_load)
	{
		qualified_child.is_const = true;
		qualified_child.is_volatile = true;
	}
	else
	{
		qualified_child.is_volatile = true;
	}
	type_store::QualType qualified_pointer = p.comp.type_store.put(type_store::type_pointer(qualified_child));
	parser_result::Result pointer_arg = { .node = pointer_node, .qt = original_pointer, .val = value::NONE };
	if (try pointer_value = p.tree.value_of(pointer_node)) pointer_arg.val = pointer_value;
	if (!pointer_arg.coerce_scalar(p, qualified_pointer, pointer_node.tok(&p.tree), parser_result::CoercionContext.ARGUMENT)!)
	{
		Diagnostic.INCOMPATIBLE_ARG.@emit(p, pointer_node.tok(&p.tree),
			p.fmt_qt(original_pointer), p.fmt_qt(qualified_pointer))!;
	}
	else
	{
		args[index] = pointer_arg.node;
	}
	pointer_arg.save_value(p);

	type_store::ScalarKind child_kind = child.scalar_kind(p.comp);
	bool valid_number = (child_kind.is_int || child_kind.is_float) && child_kind.is_real;
	if (!valid_number && !child_kind.is_pointer)
	{
		Diagnostic.BUILTIN_ARM_LDREX_STREX_INVALID_PTR_TYPE.@emit(p, pointer_node.tok(&p.tree), name, p.fmt_qt(original_pointer))!;
		return;
	}

	char mask = (char)p.comp.langopts.arm_ldrex;
	bool is_dword = false;
	switch (tag)
	{
		case arm::TAG___BUILTIN_ARM_LDREXD:
		case arm::TAG___BUILTIN_ARM_STREXD: is_dword = true;
		default: break;
	}
	if (is_dword) mask = mask & lang_opts::ARM_LDREX_D_INT;
	if (mask == 0)
	{
		Diagnostic.BUILTIN_ARM_LDREX_STREX_UNSUPPORTED.@emit(p, builtin_tok, name)!;
		return;
	}

	ulong bits = child.bit_sizeof(p.comp);
	bool supported = bits >= 8 && bits <= 64 && (bits & (bits - 1)) == 0 &&
		(mask & (char)(bits / 8)) != 0;
	if (!supported)
	{
		uint size_count = 0;
		if ((mask & lang_opts::ARM_LDREX_B_INT) != 0) size_count++;
		if ((mask & lang_opts::ARM_LDREX_H_INT) != 0) size_count++;
		if ((mask & lang_opts::ARM_LDREX_W_INT) != 0) size_count++;
		if ((mask & lang_opts::ARM_LDREX_D_INT) != 0) size_count++;
		DString sizes;
		sizes.init(tmem);
		uint seen = 0;
		if ((mask & lang_opts::ARM_LDREX_B_INT) != 0)
		{
			if (seen > 0) sizes.append_string(seen + 1 == size_count ? " or " : ", ");
			sizes.appendf("%d", 1);
			seen++;
		}
		if ((mask & lang_opts::ARM_LDREX_H_INT) != 0)
		{
			if (seen > 0) sizes.append_string(seen + 1 == size_count ? " or " : ", ");
			sizes.appendf("%d", 2);
			seen++;
		}
		if ((mask & lang_opts::ARM_LDREX_W_INT) != 0)
		{
			if (seen > 0) sizes.append_string(seen + 1 == size_count ? " or " : ", ");
			sizes.appendf("%d", 4);
			seen++;
		}
		if ((mask & lang_opts::ARM_LDREX_D_INT) != 0)
		{
			if (seen > 0) sizes.append_string(seen + 1 == size_count ? " or " : ", ");
			sizes.appendf("%d", 8);
		}
		Diagnostic.BUILTIN_ARM_LDREX_STREX_UNSUPPORTED_SIZE.@emit(p, pointer_node.tok(&p.tree), name, sizes.str_view(), p.fmt_qt(original_pointer))!;
	}

	if (is_store)
	{
		type_store::NodeIndex value_node = args[index - 1];
		parser_result::Result value_arg = { .node = value_node, .qt = value_node.qt(&p.tree), .val = value::NONE };
		if (try value = p.tree.value_of(value_node)) value_arg.val = value;
		if (!value_arg.coerce_scalar(p, child, value_node.tok(&p.tree), parser_result::CoercionContext.ARGUMENT)!)
		{
			Diagnostic.INCOMPATIBLE_ARG.@emit(p, value_node.tok(&p.tree),
				p.fmt_qt(value_arg.qt), p.fmt_qt(child))!;
		}
		else
		{
			args[index - 1] = value_arg.node;
		}
		value_arg.save_value(p);
	}
}

fn void? check_complex_arg(parser::Parser* p, type_store::NodeIndex[] args, uint index)
{
	type_store::QualType qt = args[(usz)index].qt(&p.tree);
	tokens::TokenIndex tok = args[(usz)index].tok(&p.tree);
	if (qt.is_invalid()) return;
	if (index <= 1 && !qt.is(p.comp, type_store::TypeTag.FLOAT))
	{
		Diagnostic.NOT_FLOATING_TYPE.@emit(p, tok, p.fmt_qt(qt))!;
		return;
	}
	else if (index == 1)
	{
		type_store::QualType prev = args[0].qt(&p.tree);
		if (!prev.is_invalid() && !prev.eql(qt, p.comp))
		{
			Diagnostic.ARGUMENT_TYPES_DIFFER.@emit(p, tok,
				p.fmt_qt(prev), p.fmt_qt(qt))!;
		}
	}
	return;
}

fn void? check_c11_atomic_load_arg(parser::Parser* p, type_store::NodeIndex[] args, uint index)
{
	if (index != 0) return;
	type_store::QualType qt = args[0].qt(&p.tree);
	tokens::TokenIndex tok = args[0].tok(&p.tree);
	if (qt.is_invalid()) return;
	if (try pointer = qt.get(p.comp, type_store::TypeTag.POINTER))
	{
		if (!pointer.pointer.child.is(p.comp, type_store::TypeTag.ATOMIC))
		{
			Diagnostic.C11_ATOMIC_ADDRESS_TYPE.@emit(p, tok, p.fmt_qt(qt))!;
		}
		return;
	}
	Diagnostic.ATOMIC_ADDRESS_POINTER.@emit(p, tok, p.fmt_qt(qt))!;
	return;
}

fn void? check_va_start_arg(parser::Parser* p, tokens::TokenIndex builtin_tok,
	type_store::NodeIndex[] args, uint index)
{
	if (index == 1)
	{
		parser::FunctionContext context = p.function_context;
		if (!context.active)
		{
			Diagnostic.VA_FUNC_NOT_IN_FUNC.@emit(p, builtin_tok, "va_start")!;
			return;
		}
		if (!context.variadic)
		{
			Diagnostic.VA_FUNC_FIXED_ARGS.@emit(p, builtin_tok, "va_start")!;
			return;
		}
		type_store::Func? maybe_func = context.function_qt.get_func(p.comp);
		if (catch maybe_func) return;
		type_store::Func function = maybe_func;
		if (function.kind != type_store::FuncKind.VARIADIC || function.params.len == 0)
		{
			Diagnostic.VA_FUNC_FIXED_ARGS.@emit(p, builtin_tok, "va_start")!;
			return;
		}

		type_store::NodeIndex last_arg = args[1];
		tree::Node arg_node = last_arg.get(&p.tree);
		// parse_postfix_expr applies lvalue conversion and vararg promotions before
		// the builtin hook, while Zig skips them for this argument. Peel those
		// implicit casts so the original decl-ref remains visible here.
		while (arg_node.kind == tree::NodeKind.CAST && arg_node.cast.implicit)
		{
			last_arg = arg_node.cast.operand;
			arg_node = last_arg.get(&p.tree);
		}
		bool is_last_named_param = false;
		if (arg_node.kind == tree::NodeKind.DECL_REF_EXPR)
		{
			type_store::FuncParam last_param = function.params[function.params.len - 1];
			is_last_named_param = last_param.name == p.comp.intern_string(p.tree.tok_slice(arg_node.decl_ref.name_tok));
		}
		if (!is_last_named_param)
		{
			Diagnostic.VA_START_NOT_LAST_PARAM.@emit(p, last_arg.tok(&p.tree))!;
		}
	}
	else if (index > 1)
	{
		// Zig's first_after is the first argument after the fixed parameters.
		Diagnostic.CLOSING_PAREN.@emit(p, args[1].tok(&p.tree))!;
	}
	return;
}

fn parser_result::Result? builtin_argument_type_error(parser::Parser* p, type_store::NodeIndex arg, type_store::QualType expected)
{
	Diagnostic.INCOMPATIBLE_ARG.@emit(p, arg.tok(&p.tree), p.fmt_qt(arg.qt(&p.tree)), p.fmt_qt(expected))!;
	return parser::PARSING_FAILED~;
}

<* Validate calls for known builtins. Unknown names and custom-typecheck builtins
   without a ported call rule return NO_BUILTIN_CALL so the ordinary call path
   retains its existing behavior. *>
fn parser_result::Result? dispatch(void* context, parser::Parser* p,
	type_store::NodeIndex callee, tokens::TokenIndex l_paren, type_store::NodeIndex[] args, bool eval)
{
	tree::Node callee_node = callee.get(&p.tree);
	if (callee_node.kind != tree::NodeKind.BUILTIN_REF) return parser::NO_BUILTIN_CALL~;
	tokens::TokenIndex builtin_tok = callee_node.builtin_ref.name_tok;
	String name = p.tree.tok_slice(builtin_tok);
	builtins::Expanded? maybe_expanded = p.comp.builtins.get_or_create(p.comp, name);
	if (catch maybe_expanded) return parser::NO_BUILTIN_CALL~;
	builtins::Expanded expanded = maybe_expanded;
	type_store::Func? maybe_fn = expanded.qt.get_func(p.comp);
	if (catch maybe_fn) return parser::NO_BUILTIN_CALL~;
	type_store::Func fn_ty = maybe_fn;
	bool custom = expanded.attributes.custom_typecheck;
	uint expected = 0;
	bool has_expected = false;
	bool variadic = false;

	if (custom)
	{
		if (try count = param_count_override(expanded))
		{
			expected = count;
			has_expected = true;
		}
		else if (expanded.tag == common::TAG___BUILTIN_ELEMENTWISE_CLZG ||
			expanded.tag == common::TAG___BUILTIN_ELEMENTWISE_CTZG)
		{
			// These builtins keep the variadic base signature in Zig: v. has
			// zero fixed parameters, so its arity check accepts any argument count.
			expected = (uint)fn_ty.params.len;
			has_expected = true;
			variadic = fn_ty.kind == type_store::FuncKind.VARIADIC;
		}
		else if (is_va_start_builtin(expanded.tag))
		{
			// Keep the generated one-fixed-argument variadic signature. The
			// second argument is checked against the current function below.
			expected = (uint)fn_ty.params.len;
			has_expected = true;
			variadic = fn_ty.kind == type_store::FuncKind.VARIADIC;
		}
		else
		{
			// Zig's checkVaStartArg covers __builtin_va_start, __va_start, and
			// va_start. The remaining custom va_start tags are intentionally left
			// to ordinary call handling: __builtin_ms_va_start,
			// __builtin_c23_va_start, and __builtin_zos_va_start.
			return parser::NO_BUILTIN_CALL~;
		}
	}
	else
	{
		expected = (uint)fn_ty.params.len;
		has_expected = true;
		variadic = fn_ty.kind == type_store::FuncKind.VARIADIC;
	}

	if (expanded.tag.group == builtin_properties::BuiltinGroup.AARCH64 ||
		expanded.tag.group == builtin_properties::BuiltinGroup.ARM)
	{
		for (usz i = 0; i < args.len; i++)
		{
			check_arm_exclusive(p, expanded.tag, builtin_tok, args, i)!;
		}
	}

	if (expanded.tag == common::TAG___BUILTIN_COMPLEX)
	{
		for (usz i = 0; i < args.len; i++) check_complex_arg(p, args, (uint)i)!;
	}
	else if (expanded.tag == common::TAG___C11_ATOMIC_LOAD)
	{
		for (usz i = 0; i < args.len; i++) check_c11_atomic_load_arg(p, args, (uint)i)!;
	}

	if (has_expected && ((variadic && args.len < (usz)expected) || (!variadic && args.len != (usz)expected)))
	{
		// Wrong argument count (Zig callExpr arity check): too few args -> report at
		// the closing ')' (the token just consumed, or `(` if none); too many ->
		// report at the first extra argument. Variadic builtins only fail when
		// short, with "at least N".
		tokens::TokenIndex arity_tok = args.len < expected ? (p.tok_i > 0 ? p.tok_i - 1 : l_paren) : args[(usz)expected].tok(&p.tree);
		if (variadic)
		{
			Diagnostic.EXPECTED_AT_LEAST_ARGUMENTS.@emit(p, arity_tok, expected, args.len)!;
		}
		else
		{
			Diagnostic.EXPECTED_ARGUMENTS.@emit(p, arity_tok, expected, args.len)!;
		}
		type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
			.builtin_call = { .builtin_tok = builtin_tok, .qt = type_store::INVALID, .args = args } });
		return { .node = node, .qt = type_store::INVALID, .val = value::NONE };
	}

	if (is_overflow_builtin(expanded.tag))
	{
		for (uint i = 0; i < 3; i++)
		{
			check_overflow_arg_type(p, args, i)!;
		}
	}
	else if (is_va_start_builtin(expanded.tag))
	{
		if (args.len > 1) check_va_start_arg(p, builtin_tok, args, 1)!;
		if (args.len > 2) check_va_start_arg(p, builtin_tok, args, 2)!;
	}
	// Non-custom builtins: the postfix call parser already coerced each typed
	// argument (and reported INCOMPATIBLE_ARG), as upstream callExpr does.

	type_store::QualType result_qt = return_type(p, expanded, args, fn_ty);
	type_store::NodeIndex node = p.tree.add_node({ .kind = tree::NodeKind.BUILTIN_CALL_EXPR,
		.builtin_call = { .builtin_tok = builtin_tok, .qt = result_qt, .args = args } });
	value::Value result = eval ? builtin_eval::eval(expanded, p, args) : value::NONE;
	return { .node = node, .qt = result_qt, .val = result };
}
