// Port of src/aro/Tokenizer.zig: Token, Token.Id, keyword lookup (getTokenId),
// UCNKind.classify and the Tokenizer state machine (next, nextNoWS,
// nextNoWSComments). Literal decoding (number_literal / text_literal) is a
// separate step and not part of this module.
//
// Deviations from Zig:
// - Zig's labeled `switch` with `continue :loop` maps to C3's labeled
//   `switch LOOP:` with `nextcase LOOP:`.
// - `Token.Id.lexeme` returns `NO_LEXEME~` where Zig returns null.
// - `all_kws` (a StaticStringMap) is a byte-sorted table searched by binary
//   search; `keyword_table_is_sorted` in the tests checks the order.
// - `validPreprocessorExprStart` drops Zig's `.one` / `.zero`, which are not
//   members of Token.Id (Zig never analyzed that function body).
module aro::frontend::c::tokenizer;
import aro::string_util;
import aro::source, aro::target, aro::frontend::c::lang_opts, aro::frontend::c::tree, aro::frontend::c::tokens;

excuse NO_LEXEME;

<* Value for valid escapes is how many characters to consume, not counting the leading backslash. *>
enum UCNKind : char (uint consumed)
{
	NONE { 0 },       // Just `\`
	INCOMPLETE { 0 }, // \u or \U followed by an insufficient number of hex digits
	HEX4 { 5 },       // `\uxxxx`
	HEX8 { 9 },       // `\Uxxxxxxxx`
}


<*
 In the classification phase we do not care if the escape represents a valid
 universal character name, e.g. \UFFFFFFFF is acceptable.
 @require buf.len > 0 && buf[0] == '\\'
*>
fn UCNKind ucn_classify(String buf)
{
	if (buf.len == 1) return NONE;
	switch (buf[1])
	{
		case 'u':
			if (buf.len < 6) return INCOMPLETE;
			foreach (c : buf[2..5]) if (!string_util::is_digit(c, 16)) return INCOMPLETE;
			return HEX4;
		case 'U':
			if (buf.len < 10) return INCOMPLETE;
			foreach (c : buf[2..9]) if (!string_util::is_digit(c, 16)) return INCOMPLETE;
			return HEX8;
		default:
			return NONE;
	}
}

struct Token
{
	TokenId id;
	SourceId source;
	uint start;
	uint end;
	uint line;
}

<* Per-token categories of a TokenId. Zero means none. *>
struct TokenProps
{
	<* The spelling varies (identifiers, literals, pp-numbers, ...): `lexeme()` is NO_LEXEME. *>
	bool no_lexeme;
	<* INCLUDE_START / INCLUDE_RESUME / LINEMARKER: virtual tokens without a lexeme. *>
	bool virtual_marker;
	<* `is_macro_identifier()`: identifiers and keywords. *>
	bool macro_identifier;
	<* Directive keywords that `simplify_macro_keyword` turns into IDENTIFIER. *>
	bool directive_keyword;
	<* `valid_preprocessor_expr_start()`. *>
	bool pp_expr_start;
	<* `allows_digraphs()` when the language options enable digraphs. *>
	bool digraph;
	<* `can_open_gcc_asm_stmt()`. *>
	bool asm_open;
	<* `is_string_literal()`: complete, prefixed or not, string literals. *>
	bool string_literal;
	<* `is_char_literal()`: every character literal token, including empty and unterminated ones. *>
	bool char_literal;
	<* `stringify_escapes()`: Zig stringify's `is_str`, tokens whose '\' are escaped (not u8 char literals). *>
	bool stringify_escapes;
	<* `starts_declaration()`: tokens that can begin a declaration (parser recovery stops before them). *>
	bool recovery_decl_start;
	<* `starts_compound_item()`: tokens that can begin a statement or declaration in a block. *>
	bool compound_item_start;
	<* Binary operator precedence; ANY = not a binary operator. *>
	tokens::Precedence binary_prec;
	<* The keyword this one is an alternate spelling of (__asm__ -> asm); INVALID = none. *>
	TokenId canonical;
}

<*
 Token kinds with their fixed properties: `spelling` is the lexeme (when
 `!props.no_lexeme`), `category` the `symbol()` text for tokens whose symbol is
 not their spelling ("an identifier", "a number", ...), `props` their categories.
*>
enum TokenId : char (String spelling, String category, TokenProps props)
{
	INVALID { "", "invalid bytes", { .no_lexeme = true } },
	NL { "", "", {} },
	WHITESPACE { "", "", { .no_lexeme = true } },
	EOF { "", "", { .pp_expr_start = true } },
	// identifier containing solely basic character set characters
	IDENTIFIER { "", "an identifier", { .no_lexeme = true, .macro_identifier = true, .pp_expr_start = true, .recovery_decl_start = true } },
	// identifier with at least one extended character or UCN escape sequence
	EXTENDED_IDENTIFIER { "", "an identifier", { .no_lexeme = true, .macro_identifier = true, .pp_expr_start = true, .recovery_decl_start = true } },

	// string literals with prefixes
	STRING_LITERAL { "", "a string literal", { .no_lexeme = true, .pp_expr_start = true, .string_literal = true, .stringify_escapes = true } },
	STRING_LITERAL_UTF_16 { "", "a string literal", { .no_lexeme = true, .pp_expr_start = true, .string_literal = true, .stringify_escapes = true } },
	STRING_LITERAL_UTF_8 { "", "a string literal", { .no_lexeme = true, .pp_expr_start = true, .string_literal = true, .stringify_escapes = true } },
	STRING_LITERAL_UTF_32 { "", "a string literal", { .no_lexeme = true, .pp_expr_start = true, .string_literal = true, .stringify_escapes = true } },
	STRING_LITERAL_WIDE { "", "a string literal", { .no_lexeme = true, .pp_expr_start = true, .string_literal = true, .stringify_escapes = true } },

	// Any string literal with an embedded newline or EOF
	// Always a parser error; by default just a warning from preprocessor
	UNTERMINATED_STRING_LITERAL { "", "a string literal", { .no_lexeme = true } },

	// <foobar> only generated by preprocessor
	MACRO_STRING { "", "", { .no_lexeme = true } },

	// char literals with prefixes
	CHAR_LITERAL { "", "a character literal", { .no_lexeme = true, .pp_expr_start = true, .char_literal = true, .stringify_escapes = true } },
	CHAR_LITERAL_UTF_8 { "", "a character literal", { .no_lexeme = true, .pp_expr_start = true, .char_literal = true } },
	CHAR_LITERAL_UTF_16 { "", "a character literal", { .no_lexeme = true, .pp_expr_start = true, .char_literal = true, .stringify_escapes = true } },
	CHAR_LITERAL_UTF_32 { "", "a character literal", { .no_lexeme = true, .pp_expr_start = true, .char_literal = true, .stringify_escapes = true } },
	CHAR_LITERAL_WIDE { "", "a character literal", { .no_lexeme = true, .pp_expr_start = true, .char_literal = true, .stringify_escapes = true } },

	// Any character literal with nothing inside the quotes
	// Always a parser error; by default just a warning from preprocessor
	EMPTY_CHAR_LITERAL { "", "a character literal", { .no_lexeme = true, .char_literal = true } },

	// Any character literal with an embedded newline or EOF
	// Always a parser error; by default just a warning from preprocessor
	UNTERMINATED_CHAR_LITERAL { "", "a character literal", { .no_lexeme = true, .char_literal = true } },

	// `/* */` style comment without a closing `*/` before EOF
	UNTERMINATED_COMMENT { "", "", { .no_lexeme = true } },

