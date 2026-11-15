#if &x // #error@5: invalid token at start of a preprocessor expression
#error "failed"
#endif

#if *x // #error@5: invalid token at start of a preprocessor expression
#error "failed"
#endif

#if x &= 1 // #error@7: token is not a valid binary operator in a preprocessor subexpression
#error "failed"
#endif

#if ~0 && 0
#error "failed"
#endif

#if !1
#error "failed"
#endif

#if x++ // #error@6: token is not a valid binary operator in a preprocessor subexpression
#error "failed"
#endif

#if ++x // #error@5: invalid token at start of a preprocessor expression
#error "failed"
#endif

#if x + y++ // #error@10: token is not a valid binary operator in a preprocessor subexpression
#error "failed"
#endif

#if 'c' && 0
#error "failed"
#endif

#define FOO BAR
#if FOO[0] // #error@8: token is not a valid binary operator in a preprocessor subexpression
#error "failed"
#endif

#if ) // #error@5: expected value in expression
#error "failed"
#endif

#if "not allowed" // #error@5: invalid token at start of a preprocessor expression
#error "failed"
#endif

#if U"not allowed" // #error@5: invalid token at start of a preprocessor expression
#endif

#define BAZ -- // #note@13: expanded from here // #note@13: expanded from here
#if 0 BAZ // #error@7: token is not a valid binary operator in a preprocessor subexpression
error "failed"
#endif

#if BAZ // #error@5: invalid token at start of a preprocessor expression
error "failed"
#endif

#if 1 + &x // #error@9: invalid token at start of a preprocessor expression
#endif

#if 1 < ABC 2 // #error@13: token is not a valid binary operator in a preprocessor subexpression
#endif

#if -9223372036854775808 / -1 // #warning@6: integer literal is too large to be represented in a signed integer type, interpreting as unsigned [-Wimplicitly-unsigned-literal] // #warning@26: right side of operator converted from negative value to unsigned: -1 to 18446744073709551615
#endif

#if 0 && (1 - 1U)
#endif

#if -(-9223372036854775807L -1) // #warning@5: integer overflow in preprocessor expression
#endif

#if 0 && (1 && (1 / 0))
#endif

#if (4 >> -2) != 0 // #warning@8: integer overflow in preprocessor expression
#error bad shr
#endif

#if (4 >> 250) != 0 // #warning@8: integer overflow in preprocessor expression
#error bad shr
#endif

#if (4U >> -2) != 0 // #warning@9: integer overflow in preprocessor expression
#error bad shr
#endif

#if (4U >> 250) != 0 // #warning@9: integer overflow in preprocessor expression
#error bad shr
#endif

#if (4 << -2) != 0 // #warning@8: integer overflow in preprocessor expression
#error bad shl
#endif

#if (4 << 250) != 0 // #warning@8: integer overflow in preprocessor expression
#error bad shl
#endif

#if (4U << -2) != 0 // #warning@9: integer overflow in preprocessor expression
#error bad shl
#endif

#if (4U << 250) != 0 // #warning@9: integer overflow in preprocessor expression
#error bad shl
#endif

#if ((-9223372036854775807 - 1) / -1) != (-9223372036854775807 - 1) // #warning@33: integer overflow in preprocessor expression
#error bad div overflow
#endif

#if ((-9223372036854775807 - 1) % -1) != 0
#error bad mod overflow
#endif

#if 0xFFFFFFFFFFFFFFFF != -1 // #warning@24: right side of operator converted from negative value to unsigned: -1 to 18446744073709551615
#error bad big hex int
#endif

#if defined(FOO foo // #error@17: expected closing ')' // #note@12: to match this '('
#error bad
#endif

#if (1 foo // #error@8: expected closing ')' // #note@5: to match this '('
#error bad
#endif

// Usual arithmetic conversion means the result of the ternary expression is converted to unsigned
#if (0 ? 0u : -1) != 18446744073709551615ULL
#error bad
#endif

// Usual arithmetic conversion stemming from the 0u in the inner ternary expression
// propagates all the way out to the final lhs of != and therefore turns the rhs of
// the != to unsigned as well
#if (0 ? (0 ? 0u : 1) : -1) != -1 // #warning@29: right side of operator converted from negative value to unsigned: -1 to 18446744073709551615
#error bad
#endif

