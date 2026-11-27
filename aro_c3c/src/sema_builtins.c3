// Port of c3c src/compiler/sema_builtins.c (revision 54bab366a): analysis of
// `$$builtin(...)` calls.
//
// Deviations from c3c:
// - `sema_expr_analyse_swizzle` is `sema_builtins_sema_expr_analyse_swizzle`
//   (clashes with the sema_expr.c static of the same name).
// - `sema_check_builtin_args` takes a `BuiltinArg[]` slice (c3c: a pointer
//   to a compound-literal array); sub-arrays `&args[n]` are `args[n..]`.
// - `utf8_to_codepoint` takes a `char*` (it reads the byte before
//   `data_ptr`, which a String parameter cannot express).
// - strstr / strlen-based searches (`$$str_find`, `$$str_replace`) work on
//   the String slices (`index_of`), so an embedded NUL does not end them.
// - ctype `isupper` / `islower` / `isdigit` / `isalnum` / `toupper` /
//   `tolower` use the ASCII char helpers.
// - The `%s` with a `Type*` argument in the `$$atomic_fetch_exchange` size
//   error (a c3c bug) prints `type_quoted_error_string(val)`.
// - `malloc_string` is an arena allocation (`calloc_arena`).
module aro::frontend::c3::compiler;
import aro::frontend::c3::tokens, std::math, libc;

enum BuiltinArg : char
{
	BA_POINTER,
	BA_SIZE,
	BA_BOOL,
	BA_CHAR,
	BA_FLOATLIKE,
	BA_INTEGER,
	BA_FLOAT,
	BA_INTLIKE,
	BA_NUMLIKE,
	BA_BOOLVEC,
	BA_BOOLINTVEC,
	BA_BOOLINT,
	BA_INTVEC,
	BA_FLOATVEC,
	BA_VEC,
	BA_NUMVEC,
	BA_PTRVEC,
	BA_NUM,
	BA_TYPEID,
}

// sema_builtins.c:42 (static)
fn bool sema_expr_is_valid_mask_for_value(SemaContext* context, Expr* expr, Expr* value)
{
	if (type_flatten(value.type).array.len != type_flatten(expr.type).array.len)
	{
		return @sema_error_at(context, expr.loc, "The mask must have the same length as the value.");
	}
	return true;
}

<* Used for when we have a builtin that has a constraint between argument types that they should be the same. *>
// sema_builtins.c:55 (static)
fn bool sema_check_builtin_args_match(SemaContext* context, Expr*[] args, usz arg_len)
{
	assert(arg_len > 1);
	Type* first = type_no_optional(args[0].type.canonical);
	for (usz i = 1; i < arg_len; i++)
	{
		if (first != type_no_optional(args[i].type.canonical))
		{
			return @sema_error_at(context, args[i].loc, "Expected an expression of type %s.", type_quoted_error_string(args[0].type));
		}
	}
	return true;
}

<* Check the constraint that the arguments are constant. *>
// sema_builtins.c:72 (static)
fn bool sema_check_builtin_args_const(SemaContext* context, Expr*[] args, usz arg_len)
{
	for (usz i = 0; i < arg_len; i++)
	{
		if (!sema_cast_const(args[i])) return @sema_error_at(context, args[i].loc, "Expected a compile time constant value for this argument.");
	}
	return true;
}

// sema_builtins.c:81 (static)
fn bool sema_check_alignment_expression(SemaContext* context, Expr* align, bool may_be_zero)
{
	if (!sema_analyse_expr_rhs(context, type_sz, align, false, null, false)) return false;
	if (!expr_is_const_int(align)
	    || !int_fits(align.const_expr.ixx, U64)
	    || (!is_power_of_two((ulong)align.const_expr.ixx.i) && (ulong)align.const_expr.ixx.i))
	{
		if (may_be_zero) return @sema_error_at(context, align.loc, "Expected a constant power-of-two alignment or zero.");
		return @sema_error_at(context, align.loc, "Expected a constant power-of-two alignment.");
	}
	if (int_is_neg(align.const_expr.ixx)) return @sema_error_at(context, align.loc, "Alignment must not be negative.");
	if (!may_be_zero && (ulong)align.const_expr.ixx.i == 0) return @sema_error_at(context, align.loc, "Alignment must not be zero.");
	if ((ulong)align.const_expr.ixx.i > (ulong)MAX_ALIGNMENT) return @sema_error_at(context, align.loc, "Alignment must be less or equal to %d.", (long)MAX_ALIGNMENT);
	return true;
}

