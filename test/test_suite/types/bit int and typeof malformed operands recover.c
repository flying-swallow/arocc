// #opt: -std=c23 -target x86_64-linux
int runtime_width = 8; _BitInt() empty_width; int after_empty = 1; // #error@31: expected expression
_BitInt(runtime_width) runtime_width_decl; int after_runtime = 2; // #error@9: expression is not an integer constant expression // #error@24: a type specifier is required for all declarations
_BitInt(8 unclosed_width; int after_unclosed = 3; // #error@11: expected ')', found 'an identifier' // #note@8: to match this '('
typeof() empty_operand; int after_empty_typeof = 4; // #error@7: expected expression
typeof(1 +) incomplete_operand; int after_incomplete = 5; // #error@11: expected expression
typeof(int) long conflicting; int after_conflict = 6; // #error@13: 'long typeof' is invalid

#define IS(x, T) _Generic(&(x), T *: 1, default: 0)
_Static_assert(IS(runtime_width, int), "");
_Static_assert(IS(after_empty, int), "");
_Static_assert(IS(after_runtime, int), "");
_Static_assert(IS(after_unclosed, int), "");
_Static_assert(IS(after_empty_typeof, int), "");
_Static_assert(IS(after_incomplete, int), "");
_Static_assert(IS(after_conflict, int), "");
