// Port of src/aro/Preprocessor/Diagnostic.zig: every preprocessor diagnostic
// record, in Zig declaration order, as entries of `enum PpDiag`. Texts, kinds, options and extension flags are copied from
// the Zig source (generated once from it by a throwaway script; spot-checked
// by pp_contract_tests). Data only.
//
// Who uses which records (the stage-1 owners of plan 13):
//  - pp_directives.c3 (13.5): ELIF_WITHOUT_IF, ELIF_AFTER_ELSE, ELIFDEF_*,
//    ELIFNDEF_*, ELSE_*, ENDIF_WITHOUT_IF, LINE_*, UNTERMINATED_CONDITIONAL_DIRECTIVE,
//    INVALID_PREPROCESSING_DIRECTIVE, ERROR_DIRECTIVE, WARNING_DIRECTIVE,
//    WARNING_EXTENSION, C23_EXTENSION, MACRO_NAME_MISSING,
//    EXTRA_TOKENS_DIRECTIVE_END, NEWLINE_EOF, UNTERMINATED_COMMENT,
//    POISONED_IDENTIFIER, *_LITERAL_WARNING (via invalid_token_diagnostic).
//  - pp_expression.c3 (13.2): INVALID_PREPROC_EXPR_START, EXPECTED_VALUE_IN_EXPR,
//    INVALID_PREPROC_OPERATOR, CONVERT_TO_POSITIVE, DIVISION_BY_ZERO,
//    COMMA_OPERATOR, OVERFLOW, EXPECTED_COLON, TO_MATCH_QUESTION,
//    FLOAT_LITERAL_IN_EXPR, INT_LITERAL_TOO_BIG, IMPLICITLY_UNSIGNED_LITERAL,
//    UNDEFINED_MACRO, FN_MACRO_UNDEFINED, MACRO_NAME_MISSING,
//    MACRO_NAME_MUST_BE_IDENTIFIER, CLOSING_PAREN, TO_MATCH_PAREN.
//  - macro_expand.c3 (13.3): DEFINED_AS_MACRO_NAME, MACRO_NAME_MUST_BE_IDENTIFIER,
//    KEYWORD_MACRO, WHITESPACE_AFTER_MACRO_NAME, HASH_HASH_AT_START/END,
//    MISSING_PAREN_PARAM_LIST, TO_MATCH_PAREN, UNTERMINATED_MACRO_PARAM_LIST,
//    INVALID_TOKEN_PARAM_LIST, EXPECTED_COMMA_PARAM_LIST, GNU_VA_MACRO,
//    HASH_NOT_FOLLOWED_PARAM, VA_OPT_LPAREN, VA_OPT_RPAREN, BUILTIN_MACRO_REDEFINED,
//    MACRO_REDEFINED, PREVIOUS_DEFINITION, UNTERMINATED_MACRO_ARG_LIST,
//    MISSING_LPAREN_AFTER_BUILTIN, EXPECTED_ARGUMENTS, EXPECTED_AT_LEAST_ARGUMENTS,
//    NO_ARGUMENT_VARIADIC_MACRO, COMMA_DELETION_VA_ARGS, EXPANSION_TO_DEFINED_*,
//    INCOMPLETE_UCN (also preprocessor.c3 unescape_ucn), POISONED_IDENTIFIER.
//  - macro_paste.c3 (13.4): PASTING_FORMED_INVALID, INVALID_PP_STRINGIFY_ESCAPE.
//  - Plans 14/15 (builtin macros, include/embed/pragma): the remaining records
//    (EXPECTED_FILENAME, EMBED_*, TOO_MANY_INCLUDES, DATE_TIME, ...).
//
module aro::preprocessor;
import aro::diagnostics, aro::tokenizer, aro::tokens;

<*
 Zig `invalidTokenDiagnostic`: the warning for an invalid pp token.
 @require id == UNTERMINATED_STRING_LITERAL || id == EMPTY_CHAR_LITERAL || id == UNTERMINATED_CHAR_LITERAL
*>
fn PpDiag invalid_token_diagnostic(TokenId id)
{
	switch (id)
	{
		case UNTERMINATED_STRING_LITERAL: return PpDiag.UNTERMINATED_STRING_LITERAL_WARNING;
		case EMPTY_CHAR_LITERAL: return PpDiag.EMPTY_CHAR_LITERAL_WARNING;
		case UNTERMINATED_CHAR_LITERAL: return PpDiag.UNTERMINATED_CHAR_LITERAL_WARNING;
		default: unreachable("not an invalid pp token");
	}
}

