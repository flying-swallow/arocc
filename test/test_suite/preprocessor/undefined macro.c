#pragma GCC diagnostic warning "-Wundef"

#if FOO // #warning@5: 'FOO' is not defined, evaluates to 0 [-Wundef]
    #error "Error"
#endif

#define FOO BAR // #note@13: expanded from here

#if FOO // #warning@5: 'BAR' is not defined, evaluates to 0 [-Wundef]
    #error "Error"
#endif

#if undefined(foo) // #warning@5: 'undefined' is not defined, evaluates to 0 [-Wundef] // #error@5: function-like macro 'undefined' is not defined
#error bad
#endif

