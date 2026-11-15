// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c23 -pedantic -Wundef
#include <stdbool.h>
static_assert(1 == 1);
static_assert(alignof(char) == 1);
thread_local int x;
bool b = 1;
int alignas(16) y;

#define static_assert no // #warning@9: keyword is hidden by macro definition [-Wkeyword-macro]
#define alignof no // #warning@9: keyword is hidden by macro definition [-Wkeyword-macro]
#define thread_local no // #warning@9: keyword is hidden by macro definition [-Wkeyword-macro]
#define bool no // #warning@9: keyword is hidden by macro definition [-Wkeyword-macro]
#define alignas no // #warning@9: keyword is hidden by macro definition [-Wkeyword-macro]

typedef typeof(int) MyInt;

#if false
#error false should expand to 0
#endif

#if true
#else
#error true should expand to 1
#endif

#define FOO true
#if FOO
#else
#error true should expand to 1
#endif

#if true + 1 != 2
#error true should expand to 1 in preprocessor arithmetic
#endif

#if defined(true) || defined(false)
#error true and false should not be defined
#endif

