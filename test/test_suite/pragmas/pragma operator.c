// #skip: diagnostics differ (aro_c3 gap)
// #note: <scratch space>:4:13: expanded from here
// #note: <scratch space>:9:9: expanded from here
#include "include/global_var_once_pragma_operator.h"
#include "include/global_var_once_pragma_operator.h"

#define PRAGMA(X) _Pragma(#X) // #note@19: expanded from here // #note@19: expanded from here

PRAGMA(GCC warning "This is a warning") // #warning@1: This is a warning [-W#pragma-messages]

void foo(void) {
    int x = 1;
    PRAGMA(GCC diagnostic error "-Wpointer-integer-compare")
    (void)(x == (int *)2); // #error@14: comparison between pointer and integer ('int' and 'int *') [-Werror,-Wpointer-integer-compare]
    _Pragma("GCC diagnostic warning \"-Wpointer-integer-compare\"" )
    (void)(x == (int *)2); // #warning@14: comparison between pointer and integer ('int' and 'int *') [-Wpointer-integer-compare]
}

#pragma GCC diagnostic warning "-Wunknown-pragmas"

_Pragma(GCC diagnostic error "-Wpointer-integer-compare") // #error@9: _Pragma requires exactly one string literal token
PRAGMA(Not a pragma) // #warning@1: unknown pragma ignored [-Wunknown-pragmas]
_Pragma() // #error@1: _Pragma requires exactly one string literal token