// sema_builtins.c:96 (static)
fn bool sema_check_builtin_args(SemaContext* context, Expr*[] args, BuiltinArg[] arg_type, usz arg_len)
{
	for (usz i = 0; i < arg_len; i++)
	{
		Expr* arg = args[i];
		Type* type = type_flatten(arg.type.canonical);
		switch (arg_type[i])
		{
			case BA_POINTER:
				if (type_is_pointer(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected a pointer.");
			case BA_CHAR:
				if (type == type_char || type == type_ichar) continue;
				return @sema_error_at(context, arg.loc, "Expected a char or ichar.");
			case BA_SIZE:
				if (type_is_integer(type) && type_size(type) == type_size(type_usz)) continue;
				return @sema_error_at(context, arg.loc, "Expected an usz or sz value.");
			case BA_BOOL:
				if (type == type_bool) continue;
				return @sema_error_at(context, arg.loc, "Expected a bool.");
			case BA_NUM:
				if (type_is_number(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected an integer or a float.");
			case BA_TYPEID:
				if (type == type_typeid) continue;
				return @sema_error_at(context, arg.loc, "Expected a typeid.");
			case BA_NUMLIKE:
				if (type_flat_is_numlike(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected a number or vector.");
			case BA_FLOATLIKE:
				if (type_flat_is_floatlike(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected a floating point or floating point vector, but was %s.",
				                      type_quoted_error_string(type));
			case BA_VEC:
				if (type_kind_is_real_vector(type.type_kind)) continue;
				return @sema_error_at(context, arg.loc, "Expected a vector.");
			case BA_PTRVEC:
				if (type_is_pointer_vector(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected a pointer vector.");
			case BA_NUMVEC:
				if (type_kind_is_real_vector(type.type_kind) && type_is_number_or_bool(type.array.base)) continue;
				return @sema_error_at(context, arg.loc, "Expected a numeric vector.");
			case BA_INTVEC:
				if (type_kind_is_real_vector(type.type_kind) && type_flat_is_intlike(type.array.base)) continue;
				return @sema_error_at(context, arg.loc, "Expected an integer vector.");
			case BA_BOOLINT:
				if (type_is_integer_or_bool_kind(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected a boolean or integer value.");
			case BA_BOOLVEC:
				if (type_flat_is_bool_vector(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected a boolean vector.");
			case BA_BOOLINTVEC:
				if (type_kind_is_real_vector(type.type_kind) && type_flat_is_boolintlike(type.array.base)) continue;
				return @sema_error_at(context, arg.loc, "Expected a boolean or integer vector.");
			case BA_FLOATVEC:
				if (type_kind_is_real_vector(type.type_kind) && type_flat_is_floatlike(type.array.base)) continue;
				return @sema_error_at(context, arg.loc, "Expected an float vector.");
			case BA_INTLIKE:
				if (type_flat_is_intlike(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected an integer or integer vector.");
			case BA_INTEGER:
				if (type_is_integer(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected an integer.");
			case BA_FLOAT:
				if (type_is_float(type)) continue;
				return @sema_error_at(context, arg.loc, "Expected a float or double.");
		}
	}
	return true;
}

<* Analyse both $$swizzle and $$swizzle2 *>
// sema_builtins.c:171 (static), renamed from c3c `sema_expr_analyse_swizzle`
fn bool sema_builtins_sema_expr_analyse_swizzle(SemaContext* context, Expr* expr, bool swizzle_two)
{
	Expr*[] args = expr.call_expr.arguments;
	int arg_count = (int)args.len;
	bool optional = false;
	int first_mask_value = swizzle_two ? 2 : 1;
	for (int i = 0; i < first_mask_value; i++)
	{
		Expr* arg = args[i];
		// Analyse the expressions
		if (!sema_analyse_expr_rvalue(context, arg)) return false;
		// Expect vector
		if (!type_flat_is_vector(arg.type)) return @sema_error_at(context, arg.loc, "A vector was expected here.");
		// Optional-ness updated
		optional = optional || type_is_optional(args[i].type);
	}
	// Ensure matching types
	if (swizzle_two && !sema_check_builtin_args_match(context, args, 2)) return false;

	Type* flat = type_flatten(args[0].type);
	ArrayIndex components = flat.array.len;
	if (swizzle_two) components *= 2;
	for (int i = first_mask_value; i < arg_count; i++)
	{
		Expr* mask_val = args[i];
		if (!sema_analyse_expr_rhs(context, type_int, mask_val, false, null, false)) return false;
		if (!expr_is_const_int(mask_val))
		{
			return @sema_error_at(context, mask_val.loc, "The swizzle positions must be compile time constants.");
		}
		if ((ulong)mask_val.const_expr.ixx.i >= (ulong)components)
		{
			if (components == 1) return @sema_error_at(context, mask_val.loc, "The only possible swizzle position is 0.");
			return @sema_error_at(context, mask_val.loc, "The swizzle position must be in the range 0-%d.", (long)(components - 1));
		}
	}
	expr.type = type_add_optional(type_get_vector(type_get_indexed_type(args[0].type), flat.type_kind, arg_count - first_mask_value), optional);
	return true;
}

// sema_builtins.c:211 (static)
fn bool is_valid_atomicity(SemaContext* context, Expr* expr)
{
	if (!expr_is_const_int(expr) || !int_fits(expr.const_expr.ixx, U8) || (ulong)expr.const_expr.ixx.i > 6)
	{
		return @sema_error_at(context, expr.loc, "Expected a constant integer value < 7.");
	}
	return true;
}

// sema_builtins.c:221 (static)
fn bool sema_expr_analyse_compare_exchange(SemaContext* context, Expr* expr)
{
	Expr*[] args = expr.call_expr.arguments;
	Expr* pointer = args[0];

	if (!sema_analyse_expr_rvalue(context, pointer)) return false;

	bool optional = @is_optional(pointer);
	Type* comp_type = type_flatten(pointer.type);
	if (!type_is_pointer(comp_type)) return @sema_error_at(context, pointer.loc, "Expected a pointer here.");
	Type* pointee = comp_type.pointer;
	for (int i = 1; i < 3; i++)
	{
		Expr* arg = args[i];
		if (!sema_analyse_expr_rhs(context, type_is_void(pointee) ? null : pointee, arg, true, null, false)) return false;
		if (type_is_void(pointee)) pointee = arg.type.canonical;
		if (!type_is_atomic(type_flatten(arg.type)))
		{
			return @sema_error_at(context, arg.loc, "%s may not be used with atomics.", type_quoted_error_string(arg.type));
		}
		optional = optional || @is_optional(args[i]);
	}
	for (int i = 3; i < 5; i++)
	{
		if (!sema_analyse_expr_rhs(context, type_bool, args[i], false, null, false)) return false;
		if (!sema_cast_const(args[i]))
		{
			return @sema_error_at(context, args[i].loc, "Expected a constant boolean value.");
		}
	}
	for (int i = 5; i < 7; i++)
	{
		if (!sema_analyse_expr_rhs(context, type_char, args[i], false, null, false)) return false;
		if (!is_valid_atomicity(context, args[i])) return false;
	}
	uint success = (uint)(ulong)args[5].const_expr.ixx.i;
	uint failure = (uint)(ulong)args[6].const_expr.ixx.i;
	if (success < Atomicity.RELAXED.ordinal) return @sema_error_at(context, args[5].loc, "Success ordering must be at least RELAXED.");
	if (failure < Atomicity.RELAXED.ordinal) return @sema_error_at(context, args[6].loc, "Failure ordering must be at least RELAXED.");
	if (failure == Atomicity.ACQUIRE_RELEASE.ordinal || failure == Atomicity.RELEASE.ordinal)
	{
		return @sema_error_at(context, args[6].loc, "Failure ordering may not be RELEASE / ACQUIRE_RELEASE.");
	}
	Expr* align = args[7];
	if (!sema_check_alignment_expression(context, align, true)) return false;
	expr.type = type_add_optional(args[1].type, optional);
	return true;
}

// sema_builtins.c:269 (static)
fn bool sema_expr_analyse_syscall(SemaContext* context, Expr* expr)
{
	Expr*[] args = expr.call_expr.arguments;
	int arg_count = (int)args.len;
	if (arg_count > 7)
	{
		return @sema_error_at(context, args[7].loc, "Only 7 arguments supported for $$syscall.");
	}
	bool optional = false;
	for (int i = 0; i < arg_count; i++)
	{
		Expr* arg = args[i];
		if (!sema_analyse_expr_rhs(context, type_uptr, arg, true, null, false)) return false;
		optional = optional || type_is_optional(arg.type);
	}
	switch (compiler.platform.arch)
	{
		case AARCH64:
		case AARCH64_BE:
		case X86:
		case X86_64:
		case RISCV32:
		case RISCV64:
			break;
		default:
			return @sema_error_at(context, expr.loc, "Target does not support $$syscall.");
	}
	expr.type = type_add_optional(type_uptr, optional);
	return true;
}

// sema_builtins.c:300
fn ulong rand_u64()
{
	return ((ulong)libc::rand() << 48) ^ ((ulong)libc::rand() << 32) ^ ((ulong)libc::rand() << 16) ^ (ulong)libc::rand();
}

// sema_builtins.c:305
fn bool sema_expr_analyse_rnd(SemaContext* context, Expr* expr)
{
	ulong r = rand_u64();
	ulong mantissa = r >> 11;
	double val = (double)mantissa / (double)(1UL << 53); // Not secure random but...
	expr_rewrite_const_float(expr, type_double, val);
	return true;
}

// sema_builtins.c:314 (static)
fn bool sema_expr_analyse_str_replace(SemaContext* context, Expr* expr, Expr* arg, Expr* pattern, Expr* replace, Expr* limit)
{
	if (!sema_analyse_expr_rvalue(context, arg)) return false;
	if (!sema_cast_const(arg) || !expr_is_const_string(arg))
	{
		return @sema_error_at(context, arg.loc, "Expected a constant string replace a pattern in.");
	}
	if (!sema_analyse_expr_rvalue(context, pattern)) return false;
	if (!sema_cast_const(pattern) || !expr_is_const_string(pattern))
	{
		return @sema_error_at(context, pattern.loc, "Expected a constant pattern to replace.");
	}
	if (!sema_analyse_expr_rvalue(context, replace)) return false;
	if (!sema_cast_const(replace) || !expr_is_const_string(replace))
	{
		return @sema_error_at(context, replace.loc, "Expected a constant replacement string.");
	}
	if (!sema_analyse_expr_rvalue(context, limit)) return false;
	if (!sema_cast_const(limit) || !expr_is_const_int(limit))
	{
		return @sema_error_at(context, limit.loc, "Expected a constant limit.");
	}
	char* inner_str = arg.const_expr.bytes.ptr;
	ArrayIndex len = arg.const_expr.bytes.len;
	char* pattern_str = pattern.const_expr.bytes.ptr;
	ArrayIndex pattern_len = pattern.const_expr.bytes.len;
	String replace_str = (String)replace.const_expr.bytes.ptr[:replace.const_expr.bytes.len];
	String pattern_s = (String)pattern_str[:pattern_len];
	ArrayIndex limit_int = int_ucomp(limit.const_expr.ixx, (ulong)MAX_ARRAY_SIZE, GT) ? 0 : (ArrayIndex)(ulong)limit.const_expr.ixx.i;
	scratch_buffer_clear();
	ArrayIndex index = 0;
	if (limit_int == 0) limit_int = (ArrayIndex)MAX_ARRAY_SIZE;
	if (!pattern_len)
	{
		for (ArrayIndex i = 0; i <= len; i++)
		{
			if (limit_int)
			{
				scratch_buffer_append(replace_str);
				limit_int--;
			}
			if (i < len) scratch_buffer_append_char(inner_str[i]);
		}
		expr_rewrite_const_string_from_scratch(expr);
		return true;
	}
	while (index < len)
	{
		String rest = (String)inner_str[index:len - index];
		sz? found = rest.index_of(pattern_s);
		if (catch found)
		{
			scratch_buffer_append(rest);
			break;
		}
		scratch_buffer_append_len(inner_str + index, (usz)found);
		scratch_buffer_append(replace_str);
		index = index + (ArrayIndex)found + pattern_len;
		limit_int--;
		if (limit_int == 0)
		{
			scratch_buffer_append((String)inner_str[index:len - index]);
			break;
		}
	}
	expr_rewrite_const_string_from_scratch(expr);
	return true;
}

// sema_builtins.c:381 (static)
fn bool sema_expr_analyse_str_hash(SemaContext* context, Expr* expr)
{
	Expr* inner = expr.call_expr.arguments[0];
	if (!sema_analyse_expr_rvalue(context, inner)) return false;
	if (!expr_is_const_string(inner))
	{
		return @sema_error_at(context, inner.loc, "You need a compile time constant string to take the hash of it.");
	}
	uint hash = (uint)a5hash((String)inner.const_expr.bytes.ptr[:inner.const_expr.bytes.len], (uint)inner.const_expr.bytes.len, 0);
	expr_rewrite_const_int(expr, type_uint, hash);
	return true;
}

// sema_builtins.c:394
fn bool sema_expr_analyse_str_find(SemaContext* context, Expr* expr)
{
	Expr* inner = expr.call_expr.arguments[0];
	Expr* inner_find = expr.call_expr.arguments[1];
	if (!sema_analyse_expr_rvalue(context, inner) || !sema_analyse_expr_rvalue(context, inner_find)) return false;
	if (!expr_is_const_string(inner))
	{
		return @sema_error_at(context, inner.loc, "You need a compile time constant string to search.");
	}
	if (!expr_is_const_string(inner_find))
	{
		return @sema_error_at(context, inner_find.loc, "You need a compile time constant string to search for.");
	}
	String inner_str = (String)inner.const_expr.bytes.ptr[:inner.const_expr.bytes.len];
	String find_str = (String)inner_find.const_expr.bytes.ptr[:inner_find.const_expr.bytes.len];
	sz? ret = inner_str.index_of(find_str);
	long pos = -1;
	if (try r = ret) pos = (long)r;
	expr_rewrite_const_int(expr, type_sz, (ulong)pos);
	return true;
}

// sema_builtins.c:414
fn bool sema_expr_analyse_str_conv(SemaContext* context, Expr* expr, BuiltinFunction func)
{
	Expr* inner = expr.call_expr.arguments[0];
	if (!sema_analyse_expr_rvalue(context, inner)) return false;
	if (!expr_is_const_string(inner))
	{
		return @sema_error_at(context, inner.loc, "You need a compile time constant string to take convert.");
	}
	char* string = inner.const_expr.bytes.ptr;
	ArrayIndex len = inner.const_expr.bytes.len;
	// Empty string: no conversion
	if (!len)
	{
		expr_replace(expr, inner);
		return true;
	}
	char* new_string;
	if (func == STR_SNAKECASE)
	{
		int uppers = 0;
		for (ArrayIndex i = 0; i < len; i++)
		{
			if (char_is_upper(string[i])) uppers++;
		}
		new_string = calloc_arena((usz)(len + 1 + uppers));
	}
	else
	{
		new_string = calloc_arena((usz)(len + 1));
	}
	switch (func)
	{
		case STR_LOWER:
			for (ArrayIndex i = 0; i < len; i++)
			{
				char c = string[i];
				new_string[i] = (char)(char_is_upper(c) ? (c | 0x20) : c);
			}
		case STR_SNAKECASE:
		{
			usz index = 0;
			for (ArrayIndex i = 0; i < len; i++)
			{
				char c = string[i];
				if (char_is_upper(c))
				{
					if (i > 0 && ((char_is_lower(string[i - 1]) || char_is_digit(string[i - 1])) || (i < len - 1 && char_is_lower(string[i + 1]))))
					{
						new_string[index++] = '_';
					}
					new_string[index++] = c | 0x20;
					continue;
				}
				new_string[index++] = c;
			}
			len = (ArrayIndex)index;
		}
		case STR_PASCALCASE:
		{
			bool capitalize = true;
			usz j = 0;
			for (ArrayIndex i = 0; i < len; i++)
			{
				char c = string[i];
				if (!char_is_letter(c) && !char_is_digit(c))
				{
					capitalize = true;
					continue;
				}
				if (char_is_digit(c))
				{
					new_string[j++] = c;
					continue;
				}
				if (capitalize)
				{
					new_string[j++] = char_is_lower(c) ? (char)(c & ~0x20) : c;
					capitalize = false;
					continue;
				}
				new_string[j++] = char_is_upper(c) ? (char)(c | 0x20) : c;
			}
			len = (ArrayIndex)j;
		}
		case STR_UPPER:
			for (ArrayIndex i = 0; i < len; i++)
			{
				char c = string[i];
				new_string[i] = (char)(char_is_lower(c) ? (c & ~0x20) : c);
			}
		default:
			unreachable();
	}
	expr.expr_kind = CONST;
	expr.const_expr.const_kind = STRING;
	new_string[len] = 0;
	expr.const_expr.bytes.ptr = new_string;
	expr.const_expr.bytes.len = len;
	expr.resolve_status = DONE;
	expr.type = type_string;
	return true;
}

<*
 Interpret a UTF-8 codepoint and return an integer corresponding to the raw codepoint's value.
 data_ptr points just past the lead byte; inc is set to the number of bytes consumed.
*>
// sema_builtins.c:526 (static)
fn uint utf8_to_codepoint(char* data_ptr, int* inc)
{
	int bytes = 1;
	char* data = data_ptr;
	uint result = 0;

	assert(data);
	assert(inc);

	while ((0xC0 & *(data++)) == 0x80) ++bytes;
	data = data_ptr - 1;

	switch (bytes)
	{
		case 1: return (uint)(data[0] & 0x7FU);
		case 2:
			result = ((data[0] & 0x1FU) << 6U) | (data[1] & 0x3FU);
		case 3:
			result = ((data[0] & 0x0FU) << 12U) | ((data[1] & 0x3FU) << 6U) | (data[2] & 0x3FU);
		case 4:
			result = ((data[0] & 0x07U) << 18U) | ((data[1] & 0x3FU) << 12U) | ((data[2] & 0x3FU) << 6U) | (data[3] & 0x3FU);
		default: return 0;   // U+10FFFF is the highest codepoint in UTF-8, consisting of a maximum of 4 bytes.
	}

	*inc = bytes;
	return result;
}

// sema_builtins.c:556
fn bool sema_expr_analyse_str_wide(SemaContext* context, Expr* expr, BuiltinFunction func)
{
	Expr*[] args = expr.call_expr.arguments;
	Expr* inner = args[0];
	bool zero_terminate = true;
	int arg_count = (int)args.len;
	if (arg_count > 2)
	{
		return @sema_error_at(context, inner.loc, "Too many arguments, expected 1 or 2 arguments.");
	}
	if (arg_count == 2)
	{
		Expr* zero_term = args[1];
		if (!sema_analyse_expr_rvalue(context, zero_term)) return false;
		if (!sema_cast_const(zero_term) || !expr_is_const_bool(zero_term))
		{
			return @sema_error_at(context, zero_term.loc, "Expected a boolean value here, to determine zero termination or not.");
		}
		zero_terminate = zero_term.const_expr.b;
	}
	if (!sema_analyse_expr_rvalue(context, inner)) return false;
	if (!sema_cast_const(inner) || !expr_is_const_string(inner))
	{
		return @sema_error_at(context, inner.loc, "You need a compile time constant string to convert to a wide string.");
	}

	char* string = inner.const_expr.bytes.ptr;
	ArrayIndex original_len = inner.const_expr.bytes.len;

	Type* type = func == WIDESTRING_16 ? type_ushort : type_uint;
	ConstInitializer*[] elements = {};

	char* data = string;
	char* end = data + original_len;
	while (data < end)
	{
		char c = *(data++);
		if ((0xC0 & c) != 0xC0)
		{
			// ASCII
			Expr* value = expr_new_const_int(expr.loc, type, (ulong)(c & 0x7F));
			@vec_add(&elements, const_init_new_value(value));
			continue;
		}

		int increment = 0;
		uint from_codepoint = utf8_to_codepoint(data, &increment);
		data += (sz)(increment - 1);
		if (!from_codepoint)
		{
			return @sema_error_at(context, inner.loc, "Unparsable codepoint in string.");
		}
		if (type == type_ushort && (from_codepoint & 0xFFFF0000))
		{
			return @sema_error_at(context, inner.loc, "Invalid codepoint in string: a 16-bit wide-string cannot accommodate codepoints over U+FFFF.");
		}
		Expr* value = expr_new_const_int(expr.loc, type, from_codepoint);
		@vec_add(&elements, const_init_new_value(value));
	}
	if (zero_terminate) @vec_add(&elements, const_init_new_zero(type));

	Type* array_type = type_get_array(type, (ArrayIndex)elements.len);
	ConstInitializer* init = const_init_new_array_full(array_type, elements);
	expr_rewrite_const_initializer(expr, array_type, init);
	return true;
}

// sema_builtins.c:626 (static)
fn BinaryOp operator_from_builtin(BuiltinFunction fn_)
{
	switch (fn_)
	{
		case VECCOMPLT: return VEC_LT;
		case VECCOMPLE: return VEC_LE;
		case VECCOMPGT: return VEC_GT;
		case VECCOMPGE: return VEC_GE;
		case VECCOMPEQ: return VEC_EQ;
		case VECCOMPNE: return VEC_NE;
		default: unreachable();
	}
}

<* The atomic ordering checks shared by the $$atomic_fetch_* builtins (args 2..4). *>
macro bool @check_atomic_fetch_tail(SemaContext* context, Expr*[] args) @private
{
	if (!sema_cast_const(args[2])) return @sema_error_at(context, args[2].loc, "'is_volatile' must be a compile time constant.");
	if (!sema_cast_const(args[3])) return @sema_error_at(context, args[3].loc, "Ordering must be a compile time constant.");
	if (!is_valid_atomicity(context, args[3])) return false;
	if ((ulong)args[3].const_expr.ixx.i == Atomicity.UNORDERED.ordinal) return @sema_error_at(context, args[3].loc, "'unordered' is not valid ordering.");
	if (!sema_check_alignment_expression(context, args[4], true)) return false;
	return true;
}

// sema_builtins.c:640
fn bool sema_expr_analyse_builtin_call(SemaContext* context, Expr* expr)
{
	expr.call_expr.is_builtin = true;
	if (!sema_expand_vasplat_exprs(context, &expr.call_expr.arguments, null)) return false;
	Expr*[] args = expr.call_expr.arguments;
	BuiltinFunction func = exprptr(expr.call_expr.function).builtin_expr.builtin;
	int arg_count = (int)args.len;
	int expected_args = builtin_expected_args(func);
	bool expect_vararg = false;
	if (expected_args < 0)
	{
		expected_args = -expected_args;
		expect_vararg = true;
	}

	// 1. Handle arg count, so at least we know that is ok.
	if (arg_count < expected_args || (arg_count > expected_args && !expect_vararg))
	{
		if (arg_count == 0)
		{
			return @sema_error_at(context, expr.loc, "Expected %s%d arguments to builtin.", expect_vararg ? "at least " : "", expected_args);
		}
		if (arg_count < expected_args) return @sema_error_at(context, args[arg_count - 1].loc, "Expected more arguments after this one.");
		return @sema_error_at(context, args[expected_args].loc, "Too many arguments.");
	}

	for (int i = 0; i < arg_count; i++)
	{
		if (expr_is_named_param(args[i]))
		{
			return @sema_error_at(context, args[i].loc, "Named arguments are not allowed in builtin calls.");
		}
	}

	switch (func)
	{
		case SPRINTF:
			return sema_expr_analyse_sprintf(context, expr, args[0], args[1..], arg_count - 1);
		case RND:
			return sema_expr_analyse_rnd(context, expr);
		case STR_HASH:
			return sema_expr_analyse_str_hash(context, expr);
		case STR_REPLACE:
			return sema_expr_analyse_str_replace(context, expr, args[0], args[1], args[2], args[3]);
		case STR_UPPER:
		case STR_LOWER:
		case STR_PASCALCASE:
		case STR_SNAKECASE:
			return sema_expr_analyse_str_conv(context, expr, func);
		case STR_FIND:
			return sema_expr_analyse_str_find(context, expr);
		case SWIZZLE2:
		case SWIZZLE:
			return sema_builtins_sema_expr_analyse_swizzle(context, expr, func == SWIZZLE2);
		case SYSCALL:
			return sema_expr_analyse_syscall(context, expr);
		case UNREACHABLE:
			expr.call_expr.no_return = true;
			if (!context.call_env.in_no_eval) set_jump_end(context, expr.loc);
			nextcase BREAKPOINT;
		case BREAKPOINT:
		case TRAP:
			expr.type = type_void;
			return true;
		case SYSCLOCK:
			expr.type = type_ulong;
			return true;
		case GET_ROUNDING_MODE:
			expr.type = type_int;
			return true;
		case COMPARE_EXCHANGE:
			return sema_expr_analyse_compare_exchange(context, expr);
		case WIDESTRING_16:
		case WIDESTRING_32:
			return sema_expr_analyse_str_wide(context, expr, func);
		default:
			break;
	}

	bool optional = false;

	// 2. We can now check all the arguments, since they in general work on the
	//    exact type size, we don't do any forced promotion.
	for (int i = 0; i < arg_count; i++)
	{
		if (!sema_analyse_expr_rvalue(context, args[i])) return false;
		optional = optional || type_is_optional(args[i].type);
	}

	Type* rtype = null;
	switch (func)
	{
		case SET_ROUNDING_MODE:
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_INTEGER }, 1)) return false;
			rtype = type_void;
		case SYSCALL:
		case STR_HASH:
		case STR_UPPER:
		case STR_LOWER:
		case STR_PASCALCASE:
		case STR_SNAKECASE:
		case STR_FIND:
		case STR_REPLACE:
		case WIDESTRING_16:
		case WIDESTRING_32:
		case SPRINTF:
			unreachable();
		case VECCOMPGE:
		case VECCOMPEQ:
		case VECCOMPLE:
		case VECCOMPGT:
		case VECCOMPLT:
		case VECCOMPNE:
		{
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_NUMVEC, BA_NUMVEC }, 2)) return false;
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			rtype = type_get_vector_from_vector(type_bool, type_flatten(args[0].type));
			expr.expr_kind = BINARY;
			expr.binary_expr = {
				.left = exprid(args[0]),
				.right = exprid(args[1]),
				.operator = operator_from_builtin(func)
			};
		}
		case SELECT:
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args, { BA_BOOLVEC, BA_VEC, BA_VEC }, 3)) return false;
			if (!sema_check_builtin_args_match(context, args[1..], 2)) return false;
			rtype = args[1].type;
			if (!sema_expr_is_valid_mask_for_value(context, args[0], args[1])) return false;
		case OVERFLOW_ADD:
		case OVERFLOW_MUL:
		case OVERFLOW_SUB:
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args,
			                             { BA_INTLIKE, BA_INTLIKE, BA_POINTER },
			                             3)) return false;
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			if (type_no_optional(args[0].type.canonical) != type_no_optional(args[2].type.canonical.pointer))
			{
				return @sema_error_at(context, args[2].loc, "Expected %s, not %s.",
				                      type_to_error_string(type_get_ptr(args[0].type)),
				                      type_to_error_string(args[2].type));
			}
			Type* flat_0 = type_flatten(args[0].type);
			if (type_kind_is_real_vector(flat_0.type_kind))
			{
				rtype = type_get_vector_from_vector(type_bool, flat_0);
				break;
			}
			rtype = type_bool;
		case EXACT_ADD:
		case EXACT_DIV:
		case EXACT_MUL:
		case EXACT_SUB:
		case EXACT_MOD:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_INTEGER, BA_INTEGER }, 2)) return false;
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			rtype = args[0].type.canonical;
		case ANY_MAKE:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_TYPEID }, 2)) return false;
			expr.expr_kind = MAKE_ANY;
			expr.make_any_expr = {
				.inner = args[0],
				.typeid_expr = args[1]
			};
			expr.type = type_add_optional(type_any, optional);
			return true;
		case EXACT_NEG:
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_INTLIKE }, 1)) return false;
			rtype = args[0].type.canonical;
		case MEMCOPY_INLINE:
			assert(arg_count == 6);
			if (!sema_check_builtin_args(context, args,
			                             { BA_POINTER, BA_POINTER, BA_SIZE, BA_BOOL, BA_SIZE, BA_SIZE },
			                             6)) return false;
			if (!sema_check_builtin_args_const(context, args[2..], 4)) return false;
			if (!sema_check_alignment_expression(context, args[4], true)) return false;
			if (!sema_check_alignment_expression(context, args[5], true)) return false;
			rtype = type_void;
		case MEMCOPY:
		case MEMMOVE:
			assert(arg_count == 6);
			if (!sema_check_builtin_args(context, args,
			                             { BA_POINTER, BA_POINTER, BA_SIZE, BA_BOOL, BA_SIZE, BA_SIZE },
			                             6)) return false;
			if (!sema_check_builtin_args_const(context, args[3..], 3)) return false;
			if (!sema_check_alignment_expression(context, args[4], true)) return false;
			if (!sema_check_alignment_expression(context, args[5], true)) return false;
			rtype = type_void;
		case MEMSET:
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_CHAR, BA_SIZE, BA_BOOL, BA_SIZE },
			                             5)) return false;
			if (!sema_check_builtin_args_const(context, args[3..], 2)) return false;
			if (!sema_check_alignment_expression(context, args[4], true)) return false;
			rtype = type_void;
		case MEMSET_INLINE:
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_CHAR, BA_SIZE, BA_BOOL, BA_SIZE },
			                             5)) return false;
			if (!sema_check_builtin_args_const(context, args[2..], 3)) return false;
			if (!sema_check_alignment_expression(context, args[4], true)) return false;
			rtype = type_void;
		case BITREVERSE:
		case BSWAP:
		case CTLZ:
		case POPCOUNT:
		case CTTZ:
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_INTLIKE }, 1)) return false;
			rtype = args[0].type;
			if (func == BSWAP
				&& (type_size(rtype) == 1
					|| (type_flat_is_vector(rtype) && type_size(type_flatten(rtype).array.base) == 1)))
			{
				expr_replace(expr, args[0]);
			}
		case MATRIX_TRANSPOSE:
		{
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args, { BA_VEC, BA_INTEGER, BA_INTEGER }, 3)) return false;
			if (!sema_check_builtin_args_const(context, args[1..], 2)) return false;
			ArrayIndex vec_len = type_flatten(args[0].type).array.len;
			if (!cast_implicit(context, args[2], args[1].type, false)) return false;
			Int sum = int_mul(args[1].const_expr.ixx, args[2].const_expr.ixx);
			if (!int_icomp(sum, vec_len, EQ))
			{
				return @sema_error_at(context, args[1].loc, "Expected row * col to equal %d.", (long)vec_len);
			}
			rtype = args[0].type;
		}
		case MATRIX_MUL:
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_VEC, BA_VEC, BA_INTEGER, BA_INTEGER, BA_INTEGER }, 5)) return false;
			if (!sema_check_builtin_args_const(context, args[2..], 3)) return false;
			Type* flat1 = type_flatten(args[0].type);
			Type* flat2 = type_flatten(args[1].type);
			if (flat1.array.base != flat2.array.base)
			{
				return @sema_error_at(context, args[1].loc, "Expected both matrices to be of the same type.");
			}
			ArrayIndex vec_len1 = flat1.array.len;
			ArrayIndex vec_len2 = flat2.array.len;
			uint128 sum = i128_mult(args[2].const_expr.ixx.i, args[3].const_expr.ixx.i);
			args[2].type = type_int;
			args[3].type = type_int;
			if ((sum >> 64) != 0 || (ArrayIndex)(ulong)sum != vec_len1)
			{
				return @sema_error_at(context, args[3].loc, "Expected outer row * inner to equal %d.", (long)vec_len1);
			}
			sum = i128_mult(args[3].const_expr.ixx.i, args[4].const_expr.ixx.i);
			if ((sum >> 64) != 0 || (ArrayIndex)(ulong)sum != vec_len2)
			{
				return @sema_error_at(context, args[4].loc, "Expected inner * outer col to equal %d.", (long)vec_len2);
			}
			rtype = type_get_vector(flat1.array.base, flat1.type_kind, (int)(ulong)i128_mult(args[2].const_expr.ixx.i, args[4].const_expr.ixx.i));
		case SAT_SHL:
		case SAT_SUB:
		case SAT_ADD:
		case SAT_MUL:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_INTLIKE, BA_INTLIKE }, 2)) return false;
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			rtype = args[0].type;
		case REVERSE:
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_VEC }, 1)) return false;
			rtype = args[0].type;
		case EXPECT:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_BOOLINT, BA_BOOLINT }, 2)) return false;
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			rtype = args[0].type;
		case EXPECT_WITH_PROBABILITY:
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args, { BA_BOOLINT, BA_BOOLINT }, 2)) return false;
			if (!cast_implicit(context, args[2], type_double, false))
			{
				return @sema_error_at(context, args[2].loc, "Expected a 'double', but was %s.", type_quoted_error_string(args[2].type));
			}
			if (!sema_cast_const(args[2]))
			{
				return @sema_error_at(context, args[2].loc, "This value must be a constant.");
			}
			Real r = args[2].const_expr.fxx.f;
			if (r < 0 || r > 1) return @sema_error_at(context, args[2].loc, "The probability must be between 0 and 1.");
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			rtype = args[0].type;
		case ACOS:
		case ASIN:
		case ATAN:
		case CEIL:
		case COPYSIGN:
		case COS:
		case COSH:
		case EXP:
		case EXP2:
		case EXP10:
		case FLOOR:
		case LLRINT:
		case LLROUND:
		case LOG:
		case LOG2:
		case LOG10:
		case LRINT:
		case LROUND:
		case NEARBYINT:
		case RINT:
		case ROUND:
		case ROUNDEVEN:
		case SIN:
		case SINH:
		case TAN:
		case TANH:
		case SQRT:
		case TRUNC:
			assert(arg_count);
			if (!sema_check_builtin_args(context, args, { BA_FLOATLIKE, BA_FLOATLIKE, BA_FLOATLIKE },
			                             (usz)arg_count)) return false;
			rtype = args[0].type;
			if (func == CEIL && expr_is_const_float(args[0]))
			{
				expr_rewrite_const_float(expr, rtype, math::ceil(args[0].const_expr.fxx.f));
				return true;
			}
		case FRAMEADDRESS:
		case RETURNADDRESS:
			assert(arg_count);
			if (!sema_check_builtin_args(context, args, { BA_INTEGER }, (usz)arg_count)) return false;
			if (!cast_implicit(context, args[0], type_int, false)) return false;
			if (!expr_is_const_int(args[0])) return @sema_error_at(context, args[0].loc, "Expected a compile time constant integer.");
			rtype = type_voidptr;
		case WASM_MEMORY_SIZE:
			assert(arg_count == 1);
			if (!cast_implicit(context, args[0], type_int, false)) return false;
			rtype = type_sz;
		case WASM_MEMORY_GROW:
			assert(arg_count == 2);
			if (!cast_implicit(context, args[0], type_int, false)) return false;
			if (!cast_implicit(context, args[1], type_sz, false)) return false;
			rtype = type_iptr;
		case PREFETCH:
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_INTEGER, BA_INTEGER }, 3)) return false;
			for (int i = 1; i < 3; i++)
			{
				if (!sema_cast_const(args[i])) return @sema_error_at(context, args[i].loc, "A constant value is required.");
				if (!cast_implicit(context, args[i], type_int, false)) return false;
			}
			if (!expr_in_int_range(args[1], 0, 1))
			{
				@sema_error_at(context, args[1].loc, "Expected a value between 0 and 1.");
				return false;
			}
			if (!expr_in_int_range(args[2], 0, 3))
			{
				@sema_error_at(context, args[2].loc, "Expected a value between 0 and 3.");
				return false;
			}
			if (!cast_implicit(context, args[0], type_voidptr, false)) return false;
			rtype = type_void;
		case POW:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_FLOATLIKE, BA_FLOATLIKE }, 2)) return false;
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			rtype = args[0].type;
		case POW_INT:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_FLOATLIKE, BA_INTLIKE }, 2)) return false;
			if (!cast_implicit(context, args[1], type_cint, false)) return false;
			rtype = args[0].type;
		case REDUCE_FMUL:
		case REDUCE_FADD:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_FLOATVEC, BA_FLOAT }, 2)) return false;
			if (!cast_implicit(context, args[1], args[0].type.canonical.array.base, false)) return false;
			{
				Expr* arg = args[0];
				args[0] = args[1];
				args[1] = arg;
			}
			rtype = args[0].type;
		case REDUCE_MAX:
		case REDUCE_MIN:
		{
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_NUMVEC }, 1)) return false;
			rtype = type_get_indexed_type(args[0].type);
		}
		case REDUCE_ADD:
		case REDUCE_AND:
		case REDUCE_OR:
		case REDUCE_XOR:
		case REDUCE_MUL:
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_BOOLINTVEC }, 1)) return false;
			rtype = type_get_indexed_type(args[0].type);
		case ABS:
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_NUMLIKE }, 1)) return false;
			rtype = args[0].type;
		case GATHER:
		{
			assert(arg_count == 4);
			if (!sema_check_builtin_args(context, args, { BA_PTRVEC, BA_BOOLVEC, BA_VEC, BA_INTEGER }, 4)) return false;
			Type* flat_pointer_vec = type_flatten(args[0].type);
			Type* flat_passthru_vec = type_flatten(args[2].type);
			Type* pointer_type = flat_pointer_vec.array.base;
			ArrayIndex len = flat_pointer_vec.array.len;
			if (pointer_type.pointer.canonical != flat_passthru_vec.array.base.canonical)
			{
				return @sema_error_at(context, args[2].loc, "Expected the vector to have elements of type %s.", type_quoted_error_string(pointer_type.pointer));
			}
			if (len != flat_passthru_vec.array.len)
			{
				return @sema_error_at(context, args[2].loc, "Expected the vector to be %s, not %s.",
				                      type_quoted_error_string(
				                              type_get_vector(pointer_type.pointer, flat_pointer_vec.type_kind, (int)len)),
				                      type_quoted_error_string(args[2].type));
			}
			if (!sema_check_alignment_expression(context, args[3], true)) return false;
			if (!sema_expr_is_valid_mask_for_value(context, args[1], args[2])) return false;
			rtype = type_get_vector(pointer_type.pointer, flat_pointer_vec.type_kind, (int)len);
		}
		case SCATTER:
		{
			assert(arg_count == 4);
			if (!sema_check_builtin_args(context, args, { BA_PTRVEC, BA_VEC, BA_BOOLVEC, BA_INTEGER }, 4)) return false;
			Type* flat_pointer_vec = type_flatten(args[0].type);
			Type* flat_value_vec = type_flatten(args[1].type);
			Type* pointer_type = flat_pointer_vec.array.base;
			if (pointer_type.pointer.canonical != flat_value_vec.array.base.canonical)
			{
				return @sema_error_at(context, args[1].loc, "Expected the vector to have elements of type %s.", type_quoted_error_string(pointer_type.pointer));
			}
			if (flat_pointer_vec.array.len != flat_value_vec.array.len)
			{
				return @sema_error_at(context, args[1].loc, "Expected the vector to be %s, not %s.",
				                      type_quoted_error_string(
				                              type_get_vector_from_vector(pointer_type.pointer, flat_pointer_vec)),
				                      type_quoted_error_string(args[2].type));
			}
			if (!sema_check_alignment_expression(context, args[3], true)) return false;
			if (!sema_expr_is_valid_mask_for_value(context, args[2], args[1])) return false;
			rtype = type_void;
		}
		case INT_TO_MASK:
		{
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_INTEGER, BA_INTEGER }, 2)) return false;
			Expr* len = args[1];
			if (!sema_cast_const(len) || !expr_is_const_int(len))
			{
				return @sema_error_at(context, len.loc, "Expected constant integer for the vector length.");
			}
			Type* type = type_flatten(args[0].type);
			int size = (int)type_bit_size(type);
			if (int_icomp(len.const_expr.ixx, size, GT))
			{
				return @sema_error_at(context, args[1].loc, "The vector length (%s) cannot be greater than the bit width of the integer (%d).",
				                      int_to_str(len.const_expr.ixx, 10, false), size);
			}
			int bits = (int)(ulong)len.const_expr.ixx.i;
			if (!bits)
			{
				return @sema_error_at(context, args[1].loc, "The vector length cannot be zero");
			}
			rtype = type_get_vector(type_bool, VECTOR, bits);
		}
		case MASK_TO_INT:
		{
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_BOOLVEC }, 1)) return false;
			Type* vec = type_flatten(args[0].type);
			ArrayIndex len = vec.array.len;
			if (len > 128)
			{
				return @sema_error_at(context, args[0].loc, "Masks must be 128 or fewer bits to convert them to an integer.");
			}
			if (len < 8) len = 8;
			rtype = type_int_unsigned_by_bitsize(next_highest_power_of_2((uint)len));
		}
		case MASKED_LOAD:
		{
			assert(arg_count == 4);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_BOOLVEC, BA_VEC, BA_INTEGER }, 4)) return false;
			Type* pointer_type = args[0].type;
			if (!type_is_pointer(pointer_type)) return @sema_error_at(context, args[0].loc, "Expected a direct pointer.");
			if (pointer_type.pointer.canonical != args[2].type.canonical)
			{
				return @sema_error_at(context, args[2].loc, "Expected the value to be of type %s.", type_quoted_error_string(pointer_type.pointer));
			}
			if (!sema_check_alignment_expression(context, args[3], true)) return false;
			if (!sema_expr_is_valid_mask_for_value(context, args[1], args[2])) return false;
			rtype = pointer_type.pointer;
		}
		case MASKED_STORE:
		{
			assert(arg_count == 4);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_VEC, BA_BOOLVEC, BA_INTEGER }, 4)) return false;
			Type* pointer_type = args[0].type;
			if (!type_is_pointer(pointer_type)) return @sema_error_at(context, args[0].loc, "Expected a direct pointer.");
			if (pointer_type.pointer.canonical != args[1].type.canonical)
			{
				return @sema_error_at(context, args[1].loc, "Expected the value to be of type %s.", type_quoted_error_string(pointer_type.pointer));
			}
			if (!sema_check_alignment_expression(context, args[3], true)) return false;
			if (!sema_expr_is_valid_mask_for_value(context, args[2], args[1])) return false;
			rtype = type_void;
		}
		case MAX:
		case MIN:
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_NUMLIKE, BA_NUMLIKE }, 2)) return false;
			if (!sema_check_builtin_args_match(context, args, 2)) return false;
			rtype = args[0].type;
		case FMA:
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args,
			                             { BA_FLOATLIKE, BA_FLOATLIKE, BA_FLOATLIKE },
			                             3)) return false;
			if (!sema_check_builtin_args_match(context, args, 3)) return false;
			rtype = args[0].type;
		case FSHL:
		case FSHR:
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args, { BA_INTLIKE, BA_INTLIKE, BA_INTLIKE },
			                             3)) return false;
			if (!sema_check_builtin_args_match(context, args, 3)) return false;
			rtype = args[0].type;
		case FMULADD:
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args, { BA_FLOAT, BA_FLOAT, BA_FLOAT },
			                             3)) return false;
			if (!sema_check_builtin_args_match(context, args, 3)) return false;
			rtype = args[0].type;
		case FENCE:
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_INTEGER }, 1)) return false;
			if (!sema_cast_const(args[0])) return @sema_error_at(context, args[0].loc, "Ordering must be a compile time constant.");
			if (!is_valid_atomicity(context, args[0])) return false;
			ulong ordering = (ulong)args[0].const_expr.ixx.i;
			if (ordering == Atomicity.NONE.ordinal || ordering == Atomicity.RELAXED.ordinal || ordering == Atomicity.UNORDERED.ordinal)
			{
				return @sema_error_at(context, args[0].loc, "'none', 'relaxed' and 'unordered' are not valid for fence.");
			}
			rtype = type_void;
		case ATOMIC_LOAD:
		{
			assert(arg_count == 4);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_BOOL, BA_INTEGER, BA_INTEGER }, 4)) return false;
			Type* original = type_flatten(args[0].type);
			if (original == type_voidptr) return @sema_error_at(context, args[0].loc, "Expected a typed pointer.");
			if (!sema_cast_const(args[1])) return @sema_error_at(context, args[1].loc, "'is_volatile' must be a compile time constant.");
			if (!sema_cast_const(args[2])) return @sema_error_at(context, args[2].loc, "Ordering must be a compile time constant.");
			if (!is_valid_atomicity(context, args[2])) return false;
			if (arg_count == 4) if (!sema_check_alignment_expression(context, args[3], true)) return false;
			ulong ordering = (ulong)args[2].const_expr.ixx.i;
			if (ordering == Atomicity.ACQUIRE_RELEASE.ordinal || ordering == Atomicity.RELEASE.ordinal)
			{
				return @sema_error_at(context, args[2].loc, "'release' and 'acquire release' are not valid for atomic loads.");
			}
			rtype = original.pointer;
		}
		case UNALIGNED_LOAD:
		{
			assert(arg_count == 3);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_INTEGER, BA_BOOL }, 3)) return false;
			Type* original = type_flatten(args[0].type);
			if (original == type_voidptr) return @sema_error_at(context, args[0].loc, "Expected a typed pointer.");
			if (!sema_check_alignment_expression(context, args[1], false)) return false;
			if (!sema_cast_const(args[2])) return @sema_error_at(context, args[2].loc, "'is_volatile' must be a compile time constant.");
			rtype = original.pointer;
		}
		case UNALIGNED_STORE:
		{
			assert(arg_count == 4);
			if (!sema_check_builtin_args(context, args, { BA_POINTER }, 1)) return false;
			if (!sema_check_builtin_args(context, args[2..], { BA_INTEGER, BA_BOOL }, 2)) return false;
			Type* original = type_flatten(args[0].type);
			if (!sema_check_alignment_expression(context, args[2], false)) return false;
			if (!sema_cast_const(args[3])) return @sema_error_at(context, args[3].loc, "'is_volatile' must be a compile time constant.");
			if (original != type_voidptr)
			{
				if (!cast_implicit(context, args[1], original.pointer, false)) return false;
			}
			rtype = args[1].type;
		}
		case VOLATILE_LOAD:
		{
			assert(arg_count == 1);
			if (!sema_check_builtin_args(context, args, { BA_POINTER }, 1)) return false;
			Type* original = type_flatten(args[0].type);
			if (original == type_voidptr) return @sema_error_at(context, args[0].loc, "Expected a typed pointer.");
			rtype = original.pointer;
		}
		case VOLATILE_STORE:
		{
			assert(arg_count == 2);
			if (!sema_check_builtin_args(context, args, { BA_POINTER }, 1)) return false;
			Type* original = type_flatten(args[0].type);
			if (original != type_voidptr)
			{
				if (!cast_implicit(context, args[1], original.pointer, false)) return false;
			}
			rtype = args[1].type;
		}
		case ATOMIC_FETCH_INC_WRAP:
		case ATOMIC_FETCH_DEC_WRAP:
		{
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_INTEGER }, 2)) return false;
			Type* original = type_flatten(args[0].type);
			Type* val = type_flatten(args[1].type);
			if (!type_is_unsigned(val))
			{
				return @sema_error_at(context, args[1].loc, "Expected an unsigned integer.");
			}
			if (original != type_voidptr)
			{
				Type* pointer = type_flatten(original.pointer);
				if (!type_is_unsigned(pointer))
				{
					return @sema_error_at(context, args[0].loc, "Expected a pointer to an unsigned integer.");
				}
				if (!cast_implicit(context, args[1], original.pointer, false)) return false;
			}
			if (!@check_atomic_fetch_tail(context, args)) return false;
			rtype = args[1].type;
		}
		case ATOMIC_FETCH_AND:
		case ATOMIC_FETCH_NAND:
		case ATOMIC_FETCH_OR:
		case ATOMIC_FETCH_XOR:
		{
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_BOOLINT }, 2)) return false;
			Type* original = type_flatten(args[0].type);
			if (original != type_voidptr)
			{
				if (!cast_implicit(context, args[1], original.pointer, false)) return false;
			}
			if (!@check_atomic_fetch_tail(context, args)) return false;
			rtype = args[1].type;
		}
		case ATOMIC_FETCH_EXCHANGE:
		{
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_POINTER }, 1)) return false;
			Type* original = type_flatten(args[0].type);
			if (original != type_voidptr)
			{
				if (!cast_implicit(context, args[1], original.pointer, false)) return false;
			}
			Type* val = type_flatten(args[1].type);
			if (!type_is_atomic(val)) return @sema_error_at(context, args[1].loc, "%s exceeds pointer size.", type_quoted_error_string(val));
			if (!@check_atomic_fetch_tail(context, args)) return false;
			rtype = args[1].type;
		}
		case ATOMIC_FETCH_ADD:
		case ATOMIC_FETCH_SUB:
		case ATOMIC_FETCH_MAX:
		case ATOMIC_FETCH_MIN:
		{
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_POINTER, BA_NUM }, 2)) return false;
			Type* original = type_flatten(args[0].type);
			if (original != type_voidptr)
			{
				if (!cast_implicit(context, args[1], original.pointer, false)) return false;
			}
			if (!@check_atomic_fetch_tail(context, args)) return false;
			rtype = args[1].type;
		}
		case ATOMIC_STORE:
		{
			assert(arg_count == 5);
			if (!sema_check_builtin_args(context, args, { BA_POINTER }, 1)) return false;
			if (!sema_check_builtin_args(context, args[2..], { BA_BOOL, BA_INTEGER }, 2)) return false;
			Type* original = type_flatten(args[0].type);
			if (original != type_voidptr)
			{
				if (!cast_implicit(context, args[1], original.pointer, false)) return false;
			}
			if (!sema_cast_const(args[2])) return @sema_error_at(context, args[2].loc, "'is_volatile' must be a compile time constant.");
			if (!sema_cast_const(args[3])) return @sema_error_at(context, args[3].loc, "Ordering must be a compile time constant.");
			if (!is_valid_atomicity(context, args[3])) return false;
			if (!sema_check_alignment_expression(context, args[4], true)) return false;
			ulong ordering = (ulong)args[3].const_expr.ixx.i;
			if (ordering == Atomicity.ACQUIRE_RELEASE.ordinal || ordering == Atomicity.ACQUIRE.ordinal)
			{
				return @sema_error_at(context, args[3].loc, "'acquire' and 'acquire release' are not valid for atomic stores.");
			}
			rtype = args[1].type;
		}
		case NONE:
		case COMPARE_EXCHANGE:
		case GET_ROUNDING_MODE:
		case SWIZZLE:
		case SWIZZLE2:
		case SYSCLOCK:
		case TRAP:
		case BREAKPOINT:
		case UNREACHABLE:
		case RND:
			unreachable();
	}
	expr.type = type_add_optional(rtype, optional);
	return true;
}

