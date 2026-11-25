// Port of c3c src/compiler/enums.h `TokenType` and tokens.c: the token kinds,
// their spellings (`token_type_to_string`) and token-range predicates.
//
// Deviations from c3c:
// - The spelling is an associated value (`TokenType.text`) instead of a switch.
// - The TOKEN_FIRST_KEYWORD / TOKEN_LAST_KEYWORD range markers are module
//   constants because C3 enums cannot alias a member.
// - `SourceLoc` is `SourceSpan` (same fields; `file_id` is a plain uint).
module aro::frontend::c3::tokens;

enum TokenType : char (String text)
{
	INVALID_TOKEN { "INVALID_TOKEN" },

	// Single-character tokens.
	AMP { "&" },
	AT { "@" },
	BANG { "!" },
	BIT_NOT { "~" },
	BIT_OR { "|" },
	BIT_XOR { "^" },
	COLON { ":" },
	COMMA { "," },
	EOS { ";" },
	EQ { "=" },
	GREATER { ">" },
	DIV { "/" },
	DOLLAR { "$" },
	DOT { "." },
	HASH { "#" },
	LESS { "<" },
	LBRACE { "{" },
	LBRACKET { "[" },
	LPAREN { "(" },
	MINUS { "-" },
	MOD { "%" },
	PLUS { "+" },
	QUESTION { "?" },
	RBRACE { "}" },
	RBRACKET { "]" },
	RPAREN { ")" },
	STAR { "*" },
	UNDERSCORE { "_" },

	// Two character tokens.
	AND { "&&" },
	ARROW { "->" },
	BANGBANG { "!!" },
	BIT_AND_ASSIGN { "&=" },
	BIT_OR_ASSIGN { "|=" },
	BIT_XOR_ASSIGN { "^=" },
	DIV_ASSIGN { "/=" },
	DOTDOT { ".." },
	BUILTIN { "$$" },
	ELVIS { "?:" },
	EQEQ { "==" },
	GREATER_EQ { ">=" },
	IMPLIES { "=>" },
	LESS_EQ { "<=" },
	LVEC { "[<" },
	MINUS_ASSIGN { "-=" },
	MINUSMINUS { "--" },
	MOD_ASSIGN { "%=" },
	MULT_ASSIGN { "*=" },
	NOT_EQUAL { "!=" },
	OR { "||" },
	PLUS_ASSIGN { "+=" },
	PLUSPLUS { "++" },
	RVEC { ">]" },
	QUESTQUEST { "??" },
	SCOPE { "::" },
	SHL { "<<" },
	SHR { ">>" },

	// Three or more.
	ELLIPSIS { "..." },
	SHL_ASSIGN { "<<=" },
	SHR_ASSIGN { ">>=" },
	CT_AND { "&&&" },
	CT_CONCAT { "+++" },
	CT_OR { "|||" },
	CT_TERNARY { "???" },
	CT_CONCAT_ASSIGN { "+++=" },

	// Literals.
	IDENT { "IDENT" },
	CONST_IDENT { "CONST_IDENT" },
	TYPE_IDENT { "TYPE_IDENT" },
	CT_IDENT { "CT_IDENT" },
	CT_CONST_IDENT { "CT_CONST_IDENT" },
	CT_TYPE_IDENT { "CT_TYPE_IDENT" },
	HASH_IDENT { "HASH_IDENT" },
	AT_IDENT { "MACRO_IDENT" },
	AT_CONST_IDENT { "MACRO_CONST_IDENT" },
	AT_TYPE_IDENT { "MACRO_TYPE_IDENT" },
	STRING { "STRING" },
	INTEGER { "INTEGER" },
	CHAR_LITERAL { "CHAR_LITERAL" },
	REAL { "FLOAT" },
	BYTES { "BYTES" },
	DOC_COMMENT { "DOC_COMMENT" },

