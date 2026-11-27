// #kind: expand_error
#define one a ## // #error@15: '##' cannot appear at the end of a macro expansion
#define two a ## ## // #error@18: '##' cannot appear at the end of a macro expansion
#define three ## // #error@15: '##' cannot appear at the start of a macro expansion
#define four(1) // #error@14: invalid token in macro parameter list
#define five(a,... b // #error@20: missing ')' in macro parameter list // #note@13: to match this '('
#define six(a 1) // #error@15: expected comma in macro parameter list
#define seven(a) #b // #error@19: '#' is not followed by a macro parameter
#define eight(a) ## // #error@18: '##' cannot appear at the start of a macro expansion
#define nine(a) a ## // #error@19: '##' cannot appear at the end of a macro expansion
#define ten## // #warning@12: ISO C99 requires whitespace after the macro name [-Wc99-extensions] // #error@12: '##' cannot appear at the start of a macro expansion

#if defined one || defined two || defined three || defined four || defined five \
     || defined six || defined seven || defined eight || defined nine || defined ten
#error failed
#endif

