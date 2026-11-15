// #kind: expand_error
#define FOO(X) X##OK
#define BAR FOO

#define A 1

#if BAR(A)
#error Should not error
#endif

BAR(A)

#define AOK 1
#if BAR(A)
#error Should error // #error@2: Should error
#endif

BAR(A)

