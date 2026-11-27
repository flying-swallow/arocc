// #note: stdckdint.h:7:60: expanded from here
// #note: stdckdint.h:8:54: expanded from here
// #note: stdckdint.h:9:60: expanded from here
// #note: stdckdint.h:7:60: expanded from here
// #note: stdckdint.h:8:60: expanded from here
// #note: stdckdint.h:9:60: expanded from here
#include <stdckdint.h>

enum E {
    A,
};

void foo(void) {
    int x = 0;
    unsigned y = 2;
    _Bool b, overflowed;
    enum E e;
    unsigned res;
    const unsigned const_res;
    unsigned arr[2];

    overflowed = ckd_add(&res, x, y);
    overflowed = ckd_sub(&res, x, y);
    overflowed = ckd_mul(&res, x, y);
    overflowed = ckd_add(arr, x, y);

    overflowed = ckd_add(res, x, y); // non-pointer result // #error@18: result argument to overflow builtin must be a pointer to a non-const integer ('unsigned int' invalid) // #note@26: expanded from here
    overflowed = ckd_sub(&res, 1.2, y); // non-int argument // #error@18: operand argument to overflow builtin must be an integer ('double' invalid) // #note@32: expanded from here
    overflowed = ckd_mul(&b, x, y); // pointer to boolean result // #error@18: result argument to overflow builtin must be a pointer to a non-const integer ('_Bool *' invalid) // #note@26: expanded from here
    overflowed = ckd_add(&const_res, x, y); // pointer to const result // #error@18: result argument to overflow builtin must be a pointer to a non-const integer ('const unsigned int *' invalid) // #note@26: expanded from here
    overflowed = ckd_sub(&e, x, y); // pointer to enumerated result // #error@18: result argument to overflow builtin must be a pointer to a non-const integer ('enum E *' invalid) // #note@26: expanded from here
    overflowed = ckd_mul((void *)&res, x, y); // pointer to non-int result // #error@18: result argument to overflow builtin must be a pointer to a non-const integer ('void *' invalid) // #note@26: expanded from here

}

