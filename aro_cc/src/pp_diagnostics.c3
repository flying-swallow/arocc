// Port of src/aro/Preprocessor/Diagnostic.zig: every preprocessor diagnostic
// record, in Zig declaration order, as entries of `enum Diagnostic`. Texts, kinds, options and extension flags are copied from
// the Zig source (generated once from it by a throwaway script; spot-checked
// by pp_contract_tests). Data only.
//
// Who uses which records (the stage-1 owners of plan 13):
//  - pp_directives.c3 (13.5): ELIF_WITHOUT_IF, ELIF_AFTER_ELSE, ELIFDEF_*,
//    ELIFNDEF_*, ELSE_*, ENDIF_WITHOUT_IF, LINE_*, UNTERMINATED_CONDITIONAL_DIRECTIVE,
//    INVALID_PREPROCESSING_DIRECTIVE, ERROR_DIRECTIVE, WARNING_DIRECTIVE,
//    WARNING_EXTENSION, C23_EXTENSION, MACRO_NAME_MISSING,
//    EXTRA_TOKENS_DIRECTIVE_END, NEWLINE_EOF, UNTERMINATED_COMMENT,
//    POISONED_IDENTIFIER, *_LITERAL_WARNING (via err_invalid_token).
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
module aro::frontend::c::preprocessor;
import aro::frontend::c::compilation, aro::frontend::c::diagnostics, aro::frontend::c::tokenizer, aro::frontend::c::tokens;

<*
 Zig `invalidTokenDiagnostic(tok.id)` reported at raw token `tok`.
 @require tok.id == UNTERMINATED_STRING_LITERAL || tok.id == EMPTY_CHAR_LITERAL || tok.id == UNTERMINATED_CHAR_LITERAL
 @return? compilation::FATAL_ERROR
*>
fn void? Preprocessor.err_invalid_token(&self, RawToken tok)
{
	switch (tok.id)
	{
		case UNTERMINATED_STRING_LITERAL: return self.err_raw(tok, Diagnostic.UNTERMINATED_STRING_LITERAL_WARNING);
		case EMPTY_CHAR_LITERAL: return self.err_raw(tok, Diagnostic.EMPTY_CHAR_LITERAL_WARNING);
		case UNTERMINATED_CHAR_LITERAL: return self.err_raw(tok, Diagnostic.UNTERMINATED_CHAR_LITERAL_WARNING);
		default: unreachable("not an invalid pp token");
	}
}
