#if __has_attribute(42) // #error@21: builtin feature check macro requires a parenthesized identifier
#endif

#if __has_attribute aligned // #error@5: missing '(' after built-in macro '__has_attribute' // #error@21: token is not a valid binary operator in a preprocessor subexpression
#endif

#if __has_attribute(aligned // #error@5: unterminated function macro argument list
#endif // #error@28: expected value in expression

#define __has_attribute 42 // #warning@9: redefining builtin macro [-Wbuiltin-macro-redefined]
int x = __has_attribute;

#if __has_feature(__const__)
#endif