	// Basic type names (FIRST_KEYWORD).
	VOID { "void" },
	BOOL { "bool" },
	CHAR { "char" },
	DOUBLE { "double" },
	FLOAT { "float" },
	FLOAT16 { "float16" },
	BFLOAT { "bfloat" },
	INT128 { "int128" },
	ICHAR { "ichar" },
	INT { "int" },
	IPTR { "iptr" },
	SZ { "sz" },
	LONG { "long" },
	SHORT { "short" },
	UINT128 { "uint128" },
	UINT { "uint" },
	ULONG { "ulong" },
	UPTR { "uptr" },
	USHORT { "ushort" },
	USZ { "usz" },
	FLOAT128 { "float128" },
	ANY { "any" },
	FAULT { "fault" },
	TYPEID { "typeid" },
	UNTYPEDLIST { "untypedlist" },

	// Keywords (FIRST_NON_TYPE_KEYWORD).
	ALIAS { "alias" },
	ASSERT { "assert" },
	ASM { "asm" },
	ATTRDEF { "attrdef" },
	ATTRMACRO { "attrmacro" },
	BITSTRUCT { "bitstruct" },
	BREAK { "break" },
	CASE { "case" },
	CATCH { "catch" },
	CONSTDEF { "constdef" },
	CONST { "const" },
	CONSTSET { "constset" },
	CONTINUE { "continue" },
	DEFAULT { "default" },
	DEFER { "defer" },
	DO { "do" },
	ELSE { "else" },
	ENUM { "enum" },
	EXTERN { "extern" },
	FALSE { "false" },
	FAULTDEF { "faultdef" },
	FOR { "for" },
	FOREACH { "foreach" },
	FOREACH_R { "foreach_r" },
	FN { "fn" },
	TLOCAL { "tlocal" },
	IF { "if" },
	INLINE { "inline" },
	IMPORT { "import" },
	LENGTHOF { "lengthof" },
	MACRO { "macro" },
	MODULE { "module" },
	NEXTCASE { "nextcase" },
	NULL { "null" },
	INTERFACE { "interface" },
	RETURN { "return" },
	STATIC { "static" },
	STRUCT { "struct" },
	SWITCH { "switch" },
	TRUE { "true" },
	TRY { "try" },
	TYPEDEF { "typedef" },
	UNION { "union" },
	VAR { "var" },
	WHILE { "while" },

	// Compile-time keywords (after LAST_NON_CT_KEYWORD).
	CT_ASSERT { "$assert" },
	CT_CASE { "$case" },
	CT_DEFAULT { "$default" },
	CT_DEFINED { "$defined" },
	CT_ECHO { "$echo" },
	CT_ELSE { "$else" },
	CT_EMBED { "$embed" },
	CT_ENDFOR { "$endfor" },
	CT_ENDFOREACH { "$endforeach" },
	CT_ENDIF { "$endif" },
	CT_ENDSWITCH { "$endswitch" },
	CT_EVAL { "$eval" },
	CT_ERROR { "$error" },
	CT_EXEC { "$exec" },
	CT_EXPAND { "$expand" },
	CT_FEAT { "$feat" },
	CT_FEATURE { "$feature" },
	CT_FOR { "$for" },
	CT_FOREACH { "$foreach" },
	CT_IF { "$if" },
	CT_INCLUDE { "$include" },
	CT_REFLECT { "$reflect" },
	CT_STRINGIFY { "$stringify" },
	CT_SWITCH { "$switch" },
	CT_TYPEFROM { "$Typefrom" },
	CT_TYPEOF { "$Typeof" },
	CT_VAARG { "$vaarg" },
	DOCS_START { "<*" },
	DOCS_END { "*>" },
	DOCS_EOL { "<EOL>" },

	EOF { "EOF" },
}

const TokenType FIRST_KEYWORD = VOID;
const TokenType FIRST_NON_TYPE_KEYWORD = ALIAS;
const TokenType LAST_NON_CT_KEYWORD = WHILE;
const TokenType LAST_KEYWORD = CT_VAARG;

<* c3c `token_is_any_type`. *>
fn bool TokenType.is_any_type(self)
{
	return (self >= VOID && self <= TYPEID) || self == CT_TYPE_IDENT || self == TYPE_IDENT;
}

<* True for the reserved words (types, keywords and `$` keywords). *>
fn bool TokenType.is_keyword(self) => self >= FIRST_KEYWORD && self <= LAST_KEYWORD;

<* c3c `SourceLoc`: a span in a file; `row` and `col` are 1-based. *>
struct SourceSpan
{
	uint file_id;
	ushort col;
	uint offset;
	uint length;
	uint row;
}
