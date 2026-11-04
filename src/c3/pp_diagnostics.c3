// Port of src/aro/Preprocessor/Diagnostic.zig: every preprocessor diagnostic
// record, in Zig declaration order, as `PpDiagnostic` constants named
// DIAG_<ZIG_NAME>. Texts, kinds, options and extension flags are copied from
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
// Deviation: Zig's `show_in_system_headers` is not a DiagnosticTemplate field,
// so records are `PpDiagnostic` (an inline DiagnosticTemplate plus that flag);
// a PpDiagnostic converts implicitly to DiagnosticTemplate. API note: moving
// the flag into diagnostics::DiagnosticTemplate would let this be a plain template.
module aro::preprocessor;
import aro::diagnostics, aro::tokenizer;

<* Zig `Preprocessor.Diagnostic`. *>
struct PpDiagnostic
{
	inline DiagnosticTemplate tmpl;
	<* Report even when -Wno-system-headers suppresses warnings in system headers. *>
	bool show_in_system_headers;
}

<*
 Zig `invalidTokenDiagnostic`: the warning for an invalid pp token.
 @require id == UNTERMINATED_STRING_LITERAL || id == EMPTY_CHAR_LITERAL || id == UNTERMINATED_CHAR_LITERAL
*>
fn PpDiagnostic invalid_token_diagnostic(TokenId id)
{
	switch (id)
	{
		case UNTERMINATED_STRING_LITERAL: return DIAG_UNTERMINATED_STRING_LITERAL_WARNING;
		case EMPTY_CHAR_LITERAL: return DIAG_EMPTY_CHAR_LITERAL_WARNING;
		case UNTERMINATED_CHAR_LITERAL: return DIAG_UNTERMINATED_CHAR_LITERAL_WARNING;
		default: unreachable("not an invalid pp token");
	}
}

// ---------------------------------------------------------------------------
// Records (Zig declaration order)