	BANG { "!", "", { .pp_expr_start = true } },
	BANG_EQUAL { "!=", "", { .binary_prec = EQUALITY } },
	PIPE { "|", "", { .binary_prec = BIT_OR } },
	PIPE_PIPE { "||", "", { .binary_prec = BOOL_OR } },
	PIPE_EQUAL { "|=", "", { .binary_prec = ASSIGN } },
	EQUAL { "=", "", { .binary_prec = ASSIGN } },
	EQUAL_EQUAL { "==", "", { .binary_prec = EQUALITY } },
	L_PAREN { "(", "", { .pp_expr_start = true, .asm_open = true } },
	R_PAREN { ")", "", { .pp_expr_start = true } },
	L_BRACE { "{", "", { .digraph = true } },
	R_BRACE { "}", "", { .digraph = true } },
	L_BRACKET { "[", "", { .digraph = true } },
	R_BRACKET { "]", "", { .digraph = true } },
	PERIOD { ".", "", {} },
	ELLIPSIS { "...", "", {} },
	CARET { "^", "", { .binary_prec = BIT_XOR } },
	CARET_EQUAL { "^=", "", { .binary_prec = ASSIGN } },
	PLUS { "+", "", { .pp_expr_start = true, .binary_prec = ADDITIVE } },
	PLUS_PLUS { "++", "", {} },
	PLUS_EQUAL { "+=", "", { .binary_prec = ASSIGN } },
	MINUS { "-", "", { .pp_expr_start = true, .binary_prec = ADDITIVE } },
	MINUS_MINUS { "--", "", {} },
	MINUS_EQUAL { "-=", "", { .binary_prec = ASSIGN } },
	ASTERISK { "*", "", { .binary_prec = MULTIPLICATIVE } },
	ASTERISK_EQUAL { "*=", "", { .binary_prec = ASSIGN } },
	PERCENT { "%", "", { .binary_prec = MULTIPLICATIVE } },
	PERCENT_EQUAL { "%=", "", { .binary_prec = ASSIGN } },
	ARROW { "->", "", {} },
	COLON { ":", "", {} },
	COLON_COLON { "::", "", {} },
	SEMICOLON { ";", "", {} },
	SLASH { "/", "", { .binary_prec = MULTIPLICATIVE } },
	SLASH_EQUAL { "/=", "", { .binary_prec = ASSIGN } },
	COMMA { ",", "", { .binary_prec = COMMA } },
	AMPERSAND { "&", "", { .binary_prec = BIT_AND } },
	AMPERSAND_AMPERSAND { "&&", "", { .binary_prec = BOOL_AND } },
	AMPERSAND_EQUAL { "&=", "", { .binary_prec = ASSIGN } },
	QUESTION_MARK { "?", "", { .binary_prec = CONDITIONAL } },
	ANGLE_BRACKET_LEFT { "<", "", { .binary_prec = COMPARISON } },
	ANGLE_BRACKET_LEFT_EQUAL { "<=", "", { .binary_prec = COMPARISON } },
	ANGLE_BRACKET_ANGLE_BRACKET_LEFT { "<<", "", { .binary_prec = SHIFT } },
	ANGLE_BRACKET_ANGLE_BRACKET_LEFT_EQUAL { "<<=", "", { .binary_prec = ASSIGN } },
	ANGLE_BRACKET_RIGHT { ">", "", { .binary_prec = COMPARISON } },
	ANGLE_BRACKET_RIGHT_EQUAL { ">=", "", { .binary_prec = COMPARISON } },
	ANGLE_BRACKET_ANGLE_BRACKET_RIGHT { ">>", "", { .binary_prec = SHIFT } },
	ANGLE_BRACKET_ANGLE_BRACKET_RIGHT_EQUAL { ">>=", "", { .binary_prec = ASSIGN } },
	TILDE { "~", "", { .pp_expr_start = true } },
	HASH { "#", "", { .digraph = true } },
	HASH_HASH { "##", "", { .digraph = true } },

	// Special token for handling expansion of parameters to builtin preprocessor functions
	MACRO_PARAM_BUILTIN_FUNC { "", "", {} },
	// Special token for implementing builtin object macros
	MACRO_BUILTIN_OBJ { "", "", {} },

	// Special token to speed up preprocessing, `loc.end` will be an index to the param list.
	MACRO_PARAM { "", "", {} },
	// Special token to signal that the argument must be replaced without expansion (e.g. in concatenation)
	MACRO_PARAM_NO_EXPAND { "", "", {} },
	// Special token to speed up preprocessing, `loc.end` will be an index to the param list.
	STRINGIFY_PARAM { "", "", {} },
	// Same as stringify_param, but for var args
	STRINGIFY_VA_ARGS { "", "", {} },
	// Special macro whitespace, always equal to a single space
	MACRO_WS { " ", "", {} },

	// Special identifier for implementing __func__
	MACRO_FUNC { "__func__", "an identifier", { .macro_identifier = true } },
	// Special identifier for implementing __FUNCTION__
	MACRO_FUNCTION { "__FUNCTION__", "an identifier", { .macro_identifier = true } },
	// Special identifier for implementing __PRETTY_FUNCTION__
	MACRO_PRETTY_FUNC { "__PRETTY_FUNCTION__", "an identifier", { .macro_identifier = true } },

