// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c2y
// #note: stdcountof.h:5:17: expanded from here
#include <stdcountof.h>

void countof_usage(int a, struct {int dummy; int arr[]; } b, int c[a]) {
    int vla[a], arr[2];
    (void)countof vla;
    static_assert(countof arr == 2);

    (void)countof a; // #error@19: '_Countof' requires an argument of array type; 'int' is invalid
    (void)countof b.arr; // #error@19: '_Countof' requires an argument of array type; 'int []' is invalid

    #pragma GCC diagnostic warning "-Wpre-c2y-compat"
    (void)countof c; // #warning@11: '_Countof' is incompatible with C standards before C2y [-Wpre-c2y-compat] // #error@19: '_Countof' requires an argument of array type; 'int *' is invalid
}