const PpDiagnostic DIAG_ELIF_WITHOUT_IF = { .tmpl = { .fmt = "#elif without #if", .kind = ERROR } };
const PpDiagnostic DIAG_ELIF_AFTER_ELSE = { .tmpl = { .fmt = "#elif after #else", .kind = ERROR } };
const PpDiagnostic DIAG_ELIFDEF_WITHOUT_IF = { .tmpl = { .fmt = "#elifdef without #if", .kind = ERROR } };
const PpDiagnostic DIAG_ELIFDEF_AFTER_ELSE = { .tmpl = { .fmt = "#elifdef after #else", .kind = ERROR } };
const PpDiagnostic DIAG_ELIFNDEF_WITHOUT_IF = { .tmpl = { .fmt = "#elifndef without #if", .kind = ERROR } };
const PpDiagnostic DIAG_ELIFNDEF_AFTER_ELSE = { .tmpl = { .fmt = "#elifndef after #else", .kind = ERROR } };
const PpDiagnostic DIAG_ELSE_WITHOUT_IF = { .tmpl = { .fmt = "#else without #if", .kind = ERROR } };
const PpDiagnostic DIAG_ELSE_AFTER_ELSE = { .tmpl = { .fmt = "#else after #else", .kind = ERROR } };
const PpDiagnostic DIAG_ENDIF_WITHOUT_IF = { .tmpl = { .fmt = "#endif without #if", .kind = ERROR } };
const PpDiagnostic DIAG_UNKNOWN_PRAGMA = { .tmpl = { .fmt = "unknown pragma ignored", .kind = OFF, .has_opt = true, .opt = Option.UNKNOWN_PRAGMAS } };
const PpDiagnostic DIAG_LINE_SIMPLE_DIGIT = { .tmpl = { .fmt = "#line directive requires a simple digit sequence", .kind = ERROR } };
const PpDiagnostic DIAG_LINE_INVALID_FILENAME = { .tmpl = { .fmt = "invalid filename for #line directive", .kind = ERROR } };
const PpDiagnostic DIAG_LINE_INVALID_NUMBER = { .tmpl = { .fmt = "{s} directive requires a positive integer argument", .kind = ERROR } };
const PpDiagnostic DIAG_LINE_INVALID_FLAG = { .tmpl = { .fmt = "invalid flag '{s}' in line marker directive", .kind = ERROR } };
const PpDiagnostic DIAG_UNTERMINATED_CONDITIONAL_DIRECTIVE = { .tmpl = { .fmt = "unterminated conditional directive", .kind = ERROR } };
const PpDiagnostic DIAG_INVALID_PREPROCESSING_DIRECTIVE = { .tmpl = { .fmt = "invalid preprocessing directive", .kind = ERROR } };
const PpDiagnostic DIAG_ERROR_DIRECTIVE = { .tmpl = { .fmt = "{s}", .kind = ERROR } };
const PpDiagnostic DIAG_WARNING_DIRECTIVE = { .tmpl = { .fmt = "{s}", .kind = WARNING, .has_opt = true, .opt = Option.WARNINGS }, .show_in_system_headers = true };
const PpDiagnostic DIAG_MACRO_NAME_MISSING = { .tmpl = { .fmt = "macro name missing", .kind = ERROR } };
const PpDiagnostic DIAG_EXTRA_TOKENS_DIRECTIVE_END = { .tmpl = { .fmt = "extra tokens at end of macro directive", .kind = WARNING, .has_opt = true, .opt = Option.EXTRA_TOKENS } };
const PpDiagnostic DIAG_DEFINED_AS_MACRO_NAME = { .tmpl = { .fmt = "'defined' cannot be used as a macro name", .kind = ERROR } };
const PpDiagnostic DIAG_MACRO_NAME_MUST_BE_IDENTIFIER = { .tmpl = { .fmt = "macro name must be an identifier", .kind = ERROR } };
const PpDiagnostic DIAG_WHITESPACE_AFTER_MACRO_NAME = { .tmpl = { .fmt = "ISO C99 requires whitespace after the macro name", .kind = WARNING, .has_opt = true, .opt = Option.C99_EXTENSIONS, .extension = true } };
const PpDiagnostic DIAG_HASH_HASH_AT_START = { .tmpl = { .fmt = "'##' cannot appear at the start of a macro expansion", .kind = ERROR } };
const PpDiagnostic DIAG_HASH_HASH_AT_END = { .tmpl = { .fmt = "'##' cannot appear at the end of a macro expansion", .kind = ERROR } };
const PpDiagnostic DIAG_PASTING_FORMED_INVALID = { .tmpl = { .fmt = "pasting formed '{s}', an invalid preprocessing token", .kind = ERROR } };
const PpDiagnostic DIAG_MISSING_PAREN_PARAM_LIST = { .tmpl = { .fmt = "missing ')' in macro parameter list", .kind = ERROR } };
const PpDiagnostic DIAG_UNTERMINATED_MACRO_PARAM_LIST = { .tmpl = { .fmt = "unterminated macro param list", .kind = ERROR } };
const PpDiagnostic DIAG_INVALID_TOKEN_PARAM_LIST = { .tmpl = { .fmt = "invalid token in macro parameter list", .kind = ERROR } };
const PpDiagnostic DIAG_EXPECTED_COMMA_PARAM_LIST = { .tmpl = { .fmt = "expected comma in macro parameter list", .kind = ERROR } };
const PpDiagnostic DIAG_HASH_NOT_FOLLOWED_PARAM = { .tmpl = { .fmt = "'#' is not followed by a macro parameter", .kind = ERROR } };
const PpDiagnostic DIAG_EXPECTED_FILENAME = { .tmpl = { .fmt = "expected \"FILENAME\" or <FILENAME>", .kind = ERROR } };
const PpDiagnostic DIAG_EMPTY_FILENAME = { .tmpl = { .fmt = "empty filename", .kind = ERROR } };
const PpDiagnostic DIAG_HEADER_STR_CLOSING = { .tmpl = { .fmt = "expected closing '>'", .kind = ERROR } };
const PpDiagnostic DIAG_HEADER_STR_MATCH = { .tmpl = { .fmt = "to match this '<'", .kind = NOTE } };
const PpDiagnostic DIAG_EMPTY_CHAR_LITERAL_WARNING = { .tmpl = { .fmt = "empty character constant", .kind = WARNING, .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true } };
const PpDiagnostic DIAG_UNTERMINATED_CHAR_LITERAL_WARNING = { .tmpl = { .fmt = "missing terminating ' character", .kind = WARNING, .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true } };
const PpDiagnostic DIAG_UNTERMINATED_STRING_LITERAL_WARNING = { .tmpl = { .fmt = "missing terminating '\"' character", .kind = WARNING, .has_opt = true, .opt = Option.INVALID_PP_TOKEN, .extension = true } };
const PpDiagnostic DIAG_UNTERMINATED_COMMENT = { .tmpl = { .fmt = "unterminated comment", .kind = ERROR } };
const PpDiagnostic DIAG_WARNING_EXTENSION = { .tmpl = { .fmt = "#warning is a C23 extension", .kind = OFF, .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true } };
const PpDiagnostic DIAG_C23_EXTENSION = { .tmpl = { .fmt = "{s} is a C23 extension", .kind = WARNING, .has_opt = true, .opt = Option.C23_EXTENSIONS, .extension = true } };
const PpDiagnostic DIAG_EMBED_PARAM_IDENTIFIER = { .tmpl = { .fmt = "expected identifier", .kind = ERROR } };
const PpDiagnostic DIAG_EMBED_PARAM_ARGS = { .tmpl = { .fmt = "expected '('", .kind = ERROR } };
const PpDiagnostic DIAG_INVALID_EMBED_LIMIT = { .tmpl = { .fmt = "the limit parameter expects a non-negative integer as a parameter", .kind = ERROR } };
const PpDiagnostic DIAG_DUPLICATE_EMBED_PARAM = { .tmpl = { .fmt = "duplicate embed parameter '{s}'", .kind = WARNING, .has_opt = true, .opt = Option.DUPLICATE_EMBED_PARAM } };
const PpDiagnostic DIAG_UNKNOWN_EMBED_PARAM = { .tmpl = { .fmt = "unknown embed parameter '{s}'", .kind = ERROR } };
const PpDiagnostic DIAG_VA_OPT_LPAREN = { .tmpl = { .fmt = "missing '(' following __VA_OPT__", .kind = ERROR } };
const PpDiagnostic DIAG_VA_OPT_RPAREN = { .tmpl = { .fmt = "unterminated __VA_OPT__ argument list", .kind = ERROR } };
const PpDiagnostic DIAG_KEYWORD_MACRO = { .tmpl = { .fmt = "keyword is hidden by macro definition", .kind = OFF, .has_opt = true, .opt = Option.KEYWORD_MACRO, .extension = true } };
const PpDiagnostic DIAG_UNDEFINED_MACRO = { .tmpl = { .fmt = "'{s}' is not defined, evaluates to 0", .kind = OFF, .has_opt = true, .opt = Option.UNDEF } };
const PpDiagnostic DIAG_FN_MACRO_UNDEFINED = { .tmpl = { .fmt = "function-like macro '{s}' is not defined", .kind = ERROR } };
const PpDiagnostic DIAG_PREPROCESSING_DIRECTIVE_ONLY = { .tmpl = { .fmt = "'__{s}' must be used within a preprocessing directive", .kind = ERROR } };
const PpDiagnostic DIAG_MISSING_LPAREN_AFTER_BUILTIN = { .tmpl = { .fmt = "missing '(' after built-in macro '{s}'", .kind = ERROR } };
const PpDiagnostic DIAG_TOO_MANY_INCLUDES = { .tmpl = { .fmt = "#include nested too deeply", .kind = ERROR } };
const PpDiagnostic DIAG_INCLUDE_NEXT = { .tmpl = { .fmt = "#include_next is a language extension", .kind = OFF, .has_opt = true, .opt = Option.GNU_INCLUDE_NEXT, .extension = true } };
const PpDiagnostic DIAG_INCLUDE_NEXT_OUTSIDE_HEADER = { .tmpl = { .fmt = "#include_next in primary source file; will search from start of include path", .kind = WARNING, .has_opt = true, .opt = Option.INCLUDE_NEXT_OUTSIDE_HEADER } };
const PpDiagnostic DIAG_COMMA_DELETION_VA_ARGS = { .tmpl = { .fmt = "token pasting of ',' and __VA_ARGS__ is a GNU extension", .kind = OFF, .has_opt = true, .opt = Option.GNU_ZERO_VARIADIC_MACRO_ARGUMENTS, .extension = true } };
const PpDiagnostic DIAG_EXPANSION_TO_DEFINED_OBJ = { .tmpl = { .fmt = "macro expansion producing 'defined' has undefined behavior", .kind = OFF, .has_opt = true, .opt = Option.EXPANSION_TO_DEFINED } };
const PpDiagnostic DIAG_EXPANSION_TO_DEFINED_FUNC = { .tmpl = { .fmt = "macro expansion producing 'defined' has undefined behavior", .kind = OFF, .has_opt = true, .opt = Option.EXPANSION_TO_DEFINED, .extension = true } };
const PpDiagnostic DIAG_INVALID_PP_STRINGIFY_ESCAPE = { .tmpl = { .fmt = "invalid string literal, ignoring final '\\'", .kind = WARNING } };
const PpDiagnostic DIAG_GNU_VA_MACRO = { .tmpl = { .fmt = "named variadic macros are a GNU extension", .kind = OFF, .has_opt = true, .opt = Option.VARIADIC_MACROS, .extension = true } };
const PpDiagnostic DIAG_PRAGMA_OPERATOR_STRING_LITERAL = { .tmpl = { .fmt = "_Pragma requires exactly one string literal token", .kind = ERROR } };
const PpDiagnostic DIAG_INVALID_PREPROC_EXPR_START = { .tmpl = { .fmt = "invalid token at start of a preprocessor expression", .kind = ERROR } };
const PpDiagnostic DIAG_EXPECTED_VALUE_IN_EXPR = { .tmpl = { .fmt = "expected value in expression", .kind = ERROR } };
const PpDiagnostic DIAG_INVALID_PREPROC_OPERATOR = { .tmpl = { .fmt = "token is not a valid binary operator in a preprocessor subexpression", .kind = ERROR } };
const PpDiagnostic DIAG_CONVERT_TO_POSITIVE = { .tmpl = { .fmt = "{s} side of operator converted from negative value to unsigned: {d} to {d}", .kind = WARNING } };
const PpDiagnostic DIAG_DIVISION_BY_ZERO = { .tmpl = { .fmt = "{s} by zero in preprocessor expression", .kind = ERROR } };
const PpDiagnostic DIAG_COMMA_OPERATOR = { .tmpl = { .fmt = "comma operator in operand of #if", .kind = WARNING, .extension = true } };
const PpDiagnostic DIAG_OVERFLOW = { .tmpl = { .fmt = "integer overflow in preprocessor expression", .kind = WARNING } };
const PpDiagnostic DIAG_EXPECTED_COLON = { .tmpl = { .fmt = "expected ':'", .kind = ERROR } };
const PpDiagnostic DIAG_TO_MATCH_QUESTION = { .tmpl = { .fmt = "to match this '?'", .kind = NOTE } };
const PpDiagnostic DIAG_FLOAT_LITERAL_IN_EXPR = { .tmpl = { .fmt = "floating point literal in preprocessor expression", .kind = ERROR } };
const PpDiagnostic DIAG_INT_LITERAL_TOO_BIG = { .tmpl = { .fmt = "integer literal is too large to be represented in any integer type", .kind = ERROR } };
const PpDiagnostic DIAG_IMPLICITLY_UNSIGNED_LITERAL = { .tmpl = { .fmt = "integer literal is too large to be represented in a signed integer type, interpreting as unsigned", .kind = WARNING, .has_opt = true, .opt = Option.IMPLICITLY_UNSIGNED_LITERAL, .extension = true } };
const PpDiagnostic DIAG_NEWLINE_EOF = { .tmpl = { .fmt = "no newline at end of file", .kind = OFF, .has_opt = true, .opt = Option.NEWLINE_EOF, .extension = true } };
const PpDiagnostic DIAG_MALFORMED_WARNING_CHECK = { .tmpl = { .fmt = "{s} expected option name (e.g. \"-Wundef\")", .kind = WARNING, .has_opt = true, .opt = Option.MALFORMED_WARNING_CHECK, .extension = true } };
const PpDiagnostic DIAG_FEATURE_CHECK_REQUIRES_IDENTIFIER = { .tmpl = { .fmt = "builtin feature check macro requires a parenthesized identifier", .kind = ERROR } };
const PpDiagnostic DIAG_BUILTIN_MACRO_REDEFINED = { .tmpl = { .fmt = "redefining builtin macro", .kind = WARNING, .has_opt = true, .opt = Option.BUILTIN_MACRO_REDEFINED, .extension = true } };
const PpDiagnostic DIAG_MACRO_REDEFINED = { .tmpl = { .fmt = "'{s}' macro redefined", .kind = WARNING, .has_opt = true, .opt = Option.MACRO_REDEFINED, .extension = true } };
const PpDiagnostic DIAG_PREVIOUS_DEFINITION = { .tmpl = { .fmt = "previous definition is here", .kind = NOTE } };
const PpDiagnostic DIAG_UNTERMINATED_MACRO_ARG_LIST = { .tmpl = { .fmt = "unterminated function macro argument list", .kind = ERROR } };
const PpDiagnostic DIAG_TO_MATCH_PAREN = { .tmpl = { .fmt = "to match this '('", .kind = NOTE } };
const PpDiagnostic DIAG_CLOSING_PAREN = { .tmpl = { .fmt = "expected closing ')'", .kind = ERROR } };
const PpDiagnostic DIAG_POISONED_IDENTIFIER = { .tmpl = { .fmt = "attempt to use a poisoned identifier", .kind = ERROR } };
const PpDiagnostic DIAG_EXPECTED_ARGUMENTS = { .tmpl = { .fmt = "expected {d} argument(s) got {d}", .kind = ERROR } };
const PpDiagnostic DIAG_EXPECTED_AT_LEAST_ARGUMENTS = { .tmpl = { .fmt = "expected at least {d} argument(s) got {d}", .kind = WARNING } };
const PpDiagnostic DIAG_EXPECTED_STR_LITERAL_IN = { .tmpl = { .fmt = "expected string literal in '{s}'", .kind = ERROR } };
const PpDiagnostic DIAG_BUILTIN_MISSING_R_PAREN = { .tmpl = { .fmt = "missing ')', after {s}", .kind = ERROR } };
const PpDiagnostic DIAG_CANNOT_CONVERT_TO_IDENTIFIER = { .tmpl = { .fmt = "cannot convert {s} to an identifier", .kind = ERROR } };
const PpDiagnostic DIAG_EXPECTED_IDENTIFIER = { .tmpl = { .fmt = "expected identifier argument", .kind = ERROR } };
const PpDiagnostic DIAG_INCOMPLETE_UCN = { .tmpl = { .fmt = "incomplete universal character name; treating as '\\' followed by identifier", .kind = WARNING, .has_opt = true, .opt = Option.UNICODE } };
const PpDiagnostic DIAG_INVALID_SOURCE_EPOCH = { .tmpl = { .fmt = "environment variable SOURCE_DATE_EPOCH must expand to a non-negative integer less than or equal to 253402300799", .kind = ERROR } };
const PpDiagnostic DIAG_DATE_TIME = { .tmpl = { .fmt = "expansion of date or time macro is not reproducible", .kind = OFF, .has_opt = true, .opt = Option.DATE_TIME }, .show_in_system_headers = true };
const PpDiagnostic DIAG_NO_ARGUMENT_VARIADIC_MACRO = { .tmpl = { .fmt = "passing no argument for the '...' parameter of a variadic macro is incompatible with C standards before C23", .kind = OFF, .has_opt = true, .opt = Option.VARIADIC_MACRO_ARGUMENTS_OMITTED, .extension = true } };
const PpDiagnostic DIAG_PRAGMA_ONCE_IN_MAIN_FILE = { .tmpl = { .fmt = "#pragma once in main file", .kind = WARNING, .has_opt = true, .opt = Option.PRAGMA_ONCE_OUTSIDE_HEADER } };
const PpDiagnostic DIAG_FILE_NAME_IS_CLANG_EXTENSION = { .tmpl = { .fmt = "__FILE_NAME__ is a clang extension", .kind = OFF, .has_opt = true, .opt = Option.FILE_NAME_EXTENSION, .extension = true } };
const PpDiagnostic DIAG_BASE_FILE_IS_CLANG_EXTENSION = { .tmpl = { .fmt = "__BASE_FILE__ is a clang extension", .kind = OFF, .has_opt = true, .opt = Option.BASE_FILE_EXTENSION, .extension = true } };
const PpDiagnostic DIAG_INCLUDE_LEVEL_IS_CLANG_EXTENSION = { .tmpl = { .fmt = "__INCLUDE_LEVEL__ is a clang extension", .kind = OFF, .has_opt = true, .opt = Option.INCLUDE_LEVEL_EXTENSION, .extension = true } };
const PpDiagnostic DIAG_PRE_C2Y_COUNTER = { .tmpl = { .fmt = "'__COUNTER__' is incompatible with C standards before C2y", .kind = OFF, .has_opt = true, .opt = Option.PRE_C2Y_COMPAT } };
const PpDiagnostic DIAG_C2Y_COUNTER = { .tmpl = { .fmt = "'__COUNTER__' is a C2y extension", .kind = OFF, .has_opt = true, .opt = Option.C2Y_EXTENSIONS, .extension = true } };
const PpDiagnostic DIAG_COUNTER_OVERFLOW = { .tmpl = { .fmt = "'__COUNTER__' value cannot exceed 2'147'483'647", .kind = ERROR } };