<* Report Zig `invalidTokenDiagnostic(tok.id)` at raw token `tok`. @return? compilation::FATAL_ERROR *>
fn void? Preprocessor.err_invalid_token(&self, RawToken tok)
{
	return self.err_dyn_at(tokens::raw_location(tok), {}, invalid_token_diagnostic(tok.id));
}

<*
 Zig `Preprocessor.Diagnostic`, in Zig declaration order. `fmt` is C3 printf syntax; emit with `Preprocessor.err`/`err_raw`/`err_loc`.
*>
enum PpDiag : ushort (String fmt, MessageKind kind, DiagMeta meta)
{
	ELIF_WITHOUT_IF { "#elif without #if", ERROR, {} },
	ELIF_AFTER_ELSE { "#elif after #else", ERROR, {} },
	ELIFDEF_WITHOUT_IF { "#elifdef without #if", ERROR, {} },
	ELIFDEF_AFTER_ELSE { "#elifdef after #else", ERROR, {} },
	ELIFNDEF_WITHOUT_IF { "#elifndef without #if", ERROR, {} },
	ELIFNDEF_AFTER_ELSE { "#elifndef after #else", ERROR, {} },
	ELSE_WITHOUT_IF { "#else without #if", ERROR, {} },
	ELSE_AFTER_ELSE { "#else after #else", ERROR, {} },
	ENDIF_WITHOUT_IF { "#endif without #if", ERROR, {} },
	UNKNOWN_PRAGMA { "unknown pragma ignored", OFF, { .has_opt = true, .opt = Option.UNKNOWN_PRAGMAS } },
	LINE_SIMPLE_DIGIT { "#line directive requires a simple digit sequence", ERROR, {} },
	LINE_INVALID_FILENAME { "invalid filename for #line directive", ERROR, {} },
	LINE_INVALID_NUMBER { "%s directive requires a positive integer argument", ERROR, {} },
	LINE_INVALID_FLAG { "invalid flag '%s' in line marker directive", ERROR, {} },
	UNTERMINATED_CONDITIONAL_DIRECTIVE { "unterminated conditional directive", ERROR, {} },
	INVALID_PREPROCESSING_DIRECTIVE { "invalid preprocessing directive", ERROR, {} },
	ERROR_DIRECTIVE { "%s", ERROR, {} },
	WARNING_DIRECTIVE { "%s", WARNING, { .has_opt = true, .opt = Option.WARNINGS, .show_in_system_headers = true } },
	MACRO_NAME_MISSING { "macro name missing", ERROR, {} },
	EXTRA_TOKENS_DIRECTIVE_END { "extra tokens at end of macro directive", WARNING, { .has_opt = true, .opt = Option.EXTRA_TOKENS } },
	DEFINED_AS_MACRO_NAME { "'defined' cannot be used as a macro name", ERROR, {} },
	MACRO_NAME_MUST_BE_IDENTIFIER { "macro name must be an identifier", ERROR, {} },
	WHITESPACE_AFTER_MACRO_NAME { "ISO C99 requires whitespace after the macro name", WARNING, { .has_opt = true, .opt = Option.C99_EXTENSIONS, .extension = true } },
	HASH_HASH_AT_START { "'##' cannot appear at the start of a macro expansion", ERROR, {} },
	HASH_HASH_AT_END { "'##' cannot appear at the end of a macro expansion", ERROR, {} },
	PASTING_FORMED_INVALID { "pasting formed '%s', an invalid preprocessing token", ERROR, {} },
	MISSING_PAREN_PARAM_LIST { "missing ')' in macro parameter list", ERROR, {} },
	UNTERMINATED_MACRO_PARAM_LIST { "unterminated macro param list", ERROR, {} },
	INVALID_TOKEN_PARAM_LIST { "invalid token in macro parameter list", ERROR, {} },
	EXPECTED_COMMA_PARAM_LIST { "expected comma in macro parameter list", ERROR, {} },
	HASH_NOT_FOLLOWED_PARAM { "'#' is not followed by a macro parameter", ERROR, {} },
	EXPECTED_FILENAME { "expected \"FILENAME\" or <FILENAME>", ERROR, {} },
	EMPTY_FILENAME { "empty filename", ERROR, {} },
	HEADER_STR_CLOSING { "expected closing '>'", ERROR, {} },
	HEADER_STR_MATCH { "to match this '<'", NOTE, {} },
	EMPTY_CHAR_LITERAL_WARNING { "empty character constant", WARNING, { .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true } },
	UNTERMINATED_CHAR_LITERAL_WARNING { "missing terminating ' character", WARNING, { .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true } },
	UNTERMINATED_STRING_LITERAL_WARNING { "missing terminating '\"' character", WARNING, { .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true } },
	UNTERMINATED_COMMENT { "unterminated comment", ERROR, {} },
	WARNING_EXTENSION { "#warning is a C23 extension", OFF, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true } },
	C23_EXTENSION { "%s is a C23 extension", WARNING, { .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true } },
	EMBED_PARAM_IDENTIFIER { "expected identifier", ERROR, {} },
	EMBED_PARAM_ARGS { "expected '('", ERROR, {} },
	INVALID_EMBED_LIMIT { "the limit parameter expects a non-negative integer as a parameter", ERROR, {} },
	DUPLICATE_EMBED_PARAM { "duplicate embed parameter '%s'", WARNING, { .has_opt = true, .opt = Option.DUPLICATE_EMBED_PARAM } },
	UNKNOWN_EMBED_PARAM { "unknown embed parameter '%s'", ERROR, {} },
	VA_OPT_LPAREN { "missing '(' following __VA_OPT__", ERROR, {} },
	VA_OPT_RPAREN { "unterminated __VA_OPT__ argument list", ERROR, {} },
	KEYWORD_MACRO { "keyword is hidden by macro definition", OFF, { .has_opt = true, .opt = Option.KEYWORD_MACRO, .extension = true } },
	UNDEFINED_MACRO { "'%s' is not defined, evaluates to 0", OFF, { .has_opt = true, .opt = Option.UNDEF } },
	FN_MACRO_UNDEFINED { "function-like macro '%s' is not defined", ERROR, {} },
	PREPROCESSING_DIRECTIVE_ONLY { "'__%s' must be used within a preprocessing directive", ERROR, {} },
	MISSING_LPAREN_AFTER_BUILTIN { "missing '(' after built-in macro '%s'", ERROR, {} },
	TOO_MANY_INCLUDES { "#include nested too deeply", ERROR, {} },
	INCLUDE_NEXT { "#include_next is a language extension", OFF, { .has_opt = true, .opt = Option.GNU_INCLUDE_NEXT, .extension = true } },
	INCLUDE_NEXT_OUTSIDE_HEADER { "#include_next in primary source file; will search from start of include path", WARNING, { .has_opt = true, .opt = Option.INCLUDE_NEXT_OUTSIDE_HEADER } },
	COMMA_DELETION_VA_ARGS { "token pasting of ',' and __VA_ARGS__ is a GNU extension", OFF, { .has_opt = true, .opt = Option.GNU_ZERO_VARIADIC_MACRO_ARGUMENTS, .extension = true } },
	EXPANSION_TO_DEFINED_OBJ { "macro expansion producing 'defined' has undefined behavior", OFF, { .has_opt = true, .opt = Option.EXPANSION_TO_DEFINED } },
	EXPANSION_TO_DEFINED_FUNC { "macro expansion producing 'defined' has undefined behavior", OFF, { .has_opt = true, .opt = Option.EXPANSION_TO_DEFINED, .extension = true } },
	INVALID_PP_STRINGIFY_ESCAPE { "invalid string literal, ignoring final '\\'", WARNING, {} },
	GNU_VA_MACRO { "named variadic macros are a GNU extension", OFF, { .has_opt = true, .opt = Option.VARIADIC_MACROS, .extension = true } },
	PRAGMA_OPERATOR_STRING_LITERAL { "_Pragma requires exactly one string literal token", ERROR, {} },
	INVALID_PREPROC_EXPR_START { "invalid token at start of a preprocessor expression", ERROR, {} },
	EXPECTED_VALUE_IN_EXPR { "expected value in expression", ERROR, {} },
	INVALID_PREPROC_OPERATOR { "token is not a valid binary operator in a preprocessor subexpression", ERROR, {} },
	CONVERT_TO_POSITIVE { "%s side of operator converted from negative value to unsigned: %d to %d", WARNING, {} },
	DIVISION_BY_ZERO { "%s by zero in preprocessor expression", ERROR, {} },
	COMMA_OPERATOR { "comma operator in operand of #if", WARNING, { .extension = true } },
	OVERFLOW { "integer overflow in preprocessor expression", WARNING, {} },
	EXPECTED_COLON { "expected ':'", ERROR, {} },
	TO_MATCH_QUESTION { "to match this '?'", NOTE, {} },
	FLOAT_LITERAL_IN_EXPR { "floating point literal in preprocessor expression", ERROR, {} },
	INT_LITERAL_TOO_BIG { "integer literal is too large to be represented in any integer type", ERROR, {} },
	IMPLICITLY_UNSIGNED_LITERAL { "integer literal is too large to be represented in a signed integer type, interpreting as unsigned", WARNING, { .has_opt = true, .opt = Option.IMPLICITLY_UNSIGNED_LITERAL, .extension = true } },
	NEWLINE_EOF { "no newline at end of file", OFF, { .has_opt = true, .opt = Option.NEWLINE_EOF, .extension = true } },
	MALFORMED_WARNING_CHECK { "%s expected option name (e.g. \"-Wundef\")", WARNING, { .has_opt = true, .opt = Option.MALFORMED_WARNING_CHECK, .extension = true } },
	FEATURE_CHECK_REQUIRES_IDENTIFIER { "builtin feature check macro requires a parenthesized identifier", ERROR, {} },
	BUILTIN_MACRO_REDEFINED { "redefining builtin macro", WARNING, { .has_opt = true, .opt = Option.BUILTIN_MACRO_REDEFINED, .extension = true } },
	MACRO_REDEFINED { "'%s' macro redefined", WARNING, { .has_opt = true, .opt = Option.MACRO_REDEFINED, .extension = true } },
	PREVIOUS_DEFINITION { "previous definition is here", NOTE, {} },
	UNTERMINATED_MACRO_ARG_LIST { "unterminated function macro argument list", ERROR, {} },
	TO_MATCH_PAREN { "to match this '('", NOTE, {} },
	CLOSING_PAREN { "expected closing ')'", ERROR, {} },
	POISONED_IDENTIFIER { "attempt to use a poisoned identifier", ERROR, {} },
	EXPECTED_ARGUMENTS { "expected %d argument(s) got %d", ERROR, {} },
	EXPECTED_AT_LEAST_ARGUMENTS { "expected at least %d argument(s) got %d", WARNING, {} },
	EXPECTED_STR_LITERAL_IN { "expected string literal in '%s'", ERROR, {} },
	BUILTIN_MISSING_R_PAREN { "missing ')', after %s", ERROR, {} },
	CANNOT_CONVERT_TO_IDENTIFIER { "cannot convert %s to an identifier", ERROR, {} },
	EXPECTED_IDENTIFIER { "expected identifier argument", ERROR, {} },
	INCOMPLETE_UCN { "incomplete universal character name; treating as '\\' followed by identifier", WARNING, { .has_opt = true, .opt = Option.UNICODE } },
	INVALID_SOURCE_EPOCH { "environment variable SOURCE_DATE_EPOCH must expand to a non-negative integer less than or equal to 253402300799", ERROR, {} },
	DATE_TIME { "expansion of date or time macro is not reproducible", OFF, { .has_opt = true, .opt = Option.DATE_TIME, .show_in_system_headers = true } },
	NO_ARGUMENT_VARIADIC_MACRO { "passing no argument for the '...' parameter of a variadic macro is incompatible with C standards before C23", OFF, { .has_opt = true, .opt = Option.VARIADIC_MACRO_ARGUMENTS_OMITTED, .extension = true } },
	PRAGMA_ONCE_IN_MAIN_FILE { "#pragma once in main file", WARNING, { .has_opt = true, .opt = Option.PRAGMA_ONCE_OUTSIDE_HEADER } },
	FILE_NAME_IS_CLANG_EXTENSION { "__FILE_NAME__ is a clang extension", OFF, { .has_opt = true, .opt = Option.FILE_NAME_EXTENSION, .extension = true } },
	BASE_FILE_IS_CLANG_EXTENSION { "__BASE_FILE__ is a clang extension", OFF, { .has_opt = true, .opt = Option.BASE_FILE_EXTENSION, .extension = true } },
	INCLUDE_LEVEL_IS_CLANG_EXTENSION { "__INCLUDE_LEVEL__ is a clang extension", OFF, { .has_opt = true, .opt = Option.INCLUDE_LEVEL_EXTENSION, .extension = true } },
	PRE_C2Y_COUNTER { "'__COUNTER__' is incompatible with C standards before C2y", OFF, { .has_opt = true, .opt = Option.PRE_C2Y_COMPAT } },
	C2Y_COUNTER { "'__COUNTER__' is a C2y extension", OFF, { .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true } },
	COUNTER_OVERFLOW { "'__COUNTER__' value cannot exceed 2'147'483'647", ERROR, {} },
	// C3-only: a directive whose implementation belongs to a later plan returned aro::UNSUPPORTED.
	DIRECTIVE_UNSUPPORTED { "'%s' is not supported yet by the C3 port", ERROR, {} },
}