	KEYWORD_AUTO { "auto", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_AUTO_TYPE { "__auto_type", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_BREAK { "break", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_CASE { "case", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_CHAR { "char", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_CONST { "const", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_CONTINUE { "continue", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_DEFAULT { "default", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_DO { "do", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_DOUBLE { "double", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_ELSE { "else", "", { .macro_identifier = true } },
	KEYWORD_ENUM { "enum", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_EXTERN { "extern", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_FLOAT { "float", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_FOR { "for", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_GOTO { "goto", "", { .macro_identifier = true, .asm_open = true, .compound_item_start = true } },
	KEYWORD_IF { "if", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_INT { "int", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_LONG { "long", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_REGISTER { "register", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_RETURN { "return", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_SHORT { "short", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_SIGNED { "signed", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_SIGNED1 { "__signed", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_SIGNED2 { "__signed__", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_SIZEOF { "sizeof", "", { .macro_identifier = true } },
	KEYWORD_STATIC { "static", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_STRUCT { "struct", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_SWITCH { "switch", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_TYPEDEF { "typedef", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_TYPEOF1 { "__typeof", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true, .canonical = KEYWORD_TYPEOF } },
	KEYWORD_TYPEOF2 { "__typeof__", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true, .canonical = KEYWORD_TYPEOF } },
	KEYWORD_UNION { "union", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_UNSIGNED { "unsigned", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_VOID { "void", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_VOLATILE { "volatile", "", { .macro_identifier = true, .asm_open = true, .compound_item_start = true } },
	KEYWORD_WHILE { "while", "", { .macro_identifier = true, .compound_item_start = true } },

	// ISO C99
	KEYWORD_BOOL { "_Bool", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_COMPLEX { "_Complex", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_IMAGINARY { "_Imaginary", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_INLINE { "inline", "", { .macro_identifier = true, .asm_open = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_RESTRICT { "restrict", "", { .macro_identifier = true, .compound_item_start = true } },

	// ISO C11
	KEYWORD_ALIGNAS { "_Alignas", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_ALIGNOF { "_Alignof", "", { .macro_identifier = true } },
	KEYWORD_ATOMIC { "_Atomic", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_GENERIC { "_Generic", "", { .macro_identifier = true } },
	KEYWORD_NORETURN { "_Noreturn", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_STATIC_ASSERT { "_Static_assert", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_THREAD_LOCAL { "_Thread_local", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },

	// ISO C23
	KEYWORD_BIT_INT { "_BitInt", "", { .macro_identifier = true, .recovery_decl_start = true } },
	KEYWORD_C23_ALIGNAS { "alignas", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_C23_ALIGNOF { "alignof", "", { .macro_identifier = true } },
	KEYWORD_C23_BOOL { "bool", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_C23_STATIC_ASSERT { "static_assert", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_C23_THREAD_LOCAL { "thread_local", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_CONSTEXPR { "constexpr", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_TRUE { "true", "", { .macro_identifier = true, .pp_expr_start = true } },
	KEYWORD_FALSE { "false", "", { .macro_identifier = true, .pp_expr_start = true } },
	KEYWORD_NULLPTR { "nullptr", "", { .macro_identifier = true } },
	KEYWORD_TYPEOF_UNQUAL { "typeof_unqual", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_FLOAT16 { "_Float16", "", { .macro_identifier = true } },
	KEYWORD_FLOAT32 { "_Float32", "", { .macro_identifier = true } },
	KEYWORD_FLOAT64 { "_Float64", "", { .macro_identifier = true } },
	KEYWORD_FLOAT128 { "_Float128", "", { .macro_identifier = true } },
	KEYWORD_FLOAT32X { "_Float32x", "", { .macro_identifier = true } },
	KEYWORD_FLOAT64X { "_Float64x", "", { .macro_identifier = true } },
	KEYWORD_FLOAT128X { "_Float128x", "", { .macro_identifier = true } },
	KEYWORD_DFLOAT32 { "_Decimal32", "", { .macro_identifier = true } },
	KEYWORD_DFLOAT64 { "_Decimal64", "", { .macro_identifier = true } },
	KEYWORD_DFLOAT128 { "_Decimal128", "", { .macro_identifier = true } },
	KEYWORD_DFLOAT64X { "_Decimal64x", "", { .macro_identifier = true } },

	// ISO C2y
	KEYWORD_COUNTOF { "_Countof", "", { .macro_identifier = true } },

	// Preprocessor directives
	KEYWORD_INCLUDE { "include", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_INCLUDE_NEXT { "include_next", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_EMBED { "embed", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_DEFINE { "define", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_DEFINED { "defined", "", { .macro_identifier = true, .pp_expr_start = true } },
	KEYWORD_UNDEF { "undef", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_IFDEF { "ifdef", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_IFNDEF { "ifndef", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_ELIF { "elif", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_ELIFDEF { "elifdef", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_ELIFNDEF { "elifndef", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_ENDIF { "endif", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_ERROR { "error", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_WARNING { "warning", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_PRAGMA { "pragma", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_LINE { "line", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_VA_ARGS { "__VA_ARGS__", "", { .macro_identifier = true, .directive_keyword = true } },
	KEYWORD_VA_OPT { "__VA_OPT__", "", { .macro_identifier = true, .directive_keyword = true } },

	// gcc keywords
	KEYWORD_CONST1 { "__const", "", { .macro_identifier = true, .compound_item_start = true, .canonical = KEYWORD_CONST } },
	KEYWORD_CONST2 { "__const__", "", { .macro_identifier = true, .compound_item_start = true, .canonical = KEYWORD_CONST } },
	KEYWORD_INLINE1 { "__inline", "", { .macro_identifier = true, .asm_open = true, .recovery_decl_start = true, .compound_item_start = true, .canonical = KEYWORD_INLINE } },
	KEYWORD_INLINE2 { "__inline__", "", { .macro_identifier = true, .asm_open = true, .recovery_decl_start = true, .compound_item_start = true, .canonical = KEYWORD_INLINE } },
	KEYWORD_VOLATILE1 { "__volatile", "", { .macro_identifier = true, .asm_open = true, .compound_item_start = true, .canonical = KEYWORD_VOLATILE } },
	KEYWORD_VOLATILE2 { "__volatile__", "", { .macro_identifier = true, .asm_open = true, .compound_item_start = true, .canonical = KEYWORD_VOLATILE } },
	KEYWORD_RESTRICT1 { "__restrict", "", { .macro_identifier = true, .compound_item_start = true, .canonical = KEYWORD_RESTRICT } },
	KEYWORD_RESTRICT2 { "__restrict__", "", { .macro_identifier = true, .compound_item_start = true, .canonical = KEYWORD_RESTRICT } },
	KEYWORD_ALIGNOF1 { "__alignof", "", { .macro_identifier = true } },
	KEYWORD_ALIGNOF2 { "__alignof__", "", { .macro_identifier = true } },
	KEYWORD_TYPEOF { "typeof", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_ATTRIBUTE1 { "__attribute", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_ATTRIBUTE2 { "__attribute__", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_EXTENSION { "__extension__", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_ASM { "asm", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_ASM1 { "__asm", "", { .macro_identifier = true, .compound_item_start = true, .canonical = KEYWORD_ASM } },
	KEYWORD_ASM2 { "__asm__", "", { .macro_identifier = true, .compound_item_start = true, .canonical = KEYWORD_ASM } },
	KEYWORD_THREAD { "__thread", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	// __float128
	KEYWORD_FLOAT128_1 { "__float128", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_INT24 { "__int24", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_INT128 { "__int128", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_IMAG1 { "__imag", "", { .macro_identifier = true } },
	KEYWORD_IMAG2 { "__imag__", "", { .macro_identifier = true } },
	KEYWORD_REAL1 { "__real", "", { .macro_identifier = true } },
	KEYWORD_REAL2 { "__real__", "", { .macro_identifier = true } },

	// clang keywords
	KEYWORD_FP16 { "__fp16", "", { .macro_identifier = true } },
	KEYWORD_BF16 { "__bf16", "", { .macro_identifier = true } },

	// ms keywords
	KEYWORD_DECLSPEC { "__declspec", "", { .macro_identifier = true, .recovery_decl_start = true, .compound_item_start = true } },
	KEYWORD_INT64 { "__int64", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_INT64_2 { "_int64", "", { .macro_identifier = true, .compound_item_start = true } },
	KEYWORD_INT32 { "__int32", "", { .macro_identifier = true } },
	KEYWORD_INT32_2 { "_int32", "", { .macro_identifier = true } },
	KEYWORD_INT16 { "__int16", "", { .macro_identifier = true } },
	KEYWORD_INT16_2 { "_int16", "", { .macro_identifier = true } },
	KEYWORD_INT8 { "__int8", "", { .macro_identifier = true } },
	KEYWORD_INT8_2 { "_int8", "", { .macro_identifier = true } },
	KEYWORD_STDCALL { "__stdcall", "", { .macro_identifier = true } },
	KEYWORD_STDCALL2 { "_stdcall", "", { .macro_identifier = true } },
	KEYWORD_THISCALL { "__thiscall", "", { .macro_identifier = true } },
	KEYWORD_THISCALL2 { "_thiscall", "", { .macro_identifier = true } },
	KEYWORD_VECTORCALL { "__vectorcall", "", { .macro_identifier = true } },
	KEYWORD_VECTORCALL2 { "_vectorcall", "", { .macro_identifier = true } },
	KEYWORD_FASTCALL { "__fastcall", "", { .macro_identifier = true } },
	KEYWORD_FASTCALL2 { "_fastcall", "", { .macro_identifier = true } },
	KEYWORD_REGCALL { "__regcall", "", { .macro_identifier = true } },
	KEYWORD_CDECL { "__cdecl", "", { .macro_identifier = true } },
	KEYWORD_CDECL2 { "_cdecl", "", { .macro_identifier = true } },
	KEYWORD_FORCEINLINE { "__forceinline", "", { .macro_identifier = true } },
	KEYWORD_FORCEINLINE2 { "_forceinline", "", { .macro_identifier = true } },
	KEYWORD_UNALIGNED { "__unaligned", "", { .macro_identifier = true } },
	KEYWORD_UNALIGNED2 { "_unaligned", "", { .macro_identifier = true } },
	KEYWORD_PTR64 { "__ptr64", "", { .macro_identifier = true } },
	KEYWORD_PTR32 { "__ptr32", "", { .macro_identifier = true } },
	KEYWORD_SPTR { "__sptr", "", { .macro_identifier = true } },
	KEYWORD_UPTR { "__uptr", "", { .macro_identifier = true } },

	// Type nullability
	KEYWORD_NONNULL { "_Nonnull", "", { .macro_identifier = true } },
	KEYWORD_NULLABLE { "_Nullable", "", { .macro_identifier = true } },
	KEYWORD_NULLABLE_RESULT { "_Nullable_result", "", { .macro_identifier = true } },
	KEYWORD_NULL_UNSPECIFIED { "_Null_unspecified", "", { .macro_identifier = true } },

	// Generated by #embed directive
	// Decimal value with no prefix or suffix
	EMBED_BYTE { "", "a number", { .no_lexeme = true } },

	// preprocessor number
	// An optional period, followed by a digit 0-9, followed by any number of letters
	// digits, underscores, periods, and exponents (e+, e-, E+, E-, p+, p-, P+, P-)
	PP_NUM { "", "a number", { .no_lexeme = true, .pp_expr_start = true } },

	// preprocessor placemarker token
	// generated if `##` is used with a zero-token argument
	// removed after substitution, so the parser should never see this
	// See C99 6.10.3.3.2
	PLACEMARKER { "", "", {} },

	// Virtual linemarker token output from preprocessor to indicate start of a new include
	INCLUDE_START { "", "", { .virtual_marker = true } },

	// Virtual linemarker token output from preprocessor to indicate resuming a file after
	// completion of the preceding #include
	INCLUDE_RESUME { "", "", { .virtual_marker = true } },

	// Virtual linemarker token output from preprocessor to represent actual linemarker in the source file
	LINEMARKER { "", "", { .virtual_marker = true } },

	// A comment token if asked to preserve comments.
	COMMENT { "", "", { .no_lexeme = true } },

	// Incomplete universal character name
	// This happens if the source text contains `\u` or `\U` followed by an insufficient number of hex
	// digits. This token id represents just the backslash; the subsequent `u` or `U` will be treated as the
	// leading character of the following identifier token.
	INCOMPLETE_UCN { "\\", "", {} },
}

<* Return true if token is identifier or keyword. *>
fn bool TokenId.is_macro_identifier(self) => self.props.macro_identifier;

<*
 Turn macro keywords into identifiers.
 `KEYWORD_DEFINED` is special since it should only turn into an identifier if
 we are *not* in an #if or #elif expression.
*>
fn void TokenId.simplify_macro_keyword_extra(&self, bool defined_to_identifier)
{
	if (self.props.directive_keyword || (defined_to_identifier && *self == KEYWORD_DEFINED)) *self = IDENTIFIER;
}


fn void TokenId.simplify_macro_keyword(&self) => self.simplify_macro_keyword_extra(false);

<*
 The fixed spelling of a token, or NO_LEXEME~ for tokens whose text varies.
 @require self != INCLUDE_START && self != INCLUDE_RESUME && self != LINEMARKER
*>
fn String? TokenId.lexeme(self)
{
	if (self.props.virtual_marker) unreachable("lexeme of a virtual linemarker token");
	if (self.props.no_lexeme) return NO_LEXEME~;
	return self.spelling;
}

<* Zig `Token.Id.symbol`: the spelling, or the category text for variable-spelling tokens. *>
fn String TokenId.symbol(self)
{
	if (self == MACRO_STRING) unreachable("symbol of a macro string");
	if (self.category.len) return self.category;
	return self.lexeme()!!;
}

<*
 Tokens that can start an expression parsed by Preprocessor.expr.
 eof, r_paren and string literals cannot actually start a preprocessor
 expression, but they are included so the parser can give a nicer error.
*>
fn bool TokenId.valid_preprocessor_expr_start(self) => self.props.pp_expr_start;

fn bool TokenId.allows_digraphs(self, LangOpts langopts) => self.props.digraph && langopts.has_digraphs();

fn bool TokenId.can_open_gcc_asm_stmt(self) => self.props.asm_open;

fn bool TokenId.is_string_literal(self) => self.props.string_literal;

<* The expression node built for binary/assignment operator `self` (Zig `Parser.binExpr` tag). Only valid for tokens with a binary precedence. *>
fn NodeKind TokenId.binary_kind(self)
{
	switch (self)
	{
		case COMMA: return NodeKind.COMMA_EXPR;
		case PIPE_PIPE: return NodeKind.BOOL_OR_EXPR;
		case AMPERSAND_AMPERSAND: return NodeKind.BOOL_AND_EXPR;
		case PIPE: return NodeKind.BIT_OR_EXPR;
		case CARET: return NodeKind.BIT_XOR_EXPR;
		case AMPERSAND: return NodeKind.BIT_AND_EXPR;
		case EQUAL_EQUAL: return NodeKind.EQUAL_EXPR;
		case BANG_EQUAL: return NodeKind.NOT_EQUAL_EXPR;
		case ANGLE_BRACKET_LEFT: return NodeKind.LESS_THAN_EXPR;
		case ANGLE_BRACKET_LEFT_EQUAL: return NodeKind.LESS_THAN_EQUAL_EXPR;
		case ANGLE_BRACKET_RIGHT: return NodeKind.GREATER_THAN_EXPR;
		case ANGLE_BRACKET_RIGHT_EQUAL: return NodeKind.GREATER_THAN_EQUAL_EXPR;
		case ANGLE_BRACKET_ANGLE_BRACKET_LEFT: return NodeKind.SHL_EXPR;
		case ANGLE_BRACKET_ANGLE_BRACKET_RIGHT: return NodeKind.SHR_EXPR;
		case PLUS: return NodeKind.ADD_EXPR;
		case MINUS: return NodeKind.SUB_EXPR;
		case ASTERISK: return NodeKind.MUL_EXPR;
		case SLASH: return NodeKind.DIV_EXPR;
		case PERCENT: return NodeKind.MOD_EXPR;
		case EQUAL: return NodeKind.ASSIGN_EXPR;
		case ASTERISK_EQUAL: return NodeKind.MUL_ASSIGN_EXPR;
		case SLASH_EQUAL: return NodeKind.DIV_ASSIGN_EXPR;
		case PERCENT_EQUAL: return NodeKind.MOD_ASSIGN_EXPR;
		case PLUS_EQUAL: return NodeKind.ADD_ASSIGN_EXPR;
		case MINUS_EQUAL: return NodeKind.SUB_ASSIGN_EXPR;
		case ANGLE_BRACKET_ANGLE_BRACKET_LEFT_EQUAL: return NodeKind.SHL_ASSIGN_EXPR;
		case ANGLE_BRACKET_ANGLE_BRACKET_RIGHT_EQUAL: return NodeKind.SHR_ASSIGN_EXPR;
		case AMPERSAND_EQUAL: return NodeKind.BIT_AND_ASSIGN_EXPR;
		case CARET_EQUAL: return NodeKind.BIT_XOR_ASSIGN_EXPR;
		case PIPE_EQUAL: return NodeKind.BIT_OR_ASSIGN_EXPR;
		default: unreachable("not a binary expression operator");
	}
}

fn bool TokenId.is_char_literal(self) => self.props.char_literal;

fn bool TokenId.is_identifier(self) => self == IDENTIFIER || self == EXTENDED_IDENTIFIER;

<* Zig stringify's `is_str`: the token's backslashes are escaped when stringified. *>
fn bool TokenId.stringify_escapes(self) => self.props.stringify_escapes;

<* The token can begin a declaration; parser recovery stops before it. *>
fn bool TokenId.starts_declaration(self) => self.props.recovery_decl_start;

<* The token can begin a statement or declaration inside a compound statement. *>
fn bool TokenId.starts_compound_item(self) => self.props.compound_item_start;

<* The keyword `self` is an alternate spelling of (`__asm__` -> `asm`), else `self`. *>
fn TokenId TokenId.canonical(self) => self.props.canonical == INVALID ? self : self.props.canonical;

enum HidesetContext : char
{
	FUNC,
	OBJ,
}

fn bool TokenId.should_track_hideset(self, HidesetContext context)
{
	if (self.is_macro_identifier()) return true;
	return self == R_PAREN && context == FUNC;
}

struct Keyword
{
	String name;
	TokenId id;
}

<* Zig's `all_kws`, sorted by bytes for binary search. *>
const Keyword[152] KEYWORDS = {
	{ "_Alignas", KEYWORD_ALIGNAS },
	{ "_Alignof", KEYWORD_ALIGNOF },
	{ "_Atomic", KEYWORD_ATOMIC },
	{ "_BitInt", KEYWORD_BIT_INT },
	{ "_Bool", KEYWORD_BOOL },
	{ "_Complex", KEYWORD_COMPLEX },
	{ "_Countof", KEYWORD_COUNTOF },
	{ "_Decimal128", KEYWORD_DFLOAT128 },
	{ "_Decimal32", KEYWORD_DFLOAT32 },
	{ "_Decimal64", KEYWORD_DFLOAT64 },
	{ "_Decimal64x", KEYWORD_DFLOAT64X },
	{ "_Float128", KEYWORD_FLOAT128 },
	{ "_Float128x", KEYWORD_FLOAT128X },
	{ "_Float16", KEYWORD_FLOAT16 },
	{ "_Float32", KEYWORD_FLOAT32 },
	{ "_Float32x", KEYWORD_FLOAT32X },
	{ "_Float64", KEYWORD_FLOAT64 },
	{ "_Float64x", KEYWORD_FLOAT64X },
	{ "_Generic", KEYWORD_GENERIC },
	{ "_Imaginary", KEYWORD_IMAGINARY },
	{ "_Nonnull", KEYWORD_NONNULL },
	{ "_Noreturn", KEYWORD_NORETURN },
	{ "_Null_unspecified", KEYWORD_NULL_UNSPECIFIED },
	{ "_Nullable", KEYWORD_NULLABLE },
	{ "_Nullable_result", KEYWORD_NULLABLE_RESULT },
	{ "_Static_assert", KEYWORD_STATIC_ASSERT },
	{ "_Thread_local", KEYWORD_THREAD_LOCAL },
	{ "__FUNCTION__", MACRO_FUNCTION },
	{ "__PRETTY_FUNCTION__", MACRO_PRETTY_FUNC },
	{ "__VA_ARGS__", KEYWORD_VA_ARGS },
	{ "__VA_OPT__", KEYWORD_VA_OPT },
	{ "__alignof", KEYWORD_ALIGNOF1 },
	{ "__alignof__", KEYWORD_ALIGNOF2 },
	{ "__asm", KEYWORD_ASM1 },
	{ "__asm__", KEYWORD_ASM2 },
	{ "__attribute", KEYWORD_ATTRIBUTE1 },
	{ "__attribute__", KEYWORD_ATTRIBUTE2 },
	{ "__auto_type", KEYWORD_AUTO_TYPE },
	{ "__bf16", KEYWORD_BF16 },
	{ "__cdecl", KEYWORD_CDECL },
	{ "__const", KEYWORD_CONST1 },
	{ "__const__", KEYWORD_CONST2 },
	{ "__declspec", KEYWORD_DECLSPEC },
	{ "__extension__", KEYWORD_EXTENSION },
	{ "__fastcall", KEYWORD_FASTCALL },
	{ "__float128", KEYWORD_FLOAT128_1 },
	{ "__forceinline", KEYWORD_FORCEINLINE },
	{ "__fp16", KEYWORD_FP16 },
	{ "__func__", MACRO_FUNC },
	{ "__imag", KEYWORD_IMAG1 },
	{ "__imag__", KEYWORD_IMAG2 },
	{ "__inline", KEYWORD_INLINE1 },
	{ "__inline__", KEYWORD_INLINE2 },
	{ "__int128", KEYWORD_INT128 },
	{ "__int16", KEYWORD_INT16 },
	{ "__int24", KEYWORD_INT24 },
	{ "__int32", KEYWORD_INT32 },
	{ "__int64", KEYWORD_INT64 },
	{ "__int8", KEYWORD_INT8 },
	{ "__ptr32", KEYWORD_PTR32 },
	{ "__ptr64", KEYWORD_PTR64 },
	{ "__real", KEYWORD_REAL1 },
	{ "__real__", KEYWORD_REAL2 },
	{ "__restrict", KEYWORD_RESTRICT1 },
	{ "__restrict__", KEYWORD_RESTRICT2 },
	{ "__signed", KEYWORD_SIGNED1 },
	{ "__signed__", KEYWORD_SIGNED2 },
	{ "__sptr", KEYWORD_SPTR },
	{ "__stdcall", KEYWORD_STDCALL },
	{ "__thiscall", KEYWORD_THISCALL },
	{ "__thread", KEYWORD_THREAD },
	{ "__typeof", KEYWORD_TYPEOF1 },
	{ "__typeof__", KEYWORD_TYPEOF2 },
	{ "__unaligned", KEYWORD_UNALIGNED },
	{ "__uptr", KEYWORD_UPTR },
	{ "__vectorcall", KEYWORD_VECTORCALL },
	{ "__volatile", KEYWORD_VOLATILE1 },
	{ "__volatile__", KEYWORD_VOLATILE2 },
	{ "_cdecl", KEYWORD_CDECL2 },
	{ "_fastcall", KEYWORD_FASTCALL2 },
	{ "_forceinline", KEYWORD_FORCEINLINE2 },
	{ "_int16", KEYWORD_INT16_2 },
	{ "_int32", KEYWORD_INT32_2 },
	{ "_int64", KEYWORD_INT64_2 },
	{ "_int8", KEYWORD_INT8_2 },
	{ "_regcall", KEYWORD_REGCALL },
	{ "_stdcall", KEYWORD_STDCALL2 },
	{ "_thiscall", KEYWORD_THISCALL2 },
	{ "_unaligned", KEYWORD_UNALIGNED2 },
	{ "_vectorcall", KEYWORD_VECTORCALL2 },
	{ "alignas", KEYWORD_C23_ALIGNAS },
	{ "alignof", KEYWORD_C23_ALIGNOF },
	{ "asm", KEYWORD_ASM },
	{ "auto", KEYWORD_AUTO },
	{ "bool", KEYWORD_C23_BOOL },
	{ "break", KEYWORD_BREAK },
	{ "case", KEYWORD_CASE },
	{ "char", KEYWORD_CHAR },
	{ "const", KEYWORD_CONST },
	{ "constexpr", KEYWORD_CONSTEXPR },
	{ "continue", KEYWORD_CONTINUE },
	{ "default", KEYWORD_DEFAULT },
	{ "define", KEYWORD_DEFINE },
	{ "defined", KEYWORD_DEFINED },
	{ "do", KEYWORD_DO },
	{ "double", KEYWORD_DOUBLE },
	{ "elif", KEYWORD_ELIF },
	{ "elifdef", KEYWORD_ELIFDEF },
	{ "elifndef", KEYWORD_ELIFNDEF },
	{ "else", KEYWORD_ELSE },
	{ "embed", KEYWORD_EMBED },
	{ "endif", KEYWORD_ENDIF },
	{ "enum", KEYWORD_ENUM },
	{ "error", KEYWORD_ERROR },
	{ "extern", KEYWORD_EXTERN },
	{ "false", KEYWORD_FALSE },
	{ "float", KEYWORD_FLOAT },
	{ "for", KEYWORD_FOR },
	{ "goto", KEYWORD_GOTO },
	{ "if", KEYWORD_IF },
	{ "ifdef", KEYWORD_IFDEF },
	{ "ifndef", KEYWORD_IFNDEF },
	{ "include", KEYWORD_INCLUDE },
	{ "include_next", KEYWORD_INCLUDE_NEXT },
	{ "inline", KEYWORD_INLINE },
	{ "int", KEYWORD_INT },
	{ "line", KEYWORD_LINE },
	{ "long", KEYWORD_LONG },
	{ "nullptr", KEYWORD_NULLPTR },
	{ "pragma", KEYWORD_PRAGMA },
	{ "register", KEYWORD_REGISTER },
	{ "restrict", KEYWORD_RESTRICT },
	{ "return", KEYWORD_RETURN },
	{ "short", KEYWORD_SHORT },
	{ "signed", KEYWORD_SIGNED },
	{ "sizeof", KEYWORD_SIZEOF },
	{ "static", KEYWORD_STATIC },
	{ "static_assert", KEYWORD_C23_STATIC_ASSERT },
	{ "struct", KEYWORD_STRUCT },
	{ "switch", KEYWORD_SWITCH },
	{ "thread_local", KEYWORD_C23_THREAD_LOCAL },
	{ "true", KEYWORD_TRUE },
	{ "typedef", KEYWORD_TYPEDEF },
	{ "typeof", KEYWORD_TYPEOF },
	{ "typeof_unqual", KEYWORD_TYPEOF_UNQUAL },
	{ "undef", KEYWORD_UNDEF },
	{ "union", KEYWORD_UNION },
	{ "unsigned", KEYWORD_UNSIGNED },
	{ "void", KEYWORD_VOID },
	{ "volatile", KEYWORD_VOLATILE },
	{ "warning", KEYWORD_WARNING },
	{ "while", KEYWORD_WHILE },
};

<* Byte-wise three-way comparison (memcmp order, shorter prefix first). *>
fn int compare_bytes(String a, String b)
{
	usz n = a.len < b.len ? a.len : b.len;
	for (usz i = 0; i < n; i++)
	{
		if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
	}
	if (a.len == b.len) return 0;
	return a.len < b.len ? -1 : 1;
}

<* `all_kws.get`: the keyword spelled `str`, or IDENTIFIER. *>
fn TokenId lookup_keyword(String str)
{
	usz lo = 0;
	usz hi = KEYWORDS.len;
	while (lo < hi)
	{
		usz mid = lo + (hi - lo) / 2;
		int c = compare_bytes(str, KEYWORDS[mid].name);
		if (c == 0) return KEYWORDS[mid].id;
		if (c < 0)
		{
			hi = mid;
		}
		else
		{
			lo = mid + 1;
		}
	}
	return IDENTIFIER;
}

<*
 Token.getTokenId: double underscore and underscore + capital letter
 identifiers belong to the implementation namespace, so they always become
 keywords; other keywords are gated by the language options.
*>
fn TokenId get_token_id(LangOpts langopts, Target* target, String str)
{
	TokenId kw = lookup_keyword(str);
	if (kw == IDENTIFIER) return IDENTIFIER;
	Standard standard = langopts.standard;
	switch (kw)
	{
		case KEYWORD_INLINE:
			return standard.is_gnu || standard.at_least(C99) ? kw : IDENTIFIER;
		case KEYWORD_RESTRICT:
			return standard.at_least(C99) ? kw : IDENTIFIER;
		case KEYWORD_TYPEOF:
			return standard.is_gnu || standard.at_least(C23) ? kw : IDENTIFIER;
		case KEYWORD_ASM:
			return standard.is_gnu ? kw : IDENTIFIER;
		case KEYWORD_DECLSPEC:
			return langopts.declspec_attrs ? kw : IDENTIFIER;
		case KEYWORD_INT24:
			return target.has_int24() ? kw : IDENTIFIER;
		case KEYWORD_C23_ALIGNAS:
		case KEYWORD_C23_ALIGNOF:
		case KEYWORD_C23_BOOL:
		case KEYWORD_C23_STATIC_ASSERT:
		case KEYWORD_C23_THREAD_LOCAL:
		case KEYWORD_CONSTEXPR:
		case KEYWORD_TRUE:
		case KEYWORD_FALSE:
		case KEYWORD_NULLPTR:
		case KEYWORD_TYPEOF_UNQUAL:
			return standard.at_least(C23) ? kw : IDENTIFIER;
		case KEYWORD_INT64:
		case KEYWORD_INT64_2:
		case KEYWORD_INT32:
		case KEYWORD_INT32_2:
		case KEYWORD_INT16:
		case KEYWORD_INT16_2:
		case KEYWORD_INT8:
		case KEYWORD_INT8_2:
		case KEYWORD_STDCALL2:
		case KEYWORD_THISCALL2:
		case KEYWORD_VECTORCALL2:
		case KEYWORD_FASTCALL2:
		case KEYWORD_CDECL2:
		case KEYWORD_FORCEINLINE:
		case KEYWORD_FORCEINLINE2:
		case KEYWORD_UNALIGNED:
		case KEYWORD_UNALIGNED2:
		case KEYWORD_PTR64:
		case KEYWORD_PTR32:
		case KEYWORD_SPTR:
		case KEYWORD_UPTR:
			return langopts.ms_extensions ? kw : IDENTIFIER;
		case KEYWORD_FLOAT32:
		case KEYWORD_FLOAT64:
		case KEYWORD_FLOAT128:
		case KEYWORD_FLOAT32X:
		case KEYWORD_FLOAT64X:
		case KEYWORD_FLOAT128X:
		case KEYWORD_DFLOAT32:
		case KEYWORD_DFLOAT64:
		case KEYWORD_DFLOAT128:
		case KEYWORD_DFLOAT64X:
			return langopts.emulate == CLANG ? IDENTIFIER : kw;
		default:
			return kw;
	}
}

<*
 Borrows `buf` (which must be NUL-terminated: buf.ptr[buf.len] == 0) and
 `splice_locs`; set up with `init`.
*>
struct Tokenizer
{
	String buf;
	uint index;
	SourceId source;
	LangOpts langopts;
	<* Borrowed; gates target-specific keywords (`__int24`). *>
	Target* target;
	uint line;
	uint splice_index;
	uint[] splice_locs;
}

<*
 @require buf.ptr != null && buf.ptr[buf.len] == 0 : "buf must be NUL-terminated"
 @require (ulong)buf.len < 0xFFFF_FFFF
*>
fn void Tokenizer.init(&self, String buf, SourceId source, LangOpts langopts, Target* target, uint[] splice_locs = {})
{
	*self = { .buf = buf, .source = source, .langopts = langopts, .target = target, .line = 1, .splice_locs = splice_locs };
}

enum State : char @private
{
	START,
	WHITESPACE,
	U,
	U8,
	CAPITAL_U,
	CAPITAL_L,
	STRING_LITERAL,
	CHAR_LITERAL_START,
	CHAR_LITERAL,
	CHAR_ESCAPE_SEQUENCE,
	STRING_ESCAPE_SEQUENCE,
	IDENTIFIER,
	EXTENDED_IDENTIFIER,
	EQUAL,
	BANG,
	PIPE,
	COLON,
	PERCENT,
	ASTERISK,
	PLUS,
	ANGLE_BRACKET_LEFT,
	ANGLE_BRACKET_ANGLE_BRACKET_LEFT,
	ANGLE_BRACKET_RIGHT,
	ANGLE_BRACKET_ANGLE_BRACKET_RIGHT,
	CARET,
	PERIOD,
	PERIOD2,
	MINUS,
	SLASH,
	AMPERSAND,
	HASH,
	HASH_DIGRAPH,
	HASH_HASH_DIGRAPH_PARTIAL,
	LINE_COMMENT,
	MULTI_LINE_COMMENT,
	MULTI_LINE_COMMENT_ASTERISK,
	MULTI_LINE_COMMENT_DONE,
	PP_NUM,
	PP_NUM_EXPONENT,
	PP_NUM_DIGIT_SEPARATOR,
}

<* The token id for an identifier ending at the current index. *>
fn TokenId Tokenizer.identifier_end(&self, uint start, bool extended)
{
	if (extended) return EXTENDED_IDENTIFIER;
	return get_token_id(self.langopts, self.target, self.buf[start:self.index - start]);
}

fn Token Tokenizer.next(&self)
{
	char* buf = self.buf.ptr;
	uint len = (uint)self.buf.len;
	uint start = self.index;
	TokenId id = EOF;

	switch LOOP: (State.START)
	{
		case START:
			switch (buf[self.index])
			{
				case 0:
					if (self.index != len)
					{
						id = INVALID;
						self.index++;
					}
				case '\n':
					id = NL;
					self.index++;
					self.line++;
				case '"':
					id = STRING_LITERAL;
					nextcase LOOP: State.STRING_LITERAL;
				case '\'':
					id = CHAR_LITERAL;
					nextcase LOOP: State.CHAR_LITERAL_START;
				case 'u':
					nextcase LOOP: State.U;
				case 'U':
					nextcase LOOP: State.CAPITAL_U;
				case 'L':
					nextcase LOOP: State.CAPITAL_L;
				case '\\':
					UCNKind ucn_kind = ucn_classify(self.buf[self.index..]);
					switch (ucn_kind)
					{
						case NONE:
							self.index++;
							id = INVALID;
						case INCOMPLETE:
							self.index++;
							id = INCOMPLETE_UCN;
						case HEX4:
						case HEX8:
							self.index += ucn_kind.consumed;
							id = EXTENDED_IDENTIFIER;
							nextcase LOOP: State.EXTENDED_IDENTIFIER;
					}
				case 'a'..'t':
				case 'v'..'z':
				case 'A'..'K':
				case 'M'..'T':
				case 'V'..'Z':
				case '_':
					nextcase LOOP: State.IDENTIFIER;
				case '=':
					nextcase LOOP: State.EQUAL;
				case '!':
					nextcase LOOP: State.BANG;
				case '|':
					nextcase LOOP: State.PIPE;
				case '(':
					id = L_PAREN;
					self.index++;
				case ')':
					id = R_PAREN;
					self.index++;
				case '[':
					id = L_BRACKET;
					self.index++;
				case ']':
					id = R_BRACKET;
					self.index++;
				case ';':
					id = SEMICOLON;
					self.index++;
				case ',':
					id = COMMA;
					self.index++;
				case '?':
					id = QUESTION_MARK;
					self.index++;
				case ':':
					nextcase LOOP: State.COLON;
				case '%':
					nextcase LOOP: State.PERCENT;
				case '*':
					nextcase LOOP: State.ASTERISK;
				case '+':
					nextcase LOOP: State.PLUS;
				case '<':
					nextcase LOOP: State.ANGLE_BRACKET_LEFT;
				case '>':
					nextcase LOOP: State.ANGLE_BRACKET_RIGHT;
				case '^':
					nextcase LOOP: State.CARET;
				case '{':
					id = L_BRACE;
					self.index++;
				case '}':
					id = R_BRACE;
					self.index++;
				case '~':
					id = TILDE;
					self.index++;
				case '.':
					nextcase LOOP: State.PERIOD;
				case '-':
					nextcase LOOP: State.MINUS;
				case '/':
					nextcase LOOP: State.SLASH;
				case '&':
					nextcase LOOP: State.AMPERSAND;
				case '#':
					nextcase LOOP: State.HASH;
				case '0'..'9':
					nextcase LOOP: State.PP_NUM;
				case '\t':
				case '\v':
				case '\f':
				case ' ':
					nextcase LOOP: State.WHITESPACE;
				case '$':
					if (self.langopts.dollars_in_identifiers) nextcase LOOP: State.EXTENDED_IDENTIFIER;
					id = INVALID;
					self.index++;
				case 0x1A:
					if (self.langopts.ms_extensions)
					{
						id = EOF;
					}
					else
					{
						id = INVALID;
						self.index++;
					}
				case 0x80..0xFF:
					nextcase LOOP: State.EXTENDED_IDENTIFIER;
				default:
					id = INVALID;
					self.index++;
			}
		case WHITESPACE:
			self.index++;
			switch (buf[self.index])
			{
				case '\t':
				case '\v':
				case '\f':
				case ' ':
					nextcase LOOP: State.WHITESPACE;
				default:
					id = WHITESPACE;
			}
		case U:
			self.index++;
			switch (buf[self.index])
			{
				case '8':
					nextcase LOOP: State.U8;
				case '\'':
					id = CHAR_LITERAL_UTF_16;
					nextcase LOOP: State.CHAR_LITERAL_START;
				case '"':
					id = STRING_LITERAL_UTF_16;
					nextcase LOOP: State.STRING_LITERAL;
				default:
					self.index--;
					nextcase LOOP: State.IDENTIFIER;
			}
		case U8:
			self.index++;
			switch (buf[self.index])
			{
				case '"':
					id = STRING_LITERAL_UTF_8;
					nextcase LOOP: State.STRING_LITERAL;
				case '\'':
					id = CHAR_LITERAL_UTF_8;
					nextcase LOOP: State.CHAR_LITERAL_START;
				default:
					self.index--;
					nextcase LOOP: State.IDENTIFIER;
			}
		case CAPITAL_U:
			self.index++;
			switch (buf[self.index])
			{
				case '\'':
					id = CHAR_LITERAL_UTF_32;
					nextcase LOOP: State.CHAR_LITERAL_START;
				case '"':
					id = STRING_LITERAL_UTF_32;
					nextcase LOOP: State.STRING_LITERAL;
				default:
					self.index--;
					nextcase LOOP: State.IDENTIFIER;
			}
		case CAPITAL_L:
			self.index++;
			switch (buf[self.index])
			{
				case '\'':
					id = CHAR_LITERAL_WIDE;
					nextcase LOOP: State.CHAR_LITERAL_START;
				case '"':
					id = STRING_LITERAL_WIDE;
					nextcase LOOP: State.STRING_LITERAL;
				default:
					self.index--;
					nextcase LOOP: State.IDENTIFIER;
			}
		case STRING_LITERAL:
			self.index++;
			switch (buf[self.index])
			{
				case '\\':
					nextcase LOOP: State.STRING_ESCAPE_SEQUENCE;
				case '"':
					self.index++;
				case '\n':
					id = UNTERMINATED_STRING_LITERAL;
				case '\r':
					unreachable("carriage returns are removed when the source is added");
				case 0:
					if (self.index != len) nextcase LOOP: State.STRING_LITERAL;
					id = UNTERMINATED_STRING_LITERAL;
				default:
					nextcase LOOP: State.STRING_LITERAL;
			}
		case CHAR_LITERAL_START:
			self.index++;
			switch (buf[self.index])
			{
				case '\\':
					nextcase LOOP: State.CHAR_ESCAPE_SEQUENCE;
				case '\'':
					id = EMPTY_CHAR_LITERAL;
					self.index++;
				case '\n':
					id = UNTERMINATED_CHAR_LITERAL;
				case 0:
					if (self.index != len) nextcase LOOP: State.CHAR_LITERAL;
					id = UNTERMINATED_CHAR_LITERAL;
				default:
					nextcase LOOP: State.CHAR_LITERAL;
			}
		case CHAR_LITERAL:
			self.index++;
			switch (buf[self.index])
			{
				case '\\':
					nextcase LOOP: State.CHAR_ESCAPE_SEQUENCE;
				case '\'':
					self.index++;
				case '\n':
					id = UNTERMINATED_CHAR_LITERAL;
				case 0:
					if (self.index != len) nextcase LOOP: State.CHAR_LITERAL;
					id = UNTERMINATED_CHAR_LITERAL;
				default:
					nextcase LOOP: State.CHAR_LITERAL;
			}
		case CHAR_ESCAPE_SEQUENCE:
			self.index++;
			switch (buf[self.index])
			{
				case '\r':
				case '\n':
					id = UNTERMINATED_CHAR_LITERAL;
				case 0:
					if (self.index != len) nextcase LOOP: State.CHAR_LITERAL;
					id = UNTERMINATED_CHAR_LITERAL;
				default:
					nextcase LOOP: State.CHAR_LITERAL;
			}
		case STRING_ESCAPE_SEQUENCE:
			self.index++;
			switch (buf[self.index])
			{
				case '\r':
				case '\n':
					id = UNTERMINATED_STRING_LITERAL;
				case 0:
					if (self.index != len) nextcase LOOP: State.STRING_LITERAL;
					id = UNTERMINATED_STRING_LITERAL;
				default:
					nextcase LOOP: State.STRING_LITERAL;
			}
		// Zig handles both identifier states with one `inline` prong; the two
		// cases below are identical except for the state they loop back to.
		case IDENTIFIER:
			self.index++;
			switch (buf[self.index])
			{
				case 'a'..'z':
				case 'A'..'Z':
				case '_':
				case '0'..'9':
					nextcase LOOP: State.IDENTIFIER;
				case '$':
					if (self.langopts.dollars_in_identifiers) nextcase LOOP: State.EXTENDED_IDENTIFIER;
					id = self.identifier_end(start, false);
				case 0x80..0xFF:
					nextcase LOOP: State.EXTENDED_IDENTIFIER;
				case '\\':
					UCNKind ucn_kind = ucn_classify(self.buf[self.index..]);
					if (ucn_kind == HEX4 || ucn_kind == HEX8)
					{
						self.index += ucn_kind.consumed;
						nextcase LOOP: State.EXTENDED_IDENTIFIER;
					}
					id = self.identifier_end(start, false);
				default:
					id = self.identifier_end(start, false);
			}
		case EXTENDED_IDENTIFIER:
			self.index++;
			switch (buf[self.index])
			{
				case 'a'..'z':
				case 'A'..'Z':
				case '_':
				case '0'..'9':
					nextcase LOOP: State.EXTENDED_IDENTIFIER;
				case '$':
					if (self.langopts.dollars_in_identifiers) nextcase LOOP: State.EXTENDED_IDENTIFIER;
					id = EXTENDED_IDENTIFIER;
				case 0x80..0xFF:
					nextcase LOOP: State.EXTENDED_IDENTIFIER;
				case '\\':
					UCNKind ucn_kind = ucn_classify(self.buf[self.index..]);
					if (ucn_kind == HEX4 || ucn_kind == HEX8)
					{
						self.index += ucn_kind.consumed;
						nextcase LOOP: State.EXTENDED_IDENTIFIER;
					}
					id = EXTENDED_IDENTIFIER;
				default:
					id = EXTENDED_IDENTIFIER;
			}
		case EQUAL:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = EQUAL_EQUAL;
					self.index++;
				default:
					id = EQUAL;
			}
		case BANG:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = BANG_EQUAL;
					self.index++;
				default:
					id = BANG;
			}
		case PIPE:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = PIPE_EQUAL;
					self.index++;
				case '|':
					id = PIPE_PIPE;
					self.index++;
				default:
					id = PIPE;
			}
		case COLON:
			self.index++;
			switch (buf[self.index])
			{
				case '>':
					if (self.langopts.has_digraphs())
					{
						id = R_BRACKET;
						self.index++;
					}
					else
					{
						id = COLON;
					}
				case ':':
					id = COLON_COLON;
					self.index++;
				default:
					id = COLON;
			}
		case PERCENT:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = PERCENT_EQUAL;
					self.index++;
				case '>':
					if (self.langopts.has_digraphs())
					{
						id = R_BRACE;
						self.index++;
					}
					else
					{
						id = PERCENT;
					}
				case ':':
					if (self.langopts.has_digraphs()) nextcase LOOP: State.HASH_DIGRAPH;
					id = PERCENT;
				default:
					id = PERCENT;
			}
		case ASTERISK:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = ASTERISK_EQUAL;
					self.index++;
				default:
					id = ASTERISK;
			}
		case PLUS:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = PLUS_EQUAL;
					self.index++;
				case '+':
					id = PLUS_PLUS;
					self.index++;
				default:
					id = PLUS;
			}
		case ANGLE_BRACKET_LEFT:
			self.index++;
			switch (buf[self.index])
			{
				case '<':
					nextcase LOOP: State.ANGLE_BRACKET_ANGLE_BRACKET_LEFT;
				case '=':
					id = ANGLE_BRACKET_LEFT_EQUAL;
					self.index++;
				case ':':
					if (self.langopts.has_digraphs())
					{
						id = L_BRACKET;
						self.index++;
					}
					else
					{
						id = ANGLE_BRACKET_LEFT;
					}
				case '%':
					if (self.langopts.has_digraphs())
					{
						id = L_BRACE;
						self.index++;
					}
					else
					{
						id = ANGLE_BRACKET_LEFT;
					}
				default:
					id = ANGLE_BRACKET_LEFT;
			}
		case ANGLE_BRACKET_ANGLE_BRACKET_LEFT:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = ANGLE_BRACKET_ANGLE_BRACKET_LEFT_EQUAL;
					self.index++;
				default:
					id = ANGLE_BRACKET_ANGLE_BRACKET_LEFT;
			}
		case ANGLE_BRACKET_RIGHT:
			self.index++;
			switch (buf[self.index])
			{
				case '>':
					nextcase LOOP: State.ANGLE_BRACKET_ANGLE_BRACKET_RIGHT;
				case '=':
					id = ANGLE_BRACKET_RIGHT_EQUAL;
					self.index++;
				default:
					id = ANGLE_BRACKET_RIGHT;
			}
		case ANGLE_BRACKET_ANGLE_BRACKET_RIGHT:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = ANGLE_BRACKET_ANGLE_BRACKET_RIGHT_EQUAL;
					self.index++;
				default:
					id = ANGLE_BRACKET_ANGLE_BRACKET_RIGHT;
			}
		case CARET:
			self.index++;
			switch (buf[self.index])
			{
				case '=':
					id = CARET_EQUAL;
					self.index++;
				default:
					id = CARET;
			}
		case PERIOD:
			self.index++;
			switch (buf[self.index])
			{
				case '.':
					nextcase LOOP: State.PERIOD2;
				case '0'..'9':
					nextcase LOOP: State.PP_NUM;
				default:
					id = PERIOD;
			}
		case PERIOD2:
			self.index++;
			switch (buf[self.index])
			{
				case '.':
					id = ELLIPSIS;
					self.index++;
				default:
					id = PERIOD;
					self.index--;
			}
		case MINUS:
			self.index++;
			switch (buf[self.index])
			{
				case '>':
					id = ARROW;
					self.index++;
				case '=':
					id = MINUS_EQUAL;
					self.index++;
				case '-':
					id = MINUS_MINUS;
					self.index++;
				default:
					id = MINUS;
			}
		case AMPERSAND:
			self.index++;
			switch (buf[self.index])
			{
				case '&':
					id = AMPERSAND_AMPERSAND;
					self.index++;
				case '=':
					id = AMPERSAND_EQUAL;
					self.index++;
				default:
					id = AMPERSAND;
			}
		case HASH:
			self.index++;
			switch (buf[self.index])
			{
				case '#':
					id = HASH_HASH;
					self.index++;
				default:
					id = HASH;
			}
		case HASH_DIGRAPH:
			self.index++;
			switch (buf[self.index])
			{
				case '%':
					nextcase LOOP: State.HASH_HASH_DIGRAPH_PARTIAL;
				default:
					id = HASH;
			}
		case HASH_HASH_DIGRAPH_PARTIAL:
			self.index++;
			switch (buf[self.index])
			{
				case ':':
					id = HASH_HASH;
					self.index++;
				default:
					id = HASH;
					self.index--; // re-tokenize the percent
			}
		case SLASH:
			self.index++;
			switch (buf[self.index])
			{
				case '/':
					nextcase LOOP: State.LINE_COMMENT;
				case '*':
					nextcase LOOP: State.MULTI_LINE_COMMENT;
				case '=':
					id = SLASH_EQUAL;
					self.index++;
				default:
					id = SLASH;
			}
		case LINE_COMMENT:
			self.index++;
			switch (buf[self.index])
			{
				case 0:
					if (self.index != len) nextcase LOOP: State.LINE_COMMENT;
					if (!self.langopts.preserve_comments) nextcase LOOP: State.START;
					id = COMMENT;
				case '\n':
					if (!self.langopts.preserve_comments) nextcase LOOP: State.START;
					id = COMMENT;
				default:
					nextcase LOOP: State.LINE_COMMENT;
			}
		case MULTI_LINE_COMMENT:
			self.index++;
			switch (buf[self.index])
			{
				case 0:
					if (self.index != len) nextcase LOOP: State.MULTI_LINE_COMMENT;
					id = UNTERMINATED_COMMENT;
				case '*':
					nextcase LOOP: State.MULTI_LINE_COMMENT_ASTERISK;
				case '\n':
					self.line++;
					nextcase LOOP: State.MULTI_LINE_COMMENT;
				default:
					nextcase LOOP: State.MULTI_LINE_COMMENT;
			}
		case MULTI_LINE_COMMENT_ASTERISK:
			self.index++;
			switch (buf[self.index])
			{
				case 0:
					if (self.index != len) nextcase LOOP: State.MULTI_LINE_COMMENT;
					id = UNTERMINATED_COMMENT;
				case '/':
					if (!self.langopts.preserve_comments) nextcase LOOP: State.MULTI_LINE_COMMENT_DONE;
					self.index++;
					id = COMMENT;
				case '\n':
					self.line++;
					nextcase LOOP: State.MULTI_LINE_COMMENT;
				case '*':
					nextcase LOOP: State.MULTI_LINE_COMMENT_ASTERISK;
				default:
					nextcase LOOP: State.MULTI_LINE_COMMENT;
			}
		case MULTI_LINE_COMMENT_DONE:
			self.index++;
			switch (buf[self.index])
			{
				case '\n':
					start = self.index;
					id = NL;
					self.index++;
					self.line++;
				case '\r':
					unreachable("carriage returns are removed when the source is added");
				case '\t':
				case '\v':
				case '\f':
				case ' ':
					start = self.index;
					nextcase LOOP: State.WHITESPACE;
				default:
					id = WHITESPACE;
			}
		case PP_NUM:
			self.index++;
			switch (buf[self.index])
			{
				case 'a'..'d':
				case 'A'..'D':
				case 'f'..'o':
				case 'F'..'O':
				case 'q'..'z':
				case 'Q'..'Z':
				case '0'..'9':
				case '_':
				case '.':
					nextcase LOOP: State.PP_NUM;
				case 'e':
				case 'E':
				case 'p':
				case 'P':
					nextcase LOOP: State.PP_NUM_EXPONENT;
				case '\'':
					if (self.langopts.standard.at_least(C23)) nextcase LOOP: State.PP_NUM_DIGIT_SEPARATOR;
					id = PP_NUM;
				default:
					id = PP_NUM;
			}
		case PP_NUM_DIGIT_SEPARATOR:
			self.index++;
			switch (buf[self.index])
			{
				case 'a'..'d':
				case 'A'..'D':
				case 'f'..'o':
				case 'F'..'O':
				case 'q'..'z':
				case 'Q'..'Z':
				case '0'..'9':
				case '_':
					nextcase LOOP: State.PP_NUM;
				default:
					self.index--;
					id = PP_NUM;
			}
		case PP_NUM_EXPONENT:
			self.index++;
			switch (buf[self.index])
			{
				case 'a'..'o':
				case 'q'..'z':
				case 'A'..'O':
				case 'Q'..'Z':
				case '0'..'9':
				case '_':
				case '.':
				case '+':
				case '-':
					nextcase LOOP: State.PP_NUM;
				case 'p':
				case 'P':
					nextcase LOOP: State.PP_NUM_EXPONENT;
				default:
					id = PP_NUM;
			}
	}

	while (self.splice_index < self.splice_locs.len)
	{
		if (self.splice_locs[self.splice_index] > start) break;
		self.line++;
		self.splice_index++;
	}

	return { .id = id, .start = start, .end = self.index, .line = self.line, .source = self.source };
}

<* The next token, skipping whitespace and comments. *>
fn Token Tokenizer.next_no_ws(&self)
{
	Token tok = self.next();
	while (tok.id == WHITESPACE || tok.id == COMMENT) tok = self.next();
	return tok;
}

<* The next token, skipping whitespace but keeping comments. *>
fn Token Tokenizer.next_no_ws_comments(&self)
{
	Token tok = self.next();
	while (tok.id == WHITESPACE) tok = self.next();
	return tok;
}