// sema_builtins.c:1434 (static)
fn int builtin_expected_args(BuiltinFunction func)
{
	switch (func)
	{
		case SPRINTF:
		case SYSCALL:
		case WIDESTRING_16:
		case WIDESTRING_32:
			return -1;
		case SWIZZLE:
			return -2;
		case SWIZZLE2:
			return -3;
		case GET_ROUNDING_MODE:
		case SYSCLOCK:
		case TRAP:
		case BREAKPOINT:
		case UNREACHABLE:
		case RND:
			return 0;
		case ABS:
		case ACOS:
		case ASIN:
		case ATAN:
		case BITREVERSE:
		case BSWAP:
		case CEIL:
		case COS:
		case COSH:
		case CTLZ:
		case CTTZ:
		case EXACT_NEG:
		case EXP:
		case EXP2:
		case EXP10:
		case FENCE:
		case FLOOR:
		case FRAMEADDRESS:
		case LLRINT:
		case LLROUND:
		case LOG:
		case LOG2:
		case LOG10:
		case LRINT:
		case LROUND:
		case MASK_TO_INT:
		case NEARBYINT:
		case POPCOUNT:
		case REDUCE_ADD:
		case REDUCE_AND:
		case REDUCE_MAX:
		case REDUCE_MIN:
		case REDUCE_MUL:
		case REDUCE_OR:
		case REDUCE_XOR:
		case RETURNADDRESS:
		case REVERSE:
		case RINT:
		case ROUND:
		case ROUNDEVEN:
		case SET_ROUNDING_MODE:
		case SIN:
		case SINH:
		case SQRT:
		case STR_HASH:
		case STR_LOWER:
		case STR_PASCALCASE:
		case STR_SNAKECASE:
		case STR_UPPER:
		case TAN:
		case TANH:
		case TRUNC:
		case VOLATILE_LOAD:
		case WASM_MEMORY_SIZE:
			return 1;
		case VOLATILE_STORE:
		case ANY_MAKE:
		case COPYSIGN:
		case EXACT_ADD:
		case EXACT_DIV:
		case EXACT_MOD:
		case EXACT_MUL:
		case EXACT_SUB:
		case EXPECT:
		case INT_TO_MASK:
		case MAX:
		case MIN:
		case POW:
		case POW_INT:
		case REDUCE_FADD:
		case REDUCE_FMUL:
		case SAT_ADD:
		case SAT_MUL:
		case SAT_SHL:
		case SAT_SUB:
		case STR_FIND:
		case VECCOMPEQ:
		case VECCOMPGE:
		case VECCOMPGT:
		case VECCOMPLE:
		case VECCOMPLT:
		case VECCOMPNE:
		case WASM_MEMORY_GROW:
			return 2;
		case EXPECT_WITH_PROBABILITY:
		case FMA:
		case FSHL:
		case FSHR:
		case FMULADD:
		case OVERFLOW_ADD:
		case OVERFLOW_MUL:
		case OVERFLOW_SUB:
		case PREFETCH:
		case UNALIGNED_LOAD:
		case SELECT:
		case MATRIX_TRANSPOSE:
			return 3;
		case ATOMIC_LOAD:
		case MASKED_STORE:
		case MASKED_LOAD:
		case GATHER:
		case SCATTER:
		case STR_REPLACE:
		case UNALIGNED_STORE:
			return 4;
		case ATOMIC_STORE:
		case ATOMIC_FETCH_EXCHANGE:
		case ATOMIC_FETCH_ADD:
		case ATOMIC_FETCH_INC_WRAP:
		case ATOMIC_FETCH_NAND:
		case ATOMIC_FETCH_AND:
		case ATOMIC_FETCH_OR:
		case ATOMIC_FETCH_XOR:
		case ATOMIC_FETCH_MAX:
		case ATOMIC_FETCH_MIN:
		case ATOMIC_FETCH_SUB:
		case ATOMIC_FETCH_DEC_WRAP:
		case MATRIX_MUL:
			return 5;
		case MEMCOPY:
		case MEMCOPY_INLINE:
		case MEMMOVE:
			return 6;
		case MEMSET:
		case MEMSET_INLINE:
			return 5;
		case COMPARE_EXCHANGE:
			return 8;
		case NONE:
			unreachable();
	}
}
