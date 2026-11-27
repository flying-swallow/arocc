#define FOO(X) X

#if FOO( X )
#error Should not error
#endif

#define Y 1

#if FOO ( Y )
#error Should error // #error@2: Should error
#endif

