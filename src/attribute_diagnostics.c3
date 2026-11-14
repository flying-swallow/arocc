// Port of src/aro/Attribute/Diagnostic.zig: wording, severity and
// warning-option association of every attribute diagnostic.
module aro::attribute_diagnostics;
import aro::diagnostics;

<*
 Zig `Attribute.Diagnostic`. `fmt` is C3 printf syntax, except `{at}`, which `Wip.emit` replaces with the quoted name of the attribute being reported before formatting.
*>
enum AttrDiag : ushort (String fmt, MessageKind kind, DiagMeta meta)
{
	UNIMPLEMENTED { "TODO: implement {at} attribute", WARNING, {} },
	ARG_COUNT_ZERO { "{at} attribute takes no arguments", ERROR, {} },
	ARG_COUNT_ONE { "{at} attribute takes one argument", ERROR, {} },
	ARG_COUNT { "{at} attribute takes %d arguments", ERROR, {} },
	NOT_ENOUGH_ARGS { "{at} attribute takes at least %d argument(s)", ERROR, {} },
	TOO_MANY_ARGS { "{at} attribute takes at most %d argument(s)", ERROR, {} },
	ARG_TYPE { "expected %s as argmuent of {at} attribute but got %s", ERROR, {} },
	ARG_INT_OUT_OF_RANGE { "attribute {at} argument value '%s' out of range", ERROR, {} },
	ARG_REQUIRES_STRING { "expected string literal as argmuent of {at} attribute", ERROR, {} },
	UNKNOWN_ENUM { "unknown {at} argument. Possible values are: %s", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	INVALID_TARGET { "{at} attribute only applies to %s", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	INCOMPATIBLE_ATTR { "{at} and %s attributes are not compatible", ERROR, {} },
	INVALID_STMT_ATTR { "{at} attribute cannot be applied to a statement", ERROR, {} },
	STMT_ATTR_ON_DECL { "{at} attribute cannot be applied to a declaration", ERROR, {} },
	PREVIOUS_ATTRIBUTE { "previous attribute is here", NOTE, {} },
	IGNORED_ATTRIBUTE { "{at} attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	CONFLICTING_ATTRIBUTE { "conflicting attribute is here", NOTE, {} },
	INVALID_VEC_ELEM_TY { "invalid vector element type %s", ERROR, {} },
	BIT_INT_VEC_TOO_SMALL { "'_BitInt' vector element width must be at least as wide as 'CHAR_BIT'", ERROR, {} },
	BIT_INT_VEC_NOT_POW2 { "'_BitInt' vector element width must be a power of 2", ERROR, {} },
	VEC_SIZE_NOT_MULTIPLE { "vector size not an integral multiple of component size", ERROR, {} },
	ALIGNAS_ON_FUNC { "{at} attribute only applies to variables and fields", ERROR, {} },
	ALIGNAS_ON_PARAM { "{at} attribute cannot be applied to a function parameter", ERROR, {} },
	ALIGNAS_ON_REGISTER { "{at} attribute cannot be applied to a variable with 'register' storage class", ERROR, {} },
	ALIGNAS_BITFIELD { "{at} attribute cannot be applied to a bit-field", ERROR, {} },
	MINIMUM_ALIGNMENT { "requested alignment is less than minimum alignment of %d", ERROR, {} },
	NON_POW2_ALIGN { "requested alignment is not a power of 2", ERROR, {} },
	WARN_UNUSED_RESULT_VOID { "attribute {at} cannot be applied to functions without return value", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	NONNULL_PARAM_ARGS { "{at} attribute when used on parameters takes no arguments", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	PARAM_OUT_OF_BOUNDS { "{at} attribute parameter %d is out of bounds", ERROR, {} },
	NONNULL_POINTER_ONLY { "{at} attribute only applies to pointer arguments", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	INVALID_NEON_VEC_SIZE { "Neon vector size must be 64 or 128 bits", ERROR, {} },
	TRANSPARENT_UNION_FORWARD_DECL { "{at} attribute can only be applied to a union definition; attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	TRANSPARENT_UNION_WRONG_TYPE { "{at} attribute only applies to unions", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	TRANSPARENT_UNION_ONE_FIELD { "transparent union definition must contain at least one field; {at} attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	TRANSPARENT_UNION_SIZE { "size of field '%s' (%d bits) does not match the size of the first field in transparent union; {at} attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	TRANSPARENT_UNION_SIZE_NOTE { "size of first field is %d", NOTE, {} },
	DESIGNATED_INIT_INVALID { "{at} attribute is only valid on 'struct' type'", ERROR, {} },
	FALLTHROUGH_NON_EMPTY { "{at} attribute is only allowed on empty statements", ERROR, {} },
	FALLTHROUGH_OUTSIDE_SWITCH { "{at} attribute outside a switch statement", ERROR, {} },
	FALLTHROUGH_NOT_BEFORE_CASE { "{at} attribute not preceding a switch label", ERROR, {} },
	CALLCONV_NON_FUNC { "{at} only applies to function types; type here is %s", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	CALLCONV_NOT_SUPPORTED { "{at} calling convention is not supported for this target", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	CALLCONV_INCOMPATIBLE { "%s and %s attributes are not compatible", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	VISIBILITY_PROTECTED_INVALID { "target does not support 'protected' visibility; using 'default'", WARNING, { .has_opt = true, .opt = Option.UNSUPPORTED_VISIBILITY } },
	INCOMPATIBLE_VISIBILITY { "visibility does not match previous declaration", ERROR, {} },
	CONFLICTING_NULLABILITY { "nullability specifier '%s' conflicts with existing specifier '%s'", ERROR, {} },
	INVALID_NULLABILITY { "nullability specifier cannot be applied to non-pointer type %s", ERROR, {} },
	DEPRECATED_NORETURN { "the '[[_Noreturn]]' attribute spelling is deprecated in C23; use '[[noreturn]]' instead", WARNING, { .has_opt = true, .opt = Option.DEPRECATED_ATTRIBUTES } },
	CLEANUP_NON_FUNCTION { "{at} argument '%s' is not a function", ERROR, {} },
	CLEANUP_ONE_ARG { "{at} function '%s' must take 1 parameter", ERROR, {} },
	CLEANUP_ARG_TY { "{at} function '%s' parameter %s is incompatible with %s", ERROR, {} },
	GNU_INLINE_NON_INLINE { "{at} attribute requires function to be marked 'inline', attribute ignored", WARNING, { .has_opt = true, .opt = Option.IGNORED_ATTRIBUTES } },
	CONFLICTING_SECTION_NAME { "{at} does not match previous declaration", WARNING, { .has_opt = true, .opt = Option.SECTION } },
	INVALID_WEAK { "{at} cannot be applied to declarations with internal linkage", ERROR, {} },
	INVALID_SELECTANY { "{at} can only be applied to data items with external linkage", ERROR, {} },
}



























































